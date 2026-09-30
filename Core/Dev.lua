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
