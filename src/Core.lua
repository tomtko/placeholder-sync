--[[
  Core.lua: SavedVariables setup, slash command, and a check that the client has the API we use.

  Everything the bridge app uploads lives in one table, <AddonName>DB. The table name comes from the
  folder name, so renaming the addon (brand.json + build.py) renames the SavedVariables too.

    <AddonName>DB = {
      dbVersion  = 1,
      meta       = { addonVersion, client, interface, flavor, savedAt },
      guildBank  = { guild, realm, by, at, money, complete, tabs = { { index, name, icon, items = { ... } } } },
      characters = { [guid] = { name, realm, class, level, gear, professions, talents, ... } }, -- Character.lua
      roster     = { at, by, guild, total, online, members = { { name, rank, level, class, zone, ... } } }, -- Roster.lua
      lootShared = { rev, generatedAt, receivedAt, from, payload },          -- loot sheet copy from another officer (Sync.lua)
      lootAwards = { [uid] = { src, id, at, to, itemId, name, response, ... } }, -- council awards for the sheet's Loot Log (LootLog.lua)
      _apiCheck  = { "GetGuildBankItemLink", ... },                          -- API names missing on this client
      options    = { chat = false, autoscan = true, share = true },           -- /psync settings, account-wide
    }
]]
local ADDON, NS = ...
local SLASH = "/psync" -- @brand:slash

NS.ADDON = ADDON
NS.SLASH = SLASH
NS.DB_NAME = ADDON .. "DB"
NS.DB_VERSION = 1
-- The load-on-demand modules (<Addon>_RCLC, <Addon>_FLC) reach us through this global.
_G[ADDON] = NS

local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
NS.VERSION = (getMeta and getMeta(ADDON, "Version")) or "dev"

-- Chat output -------------------------------------------------------------------------------

-- Print: the reply to something the player typed. Always shown.
function NS.Print(msg, ...)
  if select("#", ...) > 0 then msg = msg:format(...) end
  print("|cff7fd5ff" .. ADDON .. ":|r " .. msg)
end

-- Notify: something that happened on its own (a scan saved, loot data received, a module that failed to start).
-- Quiet unless "/psync chat on"; the last few are kept so "/psync" can show them.
local notices = {}
function NS.Notify(msg, ...)
  if select("#", ...) > 0 then msg = msg:format(...) end
  table.insert(notices, 1, { at = time(), text = msg })
  notices[6] = nil
  if NS.Option("chat") then NS.Print(msg) end
end
function NS.Notices() return notices end

-- Settings ------------------------------------------------------------------------------------
-- Account-wide, in the SavedVariables. Missing keys take the default, so new settings need no migration.

local OPTION_DEFAULTS = { chat = false, autoscan = true, share = true, prompt = false }
local OPTION_HELP = {
  chat = "print a line when a bank scan is saved or loot data arrives",
  autoscan = "scan the guild bank by itself when you open it (off: only %s scan)",
  share = "share the loot sheet and bank scans with guildmates in game (a change applies after /reload)",
  prompt = "after a bank visit, offer a Reload button so the scan reaches the bridge right away (never reloads by itself)",
}
local OPTION_ORDER = { "chat", "autoscan", "share", "prompt" }

function NS.Option(key)
  local o = NS.db and NS.db.options
  if o and o[key] ~= nil then return o[key] end
  return OPTION_DEFAULTS[key]
end

function NS.SetOption(key, value)
  if not NS.db then return end
  if type(NS.db.options) ~= "table" then NS.db.options = {} end
  NS.db.options[key] = value
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

--- The home realm's numeric id from the player GUID ("Player-<realmId>-<hex>"). GetRealmID and the realm name
--- follow the server the character is on right now, which on WoW Forever changes when a ruleset moves it; the
--- GUID does not.
function NS.RealmId()
  local ok, guid = pcall(UnitGUID, "player")
  if not ok or type(guid) ~= "string" then return nil end
  return tonumber(guid:match("^Player%-(%d+)%-"))
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
  if type(db.options) ~= "table" then db.options = {} end
  if type(db.guildBank) ~= "table" then db.guildBank = nil end
  db.meta = clientMeta()
  NS.db = db
  return db
