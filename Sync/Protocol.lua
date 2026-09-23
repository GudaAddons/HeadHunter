-- HH-021: wire format. Pure string functions, no WoW API, offline-tested.
--
-- One addon message (<= 255 bytes) carries records of ONE type:
--   "1" <faction A|H> <type char> ":" record ( "~" record )*
-- Fields inside a record are separated by ";", sub-fields by ",".
-- Utils.PlayerKey rejects names containing ; , ~ | : so they never collide.
-- Numbers are base36. A version other than "1" is ignored (forward compatible).
--
-- Types (docs/addon/tickets.md, HH-021):
--   D  death report          (HH-022)
--   G  identity: GUID -> full key for a report killer/assist that was incomplete
--   Q  WANTED query          (HH-023, later)
--   S  WANTED snapshot chunk (HH-023, later)
--   J  posse join            (HH-044, later)
--   P  hotspot ping          (HH-045, later)

local addonName, ns = ...

local Protocol = ns:RegisterModule("Protocol", {})

Protocol.VERSION = "1"
Protocol.MAX_MESSAGE = 255
Protocol.MAX_ASSISTS = 4

Protocol.TYPES = {
    DEATH = "D", IDENTITY = "G", QUERY = "Q", SNAPSHOT = "S", POSSE = "J", HOTSPOT = "P",
    JUSTICE = "K", -- a WANTED outlaw killed by a HeadHunter or their group (HH-048)
    PING = "T", -- /hh sync ping: manual connectivity test
}

local FACTION_CODE = { Alliance = "A", Horde = "H" }
local FACTION_NAME = { A = "Alliance", H = "Horde" }
Protocol.FACTION_CODE = FACTION_CODE

local CLASS_CODE = {
    WARRIOR = "W", PALADIN = "P", HUNTER = "H", ROGUE = "R", PRIEST = "I",
    SHAMAN = "S", MAGE = "M", WARLOCK = "L", DRUID = "D",
}
local RACE_CODE = {
    Human = "H", Dwarf = "D", NightElf = "N", Gnome = "G", Draenei = "E",
    Orc = "O", Scourge = "U", Tauren = "T", Troll = "R", BloodElf = "B",
}
-- "s": simulated death sent on purpose for two-character testing (/hh sim send)
local CONFIDENCE_CODE = { exact = "e", inferred = "i", sim = "s" }

local function Invert(t)
    local out = {}
    for k, v in pairs(t) do out[v] = k end
    return out
end
local CLASS_NAME, RACE_NAME, CONFIDENCE_NAME = Invert(CLASS_CODE), Invert(RACE_CODE), Invert(CONFIDENCE_CODE)

-------------------------------------------------
-- Primitives
-------------------------------------------------

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

function Protocol.ToB36(n)
    n = math.floor(tonumber(n) or 0)
    if n <= 0 then return "0" end
    local out = {}
    while n > 0 do
        local d = n % 36
        table.insert(out, 1, DIGITS:sub(d + 1, d + 1))
        n = math.floor(n / 36)
    end
    return table.concat(out)
end

function Protocol.FromB36(s)
    if type(s) ~= "string" or s == "" or not s:match("^[0-9a-z]+$") or #s > 10 then return nil end
    return tonumber(s, 36)
end

