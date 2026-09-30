-- HH-128: the sheriff's star on tournament hosts and co-organizers
-- (Tournament/Organizers.lua), from the website data. Made-up players only.

return function(T, H)
    local function Data(startsIn)
        return {
            format_version = 1,
            generated_at = H.serverTime - 60,
            worlds = {
                ["era|eu|Firemaw"] = {
                    generated_at = H.serverTime - 60,
                    tournaments = { {
                        id = "gatebrawl", name = "Gate Brawl", starts_at = H.serverTime + startsIn,
                        host = { name = "Tovik", realm = "Firemaw" },
                        organizers = { { name = "Marla", realm = "Firemaw" } },
                    } },
                },
            },
        }
    end

    local function Boot(startsIn, opts)
        opts = opts or {}
        opts.client, opts.siteData = "era", Data(startsIn)
        return H.Boot(opts)
    end

    T.case("the host gets the gold star and a co-organizer the silver one, from 1 hour before the start", function()
        local ns = Boot(1800)
        local O = ns.Organizers
        local role, tournament = O:RoleOf("Tovik-Firemaw")
        T.eq(role, "host", "host")
        T.eq(tournament and tournament.name, "Gate Brawl", "tournament")
        T.eq((O:RoleOf("Marla-Firemaw")), "organizer", "co-organizer")
        T.eq((O:RoleOf("Stranger-Firemaw")), nil, "anyone else")
        T.ok(O.Star("host"):find("230:180:34", 1, true) ~= nil, "gold")
        T.ok(O.Star("organizer"):find("192:192:192", 1, true) ~= nil, "silver")
        T.noErrors()
    end)

    T.case("no star before the hour before the start, nor 4 hours after it", function()
        local ns = Boot(2 * 3600)
        T.eq((ns.Organizers:RoleOf("Tovik-Firemaw")), nil, "2 hours before")
        T.eq((ns.Organizers:RoleOf("Tovik-Firemaw", H.serverTime + 2 * 3600 + 3600)), "host", "during")
        T.eq((ns.Organizers:RoleOf("Tovik-Firemaw", H.serverTime + 2 * 3600 + 4 * 3600 + 60)), nil, "after")
        T.noErrors()
    end)

    T.case("the tooltip of an organizer says so, friend or foe", function()
        local ns = Boot(1800, { tooltip = "script" })
        H.units.mouseover = { name = "Tovik", level = 30, class = "WARRIOR", race = "Human", faction = "Alliance",
            isPlayer = true }
        H.ShowUnitTooltip("mouseover")
        local text = table.concat(H.tooltipLines, "\n")
        T.ok(text:find("Tournament host: Gate Brawl · starts in 30 min", 1, true) ~= nil, "host line")
        T.ok(text:find("star", 1, true) ~= nil, "with the star")
        ns.db.settings.organizerMarks = false
        H.ShowUnitTooltip("mouseover")
        T.ok(not table.concat(H.tooltipLines, "\n"):find("Tournament host", 1, true), "option off")
        T.noErrors()
    end)

    T.case("an organizer's chat lines get the star; nobody else's", function()
        local ns = Boot(-600)
        local filter = ns.Organizers.ChatFilter
        local blocked, message, author = filter(nil, "CHAT_MSG_SAY", "Round 2 at the gate", "Marla")
        T.eq(blocked, false, "never hides a line")
        T.ok(message:find("^|T.-star.-|t Round 2 at the gate$") ~= nil, "star before the message")
        T.eq(author, "Marla", "author kept, so a click still whispers")
        local _, other = filter(nil, "CHAT_MSG_SAY", "hello", "Stranger")
        T.eq(other, nil, "nothing changed for others")
        T.noErrors()
    end)
end
