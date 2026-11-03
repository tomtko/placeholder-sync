"""
Loads the whole addon the way the game does (every file in toc order, one shared private table, Lua 5.1) under a
stubbed client, then plays a session: login, every slash command, a bank visit with autoscan on and off, loot
lookups against bridge data, council award sweeps, logout. Any Lua error fails the run. At the end the
SavedVariables table is written in the game's own file format to the path in $ADDON_SV_OUT (default: dist/), so
the backend's ingest tests can parse exactly what the addon produces.

    python3 test/addon_load.py
"""
import heapq, os, pathlib, sys
import lupa.lua51

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
L = lupa.lua51.LuaRuntime(encoding=None, unpack_returned_tuples=True)
G = L.globals()

clock = 100000.0; events = []; timers = {}; seq = 0   # GetTime() is the client's uptime: never near zero at login
def schedule(delay, fn, period=None):
    global seq
    seq += 1; timers[seq] = dict(fn=fn, period=period, cancelled=False)
    heapq.heappush(events, (clock + max(delay, 0), seq, seq)); return seq
G.py_schedule = lambda d, fn, rep: schedule(float(d), fn, float(d) if rep else None)
G.py_cancel = lambda tid: timers.__contains__(int(tid)) and timers[int(tid)].__setitem__("cancelled", True)
def run(seconds):
    global clock
    t_end = clock + seconds
    while events and events[0][0] <= t_end:
        t, _, tid = heapq.heappop(events); tm = timers.get(tid)
        if tm is None or tm["cancelled"]: timers.pop(tid, None); continue
        clock = t; G.CLOCK = clock; tm["fn"]()
        if tm["period"]: heapq.heappush(events, (clock + tm["period"], tid, tid))
        else: timers.pop(tid, None)
    clock = t_end; G.CLOCK = clock

printed = []; sent = []
G.py_print = lambda s: printed.append(bytes(s).decode("utf-8", "replace").replace("|cff7fd5ffPlaceholderSync:|r ", "PlaceholderSync: "))
G.py_send = lambda text, dist, target: sent.append((bytes(text)[:12], bytes(dist).decode()))
G.py_compress = lambda s: __import__("zlib").compress(bytes(s), 9)
G.py_decompress = lambda s: __import__("zlib").decompress(bytes(s))
G.py_b64e = lambda s: __import__("base64").b64encode(bytes(s))
G.py_b64d = lambda s: __import__("base64").b64decode(bytes(s))

