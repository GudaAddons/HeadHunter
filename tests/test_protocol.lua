-- HH-021: wire format.

return function(T, H)
    local function P()
        return H.Boot({ client = "forever" }).Protocol
    end

    local function Report(overrides)
        local r = {
            t = 1790109611,
            victim = { key = "Or Cgrimmar", level = 12, class = "WARRIOR", race = "Orc" },
            killer = { key = "Hiroshima Hashimoto", name = "Hiroshima Hashimoto", level = 20, class = "MAGE", race = "Gnome", sex = 3 },
            assists = {},
            mapID = 1434, x = 0.4213, y = 0.6599,
            confidence = "exact",
        }
        for k, v in pairs(overrides or {}) do r[k] = v end
        return r
    end

    T.case("base36 round trip and rejection", function()
        local p = P()
        for _, n in ipairs({ 0, 1, 35, 36, 1434, 1790109611 }) do
            T.eq(p.FromB36(p.ToB36(n)), n, "round trip " .. n)
        end
        T.eq(p.FromB36(""), nil, "empty")
        T.eq(p.FromB36("ZZ"), nil, "uppercase")
        T.eq(p.FromB36("-1"), nil, "sign")
    end)

    T.case("death report round trip", function()
        local p = P()
        local record = p.EncodeDeath(Report())
        T.ok(#record < 120, "compact: " .. #record .. " bytes")
        local r = p.DecodeDeath(record)
        T.eq(r.id, "Or Cgrimmar:1790109611", "id")
        T.eq(r.victim.key, "Or Cgrimmar", "victim")
        T.eq(r.victim.level, 12, "victim level")
        T.eq(r.victim.class, "WARRIOR", "victim class")
        T.eq(r.victim.race, "Orc", "victim race")
        T.eq(r.killer.key, "Hiroshima Hashimoto", "killer")
        T.eq(r.killer.level, 20, "killer level")
        T.eq(r.killer.class, "MAGE", "killer class")
        T.eq(r.killer.race, "Gnome", "killer race")
        T.eq(r.killer.sex, 3, "killer sex")
        T.eq(r.mapID, 1434, "map")
        T.eq(r.x, 0.421, "x (3 decimals)")
        T.eq(r.y, 0.659, "y")
        T.eq(r.confidence, "exact", "confidence")
    end)

    T.case("skull, unknown level, incomplete killer with GUID, assists", function()
        local p = P()
        local r = p.DecodeDeath(p.EncodeDeath(Report({
            killer = { name = "Kuh", nameIncomplete = true, guid = "Player-4613-00A96B33", level = -1 },
            assists = {
                { key = "Lokiju Hardwood", name = "Lokiju Hardwood", class = "WARRIOR" },
                { key = "Fur Enough", name = "Fur Enough", level = 18, class = "DRUID", race = "NightElf" },
            },
            -- false, not nil: a nil in a table constructor would not override the default
            confidence = "inferred", x = false, y = false,
        })))
        T.eq(r.killer.key, nil, "no key")
        T.eq(r.killer.name, "Kuh", "given name")
        T.eq(r.killer.nameIncomplete, true, "incomplete")
        T.eq(r.killer.guid, "Player-4613-00A96B33", "guid kept for completion")
        T.eq(r.killer.level, -1, "skull")
        T.eq(#r.assists, 2, "assists")
        T.eq(r.assists[1].level, nil, "unknown level")
        T.eq(r.assists[2].race, "NightElf", "assist race")
        T.eq(r.x, nil, "no position")
        T.eq(r.confidence, "inferred", "inferred")
    end)

    T.case("assists are dropped to fit, never the killer", function()
        local p = P()
        local assists = {}
        for i = 1, 10 do
            assists[i] = { name = "Longgivenname" .. i, nameIncomplete = true, guid = "Player-4613-00A96B3" .. i }
        end
        local record = p.EncodeDeath(Report({ assists = assists }))
        T.ok(#record <= p.MAX_MESSAGE - 4, "fits in a message with its header")
        local r = p.DecodeDeath(record)
        T.eq(r.killer.key, "Hiroshima Hashimoto", "killer kept")
        T.ok(#r.assists <= p.MAX_ASSISTS, "assists capped")
    end)

    T.case("malformed death records are rejected", function()
        local p = P()
        local good = p.EncodeDeath(Report())
        T.eq(p.DecodeDeath(nil), nil, "nil")
        T.eq(p.DecodeDeath(""), nil, "empty")
        T.eq(p.DecodeDeath("a;b;c"), nil, "too few fields")
        T.eq(p.DecodeDeath(good:gsub("^[^;]+", "")), nil, "no time")
        T.eq(p.DecodeDeath(good:gsub(";c;", ";zz;", 1)), nil, "victim level out of range")
        local fields = p.Split(good, ";")
        fields[3] = "s"
        T.eq(p.DecodeDeath(table.concat(fields, ";")), nil, "skull victim is impossible")
        fields = p.Split(good, ";")
        fields[11] = "Kuh,1,k,,,,"
        T.eq(p.DecodeDeath(table.concat(fields, ";")), nil, "incomplete killer without GUID")
    end)

    T.case("identity round trip", function()
        local p = P()
        local id, identity = p.DecodeIdentity(p.EncodeIdentity("Or Cgrimmar:1790109611",
            { guid = "Player-4613-00A96B33", key = "Kuh Blam", level = 20, class = "HUNTER", race = "Human", sex = 2 }))
        T.eq(id, "Or Cgrimmar:1790109611", "report id")
        T.eq(identity.key, "Kuh Blam", "key")
        T.eq(identity.guid, "Player-4613-00A96B33", "guid")
        T.eq(identity.level, 20, "level")
        T.eq(identity.class, "HUNTER", "class")
        T.eq(p.DecodeIdentity("x;;y;;;;"), nil, "missing guid")
    end)

    T.case("pack many records into few messages, each within 255 bytes", function()
        local p = P()
        local records = {}
        for i = 1, 12 do records[i] = p.EncodeDeath(Report({ t = 1790109611 + i })) end
        local messages = p.Pack("A", "D", records)
        T.ok(#messages < 12, "packed: " .. #messages .. " messages")
        local count = 0
        for _, message in ipairs(messages) do
            T.ok(#message <= 255, "size " .. #message)
            local faction, typeCode, got = p.Unpack(message)
            T.eq(faction, "Alliance", "faction")
            T.eq(typeCode, "D", "type")
            for _, record in ipairs(got) do
                T.ok(p.DecodeDeath(record) ~= nil, "record decodes")
                count = count + 1
            end
        end
        T.eq(count, 12, "no record lost")
    end)

    T.case("unpack rejects foreign versions and junk", function()
        local p = P()
        T.eq(p.Unpack("2AD:abc"), nil, "future version")
        T.eq(p.Unpack("1XD:abc"), nil, "unknown faction")
        T.eq(p.Unpack("1AD:"), nil, "empty body")
        T.eq(p.Unpack("hello"), nil, "junk")
        T.eq(p.Unpack(string.rep("x", 300)), nil, "oversized")
    end)

    T.case("our group members in the fight travel as the last field", function()
        local p = P()
        local assist = { key = "Fur Enough", name = "Fur Enough", level = 18, class = "DRUID", race = "NightElf" }
        local record = p.EncodeDeath(Report({ assists = { assist }, helpers = 2 }))
        T.ok(record:sub(-3) == ";h2", "last field: " .. record)
        local r = p.DecodeDeath(record)
        T.eq(r.helpers, 2, "helpers")
        T.eq(#r.assists, 1, "assists unchanged")
        T.eq(p.DecodeDeath(p.EncodeDeath(Report())).helpers, nil, "alone: no field")
        T.eq(p.EncodeDeath(Report({ helpers = 0 })), p.EncodeDeath(Report()), "0 is not sent")

        local assists = {}
        for i = 1, 10 do
            assists[i] = { name = "Longgivenname" .. i, nameIncomplete = true, guid = "Player-4613-00A96B3" .. i }
        end
        local full = p.EncodeDeath(Report({ assists = assists, helpers = 3 }))
        T.ok(#full <= p.MAX_MESSAGE - 4, "fits with the field")
        T.eq(p.DecodeDeath(full).helpers, 3, "kept when assists are dropped")
    end)
end
