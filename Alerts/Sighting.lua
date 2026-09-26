-- HH-042: a WANTED outlaw shows up on a nameplate, as target, under the mouse or as
-- a party member's target.
--
--   WANTED · Ganker Wiadro is here! (?? Dwarf Rogue) · Coward
--
-- Driven by HH_ENEMY_SEEN from the enemy cache, so it inherits its rules: hostile
-- players only, nothing inside instances, and a 2 s refresh throttle per GUID.
-- The same outlaw alerts again at most every THROTTLE seconds. Shown at once even in
-- combat (author, 2026-09-23): the outlaw may be the one attacking us.
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
    if not Wanted.Hunted(entry) and record.guid then
        entry = Wanted:Get("guid:" .. record.guid)
    end
    return Wanted.Hunted(entry) and entry or nil
end

-- "60 Night Elf Hunter" (skull icon for a skull level)
local function Describe(record)
    return ns.DeathReports.Describe(record)
end

function Sighting:OnEnemySeen(record, source)
    if source == "sim" or source == "fallback" then return end
    local entry = self.WantedEntry(record)
    if not entry then return end

    local Wanted = ns.Wanted
    local name = ns.Utils.DisplayName(record.key) or entry.name
    local badges = Wanted.BadgeNames(entry)
    local suffix = badges ~= "" and (" · " .. badges) or ""
    -- The chat line stays with us (nothing is sent to other HeadHunters)
    local text, chat
    if entry.wanted then
        text = string.format(L.SIGHTING_TEXT, Wanted.RankName(entry.rank), name)
        chat = string.format(L.SIGHTING_CHAT, Wanted.RankName(entry.rank), name, Describe(record),
            math.floor(entry.kills)) .. suffix
    else
        text = string.format(L.SIGHTING_AT_LARGE, name)
        chat = string.format(L.SIGHTING_CHAT_AT_LARGE, name, Describe(record),
            Wanted.RankName(entry.lastRank), entry.killCount or 0) .. suffix
    end

    ns.Alerts:Show({
        key = "seen:" .. entry.id,
        throttle = self.THROTTLE,
        text = text,
        chat = chat,
        sound = true,
        combat = true, -- the outlaw may be the one we are fighting: tell us now
    })
end

ns.Events:Register("HH_INITIALIZED", function()
    ns.Events:Register("HH_ENEMY_SEEN", function(_, record, source) Sighting:OnEnemySeen(record, source) end, OWNER)
end, OWNER)
