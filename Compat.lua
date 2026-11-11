--[[ OldRaidFrames - Compat (1.15.9)

  Patch 1.15.9 shipped the retail-style AuraUtil (now in Blizzard_FrameXMLUtil).
  Its FindAuraByName is a thin dispatch:

      AuraUtil.FindAuraByName(name, unit, filter)
        -> C_UnitAuras.GetAuraDataBySpellName(unit, name, filter)

  ...but C_UnitAuras.GetAuraDataBySpellName didn't ship on the Classic Era
  client, so every FindAuraByName call errors with "attempt to call a nil
  value". That breaks any addon or library doing aura lookups by name
  through FindAuraByName.

  Fix: polyfill the missing provider method using GetAuraDataByIndex, which
  the client does have (Blizzard's own frames run on it). Repairing the
  provider rather than FindAuraByName means:
    - every caller is fixed: our own aura code, other addons' embedded
      libraries, and anything else using FindAuraByName,
    - the shim self-retires: the guard below makes it a no-op the moment a
      client hotfix supplies the real function.

  Behavior mirrors the retail API: returns the first matching AuraData
  table; name match is case-insensitive; nil filter behaves as "HELPFUL"
  (GetAuraDataByIndex applies that default itself).
]]--

local function findByName(unit, spellName, filter)
  if not unit or not spellName then return nil end
  local wanted = string.lower(spellName)
  local i = 1
  while true do
    local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
    if not aura then return nil end
    if aura.name and string.lower(aura.name) == wanted then return aura end
    i = i + 1
  end
end

if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex and not C_UnitAuras.GetAuraDataBySpellName then
  local ok = pcall(function()
    C_UnitAuras.GetAuraDataBySpellName = findByName
  end)
  -- Belt and suspenders: if the C_UnitAuras table ever refuses writes,
  -- repair FindAuraByName itself instead (same result, narrower reach).
  if (not ok or not C_UnitAuras.GetAuraDataBySpellName)
    and AuraUtil and AuraUtil.UnpackAuraData then
    AuraUtil.FindAuraByName = function(auraName, unit, filter)
      return AuraUtil.UnpackAuraData(findByName(unit, auraName, filter))
    end
  end
end
