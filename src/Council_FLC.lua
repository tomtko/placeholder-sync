--[[
  "Sheet" column in ForeverLoot's award window, through FL.AwardColumns.Register (the guild's fork of
  ForeverLoot). Loading this file only defines functions. Core.lua calls NS.Council.FLC.Start() at login, and
  only when C_AddOns.IsAddOnLoaded("ForeverLoot") is true; without ForeverLoot nothing here ever runs. The paint
  callback runs only when ForeverLoot repaints its rows; the tooltip callback only on hover.
]]
local ADDON, NS = ...
local PS = NS
NS.Council = NS.Council or {}
local parentName = ADDON

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

NS.Council.FLC = {
  addon = "ForeverLoot",
  Start = function() tries = 0 C_Timer.After(0, tryRegister) end,
}
