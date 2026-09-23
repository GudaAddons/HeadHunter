-- HH-090 / HH-091: High Noon duel records (docs/addon/features.md section 10).
--
-- Detection: the game announces every duel result in chat to the players nearby
-- (CHAT_MSG_SYSTEM, the client's DUEL_WINNER_KNOCKOUT and DUEL_WINNER_RETREAT
-- strings, turned into patterns so it works in every language). Any HeadHunter nearby
-- records the duel, even when the duelists do not use the addon. A retreat counts as a
-- loss. Duels never touch WANTED.
-- WoW Forever sends no result line: there the duelists' own addons judge their duel
-- (DUEL_REQUESTED, countdown, UNIT_HEALTH, DUEL_OUTOFBOUNDS, DUEL_FINISHED; see "Our
-- own duels" below). Era does both; the pair dedupe keeps one.
-- Only fair duels count: both levels known, both at least MIN_LEVEL (10), and at most
-- LEVEL_RANGE apart (author, 2026-09-23: beating lowbies must not climb the list).
-- Checked when a duel is seen, when a record arrives and when stored duels are pruned.
--
-- ns.db.duels is a grow-only set, keyed "<winner>><loser>:<time>". Many witnesses see
-- the same duel: the same pair within DEDUPE seconds is one duel.
-- Duels happen inside one faction; the record says which. Other-faction HeadHunters'
-- duel records are accepted too (Transport lets only this type through), rate limited,
-- so High Noon can list both factions. Shared on the automatic routes and by login
-- catch-up (Sync/CatchUp.lua). Fires HH_DUEL_ADDED(duel).

local addonName, ns = ...
local L = ns.L

local Duels = ns:RegisterModule("Duels", {})

local OWNER = "Duels"

Duels.DEDUPE = 60           -- the same pair within a minute is one duel
Duels.MAX_AGE = 90 * 86400  -- a season
Duels.MAX_COUNT = 5000
Duels.MAX_SKEW = 300
Duels.SENDER_LIMIT = 30     -- duel records accepted per sender per window
Duels.SENDER_WINDOW = 600
Duels.LEVEL_RANGE = 5       -- the most levels apart two duelists can be
Duels.MIN_LEVEL = 10        -- High Noon starts at level 10 (author, 2026-09-23)
Duels.MIN_FIGHT = 2         -- seconds after the last countdown line: shorter is a cancel

-- enUS, used when the client's strings are missing
Duels.KNOCKOUT_FORMAT = "%1$s has defeated %2$s in a duel"
Duels.RETREAT_FORMAT = "%2$s has fled from %1$s in a duel"

local byPair = {}           -- "a|b" (sorted) -> array of times, for the dedupe
local senderLog = {}
local patterns              -- built on first use: { { pattern, order, retreat } ... }

local function Store()
    return ns.db and ns.db.duels
end

-------------------------------------------------
-- Detection
-------------------------------------------------

-- A client format string ("%1$s has defeated %2$s in a duel", or with plain %s) as a
-- Lua pattern; order[i] = which argument capture i is
function Duels.Pattern(format)
    local pattern, order, pos = "^", {}, 1
    while true do
        local s, e, index = format:find("%%(%d*)%$?s", pos)
        local literal = format:sub(pos, s and s - 1 or nil)
        pattern = pattern .. (literal:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
        if not s then break end
        order[#order + 1] = tonumber(index) or (#order + 1)
        pattern = pattern .. "(.+)"
        pos = e + 1
    end
    return pattern .. "$", order
end

local function Patterns()
    if patterns then return patterns end
    patterns = {}
    for _, item in ipairs({ { DUEL_WINNER_KNOCKOUT or Duels.KNOCKOUT_FORMAT, false },
            { DUEL_WINNER_RETREAT or Duels.RETREAT_FORMAT, true } }) do
        local pattern, order = Duels.Pattern(item[1])
        patterns[#patterns + 1] = { pattern = pattern, order = order, retreat = item[2] }
    end
    return patterns
end

-- A system message: winner, loser, retreat; or nil when it is not a duel result
function Duels.Parse(message)
    if type(message) ~= "string" then return nil end
    for _, p in ipairs(Patterns()) do
        local captures = { message:match(p.pattern) }
        if #captures == #p.order and #captures >= 2 then
            local args = {}
            for i, value in ipairs(captures) do args[p.order[i]] = value end
            if args[1] and args[2] then return args[1], args[2], p.retreat end
        end
    end
    return nil
end

-- Unit tokens to look for the duelists (level, class, race, faction)
local TOKENS = { "player", "target", "mouseover", "focus", "party1", "party2", "party3", "party4" }

local function FindUnit(key)
    local U = ns.Utils
    for _, token in ipairs(TOKENS) do
        if U.UnitIsPlayer(token) and U.SameCharacter(U.UnitKey(token), key) then return token end
    end
    for i = 1, 40 do
        local token = "nameplate" .. i
        if U.UnitIsPlayer(token) and U.SameCharacter(U.UnitKey(token), key) then return token end
    end
    return nil
end

-- Levels of players seen lately (target, mouseover, nameplates): the duel message can
-- come when the opponent is no longer targeted. key -> { level, at }
Duels.SEEN_WINDOW = 600
local seenLevels = {}

function Duels:RememberUnit(unit)
    local U = ns.Utils
    if not U.UnitIsPlayer(unit) then return end
    local key, level = U.UnitKey(unit), U.UnitLevel(unit)
    if key and level and level >= 1 then seenLevels[key] = { level = level, at = U.Now() } end
end

-- A duelist's level: from a visible unit, else seen lately, else the enemy cache;
-- nil when unknown (a skull, -1, is unknown too: only "10+ above us")
local function LevelOf(key, unit)
    local level = unit and ns.Utils.UnitLevel(unit)
    if not level or level < 1 then
        local seen = seenLevels[key]
        level = seen and ns.Utils.Now() - seen.at < Duels.SEEN_WINDOW and seen.level or nil
    end
    if not level then
        local enemy = ns.EnemyCache:ByKey(key)
        level = enemy and tonumber(enemy.level)
    end
    return level and level >= 1 and level or nil
end

-- Both levels known, both MIN_LEVEL or higher, and at most LEVEL_RANGE apart
function Duels.Fair(duel)
    local a, b = tonumber(duel.winnerLevel), tonumber(duel.loserLevel)
    return a ~= nil and b ~= nil and a >= Duels.MIN_LEVEL and b >= Duels.MIN_LEVEL
        and math.abs(a - b) <= Duels.LEVEL_RANGE
end

-- Whose duel was it? A duelist we can see tells; one the enemy cache knows is the
-- other faction; otherwise our own (duels nearby are mostly our faction's).
function Duels.FactionOf(winner, loser, winnerUnit, loserUnit)
    local U = ns.Utils
    local unit = winnerUnit or loserUnit
    local faction = unit and U.UnitFaction(unit)
    if faction then return faction end
    local mine = U.UnitFaction("player")
    if ns.EnemyCache:ByKey(winner) or ns.EnemyCache:ByKey(loser) then
        return mine == "Alliance" and "Horde" or (mine == "Horde" and "Alliance" or nil)
    end
    return mine
end

-- The countdown ("Duel starting: 3"): a duel of ours begins
local function IsCountdown(message)
    local format = DUEL_COUNTDOWN or "Duel starting: %d"
    local pattern = "^" .. format:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%d", "%%d+") .. "$"
    return message:find(pattern) ~= nil
end

function Duels:OnSystemMessage(message)
    if not ns.Guards:IsActive() or type(message) ~= "string" then return nil end
    local winnerName, loserName, retreat = Duels.Parse(message)
    if not winnerName then
        if IsCountdown(message) then
            self:OnOwnDuelStart()
        elseif message:lower():find("duel", 1, true) then
            ns:Debug("Duel message not understood:", message)
        end
        return nil
    end
    local U = ns.Utils
    return self:Record(U.PlayerKey(winnerName), U.PlayerKey(loserName), retreat)
end

-------------------------------------------------
-- Our own duels (WoW Forever sends no result line, 2026-09-23): the opponent is the
-- challenger (DUEL_REQUESTED) or our target when the countdown starts. At
-- DUEL_FINISHED the one at 1 HP lost; leaving the duel area (DUEL_OUTOFBOUNDS) is a
-- retreat. On Era the result line records the same duel; the pair dedupe keeps one.
-------------------------------------------------

local own = nil            -- { opponent = key, fled = bool, low = { [key] = true } }

local function Health(unit)
    local U = ns.Utils
    return tonumber(U.Accessible(U.SafeCall(_G.UnitHealth, unit)))
end

local function OpponentFromTarget()
    local U = ns.Utils
    if not U.UnitIsPlayer("target") then return nil end
    local key = U.UnitKey("target")
    if not key or U.SameCharacter(key, U.UnitKey("player")) then return nil end
    Duels:RememberUnit("target")
    return key
end

function Duels:OnDuelRequested(name)
    own = { opponent = ns.Utils.PlayerKey(name), low = {} }
end

-- Every countdown line; the fight starts about a second after the last one
function Duels:OnOwnDuelStart()
    own = own or { low = {} }
    own.opponent = own.opponent or OpponentFromTarget()
    Duels:RememberUnit("target") -- their level, in case the target changes before the end
    own.countdownAt = ns.Utils.Now()
    ns:Debug("Duel countdown against", tostring(own.opponent))
end

-- UNIT_HEALTH during our duel: remember who dropped to 1 HP (health comes back later)
function Duels:OnHealth(unit)
    if not own then return end
    local U = ns.Utils
    if unit ~= "player" and unit ~= "target" and not (unit and unit:find("^nameplate")) then return end
    local hp = Health(unit)
    local key = U.UnitKey(unit)
    if hp and hp <= 1 and key then own.low[key] = true end
end

function Duels:OnDuelFinished()
    local duel = own
    own = nil
    if not duel or not ns.Guards:IsActive() then return nil end
    local U = ns.Utils
    -- Cancelled before or right at the start (no countdown, or finished within it)
    if not duel.countdownAt or U.Now() - duel.countdownAt < Duels.MIN_FIGHT then
        ns:Debug("Duel cancelled, not counted")
        return nil
    end
    local me = U.UnitKey("player")
    local opponent = duel.opponent or OpponentFromTarget()
    if not (me and opponent) then
        ns:Debug("Duel finished, opponent unknown")
        return nil
    end
    local opponentUnit = FindUnit(opponent)
    local meLow = duel.low[me] or (Health("player") or 2) <= 1
    local opponentLow = duel.low[opponent] or (opponentUnit and (Health(opponentUnit) or 2) <= 1)
    if duel.fled then return self:Record(opponent, me, true) end
    if meLow then return self:Record(opponent, me, false) end
    -- We stand: they went down (maybe unseen: enemy health can be hidden) or ran away
    return self:Record(me, opponent, not opponentLow)
end

-- A duel result from any source we saw ourselves: store it and share it
function Duels:Record(winner, loser, retreat)
    local U = ns.Utils
    if not (winner and loser) then return nil end
    local winnerUnit, loserUnit = FindUnit(winner), FindUnit(loser)
    local duel = {
        winner = winner, loser = loser, t = U.ServerTime(), retreat = retreat or nil,
        mapID = ns.Zones.ZoneOf(U.PlayerMapID()),
        faction = Duels.FactionOf(winner, loser, winnerUnit, loserUnit),
        winnerClass = winnerUnit and U.UnitClass(winnerUnit), winnerRace = winnerUnit and U.UnitRace(winnerUnit),
        loserClass = loserUnit and U.UnitClass(loserUnit), loserRace = loserUnit and U.UnitRace(loserUnit),
        winnerLevel = LevelOf(winner, winnerUnit), loserLevel = LevelOf(loser, loserUnit),
    }
    if not Duels.Fair(duel) then
        ns:Debug("Duel not counted (levels", tostring(duel.winnerLevel), "vs", tostring(duel.loserLevel) .. "):",
            winner, ">", loser)
        return nil
    end
    local added = self:Add(duel, "local")
    ns:Debug(added and "Duel recorded:" or "Duel already known:", winner, "(" .. duel.winnerLevel .. ") >",
        loser, "(" .. duel.loserLevel .. ")", duel.faction)
    if added then
        local Transport = ns.Transport
        Transport:Queue(ns.Protocol.TYPES.DUEL, ns.Protocol.EncodeDuel(added), Transport.PRIORITY.bulk,
            "U:" .. added.id)
    end
    return added
end

-------------------------------------------------
-- Store
-------------------------------------------------

local function PairKey(a, b)
    if a > b then a, b = b, a end
    return a .. "|" .. b
end

local function SeenRecently(duel)
    for _, t in ipairs(byPair[PairKey(duel.winner, duel.loser)] or {}) do
        if math.abs(t - duel.t) < Duels.DEDUPE then return true end
    end
    return false
end

local function Index(duel)
    local key = PairKey(duel.winner, duel.loser)
    byPair[key] = byPair[key] or {}
    table.insert(byPair[key], duel.t)
end

function Duels:All()
    return pairs(Store() or {})
end

function Duels:Count()
    local n = 0
    for _ in self:All() do n = n + 1 end
    return n
end

-- Returns the stored duel, or nil (a duplicate, or no database yet)
function Duels:Add(duel, origin, sender)
    local store = Store()
    if not store or not duel.winner or not duel.loser or duel.winner == duel.loser then return nil end
    if not Duels.Fair(duel) then return nil end
    if SeenRecently(duel) then return nil end
    duel.id = duel.winner .. ">" .. duel.loser .. ":" .. duel.t
    if store[duel.id] then return nil end
    duel.origin, duel.sender = origin, sender
    store[duel.id] = duel
    Index(duel)
    ns.Events:Fire("HH_DUEL_ADDED", duel)
    return duel
end

function Duels:Prune(now)
    local store = Store()
    if not store then return end
    local minTime = (now or ns.Utils.ServerTime()) - self.MAX_AGE
    local list = {}
    for id, duel in pairs(store) do
        if type(duel) ~= "table" or (tonumber(duel.t) or 0) < minTime or not Duels.Fair(duel) then
            store[id] = nil
        else
            list[#list + 1] = duel
        end
    end
    if #list > self.MAX_COUNT then
        table.sort(list, function(a, b) return a.t < b.t end)
        for i = 1, #list - self.MAX_COUNT do store[list[i].id] = nil end
    end
    byPair = {}
    for _, duel in pairs(store) do Index(duel) end
end

-- Duels newer than `since`, newest first, at most `limit` (login catch-up)
function Duels:Since(since, limit)
    local list = {}
    for _, duel in self:All() do
        if duel.t > since then list[#list + 1] = duel end
    end
    table.sort(list, function(a, b) return a.t > b.t end)
    for i = #list, (limit or #list) + 1, -1 do list[i] = nil end
    return list
end

-------------------------------------------------
-- Peers
-------------------------------------------------

local function UnderRateLimit(sender)
    local id = ns.Utils.CompactName(sender)
    local now = ns.Utils.Now()
    local recent = {}
    for _, at in ipairs(senderLog[id] or {}) do
        if now - at < Duels.SENDER_WINDOW then recent[#recent + 1] = at end
    end
    senderLog[id] = recent
    if #recent >= Duels.SENDER_LIMIT then return false end
    recent[#recent + 1] = now
    return true
end

-- A duel record from another HeadHunter (either faction), or relayed at login
function Duels:OnRecord(record, sender, origin)
    local duel = ns.Protocol.DecodeDuel(record)
    if not duel then return nil end
    local U = ns.Utils
    duel.winner, duel.loser = U.PlayerKey(duel.winner), U.PlayerKey(duel.loser)
    if not (duel.winner and duel.loser) then return nil end
    local now = U.ServerTime()
    if duel.t > now + self.MAX_SKEW or duel.t < now - self.MAX_AGE then return nil end
    if origin ~= "relay" and not UnderRateLimit(sender) then return nil end
    return self:Add(duel, origin or "peer", sender)
end

ns.Events:Register("HH_INITIALIZED", function()
    Duels:Prune()
    ns.Transport:RegisterHandler(ns.Protocol.TYPES.DUEL, function(record, sender) Duels:OnRecord(record, sender) end)
    ns.Events:Register("CHAT_MSG_SYSTEM", function(_, message) Duels:OnSystemMessage(message) end, OWNER)
    ns.Events:Register("PLAYER_TARGET_CHANGED", function() Duels:RememberUnit("target") end, OWNER)
    ns.Events:Register("UPDATE_MOUSEOVER_UNIT", function() Duels:RememberUnit("mouseover") end, OWNER)
    ns.Events:Register("NAME_PLATE_UNIT_ADDED", function(_, unit) Duels:RememberUnit(unit) end, OWNER)
    -- Our own duels (the only way on Forever)
    ns.Events:Register("DUEL_REQUESTED", function(_, name) Duels:OnDuelRequested(name) end, OWNER)
    ns.Events:Register("DUEL_OUTOFBOUNDS", function() if own then own.fled = true end end, OWNER)
    ns.Events:Register("DUEL_INBOUNDS", function() if own then own.fled = false end end, OWNER)
    ns.Events:Register("UNIT_HEALTH", function(_, unit) Duels:OnHealth(unit) end, OWNER)
    ns.Events:Register("DUEL_FINISHED", function() Duels:OnDuelFinished() end, OWNER)end, OWNER)
