-- HH-005: inject fake data so rules, alerts and UI can be tested without real gankers.
--
--   /hh sim death "<name>" <level|skull> <CLASS> <RACE> [sex]
--   /hh sim sighting "<name>" <level|skull> <CLASS> <RACE> [sex]
--
-- Forever names contain a space, so quote them: /hh sim death "Grim Reaper" skull ROGUE Human
-- Simulated data goes through the same internal events as real data:
--   HH_DEATH_REPORT(report, source)   consumed from HH-013 on
--   HH_ENEMY_SEEN(enemy, source)      consumed from HH-010 on

local addonName, ns = ...
local L = ns.L

local Simulator = ns:RegisterModule("Simulator", {})

local CLASSES = {
    WARRIOR = true, PALADIN = true, HUNTER = true, ROGUE = true, PRIEST = true,
    SHAMAN = true, MAGE = true, WARLOCK = true, DRUID = true,
}

local serial = 0

-- Returns an enemy record or nil + usage error
function Simulator:ParseEnemy(args)
    local U = ns.Utils
    local key = U.PlayerKey(args[1])
    if not key then
        return nil, string.format(L.SIM_BAD_NAME, tostring(args[1]))
    end
    local levelArg = args[2] and args[2]:lower()
    local level = levelArg == "skull" and -1 or tonumber(levelArg)
    local class = args[3] and args[3]:upper()
    local race = args[4]
    if not level or not CLASSES[class] or not race then
        return nil
    end
    local sex = tonumber(args[5])
    if sex ~= 2 and sex ~= 3 then sex = 1 end
    return {
        key = key,
        level = level,
        class = class,
        race = race,
        sex = sex,
        lastSeen = U.ServerTime(),
    }
end

local function PlayerSnapshot()
    local U = ns.Utils
    return {
        key = U.UnitKey("player"),
        level = U.UnitLevel("player"),
        class = U.UnitClass("player"),
        race = U.UnitRace("player"),
    }
end

-- Same shape as a real death report (HH-013)
function Simulator:BuildDeathReport(killer)
    local U = ns.Utils
    local now = U.ServerTime()
    serial = serial + 1
    local victim = PlayerSnapshot()
    local mapID = U.PlayerMapID()
    local x, y = U.PlayerPosition(mapID)
    return {
        id = string.format("%s:%d:sim%d", victim.key or "?", now, serial),
        t = now,
        victim = victim,
        killer = killer,
        assists = {},
        mapID = mapID,
        x = x,
        y = y,
        confidence = "sim",
    }
end

local function Describe(enemy)
    local level = enemy.level == -1 and "skull" or tostring(enemy.level)
    return string.format("%s %s %s", level, enemy.race, enemy.class)
end

-- /hh sim send "<killer>" [kills] [level] [class] [race]
-- Debug only. Simulated deaths OF THIS CHARACTER, sent over the real sync so a
-- second character receives them (two-character tests of alerts and posses).
-- Must run from the typed command: on Era the realm-wide send needs that
-- hardware event.
function Simulator:Send(args)
    local U = ns.Utils
    if not ns.debugMode then
        ns:Print(L.SIM_SEND_NEEDS_DEBUG)
        return
    end
    local key = U.PlayerKey(args[1])
    local count = tonumber(args[2]) or 1
    if not key or count < 1 or count > 10 then
        ns:Print(L.SIM_SEND_USAGE)
        return
    end
    local levelArg = args[3] and args[3]:lower()
    local level = levelArg == "skull" and -1 or tonumber(levelArg) or 60
    local class = (args[4] and args[4]:upper()) or "ROGUE"
    if not CLASSES[class] then class = "ROGUE" end
    local race = args[5] or "Orc"

    local victim = PlayerSnapshot()
    local mapID = U.PlayerMapID()
    local x, y = U.PlayerPosition(mapID)
    local now = U.ServerTime()
    local records = {}
    for i = 1, count do
        local t = now - (count - i) * 60
        local report = {
            id = victim.key .. ":" .. t,
            t = t,
            victim = { key = victim.key, level = victim.level, class = victim.class, race = victim.race },
            killer = { key = key, name = key, level = level, class = class, race = race },
            assists = {},
            mapID = mapID, x = x, y = y,
            layer = ns.Layer:Current(),
            confidence = "sim",
        }
        if ns.Reports:Add(report, "sim") then
            local record = ns.Protocol.EncodeDeath(report,
                ns.Protocol.MAX_MESSAGE - 4 - #ns.Transport.CHAT_MARK)
            if record then
                records[#records + 1] = record
                ns.Transport:Queue(ns.Protocol.TYPES.DEATH, record, ns.Transport.PRIORITY.alert, "D:" .. report.id)
            end
        end
    end
    if ns.Transport:RealmWideNeedsClick() and #records > 0 then
        ns.Transport:SendRealmWide(ns.Protocol.TYPES.DEATH, records)
    end
    ns:Print(string.format(L.SIM_SENT, #records, U.DisplayName(key)))
end

ns.SlashCommands:Register("sim", function(args)
    local kind = table.remove(args, 1)
    kind = kind and kind:lower()
    if kind == "send" then
        Simulator:Send(args)
        return
    end
    if kind ~= "death" and kind ~= "sighting" then
        print(L.SIM_USAGE_DEATH)
        print(L.SIM_USAGE_SIGHTING)
        return
    end
    local enemy, err = Simulator:ParseEnemy(args)
    if not enemy then
        ns:Print(err or (kind == "death" and L.SIM_USAGE_DEATH or L.SIM_USAGE_SIGHTING))
        return
    end
    if kind == "death" then
        local report = Simulator:BuildDeathReport(enemy)
        ns:Debug("sim death report", report.id)
        ns.Events:Fire("HH_DEATH_REPORT", report, "sim")
        ns:Print(string.format(L.SIM_DEATH, enemy.key, Describe(enemy)))
    else
        ns:Debug("sim sighting", enemy.key)
        ns.Events:Fire("HH_ENEMY_SEEN", enemy, "sim")
        ns:Print(string.format(L.SIM_SIGHTING, enemy.key, Describe(enemy)))
    end
end, L.HELP_SIM)
