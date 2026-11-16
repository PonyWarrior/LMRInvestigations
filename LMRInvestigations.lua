-- =============================================================================
-- LMRInvestigations.lua - REFramework conversion of the "LMRInvestigations" mod
-- =============================================================================
-- Converts the ExQuestRewardSetting.user.3 patch to a runtime Lua mod.
--
-- Rule (as clarified): "force the theoretical maximum of vanilla rewards".
-- Each entry is raised to the largest vanilla value of its group, so quests
-- always roll the best possible slot and item counts:
--   * slot tables  (_RewardSlotTblByRank incl. Sp wrappers): _LotNum -> max per
--     grade across those tables (the legality suite confirms this is vanilla-legal)
--   * frenzy slots (_RewardSlotTbl_Frenzy): _LotNum -> its own max, capped at 3
--   * reward data  (_SkillGem/_Artian/_Amulet + ByEm variants): _Num -> max per
--     (array, rank, item) - each array its own max, never borrowed across tables
--   * EM reward    (_EmRewardTblByRank / _EmRewardTblByEm): _SlotNum -> max per rank
-- Only ever raises values (never lowers). Saved investigations are not touched.
--
-- Install: reframework\autorun\  (REFramework only - no file patched on disk).
-- NOTE: on_frame is unreliable in this build; driven by
-- re.on_pre_application_entry("BeginRendering") and reward-logic method hooks.
-- =============================================================================

local sdk, log, json = sdk, log, json

local default_config = {
    enabled = true,
    patch_slots = true,
    patch_counts = true,
    log_details = false,
    -- Capture the pre-patch reward tables (before any mutation) for the LMRI
    -- legality suite, which judges against VANILLA caps, never the modded
    -- tables. REQUIRED (true) while running the suite: without it the suite
    -- refuses to check. Players not running the suite can leave it false.
    snapshot_vanilla = false,
}
local function deepcopy(t)
    local r = {}
    for k, v in pairs(t) do
        r[k] = type(v) == "table" and deepcopy(v) or v
    end
    return r
end

local function deep_merge(base, over)
    for k, v in pairs(over) do
        if type(v) == "table" and type(base[k]) == "table" then
            deep_merge(base[k], v)
        else
            base[k] = v
        end
    end
    return base
end

local config
local cfgfile = "LMRInvestigations.json"
if json ~= nil then
    local f = json.load_file(cfgfile) or {}
    -- drop keys no longer in default_config (e.g. old patch_saved_quests)
    for k in pairs(f) do if default_config[k] == nil then f[k] = nil end end
    config = deep_merge(deepcopy(default_config), f)
    json.dump_file(cfgfile, config)
else
    config = deepcopy(default_config)
end
if config == nil then config = deepcopy(default_config) end

-- fresh log per game session (it used to grow forever)
pcall(function() local f = io.open("LMRInvestigations.log", "w"); if f then f:close() end end)

local function logi(m)
    local msg = "[LMRInvestigations] " .. tostring(m)
    log.info(msg)
    local ok, f = pcall(io.open, "LMRInvestigations.log", "a")
    if ok and f then
        f:write("[" .. tostring(os.clock()) .. "] " .. msg .. "\n")
        f:close()
    end
end

-- ---------- helpers ----------
local function get_f(o, n)
    if o == nil then return nil end
    local ok, v = pcall(function() return o:get_field(n) end)
    if ok then return v end
    return nil
end

-- "rank" may come back as a managed object (read its _Value) or a plain number.
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

local function each_elem(arr, fn)
    if arr == nil then return end
    local okE, els = pcall(function() return arr:get_elements() end)
    if okE and els then
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

local function raise_field(obj, field, want)
    local cur = get_f(obj, field)
    if cur == nil then return false end
    cur = tonumber(cur)
    if cur == nil or cur >= want then return false end
    local ok, err = pcall(function() obj:set_field(field, want) end)
    return ok
