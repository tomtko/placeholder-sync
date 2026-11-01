--[[
  LootData.lua: the officers' loot sheet, in game. The bridge writes Data.lua (see there); this file turns it into
  O(1) lookups for the loot council column: for an item and a candidate, are they an officer Prio pick, where do
  they stand among the people who need it, do they already have it.

  Performance: nothing runs at load except defining functions. The index is built once, lazily, the first time a
  council window asks, and never in combat (the call simply returns nothing until combat ends). After that every
  cell is a few table lookups; name resolution is memoised.

  payload (from placeholder-bot, src/lootdata/build.ts):
    items[ikey]   = { n = name, s = slot, b = boss, r = raid, id = itemId? }
    names[lname]  = ikey          lower-case item name → item key (the sheet rarely has item ids)
    chars[ckey]   = { n, p = player, c = class, sp = spec, rk = rank, st = status, bis = owned count, of = wanted count }
    needers[ikey] = { ckey, ... } sheet order: everyone who wants it and lacks it
    prio[ikey]    = { ckey, ... } officer Prio picks
    owned[ckey]   = { [ikey] = "date" }
  ikey = item id as a string, or "n:" .. lower-case name; ckey = lower-case character name without realm.
]]
local ADDON, NS = ...
local Loot = {}
NS.Loot = Loot

local GOLD = { 1, 0.82, 0 }
local GREEN = { 0.25, 1, 0.25 }
-- The Loot tab has six Prio columns; each rank gets its own colour so the column reads at a glance.
local PRIO_SLOTS = 6
local PRIO_COLOURS = {
  [1] = { 1, 0.82, 0 },        -- gold
  [2] = { 0.85, 0.88, 0.95 },  -- silver
  [3] = { 0.85, 0.55, 0.25 },  -- bronze
  [4] = { 0.55, 0.8, 1 },      -- light blue
  [5] = { 0.65, 0.65, 0.7 },   -- grey
  [6] = { 0.5, 0.5, 0.55 },    -- dim grey
}
local function prioColour(rank) return PRIO_COLOURS[rank] or PRIO_COLOURS[6] end
local function prioText(st) return "#" .. st.prio .. "/" .. math.max(PRIO_SLOTS, st.prioOf or 0) end
local WHITE = { 1, 1, 1 }
local GREY = { 0.55, 0.55, 0.55 }
local DIM = { 0.4, 0.4, 0.4 }

local index -- nil = not built, false = no data, table = built
local resolveCache = {}

local function rawData()
  return _G[ADDON .. "_Data"]
end

