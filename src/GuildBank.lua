--[[
  GuildBank.lua: records the guild bank into <AddonName>DB.guildBank whenever the bank is opened.

  The bank API only answers for a tab after QueryGuildBankTab(tab) has been acknowledged by
  GUILDBANKBAGSLOTS_CHANGED, so the scan walks the viewable tabs one at a time. While the window stays
  open, the tab the officer is looking at is re-read on every change, so moving items is captured too.
  The game only writes SavedVariables on /reload or logout, so the bridge app picks the scan up then; the
  addon just says so once in chat (no prompt), and /psync reload is there for anyone who wants it now.
]]
local ADDON, NS = ...

local MAX_SLOTS = MAX_GUILDBANK_SLOTS_PER_TAB or 98
local TAB_TIMEOUT = 2.0        -- seconds to wait for a tab before giving up on it
local SETTLE = 0.15            -- small delay so all slot data for a tab has arrived

local frameOpen = false
local scan                     -- in-progress scan state, nil when idle
NS.pendingUpload = false       -- true once a scan finished and no /reload has happened yet

-- Items -------------------------------------------------------------------------------------------

local QUALITY_BY_HEX = {
  ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2, ["0070dd"] = 3, ["a335ee"] = 4,
  ["ff8000"] = 5, ["e6cc80"] = 6, ["00ccff"] = 7,
}

local function qualityFromLink(link)
  local q = link:match("|cnIQ(%d+):")
  if q then return tonumber(q) end
  local hex = link:match("|cff(%x%x%x%x%x%x)")
  return hex and QUALITY_BY_HEX[hex:lower()] or nil
end

-- Item names in links can carry UI markup, e.g. a crafting-quality icon: "Azeroot |A:Professions-ChatIcon-Quality-12-Tier1:17:15::1|a".
-- We keep the plain name and record the crafting tier (1-3) separately.
local function parseLink(link)
  local id = tonumber(link:match("|Hitem:(%d+)"))
  local name = link:match("|h%[(.-)%]|h") or ""
  local tier = tonumber(name:match("Quality%-%d+%-Tier(%d)"))
  name = name:gsub("|A:.-|a", ""):gsub("|T.-|t", ""):gsub("%s+$", "")
  return id, name, tier
end

local function readTab(tab)
  local items = {}
  for slot = 1, MAX_SLOTS do
    local ok, link = pcall(GetGuildBankItemLink, tab, slot)
    if ok and link then
      local _, texture, count, _, _, quality = pcall(GetGuildBankItemInfo, tab, slot)
      local id, name, tier = parseLink(link)
      items[#items + 1] = {
        slot = slot,
        id = id,
        name = name,
        tier = tier,
        count = tonumber(count) or 1,
        quality = tonumber(quality) or qualityFromLink(link),
        icon = tonumber(texture) or nil,
        link = link,
      }
    end
  end
  return items
end

local function countItems(tabs)
  local n = 0
  for _, t in ipairs(tabs) do n = n + #(t.items or {}) end
  return n
end

-- Scan ----------------------------------------------------------------------------------------------

