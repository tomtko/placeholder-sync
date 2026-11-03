"""
Runs the real src/GuildBank.lua against a fake guild bank: tabs that answer, tabs the client already has (no event),
item links that arrive late, a transaction log the server answers late or never, a bank closed mid-scan, a tab the
character cannot view, and a full 8 x 98 bank. Checks what ends up in <Addon>DB.guildBank and guildBank.log.

    python3 test/bank_sim.py
"""
import heapq, pathlib, sys
import lupa

ROOT = pathlib.Path(__file__).resolve().parents[1]
L = lupa.LuaRuntime(encoding=None, unpack_returned_tuples=True)
G = L.globals()

clock = 0.0; events = []; timers = {}; seq = 0; last_activity = 0.0
def schedule(delay, fn, period=None):
    global seq
    seq += 1; timers[seq] = dict(fn=fn, period=period, cancelled=False)
    heapq.heappush(events, (clock + max(delay, 0), seq, seq)); return seq
G.py_schedule = lambda d, fn, rep: schedule(float(d), fn, float(d) if rep else None)
G.py_cancel = lambda tid: timers.__contains__(int(tid)) and timers[int(tid)].__setitem__("cancelled", True)

def run_until(t_end):
    global clock, last_activity
    while events and events[0][0] <= t_end:
        t, _, tid = heapq.heappop(events); tm = timers.get(tid)
        if tm is None or tm["cancelled"]: timers.pop(tid, None); continue
        clock = t; G.CLOCK = clock; tm["fn"](); last_activity = clock
        if tm["period"]: heapq.heappush(events, (clock + tm["period"], tid, tid))
        else: timers.pop(tid, None)
    clock = t_end; G.CLOCK = clock

# ---- the fake bank ------------------------------------------------------------------------------
class Bank:
    def __init__(self):
        self.tabs = {}            # index -> dict(name, viewable, items {slot: (id, count)}, cached, link_delay, log, log_delay)
        self.money = 5_000_000
        self.money_log = []       # (type, who, amount, h)
        self.money_log_delay = 0.2
        self.linked_since = {}    # (tab, slot) -> time links are available
        self.queries = []         # (time, kind, tab)
        self.answered_at = {}     # tab -> time the client got the tab's slots
    def tab(self, i, items, viewable=True, cached=False, link_delay=0.0, log=(), log_delay=0.2):
        self.tabs[i] = dict(name=f"Tab {i}", viewable=viewable, items=items, cached=cached, link_delay=link_delay, log=list(log), log_delay=log_delay, queried_at=None)
bank = Bank()
FRAMES = []
def fire(event, *args):
    for f in FRAMES:
        if event in f["events"] and f["handler"] is not None: f["handler"](f["obj"], event.encode(), *[a.encode() if isinstance(a, str) else a for a in args])

def q_tab(i):
    t = bank.tabs.get(int(i)); bank.queries.append((round(clock, 2), "tab", int(i)))
    if not t: return
    t["queried_at"] = clock
    if not t["cached"]: schedule(0.2, lambda: fire("GUILDBANKBAGSLOTS_CHANGED"))
def item_link(tab, slot):
    t = bank.tabs.get(int(tab)); 
    if not t or int(slot) not in t["items"]: return None
    if t["queried_at"] is None and not t["cached"]: return None
    if t["link_delay"] and clock < (t["queried_at"] or 0) + t["link_delay"]: return None
    iid, _ = t["items"][int(slot)]
    return f"|cffffffff|Hitem:{iid}::::::::60:::::|h[Item {iid}]|h|r".encode()
def item_info(tab, slot):
    t = bank.tabs.get(int(tab))
    if not t or int(slot) not in t["items"]: return None
    iid, count = t["items"][int(slot)]
    return (1000 + iid, count, False, False, 1)
def q_log(i):
    i = int(i); bank.queries.append((round(clock, 2), "log", i))
    delay = bank.money_log_delay if i == 9 else bank.tabs.get(i, {}).get("log_delay", 0.2)
    if delay is None: return                      # the server never answers
    def answer(i=i):
        if i == 9: bank.money_answered = True
        else: bank.tabs[i]["log_answered"] = True
        fire("GUILDBANKLOG_UPDATE")
    schedule(delay, answer)
def n_tx(tab):
    t = bank.tabs.get(int(tab)); return len(t["log"]) if t and t.get("log_answered") else 0
def tx(tab, i):
    ty, who, iid, n, h = bank.tabs[int(tab)]["log"][int(i) - 1]
    return (ty.encode(), who.encode(), f"|Hitem:{iid}::|h[Item {iid}]|h".encode(), n, None, None, 0, 0, 0, h)
def n_money(): return len(bank.money_log) if getattr(bank, "money_answered", False) else 0
def money_tx(i):
    ty, who, amount, h = bank.money_log[int(i) - 1]; return (ty.encode(), who.encode(), amount, 0, 0, 0, h)
