-- HH-092: High Noon records and ranks (docs/addon/features.md section 10).
--
-- Wins and losses per player from the duel set (Sync/Duels.lua); a retreat is a loss.
-- Order by net (wins minus losses), then fewer losses, then more wins (author,
-- 2026-09-25: no rating, 1-0 is better than 1-4). Listed from the first duel.
-- Ranks by net: Quickdraw, Sharpshooter (+5), Deadeye (+15), Legend (+30); under
-- MIN_DUELS a player is a Greenhorn (a label only, not a lower place). The same record
-- shares a place. The sole #1 of each faction is the Top Gun when they won more than
-- they lost; a shared #1 means no Top Gun yet. Two lists: Alliance and
-- Horde (duels stay inside a faction). The website ranks the same way.
--
--   HighNoon.Compute(duels) -> key -> player   (pure, tested offline)
--   HighNoon:Get(key), HighNoon:List(faction)  (listed players, best first, with .position)
-- Fires HH_HIGHNOON_UPDATED after a recompute.

local addonName, ns = ...
local L = ns.L

local HighNoon = ns:RegisterModule("HighNoon", {})

local OWNER = "HighNoon"

HighNoon.MIN_DUELS = 5
HighNoon.DEBOUNCE = 1
-- Highest first, by net wins
HighNoon.RANKS = {
    { min = 30, id = "legend" },
    { min = 15, id = "deadeye" },
    { min = 5, id = "sharpshooter" },
    { min = -math.huge, id = "quickdraw" },
}

-- Duels needed to lose the Greenhorn label; /hh debug duels <n> lowers it for testing
function HighNoon.MinDuels()
    local test = ns.db and ns.db.settings.testDuelMin
    return test or HighNoon.MIN_DUELS
end

function HighNoon.RankOf(player)
    if player.duels < HighNoon.MinDuels() then return "greenhorn" end
    for _, rank in ipairs(HighNoon.RANKS) do
        if player.net >= rank.min then return rank.id end
    end
    return "quickdraw"
end

-- The same record: they share a place
function HighNoon.Tied(a, b)
    return a.net == b.net and a.losses == b.losses and a.wins == b.wins
end

-- Best first: net, then fewer losses, then more wins (by name within a shared place)
function HighNoon.Better(a, b)
    if not HighNoon.Tied(a, b) then
        if a.net ~= b.net then return a.net > b.net end
        if a.losses ~= b.losses then return a.losses < b.losses end
        return a.wins > b.wins
    end
    return a.key < b.key
end

-- "+3", "0", "-2"
function HighNoon.NetText(net)
    return net > 0 and ("+" .. net) or tostring(net)
end

-- duels: array. Returns key -> { key, faction, wins, losses, duels, net, rank, lastT, class, race, sex }
function HighNoon.Compute(duels)
    local players = {}
    local function Player(key, faction, class, race, sex, t)
        local p = players[key]
        if not p then
            p = { key = key, wins = 0, losses = 0, duels = 0 }
            players[key] = p
        end
        -- The newest duel tells the current class, race and faction
        if not p.lastT or t >= p.lastT then
            p.faction = faction or p.faction
            p.class = class or p.class
            p.race = race or p.race
            p.sex = sex or p.sex
            p.lastT = t
        end
        return p
    end
    for _, duel in ipairs(duels) do
        local t = tonumber(duel.t) or 0
        local w = Player(duel.winner, duel.faction, duel.winnerClass, duel.winnerRace, duel.winnerSex, t)
        local l = Player(duel.loser, duel.faction, duel.loserClass, duel.loserRace, duel.loserSex, t)
        w.wins, l.losses = w.wins + 1, l.losses + 1
        w.duels, l.duels = w.duels + 1, l.duels + 1
    end
    for _, p in pairs(players) do
        p.net = p.wins - p.losses
        p.rank = HighNoon.RankOf(p)
    end
    return players
end

-------------------------------------------------
-- Runtime
-------------------------------------------------

local players = {}
local lists = {}          -- faction -> listed players, best first
local scheduled = false

function HighNoon:Recompute()
    local duels = {}
    for _, duel in ns.Duels:All() do duels[#duels + 1] = duel end
    players = HighNoon.Compute(duels)
    lists = {}
    for _, p in pairs(players) do
        if p.faction and p.duels >= 1 then
            lists[p.faction] = lists[p.faction] or {}
            table.insert(lists[p.faction], p)
        end
    end
    for _, list in pairs(lists) do
        table.sort(list, HighNoon.Better)
        for i, p in ipairs(list) do
            local previous = list[i - 1]
            p.position = previous and HighNoon.Tied(previous, p) and previous.position or i
        end
        -- Top Gun: the faction's sole leader, with a winning record (a shared #1 has none)
        local first, second = list[1], list[2]
        for _, p in ipairs(list) do p.topGun = nil end
        if first and first.net > 0 and not (second and second.position == 1) then first.topGun = true end
    end
    ns.Events:Fire("HH_HIGHNOON_UPDATED")
end

function HighNoon:RequestRecompute()
    if scheduled then return end
    scheduled = true
    C_Timer.After(self.DEBOUNCE, function()
        scheduled = false
        HighNoon:Recompute()
    end)
end

function HighNoon:Get(key)
    return key and players[key]
end

-- Listed players of one faction, best first
function HighNoon:List(faction)
    return lists[faction] or {}
end

function HighNoon.RankName(rank)
    return L["DUEL_RANK_" .. tostring(rank):upper()]
end

-- "Deadeye #3 (+16)", "Top Gun (+20)", "Greenhorn (2 duels)"
function HighNoon.Title(player)
    if not player then return nil end
    if player.topGun then return string.format(L.DUEL_TITLE_TOPGUN, HighNoon.NetText(player.net)) end
    if player.duels < HighNoon.MinDuels() then
        return string.format(L.DUEL_TITLE_GREENHORN, HighNoon.RankName("greenhorn"), player.duels)
    end
    return string.format(L.DUEL_TITLE, HighNoon.RankName(player.rank), player.position or 0,
        HighNoon.NetText(player.net))
end

ns.Events:Register("HH_INITIALIZED", function()
    ns.Events:Register("HH_DUEL_ADDED", function() HighNoon:RequestRecompute() end, OWNER)
    HighNoon:RequestRecompute() -- duels restored from SavedVariables
end, OWNER)

-- /hh duels: the top 10 of our faction, and where we stand
ns.SlashCommands:Register("duels", function()
    local U = ns.Utils
    local faction = U.UnitFaction("player")
    local list = HighNoon:List(faction)
    ns:Print(string.format(L.DUELS_HEADER, faction or "?", #list))
    for i = 1, math.min(10, #list) do
        local p = list[i]
        print(string.format("  #%d  %s  %s  %s  (%d-%d)", i, U.DisplayName(p.key) or p.key,
            HighNoon.RankName(p.rank), HighNoon.NetText(p.net), p.wins, p.losses))
    end
    local me = HighNoon:Get(U.UnitKey("player"))
    if me then ns:Print(string.format(L.DUELS_YOU, HighNoon.Title(me), me.wins, me.losses)) end
end, L.HELP_DUELS)
