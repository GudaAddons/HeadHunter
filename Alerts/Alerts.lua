-- HH-041: the alert framework every alert goes through.
--
--   ns.Alerts:Show({
--       key = "seen:Wiadro-Firemaw",   -- throttle key (required)
--       throttle = 120,                -- seconds before the same key may alert again
--       text = "...",                  -- center screen, raid-warning style
--       chat = "...",                  -- one chat line
--       sound = true,                  -- play the alert sound
--       popup = { text, accept, decline, onAccept, onDecline },  -- optional (HH-043)
--       combat = true,                 -- show at once even in combat (no popup allowed)
--   })
--
-- Rules (docs/addon/features.md sections 4 and 8):
--   - never inside instances (dropped, not queued)
--   - in combat: queued and shown when combat ends (duplicates merged, stale dropped),
--     except alerts marked `combat` with no popup (a WANTED outlaw in sight: author,
--     2026-09-23), which show at once
--   - settings.alerts: enabled, sound, popups
-- Returns true when shown, "queued" when waiting for combat to end, false otherwise.

local addonName, ns = ...

local Alerts = ns:RegisterModule("Alerts", {})

local OWNER = "Alerts"

Alerts.DEFAULT_THROTTLE = 60
Alerts.QUEUE_MAX_AGE = 60     -- seconds an alert may wait for combat to end
Alerts.SOUND = 8959           -- SOUNDKIT.RAID_WARNING
Alerts.POPUP = "HEADHUNTER_ALERT"            -- WANTED activity (Join the posse)
Alerts.HOTSPOT_POPUP = "HEADHUNTER_HOTSPOT"  -- PvP hotspots (Help / Ignore)
Alerts.JUSTICE_POPUP = "HEADHUNTER_JUSTICE"  -- our catch, Era: Announce / Close (HH-048)
Alerts.CATCHUP_POPUP = "HEADHUNTER_CATCHUP"  -- Era, at login: Catch up / Skip (HH-023)
Alerts.TOUR_POPUP = "HEADHUNTER_TOUR"        -- Gurubashi check-in: I'm here / Later (HH-104)
-- One StaticPopup per kind, so a hotspot never replaces a WANTED popup on screen
local DIALOGS = { Alerts.POPUP, Alerts.HOTSPOT_POPUP, Alerts.JUSTICE_POPUP, Alerts.CATCHUP_POPUP, Alerts.TOUR_POPUP }

local lastShown = {}          -- key -> GetTime()
local queue = {}              -- key -> { alert, queuedAt }, while in combat

local function Setting(name)
    local db = ns.db
    return db and db.settings.alerts[name]
end

local function InCombat()
    return ns.Utils.SafeCall(UnitAffectingCombat, "player") == true
end

-------------------------------------------------
-- Output channels
-------------------------------------------------

local function ShowCenter(text)
    if RaidNotice_AddMessage and RaidWarningFrame then
        local color = ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.3, b = 0.1 }
        pcall(RaidNotice_AddMessage, RaidWarningFrame, text, color)
    elseif UIErrorsFrame then
        UIErrorsFrame:AddMessage(text, 1, 0.3, 0.1)
    end
end

Alerts.SOFT_SOUND = 3175     -- SOUNDKIT.MAP_PING: posse updates

local function PlayAlertSound(kind)
    local kit
    if kind == "soft" then
        kit = SOUNDKIT and SOUNDKIT.MAP_PING or Alerts.SOFT_SOUND
    else
        kit = SOUNDKIT and SOUNDKIT.RAID_WARNING or Alerts.SOUND
    end
    pcall(PlaySound, kit, "Master")
end

local popupHandlers = {}   -- dialog name -> { accept, decline }

local function ShowPopup(popup)
    local name = popup.dialog or Alerts.POPUP
    popupHandlers[name] = { accept = popup.onAccept, decline = popup.onDecline }
    local dialog = StaticPopupDialogs[name]
    dialog.text = popup.text
    dialog.button1 = popup.accept
    dialog.button2 = popup.decline
    StaticPopup_Show(name)
end

-------------------------------------------------
-- Show
-------------------------------------------------

