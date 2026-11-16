# LMRInvestigations — file-mod → REFramework Lua conversion

Repository: https://github.com/PonyWarrior/LMRInvestigations
- `LMRInvestigations.lua` — the production script (drop into `reframework\autorun\`)
- `LMRI_LegalityTest.lua` (autorun shell) + `LMRI_Logic.lua` (`reframework\data\`, hot-reload F9) — legality test suite (§6)
- `LMRI_SpOfferProbe.lua` (`reframework\data\`) — F11 board-container probe
- `data\LMRI_Grounding_Data.lua` + `tools\extract_legality.py` — vanilla grounding extracted from the shipped file
- `tools\dev\*.py` — offline lookups in REFramework's SDK dump (`il2cpp_dump.json`; path via `LMRI_SDK_DUMP`)

## 1. What the original mod does

The mod ships a RE-Editor-patched copy of
`natives\STM\GameDesign\Environment\UserData\ExFieldPattern\ExFieldPattern_Default\ExQuestRewardSetting.user.3`.
That file is an RE Engine **USR→RSZ** container holding 522 instances of
`app.user_data.ExQuestRewardSetting` and its sub-types (the Investigation /
Field-Survey reward tables). The patch raises two categories of values:

**A. Reward slot counts** — `cExRewardSlotParam._LotNum` for specific grades
(and an equivalent high-potential block), decoded exactly from the 25 changed
bytes of the file (verified against RE-Editor's own edited file):

| grade | base block (_RewardSlotTbl) | high block (SpOfferByLowerRank) |
|---|---|---|
| 1 | 1 → 2 | 4 → 6 |
| 2 | 2 → 3 | 4 → 6 |
| 3 | 3 & 4 → 5 | 6 & 8 → 10 |
| 4 | 4 → 5 | 8 → 10 |
| 5 | 5 (unchanged) | 10 (unchanged) |

**B. Per-slot reward counts** — small +1 raises on `cExRewardDataParam._Num`
(and a few `cExEmRewardDataParam._SlotNum`) — 15 byte-level +1 edits:
`1→2 (×8), 2→3 (×2), 3→4 (×5)` roughly, spread across the reward-item tables.

## 2. Format / type resolution (for reference)

- `USR\0` header at 0x00, `RSZ\0` + v0x10 header at 0x30 (`objectCount`,
  `instanceCount=522`, 3×int64 offsets). Instance data starts at 0x10C0.
- Instance type hash/CRC halves resolved to names using the **live game TDB**
  (`sdk.find_type_definition(...):get_fqn_hash()/get_crc_hash()`):
  - `7BB48FBE` → `cExRewardSlotParam`
  - `B54ED57E` → `cExRewardSlotParamByRank`; `7BC8D16D` → its `cExRewardSlotParam_SpOffer`
  - `0F54DDDB` → `cExRewardTypeParam`; `98BED2DA` → `*ByRank`; `56D25138` → `*ByEm`
  - `540EB8E6` → `cExRewardDataParam`; `0BCCD7E9` / `44DC6CD7` → `*ByRank` / `*ByEm`
  - `9D2B8957` → `cExEmRewardDataParam`
  - `9B21A2F3` / `3E671203` / `205670D4` → SkillGem / Artian / Amulet `*ParamByEm`
  - `B10428A4` (+`9952AAA3`,`C667325B`) → `cExRecommendEmSortParamByHR` + point tables
  - `323B011F` (+`674DBDE4`,`A0290E39`) → `cSwarmSpOfferRewardByEm` + tables
  - `96060707` → the root `app.user_data.ExQuestRewardSetting`
- Managed instance class sizes include the 0x10 object header
  (e.g. `cExRewardSlotParam` size 0x15 → 5 raw bytes; `cExRewardDataParam`
  0x28 → 12 raw bytes).

## 3. Live-game findings (this REFramework build)

- `sdk.deserialize` is **broken** on this build (`[REManagedObject] Failed to find
  first step`), so runtime byte-deserialization could not be used.
- `re.on_frame` is **not dispatched** in this session; `re.on_pre_application_entry("BeginRendering")`
  fires every frame. All per-frame work must use the latter.
- The settings object is created at **boot** (its `.ctor`/`onLoad` are not
  reliably hookable from mid-session scripts). It *is* reliably reachable via its
  reward-logic instance methods (`judgeRareEmReward`, `getRewardTypeFromItemID`,
  `isLegendaryForExRewardType`, …) which fire whenever investigations are
  regenerated / the Field Survey board is used.
- Live structure confirmed: `_RewardSlotTblByRank` has 2 rows; `ByRank[0]._RewardSlotTbl`
  = 10 base slots (grades 1–5 ×2), the high-potential slots live inside
  `ByRank[]._RewardSlotTbl_SpOfferByLowerRank[j]._RewardSlotTbl_SpOffer`.

## 4. The Lua script

`LMRInvestigations.lua` (autorun):
- Installs catcher hooks immediately + via BeginRendering; applies whenever the
  game exposes the settings object (boot creation or reward-logic calls).
- **Maximum-roll normalization** (data-driven, no hard-coded tables):
  - slot arrays (`_RewardSlotTblByRank[]._RewardSlotTbl` and the inner arrays of
    `..._SpOfferByLowerRank[j]`): `_LotNum` → the **global vanilla max for that
    `_Grade`** across all slot tables (so any roll path yields the maximum).
  - `_RewardSlotTbl_Frenzy`: raised to the frenzy table's own max, **capped at
    the vanilla-legal limit 3** (values above 3 are impossible in vanilla).
  - reward-data arrays (`_SkillGemRewardTbl`, `_ArtianRewardTbl`,
    `_AmuletRewardTbl` and their ByEm/SpOffer variants): `_Num` → the **vanilla
    max per (row `_Rank`, item) within that same array** (per-array, so no value
    leaks between tables — e.g. a monster-specific ByEm table's 2 never raises a
    generic table's 1).
  - EM-reward arrays (`_EmRewardTblByRank`, `_EmRewardTblByEm`, + Yummy):
    `_SlotNum` → the global max per rank.
  - Only ever raises values.
  - Fixed 2026-11-16: item counts formerly used a *cross-rank* global max (★4
    Glowing Orb x2 > vanilla 1; ★6 Ancient Orb x4 > vanilla 2). Now per rank;
    verified in-game: 23 regenerated investigations, 0 LIVE ILLEGAL.
  - Saved investigations are not modified (the old saved-quest pass never ran and
    was removed). Investigations saved before the fix keep their illegal counts.
- Config via `reframework\data\LMRInvestigations.json` (no in-game menu; unknown
  keys are dropped on load). `snapshot_vanilla` must be `true` while the test
  suite runs. `LMRInvestigations.log` is truncated at each game start; F8 re-applies
  (edge-triggered — note the shell does not use F8).
- Each hook call is `pcall`-guarded so a patch error can't break the game method.

## 5. Verification

1. Boot with `LMRInvestigations.lua` in autorun (no loose file).
2. Regenerate/browse investigations → hooks fire → log shows
   `[LMRInvestigations] patched settings ... updated N fields`.
3. Expected: every slot table at its grade's vanilla max (Frenzy capped at 3),
   every item count at its vanilla max for its rank.
4. Legality: `LMRI_LegalityTest.lua` (§6) verifies settings + generated quests.

## 6. Test suite (vanilla-legality verification)

`LMRI_LegalityTest.lua` (autorun shell; owns all hooks, registered once at boot —
shell changes need a game restart) loads `LMRI_Logic.lua` (pure logic; F9 reloads
it and clears the log). Output: `reframework\data\LMRI_Legality.log`, one table per
investigation (item / count / cap / verdict) plus a slot-count line.

- **Source of truth:** caps and slot limits come from the mod's pre-patch vanilla
  snapshot of the live tables (`_G.LMRI_VANILLA_CAPS`, `_G.LMRI_VANILLA_SLOTS`;
  `snapshot_vanilla` debug toggle), so game updates are picked up automatically.
  `LMRI_Grounding_Data.lua` only *confirms* the reader (F6 / on anchor: the
  `GROUND`, `GROUND SLOTS`, `GROUND EM-ITEM` lines must show 0 mismatches).
- **Capture (`field_scan`, every 5 s, every region from `getExStageArray`):**
  - regular: `EnvironmentManager.findExecutedPopEmsInMyExField(stage, false)` →
    pop-enemies with `EnableKeepQuestTarget` and `KeepQuestIndex == 255` (unsaved)
    → `getRewardData_EnemyInfo(false)`. `getItemID` returns *runtime* item ids,
    mapped back to fixed ids before cap lookup.
  - Sp: `getSpOfferInfoList(stage)` (unkept offers) → `get_RewardArray`
    (`ItemIdFixed` / `Num`); targets via `get_TargetEmArray` → `get_EmID`.
  - Labels: monster name (`EnemyDef.NameString`), Tempered / Arch-tempered /
    Frenzied, ★rank and grade. Summary line `FIELD ... TOTAL x regular + y Sp`
    (expect 15-30).
  - The `judgeRareEmReward*` hooks also capture rolls at generation time; those
    carry no rank, so they are held 15 s and dropped when the ranked field-scan
    copy arrives (logged unranked only if it never does).
- **No snapshot, no verdicts:** without `_G.LMRI_VANILLA_CAPS` the suite logs
  `CAPS REFUSED` instead of reading the (modded) live tables. If the snapshot
  differs from the grounding file it logs `!!!! GROUND WARNING` (snapshot taken
  after patching → restart the game).
- **Checks per investigation:** item count ≤ vanilla cap *for its rank*
  (★N = `REWARD_RANK_0N`) from the generic tables, plus a monster's own ByEm table
  only when that monster is in the investigation (`_G.LMRI_VANILLA_CAPS_BYEM`,
  matched via `EnemyDef.getFixedFromID`). Cap marks: `*` item absent from that
  rank (cross-rank max used); `^` monster part — cap = max count for that item in
  the investigation monster's own drop table (`EnemyRewardDataSetting
  .getEnemyRewardData(em)` rows `_IdEx[]`/`_RewardNumEx[]`, max over all reward
  types; e.g. gems 1, Nerscylla Spike+ 3); `~` monster part with no known monster
  (F5 saved tables only: largest EM-material cap, an assumption). Slot count ≤ vanilla max for rank+grade (Sp:
  rank + lower-rank table; frenzied regular: frenzy table, ≤ 3). Violations log
  `LIVE ILLEGAL`; rows/slots under the vanilla max log `BELOW MAX` (warning only —
  the mod should always roll the max).
- **Saved investigations:** baselined on load and excluded from verdicts (may be
  user-modified); listed only on F5.
- **Keys:** F9 reload engine · F2/F3 report captured rolls · F4 re-baseline ·
  F5 settings + saved dump · F6 grounding · F11 board probe.
- Saved-quest check runs every 2 s; the baseline resets when you return to title,
  so loading another save baselines that save.
- Known limitations:
  - saved-quest (F5) tables use cross-rank caps (`cap_for(nil, …)`; display only);
  - Sp offers: rank = highest target ★ and grade = highest target grade (offer
    rank getters don't read) — lenient;
  - dedupe signature is method + monsters + rows: two identical rolls for the
    same monster(s) show once.