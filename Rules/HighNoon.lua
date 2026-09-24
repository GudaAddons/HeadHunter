-- HH-092: High Noon ratings and ranks (docs/addon/features.md section 10).
--
-- Elo per player, computed from the duel set (Sync/Duels.lua) in time order, so every
-- client gets the same numbers. Start 1000, K = 32; a retreat is a loss.
-- Listed from the first duel (author, 2026-09-24). Ranks: Greenhorn (under MIN_DUELS),
-- then by rating Quickdraw, Sharpshooter (1100), Deadeye (1200), Legend (1300). The best
-- non-Greenhorn of each faction is the Top Gun. Two lists: Alliance and Horde (duels stay inside a faction).
--
--   HighNoon.Compute(duels) -> key -> player   (pure, tested offline)
--   HighNoon:Get(key), HighNoon:List(faction)  (listed players, best first, with .position)
-- Fires HH_HIGHNOON_UPDATED after a recompute.

local addonName, ns = ...
local L = ns.L

local HighNoon = ns:RegisterModule("HighNoon", {})

local OWNER = "HighNoon"

HighNoon.START = 1000
HighNoon.K = 32
HighNoon.MIN_DUELS = 5
HighNoon.DEBOUNCE = 1
-- Highest first
HighNoon.RANKS = {
    { min = 1300, id = "legend" },
    { min = 1200, id = "deadeye" },
    { min = 1100, id = "sharpshooter" },
    { min = -math.huge, id = "quickdraw" },
}

-- Chance that a player rated `a` beats one rated `b`
function HighNoon.Expected(a, b)
    return 1 / (1 + 10 ^ ((b - a) / 400))
end

-- Duels needed to be listed; /hh debug duels <n> lowers it for testing
function HighNoon.MinDuels()
    local test = ns.db and ns.db.settings.testDuelMin
    return test or HighNoon.MIN_DUELS
end

function HighNoon.RankOf(player)
    if player.duels < HighNoon.MinDuels() then return "greenhorn" end
    for _, rank in ipairs(HighNoon.RANKS) do
        if player.rating >= rank.min then return rank.id end
    end
    return "quickdraw"
end

-- duels: array. Returns key -> { key, faction, rating, wins, losses, duels, lastT, class, race }
function HighNoon.Compute(duels)
    local list = {}
    for _, duel in ipairs(duels) do list[#list + 1] = duel end
    table.sort(list, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return (a.id or "") < (b.id or "")
    end)
    local players = {}
    local function Player(key, faction, class, race)
        local p = players[key]
        if not p then
            p = { key = key, rating = HighNoon.START, wins = 0, losses = 0, duels = 0 }
            players[key] = p
        end
        p.faction = faction or p.faction
        p.class = class or p.class
        p.race = race or p.race
        return p
    end
    for _, duel in ipairs(list) do
        local w = Player(duel.winner, duel.faction, duel.winnerClass, duel.winnerRace)
        local l = Player(duel.loser, duel.faction, duel.loserClass, duel.loserRace)
        local expected = HighNoon.Expected(w.rating, l.rating)
        local change = HighNoon.K * (1 - expected)
        w.rating, l.rating = w.rating + change, l.rating - change
        w.wins, l.losses = w.wins + 1, l.losses + 1
        w.duels, l.duels = w.duels + 1, l.duels + 1
        w.lastT, l.lastT = duel.t, duel.t
    end
    for _, p in pairs(players) do
        p.rating = math.floor(p.rating + 0.5)
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
        table.sort(list, function(a, b)
            if a.rating ~= b.rating then return a.rating > b.rating end
            if a.wins ~= b.wins then return a.wins > b.wins end
            return a.key < b.key
        end)
        -- Top Gun: the best of those past Greenhorn, so one lucky first duel is not enough
        local topGun
        for i, p in ipairs(list) do
            p.position = i
            p.topGun = nil
            if not topGun and p.rank ~= "greenhorn" then
                topGun = p
                p.topGun = true
            end
        end
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

-- "Deadeye #3 (1450)", "Top Gun (1500)", "Greenhorn (2 duels)"
function HighNoon.Title(player)
    if not player then return nil end
    if player.duels < HighNoon.MinDuels() then
        return string.format(L.DUEL_TITLE_GREENHORN, HighNoon.RankName("greenhorn"), player.duels)
    end
    if player.topGun then return string.format(L.DUEL_TITLE_TOPGUN, player.rating) end
    return string.format(L.DUEL_TITLE, HighNoon.RankName(player.rank), player.position or 0, player.rating)
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
        print(string.format("  #%d  %s  %s  %d  (%d-%d)", i, U.DisplayName(p.key) or p.key,
            HighNoon.RankName(p.rank), p.rating, p.wins, p.losses))
    end
    local me = HighNoon:Get(U.UnitKey("player"))
    if me then ns:Print(string.format(L.DUELS_YOU, HighNoon.Title(me), me.wins, me.losses)) end
end, L.HELP_DUELS)
