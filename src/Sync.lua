--[[
  Sync.lua: shares data between addon users in game, so only one PC needs the bridge app.
  Same approach as WowUtils: AceComm over the guild channel (and the home raid), the client's own
  C_EncodingUtil for CBOR + zlib + base64, and a queue for anything that comes up while the client restricts
  addon chat (ADDON_RESTRICTION_STATE_CHANGED, in-instance combat on the Midnight engine) or we are in combat.

  Three datasets travel, each with its own version number:
    L  the loot sheet without the officer Prio layer, version = rev                          (into the game)
    P  the officer Prio layer for one L rev. It reaches two groups and nobody else: ranks that can read officer
       chat (the OFFICER addon channel, enforced by the server) and the in-game ranks the bot names in
       payload.prioRanks (e.g. "Council"), to whom a holder whispers it after checking the guild roster. The
       rank list itself travels inside P, so the public copy carries no hint of it.
    B  the guild bank scan (<Addon>DB.guildBank), version = scan time, complete scans only   (out of the game)
  Anyone who opens the guild bank produces a B; it spreads to every addon user, so the PC with the bridge
  holds the newest scan from whoever opened the bank and uploads it at that officer's next /reload or logout.
  A received scan is only kept when it is for the receiver's own guild.

  Wire protocol, one message per AceComm send (prefix = addon name, first byte = protocol version):
    2H<lootRev>,<bankAt>        "have": 10 s after login, every 5 minutes, after a change, in reply to an older H
    2R<kind><ver>               "request": send me <kind> if yours is newer than ver (P: exactly ver; answered on
                                OFFICER when asked there, by whisper when asked on GUILD by an allowed rank)
    2S<kind><ver>               "sending": one chunk, goes out right before a D so other holders stand down
    2D<kind><ver>:<gen>:<b64>   the data: CBOR, zlib, base64 (loot about 15 KB, bank about 8 KB)

  Who speaks: a client that sees an H above its own version requests; a client that gets an R below its own
  answers after a short random delay, unless somebody else announced S or D on that channel first (AceComm only
  delivers a multipart D once its last chunk arrives, which is why S exists). "Have" replies are jittered and
  dropped when someone else already answered, so a raid full of holders does not shout in unison. Nothing is
  sent, encoded or decoded in combat.

  Trust: anyone in the guild could send a crafted D on our prefix. Payloads are shape-checked, a bank scan must
  name the receiver's guild, and only a higher version is accepted; /psync forget drops shared copies. That is
  the same exposure WowUtils accepts.
]]
local ADDON, NS = ...
local Sync = {}
NS.Sync = Sync

local PREFIX = ADDON:sub(1, 16)
local PROTO = "2"
local ANNOUNCE_EVERY = 300   -- seconds between "have" announcements
local QUIET = 20             -- seconds: at most one data send / request per kind and channel in this window
local INBOUND_QUIET = 30     -- seconds: ignore repeated requests for a kind from the same sender
local MAX_ENCODED = 250000   -- bytes: refuse anything bigger than this on the wire

local Ace = LibStub and LibStub("AceComm-3.0", true)
local EU = C_EncodingUtil
local me

local state = {
  started = false,
  restricted = false,  -- the client currently blocks addon chat
  queue = {},          -- [key] = function() ... end, held back while restricted or in combat
  lastHave = {},       -- [channel] = GetTime() of our last H
  seenHave = {},       -- [channel] = { at, L, B }: the newest H anyone broadcast there
  pendingHave = {},    -- [channel] = timer
  received = 0, sent = 0,
}

-- Per-kind state: [kind] = { lastSend = {ch=t}, seenData = {ch={ver,at}}, pendingSend = {ch=timer},
--   pendingRequest = timer, lastRequest = t, inbound = {sender=t}, stash = {...}, encodedVer, encoded, lastShared }
local K = {}
local function kstate(kind)
  local s = K[kind]
  if not s then
    s = { lastSend = {}, seenData = {}, pendingSend = {}, inbound = {}, lastRequest = 0 }
    K[kind] = s
  end
  return s
end

-- Helpers ---------------------------------------------------------------------------------------

local function short(name) return (Ambiguate and Ambiguate(name or "?", "short")) or name or "?" end

local function isMe(sender)
  if not sender then return true end
  if sender == me then return true end
  return not sender:find("-", 1, true) and sender == UnitName("player")
