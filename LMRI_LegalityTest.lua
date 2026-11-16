-- =============================================================================
-- LMRI_LegalityTest.lua - STABLE SHELL (loads LMRI_Logic.lua as its engine)
-- =============================================================================
-- This script is the autorun entry point. It registers hooks and the frame loop
-- EXACTLY ONCE (on the first BeginRendering frame, when game types exist). The
-- actual test logic lives in reframework/data/LMRI_Logic.lua which this shell
-- (re)loads on demand:
--
--   * First frame: loads LMRI_Logic.lua (module = table of handlers).
--   * F9: reloads LMRI_Logic.lua from disk, swapping ALL logic in place.
--         Edit LMRI_Logic.lua, press F9: new behavior is live immediately.
--   * F2/F3: report captured generated investigations.
--   * F4: re-baseline saved investigations (forget them, watch for new).
--   * F5: settings sanity + full sweep of saved investigations.
--   * F6: grounding (live reader + slot snapshot vs extracted vanilla data).
--   * F11: live board-container probe (data/LMRI_SpOfferProbe.lua).
--
-- Hooks (QuestUtil save/convert + ExQuestRewardSetting reward methods) are
-- owned by THIS shell and registered exactly once; the module only supplies
-- the handlers they dispatch to. Reloading the module (F9) is therefore a
-- pure handler swap: no re-hooking, no double capture.
--
-- Because the shell never re-registers hooks/frames, a reload is fully safe and
-- does NOT touch ScriptRunner, does NOT restart the game, and does NOT rebuild
-- the Lua state (so other mods are unaffected). This is the no-freeze, no-
-- restart reload path.
--
-- The REASON the ScriptRunner checkbox/Reset-scripts path is avoided: in
-- REFramework's source every checkbox toggle calls reset_scripts(), which tears
-- down and rebuilds the ENTIRE Lua state for ALL autorun scripts (CatLib,
-- overlay, IE, ...) and reliably freezes the game. Do not use ScriptRunner here.
-- =============================================================================

local sdk, log = sdk, log
local function l(msg)
    local txt = tostring(msg)
    log.info("LEGALITY: " .. txt)
    local ok, f = pcall(io.open, "LMRI_Legality.log", "a")
    if ok and f then
        f:write("[" .. (os.date and os.date("%Y-%m-%d %H:%M:%S") or "?") .. "] " .. txt .. "\n")
        f:close()
    end
end

-- guard: register hooks/frame only once per Lua state
if _G.LMRI_LEGALITY_SHELL then
    l("shell already registered in this state (skip). Reload logic = press F9.")
    return
end
-- fresh log header (used at boot AND on F9 reload so the log always reflects
-- the current logic pass) - defined early so the boot call below can use it
local function fresh_log()
    pcall(function()
        local f0 = io.open("LMRI_Legality.log", "w")
        if f0 then
            f0:write("===== LMRI Legality log - " .. (os.date and os.date("%Y-%m-%d %H:%M:%S") or "?") .. " =====\n")
            f0:close()
        end
    end)
end

_G.LMRI_LEGALITY_SHELL = true

-- fresh log at boot; F9 also clears (both go through fresh_log)
fresh_log()

-- hook into script reset so a ScriptRunner "Reset scripts" gives us a clean state
if re.on_script_reset then
    re.on_script_reset(function()
        _G.LMRI_LEGALITY_SHELL = nil
        _G.LMRI_LOGIC = nil
    end)
end

-- ============================================================================
-- LOGIC MODULE (LMRI_Logic.lua) loading
-- NOTE: REFramework redirects io.open (and only io.open) into the sandboxed
-- "data" directory (reframework/data). Plain loadfile is NOT redirected, so we
-- read the module through io.open and compile it with load() - this resolves to
-- reframework/data/LMRI_Logic.lua exactly like our log files.
-- ============================================================================
_G.LMRI_LOGIC = _G.LMRI_LOGIC or nil

local function load_logic()
    local f, err = io.open("LMRI_Logic.lua", "r")
    if f == nil then
        l("logic file open error: " .. tostring(err))
        return false
    end
    local text = f:read("*a")
    f:close()
    if text == nil or #text == 0 then
        l("logic file empty")
        return false
    end
    local chunk, cerr = load(text, "LMRI_Logic.lua")
    if chunk == nil then
        l("logic compile error: " .. tostring(cerr))
        return false
    end
    local ok2, mod = pcall(chunk)
    if not ok2 or type(mod) ~= "table" then
        l("logic exec error: " .. tostring(mod))
        return false
    end
    _G.LMRI_LOGIC = mod
    l("logic module loaded - " .. os.date("%Y-%m-%d %H:%M:%S"))
    -- NOTE: hooks are owned by this shell and registered EXACTLY ONCE in
    -- register_hooks(); a module reload only swaps the handlers they dispatch
    -- to (M:on_reward, M:on_save, ...). This is what makes F9 hot-reload safe:
    -- no re-hooking, no double capture, no frozen game.
    return true
end

-- forward a hook event to the current logic module (pcall-guarded, but errors
-- are logged so a silently-broken handler is visible)
local function dispatch(handler, a, b, c)
    local M = _G.LMRI_LOGIC
    if M and type(M[handler]) == "function" then
        local ok, err = pcall(M[handler], M, a, b, c)
        if not ok then
            l("error in handler " .. handler .. ": " .. tostring(err))
        end
    end
end