L.execute(r'''
CLOCK = 100000
BASE = 1762000000 - 100000
WOW = { name = "Fluffys", guild = "Placeholder", officer = true, combat = false, inRaid = false, bankOpen = false,
        tabs = {}, money = 2345678, log = {}, moneyLog = {}, loaded = { PlaceholderSync = true } }
FRAMES = {}
function print(...) local p = {} for i = 1, select("#", ...) do p[#p + 1] = tostring(select(i, ...)) end py_print(table.concat(p, " ")) end
function GetTime() return CLOCK end
local os_time, os_date = os.time, os.date
function time(t) if t then return os_time(t) end return BASE + math.floor(CLOCK) end
function date(fmt, t) return os_date(fmt, t or time()) end
function GetBuildInfo() return "12.1.5", "66001", "Oct 1 2026", 120105 end
WOW_PROJECT_ID = 1
function IsLoggedIn() return true end
function ReloadUI() WOW.reloaded = (WOW.reloaded or 0) + 1 end
function hooksecurefunc(t, name, fn) if type(t) == "string" then return end local orig = t[name] t[name] = function(...) local r = { orig(...) } fn(...) return unpack(r) end end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function UnitName() return WOW.name end
function UnitGUID() return "Player-1403-0000ABCD" end
function UnitClass() return "Warlock", "WARLOCK" end
function UnitLevel() return 60 end
function GetGuildInfo() return WOW.guild, "Officer", 1, "Realm" end
function GetRealmName() return "Realm" end
function GetNormalizedRealmName() return "Realm" end
function IsInGuild() return WOW.guild ~= nil end
function IsInRaid() return WOW.inRaid end
LE_PARTY_CATEGORY_HOME = 1
function InCombatLockdown() return WOW.combat end
function Ambiguate(n) return (tostring(n):match("^([^-]+)")) end
C_AddOns = { GetAddOnMetadata = function(a, k) if k == "Version" then return "0.3.4" end end, IsAddOnLoaded = function(a) return WOW.loaded[a] == true end }
C_GuildInfo = { GuildRoster = function() end, IsGuildOfficer = function() return WOW.officer end }
function GetNumGuildMembers() return 40, 25 end
function GetGuildRosterInfo(i) return "Member" .. i .. "-Realm", i <= 5 and "Officer" or "Raider" end
C_ChatInfo = { SendAddonMessage = function() end, RegisterAddonMessagePrefix = function() end }
Enum = { CompressionMethod = { Zlib = 1 }, CompressionLevel = { OptimizeForSize = 9 }, AddOnRestrictionType = { Chat = 1 },
         AddOnRestrictionState = { Inactive = 0 }, PlayerInteractionType = { GuildBanker = 10 } }
MAX_GUILDBANK_SLOTS_PER_TAB, MAX_GUILDBANK_TABS = 98, 8
local function ser(v, out)
  local t = type(v)
  if t == "table" then out[#out + 1] = "{" for k, x in pairs(v) do out[#out + 1] = "[" .. (type(k) == "string" and string.format("%q", k) or tostring(k)) .. "]=" ser(x, out) out[#out + 1] = "," end out[#out + 1] = "}"
  elseif t == "string" then out[#out + 1] = string.format("%q", v) else out[#out + 1] = tostring(v) end
end
C_EncodingUtil = {
  SerializeCBOR = function(v) local out = {} ser(v, out) return table.concat(out) end,
  DeserializeCBOR = function(s) return loadstring("return " .. s)() end,
  CompressString = function(s) return py_compress(s) end, DecompressString = function(s) return py_decompress(s) end,
  EncodeBase64 = function(s) return py_b64e(s) end, DecodeBase64 = function(s) return py_b64d(s) end,
}
C_Timer = {
  NewTimer = function(d, fn) local id = py_schedule(d, fn, false) return { id = id, Cancel = function(self) py_cancel(self.id) end } end,
  After = function(d, fn) py_schedule(d, fn, false) end,
  NewTicker = function(d, fn) local id = py_schedule(d, fn, true) return { id = id, Cancel = function(self) py_cancel(self.id) end } end,
}
function CreateFrame(kind, name, parent)
  local f = { events = {}, kind = kind }
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:SetScript(k, h) self[k] = h end
  function f:SetSize() end function f:SetPoint() end function f:SetShown() end function f:Show() end function f:Hide() end
  function f:CreateFontString() local s = {} function s:SetAllPoints() end function s:SetJustifyH() end function s:SetText(t) self.t = t end function s:SetTextColor() end return s end
  FRAMES[#FRAMES + 1] = f
  return f
end
function FireEvent(e, ...) for _, f in ipairs(FRAMES) do if f.events[e] and f.OnEvent then f.OnEvent(f, e, ...) end end end
GameTooltip = { lines = {} }
function GameTooltip:SetOwner() wipe(self.lines) end
function GameTooltip:AddLine(t) self.lines[#self.lines + 1] = t end
function GameTooltip:Show() end
function GameTooltip:Hide() end
SlashCmdList = {}
local ACE = { handlers = {} }
function ACE:RegisterComm(prefix, fn) self.handlers[prefix] = fn end
function ACE:SendCommMessage(prefix, text, dist, target, prio) py_send(text, dist, target or "") end
function LibStub(name, silent) if name == "AceComm-3.0" then return ACE end return nil end
ACECOMM = ACE
-- the character sheet
NUM_BAG_SLOTS = 4
CR_HIT_MELEE, CR_HIT_SPELL, CR_HASTE_MELEE, CR_DEFENSE_SKILL = 6, 8, 18, 2
WOW_PROJECT_CAMELOT = 1
function UnitRace() return "Orc", "Orc", 2 end
function UnitFactionGroup() return "Horde", "Horde" end
function UnitSex() return 2 end
WOW.worn = { [1] = { 250224, 2583 }, [2] = { 274497, 0 }, [5] = { 19145, 1891 }, [16] = { 17182, 2564 } }
function GetInventoryItemLink(u, slot) local w = WOW.worn[slot] if not w then return nil end return "|cffa335ee|Hitem:" .. w[1] .. ":" .. w[2] .. ":0:0:0:0:0:0:60:::::|h[Worn " .. w[1] .. "]|h|r" end
function GetInventoryItemQuality(u, slot) return WOW.worn[slot] and 4 or nil end
function GetInventoryItemID(u, slot) return WOW.worn[slot] and WOW.worn[slot][1] or nil end
C_Item = { GetDetailedItemLevelInfo = function(link) return 115, false, 115 end }
function GetAverageItemLevel() return 110.5, 108.25 end
function GetProfessions() return 1, 2, nil, 4, 5, 6 end
function GetProfessionInfo(i) local n = { "Tailoring", "Enchanting", nil, "Fishing", "Cooking", "First Aid" } return n[i], 1, 300 - i, 300, 0, 0, 100 + i, 0 end
WOW.skillHeaders = { [1] = { collapsed = true } }
WOW.skillLines = { { "Professions", true }, { "Tailoring", false, 300, 300 }, { "Weapon Skills", true }, { "Daggers", false, 290, 300 } }
function GetNumSkillLines() local n = 0 for i, l in ipairs(WOW.skillLines) do if l[2] then n = n + 1 elseif not WOW.skillHeaders[1].collapsed or i > 2 then n = n + 1 end end return n end
function GetSkillLineInfo(i) local vis = {} for j, l in ipairs(WOW.skillLines) do if l[2] or not WOW.skillHeaders[1].collapsed or j > 2 then vis[#vis + 1] = l end end local l = vis[i] if not l then return nil end return l[1], l[2], not WOW.skillHeaders[1].collapsed, l[3], 0, 0, l[4] end
function ExpandSkillHeader(i) WOW.skillHeaders[1].collapsed = false end
function CollapseSkillHeader(i) WOW.skillHeaders[1].collapsed = true WOW.skillCollapsedAgain = true end
-- Forever talents: one trait config, one tree, three groups
C_ClassTalents = { GetActiveConfigID = function() return 501 end }
C_SpecializationInfo = { GetSpecialization = function() return 1 end, GetSpecializationInfo = function(i) return 1486, "Warlock", "", 1, "DAMAGER" end }
local NODES = { [1] = { group = 11600, spell = 18827, rank = 5, max = 5, x = 100, y = 100 }, [2] = { group = 11600, spell = 17810, rank = 0, max = 2, x = 200, y = 100 }, [3] = { group = 11610, spell = 18288, rank = 3, max = 3, x = 100, y = 100 }, [4] = { group = 11622, spell = 17877, rank = 1, max = 1, x = 300, y = 500 } }
C_Traits = {
  GetConfigInfo = function(id) return { ID = id, treeIDs = { 900 } } end,
  GetGroupDisplayInfoByTreeID = function(tree) return { { groupID = 11622, displayName = "Destruction", order = 3 }, { groupID = 11600, displayName = "Affliction", order = 1 }, { groupID = 11610, displayName = "Demonology", order = 2 } } end,
  GetGroupCurrencyInfo = function(cfg, groups) local spent = 0 for _, n in pairs(NODES) do if n.group == groups[1] then spent = spent + n.rank end end return { { currencyInfos = { { spent = spent } } } } end,
  GetTreeCurrencyInfo = function() return { { quantity = 42 } } end,
  GetTreeNodes = function(tree) return { 1, 2, 3, 4 } end,
  GetNodeInfo = function(cfg, id) local n = NODES[id] return { ID = id, isVisible = true, ranksPurchased = n.rank, activeRank = n.rank, maxRanks = n.max, posX = n.x, posY = n.y, entryIDs = { id * 10 }, groupIDs = { n.group }, activeEntry = n.rank > 0 and { entryID = id * 10 } or nil } end,
  GetEntryInfo = function(cfg, entry) return { definitionID = entry * 100 } end,
  GetDefinitionInfo = function(def) return { spellID = NODES[def / 1000].spell } end,
  GenerateImportString = function() return "BwAAAAAA" end,
}
C_Spell = { GetSpellInfo = function(id) return { name = "Spell " .. id, spellID = id } end }
-- quests: two weeklies and a daily in the log, a flagged weekly from the officers' list
C_QuestLog = {
  GetNumQuestLogEntries = function() return 4 end,
  GetInfo = function(i) return ({ { title = "Raiding", isHeader = true }, { title = "Weekly: Onyxia Head", questID = 7490, frequency = 2 },
    { title = "Daily: Fish", questID = 9000, frequency = 1 }, { title = "Weekly: Dire Maul Tribute", questID = 7491, frequency = 2 } })[i] end,
  IsComplete = function(id) return id == 7491 end,
  IsQuestFlaggedCompleted = function(id) return id == 7000 end,
}
function GetPVPLifetimeStats() return 1234, 2 end
function UnitPVPRank() return 9 end
function GetPVPRankInfo(rank) return "Knight-Lieutenant", 5 end
WOW.repCollapsed = true
local REPS = { { id = 1, name = "Classic", header = true }, { id = 530, name = "Darkspear Trolls", standing = 6, value = 9000, min = 9000, max = 21000, child = true } }
C_Reputation = {
  GetNumFactions = function() return WOW.repCollapsed and 1 or 2 end,
  GetFactionDataByIndex = function(i) local r = REPS[i] if not r then return nil end return { factionID = r.id, name = r.name, reaction = r.standing, currentStanding = r.value, currentReactionThreshold = r.min, nextReactionThreshold = r.max, isHeader = r.header or false, isCollapsed = r.header and WOW.repCollapsed or false, isChild = r.child or false } end,
  ExpandFactionHeader = function(i) WOW.repCollapsed = false end,
  CollapseFactionHeader = function(i) WOW.repCollapsed = true WOW.repCollapsedAgain = true end,
}
function UnitHealthMax() return 5000 end
function UnitPowerType() return 0 end
function UnitPowerMax(u, p) return 7000 end
function UnitArmor() return 1200, 1300, 1200, 100, 0 end
function UnitResistance(u, i) return 10 * i, 15 * i, 5 * i, 0 end
function UnitStat(u, i) return 50 + i, 60 + i, 10, 0 end
function UnitAttackPower() return 300, 50, 0 end
function GetSpellBonusDamage(school) return 400 + school end
function GetSpellBonusHealing() return 250 end
function GetCritChance() return 12.3456 end
function GetSpellCritChance(school) return 9.87 end
function GetCombatRatingBonus(cr) return cr == 8 and 6.5 or 1.25 end
function GetMoney() return 1234567 end
C_Container = {
  GetContainerNumSlots = function(bag) return bag == 0 and 16 or 14 end,
  GetContainerItemInfo = function(bag, slot) if slot > 3 then return nil end local id = 13446 + bag return { itemID = id, stackCount = 5, hyperlink = "|cffffffff|Hitem:" .. id .. "::::::::60:::::|h[Potion " .. id .. "]|h|r" } end,
}
function GetNumSavedInstances() return WOW.raidInfo and 1 or 0 end
function GetSavedInstanceInfo(i) return "Molten Core", 12345, 500000, 9, true, false, 0, true, 40, "40 Player", 10, 3 end
function RequestRaidInfo() C_Timer.After(0.5, function() WOW.raidInfo = true FireEvent("UPDATE_INSTANCE_INFO") end) end
-- the fake guild bank
function GetNumGuildBankTabs() return #WOW.tabs end
function GetGuildBankTabInfo(i) local t = WOW.tabs[i] if not t then return nil end return t.name, 1, t.viewable ~= false end
function QueryGuildBankTab(i) WOW.tabs[i].queried = true C_Timer.After(0.2, function() FireEvent("GUILDBANKBAGSLOTS_CHANGED") end) end
function GetGuildBankItemLink(tab, slot) local t = WOW.tabs[tab] local it = t and t.queried and t.items[slot] if not it then return nil end return "|cffffffff|Hitem:" .. it.id .. "::::::::60:::::|h[Item " .. it.id .. "]|h|r" end
function GetGuildBankItemInfo(tab, slot) local t = WOW.tabs[tab] local it = t and t.items[slot] if not it then return nil end return 1000 + it.id, it.count, false, false, 1 end
function GetGuildBankMoney() return WOW.money end
function GetCurrentGuildBankTab() return 1 end
function QueryGuildBankLog(tab) WOW.logQueried = (WOW.logQueried or 0) + 1 C_Timer.After(0.2, function() WOW.logReady = true FireEvent("GUILDBANKLOG_UPDATE") end) end
function GetNumGuildBankTransactions(tab) return WOW.logReady and #(WOW.log[tab] or {}) or 0 end
function GetGuildBankTransaction(tab, i) local e = WOW.log[tab][i] return e[1], e[2], "|Hitem:" .. e[3] .. "::|h[Item " .. e[3] .. "]|h", e[4], nil, nil, 0, 0, 0, e[5] end
function GetNumGuildBankMoneyTransactions() return WOW.logReady and #WOW.moneyLog or 0 end
function GetGuildBankMoneyTransaction(i) local e = WOW.moneyLog[i] return e[1], e[2], e[3], 0, 0, 0, e[4] end
-- bridge data on this PC (what the bridge writes to PlaceholderSync_Data/Data.lua), with the officer layer
PlaceholderSync_Data = { rev = 3, writtenAt = BASE - 600, generatedAt = (BASE - 700) * 1000, payload = {
  guild = "Placeholder",
  items = { ["250224"] = { n = "Mindpiercer's Sigil", s = "Trinket", b = "Charonus", r = "Midnight", id = 250224 }, ["n:spirit-rending poison"] = { n = "Spirit-Rending Poison", s = "Trinket", b = "The Coiled Isle" } },
  names = { ["mindpiercer's sigil"] = "250224", ["spirit-rending poison"] = "n:spirit-rending poison" },
  chars = { fluffys = { n = "Fluffys", p = "Tom", c = "WARLOCK", sp = "Destruction", rk = "Officer", st = "Main", bis = 3, of = 12 }, mlad = { n = "Mlad", p = "Mlad", c = "HUNTER", rk = "Raider", st = "Main", bis = 1, of = 10 } },
  needers = { ["250224"] = { "fluffys", "mlad" }, ["n:spirit-rending poison"] = { "mlad" } },
  prio = { ["250224"] = { "mlad", "fluffys" } }, prioRanks = { "Council" },
  weeklyQuests = { { id = 7000, name = "Weekly: Blackrock" }, { id = 7001, name = "Weekly: Zul'Gurub" } },
  owned = { fluffys = { ["n:spirit-rending poison"] = "2026-10-30" } },
} }
''')

