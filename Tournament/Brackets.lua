-- HH-105: Gurubashi Tournament brackets (docs/addon/features.md section 11).
--
-- Pure logic, no game API, so every client that has the same entrants and results
-- builds the same bracket. Entrants are ids (a player key, or a team id for 2v2+).
--
--   Brackets.Seed(entrants, ratingOf, seed)       rated first (best first), then the
--                                                 unrated in a shuffled order from `seed`
--   Brackets.SingleElimination(seeds, bestOf)     the default; byes for the top seeds
--   Brackets.RoundRobin(seeds, bestOf)            everyone meets everyone once
--   Brackets.RecordGame(bracket, matchId, winner) one game of a match (Best of 1 / 3 / 5)
--   Brackets.Ready(bracket)                       matches that can be called now
--   Brackets.Standings(bracket)                   { { id, place, points } ... }
--
-- A bracket is a plain table (no shared references), so it can be saved and sent.

local addonName, ns = ...

local Brackets = ns:RegisterModule("Brackets", {})

Brackets.BEST_OF = { 1, 3, 5 }
Brackets.POINTS = { 10, 6, 3, 3 }   -- by place; everyone else who played gets 1

function Brackets.WinsNeeded(bestOf)
    return math.floor((bestOf or 1) / 2) + 1
end

function Brackets.Points(place)
    return Brackets.POINTS[place] or 1
end

-- A small deterministic generator (the same numbers on every client)
local function Random(seed)
    local state = (tonumber(seed) or 1) % 2147483647
    if state <= 0 then state = state + 2147483646 end
    return function()
        state = (state * 16807) % 2147483647
        return state / 2147483647
    end
end