-- ============================================================================
-- Registration (done once on the first frame, after game types are ready)
-- ============================================================================
local registered = false
_G.LMRI_SHELL_POST = true   -- tells the logic module roll capture is post-hook
local function register_hooks()
    if registered then return end

    local quest_util_td = sdk.find_type_definition("app.QuestUtil")

    local m_save = quest_util_td and quest_util_td:get_method("saveInstantQuest(app.cKeepQuestData)")
    if m_save ~= nil then
        sdk.hook(m_save, function(args)
            thread.get_hook_storage()["keep"] = args[2]
        end, function(r)
            local keep = thread.get_hook_storage()["keep"]
            local obj = nil
            if keep ~= nil then
                local ok2, o = pcall(function() return sdk.to_managed_object(keep) end)
                obj = ok2 and o or nil
            end
            if obj ~= nil then dispatch("on_save", obj) end
            return r
        end)
        l("hooked QuestUtil.saveInstantQuest")
    end

    local m_conv = quest_util_td and quest_util_td:get_method("convertSaveData2KeepQuest")
    if m_conv ~= nil then
        sdk.hook(m_conv, function(args)
            thread.get_hook_storage()["keep"] = args[2]
        end, function(r)
            -- prefer the return value (converted keep data); fall back to arg
            local obj = nil
            if r ~= nil then
                local okR, ro = pcall(function() return sdk.to_managed_object(r) end)
                if okR and ro then obj = ro end
            end
            if obj == nil then
                local keep = thread.get_hook_storage()["keep"]
                if keep ~= nil then
                    local ok2, o = pcall(function() return sdk.to_managed_object(keep) end)
                    obj = ok2 and o or nil
                end
            end
            if obj ~= nil then dispatch("on_convert", obj) end
            return r
        end)
        l("hooked QuestUtil.convertSaveData2KeepQuest")
    end

    -- ExQuestRewardSetting reward-logic hooks: installed ONCE here, dispatch to
    -- the logic module's M:on_reward (pre) / M:on_reward_post (post). This
    -- list is the only one: hooks can't be re-registered on F9 anyway.
    local td_reward = sdk.find_type_definition("app.user_data.ExQuestRewardSetting")
    local REWARD_HOOKS = { ".ctor", "onLoad", "setup", "read", "initialize",
        "judgeYummyReward", "judgeYummyReward_SpOffer",
        "judgeRareEmReward", "judgeRareEmReward_SpOffer",
        "judgeRareEmReward_MoreSpOffer", "getRewardTypeFromItemID",
        "get_WorthNotifyRareLv", "isWorthNotifyRareLv", "get_RewardPointBorder",
        "getRecommendEmSortParam", "tryGetSwarmSpOfferRewardByEm",
        "isLegendaryForExRewardType", "isNeedJudgeEmReward" }
    if td_reward ~= nil then
        local hooked = 0
        for _, mn in ipairs(REWARD_HOOKS) do
            local m = td_reward:get_method(mn)
            if m ~= nil then
                sdk.hook(m, function(args)
                    dispatch("on_reward", mn, args)
                    -- copy: the args table is only valid during the pre-call
                    local saved = {}
                    for i = 1, #args do saved[i] = args[i] end
                    thread.get_hook_storage()["args"] = saved
                end, function(r)
                    local saved = thread.get_hook_storage()["args"]
                    if saved then dispatch("on_reward_post", mn, saved) end
                    return r
                end)
                hooked = hooked + 1
            end
        end
        l("hooked " .. hooked .. " ExQuestRewardSetting reward methods")
    else
        l("WARNING - ExQuestRewardSetting type not found (reward capture disabled)")
    end

    registered = true
end

-- ============================================================================
-- Frame loop (registered once) - register hooks, F9 reload, forward on_frame()
-- ============================================================================
local key_state = {}
local auto_load_tried = false
local function pressed_once(vk)
    local now = reframework:is_key_down(vk)
    local was = key_state[vk]
    key_state[vk] = now
    return now and not was
end

re.on_pre_application_entry("BeginRendering", function()
    pcall(function()
        register_hooks()
        -- auto-load once; after a failure only F9 retries (no per-frame spam)
        if _G.LMRI_LOGIC == nil and not auto_load_tried then
            auto_load_tried = true
            load_logic()
        end
        if pressed_once(0x78) then   -- F9 = reload logic module from disk
            fresh_log()
            l("######## RELOAD LOGIC (F9) ########")
            load_logic()
        end
        local f2, f3 = pressed_once(0x71), pressed_once(0x72)   -- both polled every frame
        if f2 or f3 then   -- F2/F3 = report live captures
            l("######## MID-SESSION REPORT (F2/F3) ########")
            dispatch("report")
        end
        if pressed_once(0x73) then   -- F4 = re-baseline saved investigations
            l("######## RE-BASELINE SAVED (F4) ########")
            dispatch("baseline")
        end
        if pressed_once(0x74) then   -- F5 = settings sanity + full saved sweep
            l("######## SETTINGS + SAVED SWEEP (F5) ########")
            dispatch("settings")
            dispatch("verified_all")
        end
        if pressed_once(0x75) then   -- F6 = grounding: live reader vs vanilla snapshot
            l("######## GROUNDING (F6) ########")
            dispatch("grounding")
        end
        if pressed_once(0x7A) then   -- F11 = live board-container probe (LMRI_SpOfferProbe.lua)
            l("######## BOARD PROBE (F11) ########")
            dispatch("instant")
        end
        if _G.LMRI_LOGIC ~= nil then
            dispatch("on_frame")
        end
    end)
end)

l("shell ready - edit reframework/data/LMRI_Logic.lua and press F9 to reload (no restart, no ScriptRunner)")
