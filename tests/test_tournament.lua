-- M9 Gurubashi Tournament: HH-100 spike tools, HH-102 arena presence, HH-105 brackets.

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
        T.eq(select(2, Create(ns, { bracket = "robin", maxTeams = 9 })), "TEAMS", "round robin max 8")
        local t = Create(ns)
        T.ok(t ~= nil, "created")
        T.eq(t.state, "scheduled", "scheduled")
        T.eq(select(2, Create(ns)), "ALREADY", "one at a time")
        Run(5)
        T.eq(#Sent("^1AV:A", "CHANNEL"), 1, "announced on the hidden channel")
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
        T.eq(#Sent("^1AV:A.*;2~EVati Guda#%w+;2;Dampa Lee;Dampa Lee$", "CHANNEL"), 1,
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