G.py_q_tab, G.py_item_link, G.py_item_info, G.py_q_log, G.py_n_tx, G.py_tx, G.py_n_money, G.py_money_tx = q_tab, item_link, item_info, q_log, n_tx, tx, n_money, money_tx
G.py_num_tabs = lambda: max(bank.tabs) if bank.tabs else 0
G.py_tab_info = lambda i: (bank.tabs[int(i)]["name"].encode(), 1, bank.tabs[int(i)]["viewable"]) if int(i) in bank.tabs else None
G.py_money = lambda: bank.money
G.py_frame = lambda obj: FRAMES.append(dict(obj=obj, events=set(), handler=None)) or (len(FRAMES) - 1)
G.py_frame_event = lambda idx, e: FRAMES[int(idx)]["events"].add(bytes(e).decode())
G.py_frame_handler = lambda idx, h: FRAMES[int(idx)].__setitem__("handler", h)

G.GB_PATH = str(ROOT / "src" / "GuildBank.lua").encode()
L.execute(r'''
CLOCK = 0
MAX_GUILDBANK_SLOTS_PER_TAB = 98
MAX_GUILDBANK_TABS = 8
function GetTime() return CLOCK end
function time() return 1762000000 + math.floor(CLOCK) end
function GetGuildInfo() return "Placeholder", "Officer", 1, "Realm" end
function GetNormalizedRealmName() return "Realm" end
function GetRealmName() return "Realm" end
function GetNumGuildBankTabs() return py_num_tabs() end
function GetGuildBankTabInfo(i) return py_tab_info(i) end
function QueryGuildBankTab(i) py_q_tab(i) end
function GetGuildBankItemLink(t, s) return py_item_link(t, s) end
function GetGuildBankItemInfo(t, s) return py_item_info(t, s) end
function GetGuildBankMoney() return py_money() end
function QueryGuildBankLog(t) py_q_log(t) end
function GetNumGuildBankTransactions(t) return py_n_tx(t) end
function GetGuildBankTransaction(t, i) return py_tx(t, i) end
function GetNumGuildBankMoneyTransactions() return py_n_money() end
function GetGuildBankMoneyTransaction(i) return py_money_tx(i) end
Enum = { PlayerInteractionType = { GuildBanker = 10 } }
C_Timer = {
  NewTimer = function(d, fn) local id = py_schedule(d, fn, false) return { id = id, Cancel = function(self) py_cancel(self.id) end } end,
  After = function(d, fn) py_schedule(d, fn, false) end,
  NewTicker = function(d, fn) local id = py_schedule(d, fn, true) return { id = id, Cancel = function(self) py_cancel(self.id) end } end,
}
function CreateFrame()
  local f = {}
  f.idx = py_frame(f)
  function f:RegisterEvent(e) py_frame_event(self.idx, e) end
  function f:UnregisterEvent() end
  function f:SetScript(_, h) py_frame_handler(self.idx, h) end
  return f
end
NS = { db = { characters = {}, options = {} }, notices = {}, prints = {} }
NS.Print = function(m, ...) NS.prints[#NS.prints + 1] = select("#", ...) > 0 and m:format(...) or m end
NS.Notify = function(m, ...) NS.notices[#NS.notices + 1] = select("#", ...) > 0 and m:format(...) or m end
NS.Option = function(k) if k == "chat" then return false end return true end
NS.PlayerKey = function() return "Officer-Realm" end
NS.ForThisGuild = function() return true end
NS.GuildName = function() return "Placeholder" end
NS.FormatMoney = function(c) return tostring(c) end
assert(loadfile(GB_PATH))("PlaceholderSync", NS)
''')

NS = G.NS
failures = []
def check(cond, msg):
    print(("   ok   " if cond else "   FAIL ") + msg)
    if not cond: failures.append(msg)
def open_bank(): fire("GUILDBANKFRAME_OPENED")
def close_bank(): fire("GUILDBANKFRAME_CLOSED")
def gb(): return NS.db.guildBank
def lget(t, key):
    """Field of a Lua table under the byte-key runtime."""
    return None if t is None else t[key.encode()]
def lvalues(t): return [] if t is None else [t[k] for k in list(t.keys())]
def tab_items(t):
    items = lget(t, "items")
    return {int(lget(i, "slot")): int(lget(i, "count")) for i in lvalues(items)} if items is not None else {}
def tabs(): return {int(lget(t, "index")): t for t in lvalues(lget(gb(), "tabs"))} if gb() is not None else {}
def log_tabs():
    log = lget(gb(), "log")
    if log is None: return None
    return {int(lget(e, "tab")): len(lvalues(lget(e, "e"))) for e in lvalues(lget(log, "tabs"))}
def money_lines():
    log = lget(gb(), "log"); return 0 if log is None else len(lvalues(lget(log, "money")))
def complete(): return bool(lget(gb(), "complete"))
def scan_at(): return int(lget(gb(), "at"))
def items_of(n, base=1): return {s: (base + s, 20) for s in range(1, n + 1)}

