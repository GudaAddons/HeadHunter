-- Zone names for the website: each zone seen in a report, duel or catch is saved with
-- its name and continent, so the desktop app can send zones the website does not know.

return function(T, H)
    T.case("a zone seen in a report is saved with its name and continent", function()
        local ns = H.Boot({ client = "era" })
        _G.GetLocale = function() return "enUS" end
        T.eq(next(ns.db.zones), nil, "empty at first")

        ns.Zones:Remember(1434)
        local zone = ns.db.zones[1434]
        T.eq(zone.name, "Stranglethorn Vale", "name")
        T.eq(zone.continent, 1415, "continent")
        T.eq(zone.locale, "enUS", "locale")
        _G.GetLocale = nil
    end)

    T.case("a cave is saved as the zone around it; unknown maps are skipped", function()
        local ns = H.Boot({ client = "era" })
        ns.Zones:Remember(9001) -- Jasperlode Mine, inside Elwynn Forest
        T.eq(ns.db.zones[1429].name, "Elwynn Forest", "the zone, not the mine")
        T.eq(ns.db.zones[9001], nil, "no entry for the mine itself")
        ns.Zones:Remember(123456)
        T.eq(ns.db.zones[123456], nil, "the game does not know it: nothing saved")
        ns.Zones:Remember(nil)
    end)

    T.case("a new zone outside the Vanilla list is learned from the game", function()
        local ns = H.Boot({ client = "forever" })
        H.maps[2200] = { mapID = 2200, name = "Isle of Tomorrow", mapType = 3, parentMapID = 1414 }
        ns.Zones:Remember(2200)
        T.eq(ns.db.zones[2200].name, "Isle of Tomorrow", "learned")
        T.eq(ns.db.zones[2200].continent, 1414, "continent from the map tree")
        H.maps[2200] = nil
    end)

    T.case("deaths, duels and catches remember their zone", function()
        local ns = H.Boot({ client = "era" })
        ns.Duels:Add({ winner = "A-Firemaw", loser = "B-Firemaw", t = H.serverTime, mapID = 1436,
            faction = "Alliance", winnerLevel = 30, loserLevel = 30 }, "local")
        T.eq(ns.db.zones[1436] and ns.db.zones[1436].name, "Westfall", "duel")

        ns.Justice:Add({ id = "Gank-Stonespine:1", outlaw = "Gank-Stonespine", t = H.serverTime, mapID = 1417 }, "local")
        T.eq(ns.db.zones[1417] and ns.db.zones[1417].name, "Arathi Highlands", "catch")
        T.noErrors()
    end)
end
