"""
Simulates many addon users sharing data in game, running the real src/Sync.lua (and GuildBank.lua's merge) under a
stubbed WoW API. One Lua runtime hosts every instance; CUR points at the instance whose code is running. Messages
travel through a model of AceComm + ChatThrottleLib: one output queue per sender at ~800 bytes/s, a multipart message
arrives whole when its last chunk has gone out.

    python3 test/sync_sim.py            # runs the scenarios, prints counts, exits 1 on a failed check
"""
import base64, heapq, math, pathlib, random, sys, zlib
import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
BYTES_PER_SEC = 800          # ChatThrottleLib MAX_CPS
LATENCY = 0.15               # server round trip for one chunk
CHUNK = 255

L = lupa.LuaRuntime(encoding=None, unpack_returned_tuples=True)
G = L.globals()

# ---- event loop ---------------------------------------------------------------------------------
clock = 0.0
events = []                  # (time, seq, id)
timers = {}                  # id -> dict(fn, inst, period, cancelled)
seq = 0
def schedule(delay, fn, inst_id, period):
    global seq
    seq += 1
    timers[seq] = dict(fn=fn, inst=inst_id, period=period if period else None, cancelled=False)
    heapq.heappush(events, (clock + max(delay, 0), seq, seq))
    return seq
def cancel(tid): 
    if tid in timers: timers[tid]["cancelled"] = True
G.py_schedule = lambda d, fn, inst, rep: schedule(float(d), fn, int(inst), float(d) if rep else None)
G.py_cancel = lambda tid: cancel(int(tid))

# ---- network ------------------------------------------------------------------------------------
instances = {}               # id -> python-side record (name, guild, officer, inRaid, online, busy_until, lua NS)
stats = dict(msgs={}, bytes={}, per_sender={}, d_sends=[])
def py_send(sender_id, text, dist, target, prio):
    s = instances[sender_id]
    if not s["online"]: return
    op = text[1:2].decode() if len(text) > 1 else "?"
    kind = text[2:3].decode() if len(text) > 2 else ""
    key = f"{op}{kind}" if op in "RSD" else op
    stats["msgs"][key] = stats["msgs"].get(key, 0) + 1
    stats["bytes"][key] = stats["bytes"].get(key, 0) + len(text)
    stats["per_sender"][sender_id] = stats["per_sender"].get(sender_id, 0) + len(text)
    if op == "D": stats["d_sends"].append((round(clock, 1), s["name"], kind, dist.decode(), len(text)))
    start = max(clock, s["busy_until"])
    done = start + len(text) / BYTES_PER_SEC
    s["busy_until"] = done
    arrive = done + LATENCY
    d = dist.decode()
    if d == "GUILD": rcv = [i for i in instances.values() if i["online"] and i["guild"] == s["guild"]]
    elif d == "RAID": rcv = [i for i in instances.values() if i["online"] and i["inRaid"]]
    elif d == "OFFICER": rcv = [i for i in instances.values() if i["online"] and i["officer"] and i["guild"] == s["guild"]]
    elif d == "WHISPER": rcv = [i for i in instances.values() if i["online"] and i["full"] == target.decode()]
    else: rcv = []
    for r in rcv:
        if r["id"] == sender_id: continue
        def deliver(r=r, text=text, d=d, sender=s["full"]):
            fn = r["ns"].onCommFn
            if fn is not None: fn(b"PlaceholderSync", text, d.encode(), sender.encode())
        schedule(arrive - clock, deliver, r["id"], None)
G.py_send = lambda sid, text, dist, target, prio: py_send(int(sid), bytes(text), bytes(dist), bytes(target), prio)
G.py_compress = lambda s: zlib.compress(bytes(s), 9)
G.py_decompress = lambda s: zlib.decompress(bytes(s))
G.py_b64e = lambda s: base64.b64encode(bytes(s))
G.py_b64d = lambda s: base64.b64decode(bytes(s))