end

local function inHomeRaid()
  if LE_PARTY_CATEGORY_HOME then return IsInRaid(LE_PARTY_CATEGORY_HOME) end
  return IsInRaid()
end

--- Can this character use officer chat? The game decides who is an officer, whatever the rank is called.
local function officerSelf()
  if not IsInGuild() then return false end
  if C_GuildInfo and C_GuildInfo.IsGuildOfficer then return C_GuildInfo.IsGuildOfficer() == true end
  if C_GuildInfo and C_GuildInfo.CanViewOfficerNote then return C_GuildInfo.CanViewOfficerNote() == true end
  return false
end

local function channelOpen(ch)
  if ch == "GUILD" then return IsInGuild() end
  if ch == "RAID" then return inHomeRaid() end
  if ch == "OFFICER" then return officerSelf() end
  if ch:sub(1, 8) == "WHISPER:" then return true end
  return false
end

-- Guild roster: "Name-Realm" → lower-case rank name, refreshed on GUILD_ROSTER_UPDATE.
local rankOf = {}
local function refreshRoster()
  if not IsInGuild() then wipe(rankOf) return end
  local n = GetNumGuildMembers and GetNumGuildMembers() or 0
  if n == 0 then return end
  wipe(rankOf)
  for i = 1, n do
    local name, rankName = GetGuildRosterInfo(i)
    if name and rankName then rankOf[name] = rankName:lower() end
  end
end

-- In-game rank names the bot allows to hold the Prio layer (payload.prioRanks), lower-cased set.
local function allowedRanks()
  local c = NS.Loot and NS.Loot.Current()
  local list = c and c.payload and c.payload.prioRanks
  local set = {}
  if type(list) == "table" then
    for _, r in ipairs(list) do if type(r) == "string" then set[r:lower()] = true end end
  end
  return set
end

local function rankAllowed(sender)
  local rank = rankOf[sender]
  if not rank then
    local short = sender:match("^([^-]+)")
    if short then rank = rankOf[short] end
  end
  return rank ~= nil and allowedRanks()[rank] == true
end

