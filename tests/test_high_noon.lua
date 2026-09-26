-- M8 High Noon (HH-090..093): duels seen in chat, shared, rated, listed per faction.

return function(T, H)
    -- `n` duels won by `winner` over `loser`, a few minutes apart
    local function Duels(ns, winner, loser, n, faction, from)
        for i = 1, n do
            ns.Duels:Add({ winner = winner, loser = loser, t = H.serverTime - 86400 + (from or 0) + i * 300,
                faction = faction or "Alliance", winnerLevel = 30, loserLevel = 30 }, "local")
        end
    end

    local function Settle()
        H.Advance(1)
        for _ = 1, 5 do H.Advance(0) end
    end

    local function Sent(pattern)
        local found = {}
        for _, m in ipairs(H.sent) do
            if m.message:find(pattern) then found[#found + 1] = m end
        end
        return found
    end

    -------------------------------------------------
    -- HH-090 detection
    -------------------------------------------------

    T.case("client duel strings become patterns, positional ones too", function()
        local ns = H.Boot({ client = "era" })
        local D = ns.Duels
        local winner, loser, retreat = D.Parse("Gank has defeated Bob in a duel")
        T.eq(winner, "Gank", "winner")
        T.eq(loser, "Bob", "loser")
        T.eq(retreat, false, "knockout")
        winner, loser, retreat = D.Parse("Bob has fled from Gank in a duel")
        T.eq(winner, "Gank", "retreat: winner is the one who stayed")
        T.eq(loser, "Bob", "retreat: loser fled")
        T.eq(retreat, true, "retreat")
        T.eq(D.Parse("Bob has come online."), nil, "not a duel")
        T.eq(D.Parse(nil), nil, "no message")

        local pattern, order = D.Pattern("%s hat %s im Duell besiegt.")
        T.eq(order[1], 1, "plain %s: in order")
        T.eq(order[2], 2, "plain %s: in order")
        local a, b = ("Gank hat Bob im Duell besiegt."):match(pattern)
        T.eq(a .. ">" .. b, "Gank>Bob", "special characters escaped")
        T.noErrors()
    end)

    T.case("a duel in chat is stored once, even when a second witness sees it", function()
        local ns = H.Boot({ client = "era" })
        H.units.target = { name = "Bob", level = 32, class = "MAGE", race = "Gnome", faction = "Alliance", isPlayer = true }
        H.Fire("CHAT_MSG_SYSTEM", "Vati has defeated Bob in a duel")
        T.eq(ns.Duels:Count(), 1, "stored")
        local _, duel = next(ns.db.duels)
        T.eq(duel.winner, "Vati-Firemaw", "winner key")
        T.eq(duel.loser, "Bob-Firemaw", "loser key")
        T.eq(duel.faction, "Alliance", "faction")
        T.eq(duel.winnerClass, "ROGUE", "winner class from the player unit")
        T.eq(duel.loserRace, "Gnome", "loser race from the target")
        T.eq(duel.mapID, 1429, "zone")

        H.Advance(20)
        H.serverTime = H.serverTime + 20
        H.Deliver(ns.Protocol.Pack("A", "U", { ns.Protocol.EncodeDuel({ winner = "Vati-Firemaw",
            loser = "Bob-Firemaw", t = H.serverTime, mapID = 1429, faction = "Alliance", winnerLevel = 30, loserLevel = 32 }) }), "Witness-Firemaw")
        T.eq(ns.Duels:Count(), 1, "the same pair within a minute is one duel")
        T.noErrors()
    end)

    T.case("a seen duel is shared; nothing is shared for chat that is not a duel", function()
        local ns = H.Boot({ client = "era" })
        H.inGuild = true
        H.units.target = { name = "Gank", level = 31, class = "ROGUE", race = "Dwarf", faction = "Alliance", isPlayer = true }
        H.units.mouseover = { name = "Bob", level = 29, class = "MAGE", race = "Gnome", faction = "Alliance", isPlayer = true }
        H.Fire("CHAT_MSG_SYSTEM", "Bob has come online.")
        H.Fire("CHAT_MSG_SYSTEM", "Bob has fled from Gank in a duel")
        for _ = 1, 30 do H.Advance(1) end
        local sent = Sent("^1AU:")
        T.eq(#sent, 1, "one duel record")
        T.ok(sent[1].message:find("Gank%-Firemaw;Bob%-Firemaw") ~= nil, "winner;loser")
        local _, duel = next(ns.db.duels)
        T.eq(duel.retreat, true, "retreat kept")
        T.noErrors()
    end)

    T.case("a witness stays quiet when another witness shared the duel first", function()
        local ns = H.Boot({ client = "era" })
        H.inGuild = true
        H.units.target = { name = "Gank", level = 31, class = "ROGUE", race = "Dwarf", faction = "Alliance", isPlayer = true }
        H.units.mouseover = { name = "Bob", level = 29, class = "MAGE", race = "Gnome", faction = "Alliance", isPlayer = true }
        H.Fire("CHAT_MSG_SYSTEM", "Gank has defeated Bob in a duel")
        H.Deliver(ns.Protocol.Pack("A", "U", { ns.Protocol.EncodeDuel({ winner = "Gank-Firemaw", loser = "Bob-Firemaw",
            t = H.serverTime, mapID = 1429, faction = "Alliance", winnerLevel = 31, loserLevel = 29 }) }), "Witness-Firemaw")
        for _ = 1, 30 do H.Advance(1) end
        T.eq(#Sent("^1AU:"), 0, "not shared twice")
        T.eq(ns.Duels:Count(), 1, "stored once")
        T.noErrors()
    end)

    T.case("our own duel is shared at once, even when a witness shares it too", function()
        local ns = H.Boot({ client = "era" })
        H.inGuild = true
        H.units.target = { name = "Bob", level = 30, class = "MAGE", race = "Gnome", faction = "Alliance", isPlayer = true }
        H.Fire("CHAT_MSG_SYSTEM", "Vati has defeated Bob in a duel")
        H.Deliver(ns.Protocol.Pack("A", "U", { ns.Protocol.EncodeDuel({ winner = "Vati-Firemaw", loser = "Bob-Firemaw",
            t = H.serverTime, mapID = 1429, faction = "Alliance", winnerLevel = 30, loserLevel = 30 }) }), "Witness-Firemaw")
        for _ = 1, 30 do H.Advance(1) end
        T.eq(#Sent("^1AU:"), 1, "shared: the duelists are the best source")
    end)

    T.case("duelists the enemy cache knows are the other faction", function()
        local ns = H.Boot({ client = "era" })
        ns.EnemyCache:Upsert("Gank-Firemaw", { level = 60, class = "ROGUE" }, "test")
        ns.EnemyCache:Upsert("Orcy-Firemaw", { level = 58, class = "WARRIOR" }, "test")
        H.Fire("CHAT_MSG_SYSTEM", "Gank has defeated Orcy in a duel")
        local _, duel = next(ns.db.duels)
        T.eq(duel.faction, "Horde", "Horde duel")
        T.eq(duel.winnerLevel, 60, "level from the enemy cache")
        T.eq(duel.loserLevel, 58, "level from the enemy cache")
        T.noErrors()
    end)

    T.case("only duels within 5 levels count; lowbie and unknown-level duels are not stored or shared", function()
        local ns = H.Boot({ client = "era" })
        H.inGuild = true
        -- The player is 30
        H.units.target = { name = "Lowbie", level = 24, class = "MAGE", race = "Gnome", faction = "Alliance", isPlayer = true }
        H.Fire("CHAT_MSG_SYSTEM", "Vati has defeated Lowbie in a duel")
        T.eq(ns.Duels:Count(), 0, "6 levels apart: not counted")
        H.units.target.level = 35
        H.serverTime = H.serverTime + 120
        H.Fire("CHAT_MSG_SYSTEM", "Lowbie has defeated Vati in a duel")
        T.eq(ns.Duels:Count(), 1, "5 levels apart: counted")
        H.units.target = nil
        H.serverTime = H.serverTime + 120
        H.Fire("CHAT_MSG_SYSTEM", "Vati has defeated Stranger in a duel")
        T.eq(ns.Duels:Count(), 1, "unknown level: not counted")
        H.units.target = { name = "Big", level = -1, class = "MAGE", race = "Gnome", faction = "Alliance", isPlayer = true }
        H.Fire("CHAT_MSG_SYSTEM", "Big has defeated Vati in a duel")
        T.eq(ns.Duels:Count(), 1, "skull level: not counted")
        for _ = 1, 30 do H.Advance(1) end
        T.eq(#Sent("^1AU:"), 1, "only the fair duel was shared")
        T.noErrors()
    end)

    T.case("the opponent's level is remembered from an earlier target", function()
        local ns = H.Boot({ client = "era" })
        H.units.target = { name = "Bob", level = 31, class = "MAGE", race = "Gnome", faction = "Alliance", isPlayer = true }
        H.Fire("PLAYER_TARGET_CHANGED")
        H.units.target = nil
        H.Slash("debug on")
        H.Fire("CHAT_MSG_SYSTEM", "Vati has defeated Bob in a duel")
        T.eq(ns.Duels:Count(), 1, "counted")
        local _, duel = next(ns.db.duels)
        T.eq(duel.loserLevel, 31, "remembered level")
        T.ok(H.Printed("Duel recorded:"), "debug line")
        H.Fire("CHAT_MSG_SYSTEM", "Duel odd wording from somewhere")
        T.ok(H.Printed("Duel message not understood"), "unknown duel text is shown in debug")
        T.noErrors()
    end)

    -- Forever: no result line; our addon judges our own duel
    local function OwnDuel(opts)
        local ns = H.Boot({ client = "forever" })
        H.units.target = { name = "Dampa", realm = "Lee", level = 31, class = "PALADIN", race = "Human",
            faction = "Alliance", isPlayer = true, health = 900 }
        if opts.challenged then H.Fire("DUEL_REQUESTED", "Dampa Lee") end
        for i = 3, 1, -1 do H.Fire("CHAT_MSG_SYSTEM", "Duel starting: " .. i) end
        H.Advance(opts.fight or 20)
        if opts.fled then H.Fire("DUEL_OUTOFBOUNDS") end
        if opts.lowUnit then
            H.units[opts.lowUnit].health = 1
            H.Fire("UNIT_HEALTH", opts.lowUnit)
            H.units[opts.lowUnit].health = 50
        end
        if opts.targetGone then H.units.target = nil end
        H.Fire("DUEL_FINISHED")
        H.Advance(ns.Duels.RESULT_WAIT)
        local _, duel = next(ns.db.duels)
        return ns, duel
    end

    T.case("forever: we knock the opponent to 1 HP: our win", function()
        local ns, duel = OwnDuel({ lowUnit = "target" })
        T.eq(ns.Duels:Count(), 1, "recorded")
        T.eq(duel.winner, ns.Utils.UnitKey("player"), "we won")
        T.eq(duel.loser, ns.Utils.PlayerKey("Dampa Lee"), "opponent from the target")
        T.eq(duel.retreat, nil, "knockout")
        T.eq(duel.loserLevel, 31, "level")
        T.noErrors()
    end)

    T.case("forever: we drop to 1 HP: their win, opponent from the challenge", function()
        local ns, duel = OwnDuel({ challenged = true, lowUnit = "player", targetGone = true })
        T.eq(duel and duel.winner, ns.Utils.PlayerKey("Dampa Lee"), "they won")
        T.eq(duel.loserLevel, 30, "our level")
        T.eq(duel.winnerLevel, 31, "their level remembered from the countdown")
        T.noErrors()
    end)

    T.case("forever: leaving the duel area is our retreat; their unseen fall is our win", function()
        local ns, duel = OwnDuel({ fled = true })
        T.eq(duel.loser, ns.Utils.UnitKey("player"), "we fled")
        T.eq(duel.retreat, true, "retreat")
        ns, duel = OwnDuel({})
        T.eq(duel.winner, ns.Utils.UnitKey("player"), "we stand: our win")
        T.eq(duel.retreat, true, "their health never seen at 1: counted as their retreat")
    end)

    T.case("forever: a duel cancelled in the countdown does not count", function()
        local ns = OwnDuel({ fight = 0 })
        T.eq(ns.Duels:Count(), 0, "cancelled")
        H.Fire("DUEL_FINISHED")
        H.Advance(ns.Duels.RESULT_WAIT)
        T.eq(ns.Duels:Count(), 0, "no duel going on")
        T.noErrors()
    end)

    -- Forever may send no countdown line: a challenge (either way) plus entering combat
    local function SilentDuel(ns, opts)
        H.units.target = { name = "Dampa", realm = "Lee", level = 31, class = "PALADIN", race = "Human",
            faction = "Alliance", isPlayer = true, health = 900 }
        if opts.challenged then
            H.Fire("DUEL_REQUESTED", "Dampa Lee")
            if opts.noTarget then H.units.target = nil end
        else
            _G.StartDuel("target")
        end
        H.Advance(opts.wait or 3)
        if opts.combat ~= false then
            if opts.noTarget then
                -- They show up as our target only once the fight is on
                H.units.target = { name = "Dampa", realm = "Lee", level = 31, class = "PALADIN", race = "Human",
                    faction = "Alliance", isPlayer = true, health = 900 }
            end
            H.Fire("PLAYER_REGEN_DISABLED")
            H.Advance(15)
            H.units.target.health = 1
            H.Fire("UNIT_HEALTH", "target")
            if opts.noTarget then H.units.target = nil end
        end
        H.Fire("DUEL_FINISHED")
        H.Advance(ns.Duels.RESULT_WAIT)
        local _, duel = next(ns.db.duels)
        return duel
    end

    T.case("forever, no countdown line: our challenge plus combat is a duel", function()
        local ns = H.Boot({ client = "forever" })
        local duel = SilentDuel(ns, {})
        T.eq(H.duelsStarted[1], "target", "the challenge still goes out")
        T.eq(ns.Duels:Count(), 1, "recorded")
        T.eq(duel.winner, ns.Utils.UnitKey("player"), "we won")
        T.eq(duel.loser, ns.Utils.PlayerKey("Dampa Lee"), "opponent from the challenge")
        T.eq(duel.retreat, nil, "knockout")
        T.noErrors()
    end)

    T.case("forever, no countdown line: challenged, never targeted, level seen in the fight", function()
        local ns = H.Boot({ client = "forever" })
        local duel = SilentDuel(ns, { challenged = true, noTarget = true })
        T.eq(ns.Duels:Count(), 1, "recorded")
        T.eq(duel.loser, ns.Utils.PlayerKey("Dampa Lee"), "opponent from the request")
        T.eq(duel.loserLevel, 31, "their level, seen during the fight")
        T.noErrors()
    end)

    T.case("forever: a declined challenge, or combat long after it, is no duel", function()
        local ns = H.Boot({ client = "forever" })
        SilentDuel(ns, { combat = false })
        T.eq(ns.Duels:Count(), 0, "declined: no fight")
        H.Fire("DUEL_REQUESTED", "Dampa Lee") -- never answered, no DUEL_FINISHED
        H.Advance(ns.Duels.PENDING + 10)
        H.Fire("PLAYER_REGEN_DISABLED")
        H.Advance(15)
        H.Fire("DUEL_FINISHED")
        H.Advance(ns.Duels.RESULT_WAIT)
        T.eq(ns.Duels:Count(), 0, "a stale challenge does not turn a later fight into a duel")
        T.noErrors()
    end)

    -- In game, 2026-09-24: DUEL_FINISHED, then "Rot has defeated Dampa in a duel" with
    -- given names only; our health never read 1, so the health judgement named us wrongly
    T.case("forever: the result line after DUEL_FINISHED decides, given names matched", function()
        local ns = H.Boot({ client = "forever" })
        H.units.target = { name = "Dampa", realm = "Lee", level = 31, class = "PALADIN", race = "Human",
            faction = "Alliance", isPlayer = true, health = 900 }
        _G.StartDuel("target")
        for i = 3, 1, -1 do H.Fire("CHAT_MSG_SYSTEM", "Duel starting: " .. i) end
        H.Advance(20)
        H.Fire("DUEL_FINISHED")
        T.eq(ns.Duels:Count(), 0, "waits for the result line")
        H.Fire("CHAT_MSG_SYSTEM", "Dampa has defeated Vati in a duel")
        H.Advance(ns.Duels.RESULT_WAIT)
        T.eq(ns.Duels:Count(), 1, "one duel")
        local _, duel = next(ns.db.duels)
        T.eq(duel.winner, ns.Utils.PlayerKey("Dampa Lee"), "they won, as the line says")
        T.eq(duel.loser, ns.Utils.UnitKey("player"), "we lost")
        T.noErrors()
    end)

    T.case("forever: a witness matches given names to a single nearby player", function()
        local ns = H.Boot({ client = "forever" })
        H.units.target = { name = "Dampa", realm = "Lee", level = 31, class = "PALADIN", race = "Human",
            faction = "Alliance", isPlayer = true }
        H.units.mouseover = { name = "Rot", realm = "Ribution", level = 29, class = "WARRIOR", race = "Orc",
            faction = "Horde", isPlayer = true }
        H.Fire("CHAT_MSG_SYSTEM", "Rot has defeated Dampa in a duel")
        local _, duel = next(ns.db.duels)
        T.eq(duel and duel.winner, ns.Utils.PlayerKey("Rot Ribution"), "winner")
        T.eq(duel.loser, ns.Utils.PlayerKey("Dampa Lee"), "loser")
        H.units.target = nil
        H.serverTime = H.serverTime + 120
        H.Fire("CHAT_MSG_SYSTEM", "Rot has defeated Stranger in a duel")
        T.eq(ns.Duels:Count(), 1, "an unknown given name is not guessed")
        T.noErrors()
    end)

    T.case("a duelist seen earlier keeps class, race and sex when no longer shown", function()
        local ns = H.Boot({ client = "era" })
        H.units.mouseover = { name = "Brisa", level = 31, class = "PRIEST", race = "Dwarf", sex = 3,
            faction = "Alliance", isPlayer = true }
        H.Fire("UPDATE_MOUSEOVER_UNIT")
        H.units.mouseover = nil
        H.units.target = { name = "Someone", level = 12, class = "MAGE", race = "Gnome", faction = "Alliance", isPlayer = true }
        H.Fire("CHAT_MSG_SYSTEM", "Brisa has defeated Vati in a duel")
        local _, duel = next(ns.db.duels)
        T.eq(duel and duel.winnerClass, "PRIEST", "class remembered")
        T.eq(duel.winnerRace, "Dwarf", "race remembered")
        T.eq(duel.winnerSex, 3, "sex remembered")
        T.eq(duel.winnerLevel, 31, "level remembered")
        T.noErrors()
    end)

    T.case("at the countdown the opponent is remembered even when we target someone else", function()
        local ns = H.Boot({ client = "era" })
        H.units.nameplate3 = { name = "Brisa", level = 31, class = "PRIEST", race = "Dwarf", sex = 3,
            faction = "Alliance", isPlayer = true }
        H.units.target = { name = "Someone", level = 12, class = "MAGE", race = "Gnome", faction = "Alliance", isPlayer = true }
        ns.Duels:OnDuelRequested("Brisa")
        for i = 3, 1, -1 do H.Fire("CHAT_MSG_SYSTEM", "Duel starting: " .. i) end
        H.units.nameplate3 = nil
        H.Fire("CHAT_MSG_SYSTEM", "Brisa has defeated Vati in a duel")
        local _, duel = next(ns.db.duels)
        T.eq(duel and duel.winnerRace, "Dwarf", "opponent's race, not the target's")
        T.eq(duel.winnerSex, 3, "opponent's sex")
        T.eq(ns.HighNoon.Compute({ duel })[duel.winner].sex, 3, "High Noon shows the female icon")
        T.noErrors()
    end)

    T.case("era: the result line and our own judgement give one duel", function()
        local ns = H.Boot({ client = "era" })
        H.units.target = { name = "Bob", level = 31, class = "MAGE", race = "Gnome", faction = "Alliance",
            isPlayer = true, health = 900 }
        for i = 3, 1, -1 do H.Fire("CHAT_MSG_SYSTEM", "Duel starting: " .. i) end
        H.Advance(20)
        H.units.target.health = 1
        H.Fire("UNIT_HEALTH", "target")
        H.Fire("CHAT_MSG_SYSTEM", "Vati has defeated Bob in a duel")
        H.Fire("DUEL_FINISHED")
        H.Advance(ns.Duels.RESULT_WAIT)
        T.eq(ns.Duels:Count(), 1, "one duel")
        T.noErrors()
    end)

    T.case("High Noon starts at level 10: lower duels are not counted", function()
        local ns = H.Boot({ client = "era" })
        local D = ns.Duels
        T.ok(not D.Fair({ winnerLevel = 9, loserLevel = 12 }), "a level 9 duelist")
        T.ok(not D.Fair({ winnerLevel = 12, loserLevel = 9 }), "either side")
        T.ok(D.Fair({ winnerLevel = 10, loserLevel = 14 }), "10 and up")
        H.units.player.level = 9
        H.units.target = { name = "Bob", level = 10, class = "MAGE", race = "Gnome", faction = "Alliance", isPlayer = true }
        H.Fire("CHAT_MSG_SYSTEM", "Vati has defeated Bob in a duel")
        T.eq(D:Count(), 0, "not stored")
        T.eq(D:OnRecord(ns.Protocol.EncodeDuel({ winner = "A-Firemaw", loser = "B-Firemaw", t = H.serverTime - 60,
            faction = "Alliance", winnerLevel = 8, loserLevel = 9 }), "X-Firemaw"), nil, "peer record refused")
        T.noErrors()
    end)

    T.case("peer records must be fair too; old unfair duels are pruned", function()
        local ns = H.Boot({ client = "era" })
        local P = ns.Protocol
        local function Record(wLevel, lLevel, loser)
            return P.EncodeDuel({ winner = "Smurf-Firemaw", loser = loser, t = H.serverTime - 60,
                faction = "Alliance", winnerLevel = wLevel, loserLevel = lLevel })
        end
        T.eq(ns.Duels:OnRecord(Record(60, 20, "A-Firemaw"), "X-Firemaw"), nil, "lowbie farm")
        T.eq(ns.Duels:OnRecord(Record(nil, 20, "B-Firemaw"), "X-Firemaw"), nil, "unknown level")
        T.eq(ns.Duels:OnRecord(Record(60, 60, "C-Firemaw"), "X-Firemaw") ~= nil, true, "fair")
        T.eq(P.DecodeDuel("a;b;1;;;A;;;;"), nil, "old format without levels")

        ns.db.duels["Old>Low:1"] = { id = "Old>Low:1", winner = "Old-Firemaw", loser = "Low-Firemaw",
            t = H.serverTime - 60, faction = "Alliance" }
        ns.Duels:Prune()
        T.eq(ns.db.duels["Old>Low:1"], nil, "stored duel without levels pruned")
        T.eq(ns.Duels:Count(), 1, "fair duel kept")
        T.noErrors()
    end)

    -------------------------------------------------
    -- HH-091 records and sync
    -------------------------------------------------

    T.case("duel records from the other faction are accepted, rate limited", function()
        local ns = H.Boot({ client = "era" })
        local P = ns.Protocol
        local function Record(i)
            return P.EncodeDuel({ winner = "Grom-Firemaw", loser = "Thrall" .. i .. "-Firemaw",
                t = H.serverTime - 60, mapID = 1413, faction = "Horde", winnerClass = "WARRIOR", winnerRace = "Orc", winnerLevel = 60, loserLevel = 58 })
        end
        H.Deliver(P.Pack("H", "U", { Record(0) }), "Hordie-Firemaw")
        T.eq(ns.Duels:Count(), 1, "Horde duel accepted")
        local _, duel = next(ns.db.duels)
        T.eq(duel.faction, "Horde", "faction kept")
        T.eq(duel.winnerRace, "Orc", "race kept")

        local female = P.DecodeDuel(P.EncodeDuel({ winner = "A-Firemaw", loser = "B-Firemaw", t = 100,
            winnerRace = "Troll", winnerSex = 3, loserRace = "Orc", loserSex = 2, winnerLevel = 60, loserLevel = 60 }))
        T.eq(female.winnerRace .. female.winnerSex, "Troll3", "female: lower-case race code")
        T.eq(female.loserRace .. female.loserSex, "Orc2", "male")

        for i = 1, ns.Duels.SENDER_LIMIT + 5 do
            H.Deliver(P.Pack("H", "U", { Record(i) }), "Spammer-Firemaw")
        end
        T.eq(ns.Duels:Count(), 1 + ns.Duels.SENDER_LIMIT, "at most SENDER_LIMIT per sender")
        T.eq(ns.Duels:OnRecord(Record(99), "Spammer-Firemaw", "relay") ~= nil, true, "catch-up relays skip the limit")

        T.eq(ns.Duels:OnRecord(P.EncodeDuel({ winner = "A-Firemaw", loser = "B-Firemaw", t = H.serverTime + 3600, winnerLevel = 60, loserLevel = 60,
            faction = "Horde" }), "X-Firemaw"), nil, "from the future")
        T.eq(ns.Duels:OnRecord("garbage", "X-Firemaw"), nil, "malformed")
        T.noErrors()
    end)

    T.case("catch-up passes duels on", function()
        local ns = H.Boot({ client = "era" })
        Duels(ns, "Vati-Firemaw", "Bob-Firemaw", 2)
        local duels = 0
        for _, record in ipairs(ns.CatchUp.Records(H.serverTime - 2 * 86400)) do
            if record:sub(1, 1) == "U" then duels = duels + 1 end
        end
        T.eq(duels, 2, "duel records")
    end)

    -------------------------------------------------
    -- HH-092 rating and ranks
    -------------------------------------------------

    T.case("records: net wins decide the rank; Greenhorn is only a label", function()
        local ns = H.Boot({ client = "era" })
        local HN = ns.HighNoon
        local players = HN.Compute({ { winner = "A", loser = "B", t = 1, faction = "Alliance" } })
        T.eq(players.A.net, 1, "winner +1")
        T.eq(players.B.net, -1, "loser -1")
        T.eq(players.A.rank, "greenhorn", "under 5 duels")

        local duels = {}
        for i = 1, 10 do duels[#duels + 1] = { winner = "A", loser = "B", t = i, faction = "Alliance" } end
        duels[#duels + 1] = { winner = "B", loser = "A", t = 11, faction = "Alliance" }
        players = HN.Compute(duels)
        T.eq(players.A.wins .. "-" .. players.A.losses, "10-1", "record")
        T.eq(players.A.net, 9, "net")
        T.eq(players.A.rank, "sharpshooter", "+5 or more")
        T.eq(players.B.rank, "quickdraw", "a losing record")
        T.eq(HN.RankOf({ duels = 40, net = 30 }), "legend", "legend")
        T.eq(HN.RankOf({ duels = 20, net = 15 }), "deadeye", "deadeye")
        T.eq(HN.NetText(3) .. HN.NetText(0) .. HN.NetText(-2), "+30-2", "net text")
    end)

    T.case("best first by net, then fewer losses: 1-0 beats 1-4", function()
        local HN = H.Boot({ client = "era" }).HighNoon
        local list = {
            { key = "Grinder", wins = 30, losses = 40, net = -10 },
            { key = "Lucky", wins = 1, losses = 0, net = 1 },
            { key = "Unlucky", wins = 1, losses = 4, net = -3 },
            { key = "Even", wins = 10, losses = 9, net = 1 },
            { key = "Solid", wins = 6, losses = 0, net = 6 },
        }
        table.sort(list, HN.Better)
        local order = {}
        for _, p in ipairs(list) do order[#order + 1] = p.key end
        T.eq(table.concat(order, " "), "Solid Lucky Even Unlucky Grinder", "order")
    end)

    T.case("two lists, best first, from the first duel; the #1 with a winning record is the Top Gun", function()
        local ns = H.Boot({ client = "era" })
        Duels(ns, "Vati-Firemaw", "Bob-Firemaw", 6)
        Duels(ns, "Bob-Firemaw", "Cid-Firemaw", 5, "Alliance", 10000)
        Duels(ns, "Grom-Firemaw", "Orcy-Firemaw", 5, "Horde", 20000)
        Duels(ns, "New-Firemaw", "Bob-Firemaw", 1, "Alliance", 30000)
        Settle()
        local HN = ns.HighNoon
        local alliance = HN:List("Alliance")
        T.eq(#alliance, 4, "Alliance: Vati, Bob, Cid and New (one duel is enough)")
        T.eq(alliance[1].key, "Vati-Firemaw", "best first (+6)")
        T.eq(alliance[1].topGun, true, "Top Gun")
        T.eq(alliance[2].key, "New-Firemaw", "1-0 comes before losing records")
        T.eq(alliance[2].position, 2, "position")
        T.eq(#HN:List("Horde"), 2, "Horde list")
        T.eq(HN:List("Horde")[1].key, "Grom-Firemaw", "Horde Top Gun")
        T.ok(HN.Title(HN:Get("Vati-Firemaw")):find("Top Gun", 1, true) ~= nil, "Top Gun title")
        T.ok(HN.Title(HN:Get("Vati-Firemaw")):find("+6", 1, true) ~= nil, "net in the title")
        T.ok(HN.Title(HN:Get("Cid-Firemaw")):find("#" .. HN:Get("Cid-Firemaw").position, 1, true) ~= nil, "title with position")
        T.eq(HN:Get("New-Firemaw").topGun, nil, "only the #1 is the Top Gun")
        T.eq(HN.Title(HN:Get("New-Firemaw")), "Greenhorn (1 duels)", "greenhorn title")

        H.Slash("duels")
        T.ok(H.Printed("Duels, Alliance: 4 duelists"), "/hh duels header")
        T.ok(H.Printed("You: .*Top Gun"), "/hh duels: where we stand")
        T.noErrors()
    end)

    T.case("the same record shares a place; a shared #1 is no Top Gun", function()
        local ns = H.Boot({ client = "era" })
        Duels(ns, "Argo-Firemaw", "Chad-Firemaw", 1, "Horde")
        Duels(ns, "Heavy-Firemaw", "Alex-Firemaw", 1, "Horde", 10000)
        Duels(ns, "Mornin-Firemaw", "Dampa-Firemaw", 1, "Horde", 20000)
        Settle()
        local list = ns.HighNoon:List("Horde")
        T.eq(list[1].position .. list[2].position .. list[3].position, "111", "three 1-0 share #1")
        T.eq(list[4].position, 4, "the next record is #4")
        for _, p in ipairs(list) do T.eq(p.topGun, nil, p.key .. " is no Top Gun") end

        Duels(ns, "Heavy-Firemaw", "Chad-Firemaw", 1, "Horde", 30000)
        Settle()
        list = ns.HighNoon:List("Horde")
        T.eq(list[1].key, "Heavy-Firemaw", "2-0 pulls ahead")
        T.eq(list[1].topGun, true, "the sole leader is the Top Gun")
        T.eq(list[2].position, 2, "the 1-0s share #2")
        T.noErrors()
    end)

    T.case("no Top Gun without a winning record", function()
        local ns = H.Boot({ client = "era" })
        Duels(ns, "Vati-Firemaw", "Bob-Firemaw", 1)
        Duels(ns, "Bob-Firemaw", "Vati-Firemaw", 1, "Alliance", 10000)
        Settle()
        local list = ns.HighNoon:List("Alliance")
        T.eq(list[1].net, 0, "even")
        T.eq(list[1].topGun, nil, "no Top Gun at 1-1")
        T.noErrors()
    end)

    T.case("/hh debug duels 1: no Greenhorn after one duel; off restores 5", function()
        local ns = H.Boot({ client = "era" })
        Duels(ns, "Vati-Firemaw", "Bob-Firemaw", 1)
        Settle()
        T.eq(#ns.HighNoon:List("Alliance"), 2, "listed after one duel")
        T.eq(ns.HighNoon:Get("Bob-Firemaw").rank, "greenhorn", "a Greenhorn")
        H.Slash("debug duels 1")
        T.eq(#ns.HighNoon:List("Alliance"), 2, "listed after one duel")
        T.eq(ns.HighNoon:Get("Bob-Firemaw").rank, "quickdraw", "no Greenhorn")
        T.ok(H.Printed("Greenhorn below 1 duel"), "said so")
        H.Slash("debug duels 9")
        T.ok(H.Printed("Usage: /hh debug duels"), "usage")
        H.Slash("debug duels off")
        T.eq(ns.HighNoon:Get("Bob-Firemaw").rank, "greenhorn", "back to 5")
        T.noErrors()
    end)

    -------------------------------------------------
    -- HH-093 tab and tooltip
    -------------------------------------------------

    T.case("High Noon tab: our faction's list, the switch shows the other", function()
        local ns = H.Boot({ client = "era" })
        Duels(ns, "Vati-Firemaw", "Bob-Firemaw", 5)
        Duels(ns, "Grom-Firemaw", "Orcy-Firemaw", 5, "Horde", 20000)
        Settle()
        local MW = ns.MainWindow
        local rows = MW.Rows("duels", nil, nil, "Alliance")
        T.eq(#rows, 2, "Alliance rows")
        T.eq(rows[1].position, "1", "position")
        T.ok(rows[1].name:find("Vati", 1, true) ~= nil, "name")
        T.ok(rows[1].rank:find("Top Gun", 1, true) ~= nil, "Top Gun")
        T.eq(rows[1].record, "5-0", "won-lost")
        T.eq(rows[2].rank, "Quickdraw", "rank name")
        T.ok(#rows[1].tooltip >= 2, "tooltip")

        T.eq(MW:DuelFaction(), "Alliance", "our faction first")
        MW:Toggle()
        MW:SelectTab("duels")
        T.eq(#MW.shownRows, 2, "shown")
        MW:SwitchFaction()
        T.eq(MW:DuelFaction(), "Horde", "switched")
        T.eq(MW.shownRows[1].name:find("Grom", 1, true) ~= nil, true, "Horde list shown")
        T.noErrors()
    end)

    T.case("tooltip: any player with duels gets a High Noon line", function()
        local ns = H.Boot({ client = "era", tooltip = "script" })
        Duels(ns, "Bob-Firemaw", "Cid-Firemaw", 5)
        Settle()
        H.units.mouseover = { name = "Bob", level = 40, class = "MAGE", race = "Gnome", faction = "Alliance",
            isPlayer = true, guid = "Player-1-0000B0B" }
        H.ShowUnitTooltip("mouseover", 2)
        T.eq(#H.tooltipLines, 1, "one line")
        T.ok(H.tooltipLines[1]:find("Duels:", 1, true) ~= nil, "Duels line")
        T.ok(H.tooltipLines[1]:find("Top Gun", 1, true) ~= nil, "title")

        H.units.mouseover = { name = "Nobody", level = 40, class = "MAGE", race = "Gnome", faction = "Alliance",
            isPlayer = true, guid = "Player-1-0000C0C" }
        H.ShowUnitTooltip("mouseover")
        T.eq(#H.tooltipLines, 0, "no duels, no line")
        T.noErrors()
    end)
end
