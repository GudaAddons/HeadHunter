-- HH-103: the Create tournament dialog (Tournaments tab > Create).
--
-- Fields: name, format / bracket / series (dropdowns, UI/Select.lua), start in minutes (with
-- the realm time and the arena chest check shown live), minimum level, max teams.
-- The values live in TournamentDialog.values; the widgets only edit them, so the
-- offline tests fill the values and press Create. Create is a click: on Era the
-- announcement also goes realm-wide.

local addonName, ns = ...
local L = ns.L

local TournamentDialog = ns:RegisterModule("TournamentDialog", {})

TournamentDialog.WIDTH = 330
TournamentDialog.HEIGHT = 330
TournamentDialog.DEFAULT_MINUTES = 30

local FORMATS = { 1, 2, 3, 5 }
local BRACKETS = { "single", "robin" }
local SERIES = { 1, 3, 5 }

local frame
TournamentDialog.values = nil

function TournamentDialog.Defaults()
    local level = ns.Utils.UnitLevel("player")
    return {
        name = "", format = 1, bracket = "single", bestOf = 3,
        minutes = ns.Arena.FirstFreeMinutes(TournamentDialog.DEFAULT_MINUTES),
        minLevel = (level and level >= 1) and level or 1, maxTeams = 16,
    }
end

-- The options for Tournaments:Create (pure)
function TournamentDialog.Options(values, now)
    return {
        name = values.name, format = values.format, bracket = values.bracket, bestOf = values.bestOf,
        start = (now or ns.Utils.ServerTime()) + math.floor((tonumber(values.minutes) or 0) * 60),
        minLevel = tonumber(values.minLevel), maxTeams = tonumber(values.maxTeams),
    }
end

-- "Starts at 18:30 realm time" or the chest warning
function TournamentDialog.Preview(values, now)
    local Arena = ns.Arena
    now = now or ns.Utils.ServerTime()
    local minutes = tonumber(values.minutes)
    if not minutes then return L.TOUR_DLG_NEED_MINUTES end
    local clock = Arena.RealmClock(minutes) or "?"
    if not Arena.StartClearOfChest(now + math.floor(minutes * 60), now) then
        return string.format(L.TOUR_DLG_CHEST, clock)
    end
    return string.format(L.TOUR_DLG_STARTS, clock)
end

-------------------------------------------------
-- Frame
-------------------------------------------------

local function Label(f, text, y)
    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 18, y)
    label:SetText(text)
    return label
end

