-- HH-060: main window (WANTED, Hall of Shame, My deaths) and the minimap button.

return function(T, H)
    local serial = 0

    -- `killer` kills n victims; the newest kill `ago` seconds ago
    local function Spree(ns, killer, n, opts)
        opts = opts or {}
        for i = 1, n do
            serial = serial + 1
            local victim = "Victim" .. serial .. "-Firemaw"
            local t = H.serverTime - (opts.ago or 0) - (n - i + 1) * 30
            ns.Reports:Add({ id = victim .. ":" .. t, t = t, victim = { key = victim, level = opts.victimLevel or 58 },
                killer = { key = killer, name = killer, level = 60, class = opts.class or "ROGUE", race = "Orc" },
                assists = {}, mapID = opts.mapID or 1436, x = 0.5, y = 0.5, confidence = "exact" }, "peer", victim)
        end
    end

    local function Settle()
        H.Advance(1)
        for _ = 1, 10 do H.Advance(0) end
        H.Advance(0.5)
        for _ = 1, 3 do H.Advance(0) end
    end

    local function Names(rows)
        local names = {}
        for i, row in ipairs(rows) do
            -- Race icon and colors off, and the realm (other realms keep it in the name)
            names[i] = row.name:gsub("|A.-|a ", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("%-%a+$", "")
        end
        return table.concat(names, ",")
    end

    T.case("WANTED tab: rank, kills, last kill and zone, badges; three sort orders", function()
        local ns = H.Boot({ client = "era" })
        Spree(ns, "Big-Stonespine", 12, { ago = 3600 })          -- Outlaw, an hour ago
        Spree(ns, "Fresh-Stonespine", 5, { mapID = 1417 })        -- Ganker, just now
        Spree(ns, "Mid-Stonespine", 6, { ago = 600, class = "MAGE" })
        Settle()
        local rows = ns.MainWindow.Rows("wanted", "rank")
        T.eq(Names(rows), "Big,Mid,Fresh", "by rank, then kills")
        T.ok(rows[1].rank:find("Outlaw", 1, true) ~= nil, "rank text")
        T.eq(rows[1].kills, "12", "kills")
        T.ok(rows[1].lastKill:find("1 h", 1, true) ~= nil and rows[1].lastKill:find("Westfall", 1, true) ~= nil,
            "last kill: " .. rows[1].lastKill)
        T.ok(rows[1].badges:find("Gunslinger", 1, true) ~= nil, "badges: " .. rows[1].badges)
        T.eq(Names(ns.MainWindow.Rows("wanted", "kills")), "Big,Mid,Fresh", "by kills")
        T.eq(Names(ns.MainWindow.Rows("wanted", "last")), "Fresh,Mid,Big", "by last kill")
        T.ok(rows[2].name:find("|c", 1, true) ~= nil, "class colored name")
    end)

    T.case("Hall of Shame: every coward, WANTED or not, most coward kills first", function()
        local ns = H.Boot({ client = "era" })
        Spree(ns, "Bully-Stonespine", 5, { victimLevel = 20 })       -- WANTED coward
        Spree(ns, "Sneak-Stonespine", 2, { victimLevel = 20 })       -- coward, not WANTED
        Spree(ns, "Fair-Stonespine", 5, { victimLevel = 60 })        -- WANTED, fair fights
        Settle()
        local rows = ns.MainWindow.Rows("shame")
        T.eq(Names(rows), "Bully,Sneak", "cowards only")
        T.eq(rows[1].coward, "5", "coward kills")
        T.ok(rows[1].status:find("WANTED", 1, true) ~= nil, "WANTED now")
        T.eq(rows[2].status, "WANTED 0x · caught 0x", "past status")
        T.ok(rows[2].desc:find("Orc", 1, true) ~= nil, "who")
    end)

    T.case("My deaths: our own deaths, newest first", function()
        local ns = H.Boot({ client = "era" })
        H.Slash("sim death Older-Stonespine 60 ROGUE Orc")
        H.serverTime = H.serverTime + 120
        H.Slash("sim death Newer-Stonespine skull WARRIOR Troll")
        local rows = ns.MainWindow.Rows("deaths")
        T.eq(Names(rows), "Newer,Older", "newest first")
        T.ok(rows[1].desc:find("??", 1, true) ~= nil, "skull level")
        T.ok(rows[1].kind ~= "", "kill type")
        T.eq(rows[1].zone, "Elwynn Forest", "zone")
    end)

    T.case("My deaths: a 3 vs 1 shows as Gang, even if saved as fair before", function()
        local ns = H.Boot({ client = "era" })
        table.insert(ns.db.deaths, { id = "Vati-Firemaw:1", t = H.serverTime - 60, classification = "fair",
            victim = { key = "Vati-Firemaw", level = 30 },
            killer = { key = "Gank-Stonespine", level = 30, class = "ROGUE", race = "Orc" },
            assists = { { key = "Pal-Stonespine", level = 30 }, { key = "Buddy-Stonespine", level = 31 } },
            mapID = 1429 })
        local row = ns.MainWindow.Rows("deaths")[1]
        T.eq(row.kind, "|cffcc66ffGang|r (3 vs 1)", "kind")
    end)

    T.case("the window: /hh opens it, tabs, sorting, live refresh, row click", function()
        local ns = H.Boot({ client = "era" })
        local M = ns.MainWindow
        H.Slash("")
        T.ok(M:IsShown(), "open")
        T.eq(#M.shownRows, 0, "empty")
        Spree(ns, "Gank-Stonespine", 4)
        Settle()
        H.Advance(0.2)
        T.eq(#M.shownRows, 1, "refreshed when the WANTED list changed")

        M:SelectTab("deaths")
        T.eq(select(1, M:Current()), "deaths", "tab")
        local tabs = _G.HeadHunterMainFrame.tabs.buttons
        T.eq(#tabs, 4, "four bottom tabs")
        T.ok(tabs[3].selected and not tabs[1].selected, "the selected tab is drawn selected")
        T.eq(tabs[1].point[1], "BOTTOMLEFT", "hanging from the bottom edge")
        T.eq(#M.shownRows, 0, "no deaths of ours")
        M:SelectTab("wanted")
        M:SetSort("kills")
        T.eq(select(2, M:Current()), "kills", "sort")

        M:OnRowClick(M.shownRows[1])
        T.eq(ns.Poster:ShownId(), "Gank-Stonespine", "the row opened the poster")
        H.Slash("")
        T.ok(not M:IsShown(), "closed")
        T.noErrors()
    end)

    T.case("race icons: atlas per client, gender, Undead's atlas name, unknown race", function()
        local U = H.Boot({ client = "era" }).Utils
        T.eq(U.RaceIcon("Orc", 3), "|A:raceicon-orc-female:14:14|a", "era, female")
        T.eq(U.RaceIcon("Scourge", 2), "|A:raceicon-undead-male:14:14|a", "Scourge is undead")
        T.eq(U.RaceIcon("NightElf"), "|A:raceicon-nightelf-male:14:14|a", "unknown gender: male")
        T.eq(U.RaceIcon(nil, 2), "", "unknown race: nothing")
        U = H.Boot({ client = "forever" }).Utils
        T.eq(U.RaceIcon("Orc", 2), "|A:raceicon128-orc-male:14:14|a", "forever: larger art")
    end)

    T.case("rows start with the race icon; hovering shows the outlaw's details", function()
        local ns = H.Boot({ client = "era" })
        Spree(ns, "Gank-Stonespine", 5)
        Settle()
        local row = ns.MainWindow.Rows("wanted", "rank")[1]
        T.ok(row.name:find("|A:raceicon-orc-male", 1, true) == 1, "icon first: " .. row.name)
        local tip = table.concat(row.tooltip, "\n")
        T.ok(row.tooltip[1]:find("raceicon", 1, true) ~= nil, "title with icon")
        T.ok(tip:find("60 Orc Rogue", 1, true) ~= nil, "who")
        T.ok(tip:find("WANTED|r · ", 1, true) ~= nil and tip:find("5 kills", 1, true) ~= nil, "status")
        T.ok(tip:find("Last kill just now in Westfall", 1, true) ~= nil, "last kill")
        T.ok(tip:find("Kills known: 5 · WANTED 1x · caught 0x", 1, true) ~= nil, "history")

        H.Slash("sim death Gank-Stonespine 60 ROGUE Orc 3")
        local death = ns.MainWindow.Rows("deaths")[1]
        T.ok(death.name:find("raceicon-orc-female", 1, true) ~= nil, "the killer's gender from the death")
        T.ok(death.tooltip[2]:find("^Killed you") ~= nil, "this death first")
        T.ok(table.concat(death.tooltip, "\n"):find("Kills known", 1, true) ~= nil, "then the outlaw's record")
    end)

    T.case("minimap button: shown by default, /hh minimap hides it (remembered)", function()
        local ns = H.Boot({ client = "era", minimap = true })
        T.ok(ns.MinimapButton:IsShown(), "shown")
        H.Slash("minimap")
        T.ok(not ns.MinimapButton:IsShown(), "hidden")
        T.eq(ns.db.settings.minimap.hidden, true, "remembered")
        local x, y = ns.MinimapButton.Offset(90, 80)
        T.ok(math.abs(x) < 1e-9 and math.abs(y - 80) < 1e-9, "90 degrees: straight up")
        T.noErrors()
    end)

    T.case("no minimap frame: no button, no error", function()
        local ns = H.Boot({ client = "forever" })
        T.ok(not ns.MinimapButton:IsShown(), "none")
        T.noErrors()
    end)
end