end

-- Identity of the logged-in character. Gear and the rest come later; this is enough for the
-- backend to know who runs the addon and who scanned the bank.
function NS.RecordCharacter(reason)
  local db = NS.db
  if not db then return end
  if reason ~= "identity" and NS.Character and NS.Character.Capture then
    local ok, rec = pcall(NS.Character.Capture, reason or "logout")
    if ok and rec then return end
  end
  local ok, guid = pcall(UnitGUID, "player")
  if not ok or not guid then return end
  local _, class = UnitClass("player")
  local name = UnitName("player")
  local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
  local rec = db.characters[guid] or {}
  rec.name = name
  rec.realm = realm
  rec.realmId = NS.RealmId()
  rec.class = class
  rec.level = UnitLevel("player")
  rec.guild = GetGuildInfo("player")
  rec.updatedAt = time()
  db.characters[guid] = rec
end

-- Which guild ---------------------------------------------------------------------------------------
-- The loot dataset carries the guild the server serves (the bridge folds it in from the server, and the in-game
-- sync hands it to every addon user). A character in any other guild, an officer's alt elsewhere or a test guild,
-- records nothing and shares nothing, so another guild's bank or awards never reach our server or sheet.

local function normGuild(s) return (tostring(s or ""):lower():gsub("[%s'’%-]", "")) end

function NS.GuildName()
  local c = NS.Loot and NS.Loot.Current()
  local g = c and c.payload and c.payload.guild
  return type(g) == "string" and g ~= "" and g or nil
end

function NS.ForThisGuild()
  local want = NS.GuildName()
  if not want then return true end -- nothing configured yet: a fresh install before any data arrived
  local mine = GetGuildInfo("player")
  return mine ~= nil and normGuild(mine) == normGuild(want)
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

-- Upload acknowledgement -------------------------------------------------------------------------------
-- The bridge writes <AddonName>_Data/Upload.lua after every upload of this install's file:
--   <AddonName>_Upload = { at, scanAt, status, gold, items, tabs, by, characters, appVersion }  (at, scanAt: unix seconds)
-- Like Data.lua it is read at login or /reload, so it describes the upload before this session started.

