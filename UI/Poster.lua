-- HH-061: the poster. Everything known about one enemy, opened from a row of the main
-- window. Basic layout for now; the parchment "WANTED — DEAD OR ALIVE" art comes later.
--
--   [race][class] Name (class color)            60 Orc Rogue
--   WANTED · Ganker · 8 kills        Coward, Gunslinger
--   Last kill 5 min ago in Westfall
--   Kills known: 12 (exact 10, guessed 2) · WANTED 2x · caught 1x · peak rank Outlaw
--   Recent kills: when · victim · zone · kill type (newest first)
--   Posse: you, Hunterx
--   [Join the posse]
--
-- Poster.Content(id, now) is the pure part (tested offline).

local addonName, ns = ...
local L = ns.L

local Poster = ns:RegisterModule("Poster", {})

local OWNER = "Poster"

Poster.WIDTH = 400
Poster.HEIGHT = 420
Poster.RECENT = 8

-------------------------------------------------
-- Content (pure)
-------------------------------------------------

-- The enemy's reports, newest first: { report, enemy } (the killer or an assist)
local function KillsOf(id, limit)
    local Engine = ns.RulesEngine
    local list = {}
    for _, report in ns.Reports:All() do
        local enemies = { report.killer }
        for _, assist in ipairs(report.assists or {}) do enemies[#enemies + 1] = assist end
        for _, enemy in ipairs(enemies) do
            if Engine.EnemyId(enemy) == id then
                list[#list + 1] = { report = report, enemy = enemy }
                break
            end
        end
    end
    table.sort(list, function(a, b) return a.report.t > b.report.t end)
    for i = #list, (limit or #list) + 1, -1 do list[i] = nil end
    return list
end
Poster.KillsOf = KillsOf

function Poster.Content(id, now)
    local entry = id and ns.Wanted:Get(id)
    if not entry then return nil end
    now = now or ns.Utils.ServerTime()
    local U, Wanted = ns.Utils, ns.Wanted
    local name = entry.key and U.DisplayName(entry.key) or entry.name or "?"
    local icons = U.RaceIcon(entry.race, entry.sex, 18) .. U.ClassIcon(entry.class, 18)
    local c = {
        id = entry.id,
        name = name,
        title = (icons ~= "" and (icons .. " ") or "") .. ns.MainWindow.ClassColored(name, entry.class),
        who = ns.DeathReports.Describe(entry),
        wanted = entry.wanted == true,
        badges = Wanted.BadgeNames(entry),
        history = string.format(L.POSTER_HISTORY, entry.killCount or 0, entry.exactKills or 0, entry.guessedKills or 0,
            entry.timesWanted or 0, entry.timesCaught or 0,
            entry.peakRank and Wanted.RankName(entry.peakRank) or "-"),
        posse = ns.Posse:Summary(entry.id),
        recent = {},
    }
    if entry.wanted then
        c.status = string.format(L.TIP_WANTED, Wanted.RankName(entry.rank), math.floor(entry.kills))
    else
        c.status = L.TIP_NOT_WANTED
    end
    local kill = entry.lastKill
    if kill then
        c.lastKill = string.format(L.TIP_LAST_KILL, U.Ago(math.max(0, now - kill.t)), U.MapName(kill.mapID) or L.UNKNOWN_ZONE)
    end
    local kills = KillsOf(entry.id, Poster.RECENT)
    for _, item in ipairs(kills) do
        local report = item.report
        local kind = ns.Classify.Kill(item.enemy.level, report.victim and report.victim.level)
        c.recent[#c.recent + 1] = string.format(L.POSTER_KILL, U.Ago(math.max(0, now - report.t)),
            U.DisplayName(report.victim and report.victim.key) or "?", U.MapName(report.mapID) or L.UNKNOWN_ZONE,
            L["KILL_" .. kind:upper()])
    end
    -- Join needs a kill to go to (and WANTED status); not twice
    c.newestReport = kills[1] and kills[1].report
    c.canJoin = entry.wanted and c.newestReport ~= nil and not ns.Posse:IsMember(entry.id)
    return c
end

-------------------------------------------------
-- Actions
-------------------------------------------------

local shownId

function Poster:Join()
    local c = Poster.Content(shownId)
    if not (c and c.canJoin) then return false end
    ns.Posse:Join(ns.Wanted:Get(c.id), c.newestReport)
    self:Refresh()
    return true
end

-------------------------------------------------
-- Drawing
-------------------------------------------------

local frame

local function Text(parent, font, anchor, relative, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetPoint("TOPLEFT", relative or parent, anchor or "TOPLEFT", x or 0, y or 0)
    fs:SetJustifyH("LEFT")
    if width then fs:SetWidth(width) end
    return fs
end

local function CreatePosterFrame()
    local ok, f = pcall(CreateFrame, "Frame", "HeadHunterPosterFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok then
        f = CreateFrame("Frame", "HeadHunterPosterFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    end
    f:SetSize(Poster.WIDTH, Poster.HEIGHT)
    f:SetPoint("CENTER", UIParent, "CENTER", 260, 0)
    -- Above the main window (HIGH), which it is opened from and may overlap
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "HeadHunterPosterFrame")

    local header = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    header:SetPoint("TOP", 0, -5)
    header:SetText(L.POSTER_HEADER)

    local width = Poster.WIDTH - 32
    f.title = Text(f, "GameFontNormalLarge", "TOPLEFT", f, 16, -34, width)
    f.who = Text(f, "GameFontDisable", "BOTTOMLEFT", f.title, 0, -4, width)
    f.status = Text(f, "GameFontHighlight", "BOTTOMLEFT", f.who, 0, -10, width)
    f.badges = Text(f, "GameFontHighlightSmall", "BOTTOMLEFT", f.status, 0, -4, width)
    f.lastKill = Text(f, "GameFontHighlightSmall", "BOTTOMLEFT", f.badges, 0, -8, width)
    f.history = Text(f, "GameFontDisableSmall", "BOTTOMLEFT", f.lastKill, 0, -8, width)
    f.recentHeader = Text(f, "GameFontNormal", "BOTTOMLEFT", f.history, 0, -12, width)
    f.recentHeader:SetText(L.POSTER_RECENT)
    f.recent = {}
    local previous = f.recentHeader
    for i = 1, Poster.RECENT do
        f.recent[i] = Text(f, "GameFontHighlightSmall", "BOTTOMLEFT", previous, 0, -3, width)
        previous = f.recent[i]
    end
    f.posse = Text(f, "GameFontHighlightSmall", "BOTTOMLEFT", previous, 0, -10, width)

    f.joinButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.joinButton:SetSize(170, 22)
    f.joinButton:SetPoint("BOTTOM", 0, 14)
    f.joinButton:SetText(L.POSSE_JOIN)
    f.joinButton:SetScript("OnClick", function() Poster:Join() end)

    f:Hide()
    return f
end

function Poster:Refresh()
    if not (frame and frame:IsShown()) then return end
    local c = Poster.Content(shownId)
    if not c then
        frame:Hide()
        return
    end
    frame.title:SetText(c.title)
    frame.who:SetText(c.who)
    frame.status:SetText(c.status)
    frame.badges:SetText(c.badges)
    frame.lastKill:SetText(c.lastKill or "")
    frame.history:SetText(c.history)
    for i, line in ipairs(frame.recent) do line:SetText(c.recent[i] or "") end
    if #c.recent == 0 then frame.recent[1]:SetText(L.POSTER_NO_KILLS) end
    frame.posse:SetText(c.posse or "")
    if c.canJoin then frame.joinButton:Show() else frame.joinButton:Hide() end
    self.shown = c
end

function Poster:Show(id)
    if not (id and ns.Wanted:Get(id)) then return false end
    frame = frame or CreatePosterFrame()
    shownId = id
    frame:Show()
    frame:Raise()
    self:Refresh()
    return true
end

function Poster:Hide()
    if frame then frame:Hide() end
end

function Poster:IsShown()
    return frame ~= nil and frame:IsShown()
end

function Poster:ShownId()
    return self:IsShown() and shownId or nil
end

ns.Events:Register("HH_INITIALIZED", function()
    local refresh = function() Poster:Refresh() end
    for _, event in ipairs({ "HH_WANTED_UPDATED", "HH_POSSE_CHANGED" }) do
        ns.Events:Register(event, refresh, OWNER)
    end
end, OWNER)
