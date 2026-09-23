-- HeadHunter_DB: account-wide state.
--
-- Runtime state lives in memory (ns.db). The SavedVariable is a best-effort mirror:
-- on Forever the client writes it at logout but does not load it back (docs/README.md
-- "Known bug"), so every module must work from an empty database on every load and
-- recover shared state from peers (HH-023).

local addonName, ns = ...

local DB = ns:RegisterModule("Database", {})

DB.SCHEMA_VERSION = 1

DB.LIMITS = {
    deaths = 500,
    deathMaxAgeDays = 30,
    enemies = 2000,
    enemyMaxAgeDays = 7,
}

local DEFAULTS = {
    schemaVersion = DB.SCHEMA_VERSION,
    meta = {
        createdAt = 0,
        lastLoadAt = 0,
        savedAt = 0,
        loadCount = 0,
    },
    settings = {
        debug = false,
        alerts = {
            enabled = true,
            sound = true,
            popups = true,
            range = "adjacent", -- "adjacent" | "continent"
            whisperInvite = true, -- Join on another layer: whisper the victim for an invite
        },
        serialKillerWindowMin = 15, -- 5..15
        mapPins = true, -- HH-046: hotspot and WANTED pins on the world map
        minimap = { angle = 200, hidden = false }, -- HH-060 minimap button
    },
    deaths = {},  -- array of death reports, oldest first (HH-013)
    reports = {}, -- report id -> report: own + peer deaths, grow-only (HH-022)
    enemies = {}, -- player key -> enemy record (HH-010)
    wanted = {},  -- player key -> WANTED state (HH-031)
    justice = {}, -- catch id -> WANTED outlaw killed by a HeadHunter or their group (HH-048)
    marks = { total = 0, events = {} }, -- HH-050
}

-- MIGRATIONS[n] upgrades a database from schema n-1 to n
local MIGRATIONS = {}

local DAY = 86400

function DB:Initialize()
    local Utils = ns.Utils
    local saved = HeadHunter_DB
    local restored = type(saved) == "table"
    local db = restored and saved or {}

    Utils.ApplyDefaults(db, DEFAULTS)
    self:Migrate(db)

    local now = Utils.ServerTime()
    if db.meta.createdAt == 0 then db.meta.createdAt = now end
    db.meta.lastLoadAt = now
    db.meta.loadCount = db.meta.loadCount + 1

    -- Lets /hh status and the probe report whether this client loaded SavedVariables
    self.restoredFromDisk = restored

    HeadHunter_DB = db
    ns.db = db
    ns.debugMode = db.settings.debug == true

    self:Prune(now)
    ns:Debug("Database ready. Restored from disk:", restored, "schema:", db.schemaVersion)
    return db
end

function DB:Migrate(db)
    local version = tonumber(db.schemaVersion) or 0
    if version > self.SCHEMA_VERSION then
        -- Written by a newer addon version: leave it untouched rather than guess
        ns:Debug("Database schema", version, "is newer than", self.SCHEMA_VERSION)
        return
    end
    for v = version + 1, self.SCHEMA_VERSION do
        if MIGRATIONS[v] then
            MIGRATIONS[v](db)
        end
    end
    db.schemaVersion = self.SCHEMA_VERSION
end

-- Drop old or excess records. Runs on load and logout.
function DB:Prune(now)
    local db = ns.db
    if not db then return end
    now = now or ns.Utils.ServerTime()
    local limits = self.LIMITS

    local minDeathTime = now - limits.deathMaxAgeDays * DAY
    local kept = {}
    for _, report in ipairs(db.deaths) do
        if type(report) == "table" and (tonumber(report.t) or 0) >= minDeathTime then
            kept[#kept + 1] = report
        end
    end
    local excess = #kept - limits.deaths
    if excess > 0 then
        local trimmed = {}
        for i = excess + 1, #kept do
            trimmed[#trimmed + 1] = kept[i]
        end
        kept = trimmed
    end
    db.deaths = kept

    local minSeen = now - limits.enemyMaxAgeDays * DAY
    local byAge = {}
    for key, enemy in pairs(db.enemies) do
        local seen = type(enemy) == "table" and tonumber(enemy.lastSeen) or 0
        if seen < minSeen then
            db.enemies[key] = nil
        else
            byAge[#byAge + 1] = { key = key, seen = seen }
        end
    end
    if #byAge > limits.enemies then
        table.sort(byAge, function(a, b) return a.seen < b.seen end)
        for i = 1, #byAge - limits.enemies do
            db.enemies[byAge[i].key] = nil
        end
    end
end

function DB:OnLogout()
    if not ns.db then return end
    self:Prune()
    ns.db.meta.savedAt = ns.Utils.ServerTime()
end

-------------------------------------------------
-- Settings: dotted paths, e.g. "alerts.range"
-------------------------------------------------

local function Resolve(path)
    local node = ns.db.settings
    local keys = {}
    for key in path:gmatch("[^%.]+") do
        keys[#keys + 1] = key
    end
    for i = 1, #keys - 1 do
        node = node[keys[i]]
        if type(node) ~= "table" then return nil end
    end
    return node, keys[#keys]
end

function DB:GetSetting(path)
    local node, key = Resolve(path)
    return node and node[key]
end

function DB:SetSetting(path, value)
    local node, key = Resolve(path)
    if not node then return false end
    node[key] = value
    ns.Events:Fire("HH_SETTING_CHANGED", path, value)
    return true
end
