-- HH-110: HeadHunters online (Sync/Presence.lua). Made-up players only.

return function(T, H)
    local function Here(ns, faction, version)
        return ns.Protocol.Pack(faction, ns.Protocol.TYPES.PRESENCE, { version or "0.1.7" })
    end

    local function SentPresence(ns)
        local found = 0
        for _, m in ipairs(H.sent) do
            if m.message:find("^%d%a" .. ns.Protocol.TYPES.PRESENCE .. ":") then found = found + 1 end
        end
        return found
    end

    T.case("you alone count as one, on your faction", function()
        local ns = H.Boot({ client = "forever" })
        local count = ns.Presence:Count()
        T.eq(count.total, 1, "you")
        T.eq(count.Alliance, 1, "your faction")
        T.eq(count.Horde, 0, "other faction")
        T.eq(count.scope, "region", "Forever reaches the region")
        T.noErrors()
    end)

    T.case("players heard on Forever count per faction, the other faction too", function()
        local ns = H.Boot({ client = "forever" })
        H.Deliver(Here(ns, "A"), "Iron Maple")
        H.Deliver(Here(ns, "H", "0.1.6"), "Grim Tusk")
        H.Deliver(Here(ns, "A"), "Iron Maple") -- the same player twice
        local count = ns.Presence:Count()
        T.eq(count.total, 3, "you and two others")
        T.eq(count.Alliance, 2, "Alliance")
        T.eq(count.Horde, 1, "Horde")
        T.eq(ns.Presence:Versions()["0.1.6"], 1, "their version")
        T.noErrors()
    end)

    T.case("any message shows its sender is online, not only presence", function()
        local ns = H.Boot({ client = "forever" })
        H.Deliver(ns.Protocol.Pack("H", ns.Protocol.TYPES.PING, { "hello" }), "Grim Tusk")
        T.eq(ns.Presence:Count().Horde, 1, "a ping from the other faction counts")
        T.noErrors()
    end)

    T.case("players not heard within the window drop out", function()
        local ns = H.Boot({ client = "forever" })
        H.Deliver(Here(ns, "A"), "Iron Maple")
        H.Advance(ns.Presence.WINDOW - 60)
        T.eq(ns.Presence:Count().total, 2, "still online")
        H.Advance(120)
        T.eq(ns.Presence:Count().total, 1, "gone")
        T.noErrors()
    end)

    T.case("we say here after login and answer a newcomer once", function()
        local ns = H.Boot({ client = "forever" })
        H.Advance(ns.Presence.FIRST_DELAY)
        H.Advance(ns.Transport.FLUSH_INTERVAL)
        T.eq(SentPresence(ns), 1, "here after login")

        H.Deliver(Here(ns, "A"), "Iron Maple")
        H.Advance(ns.Presence.ANSWER_DELAY)
        H.Advance(ns.Transport.FLUSH_INTERVAL)
        T.eq(SentPresence(ns), 2, "answered the newcomer")

        H.Deliver(Here(ns, "H"), "Grim Tusk")
        H.Advance(ns.Presence.ANSWER_DELAY)
        H.Advance(ns.Transport.FLUSH_INTERVAL)
        T.eq(SentPresence(ns), 2, "no second answer within the cooldown")
        T.noErrors()
    end)

    T.case("the repeat waits while we broadcast anything else", function()
        local ns = H.Boot({ client = "forever" })
        local now = ns.Utils.Now()
        ns.Transport.lastBroadcastAt = nil
        T.ok(ns.Presence.RepeatNeeded(now), "nothing sent: repeat")
        ns.Transport.lastBroadcastAt = now - 60
        T.ok(not ns.Presence.RepeatNeeded(now), "sent a minute ago: wait")
        ns.Transport.lastBroadcastAt = now - ns.Presence.INTERVAL
        T.ok(ns.Presence.RepeatNeeded(now), "sent an interval ago: repeat")
        T.noErrors()
    end)

    T.case("Classic Era says guild and group", function()
        local ns = H.Boot({ client = "era" })
        T.eq(ns.Presence:Count().scope, "group", "Era cannot reach the realm")
        H.Slash("online")
        T.ok(H.Printed("in your guild and group: 1"), "the command says so")
        T.noErrors()
    end)

    T.case("the window and /hh online show the count", function()
        local ns = H.Boot({ client = "forever" })
        H.Deliver(Here(ns, "H"), "Grim Tusk")
        H.Slash("")
        T.eq(_G.HeadHunterMainFrame.online.text.shownText, "2 online", "window")
        H.Slash("online")
        T.ok(H.Printed("Alliance 1, Horde 1"), "command, per faction")
        T.ok(H.Printed("0.1.7"), "versions")
        T.noErrors()
    end)
end
