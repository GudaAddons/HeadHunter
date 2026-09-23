-- In-memory debug log (ring buffer) with a copyable viewer window.
-- Everything silent (sync, detection, probes) writes here instead of chat.

local addonName, ns = ...

local Log = ns:RegisterModule("Log", {})

local MAX_LINES = 500
local lines = {}
local head = 0
local count = 0

function Log:Add(level, msg)
    head = head % MAX_LINES + 1
    lines[head] = string.format("%s [%s] %s", date("%H:%M:%S"), level, tostring(msg))
    if count < MAX_LINES then count = count + 1 end
    if self.frame and self.frame:IsShown() then
        self:RequestRefresh()
    end
end

-- Oldest first
function Log:Lines()
    local out = {}
    local start = (count < MAX_LINES) and 1 or (head % MAX_LINES + 1)
    for i = 0, count - 1 do
        out[#out + 1] = lines[(start - 1 + i) % MAX_LINES + 1]
    end
    return out
end

function Log:Clear()
    lines, head, count = {}, 0, 0
    if self.frame and self.frame:IsShown() then self:Refresh() end
end

-------------------------------------------------
-- Viewer
-------------------------------------------------

local function CreateLogFrame()
    local ok, frame = pcall(CreateFrame, "Frame", "HeadHunterLogFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok then
        frame = CreateFrame("Frame", "HeadHunterLogFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    end
    frame:SetSize(640, 420)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "HeadHunterLogFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("HeadHunter debug log")

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -30)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(580)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    scroll:SetScrollChild(edit)

    frame.scroll = scroll
    frame.edit = edit
    frame:Hide()
    return frame
end

function Log:Refresh()
    if not self.frame then return end
    self.frame.edit:SetText(table.concat(self:Lines(), "\n"))
    self.frame.scroll:SetVerticalScroll(self.frame.scroll:GetVerticalScrollRange())
end

-- Coalesce bursts of log lines into one redraw
function Log:RequestRefresh()
    if self.refreshPending then return end
    self.refreshPending = true
    C_Timer.After(0.2, function()
        self.refreshPending = false
        self:Refresh()
    end)
end

function Log:Toggle()
    self.frame = self.frame or CreateLogFrame()
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
        self:Refresh()
    end
end

function Log:Show()
    self.frame = self.frame or CreateLogFrame()
    self.frame:Show()
    self:Refresh()
end
