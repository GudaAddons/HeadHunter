-- HH-044: posses. Who is hunting which WANTED outlaw.
--
-- Join (the popup button): waypoint at the last known position, we become a member,
-- and the join is sent to other HeadHunters:
--   Forever: queued on the hidden channel (posse priority)
--   Era:     sent realm-wide as channel text right away (the click is the hardware
--            event), plus queued for guild / party
-- Received joins (protocol type J, "outlawId;mapID;time", the sender is the member)
-- keep a member list per outlaw for TTL seconds. Shown in the activity popup
-- ("Posse: A, B") and by /hh posse.
-- Decline: HH_POSSE_DECLINED(entry, report), counted by marks (M5).
-- Events: HH_POSSE_JOINED(entry, report), HH_POSSE_CHANGED(outlawId).

local addonName, ns = ...
local L = ns.L

local Posse = ns:RegisterModule("Posse", {})

local OWNER = "Posse"

Posse.TTL = 1800        -- a join counts for 30 minutes
Posse.MAX_SKEW = 300
Posse.SHOWN_NAMES = 3   -- names shown in popups, then "+N"

local posses = {}        -- outlawId -> compact member -> { name, t, mapID, self }

local function Prune(outlawId, now)
    local members = posses[outlawId]
    if not members then return end
    for id, member in pairs(members) do
        if now - member.t > Posse.TTL then members[id] = nil end
    end
    if next(members) == nil then posses[outlawId] = nil end
end

local function AddMember(outlawId, name, t, mapID, isSelf, layer)
    local id = ns.Utils.CompactName(name)
    if not id then return false end
    posses[outlawId] = posses[outlawId] or {}
    local known = posses[outlawId][id]
    posses[outlawId][id] = { name = name, t = t, mapID = mapID, layer = layer,
        self = isSelf or (known and known.self) or nil }
    ns.Events:Fire("HH_POSSE_CHANGED", outlawId)
    return not known
end

