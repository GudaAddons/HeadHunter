-- The HeadHunter look: the "guda" theme of GudaBags (Core/Theme.lua, UI/TabPanel.lua),
-- by the same author. A flat dark window with a thin tooltip border, a white title,
-- the standard close button, and tabs that hang from the window's bottom edge (the
-- selected one taller, joined to the window).
--
--   Theme.StyleFrame(frame, title)          window chrome
--   Theme.CreateTabs(frame, tabs, onSelect) bottom tabs; tabs = { { id, label }, ... }
--                                           returns { buttons, Select(id) }

local addonName, ns = ...

local Theme = ns:RegisterModule("Theme", {})

Theme.FRAME_BG = { 0.08, 0.08, 0.08, 1 }
Theme.FRAME_BORDER = { 0.30, 0.30, 0.30, 1 }
Theme.BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
Theme.TAB_TEXTURE = "Interface\\AddOns\\HeadHunter\\Assets\\uiframetabs"
Theme.TAB_TINT = 0.45 -- the guda theme greys the tab art
Theme.TAB_COORDS = {
    left      = { 0.015625, 0.5625, 0.816406, 0.957031 },
    right     = { 0.015625, 0.59375, 0.667969, 0.808594 },
    middle    = { 0, 0.015625, 0.175781, 0.316406 },
    leftSel   = { 0.015625, 0.5625, 0.496094, 0.660156 },
    rightSel  = { 0.015625, 0.59375, 0.324219, 0.488281 },
    middleSel = { 0, 0.015625, 0.00390625, 0.167969 },
}

-------------------------------------------------
-- Window
-------------------------------------------------

-- A plain frame gets the guda backdrop, a title and a close button
function Theme.StyleFrame(f, title)
    local bg = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
    bg:SetAllPoints(f)
    bg:SetFrameLevel(math.max(0, (f:GetFrameLevel() or 1) - 1))
    if bg.SetBackdrop then
        bg:SetBackdrop(Theme.BACKDROP)
        bg:SetBackdropColor(unpack(Theme.FRAME_BG))
        bg:SetBackdropBorderColor(unpack(Theme.FRAME_BORDER))
    end
    f.themeBg = bg

    f.windowTitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.windowTitle:SetPoint("TOP", f, "TOP", 0, -10)
    f.windowTitle:SetTextColor(1, 1, 1)
    f.windowTitle:SetText(title or "")

    local ok, close = pcall(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
    if ok and close then
        close:SetSize(22, 22)
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
        close:SetScript("OnClick", function() f:Hide() end)
        f.closeButton = close
    end
    return f
end

-------------------------------------------------
-- Bottom tabs
-------------------------------------------------

local function Piece(tab, layer, coords, width, height, point, x)
    local tex = tab:CreateTexture(nil, layer)
    tex:SetTexture(Theme.TAB_TEXTURE)
    tex:SetSize(width, height)
    tex:SetPoint(point, tab, point, x, 0)
    tex:SetTexCoord(unpack(coords))
    return tex
end

local function Middle(tab, layer, coords, height, left, right)
    local tex = tab:CreateTexture(nil, layer)
    tex:SetTexture(Theme.TAB_TEXTURE)
    tex:SetSize(1, height)
    tex:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
    tex:SetPoint("TOPRIGHT", right, "TOPLEFT", 0, 0)
    tex:SetTexCoord(unpack(coords))
    return tex
end

local function CreateTab(frame, info, previous, onClick)
    local C = Theme.TAB_COORDS
    local tab = CreateFrame("Button", nil, frame)
    tab.id = info.id

    local normal = { Piece(tab, "BACKGROUND", C.left, 35, 36, "TOPLEFT", -3),
        Piece(tab, "BACKGROUND", C.right, 37, 36, "TOPRIGHT", 7) }
    normal[3] = Middle(tab, "BACKGROUND", C.middle, 36, normal[1], normal[2])
    local selected = { Piece(tab, "BACKGROUND", C.leftSel, 35, 45, "TOPLEFT", -1),
        Piece(tab, "BACKGROUND", C.rightSel, 37, 45, "TOPRIGHT", 8) }
    selected[3] = Middle(tab, "BACKGROUND", C.middleSel, 45, selected[1], selected[2])
    local highlight = { Piece(tab, "HIGHLIGHT", C.left, 35, 36, "TOPLEFT", -3),
        Piece(tab, "HIGHLIGHT", C.right, 37, 36, "TOPRIGHT", 7) }
    highlight[3] = Middle(tab, "HIGHLIGHT", C.middle, 36, highlight[1], highlight[2])
    for _, tex in ipairs(highlight) do
        tex:SetBlendMode("ADD")
        tex:SetAlpha(0.4)
    end
    local tint = Theme.TAB_TINT
    for _, list in ipairs({ normal, selected, highlight }) do
        for _, tex in ipairs(list) do tex:SetVertexColor(tint, tint, tint) end
    end

    tab.label = tab:CreateFontString(nil, "BORDER", "GameFontNormalSmall")
    tab.label:SetPoint("CENTER", tab, "CENTER", 0, 2)
    tab.label:SetText(info.label)
    tab:SetSize((tab.label:GetStringWidth() or 60) + 36, 32)

    function tab:SetSelected(isSelected)
        for _, tex in ipairs(normal) do if isSelected then tex:Hide() else tex:Show() end end
        for _, tex in ipairs(selected) do if isSelected then tex:Show() else tex:Hide() end end
        for _, tex in ipairs(highlight) do tex:SetHeight(isSelected and 45 or 36) end
        if isSelected then tab.label:SetTextColor(1, 1, 1) else tab.label:SetTextColor(1, 0.82, 0) end
        tab.selected = isSelected
    end

    -- Hanging from the window's bottom edge, side by side
    if previous then
        tab:SetPoint("BOTTOMLEFT", previous, "BOTTOMRIGHT", 1, 0)
    else
        tab:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, -30)
    end
    tab:SetScript("OnClick", function()
        if PlaySound then pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB or 841) end
        onClick(info.id)
    end)
    tab:SetSelected(false)
    return tab
end

function Theme.CreateTabs(frame, tabs, onSelect)
    local set = { buttons = {} }
    local previous
    for i, info in ipairs(tabs) do
        previous = CreateTab(frame, info, previous, onSelect)
        set.buttons[i] = previous
    end
    function set:Select(id)
        for _, tab in ipairs(self.buttons) do tab:SetSelected(tab.id == id) end
    end
    return set
end