# ---- load the addon in toc order ---------------------------------------------------------------
toc = (SRC / "PlaceholderSync.toc").read_text().splitlines()
files = [ln.strip() for ln in toc if ln.strip() and not ln.startswith("#") and ln.strip().endswith(".lua")]
G.NS = L.table()
errors = []
for f in files:
    chunk = L.eval("function(path, name) local fn, err = loadfile(path) if not fn then return err end local ok, e = pcall(fn, name, NS) if not ok then return e end return nil end")
    err = chunk(str(SRC / f).encode(), b"PlaceholderSync")
    print(f"load {f}: {'OK' if err is None else 'ERROR ' + bytes(err).decode()}")
    if err is not None: errors.append(f)
if errors: sys.exit(1)

fails = []
def check(cond, msg):
    print(("   ok   " if cond else "   FAIL ") + msg)
    if not cond: fails.append(msg)
def lua(src): return L.execute(src)
def pcall(src):
    """Run Lua, return (ok, err_or_result)."""
    r = L.eval("function(src) local fn, e = loadstring(src) if not fn then return false, e end return pcall(fn) end")(src.encode())
    ok = r[0] if isinstance(r, tuple) else r
    return bool(ok), (r[1] if isinstance(r, tuple) and len(r) > 1 else None)
def slash(cmd):
    printed.clear()
    ok, err = pcall(f'SlashCmdList.PLACEHOLDERSYNC({cmd!r})')
    check(ok, f"/psync {cmd or '(status)'} ran without error" + ("" if ok else f": {bytes(err).decode()}"))
    return list(printed)

