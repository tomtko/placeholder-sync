--[[
  LootLog.lua: copies loot council awards into <AddonName>DB.lootAwards so the bridge uploads them and the bot
  appends them to the sheet's Loot Log (the same rows an officer's manual RCLC import would add, with the
  council's own id in the sheet's id column, so neither path ever doubles the other).

  Sources, both read on this PC only (no comms of our own):
    ForeverLoot   FL.LootCouncil.History, which ForeverLoot already syncs between officers; new rows arrive
                  through its Store "EntryApplied" callback, the rest by a sweep.
    RCLootCouncil RCLootCouncil:GetHistoryDB(), which the master looter broadcasts to the whole raid; new
                  rows arrive through RCLootHistory:OnHistoryReceived, the rest by a sweep.
  Sweeps run 15 s after login, every 10 minutes, and at logout, never in combat. Records older than 45 days
  are dropped here; the server keeps its own copy.

    lootAwards[uid] = { uid = "flc:<id>" | "rclc:<id>", src, id, at (unix), to, toClass, by, itemId, link, name,
                        response, responseID, isAwardReason, votes, note, instance, boss, datetime, gear1, gear2 }
]]
local ADDON, NS = ...
local Log = {}
NS.LootLog = Log

local KEEP_DAYS = 45
local started = false

local function store()
  if not NS.db then return nil end
  if type(NS.db.lootAwards) ~= "table" then NS.db.lootAwards = {} end
  return NS.db.lootAwards
end

local function itemName(link)
  return type(link) == "string" and link:match("%[(.-)%]") or nil
end

local function put(rec)
  local t = store()
  if not t or not rec.uid or t[rec.uid] then return false end
  rec.seenAt = time()
  t[rec.uid] = rec
  return true
end

local function prune()
  local t = store()
  if not t then return end
  local cutoff = time() - KEEP_DAYS * 86400
  for uid, rec in pairs(t) do
    if (tonumber(rec.at) or tonumber(rec.seenAt) or 0) < cutoff then t[uid] = nil end
  end
end

-- ForeverLoot -----------------------------------------------------------------------------------

local function fromFL(row)
  if type(row) ~= "table" or not row.id or not row.awardedTo or not row.itemLink then return false end
  local FL = _G.ForeverLoot
  local Store = FL and FL.Sync and FL.Sync.Store
  if Store and Store.IsTestId and Store.IsTestId(row.id) then return false end
  if row.test then return false end -- a /flc test session: never for the sheet
  local resp = type(row.responses) == "table" and row.responses[row.awardedTo] or nil
  local r = resp and resp.response
  local label = (type(r) == "table" and r.label) or (type(r) == "string" and r) or nil
  return put({
    uid = "flc:" .. tostring(row.id), src = "flc", id = tostring(row.id),
    at = tonumber(row.awardedAt) or time(),
    to = row.awardedTo, toClass = row.awardedToClass, by = row.awardedBy,
    itemId = tonumber(row.itemID) or (NS.Loot and NS.Loot.ItemId(row.itemLink)) or nil,
    link = row.itemLink, name = itemName(row.itemLink),
    response = row.reason or label, isAwardReason = (row.reason ~= nil) or nil,
    votes = resp and tonumber(resp.votes) or nil, note = resp and resp.note or nil,
    instance = row.instanceName, boss = row.boss,
  })
end

function Log.SweepFL()
  local FL = _G.ForeverLoot
  local hist = FL and FL.LootCouncil and FL.LootCouncil.History
  if type(hist) ~= "table" then return 0 end
  local n = 0
  for _, row in ipairs(hist) do if fromFL(row) then n = n + 1 end end
  return n
end

-- RCLootCouncil ---------------------------------------------------------------------------------

