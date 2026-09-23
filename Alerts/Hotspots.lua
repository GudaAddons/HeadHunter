-- HH-045: PvP hotspots, "fire" levels per zone (docs/addon/features.md section 5).
--
-- Over the last WINDOW seconds, per zone:
--   A = HeadHunter users in PvP combat there (their pings, and us)
--   E = distinct enemy players seen fighting there (merged across all pings)
--   D = deaths reported there
--   heat = A + E + 2*D
-- Levels: >= 4 Skirmish (chat line), >= 10 Battle (popup + sound),
--         >= 20 Warzone (popup + sound + raid-warning text).
--
-- We count as "in PvP combat" while in combat with enemy players on screen in the
-- last FIGHT_RECENT seconds. Then, at most every PING_INTERVAL seconds, a ping
-- (protocol type P: map, time, position, short enemy ids) goes out on the
-- automatic routes.
-- Alerts: when a zone climbs a level, inside the alert range, never for a fight we
-- are in ourselves, at most once per zone and level per LEVEL_THROTTLE.
-- [Help] sets a waypoint to the newest fight; [Ignore] mutes the zone for IGNORE_TIME.

local addonName, ns = ...
local L = ns.L

local Hotspots = ns:RegisterModule("Hotspots", {})

local OWNER = "Hotspots"

Hotspots.WINDOW = 300
Hotspots.TICK = 5
Hotspots.FIGHT_RECENT = 15
Hotspots.PING_INTERVAL = 30
Hotspots.LEVEL_THROTTLE = 300
Hotspots.IGNORE_TIME = 600
Hotspots.MAX_SKEW = 300
Hotspots.LEVELS = { { heat = 20, id = 3 }, { heat = 10, id = 2 }, { heat = 4, id = 1 } }

local zones = {}        -- zone mapID -> { fighters = {id -> {t, x, y}}, enemies = {id -> t}, deaths = {id -> t} }
local announced = {}    -- zone -> highest level announced in the current burst
local ignored = {}      -- zone -> GetTime() until which it is muted
local lastPing = 0

local function Zone(mapID)
    local zone = ns.Zones.ZoneOf(mapID)
    if not zone then return nil end
    zones[zone] = zones[zone] or { fighters = {}, enemies = {}, deaths = {} }
    return zone, zones[zone]
end

-- Short, stable enemy id for pings: the last 8 characters of the GUID
function Hotspots.ShortId(guid)
    guid = tostring(guid or ""):gsub("[^%w]", "")
    return guid:sub(-8)
end

-------------------------------------------------
-- Inputs
-------------------------------------------------

function Hotspots:AddFighter(mapID, who, t, x, y, enemyIds)
    local zone, data = Zone(mapID)
    if not zone or not who then return nil end
    data.fighters[who] = { t = t, x = x, y = y }
    for _, id in ipairs(enemyIds or {}) do
        if not data.enemies[id] or data.enemies[id] < t then data.enemies[id] = t end
    end
    return zone
end

function Hotspots:AddDeath(report)
    local zone, data = Zone(report.mapID)
    if not zone or not report.id then return nil end
    -- Reports keep the map the victim stood on (maybe a cave); hotspots use the zone
    local _, x, y = ns.Zones.ToZone(report.mapID, report.x, report.y)
    local U = ns.Utils
    local t = report.t or U.ServerTime()
    data.deaths[report.id] = { t = t, killer = ns.RulesEngine.EnemyId(report.killer), x = x, y = y }
    -- Our own death: we were in that fight (a quick gank can end before our combat
    -- tick sees it), so we count as a HeadHunter there and are not alerted about it
    if report.victim and U.SameCharacter(report.victim.key, U.UnitKey("player")) then
        local me = U.CompactName(U.UnitKey("player"))
        local known = me and data.fighters[me]
        if me and (not known or known.t < t) then data.fighters[me] = { t = t, x = x, y = y } end
    end
    return zone
end

-------------------------------------------------
-- Heat
-------------------------------------------------

local function CountRecent(map, since)
    local n = 0
    for key, value in pairs(map) do
        local t = type(value) == "table" and value.t or value
        if t >= since then n = n + 1 else map[key] = nil end
    end
    return n
end

-- heat, level (0-3), A, E, D for a zone
function Hotspots:Heat(zone, now)
    local data = zones[zone]
    if not data then return 0, 0, 0, 0, 0 end
    local since = (now or ns.Utils.ServerTime()) - self.WINDOW
    local a = CountRecent(data.fighters, since)
    local e = CountRecent(data.enemies, since)
    local d = CountRecent(data.deaths, since)
    local heat = a + e + 2 * d
    for _, level in ipairs(self.LEVELS) do
        if heat >= level.heat then return heat, level.id, a, e, d end
    end
    return heat, 0, a, e, d
end

-- True when the zone's heat is only deaths by ONE WANTED outlaw (no fighters, no
-- enemies seen): that is a ganker, already covered by the WANTED popup, not a
-- battle (author, 2026-09-23: chat line only).
function Hotspots:IsLoneOutlaw(zone, a, e)
    if a > 0 or e > 0 then return false end
    local killer
    for _, death in pairs(zones[zone].deaths) do
        if not death.killer or (killer and death.killer ~= killer) then return false end
        killer = death.killer
    end
    local entry = killer and ns.Wanted:Get(killer)
    return entry ~= nil and entry.wanted == true
