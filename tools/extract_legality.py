#!/usr/bin/env python3
r"""
Build LMRI_Grounding_Data.lua - a SNAPSHOT of vanilla ExQuestRewardSetting.user.3,
used ONLY to confirm the live in-game reader produces the same per-(table,rank,item)
caps. Never used as the source of legality checks.

The live Lua reader reads the same fields and this file lets it diff itself
against the file, so a game update that changes the tables is caught as a
"reader matches live" re-confirmation rather than silent drift.

Usage:  python extract_legality.py [vanilla.json] [out.lua]
"""
import json, os, collections, re, sys

BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
DEF_IN  = os.path.join(BASE, "ExQuestRewardSetting.vanilla.json")
DEF_OUT = os.path.join(BASE, "LMRI_Grounding_Data.lua")

INFILE  = sys.argv[1] if len(sys.argv) > 1 else DEF_IN
OUTFILE = sys.argv[2] if len(sys.argv) > 2 else DEF_OUT

v = json.load(open(INFILE, encoding="utf-8"))

# ----------------------------------------------------------------------------
# helpers tolerant of both row shapes in the export
# ----------------------------------------------------------------------------
def rank_of(d):
    """Return the rank as a canonical string. Handles:
       'Rank_Unwrapped': 'REWARD_RANK_04'  (reward tables)
       'Rank': 'REWARD_RANK_01'            (slot tables / slot wrappers)
       'Rank': [{'Value': hash}]           (enum as list) - mapped via rank map
    """
    if not isinstance(d, dict): return None
    if isinstance(d.get("Rank_Unwrapped"), str) and d["Rank_Unwrapped"]:
        return d["Rank_Unwrapped"]
    r = d.get("Rank")
    if isinstance(r, str): return r
    return None  # hash-form handled by caller via RANK hash map

def rank_hash_of(d):
    if isinstance(d, dict) and isinstance(d.get("Rank"), list) and d["Rank"]:
        return d["Rank"][0].get("Value")
    return None

def item_of(d):
    if not isinstance(d, dict): return None
    ri = d.get("RewardItem")
    if isinstance(ri, list) and ri and ri[0].get("Value") is not None:
        return ri[0]["Value"]
    return None

def num_of(d):
    try: return int(d.get("Num", 0))
    except Exception: return 0

def collect_names():
    names = {}
    def walk(o):
        if isinstance(o, dict):
            for k, x in o.items():
                if k == "RewardItem" and isinstance(x, list) and x:
                    e = x[0]
                    if e.get("Value") is not None and e.get("Value_button"):
                        names[e["Value"]] = e["Value_button"].split(":", 1)[-1].strip()
                walk(x)
        elif isinstance(o, list):
            for x in o: walk(x)
    walk(v)
    return names

def collect_rankmap():
    # enum hash (from Rank:[{Value}]) -> canonical REWARD_RANK_xx name
    rm = {}
    def walk(o):
        if isinstance(o, dict):
            if isinstance(o.get("Rank"), list) and o["Rank"] and isinstance(o.get("Rank_Unwrapped"), str):
                rm.setdefault(o["Rank"][0]["Value"], o["Rank_Unwrapped"])
            for x in o.values(): walk(x)
        elif isinstance(o, list):
            for x in o: walk(x)
    walk(v)
    return rm

# ----------------------------------------------------------------------------
# per-field caps: {source_key: {rank: {item: max_num}}}
# source_key is the LIVE navigation path, so the live reader can diff 1:1:
#   direct tables        -> "SkillGemRewardTbl", "ArtianRewardTbl", "AmuletRewardTbl"
#   ByEm wrappers        -> "SkillGemRewardTblByEm.SkillGemRewardTbl",
#                           "SkillGemRewardTblByEm.SkillGemRewardTbl_SpOffer", ...
#   EM wrappers          -> "EmRewardTblByRank.EmRewardTbl",
#                           "EmRewardTblByRank.EmRewardTbl_Yummy", ...
# ----------------------------------------------------------------------------
def collect_field_caps():
    caps = collections.defaultdict(lambda: collections.defaultdict(dict))
    def add_rows(src, d):
        if not isinstance(d, dict): return
        rk = rank_of(d)
        if rk is None: return
        it = item_of(d)
        if it is None: return
        caps[src][rk][it] = max(caps[src][rk].get(it, 0), num_of(d))

    # direct tables
    for t in ("SkillGemRewardTbl", "ArtianRewardTbl", "AmuletRewardTbl"):
        for d in (v.get(t) or []):
            add_rows(t, d)

    # wrapper tables: prefix the subfield with the wrapper name
    wrappers = {
        "SkillGemRewardTblByEm": ("SkillGemRewardTbl", "SkillGemRewardTbl_SpOffer"),
        "ArtianRewardTblByEm":   ("ArtianRewardTbl",   "ArtianRewardTbl_SpOffer"),
        "AmuletRewardTblByEm":   ("AmuletRewardTbl",   "AmuletRewardTbl_SpOffer"),
        "EmRewardTblByRank":     ("EmRewardTbl",       "EmRewardTbl_Yummy"),
        "EmRewardTblByEm":       ("EmRewardTbl",       "EmRewardTbl_Yummy"),
    }
    for wrapper, (f1, f2) in wrappers.items():
        for row in (v.get(wrapper) or []):
            for f in (f1, f2):
                for d in (row.get(f) or []):
                    add_rows(f"{wrapper}.{f}", d)

    return caps

