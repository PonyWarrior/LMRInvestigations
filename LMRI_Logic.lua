-- =============================================================================
-- LMRI_Logic.lua - validation engine for LMRI_LegalityTest
-- =============================================================================
-- Loaded by the autorun shell (LMRI_LegalityTest.lua). Exports handlers:
--   on_frame()   - saved-quest baseline + field_scan of every generated
--                  investigation (regular pop-enemies + Sp offers, all regions)
--   on_save/on_convert - live QuestUtil save/convert legality alerts
--   on_reward / on_reward_post - caps anchoring + judge-hook roll capture
--   report()     - F2/F3: replay captured generated investigations
--   baseline()   - F4: re-baseline saved investigations
--   settings()   - F5: settings sanity
--   verified_all() - F5: sweep saved investigations
--   grounding()  - F6: live reader + slot snapshot vs extracted vanilla data
--   instant()    - F11: board-container probe (LMRI_SpOfferProbe.lua)
-- =============================================================================

local sdk, log = sdk, log
local M = {}

local function l(msg)
    local txt = tostring(msg)
    log.info("LEGALITY: " .. txt)
    local ok, f = pcall(io.open, "LMRI_Legality.log", "a")
    if ok and f then
        f:write("[" .. (os.date and os.date("%Y-%m-%d %H:%M:%S") or "?") .. "] " .. txt .. "\n")
        f:close()
    end
end

-- ---------- helpers ----------------------------------------------------------

local function get_f(o, n)
    if o == nil then return nil end
    local ok, v = pcall(function() return o:get_field(n) end)
    return ok and v or nil
end

local function each_elem(arr, fn)
    if arr == nil then return end
    -- get_elements() can return an empty-but-truthy wrapper; only trust it when
    -- it actually has content, otherwise fall back to size/get_element (same
    -- guard the roll-payload reader uses, so caps are never under-read).
    local okE, els = pcall(function() return arr:get_elements() end)
    if okE and type(els) == "table" and #els > 0 then
        for i, e in ipairs(els) do fn(e, i - 1) end
        return
    end
    local okS, sz = pcall(function() return arr:get_size() end)
    if not okS then return end
    for i = 0, sz - 1 do
        local ok, e = pcall(function() return arr:get_element(i) end)
        if ok then fn(e, i) end
    end
end

