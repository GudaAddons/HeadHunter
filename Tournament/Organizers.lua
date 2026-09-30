-- HH-128: a sheriff's star on tournament hosts and co-organizers (docs/addon/tickets.md).
-- Gold for the host, silver for co-organizers, on player tooltips, before their chat
-- lines and above their head (the nameplate: friendly nameplates must be on to see it
-- on your own faction). Only HeadHunter users see it. Who organizes comes only from the website data
-- (Sync/SiteData.lua: the tournaments HeadHunter Sync brought in), never from a player's
-- own addon message, which an edited addon could fake.
--
-- When (author, 2026-09-30): from 1 hour before the start (the lock), during the
-- tournament, until 30 minutes after it ends. The addon does not know the end yet (no
-- match results), so the star stops AFTER seconds after the start.
--
-- Organizers:RoleOf(key, now) -> "host" | "organizer", tournament; or nil
-- Organizers.Star(role, size) -> the star as chat and tooltip text (|T...|t)

local addonName, ns = ...
local L = ns.L

local Organizers = ns:RegisterModule("Organizers", {})

Organizers.BEFORE = 3600
Organizers.AFTER = 4 * 3600
Organizers.STAR = "Interface\\AddOns\\HeadHunter\\Assets\\Textures\\star"
-- The texture is white; the color tints it (the website's gold, and silver)
Organizers.COLORS = { host = { 230, 180, 34 }, organizer = { 192, 192, 192 } }
-- Chat where players talk; channels are left alone (Sync/Transport.lua filters its own)
Organizers.CHAT_EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_WHISPER", "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
}

function Organizers.Star(role, size)
    local color = Organizers.COLORS[role] or Organizers.COLORS.organizer
    size = size or 14
    return string.format("|T%s:%d:%d:0:0:64:64:0:64:0:64:%d:%d:%d|t",
        Organizers.STAR, size, size, color[1], color[2], color[3])
end

function Organizers:Enabled()
    return ns.db ~= nil and ns.db.settings.organizerMarks ~= false
end

local function InWindow(tournament, now)
    return tournament.startsAt and now >= tournament.startsAt - Organizers.BEFORE
        and now <= tournament.startsAt + Organizers.AFTER
end

-- The role of a player now: "host" before "organizer" when both
function Organizers:RoleOf(key, now)
    if not key then return nil end
    local U = ns.Utils
    now = now or U.ServerTime()
    local found, foundTournament
    for _, tournament in ipairs(ns.SiteData:Tournaments()) do
        if InWindow(tournament, now) then
            if U.SameCharacter(tournament.host, key) then return "host", tournament end
            for _, organizer in ipairs(tournament.organizers) do
                if not found and U.SameCharacter(organizer, key) then found, foundTournament = "organizer", tournament end
            end
        end
    end
    return found, foundTournament
end

-- "starts in 45 min" or "in progress"
function Organizers.Status(tournament, now)
    if now < tournament.startsAt then
        return string.format(L.TOURNAMENT_STARTS_IN, math.max(1, math.ceil((tournament.startsAt - now) / 60)))
    end
    return L.TOURNAMENT_IN_PROGRESS
end

-- The tooltip line for a player unit: { text, r, g, b } or nil
function Organizers:TooltipLine(unit, now)
    local U = ns.Utils
    if not self:Enabled() or not unit or not U.UnitIsPlayer(unit) then return nil end
    now = now or U.ServerTime()
    local role, tournament = self:RoleOf(U.UnitKey(unit), now)
    if not role then return nil end
    local format = role == "host" and L.TOOLTIP_TOURNAMENT_HOST or L.TOOLTIP_TOURNAMENT_ORGANIZER
    return { Organizers.Star(role) .. " " .. string.format(format, tournament.name, Organizers.Status(tournament, now)),
        1, 0.82, 0 }
end

-- Chat filter: the star before the message of a host or co-organizer
function Organizers.ChatFilter(_, _, message, author, ...)
    local U = ns.Utils
    if not Organizers:Enabled() or type(U.AccessibleString(message)) ~= "string" then return false end
    local role = Organizers:RoleOf(U.PlayerKey(U.AccessibleString(author)))
    if not role then return false end
    return false, Organizers.Star(role, 12) .. " " .. message, author, ...
end

-------------------------------------------------
-- Above the head (step 2): the star on the nameplate
-------------------------------------------------