print("== login")
lua('FireEvent("ADDON_LOADED", "PlaceholderSync")')
lua('FireEvent("PLAYER_LOGIN")')
run(20)
check(G.PlaceholderSyncDB is not None, "SavedVariables table created")
check(not printed, f"nothing printed at login by default ({printed})")
check(any(d == "GUILD" for _, d in sent), "announced on guild chat after login")

print("== character capture")
db0 = G.PlaceholderSyncDB
rec = db0.characters[b"Player-1403-0000ABCD"]
check(rec is not None and rec.gear is not None, "full record captured a few seconds after login")
def f(k): return rec[k.encode()] if rec is not None else None
check(f("name") == b"Fluffys" and f("class") == b"WARLOCK" and f("race") == b"Orc" and f("faction") == b"Horde" and f("level") == 60 and f("guildRank") == b"Officer" and f("sex") is None and f("flavor") is None and f("project") is None, "identity fields, no sex or client")
gear = f("gear"); check(gear is not None and len(list(gear.keys())) == 4 and gear[1].id == 250224 and gear[1].enchant == 2583 and gear[1].ilvl == 115 and gear[1].quality == 4 and gear[2].enchant is None and bytes(gear[16].name) == b"Worn 17182", "gear: ids, enchants, ilvl, quality, names")
check(f("avgIlvl") == 110.5 and f("avgIlvlEquipped") == 108.25, "average item level")
prof = f("professions"); check(prof is not None and bytes(prof.primary1.name) == b"Tailoring" and prof.primary1.skill == 299 and bytes(prof.firstAid.name) == b"First Aid" and prof.archaeology is None, "professions by slot")
skills = f("skills"); check(skills is not None and len(list(skills.keys())) == 4 and bool(G.WOW.skillCollapsedAgain), "skill lines read with the collapsed header opened and closed again")
tal = f("talents"); tals = [tal.talents[k] for k in list(tal.talents.keys())] if tal is not None else []
check(tal is not None and tal.source == b"traits" and [bytes(tal.tabs[i].name) for i in (1, 2, 3)] == [b"Affliction", b"Demonology", b"Destruction"] and [tal.tabs[i].points for i in (1, 2, 3)] == [5, 3, 1] and tal.unspent == 42, f"Forever talent trees: ordered groups and points")
check(len(tals) == 4 and any(t.spellID == 18827 and t.rank == 5 and t.tab == 1 and bytes(t.name) == b"Spell 18827" for t in tals) and any(t.rank == 0 and t.max == 2 for t in tals), "talent nodes with spell, rank, max and tab")
check(tal is not None and tal.spec is not None and tal.spec.id == 1486 and bytes(tal.exportString) == b"BwAAAAAA", "spec and export string")
qs = f("quests"); qlog = [qs.log[k] for k in list(qs.log.keys())] if qs is not None else []
check(len(qlog) == 3 and {int(q.id): (q.frequency, q.complete) for q in qlog} == {7490: (2, None), 9000: (1, None), 7491: (2, True)}, f"daily and weekly quests from the log with completion")
check(qs is not None and qs.flagged[b"7000"] is True and qs.flagged[b"7001"] is False, "officer-listed weeklies checked by flag")
pvp = f("pvp"); check(pvp is not None and pvp.honorableKills == 1234 and pvp.rank == 9 and bytes(pvp.rankName) == b"Knight-Lieutenant", "pvp kills and rank")
reps = f("reputations"); check(reps is not None and len(list(reps.keys())) == 2 and bytes(reps[2].name) == b"Darkspear Trolls" and reps[2].standing == 6 and bool(G.WOW.repCollapsedAgain) and bool(G.WOW.repCollapsed), "reputations read under a collapsed header, header restored")
st = f("stats"); check(st is not None and st.hp == 5000 and st.mana == 7000 and st.armor == 1300 and st.resistances.fire == 30 and st.strength == 61 and st.attackPower == 350 and st.spellPower == 407 and st.healingPower == 250 and st.meleeCrit == 12.35 and st.spellHit == 6.5, "stats and resistances")
bg = f("bags"); bagd = {bytes(k).decode(): v for k, v in [(k, bg[k]) for k in bg.keys()]} if bg is not None else {}
check(bg is not None and bagd["items"][13446] == 15 and bagd["items"][13450] == 15 and bagd["slots"] == 72 and bagd["free"] == 57 and bytes(bagd["names"][13446]) == b"Potion 13446", f"bag contents aggregated by item ({ {k: (v if isinstance(v, (int, float)) else '…') for k, v in bagd.items()} })")
check(f("money") == 1234567, "money")
lk = f("lockouts"); check(lk is not None and len(list(lk.keys())) == 1 and bytes(lk[1].name) == b"Molten Core" and lk[1].progress == 3 and lk[1].raid is True, "raid lockouts after RequestRaidInfo")
miss = f("missing"); miss_l = [bytes(v).decode() for v in miss.values()] if miss is not None else []
check("UnitHonorLevel" in miss_l and "GetNumTalentTabs" not in miss_l and "GetFactionInfo" not in miss_l, f"absent APIs listed, used families not ({miss_l})")
check(f("errors") is None, f"no capture errors ({f('errors') and [bytes(v) for v in f('errors').values()]})")
check(f("reason") in (b"login", b"change"), f"reason recorded ({f('reason')})")
# a gear change outside combat recaptures after the debounce; in combat it waits
lua('WOW.worn[2] = { 18814, 0 }; FireEvent("PLAYER_EQUIPMENT_CHANGED")'); run(12)
rec = G.PlaceholderSyncDB.characters[b"Player-1403-0000ABCD"]
check(rec.gear[2].id == 18814 and rec.reason == b"change", "equipment change recaptured after the debounce")
lua('WOW.combat = true; WOW.worn[2] = { 19379, 0 }; FireEvent("PLAYER_EQUIPMENT_CHANGED")'); run(25)
rec = G.PlaceholderSyncDB.characters[b"Player-1403-0000ABCD"]
check(rec.gear[2].id == 18814, "no capture during combat")
lua('WOW.combat = false'); run(12)
rec = G.PlaceholderSyncDB.characters[b"Player-1403-0000ABCD"]
check(rec.gear[2].id == 19379, "captured once combat ended")
out = slash("capture"); check(out and out[0].startswith("PlaceholderSync: character data: 4 items worn (ilvl 108)"), f"/psync capture ({out})")

