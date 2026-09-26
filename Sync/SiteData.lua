-- HH-082: data from the website, written by the desktop sync app into the separate
-- addon HeadHunter_Data (Data.lua sets HeadHunter_SiteData; listed as OptionalDeps, so
-- it loads before us). The game loads it as addon code, so it also works on WoW
-- Forever, where saved variables are not loaded back.
--
-- The file keeps the website's names (the /api/v1/sync/download answer):
--   worlds["era|eu|Firemaw"] / ["forever|us|pvp"] = { generated_at, wanted = {...},
--     duels = { alliance = {...}, horde = {...} } }
--   characters = { { world, name, deaths, duels, catches, bounty = { total, events } } }
-- This module picks our world, maps names to the addon's (player keys, "ROGUE",
-- "Scourge", "mostwanted") and:
--   * gives Wanted and HighNoon the website's lists to merge with what we saw
--     (Rules/Wanted.lua MergeSite, Rules/HighNoon.lua Merge)
--   * restores our own deaths, duels, catches and bounty events at login, marked
--     origin "website" so the sync app never uploads them again
--   * tells us at login when we are on the website's WANTED list ourselves: the other
--     faction's reports never reach our addon, so this is the only way to learn it
--
--   SiteData:Wanted() -> id -> WANTED entry     SiteData:Duelists() -> key -> player
--   SiteData:GeneratedAt()                      nil when there is no data for our world

local addonName, ns = ...

local SiteData = ns:RegisterModule("SiteData", {})

local OWNER = "SiteData"

SiteData.FORMAT_VERSION = 1
SiteData.ORIGIN = "website"

local RACES = {
    human = "Human", dwarf = "Dwarf", night_elf = "NightElf", gnome = "Gnome", draenei = "Draenei",
    orc = "Orc", undead = "Scourge", tauren = "Tauren", troll = "Troll", blood_elf = "BloodElf",
}
local FACTIONS = { alliance = "Alliance", horde = "Horde" }

local world, wanted, duelists

-------------------------------------------------
-- Names
-------------------------------------------------

local function Number(value)
    return type(value) == "number" and value or nil
end

local function Text(value)
    return type(value) == "string" and value ~= "" and value or nil
end

function SiteData.Class(class)
    return Text(class) and class:upper() or nil
end

function SiteData.Race(race)
    return Text(race) and RACES[race] or nil
end

function SiteData.Faction(faction)
    return Text(faction) and FACTIONS[faction] or nil
end

-- "most_wanted" -> "mostwanted", "serial_killer" -> "serialkiller"
function SiteData.Token(value)
    return Text(value) and (value:gsub("_", "")) or nil
end

-- { name, realm } -> the addon's player key
function SiteData.Key(person)
    if type(person) ~= "table" then return nil end
    return ns.Utils.PlayerKey(Text(person.name), Text(person.realm))
end

-------------------------------------------------
-- Our world
-------------------------------------------------

local function Split(key)
    return key:match("^([^|]+)|([^|]+)|(.+)$")
end

-- Ours: same client and region (when known) and, on Era, the same realm
local function IsOurWorld(key)
    if type(key) ~= "string" then return false end
    local client, region, place = Split(key)
    if client ~= ns.Expansion.ClientKey then return false end
    local myRegion = (ns.db and ns.db.meta.region) or ns.Utils.Region()
    if myRegion and region ~= myRegion then return false end
    if ns.Features.RealmlessNames then return true end
    local realm = ns.Utils.PlayerRealm()
    return realm ~= nil and place:gsub("%s", ""):lower() == realm:gsub("%s", ""):lower()
end

-- The first matching world, by key, so the choice does not depend on table order
local function FindWorld(data)
    if type(data.worlds) ~= "table" then return nil end
    local keys = {}
    for key in pairs(data.worlds) do
        if IsOurWorld(key) and type(data.worlds[key]) == "table" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return keys[1] and data.worlds[keys[1]]
end

local function Data()
    local data = _G.HeadHunter_SiteData
    if type(data) ~= "table" or data.format_version ~= SiteData.FORMAT_VERSION then return nil end
    return data
end

-------------------------------------------------
-- Lists
-------------------------------------------------

function SiteData.WantedEntry(w)
    local key = SiteData.Key(w)
    local rank = SiteData.Token(w.rank)
    local wantedUntil = Number(w.wanted_until)
    if not key or not rank or not ns.RulesEngine.RANK_ORDER[rank] or not wantedUntil then return nil end
    local badges = {}
    for _, badge in ipairs(type(w.badges) == "table" and w.badges or {}) do
        if Text(badge) then badges[SiteData.Token(badge)] = true end
    end
    local kills = Number(w.kills) or 0
    local lastKillAt = Number(w.last_kill_at)
    return {
        id = key, key = key, name = key,
        level = Number(w.level), class = SiteData.Class(w.class), race = SiteData.Race(w.race), sex = Number(w.sex),
        wanted = true, rank = rank, peakRank = rank, kills = kills,
        wantedSince = Number(w.wanted_since), wantedUntil = wantedUntil,
        timesWanted = Number(w.times_wanted) or 1, timesCaught = Number(w.times_caught) or 0,
        killCount = Number(w.kill_count) or math.floor(kills), cowardKills = Number(w.coward_kills) or 0,
        badges = badges,
        lastKill = lastKillAt and { t = lastKillAt, mapID = Number(w.last_map_id) } or nil,
        source = SiteData.ORIGIN,
    }