# ---- WoW API stubs (Lua) ------------------------------------------------------------------------
L.execute(r'''
CLOCK = 0
CUR = nil
ROSTER = {}
LE_PARTY_CATEGORY_HOME = 1
function GetTime() return CLOCK end
function time() return 1762000000 + math.floor(CLOCK) end
function date(fmt, t) return tostring(t or time()) end
function UnitName(u) return CUR.name end
function UnitGUID(u) return "Player-1-" .. CUR.id end
function UnitClass() return "Warrior", "WARRIOR" end
function UnitLevel() return 60 end
function GetNormalizedRealmName() return "Realm" end
function GetRealmName() return "Realm" end
function GetGuildInfo() return CUR.guild end
function IsInGuild() return CUR.guild ~= nil end
function IsInRaid() return CUR.inRaid == true end
function IsLoggedIn() return true end
function InCombatLockdown() return CUR.combat == true end
function Ambiguate(n) return (tostring(n):match("^([^-]+)")) end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function ReloadUI() end
function hooksecurefunc() end
C_GuildInfo = { GuildRoster = function() end, IsGuildOfficer = function() return CUR.officer == true end }
function GetNumGuildMembers() return #ROSTER, #ROSTER end
function GetGuildRosterInfo(i) local r = ROSTER[i] return r.name .. "-Realm", r.rank end
function GetNumGuildBankTabs() return 0 end
function GetGuildBankMoney() return 0 end
Enum = { CompressionMethod = { Zlib = 1 }, CompressionLevel = { OptimizeForSize = 9 },
         AddOnRestrictionType = { Chat = 1 }, AddOnRestrictionState = { Inactive = 0 } }

-- a Lua-literal serialiser stands in for CBOR (same shape round trip, similar size after zlib)
local function ser(v, out)
  local t = type(v)
  if t == "table" then
    out[#out + 1] = "{"
    for k, x in pairs(v) do
      out[#out + 1] = "[" if type(k) == "string" then out[#out + 1] = string.format("%q", k) else out[#out + 1] = tostring(k) end
      out[#out + 1] = "]="
      ser(x, out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  elseif t == "string" then out[#out + 1] = string.format("%q", v)
  elseif t == "number" or t == "boolean" then out[#out + 1] = tostring(v)
  else out[#out + 1] = "nil" end
end
C_EncodingUtil = {
  SerializeCBOR = function(v) local out = {} ser(v, out) return table.concat(out) end,
  DeserializeCBOR = function(s) return load("return " .. s)() end,
  CompressString = function(s) return py_compress(s) end,
  DecompressString = function(s) return py_decompress(s) end,
  EncodeBase64 = function(s) return py_b64e(s) end,
  DecodeBase64 = function(s) return py_b64d(s) end,
}
C_Timer = {
  NewTimer = function(d, fn) local id = py_schedule(d, fn, CUR.id, false) return { id = id, Cancel = function(self) py_cancel(self.id) end } end,
  After = function(d, fn) py_schedule(d, fn, CUR.id, false) end,
  NewTicker = function(d, fn) local id = py_schedule(d, fn, CUR.id, true) return { id = id, Cancel = function(self) py_cancel(self.id) end } end,
}
function CreateFrame()
  local f = {}
  function f:RegisterEvent() end
  function f:UnregisterEvent() end
  function f:SetScript(_, h) self.handler = h end
  return f
end
local ACE = {}
function ACE:RegisterComm(prefix, fn) CUR.ns.onCommFn = fn end
function ACE:SendCommMessage(prefix, text, dist, target, prio) py_send(CUR.id, text, dist, target or "", prio or "NORMAL") end
function LibStub(name, silent) return ACE end
C_ChatInfo = { SendAddonMessage = function() end, RegisterAddonMessagePrefix = function() end }

INSTANCES = {}
function SetInst(id, key, value) INSTANCES[id][key] = value end
function SetBridgeLoot(id, t) INSTANCES[id].bridgeLoot = t end
function SetBank(id, t) INSTANCES[id].ns.db.guildBank = t INSTANCES[id].ns.pendingUpload = true end
function ClearData(id) INSTANCES[id].ns.db.lootShared = nil INSTANCES[id].ns.db.guildBank = nil end
function NewInstance(id, name, guild, officer)
  local inst = { id = id, name = name, guild = guild, officer = officer, combat = false, inRaid = false }
  local NS = { onCommFn = false, printed = 0, notified = 0 }
  inst.ns = NS
  NS.ADDON = "PlaceholderSync"; NS.SLASH = "/psync"
  NS.db = { characters = {}, options = {}, _apiCheck = {} }
  NS.Print = function() NS.printed = NS.printed + 1 end
  NS.Notify = function() NS.notified = NS.notified + 1 end
  NS.Option = function(k) if k == "chat" then return false end return true end
  NS.PlayerKey = function() return name .. "-Realm" end
  NS.ForThisGuild = function() return true end
  NS.GuildName = function() return guild end
  inst.bridgeLoot = nil   -- { rev, generatedAt, payload } written by "the bridge" on this PC
  NS.Loot = {
    Current = function()
      local b, s = inst.bridgeLoot, NS.db.lootShared
      local brev = b and tonumber(b.rev) or nil
      local srev = s and tonumber(s.rev) or nil
      if srev and brev and brev >= srev then NS.db.lootShared = nil srev = nil end
      if srev then return { rev = srev, generatedAt = s.generatedAt, payload = s.payload, source = "shared", from = s.from } end
      if brev then return { rev = brev, generatedAt = b.generatedAt, payload = b.payload, source = "bridge" } end
      return nil
    end,
    Reset = function() end,
    Info = function() return nil end,
  }
  INSTANCES[id] = inst
  CUR = inst
  local gbSrc = assert(loadfile(GUILDBANK_PATH))
  gbSrc("PlaceholderSync", NS)
  local chunk = assert(loadfile(SYNC_PATH))
  chunk("PlaceholderSync", NS)
  return inst
end
''')
G.SYNC_PATH = str(SRC / "Sync.lua").encode()
G.GUILDBANK_PATH = str(SRC / "GuildBank.lua").encode()