print("== slash commands")
out = slash("")
check(any("no guild bank scan yet" in l for l in out), "status says no scan yet")
check(any("settings: chat off, autoscan on, share on" in l for l in out), "status lists the settings with defaults")
check(any("serving guild Placeholder" in l for l in out), "status names the guild from the bridge data")
check(any(l.startswith("PlaceholderSync: character data: ") for l in out), "status has the character data line")
out = slash("help"); check(len(out) == 4 and any("chat on|off" in l for l in out) and "capture" in out[0], "help lists commands and three settings")
out = slash("chat on"); check(out == ["PlaceholderSync: chat on."], f"chat on confirms ({out})")
out = slash("chat"); check(out == ["PlaceholderSync: chat off."], "bare chat toggles back")
out = slash("autoscan off"); check(out and "autoscan off" in out[0], "autoscan off")
out = slash("share off"); check(out and "Applies after /reload" in out[0], "share off says it applies after reload")
out = slash("share on"); check(out and out[0].endswith("share on."), "share on")
out = slash("apicheck"); check(out and "all " in out[0] and "present" in out[0], f"apicheck: every API present under the stub ({out})")
out = slash("awards"); check(out and "0 new award" in out[0], "awards sweep with nothing to find")
out = slash("scan"); check(out == ["PlaceholderSync: open the guild bank first."], "scan without the bank open")
out = slash("sync"); check(out and out[0].startswith("PlaceholderSync: asked guild"), "sync asks the guild")
out = slash("forget"); check(out == ["PlaceholderSync: shared copies dropped."], "forget")
out = slash("debug"); check(out and "sync debug on" in out[0], "debug on"); slash("debug")
out = slash("nonsense"); check(len(out) == 4, "unknown command shows help")
out = slash("CHAT ON"); check(out == ["PlaceholderSync: chat on."], "commands are case-insensitive")
slash("chat off")

