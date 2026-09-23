-- HH-040: which zones are "near" for alerts (docs/addon/features.md section 4).
--
-- Range setting (settings.alerts.range):
--   "adjacent"  (default) the player's zone and the zones bordering it
--   "continent" anywhere on the player's continent
--
-- Classic uiMapIDs (Classic Era; Forever uses the same Vanilla maps). Borders follow
-- Vanilla roads and paths; boats and flight paths do not count. Each border is listed once and made symmetric below. Confirm doubtful
-- borders in game (HH-070).

local addonName, ns = ...

local Zones = ns:RegisterModule("Zones", {})

local EASTERN_KINGDOMS, KALIMDOR = 1415, 1414

-- mapID -> continent (also the list of known zones)
local CONTINENT = {}
local EK = {
    1416, 1417, 1418, 1419, 1420, 1421, 1422, 1423, 1424, 1425, 1426, 1427, 1428, 1429,
    1430, 1431, 1432, 1433, 1434, 1435, 1436, 1437, 1453, 1455, 1458,
}
local KAL = {
    1411, 1412, 1413, 1438, 1439, 1440, 1441, 1442, 1443, 1444, 1445, 1446, 1447, 1448,
    1449, 1450, 1451, 1452, 1454, 1456, 1457,
}
for _, id in ipairs(EK) do CONTINENT[id] = EASTERN_KINGDOMS end
for _, id in ipairs(KAL) do CONTINENT[id] = KALIMDOR end

local BORDERS = {
    -- Eastern Kingdoms
    { 1429, 1436 }, { 1429, 1431 }, { 1429, 1433 }, { 1429, 1453 },  -- Elwynn: Westfall, Duskwood, Redridge, Stormwind
    { 1436, 1431 },                                                    -- Westfall - Duskwood
    { 1431, 1433 }, { 1431, 1430 }, { 1431, 1434 },                    -- Duskwood: Redridge, Deadwind, Stranglethorn
    { 1433, 1428 },                                                    -- Redridge - Burning Steppes
    { 1430, 1435 },                                                    -- Deadwind - Swamp of Sorrows
    { 1435, 1419 },                                                    -- Swamp - Blasted Lands
    { 1428, 1427 },                                                    -- Burning Steppes - Searing Gorge
    { 1427, 1418 }, { 1427, 1432 },                                    -- Searing Gorge: Badlands, Loch Modan (gate)
    { 1418, 1432 },                                                    -- Badlands - Loch Modan
    { 1432, 1426 }, { 1432, 1437 },                                    -- Loch Modan: Dun Morogh, Wetlands
    { 1426, 1455 },                                                    -- Dun Morogh - Ironforge
    { 1437, 1417 },                                                    -- Wetlands - Arathi
    { 1417, 1424 }, { 1417, 1425 },                                    -- Arathi: Hillsbrad, Hinterlands
    { 1424, 1416 }, { 1424, 1421 }, { 1424, 1425 },                    -- Hillsbrad: Alterac, Silverpine, Hinterlands
    { 1416, 1421 }, { 1416, 1422 },                                    -- Alterac: Silverpine, Western Plaguelands
    { 1421, 1420 },                                                    -- Silverpine - Tirisfal
    { 1420, 1422 }, { 1420, 1458 },                                    -- Tirisfal: Western Plaguelands, Undercity
    { 1422, 1423 }, { 1422, 1425 },                                    -- WPL: EPL, Hinterlands
    -- Kalimdor
    { 1411, 1413 }, { 1411, 1454 },                                    -- Durotar: Barrens, Orgrimmar
    { 1454, 1413 },                                                    -- Orgrimmar - Barrens
    { 1413, 1412 }, { 1413, 1440 }, { 1413, 1442 }, { 1413, 1445 }, { 1413, 1441 }, -- Barrens
    { 1412, 1456 },                                                    -- Mulgore - Thunder Bluff
    { 1442, 1440 }, { 1442, 1443 },                                    -- Stonetalon: Ashenvale, Desolace
    { 1440, 1439 }, { 1440, 1448 }, { 1440, 1447 },                    -- Ashenvale: Darkshore, Felwood, Azshara
    { 1438, 1457 },                                                    -- Teldrassil - Darnassus
    { 1448, 1452 }, { 1448, 1450 }, { 1452, 1450 },                    -- Felwood, Winterspring, Moonglade
    { 1443, 1444 },                                                    -- Desolace - Feralas
    { 1444, 1441 },                                                    -- Feralas - Thousand Needles
    { 1441, 1446 },                                                    -- Thousand Needles - Tanaris
    { 1446, 1449 },                                                    -- Tanaris - Un'Goro
    { 1449, 1451 },                                                    -- Un'Goro - Silithus
}

local NEIGHBORS = {}
for _, pair in ipairs(BORDERS) do
    local a, b = pair[1], pair[2]
    NEIGHBORS[a] = NEIGHBORS[a] or {}
    NEIGHBORS[b] = NEIGHBORS[b] or {}
    NEIGHBORS[a][b] = true
    NEIGHBORS[b][a] = true
end

Zones.CONTINENT = CONTINENT
Zones.NEIGHBORS = NEIGHBORS

-- Normalise any map (cave, sub-zone, micro-dungeon) to the zone it belongs to
function Zones.ZoneOf(mapID)
    mapID = tonumber(mapID)
    local id = mapID
    for _ = 1, 6 do
        if not id then return mapID end
        if CONTINENT[id] then return id end
        local info = C_Map and ns.Utils.SafeCall(C_Map.GetMapInfo, id)
        if not info or not info.parentMapID or info.parentMapID == 0 then break end
        id = info.parentMapID
    end
    return mapID
end

function Zones.ContinentOf(mapID)
    local zone = Zones.ZoneOf(mapID)
    return zone and (CONTINENT[zone] or ns.Utils.ContinentOf(zone))
end

function Zones.AreNeighbors(a, b)
    return NEIGHBORS[a] ~= nil and NEIGHBORS[a][b] == true
end

-- "zone" | "adjacent" | "continent" | nil (farther or unknown)
function Zones.Distance(eventMapID, playerMapID)
    local a, b = Zones.ZoneOf(eventMapID), Zones.ZoneOf(playerMapID)
    if not a or not b then return nil end
    if a == b then return "zone" end
    if Zones.AreNeighbors(a, b) then return "adjacent" end
    local ca, cb = Zones.ContinentOf(a), Zones.ContinentOf(b)
    if ca and ca == cb then return "continent" end
    return nil
end

-- Is an event on eventMapID inside the player's alert range?
function Zones.InRange(eventMapID, playerMapID, range)
    local distance = Zones.Distance(eventMapID, playerMapID or ns.Utils.PlayerMapID())
    if not distance then return false, nil end
    range = range or (ns.db and ns.db.settings.alerts.range) or "adjacent"
    if distance == "continent" then return range == "continent", distance end
    return true, distance
end
