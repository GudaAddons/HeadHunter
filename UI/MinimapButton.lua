-- HH-060: minimap button. Left-click toggles the main window; drag moves it around
-- the minimap (angle kept in settings.minimap); /hh minimap shows or hides it.

local addonName, ns = ...
local L = ns.L

local MinimapButton = ns:RegisterModule("MinimapButton", {})

local OWNER = "MinimapButton"

MinimapButton.ICON = "Interface\\Icons\\INV_Misc_Head_Human_01"
MinimapButton.SIZE = 31

local button

-- Position on the minimap's edge for an angle in degrees
function MinimapButton.Offset(angle, radius)
    local rad = math.rad(angle)
    return math.cos(rad) * radius, math.sin(rad) * radius
end

local function Settings()
    return ns.db.settings.minimap
end

local function Place()
    local radius = (Minimap:GetWidth() or 140) / 2 + 10
    local x, y = MinimapButton.Offset(Settings().angle, radius)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not (mx and px and scale and scale > 0) then return end
    Settings().angle = math.deg(math.atan2(py / scale - my, px / scale - mx))
    Place()
end

local function Create()
    button = CreateFrame("Button", "HeadHunterMinimapButton", Minimap)
    button:SetSize(MinimapButton.SIZE, MinimapButton.SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture(MinimapButton.ICON)
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", button, "CENTER", 0, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", button, "TOPLEFT")

    button:SetScript("OnClick", function() ns.MainWindow:Toggle() end)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", OnDragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(L.WINDOW_TITLE)
        GameTooltip:AddLine(L.MINIMAP_HINT, 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    Place()
end

function MinimapButton:Apply()
    if not Minimap then return end
    if Settings().hidden then
        if button then button:Hide() end
        return
    end
    if not button then Create() end
    button:Show()
end

function MinimapButton:IsShown()
    return button ~= nil and button:IsShown()
end

ns.Events:Register("HH_INITIALIZED", function()
    MinimapButton:Apply()
end, OWNER)

ns.SlashCommands:Register("minimap", function()
    Settings().hidden = not Settings().hidden
    MinimapButton:Apply()
    ns:Print(Settings().hidden and L.MINIMAP_HIDDEN or L.MINIMAP_SHOWN)
end, L.HELP_MINIMAP)
