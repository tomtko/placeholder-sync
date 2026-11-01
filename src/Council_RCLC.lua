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
  }, "response", "after")
  if not ok then
    PS.Print("RCLootCouncil column could not be added: %s", tostring(err))
    return true
  end
  return true
end

local tries = 0
local function trySetup()
  if setup() then return end
  tries = tries + 1
  if tries < 10 then C_Timer.After(1, trySetup) end
end

NS.Council.RCLC = {
  addon = "RCLootCouncil",
  Start = function() tries = 0 C_Timer.After(0, trySetup) end,
}
