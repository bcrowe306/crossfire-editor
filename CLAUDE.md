# Crossfire Editor

A desktop game editor for the **Crossfire Engine** (`bcrowe306/crossfire-engine`, checked out next
to this one as `odin_sdl_engine/`). This repository is `bcrowe306/crossfire-editor` (renamed
2026-10-20 from `odin_sdl_editor`; GitHub redirects the old URLs).

**Branding:** the product names are **Crossfire Editor** and **Crossfire Engine**; the logo is
`assets/icons/crossfire.png` (1024 px, transparent; made from the artwork with the background and
watermarks removed: see `tools/icons/make_icons.sh`). Use the names in anything users see (window
title, docs, release titles and archives, the app bundle). The executable is `crossfire-editor`,
the Odin package `crossfire_editor` (`-vet-packages:crossfire_editor`), the engine's `crossfire`;
local folder names stay `odin_sdl_editor/` and `odin_sdl_engine/`.
- **Icons per platform:** the window icon at run time on all of them (`branding.odin`, from
  `assets/icons/crossfire_256.png`); Windows: `crossfire.rc` (at the root, so rc.exe finds
  `assets/icons/crossfire.ico` whichever folder it resolves from) compiled in with `-resource:`
  (`ICON_RESOURCE` in the Taskfile, package_editor.sh); macOS: `Crossfire.icns` made by
  bundle.sh's layout step (sips + iconutil), `CFBundleIconFile`, also the disk image's volume
  icon; Linux: the archive's `icons/` and `install-desktop-entry.sh` (a `.desktop` named by the
  app ID `io.github.bcrowe306.crossfire-editor`, which the window carries, so the desktop shows
  the icon for the running window too).
- The data folder (`Toolchain_DataDir`) is `crossfire-editor` (it was `odin_sdl_editor`: an Odin
  installed there before needs installing again). Users create projects, build scenes from nodes,
manage assets, run their game, and export it to the web and desktop platforms (later: Steam,
consoles and handhelds).

