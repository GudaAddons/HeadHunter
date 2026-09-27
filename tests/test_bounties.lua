-- HH-118: player bounties. A killed player posts a gold bounty on their killer; the
-- killing blow of a HeadHunter claims it and the owner pays by mail.

return function(T, H)
    local serial = 0

    local function Settle()
        H.Advance(1)
        for _ = 1, 10 do H.Advance(0) end
        H.Advance(0.5)
        for _ = 1, 3 do H.Advance(0) end
    end

    local function Sent(pattern, chatType)
        local found = {}
        for _, m in ipairs(H.sent) do
            if m.message:find(pattern) and (not chatType or m.chatType == chatType) then found[#found + 1] = m end
        end
        return found
    end

    -- `killer` killed `victim` `ago` seconds ago; our own death when victim is us
    local function Death(ns, victim, killer, ago, killerLevel)
        serial = serial + 1
        local t = H.serverTime - (ago or 60) - serial
        local report = { id = victim .. ":" .. t, t = t, victim = { key = victim, level = 30 },
            killer = { key = killer, name = killer, level = killerLevel or 32, class = "ROGUE", race = "Orc" },
            assists = {}, mapID = 1436, x = 0.5, y = 0.5, confidence = "exact" }
        if victim == "Vati-Firemaw" then
            ns.db.deaths[#ns.db.deaths + 1] = report
            ns.Reports:Add(report, "local")
        else
            ns.Reports:Add(report, "peer", victim)
        end
        return report
    end

    -- A peer's poster on `target`, delivered from the owner
    local function PeerPoster(ns, owner, target, goldG, opts)
        opts = opts or {}
        local t = opts.t or H.serverTime - 30
        local record = ns.Protocol.EncodePoster({ owner = owner, target = target, reason = opts.reason or 1,
            gold = goldG * 10000, ["until"] = t + (opts.days or 3) * 86400, t = t })
        H.Deliver(ns.Protocol.Pack("A", "W", { record }), opts.sender or owner)
        return owner .. ":" .. t
    end

    local function PeerPayment(ns, posterId, hunter, status, claimedAt, sender)
        local record = ns.Protocol.EncodePayment({ posterId = posterId, hunter = hunter, status = status,
            claimedAt = claimedAt or H.serverTime - 20, t = H.serverTime })
        H.Deliver(ns.Protocol.Pack("A", "R", { record }), sender or hunter)
    end

    -- PARTY_KILL of `victimName` by `sourceName` (us unless given)
    local function PartyKill(victimName, sourceName)
        H.FireCLEU(H.serverTime, "PARTY_KILL", false, "Player-1-00000001", sourceName or "Vati",
            H.FLAGS_FRIENDLY_PLAYER, 0, "Player-2-0000BEEF", victimName, H.FLAGS_HOSTILE_PLAYER, 0)
    end

    local function Popup(which)
        for i = #H.popups, 1, -1 do
            if H.popups[i].which == which then return H.popups[i] end
        end
        return nil
    end

    -------------------------------------------------
    -- Wire format
    -------------------------------------------------

    T.case("protocol: poster and payment round trip, malformed ones refused", function()
        local P = H.Boot({ client = "era" }).Protocol
        local poster = P.DecodePoster(P.EncodePoster({ owner = "Tallon-Firemaw", target = "Grim-Stonespine", reason = 2,
            gold = 200000, ["until"] = 1790259200, t = 1790000000 }))
        T.eq(poster.owner .. "|" .. poster.target, "Tallon-Firemaw|Grim-Stonespine", "names")
        T.eq(poster.reason, 2, "reason")
        T.eq(poster.gold, 200000, "gold in copper")
        T.eq(poster["until"] - poster.t, 259200, "3 days")
        local pay = P.DecodePayment(P.EncodePayment({ posterId = "Tallon-Firemaw:1790000000", hunter = "Kestrel-Firemaw",
            status = "paid", claimedAt = 1790000100, t = 1790000200 }))
        T.eq(pay.posterId, "Tallon-Firemaw:1790000000", "poster id with its colon")
        T.eq(pay.status, "paid", "status")
        T.eq(pay.claimedAt, 1790000100, "claim time")
        T.eq(P.DecodePoster("a;b;1"), nil, "short poster")
        T.eq(P.DecodePayment("x;y;z;1;2"), nil, "unknown status")
    end)

    -------------------------------------------------
    -- Posting
    -------------------------------------------------

    T.case("only our own killer from the last 24 hours; posted and sent, realm-wide on Era", function()
        local ns = H.Boot({ client = "era" })
        H.inGuild = true
        Death(ns, "Vati-Firemaw", "Grim-Stonespine", 600)
        Death(ns, "Vati-Firemaw", "Old-Stonespine", 2 * 86400)
        Death(ns, "Tallon-Firemaw", "Other-Stonespine", 60)
        Settle()
        local B = ns.Bounties
        T.eq(B:CanPost("Grim-Stonespine"), true, "our killer")
        T.eq(select(2, B:CanPost("Old-Stonespine")), "notkiller", "killed us 2 days ago")
        T.eq(select(2, B:CanPost("Other-Stonespine")), "notkiller", "killed someone else")

        local poster, why = B:Post("Grim-Stonespine", 1, 4, 3)
        T.eq(poster, nil, "under 5g")
        T.eq(why, "gold", "reason")
        T.eq(select(2, B:Post("Grim-Stonespine", 1, 20, 5)), "days", "1, 2, 3 or 7 days")

        T.ok(ns.BountyDialog:Open("Grim-Stonespine"), "the dialog opens")
        ns.BountyDialog.values.gold = 20
        ns.BountyDialog.values.reason = 1
        ns.BountyDialog.values.days = 3
        poster = ns.BountyDialog:Submit()
        T.ok(poster ~= nil, "posted")
        T.eq(poster.gold, 200000, "20g")
        T.eq(poster["until"] - poster.t, 3 * 86400, "3 days")
        T.ok(H.Printed("Bounty posted: 20g on"), "said so")
        T.ok(#H.chatSent == 1 and H.chatSent[1].text:find("^HH1:1AW:") ~= nil, "realm-wide with the click")
        H.Advance(3)
        T.eq(#Sent("^1AW:", "GUILD"), 1, "and to the guild")

        T.eq(select(2, B:CanPost("Grim-Stonespine")), "active", "one poster at a time")
        T.ok(not ns.BountyDialog:Open("Grim-Stonespine"), "no dialog then")
        T.ok(H.Printed("already have a bounty running"), "told why")
        T.noErrors()
    end)

    T.case("a peer's poster: only from the owner, only on their killer, one at a time", function()
        local ns = H.Boot({ client = "era" })
        Death(ns, "Tallon-Firemaw", "Grim-Stonespine", 600)
        Death(ns, "Tallon-Firemaw", "Moo-Stonespine", 300)
        Settle()
        local B = ns.Bounties
        PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20, { sender = "Faker-Firemaw" })
        T.eq(B:Summary("Grim-Stonespine"), nil, "not sent by the owner")
        PeerPoster(ns, "Tallon-Firemaw", "Innocent-Stonespine", 20)
        T.eq(B:Summary("Innocent-Stonespine"), nil, "never killed the owner")
        PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 3)
        T.eq(B:Summary("Grim-Stonespine"), nil, "under 5g")
        PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20, { days = 9 })
        T.eq(B:Summary("Grim-Stonespine"), nil, "more than 7 days")

        PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20)
        T.eq(B:Summary("Grim-Stonespine").gold, 200000, "accepted")
        PeerPoster(ns, "Tallon-Firemaw", "Moo-Stonespine", 20, { t = H.serverTime - 10 })
        T.eq(B:Summary("Moo-Stonespine"), nil, "a second poster within 30 min")
        T.noErrors()
    end)

    T.case("several posters on one target are one row and one line; tooltip and WANTED tab", function()
        local ns = H.Boot({ client = "era", tooltip = "script" })
        Death(ns, "Tallon-Firemaw", "Grim-Stonespine", 600)
        Death(ns, "Rowena-Firemaw", "Grim-Stonespine", 500)
        Settle()
        PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20, { t = H.serverTime - 100 })
        T.eq(ns.Bounties:Line("Grim-Stonespine"), "|cffffd100Bounty:|r 20g by Tallon · Camped me", "one poster")
        PeerPoster(ns, "Rowena-Firemaw", "Grim-Stonespine", 25, { reason = 3 })
        local summary = ns.Bounties:Summary("Grim-Stonespine")
        T.eq(summary.count, 2, "two posters")
        T.eq(summary.gold, 450000, "45g together")
        T.eq(ns.Bounties:Line("Grim-Stonespine"), "|cffffd100Bounty:|r 2 posters · 45g", "merged line")

        local rows = ns.MainWindow.Rows("wanted", "rank", nil, "Horde")
        T.eq(rows[1].bounty, true, "on top of the WANTED tab")
        T.ok(rows[1].rank:find("45g", 1, true) ~= nil, "the reward summed")
        T.eq(rows[1].id, "Grim-Stonespine", "opens the poster")

        H.units.target = { name = "Grim", realm = "Stonespine", level = 32, class = "ROGUE", race = "Orc",
            guid = "Player-2-0000BEEF", faction = "Horde", isPlayer = true }
        H.ShowUnitTooltip("target")
        local found = false
        for _, line in ipairs(H.tooltipLines) do
            if line:find("2 posters", 1, true) then found = true end
        end
        T.ok(found, "tooltip line")
        T.ok(ns.Poster.Content("Grim-Stonespine").bounty:find("45g", 1, true) ~= nil, "poster line")
        T.noErrors()
    end)

    T.case("meeting a posted target: the sighting alert, no popup", function()
        local ns = H.Boot({ client = "era" })
        Death(ns, "Tallon-Firemaw", "Grim-Stonespine", 600)
        Settle()
        PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20)
        local popups = #H.popups
        ns.Sighting:OnEnemySeen({ key = "Grim-Stonespine", level = 32, class = "ROGUE", race = "Orc" }, "target")
        local seen = false
        for _, text in ipairs(H.centerTexts) do
            if text:find("BOUNTY", 1, true) and text:find("Grim", 1, true) then seen = true end
        end
        T.ok(seen, "center text")
        T.ok(H.Printed("Bounty:.*20g by Tallon"), "chat line with the bounty")
        T.eq(#H.popups, popups, "no new popup")
        T.noErrors()
    end)

    T.case("forever: names without a realm; a peer's poster and our claim", function()
        local ns = H.Boot({ client = "forever" })
        H.inGuild = true
        local t = H.serverTime - 600
        ns.Reports:Add({ id = "Tallon Brook:" .. t, t = t, victim = { key = "Tallon Brook", level = 20 },
            killer = { key = "Grim Reaper", name = "Grim Reaper", level = 28, class = "ROGUE", race = "Orc" },
            assists = {}, mapID = 1436, confidence = "exact" }, "peer", "Tallon Brook")
        Settle()
        local posterId = PeerPoster(ns, "Tallon Brook", "Grim Reaper", 10, { sender = "TallonBrook-Realm" })
        T.eq(ns.Bounties:Summary("Grim Reaper").gold, 100000, "accepted from the owner's other name shape")
        T.eq(ns.Bounties:CanPost("Grim Reaper"), false, "we were not killed by them")
        ns.Justice:Add({ id = "Grim Reaper:" .. H.serverTime, outlaw = "Grim Reaper", t = H.serverTime,
            killer = "Vati Guda", hunter = "Vati Guda" }, "local")
        T.eq(ns.Bounties:Payment(posterId).hunter, "Vati Guda", "claimed by us")
        T.noErrors()
    end)

    -------------------------------------------------
    -- Claiming
    -------------------------------------------------

    T.case("our killing blow claims it: claim sent, poster closed, +5 bounty points", function()
        local ns = H.Boot({ client = "era" })
        H.inGuild = true
        Death(ns, "Tallon-Firemaw", "Grim-Stonespine", 600)
        Settle()
        local posterId = PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20)
        T.eq(ns.Wanted:ByKey("Grim-Stonespine").wanted, false, "not WANTED, only posted")

        PartyKill("Grim-Stonespine")
        Settle()
        local pay = ns.Bounties:Payment(posterId)
        T.ok(pay ~= nil and pay.status == "claimed", "claimed")
        T.eq(pay.hunter, "Vati-Firemaw", "by us")
        T.ok(H.Printed("Bounty claimed:.*20g from Tallon, it comes by mail"), "chat line")
        T.eq(ns.Bounties:Summary("Grim-Stonespine"), nil, "the poster is closed")
        T.eq(ns.Marks:Total(), 5, "+5 bounty points")
        H.Advance(3)
        T.eq(#Sent("^1AR:"), 1, "claim shared")
        T.noErrors()
    end)

    T.case("a group member's killing blow: they claim, we get the points; no claim hunting down", function()
        local ns = H.Boot({ client = "era" })
        Death(ns, "Tallon-Firemaw", "Grim-Stonespine", 600)
        Death(ns, "Rowena-Firemaw", "Tiny-Stonespine", 500, 15)
        Settle()
        local posterId = PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20)
        PartyKill("Grim-Stonespine", "Buddy")
        Settle()
        T.eq(ns.Bounties:Payment(posterId), nil, "no claim from us")
        T.eq(ns.Marks:Total(), 5, "but the bounty points")

        local tiny = PeerPoster(ns, "Rowena-Firemaw", "Tiny-Stonespine", 20)
        PartyKill("Tiny-Stonespine")
        Settle()
        T.eq(ns.Bounties:Payment(tiny), nil, "15 levels below us: no claim")
        T.ok(H.Printed("No bounty: Tiny.*10%+ levels below you"), "told why")
        T.noErrors()
    end)

    -------------------------------------------------
    -- Paying
    -------------------------------------------------

    T.case("the owner at the mailbox: one click sends the posted gold to the hunter", function()
        local ns = H.Boot({ client = "era" })
        Death(ns, "Vati-Firemaw", "Grim-Stonespine", 600)
        Settle()
        local poster = ns.Bounties:Post("Grim-Stonespine", 1, 20, 3)
        PeerPayment(ns, poster.id, "Kestrel-Firemaw", "claimed", H.serverTime)
        T.eq(ns.Bounties:Payment(poster.id).hunter, "Kestrel-Firemaw", "claim arrived")

        local mail = {}
        _G.GetMoney = function() return 1000000 end
        _G.SetSendMailMoney = function(copper) mail.money = copper return true end
        _G.SendMail = function(to, subject, body) mail.to, mail.subject, mail.body = to, subject, body end
        H.Fire("MAIL_SHOW")
        local popup = Popup(ns.Bounties.PAY_POPUP)
        T.ok(popup ~= nil and popup.text:find("Kestrel brought down Grim", 1, true) ~= nil, "asked")
        T.ok(popup.text:find("Send 20g?", 1, true) ~= nil, "the amount")
        _G.StaticPopupDialogs[ns.Bounties.PAY_POPUP].OnAccept()
        T.eq(mail.money, 200000, "exactly the posted gold")
        T.eq(mail.to, "Kestrel", "to the hunter")
        T.eq(mail.subject, "HeadHunter bounty: Grim-Stonespine", "bounty subject")
        T.ok(poster.sentAt ~= nil, "remembered")

        H.Fire("MAIL_SHOW")
        T.eq(#ns.Bounties:ToPay(), 0, "not asked again")
        _G.GetMoney, _G.SetSendMailMoney, _G.SendMail = nil, nil, nil
        T.noErrors()
    end)

    T.case("[Later] or too little gold asks again at the next mailbox", function()
        local ns = H.Boot({ client = "era" })
        Death(ns, "Vati-Firemaw", "Grim-Stonespine", 600)
        Settle()
        local poster = ns.Bounties:Post("Grim-Stonespine", 1, 20, 3)
        PeerPayment(ns, poster.id, "Kestrel-Firemaw", "claimed", H.serverTime)
        local sent = false
        _G.GetMoney = function() return 50000 end
        _G.SetSendMailMoney = function() return true end
        _G.SendMail = function() sent = true end
        H.Fire("MAIL_SHOW")
        _G.StaticPopupDialogs[ns.Bounties.PAY_POPUP].OnAccept()
        T.ok(not sent, "no mail without the gold")
        T.ok(H.Printed("Not enough gold"), "told why")
        H.Fire("MAIL_SHOW")
        _G.StaticPopupDialogs[ns.Bounties.PAY_POPUP].OnCancel()
        T.eq(#ns.Bounties:ToPay(), 1, "still to pay")
        _G.GetMoney, _G.SetSendMailMoney, _G.SendMail = nil, nil, nil
        T.noErrors()
    end)

    T.case("the hunter's inbox shows the gold: paid, shared, the owner pays up", function()
        local ns = H.Boot({ client = "era" })
        H.inGuild = true
        Death(ns, "Tallon-Firemaw", "Grim-Stonespine", 600)
        Settle()
        local posterId = PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20)
        PartyKill("Grim-Stonespine")
        Settle()
        local inbox = { { "Tallon", "HeadHunter bounty: Grim-Stonespine", 100000 } }
        _G.GetInboxNumItems = function() return #inbox end
        _G.GetInboxHeaderInfo = function(i) return nil, nil, inbox[i][1], inbox[i][2], inbox[i][3] end
        H.Fire("MAIL_INBOX_UPDATE")
        T.eq(ns.Bounties:Payment(posterId).status, "claimed", "10g is not the 20g posted")
        inbox[1][3] = 200000
        H.Fire("MAIL_INBOX_UPDATE")
        T.eq(ns.Bounties:Payment(posterId).status, "paid", "paid")
        T.ok(H.Printed("Tallon paid the 20g bounty"), "chat line")
        T.eq(ns.Bounties:StandingText("Tallon-Firemaw"), " · |cff40ff40pays up|r", "pays up")
        H.Advance(3)
        T.ok(#Sent("^1AR:.*;p;") >= 1, "paid shared")
        _G.GetInboxNumItems, _G.GetInboxHeaderInfo = nil, nil
        T.noErrors()
    end)

    T.case("3 days without the gold: unpaid; 2 hunters unpaid blocks the owner", function()
        local ns = H.Boot({ client = "era" })
        Death(ns, "Tallon-Firemaw", "Grim-Stonespine", 600)
        Settle()
        local first = PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20)
        PartyKill("Grim-Stonespine")
        Settle()
        H.serverTime = H.serverTime + 3 * 86400 + 60
        ns.Bounties:CheckUnpaid()
        T.eq(ns.Bounties:Payment(first).status, "unpaid", "unpaid after 3 days")
        T.eq(ns.Bounties:StandingText("Tallon-Firemaw"), " · |cffff4040" .. "1 unpaid|r", "a warning")
        T.eq(ns.Bounties:IsBlocked("Tallon-Firemaw"), false, "one hunter: not blocked")

        Death(ns, "Tallon-Firemaw", "Moo-Stonespine", 600)
        local second = PeerPoster(ns, "Tallon-Firemaw", "Moo-Stonespine", 20)
        T.ok(ns.Bounties:Get(second) ~= nil, "a new poster after the first was claimed")
        PeerPayment(ns, second, "Kestrel-Firemaw", "unpaid", H.serverTime - 10)
        T.eq(ns.Bounties:IsBlocked("Tallon-Firemaw"), true, "two hunters unpaid: blocked")

        H.serverTime = H.serverTime + 3600
        Death(ns, "Tallon-Firemaw", "Hoof-Stonespine", 600)
        PeerPoster(ns, "Tallon-Firemaw", "Hoof-Stonespine", 20)
        T.eq(ns.Bounties:Summary("Hoof-Stonespine"), nil, "a blocked owner's poster is ignored")

        PeerPayment(ns, second, "Kestrel-Firemaw", "paid", H.serverTime - 3610)
        T.eq(ns.Bounties:IsBlocked("Tallon-Firemaw"), false, "a late payment lifts it")
        T.noErrors()
    end)

    T.case("payments only from the hunter; nobody claims their own bounty", function()
        local ns = H.Boot({ client = "era" })
        Death(ns, "Tallon-Firemaw", "Grim-Stonespine", 600)
        Settle()
        local posterId = PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20)
        PeerPayment(ns, posterId, "Kestrel-Firemaw", "unpaid", nil, "Faker-Firemaw")
        T.eq(ns.Bounties:Payment(posterId), nil, "not from the hunter")
        PeerPayment(ns, posterId, "Tallon-Firemaw", "claimed")
        T.eq(ns.Bounties:Payment(posterId), nil, "the owner cannot claim")
        T.noErrors()
    end)

    T.case("catch-up passes posters and payments on", function()
        local ns = H.Boot({ client = "era" })
        Death(ns, "Tallon-Firemaw", "Grim-Stonespine", 600)
        Settle()
        local posterId = PeerPoster(ns, "Tallon-Firemaw", "Grim-Stonespine", 20)
        PeerPayment(ns, posterId, "Kestrel-Firemaw", "claimed")
        local records = ns.CatchUp.Records(0)
        local kinds = {}
        for _, record in ipairs(records) do kinds[record:sub(1, 1)] = (kinds[record:sub(1, 1)] or 0) + 1 end
        T.eq(kinds.W, 1, "the poster")
        T.eq(kinds.R, 1, "the claim")

        local fresh = H.Boot({ client = "era" })
        for _, record in ipairs(records) do
            if record:sub(1, 1) == "W" then fresh.Bounties:AddRelayedPoster(record:sub(2), "Helper-Firemaw") end
            if record:sub(1, 1) == "R" then fresh.Bounties:AddRelayedPayment(record:sub(2)) end
        end
        T.ok(fresh.Bounties:Get(posterId) ~= nil, "poster relayed")
        T.eq(fresh.Bounties:Payment(posterId).status, "claimed", "claim relayed")
        T.noErrors()
    end)
end
