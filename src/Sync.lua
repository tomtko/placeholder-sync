--[[
  Sync.lua: shares the loot sheet dataset between addon users in game, so only one PC needs the bridge app.
  Same approach as WowUtils: AceComm over the guild channel (and the home raid), the client's own
  C_EncodingUtil for CBOR + zlib + base64, and a queue for anything that comes up while the client restricts
  addon chat (ADDON_RESTRICTION_STATE_CHANGED, in-instance combat on the Midnight engine) or we are in combat.

  Wire protocol, one message per AceComm send (prefix = addon name, first byte = protocol version):
    1H<rev>                 "have": announced 10 s after login, every 5 minutes, and in reply to an older H
    1R<rev>                 "request": send me anything newer than rev
    1S<rev>                 "sending": one chunk, goes out right before a D so other holders stand down
    1D<rev>:<gen>:<base64>  the dataset: CBOR payload, zlib, base64 (about 15 KB, roughly 60 chunks, 15-20 s)

  Who speaks: a client that sees an H above its own rev requests; a client that gets an R below its own rev
  answers after a short random delay, unless somebody else announced S or D on that channel first (AceComm only
  delivers a multipart D once its last chunk arrives, which is why S exists). "Have" replies are jittered and
  dropped when someone else already answered, so a raid full of holders does not shout in unison. Received copies
  go to <AddonName>DB.lootShared, so they survive logout; LootData.lua picks the newer of the bridge file and
  the shared copy. Nothing is sent, encoded or decoded in combat.

  Trust: anyone in the guild could send a crafted D on our prefix. The payload is shape-checked and only a
  higher rev is accepted; /psync forget drops a shared copy. That is the same exposure WowUtils accepts.
]]
local ADDON, NS = ...
local Sync = {}
NS.Sync = Sync

local PREFIX = ADDON:sub(1, 16)
local PROTO = "1"
local ANNOUNCE_EVERY = 300   -- seconds between "have" announcements
local QUIET = 20             -- seconds: at most one data send / request per channel in this window
local INBOUND_QUIET = 30     -- seconds: ignore repeated requests from the same sender
local MAX_ENCODED = 200000   -- bytes: refuse anything bigger than this on the wire

local Ace = LibStub and LibStub("AceComm-3.0", true)
local EU = C_EncodingUtil
local me

local state = {
  started = false,
  restricted = false,  -- the client currently blocks addon chat
  queue = {},          -- [kind .. channel] = function() ... end, held back while restricted or in combat
  lastSend = {},       -- [channel] = GetTime() of our last data send
  lastHave = {},       -- [channel] = GetTime() of our last H
  lastRequest = 0,
  seenData = {},       -- [channel] = { rev, at }: the newest S/D anyone broadcast there
  seenHave = {},       -- [channel] = { rev, at }: the newest H anyone broadcast there
  pendingSend = {},    -- [channel] = timer
  pendingHave = {},    -- [channel] = timer
  pendingRequest = nil,
  inbound = {},        -- [sender] = GetTime() of their last R
  stash = nil,         -- a D that arrived in combat, applied on PLAYER_REGEN_ENABLED
  encodedRev = nil, encoded = nil,
  lastShared = nil,    -- { to, rev, at } for /psync
  received = 0, sent = 0,
}

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

local function channelOpen(ch)
  if ch == "GUILD" then return IsInGuild() end
  if ch == "RAID" then return inHomeRaid() end
  return false
end

