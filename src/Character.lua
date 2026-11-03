--[[
  Character.lua: everything the game will tell us about the logged-in character, kept in <AddonName>DB.characters[guid]
  so the bridge uploads it and the sheet's roster, armory and raid-prep columns can fill themselves without the
  Blizzard web API (which has nothing for Forever characters at launch).

  Every read goes through pcall and a type check: a function the client lacks, or a value the client keeps secret,
  leaves the field nil and the function's name in rec.missing. Forever runs the Midnight engine with 1.x content,
  so both API families are tried where they differ (professions, talents, reputations, bags, honour).

  Captured at login (8 s in, so item links are cached), after gear / skill / talent / reputation / bag / money
  changes (10 s debounce, never in combat), and at logout. Each record:
    identity   name, realm, class, classId, race, raceFile, faction, level, guild, guildRank, guildRankIndex, updatedAt, reason
    gear       [slot] = { slot, name, id, link, itemString, ilvl, quality, enchant, gems = {...}, suffix }  (19 slots)
               avgIlvl, avgIlvlEquipped, missing enchant count is left to the sheet (it knows which slots count)
    professions retail: { name, skill, max, skillLine, icon } x up to 6 (primary 1-2, fishing, cooking, first aid,
               archaeology); classic: skills = every skill line { name, rank, max, header } (weapons, defence too)
    talents    Forever (trait trees): tabs = { { groupID, name, points } }, talents = { { tab, nodeID, spellID, name, rank, max, x, y } },
               unspent, source = "traits"; classic tabs: the same with tier/col, source = "tabs"; spec where the client has one
    quests     log = { { id, title, frequency (1 daily, 2 weekly), complete } }, flagged = { [questId] = done } for the ids
               the officers list in the loot data
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
  rec.level = first("UnitLevel", "player")
  rec.guild, rec.guildRank, rec.guildRankIndex = guildR[1], guildR[2], guildR[3]
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
-- Forever shows the classic three trees through the trait-tree API: one config, one tree, three display groups,
-- a node per talent with ranksPurchased; the spell behind a node names it. Classic clients keep the old tab API.

local function spellName(spellID)
  local info = resolve("C_Spell.GetSpellInfo")
  if info then
    local ok, d = pcall(info, spellID)
    if ok and type(d) == "table" then return plain(d.name) end
  end
  return first("GetSpellInfo", spellID)
end

local function traitConfig()
  local id = first("C_ClassTalents.GetActiveConfigID")
  if type(id) == "number" then return id end
  local group = first("C_SpecializationInfo.GetActiveSpecGroup")
  if type(group) == "number" then
    id = first("C_SpecializationInfo.GetCombatConfigIDForSpecGroup", group)
    if type(id) == "number" then return id end
  end
  return nil
end

local function traitTalents(t)
  local configID = traitConfig()
  if not configID then return false end
  local getConfig, getNodes, getNode = resolve("C_Traits.GetConfigInfo"), resolve("C_Traits.GetTreeNodes"), resolve("C_Traits.GetNodeInfo")
  if not (getConfig and getNodes and getNode) then return false end
  local ok, config = pcall(getConfig, configID)
  if not ok or type(config) ~= "table" or type(config.treeIDs) ~= "table" then return false end
  t.configID = configID
  t.tabs, t.talents = {}, {}
  local groupIndex = {}
  for _, treeID in ipairs(config.treeIDs) do
    local groupsFn = resolve("C_Traits.GetGroupDisplayInfoByTreeID")
    local okG, groups = false, nil
    if groupsFn then okG, groups = pcall(groupsFn, treeID) end   -- a conditional expression would keep only pcall's first return
    if okG and type(groups) == "table" then
      table.sort(groups, function(a, b) return (tonumber(a.order) or 0) < (tonumber(b.order) or 0) end)
      for _, g in ipairs(groups) do
        local tab = { groupID = plain(g.groupID), name = plain(g.displayName), order = plain(g.order), treeID = treeID }
        local curFn = resolve("C_Traits.GetGroupCurrencyInfo")
        local okC, cur = false, nil
        if curFn then okC, cur = pcall(curFn, configID, { g.groupID }) end
        local c = okC and type(cur) == "table" and cur[1]
        local ci = c and type(c.currencyInfos) == "table" and c.currencyInfos[1]
        if ci then tab.points = plain(ci.spent) end
        t.tabs[#t.tabs + 1] = tab
        groupIndex[tab.groupID] = #t.tabs
      end
    end
    local treeFn = resolve("C_Traits.GetTreeCurrencyInfo")
    local okT, tc = false, nil
    if treeFn then okT, tc = pcall(treeFn, configID, treeID, false) end
    if okT and type(tc) == "table" and type(tc[1]) == "table" then t.unspent = plain(tc[1].quantity) end
    local okN, nodes = pcall(getNodes, treeID)
    for _, nodeID in ipairs(okN and type(nodes) == "table" and nodes or {}) do
      local okI, node = pcall(getNode, configID, nodeID)
      if okI and type(node) == "table" and node.isVisible ~= false then
        local rank = math.max(tonumber(plain(node.ranksPurchased)) or 0, tonumber(plain(node.activeRank)) or 0)
        local entryID = type(node.activeEntry) == "table" and plain(node.activeEntry.entryID) or (type(node.entryIDs) == "table" and plain(node.entryIDs[1])) or nil
        local spellID
        if entryID then
          local okE, entry = pcall(resolve("C_Traits.GetEntryInfo") or error, configID, entryID)
          local defID = okE and type(entry) == "table" and plain(entry.definitionID)
          if defID then
            local okD, def = pcall(resolve("C_Traits.GetDefinitionInfo") or error, defID)
            if okD and type(def) == "table" then spellID = plain(def.spellID) end
          end
        end
        local groupID = type(node.groupIDs) == "table" and plain(node.groupIDs[1]) or nil
        t.talents[#t.talents + 1] = { tab = groupIndex[groupID], nodeID = nodeID, spellID = spellID, name = spellID and spellName(spellID) or nil,
          rank = rank, max = plain(node.maxRanks), x = plain(node.posX), y = plain(node.posY) }
      end
    end
  end
  -- points per tab from the nodes when the currency call gave nothing
  for i, tab in ipairs(t.tabs) do
    if tab.points == nil then
      local sum = 0
      for _, tl in ipairs(t.talents) do if tl.tab == i then sum = sum + (tl.rank or 0) end end
      tab.points = sum
    end
  end
  return #t.talents > 0
end

local function classicTalents(t)
  local tabs = first("GetNumTalentTabs")
  if type(tabs) ~= "number" or tabs == 0 then return false end
  t.tabs, t.talents = {}, {}
  for tab = 1, tabs do
    local info = call("GetTalentTabInfo", tab) or {}
    local name
    for _, v in ipairs(info) do if not name and type(v) == "string" and not v:find("\\") then name = v end end
    local points = 0
    local count = first("GetNumTalents", tab)
    for i = 1, (type(count) == "number" and count or 0) do
      local ti = call("GetTalentInfo", tab, i)
      if ti and type(ti[1]) == "string" then
        t.talents[#t.talents + 1] = { tab = tab, name = ti[1], tier = ti[3], col = ti[4], rank = ti[5], max = ti[6] }
        points = points + (tonumber(ti[5]) or 0)
      end
    end
    t.tabs[tab] = { name = name, points = points, raw = info }
  end
  t.activeGroup = first("GetActiveTalentGroup") or first("GetActiveSpecGroup")
  return true
end

local function talents(rec)
  local t = {}
  if traitTalents(t) then t.source = "traits"
  elseif classicTalents(t) then t.source = "tabs" end
  local specIndex = first("C_SpecializationInfo.GetSpecialization") or first("GetSpecialization")
  if type(specIndex) == "number" then
    local info = call("C_SpecializationInfo.GetSpecializationInfo", specIndex) or call("GetSpecializationInfo", specIndex)
    if info then t.spec = { index = specIndex, id = info[1], name = info[2], role = info[5] } end
  end
  if type(t.configID) == "number" then
    local s = first("C_Traits.GenerateImportString", t.configID)
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

-- Quests -----------------------------------------------------------------------------------------
-- Daily and weekly quests in the log with their state, and done/not-done for the quest ids the officers list in the
-- loot data (payload.weeklyQuests = { { id, name }, ... }), so the sheet can track weeklies without the quest in the log.

local function quests(rec)
  local q = { log = {} }
  local n = first("C_QuestLog.GetNumQuestLogEntries")
  if type(n) == "number" and resolve("C_QuestLog.GetInfo") then
    for i = 1, n do
      local ok, d = pcall(resolve("C_QuestLog.GetInfo"), i)
      if ok and type(d) == "table" and not d.isHeader then
        local freq = plain(d.frequency)
        if freq and freq ~= 0 then
          local done = first("C_QuestLog.IsComplete", plain(d.questID))
          q.log[#q.log + 1] = { id = plain(d.questID), title = plain(d.title), frequency = freq, complete = done == true or nil }
        end
      end
    end
  elseif resolve("GetQuestLogTitle") then
    local count = call("GetNumQuestLogEntries")
    for i = 1, (count and count[1]) or 0 do
      local r = call("GetQuestLogTitle", i)
      if r and r[1] and r[4] ~= true and r[7] and r[7] ~= 0 then
        q.log[#q.log + 1] = { id = r[8], title = r[1], frequency = r[7], complete = r[6] == 1 or r[6] == true or nil }
      end
    end
  else
    miss("C_QuestLog.GetInfo")
  end
  local c = NS.Loot and NS.Loot.Current()
  local list = c and c.payload and c.payload.weeklyQuests
  if type(list) == "table" and resolve("C_QuestLog.IsQuestFlaggedCompleted") then
    q.flagged = {}
    for _, w in ipairs(list) do
      local id = type(w) == "table" and tonumber(w.id) or tonumber(w)
      if id then q.flagged[tostring(id)] = first("C_QuestLog.IsQuestFlaggedCompleted", id) == true end
    end
  end
  rec.quests = q
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
  missing, absent = {}, {}
  local rec = {}
  local parts = { identity, gear, professions, talents, pvp, reputations, stats, bags, quests, lockouts, function(r) r.money = first("GetMoney") end }
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

local CHANGE_EVENTS = { "QUEST_LOG_UPDATE", "PLAYER_EQUIPMENT_CHANGED", "SKILL_LINES_CHANGED", "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE",
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
