-- HH-004 guards: HeadHunter is off inside instances; duel window.

return function(T, H)
    local INSTANCE_TYPES = { "pvp", "arena", "party", "raid", "scenario" }

    for _, instanceType in ipairs(INSTANCE_TYPES) do
        T.case("suspended inside " .. instanceType, function()
            local ns = H.Boot({ client = "era" })
            local seen
            ns.Events:Register("HH_SUSPEND_CHANGED", function(_, suspended, kind) seen = tostring(suspended) .. ":" .. kind end, "t")
            H.instance = { true, instanceType }
            H.Fire("PLAYER_ENTERING_WORLD", false, false)
            T.eq(ns.Guards.InstanceSuspended, true, "suspended")
            T.eq(ns.Guards:IsActive(), false, "inactive")
            T.eq(seen, "true:" .. instanceType, "event")
        end)
    end

    T.case("active again after leaving; no event when nothing changes", function()
        local ns = H.Boot({ client = "forever" })
        local fired = 0
        ns.Events:Register("HH_SUSPEND_CHANGED", function() fired = fired + 1 end, "t")
        H.instance = { true, "pvp" }
        H.Fire("ZONE_CHANGED_NEW_AREA")
        H.instance = { false, "none" }
        H.Fire("ZONE_CHANGED_NEW_AREA")
        H.Fire("ZONE_CHANGED_NEW_AREA")
        T.eq(ns.Guards:IsActive(), true, "active")
        T.eq(ns.Guards.InstanceType, "none", "type")
        T.eq(fired, 2, "only real transitions fire")
    end)

    T.case("duel window", function()
        local ns = H.Boot({ client = "era" })
        T.eq(ns.Guards:RecentlyDueled(10), false, "no duel")
        H.Fire("DUEL_REQUESTED", "Duelist")
        T.eq(ns.Guards.InDuel, true, "in duel")
        T.eq(ns.Guards.DuelOpponent, "Duelist-Firemaw", "opponent key")
        H.Fire("DUEL_FINISHED")
        T.eq(ns.Guards:RecentlyDueled(10), true, "just finished")
        H.clock = H.clock + 11
        T.eq(ns.Guards:RecentlyDueled(10), false, "window passed")
    end)
end
