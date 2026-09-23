-- HH-101: Gurubashi Tournament model and protocol (docs/addon/features.md section 11).
--
-- The organizer's client is the authority: it holds the tournament, accepts or refuses
-- join requests and changes the state. Everyone else keeps a copy from its broadcasts.
--
-- States: scheduled -> checkin (at the start time, by the organizer's client) ->
-- running -> finished; cancelled from any of the first three. Forward only.
--
-- Messages (protocol type V; records start with a kind letter):
--   A  announce   id;organizer;name;format;bracket;bestOf;start;minLevel;maxTeams;state;version;venue
--   E  entrant    id;version;teamId;member,+member...    (one per team, same version as A;
--                                                          "+" = checked in)
--   R  request    id;action(j|l);teamId;member:level,...  (addon whisper to the organizer)
--   C  check-in   id                                      (addon whisper: "I'm here", HH-104)
--   X  reply      id;code                                 (addon whisper back)
--   H  heartbeat  id                                      (registered players, every minute)
-- The organizer broadcasts A + E on the automatic routes (Forever: hidden channel; Era:
-- guild and group), realm-wide on Era only from a click or typed command. Requests,
-- replies and heartbeats are whispers: automatic on both clients (same faction).
-- Heartbeats keep players up to date on Era and show whether the organizer is still
-- there: nothing heard for ORGANIZER_TIMEOUT once it should have started = cancelled.
--
-- Teams: 1v1 is a player; 2v2+ is a premade party, registered by its leader (team id =
-- the leader). Fires HH_TOURNAMENT_UPDATED(id).
--
-- Venues (Tournament/Arena.lua): Gurubashi Arena (default, the arena chest rule) or the
-- organizer's faction's dueling spots outside the capitals. Tournaments are for the
-- organizer's faction: other-faction messages are dropped (HH-100 decides the rest).
--
-- HH-104: reminders 30 and 5 min before the start (registered players: center text,
-- chat, sound; players who could join: one chat line). Check-in: at the start the
-- organizer's client moves to checkin; registered players click "I'm here" at the
-- venue within CHECKIN_WINDOW. A team counts only when all its members are
-- in. Then (or as soon as everyone is in) the teams that are in go on and the state is
-- running; fewer than 2 teams = cancelled. Every client builds the same bracket from
-- the teams that are in (Tournaments:Bracket, seeded with the start time).

local addonName, ns = ...
local L = ns.L

local Tournaments = ns:RegisterModule("Tournaments", {})

local OWNER = "Tournaments"

Tournaments.FORMATS = { [1] = true, [2] = true, [3] = true, [5] = true }
Tournaments.BEST_OF = { [1] = true, [3] = true, [5] = true }
Tournaments.MAX_TEAMS = 32
Tournaments.ROBIN_MAX_TEAMS = 8        -- everyone meets everyone: keep it short
Tournaments.MIN_LEAD = 60              -- the start is at least a minute ahead
Tournaments.MAX_LEAD = 7 * 86400
Tournaments.MAX_NAME = 30
Tournaments.MIN_LEVEL = 19             -- tournaments start at level 19 (author, 2026-09-23)
Tournaments.ORGANIZER_TIMEOUT = 300    -- author: gone for 5 minutes = cancelled
Tournaments.HEARTBEAT = 60
Tournaments.HEARTBEAT_BEFORE = 600     -- players start pinging 10 min before the start
Tournaments.REPLY_LIMIT = 20           -- the organizer answers a heartbeat at most every 20 s per player
Tournaments.TICK = 5
Tournaments.KEEP = 7 * 86400           -- finished or cancelled ones stay listed a week
Tournaments.REMINDERS = { 5, 30 }      -- minutes before the start, smallest first
Tournaments.CHECKIN_WINDOW = 600       -- 10 minutes to click "I'm here"

local ORDER = { scheduled = 1, checkin = 2, running = 3, finished = 4, cancelled = 5 }
local STATE_CODE = { scheduled = "s", checkin = "c", running = "r", finished = "f", cancelled = "x" }
local STATE_NAME = {}
for name, code in pairs(STATE_CODE) do STATE_NAME[code] = name end
Tournaments.ORDER = ORDER

local lastBeat = {}      -- id -> Now() of our last heartbeat (player) or re-announce (organizer)
local lastReply = {}     -- sender -> Now() of our last heartbeat answer (organizer)
local pending = {}       -- id -> true while our join or leave request waits for a reply

local function Store()
    return ns.db and ns.db.tournaments
end

local function Me()
    return ns.Utils.UnitKey("player")
end

local function IsMine(t)
    return t ~= nil and ns.Utils.SameCharacter(t.organizer, Me())
end

local function Final(state)
    return state == "finished" or state == "cancelled"
end

-------------------------------------------------
-- Encoding (pure)
-------------------------------------------------

local P = ns.Protocol

-- Free text for a field: no separators, trimmed, at most max characters
function Tournaments.Clean(s, max)
    s = tostring(s or ""):gsub("[;~,:|]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return s:sub(1, max or Tournaments.MAX_NAME)
end

function Tournaments.EncodeAnnounce(t)
    return "A" .. table.concat({ t.id, t.organizer, t.name, t.format, t.bracket == "robin" and "r" or "s",
        t.bestOf, P.ToB36(t.start), t.minLevel, t.maxTeams, STATE_CODE[t.state], t.version,
        t.venue or ns.Arena.DEFAULT_VENUE }, ";")
end

function Tournaments.DecodeAnnounce(body)
    local f = P.Split(body, ";")
    if #f ~= 12 or f[1] == "" or f[2] == "" or not ns.Arena.VENUE[f[12]] then return nil end
    local t = {
        id = f[1], organizer = f[2], name = Tournaments.Clean(f[3]), format = tonumber(f[4]),
        bracket = f[5] == "r" and "robin" or "single", bestOf = tonumber(f[6]), start = P.FromB36(f[7]),
        minLevel = tonumber(f[8]), maxTeams = tonumber(f[9]), state = STATE_NAME[f[10]], version = tonumber(f[11]),
        venue = f[12],
    }
    if not (Tournaments.FORMATS[t.format] and Tournaments.BEST_OF[t.bestOf] and t.start and t.minLevel
        and t.maxTeams and t.state and t.version) then return nil end
    return t
end

function Tournaments.EncodeEntrant(t, team)
    local members = {}
    for i, member in ipairs(team.members) do
        members[i] = (team.here and team.here[member] and "+" or "") .. member
    end
    return "E" .. table.concat({ t.id, t.version, team.id, table.concat(members, ",") }, ";")
end

function Tournaments.DecodeEntrant(body)
    local f = P.Split(body, ";")
    if #f ~= 4 or f[3] == "" or f[4] == "" then return nil end
    local team = { id = f[3], members = {}, here = {} }
    for _, item in ipairs(P.Split(f[4], ",")) do
        local member = item:gsub("^%+", "")
        team.members[#team.members + 1] = member
        if member ~= item then team.here[member] = true end
    end
    return f[1], tonumber(f[2]), team
end

-- members: array of { key, level }
function Tournaments.EncodeRequest(id, action, teamId, members)
    local list = {}
    for i, m in ipairs(members or {}) do list[i] = m.key .. ":" .. (m.level or 0) end
    return "R" .. table.concat({ id, action, teamId, table.concat(list, ",") }, ";")
end

function Tournaments.DecodeRequest(body)
    local f = P.Split(body, ";")
    if #f ~= 4 or (f[2] ~= "j" and f[2] ~= "l") or f[3] == "" then return nil end
    local members = {}
    if f[4] ~= "" then
        for _, item in ipairs(P.Split(f[4], ",")) do
            local key, level = item:match("^(.+):(%d+)$")
            if not key then return nil end
            members[#members + 1] = { key = key, level = tonumber(level) }
        end
    end
    return f[1], f[2], f[3], members
end

-------------------------------------------------
-- Store and queries
-------------------------------------------------

-- "Gurubashi Arena (Stranglethorn Vale)", "the Orgrimmar gate (Durotar)" ...
function Tournaments.Where(t)
    return ns.Arena.VenueName(t.venue or ns.Arena.DEFAULT_VENUE)
end

function Tournaments:Get(id)
    local store = Store()
    return store and id and store[id]
end

-- Every tournament we know, soonest first
function Tournaments:List()
    local list = {}
    for _, t in pairs(Store() or {}) do list[#list + 1] = t end
    table.sort(list, function(a, b)
        if a.start ~= b.start then return a.start < b.start end
        return a.id < b.id
    end)
    return list
end

local function TeamOf(t, key)
    for _, teamId in ipairs(t.order or {}) do
        local team = t.entrants[teamId]
        for _, member in ipairs(team and team.members or {}) do
            if ns.Utils.SameCharacter(member, key) then return team end
        end
    end
    return nil
end
Tournaments.TeamOf = TeamOf

function Tournaments:IsRegistered(t, key)
    return TeamOf(t, key or Me()) ~= nil
end

function Tournaments:TeamCount(t)
    return #(t.order or {})
end

local function Changed(t)
    ns.Events:Fire("HH_TOURNAMENT_UPDATED", t.id)
end

-------------------------------------------------
-- Organizer
-------------------------------------------------

local function Records(t)
    local records = { Tournaments.EncodeAnnounce(t) }
    for _, teamId in ipairs(t.order) do records[#records + 1] = Tournaments.EncodeEntrant(t, t.entrants[teamId]) end
    return records
end

-- The automatic routes; realm-wide too when this comes from a click on Era
function Tournaments:Broadcast(t, click)
    local Transport = ns.Transport
    local V = P.TYPES.TOURNAMENT
    Transport:Queue(V, Tournaments.EncodeAnnounce(t), Transport.PRIORITY.posse, "V:A:" .. t.id)
    for _, teamId in ipairs(t.order) do
        Transport:Queue(V, Tournaments.EncodeEntrant(t, t.entrants[teamId]), Transport.PRIORITY.posse,
            "V:E:" .. t.id .. ":" .. teamId)
    end
    if click and Transport:RealmWideNeedsClick() then Transport:SendRealmWide(V, Records(t)) end
    lastBeat[t.id] = ns.Utils.Now()
end

-- opts: name, format, bracket, bestOf, start (server time), minLevel, maxTeams.
-- Returns the tournament, or nil and a reason key (L.TOUR_ERR_*).
function Tournaments:Create(opts, click)
    local U = ns.Utils
    local store = Store()
    local me = Me()
    if not store or not me then return nil, "NOT_READY" end
    if not self:CanHost() then return nil, "ORGANIZER_LEVEL" end
    local name = Tournaments.Clean(opts.name)
    if name == "" then return nil, "NAME" end
    if not Tournaments.FORMATS[opts.format] then return nil, "FORMAT" end
    local bracket = opts.bracket or "single"
    if bracket ~= "single" and bracket ~= "robin" then return nil, "BRACKET" end
    local bestOf = opts.bestOf or 1
    if not Tournaments.BEST_OF[bestOf] then return nil, "BEST_OF" end
    local now = U.ServerTime()
    local start = tonumber(opts.start)
    if not start or start < now + self.MIN_LEAD or start > now + self.MAX_LEAD then return nil, "START" end
    local venue = opts.venue or ns.Arena.DEFAULT_VENUE
    if not ns.Arena.VenueAllowed(venue, U.UnitFaction("player")) then return nil, "VENUE" end
    if ns.Arena.VENUE[venue].chest and not ns.Arena.StartClearOfChest(start, now) then return nil, "CHEST" end
    local minLevel = math.floor(tonumber(opts.minLevel) or self.MIN_LEVEL)
    if minLevel < self.MIN_LEVEL or minLevel > 60 then return nil, "LEVEL" end
    local cap = bracket == "robin" and self.ROBIN_MAX_TEAMS or self.MAX_TEAMS
    local maxTeams = math.floor(tonumber(opts.maxTeams) or cap)
    if maxTeams < 2 or maxTeams > cap then return nil, "TEAMS" end
    for _, t in pairs(store) do
        if IsMine(t) and not Final(t.state) then return nil, "ALREADY" end
    end
    local t = {
        id = me .. "#" .. P.ToB36(now), organizer = me, name = name, format = opts.format, bracket = bracket,
        bestOf = bestOf, start = start, minLevel = minLevel, maxTeams = maxTeams, state = "scheduled", version = 1,
        venue = venue, faction = U.UnitFaction("player"), entrants = {}, order = {}, heard = U.Now(),
    }
    store[t.id] = t
    self:Broadcast(t, click)
    Changed(t)
    return t
end

-- Organizer only, forward only (cancel from any open state)
function Tournaments:SetState(id, state, click)
    local t = self:Get(id)
    if not IsMine(t) or not ORDER[state] or Final(t.state) then return false end
    if state ~= "cancelled" and ORDER[state] <= ORDER[t.state] then return false end
    t.state = state
    t.version = t.version + 1
    self:Broadcast(t, click)
    Changed(t)
    return true
end

-- A join or leave request, on the organizer's client. Returns the reply code.
function Tournaments:HandleRequest(t, action, teamId, members, sender)
    local U = ns.Utils
    if not U.SameCharacter(teamId, sender) then return "leader" end
    if action == "l" then
        if not t.entrants[teamId] then return "left" end
        if t.state ~= "scheduled" then return "closed" end
        t.entrants[teamId] = nil
        for i, id in ipairs(t.order) do
            if id == teamId then table.remove(t.order, i) break end
        end
        t.version = t.version + 1
        self:Broadcast(t)
        Changed(t)
        return "left"
    end
    if t.state ~= "scheduled" then return "closed" end
    if #members ~= t.format then return "format" end
    local keys = {}
    for _, m in ipairs(members) do
        if (m.level or 0) < t.minLevel then return "level" end
        local other = TeamOf(t, m.key)
        if other and other.id ~= teamId then return "dupe" end
        keys[#keys + 1] = m.key
    end
    if not U.SameCharacter(keys[1], teamId) then return "leader" end
    if not t.entrants[teamId] then
        if #t.order >= t.maxTeams then return "full" end
        t.order[#t.order + 1] = teamId
    end
    t.entrants[teamId] = { id = teamId, members = keys }
    t.version = t.version + 1
    self:Broadcast(t)
    Changed(t)
    return "ok"
end

-- "I'm here" from a registered player, on the organizer's client. Returns the reply code.
function Tournaments:HandleCheckIn(t, sender)
    if t.state ~= "checkin" then return "closed" end
    local team = TeamOf(t, sender)
    if not team then return "notin" end
    team.here = team.here or {}
    for _, member in ipairs(team.members) do
        if ns.Utils.SameCharacter(member, sender) then team.here[member] = true end
    end
    t.version = t.version + 1
    self:Broadcast(t)
    Changed(t)
    return "here"
end

-- A team is in when every member checked in
function Tournaments.TeamIsIn(team)
    for _, member in ipairs(team.members) do
        if not (team.here and team.here[member]) then return false end
    end
    return true
end

-- End of check-in (organizer): the teams that are in go on; fewer than 2 = cancelled
function Tournaments:FinishCheckIn(t)
    local kept = {}
    for _, teamId in ipairs(t.order) do
        if Tournaments.TeamIsIn(t.entrants[teamId]) then
            kept[#kept + 1] = teamId
        else
            t.entrants[teamId] = nil
        end
    end
    t.order = kept
    if #kept < 2 then
        t.cancelReason = "players"
        ns:Print(string.format(L.TOUR_CHECKIN_TOO_FEW, t.name))
        return self:SetState(t.id, "cancelled")
    end
    t.tree = nil
    ns:Print(string.format(L.TOUR_CHECKIN_DONE, t.name, #kept))
    return self:SetState(t.id, "running")
end

-- The bracket of a running tournament: the same on every client, built from the teams
-- that checked in (in the order the organizer sent them) and seeded with the start time.
-- Ranking points for the seeding come with HH-107. Kept in t.tree (t.bracket is the
-- kind: "single" or "robin"); rebuilt when a new version arrives.
function Tournaments:Bracket(t)
    if not t or (t.state ~= "running" and t.state ~= "finished") then return nil end
    if not t.tree or t.treeVersion ~= t.version or t.treeTeams ~= #t.order then
        local B = ns.Brackets
        local seeds = B.Seed(t.order, nil, t.start)
        if t.bracket == "robin" then
            t.tree = B.RoundRobin(seeds, t.bestOf)
        else
            t.tree = B.SingleElimination(seeds, t.bestOf)
        end
        t.treeVersion, t.treeTeams = t.version, #t.order
    end
    return t.tree
end

-------------------------------------------------
-- Players
-------------------------------------------------

-- Us, and for 2v2+ our party: { { key, level } ... }, or nil and a reason key
function Tournaments:OurTeam(t)
    local U = ns.Utils
    local members = { { key = Me(), level = U.UnitLevel("player") } }
    if t.format > 1 then
        if _G.UnitIsGroupLeader and not U.SafeCall(_G.UnitIsGroupLeader, "player") then return nil, "NOT_LEADER" end
        for i = 1, 4 do
            local unit = "party" .. i
            if U.UnitIsPlayer(unit) then
                members[#members + 1] = { key = U.UnitKey(unit), level = U.UnitLevel(unit) }
            end
        end
        if #members ~= t.format then return nil, "PARTY_SIZE" end
    end
    for _, m in ipairs(members) do
        if not m.key then return nil, "NOT_READY" end
        if (m.level or 0) < t.minLevel then return nil, "LEVEL_LOW" end
    end
    return members
end

local function Ask(t, action, members)
    local me = Me()
    if IsMine(t) then
        return Tournaments:OnReply(t.id, Tournaments:HandleRequest(t, action, me, members or {}, me))
    end
    pending[t.id] = true
    ns.Transport:SendDirect(P.TYPES.TOURNAMENT, { Tournaments.EncodeRequest(t.id, action, me, members) }, t.organizer)
    return "sent"
end

-- Returns "sent", a reply code (our own tournament) or nil and a reason key
function Tournaments:Join(id)
    local t = self:Get(id)
    if not t then return nil, "UNKNOWN" end
    if t.state ~= "scheduled" then return nil, "CLOSED" end
    local members, reason = self:OurTeam(t)
    if not members then return nil, reason end
    return Ask(t, "j", members)
end

function Tournaments:Leave(id)
    local t = self:Get(id)
    if not t then return nil, "UNKNOWN" end
    return Ask(t, "l", {})
end

-- Did `key` (default: us) click "I'm here"?
function Tournaments:IsHere(t, key)
    key = key or Me()
    local team = TeamOf(t, key)
    if not (team and team.here) then return false end
    for member in pairs(team.here) do
        if ns.Utils.SameCharacter(member, key) then return true end
    end
    return false
end

-- "I'm here": only inside Gurubashi Arena, during check-in, when registered.
-- Returns "sent", "here" (our own tournament) or nil and a reason key.
function Tournaments:CheckIn(id)
    local t = self:Get(id)
    if not t then return nil, "UNKNOWN" end
    if t.state ~= "checkin" then return nil, "NOT_CHECKIN" end
    if not self:IsRegistered(t) then return nil, "NOT_REGISTERED" end
    if not ns.Arena:PlayerAt(t.venue) then return nil, "NOT_AT_VENUE" end
    if IsMine(t) then return self:OnReply(t.id, self:HandleCheckIn(t, Me())) end
    pending[t.id] = true
    ns.Transport:SendDirect(P.TYPES.TOURNAMENT, { "C" .. t.id }, t.organizer)
    return "sent"
end

-- What we can do with a tournament: "joined", "open", or why not: "full", "level",
-- "party", "leader". During check-in: "checkin_me" (we must click I'm here), "here",
-- or "checkin" (not ours). Later: the state.
function Tournaments:JoinStatus(t)
    if t.state == "checkin" and self:IsRegistered(t) then
        return self:IsHere(t) and "here" or "checkin_me"
    end
    if t.state ~= "scheduled" then return t.state end
    if self:IsRegistered(t) then return "joined" end
    if #t.order >= t.maxTeams then return "full" end
    local members, reason = self:OurTeam(t)
    if not members then
        return ({ LEVEL_LOW = "level", PARTY_SIZE = "party", NOT_LEADER = "leader" })[reason] or "open"
    end
    return "open"
end

-- Hosting starts at MIN_LEVEL (joining is checked against each tournament's minimum)
function Tournaments:CanHost()
    return (ns.Utils.UnitLevel("player") or 0) >= self.MIN_LEVEL
end

function Tournaments:IsOrganizer(t)
    return IsMine(t)
end

-- Player actions with their chat feedback (the Tournaments tab and /hh tour)
local function Fail(reason)
    ns:Print(L["TOUR_ERR_" .. tostring(reason)] or tostring(reason))
end

function Tournaments:DoJoin(id, leave)
    local t = self:Get(id)
    local result, reason
    if leave then result, reason = self:Leave(id) else result, reason = self:Join(id) end
    if not result then return Fail(reason) end
    if result == "sent" and t then ns:Print(string.format(L.TOUR_REQUEST_SENT, t.name)) end
    return result
end

function Tournaments:DoCheckIn(id)
    local t = self:Get(id)
    local result, reason = self:CheckIn(id)
    if not result then return Fail(reason) end
    if result == "sent" and t then ns:Print(string.format(L.TOUR_CHECKIN_SENT, t.name)) end
    return result
end

function Tournaments:DoCancel(id)
    local t = self:Get(id)
    if not (t and self:SetState(id, "cancelled", true)) then return ns:Print(L.TOUR_NONE_OWN) end
    ns:Print(string.format(L.TOUR_CANCELLED, t.name))
    return true
end

function Tournaments:OnReply(id, code)
    pending[id] = nil
    local t = self:Get(id)
    local text = L["TOUR_REPLY_" .. tostring(code):upper()]
    if t and text then ns:Print(string.format(text, t.name)) end
    return code
end

-------------------------------------------------
-- Receiving
-------------------------------------------------

function Tournaments:OnAnnounce(a, sender, faction)
    local U = ns.Utils
    if not U.SameCharacter(sender, a.organizer) then return nil end
    local t = self:Get(a.id)
    if IsMine(t) then return nil end -- we are the authority
    if t and a.version < t.version then return nil end
    local store = Store()
    if not store then return nil end
    if not t or a.version > t.version then
        -- Tell our players when check-in ends: the matches begin, or it is off
        local wasRegistered = t and self:IsRegistered(t)
        if wasRegistered and a.state ~= t.state and (a.state == "running" or a.state == "cancelled") then
            ns:Print(string.format(a.state == "running" and L.TOUR_RUNNING_NOTICE or L.TOUR_CANCELLED_NOTICE, t.name))
        end
        -- A new version: its entrants follow as E records
        t = t or {}
        for k, v in pairs(a) do t[k] = v end
        t.entrants, t.order = {}, {}
        t.faction = faction or t.faction
        store[t.id] = t
    end
    t.heard = U.Now()
    Changed(t)
    return t
end

function Tournaments:OnEntrant(id, version, team, sender)
    local t = self:Get(id)
    if not t or IsMine(t) or version ~= t.version or not ns.Utils.SameCharacter(sender, t.organizer) then return nil end
    if not t.entrants[team.id] then t.order[#t.order + 1] = team.id end
    t.entrants[team.id] = team
    Changed(t)
    return team
end

function Tournaments:OnRecord(record, sender, faction)
    local kind, body = record:sub(1, 1), record:sub(2)
    if kind == "A" then
        local a = Tournaments.DecodeAnnounce(body)
        return a and self:OnAnnounce(a, sender, faction)
    elseif kind == "E" then
        local id, version, team = Tournaments.DecodeEntrant(body)
        return id and self:OnEntrant(id, version, team, sender)
    elseif kind == "R" then
        local id, action, teamId, members = Tournaments.DecodeRequest(body)
        local t = id and self:Get(id)
        if not IsMine(t) then return nil end
        local code = self:HandleRequest(t, action, teamId, members, sender)
        ns.Transport:SendDirect(P.TYPES.TOURNAMENT, { "X" .. t.id .. ";" .. code }, sender)
        return code
    elseif kind == "C" then
        local t = self:Get(body)
        if not IsMine(t) then return nil end
        local code = self:HandleCheckIn(t, sender)
        ns.Transport:SendDirect(P.TYPES.TOURNAMENT, { "X" .. t.id .. ";" .. code }, sender)
        return code
    elseif kind == "X" then
        local f = P.Split(body, ";")
        if #f == 2 and pending[f[1]] then return self:OnReply(f[1], f[2]) end
    elseif kind == "H" then
        local t = self:Get(body)
        if not IsMine(t) then return nil end
        local now, who = ns.Utils.Now(), ns.Utils.CompactName(sender) or sender
        if lastReply[who] and now - lastReply[who] < self.REPLY_LIMIT then return nil end
        lastReply[who] = now
        ns.Transport:SendDirect(P.TYPES.TOURNAMENT, Records(t), sender)
        return true
    end
    return nil
end

-------------------------------------------------
-- Reminders and the check-in call (HH-104), on every client
-------------------------------------------------

function Tournaments:Remind(t, now)
    if t.state ~= "scheduled" or now >= t.start then return end
    t.reminded = t.reminded or {}
    local left = t.start - now
    for _, minutes in ipairs(self.REMINDERS) do
        if left <= minutes * 60 then
            if t.reminded[minutes] then return end
            -- Only the latest one when we are late (logged in 3 min before: just the 5)
            for _, m in ipairs(self.REMINDERS) do
                if m >= minutes then t.reminded[m] = true end
            end
            local minutesLeft = math.ceil(left / 60)
            if self:IsRegistered(t) then
                ns.Alerts:Show({ key = "tour:" .. t.id .. ":" .. minutes, sound = true,
                    text = string.format(L.TOUR_REMIND_CENTER, t.name, minutesLeft),
                    chat = string.format(L.TOUR_REMIND_CHAT, t.name, minutesLeft, Tournaments.Where(t)) })
            elseif minutes == self.REMINDERS[#self.REMINDERS] and self:JoinStatus(t) == "open" then
                ns:Print(string.format(L.TOUR_REMIND_OPEN, t.name, minutesLeft))
            end
            return
        end
    end
end

-- Check-in has started and we still have to click "I'm here"
function Tournaments:CallCheckIn(t)
    if t.state ~= "checkin" or t.checkinCalled or not self:IsRegistered(t) or self:IsHere(t) then return end
    t.checkinCalled = true
    local id = t.id
    ns.Alerts:Show({ key = "tour:" .. id .. ":checkin", sound = true,
        text = string.format(L.TOUR_CHECKIN_CENTER, t.name, Tournaments.Where(t)),
        chat = string.format(L.TOUR_CHECKIN_CHAT, t.name, Tournaments.Where(t), self.CHECKIN_WINDOW / 60),
        popup = { dialog = ns.Alerts.TOUR_POPUP, text = string.format(L.TOUR_CHECKIN_POPUP, t.name, Tournaments.Where(t)),
            accept = L.TOUR_BUTTON_HERE, decline = L.TOUR_BUTTON_LATER,
            onAccept = function() Tournaments:DoCheckIn(id) end } })
end

-- All teams fully checked in: no need to wait for the end of the window
local function EveryoneIn(t)
    if #t.order == 0 then return false end
    for _, teamId in ipairs(t.order) do
        if not Tournaments.TeamIsIn(t.entrants[teamId]) then return false end
    end
    return true
end

-------------------------------------------------
-- Clock: start, check-in, heartbeats, organizer gone, pruning
-------------------------------------------------

function Tournaments:Tick()
    local U = ns.Utils
    local store = Store()
    if not store then return end
    local now, clock = U.ServerTime(), U.Now()
    for id, t in pairs(store) do
        if not Final(t.state) then
            self:Remind(t, now)
            self:CallCheckIn(t)
        end
        if Final(t.state) then
            if now - t.start > self.KEEP then store[id] = nil end
        elseif IsMine(t) then
            if t.state == "scheduled" and now >= t.start then
                self:SetState(id, "checkin")
                self:CallCheckIn(t)
            elseif t.state == "checkin" and (now >= t.start + self.CHECKIN_WINDOW or EveryoneIn(t)) then
                self:FinishCheckIn(t)
            elseif t.state ~= "scheduled" and clock - (lastBeat[id] or 0) >= self.HEARTBEAT then
                self:Broadcast(t)
            end
        else
            local registered = self:IsRegistered(t)
            if registered and now >= t.start - self.HEARTBEAT_BEFORE
                    and clock - (lastBeat[id] or 0) >= self.HEARTBEAT then
                lastBeat[id] = clock
                ns.Transport:SendDirect(P.TYPES.TOURNAMENT, { "H" .. id }, t.organizer)
            end
            t.heard = t.heard or clock
            local shouldRun = t.state ~= "scheduled" or now >= t.start + self.ORGANIZER_TIMEOUT
            if shouldRun and clock - t.heard > self.ORGANIZER_TIMEOUT then
                t.state, t.cancelReason = "cancelled", "organizer"
                if registered then ns:Print(string.format(L.TOUR_ORGANIZER_GONE, t.name)) end
                Changed(t)
            end
        end
    end
end

local function Loop()
    local ok, err = pcall(Tournaments.Tick, Tournaments)
    if not ok then ns:Error(err) end
    C_Timer.After(Tournaments.TICK, Loop)
end

ns.Events:Register("HH_INITIALIZED", function()
    local store = Store()
    local now = ns.Utils.Now()
    for _, t in pairs(store or {}) do t.heard = now end -- a /reload is not the organizer leaving
    ns.Transport:RegisterHandler(P.TYPES.TOURNAMENT, function(record, sender, faction)
        Tournaments:OnRecord(record, sender, faction)
    end)
    C_Timer.After(Tournaments.TICK, Loop)
end, OWNER)

-------------------------------------------------
-- /hh tour (the Tournaments tab comes with HH-103)
-------------------------------------------------

local function Describe(t, index)
    local U = ns.Utils
    local now = U.ServerTime()
    local when = t.start > now and string.format(L.TOUR_STARTS_IN, math.ceil((t.start - now) / 60))
        or string.format(L.TOUR_STARTED, U.Ago(now - t.start))
    local mark = Tournaments:IsRegistered(t) and L.TOUR_JOINED_MARK or ""
    return string.format(L.TOUR_LINE, index, t.name, t.format, t.format, L["TOUR_BRACKET_" .. t.bracket:upper()],
        t.bestOf, when, t.minLevel, #t.order, t.maxTeams, U.DisplayName(t.organizer) or t.organizer,
        L["TOUR_STATE_" .. t.state:upper()], mark)
end

local function ByIndex(arg)
    local list = Tournaments:List()
    return list[tonumber(arg or "")]
end

ns.SlashCommands:Register("tour", function(args)
    local sub = args[1] and args[1]:lower() or "list"
    if sub == "create" then
        -- /hh tour create "Name" 2v2 single|robin bo1|bo3|bo5 <minutes> <minLevel> [maxTeams]
        local format = tonumber((args[3] or ""):match("^(%d)v%d$"))
        local bestOf = tonumber((args[5] or ""):match("^bo(%d)$"))
        local minutes = tonumber(args[6] or "")
        if not (args[2] and format and bestOf and minutes) then
            ns:Print(L.TOUR_CREATE_USAGE)
            return
        end
        local t, reason = Tournaments:Create({ name = args[2], format = format, bracket = (args[4] or ""):lower(),
            bestOf = bestOf, start = ns.Utils.ServerTime() + math.floor(minutes * 60),
            minLevel = tonumber(args[7] or "1"), maxTeams = tonumber(args[8] or "") }, true)
        if not t then return ns:Print(L["TOUR_ERR_" .. tostring(reason)] or tostring(reason)) end
        ns:Print(string.format(L.TOUR_CREATED, t.name))
        return
    end
    if sub == "join" or sub == "leave" then
        local t = ByIndex(args[2])
        if not t then return ns:Print(L.TOUR_PICK) end
        Tournaments:DoJoin(t.id, sub == "leave")
        return
    end
    if sub == "here" then
        for _, t in ipairs(Tournaments:List()) do
            if Tournaments:JoinStatus(t) == "checkin_me" then return Tournaments:DoCheckIn(t.id) end
        end
        return ns:Print(L.TOUR_ERR_NOT_CHECKIN)
    end
    if sub == "cancel" then
        for _, t in ipairs(Tournaments:List()) do
            if IsMine(t) and not Final(t.state) then return Tournaments:DoCancel(t.id) end
        end
        return ns:Print(L.TOUR_NONE_OWN)
    end
    local list = Tournaments:List()
    ns:Print(string.format(L.TOUR_HEADER, #list))
    for i, t in ipairs(list) do print(Describe(t, i)) end
    local toChest = ns.Arena.MinutesToChest()
    if toChest then print(string.format(L.TOUR_NEXT_CHEST, toChest, ns.Arena.RealmClock(toChest))) end
end, L.HELP_TOUR)
