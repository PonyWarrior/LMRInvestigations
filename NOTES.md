# Developer Notes - Monster Hunter Wilds + REFramework

General REFramework / RE Engine reference gathered while building this mod.
Upstream references:
- `REFramework/` -> https://github.com/praydog/REFramework (master)
- `reframework-book/` -> https://github.com/cursey/reframework-book (master, book at https://cursey.github.io/reframework-book/)

## 1. REFramework Architecture (repo)

Layout:
- `src/` — loader + mods (DInputHook, REFramework.cpp, Mods.cpp, Hooks.cpp, ScriptRunner.cpp,
  Camera/FreeCam/Scene/Graphics/VR mods, PluginLoader, ObjectExplorer, IntegrityCheckBypass, LooseFileLoader)
- `shared/sdk/` — the internal SDK (RE types, TDB parsing, VM, singletons)
- `shared/utility/` — FunctionHook (MinHook), Relocate, Exceptions
- `include/reframework/API.h|hpp` — public plugin API header
- `csharp-api/` — REFramework.NET (C# scripting): REFrameworkNET native interop, AssemblyGenerator
  (generates C# reference assemblies from TDB), test mods incl. `TestMHWilds.cs`
- `scripts/` — Lua examples; `reversing/` — RE_RSZ-ish tooling

### Game-specific SDK
- `sdk::GameIdentity` maps `"mhwilds"` -> `GameID::MHWILDS`
- `TDBVer.hpp`: MHWILDS = TDB_VER 81
- `shared/sdk/ReClass_Internal_MHWILDS.hpp`: internal class layouts (REType 0x68,
  REManagedObject 0x10, REComponent 0x30, RECamera 0x198, RETransform 0x1F0, REScene 0x1807D0,
  RopewayPlayerCameraController 0x220, RopewayCameraSystem 0x158, RopewayMainCameraController 0x140...)
- `src/mods/Graphics.cpp` has mhwilds-specific ultrawide correction binding
  (`get/set_mhwilds_ultrawide_correction_value`, hooks it on `is_mhwilds()`)

### Loader (non-VR install)
- Drop only `dinput8.dll` into game dir; REFramework copies sibling DLLs to `_storage_`,
  hooks D3D11/D3D12/input, initializes VM/TDB lookup, then Lua + plugins.
- Lua: shared state, `reframework/autorun/*.lua` auto-run; errors during init -> MessageBox;
  errors during callbacks -> shown in ScriptRunner (log).

---

## 2. Lua Scripting API (reframework-book)

Global tables: `sdk`, `re`, `reframework`, `json`, `log`, `fs`, `draw`, `imgui`
(+`imnodes`, `imguizmo`, `vrmod`, `thread`, `object_explorer`; types `Vector2f/3f/4f`,
`Matrix4x4f`, `Quaternion`, `REManagedObject`, `RETypeDefinition`, `REMethodDefinition`,
`REField`, `REComponent`, `RETransform`, `REResource`, `SystemArray`, `ValueType`).

### Key entry points
- `sdk.find_type_definition("app.Foo")` -> RETypeDefinition
- `sdk.get_managed_singleton("app.PlayerManager")` -> REManagedObject
- `sdk.get_native_singleton("via.SceneManager")`
- `sdk.hook(method_def, on_pre(args), on_post(retval))`
  - args[1]=thread ctx, args[2]=`this`, args[3..]=params (static: params start at args[1])
  - return `sdk.PreHookResult.SKIP_ORIGINAL` / `CALL_ORIGINAL` from on_pre
  - `sdk.to_managed_object(args[2])`, `sdk.to_int64`, `sdk.to_ptr`, `sdk.float_to_ptr`, `sdk.get_native_field`
- `re.on_frame(fn)`, `re.on_draw_ui(fn)`, `re.on_pre_application_entry(name, fn)`,
  `re.on_gui_draw_element`, `re.on_config_save`, `re.on_script_reset`, `re.msg`
- `reframework:is_key_down(vkey)`, `:is_drawing_ui()`, `:get_game_name()`, `:get_commit_hash()`
- `json.load_file/dump_file/load_string/dump_string` (data dir = `reframework/data`)
- `log.info/warn/debug/error`
- `fs.glob/read/write`, `io` sandboxed to `reframework/data` + `$natives`
- `thread.get_hook_storage()` — per-hook ephemeral storage (pre->post)
- `draw.*` (world_to_screen, text, shapes), `imgui.*` (full Dear ImGui bindings)
- Object methods: `obj:call("name", args...)`, `obj:get_field`, `obj:set_field`,
  `obj._FieldName` sugar, `obj:get_type_definition()`, `read/write_byte/short/dword/qword/float/double(off)`

### Real-world MHWilds pattern examples (installed mods)
- `skip_intro_logos.lua`: hooks `app.GUI010001.onOpen()` + `guiVisibleUpdate()`, sets `_Flow`/`_Skip`/`_EnableSkip`
- `free_rest.lua`: hooks `app.FacilityManager.executeChangeTime` and
  `app.cGUIPartsQuantityCore.setQuantity(app.GUIBaseApp, System.Int32, System.Action\`1<via.gui.Text>)` (full-signature hooking)
- `better_camera_distance.lua`: hooks `app.mcCam_OfsDistance.getTargetOffset()`,
  `ace.cCameraParam.applyToCameraController`, reads hunter via
  `app.PlayerManager`:getMasterPlayer():get_ContextHolder():get_Hunter(), uses `sdk.get_native_field/set_native_field` on `via.vec3`
- Config pattern: default_config table + `json.load_file/dump_file`, `imgui.checkbox/slider_float/combo` in `re.on_draw_ui`

### C# scripting (REFramework.NET; supported by nightly builds incl. this one)
- `.cs` files -> `reframework/plugins/source/` compile+hot-reload; DLLs -> `reframework/plugins/managed/`
- Requires .NET 10 runtime; generated proxies in `reframework/plugins/managed/generated/`
- `[PluginEntryPoint]`, `[PluginExitPoint]`, `[MethodHook(type, nameof, Pre|Post, skipJmp)]`,
  `[Callback(typeof(UpdateBehavior), CallbackType.Pre)]`
- `API.GetManagedSingletonT<T>()`, `ManagedObject.ToManagedObject(addr).As<T>()`,
  `app.*`, `via.*`, `ace.*` proxies; `_System.*` for `System.*` types
- `TestMHWilds.cs` example uses `app.PlayerManager.getMasterPlayer().ContextHolder.Pl`,
  `HealthManager._Health.read()`, `via.SceneManager.MainView.PrimaryCamera`

---

## 3. MH Wilds / RE Engine specifics

- Game namespace: `app.*` (game code, C#-like managed), `via.*` (native engine/core),
  `ace.*` (camera/effects gameplay), `System.*` (.NET-style).
- Managed singletons to look at: `app.PlayerManager`, `app.CameraManager`, `app.FacilityManager`,
  `app.EnemyManager`, `app.SaveServiceManager`, `app.ItemManager`, `app.CharacterManager`.
- Native singletons: `via.SceneManager`; entry names via `via.ModuleEntry` (re.on_application_entry).
- Full enum dump available: `<game folder>\Enums_Internal.hpp`
- `il2cpp_dump.json` can be generated from Object Explorer "Dump SDK" (offline TDB reference).
- Object Explorer (DeveloperTools) is the primary discovery tool; ObjectExplorer context menu can hook methods at runtime.

---


## 4. Useful follow-ups
- Deep-dive disassembly of specific TDB method addresses from `il2cpp_dump.json` in rizin/REA.
- Prototyping new mods: drop a `.lua` into `reframework/autorun/`, iterate via ScriptRunner hot-load.
- For C# plugins: clone csharp-api deps, reference generated proxies, place source in `plugins/source/`.
