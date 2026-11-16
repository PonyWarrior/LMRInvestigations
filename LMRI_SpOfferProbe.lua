-- =============================================================================
-- LMRI_SpOfferProbe.lua - find where GENERATED (board) investigations live.
-- =============================================================================
-- Two types of generated investigations exist:
--
--   A) "Sp" offers (cExSpOfferInfo_forView): 2 monsters, up to 10 reward slots.
--      Not always available in a region; generally 1-2 when they appear.
--      EnvironmentManager.getSpOfferInfoList(stage) -> cExSpOfferInfo_forView[]
--
--   C) Regular investigations (cExBattlefieldInfo_forView): 1 monster, up to 5
--      reward slots. Always exist in all regions (except Wounded Hollow which
--      can have 1 or 0).
--      EnvironmentManager.getBattlefieldInfoList(stage)
--        -> List<cExBattlefieldInfo_forView>, each .KeepQuestData is a
--           cKeepQuestData that converts to cQuestParam for describe_quest.
--
-- NOTE: cUserSaveParam._InstantQuestHistory is the WRONG container - it lists
-- the history of investigations the player completed but did not save, NOT
-- newly generated ones.
--
-- Globally there are always 15-30 generated investigations at any time. Any
-- enumeration showing fewer is incomplete. This probe dumps A + C across ALL
-- stages and the global total so we can verify coverage.
-- =============================================================================
local sdk, log = sdk, log

local function wlog(msg)
    local txt = tostring(msg)
    local ok, f = pcall(io.open, "LMRI_Legality.log", "a")
    if ok and f then f:write(txt .. "\n"); f:close() end
    log.info(txt)
end

