# LMRInvestigations

A [REFramework](https://github.com/praydog/REFramework) Lua mod for **Monster Hunter Wilds**:
every newly generated investigation (field survey quest) rolls the **best result vanilla can produce**.
That means the most reward slots, the largest item counts and the most monster-part/EM slots,
without ever going past what the unmodded game can legitimately generate.

Nexus Mods page: https://www.nexusmods.com/monsterhunterwilds/mods/661

Version 2 replaces the old file-replacement version (a patched `ExQuestRewardSetting.user.3`).
Nothing on disk is replaced any more. The script patches the reward tables in memory at runtime.

## What it changes

| Table | Rule |
|---|---|
| Reward slot counts (`_RewardSlotTblByRank`, incl. Sp offers) | raised to the vanilla max for that grade |
| Frenzied reward slots (`_RewardSlotTbl_Frenzy`) | raised to that table's own max, never above 3 |
| Item counts (`_SkillGem` / `_Artian` / `_Amulet` tables + per-monster variants) | raised to the vanilla max for that table, rank and item; values are never borrowed from another table or rank |
| Monster EM reward slots | raised to the vanilla max per rank |

Values are only ever raised, never lowered. Saved investigations are not touched. Only investigations
generated after the mod loads are affected.

## Requirements

- Monster Hunter Wilds (PC)
- [REFramework](https://github.com/praydog/REFramework-nightly/releases) (nightly builds supported)

## Install

1. Install REFramework.
2. Copy `reframework/autorun/LMRInvestigations.lua` into `<game folder>/reframework/autorun/`.
3. **Remove the old version first** if you used it: delete the patched
   `natives/STM/GameDesign/Environment/UserData/ExFieldPattern/ExFieldPattern_Default/ExQuestRewardSetting.user.3`.

Uninstall: delete `LMRInvestigations.lua`, plus `LMRInvestigations.json` and `LMRInvestigations.log` in `reframework/data/`.

### Settings

`reframework/data/LMRInvestigations.json` is created the first time the mod runs:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | master switch |
| `patch_slots` | `true` | raise slot counts |
| `patch_counts` | `true` | raise item counts |
| `log_details` | `false` | log every changed field to `reframework/data/LMRInvestigations.log` |
| `snapshot_vanilla` | `false` | capture the unpatched tables for the legality suite (must be `true` while you run it) |

F8 re-applies the patch by hand. You should never need to.

## Legality test suite (optional)

A separate, optional download that checks the mod's results against the game. It reads every
investigation currently on the boards (regular and Sp, every region) and checks each one against the
**unmodified game's own tables**. Those tables are captured live before the mod patches anything, so
game updates are picked up automatically.

Checks per investigation:
- each item count ≤ the vanilla cap for that rank; for monster parts, the monster's own drop table
- the number of reward slots ≤ the vanilla max for that rank and grade (frenzied: ≤ 3)
- whether the counts are already at the vanilla maximum (shows the mod is doing its job)

Install: copy `reframework/autorun/LMRI_LegalityTest.lua` and the `reframework/data/` files (`LMRI_Logic.lua`, `LMRI_Grounding_Data.lua`, `LMRI_SpOfferProbe.lua`)
into your game folder, then set `"snapshot_vanilla": true` in `LMRInvestigations.json` and restart the game.
The suite refuses to judge anything without the vanilla snapshot.

Output goes to `reframework/data/LMRI_Legality.log`. The file is cleared on each run and holds one table per investigation.

| Key | Action |
|---|---|
| F9 | reload the logic module (clears the log) |
| F2 / F3 | report captured rolls |
| F4 | re-baseline saved investigations |
| F5 | settings check + table of every saved investigation |
| F6 | grounding: live reader vs bundled vanilla snapshot |
| F11 | dump the live investigation boards (developer probe) |

Full design notes: [CONVERSION.md](CONVERSION.md).

## Repository layout

| Path | Content |
|---|---|
| `LMRInvestigations.lua` | the mod |
| `LMRI_LegalityTest.lua`, `LMRI_Logic.lua`, `LMRI_SpOfferProbe.lua` | legality suite |
| `data/LMRI_Grounding_Data.lua` | vanilla grounding values, cross-checked against the live reader (F6) |
| `tools/extract_legality.py` | rebuilds the grounding file from an RE-Editor JSON export of the vanilla `ExQuestRewardSetting.user.3` (not included: game data) |
| `tools/dev/*.py` | offline searches in REFramework's SDK dump (`il2cpp_dump.json`); set `LMRI_SDK_DUMP` to its path |
| `tools/package.ps1` | builds the two Nexus zips into `dist/` |
| `NOTES.md` | REFramework / RE Engine developer notes |

## Credits

- [REFramework](https://github.com/praydog/REFramework) by praydog and contributors
- [RE-Editor](https://github.com/Synthlight/RE-Editor) by Synthlight, used for the original file mod and the vanilla data export

AI disclosure: the conversion to Lua, the legality suite and these docs were written with AI assistance
(Claude Code, Claude Opus). Every behaviour was tested in game.

## License

[MIT](LICENSE)
