-- M9 Gurubashi Tournament: HH-100 spike tools, HH-101 model and protocol, HH-102 arena,
-- HH-103 tab and dialog, HH-104 reminders and check-in, HH-105 brackets.

return function(T, H)
    local function Ids(list, field)
        local out = {}
        for i, item in ipairs(list) do out[i] = tostring(field and item[field] or item) end
        return table.concat(out, ",")
    end

    -------------------------------------------------
    -- HH-100 spike tools
    -------------------------------------------------

    T.case("a ping from the other faction is printed; their other records stay dropped", function()
        local ns = H.Boot({ client = "forever" })
        H.Slash("debug on")
        H.Deliver(ns.Protocol.Pack("H", "T", { "12:00:00" }), "Hordie")
        T.ok(H.Printed("Sync ping from Hordie %[Horde%]"), "cross-faction ping shown with the faction")
        T.ok(H.Printed("Other faction %(Horde%) message from Hordie"), "debug line")
        T.eq(ns.Transport.stats.crossFaction, 1, "counted")
        T.noErrors()
    end)

    T.case("/hh sync whisper sends an addon whisper ping", function()
        H.Boot({ client = "era" })
        H.Slash('sync whisper "Hordie"')
        for _ = 1, 5 do H.Advance(1) end
        local whisper
        for _, m in ipairs(H.sent) do
            if m.chatType == "WHISPER" and m.message:find("^1AT:whisper") then whisper = m end
        end
        T.ok(whisper ~= nil, "whisper ping sent")
        T.eq(whisper and whisper.target, "Hordie", "to the name given")
        H.Slash("sync whisper")
        T.ok(H.Printed("Usage: /hh sync whisper"), "usage")
        T.noErrors()
    end)

    -------------------------------------------------
    -- HH-102 arena presence
    -------------------------------------------------

    T.case("arena: pit, stands, outside, other zone", function()
        local ns = H.Boot({ client = "era" })
        local A = ns.Arena
        T.eq(A.Where(1434, 0.3055, 0.4785), "pit", "center")
        T.eq(A.Where(1434, 0.312, 0.479), "pit", "east edge 31.2, 47.9")
        T.eq(A.Where(1434, 0.306, 0.489), "pit", "south edge 30.6, 48.9")
        T.eq(A.Where(1434, 0.299, 0.476), "pit", "west edge 29.9, 47.6")
        T.eq(A.Where(1434, 0.305, 0.468), "pit", "north edge 30.5, 46.8")
        T.eq(A.Where(1434, 0.316, 0.4785), "arena", "stands east of the pit")
        T.eq(A.Where(1434, 0.305, 0.492), "arena", "south seats start 30.5, 49.2")
        T.eq(A.Where(1434, 0.297, 0.476), "arena", "west seats start 29.7, 47.6")
        T.eq(A.Where(1434, 0.306, 0.465), "arena", "north seats start 30.6, 46.5")
        T.eq(A.Where(1434, 0.396, 0.480), nil, "outside")
        T.eq(A.Where(1429, 0.3055, 0.4785), nil, "another zone")
        T.eq(A.Where(1434, nil, nil), nil, "no position")

        H.playerMap, H.playerX, H.playerY = 1434, 0.306, 0.480
        T.eq(A:PlayerWhere(), "pit", "player in the pit")
        H.Slash("arena")
        T.ok(H.Printed("Stranglethorn Vale at 30%.6, 48%.0: .*in the arena pit"), "/hh arena")
        H.playerX = 0.5
        T.ok(not A:InArena(), "left")
        T.noErrors()
    end)

    -------------------------------------------------
    -- HH-101 model and protocol
    -------------------------------------------------

    local function Sent(pattern, chatType)
        local found = {}
        for _, m in ipairs(H.sent) do
            if m.message:find(pattern) and (not chatType or m.chatType == chatType) then found[#found + 1] = m end
        end
        return found
    end

    local function Run(seconds)
        for _ = 1, seconds do H.Advance(1) end
    end

    local function Create(ns, overrides)
        local opts = { name = "Blood Sands", format = 1, bracket = "single", bestOf = 3,
            start = H.serverTime + 1800, minLevel = 30, maxTeams = 2 }
        for k, v in pairs(overrides or {}) do opts[k] = v end
        return ns.Tournaments:Create(opts)
    end

    -- A join request from another player, as the organizer's client receives it
    local function Request(ns, t, who, level, action)
        H.Deliver(ns.Protocol.Pack("A", "V", { ns.Tournaments.EncodeRequest(t.id, action or "j", who,
            { { key = who, level = level or 40 } }) }), who)
    end

    T.case("tournament records round trip; free text loses separators", function()
        local TN = H.Boot({ client = "forever" }).Tournaments
        local t = { id = "Org Man#abc", organizer = "Org Man", name = "Blood Sands", format = 2, bracket = "robin",
            bestOf = 5, start = 1790000000, minLevel = 40, maxTeams = 8, state = "checkin", version = 7 }
        local a = TN.DecodeAnnounce(TN.EncodeAnnounce(t):sub(2))
        for _, k in ipairs({ "id", "organizer", "name", "format", "bracket", "bestOf", "start", "minLevel",
                "maxTeams", "state", "version" }) do
            T.eq(a[k], t[k], k)
        end
        local id, version, team = TN.DecodeEntrant(TN.EncodeEntrant(t, { id = "A B", members = { "A B", "C D" } }):sub(2))
        T.eq(id .. "|" .. version .. "|" .. team.id .. "|" .. table.concat(team.members, "+"), "Org Man#abc|7|A B|A B+C D", "entrant")
        local rid, action, teamId, members = TN.DecodeRequest(TN.EncodeRequest("x#1", "j", "A B",
            { { key = "A B", level = 41 }, { key = "C D", level = 42 } }):sub(2))
        T.eq(rid .. action .. teamId .. members[2].key .. members[2].level, "x#1jA BC D42", "request")
        T.eq(TN.Clean("  Blood;Sands~,:|  "), "BloodSands", "clean")
        T.eq(TN.DecodeAnnounce("x;y"), nil, "malformed")
        T.eq(TN.DecodeRequest("x;q;A;"), nil, "unknown action")
    end)

    T.case("create: checks every field, one open tournament per organizer, broadcast", function()
        local ns = H.Boot({ client = "forever" })
        local _, reason = Create(ns, { name = " ;; " })
        T.eq(reason, "NAME", "name")
        T.eq(select(2, Create(ns, { format = 4 })), "FORMAT", "format")
        T.eq(select(2, Create(ns, { bestOf = 2 })), "BEST_OF", "best of")
        T.eq(select(2, Create(ns, { start = H.serverTime + 10 })), "START", "too soon")
        T.eq(select(2, Create(ns, { minLevel = 61 })), "LEVEL", "level")
        T.eq(select(2, Create(ns, { minLevel = 18 })), "LEVEL", "tournaments start at level 19")
        H.units.player.level = 18
        T.eq(select(2, Create(ns)), "ORGANIZER_LEVEL", "hosts from level 19")
        H.units.player.level = 30
        T.eq(select(2, Create(ns, { bracket = "robin", maxTeams = 9 })), "TEAMS", "round robin max 8")
        local t = Create(ns)
        T.ok(t ~= nil, "created")
        T.eq(t.state, "scheduled", "scheduled")
        T.eq(select(2, Create(ns)), "ALREADY", "one at a time")
        Run(5)
        T.eq(#Sent("^1AV:A", "CHANNEL"), 1, "announced on the hidden channel")
        T.noErrors()
    end)

    T.case("no tournament starts near the arena chest (every 3 h from midnight, realm time)", function()
        local ns = H.Boot({ client = "forever" })
        local A = ns.Arena
        local now = H.serverTime
        -- Realm 13:00: chests at 12:00 and 15:00
        T.ok(A.StartClearOfChest(now + 15 * 60, now, 13 * 60), "13:15 is free")
        T.ok(A.StartClearOfChest(now + 60 * 60, now, 13 * 60), "14:00 is the last free start")
        T.ok(not A.StartClearOfChest(now + 90 * 60, now, 13 * 60), "14:30: under an hour to the 15:00 chest")
        T.ok(not A.StartClearOfChest(now + 125 * 60, now, 13 * 60), "15:05: the chest brawl")
        T.ok(A.StartClearOfChest(now + 135 * 60, now, 13 * 60), "15:15: over")
        T.ok(not A.StartClearOfChest(now + 11 * 3600 + 5 * 60, now, 13 * 60), "00:05 next day: the midnight chest")
        local clock = _G.GetGameTime
        _G.GetGameTime = nil
        T.ok(A.StartClearOfChest(now + 125 * 60, now), "no realm clock: not blocked")
        _G.GetGameTime = clock
        T.eq(A.MinutesToChest(13 * 60 + 20), 100, "next chest in 100 min")
        T.eq(A.MinutesToChest(15 * 60), 0, "chest now")

        T.eq(select(2, Create(ns, { start = now + 90 * 60 })), "CHEST", "create refuses it")
        H.Slash("tour")
        T.ok(H.Printed("Next arena chest in 120 min %(realm time 15:00%)"), "/hh tour shows the next chest")
        T.noErrors()
    end)

    T.case("organizer: join requests are checked, answered by whisper, and broadcast", function()
        local ns = H.Boot({ client = "forever" })
        local t = Create(ns)
        Run(5)
        H.sent = {}
        Request(ns, t, "Dampa Lee", 40)
        T.eq(ns.Tournaments:TeamCount(t), 1, "joined")
        T.eq(t.version, 2, "new version")
        Run(5)
        local reply = Sent("^1AV:X", "WHISPER")
        T.eq(#reply, 1, "reply whisper")
        T.eq(reply[1].target, "Dampa Lee", "to the player")
        T.ok(reply[1].message:find(";ok$") ~= nil, "ok")
        T.eq(#Sent("^1AV:A.*;2;gurubashi~EVati Guda#%w+;2;Dampa Lee;Dampa Lee$", "CHANNEL"), 1,
            "new announce and its entrant broadcast together")

        Request(ns, t, "Low Bie", 20)
        T.eq(ns.Tournaments:TeamCount(t), 1, "below the minimum level")
        H.Deliver(ns.Protocol.Pack("A", "V", { ns.Tournaments.EncodeRequest(t.id, "j", "Some One",
            { { key = "Some One", level = 40 } }) }), "Imposter Guy")
        T.eq(ns.Tournaments:TeamCount(t), 1, "only the team leader can register the team")
        Request(ns, t, "Kiko Ra", 45)
        Request(ns, t, "Third Wheel", 45)
        T.eq(ns.Tournaments:TeamCount(t), 2, "max 2 teams")
        Request(ns, t, "Dampa Lee", 40, "l")
        T.eq(ns.Tournaments:TeamCount(t), 1, "left")
        T.eq(t.order[1], "Kiko Ra", "order kept")
        T.noErrors()
    end)

    T.case("organizer: check-in starts by itself at the start time", function()
        local ns = H.Boot({ client = "forever" })
        local t = Create(ns, { start = H.serverTime + 120 })
        H.serverTime = H.serverTime + 120
        Run(6)
        T.eq(t.state, "checkin", "check-in")
        T.eq(t.version, 2, "announced as a new version")
        T.eq(ns.Tournaments:SetState(t.id, "scheduled"), false, "never backwards")
        T.eq(ns.Tournaments:SetState(t.id, "cancelled"), true, "cancel")
        T.eq(ns.Tournaments:SetState(t.id, "running"), false, "cancelled is final")
        T.noErrors()
    end)

    -- A tournament by "Org Man", as another player's client receives it
    local function Announce(ns, fields, entrants, sender)
        local t = { id = "Org Man#1", organizer = "Org Man", name = "Blood Sands", format = 1, bracket = "single",
            bestOf = 1, start = H.serverTime + 1800, minLevel = 30, maxTeams = 8, state = "scheduled", version = 1 }
        for k, v in pairs(fields or {}) do t[k] = v end
        local records = { ns.Tournaments.EncodeAnnounce(t) }
        for _, team in ipairs(entrants or {}) do records[#records + 1] = ns.Tournaments.EncodeEntrant(t, team) end
        H.Deliver(ns.Protocol.Pack("A", "V", records), sender or "Org Man")
        return ns.Tournaments:Get(t.id)
    end

    T.case("player: sees the tournament, joins by whisper, gets the answer", function()
        local ns = H.Boot({ client = "forever" })
        local t = Announce(ns, nil, { { id = "Kiko Ra", members = { "Kiko Ra" } } })
        T.ok(t ~= nil, "known")
        T.eq(ns.Tournaments:TeamCount(t), 1, "entrants")
        H.Slash("tour")
        T.ok(H.Printed("Blood Sands.*1v1.*single elimination.*Best of 1.*starts in 30 min.*level 30%+.*1/8 teams"),
            "listed")
        H.Slash("tour join 1")
        T.ok(H.Printed("Request sent"), "sent")
        Run(5)
        local request = Sent("^1AV:R", "WHISPER")
        T.eq(#request, 1, "request whisper")
        T.eq(request[1].target, "Org Man", "to the organizer")
        H.Deliver(ns.Protocol.Pack("A", "V", { "X" .. t.id .. ";ok" }), "Org Man")
        T.ok(H.Printed("You are in: Blood Sands"), "answer shown")

        Announce(ns, { version = 2 }, { { id = "Kiko Ra", members = { "Kiko Ra" } },
            { id = "Vati Guda", members = { "Vati Guda" } } })
        T.ok(ns.Tournaments:IsRegistered(t), "registered in the new version")
        Announce(ns, { version = 1, name = "Old" })
        T.eq(t.name, "Blood Sands", "older versions ignored")
        Announce(ns, { version = 9, name = "Fake" }, nil, "Some Troll")
        T.eq(t.name, "Blood Sands", "only the organizer speaks for the tournament")
        T.noErrors()
    end)

    T.case("player: 2v2 needs the party; levels are checked before asking", function()
        local ns = H.Boot({ client = "forever" })
        local t = Announce(ns, { format = 2 })
        T.eq(select(2, ns.Tournaments:Join(t.id)), "PARTY_SIZE", "no party")
        H.units.party1 = { name = "Kiko", realm = "Ra", level = 20, class = "MAGE", race = "Gnome",
            faction = "Alliance", isPlayer = true }
        T.eq(select(2, ns.Tournaments:Join(t.id)), "LEVEL_LOW", "party member too low")
        H.units.party1.level = 35
        T.eq(ns.Tournaments:Join(t.id), "sent", "sent")
        Run(5)
        T.ok(Sent("^1AV:R.*Kiko Ra:35", "WHISPER")[1] ~= nil, "both members with levels")
        T.noErrors()
    end)

    T.case("player: heartbeats to the organizer; nothing heard for 5 minutes = cancelled", function()
        local ns = H.Boot({ client = "forever" })
        local t = Announce(ns, { state = "checkin", start = H.serverTime - 60 },
            { { id = "Vati Guda", members = { "Vati Guda" } } })
        Run(65)
        T.ok(#Sent("^1AV:HOrg Man#1", "WHISPER") >= 1, "heartbeat sent")
        T.eq(t.state, "checkin", "still on after a minute")
        for _ = 1, 50 do H.Advance(5) end
        T.eq(t.state, "cancelled", "organizer gone")
        T.eq(t.cancelReason, "organizer", "why")
        T.ok(H.Printed("the organizer is gone"), "told")
        T.noErrors()
    end)

    T.case("organizer: answers a heartbeat with the tournament, not more than every 20 s", function()
        local ns = H.Boot({ client = "forever" })
        local t = Create(ns)
        Request(ns, t, "Dampa Lee", 40)
        Run(5)
        H.sent = {}
        H.Deliver(ns.Protocol.Pack("A", "V", { "H" .. t.id }), "Dampa Lee")
        H.Deliver(ns.Protocol.Pack("A", "V", { "H" .. t.id }), "Dampa Lee")
        Run(5)
        T.eq(#Sent("^1AV:A", "WHISPER"), 1, "one answer")
        T.noErrors()
    end)

    -------------------------------------------------
    -- HH-104 reminders and check-in
    -------------------------------------------------

    local function Centers(text)
        for _, line in ipairs(H.centerTexts) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end

    local function InPit()
        H.playerMap, H.playerX, H.playerY = 1434, 0.306, 0.479
    end

    T.case("entrants carry who checked in", function()
        local TN = H.Boot({ client = "forever" }).Tournaments
        local line = TN.EncodeEntrant({ id = "x#1", version = 4 },
            { id = "A B", members = { "A B", "C D" }, here = { ["C D"] = true } })
        T.eq(line, "Ex#1;4;A B;A B,+C D", "the + marks a check-in")
        local _, _, team = TN.DecodeEntrant(line:sub(2))
        T.eq(team.members[2], "C D", "name without the mark")
        T.ok(team.here["C D"] and not team.here["A B"], "who is here")
        T.ok(not TN.TeamIsIn(team), "a team is in only when everyone is")
        team.here["A B"] = true
        T.ok(TN.TeamIsIn(team), "all in")
    end)

    T.case("reminders: 30 and 5 min before, once each; a late login gets only the latest", function()
        local ns = H.Boot({ client = "forever" })
        local t = Announce(ns, { start = H.serverTime + 30 * 60 }, { { id = "Vati Guda", members = { "Vati Guda" } } })
        Run(5)
        T.ok(Centers("Blood Sands in 30 min"), "30 min: center text")
        T.ok(H.Printed("starts in 30 min at Gurubashi Arena"), "and chat")
        T.ok(#H.sounds >= 1, "and a sound")
        H.centerTexts = {}
        Run(10)
        T.eq(#H.centerTexts, 0, "not again")
        H.serverTime = t.start - 5 * 60
        Run(5)
        T.ok(Centers("Blood Sands in 5 min"), "5 min")

        ns = H.Boot({ client = "forever" })
        Announce(ns, { start = H.serverTime + 3 * 60 }, { { id = "Vati Guda", members = { "Vati Guda" } } })
        Run(5)
        T.ok(Centers("in 3 min"), "late: the latest one")
        T.eq(#H.centerTexts, 1, "only one")

        ns = H.Boot({ client = "forever" })
        Announce(ns, { start = H.serverTime + 20 * 60 })
        Run(5)
        T.ok(H.Printed("starts in 20 min and you can still join"), "could join: one chat line")
        T.eq(#H.centerTexts, 0, "no center text for them")
        T.noErrors()
    end)

    T.case("player: check-in popup, I'm here only inside the arena", function()
        local ns = H.Boot({ client = "forever" })
        local t = Announce(ns, { state = "checkin", start = H.serverTime - 30 },
            { { id = "Vati Guda", members = { "Vati Guda" } } })
        Run(5)
        T.ok(Centers("check-in!"), "center text")
        local popup
        for _, p in ipairs(H.popups) do if p.which == ns.Alerts.TOUR_POPUP then popup = p end end
        T.ok(popup ~= nil, "popup")
        T.eq(ns.Tournaments:JoinStatus(t), "checkin_me", "we must check in")

        T.eq(select(2, ns.Tournaments:CheckIn(t.id)), "NOT_AT_VENUE", "not in the arena yet")
        InPit()
        T.eq(ns.Tournaments:CheckIn(t.id), "sent", "sent")
        Run(5)
        T.eq(#Sent("^1AV:COrg Man#1$", "WHISPER"), 1, "check-in whisper to the organizer")
        H.Deliver(ns.Protocol.Pack("A", "V", { "X" .. t.id .. ";here" }), "Org Man")
        T.ok(H.Printed("Checked in for Blood Sands"), "confirmed")

        Announce(ns, { state = "checkin", start = H.serverTime - 30, version = 2 },
            { { id = "Vati Guda", members = { "+Vati Guda" } } })
        T.eq(ns.Tournaments:JoinStatus(t), "here", "checked in, from the organizer")
        T.noErrors()
    end)

    T.case("organizer: check-in marks players; after 10 min the no-shows drop out and it runs", function()
        local ns = H.Boot({ client = "forever" })
        local TN = ns.Tournaments
        local t = Create(ns, { start = H.serverTime + 120, maxTeams = 8 })
        Request(ns, t, "Dampa Lee", 40)
        Request(ns, t, "Kiko Ra", 40)
        Request(ns, t, "No Show", 40)
        H.serverTime = t.start
        Run(5)
        T.eq(t.state, "checkin", "check-in")
        H.Deliver(ns.Protocol.Pack("A", "V", { "C" .. t.id }), "Dampa Lee")
        H.Deliver(ns.Protocol.Pack("A", "V", { "C" .. t.id }), "Kiko Ra")
        H.Deliver(ns.Protocol.Pack("A", "V", { "C" .. t.id }), "Stranger Guy")
        T.ok(TN:IsHere(t, "Dampa Lee") and TN:IsHere(t, "Kiko Ra"), "marked")
        H.sent = {}
        Run(5)
        T.eq(#Sent(";here$", "WHISPER"), 2, "both answered")
        T.eq(#Sent(";notin$", "WHISPER"), 1, "not registered")
        T.eq(#Sent("~E" .. t.id:gsub("%p", "%%%0") .. ";%d+;Dampa Lee;%+Dampa Lee", "CHANNEL"), 1,
            "check-ins broadcast")
        T.eq(t.state, "checkin", "still waiting for No Show")

        H.serverTime = t.start + TN.CHECKIN_WINDOW
        Run(5)
        T.eq(t.state, "running", "running")
        T.eq(TN:TeamCount(t), 2, "No Show dropped")
        T.ok(H.Printed("2 teams are in"), "organizer told")
        local bracket = TN:Bracket(t)
        T.eq(#bracket.rounds, 1, "two teams: one final")
        local final = bracket.rounds[1][1]
        T.eq(final.a .. " v " .. final.b, table.concat(ns.Brackets.Seed(t.order, nil, t.start), " v "),
            "seeded from the teams that are in")
        T.eq(t.bracket, "single", "the kind is kept")
        T.noErrors()
    end)

    T.case("organizer: everyone in = no waiting; one team in = cancelled", function()
        local ns = H.Boot({ client = "forever" })
        local t = Create(ns, { start = H.serverTime + 120 })
        Request(ns, t, "Dampa Lee", 40)
        Request(ns, t, "Kiko Ra", 40)
        H.serverTime = t.start
        Run(5)
        H.Deliver(ns.Protocol.Pack("A", "V", { "C" .. t.id }), "Dampa Lee")
        H.Deliver(ns.Protocol.Pack("A", "V", { "C" .. t.id }), "Kiko Ra")
        Run(5)
        T.eq(t.state, "running", "all in: starts at once")

        ns = H.Boot({ client = "forever" })
        t = Create(ns, { start = H.serverTime + 120 })
        Request(ns, t, "Dampa Lee", 40)
        Request(ns, t, "Kiko Ra", 40)
        H.serverTime = t.start
        Run(5)
        H.Deliver(ns.Protocol.Pack("A", "V", { "C" .. t.id }), "Dampa Lee")
        H.serverTime = t.start + ns.Tournaments.CHECKIN_WINDOW
        Run(5)
        T.eq(t.state, "cancelled", "one team: cancelled")
        T.ok(H.Printed("fewer than 2 teams"), "told")
        T.noErrors()
    end)

    T.case("player: told when the matches begin; the same bracket as the organizer", function()
        local ns = H.Boot({ client = "forever" })
        local teams = { { id = "Vati Guda", members = { "+Vati Guda" } }, { id = "Kiko Ra", members = { "+Kiko Ra" } },
            { id = "Dampa Lee", members = { "+Dampa Lee" } } }
        local t = Announce(ns, { state = "checkin", start = H.serverTime - 60 }, teams)
        T.eq(ns.Tournaments:Bracket(t), nil, "no bracket during check-in")
        Announce(ns, { state = "running", start = H.serverTime - 60, version = 2 }, teams)
        T.ok(H.Printed("the matches begin"), "told")
        local bracket = ns.Tournaments:Bracket(t)
        T.eq(#bracket.rounds, 2, "3 teams: 4 slots, 2 rounds")
        local expected = ns.Brackets.SingleElimination(ns.Brackets.Seed({ "Vati Guda", "Kiko Ra", "Dampa Lee" }, nil,
            t.start), 1)
        T.eq(bracket.rounds[1][2].a .. bracket.rounds[1][2].b, expected.rounds[1][2].a .. expected.rounds[1][2].b,
            "same as the organizer builds")
        T.noErrors()
    end)

    T.case("tab: I'm here button during check-in", function()
        local ns = H.Boot({ client = "forever" })
        local MW = ns.MainWindow
        local t = Announce(ns, { state = "checkin", start = H.serverTime - 30 },
            { { id = "Vati Guda", members = { "Vati Guda" } } })
        T.eq(MW.TourActions(t).action, "here", "I'm here")
        T.ok(MW.Rows("tours")[1].status:find("Check in now", 1, true) ~= nil, "status")
        MW:Toggle()
        MW:SelectTab("tours")
        MW:OnRowClick(MW.shownRows[1])
        MW:TourAction()
        T.ok(H.Printed("You must be at the tournament"), "outside the arena")
        InPit()
        MW:TourAction()
        T.ok(H.Printed("Check%-in sent for Blood Sands"), "sent")
        H.Slash("tour here")
        T.noErrors()
    end)

    -------------------------------------------------
    -- Venues: Gurubashi for both factions, capital gates for their own faction
    -------------------------------------------------

    T.case("venues: Gurubashi for all, each faction its own capital gates", function()
        local ns = H.Boot({ client = "forever" })
        local A = ns.Arena
        local function Ids(list)
            local out = {}
            for i, v in ipairs(list) do out[i] = v.id end
            return table.concat(out, ",")
        end
        T.eq(Ids(A.VenuesFor("Alliance")), "gurubashi,ironforge,stormwind", "Alliance")
        T.eq(Ids(A.VenuesFor("Horde")), "gurubashi,orgrimmar,undercity", "Horde")
        T.ok(A.VenueAllowed("gurubashi", "Horde") and not A.VenueAllowed("stormwind", "Horde"), "allowed")
        local sw = A.VENUE.stormwind
        T.eq(A.VenueWhere("stormwind", sw.mapID, sw.center.x, sw.center.y), "fight", "at the Stormwind gate")
        T.eq(A.VenueWhere("stormwind", sw.mapID, sw.center.x + 0.1, sw.center.y), nil, "away from it")
        T.eq(A.VenueWhere("stormwind", 1434, sw.center.x, sw.center.y), nil, "other zone")
        T.eq(A.VenueWhere("gurubashi", 1434, 0.3055, 0.4785), "fight", "Gurubashi pit")

        H.playerMap, H.playerX, H.playerY = sw.mapID, sw.center.x, sw.center.y
        H.Slash("arena")
        T.ok(H.Printed("at the Stormwind gate"), "/hh arena names the venue")
        H.playerX = 0.9
        H.Slash("arena")
        T.ok(H.Printed("not at a tournament venue"), "and says when we are at none")
        T.noErrors()
    end)

    T.case("venues: create, announce, chest rule only at Gurubashi, check-in at the venue", function()
        local ns = H.Boot({ client = "forever" })
        local TN = ns.Tournaments
        -- The player is Alliance; realm 13:00, so 14:30 is too close to the 15:00 chest
        T.eq(select(2, Create(ns, { venue = "orgrimmar" })), "VENUE", "a Horde venue")
        T.eq(select(2, Create(ns, { start = H.serverTime + 90 * 60 })), "CHEST", "Gurubashi keeps the chest rule")
        local t = Create(ns, { venue = "stormwind", start = H.serverTime + 90 * 60 })
        T.ok(t ~= nil, "the Stormwind gate has no chest")
        T.eq(t.venue, "stormwind", "venue kept")
        local a = TN.DecodeAnnounce(TN.EncodeAnnounce(t):sub(2))
        T.eq(a.venue, "stormwind", "sent with the announce")
        T.eq(TN.DecodeAnnounce((TN.EncodeAnnounce(t):sub(2):gsub("stormwind$", "moonglade"))), nil, "unknown venue")
        T.eq(TN.Where(t), "the Stormwind gate (Elwynn Forest)", "named")

        -- Check-in at a Stormwind tournament: the pit does not count, the gate does
        ns = H.Boot({ client = "forever" })
        TN = ns.Tournaments
        local g = Announce(ns, { state = "checkin", start = H.serverTime - 30, venue = "stormwind" },
            { { id = "Vati Guda", members = { "Vati Guda" } } })
        T.eq(g.venue, "stormwind", "received")
        InPit()
        T.eq(select(2, TN:CheckIn(g.id)), "NOT_AT_VENUE", "Gurubashi is the wrong place")
        local sw = ns.Arena.VENUE.stormwind
        H.playerMap, H.playerX, H.playerY = sw.mapID, sw.center.x, sw.center.y
        T.eq(TN:CheckIn(g.id), "sent", "at the Stormwind gate")
        T.ok(table.concat(ns.MainWindow.Rows("tours")[1].tooltip, "\n"):find("Where: the Stormwind gate", 1, true) ~= nil,
            "the tab says where")
        T.noErrors()
    end)

    T.case("below level 19: no Create button, no dialog, no /hh tour create", function()
        local ns = H.Boot({ client = "forever" })
        H.units.player.level = 14
        local MW = ns.MainWindow
        MW:Toggle()
        MW:SelectTab("tours")
        T.eq(MW.tourButtons.create, false, "no Create button")
        T.eq(ns.TournamentDialog:Open(), false, "the dialog does not open")
        T.ok(not ns.TournamentDialog:IsShown(), "not shown")
        T.ok(H.Printed("You can host tournaments from level 19"), "told why")
        H.printed = {}
        H.Slash('tour create "Lowbie Cup" 1v1 single bo1 30 19')
        T.ok(H.Printed("You can host tournaments from level 19"), "the command refuses too")
        T.eq(#ns.Tournaments:List(), 0, "nothing created")
        H.units.player.level = 19
        MW:Refresh()
        T.eq(MW.tourButtons.create, true, "at 19: Create")
        T.noErrors()
    end)

    T.case("create dialog: venue dropdown with our faction's venues; the chest only matters at Gurubashi", function()
        local ns = H.Boot({ client = "forever" })
        local D = ns.TournamentDialog
        D:Open()
        T.eq(D.values.venue, "gurubashi", "Gurubashi by default")
        local dropdowns = D:Dropdowns()
        T.eq(dropdowns.venue.dropdown.menuText, "Gurubashi Arena (Stranglethorn Vale)", "shown")
        local entries = H.OpenDropdown(dropdowns.venue.dropdown)
        T.eq(#entries, 3, "Gurubashi, Ironforge, Stormwind")
        D.values.minutes = 90
        T.ok(D.Preview(D.values):find("arena chest", 1, true) ~= nil, "chest warning at Gurubashi")
        entries[3].func()
        T.eq(D.values.venue, "stormwind", "picked the Stormwind gate")
        T.ok(D.Preview(D.values):find("Starts at 14:30", 1, true) ~= nil, "no chest there")
        D.values.name = "Gate Brawl"
        local t = D:Submit()
        T.eq(t and t.venue, "stormwind", "created there")
        T.noErrors()
    end)

    -------------------------------------------------
    -- HH-103 Tournaments tab and Create dialog
    -------------------------------------------------

    T.case("tab rows: details, our status, tooltip with the teams", function()
        local ns = H.Boot({ client = "forever" })
        Announce(ns, { minLevel = 50 }, { { id = "Kiko Ra", members = { "Kiko Ra" } } })
        Announce(ns, { id = "Org Man#2", name = "Pit Kings", format = 2, bracket = "robin", bestOf = 3,
            start = H.serverTime + 3 * 3600 + 20 * 60 })
        local rows = ns.MainWindow.Rows("tours")
        T.eq(#rows, 2, "two tournaments")
        local r = rows[1]
        T.eq(r.name, "Blood Sands", "soonest first")
        T.eq(r.format .. "|" .. r.series .. "|" .. r.start .. "|" .. r.level .. "|" .. r.teams,
            "1v1|Best of 1|in 30 min|50+|1/8", "columns")
        T.ok(r.status:find("Level too low", 1, true) ~= nil, "we are level 30")
        T.ok(table.concat(r.tooltip, "\n"):find("Kiko Ra", 1, true) ~= nil, "teams in the tooltip")
        T.ok(table.concat(r.tooltip, "\n"):find("realm time 13:30", 1, true) ~= nil, "realm start time")
        T.eq(rows[2].series, "Best of 3, robin", "round robin")
        T.eq(rows[2].start, "in 3 h 20 min", "hours")
        T.ok(rows[2].status:find("Needs a party", 1, true) ~= nil, "2v2 without a party")
        T.noErrors()
    end)

    T.case("tab: a click selects; Join, Leave and Cancel follow the selection", function()
        local ns = H.Boot({ client = "forever" })
        local MW = ns.MainWindow
        local other = Announce(ns)
        local mine = Create(ns, { name = "My Cup" })
        MW:Toggle()
        MW:SelectTab("tours")
        T.eq(MW.tourButtons.create, true, "Create shown")
        T.eq(MW.tourButtons.action, nil, "nothing selected")

        local function RowOf(id)
            for _, row in ipairs(MW.shownRows) do if row.id == id then return row end end
        end
        MW:OnRowClick(RowOf(other.id))
        T.eq(MW:SelectedTour(), other.id, "selected, no poster")
        T.eq(MW.tourButtons.action, "join", "Join")
        T.eq(MW.tourButtons.cancel, false, "not ours")
        MW:TourAction()
        Run(5)
        T.eq(#Sent("^1AV:R", "WHISPER"), 1, "Join sent the request")

        MW:OnRowClick(RowOf(mine.id))
        T.eq(MW.tourButtons.cancel, true, "Cancel on our own")
        MW:TourAction()
        T.ok(ns.Tournaments:IsRegistered(mine), "we joined our own cup directly")
        T.eq(MW.tourButtons.action, "leave", "then Leave")
        T.ok(H.Printed("You are in: My Cup"), "told")

        MW:SelectTab("wanted")
        T.eq(MW.tourButtons.create, false, "buttons only on the Tournaments tab")
        T.noErrors()
    end)

    T.case("create dialog: free start by default, live chest check, errors, create", function()
        local ns = H.Boot({ client = "forever" })
        local D = ns.TournamentDialog
        D:Open()
        T.ok(D:IsShown(), "open")
        T.eq(D.values.minutes, 30, "30 min: 13:30 is free")
        T.eq(D.values.minLevel, 30, "our level by default")
        T.ok(D.Preview(D.values):find("Starts at 13:30", 1, true) ~= nil, "preview")
        D.values.minutes = 90
        T.ok(D.Preview(D.values):find("clashes with the arena chest", 1, true) ~= nil, "chest warning")
        T.eq(select(2, D:Submit()), "NAME", "needs a name")
        D.values.name = "Sunday Brawl"
        T.eq(select(2, D:Submit()), "CHEST", "refused")
        D.values.minutes = 45

        -- Format, bracket and series are dropdowns (the GudaBags select)
        local dropdowns = D:Dropdowns()
        T.eq(dropdowns.format.dropdown.menuText, "1v1", "format shown")
        T.eq(dropdowns.series.dropdown.menuText, "Best of 3", "series shown")
        local entries = H.OpenDropdown(dropdowns.format.dropdown)
        T.eq(#entries, 4, "1v1, 2v2, 3v3, 5v5")
        T.eq(entries[1].checked, true, "current one checked")
        entries[2].func()
        T.eq(D.values.format, 2, "picked 2v2")
        T.eq(dropdowns.format.dropdown.menuText, "2v2", "shown")
        H.OpenDropdown(dropdowns.bracket.dropdown)[2].func()
        T.eq(D.values.bracket, "robin", "round robin")
        T.eq(dropdowns.bracket.dropdown.menuText, "round robin", "shown")
        dropdowns.bracket:Choose("single")

        local t = D:Submit()
        T.ok(t ~= nil, "created")
        T.eq(t.format, 2, "2v2")
        T.eq(t.start, H.serverTime + 45 * 60, "start")
        T.ok(not D:IsShown(), "closed")
        T.ok(H.Printed("Tournament |cffffd100Sunday Brawl|r created"), "told")

        H.gameTime = { 14, 40 } -- 20 min to the 15:00 chest: the default skips past it
        D:Open()
        T.eq(D.values.minutes, 35, "first free start: 15:15")
        T.eq(D:Dropdowns().format.dropdown.menuText, "1v1", "reopened with the defaults")
        T.noErrors()
    end)

    T.case("select: the modern dropdown where the client has it", function()
        local ns = H.Boot({ client = "forever" })
        local radio
        _G.DoesTemplateExist = function(name) return name == "WowStyle1DropdownTemplate" end
        _G.MenuUtil = { CreateRadioMenu = function(_, isSelected, onSelect, ...)
            radio = { isSelected = isSelected, onSelect = onSelect, entries = { ... } }
        end }
        local value = "b"
        local select = ns.Select.Create(UIParent, { options = { { value = "a", label = "A" }, { value = "b", label = "B" } },
            get = function() return value end, set = function(v) value = v end })
        T.eq(#radio.entries, 2, "radio menu entries")
        T.eq(radio.entries[1][1] .. radio.entries[1][2], "Aa", "label, value")
        T.ok(radio.isSelected("b") and not radio.isSelected("a"), "current value selected")
        radio.onSelect("a")
        T.eq(value, "a", "picked")
        select:Choose("b")
        T.eq(value, "b", "Choose")
        _G.DoesTemplateExist, _G.MenuUtil = nil, nil
        T.noErrors()
    end)

    -------------------------------------------------
    -- HH-105 brackets
    -------------------------------------------------

    T.case("seeding: rated best first, unrated shuffled the same way on every client", function()
        local B = H.Boot({ client = "era" }).Brackets
        local ratings = { A = 10, B = 30, C = 20 }
        local entrants = { "A", "B", "C", "X", "Y", "Z" }
        local seeds = B.Seed(entrants, function(id) return ratings[id] end, 42)
        T.eq(Ids({ seeds[1], seeds[2], seeds[3] }), "B,C,A", "rated first, best first")
        T.eq(Ids(B.Seed({ "Z", "Y", "X", "C", "B", "A" }, function(id) return ratings[id] end, 42)), Ids(seeds),
            "same seed, same order whatever the join order")
        T.eq(B.WinsNeeded(1), 1, "Best of 1")
        T.eq(B.WinsNeeded(3), 2, "Best of 3")
        T.eq(B.WinsNeeded(5), 3, "Best of 5")
        T.eq(Ids(B.SeedOrder(8)), "1,8,4,5,2,7,3,6", "seed order")
    end)

    T.case("single elimination with byes, Best of 3, standings and points", function()
        local B = H.Boot({ client = "era" }).Brackets
        local br = B.SingleElimination({ "S1", "S2", "S3", "S4", "S5" }, 3)
        T.eq(#br.rounds, 3, "8 slots: 3 rounds")
        local r1 = br.rounds[1]
        T.eq(r1[1].winner, "S1", "S1 bye")
        T.eq(r1[1].bye, true, "marked as a bye")
        T.eq(r1[2].a .. "v" .. r1[2].b, "S4vS5", "the only first-round game")
        T.eq(br.rounds[2][2].a .. "v" .. br.rounds[2][2].b, "S2vS3", "byes meet in round 2")
        T.eq(Ids(B.Ready(br), "id"), "r1m2,r2m2", "ready now")

        T.eq(B.RecordGame(br, "r1m2", "Nobody"), nil, "not in this match")
        B.RecordGame(br, "r1m2", "S5")
        T.eq(r1[2].winner, nil, "one game is not enough in Best of 3")
        B.RecordGame(br, "r1m2", "S4")
        B.RecordGame(br, "r1m2", "S5")
        T.eq(r1[2].winner, "S5", "2 wins")
        T.eq(br.rounds[2][1].b, "S5", "advanced")
        T.eq(B.RecordGame(br, "r1m2", "S5"), nil, "decided matches take no more games")

        for _ = 1, 2 do B.RecordGame(br, "r2m1", "S1") end
        for _ = 1, 2 do B.RecordGame(br, "r2m2", "S3") end
        T.eq(br.rounds[3][1].a .. "v" .. br.rounds[3][1].b, "S1vS3", "final")
        for _ = 1, 2 do B.RecordGame(br, "r3m1", "S3") end
        T.ok(B.Finished(br), "finished")
        T.eq(br.champion, "S3", "champion")

        local standings = B.Standings(br)
        T.eq(Ids(standings, "id"), "S3,S1,S5,S2,S4", "order")
        T.eq(Ids(standings, "place"), "1,2,3,3,5", "places")
        T.eq(Ids(standings, "points"), "10,6,3,3,1", "points")
    end)

    T.case("round robin: everyone meets everyone once, one round at a time", function()
        local B = H.Boot({ client = "era" }).Brackets
        local br = B.RoundRobin({ "A", "B", "C" }, 1)
        T.eq(#br.rounds, 3, "3 rounds for 3 (one sits out)")
        local pairs = {}
        for _, round in ipairs(br.rounds) do
            T.eq(#round, 1, "one match per round")
            for _, m in ipairs(round) do
                local key = m.a < m.b and m.a .. m.b or m.b .. m.a
                T.eq(pairs[key], nil, "no pair twice")
                pairs[key] = true
            end
        end
        T.eq(Ids(B.Ready(br), "id"), "r1m1", "only the first round is ready")

        -- A beats everyone, B beats C
        for _, round in ipairs(br.rounds) do
            local m = round[1]
            local winner = (m.a == "A" or m.b == "A") and "A" or "B"
            B.RecordGame(br, m.id, winner)
        end
        T.ok(B.Finished(br), "finished")
        T.eq(Ids(B.Standings(br), "id"), "A,B,C", "by match wins")

        local four = B.RoundRobin({ "A", "B", "C", "D" }, 1)
        T.eq(#four.rounds, 3, "3 rounds for 4")
        T.eq(#four.rounds[1], 2, "2 matches per round")
        T.eq(B.SingleElimination({ "A" }), nil, "one entrant: no bracket")
    end)
end
