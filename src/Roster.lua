--[[
  Roster.lua: the whole in-game guild roster, kept in <AddonName>DB.roster so the bridge uploads it and the sheet's
  Levelling tab can follow every member, not only those who run the addon. Captured from GUILD_ROSTER_UPDATE (at most
  once a minute) and at logout. Officer notes are never read: raiders run this addon too.

    roster = { at, by, guild, realmId, total, online, complete,
               members = { { name, rank, rankIndex, level, class, zone, online, note, guid, lastOnline } } }

  name is "Name-Realm" as the roster gives it, class the file name ("WARLOCK"), lastOnline hours since the member was
  last on (nil while online). complete is false when the client listed fewer members than GetNumGuildMembers counts.

  Level-ups, in <AddonName>DB.rosterDings = { { name, from, to, at, own } }: each copy is compared with the one before
  it, and a level that went up since a copy at most LIVE_GAP seconds old is logged with this copy's time, so a ding
  is timed to about a minute while anyone running the addon is online. Your own character's PLAYER_LEVEL_UP is logged
  to the second (own = true). An older previous copy (the last session's) proves nothing about when: the backend
  times those from the scan instead. Kept for 14 days.
]]
local ADDON, NS = ...
local Roster = {}
NS.Roster = Roster

local THROTTLE = 60
local LIVE_GAP = 600
local KEEP_DINGS = 14 * 86400
local lastAt = 0
local pending = false

local function logDing(name, from, to, at, own)
  local log = NS.db.rosterDings
  if type(log) ~= "table" then log = {} NS.db.rosterDings = log end
  for _, d in ipairs(log) do
    if d.name == name and d.to == to then
      if at < d.at then d.at, d.own = at, own or d.own end
      return
    end
  end
  log[#log + 1] = { name = name, from = from, to = to, at = at, own = own or nil }
  local cutoff = at - KEEP_DINGS
  for i = #log, 1, -1 do if (log[i].at or 0) < cutoff then table.remove(log, i) end end
  while #log > 2000 do table.remove(log, 1) end
end

local function plain(v)
  if issecretvalue and issecretvalue(v) then return nil end
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then return v end
  return nil
end

-- Hours since the member was last online, from GetGuildRosterLastOnline (years, months, days, hours); nil while online.
local function hoursOffline(i)
  if not GetGuildRosterLastOnline then return nil end
  local ok, y, mo, d, h = pcall(GetGuildRosterLastOnline, i)
  if not ok or (y == nil and mo == nil and d == nil and h == nil) then return nil end
  return (((plain(y) or 0) * 12 + (plain(mo) or 0)) * 30 + (plain(d) or 0)) * 24 + (plain(h) or 0)
end

function Roster.Capture()
  if not NS.db or not IsInGuild or not IsInGuild() then return nil end
  local guild = GetGuildInfo and plain((GetGuildInfo("player")))
  local total, online = 0, 0
  if GetNumGuildMembers then
    local ok, t, o = pcall(GetNumGuildMembers)
    if ok then total, online = plain(t) or 0, plain(o) or 0 end
  end
  if not guild or total == 0 then return nil end -- the roster has not arrived yet: keep the last good one
  local members = {}
  for i = 1, total do
    local ok, name, rank, rankIndex, level, _, zone, note, _, isOnline, _, class, _, _, _, _, _, guid = pcall(GetGuildRosterInfo, i)
    name = ok and plain(name)
    if name then
      members[#members + 1] = {
        name = name, rank = plain(rank), rankIndex = plain(rankIndex), level = plain(level), class = plain(class),
        zone = plain(zone), online = plain(isOnline) == true, note = plain(note) ~= "" and plain(note) or nil,
        guid = plain(guid), lastOnline = plain(isOnline) ~= true and hoursOffline(i) or nil,
      }
    end
  end
  if #members == 0 then return nil end
  local now, prev = time(), NS.db.roster
  if prev and prev.guild == guild and type(prev.members) == "table" and (prev.at or 0) >= now - LIVE_GAP then
    local before = {}
    for _, m in ipairs(prev.members) do if m.name and m.level then before[m.name] = m.level end end
    for _, m in ipairs(members) do
      local was = before[m.name]
      if was and m.level and m.level > was then logDing(m.name, was, m.level, now) end
    end
  end
  NS.db.roster = {
    at = now, by = NS.PlayerKey and NS.PlayerKey() or nil, guild = guild, realmId = NS.RealmId and NS.RealmId() or nil,
    total = total, online = online, complete = #members >= total, members = members,
  }
  lastAt = GetTime and GetTime() or 0
  return NS.db.roster
end

local function onRosterUpdate()
  if pending then return end
  local now = GetTime and GetTime() or 0
  local wait = math.max(0, THROTTLE - (now - lastAt))
  if lastAt == 0 then wait = 2 end -- the first answer after login: take it soon
  pending = true
  C_Timer.After(wait, function()
    pending = false
    pcall(Roster.Capture)
  end)
end

function Roster.Summary()
  local r = NS.db and NS.db.roster
  if not r or not r.members then return "guild roster not captured yet" end
  return ("guild roster: %d members (%d online) captured %s"):format(#r.members, r.online or 0, date("%H:%M", r.at))
end

function Roster.Start()
  local f = CreateFrame("Frame")
  f:RegisterEvent("GUILD_ROSTER_UPDATE")
  f:RegisterEvent("PLAYER_LOGOUT")
  f:RegisterEvent("PLAYER_LEVEL_UP")
  f:SetScript("OnEvent", function(_, event, level)
    if event == "PLAYER_LOGOUT" then pcall(Roster.Capture)
    elseif event == "PLAYER_LEVEL_UP" then
      local to = plain(level)
      if type(to) == "number" and NS.db and IsInGuild and IsInGuild() then pcall(logDing, NS.PlayerKey(), to - 1, to, time(), true) end
    else onRosterUpdate() end
  end)
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
end