print("== bank visit with autoscan off: nothing recorded")
lua('WOW.tabs = { { name = "Mats", items = { [1] = { id = 2589, count = 20 }, [2] = { id = 2592, count = 17 } } }, { name = "Gear", items = { [1] = { id = 2825, count = 1 } } }, { name = "Locked", viewable = false, items = {} } }')
lua('WOW.log = { { { "deposit", "Fluffys", 2589, 20, 1 }, { "withdraw", "Mlad", 2592, 3, 0 } }, { { "deposit", "Vari", 2825, 1, 2 } } }; WOW.moneyLog = { { "deposit", "Fluffys", 500000, 1 } }')
lua('FireEvent("GUILDBANKFRAME_OPENED")'); run(10); lua('FireEvent("GUILDBANKFRAME_CLOSED")'); run(1)
check(G.PlaceholderSyncDB.guildBank is None, "autoscan off: no scan on open")
slash("autoscan on")

print("== bank visit with autoscan on, chat on")
slash("chat on"); printed.clear(); sent.clear()
lua('FireEvent("GUILDBANKFRAME_OPENED")'); run(10); lua('FireEvent("GUILDBANKFRAME_CLOSED")'); run(5)
gb = G.PlaceholderSyncDB.guildBank
check(gb is not None and bool(gb.complete), "scan complete")
check(gb is not None and len(list(gb.tabs.values())) == 3, "three tabs recorded, hidden one included as not viewable")
check(gb is not None and gb.log is not None and len(list(gb.log.tabs.values())) == 2 and len(list(gb.log.money.values())) == 1, "log: two tabs plus money")
check(any("bank saved" in l for l in printed), f"chat on: bank saved line shown ({printed})")
check(any(t.startswith(b"2H") for t, d in sent), "bank close announces the new scan")
slash("chat off")
out = slash(""); check(any("last scan" in l and "3 items in 3 tabs" in l for l in out), f"status reports the scan ({[l for l in out if 'scan' in l]})")
check(any("last notice" in l for l in out), "status shows the last notice")