local function rcTime(e)
  local y, m, d = tostring(e.date or ""):match("^(%d%d%d%d)/(%d%d?)/(%d%d?)")
  if not y then
    local dd, mm, yy = tostring(e.date or ""):match("^(%d+)/(%d+)/(%d+)")
    if dd then d, m, y = dd, mm, (#yy == 2 and ("20" .. yy) or yy) end
  end
  if not y then return time() end
  local H, M, S = tostring(e.time or ""):match("^(%d+):(%d+):(%d+)")
  return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = tonumber(H) or 0, min = tonumber(M) or 0, sec = tonumber(S) or 0 })
end

local function fromRC(name, e)
  if type(e) ~= "table" or not e.lootWon or type(name) ~= "string" then return false end
  if e.responseID == "PL" or e.responseID == "PL_REJECT" then return false end -- personal loot, not an award
  local id = e.id and tostring(e.id) or (tostring(e.date) .. "|" .. tostring(e.time) .. "|" .. name .. "|" .. tostring(e.lootWon))
  return put({
    uid = "rclc:" .. id, src = "rclc", id = id, at = rcTime(e),
    to = name, toClass = e.class, by = e.owner, -- owner: whose bags the item was in, the closest RCLC has to "awarded by"
    itemId = (NS.Loot and NS.Loot.ItemId(e.lootWon)) or nil, link = e.lootWon, name = itemName(e.lootWon),
    response = e.response, responseID = e.responseID ~= nil and tostring(e.responseID) or nil,
    isAwardReason = e.isAwardReason or nil,
    votes = tonumber(e.votes), note = e.note, instance = e.instance, boss = e.boss,
    datetime = (e.date and e.time) and (tostring(e.date) .. " " .. tostring(e.time)) or nil,
    gear1 = e.itemReplaced1, gear2 = e.itemReplaced2,
  })
end

function Log.SweepRC()
  local rc = _G.RCLootCouncil
  local ok, db = pcall(function() return rc and rc.GetHistoryDB and rc:GetHistoryDB() end)
  if not ok or type(db) ~= "table" then return 0 end
  local n = 0
  for name, list in pairs(db) do
    if type(list) == "table" then
      for _, e in ipairs(list) do if fromRC(name, e) then n = n + 1 end end
    end
  end
  return n
end

-- Lifecycle -------------------------------------------------------------------------------------

function Log.Sweep()
  if InCombatLockdown() then return 0 end
  local n = Log.SweepFL() + Log.SweepRC()
  prune()
  return n
end

--- total recorded, and how many from the last 7 days
function Log.Count()
  local n, week, cutoff = 0, 0, time() - 7 * 86400
  for _, rec in pairs(store() or {}) do
    n = n + 1
    if (tonumber(rec.at) or 0) >= cutoff then week = week + 1 end
  end
  return n, week
end

local function hookFL()
  local FL = _G.ForeverLoot
  local Store = FL and FL.Sync and FL.Sync.Store
  if Log.flHooked or not Store or type(Store.RegisterCallback) ~= "function" then return end
  Log.flHooked = true
  Store.RegisterCallback(Log, "EntryApplied", function(_, entry, _, how)
    if how == "added" and type(entry) == "table" and entry.row then fromFL(entry.row) end
  end)
end

local function hookRC()
  local rc = _G.RCLootCouncil
  if Log.rcHooked or not rc or not rc.GetModule then return end
  local mod = rc:GetModule("RCLootHistory", true)
  if mod and type(mod.OnHistoryReceived) == "function" then
    Log.rcHooked = true
    hooksecurefunc(mod, "OnHistoryReceived", function() C_Timer.After(1, function() pcall(Log.SweepRC) end) end)
  end
end

function Log.Start()
  if started then return end
  started = true
  pcall(hookFL)
  pcall(hookRC)
  C_Timer.After(15, function() pcall(Log.Sweep) end)
  C_Timer.NewTicker(600, function()
    pcall(Log.Sweep)
    pcall(hookFL) -- a council addon that loaded late
    pcall(hookRC)
  end)
end
