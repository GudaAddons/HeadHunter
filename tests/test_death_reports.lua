-- HH-013: the report pipeline (validation, storage, classification, completion).

return function(T, H)
    T.case("a simulated death is recorded, classified and announced", function()
        local ns = H.Boot({ client = "forever" })
        local recorded
        ns.Events:Register("HH_DEATH_RECORDED", function(_, report) recorded = report end, "t")
        H.Slash('sim death "Grim Reaper" skull ROGUE Orc')
        T.eq(#ns.db.deaths, 1, "stored")
        local report = ns.db.deaths[1]
        T.eq(recorded, report, "HH_DEATH_RECORDED")
        T.eq(report.classification, "coward", "skull is coward")
        T.eq(report.victim.level, 30, "victim level")
        T.eq(report.confidence, "sim", "confidence")
        T.ok(H.Printed("Killed by .*Grim Reaper"), "chat line")
        T.ok(H.Printed("Coward kill"), "classification shown")
        T.noErrors()
    end)

    T.case("the same report id is only recorded once", function()
        local ns = H.Boot({ client = "era" })
        local t = H.serverTime
        ns.DeathReports:Record({ id = "Vati-Firemaw:1", t = t, killer = { key = "Gank-Stonespine", level = 30 } }, "test")
        ns.DeathReports:Record({ id = "Vati-Firemaw:1", t = t, killer = { key = "Gank-Stonespine" } }, "test")
        T.eq(#ns.db.deaths, 1, "deduplicated")
        T.eq(ns.db.deaths[1].classification, "fair", "30 vs 30")
    end)

    T.case("invalid reports are dropped", function()
        local ns = H.Boot({ client = "era" })
        T.eq(ns.DeathReports:Record({ t = 1 }, "test"), nil, "no killer")
        T.eq(ns.DeathReports:Record("junk", "test"), nil, "not a table")
        H.units.player.name = nil
        T.eq(ns.DeathReports:Record({ killer = { key = "X-Y" } }, "test"), nil, "victim unknown")
        T.eq(#ns.db.deaths, 0, "nothing stored")
        T.noErrors()
    end)

    T.case("a report fills time, victim and position when missing", function()
        local ns = H.Boot({ client = "era" })
        local report = ns.DeathReports:Record({ killer = { key = "Gank-Stonespine", level = 45 } }, "test")
        T.eq(report.t, H.serverTime, "time")
        T.eq(report.id, "Vati-Firemaw:" .. H.serverTime, "id")
        T.eq(report.victim.key, "Vati-Firemaw", "victim")
        T.eq(report.mapID, 1429, "map")
        T.eq(report.x, 0.42, "x")
        T.eq(report.classification, "coward", "45 vs 30 is 15 levels")
    end)

    T.case("an incomplete killer is completed when its GUID is resolved", function()
        local ns = H.Boot({ client = "forever" })
        local updated
        ns.Events:Register("HH_DEATH_UPDATED", function(_, report) updated = report end, "t")
        local report = ns.DeathReports:Record({
            killer = { guid = "Player-7", name = "Kuh", nameIncomplete = true, class = "HUNTER" },
            assists = { { guid = "Player-8", name = "Lokiju", nameIncomplete = true } },
        }, "test")
        T.eq(report.classification, "unknown", "no level yet")

        H.units.nameplate1 = { name = "Kuh", realm = "Blam", level = 30, class = "HUNTER", race = "Orc",
            faction = "Horde", isPlayer = true, guid = "Player-7" }
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        T.eq(report.killer.key, "Kuh Blam", "killer completed")
        T.eq(report.killer.nameIncomplete, nil, "flag cleared")
        T.eq(report.killer.level, 30, "level filled")
        T.eq(report.classification, "fair", "reclassified")
        T.eq(updated, report, "HH_DEATH_UPDATED")

        H.units.nameplate2 = { name = "Lokiju", realm = "Hardwood", level = 20, faction = "Horde",
            isPlayer = true, guid = "Player-8" }
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
        T.eq(report.assists[1].key, "Lokiju Hardwood", "assist completed")
        T.noErrors()
    end)

    T.case("/hh deaths lists newest first", function()
        local ns = H.Boot({ client = "era" })
        H.Slash("sim death Gank 60 ROGUE Orc")
        H.serverTime = H.serverTime + 100
        H.Slash("sim death Stab 31 WARRIOR Troll")
        H.Slash("deaths")
        T.ok(H.Printed("PvP deaths recorded: 2"), "header")
        local first, second
        for i, line in ipairs(H.printed) do
            -- Own-realm names are shown without the realm
            if line:find("^  .* Stab %(") then first = first or i end
            if line:find("^  .* Gank %(") then second = second or i end
        end
        T.ok(first and second and first < second, "newest first")
        T.noErrors()
    end)
end
