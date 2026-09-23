-- HH-007 spike: find out, in game, what each client offers for killer detection.
--
--   /hh probe        one-shot report of API/event availability (+ current target)
--   /hh probe watch  toggle live logging of combat and death signals
--
-- Everything goes to the debug log (/hh log), which is copyable, so results can be
-- pasted into docs/addon/README.md.

local addonName, ns = ...
local L = ns.L

local Probe = ns:RegisterModule("Probe", {})

local OWNER = "Probe"

local function Write(...)
    ns.Log:Add("probe", ns.Join(...))
end

-- tostring can raise on a secret value; show a marker instead
local function Show(value)
    if value ~= nil and ns.Utils.Accessible(value) == nil then
        return "<secret>"
    end
    local ok, text = pcall(tostring, value)
    return ok and text or "<unprintable>"
end

local function ShowAll(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = Show((select(i, ...)))
    end
    return table.concat(parts, ", ")
end

-------------------------------------------------
-- Availability
-------------------------------------------------

local scratch = CreateFrame("Frame")

local function EventAvailable(event)
    if ns.Events.IsRestricted(event) then
        return "restricted (never registered on this client)"
    end
    if C_EventUtils and C_EventUtils.IsEventValid then
        local ok, valid = pcall(C_EventUtils.IsEventValid, event)
        if ok then return valid and "yes" or "no" end
    end
    local ok = pcall(scratch.RegisterEvent, scratch, event)
    if ok then
        scratch:UnregisterEvent(event)
        return "yes (registered)"
    end
    return "no (register failed)"
end

local function Exists(value)
    return value ~= nil and "yes" or "no"
end

local function FunctionNames(tbl)
    if type(tbl) ~= "table" then return "-" end
    local names = {}
    for key, value in pairs(tbl) do
        if type(value) == "function" then names[#names + 1] = key end
    end
    table.sort(names)
    return table.concat(names, " ")
end

local EVENTS = {
    "COMBAT_LOG_EVENT_UNFILTERED", "PLAYER_DEAD", "PARTY_KILL", "PLAYER_PVP_KILLS_CHANGED",
    "UNIT_COMBAT", "CHAT_MSG_COMBAT_HONOR_GAIN", "NAME_PLATE_UNIT_ADDED", "UPDATE_MOUSEOVER_UNIT",
    "PLAYER_TARGET_CHANGED", "UNIT_TARGET", "DUEL_REQUESTED", "DUEL_FINISHED",
}

local function ReportTarget()
    local U = ns.Utils
    if not UnitExists("target") then
        Write("target: none (target an enemy player and run /hh probe again)")
        return
    end
    Write("target raw UnitName:", ShowAll(U.SafeCall(UnitName, "target")))
    Write("target raw GetUnitName(true):", ShowAll(U.SafeCall(GetUnitName, "target", true)),
        "UnitFullName:", ShowAll(U.SafeCall(UnitFullName, "target")))
    Write("player raw UnitName:", ShowAll(U.SafeCall(UnitName, "player")),
        "GetUnitName(true):", ShowAll(U.SafeCall(GetUnitName, "player", true)))
    Write("target key:", Show(U.UnitKey("target")), "enemy player:", Show(U.UnitIsEnemyPlayer("target")))
    Write("target level:", Show(U.UnitLevel("target")), "class:", Show(U.UnitClass("target")),
        "race:", Show(U.UnitRace("target")), "sex:", Show(U.UnitSex("target")),
        "guild:", Show(U.UnitGuild("target")), "faction:", Show(U.UnitFaction("target")))
    local guid = U.UnitGUID("target")
    Write("target GUID:", Show(guid))
    if guid and GetPlayerInfoByGUID then
        Write("GetPlayerInfoByGUID:", ShowAll(U.SafeCall(GetPlayerInfoByGUID, guid)))
    end
end

function Probe:Run()
    local E = ns.Expansion
    Write("==== HeadHunter probe", ns.version, "====")
    Write("build:", ShowAll(GetBuildInfo()))
    Write("client:", E.ClientKey, "interface:", E.InterfaceVersion, "WOW_PROJECT_ID:", Show(WOW_PROJECT_ID))
    Write("SavedVariables restored from disk this load:", Show(ns.Database.restoredFromDisk),
        "loadCount:", Show(ns.db and ns.db.meta.loadCount))

    for _, event in ipairs(EVENTS) do
        Write("event", event .. ":", EventAvailable(event))
    end

    Write("CombatLogGetCurrentEventInfo:", Exists(CombatLogGetCurrentEventInfo))
    Write("GetPlayerInfoByGUID:", Exists(GetPlayerInfoByGUID))
    Write("C_DeathRecap:", Exists(C_DeathRecap), "functions:", FunctionNames(C_DeathRecap))
    Write("C_Map.SetUserWaypoint:", Exists(C_Map and C_Map.SetUserWaypoint),
        "CanSetUserWaypointOnMap:", Exists(C_Map and C_Map.CanSetUserWaypointOnMap))
    Write("TooltipDataProcessor:", Exists(TooltipDataProcessor), "Settings API:", Exists(Settings and Settings.RegisterCanvasLayoutCategory))
    Write("C_ChatInfo.SendAddonMessage:", Exists(C_ChatInfo and C_ChatInfo.SendAddonMessage),
        "C_BattleNet.SendGameData:", Exists(C_BattleNet and C_BattleNet.SendGameData))
    Write("canaccessvalue:", Exists(canaccessvalue), "issecretvalue:", Exists(issecretvalue))
    Write("GetServerTime:", Exists(GetServerTime), "realm:", Show(ns.Utils.PlayerRealm()),
        "player key:", Show(ns.Utils.UnitKey("player")))

    local mapID = ns.Utils.PlayerMapID()
    Write("map:", Show(mapID), Show(ns.Utils.MapName(mapID)), "continent:", Show(ns.Utils.ContinentOf(mapID)),
        "pos:", ShowAll(ns.Utils.PlayerPosition(mapID)))

    ReportTarget()
    Write("==== end probe ====")
end

-------------------------------------------------
-- Watch mode
-------------------------------------------------

local function DumpDeathRecap()
    if not C_DeathRecap then
        Write("death recap: C_DeathRecap missing")
        return
    end
    for _, fnName in ipairs({ "HasRecapEvents", "GetRecapEvents", "GetRecapMaxHealth", "GetRecapLink" }) do
        local fn = C_DeathRecap[fnName]
        if fn then
            local ok, result = pcall(fn)
            Write("death recap", fnName .. "():", ok and Show(result) or ("error " .. Show(result)))
            if ok and type(result) == "table" then
                local first = result[1]
                if type(first) == "table" then
                    local fields = {}
                    for key, value in pairs(first) do
                        fields[#fields + 1] = key .. "=" .. Show(value)
                    end
                    Write("death recap first event:", table.concat(fields, " "))
                end
                Write("death recap events:", #result)
            end
        end
    end
end

local function OnCombatLog()
    if not CombatLogGetCurrentEventInfo then return end
    local info = { CombatLogGetCurrentEventInfo() }
    local subevent, sourceFlags, destGUID = info[2], info[6], info[8]
    if destGUID ~= UnitGUID("player") or type(sourceFlags) ~= "number" then return end
    local isPlayer = bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_PLAYER or 0x400) > 0
    local isHostile = bit.band(sourceFlags, COMBATLOG_OBJECT_REACTION_HOSTILE or 0x40) > 0
    if not (isPlayer and isHostile) then return end
    Write("CLEU", subevent, "from", Show(info[5]), Show(info[4]), "args:", ShowAll(unpack(info, 12, 18)))
end

local WATCHED = {
    PLAYER_DEAD = function()
        Write("PLAYER_DEAD at", date("%H:%M:%S"), "target:", Show(ns.Utils.UnitKey("target")))
        C_Timer.After(1, DumpDeathRecap)
    end,
    PARTY_KILL = function(_, ...) Write("PARTY_KILL", ShowAll(...)) end,
    PLAYER_PVP_KILLS_CHANGED = function(_, ...) Write("PLAYER_PVP_KILLS_CHANGED", ShowAll(...)) end,
    CHAT_MSG_COMBAT_HONOR_GAIN = function(_, ...) Write("HONOR_GAIN", ShowAll(...)) end,
    UNIT_COMBAT = function(_, unit, ...)
        if unit == "player" then Write("UNIT_COMBAT player", ShowAll(...)) end
    end,
    NAME_PLATE_UNIT_ADDED = function(_, unit)
        if ns.Utils.UnitIsEnemyPlayer(unit) then
            Write("nameplate enemy", Show(ns.Utils.UnitKey(unit)), "level", Show(ns.Utils.UnitLevel(unit)),
                Show(ns.Utils.UnitClass(unit)), Show(ns.Utils.UnitRace(unit)))
        end
    end,
    COMBAT_LOG_EVENT_UNFILTERED = OnCombatLog,
}

function Probe:SetWatch(on)
    self.watching = on
    for event, handler in pairs(WATCHED) do
        if ns.Events.IsRestricted(event) then
            if on then Write("watch", event .. ": restricted, skipped") end
        elseif on then
            local ok = ns.Events:Register(event, handler, OWNER)
            Write("watch", event .. ":", ok and "registered" or "NOT available")
        else
            ns.Events:Unregister(event, OWNER)
        end
    end
end

ns.SlashCommands:Register("probe", function(args)
    if args[1] and args[1]:lower() == "watch" then
        Probe:SetWatch(not Probe.watching)
        ns:Print(Probe.watching and L.PROBE_WATCH_ON or L.PROBE_WATCH_OFF)
        return
    end
    Probe:Run()
    ns:Print(L.PROBE_DONE)
    ns.Log:Show()
end, L.HELP_PROBE)
