-- HH-010: enemy cache by key and GUID.

return function(T, H)
    -- An enemy nameplate as each client presents it
    local function Enemy(client, guid, given, family, level)
        return {
            name = given, realm = client == "forever" and family or "Stonespine",
            level = level or 20, class = "HUNTER", race = "Orc", sex = 2, guild = "The Island",
            faction = "Horde", isPlayer = true, guid = guid,
        }
    end

    local KEYS = { era = "Kuh-Stonespine", forever = "Kuh Blam" }

    for _, client in ipairs({ "era", "forever" }) do
        T.case(client .. ": nameplate fills the cache by key and GUID", function()
            local ns = H.Boot({ client = client })
            local seen
            ns.Events:Register("HH_ENEMY_SEEN", function(_, record, source) seen = source end, "t")
            H.units.nameplate1 = Enemy(client, "Player-4613-00A96B33", "Kuh", "Blam")
            H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
            local record = ns.EnemyCache:ByGUID("Player-4613-00A96B33")
            T.ok(record ~= nil, "cached")
            T.eq(record.key, KEYS[client], "key")
            T.eq(record.level, 20, "level")
            T.eq(record.class, "HUNTER", "class")
            T.eq(record.race, "Orc", "race")
            T.eq(record.sex, 2, "sex")
            T.eq(record.guild, "The Island", "guild")
            T.eq(record.lastMapID, 1429, "map")
            T.eq(ns.db.enemies[KEYS[client]], record, "stored in db")
            T.eq(seen, "nameplate", "HH_ENEMY_SEEN source")
            T.noErrors()
        end)
    end

    T.case("friendly players and NPCs are ignored", function()
        local ns = H.Boot({ client = "era" })
        H.units.nameplate1 = { name = "Friend", faction = "Alliance", isPlayer = true, guid = "Player-9" }
        H.units.nameplate2 = { name = "Defias", faction = "Horde", isPlayer = false, guid = "Creature-1" }
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
        T.eq(next(ns.db.enemies), nil, "nothing cached")
    end)

    T.case("nothing is cached inside instances", function()
        local ns = H.Boot({ client = "era" })
        H.instance = { true, "pvp" }
        H.Fire("PLAYER_ENTERING_WORLD", false, false)
        H.units.nameplate1 = Enemy("era", "Player-2", "Kuh")
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        T.eq(next(ns.db.enemies), nil, "nothing cached")
    end)

    T.case("skull level keeps a minimum level", function()
        local ns = H.Boot({ client = "era" })
        H.units.target = Enemy("era", "Player-2", "Kuh", nil, -1)
        H.Fire("PLAYER_TARGET_CHANGED")
        local record = ns.EnemyCache:ByGUID("Player-2")
        T.eq(record.level, -1, "skull")
        T.eq(record.levelMin, 40, "player level 30 + 10")
    end)

    T.case("refresh is throttled per GUID but levels update later", function()
        local ns = H.Boot({ client = "era" })
        H.units.nameplate1 = Enemy("era", "Player-2", "Kuh", nil, 20)
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        H.units.nameplate1.level = 21
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        T.eq(ns.EnemyCache:ByGUID("Player-2").level, 20, "throttled")
        H.clock = H.clock + 3
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        T.eq(ns.EnemyCache:ByGUID("Player-2").level, 21, "refreshed")
    end)

    T.case("era: a combat log GUID gets a full key immediately", function()
        local ns = H.Boot({ client = "era" })
        H.guidInfo["Player-2"] = { class = "ROGUE", race = "Orc", sex = 3, name = "Gank", realm = "Stonespine" }
        local record = ns.EnemyCache:ObserveGUID("Player-2", "Gank-Stonespine", "combatlog")
        T.eq(record and record.key, "Gank-Stonespine", "key")
        T.eq(record.class, "ROGUE", "class from GUID")
        T.eq(record.sex, 3, "sex from GUID")
        T.eq(record.level, nil, "no level from the combat log")
    end)

    T.case("forever: a recap GUID stays partial until the unit is seen", function()
        local ns = H.Boot({ client = "forever" })
        local resolved
        ns.Events:Register("HH_ENEMY_RESOLVED", function(_, guid, record) resolved = guid .. "=" .. record.key end, "t")
        H.guidInfo["Player-4613-00A96B33"] = { class = "HUNTER", race = "Orc", sex = 2, name = "Kuh", realm = "ClassicBetaPvP2" }
        local record, part = ns.EnemyCache:ObserveGUID("Player-4613-00A96B33", "Kuh-ClassicBetaPvP2", "deathrecap")
        T.eq(record, nil, "no full record yet")
        T.eq(part.givenName, "Kuh", "given name")
        T.eq(part.class, "HUNTER", "class")
        H.units.nameplate1 = Enemy("forever", "Player-4613-00A96B33", "Kuh", "Blam")
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        T.eq(resolved, "Player-4613-00A96B33=Kuh Blam", "HH_ENEMY_RESOLVED")
        T.eq(ns.EnemyCache:PartialByGUID("Player-4613-00A96B33"), nil, "partial dropped")
    end)

    T.case("GUID index is rebuilt from restored SavedVariables", function()
        local saved = { enemies = { ["Kuh Blam"] = { key = "Kuh Blam", guid = "Player-7", lastSeen = 1780000000 } } }
        local ns = H.Boot({ client = "forever", savedDB = saved })
        T.eq(ns.EnemyCache:ByGUID("Player-7").key, "Kuh Blam", "indexed")
    end)

    T.case("likely attacker: live target, then recent target, then newest sighting", function()
        local ns = H.Boot({ client = "era" })
        T.eq(ns.EnemyCache:LikelyAttacker(10), nil, "nobody")

        H.units.target = Enemy("era", "Player-2", "Kuh")
        T.eq(ns.EnemyCache:LikelyAttacker(10).key, "Kuh-Stonespine", "live target")

        H.Fire("PLAYER_TARGET_CHANGED")
        H.units.target = nil
        H.clock = H.clock + 5
        T.eq(ns.EnemyCache:LikelyAttacker(10).key, "Kuh-Stonespine", "recent target")

        H.clock = H.clock + 20
        H.units.nameplate1 = Enemy("era", "Player-3", "Stab")
        H.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
        T.eq(ns.EnemyCache:LikelyAttacker(10).key, "Stab-Stonespine", "newest sighting")

        H.clock = H.clock + 20
        T.eq(ns.EnemyCache:LikelyAttacker(10), nil, "all too old")
        H.Slash("enemies")
        T.ok(H.Printed("Enemies seen: 2"), "/hh enemies")
        T.noErrors()
    end)
end