print("== manual scan while open")
lua('FireEvent("GUILDBANKFRAME_OPENED")'); run(1); out = slash("scan"); run(10); lua('FireEvent("GUILDBANKFRAME_CLOSED")'); run(1)
check(G.PlaceholderSyncDB.guildBank.at >= gb.at, "manual scan refreshed the scan time")

print("== loot lookups against the bridge data")
ok, err = pcall('''
  local st = NS.Loot.Standing("|cffa335ee|Hitem:250224::::::::60:::::|h[Mindpiercer's Sigil]|h|r", "Mlad-Realm")
  assert(st and st.prio == 1 and st.need == 2, "Mlad is prio #1 and second in need")
  local text = NS.Loot.CellText(st) assert(text == "#1/6", "cell text " .. tostring(text))
  local st2 = NS.Loot.Standing("Spirit-Rending Poison", "Fluffys") assert(st2 and st2.has == "2026-10-30", "owned by name lookup")
  assert(NS.Loot.CellText(st2) == "has")
  local st3 = NS.Loot.Standing("|Hitem:999::|h[Nothing]|h", "Fluffys") assert(st3 and st3.unknownItem, "unknown item")
  assert(NS.Loot.Standing("Spirit-Rending Poison", "Stranger").char == nil, "unknown character")
  NS.Loot.ShowTooltip({}, "|Hitem:250224::|h[Mindpiercer's Sigil]|h", "Mlad") assert(#GameTooltip.lines > 5, "tooltip lines")
  NS.Loot.SelfTooltip({}, "Spirit-Rending Poison", "Fluffys-Realm") assert(#GameTooltip.lines > 3, "self tooltip")
  local t, r = NS.Loot.SelfText(st) assert(t == "Wishlist", "self text " .. tostring(t))
  assert(NS.Loot.HasPrio() == true)
  assert(#NS.Loot.NeederLines("250224", 5) >= 4)
''')
check(ok, "loot standing, cell text, tooltips" + ("" if ok else f": {bytes(err).decode()}"))

