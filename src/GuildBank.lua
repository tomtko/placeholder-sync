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
local TAB_TIMEOUT = 3.0        -- seconds to wait for a tab before giving up on it
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

-- Returns the items, plus how many occupied slots had no item link yet (the client has not cached that
-- item: the link arrives a moment later, so the caller re-reads).
local function readTab(tab)
  local items = {}
  local unlinked = 0
  for slot = 1, MAX_SLOTS do
    local ok, link = pcall(GetGuildBankItemLink, tab, slot)
    if ok and not link then
      local ok2, texture = pcall(GetGuildBankItemInfo, tab, slot)
      if ok2 and texture then unlinked = unlinked + 1 end
    end
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
  return items, unlinked
end

local READ_RETRIES, READ_RETRY_DELAY = 6, 0.5

-- Read a tab, re-reading while some occupied slots still lack item links. done(items, partial).
local function readTabSettled(tab, done, attempt)
  local items, unlinked = readTab(tab)
  if unlinked > 0 and (attempt or 1) < READ_RETRIES then
    C_Timer.After(READ_RETRY_DELAY, function() readTabSettled(tab, done, (attempt or 1) + 1) end)
    return
  end
  done(items, unlinked > 0)
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
  local fresh = {
    guild = guild,
    realm = realm or ((GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()),
    by = NS.PlayerKey(),
    at = time(),
    money = GetGuildBankMoney() or 0,
    complete = complete and s.complete,
    tabs = tabs,
  }
  -- Tabs this character cannot view keep whatever an earlier scan (ours or a guildmate's, Sync.lua) held.
  NS.db.guildBank = NS.MergeBank(NS.db.guildBank, fresh)
  NS.pendingUpload = true

  local gb = NS.db.guildBank
  local hidden = 0
  for _, t in ipairs(tabs) do if not t.viewable then hidden = hidden + 1 end end
  local note = ""
  if not gb.complete then note = " (some items were still loading, open the bank again in a moment)" end
  if hidden > 0 then note = note .. (" (%d tab%s you cannot view, kept from earlier scans)"):format(hidden, hidden == 1 and "" or "s") end
  NS.Print("bank saved: %s, %d items in %d tabs%s. It uploads at your next /reload or logout.",
    NS.FormatMoney(gb.money), countItems(gb.tabs), #gb.tabs, note)
end

--- Merge two scans of the same guild bank tab by tab: a tab is taken from `inc` only when `inc` actually saw
--- it (viewable, answered) and saw it no earlier than what we hold. Money comes from the newer scan. `at`
--- is the newer scan time (it doubles as the sharing version), `by` the character who saw the newest tab.
--- Different guild or nothing held yet: `inc` as is.
function NS.MergeBank(cur, inc)
  if not inc then return cur end
  if not cur or type(cur.tabs) ~= "table" or cur.guild ~= inc.guild then return inc end
  local curBy, incBy, order, seen = {}, {}, {}, {}
  for _, t in ipairs(cur.tabs) do curBy[t.index] = t if not seen[t.index] then seen[t.index] = true order[#order + 1] = t.index end end
  for _, t in ipairs(inc.tabs or {}) do incBy[t.index] = t if not seen[t.index] then seen[t.index] = true order[#order + 1] = t.index end end
  table.sort(order)
  local function has(t, scanAt) return t and t.viewable and not t.missing and (t.at or scanAt or 0) end
  local tabs, complete, newestAt, newestBy = {}, true, 0, nil
  for _, i in ipairs(order) do
    local a, b = curBy[i], incBy[i]
    local aAt, bAt = has(a, cur.at), has(b, inc.at)
    local pick = a
    -- A partial read (item links still missing) only ever fills a gap; it never replaces a full read.
    if bAt and b.partial and aAt and not a.partial then pick = a
    elseif bAt and (not aAt or bAt >= aAt) then pick = b
    elseif not a then pick = b end
    if pick == a and a and b then a.name = b.name or a.name a.icon = b.icon or a.icon end
    tabs[#tabs + 1] = pick
    if not (pick and pick.viewable and not pick.missing and not pick.partial) then complete = false end
    local pickAt = pick and has(pick, pick == b and inc.at or cur.at)
    if pickAt and pickAt > newestAt then newestAt, newestBy = pickAt, pick.by or (pick == b and inc.by or cur.by) end
  end
  local newer = (inc.at or 0) >= (cur.at or 0) and inc or cur
  return {
    guild = inc.guild, realm = inc.realm or cur.realm,
    at = math.max(inc.at or 0, cur.at or 0),
    by = newestBy or newer.by,
    money = newer.money, complete = complete, tabs = tabs,
    sharedFrom = newer.sharedFrom, receivedAt = newer.receivedAt,
  }
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
    readTabSettled(t.index, function(items, partial)
      if not scan or scan.pos ~= pos then return end
      if partial then scan.complete = false end
      scan.results[t.index] = { index = t.index, name = t.name, icon = t.icon, viewable = true, items = items, partial = partial or nil, at = time(), by = NS.PlayerKey() }
      nextTab()
    end)
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
      -- No event: the client usually already had this tab from an earlier open. The read below is as good
      -- as any; it only counts as partial when item links are still missing.
      scan.waiting = nil
      local pos = scan.pos
      readTabSettled(t.index, function(items, partial)
        if not scan or scan.pos ~= pos then return end
        if partial then scan.complete = false end
        scan.results[t.index] = { index = t.index, name = t.name, icon = t.icon, viewable = true, items = items, partial = partial or nil, timedOut = true, at = time(), by = NS.PlayerKey() }
        nextTab()
      end)
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
      local items, unlinked = readTab(cur)
      if unlinked == 0 then
        t.items = items
        t.viewable = true
        t.missing = nil
        t.timedOut = nil
        t.partial = nil
        t.at = time()
        t.by = NS.PlayerKey()
      end
      break
    end
  end
  gb.money = GetGuildBankMoney() or gb.money
  gb.at = time()
  gb.by = NS.PlayerKey()
  NS.pendingUpload = true
end

-- Open / close --------------------------------------------------------------------------------------

local saidOtherGuild = false
local function onOpened()
  if frameOpen then return end
  if NS.ForThisGuild and not NS.ForThisGuild() then
    if not saidOtherGuild then
      saidOtherGuild = true
      NS.Print("this is %s's bank, not %s's: not recording it.", GetGuildInfo("player") or "another guild", NS.GuildName() or "our guild")
    end
    return
  end
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