local function countt(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

local function join(t)
    if type(t) ~= "table" then return tostring(t) end
    return table.concat(t, "; ")
end

local function quest_label(k)
    local lv = nil
    if k ~= nil then
        local okL, v = pcall(function() return k:call("getQuestLv()") end)
        if okL then lv = tonumber(v)
            if lv == nil then
                -- some bindings return a wrapped object; try the IE rank helper
                local ie2 = _G.InvestigationEditor
                if ie2 and ie2.investigations and ie2.investigations.get_quest_rank_from_data then
                    local okR, r = pcall(function() return ie2.investigations.get_quest_rank_from_data(k) end)
                    if okR then lv = tonumber(r) end
                end
            end
        end
    end
    local ie = _G.InvestigationEditor
    local name = nil
    if ie and ie.investigations and ie.investigations.extract_quest_info then
        local ok, n = pcall(function() return ie.investigations.extract_quest_info(k) end)
        if ok and n then name = tostring(n) end
    end
    local base = name or "Investigation"
    return base .. (lv and (" (lv=" .. tostring(lv) .. ")") or "")
end

-- ---------- item id map + names ----------------------------------------------

local fixed_to_item = {}
local item_to_fixed = {}   -- inverse: runtime ItemDef.ID -> fixed id
local item_name_cache = {}
local fixed_ready = false

local function resolve_name(guid)
    if guid == nil then return nil end
    local okN, name = pcall(function()
        return sdk.get_message_ex:call(nil, guid, sdk.get_language())
    end)
    if okN and name and tostring(name) ~= "" then return tostring(name) end
    return nil
end

local function build_fixed_map()
    if fixed_ready then return true end
    local vdm = sdk.get_managed_singleton("app.VariousDataManager")
    if not vdm then return false end
    local okS, setting = pcall(function() return vdm:get_Setting() end)
    if not okS or not setting then return false end
    local okI, items = pcall(function() return setting:get_Item():get_ItemData() end)
    if not okI or not items then return false end
    local okC, count = pcall(function() return items:getDataNum() end)
    if not okC or not count then return false end
    local get_id = sdk.find_type_definition("app.ItemDef"):get_method("getIDFromFixed")
    if get_id == nil then return false end
    local VTI = sdk.find_type_definition("System.Int32")
    for i = 0, count - 1 do
        local okD, itemdata = pcall(function() return items:getDataByIndex(i) end)
        if okD and itemdata then
            local okF, fixed = pcall(function() return itemdata:get_ItemId() end)
            if okF and fixed and fixed > 0 then
                local wrapper = ValueType.new(VTI)
                if pcall(function() return get_id:call(nil, fixed, wrapper) end) then
                    local okM, id = pcall(function() return wrapper.m_value end)
                    if okM and id and id > 0 then
                        fixed_to_item[fixed] = id
                        item_to_fixed[id] = fixed
                        if not item_name_cache[id] then
                            local okG, guid = pcall(function() return itemdata:call("get_RawName") end)
                            if okG and guid ~= nil then
                                local nm = resolve_name(guid)
                                if nm then item_name_cache[id] = nm end
                            end
                        end
                    end
                end
            end
        end
    end
    fixed_ready = true
    return true
end

-- forward declarations: grounding helpers assigned below (after item caps);
-- item_name_of must reference them as upvalues, so declare before use
local load_ground
local ground_item_name
local rank_name_of
local em_drop_caps   -- monster drop table caps (assigned after list_of)

local function item_name_of(item)
    if item == nil then return nil end
    -- Display names must resolve in the RUNTIME id space (get_ItemId), the same
    -- space the game UI and Investigation Editor cache names under. The vanilla
    -- snapshot ITEM_NAMES is keyed by the FIXED space and would mislabel (e.g.
    -- runtime 157 = Ancient Orb while fixed 157 = Glowing Orb), so keep the
    -- runtime-name cache / IE lookup first.
    if item_name_cache[item] ~= nil then return item_name_cache[item] end
    local ie = _G.InvestigationEditor
    if ie and ie.items and ie.items.get_item_name then
        local okN, nm = pcall(function() return ie.items.get_item_name(item) end)
        if okN and nm and tostring(nm) ~= "" then
            item_name_cache[item] = tostring(nm)
            return item_name_cache[item]
        end
    end
    local gn = ground_item_name(item)
    if gn ~= nil then
        item_name_cache[item] = gn
        return gn
    end
    item_name_cache[item] = false
    return nil
end

local HARD_CAP_1 = { [820] = true }   -- glowing stone / legendary material cap 1
local item_cap = {}                   -- item id -> max _Num in vanilla tables (per-item aggregate)
local cap_by_src = {}                 -- [src_key][rank][item] -> max _Num (per-source, per-rank)
local snapshot_warned = false         -- "no vanilla snapshot" refusal logged once
local item_cap_src = {}               -- item id -> "SrcName=value, ..." (provenance)
local anchored = nil                  -- ExQuestRewardSetting instance
local caps_ready = false              -- item_cap populated & anchored
local ground_diff_done = false        -- snapshot confirmation ran once after caps load

-- ---------------------------------------------------------------------------
-- Grounding snapshot (confirmation oracle only - NEVER the source of checks).
-- Loaded from reframework/data/LMRI_Grounding_Data.lua, generated from the
-- vanilla ExQuestRewardSetting.user.3 via the RE-Editor JSON export. It lets
-- the live reader diff itself against the file so that after a game update the
-- reader is re-confirmed to match. Regenerate: python tools/extract_legality.py
-- ---------------------------------------------------------------------------
local GROUND = nil

load_ground = function()
    if GROUND then return GROUND end
    local okG, f = pcall(io.open, "LMRI_Grounding_Data.lua", "r")
    if not okG or not f then return nil end
    local text = f:read("*a")
    f:close()
    if not text then return nil end
    local chunk, cerr = load(text, "LMRI_Grounding_Data.lua")
    if not chunk then
        l("GROUND: snapshot load error: " .. tostring(cerr))
        return nil
    end
    local okC, G = pcall(chunk)
    if okC and type(G) == "table" then GROUND = G end
    return GROUND
end

-- authoritative item display name from the snapshot (when present)
ground_item_name = function(item)
    local G = load_ground()
    if G and G.ITEM_NAMES and G.ITEM_NAMES[item] then return G.ITEM_NAMES[item] end
    return nil
end

-- rank hash -> canonical REWARD_RANK_xx name (from snapshot; stable across updates)
rank_name_of = function(hash)
    local G = load_ground()
    if G and G.RANK_NAMES and G.RANK_NAMES[hash] then return G.RANK_NAMES[hash] end
    return hash ~= nil and ("rank_" .. tostring(hash)) or nil
end

-- runtime EnemyDef.ID -> fixed id (ByEm rows key monsters by _EmID, fixed space)
local em_fixed_cache = {}
local function em_fixed_of(id)
    if id == nil then return nil end
    if em_fixed_cache[id] ~= nil then return em_fixed_cache[id] or nil end
    local fixed = false
    pcall(function()
        local m = sdk.find_type_definition("app.EnemyDef"):get_method("getFixedFromID")
        local w = ValueType.new(sdk.find_type_definition("System.Int32"))
        if m:call(nil, id, w) then fixed = w.m_value end
    end)
    em_fixed_cache[id] = fixed
    return fixed or nil
end

-- per-monster tables (_G.LMRI_VANILLA_CAPS_BYEM[emFixed][rankHash][item]) apply
-- only to that monster; generic tables apply to all. em_ids = roll's monsters.
local function byem_cap(rank, item, em_ids)
    local by = _G.LMRI_VANILLA_CAPS_BYEM
    if type(by) ~= "table" or not em_ids then return nil end
    local cap
    for _, id in ipairs(em_ids) do
        -- fixed ids are 32-bit hashes: the snapshot may hold them signed or
        -- unsigned depending on how the field was read, so try both forms
        local f = em_fixed_of(id)
        local t = f and (by[f] or by[(f < 0) and (f + 0x100000000) or (f - 0x100000000)])
        for rh, items in pairs(t or {}) do
            if rank_name_of(rh) == rank and items[item] and (cap == nil or items[item] > cap) then
                cap = items[item]
            end
        end
    end
    return cap
end

local function legality_of_item(rank, item, em_ids)
    if not caps_ready then return nil end   -- can't judge yet
    local cap = nil
    if rank ~= nil then
        -- per-rank: max over the generic sources at this rank (ByEm sources are
        -- monster-specific: pooled copies kept only for grounding)
        for src, tbl in pairs(cap_by_src) do
            local rk = not src:find("ByEm", 1, true) and tbl[rank]
            if rk and rk[item] and (cap == nil or rk[item] > cap) then cap = rk[item] end
        end
        local bc = byem_cap(rank, item, em_ids)
        if bc and (cap == nil or bc > cap) then cap = bc end
    end
    -- 2nd return: true = cap came from this rank's tables (exact); false =
    -- cross-rank fallback (no rank known, or item absent at this rank)
    local exact = cap ~= nil
    if cap == nil then cap = item_cap[item] end   -- fallback: per-item aggregate
    if cap == nil then return nil end
    if HARD_CAP_1[item] then cap = math.min(cap, 1) end
    return cap, exact
end

-- board star rank (cExFieldEvent_PopEnemy.get_Rank, user-confirmed = the ★ on
-- the board) -> the vanilla tables' rank key
local function reward_rank_of(star)
    return star and string.format("REWARD_RANK_%02d", star) or nil
end

-- enum userdata like ItemDef -> number (same normalization as LMRInvestigations)
local function normalize_key(v)
    if v == nil then return nil end
    local t = type(v)
    if t == "number" then return v end
    if t == "userdata" then
        local ok, val = pcall(function() return v:get_field("_Value") end)
        if ok and val ~= nil then return tonumber(val) end
    end
    return nil
end

-- Item id extraction: keep-list entries (app.savedata.cItemWork) expose TWO
-- id spaces, and they must be used for DIFFERENT purposes:
--   * ItemIdFixed  = the table/fixed space used by the vanilla ExQuestReward
--                    tables (RewardItem.Value: 470=Basic, 471=Valuable, 158=
--                    Ancient Orb...). Legality CAPS are keyed on this space.
--   * get_ItemId() = a runtime id space (getIDFromFixed), which the game UI /
--                    the Investigation Editor cache item NAMES under (and which
--                    is often fixed_MINUS_1: F10 showed get_ItemId=470 while
--                    ItemIdFixed=471). NAMES must be resolved through this space.
-- Returns: fixed_id, runtime_id (either may be nil).
local function keep_ids_of(e)
    if e == nil then return nil, nil end
    local fixed, runtime = nil, nil
    local okF, f = pcall(function() return e:get_field("ItemIdFixed") end)
    if okF and f ~= nil then
        local n = tonumber(f)
        if n ~= nil then fixed = n end
    end
    if fixed == nil then
        local okF2, f2 = pcall(function() return e:get_field("_ItemIdFixed") end)
        if okF2 and f2 ~= nil then
            local n = tonumber(f2)
            if n ~= nil then fixed = n end
        end
    end
    local okI, id = pcall(function() return e:call("get_ItemId") end)
    if okI and id ~= nil then
        local n = tonumber(id)
        if n ~= nil then runtime = n end
    end
    return fixed, runtime
end

-- fixed-space id for cap lookups (fall back to runtime when fixed is absent)
local function fixed_id_of(e)
    local fixed, runtime = keep_ids_of(e)
    return fixed or runtime
end

-- human-readable cap provenance for an item: "Amulet=2, Artian=4, ..."
local function cap_provenance(item)
    local src = item_cap_src[item]
    if not src or #src == 0 then return nil end
    table.sort(src)
    return table.concat(src, ", ")
end

-- Ingest the mod's pre-patch vanilla snapshot (_G.LMRI_VANILLA_CAPS, written by
-- LMRInvestigations.lua with config.snapshot_vanilla=true). Shape:
--   [src][rank_hash][item] = max _Num
-- This is the ONLY trustworthy caps source: live tables are mutated by the mod,
-- so reading them would validate against modded values. Returns entry count.
local function ingest_vanilla_snapshot()
    local snap = _G.LMRI_VANILLA_CAPS
    if snap == nil or type(snap) ~= "table" then return 0 end
    local n = 0
    for src, rk_tbl in pairs(snap) do
        for rhk, it_tbl in pairs(rk_tbl) do
            local rk = rank_name_of(rhk)
            if rk then
                for it, num in pairs(it_tbl) do
                    -- per-(source,rank,item)
                    if not cap_by_src[src] then cap_by_src[src] = {} end
                    if not cap_by_src[src][rk] then cap_by_src[src][rk] = {} end
                    local cur = cap_by_src[src][rk][it] or 0
                    if num > cur then cap_by_src[src][rk][it] = num end
                    -- per-item aggregate
                    if (item_cap[it] or 0) < num then item_cap[it] = num end
                    -- provenance
                    if not item_cap_src[it] then item_cap_src[it] = {} end
                    local entry = src .. "=" .. tostring(num)
                    local dup = false
                    for _, x in ipairs(item_cap_src[it]) do
                        if x == entry then dup = true break end
                    end
                    if not dup then item_cap_src[it][#item_cap_src[it] + 1] = entry end
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- ---------- vanilla slot tables (_G.LMRI_VANILLA_SLOTS, mod's pre-patch snapshot) ----------
-- Never read from the live tables: the mod raises _LotNum/_SlotNum in place.
-- Rank keys are converted hash -> "REWARD_RANK_xx".
local slot_tbl = nil
local function rank_num(rk) return tonumber(string.match(rk or "", "(%d+)$")) end
local function by_rank_name(t)
    local o = {}
    for h, v in pairs(t or {}) do
        local rk = rank_name_of(h)
        if rk then o[rk] = v end
    end
    return o
end
local function load_slots()
    if slot_tbl then return slot_tbl end
    local s = _G.LMRI_VANILLA_SLOTS
    if type(s) ~= "table" then return nil end
    local sp = {}
    for rk, lower in pairs(by_rank_name(s.sp)) do sp[rk] = by_rank_name(lower) end
    slot_tbl = { normal = by_rank_name(s.normal), sp = sp, frenzy = s.frenzy,
        em = by_rank_name(s.em), em_items = s.em_items or {} }
    return slot_tbl
end
-- table row that applies to a quest star: the highest table rank <= star
local function row_for(t, star)
    local best, bn = nil, -1
    for rk, v in pairs(t or {}) do
        local n = rank_num(rk)
        if n and star and n <= star and n > bn then best, bn = v, n end
    end
    return best, (bn >= 0) and string.format("REWARD_RANK_%02d", bn) or nil
end

-- ctx = { kind = "regular"|"sp", star, grade, frenzy, min_star }
-- returns max legal slot count (nil = unknown) and a short table description
local function slot_limit(ctx)
    local s = load_slots()
    if not (s and ctx and ctx.star and ctx.grade) then return nil, "no vanilla slot snapshot" end
    if ctx.kind == "regular" and ctx.frenzy then
        return s.frenzy, "frenzy table"
    end
    if ctx.kind == "regular" then
        local row, rk = row_for(s.normal, ctx.star)
        return row and row[ctx.grade], string.format("%s grade %d", tostring(rk), ctx.grade)
    end
    local lower, rk = row_for(s.sp, ctx.star)
    local tbl, lrk = row_for(lower, ctx.min_star or ctx.star)
    local cap = tbl and (tbl[ctx.grade] or tbl[0])
    return cap, string.format("%s Sp lower %s grade %d", tostring(rk), tostring(lrk), ctx.grade)
end

-- EM-item caps (Basic/Valuable Material...): _ExjudgeEmRewardArray maps item ->
-- slot rank (COMMON/UNCOMMON/RARE); _EmRewardTblByRank gives that rank's _SlotNum.
local function em_item_cap(item, star)
    local s = load_slots()
    if not s then return nil end
    local tr = s.em_items[item]
    if tr == nil then return nil end
    local row = row_for(s.em, star or 99)
    return row and row[tr]
end

-- reward-table cap, else EM-item cap (exact=true: EM caps are rank-resolved)
-- 3rd return "part" = cap is the monster-part assumption below (not a table hit)
local function cap_for(rank, item, em_ids)
    local cap, exact = legality_of_item(rank, item, em_ids)
    if cap ~= nil then return cap, exact end
    local ec = em_item_cap(item, rank_num(rank))
    if ec ~= nil then return ec, true end
    -- monster parts: the roll's monster(s) own drop table (EnemyRewardData)
    -- gives the real max count per item (gems x1, spikes x3...)
    local dc
    for _, id in ipairs(em_ids or {}) do
        local t = em_drop_caps and em_drop_caps(id)
        local c = t and t[item]
        if c and (dc == nil or c > dc) then dc = c end
    end
    if dc then return dc, true, "drop" end
    -- fallback when no monster is known (saved-quest tables): (e.g. Nerscylla Spike+) are what judgeRareEmReward turns a
    -- Basic/Valuable placeholder into, so they inherit the largest placeholder cap.
    -- shortcut: assumes every uncapped item is a judged monster part; upgrade if
    -- a non-material uncapped item ever appears in a roll.
    local s = load_slots()
    if s then
        local best
        for it in pairs(s.em_items) do
            local c = em_item_cap(it, rank_num(rank))
            if c and (best == nil or c > best) then best = c end
        end
        if best then return best, true, "part" end
    end
    return nil, false
end

local function collect_item_caps(obj)
    -- prefer the mod's pre-patch vanilla snapshot (source of truth)
    -- the live tables are never read: the mod patches them in place, so they
    -- would validate the mod against itself. No snapshot -> no verdicts.
    local snapped = ingest_vanilla_snapshot()
    if snapped == 0 and not snapshot_warned then
        snapshot_warned = true
        l("CAPS REFUSED: no vanilla snapshot (_G.LMRI_VANILLA_CAPS). Set snapshot_vanilla=true in LMRInvestigations.json and restart the game.")
    end
    return snapped
end

-- ---------------------------------------------------------------------------
-- Grounding diff: live reader vs vanilla snapshot (confirmation, not source)
-- ---------------------------------------------------------------------------
local function ground_diff()
    local ok, err = pcall(function()
        local G = load_ground()
        l("######## GROUNDING (live reader vs vanilla snapshot)")
        if G == nil then l("GROUND: snapshot not loaded - deploy LMRI_Grounding_Data.lua to reframework/data"); return end
        if not caps_ready then l("GROUND: caps not collected yet"); return end
        local mism = 0
        local total_live = 0
        local total_snap = 0
        for src, tbl in pairs(cap_by_src) do
            local snap_src = G.ITEM_CAPS and G.ITEM_CAPS[src]
            for rk, items in pairs(tbl) do
                for it, num in pairs(items) do
                    total_live = total_live + 1
                    local snap = snap_src and snap_src[rk] and snap_src[rk][it]
                    if snap ~= num then
                        mism = mism + 1
                        if mism <= 20 then
                            l(string.format("GROUND DIFF %s %s item %d (%s): live=%s snapshot=%s",
                                src, rk, it, tostring(ground_item_name(it) or ("item " .. it)),
                                tostring(num), tostring(snap or "nil")))
                        end
                    end
                end
            end
            if snap_src then
                for rk, items in pairs(snap_src) do
                    for it in pairs(items) do total_snap = total_snap + 1 end
                end
            end
        end
        -- items missing entirely (present in snapshot, never seen live)
        local missing = 0
        for src, snap_src in pairs(G.ITEM_CAPS or {}) do
            for rk, items in pairs(snap_src) do
                for it in pairs(items) do
                    local seen = false
                    local live_tbl = cap_by_src[src]
                    if live_tbl and live_tbl[rk] and live_tbl[rk][it] then seen = true end
                    if not seen then
                        missing = missing + 1
                        if missing <= 20 then
                            l(string.format("GROUND MISSING %s %s item %d (%s)", src, rk, it,
                                tostring(ground_item_name(it) or ("item " .. it))))
                        end
                    end
                end
            end
        end
        l(string.format("GROUND: %d live entries vs %d snapshot entries, %d value mismatch(es), %d snapshot-only item(s)",
            total_live, total_snap, mism, missing))
        if mism > 0 or missing > 0 then
            -- snapshot != extracted vanilla file: either a game update (regenerate
            -- the grounding file) or the snapshot was taken after the mod patched
            l("!!!! GROUND WARNING: vanilla snapshot differs from the grounding file - caps may be MODDED values."
                .. " Restart the game (snapshot must be taken before the mod patches); if it persists after a game update, regenerate LMRI_Grounding_Data.lua.")
        end
        -- slot tables: G.SLOT_CAPS[rank][grade] merges normal + Sp (max LotNum)
        local s = load_slots()
        if not s then
            l("GROUND SLOTS: no vanilla slot snapshot (_G.LMRI_VANILLA_SLOTS) - slot checks will read n/a")
        else
            local merged, smism = {}, 0
            local function put(rk, grade, lot)
                merged[rk] = merged[rk] or {}
                if lot > (merged[rk][grade] or 0) then merged[rk][grade] = lot end
            end
            for rk, gt in pairs(s.normal) do for g, lot in pairs(gt) do put(rk, g, lot) end end
            for rk, lower in pairs(s.sp) do
                for _, gt in pairs(lower) do for g, lot in pairs(gt) do put(rk, g, lot) end end
            end
            for rk, gt in pairs(G.SLOT_CAPS or {}) do
                for g, lot in pairs(gt) do
                    local live = merged[rk] and merged[rk][g]
                    if live ~= lot then
                        smism = smism + 1
                        l(string.format("GROUND SLOT DIFF %s grade %s: snapshot=%s grounding=%s",
                            rk, tostring(g), tostring(live), tostring(lot)))
                    end
                end
            end
            l(string.format("GROUND SLOTS: %d mismatch(es); frenzy max snapshot=%s grounding=%s",
                smism, tostring(s.frenzy), tostring(G.FRENZY_CAP)))
            local em = {}
            for it, tr in pairs(s.em_items) do
                em[#em + 1] = string.format("%s(%d)=%s", tostring(ground_item_name(it) or item_name_of(fixed_to_item[it] or it) or "?"), it,
                    tostring(em_item_cap(it, 99)))
            end
            table.sort(em)
            l("GROUND EM-ITEM caps (top rank row): " .. table.concat(em, ", "))
        end
        l("######## GROUNDING END")
    end)
    if not ok then l("GROUND: diff error: " .. tostring(err)) end
end

-- ---------- settings sanity (F5) ---------------------------------------------

local SLOTS_PER_EVENT15 = 6
local FRENZY_LEGAL_CAP = 3

local sett_errors = {}

local function check_settings(obj)
    sett_errors = {}
    if obj == nil then return 0 end
    if get_f(obj, "_RewardSlotTbl_Frenzy") then
        each_elem(get_f(obj, "_RewardSlotTbl_Frenzy"), function(s)
            local lot = get_f(s, "_LotNum")
            if lot and tonumber(lot) > FRENZY_LEGAL_CAP then
                sett_errors[#sett_errors + 1] = string.format("FRENZY lot %s > %d", tostring(lot), FRENZY_LEGAL_CAP)
            end
        end)
    end
    return #sett_errors
end

-- ---------- content signature ------------------------------------------------

local function quest_sig(q)
    if q == nil then return "" end
    local parts = {}
    local exfield = q:get_field("_ExField")
    if exfield then
        local elist = exfield:get_field("_EventList")
        local ec = exfield:get_field("EventCount")
        if elist and ec then
            for e = 0, ec - 1 do
                local okEv, ev = pcall(function() return elist:call("get_Item", e) end)
                if okEv and ev then
                    local et = ev:get_field("EventType") or 0
                    parts[#parts + 1] = "T" .. tostring(et)
                    for j = 0, SLOTS_PER_EVENT15 - 1 do
                        local fv = ev:get_field("EventValue" .. j) or 0
                        local cv = ev:get_field("EventMiniValue" .. j) or 0
                        parts[#parts + 1] = string.format("%s:%s", tostring(fv), tostring(cv))
                    end
                end
            end
        end
    end
    return table.concat(parts)
end

local function keep_sig(keep)
    local parts = {}
    local function addlist(mn)
        local okL, list = pcall(function() return keep:call(mn) end)
        if okL and list then
            local okC, c = pcall(function() return list:call("get_Count") end)
            if okC and c then
                for i = 0, c - 1 do
                    local okE, e = pcall(function() return list:call("get_Item", i) end)
                    if okE and e then
                        local id = fixed_id_of(e)
                        local num = get_f(e, "Num")
                        parts[#parts + 1] = string.format("%s:%s", tostring(id or 0), tostring(num or 0))
                    end
                end
            end
        end
    end
    addlist("getSpOfferRewardList")
    addlist("getExEmRewardList")
    return table.concat(parts)
end

local keep_sigh = {}   -- signature of keep data already reported live

local function validate_keep(keep)
    local issues = {}
    local by_item = {}
    local function addlist(mn)
        local okL, list = pcall(function() return keep:call(mn) end)
        if okL and list then
            local okC, c = pcall(function() return list:call("get_Count") end)
            if okC and c then
                for i = 0, c - 1 do
                    local okE, e = pcall(function() return list:call("get_Item", i) end)
                    if okE and e then
                        local fixed, runtime = keep_ids_of(e)
                        local item = fixed or runtime
                        local num = get_f(e, "Num")
                        local nv = tonumber(num)
                        if item and nv and nv > 0 then
                            local cap = cap_for(nil, item)
                            if cap ~= nil and nv > cap then
                                local key = (fixed or 0) .. "_" .. tostring(runtime or "r")
                                local agg = by_item[key]
                                if not agg then
                                    agg = { item = item, name_id = runtime or item, nv = nv, cap = cap, list = mn, slots = 0 }
                                    by_item[key] = agg
                                end
                                agg.slots = agg.slots + 1
                                if nv > agg.nv then agg.nv = nv end
                            end
                        end
                    end
                end
            end
        end
    end
    addlist("getSpOfferRewardList")
    addlist("getExEmRewardList")
    for _, agg in pairs(by_item) do
        issues[#issues + 1] = string.format(
            "item %d (%s) count %d > cap %d in %s [caps: %s]",
            agg.item, tostring(item_name_of(agg.name_id) or "?"), agg.nv, agg.cap, agg.list,
            tostring(cap_provenance(agg.item) or "?"))
    end
    table.sort(issues)
    return issues
end

local SAVED_INVESTIGATION_ID = 391
local EVENT_TYPE_REWARD = 15

-- validate ONE saved quest (MissionId 391) - raw event slots + conversion
-- ---------- investigation description + readable table rendering --------------

-- Collect every reward slot + conversion issues for ONE saved investigation,
-- producing a plain-data descriptor the table renderer turns into a log block.
local function describe_quest(q, i)
    local desc = { label = "?", lv = nil, rows = {}, issues = {}, active = 0, events = 0 }
    -- identity + REWARDS come from the CONVERTED keep object: it carries the
    -- quest level, target monster array, AND the authoritative rolled reward
    -- lists (getSpOfferRewardList / getExEmRewardList) - the same source the
    -- game UI and Investigation Editor use. The raw _EventList EventType-15
    -- rows are reward POOLS, not the rolled rewards, so they mislead (qu[1]
    -- had 11 pool entries = 55 pseudo-slots while its real reward list has 5).
    local keep_obj = nil
    local ot = sdk.find_type_definition("app.QuestUtil")
    if ot then
        local cm = ot:get_method("convertSaveData2KeepQuest")
        if cm then
            local okK, keep = pcall(function() return cm:call(nil, q) end)
            if okK and keep ~= nil then
                keep = sdk.to_managed_object(keep)
                if keep ~= nil then
                    keep_obj = keep
                    local okL2, v2 = pcall(function() return keep:call("getQuestLv()") end)
                    if okL2 then desc.lv = tonumber(v2) end
                    local okV2, res2 = pcall(function() return validate_keep(keep) end)
                    if okV2 then
                        for _, v in ipairs(res2) do desc.issues[#desc.issues + 1] = v end
                    end
                    -- build the reward rows from the keep lists (authoritative)
                    local function add_list(mn, src)
                        local okL, list = pcall(function() return keep:call(mn) end)
                        if not okL or not list then return end
                        local okC, c = pcall(function() return list:call("get_Count") end)
                        if not okC or not c then return end
                        for x = 0, c - 1 do
                            local okE, e = pcall(function() return list:call("get_Item", x) end)
                            if okE and e then
                                local fixed, runtime = keep_ids_of(e)
                                local item = fixed or runtime
                                local num = get_f(e, "Num")
                                local nv = tonumber(num)
                                if item and nv and nv > 0 then
                                    desc.active = desc.active + 1
                                    local cap = cap_for(nil, item)
                                    local verdict = (cap == nil) and "n/a" or ((nv > cap) and "ILLEGAL" or "ok")
                                    desc.rows[#desc.rows + 1] = {
                                        e = -1, j = x, item = item, src = src,
                                        name = item_name_of(runtime or item) or ("item " .. tostring(runtime or item)),
                                        count = nv, cap = cap, verdict = verdict,
                                    }
                                end
                            end
                        end
                    end
                    add_list("getSpOfferRewardList", "SpOffer")
                    add_list("getExEmRewardList", "ExEm")
                end
            end
        end
    end
    desc.label = quest_label(keep_obj or q)
    desc.label = desc.label:gsub("%s*%(lv=%d+%)%s*$", "")   -- quest_label already appends lv;
    -- diagnostics only: count EventType-15 entries in the raw _EventList
    -- (they are reward POOLS, not rolled rewards - kept for comparison)
    local exfield = q:get_field("_ExField")
    if exfield then
        local elist = exfield:get_field("_EventList")
        local ec = exfield:get_field("EventCount")
        if elist and ec then
            for e = 0, ec - 1 do
                local okEv, ev = pcall(function() return elist:call("get_Item", e) end)
                if okEv and ev and ev:get_field("EventType") == EVENT_TYPE_REWARD then
                    desc.events = desc.events + 1
                end
            end
        end
    end
    return desc
end

-- write a table body line WITHOUT the per-line timestamp, so columns stay aligned
local function lr(msg)
    local txt = tostring(msg)
    local ok, f = pcall(io.open, "LMRI_Legality.log", "a")
    if ok and f then f:write(txt .. "\n"); f:close() end
end

local LINE = "=" .. string.rep("=", 76)

local function render_quest_table(desc, i, marker)
    local lines = {}
    local title = string.format("INVESTIGATION [qu %d]  %s", i, desc.label or "?")
    if marker then title = title .. "   <<" .. tostring(marker) .. ">>" end
    if desc.lv then title = title .. "   (lv=" .. tostring(desc.lv) .. ")" end
    lines[#lines + 1] = LINE
    lines[#lines + 1] = title
    local namew = 24
    for _, r in ipairs(desc.rows) do
        if r.name and #r.name > namew then namew = #r.name end
    end
    if namew > 48 then namew = 48 end
    -- Lua's string.format has no %* width-from-arg; bake the width in as a literal
    local col_fmt = "  %-4s %-8s %-6s  %-" .. tostring(namew) .. "s  %-6s  %-5s  %s"
    lines[#lines + 1] = string.format(col_fmt, "#", "source", "idx", "item", "count", "cap", "verdict")
    lines[#lines + 1] = "-" .. string.rep("-", 76)
    local row_fmt = "  %-4d %-8s %-6d  %-" .. tostring(namew) .. "s  %-6s  %-5s  %s"
    for n, r in ipairs(desc.rows) do
        local nm = r.name
        if #nm > namew then nm = string.sub(nm, 1, namew - 3) .. "..." end
        lines[#lines + 1] = string.format(row_fmt,
            n, r.src or "?", r.j, nm,
            tostring(r.count or 0),
            r.cap and tostring(r.cap) or "n/a",
            r.verdict or "n/a")
    end
    lines[#lines + 1] = "-" .. string.rep("-", 76)
    lines[#lines + 1] = string.format("  reward slots: %d    raw reward-pool events(EventType15): %d",
        desc.active, desc.events)
    -- when caps are not loaded yet, no slot can be judged - say so explicitly
    local status
    if not caps_ready then
        status = "PENDING (vanilla caps not loaded yet)"
    elseif #desc.issues == 0 then
        status = "LEGAL"
    else
        status = "ILLEGAL (" .. #desc.issues .. " issue(s))"
    end
    lines[#lines + 1] = string.format("  status: %s", status)
    if #desc.issues > 0 then
        for _, is in ipairs(desc.issues) do lines[#lines + 1] = "  ! " .. is end
    end
    lines[#lines + 1] = LINE
    return lines
end

local function dump_quest(i, q, marker)
    local ok, desc = pcall(function() return describe_quest(q, i) end)
    if not ok or not desc then
        l("DUMP qu[" .. i .. "]: describe error " .. tostring(desc))
        return nil
    end
    for _, line in ipairs(render_quest_table(desc, i, marker)) do lr(line) end
    return desc
end

-- forward declarations: these are defined in the baseline section below, but
-- the describe/dump functions (defined here) must call them as long-lived
-- upvalues, so declare the names before any use.
local save_loaded
local baseline_dates
local baseline_sigs
local baseline_ready

-- Enumerate EVERY saved investigation (MissionId 391) and print one readable
-- table per quest. Runs on save load and again once vanilla caps are ready.
local function dump_all(reason)
    if not save_loaded() then l("DUMP: no save loaded yet - enter the game first"); return end
    build_fixed_map()
    lr("######## ALL SAVED INVESTIGATIONS  (" .. tostring(reason) .. ")")
    local sm = sdk.get_managed_singleton("app.SaveDataManager")
    if not sm then lr("# no SaveDataManager"); return end
    local okU, us = pcall(function() return sm:call("getCurrentUserSaveData") end)
    if not okU or not us then lr("# no save"); return end
    local okF, qf = pcall(function() return us:get_type_definition():get_field("_Quest") end)
    if not okF or not qf then lr("# no _Quest field"); return end
    local okQ, qa = pcall(function() return qf:get_data(us) end)
    if not okQ or not qa then lr("# no quest array"); return end
    local okN, n = pcall(function() return qa:call("get_Count") end)
    if not okN or not n then lr("# no count"); return end
    local shown = 0
    local ok2, bad = 0, 0
    for i = 0, n - 1 do
        local okItem, q = pcall(function() return qa:call("get_Item", i) end)
        if okItem and q and q:get_field("MissionId") == SAVED_INVESTIGATION_ID then
            shown = shown + 1
            local created = q:get_field("CreatedDate")
            local marker = created and baseline_dates[created] and "PRE-EXISTING" or "NEW"
            local desc = dump_quest(i, q, marker)
            if desc then
                if #desc.issues == 0 then ok2 = ok2 + 1 else bad = bad + 1 end
            end
        end
    end
    lr(string.format("TOTAL: %d saved investigation(s) shown  |  %d legal, %d with issue(s)", shown, ok2, bad))
    lr("######## ALL SAVED INVESTIGATIONS END")
end

-- ---------- saved-quest baseline & watcher -----------------------------------

-- A save is "loaded" only when the player character exists in the world (same
-- signal CatLib uses). At the main menu there is no character, so the quest
-- array is just template/placeholder data - nothing must be validated yet.
save_loaded = function()
    local pm = sdk.get_managed_singleton("app.PlayerManager")
    if pm == nil then return false end
    local okM, mp = pcall(function() return pm:call("getMasterPlayer") end)
    if not okM or mp == nil then return false end
    local okC, ch = pcall(function() return mp:call("get_Character") end)
    return okC and ch ~= nil
end

baseline_dates = {}
baseline_sigs = {}
baseline_ready = false

local function snapshot_baseline()
    if baseline_ready then return end
    if not save_loaded() then return end
    local sm = sdk.get_managed_singleton("app.SaveDataManager")
    if not sm then return end
    local okU, us = pcall(function() return sm:call("getCurrentUserSaveData") end)
    if not okU or not us then return end
    local okF, qf = pcall(function() return us:get_type_definition():get_field("_Quest") end)
    if not okF or not qf then return end
    local okQ, qa = pcall(function() return qf:get_data(us) end)
    if not okQ then return end
    local okN, n = pcall(function() return qa:call("get_Count") end)
    if not okN or not n then return end
    for i = 0, n - 1 do
        local okQ2, q = pcall(function() return qa:call("get_Item", i) end)
        if okQ2 and q and q:get_field("MissionId") == SAVED_INVESTIGATION_ID then
            local created = q:get_field("CreatedDate")
            if created then
                baseline_dates[created] = true
                baseline_sigs[created] = quest_sig(q)
            end
        end
    end
    baseline_ready = true
    l(string.format("LEGAL: baseline captured (%d saved investigation(s) excluded)", countt(baseline_dates)))
end

local function check_quests(reported)
    if not save_loaded() then return end
    if not (fixed_ready or build_fixed_map()) then return end
    local sm = sdk.get_managed_singleton("app.SaveDataManager")
    if not sm then return end
    local okU, us = pcall(function() return sm:call("getCurrentUserSaveData") end)
    if not okU or not us then return end
    local okF, qf = pcall(function() return us:get_type_definition():get_field("_Quest") end)
    if not okF or not qf then return end
    local okQ, qa = pcall(function() return qf:get_data(us) end)
    if not okQ then return end
    local okN, n = pcall(function() return qa:call("get_Count") end)
    if not okN or not n then return end
    local checked, fails = 0, 0
    for i = 0, n - 1 do
        local okQ2, q = pcall(function() return qa:call("get_Item", i) end)
        if okQ2 and q and q:get_field("MissionId") == SAVED_INVESTIGATION_ID then
            local created = q:get_field("CreatedDate")
            local sig = quest_sig(q)
            local new_content = false
            if created and baseline_dates[created] then
                if baseline_sigs[created] and baseline_sigs[created] ~= sig then
                    new_content = true
                    baseline_sigs[created] = sig
                end
            else
                new_content = true
                if created then
                    baseline_sigs[created] = sig
                    baseline_dates[created] = true
                end
            end
            if new_content then
                checked = checked + 1
                local okD, desc = pcall(function() return describe_quest(q, i) end)
                if not okD or not desc then
                    desc = { label = "?", rows = {}, issues = { "describe error: " .. tostring(desc) }, active = 0 }
                end
                if #desc.issues == 0 then
                    if reported then
                        lr("**** NEW/CHANGED INVESTIGATION qu[" .. i .. "] " .. tostring(desc.label) .. " : LEGAL")
                    end
                else
                    fails = fails + 1
                    lr("**** NEW/CHANGED INVESTIGATION qu[" .. i .. "] " .. tostring(desc.label) .. " : ILLEGAL")
                end
                for _, line in ipairs(render_quest_table(desc, i, "NEW/CHANGED")) do lr(line) end
            end
        end
    end
    if checked > 0 then
        l(string.format("LEGAL: %d changed/new saved investigation(s) checked, %d violation(s)", checked, fails))
    elseif reported then
        l(string.format("LEGAL: 0 changed/new saved investigation(s)"))
    end
end

local function verify_all()
    dump_all("F5 VERIFY")
end

-- ---------- live roll capture ------------------------------------------------

-- roll payload readers (must precede scan_roll_args which calls them)
local function read_item_work_list(m)
    local es = nil
    local okE, e1 = pcall(function() return m:get_elements() end)
    if okE and e1 and type(e1) == "table" and #e1 > 0 then
        es = e1
    else
        local okC, c = pcall(function() return m:call("get_Count") end)
        if okC and c and c > 0 then
            es = {}
            for i = 0, math.min(c - 1, 47) do
                local okI, it = pcall(function() return m:call("get_Item", i) end)
                if okI and it then es[#es + 1] = it end
            end
        end
    end
    if not es or #es == 0 then return nil end
    local rows = {}
    for _, el in ipairs(es) do
        if type(el) == "userdata" then
            local okM, em = pcall(function() return sdk.to_managed_object(el) end)
            if okM and em then
                local okF, f = pcall(function() return em:get_field("ItemIdFixed") end)
                local okN, n = pcall(function() return em:get_field("Num") end)
                if not okF or f == nil then
                    local okF2, f2 = pcall(function() return em:get_field("_RewardItem") end)
                    if okF2 and f2 ~= nil then f = f2 end
                end
                if not okN or n == nil then
                    local okN2, n2 = pcall(function() return em:get_field("_Num") end)
                    if okN2 and n2 ~= nil then n = n2 end
                end
                if f ~= nil then
                    local fid = tonumber(f)
                    if fid == nil then fid = normalize_key(f) end
                    -- item = fixed/table id (for cap lookups);
                    -- name_id = runtime id (get_ItemId / fixed_to_item) if we can
                    -- resolve it, else fixed (names fall back to IE lookup)
                    local rid = fixed_to_item[fid] or fid
                    rows[#rows + 1] = { fixed = fid, item = fid, name_id = rid, num = n or 0 }
                end
            end
        end
    end
    if #rows == 0 then return nil end
    return rows
end

-- Regular rolls pass app.cExEnemyRewardItemInfo: _RewardList is a
-- cLimitedArray<ExRewardData> (ItemIDValue/ItemNum value types, NOT cItemWork),
-- so read it through the info object's own getItemID(i)/getItemNum(i).
-- getItemID is the runtime ItemDef.ID (NOT fixed: treating it as fixed showed
-- every item one id off on the board), mapped back via item_to_fixed.
local function read_reward_info_payload(m)
    local okL, rl = pcall(function() return m:get_field("_RewardList") end)
    if not okL or rl == nil then return nil end
    local okC, c = pcall(function() return sdk.to_managed_object(rl):call("get_Count") end)
    if not okC or not c or c <= 0 then return nil end
    local rows = {}
    for i = 0, c - 1 do
        local okI, rid = pcall(function() return m:call("getItemID", i) end)
        local okN, n = pcall(function() return m:call("getItemNum", i) end)
        rid = okI and tonumber(rid) or nil
        if rid then
            -- getItemID returns the RUNTIME ItemDef.ID (verified against the
            -- in-game board): name by it directly, convert to fixed for caps
            local fid = item_to_fixed[rid] or rid
            rows[#rows + 1] = { fixed = fid, item = fid, name_id = rid,
                num = okN and tonumber(n) or 0 }
        end
    end
    if #rows == 0 then return nil end
    return rows
end

-- forward declarations: assigned below (before any runtime call)
local check_rolled_items

-- Monster ids of each roll method, by hook-arg position (args[1]=thread ctx,
-- args[2]=this). EnemyDef.ID is a value-type enum passed raw in the 64-bit
-- arg slot (upper bits are garbage), so read the low 32 bits:
--   judgeRareEmReward(cExEnemyRewardItemInfo, EnemyDef.ID, bool)        -> [4]
--   judgeRareEmReward_SpOffer(List<cItemWork>, ID, ID, bool)            -> [4],[5]
local EM_ARG_POS = { judgeRareEmReward = { 4 }, judgeRareEmReward_SpOffer = { 4, 5 } }

local function em_ids_of(args, mn)
    local ids = {}
    for _, i in ipairs(EM_ARG_POS[mn] or {}) do
        local ok, v = pcall(function() return sdk.to_int64(args[i]) % 0x100000000 end)
        -- >= 0x80000000 is a negative enum (INVALID/-1), not a monster
        if ok and v and v < 0x80000000 then ids[#ids + 1] = v end
    end
    return ids
end

local function scan_roll_args(args, mn)
    if not (fixed_ready or build_fixed_map()) then return end
    local em_ids = em_ids_of(args, mn)
    local ok, m = pcall(function() return sdk.to_managed_object(args[3]) end)
    if not ok or not m then return end
    local rows = read_item_work_list(m) or read_reward_info_payload(m)
    if rows then check_rolled_items(rows, mn, em_ids) end
end

local em_cache = {}

-- EnemyDef.NameString(ID, ROLE_ID=0, LEGENDARY_ID=0) -> localized name.
-- Only successes are cached, so a call made before the message tables load
-- can still succeed later.
local function enemy_name(em_id)
    if em_id == nil or em_id < 0 then return nil end
    if em_cache[em_id] then return em_cache[em_id] end
    local td = sdk.find_type_definition("app.EnemyDef")
    local m = td and td:get_method("NameString")
    if not m then return nil end
    local ok, name = pcall(function() return m:call(nil, em_id, 0, 0) end)
    if ok and name ~= nil and tostring(name) ~= "" then
        em_cache[em_id] = tostring(name)
        return em_cache[em_id]
    end
    return nil
end

local captured_rolls = {}
local roll_seq = 0
local roll_seen = {}
local pending_rolls = {}   -- sig -> { t, args } unranked hook rolls awaiting the field scan
local flushing_rolls = false
local PENDING_GRACE = 15.0 -- > 2 field-scan periods

-- log held hook rolls the field scan never matched (e.g. saved immediately)
local function flush_pending_rolls()
    local now = os.clock()
    for sig, p in pairs(pending_rolls) do
        if now - p.t > PENDING_GRACE then
            pending_rolls[sig] = nil
            flushing_rolls = true
            pcall(check_rolled_items, p.args[1], p.args[2], p.args[3], p.args[4], p.args[5])
            flushing_rolls = false
        end
    end
end

-- returns issues (illegal) and warns (legal but not at max: the mod's goal is
-- "always max", but an item's cap here is the max over every table at this
-- rank, so a below-max count can also mean the roll came from a lower table)
local function validate_rolled_rows(rows, rank, slots_ctx, em_ids)
    local by_item = {}
    local warns = {}
    for _, r in ipairs(rows) do
        if r.item ~= nil then
            local cap, _, kind = cap_for(rank, r.item, em_ids)
            if cap ~= nil then
                local n = tonumber(r.num or 0)
                -- monster-part caps (drop table / assumption) are a max over
                -- several reward types, so no below-max warning against them
                if rank and n < cap and kind == nil then
                    warns[#warns + 1] = string.format("%s x%d < max %d",
                        tostring(item_name_of(r.name_id or r.item) or r.item), n, cap)
                end
                if n > cap then
                    local key = r.item
                    local e = by_item[key]
                    if not e then
                        e = { item = r.item, name_id = r.name_id or r.item, num = n, cap = cap, slots = 0 }
                        by_item[key] = e
                    end
                    e.slots = e.slots + 1
                    if n > e.num then e.num = n end
                end
            end
        end
    end
    local issues = {}
    for _, e in pairs(by_item) do
        issues[#issues + 1] = string.format(
            "item %d (%s) in %d slot(s) count %d > cap %d [caps: %s]",
            e.item, tostring(item_name_of(e.name_id) or "?"), e.slots, e.num, e.cap,
            tostring(cap_provenance(e.item) or "EM table"))
    end
    table.sort(issues)
    -- slot count: vanilla LotNum for this rank/grade (frenzy table for frenzied)
    if slots_ctx then
        local lim, what = slot_limit(slots_ctx)
        if lim and #rows > lim then
            issues[#issues + 1] = string.format("%d slot(s) > vanilla max %d [%s]", #rows, lim, what)
        elseif lim and #rows < lim then
            warns[#warns + 1] = string.format("%d slot(s) < vanilla max %d", #rows, lim)
        end
    end
    return issues, warns
end

-- labels (optional): display names per monster (e.g. "Frenzied Blangonga"),
-- used instead of the plain enemy_name lookup; not part of the dedupe sig
-- rank (optional): REWARD_RANK_xx key for per-rank caps; nil = cross-rank max
-- slots_ctx (optional): { kind, star, grade, frenzy, min_star } for the slot-count check
check_rolled_items = function(rows, mn, em_ids, tag, labels, rank, slots_ctx)
    if not rows then return end
    em_ids = em_ids or {}
    local em_id = #em_ids > 0 and em_ids[1] or nil
    local sig = mn .. "|" .. table.concat(em_ids, "+") .. "|"
    for _, r in ipairs(rows) do
        sig = sig .. tostring(r.fixed) .. "x" .. tostring(r.num) .. ","
    end
    -- roll_seen[sig]: "ranked" or "unranked". A hook roll (no rank known) is
    -- re-checked once when the field scan sees the same roll WITH its rank.
    local seen = roll_seen[sig]
    if seen == "ranked" or (seen and not rank) then return end
    -- hook rolls carry no rank/grade: hold them; the field scan usually logs
    -- the same roll with rank within seconds, else flush_pending_rolls logs it
    if not rank and not flushing_rolls then
        if not pending_rolls[sig] then
            pending_rolls[sig] = { t = os.clock(), args = { rows, mn, em_ids, tag, labels } }
        end
        return
    end
    pending_rolls[sig] = nil
    roll_seen[sig] = rank and "ranked" or "unranked"
    roll_seq = roll_seq + 1

    -- human-readable reward breakdown (names + counts)
    local desc = {}
    for _, r in ipairs(rows) do
        desc[#desc + 1] = string.format("%s x%s",
            tostring(item_name_of(r.name_id or r.item) or ("fixed " .. tostring(r.fixed))),
            tostring(r.num))
    end

    local issues, warns = validate_rolled_rows(rows, rank, slots_ctx, em_ids)
    -- monster name(s): prefer the em ids found in the args (Sp offers have 2)
    local names = {}
    for i, id in ipairs(em_ids) do
        local nm = (labels and labels[i]) or enemy_name(id)
        if nm then names[#names + 1] = nm end
    end
    local who = (#names > 0) and table.concat(names, " + ") or "?"
    local em_str = (#em_ids > 0) and table.concat(em_ids, "+") or nil
    local rec = {
        id = "#" .. roll_seq,
        sources = { mn },
        name = (who ~= "?") and who or nil,
        em = em_id,
        rows = rows,
        issues = issues,
        desc = desc,
    }
    captured_rolls[#captured_rolls + 1] = rec
    if #issues > 0 then
        l(string.format("LIVE ILLEGAL %s %s (%s): %s",
            mn, tostring(rec.id), tostring(who), table.concat(issues, "; ")))
    end
    if #warns > 0 then
        l(string.format("BELOW MAX %s (%s): %s", tostring(rec.id), tostring(who), table.concat(warns, "; ")))
    end
    l(string.format("ROLLCHECK %s (%s%s%s): %d slot(s) | %s | %d violation(s), %d below-max",
        tostring(rec.id), mn,
        em_str and (" em=" .. em_str .. " " .. who) or "", tag and (", " .. tag) or "",
        #rows, table.concat(desc, ", "), #issues, #warns))
    -- A region-board roll IS a generated investigation. Render it as a compact
    -- table (with per-slot caps + verdicts), grouped by regeneration burst.
    if caps_ready then
        local gline = {}
        local namew = 24
        for _, r in ipairs(rows) do
            local nm = item_name_of(r.name_id or r.item) or ("fixed " .. tostring(r.fixed))
            if #nm > namew then namew = #nm end
        end
        if namew > 40 then namew = 40 end
        local gcol = "  %-4s  %-" .. tostring(namew) .. "s  %-5s  %-5s  %s"
        gline[#gline + 1] = LINE
        gline[#gline + 1] = string.format("GENERATED INVESTIGATION %s: %s (%s%s%s) caps: %s",
            tostring(rec.id), who, mn, em_str and (" em=" .. em_str) or "", tag and (", " .. tag) or "",
            rank or "cross-rank max (rank unknown)")
        gline[#gline + 1] = string.format(gcol, "#", "item", "count", "cap", "verdict")
        gline[#gline + 1] = "-" .. string.rep("-", 70)
        local fallback, part, drop = false, false, false
        for n, r in ipairs(rows) do
            local nm = item_name_of(r.name_id or r.item) or ("fixed " .. tostring(r.fixed))
            if #nm > namew then nm = string.sub(nm, 1, namew - 3) .. "..." end
            local cap, exact, kind = cap_for(rank, r.item, em_ids)
            local nv = tonumber(r.num or 0)
            local vd = (cap == nil) and "n/a" or ((nv > cap) and "ILLEGAL"
                or ((rank and nv < cap and kind == nil) and "ok, below max" or "ok"))
            -- "*" = cross-rank fallback; "~" = monster-part assumption;
            -- "^" = monster drop table
            local mark = (kind == "part") and "~" or (kind == "drop") and "^"
                or ((rank and not exact) and "*" or "")
            local cs = cap and (tostring(cap) .. mark) or "n/a"
            if mark == "*" and cap then fallback = true end
            if mark == "~" then part = true end
            if mark == "^" then drop = true end
            gline[#gline + 1] = string.format(gcol, n, nm, tostring(nv), cs, vd)
        end
        if fallback then
            gline[#gline + 1] = "  * item not in " .. rank .. " tables - cap is the cross-rank max"
        end
        if part then
            gline[#gline + 1] = "  ~ item in no reward table - assumed a judged monster part, cap = largest EM-material cap"
        end
        if drop then
            gline[#gline + 1] = "  ^ monster part - cap = max count in the monster's own drop table"
        end
        if slots_ctx then
            local lim, what = slot_limit(slots_ctx)
            local note = (lim == nil) and "n/a" or ((#rows > lim) and "ILLEGAL"
                or ((#rows == lim) and "ok, at max" or "ok, below max"))
            gline[#gline + 1] = string.format("  slots: %d / vanilla max %s [%s] %s",
                #rows, tostring(lim or "?"), what, note)
        else
            gline[#gline + 1] = "  slots: not checked (hook roll, rank/grade unknown)"
        end
        gline[#gline + 1] = string.format("  status: %s%s", (#issues == 0) and "LEGAL" or "ILLEGAL",
            (#warns > 0) and string.format(" (%d below max)", #warns) or "")
        gline[#gline + 1] = LINE
        for _, gl in ipairs(gline) do lr(gl) end
    end
end

-- ---------- field scan: regular investigations of ALL regions ----------------
-- The judge hooks only see regular rolls for the region the player loads into.
-- Every region's regular investigations are its executed field PopEnemy events
-- (EnvironmentManager.findExecutedPopEmsInMyExField(STAGE, false)), each with
-- its rolled cExEnemyRewardItemInfo. Same mn as the hook so rolls dedupe.
local FIELD_SCAN_EVERY = 5.0
local field_scan_time = -FIELD_SCAN_EVERY
local field_last_summary = nil
-- app.cExFieldEvent_PopEnemy -> em id (nil unless it names a monster), display
-- label with the board's modifiers, and a " | rank R grade G" info suffix.
-- ROLE_ID FRENZY=3; LEGENDARY_ID NORMAL=1 (tempered), KING=2 (arch-tempered).
local LEGEND_TAG = { [1] = "Tempered ", [2] = "Arch-tempered " }
local function pop_label(p)
    local function get(name)
        local ok, v = pcall(function() return p:call(name) end)
        return ok and tonumber(v) or nil
    end
    local id = get("get_EmID")
    local name = id and id >= 0 and id <= 0xFFFF and enemy_name(id)
    if not name then return nil end
    local role, leg = get("get_RoleID"), get("get_LegendaryID")
    local label = (LEGEND_TAG[leg] or "") .. (role == 3 and "Frenzied " or "") .. name
    local star, grade = get("get_Rank"), get("get_Grade")
    return id, label, string.format(" | %s rank %s grade %s", label,
        tostring(star), tostring(grade)), star, grade, role == 3
end

local function list_of(v)
    local out = {}
    local mo = nil
    pcall(function() mo = sdk.to_managed_object(v) end)
    if not mo and type(v) == "userdata" then mo = v end   -- getter already returned a managed object
    if not mo then return out end
    local okC, c = pcall(function() return mo:call("get_Count") end)
    if okC and c then
        for i = 0, c - 1 do
            local okE, e = pcall(function() return mo:call("get_Item", i) end)
            if okE and e ~= nil then out[#out + 1] = e end
        end
    else
        -- plain managed arrays (T[]) have no get_Count
        local okA, els = pcall(function() return mo:get_elements() end)
        if okA and type(els) == "table" then out = els end
    end
    return out
end

-- number from a getter result: plain number, boxed Int16/Int32 (m_value) or
-- an ID_Serializable (_Value)
local function num_of(v)
    local n = tonumber(v)
    if n then return n end
    if type(v) == "userdata" then
        for _, f in ipairs({ "m_value", "_Value", "value__" }) do
            local ok, x = pcall(function() return v:get_field(f) end)
            if ok and tonumber(x) then return tonumber(x) end
        end
    end
    return nil
end

-- per monster: fixed item id -> max count over every row and rank column of
-- its EnemyRewardData (_IdEx[k] / _RewardNumEx[k]). Lenient (max over all
-- reward types), but monster-specific. The mod never touches these tables.
local drop_cache = {}
em_drop_caps = function(em_id)
    if em_id == nil then return nil end
    if drop_cache[em_id] ~= nil then return drop_cache[em_id] or nil end
    local caps = false
    pcall(function()
        local vdm = sdk.get_managed_singleton("app.VariousDataManager")
        local ers = vdm:get_Setting():call("get_EnemyRewardSettingData")
        local rd = ers:call("getEnemyRewardData", em_id)
        if not rd then return end
        caps = {}
        for _, row in ipairs(list_of(rd:call("getValues"))) do
            -- _IdEx holds fixed ids (verified: names resolve via fixed_to_item)
            local ids = list_of(row:call("get_IdEx"))
            local nums = list_of(row:call("get_RewardNumEx"))
            for k = 1, #ids do
                local it, n = num_of(ids[k]), num_of(nums[k])
                if it and it > 0 and n and n > 0 and (caps[it] or 0) < n then
                    caps[it] = n
                end
            end
        end
    end)
    if caps and next(caps) == nil then caps = false end
    drop_cache[em_id] = caps
    if not caps then l(string.format("DROPTBL em %d: no drop table read", em_id)) end
    return caps or nil
end

local function field_scan()
    if os.clock() - field_scan_time < FIELD_SCAN_EVERY then return end
    field_scan_time = os.clock()
    if not caps_ready and _G.LMRI_ANCHOR then
        pcall(function() M:on_reward("F9 reuse", { nil, _G.LMRI_ANCHOR }) end)
    end
    if not caps_ready or not (fixed_ready or build_fixed_map()) then return end
    local em = sdk.get_managed_singleton("app.EnvironmentManager")
    if not em then return end
    local td = em:get_type_definition()
    local mS, mF, mSp = td:get_method("getExStageArray"),
        td:get_method("findExecutedPopEmsInMyExField"), td:get_method("getSpOfferInfoList")
    if not (mS and mF) then return end
    local okS, sv = pcall(function() return mS:call(em) end)
    if not okS or sv == nil then return end
    local parts, n_reg, n_sp = {}, 0, 0
    for _, st in ipairs(list_of(sv)) do
        local stn = tonumber(st)
        local reg = 0
        local okF, fv = pcall(function() return mF:call(em, stn, false) end)
        for _, pe in ipairs(okF and fv and list_of(fv) or {}) do
            local p = nil
            pcall(function() p = sdk.to_managed_object(pe) end)
            local okK, keep_ok = pcall(function() return p:call("get_EnableKeepQuestTarget") end)
            local okI, kidx = pcall(function() return p:call("get_KeepQuestIndex") end)
            -- keep index 255 = not saved (saved ones are excluded from verdicts)
            if p and okK and keep_ok and okI and tonumber(kidx) == 255 then
                local okR, info = pcall(function() return p:call("getRewardData_EnemyInfo", false) end)
                local im = nil
                if okR and info then pcall(function() im = sdk.to_managed_object(info) end) end
                local rows = im and read_reward_info_payload(im)
                if rows then
                    reg = reg + 1
                    local id, label, info, star, grade, frenzy = pop_label(p)
                    check_rolled_items(rows, "judgeRareEmReward", id and { id } or {},
                        "field scan, stage " .. tostring(stn) .. (info or ""), id and { label } or nil,
                        reward_rank_of(star),
                        { kind = "regular", star = star, grade = grade, frenzy = frenzy })
                end
            end
        end
        local sp = 0
        if mSp then
            local okP, pv = pcall(function() return mSp:call(em, stn) end)
            for _, off in ipairs(okP and pv and list_of(pv) or {}) do
                sp = sp + 1
                local o = nil
                pcall(function() o = sdk.to_managed_object(off) end)
                local okK, kept = pcall(function() return o:call("get_IsKept") end)
                if o and not (okK and kept) then
                    local okR, ra = pcall(function() return o:call("get_RewardArray") end)
                    local rm = nil
                    if okR and ra then pcall(function() rm = sdk.to_managed_object(ra) end) end
                    local rows = rm and read_item_work_list(rm)
                    if rows then
                        local ids, labels, infos, star, min_star, grade = {}, {}, {}, nil, nil, nil
                        local okT, ta = pcall(function() return o:call("get_TargetEmArray") end)
                        for _, e in ipairs(okT and ta and list_of(ta) or {}) do
                            -- get_TargetEmArray returns app.cExFieldEvent_PopEnemy[] (SDK dump),
                            -- the same objects the regular scan reads get_EmID from
                            local n, label, info, s, g = pop_label(e)
                            -- only trust ids that resolve to a monster: a garbage id
                            -- would change the dedupe signature every scan (log spam)
                            if n then
                                ids[#ids + 1] = n; labels[#labels + 1] = label; infos[#infos + 1] = info
                                -- shortcut: Sp rank = highest target rank (offer's own
                                -- get_QuestRank read "?" in the probe); verify vs board
                                if s and (star == nil or s > star) then star = s end
                                if s and (min_star == nil or s < min_star) then min_star = s end
                                -- shortcut: offer grade = highest target grade (lenient)
                                if g and (grade == nil or g > grade) then grade = g end
                            end
                        end
                        check_rolled_items(rows, "judgeRareEmReward_SpOffer", ids,
                            "field scan, stage " .. tostring(stn) .. table.concat(infos), labels,
                            reward_rank_of(star),
                            { kind = "sp", star = star, grade = grade, min_star = min_star })
                    end
                end
            end
        end
        if reg + sp > 0 then
            parts[#parts + 1] = string.format("stage %d: %d regular + %d Sp", stn, reg, sp)
        end
        n_reg, n_sp = n_reg + reg, n_sp + sp
    end
    local summary = string.format("FIELD: %s | TOTAL %d regular + %d Sp = %d (expect 15-30)",
        table.concat(parts, ", "), n_reg, n_sp, n_reg + n_sp)
    if summary ~= field_last_summary then
        field_last_summary = summary
        l(summary)
    end
end

-- ---------- reward-logic hook metadata ---------------------------------------

-- The SHELL owns the ExQuestRewardSetting hooks (installed once, survives F9)
-- and dispatches every call to M:on_reward / M:on_reward_post.
local DEEP = { judgeRareEmReward = true, judgeRareEmReward_SpOffer = true,
    judgeRareEmReward_MoreSpOffer = true }

function M:on_reward(mn, args)
    -- anchor to the settings object and collect item caps from its reward
    -- tables. The lifecycle methods (.ctor/onLoad/setup/read/initialize) fire
    -- when the tables are populated; keep retrying via ANY hooked method until
    -- we actually got caps, so legality checks are never vacuous.
    if not caps_ready then
        local okT, self = pcall(function() return sdk.to_managed_object(args and args[2]) end)
        if not (okT and self) then self = args and args[2] end   -- already managed (F9 reuse)
        if self and get_f(self, "_RewardSlotTblByRank") then
            if anchored == nil then
                anchored = self
                -- survives F9 so field_scan can reload caps without a fresh roll
                _G.LMRI_ANCHOR = self
                l("ROLLCHECK anchored via " .. mn)
            end
            local before = countt(item_cap)
            local found = collect_item_caps(self)
            local after = countt(item_cap)
            if after > 0 then
                caps_ready = true
                if after > before then
                    l(string.format("ROLLCHECK caps loaded: %d distinct item cap(s) (%d entries; hard-caps=%d)",
                        after, found, countt(HARD_CAP_1)))
                end
                -- confirm the live reader against the vanilla snapshot once
                if not ground_diff_done then
                    ground_diff_done = true
                    ground_diff()
                end
            elseif found > 0 or before > 0 then
                l(string.format("ROLLCHECK caps: %d found this call, %d total - waiting for full tables",
                    found, after))
            end
        end
    end
    -- shells older than the post-hook dispatch: best effort pre-call read
    if not _G.LMRI_SHELL_POST and DEEP[mn] then scan_roll_args(args, mn) end
end

-- Post-hook: the judge methods fill/adjust the reward list in place, so the
-- final rolled rewards are only readable after the call returns.
function M:on_reward_post(mn, args)
    if DEEP[mn] then scan_roll_args(args, mn) end
end

function M:report()
    build_fixed_map()
    l("######## REGIONS: live rolls captured this session")
    if #captured_rolls == 0 then
        l("REGIONS: none yet - open/regenerate a region board to generate some")
    else
        local fails = 0
        for _, rec in ipairs(captured_rolls) do
            local verdict = (#rec.issues == 0) and "LEGAL" or ("ILLEGAL")
            l(string.format("REGION ROLL %s (%s) %s : %s",
                tostring(rec.id),
                rec.sources and rec.sources[1] or "?",
                rec.name or "?",
                verdict))
            if rec.desc and #rec.desc > 0 then
                l("    rewards: " .. table.concat(rec.desc, ", "))
            end
            if #rec.issues > 0 then
                l("    violations: " .. table.concat(rec.issues, "; "))
                fails = fails + 1
            end
        end
        l(string.format("REGIONS: %d roll(s), %d with violation(s)", #captured_rolls, fails))
    end
    l("######## REGIONS END")
end

function M:verified_all()
    verify_all()
end

function M:settings()
    build_fixed_map()
    l("######## LEGAL SETTINGS")
    local s_err = anchored and check_settings(anchored) or -1
    if anchored then
        if s_err == 0 then l("SETTINGS: tables OK") end
        if s_err > 0 then l("SETTINGS violations: " .. table.concat(sett_errors, "; ")) end
    else
        l("SETTINGS: not captured yet - trigger reward logic once (open a board)")
    end
    -- item caps summary (readable legality reference)
    l(string.format("CAPS: %d item(s) capped across %d source table(s) (hard-caps: %d)",
        countt(item_cap), countt(cap_by_src), countt(HARD_CAP_1)))
    local cap_names = {}
    for item, cap in pairs(item_cap) do
        cap_names[#cap_names + 1] = string.format("%s=%d [%s]",
            tostring(item_name_of(item) or ("item " .. tostring(item))),
            cap, tostring(cap_provenance(item) or "?"))
    end
    table.sort(cap_names)
    for _, line in ipairs(cap_names) do l("  " .. line) end
    -- per-source / per-rank summary
    l("PER-SOURCE CAPS:")
    local src_names = {}
    for src in pairs(cap_by_src) do src_names[#src_names + 1] = src end
    table.sort(src_names)
    for _, src in ipairs(src_names) do
        local ents = 0
        local ranks = {}
        for rk, items in pairs(cap_by_src[src]) do ranks[#ranks + 1] = rk; for _ in pairs(items) do ents = ents + 1 end end
        l(string.format("  %s: %s (%d entries)", src, table.concat(ranks, ", "), ents))
    end
    l("######## LEGAL SETTINGS END")
end

function M:grounding()
    ground_diff()
end

function M:baseline()
    baseline_ready = false
    baseline_dates = {}
    baseline_sigs = {}
    snapshot_baseline()
end

-- =============================================================================
-- HANDLERS (called by the shell)
-- =============================================================================

local QUEST_CHECK_EVERY = 2.0   -- seconds; check_quests walks the whole quest array
local last_quest_check = -1e9

function M:on_frame()
    if not save_loaded() then
        -- back at title / save unloaded: forget the baseline so the next save
        -- (possibly a different one) is baselined fresh
        if baseline_ready then
            baseline_ready = false
            baseline_dates = {}
            baseline_sigs = {}
        end
        return
    end
    -- pre-existing saved investigations are baselined once and excluded from
    -- verdicts (they may be user-modified); F5 lists them
    if not baseline_ready then snapshot_baseline() end
    local now = os.clock()
    if now - last_quest_check >= QUEST_CHECK_EVERY then
        last_quest_check = now
        check_quests(false)
    end
    field_scan()
    flush_pending_rolls()
end

-- F11: live board-container probe (data/LMRI_SpOfferProbe.lua): Sp offers per
-- stage (getSpOfferInfoList) and regular pop-enemy investigations
-- (findExecutedPopEmsInMyExField) - the same containers field_scan reads.
function M:instant()
    local name = "LMRI_SpOfferProbe.lua"
    local ok, f = pcall(io.open, name, "r")
    if not ok or not f then
        l("PROBE: " .. name .. " not found in reframework/data")
        return
    end
    local text = f:read("*a")
    f:close()
    local chunk, cerr = load(text, name)
    if not chunk then
        l("PROBE: " .. name .. " compile error: " .. tostring(cerr))
        return
    end
    local okRun, err = pcall(chunk)
    if not okRun then l("PROBE: " .. name .. " run error: " .. tostring(err)) end
    l("PROBE: done (F11 again to re-probe)")
end

function M:on_save(keep_arg)
    if keep_arg == nil then return end
    local okS, s = pcall(function() return keep_sig(keep_arg) end)
    if okS and s and not keep_sigh[s] then
        keep_sigh[s] = true
        local okV, res = pcall(function() return validate_keep(keep_arg) end)
        if okV and res and #res > 0 then
            l("LIVE INSTANT(SAVE) ILLEGAL " .. quest_label(keep_arg) .. " : " .. join(res))
        end
    end
end

function M:on_convert(obj)
    if not obj then return end
    local okS, s = pcall(function() return keep_sig(obj) end)
    if okS and s and not keep_sigh[s] then
        keep_sigh[s] = true
        local okV, res = pcall(function() return validate_keep(obj) end)
        if okV and res and #res > 0 then
            l("LIVE INSTANT(CONVERT) ILLEGAL " .. quest_label(obj) .. " : " .. join(res))
        end
    end
end

return M