local function channels()
  local t = {}
  if IsInGuild() then t[#t + 1] = "GUILD" end
  if inHomeRaid() then t[#t + 1] = "RAID" end
  return t
end

local function current() return NS.Loot and NS.Loot.Current() or nil end
local function myRev() local c = current() return c and c.rev or 0 end

-- Encoding --------------------------------------------------------------------------------------

local function encodedData(cur)
  if state.encodedRev == cur.rev and state.encoded then return state.encoded end
  local ok, cbor = pcall(EU.SerializeCBOR, cur.payload)
  if not ok or type(cbor) ~= "string" then return nil, "serialise: " .. tostring(cbor) end
  local ok2, z = pcall(EU.CompressString, cbor, Enum.CompressionMethod.Zlib, Enum.CompressionLevel and Enum.CompressionLevel.OptimizeForSize or nil)
  if not ok2 or type(z) ~= "string" then return nil, "compress: " .. tostring(z) end
  local ok3, b64 = pcall(EU.EncodeBase64, z)
  if not ok3 or type(b64) ~= "string" then return nil, "encode: " .. tostring(b64) end
  state.encodedRev, state.encoded = cur.rev, b64
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

local function plausible(p)
  if type(p) ~= "table" or type(p.items) ~= "table" or type(p.chars) ~= "table" then return false end
  for _, k in ipairs({ "names", "needers", "prio", "owned" }) do
    if p[k] ~= nil and type(p[k]) ~= "table" then return false end
  end
  local n = 0
  for _ in pairs(p.items) do n = n + 1 if n > 5000 then return false end end
  n = 0
  for _ in pairs(p.chars) do n = n + 1 if n > 5000 then return false end end
  return true
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

local function sendHave(ch)
  state.pendingHave[ch] = nil
  if not channelOpen(ch) then return end
  if not canSendNow() then later("H" .. ch, function() sendHave(ch) end) return end
  local now = GetTime()
  if (state.lastHave[ch] or 0) > now - QUIET then return end
  state.lastHave[ch] = now
  Ace:SendCommMessage(PREFIX, PROTO .. "H" .. myRev(), ch, nil, "NORMAL")
end

--- Reply to someone behind us, unless another holder already did.
local function scheduleHave(ch)
  if state.pendingHave[ch] then return end
  state.pendingHave[ch] = C_Timer.NewTimer(0.3 + math.random() * 1.5, function()
    state.pendingHave[ch] = nil
    local sh = state.seenHave[ch]
    if sh and sh.rev >= myRev() and sh.at > GetTime() - 5 then return end
    sendHave(ch)
  end)
end

local function sendRequest(ch)
  state.pendingRequest = nil
  if not channelOpen(ch) then return end
  if not canSendNow() then later("R" .. ch, function() sendRequest(ch) end) return end
  state.lastRequest = GetTime()
  Ace:SendCommMessage(PREFIX, PROTO .. "R" .. myRev(), ch, nil, "NORMAL")
end

local function sendData(ch, to)
  state.pendingSend[ch] = nil
  if not channelOpen(ch) then return end
  if not canSendNow() then later("D" .. ch, function() sendData(ch, to) end) return end
  local now = GetTime()
  if (state.lastSend[ch] or 0) > now - QUIET then return end
  local cur = current()
  if not cur then return end
  local sd = state.seenData[ch]
  if sd and sd.rev >= cur.rev and sd.at > now - QUIET then return end -- somebody else already answered
  local b64, err = encodedData(cur)
  if not b64 then NS.Print("could not share the loot sheet (%s).", err) return end
  state.lastSend[ch] = now
  state.sent = state.sent + 1
  state.lastShared = { to = to, rev = cur.rev, at = time() }
  local gen = string.format("%.0f", tonumber(cur.generatedAt) or 0)
  Ace:SendCommMessage(PREFIX, PROTO .. "S" .. cur.rev, ch, nil, "ALERT")
  Ace:SendCommMessage(PREFIX, PROTO .. "D" .. cur.rev .. ":" .. gen .. ":" .. b64, ch, nil, "BULK")
end

local function scheduleRequest(ch, rev)
  if state.pendingRequest then return end
  local now = GetTime()
  if state.lastRequest > now - QUIET then return end
  local sd = state.seenData[ch]
  if sd and sd.rev >= rev and sd.at > now - QUIET then return end -- data is already on its way
  state.pendingRequest = C_Timer.NewTimer(0.5 + math.random() * 2, function() sendRequest(ch) end)
end

local function scheduleSend(ch, to)
  if state.pendingSend[ch] then return end
  state.pendingSend[ch] = C_Timer.NewTimer(0.5 + math.random() * 3.5, function() sendData(ch, to) end)
end

local function cancelSend(ch)
  local t = state.pendingSend[ch]
  if t then t:Cancel() state.pendingSend[ch] = nil end
  state.queue["D" .. ch] = nil
end

-- Receiving -------------------------------------------------------------------------------------

local function apply(rev, gen, b64, sender)
  local p = decode(b64)
  if not p or not plausible(p) then return end
  if myRev() >= rev then return end
  NS.db.lootShared = { rev = rev, generatedAt = gen, receivedAt = time(), from = sender, payload = p }
  state.encodedRev, state.encoded = rev, b64 -- we can pass it on as is
  state.received = state.received + 1
  if NS.Loot then NS.Loot.Reset() end
  local n = 0
  for _ in pairs(p.items) do n = n + 1 end
  NS.Print("loot sheet rev %d received from %s (%d items). It shows in the council window right away.", rev, short(sender), n)
end

local function onComm(_, msg, channel, sender)
  if type(msg) ~= "string" or msg:sub(1, 1) ~= PROTO then return end
  if channel ~= "GUILD" and channel ~= "RAID" then return end
  if isMe(sender) then return end
  local kind = msg:sub(2, 2)
  local mine = myRev()
  if kind == "H" then
    local rev = tonumber(msg:sub(3))
    if not rev then return end
    state.seenHave[channel] = { rev = rev, at = GetTime() }
    if rev > mine then scheduleRequest(channel, rev)
    elseif rev < mine then scheduleHave(channel) end -- they are behind: tell them, they will ask
  elseif kind == "S" then
    local rev = tonumber(msg:sub(3))
    if not rev then return end
    state.seenData[channel] = { rev = rev, at = GetTime() }
    if rev >= mine then cancelSend(channel) end
    if rev > mine and state.pendingRequest then state.pendingRequest:Cancel() state.pendingRequest = nil end
  elseif kind == "R" then
    local rev = tonumber(msg:sub(3))
    if not rev then return end
    local now = GetTime()
    if (state.inbound[sender] or 0) > now - INBOUND_QUIET then return end
    state.inbound[sender] = now
    if mine > rev then scheduleSend(channel, sender) end
  elseif kind == "D" then
    local rev, gen, b64 = msg:match("^.D(%d+):(%d+):(.*)$")
    rev = tonumber(rev)
    if not rev or not b64 or #b64 == 0 or #b64 > MAX_ENCODED then return end
    state.seenData[channel] = { rev = rev, at = GetTime() }
    if rev >= mine then cancelSend(channel) end
    if rev <= mine then return end
    if InCombatLockdown() then
      if not state.stash or state.stash.rev < rev then state.stash = { rev = rev, gen = tonumber(gen), b64 = b64, sender = sender } end
      return
    end
    apply(rev, tonumber(gen), b64, sender)
  end
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
end

--- /psync sync: ask right now, ignoring the quiet period.
function Sync.RequestNow()
  if not state.started then NS.Print("sharing is off: %s.", select(2, Sync.Available()) or "not started") return end
  state.lastRequest = 0
  local chs = channels()
  if #chs == 0 then NS.Print("not in a guild or raid, nobody to ask.") return end
  for _, ch in ipairs(chs) do sendRequest(ch) end
  NS.Print("asked %s for loot sheet data newer than rev %d.", table.concat(chs, " and "):lower(), myRev())
end

--- /psync forget: drop a shared copy (the bridge file, if any, stays).
function Sync.Forget()
  if NS.db then NS.db.lootShared = nil end
  state.encodedRev, state.encoded = nil, nil
  if NS.Loot then NS.Loot.Reset() end
  NS.Print("shared loot sheet copy dropped.")
end

function Sync.Status()
  if not state.started then return "sharing off (" .. (select(2, Sync.Available()) or "not started") .. ")" end
  local parts = { ("sharing on as %s"):format(table.concat(channels(), "+") ~= "" and table.concat(channels(), "+"):lower() or "nobody (no guild/raid)") }
  if state.lastShared then parts[#parts + 1] = ("last sent rev %d to %s %ds ago"):format(state.lastShared.rev, short(state.lastShared.to), time() - state.lastShared.at) end
  parts[#parts + 1] = ("%d received, %d sent this session"):format(state.received, state.sent)
  if state.restricted then parts[#parts + 1] = "addon chat restricted right now" end
  if next(state.queue) then parts[#parts + 1] = "messages waiting" end
  return table.concat(parts, ", ")
end

function Sync.Start()
  if state.started then return end
  local ok, why = Sync.Available()
  if not ok then NS.Print("in-game sharing of the loot sheet is off: %s.", why) return end
  state.started = true
  me = NS.PlayerKey()
  Ace:RegisterComm(PREFIX, onComm)

  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_REGEN_ENABLED")
  f:RegisterEvent("GROUP_JOINED")
  pcall(f.RegisterEvent, f, "ADDON_RESTRICTION_STATE_CHANGED")
  f:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "PLAYER_REGEN_ENABLED" then
      local s = state.stash
      state.stash = nil
      if s and s.rev > myRev() then apply(s.rev, s.gen, s.b64, s.sender) end
      flush()
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
      if Enum.AddOnRestrictionType and a1 ~= Enum.AddOnRestrictionType.Chat then return end
      state.restricted = Enum.AddOnRestrictionState and a2 ~= Enum.AddOnRestrictionState.Inactive or false
      if not state.restricted then flush() end
    elseif event == "GROUP_JOINED" then
      C_Timer.After(5, Sync.Announce)
    end
  end)

  C_Timer.After(10, Sync.Announce)
  C_Timer.NewTicker(ANNOUNCE_EVERY, Sync.Announce)
end
