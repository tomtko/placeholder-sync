--[[
  Core.lua: SavedVariables setup, slash command, and a check that the client has the API we use.

  Everything the bridge app uploads lives in one table, <AddonName>DB. The table name comes from the
  folder name, so renaming the addon (brand.json + build.py) renames the SavedVariables too.

    <AddonName>DB = {
      dbVersion  = 1,
      meta       = { addonVersion, client, interface, flavor, savedAt },
      guildBank  = { guild, realm, by, at, money, complete, tabs = { { index, name, icon, items = { ... } } } },
      characters = { [guid] = { name, realm, class, level, updatedAt } },   -- identity only for now
      lootShared = { rev, generatedAt, receivedAt, from, payload },          -- loot sheet copy from another officer (Sync.lua)
      lootAwards = { [uid] = { src, id, at, to, itemId, name, response, ... } }, -- council awards for the sheet's Loot Log (LootLog.lua)
      _apiCheck  = { "GetGuildBankItemLink", ... },                          -- API names missing on this client
    }
]]
local ADDON, NS = ...
local SLASH = "/psync" -- @brand:slash

NS.ADDON = ADDON
NS.DB_NAME = ADDON .. "DB"
NS.DB_VERSION = 1
-- The load-on-demand modules (<Addon>_RCLC, <Addon>_FLC) reach us through this global.
_G[ADDON] = NS

local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
NS.VERSION = (getMeta and getMeta(ADDON, "Version")) or "dev"

-- Chat output -------------------------------------------------------------------------------

function NS.Print(msg, ...)
  if select("#", ...) > 0 then msg = msg:format(...) end
  print("|cff7fd5ff" .. ADDON .. ":|r " .. msg)
end

function NS.FormatMoney(copper)
  copper = tonumber(copper) or 0
  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local s = tostring(gold):reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
  if gold >= 100 then return s .. "g" end
  return s .. "g " .. silver .. "s"
end

-- Who is logged in ----------------------------------------------------------------------------

function NS.PlayerKey()
  local name = UnitName("player") or "Unknown"
  local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or ""
  realm = realm:gsub("%s+", "")
  return realm ~= "" and (name .. "-" .. realm) or name
end

-- SavedVariables --------------------------------------------------------------------------------

local function clientMeta()
  local version, build, _, interface = GetBuildInfo()
  local flavor
  if WOW_PROJECT_ID then
    flavor = tostring(WOW_PROJECT_ID)
  end
  return {
    addonVersion = NS.VERSION,
    client = version,
    build = build,
    interface = interface,
    flavor = flavor,
    savedAt = time(),
  }
end

function NS.InitDB()
  local db = _G[NS.DB_NAME]
  if type(db) ~= "table" then
    db = {}
    _G[NS.DB_NAME] = db
  end
  db.dbVersion = NS.DB_VERSION
  if type(db.characters) ~= "table" then db.characters = {} end
  if type(db._apiCheck) ~= "table" then db._apiCheck = {} end
  if type(db.guildBank) ~= "table" then db.guildBank = nil end
  db.meta = clientMeta()
  NS.db = db
  return db
end

-- Identity of the logged-in character. Gear and the rest come later; this is enough for the
-- backend to know who runs the addon and who scanned the bank.
function NS.RecordCharacter()
  local db = NS.db
  if not db then return end
  local ok, guid = pcall(UnitGUID, "player")
  if not ok or not guid then return end
  local _, class = UnitClass("player")
  local name = UnitName("player")
  local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
  local rec = db.characters[guid] or {}
  rec.name = name
  rec.realm = realm
  rec.class = class
  rec.level = UnitLevel("player")
  rec.guild = GetGuildInfo("player")
  rec.updatedAt = time()
  db.characters[guid] = rec
end

-- API check -----------------------------------------------------------------------------------
-- Forever is built on the Midnight client, but some globals only exist as C_ functions there.
-- We record what is missing so the backend (and /psync apicheck) can show it.

local REQUIRED = {
  "GetNumGuildBankTabs", "GetGuildBankTabInfo", "QueryGuildBankTab", "GetGuildBankItemInfo",
  "GetGuildBankItemLink", "GetGuildBankMoney", "GetCurrentGuildBankTab", "GetGuildInfo",
  "GetRealmName", "UnitName", "UnitGUID", "UnitClass", "UnitLevel", "ReloadUI", "C_Timer.NewTimer",
  "C_Timer.After",
  -- in-game sharing of the loot sheet (Sync.lua); missing ones switch sharing off, nothing else breaks
  "C_ChatInfo.SendAddonMessage", "C_ChatInfo.RegisterAddonMessagePrefix", "C_EncodingUtil.SerializeCBOR",
  "C_EncodingUtil.DeserializeCBOR", "C_EncodingUtil.CompressString", "C_EncodingUtil.DecompressString",
  "C_EncodingUtil.EncodeBase64", "C_EncodingUtil.DecodeBase64",
}

local function resolve(path)
  local v = _G
  for part in path:gmatch("[^%.]+") do
    if type(v) ~= "table" then return nil end
    v = v[part]
  end
  return v
end