end

-- Newest known fight position in the zone (a fighter or a death), in zone coordinates
local function LastPosition(data)
    local best
    for _, list in ipairs({ data.fighters, data.deaths }) do
        for _, item in pairs(list) do
            if item.x and item.y and (not best or item.t > best.t) then best = item end
        end
    end
    if best then return best.x, best.y end
    return nil
end

-- Time of the newest activity of any kind in the zone
local function Newest(data)
    local newest = 0
    for _, list in ipairs({ data.fighters, data.enemies, data.deaths }) do
        for _, value in pairs(list) do
            local t = type(value) == "table" and value.t or value
            if t > newest then newest = t end
        end
    end
    return newest
end

-- Burning zones for the map pins (HH-046), hottest first:
--   { zone, level, heat, a, e, d, x, y, t = newest activity }
-- x, y is the newest fight position (nil when none is known). Lone-outlaw zones are
-- left out: the WANTED skull pin already marks that ganker.
function Hotspots:Active(now)
    now = now or ns.Utils.ServerTime()
    local list = {}
    for zone, data in pairs(zones) do
        local heat, level, a, e, d = self:Heat(zone, now)
        if level > 0 and not self:IsLoneOutlaw(zone, a, e) then
            local x, y = LastPosition(data)
            list[#list + 1] = { zone = zone, level = level, heat = heat, a = a, e = e, d = d, x = x, y = y,
                t = Newest(data) }
        end
    end
    table.sort(list, function(p, q)
        if p.heat ~= q.heat then return p.heat > q.heat end
        return p.zone < q.zone
    end)
    return list
end

-------------------------------------------------
-- Alerts
-------------------------------------------------

Hotspots.FIRE_ICON = "Interface\\Icons\\Spell_Fire_Fire"

local function Fire(level)
    local icon = "|T" .. Hotspots.FIRE_ICON .. ":14:14|t"
    return string.rep(icon, level)
end
Hotspots.Fire = Fire

local function EnemyFaction()
    local mine = ns.Utils.UnitFaction("player")
    if mine == "Alliance" then return FACTION_HORDE or "Horde" end
    if mine == "Horde" then return FACTION_ALLIANCE or "Alliance" end
    return L.ENEMIES
end
Hotspots.EnemyFaction = EnemyFaction

-- Our side of the fight. The count next to it is the HeadHunter users in the fight
-- (only they send pings), so it is a lower bound.
local function OwnFaction()
    local mine = ns.Utils.UnitFaction("player")
    if mine == "Alliance" then return FACTION_ALLIANCE or "Alliance" end
    if mine == "Horde" then return FACTION_HORDE or "Horde" end
    return L.HEADHUNTERS
end
Hotspots.OwnFaction = OwnFaction