-- Members of one posse: us first, then earliest first
function Posse:Members(outlawId)
    local now = ns.Utils.ServerTime()
    Prune(outlawId, now)
    local list = {}
    for _, member in pairs(posses[outlawId] or {}) do list[#list + 1] = member end
    table.sort(list, function(a, b)
        if (a.self or false) ~= (b.self or false) then return a.self == true end
        return a.t < b.t
    end)
    return list
end

function Posse:IsMember(outlawId)
    for _, member in ipairs(self:Members(outlawId)) do
        if member.self then return true end
    end
    return false
end

-- "Posse: Alpha, Bravo, Charlie +2" or nil when empty
function Posse:Summary(outlawId)
    local members = self:Members(outlawId)
    if #members == 0 then return nil end
    local names = {}
    for i = 1, math.min(#members, self.SHOWN_NAMES) do
        names[i] = members[i].self and L.POSSE_YOU or ns.Utils.DisplayName(members[i].name) or members[i].name
    end
    local text = table.concat(names, ", ")
    if #members > self.SHOWN_NAMES then text = text .. " +" .. (#members - self.SHOWN_NAMES) end
    return string.format(L.POSSE_SUMMARY, text)
end

-------------------------------------------------
-- Join / decline
-------------------------------------------------

-- The game's waypoint where the client allows it (Classic Era does not)
local function Guide(report)
    return ns.MapMarkers.Guide(report.mapID, report.x, report.y)
end

-- Runs inside the popup click (a hardware event): Era may send channel text here
local function Broadcast(outlawId, mapID, t, layer)
    local Protocol, Transport = ns.Protocol, ns.Transport
    local record = Protocol.EncodePosse(outlawId, mapID, t, layer)
    Transport:Queue(Protocol.TYPES.POSSE, record, Transport.PRIORITY.posse, "J:" .. outlawId)
    if Transport:RealmWideNeedsClick() then
        Transport:SendRealmWide(Protocol.TYPES.POSSE, { record })
    end
end

function Posse:Join(entry, report)
    local U = ns.Utils
    local name = entry.key and U.DisplayName(entry.key) or entry.name
    local zone = U.MapName(report.mapID) or L.UNKNOWN_ZONE
    local how, zx, zy = Guide(report)
    if how == "waypoint" then
        ns:Print(string.format(L.POSSE_JOINED_PIN, name, zone))
    elseif how == "coords" then
        ns:Print(string.format(L.POSSE_JOINED_COORDS, name, zone, zx * 100, zy * 100))
    else
        ns:Print(string.format(L.POSSE_JOINED, name, zone))
    end
    local now = U.ServerTime()
    local myLayer = ns.Layer:Current()
    AddMember(entry.id, U.UnitKey("player") or "me", now, U.PlayerMapID(), true, myLayer)
    Broadcast(entry.id, U.PlayerMapID(), now, myLayer)

    -- Another layer: ask the victim for a group invite (moves us to their layer).
    -- report.sender is the name the game gave us, so it is always a valid target.
    -- Runs inside the popup click, which allows sending a whisper.
    if ns.Layer:Compare(report.layer, report.mapID) == "different"
            and ns.db.settings.alerts.whisperInvite and report.sender then
        local ok = pcall(SendChatMessage, string.format(L.POSSE_WHISPER, name), "WHISPER", nil, report.sender)
        if ok then ns:Print(string.format(L.POSSE_WHISPERED, U.DisplayName(U.PlayerKey(report.sender)) or report.sender)) end
    end
    ns.Events:Fire("HH_POSSE_JOINED", entry, report)
end

-- Decline: no popup about this outlaw for DECLINE_QUIET seconds (chat lines only)
Posse.DECLINE_QUIET = 900
local declined = {}   -- outlawId -> GetTime() of the decline

function Posse:Decline(entry, report)
    declined[entry.id] = ns.Utils.Now()
    ns.Events:Fire("HH_POSSE_DECLINED", entry, report)
end

function Posse:RecentlyDeclined(outlawId)
    local at = declined[outlawId]
    return at ~= nil and ns.Utils.Now() - at < self.DECLINE_QUIET
end

-- A new kill by an outlaw we are hunting (author, 2026-09-23): the waypoint follows
-- the newest kill and our membership is refreshed (and re-announced to other
-- HeadHunters on the automatic routes).
function Posse:Refresh(entry, report)
    local U = ns.Utils
    Guide(report)
    local now = U.ServerTime()
    local myLayer = ns.Layer:Current()
    AddMember(entry.id, U.UnitKey("player") or "me", now, U.PlayerMapID(), true, myLayer)
    local Protocol, Transport = ns.Protocol, ns.Transport
    Transport:Queue(Protocol.TYPES.POSSE, Protocol.EncodePosse(entry.id, U.PlayerMapID(), now, myLayer),
        Transport.PRIORITY.posse, "J:" .. entry.id)
end

-------------------------------------------------
-- Receiving
-------------------------------------------------

function Posse:OnPeerJoin(record, sender)
    local outlawId, mapID, t, layer = ns.Protocol.DecodePosse(record)
    if not outlawId then return end
    local now = ns.Utils.ServerTime()
    if t > now + self.MAX_SKEW or now - t > self.TTL then return end
    local isNew = AddMember(outlawId, sender, t, mapID, false, layer)
    -- Only hunters in the same posse hear about new members
    if isNew and self:IsMember(outlawId) then
        local entry = ns.Wanted:Get(outlawId)
        local outlaw = entry and (entry.key and ns.Utils.DisplayName(entry.key) or entry.name) or outlawId
        ns:Print(string.format(L.POSSE_MEMBER_JOINED, ns.Utils.DisplayName(ns.Utils.PlayerKey(sender)) or sender, outlaw))
    end
end

ns.Events:Register("HH_INITIALIZED", function()
    ns.Transport:RegisterHandler(ns.Protocol.TYPES.POSSE, function(record, sender) Posse:OnPeerJoin(record, sender) end)
end, OWNER)

ns.SlashCommands:Register("posse", function()
    local now = ns.Utils.ServerTime()
    local any = false
    for outlawId in pairs(posses) do
        Prune(outlawId, now)
    end
    for outlawId in pairs(posses) do
        any = true
        local entry = ns.Wanted:Get(outlawId)
        local outlaw = entry and (entry.key and ns.Utils.DisplayName(entry.key) or entry.name) or outlawId
        ns:Print(string.format("|cffff4040%s|r · %s", outlaw, Posse:Summary(outlawId) or ""))
        for _, member in ipairs(Posse:Members(outlawId)) do
            print(string.format("  %s  %s  %s", member.self and L.POSSE_YOU or ns.Utils.DisplayName(member.name) or member.name,
                ns.Utils.MapName(member.mapID) or "?",
                member.layer and string.format(L.LAYER_TAG, member.layer) or ""))
        end
    end
    if not any then ns:Print(L.POSSE_NONE) end
end, L.HELP_POSSE)
