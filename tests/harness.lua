-- Offline harness: stubs just enough of the WoW API to load the real addon files
-- (in TOC order) under a chosen client, fire events at them and inspect the result.
-- Never loaded by the game (tests/ is not in the TOC).

local H = {}

local ROOT = assert(arg and arg[1], "usage: lua5.1 tests/run.lua <addon root>")
H.ROOT = ROOT

local CLIENTS = {
    era = { iface = 11509, project = 2 },
    -- Forever reports WOW_PROJECT_ID 1 (mainline); probe 2026-09-23, build 1.60.1.69913
    forever = { iface = 16001, project = 1 },
}
H.CLIENTS = CLIENTS

-------------------------------------------------
-- Frames
-------------------------------------------------

local frames

local function NoOp() end

local function NewFrame(name)
    local frame = { registered = {}, scripts = {}, shown = false, name = name }
    function frame:RegisterEvent(event)
        if H.removedEvents[event] then
            error("Attempt to register unknown event \"" .. event .. "\"")
        end
        -- The real client does not raise here: it blocks the call and reports
        -- ADDON_ACTION_FORBIDDEN, which pcall cannot catch. Record it instead.
        if H.protectedEvents[event] then
            H.forbidden[#H.forbidden + 1] = "RegisterEvent(" .. event .. ")"
            return
        end
        self.registered[event] = true
    end
    function frame:UnregisterEvent(event) self.registered[event] = nil end
    function frame:SetScript(script, fn) self.scripts[script] = fn end
    function frame:GetScript(script) return self.scripts[script] end
    function frame:Show() self.shown = true end
    function frame:Hide() self.shown = false end
    function frame:IsShown() return self.shown end
    function frame:CreateFontString() return NewFrame() end
    function frame:GetVerticalScrollRange() return 0 end
    frames[#frames + 1] = frame
    if name then _G[name] = frame end
    -- Any other widget method is a harmless no-op
    return setmetatable(frame, { __index = function() return NoOp end })
end

-------------------------------------------------
-- Environment
-------------------------------------------------

-- Replaces every stubbed global. opts.client = "era" | "forever" | custom
-- { iface = n, project = n }.
function H.Install(opts)
    opts = opts or {}
    local client = type(opts.client) == "table" and opts.client or CLIENTS[opts.client or "era"]

    frames = {}
    H.printed = {}
    H.errors = {}
    H.timers = {}
    H.clock = 1000
    H.serverTime = 1780000000
    H.realm = "Firemaw"
    H.instance = { false, "none" }
    H.removedEvents = {}
    H.protectedEvents = {}
    H.forbidden = {}
    if client == CLIENTS.forever then
        H.protectedEvents.COMBAT_LOG_EVENT_UNFILTERED = true
    end
    H.units = {
        player = {
            name = client == CLIENTS.forever and "Vati Guda" or "Vati",
            level = 30, class = "ROGUE", race = "Human", sex = 2,
            guid = "Player-1-00000001", faction = "Alliance", isPlayer = true,
        },
    }
    H.maps = {
        [1429] = { mapID = 1429, name = "Elwynn Forest", mapType = 3, parentMapID = 1415 },
        [1436] = { mapID = 1436, name = "Westfall", mapType = 3, parentMapID = 1415 },
        [1434] = { mapID = 1434, name = "Stranglethorn Vale", mapType = 3, parentMapID = 1415 },
        [1417] = { mapID = 1417, name = "Arathi Highlands", mapType = 3, parentMapID = 1415 },
        [1413] = { mapID = 1413, name = "The Barrens", mapType = 3, parentMapID = 1414 },
        [9001] = { mapID = 9001, name = "Jasperlode Mine", mapType = 5, parentMapID = 1429 },
        [1415] = { mapID = 1415, name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
        [1414] = { mapID = 1414, name = "Kalimdor", mapType = 2, parentMapID = 947 },
        [947] = { mapID = 947, name = "Azeroth", mapType = 1, parentMapID = 0 },
    }
    H.waypoints = {}
    _G.UiMapPoint = { CreateFromCoordinates = function(mapID, x, y) return { uiMapID = mapID, x = x, y = y } end }
    _G.C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
    H.playerMap = 1429

    _G.HeadHunter_DB = opts.savedDB
    _G.SLASH_HEADHUNTER1, _G.SLASH_HEADHUNTER2 = nil, nil
    _G.SlashCmdList = {}
    _G.UISpecialFrames = {}
    _G.UIParent = NewFrame()
    _G.ChatFontNormal = {}
    _G.BackdropTemplateMixin = nil
    _G.canaccessvalue = nil
    _G.issecretvalue = nil
    _G.tinsert = table.insert
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    _G.strsplit = function(sep, s)
        local out, pos = {}, 1
        while true do
            local i = s:find(sep, pos, true)
            if not i then out[#out + 1] = s:sub(pos) break end
            out[#out + 1] = s:sub(pos, i - 1)
            pos = i + 1
        end
        return unpack(out)
    end
    _G.C_NamePlate = nil

    -- Chat channels and addon messages (Sync)
    H.channels = { General = 1 }     -- name -> channel id; slot 1 holds General
    H.joinWorks = true
    H.sent = {}                      -- { prefix, message, chatType, target } (accepted sends)
    H.attempts = {}                  -- every send attempt { chatType, result }
    H.sendResults = {}
    H.chatFilters = {}
    H.inCombat = false
    H.profileStep = 0                -- ms added per debugprofilestop() call
    H.profileNow = 0
    _G.securecall = function(fn, ...) return fn(...) end
    _G.GetChannelName = function(id)
        if type(id) == "number" then
            for name, channelID in pairs(H.channels) do
                if channelID == id then return channelID, name end
            end
            return 0
        end
        return H.channels[id] or 0
    end
    _G.JoinChannelByName = function(name)
        if H.joinWorks then H.channels[name] = 5 end
    end
    _G.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return true end,
        -- H.sendResults[chatType] overrides the result (Era: CHANNEL -> 4 InvalidChatType)
        SendAddonMessage = function(prefix, message, chatType, target)
            local result = H.sendResults[chatType] or 0
            H.attempts[#H.attempts + 1] = { chatType = chatType, result = result }
            if result ~= 0 then return result end
            H.sent[#H.sent + 1] = { prefix = prefix, message = message, chatType = chatType, target = target }
            return 0
        end,
    }
    _G.ChatFrame_AddMessageEventFilter = function(event, fn) H.chatFilters[event] = fn end
    -- Guild / group state (Era automatic routes)
    H.inGuild, H.inRaid, H.inGroup = false, false, false
    _G.IsInGuild = function() return H.inGuild end
    _G.IsInRaid = function() return H.inRaid end
    _G.IsInGroup = function() return H.inGroup or H.inRaid end

    -- Alert output
    H.centerTexts, H.sounds = {}, {}
    _G.RaidWarningFrame = {}
    _G.ChatTypeInfo = { RAID_WARNING = { r = 1, g = 0.3, b = 0.1 } }
    _G.RaidNotice_AddMessage = function(_, text) H.centerTexts[#H.centerTexts + 1] = text end
    _G.PlaySound = function(kit, channel) H.sounds[#H.sounds + 1] = kit end
    _G.SOUNDKIT = nil
    _G.OKAY, _G.CANCEL = "Okay", "Cancel"

    -- StaticPopup: H.popups records every StaticPopup_Show
    H.popups = {}
    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = function(which) H.popups[#H.popups + 1] = { which = which, text = _G.StaticPopupDialogs[which].text } end
    _G.StaticPopup_Hide = function() end

    H.chatSent = {}
    _G.SendChatMessage = function(text, chatType, language, target)
        H.chatSent[#H.chatSent + 1] = { text = text, chatType = chatType, target = target }
    end
    _G.UnitAffectingCombat = function() return H.inCombat end
    _G.debugprofilestop = function() H.profileNow = H.profileNow + H.profileStep; return H.profileNow end

    -- Combat log (Era): H.FireCLEU sets the current event
    H.cleu = {}
    -- Death recap (Forever): nil = no recap, otherwise a list of recap events
    H.recap = nil

    _G.WOW_PROJECT_CLASSIC = 2
    _G.WOW_PROJECT_MAINLINE = 1
    _G.WOW_PROJECT_ID = client.project
    _G.GetBuildInfo = function() return "1.0.0", "00000", "Jan 1 2026", client.iface end
    _G.C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
    _G.CombatLogGetCurrentEventInfo = (client ~= CLIENTS.forever)
        and function() return unpack(H.cleu, 1, H.cleu.n or #H.cleu) end or nil
    _G.C_EventUtils = nil
    _G.C_DeathRecap = (client == CLIENTS.forever) and {
        HasRecapEvents = function() return H.recap ~= nil and #H.recap > 0 end,
        GetRecapEvents = function() return H.recap end,
        GetRecapMaxHealth = function() return 100 end,
        GetRecapLink = function() return "[You died.]" end,
    } or nil

    _G.CreateFrame = function(_, name) return NewFrame(name) end
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        H.printed[#H.printed + 1] = table.concat(parts, " ")
    end
    _G.geterrorhandler = function()
        return function(err) H.errors[#H.errors + 1] = tostring(err) end
    end
    _G.date = os.date
    _G.time = os.time
    _G.GetTime = function() return H.clock end
    _G.GetServerTime = function() return H.serverTime end
    _G.C_Timer = {
        After = function(delay, fn) H.timers[#H.timers + 1] = { at = H.clock + delay, fn = fn } end,
    }
    _G.bit = {
        band = function(a, b)
            local result, bitValue = 0, 1
            while a > 0 and b > 0 do
                if a % 2 == 1 and b % 2 == 1 then result = result + bitValue end
                a, b, bitValue = math.floor(a / 2), math.floor(b / 2), bitValue * 2
            end
            return result
        end,
    }

    local function Unit(unit) return H.units[unit] end
    _G.UnitExists = function(unit) return Unit(unit) ~= nil end
    -- u.realm is UnitName's second value. On Forever that is the family name for
    -- other players; u.guidRealm is what GetPlayerInfoByGUID reports.
    _G.UnitName = function(unit) local u = Unit(unit); if u then return u.name, u.realm end end
    _G.GetUnitName = function(unit) local u = Unit(unit); return u and (u.fullName or u.name) end
    _G.UnitFullName = function(unit) local u = Unit(unit); if u then return u.name, u.realm end end
    _G.UnitLevel = function(unit) local u = Unit(unit); return u and u.level or 0 end
    _G.UnitClass = function(unit) local u = Unit(unit); if u then return u.class, u.class end end
    _G.UnitRace = function(unit) local u = Unit(unit); if u then return u.race, u.race end end
    _G.UnitSex = function(unit) local u = Unit(unit); return u and u.sex end
    _G.UnitGUID = function(unit) local u = Unit(unit); return u and u.guid end
    _G.UnitFactionGroup = function(unit) local u = Unit(unit); if u then return u.faction, u.faction end end
    _G.UnitIsPlayer = function(unit) local u = Unit(unit); return u ~= nil and u.isPlayer == true end
    _G.UnitIsDead = function(unit) local u = Unit(unit); return u ~= nil and u.dead == true end
    -- Pets: u.playerControlled, u.hostile, u.tooltip = { "line2", "line3" }
    _G.UnitPlayerControlled = function(unit) local u = Unit(unit); return u ~= nil and (u.playerControlled or u.isPlayer) == true end
    _G.UnitCanAttack = function(_, unit) local u = Unit(unit); return u ~= nil and (u.hostile or u.faction == "Horde") == true end
    _G.UNITNAME_TITLE_PET = "%s's Pet"
    _G.UNITNAME_TITLE_MINION = "%s's Minion"
    _G.UNITNAME_TITLE_GUARDIAN = "%s's Guardian"
    _G.C_TooltipInfo = {
        GetUnit = function(unit)
            local u = Unit(unit)
            if not u then return nil end
            local lines = { { leftText = u.name } }
            for _, text in ipairs(u.tooltip or {}) do lines[#lines + 1] = { leftText = text } end
            return { lines = lines }
        end,
    }
    _G.GetGuildInfo = function(unit) local u = Unit(unit); return u and u.guild end
    -- H.guidInfo[guid] = { class, race, sex, name, realm } for players seen only by GUID
    H.guidInfo = {}
    _G.GetPlayerInfoByGUID = function(guid)
        local info = H.guidInfo[guid]
        if info then
            return info.class, info.class, info.race, info.race, info.sex, info.name, info.realm
        end
        for _, u in pairs(H.units) do
            if u.guid == guid then
                return u.class, u.class, u.race, u.race, u.sex, u.name, u.guidRealm or H.realm
            end
        end
    end
    _G.GetNormalizedRealmName = function() return H.realm end
    _G.GetRealmName = function() return H.realm end
    _G.IsInInstance = function() return H.instance[1], H.instance[2] end

    _G.Enum = { UIMapType = { Continent = 2 } }
    _G.C_Map = {
        GetBestMapForUnit = function() return H.playerMap end,
        GetMapInfo = function(id) return H.maps[id] end,
        GetPlayerMapPosition = function()
            return { GetXY = function() return 0.42, 0.65 end }
        end,
        CanSetUserWaypointOnMap = function() return true end,
        SetUserWaypoint = function(point) H.waypoints[#H.waypoints + 1] = point end,
    }
end

-------------------------------------------------
-- Loading and events
-------------------------------------------------

-- Load every file listed in the real TOC, in order, with a fresh namespace
function H.Load()
    local ns = {}
    local toc = assert(io.open(ROOT .. "/HeadHunter.toc", "r"))
    for line in toc:lines() do
        line = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local path = ROOT .. "/" .. line:gsub("\\", "/")
            local chunk = assert(loadfile(path))
            chunk("HeadHunter", ns)
        end
    end
    toc:close()
    H.ns = ns
    return ns
end

function H.Fire(event, ...)
    for _, frame in ipairs(frames) do
        local onEvent = frame.scripts.OnEvent
        if frame.registered[event] and onEvent then
            onEvent(frame, event, ...)
        end
    end
end

-- Install + load + ADDON_LOADED + PLAYER_LOGIN + PLAYER_ENTERING_WORLD
function H.Boot(opts)
    H.Install(opts)
    local ns = H.Load()
    H.Fire("ADDON_LOADED", "HeadHunter")
    H.Fire("PLAYER_LOGIN")
    H.Fire("PLAYER_ENTERING_WORLD", true, false)
    return ns
end

function H.Advance(seconds)
    H.clock = H.clock + seconds
    local due = {}
    local pending = {}
    for _, timer in ipairs(H.timers) do
        if timer.at <= H.clock then due[#due + 1] = timer else pending[#pending + 1] = timer end
    end
    H.timers = pending
    for _, timer in ipairs(due) do timer.fn() end
end

-- Fire one combat log event. Arguments are CombatLogGetCurrentEventInfo's returns
-- from index 1 (timestamp) on; nils are allowed.
function H.FireCLEU(...)
    H.cleu = { n = select("#", ...), ... }
    H.Fire("COMBAT_LOG_EVENT_UNFILTERED")
end

-- Flags of a hostile player / hostile player-controlled pet, as the client sends them
H.FLAGS_HOSTILE_PLAYER = 0x548   -- TYPE_PLAYER | CONTROL_PLAYER | REACTION_HOSTILE | AFFILIATION_OUTSIDER
H.FLAGS_HOSTILE_PET = 0x1148     -- TYPE_PET | CONTROL_PLAYER | REACTION_HOSTILE | AFFILIATION_OUTSIDER
H.FLAGS_HOSTILE_NPC = 0xA48      -- TYPE_NPC | CONTROL_NPC | REACTION_HOSTILE | AFFILIATION_OUTSIDER
H.FLAGS_FRIENDLY_PLAYER = 0x511  -- TYPE_PLAYER | CONTROL_PLAYER | REACTION_FRIENDLY | AFFILIATION_MINE

-- Deliver addon messages to the currently booted client as if sent by `sender`
function H.Deliver(messages, sender)
    for _, m in ipairs(messages) do
        H.Fire("CHAT_MSG_ADDON", m.prefix or "HeadHunter", m.message or m, "CHANNEL", sender)
    end
    -- Let the inbox drain (it runs on C_Timer.After(0))
    for _ = 1, 20 do H.Advance(0) end
end

function H.Slash(input)
    _G.SlashCmdList.HEADHUNTER(input)
end

function H.Printed(pattern)
    for _, line in ipairs(H.printed) do
        if line:find(pattern) then return true end
    end
    return false
end

return H