-- "≈4 Horde fighting 5 Alliance, 4 death(s) in 5 min", saying only what is known:
-- a = HeadHunters fighting, e = enemies seen, d = deaths
function Hotspots.Describe(a, e, d)
    local parts = {}
    if e > 0 and a > 0 then
        parts[1] = string.format(L.HOTSPOT_BOTH, e, EnemyFaction(), a, OwnFaction())
    elseif e > 0 then
        parts[1] = string.format(L.HOTSPOT_ENEMIES, e, EnemyFaction())
    elseif a > 0 then
        parts[1] = string.format(L.HOTSPOT_OURS, a, OwnFaction())
    end
    if d > 0 then parts[#parts + 1] = string.format(L.HOTSPOT_DEATHS, d) end
    return table.concat(parts, ", ")
end

-- [Help]: a waypoint to the newest fight where the client allows it (Classic Era does
-- not), and chat always says where it is. title: "Battle", ...
function Hotspots:Help(zone, title)
    local data = zones[zone]
    local x, y
    -- Not "data and LastPosition(data)": `and` would keep only the first return value
    if data then x, y = LastPosition(data) end
    local zoneName = ns.Utils.MapName(zone) or L.UNKNOWN_ZONE
    return ns.MapMarkers.GuideAndTell(zone, x, y, string.format(L.GUIDE_HOTSPOT, title, zoneName),
        string.format(L.HOTSPOT_WAYPOINT, zoneName))
end

function Hotspots:Evaluate(zone)
    -- The zone's data changed (map pins redraw); HH_HOTSPOT below is only for alerts
    ns.Events:Fire("HH_HOTSPOT_CHANGED", zone)
    local now = ns.Utils.ServerTime()
    local heat, level, a, e, d = self:Heat(zone, now)
    if level == 0 then
        announced[zone] = nil
        return
    end
    if (announced[zone] or 0) >= level then return end
    -- Our own fight: nothing to tell us
    local me = ns.Utils.CompactName(ns.Utils.UnitKey("player"))
    local mine = me and zones[zone].fighters[me]
    if mine and now - mine.t <= self.FIGHT_RECENT * 4 then
        announced[zone] = level
        return
    end
    if ignored[zone] and ns.Utils.Now() < ignored[zone] then return end
    if not ns.Zones.InRange(zone) then return end
    announced[zone] = level

    local zoneName = ns.Utils.MapName(zone) or L.UNKNOWN_ZONE
    local title = L["HOTSPOT_LEVEL_" .. level]
    local line = string.format(L.HOTSPOT_LINE, Fire(level), title, zoneName, Hotspots.Describe(a, e, d))
    local alert = {
        key = "hot:" .. zone .. ":" .. level,
        throttle = self.LEVEL_THROTTLE,
        chat = line,
    }
    local loneOutlaw = self:IsLoneOutlaw(zone, a, e)
    if level >= 2 and not loneOutlaw then
        alert.sound = true
        alert.popup = {
            -- Own dialog: must never replace a WANTED "Join the posse" popup
            dialog = ns.Alerts.HOTSPOT_POPUP,
            text = line,
            accept = L.HOTSPOT_HELP,
            decline = L.HOTSPOT_IGNORE,
            onAccept = function() Hotspots:Help(zone, title) end,
            onDecline = function() ignored[zone] = ns.Utils.Now() + Hotspots.IGNORE_TIME end,
        }
    end
    if level >= 3 and not loneOutlaw then
        alert.text = string.format(L.HOTSPOT_CENTER, Fire(level), title, zoneName)
    end
    ns.Alerts:Show(alert)
    ns.Events:Fire("HH_HOTSPOT", zone, level, heat)
end

-------------------------------------------------
-- Our own fight
-------------------------------------------------

function Hotspots:Tick()
    if not ns.Guards:IsActive() then return end
    local U = ns.Utils
    if not U.SafeCall(UnitAffectingCombat, "player") then return end
    local guids = ns.EnemyCache:RecentGUIDs(self.FIGHT_RECENT)
    if #guids == 0 then return end
    local ids = {}
    for i, guid in ipairs(guids) do ids[i] = Hotspots.ShortId(guid) end
    -- Pings carry the zone, so the position must be on the zone map too (not a cave's)
    local mapID = U.PlayerMapID()
    local _, x, y = ns.Zones.ToZone(mapID, U.PlayerPosition(mapID))
    local now = U.ServerTime()
    local zone = self:AddFighter(mapID, U.CompactName(U.UnitKey("player")), now, x, y, ids)
    if not zone then return end
    if now - lastPing >= self.PING_INTERVAL then
        lastPing = now
        local Protocol, Transport = ns.Protocol, ns.Transport
        Transport:Queue(Protocol.TYPES.HOTSPOT, Protocol.EncodeHotspot(zone, now, x, y, ids),
            Transport.PRIORITY.hotspot, "P:" .. zone)
    end
    self:Evaluate(zone)
end

function Hotspots:OnPeerPing(record, sender)
    local mapID, t, x, y, ids = ns.Protocol.DecodeHotspot(record)
    if not mapID then return end
    local now = ns.Utils.ServerTime()
    if t > now + self.MAX_SKEW or now - t > self.WINDOW then return end
    local zone = self:AddFighter(mapID, ns.Utils.CompactName(sender), t, x, y, ids)
    if zone then self:Evaluate(zone) end
end

local function Ticker()
    C_Timer.After(Hotspots.TICK, function()
        local ok, err = pcall(Hotspots.Tick, Hotspots)
        if not ok then ns:Error(err) end
        Ticker()
    end)
end

-- Deaths are evaluated after the WANTED recompute (1 s debounce), so the lone
-- outlaw check sees whether the killer is WANTED. One check per zone per burst.
Hotspots.DEATH_DELAY = 1.5
local deathCheckPending = {}

local function ScheduleDeathCheck(zone)
    if deathCheckPending[zone] then return end
    deathCheckPending[zone] = true
    C_Timer.After(Hotspots.DEATH_DELAY, function()
        deathCheckPending[zone] = nil
        Hotspots:Evaluate(zone)
    end)
end

ns.Events:Register("HH_INITIALIZED", function()
    ns.Transport:RegisterHandler(ns.Protocol.TYPES.HOTSPOT, function(record, sender) Hotspots:OnPeerPing(record, sender) end)
    ns.Events:Register("HH_REPORT_ADDED", function(_, report)
        local zone = Hotspots:AddDeath(report)
        if zone then ScheduleDeathCheck(zone) end
    end, OWNER)
    Ticker()
end, OWNER)

ns.SlashCommands:Register("hotspots", function()
    local now = ns.Utils.ServerTime()
    local any = false
    for zone in pairs(zones) do
        local heat, level, a, e, d = Hotspots:Heat(zone, now)
        if heat > 0 then
            any = true
            ns:Print(string.format(L.HOTSPOT_STATUS, Fire(math.max(level, 0)), ns.Utils.MapName(zone) or tostring(zone),
                heat, a, e, d))
        end
    end
    if not any then ns:Print(L.HOTSPOT_NONE) end
end, L.HELP_HOTSPOTS)
