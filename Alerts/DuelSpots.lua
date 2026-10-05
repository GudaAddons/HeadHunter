-- HH-134: duel spots, places where players duel now (docs/addon/features.md section 10).
--
-- A zone and layer is a duel spot when HeadHunters saw at least MIN_DUELS duels between
-- at least MIN_PLAYERS different players there in the last WINDOW seconds. Only duels
-- where both players are level MIN_LEVEL or higher count (author, 2026-10-05); the level
-- gap does not matter here, unlike the Duels list.
--
-- Our own duels and the duels we watch come from Sync/Duels.lua (HH_DUEL_SEEN, once both
-- levels are known). We keep them under our zone and our layer (Detection/Layer.lua),
-- and at most every PING_INTERVAL seconds a ping (protocol type Z: zone, time, position,
-- layer, the duels as name hashes) goes out on the automatic routes. Pings from the
-- other faction never arrive (Sync/Transport.lua), so the HeadHunters we can ask for an
-- invite are always our faction. Many witnesses see the same duel: the same two players
-- within DEDUPE seconds is one duel.
--
-- Players see a duel spot as a mark on the world map (UI/MapMarkers.lua; a click asks a
-- HeadHunter on that layer for an invite), a chat line when one starts in the alert
-- range (alerts.duelSpots; names as links, a click whispers them) and /hh duelspots.
-- The map keeps a spot MAP_TIME seconds after its last duel, like PvP areas.

local addonName, ns = ...
local L = ns.L

local DuelSpots = ns:RegisterModule("DuelSpots", {})

local OWNER = "DuelSpots"

DuelSpots.WINDOW = 1200
DuelSpots.MIN_DUELS = 10
DuelSpots.MIN_PLAYERS = 5
DuelSpots.MIN_LEVEL = 19
DuelSpots.MAP_TIME = 1200
DuelSpots.DEDUPE = ns.Duels.DEDUPE
DuelSpots.TICK = 5
DuelSpots.PING_INTERVAL = 60
DuelSpots.ALERT_THROTTLE = 1800
DuelSpots.MAX_SKEW = 300
DuelSpots.MAX_NAMES = 3
DuelSpots.UNKNOWN_LAYER = "?"
DuelSpots.ICON = "Interface\\AddOns\\HeadHunter\\Assets\\Textures\\swords"

-- zone -> layer key -> { duels = { { a, b, t, x, y } }, reporters = { who -> { t, sender } } }.
-- The layer key is the layer number, or UNKNOWN_LAYER when the reporter could not tell.
local spots = {}
-- "zone:layer" -> the spot as it last was, for the map (MAP_TIME)
local remembered = {}
-- "zone:layer" -> true while the spot is announced, so the chat line comes once per start
local announced = {}
local unsent = false
local lastPing = 0

local function LayerKey(layer)
    return layer or DuelSpots.UNKNOWN_LAYER
end

local function SpotId(zone, layerKey)
    return zone .. ":" .. tostring(layerKey)
end

local function Bucket(zone, layerKey)
    spots[zone] = spots[zone] or {}
    spots[zone][layerKey] = spots[zone][layerKey] or { duels = {}, reporters = {} }
    return spots[zone][layerKey]
end

local function Me()
    local U = ns.Utils
    return U.CompactName(U.UnitKey("player"))
end

-------------------------------------------------
-- Inputs
-------------------------------------------------

local function Known(bucket, duel)
    for _, have in ipairs(bucket.duels) do
        if have.a == duel.a and have.b == duel.b and math.abs(have.t - duel.t) < DuelSpots.DEDUPE then return true end
    end
    return false
end

