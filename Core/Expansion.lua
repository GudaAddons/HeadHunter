-- HeadHunter client detection. Supports exactly two clients:
--   Classic Era   Interface 11509, WOW_PROJECT_CLASSIC
--   WoW: Forever  Interface 16001 ("Camelot", 1.60.1)
-- Adapted from GudaBags Core/Expansion.lua, which documents why Forever is matched
-- by interface range: it has no WOW_PROJECT_ID of its own and runs the modern 12.x
-- engine behind a Vanilla-shaped version number.

local addonName, ns = ...

local Expansion = ns:RegisterModule("Expansion", {})

-- Normalise once: a nil or string 4th return must not turn into a load-time error.
local _, _, _, interfaceVersion = GetBuildInfo()
local iface = tonumber(interfaceVersion) or 0
Expansion.InterfaceVersion = iface

Expansion.IsForever = iface >= 16000 and iface < 20000

-- Forever may report WOW_PROJECT_CLASSIC too, so it is excluded by range first.
-- A client that reports a project ID other than Classic is never Era, whatever
-- its interface number says.
local projectIsClassic = WOW_PROJECT_ID == nil or WOW_PROJECT_ID == (WOW_PROJECT_CLASSIC or 2)
Expansion.IsEra = not Expansion.IsForever and iface >= 11500 and iface < 16000 and projectIsClassic

Expansion.IsSupported = Expansion.IsEra or Expansion.IsForever

if Expansion.IsForever then
    Expansion.ClientKey = "forever"
elseif Expansion.IsEra then
    Expansion.ClientKey = "era"
else
    Expansion.ClientKey = "unsupported"
end

Expansion.Features = {
    -- Forever runs the 12.x engine, which withholds COMBAT_LOG_EVENT_UNFILTERED from
    -- addons. Killer detection there is inferred.
    -- HH-007 (/hh probe) confirms this in game.
    HasCLEU = Expansion.IsEra and type(CombatLogGetCurrentEventInfo) == "function",

    -- The Forever client writes SavedVariables but does not load them back
    -- (docs/README.md "Known bug"). Nothing may depend on data surviving a reload there.
    SavedVarsReliable = not Expansion.IsForever,

    -- 12.x "secret values": unit API results an addon may hold but not inspect.
    -- Core/Utils.lua treats them as missing.
    HasSecretValues = type(canaccessvalue) == "function" or type(issecretvalue) == "function",

    -- Forever identities are "Given Family" with no realm; Era identities are Name-Realm.
    RealmlessNames = Expansion.IsForever,
}

-- Convenience exports to namespace root
ns.IsEra = Expansion.IsEra
ns.IsForever = Expansion.IsForever
ns.IsSupported = Expansion.IsSupported
ns.Features = Expansion.Features
