--[[
  Character.lua: everything the game will tell us about the logged-in character, kept in <AddonName>DB.characters[guid]
  so the bridge uploads it and the sheet's roster, armory and raid-prep columns can fill themselves without the
  Blizzard web API (which has nothing for Forever characters at launch).

  Every read goes through pcall and a type check: a function the client lacks, or a value the client keeps secret,
  leaves the field nil and the function's name in rec.missing. Forever runs the Midnight engine with 1.x content,
  so both API families are tried where they differ (professions, talents, reputations, bags, honour).

  Captured at login (8 s in, so item links are cached), after gear / skill / talent / reputation / bag / money
  changes (10 s debounce, never in combat), and at logout. Each record:
    identity   name, realm, class, classId, race, raceFile, faction, sex, level, guild, guildRank, guildRankIndex,
               project (WOW_PROJECT_ID), flavor name, updatedAt, reason
    gear       [slot] = { slot, name, id, link, itemString, ilvl, quality, enchant, gems = {...}, suffix }  (19 slots)
               avgIlvl, avgIlvlEquipped, missing enchant count is left to the sheet (it knows which slots count)
    professions retail: { name, skill, max, skillLine, icon } x up to 6 (primary 1-2, fishing, cooking, first aid,
               archaeology); classic: skills = every skill line { name, rank, max, header } (weapons, defence too)
    talents    classic: tabs = { { name, points, raw = {...} } }, talents = { { tab, name, tier, col, rank, max } },
               activeGroup; retail: spec = { id, name, role }, exportString (C_Traits)
    pvp        honorableKills, dishonorableKills, rank, rankName, honorLevel
    reputations [i] = { id, name, standing, value, min, max, header, child, atWar }  (collapsed headers expanded and restored)
    stats      hp, mana, powerType, armor, resistances = { holy, fire, nature, frost, shadow, arcane }, strength, agility,
               stamina, intellect, spirit, attackPower, rangedAttackPower, spellPower, healingPower, meleeCrit,
               rangedCrit, spellCrit, meleeHit, spellHit, haste, defense
    bags       items = { [itemId] = count }, names = { [itemId] = name }, slots, free   (bags only, not the bank)
    money      copper
    lockouts   [i] = { name, id, reset, difficulty, difficultyName, locked, extended, raid, maxPlayers, encounters, progress }
    missing    { "GetProfessions", ... }
]]
local ADDON, NS = ...
local Char = {}
NS.Character = Char

local DEBOUNCE = 10
local LOGIN_DELAY = 8