end

function SiteData.Duelist(d, faction)
    local key = SiteData.Key(d)
    local wins, losses = Number(d.wins), Number(d.losses)
    if not key or not wins or not losses then return nil end
    return {
        key = key, faction = faction,
        class = SiteData.Class(d.class), race = SiteData.Race(d.race), sex = Number(d.sex),
        wins = wins, losses = losses, duels = Number(d.duels) or (wins + losses),
        lastT = Number(d.last_duel_at),
        source = SiteData.ORIGIN,
    }
end

function SiteData:Load()
    world, wanted, duelists = nil, nil, nil
    local data = Data()
    world = data and FindWorld(data)
    if not world then return false end
    wanted = {}
    for _, w in ipairs(type(world.wanted) == "table" and world.wanted or {}) do
        local entry = type(w) == "table" and SiteData.WantedEntry(w)
        if entry then wanted[entry.id] = entry end
    end
    duelists = {}
    for token, faction in pairs(FACTIONS) do
        local list = type(world.duels) == "table" and world.duels[token]
        for _, d in ipairs(type(list) == "table" and list or {}) do
            local player = type(d) == "table" and SiteData.Duelist(d, faction)
            if player then duelists[player.key] = player end
        end
    end
    return true
end

function SiteData:GeneratedAt()
    return world and Number(world.generated_at)
end

function SiteData:Wanted()
    return wanted
end

function SiteData:Duelists()
    return duelists
end

-------------------------------------------------
-- Our own records
-------------------------------------------------

local function Enemy(attacker)
    local level = attacker.skull and -1 or Number(attacker.level)
    local key = SiteData.Key(attacker)
    if key then
        return { key = key, name = key, level = level, class = SiteData.Class(attacker.class),
            race = SiteData.Race(attacker.race), sex = Number(attacker.sex) }
    end
    local guid = Text(attacker.guid)
    if not guid then return nil end
    return { guid = guid, name = Text(attacker.given_name), nameIncomplete = true, level = level,
        class = SiteData.Class(attacker.class), race = SiteData.Race(attacker.race) }
end