end

-- ---------- slot tables: _LotNum -> max per grade, GLOBAL across all slot tables ----------
local slot_global = {}   -- grade -> max lot across every table (filled at first settings anchor)
local slot_global_dirty = true
local em_rank_max = {}   -- rank -> max _SlotNum across all EM tables

local function collect_slot_max(arr)
    if arr == nil then return end
    each_elem(arr, function(s)
        local g = get_f(s, "_Grade")
        local lot = get_f(s, "_LotNum")
        if g ~= nil and lot ~= nil then
            g = tonumber(g); lot = tonumber(lot)
            slot_global[g] = math.max(slot_global[g] or 0, lot)
        end
    end)
end

local function build_slot_global(obj)
    slot_global = {}
    each_elem(get_f(obj, "_RewardSlotTblByRank"), function(row)
        collect_slot_max(get_f(row, "_RewardSlotTbl"))
        each_elem(get_f(row, "_RewardSlotTbl_SpOfferByLowerRank"), function(w)
            collect_slot_max(get_f(w, "_RewardSlotTbl_SpOffer"))
        end)
    end)
    -- Frenzy deliberately excluded (see patch note)
    slot_global_dirty = false
end

-- raise every entry to the GLOBAL max lot for its grade (any table, any path)
local function patch_slot_array_global(arr, where)
    if arr == nil or slot_global_dirty then return 0 end
    local changed = 0
    each_elem(arr, function(s)
        local g = get_f(s, "_Grade")
        if g ~= nil then
            local want = slot_global[tonumber(g)]
            if want ~= nil and raise_field(s, "_LotNum", want) then changed = changed + 1 end
        end
    end)
    if config.log_details and changed > 0 then logi("  slots " .. where .. ": " .. changed .. " raised") end
    return changed
end

-- ---------- reward item counts: _Num -> max per (table, rank, item) ----------
-- Each table array uses ITS OWN max: a global max raised ★4 Glowing Orb to x2
-- (vanilla 1), and pooling tables per rank still lends one table's count to
-- another (Amulet R9 Glowing Stone 1 vs ByEm 2; Artian R8 Ancient Weapon
-- Fragment 2 vs 3). Per-array is vanilla-legal whichever table the game uses.
local function patch_count_arr(arr, where)
    if arr == nil then return 0 end
    local max = {}   -- rank -> item -> max _Num within this array
    each_elem(arr, function(d)
        local it = normalize_key(get_f(d, "_RewardItem"))
        local rk = normalize_key(get_f(d, "_Rank"))
        local num = tonumber(get_f(d, "_Num"))
        if it ~= nil and rk ~= nil and num ~= nil then
            max[rk] = max[rk] or {}
            max[rk][it] = math.max(max[rk][it] or 0, num)
        end
    end)
    local changed = 0
    each_elem(arr, function(d)
        local it = normalize_key(get_f(d, "_RewardItem"))
        local rk = normalize_key(get_f(d, "_Rank"))
        local want = it ~= nil and rk ~= nil and max[rk] and max[rk][it] or nil
        if want and want > 0 and raise_field(d, "_Num", want) then changed = changed + 1 end
    end)
    if config.log_details and changed > 0 then logi("  counts " .. where .. ": " .. changed .. " raised") end
    return changed
end

-- ---------- EM reward: _SlotNum -> GLOBAL max per rank ----------
local function build_em_global(obj)
    em_rank_max = {}   -- reset (assign outer local)
    local function scan(arr)
        if arr == nil then return end
        each_elem(arr, function(d)
            local rk = normalize_key(get_f(d, "_TblRank"))
            local sn = get_f(d, "_SlotNum")
            if rk ~= nil and sn ~= nil then
                em_rank_max[rk] = math.max(em_rank_max[rk] or 0, tonumber(sn))
            end
        end)
    end
    local function scan_pair(arr, f1, f2)
        if arr == nil then return end
        each_elem(arr, function(row)
            scan(get_f(row, f1)); scan(get_f(row, f2))
        end)
    end
    scan_pair(get_f(obj, "_EmRewardTblByRank"), "_EmRewardTbl", "_EmRewardTbl_Yummy")
    scan_pair(get_f(obj, "_EmRewardTblByEm"), "_EmRewardTbl", "_EmRewardTbl_Yummy")