Organizers.PLATE_SIZE = 22
Organizers.PLATE_REFRESH = 60 -- seconds: the star comes and goes with the time window

local function PlateFor(unit)
    local api = _G.C_NamePlate
    if not (api and api.GetNamePlateForUnit and unit) then return nil end
    local plate = ns.Utils.SafeCall(api.GetNamePlateForUnit, unit)
    -- Nameplates the game keeps from addons (some instances, WoW Forever in places)
    if type(plate) ~= "table" or (plate.IsForbidden and plate:IsForbidden()) then return nil end
    return plate
end

-- Shows or hides the star on one unit's nameplate
function Organizers:UpdatePlate(unit)
    local plate = PlateFor(unit)
    if not plate then return end
    local U = ns.Utils
    local role = self:Enabled() and U.UnitIsPlayer(unit) and self:RoleOf(U.UnitKey(unit))
    local star = rawget(plate, "hhStar")
    if not role then
        if star then star:Hide() end
        return
    end
    if not star then
        star = plate:CreateTexture(nil, "OVERLAY")
        star:SetTexture(Organizers.STAR)
        star:SetSize(Organizers.PLATE_SIZE, Organizers.PLATE_SIZE)
        star:SetPoint("BOTTOM", plate, "TOP", 0, 2)
        plate.hhStar = star
    end
    local color = Organizers.COLORS[role]
    star:SetVertexColor(color[1] / 255, color[2] / 255, color[3] / 255, 1)
    star:Show()
end

function Organizers:HidePlate(unit)
    local plate = PlateFor(unit)
    local star = plate and rawget(plate, "hhStar")
    if star then star:Hide() end
end

-- Every nameplate on screen again (the window opens and closes while they are shown)
function Organizers:RefreshPlates()
    local api = _G.C_NamePlate
    local plates = api and api.GetNamePlates and ns.Utils.SafeCall(api.GetNamePlates)
    for _, plate in ipairs(type(plates) == "table" and plates or {}) do
        local unit = rawget(plate, "namePlateUnitToken")
        if unit then self:UpdatePlate(unit) end
    end
end

local function Safely(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then ns:Debug("Organizer star:", tostring(err)) end
end

ns.Events:Register("NAME_PLATE_UNIT_ADDED", function(_, unit) Safely(Organizers.UpdatePlate, Organizers, unit) end, "Organizers")
ns.Events:Register("NAME_PLATE_UNIT_REMOVED", function(_, unit) Safely(Organizers.HidePlate, Organizers, unit) end, "Organizers")

local function RefreshLoop()
    Safely(Organizers.RefreshPlates, Organizers)
    C_Timer.After(Organizers.PLATE_REFRESH, RefreshLoop)
end
C_Timer.After(Organizers.PLATE_REFRESH, RefreshLoop)

-- /hh organizers (not in the help, a check like /hh probe): the tournaments from the
-- website data, their host and co-organizers, and how the addon sees the target
ns.SlashCommands:Register("organizers", function()
    local U = ns.Utils
    local now = U.ServerTime()
    local list = ns.SiteData:Tournaments()
    print(string.format("HeadHunter organizers: %d tournament(s) in the website data, marks %s",
        #list, Organizers:Enabled() and "on" or "off"))
    for _, t in ipairs(list) do
        print(string.format("  %s: starts in %d min, star window %s", t.name, math.floor((t.startsAt - now) / 60),
            InWindow(t, now) and "open" or "closed"))
        print("    host: " .. tostring(t.host) .. " (" .. tostring(U.CompactName(t.host)) .. ")")
        for _, key in ipairs(t.organizers) do
            print("    co-organizer: " .. tostring(key) .. " (" .. tostring(U.CompactName(key)) .. ")")
        end
    end
    local name, second = U.UnitName("target")
    local key = U.UnitKey("target")
    print(string.format("  target: name %s / %s, full %s, key %s (%s), role %s", tostring(name), tostring(second),
        tostring(U.AccessibleString(U.SafeCall(_G.GetUnitName, "target", true))), tostring(key),
        tostring(U.CompactName(key)), tostring((Organizers:RoleOf(key, now)))))
end)

-- Registered at load (the filter does nothing until the database is ready), so no new
-- HH_INITIALIZED handler changes the login order of the other modules
do
    local add = ChatFrame_AddMessageEventFilter or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
    if add then
        for _, event in ipairs(Organizers.CHAT_EVENTS) do
            pcall(add, event, Organizers.ChatFilter)
        end
    end
end