function Brackets.Seed(entrants, ratingOf, seed)
    local rated, unrated = {}, {}
    for _, id in ipairs(entrants) do
        local rating = ratingOf and ratingOf(id)
        if rating then rated[#rated + 1] = { id = id, rating = rating } else unrated[#unrated + 1] = id end
    end
    table.sort(rated, function(a, b)
        if a.rating ~= b.rating then return a.rating > b.rating end
        return a.id < b.id
    end)
    table.sort(unrated)
    local random = Random(seed)
    for i = #unrated, 2, -1 do
        local j = math.floor(random() * i) + 1
        unrated[i], unrated[j] = unrated[j], unrated[i]
    end
    local seeds = {}
    for _, p in ipairs(rated) do seeds[#seeds + 1] = p.id end
    for _, id in ipairs(unrated) do seeds[#seeds + 1] = id end
    return seeds
end

-- Bracket positions for `size` slots: seed 1 meets the last seed, 1 and 2 meet only
-- in the final. SeedOrder(8) = 1 8 4 5 2 7 3 6
function Brackets.SeedOrder(size)
    local order = { 1 }
    local n = 1
    while n < size do
        n = n * 2
        local nextOrder = {}
        for _, s in ipairs(order) do
            nextOrder[#nextOrder + 1] = s
            nextOrder[#nextOrder + 1] = n + 1 - s
        end
        order = nextOrder
    end
    return order
end

local function NewMatch(round, index, a, b)
    return { id = "r" .. round .. "m" .. index, round = round, index = index, a = a, b = b, winsA = 0, winsB = 0 }
end

local function Find(bracket, matchId)
    for _, round in ipairs(bracket.rounds) do
        for _, match in ipairs(round) do
            if match.id == matchId then return match end
        end
    end
    return nil
end
Brackets.Find = Find

-- Single elimination: the winner goes on to the next round's match
local function Advance(bracket, match)
    local nextRound = bracket.rounds[match.round + 1]
    if not nextRound then
        bracket.champion = match.winner
        return
    end
    local target = nextRound[math.ceil(match.index / 2)]
    if match.index % 2 == 1 then target.a = match.winner else target.b = match.winner end
end

function Brackets.SingleElimination(seeds, bestOf)
    local n = #seeds
    if n < 2 then return nil end
    local size = 2
    while size < n do size = size * 2 end
    local order = Brackets.SeedOrder(size)
    local bracket = { kind = "single", bestOf = bestOf or 1, size = size, entrants = n, rounds = {} }
    local roundNo, matches = 1, size / 2
    while matches >= 1 do
        local round = {}
        for i = 1, matches do
            if roundNo == 1 then
                round[i] = NewMatch(1, i, seeds[order[2 * i - 1]], seeds[order[2 * i]])
            else
                round[i] = NewMatch(roundNo, i)
            end
        end
        bracket.rounds[roundNo] = round
        roundNo, matches = roundNo + 1, matches / 2
    end
    -- Byes: a first-round match with one side goes through at once
    for _, match in ipairs(bracket.rounds[1]) do
        if not (match.a and match.b) then
            match.winner, match.bye = match.a or match.b, true
            Advance(bracket, match)
        end
    end
    return bracket
end

-- Round robin (circle method): n - 1 rounds (n rounds for an odd n, one sits out each)
function Brackets.RoundRobin(seeds, bestOf)
    local n = #seeds
    if n < 2 then return nil end
    local list = {}
    for i, id in ipairs(seeds) do list[i] = id end
    if n % 2 == 1 then list[#list + 1] = false end -- the one who meets `false` sits out
    local slots = #list
    local bracket = { kind = "robin", bestOf = bestOf or 1, entrants = n, rounds = {} }
    for r = 1, slots - 1 do
        local round = {}
        for i = 1, slots / 2 do
            local a, b = list[i], list[slots + 1 - i]
            if a and b then round[#round + 1] = NewMatch(r, #round + 1, a, b) end
        end
        bracket.rounds[r] = round
        -- Keep the first in place, rotate the rest
        table.insert(list, 2, table.remove(list))
    end
    return bracket
end

-- One game of a match. Returns the match, or nil when it cannot take this result.
function Brackets.RecordGame(bracket, matchId, winner)
    local match = Find(bracket, matchId)
    if not match or match.winner or not (match.a and match.b) then return nil end
    if winner == match.a then
        match.winsA = match.winsA + 1
    elseif winner == match.b then
        match.winsB = match.winsB + 1
    else
        return nil
    end
    local need = Brackets.WinsNeeded(bracket.bestOf)
    if match.winsA >= need or match.winsB >= need then
        match.winner = match.winsA >= need and match.a or match.b
        match.loser = match.winner == match.a and match.b or match.a
        if bracket.kind == "single" then Advance(bracket, match) end
    end
    return match
end

-- Matches that can be called now: both sides known, not decided. Round robin plays
-- one round at a time.
function Brackets.Ready(bracket)
    local ready = {}
    for _, round in ipairs(bracket.rounds) do
        local open = false
        for _, match in ipairs(round) do
            if not match.winner then
                open = true
                if match.a and match.b then ready[#ready + 1] = match end
            end
        end
        if open and bracket.kind == "robin" then break end
    end
    return ready
end

function Brackets.Finished(bracket)
    for _, round in ipairs(bracket.rounds) do
        for _, match in ipairs(round) do
            if not match.winner then return false end
        end
    end
    return true
end

-- Single elimination: champion 1st, final loser 2nd, semi-final losers 3rd, a loser in
-- a round of M matches places M + 1. Round robin: match wins, then game difference.
function Brackets.Standings(bracket)
    local standings = {}
    local function Add(id, place)
        standings[#standings + 1] = { id = id, place = place, points = Brackets.Points(place) }
    end
    if bracket.kind == "single" then
        if bracket.champion then Add(bracket.champion, 1) end
        for r = #bracket.rounds, 1, -1 do
            local round = bracket.rounds[r]
            for _, match in ipairs(round) do
                if match.loser then Add(match.loser, #round + 1) end
            end
        end
        return standings
    end
    local stats, order = {}, {}
    local function Stat(id)
        if not stats[id] then
            stats[id] = { id = id, wins = 0, diff = 0 }
            order[#order + 1] = stats[id]
        end
        return stats[id]
    end
    for _, round in ipairs(bracket.rounds) do
        for _, match in ipairs(round) do
            local a, b = Stat(match.a), Stat(match.b)
            a.diff = a.diff + match.winsA - match.winsB
            b.diff = b.diff + match.winsB - match.winsA
            if match.winner then Stat(match.winner).wins = Stat(match.winner).wins + 1 end
        end
    end
    table.sort(order, function(x, y)
        if x.wins ~= y.wins then return x.wins > y.wins end
        if x.diff ~= y.diff then return x.diff > y.diff end
        return x.id < y.id
    end)
    for i, s in ipairs(order) do
        local prev = order[i - 1]
        local place = (prev and prev.wins == s.wins and prev.diff == s.diff) and standings[i - 1].place or i
        Add(s.id, place)
    end
    return standings
end
