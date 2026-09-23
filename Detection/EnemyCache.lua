-- HH-010: every enemy player we see, by player key and by GUID.
--
-- This is where a killer's FULL identity comes from. Death Recap (Forever) only
-- carries the given name and a GUID, and the combat log (Era) carries no level, so
-- the name, level, class, race and sex are taken from what nameplates, target,
-- mouseover and party targets showed before the death.
--
-- Records live in ns.db.enemies (key -> record, pruned by Core/Database.lua).
-- The GUID index is rebuilt from those records on load.

local addonName, ns = ...

local EnemyCache = ns:RegisterModule("EnemyCache", {})

local OWNER = "EnemyCache"

-- Minimum seconds between two refreshes of the same GUID from the same kind of source
local REFRESH_INTERVAL = 2

local byGUID = {}      -- guid -> record (records with a full key)
local partial = {}     -- guid -> { guid, givenName, class, race, sex, lastSeen } (key not known yet)
local lastRefresh = {} -- guid -> GetTime() of last unit refresh

local function Records()
    return ns.db and ns.db.enemies
end

function EnemyCache:RebuildIndex()
    wipe(byGUID)
    local records = Records()
    if not records then return end
    for _, record in pairs(records) do
        if type(record) == "table" and record.guid then
            byGUID[record.guid] = record
        end
    end
end

function EnemyCache:ByKey(key)
    local records = Records()
    return key and records and records[key]
end

function EnemyCache:ByGUID(guid)
    return guid and byGUID[guid]
end

-- Partial identity for a GUID seen only through the combat log / Death Recap
function EnemyCache:PartialByGUID(guid)
    return guid and partial[guid]
end

-- Store or refresh the record for key. fields may omit anything unknown; known
-- values are never overwritten with nil. Fires HH_ENEMY_RESOLVED the first time a
-- GUID gets a full key, and HH_ENEMY_SEEN on every sighting.
function EnemyCache:Upsert(key, fields, source)
    local records = Records()
    if not key or not records then return nil end
    local now = ns.Utils.ServerTime()

    local record = records[key]
    if not record then
        record = { key = key, firstSeen = now }
        records[key] = record
    end
    for field, value in pairs(fields) do
        if value ~= nil then record[field] = value end
    end
    record.lastSeen = now

    local guid = record.guid
    if guid and byGUID[guid] ~= record then
        byGUID[guid] = record
        if partial[guid] then
            partial[guid] = nil
        end
        ns.Events:Fire("HH_ENEMY_RESOLVED", guid, record)
    end

    ns.Events:Fire("HH_ENEMY_SEEN", record, source)
    return record
end

-- Read everything the client exposes about an enemy player unit
function EnemyCache:ObserveUnit(unit, source)
    if not ns.Guards:IsActive() then return nil end
    local U = ns.Utils
    if not U.UnitIsEnemyPlayer(unit) then return nil end

    local guid = U.UnitGUID(unit)
    local nowLocal = U.Now()
    if guid and lastRefresh[guid] and nowLocal - lastRefresh[guid] < REFRESH_INTERVAL then
        return byGUID[guid]
    end

    local key = U.UnitKey(unit)
    if not key then return nil end
    if guid then lastRefresh[guid] = nowLocal end

    local level = U.UnitLevel(unit)
    local levelMin
    if level == -1 then
        -- Skull: at least 10 levels above us
        local mine = U.UnitLevel("player")
        levelMin = mine and mine > 0 and (mine + 10) or nil
    end

    local mapID = U.PlayerMapID()
    return self:Upsert(key, {
        guid = guid,
        level = level,
        levelMin = levelMin,
        class = U.UnitClass(unit),
        race = U.UnitRace(unit),
        sex = U.UnitSex(unit) ~= 1 and U.UnitSex(unit) or nil,
        guild = U.UnitGuild(unit),
        faction = U.UnitFaction(unit),
        lastMapID = mapID,
    }, source)
end

