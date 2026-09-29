-- HH-123: settings for the author's own PCs, from the separate addon HeadHunter_Dev
-- (listed as OptionalDeps). It is never in this repo or a release, so every player
-- has none and gets the defaults.
--
-- Interface\AddOns\HeadHunter_Dev\Config.lua:
--   HeadHunter_Dev = { trust = { "Testone-Firemaw", "Testtwo Forever" } }
--
-- trust: characters whose test deaths (/hh sim send) we count. The check is on our
-- side, so another player's own HeadHunter_Dev never makes us count their test data.

local addonName, ns = ...

local Dev = ns:RegisterModule("Dev", {})

local function Config()
    local config = _G.HeadHunter_Dev
    return type(config) == "table" and config or nil
end

function Dev.Trusts(name)
    local config = Config()
    if not name or not config or type(config.trust) ~= "table" then return false end
    for _, trusted in ipairs(config.trust) do
        if type(trusted) == "string" and ns.Utils.SameCharacter(name, trusted) then return true end
    end
    return false
end
