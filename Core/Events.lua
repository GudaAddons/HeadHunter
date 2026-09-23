local addonName, ns = ...

local Events = ns:RegisterModule("Events", {})

local callbacks = {}
local eventFrame = CreateFrame("Frame")

-- Addon-internal events carry this prefix and never touch the frame
local function IsCustom(event)
    return event:sub(1, 3) == "HH_"
end

local function Dispatch(event, ...)
    local list = callbacks[event]
    if not list then return end
    for _, callback in pairs(list) do
        local ok, err = pcall(callback, event, ...)
        if not ok then
            ns:Error(err)
        end
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    Dispatch(event, ...)
end)

-- Events that exist on a client but must never be registered there. On Forever,
-- C_EventUtils reports COMBAT_LOG_EVENT_UNFILTERED as valid, yet registering it is a
-- protected action: pcall cannot catch it and the client raises ADDON_ACTION_FORBIDDEN
-- (probe 2026-09-23, build 1.60.1.69913).
local function IsRestricted(event)
    return event == "COMBAT_LOG_EVENT_UNFILTERED" and not ns.Features.HasCLEU
end
Events.IsRestricted = IsRestricted

-- Returns false when the event is restricted or the client refuses it, instead of
-- raising.
function Events:Register(event, callback, owner)
    if IsRestricted(event) then
        ns:Debug("Event restricted on this client:", event)
        return false
    end
    if not callbacks[event] then
        if not IsCustom(event) then
            local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
            if not ok then
                ns:Debug("Event not available on this client:", event)
                return false
            end
        end
        callbacks[event] = {}
    end
    callbacks[event][owner] = callback
    return true
end

function Events:Unregister(event, owner)
    local list = callbacks[event]
    if not list then return end
    list[owner] = nil
    if next(list) == nil then
        callbacks[event] = nil
        if not IsCustom(event) then
            eventFrame:UnregisterEvent(event)
        end
    end
end

function Events:UnregisterAll(owner)
    for event in pairs(callbacks) do
        self:Unregister(event, owner)
    end
end

function Events:OnAddonLoaded(callback, owner)
    self:Register("ADDON_LOADED", function(event, loadedAddon)
        if loadedAddon == addonName then
            self:Unregister("ADDON_LOADED", owner)
            callback(event, loadedAddon)
        end
    end, owner)
end

-- Fire an addon-internal event (name must start with HH_)
function Events:Fire(event, ...)
    Dispatch(event, ...)
end