function NS.ApiCheck()
  local missing = {}
  for _, name in ipairs(REQUIRED) do
    if type(resolve(name)) ~= "function" then missing[#missing + 1] = name end
  end
  if NS.db then NS.db._apiCheck = missing end
  return missing
end

-- Slash command ---------------------------------------------------------------------------------

local function status()
  local gb = NS.db and NS.db.guildBank
  if not gb then
    NS.Print("no guild bank scan yet. Open the guild bank and the scan runs by itself.")
  else
    local items = 0
    for _, tab in ipairs(gb.tabs or {}) do items = items + #(tab.items or {}) end
    NS.Print("last scan %s by %s%s: %s, %d items in %d tabs%s. %s",
      date("%d/%m %H:%M", gb.at), gb.by or "?", gb.sharedFrom and " (received in game)" or "", NS.FormatMoney(gb.money), items, #(gb.tabs or {}),
      gb.complete and "" or " (incomplete)",
      NS.pendingUpload and ("Uploads at your next /reload or logout (" .. SLASH .. " reload does it now).") or "Already written to disk.")
  end
  local info = NS.Loot and NS.Loot.Info()
  if info then
    local how = info.source == "shared" and ("received in game from " .. (Ambiguate and Ambiguate(info.from or "?", "short") or tostring(info.from))) or "from the bridge app"
    NS.Print("loot sheet data: rev %s, %d items, %s %s.", tostring(info.rev), info.items, how, date("%d/%m %H:%M", info.writtenAt or 0))
  else NS.Print("no loot sheet data yet. The bridge writes it, or another officer's addon shares it in game (%s sync asks now).", SLASH) end
  if NS.Sync then NS.Print(NS.Sync.Status() .. ".") end
  if NS.LootLog then
    local n, week = NS.LootLog.Count()
    NS.Print("%d council award%s recorded for the Loot Log (%d this week).", n, n == 1 and "" or "s", week)
  end
  local missing = NS.db and NS.db._apiCheck or {}
  if #missing > 0 then NS.Print("missing API on this client: %s", table.concat(missing, ", ")) end
end

local key = ADDON:upper():gsub("[^%w]", "")
_G["SLASH_" .. key .. "1"] = SLASH
SlashCmdList[key] = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "reload" then
    ReloadUI()
  elseif msg == "apicheck" then
    local missing = NS.ApiCheck()
    if #missing == 0 then NS.Print("all %d API functions present.", #REQUIRED)
    else NS.Print("missing: %s", table.concat(missing, ", ")) end
  elseif msg == "scan" then
    if NS.StartScan then NS.StartScan(true) end
  elseif msg == "sync" then
    if NS.Sync then NS.Sync.RequestNow() end
  elseif msg == "forget" then
    if NS.Sync then NS.Sync.Forget() end
  elseif msg == "debug" then
    if NS.Sync then NS.Sync.ToggleDebug() end
  elseif msg == "awards" then
    if NS.LootLog then
      local n = NS.LootLog.Sweep() or 0
      local total = NS.LootLog.Count()
      NS.Print("%d new award%s picked up, %d recorded. They upload at your next /reload or logout.", n, n == 1 and "" or "s", total)
    end
  elseif msg == "" or msg == "status" then
    status()
  else
    NS.Print("%s  |  %s reload  |  %s scan  |  %s sync  |  %s forget  |  %s apicheck", SLASH, SLASH, SLASH, SLASH, SLASH, SLASH)
  end
end

-- Loot council columns ---------------------------------------------------------------------------
-- Council_RCLC.lua and Council_FLC.lua only define functions. Their Start() runs once, at login, and only when
-- that council addon is loaded; a client without it never executes any of that code.

local started = {}

function NS.StartCouncilColumns()
  local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
  if not isLoaded or not NS.Council then return end
  for key, mod in pairs(NS.Council) do
    if not started[key] and mod.addon and isLoaded(mod.addon) then
      started[key] = true
      local ok, err = pcall(mod.Start)
      if not ok then NS.Print("%s column failed to start: %s", key, tostring(err)) end
    end
  end
end

-- Events --------------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == ADDON then
      NS.InitDB()
    elseif IsLoggedIn() and (arg1 == "RCLootCouncil" or arg1 == "ForeverLoot") then
      NS.StartCouncilColumns() -- a council addon loaded on demand after login
    end
  elseif event == "PLAYER_LOGIN" then
    if not NS.db then NS.InitDB() end
    NS.StartCouncilColumns()
    local missing = NS.ApiCheck()
    pcall(NS.RecordCharacter)
    if NS.Sync then
      local ok, err = pcall(NS.Sync.Start)
      if not ok then NS.Print("sharing failed to start: %s", tostring(err)) end
    end
    if NS.LootLog then pcall(NS.LootLog.Start) end
    if #missing > 0 then
      NS.Print("this client is missing %d API function(s): %s", #missing, table.concat(missing, ", "))
    end
  elseif event == "PLAYER_LOGOUT" then
    if NS.db then
      NS.db.meta = clientMeta()
      pcall(NS.RecordCharacter)
      if NS.LootLog then pcall(NS.LootLog.Sweep) end
    end
  end
end)