**Status:** early but usable.
- **Works:**
  - The viewport renders the scene with the engine and supports selecting, moving, rotating and
    scaling nodes, with a keyboard-driven keymap.
  - Projects load from and save to disk as XML (`examples/demo_project` opens by default).
  - The project browser searches, previews images and sounds, and imports/removes assets.
  - The inspector edits node properties. **Play** runs the project in the engine's player.
  - The scene tree has a context menu, copy/paste/duplicate, and drag to reorder and reparent.
  - Undo/redo covers every scene edit. Settings (appearance, undo, keymap) are edited in a dialog
    and saved to editor.ini next to the executable.
  - **Scripts**: Odin code attached to nodes, created from the inspector, edited in the built-in
    code editor's tabs (`code_editor/`, with OLS completion) or an external editor (Zed by default), exported fields edited in the inspector, built into a per-project
    player for Play.
  - Multi-select (Ctrl/Shift+click, box select, Ctrl+A), a viewport grid with snapping, inline
    rename, dragging images from the browser into the viewport, New/Open Project with an
    unsaved-changes prompt.
  - **Physics** (the engine's Box2D integration): body, shape, Area and RayCast nodes edited in the
    inspector, shapes and rays outlined in the viewport, physics settings in Project Settings.
  - **Particles**: ParticleEmitter nodes, every setting edited in the inspector (sliders, linked
    pairs, color pickers with alpha, a color ramp editor, reset), played live in the viewport.
  - **Sound**: AudioPlayer, AudioPlayer2D (positional) and MusicPlayer (streamed) nodes edited
    in the inspector (sound, bus, sliders, Preview); mix buses in the bottom panel's Mixer tab.
  - **Export** to Linux x86_64 and the web (WebAssembly, through Emscripten). Every other target
    is listed with its settings and reports "not implemented yet".
- **Not yet:** the other export targets, non-PNG/BMP images on the web, CI.

Sections marked "planned" describe where it's going. Update this file as they become real.

## Stack

| Piece | What | Where |
|---|---|---|
| Language | Odin (`dev-2026-10` nightly) | `odin version` |
| UI | **Skald**: Elm-architecture GUI, Vulkan renderer, SDL3 windowing | `Skald/` git submodule (github.com/bcrowe306/Skald) |
| Code editor | **code_editor**: an Odin code editor on SDL3 with an OLS client, hosted in code tabs | `code_editor/` (in this repo) |
| Engine | **odin_sdl_engine**: SDL3 renderer, scenes/nodes with transforms, camera, animation, UI menus, project loader, player | Separate repo; found through `ENGINE_DIR` (default `../odin_sdl_engine`) |
| Project files | XML | Written by this repo (`project_xml.odin`), read by the engine's parser (see "Project format") |

## Setup and commands

All build, run and test commands live in `Taskfile.yml` ([Task](https://taskfile.dev)). **Use the
tasks rather than raw `odin` commands**, and when adding a new build, test or tooling command,
add it as a task and to the README's command table.

| Command | What it does |
|---|---|
| `task setup` | One-time setup: `submodules` + `stb` + `box2d` |
| `task box2d` | Build the engine's Box2D (`<engine>/tools/build_box2d.sh` into `<engine>/box2d/lib`). A dependency of `check`, `test`, the builds and `run`; skipped when built |
| `task sdl` | Build the engine's static SDL (`<engine>/tools/build_sdl_static.sh` into `<engine>/sdl/lib`; CMake; Linux, macOS). The editor and every game then link SDL in (a single executable). A dependency like `box2d`; skipped when built |
| `task box2d:web` | The engine's Box2D for web exports (`task emsdk` runs it; exports build it when missing) |
| `task submodules` | `git submodule update --init --recursive` (Skald, emsdk) |
| `task emsdk` | Install Emscripten into the `third_party/emsdk` submodule (`EMSDK_VERSION`, ~1 GB, once per machine), then `web:mixer`. Web exports need it |
| `task web:mixer` | Build SDL3_mixer for the web (`tools/build_web_mixer.sh` → `build/web/libSDL3_mixer.a`); exports also build it when it's missing |
| `task stb` | Build Odin's STB libraries Skald needs (`build_stb.sh`). Skipped when already built for the active Odin install |
| `task check` | Type-check with `-vet-unused -vet-packages:crossfire_editor` (Skald itself doesn't pass vet) |
| `task test` | Unit tests (`editor_test.odin`) |
| `task test:code-editor` | The built-in code editor's own unit tests (`code_editor/`, its Taskfile) |
| `task ols` | Build OLS into `code_editor/third_party/ols` (its `ols:build`; skipped when built) |
| `task verify` | `check` + `test` |
| `task test:ui` | UI test scripts (`tests/ui/*.script`) driving the real editor with injected input (`SCRIPT=<file>` for one) |
| `task test:ui:fullscreen` | The same with a fullscreen editor (`SCRIPT=<file>` for one) |
| `task build` / `task build:release` | Debug build into `build/`, optimized build into `build/release/` |
| `task run` | Build optimized (`build/release/`) and run; program arguments after `--` |
| `task run:debug` | Build with `-debug` and run (unoptimized: the viewport ran at ~14 fps vs 60) |
| `task run:fullscreen` | Optimized, with `-define:EDITOR_FULLSCREEN=true` |
| `task player` | Build the engine's player into `build/player/player` |
| `task play:demo` | Run the demo project in the player, without the editor |
| `task clean` | Delete build output |

- `EDITOR_FULLSCREEN` exists for checking the full layout on a tiling window manager (Hyprland
  here), which otherwise squeezes the window into a tile.
- **Engine location:** the Taskfile's `ENGINE_DIR` (default `../odin_sdl_engine`, override with
  `task run ENGINE_DIR=...`) is used twice:
  - as the `engine` collection (`import e "engine:."`)
  - as `-define:ENGINE_DIR`, which Play and Export build from (`Toolchain_EngineDir`; a release
    has no checkout there and uses the `engine/` folder it ships instead)
- `task prebuilt` builds this platform's **prebuilt player** (`<engine>/player`, `-o:speed`) into
  `build/prebuilt/<target>/player` and `build/release/prebuilt/...`, next to both editors: projects
  without scripts then play and export without compiling. `run` and the UI test tasks depend on it.
- `task run -- <project folder>` opens another project. With no argument the editor opens the
  demo project (`Editor_DemoProject`): `examples/demo_project` beside the executable (release
  archives ship it there), else in the working folder (a checkout); from a macOS bundle a copy
  in `~/Documents/Crossfire Editor`, made on first run from the bundle's
  `Resources/demo_project` (`Editor_ShippedDemo`, `Folder_Copy`). Only when there's no shipped
  demo to copy does `Project_CreateDemo` write a reduced built-in one.
- Skald is imported as `import "gui:skald"` (`-collection:gui=Skald`, set by the Taskfile).
- Runtime needs a Vulkan loader and SDL3 (plus SDL3_image, SDL3_ttf, SDL3_mixer through the engine).
  Per-OS setup is in `Skald/PLATFORMS.md`.
- Odin reference for Skald: `odin doc Skald/skald`. Guides: `Skald/docs/` (start with `gotchas.md`
  and `widget_choice.md`).

**Don't edit `Skald/` here.** It's a pinned submodule of a separate repo. Skald fixes go to that repo;
here you only bump the submodule commit.

## Skald rules

Skald is not immediate-mode and not a retained widget tree:

- The app is `init` / `update` / `view`. `State` is the single source of truth and `Msg` is a union of
  everything that can happen. `update(state, msg) -> (State, Command(Msg))`.
- `view` rebuilds the whole UI every frame from `State`. There are no widget handles to keep: to
  change the UI, change `State` through a `Msg`.
- Side effects (file I/O, dialogs, timers) go through `Command(Msg)`. Blocking work goes in a child
  process or `cmd_thread`. Never block `update` or `view`.
  - Some side effects happen directly in `update` because they own non-State resources: child
    processes (`play.odin`), audio playback (`audio_preview.odin`), file copies (`assets.odin`).
- Read `Skald/docs/gotchas.md` before writing UI code, and copy the patterns in `Skald/examples/`
  rather than inventing new ones.

## Code map

| File | What |
|---|---|
| `doc.odin` | Package overview and a diagram of the window layout |
| `editor.odin` | `State`, `Layout`, panel size rules (`FittedSidebarWidths`, `FittedBottomHeight`), `init`, args, `main` |
| `msg.odin` | `Msg` union and `Action` (menu, toolbar and shortcut commands) |
| `update.odin` | `update`, the only place State changes |
| `keymap.odin` | `DEFAULT_KEYMAP`, shortcut dispatch, typing guard, the platform's keys (`Chord_OnPlatform` / `Chord_FromPlatform` / `Chord_Format`: the keymap's Ctrl is Cmd on macOS), `keyParen` (an action's keys for text) |
| `context_menus.odin` | **Right-click menus everywhere**: `ContextTarget` (what was clicked), `State.contextMenu`, `Context_Menu_Opened` / `_Closed`, `ContextMenu_Items` (the items per target: nodes, empty viewport, the tree, the browser's every kind, tabs, logs), `contextMenuView` (Skald's `popup_menu`, built first in the frame), `rightPressOpens`, the commands without an older message (`Node_Command`, `Add_Node_Here`, `Paste_Here`, `Tab_Command`, `File_Command`, `Log_Command`, `Asset_Add_To_Scene`) |
| `context_menus_panels.odin` | The bottom panel's menus (`Ctx_Graph`): States, Dialogue nodes and steps, Timeline tracks and keys, Mixer strips, Git changes, Live nodes, Animation frames, plugins |
| `viewport_tools.odin` | **Viewport tools**: Align and Distribute (`Align_Nodes`, `Align_Moves` on `Viewport_NodeShapes`' boxes), the Zoom tool's click or box (`ViewportTools_ZoomBox`), guides (`SceneDef.guides`, `Guide_*` messages, `Guides_Snap` / `Guides_SnapNode`, `.editor/guides.ini`: `Guides_Save` / `Guides_Load`) |
| `editor_theme.odin` | **The editor's look**, edited live in Settings > Appearance: `ThemeColor` (Skald's roles), `Settings.themeColors` / `themeColorsSet` / `cornerRadius`, `EditorTheme_Apply` (in `Settings_Theme`), `THEME_PRESETS`, `ThemeColor_Format` / `_Parse` (editor.ini's `[theme]`) |
| `project.odin` | Project model (`Project`, `SceneDef`, `NodeDef`, `AssetDef`), node insert/remove, world transforms, `Project_Load` (through the engine's parser), the demo project |
| `project_xml.odin` | `Project_Save`, XML writer (`ProjectToXML`, `SceneToXML`, `EscapeXML`) |
| `assets.odin` | Importing (copy into `assets/`), removing, usage counts, asset kinds by extension |
| `audio_preview.odin` | Sound playback for the preview panel (SDL3_mixer; package state) |
| `play.odin` | Play mode: save, build the player, run it as a child process, stream output, pause/stop |
| `play_reload.odin` | **Hot reload**: `PlayReload` (`PlaySession.reload`): scripts newer than the running game rebuild `player-reload` beside it, describe it, ask the game for a `snapshot` over the live link, restart it with `--restore` (`playReloadTick`, from `playTick`); `settings.hotReload` |
| `plugin_host.odin` | **Editor plugins**: `PluginsState` (package state: the project's `plugins/<name>/` folders, a build process, loaded libraries), `Plugins_Tick` (find, build with `-build-mode:shared` and the `plugin_api` collection, load with `core:dynlib`, reload on changes), the `Host` procedures (`pluginState`), `Plugin_Command_Run` / `Plugin_Row_Changed` (`.Project` undo steps), `Plugins_Import`, `Plugins_InspectorRows`, `Plugin_Create` (`PLUGIN_TEMPLATE`), `Toolchain_PluginAPI` |
| `view_plugins.odin` | The bottom panel's **Plugins** tab (`PluginsPanel`: each plugin's state, commands, importers, inspectors) and plugins' inspector rows (`pluginInspectorRows`) |
| `plugin_api/` | **The plugin API** (package `crossfire_plugin`): `Plugin`, `Command`, `Importer`, `Inspector`, `InspectorRow`, `Host`, `PLUGIN_API_VERSION`; plugins import it as the `plugin_api` collection, the editor by relative path; releases ship it beside the editor (macOS: Resources/plugin_api) |
| `dialogue_edit.odin` | **Dialogues**: `DialogueDef` (`Project.dialogues`, asset kind Dialogue, `dialogues/`), `Project_CreateDialogue` / `SaveDialogues`, `Yarn_Import`, `DialogueEditor` (`State.dialogue`: the shown dialogue, node, step, drag), `Dialogue_Changed` (every edit: a `.Project` step) / `Dialogue_View`, DialogueBox's `NodeDef.dialogue` / `dialogueStart` / `dialogueBox` and rows (`dialogueBoxRows`, `DialogueBox_Setting_Changed`), `Dialogue_ProvideToGame` |
| `view_dialogue.odin` | The bottom panel's **Dialogue** tab (`DialoguePanel`): the dialogue's graph (`dialogueGraph`: boxes with their first line, arrows for jumps and options), the selected node's steps and options as rows, + step buttons |
| `skeleton_edit.odin` | **Skeletons**: `NodeDef.boneLength` / `mesh` / `ik` / `ikTip` / `ikTarget`, `Skeleton_Setting_Changed`, `Skeleton_Bone_Added`, `Mesh_Made` (`Mesh_FromPicture`: a grid, empty cells dropped), `Mesh_Bound` (`Mesh_AutoWeights`: nearest bones' segments, inverse square, up to 4), the inspector's rows (`skeletonInspectorRows`), `DragonBones_Import` (a `_ske.json` into a component and an atlas) |
| `asset_import_edit.odin` | **Import settings**: `AssetDef.filter` / `msdf`, `Project.textureFilter` (Project Settings > General > Image filtering), `Asset_Filter_Changed` / `Asset_MSDF_Changed` / `Font_MSDF_Make_Requested`, `Fonts_MakeMSDF` (save, Play, exports), `Fonts_ExportFiles`, the previews' rows (`imageImportRows`, `fontPreview`, `audioImportRows`), sound conversion with ffmpeg (`Audio_Convert` on a worker, `Audio_ConvertFile`, `Audio_Converted`: references follow; `AUDIO_CONVERT_EXTENSIONS` converted on import), `Toolchain_FFmpeg` |
| `atlas_edit.odin` | **Texture atlases**: `AtlasDef` (`Project.atlases`, asset kind Atlas, `atlases/`), `Project_CreateAtlas` (the browser's New Atlas), `Atlas_PackFiles` (packs with `e.Atlas_Pack`, writes the PNG and `.atlas.xml` on every edit), `atlasInspector` (`State.atlasSelection`), `atlasPreview`, Sprites' `NodeDef.region` (the Region row) |
| `node_scripts_edit.odin` | **Several scripts per node and node types of game code**: `NodeDef.moreScripts` / `customKind` / `customProps`, `Node_Script_Added` / `_Removed` / `_Open`, `NodeScriptTarget` / `NodeCustomTarget` (PropTarget), `AddNode_Entries` (Add Node's "Your node types"), `NodeDef_Codes` (what a node runs, in the engine's order), the inspector's rows (`moreScriptsRows`, `nodeTypeRows`) |
| `tree_rows.odin` | Flattens the project into browser and scene tree rows, applying the browser search. Shared by view and update, because Skald's tree reports clicks by row index |
| `view.odin` | Root layout: menu bar, toolbar, resizable workspace, status bar, remove-asset dialog, panel header helpers |
| `view_browser.odin` | Left sidebar: project browser (search, tree, collapsible preview panel) |
| `view_browser_info.odin` | The preview for scripts (`scriptInfoPreview`: what each registered script and data type is, where it's used) and scenes (`scenePreview`: facts, actions, the scene's own settings) |
| `scene_settings.odin` | A scene's own settings (`SceneDef.settings`, the engine's `e.SceneSettings`): their messages and undo |
| `node_listeners.odin`, `view_inspector_events.odin` | **Listening to node events**: the inspector's Events section (`eventsSection`), the Listen... dialog (`listenerDialogView`), attaching (`Listener_Attach`: the listener on the node, the handler appended to the script's file) |
| `asset_fields.odin` | A browser asset dropped on a code tab: a field of its handle type (`AssetField_Type`, `AssetField_Line`, `AssetField_Insert`) |
| `node_fields.odin` | Script node fields: paths between nodes (`Scene_NodePath`), the nodes a field takes (`NodeField_Choices`), adding one by dropping a node on a code tab (`NodeField_Insert`) |
| `view_viewport.odin` | Center: scene tabs, view controls, and the viewport canvas (rendered scene, rulers, gizmos, input) |
| `viewport_preview.odin` | Engine-rendered preview of the open scene (the shared GPU renderer straight into a Skald image; fallbacks: a GPU readback, software) |
| `gpu_share.odin` | **The shared GPU renderer**: SDL's Vulkan renderer on Skald's device (`SharedGPU_Renderer`, `SharedGPU_Shutdown`), `GPUTarget` (a Skald `image_create_target` image as an SDL render target: `_Ensure`, `_Begin` / `_End`, `_Draw`, `_ReadPixels` for tests), used by the viewport and the code tabs |
| `viewport_math.odin` | Viewport pan/zoom math and drag (move/rotate/scale) math |
| `add_node.odin` | Add Node dialog logic: `AddNode_Kinds` (search over the engine's `SCENE_NODE_KINDS`), `AddNode_Create` (parent, unique name) |
| `node_edit.odin` | Subtree copy/paste/duplicate, `Scene_MoveNode` (reorder and reparent keeping the world transform), unique names |
| `history.odin` | Undo/redo: command history, automatic recording (`History_Classify`), merging |
| `settings.odin` | `Settings`, loading/saving editor.ini over `settings.default.ini`, chord text, the Skald theme |
| `zip.odin` | Zip files: `Zip_Write` (stored), `Zip_List` / `Zip_Read` (stored and deflated, CRC checked), `Zip_SafeName` |
| `project_archive.odin` | Project archives (`.odinsdl`): `ProjectArchive_Create` (outside assets brought in), `ProjectArchive_Extract`, the File menu's flow |
| `vcs.odin` | Version control through `git`: `GitSnapshot` / `Git_ReadSnapshot`, `GitOp` / `Git_Commands` / `Git_RunCommands`, `Git_Update` |
| `view_git.odin` | The bottom panel's Git tab |
| `view_about.odin` | Help > About: the logo (the built-in 256 px icon, uploaded once), `EDITOR_VERSION` (`-define:EDITOR_VERSION`: the Taskfile's `git describe`, CI's tag), Odin's version, links (opened with `sdl.OpenURL`); `tests/ui/about.script` |
| `branding.odin` | `APP_NAME`, `APP_IDENTIFIER`; `Branding_SetAppMetadata` (the Wayland app ID / X11 class) and `Branding_SetWindowIcon` (the built-in 256 px logo) |
| `bundle.odin` | Running from a macOS app bundle: `Editor_SetupBundle` (the data folder as working folder, settings there, the bundled Vulkan through `bundle_darwin.odin`), `Editor_DemoProject` / `Editor_ShippedDemo` (where the demo is, and the shipped copy), `Folder_Copy`, `Editor_ArgumentPath` |
| `tilemap_edit.odin` | **TileMap nodes**: `NodeDef.tilemap` (the engine's `e.TileMapSettings`), `TileMap_Setting_Changed`, the inspector's rows (file, frame, layers, tile collision, what each layer becomes: `TileMapEdit_LayerInfo`), `Scene_AddTileMapAt` |
| `material_edit.odin` | **Physics materials**: `MaterialDef` (`Project.materials`), load / save / create, `Material_Field_Changed` / `Material_Created`, the material inspector (`materialInspector`) and a body's Material rows (`materialBodyRows`) |
| `collision_trace_edit.odin` | **Collision from sprite**: `TraceSettings` (`State.trace`), `Trace_Sprites`, `Trace_Pieces`, `Trace_MakeShapes` (`Collision_Traced`), the body inspector's rows (`traceInspectorRows`) |
| `camera_edit.odin` | **A Camera's follow target and settings**: `NodeDef.camera` (`e.CameraSettings`) and `cameraTarget`, `Camera_Changed` (`CameraNumber`), the Camera's inspector rows (`cameraInspectorRows`: Zoom; Follow, Limits, Shake groups), keeping target paths through renames and moves (`CameraTargets_Resolve` / `_Repath`, `Scene_HasCameraTargets`) |
| `camera_tools_edit.odin` | **Camera tools**: `NodeDef.cameraTools` (`e.CameraToolSettings`) and `viewCamera`, `Camera_Tool_Changed` (`CameraToolNumber`), the ParallaxLayer / CameraZone / CameraView inspector rows (`cameraToolInspectorRows`) |
| `state_machine_edit.odin` | **State machines**: `NodeDef.stateMachine` (`e.StateMachineSettings`), `StatesEditor` (the machine shown, its selection), `SM_Changed` / `SM_View`, `States_Update`, `States_Follow`, `States_Target` / `States_Animations`, `Scene_ResolvePath`, the inspector's rows |
| `view_states.odin` | The bottom panel's States tab (`StatesPanel`): the graph (`graphCanvas`: boxes, arrows with their conditions, Any state; click, drag, double-click), the selected state's and transition's fields, the parameters |
| `scene_flow_edit.odin` | **Scene changes**: `Project.transition` / `loadingScene`, Project Settings > General's rows (`sceneFlowSettingRows`, on the dialog's draft), `Project_Settings_Transition_Changed` / `_Loading_Changed` |
| `live_edit.odin` | **The live view**: `LiveView` (`State.live`: the running game's tree, chosen node's properties, stats, frame-time history), `Live_Send` (to the game's stdin), `Live_Ingest` (its `@@live` replies), `Live_Update`, `Live_Reset` |
| `view_live.odin` | The bottom panel's Live tab (`LivePanel`): pause / step, stats and the frame-time graph, the nodes, the chosen node's fields (side by side, or stacked in a narrow panel) |
| `nav_edit.odin` | **Navigation**: `NodeDef.nav` (`e.NavSettings`; a region's area is `shapeSize`), `Nav_Setting_Changed` (`NavNumberTarget`), the NavRegion and NavAgent inspector rows (`navInspectorRows`) |
| `light_edit.odin` | **2D lighting**: `NodeDef.light` (`e.LightSettings`), `Light_Setting_Changed`, `Scene_Lighting_Changed`, the light and occluder inspector rows (`lightInspectorRows`; occluders use `shapeRows`), the scene preview's lighting rows (`sceneLightingRows`) |
| `ui_edit.odin` | **UI controls** (Panel, Button, ProgressBar, TextField, ScrollBox, RichText): `NodeDef.ui` (the engine's `e.UISettings`), `UI_Setting_Changed` / `UIEdit_Update`, the inspector's rows (`uiInspectorRows`), `NodeKind_IsControl` |
| `theme_edit.odin` | **UI themes** (`.theme.xml` assets, kind Theme): `ThemeDef`, `Project.themes` / `uiTheme`, load / save / create, the theme inspector (`themeInspector`, `State.themeSelection`), `Theme_*` messages |
| `timeline_edit.odin` | **The Timeline** (Animator nodes): `TimelineEditor` (the Animator edited, playhead, selection), `Timeline_Changed` (edits: node steps on the Animator) / `Timeline_View` (panel only), `Timeline_Update`, `Timeline_Follow`, track paths (`Timeline_ResolvePath`, `Timeline_PathTo`), `Timeline_Properties`, `Timeline_NodeValue` (what Key records) |
| `view_timeline.odin` | The bottom panel's Timeline tab (`TimelinePanel`: clip and transport toolbars, the tracks canvas with the ruler, keys and playhead, the key editor) and the Animator's inspector rows (`animatorInspectorRows`) |
| `tile_paint.odin` | **Tile painting**: `TilePainter` (tool, brush, layer, terrain), its messages, `TilePaint_Update` (strokes, fills, terrains, growing grids, copying file layers), `TilePaint_CellAt` |
| `view_tiles.odin` | The bottom panel's Tiles tab: layer and tileset choices, tools, flips, the tile palette (`TilesPanel`) |
| `docs/manual/` | **The user manual**: a page per feature for users new to the editor (`README.md` lists them in reading order). Help > User Manual (F1, `Manual_Open`: `MANUAL_URL` + page) and panels' Manual buttons open it. **Every new feature gets a page here.** Pages are ready for a static site (Astro, later): YAML frontmatter `title` / `description` (quoted when they hold `: `) / `order` (the reading order, unique, README 0; a new page takes its place and the ones after it move up), plain relative links, no GitHub-only syntax (no `> [!NOTE]`, no `<details>`), a Questions section at the end, examples that compile |
| `aseprite_edit.odin` | Aseprite files: the parsed-file cache (`AsepriteEdit_File`), the browser preview (`AsepriteEdit_Preview`, `AsepriteEdit_Summary`), Open in Aseprite (`AsepriteEdit_Open`, Settings > Editor > Aseprite program), `Image_LoadRGBA` (any image, Aseprite files through the engine), `Image_Size` (its size, cached per file time: the header only) |
| `ldtk_edit.odin` | LDtk levels: the inspector's LDtkLevel section, `LDtk_Setting_Changed`, the parsed-file cache (`LDtkEdit_Project`), importing with dependencies (`LDtkEdit_Import`), export files, Open in LDtk, the browser preview, `Scene_AddLDtkAt` |
| `toolchain.odin` | What building games needs, found at run time: `Toolchain_Odin` (setting, PATH, installed), `Toolchain_EngineDir`, `Toolchain_PrebuiltPlayer`, `Toolchain_Check` (Settings > Toolchain), `Toolchain_InstallOdin` |
| `settings_dialog.odin` | Settings dialog state and messages (edits a draft) |
| `view_settings.odin` | The Settings dialog: Appearance, Editor, Keyboard, Toolchain tabs |
| `settings.default.ini` | Default settings, built into the editor |
| `tree_view.odin` | `coloredTree`: the browser's and scene tree's tree widget (skald.tree's behavior, plus per-row icon/label colors); type colors; `Tree_RevealSelected` and `Scroll_RevealClicked` (keeping what was clicked in view) |
| `value_slider.odin` | `valueSlider`: a slider with a typeable value box, Shift for 10× finer drags (no jump to the pointer), and a reset-to-default button. Generic over the message type, its state kept in the file (not `State`), so it can move to a widget package |
| `number_field.odin` | `numberField`: text box with small flat −/+ buttons, used by the inspector and Settings |
| `code_editor/` | **The built-in code editor**: an Odin code editor on SDL3 (buffer, keymap, syntax, LSP client, `editor` = package `code_editor`, its own README, tests and Taskfile). Changed here: its `editor` package renamed `code_editor` (Odin package names must be unique: it was `editor`, ours then; ours is `crossfire_editor` now), and SDL_ttf calls taking `[^]u8` for this Odin |
| `code_editor_host.odin` | Hosting it in Skald: `CodeEditor` per open file (a `ce.Editor`), the shown one drawn by the shared GPU renderer into `CODE_IMAGE` (else a software renderer and surface, uploaded when the pixels change), the SDL event watch feeding it input, focus (`CodeEditor_Frame`, `CODE_EDITOR_PASSTHROUGH`), the bundled font (Liberation Mono), `Code_FindOLS` |
| `code_tabs.odin` | Code tabs: `Script_Open` (built-in or external), `CodeTabs_Open` / `Close` / `SaveAll`, their messages (`CodeTabs_Update`), the tabs' view, the status line, the close prompt |
| `scripts.odin` | Project scripts: the catalog from `--describe-scripts`, script files, New Script template, opening in the code editor, node script values |
| `project_scenes.odin` | Scene list operations: add, copy, rename (updating references), remove, start scene, names; deleting old scene files on save |
| `scene_actions.odin` | The browser's scene actions (`Scene_DoAction`), key routing while the browser has focus, scene rename, Project Settings state |
| `component_edit.odin` | **Components**: saving a node tree as one (`Scene_SaveBranchAsComponent`), new ones, loading and writing their files, instances (`Scene_AddInstanceAt`, `Component_Contains` against nesting itself), `Scene_IsComponent` |
| `input_actions.odin` | The project's input actions (`ActionDef`), the default ui_* ones (`DefaultActions`), capturing a binding through Skald (`Input_CaptureBinding`, `EngineKeyFor`), the Input tab's messages (`InputSettings_Update`) |
| `view_project_settings.odin` | The Project Settings dialog: General (name, resolution, scaling, background, start scene) and Export (targets and their settings) tabs |
| `export.odin` | Export targets (`ExportTarget`, `EXPORT_TARGETS`), per-target settings and export.ini, `Export_Plan` (the steps, pure and unit-tested), ldd parsing, the web page template |
| `export_run.odin` | Running exports: one job per target, commands as child processes (`Export_Tick`), file steps in `update`; `EMSDK_DIR` |
| `third_party/emsdk` | Emscripten SDK submodule, pinned to a release tag (`task emsdk` installs it) |
| `third_party/SDL_mixer`, `tools/build_web_mixer.sh` | SDL3_mixer sources (submodule, the native version) and the script that builds them for the web, with the symbol aliases Odin's binding needs (see the engine's CLAUDE.md, "Web build") |
| `selection.odin` | Multi-selection: `Selection_Set/Toggle/Normalize/Roots` |
| `project_session.odin` | Unsaved changes, New/Open Project, Save Project As, the save prompt, the window title |
| `recent_projects.odin` | Recent projects: `RecentProjects` (`recent_projects.txt` beside the settings), `Recent_Add` / `Remove` / `Clear`, `Recent_Shown` (what the File menu lists), `Recent_Label` |
| `view_project_dialogs.odin` | The save-changes and New Project dialogs |
| `view_add_node.odin` | The Add Node dialog: search box, list of node kinds, Up/Down/Enter keys |
| `view_inspector.odin` | Right sidebar: scene tree above the inspector (common and per-kind properties) |
| `project_data.odin` | Global scripts (`GlobalDef`) and data resources (`DataDef`) in the project; prop editing for any owner (`PropTarget`); creating, loading and saving data files; the generated `scripts/assets.odin` (`Scripts_AssetsSource` / `Scripts_WriteAssetsFile`) |
| `view_fields.odin` | `FieldControl`: the control for one exported field (numbers, bool, text, scene, vector, color, enum, asset handles), for node scripts, globals and data resources |
| `view_inspector_particles.odin` | The inspector's ParticleEmitter settings, built from the engine's `e.ParticleSettings_Fields` (sliders, linked pairs, colors with alpha, the color ramp editor `colorRampEditor`, Reset) |
| `view_inspector_physics.odin` | The inspector's physics properties: layer grids (`layerGrid`), body, shape and ray fields, the points field; `shapeBody` (a shape's body) |
| `view_bottom.odin` | Bottom panel: Console / Output / Animation / Mixer tabs, collapsible; the log tabs' view (`logView`: header of filters, a `virtual_list` of lines, `logFollow`) |
| `console.odin` | **The Console's and Output tab's lines**: `LogList` (`State.console` / `output`: lines with a level and category, the categories seen, counts, the history limit, filters, following), `LogList_Append` / `Trim` / `Clear` / `Shown`, `LOG_*_CATEGORY`, `LogLevel` (the engine's), `Console_Update` (the `Log_*` messages) |
| `console_test.odin` | Tests: categories and the limit, filters, the game's lines parsed, the messages and menus, the setting |
| `mixer.odin` | Mix buses: `BusDef`, `Buses_FromData` (Master first), names (`BusNameProblem`), `Bus_NodeCount`, `isSoundKind`, the Mixer's messages (`Mixer_Update`) |
| `view_mixer.odin` | The Mixer tab (`MixerPanel`, built in `skald.sized`), like a DAW's: a channel strip per bus (node count, remove, pan, fader beside its level meter, dB, mute, name at the bottom), scrolling sideways; Master pinned on the right, + beside it |
| `mixer_widgets.odin` | The mixer's widgets, generic like `valueSlider`: `hScroll` (sideways scrolling: Skald's scroll is vertical only), `fader` (dB scale, `Fader_GainToPosition` / `PositionToGain`), `panControl`, `levelMeter` (stereo peaks, fall, hold, clip light) |
| `line_edit.odin` | **Lines and trails**: `NodeDef.line` (`e.LineSettings`; a line's points are `points`, shared `pointsField`), `Line_Setting_Changed` (node steps), the Line2D / Trail2D inspector rows (`lineInspectorRows`) |
| `shader_edit.odin` | **Shaders**: `NodeDef.shader` / `shaderParams`, the Shader section and ScreenEffect rows (`shaderInspectorRows`), `Node_Shader_Changed` / `Node_Shader_Param_Changed` / `Shader_New_Requested`, Shader assets (`.frag`, `shaderPreview`), compiling (`Shaders_Compile`, `ShaderEdit_Watch`, `Toolchain_ShaderTools`), `Project_UsesShaders` |
| `touch_edit.odin` | **Touch controls**: `NodeDef.touch` (`e.TouchControlSettings`) and `touchActions` (comma-separated, owned), `Touch_Setting_Changed` (node steps), the VirtualJoystick / TouchButton inspector rows (`touchInspectorRows`), `NodeKind_IsTouchControl` |
| `players_edit.odin` | **Local players**: `Project.players` (`e.PlayerSettings`, `joinAction` owned: `PlayerSettings_Clone`), Project Settings > Input's Local players rows (`playersSettingRows`, `Players_Setting_Changed` on the draft) |
| `steam_edit.odin` | **Steam**: `Project.steam` / `achievements` (`AchievementDef`: clone, destroy, equal, `AchievementNameProblem`), Project Settings > Steam (`SteamTab`, `Steam_Setting_Changed` / `_Achievement_Added` / `_Removed` on the draft), `ACHIEVEMENT_X` constants |
| `bus_effects_edit.odin` | **Bus effects**: `BusDef.effects` / `effectCount` (a plain array), `Bus_Effects_Opened` (the Mixer's FX: `State.busSelection`) and `Bus_Effect_Added` / `_Removed` / `_Moved` / `_Changed` (`.Project` steps), `busEffectsInspector`; the preview hears them (`AudioPreview_SetEffects` from `Mixer_RoutePreview`) |
| `music_layers_edit.odin` | **Music layers**: `NodeDef.musicLayers` (`MusicLayerDef`: clone, destroy, equal), `Music_Layer_Added` / `_Removed` / `_Changed` (node steps), the MusicPlayer's Layers rows (`musicLayerRows`) |
| `view_inspector_audio.odin` | The inspector's sound node settings (`audioInspectorRows`): sound or music, bus, Open Mixer, volume / pitch / pan sliders, loop, autostart, a 2D player's range and falloff, music's fades, Preview |
| `view_animation.odin` | The Animation panel (the animation editor): a toolbar (animation dropdown and buttons, name, starts-with; the selected animation's sheet, grid mode and values, margin, gap; frames, count, FPS, loop, mode; small groups in a `wrap_row`) over the preview and the thumbnails of its sheet's frames (`frameStrip`, cells drawn from the sheet uploaded once: `Image_LoadRGBA`); one scroll for all, which takes images dropped from the browser (`AnimationPanel_TakesDrop`) |
| `animation_edit.odin` | The Animation panel's logic: `AnimEditor` state, `AnimEdit_Update` (its messages), `AnimEdit_Cells` / `AnimEdit_SheetSize` (an animation's sheet's cells, from `Image_Size`), `AnimationDef_FrameAt` / `StepAt` (the frame at a time, as the engine plays it, durations too), `AnimationDef_Range`, unique names, `AnimEdit_IsEdit` |
| `animation_sets_edit.odin` | **Animation assets**: `AnimationSetDef` (`.anim.xml`, `Project.animationSets`: load, save when changed, make: `Project_CreateAnimationSet`), `AnimationDef` / set clone, equal and engine conversions, an Aseprite file's tags as a set (`AsepriteEdit_AnimationSet`), the panel's `AnimSource` (`AnimEdit_Source`), the browser preview, `Scene_AddAnimatedSpriteAt` |
| `icons.odin` | Font Awesome icon font (`assets/fonts`, OFL) and glyph constants |
| `test_driver.odin` | UI test driver: runs a `--script`, injecting SDL input and checking state (format in its doc comment) |
| `editor_test.odin` | Unit tests for the model, XML round trips, transforms, assets, search, viewport math, keymap and update |
| `tests/ui/*.script` | UI test scripts, run by `task test:ui` |
| `tests/fixtures/` | Files tests import (`beep.wav`: a generated 1.5 s tone) |
| `examples/demo_project/` | The demo project, shipped with the editor: the Asteroids game and the forest level (ForestScene: an LDtk level, `assets/forest/`, with entity components and scripts). Its README lists what each part demonstrates |
| `tools/demo/make_forest.py` | Made the forest level from the Legacy-Fantasy and GameSounds packs: copies and cuts the images (a combined hero sheet), copies the sounds, and writes `forest.ldtk` from LDtk's JSON schema (every required key; validated), with auto-layer rules and the tiles they make. Rerun only to start the level over: it's edited in LDtk now |

**Layout rules learned building it:**
- `skald.split` only sizes its **first** pane. Panels that should keep their size (sidebars, bottom
  panel, browser preview) are stored as their own sizes. Their container is built with
  `skald.sized` and reports its size back (`Workspace_Measured`, `Browser_Body_Measured`), so
  `update` can turn a divider position into a panel size. The `Fitted*` procs keep `view` and
  `update` in agreement.
- A `text_input` (or any other widget with width 0) inside a `row` collapses to nothing. Wrap it in
  `skald.flex(1, ...)` or give it a width. A UI test caught the browser search box this way.
- Content inside `skald.scroll` isn't width-limited. Give controls explicit widths (see the
  inspector) instead of `flex`, or they overflow the panel.
- Widgets made by a shared helper all have the same call site. Give each one an explicit
  `skald.hash_id(...)` id, or they share widget state.
- Canvas data must be allocated with `context.temp_allocator`: the canvas draws after `view` returns.
- **Never hand a widget a string that points into the view's `State`.** `view` gets a copy of the
  state on its stack, and Skald lays out and draws after `view` returns, when that memory is reused.
  Heap strings in State are fine (the copy shares them), but text stored inline (`FixedText`, the
  code editor setting) must be cloned to `context.temp_allocator` first. The Code editor field
  showed garbage until it was (only in the optimized build, and tests can't see drawing).
- **Widgets with their own mouse handling ignore presses while a popup is open**
  (`len(ctx.widgets.overlay_rects_prev) > 0`): a click outside a dropdown only closes it.
  `valueSlider`, the ramp editor and the frame strip do. (Skald's `select` once reported its list
  above the trigger while drawing it below, so a choice clicked over a slider changed the slider;
  fixed in Skald's 8f51fe5.)
- `skald.tree` can't color rows and `skald.number_input`'s stepper buttons can't be restyled, so the
  editor has its own `coloredTree` and `numberField`. Keep their widget ids (`browser-tree`,
  `scene-tree`, `inspector-<Field>-<node>`, `-dec` / `-inc` for the buttons): tests click them.
- **A widget inside a scroll must hit-test against its `clip_rect` too**, not just `last_rect`:
  the rect of content taller than the scroll runs on past it, over whatever is below (the scene
  tree's rows took clicks meant for the inspector under it and selected hidden rows).
- **A focusable widget taller than its scroll makes Skald's `reveal_focus` scroll to its top.**
  The trees are one focusable widget each, so a click on a row (which focuses the tree) threw the
  browser and scene tree back to their top and the clicked row out of view. Their scrolls have
  `reveal_focus = false`; `Tree_RevealSelected` scrolls the selected row into view instead, only
  when the selection moves (clicks, the arrow keys, a node picked in the viewport), so wheeling
  away stays put. The inspector's `Scroll_RevealClicked` shows all of a control clicked while
  half hidden (on release, so it doesn't move mid-click); Skald only reveals focusable ones.
  Test: `tests/ui/scroll_reveal.script` (driver checks `scrolled`, `row_visible`).
- A custom widget that stores state under an id (`widget_get`) must not also wrap itself in
  `skald.zone` with that id: the zone claims the slot as another widget kind and Skald resets the
  state every frame. Return a bare `skald.View_Zone{id, child}` (as `coloredTree` does).
- **Tooltips** (tooltips.odin): hovering a row's label in the inspector, Settings or Project
  Settings explains it. `inspectorRow` and `settingRow` look the label up in `fieldTip` (one
  explanation per label); particle settings add their range and default, script fields their
  type, range and default (`scriptFieldTip`); the bottom panel's tab strip has one for all its
  tabs (`skald.tabs` has no per-tab tooltips). **A new row with a fixed label needs a `fieldTip`
  entry**: `every_row_label_has_a_tooltip` scans the sources. Ids come from a per-frame counter
  (`rowTipCount`, reset by `view`). Toolbar and panel buttons have theirs with the shortcut.
- **Arrow keys step a focused control** (`arrowSteps` in value_slider.odin: Right/Up +1,
  Left/Down -1, Shift ×10): `valueSlider`'s track (focusable, Tab reaches it; its thumb turns the
  accent color while focused), `numberField` (Up/Down only: Left/Right move the caret), the
  mixer's `fader` and `panControl`; Skald's own slider, and its `select` (Up / Down while closed:
  Skald 5fc513b). Tests: node_settings.script, particles.script.
- Inspector fields use tight padding (`InspectorFieldPadding`, 2 px vertical) and capped widths
  (`INSPECTOR_MAX_NUMBER_WIDTH` 120, `INSPECTOR_MAX_TEXT_WIDTH` 200). Position and Scale have a link
  toggle (`inspectorLinks`): a change to one axis scales the other by the same ratio
  (`LinkedAxis`; from 0 it moves by the same amount). Number widths leave room for that button:
  anything spilling into the reserved scrollbar strip is covered by the scrollbar and can't be
  clicked.
  **Every inspector row must fit `controlWidth`**: it happened twice (the link button, then the
  script Open button beside a dropdown held at its minimum width). Put extra buttons on their own
  row, and check a new button with a UI click in a narrow window.
- **A tab strip wider than its panel must scroll (`hScroll`), not overflow:** the bottom panel's
  tabs ran past the panel into the inspector beside it in a tiled window, unclipped, and a
  dropdown's choice there also clicked the tab under it (mixer.script caught it once Tiles and
  Timeline made seven tabs). The bottom tabs scroll sideways like the center's
  (`bottom-tabs-scroll`; a UI script wheels it to reach a tab out of view).
- **A closed dialog must build no content** (`closedDialog`, at the top of every dialog view):
  Skald hit-tests a widget by its rect from the last frame it was *built* in, not drawn, so a
  closed dialog's buttons stayed clickable where they had been (a viewport click where the Add
  Node dialog's "Sprite" row had been added a Sprite; smoke.script caught it once the header's
  layout moved a node there). Skald itself should check the widget was drawn last frame.
- **Skald's `draw_text` takes the baseline**, not the top: `drawTextTop` (view_viewport.odin)
  adds `text_ascent`. Drawn from the top, the top ruler's numbers showed only their bottoms.
- Type colors: node kinds use `kindColor` (scene tree rows and viewport markers); the browser uses
  `BrowserItemColor` (scenes blue, images like sprites, audio pink, fonts amber). Icons get the
  full color, labels `TintLabel` (the text color pulled 45% toward it); hidden nodes are muted.

## Architecture

### Layers

```
editor UI (Skald views)       renders State; emits Msgs
  └─ editor State             open project, selection, panels, viewport, play session
      └─ project model        plain Odin structs mirroring the XML (node kinds shared with the engine)
          ├─ serializer       project model <-> XML files (engine parser for reading)
          ├─ viewport preview the model rendered by the engine
          └─ play / exporter  the engine's player runs the saved project
```

The **project model** is the editor's data (`Project`, `SceneDef`, `NodeDef`, `AssetDef`). The
editor never edits live engine objects. It edits definitions, and the preview, the player and
exports build engine objects from them. This keeps saving, undo and export deterministic.

### Viewport (implemented)

**Rendering** (`viewport_preview.odin`, `gpu_share.odin`): the open scene is rendered by the
engine itself, so sprites, animations, text and menus look as they do in the game. Future engine
features (particles) appear without editor work.
- **On Skald's own GPU device, with no copy** (gpu_share.odin, 2026-10-22): SDL's Vulkan
  renderer is made on Skald's instance, device and queue (`skald.renderer_vulkan_handles`, SDL's
  `PROP_RENDERER_CREATE_VULKAN_*`; a hidden `{.HIDDEN, .VULKAN}` window it never presents to) and
  draws into a Skald image (`skald.image_create_target`, wrapped as an SDL render target through
  `PROP_TEXTURE_CREATE_VULKAN_TEXTURE_NUMBER`): `GPUTarget`. The canvas draws its used corner
  (`GPUTarget_Draw`: `draw_image_region(..., inset = false)`; targets only grow, rounded to 256).
  `Preview_Render` returns no pixels then (`Preview_Shared`). Drawing goes between
  `GPUTarget_Begin` / `GPUTarget_End`: End sets SDL's target back to the window, which moves the
  image to SHADER_READ_ONLY_OPTIMAL with a barrier and submits (SDL waits for its queue), and
  making it the target again starts with a barrier from fragment-shader reads: Skald's contract
  for target images, so no per-frame barrier on Skald's side. Everything is on the main thread,
  so the shared queue is never used twice at once. **SDL's resources must go before Skald's
  device:** `App.on_shutdown` (a Skald addition) runs `Preview_Destroy`, `CodeEditor_Shutdown`,
  `SharedGPU_Shutdown`. Measured (debug build, fullscreen 1059 x 555): a viewport render 1.7 ms
  median against 4.0 ms with the readback; pixel-identical to the OpenGL readback (the driver's
  `save_viewport_render`, read back on demand: `Viewport_LastRender`). Check: `render_path` in
  viewport.script. Skald's own test `image_target_shows_what_sdl_draws` renders a Skald view of
  such an image off screen and checks SDL's colors.
- **Fallbacks:** without it (`EDITOR_GPU_SHARE=0`, no SDL video, or SDL's Vulkan renderer can't
  use Skald's device) the engine draws with **a GPU renderer of SDL's** (SDL's choice: OpenGL
  here) owned by a hidden window of the preview's own, into a render-target texture, and the
  pixels are read back (`RenderReadPixels`); then the view uploads them with
  `skald.image_update_pixels` (or `image_load_pixels` when the size changes), drawn with
  `draw_image` inside a canvas.
  - **Software fallback:** without SDL video (unit tests, which run on several threads), when no
    GPU renderer can be made, or with `EDITOR_PREVIEW_SOFTWARE` set, it draws with SDL's software
    renderer into a surface, as it used to. That path was slower (90% of renders under 40 ms
    against under 7 ms on the GPU, measured zooming the forest fullscreen) and had its own bugs
    (the engine's LDtk tiles: cracks, then tiles vanishing after a zoom).
  - Growing the GPU target keeps the renderer, its game and textures (the software surface
    still rebuilds them).
  - The image is single-level (`image_load_pixels(..., mipmaps = false)`), so
    `image_update_pixels` streams it (Skald's fast path: no CPU mips, a staging buffer kept
    mapped, a fence instead of a queue wait): ~0.6 ms per update fullscreen, from ~12 ms. Checked
    by reading the GPU image back after streamed updates (zooming, animations): byte-identical
    to the render. The code editor's image is single-level too.
- **The upload was the expensive part** (Skald rebuilt mipmaps on the CPU and waited for the
  GPU on every update: ~4 ms optimized, ~46 ms in a debug build, for a 400x730 px viewport;
  ~12 ms for a fullscreen 1059x555 one; now ~0.6 ms, see above). Still:
  - the view only renders and uploads when `Preview_FrameKey` changes (scene, transforms, view,
    size, animation frame); other redraws reuse the image
  - animations run on a timer at `VIEWPORT_ANIMATION_FPS` (30): `Viewport_Tick` schedules the
    next tick itself, and stops when the window isn't focused (`EditorFocused`)
  - The cheap upload was a Skald change (no mipmaps, a reused staging buffer, no
    `QueueWaitIdle`: Skald's `mipmaps = false`). Sharing Skald's device (above) removed the
    upload and the readback altogether.
- The preview is package state, not `State`, because it holds SDL resources:
  - The engine scene is rebuilt only when the scene's structure changes (`sceneSignature`).
  - Transforms, visibility and layers are copied to the engine nodes every frame (`syncTransforms`).
  - The surface only grows.
- Engine APIs it uses: `Scene_DrawWithView` (the editor's pan/zoom replaces the game camera; labels
  and menus are scaled by the zoom), `Scene_Build` returning its nodes, `Node_GetLocalBounds`.
- `sdl.FlushRenderer` before reading the surface is required: SDL batches draw commands.
- Animations play in real time while `viewport.animate` is on (P). The view sends `Viewport_Tick`
  each frame then, to keep frames coming. **Game-code nodes will also update in the preview**; when
  game code arrives, they'll need an "in editor" flag so game logic doesn't run there.
- Opening a scene fits the game area to the view.

**View and overlays** (`view_viewport.odin`): a canvas with these overlays:
- rulers (top and left, in world units, following the mouse)
- the game frame, and each camera's view frame
- markers for nodes that draw nothing (Node2D, Camera)
- the selection box and the active tool's handles
- the zoom indicator and the mouse's world position

**Navigation and math** (`viewport_math.odin`, pure and unit-tested):
- `ViewportState` (center, zoom, view size, drag) is part of `State`.
- `Viewport_ApplyDrag` turns a drag into new local values through the parent's transform, so
  dragging works inside rotated or scaled parents.

**Input:**
- Left click picks the topmost node under the cursor, by bounds from the engine node or by marker,
  and starts a drag with the active tool.
- Tool handles: the move arrows constrain to an axis, the rotate ring rotates, the scale corners
  scale each axis separately.
- Shift constrains a drag.
- Wheel zooms around the cursor; Shift + wheel pans sideways, Ctrl + wheel up and down, and
  sideways scrolling always pans (`wheelAction`, `WHEEL_PAN_PIXELS` a notch). Settings > Editor >
  Wheel pans (`settings.wheelPans`, `viewport_wheel_pans`, for touchpads) makes the wheel pan and
  Ctrl + wheel zoom. Middle or right drag, Space + left drag, or the Pan tool (H, `Tool.Pan`)
  pans. viewport.script tests them (the driver's `scroll ... shift|ctrl|sideways`,
  `viewport_center`).
- Messages: `Viewport_Drag_Begin/Move/End`, `Viewport_Panned`, `Viewport_Zoomed`, `Viewport_Measured`.

**Keyboard** (`keymap.odin`): the chords are in `Settings.keymap` (two per action), with defaults
in the `[keymap]` section of `settings.default.ini`. `ACTION_KEY_RULES` says how each action's keys
behave (`viewportOnly`, `textChord`).
- Defaults:
  - Q W E R T Z H tools (T: transform, Z: zoom, H: pan), L the node's own axes, F frame selected,
    Shift+; guides
  - Ctrl+0 fit, Ctrl+1 100%, Ctrl+=/- zoom, P animations
  - arrows nudge (Shift ×10), Esc deselect, Delete
  - Ctrl+D duplicate, Ctrl+C/X/V copy/cut/paste nodes (not while typing)
  - Ctrl+Z undo, Ctrl+Shift+Z or Ctrl+Y redo (not while typing: the text field undoes typing)
  - F5/F6/Shift+F5 play controls, Ctrl+I import, Ctrl+, settings
- `KeymapDispatch` runs at the start of `view`, before the menu bar, so each shortcut fires once.
- **Plain keys are ignored while a text or number field has focus** (`IsTyping`), and are hidden
  from menu hints then.
- `viewportOnly` bindings (nudges) need the mouse over the viewport.
- Settings > Keyboard lists and edits the keymap (Help > Keyboard Shortcuts opens it there).
- **A new Action needs a line in `settings.default.ini`'s `[keymap]`** (a test checks), and an
  `ACTION_LABELS` entry. Don't add ad-hoc `skald.shortcut` calls.
- Tooltips and menu hints read the keymap (`actionTip`, `Keymap_Shortcut`, `keyParen` for text);
  never hard-code a shortcut in a label.
- **macOS: the keymap's Ctrl is Cmd.** Chords are stored once for every platform (editor.ini is
  portable): Ctrl means the platform's command key, Super the other one. `Chord_OnPlatform` swaps
  them on macOS for matching (`KeymapDispatch`, menu items, the code editor's passthrough) and
  `Chord_Format` names them (Skald's `shortcut_format`: Cmd, Option on a Mac); a captured chord
  goes back through `Chord_FromPlatform`. Clicks use `skald.PRIMARY_MODIFIER` (Cmd+click selects
  on a Mac, where Ctrl+click is a right click); Ctrl + wheel takes either. The code editor's own
  keymap uses Cmd there already. Test: `chords_follow_the_platform` (with `mac = true`).

### Project browser (implemented)

- **Search** (`browserSearch`): case-insensitive substring match on scene names and asset file
  names. While searching, only folders with matches are shown, and they're shown open.
  `BrowserRows` applies the filter, so row indices from the tree still map correctly in `update`.
- **Preview panel**: collapsible, with a resizable height (`previewHeight`).
  - Images are shown with `skald.image` fitted to the panel. The info line reads the image header
    with `stb_image.info` and adds the file size.
  - Sounds play through SDL3_mixer (`audio_preview.odin`), with a progress bar; `Preview_Tick`
    keeps frames coming while one plays. Selecting a sound loads it; selecting anything else
    unloads it.
  - If no audio device opens, the preview logs a warning and stays silent.
  - **Scripts** (`scriptInfoPreview`): each script the file registers (`Script_Register(Name`
    found in its text: `ScriptFile_Registrations`, no build needed) as a global (in
    Project Settings > Globals) or a node script with the nodes it's attached to (buttons:
    `Script_Usage_Clicked` opens the scene or component and selects the node), its fields once
    built; each data type (`Data_Register(Name`) with its resource count. The file's contents
    are the code tab's.
  - **Scenes** (`scenePreview`): start scene, file, nodes by kind, camera, scripts and components
    used, Open / Play Scene / Set as Start, and the scene's own settings (below).
  - A double-click opens an LDtk project in LDtk (like Open in LDtk); on a component, its tab.
  - **Preview text wraps** to `previewTextWidth` (the browser's width less padding, set by the
    browser body's `sized` before the preview is built): every preview's `skald.text` gets
    `max_width = previewTextWidth`, and the script preview's node rows are clickable text, not
    buttons (a button's label doesn't wrap).
- **A scene's own settings** (`SceneDef.settings`, the engine's `e.SceneSettings`, on the scene
  file's root element; scene_settings.odin): screen layers (drawn without the camera: HUDs,
  menus), its own background (the viewport draws it too), its own gravity. Each edit is a
  `.Project` undo step (the snapshot holds every scene; `projectSnapshotsEqual` compares
  settings). Components have none. Test: `tests/ui/scene_preview.script`.
- **Import** (Ctrl+I or the + button): Skald's native dialog with `allow_many` (several files at
  once: `File_Dialog_Result.paths`), opening in the folder of the last import
  (`Settings.importFolder`, editor.ini's `import_folder`, written when it changes). The dialog's
  callback (`importDialogResult`) copies the paths to the frame's memory and frees Skald's, so
  `Asset_Import_Result` never owns them (tests and the driver send it with their own strings);
  `importChosen` imports each, converting sounds games can't play first.
  - `Project_ImportAsset` detects the kind from the extension and copies the file into
    `assets/`, renaming it to `name_1.ext` and so on if the name is taken.
  - A file already inside the project folder is referenced, not copied.
- **Remove** (trash button): a dialog shows how many nodes use the asset, and offers "Remove from
  Project" (the file stays) or "Delete File".
- Imports and removals change `project.assets`, which is written to project.xml on Save or Play.
  Copying and deleting the files happens immediately.

### Adding nodes (implemented, `add_node.odin`, `view_add_node.odin`)

Add Node (Ctrl+Shift+A, the scene tree's + button, Edit menu) opens a dialog listing every
`SceneNodeKind` with its description from the engine's `SCENE_NODE_KINDS`. A new kind in the engine
shows up here with no editor change (it still needs inspector fields).
- The search box has focus when it opens and filters by name, description or category,
  case-insensitive.
- Kinds are listed under their category's header (the engine's `SceneNodeCategory`: Scene,
  Graphics, User interface, Physics, Sound), in a scroll (`add-node-scroll`) as tall as the window
  allows. `AddNode_Kinds` returns them in that order, which the highlight indexes.
- Up/Down move the highlight and scroll it into view (rows and headers have fixed heights, so
  its position is known without layout: rows scrolled out of view keep stale rects), Enter or a
  click adds that kind, Escape cancels. add_node.script tests it.
- The node becomes a child of the selected node (top-level when nothing is selected), is named
  after its kind (`Sprite`, `Sprite2`, ...), and is selected.
- While any modal dialog or the scene tree's context menu is open, `KeymapDispatch` registers
  nothing and the menu bar drops its shortcuts (it registers them itself, and Edit > Deselect would
  take Escape). Add new dialogs' open flags to `keysTaken` in `view`.

### Scene tree editing (implemented, `node_edit.odin`, `view_inspector.odin`)

- **Subtrees** (`node_edit.odin`): a copied subtree is a node list in depth-first order with
  parents relative to the list (the root's is -1). `Scene_CopySubtree`, `Scene_PasteSubtree` (last
  child of a parent), `Scene_DuplicateNode` (next sibling). Pasted and duplicated roots get a free
  name via `Scene_UniqueNodeName` ("Ship2" -> "Ship3"); their descendants keep theirs.
- **Clipboard**: `State.clipboard`, editor-internal (not the system clipboard). Copy, Cut and Paste
  are Ctrl+C/X/V, Duplicate Ctrl+D. These are `textChord` bindings: skipped while typing, so text
  fields keep the chords. Paste goes into the selected node, or the top level.
- **Context menu**: the editor's (context_menus.odin, below): a right press on a row sends
  `Context_Menu_Opened{Ctx_Node}` (selecting it unless it's in the selection), below the rows
  `Node_Right_Clicked(-1)` and `Ctx_Tree`.
- **Drag to move** (`sceneTreeMouse`): a press on a row records `treeDrag`; moving
  `TREE_DRAG_THRESHOLD` px starts the drag. Top/bottom quarter of a row = before/after it as a
  sibling, the middle = its last child, below the rows = last top-level node. The bottom edge of an
  open parent means before its first child. A line or box overlay shows the spot.
  `Scene_MoveNode` rebuilds the depth-first order and keeps the node's world transform under its new
  parent. A node can't go into its own subtree (`Scene_CanMoveNode`). Near the top or bottom edge
  the tree scrolls (`Frame_Requested` keeps frames coming while the mouse is still).
- **Inline rename** (F2, double-click, menu): `State.rename` plus an overlay `text_input` pinned
  over the row (`sceneTreeRename`). Enter or losing focus commits (`Rename_Committed`, undoable),
  Escape cancels. The double-click's click count is hidden from the tree, which would otherwise
  expand or collapse the row.

### Scenes (implemented, `project_scenes.odin`, `scene_actions.odin`)

- **Browser context menu** (`browser-menu`, built by `browserMenuItems`; the messages for its items
  are in `browserMenuMsgs` because the callback can't capture): on a scene Open, Play Scene, Rename,
  Duplicate, Copy, Cut, Paste, Delete, Set as Start Scene, New Scene; on the Scenes folder or empty
  space New Scene and Paste; Remove for assets, Open in Editor for scripts. A right-click selects
  the row first (`Browser_Right_Clicked`) without opening it, and focuses the browser.
- **Keys:** while the browser tree has focus (`State.browserFocused`, reported by the view with
  `Browser_Focus_Changed`), `Browser_RouteAction` turns Delete, Ctrl+D/C/X/V and F2 into scene
  operations on the selected scene; otherwise they act on nodes. `History_Classify` uses the same
  routing.
- **Rename** in place (F2, double-click, menu): `State.rename` with `target = .Scene`; the overlay
  is `browserRename` and shows why a name is refused (`SceneNameProblem`: empty, not a file name,
  taken). `Project_RenameScene` updates the start scene, Menu `scene:<Name>` actions and scene-kind
  script fields. After Enter or Escape, focus returns to the tree (`State.refocus`); a commit from
  clicking elsewhere leaves focus where the click put it.
- New scenes get a World node and are named straight away. The last scene can't be deleted;
  deleting the start scene makes the first remaining one the start; deleting the open scene opens
  the one before it. Dangling menu references are reported, not changed.
- **Files:** `Project.sceneFiles` lists the scene files the editor loaded or saved;
  `Project_CleanSceneFiles` (end of `Project_Save`) deletes those no scene uses any more. Other
  files in `scenes/` are never touched.
- **Undo:** scene operations and Project Settings are `.Project` edits: the undo step holds a
  `ProjectSnapshot` (every scene, the start scene, name, size, scaling, background, open scene).
- **Play Scene** (Ctrl+F5, the toolbar's second play button, Scene menu, a scene's menu) runs
  `player <project> --scene <name>` (the engine's `Player_ParseArgs`); Play (F5) uses the start
  scene. The start scene is chosen in **Project Settings** (File menu, `Open_Project_Settings`) or
  with Set as Start Scene, and shows as "(start)" in the browser.

### Multi-selection (implemented, `selection.odin`)

- `State.selection` is every selected node (sorted); `selectedNode` is the primary one, which the
  inspector edits and the tool handles sit on. `update` runs `Selection_Normalize` before and
  after every message: setting only `selectedNode` (a plain click) makes a one-node selection.
- Code choosing several nodes calls `Selection_Set` / `Selection_Toggle`, which set
  `selectionSet`. After a `.Scene`-scope edit (nodes renumbered), `update` drops the selection
  unless `selectionSet` is true.
- Viewport: Ctrl+click toggles, Shift+click adds, a drag on empty space is a box select
  (`DragMode.Box`, `ViewportNodesInRect`; Ctrl/Shift adds). Clicking a node of a multi-selection
  keeps it (`Node_Primary_Picked`) so the drag moves all. Tree: Ctrl+click toggles, Shift+click
  selects the range from the primary row; the press is hidden from the tree. Ctrl+A selects all.
- Edits act on `Selection_Roots` (selected nodes without a selected ancestor): Delete, Cut, Copy
  (`Scene_CopyNodes`, several roots in one list), Duplicate (`Scene_DuplicateNodes`), Paste (every
  root), nudges. A viewport drag applies the tool to the dragged node and `Viewport_FollowDrag`
  gives the others the same movement, rotation and scale factor. Multi-node drags and nudges are
  `.Scene`-scope undo steps. Undo/redo restore only the primary node.

### Viewport grid and snapping

- **The grid is the project's** (`Project.grid`, the engine's `e.GridSettings`, project.xml's
  `<grid>`, written when not `e.DEFAULT_GRID_SETTINGS`; in the `.Project` undo snapshot), so a
  team shares it and tilemaps can use it later. Project Settings > **Grid** edits it
  (`Project_Settings_Grid_Changed`, `GridTarget`; View > Grid Settings opens it:
  `Open_Grid_Settings`). Older editor.ini files' `grid_*` keys are skipped.
- `viewport.gridVisible` (G, on by default) draws lines every cell (width and height, world
  units), a major line every `majorEvery` cells (0 = none), each at its opacity (`opacity`,
  `majorOpacity`, percent of the theme's text color); the axes are brighter. Zoomed out, cells
  double until 8 px apart, majors with them. `viewport.snap` (Shift+G) makes
  `Viewport_ApplyDrag` put the node's origin on the grid, rotation on 15° steps and scale on 0.1.
  Toolbar toggles sit in the viewport header. A multi-selection keeps its layout: only the
  dragged node snaps. usability.script sets a 16 x 24 grid, saves it and snaps to it (driver
  check `project_grid`).
- The game area is outlined in a subtle red (`GAME_FRAME_COLOR`), apart from the grid and the
  camera frames.
- **The grid is dark gray** (`GRID_LINE_COLOR`, `GRID_MAJOR_COLOR`, `GRID_AXIS_COLOR`; the user's
  choice, 2026-10-22: apart from the editor's own colors), the project's opacities applied to them
  (the engine's defaults are 60 and 90 since).

### Dragging images into the viewport

A press on an image row in the browser, then moving, starts `assetDrag` (`browserDrag`, with a
label following the cursor); releasing over the viewport sends `Asset_Dropped` with the world
point. `Scene_AddSpriteAt` adds a Sprite named after the file, as a child of the selection,
positioned at that point in the parent's space. Undoable.

### Project session (implemented, `project_session.odin`, `view_project_dialogs.odin`)

- Unsaved changes: `history.version` (bumped by every push, merge, undo and redo) differs from
  `session.savedVersion`, or `session.assetsChanged` (imports and removals aren't in the history).
  Save and Play call `Session_MarkSaved`. The status bar shows Modified/Saved; the window title
  gets a `*` (`Session_UpdateTitle`, through SDL, only when it changes).
- Quit (Ctrl+Q, and the window's close button through `App.on_close_request`), New and Open go
  through `Session_Request`: with unsaved changes it opens the "save changes?" dialog
  (Save / Don't Save / Cancel) and runs the action after. The UI test driver quits with
  `Quit_Without_Asking`.
- New Project: a name and location (Browse uses `cmd_open_folder_dialog`); creates
  `<location>/<name>` with `Project_CreateEmpty` (a Main scene with a World node) and opens it.
  Open Project: a folder dialog, then `Project_Load`. `switchProject` resets everything that
  belonged to the old project, including the undo history.
- **Save Project As** (Ctrl+Shift+S, `Session_OpenSaveAs`: the New Project dialog with
  `newProject.saveAs`): `saveProjectAs` copies `Project_OwnFiles` (project_archive.odin: the
  archive's rules, so no `export/`, `build/`, `.git`, export output folders) into the new folder,
  writes dirty code tabs' text there, points the in-memory project at it (name too) and
  `Project_Save`s it, then `Session_OpenProject`s the copy (history starts fresh; the original
  on disk stays as saved). Outside assets keep their paths and are warned about. Test:
  `save_as_copies_the_project_and_opens_the_copy`, `tests/ui/save_as.script` (the copy goes
  inside the scratch project, made fresh each run). User guide: `docs/manual/projects.md`.
- **Recent projects** (recent_projects.odin, `State.recentProjects`): `recent_projects.txt` beside
  the settings file (none without one), absolute folders, most recent first, at most 10;
  `switchProject` and `init` add the opened project. File > Open Recent (a Skald submenu,
  `Menu_Item.submenu`; disabled with none) lists `Recent_Shown` (8, not the open one) and Clear
  Recent Projects;
  `Recent_Project_Chosen(index)` goes through `Session_Request(.Open_Recent)` (the path waits in
  `session.recent`); a folder without project.xml is reported and dropped. Driver: `send
  Recent_Project_Chosen <i>` (the menu bar can't be clicked), check `recent_menu <i> <name>`.

### Project archives (implemented, `project_archive.odin`, `zip.odin`)

A project in one file: a zip with the extension `.odinsdl` (`PROJECT_ARCHIVE_EXTENSION`) holding
one folder, the project folder's name (`Game/project.xml`, ...). Its doc comment has the rules.
- **Export Project Archive** (File menu): a save dialog, then `Session_Save`, then
  `ProjectArchive_Create` on a worker (`ProjectArchive_Input` copies what it needs). Left out:
  `export/`, `.git/`, `build/`, every export target's output folder, OS clutter, the archive
  itself. **Assets outside the folder** (`../x.png`, absolute) go to `assets/external/` and the
  archive's text files (`.xml`, `.json`, `.odin`, `.ini`) get the quoted old path replaced; the
  project on disk keeps its paths.
- **Open Project Archive**: the unsaved-changes prompt (`PendingAction.Open_Project_Archive`), an
  open dialog (`.odinsdl`, `.zip`), a folder dialog (default: the archive's folder), then
  `ProjectArchive_Extract` on a worker into `<folder>/<top folder>` (`_2`... when taken), then
  `Session_OpenProject`. A zip with `project.xml` at its top works too (folder: the zip's name).
  Names with `..`, absolute, with `\` or `:` are refused before anything is written.
- **With History** (Action.Export_Project_Archive_With_History): the same, `.git/` included
  (`ArchiveInput.includeGit`, from `state.archive.includeGit`).
- **On the command line** (`odin_sdl_editor game.odinsdl`, or a `.zip`): `init` unpacks it next
  to itself (`ProjectArchive_ExtractArgument`, `_2`... when the folder is taken) before loading,
  and opens what it unpacked (checked by hand: a fixture archive given to the built editor).
- **Why stored, not deflated:** Odin's core library inflates (`core:compress/zlib`) but has no
  deflate encoder, and a project is mostly PNGs and compressed audio. No zip64 (65535 files, 4 GB).
- Tests: `zip_round_trip_and_safe_names` (round trip, CRC catches damage, a Python-made deflated
  zip `tests/fixtures/deflated.zip`, zip slip names), `project_archive_brings_outside_assets_in`
  (left-out folders, rewritten paths, opens with `Project_Load`, `_2`, refusals);
  `tests/ui/project_archive.script` (unsaved edit saved first, archive, unpack, open; `unzip -t`
  accepts the archive). The driver's `archive_project <path>` and `open_archive <a> | <folder>`
  stand in for the dialogs.

### Version control (implemented, `vcs.odin`, `view_git.odin`; the bottom panel's Git tab)

Git through the `git` program (`Script_FindEditorProgram`; Settings > Toolchain has a row).
`vcs.odin`'s doc comment has the behavior; what the code relies on:
- **The tab shows a `GitSnapshot`**, read on a worker (`Git_ReadSnapshot`: rev-parse, status
  `--porcelain=v1 -z --branch -- .`, log, branch, remote) into its own arena, replaced whole.
  Reads are asked for by `Git_View_Tick` (the view, every frame) when the snapshot is unknown or
  `stale`: saves (`Session_Save`) and `switchProject` set `stale`, since they can't return
  commands; showing the tab and every command's end refresh directly. A snapshot read for another
  folder (the project changed meanwhile) is dropped and read again.
- **Paths are the project's**: commands run in the project folder with `-- .` pathspecs, and
  porcelain paths (relative to the repository) lose the project's prefix. A project inside a
  repository that ignores it (`check-ignore`, like `build/ui_project` in this repo) counts as not
  under version control: Initialize makes it its own repository.
- **Commands** (`GitOp`, `Git_Commands` lists the git calls, `Git_OpProblem` refuses bad input)
  run one at a time on a worker (`Git_RunCommands`), env `GIT_TERMINAL_PROMPT=0`,
  `GIT_MERGE_AUTOEDIT=no`, `GIT_SSH_COMMAND=ssh -o BatchMode=yes` (unless set) and no stdin, so
  nothing waits for a password. Saved first; Pull and Switch_Branch (`Git_ChangesFiles`) open the
  project again from disk. Unstage before the first commit is `git rm --cached` (no HEAD to reset
  to). Commit with nothing staged runs `git add -A -- .` first.
- **Layout:** the history column is left out under 720 px (a tiled window), so the commit
  controls keep their width.
- Tests: `git_init_stage_commit_branch_push` (a real repository in build/: init, stage and
  unstage, commits, branches, a bare remote for push, upstream and ahead counts; sets
  `GIT_AUTHOR_*` since CI has no identity) and `tests/ui/git.script` (the Taskfile's UI tasks set
  `GIT_AUTHOR_*` / `GIT_COMMITTER_*`). The branch list is a dropdown: the driver's `send
  Git_Switch_Branch <name>` picks one.
- **Diffs:** a change's path shows `git diff HEAD` (a new file: its lines as added;
  `Git_ReadDiff` on a worker) on the right instead of the history, or instead of the changes in
  a narrow panel. **Discard** (↶ before the path, asked first: `gitDiscardDialog`): `git restore
  --source=HEAD --staged --worktree`; a new file is deleted (`Git_DiscardDeletes`, done by
  `Git_RunCommands` after git lets go of it). Rows put their buttons before the path: rows in a
  scroll aren't width-limited, and a long path pushed them out of a narrow panel.
- **Merges:** Merge... (`git merge --no-edit`); conflicts stop it (`snapshot.merging`, from
  MERGE_HEAD): conflicted files (UU, AA...) get Keep mine / Take theirs (`git checkout
  --ours|--theirs` + add), Abort Merge (`git merge --abort`); the Commit after resolving ends it.
  The project is read again after merges, discards, aborts and that commit, never while a merge
  is half resolved (other files still have conflict markers). `gitRun` keeps stdout and stderr
  on failure (a merge prints CONFLICT on stdout).
- **Git LFS:** with git-lfs installed and not in use, Use Git LFS runs `git lfs install --local`
  and tracks the asset patterns (`GIT_LFS_PATTERNS`, .gitattributes). Not checked by hand: this
  machine has no git-lfs (the unit test checks the refusal).
- **The status bar** shows the branch (ahead / behind, merging); a click opens the Git tab.
- Tests: the unit test also diffs, discards, merges with conflicts resolved both ways and
  aborted (rerere off in its repository); git.script diffs, discards and merges (a fast-forward).

### Status bar frame stats

`FrameStats` (view.odin) counts the frames drawn per second and times the last viewport render and
upload; the status bar shows them. The editor only draws when something changes, so while idle
they show the last busy moment.

### Play mode (implemented, `play.odin`)

Play runs the project in a **player** (`e.Player_Run`), a separate program that loads `project.xml`
and runs the start scene. A crashing game can't take the editor down, and the player is the same
runtime exports will ship.
- A project **without scripts** uses the prebuilt player next to the editor when there is one
  (`Toolchain_PrebuiltPlayer`, `PlayerTarget.prebuilt`: nothing is compiled), else the engine's
  `<engine>/player` (`build/player/player`).
- Compiling uses `Toolchain_Odin` (Settings > Toolchain's path, PATH, the editor's install); with
  none, Play fails with a message pointing at Settings > Toolchain.
- A project **with scripts** (`.odin` files in `scripts/`) gets its own: `playerTarget` writes a
  generated `main.odin` (`playerMainSource`) into `build/players/<project>-<hash>/`, which imports
  `engine:.` and `project:scripts`, built with `-collection:project=<project folder>`.

1. Save the project (`Project_Save`).
2. If the player is missing or older than any `.odin` file it's built from (engine, scripts, the
   generated main), build it. Unoptimized unless `settings.optimizedPlay` (about 4 s against 50 s
   with `-o:speed`). Output goes to the **Output** tab.
3. A project player then runs with `--describe-scripts` (stage `.Describing`); its JSON becomes
   the script catalog (`ScriptCatalog_Parse`), shown by the inspector.
4. Run `player <absolute project folder>`. Its output goes to the **Console**: the engine's
   logger writes `[LEVEL] [category] text` and `parseLogLine` (`e.Log_ParseLine`) gives each line
   its level and category; other lines are "game" Info lines (compiler-looking errors: Error).
   See "The Console" below.

**Build Scripts** (Ctrl+B, and once in the background when a project with scripts opens) does steps
2-3 only. `PlaySession.purpose` says which; `.Describe` is its zero value on purpose, and it must be
carried across `endSession` between steps (losing it once made describing start the game).

### The Console (implemented, `console.odin`, `view_bottom.odin`; engine: logging.odin)

console.odin's doc comment describes it; what the code relies on:
- **Lines carry a level and a category index** (`LogLine.category` into `LogList.categories`,
  kept after Clear so the menu still lists them). `logLine` (the editor's ~250 calls, category
  "editor" by default), `outputLine` ("build"; exports pass "export"), the game's lines (Play's
  `emitLine`: the parsed category, else "game"), plugins ("plugin").
- **The limit** (`Settings.consoleLimit`, `console_limit`, 5000; Settings > Editor) is applied on
  every append (`LogList_Trim`) and when Settings apply. Kept lines are `lines[start:]`; the
  array is compacted when `start` reaches half of it. **Use `LogList_Lines`**, never `lines`.
  `serial` numbers lines across drops: the line menu's `Ctx_Log.line` is a serial, so a menu
  opened before lines were dropped still copies the right one.
- **Only visible rows are built:** `logView` filters (`LogList_Shown`, every frame: levels,
  hidden categories, an ASCII case-folding search) and hands the indexes to `skald.virtual_list`
  (fixed rows of `logRowHeight`); rows' widget keys are `<list>-line-<index>`, their state keyed
  by serial. Measured (debug build, fullscreen, Intel UHD 620, `frame_times` with
  `SKALD_BENCH_UNCAP`): before, a column of every line: 7.6 ms a frame empty, 98 ms with 1000
  lines, 5.3 s with 5000; now 8.4 ms empty, 10.5 ms with 1000, 10.6 ms with 5000, 12.9 ms at the
  limit with 10 new lines a frame, 11.3 ms searching.
- **Following** is view-side: `logFollow` reads the list's Skald scroll state before
  `virtual_list` builds. Following: it sets the offset to the end (and `reveal_row` the last row,
  for the first frame after the list was hidden: Skald resets a state not drawn last frame). The
  offset moving up while following sends `Log_Follow_Set{false}`; moving to the end while paused
  `{true}`; the header's toggle is `Log_Follow_Toggled`. Paused, the top row's line stays at the
  top as lines are dropped or filters change (`logScrollSeen`: its serial and offset).
- **The category menu** is a context menu target (`Ctx_Log_Categories`, opened by the header's
  button at its corner); `Log_Category_Toggled` sets `ContextMenu.keepOpen`, so the
  `Context_Menu_Closed` the popup sends after an item is ignored once and several can be picked.
- Nothing here is undoable (not in `History_Classify`).
- Driver: `console_fill <n> [Level [category]]` (`Log_Test_Lines`), `frame_times <frames>
  [lines]`; checks `console_lines`, `console_shown`, `console_following`, `console_first`,
  `console_category`, `console_line_category`, the `output_*` ones, `setting console_limit`.
  Tests: `console_test.odin`, `tests/ui/console.script` (the controls, the limit, a game with a
  script logging with categories and levels). User guide: `docs/manual/getting_started.md`
  (the Console), `docs/manual/scripts.md#logging`.

### Built-in code editor (implemented, `code_editor/`, `code_editor_host.odin`, `code_tabs.odin`)

Scripts open in code tabs after the scene tabs (`State.codeTabs`, absolute paths; `codeTab` is
1-based, 0 = the scene shows). `Script_Open` is the one way to open a script: a tab with
`settings.builtInCodeEditor` (Settings > Editor, `code_editor_builtin`, on by default), else the
external program (`Script_OpenInEditor`). Picking a scene tab, or anything that changes
`currentScene` (`update` resets `codeTab`), shows the scene.
- **Rendering:** the code editor draws with an SDL renderer: the shared GPU renderer
  (gpu_share.odin, as the viewport) straight into the tab's image (`host.target`, key
  `CODE_IMAGE`, one for whichever file shows; `CodeEditor_OnGPU`, driver check
  `code_render_path`); its text goes through SDL_ttf's renderer text engine
  (`atlas_text` in code_editor's render.odin, one glyph atlas per renderer, freed by
  `ce.editor_forget_renderer` before the renderer goes): a texture made per run of text was
  cheap in software, but SDL's Vulkan renderer uploads and waits for each. A fullscreen render
  went from 12.1 ms (software, with its upload) to 2.8 ms median (debug build, code_keys.script).
  Without the shared renderer each open file has an SDL software renderer on a surface. Only the
  shown one is rendered, and only when
  what it shows may have changed (`codeRenderKey`: size, text version, carets, scroll, the
  server's answer counters; or input reached it, a server reply is waiting, it was reloaded or
  just came to the front), at least every `CODE_RENDER_REFRESH` (0.5 s) for anything else. A
  full render takes about 11 ms fullscreen: done every frame, it took most of a 60 fps frame
  (measured with the editor running: 60 renders a second before, 2 after). It's uploaded into
  one Skald image only when its pixels' hash changed. It's drawn at the
  display's pixel scale (font size × `ctx.renderer.scale`).
- **Input:** Skald has no raw-event hook and folds a frame's keys into a set, so an SDL event
  watch (`sdl.AddEventWatch`) copies every key, text and mouse event as SDL queues it; the code
  view hands them on (keys and text with focus, the mouse over it in its pixel coordinates, a
  drag's end). Focus is Skald's (`focused_id == hash_id("code-editor")`); Skald's Tab traversal
  takes it before `view`, so `CodeEditor_Frame` gives it back; `IsTyping` counts it, and
  `KeymapDispatch` runs only `CODE_EDITOR_PASSTHROUGH` then (their chords don't reach the code
  editor); the menu bar drops its shortcuts.
- **Unsaved scripts** count in `Project_IsModified`; `Session_Save`, Play and Export call
  `CodeTabs_SaveAll` first; Save starts a background script build when a script was saved.
- **Language server:** `Code_FindOLS` (the setting `ols_path`, PATH, `code_editor/third_party/ols`
  from `task ols`, Zed's extension), rooted at the scripts folder (its ols.json). **One for all
  tabs**: a `ce.Editor` owns its client by value, so the client (with its supervisor) moves to the
  editor that shows (`takeServer`); hidden editors have it off and get no input, so they have
  nothing to send. The receiver resends its whole text (`lsp_need_full`) and reopens its document
  if the server process changed (`openedIn`, the pid it was opened in). Closing a tab sends
  `didClose` (`releaseServer`); the last tab stops the server. `Code_Tick` (0.1 s with a server,
  1 s without, while the window is focused) keeps frames coming for replies and the disk check.
- **The language server's view of the scripts** (OLS, rooted at the scripts folder: checked
  with a headless LSP session to complete same-file structs in Script_Register's proc
  literals, other files' types and `e.`): it doesn't see a file of the package created or
  rewritten while it runs (New Script, the regenerated assets.odin, git) until told, so
  `CodeEditor_WatchScripts` (from the code view and Code_Tick, at most once a second: ticks only come while the window has the keyboard, and a file written meanwhile was never announced: code_editor.script failed whenever its window opened unfocused) sends
  `workspace/didChangeWatchedFiles` for the folder's .odin files that appeared, changed or went
  (files open in a tab excepted). And text the host inserts (`CodeEditor_InsertAtLine`: node
  fields, listeners) reaches it once: `editor_notify_lsp_changed` drops the queued incremental
  edits its full text already carries (they were sent again, doubling the inserted code on the
  server and breaking completion). code_editor.script writes a new file and completes its
  struct (`code_completion_has`); the code editor's sync_shadow_test.odin replays what the client
  sends after every kind of edit and compares it with the buffer.
- **Files changed on disk:** the modification time is kept at open, save and reload; the shown
  file is looked at once a second and as soon as its tab shows again (`CodeEditor_DiskChange`):
  unchanged buffers reload (caret kept), dirty ones get the bar over the code (`CodeTabs_DiskBar`:
  Reload / Keep mine, `Code_Disk_Chosen`). A hidden tab's reload keeps its document open on the
  server (it resends the text when it shows).
- **Completion rows show fields as code declares them** (`speed: f32` then the field's comment;
  code_editor's render_popups.odin, `completion_row_parts`): OLS sends a field's type and comment
  only in its documentation (`Hero.speed: f32`, `---`, the comment), so they're read from there,
  and fields get no "field" tag; the text on the right starts in one column. The kind column is
  left out when no row has a tag.
- **Auto-closing pairs** (code_editor's buffer/autopairs.odin, `Editor.auto_close_pairs`, set
  from Settings > Editor > Auto-close, `code_editor_auto_close`, every frame in
  `CodeEditor_View`): typed brackets and quotes close; `<` only after a word (or in XML); the
  closer steps over; Backspace removes an empty pair; Enter between brackets indents. Only typed
  text (TEXT_INPUT, one character) goes through it: what the host inserts (node fields,
  listeners) doesn't. code_editor.script types and checks it.
- **Overlays fit the code view** (code_editor's overlay_scroll.odin; its README's "Overlays in a
  small editor"): popups, menus, the palette and the problems / references panel fit the tab's
  height and width (a tiled window's tab is about 300 px wide), scroll what doesn't fit (wheel,
  keys, clicks through the scroll) and show a scrollbar then. Found doing it: code actions past
  the 8th couldn't be reached, references clicks used the problems panel's scroll, a click on the
  completion docs closed the list, the wheel over the palette scrolled the code.
- **Its own settings persist:** `ce.editor_set_config_dir` with `code_editor/` next to editor.ini
  (keymap.json, theme.json: the code editor's Keymap Editor, Theme Editor, "Color Theme"). Test
  runs without `--settings` keep none. A light editor theme starts the code on Ayu Light until a
  theme is saved.
- **Tabs** (scenes, components and scripts: `editorTab`) look like `skald.tabs`' (its fill, text
  colors, padding, font, underline; copied from view.odin's `_tabs`, with the × inside the tile):
  they're our buttons because Skald's tabs have no close button. Keys `scene-tab-<i>`,
  `scene-tab-close-<i>`, `code-tab-<i>`, `code-tab-close-<i>`. **Scene tabs close**
  (`Scene_Tab_Closed`): a scene's `SceneDef.tabClosed` (zero = open, so every scene starts with a
  tab; components keep `opened`), the scene stays; closing the one that shows shows its
  neighbour; the last tab has no ×; anything that changes `currentScene` opens its tab again
  (`update`). When the view's buttons leave the tabs under `CENTER_TABS_MIN_WIDTH` (200 px: the
  tiled window's center is about 300), the tabs get a header row of their own (`centerHeader`).
- **Every keymap command is tested** (`tests/ui/code_keys.script`): moving, selecting, cursors,
  editing, lines, clipboard (the driver puts the user's clipboard back), undo/redo, find/replace,
  zoom, the palette and its windows, completion, signature help, definitions, peek, references,
  navigation, diagnostics, quick fixes, problems, Save / Save As / Open, and the palette's Zed
  and VS Code keymap imports (fixtures in `code_editor/example/assets/keymaps`). Found and fixed
  doing it: the find bar swallowed F3/Shift+F3 (code_editor's find.odin), Tab indented with
  spaces (`Editor.indent_with_tabs`, on for .odin), Ctrl+0 didn't reset the zoom (the host reset
  the base size every frame), Save As and Open did nothing (the host now answers them with file
  dialogs: `Code_Dialog_Requested`; `code_dialog_pick` in tests), the code editor's status
  messages were hidden with its header (now in the status line), and a tab coming to the front
  now reloads the keymap and theme another tab changed. Driver: key events' key codes are the
  unshifted ones (`GetKeyFromScancode(..., true)`, as real events: Ctrl+Shift+letter chords
  failed), `code_state <json path>` reads the code editor's control-package snapshot.
- **The test driver** had to send what real input sends: `type` is one TEXT_INPUT per character
  (the code editor completes after a typed "."), and key events carry the key code
  (`GetKeyFromScancode`: the code editor reads key codes, Skald scancodes). `click_tab` clicks a
  `skald.tabs` tab (sub-ids of the strip).
- The center panel's tab strip scrolls sideways (`hScroll`, key `center-tabs`) and scrolls the
  tab that shows into view when it changes (`hScroll_Reveal`); the caret and the language server
  are in the status line under the code, so the header keeps its room for tabs.
- Tests: `code_tabs_open_switch_close` (no OLS: `olsPath` set to a missing file),
  `tests/ui/code_editor.script` (typing, Tab, Delete and Ctrl+Z staying in the code, OLS
  completion, saving, tabs, the close prompt, the external fallback; driver checks `code_tabs`,
  `code_tab`, `code_focused`, `code_contains`, `code_dirty`, `code_caret`, `code_rendered`
  (pixels unlike the background, uploaded), `code_lsp`, `code_completion`, `code_close_dialog`).
- **Looking at it:** `save_code_render <file.png>` (driver) writes the code editor's own pixels
  (its surface, not the screen). The rest of the UI can't be captured: Skald's offscreen renderer
  (`render_view_to_pixels`) is private.
- **Unit tests and package state:** the code editor tests take `previewTestLock` (SDL_ttf isn't
  thread-safe) and end with `CodeEditor_Shutdown`: each test has its own allocator, freed after
  it, and the editors' list allocated by one test crashed the next (and corrupted others' data).
  `testState` turns the built-in editor off; "unsaved scripts" and closing all look only at a
  state's own tabs; the event watch is installed by the first code view, not by opening a file.
- Tests also: `code_editor_settings_persist_and_disk_changes`; the script's disk steps
  (`touch_project_file`, `code_disk_conflict`) and shared server (`code_servers`).

### Scripts (implemented, `scripts.odin`, the inspector's Script section)

- `NodeDef.script` and `props` (name/value text, only values that differ from the field's default)
  are written as `<script name><prop name value/></script>` (format version 3).
- The catalog (`State.scripts`: status Unknown/Building/Ready/Failed, and each script's fields)
  comes only from builds. Before one, nodes keep their script and values; the inspector lists the
  stored values read-only.
- Inspector: a dropdown of built scripts (or None), New (the New Script dialog: name, then
  `Project_CreateScript` writes `scripts/<snake_name>.odin` from `ScriptTemplate`, attaches it,
  opens it and builds), Open (`Script_OpenInEditor`: an `os.Process_Desc` with the program as
  `command[0]` and the arguments template after it, `env = os.environ()`, `working_dir` = the
  project's scripts folder, and the editor's own stdout/stderr; `Editor_Process_Check` polls for
  10 s and reports a program that exits with an error). Fields by type: number fields (`ScriptPropTarget`), checkbox, text or scene dropdown
  (`kind=scene`), two numbers for vectors, color picker, enum dropdown. All undoable.
- Browser: a Scripts folder (only when there are scripts; `State.scriptFiles`, refreshed by
  `Scripts_Refresh`) whose preview shows the file's start and an Open button.
- Scripts don't run in the viewport (`Scene_Build(..., attachScripts = false)`).
- **Events and listeners** (node_listeners.odin, view_inspector_events.odin; the engine's
  node_events.odin): the inspector's Events section lists the node's events
  (`e.SceneNodeKind_Events` of `NodeDef_BuiltKind`; collapsed until Show, open when the node has
  listeners) with its listeners (× removes one: `Listener_Removed`). Listen... opens a dialog of
  the scene's nodes with a script (`Listener_Targets`); choosing one (`Listener_Target_Chosen`,
  a `.Node` undo step) adds `NodeDef.listeners` (`<listener event target handler/>`, target a
  path from the node) and appends to the script's file (`Script_FileOf`: the one registering it)
  the handler `<Script>_<handler> :: proc(self: ^Script, source: ^e.Node, data: e.EventData)`
  with the event's data hint and its `@(init)` `e.Script_Listener` registration
  (`Listener_HandlerSource`; named `on<Node><Event>`, unique in the file:
  `Listener_HandlerName`), in the code tab (`CodeEditor_InsertAtLine`, caret in the body) or,
  with the external editor, written to the file. Tests: `listeners_from_the_inspector`,
  scripts.script (built and played without a listener warning).
- **Script events** (new_event.odin; the catalog's `ScriptDesc.events`): the Events section also
  lists the node's script's events ("script.x"; a Component instance's root's script:
  `NodeDef_Script`), once built, with **New Event...** (`NewEventDialog`: name, description,
  `EventDataKind`), which adds the tagged field and a "Fire it:" comment to the script's struct
  (`NewEvent_Insert`, `NodeField_FindStruct(text, name)` for files with several scripts), and
  **Globals**: each global's events (Listen... makes the selected node's script listen, the
  listener stored on that node with `global` set: `Global_Listen_Requested`,
  `Listener_Connect`) and **+ Event** for the global. Handlers for a script's event get a
  `sender := e.Node_GetScript(source, X)` hint, a global's `x := e.Global(X)`. Listeners whose
  event is gone show "(no such event)" once the scripts are built. Tests:
  `scripts_publish_events_in_the_editor`; scripts.script (New Event, build, listen, play).
- **Assets dropped on a code tab** (asset_fields.odin; the browser's `browserDrag`, which now
  starts for every asset kind with a handle type and for LDtk projects): an exported field of
  its handle type (`TextureAsset`, `SoundAsset`, `MusicAsset`, `FontAsset`, `ComponentAsset`,
  `DataAsset` with `kind=<type>`) defaulting to the asset, with a comment using it (a
  component: `e.Scene_AddComponent(self.scene, self.coin, position = e.Node_GetWorldPosition(self.node))`:
  with no parent the position is the world's, and the demo's coin particles once played at the
  level's corner, off screen, with `{0, 0}`); the inspector
  then picks another per node. scripts.script saves a node as a component and drags it in
  (the driver's `drag_asset_to <path start> <widget>`).
- **Fields the editor adds end with a comma**, and the field above gets one if it had none
  (`Struct_MissingComma`): Odin allows no comma only on the last field, so the next insert broke
  the build.
- **Node fields** (node_fields.odin; the engine sets them before `ready`): an exported pointer
  to a node type (`camera: ^e.Camera2D `export:"default=../Camera"``) holds a path
  (`e.Node_FindPath`). The inspector's control is a dropdown of the scene's nodes that fit
  (`NodeField_Choices`: `e.SceneNodeKind_IsType`, a Component instance counting as its root's
  kind), as paths from the script's node. **Dropping a scene tree node on a code tab**
  (`Tree_Drag_Dropped_On_Code`, `sceneTreeMouse`; a label follows the pointer) adds such a
  field to the file's script struct (`NodeField_FindStruct`: the one with `using script:`),
  before its closing brace through the code editor's buffer (`CodeEditor_InsertAtLine`: one
  undo step, no auto-indent), named after the node (`NodeField_Name`), defaulting to its path
  from the node using the script (the selected one, else the scene's first; none: from the top
  level). Tests: code_editor.script (the drop), scripts.script (built, the inspector's picker,
  played without a warning); the driver's `drag_row_to <tree> <row> <widget>`.
- **Code completion:** `Scripts_WriteOLSConfig` writes `scripts/ols.json` for OLS (the Odin
  language server): collections `engine` (this editor's engine checkout) and `project`. Written
  whenever the script files are refreshed (project open, New Script, Build) and on Open, only when
  the content changes; a file without its `_generated_by` line is the user's and is left alone.
  **OLS only reads ols.json at the root of the folder the code editor has open**, so the default
  arguments open `{folder}` (the scripts folder) as the workspace: `{folder} {file}:{line}`.
  Checked with a headless LSP session against Zed's OLS: 0 completions after `e.` without the
  file, 268 (the engine's procedures) with it, and 0 when the open folder is the project root.

- **Several scripts per node** (node_scripts_edit.odin; the engine's `node.moreScripts`): the
  first stays `NodeDef.script` / `props`; **Add script** (`inspector-add-script-<i>`, once it has
  one and the catalog has others) appends `NodeScriptDef`s (name + props, owned: clone, destroy,
  equal, load, writer: one `<script>` each, in order). Their fields edit through
  `NodeScriptTarget(i)`; Open / × per script. Choosing None for the first promotes the next
  (`NodeDef_RemoveFirstScript`); choosing one of the more scripts as the first moves it. Script
  usages, the scene preview's list, scene renames, node-field drops (`NodeDef_Runs`), the
  Events section (each script's and the node type's events, New Event... per script) and the
  Timeline's `script.x` properties (`NodeDef_Codes`: node type, first, more; the first with the
  field) see all of them. Listen... still puts the handler in the first script's file.
- **Node types of game code** (`e.NodeType_Register`): the catalog's `nodeTypes`
  (`ScriptCatalog_ParseAll`'s third list, `ScriptDesc.base`), Add Node's last group "Your node
  types" (`AddNode_Entries`, `Add_Node_Type_Chosen`; New Component too). The node is its base
  kind with `customKind` set, so the viewport, inspector and writer treat it as the base; the
  writer writes `kind="<Type>" baseKind="<Base>"` and `<prop>` children (`customProps`, edited
  through `NodeCustomTarget`, the inspector's section above Script). Tests:
  `several_scripts_and_node_types_in_the_editor`, `tests/ui/node_types.script` (real code built:
  Add Node, fields, Add script, undo, played; driver checks `node_type`, `more_scripts`,
  `script_prop`; `write_project_file` makes missing folders).

**Hot reload** (play_reload.odin; Settings > Editor > Hot reload, `hot_reload`, on by default):
while a project player runs, `playReloadTick` looks at the scripts folder every half second.
A script newer than the game's build starts a build of `<player>-reload` beside the running one
(the game goes on; output to the Output tab; a failed build is logged and the game keeps the old
code), then `--describe-scripts` on it (the catalog follows), then `snapshot <file>` over the live
link (`Live_Ingest`'s `snapshot` reply; PLAY_RELOAD_WAIT seconds, else it restarts fresh), then
stops the game, renames the new binary over the old and `startGame(state, restore)` (no
`--scene`: the snapshot's). The restarted game's `built` is the newest source when the build
started, so saves during a build reload again. `endSession` aborts a reload's process. Test:
`tests/ui/hot_reload.script` (a live edit of a script field survives the reload; a broken save
leaves the game running; driver `live_select <name>`, check `live prop <name> <value>`, `send
Live_Property_Edited`).

Both are child processes (`core:os` `process_start` with a pipe). A `Play_Tick` message every 0.1 s
(`skald.cmd_delay`) drains the pipe and checks for exit with `process_wait(…, 0)`, so there are no
threads. **Stop** kills the child. **Pause/Resume** send SIGSTOP/SIGCONT; they aren't supported on
Windows yet. Quitting the editor stops the game.

### Undo / redo (implemented, `history.odin`)

A command history in `State.history`: each `UndoCommand` holds what changed (one node:
`NodeChange`, or a scene's node list: `SceneChange`) before and after, the selection before and
after, and its scene. Undo switches to that scene and restores "before"; redo restores "after".
- **Recording is automatic.** `update` wraps `applyMsg`: `History_Classify` says what a message
  edits (`.Node`, `.Scene` or `.None`), `History_Snapshot` copies it, and `History_Commit`
  compares after the message and pushes a command if anything changed. **A new edit message needs
  a case in `History_Classify`**, or it won't be undoable.
- **Merging:** commands with the same `mergeKey` (the same field of the same node) fold together
  when they come within `undoMergeMs` of each other (debounce), until the run is `undoGroupMaxMs`
  long (throttle; 0 = never cut). Viewport drags are `sticky`: one step from press to release,
  keyed by `history.gesture`, which `Viewport_Drag_Begin` bumps.
- Not undoable: selection, layout and other view state, the tree's expanded flags, and asset
  import/remove (they copy and delete files).
- Undo/Redo are `textChord` actions: in a text field, Ctrl+Z is the field's own undo.

### Settings (implemented, `settings.odin`, `settings_dialog.odin`, `view_settings.odin`)

- `settings.default.ini` (in git) holds every default and is built in with `#load`;
  `Settings_Default` parses it, so the file and the code can't disagree.
- The user's settings are `editor.ini` next to the executable (`Settings_DefaultPath`, so
  `build/release/editor.ini` for `task run`, `build/editor.ini` for the debug build). Loading parses the defaults, then that file over them;
  unknown or bad lines are reported in the Console and skipped. Saving writes every setting.
- `--settings <file>` picks another file. Test scripts (`--script`) use the defaults and never
  save unless `--settings` is given; `task test:ui` passes a scratch `build/ui_settings.ini`.
- `Settings` is a plain value (no allocations). The dialog edits `settingsDialog.draft`; Apply/Save
  copy it to `state.settings`, write the file and return `skald.cmd_set_theme`.
- Appearance: `Settings_Theme` builds the Skald theme: dark/light colors, text sizes scaled from
  `fontSize` (default 13, Skald's is 14), spacing as a percentage of Skald's scale (default 75%).
  Tree rows use `settings.rowHeight` (26). Toolbar and panel button sizes follow the text size.
- Keyboard tab: clicking a shortcut starts a capture; the next key press (with modifiers) binds
  it, Escape cancels, Clear unbinds. `captureKey` empties that frame's key input so nothing else
  sees it. Conflicts are shown, not blocked (the first action in `Action` order wins).

### Settings > Project

The Settings dialog's last tab shows the Project Settings dialog's tabs (`ProjectSettings_TabsView`,
shared) on its draft, opened with `ProjectSettingsDialog.embedded` set: File > Project Settings'
own dialog then draws nothing. Settings' Apply and Save also send `Project_Settings_Applied`
(`cmd_batch` after the theme), one undoable step, after which an Apply (dialog still open) opens a
fresh copy; Cancel drops it. Reset to Defaults is hidden on that tab. The dialog widens to 760 for
the project's Input, Globals and Export tabs. Test: `tests/ui/settings_project.script`.

### Toolchain (implemented, `toolchain.odin`, Settings > Toolchain)

What a user needs to build games, so a release works without a checkout or a hand-installed Odin:
- **Projects without scripts** play and export with the **prebuilt player** shipped next to the
  editor (`prebuilt/<target>/player`): nothing to install.
- **Projects with scripts** are compiled from the **engine's sources**: `ENGINE_DIR` (a checkout:
  development), else `engine/` next to the editor (releases ship the engine's git-tracked files
  with its built `box2d/lib` and `sdl/lib`).
- **Odin:** `Toolchain_Odin` takes the setting (`odin_path`), else `odin` in PATH, else the one
  the editor installed. **Install Odin** (`Toolchain_InstallOdin`, a `skald.cmd_thread`) downloads
  the pinned release (`ODIN_VERSION`, the engine's: `dev-2026-10`) from GitHub with curl and
  unpacks it with tar (Windows 10+ has both) into `<SDL pref path>/odin/<version>/` (Linux:
  `$XDG_DATA_HOME/crossfire-editor/...`, else `~/.local/share/...`). About 3 minutes.
- **A linker** can't be shipped: clang (Linux), Xcode's command line tools (macOS), Visual Studio
  Build Tools (Windows). The tab says how to get the missing one.
- The tab lists `Toolchain_Check`'s rows (Odin, engine sources, linker, prebuilt player, static
  SDL, OLS) with found/missing, the path and a note. It reads the dialog's **draft**, so an edited
  Odin path shows its result before Apply.
- Tests: `export_plan_uses_a_prebuilt_player`; `tests/ui/toolchain.script` (the tab, a bad path
  shows missing; `toolchain <name>: <found|missing>` in the driver). Verified by hand: with no
  odin in PATH (mise's shims removed) and `XDG_DATA_HOME` scratch, Install Odin, then
  `scripts.script` compiles with the installed one (its path in the Output tab).
- CI's Linux builds link with zig against glibc 2.31 (the engine's `tools/ci/zig_toolchain.sh`;
  `package_editor.sh` checks the editor and player). Users' own builds still use their linker.

## Project format (XML)

**The format is defined in the engine**, in `odin_sdl_engine/project_format.odin`; its doc comment
has the full spec with examples and the version history. The engine parses it (`ParseProject`,
`ParseScene`) and builds scenes from it (`project_loader.odin`). The editor reuses that parser for
loading (`Project_Load`) and writes the same format (`project_xml.odin`). Change the format in the
engine first, then the editor's writer and model, bumping `PROJECT_FORMAT_VERSION` (with a
migration) for incompatible changes.

```
MyGame/
  project.xml              name, resolution, scale mode, background, start scene, scene list, asset list
  scenes/<Name>.scene.xml  one per scene; <node> nesting is the hierarchy
  assets/                  images, audio, fonts, referenced by relative path
  export.ini               export targets and their settings (only once changed)
  export/<target>/         export output (the default folder; gitignored in this repo's examples)
  .editor/                 per-user editor state (gitignored; not used yet)
```

- **Version 14:** an AnimatedSprite's animations each have their own sheet (`AnimationDef.sheet`,
  `grid`: the engine's `e.SheetGrid`, Cells or Size), written on each `<animation>` (`sheet`,
  `columns` / `rows` or `grid="Size" cellWidth cellHeight`, `margin`, `spacing`), in scene files
  and `.anim.xml` files; NodeDef and AnimationSetDef have no sheet (no `columns`, `rows`, `margin`,
  `spacing`). Older files migrate in the engine's parser (the node's or file's sheet becomes every
  animation's; a node without animations gets "default"), so `Project_Load` just copies them;
  they're rewritten in the new format only when saved. Also in 14 (no version of its own): a
  Camera's `target` and follow, limit and shake attributes (`NodeDef.camera`, `cameraTarget`;
  see "Camera follow target").
- **Version 13** also: CollisionShape `oneWay` (the inspector's One way checkbox,
  `NodeFlag.One_Way`); **translation tables**: `.csv` assets of kind Translation (the browser's
  Translations folder, its preview parsed by the engine's `e.Locale_LoadCSV`; not in
  `scripts/assets.odin`: scripts use keys, `e.Tr`), and the project's `locale` (Project
  Settings > General > Language, `project-settings-locale`, in the `.Project` snapshot;
  `tests/ui/localization.script`).
- **Version 13** also: the editor's grid (`<grid width height majorEvery opacity majorOpacity/>`,
  `Project.grid`; see "Viewport grid and snapping"). Games ignore it.
- **Version 13** also: the game window's icon (`Project.icon`, an image asset; Project Settings >
  General > Icon, `project-settings-icon`; written when set; the engine shows the Crossfire logo
  without one). The General tab scrolls (`project-settings-general-scroll`) once taller than the
  window allows, so Apply stays drawn: scripts `scroll_into_view` to its lower rows.
- **Version 13** also: the project's window (`Project.window`, the engine's `WindowSettings`):
  Project Settings > General's Window checkboxes (`project-settings-window-<field>`,
  `tests/ui/window_settings.script`), in the `.Project` undo snapshot, written when not the
  defaults.
- **Version 13:** every node's process mode, blend mode, z index, y sort and groups: `NodeDef`
  fields of the same names (groups as one comma-separated string), the inspector's common rows
  (Z index, Y sort, Blend, Process, Groups; `tests/ui/node_settings.script`), written only when
  not the defaults.
- **Version 2:** node positions, rotation and scale are relative to the parent. Version 1 files
  (world positions) are migrated when parsed.
- **Version 4:** physics node kinds and attributes, and the project's physics settings.
- **Version 11:** the project's `renderer` (written only when not Auto).
- **Version 10:** sound nodes, `<bus>` elements in project.xml, asset kind Music.
- **Version 9:** components (`.component.xml` files, asset kind Component) and Component nodes.
- **Version 8:** input actions in project.xml.
- **Version 7:** AnimatedSprite `<animation>` children, `margin`, `spacing`, `autoplay` (the sheet
  moved into each animation in version 14).
- **Version 6:** ParticleEmitter nodes; their settings are a `<particles>` child element (the
  engine's `e.FormatParticleSettings`: only what differs from the defaults).
- **Node kinds** are the engine's `SceneNodeKind` (the editor's `NodeKind` is an alias):
  Node2D, Sprite, AnimatedSprite, Camera, Label, Menu, StaticBody, DynamicBody, CharacterMover,
  Area, CollisionShape, RayCast, ParticleEmitter (its settings in a `<particles>` element).
  - Menu buttons carry an action: `scene:<Name>` or `quit`.
  - Hidden nodes and their children aren't drawn at runtime.
- **Writer rules:** attributes are written in a fixed order, and only the ones that apply to the
  node's kind and differ from `e.DEFAULT_SCENE_NODE`. Values are escaped (`EscapeXML`). Output is
  deterministic, so saving an unchanged project produces identical files; a test checks it.
- **Round trips:** `editor_test.odin` saves the demo with tricky values (escapes, non-default
  fields), reloads it, and compares every field. Extend it whenever a property is added.
- **Not handled yet:**
  - Scene files of deleted or renamed scenes aren't removed.
  - The editor doesn't scan `assets/` for files added outside the editor.
- **Constants in `scripts/assets.odin`** take their names from files, actions and achievements
  through `ConstantName` (letters and digits upper-cased, anything else one underscore): a
  dash once went in as it was (`TEXTURE_HERO-RUN`), which isn't an Odin name.

## Globals, data resources, saves, asset handles (implemented; engine: globals.odin, data.odin, save.odin, assets.odin)

- **Globals** (`Project.globals`, `<global>` in project.xml): scripts the game runs once for
  the whole run, in order, with field values. Project Settings > **Globals** edits a draft
  (`ProjectSettingsDialog.globals`, Apply is the `.Project` undo step): add a built script
  (`global-add`), reorder, remove, set fields. New Script's **kind** (`ScriptKind`) Global writes
  `GlobalScriptTemplate` and adds it to the globals; kind Data writes `DataTypeTemplate`.
- **Data resources** (`Project.data`, one per asset of kind Data, `data/<name>.data.json`): the
  browser's **Data** folder (right-click > New Data Resource: `newDataDialogView`,
  `Project_CreateData`). Selecting one shows it in the inspector (`State.dataSelection`, set in
  `update` when the browser selects a data asset, cleared when a node is selected;
  `dataInspector`). Values are text props like script values; `Project_SaveData` writes the
  files (only changed ones). Undo restores values per file (`restoreProjectSnapshot`): creating
  and removing resources touches files, so like imports it isn't undone.
- **One field editor** (`FieldControl`) for all three owners: `Script_Prop_Changed.target` is a
  `PropTarget` (`SelectedNodeTarget` is the `#no_nil` zero value, `DraftGlobalTarget`,
  `DataTarget`); number fields carry it in `ScriptPropTarget.target`.
- **Catalog:** `--describe-scripts` also lists data types (`ScriptCatalog.dataTypes`,
  `ScriptCatalog_ParseAll`), used by the New Data dialog and the data inspector.
- **Asset handles:** fields of type `e.TextureAsset` / `SoundAsset` / `FontAsset` / `DataAsset`
  get a picker of the project's assets of that kind (Data: of the field's `kind=` type).
  `scripts/assets.odin` is regenerated (when its content changes, never over a file without the
  editor's marker) on save, import, remove, new data resource, refresh and before every build,
  so scripts always compile against the current asset list.
- **Saves** are the engine's (`e.Save_Game` / `e.Load_Game`): games run from the editor (`--dev`)
  save under "<name> (dev)". The demo shows the whole loop.
- Test driver: `send <Message> <value>` (dropdown choices), checks `globals`, `draft_globals`,
  `data_count`, `inspector_data`, `data_value`. `tests/ui/globals_data.script` builds both
  templates, sets a global's field, makes and edits a data resource, saves and plays.

## Physics (implemented; the engine does the simulation)

The engine integrates Box2D 3.1 (its physics*.odin files say how). The editor edits the seven node
kinds (bodies, CollisionShape, RayCast, Joint) like any others:
- **Model:** `NodeDef` has the engine `SceneNodeData`'s physics fields (same names), written by
  `writeNode` only when they apply to the kind and differ from `e.DEFAULT_SCENE_NODE`; layers as
  `e.FormatPhysicsLayers`, points as `e.FormatPoints`. `NodeDef_Equal`, `NodeDef_Clone`, the
  preview's conversion (`viewport_preview.odin`) and its `sceneSignature` (shape sizes: bounds)
  include them. **A new physics field needs all of these**, and the round-trip test.
- **Inspector** (`view_inspector_physics.odin`): numbers through `NodeField`, the shape kind
  through `NodeTextField.Shape`, flags through `NodeFlag`; layers 1-16 as toggle buttons
  (`Node_Layer_Toggled`; higher layers are kept); points as text kept while typing (it reuses
  `State.numberEdit`, like number fields). Warnings: a body without a shape, a mover without a
  capsule/circle, a shape not under a body, a joint without body B or naming a missing or
  duplicated body.
- **Joints name their bodies** (`bodyA`, `bodyB`; the engine finds them with `Scene_FindNode`, so
  the first node with the name). The inspector offers the scene's bodies (`JOINT_BODY_DEFAULT` /
  `JOINT_BODY_NONE` for none). **Renaming a body updates the joints that name it**
  (`Scene_RenameJointReferences`), and that rename is then a `.Scene` undo step
  (`Scene_JointsReferTo`). `jointBodies` resolves them as the engine will.
- **Viewport:** the preview scene has `physicsPaused` (animations update the scene; bodies mustn't
  fall in the editor). CollisionShape, RayCast and Joint nodes draw nothing in the game, so the
  overlay outlines shapes in their body's kind color (muted when disabled or without a body), draws
  rays, and joints (`drawJoint`: anchor ring, red without body B; lines to the bodies; Distance's
  offset point; the slide axis of Prismatic and Wheel). `viewport.showShapes`
  (`Toggle_Collision_Shapes`, Shift+C, the `panel-viewport-shapes` button) hides them. Shapes
  have engine bounds, so picking and selection boxes work as for sprites.
- **Debug drawing in the game is a development setting of the project** (`project.physics.debugDraw`,
  project.xml's `physicsDebug`): Project Settings > Show shapes, or Scene > Show Collision Shapes
  in Game (`Toggle_Physics_Debug`, a `.Project` undo step). Play uses it (the player reads
  project.xml). **Exports never ship it:** they write `data/project.xml` with
  `Export_ProjectXML` (the project with development settings off) instead of copying the file.
  Play also passes `--dev`, so F9 toggles the shapes while the game runs, and F10 the engine's
  debug overlay (frame rate, frame times, the scene's counts); exports don't.
  (Older editor.ini files' `play_collision_shapes` is ignored.)
- The viewport header clips the scene tabs to what its buttons leave (measured with
  `skald.view_size`), so many scenes or a narrow window can't push the buttons out of view.
- **Project Settings > General > Renderer** (`Project.renderer`, the engine's `e.RenderBackend`;
  `Project_Settings_Renderer_Changed`, in the `.Project` snapshot): every backend, those this
  computer's SDL lacks marked "(not on this computer)" (`e.RenderBackend_Available`), with a note
  on where the choice works. Play and exports read it from project.xml; the game falls back to
  SDL's choice where it isn't available, and logs "Renderer: <name>" (scenes.script plays with
  Vulkan and checks that line). The viewport isn't affected: it renders with SDL's Vulkan
  renderer on the editor's own GPU device (`gpu_share.odin`).
- **Project Settings > General:** pixels per meter, gravity, Show shapes (the game's debug
  drawing), Smooth motion (the engine's smoothing: bodies drawn between physics steps); `Project.physics`, in the `.Project` undo snapshot, written to project.xml only when
  not the defaults.
- Play and exports need nothing more: the player is the engine's. Box2D is static (the native
  `.a` through the engine's binding; on the web, `box2d_web.o` on the emcc line).

## Components (implemented, `component_edit.odin`; engine: project_loader.odin)

Reusable node trees, like Godot's packed scenes: saved in the assets
(`components/<name>.component.xml`, asset kind Component), instanced in any scene by a
Component node, and from scripts with `e.Scene_AddComponent(scene, COMPONENT_X)` (removed with
`e.Scene_RemoveComponent(scene, root.id)`).
- **Model:** a component is a `SceneDef` with `component` set (its file), in `Project.scenes`
  after the scenes, so the viewport, scene tree, inspector and undo edit it like a scene.
  **Anything that means "the project's scenes" must skip `Scene_IsComponent`**: the browser's
  Scenes folder, the start scene, scene fields and menu targets (`Project_SceneNames`),
  `Project_FindScene`, `Project_SceneCount`, project.xml's scene list, scene file cleanup, the
  export's scene files (component files go as assets), Play Scene (refused), and the `.Project`
  undo snapshot (scenes only; components are assets: made and removed with their files, like data
  resources). Loaded from the assets after the scenes (`Project_LoadComponent`); written by
  `Project_Save` (`SceneToXML` writes a `<component>` root for them).
- **Unsaved changes show on the tab** (scenes' and components': a filled circle beside the
  icon, `ICON_CIRCLE`): `Scene_IsDirty` compares the hash of what it would save (`Scene_Hash`,
  its SceneToXML) with the one taken when it was loaded or written (`Scene_MarkSaved`: load,
  Project_Save, Project_WriteComponent; clones keep it, so a project undo doesn't fake a change),
  once per history version. Ctrl+S saves them in place (Project_Save writes every component).
  **Closing a component's tab with unsaved changes asks** (`componentClose`,
  `Component_Close_Chosen`): Save writes it; Don't Save reloads it from its file and drops its
  undo steps (`History_DropScene`); scenes don't ask (closing their tab keeps them in the
  project). components.script: the driver's `close_current_tab`, check `scene_dirty`.
- **One root:** nothing goes beside a component's root. With nothing selected, Add Node, drops
  and Paste put nodes under it (`Scene_ParentFor`, in `Scene_InsertNode`, `Scene_PasteNodes`,
  the `*At` adders), duplicating the root puts the copy under it, and the tree refuses moves
  beside it (`Scene_CanMoveNode`). Files with nodes beside it load with them under it (the
  engine's parser). A node dropped on a code tab gets a path from the root when no node of the
  component has the script (`NodeField_From`: it runs on the instance's root, or on the LDtk
  entity's named like it); the path was from the top level, which the game never found.
  `components_keep_one_root`, `components_with_nodes_beside_the_root_load_with_them_under_it`.
- **Listed by name** (`Asset_DisplayName`, assets.odin): the browser, its previews and every asset
  choice (`labeledSelect`: names shown, paths stored) leave out the extension of the editor's own
  formats (`EDITOR_FORMAT_EXTENSIONS`: `.component.xml`, `.data.json`, `.anim.xml`, `.theme.xml`,
  `.material.xml`, `.atlas.xml`, `.dialogue.xml`); real file types keep theirs. The browser's search
  matches either.
- **Making one:** Save as Component (scene tree menu, Action.Save_As_Component): the subtree is
  written as a component (root at the origin) and the node becomes an instance with its
  transform (a `.Scene` undo step; the component stays). Browser > Components > New Component
  opens the Add Node dialog to pick the root's kind (`AddNodeDialog.forComponent`; a click and
  Enter both go through `addNodeChosen`): the root is named after it and selected, and the
  component opens in its tab (`Project_NewComponent(project, name, kind)`).
- **Editing one:** **Edit** on the browser preview, the browser menu and an instance's inspector
  opens its tab (`Component_Opened`), edited like a scene (components.script: Add Node and undo
  in a new component's tab).
- **Using one:** drag it from the browser into the viewport, Add to Scene (browser preview or
  menu), or a Component node with the inspector's Component choice; instancing a component into
  itself (directly or through others) is refused. Opened (double-click, Open), it gets a tab
  (`SceneDef.opened`, `ViewportTabScenes`), and the view fits what it draws rather than the game
  area: `openScene` sets `viewport.fitContent`; once the preview has built it
  (`Preview_IsCurrent`) the view sends `Viewport_Content_Measured` (`contentRect`: every visible
  node's bounds, and the positions of nodes that draw nothing) and update fits it
  (`Viewport_FitRect`, at least `VIEWPORT_FIT_MIN_SIZE` across). components.script checks it
  (`viewport_center`).
- **Viewport:** instances are built from the components in memory (`provideComponents` fills the
  engine game's component map before `Scene_Build`), and rebuild when a component they use
  changes (`componentSignature`); an instance picks and outlines by its whole tree
  (`subtreeBounds`). The browser preview draws a component with its own engine renderer
  (`Preview_RenderComponent`, cached by content and size).
- **Renaming** (the browser's menu, an inline rename with `RenameTarget.Component`): the file
  moves now (`Project_RenameComponent`), its asset, SceneDef and every instance follow; not
  undoable (it moves a file). Names are file names (`ComponentNameProblem`; compared ignoring
  case, as on Windows and macOS).
- **Make Unique** (an instance's inspector): a copy of its component as a new one
  (`<name>_2`), which the instance then uses alone (`Scene_MakeInstanceUnique`; undo points the
  instance back, the copy stays).
- **Removing** its asset removes its SceneDef (`History_SceneRemoved` drops and re-indexes undo
  steps). `scripts/assets.odin` gets `COMPONENT_X` constants; script fields of type
  `e.ComponentAsset` get a picker.
- Tests: `components_save_open_instance`, `components_render_in_instances_and_thumbnails` (the
  preview tests take turns: `previewTestLock`, and `Preview_Destroy` after), `tests/ui/components.script`
  (driver: `select_asset`, `right_click_asset`, `{selected}` in commands, checks `components`,
  `kind`, `preview component`), `components_rename_and_make_unique`.
- The browser's inline rename scrolls its row back into view when it's out of view (focusing the
  tree scrolls the browser to its top, which hid the field and left the rename stuck).

## Aseprite files (implemented: images; `aseprite_edit.odin`; engine: aseprite.odin)

`aseprite_edit.odin`'s doc comment describes it; what the code relies on:
- **Images:** `.aseprite` / `.ase` are assets of kind Image (`AssetKindForPath`, the import
  filter), so every texture field, picker and drop takes them. The engine draws their first frame
  with every visible layer (its resource manager), in the viewport, Play and exports alike (the
  web build too: the reader is pure Odin).
- **Anything the editor decodes itself** goes through `Image_LoadRGBA` (the Animation panel's
  sheet), not stb_image, which can't read them; Skald's `skald.image` can't either, so the
  browser preview uploads the engine's composite (`aseprite-preview`, keyed by path and time).
- **Saved in Aseprite:** the viewport re-reads changed textures at most twice a second when it
  draws (`Preview_FrameKey`: the engine's `ResourceManager_ReloadChangedTextures`, which updates
  textures in place; `texturesVersion` makes a new frame); a game run with Play does the same
  (development runs). Any image, not only Aseprite's. A file that changes size waits for a rebuild.
- Tests: `aseprite_files_are_images_in_the_editor` (import, parse, viewport pixels, saved over);
  `tests/ui/aseprite.script` (import, preview, Open in Aseprite, drag in, save, Play; driver
  check `texture`). Fixtures: `tests/fixtures/aseprite/` (Aseprite's MIT test sprites, its
  LICENSE beside them).
- **Animations:** an Aseprite file is an animation asset as it is (its tags; see the Animation
  editor's "Animation assets").
- **TileMaps** (tilemap_edit.odin; the engine's tilemap.odin): a TileMap node draws an Aseprite
  file's tilemap layers, with collision from its tiles' properties (`collision` = solid / one-way
  / area, or an `area` name, set in Aseprite's tile properties). Dropping a file that has tilemap
  layers adds one (`TileMapEdit_HasTilemaps`); otherwise a Sprite. The inspector ticks layers:
  with none named every visible one is built, and ticking or unticking starts from what's built
  (the last one can't go). Each layer's line counts its solid, one-way and area tiles by the
  engine's rules (`e.TileMap_TileCollision`). The viewport's rebuild signature includes the file's
  time. Tests: `tilemaps_in_the_editor`, `tests/ui/tilemap.script` (driver checks `tilemap`,
  `tilemap_built`); the fixture `tests/fixtures/aseprite/tilemap.aseprite` is ours
  (`make_tilemap.py`).
- **Slices, layers, events** (aseprite_edit.odin's `asepriteSpriteRows`, `sliceShapeRows`; the
  engine's aseprite_nodes.odin): a Sprite or AnimatedSprite showing an Aseprite file
  (`AsepriteEdit_NodeSource`: an AnimatedSprite's animation asset, else the first of its
  animations whose sheet is one; in a game the playing animation's file counts) gets layer checkboxes (`Aseprite_Layer_Toggled`, ticking from what's
  drawn, the last stays: `AsepriteEdit_ToggleLayer`), a Pivot slice (slices with a pivot), a
  Sprite a 9-patch (slices with a center) and its size; an AnimatedSprite lists its frame events
  (the Animation panel too). A CollisionShape near one (`AsepriteEdit_ShapeSprite`, the engine's
  rule) gets a Slice choice: a hitbox. The viewport runs one zero-time update after each rebuild
  so hitboxes take their place, and `syncTransforms` leaves them alone; it reloads saved
  Aseprite files' slices (`e.Game_ReloadChangedAseprites`). TileMaps: Animate and Tag. Tests:
  `aseprite_slices_layers_and_events_in_the_editor`, `tests/ui/aseprite_features.script` (driver
  check `aseprite`); fixtures `features.aseprite`, `tilemap_animated.aseprite` (Aseprite's).
- **Painting tiles** (tile_paint.odin: `TilePainter`, `TilePaint_Update`; view_tiles.odin: the
  bottom panel's **Tiles** tab, `TilesPanel`; the inspector's Paint Tiles opens it): while the tab
  shows and a TileMap is selected, viewport presses are `Tile_Brush` strokes (Begin / Move / End,
  Hover; right button erases; Space or middle drag still pans), before node drags. Tools Paint,
  Erase, Rectangle, Fill, Pick, Terrain; the brush is a tile value with flips (`Tile_Brush_Turned`).
  The first stroke on a file layer copies its cel into `TileMapSettings.painted` (the engine's
  `TileLayerData`; `<tiles>` children in the scene file); painting outside a grid grows it (left
  and up move its x / y). +Layer adds a layer of the scene's own; Use the File's Tiles drops a
  painted copy. Each stroke is one sticky undo step (keyed by `history.gesture`, bumped at Begin);
  equality is `TileMapSettings_Equal`. The rebuild signature includes the painted bytes.
  Terrains are the engine's (`e.TileGrid_PaintTerrain`). Tests: `tile_paint_test.odin`,
  `tests/ui/tiles.script` (driver: `click_tile`, `drag_world`, `paint_cells`; checks `tile`,
  `tile_brush`, `tile_tool`); fixture `tests/fixtures/aseprite/terrain.aseprite` (the engine's
  conformance file). User guide: `docs/manual/tilemaps.md`.

## LDtk levels (implemented, `ldtk_edit.odin`; engine: ldtk.odin, ldtk_nodes.odin)

`ldtk_edit.odin`'s doc comment describes the feature; what the code relies on:
- **Data:** `NodeDef.ldtk` is the engine's `e.LDtkLevelSettings` (owned: `LDtkSettings_Clone`,
  `e.LDtkLevelSettings_Destroy`, `LDtkSettings_Equal` for undo). Every copy path clones it
  (load, `NodeDef_Clone`, `NodeDef_Make` from `e.DEFAULT_LDTK_LEVEL_SETTINGS`). The XML writer
  leaves defaults out and writes `<entity>` children; the generated body's physics attributes
  only with a collision layer.
- **Inspector edits** are one message, `LDtk_Setting_Changed{field, text, flag, name}`, handled in
  `LDtkEdit_Update`; each is a node undo step (collision values typing merges).
- **Two parsed copies:** the inspector's (`LDtkEdit_Project`, a thread-local cache by full path,
  re-read when the file's modification time changes) and the preview game's (`Game_LoadLDtk`).
  The viewport's rebuild signature includes the file's time (`LDtkSettings_Signature`), and
  `rebuild` drops the preview game's changed projects (`forgetChangedLDtk`) after destroying the
  old scene, so saving in LDtk rebuilds the level when the editor next draws.
- **Import** (`Project_ImportAsset` -> `LDtkEdit_Import` for `.ldtk` from outside):
  `e.LDtk_Dependencies` lists tilesets, `.ldtkl` files and backgrounds; they're copied at the
  same relative paths under `assets/<stem>/` (`_2`... when taken); `../` ones go to `external/`
  and the copy's JSON is rewritten (quoted paths, plain and `\/`-escaped).
- **Exports:** `Export_ProjectFiles` adds `LDtkEdit_ExportFiles` (dependencies inside the project
  that aren't assets already), so packs and data folders have the tilesets.
- **Browser:** a **Levels** folder, its preview lists levels; the menu and preview have Open in
  LDtk (`LDtk_Asset_Open_Requested`). **The world map picks levels:** `Preview_RenderLDtk`
  records each level's rectangle in the picture (`Preview_LDtkLevelAt`); hovering one outlines
  it and a click sends `LDtk_Level_Picked`, which shows it in the selected LDtkLevel node (else
  the scene's first using that file), a `.Scene` undo step (ldtk.script: `ldtk_level`).
- Tests: `ldtk_import_settings_and_export`, `ldtk_import_brings_outside_files_in`;
  `tests/ui/ldtk.script` (import, Add Node, inspector selects, the preview's levels / entities /
  shapes through the driver's `ldtk_preview`, undo, save, Play). The fixture
  `tests/fixtures/ldtk/` (a one-level project with a generated 32x32 tileset) is ours, written
  for the tests: LDtk's own samples have third-party art.
- **What the inspector tells about the level** (view_inspector_ldtk.odin, read-only, every rule
  the engine's own): the level (size in pixels and cells, world position, background,
  neighbours, its LDtk fields; each level's line for a whole world), how it's built (every
  layer bottom first: drawn tiles, auto-layer tiles, IntGrid colors, the collision layer with
  how many cells and which values by name, entities on or off; parallax, opacity, hidden),
  each entity type (count, the component choice, what it becomes and why: `LDtkEdit_EntityPlan`;
  a bare rectangle without a script is a warning; which LDtk field sets which script field), and
  a list of every entity (position, fields) whose rows center the viewport on it
  (`LDtk_Entity_Framed`). ldtk.script clicks one; `ldtk_inspector_says_what_entities_become`.
- **Collision settings:** with a collision layer, the inspector shows the generated body's
  layers, mask, friction and bounce (`bodySurfaceRows`, shared with body nodes).
- **Entity rules and collision kinds** (the engine's `LDtkEntityRule`, `LDtkCollisionKind`): per
  entity type a **Becomes** select (`Entity_Make`: Auto, Its rectangle, Code, Nothing, then the
  project's components; `LDTK_MAKE_LABELS`) and a **Runs** select (`Entity_Script`: Auto, No
  script, the catalog's scripts; a named one the catalog lacks stays listed); rules that say
  nothing are dropped (`ldtkDropDefaultRules`), so Auto writes no `<entity>`. Per IntGrid value
  of the collision layer a kind select (`Collision_Value_Kind`, `LDTK_KIND_LABELS`):
  `LDtkEdit_SetCollisionKind` rewrites the three lists from every value's kind (all solid: no
  lists; none solid: `collisionValues="0"`). `Entity_Component` and `Collision_Values` stay for
  older messages. Tests: `ldtk_entity_rules_and_collision_kinds_in_the_inspector`; ldtk.script
  (the driver's `ldtk_areas`).
- **Thumbnails:** `Preview_RenderLDtk` builds an LDtkLevel node in its own software renderer and
  fits it; one cache per place (`LDtkThumbnailSlot`: the browser's world map, the inspector's
  level), keyed by file, level and the file's modification time. `ldtkThumbnailView` uploads it.
- **Play reloads** saved LDtk files (the engine's LDtk_WatchFiles in dev runs): tiles, collision
  and backgrounds update in the running game, layers added or removed appear or go, and
  entities placed or deleted spawn or go (the others keep running).
- **The demo's forest level** (ForestScene, `examples/demo_project/assets/forest/forest.ldtk`)
  uses all of it: auto-layer rules, IntGrid collision, parallax layers, entities mapped to
  components with scripts named like them, fields (enemies' patrol, speed, health), an EntityRef.
  Combat (the hero's attack, snails, boars, bees, blood, the engine's hitstop and camera shake,
  the HUD) is in its scripts; the demo README lists where. Test:
  `shipped_demo_copies_with_its_level` (copied like a bundle's first run, loaded, its files
  exported). It was checked playing (a headless program driving the hero through each mechanic)
  and rendered, in the game and as the editor shows it.

## Input actions (implemented; engine: input.odin)

- **Model:** `Project.actions` (`ActionDef`: name, deadzone, `[dynamic]e.InputBinding`; the
  bindings are a plain union, compared with `==`), in project.xml as `<action>` (format 8, written
  by `ProjectToXML` with `e.FormatInputBinding`), in the `.Project` undo snapshot. New projects
  (and the demo) start with Godot's ui_left/right/up/down/accept/cancel (`DefaultActions`).
- **Project Settings > Input** edits a draft (`ProjectSettingsDialog.actions`; Apply is the undo
  step): the action list (select, reorder, remove, add by name, add the default ui_* ones), the
  shown action's name (typed text kept until valid and unused), deadzone (`valueSlider`) and
  bindings (remove; add by pressing: "Press a key or button" captures the next key, lone
  modifier, mouse button or wheel through Skald's input, `Input_CaptureBinding`; or from
  dropdowns: every engine key, mouse buttons, gamepad buttons and stick directions, for any
  gamepad or one). Skald can't see gamepads, so gamepad bindings come from the dropdowns.
- `scripts/assets.odin` gets a constant per action (`ACTION_JUMP :: "jump"`).
- Tests: `input_actions_round_trip`, `input_settings_edits`, `tests/ui/input.script` (driver
  checks `input_actions`, `draft_input_actions`, `input_bindings`, `draft_input_bindings`;
  `click_overlay_item` picks the choices of the last popup, inside a dialog too).

## Animation editor (implemented, `view_animation.odin`, `animation_edit.odin`)

**Animation assets** (animation_sets_edit.odin; the engine's animation_sets.odin): an
AnimatedSprite plays its own animations or an animation asset's (`NodeDef.animationSet`, the
inspector's **Animations**): an `.anim.xml` file (kind Animation) or an Aseprite file (its tags).
- **The panel edits an `AnimSource`** (`AnimEdit_Source`): the set the browser shows in it
  (`AnimEditor.asset`: an asset's Edit Animations, an Aseprite preview's Animations; Back to the
  sprite clears it), else the selected sprite's set, else its own. Every message goes through the
  source's pointers (its animations and autoplay: the sheets are the animations'). Aseprite's are
  read only (edits are dropped).
- **Undo:** edits to a set are `.Project` steps (History_Classify checks `AnimEdit_IsEdit` first;
  the snapshot holds every set, restored by file like data resources); a project step that
  doesn't touch the open scene's nodes keeps the selection, so the panel keeps showing it.
- **Making one:** the inspector's Save as Animation Asset (`Anim_Set_From_Node`: the sprite's own
  animations, their sheets with them, go into `animations/<name>.anim.xml`, the sprite uses it; the node's step
  is undone, the file stays), or the browser's New Animations (`Anim_Set_New`, an empty one).
  The browser's Animations folder shows once there's one (row counts in tests stay put).
- **Using one:** the inspector's Animations choice, dragging the asset into the viewport (an
  AnimatedSprite: `Scene_AddAnimatedSpriteAt`), or scripts: `ANIMATION_X` constants (an Aseprite
  file gets both `TEXTURE_X` and `ANIMATION_X`), `e.AnimatedSprite_UseAnimations`, fields of type
  `e.AnimationAsset` (a picker of both kinds).
- **Viewport:** the preview game gets the in-memory sets and the Aseprite files' (parsed by the
  editor) before each build (`provideComponents`), and the rebuild signature includes a set's
  text or an Aseprite file's time.
- **Durations** (Aseprite frames each have one) and `repeat` round-trip; the panel shows them
  (`AnimationDef_StepAt` previews them) but doesn't edit them yet.
- Tests: `animation_assets_are_made_saved_edited_and_undone`, `tests/ui/animation_assets.script`
  (driver checks `anim_source`, `animation_set`, `animation_sets`).

- **Model:** an AnimatedSprite has `animations` (`AnimationDef`: name, **its own sheet** (`sheet`,
  a path) and `grid` (`e.SheetGrid`: mode Cells with `columns` x `rows`, or Size with `cellSize`,
  plus `margin`, `spacing`; only the mode's own values are kept, as files keep them), start, end
  (-1 = last cell), fps, loop, play mode; at least one) and `autoplay` (the one it starts with, "" =
  the first); the node has no sheet (format 14: `NodeDef.texture` stays "" for it). Scene files:
  `<animation>` children. Older files' node sheet (and before format 7 the node's fps/loop/
  playMode as one "default" animation) are moved into the animations by the engine's parser.
- **Cells:** a Size grid's count needs the image's size: `AnimEdit_Cells` reads it through
  `Image_Size` (stb_image's header, or the Aseprite file; cached per file time on the heap under a
  lock, since tests run on several threads; freed by `AsepriteEdit_Destroy`). Without an image a
  Size grid is one cell. Start, end, count and frame clicks clamp to those cells.
- **Panel** (bottom panel, Animation tab; the inspector's Edit Animations opens it): a toolbar on
  top, the frames below, so it uses the panel's width. The toolbar: a dropdown picking the
  animation (a star on the starting one), add (`Anim_Added`: every cell of the selected
  animation's sheet, its grid too) / duplicate (unique name) / remove (one stays) / move up and
  down, the name (kept while typed until valid and unused), Starts with this; then the selected
  animation's sheet (`Anim_Sheet_Texture_Changed`, or an image dragged from the browser and
  released over the panel: `Anim_Sheet_Dropped`, which ends the drag and takes
  `State.assetDrag`'s asset), its grid mode (`Anim_Grid_Mode_Changed`: switching works the other
  mode's values out from the image, so the cells stay put) and values (`AnimField.Columns`, `Rows`,
  `Cell_Width`, `Cell_Height`), margin and gap (`Margin`, `Spacing`), the cells it makes; then
  frames, count (`AnimField.Frames`: sets the end from the start), FPS, loop, mode. Its controls
  are small groups in a `skald.wrap_row`, so
  they wrap onto more lines in a narrow panel (a group wider than a line would spill into the
  scrollbar strip: keep groups small). Below: a preview playing the animation and a thumbnail per
  cell of its sheet (click = start, Shift+click = end; the animation's cells lit). The preview runs on `Anim_Tick` at ANIMATION_PREVIEW_FPS while it
  plays and the panel shows. The viewport plays the panel's animation on the sprite too
  (`Preview_Render`).
- **Thumbnails:** the sheet is uploaded once per file (`image_load_pixels`); `drawCell` draws a
  cell with Skald's `draw_image_region` (a pixel rect of an image, inset half a texel so
  neighbouring cells don't bleed in).
- **Undo:** every edit is a `.Node` step (History_Classify; sheet, drop and grid mode too); the
  selection, preview and typed name are panel state (`State.animEditor`).
- **Inspector:** an AnimatedSprite's rows are Animations, **Sheets** (the sheets its animations
  use, read only), Starts with, Edit Animations, Save as Animation Asset.
- Tests: `animation_frames_over_time`, `animation_panel_edits`, `animations_round_trip`,
  `animations_have_their_own_sheets_in_the_panel` (two sheets, the Size grid, counts, a drop,
  undo, the round trip), `tests/ui/animation.script` (the driver's `click_frame`, `drag_asset_to
  ... animation-scroll`; checks `animations`, `animation` (its sheet, grid, columns, rows, cell,
  margin, gap, cells, count too), `autoplay`, `sheet_loaded`), `tests/ui/animation_assets.script`
  (a set's second animation on another sheet, cut by size). `scroll_into_view` centers a laid-out widget, and passes when the
  scroll isn't drawn but the widget is visible (layouts that change with the window).

## Collision from sprites and physics materials (implemented, `collision_trace_edit.odin`, `material_edit.odin`; engine: collision_trace.odin, physics_material.odin)

- **Materials** follow themes: `Project.materials` (`MaterialDef`), `.material.xml` assets of kind
  PhysicsMaterial (browser folder Materials, hidden until one exists), `Project_SaveMaterials` in
  `Project_Save`, `.Project` undo steps (the snapshot holds every material), the inspector when
  the browser selects one (`State.materialSelection`, set in `update` like `themeSelection`).
  Values are rounded to three decimals as they're set (short numbers in files). A body's
  `NodeDef.material` (Node_Text_Changed `.Material`) replaces its friction, restitution and
  density, so the inspector leaves those rows out (`materialBodyRows`). Areas have none.
- **Collision from sprite** (`State.trace`, view state): the body inspector's section under its
  shapes; `Collision_Traced` is a `.Scene` step that removes the body's direct CollisionShape
  children named `Traced...` and inserts one Polygon per piece (`e.Image_CollisionPolygons` on
  `Image_LoadRGBA`, an AnimatedSprite's first animation's first cell cropped from that animation's
  sheet by its grid: `Trace_Picture`), mapped through the sprite's
  transform relative to the body. A trace that changes nothing records no step.
- Tests: `physics_materials_in_the_editor`, `collision_from_a_sprite_in_the_editor`,
  `tests/ui/collision_tools.script` (driver `select_node`, checks `traced`, `material`,
  `node_material`). User guide: `docs/manual/collision_and_materials.md`.

## Shaders (implemented, `shader_edit.odin`; engine: shaders.odin, screen_effects.odin, shader_compile.odin)

- **Data:** `NodeDef.shader` (owned path) and `shaderParams` (`ScriptPropDef`, only the values
  set: clearing one deletes it), ScreenEffect's `effectScreenLayers`; written as the node's
  `shader` attribute and `<shaderParam>` children (the writer's "no children" test counts them);
  project.xml's `shaders="true"` (`Project_UsesShaders`). Asset kind Shader (`.frag`, browser
  folder Shaders hidden until one exists; `SHADER_X` path constants in assets.odin).
- **Inspector:** for kinds that draw or have drawing children (`NodeKind_TakesShader`), after the
  kind's rows; a project shader's params come from its source (`ShaderEdit_Params`:
  `e.Shader_ParseParams`), a built-in's from its bundle. Param labels are the shader's own (no
  editor tooltip).
- **Compiling** (`Shaders_Compile`): on Session_Save, before Play and exports (before
  Project_Save), and from Code_Tick (`ShaderEdit_Watch`, once a second) while code tabs are
  open; errors to the Console. The tools: `shader_tools/` beside the editor (releases; a macOS
  bundle's MacOS folder), else the engine's (`task shadertools`). Exports add `<asset>.shader`.
- **Viewport:** a scene with shaders (`Preview_SceneUsesShaders`) switches the preview to an
  offscreen SDL GPU renderer (`startEffects`, read back like the OpenGL fallback; `render_path`
  says `effects`); parameters follow every frame (`syncTransforms`: defaults, then the node's
  values) and are in `Preview_FrameKey` (they weren't: a drag never re-rendered); scenes with
  shaders count as animated (`time`). `destroyAll` releases the game's shaders before the
  renderer; the preview game gets `projectDir` (project shaders are read from it).
- Tests: `node_shaders_in_the_editor`, `project_shaders_new_compile_and_export`,
  `tests/ui/shaders.script` (the hit flash seen in the render, undo, New Shader compiled on
  save, a CRT ScreenEffect, Play: `Renderer: gpu`; driver checks `shader`, `viewport_has_color`,
  `render_path effects`; checked with Vulkan validation). User guide: `docs/manual/shaders.md`.

## Context menus (implemented, `context_menus.odin`, `context_menus_panels.odin`)

One right-click menu for the whole editor (the user asked for complete menus everywhere,
2026-10-22). Its file's doc comment lists every target and what it offers; what the code relies on:
- **State, not widgets:** `State.contextMenu` (open, where, the `ContextTarget`). Every place opens
  it with `Context_Menu_Opened` from its own mouse handling (`rightPressOpens(ctx, rect, target)`
  for a widget's last rect, or the place's hit test: graphs, the tree, the viewport); the items are
  built each frame from the state (`ContextMenu_Items`), so they're always current.
- **Skald's `popup_menu`** (added for this, Skald 2026-10-22): `Menu_Item`s (shortcut hints,
  checks, separators, disabled rows, a level of submenus) at a point the app keeps; keys (Up / Down
  / Right / Left / Enter / Escape). `contextMenuView` is built first in the root view, so it takes
  its clicks before the widgets under it, and an open menu counts in `keysTaken`.
- **Items send the existing messages** (an `Action` where one exists: the menu, the shortcut and
  the menu bar do the same, with the keymap's hint): only what had no message got one
  (`Node_Command`: hide / show, move up / down, reset transform, z order, select children / parent,
  copy path, expand / collapse; `Add_Node_Here` (`AddNodeDialog.at`), `Paste_Here`, tab, file and
  log commands). Their undo steps are classified in `History_Classify`.
- **The viewport** opens it on a right **release** that moved under `RIGHT_CLICK_SLOP` px (a right
  drag still pans): a guide, else the node under the pointer (`pickNode`), else empty space.
- **Tab commands close by scene**, not by tab position (`closeSceneTab`): positions shift as tabs
  close. Components with unsaved changes and code tabs with unsaved text stay open (their × asks).
- Driver: `click_context_item <label>[/<submenu label>]` (a label's start works), `right_click_node`,
  `right_click_world`, `right_click_widget`, `click_frame <n> right`; checks `context_menu`,
  `context_item <label> <enabled|disabled|checked|missing>`. Tests: `context_menu_commands`,
  `tests/ui/context_menus.script`. User guide: `docs/manual/scenes_and_nodes.md#right-click-menus`.

## Viewport tools (implemented, `viewport_tools.odin`, `view_viewport.odin`, `viewport_math.odin`)

- **Tools:** Transform (T: the arrows, the middle square, corner and side handles, the ring;
  `gizmoHit` tries them in that order) and Zoom (Z: `DragMode.Zoom_Box`, a click zooms 2x, Alt
  out, a box fits). Side handles are `DragMode.Scale_X` / `Scale_Y` (one local axis), for Scale and
  Transform.
- **Local axes** (`ViewportState.localAxes`, L): the move arrows (drawn and dragged) follow the
  node's rotation; `ViewportDrag.localAxes` is taken when a drag starts. Grid snapping along a
  turned axis is skipped (it would leave the axis).
- **Alt+drag** (`Viewport_Drag_Begin.duplicate`): the selection's roots are duplicated in
  Drag_Begin and the copy of the dragged node is dragged; Drag_Begin is a `.Scene` step merged
  with the drag's moves (`key("drag", gesture + 1)`, `ViewportDrag.duplicated` keeps them `.Scene`).
- **Snap steps** are settings (`Settings.rotateSnap` / `scaleSnap`, Settings > Editor), passed to
  `Viewport_ApplyDrag`.
- **Align and Distribute** use `Viewport_NodeShapes` (the preview's bounds; without a preview,
  as in unit tests, the nodes' origins). The header's Align button opens the menu (`Ctx_Align`).
- **Guides** are view state on `SceneDef` (cloned, destroyed; not undo steps), drawn after the
  grid in `GUIDE_COLOR`; the drag is file state in view_viewport.odin (`guideDrag`), out of a ruler
  or from a guide (`guideAt`, before node picking); moves snap to them with snapping on
  (`Guides_SnapNode`). Saved in `.editor/guides.ini` (scene name or component file per section).
- Driver: `drag_guide <top|left> <world>`, `drag_guide_back <i>`, `drag_node ... alt`; checks
  `guides`, `guide`, `local_axes`. Tests: `viewport_tool_drags`, `zoom_tool_clicks_and_boxes`,
  `align_and_distribute`, `alt_drag_moves_a_copy`, `tests/ui/viewport_tools.script`. User guide:
  `docs/manual/scenes_and_nodes.md`.

## The editor's look (implemented, `editor_theme.odin`, Settings > Appearance)

- Colors are set over the base theme (Skald's Dark or Light) only where the user set one
  (`themeColorsSet`), so a set color survives a base change; `cornerRadius` scales Skald's radii.
- **Live:** the dialog returns `skald.cmd_set_theme` with the draft's theme for every Appearance
  change (`liveTheme`); Cancel returns the applied settings' theme. Row height isn't live (views
  read `settings.rowHeight`, not the draft).
- The picker has no alpha: a picked color keeps the opacity it had; Selection opacity sets it.
- Labels are "Window background" and "Main text" (tooltips are per label; Background and Text
  were taken).
- Driver: `send Settings_Theme_Preset_Chosen <name>`; checks `live_theme <applied|draft>`,
  `theme_color <key> <#RRGGBB>`. Tests: `editor_theme_settings`, `tests/ui/theme_editor.script`.
  User guide: `docs/manual/settings_and_toolchain.md#appearance`.

## Editor plugins (implemented, `plugin_host.odin`, `view_plugins.odin`, `plugin_api/`)

- **Odin calling convention across the boundary:** the editor and its plugins are built by the
  same Odin, so plugin procedures (and the Host's) are plain Odin procs: they get the caller's
  `context` (allocators), default parameters work. A plugin's returned slices must be
  package-level (a literal inside the entry proc is on its stack: Odin refuses it).
- **Everything a plugin gives is copied** on load (names, extensions, targets); procedure pointers
  point into the library, so a reload clears the records before `dynlib.unload_library`. Each
  build goes to a new file (`<name>-<n>.so`): a loaded library can't be overwritten on Windows,
  and Linux's dlopen returns the already-loaded handle for the same path.
- **The tick** (`Plugins_Tick`, 0.5 s) starts from the view when the project has `plugins/`
  (`State.pluginsTicking`), handles a project change (unloads, starts over), builds one plugin at a
  time (`newestSource` of its folder against its last build), loads when its build ends. Build
  output goes to the Output tab.
- **Host procedures** read and change the editor state through `pluginState` (set by `pluginCall`
  before every call). Inspector rows are asked during `view` on its state copy: rows must only
  read. Commands and row changes run in `update` and are `.Project` steps.
- **Importers** take their extensions before the editor's own importers (`importAsset`).
- Tests: `plugins_build_load_and_run` (the sample plugin built and loaded, its command undone, its
  rows and importer, the template built, a reload after a change; needs Odin),
  `tests/ui/plugins.script` (driver `copy_into_project`, `send Bottom_Tab <Tab>`, check `plugin
  <folder> <state>`); fixture `tests/fixtures/plugins/` (grid_tools, talk.csv). User guide:
  `docs/manual/plugins.md`.

## Dialogue (implemented, `dialogue_edit.odin`, `view_dialogue.odin`; engine: dialogue.odin, yarn.odin, dialogue_box.odin)

- Dialogues are files edited in memory like animation sets: `Project.dialogues`, in the
  `.Project` undo snapshot (restored by file), written by `Project_Save` when changed; creating,
  importing and removing them are asset changes. The Dialogue tab shows `s.dialogue.path`: set
  by New Dialogue, a browser selection of a dialogue asset (`update`), a DialogueBox's Dialogue
  choice, the tab's own dropdown.
- `Dialogue_Changed` ops act on the shown dialogue's selected node (`s.dialogue.node`); typing
  merges per node, step, option and field; a node drag merges per `history.gesture` (bumped by
  `Dialogue_View{.Drag_Begin}`). Renaming a node follows in jumps, options and the start.
- The preview game gets the dialogues in memory (`Dialogue_ProvideToGame` in
  `provideComponents`), and a DialogueBox's signature holds its dialogue's text, so a box shows
  the edited first line at once (it autostarts on the preview's zero-time update). The preview
  frees the game's `dialogueVariables` itself (`destroyAll`, thumbnails).
- Importing a `.yarn` file converts it (`Yarn_Import`: `dialogues/<name>.dialogue.xml`, the Yarn
  file isn't added); `AssetKindForPath` takes `.yarn` as Dialogue for the import dialog.
- Labels: "Letter size" (not "Text size": Settings' editor text size), "Chosen color", "Box
  padding", "Starts playing".
- Tests: `dialogues_in_the_editor` (edits, renames following, undo, played by the engine, a Yarn
  import, a DialogueBox drawn in the viewport, saved and read back), `tests/ui/dialogue.script`
  (typing a line, + Options, + Node, an option's target, moving and undo, a Yarn import, a box
  set up and played; driver `send Dialogue_Created` / `Dialogue_Select_Node`, check `dialogue
  <field>`); fixture `tests/fixtures/dialogue/shop.yarn`. User guide: `docs/manual/dialogue.md`.

## Skeletons (implemented, `skeleton_edit.odin`; engine: skeleton.odin, dragonbones.odin)

- `NodeDef.mesh` is the engine's `e.MeshData` (owned: `e.MeshData_Clone` / `_Destroy` / `_Equal`
  in Clone, Destroy, FromData, `NodeDef_Equal`); the writer puts a `<mesh>` child (FormatPoints,
  FormatTriangles, FormatWeights; weights rounded to thousandths so files read back equal),
  `boneLength`, the `ik*` attributes. The preview rebuilds on mesh, IK paths and bone lengths
  (`sceneSignature`).
- **The scene's pose is the rest pose:** `Skeleton_PreviewBind` (viewport_preview.odin) binds
  every preview mesh after `syncTransforms`, so editing bones never bends a mesh; the Timeline's
  clip at the playhead does, and IK, solved in the preview after the Timeline
  (`e.Scene_SolveIK`), so dragging a target shows at once. The engine nodes' bones are restored
  from the NodeDefs every frame.
- Overlays (`drawSkeletonNode` in view_viewport.odin): every bone a wedge, an IK chain's line from
  its solved tip to a crosshair on its target, the selected mesh's deformed triangles. Bones have
  no bounds: they're picked in the scene tree.
- Labels "Mesh columns" / "Mesh rows" (not "Grid columns": a Panel's), "Tip bone", "IK target",
  "Bones", "Bend", "Solve", "Length". Make Mesh's grid size is editor state (`meshGrid`), not
  an undo step.
- **DragonBones:** `AssetKindForPath` takes `_ske.json` as a component; `importAsset` (and
  `Project_ImportAsset`) call `DragonBones_Import`: the atlas picture copied to
  `atlases/<name>.png`, the `.atlas.xml` written and added (`Project.atlases`), the converted
  nodes (`NodeDef_FromData`) written as a component (root named after it); warnings to the
  Console.
- Tests: `skeletons_in_the_editor` (bones, a mesh made and bound, IK solved in the preview, saved
  and read back), `dragonbones_files_import_as_components`, `tests/ui/skeleton.script` (Add Bone,
  Make Mesh, Bind, IK dropdowns, a DragonBones import added and played); fixture
  `tests/fixtures/dragonbones/` (ours). User guide: `docs/manual/skeletal_animation.md`.

## Import settings, atlases and fonts (implemented, `asset_import_edit.odin`, `atlas_edit.odin`; engine: asset_import.odin, atlas.odin, fonts.odin)

- **Asset changes, not undo steps** (like imports): an image's filtering, a font's MSDF, a
  conversion, every atlas edit; the project's Image filtering is in the Project Settings draft and
  the `.Project` snapshot. The writer puts `filter` / `msdf` on `<asset>` and `textureFilter` on
  project.xml's root, only when set.
- **The viewport** applies the import settings when they change (`previewImportSettings`, hashed
  into `Preview_FrameKey`: `e.ResourceManager_SetImportSettings` on the preview game); a repacked
  atlas drops the preview game's copy and its texture (`Preview_AtlasChanged`), a remade MSDF atlas
  its glyph font (`Preview_FontChanged`). The viewport's shared renderer isn't SDL's GPU renderer, so
  MSDF fonts show as TrueType there; games on the GPU renderer draw the atlas.
- **Atlases are always written**: every edit repacks and writes both files at once
  (`Atlas_PackFiles`), so the preview, Play and exports read them from disk; exports add the
  packed picture (`Export_ProjectFiles`). Choosing an atlas as a Sprite's texture picks its first
  region. The inspector shows an atlas while `atlasSelection` holds (cleared like
  `materialSelection`).
- **MSDF atlases** (`<font>.msdf.json` / `.msdf.bmp`) are made by `e.Font_MakeMSDF` with the shader
  tools' msdf-atlas-gen (Settings > Toolchain > Font tool) when the setting goes on, on save, before
  Play and exports (beside `Shaders_Compile`), when the font is newer; exports add them
  (`Fonts_ExportFiles`), and a bitmap font's page images.
- **Sounds** convert with ffmpeg (`Toolchain_FFmpeg`, Settings > Toolchain) on a worker; the
  asset's path, sound nodes, music layers, script and global values naming the old file follow
  (`audioReplace`); imports of formats SDL_mixer can't play convert first (`Asset_Import_Result`).
- Tests: `import_settings_in_the_editor`, `atlases_in_the_editor`, `tests/ui/asset_import.script`
  (filtering, MSDF made, a conversion, an m4a converted on import (`tests/fixtures/tone.m4a`), an
  atlas packed and a Sprite's region, played; driver checks `asset <path> ...`, `file_exists`,
  `atlas <field>`, `region`; `send Atlas_Created`, `Node_Texture`, `Node_Region`). User guide:
  `docs/manual/asset_import.md`.

## Lines, trails and GPU particles (implemented, `line_edit.odin`; engine: lines.odin, gpu_particles.odin)

- `NodeDef.line` is plain (`==`); the writer puts a line's `points` and the settings that differ
  from `e.DEFAULT_LINE_SETTINGS`. `syncTransforms` copies a line's settings and points, a
  trail's settings, every frame (no rebuild). Trails draw nothing in the viewport (nothing
  moves there).
- GPU particles are two particle settings (`gpu`, `gpuAmount`), so the particle inspector shows
  them with no editor change; a scene with a GPU emitter counts as using shaders
  (`Preview_SceneUsesShaders`, `Project_UsesShaders`): the viewport draws it with the GPU
  renderer, and Auto picks it in games.
- Tests: `lines_and_trails_in_the_editor`, `tests/ui/lines.script` (typed points seen in the
  render, width, joints, closed, undo, a trail under a node, an emitter switched to the GPU and
  `render_path effects`, Play: `Renderer: gpu`; checked with Vulkan validation). User guide:
  `docs/manual/lines_and_trails.md`.

## Touch controls, Steam and local players (implemented, `touch_edit.odin`, `steam_edit.odin`; engine: touch.odin, steam.odin)

- **Touch controls** are node kinds with a plain `NodeDef.touch` and owned `touchActions` (the
  scene file's comma-separated left, right, up, down; a button's one); a button's label is `text`
  (written only for TouchButtons besides Labels and UI kinds). `NodeDef_Make` takes
  `e.TouchControl_Defaults(kind)` (a button's radius is smaller), and the writer compares against
  it. `TouchEdit_Update` formats the actions before freeing the old text (the parsed names are
  slices of it: a use-after-free the UI script caught). The preview game has
  `showTouchControls`, so they draw whatever their visibility; `syncTransforms` copies their
  settings. The inspector warns when the node's layer isn't one of the scene's screen layers
  and the scene has a camera. Labels "Input action" (not "Action": a UI Button's), "Size radius".
- **Steam** lives on the Project Settings draft (`ProjectSettingsDialog.steam`, `achievements`),
  applied with the rest and in the `.Project` snapshot (take, restore, destroy, equal). The
  writer puts `steamAppId` / `steamCloud` on project.xml's root and `<achievement>` children.
  Achievements lay out on two lines each (a tiled window's dialog is narrow).
- **Local players** (players_edit.odin) are on the Project Settings draft too (Input tab, under the
  action list), in the snapshot, and written as `<players>` only when not the defaults (new
  projects get `e.DEFAULT_PLAYER_SETTINGS`). Renaming or removing the join action in the draft
  follows (input_actions.odin). Tests: `local_players_settings_in_the_editor`,
  `tests/ui/players.script` (plays: the engine logs `Local players: up to 2, joining with
  ui_accept`; driver check `players <field>`). User guide: `docs/manual/local_multiplayer.md`.
- Tests: `touch_controls_in_the_editor`, `touch_controls_draw_in_the_viewport` (pixels),
  `steam_settings_in_the_editor`, `tests/ui/touch_steam.script` (Play: the console's
  `Steam: stub backend (app 480)`; driver checks `touch <field>`, `steam <field>`). User guide:
  `docs/manual/touch_and_steam.md`.

## Camera follow target (implemented, `camera_edit.odin`; engine: camera.odin)

- `NodeDef.camera` is the engine's `e.CameraSettings`, plain (`==`: NodeDef_Equal), defaulting
  to `e.DEFAULT_CAMERA_SETTINGS` (`NodeDef_Make` from DEFAULT_SCENE_NODE); `cameraTarget` is
  owned (Make, Clone, Destroy, FromData). The writer (`writeCamera`) puts what isn't the default;
  a limit side's value only when it's on (so a side turned off loses its value when saved).
  Format 14, added without a version (the engine's history says so).
- **Inspector:** Zoom, then sub-headers (the particle groups' pattern: a spacer and an xs text)
  Follow (Target: a select of every other node's path from the camera, `CAMERA_TARGET_NONE`, and
  a warning when `Scene_ResolvePath` finds nothing; Follow mode; the mode's own strength only;
  Max speed except for Snap; Dead zone, Aim offset, Look ahead X / Y; Look ease once there's a
  look-ahead), Limits (per side a checkbox and, when on, a number in one row:
  `limitWidth` leaves room for the box inside controlWidth; a Right or Bottom side turned on at 0
  starts at the game's size), Shake (size, time, rate). Labels avoid other kinds' ("Aim offset X":
  a joint's is "Offset X"; "Shake size": a motor's is "Strength").
- **Undo:** `Camera_Changed` is a node step (numbers merge per field; typing is
  Number_Text_Changed's `CameraNumber` case). Renames (`Rename_Committed`, `Node_Renamed`) are
  `.Scene` steps when any camera has a target, since they may rewrite its path.
- **Paths kept:** `Scene_MoveNode` and both renames resolve every camera's target first
  (`CameraTargets_Resolve`) and rewrite the paths after (`CameraTargets_Repath`, with the move's
  `newIndex`). Other node paths (script node fields, CameraView's `viewCamera`, IK targets)
  still aren't rewritten.
- **Viewport:** the preview builds cameras without the settings (`toSceneData` leaves `camera`
  zero: no target, no limits), so the camera stays where it's placed and parallax shows the scene
  as placed; a selected camera draws its limits, dead zone, a line to its target and a ring where
  it aims (`drawCameraGuides`, view_viewport.odin).
- Tests: `camera_follow_settings_in_the_editor` (messages, clamps, undo, clone / equal, renames
  and moves keeping the path, saved and parsed by the engine), `project_round_trips_through_xml`
  (every setting), `tests/ui/camera.script` (driver check `cam <field>`). User guide:
  `docs/manual/camera_tools.md#following-a-target`.

## Camera tools (implemented, `camera_tools_edit.odin`; engine: camera_tools.odin)

- `NodeDef.cameraTools` is plain (`==`), `viewCamera` owned; zones' and views' sizes are
  `shapeSize` (the shape fields, labelled Room / View width and height; defaults 640 x 360 and
  160 x 90 in `NodeDef_Make`); a layer's image is `texture`. The viewport outlines zones and views;
  the engine draws layers and views (a view's camera as the scene starts it).
- Tests: `camera_tools_in_the_editor`, `tests/ui/camera_tools.script` (driver check
  `camtool <field>`). User guide: `docs/manual/camera_tools.md`.

## State machines (implemented, `state_machine_edit.odin`, `view_states.odin`; engine: state_machine.odin)

- Like the Timeline, the States tab shows the selected StateMachine and keeps it while other
  nodes are selected (`States_Follow` after every message); `SM_Changed` is a node step on the
  machine's index (a state drag sticky per `history.gesture`, bumped by `SM_View{.Drag_Begin}`;
  typing merges). `NodeDef_Make` gives a new machine an `idle` state.
- Renames follow: a state in transitions and the start; a parameter in conditions, whole words
  only (`renameWord`). Removing a state removes its transitions.
- The graph handles the mouse from last frame's rect (the canvas pattern); arrows run box edge to
  box edge, nudged sideways so both ways between two states show (`States_Arrow`). States'
  positions are graph pixels, saved as `x` / `y`.
- Tests: `state_machines_in_the_editor`, `tests/ui/states.script` (driver `click_state`,
  `drag_state`, check `states <field>`). User guide: `docs/manual/state_machines.md`.

## Scene changes (implemented, `scene_flow_edit.odin`; engine: scene_flow.odin)

- `Project.transition` (plain) and `loadingScene` (owned) are on the Project Settings draft
  (`ProjectSettingsDialog.transition`, `loadingScene`), applied with the rest, in the `.Project`
  snapshot, written on project.xml's root when set.
- Button actions offer **Open <Scene> over this** (`push:<Name>`) and **Close this** (`pop`) besides
  Go to and Quit (`uiActionChoice` / `uiActionFromChoice`); `Project_RenameScene` renames
  `scene:` and `push:` actions of Menu items and Buttons, and the loading scene;
  `Project_RemoveScene` clears the loading scene. A ProgressBar's **Shows loading**
  (`UIField.Show_Loading`).
- Tests: `scene_changes_in_the_editor`, `tests/ui/scene_flow.script` (project.xml checked with
  `project_file_contains`). User guide: `docs/manual/scene_changes.md`.

## The live view (implemented, `live_edit.odin`, `view_live.odin`; engine: live.odin)

- **The link:** `startGame` passes `--live` and `startProcess(..., live = true)` gives the game a
  stdin pipe (`PlaySession.stdin`, closed by `endSession`); `watch` is sent at once. `emitLine`
  hands `@@live ` lines to `Live_Ingest` instead of the Console.
- **Pause** (`playPause`, F6, the toolbar) goes through the link when connected (`pauseGame`),
  else through the signal (POSIX); Stop no longer needs a SIGCONT first then.
- **Stale stats:** a stats line the game sent before it read a pause or resume arrives after the
  editor changed `live.paused`; until one agrees (or 2 s pass, `pausePending`) they're ignored.
  Without that the Step button vanished under a click and the next click sent pause again
  (live.script caught it).
- **Edits** are sent as typed (`set`; the game refuses what doesn't parse, logged); typed text is
  kept in `live.edits` until another node is chosen, since the node's values come back every
  half second. Nothing is undoable or saved: it's the running game.
- Tests: `the_live_view_reads_the_game`, `tests/ui/live.script` (plays the fixture: connects,
  nodes, properties, pause / step / resume by the tab and F6/F5, an edit; driver check
  `live <field>` with `> n` counts). User guide: `docs/manual/live.md`.

## Navigation (implemented, `nav_edit.odin`; engine: navigation.odin)

- `NodeDef.nav` is plain (`==`); a NavRegion's area is `shapeSize` (the shape fields' messages,
  labelled Area width / height), defaulting to 640 x 360 (`NodeDef_Make`). `syncTransforms` copies
  a region's settings and area to the engine node every frame, and while a region is selected
  `Preview_Render` rebuilds its grid (`e.NavRegion_Rebuild`), so the viewport's shaded blocked
  cells follow walls as they're dragged. The overlay draws a region's outline and, selected, its
  blocked cells from the engine's grid (`Preview_Node`).
- Labels differ from other kinds' ("Walk speed", not Speed: tooltips are per label).
- Tests: `navigation_in_the_editor` (the preview grid following a moved wall), 
  `tests/ui/navigation.script` (driver check `nav <field>`). User guide: `docs/manual/navigation.md`.

## 2D lighting (implemented, `light_edit.odin`; engine: lighting.odin)

`light_edit.odin`'s doc comment describes it; what the code relies on:
- A Light2D's settings are `NodeDef.light` (plain; `==`), copied to the engine's light every
  frame by `syncTransforms` (no rebuild for a slider). A LightOccluder's shape is the
  CollisionShape fields: `shapeRows` (view_inspector_physics.odin) and `writeShape`
  (project_xml.odin) serve both; its shape is in the rebuild signature.
- A scene's lighting is in `SceneDef.settings` (`lighting`, `ambient`, `bodyShadows`), edited in
  the scene preview (`sceneLightingRows`) as `.Project` steps (`SceneSettings_Classify`).
  `Preview_Render` sets the preview scene's lighting every frame from them and
  `viewport.unlit` (Action.Toggle_Lighting, Shift+L, the header's light bulb).
- The viewport outlines occluders (`drawCollisionShape` in their gray) and draws a selected
  light's reach.
- Tests: `lighting_in_the_editor` (the preview's pixels lit, dark past the reach and behind an
  occluder, unlit when toggled), `tests/ui/lighting.script` (driver checks `scene_lit`,
  `light <field>`, `viewport_unlit`). User guide: `docs/manual/lighting.md`.

## UI controls and themes (implemented, `ui_edit.odin`, `theme_edit.odin`; engine: ui_controls.odin, ui_theme.odin)

Their files' doc comments describe them; what the code relies on:
- **Controls** are node kinds whose settings are `NodeDef.ui` (`e.UISettings`; clone / destroy
  through the engine, `UISettings_Equal`), their text and image the usual `text` / `texture`.
  One message, `UI_Setting_Changed{field, value, text, flag}` (numbers through `UINumberTarget`),
  a node step merged per field while typing. The writer writes their attributes only for UI
  kinds (the parser reads them only for UI kinds: an AnimatedSprite's `columns` once leaked
  into its `ui`).
- **The viewport** builds them with the engine, which lays them out against the game area (the
  preview game's size). Their `position` is the layout's, so `syncTransforms` hands
  `NodeDef.position` to `Control.offset`. The rebuild signature includes their settings, text
  and image. The inspector says when a parent's layout places a control.
- **Themes** are files (`Project.themes`, loaded with the project and imports, written by
  `Project_SaveThemes` in `Project_Save`) edited as `.Project` steps (the snapshot holds them and
  `uiTheme`); the theme inspector shows when the browser selects one (`themeSelection`, set in
  `update` like `dataSelection`). The preview game reads them through `syncThemes` (one
  `e.ThemeData` per file kept in `previewThemes`, updated in place each render, so a font's
  resolved path is made only when it changes; the game's `themes` map is cleared before it's
  freed). `Theme_Created{forSelected}` (a control's New Theme button) gives the control the
  new theme and is a node step (the file stays).
- **Labels** differ from other kinds' where the meaning differs ("Grid columns", "Gap", "Edge
  margin", "Can't be used", "UI theme"): tooltips are per label.
- Tests: `ui_controls_and_themes_in_the_editor`, `tests/ui/ui_controls.script` (driver checks
  `ui <field>`, `themes`, `theme <field>`, `ui_theme`). User guide: `docs/manual/ui.md`.

## Keyframe animation: the Timeline (implemented, `timeline_edit.odin`, `view_timeline.odin`; engine: animator.odin)

`timeline_edit.odin`'s doc comment describes it; what the code relies on:
- **Model:** `NodeDef.animator` is the engine's `e.AnimatorSettings` (clips of tracks of keys,
  values as text; owned: `e.AnimatorSettings_Clone` / `_Destroy` / `_Equal`, in NodeDef_Make,
  NodeDef_Destroy, Clone, load and `NodeDef_Equal`). The writer puts `autoplay` / `speed` on the
  node and `<clip>` / `<track>` / `<key>` children. The preview's rebuild signature includes every
  key (the engine parses clips when it builds).
- **Which Animator:** `TimelineEditor.node` follows the selection when an Animator is selected
  (`Timeline_Follow`, after every message in `update`) and stays when another node is selected,
  so targets can be moved and keyed. `Timeline_Animator` checks it's still an Animator of the
  open scene.
- **Undo:** `Timeline_Changed` is a `.Node` step on the Animator's index (not the selection's);
  `Key_Moved` is sticky per `history.gesture` (bumped by `Timeline_View{.Drag_Begin}`), typing a
  key value or a number merges, a clip name applies once valid (`Name_Typed`, typed text kept in
  `nameEdit`). `Timeline_IsEdit` tells them apart from other edits.
- **Viewport:** Animators don't autoplay there (`rebuild` sets `started`). While the Timeline tab
  shows and `previewing` (set by scrubbing, playing, selecting keys, Timeline edits; cleared by
  any other undoable edit), `Preview_Render` applies the clip at the playhead after the update
  (`e.Animator_Apply`); when it stops, the scene is built again (an Animator may have changed
  what the build set). `Preview_FrameKey` includes the playhead. Playing ticks at `TIMELINE_FPS`
  (`Timeline_Tick`, only while the tab shows and the window is focused). Animators have no
  viewport marker and no handles and aren't picked (they'd cover what they animate).
- **Tracks** store paths from the Animator's parent (`Timeline_PathTo` = `Scene_NodePath` from
  the parent; `Timeline_ResolvePath` reads them as the engine's `trackTarget`). Key records the
  NodeDef's value (`Timeline_NodeValue`; tint and opacity are white / 1: scene files have no
  tint), a script field's stored prop or its catalog default.
- **The canvas** (`tracksCanvas`) handles the mouse from last frame's rect like the Tiles palette;
  its names' column shrinks in a narrow panel (`Timeline_NameWidth`: the tiled window's panel is
  narrow, and a canvas wider than the scroll put the end of the clip out of reach).
- Tests: `animators_are_edited_in_the_timeline` (paths, follow, tracks, Key, undo, a sticky drag,
  events, names, the viewport at the playhead, save and load), `tests/ui/timeline.script`
  (driver: `click_timeline <s> [track] [double]`, `drag_timeline_key`; checks `timeline <field>`,
  `timeline_key`). User guide: `docs/manual/animation.md`.

## Sound and the Mixer (implemented; the engine's audio_nodes.odin)

- **Model:** `NodeDef.sound` (an asset path), `bus` ("" = Master) and `audio` (the engine's
  `e.AudioSettings`, a plain value: compared with `==`, cloned by copy). Written by `writeNode`
  only when not the defaults (loop only for the sound kinds). `Project.buses` (`BusDef`, Master
  always first) is in project.xml as `<bus>` (Master only when changed) and in the `.Project`
  undo snapshot.
- **Assets:** a sound file is a Sound (`.Audio`, loaded whole: `SOUND_X` constants) or Music
  (`.Music`, streamed by MusicPlayers: `MUSIC_X`, its own browser folder). Imports are sounds;
  the browser's menu switches one (`Asset_Kind_Changed`, "Use as Music (streamed)" / "Use as a
  Sound"); it's an asset change, like imports, not undoable. Script fields of type
  `e.MusicAsset` get a picker.
- **Inspector** (`view_inspector_audio.odin`): sliders are `valueSlider`s (`Audio_Field_Changed`,
  clamped in `update`), checkboxes `Audio_Flag_Changed`, the sound and bus through
  `Node_Text_Changed` (`.Sound`, `.Bus`; choosing Master stores ""). A bus name that no bus has
  is warned about (the engine plays it on Master). **Preview** plays the node's sound through the
  browser's audio preview with its volume, pitch and pan (`AudioPreview_SetSettings`; not its bus).
- **Mixer tab** (`MixerPanel`, `Mixer_Update`), laid out like a DAW's mixer: channel strips for
  the buses in an `hScroll` (wheel or bar), Master pinned on the far right with + (Add Bus,
  "Bus", "Bus 2", ...; the new strip is scrolled into view: `hScroll_ScrollToEnd`) beside it.
  A strip, as tall as the panel: node count and remove (not Master; its nodes go to Master), pan
  (`panControl`), the fader (`fader`, 20 px: -inf to +6 dB, unity snaps, Shift fine, double-click or
  Ctrl+click resets; in a flex slot built by `skald.sized`, so it takes the height the rest leaves)
  beside its meter on the same scale, the level in dB, mute, the name (typed text kept in
  `State.busEdit` until valid: not empty, no edge spaces, unused ignoring case; nodes on it
  follow the name). Each edit is a `.Project` undo step, merged while a fader drags.
- **The sound device:** the project's output format is Project Settings > General > Sound output
  (`Project.audioOutput`, the engine's `AudioOutputSettings`: `audioFrequency` / `audioChannels`
  in project.xml when not stereo 48 kHz; in the `.Project` snapshot); the device is the
  machine's, Settings > Editor > Audio device (`settings.audioDevice`, `audio_device`, from
  `AudioPreview_Devices`): Play passes `--audio-device`, and the previews' mixer opens on it
  with the engine's fallbacks (`e.Audio_OpenMixer`; `AudioPreview_SetDevice` reopens it when it
  changes). window_settings.script picks Mono and sees the setting.
- **Meters show the editor's own playback**: Preview plays the node's sound through its bus
  (`Mixer_RoutePreview`, applied again after every Mixer edit, so a fader changes what you hear),
  the browser's previews through Master. The preview's track carries sound × bus gains, its group
  meters the bus, the mixer's post-mix applies and meters Master (the engine's AudioMeter, as in
  the game). A game run with Play is another process: its levels aren't shown (later: send them
  back over the player's output).
- **Viewport:** a selected AudioPlayer2D shows its range as a ring (`maxDistance`, world units).
  The viewport never plays sounds: `Scene_Build` without scripts doesn't load them.
- Tests: `sound_nodes_and_buses_round_trip`, `mixer_edits`, `fader_scale_in_decibels`,
  `tests/ui/mixer.script` (real fader, pan, mute and scroll-bar drags, the wheel, a preview moving
  the meters; driver: `double_click_widget`, `wheel_widget`, checks `buses`, `bus <i> <field>`,
  `sound <field>`, `meter <key>`, `widget_visible <key>`).
- **Bus effects** (bus_effects_edit.odin; the engine's audio_effects.odin): `BusDef.effects` is
  a fixed array with `effectCount`, so buses stay plain values (`busesEqual` with `!=`, copied by
  `BusDef_Clone`, the snapshot's copies too). The Mixer strip's **FX** (`mixer-fx-<i>`) sends
  `Bus_Effects_Opened`: the inspector shows `busEffectsInspector` while `State.busSelection` is
  valid (cleared when a node is selected or the browser selection changes). Edits are `.Project`
  steps, a slider's drag merged per effect and field. The writer puts `<effect>` children under
  `<bus>` (only what differs from `e.DEFAULT_AUDIO_EFFECT`; Master is written once it has
  effects). **The preview hears them:** `Mixer_RoutePreview` hands the routed bus's and Master's
  effects to `AudioPreview_SetEffects`, which sets the preview's two chains (the bus meter's
  and the master meter's `effects`) only when they changed, with `AudioEffects_SetOne` when only
  settings changed (an echo's tail carries on); the chains' state is on the heap allocator
  (package state outlives a unit test's allocator). Labels: "Damp highs" (not "Damping", a
  body's). Tests: `bus_effects_in_the_editor`, `tests/ui/bus_effects.script` (driver checks
  `bus <i> effects`, `bus_effect`, `bus_selection`, `preview_effects`).
- **Music layers** (music_layers_edit.odin): `NodeDef.musicLayers` (owned), in NodeDef_Clone /
  Destroy / Equal and the load; written as `<layer>` children of a MusicPlayer. The inspector's
  Layers rows (`inspector-layer-<i>-name|sound|volume|remove`, `inspector-layer-add`) send node
  steps (typing and drags merge). The viewport doesn't play them; the editor's Preview plays the
  main music only. Tests: `music_layers_in_the_editor`, bus_effects.script (`music_layer`).
  User guide: `docs/manual/audio_effects_and_music.md`.

## Particles (implemented; the engine's particles.odin)

- **Model:** `NodeDef.particles` is the engine's `e.ParticleSettings`, a plain value (no
  allocations), so cloning, equality (`==`) and the undo snapshot need nothing per field; the
  Texture shape's image is `NodeDef.texture`. Written by `SceneToXML` as `<particles>`.
- **Inspector** (`view_inspector_particles.odin`): one loop over `e.ParticleSettings_Fields()`
  (names, types, the `min`/`max`/`label`/`group` tags), so **a setting added in the engine shows
  up here with no editor change** (a new field type needs a case in `particleControl`). Ranged
  numbers are `valueSlider`s (reset goes to `e.DEFAULT_PARTICLE_SETTINGS`), rounded to about a
  thousandth of their range (`sliderStep`; a tenth of that with Shift) and written with
  `formatSliderValue`, so scene files get short numbers; `[2]f32` is two sliders, with the link
  button under the label (`State.particleLinks`, by field index; `ParticleSettings_SetAxis`
  applies `LinkedAxis`); colors are Skald's picker (no alpha) plus an alpha slider. The ramp hides the start/end colors when on, and vice versa.
- **Color ramp editor** (`colorRampEditor`): a canvas (checkerboard, the gradient in 2 px slices,
  a marker per stop). Its mouse handling runs before it's built, from last frame's rect (like the
  scene tree's): a press near a marker grabs it, elsewhere on the bar adds a stop in the ramp's
  color there; while `State.rampDragging`, moving re-sorts the ramp and follows the stop
  (`e.ColorRamp_Sort` tracks it). `State.rampStop` is the selected stop.
- **Messages:** `Particle_Field_Changed` (a setting as text, `e.ParticleSettings_Set`),
  `Particle_Axis_Changed`, `Ramp_Edited` (the whole ramp as text plus the stop to select),
  `Particles_Reset` (also clears the texture). All `.Node` undo steps merged per setting;
  `Particle_Link_Toggled`, `Ramp_Stop_Selected`, `Ramp_Drag_Changed` are view state.
- **Viewport:** emitters make the preview animated; `syncTransforms` copies their settings every
  frame (so a slider drag shows at once without losing the particles), stops an emitter whose
  Emitting is off, and replays a one-shot one once its particles are gone.
- Tests: `particle_emitter_round_trip`, `particle_inspector_edits`, `viewport_shows_particles`
  (pixels from `Preview_Render`), and `tests/ui/particles.script` (real slider drags, the link
  button, ramp clicks and drags, alpha, typing a value, Shift drags, reset, the shape dropdown,
  undo). The driver's `click_at` / `drag_widget [shift]` press at fractions of a widget,
  `click_overlay_item` clicks a popup's choice (a dropdown's), `scroll_by` scrolls; checks
  `particle`, `particle_near`, `particle_linked`, `ramp_stops`, `ramp_stop`.

## Export (implemented, `export.odin`, `export_run.odin`)

**Settings:** Project Settings > Export lists every `ExportTarget` (desktop: Linux, Windows and
macOS on x86_64 and ARM64; Web; Steam; PlayStation 5, Xbox Series, Switch, generic until console
generations matter). Each target has a checkbox (`enabled`) and its own fields
(`EXPORT_TARGETS[t].fields`, described by `EXPORT_FIELDS`). They're `Project.exports`, a plain value
(`FixedText`), part of the `.Project` undo snapshot, saved as `export.ini` next to project.xml (only
targets that differ from the defaults; the file isn't created for untouched projects).
- File > Export (Ctrl+Shift+E) exports every checked target; with none checked it opens the Export
  tab. The tab's Export button applies the dialog, then exports the shown target
  (`Export_Target_Run` is the undo step, `Export_Requested` follows it with `cmd_now`, so the save
  happens after the step and the project isn't left "modified").
- Unimplemented targets fail with `Export_NotImplementedReason`. Desktop targets only build for the
  host (`Export_Implemented`); today that means Linux x86_64.

**Running:** `Export_Start` saves the project, then turns each target into a job: its
`Export_Plan` (in the job's own arena). Steps are child-process commands (output to the Output tab,
polled by `Export_Tick` like Play) or quick file steps done in `update` (`Make_Folder`, `Write_File`,
`Copy_Files`, `Bundle_Libraries`, `Remove_Folder`, which refuses anything outside
`build/exports/`). A failing step fails its target; the next one runs. Exports run beside Play.
Intermediate files go to `build/exports/<project>-<hash>/` in the editor's folder.
- The player is the engine's `player/` package, or (projects with scripts) the same generated main
  as Play (`playerMainSource`, which calls `e.Player_Main` so it builds for both targets).
- Output goes to `<project>/export/<target>` unless an output folder is set. `checkOutputDir` refuses
  folders that contain the project or sit in its scenes/, assets/ or scripts/.

**Linux x86_64:** for a project without scripts with a prebuilt player next to the editor, the
plan copies it (`Copy_File`, made executable) instead of compiling; otherwise
`odin build <player> -o:speed -out:<out>/<exe>` (odin: `Toolchain_Odin`). Then with **Single file** (the
default, `ExportTargetSettings.singleFile`) the project's files (project.xml as exported, each
scene's file, each asset) appended to the executable as the engine's data pack
(`ExportStepKind.Append_Pack`, `e.Pack_Append`): the export is one file. With it off, they're
copied to `<out>/data/`. **With the engine's static
SDL built** (its tools/build_sdl_static.sh; `Export_StaticSDLBuilt`, `ExportInput.staticSDL`) SDL
is inside the game: the export is the executable and `data/`, needing only libc (verified: ldd
shows libc, libm and the loader). Without it, `-extra-linker-flags:-Wl,-rpath,$ORIGIN/lib`, then
`ldd` on the game and the `libSDL3*` libraries it names copied to `<out>/lib/` under their
sonames. A game runs on the glibc it was built against or newer (see the engine's CLAUDE.md). The engine's player finds `data/project.xml` next to the
executable when it gets no folder argument. Other libraries (libc, GPU drivers, the libraries SDL3
itself links) come from the player's system. Archive: `tar -czf <out>.tar.gz`.
Verified: the export copied elsewhere runs from another folder with the bundled libraries (ldd),
with and without scripts.

**Web:** `odin build <player> -target:js_wasm32 -build-mode:obj` into `build/exports/.../web/`, the
project's files staged in `web/data/`, a page template (`Export_WebShell`: title, canvas scaled to
the window keeping its shape), then Emscripten's `emcc` (from `third_party/emsdk`, found without any
environment setup) links `<engine>/web/main.c`, the object, `-sUSE_SDL=3 -sUSE_SDL_TTF=3
-sALLOW_MEMORY_GROWTH`, the engine's `web/odin_env.js` and `odin_env_pre.js`, and
`--preload-file data@/data`, plus `build/web/libSDL3_mixer.a` and the engine's
`box2d/lib/box2d_web.o` (each built by a first step when missing), into `<out>/index.{html,js,wasm,data}` (`-O2` when optimizing). Archive:
a .zip made with `python3 -m zipfile` (Emscripten needs Python anyway). The engine side (platform
layer, frame loop, why each flag) is in the engine's CLAUDE.md, "Web build".
- **Sound:** the link includes `build/web/libSDL3_mixer.a`, SDL3_mixer compiled with Emscripten
  (`tools/build_web_mixer.sh`, run by `task emsdk`, `task web:mixer`, or the export's first step
  when it's missing). Browsers start sound after the player's first click or key press.
  Verified in headless Chromium: WAV, OGG, MP3, FLAC play (output samples measured); with the
  default autoplay policy, audio starts on a trusted click (DevTools protocol input).
- Limits: no SDL3_image Emscripten port exists, so web games load PNG and BMP only (it could be
  built the same way as SDL3_mixer, with its codecs).
- Verified in headless Chromium (served over HTTP, real time, console read; colors sampled from the
  canvas inside the page, never screenshots): scenes render at 60 fps, a click through the scaled
  canvas presses a menu button, a script runs, optimized and unoptimized.
- Missing Emscripten is reported with the fix: `task emsdk`.

**Tests:** `export_*` unit tests (ini round trip, plans' command lines, refusals, ldd parsing,
saving, the dialog and undo) and `tests/ui/export.script`, which really exports the fixture to both
targets (unoptimized; about 10 s once emsdk's port cache is warm).

**Emscripten for the user** (toolchain.odin): web exports use the checkout's emsdk submodule
when installed (`task emsdk`), else the data folder's (`Toolchain_EmsdkDir`). A web export
without one (or without SDL_mixer's sources, `Toolchain_SDLMixerDir`) installs them first
(`Toolchain_InstallEmscripten`: emsdk's pinned release tarball with curl and tar, `emsdk install`
/ `activate` (about 1 GB; needs Python), SDL_mixer's tagged sources) and runs once it's done
(`exportAfterEmscripten`); Settings > Toolchain has Install Emscripten too. Releases ship
`tools/build_web_mixer.sh` beside the editor (a macOS bundle in Resources/tools;
`Toolchain_WebMixerScript`). Checked by hand with a build that couldn't see the checkout
(`EMSDK_DIR`, `SDL_MIXER_DIR` pointed nowhere) and a scratch data folder: installed, built
SDL3_mixer from the downloaded sources, exported. (A UI script can't wait that long: the driver
stops scripts after 300 s.)

**Desktop exports on every OS** (`Export_Plan`, from its input: `ExportInput.host`): a desktop
target is compiled on its own machine, or (a project without scripts) made anywhere from its
prebuilt player next to the editor (`Export_Implemented`). Windows: `<name>.exe`, Hide console
(`-subsystem:windows`, or patching a prebuilt player's PE header: `Export_SetWindowsSubsystem`),
Odin's SDL3 DLLs beside it without the static SDL, the pack appended, a .zip (`Zip_Folder`, the
editor's zip). macOS: `<name>.app` (Contents/MacOS, Info.plist from `Export_MacInfoPlist`, the
project in Contents/Resources/data where the engine's player looks: no pack, which would break the
signature), the static SDL required, `codesign -s -` on a Mac, a .tar.gz (keeps the program
executable). **Headless:** `crossfire-editor <project> --export <target>` (`Export_Headless`)
runs a plan without a window (installing Emscripten first for the web); CI exports the UI fixture
on each OS with it and starts the game with the player's `--quit-after`.

**Future work (decided, not built):**
- **CI/CD on GitHub Actions:** build the editor and engine on every desktop platform (a runner per
  OS and architecture), run the unit and UI tests, show build statuses, and publish development
  binaries as releases. The other desktop export targets get built there too.
- The remaining targets: Windows (`-subsystem:windows` for Hide console; SDL can be static there
  now, `Export_StaticSDLBuilt` knows its `sdl3_static.lib`),
  macOS (`.app` bundle, dylibs in `Contents/Frameworks`, signing and notarization), Linux ARM64,
  Steam (Steamworks SDK, depots via `steamcmd`; Steam Deck = the Linux build), consoles (licensed
  SDKs).
- Other image formats on the web: build SDL3_image for Emscripten like SDL3_mixer (it needs
  libpng/libjpeg ports, which Emscripten has).
- Fold the SDL3_mixer build into the automatic toolchain setup above.

## macOS app bundle (`Taskfile.macos.yml`, `tools/macos/`)

`task macos:dist` makes `dist/macos/Crossfire Editor.app` and a disk image; `task macos:verify`
installs the image's app into a temporary folder and runs UI scripts with it. CI's macOS job runs
the same tasks (the Taskfile is included as `macos:`). Everything but Odin is in the bundle:

	Contents/MacOS/crossfire-editor, ols, prebuilt/<target>/player
	Contents/Frameworks/   libvulkan.1.dylib, libMoltenVK.dylib, whatever else dylibbundler finds
	Contents/Resources/    vulkan/icd.d/MoltenVK_icd.json, engine/ (sources, box2d/lib, sdl/lib),
	                       demo_project/ (the demo's git-tracked files)

- **Steps** (tools/macos/bundle.sh, one task each): `layout` (Info.plist from Info.plist.in, the
  binaries, the engine's git-tracked files without third_party/), `vulkan` (Homebrew's loader and
  MoltenVK, copied: SDL dlopens the loader, so dylibbundler can't see it; ids @rpath; the
  manifest's `library_path` rewritten to `../../../Frameworks/`), `dylibs` (dylibbundler, `-of`
  not `-od`, which would empty Frameworks; `@rpath` plus an rpath per executable's depth),
  `sign` (ad hoc, inside out: Apple Silicon runs nothing unsigned and install_name_tool breaks
  signatures), `check` (no Mach-O links outside `/usr/lib`, `/System` and the bundle; the
  prebuilt player links nothing bundled, since exported games carry no bundle; files present;
  `codesign --verify --deep --strict`).
- **SDL is static** (the engine's sdl/lib): the editor and players link no SDL dylibs. Skald
  loads Vulkan through SDL at run time; `bundle_darwin.odin` sets `SDL_VULKAN_LIBRARY` to the
  bundle's loader and `VK_DRIVER_FILES` / `VK_ICD_FILENAMES` to its MoltenVK manifest (unless set).
- **A bundle is read-only and starts in `/`:** `Editor_SetupBundle` makes the data folder
  (`Toolchain_DataDir`) the working folder, so Play's and Export's relative `build/` folders land
  there; settings live there too; the demo project goes to `~/Documents/Crossfire Editor/`
  (copied from `Resources/demo_project` on first run, since the bundle is read-only).
  Command-line and UI-script paths resolve against the folder the editor was started in
  (`Editor_ArgumentPath`: the driver's `import`, `open_project`, archives). The engine is found in
  `Resources/engine`, OLS beside the executable (`Code_FindOLS`), the prebuilt player in
  `MacOS/prebuilt/`. ols.json gets `odin_command` (the toolchain's odin, which needn't be in PATH).
- **No Homebrew `-L` with the static SDL:** CI's `ODIN_LINK_FLAGS` (`-L/opt/homebrew/lib`, for
  the dynamic fallback) comes before the engine's static folder, and macOS's linker takes the
  first folder that has a library: the first CI bundle linked Homebrew's SDL dylibs. The macOS
  tasks pass only `-headerpad_max_install_names` (room for dylibbundler's rewritten paths; OLS
  failed without it, so `macos:ols` builds its own optimized copy). `check` fails if any SDL
  dylib got bundled.
- **Spaces in paths:** "Crossfire Editor.app" found that the engine's static SDL `-L` wasn't
  quoted (the link failed); it is now (the engine's sdl_static.odin).
- **Tested on Linux with a fake bundle** (the real editor, OLS, prebuilt player and engine copy
  in `/tmp/fakebundle/Crossfire Editor.app/Contents/...`, `XDG_DATA_HOME` scratch): toolchain,
  ldtk, scripts (a game with scripts compiled against the bundled engine) and code_editor pass.
  The dylib, Vulkan, signing and disk-image steps only run on a Mac: CI.
- **CI:** `brew install go-task`, `task macos:deps`, `task macos:dist`, `UI=false task
  macos:verify` (install and bundle check), then `task macos:verify` with UI scripts (smoke,
  toolchain, ldtk, scripts) run by the installed app: MoltenVK gets a Metal device on GitHub's
  macOS runners. `verify.sh` unsets the job's `SDL_VIDEO_DRIVER=dummy` (no Vulkan there). The
  release ships the `.dmg`.
- **The host target** (`Toolchain_HostTarget`) comes from `ODIN_OS` / `ODIN_ARCH`: it once came
  from the implemented exports, so on a Mac there was none and Play never used the prebuilt
  player (the installed app's toolchain.script found it).
- **Later:** a Developer ID signature and notarization with gon (`task macos:notarize`,
  `tools/macos/gon.json.example`, `entitlements.plist`); an app icon.
- OLS is pinned in code_editor (`OLS_REF`): `c96dea91` is the newest that builds with Odin
  dev-2026-10 (newer OLS needs `core:odin/tool-format`). UI test tasks build it (`ols`):
  toolchain.script expects a language server.

## CI and releases (`.github/workflows/build.yml`)

**The website and downloads** (2026-10-22): after `release`, the `downloads` job uploads the
release's files to Cloudflare R2 (bucket `crossfire-downloads`, served at
downloads.crossfireengine.io: `releases/<tag>/<file>` and `latest.json`) with the repository's
`R2_*` / `CLOUDFLARE_ACCOUNT_ID` secrets, then dispatches `editor-release` to the website repo
(bcrowe306/crossfire-astro) when a `WEBSITE_DISPATCH_TOKEN` secret exists; otherwise the
website's hourly check notices the new release. The website (crossfireengine.io) publishes this
repo's `docs/manual/` at the release's tag: keep the manual's frontmatter and relative links as
they are (see `docs/manual/`'s row in the code map). Issue templates: `.github/ISSUE_TEMPLATE/`.

**Linux and Windows packages:** an AppImage (`tools/linux/make_appimage.sh`, `task
linux:appimage`; CI's combine job makes it from the Linux archive with every player; appimagetool
is downloaded and run extracted, no FUSE needed) and an installer (`tools/windows/
crossfire-editor.iss`, Inno Setup 6, preinstalled on GitHub's Windows runners: the
`windows-installer` job). Both run the editor **installed** (`Editor_Installed`, bundle.odin:
$APPIMAGE set, or the editor's folder not writable): settings and build folders in the data
folder, the demo copied to ~/Documents/Crossfire Editor from the release's
`examples/demo_project`. Checked by hand: the AppImage from a locally made release archive, run
with a scratch home (`--appimage-extract-and-run`): the demo copied, `build/` in the data folder.

**Every release has every platform's prebuilt player:** each build job uploads its player
(`player-<platform>`); the `combine` job (Ubuntu) adds the others' to the Linux and Windows
archives (`prebuilt/<target>/`), `combine-macos` (a Mac) to the app's
`Contents/Resources/prebuilt/` (codesign takes only Mac programs in Contents/MacOS; the app is
signed again ad hoc) and remakes the disk image; the release publishes those (`final-*`).
`Toolchain_PrebuiltPlayer` looks in both places, so any release exports games without scripts for
every desktop OS. Each build job also exports the UI fixture headless and starts the game
(`--quit-after`).

Pushing a `v*` tag builds and tests on Linux x86_64 (ubuntu-24.04), Windows x86_64 (windows-2022)
and macOS arm64 (macos-15), then publishes a GitHub release of the three archives if all
pass (tags with a `-`, like `v0.1.0-dev.1`, make pre-releases). The README's badge shows the
latest run. The workspace's `ci-fix` skill (`.claude/skills/ci-fix/`) watches a run, finds why it
failed, fixes it and builds again with the next tag.
- The engine's `main` is checked out next to the editor (`odin_sdl_engine/`), and its
  `tools/ci/setup.sh`, `tools/ci/zig_toolchain.sh` (Linux) and `tools/build_box2d.sh` set things up. The emsdk submodule isn't
  fetched (desktop builds don't need it).
- macOS uses the bundling tasks instead (above): its release asset is the `.dmg`.
- `tools/ci/package_editor.sh` packs the built editor (Linux, Windows) (settings and fonts are built in), the demo
  project's git-tracked files in `examples/demo_project` (where `Editor_DemoProject` finds it), its SDL3 libraries when SDL isn't static, this platform's prebuilt
  player (`prebuilt/<target>/player`; SDL DLLs beside both on Windows only without the static SDL,
  which CI now builds there too: `ldd` checks no SDL library is loaded), and the engine's
  sources in `engine/` (git-tracked files without `third_party/`, plus `box2d/lib` and `sdl/lib`;
  about 17 MB). Each archive has only its own platform's player: exports only build for the host
  so far. Projects with scripts need Odin (Settings > Toolchain installs it) and a linker.

## Documentation (required)

All public code in this repo and the engine has **Odin-style doc comments**, and the docs are
published to GitHub Pages.

### Writing docs

Use the format of Odin's own `core` library, which `odin doc` and pkg.odin-lang.org render:

```odin
/*
One-line summary of what it does.

More detail when needed: behavior, ownership, when to call it.

Inputs:
- scene: The scene to add the node to
- name: Display name shown in the hierarchy

Returns:
- The new node's index

Example:
	index := Scene_InsertNode(scene, "Player", .Sprite, -1)
*/
```

- **Coverage:** every public type, procedure, constant and enum. Document struct fields with a
  comment above or beside each one.
- **Code blocks:** examples are tab-indented under `Example:`, and must compile. Check them by
  extracting them into a scratch package and running `odin check`.
- **Package docs:** each package's overview lives in one file, `doc.odin`, as a `/* */` block directly
  above `package`. Any other file-level overview needs a blank line between it and `package`;
  otherwise it becomes the package doc.
- **Private helpers** (`@(private)` / `@(private="file")`) get a short `//` comment when the reason
  isn't obvious.

### Generating and hosting

The site is built with Odin's own generator, the one behind pkg.odin-lang.org
(github.com/odin-lang/pkg.odin-lang.org):

1. Build the generator: `odin build . -out:odin-doc` in a checkout of that repo.
2. Make a file that imports every package to document (e.g. `docs/all/all.odin`).
3. Run `odin doc docs/all/all.odin -file -all-packages -doc-format -out:editor`.
4. Write a JSON config (`docs/config.json`): `hide_core`, `hide_base`, `url_prefix`, and a
   `collections` entry with `name`, `source_url`, `base_url`, `root_path`, `license` and `home`.
5. Run `odin-doc editor.odin-doc docs/config.json` inside the output directory.
6. Deploy that directory with a GitHub Actions workflow (`.github/workflows/docs.yml`) to GitHub Pages.

The generator renders Markdown through `vendor:commonmark`, which must be installed on Linux CI.
Neither the docs workflow nor `docs/` exists yet.

## Conventions

Match the engine's style:
- Types are `PascalCase`.
- Procedures are `Type_Action` (`Scene_InsertNode`), and constructors are `CreateThing`.
- Fields and locals are `camelCase`. Constants are `SCREAMING_SNAKE_CASE`.
- Indent with tabs.
- Import the engine as `e`, Skald as `skald`, SDL as `sdl`.
- **Memory:** the per-frame temp allocator is for anything that dies within the frame
  (`fmt.tprintf`). Long-lived data belongs to an explicit owner (project, scene, panel) and is freed
  with it. Strings in a `Msg` only live for the frame: clone them in `update` before storing.
- **Delete folders with `removeAll`** (export_run.odin), never `os.remove_all`: on Windows that
  goes through the shell (SHFileOperationW), whose COM copy hooks crashed the tests running on
  several threads.

## UI tests (input injection)

`crossfire-editor <project> --script <file>` runs a test script inside the editor.
`test_driver.odin` documents the commands, including:
- input: `click_widget`, `click_row`, `click_node`, `drag_node`, `scroll`, `key`, `type`
- `import` (bypasses the native file dialog)
- checks: `expect`, `wait_until`

Highlights:
- **Input is real.** The driver pushes SDL events (`sdl.PushEvent`), which reach Skald exactly like a
  user's input, so the whole path from widgets to `Msg` to `update` is tested.
  - Clicks move the mouse a frame before pressing, like a real mouse (widgets that act on press
    check hover from the previous frame).
  - Clicks land in the center of the widget's visible part.
- **Widgets are found by key**, not coordinates. A widget built with `id = skald.hash_id("toolbar-play")`
  is clicked with `click_widget toolbar-play`; its rectangle is read from Skald's widget store
  (`ctx.widgets.states`) without touching its state. **Give every widget a test should reach a
  stable `hash_id` key.** Existing keys:
  - toolbar buttons `toolbar-<name>`, panel buttons `panel-<name>`
  - the Console and Output tabs: `console-scroll` / `output-scroll` (the list; `-area` the list or
    its placeholder), `-line-<i>`, `-search`, `-level-<Level>`, `-categories`, `-follow`
  - trees `browser-tree` / `scene-tree`, the search box `browser-search`
  - dialog buttons `dialog-<name>`, the viewport `viewport-canvas`
  - Add Node dialog: `add-node-search`, rows `add-node-<Kind>` (e.g. `add-node-Sprite`), `add-node-cancel`
  - the scene tree's context menu `scene-tree-menu` (`right_click_row`, `click_menu_item`)
  - Git tab: `git-init`, `git-message`, `git-commit`, `git-change-<i>`, `git-new-branch`,
    `git-create-branch`, `git-remote-url`, `git-add-remote`, `git-pull`, `git-push` (view_git.odin)
  - Settings dialog: `settings-tab-<Tab>`, `settings-search`, `settings-key-<Action>-<slot>`,
    `settings-save` / `settings-apply` / `settings-cancel` (see view_settings.odin)
  - Project Settings: `project-settings-tab-<Tab>`; Export tab `export-enable-<Target>`,
    `export-target-<Target>`, `export-field-<Field>`, `export-run`, `export-cancel`
  - Camera inspector: `inspector-camera-<CameraField>-<node>` (numbers, the Target and Follow mode
    selects, the limits' `Limit_<Side>_On` checkboxes), zoom `inspector-Zoom-<node>`
  - ParticleEmitter inspector: `inspector-particle-<setting>-<node>` (`-x` / `-y` for pairs,
    `-alpha` for colors), `inspector-particle-link-<setting>`, `inspector-particles-reset-<node>`,
    `inspector-ramp-<node>` and its `-add-`, `-remove-`, `-position-`, `-color-`, `-alpha-` controls
- **UI tests run on `tests/fixtures/ui_project`**, not `examples/demo_project`: the demo is what
  `task run` opens, so it changes when you use the editor. Update the fixture on purpose when a
  test needs different content.
- **Don't assert timing-dependent results** (undo merging) in UI scripts: when the editor window
  isn't visible, the compositor may throttle its frames. Unit tests cover timing with fake clocks.
- **Rows must be in view.** `click_row`, `right_click_row` and `drag_row` fail on a row scrolled
  out of the tree's visible area. The scene tree pane is short; collapse nodes to keep rows in view.
- **Tree rows** are clicked by row index using `TREE_ROW_HEIGHT`; keep trees on that row height.
- **Never read the screen.** The driver checks editor state, never pixels, and nothing here may
  screenshot the desktop: the user's other windows can be on screen. To check rendering, call
  `Preview_Render` from a scratch test and save its pixels. Skald's own off-screen renderer is
  private to Skald, so snapshots of the UI would need a public Skald API first.
- `task test:ui` runs each script on a fresh scratch copy of `tests/fixtures/ui_project`
  (`build/ui_project`), because scripts save, rename, play and import. The editor window opens while it runs. On a
  workspace that isn't visible, the compositor may throttle it, and the run takes minutes instead
  of seconds.
- Add a script, or extend one, for each new interactive feature.
- The driver waits until the window size has been stable for `WINDOW_SETTLE_TIME` (1.5 s) before
  the first command: a tiling window manager resizes a new window after it opens, sometimes more
  than 0.5 s later, and a click aimed at the old layout misses (the first script of a run failed).
- `action <Action>` sends an action, for menu-bar entries without a shortcut.
- **UI tests never start a real code editor:** `tests/ui/settings.ini` (copied to the scratch
  settings file) sets `code_editor_path = true`. Unit tests that create scripts set it too.
- `scripts.script` really builds a project player (a few seconds unoptimized, longer when the engine
  changed) and plays it.
- `scroll_into_view <scroll> <widget>` pages a scroll container until the widget is visible: widgets
  far outside a scroll aren't laid out, and keep stale rects. A `wait_until` that passes lets a few
  frames settle before the next command.
- A game window (Play) makes a tiling window manager shrink the editor's window, which moves every
  rect: stop the game before clicking things that may move.
- **Modifier clicks:** Skald reads Ctrl/Shift from key events, not mouse events, so the driver
  holds the modifier key around the click (`click_row ... ctrl`, `click_node ... shift`).
- **A script's `ctrl` is the platform's command key** (`PRIMARY_KEYMOD`: Cmd on macOS, as the
  keymap's Ctrl is there), so the same scripts pass on a Mac; `control` presses the Control key
  itself.
- A context menu fades out after closing and blocks clicks under it meanwhile; the driver waits
  for that (`FADING_MENUS`) before the next command.

## Verifying work

- `task verify` (check + tests) must pass before saying anything works. The vet flags are limited to
  this package (`-vet-packages:crossfire_editor`) because Skald itself has unused imports.
- `task test` fails a test that leaks or frees badly (`ODIN_TEST_FAIL_ON_BAD_MEMORY`): drafts
  and dialogs free what they own on close and in `State_Destroy` (`ProjectSettings_Destroy`).
- Logic (the serializer, model, undo, export command lines) gets `odin test` tests. Pay particular
  attention to XML round trips.
- Interaction: add or extend a `tests/ui` script and run `task test:ui` **and**
  `task test:ui:fullscreen`. On a tiling window manager the normal window can be tiny (here about
  640x660, a bottom panel 200 px wide), so wide layouts only get exercised fullscreen (1280x720).
- Layout: run the editor and look at it yourself (or ask the user). A type check proves nothing
  about layout, and automated checks must not capture the screen.
- Exports: build the exported game and launch it. Report each target honestly as verified, untested,
  or blocked.
- **Vulkan validation** (after any change to how the editor or Skald use the GPU): run the UI
  scripts with the Khronos validation layer and its synchronization checks, and expect no
  `Validation Error` lines:
  `VK_LOADER_LAYERS_ENABLE='*validation' VK_KHRONOS_VALIDATION_VALIDATE_SYNC=1 task test:ui SCRIPT=...`
  (the layer is the `vulkan-validation-layers` package; without installing it, unpack the package
  somewhere and point `VK_LAYER_PATH` at its `explicit_layer.d` with the manifest's
  `library_path` made absolute). The first run (2026-10-22, the shared GPU renderer) found four
  bugs, all fixed: SDL 3.4's Vulkan pipelines are picked by the swapchain's format (the engine's
  `RENDER_TARGET_FORMAT`), and in Skald a vertex buffer shared by two frames in flight, the
  swapchain acquire barrier's stage, and leaked image streams.
- **Editing files with scripts:** never `open(path, 'w')` before the new content is ready; a failure
  in between empties the file. (That happened to this file once.)

## Decisions made

- **SDL3_mixer for the web is built from a submodule** (`third_party/SDL_mixer`, 2026-10-16),
  because Emscripten has no port; its version follows the native library's.
- **Emscripten is a pinned git submodule** (`third_party/emsdk`, 2026-10-16): reproducible web
  builds with a known version; installing it (`task emsdk`, ~1 GB) is a separate step, to be
  automated (see Export, future work).
- **The editor gets the engine through a workspace path.** The `engine` collection is set from
  `ENGINE_DIR` in the Taskfile, not a submodule.
- **Scenes load at runtime from XML.** An engine-side loader and a generic player read them; no
  code generation.
- **Game code is written in Odin, not a scripting language.** Lua (`vendor:lua`) stays out unless
  modding support is wanted.
- **Scripts attach to nodes, several per node** (2026-10-16; several since 2026-10-22, with node
  types of game code and hot reload by restarting with the game's state: the user's choice). A project's `scripts/` package is
  compiled into a per-project player; each script registers itself (`e.Script_Register` from an
  `@(init) proc "contextless"`), scene files attach it by name, and the editor learns its exported
  fields from `player --describe-scripts`. See "Scripts" above and the engine's `script.odin`.
- **Scripts are edited in an external editor**, set in Settings: the program
  (`code_editor_path`, a path or a name found in PATH, default `zed`; the user uses Zed) and its
  arguments (`code_editor_args`, default `{file}:{line}`). Older files' single `code_editor`
  command is split on load. **Zed's app binary (`zed-editor`) can't open files in a running Zed**
  ("zed is already running"); only its command-line tool can (`zed` in Zed's installs, `zeditor` in
  Arch's package; the user's `~/.local/bin/zed` is a symlink to the app). `Script_ZedCLIFor`
  detects the app (through symlinks) and Open uses the CLI instead; Settings warns.
- **Built since:** node types registered by game code (`kind="Player" baseKind="Sprite"`), several
  scripts per node, hot reload (a rebuild and a restart with the game's state, not a shared
  library: the state would need to survive a code change either way), and the built-in code
  editor using OLS.
- **Node transforms are relative to the parent**, with UI nodes (Label, Menu) following position only.
  The camera is a node.

## Open decisions (confirm with the user before building on them)

- Minimum supported OS versions and CPU architectures for each export target.