local function position(list)
  local map = {}
  for i, key in ipairs(list) do map[key] = i end
  return { map = map, list = list, n = #list }
end

local function build()
  local d = rawData()
  local p = d and d.payload
  if type(p) ~= "table" then index = false return end
  index = {
    rev = d.rev, writtenAt = d.writtenAt, generatedAt = p.generatedAt,
    items = p.items or {}, names = p.names or {}, chars = p.chars or {}, owned = p.owned or {},
    need = {}, prio = {}, byHalf = {},
  }
  for id, list in pairs(p.needers or {}) do index.need[id] = position(list) end
  for id, list in pairs(p.prio or {}) do index.prio[id] = position(list) end
  -- Forever names are "First Last"; some sources give one half. Map each half to the keys that contain it.
  for key in pairs(index.chars) do
    for part in key:gmatch("%S+") do
      local t = index.byHalf[part]
      if not t then t = {} index.byHalf[part] = t end
      t[#t + 1] = key
    end
  end
  wipe(resolveCache)
end

--- The index, or nil when there is no data yet or we are in combat and it is not built.
function Loot.Ensure()
  if index == nil then
    if InCombatLockdown() then return nil end
    build()
  end
  return index or nil
end

--- Drop the index (e.g. after the bridge wrote a new file and the officer reloaded: a reload rebuilds anyway).
function Loot.Reset()
  index = nil
  wipe(resolveCache)
end

function Loot.Info()
  local d = rawData()
  if not d or not d.payload then return nil end
  local n = 0
  for _ in pairs(d.payload.items or {}) do n = n + 1 end
  return { rev = d.rev, writtenAt = d.writtenAt, generatedAt = d.payload.generatedAt, items = n }
end

function Loot.ItemId(link)
  if type(link) == "number" then return link end
  if type(link) ~= "string" then return nil end
  return tonumber(link:match("item:(%d+)"))
end

local function cleanItemName(name)
  return (name:gsub("|A:.-|a", ""):gsub("|T.-|t", ""):gsub("%s+$", ""):gsub("^%s+", ""):gsub("%s+", " ")):lower()
end

--- Item link (or id, or plain name) → the dataset's item key, or nil when the sheet does not list it.
function Loot.ItemKey(linkOrId)
  local idx = Loot.Ensure()
  if not idx or not linkOrId then return nil end
  if type(linkOrId) == "number" then
    local k = tostring(linkOrId)
    return idx.items[k] and k or nil
  end
  local id = linkOrId:match("item:(%d+)")
  if id and idx.items[id] then return id end
  local name = linkOrId:match("|h%[(.-)%]|h") or linkOrId
  return idx.names[cleanItemName(name)]
end

--- "Name-Realm" or "First Last" → the sheet's character key, or nil when the sheet does not know them.
function Loot.ResolveKey(name)
  if type(name) ~= "string" or name == "" then return nil end
  local cached = resolveCache[name]
  if cached ~= nil then return cached or nil end
  local idx = Loot.Ensure()
  if not idx then return nil end
  local key = name:lower():gsub("%-.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  local found = idx.chars[key] and key or nil
  if not found then
    local parts = {}
    for part in key:gmatch("%S+") do parts[#parts + 1] = part end
    if #parts == 1 then
      local hits = idx.byHalf[parts[1]]
      if hits and #hits == 1 then found = hits[1] end
    end
  end
  resolveCache[name] = found or false
  return found
end

--- Where a candidate stands for an item (link, id or key). nil when there is no sheet data at all.
--- { key, char, item, prio, prioOf, need, needOf, has }
function Loot.Standing(linkOrKey, name)
  local idx = Loot.Ensure()
  if not idx or not linkOrKey then return nil end
  local id = idx.items[linkOrKey] and linkOrKey or Loot.ItemKey(linkOrKey)
  if not id then return { key = Loot.ResolveKey(name), item = nil, char = nil, unknownItem = true } end
  local key = Loot.ResolveKey(name)
  local st = { key = key, item = idx.items[id], char = key and idx.chars[key] or nil }
  if key then
    local pr = idx.prio[id]
    if pr and pr.map[key] then st.prio, st.prioOf = pr.map[key], pr.n end
    local nd = idx.need[id]
    if nd and nd.map[key] then st.need, st.needOf = nd.map[key], nd.n end
    local owned = idx.owned[key]
    if owned and owned[id] then st.has = owned[id] end
  end
  return st
end

--- Short cell text plus colour.
function Loot.CellText(st)
  if not st then return "", unpack(DIM) end
  if st.unknownItem then return "\226\128\148", unpack(DIM) end
  if not st.char then return "?", unpack(DIM) end
  if st.prio then return prioText(st), unpack(prioColour(st.prio)) end
  if st.has then return "has", unpack(GREY) end
  if st.need then return "Wants", unpack(GREEN) end
  return "\226\128\148", unpack(DIM) -- em dash: not on their list
end

--- A number that sorts best-first (bigger is better): officer picks in order, then everyone who wants it,
--- then people who already have it. Wishlist order is not a ranking, so all "Wants" sort equal.
function Loot.SortValue(st)
  if not st or st.unknownItem or not st.char then return -1 end
  if st.prio then return 10000 - st.prio end
  if st.need then return 1000 end
  if st.has then return 1 end
  return 0
end

local function ago(unix)
  if not unix then return "unknown" end
  local s = time() - unix
  if s < 90 then return "just now" end
  if s < 5400 then return math.floor(s / 60 + 0.5) .. " min ago" end
  if s < 129600 then return math.floor(s / 3600 + 0.5) .. " h ago" end
  return math.floor(s / 86400 + 0.5) .. " days ago"
end

--- Tooltip lines: { { text, r, g, b }, ... } or nil.
function Loot.TooltipLines(st, name)
  local idx = Loot.Ensure()
  if not idx then return nil end
  local lines = {}
  local function add(text, c) lines[#lines + 1] = { text, c[1], c[2], c[3] } end
  local item = st and st.item
  add(item and item.n or "Item not on the loot sheet", WHITE)
  if item and (item.s or item.b) then add((item.s or "") .. (item.b and ("  ·  " .. item.b) or ""), GREY) end
  add(" ", WHITE)
  if st and st.unknownItem then
    add("The loot sheet does not list this item.", GREY)
  elseif not st or not st.char then
    add((name or "This character") .. " is not on the loot sheet.", GREY)
  else
    local c = st.char
    add(c.n .. "  (" .. (c.p or "?") .. ")", WHITE)
    add((c.rk or "") .. (c.st and c.st ~= "" and ("  ·  " .. c.st) or "") .. (c.sp and c.sp ~= "" and ("  ·  " .. c.sp) or ""), GREY)
    add(" ", WHITE)
    if st.prio then add("Officer Prio pick " .. prioText(st), prioColour(st.prio)) end
    if st.has then add("Already has it  (Loot Log " .. tostring(st.has) .. ")", GREY)
    elseif st.need then add("Wants it" .. (st.needOf > 1 and ("  (one of " .. st.needOf .. " who still need it)") or ""), GREEN)
    elseif not st.prio then add("Not on their list", GREY) end
    if c.of and c.of > 0 then add("BiS progress " .. (c.bis or 0) .. " / " .. c.of, GREY) end
  end
  return lines
end

--- The other people in line for an item (top n), for the tooltip's second half.
function Loot.NeederLines(linkOrKey, n)
  local idx = Loot.Ensure()
  if not idx then return {} end
  local out = {}
  local ikey = idx.items[linkOrKey] and linkOrKey or Loot.ItemKey(linkOrKey)
  if not ikey then return out end
  local pr = idx.prio[ikey]
  if pr and pr.n > 0 then
    out[#out + 1] = { "Officer Prio:", GOLD[1], GOLD[2], GOLD[3] }
    for i, key in ipairs(pr.list) do
      local c = idx.chars[key]
      local col = prioColour(i)
      out[#out + 1] = { "  #" .. i .. "  " .. (c and c.n or key), col[1], col[2], col[3] }
    end
  end
  local nd = idx.need[ikey]
  if nd and nd.n > 0 then
    out[#out + 1] = { "Want it (" .. nd.n .. "):", WHITE[1], WHITE[2], WHITE[3] }
    for i = 1, math.min(n or 5, nd.n) do
      local c = idx.chars[nd.list[i]]
      out[#out + 1] = { "  " .. (c and c.n or nd.list[i]) .. (c and c.rk and ("  " .. c.rk) or ""), GREY[1], GREY[2], GREY[3] }
    end
    if nd.n > (n or 5) then out[#out + 1] = { "  …", DIM[1], DIM[2], DIM[3] } end
  end
  out[#out + 1] = { "Sheet data from " .. ago(idx.generatedAt and math.floor(idx.generatedAt / 1000) or nil) .. ", written " .. ago(idx.writtenAt), DIM[1], DIM[2], DIM[3] }
  return out
end

--- Fill GameTooltip for a cell. Call from OnEnter.
function Loot.ShowTooltip(owner, linkOrKey, name)
  local st = Loot.Standing(linkOrKey, name)
  local lines = Loot.TooltipLines(st, name)
  if not lines then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  for _, l in ipairs(lines) do GameTooltip:AddLine(l[1], l[2], l[3], l[4], true) end
  GameTooltip:AddLine(" ")
  for _, l in ipairs(Loot.NeederLines(linkOrKey, 5)) do GameTooltip:AddLine(l[1], l[2], l[3], l[4], true) end
  GameTooltip:Show()
end
