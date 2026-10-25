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
  installed there before needs installing again).

Users create projects, build scenes from nodes, manage assets, write game code, run their game
and export it to the desktop platforms and the web (later: Steam, consoles).

**Status (2026-10-23):** usable, released as development builds (`v0.1.0-dev.N`).
- **Editing:** the engine-rendered viewport (select, move, rotate, scale; guides, grid, snapping,
  align, the Zoom and Pan tools), the scene tree (drag, rename, copy / paste, components),
  multi-select, right-click menus everywhere, undo / redo of every edit, Settings (look, keymap,
  toolchain) and Project Settings, recent projects, project archives, the Git tab.
- **Node kinds** edited in the inspector, most with their own panel: sprites and Aseprite files
  (layers, slices, tags), AnimatedSprites and animation assets (the Animation panel), TileMaps
  (the Tiles tab), LDtk levels, physics (bodies, shapes, joints, materials, collision traced
  from sprites), particles (CPU and GPU; the Particles tab: the settings by category, presets,
  Restart), sound (players, the Mixer, bus effects, music layers),
  UI controls and themes, 2D lighting, navigation, cameras and camera tools, lines and trails,
  shaders and screen effects, skeletons (meshes, IK, DragonBones), dialogue, state machines (the
  States tab's graph and sidebar: conditions, guards, priorities, exit times, live while playing), the
  Timeline (Animators), touch controls.
- **Game code:** Odin scripts on nodes (several per node), node types, globals, data resources,
  events and listeners; the built-in code editor (OLS completion, clickable errors, and the
  project's own completions, hovers with previews (images, sounds with a play button, animation
  frames, dialogue lines, components, fonts) and the engine's documentation (F1 opens its API
  entry in the docs window), color swatches with a picker, problems, gutter markers and drops through code_editor's
  providers; the names engine calls take, completed and checked inside their strings, with
  quick fixes; gutter markers listing every node using a script or setting a field, Find Usages
  in the scenes, and renames of scripts, fields and events carried into scenes, components,
  globals, listeners and Timeline tracks; drops of nodes, inspector properties, events, groups,
  animations, states, input actions, buses, clips, scenes and assets that become a field, a
  statement or a constant by where they land, Shift for a menu of choices) or an external one; the script index (the scripts' declarations read from their
  source as they're typed, before any build); typed constants for assets, animations, states,
  groups, buses, scenes, dialogue nodes and node paths (scripts/assets.odin); Play / Play
  Scene / Restart, hot reload, the live view of the running game, and the running game in the
  code (live field values beside the declarations, Alt+drag on a default's number changing the
  game with a write-back menu, log points built in through hot reload; engine-aware code actions in Ctrl+.'s menu: a handler for
  a node's event, export a field (with a range), a switch over a state machine's states, register
  a struct, add a hook, and the jump between an inspector field and its declaration); editor
  plugins (plugin_api/).
- **Export:** Linux, Windows and macOS (built on their own OS, or for projects without scripts
  from the prebuilt players every release carries) and the web (Emscripten, installed on
  demand); headless (`--export <target>`).
- **CI and releases** (`.github/workflows/build.yml`, a `v*` tag): Linux x86_64, Windows x86_64
  and macOS arm64 built and tested (unit tests, a headless export run, UI scripts on macOS),
  published as a GitHub release (archives with every prebuilt player, an AppImage, a Windows
  installer, a macOS disk image), uploaded to R2, then the website deployed.
- **The sprite sheet slicer** (`slicer_edit.odin`, `view_slicer.odin`): a center tab per image
  (beside the scene and code tabs) cutting a sheet by a grid or by its sprites (auto-detect),
  frames picked on the picture, animations named from them (a row each), previewed, then an
  animation asset, the selected AnimatedSprite's or a new one's (see "The sprite sheet slicer").
- **Docs in the editor** (`docs.odin`, `docs_window.odin`, `view_docs.odin`, `markdown.odin`): a
  docs window over the editor showing the bundled manual (with a guide to every node kind) and
  the engine's API reference, offline, from F1, Open Docs in every right-click menu and code tab,
  and the panels' Manual buttons (see "Docs in the editor" below).
- **Editor modes** (`editor_modes.odin`, `level_mode.odin`): the mode bar beside the menus
  switches the workspace between the **Scene** mode (everything above) and the **Level** mode,
  the LDtk level editor laid out as LDtk (all five phases, 2026-10-24/25: the user's design; parity with LDtk checked feature by feature in the manual's level_parity.md): a
  the editor's toolbar (LDtk's tools per layer type in the viewport tools' place), the Levels sidebar (worlds, levels:
  select, focus), the canvas (the world, or a focused level; levels and entities picked and
  moved, links drawn; **painting** as LDtk: IntGrid values with the auto-layers worked out by
  LDtk's rules ported (byte-identical to LDtk's samples), tiles (stamps, random, flips, stacking),
  entities placed, moved, resized, copied, removed, their points and references picked on the
  canvas; one undo step a stroke), the Layers sidebar (select, eye, drag to reorder, the layer's
  palette), LDtk's panels as bottom tabs (World, Level, Layers, Entities, Enums, Tilesets,
  Auto-layer Rules, Project) editing the world, fields' values, references and **every
  definition as LDtk's panels do** (layers, IntGrid values and groups, entity types, every field
  type, enums and external enum files, tilesets and their tiles' tags and data, level fields;
  every level kept in step by LDtk's tidy, ported) and **the auto-layer rules as LDtk's rule panel
  does** (groups: optional per level, biomes, colors, icons, the Assistant's; rules and their
  editor: tiles, the 9 x 9 pattern with LDtk's buttons, every option; the Rule Assistant;
  duplicate and remap; LDtk's clipboard; written as LDtk's toJson writes them and applied again in
  every level, the canvas outlining a rule's cells) and **levels, worlds and the project as LDtk
  does** (levels made on a picked spot, renamed, copied, resized from any side, deleted, their
  backgrounds and depths; worlds added and removed (Multi-worlds), their layouts; LDtk's selection
  of cells, entities and points moved, copied, deleted; field values drawn as LDtk's display modes
  draw them; saved tile selections; every project panel option, LDtk's extra save outputs:
  backups, PNG images, the simple export); edits in memory, saved into the `.ldtk` file with the project (Ctrl+S, Play, exports),
  undoable, LDtk's own saves merged; the scenes showing each level, a scene made for a level, Open
  in LDtk at a level); built from the editor's own widgets and sizes (the toolbar, panel headers,
  the scene tree's rows, the inspector's rows; the user's correction of 2026-10-25), its list tabs
  in one shared layout (view_list_tab.odin); see "Editor modes" and "Editing LDtk projects" below.
- **The website** [crossfireengine.io](https://crossfireengine.io) (`../crossfire_astro`,
  bcrowe306/crossfire-astro) publishes this repository's `docs/manual/` and the engine's doc
  comments (see "Documentation").
