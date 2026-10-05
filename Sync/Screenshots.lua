-- HH-132: a screenshot of our PvP deaths and catches, for the HeadHunter admins.
--
-- Off by default, and only with HeadHunter Sync (its HeadHunter_Data addon is
-- installed): the app finds each picture in the game's Screenshots folder by the time
-- in its name, turns it into a small webp, uploads it and deletes the original. The
-- pictures are seen only in the website's admin panel.
--
-- A picture is taken right after:
--   - our PvP death, when the killer is WANTED, a bully or a Deadbeat, or the kill was
--     a coward's (no picture of a fair death)
--   - our catch of a WANTED player (HH_JUSTICE_ADDED, origin "local")
--   - our kill of a bully or a Deadbeat (HH_SHAME_KILLED)
-- One per killer or outlaw for WINDOW (a camp or a long fight gives one), at most
-- DAY_CAP a day, and events within MERGE seconds share one picture. Each picture is
-- taken at the lowest jpeg quality; the player's own setting comes back once the game
-- wrote the file.
--
-- ns.db.screenshots (per home) = {
--   shots = { { t, file, kinds = { "death" }, refs = { report id / catch id }, target,
--               hunter, mapID }, ... }  oldest first, read by the sync app
--   last  = { ["death:<killer>" / "catch:<outlaw>"] = t },
--   day   = { key = "YYYY-MM-DD", count = n } }

local addonName, ns = ...

local Screenshots = ns:RegisterModule("Screenshots", {})

local OWNER = "Screenshots"

Screenshots.WINDOW = 3600        -- one picture per killer or outlaw this often
Screenshots.DAY_CAP = 20         -- pictures a day, all kinds together
Screenshots.MERGE = 5            -- seconds: events this close share one picture
Screenshots.KEEP = 7 * 86400     -- the app uploads them long before
Screenshots.MAX_SHOTS = 100
Screenshots.QUALITY = 1          -- jpeg quality 1..10 (10 is about 6 times bigger)
Screenshots.RESTORE_AFTER = 5    -- seconds: put the quality back even without an event
Screenshots.FILE_PREFIX = "WoWScrnShot_"
Screenshots.FILE_TIME = "%m%d%y_%H%M%S" -- the game names the file by the PC's local time

Screenshots.KIND = { death = "death", wanted = "wanted", bully = "bully", deadbeat = "deadbeat" }

local QUALITY_SETTING = "screenshotQuality"
local SHOT_EVENTS = { "SCREENSHOT_SUCCEEDED", "SCREENSHOT_FAILED" }

local ownQuality             -- the player's quality while ours is set

local function Store()
    local db = ns.db
    if not db then return nil end
    local store = db.screenshots
    if type(store) ~= "table" then return nil end
    store.shots = store.shots or {}
    store.last = store.last or {}
    store.day = store.day or {}
    return store
end

local function GetSetting(name)
    local get = (C_CVar and C_CVar.GetCVar) or GetCVar
    return get and get(name)
end

local function SetSetting(name, value)
    local set = (C_CVar and C_CVar.SetCVar) or SetCVar
    return set ~= nil and pcall(set, name, value)
end

-- HeadHunter Sync wrote its HeadHunter_Data addon at least once
function Screenshots.SyncInstalled()
    return type(_G.HeadHunter_SiteData) == "table"
end

function Screenshots:Enabled()
    return ns.Database:GetSetting("screenshots") == true and Screenshots.SyncInstalled()
        and _G.Screenshot ~= nil
end

local function RestoreQuality()
    if ownQuality == nil then return end
    SetSetting(QUALITY_SETTING, ownQuality)
    ownQuality = nil
end

local function DayKey()
    return date("%Y-%m-%d")
end