-- Adds duels seen on mapID and layer by `who` (compact name). sender: the name to
-- whisper, only for other HeadHunters. duels: { a, b, t } with a and b as
-- Protocol.NameHash. sim: test data from /hh sim duels, never sent and never whispered.
-- Returns the zone and the layer key, or nil.
function DuelSpots:Add(mapID, layer, who, t, x, y, duels, sender, sim)
    local zone = ns.Zones.ZoneOf(mapID)
    if not zone or not who then return nil end
    local layerKey = LayerKey(layer)
    local bucket = Bucket(zone, layerKey)
    local reporter = bucket.reporters[who]
    if not reporter or reporter.t < t then bucket.reporters[who] = { t = t, sender = sender, sim = sim } end
    for _, duel in ipairs(duels or {}) do
        local a, b = duel.a, duel.b
        if a > b then a, b = b, a end
        local entry = { a = a, b = b, t = duel.t, x = x, y = y, sim = sim }
        if not Known(bucket, entry) then bucket.duels[#bucket.duels + 1] = entry end
    end
    return zone, layerKey
end

-- A duel we saw ourselves (HH_DUEL_SEEN): counted when both players are MIN_LEVEL+
function DuelSpots:OnDuelSeen(duel)
    if not ns.Guards:IsActive() or type(duel) ~= "table" then return nil end
    local winnerLevel, loserLevel = tonumber(duel.winnerLevel), tonumber(duel.loserLevel)
    if not (winnerLevel and loserLevel and winnerLevel >= self.MIN_LEVEL and loserLevel >= self.MIN_LEVEL) then
        return nil
    end
    local U, P = ns.Utils, ns.Protocol
    local mapID = U.PlayerMapID()
    local _, x, y = ns.Zones.ToZone(mapID, U.PlayerPosition(mapID))
    local t = tonumber(duel.t) or U.ServerTime()
    local zone, layerKey = self:Add(mapID, ns.Layer:Current(), Me(), t, x, y,
        { { a = P.NameHash(duel.winner), b = P.NameHash(duel.loser), t = t } })
    if not zone then return nil end
    unsent = true
    self:Evaluate(zone, layerKey)
    self:Tick()
    return zone, layerKey
end

-------------------------------------------------
-- State
-------------------------------------------------

-- Duels and different players on a zone and layer in the WINDOW (older duels are
-- forgotten, reporters after MAP_TIME)
function DuelSpots:State(zone, layerKey, now)
    local bucket = spots[zone] and spots[zone][layerKey]
    if not bucket then return 0, 0 end
    now = now or ns.Utils.ServerTime()
    local kept, players, count = {}, {}, 0
    for _, duel in ipairs(bucket.duels) do
        if duel.t >= now - self.WINDOW then
            kept[#kept + 1] = duel
            players[duel.a], players[duel.b] = true, true
        end
    end
    bucket.duels = kept
    for who, reporter in pairs(bucket.reporters) do
        if reporter.t < now - self.MAP_TIME then bucket.reporters[who] = nil end
    end
    for _ in pairs(players) do count = count + 1 end
    return #kept, count
end

function DuelSpots:IsSpot(zone, layerKey, now)
    local duels, players = self:State(zone, layerKey, now)
    return duels >= self.MIN_DUELS and players >= self.MIN_PLAYERS, duels, players
end

-- The newest duel's place and time on a zone and layer
local function Newest(bucket)
    local best
    for _, duel in ipairs(bucket.duels) do
        if not best or duel.t > best.t then best = duel end
    end
    return best
end

local function Snapshot(zone, layerKey, duels, players)
    local newest = Newest(spots[zone][layerKey])
    return { zone = zone, layerKey = layerKey, layer = layerKey ~= DuelSpots.UNKNOWN_LAYER and layerKey or nil,
        duels = duels, players = players, x = newest and newest.x, y = newest and newest.y, t = newest and newest.t or 0 }
end

-- Duel spots for the map and /hh duelspots, busiest first: the ones that pass the rule
-- now, and the ones that did within MAP_TIME as they last were (remembered = true).
-- Each: { zone, layerKey, layer, duels, players, x, y, t = newest duel }.
function DuelSpots:Active(now)
    now = now or ns.Utils.ServerTime()
    local list, seen = {}, {}
    for zone, layers in pairs(spots) do
        for layerKey in pairs(layers) do
            local ok, duels, players = self:IsSpot(zone, layerKey, now)
            if ok then
                local spot = Snapshot(zone, layerKey, duels, players)
                local id = SpotId(zone, layerKey)
                remembered[id] = spot
                seen[id] = true
                list[#list + 1] = spot
            end
        end
    end
    for id, spot in pairs(remembered) do
        if not seen[id] then
            if now - spot.t > self.MAP_TIME then
                remembered[id] = nil
            else
                local copy = {}
                for k, v in pairs(spot) do copy[k] = v end
                copy.remembered = true
                list[#list + 1] = copy
            end
        end
    end
    table.sort(list, function(p, q)
        if p.duels ~= q.duels then return p.duels > q.duels end
        if p.zone ~= q.zone then return p.zone < q.zone end
        return tostring(p.layerKey) < tostring(q.layerKey)
    end)
    return list
end

-- Other HeadHunters who saw duels on that zone and layer, newest first: the names to
-- whisper (our faction only, as Transport drops the other faction's pings)
-- Also returns the reporters themselves, in the same order (sim tells test data)
function DuelSpots:Inviters(zone, layerKey, now)
    local bucket = spots[zone] and spots[zone][layerKey]
    if not bucket then return {}, {} end
    now = now or ns.Utils.ServerTime()
    local me, list = Me(), {}
    for who, reporter in pairs(bucket.reporters) do
        if who ~= me and reporter.sender and reporter.t >= now - self.MAP_TIME then list[#list + 1] = reporter end
    end
    table.sort(list, function(a, b) return a.t > b.t end)
    local names = {}
    for i, reporter in ipairs(list) do names[i] = reporter.sender end
    return names, list
end

-- True when we are in that zone on that layer now
function DuelSpots:OnOurLayer(zone, layerKey)
    if layerKey == self.UNKNOWN_LAYER then return false end
    return ns.Layer:Compare(layerKey, zone) == "same"
end

-------------------------------------------------
-- Texts
-------------------------------------------------

function DuelSpots.Icon()
    return "|T" .. DuelSpots.ICON .. ":14:14|t"
end

-- "12 duels, 6 players in 10 min"
function DuelSpots.Describe(spot)
    return string.format(L.DUEL_SPOT_DESCRIBE, spot.duels, spot.players, math.floor(DuelSpots.WINDOW / 60))
end

-- "Layer 3", "Layer 3 (your layer)" or "Layer unknown"
function DuelSpots:LayerText(spot)
    if not spot.layer then return L.DUEL_SPOT_LAYER_UNKNOWN end
    if self:OnOurLayer(spot.zone, spot.layerKey) then return string.format(L.DUEL_SPOT_LAYER_YOURS, spot.layer) end
    return string.format(L.DUEL_SPOT_LAYER, spot.layer)
end

-- Up to MAX_NAMES HeadHunters there, as chat links when `links`, else plain names
function DuelSpots:InviterNames(zone, layerKey, links)
    local U, parts = ns.Utils, {}
    for i, sender in ipairs(self:Inviters(zone, layerKey)) do
        if i > self.MAX_NAMES then break end
        local key = U.PlayerKey(sender)
        parts[#parts + 1] = (links and U.PlayerLink(key)) or U.DisplayName(key) or sender
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- The chat line: "Duels in Orgrimmar (Layer 3): 12 duels, 6 players in 10 min. Ask for an
-- invite: [Brakka]"; the invite part only when we are not on that layer
function DuelSpots:Line(spot)
    local zoneName = ns.Utils.MapName(spot.zone) or L.UNKNOWN_ZONE
    local line = string.format(L.DUEL_SPOT_LINE, DuelSpots.Icon(), zoneName, self:LayerText(spot), DuelSpots.Describe(spot))
    local names = not self:OnOurLayer(spot.zone, spot.layerKey) and self:InviterNames(spot.zone, spot.layerKey, true)
    if names then line = line .. string.format(L.DUEL_SPOT_ASK, names) end
    return line
end

-------------------------------------------------
-- Invite
-------------------------------------------------

-- Asks the newest HeadHunter on that zone and layer for a group invite, by whisper.
-- Runs inside a click (the map mark), which allows the whisper. A made-up HeadHunter
-- from /hh sim duels gets no whisper: chat shows what would be sent.
function DuelSpots:AskInvite(zone, layerKey)
    local U = ns.Utils
    local zoneName = U.MapName(zone) or L.UNKNOWN_ZONE
    if self:OnOurLayer(zone, layerKey) then
        ns:Print(L.DUEL_SPOT_SAME_LAYER)
        return "same"
    end
    local names, reporters = self:Inviters(zone, layerKey)
    local target = names[1]
    if not target then
        ns:Print(string.format(L.DUEL_SPOT_NOBODY, zoneName))
        return nil
    end
    local text = string.format(L.DUEL_SPOT_WHISPER, zoneName)
    if reporters[1].sim then
        ns:Print(string.format(L.SIM_DUELS_WHISPER, target, text))
        return "sim", target
    end
    local ok = pcall(SendChatMessage, text, "WHISPER", nil, target)
    if not ok then return nil end
    ns:Print(string.format(L.POSSE_WHISPERED, U.DisplayName(U.PlayerKey(target)) or target))
    return "whispered", target
end

-------------------------------------------------
-- Alerts
-------------------------------------------------

local function AlertsOn()
    return ns.db ~= nil and ns.db.settings.alerts.duelSpots ~= false
end

-- We saw duels there ourselves lately: we are there, nothing to tell us
local function WeAreThere(zone, layerKey, now)
    local mine = spots[zone][layerKey].reporters[Me()]
    return mine ~= nil and now - mine.t <= DuelSpots.WINDOW
end

-- Test spots (/hh sim duels) are not held back by the alert throttle, so each run shows
-- the chat line again.
function DuelSpots:Evaluate(zone, layerKey, sim)
    ns.Events:Fire("HH_DUEL_SPOTS_CHANGED", zone)
    local now = ns.Utils.ServerTime()
    local ok, duels, players = self:IsSpot(zone, layerKey, now)
    local id = SpotId(zone, layerKey)
    if not ok then
        announced[id] = nil
        return false
    end
    local spot = Snapshot(zone, layerKey, duels, players)
    remembered[id] = spot
    if announced[id] then return false end
    announced[id] = true
    if not AlertsOn() or WeAreThere(zone, layerKey, now) or self:OnOurLayer(zone, layerKey) then return false end
    if not ns.Zones.InRange(zone) then return false end
    ns.Alerts:Show({ key = "duels:" .. id, throttle = sim and 0 or self.ALERT_THROTTLE, chat = self:Line(spot), combat = true })
    return true
end

-------------------------------------------------
-- Test data: /hh sim duels [clear]
-------------------------------------------------

-- Made-up duelists and the made-up HeadHunter on the other layer. Never real players.
DuelSpots.SIM_DUELISTS = { "Testone", "Testtwo", "Testthree", "Testfour", "Testfive", "Testsix", "Testseven" }
DuelSpots.SIM_HEADHUNTER = "Testeight"
DuelSpots.SIM_DUELS = 12
DuelSpots.SIM_OFFSET = 0.05

-- A made-up name as this client writes names: "Testsix Sim" on WoW Forever (given and
-- family name), "Testsix-<our realm>" on Classic Era
local function SimName(given)
    if ns.Features.RealmlessNames then return given .. " Sim" end
    return given .. "-" .. tostring(ns.Utils.PlayerRealm())
end

local function SimDuels(now)
    local P, list, names = ns.Protocol, {}, DuelSpots.SIM_DUELISTS
    for i = 1, DuelSpots.SIM_DUELS do
        list[i] = { a = P.NameHash(SimName(names[(i - 1) % #names + 1])), b = P.NameHash(SimName(names[i % #names + 1])),
            t = now - (i - 1) * 45 }
    end
    return list
end

-- Two test spots in our zone, only on our screen: one on our layer, one on the next
-- layer with a made-up HeadHunter to ask for an invite (the click only prints the
-- whisper). Returns the zone, the other layer and the made-up HeadHunter, or nil when
-- the zone or our position cannot be read.
function DuelSpots:Simulate()
    local U = ns.Utils
    local mapID = U.PlayerMapID()
    local zone, x, y = ns.Zones.ToZone(mapID, U.PlayerPosition(mapID))
    if not zone or not x then return nil end
    local now = U.ServerTime()
    local layer = ns.Layer:Current()
    local otherLayer = (layer or 0) + 1
    local headhunter = SimName(self.SIM_HEADHUNTER)
    local here = self:Add(zone, layer, "sim:here", now, x, y, SimDuels(now), nil, true)
    if here then self:Evaluate(zone, LayerKey(layer), true) end
    local otherX = x + self.SIM_OFFSET > 1 and x - self.SIM_OFFSET or x + self.SIM_OFFSET
    self:Add(zone, otherLayer, U.CompactName(headhunter), now, otherX, y, SimDuels(now), headhunter, true)
    announced[SpotId(zone, otherLayer)] = nil
    self:Evaluate(zone, otherLayer, true)
    return zone, otherLayer, headhunter
end

-- Removes every test duel and test HeadHunter; returns how many test duels went
function DuelSpots:ClearSim()
    local removed = 0
    for zone, layers in pairs(spots) do
        for layerKey, bucket in pairs(layers) do
            local kept = {}
            for _, duel in ipairs(bucket.duels) do
                if duel.sim then removed = removed + 1 else kept[#kept + 1] = duel end
            end
            bucket.duels = kept
            for who, reporter in pairs(bucket.reporters) do
                if reporter.sim then bucket.reporters[who] = nil end
            end
            local id = SpotId(zone, layerKey)
            if not self:IsSpot(zone, layerKey) then
                remembered[id] = nil
                announced[id] = nil
            end
        end
    end
    ns.Events:Fire("HH_DUEL_SPOTS_CHANGED")
    return removed
end

-------------------------------------------------
-- Pings
-------------------------------------------------

-- Sends the duels on our zone and layer, newest first, when we saw new ones and the
-- last ping is PING_INTERVAL seconds old. Test duels from /hh sim duels never go out.
function DuelSpots:Tick()
    if not unsent or not ns.Guards:IsActive() then return false end
    local U = ns.Utils
    local now = U.ServerTime()
    if now - lastPing < self.PING_INTERVAL then return false end
    local mapID = U.PlayerMapID()
    local zone = ns.Zones.ZoneOf(mapID)
    local layer = ns.Layer:Current()
    local bucket = zone and spots[zone] and spots[zone][LayerKey(layer)]
    unsent = false
    if not bucket then return false end
    self:State(zone, LayerKey(layer), now)
    local duels = {}
    for _, duel in ipairs(bucket.duels) do
        if not duel.sim then duels[#duels + 1] = duel end
    end
    if #duels == 0 then return false end
    table.sort(duels, function(a, b) return a.t > b.t end)
    lastPing = now
    local _, x, y = ns.Zones.ToZone(mapID, U.PlayerPosition(mapID))
    local Protocol, Transport = ns.Protocol, ns.Transport
    Transport:Queue(Protocol.TYPES.DUEL_SPOT, Protocol.EncodeDuelSpot(zone, now, x, y, layer, duels),
        Transport.PRIORITY.hotspot, "Z:" .. zone)
    return true
end

function DuelSpots:OnPeerPing(record, sender, faction)
    local U = ns.Utils
    if faction and faction ~= U.UnitFaction("player") then return nil end
    local mapID, t, x, y, layer, duels = ns.Protocol.DecodeDuelSpot(record)
    if not mapID then return nil end
    local now = U.ServerTime()
    if t > now + self.MAX_SKEW or now - t > self.WINDOW then return nil end
    local zone, layerKey = self:Add(mapID, layer, U.CompactName(sender), t, x, y, duels, sender)
    if zone then self:Evaluate(zone, layerKey) end
    return zone, layerKey
end

local function Ticker()
    C_Timer.After(DuelSpots.TICK, function()
        local ok, err = pcall(DuelSpots.Tick, DuelSpots)
        if not ok then ns:Error(err) end
        Ticker()
    end)
end

ns.Events:Register("HH_INITIALIZED", function()
    ns.Transport:RegisterHandler(ns.Protocol.TYPES.DUEL_SPOT, function(record, sender, faction)
        DuelSpots:OnPeerPing(record, sender, faction)
    end)
    ns.Events:Register("HH_DUEL_SEEN", function(_, duel) DuelSpots:OnDuelSeen(duel) end, OWNER)
    Ticker()
end, OWNER)

ns.SlashCommands:Register("duelspots", function()
    local list = DuelSpots:Active()
    if #list == 0 then
        ns:Print(L.DUEL_SPOT_NONE)
        return
    end
    for _, spot in ipairs(list) do ns:Print(DuelSpots:Line(spot)) end
end, L.HELP_DUELSPOTS)