def collect_slot_caps():
    """slot_caps[rank][grade] = max LotNum over RewardSlotTblByRank rows
    (both the plain RewardSlotTbl and all RewardSlotTbl_SpOfferByLowerRank)."""
    sc = collections.defaultdict(lambda: collections.defaultdict(int))
    for row in (v.get("RewardSlotTblByRank") or []):
        rk = rank_of(row)
        if rk is None: continue
        for s in (row.get("RewardSlotTbl") or []):
            g = int(s.get("Grade", 0)); lot = int(s.get("LotNum", 0))
            sc[rk][g] = max(sc[rk][g], lot)
        for w in (row.get("RewardSlotTbl_SpOfferByLowerRank") or []):
            for s in (w.get("RewardSlotTbl_SpOffer") or []):
                g = int(s.get("Grade", 0)); lot = int(s.get("LotNum", 0))
                sc[rk][g] = max(sc[rk][g], lot)
    return sc

def collect_frenzy():
    mx = 0
    for s in (v.get("RewardSlotTbl_Frenzy") or []):
        mx = max(mx, int(s.get("LotNum", 0)))
    return mx

names     = collect_names()
rankmap   = collect_rankmap()
caps      = collect_field_caps()
slot_caps = collect_slot_caps()
frenzy    = collect_frenzy()

# sanity report (user's claims) - caps lookups by field
print("--- grounding sanity (user's claims) ---")
def mc(field, rk, it): return caps[field].get(rk, {}).get(it)
checks = [
    ("SkillGemRewardTbl", "REWARD_RANK_06", 621, 2, "ITEM_0647 RANK_06 max 2"),
    ("SkillGemRewardTbl", "REWARD_RANK_07", 621, 3, "ITEM_0647 RANK_07 max 3"),
    ("SkillGemRewardTbl", "REWARD_RANK_08", 621, 4, "ITEM_0647 RANK_08 max 4"),
    ("SkillGemRewardTbl", "REWARD_RANK_04", 157, 1, "ITEM_0183 RANK_04 max 1"),
    ("SkillGemRewardTbl", "REWARD_RANK_05", 157, 2, "ITEM_0183 RANK_05 max 2"),
    ("ArtianRewardTbl", "REWARD_RANK_08", 479, 2, "artian frag x2 @ R8"),
    ("AmuletRewardTbl", "REWARD_RANK_09", 822, 1, "Glowing Stone x1 @ R9"),
]
for field, rk, it, exp, note in checks:
    got = mc(field, rk, it)
    mark = "OK" if got == exp else "<-- MISMATCH"
    if got != exp: print(f"  {note}: field={field} rank={rk} item={it} cap={got} expected={exp} {mark}")
    else: print(f"  {note}: cap={got} OK")

tot = sum(len(caps[f][r]) for f in caps for r in caps[f])
print(f"--- totals: {tot} item-cap entries across fields {sorted(caps.keys())}")
print(f"--- item names: {len(names)}, rank hash->name: {len(rankmap)}")
print(f"--- slot caps: {sum(len(m) for m in slot_caps.values())} (rank,grade) entries; frenzy max={frenzy}")

# ----------------------------------------------------------------------------
# emit Lua
# ----------------------------------------------------------------------------
def lua_key(k):
    if isinstance(k, int): return str(k)
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k): return k
    # dotted source keys (e.g. "ByEm.Tbl") must use the [\"...\"] key form
    return "[" + json.dumps(k) + "]"

L = []
L.append("-- =============================================================================")
L.append("-- LMRI_Grounding_Data.lua - SNAPSHOT of vanilla ExQuestRewardSetting.user.3")
L.append("-- Ground-truth oracle to CONFIRM the live in-game reader produces the same")
L.append("-- per-(field,rank,item) caps. The live tables are the SOURCE of legality")
L.append("-- checks; this file only cross-checks the reader after loading the game.")
L.append("-- Regenerate: python extract_legality.py <vanilla.json> <out.lua>")
L.append("-- =============================================================================")
L.append("")
L.append("local G = {}")

L.append("")
L.append("-- rank enum hash -> 'REWARD_RANK_xx' (names are stable across updates)")
L.append("G.RANK_NAMES = {")
for rv in sorted(rankmap): L.append(f"    [{rv}] = {json.dumps(rankmap[rv])},")
L.append("}")

L.append("")
L.append("-- item id -> display name (id space = RewardItem enum _Value)")
L.append("G.ITEM_NAMES = {")
for it in sorted(names): L.append(f"    [{it}] = {json.dumps(names[it])},")
L.append("}")

L.append("")
L.append("-- caps[field][rank][item] = max Num; field names match live fields (_X)")
L.append("G.ITEM_CAPS = {")
for f in sorted(caps.keys()):
    L.append(f"    {lua_key(f)} = {{")
    for rk in sorted(caps[f].keys()):
        L.append(f"        {lua_key(rk)} = {{")
        for it in sorted(caps[f][rk].keys()):
            L.append(f"            [{it}] = {caps[f][rk][it]},")
        L.append("        },")
    L.append("    },")
L.append("}")

L.append("")
L.append("-- slot caps: SLOT_CAPS[rank][grade] = max LotNum (normal + SpOffer)")
L.append("G.SLOT_CAPS = {")
for rk in sorted(slot_caps.keys()):
    L.append(f"    {lua_key(rk)} = {{")
    for g in sorted(slot_caps[rk].keys()):
        L.append(f"        [{g}] = {slot_caps[rk][g]},")
    L.append("    },")
L.append("}")

L.append("")
L.append(f"G.FRENZY_CAP = {frenzy}")
L.append("")
L.append("return G")

with open(OUTFILE, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(L) + "\n")
print(f"Wrote {OUTFILE} ({os.path.getsize(OUTFILE)} bytes)")