local missing
local function miss(name) missing[#missing + 1] = name end

-- A plain value, or nil: secret values (Midnight) and anything that is not a string/number/boolean never reach the file.
local function plain(v)
  if issecretvalue and issecretvalue(v) then return nil end
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then return v end
  return nil
end

-- call("C_Item.GetDetailedItemLevelInfo", link) → the function's returns as a table of plain values, or nil (and a note) when absent / erroring.
local function resolve(path)
  local v = _G
  for part in path:gmatch("[^%.]+") do
    if type(v) ~= "table" then return nil end
    v = v[part]
  end
  return type(v) == "function" and v or nil
end
local absent = {}
local function call(path, ...)
  local fn = resolve(path)
  if not fn then
    if not absent[path] then absent[path] = true miss(path) end
    return nil
  end
  local r = { pcall(fn, ...) }
  if not r[1] then return nil end
  local out = {}
  for i = 2, #r do out[i - 1] = plain(r[i]) end
  return out
end
local function first(path, ...) local r = call(path, ...) return r and r[1] end

local function itemString(link)
  return type(link) == "string" and link:match("|H(item:[^|]+)|h") or nil
end

-- Identity --------------------------------------------------------------------------------------

local PROJECT_NAMES = { "MAINLINE", "CLASSIC", "BURNING_CRUSADE_CLASSIC", "WRATH_CLASSIC", "CATACLYSM_CLASSIC", "MISTS_CLASSIC", "CAMELOT" }
local function flavorName()
  for _, n in ipairs(PROJECT_NAMES) do
    local id = _G["WOW_PROJECT_" .. n]
    if id and id == WOW_PROJECT_ID then return n end
  end
  return nil
end

local function identity(rec)
  local name = first("UnitName", "player")
  local realm = first("GetNormalizedRealmName") or first("GetRealmName")
  local classR = call("UnitClass", "player") or {}
  local raceR = call("UnitRace", "player") or {}
  local guildR = call("GetGuildInfo", "player") or {}
  rec.name, rec.realm = name, realm
  rec.class, rec.className, rec.classId = classR[2], classR[1], classR[3]
  rec.race, rec.raceFile, rec.raceId = raceR[1], raceR[2], raceR[3]
  rec.faction = first("UnitFactionGroup", "player")
  rec.sex = first("UnitSex", "player")
  rec.level = first("UnitLevel", "player")
  rec.guild, rec.guildRank, rec.guildRankIndex = guildR[1], guildR[2], guildR[3]
  rec.project, rec.flavor = WOW_PROJECT_ID, flavorName()
end

-- Gear ------------------------------------------------------------------------------------------

local SLOTS = { [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest", [6] = "Waist", [7] = "Legs", [8] = "Feet",
  [9] = "Wrist", [10] = "Hands", [11] = "Finger 1", [12] = "Finger 2", [13] = "Trinket 1", [14] = "Trinket 2", [15] = "Back",
  [16] = "Main Hand", [17] = "Off Hand", [18] = "Ranged / Relic", [19] = "Tabard" }

local function gear(rec)
  local out = {}
  for slot = 1, 19 do
    local link = first("GetInventoryItemLink", "player", slot)
    if link then
      local s = itemString(link)
      local f = {}
      if s then for part in (s .. ":"):gmatch("([^:]*):") do f[#f + 1] = part end end -- f[1]="item", f[2]=id, f[3]=enchant, f[4..7]=gems, f[8]=suffix
      local gems = {}
      for i = 4, 7 do if f[i] and f[i] ~= "" and f[i] ~= "0" then gems[#gems + 1] = tonumber(f[i]) end end
      local ilvlR = call("C_Item.GetDetailedItemLevelInfo", link) or call("GetDetailedItemLevelInfo", link)
      out[slot] = {
        slot = slot, slotName = SLOTS[slot], link = link, itemString = s,
        name = link:match("%[(.-)%]"),
        id = tonumber(f[2]) or first("GetInventoryItemID", "player", slot),
        enchant = (tonumber(f[3]) or 0) ~= 0 and tonumber(f[3]) or nil,
        gems = #gems > 0 and gems or nil,
        suffix = (tonumber(f[8]) or 0) ~= 0 and tonumber(f[8]) or nil,
        ilvl = ilvlR and ilvlR[1] or nil,
        quality = first("GetInventoryItemQuality", "player", slot),
      }
    end
  end
  rec.gear = out
  local avg = call("GetAverageItemLevel")
  if avg then rec.avgIlvl, rec.avgIlvlEquipped = avg[1], avg[2] end
end

-- Professions and skills ----------------------------------------------------------------------------

local PROF_SLOTS = { "primary1", "primary2", "archaeology", "fishing", "cooking", "firstAid" }

local function professions(rec)
  local idx = call("GetProfessions")
  if idx then
    local out = {}
    for i, slotName in ipairs(PROF_SLOTS) do
      local n = idx[i]
      if type(n) == "number" then
        local info = call("GetProfessionInfo", n)
        if info and info[1] then out[slotName] = { name = info[1], icon = info[2], skill = info[3], max = info[4], skillLine = info[7], modifier = info[8] } end
      end
    end
    rec.professions = out
  end
  -- The classic skill window lists every skill line: professions, weapon skills, defence, languages. Collapsed
  -- headers hide their lines, so each one is opened and closed again.
  local n = first("GetNumSkillLines")
  if type(n) == "number" then
    local reopened = {}
    local i = 1
    while i <= (first("GetNumSkillLines") or 0) do
      local s = call("GetSkillLineInfo", i)
      if s and s[2] == true and s[3] == false then -- header, collapsed
        if first("ExpandSkillHeader", i) ~= nil or resolve("ExpandSkillHeader") then reopened[#reopened + 1] = i end
      end
      i = i + 1
    end
    local skills = {}
    for j = 1, first("GetNumSkillLines") or 0 do
      local s = call("GetSkillLineInfo", j)
      if s and s[1] then skills[#skills + 1] = { name = s[1], header = s[2] == true or nil, rank = s[4], modifier = s[6], max = s[7] } end
    end
    for k = #reopened, 1, -1 do call("CollapseSkillHeader", reopened[k]) end
    rec.skills = skills
  end
end

-- Talents ----------------------------------------------------------------------------------------

local function talents(rec)
  local t = {}
  local tabs = first("GetNumTalentTabs")
  if type(tabs) == "number" and tabs > 0 then
    t.tabs, t.talents = {}, {}
    for tab = 1, tabs do
      local info = call("GetTalentTabInfo", tab) or {}
      local name, points
      for _, v in ipairs(info) do if not name and type(v) == "string" and not v:find("\\") then name = v end end
      -- pointsSpent is the first integer after the name that is not an icon id: classic era returns (name, icon, points),
      -- wrath-style (id, name, desc, icon, points). Keep the raw returns so the backend can decide.
      local seenName = false
      for _, v in ipairs(info) do
        if v == name then seenName = true
        elseif seenName and points == nil and type(v) == "number" and v < 100 then points = v end
      end
      t.tabs[tab] = { name = name, points = points, raw = info }
      local count = first("GetNumTalents", tab)
      for i = 1, (type(count) == "number" and count or 0) do
        local ti = call("GetTalentInfo", tab, i)
        if ti and type(ti[1]) == "string" then
          t.talents[#t.talents + 1] = { tab = tab, name = ti[1], tier = ti[3], col = ti[4], rank = ti[5], max = ti[6] }
        end
      end
    end
    t.activeGroup = first("GetActiveTalentGroup") or first("GetActiveSpecGroup")
  end
  local specIndex = first("GetSpecialization")
  if type(specIndex) == "number" then
    local info = call("GetSpecializationInfo", specIndex)
    if info then t.spec = { index = specIndex, id = info[1], name = info[2], role = info[5] } end
  end
  local cfg = first("C_ClassTalents.GetActiveConfigID")
  if type(cfg) == "number" then
    local s = first("C_Traits.GenerateImportString", cfg)
    if type(s) == "string" and s ~= "" then t.exportString = s end
  end
  if next(t) then rec.talents = t end
end

-- PvP --------------------------------------------------------------------------------------------

local function pvp(rec)
  local p = {}
  local life = call("GetPVPLifetimeStats")
  if life then p.honorableKills, p.dishonorableKills = life[1], life[2] end
  local rank = first("UnitPVPRank", "player")
  if type(rank) == "number" then
    p.rank = rank
    local info = call("GetPVPRankInfo", rank, "player")
    if info then p.rankName, p.rankNumber = info[1], info[2] end
  end
  p.honorLevel = first("UnitHonorLevel", "player")
  if next(p) then rec.pvp = p end
end

-- Reputations ------------------------------------------------------------------------------------

local function reputations(rec)
  local out = {}
  if resolve("C_Reputation.GetFactionDataByIndex") then
    local expanded = {}
    local i = 1
    while i <= (first("C_Reputation.GetNumFactions") or 0) do
      local fn = resolve("C_Reputation.GetFactionDataByIndex")
      local ok, d = pcall(fn, i)
      if ok and type(d) == "table" and d.isHeader and d.isCollapsed then
        call("C_Reputation.ExpandFactionHeader", i)
        expanded[#expanded + 1] = i
      end
      i = i + 1
    end
    for j = 1, first("C_Reputation.GetNumFactions") or 0 do
      local ok, d = pcall(resolve("C_Reputation.GetFactionDataByIndex"), j)
      if ok and type(d) == "table" and plain(d.name) then
        out[#out + 1] = { id = plain(d.factionID), name = plain(d.name), standing = plain(d.reaction), value = plain(d.currentStanding),
          min = plain(d.currentReactionThreshold), max = plain(d.nextReactionThreshold), header = d.isHeader and true or nil,
          headerWithRep = d.isHeaderWithRep and true or nil, child = d.isChild and true or nil, atWar = d.atWarWith and true or nil }
      end
    end
    for k = #expanded, 1, -1 do call("C_Reputation.CollapseFactionHeader", expanded[k]) end
  elseif resolve("GetFactionInfo") then
    local expanded = {}
    local i = 1
    while i <= (first("GetNumFactions") or 0) do
      local f = call("GetFactionInfo", i)
      if f and f[9] == true and f[10] == true then call("ExpandFactionHeader", i) expanded[#expanded + 1] = i end
      i = i + 1
    end
    for j = 1, first("GetNumFactions") or 0 do
      local f = call("GetFactionInfo", j)
      if f and f[1] then
        out[#out + 1] = { id = f[14], name = f[1], standing = f[3], min = f[4], max = f[5], value = f[6], atWar = f[7] == true or nil,
          header = f[9] == true or nil, headerWithRep = f[11] == true or nil, child = f[13] == true or nil }
      end
    end
    for k = #expanded, 1, -1 do call("CollapseFactionHeader", expanded[k]) end
  else
    return
  end
  rec.reputations = out
end

-- Stats ------------------------------------------------------------------------------------------

local function stats(rec)
  local s = {}
  s.hp = first("UnitHealthMax", "player")
  s.powerType = first("UnitPowerType", "player")
  s.mana = first("UnitPowerMax", "player", 0)
  local armor = call("UnitArmor", "player") if armor then s.armor = armor[2] or armor[1] end
  local res, names = {}, { "holy", "fire", "nature", "frost", "shadow", "arcane" }
  for i, n in ipairs(names) do local r = call("UnitResistance", "player", i) if r then res[n] = r[2] or r[1] end end
  if next(res) then s.resistances = res end
  local statNames = { "strength", "agility", "stamina", "intellect", "spirit" }
  for i, n in ipairs(statNames) do local r = call("UnitStat", "player", i) if r then s[n] = r[2] or r[1] end end
  local ap = call("UnitAttackPower", "player") if ap then s.attackPower = (ap[1] or 0) + (ap[2] or 0) + (ap[3] or 0) end
  local rap = call("UnitRangedAttackPower", "player") if rap then s.rangedAttackPower = (rap[1] or 0) + (rap[2] or 0) + (rap[3] or 0) end
  local sp = 0
  for school = 2, 7 do local v = first("GetSpellBonusDamage", school) if type(v) == "number" and v > sp then sp = v end end
  if resolve("GetSpellBonusDamage") then s.spellPower = sp end
  s.healingPower = first("GetSpellBonusHealing")
  s.meleeCrit = first("GetCritChance")
  s.rangedCrit = first("GetRangedCritChance")
  local sc = 0
  for school = 2, 7 do local v = first("GetSpellCritChance", school) if type(v) == "number" and v > sc then sc = v end end
  if resolve("GetSpellCritChance") then s.spellCrit = sc end
  if CR_HIT_MELEE then s.meleeHit = first("GetCombatRatingBonus", CR_HIT_MELEE) end
  if CR_HIT_SPELL then s.spellHit = first("GetCombatRatingBonus", CR_HIT_SPELL) end
  if CR_HASTE_MELEE then s.haste = first("GetCombatRatingBonus", CR_HASTE_MELEE) end
  if CR_DEFENSE_SKILL then s.defense = first("GetCombatRatingBonus", CR_DEFENSE_SKILL) end
  for k, v in pairs(s) do if type(v) == "number" and v % 1 ~= 0 then s[k] = math.floor(v * 100 + 0.5) / 100 end end
  rec.stats = s
end

-- Bags -------------------------------------------------------------------------------------------

local function bags(rec)
  local numSlots = resolve("C_Container.GetContainerNumSlots") and "C_Container.GetContainerNumSlots" or (resolve("GetContainerNumSlots") and "GetContainerNumSlots")
  if not numSlots then miss("C_Container.GetContainerNumSlots") return end
  local items, names, slots, free = {}, {}, 0, 0
  local last = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4)
  for bag = 0, last do
    local n = first(numSlots, bag)
    if type(n) == "number" then
      slots = slots + n
      for slot = 1, n do
        local id, count, link
        local infoFn = resolve("C_Container.GetContainerItemInfo")
        if infoFn then
          local ok, d = pcall(infoFn, bag, slot)
          if ok and type(d) == "table" then id, count, link = plain(d.itemID), plain(d.stackCount), plain(d.hyperlink) end
        else
          local r = call("GetContainerItemInfo", bag, slot)
          if r then count, link, id = r[2], r[7], r[10] end
        end
        if not id and link then id = tonumber(link:match("item:(%d+)")) end
        if id then
          items[id] = (items[id] or 0) + (tonumber(count) or 1)
          if not names[id] and type(link) == "string" then names[id] = link:match("%[(.-)%]") end
        else
          free = free + 1
        end
      end
    end
  end
  rec.bags = { items = items, names = names, slots = slots, free = free }
end

-- Lockouts ----------------------------------------------------------------------------------------

local function lockouts(rec)
  local n = first("GetNumSavedInstances")
  if type(n) ~= "number" then return end
  local out = {}
  for i = 1, n do
    local r = call("GetSavedInstanceInfo", i)
    if r and r[1] then
      out[#out + 1] = { name = r[1], id = r[2], reset = r[3], difficulty = r[4], locked = r[5] == true or nil, extended = r[6] == true or nil,
        raid = r[8] == true or nil, maxPlayers = r[9], difficultyName = r[10], encounters = r[11], progress = r[12] }
    end
  end
  rec.lockouts = out
end

-- Capture -----------------------------------------------------------------------------------------

local capturing = false

--- Record everything now. reason: "login" | "change" | "logout" | "manual". Returns the record or nil.
function Char.Capture(reason)
  local db = NS.db
  if not db then return nil end
  local guid = first("UnitGUID", "player")
  if not guid then return nil end
  if type(db.characters) ~= "table" then db.characters = {} end
  capturing = true
  missing = {}
  local rec = {}
  local parts = { identity, gear, professions, talents, pvp, reputations, stats, bags, lockouts, function(r) r.money = first("GetMoney") end }
  local failed = {}
  for i, part in ipairs(parts) do
    local ok, err = pcall(part, rec)
    if not ok then failed[#failed + 1] = tostring(err) end
  end
  rec.missing = #missing > 0 and missing or nil
  rec.errors = #failed > 0 and failed or nil
  rec.updatedAt = time()
  rec.reason = reason
  rec.addonVersion = NS.VERSION
  local old = db.characters[guid]
  if old and old.firstSeen then rec.firstSeen = old.firstSeen else rec.firstSeen = rec.updatedAt end
  db.characters[guid] = rec
  capturing = false
  return rec
end

local timer
local function soon(reason)
  if timer then timer:Cancel() end
  timer = C_Timer.NewTimer(DEBOUNCE, function()
    timer = nil
    if InCombatLockdown() then soon(reason) return end
    pcall(Char.Capture, reason)
  end)
end

local CHANGE_EVENTS = { "PLAYER_EQUIPMENT_CHANGED", "SKILL_LINES_CHANGED", "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE",
  "ACTIVE_TALENT_GROUP_CHANGED", "TRAIT_CONFIG_UPDATED", "UPDATE_FACTION", "PLAYER_MONEY", "BAG_UPDATE_DELAYED",
  "UPDATE_INSTANCE_INFO", "PLAYER_LEVEL_UP", "PLAYER_GUILD_UPDATE" }

function Char.Start()
  local f = CreateFrame("Frame")
  for _, e in ipairs(CHANGE_EVENTS) do pcall(f.RegisterEvent, f, e) end
  f:SetScript("OnEvent", function(_, event)
    if capturing then return end -- our own header expansions fire UPDATE_FACTION / SKILL_LINES_CHANGED
    soon("change")
  end)
  C_Timer.After(LOGIN_DELAY, function()
    if InCombatLockdown() then soon("login") return end
    pcall(Char.Capture, "login")
  end)
  call("RequestRaidInfo") -- lockouts arrive with UPDATE_INSTANCE_INFO, which schedules a capture
end

--- One line for /psync.
function Char.Summary()
  local db = NS.db
  local guid = first("UnitGUID", "player")
  local rec = db and guid and db.characters and db.characters[guid]
  if not rec or not rec.gear then return "character data not captured yet" end
  local worn = 0
  for _ in pairs(rec.gear) do worn = worn + 1 end
  local reps = rec.reputations and #rec.reputations or 0
  local bagItems = 0
  if rec.bags then for _ in pairs(rec.bags.items) do bagItems = bagItems + 1 end end
  return ("character data: %d items worn%s, %d reputations, %d bag item types, %d API gaps, captured %s"):format(
    worn, rec.avgIlvlEquipped and (" (ilvl " .. math.floor(rec.avgIlvlEquipped) .. ")") or "", reps, bagItems,
    rec.missing and #rec.missing or 0, date("%d/%m %H:%M", rec.updatedAt or 0))
end