-- A hostile player known only by GUID and a combat-log style name
-- ("Name", "Name-Realm"). Era: the name is the full identity, so a key is built.
-- Forever: the name is only the given name, so a partial entry is kept until the
-- GUID is seen on a unit.
function EnemyCache:ObserveGUID(guid, name, source)
    if not guid or not ns.Guards:IsActive() then return nil end
    local known = byGUID[guid]
    if known then return known end

    local U = ns.Utils
    -- A duel opponent is flagged hostile but is not an enemy
    if U.IsSameFactionGUID(guid) then return nil end
    local _, classFile, _, raceFile, sex, givenName = U.SafeCall(GetPlayerInfoByGUID, guid)
    classFile = U.AccessibleString(classFile)
    raceFile = U.AccessibleString(raceFile)
    sex = tonumber(U.Accessible(sex))
    if sex ~= 2 and sex ~= 3 then sex = nil end

    if not ns.Features.RealmlessNames then
        local key = U.PlayerKey(name)
        if key then
            return self:Upsert(key, { guid = guid, class = classFile, race = raceFile, sex = sex }, source)
        end
    end

    local given = U.AccessibleString(givenName)
    if not given then
        local cleaned = U.AccessibleString(name)
        given = cleaned and cleaned:match("^([^%-]+)")
    end
    local entry = partial[guid] or { guid = guid }
    entry.givenName = given or entry.givenName
    entry.class = classFile or entry.class
    entry.race = raceFile or entry.race
    entry.sex = sex or entry.sex
    entry.lastSeen = U.ServerTime()
    partial[guid] = entry
    return nil, entry
end

-- GUIDs of enemy players seen on a unit within `seconds`
function EnemyCache:RecentGUIDs(seconds)
    local now = ns.Utils.Now()
    local list = {}
    for guid, at in pairs(lastRefresh) do
        if now - at <= seconds and byGUID[guid] then list[#list + 1] = guid end
    end
    return list
end

-- Was this GUID seen on a unit (nameplate, target, mouseover...) within `seconds`?
function EnemyCache:SeenWithin(guid, seconds)
    local at = guid and lastRefresh[guid]
    return at ~= nil and ns.Utils.Now() - at <= seconds
end

-- Best guess at who is attacking us, for when no exact source exists
-- (Forever with an empty Death Recap). Order:
-- live hostile target, then the last hostile target within window, then the most
-- recently seen enemy.
function EnemyCache:LikelyAttacker(window)
    window = window or 10
    local U = ns.Utils
    if U.UnitIsEnemyPlayer("target") and not U.SafeCall(UnitIsDead, "target") then
        local record = self:ObserveUnit("target", "fallback")
        if record then return record end
    end
    local nowLocal = U.Now()
    if self.lastTarget and nowLocal - self.lastTarget.at <= window then
        return self.lastTarget.record
    end
    local newest, newestAt
    for guid, at in pairs(lastRefresh) do
        if nowLocal - at <= window and (not newestAt or at > newestAt) and byGUID[guid] then
            newest, newestAt = byGUID[guid], at
        end
    end
    return newest
end

-------------------------------------------------
-- Wiring
-------------------------------------------------

local function OnTargetChanged()
    local record = EnemyCache:ObserveUnit("target", "target")
    if record then
        EnemyCache.lastTarget = { record = record, at = ns.Utils.Now() }
    end
end

-- Party members' targets: an enemy a groupmate is fighting
local function OnUnitTarget(_, unit)
    if type(unit) == "string" and unit:match("^party%d$") then
        EnemyCache:ObserveUnit(unit .. "target", "party")
    end
end

ns.Events:Register("HH_INITIALIZED", function()
    local Events = ns.Events
    EnemyCache:RebuildIndex()
    Events:Register("NAME_PLATE_UNIT_ADDED", function(_, unit) EnemyCache:ObserveUnit(unit, "nameplate") end, OWNER)
    Events:Register("UPDATE_MOUSEOVER_UNIT", function() EnemyCache:ObserveUnit("mouseover", "mouseover") end, OWNER)
    Events:Register("PLAYER_TARGET_CHANGED", OnTargetChanged, OWNER)
    Events:Register("UNIT_TARGET", OnUnitTarget, OWNER)
end, OWNER)

ns.SlashCommands:Register("enemies", function()
    local list = {}
    for _, record in pairs(Records() or {}) do
        list[#list + 1] = record
    end
    table.sort(list, function(a, b) return (a.lastSeen or 0) > (b.lastSeen or 0) end)
    ns:Print(string.format(ns.L.ENEMIES_HEADER, #list))
    for i = 1, math.min(10, #list) do
        local r = list[i]
        print(string.format("  %s  %s %s %s", ns.Utils.DisplayName(r.key),
            r.level == -1 and "??" or tostring(r.level or "?"), r.race or "?", r.class or "?"))
    end
end, ns.L.HELP_ENEMIES)
