--[[
  "Sheet" column in RCLootCouncil's voting frame, through RCLC's Column API (RCVotingFrame:AddColumn, 3.x).
  Loading this file only defines functions. Core.lua calls NS.Council.RCLC.Start() at login, and only when
  C_AddOns.IsAddOnLoaded("RCLootCouncil") is true; without RCLC nothing here ever runs. Work happens only when
  RCLC redraws a cell; the tooltip handler is attached once per cell frame.
]]
local ADDON, NS = ...
local PS = NS
NS.Council = NS.Council or {}

local COL = ADDON .. "Sheet"
local rclc

local function currentItemLink(VF)
  local session = VF:GetCurrentSession()
  local lt = (rclc.GetLootTable and rclc:GetLootTable()) or (VF.GetLootTable and VF:GetLootTable())
  local entry = lt and session and lt[session]
  return entry and entry.link
end

local function onEnter(self)
  if self.psLink and self.psName then PS.Loot.ShowTooltip(self, self.psLink, self.psName) end
end
local function onLeave() GameTooltip:Hide() end

local VFref

local function cellUpdate(rowFrame, frame, data, cols, row, realrow, column, fShow, st, ...)
  if not fShow then return end
  local name = data[realrow] and data[realrow].name
  local link = VFref and currentItemLink(VFref)
  local standing = link and PS.Loot.Standing(link, name) or nil
  local text, r, g, b = PS.Loot.CellText(standing)
  frame.text:SetText(text)
  frame.text:SetTextColor(r, g, b)
  if data[realrow] and data[realrow].cols and data[realrow].cols[column] then
    data[realrow].cols[column].value = PS.Loot.SortValue(standing)
  end
  frame.psLink, frame.psName = link, name
  if not frame.psHooked then
    frame.psHooked = true
    frame:SetScript("OnEnter", onEnter)
    frame:SetScript("OnLeave", onLeave)
  end
end

local function setup()
  local Ace = LibStub and LibStub("AceAddon-3.0", true)
  rclc = Ace and Ace:GetAddon("RCLootCouncil", true)
  if not rclc then return false end
  local VF = rclc:GetModule("RCVotingFrame", true)
  if not VF or not VF.AddColumn or not VF.scrollCols then return false end
  VFref = VF
  if VF:GetColumnIndex(COL) then return true end
  local ok, err = pcall(VF.AddColumn, VF, {
    colName = COL, name = "Sheet", width = 58, align = "CENTER", DoCellUpdate = cellUpdate,
    comparesort = function(table, rowa, rowb, sortbycol)
      local a = table:GetRow(rowa).cols[sortbycol].value or 0
      local b = table:GetRow(rowb).cols[sortbycol].value or 0
      if a == b then return false end
      local col = table.cols[sortbycol]
      if col.sort == "dsc" then return a > b else return a < b end
    end,
  }, "roll", "after") -- last column, after Roll (where WowUtils puts its own)
  if not ok then
    PS.Print("RCLootCouncil column could not be added: %s", tostring(err))
    return true
  end
  return true
end

-- Raider side: RCLC's loot frame (the Need/Greed-style popup). Same hook WowUtils uses: every entry gets a
-- small label top right with "Wishlist" / "Owned" for the player themself, and a tooltip about them only.
local function paintEntry(entry)
  local f = entry and entry.frame
  if not f then return end
  if not f.psBadge then
    -- Under RCLC's "Time Left" line, right-aligned: the spot WowUtils uses for its sim value (its logo button sits
    -- at -5,-5, 16 px tall, and the value hangs 5 px below it), so neither text covers the timer.
    local b = CreateFrame("Button", nil, f)
    b:SetSize(90, 14)
    b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -5, -26)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.text:SetAllPoints(b)
    b.text:SetJustifyH("RIGHT")
    b:SetScript("OnEnter", function(self) if self.psLink then PS.Loot.SelfTooltip(self, self.psLink, PS.PlayerKey()) end end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.psBadge = b
  end
  local item = entry.item
  local link = type(item) == "table" and (item.link or item.itemLink) or item
  local text, r, g, b = PS.Loot.SelfText(link and PS.Loot.Standing(link, PS.PlayerKey()) or nil)
  f.psBadge.psLink = link
  f.psBadge.text:SetText(text or "")
  if text then f.psBadge.text:SetTextColor(r, g, b) end
  f.psBadge:SetShown(text ~= nil)
end

local function hookLootFrame()
  local LF = rclc and rclc:GetModule("RCLootFrame", true)
  local mgr = LF and LF.EntryManager
  if not mgr or type(mgr.GetEntry) ~= "function" or mgr.psHooked then return end
  mgr.psHooked = true
  hooksecurefunc(mgr, "GetEntry", function(self, item, isOurs)
    if isOurs then return end
    local ok, entry = pcall(self.GetEntry, self, item, true)
    if not ok or type(entry) ~= "table" or entry.psHooked then return end
    entry.psHooked = true
    if type(entry.Update) == "function" then hooksecurefunc(entry, "Update", function(e) pcall(paintEntry, e) end) end
    pcall(paintEntry, entry)
  end)
end

local tries = 0
local function trySetup()
  if setup() then pcall(hookLootFrame) return end
  tries = tries + 1
  if tries < 10 then C_Timer.After(1, trySetup) end
end

NS.Council.RCLC = {
  addon = "RCLootCouncil",
  Start = function() tries = 0 C_Timer.After(0, trySetup) end,
}