end

local function patch_em_arr(arr, where)
    if arr == nil then return 0 end
    local changed = 0
    each_elem(arr, function(d)
        local rk = normalize_key(get_f(d, "_TblRank"))
        local max = rk ~= nil and em_rank_max[rk] or nil
        if max and max > 0 and raise_field(d, "_SlotNum", max) then changed = changed + 1 end
    end)
    if config.log_details and changed > 0 then logi("  emCounts " .. where .. ": " .. changed .. " raised") end
    return changed
end

-- ---------------------------------------------------------------------------
-- DEBUG-ONLY vanilla snapshot for the LMRI legality script.
-- Reads the SAME reward tables BEFORE any mutation and stores per-source,
-- per-rank, per-item max _Num into _G.LMRI_VANILLA_CAPS so the legality script
-- can judge generated investigations against VANILLA caps rather than the
-- modded tables. Rank keys are the raw _Rank enum hashes (the legality script
-- maps them to REWARD_RANK_xx via its snapshot). No value is ever written.
-- ---------------------------------------------------------------------------
local function snapshot_vanilla_for_legality(obj)
    local snap = {}
    local function scan(arr, src)
        if arr == nil then return end
        each_elem(arr, function(d)
            local it = normalize_key(get_f(d, "_RewardItem"))
            local num = get_f(d, "_Num")
            local rk = normalize_key(get_f(d, "_Rank"))
            if it ~= nil and num ~= nil and rk ~= nil then
                num = tonumber(num)
                if num and num > 0 then
                    if not snap[src] then snap[src] = {} end
                    if not snap[src][rk] then snap[src][rk] = {} end
                    snap[src][rk][it] = math.max(snap[src][rk][it] or 0, num)
                end
            end
        end)
    end
    local function scan_pair(arr, prefix, f1, f2)
        if arr == nil then return end
        local k1, k2 = f1:gsub("^_", ""), f2:gsub("^_", "")
        each_elem(arr, function(row)
            scan(get_f(row, f1), prefix .. "." .. k1)
            scan(get_f(row, f2), prefix .. "." .. k2)
        end)
    end
    scan(get_f(obj, "_SkillGemRewardTbl"), "SkillGemRewardTbl")
    scan(get_f(obj, "_ArtianRewardTbl"), "ArtianRewardTbl")
    scan(get_f(obj, "_AmuletRewardTbl"), "AmuletRewardTbl")
    scan_pair(get_f(obj, "_SkillGemRewardTblByEm"), "SkillGemRewardTblByEm", "_SkillGemRewardTbl", "_SkillGemRewardTbl_SpOffer")
    scan_pair(get_f(obj, "_ArtianRewardTblByEm"), "ArtianRewardTblByEm", "_ArtianRewardTbl", "_ArtianRewardTbl_SpOffer")
    scan_pair(get_f(obj, "_AmuletRewardTblByEm"), "AmuletRewardTblByEm", "_AmuletRewardTbl", "_AmuletRewardTbl_SpOffer")
    return snap
end

