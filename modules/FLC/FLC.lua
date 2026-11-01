--[[
  "Sheet" column in ForeverLoot's award window, through FL.AwardColumns.Register (the guild's fork of
  ForeverLoot). LoadOnDemand + LoadWith ForeverLoot: never loaded otherwise. The paint callback runs only when
  ForeverLoot repaints its rows; the tooltip callback only on hover.
]]
local THIS = ...
local parentName = THIS:gsub("_FLC$", "")
local PS = _G[parentName]
if not PS or not PS.Loot then return end

local function register()
  local FL = _G.ForeverLoot
  if not FL or not FL.AwardColumns or not FL.AwardColumns.Register then return false end
  FL.AwardColumns.Register({
    id = parentName .. "Sheet",
    label = "Sheet",
    width = 58,
    justify = "CENTER",
    paint = function(entry, item)
      local link = item and item.itemLink
      local standing = link and PS.Loot.Standing(link, entry and entry.name) or nil
      return PS.Loot.CellText(standing)
    end,
    tooltip = function(owner, entry, item)
      local link = item and item.itemLink
      if link and entry then PS.Loot.ShowTooltip(owner, link, entry.name) end
    end,
    sortValue = function(entry, item)
      local link = item and item.itemLink
      return PS.Loot.SortValue(link and PS.Loot.Standing(link, entry and entry.name) or nil)
    end,
  })
  return true
end

local tries = 0
local function tryRegister()
  if register() then return end
  tries = tries + 1
  if tries < 10 then C_Timer.After(1, tryRegister) end
end

if IsLoggedIn() then C_Timer.After(0, tryRegister)
else
  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_LOGIN")
  f:SetScript("OnEvent", function(self) self:UnregisterAllEvents() C_Timer.After(0, tryRegister) end)
end
