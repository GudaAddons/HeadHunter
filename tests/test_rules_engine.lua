-- M3: WANTED rules (pure engine). These cases are the rule contract the website
-- must reproduce as well (WEB-033).

return function(T, H)
    local MIN, HOUR = 60, 3600
    local T0 = 1790000000

    local function Engine()
        return H.Boot({ client = "era" }).RulesEngine
    end

    -- r(minutesFromT0, victim, opts) -> a report killed by "Gank-Stonespine"
    local function Report(minutes, victim, opts)
        opts = opts or {}
        return {
            id = (victim or "V") .. ":" .. (T0 + math.floor(minutes * MIN)),
            t = T0 + math.floor(minutes * MIN),
            victim = { key = victim or "Victim-Firemaw", level = opts.victimLevel or 40 },
            killer = opts.killer or { key = "Gank-Stonespine", level = opts.killerLevel or 42 },
            assists = opts.assists or {},
            confidence = opts.confidence or "exact",
        }
    end

    local function Compute(reports, nowMinutes, opts)
        local entries = Engine().Compute(reports, T0 + math.floor(nowMinutes * MIN), opts)
        return entries["Gank-Stonespine"], entries
    end

    T.case("timer durations", function()
        local E = Engine()
        local CASES = {
            { 1, 3 * HOUR }, { 4, 3 * HOUR }, { 10, 3 * HOUR },
            { 11, 3 * HOUR + 10 * MIN }, { 29, 6 * HOUR + 10 * MIN },
            { 30, 24 * HOUR }, { 31, 25 * HOUR }, { 174, 168 * HOUR }, { 200, 168 * HOUR },
            { 10.5, 3 * HOUR },
        }
        for _, c in ipairs(CASES) do
            T.eq(E.Duration(c[1]), c[2], "duration at " .. c[1])
        end
    end)

    T.case("rank thresholds", function()
        local E = Engine()
        local CASES = {
            { 3, nil }, { 3.5, nil }, { 4, "ganker" }, { 9, "ganker" }, { 10, "outlaw" }, { 19, "outlaw" },
            { 20, "desperado" }, { 29, "desperado" }, { 30, "mostwanted" }, { 49, "mostwanted" },
            { 50, "deadoralive" }, { 500, "deadoralive" },
        }
        for _, c in ipairs(CASES) do
            T.eq(E.Rank(c[1]), c[2], "rank at " .. c[1])
        end
    end)

    T.case("3 kills in 20 min is not WANTED; the 4th makes a Ganker", function()
        local three = { Report(0, "A"), Report(5, "B"), Report(10, "C") }
        local e = Compute(three, 11)
        T.eq(e.wanted, false, "3 kills")
        T.eq(e.killCount, 3, "kills known")

        local four = { Report(0, "A"), Report(5, "B"), Report(10, "C"), Report(19, "D") }
        e = Compute(four, 20)
        T.eq(e.wanted, true, "4 kills")
        T.eq(e.kills, 4, "count")
        T.eq(e.rank, "ganker", "rank")
        T.eq(e.wantedUntil, T0 + 19 * MIN + 3 * HOUR, "3 h after the last kill")
        T.eq(e.timesWanted, 1, "times wanted")
    end)

    T.case("the same victim killed 4 times also counts", function()
        local e = Compute({ Report(0, "A"), Report(3, "A"), Report(6, "A"), Report(9, "A") }, 10)
        T.eq(e.wanted, true, "wanted")
    end)

    T.case("4 kills spread over more than 20 minutes are not enough", function()
        local e = Compute({ Report(0, "A"), Report(7, "B"), Report(14, "C"), Report(21, "D") }, 22)
        T.eq(e.wanted, false, "window")
    end)

    T.case("inferred kills weigh half", function()
        local inferred = { confidence = "inferred" }
        local reports = {}
        for i = 1, 7 do reports[i] = Report(i, "V" .. i, inferred) end
        T.eq(Compute(reports, 8).wanted, false, "7 x 0.5 = 3.5")
        reports[8] = Report(8, "V8", inferred)
        local e = Compute(reports, 9)
        T.eq(e.wanted, true, "8 x 0.5 = 4")
        T.eq(e.kills, 4, "weighted count")
    end)

    T.case("the timer grows with kills and the rank follows", function()
        local reports = {}
        for i = 1, 12 do reports[i] = Report(i, "V" .. i) end
        local e = Compute(reports, 13)
        T.eq(e.kills, 12, "12 kills")
        T.eq(e.rank, "outlaw", "outlaw")
        T.eq(e.wantedUntil, T0 + 12 * MIN + 3 * HOUR + 20 * MIN, "3 h 20 m after the last kill")
        T.eq(e.peakRank, "outlaw", "peak")
    end)

    T.case("expiry: the timer runs out, the status ends and the count resets", function()
        local reports = { Report(0, "A"), Report(1, "B"), Report(2, "C"), Report(3, "D") }
        local e = Compute(reports, 3 + 180 + 1)
        T.eq(e.wanted, false, "expired")
        T.eq(e.expired, true, "flag")
        T.eq(e.kills, 0, "no current count")

        -- Two more kills later: count restarted, not WANTED
        reports[5] = Report(300, "E")
        reports[6] = Report(301, "F")
        e = Compute(reports, 302)
        T.eq(e.wanted, false, "count reset")

        -- Two more in the same window: WANTED again, second time
        reports[7] = Report(302, "G")
        reports[8] = Report(303, "H")
        e = Compute(reports, 304)
        T.eq(e.wanted, true, "wanted again")
        T.eq(e.kills, 4, "fresh count")
        T.eq(e.timesWanted, 2, "second time")
    end)

    T.case("each kill while WANTED restarts the timer", function()
        local reports = { Report(0, "A"), Report(1, "B"), Report(2, "C"), Report(3, "D"), Report(170, "E") }
        local e = Compute(reports, 170 + 179)
        T.eq(e.wanted, true, "still wanted 3 h after the 5th kill minus a minute")
        T.eq(e.kills, 5, "5")
    end)

    T.case("assists get the kill too; GUID-only enemies are tracked by GUID", function()
        local _, entries = Compute({
            Report(0, "A", { assists = { { key = "Helper-Stonespine", level = 40 } } }),
            Report(1, "B", { assists = { { guid = "Player-9", name = "Kuh", nameIncomplete = true } } }),
        }, 2)
        T.eq(entries["Helper-Stonespine"].killCount, 1, "assist counted")
        T.eq(entries["guid:Player-9"].killCount, 1, "GUID id")
        T.eq(entries["guid:Player-9"].name, "Kuh", "given name shown")
        T.eq(entries["guid:Player-9"].nameIncomplete, true, "flagged incomplete")
    end)

    T.case("badges", function()
        -- Coward: one skull kill
        local e = Compute({ Report(0, "A", { killer = { key = "Gank-Stonespine", level = -1 } }) }, 1)
        T.eq(e.badges.coward, true, "coward")

        -- Gunslinger: 3 fair of 4
        e = Compute({
            Report(0, "A", { killerLevel = 40 }), Report(10, "B", { killerLevel = 41 }),
            Report(20, "C", { killerLevel = 39 }), Report(30, "D", { killerLevel = 47 }),
        }, 31)
        T.eq(e.badges.gunslinger, true, "gunslinger")
        T.eq(e.badges.coward, nil, "not coward")

        -- Giant Slayer: 2 kills of higher-level victims
        e = Compute({ Report(0, "A", { killerLevel = 30 }), Report(10, "B", { killerLevel = 30 }) }, 11)
        T.eq(e.badges.giantslayer, true, "giant slayer")
    end)

    T.case("serial killer needs 5 victims in separate engagements inside the window", function()
        local E = Engine()
        local function Kills(spec)
            local list = {}
            for i, k in ipairs(spec) do list[i] = { t = T0 + k[1], victim = k[2], weight = 1 } end
            return list
        end
        T.eq(E.IsSerialKiller(Kills({ { 0, "A" }, { 120, "B" }, { 240, "C" }, { 360, "D" }, { 480, "E" } })), true,
            "5 victims, 2 min apart")
        T.eq(E.IsSerialKiller(Kills({ { 0, "A" }, { 10, "B" }, { 20, "C" }, { 30, "D" }, { 40, "E" } })), false,
            "one group fight (<= 60 s apart) is one engagement")
        T.eq(E.IsSerialKiller(Kills({ { 0, "A" }, { 300, "B" }, { 600, "C" }, { 900, "D" }, { 1200, "E" } })), false,
            "spread over 20 min, window 15")
        T.eq(E.IsSerialKiller(Kills({ { 0, "A" }, { 300, "B" }, { 600, "C" }, { 900, "D" }, { 1200, "E" } }), 25 * 60), true,
            "same with a larger window")
        T.eq(E.IsSerialKiller(Kills({ { 0, "A" }, { 120, "B" }, { 240, "C" }, { 360, "D" }, { 480, "A" } })), false,
            "a repeat victim does not count twice")
        T.eq(E.IsSerialKiller(Kills({ { 0, "A" }, { 120, "B" }, { 240, "C" }, { 250, "X" }, { 360, "D" }, { 480, "E" } })), true,
            "an extra kill in the same fight does not break it")
    end)

    T.case("result does not depend on report order", function()
        local reports = {}
        for i = 1, 25 do reports[i] = Report(i * 3, "V" .. (i % 7)) end
        local forward = Compute(reports, 80)
        local shuffled = {}
        for i = #reports, 1, -1 do shuffled[#shuffled + 1] = reports[i] end
        local backward = Compute(shuffled, 80)
        T.eq(forward.kills, backward.kills, "kills")
        T.eq(forward.rank, backward.rank, "rank")
        T.eq(forward.wantedUntil, backward.wantedUntil, "timer")
        T.eq(forward.badges.serialkiller, backward.badges.serialkiller, "badge")
    end)
end