-- Monster-specific (ByEm) caps for the legality script, keyed by the row's
-- monster: byem[_EmID fixed value][rank][item] = max _Num (both the normal and
-- the _SpOffer table of that row). The pooled ByEm sources above are kept for
-- grounding; the suite only allows these caps for a roll of that monster.
local function snapshot_vanilla_byem(obj)
    local byem = {}
    local function scan(arr, em)
        each_elem(arr, function(d)
            local it, rk = normalize_key(get_f(d, "_RewardItem")), normalize_key(get_f(d, "_Rank"))
            local num = tonumber(get_f(d, "_Num"))
            if it and rk and num and num > 0 then
                byem[em][rk] = byem[em][rk] or {}
                byem[em][rk][it] = math.max(byem[em][rk][it] or 0, num)
            end
        end)
    end
    for _, p in ipairs({ { "_SkillGemRewardTblByEm", "_SkillGemRewardTbl" },
                         { "_ArtianRewardTblByEm", "_ArtianRewardTbl" },
                         { "_AmuletRewardTblByEm", "_AmuletRewardTbl" } }) do
        each_elem(get_f(obj, p[1]), function(row)
            local em = normalize_key(get_f(row, "_EmID"))
            if em == nil then return end
            byem[em] = byem[em] or {}
            scan(get_f(row, p[2]), em)
            scan(get_f(row, p[2] .. "_SpOffer"), em)
        end)
    end
    return byem
end

-- Slot tables for the legality script (same rules: read-only, pre-patch).
-- Shape (rank keys = raw EM_REWARD_RANK_Fixed hashes):
--   normal[rank][grade] = max _LotNum      sp[rank][lower_rank][grade] = max _LotNum
--   frenzy = max _LotNum                    em[rank][tbl_rank] = max _SlotNum
--   em_items[item] = tbl_rank (_ExjudgeEmRewardArray)
local function snapshot_vanilla_slots(obj)
    local s = { normal = {}, sp = {}, frenzy = nil, em = {}, em_items = {} }
    local function lots(arr, into)
        each_elem(arr, function(d)
            local g, lot = tonumber(get_f(d, "_Grade")), tonumber(get_f(d, "_LotNum"))
            if g and lot then into[g] = math.max(into[g] or 0, lot) end
        end)
    end
    each_elem(get_f(obj, "_RewardSlotTblByRank"), function(row)
        local rk = normalize_key(get_f(row, "_Rank"))
        if rk == nil then return end
        s.normal[rk] = s.normal[rk] or {}
        lots(get_f(row, "_RewardSlotTbl"), s.normal[rk])
        each_elem(get_f(row, "_RewardSlotTbl_SpOfferByLowerRank"), function(w)
            local lr = normalize_key(get_f(w, "_LowerRank"))
            if lr == nil then return end
            s.sp[rk] = s.sp[rk] or {}
            s.sp[rk][lr] = s.sp[rk][lr] or {}
            lots(get_f(w, "_RewardSlotTbl_SpOffer"), s.sp[rk][lr])
        end)
    end)
    each_elem(get_f(obj, "_RewardSlotTbl_Frenzy"), function(d)
        local lot = tonumber(get_f(d, "_LotNum"))
        if lot then s.frenzy = math.max(s.frenzy or 0, lot) end
    end)
    each_elem(get_f(obj, "_EmRewardTblByRank"), function(row)
        local rk = normalize_key(get_f(row, "_Rank"))
        if rk == nil then return end
        s.em[rk] = s.em[rk] or {}
        each_elem(get_f(row, "_EmRewardTbl"), function(d)
            local tr, sn = normalize_key(get_f(d, "_TblRank")), tonumber(get_f(d, "_SlotNum"))
            if tr and sn then s.em[rk][tr] = math.max(s.em[rk][tr] or 0, sn) end
        end)
    end)
    each_elem(get_f(obj, "_ExjudgeEmRewardArray"), function(d)
        local it, tr = normalize_key(get_f(d, "_ItemID")), normalize_key(get_f(d, "_TblRank"))
        if it and tr then s.em_items[it] = tr end
    end)
    return s
end