local function Render(alert)
    if alert.text then ShowCenter(alert.text) end
    if alert.chat then ns:Print(alert.chat) end
    if alert.sound and Setting("sound") then PlayAlertSound(alert.sound) end
    if alert.popup and Setting("popups") then ShowPopup(alert.popup) end
    lastShown[alert.key] = ns.Utils.Now()
    ns.Events:Fire("HH_ALERT_SHOWN", alert)
end

function Alerts:Show(alert)
    if type(alert) ~= "table" or not alert.key then return false end
    if not Setting("enabled") then return false end
    if not ns.Guards:IsActive() then return false end

    local now = ns.Utils.Now()
    local last = lastShown[alert.key]
    if last and now - last < (alert.throttle or self.DEFAULT_THROTTLE) then return false end

    if InCombat() and not (alert.combat and not alert.popup) then
        -- Newest version of the same alert wins
        queue[alert.key] = { alert = alert, queuedAt = now }
        return "queued"
    end
    Render(alert)
    return true
end

function Alerts:FlushQueue()
    if not ns.Guards:IsActive() then
        wipe(queue)
        return
    end
    local now = ns.Utils.Now()
    local pending = {}
    for key, item in pairs(queue) do
        if now - item.queuedAt <= self.QUEUE_MAX_AGE then pending[#pending + 1] = item end
        queue[key] = nil
    end
    table.sort(pending, function(a, b) return a.queuedAt < b.queuedAt end)
    for _, item in ipairs(pending) do
        local last = lastShown[item.alert.key]
        if not last or now - last >= (item.alert.throttle or self.DEFAULT_THROTTLE) then
            Render(item.alert)
        end
    end
end

function Alerts:QueuedCount()
    local n = 0
    for _ in pairs(queue) do n = n + 1 end
    return n
end

-- Forget throttles (tests, and /hh alerts reset)
function Alerts:ResetThrottles()
    wipe(lastShown)
end

-------------------------------------------------
-- Wiring
-------------------------------------------------

ns.Events:Register("HH_INITIALIZED", function()
    for _, name in ipairs(DIALOGS) do
        StaticPopupDialogs[name] = {
            text = "",
            button1 = OKAY or "OK",
            button2 = CANCEL or "Cancel",
            OnAccept = function()
                local handlers = popupHandlers[name]
                if handlers and handlers.accept then handlers.accept() end
            end,
            OnCancel = function()
                local handlers = popupHandlers[name]
                if handlers and handlers.decline then handlers.decline() end
            end,
            timeout = 30,
            whileDead = 1,
            hideOnEscape = 1,
            preferredIndex = 3,
        }
    end
    ns.Events:Register("PLAYER_REGEN_ENABLED", function() Alerts:FlushQueue() end, OWNER)
    -- Entering an instance drops anything that waited for combat to end
    ns.Events:Register("HH_SUSPEND_CHANGED", function(_, suspended)
        if suspended then wipe(queue) end
    end, OWNER)
end, OWNER)

-- /hh alerts [on|off|sound on|off|test]
ns.SlashCommands:Register("alerts", function(args)
    local a, b = args[1] and args[1]:lower(), args[2] and args[2]:lower()
    local DB = ns.Database
    if a == "on" or a == "off" then
        DB:SetSetting("alerts.enabled", a == "on")
    elseif a == "sound" and (b == "on" or b == "off") then
        DB:SetSetting("alerts.sound", b == "on")
    elseif a == "range" and (b == "adjacent" or b == "continent") then
        DB:SetSetting("alerts.range", b)
    elseif a == "whisper" and (b == "on" or b == "off") then
        DB:SetSetting("alerts.whisperInvite", b == "on")
    elseif a == "test" then
        Alerts:ResetThrottles()
        local shown = Alerts:Show({ key = "test", text = ns.L.ALERT_TEST_TEXT, chat = ns.L.ALERT_TEST_TEXT, sound = true })
        if shown == "queued" then ns:Print(ns.L.ALERT_QUEUED) end
        return
    end
    ns:Print(string.format(ns.L.ALERTS_STATUS, DB:GetSetting("alerts.enabled") and "on" or "off",
        DB:GetSetting("alerts.sound") and "on" or "off", DB:GetSetting("alerts.range"),
        DB:GetSetting("alerts.whisperInvite") and "on" or "off"))
end, ns.L.HELP_ALERTS)
