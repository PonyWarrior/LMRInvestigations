# Changelog

## 2.0.0 - 2026-11-16

- Rewritten as a REFramework Lua script; no game file is replaced any more (remove the old patched `ExQuestRewardSetting.user.3`).
- Item counts are now raised to the vanilla maximum for that table, rank and item. The old file raised every item to its highest count across all ranks, which produced counts vanilla can't roll (e.g. ★4 Glowing Orb x2, ★6 Ancient Orb x4).
- Frenzied reward slots capped at the vanilla maximum of 3.
- New optional legality test suite that checks every generated investigation against the unmodified game tables.