-- take the snapshot once, on the first fully-populated settings object, BEFORE
-- patch_settings() mutates it. Only a non-empty capture is published.
local function snapshot_vanilla_if_not_done(obj)
    if _G.LMRI_VANILLA_CAPS ~= nil then return end
    if not config.snapshot_vanilla then return end
    local okS, slots = pcall(snapshot_vanilla_slots, obj)
    if okS and slots and next(slots.normal) then
        _G.LMRI_VANILLA_SLOTS = slots
    else
        logi("[debug] vanilla slot snapshot failed: " .. tostring(slots))
    end
    local ok, snap = pcall(function() return snapshot_vanilla_for_legality(obj) end)
    if not ok or not snap then return end
    local n = 0
    for src, t1 in pairs(snap) do
        for rk, t2 in pairs(t1) do
            for it in pairs(t2) do n = n + 1 end
        end
    end
    if n == 0 then return end
    local okB, byem = pcall(snapshot_vanilla_byem, obj)
    _G.LMRI_VANILLA_CAPS_BYEM = okB and byem or nil
    if not okB then logi("[debug] vanilla ByEm snapshot failed: " .. tostring(byem)) end
    _G.LMRI_VANILLA_CAPS = snap
    local table_count = 0
    for _ in pairs(snap) do table_count = table_count + 1 end
    logi("[debug] vanilla snapshot captured for legality: " .. n .. " item caps across " .. table_count .. " tables")
end