function Screenshots:Prune(now)
    local store = Store()
    if not store then return end
    now = now or ns.Utils.ServerTime()
    local kept = {}
    for _, shot in ipairs(store.shots) do
        if type(shot) == "table" and (tonumber(shot.t) or 0) >= now - self.KEEP then kept[#kept + 1] = shot end
    end
    for i = 1, #kept - self.MAX_SHOTS do table.remove(kept, 1) end
    store.shots = kept
    for key, t in pairs(store.last) do
        if (tonumber(t) or 0) < now - self.WINDOW then store.last[key] = nil end
    end
end

-- Take a picture for this event, or add the event to one just taken. kind: KIND;
-- group: "death" or "catch" (which hour window); target: the killer's or outlaw's key;
-- ref: the death report or catch id. Returns the shot, or nil when no picture is due.
function Screenshots:Take(kind, group, target, ref)
    if not (target and self:Enabled()) then return nil end
    local store = Store()
    if not store then return nil end
    local now = ns.Utils.ServerTime()

    local latest = store.shots[#store.shots]
    if latest and now - (tonumber(latest.t) or 0) <= self.MERGE then
        latest.kinds[#latest.kinds + 1] = kind
        latest.refs[#latest.refs + 1] = ref
        store.last[group .. ":" .. target] = now
        return latest
    end

    local windowKey = group .. ":" .. target
    if store.last[windowKey] and now - store.last[windowKey] < self.WINDOW then return nil end
    local day = DayKey()
    if store.day.key ~= day then store.day.key, store.day.count = day, 0 end
    if store.day.count >= self.DAY_CAP then return nil end

    ownQuality = ownQuality or GetSetting(QUALITY_SETTING)
    SetSetting(QUALITY_SETTING, tostring(self.QUALITY))
    local ok = pcall(_G.Screenshot)
    if not ok then
        RestoreQuality()
        return nil
    end
    C_Timer.After(self.RESTORE_AFTER, RestoreQuality)

    local shot = {
        t = now, file = self.FILE_PREFIX .. date(self.FILE_TIME), kinds = { kind }, refs = { ref },
        target = target, hunter = ns.Utils.UnitKey("player"), mapID = ns.Utils.PlayerMapID(),
    }
    store.shots[#store.shots + 1] = shot
    store.last[windowKey] = now
    store.day.count = store.day.count + 1
    self:Prune(now)
    ns:Debug("Screenshot", kind, target, shot.file)
    return shot
end

-- Our death is worth a picture when the killer is hunted or listed, or it was a coward's
function Screenshots.DeathMatters(report)
    if report.classification == "coward" then return true end
    local key = report.killer and report.killer.key
    if not key then return false end
    local entry = ns.Wanted:ByKey(key)
    if ns.Wanted.Hunted(entry) or (entry and entry.badges and entry.badges.coward) then return true end
    return ns.Bounties:IsBlocked(key) and true or false
end

function Screenshots:OnDeathRecorded(report)
    if report.confidence == "sim" or report.demo then return end
    if not Screenshots.DeathMatters(report) then return end
    self:Take(self.KIND.death, "death", report.killer.key, report.id)
end

function Screenshots:OnJustice(record)
    if record.origin ~= "local" or record.demo then return end
    self:Take(self.KIND.wanted, "catch", record.outlaw, record.id)
end

function Screenshots:OnShameKilled(entry, kind)
    local target = entry and (entry.key or entry.id)
    self:Take(kind == "deadbeat" and self.KIND.deadbeat or self.KIND.bully, "catch", target, nil)
end

ns.Events:Register("HH_INITIALIZED", function()
    local Events = ns.Events
    Events:Register("HH_DEATH_RECORDED", function(_, report) Screenshots:OnDeathRecorded(report) end, OWNER)
    Events:Register("HH_JUSTICE_ADDED", function(_, record) Screenshots:OnJustice(record) end, OWNER)
    Events:Register("HH_SHAME_KILLED", function(_, entry, kind) Screenshots:OnShameKilled(entry, kind) end, OWNER)
    for _, event in ipairs(SHOT_EVENTS) do
        Events:Register(event, RestoreQuality, OWNER)
    end
    Screenshots:Prune()
end, OWNER)
