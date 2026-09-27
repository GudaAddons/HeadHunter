-- HH-118: the Post a bounty dialog, opened from the poster of an enemy who killed us
-- in the last 24 hours (UI/Poster.lua).
--
--   Put a bounty on Grim Reaper
--   Reason   [Camped me          v]
--   Gold     [ 20 ]   (at least 5g)
--   Days     [ 3 days v]
--                               [Post] [Cancel]
--
-- The values live in BountyDialog.values; the widgets only edit them, so the offline
-- tests fill the values and press Post. Post is a click: on Era the poster also goes
-- realm-wide.

local addonName, ns = ...
local L = ns.L

local BountyDialog = ns:RegisterModule("BountyDialog", {})

BountyDialog.WIDTH = 320
BountyDialog.HEIGHT = 200
BountyDialog.DEFAULT_GOLD = 5
BountyDialog.DEFAULT_DAYS = 3

local frame
BountyDialog.values = nil

function BountyDialog.ReasonOptions()
    local options = {}
    for i in ipairs(ns.Bounties.REASONS) do options[i] = { value = i, label = ns.Bounties.ReasonText(i) } end
    return options
end

function BountyDialog.DayOptions()
    local options = {}
    for i, days in ipairs(ns.Bounties.DAYS) do options[i] = { value = days, label = string.format(L.BOUNTY_DAYS, days) } end
    return options
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

local function Dropdown(f, key, y, options)
    local select = ns.Select.Create(f, {
        width = 170, options = options,
        get = function() return BountyDialog.values and BountyDialog.values[key] end,
        set = function(value) BountyDialog.values[key] = value end,
    })
    select:SetPoint("TOPLEFT", 96, y + 6)
    return select
end

local function CreateDialog()
    local f = CreateFrame("Frame", "HeadHunterBountyDialog", UIParent)
    f:SetSize(BountyDialog.WIDTH, BountyDialog.HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "HeadHunterBountyDialog")
    ns.Theme.StyleFrame(f, L.BOUNTY_DLG_TITLE)

    f.target = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.target:SetPoint("TOPLEFT", 18, -36)
    f.target:SetWidth(BountyDialog.WIDTH - 36)
    f.target:SetJustifyH("LEFT")

    Label(f, L.BOUNTY_DLG_REASON, -66)
    f.reason = Dropdown(f, "reason", -66, BountyDialog.ReasonOptions())

    Label(f, L.BOUNTY_DLG_GOLD, -96)
    f.gold = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.gold:SetSize(60, 20)
    f.gold:SetPoint("TOPLEFT", 100, -93)
    f.gold:SetAutoFocus(false)
    f.gold:SetNumeric(true)
    f.gold:SetMaxLetters(5)
    f.gold:SetScript("OnTextChanged", function(self) BountyDialog.values.gold = tonumber(self:GetText()) end)
    f.gold:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.gold:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.goldHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.goldHint:SetPoint("TOPLEFT", 170, -99)
    f.goldHint:SetText(string.format(L.BOUNTY_DLG_MIN, ns.Bounties.Gold(ns.Bounties.MIN_GOLD)))

    Label(f, L.BOUNTY_DLG_DAYS, -126)
    f.days = Dropdown(f, "days", -126, BountyDialog.DayOptions())

    f.error = f:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    f.error:SetPoint("BOTTOMLEFT", 18, 42)
    f.error:SetWidth(BountyDialog.WIDTH - 36)
    f.error:SetJustifyH("LEFT")

    f.post = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.post:SetSize(100, 22)
    f.post:SetPoint("BOTTOMRIGHT", -124, 14)
    f.post:SetText(L.BOUNTY_DLG_POST)
    f.post:SetScript("OnClick", function() BountyDialog:Submit() end)
    f.close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.close:SetSize(100, 22)
    f.close:SetPoint("BOTTOMRIGHT", -18, 14)
    f.close:SetText(CANCEL or "Cancel")
    f.close:SetScript("OnClick", function() f:Hide() end)
    f:Hide()
    return f
end

-- Opens the dialog for one enemy id; false (with a chat line) when we cannot post on them
function BountyDialog:Open(targetId)
    local ok, reason = ns.Bounties:CanPost(targetId)
    if not ok then
        ns:Print(L["BOUNTY_ERR_" .. tostring(reason):upper()] or tostring(reason))
        return false
    end
    frame = frame or CreateDialog()
    self.values = { target = targetId, reason = 1, gold = self.DEFAULT_GOLD, days = self.DEFAULT_DAYS }
    frame.target:SetText(string.format(L.BOUNTY_DLG_TARGET, ns.Bounties.TargetName(targetId)))
    frame.gold:SetText(tostring(self.values.gold))
    frame.reason:Refresh()
    frame.days:Refresh()
    frame.error:SetText("")
    frame:Show()
    return true
end

function BountyDialog:IsShown()
    return frame ~= nil and frame:IsShown()
end

-- The Post click. Returns the poster, or nil and the reason key.
function BountyDialog:Submit()
    local v = self.values
    if not v then return nil, "unknown" end
    local poster, reason = ns.Bounties:Post(v.target, v.reason, v.gold, v.days)
    if not poster then
        local text = L["BOUNTY_ERR_" .. tostring(reason):upper()] or tostring(reason)
        if frame then frame.error:SetText(text) end
        return nil, reason
    end
    if frame then frame:Hide() end
    return poster
end
