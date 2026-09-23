-- HH-048: Justice served. A WANTED outlaw killed by a HeadHunter or their group
-- ends WANTED for everyone, and the outlaw's count starts again from zero
-- (Rules/Engine.lua; author decision 2026-09-23).
--
-- ns.db.justice is a grow-only set like the death reports, keyed "<outlaw id>:<time>":
--   { id, outlaw, t, mapID, killer (who landed the blow), hunter (who reported), how }
-- Every client derives WANTED from reports + catches, so all agree.
--
-- Detection (only for an enemy that is WANTED right now):
--   Era      combat log PARTY_KILL by us, our pet or a group member
--   Forever  no combat log: our target, a WANTED enemy player, died while we were
--            in combat (less exact: we may not have landed the blow)
-- Sync: the automatic routes. On Era the realm-wide channel needs a click, so the
-- hunter gets [Announce] (a typed /hh justice works too).
-- Peer catches are accepted with a plausible time, under a per-sender rate limit.
-- Fires HH_JUSTICE_ADDED(record).

local addonName, ns = ...
local L = ns.L

local Justice = ns:RegisterModule("Justice", {})

local OWNER = "Justice"

Justice.MAX_SKEW = 300
Justice.DEDUPE = 60            -- one catch per outlaw per minute (group members all see it)
Justice.SENDER_LIMIT = 5       -- catches accepted per sender per window
Justice.SENDER_WINDOW = 600
Justice.COMBAT_GRACE = 5       -- Forever: seconds after combat a target death still counts

-- COMBATLOG_OBJECT_* bits
local AFFILIATION_OURS = 0x00000007 -- MINE | PARTY | RAID
local TYPE_PLAYER = 0x00000400
local REACTION_HOSTILE = 0x00000040

local senderLog = {}
local toAnnounce = {}           -- Era: our catch ids waiting for the [Announce] click
local lastCombat = 0

local function Store()
    return ns.db and ns.db.justice
end

function Justice:Get(id)
    local store = Store()
    return id and store and store[id]
end

function Justice:All()
    return pairs(Store() or {})
end

-- enemy id -> array of catch times, for the rules
function Justice:CatchesByOutlaw()
    local result = {}
    for _, record in self:All() do
        result[record.outlaw] = result[record.outlaw] or {}
        table.insert(result[record.outlaw], record.t)
    end
    return result
end

-- Newest catch of one outlaw
function Justice:Latest(outlawId)
    local best
    for _, record in self:All() do
        if record.outlaw == outlawId and (not best or record.t > best.t) then best = record end
    end
    return best
end

-- Catches live as long as the reports they apply to
function Justice:Prune(now)
    local store = Store()
    if not store then return end
    local minTime = (now or ns.Utils.ServerTime()) - ns.Reports.MAX_AGE
    for id, record in pairs(store) do
        if type(record) ~= "table" or (tonumber(record.t) or 0) < minTime then store[id] = nil end
    end
end

function Justice:Add(record, origin, sender)
    local store = Store()
    if not store or not record.id or store[record.id] then return nil end
    record.origin = origin
    record.sender = sender
    store[record.id] = record
    ns:Debug("Justice added", record.id, "origin", origin)
    ns.Events:Fire("HH_JUSTICE_ADDED", record)
    return record
end

-------------------------------------------------
-- Our own catch
-------------------------------------------------

