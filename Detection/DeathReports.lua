-- HH-013: the death report pipeline.
--
-- Detectors (EraDeaths, ForeverDeaths) and the simulator fire
--   HH_DEATH_REPORT(report, source)
-- This module completes and validates the report, classifies the kill (HH-014),
-- stores it in ns.db.deaths, prints one chat line and fires
--   HH_DEATH_RECORDED(report)
-- which sync (M2) and the rules (M3) consume.
--
-- Report shape:
--   id          "<victim key>:<server time>" (sim reports add a suffix)
--   t           server time of the death (seconds)
--   victim      { key, level, class, race }
--   killer      enemy { key?, guid?, name, nameIncomplete?, level?, levelMin?, class?, race?, sex?, guild? }
--   assists     array of enemies
--   mapID, x, y where it happened
--   confidence  "exact" | "inferred" | "sim"
--   classification  "coward" | "fair" | "giant" | "normal" | "unknown"

local addonName, ns = ...
local L = ns.L

local DeathReports = ns:RegisterModule("DeathReports", {})

local OWNER = "DeathReports"

local function VictimSnapshot()
    local U = ns.Utils
    return {
        key = U.UnitKey("player"),
        level = U.UnitLevel("player"),
        class = U.UnitClass("player"),
        race = U.UnitRace("player"),
    }
end

-- Enemy entry from a cache record, a partial (GUID-only) entry, or nothing
function DeathReports.EnemyFromCache(guid, fallbackName)
    local cache = ns.EnemyCache
    local record = cache:ByGUID(guid)
    if record then
        return {
            key = record.key, guid = guid, name = record.key,
            level = record.level, levelMin = record.levelMin,
            class = record.class, race = record.race, sex = record.sex, guild = record.guild,
        }
    end
    local part = cache:PartialByGUID(guid)
    local given = (part and part.givenName) or (fallbackName and fallbackName:match("^([^%-]+)"))
    return {
        guid = guid,
        name = given or "?",
        nameIncomplete = true,
        class = part and part.class, race = part and part.race, sex = part and part.sex,
    }
end

-- Enemy entry from a full cache record (used by the inferred fallback)
function DeathReports.EnemyFromRecord(record)
    return {
        key = record.key, guid = record.guid, name = record.key,
        level = record.level, levelMin = record.levelMin,
        class = record.class, race = record.race, sex = record.sex, guild = record.guild,
    }
end

-- "60 Night Elf Hunter", with the skull icon for a skull level
local function Describe(enemy)
    local parts = { ns.Utils.LevelText(enemy.level) }
    if enemy.race then parts[#parts + 1] = ns.Utils.RaceName(enemy.race) end
    if enemy.class then parts[#parts + 1] = enemy.class:sub(1, 1) .. enemy.class:sub(2):lower() end
    return table.concat(parts, " ")
end
DeathReports.Describe = Describe

local function DisplayName(enemy)
    if enemy.key then return ns.Utils.DisplayName(enemy.key) end
    return enemy.name or "?"
end
DeathReports.DisplayName = DisplayName

function DeathReports:Find(id)
    for _, report in ipairs(ns.db.deaths) do
        if report.id == id then return report end
    end
    return nil
end

function DeathReports:Record(report, source)
    if not ns.db or type(report) ~= "table" or type(report.killer) ~= "table" then return nil end
    local U = ns.Utils

    report.t = math.floor(tonumber(report.t) or U.ServerTime())
    report.victim = report.victim or VictimSnapshot()
    if not report.victim.key then
        ns:Debug("Death report dropped: victim key unknown")
        return nil
    end
    report.id = report.id or (report.victim.key .. ":" .. report.t)
    if self:Find(report.id) then
        ns:Debug("Death report already recorded:", report.id)
        return nil
    end
    report.assists = report.assists or {}
    if not report.mapID then
        report.mapID = U.PlayerMapID()
        report.x, report.y = U.PlayerPosition(report.mapID)
    end
    report.layer = report.layer or ns.Layer:Current()
    report.confidence = report.confidence or source or "inferred"
    report.classification = ns.Classify.Report(report)

    table.insert(ns.db.deaths, report)
    ns.Database:Prune()

    ns:Debug("Death recorded", report.id, "killer", DisplayName(report.killer), report.confidence, report.classification)
    local tag = ns.Classify.ReportLabel(report)
    ns:Print(string.format(L.DEATH_RECORDED, DisplayName(report.killer), Describe(report.killer), tag))
    ns.Events:Fire("HH_DEATH_RECORDED", report)
    return report
end

-- A GUID got its full identity: complete an enemy entry that only had the given
-- name. record: { guid, key, level?, levelMin?, class?, race?, sex? }
local function Complete(enemy, record)
    if not enemy or not record.guid or enemy.guid ~= record.guid or not enemy.nameIncomplete then return false end
    enemy.key = record.key
    enemy.name = record.key
    enemy.nameIncomplete = nil
    enemy.level = enemy.level or record.level
    enemy.levelMin = enemy.levelMin or record.levelMin
    enemy.class = enemy.class or record.class
    enemy.race = enemy.race or record.race
    enemy.sex = enemy.sex or record.sex
    return true
end
DeathReports.CompleteEnemy = Complete

-- Own reports are the same tables in ns.db.reports (Sync/Reports.lua), which may
-- complete them first. So "this report involves the GUID" decides, not "I changed it".
local function Involves(report, guid)
    if report.killer and report.killer.guid == guid then return true end
    for _, assist in ipairs(report.assists or {}) do
        if assist.guid == guid then return true end
    end
    return false
end
DeathReports.Involves = Involves

function DeathReports:OnEnemyResolved(guid, record)
    for _, report in ipairs(ns.db.deaths) do
        Complete(report.killer, record)
        for _, assist in ipairs(report.assists or {}) do
            Complete(assist, record)
        end
        if Involves(report, guid) then
            report.classification = ns.Classify.Report(report)
            ns:Debug("Death report completed", report.id, "->", record.key)
            ns.Events:Fire("HH_DEATH_UPDATED", report)
        end
    end
end

ns.Events:Register("HH_INITIALIZED", function()
    ns.Events:Register("HH_DEATH_REPORT", function(_, report, source)
        DeathReports:Record(report, source)
    end, OWNER)
    ns.Events:Register("HH_ENEMY_RESOLVED", function(_, guid, record)
        DeathReports:OnEnemyResolved(guid, record)
    end, OWNER)
end, OWNER)

ns.SlashCommands:Register("deaths", function(args)
    local deaths = ns.db and ns.db.deaths or {}
    local count = math.min(tonumber(args[1]) or 10, #deaths)
    ns:Print(string.format(L.DEATHS_HEADER, #deaths))
    for i = #deaths, #deaths - count + 1, -1 do
        local r = deaths[i]
        print(string.format("  %s  %s (%s)  %s  %s%s", date("%m-%d %H:%M", r.t), DisplayName(r.killer),
            Describe(r.killer), ns.Classify.ReportLabel(r),
            ns.Utils.MapName(r.mapID) or "?", #r.assists > 0 and ("  +" .. #r.assists) or ""))
    end
end, L.HELP_DEATHS)
