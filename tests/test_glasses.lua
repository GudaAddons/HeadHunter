-- Raise a glass to a catch (Sync/Glasses.lua): any HeadHunter, one per catch, never to
-- their own, shared with the others, and the website's count when it is larger.
-- Made-up players only.

return function(T, H)
    local function Wait(seconds)
        for _ = 1, seconds do H.Advance(1) end
    end

    -- A catch of Grim Reaper by `hunter` (another HeadHunter by default)
    local function Catch(ns, hunter)
        local t = H.serverTime - 60
        return ns.Justice:Add({ id = "Grim Reaper:" .. t, outlaw = "Grim Reaper", t = t, mapID = 1436,
            killer = hunter or "Kestrel Vane", hunter = hunter or "Kestrel Vane" }, "peer", hunter or "Kestrel Vane")
    end

    local function Sent()
        local found = 0
        for _, m in ipairs(H.sent) do
            if m.message:find("Y:", 1, true) or m.message:find("|Y|", 1, true) then found = found + 1 end
        end
        return found
    end

    T.case("we raise a glass once, it is shared, and the count shows", function()
        local ns = H.Boot({ client = "forever" })
        local catch = Catch(ns)
        T.eq(ns.Glasses:CanRaise(catch), true, "another hunter's catch")
        H.sent = {}
        T.ok(ns.Glasses:Raise(catch) ~= nil, "raised")
        Wait(10)
        T.ok(#H.sent > 0, "sent to the others")
        T.eq(ns.Glasses:Count(catch), 1, "one glass")
        T.eq(ns.Glasses:CanRaise(catch), false, "once per catch")
        T.eq(ns.Glasses:Raise(catch), nil, "not twice")
        T.noErrors()
    end)

    T.case("never to our own catch", function()
        local ns = H.Boot({ client = "forever" })
        local catch = Catch(ns, ns.Utils.UnitKey("player"))
        T.eq(ns.Glasses:CanRaise(catch), false, "our own catch")
        T.eq(ns.Glasses:Raise(catch), nil, "not raised")
        T.noErrors()
    end)

    T.case("peers: only for themselves, never to their own catch, under a limit", function()
        local ns = H.Boot({ client = "forever" })
        local P = ns.Protocol
        local catch = Catch(ns)
        local function Glass(by, sender)
            H.Deliver(P.Pack("A", P.TYPES.GLASS, { P.EncodeGlass({ outlaw = "Grim Reaper", caughtAt = catch.t,
                t = H.serverTime, by = by }) }), sender or by)
        end
        Glass("Rowan Ash")
        T.eq(ns.Glasses:Count(catch), 1, "a peer's glass")
        Glass("Rowan Ash")
        T.eq(ns.Glasses:Count(catch), 1, "one per HeadHunter")
        Glass("Other Name", "Rowan Ash")
        T.eq(ns.Glasses:Count(catch), 1, "nobody raises one for someone else")
        Glass("Kestrel Vane")
        T.eq(ns.Glasses:Count(catch), 1, "the hunter never to their own catch")
        T.eq(select(2, ns.Glasses:Of(catch)), false, "not ours")
        T.eq(ns.Glasses:CanRaise(catch), true, "we still can")
        T.noErrors()
    end)

    T.case("the website's count when it is larger", function()
        local ns = H.Boot({ client = "forever" })
        local catch = Catch(ns)
        ns.Glasses:Raise(catch)
        local site = ns.SiteData.Glasses
        ns.SiteData.Glasses = function() return 7 end
        T.eq(ns.Glasses:Count(catch), 7, "the website knows more")
        ns.SiteData.Glasses = site
        T.eq(ns.Glasses:Count(catch), 1, "ours without it")
        T.noErrors()
    end)

    T.case("the Busted list: a mug with the count, raised with a click", function()
        local ns = H.Boot({ client = "forever" })
        Catch(ns)
        local glass = ns.MainWindow.Rows("busted")[1].actions[1]
        T.eq(glass.kind, "glass", "the mug")
        T.eq(glass.count, 0, "no glasses yet")
        T.eq(glass.canRaise, true, "we may raise one")
        T.eq(glass.raised, false, "not raised")
        T.ok(ns.MainWindow.Rows("busted")[1].tooltip[3]:find("click the mug to raise a glass", 1, true) ~= nil,
            "the row says how to raise one")
        ns.MainWindow:OnRowAction(nil, glass)
        local row = ns.MainWindow.Rows("busted")[1]
        T.eq(row.actions[1].count, 1, "raised")
        T.eq(row.actions[1].raised, true, "ours")
        T.eq(row.actions[1].canRaise, false, "once")
        T.ok(row.tooltip[3]:find("Glasses raised: 1", 1, true) ~= nil, "tooltip: " .. row.tooltip[3])

        -- Drawn: the mug button, no text button
        H.Slash("")
        ns.MainWindow:SelectSection("busted")
        local drawn = ns.MainWindow.shownRows and ns.MainWindow.shownRows[1]
        T.ok(drawn ~= nil, "a row drawn")
        T.noErrors()
    end)
end