-- Split keeping empty fields ("a;;b" -> {"a", "", "b"})
function Protocol.Split(s, sep)
    local out = {}
    local pos = 1
    while true do
        local i = s:find(sep, pos, true)
        if not i then
            out[#out + 1] = s:sub(pos)
            return out
        end
        out[#out + 1] = s:sub(pos, i - 1)
        pos = i + 1
    end
end
local Split = Protocol.Split

local function Blank(v)
    return v == nil or v == ""
end

-- Level: "" unknown, "s" skull, else base36
local function EncodeLevel(level)
    if level == -1 then return "s" end
    if not level then return "" end
    return Protocol.ToB36(level)
end

local function DecodeLevel(s)
    if s == "s" then return -1 end
    if Blank(s) then return nil end
    local level = Protocol.FromB36(s)
    if not level or level < 1 or level > 100 then return false end
    return level
end

-- Position 0..1 -> 0..999
local function EncodeCoord(v)
    if not v then return "" end
    return Protocol.ToB36(math.max(0, math.min(999, math.floor(v * 1000))))
end

local function DecodeCoord(s)
    if Blank(s) then return nil end
    local n = Protocol.FromB36(s)
    return n and n <= 999 and n / 1000 or nil
end

-------------------------------------------------
-- Enemy: key-or-name , incomplete , level , class , race , sex , guid
-- The GUID is only sent for incomplete (given-name-only) entries, which need it
-- to be completed later.
-------------------------------------------------

local function EncodeEnemy(enemy)
    local incomplete = enemy.nameIncomplete and not enemy.key
    return table.concat({
        enemy.key or enemy.name or "",
        incomplete and "1" or "",
        EncodeLevel(enemy.level),
        CLASS_CODE[enemy.class] or "",
        RACE_CODE[enemy.race] or "",
        (enemy.sex == 2 or enemy.sex == 3) and tostring(enemy.sex) or "",
        incomplete and (enemy.guid or "") or "",
    }, ",")
end

local function DecodeEnemy(s)
    local f = Split(s, ",")
    if #f ~= 7 or Blank(f[1]) then return nil end
    local level = DecodeLevel(f[3])
    if level == false then return nil end
    local enemy = {
        level = level,
        class = CLASS_NAME[f[4]],
        race = RACE_NAME[f[5]],
        sex = tonumber(f[6]),
    }
    if f[2] == "1" then
        if Blank(f[7]) then return nil end
        enemy.name = f[1]
        enemy.nameIncomplete = true
        enemy.guid = f[7]
    else
        enemy.key = f[1]
        enemy.name = f[1]
    end
    return enemy
end

-------------------------------------------------
-- Death report:
--   t ; victimKey ; victimLevel ; victimClass ; victimRace ; mapID ; x ; y ;
--   confidence ; layer ; killer ; assist ; assist ...
-------------------------------------------------

local KILLER_FIELD = 11

function Protocol.EncodeDeath(report, maxLength)
    maxLength = maxLength or (Protocol.MAX_MESSAGE - 4)
    local v = report.victim
    local fields = {
        Protocol.ToB36(report.t),
        v.key,
        EncodeLevel(v.level),
        CLASS_CODE[v.class] or "",
        RACE_CODE[v.race] or "",
        report.mapID and Protocol.ToB36(report.mapID) or "",
        EncodeCoord(report.x),
        EncodeCoord(report.y),
        CONFIDENCE_CODE[report.confidence] or "i",
        report.layer and Protocol.ToB36(report.layer) or "",
        EncodeEnemy(report.killer),
    }
    local base = table.concat(fields, ";")
    if #base > maxLength then return nil end
    -- Assists are optional: add as many as fit
    local out = base
    for i = 1, math.min(#(report.assists or {}), Protocol.MAX_ASSISTS) do
        local candidate = out .. ";" .. EncodeEnemy(report.assists[i])
        if #candidate > maxLength then break end
        out = candidate
    end
    return out
end

-- Returns a report table, or nil for anything malformed
function Protocol.DecodeDeath(s)
    if type(s) ~= "string" then return nil end
    local f = Split(s, ";")
    if #f < KILLER_FIELD then return nil end
    local t = Protocol.FromB36(f[1])
    local victimLevel = DecodeLevel(f[3])
    if not t or Blank(f[2]) or not victimLevel or victimLevel == -1 then return nil end
    local killer = DecodeEnemy(f[KILLER_FIELD])
    if not killer then return nil end
    local report = {
        t = t,
        victim = { key = f[2], level = victimLevel, class = CLASS_NAME[f[4]], race = RACE_NAME[f[5]] },
        mapID = Protocol.FromB36(f[6]),
        x = DecodeCoord(f[7]),
        y = DecodeCoord(f[8]),
        confidence = CONFIDENCE_NAME[f[9]] or "inferred",
        layer = Protocol.FromB36(f[10]),
        killer = killer,
        assists = {},
    }
    for i = KILLER_FIELD + 1, math.min(#f, KILLER_FIELD + Protocol.MAX_ASSISTS) do
        local assist = DecodeEnemy(f[i])
        if assist then report.assists[#report.assists + 1] = assist end
    end
    report.id = report.victim.key .. ":" .. t
    return report
end

-------------------------------------------------
-- Identity: reportId ; guid ; key ; level ; class ; race ; sex
-------------------------------------------------

function Protocol.EncodeIdentity(reportId, enemy)
    return table.concat({
        reportId, enemy.guid or "", enemy.key or "", EncodeLevel(enemy.level),
        CLASS_CODE[enemy.class] or "", RACE_CODE[enemy.race] or "",
        (enemy.sex == 2 or enemy.sex == 3) and tostring(enemy.sex) or "",
    }, ";")
end

function Protocol.DecodeIdentity(s)
    if type(s) ~= "string" then return nil end
    local f = Split(s, ";")
    if #f ~= 7 or Blank(f[1]) or Blank(f[2]) or Blank(f[3]) then return nil end
    local level = DecodeLevel(f[4])
    if level == false then return nil end
    return f[1], {
        guid = f[2], key = f[3], level = level,
        class = CLASS_NAME[f[5]], race = RACE_NAME[f[6]], sex = tonumber(f[7]),
    }
end

-------------------------------------------------
-- Posse join: outlawId ; mapID ; time ; layer   (the sender is the member)
-------------------------------------------------

function Protocol.EncodePosse(outlawId, mapID, t, layer)
    return table.concat({ outlawId, mapID and Protocol.ToB36(mapID) or "", Protocol.ToB36(t),
        layer and Protocol.ToB36(layer) or "" }, ";")
end

-- Returns outlawId, mapID, time, layer
function Protocol.DecodePosse(s)
    if type(s) ~= "string" then return nil end
    local f = Split(s, ";")
    if #f ~= 4 or Blank(f[1]) then return nil end
    local t = Protocol.FromB36(f[3])
    if not t then return nil end
    return f[1], Protocol.FromB36(f[2]), t, Protocol.FromB36(f[4])
end

-------------------------------------------------
-- Justice: outlawId ; time ; mapID ; killer (who landed the blow, display only).
-- The sender is the hunter who saw it (the killer or in their group).
-------------------------------------------------

function Protocol.EncodeJustice(outlawId, t, mapID, killer)
    return table.concat({ outlawId, Protocol.ToB36(t), mapID and Protocol.ToB36(mapID) or "", killer or "" }, ";")
end

-- Returns outlawId, time, mapID, killer (nil when blank)
function Protocol.DecodeJustice(s)
    if type(s) ~= "string" then return nil end
    local f = Split(s, ";")
    if #f ~= 4 or Blank(f[1]) then return nil end
    local t = Protocol.FromB36(f[2])
    if not t then return nil end
    return f[1], t, Protocol.FromB36(f[3]), not Blank(f[4]) and f[4] or nil
end

-------------------------------------------------
-- Hotspot ping: mapID ; time ; x ; y ; enemyIds (comma separated short ids)
-- The sender is the HeadHunter in PvP combat there.
-------------------------------------------------

Protocol.MAX_PING_ENEMIES = 12

function Protocol.EncodeHotspot(mapID, t, x, y, enemyIds)
    local ids = {}
    for i = 1, math.min(#enemyIds, Protocol.MAX_PING_ENEMIES) do
        local id = tostring(enemyIds[i]):gsub("[^%w]", "")
        ids[#ids + 1] = id
    end
    return table.concat({ Protocol.ToB36(mapID), Protocol.ToB36(t), EncodeCoord(x), EncodeCoord(y),
        table.concat(ids, ",") }, ";")
end

-- Returns mapID, time, x, y, enemyIds
function Protocol.DecodeHotspot(s)
    if type(s) ~= "string" then return nil end
    local f = Split(s, ";")
    if #f ~= 5 then return nil end
    local mapID, t = Protocol.FromB36(f[1]), Protocol.FromB36(f[2])
    if not mapID or not t then return nil end
    local ids = {}
    if f[5] ~= "" then
        for id in f[5]:gmatch("[^,]+") do
            if #ids < Protocol.MAX_PING_ENEMIES and id:match("^%w+$") then ids[#ids + 1] = id end
        end
    end
    return mapID, t, DecodeCoord(f[3]), DecodeCoord(f[4]), ids
end

-------------------------------------------------
-- Messages
-------------------------------------------------

function Protocol.Header(factionCode, typeCode)
    return Protocol.VERSION .. factionCode .. typeCode .. ":"
end

-- Pack records into as few messages as possible, in order. Returns the messages
-- and, per message, how many input records it consumed (so a caller that can only
-- send some of the messages knows how many records went out). A record that cannot
-- fit even alone is consumed without being sent (callers keep records far below
-- the limit).
-- maxLength defaults to MAX_MESSAGE (channel chat text passes less: its marker
-- takes room).
function Protocol.Pack(factionCode, typeCode, records, maxLength)
    maxLength = maxLength or Protocol.MAX_MESSAGE
    local header = Protocol.Header(factionCode, typeCode)
    local messages, consumed = {}, {}
    local current, count = nil, 0
    for _, record in ipairs(records) do
        if #header + #record > maxLength then
            count = count + 1
        elseif current and #current + 1 + #record <= maxLength then
            current = current .. "~" .. record
            count = count + 1
        else
            if current then
                messages[#messages + 1], consumed[#consumed + 1] = current, count
                count = 0
            end
            current = header .. record
            count = count + 1
        end
    end
    if current then
        messages[#messages + 1], consumed[#consumed + 1] = current, count
    elseif count > 0 and #consumed > 0 then
        consumed[#consumed] = consumed[#consumed] + count
    end
    return messages, consumed
end

-- Returns faction name, type code, records; or nil for anything we do not speak
function Protocol.Unpack(message)
    if type(message) ~= "string" or #message > Protocol.MAX_MESSAGE then return nil end
    local version, factionCode, typeCode, body = message:match("^(%d)([AH])(%u):(.*)$")
    if version ~= Protocol.VERSION or not body or body == "" then return nil end
    return FACTION_NAME[factionCode], typeCode, Split(body, "~")
end