print("== council awards")
lua('''
RCLootCouncil = { GetHistoryDB = function() return { ["Mlad-Realm"] = {
  { lootWon = "|cffa335ee|Hitem:250224::::::::60:::::|h[Mindpiercer's Sigil]|h|r", date = "2026/11/01", time = "20:15:00", response = "BiS", responseID = 1, id = "1762024500-1", class = "HUNTER", instance = "Midnight", boss = "Charonus", votes = 3 },
  { lootWon = "|Hitem:1::|h[PL thing]|h", date = "2026/11/01", time = "20:16:00", responseID = "PL", id = "x" },
} } end }
ForeverLoot = { LootCouncil = { History = {
  { id = 77, awardedTo = "Vari", awardedToClass = "WARRIOR", itemLink = "|Hitem:274497::|h[Spirit-Rending Poison]|h", awardedAt = BASE - 3600, awardedBy = "Fluffys", responses = { Vari = { response = { label = "Main spec" }, votes = 2 } } },
  { id = 78, awardedTo = "Vari", itemLink = "|Hitem:5::|h[Test]|h", awardedAt = BASE - 3000, test = true },
} } }
''')
out = slash("awards")
check(out and out[0].startswith("PlaceholderSync: 2 new award"), f"two awards picked up, personal loot and test rows skipped ({out})")
aw = G.PlaceholderSyncDB.lootAwards
check(aw is not None and set(bytes(k).decode() for k in aw.keys()) == {"rclc:1762024500-1", "flc:77"}, "award uids")
check(aw is not None and aw[b"rclc:1762024500-1"].itemId == 250224 and bytes(aw[b"flc:77"].response) == b"Main spec", "award fields")
out = slash(""); check(any("2 council awards recorded" in l for l in out), "status counts awards")

print("== a message from a guildmate")
sent.clear()
lua('ACECOMM.handlers.PlaceholderSync("PlaceholderSync", "2H9,0", "GUILD", "Other-Realm")'); run(5)
check(any(t == b"2RL3" for t, d in sent), f"a newer loot rev announced leads to a request ({sent})")
ok, err = pcall('ACECOMM.handlers.PlaceholderSync("PlaceholderSync", "2DL9:0:not-base64!!", "GUILD", "Other-Realm")')
check(ok, "garbage data message is ignored without error")
ok, err = pcall('ACECOMM.handlers.PlaceholderSync("PlaceholderSync", "1H1,1", "GUILD", "Other-Realm")'); check(ok, "old protocol ignored")

print("== logout")
lua('FireEvent("PLAYER_LOGOUT")')
db = G.PlaceholderSyncDB
check(db.meta is not None and bytes(db.meta.addonVersion) == b"0.3.4", "meta stamped with the version")
check(db.characters is not None and len(list(db.characters.keys())) == 1, "the character is recorded")
check(bool(db.options.autoscan) is True and db.options.chat is False, f"options saved")
check(all("Error" not in l and "error" not in l.lower() or "could not" in l for l in printed), "no error lines printed")

# ---- write the SavedVariables file as the game would ---------------------------------------------
L.execute(r'''
local function esc(s) return (s:gsub('[\\"\n]', { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n" }):gsub("[\128-\255]", function(c) return string.format("\\%03d", c:byte()) end)) end
local function w(v, out, indent)
  local t = type(v)
  if t == "table" then
    out[#out + 1] = "{\n"
    local n = #v
    for i = 1, n do w(v[i], out, indent) out[#out + 1] = ", -- [" .. i .. "]\n" end
    local keys = {}
    for k in pairs(v) do if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      out[#out + 1] = type(k) == "string" and ('["' .. esc(k) .. '"] = ') or ("[" .. tostring(k) .. "] = ")
      w(v[k], out, indent) out[#out + 1] = ",\n"
    end
    out[#out + 1] = "}"
  elseif t == "string" then out[#out + 1] = '"' .. esc(v) .. '"'
  else out[#out + 1] = tostring(v) end
end
local out = { "\nPlaceholderSyncDB = " }
w(PlaceholderSyncDB, out, "")
SV_TEXT = table.concat(out) .. "\n"
''')
out_path = pathlib.Path(os.environ.get("ADDON_SV_OUT", ROOT / "dist" / "PlaceholderSync.lua"))
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_bytes(bytes(G.SV_TEXT))
print(f"\nSavedVariables written: {out_path} ({out_path.stat().st_size} bytes)")
print("\n" + ("ALL CHECKS PASSED" if not fails else f"{len(fails)} CHECK(S) FAILED"))
sys.exit(1 if fails else 0)