function SiteData.Death(d, me)
    local t = Number(d.t)
    if not t or type(d.attackers) ~= "table" then return nil end
    local killer, assists = nil, {}
    for _, attacker in ipairs(d.attackers) do
        local enemy = type(attacker) == "table" and Enemy(attacker)
        if enemy then
            if attacker.role == "killer" and not killer then killer = enemy else assists[#assists + 1] = enemy end
        end
    end
    killer = killer or table.remove(assists, 1)
    if not killer then return nil end
    return {
        id = me .. ":" .. t, t = t,
        victim = { key = me, level = Number(d.victim_level), class = SiteData.Class(d.victim_class),
            race = SiteData.Race(d.victim_race) },
        killer = killer, assists = assists,
        mapID = Number(d.map_id), x = Number(d.x), y = Number(d.y), layer = Number(d.layer),
        confidence = Text(d.confidence) or "inferred", classification = Text(d.classification),
        origin = SiteData.ORIGIN,
    }
end

function SiteData.DuelRecord(d)
    local winner, loser = type(d.winner) == "table" and d.winner, type(d.loser) == "table" and d.loser
    local t = Number(d.t)
    if not winner or not loser or not t then return nil end
    return {
        winner = SiteData.Key(winner), loser = SiteData.Key(loser), t = t,
        mapID = Number(d.map_id), retreat = d.retreat == true or nil, faction = SiteData.Faction(d.faction),
        winnerClass = SiteData.Class(winner.class), winnerRace = SiteData.Race(winner.race),
        winnerSex = Number(winner.sex), winnerLevel = Number(d.winner_level),
        loserClass = SiteData.Class(loser.class), loserRace = SiteData.Race(loser.race),
        loserSex = Number(loser.sex), loserLevel = Number(d.loser_level),
    }
end

function SiteData.Catch(c, me)
    local outlaw, t = SiteData.Key(c.outlaw), Number(c.t)
    if not outlaw or not t then return nil end
    return { id = outlaw .. ":" .. t, outlaw = outlaw, t = t, mapID = Number(c.map_id),
        killer = Text(c.killer_name), hunter = me }
end

function SiteData.MarksEvent(e, me)
    local t, delta = Number(e.t), Number(e.bounty)
    if not t or not delta or not Text(e.type) then return nil end
    return { t = t, delta = delta, reason = e.type, outlaw = Text(e.outlaw_name), rank = SiteData.Token(e.outlaw_rank),
        total = Number(e.total_after), hunter = me, origin = SiteData.ORIGIN }
end

local function RestoreDeaths(list, me)
    local db, added = ns.db, 0
    for _, d in ipairs(list) do
        local report = type(d) == "table" and SiteData.Death(d, me)
        if report and not ns.DeathReports:Find(report.id) then
            db.deaths[#db.deaths + 1] = report
            added = added + 1
        end
    end
    if added > 0 then
        table.sort(db.deaths, function(a, b) return (a.t or 0) < (b.t or 0) end)
        ns.Database:Prune()
    end
    return added
end

local function RestoreMarks(bounty, me, isMe)
    local store = ns.db.marks
    local seen, added = {}, 0
    for _, event in ipairs(store.events) do
        seen[table.concat({ event.t or 0, event.reason or "", event.hunter or "" }, "|")] = true
    end
    for _, e in ipairs(type(bounty.events) == "table" and bounty.events or {}) do
        local event = type(e) == "table" and SiteData.MarksEvent(e, me)
        local id = event and table.concat({ event.t, event.reason, me }, "|")
        if event and not seen[id] then
            seen[id] = true
            store.events[#store.events + 1] = event
            added = added + 1
        end
    end
    if added > 0 then
        table.sort(store.events, function(a, b) return (a.t or 0) < (b.t or 0) end)
        while #store.events > ns.Marks.MAX_EVENTS do table.remove(store.events, 1) end
    end
    -- The addon keeps one total for the account; the character we play shows theirs
    if isMe and Number(bounty.total) and bounty.total > (store.total or 0) then
        store.total = bounty.total
        added = added + 1
    end
    return added
end

-- Returns how many records were added
function SiteData:Restore()
    local data = Data()
    if not (data and ns.db and type(data.characters) == "table") then return 0 end
    local myKey = ns.Utils.UnitKey("player")
    local added = 0
    for _, c in ipairs(data.characters) do
        local me
        if type(c) == "table" and IsOurWorld(c.world) then
            local _, _, place = Split(c.world)
            me = ns.Utils.PlayerKey(Text(c.name), not ns.Features.RealmlessNames and place or nil)
        end
        if me then
            added = added + RestoreDeaths(type(c.deaths) == "table" and c.deaths or {}, me)
            for _, d in ipairs(type(c.duels) == "table" and c.duels or {}) do
                local duel = type(d) == "table" and SiteData.DuelRecord(d)
                if duel and ns.Duels:Add(duel, SiteData.ORIGIN) then added = added + 1 end
            end
            for _, j in ipairs(type(c.catches) == "table" and c.catches or {}) do
                local record = type(j) == "table" and SiteData.Catch(j, me)
                if record and ns.Justice:Add(record, SiteData.ORIGIN) then added = added + 1 end
            end
            if type(c.bounty) == "table" then
                added = added + RestoreMarks(c.bounty, me, ns.Utils.SameCharacter(me, myKey))
            end
        end
    end
    if added > 0 then ns.Events:Fire("HH_MARKS_CHANGED", ns.db.marks.total) end
    return added
end

-- Our own entry in the website's WANTED list, while it runs
function SiteData:SelfWanted(now)
    local me = ns.Utils.UnitKey("player")
    if not me then return nil end
    now = now or ns.Utils.ServerTime()
    for _, entry in pairs(wanted or {}) do
        if ns.Utils.SameCharacter(entry.key, me) and entry.wantedUntil > now then return entry end
    end
    return nil
end

SiteData.SELF_WANTED_DELAY = 10  -- after login, once the chat is up

function SiteData:TellSelfWanted()
    local entry = self:SelfWanted()
    if not entry then return false end
    local L, U = ns.L, ns.Utils
    local enemies = U.UnitFaction("player") == "Horde" and "Alliance" or "Horde"
    local rank = ns.Wanted.RankName(entry.rank)
    local age = U.Ago(math.max(0, U.ServerTime() - (self:GeneratedAt() or U.ServerTime())))
    return ns.Alerts:Show({
        key = "self-wanted",
        throttle = 0,
        text = L.SELF_WANTED_CENTER,
        chat = string.format(L.SELF_WANTED, enemies, rank, math.floor(entry.kills or 0), age),
        sound = "soft",
    }) ~= false
end

ns.Events:Register("HH_INITIALIZED", function()
    SiteData:Load()
end, OWNER)

-- Our character is known at login
ns.Events:Register("PLAYER_LOGIN", function()
    if not ns.db then return end
    SiteData:Load()
    local added = SiteData:Restore()
    if added > 0 then ns:Debug("Website data restored", added, "records") end
    ns.Wanted:RequestRecompute()
    ns.HighNoon:RequestRecompute()
    C_Timer.After(SiteData.SELF_WANTED_DELAY, function() SiteData:TellSelfWanted() end)
end, OWNER)
