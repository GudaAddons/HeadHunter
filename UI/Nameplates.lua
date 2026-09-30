-- Marks above players' heads, on their nameplates (author, 2026-09-30). Only HeadHunter
-- users see them. Side by side when a player has more than one:
--   wanted     the HeadHunter crosshair on a WANTED player, either faction
--   shame      a white feather on a Hall of Shame bully or Deadbeat (Alerts/Sighting.lua)
--   organizer  the sheriff's star on a tournament host (gold) or co-organizer (silver),
--              HH-128, Tournament/Organizers.lua
-- Nameplates for your own faction are off by default in the game, so marks on them
-- need friendly nameplates on. Shown when a nameplate appears, hidden when it goes, and
-- every REFRESH seconds the shown ones are checked again (WANTED and the organizers'
-- time window change while they are on screen). Nameplates the game keeps from addons
-- (IsForbidden) are skipped; everything runs in pcall.

local addonName, ns = ...

local Nameplates = ns:RegisterModule("Nameplates", {})

local OWNER = "Nameplates"

Nameplates.SIZE = 22
Nameplates.GAP = 2
Nameplates.REFRESH = 60

local function WantedEntry(unit)
    local U = ns.Utils
    local key = U.UnitKey(unit)
    local entry = key and ns.Wanted:ByKey(key)
    if entry then return entry end
    local guid = U.UnitGUID(unit)
    return guid and ns.Wanted:Get("guid:" .. guid)
end

-- In order, left to right. For(unit) -> true, r, g, b (0..1) to show, else nil
Nameplates.BADGES = {
    {
        id = "wanted",
        texture = "Interface\\AddOns\\HeadHunter\\Assets\\Textures\\mark",
        For = function(unit)
            if not ns.db or ns.db.settings.wantedMarks == false then return nil end
            local entry = WantedEntry(unit)
            if (entry and entry.wanted) or ns.Dev.TestMark("wanted", ns.Utils.UnitKey(unit)) then return true, 1, 1, 1 end
            return nil
        end,
    },
    {
        id = "shame",
        texture = "Interface\\AddOns\\HeadHunter\\Assets\\Textures\\feather",
        For = function(unit)
            if not ns.db or ns.db.settings.shameMarks == false then return nil end
            local entry = WantedEntry(unit)
            local key = ns.Utils.UnitKey(unit)
            if (entry and entry.badges and entry.badges.coward) or (key and ns.Bounties:IsBlocked(key))
                or ns.Dev.TestMark("shame", key) then
                return true, 1, 1, 1
            end
            return nil
        end,
    },
    {
        id = "organizer",
        texture = "Interface\\AddOns\\HeadHunter\\Assets\\Textures\\star",
        For = function(unit)
            local role = ns.Organizers:Enabled() and ns.Organizers:RoleOf(ns.Utils.UnitKey(unit))
            local color = role and ns.Organizers.COLORS[role]
            if color then return true, color[1] / 255, color[2] / 255, color[3] / 255 end
            return nil
        end,
    },
}

local function PlateFor(unit)
    local api = _G.C_NamePlate
    if not (api and api.GetNamePlateForUnit and unit) then return nil end
    local plate = ns.Utils.SafeCall(api.GetNamePlateForUnit, unit)
    if type(plate) ~= "table" or (plate.IsForbidden and plate:IsForbidden()) then return nil end
    return plate
end

-- The texture of one badge on one nameplate, made the first time
local function Texture(plate, badge)
    plate.hhBadges = rawget(plate, "hhBadges") or {}
    local texture = plate.hhBadges[badge.id]
    if not texture then
        texture = plate:CreateTexture(nil, "OVERLAY")
        texture:SetTexture(badge.texture)
        texture:SetSize(Nameplates.SIZE, Nameplates.SIZE)
        plate.hhBadges[badge.id] = texture
    end
    return texture
end

-- Shows the marks this unit has, centred in a row above its nameplate
function Nameplates:Update(unit)
    local plate = PlateFor(unit)
    if not plate then return end
    local isPlayer = ns.Utils.UnitIsPlayer(unit)
    local shown = {}
    for _, badge in ipairs(self.BADGES) do
        local show, r, g, b = false
        if isPlayer then show, r, g, b = badge.For(unit) end
        local existing = rawget(plate, "hhBadges") and plate.hhBadges[badge.id]
        if show then
            local texture = Texture(plate, badge)
            texture:SetVertexColor(r, g, b, 1)
            shown[#shown + 1] = texture
        elseif existing then
            existing:Hide()
        end
    end
    local width = #shown * self.SIZE + math.max(0, #shown - 1) * self.GAP
    for i, texture in ipairs(shown) do
        local x = -width / 2 + (i - 1) * (self.SIZE + self.GAP) + self.SIZE / 2
        texture:ClearAllPoints()
        texture:SetPoint("BOTTOM", plate, "TOP", x, 2)
        texture:Show()
    end
end

function Nameplates:Hide(unit)
    local plate = PlateFor(unit)
    for _, texture in pairs(plate and rawget(plate, "hhBadges") or {}) do texture:Hide() end
end

-- Every nameplate on screen again
function Nameplates:Refresh()
    local api = _G.C_NamePlate
    local plates = api and api.GetNamePlates and ns.Utils.SafeCall(api.GetNamePlates)
    for _, plate in ipairs(type(plates) == "table" and plates or {}) do
        local unit = rawget(plate, "namePlateUnitToken")
        if unit then self:Update(unit) end
    end
end

local function Safely(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then ns:Debug("Nameplate marks:", tostring(err)) end
end

-- Registered at load (they do nothing until the database is ready), so no new
-- HH_INITIALIZED handler changes the login order of the other modules
ns.Events:Register("NAME_PLATE_UNIT_ADDED", function(_, unit) Safely(Nameplates.Update, Nameplates, unit) end, OWNER)
ns.Events:Register("NAME_PLATE_UNIT_REMOVED", function(_, unit) Safely(Nameplates.Hide, Nameplates, unit) end, OWNER)

local function RefreshLoop()
    Safely(Nameplates.Refresh, Nameplates)
    C_Timer.After(Nameplates.REFRESH, RefreshLoop)
end
C_Timer.After(Nameplates.REFRESH, RefreshLoop)

-- /hh dev wanted | shame | clear (not in the help, only with HeadHunter_Dev): a test mark
-- on the target, see Core/Dev.lua
ns.SlashCommands:Register("dev", function(args)
    if not ns.Dev.Enabled() then return end
    local kind = args[1] and args[1]:lower()
    if kind == "clear" then
        ns.Dev.ClearTestMarks()
        print("HeadHunter dev: test marks cleared")
    elseif kind == "wanted" or kind == "shame" then
        local key = ns.Utils.UnitIsPlayer("target") and ns.Utils.UnitKey("target")
        if not key then
            print("HeadHunter dev: target a player first")
            return
        end
        local on = ns.Dev.ToggleTestMark(kind, key)
        print(string.format("HeadHunter dev: %s mark %s on %s", kind, on and "on" or "off", key))
    else
        print("HeadHunter dev: /hh dev wanted | shame | clear")
        return
    end
    Nameplates:Refresh()
end)