local function fmt(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "userdata" then
        local ok, a = pcall(function() return sdk.to_managed_object(v):get_address() end)
        if ok then return string.format("0x%x", a) end
        return "ud"
    end
    return tostring(v)
end

local function get_num(obj, ...)
    for _, name in ipairs({...}) do
        local ok, v = pcall(function() return obj:get_field(name) end)
        if ok and v ~= nil then
            local n = tonumber(v)
            if n ~= nil then return n end
        end
    end
    return nil
end

-- enumerate a managed array/list and return elements (raw - do NOT force
-- to_managed_object: enum arrays (e.g. STAGE[]) return plain numbers and would
-- throw "1 is not a managed object")
local function enum_arr(mo)
    local els = {}
    if not mo then return els end
    local okC, c = pcall(function() return mo:call("get_Count") end)
    if okC and c and c > 0 then
        for i = 0, c - 1 do
            local okE, e = pcall(function() return mo:call("get_Item", i) end)
            if okE and e ~= nil then els[#els + 1] = e end
        end
        return els
    end
    local okA, arr = pcall(function() return sdk.to_managed_object(mo):get_elements() end)
    if okA and arr then
        for _, e in ipairs(arr) do els[#els + 1] = e end
    end
    return els
end

-- numeric value of a stage element (number or enum userdata)
local function stage_num(s)
    local n = tonumber(s)
    if n ~= nil then return n end
    if type(s) == "userdata" then
        local ok, v = pcall(function() return s:get_field("_Value") end)
        if ok then return tonumber(v) end
    end
    return nil
end

local EM = nil
local function env_mgr()
    if EM then return EM end
    EM = sdk.get_managed_singleton("app.EnvironmentManager")
    if not EM then
        local td = sdk.find_type_definition("app.EnvironmentManager")
        if td then
            local m = td:get_method("get_Instance")
            if m then pcall(function() EM = sdk.to_managed_object(m:call(nil)) end) end
        end
    end
    return EM
end

-- all stages the game knows about (as plain numbers - the STAGE methods accept
-- a numeric enum value, proven by _CurrentStage=3 working in the first probe)
local stage_list = nil
local function all_stages()
    if stage_list then return stage_list end
    stage_list = {}
    local em = env_mgr()
    if em then
        local mS = em:get_type_definition():get_method("getExStageArray")
        if mS then
            local okS, sv = pcall(function() return mS:call(em) end)
            if okS and sv then
                local arr = enum_arr(sdk.to_managed_object(sv))
                local seen = {}
                for _, s in ipairs(arr) do
                    local n = stage_num(s)
                    if n ~= nil and not seen[n] then seen[n] = true end
                end
                for k in pairs(seen) do stage_list[#stage_list + 1] = k end
            end
        end
    end
    if #stage_list == 0 then
        for s = 0, 15 do stage_list[#stage_list + 1] = s end
    end
    table.sort(stage_list)
    return stage_list
end

-- dump one cExSpOfferInfo_forView (Sp: 2 monsters, up to 10 rewards)
local function dump_offer(off, i)
    local ra = nil
    pcall(function() ra = sdk.to_managed_object(off:call("get_RewardArray")) end)
    local rows = ra and enum_arr(ra) or {}
    local rank = get_num(off, "QuestRank", "_QuestRank") or "?"
    local kq = get_num(off, "KeepQuestIndex", "_KeepQuestIndex") or "?"
    local isk = get_num(off, "IsKept", "_IsKept") or "?"
    local sui = get_num(off, "SpOfferUniqueIdx", "_SpOfferUniqueIdx") or "?"
    local stage = get_num(off, "Stage", "_Stage") or "?"
    local tgt = 0
    local ta = nil
    pcall(function() ta = sdk.to_managed_object(off:call("get_TargetEmArray")) end)
    if ta then tgt = #enum_arr(ta) end
    wlog(string.format("SPOFFER[%d] rank=%s KeepQuestIdx=%s IsKept=%s UniqueIdx=%s Stage=%s targets=%s rewardRows=%d",
        i, tostring(rank), tostring(kq), tostring(isk), tostring(sui), tostring(stage), tostring(tgt), #rows))
    for n, e in ipairs(rows) do
        local fixed = get_num(e, "ItemIdFixed", "_ItemIdFixed")
        local num = get_num(e, "Num", "_Num")
        wlog(string.format("    reward[%d] ItemIdFixed=%s Num=%s", n, tostring(fixed), tostring(num)))
    end
end

-- Path A: Sp offers across ALL stages
local function probe_path_a()
    wlog("=== PATH A: Sp offers (getSpOfferInfoList) x ALL stages ===")
    local em = env_mgr()
    if not em then wlog("  EnvironmentManager not reachable"); return 0 end
    local stage = nil
    pcall(function() stage = em:get_field("_CurrentStage") end)
    wlog("  _CurrentStage=" .. fmt(stage))
    local m = em:get_type_definition():get_method("getSpOfferInfoList")
    if not m then wlog("  no getSpOfferInfoList"); return 0 end
    local sl = all_stages()
    local parts = {}
    for _, s in ipairs(sl) do parts[#parts + 1] = tostring(s) end
    wlog("  stages: " .. table.concat(parts, ","))
    local total = 0
    for _, st in ipairs(sl) do
        local ok, v = pcall(function() return m:call(em, st) end)
        if ok and v ~= nil then
            local mo = nil
            pcall(function() mo = sdk.to_managed_object(v) end)
            local offs = mo and enum_arr(mo) or {}
            if #offs > 0 then wlog(string.format("  stage %d -> %d Sp offer(s)", st, #offs)) end
            for i, off in ipairs(offs) do pcall(dump_offer, off, total + i - 1) end
            total = total + #offs
        end
    end
    wlog("  TOTAL Sp offers (all stages) = " .. total)
    return total
end

-- dump one cExBattlefieldInfo_forView (regular: 1 monster, up to 5 rewards)
local function dump_bf(bf, i, qu)
    local kqo = nil
    pcall(function() kqo = sdk.to_managed_object(bf:call("get_KeepQuestData")) end)
    local isk = get_num(bf, "IsKept", "_IsKept") or "?"
    local kqi = get_num(bf, "KeepQuestIndex", "_KeepQuestIndex") or "?"
    local stage = get_num(bf, "BelongingStage", "_BelongingStage") or "?"
    if not kqo then
        wlog(string.format("BF[%d] IsKept=%s KeepQuestIdx=%s Stage=%s (no KeepQuestData)",
            i, tostring(isk), tostring(kqi), tostring(stage)))
        return
    end
    local cm = qu and qu:get_method("convertKeepQuest2SaveData")
    local okC, cq = false, nil
    if cm then okC, cq = pcall(function() return cm:call(nil, kqo) end) end
    local lv = "?"
    local ec = "?"
    local rcount = 0
    if okC and cq then
        local cqo = nil
        pcall(function() cqo = sdk.to_managed_object(cq) end)
        if cqo then
            lv = get_num(cqo, "QuestLv", "_QuestLv") or "?"
            local ex = cqo:get_field("_ExField")
            if ex then ec = get_num(ex, "EventCount", "_EventCount") or "?" end
            -- rewards via keep quest (same as describe_quest)
            local cm2 = qu:get_method("convertSaveData2KeepQuest")
            if cm2 then
                local ok2, k2 = pcall(function() return cm2:call(nil, cqo) end)
                if ok2 and k2 then
                    local ko = nil
                    pcall(function() ko = sdk.to_managed_object(k2) end)
                    if ko then
                        for _, mn in ipairs({"getSpOfferRewardList", "getExEmRewardList"}) do
                            pcall(function()
                                local rl = ko:call(mn)
                                if rl then rcount = rcount + #enum_arr(sdk.to_managed_object(rl)) end
                            end)
                        end
                    end
                end
            end
        end
    end
    wlog(string.format("BF[%d] IsKept=%s KeepQuestIdx=%s Stage=%s lv=%s EventCount=%s keepRewardRows=%d",
        i, tostring(isk), tostring(kqi), tostring(stage), tostring(lv), tostring(ec), rcount))
end

-- Path C: regular investigations (battlefield info) across ALL stages
local function probe_path_c()
    wlog("=== PATH C: regular investigations (getBattlefieldInfoList) x ALL stages ===")
    local em = env_mgr()
    if not em then wlog("  EnvironmentManager not reachable"); return 0 end
    local m = em:get_type_definition():get_method("getBattlefieldInfoList")
    if not m then wlog("  no getBattlefieldInfoList"); return 0 end
    local qu = sdk.find_type_definition("app.QuestUtil")
    if not qu then wlog("  no QuestUtil"); return 0 end
    local sl = all_stages()
    local total = 0
    for _, st in ipairs(sl) do
        local ok, v = pcall(function() return m:call(em, st) end)
        if ok and v ~= nil then
            local mo = nil
            pcall(function() mo = sdk.to_managed_object(v) end)
            local bfs = mo and enum_arr(mo) or {}
            if #bfs > 0 then wlog(string.format("  stage %d -> %d regular investigation(s)", st, #bfs)) end
            for i, bf in ipairs(bfs) do pcall(dump_bf, bf, total + i - 1, qu) end
            total = total + #bfs
        end
    end
    wlog("  TOTAL regular investigations (all stages) = " .. total)
    return total
end

-- Path D: regular investigations = executed field PopEnemy events
-- (EnvironmentManager.findExecutedPopEms(bool, bool) -> List<cExFieldEvent_PopEnemy>)
local function call0(o, name, a1)
    local ok, v
    if a1 == nil then ok, v = pcall(function() return o:call(name) end)
    else ok, v = pcall(function() return o:call(name, a1) end) end
    if ok then return v end
    return nil
end

local function probe_path_d()
    wlog("=== PATH D: field monsters (findExecutedPopEms) ===")
    local em = env_mgr()
    if not em then wlog("  EnvironmentManager not reachable"); return 0, 0 end
    local m = em:get_type_definition():get_method("findExecutedPopEms")
    if not m then wlog("  no findExecutedPopEms"); return 0, 0 end
    local ok, v = pcall(function() return m:call(em, false, false) end)
    if not ok or v == nil then wlog("  call failed: " .. tostring(v)); return 0, 0 end
    local mo = nil
    pcall(function() mo = sdk.to_managed_object(v) end)
    local pes = mo and enum_arr(mo) or {}
    local with_reward = 0
    for i, pe in ipairs(pes) do
        local p = nil
        pcall(function() p = sdk.to_managed_object(pe) end)
        if p then
            local emid = call0(p, "get_EmID")
            local nm = "?"
            pcall(function()
                nm = tostring(sdk.find_type_definition("app.EnemyDef"):get_method("NameString"):call(nil, emid, 0, 0))
            end)
            local rows, n = {}, 0
            local info = call0(p, "getRewardData_EnemyInfo", false)
            if info then
                local io_ = nil
                pcall(function() io_ = sdk.to_managed_object(info) end)
                local rl = io_ and call0(io_, "get_RewardList") or nil
                if io_ and not rl then pcall(function() rl = io_:get_field("_RewardList") end) end
                local rlo = nil
                pcall(function() rlo = sdk.to_managed_object(rl) end)
                local c = rlo and tonumber(call0(rlo, "get_Count")) or 0
                for k = 0, c - 1 do
                    rows[#rows + 1] = string.format("%s x%s",
                        tostring(call0(io_, "getItemID", k)), tostring(call0(io_, "getItemNum", k)))
                end
                n = c
            end
            if n > 0 then with_reward = with_reward + 1 end
            wlog(string.format("  PE[%d] em=%s %s stage=%s rank=%s grade=%s keepOK=%s instOK=%s keepIdx=%s bf=%s legend=%s rewards(%d): %s",
                i - 1, tostring(emid), nm, tostring(call0(p, "get_StageNo")), tostring(call0(p, "get_Rank")),
                tostring(call0(p, "get_Grade")), tostring(call0(p, "get_EnableKeepQuestTarget")),
                tostring(call0(p, "get_EnableInstantQuestTarget")), tostring(call0(p, "get_KeepQuestIndex")),
                tostring(call0(p, "get_IsBattlefieldEm")), tostring(call0(p, "get_IsLegendary")),
                n, table.concat(rows, ", ")))
        end
    end
    wlog(string.format("  TOTAL field monsters=%d, with rewards=%d", #pes, with_reward))
    -- scope check: does any variant reach other regions' monsters?
    for _, bb in ipairs({ { true, false }, { false, true }, { true, true } }) do
        local okV, vv = pcall(function() return m:call(em, bb[1], bb[2]) end)
        local n = "err"
        if okV and vv ~= nil then
            pcall(function() n = #enum_arr(sdk.to_managed_object(vv)) end)
        end
        wlog(string.format("  findExecutedPopEms(%s,%s) -> %s", tostring(bb[1]), tostring(bb[2]), tostring(n)))
    end
    local mf = em:get_type_definition():get_method("findExecutedPopEmsInMyExField")
    if mf then
        for _, st in ipairs(all_stages()) do
            for _, b in ipairs({ false, true }) do
                local okV, vv = pcall(function() return mf:call(em, st, b) end)
                local n = "err"
                if okV and vv ~= nil then
                    pcall(function() n = #enum_arr(sdk.to_managed_object(vv)) end)
                end
                wlog(string.format("  findExecutedPopEmsInMyExField(stage %s,%s) -> %s", tostring(st), tostring(b), tostring(n)))
            end
        end
    end
    return #pes, with_reward
end

local function run()
    wlog("######## SPOFFER PROBE ########")
    local a = probe_path_a()
    local c = probe_path_c()
    local d, dr = probe_path_d()
    wlog(string.format("GLOBAL TOTAL: Sp offers=%d + regular(PathC)=%d + field(PathD, with rewards)=%d = %d  (expect 15-30)",
        a, c, dr, a + c + dr))
    wlog("######## SPOFFER PROBE END ########")
end

run()