-- entry: the WANTED entry; killer: who landed the blow (nil = us)
function Justice:Record(entry, how, killer)
    local U = ns.Utils
    local now = U.ServerTime()
    local latest = self:Latest(entry.id)
    if latest and math.abs(now - latest.t) < self.DEDUPE then return nil end
    local me = U.UnitKey("player")
    local record = {
        id = entry.id .. ":" .. now, outlaw = entry.id, t = now,
        mapID = ns.Zones.ZoneOf(U.PlayerMapID()), killer = killer or me, hunter = me, how = how,
    }
    if not self:Add(record, "local") then return nil end
    local Protocol, Transport = ns.Protocol, ns.Transport
    Transport:Queue(Protocol.TYPES.JUSTICE, self.Encode(record), Transport.PRIORITY.alert, "K:" .. record.id)
    if Transport:RealmWideNeedsClick() then toAnnounce[#toAnnounce + 1] = record.id end
    return record
end

function Justice.Encode(record)
    return ns.Protocol.EncodeJustice(record.outlaw, record.t, record.mapID, record.killer)
end

-- An enemy player died by our hand or our group's: a catch if WANTED right now
function Justice:OnEnemyKilled(key, guid, how, killer)
    if not ns.Guards:IsActive() then return nil end
    local Wanted = ns.Wanted
    local entry = (key and Wanted:ByKey(key)) or (guid and Wanted:Get("guid:" .. guid))
    if not (entry and entry.wanted) then return nil end
    return self:Record(entry, how, killer)
end

-- Era: PARTY_KILL is logged for kills by us, our pet or a group member
function Justice:OnCombatLog()
    local _, subevent, _, _, sourceName, sourceFlags, _, destGUID, destName, destFlags = CombatLogGetCurrentEventInfo()
    if subevent ~= "PARTY_KILL" then return end
    if type(sourceFlags) ~= "number" or type(destFlags) ~= "number" then return end
    if bit.band(sourceFlags, AFFILIATION_OURS) == 0 then return end
    if bit.band(destFlags, TYPE_PLAYER) == 0 or bit.band(destFlags, REACTION_HOSTILE) == 0 then return end
    -- Duel opponents are flagged hostile too
    if ns.Utils.IsSameFactionGUID(destGUID) then return end
    self:OnEnemyKilled(ns.Utils.PlayerKey(destName), destGUID, "combatlog", ns.Utils.PlayerKey(sourceName))
end

-- Forever: our target died while we were fighting
function Justice:CheckTarget()
    local U = ns.Utils
    if not U.UnitIsEnemyPlayer("target") then return end
    if U.Accessible(U.SafeCall(UnitIsDead, "target")) ~= true then return end
    local fighting = U.SafeCall(UnitAffectingCombat, "player") == true
    if not fighting and U.Now() - lastCombat > self.COMBAT_GRACE then return end
    self:OnEnemyKilled(U.UnitKey("target"), U.UnitGUID("target"), "target")
end

-------------------------------------------------
-- Peers
-------------------------------------------------

local function UnderRateLimit(sender)
    local id = ns.Utils.CompactName(sender)
    local now = ns.Utils.Now()
    local recent = {}
    for _, at in ipairs(senderLog[id] or {}) do
        if now - at < Justice.SENDER_WINDOW then recent[#recent + 1] = at end
    end
    senderLog[id] = recent
    if #recent >= Justice.SENDER_LIMIT then return false end
    recent[#recent + 1] = now
    return true
end

function Justice:OnPeer(record, sender)
    local outlaw, t, mapID, killer = ns.Protocol.DecodeJustice(record)
    if not outlaw then return end
    local U = ns.Utils
    -- Same key format as our reports (a sender's client may write names differently)
    if not outlaw:find("^guid:") then
        outlaw = U.PlayerKey(outlaw)
        if not outlaw then return end
    end
    local now = U.ServerTime()
    if t > now + self.MAX_SKEW or t < now - ns.Reports.MAX_AGE then return end
    if self:Get(outlaw .. ":" .. t) or not UnderRateLimit(sender) then return end
    self:Add({ id = outlaw .. ":" .. t, outlaw = outlaw, t = t, mapID = mapID,
        killer = killer and U.PlayerKey(killer) or U.PlayerKey(sender), hunter = U.PlayerKey(sender) or sender },
        "peer", sender)
end

-- A catch passed on by another HeadHunter during login catch-up (HH-023): no rate
-- limit (one pull brings many), the time checks still apply
function Justice:AddRelayed(record, sender)
    local outlaw, t, mapID, killer = ns.Protocol.DecodeJustice(record)
    if not outlaw then return nil end
    local U = ns.Utils
    if not outlaw:find("^guid:") then
        outlaw = U.PlayerKey(outlaw)
        if not outlaw then return nil end
    end
    local now = U.ServerTime()
    if t > now + self.MAX_SKEW or t < now - ns.Reports.MAX_AGE then return nil end
    return self:Add({ id = outlaw .. ":" .. t, outlaw = outlaw, t = t, mapID = mapID,
        killer = killer and U.PlayerKey(killer), hunter = killer and U.PlayerKey(killer) }, "relay", sender)
end

-- Catches to hand to a peer who missed them, newest first
function Justice:Since(since)
    local list = {}
    for _, record in self:All() do
        if record.t > since then list[#list + 1] = record end
    end
    table.sort(list, function(a, b) return a.t > b.t end)
    return list
end

-------------------------------------------------
-- Era: [Announce] to the whole realm (needs the click)
-------------------------------------------------

function Justice:PendingAnnounce()
    return #toAnnounce
end

-- Must run inside a hardware event (the popup button or a typed command)
function Justice:Announce()
    local records = {}
    for _, id in ipairs(toAnnounce) do
        local record = self:Get(id)
        if record then records[#records + 1] = self.Encode(record) end
    end
    wipe(toAnnounce)
    if #records == 0 then return 0 end
    local sent = ns.Transport:SendRealmWide(ns.Protocol.TYPES.JUSTICE, records)
    ns:Print(sent > 0 and L.JUSTICE_ANNOUNCED or L.REPORT_FAILED)
    return sent
end

function Justice:SkipAnnounce()
    wipe(toAnnounce)
end

-------------------------------------------------
-- Wiring
-------------------------------------------------

ns.Events:Register("HH_INITIALIZED", function()
    local Events = ns.Events
    Justice:Prune()
    ns.Transport:RegisterHandler(ns.Protocol.TYPES.JUSTICE, function(record, sender) Justice:OnPeer(record, sender) end)
    if ns.Features.HasCLEU then
        Events:Register("COMBAT_LOG_EVENT_UNFILTERED", function() Justice:OnCombatLog() end, OWNER)
    else
        Events:Register("UNIT_HEALTH", function(_, unit)
            if unit == "target" then Justice:CheckTarget() end
        end, OWNER)
        Events:Register("PLAYER_REGEN_ENABLED", function()
            lastCombat = ns.Utils.Now()
            Justice:CheckTarget()
        end, OWNER)
    end
end, OWNER)

-- /hh catch "<name>": debug only (HH-072 removes it). Records our catch of a WANTED
-- outlaw as if we had landed the killing blow; shared like a real one.
ns.SlashCommands:Register("catch", function(args)
    if not ns.debugMode then
        ns:Print(L.CATCH_NEEDS_DEBUG)
        return
    end
    local key = ns.Utils.PlayerKey(table.concat(args, " "))
    if not (key and Justice:OnEnemyKilled(key, nil, "sim")) then
        ns:Print(string.format(L.CATCH_NOT_WANTED, tostring(key)))
    end
end)

ns.SlashCommands:Register("justice", function()
    if #toAnnounce == 0 then
        ns:Print(L.JUSTICE_NOTHING)
        return
    end
    StaticPopup_Hide(ns.Alerts.JUSTICE_POPUP)
    Justice:Announce()
end, L.HELP_JUSTICE)
