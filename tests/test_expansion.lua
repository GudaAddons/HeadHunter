-- HH-002: client detection must accept exactly Classic Era and WoW Forever.

return function(T, H)
    local function Detect(client)
        H.Install({ client = client })
        return H.Load()
    end

    T.case("Classic Era 11509", function()
        local ns = Detect("era")
        local E = ns.Expansion
        T.eq(E.IsEra, true, "IsEra")
        T.eq(E.IsForever, false, "IsForever")
        T.eq(E.IsSupported, true, "IsSupported")
        T.eq(E.ClientKey, "era", "ClientKey")
        T.eq(ns.Features.HasCLEU, true, "HasCLEU")
        T.eq(ns.Features.SavedVarsReliable, true, "SavedVarsReliable")
        T.eq(ns.Features.RealmlessNames, false, "RealmlessNames")
    end)

    T.case("WoW Forever 16001 reporting WOW_PROJECT_CLASSIC", function()
        local ns = Detect({ iface = 16001, project = 2 })
        T.eq(ns.Expansion.IsForever, true, "IsForever")
        T.eq(ns.Expansion.IsEra, false, "IsEra")
    end)

    T.case("WoW Forever 16001 (reports WOW_PROJECT_ID 1, as seen in game)", function()
        local ns = Detect("forever")
        local E = ns.Expansion
        T.eq(E.IsForever, true, "IsForever")
        T.eq(E.IsEra, false, "IsEra must not also match")
        T.eq(E.ClientKey, "forever", "ClientKey")
        T.eq(ns.Features.HasCLEU, false, "HasCLEU")
        T.eq(ns.Features.SavedVarsReliable, false, "SavedVarsReliable")
        T.eq(ns.Features.RealmlessNames, true, "RealmlessNames")
    end)

    T.case("WoW Forever without any project ID", function()
        local ns = Detect({ iface = 16001, project = nil })
        T.eq(ns.Expansion.IsForever, true, "IsForever")
    end)

    local UNSUPPORTED = {
        { name = "TBC Anniversary", iface = 20506, project = 5 },
        { name = "MoP Classic", iface = 50504, project = 19 },
        { name = "Retail", iface = 120100, project = 1 },
        { name = "Era-range version with mainline project", iface = 11509, project = 1 },
        { name = "missing interface version", iface = nil, project = nil },
        { name = "string interface version", iface = "garbage", project = 2 },
    }
    for _, client in ipairs(UNSUPPORTED) do
        T.case("unsupported: " .. client.name, function()
            local ns = Detect(client)
            T.eq(ns.Expansion.IsSupported, false, "IsSupported")
            T.eq(ns.Expansion.ClientKey, "unsupported", "ClientKey")
        end)
    end

    T.case("unsupported client boots without a database or errors", function()
        H.Install({ client = { iface = 20506, project = 5 } })
        local ns = H.Load()
        H.Fire("ADDON_LOADED", "HeadHunter")
        H.Fire("PLAYER_LOGIN")
        T.eq(ns.db, nil, "db")
        T.ok(H.Printed("not supported"), "warning printed")
        T.ok(not H.Printed("loaded%."), "no loaded message")
        H.Slash("status")
        T.noErrors()
    end)
end