local function EditBox(f, key, y, width, numeric)
    local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetPoint("TOPLEFT", 130, y + 3)
    box:SetAutoFocus(false)
    if numeric then box:SetNumeric(true) end
    box:SetScript("OnTextChanged", function(self)
        local text = self:GetText()
        TournamentDialog.values[key] = numeric and tonumber(text) or text
        TournamentDialog:UpdatePreview()
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return box
end

-- A dropdown for one of the values (UI/Select.lua, the GudaBags select)
local function Dropdown(f, key, y, options)
    local select = ns.Select.Create(f, {
        width = 170, options = options,
        get = function() return TournamentDialog.values and TournamentDialog.values[key] end,
        set = function(value) TournamentDialog.values[key] = value end,
    })
    select:SetPoint("TOPLEFT", 126, y + 6)
    return select
end

function TournamentDialog.FormatOptions()
    local options = {}
    for i, n in ipairs(FORMATS) do options[i] = { value = n, label = n .. "v" .. n } end
    return options
end

function TournamentDialog.BracketOptions()
    local options = {}
    for i, b in ipairs(BRACKETS) do options[i] = { value = b, label = L["TOUR_BRACKET_" .. b:upper()] } end
    return options
end

function TournamentDialog.SeriesOptions()
    local options = {}
    for i, n in ipairs(SERIES) do options[i] = { value = n, label = string.format(L.TOUR_BEST_OF, n) } end
    return options
end

local function CreateDialog()
    local f = CreateFrame("Frame", "HeadHunterTournamentDialog", UIParent)
    f:SetSize(TournamentDialog.WIDTH, TournamentDialog.HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "HeadHunterTournamentDialog")
    ns.Theme.StyleFrame(f, L.TOUR_DLG_TITLE)

    Label(f, L.TOUR_DLG_NAME, -40)
    f.name = EditBox(f, "name", -40, 170)
    f.name:SetMaxLetters(ns.Tournaments.MAX_NAME)

    Label(f, L.TOUR_DLG_FORMAT, -70)
    f.format = Dropdown(f, "format", -70, TournamentDialog.FormatOptions())
    Label(f, L.TOUR_DLG_BRACKET, -100)
    f.bracket = Dropdown(f, "bracket", -100, TournamentDialog.BracketOptions())
    Label(f, L.TOUR_DLG_SERIES, -130)
    f.series = Dropdown(f, "bestOf", -130, TournamentDialog.SeriesOptions())

    Label(f, L.TOUR_DLG_MINUTES, -160)
    f.minutes = EditBox(f, "minutes", -160, 60, true)
    f.minutes:SetMaxLetters(5)
    f.preview = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.preview:SetPoint("TOPLEFT", 18, -184)
    f.preview:SetWidth(TournamentDialog.WIDTH - 36)
    f.preview:SetJustifyH("LEFT")

    Label(f, L.TOUR_DLG_LEVEL, -214)
    f.minLevel = EditBox(f, "minLevel", -214, 40, true)
    f.minLevel:SetMaxLetters(2)
    Label(f, L.TOUR_DLG_TEAMS, -244)
    f.maxTeams = EditBox(f, "maxTeams", -244, 40, true)
    f.maxTeams:SetMaxLetters(2)

    f.error = f:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    f.error:SetPoint("BOTTOMLEFT", 18, 42)
    f.error:SetWidth(TournamentDialog.WIDTH - 36)
    f.error:SetJustifyH("LEFT")

    f.create = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.create:SetSize(100, 22)
    f.create:SetPoint("BOTTOMRIGHT", -124, 14)
    f.create:SetText(L.TOUR_BUTTON_CREATE)
    f.create:SetScript("OnClick", function() TournamentDialog:Submit() end)
    f.close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.close:SetSize(100, 22)
    f.close:SetPoint("BOTTOMRIGHT", -18, 14)
    f.close:SetText(CANCEL or "Cancel")
    f.close:SetScript("OnClick", function() f:Hide() end)
    f:Hide()
    return f
end

function TournamentDialog:UpdateDropdowns()
    if not (frame and self.values) then return end
    frame.format:Refresh()
    frame.bracket:Refresh()
    frame.series:Refresh()
end

-- The dropdowns, for the offline tests: format, bracket, series
function TournamentDialog:Dropdowns()
    return frame and { format = frame.format, bracket = frame.bracket, series = frame.series }
end

function TournamentDialog:UpdatePreview()
    if frame and self.values then frame.preview:SetText(self.Preview(self.values)) end
end

function TournamentDialog:Open()
    frame = frame or CreateDialog()
    self.values = self.Defaults()
    local v = self.values
    frame.name:SetText(v.name)
    frame.minutes:SetText(tostring(v.minutes))
    frame.minLevel:SetText(tostring(v.minLevel))
    frame.maxTeams:SetText(tostring(v.maxTeams))
    frame.error:SetText("")
    self:UpdateDropdowns()
    self:UpdatePreview()
    frame:Show()
end

function TournamentDialog:IsShown()
    return frame ~= nil and frame:IsShown()
end

-- The Create click. Returns the tournament, or nil and the reason key.
function TournamentDialog:Submit()
    local t, reason = ns.Tournaments:Create(self.Options(self.values), true)
    if not t then
        local text = L["TOUR_ERR_" .. tostring(reason)] or tostring(reason)
        if frame then frame.error:SetText(text) end
        return nil, reason
    end
    ns:Print(string.format(L.TOUR_CREATED, t.name))
    if frame then frame:Hide() end
    return t
end
