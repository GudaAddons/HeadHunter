-- HH-042: a WANTED outlaw shows up on a nameplate, as target, under the mouse or as
-- a party member's target.
--
--   WANTED · Ganker Wiadro is here! (?? Dwarf Rogue) · Coward
--
-- Driven by HH_ENEMY_SEEN from the enemy cache, so it inherits its rules: hostile
-- players only, nothing inside instances, and a 2 s refresh throttle per GUID.
-- The same outlaw alerts again at most every THROTTLE seconds.
-- Level window (docs/addon/features.md section 4) deferred on purpose (tickets HH-043).

local addonName, ns = ...
local L = ns.L

local Sighting = ns:RegisterModule("Sighting", {})

local OWNER = "Sighting"

Sighting.THROTTLE = 120

-- The WANTED entry for an enemy record: by key, or by GUID for Forever outlaws
-- still known only by their given name
function Sighting.WantedEntry(record)
    local Wanted = ns.Wanted
    local entry = record.key and Wanted:ByKey(record.key)
    if (not entry or not entry.wanted) and record.guid then
        entry = Wanted:Get("guid:" .. record.guid)
    end
    return entry and entry.wanted and entry or nil
end

local function Describe(record)
    local level = record.level == -1 and "??" or (record.level and tostring(record.level)) or "?"
    local parts = { level }
    if record.race then parts[#parts + 1] = record.race end
    if record.class then parts[#parts + 1] = record.class:sub(1, 1) .. record.class:sub(2):lower() end
    return table.concat(parts, " ")
end

function Sighting:OnEnemySeen(record, source)
    if source == "sim" or source == "fallback" then return end
    local entry = self.WantedEntry(record)
    if not entry then return end

    local Wanted = ns.Wanted
    local name = ns.Utils.DisplayName(record.key) or entry.name
    local badges = Wanted.BadgeNames(entry)
    local suffix = badges ~= "" and (" · " .. badges) or ""
    local text = string.format(L.SIGHTING_TEXT, Wanted.RankName(entry.rank), name)
    local chat = string.format(L.SIGHTING_CHAT, Wanted.RankName(entry.rank), name, Describe(record),
        math.floor(entry.kills), Wanted.TimeLeft(entry)) .. suffix

    ns.Alerts:Show({
        key = "seen:" .. entry.id,
        throttle = self.THROTTLE,
        text = text,
        chat = chat,
        sound = true,
    })
end

ns.Events:Register("HH_INITIALIZED", function()
    ns.Events:Register("HH_ENEMY_SEEN", function(_, record, source) Sighting:OnEnemySeen(record, source) end, OWNER)
end, OWNER)