local function finishScan(complete)
  if not scan then return end
  local s = scan
  scan = nil
  if s.timer then s.timer:Cancel() end

  local tabs = {}
  for _, t in ipairs(s.tabs) do
    tabs[#tabs + 1] = s.results[t.index] or { index = t.index, name = t.name, icon = t.icon, viewable = t.viewable, items = {}, missing = true }
  end

  local guild, _, _, realm = GetGuildInfo("player")
  NS.db.guildBank = {
    guild = guild,
    realm = realm or ((GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()),
    by = NS.PlayerKey(),
    at = time(),
    money = GetGuildBankMoney() or 0,
    complete = complete and s.complete,
    tabs = tabs,
  }
  NS.pendingUpload = true

  local gb = NS.db.guildBank
  NS.Print("bank saved: %s, %d items in %d tabs%s. It uploads at your next /reload or logout.",
    NS.FormatMoney(gb.money), countItems(tabs), #tabs, gb.complete and "" or " (some tabs did not answer)")
end

local nextTab

local function tabAnswered()
  if not scan or not scan.waiting then return end
  local t = scan.tabs[scan.pos]
  if scan.timer then scan.timer:Cancel() end
  scan.waiting = nil
  local pos = scan.pos
  -- Give the remaining slot updates a moment to land, then read the whole tab.
  C_Timer.After(SETTLE, function()
    if not scan or scan.pos ~= pos then return end
    scan.results[t.index] = { index = t.index, name = t.name, icon = t.icon, viewable = true, items = readTab(t.index) }
    nextTab()
  end)
end

nextTab = function()
  if not scan then return end
  scan.pos = scan.pos + 1
  local t = scan.tabs[scan.pos]
  if not t then
    finishScan(true)
    return
  end
  if not t.viewable then
    scan.results[t.index] = { index = t.index, name = t.name, icon = t.icon, viewable = false, items = {} }
    nextTab()
    return
  end
  scan.waiting = t.index
  local ok = pcall(QueryGuildBankTab, t.index)
  if not ok then
    scan.complete = false
    scan.results[t.index] = { index = t.index, name = t.name, icon = t.icon, viewable = true, items = {}, error = true }
    nextTab()
    return
  end
  scan.timer = C_Timer.NewTimer(TAB_TIMEOUT, function()
    if scan and scan.waiting == t.index then
      scan.complete = false
      scan.waiting = nil
      scan.results[t.index] = { index = t.index, name = t.name, icon = t.icon, viewable = true, items = readTab(t.index), timedOut = true }
      nextTab()
    end
  end)
end

function NS.StartScan(manual)
  if not frameOpen then
    if manual then NS.Print("open the guild bank first.") end
    return
  end
  if scan then
    if manual then NS.Print("a scan is already running.") end
    return
  end
  local n = GetNumGuildBankTabs() or 0
  local tabs = {}
  for i = 1, n do
    local ok, name, icon, isViewable = pcall(GetGuildBankTabInfo, i)
    if ok then
      tabs[#tabs + 1] = { index = i, name = name or ("Tab " .. i), icon = tonumber(icon) or icon, viewable = isViewable and true or false }
    end
  end
  scan = { tabs = tabs, pos = 0, results = {}, complete = true, waiting = nil }
  if n == 0 then
    finishScan(true)
  else
    nextTab()
  end
end

-- Re-read the tab being viewed when its contents change while the window is open.
local function viewedTabChanged()
  local gb = NS.db and NS.db.guildBank
  if not gb or not frameOpen then return end
  local ok, cur = pcall(GetCurrentGuildBankTab)
  if not ok or not cur or cur < 1 then return end
  for _, t in ipairs(gb.tabs) do
    if t.index == cur then
      t.items = readTab(cur)
      t.viewable = true
      t.missing = nil
      t.timedOut = nil
      break
    end
  end
  gb.money = GetGuildBankMoney() or gb.money
  gb.at = time()
  gb.by = NS.PlayerKey()
  NS.pendingUpload = true
end

-- Open / close --------------------------------------------------------------------------------------

local function onOpened()
  if frameOpen then return end
  frameOpen = true
  -- Let the Blizzard frame issue its own first query, then start ours.
  C_Timer.After(0.3, function() if frameOpen then NS.StartScan(false) end end)
end

local function onClosed()
  if not frameOpen then return end
  frameOpen = false
  if scan then finishScan(false) end
  if NS.db and NS.db.guildBank then
    NS.db.guildBank.money = GetGuildBankMoney() or NS.db.guildBank.money
  end
  -- Tell the other addon users (Sync.lua): whoever runs the bridge picks the scan up from here.
  if NS.pendingUpload and NS.Sync and NS.Sync.Changed then NS.Sync.Changed() end
end

local GUILD_BANKER = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker

local frame = CreateFrame("Frame")
frame:RegisterEvent("GUILDBANKFRAME_OPENED")
frame:RegisterEvent("GUILDBANKFRAME_CLOSED")
frame:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
frame:RegisterEvent("GUILDBANK_UPDATE_MONEY")
if GUILD_BANKER then
  frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
  frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
end
frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "GUILDBANKFRAME_OPENED" then
    onOpened()
  elseif event == "GUILDBANKFRAME_CLOSED" then
    onClosed()
  elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
    if arg1 == GUILD_BANKER then onOpened() end
  elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    if arg1 == GUILD_BANKER then onClosed() end
  elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
    if scan and scan.waiting then
      tabAnswered()
    elseif not scan then
      viewedTabChanged()
    end
  elseif event == "GUILDBANK_UPDATE_MONEY" then
    local gb = NS.db and NS.db.guildBank
    if gb and frameOpen then
      gb.money = GetGuildBankMoney() or gb.money
      NS.pendingUpload = true
    end
  end
end)
