-- Pet and minion kills count for their owner (in game 2026-09-23: hunter pet "Aida"
-- killed the player and nothing was reported).

return function(T, H)
    local ME = "Player-1-00000001"
    local HUNTER, HUNTER2, PET = "Player-2-HUNT", "Player-3-HUNT", "Pet-0-4613-0-777-1-AIDA"

    local function PetUnit(ownerName, guid)
        return { name = "Aida", level = 60, playerControlled = true, hostile = true, isPlayer = false,
            guid = guid or PET, tooltip = { ownerName .. "'s Pet", "Level 60 Beast" } }
    end

    local function HunterUnit(name, guid)
        return { name = name, realm = "Stonespine", level = 60, class = "HUNTER", race = "Orc",
            faction = "Horde", isPlayer = true, guid = guid or HUNTER }
    end

    local function PetBite(amount, overkill, petGUID)
        H.FireCLEU(1, "SWING_DAMAGE", false, petGUID or PET, "Aida", H.FLAGS_HOSTILE_PET, 0,
            ME, "Vati", 0x511, 0, amount, overkill)
    end

    T.case("owner names are read from pet tooltip lines", function()
        local P = H.Boot({ client = "era" }).PetOwners
        T.eq(P.OwnerFromLine("Rexxar's Pet"), "Rexxar", "pet")
        T.eq(P.OwnerFromLine("Gulgar's Minion"), "Gulgar", "minion")
        T.eq(P.OwnerFromLine("Grim Reaper's Pet"), "Grim Reaper", "Forever two-word owner")
        T.eq(P.OwnerFromLine("Level 60 Beast"), nil, "not an owner line")
        T.eq(P.OwnerFromLine(nil), nil, "nil")
    end)

    T.case("era: pet seen on a nameplate earlier, its killing blow credits the hunter", function()
        local ns = H.Boot({ client = "era" })
        H.units.nameplate1 = PetUnit("Hunty")
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        PetBite(200, -1)
        PetBite(90, 47)
        H.Fire("PLAYER_DEAD")
        T.eq(#ns.db.deaths, 1, "reported")
        T.eq(ns.db.deaths[1].killer.key, "Hunty-Firemaw", "the owner is the killer")
        T.eq(ns.db.deaths[1].confidence, "exact", "full kill")
        T.noErrors()
    end)

    T.case("era: pet never seen before, still the target at death: tooltip read at death", function()
        local ns = H.Boot({ client = "era" })
        PetBite(300, 47)
        H.units.target = PetUnit("Hunty")
        H.Fire("PLAYER_DEAD")
        T.eq(ns.db.deaths[1].killer.key, "Hunty-Firemaw", "owner found at death")
        T.eq(ns.db.deaths[1].confidence, "exact", "full kill")
    end)

    T.case("era: targeting the hunter reveals his pet (targetpet)", function()
        local ns = H.Boot({ client = "era" })
        H.units.target = HunterUnit("Hunty")
        H.units.targetpet = { name = "Aida", guid = PET, playerControlled = true }
        H.Fire("PLAYER_TARGET_CHANGED")
        H.units.target, H.units.targetpet = nil, nil
        PetBite(300, 47)
        H.Fire("PLAYER_DEAD")
        T.eq(ns.db.deaths[1].killer.key, "Hunty-Stonespine", "owner from targetpet")
    end)

    T.case("era: Mend Pet in the combat log links the hunter to his pet", function()
        local ns = H.Boot({ client = "era" })
        H.guidInfo[HUNTER] = { class = "HUNTER", race = "Orc", sex = 2, name = "Hunty", realm = "Stonespine" }
        H.FireCLEU(1, "SPELL_CAST_SUCCESS", false, HUNTER, "Hunty-Stonespine", H.FLAGS_HOSTILE_PLAYER, 0,
            PET, "Aida", H.FLAGS_HOSTILE_PET, 0, 136, "Mend Pet", 1)
        PetBite(300, 47)
        H.Fire("PLAYER_DEAD")
        T.eq(ns.db.deaths[1].killer.key, "Hunty-Stonespine", "owner from Mend Pet")
        T.eq(ns.db.deaths[1].confidence, "exact", "full kill")
    end)

    T.case("era: the hunter and his pet together are one attacker", function()
        local ns = H.Boot({ client = "era" })
        H.guidInfo[HUNTER] = { class = "HUNTER", race = "Orc", sex = 2, name = "Hunty", realm = "Stonespine" }
        H.FireCLEU(1, "SPELL_CAST_SUCCESS", false, HUNTER, "Hunty-Stonespine", H.FLAGS_HOSTILE_PLAYER, 0,
            PET, "Aida", H.FLAGS_HOSTILE_PET, 0, 136, "Mend Pet", 1)
        H.FireCLEU(1, "RANGE_DAMAGE", false, HUNTER, "Hunty-Stonespine", H.FLAGS_HOSTILE_PLAYER, 0,
            ME, "Vati", 0x511, 0, 75, "Auto Shot", 1, 150, -1)
        PetBite(300, 47)
        H.Fire("PLAYER_DEAD")
        T.eq(ns.db.deaths[1].killer.key, "Hunty-Stonespine", "killer")
        T.eq(#ns.db.deaths[1].assists, 0, "no separate pet assist")
    end)

    T.case("era: unknown pet owner, one enemy hunter seen nearby: guessed (half weight)", function()
        local ns = H.Boot({ client = "era" })
        H.units.nameplate2 = HunterUnit("Hunty")
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
        PetBite(300, 47)
        H.Fire("PLAYER_DEAD")
        T.eq(ns.db.deaths[1].killer.key, "Hunty-Stonespine", "lone hunter")
        T.eq(ns.db.deaths[1].confidence, "inferred", "guessed")
    end)

    T.case("era: unknown pet owner, two hunters around: no guess, no report", function()
        local ns = H.Boot({ client = "era" })
        H.units.nameplate2 = HunterUnit("Hunty")
        H.units.nameplate3 = HunterUnit("Other", HUNTER2)
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
        PetBite(300, 47)
        H.Fire("PLAYER_DEAD")
        T.eq(#ns.db.deaths, 0, "not reported")
        T.noErrors()
    end)

    T.case("forever: a pet in the Death Recap counts for its owner", function()
        local ns = H.Boot({ client = "forever" })
        H.units.nameplate1 = PetUnit("Hunty Man")
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        H.recap = { { sourceGUID = PET, sourceName = "Aida", sourceFlags = 0x1148, overkill = 47,
            amount = 90, timestamp = H.serverTime - 2 } }
        H.Fire("PLAYER_DEAD")
        H.Advance(0.3)
        T.eq(#ns.db.deaths, 1, "reported")
        T.eq(ns.db.deaths[1].killer.key, "Hunty Man", "owner is the killer")
        T.eq(ns.db.deaths[1].confidence, "exact", "full kill")
        T.noErrors()
    end)

    T.case("forever: unknown pet owner and a lone hunter nearby: guessed", function()
        local ns = H.Boot({ client = "forever" })
        H.units.nameplate2 = { name = "Hunty", realm = "Man", level = 60, class = "HUNTER", race = "Orc",
            faction = "Horde", isPlayer = true, guid = HUNTER }
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
        H.recap = { { sourceGUID = PET, sourceName = "Aida", sourceFlags = 0x1148, overkill = 47,
            amount = 90, timestamp = H.serverTime - 2 } }
        H.Fire("PLAYER_DEAD")
        H.Advance(0.3)
        T.eq(ns.db.deaths[1].killer.key, "Hunty Man", "lone hunter")
        T.eq(ns.db.deaths[1].confidence, "inferred", "guessed")
    end)
end