-- Frenzy: raise to the frenzy table's own max, capped at the vanilla-legal limit (3).
local FRENZY_LEGAL_CAP = 3
local function patch_frenzy(arr)
    if arr == nil then return 0 end
    local m = 0
    local entries = {}
    each_elem(arr, function(s)
        local lot = get_f(s, "_LotNum")
        if lot ~= nil then
            lot = tonumber(lot)
            m = math.max(m, lot)
            entries[#entries + 1] = s
        end
    end)
    m = math.min(m, FRENZY_LEGAL_CAP)
    local c = 0
    for _, s in ipairs(entries) do
        if raise_field(s, "_LotNum", m) then c = c + 1 end
    end
    if config.log_details and c > 0 then logi("  Frenzy: " .. c .. " -> lot " .. m) end
    return c
end

-- ---------- apply to the settings object ----------
local function patch_settings(obj)
    local total = 0
    build_slot_global(obj)
    build_em_global(obj)

    if config.patch_slots then
        each_elem(get_f(obj, "_RewardSlotTblByRank"), function(row, bi)
            total = total + patch_slot_array_global(get_f(row, "_RewardSlotTbl"), "ByRank[" .. bi .. "].slot")
            each_elem(get_f(row, "_RewardSlotTbl_SpOfferByLowerRank"), function(wrp, wi)
                total = total + patch_slot_array_global(get_f(wrp, "_RewardSlotTbl_SpOffer"),
                                                        "ByRank[" .. bi .. "].spoffer[" .. wi .. "]")
            end)
        end)
        total = total + patch_frenzy(get_f(obj, "_RewardSlotTbl_Frenzy"))
    end

    if config.patch_counts then
        total = total + patch_count_arr(get_f(obj, "_SkillGemRewardTbl"), "SkillGem")
        total = total + patch_count_arr(get_f(obj, "_ArtianRewardTbl"), "Artian")
        total = total + patch_count_arr(get_f(obj, "_AmuletRewardTbl"), "Amulet")
        local function byem(arr, f1, f2)
            if arr == nil then return 0 end
            local n = 0
            each_elem(arr, function(row)
                n = n + patch_count_arr(get_f(row, f1), f1)
                n = n + patch_count_arr(get_f(row, f2), f2)
            end)
            return n
        end
        total = total + byem(get_f(obj, "_SkillGemRewardTblByEm"), "_SkillGemRewardTbl", "_SkillGemRewardTbl_SpOffer")
        total = total + byem(get_f(obj, "_ArtianRewardTblByEm"), "_ArtianRewardTbl", "_ArtianRewardTbl_SpOffer")
        total = total + byem(get_f(obj, "_AmuletRewardTblByEm"), "_AmuletRewardTbl", "_AmuletRewardTbl_SpOffer")
        local function emarr(arr, f1, f2)
            if arr == nil then return 0 end
            local n = 0
            each_elem(arr, function(row)
                n = n + patch_em_arr(get_f(row, f1), f1)
                n = n + patch_em_arr(get_f(row, f2), f2)
            end)
            return n
        end
        total = total + emarr(get_f(obj, "_EmRewardTblByRank"), "_EmRewardTbl", "_EmRewardTbl_Yummy")
        total = total + emarr(get_f(obj, "_EmRewardTblByEm"), "_EmRewardTbl", "_EmRewardTbl_Yummy")
    end
    return total
end

local patched = {}
local anchored = nil
local session_total = 0

local function apply(obj, via)
    if obj == nil or not config.enabled then return end
    if anchored == nil then anchored = obj end
    -- DEBUG: snapshot the vanilla tables BEFORE any mutation, so the legality
    -- script can judge against vanilla caps (never the modded tables).
    snapshot_vanilla_if_not_done(obj)
    local a = obj:get_address()
    if patched[a] then return end
    local ok, res = pcall(function() return patch_settings(obj) end)
    if not ok then
        logi("apply error: " .. tostring(res))
        return
    end
    local n = res or 0
    -- mark patched even at 0 changes, else retick re-applies (and logs) every frame
    patched[a] = true
    session_total = session_total + n
    logi(string.format("patched settings %s : updated %d fields (session=%d)",
        tostring(a), n, session_total))
end

local HOOKS = {".ctor", "onLoad", "setup", "read", "initialize",
    "judgeYummyReward", "judgeYummyReward_SpOffer", "judgeRareEmReward", "judgeRareEmReward_SpOffer",
    "judgeRareEmReward_MoreSpOffer", "getRewardTypeFromItemID", "get_WorthNotifyRareLv",
    "isWorthNotifyRareLv", "get_RewardPointBorder", "getRecommendEmSortParam",
    "tryGetSwarmSpOfferRewardByEm", "isLegendaryForExRewardType", "isNeedJudgeEmReward"}

local installed = false
local function ensure_hooks()
    if installed then return true end
    local td = sdk.find_type_definition("app.user_data.ExQuestRewardSetting")
    if td == nil then return false end
    local ok = pcall(function()
        for _, mn in ipairs(HOOKS) do
            local m = td:get_method(mn)
            if m ~= nil then
                sdk.hook(m, function(args)
                    -- an error here would propagate into the game's own call
                    pcall(function() apply(sdk.to_managed_object(args[2]), mn) end)
                end, function(r) return r end)
            end
        end
    end)
    if ok then
        installed = true
        logi("hooks installed (" .. #HOOKS .. " methods)")
    end
    return ok
end

pcall(ensure_hooks)
local f8_was_down = false
re.on_pre_application_entry("BeginRendering", function()
    pcall(function()
        if not installed then ensure_hooks() end
        -- manual status/reapply key: F8 (edge-triggered: once per press)
        local f8 = reframework:is_key_down(0x77)
        local f8_pressed = f8 and not f8_was_down
        f8_was_down = f8
        if f8_pressed then
            if anchored ~= nil then
                patched[anchored:get_address()] = nil
                logi("F8: manual reapply on " .. tostring(anchored:get_address()))
                apply(anchored, "F8")
            else
                logi("F8: not anchored yet - regenerate investigations / use the Field Survey board")
            end
        end
        -- re-apply to the anchored object if it got re-created
        if anchored ~= nil and config.enabled then
            local a = anchored:get_address()
            if not patched[a] then apply(anchored, "retick") end
        end
    end)
end)

re.on_config_save(function()
    if json then json.dump_file(cfgfile, config) end
end)

logi("loaded (max normalization: slots per grade, counts per (array,rank,item), EM per rank, frenzy <= 3)")