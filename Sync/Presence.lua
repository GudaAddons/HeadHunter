-- HH-110: how many HeadHunters are online. Each addon says "here" (its version) at login
-- and every INTERVAL seconds through the normal outbox; everyone counts the players heard from
-- within WINDOW, per faction, plus themselves.
--   Forever: the hidden channel reaches the whole region, both factions.
--   Era:     addon messages only reach the guild and group (custom channels refuse
--            them), so the count says "in your guild and group".
-- A newcomer's first "here" gets one early answer (throttled), so they see the count
-- within a minute instead of an interval. With many online only about ANSWER_TARGET
-- of us answer (HH-116): the rest reach the newcomer with their next repeat.
--
--   Presence:Count() -> { total, Alliance, Horde, scope = "region" | "group" }
-- Fires HH_PRESENCE_UPDATED when the count changes.

local addonName, ns = ...
local L = ns.L

local Presence = ns:RegisterModule("Presence", {})

local OWNER = "Presence"

-- Logging out cannot send anything reliably, so a slow repeat is what lets players who
-- left drop out and keeps those who stay counted.
Presence.INTERVAL = 600      -- seconds between our announcements
Presence.WINDOW = 1500       -- heard within this long counts as online
Presence.FIRST_DELAY = 30    -- after login, once the channel is joined
Presence.ANSWER_DELAY = 20   -- early answer to a newcomer, coalesced
Presence.ANSWER_COOLDOWN = 120
Presence.ANSWER_TARGET = 5   -- about this many answer a newcomer, however many are online

local seen = {}              -- compact name -> { t, faction, version }
local lastAnswer = -math.huge
local lastTotal

local function Announce()
    ns.Transport:Queue(ns.Protocol.TYPES.PRESENCE, ns.version, ns.Transport.PRIORITY.bulk, "presence")
end

local function Prune(now)
    for name, peer in pairs(seen) do
        if now - peer.t > Presence.WINDOW then seen[name] = nil end
    end
end

function Presence:Count()
    local now = ns.Utils.Now()
    Prune(now)
    local count = { total = 0, Alliance = 0, Horde = 0 }
    local mine = ns.Utils.UnitFaction("player")
    if mine and count[mine] then
        count[mine] = 1
        count.total = 1
    end
    for _, peer in pairs(seen) do
        if count[peer.faction] then
            count[peer.faction] = count[peer.faction] + 1
            count.total = count.total + 1
        end
    end
    count.scope = ns.Transport:RealmWideNeedsClick() and "group" or "region"
    return count
end

local function Changed()
    local total = Presence:Count().total
    if total ~= lastTotal then
        lastTotal = total
        ns.Events:Fire("HH_PRESENCE_UPDATED")
    end
end

-- The share of us that answers a newcomer: 1 while few are online
function Presence.AnswerChance(online)
    return math.min(1, Presence.ANSWER_TARGET / math.max(1, (online or 1) - 1))
end

-- Called by Transport for every message received (version only from presence ones)
function Presence:Heard(sender, faction, version)
    local name = ns.Utils.CompactName(sender)
    if not name or (faction ~= "Alliance" and faction ~= "Horde") then return end
    local now = ns.Utils.Now()
    local before = seen[name]
    local isNew = not before or now - before.t > self.WINDOW
    seen[name] = {
        t = now,
        faction = faction,
        version = version and tostring(version):sub(1, 16) or (before and before.version) or "?",
    }
    if isNew and now - lastAnswer >= self.ANSWER_COOLDOWN
        and math.random() < Presence.AnswerChance(self:Count().total) then
        lastAnswer = now
        C_Timer.After(self.ANSWER_DELAY, Announce)
    end
    Changed()
end

-- Versions heard (for /hh online): version -> players
function Presence:Versions()
    local versions = { [ns.version] = 1 }
    for _, peer in pairs(seen) do
        versions[peer.version] = (versions[peer.version] or 0) + 1
    end
    return versions
end

-- The repeat is skipped when we broadcast anything else within the interval: the
-- others heard from us already (Transport.lastBroadcastAt).
function Presence.RepeatNeeded(now)
    local last = ns.Transport.lastBroadcastAt
    return not last or now - last >= Presence.INTERVAL
end

local function Loop()
    C_Timer.After(Presence.INTERVAL, function()
        if Presence.RepeatNeeded(ns.Utils.Now()) then Announce() end
        Changed()
        Loop()
    end)
end

ns.Events:Register("HH_INITIALIZED", function()
    -- Presence records need no handler of their own: Transport reports every sender
    ns.Transport:RegisterHandler(ns.Protocol.TYPES.PRESENCE, function() end)
    C_Timer.After(Presence.FIRST_DELAY, function()
        Announce()
        Loop()
    end)
end, OWNER)

function Presence.Describe(count)
    if count.scope == "group" then
        return string.format(L.ONLINE_GROUP, count.total)
    end
    return string.format(L.ONLINE_REGION, count.total, count.Alliance, count.Horde)
end

ns.SlashCommands:Register("online", function()
    ns:Print(Presence.Describe(Presence:Count()))
    local parts = {}
    for version, players in pairs(Presence:Versions()) do
        parts[#parts + 1] = string.format("%s (%d)", version, players)
    end
    table.sort(parts)
    ns:Print(string.format(L.ONLINE_VERSIONS, table.concat(parts, ", ")))
end, L.HELP_ONLINE)