local function channels()
  local t = {}
  if IsInGuild() then t[#t + 1] = "GUILD" end
  if inHomeRaid() then t[#t + 1] = "RAID" end
  return t
end

local function countKeys(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

-- Datasets --------------------------------------------------------------------------------------

local SETS = {}

local function withoutPrio(payload)
  local out = {}
  for k, v in pairs(payload) do if k ~= "prio" and k ~= "prioRanks" then out[k] = v end end
  return out
end

SETS.L = {
  name = "loot sheet",
  version = function()
    local c = NS.Loot and NS.Loot.Current()
    return c and c.rev or 0
  end,
  -- payload, generatedAt
  current = function()
    local c = NS.Loot and NS.Loot.Current()
    if not c then return nil end
    return withoutPrio(c.payload), tonumber(c.generatedAt) or 0
  end,
  plausible = function(p)
    if type(p) ~= "table" or type(p.items) ~= "table" or type(p.chars) ~= "table" then return false end
    for _, k in ipairs({ "names", "needers", "prio", "owned" }) do
      if p[k] ~= nil and type(p[k]) ~= "table" then return false end
    end
    return countKeys(p.items) <= 5000 and countKeys(p.chars) <= 5000
  end,
  apply = function(ver, gen, p, sender)
    NS.db.lootShared = { rev = ver, generatedAt = gen, receivedAt = time(), from = sender, payload = p }
    if NS.Loot then NS.Loot.Reset() end
    NS.Print("loot sheet rev %d received from %s (%d items). It shows in the council window right away.", ver, short(sender), countKeys(p.items))
  end,
  forget = function()
    if NS.db then NS.db.lootShared = nil end
    if NS.Loot then NS.Loot.Reset() end
  end,
}

-- The officer Prio layer: { prio = { [ikey] = { ckey, ... } }, prioRanks = { "Council", ... } } for exactly one L rev.
SETS.P = {
  name = "officer prio",
  version = function()
    local c = NS.Loot and NS.Loot.Current()
    if not c or type(c.payload.prio) ~= "table" then return 0 end
    return c.rev
  end,
  current = function()
    local c = NS.Loot and NS.Loot.Current()
    if not c or type(c.payload.prio) ~= "table" then return nil end
    return { prio = c.payload.prio, prioRanks = c.payload.prioRanks }, 0
  end,
  plausible = function(p)
    if type(p) ~= "table" or type(p.prio) ~= "table" or countKeys(p.prio) > 5000 then return false end
    return p.prioRanks == nil or (type(p.prioRanks) == "table" and #p.prioRanks <= 50)
  end,
  apply = function(ver, _, p, sender)
    local c = NS.Loot and NS.Loot.Current()
    if not c or c.rev ~= ver or c.source ~= "shared" then return end
    NS.db.lootShared.payload.prio = p.prio
    NS.db.lootShared.payload.prioRanks = p.prioRanks
    NS.db.lootShared.prioRev = ver
    NS.Loot.Reset()
    NS.Print("officer data for loot sheet rev %d received from %s.", ver, short(sender))
  end,
  forget = function() end, -- lives inside lootShared, dropped with it
}

SETS.B = {
  name = "guild bank",
  version = function()
    local gb = NS.db and NS.db.guildBank
    if not gb or gb.complete == false or type(gb.at) ~= "number" then return 0 end
    return gb.at
  end,
  current = function()
    local gb = NS.db and NS.db.guildBank
    if not gb then return nil end
    return gb, 0
  end,
  plausible = function(gb)
    if type(gb) ~= "table" or type(gb.at) ~= "number" or type(gb.tabs) ~= "table" or type(gb.guild) ~= "string" then return false end
    if gb.complete ~= true then return false end
    local mine = GetGuildInfo("player")
    if not mine or mine ~= gb.guild then return false end -- someone else's guild, or we are not in one
    local items = 0
    for _, t in pairs(gb.tabs) do
      if type(t) ~= "table" then return false end
      items = items + countKeys(t.items)
    end
    return items <= 3000
  end,
  apply = function(ver, _, gb, sender)
    gb.sharedFrom = sender
    gb.receivedAt = time()
    NS.db.guildBank = gb
    NS.pendingUpload = true -- the bridge gets it at this PC's next /reload or logout
  end,
  forget = function()
    local gb = NS.db and NS.db.guildBank
    if gb and gb.sharedFrom then NS.db.guildBank = nil end
  end,
}

-- Encoding --------------------------------------------------------------------------------------

local function encodedData(kind)
  local ks = kstate(kind)
  local set = SETS[kind]
  local ver = set.version()
  if ks.encodedVer == ver and ks.encoded then return ks.encoded end
  local payload = set.current()
  if not payload then return nil, "nothing to send" end
  local ok, cbor = pcall(EU.SerializeCBOR, payload)
  if not ok or type(cbor) ~= "string" then return nil, "serialise: " .. tostring(cbor) end
  local ok2, z = pcall(EU.CompressString, cbor, Enum.CompressionMethod.Zlib, Enum.CompressionLevel and Enum.CompressionLevel.OptimizeForSize or nil)
  if not ok2 or type(z) ~= "string" then return nil, "compress: " .. tostring(z) end
  local ok3, b64 = pcall(EU.EncodeBase64, z)
  if not ok3 or type(b64) ~= "string" then return nil, "encode: " .. tostring(b64) end
  ks.encodedVer, ks.encoded = ver, b64
  return b64
end

local function decode(b64)
  local ok, z = pcall(EU.DecodeBase64, b64)
  if not ok or type(z) ~= "string" then return nil end
  local ok2, cbor = pcall(EU.DecompressString, z, Enum.CompressionMethod.Zlib)
  if not ok2 or type(cbor) ~= "string" then return nil end
  local ok3, p = pcall(EU.DeserializeCBOR, cbor)
  if not ok3 then return nil end
  return p
end

-- Sending ---------------------------------------------------------------------------------------

local function canSendNow() return not state.restricted and not InCombatLockdown() end

local function later(key, fn) state.queue[key] = fn end

local function flush()
  if not canSendNow() then return end
  local q = state.queue
  state.queue = {}
  for _, fn in pairs(q) do fn() end
end

local function haveText()
  return PROTO .. "H" .. SETS.L.version() .. "," .. SETS.B.version()
end

local function sendHave(ch)
  state.pendingHave[ch] = nil
  if not channelOpen(ch) then return end
  if not canSendNow() then later("H" .. ch, function() sendHave(ch) end) return end
  local now = GetTime()
  if (state.lastHave[ch] or 0) > now - QUIET then return end
  state.lastHave[ch] = now
  Ace:SendCommMessage(PREFIX, haveText(), ch, nil, "NORMAL")
end

--- Reply to someone behind us, unless another holder already did.
local function scheduleHave(ch)
  if state.pendingHave[ch] then return end
  state.pendingHave[ch] = C_Timer.NewTimer(0.3 + math.random() * 1.5, function()
    state.pendingHave[ch] = nil
    local sh = state.seenHave[ch]
    if sh and sh.at > GetTime() - 5 and sh.L >= SETS.L.version() and sh.B >= SETS.B.version() then return end
    sendHave(ch)
  end)
end

local function sendRequest(kind, ch)
  local ks = kstate(kind)
  ks.pendingRequest = nil
  if not channelOpen(ch) then return end
  if not canSendNow() then later("R" .. kind .. ch, function() sendRequest(kind, ch) end) return end
  ks.lastRequest = GetTime()
  Ace:SendCommMessage(PREFIX, PROTO .. "R" .. kind .. SETS[kind].version(), ch, nil, "NORMAL")
end

-- ch is "GUILD", "RAID", "OFFICER" (Prio layer) or "WHISPER:<Name-Realm>" (Prio layer to an allowed rank).
local function sendData(kind, ch, to)
  local ks = kstate(kind)
  ks.pendingSend[ch] = nil
  if not channelOpen(ch) then return end
  local dist, target = ch, nil
  if ch:sub(1, 8) == "WHISPER:" then dist, target = "WHISPER", ch:sub(9) end
  if not canSendNow() then later("D" .. kind .. ch, function() sendData(kind, ch, to) end) return end
  local now = GetTime()
  if (ks.lastSend[ch] or 0) > now - QUIET then return end
  local ver = SETS[kind].version()
  if ver == 0 then return end
  local sd = ks.seenData[ch]
  if sd and sd.ver >= ver and sd.at > now - QUIET then return end -- somebody else already answered
  local b64, err = encodedData(kind)
  if not b64 then NS.Print("could not share the %s (%s).", SETS[kind].name, err) return end
  local _, gen = SETS[kind].current()
  ks.lastSend[ch] = now
  state.sent = state.sent + 1
  ks.lastShared = { to = to, ver = ver, at = time() }
  if not target then Ace:SendCommMessage(PREFIX, PROTO .. "S" .. kind .. ver, dist, nil, "ALERT") end
  Ace:SendCommMessage(PREFIX, PROTO .. "D" .. kind .. ver .. ":" .. string.format("%.0f", gen or 0) .. ":" .. b64, dist, target, "BULK")
end

local function scheduleRequest(kind, ch, theirVer)
  local ks = kstate(kind)
  if ks.pendingRequest then return end
  local now = GetTime()
  if ks.lastRequest > now - QUIET then return end
  local sd = ks.seenData[ch]
  if sd and sd.ver >= theirVer and sd.at > now - QUIET then return end -- data is already on its way
  ks.pendingRequest = C_Timer.NewTimer(0.5 + math.random() * 2, function() sendRequest(kind, ch) end)
end

local function scheduleSend(kind, ch, to)
  local ks = kstate(kind)
  if ks.pendingSend[ch] then return end
  ks.pendingSend[ch] = C_Timer.NewTimer(0.5 + math.random() * 3.5, function() sendData(kind, ch, to) end)
end

local function cancelSend(kind, ch)
  local ks = kstate(kind)
  local t = ks.pendingSend[ch]
  if t then t:Cancel() ks.pendingSend[ch] = nil end
  state.queue["D" .. kind .. ch] = nil
end

local function cancelRequest(kind)
  local ks = kstate(kind)
  if ks.pendingRequest then ks.pendingRequest:Cancel() ks.pendingRequest = nil end
end

-- Receiving -------------------------------------------------------------------------------------

local function apply(kind, ver, gen, b64, sender)
  local set = SETS[kind]
  local p = decode(b64)
  if not p or not set.plausible(p) then return end
  if set.version() >= ver then return end
  if kind == "P" and SETS.L.version() ~= ver then return end -- a Prio layer for a rev we do not hold
  set.apply(ver, gen, p, sender)
  local ks = kstate(kind)
  ks.encodedVer, ks.encoded = ver, b64 -- we can pass it on as is
  state.received = state.received + 1
end

local requestPrio -- defined below

local function onComm(_, msg, channel, sender)
  if type(msg) ~= "string" or msg:sub(1, 1) ~= PROTO then return end
  if isMe(sender) then return end
  local op = msg:sub(2, 2)
  local kind = msg:sub(3, 3)
  if channel == "OFFICER" then
    if op == "H" or kind ~= "P" then return end -- only the Prio layer lives on officer chat
  elseif channel == "WHISPER" then
    if not (op == "D" and kind == "P") then return end -- a whispered Prio layer, nothing else
  elseif channel ~= "GUILD" and channel ~= "RAID" then
    return
  elseif op ~= "H" and kind == "P" and op ~= "R" then
    return -- on guild and raid the Prio layer is only ever asked for, never sent
  end
  if op == "H" then
    local l, b = msg:match("^.H(%d+),(%d+)$")
    l, b = tonumber(l), tonumber(b)
    if not l or not b then return end
    state.seenHave[channel] = { at = GetTime(), L = l, B = b }
    local theirs, behind = { L = l, B = b }, false
    for k, set in pairs(SETS) do
      if theirs[k] then
        local mine = set.version()
        if theirs[k] > mine then scheduleRequest(k, channel, theirs[k])
        elseif theirs[k] < mine then behind = true end
      end
    end
    if behind then scheduleHave(channel) end -- they are behind: tell them, they will ask
    return
  end
  local set = SETS[kind]
  if not set then return end
  local ks = kstate(kind)
  local mine = set.version()
  if op == "R" then
    local ver = tonumber(msg:sub(4))
    if not ver then return end
    local now = GetTime()
    if (ks.inbound[sender] or 0) > now - INBOUND_QUIET then return end
    ks.inbound[sender] = now
    if kind == "P" then
      if mine ~= ver then return end -- exactly this rev
      if channel == "OFFICER" then scheduleSend("P", "OFFICER", sender)          -- the channel limits who hears it
      elseif rankAllowed(sender) then scheduleSend("P", "WHISPER:" .. sender, sender) -- an allowed in-game rank
      end
    elseif mine > ver then
      scheduleSend(kind, channel, sender)
    end
  elseif op == "S" then
    local ver = tonumber(msg:sub(4))
    if not ver then return end
    ks.seenData[channel] = { ver = ver, at = GetTime() }
    if ver >= mine then cancelSend(kind, channel) end
    if ver > mine then cancelRequest(kind) end
  elseif op == "D" then
    local ver, gen, b64 = msg:match("^..(%d+):(%d+):(.*)$", 3)
    ver = tonumber(ver)
    if not ver or not b64 or #b64 == 0 or #b64 > MAX_ENCODED then return end
    ks.seenData[channel] = { ver = ver, at = GetTime() }
    if ver >= mine then cancelSend(kind, channel) end
    if ver <= mine then return end
    if InCombatLockdown() then
      if not ks.stash or ks.stash.ver < ver then ks.stash = { ver = ver, gen = tonumber(gen), b64 = b64, sender = sender, channel = channel } end
      return
    end
    apply(kind, ver, tonumber(gen), b64, sender)
    if kind == "L" then C_Timer.After(1, requestPrio) end
  end
end

--- Ask for the Prio layer of the loot sheet rev we hold, when we do not have it yet: officers on officer chat,
--- everyone else once on guild chat (one tiny message; holders answer only ranks the bot allows, others hear nothing).
requestPrio = function()
  if not NS.Loot or SETS.L.version() == 0 or SETS.P.version() ~= 0 or not IsInGuild() then return end
  scheduleRequest("P", officerSelf() and "OFFICER" or "GUILD", SETS.L.version())
end

-- Lifecycle -------------------------------------------------------------------------------------

function Sync.Available()
  if not Ace then return false, "AceComm did not load" end
  if not EU or not EU.SerializeCBOR or not EU.DeserializeCBOR or not EU.CompressString or not EU.DecompressString or not EU.EncodeBase64 or not EU.DecodeBase64 then
    return false, "this client has no C_EncodingUtil"
  end
  if not Enum or not Enum.CompressionMethod or not Enum.CompressionMethod.Zlib then return false, "this client has no zlib" end
  return true
end

function Sync.Announce()
  for _, ch in ipairs(channels()) do sendHave(ch) end
  requestPrio()
end

--- Something we hold changed (bank closed after a scan, loot file reloaded): announce it right away.
function Sync.Changed()
  if not state.started then return end
  wipe(state.lastHave)
  C_Timer.After(1, Sync.Announce)
end

--- /psync sync: ask right now, ignoring the quiet period.
function Sync.RequestNow()
  if not state.started then NS.Print("sharing is off: %s.", select(2, Sync.Available()) or "not started") return end
  local chs = channels()
  if #chs == 0 then NS.Print("not in a guild or raid, nobody to ask.") return end
  for kind in pairs(SETS) do
    if kind ~= "P" then
      kstate(kind).lastRequest = 0
      for _, ch in ipairs(chs) do sendRequest(kind, ch) end
    end
  end
  kstate("P").lastRequest = 0
  requestPrio()
  NS.Print("asked %s for loot sheet data newer than rev %d and bank scans newer than %s.",
    table.concat(chs, " and "):lower(), SETS.L.version(), SETS.B.version() > 0 and date("%d/%m %H:%M", SETS.B.version()) or "none")
end

--- /psync forget: drop shared copies (the bridge file and your own scans stay).
function Sync.Forget()
  for _, set in pairs(SETS) do set.forget() end
  for _, ks in pairs(K) do ks.encodedVer, ks.encoded = nil, nil end
  NS.Print("shared copies dropped.")
end

function Sync.Status()
  if not state.started then return "sharing off (" .. (select(2, Sync.Available()) or "not started") .. ")" end
  local chs = table.concat(channels(), "+"):lower()
  local parts = { ("sharing on in %s"):format(chs ~= "" and chs or "no channel (no guild or raid)") }
  for kind, set in pairs(SETS) do
    local ls = K[kind] and K[kind].lastShared
    if ls then parts[#parts + 1] = ("%s last sent to %s %ds ago"):format(set.name, short(ls.to), time() - ls.at) end
  end
  -- Holders only. A raider's status never mentions that officers hold anything extra.
  if SETS.L.version() > 0 and (SETS.P.version() > 0 or officerSelf()) then
    parts[#parts + 1] = SETS.P.version() > 0 and "officer data present" or "officer data not received yet"
  end
  local gb = NS.db and NS.db.guildBank
  if gb and gb.sharedFrom then parts[#parts + 1] = ("bank scan here is %s's, received %s"):format(short(gb.sharedFrom), date("%d/%m %H:%M", gb.receivedAt or 0)) end
  parts[#parts + 1] = ("%d received, %d sent this session"):format(state.received, state.sent)
  if state.restricted then parts[#parts + 1] = "addon chat restricted right now" end
  if next(state.queue) then parts[#parts + 1] = "messages waiting" end
  return table.concat(parts, ", ")
end

function Sync.Start()
  if state.started then return end
  local ok, why = Sync.Available()
  if not ok then NS.Print("in-game sharing is off: %s.", why) return end
  state.started = true
  me = NS.PlayerKey()
  Ace:RegisterComm(PREFIX, onComm)

  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_REGEN_ENABLED")
  f:RegisterEvent("GROUP_JOINED")
  f:RegisterEvent("GUILD_ROSTER_UPDATE")
  pcall(f.RegisterEvent, f, "ADDON_RESTRICTION_STATE_CHANGED")
  f:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "PLAYER_REGEN_ENABLED" then
      for kind, ks in pairs(K) do
        local s = ks.stash
        ks.stash = nil
        if s and s.ver > SETS[kind].version() then
          apply(kind, s.ver, s.gen, s.b64, s.sender)
          if kind == "L" then C_Timer.After(1, requestPrio) end
        end
      end
      flush()
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
      if Enum.AddOnRestrictionType and a1 ~= Enum.AddOnRestrictionType.Chat then return end
      state.restricted = Enum.AddOnRestrictionState and a2 ~= Enum.AddOnRestrictionState.Inactive or false
      if not state.restricted then flush() end
    elseif event == "GROUP_JOINED" then
      C_Timer.After(5, Sync.Announce)
    elseif event == "GUILD_ROSTER_UPDATE" then
      refreshRoster()
    end
  end)

  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
  C_Timer.After(10, Sync.Announce)
  C_Timer.NewTicker(ANNOUNCE_EVERY, function()
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
    Sync.Announce()
  end)
end
