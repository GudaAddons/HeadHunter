-- HH-014: how fair was a kill? Pure functions, no WoW API.
-- Rules: docs/addon/features.md section 3 (Coward, Gunslinger, Giant Slayer).
-- The website applies the same rules (docs/website/plan.md), so keep them in sync.

local addonName, ns = ...

local Classify = ns:RegisterModule("Classify", {})

Classify.FAIR_RANGE = 3
Classify.SKULL_GAP = 10

-- Highest level that is grey (gives no XP or honor) to a player of this level.
-- Classic formula: 1-5 none; 6-39 L - floor(L/10) - 5; 40+ L - floor(L/5) - 1.
-- At 60 that makes 47 and below grey. Confirm in game (HH-070).
function Classify.GreyLevel(level)
    if level <= 5 then return 0 end
    if level <= 39 then return level - math.floor(level / 10) - 5 end
    return level - math.floor(level / 5) - 1
end

-- killerLevel as the victim saw it: -1 = skull (10+ above the victim), nil = unknown.
-- Returns "coward" | "fair" | "giant" | "normal" | "unknown" (the level judgement; the
-- group size is judged separately, see Classify.Group).
--   coward  10+ levels above the victim, or the victim was grey to the killer
--   fair    within FAIR_RANGE levels
--   giant   the killer was lower level than the victim (beyond FAIR_RANGE)
--   normal  higher level, but neither skull nor grey
function Classify.Kill(killerLevel, victimLevel)
    if killerLevel == -1 then return "coward" end
    if not killerLevel or not victimLevel or killerLevel < 1 or victimLevel < 1 then
        return "unknown"
    end
    local gap = killerLevel - victimLevel
    if gap >= Classify.SKULL_GAP or victimLevel <= Classify.GreyLevel(killerLevel) then
        return "coward"
    end
    if math.abs(gap) <= Classify.FAIR_RANGE then return "fair" end
    if gap < 0 then return "giant" end
    return "normal"
end

-- Group size (author, 2026-09-23), judged next to the levels, never instead of them:
--   duo   2 enemy players on one victim   -> Duo badge
--   gang  3 or more                       -> Gang badge
-- A kill with help is never a fair fight (no Gunslinger, no Giant Slayer), but a
-- lowbie kill stays a Coward kill with or without help. Both clients record every
-- attacker (Era: combat log; Forever: Death Recap), so the count travels in every
-- report and all clients agree.
Classify.DUO = 2
Classify.GANG = 3

-- Enemy players on one death: the killer plus the assists
function Classify.Attackers(report)
    return 1 + #(report.assists or {})
end

-- nil (alone) | "duo" | "gang"
function Classify.Group(attackers)
    attackers = attackers or 1
    if attackers >= Classify.GANG then return "gang" end
    if attackers >= Classify.DUO then return "duo" end
    return nil
end

-- One enemy's kill in a death that had `attackers` enemy players: level judgement, group
function Classify.Enemy(enemyLevel, victimLevel, attackers)
    return Classify.Kill(enemyLevel, victimLevel), Classify.Group(attackers)
end

-- A whole report, as the killer's kill (the level judgement)
function Classify.Report(report)
    return Classify.Kill(report.killer and report.killer.level, report.victim and report.victim.level)
end

-- Counts toward the Coward badge and the Hall of Shame (with help or not)
function Classify.IsCoward(classification)
    return classification == "coward"
end

-- Counts toward Gunslinger / Giant Slayer: only a one-on-one kill
function Classify.IsFair(classification, group)
    return classification == "fair" and group == nil
end

function Classify.IsGiant(classification, group)
    return classification == "giant" and group == nil
end

-- Display text: "Fair fight", "Coward kill · Duo (2 vs 1)", "Gang (3 vs 1)", ...
-- A same-level fight with help is not fair, so then only the group is shown.
function Classify.Label(classification, attackers)
    classification = classification or "unknown"
    local L = ns.L
    local group = Classify.Group(attackers)
    if not group then return L["KILL_" .. classification:upper()] end
    local groupText = string.format(L["KILL_" .. group:upper()], attackers)
    if classification == "fair" or classification == "unknown" then return groupText end
    return L["KILL_" .. classification:upper()] .. " · " .. groupText
end

-- Display text for a report
function Classify.ReportLabel(report)
    return Classify.Label(Classify.Report(report), Classify.Attackers(report))
end
