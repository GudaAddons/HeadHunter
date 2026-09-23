-- HH-048: "Justice served!" when a WANTED outlaw is caught (Sync/Justice.lua).
--
--   Our catch:      center text + chat + sound; on Era also [Announce] to the realm
--   Someone else's: a chat line; posse members of that outlaw also get center text
-- Driven by HH_WANTED_CAUGHT, so it describes what the rules decided, once.

local addonName, ns = ...
local L = ns.L

local JusticeAlerts = ns:RegisterModule("JusticeAlerts", {})

local OWNER = "JusticeAlerts"

local function Name(key)
    return key and ns.Utils.DisplayName(key) or "?"
end

function JusticeAlerts:OnCaught(entry, before)
    local record = ns.Justice:Latest(entry.id)
    if not record then return end
    local U, Wanted = ns.Utils, ns.Wanted
    local outlaw = entry.key and U.DisplayName(entry.key) or entry.name
    local rank = Wanted.RankName(before.rank)
    local kills = math.floor(before.kills or 0)
    local zone = U.MapName(record.mapID) or L.UNKNOWN_ZONE
    local byMe = U.SameCharacter(record.killer, U.UnitKey("player"))
    local line = string.format(L.JUSTICE_LINE, rank, outlaw, kills, byMe and L.POSSE_YOU or Name(record.killer), zone)
    local alert = { key = "justice:" .. record.id, throttle = 0, chat = line }

    if record.origin == "local" then
        alert.text = string.format(L.JUSTICE_CENTER, outlaw)
        alert.sound = true
        -- Era: the realm hears about it only through a click
        if ns.Justice:PendingAnnounce() > 0 then
            alert.popup = {
                dialog = ns.Alerts.JUSTICE_POPUP,
                text = line .. "\n\n" .. L.JUSTICE_ANNOUNCE_QUESTION,
                accept = L.JUSTICE_ANNOUNCE,
                decline = CLOSE or "Close",
                onAccept = function() ns.Justice:Announce() end,
                onDecline = function() ns.Justice:SkipAnnounce() end,
            }
        end
    elseif ns.Posse:IsMember(entry.id) then
        alert.text = string.format(L.JUSTICE_CENTER_POSSE, outlaw, byMe and L.POSSE_YOU or Name(record.killer))
        alert.sound = "soft"
    end
    ns.Alerts:Show(alert)
end

ns.Events:Register("HH_INITIALIZED", function()
    ns.Events:Register("HH_WANTED_CAUGHT", function(_, entry, before) JusticeAlerts:OnCaught(entry, before) end, OWNER)
end, OWNER)