def lt(obj):
    """Python structure → Lua table. The runtime has no string encoding, so every key and string must be bytes."""
    if isinstance(obj, dict): return L.table_from({(k.encode() if isinstance(k, str) else k): lt(v) for k, v in obj.items()})
    if isinstance(obj, (list, tuple)): return L.table_from([lt(v) for v in obj])
    if isinstance(obj, str): return obj.encode()
    return obj

def make_loot_payload(rev, n_items=1000, n_chars=120):
    items = {f"item{i}": {"name": f"Item of Testing {i}", "needers": [f"Char{j}" for j in range(i % 6)], "boss": "Some Boss", "slot": "Trinket"} for i in range(n_items)}
    chars = {f"Char{j}": {"class": "WARRIOR", "owned": [f"item{(j*7+k)%n_items}" for k in range(5)]} for j in range(n_chars)}
    return lt({"items": items, "chars": chars, "guild": "Placeholder", "generatedAt": 1762000000 + rev})

def make_bank(at, by, guild="Placeholder", tabs=8, per_tab=98):
    tab_list = [{"index": t, "name": f"Tab {t}", "viewable": True,
                 "items": [{"slot": s, "id": 1000 + (s * 13 + t) % 300, "name": f"Thing {s}", "count": 20, "quality": 1} for s in range(1, per_tab + 1)]}
                for t in range(1, tabs + 1)]
    return lt({"guild": guild, "realm": "Realm", "by": by, "at": at, "money": 1234567, "complete": True, "tabs": tab_list})

def new_instance(i, name, officer=False):
    inst = L.globals().NewInstance(i, name.encode(), b"Placeholder", officer)
    instances[i] = dict(id=i, name=name, full=f"{name}-Realm", guild=b"Placeholder", officer=officer, inRaid=False, online=False, busy_until=0.0, ns=inst.ns, lua=inst)
    return instances[i]

def login(i, at):
    def go(i=i):
        instances[i]["online"] = True
        instances[i]["lua"].ns.Sync.Start()
    schedule(at - clock, go, i, None)

def run_until(t_end):
    global clock
    while events and events[0][0] <= t_end:
        t, _, tid = heapq.heappop(events)
        tm = timers.get(tid)
        if tm is None or tm["cancelled"]:
            timers.pop(tid, None); continue
        clock = t
        G.CLOCK = clock
        G.CUR = instances[tm["inst"]]["lua"]
        tm["fn"]()
        if tm["period"]: heapq.heappush(events, (clock + tm["period"], tid, tid))
        else: timers.pop(tid, None)
    clock = t_end
    G.CLOCK = clock

def versions():
    out = []
    for i in instances.values():
        c = i["ns"].Loot.Current()
        gb = i["ns"].db.guildBank
        out.append((c.rev if c else 0, gb.at if gb else 0))
    return out

def reset_stats():
    stats["msgs"].clear(); stats["bytes"].clear(); stats["per_sender"].clear(); stats["d_sends"].clear()

def report(title):
    total = sum(stats["bytes"].values())
    top = max(stats["per_sender"].values(), default=0)
    print(f"\n== {title}")
    print("   messages:", dict(sorted(stats["msgs"].items())))
    print(f"   bytes on the wire: {total/1024:.1f} KB total, busiest sender {top/1024:.1f} KB")
    print(f"   data sends: {len(stats['d_sends'])}", stats["d_sends"][:8], "..." if len(stats["d_sends"]) > 8 else "")

failures = []
def check(cond, msg):
    print(("   ok   " if cond else "   FAIL ") + msg)
    if not cond: failures.append(msg)

random.seed(1); L.execute("math.randomseed(1)")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 100

