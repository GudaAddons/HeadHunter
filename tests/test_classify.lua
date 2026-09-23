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
end
