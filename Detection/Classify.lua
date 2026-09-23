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
-- Returns "coward" | "fair" | "giant" | "normal" | "unknown" (see Classify.Enemy for
-- "outnumbered", which depends on the whole death, not the levels).
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

-- Outnumbered (author, 2026-09-23): OUTNUMBERED or more enemy players hit one victim.
-- Then it is never a fair fight, whatever the levels, and it gives everyone who took
-- part the Gang badge (not Coward). Both clients record every attacker (Era: combat log;
-- Forever: Death Recap), so the count travels in every report and all clients agree.
Classify.OUTNUMBERED = 3

-- Enemy players on one death: the killer plus the assists
function Classify.Attackers(report)
    return 1 + #(report.assists or {})
end

-- One enemy's kill in a death that had `attackers` enemy players
function Classify.Enemy(enemyLevel, victimLevel, attackers)
    if (attackers or 1) >= Classify.OUTNUMBERED then return "outnumbered" end
    return Classify.Kill(enemyLevel, victimLevel)
end

-- A whole report, as the killer's kill
function Classify.Report(report)
    return Classify.Enemy(report.killer and report.killer.level, report.victim and report.victim.level,
        Classify.Attackers(report))
end

-- Counts toward the Coward badge and the Hall of Shame
function Classify.IsCoward(classification)
    return classification == "coward"
end

-- Counts toward the Gang badge
function Classify.IsGang(classification)
    return classification == "outnumbered"
end

-- Display text: "Fair fight", "Outnumbered (3 vs 1)", ...
function Classify.Label(classification, attackers)
    classification = classification or "unknown"
    if classification == "outnumbered" then return string.format(ns.L.KILL_OUTNUMBERED, attackers or 3) end
    return ns.L["KILL_" .. classification:upper()]
end

-- Display text for a report
function Classify.ReportLabel(report)
    return Classify.Label(Classify.Report(report), Classify.Attackers(report))
end
