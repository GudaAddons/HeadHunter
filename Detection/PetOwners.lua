-- Who owns a hostile pet or minion (hunter pets, warlock demons, guardians).
--
-- A pet called before the fight gives no SPELL_SUMMON, so the combat log alone
-- cannot tell whose it is (in game 2026-09-23: a hunter pet "Aida" killed the
-- player and nothing was reported). Owners are learned from:
--   1. the pet's tooltip: "<Owner>'s Pet" / "Minion" / "Guardian" (UNITNAME_TITLE_*),
--      read when the pet is seen as nameplate, target or mouseover, and on demand
--      at death
--   2. "targetpet" / "focuspet" when the owner himself is target / focus
--   3. the combat log (Era): SPELL_SUMMON, and a hostile hunter/warlock casting on
--      his pet (Mend Pet, buffs...)
-- Fallback at death (LikelyOwner): exactly one enemy hunter or warlock seen in the
-- last 30 s.
--
--   PetOwners:Owner(petGUID) -> { key?, guid?, name }  or nil

local addonName, ns = ...

local PetOwners = ns:RegisterModule("PetOwners", {})

local OWNER = "PetOwners"

PetOwners.TTL = 3600
PetOwners.LIKELY_WINDOW = 30
PetOwners.PET_CLASSES = { HUNTER = true, WARLOCK = true }

local owners = {}   -- petGUID -> { key, guid, name, at }

-- "%s's Pet" -> "^(.+)'s Pet$" for every owner title the client knows
local titlePatterns
local function TitlePatterns()
    if titlePatterns then return titlePatterns end
    titlePatterns = {}
    for _, global in ipairs({ "UNITNAME_TITLE_PET", "UNITNAME_TITLE_MINION", "UNITNAME_TITLE_GUARDIAN",
            "UNITNAME_TITLE_CREATION", "UNITNAME_TITLE_COMPANION", "UNITNAME_TITLE_CHARM" }) do
        local format = _G[global]
        if type(format) == "string" and format:find("%%s") then
            -- Escape pattern magic, then turn the literal "%s" into a capture
            local pattern = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)")
            titlePatterns[#titlePatterns + 1] = "^" .. pattern .. "$"
        end
    end
    return titlePatterns
end

-- Owner name from one tooltip line, or nil
function PetOwners.OwnerFromLine(line)
    if type(line) ~= "string" then return nil end
    for _, pattern in ipairs(TitlePatterns()) do
        local owner = line:match(pattern)
        if owner then return owner end
    end
    return nil
end

-- Tooltip lines 2..4 of a unit: C_TooltipInfo where it exists (Forever), a hidden
-- scanning tooltip otherwise (Era)
local scanner
local function TooltipLines(unit)
    local lines = {}
    if C_TooltipInfo and C_TooltipInfo.GetUnit then
        local data = ns.Utils.SafeCall(C_TooltipInfo.GetUnit, unit)
        for i = 2, 4 do
            local line = data and data.lines and data.lines[i]
            lines[#lines + 1] = line and ns.Utils.AccessibleString(line.leftText)
        end
        return lines
    end
    if not scanner then
        scanner = CreateFrame("GameTooltip", "HeadHunterScanTooltip", nil, "GameTooltipTemplate")
    end
    scanner:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
    local ok = pcall(scanner.SetUnit, scanner, unit)
    if ok then
        for i = 2, 4 do
            local region = _G["HeadHunterScanTooltipTextLeft" .. i]
            lines[#lines + 1] = region and ns.Utils.AccessibleString(region:GetText())
        end
    end
    scanner:Hide()
    return lines
end

local function Remember(petGUID, ownerName, ownerGUID)
    if not petGUID then return nil end
    local key = ns.Utils.PlayerKey(ownerName)
    if not key and not ownerGUID then return nil end
    local entry = { key = key, guid = ownerGUID, name = ownerName, at = ns.Utils.Now() }
    owners[petGUID] = entry
    ns:Debug("Pet owner:", petGUID, "->", key or ownerGUID)
    return entry
end

function PetOwners:Learn(petGUID, ownerName, ownerGUID)
    return Remember(petGUID, ownerName, ownerGUID)
end

-- A hostile pet unit: read its owner from the tooltip
function PetOwners:ObservePetUnit(unit)
    local U = ns.Utils
    if U.UnitIsPlayer(unit) or not U.SafeCall(UnitPlayerControlled, unit) then return nil end
    if not U.SafeCall(UnitCanAttack, "player", unit) then return nil end
    local petGUID = U.UnitGUID(unit)
    if not petGUID or owners[petGUID] then return owners[petGUID] end
    for _, line in ipairs(TooltipLines(unit)) do
        local owner = PetOwners.OwnerFromLine(line)
        if owner then return Remember(petGUID, owner) end
    end
    return nil
end

-- The owner himself as target/focus: his pet is "<unit>pet"
function PetOwners:ObserveOwnerUnit(unit)
    local U = ns.Utils
    if not U.UnitIsEnemyPlayer(unit) then return end
    local petGUID = U.UnitGUID(unit .. "pet")
    if petGUID and not owners[petGUID] then
        Remember(petGUID, U.UnitName(unit), U.UnitGUID(unit))
        local entry = owners[petGUID]
        if entry then entry.key = U.UnitKey(unit) or entry.key end
    end
end

-- Look for the pet among current units (at death: the killer pet is usually still there)
function PetOwners:ScanFor(petGUID)
    if not petGUID or owners[petGUID] then return owners[petGUID] end
    local units = { "target", "mouseover", "focus", "softenemy" }
    for i = 1, 40 do units[#units + 1] = "nameplate" .. i end
    for _, unit in ipairs(units) do
        if ns.Utils.UnitGUID(unit) == petGUID then
            return self:ObservePetUnit(unit)
        end
    end
    return nil
end

function PetOwners:Owner(petGUID)
    local entry = petGUID and owners[petGUID]
    if entry and ns.Utils.Now() - entry.at > self.TTL then
        owners[petGUID] = nil
        return nil
    end
    return entry
end

-- Fallback: exactly one enemy hunter/warlock seen recently
function PetOwners:LikelyOwner()
    local candidate
    local cache = ns.EnemyCache
    for _, record in pairs(ns.db and ns.db.enemies or {}) do
        if record.guid and self.PET_CLASSES[record.class] and cache:SeenWithin(record.guid, self.LIKELY_WINDOW) then
            if candidate then return nil end -- more than one: no guess
            candidate = record
        end
    end
    return candidate
end

ns.Events:Register("HH_INITIALIZED", function()
    local Events = ns.Events
    Events:Register("NAME_PLATE_UNIT_ADDED", function(_, unit) PetOwners:ObservePetUnit(unit) end, OWNER)
    Events:Register("UPDATE_MOUSEOVER_UNIT", function() PetOwners:ObservePetUnit("mouseover") end, OWNER)
    Events:Register("PLAYER_TARGET_CHANGED", function()
        PetOwners:ObservePetUnit("target")
        PetOwners:ObserveOwnerUnit("target")
    end, OWNER)
    Events:Register("PLAYER_FOCUS_CHANGED", function() PetOwners:ObserveOwnerUnit("focus") end, OWNER)
end, OWNER)
