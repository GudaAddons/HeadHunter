-- HH-014: grey level and kill classification.

return function(T, H)
    T.case("grey level follows the Classic formula", function()
        local C = H.Boot({ client = "era" }).Classify
        local EXPECTED = {
            [1] = 0, [5] = 0, [6] = 1, [9] = 4, [10] = 4, [20] = 13, [30] = 22,
            [39] = 31, [40] = 31, [50] = 39, [59] = 47, [60] = 47,
        }
        for level, grey in pairs(EXPECTED) do
            T.eq(C.GreyLevel(level), grey, "grey at " .. level)
        end
    end)

    T.case("kill classification", function()
        local C = H.Boot({ client = "era" }).Classify
        local CASES = {
            { -1, 10, "coward", "skull" },
            { 60, 47, "coward", "grey victim at 60" },
            { 60, 50, "coward", "10+ levels" },
            { 30, 22, "coward", "grey victim at 30" },
            { 30, 23, "normal", "7 above, not grey" },
            { 20, 20, "fair", "same level" },
            { 23, 20, "fair", "3 above" },
            { 17, 20, "fair", "3 below" },
            { 24, 20, "normal", "4 above" },
            { 16, 20, "giant", "4 below" },
            { nil, 20, "unknown", "killer level unknown" },
            { 20, nil, "unknown", "victim level unknown" },
            { 0, 20, "unknown", "zero level" },
        }
        for _, c in ipairs(CASES) do
            T.eq(C.Kill(c[1], c[2]), c[3], c[4])
        end
    end)

    T.case("outnumbered: 3+ attackers on one victim, whatever the levels", function()
        local C = H.Boot({ client = "era" }).Classify
        local function Report(assists, killerLevel)
            local list = {}
            for i = 1, assists do list[i] = { key = "A" .. i .. "-Stonespine", level = 60 } end
            return { killer = { key = "K-Stonespine", level = killerLevel or 60 }, victim = { level = 60 }, assists = list }
        end
        T.eq(C.Report(Report(0)), "fair", "1 vs 1: by level")
        T.eq(C.Report(Report(1)), "fair", "2 vs 1: still by level")
        T.eq(C.Report(Report(2)), "outnumbered", "3 vs 1")
        T.eq(C.Report(Report(4, -1)), "outnumbered", "5 vs 1, even with a skull killer")
        T.eq(C.Attackers(Report(2)), 3, "attackers")
        T.ok(C.IsGang("outnumbered") and not C.IsCoward("outnumbered") and C.IsCoward("coward"), "Gang, not Coward")
        T.eq(C.ReportLabel(Report(2)), "|cffff8000Outnumbered|r (3 vs 1)", "label")
        T.eq(C.ReportLabel(Report(0)), "|cff40ff40Fair fight|r", "fair label")
    end)
end
