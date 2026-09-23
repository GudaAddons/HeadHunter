-- HH-001 / HH-005 / HH-007: full boot and every slash command on both clients.

return function(T, H)
    for _, client in ipairs({ "era", "forever" }) do
        T.case(client .. ": boots and prints one loaded line", function()
            H.Boot({ client = client })
            T.ok(H.Printed("v0%.1%.0 loaded"), "loaded line")
            T.eq(_G.SLASH_HEADHUNTER1, "/hh", "slash")
            T.noErrors()
        end)

        T.case(client .. ": help, status, debug, log, unknown", function()
            local ns = H.Boot({ client = client })
            H.Slash("")
            T.ok(H.Printed("/hh status"), "help lists status")
            H.Slash("status")
            T.ok(H.Printed("Client: " .. client), "status client")
            H.Slash("debug on")
            T.eq(ns.debugMode, true, "debug on")
            T.eq(ns.db.settings.debug, true, "debug persisted")
            H.Slash("debug")
            T.eq(ns.debugMode, false, "debug toggled off")
            H.Slash("log")
            T.ok(_G.HeadHunterLogFrame ~= nil, "log frame created")
            H.Slash("log clear")
            H.Slash("bogus")
            T.ok(H.Printed("Unknown command 'bogus'"), "unknown command")
            T.noErrors()
        end)

        T.case(client .. ": probe and probe watch", function()
            local ns = H.Boot({ client = client })
            H.units.target = { name = client == "forever" and "Grim" or "Gank", realm = client == "forever" and "Reaper" or nil, level = -1,
                class = "ROGUE", race = "Orc", sex = 2, faction = "Horde", isPlayer = true, guid = "Player-2" }
            H.Slash("probe")
            local text = table.concat(ns.Log:Lines(), "\n")
            T.ok(text:find("==== end probe ====", 1, true) ~= nil, "probe completed")
            T.ok(text:find("target level: -1", 1, true) ~= nil, "skull level reported")
            local cleu = text:match("event COMBAT_LOG_EVENT_UNFILTERED: ([^\n]+)")
            if client == "forever" then
                T.eq(cleu, "restricted (never registered on this client)", "CLEU on Forever")
            else
                T.eq(cleu, "yes (registered)", "CLEU on Era")
            end
            H.Slash("probe watch")
            T.eq(ns.Probe.watching, true, "watch on")
            H.Fire("PLAYER_DEAD")
            H.Advance(2)
            H.Slash("probe watch")
            T.eq(ns.Probe.watching, false, "watch off")
            T.noErrors()
        end)

        T.case(client .. ": sim death and sighting fire internal events", function()
            local ns = H.Boot({ client = client })
            local report, enemy
            ns.Events:Register("HH_DEATH_REPORT", function(_, r, source) report = r; T.eq(source, "sim", "source") end, "t")
            ns.Events:Register("HH_ENEMY_SEEN", function(_, e) enemy = e end, "t")
            if client == "forever" then
                H.Slash('sim death "Grim Reaper" skull ROGUE Orc 3')
                T.eq(report and report.killer.key, "Grim Reaper", "killer key")
                T.eq(report.victim.key, "Vati Guda", "victim key")
            else
                H.Slash("sim death Gank skull ROGUE Orc 3")
                T.eq(report and report.killer.key, "Gank-Firemaw", "killer key")
                T.eq(report.victim.key, "Vati-Firemaw", "victim key")
            end
            T.eq(report.killer.level, -1, "skull")
            T.eq(report.killer.sex, 3, "sex")
            T.eq(report.mapID, 1429, "map")
            T.eq(report.t, H.serverTime, "server time")
            T.ok(report.id ~= nil, "id")

            H.Slash('sim sighting "Grim Reaper" 58 MAGE Troll')
            if client == "forever" then
                T.eq(enemy and enemy.level, 58, "sighting level")
            else
                T.eq(enemy, nil, "space in Era name rejected")
                T.ok(H.Printed("Invalid name"), "bad name message")
            end

            H.Slash(client == "forever" and 'sim death "Grim Reaper" sixty ROGUE Orc' or "sim death Gank sixty ROGUE Orc")
            T.ok(H.Printed("/hh sim death"), "usage on bad level")
            H.Slash("sim")
            T.noErrors()
        end)
    end
end