--- One sentence for /psync: did the last scan reach the server? nil when the bridge never wrote the file here.
function NS.LastUpload()
  local up = _G[ADDON .. "_Upload"]
  if type(up) ~= "table" or not up.at then return nil end
  local when = date("%d/%m %H:%M", up.at)
  if up.status ~= "stored" and up.status ~= "unchanged" then
    return ("last upload from this PC %s: %s"):format(when, tostring(up.error or up.status or "?"))
  end
  local gb = NS.db and NS.db.guildBank
  local scan = up.scanAt and date("%d/%m %H:%M", up.scanAt) or "no bank scan"
  if gb and up.scanAt and up.scanAt >= gb.at then
    return ("the scan from %s reached the server %s"):format(scan, when)
  elseif gb and up.scanAt then
    return ("the server has the scan from %s (uploaded %s); the %s scan goes at your next /reload or logout"):format(scan, when, date("%d/%m %H:%M", gb.at))
  end
  return ("last upload from this PC %s (%s)"):format(when, scan)
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
  local up = NS.LastUpload()
  if up then NS.Print(up .. ".") end
  local info = NS.Loot and NS.Loot.Info()
  if info then
    local how = info.source == "shared" and ("received in game from " .. (Ambiguate and Ambiguate(info.from or "?", "short") or tostring(info.from))) or "from the bridge app"
    NS.Print("loot sheet data: rev %s, %d items, %s %s.", tostring(info.rev), info.items, how, date("%d/%m %H:%M", info.writtenAt or 0))
  else NS.Print("no loot sheet data yet. The bridge writes it, or another officer's addon shares it in game (%s sync asks now).", SLASH) end
  local want = NS.GuildName()
  if want then
    if NS.ForThisGuild() then NS.Print("serving guild %s.", want)
    else NS.Print("this character is in %s, not %s: nothing is recorded or shared from here.", GetGuildInfo("player") or "no guild", want) end
  end
  if NS.Sync then NS.Print(NS.Sync.Status() .. ".") end
  if NS.NewerVersion then NS.Print("%s %s is out (you run %s): update it with the CurseForge app or from the install page.", ADDON, NS.NewerVersion, NS.VERSION) end
  if NS.LootLog then
    local n, week = NS.LootLog.Count()
    NS.Print("%d council award%s recorded for the Loot Log (%d this week).", n, n == 1 and "" or "s", week)
  end
  if NS.Character then NS.Print(NS.Character.Summary() .. ".") end
  if NS.Roster then NS.Print(NS.Roster.Summary() .. ".") end
  local missing = NS.db and NS.db._apiCheck or {}
  if #missing > 0 then NS.Print("missing API on this client: %s", table.concat(missing, ", ")) end
  local last = notices[1]
  if last then NS.Print("last notice %s: %s", date("%H:%M", last.at), last.text) end
  local set = {}
  for _, k in ipairs(OPTION_ORDER) do set[#set + 1] = k .. " " .. (NS.Option(k) and "on" or "off") end
  NS.Print("settings: %s.  %s help lists them.", table.concat(set, ", "), SLASH)
end

local function help()
  NS.Print("%s  |  %s scan  |  %s capture  |  %s sync  |  %s awards  |  %s forget  |  %s apicheck  |  %s reload", SLASH, SLASH, SLASH, SLASH, SLASH, SLASH, SLASH, SLASH)
  for _, k in ipairs(OPTION_ORDER) do
    NS.Print("%s %s on|off  (%s): %s", SLASH, k, NS.Option(k) and "on" or "off", OPTION_HELP[k]:format(SLASH))
  end
end

local function setOption(key, arg)
  local value
  if arg == "on" or arg == "yes" or arg == "1" then value = true
  elseif arg == "off" or arg == "no" or arg == "0" then value = false
  elseif arg == "" or arg == nil then value = not NS.Option(key)
  else NS.Print("%s %s on|off", SLASH, key) return end
  NS.SetOption(key, value)
  NS.Print("%s %s.%s", key, value and "on" or "off", (key == "share" and not value) and " Applies after /reload." or "")
  if key == "share" and value and NS.Sync and NS.Sync.Start then pcall(NS.Sync.Start) end
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
  elseif msg == "capture" then
    if NS.Character then
      local rec = NS.Character.Capture("manual")
      NS.Print(rec and (NS.Character.Summary() .. ". It uploads at your next /reload or logout.") or "could not capture (not logged in?).")
    end
  elseif msg == "awards" then
    if NS.LootLog then
      local n = NS.LootLog.Sweep() or 0
      local total = NS.LootLog.Count()
      NS.Print("%d new award%s picked up, %d recorded. They upload at your next /reload or logout.", n, n == 1 and "" or "s", total)
    end
  elseif msg == "" or msg == "status" then
    status()
  elseif OPTION_DEFAULTS[msg:match("^(%S+)") or ""] ~= nil then
    local key, arg = msg:match("^(%S+)%s*(.*)$")
    setOption(key, arg)
  else
    help()
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
      if not ok then NS.Notify("%s column failed to start: %s", key, tostring(err)) end
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
    pcall(NS.RecordCharacter, "identity") -- the full capture follows a few seconds later (Character.lua)
    if NS.Sync then
      local ok, err = pcall(NS.Sync.Start)
      if not ok then NS.Notify("sharing failed to start: %s", tostring(err)) end
    end
    if NS.LootLog then pcall(NS.LootLog.Start) end
    if NS.Character then pcall(NS.Character.Start) end
    if NS.Roster then pcall(NS.Roster.Start) end
    if #missing > 0 then
      NS.Notify("this client is missing %d API function(s): %s", #missing, table.concat(missing, ", "))
    end
  elseif event == "PLAYER_LOGOUT" then
    if NS.db then
      NS.db.meta = clientMeta()
      pcall(NS.RecordCharacter, "logout")
      if NS.LootLog then pcall(NS.LootLog.Sweep) end
    end
  end
end)
