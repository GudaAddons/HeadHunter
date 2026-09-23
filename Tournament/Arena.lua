-- HH-102: are we in Gurubashi Arena? (docs/addon/features.md section 11)
--
-- The arena has no map of its own: it is part of Stranglethorn Vale. So it is a
-- position check on that map, locale-safe (no subzone text). Two ovals around the same
-- center: the whole arena (stands and pit) and the pit, where the fights happen.
-- The pit is measured in game; the stands are still a guess (/hh arena shows the
-- position, to set them in game).
--
--   Arena.Where(mapID, x, y) -> "pit" | "arena" | nil   (pure, tested offline)
--   Arena:PlayerWhere()      -> the same for the player

local addonName, ns = ...
local L = ns.L

local Arena = ns:RegisterModule("Arena", {})

Arena.MAP_ID = 1434                      -- Stranglethorn Vale
Arena.CENTER = { x = 0.3055, y = 0.4785 } -- pit center, from its 4 edges measured in game (2026-09-23)
Arena.ARENA = { x = 0.012, y = 0.019 }    -- pit and stands; seats start S 49.2, W 29.7, N 46.5 (back: a guess)
Arena.PIT = { x = 0.007, y = 0.011 }      -- half widths: E 31.2, W 29.9, N 46.8, S 48.9 (+ a small margin)

local function Inside(x, y, size)
    local dx = (x - Arena.CENTER.x) / size.x
    local dy = (y - Arena.CENTER.y) / size.y
    return dx * dx + dy * dy <= 1
end

function Arena.Where(mapID, x, y)
    if mapID ~= Arena.MAP_ID or not x or not y then return nil end
    if Inside(x, y, Arena.PIT) then return "pit" end
    if Inside(x, y, Arena.ARENA) then return "arena" end
    return nil
end

-- The player's zone map (a cave or sub-map counts as its zone) and position on it
function Arena:PlayerWhere()
    local U = ns.Utils
    local mapID = ns.Zones.ZoneOf(U.PlayerMapID())
    if not mapID then return nil end
    local x, y = U.PlayerPosition(mapID)
    return Arena.Where(mapID, x, y), mapID, x, y
end

function Arena:InArena()
    return self:PlayerWhere() ~= nil
end

-------------------------------------------------
-- The arena chest event (Gurubashi Arena Booty Run): every 3 hours from midnight,
-- realm time, Short John Mithril yells and puts a chest in the pit about a minute
-- later; both factions fight for it. Tournaments keep out of its way: a start from
-- CHEST_AFTER after a chest until CHEST_BEFORE before the next one.
-------------------------------------------------

Arena.CHEST_EVERY = 180      -- minutes
Arena.CHEST_AFTER = 15       -- the brawl is over by then
Arena.CHEST_BEFORE = 60      -- at least an hour of tournament before the next chest

-- Realm time of day in minutes (GetGameTime is the realm clock), or nil
function Arena.RealmMinutes()
    local U = ns.Utils
    local hours, minutes = U.SafeCall(_G.GetGameTime)
    hours, minutes = tonumber(U.Accessible(hours)), tonumber(U.Accessible(minutes))
    if not hours or not minutes then return nil end
    return hours * 60 + minutes
end

-- Minutes into the chest cycle (0 = a chest right now) at server time `at`
local function CycleMinute(at, now, realmMinutes)
    local minute = realmMinutes + math.floor((at - now) / 60)
    return minute % Arena.CHEST_EVERY
end

-- True when a tournament may start at server time `start`. now, realmMinutes: the
-- current server time and realm time of day (tests pass them; nil = read the clocks).
function Arena.StartClearOfChest(start, now, realmMinutes)
    now = now or ns.Utils.ServerTime()
    realmMinutes = realmMinutes or Arena.RealmMinutes()
    if not realmMinutes then return true end -- no realm clock: do not block
    local m = CycleMinute(start, now, realmMinutes)
    return m >= Arena.CHEST_AFTER and m <= Arena.CHEST_EVERY - Arena.CHEST_BEFORE
end

-- The first start, in whole minutes from now and at least `from`, clear of the chest
function Arena.FirstFreeMinutes(from, now, realmMinutes)
    now = now or ns.Utils.ServerTime()
    for minutes = from, from + Arena.CHEST_EVERY do
        if Arena.StartClearOfChest(now + minutes * 60, now, realmMinutes) then return minutes end
    end
    return from
end

-- Realm time of day ("18:30") `minutes` from now, or nil
function Arena.RealmClock(minutes, realmMinutes)
    realmMinutes = realmMinutes or Arena.RealmMinutes()
    if not realmMinutes then return nil end
    local at = (realmMinutes + math.floor(minutes)) % 1440
    return string.format("%02d:%02d", math.floor(at / 60), at % 60)
end

-- Minutes until the next chest, or nil
function Arena.MinutesToChest(realmMinutes)
    realmMinutes = realmMinutes or Arena.RealmMinutes()
    if not realmMinutes then return nil end
    local m = realmMinutes % Arena.CHEST_EVERY
    return m == 0 and 0 or Arena.CHEST_EVERY - m
end

-- /hh arena: where we are, to check and set the arena box in game
ns.SlashCommands:Register("arena", function()
    local where, mapID, x, y = Arena:PlayerWhere()
    local position = x and string.format("%.1f, %.1f", x * 100, y * 100) or "?"
    ns:Print(string.format(L.ARENA_WHERE, ns.Utils.MapName(mapID) or tostring(mapID), position,
        where == "pit" and L.ARENA_IN_PIT or (where == "arena" and L.ARENA_IN_ARENA or L.ARENA_OUTSIDE)))
end, L.HELP_ARENA)
