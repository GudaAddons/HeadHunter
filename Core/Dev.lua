-- HH-123: settings for the author's own PCs, from the separate addon HeadHunter_Dev
-- (listed as OptionalDeps). It is never in this repo or a release, so every player
-- has none and gets the defaults.
--
-- Interface\AddOns\HeadHunter_Dev\Config.lua:
--   HeadHunter_Dev = { trust = { "Testone-Firemaw", "Testtwo Forever" } }
--
-- trust: characters whose test deaths (/hh sim send) we count. The check is on our
-- side, so another player's own HeadHunter_Dev never makes us count their test data.
--
-- locale: show a translation on any client: "zhCN", "zhTW", "koKR", "ruRU", "ptBR", "esES", "esMX", "frFR", "deDE" or "itIT" (read by Locales.lua).
-- Class and faction names still come from the client, so they stay in its language.
--
-- noSharing = true: test mode, for example with the local development sync app (author,
-- 2026-09-30). Nothing leaves this client: no addon messages and no channel text
-- (Sync/Transport.lua), so local test data never reaches other players. Receiving still
-- works. A chat line at login says it is on (Core/Main.lua).

local addonName, ns = ...

local Dev = ns:RegisterModule("Dev", {})

local function Config()
    local config = _G.HeadHunter_Dev
    return type(config) == "table" and config or nil
end

function Dev.NoSharing()
    local config = Config()
    return config ~= nil and config.noSharing == true
end

function Dev.Trusts(name)
    local config = Config()
    if not name or not config or type(config.trust) ~= "table" then return false end
    for _, trusted in ipairs(config.trust) do
        if type(trusted) == "string" and ns.Utils.SameCharacter(name, trusted) then return true end
    end
    return false
end

-- Test marks (author, 2026-09-30): /hh dev wanted and /hh dev shame (UI/Nameplates.lua)
-- put the WANTED or Hall of Shame mark above the target's head, only on this client and
-- only with a HeadHunter_Dev config. Nothing else changes: no list, alert or sharing.
-- Memory only, so a /reload clears them.
local testMarks = { wanted = {}, shame = {} }

function Dev.TestMark(kind, key)
    return Config() ~= nil and key ~= nil and testMarks[kind] ~= nil and testMarks[kind][key] == true
end

-- Turns the mark on or off; returns true when it is now on
function Dev.ToggleTestMark(kind, key)
    testMarks[kind][key] = not testMarks[kind][key] or nil
    return testMarks[kind][key] == true
end

function Dev.ClearTestMarks()
    testMarks = { wanted = {}, shame = {} }
end

function Dev.Enabled()
    return Config() ~= nil
end