- **Not yet:** Steam and console exports (Steam's settings exist, the engine has a stub
  backend), CI players for Linux ARM64, Windows ARM64 and macOS x86_64 (those export only on
  their own machine, untested), images other than PNG and BMP on the web, a Developer ID
  signature and notarization on macOS, a running game's levels in the Mixer's meters, picking up
  files added to `assets/` outside the editor.

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
| `task sdl` | Build the engine's static SDL (`<engine>/tools/build_sdl_static.sh` into `<engine>/sdl/lib`; CMake; Linux, macOS, Windows with Visual Studio). The editor and every game then link SDL in (a single executable). A dependency like `box2d`; skipped when built |
| `task box2d:web` | The engine's Box2D for web exports (`task emsdk` runs it; exports build it when missing) |
| `task submodules` | `git submodule update --init --recursive` (Skald, emsdk) |
| `task emsdk` | Install Emscripten into the `third_party/emsdk` submodule (`EMSDK_VERSION`, ~1 GB, once per machine), then `web:mixer`. Web exports need it |
| `task web:mixer` | Build SDL3_mixer for the web (`tools/build_web_mixer.sh` → `build/web/libSDL3_mixer.a`); exports also build it when it's missing |
| `task stb` | Build Odin's STB libraries Skald needs (`build_stb.sh`; Windows: Odin's `build.bat`, needing `cl` and `lib`, though Odin's Windows release has them built). Skipped when already built for the active Odin install |
| `task check` | Type-check with `-vet-unused -vet-packages:crossfire_editor` (Skald itself doesn't pass vet) |
| `task test` | Unit tests (`editor_test.odin`) |
| `task test:code-editor` | The built-in code editor's own unit tests (`code_editor/`, its Taskfile) |
| `task ols` | Build OLS into `code_editor/third_party/ols` (its `ols:build`; skipped when built) |
| `task verify` | `check` + `test` |
| `task test:ui` | UI test scripts (`tests/ui/*.script`) driving the real editor with injected input: headless, several at once (`tools/ui_tests.sh`), in a 640x660 window like a tiled one; `SCRIPT=<file>` for one, `JOBS=<n>` workers (default half the CPUs; `JOBS=1` serial) |
| `task test:ui:fullscreen` | The same in a 1280x720 window, like a fullscreen one |
| `task test:ui:short` | The same in a short 900x500 window (squeezed panels: run it after layout changes) |
| `task test:ui:visible` | The scripts one at a time in a real window on the desktop, to watch (`FULLSCREEN=true`: the `EDITOR_FULLSCREEN` build) |
| `task build` / `task build:release` | Debug build into `build/`, optimized build into `build/release/` |
| `task run` | Build optimized (`build/release/`) and run; program arguments after `--` |
| `task run:debug` | Build with `-debug` and run (unoptimized: the viewport ran at ~14 fps vs 60) |
| `task run:fullscreen` | Optimized, with `-define:EDITOR_FULLSCREEN=true` |
| `task player` | Build the engine's player into `build/player/player` |
| `task play:demo` | Run the demo project (its scripts linked into its own player: `tools/demo/player`), without the editor |
| `task demo:playtest` | Play the demo headless (`tools/demo/playtest`: a bot pressing keys), check its mechanics and levels, save frames to `build/playtest/` (`PART=title|forest|hollow|lair|gameover`) |
| `task profile` | **Profiling** (Spall; "Profiling" below): the scenarios `tests/profile/*.script` in a `-define:SPALL=true` optimized build, headless, `--runs` each (default 3), the report over all runs (pooled), its JSON and the median run's trace in `build/profile/results/`; arguments after `--` go to `tools/profile.sh` (scenario names, `--auto`, `--no-build`, `--runs`, `--cpus`) |
| `task profile:baseline` / `task profile:compare` | Keep the results and the build as the baseline (`build/profile/baseline/`) / profile and compare with it, the baseline build's runs interleaved with the new one's: exit 1 when a scenario's mean frame (the median jumps between frames with and without a viewport render) grew more than `--threshold` (5%) |
| `task clean` | Delete build output |

- **Windows:** Task's own shell can't start a `.sh` file there, so the tasks that run the engine's
  bash scripts (`box2d`, `sdl`, `shadertools`) put `{{.SH}}` (`bash ` on Windows, nothing elsewhere)
  before them: run `task` in Git Bash, whose `bash` is then in PATH. `box2d`'s status checks
  `{{.BOX2D_LIB}}` (`box2d_windows_amd64.lib` there, `.a` elsewhere); `stb` runs Odin's `build.bat`
  there (`platforms:`) and checks for `stb_truetype.lib`. Checked with `task --dry --force` on a
  copy of the Taskfile with the OS filled in (Windows can't be run here).
- `EDITOR_FULLSCREEN` exists for checking the full layout on a tiling window manager (Hyprland
  here), which otherwise squeezes the window into a tile (`task run:fullscreen`, `task
  test:ui:visible FULLSCREEN=true`). The headless UI runs pass `--window-size <w>x<h>` instead
  (a fixed window, never fullscreen; editor.odin's `Args.windowSize`).
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
  demo to copy does `Project_CreateDemo` write a reduced built-in one (an outline of the demo:
  its title, options and an empty level, made of UI controls, no images).
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
| `editor_modes.odin` | **Editor modes**: `EditorMode` (Scene, Level), `EDITOR_MODES` (each mode's registration: name, icon, its `view`, its bottom tabs, its manual page, the `Action` switching to it), `Mode_Layout` / `Mode_LayoutOf` (each mode's panel sizes), `Mode_BottomTab`, `Mode_ShowBottomTab` / `Mode_ShowLogTab`, `Mode_Set`, `.editor/modes.ini` (`Mode_Save` / `Mode_Load`), the mode bar (`modeBarView`), `modeWorkspaceView`, `Modes_Update` |
| `level_mode.odin` | **The Level mode** (LDtk's layout: the doc block has the picture): `LevelMode` (`State.level`: its layout, bottom tab, file and world, selected level, entity and layer, the focused level, the tool, the canvas's `LevelView` and `LevelDrag`, the tabs' items, the last edit's problem, the conflict dialog), `LEVEL_LAYOUT_DEFAULT` (the Scene mode's sidebar widths), `levelModeView` (the Levels sidebar, the canvas over the bottom panel, the Layers sidebar: the Scene mode's splits and `FittedSidebarWidths`), the bottom lists' widths (`listWidths`, `List_Tab_Resized`), `levelMapView` (the canvas's header, the disk bar), `LevelMode_File`, `LevelMode_World` / `_WorldLevels`, `LevelMode_ScenesShowing`, the `Level_*` / `LDtk_*` messages (`LevelMode_Update`: rows, focus, worlds, layers, tools, canvas presses, drags and releases, edits and renames the scenes follow, the disk bar's answer), `LevelDrag_Target` (where a drag lands: GridVania's grid, an entity's layer grid), `LevelMode_Status`, `ldtkConflictDialogView` |
| `level_canvas.odin` | **The world canvas**: `levelCanvasView` / `LevelCanvas_Build` (input from its last rect: the painting tools first on the focused level; the levels' pictures with each layer's opacity, entities, links, the painting overlay; a focused level's neighbours dimmed), `LevelCanvas_Content` (the shown world's levels, entities (shapes, tiles, a stroke's previews: resized, erased, a copy's ghost) and links in world pixels, a drag's target applied), `LevelCanvas_Fit` / `_FitOnce` (the world or the focused level), `LevelCanvas_WorldToWindow` (the driver's) |
| `level_paint.odin` | **Painting in the Level mode** (phase 2; its doc block has LDtk's buttons and keys): `LevelPaint` (`LevelMode.paint`: the picked value per layer, tiles per tileset, entity type, flips, random, LDtk's toggles, the `LevelStroke`, a `LevelPick` waiting, the chain), the focused level's model (`LevelPaint_Model`, kept across strokes, rebuilt per document version), `LevelPaint_PlanPress` (what a press does: a grid stroke, erase, resize, point, place, Alt pick / copy, a pick, refused with why), `LevelPaint_Press` / `_Moved` / `_Released` / `_Commit` (one `LDtkDoc_Commit` a stroke), entity boxes and handles (`LevelEntityBox`, `LevelPaint_HandleAt`, LDtk's isOver and ResizeTool), `LevelPaint_Update` (the palette's picks, the keys' actions, Delete, Ctrl+D), `LevelPaint_Classify` (the history's labels), `LevelPaint_Cursor` |
| `level_canvas_paint.odin` | **The painting overlay**: `LevelOverlay` (grid lines, the brush's cells, rectangle or stamp image, the selected entity's handles, its points' path, the hint: why a press did nothing), `LevelOverlay_Build` / `_DrawGrid` / `_Draw` / `_DrawHint`, `LevelEntity_Draw` (an entity as LDtk draws it: its shape, color, alphas, tile) |
| `level_layers_render.odin` | **The level pictures**, drawn as LDtk's LayerRender from the decoded levels: the focused level a picture per layer in `LEVEL_CHUNK` pieces (only changed pieces drawn and uploaded, `LEVEL_RENDER_BUDGET_MS` a frame), others one composite; backgrounds (`__bgPos`), IntGrid colors, auto tiles in display order, tiles with LDtk's pivot slip (`LevelPictures_Update` / `_Pieces` / `_Draw`, `LevelPictures_BrushImage`, `LevelPictures_RedrawDirty`) |
| `view_level_palette.odin` | **The palette** under the Layers sidebar (LDtk's IntGridPalette, TilePalette, EntityPalette): IntGrid values (`level-value-<v>`), the tileset with LDtk's selection rules (`level-palette-tiles`; Stamp / Random, flips, stacking toggles), entity types (`level-entity-type-<uid>`) |
| `ldtk_level_model.odin` | **A level decoded for painting**: `LDtkLevelModel` (its layers' IntGrid values, grid tiles and auto tiles per cell, rule area counts, what changed, the tilesets' opaque tiles), `LDtkLevel_Read`, the layer edits (`LDtkLayer_SetIntGrid`, `_AddTile`, `_RemoveTiles`...), `LDtkLevel_Patches` (the changed layers written back as LDtk writes them: fast text writers) |
| `ldtk_rules.odin` | **LDtk's auto-layer rules, ported** (its AutoLayerRuleDef, LayerInstance.applyAllRules...): rules and groups read, `LDtkRule_Matches`, LDtk's seeds (`ldtkRandSeedCoords` with JavaScript's number semantics) and Perlin noise (heaps' `hxd.Perlin`), stamps, offsets, `breakOnMatch`, `LDtkRules_ApplyArea` / `_AfterChange` / `_ApplyAll`, evaluation and display order, biomes / optional groups |
| `ldtk_paint.odin` | **LDtk's painting tools on a model**: `LDtkPaintMode`, `LDtkTileBrush` (stamp, random, flips, stacking), `LDtkPaintStroke`, lines (Bresenham), `ldtkFloodFill` (LDtk's order), IntGrid cell / line / rectangle / fill, tiles at a cell, stamps, rectangles, fills, removal |
| `ldtk_entity_ops.odin` | **Entity edits LDtk makes** (`LDtkOps_EntityEdit`): added (LDtk's JSON key order, `maxCount` / `limitScope` / `limitBehavior`), removed (references to it dropped), resized, duplicated, a point moved, array and symmetrical references; new iids (`LDtk_NewIid`), the table of contents rebuilt |
| `ldtk_json_pretty.odin` | **LDtk's JSON writer, ported** (its JsonPretty): `LDtkJV` values, `LDtk_PrettyJson` (Compact / Minified: lines up to 85 columns, number grids 35 a row, rules on one line), `LDtk_JsNumber` (JavaScript's `String(n)`) |
| `view_level_tools.odin` | **The Level mode's tools** (on the editor's toolbar: view.odin's `toolbarView` puts them in the viewport tools' place): `LevelTool`, `LEVEL_TOOLS` (icons, names, what each does: all work since phase 2), `LevelTools_For` (LDtk's tools per layer type), `LevelMode_LayerDef` / `_LayerType` (the selected layer), `LevelTool_Available` / `_Look` / `_Tip`, the toolbar's overflow menu's items (`LevelTools_MenuItems`, `Ctx_Toolbar_More{level}`) |
| `view_level_sidebars.odin` | **The Level mode's sidebars**, the Scene mode's panels (`panelHeader`, `rowList` rows): Levels (+ New Level in its header, the file and world choices, a row per level: select, double-click focus, its menu `Ctx_Level` / `LevelMode_MenuItems`), Layers (the selected level's layers: select, the eye, a row dragged to reorder as the scene tree's: file state `layerRowDrag`, an overlay line; the palette under them), `LevelLayer_Icon` |
| `view_ldtk_tab.odin` | **The Level mode's LDtk tabs** (`LevelMode_LDtkTab(s, ctx, tab)`: World, Level, Layers, Entities, Enums, Tilesets, Auto-layer Rules, Project, in view_list_tab.odin's layout: `tabListItem`, `tabTool`, `tabItemChoice` fill its list and toolbar row; `tabRow` is the inspector's row), each tab's rows (the world and its choice, the level with its scenes, fields and neighbours, a layer with its IntGrid values and the scenes' collision kinds, entity types with their fields, instances and references, enums, tilesets, the rules (view_ldtk_rules.odin), the file's settings), text fields keeping what's typed in `State.numberEdit`, number fields (`LDtkNumberTarget`) |
| `ldtk_rule_ops.odin` | **The Auto-layer Rules tab's edits** (`LDtkOps_RuleEdit`, the `Rule_*` ops): a layer's groups read as LDtk's fromJson reads them (`LDtkRules_ReadGroups`, `LDtkGroupEdit`), changed, written as its toJson writes them (`ldtkGroupJV`, `ldtkRuleJV`) after its rule tidy (`LDtkRule_Tidy`: trim, mirrors, checkers, out-of-bounds), then LDtk's tidy and the rules applied again (`rerunRules`); `LDTK_RULE_MEMBERS` (the options and LDtk's bounds), groups, rules, patterns, tiles, LDtk's clipboard (`LDtkRules_CopyText`, `Rule_Pasted`), duplicate and remap, the level's optional groups, seed and tileset; `LDtkRules_At` (the rules of a cell), `LDtkRules_BiomeValues` |
| `ldtk_rule_assistant.odin` | **LDtk's Rule Assistant, ported** (RulesWizard): `LDtkWallFragment` (its parts in LDtk's order, their grid places, patterns and mirrors), `LDtkAssistant` (the choices; `_Encode` / `_Decode` for the edit, `_Import` reads a group back), `ruleAssistant` (the group made or made again) |
| `level_rules.odin` | **The rules tab's state** (`LevelRules`, `State.level.rules`: the page (list, rule editor, Assistant, remap, icon, color), the groups opened, the edited and last rules, the editor's value (`LevelRules_SmartValue`: RuleEditor's pick), the Assistant's and remap's choices, LDtk's clipboard), `Rules_View` / `LevelRules_Update` (none of it undone), `LevelRules_BeforeEdit` / `_AfterEdit` (a cut copies; a new rule opens its editor, a new group its name), what the pointer is over (`LevelRules_SetHovered`, `_SetCanvasCell`, `_AtPointer`) |
| `view_ldtk_rules.odin` | **The Auto-layer Rules tab** (`LDtkRules_Tab`): its sidebar list (the layers with rules), its toolbar row (+ Group's menu, Paste, Randomize, Render), the list (the level's tileset; groups' headers with grip, toggle or eye, icon, name, biomes, + / EDIT, menu; rules' rows with grip, toggle, pattern preview, chance, opacity, flags, insert), grips' drags (file state `rulesDrag`), the rule editor (tiles and stamps on a tile picker `rTilePicker`, pivot, the value palette, the 9 x 9 pattern grid with LDtk's buttons `rPatternGrid`, out-of-bounds, every option, the modulo preview), the Assistant's page (its parts' grid), Duplicate and Remap, icon and color pages, the menus (`Ctx_Rules_New`, `Ctx_Rule_Group`, `Ctx_Rule`: `LevelRules_MenuItems`) |
| `ldtk_json.odin` | **JSON that keeps its text**: `Json_Parse` (a flat tree of nodes with their spans), lookups (`Json_Get`, `Json_At`, `Json_Items`, `Json_String`, `Json_Path`), patches (`Json_SetPatch`, `Json_AppendPatch`, `Json_InsertPatch`, `Json_AddMemberPatch`, `Json_RemovePatch`, `Json_Apply`), values written like their neighbours (`Json_Quote`, `Json_FormatNumber`, `Json_Object`, `Json_Array`, minified files kept minified) |
| `ldtk_doc.odin` | **An LDtk project's files as the Level mode edits them, in memory**: `LDtkDoc` (the .ldtk file and its levels' .ldtkl files: each one's text, what's on disk and whether it's unsaved; worlds, levels), the cache (`LDtkDoc_Get`: read again when a file changes, LDtk's change merged into unsaved edits or waiting: `LDtkDoc_DiskConflict` / `_ResolveDisk`; `LDtkDoc_Outside`), lookups (levels' rects as LDtk lays them out, definitions by uid, layer instances, entities by iid), `LDtkPatches`, `LDtkDoc_Commit` / `_SetTexts` (in memory), saving (`LDtkDoc_Save`, `LDtkDocs_SaveProject`, `LDtk_WriteFile`: atomic, the modification time always moved on), what the engine reads of it (`LDtkDoc_Stamp`, `LDtkDoc_GameText`, `LDtkDoc_ProvideToGame`) |
| `ldtk_ops.odin` | **The LDtk edits**: `LDtk_Edit` (`LDtkEditOp`: layers, entity types, fields, instances, references, levels' places and fields, IntGrid values, enums, the world), `LDtkOps_Apply` (each op's patches and the mirrors LDtk keeps: `__identifier`s, `__type`s, enum values everywhere, `__grid`, `__opacity`, layer instance order, neighbours, world positions, the table of contents), LDtk's rules ported (`LDtk_CleanIdentifier`, `LDtkDoc_Neighbours`, layout changes, `LDtk_SnapToGrid`, field values and defaults), `LDtkOps_GridSizeLocked`, `LDtkOps_FieldLocked`, `LDtkOps_RefAllowed` |
| `ldtk_tidy.odin` | **LDtk's tidy, ported** (`LDtkTidy_Run`: Project.tidy and what toJson derives): definitions' lost references cleared, every level's layer instances and field instances as the definitions want them (added, removed, ordered), every derived value (`__identifier`, `__type`, `__cWid`, `__value` from `realEditorValues`, smart colors and tiles...) written where it differs; `LDtkTidyScope`, `jvSame`, `tidySet`, `ldtkRebuildRows`, `ldtkNewLayerInstance`, `ldtkToWhite` |
| `ldtk_defs.odin` | **The definitions editors' edits** (`LDtkOps_DefEdit`): `LDTK_MEMBERS` (every member the panels set, its kind and bounds: `LDtkMember`, `LDtkMemberKind`), `memberValue`, `ldtkUniqueId` (Project.fixUniqueIdStr), uids from `nextUid`, `LDtk_ParseTags`, `rerunRules` (auto-layers applied again in every level) |
| `ldtk_defs_ops.odin` | `Def_Set` (`defConsequences`: LDtk's handlers; `defSpecial`: grids, render modes, ranges, defaults by type, regexes, file types, reference rules), `layerGrid` (LayerInstance.remapToGridSize), new definitions in LDtk's key order (`newLayerJV`, `newEntityDefJV`, `newFieldJV`, `newEnumJV`), removal, copies, moves, field type conversions (`LDTK_CONVERSIONS`), `LDtk_DisplayModeAllowed` |
| `ldtk_defs_more.odin` | IntGrid values and groups, enum values, external enums (`LDtk_ParseExternalEnums`: text, JSON, Haxe, CastleDB; `LDtk_Checksum`, `LDtkEnums_SyncPreview`), tilesets (`newTilesetJV`, LDtk's icons, `tilesetImage`, `tilesetGrid`, `remapTileIds`, `LDtk_PixelData`: LDtk's opaque tiles and average colors), tiles' tags and custom data |
| `ldtk_level_ops.odin` | **Levels and worlds as LDtk edits them** (`LDtkOps_LevelEdit`: `Level_Added` / `_Removed` / `_Duplicated` / `_Set` / `_Depth` / `_Resized` / `_Sorted` / `_World_Moved`, `World_Added` / `_Removed` / `_Set`), `LDtkOps_LevelsFinish` (tidy, neighbours, world positions, table of contents), LDtk's rules ported (automatic names, `LDtk_LevelSpot` / LevelSpotPicker, linear insert points, `__bgPos`: `LDtk_BgTileInfos`, external file names, Multi-worlds conversion), `tidyLevels` / `tidyLevelFiles` |
| `ldtk_project_ops.odin` | **The Project tab's edits** (`LDtkOps_ProjectEdit`: `Project_Set` every option, `Project_Flag`, `Project_Command`), the identifier style applied everywhere, `LDTK_IMAGE_EXPORT_MODES` / `_IDENTIFIER_STYLES` / `_COMMAND_TRIGGERS` / `_ADVANCED_FLAGS`, `tidyLegacyIntGrid` (ExportPreCsvIntGridFormat's `intGrid` arrays, in the tidy and every commit) |
| `ldtk_field_ops.odin` | **Field values** (`LDtkOps_FieldValue`: set, add, remove, move, clear an item, FieldInstance.parseValue's rules), `LDtk_ApplyRegex` (a small regex engine: LDtk keeps the matched parts) |
| `ldtk_save_extras.odin` | **What LDtk's save writes besides the files**: backups (`LDtkSave_Backup`, `LDtk_PruneBackups`), PNG images (`LDtk_PngFileName`), the simple export (`data.json`, CSVs), removed when turned off (`LDtkSave_Exports`) |
| `ldtk_selection_ops.odin` | **LDtk's selection moved, copied, deleted** (`Selection_Edit`, `LDtk_SelectionText` / `_Parse`: cells, entities, points, empty-space rectangles; GenericLevelElementGroup's rules) |
| `level_world_tools.odin` | **The world tools on the canvas** (WorldTool, LevelSpotPicker, Rulers): a new level's spot, the right-click menu (`LevelWorld_MenuItems`), level drags (snapping, linear order, Ctrl + Alt copies), the focused level's resize handles, world depths; `LevelWorldOverlay` |
| `level_select.odin` | **The selection on the canvas** (`LevelMode.selection`): rectangles (Shift + Alt, the Select tool), moved and copied by drags, Ctrl+A, Delete, empty spaces (Shift+E), `LevelSelectOverlay`, `LevelSelect_Summary` (the header) |
| `level_fields_render.odin` | **Field values on the canvas** (FieldInstanceRender): `LevelFields_Make` (rows above / at the center / beneath, radii, points, reference links by display mode), `LevelFields_DrawRows`, `LevelFields_DrawMark`, `LevelFields_DrawLink` (LDtk's link styles) |
| `view_ldtk_project.odin` | **The World, Level and Project tabs' rows** (LDtk's world panel, level form and project panel): `LDtkProject_WorldTab`, `LDtkProject_LevelSettings`, `LDtkProject_ProjectTab`, `pivotPicker` |
| `view_list_tab.odin` | **The bottom tabs' shared layout** for a tab managing a list (the Level mode's World, Level, Layers, Entities, Enums, Tilesets, Auto-layer Rules; the Project tab without a list): `ListTab_Layout` (the widths first: the sidebar, kept per tab; a dropdown under `LIST_TAB_COMPACT_WIDTH`; the content's rows as `Inspector_Layout` lays them out), `ListTab` / `ListTabItem` (the list, the toolbar row's buttons and text), `listTabView` (the toolbar row, the sidebar's `rowList` beside the content in a split, `List_Tab_Resized`) |
| `view_ldtk_defs.odin` | **The definitions editors' UI** in the Layers, Entities, Enums, Tilesets and Level tabs (`LDtkDefs_Layers`, `_Entities`, `_Enums`, `_Tilesets`, `_LevelFields`): lists' buttons, members' rows, the field form (`defsFieldForm`), `tilesetPicker` (tile rectangles, tags, a tile), `LevelMode_SelectMade` |
| `update.odin` | `update`, the only place State changes |
| `keymap.odin` | `DEFAULT_KEYMAP`, shortcut dispatch, typing guard, the platform's keys (`Chord_OnPlatform` / `Chord_FromPlatform` / `Chord_Format`: the keymap's Ctrl is Cmd on macOS), `keyParen` (an action's keys for text) |
| `context_menus.odin` | **Right-click menus everywhere**: `ContextTarget` (what was clicked), `State.contextMenu`, `Context_Menu_Opened` / `_Closed`, `ContextMenu_Items` (the items per target: nodes, empty viewport, the tree, the browser's every kind, tabs, logs), `contextMenuView` (Skald's `popup_menu`, built first in the frame), `rightPressOpens`, the commands without an older message (`Node_Command`, `Add_Node_Here`, `Paste_Here`, `Tab_Command`, `File_Command`, `Log_Command`, `Asset_Add_To_Scene`) |
| `context_menus_panels.odin` | The bottom panel's menus (`Ctx_Graph`): States, Dialogue nodes and steps, Timeline tracks and keys, Mixer strips, Git changes, Live nodes, Animation frames, plugins |
| `viewport_tools.odin` | **Viewport tools**: Align and Distribute (`Align_Nodes`, `Align_Moves` on `Viewport_NodeShapes`' boxes), the Zoom tool's click or box (`ViewportTools_ZoomBox`), guides (`SceneDef.guides`, `Guide_*` messages, `Guides_Snap` / `Guides_SnapNode`, `.editor/guides.ini`: `Guides_Save` / `Guides_Load`) |
| `editor_theme.odin` | **The editor's look**, edited live in Settings > Appearance (and its contrast check: `CONTRAST_PAIRS`, `Contrast_Ratio`, `EditorTheme_ContrastProblems`): `ThemeColor` (Skald's roles), `Settings.themeColors` / `themeColorsSet` / `cornerRadius`, `EditorTheme_Apply` (in `Settings_Theme`), `THEME_PRESETS`, `ThemeColor_Format` / `_Parse` (editor.ini's `[theme]`); the canvases' colors (`ViewportColor`, `ViewportColors`, `ViewportColor_Default`, `ViewportBg_Bytes`) |
| `project.odin` | Project model (`Project`, `SceneDef`, `NodeDef`, `AssetDef`), node insert/remove, world transforms, `Project_Load` (through the engine's parser), the built-in outline of the demo (`Project_CreateDemo`) |
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
| `view.odin` | Root layout: menu bar with the mode bar, toolbar (every mode's: the Level mode's tools in the viewport tools' place, `Toolbar_Overflow` by the mode's tool count), the mode's workspace (the Scene mode's: `sceneModeView`), status bar, remove-asset dialog, panel header helpers (`panelHeader`, `panelButton`, `panelToolButton`: a panel button under its own key, with a label or pressed) |
| `view_browser.odin` | Left sidebar: project browser (search, tree, collapsible preview panel) |
| `view_browser_info.odin` | The preview for scripts (`scriptInfoPreview`: what each registered script and data type is, where it's used) and scenes (`scenePreview`: facts, actions, the scene's own settings) |
| `scene_settings.odin` | A scene's own settings (`SceneDef.settings`, the engine's `e.SceneSettings`): their messages and undo |
| `node_listeners.odin`, `view_inspector_events.odin` | **Listening to node events**: the inspector's Events section (`eventsSection`), the Listen... dialog (`listenerDialogView`), attaching (`Listener_Attach`: the listener on the node, the handler appended to the script's file) |
| `asset_fields.odin` | An asset's field in a script struct (a drop in the struct: code_drops.odin): its handle type and the line using it (`AssetField_Type`, `AssetField_Line`) |
| `node_fields.odin` | Script node fields: paths between nodes (`Scene_NodePath`), the nodes a field takes (`NodeField_Choices`), the script struct in a file (`NodeField_FindStruct`: its fields and their lines), a node's field line (`NodeField_Line`, for drops: code_drops.odin) |
| `code_drops.odin` | **Drops into code**: `DropSource` (what a panel drags: its kind, name, node, asset or scene, detail), `CODE_DROP_KINDS` (the one table: each kind's name type and shape in a struct), `codeUseKeys` (which of the engine's `e.CODE_USES` apply), `CodeDrops_Build` (the choices by syntactic context: a field, a statement, the constant or expression, the name in a string), `CodeDrops_PropertyField` (an inspector label's engine field) |
| `code_previews.odin` | **Previews in code hovers**: `CodePreviews_Constant` / `_Asset` / `_Scene` / `_Literal` (an image's thumbnail, a sound's length and play button, an animation's strip, a dialogue node's lines, a component's picture, a scene's facts, a font's sample), the picture cache (`PREVIEW_CACHE_MAX`), `Preview_Fit` / `Preview_Strip` / `Preview_FontSample` / `Preview_LiteralAt`, the play button's `Code_Hover_Audio` |
| `code_colors.odin` | **Color literals in code**: `ColorLiterals_InLine` / `ColorLiteral_Write` (composites, named, hex in a color field's tag or `e.ParseColor`), the swatch inlay provider (`colorInlays`, `colorSwatchClicked`), the Color dialog (`CodeColorDialog`, `State.codeColor`, `Code_Color_*`, `CodeColorDialogView`, `CodeColors_Rewrite`: one edit in the tab) |
| `engine_docs.odin` | **The engine's documentation in code**: `EngineDocs` (its source's declarations and doc comments, files' overviews and the package's, read once on a worker: `EngineDocs_Start` / `_Load` / `_Read`), `EngineDoc_Markdown` (the hover), `ENGINE_API_AREAS` (the website's api-groups.json: slugs, titles, descriptions, files; checked by a test), `EngineDoc_URL` (an entry on the website), `EngineDocs_At` (the name at a column) |
| `markdown.odin` | **A small Markdown parser** for the docs window: `Markdown_Parse` (frontmatter, headings with Starlight's anchors, paragraphs, lists, tables, fenced code, quotes, rules) into an `MdDoc` (its own arena), `Markdown_Inline` (bold, italic, code, links, images, escapes), `Markdown_Slug` (github-slugger's anchors), `MdDoc_PlainText` |
| `docs.odin` | **The docs' pages**: `DocsLibrary` (`Docs_Library`: the manual from `Docs_ManualDir`, the API reference made from `EngineDocs` as the website's build-api.mjs lays it out), addresses as the website's paths (`Docs_ManualAddress`, `Docs_URL`, `Docs_FromURL`, `Docs_ResolveLink`), `Docs_Search`, the lookups (`DOCS_NODE_GUIDES`, `DOCS_ASSET_PAGES`, `DOCS_BOTTOM_TAB_PAGES`, `Docs_EngineAddress`, `Docs_TypeAddress`, `Docs_EngineNameAddress`) |
| `docs_window.odin` | **The docs window's state and messages**: `DocsWindow` (`State.docs`: history, search), `Docs_Opened` and the other `Docs_*` messages (`Docs_Update`), `Docs_Navigate`, F1's panel (`Docs_TrackPointer`, `Docs_HelpAddress`), `Docs_BrowserAddress`, `Docs_MenuItem` |
| `view_docs.odin` | **The docs window** (`docsWindowView`, `docsWindowContent`): header, sidebar (contents or search results), the page rendered from its blocks (rich text with links, tables, Odin highlighted with code_editor's tokenizer, images), long pages measured once and built only where in view (`docsLayout`), anchors scrolled to; driver probes `Docs_VisibleAnchor`, `Docs_LinkRect` |
| `code_live.odin` | **The running game in the code**: the live values' inlay provider (`liveInlays`, `liveInlayClicked`: the struct line's node and its menu, each field's value), which running node (`CodeLive_Target`), the watches for the visible lines (`CodeLive_Watches`, `CodeLive_Frame` from `view`), scrubbing a default's number (`liveScrubTarget` / `liveScrubbed` / `liveScrubChosen`, `CodeScrub_Literal`), the write-back (`Code_Scrub_Write`, `CodeLive_Write`), `CodeLive_Messages` (what the providers left) |
| `log_points.odin` | **Log points**: `LogPoints` (`State.logPoints`, `.editor/logpoints.ini`: `LogPoints_Follow` / `_Parse` / `_Format` / `_Save`, `_Relocate`), where one can go (`LogPoint_Check`), the injected statement (`LogPoint_Statement`, `LogPoint_Inject`), the build's copy (`LogPoints_WriteBuild`, `LogPoints_BuildDir`, `LogPoints_ProjectPaths`), the gutter, inlay and menu providers, the Log Point dialog (`LogPointDialogView`, `Log_Point_*`) |
| `code_drag.odin` | **Dragging editor things into code**: `State.codeDrag`, `CodeDrag_From` / `_Zone` / `_Handle` (a widget, a label, a grip starts one), `CodeDrag_View` (the label by the pointer, the drop or cancel), `CodeDrag_HidesDialogs` (Project Settings steps aside for an input action), `Code_Drag_*` / `Code_Source_Dropped` / `Code_Drop_Chosen` |
| `script_index.odin` | **The script index**: `ScriptIndex` (`State.scriptIndex`), `ScriptIndex_ParseSource` (core:odin/parser: structs, fields with types, tags, comments, enums, `Script_Register` / `Data_Register` / `NodeType_Register` calls), `ScriptIndex_Take` (a broken file keeps its last good declarations), `ScriptIndex_Derive` (ScriptDescs like the catalog's, events, problems), `ScriptIndex_Plan` (changed files and still code tab buffers), engine calls' string literal arguments and procedures' lines (`IndexCall`, `IndexProc`: the name providers'), `ScriptIndex_Tick` / `_Parsed` (the worker), `ScriptIndex_Apply` / `_TakeBuild` (merged into `State.scripts`, the build authoritative where newer) |
| `script_constants.odin` | **scripts/assets.odin's constants**: `Scripts_Constants` (every constant, sections, `GeneratedConstant`), `Scripts_AssetsSource` (the file), `ConstantWords` (the new kinds' names), `Constants_ChangeMatters` / `Scripts_NewestFor` (a change to unused constants doesn't rebuild the player), Aseprite tags cached on the heap |
| `code_providers.odin` | **The code editor's providers**: `CodeProviders_Registry` (completion of the constants, hovers on constants and scripts, the index's problems, drops (code_drops.odin); the name providers of code_names.odin; the link providers of script_links.odin), `CodeProviders_Begin` / `_End` (the State they read), what the providers leave for the view (`CodeProviders_TakeOpen`, `_TakeRename`), `scriptUsers`, `CodeProviders_Constants` (cached per project version) |
| `script_links.odin` | **Code and scene links**: usages of a registered type, field or event (`ScriptLinks_TypeUsages` / `_FieldUsages` / `_EventUsages`: nodes, component instances, globals, data, Timeline tracks, listeners), the gutter markers with their choices and inlay hints, Find Usages and Rename providers, `ScriptRename_Project` (the project side of a rename; `dryRun` counts), `ScriptRename_Apply` (`Code_Rename_Requested`: the project as one `.Project` step, other files' edits in hidden code tabs), `ScriptLinks_Open` (`Code_Usage_Opened`) |
| `script_rename.odin` | **The code side of renames**: the scripts package parsed (`CodeModel`), each identifier classified (a package type, a field of a struct whose receiver type the code shows, `kind=` tags, engine calls' strings), `ScriptRename_SymbolAt`, `ScriptRename_Code` (edits, names taken, uses left alone) |
| `name_kinds.odin` | **Which engine parameters take which kind of name**, read from the engine's source (its name types, names.odin): `NameKind`, `NameTable_Read` (core:odin/parser; groups merged; `_Add` / `_Create` procedures declare), `NameTable_Start` / `_Load` / `_Get` (once, on a worker; heap, never freed), `NameTable_ParamKind` |
| `code_names.odin` | **Project-aware strings**: the name providers (`nameCompletions`: names inside a call's string, its kind's constants outside; `nameDiagnostics`: unknown names, "did you mean", quick fixes), the scenes' trees through component instances (`NameTree`, `treeResolve` as the engine's three lookups), a script's attachments, receivers (`self.node`, node fields), `Names_Check`, `Names_Closest` |
| `code_actions.odin` | **Engine-aware code actions** (Ctrl+.): the tab's text read for them (`CodeActions_Read`: structs with tag columns, registrations with their hooks, procedures), the action provider (`projectActions` / `projectActionRun`: handlers for events, export / remove export / ranges, a switch over a state machine's states, registering a struct, hooks, Show in the inspector), the Range dialog (`CodeRangeDialog`, `State.codeRange`, `Code_Range_*`, `CodeRange_Write`), `CodeActions_Reveal`, `ScriptField_Declaration` (the inspector's Go to Declaration) |
| `view_viewport.odin` | Center: scene tabs, view controls, and the viewport canvas (rendered scene, rulers, gizmos, input) |
| `viewport_preview.odin` | Engine-rendered preview of the open scene (the shared GPU renderer straight into a Skald image; fallbacks: a GPU readback, software); the collision LDtk levels and TileMaps build, drawn into it (`Preview_GeneratedShapes`) |
| `gpu_share.odin` | **The shared GPU renderer**: SDL's Vulkan renderer on Skald's device (`SharedGPU_Renderer`, `SharedGPU_Shutdown`), `GPUTarget` (a Skald `image_create_target` image as an SDL render target: `_Ensure`, `_Begin` / `_End`, `_Draw`, `_ReadPixels` for tests), used by the viewport and the code tabs |
| `viewport_math.odin` | Viewport pan/zoom math and drag (move/rotate/scale) math |
| `add_node.odin` | Add Node dialog logic: `AddNode_Kinds` (search over the engine's `SCENE_NODE_KINDS`), `AddNode_Create` (parent, unique name) |
| `node_edit.odin` | Subtree copy/paste/duplicate, `Scene_MoveNode` (reorder and reparent keeping the world transform), unique names |
| `history.odin` | Undo/redo: command history, automatic recording (`History_Classify`), merging; LDtk document steps (`FileChange`: the Level mode's, in memory: `History_RestoreFiles`, `History_MergeText`, `History_ResolveConflict`, `LDtkEdit_Info`; a big file's step keeps only its hunks: `FileText`, `FileHunk`) |
| `settings.odin` | `Settings`, loading/saving editor.ini over `settings.default.ini`, chord text, the Skald theme |
| `zip.odin` | Zip files: `Zip_Write` (stored), `Zip_List` / `Zip_Read` (stored and deflated, CRC checked), `Zip_SafeName` |
| `project_archive.odin` | Project archives (`.odinsdl`): `ProjectArchive_Create` (outside assets brought in), `ProjectArchive_Extract`, the File menu's flow |
| `vcs.odin` | Version control through `git`: `GitSnapshot` / `Git_ReadSnapshot`, `GitOp` / `Git_Commands` / `Git_RunCommands`, `Git_Update` |
| `process_exec.odin` | `Process_Exec`: the engine's `e.Process_Exec` under the editor's name (`os.process_exec` without its lost output: a program that wrote and exited between Linux pipe poll's two looks seemed to print nothing); every program the editor runs and reads goes through it |
| `view_git.odin` | The bottom panel's Git tab |
| `view_about.odin` | Help > About: the logo (the built-in 256 px icon, uploaded once), `EDITOR_VERSION` (`-define:EDITOR_VERSION`: the Taskfile's `git describe`, CI's tag), Odin's version, links (opened with `sdl.OpenURL`); `tests/ui/about.script` |
| `branding.odin` | `APP_NAME`, `APP_IDENTIFIER`; `Branding_SetAppMetadata` (the Wayland app ID / X11 class) and `Branding_SetWindowIcon` (the built-in 256 px logo) |
| `bundle.odin` | Running from a macOS app bundle: `Editor_SetupBundle` (the data folder as working folder, settings there, the bundled Vulkan through `bundle_darwin.odin`), `Editor_DemoProject` / `Editor_ShippedDemo` (where the demo is, and the shipped copy), `Folder_Copy`, `Editor_ArgumentPath` |
| `tilemap_edit.odin` | **TileMap nodes**: `NodeDef.tilemap` (the engine's `e.TileMapSettings`), `TileMap_Setting_Changed`, the inspector's rows (file, frame, layers, tile collision, what each layer becomes: `TileMapEdit_LayerInfo`), `Scene_AddTileMapAt` |
| `material_edit.odin` | **Physics materials**: `MaterialDef` (`Project.materials`), load / save / create, `Material_Field_Changed` / `Material_Created`, the material inspector (`materialInspector`) and a body's Material rows (`materialBodyRows`) |
| `collision_trace_edit.odin` | **Collision from sprite**: `TraceSettings` (`State.trace`), `Trace_Sprites`, `Trace_Pieces`, `Trace_MakeShapes` (`Collision_Traced`), the body inspector's rows (`traceInspectorRows`) |
| `camera_edit.odin` | **A Camera's follow target and settings**: `NodeDef.camera` (`e.CameraSettings`) and `cameraTarget`, `Camera_Changed` (`CameraNumber`), the Camera's inspector rows (`cameraInspectorRows`: Zoom; Follow, Limits, Shake groups) |
| `node_paths_edit.odin` | **Node paths that follow renames and moves**: `NodePathRef` / `NodePathKind` (cameras' targets, CameraViews' cameras, IK tips and targets, StateMachines' targets, SkinnedMeshes' bones, Timeline tracks, listeners' targets, script node fields from the catalog), `NodePaths_Resolve` before a change, `NodePaths_Repath` after (with a move's `newIndex`), `Scene_HasNodePaths` (a rename is a `.Scene` step then); tests in `node_paths_edit_test.odin` |
| `camera_tools_edit.odin` | **Camera tools**: `NodeDef.cameraTools` (`e.CameraToolSettings`) and `viewCamera`, `Camera_Tool_Changed` (`CameraToolNumber`), the ParallaxLayer / CameraZone / CameraView inspector rows (`cameraToolInspectorRows`) |
| `state_machine_edit.odin` | **State machines**: `NodeDef.stateMachine` (`e.StateMachineSettings`), `StatesEditor` (the machine shown, its selection), `SM_Changed` (`SMOp`; conditions' rows: `SMCondition`, `SMClausePart`, `States_EditClause`, `States_ConditionText`) / `SM_View`, `States_Update`, `States_Follow`, `States_Target` / `States_Animations`, `States_GuardNames` (the scripts' code guards from the index), the running machine (`States_LiveTarget`, `States_LiveFrame`, `States_Live_Watch`), `Scene_ResolvePath`, the inspector's rows |
| `view_states.odin` | The bottom panel's States tab (`StatesPanel`, `StatesPanel_Content`): the graph (`graphCanvas`: boxes, arrows with their conditions, guards and priorities, Any state, the running state lit; click, drag, double-click), the sidebar (`statesSidebar`: the selected state's or transition's properties, `conditionEditor`'s clause rows; beside the graph from `STATES_SIDEBAR_SPLIT_WIDTH`, else under it), the parameters, `States_Live` |
| `scene_flow_edit.odin` | **Scene changes**: `Project.transition` / `loadingScene`, Project Settings > General's rows (`sceneFlowSettingRows`, on the dialog's draft), `Project_Settings_Transition_Changed` / `_Loading_Changed` |
| `live_edit.odin` | **The live view**: `LiveView` (`State.live`: the running game's tree, chosen node's properties, stats, frame-time history), `Live_Send` (to the game's stdin), `Live_Ingest` (its `@@live` replies), `Live_Update`, `Live_Reset`, the game's collision shapes (`Live_SetShapes`, `PhysicsDebug_Shown`) |
| `view_live.odin` | The bottom panel's Live tab (`LivePanel`): pause / step, stats and the frame-time graph, the nodes, the chosen node's fields (side by side, or stacked in a narrow panel) |
| `nav_edit.odin` | **Navigation**: `NodeDef.nav` (`e.NavSettings`; a region's area is `shapeSize`), `Nav_Setting_Changed` (`NavNumberTarget`), the NavRegion and NavAgent inspector rows (`navInspectorRows`) |
| `light_edit.odin` | **2D lighting**: `NodeDef.light` (`e.LightSettings`), `Light_Setting_Changed`, `Scene_Lighting_Changed`, the light and occluder inspector rows (`lightInspectorRows`; occluders use `shapeRows`), the scene preview's lighting rows (`sceneLightingRows`) |
| `ui_edit.odin` | **UI controls** (Panel, Button, ProgressBar, TextField, ScrollBox, RichText, Slider, CheckBox): `NodeDef.ui` (the engine's `e.UISettings`), `UI_Setting_Changed` / `UIEdit_Update`, the inspector's rows (`uiInspectorRows`), `NodeKind_IsControl`, `UIKind_TakesImage` |
| `theme_edit.odin` | **UI themes** (`.theme.xml` assets, kind Theme): `ThemeDef`, `Project.themes` / `uiTheme`, load / save / create, the theme inspector (`themeInspector`, `State.themeSelection`), `Theme_*` messages |
| `timeline_edit.odin` | **The Timeline** (Animator nodes): `TimelineEditor` (the Animator edited, playhead, selection), `Timeline_Changed` (edits: node steps on the Animator) / `Timeline_View` (panel only), `Timeline_Update`, `Timeline_Follow`, track paths (`Timeline_ResolvePath`, `Timeline_PathTo`), `Timeline_Properties`, `Timeline_NodeValue` (what Key records) |
| `view_timeline.odin` | The bottom panel's Timeline tab (`TimelinePanel`: clip and transport toolbars, the tracks canvas with the ruler, keys and playhead, the key editor) and the Animator's inspector rows (`animatorInspectorRows`) |
| `tile_paint.odin` | **Tile painting**: `TilePainter` (tool, brush, layer, terrain), its messages, `TilePaint_Update` (strokes, fills, terrains, growing grids, copying file layers), `TilePaint_CellAt` |
| `view_tiles.odin` | The bottom panel's Tiles tab: layer and tileset choices, tools, flips, the tile palette (`TilesPanel`) |
| `docs/manual/` | **The user manual**: a page per feature for users new to the editor (`README.md` lists them in reading order), and the node guides (`nodes.md` and `nodes_*.md`: a `## <Kind>` section per node kind). Help > User Manual (F1), Open Docs and panels' Manual buttons open it in the docs window (`docs_window.odin`; `Manual_URL` is a page's address on crossfireengine.io). **Every new feature gets a page here.** Pages are ready for a static site (Astro, later): YAML frontmatter `title` / `description` (quoted when they hold `: `) / `order` (the reading order, unique, README 0; a new page takes its place and the ones after it move up), plain relative links, no GitHub-only syntax (no `> [!NOTE]`, no `<details>`), a Questions section at the end, examples that compile |
| `aseprite_edit.odin` | Aseprite files: the parsed-file cache (`AsepriteEdit_File`), the browser preview (`AsepriteEdit_Preview`, `AsepriteEdit_Summary`), Open in Aseprite (`AsepriteEdit_Open`, Settings > Editor > Aseprite program), `Image_LoadRGBA` (any image, Aseprite files through the engine), `Image_Size` (its size, cached per file time: the header only) |
| `ldtk_edit.odin` | LDtk levels: the inspector's LDtkLevel section, `LDtk_Setting_Changed`, the parsed-file cache (`LDtkEdit_Project`), importing with dependencies (`LDtkEdit_Import`), export files, Open in LDtk (at a level: `LDtk_RememberLevel` in LDtk's settings, `LDtk_SettingsPath`), the browser preview, `Scene_AddLDtkAt` |
| `toolchain.odin` | What building games needs, found at run time: `Toolchain_Odin` (setting, PATH, installed), `Toolchain_EngineDir`, `Toolchain_PrebuiltPlayer`, `Toolchain_Check` (Settings > Toolchain), `Toolchain_InstallOdin` |
| `settings_dialog.odin` | Settings dialog state and messages (edits a draft) |
| `view_settings.odin` | The Settings dialog: Appearance, Editor, Keyboard, Toolchain tabs |
| `settings.default.ini` | Default settings, built into the editor |
| `ui_tokens.odin` | **The design tokens** ("Design tokens" below): `Ui_Tokens` / `UiTokens_Of` / `uiTokens(ctx)` (the spacing scale, control and row heights, panel padding, section and button gaps, label columns, field and dialog widths, icon sizes, all from the look shown and the Row height setting), the text hierarchy (`Text_Role`, `TextRole_Style`, `uiText`, `uiSection`; `uiMonoFont`) |
| `tree_view.odin` | `coloredTree`: the browser's and scene tree's tree widget (skald.tree's behavior, plus per-row icon/label colors); `Tree_RowView` (one row's look: every list's), `rowList` (a list of keyed rows that look and act as the tree's: the Level mode's sidebars and bottom lists); type colors (`AssetKind_Color`); `Tree_RevealSelected` and `Scroll_RevealClicked` (keeping what was clicked in view) |
| `value_slider.odin` | `valueSlider`: a slider with a typeable value box, Shift for 10× finer drags (no jump to the pointer), and a reset-to-default button. Generic over the message type, its state kept in the file (not `State`), so it can move to a widget package |
| `number_field.odin` | `numberField`: text box with small flat −/+ buttons, used by the inspector and Settings; `NumberField_MinWidth` (never drawn narrower) |
| `code_editor/` | **The built-in code editor**: an Odin code editor on SDL3 (buffer, keymap, syntax, LSP client, `editor` = package `code_editor`, its own README, tests and Taskfile). Changed here: its `editor` package renamed `code_editor` (Odin package names must be unique: it was `editor`, ours then; ours is `crossfire_editor` now), and SDL_ttf calls taking `[^]u8` for this Odin |
| `code_editor_host.odin` | Hosting it in Skald: `CodeEditor` per open file (a `ce.Editor`, pointed at the providers' registry), the shown one drawn by the shared GPU renderer into `CODE_IMAGE` (else a software renderer and surface, uploaded when the pixels change), the SDL event watch feeding it input, focus (`CodeEditor_Frame`, `CODE_EDITOR_PASSTHROUGH`), the bundled font (Liberation Mono), `Code_FindOLS`, drops (`CodeEditor_Drop`), buffers for the index (`CodeEditor_Buffer`), test probes (`CodeEditor_HoverText`, `_LineNotes`, `_CompletionProvided`, `_WindowPoint`) |
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
| `project_data.odin` | Global scripts (`GlobalDef`) and data resources (`DataDef`) in the project; prop editing for any owner (`PropTarget`); creating, loading and saving data files; writing the generated `scripts/assets.odin` (`Scripts_WriteAssetsFile`, `ASSETS_FILE_MARKER`; its content: script_constants.odin) |
| `view_fields.odin` | `FieldControl`: the control for one exported field (numbers, bool, text, scene, vector, color, enum, asset handles), for node scripts, globals and data resources |
| `view_inspector_particles.odin` | The inspector's ParticleEmitter rows (`particleInspectorRows`: the summary `Particles_Facts`, Emitting and a preset inline, Edit in the Particles tab, a link per category) and the Particles tab's settings rows (`particleSettingRows`, `ParticleRows`: one group or all, the widths), built from the engine's `e.ParticleSettings_Fields` (sliders, linked pairs, colors with alpha, the color ramp editor `colorRampEditor`) |
| `particles_edit.odin` | **The Particles tab's model**: `ParticlesEditor` (`State.particles`: the emitter shown, its category), `Particles_Follow`, `Particles_Emitter`, `Particles_Target` (what the particle messages edit), `Particles_Categories` / `Particles_FieldGroups` (the engine's `group` tags, then All), `PARTICLE_PRESETS` (`Particles_Preset`), `Particles_Update` (`Particles_Category_Picked`, `Particles_Restart`, `Particles_Preset_Applied`) |
| `view_particles.odin` | The bottom panel's **Particles** tab (`ParticlesPanel`): the categories' column (names, icons, or a choice: `Particles_TabLayout`), the category's settings (`particleSettingRows`), the header (`particlesHeader`: name and live count, Restart, Emitting, One-shot, Preset, Reset, Manual) |
| `view_inspector_physics.odin` | The inspector's physics properties: layer grids (`layerGrid`), body, shape and ray fields, the points field; `shapeBody` (a shape's body) |
| `view_bottom.odin` | Bottom panel: the shown mode's tabs (the Scene mode's Console / Output / Animation / Mixer ... / States / Particles / Dialogue / Plugins, the Level mode's World / Level / Layers / Entities / Enums / Tilesets / Auto-layer Rules / Project / Console / Output), collapsible; the log tabs' view (`logView`: header of filters, a `virtual_list` of lines, `logFollow`) |
| `console.odin` | **The Console's and Output tab's lines**: `LogList` (`State.console` / `output`: lines with a level and category, the categories seen, counts, the history limit, filters, following), `LogList_Append` / `Trim` / `Clear` / `Shown`, `LOG_*_CATEGORY`, `LogLevel` (the engine's), `Console_Update` (the `Log_*` messages) |
| `console_test.odin` | Tests: categories and the limit, filters, the game's lines parsed, the messages and menus, the setting |
| `error_locations.odin` | **Clickable errors**: `ErrorLocation_Parse` (a line's `path(line:col)` / `path:line:col`, Windows drive letters, paths with spaces), `ErrorLocation_Resolve` (where the file is), `ErrorLocation_Open` (Go to Error: `Script_Open` at the line and column, read-only outside the project), `Path_InProject`; tests in `error_locations_test.odin` |
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
| `view_animation.odin` | The Animation panel (the animation editor): a toolbar (animation dropdown and buttons, name, starts-with; the selected animation's sheet, grid mode and values, margin, gap, offset, Slice a sheet… (the slicer); a sliced animation's note and Use a grid instead; frames, count, FPS, loop, mode, Plays (repeat), Frame times and each frame's ms; the sheet's leftover note; small groups in a `wrap_row`) over the preview and the thumbnails of its sheet's frames (`frameStrip`, cells drawn from the sheet uploaded once: `Image_LoadRGBA`); one scroll for all, which takes images dropped from the browser (`AnimationPanel_TakesDrop`) |
| `animation_edit.odin` | The Animation panel's logic: `AnimEditor` state, `AnimEdit_Update` (its messages), `AnimEdit_Cells` / `AnimEdit_SheetSize` (an animation's sheet's cells, from `Image_Size`), `AnimationDef_FrameAt` / `StepAt` (the frame at a time, as the engine plays it, durations and repeats too), `AnimationDef_Range`, unique names, `AnimEdit_IsEdit`, `AnimEdit_SheetNote` (leftover pixels), `AnimEdit_FpsDuration`, `AnimEdit_RenameReferences` (state machines and Timeline keys follow a rename) |
| `slicer_edit.odin` | **The sprite sheet slicer's model**: `SlicerState` (`State.slicer`: the tabs, the one shown, the preview's clock, a name being typed, the asset's name, Use the asset), `SlicerTab` (an image, its `SlicerSettings`, the picks, the shown animation and frame, the canvas's view), `SlicerSettings` (`SliceMode` Grid / Auto, the grid, auto-detect's settings and sprites found, `SliceAnimation`s, the asset made), the cells (`Slicer_CellCount` / `_CellRect` / `_CellAt` / `_RowOf` / `_Rows`), `Slicer_FindSprites` / `Slicer_Detect` (here or on a worker), `Slicer_AnimationDefs` (runs as a grid range, else rectangles; `Slicer_EvenOut`), the outputs (`Slicer_CreateAsset`, `Slicer_Apply`, `Slicer_AddToScene`), `Slicer_Update` (`Slicer_Changed{op: SlicerOp}`, `SlicerNumber`, `SlicerDurationTarget`), `.editor/slicer.ini` (`Slicer_Format` / `_Parse` / `_Load` / `_Save` / `_ReplaceSection`) |
| `view_slicer.odin` | **The sprite sheet slicer's tab** (`slicerCenterView`: the header, the canvas beside the controls from `SLICER_SIDE_WIDTH`, else over them), `SlicerTabs_View` (the strip's tabs), the canvas (`slicerCanvas`: input from its last rect, the sheet on a checkerboard, the cells in view, the picks numbered, the shown animation's frames), the controls (`slicerControls`, `slicerAnimationRows`: rows as the inspector's, the preview, the frame strip), the driver's `Slicer_CellCenter` / `Slicer_FrameStripCenter` |
| `animation_sets_edit.odin` | **Animation assets**: `AnimationSetDef` (`.anim.xml`, `Project.animationSets`: load, save when changed, make: `Project_CreateAnimationSet`), `AnimationDef` / set clone, equal and engine conversions, an Aseprite file's tags as a set (`AsepriteEdit_AnimationSet`), the panel's `AnimSource` (`AnimEdit_Source`), the browser preview, `Scene_AddAnimatedSpriteAt` |
| `icons.odin` | Font Awesome icon font (`assets/fonts`, OFL), glyph constants, the action icons (`ACTION_ICONS`, `Icon_Action`, `Action_Icon`: one icon per action) |
| `test_driver.odin` | UI test driver: runs a `--script`, injecting SDL input and checking state (format in its doc comment); `repeat <n> <commands>` (written out on load: `ScriptDriver_ExpandRepeats`), `profile_mark <name>` (a trace's mark) |
| `profiling.odin` | **Profiling with Spall**: `Profiling_Start` (Skald's trace, shared with the engine: `e.Trace_Share`) / `Profiling_Stop` (before any exit), `Profiling_Message` (`update`'s span, named by the message's type) |
| `tools/profile.sh`, `tests/profile/` | **The profiling harness** and its scenarios (driver scripts between `profile_mark start` and `end`): idle, inspector, browser, viewport, code, level, console |
| `editor_test.odin` | Unit tests for the model, XML round trips, transforms, assets, search, viewport math, keymap and update |
| `tests/ui/*.script` | UI test scripts, run by `task test:ui` |
| `tools/ui_tests.sh` | The UI test runner: headless editors (SDL's offscreen driver) on per-script copies of the fixture, `--jobs` at a time, longest first, per-script results, times and a summary; `--visible` for real windows |
| `tests/fixtures/` | Files tests import (`beep.wav`: a generated 1.5 s tone) |
| `test_project_test.odin` | `Project_CreateTestProject`: the unit tests' sample project (the old built-in demo: a menu, a play scene with a tree of sprites, options); the outline demo's test |
| `examples/demo_project/` | The demo game, "Legacy of the Wardens", shipped with the editor (see "The demo project" below). Its README lists what each part demonstrates |
| `tools/demo/make_demo.py`, `tools/demo/hero.lua` | Made the demo's art (from the Legacy-Fantasy pack: ImageMagick, and Aseprite for the hero's file) and its three LDtk levels (`assets/levels/legacy.ldtk`, from LDtk's JSON schema: every required key, validated; auto-layer rules and the tiles they make). Rerun only to start over: the levels are edited in LDtk now |
| `tools/demo/make_sounds.py` | Synthesizes the demo's music (layers of equal length, seamless loops) and the bees' buzz, Python's standard library and ffmpeg (OGG Vorbis) |
| `tools/demo/pick_sounds.py` | Copies the demo's sound effects from the workspace's GameSounds pack under the names its scripts use (the table of picks) |
| `tools/demo/playtest/` | The demo's headless playtest (`task demo:playtest`) |
| `tools/demo/player/` | The demo's own player (the engine's player with its scripts): `task play:demo` |

**Layout rules learned building it:**
- **Each mode owns its workspace and panel sizes** (editor_modes.odin): the dividers' messages
  (`Left_Resized`, `Center_Resized`, `Viewport_Resized`) and Toggle_Bottom_Panel change the shown
  mode's `Layout` (`Mode_Layout`); `Workspace_Measured` sets every mode's (one area). A mode's
  splits need ids of their own (`level-split-left`...): a split keeps its drag state by id.
  `State.layout` and `State.bottomTab` are the Scene mode's.
- **Every mode uses the editor's shared widgets and sizes** (the user's correction of 2026-10-25:
  "The Level editor looks like a different app"): one toolbar (`toolbarView`: a mode's tools in
  the viewport tools' place, `Toolbar_Overflow` by the mode's tool count), panel headers
  (`panelHeader`) and buttons (`panelButton`, `panelToolButton` for a kept key), list rows that
  are the scene tree's (`Tree_RowView`, `rowList`: `settings.rowHeight`, its font, icons, indent,
  selection colors; a row dragged to reorder, not a grip), the inspector's rows
  (`inspectorLabelled`, `Inspector_Layout`), the sidebars' default widths (`DEFAULT_LEFT_WIDTH`,
  `DEFAULT_RIGHT_WIDTH`), minimums and fitting (`FittedSidebarWidths`). A design or mockup gives
  the arrangement, not its pixel sizes, colors, corners or paddings: no mode-only sizes.
  Checked by `level_mode_layout_tools_worlds_and_layers` (the sidebars against the Scene mode's)
  and by measuring both modes' rects (2026-10-25: the toolbar's buttons 31 x 23 px at y 35 and
  the workspace at y 65 in both, rows 26 px, sidebars 240 / 300, fitted to 190 / 238 at 640 px).
- **A bottom tab that manages a list uses the shared layout** (view_list_tab.odin, the user's
  sketch): the tab strip, a toolbar row (the list's add / duplicate / delete / up / down and the
  tab's actions as panel buttons, then a text), then the list in a sidebar (`rowList` rows; a
  divider whose width is kept per tab) beside the selected item's settings in the inspector's rows;
  under `LIST_TAB_COMPACT_WIDTH` (480 px of panel: a tiled window's is about 200) the list is a
  dropdown over the settings. The widths are worked out before the rows are built
  (`ListTab_Layout`), since rows size their controls from them. A new list tab fills a `ListTab`
  and calls `listTabView`; a toolbar row's buttons keep their older keys (`panelToolButton`).
- **Another mode's widgets keep their last rects in Skald's store** (states live about two
  minutes unbuilt): code that hit-tests a widget's last rect without building it (the viewport's
  `ViewportHovered`, F1's `Docs_TrackPointer`) must check the mode first, or the Level mode's map
  counted as the viewport under the pointer.
- **The mode bar sits in the menu bar's row**, centered in what the menus leave, and is no taller
  than it: the Scene mode's layout is as it was. Under `MODE_BAR_COMPACT_WIDTH` it shows icons.
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
- Inspector fields use tight padding (`InspectorFieldPadding`: the `fieldPadding` token, 2 px vertical) and capped widths
  (`INSPECTOR_MAX_NUMBER_WIDTH` 120, `INSPECTOR_MAX_TEXT_WIDTH` 200). Position and Scale have a link
  toggle (`inspectorLinks`): a change to one axis scales the other by the same ratio
  (`LinkedAxis`; from 0 it moves by the same amount). Number widths leave room for that button:
  anything spilling into the reserved scrollbar strip is covered by the scrollbar and can't be
  clicked.
  **A narrow inspector stacks its rows** (`Inspector_Layout`, from the sidebar's width and the
  theme): when a label column beside a number field and its link button doesn't fit
  (`NumberField_MinWidth` + `LINK_BUTTON_WIDTH`: about 224 px of sidebar at the default look),
  `inspectorRow` / `inspectorLabelled` put the label over the control, which gets the row's
  whole width. It was a floor of 80 px under `controlWidth`, but a number field is never drawn
  narrower than about 80 px with its buttons: at the 180 px minimum every number row ran under
  the scrollbar, the linked rows below about 235. `inspectorStacked` is set while the right
  sidebar is built (`rightSidebarView`), so rows elsewhere never stack. Widths: every inspector
  takes `inspectorControlWidth(th, sidebarWidth)`, and a whole row (text across it, a row of
  buttons) `inspectorRowWidth(controlWidth)`, never `controlWidth + INSPECTOR_LABEL_WIDTH`.
  Tests: `narrow_inspectors_stack_their_rows`, `tests/ui/narrow_inspector.script` (180 px:
  numbers, link buttons, a particle emitter's summary, clear of the scrollbar and clicked).
  **Every inspector row must fit `controlWidth`**: it happened three times (the link button, the
  script Open button beside a dropdown held at its minimum width, the Camera's limit checkbox
  beside a number field held at `NumberField_MinWidth`). Put extra buttons on their own row, and
  check a new button with a UI click in a narrow window: `send Right_Sidebar_Width <px>` narrows
  the inspector, `clear_of_scrollbar <key> inspector-scroll` checks the row's end.
- **The toolbar fits the window** (view.odin's `toolbarView`, `Toolbar_Overflow`): its buttons all
  have one width, so its width is worked out, not laid out (building buttons twice to measure
  would make them take clicks twice). With everything it's about 680 px (19 buttons since
  Restart); a tiled window is about 650, so there the seven tools go into an overflow button
  (`toolbar-more`, ICON_ELLIPSIS, `Ctx_Toolbar_More`: the tools checked as they're active), and
  under about 480 px the file and undo buttons too. The play controls and Export always show.
  Tests: `toolbar_overflows_in_a_narrow_window`; live.script (`in_window toolbar-export`, the
  overflow menu's Zoom Tool through `if_drawn toolbar-more ...`: fullscreen draws the tools).
- **A tab strip wider than its panel must scroll (`hScroll`), not overflow:** the bottom panel's
  tabs ran past the panel into the inspector beside it in a tiled window, unclipped, and a
  dropdown's choice there also clicked the tab under it (mixer.script caught it once Tiles and
  Timeline made seven tabs). The bottom tabs scroll sideways like the center's
  (`bottom-tabs-scroll`; a UI script wheels it to reach a tab out of view).
- **A closed dialog must build no content** (`closedDialog`, at the top of every dialog view):
  Skald hit-tests a widget by its rect from the last frame it was *built* in, not drawn, so a
  closed dialog's buttons stayed clickable where they had been (a viewport click where the Add
  Node dialog's "Sprite" row had been added a Sprite; smoke.script caught it once the header's
  layout moved a node there). Skald now checks it too (`widget_drawn_last_frame`: a widget
  built but not laid out takes no clicks), but keep building nothing for closed dialogs.
- **Skald culls rows outside a scroll's view** (`stack_render`): they're laid out with drawing
  suppressed, so their rects stay current (the reveal and scroll-into-view code reads them), and
  `widget_drawn_last_frame` counts them as laid out. Code that asks "was it laid out last frame" uses `skald.widget_drawn_last_frame`, not
  `last_frame + 1 >= frame` (tree_view.odin, view_docs.odin, view_inspector.odin,
  view_bottom.odin, the test driver).
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
- The preview is package state, not `State`, because it holds SDL resources. **It's
  thread-local** (`preview`, `thumbnail`, `ldtkThumbnails`, `ldtkLevelRects`, `previewThemes`):
  the editor uses it on its main thread only, and unit tests run on several. Shared, a test that
  made a font's MSDF atlas, packed an atlas or compiled a shader (`Preview_FontChanged`,
  `Preview_AtlasChanged`, `Preview_ShadersChanged`, which take no lock) zeroed the signature of
  the scene a preview test had just built and reached into that test's game:
  `ldtk_collision_shows_in_the_viewport` lost its shapes about one run in ten (2026-10-23:
  traced to `Preview_FontChanged` from import_settings_in_the_editor on another thread; none
  in 60 runs after). `previewTestLock` still serializes the tests that render (SDL_ttf):
  - The engine scene is rebuilt only when the scene's structure changes (`sceneSignature`).
  - Transforms, visibility and layers are copied to the engine nodes every frame (`syncTransforms`).
  - The surface only grows.
- Engine APIs it uses: `Scene_DrawWithView` (the editor's pan/zoom replaces the game camera; labels
  and menus are scaled by the zoom), `Scene_Build` returning its nodes, `Node_GetLocalBounds`.
- `sdl.FlushRenderer` before reading the surface is required: SDL batches draw commands.
- Animations play in real time while `viewport.animate` is on (P). The view sends `Viewport_Tick`
  each frame then, to keep frames coming. **Game code doesn't run in the preview:** scenes are
  built with `attachScripts = false`, so scripts aren't attached and a node type of game code is
  built as its base kind.
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
  - Ctrl+0 fit, Ctrl+1 100%, Ctrl+=/- zoom, P animations; Ctrl+Alt+1 / 2 the Scene / Level mode
  - arrows nudge (Shift ×10), Esc deselect, Delete
  - Ctrl+D duplicate, Ctrl+C/X/V copy/cut/paste nodes (not while typing)
  - Ctrl+Z undo, Ctrl+Shift+Z or Ctrl+Y redo (not while typing: the text field undoes typing)
  - F5/F6/Shift+F5 play controls (Ctrl+F5 Play Scene, Ctrl+Shift+F5 Restart), F9 the game's collision shapes (as F9 in the game), Ctrl+I
    import, Ctrl+, settings
- `KeymapDispatch` runs at the start of `view`, before the menu bar, so each shortcut fires once.
- **Plain keys are ignored while a text or number field has focus** (`IsTyping`), and are hidden
  from menu hints then.
- `viewportOnly` bindings (nudges) need the mouse over the viewport.
- Settings > Keyboard lists and edits the keymap (Help > Keyboard Shortcuts opens it there).
- **A new Action needs a line in `settings.default.ini`'s `[keymap]`** (a test checks), and an
  `ACTION_LABELS` entry. Don't add ad-hoc `skald.shortcut` calls.
- **Keys of one mode** (`ActionKeyRule.onlyIn`, `Action_InMode`): the nodes', the viewport's and
  the code tabs' actions are the Scene mode's; `KeymapDispatch` skips them in another mode and the
  menu bar disables their items (a disabled item registers no shortcut: the menu bar would fire
  Del itself). The browser's routed keys (Delete, Ctrl+D/C/X/V, F2 on its scene) work wherever it
  has the keyboard. Ctrl+Alt+1 / Ctrl+Alt+2 switch modes (`Mode_Scene`, `Mode_Level`; Ctrl+1 is
  the viewport's 100%), in `CODE_EDITOR_PASSTHROUGH` too.
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
  its position is known without computing it from the rects), Enter or a
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
  (the engine's defaults are 60 and 90 since). They're the defaults: Settings > Appearance's
  Viewport section sets its own ("The editor's look").

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
  repository that ignores it (`check-ignore`, like the UI tests' copies under `build/` in this repo) counts as not
  under version control: Initialize makes it its own repository.
- **Commands** (`GitOp`, `Git_Commands` lists the git calls, `Git_OpProblem` refuses bad input)
  run one at a time on a worker (`Git_RunCommands`), env `GIT_TERMINAL_PROMPT=0`,
  `GIT_MERGE_AUTOEDIT=no`, `GIT_SSH_COMMAND=ssh -o BatchMode=yes` (unless set) and no stdin, so
  nothing waits for a password. Saved first; Pull and Switch_Branch (`Git_ChangesFiles`) open the
  project again from disk. Unstage before the first commit is `git rm --cached` (no HEAD to reset
  to). Commit with nothing staged runs `git add -A -- .` first.
- **Layout:** the history column is left out under 720 px (a tiled window), so the commit
  controls keep their width.
- **Reads and commands take turns** (`GitState.queued`): no snapshot read while a command runs
  (`Git_Refresh` returns nothing: its end reads one; a save during it only marks `stale`), and a
  command asked for during a read waits for it, then runs on the new snapshot. git status
  refreshes the index under its lock, so a commit or checkout beside it could fail, or the read
  show the repository half changed (a commit's own save marked the snapshot stale and the view
  started a read the next frame, while the commit ran). Test: `git_reads_and_commands_take_turns`.
- **Output is never lost:** git runs through `Process_Exec` (process_exec.odin: the engine's since 2026-10-23). With
  `os.process_exec`, a read under heavy CPU load sometimes got an empty `git status` (no branch:
  `git_init_stage_commit_branch_push` failed with `ahead` 0 vs 1, then the push's "invalid
  refspec"; 4 of 384 runs, 16 at once beside 8 CPU hogs, and none of 224 after; 3 of 12000 runs
  of `printf` lost their output, none after). `gitDo` in the test checks each read had no
  problem; `process_exec_keeps_output` runs git 200 times.
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

**Restart** (`Action.Restart`, Ctrl+Shift+F5, `toolbar-restart` beside Stop, Scene > Restart;
`playRestart`): `playStop`, then `playStart` with the scene the last Play used (`playScene`: ""
for Play, Play Scene's name; a hot reload's restart doesn't change it), so it saves and rebuilds
when scripts changed, as Play does. Off unless `Play_CanRestart` (a game running or paused, or
Play's build: not Build Scripts'). **One chain of `Play_Tick`s** (`playPoll`,
`State.playTickPending`, cleared when one arrives): a stop and a start in one message left the old
chain's tick pending beside the new one's, and each kept itself going. Tests:
`restart_needs_a_game_to_restart`; live.script (the toolbar's Restart and Ctrl+Shift+F5 after
Play Scene: a new process, `game pid new` after `note_game`, on the same scene, `live scene`).

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
- **Clickable errors** (error_locations.odin): a line `ErrorLocation_Parse` finds a location in
  (Odin's `path(line:col)`, else `path:line[:col]`; the path needs an extension with a letter,
  no `://`; a line starting with an absolute path keeps its spaces, `shortPath` is the fallback
  after the last space) gets its text in a `View_Zone` keyed `<list>-link-<index>`: under the
  pointer (its last rect, inside the list's, no popup or modal) the accent color, a 1 px
  underline and `skald.cursor_request(.Pointer)`; a **single click** (like a link: rows have no
  other click) sends `Log_Command{.Go_To_Error}`, the line menu's **Go to Error** too (only on such
  lines). `ErrorLocation_Resolve`: absolute as is, else under the Output's build folder (the
  editor's working folder) or the game's (the project), the project, `scripts/`, the working
  folder, the engine. **Files outside the project open read-only** (code_editor's
  `Buffer.read_only`: raw inserts and deletes do nothing and record no undo; `buffer_set_text`
  still loads; `CodeEditor_SetReadOnly`, the status line says so): engine sources and Odin's
  library are shared; Go to Definition (`Code_Open_Requested`) does the same. The external
  editor gets `{column}` too. Driver: `click_log_location <console|output> [n] [right]`, check
  `code_read_only`. Tests: `error_locations_are_found_in_lines`,
  `go_to_error_opens_the_file_at_the_line`, scripts.script (a compile error clicked, its menu).
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
  editor); the menu bar drops its shortcuts. Help's chord (F1, `User_Manual`) is the code view's
  own: the docs window at the API entry of the engine declaration at the caret, else the type of
  the name there, else the manual's code editor page ("Hovers and previews", below).
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

### The project in the code (implemented, `code_providers.odin`, `script_index.odin`, `script_constants.odin`, `name_kinds.odin`, `code_names.odin`, `script_links.odin`, `script_rename.odin`, `code_drops.odin`, `code_drag.odin`, `code_previews.odin`, `code_colors.odin`, `engine_docs.odin`, `code_live.odin`, `log_points.odin`, `code_actions.odin`; code_editor's `providers.odin`, `providers_scrub.odin`, `rename.odin`; the engine's `code_uses.odin`, `live.odin`)

Odin editing that knows the project: the scenes, assets, actions, animations, the running game.
Code and scene editing are one environment (no remembering how to refer to things in code). Built
as TODO.md's "Code editor integration" (asked 2026-10-23, built in seven steps, done 2026-10-24); the
manual's code editor page is the user's guide, "Your project in the code" its part on this.

#### Overview: how it's put together

- **Architecture:** code_editor (`code_editor/`, engine-agnostic, imports nothing of the editor
  or the engine) has a **provider registry** (`ce.Provider_Registry`, `providers.odin`): plain
  procedures with a user-data pointer, per kind, merged with OLS's answers and working without
  it. The editor registers its providers once (`CodeProviders_Registry`, code_providers.odin);
  they read State through package state set around every call into the code editor
  (`CodeProviders_Begin` / `_End`) and never change it: what needs State changed (open a node, a
  rename's project side, a dialog, the game) is left in package state and sent as a message by
  the code view after the code editor ran (`linksSend`, `CodeLive_Take`, `LogPoints_Take`,
  `CodeColors_TakeRequest`, `CodeActions_Take`). Everything reads the **script index** (the
  scripts' declarations from their source, no build) and the project; slow reads (the engine's
  name table and docs) run once on a worker.

| Part | What it gives | Where (editor; code_editor; engine) |
|---|---|---|
| Provider interface | completion, hover, diagnostics + fixes, gutter, inlay, drops, usages, renames, scrubbing, menu entries, code actions | code_providers.odin; `providers.odin`, `providers_scrub.odin`, `rename.odin`, `code_actions.odin` |
| Script index | each file's structs, fields, tags, registrations, engine calls' string literals, procedures; problems; merged into the catalog | script_index.odin (`ScriptIndex_*`) |
| Typed constants | `scripts/assets.odin`: assets, animations, states, groups, buses, scenes, dialogue nodes, node paths | script_constants.odin |
| Names | which engine parameters take which kind of name (name types), completion and checks inside strings | name_kinds.odin, code_names.odin; the engine's names.odin |
| Links | gutter markers of who uses a script / sets a field / listens, Find Usages, renames carried into the project | script_links.odin, script_rename.odin |
| Drops | editor things dragged onto code become fields, statements, constants | code_drops.odin, code_drag.odin, asset_fields.odin; the engine's code_uses.odin |
| Hovers | previews of assets and scenes, the engine's docs (F1), color swatches and their dialog | code_previews.odin, engine_docs.odin, code_colors.odin |
| Live | the running game's values beside fields, scrubbing defaults, log points | code_live.odin, log_points.odin; the engine's live.odin |
| Actions | Ctrl+.'s engine-aware code actions, the inspector-to-code jump | code_actions.odin, view_inspector.odin (`inspectorRow`, `Inspector_RevealWidget`) |

The parts below say what each relies on; the files' doc blocks have the details.

#### The provider interface, the State they read, the syntactic context

- **The provider interface is code_editor's** (`code_editor/editor/providers.odin`, its README's
  "Providers"): completion, hover, diagnostics, gutter markers, inlay hints and drops, each a
  plain procedure with a user-data pointer in a `ce.Provider_Registry`; code_editor imports
  nothing of the engine or the editor. Merging is code_editor's: completion items fold into the
  server's by label (docs added, priority taken; `Completion_State.items` is the merged list,
  `filtered` indexes it, never `lsp.last_completion` any more), hovers show the providers' blocks
  then the server's text (`Hover_Text` / `Hover_Image` / `Hover_Widget`), diagnostics join the
  overlay (`Diag.provided`; moved with edits; one the server has on the same line and message
  is dropped). Diagnostics, gutter and inlay providers run once per text version after
  `PROVIDER_DEBOUNCE` (250 ms) and on `provider_registry_invalidate`; completion and hover when
  asked. They all work without OLS. A word typed faster than frames (the test driver's `type`)
  restarts the list for the new word (`completion_prefix_ok`).
- **The editor's providers read State through package state** (`codeProviders.state`, set by
  `CodeProviders_Begin` in `CodeEditor_View` and `CodeEditor_Drop`, nil otherwise): providers run
  inside the code editor's calls, which only happen there. `CodeProviders_Begin` invalidates the
  cached providers when the history version, the index's or catalog's generation, or the scene or
  asset count changed. A gutter click can't change State from inside the code editor: it leaves
  its target (`CodeProviders_SetOpen`) for the view to send as `Code_Usage_Opened`.
- **The syntactic context** (`ce.editor_syntax_context_at`) is a tokenizer scan, not a parse:
  brackets on a stack, what each opened decided from the tokens before it (`Name :: struct`,
  `proc` and `proc "contextless"` parameter lists, `if` / `for` / `when` blocks, literals). The
  drop provider decides by it ("Drops into code", below), and the code actions read it. Drops carry the mouse and Shift
  (`Tree_Drag_Dropped_On_Code{mouse, menu}`, `Asset_Dropped_On_Code`, `Code_Source_Dropped`),
  turned into the editor's pixels with the shown view's rect and scale (`host.shownRect`,
  `shownScale`).

#### The script index, the catalog and the constants

- **The script index** (script_index.odin's doc block): `core:odin/parser` per file, the AST in a
  growing virtual arena freed at once; results copied to the heap. Parsing runs on a
  `skald.cmd_thread` worker with copied texts (`ScriptIndex_Tick` every 0.5 s while a project is
  open, started from `view` like the plugins' tick); one parse at a time (`running`, `again`).
  A code tab's dirty buffer is parsed once its version stayed the same for a tick (the
  debounce); a disk file when its modification time changed (a save of what was already parsed
  only moves the time: same hash). Events follow the engine's rule (an `EventSubject` field
  tagged `event:"..."`, named `script.<field>`); field types are read from the text (`f32`,
  `^e.Camera2D`: any pointer to another package's type counts as a node, the build decides;
  another package's non-pointer type is skipped, not reported). Problems are only what's sure:
  a type the engine can't export, an unknown tag option, a min / max / number default that isn't
  a number. Each problem and registration keeps its line's text, so the providers find it again
  in a buffer edited since (`relocate`, 200 lines either way).
- **The catalog stays authoritative** (`ScriptIndex_Apply`): `takeDescription` keeps a copy of
  the build's catalog (`ScriptIndex_TakeBuild`, `scriptIndex.built`) and the newest script source
  when the build started (`State.scriptsBuildSource`, set in `buildPlayer` and hot reload's
  build); `State.scripts` is that copy with the index's description of each script, data type and
  node type whose file changed since (newer on disk, or unsaved in a tab), matched by file base
  name (the scripts package is flat). A built script whose changed file no longer registers it
  goes. The status isn't touched. `ScriptCatalog.generation` counts changes.
- **Constants** (script_constants.odin's doc block has the naming): `Scripts_Constants` is the
  one list (the file, completion, hovers, drops). Asset, action and achievement names didn't
  change (`ConstantName`); the new kinds use `ConstantWords` (camelCase split). Sections in a
  fixed order with a comment each and `// - <owner>` lines; owners, groups, scenes and paths
  sorted by name; collisions `_2` in that order, one `used` map for the whole file. Aseprite tags
  are read once per file time into a heap cache with a lock (`aseTags`): `Project_Save` writes
  the file, and unit tests on several threads save projects (the `AsepriteEdit_File` cache
  would have kept their allocators' memory). Paths need the engine's `Scene_FindNode` to take a
  leading "/" (engine, 2026-10-23).
- **Scene edits don't rebuild the game:** node paths change with every node added, so a player
  build keeps the assets.odin it was built with (`<binary>.constants.txt`, `Constants_Snapshot`)
  and `playerIsCurrent` / hot reload (`Scripts_NewestFor`) ignore assets.odin unless a constant
  it had is gone or changed and another script file names it (`Constants_ChangeMatters`).
- **Measured** (2026-10-23, the demo: 13 files, 3517 lines, 452 constants): a full index 8-10 ms
  optimized (16 ms debug), one file again (hero.odin, 392 lines) 1.3-1.9 ms (2.5 ms debug), all
  on the worker; the constants 2 ms (`script_index_demo_project_timing` logs them).
- **Tests:** code_editor's `providers_test.odin`; `script_index_test.odin` (reading, broken code
  and incremental updates, the plan, the merge with a build, the timing),
  `script_constants_test.odin` (names, collisions, determinism, an empty project, rebuild
  decisions), `code_providers_test.odin` (completion, problems, markers, a drop in a real code
  tab), `tests/ui/code_providers.script` (marker and hint, a marker click selecting the node, a
  typed field reaching the catalog, a problem, a constant completing, its hover; driver:
  `code_hover`, `code_click_marker`, `code_completion_provided`, `code_hover_has`,
  `code_inlay`, `code_marker`, `code_diagnostic_has`, `script_field`, `script_from_index`,
  `key <combo> <times>`).

#### Names in strings (project-aware strings)

See name_kinds.odin's and code_names.odin's doc blocks.

- **The engine says which parameters take which kind of name with name types** (its names.odin:
  `NodePath :: string`, `SceneName`, `AnimationName`... 14 of them), chosen over distinct types
  and over a table: aliases break no caller (a `string` variable still passes; distinct types
  would have needed casts in the engine, the demo, the website's examples and users' code), they
  show in signatures, OLS's hovers and the API reference, and the engine checks itself
  (names_test.odin: a public `action` / `bus` / `group` / `state`... parameter typed `string`
  fails). The editor can't see an alias through reflection, so **it reads the engine's source**
  (`NameTable_Read`: core:odin/parser on the files naming a type, groups merged by position and
  name; `_Add` / `_Create` procedures declare names), once per run on a worker started by the
  index's tick (`NameTable_Start`, then `NameTable_Loaded` invalidates the providers).
- **The index records the calls** (`IndexFile.calls`: an engine call's string literal argument,
  its position or name, its first argument as written, the type of the enclosing procedure's
  first parameter; `IndexFile.procs` for positions being typed; escapes and non-literals are
  skipped), so diagnostics don't scan buffers.
- **Resolution** (code_names.odin): the script is the procedure's `^T` when T is registered, else
  the file's only one; it runs where `scriptUsers` says, a component's node expanded into every
  instance (`placesOf`: `PathLoc` with the instance it's reached through, so ".." leaves the
  component; an uninstanced one's ".." is unknown). Receivers: `x.node`, a node field (`x.f`: the
  node's prop or the field's default, resolved from it), a scene for `ScenePath`; anything else
  is unknown: no path is checked, names are checked against the whole project. Children of
  LDtkLevel and TileMap nodes are unknown (made at run time). Each attachment is checked apart;
  mixed results say from which nodes. "Did you mean" is an edit distance of at most a third of
  the name; the constant fix is the one with that value (paths: one leading to the same node).
- **code_editor grew** (its README): `Provider_Diagnostic.fixes` (`Provider_Fix`, moved with
  edits, listed before the server's actions by Ctrl+., shown at once and without a server),
  `Provider_Completion.replace_start` (replacing a path segment or a name with spaces while the
  list filters by the word), `Provider.trigger_chars` (`"` and `/` open the list, asking only the
  providers: `Completion_State.providers_only`), and `in_string` at the end of an unclosed string.
  The names provider is registered before the constants one, so its constants' priority (30)
  wins the label.
- **Measured** (2026-10-23, the demo; `names_demo_project_timing`): reading the table 55-63 ms optimized (146 ms debug; 23 of the engine's files parsed, once, on the worker), every literal of the slowest file checked in 0.06-0.07 ms (0.19 ms debug), a completion inside a string 0.4-0.6 ms and one of constants 0.5-0.7 ms (2.5 and 3.3 ms debug). The demo's
  32 literals in 13 files give no problem (the test fails on any: no false positives).
- **Tests:** the engine's names_test.odin; `code_names_test.odin` (the table read from the real
  engine: every kind, groups, named arguments, declaring procedures; completion per kind inside
  and outside strings; problems and fixes per kind, a script on a component placed in two trees;
  the demo's timing and its clean bill); code_editor's `providers_names_test.odin`;
  `tests/ui/code_names.script` (a quote opens the scenes, a path after "../", a misspelled scene's
  squiggle fixed with Ctrl+.; driver: `code_diagnostic_lacks`).

#### Code and scene links

See script_links.odin's and script_rename.odin's doc blocks.

- **Markers** on registration lines list every user (nodes as script, more script or node type;
  component instances through their root; globals; data resources), on exported fields the
  nodes, globals and data that set a value plus Timeline tracks, on events the listeners. Each
  is a `ce.Gutter_Marker` with `choices` (code_editor opens its code actions menu for several,
  `Gutter_Marker.choice` says which); a click can't change State inside the code editor, so the
  provider leaves the target (`CodeProviders_SetOpen`) and the view sends `Code_Usage_Opened`
  (`linksSend` in `CodeEditor_View`). The click is recomputed from the marker's line, not kept.
- **Find Usages** is code_editor's `.Usages` provider kind: the references panel's rows are the
  provider's (`Ref_Item.provider`, `id`), opened through `on_open`.
- **Rename is the index's, not OLS's** (the reason is in script_rename.odin's doc): OLS's rename
  reads other files from disk (unsaved tabs missed), may not be running, and answers later; the
  project side must match the code side exactly. So the editor parses the package itself
  (`CodeModel`, an arena per call: 40-45 ms for the demo's 13 files, debug or optimized,
  measured by `script_rename_demo_project_timing`; only when asked: F2, Enter, Find Usages) and classifies every
  identifier: a package type, or a field with the struct its receiver resolves to (parameters,
  locals and globals with types or values, composite literals, casts, `&`, the package's
  procedures' results, `e.Node_GetScript` / `Global` / `Data` / `CreateNode` / `new`, ranged
  slices, `using`). A `.field` whose receiver isn't known is left and reported, never guessed.
  code_editor's `.Rename` provider kind: `prepare_rename` (the box's title and a dry-run note)
  and `rename` (this file's edits as one undo step); the provider leaves the rest
  (`CodeProviders_SetRename`) for `Code_Rename_Requested`: the project in one `.Project` undo
  step (History_Classify), other files opened in hidden tabs (`CodeTabs_Open(show = false)`,
  `CodeEditor_ApplyEdits`: their own undo step, unsaved), written to disk only when no tab can
  open. Without a project symbol, F2 falls to OLS's `textDocument/rename` (code_editor's
  rename.odin): its edits to other files come through `editor_take_file_edits`, sent as
  `Code_File_Edits_Requested` and applied in hidden tabs of project files the same way.
- **Undoing a project step keeps the selection** when the open scene's tree (names, parents)
  is the same (`nodesSameTree`): a rename changes nodes, not which they are.
- **The inspector keeps what it can't place**: values of fields the code no longer has are
  listed under the fields with a × (`OrphanedValueRows`), values that don't fit a field's
  changed type get a warning and Reset (`FieldMismatchRows`, `ScriptProp_Fits` as the engine's
  `Script_SetField` parses); in the node's Script section, more scripts, node types, globals
  and data resources.
- **Tests:** `script_links_test.odin` (the code side's edits for a type, a field through every
  receiver kind, an event's strings, a data type's tags, taken names, uses left; the project side
  through the message with undo and redo across scenes, components, globals, listeners, tracks,
  data; a real code tab: markers and their menu, Find Usages, F2, the other file in a hidden tab,
  each undo), code_editor's `providers_links_test.odin` (the marker menu, usages, the rename
  box with a provider and through a fake server), `tests/ui/code_links.script` (markers, the
  menu, Alt+Shift+F12, F2 on a field and a type with both undos, an orphaned value removed;
  driver: `code_state rename.*`).

#### Drops into code

See code_drops.odin's and code_drag.odin's doc blocks; the manual's "Dragging things into the code" has the table of what each kind becomes.

- **Sources describe themselves** (`DropSource`), panels know nothing of code: scene tree
  nodes and browser assets through their own drags (`treeDrag`, `assetDrag`: they also drop
  into the tree and the viewport); everything else through `State.codeDrag`: inspector
  property labels (`inspectorRow`, thread-local `inspectorDrag`: a label is draggable when
  `CodeDrops_PropertyField` finds the engine field, `Position X` as `position.x`, aliases in
  `PROPERTY_ALIASES`; key `inspector-label-<label, spaces as _>-<node>`), the Script section's
  fields (as `.Script_Field`), event names (`inspector-event-drag-...`), group chips under the
  Groups field (`inspector-group-<g>-<node>`), grips (`ICON_GRIP`, only while a code tab
  shows) for the Animation panel's animation (`animation-drag`), the selected state
  (`states-drag`) and each parameter (`states-param-drag-<i>`), the Timeline's clip
  (`timeline-clip-drag`) and each Mixer strip (`mixer-drag-<i>`), Project Settings > Input's
  action buttons (`input-action-<i>`), browser scenes. A press only arms the drag: the click
  still happens (a scene row's waits for the release, since opening it would hide the code
  tab: `browserRow`).
- **Input actions in a modal dialog** (decided): Project Settings and Settings (whose Project
  tab shows the same list) hide while an action is dragged (`CodeDrag_HidesDialogs`:
  `closedDialog`), so the code tab under them takes the drop; they show again after. Presses
  behind a dialog never start a drag (`pressStarts`; the browser checks `modal_rect_prev`: the
  workspace is built after the dialogs, so its press came last and won).
- **One table** (`CODE_DROP_KINDS`: noun, name type, struct shape, a name field's suffix);
  **what code does is the engine's** (`e.CODE_USES`, code_uses.odin: uses per name type,
  handle type, node type and `Type.field`, the first being the plain drop; checked by the
  engine's code_uses_test.odin against its source and by `code_drops_engine_uses_compile`,
  which fills every use in and runs `odin check`). `codeUseKeys` picks the keys of a source,
  most specific first (`StateParamName:Trigger`, then `StateParamName`; a node's type chain).
- **Shapes** (`CodeDrops_Build`): struct (or outside a procedure): a field before the closing
  brace (node fields, asset fields as before, name fields `<name><Suffix>: e.<NameType>` with
  `export:"default=..."`, an owner's node field); procedure body: a statement after the
  dropped-on line (on it when blank, before it when it closes a block), indented like it,
  conditions as `if` blocks, values as `x := `; argument: the constant (`constantOf`: the
  section, value and owner group of `Scripts_Constants`, else the name quoted) first where
  `NameTable_ParamKind` says the parameter takes that kind, else the expression; in a string the
  name; in a comment the constant.
- **Reaching nodes** (`nodeExpr`): `self.node` for the script's own node (when any node type
  will do: `fieldOwnerType` says which type declares a field, so `position` needs only a
  Node), a field whose default path leads to the node and whose type fits, else a new field in
  the same edits (one undo step: code_editor applies a choice's edits together). A thing
  without a node (music, a group) takes the struct's only field of the type, else the scene's
  first node of it. The script variable is the procedure's `^Struct` parameter
  (`Syntax_Context.proc_params`), else `self`. `e.` becomes the file's import name.
- **The menu** is code_editor's (`Drop_Choice`, `Drop_Request.menu`: Shift at the release); at
  most `CODE_DROP_MAX_CHOICES` (4). A drop focuses the code tab (`host.focusNext`) so the menu's
  keys reach it; a pick's message comes back through `Code_Drop_Chosen`.
- **Tests:** the engine's code_uses_test.odin; `code_drops_test.odin` (the table, use keys,
  property fields; every kind in a struct, a body, an argument and a string in a real code
  tab with one undo step each; the menu's choices and previews; every engine use compiled);
  code_editor's `test_provider_drop_choices_and_their_menu`; `tests/ui/code_drops.script` (each
  source dragged at a line or text, Shift's menu picked by keys, then saved and built).
- **Found doing it:** the driver's drop point was the middle of a character cell, which the code
  editor rounds either way (now a quarter in: `CodeEditor_WindowPoint`), and `RevealLine`
  didn't scroll sideways, so a drop at a long line's end in a tiled window landed in the
  inspector (it reveals the column now). A click on an inspector button right after the code
  tab took the keyboard was sometimes lost (the Events toggle): not the focus handoff (Skald
  drops the code view's focus on the press and the button takes it), but the layout moving
  under the pointer: the Script section's rows changed half a second after New Script (the
  index read the file: "Building..." became the fields and a note) and again when its build
  ended (the note went), so the toggle moved between the driver's move and its press; and in a
  tiled window the toggle sat at the row's right end, under the inspector's scrollbar strip
  (the press went to the scrollbar; repeated clicks too). Fixed with the hovers:
  `ScriptIndex_ReadNow`, a source line that's always there, the toggle beside the Events
  title; `tests/ui/code_focus_clicks.script` (driver check `inspector_events`) clicks it at
  once, while typing and after the build, in all three sizes.

#### Hovers and previews

See code_previews.odin's, code_colors.odin's and engine_docs.odin's doc blocks; the manual's "Hovers and previews".

- **code_editor grew** (its README): `Hover_Widget.click` (a left press on the widget calls it
  with the point in its block; the hover stays: `editor_click_hover_widget`), and
  `Hover_Content.replace_server` (the server isn't asked, its answer isn't shown); images up
  to `HOVER_IMAGE_MAX` tall and twice as wide (strips); `Inlay_Hint.swatch` (a square of the
  color before the label) and the inlay provider's `on_inlay_click` (`editor_click_inlay_swatch`,
  `Provided.inlay_providers` says whose each hint is); inlay hints count in the scrollable width
  (`editor_max_visual_width`, keyed by `provided.seq` too), so a narrow tab scrolls to a swatch.
- **Asset previews** (`CodePreviews_*`): on a constant (the preview first, then what it is: a
  play button stays in view in a short tab), a string literal or a tag's `default=` naming an
  asset or a scene. Pictures are made once, scaled down, kept by path and modification time (a
  component's by its XML's hash) in a cache of at most 64. **Scenes get facts, no picture:**
  drawing ForestScene took 200 ms on the editor's thread. Sounds: the length is read by
  SDL3_mixer without decoding or opening the device (`AudioPreview_Length`, its own mixer); the
  play button is a `Hover_Widget` whose click leaves `Code_Hover_Audio` for the code view to
  send (it can't change State inside the code editor), update plays it through the audio
  preview; `codeRenderKey` has the playing state, so the button turns back to ▶ when it ends.
- **Engine docs** (`EngineDocs`): the engine's source parsed once per run on a worker (started
  from the index's tick with the name table), docgen's rules (public declarations, `when`
  blocks, the comment attached or ending on the line above); `EngineDocs_At` takes the name
  after the file's import name (`IndexFile.engineAlias`). The hover renders the declaration,
  the comment, Inputs / Returns bold, Example as code, and stands in for OLS's (which repeats
  the declaration and the raw comment). **F1 in a code tab** is the host's
  (`CodeEditor_View`: the editor's `User_Manual` chords are taken before the code editor, whose
  own F1 opened its palette; Ctrl+Shift+P still does): the docs window at the declaration at
  the caret's API entry (`Docs_EngineAddress`: the area from `ENGINE_API_AREAS`, the anchor the
  name lower-cased, as the website's build-api.mjs makes them; `EngineDoc_URL` is the same entry
  on crossfireengine.io, checked there for five names), else the page of the type the code
  shows for the name (`CodeProviders_DocsAt`), else the manual's code editor page. The code
  tab's right-click **Open Docs** (a `.Menu` provider) goes the same way, a node type to its
  guide ("Docs in the editor", below).
  **A new engine file needs an area in the website's api-groups.json and in
  `ENGINE_API_AREAS`** (`engine_api_areas_match_the_website` and the docs test catch both).
- **Color literals** (`ColorLiterals_InLine`): typed composites (`sdl.Color{...}`, whatever the
  file imports vendor:sdl3 as; positional or named, 3 or 4 integers 0-255, decimal or hex),
  `x: sdl.Color = {...}` (not `-> sdl.Color {`, a procedure body), hex in a color field's tag
  and in `e.ParseColor("#...")`. The engine has no `e.Color` (its colors are `sdl.Color`) and
  takes hex only in those places. A swatch's click leaves `Code_Color_Requested` (the literal's
  line, bytes and text) for the view to send; the dialog (Skald's color picker, the hex, the
  alpha; keys `code-color-picker`, `-hex`, `-alpha`, `-ok`, `-cancel`) writes on OK with
  `CodeEditor_ApplyEdits` (one undo step in the tab), only when the literal is still there as
  it was.
- **Measured** (2026-10-23, the demo, `code_previews_of_every_kind` and
  `engine_docs_read_render_and_link`, optimized; debug in brackets): a warm hover of every kind
  14-30 µs; cold: an image 0.08 ms, an Aseprite file 15 ms (46), a sound's length 0.9 ms, a
  font's sample 0.8 ms (1.0), a component's picture 10 ms (27), an animation strip 0.5-0.6 ms
  (1.3-1.7), a dialogue or a scene's facts under 0.05 ms; the engine's docs read in 74 ms (225)
  on the worker (1307 declarations, 100 files), a docs hover 3 µs (11).
- **Tests:** code_editor's `providers_previews_test.odin`; `code_previews_test.odin` (every
  kind on the demo with its timing, literals, fitting and strips, `ENGINE_API_AREAS` against the
  website's file), `code_colors_test.odin` (every form read and written back; a real code tab:
  swatches, the dialog, OK, one undo, a stale literal left alone), `engine_docs_test.odin`
  (rendering, URLs, the name at a column, every engine file in an area);
  `tests/ui/code_previews.script` (an image's hover, a sound's play button, an engine
  procedure's docs, a swatch's dialog and undo, F1 both ways; driver: `code_hover_image`,
  `code_hover_widget`, `code_click_hover_widget`, `code_swatch`, `code_click_swatch`,
  `code_color_dialog`, `code_click`, `audio_loaded`, `last_link`). The driver's `code_hover`,
  `code_click` and `code_click_swatch` scroll the line (and a swatch's column) into view first
  (`CodeEditor_RevealLine` keeps clear of the last row: the horizontal scrollbar), and
  `code_hover` moves twice, a frame apart (a tooltip still up on the first frame kept the code
  view from the motion).

#### The running game in the code

See code_live.odin's and log_points.odin's doc blocks; the manual's "The running game in the code".

- **code_editor grew** (its README, `providers_scrub.odin`): clickable inlay hints with
  `choices` (a menu, then `on_inlay_click` with `hint.choice`); the `.Scrub` provider kind
  (Alt+press on a number the provider accepts, a sideways drag, `.Change` values and `.End`
  choices in the code actions menu, `on_scrub_choice`; the buffer untouched, the value drawn
  over the literal; an Alt+click that doesn't move still toggles a cursor); the `.Menu` kind
  (host entries after the right-click menu's own); gutter providers' `on_gutter_line` (the
  marker column of a line without a marker). **Found doing it:** a marker's click went to the
  first gutter provider with an `on_click`, whatever provider made it (one gutter provider
  hid it); markers now keep their provider (`Provided.marker_providers`).
- **The engine sends what's asked** (its live.odin): `fields <Script> <id> <field>...` (any
  field, read by reflection: `e.LiveLink_FieldText`), sent with the stats; the tree's nodes say
  which scripts they run (`LiveNode.scripts`). **Ask for what's shown:** `CodeLive_Frame`
  (every `view`) works out the shown tab's visible lines' fields (`CODE_LIVE_MARGIN` more) and
  `Live_Watch` sends only the watches that changed; no code tab or no game, they stop.
  `CodeProviders_Begin`'s key has the live tree's and values' generations, the link, the Live
  tab's choice, the selection and the log points, so hints follow them and go with the game.
- **Which node** (`CodeLive_Target`): a pick from the struct hint's menu
  (`LiveView.codePicks`, kept while the Live tab's choice and the selection stay as they were
  then), else the Live tab's node, else the scene's selected node by its path in the running
  scene of that name (`CodeLive_NodePath`, `CodeLive_ProjectNode`), else the first.
- **Scrubbing (decided):** only numbers in an exported field's `default=` (vectors' numbers
  too: the property keeps the other one), from the game's value, in the tag's range; each value
  is `set` over the link (`Code_Scrub_Changed`, sent by the view: providers can't change
  State). The release's menu (`CodeScrubWriteKind`): the code's default (`CodeEditor_ApplyEdits`,
  one undo step in the tab, only when the literal is still as it was), the node's own value (a
  `.Project` undo step: History_Classify; offered first when the node has its own value, and the
  default's title then says the node keeps it), or the game only. **Plain literals in procedure
  bodies aren't scrubbed:** they need a rebuild, and hot reload restarts the game, so it can't
  follow a drag. The field hint shows the node's own value beside the game's.
- **Log points (decided: the build's copy, never the user's file):** while any is on, the
  player's main imports `logpoints:scripts` (`playerMainSource(logPoints)`, `PlayerTarget.logPoints`,
  `-collection:logpoints=`), a copy of `scripts/` under `build/players/<project>/logpoints/`
  written before each build (only changed files; a fourth input of `playerIsCurrent`), each
  point's line starting with `e.Log_Debug("file:line: expr = %v", expr, category = "logpoint"); `
  so no line moves (compiler errors land on the user's lines: `LogPoints_ProjectPaths` turns
  the copy's paths back in the Output tab). Hot reload builds again when
  `LogPoints_Signature` differs from `PlayReload.builtLogPoints` ("Hot reload: log points
  changed"). A file not importing the engine gets an import at its end. Points follow their
  line's text (`LogPoints_Relocate`, at each build and in the providers); refused or lost ones
  are skipped with an Output warning. Exports never use them.
- **Tests:** the engine's live_test.odin (`liveFieldsCheck`); code_editor's
  `providers_scrub_test.odin`; `code_live_test.odin` (hints in a real code tab, the target
  rules, the watches, a pick, gone when the game stops; literals; a scrub sent and written
  back each way with undo, a vector, an int); `log_points_test.odin` (the statement, where one
  can go, injection, relocation, the file, the dialog and marker commands, the copy compiling
  with `odin check`, the paths); `tests/ui/code_live.script` (a fixture played: hints, two
  scrubs seen in the game and written back both ways, a log point from the gutter rebuilt into
  the game, its Console line clicked, turned off, the hints gone after Stop; driver:
  `code_scrub`, `code_click_inlay`, checks `code_inlay_lacks`, `log_points`, `log_point`,
  `logpoint_dialog`, `live_field`).

#### Code actions

See code_actions.odin's doc block; the manual's "Code actions (Ctrl+.)".

- **code_editor grew** (its README): the `.Action` provider kind (`Provider_Action`: a title,
  edits, a caret, a preview shown beside the menu as a drop choice's, `preferred`, an id;
  `on_action` after the edits), listed after the diagnostics' fixes and before the server's
  actions, at once and without a server; with nothing offered and no server the menu doesn't
  open ("No code actions here").
- **Read when asked:** Ctrl+. parses the tab's text again (`CodeActions_Read`, the index's parser
  in an arena: about a millisecond) for the positions it writes at (a field's type end and tag
  columns, a registration's literal and hooks with their braces, the declaration's attribute
  line, procedures with their `self`); other files come from the script index (registrations,
  node types' events, enums) and the catalog it keeps (fields to show, node fields to resolve).
  No build. Only a closed struct counts (a half-typed one runs into what follows).
- **The actions** (each only where it applies): **Handle <x>'s <event>** on a node field (its
  line, or `self.x` in the script's procedures) whose type has events (an engine type: its
  kind's `e.SceneNodeKind_Events`; a node type of the game's: its base kind's and its tagged
  `EventSubject` fields), and on the struct's line, its `using` line or its registration for the
  node it runs on (every node running it of one kind, through `e.Node_Is` and a cast; a node
  type: its own). **Export x** (the default from the struct's procedures' first `self.x = ...`,
  else the type's zero, a node field the first node that fits from the first node running it),
  **Export x with a range...**, **Remove export from x**, **Set x's range...** (the Range dialog:
  `CodeRange_Problem` refuses what isn't a number, a fraction for an int, min over max, a
  default outside; `CodeRange_Write` checks the line is as it was), **Show x in the inspector**.
  **Insert a switch over x's states** on a `^e.StateMachine` field in a procedure of the script
  (or a blank line there, one per such field): the machine the field points to from the nodes
  running the script (`CodeNames_FieldNodes`), a case per `STATE_` constant (the constants' group
  says the machine; the providers' cache keeps groups since this round: drops of a sprite's own
  animation now get its constant), in a nil check, placed as a drop's statement
  (`CodeStatement_Edit`). **Register x as a script / node type** on a struct embedding
  `e.Script` or an engine node type that nothing registers: New Script's registration
  (`ScriptTemplate_Registration`), the `vendor:sdl3` import added when missing. **Add the <hook>
  hook** on a registration: ready, update, draw, destroy; the physics four for bodies and areas;
  sceneChanged and loaded for globals.
- **Decided (handlers):** the subscription is code in `ready`
  (`if self.door != nil do e.Event_Subscribe(&self.door.onOpened, Hero_onDoorOpened, self)`, the
  handler `proc(_: ^e.EventSubject, source: rawptr, data: e.EventData, user: rawptr)` with
  `self := cast(^Hero)user` and the event's data hint), as the demo's scripts subscribe, not a
  scene listener as Listen... adds: it holds for every node running the script in every scene,
  needs no scene edit (one undo step), and reads in the code. An event already subscribed in the
  file isn't offered again. Listen... stays the way to wire one node's event to another node's
  script.
- **Decided (state machine constants):** the typed constants already are them (`STATE_` /
  `PARAM_`), so the action inserts the switch over them instead.
- **The jump both ways:** Show x in the inspector leaves `Code_Field_Reveal_Requested`
  (`CodeActions_Take` sends it): `CodeActions_Reveal` selects a node running the script as its
  first script (the selected one, else one in the open scene, else the first: its tab opens; a
  global: Project Settings > Globals) and `Inspector_RevealWidget` pages the inspector's scroll
  until the field's label (`Inspector_ScriptFieldKey`: `inspector-label-<field>-<node>`, always a
  zone now) is drawn, then brings it into view (at most 60 frames). The label's right-click menu
  (`Ctx_Script_Field`: Go to Declaration) and Ctrl+click send `Script_Field_Declaration_Requested`
  (`ScriptField_Declaration`: the index's struct and field line), opened with `Script_Open`. Only
  the node's first script's fields (the Script section's) have it.
- **Tests:** code_editor's `providers_actions_test.odin`; `code_actions_test.odin` (the reading;
  every action offered and not offered, what it writes, one undo step each, the caret, the Range
  dialog with a refusal, the reveal and the declaration, a struct ending the file; and every
  action's code applied together compiling with `odin check` and the project's assets.odin);
  `tests/ui/code_actions.script` (each action through Ctrl+. and the menu, the Range dialog,
  undo / redo, Show in the inspector, the label's Ctrl+click and menu, saved and built; driver:
  `code_pick_action`, `code_line_end`, `code_click text`, `click_widget <key> ctrl`, check
  `code_range_dialog`).

### Scripts (implemented, `scripts.odin`, the inspector's Script section)

- `NodeDef.script` and `props` (name/value text, only values that differ from the field's default)
  are written as `<script name><prop name value/></script>` (format version 3).
- The catalog (`State.scripts`: status Unknown/Building/Ready/Failed, and each script's fields)
  comes from builds, merged with the **script index** (script_index.odin, below) for every file
  changed since the build (or all, before one): those `ScriptDesc`s have `fromIndex` and the
  inspector says "From the source: not built yet" (else "From the last build": always a line, so
  the rows below don't move when a build ends). New Script reads its file into the index at once
  (`ScriptIndex_ReadNow`), so its section has its final rows from the first frame. The status is
  the build's either way.
  A script neither knows: nodes keep their script and values; the inspector lists the stored
  values read-only.
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
- **Assets dropped on a code tab's struct** (asset_fields.odin; the browser's `browserDrag`, which
  starts for every asset kind with a handle type and for LDtk projects, and for any asset while a
  code tab shows; elsewhere in the code the drop does what code_drops.odin says): an exported field of
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
  kind), as paths from the script's node. **Dropping a scene tree node on a code tab's struct**
  (`Tree_Drag_Dropped_On_Code`, `sceneTreeMouse`; a label follows the pointer) adds such a
  field to the file's script struct (`NodeField_FindStruct`: the one with `using script:`),
  before its closing brace as the drop's edits (one undo step, no auto-indent), named after the
  node (`NodeField_Name`), defaulting to its path from the node using the script (the selected
  one, else the scene's first; none: from the top level). Elsewhere in the code the drop does
  what code_drops.odin says (a statement using the node, its `PATH_` constant on an argument). Tests: code_editor.script (the drop), scripts.script (built, the inspector's picker,
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
Live_Property_Edited`). Log points added, changed or removed reload too (log_points.odin:
`builtLogPoints`; code_live.script).

Both are child processes (`core:os` `process_start` with a pipe). A `Play_Tick` message every 0.1 s
(`skald.cmd_delay`) drains the pipe and checks for exit with `process_wait(…, 0)`, so there are no
threads. **Stop** kills the child. **Pause/Resume** go through the live link (`pause` / `resume`,
every OS); only without it do they fall back to SIGSTOP/SIGCONT (POSIX). Quitting the editor
stops the game.

### Undo / redo (implemented, `history.odin`)

A command history in `State.history`: each `UndoCommand` holds what changed (one node:
`NodeChange`, or a scene's node list: `SceneChange`) before and after, the selection before and
after, its scene, and the editor mode it was made in and left (`modeBefore` / `modeAfter`). Undo
switches to that mode and scene and restores "before"; redo shows `modeAfter` and restores
"after". **One history for every mode**: edits undo in order wherever they were made.
- **Recording is automatic.** `update` wraps `applyMsg`: `History_Classify` says what a message
  edits (`.Node`, `.Scene`, `.Project`, `.Files` or `.None`), `History_Snapshot` copies it, and
  `History_Commit` compares after the message and pushes a command if anything changed. **A new
  edit message needs a case in `History_Classify`**, or it won't be undoable. `.Files` steps are
  files the editor wrote at once (the LDtk tab's: "Editing LDtk projects"), restored on undo.
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
  save unless `--settings` is given; the UI test tasks give each script a scratch copy of `tests/ui/settings.ini`.
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
  .editor/                 per-user editor state (gitignored): guides.ini (the viewport's guides),
                           logpoints.ini (the code tabs' log points), modes.ini (the editor mode
                           and the Level mode's world: editor_modes.odin), slicer.ini (the sprite
                           sheet slicer's settings per image: slicer_edit.odin)
```

- **Version 14:** an AnimatedSprite's animations each have their own sheet (`AnimationDef.sheet`,
  `grid`: the engine's `e.SheetGrid`, Cells or Size), written on each `<animation>` (`sheet`,
  `columns` / `rows` or `grid="Size" cellWidth cellHeight`, `margin`, `spacing`), in scene files
  and `.anim.xml` files; NodeDef and AnimationSetDef have no sheet (no `columns`, `rows`, `margin`,
  `spacing`). Older files migrate in the engine's parser (the node's or file's sheet becomes every
  animation's; a node without animations gets "default"), so `Project_Load` just copies them;
  they're rewritten in the new format only when saved. Also in 14 (no version of its own): an
  `<animation>`'s `offsetX` / `offsetY` (`SheetGrid.offset`) and `rects` (`AnimationDef.rects`,
  written instead of the grid: the sprite sheet slicer's); a
  Camera's `target` and follow, limit (`limitsOff` too) and shake attributes (`NodeDef.camera`,
  `cameraTarget`; see "Camera follow target"), and the Slider and CheckBox UI controls (`step`,
  `checked`; themes' `checkColor`: see "UI controls and themes").
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
  node's kind and differ from `e.DEFAULT_SCENE_NODE`. Values are escaped (`EscapeXML`), line
  breaks and tabs too (`&#10;`: an XML parser reads a raw line break in an attribute as a space,
  and the demo's credits roll lost its lines to a save and a load). Output is
  deterministic, so saving an unchanged project produces identical files; a test checks it.
  Line endings are LF on every OS; `.gitattributes` checks the repository's projects (examples,
  fixtures) out with LF, or Windows (CRLF by default) saw every file change on save.
- **Round trips:** `editor_test.odin` saves the test project (`Project_CreateTestProject`) with tricky values (escapes, non-default
  fields), reloads it, and compares every field. Extend it whenever a property is added.
- **Not handled yet:**
  - The editor doesn't scan `assets/` for files added outside the editor.
  - (Scene files of deleted or renamed scenes are removed now: `Project_CleanSceneFiles`.)
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
  (`Toggle_Collision_Shapes`, Shift+C, the `panel-viewport-shapes` button, View > Show Collision
  Shapes, the empty viewport's Show submenu) hides them. Shapes have engine bounds, so picking and
  selection boxes work as for sprites.
- **Generated collision** (viewport_preview.odin): what LDtkLevel nodes (IntGrid collision) and
  TileMaps (tile collision) build isn't in the scene tree, so the overlay can't outline it.
  `Preview_GeneratedShapes` reads the preview scene's own built shapes (the node's StaticBody /
  Area children, a level view's for LDtk; entity layers left alone) as `GeneratedShape`s (owner,
  `GeneratedShapeKind` Solid / One_Way / Area, world corners), and `Preview_Render` draws them
  **into the picture** after the scene (`drawGeneratedShapes`, while `showShapes`:
  `GENERATED_SHAPE_COLORS`, filled faintly and outlined, one-way with a heavier top edge), so
  the driver's `viewport_has_color` sees them. `showShapes` is in `Preview_FrameKey`. Tests:
  `ldtk_collision_shows_in_the_viewport` (rectangles, pixels per kind, the toggle, moved and
  hidden nodes), `tilemaps_in_the_editor`; ldtk.script (`generated_shapes`, colors, the header
  button, Shift+C, the context menu).
- **Debug drawing in the game is a development setting of the project** (`project.physics.debugDraw`,
  project.xml's `physicsDebug`): the toolbar's `toolbar-physics-debug` button beside Stop (F9),
  Project Settings > Show shapes, or Scene > Show Collision Shapes in Game (`Toggle_Physics_Debug`,
  a `.Project` undo step). **While a game runs** the button shows the game's state
  (`PhysicsDebug_Shown`: `live.shapes`, from every stats line's `shapes`, so F9 pressed in the
  game shows) and a click sets the opposite in both: the project (no undo step when it already
  agreed) and the game over the live link (`Live_SetShapes`: `shapes on|off`; stale stats
  ignored like a pause's, `shapesPending`). Undo / redo of the toggle reach the game too. Test:
  `the_toolbar_shows_and_hides_the_games_collision_shapes`; physics.script, live.script. Play uses it (the player reads
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
  The viewport's rebuild signature includes the file's time (`LDtkSettings_Signature`: every
  setting the build reads, the one-way and area lists and whole entity rules too; one-way to an
  area once changed nothing else and didn't rebuild), and
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
  layers, mask, friction and bounce (`bodySurfaceRows`, shared with body nodes). The viewport
  draws the generated collision (Physics: Generated collision).
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
- **The demo's levels** (ForestScene, HollowScene, LairScene, all in
  `examples/demo_project/assets/levels/legacy.ldtk`) use all of it: auto-layer rules, IntGrid
  collision with one-way and Area values, entities mapped to components with scripts named like
  them, fields (patrols, speeds, health, dialogue nodes, next scenes), a rectangle entity and an
  EntityRef. Test: `shipped_demo_copies_with_its_level` (copied like a bundle's first run,
  loaded, every level scene's node and components, the files exports need).

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
- **Durations** (Aseprite frames each have one) and `repeat` round-trip; the panel edits both
  (see the panel below) and previews them (`AnimationDef_StepAt`, `AnimationDef_FrameAt`).
- **Renames follow** (`AnimEdit_RenameReferences`): a renamed animation is renamed in the states
  of StateMachines whose sprite plays the source (a node's own: in its scene; a set's: every
  sprite using it) and in Timeline tracks' "animation" keys on such a sprite. A node's rename is
  a `.Scene` step when the scene has a StateMachine or an Animator (`Scene_PlaysAnimationsByName`).
  An asset's rename leaves components alone (its `.Project` step's snapshot holds scenes only).
- **Frame times cover the range:** after an edit, frames the range gained get the fps's time
  (`AnimEdit_Update`'s end), and the preview holds a frame without a time when fps is 0, as the
  engine does. A ping-pong's repeat is passes (the engine's rule; the panel says "passes").
- **The viewport plays the panel's animation** only when the panel shows what the selected sprite
  plays (not an asset picked in the browser).
- Tests: `animation_assets_are_made_saved_edited_and_undone`, `tests/ui/animation_assets.script`
  (driver checks `anim_source`, `animation_set`, `animation_sets`).

- **Model:** an AnimatedSprite has `animations` (`AnimationDef`: name, **its own sheet** (`sheet`,
  a path) and `grid` (`e.SheetGrid`: mode Cells with `columns` x `rows`, or Size with `cellSize`,
  plus `margin`, `spacing` and `offset` (where the grid starts); only the mode's own values are
  kept, as files keep them), or `rects` (the sheet's cells as rectangles, from the sprite sheet
  slicer: the grid is then unused; the panel shows a note, Slice a sheet… and Use a grid instead,
  `Anim_Rects_Cleared`; `AnimEdit_Cells` counts them), start, end
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
  frames, count (`AnimField.Frames`: sets the end from the start), FPS, loop, mode; without Loop,
  Plays ... times (`AnimField.Repeat`; once is stored as 0); **Frame times**
  (`Anim_Durations_Toggled`: on fills each frame of its range with the fps's time in whole ms,
  `AnimEdit_FpsDuration`; off clears them) and, when on, a number per frame in ms
  (`AnimDurationTarget`, `Anim_Duration_Changed`; keys `animation-duration-<frame>-<node>`;
  durations belong to cells from the first, whichever way it plays, as the engine's). Under the
  sheet's values, `AnimEdit_SheetNote`: a Size grid's leftover pixels (`e.SheetGrid_Leftover`:
  still not part of any frame, since frames are one size and leftovers are usually padding) or
  a Cells grid's fractional cells. Its controls
  are small groups in a `skald.wrap_row`, so
  they wrap onto more lines in a narrow panel (a group wider than a line would spill into the
  scrollbar strip: keep groups small). Below: a preview playing the animation and a thumbnail per
  cell of its sheet (click = start, Shift+click = end; the animation's cells lit). The preview runs on `Anim_Tick` at ANIMATION_PREVIEW_FPS while it
  plays and the panel shows. The viewport plays the panel's animation on the sprite too
  (`Preview_Render`).
- **Thumbnails:** the sheet is uploaded once per file (`image_load_pixels`); `drawCell` draws a
  cell with Skald's `draw_image_region` (a pixel rect of an image, inset half a texel so
  neighbouring cells don't bleed in).
- **Undo:** every edit is a `.Node` step (History_Classify; sheet, drop, grid mode and frame
  times too; a frame's time merges per frame); the
  selection, preview and typed name are panel state (`State.animEditor`).
- **Inspector:** an AnimatedSprite's rows are Animations, **Sheets** (the sheets its animations
  use, read only), Starts with, Edit Animations, Save as Animation Asset.
- **Plugins** read and set animations through `getProperty` / `setProperty`
  (`hostGetAnimationProperty` / `hostSetAnimationProperty` in plugin_host.odin; the names are in
  plugin_api's Host doc): no Host change, so PLUGIN_API_VERSION stays 1.
- Tests: `animation_frames_over_time`, `animation_panel_edits`, `animation_frame_times_repeats_and_renames` (frame times, repeats, renames into state machines and keys with undo, the plugin properties), `animations_round_trip`,
  `animations_have_their_own_sheets_in_the_panel` (two sheets, the Size grid, counts, a drop,
  undo, the round trip), `tests/ui/animation.script` (the driver's `click_frame`, `drag_asset_to
  ... animation-scroll`; checks `animations`, `animation` (its sheet, grid, columns, rows, cell,
  margin, gap, cells, count, repeat, durations too), `animation_note`, `autoplay`, `sheet_loaded`; frame times, Plays, a leftover note), `tests/ui/animation_assets.script`
  (a set's second animation on another sheet, cut by size). `scroll_into_view` centers a laid-out widget, and passes when the
  scroll isn't drawn but the widget is visible (layouts that change with the window).

## The sprite sheet slicer (implemented, `slicer_edit.odin`, `view_slicer.odin`; engine: animation.odin's `Sheet_FindSprites`, `CreateRectSheetAnimation`)

TODO.md's Round 4 item 5 (asked 2026-10-24: "Implement a spritesheet slicer. This will allow
slicing of sprite sheets and loading them into an animationplayer. Maybe this could load in it's
own viewport tab."). The manual's page is `docs/manual/sprite_slicer.md`.
- **A center tab per image** (`SlicerState.tabs`, `shown` 1-based), after the code tabs
  (`SlicerTabs_View`, keys `slicer-tab-<i>`, menu `Ctx_Slicer_Tab`). Showing one sets `codeTab`
  0 and the Scene mode (`Slicer_Show`); a code tab picked, a scene tab picked, or another scene
  opened hides it (`update`); Close_Code_Tab (Ctrl+W) closes it. `viewportView` builds
  `slicerCenterView` instead of the viewport, and everything that hit-tests the viewport's last
  rect checks it first (`ViewportWorldAt`: an image dropped on the slicer added a Sprite to the
  scene; the keymap's viewport-only keys; F1's `Docs_TrackPointer`, which says `.Slicer`).
  Opened from the browser's image preview (`browser-slice`) and menu, the Animation panel
  (`animation-slice`), an image dropped on the center tabs or the slicer's canvas
  (`slicerTakesDrop`).
- **Arbitrary rectangles (decided 2026-10-24): frame rects in the animation**, not atlas regions:
  an atlas packs images into one picture and names regions for Sprites, so an animation over
  regions would need a packed copy of the sheet and a frame list of names; the engine's
  per-animation sheet only lacked a way to cut it other than a grid. So `AnimationData.rects` /
  `AnimationDef.rects` (file: `rects="x,y,w,h ..."`, `e.ParseSheetRects` / `e.FormatSheetRects`)
  replace the grid when present: the cells are the rectangles in order, `start` / `end` count
  them, each frame drawn at its size (`e.CreateRectSheetAnimation`, `e.Sheet_CellCount` /
  `Sheet_CellRect` for editors). Added to format 14 without a version (an older reader plays the
  grid's cells instead: wrong frames, nothing breaks), as the camera's settings were.
  **What's made** (`Slicer_AnimationDefs`): a run of a grid's cells in order is the grid and a
  range (the Animation panel edits it as before); frames out of order and found sprites are
  rectangles, evened out per animation when **Same size frames** (`Slicer_EvenOut`: the largest
  size, bottom middle anchored, kept inside the sheet). The grid's `offset` (where it starts:
  `offsetX` / `offsetY`) was missing from the engine too, and is in `SheetGrid` now (the panel's
  Offset).
- **Auto-detect** is the engine's `Sheet_FindSprites` (runs of opaque pixels joined across rows
  with a union-find, 8-connected; boxes merged within `mergeDistance` until none are close;
  specks under `minSize` both ways dropped; reading order by rows of vertically overlapping
  boxes; an opaque top-left pixel is the background key: `Sheet_BackgroundKey`), not the
  collision tracer (`Image_TraceOutlines` keeps a map of edges per pixel: far too slow at 4096²).
  Sheets over `SLICER_DETECT_SYNC_PIXELS` (1 MP) run on a `cmd_thread` worker (`Slicer_Detected`,
  the canvas says "Finding sprites…"); smaller ones in `update` (so unit tests see the result).
  Measured: 4096 x 4096 with 1024 sprites in 207 ms best of 5 (debug build,
  `slicer_big_sheets_are_fast`); the engine's test, 4096 sprites, 264 ms debug.
- **Undo:** the outputs are steps (`History_Classify`): **Create Animation Asset**
  (`Slicer_Asset_Created`) a `.Project` step: the set goes into the project unwritten
  (`Project_CreateAnimationSet(write = false)`: Save writes it like an edited set) with
  `AnimationSetDef.stepMade`, and `restoreProjectSnapshot` takes such sets (and their asset
  entries) out when the snapshot lacks them and puts them back when it has them (other sets are
  still files, not undone); pressed again it updates that asset (a `.Project` step by file).
  **Apply to <sprite>** (`Slicer_Applied`) a `.Node` step on the selected AnimatedSprite (the
  asset when **Use the asset**, else the animations as its own); **Add to Scene**
  (`Slicer_Added_To_Scene`) a `.Scene` step (named after the image: `Slicer_NodeName`, at the
  viewport's center, selected). The tab's settings, picks and animations aren't steps (like the
  Animation panel's selection): they're remembered.
- **Persistence:** `.editor/slicer.ini`, a section per image (`Slicer_Format`: mode, grid,
  detect, found, asset, `anim = fps loop mode | frames | ms | name`), written whenever the
  section's text changes (`Slicer_Save`: the other sections kept, `Slicer_ReplaceSection`, into
  a `.tmp` file renamed over it), read when a tab opens (`Slicer_Load`; else
  `SlicerSettings_Default`: a strip of square cells when the image is one).
- **The canvas** (`slicerCanvas`, built in the body's `sized`): its view is the tab's `center` /
  `zoom`, fitted while not moved by hand (`viewMoved`: `.Measured` refits); input from its last
  rect (the wheel through `wheelAction`, a middle / right / Space drag pans: file state
  `slicerPanning`; a click `Cell_Clicked` with Shift / Ctrl); only the cells in view are built
  (a grid's by its column and row range, nothing under 3 screen pixels), picks numbered when big
  enough. The controls (`slicerControls`) are `inspectorRow`s (labels in `fieldTip`; stacked by
  `Inspector_Layout` at the column's width), 300 px beside the canvas from `SLICER_SIDE_WIDTH`
  (620) of center, else under it (the canvas gets 42%).
- **ANIM_ constants** come as for any set or sprite (script_constants.odin): the asset's
  `ANIM_<ASSET>_<NAME>` and `ANIMATION_<ASSET>` once it's in the project.
- Tests: `slicer_edit_test.odin` (`slicer_grid_math`, `slicer_finds_sprites_on_sheets`: the
  demo's snail walk and a generated uneven sheet on magenta; `slicer_big_sheets_are_fast`;
  `slicer_makes_animations_applies_and_undoes`: picks, two animations, frame times moved, the
  asset made / undone / redone / updated, constants, apply both ways, add, the saved file read
  back; `slicer_settings_persist`), the engine's `sheet_grids_with_offsets_and_rectangles`,
  `sheets_find_their_sprites`, `animation_set_files_and_sprites_using_them` (a sliced animation
  built from a scene file); `tests/ui/slicer.script` (opened from the preview, closed, opened
  from the menu, a grid typed, a run and an out-of-order pick, two animations named, frame times
  and a frame moved, the preview, the asset with undo / redo, applied to PlayScene's Balloon and
  undone, as its own animations, added and undone, auto-detect, the Animation panel's link, a
  narrow center, saved, closed with Ctrl+W, an image dropped on the tabs). Looked at in PNGs at
  640x660, 900x500 and 1280x720 (Skald's offscreen renderer made public in the submodule's
  working tree for a scratch driver command, then put back).

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

## Editor modes (implemented, `editor_modes.odin`, `level_mode.odin`)

TODO.md's Round 4 "Editor modes: a top tab bar" (asked 2026-10-24: "the current app could be a tab
called Scene, the next mode would be Level... in the future 3D, or a pixel editor"). The manual's
pages: getting_started.md's "Editor modes" and `docs/manual/level_mode.md`.
- **A mode is a registration** (`EDITOR_MODES[mode]`): its workspace view (built by
  `modeWorkspaceView` inside the root view's `sized`), its bottom tabs, its manual page and the
  `Action` switching to it. Its state lives beside `State.level`; its panel sizes are a `Layout`
  (`Mode_LayoutOf`). A new mode: an `EditorMode` value, its registration, an Action with its
  `[keymap]` line and label, and its state.
- **The mode bar** (`modeBarView`, keys `mode-tab-<Name>`): in the menu bar's row (Godot's
  workspace buttons are the model: no height of its own), each tab an icon and a name, the shown
  one in the accent color, a tooltip with its keys.
- **Shared:** the menu bar (View > Scene Mode / Level Mode, checked; another mode's items
  disabled), the toolbar (its file, undo, play and Export buttons; the mode's tools in the
  viewport tools' place), the Console and Output (one list each; the Level mode's strip shows them
  too), Settings, Project Settings, the docs window, the history, and the panels' look and default
  sizes (the layout rules' "Every mode uses the editor's shared widgets and sizes"). Per mode: the
  workspace, panel sizes, the bottom tab, the status bar's middle (`LevelMode_Status`). The
  viewport's tools and the project browser are the Scene mode's: the Level mode has its layer tools
  and its Levels sidebar instead.
- **Code tabs are the Scene mode's**, beside the scene tabs: `CodeTabs_Open(show = true)` shows the
  Scene mode, so Go to Error, Open Script and the docs' links reach the code from any mode; the
  code view, `CodeEditor_Frame` and the live values only run there.
- **What belongs to a mode shows it** (`update`, after the message): in another mode, a scene
  opened, a node selected or a code tab picked shows the Scene mode; `Bottom_Tab_Changed` with a
  tab only another mode has shows that mode (`Mode_ShowBottomTab`: the status bar's Git branch);
  Play's and exports' log tabs show in every mode that has them, without switching
  (`Mode_ShowLogTab`). Not after undo / redo (their step's own mode) or a project opened
  (`session.opened`: the mode it was left in). Scene-only ticks (the Animation panel's, the
  Timeline's) stop in another mode.
- **Persistence:** `.editor/modes.ini` (`mode`, `level_file`, `level_world`), written when the mode
  or the Level mode's world changes (`Mode_Save`; only for a project folder on disk), read by
  `init` and `switchProject` (`Mode_Load`).

### The Level mode: LDtk's layout (phase 1 of TODO.md's "LDtk level editor", 2026-10-24)

The user's design (`LDtk_interface.html`, a Penpot export of a 1920x1080 mockup, not committed:
the user's file) gives the arrangement; the sizes and widgets are the editor's (the user's
correction of 2026-10-25: phase 1 had copied the mockup's 75 px tool row of 45 px buttons, 60 px
rows and 300 px sidebars, and the Level mode looked like another app); level_mode.odin's doc block
has the picture.
- **The tools** (view_level_tools.odin) are on the editor's toolbar (`toolbarView`), in the
  viewport tools' place, with its buttons, grouping, file, undo, play and Export buttons.
  LDtk has no tool buttons (left paints, right erases, Shift a rectangle, Shift + click fills, Alt
  picks: its Tool.hx), so the row is those per layer type (`LevelTools_For`: IntGrid Select /
  Pencil / Rectangle / Fill / Eraser / Picker; Tiles with Stamp and Random; Entities Select /
  Place / Eraser / Picker; AutoLayer Select). Since phase 2 every tool works (painting: below).
  Narrow: the tools go into the toolbar's overflow menu (`toolbar-more`, `Ctx_Toolbar_More{level}`:
  `LevelTools_MenuItems`), by the same rule as the viewport's (`Toolbar_Overflow` takes the mode's
  tool count).
- **Sizes:** the Scene mode's. The sidebars start at its widths (`LEVEL_LAYOUT_DEFAULT`:
  `DEFAULT_LEFT_WIDTH` / `DEFAULT_RIGHT_WIDTH`, a 374 px bottom panel for LDtk's tabs) and fit a
  window as its sidebars do (`FittedSidebarWidths`, `MIN_SIDEBAR_WIDTH`, `MIN_CENTER_WIDTH`; no
  one-sidebar layout); the rows are `settings.rowHeight`, the headers `panelHeader`s, the tab
  strip the bottom panel's own height.
- **The Levels sidebar** (view_level_sidebars.odin): the panel header (+ is `level-new`: a new
  level's spot), the file choice (`level-file`, several LDtk assets), the world choice
  (`level-world`, LDtk's Multi-worlds), a row per level of the shown world (`level-row-<i>`:
  `rowList`'s rows, the scene tree's: a click `Level_Row_Clicked`, Up / Down the next, a
  double-click focuses, a right-click selects it and opens `Ctx_Level{level:
  its index}`: the target holds no string, it outlives the frame). Its menu: Focus, Open in the
  Scene Mode, New Scene with This Level, Open in LDtk at This Level, Rename, Duplicate, Delete,
  depths, Move to another world, New Level... (phase 5: "Levels, worlds and the project").
- **Several worlds** (`LevelMode.world`, a world's iid; `LevelMode_World`, `LevelMode_WorldLevels`):
  the canvas (`LevelCanvas_Content` filters to the world), the fit, the sidebar and the World tab
  show one world; a level of another world selected shows its world (`levelSelect`). Fixture:
  `tests/fixtures/ldtk_world/worlds.ldtk`.
- **Focus** (`LevelMode.focus`, `Level_Focus_Changed`): LDtk's level view: the view fits the
  level (`levelFit`, a 0.85 margin), the others dimmed (`LevelCanvasLevel.dim`), only its
  entities picked; a press on another level focuses it, on the focused one pans (levels move only
  in the world view), a double-click on empty space or the header's `panel-level-world-view`
  goes back. `LevelView.fitted` is the file, world and focus (`levelFitKey`).
- **The Layers sidebar**: the selected level's layer instances, top first (else the
  definitions); a row selects the layer (`Level_Layer_Picked`: `LevelMode.layerDef`, which the
  tools and the Layers tab follow; -1 the first); the eye (`level-layer-eye-<i>`, a zone: a
  button draws its own background) sends `Layer_Visible` (LDtk's eye is the layer instance's
  `visible`, saved and undoable: its LevelRender.setLayerVisibility); a row dragged (past
  `TREE_DRAG_THRESHOLD`, as the scene tree's) moves the layer: file state `layerRowDrag`
  (view-only, like `valueSlider`'s), an overlay line where it goes, the release sends `Layer_Move`
  with `number` the places moved (ldtk_ops.odin's `ldtkMove`: the definitions' array and every level's instances in that
  order).
- **The bottom tabs** are LDtk's panels (`BottomTab` World, Level, Layers, Entities, Enums,
  Tilesets, Auto_Layer_Rules, LDtk_Project: `BottomTab_Label` names them), then Console and
  Output; view_ldtk_tab.odin builds them (`LevelMode_LDtkTab(s, ctx, tab)`), every one with a list
  in the bottom tabs' shared layout (view_list_tab.odin: toolbar row, list sidebar
  `ldtk-list-<Tab>`, settings; the Project tab without a list). Today's sections
  moved: Layers + Collisions (an IntGrid layer's values and kinds) into Layers; Entities + Links'
  references into Entities; Level fields + the old level panel (size, place, the scenes showing
  it, New Scene with This Level) + Links' neighbours into Level; World (the shown world, its
  choice), Enums and Tilesets as they were; Auto-layer Rules LDtk's rule panel (since phase 4); Project the
  file's settings read only, Unsaved / Save. Selecting an entity shows the Entities tab unless
  the Console or Output shows. Each tab has its manual section (`DOCS_BOTTOM_TAB_PAGES`).
- **The canvas header** (`levelMapView`): where it is (World, or World → Level), "unsaved", the
  zoom, Focus / World, Fit, Open in LDtk (`panel-level-*`, panelButton's keys), and LDtk's change
  on disk (the bar of "Saving, undo and LDtk" below, or a note).
- **The world canvas** (`LevelCanvas_Build` in a `sized`): its view is `LevelView` (the world point
  at the center, a zoom; fitted once per file, world and focus: `LevelCanvas_FitOnce` on
  `Level_Canvas_Measured`). Input comes from its last rect like the viewport's: the wheel through
  `wheelAction`, a press (`Level_Canvas_Pressed`: the entity under it first, then the level, `pan`
  for middle / right / Space) starts a `LevelDrag` (Pan, Level, Entity), every move sends
  `Level_Canvas_Moved` anywhere, the release `Level_Canvas_Released`, which makes the move
  (`LevelDrag_Target`: a GridVania world's grid, an entity's layer grid with its pivot on a cell's,
  Shift free) one `.Files` step (`History_Classify` names it from the drag). The levels are drawn
  by level_layers_render.odin as LDtk's LayerRender draws them (since phase 2; it was the engine's
  software renderer, `Preview_RenderLDtkLevel`, one picture per level): the focused level a
  picture per layer in 256 px pieces (painting redraws only the pieces it changed), the others one
  picture each, drawn again only when their content key changes (`levelContentKeys`), so dragging
  a level doesn't redraw it. Entities are outlined from the JSON (pivot, size, smart color), links
  are EntityRef `__value`s (arrows) and the selected level's neighbours (`LDtkDoc_Neighbours`,
  dashed).
- **The tabs' rows** (view_ldtk_tab.odin): each tab picks its item in its list (`ldtk-list-<Tab>-<i>`,
  a narrow panel's dropdown `ldtk-item-<Tab>`; `LDtk_Item_Picked` and the others, by uid: the first
  when gone); its rows are the inspector's (`tabRow` → `inspectorLabelled`, stacked by
  `Inspector_Layout` at the content's width). Text fields send `LDtk_Text_Typed` (the typed
  text kept in `State.numberEdit` while focused, applied whenever valid: an invalid name never
  reaches the document, `LevelMode.problem` says why above the rows), numbers
  `LDtkNumberTarget`, flags and choices `LDtk_Edit` directly. The Layers tab's kind choices edit
  scenes' LDtkLevel nodes (`Level_Collision_Kind_Changed`, a `.Project` step: the node may be in
  another scene).
- **Looked at** in PNGs at 640x660, 900x500, 1280x720 and 1920x1080 (Skald's offscreen renderer
  made public in the submodule's working tree for a scratch driver command rendering the whole
  window, then put back), against the design's render; again on 2026-10-25 beside the Scene mode's,
  with both modes' widget rects compared (see the layout rules).
- Tests: `editor_modes_test.odin` (switching, bottom tabs and panel sizes per mode, what shows the
  Scene mode, the keys' scope and chords, persistence, a level's scene made and opened, undo and
  redo across modes; `level_mode_layout_tools_worlds_and_layers`: the sidebars at four widths,
  the tools per layer type and only Select working, worlds, focus, the layer selection, a layer
  dragged two places in one step, the world remembered); `tests/ui/modes.script` (the bar, the
  keys, the actions, the toolbar's Level tools and the Levels sidebar instead of the viewport's tools and browser, a
  selection kept across modes, Scene-only keys idle in the Level mode, the world of an imported
  LDtk file, a level selected, New Scene with This Level in the Level tab, undo back into the Level
  mode, a level's menu opening its scene, the mode remembered when the project opens again);
  docs_test's `Docs_TypeAddress` with project types; `level_canvas_drags_levels_and_entities`
  (fit, drags of levels in Free and GridVania worlds and of entities on and off their grid, a
  click that doesn't move, panning, typing merged into one step, undo, unsaved until undone);
  `tests/ui/ldtk_tab.script` (below).

### Painting in the Level mode (phase 2 of TODO.md's "LDtk level editor", 2026-10-24)

LDtk's tools on the focused level's selected layer, as LDtk behaves (its source in the
workspace's `../ldtk`, 1.5.3: Tool.hx, tool/lt/, SelectionTool, ResizeTool, data/inst/
LayerInstance.hx, data/def/AutoLayerRuleDef.hx). level_paint.odin's doc block has the buttons and
keys; the manual's level_mode.md "Painting" is the user's guide.
- **The model, not the JSON, while a stroke runs:** the focused level is decoded once per
  document version (`LevelPaint_Model`: ldtk_level_model.odin, about 35-58 ms for a 256 x 256
  level of six layers, optimized), changed in place by the tools (ldtk_paint.odin) and the rules
  (ldtk_rules.odin), drawn from it (only the changed pieces); the release writes the changed
  layers back (`LDtkLevel_Patches`: the arrays rewritten as LDtk's JsonPretty writes them,
  ldtk_json_pretty.odin) in one `LDtkDoc_Commit`: one `.Files` step a stroke. The model survives
  the commit (only grid strokes are dropped when it's rebuilt).
- **Auto-layers are LDtk's, byte for byte:** rules evaluated in LDtk's order around each change
  (radius: the rules' size; `LDtkRules_AfterChange`: the layer's own rules, the AutoLayers built
  from it, Tiles layers' tiles killed by rules), its seeds with JavaScript's number semantics
  (`ldtkRandSeedCoords`), heaps' Perlin noise (repeat 50, gradients scaled as at run time), the
  area counts LDtk uses to skip rules (`isRelevantInLayerAt`: 10 x 10 areas, a group's values
  `(g + 1) * 1000`, ungrouped values counted as 1000), tiles stored by coordinate (Haxe's IntMap
  iterates in order) and drawn in display order (groups and rules reversed). Checked against
  LDtk's own samples (`ldtk_rules_test.odin`: every auto layer of every sample in `../ldtk`
  re-evaluated from its IntGrid, 130 layers, 57,682 tiles, identical; a sabotaged rule fails it).
  The demo's legacy.ldtk differs only in its random tiles: make_demo.py chose them with Python's
  `random`, not LDtk's seeds.
- **Entities** (ldtk_entity_ops.odin, `LDtkOps_EntityEdit`): new ones written in LDtk's key order
  with new iids, `__worldX/Y` in Free and GridVania worlds, LDtk's count limits, references to a
  removed entity dropped, the table of contents rebuilt only when it differs.
- **Performance** (2026-10-24, optimized, `level_painting_is_fast`, best of runs): a generated
  256 x 256 level of six layers (6.5 MB file, 34,607 auto tiles): press 35-58 ms (the decode,
  first press after a document change), moves 2.5-3.5 ms mean (worst 6-11 ms), release 120-147 ms
  (most of it `LDtkDoc_SetTexts` parsing the 6.5 MB text again), undo 55-104 ms; the demo's
  Hollow (180 x 48): moves 1.4-2 ms, release 10-56 ms, undo 8-12 ms. Moves are what keeps 60 fps.
- **Undo steps of big files keep hunks** (history.odin's `FileText`): files under
  `FILE_STEP_WHOLE_MAX` (256 KB) keep both texts; bigger ones the diff's hunks (`textHunks`: the
  texts split after `,` and line breaks, resynced on six equal segments in a row, the nearest
  within 4096): 0.1 MB a stroke on the 256 x 256 level instead of 13 MB. A hunk step needs the
  document as the step left it (applied exactly); otherwise it waits on the conflict dialog.
- Tests: `level_paint_test.odin` (each tool and layer type against LDtk's behaviour, rules and
  writing, entity edits, the Level mode's strokes with undo, the performance test with
  byte-identical undo / redo), `ldtk_rules_test.odin` (LDtk's samples, the JSON writer),
  `tests/ui/level_paint.script` (every kind painted, at 640x660, 1280x720 and 900x500); fixture
  `tests/fixtures/ldtk_paint/` (`make_paint.py`).

### The definitions editors (phase 3 of TODO.md's "LDtk level editor", 2026-10-25)

LDtk's definition panels (its source in the workspace's `../ldtk`, 1.5.3: ui/modal/panel/
EditLayerDefs, EditEntityDefs, EditEnumDefs, EditTilesetDefs, EditLevelFieldDefs, ui/FieldDefsForm,
data/Definitions.hx, data/def/, misc/FieldTypeConverter, importer/) as the bottom tabs' rows
(view_ldtk_defs.odin); the manual's `level_definitions.md` is the user's guide.
- **One way for every edit** (ldtk_defs.odin's doc block): the definition changes (`Def_Set` a
  member from `LDTK_MEMBERS`, `Def_Added` / `_Removed` / `_Duplicated` / `_Moved`,
  `Field_Converted`, IntGrid values and groups, enum values, external enums, tiles' data), LDtk's
  handler's consequences (`defConsequences`), then **LDtk's tidy** (ldtk_tidy.odin) brings every
  level in step, then auto-layers whose tiles depend on what changed are applied again
  (`rerunRules`), all in `Stages` (each pass made on what the last left) and one `LDtkDoc_Commit`:
  one `.Files` undo step. The older ops route through it where LDtk does more (`Field_Default`:
  every type's default; `Layer_Grid_Size`: cells remapped as LDtk remaps them, no longer refused
  when painted).
- **The tidy is the check against LDtk**: it changes nothing in LDtk's 18 samples and its 1.5 test
  files (`ldtk_tidy_leaves_ldtks_own_files_alone`), so whatever it writes after an edit is what
  LDtk derives. Found doing it: a level's `__smartColor` is its background 45% toward white
  (rounded); local enum values are looked up cleaned with the project's style ("Heavy sword"
  finds Heavy_sword); a Multilines value's editor value is escaped once more than `__value`
  (FieldInstance.fromJson unescapes it); our fixtures' smart colors, entity tags and tiles and
  references' world iids weren't LDtk's (fixed in make_world.py / make_paint.py, regenerated).
  The writer now keeps line breaks as `\n` (LDtk escapes its strings before JsonPretty).
- **New definitions in LDtk's key order** (compared with LDtk's sample's in
  `ldtk_new_definitions_are_written_as_ldtk_writes_them`), LDtk's defaults and names
  (`ldtkUniqueId`), uids from `nextUid` (never reused, as in LDtk). **Pixel data** of a new or
  changed tileset is LDtk's byte for byte (`ldtk_tileset_pixel_data_matches_ldtk`: every sample
  tileset, an Aseprite one too; the average colors' nibbles are bytes rounded to 17ths).
- **External enums**: imported from the project's assets (text, JSON, Haxe, CastleDB), synced with
  LDtk's diff (values added and removed, the file's order, CastleDB's colors and icons, the MD5
  checksum: LDtk's sample synced is byte-identical), removed per file. The tab says when a file
  changed and what a sync would remove (`LDtkEnums_SyncPreview`).
- **LDtk's internal icons** (`embedAtlas: LdtkIcons`): the tileset is made (512 x 1024, 16 px), but
  the image is LDtk's (FinalBossBlues', editor only): pickers and the engine show it only from a
  copy beside the .ldtk (LDTK_ICONS_FILE).
- **Deviations, on purpose:** a Tiles layer given a tileset of another grid has its cells remapped
  (LDtk keeps coordinates, scrambling them); auto-layers are applied again when their tileset,
  source, kill layer or biome changes (LDtk waits for the next rule change); a field's conversion
  converts level fields' values too (LDtk only entities'); IntGrid values move to a place in a
  group (LDtk's drag moving down always went to the group's end).
- **The UI**: each tab's list in its sidebar (view_list_tab.odin), its buttons on the toolbar row
  (`ldtk-<list>-add`, `-duplicate`, `-delete`, `-up`, `-down`: `listTools`); a sub-list's (fields)
  choice and buttons in the rows, members' rows keyed `ldtk-<kind>-<member>`, the field form for entities' and levels'
  fields, `tilesetPicker` (`ldtk-picker-<what>`: a drag picks a rectangle, tags, or one tile; its
  drag state is file state, freed by `LDtkDefs_Destroy`). Picks: `LDtk_Def_Picked` (field, level
  field, tileset, tile data mode, data tile); a definition made or copied is selected
  (`LevelMode_SelectMade`). Looked at in PNGs at 640x660, 900x500 and 1280x720 (the tabs' rows
  rendered through Skald's offscreen renderer, made public in the working tree for a scratch driver
  command, then put back).
- Tests: `ldtk_defs_test.odin` (the tidy on LDtk's files, pixel data, new definitions against
  LDtk's sample, layers, entity types and fields, enums and external enums with LDtk's sample
  synced, tilesets, auto-layers re-applied, undo byte for byte through the editor; every edit
  schema-checked, read by the engine and left tidy: `defsCheck`), `tests/ui/ldtk_defs.script`
  (every tab: a layer made and removed, values, a grid, an entity type drawn with a picked tile, a
  field and its default, an enum, a tileset's tags dragged on its picture and a tile's data, a
  level field, saved; driver: `send LDtk_Item_Picked`, `send LDtk_Def_Picked`); fixtures
  `tests/fixtures/ldtk_enums/`.

### The Auto-layer Rules tab (phase 4 of TODO.md's "LDtk level editor", 2026-10-25)

LDtk's rule panel and rule editor (its source in the workspace's `../ldtk`, 1.5.3: ui/modal/panel/
EditAllAutoLayerRules, ui/modal/dialog/RuleEditor, RuleModuloEditor, RuleRandomOffsets,
RulePerlinSettings, RulesWizard, RuleGroupRemap, ui/RulePatternEditor, data/def/AutoLayerRuleDef,
AutoLayerRuleGroupDef, LayerDef's rule functions) as the tab's pages (view_ldtk_rules.odin), so the
canvas stays in view; the manual's `level_rules.md` is the user's guide.
- **One way for every edit** (ldtk_rule_ops.odin's doc block): the layer's groups read as LDtk's
  fromJson reads them, changed, every rule tidied as LDtk's toJson tidies it (trimmed patterns,
  mirrors of symmetric patterns and checkers without a modulo off, a lost out-of-bounds value
  cleared) and written as toJson writes them (the whole `autoRuleGroups` array: LDtk's key order,
  `invalidated` false), then LDtk's tidy (an optional group's levels' states go with it) and the
  layer's rules applied again in every level (`rerunRules`; one level for its seed, tileset or an
  optional group there; not for names, colors, icons, advanced mode): one `LDtkDoc_Commit`, one
  `.Files` undo step. Typed and stepped values merge (`LDtkEdit_Info`); toggles don't.
- **The check against LDtk**: every group of LDtk's 18 samples (86 groups, 368 rules) read and
  written back is its text byte for byte, and LDtk's rule tidy changes nothing in them
  (`ldtk_rule_groups_write_back_as_ldtk_wrote_them`); edits undone by their opposite (a chance, a
  rule and a group off and on, a pattern changed and put back, a group moved, a rule copied and
  removed, an optional group off and on in a level, biomes) give LDtk's own sample files back byte
  for byte, the auto-layer tiles made again by the ported evaluation included; the Assistant's
  sample group read back and made again gives LDtk's 19 rules (patterns, tiles, mirrors,
  policies, order). Every edit in the tests is schema-checked, read by the engine, left tidy, and
  its levels' tiles are what the rules make (`rulesCheck`).
- **LDtk's behaviour kept**: new rules are LDtk's (3 x 3, chance 1, break on match, a random Perlin
  seed; written trimmed), new empty groups go first ("New group"), copies and pastes get new uids
  after the original, a moved rule lands where LDtk's sortable puts it, the editor's 9 x 9 grid with
  RulePatternEditor's buttons (left: the value, or clears a "not"; right: "not" the value, or
  clears; middle: clears; the cell pressed first decides), RuleEditor's smart value, tiles picked
  as ui.Tileset picks them (a drag column by column, Shift adds in tile order, the right button
  removes, one stays), chance and Perlin scale in percent, alpha to 2 decimals, the X offset kept
  within its modulo (only X, as LDtk), random offsets linked while min is -max, a level's own
  tileset for the layer only of the same size, flips refused on symmetric patterns, checker modes only
  with their modulo, a group of the Assistant's refusing other edits until Advanced mode. Rule
  groups' `collapsed` is the tab's (LDtk doesn't save it): closed, but a layer's only group.
- **Deviations, on purpose:** a new rule left empty stays (LDtk's editor removes it when it
  closes: here there's nothing to close); the Assistant reads back every tile of a part (LDtk
  keeps the first only, losing the others when a group is edited again); LDtk 1.5.3's group menu
  offers "Turn into an OPTIONAL group" to optional groups and "Disable OPTIONAL state" to the others
  (inverted): here each to the group it applies to; colors from LDtk's palette or typed (no color
  wheel); the remap's and icon's pickers and the modulo, offsets and Perlin dialogs are the tab's
  pages and sections.
- **Measured** (2026-10-25, `ldtk_rule_edits_timing`, best of runs): a rule's chance changed on
  LDtk's biggest sample (WorldMap_GridVania_layout: 2.4 MB, 21 levels, 30 rules) takes 62 ms
  optimized, 231 ms in a debug build (every level of the layer evaluated again).
- **The canvas** (level_canvas_paint.odin's `levelRulesOverlay`, while the tab shows): the hovered
  rule's or group's tiles outlined (magenta over purple, LDtk's showAffectedCells; not while
  auto-layers are hidden), the edited rule's Perlin noise (RulePerlinSettings' preview), and the
  cell under the pointer reported to the tab, which highlights the rules putting tiles there
  (onEditorMouseMove: `LDtkRules_At`). The hover is view state kept a frame behind
  (`LevelRules_SetHovered`).
- Tests: `ldtk_rule_ops_test.odin` (LDtk's samples written back, edited and given back, optional
  groups, biomes, every group and rule edit with LDtk's bounds and refusals, the Assistant against
  LDtk's sample, duplicate and remap, undo through the editor, the tab's state),
  `tests/ui/ldtk_rules.script` (at 640x660, 1280x720 and 900x500: a group opened, a rule hovered
  and its 36 cells outlined, a canvas cell highlighting its rule, a group off with undo and redo,
  an optional group per level, a group made and named, a rule made in its editor (tiles dragged,
  added and removed, the pattern painted with the three buttons, the chance typed, a mirror, a
  modulo and checker, linked offsets, Perlin and its preview, the out-of-bounds policy), a rule
  dragged into another group, copied and pasted with undo, the Assistant, duplicate and remap, a
  color, an icon, a group deleted, Randomize, saved; driver: `send Rules_View <op> [uid] [number]
  [flag]`, `hover_at`, `drag_to`, `level_hover`, check `rules <field>`). The paint fixture's
  one-cell rules are 1 x 1 now (make_paint.py: LDtk writes them trimmed). Looked at in PNGs at
  640x660, 900x500 and 1280x720 (the tab's rows and the canvas rendered through Skald's offscreen
  renderer, made public in the submodule's working tree for a scratch driver command, then put
  back).

### Levels, worlds and the project (phase 5 of TODO.md's "LDtk level editor", 2026-10-25)

LDtk's world view and World panel (WorldTool, WorldPanel, LevelSpotPicker, Rulers), level form
(LevelInstanceForm), project panel (EditProject), its save's extra outputs (ProjectSaver), its
selection (SelectionTool, GenericLevelElementGroup), its field display (FieldInstanceRender) and
saved tile selections; the manual's `level_worlds.md` is the guide, `level_parity.md` the
checklist of every LDtk feature (429: 305 done, 60 differently, 41 not done, 23 not applicable).
- **The document's file set can change** (ldtk_doc.odin): texts are by path
  (`LDtkDoc_FromPaths`, `_TextsByPath`, `_SetTextsByPath`); a file with `saved == ""` isn't on
  disk yet; `Stages.added` carries new files through an edit's passes; undo steps record files
  made and dropped (a side of `""`, always whole); Save makes folders, writes a backup first, then
  the files, then removes `.ldtkl` files no level uses (`ldtkCleanLevelFiles`) and writes LDtk's
  extra outputs (`LDtkSave_Exports`). Separate level files, minified JSON and Multi-worlds rewrite
  whole files: `LDtk_PrettyJson` writes LDtk's 1.5 files byte for byte, whole
  (`ldtk_writer_remakes_ldtks_files_whole`).
- **LDtk's rules, ported and checked** (ldtk_level_ops_test.odin): automatic names
  (`applyAutoLevelIdentifiers`), new levels' spots and linear insert points, duplicates' remapped
  references, resizes (`applyNewBounds`: cells and entities kept where they are, cropped),
  `__bgPos`, external file names (the index prefix), Multi-worlds on and off, the identifier
  style everywhere, field values' parsing and regexes, PNG names, backups' names and pruning; PNG
  export compared with LDtk's `levelBgs` output, every edit schema-checked, read by the engine and
  left tidy.
- **Decided:** custom commands are kept and edited but never run (a project file could run any
  program); the Tiled export isn't written (LDtk's covers the first world only: its own HACK note),
  its setting kept; PNG images are drawn by the editor's renderer (a pixel can differ where tiles
  blend); turning Multi-worlds off keeps LDtk's `dummyWorldIid` (references follow on LDtk's next
  load, as LDtk does).
- **The canvas:** a press goes to the world tools (`LevelWorld_Press`: a spot, a resize handle),
  then the selection (`LevelSelect_Press`, inside the focused level only), then painting. Fields
  are drawn from `LevelCanvasEntity.fields` / `LevelCanvasLevel.fields` (marks under entities,
  rows over them); entity references are field marks now (the old arrows are gone).
- **Keys** (settings.default.ini): P / L / E / U / T / C the tabs, 1 to 0 the layers, PgUp / PgDn
  depths (Ctrl: the level's), Ctrl+A, Shift+E, Shift+S, Delete.
- Tests: `ldtk_level_ops_test.odin`, `level_fields_render_test.odin` (field display, references
  picked across levels, typed entity sizes, the panel and layer keys), `tests/ui/levels.script`
  (driver: `level_world_click`, `level selection | spot | depth`). Looked at in PNGs at 640x660,
  900x500 and 1280x720 (Skald's offscreen renderer made public in the submodule's working tree for
  a scratch driver command, then put back).

## Editing LDtk projects (implemented, `ldtk_json.odin`, `ldtk_doc.odin`, `ldtk_ops.odin`)

TODO.md's Round 4 "Level mode and the LDtk tab" (asked 2026-10-24: "Dedicated LDtk tab for deeper
level integration... Also allow tighter integration with the LDtk"; decided: the Level mode is a
world/level editor and the groundwork for our own LDtk-format editor; edits write back into the
.ldtk file), and since phase 1 of "LDtk level editor" (2026-10-24) **saved as LDtk saves: edits in
memory, written on Save, Play, exports and Open in LDtk**. ldtk_ops.odin's doc block lists what
each edit changes and what isn't editable yet.
- **Write-back keeps the file's text** (ldtk_json.odin): the JSON is parsed into nodes that know
  their spans, and an edit is a list of patches (`LDtkPatches`, per file) replacing only the
  values it changes; untouched files and values stay byte for byte as written (key order, number
  forms like `1.0`, LDtk's odd pretty-printing, minified files). New values are written like their
  neighbours (`Json_AppendPatch` copies the separator between the first two items; minified
  stays minified; small objects LDtk-style, `{ "id": "V_Int", "params": [5] }`). Patches that
  overlap or a result that doesn't parse are refused before anything is written.
- **Edits in memory, written on Save** (decided 2026-10-24, phase 1: phase 2's painting needs fast
  edits and an undo step per stroke; LDtk saves the same way). `LDtkDoc_Commit` applies the op's
  patches, then from what they make (`LDtkDoc_FromTexts`) a second pass for what LDtk derives
  (`ldtkCommit`: neighbours, entities' `__worldX/Y`, the table of contents), and gives the document
  its new texts (`LDtkDoc_SetTexts`): nothing is written. Each `LDtkDocFile` keeps what's on disk
  (`saved`, its time `modified`) and whether its text differs (`unsaved`). The project is
  modified while any document is (`Project_IsModified` → `LDtkDocs_AnyUnsaved`; an undo back to
  the saved text leaves nothing to save: file steps stay out of `History.fileVersion`'s count).
  **Written** by `LDtkDoc_Save` / `LDtkDocs_SaveProject` from `Session_Save` (Ctrl+S, the save
  prompt, git's commands), `playStart`, `Export_Start` and `LDtkEdit_OpenInLDtk`; Save As writes
  the unsaved texts into the copy (`LDtkDocs_UnsavedTexts`); another project opened drops them
  (`switchProject` → `LDtkDoc_DestroyAll`, after the save prompt). Each changed file goes to a
  temporary file renamed over it (`LDtk_WriteFile`, never a half-written file); the rename is
  `File_Replace`, which tries again for about 100 ms when Windows refuses it (a file another
  program has open without sharing its deletion) and then writes the text into the file itself
  (`ldtk_files_are_replaced_even_when_open`). The time is moved past the last one seen
  (`ensureNewerTime`: Linux's file clock is coarse, two writes a few ms apart got one time, and
  every cache keyed by it (a running game's `LDtk_WatchFiles` too) missed the second).
- **The unsaved document is what the editor shows**: `LDtkDoc_Stamp` (the file's time, or the
  unsaved document's version) keys the caches of what the engine makes of a file (the viewport's
  `forgetChangedLDtk` and `LDtkSettings_Signature`, the thumbnails, `Preview_RenderLDtkLevel`, the
  inspector's `LDtkEdit_Project`), and `LDtkDoc_ProvideToGame` puts the unsaved version in a
  game's `ldtk` map (`e.Game_LoadLDtk` finds it) parsed from `LDtkDoc_GameText`: the project file
  with the `.ldtkl` levels' layers patched into their entries (the engine reads an entry's layers
  when it has them, else the file): no engine change. A game from Play reads the saved files.- **LDtk's consistency, ported from its source** (`../ldtk`, 1.5.3): identifiers cleaned as
  `Project.cleanupIdentifier` with the project's style (fields and IntGrid values: Free), unique;
  `__identifier` / `__type` mirrors, enum value renames into values, editor values, defaults and
  tilesets' tags (`EnumDef.renameValue`); a field value is `__value` and `realEditorValues`
  (`FieldInstance.toJson`: `[]` for the default; points `V_String("cx,cy")`, colors `V_Int`);
  `__grid` (`EntityInstance.getCx`: a pivot of 1 counts the pixel before); neighbours
  (`Level.getNeighboursJson`; an equal set is left as written); layouts
  (`World.onWorldLayoutChange`, `onWorldGridChange`; linear worlds store -1 and are laid out 48 px
  apart); new enums take `nextUid`. Renames of layers and entity types also rename scenes' and
  components' LDtkLevel settings (collision layer, entity rules) in the same step (`LDtkRename`,
  `EditInfo.withProject`; components, which the project's snapshot doesn't hold, through
  `FileChange.components`, their nodes before and after: `ldtk_renames_follow_into_components_and_undo`). Files LDtk older than 1.0 wrote aren't edited (`LDtkOps_TooOld`).
- **Undo** (history.odin, `.Files`): the snapshot is the document's texts in memory, the step
  keeps the files that changed (`FileChange`: before and after texts, or a big file's hunks
  (`FileText`, since phase 2: see "Painting in the Level mode"), and the project's snapshot for
  renames). Undo puts "before" back in the document (`History_RestoreFiles` →
  `LDtkDoc_SetTexts`) when it's as the step left it; when it changed since (LDtk saved the file and
  it was read again or merged), `History_MergeText` applies the step's change to it when the two
  changes don't overlap (common prefix and suffix of each against the step's text) and the result
  parses; otherwise the step waits on the conflict dialog (`ldtkConflictDialogView`: Overwrite,
  Keep the File (the step and the older history go), Cancel; a big file's hunks can't overwrite a
  file changed where they are: the file is kept).
- **External changes** (`LDtkDoc_Get`, when any file's time changed): without unsaved edits the
  document is read again; with them, LDtk's change is merged into them per file
  (`ldtkMergeDisk`: `History_MergeText` with the saved text as the base, the document's as ours,
  the file's as theirs; the file's text becomes the new saved one, so the document stays
  unsaved); when they touch, the document stays and the file's text waits in `diskConflict`
  (`LDtkDoc_DiskConflict`; not looked at again until the file changes again): the canvas's bar
  (`ldtk-disk-reload` / `ldtk-disk-keep`, `LDtk_Disk_Chosen` → `LDtkDoc_ResolveDisk`) reloads the
  file (the edits dropped; Ctrl+Z still has them, merged or asked as above) or keeps the edits
  (the file's text becomes the saved one, other files' changes merged: Save writes over LDtk's
  change); `LDtkDoc_Save` refuses meanwhile. `LDtkDoc_Outside` remembers the change (merged or
  clashing) for the status bar and the canvas's header. LDtk itself doesn't watch its project file
  (its FileWatcher watches images and external enums), so the manual says to reopen the file in
  LDtk after saving here.
- **Open in LDtk at a level**: LDtk's command line takes only a file (App.hx's `getArgPath`; a
  `.ldtkl` path's level index is parsed but unused, Editor.hx's TODO), but its editor selects
  `settings.lastProject.levelUid` whenever it opens a project, so `LDtk_RememberLevel` patches that
  member of LDtk's settings.cfg (`LDtk_SettingsPath`: Electron's userData per OS;
  `CROSSFIRE_LDTK_SETTINGS` overrides it) before starting it. An entity can't be selected.
- **Schema**: LDtk's JSON_SCHEMA.json (1.5.3, MIT) is in `tests/fixtures/ldtk_schema/`;
  `LDtk_SchemaProblems` (ldtk_doc_test.odin) checks the keywords it uses (`$ref`, `type`,
  `required`, `properties`, `additionalProperties: false`, `items`, `oneOf`, `enum`; a .ldtkl as
  `Level` without its `__header__`). Not checked with LDtk itself: it's an Electron app and this
  machine has no headless display server (no Xvfb); its source was read instead.
- **The demo's legacy.ldtk** (generated, never saved by LDtk) had Point fields' editor values as
  `V_Int` (LDtk's `getPointStr` throws on them: its load would fail) and its EntityRef's empty (LDtk
  reads that as unset and would drop the gate's reference on save): fixed in the file (a Python
  round trip is byte-identical but for them) and in `tools/demo/make_demo.py`.
- **Fixtures**: `tests/fixtures/ldtk_world/` (`make_world.py`, from the schema and the older
  fixture: world.ldtk, three levels in a Free world, every simple field type, enums, references,
  level fields, a table of contents; external.ldtk, two levels in .ldtkl files in a GridVania world;
  worlds.ldtk, LDtk's Multi-worlds: Overworld (Meadow, Hill: Free) and Underworld (Crypt:
  GridVania), the root's levels empty and its world settings null).
- Tests: ldtk_doc_test.odin: `ldtk_json_keeps_its_text` (every fixture, the demo and LDtk's own
  samples when `../ldtk` exists, untouched byte for byte; patches, inserts, removals, minified
  style, numbers, identifiers), `ldtk_fixtures_match_the_schema`, `ldtk_edits_write_valid_files`
  (every edit kind, its mirrors, refusals, each result schema-checked and read by the engine),
  `ldtk_external_levels_are_written_where_they_are` (nothing on disk until saved),
  `ldtk_edits_undo_and_redo` (in memory until Save, unsaved until undone to the saved text,
  byte-identical undo, a merged outside change, a conflict kept), `ldtk_unsaved_edits_and_outside_changes`
  (LDtk's save merged into unsaved edits, a clash waiting with Save refused, Keep My Edits then
  Save, Reload It, the stamp, the inspector's and a game's copies of the unsaved document, Save
  As's texts), `ldtk_opens_at_a_level`, `level_canvas_drags_levels_and_entities`;
  `tests/ui/ldtk_tab.script` (LDtk's bottom tabs, the Levels sidebar (select, focus, the world
  view, a level's menu), the Layers sidebar (a layer selected and the tools following it, the eye,
  a layer dragged by its row, undone), a layer's opacity and name, a refused name, undo / redo,
  an entity clicked on the canvas and its field, a level field, a level and an entity dragged, the
  document unsaved and the file unchanged until Save, a touched file merged with unsaved edits, a
  file written over unsaved edits and Keep My Edits, Play saving first, opened again; driver:
  `drag_level`, `drag_entity`, `click_entity`, checks `ldtk [<file>:]<path>` (the document as the
  editor has it), `ldtk_disk` (the file), `level entity|problem|conflict|outside|world|focus|
  tool|layer|layer_type|unsaved|disk_conflict|sidebars`, `send Level_World_Chosen <iid>`).

## Docs in the editor (implemented, `docs.odin`, `docs_window.odin`, `view_docs.odin`, `markdown.odin`)

TODO.md's Round 4 item 1 (asked 2026-10-24): the docs in a popup inside the editor, offline, with
"Open on crossfireengine.io" for the same page. The manual's page is `docs/manual/docs_window.md`.
- **Addresses are the website's paths** (`/manual/<slug>/#<anchor>`, `/api/<area>/#<name>`):
  links between pages, the history and "Open on crossfireengine.io" (`Docs_URL`) all use them, and
  `Docs_ResolveLink` takes what pages write (`#x`, `scene_changes.md#x`, `/api/...`,
  `https://crossfireengine.io/...`; other files of the repository go to GitHub, other sites to
  the browser through `Links_Open`). Anchors are Starlight's (`Markdown_Slug`: github-slugger),
  checked against the built site for the ones the lookups use.
- **Content:** the manual's Markdown files (`Docs_ManualDir`: this checkout's `docs/manual`, else
  `docs/manual` beside the executable, `Resources/docs/manual` in a macOS bundle; releases ship
  it: tools/ci/package_editor.sh, which the AppImage and the Windows installer take whole, and
  tools/macos/bundle.sh) and the API reference **made in the editor** from engine_docs.odin's
  parse (decided over shipping docgen's JSON: no build step, always the engine the editor builds
  with, and the release's `engine/` folder is already there), laid out like build-api.mjs: the
  same areas (`ENGINE_API_AREAS` now carries their titles and descriptions; the test compares all
  of it with api-groups.json), sections, `### Name` headings, inline code linked. Read once on
  first open (`Docs_Library`, the main thread; 69 pages, about 0.45 s in a debug build).
- **The node guides** are manual pages (`nodes.md` and `nodes_scene/graphics/animation/ui/physics/audio.md`),
  a `## <Kind>` section per node kind (anchor: the kind lower-cased) with its properties as the
  inspector names them, steps, code, an example that compiles (the website's check) and API
  links. `DOCS_NODE_GUIDES` maps every kind to its page; `docs_every_kind_has_a_page` fails when a
  kind (or an asset kind, a bottom tab, a place F1 knows) has no page or the anchor is missing.
  **A new node kind needs a section there and an entry in `DOCS_NODE_GUIDES`.**
- **Rendering** (`view_docs.odin`'s doc block): Skald's `rich_text_links` per paragraph, list
  item and table cell (spans from `MdSpan`: bold, italic, code in the code editor's Liberation
  Mono on a chip, links), headings sized by level, tables with columns sized to their text and
  shrunk to fit, code blocks tokenized by code_editor's `syntax` package and colored with its
  Ayu dark or light preset (by the editor's background), images from the manual's folder. **Long
  pages are virtualized:** every block is measured once per page, width, theme and font size
  (built without links, `skald.view_size`) and only the blocks within 200 px of the view are
  built, between spacers. The API's core page (879 blocks) measures in 117 ms optimized (634 ms
  debug), then frames stay at the display's rate. **An anchor scrolls only once the scroll has
  laid out the new page:** Skald clamps `scroll_y` to last frame's `content_h`, so the first
  frame of a new page clamped it to the old page's height (`docsPageView` waits for `content_h`
  to match `docsLayout.total`).
- **Found doing it:** `strings.replace_all` returns its input when there's nothing to replace,
  so the parser's blocks pointed into the file's freed buffer (code blocks lost their language);
  the parser copies its source into its arena first (a test parses from a freed buffer).
- **Ways in** (docs_window.odin's doc block): `.User_Manual` (Help > User Manual, F1 outside a
  code tab) by the panel under the pointer (`Docs_TrackPointer` from `view`, `Docs_HelpAddress`:
  the inspector and viewport the selected node's guide, a bottom tab its page, the browser its
  selection's); F1 in a code tab (`Code_Help_Requested` now carries an address); the code tab's
  **Open Docs** (`docsMenuItems` / `docsMenuPicked`, sent by `CodeProviders_TakeDocs`): an engine
  name (a node type to its guide), else `ScriptCode_TypeAt` (script_rename.odin: the type the
  code model shows for a field, parameter or local, `self.door` through the struct's field) to
  `Docs_TypeAddress`; **Open Docs** in the right-click menus (context_menus.odin); `Manual_Opened`
  (the panels' Manual buttons). A project's own node type (`^Door` declared
  `Door :: struct { using sprite: e.Sprite }`, or the name `Door` itself) goes to its base kind's
  guide through what it embeds (`ScriptIndex_Embeds`, `Docs_TypeAddress`'s `projectTypes`, a chain
  of them); a script's struct to the scripts page.
- **Looking at it:** Skald's offscreen renderer (`render_view_to_pixels`) is private, so the
  window was checked by making it public in the submodule's working tree for a scratch driver
  command (rendering `docsWindowContent` to a PNG), then putting it back: it reads back sRGB, so
  such pictures look lighter than the screen. A public snapshot API in Skald would make this a
  driver command.
- **Tests:** `docs_test.odin` (the parser, links, the library and the API's anchors for every
  declaration, every kind's page, symbols, search), `docs_window_navigates` and
  `docs_context_menus_open_docs` (editor_test.odin), `tests/ui/docs.script` (Help > User Manual,
  a link, back, forward, the website, an anchor, search and a result, Open Docs on a node and a
  scene tab, a Manual button, F1 and Open Docs in a code tab). Driver: checks `docs`,
  `docs_address`, `docs_address_has`, `docs_title`, `docs_at`, `docs_hits`; commands
  `docs_click_link`, `code_right_click`, `code_menu_pick`, `send Docs_Opened <address>`,
  `send Docs_Search_Changed <text>`. Widget keys: `docs-dialog`, `docs-back`, `docs-forward`,
  `docs-contents`, `docs-web`, `docs-close`, `docs-search`, `docs-scroll`, `docs-side-scroll`,
  `docs-entry-<i>`, `docs-hit-<i>`.

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
- **Open Docs** ends every menu with a page (`contextDocsAddress`): a node's kind's guide, empty
  viewport space, the scene tree, a browser row (a scene, an asset kind, a script), a scene,
  component or code tab, a log line, a bottom panel's graph (its tab's page); not the guides,
  the Align button, the toolbar's overflow or a log's categories.

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

## Design tokens (implemented, `ui_tokens.odin`)

TODO.md's "UI and UX" round 3 (2026-10-25): one set of sizes for every view, so spacing stays even
and everything scales together with Settings > Appearance's Text size, Spacing and Row height.
- **The tokens** (`uiTokens(ctx)` = `UiTokens_Of(ctx.theme, uiRowHeight)`; a view declares
  `tk := uiTokens(ctx)`): the spacing scale `hair` (1) / `xxs` (half of xs) / `xs` / `s` / `m` /
  `l` / `xl` (Skald's theme spacing: a 4 px grid at 100% Spacing, 3 / 6 / 9 / 12 / 18 at the
  default 75%); `panelPadding`, `sectionGap`, `rowGap`, `buttonGap`, `fieldPadding` /
  `buttonPadding` (dense fields and small buttons: s across, xxs down); `controlHeight`,
  `rowHeight` (the Row height setting: `view` sets `uiRowHeight`), `headerHeight`; `labelWidth`
  (the inspector's 82 px column) / `labelWidthWide` (Settings' and Project Settings' 170);
  field widths `fieldXXS` / `fieldXS` / `fieldS` / `fieldM` / `fieldL` / `fieldXL`; wrap widths
  `textNarrow` (sidebars, the inspector) / `textDialog` / `textMeasure` (Settings' help) /
  `textWide`; dialog widths `dialogS` / `dialogM` / `dialogL` / `dialogSettings` (Settings' and
  Project Settings' pages, one width) / `dialogWide`; icons `iconSmall` (panel header buttons),
  `iconMedium` (the toolbar, list rows, tabs), `iconLarge`; `toolButtonWidth`,
  `panelButtonWidth` (every small icon button), `squareButton`, `iconColumn`, `swatch`. Lengths in
  text units are measured at 13 px (`TOKENS_BASE_FONT`), so at the default look they're the sizes
  the views had (a few uneven ones were evened out: below).
- **Rules for new UI:** lay out with the tokens, never a pixel number in a layout call's
  `padding`, `spacing`, `width`, `height`, `max_width` or a `spacer`; a factor (`tk.m * 2`) is
  fine. `view_layout_uses_design_tokens` scans every source (strings and comments left out) and
  fails on a new one; its allow-list holds the exceptions with a reason (drawing math, canvases,
  images, the code editor's widgets, data that isn't layout). Alignment: label columns in a panel
  use one token (`labelWidth`; `labelWidthWide` in dialogs' forms); a group of buttons one gap
  (`buttonGap`); sections one gap (`uiSection`); small icon buttons one width
  (`panelButtonWidth`); panel headers are `panelHeader` (one height and padding).
- **Typography** (`Text_Role`, `uiText(th, role, str)`, `TextRole_Style`): `.Title` (dialog and
  docs window titles: lg), `.Panel_Title` (panel headers, tabs: sm), `.Section` (a section's
  header: sm, the main text, the section gap above it: `uiSection`), `.Label` (form labels: sm,
  muted), `.Value` (values, list items: sm), `.Muted` (help, captions, counts: xs, muted),
  `.Code` (the code editor's monospace, `uiMonoFont`). A status color (warning, danger) overrides
  a role's color, never its size. Sizes are Skald's theme sizes; no new fonts.
- **What the audit changed** (2026-10-25): about 500 layout numbers became tokens and 410 texts
  roles; Settings' and Project Settings' label columns (170 vs 120 px of main text) are one
  column of muted labels and the two dialogs one width; help text wraps at one measure (it was
  420, 440 or 560); section headers (fg xs in the inspector, sm in the panels, md in Settings)
  are one style and gap; small icon buttons (22 to 28 px) one width; color chips one size.
- Tests: `design_tokens_scale_with_the_look`, `view_layout_uses_design_tokens`.

## Focus, contrast and icons (implemented: Skald's focus, `editor_theme.odin`, `icons.odin`)

TODO.md's "UI and UX" round 3 (2026-10-25), with the tokens.
- **Focus** (Skald, `focus_visible`): Tab / Shift+Tab move the keyboard through the controls in
  build order; buttons, checks, toggles and selects draw the accent ring only after Tab moved
  focus (a press hides it: no ring on clicked buttons), text fields show focus either way.
  Dialogs trap Tab (Skald's modal rect), Escape is `on_dismiss`, and **Enter confirms**: Skald's
  `dialog(..., on_confirm)` sends it unless the focused widget in the card takes Enter (a
  button, check, select, list, picker, multi-line field, a field with `on_submit`); every
  editor dialog with a primary button passes it (`dialogConfirm(ok, msg)`: nothing while the
  button is disabled); Add Node keeps its own Enter, the LDtk conflict, Git discard and listener
  dialogs have none (no safe default), and neither have Settings and Project Settings (property
  sheets: Enter keeps a typed number, console.script and scene_flow.script type and press it). The
  trap counts only what the dialog drew (Skald: a widget behind the scrim under the card was a
  stop in a short window). The code editor gets Tab back from Skald
  (`CodeEditor_Frame`); canvases aren't focusable. Driver: checks `focused <key> | none`,
  `focus_visible <true|false>`. Tests: Skald's `focus_ring_shows_after_tab_and_hides_after_a_press`,
  `dialog_enter_confirms_unless_the_focus_takes_it`; `tests/ui/focus_keys.script`.
- **Contrast** (`CONTRAST_PAIRS`, `Contrast_Ratio`, `Contrast_Suggest`,
  `EditorTheme_ContrastProblems`): WCAG 2's ratio on Skald's linear colors; text needs 4.5:1
  (`CONTRAST_TEXT_MIN`): main and muted text on the window, panels and popups, text on the
  accent, warning and danger on panels and popups. Settings > Appearance lists each pair under
  it with its ratio and a suggestion (the text color mixed toward white or black until it
  reads), **Use it** (`settings-contrast-fix-<text>-<back>`) applies it. The presets were fixed
  to meet it (Midnight's accent, Graphite's danger, Paper's warning) and Skald's dark theme too
  (primary #2b6ee8, danger #f06a6e). Driver: `send Settings_Theme_Color_Changed <key> <#hex>`.
  Tests: `theme_presets_are_readable`; theme_editor.script.
- **Icons** (`ACTION_ICONS`, `Icon_Action`, `Action_Icon`): one icon per action, the table the
  single source: Add, Delete (the item goes: trash), Remove (out of a list: ×), Clear,
  Duplicate (ICON_CLONE; Copy is the clipboard's), Move Up / Down, Close, Back, Forward, Reset,
  Fit View (ICON_FIT: the viewport, Level canvas and slicer had three), Focus, Manual, Open
  Externally, Refresh, Randomize, Warning, More; the toolbar's buttons take `Action_Icon`.
  Sizes per context are tokens (`iconSmall` panel buttons, `iconMedium` toolbar, rows and tabs).
  Menus are text only. Test: `action_icons_are_the_single_source` (their glyphs used nowhere
  else).

## The editor's look (implemented, `editor_theme.odin`, Settings > Appearance)

- Colors are set over the base theme (Skald's Dark or Light) only where the user set one
  (`themeColorsSet`), so a set color survives a base change; `cornerRadius` scales Skald's radii.
- **Live:** the dialog returns `skald.cmd_set_theme` with the draft's theme for every Appearance
  change (`liveTheme`); Cancel returns the applied settings' theme. Row height isn't live (views
  read `settings.rowHeight`, not the draft).
- The picker has no alpha: a picked color keeps the opacity it had; Selection opacity sets it.
- Labels are "Window background" and "Main text" (tooltips are per label; Background and Text
  were taken).
- **The canvases' colors** (TODO.md's "UI and UX" round 2, 2026-10-25: Appearance's Viewport
  section): `ViewportColor` (the viewport's background around the game area, grid / major / axes,
  game frame, selection outline, gizmo X / Y / handles, guides; the Level canvas's background and
  grid), `Settings.viewportColors` / `viewportColorsSet`, keys in `[theme]` (`VIEWPORT_COLOR_KEYS`:
  `viewport_bg`...), in the presets (`ThemePreset.viewport`; `EditorTheme_PresetName` compares
  them). Not Skald's: the views read `ViewportColors(s, ctx.theme)`, **the draft while the dialog
  is open** (live without a theme command; Cancel drops the draft). Unset, `ViewportColor_Default`:
  view_viewport.odin's constants (`GRID_*_COLOR`, `GAME_FRAME_COLOR`, `GUIDE_COLOR`, `X_COLOR`,
  `Y_COLOR`, `VIEWPORT_BG_HEX`) or the theme color they always followed (selection outline: the
  accent; handles: the main text; Level canvas: window background and borders). The background
  around the game area is in the engine's render (`ViewportBg_Bytes`, in `Preview_FrameKey`).
- Driver: `send Settings_Theme_Preset_Chosen <name>`, `send Settings_Viewport_Color_Changed <key>
  <#RRGGBB>`; checks `live_theme <applied|draft>`, `theme_color <key> <#RRGGBB>` (canvas keys
  too). Tests: `editor_theme_settings`, `viewport_colors_in_the_theme`,
  `tests/ui/theme_editor.script`.
  User guide: `docs/manual/settings_and_toolchain.md#appearance`.

## Pointers (implemented: Skald's widgets, `Viewport_Cursor`, the canvases)

TODO.md's "UI and UX" round 1 (2026-10-25): the pointer says what a press does.
- **Skald's widgets set it** (Skald 475de93, 889ba99): a hand over buttons (so `panelButton`,
  `panelToolButton`, `toolButton`, `editorTab`, the mode bar), links, checkboxes, selects,
  `clickable`, trees, menus; an I-beam over text and number fields; resize arrows over every
  `skald.split` (all the editor's dividers are splits); not-allowed over disabled controls.
  `Cursor_Shape` has `Grab` / `Grabbing` (drawn by Skald: SDL has no hand cursors for them).
- **Ordering:** the last request in a frame wins, and the workspace is built last (inside
  `skald.sized`, during layout). Containers built after their children use
  `skald.cursor_request_soft` (`coloredTree`'s and `rowList`'s rows: a row's eye or rename field
  keeps its own); things built early but drawn on top use `skald.cursor_request_top` (popup and
  menu-bar menus, the viewport's drags, the asset / tree / code / layer row drags).
- **Canvases:** the viewport's `Viewport_Cursor` (view_viewport.odin: what a press would do,
  read before the input moves the state on: Move over a node and the move arrows, resize arrows
  over scale handles by axis or diagonal, Grab for the Pan tool or Space, Grabbing while panning,
  Crosshair for the Zoom tool, tile painting and rotating, resize arrows over guides and rulers,
  the arrow over empty space); the Level canvas (`levelCanvasView`: Move over levels in the world
  view and over entities, Pointer over another level, Grab over the focused level, Grabbing
  while panning, the paint tools' crosshair, `LevelHandle_Cursor` over the selected entity's
  handles via `LevelPaint_HandleHovered`); the slicer (Grab / Grabbing); the code view takes the
  code editor's (I-beam, scrub arrows).
- **Drags:** Move while a drop would be taken, Not_Allowed where it wouldn't (the asset drag's
  release cases, the scene tree's `valid` spot or a code tab, a code drag over the code).
- Driver: check `cursor <shape>` (Skald's `cursor_shown`: the last frame's), commands
  `hover_beside <key> <edge> [px]` (a split's divider beside its pane), `hover_node <name>`.
  Tests: Skald's `cursor_test.odin`; `tests/ui/pointers.script`.

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
- GPU particles are two particle settings (`gpu`, `gpuAmount`), so the Particles tab shows
  them with no editor change (its GPU category; the inspector's summary says CPU or GPU); a scene with a GPU emitter counts as using shaders
  (`Preview_SceneUsesShaders`, `Project_UsesShaders`): the viewport draws it with the GPU
  renderer, and Auto picks it in games.
- **They're in `Preview_FrameKey`** (a line's settings and points, and whether the scene needs
  the effects renderer): the viewport renders only when the key changes, and these change
  without a rebuild. lines.script failed (no white pixel after typing points; `render_path`
  stayed `shared` after a GPU emitter) whenever the test window didn't have the keyboard: its
  only redraws came from the AnimatedSprites' frames, which stop while the window isn't
  focused (`EditorFocused`); a scene without animations never redrew at all. Not a commit: it
  failed the same way built from 864be8a, the commit that added the script. Test:
  `line_edits_and_gpu_emitters_draw_the_viewport_again`.
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
  a limit side's value when it's on, or when it's off with a value (not 0) to keep, listed then in
  `limitsOff="Left,Top"` (the engine's parser takes those sides back out of `limits`), so a side
  turned off keeps its value in memory and in the file, and comes back with it when ticked.
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
  Number_Text_Changed's `CameraNumber` case). Renames are `.Scene` steps when the scene stores
  any node path (see "Node paths" below).
- **The Limits rows fit controlWidth:** checkbox and number in one row only when the number
  gets `NumberField_MinWidth` (a numberField is never drawn narrower: a 40 px box and two step
  buttons); in a narrower control the number goes under its checkbox (`stacked`; since the
  inspector stacks its rows under about 224 px, that's only with bigger fonts). camera.script
  checks at a 215 px sidebar (`send Right_Sidebar_Width`, `clear_of_scrollbar`).
- **Viewport:** the preview builds cameras without the settings (`toSceneData` leaves `camera`
  zero: no target, no limits), so the camera stays where it's placed and parallax shows the scene
  as placed; a selected camera draws its limits, dead zone, a line to its target and a ring where
  it aims (`drawCameraGuides`, view_viewport.odin).
- Tests: `camera_follow_settings_in_the_editor` (messages, clamps, undo, clone / equal, renames
  and moves keeping the path, saved and parsed by the engine), `project_round_trips_through_xml`
  (every setting), `tests/ui/camera.script` (driver check `cam <field>`). User guide:
  `docs/manual/camera_tools.md#following-a-target`.

## Node paths that follow renames and moves (implemented, `node_paths_edit.odin`)

Its doc comment has the rules; what the code relies on:
- **Every stored node path is a `NodePathKind`**: a Camera's `cameraTarget`, a CameraView's
  `viewCamera`, an IKChain's `ikTip` / `ikTarget`, a StateMachine's `stateMachine.target` (""
  is its parent: not a path), a SkinnedMesh's `mesh.bones`, an Animator's tracks (from its
  parent, as the engine reads them; event tracks have none), listeners' `target` (not a
  global's), and script node fields (`.Node` fields of the node's first script, node type and
  more scripts, from `State.scripts`: unknown until built). **A new kind of stored path needs a
  case in each of its procedures.** Joints name bodies, not paths (`Scene_RenameJointReferences`).
- `Scene_MoveNode` (with the catalog) and both renames (`Rename_Committed`, `Node_Renamed`) call
  `NodePaths_Resolve` before and `NodePaths_Repath` after. A path still leading to its node is
  kept as written; else it's rewritten from its owner, or from the top level when it started
  with `/`. A script field on its default gets a prop when the default no longer leads there.
  Paths that led nowhere are left alone.
- **Undo:** renames are `.Scene` steps when `Scene_HasNodePaths` (or a body named by joints);
  moves already are. Test: `node_paths_follow_renames_and_moves` (every kind, undo, a move, no
  catalog, a broken path); `camera_follow_settings_in_the_editor`.

## Camera tools (implemented, `camera_tools_edit.odin`; engine: camera_tools.odin)

- `NodeDef.cameraTools` is plain (`==`), `viewCamera` owned; zones' and views' sizes are
  `shapeSize` (the shape fields, labelled Room / View width and height; defaults 640 x 360 and
  160 x 90 in `NodeDef_Make`); a layer's image is `texture`. The viewport outlines zones and views;
  the engine draws layers and views (a view's camera as the scene starts it).
- Tests: `camera_tools_in_the_editor`, `tests/ui/camera_tools.script` (driver check
  `camtool <field>`). User guide: `docs/manual/camera_tools.md`.

## State machines (implemented, `state_machine_edit.odin`, `view_states.odin`; engine: state_machine.odin)

- **Transition logic and guards** (TODO.md's Round 4 item 1, asked 2026-10-24, done 2026-10-24;
  the engine's state_machine.odin has the model): conditions with `and` / `or` / `not` /
  parentheses and code guards (`name()`), a transition's `guard`, `priority`, exit time (`after`,
  `onFinished`) and `interrupts`, a state's exit guard (`canExit`), `speed`, `loop`, `onEnter` /
  `onExit` events. No crossfades: the engine has none (an AnimatedSprite shows one animation).
- **The sidebar** (`statesSidebar`): the selected state's or transition's properties; beside the
  graph when the panel is at least `STATES_SIDEBAR_SPLIT_WIDTH` (620) wide, else under it, its
  rows stacked (`inspectorStacked` set while it's built) under `STATES_STACK_WIDTH`. One scroll
  (`states-scroll`) holds the graph and the sidebar, so scripts reach every widget the same way
  in every window size. Rows are `inspectorRow`s (tooltips from `fieldTip`; labels unique to
  state machines: "State name", "Play speed", "Can exit when"...).
- **Conditions stay text** (the engine's format: backward compatible): the rows edit flat ones
  (all `and` or all `or`, no parentheses) through the engine's `StateMachine_SplitCondition` /
  `JoinCondition`; each `Clause_*` op splits, changes, joins (`States_EditClause`), so the text is
  what's stored and undone. Other conditions show as text only (the text field is always there).
- **Code guards** are read from the script index, not the catalog: calls of
  `StateMachine_RegisterGuard` (first argument) and `StateMachine_SetGuard` (second) with a string
  literal (`IndexCall`), so they're offered and checked (`e.StateMachine_ConditionProblem(...,
  guards, checkGuards = true)`) as soon as they're typed.
- **Live** (the engine's `machine <id>` command): `States_LiveFrame` (from `view`, while the
  States tab shows) works out the running node (`States_LiveTarget`: the Live tab's chosen
  StateMachine of that name, the same path in the playing scene, else one whose path ends like
  the machine's below its top node: a component's) and sends `States_Live_Watch` when it changes;
  `Live_Ingest` keeps the reply in `LiveView.machine` (`LiveMachine`: state, time, can exit, each
  clause's result, each transition's `e.StateMachineTransitionStatus`, parameters). Not undoable.
- Like the Timeline, the States tab shows the selected StateMachine and keeps it while other
  nodes are selected (`States_Follow` after every message); `SM_Changed` is a node step on the
  machine's index (a state drag sticky per `history.gesture`, bumped by `SM_View{.Drag_Begin}`;
  typing merges). `NodeDef_Make` gives a new machine an `idle` state.
- Renames follow: a state in transitions and the start; a parameter in conditions, whole words
  only (`renameWord`). Removing a state removes its transitions.
- The graph handles the mouse from last frame's rect (the canvas pattern); arrows run box edge to
  box edge, nudged sideways so both ways between two states show (`States_Arrow`). States'
  positions are graph pixels, saved as `x` / `y`.
- Tests: `state_machines_in_the_editor`, `state_machine_guards_in_the_editor` (clauses, any of,
  negation, guards from the index, priority, interrupts, a state's exit guard, speed, loop and
  events, undo, renames into guards, the round trip), `state_machines_live_in_the_editor`;
  `tests/ui/states.script`, `tests/ui/state_guards.script` (the sidebar: an exit guard, a
  condition's rows, a guard, priority, interrupts, undo, played: `states live_state`,
  `live_status`); driver `click_state`, `drag_state`, check `states <field>`. Checked by eye at
  640x660, 900x500 and 1280x720 (Skald's offscreen renderer made public for a scratch command,
  then put back). User guide: `docs/manual/state_machines.md`.

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
- **Collision shapes** (`shapes on|off`, `Live_SetShapes`, `live.shapes`): see Physics.
- **Edits** are sent as typed (`set`; the game refuses what doesn't parse, logged); typed text is
  kept in `live.edits` until another node is chosen, since the node's values come back every
  half second. Nothing is undoable or saved: it's the running game.
- **Code tabs** ask for a script's fields (`fields`, `Live_Watch`, `LiveView.fields` /
  `watches`) and read which scripts each node runs (`LiveNode.scripts`): see code_live.odin.
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
- **Sliders and check boxes** (format 14, no bump): a Slider's rows are Value, Min, Max, Step
  (`UIField.Step`, `u.step`, 0 and up), Show percent, Can't be used; a CheckBox's Text, Checked
  (`UIField.Checked`), Can't be used. Neither has an Image row (`UIKind_TakesImage`) nor writes
  `texture`; a Slider has no Font size row (as a ProgressBar) and writes no `text`. The writer
  writes `step` only for Sliders and `checked` only for CheckBoxes (the parser reads them only
  for those kinds). Their tooltips share the labels Value / Min / Max / Show percent with the
  ProgressBar's, so those texts fit both.
- **Labels** differ from other kinds' where the meaning differs ("Grid columns", "Gap", "Edge
  margin", "Can't be used", "UI theme"): tooltips are per label.
- Tests: `ui_controls_and_themes_in_the_editor` (a slider's and a check box's settings, undo,
  the built preview nodes, their written attributes, the round trip), `tests/ui/ui_controls.script`
  (a Slider's max, value and step, a CheckBox's text and Checked with undo; driver checks
  `ui <field>`: `value`, `min`, `max`, `step`, `checked` too; `themes`, `theme <field>`,
  `ui_theme`). User guide: `docs/manual/ui.md`.

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
  browser's audio preview with its volume, pitch and pan (`AudioPreview_SetSettings`), through its bus
  (`Mixer_RoutePreview`: see "Meters show the editor's own playback" below).
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

## Particles (implemented, `particles_edit.odin`, `view_particles.odin`, `view_inspector_particles.odin`; the engine's particles.odin)

- **Model:** `NodeDef.particles` is the engine's `e.ParticleSettings`, a plain value (no
  allocations), so cloning, equality (`==`) and the undo snapshot need nothing per field; the
  Texture shape's image is `NodeDef.texture`. Written by `SceneToXML` as `<particles>`.
- **The settings' rows** (`particleSettingRows`, view_inspector_particles.odin; the Particles
  tab's): one loop over `e.ParticleSettings_Fields()` (names, types, the `min`/`max`/`label`/`group`
  tags), so **a setting added in the engine shows up in the Particles tab with no editor change**
  (a new field type needs a case in `particleControl`; a new group is a new category and an
  inspector link). `ParticleRows` says which group ("" all, under their headings) and the widths
  (the ramp's wider); keys start `particles-tab` (`PARTICLE_KEYS`); `particleRow` is a labelled
  row (`inspectorLabelled`, its label's `tipLabel`). Ranged numbers are `valueSlider`s (reset goes to
  `e.DEFAULT_PARTICLE_SETTINGS`), rounded to about a thousandth of their range (`sliderStep`; a
  tenth of that with Shift) and written with `formatSliderValue`, so scene files get short
  numbers; `[2]f32` is two sliders, with the link button under the label (`State.particleLinks`,
  by field index; `ParticleSettings_SetAxis` applies `LinkedAxis`); colors are Skald's picker (no
  alpha) plus an alpha slider. The ramp hides the start/end colors when on, and vice versa.
- **The inspector** (decided 2026-10-25: "Shrink to a summary with the particles bottom tab"; it
  had every setting until then): `particleInspectorRows` is **Emits** (the `emitting` checkbox)
  and **Look** (the preset select, value always ""), the summary's rows of xs text
  (`Particles_Facts`: Cycle, Particles (a cycle's amount, the GPU's when on it, and a second's
  when continuous), Lives, Drawn as (the shape, the texture's file, the ramp), Runs on, and Alive
  from `Preview_EmitterAlive` when the viewport has it), **Edit in the Particles tab** (the row's
  width, `inspectorRowWidth`) and a `wrap_row` of a link per category but All. Both send
  `Particles_Tab_Opened` (the category, or -1 to keep the tab's: `Mode_ShowBottomTab`, so the
  Scene mode and the bottom panel open). Labels have `fieldTip`s of their own (Emitting, Shape,
  Preset were taken by trails, collision shapes and themes). Reset, the sliders and the ramp are
  the tab's only.
- **The Particles tab** (the Scene mode's bottom tab `.Particles`, after States; asked
  2026-10-24: "the particle categories in a left sidebar with vert tabs, the settings in the right
  content pane"): `ParticlesEditor.node` follows the selection when an emitter is selected
  (`Particles_Follow` after every message; `shown` false until one was, and after a project
  switch) and stays when another node is selected, like the Timeline and States tabs.
  **Messages edit `Particles_Target`**: the selected node when it's an emitter, else the tab's;
  since the inspector shows an emitter only while it's selected, and the tab then shows the same
  one, every particle message (`Particle_Field_Changed`, `Particle_Axis_Changed`, `Ramp_Edited`,
  `Particles_Reset`, `Particles_Preset_Applied`) needs no node of its own, and `History_Classify`
  makes it a `.Node` step on the target's index. Categories are the engine's groups then All
  (`Particles_Categories`; `PARTICLES_ALL`); the engine gained a `GPU` group for `gpu` /
  `gpuAmount` (they were the end of Emission). Layout (`Particles_TabLayout`): from
  `PARTICLES_TAB_NAMES_WIDTH` (560 px of panel) the categories with icons and names, from
  `PARTICLES_TAB_ICONS_WIDTH` (340) icons with their names in tooltips, narrower a choice
  (`particles-tab-select`) over the settings with the header inside the one scroll; rows stack
  their labels under `STACK_WIDTH` of content (`inspectorStacked` set while they're built).
  The header (`particlesHeader`, a `wrap_row`): the name and the viewport's live count
  (`Preview_EmitterAlive`; a GPU emitter says how many a cycle), **Restart**
  (`Particles_Restart` → `Preview_RestartEmitter`: `ParticleEmitter_Clear` + `Start` on the
  preview's node; not an edit), **Emitting** and **One-shot** toggles (`emitting`, `continuous`),
  **Preset** (a select whose value stays ""), Reset, Manual (`particles#the-particles-tab`, also
  F1's page: `DOCS_BOTTOM_TAB_PAGES`). Without an emitter: a hint and Add ParticleEmitter
  (`Add_Node_Kind_Chosen`).
- **Presets** (`PARTICLE_PRESETS`: Fire, Smoke, Sparks, Dust, Rain; few on purpose): each a proc
  from `DEFAULT_PARTICLE_SETTINGS` setting a whole look, every value inside its slider's range
  (`particle_presets_are_in_range`); applying keeps the emitter's `gpu` / `gpuAmount`, one undo
  step ("Apply the Fire preset to Sparks").
- **Color ramp editor** (`colorRampEditor`): a canvas (checkerboard, the gradient in 2 px slices,
  a marker per stop). Its mouse handling runs before it's built, from last frame's rect (like the
  scene tree's): a press near a marker grabs it, elsewhere on the bar adds a stop in the ramp's
  color there; while `State.rampDrag` is this bar's id (`Ramp_Drag_Changed(bar)`, 0 on release:
  by bar, from when the inspector had a bar too and both followed one drag), moving
  re-sorts the ramp and follows the stop (`e.ColorRamp_Sort` tracks it). `State.rampStop` is the
  selected stop.
- **Messages:** `Particle_Field_Changed` (a setting as text, `e.ParticleSettings_Set`),
  `Particle_Axis_Changed`, `Ramp_Edited` (the whole ramp as text plus the stop to select),
  `Particles_Reset` (also clears the texture), `Particles_Preset_Applied`. All `.Node` undo steps
  on `Particles_Target`, merged per setting; `Particle_Link_Toggled`, `Ramp_Stop_Selected`,
  `Ramp_Drag_Changed`, `Particles_Category_Picked`, `Particles_Tab_Opened`, `Particles_Restart`
  are view state.
- **Viewport:** emitters make the preview animated; `syncTransforms` copies their settings every
  frame (so a slider drag shows at once without losing the particles), stops an emitter whose
  Emitting is off, and replays a one-shot one once its particles are gone.
- Tests: `particle_emitter_round_trip`, `particle_inspector_edits` (the messages),
  `viewport_shows_particles` (pixels from `Preview_Render`), particles_edit_test.odin
  (`particles_inspector_summary_opens_the_tab`: the facts, their tooltips, `Particles_Tab_Opened`
  from either mode; `particle_categories_come_from_the_engines_groups`,
  `particles_tab_follows_edits_and_undoes`: follow, edits on the tab's emitter with another node
  selected, the ramp, a preset, undo / redo, Reset; `particle_presets_are_in_range`,
  `particles_tab_rows_fit_their_column` at 200 to 760 px), `tests/ui/particles.script` (the
  inspector's Emitting, preset, button and links clear of its scrollbar, the links opening the
  tab at their category; in the tab real slider drags, the link button, ramp clicks and drags,
  alpha, typing a value, Shift drags, Reset, the shape dropdown, undo) and `tests/ui/particles_tab.script` (Edit in the Particles tab, the
  tab keeping the emitter, a slider, One-shot, a category by tab or choice, the ramp's bar, a
  preset, undo / redo, Restart, Reset, the Manual). The driver's `click_at` / `drag_widget
  [shift]` press at fractions of a widget, `click_overlay_item` clicks a popup's choice (a
  dropdown's), `scroll_by` scrolls, `send Particles_Category_Picked <i>` /
  `Particles_Preset_Applied <name>`; checks `particle`, `particle_near`, `particle_linked`,
  `ramp_stops`, `ramp_stop`, `particles_tab <node | category | ramp_stops | setting>`,
  `bottom_tab`. Checked by eye at 640x660, 900x500 and 1280x720 (Skald's offscreen renderer made
  public for a scratch command, then put back). User guide: `docs/manual/particles.md`.

## The demo project (`examples/demo_project`, `tools/demo/`)

"Legacy of the Wardens" (2026-10-23; it replaced the Asteroids demo and its forest level): a
platformer that shows as much of the engine as one game can. Its README says what each part
demonstrates and where; what the code here relies on:
- **What's in it:** a title screen of UI controls (parallax, particles, lighting, an Animator),
  Options and Credits pushed over it, a loading scene, three LDtk levels (one `.ldtk` file,
  three scenes: ForestScene, HollowScene, LairScene), a pause menu, game over and victory scenes,
  27 scripts (`scripts/`: GameState is the one global), 21 components, three animation sets, one
  dialogue, four themes. Format 14, saved by the editor's writer: load + `Project_Save` leaves
  every file as it is (`shipped_demo_saves_unchanged`; after a hand edit, `DEMO_RESAVE=1` on
  that test writes the writer's version back into the demo).
- **Assets:** the art is cut from the workspace's `Legacy-Fantasy/` pack by `make_demo.py` (and
  `hero.lua`, with Aseprite); the sound effects are files of the workspace's GameSounds pack
  (GameBurp), copied under the demo's names by `pick_sounds.py` (its table says which file is
  which effect; each creature has its own cries: `Enemy.hurtSound` / `defeatSound`). Both packs
  ship with their owners' permission (the user's decision, 2026-10-23; the user updates the
  license text). `make_sounds.py` synthesizes the music and the bees' buzz (the pack has
  neither); `--all-sfx` also writes its older synthesized effects.
  The fonts are SIL OFL (Pixelify Sans, Jacquarda Bastarda 9; their licenses beside them).
  About 5 MB; keep it small (releases ship it): the `.ldtk` is compact JSON, music is OGG
  quality 1, and the LDtk levels have no tree layers (the scenes' ParallaxLayers draw the forest).
- **The levels** are generated from layouts in `make_demo.py` (fills and entity lists, with the
  hero's reach in mind: steps up at most 4 cells, gaps at most 6); after a change, run the
  playtest. The Ground layer's values: 1 grass, 3 stone (solid; one IntGrid group for the rules),
  2 planks (one-way), 4 water (an Area named Water).
- **The playtest** (`tools/demo/playtest`, `task demo:playtest`, about 10 minutes: the software
  renderer draws one frame in ten): the engine's player set up on an offscreen window
  (`Player_Setup`, `renderer = "software"`), frames stepped at 1/60 s with SDL key events, checks
  printed, frames saved as PNG from the renderer. A bot runs each level (jumps at walls, gaps and
  water, rides platforms, climbs planks; where it's stuck 6 s it's moved on and the place
  reported). Saves go to "Legacy Playtest". Run it after changing the demo or the engine.
  `PLAYTEST_RENDERER=gpu` plays it on the GPU renderer (the hit flash's shader runs; it
  works with SDL's offscreen video driver here).
- **Exports checked** (2026-10-23): Linux x86_64 single file (14 MB, needing only libc), run
  from another folder; Web (8.6 MB) in headless Chromium: the title draws, a synthetic Enter
  starts a new game (saved to localStorage), the forest draws. That run found the engine's web
  heap bug (every web export stopped before its first scene).
- **Tests:** `shipped_demo_copies_with_its_level` (each level scene, its components, the files an
  export takes), `shipped_demo_saves_unchanged`; the outline demo (`Project_CreateDemo`) has `built_in_demo_outline_saves_and_loads`;
  the unit tests' own sample project is `Project_CreateTestProject` (test_project_test.odin).
- **Engine changes it led to** (2026-10-23): Slider and CheckBox controls, `Game_PlaySound` on a
  bus with volume, pitch and pan, RichText alignment, scroll boxes hiding a row's controls and
  scrolling to the keys' focus, pushed scenes starting fresh and ignoring the press that opened
  them, `CreateLabel` copying its font path, the project icon read from the project's folder, Escape quitting only games
  whose actions don't use it, web exports' heap memory through Emscripten's malloc.

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
- Unimplemented targets fail with `Export_NotImplementedReason`. A desktop target exports on its
  own OS, or anywhere from its prebuilt player beside the editor for a project without scripts
  (`Export_Implemented`; releases carry Linux x86_64, Windows x86_64 and macOS arm64 players). Web
  exports everywhere; Steam and consoles don't yet.

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

**Built since it was planned:** CI and releases on GitHub Actions ("CI and releases"), Windows
and macOS exports (above), SDL3_mixer built by the automatic Emscripten install.

**Future work (decided, not built):**
- The remaining targets: Linux ARM64, Windows ARM64 and macOS x86_64 players on CI (runners per
  architecture; today they export only on their own machine, untested); a macOS game's Developer
  ID signature and notarization; Steam (Steamworks SDK, depots via `steamcmd`; Steam Deck = the
  Linux build); consoles (licensed SDKs).
- Other image formats on the web: build SDL3_image for Emscripten like SDL3_mixer (it needs
  libpng/libjpeg ports, which Emscripten has).

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
  `tools/macos/gon.json.example`, `entitlements.plist`). (The app icon is done: see Branding.)
- OLS is pinned in code_editor (`OLS_REF`): `c96dea91` is the newest that builds with Odin
  dev-2026-10 (newer OLS needs `core:odin/tool-format`). UI test tasks build it (`ols`):
  toolchain.script expects a language server.

## CI and releases (`.github/workflows/build.yml`)

**The website and downloads** (2026-10-22): after `release`, the `downloads` job uploads the
release's files to Cloudflare R2 (bucket `crossfire-downloads`, served at
downloads.crossfireengine.io: `releases/<tag>/<file>` and `latest.json`) with the repository's
`R2_*` / `CLOUDFLARE_ACCOUNT_ID` secrets. Then the `website` job (`needs: downloads`, tags only)
calls the website's own workflow, `bcrowe306/crossfire-astro/.github/workflows/deploy.yml@main`,
with `secrets: inherit` (it deploys with this repository's `CLOUDFLARE_*` secrets), so a release
deploys the site at once, no token needed; the site's hourly check is the fallback. The website
(crossfireengine.io) publishes this repo's `docs/manual/` at the release's tag: keep the manual's
frontmatter and relative links as they are (see "Documentation"). After a tag, watch the build,
then the `website` job, then the live site. Issue templates: `.github/ISSUE_TEMPLATE/`.

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
  about 17 MB). Each build job's archive has its own platform's player; the `combine` jobs then
  add the others' (above). Projects with scripts need Odin (Settings > Toolchain installs it) and a linker.

## Documentation (required)

All public code in this repo and the engine has **Odin-style doc comments**, and users read the
docs on the website, [crossfireengine.io](https://crossfireengine.io) (below).

**Every change updates its docs, in the same commit or the one beside it:** the manual
(`docs/manual/`: a page per feature; a new feature gets a page), the doc comments, both repos'
CLAUDE.md (this file's status block, code map and sections), the READMEs, and the website's own
pages (`../crossfire_astro/src/content/docs/getting-started/`, `examples/`, the hand-built pages)
when what they say changed. A change isn't done until they agree with it. **After pushing or
tagging, watch the website deploy** (crossfire-astro's Deploy workflow: after a release tag, the
editor's `website` job calls it; then crossfireengine.io itself, fetched with a cache-busting
query) and fix it if it fails.

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

### Publishing: the website

The website, crossfireengine.io (Astro + Starlight; the workspace's `../crossfire_astro`,
bcrowe306/crossfire-astro; its CLAUDE.md and README have the details), publishes:
- **The manual:** this repo's `docs/manual/` at the newest editor release's tag (the docs window
  shows the same files, bundled: "Docs in the editor"; keep its anchors, the editor links to
  them)
  (`scripts/sync-manual.mjs` copies it into `src/content/docs/manual/`, generated and gitignored
  there). Keep its pages as the site needs them: frontmatter `title` / `description` (quoted when
  they hold `: `) / `order`, plain relative links, no GitHub-only syntax, examples that compile.
- **The engine's API reference:** the engine's doc comments at its newest tag
  (`scripts/build-api.mjs` with the site's `tools/docgen`; every engine file needs an area in
  `scripts/api-groups.json`). The editor's own doc comments aren't published; `odin doc .`
  reads them.
- **Every Odin example on the site is type-checked** (`npm run docs && node
  scripts/check-examples.mjs`, run by the site's CI before deploying): the manual's blocks, the
  engine's `Example:` blocks, the plugin API's (against `plugin_api/`). ```odin nocheck skips a
  block; a `// Given: name: Type` first line declares what a snippet uses.
- **When it updates:** the editor's release workflow deploys it after each release (its `website`
  job calls crossfire-astro's `deploy.yml` with `secrets: inherit`), and it checks hourly for a
  release the live site doesn't describe. So doc fixes here reach the site with the next release
  tag. Its Download page reads the release files on downloads.crossfireengine.io (R2).

The old GitHub Pages plan (Odin's pkg.odin-lang.org generator and a `docs.yml` here) was dropped:
there is no Pages site for the editor.

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
- **Paths are compared resolved** (`absolutePath`, play.odin: links followed, a file that doesn't
  exist yet through its folder; `Paths_Same`): the project's root is resolved when a project
  loads, is created or is saved elsewhere, the script index keys its files that way, code tabs
  keep resolved paths and `ScriptIndex_File` / `CodeEditor_Find` resolve what they're given. On
  macOS the temporary folder /var is a link to /private/var, and paths spelled both ways broke
  the live values' tests on CI (v0.1.0-dev.61 and .62); tests make their folders under
  `testTempBase()` (resolved), and `code_paths_through_a_link` opens a project through a link.
- **Timing tests assert on the best of `TIMING_RUNS`** (editor_test.odin) with generous limits:
  one run under load (other tests' threads, a UI suite beside them, CI's Mac) took several times
  as long (`names_demo_project_timing`, `engine_docs_read_render_and_link`). The numbers in this
  file are the logged best times.
- **Unit tests step the State through a pointer** (`send :: proc(state: ^State, m: Msg)`), not
  `state, _ = update(state, m)` at every step: each such call keeps a copy of the State (35 KB)
  in the test's frame in debug builds, and a test thread's stack on Windows is 1 MB (8 MB on
  Linux). `ldtk_edits_undo_and_redo` had a 458 KB frame and, under update, History_Commit and
  History_Push (whose UndoCommand copies were 25 KB each: now pointers), overflowed it on
  Windows CI (v0.1.0-dev.66, "Signal caught: Unknown"). Check a frame with `objdump -d` of
  the test binary (`odin build . -build-mode:test -debug`) and `sub $N,%rsp`.
- **`update` keeps one State** (2026-10-24): `applyMsg` and `handleAction` change it through a
  pointer (`applyMsg(&out, m) -> Command`), `update` remembers what it compares in a small
  `Update_Before`, and the history's big values live on the heap: `History_Snapshot` returns an
  `^EditSnapshot` that `History_Commit` frees, the command is built on the heap and pushed by
  pointer, and `ProjectChange` holds `^ProjectSnapshot`s (12 KB each), so an `UndoCommand` is
  about 5 KB, not 25. Debug frames before / after: `History_Commit` 250 / 30 KB, `applyMsg`
  151 / 40 KB, `update` 139 / 37 KB, `History_Snapshot` 59 / 3.5 KB, `History_Push` 26 / 0.7 KB;
  the tests that still stepped by value (code_colors, log_points, code_live, two in
  editor_test) use `send` now (`code_color_swatches_in_a_code_tab` 449 / 91 KB). Debug builds
  give every local of every `switch` case its own slot, so a big value in one case costs the
  whole procedure: keep them behind pointers in procedures on `update`'s path.
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
  - the mode bar's tabs `mode-tab-<Name>` (`mode-tab-Level`); the Level mode's (level_mode.odin's
    doc block): its tools on the toolbar `level-tool-<Tool>` (overflow `toolbar-more`), the Levels
    sidebar's `level-list`, `level-row-<i>`, `level-new`, `level-file`, `level-world`,
    `level-import`, the Layers sidebar's `level-layers`, `level-layer-row-<i>` / `-eye-<i>`, the palette's `level-value-<v>`,
    `level-palette-tiles` / `-random` / `-flip-x` / `-flip-y` / `-stacking`,
    `level-entity-type-<uid>`, the canvas `ldtk-map-Level` and its header's
    `panel-level-fit` / `-world-view` / `-focus` / `-open-ldtk`, the disk bar's `ldtk-disk-reload` /
    `-keep`, its bottom strip `level-bottom-tabs` (far tabs: `send Bottom_Tab <Tab>`), the tabs'
    (view_ldtk_tab.odin's doc block: `ldtk-tab-scroll`, `level-new-scene`, `level-open-scene-<i>`,
    `ldtk-layer-name`...; the lists `ldtk-list-<Tab>`, rows `ldtk-list-<Tab>-<i>`, a narrow panel's
    dropdown `ldtk-item-<Tab>`), the conflict dialog's `ldtk-conflict-overwrite` / `-keep` / `-cancel`
    (driver checks `mode`, `level <file | level | tab | levels | shown_in | entity | problem |
    conflict | outside | world | focus | tool | layer | layer_type | unsaved | disk_conflict |
    sidebars | value | tiles | random | flip | grid | single_layer | stacking | auto_layers |
    stroke | pick | entity_type>`, `ldtk`, `ldtk_disk`, `ldtk_cell`, `ldtk_tiles`, `ldtk_count`,
    `level_entities`; commands `level_paint`, `level_drag_world`, `level_palette_tiles`;
    tests/ui/modes.script, ldtk_tab.script, level_paint.script); the definitions editors'
    (view_ldtk_defs.odin's doc block: `ldtk-layers-add-<Type>`, `ldtk-<kind>-<member>`,
    `ldtk-picker-<what>`...; tests/ui/ldtk_defs.script); the Auto-layer Rules tab's
    (view_ldtk_rules.odin's doc block: `ldtk-rules-add-group`, `ldtk-group-<part>-<uid>`,
    `ldtk-rule-<part>-<uid>`, the editor's `ldtk-rule-pattern`, `ldtk-rule-tiles`,
    `ldtk-rule-<member>`, the Assistant's `ldtk-assistant-*`...; driver `send Rules_View`,
    `hover_at`, `drag_to`, `level_hover`, check `rules`; tests/ui/ldtk_rules.script); the World,
    Level and Project tabs' (view_ldtk_project.odin's doc block: `ldtk-world-*`, `ldtk-level-*`,
    `ldtk-project-<key>`; driver `level_world_click`, check `level selection | spot | depth`;
    tests/ui/levels.script)
  - the sprite sheet slicer's tab (slicer_edit.odin's doc block: `slicer-tab-<i>`, `slicer-canvas`,
    `slicer-scroll`, `slicer-<SlicerNumber>`, `slicer-add`, `slicer-create`, `slicer-apply`...),
    the browser preview's `browser-slice`, the Animation panel's `animation-slice` (driver:
    `click_cell <n> [shift|ctrl]`, `click_slicer_frame <n>`, check `slicer <field>`;
    tests/ui/slicer.script)
  - toolbar buttons `toolbar-<name>` (`toolbar-physics-debug`: the game's collision shapes,
    `toolbar-restart`, `toolbar-more`: the overflow in a narrow window, drawn instead of the tools),
    panel buttons `panel-<name>`
  - the docs window: `docs-dialog`, `docs-search`, `docs-hit-<i>`, `docs-back`, `docs-web`...
    ("Docs in the editor")
  - the Console and Output tabs: `console-scroll` / `output-scroll` (the list; `-area` the list or
    its placeholder), `-line-<i>`, `-link-<i>` (a located line's text), `-search`,
    `-level-<Level>`, `-categories`, `-follow`
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
  - ParticleEmitter inspector: `inspector-particles-emitting-<node>`,
    `inspector-particles-preset-<node>`, `inspector-particles-edit-<node>`,
    `inspector-particles-cat-<Category>-<node>`. The Particles tab's settings:
    `particles-tab-particle-<setting>-<node>` (`-x` / `-y` for pairs, `-alpha` for colors),
    `particles-tab-particle-link-<setting>`, `particles-tab-ramp-<node>` and its `-add-`,
    `-remove-`, `-position-`, `-color-`, `-alpha-` controls, `particles-tab-texture-<node>`; its
    own `particles-tab-cat-<Category>`, `-select`, `-scroll`, `-restart`, `-emitting`,
    `-one-shot`, `-preset`, `-reset`, `-manual`, `-add` (view_particles.odin's doc block)
- **UI tests run on `tests/fixtures/ui_project`**, not `examples/demo_project`: the demo is what
  `task run` opens, so it changes when you use the editor. Update the fixture on purpose when a
  test needs different content.
- **Don't assert timing-dependent results** (undo merging) in UI scripts: several editors share
  the CPU in a headless run, and a visible window the compositor hides is throttled. Unit tests
  cover timing with fake clocks.
- **Rows must be in view.** `click_row`, `right_click_row` and `drag_row` fail on a row scrolled
  out of the tree's visible area. The scene tree pane is short; collapse nodes to keep rows in view.
- **Tree rows** are clicked by row index using `TREE_ROW_HEIGHT`; keep trees on that row height.
- **Never read the screen.** The driver checks editor state, never pixels, and nothing here may
  screenshot the desktop: the user's other windows can be on screen. To check rendering, call
  `Preview_Render` from a scratch test and save its pixels. Skald's own off-screen renderer is
  private to Skald, so snapshots of the UI would need a public Skald API first.
- **How the runs work** (`tools/ui_tests.sh`, from the `test:ui` tasks): each script runs in its
  own editor on a fresh copy of `tests/fixtures/ui_project` and of `tests/ui/settings.ini` in
  `build/ui_tests/<run>/<script>/` (`<run>`: `tiled`, `fullscreen`, `visible`), because scripts
  save, rename, play and import; `JOBS` of them at once (default half the CPUs), longest first
  (the last run's `times.txt`). It prints each script's result and time as it ends, then the
  slowest and a summary (wall time, the scripts' total), and exits 1 if one failed; a failing
  script keeps its folder and `log.txt` (passing ones keep only the log). One run per `<run>`
  folder at a time (`.lock`).
  - **Headless** (`test:ui`, `test:ui:fullscreen`): `SDL_VIDEO_DRIVER=offscreen` (Vulkan through
    `VK_EXT_headless_surface`, on the GPU: Skald, the shared GPU renderer and the code editor
    all work) and `SDL_AUDIO_DRIVER=dummy`, with `--window-size` 640x660 or 1280x720. No window
    appears, nothing resizes or throttles it, a game started by Play inherits both (no game
    window either), and the clipboard is SDL's own (the user's isn't touched). The window
    never moves, so the driver skips `WINDOW_SETTLE_TIME` there.
  - **Visible** (`test:ui:visible`): real windows, one at a time (they share the desktop and the
    clipboard). For watching a script; a tiling window manager squeezes the window, and other
    windows (yours, or a game from Play) shrink it further and can make scripts fail.
  - **Nothing is shared between workers:** each has its own project folder, settings and
    recent-projects file; Play's players (`build/players/<project>-<hash>`), export work
    (`build/exports/...`), plugin builds and shader and font scratch (`build/shaders/<...>`,
    `build/fonts/<...>`: `projectBuildFolder`) are per project folder; OLS is a process per
    editor; git repositories are inside each project. **Scripts never name `build/ui_project`:**
    `{project}` is the project the script started on (`open_project {project}`,
    `{project}_archive/...` for files beside it).
  - Measured (2026-10-23, 8 CPUs, Intel UHD 620, 62 scripts): before, one visible window at a
    time: 808 s tiled (11 scripts failed: other windows squeezed it to 621x329), 484 s
    fullscreen. Headless with 4 workers: 144 s tiled, 150 s fullscreen, no failures; 6 workers
    134 s, 8 workers 129 s (CPU-bound: the default stays at half the CPUs). Both suites at once:
    about 262 s each, no failures. The slowest is `scripts.script` (about 70 s: a player built
    on each save), then code_keys, globals_data, ldtk, hot_reload.
- Add a script, or extend one, for each new interactive feature.
- The driver waits until the window size has been stable for `WINDOW_SETTLE_TIME` (1.5 s) before
  the first command: a tiling window manager resizes a new window after it opens, sometimes more
  than 0.5 s later, and a click aimed at the old layout misses (the first script of a run failed).
  Not on the offscreen driver (headless runs), where the size never changes.
- **Drops onto a code tab say where** (`drag_row_to <tree> <row> code-editor at_text <text>` /
  `at_line <n> [<column>]`, `drag_asset_to ... code-editor at_text ...`, `drag_widget_to
  <widget> code-editor ...` from a label or grip, a trailing `shift` for the menu; the line and
  column scrolled into view first, `CodeEditor_RevealLine` / `CodeEditor_FindText`; the point a
  quarter into the cell, so it's the position before it whichever way the code editor rounds): the drop providers decide by
  where it lands, and the view's middle is another line in another window size (macOS CI's
  installed-app run, v0.1.0-dev.56, dropped outside the struct). Checked at 640x660, 900x500
  and 1280x720.
- `action <Action>` sends an action, for menu-bar entries without a shortcut.
- **Short windows** (`task test:ui:short`, 900x500; checked 2026-10-23): the panels keep their
  minimums (`FittedBottomHeight`, `FittedSceneTreeHeight`: the inspector keeps
  `MIN_INSPECTOR_HEIGHT`; `FittedPreviewHeight`: the browser's preview takes at most half its
  column), dialogs fit the window's height (Settings, Project Settings, Add Node), and the
  Aseprite preview's buttons sit outside its scroll. The viewport is then about 330x130: scripts
  that click nodes collapse the bottom panel first (`action Toggle_Bottom_Panel`), and
  `click_node` / `drag_node` / `right_click_node` fail when the node is outside the view rather
  than clicking whatever is there. Scroll trees and previews into view (`scroll_by`,
  `scroll_into_view`) rather than counting on a row being shown.
- **Layouts that depend on the window** (the toolbar's overflow): `if_drawn <key> <command>` runs
  a command only when the widget was drawn, so one script passes tiled and fullscreen;
  `in_window <key>` checks nothing was pushed off the window's edge.
- **UI tests never start a real code editor:** `tests/ui/settings.ini` (copied to the scratch
  settings file) sets `code_editor_path = true`. Unit tests that create scripts set it too.
- `scripts.script` really builds a project player (a few seconds unoptimized, longer when the engine
  changed) and plays it.
- `scroll_into_view <scroll> <widget>` pages a scroll container until the widget is visible
  (inside the scroll's clip). Rows outside it are laid out but not drawn (Skald's culling); the
  driver's `visible` means laid out last frame (`widget_drawn_last_frame`, culled rows included)
  and inside its clip and the window. A `wait_until` that passes lets a few frames settle before
  the next command. `top` puts the widget at the view's top, so what's under it is in view too (a
  drag's target: ldtk_rules.script's rule dragged onto the next group, in a short window); a
  widget drawn outside the scroll (a bottom tab's toolbar row) passes as it is.
- A game window (Play) makes a tiling window manager shrink the editor's window, which moves every
  rect (visible runs; headless games have no window): stop the game before clicking things that
  may move.
- **Modifier clicks:** Skald reads Ctrl/Shift from key events, not mouse events, so the driver
  holds the modifier key around the click (`click_row ... ctrl`, `click_node ... shift`).
- **A script's `ctrl` is the platform's command key** (`PRIMARY_KEYMOD`: Cmd on macOS, as the
  keymap's Ctrl is there), so the same scripts pass on a Mac; `control` presses the Control key
  itself.
- A context menu fades out after closing and blocks clicks under it meanwhile; the driver waits
  for that (`FADING_MENUS`) before the next command.

## Profiling (Spall: `profiling.odin`, `tools/profile.sh`, `tests/profile/`)

TODO.md's "Performance" work (asked 2026-10-24): every speed-up is measured before and after.
- **The trace:** built with `-define:SPALL=true`, Skald, the engine and the editor record spans
  into one `.spall` file (https://gravitymoth.com/spall/), each thread in its own buffer. Skald
  owns it (its `prof.odin`; its frame loop's spans `frame`, `view`, `render_view`,
  `render_overlays`, `frame_begin`, `frame_end`, `update`, `events`, `idle`, `pace`; text's
  `measure_text`, `draw_text`, `wrap_text`), `Profiling_Start` hands it to the engine
  (`e.Trace_Share`: its `Preview_Render` → `scene_draw` → `draw_order`, `nodes_draw`, `lighting`
  nest under the editor's spans), and the editor adds each message `update` handles
  (`Profiling_Message`: its type, an Action's name) and the panels' views (`browserView`,
  `inspectorView`, `viewportView`, `bottomPanelView`, `CodeEditor_View`, `levelModeView`...).
  Without the define all of it compiles to nothing. `-define:SPALL_AUTO=true` records every
  procedure (Skald defines the instrumentation hooks): for finding what no span names, far
  slower. `SPALL_TRACE` names the file. **`Profiling_Stop` runs after `skald.run`, before
  `os.exit`** (the script driver's exit code): `os.exit` runs no defers, and the buffers would be
  lost.
- **The harness** (`task profile`, `tools/profile.sh`): each scenario is a driver script in
  `tests/profile/` that sets up (a scene, a selection, a code tab), then `profile_mark start`,
  the work (`repeat 80 scroll_by inspector-scroll 30 ; wait 1`), `profile_mark end`, `quit`. Each
  run: a fresh copy of the project **as committed** (`git archive HEAD examples/demo_project`, or
  the UI fixture with `# project: fixture`), the UI tests' settings file, its own XDG_DATA_HOME,
  SDL's offscreen video driver and dummy audio (no window, no focus taken, no input from the
  desktop, never resized), every frame drawn uncapped (`SKALD_BENCH_FRAMES`,
  `SKALD_BENCH_UNCAP`), pinned CPUs (`--cpus`, default 2-5), a window of `--size` (1680x1000; a
  script's `# window:` line wins). The report (the engine's `tools/spall_report -from=start
  -to=end`) pools every run's frames and spans; the median run's trace is kept for the viewer.
  **Judge by the mean and by time per call:** the viewport renders on a timer (30 fps for
  animations), so frames with and without a scene render alternate and the median jumps
  between the two kinds; a span driven by that timer (`Preview_Render`, `lighting`) changes
  per frame when frames get faster or slower, so compare its time per call (`compare` prints
  both).
- **Compare interleaved, on a quiet machine:** `task profile:baseline` keeps the build too
  (`build/profile/baseline/crossfire-editor`), and `task profile:compare` runs it and the new
  build in turns, in **ABBA order** (baseline first in odd runs, the new build first in even
  ones: `--runs` 4 by default). Without a kept build it falls back to the kept results and says
  so. What was found measuring the harness itself (2026-10-24, one build compared with itself):
  - results taken an hour apart differed by 60-90% per call in code neither build changed;
  - with the baseline always first, the second run of each pair came out 3-11% faster (warm
    file and shader caches, clocks already up): hence ABBA;
  - with another program compiling (a load of 15-25 on 8 CPUs) runs varied by 10% even on the
    CPU clock (`--clock cpu`, `SPALL_CLOCK=cpu`: each thread's CPU time), which leaves out time
    the thread was descheduled but not a hyperthread or cache shared with that work. So each
    run first waits (`--wait-quiet`, up to 300 s) for the machine's CPU use to drop under
    `--quiet-busy` (20%), and says when it gave up waiting. A change smaller than about 10% is
    only believable from a quiet machine.
  - **The verdict is the median pair:** each ABBA pair gives this build's mean frame over the
    baseline's; the median of those ratios gates (`Pairs ...; median 0.979`), since one disturbed
    run in a pooled mean moved a scenario by 16% (pairs 0.69, 2.14, 0.98, 1.08: no change). The
    pooled comparison still prints where time moved.
- **SPALL_AUTO inflates small procedures:** every call pays the hooks, so a tiny procedure called
  thousands of times a frame looks expensive (the map hashers looked like the next target; a
  microbenchmark put a different key at 2-4% of 31 ns a lookup, about 3 us a frame, so that
  change was dropped). Use SPALL_AUTO to find where time goes, then confirm a candidate in a
  normal SPALL build or a microbenchmark before changing it. It warns when the load average is
  over a quarter of the CPUs: other work on the machine moves the numbers.
- **Reading results:** `build/profile/results/<scenario>.txt` (frames: median, mean, p95, p99,
  max of a frame's work, and start to start; spans by self time per frame), `.json` (what
  `compare` reads), `.spall` (open in Spall's viewer). `task profile:baseline` keeps them,
  `task profile:compare` fails past the threshold.
- **The engine's games:** its `tools/profile_game.sh <project> [scene...]` (its CLAUDE.md,
  "Profiling with Spall") plays scenes headless in a Spall build of the player.

## Verifying work

- `task verify` (check + tests) must pass before saying anything works. The vet flags are limited to
  this package (`-vet-packages:crossfire_editor`) because Skald itself has unused imports.
- `task test` fails a test that leaks or frees badly (`ODIN_TEST_FAIL_ON_BAD_MEMORY`): drafts
  and dialogs free what they own on close and in `State_Destroy` (`ProjectSettings_Destroy`).
- Logic (the serializer, model, undo, export command lines) gets `odin test` tests. Pay particular
  attention to XML round trips.
- Interaction: add or extend a `tests/ui` script and run `task test:ui` **and**
  `task test:ui:fullscreen` (headless and parallel; `SCRIPT=` for one while working on it). The
  tiled size (640x660, a bottom panel 200 px wide) is what a tiling window manager gives the
  window here; wide layouts only get exercised at 1280x720. `task test:ui:visible` shows a
  script running when a failure needs watching.
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
  builds with a known version; installing it (`task emsdk`, ~1 GB) is a separate step in a
  checkout; users' editors install it on demand (Export: "Emscripten for the user").
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
- **Scripts open in the built-in code editor** by default (Settings > Editor's built-in code
  editor), **or an external editor**, set in Settings: the program
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