print("== 1. ordinary bank: six tabs answer, log answers")
for i in range(1, 7): bank.tab(i, items_of(10 + i, i * 100), log=[("deposit", f"Who{i}", i * 100 + 1, 5, 1), ("withdraw", "Mlad", i * 100 + 2, 1, 0)])
bank.money_log = [("deposit", "Fluffys", 100000, 2)]
open_bank(); run_until(clock + 30); close_bank(); run_until(clock + 5)
check(gb() is not None and complete(), "scan complete")
check(len(tabs()) == 6 and all(len(tab_items(tabs()[i])) == 10 + i for i in range(1, 7)), "every tab has its items")
check(log_tabs() == {i: 2 for i in range(1, 7)}, f"log copied for six tabs ({log_tabs()})")
check(money_lines() == 1, "money log copied")
check(bool(lget(NS, "pendingUpload")), "upload flagged")
check(last_activity < 15, f"scan and log done {last_activity:.1f}s after opening")
t_scan1 = clock

print("== 2. the log for tab 5 is never answered, tab 3 answers late (its event lands while tab 5 is awaited)")
bank.tabs[5]["log_delay"] = None; bank.tabs[3]["log_delay"] = 4.5
for t in bank.tabs.values(): t.pop("log_answered", None)
bank.money_answered = False
bank.queries.clear(); start = clock
open_bank(); run_until(clock + 60); close_bank(); run_until(clock + 5)
lt = log_tabs()
check(lt is not None and 5 not in lt, f"tab 5 left out of the copy, not sent empty ({lt})")
check(lt is not None and lt.get(3) == 2, "tab 3 arrived through the retry window")
check(len([q for q in bank.queries if q[1] == "log" and q[2] == 5]) == 2, f"tab 5 was asked exactly twice ({[q for q in bank.queries if q[1] == 'log' and q[2] == 5]})")
check(last_activity - start < 20, f"log read with a silent tab finished {last_activity - start:.1f}s after opening")
check(complete(), "scan still complete (items were fine)")

print("== 3. client already holds tabs 1-2 (no event), tab 4 item links arrive 1.2s late")
bank.tabs[5]["log_delay"] = 0.2; bank.tabs[3]["log_delay"] = 0.2
for t in bank.tabs.values(): t.pop("log_answered", None); t["queried_at"] = None
bank.money_answered = False
bank.tabs[1]["cached"] = True; bank.tabs[2]["cached"] = True; bank.tabs[4]["link_delay"] = 1.2
open_bank(); run_until(clock + 60); close_bank(); run_until(clock + 5)
check(complete(), "complete despite cached tabs and late links")
check(len(tab_items(tabs()[4])) == 14, "tab 4 read with all 14 items once links arrived")
check(bool(lget(tabs()[1], "timedOut")), "tab 1 noted as read after the timeout")

print("== 4. bank closed 2 seconds into the scan, then reopened")
bank.tabs[1]["cached"] = False; bank.tabs[2]["cached"] = False; bank.tabs[4]["link_delay"] = 0
for t in bank.tabs.values(): t.pop("log_answered", None); t["queried_at"] = None
before = scan_at()
open_bank(); run_until(clock + 2.0); close_bank(); run_until(clock + 5)
check(gb() is not None and complete() and len(tabs()) == 6, "earlier full tabs kept when a quick open gives a partial scan")
for t in bank.tabs.values(): t.pop("log_answered", None); t["queried_at"] = None
bank.money_answered = False
open_bank(); run_until(clock + 60); close_bank(); run_until(clock + 5)
check(scan_at() > before and complete(), "reopening scans fully again")

print("== 5. a tab this character cannot view keeps the earlier copy")
bank.tabs[6]["viewable"] = False
for t in bank.tabs.values(): t.pop("log_answered", None); t["queried_at"] = None
bank.money_answered = False
open_bank(); run_until(clock + 60); close_bank(); run_until(clock + 5)
check(len(tab_items(tabs()[6])) == 16, "tab 6 still has the 16 items from the last scan that could see it")
check(log_tabs() is not None and 6 not in log_tabs(), "no log asked for the hidden tab")
bank.tabs[6]["viewable"] = True

print("== 6. full bank: 8 tabs x 98 stacks, 25 log lines each")
bank.tabs.clear()
for i in range(1, 9): bank.tab(i, items_of(98, i * 1000), log=[("deposit", f"P{k}", i * 1000 + k, 1, 0) for k in range(25)])
bank.money_log = [("deposit", f"P{k}", 10000, 0) for k in range(25)]
bank.money_answered = False
start = clock; open_bank(); run_until(clock + 120); close_bank(); run_until(clock + 5)
check(complete() and sum(len(tab_items(t)) for t in tabs().values()) == 784, f"784 stacks recorded ({sum(len(tab_items(t)) for t in tabs().values())})")
check(log_tabs() == {i: 25 for i in range(1, 9)} and money_lines() == 25, f"25 log lines per tab plus money ({log_tabs()}, money {money_lines()})")
check(last_activity - start < 20, f"full bank scanned and logged {last_activity - start:.1f}s after opening")

print("\n" + ("ALL CHECKS PASSED" if not failures else f"{len(failures)} CHECK(S) FAILED"))
sys.exit(1 if failures else 0)