# ---- scenario 1: one bridge officer holds everything, 99 others log in over ten minutes ---------
officer = new_instance(1, "Bridge", officer=True)
G.SetBridgeLoot(1, lt({"rev": 5, "generatedAt": 1762000005, "payload": make_loot_payload(5)}))
G.SetBank(1, make_bank(1762000100, "Bridge-Realm"))
for i in range(2, N + 1): new_instance(i, f"Member{i}", officer=(i <= 5))
G.ROSTER = lt([{"name": inst["name"], "rank": "officer" if inst["officer"] else "raider"} for inst in instances.values()])
login(1, 0)
for i in range(2, N + 1): login(i, random.uniform(5, 600))
run_until(900)
v = versions()
report(f"S1: {N} members log in over 10 min, one holder of loot rev 5 + a bank scan")
check(all(l == 5 for l, _ in v), "everyone holds loot rev 5")
check(all(b == 1762000100 for _, b in v), "everyone holds the bank scan")
d = len(stats["d_sends"])
check(d <= 75, f"data sends stay near two per 20 s window per kind ({d})")
busiest = max(stats["per_sender"].values()) / 1024
check(busiest < 400, f"busiest sender under 400 KB ({busiest:.0f} KB)")

# ---- scenario 2: everyone online, the bridge brings rev 6 ----------------------------------------
reset_stats()
G.SetBridgeLoot(1, lt({"rev": 6, "generatedAt": 1762000006, "payload": make_loot_payload(6)}))
G.CUR = officer["lua"]; officer["ns"].Sync.Changed()
run_until(clock + 300)
v = versions()
report("S2: all online, loot rev 6 appears on the bridge PC")
check(all(l == 6 for l, _ in v), "everyone moves to rev 6")
d = len(stats["d_sends"])
check(d <= 6, f"few data sends for one new rev ({d})")

# ---- scenario 3: a raider opens the bank; the scan must reach the bridge officer -----------------
reset_stats()
raider = instances[50]
G.SetBank(50, make_bank(1762001000, "Member50-Realm"))
G.CUR = raider["lua"]; raider["ns"].Sync.Changed()
run_until(clock + 300)
gb = officer["ns"].db.guildBank
report("S3: Member50 scans the bank")
check(gb is not None and gb.at == 1762001000, "the bridge officer holds the raider's scan")
check(gb is not None and bytes(gb.sharedFrom or b"") == b"Member50-Realm", "scan is marked as received from Member50")
check(officer["ns"].pendingUpload == True, "bridge PC flags an upload")
d = len(stats["d_sends"])
check(d <= 6, f"few data sends for one scan ({d})")

# ---- scenario 4: a 40-player raid inside the guild, new rev -------------------------------------
reset_stats()
for i in range(1, 41): instances[i]["inRaid"] = True; G.SetInst(i, b"inRaid", True)
G.SetBridgeLoot(1, lt({"rev": 7, "generatedAt": 1762000007, "payload": make_loot_payload(7)}))
G.CUR = officer["lua"]; officer["ns"].Sync.Changed()
run_until(clock + 300)
v = versions()
report("S4: 40 of them in a raid, loot rev 7 appears")
check(all(l == 7 for l, _ in v), "everyone moves to rev 7")
d = len(stats["d_sends"])
check(d <= 8, f"data sends bounded with raid + guild channels ({d})")
for i in range(1, 41): instances[i]["inRaid"] = False; G.SetInst(i, b"inRaid", False)

# ---- scenario 5: an hour of nothing happening ---------------------------------------------------
reset_stats()
run_until(clock + 3600)
report("S5: one quiet hour")
check(stats["msgs"].get("H", 0) <= N * 13, f"only periodic 'have' lines ({stats['msgs'].get('H', 0)})")
check(len(stats["d_sends"]) == 0, "no data sends when nothing changed")

# ---- scenario 6: 30 people log in at the same second after a server restart ---------------------
reset_stats()
for i in range(60, 90): instances[i]["online"] = False
# fresh Sync state needs fresh instances: recreate them
for i in range(60, 90): new_instance(i, f"Member{i}")
for i in range(60, 90): login(i, clock + 1)
run_until(clock + 240)
v = versions()
report("S6: 30 members log in together with empty data")
check(all(l == 7 for l, _ in v), "the 30 catch up to rev 7")
check(all(b == 1762001000 for _, b in v), "the 30 receive the latest bank scan")
d = len(stats["d_sends"])
check(d <= 6, f"the burst is answered by a few sends, not thirty ({d})")

print("\n" + ("ALL CHECKS PASSED" if not failures else f"{len(failures)} CHECK(S) FAILED"))
sys.exit(1 if failures else 0)
