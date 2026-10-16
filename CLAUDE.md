# Odin SDL Editor

A desktop game editor for the **odin_sdl_engine**. Users create projects, build scenes from nodes,
manage assets, run their game, and export it to the web and desktop platforms (later: Steam,
consoles and handhelds).

**Status:** early but usable.
- **Works:**
  - The viewport renders the scene with the engine and supports selecting, moving, rotating and
    scaling nodes, with a keyboard-driven keymap.
  - Projects load from and save to disk as XML (`examples/demo_project` opens by default).
  - The project browser searches, previews images and sounds, and imports/removes assets.
  - The inspector edits node properties. **Play** runs the project in the engine's player.
- **Not yet:**
  - Export, Undo, New and Open only log "not implemented yet". To open a project, pass its folder
    on the command line.
  - No drag-to-reparent in the scene tree.

Sections marked "planned" describe where it's going. Update this file as they become real.

## Stack

| Piece | What | Where |
|---|---|---|
| Language | Odin (`dev-2026-10` nightly) | `odin version` |
| UI | **Skald**: Elm-architecture GUI, Vulkan renderer, SDL3 windowing | `Skald/` git submodule (github.com/bcrowe306/Skald) |
| Engine | **odin_sdl_engine**: SDL3 renderer, scenes/nodes with transforms, camera, animation, UI menus, project loader, player | Separate repo; found through `ENGINE_DIR` (default `../odin_sdl_engine`) |
| Project files | XML | Written by this repo (`project_xml.odin`), read by the engine's parser (see "Project format") |

## Setup and commands

All build, run and test commands live in `Taskfile.yml` ([Task](https://taskfile.dev)). **Use the
tasks rather than raw `odin` commands**, and when adding a new build, test or tooling command,
add it as a task and to the README's command table.

| Command | What it does |
|---|---|
| `task setup` | One-time setup: `submodules` + `stb` |
| `task submodules` | `git submodule update --init --recursive` (Skald) |
| `task stb` | Build Odin's STB libraries Skald needs (`build_stb.sh`). Skipped when already built for the active Odin install |
| `task check` | Type-check with `-vet-unused -vet-packages:editor` (Skald itself doesn't pass vet) |
| `task test` | Unit tests (`editor_test.odin`) |
| `task verify` | `check` + `test` |
| `task test:ui` | UI test scripts (`tests/ui/*.script`) driving the real editor with injected input |
| `task build` / `task build:release` | Debug build into `build/`, optimized build into `build/release/` |
| `task run` | Build and run (debug); program arguments after `--` |
| `task run:fullscreen` | Run with `-define:EDITOR_FULLSCREEN=true` |
| `task player` | Build the engine's player into `build/player/player` |
| `task play:demo` | Run the demo project in the player, without the editor |
| `task clean` | Delete build output |

- `EDITOR_FULLSCREEN` exists for checking the full layout on a tiling window manager (Hyprland
  here), which otherwise squeezes the window into a tile.
- **Engine location:** the Taskfile's `ENGINE_DIR` (default `../odin_sdl_engine`, override with
  `task run ENGINE_DIR=...`) is used twice:
  - as the `engine` collection (`import e "engine:."`)
  - as `-define:ENGINE_DIR`, which Play uses to build `<engine>/player`
- `task run -- <project folder>` opens another project. With no argument the editor opens
  `examples/demo_project`, recreating it from `Project_CreateDemo` if it's missing.
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
| `keymap.odin` | `DEFAULT_KEYMAP`, shortcut dispatch, typing guard |
| `project.odin` | Project model (`Project`, `SceneDef`, `NodeDef`, `AssetDef`), node insert/remove, world transforms, `Project_Load` (through the engine's parser), the demo project |
| `project_xml.odin` | `Project_Save`, XML writer (`ProjectToXML`, `SceneToXML`, `EscapeXML`) |
| `assets.odin` | Importing (copy into `assets/`), removing, usage counts, asset kinds by extension |
| `audio_preview.odin` | Sound playback for the preview panel (SDL3_mixer; package state) |
| `play.odin` | Play mode: save, build the player, run it as a child process, stream output, pause/stop |
| `tree_rows.odin` | Flattens the project into browser and scene tree rows, applying the browser search. Shared by view and update, because Skald's tree reports clicks by row index |
| `view.odin` | Root layout: menu bar, toolbar, resizable workspace, status bar, remove-asset dialog, panel header helpers |
| `view_browser.odin` | Left sidebar: project browser (search, tree, collapsible preview panel) |
| `view_viewport.odin` | Center: scene tabs, view controls, and the viewport canvas (rendered scene, rulers, gizmos, input) |
| `viewport_preview.odin` | Engine-rendered preview of the open scene (software renderer → Skald image) |
| `viewport_math.odin` | Viewport pan/zoom math and drag (move/rotate/scale) math |
| `add_node.odin` | Add Node dialog logic: `AddNode_Kinds` (search over the engine's `SCENE_NODE_KINDS`), `AddNode_Create` (parent, unique name) |
| `node_edit.odin` | Subtree copy/paste/duplicate, `Scene_MoveNode` (reorder and reparent keeping the world transform), unique names |
| `view_add_node.odin` | The Add Node dialog: search box, list of node kinds, Up/Down/Enter keys |
| `view_inspector.odin` | Right sidebar: scene tree above the inspector (common and per-kind properties) |
| `view_bottom.odin` | Bottom panel: Console / Output / Animation / Keys tabs, collapsible |
| `icons.odin` | Font Awesome icon font (`assets/fonts`, OFL) and glyph constants |
| `test_driver.odin` | UI test driver: runs a `--script`, injecting SDL input and checking state (format in its doc comment) |
| `editor_test.odin` | Unit tests for the model, XML round trips, transforms, assets, search, viewport math, keymap and update |
| `tests/ui/*.script` | UI test scripts, run by `task test:ui` |
| `tests/fixtures/` | Files tests import (`beep.wav`: a generated 1.5 s tone) |
| `examples/demo_project/` | The demo project: project.xml, scenes/, generated sprite images in assets/ |

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

**Rendering** (`viewport_preview.odin`): the open scene is rendered by the engine itself, so
sprites, animations, text and menus look as they do in the game. Future engine features
(particles) appear without editor work.
- The engine draws with SDL's software renderer into a surface, then the view uploads the pixels
  with `skald.image_update_pixels` (or `image_load_pixels` when the size changes). The image is
  drawn with `draw_image` inside a canvas.
- Skald draws with Vulkan, so it can't share a GPU context with the engine.
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
- Wheel zooms around the cursor. Middle or right drag, or Space + left drag, pans.
- Messages: `Viewport_Drag_Begin/Move/End`, `Viewport_Panned`, `Viewport_Zoomed`, `Viewport_Measured`.

**Keyboard** (`keymap.odin`): `DEFAULT_KEYMAP` is the single table of shortcuts.
- Defaults:
  - Q W E R tools, F frame selected
  - Ctrl+0 fit, Ctrl+1 100%, Ctrl+=/- zoom, P animations
  - arrows nudge (Shift ×10), Esc deselect, Delete
  - Ctrl+D duplicate, Ctrl+C/X/V copy/cut/paste nodes (not while typing)
  - F5/F6/Shift+F5 play controls, Ctrl+I import
- `KeymapDispatch` runs at the start of `view`, before the menu bar, so each shortcut fires once.
- **Plain keys are ignored while a text or number field has focus** (`IsTyping`), and are hidden
  from menu hints then.
- `viewportOnly` bindings (nudges) need the mouse over the viewport.
- The Keys tab (Help > Keyboard Shortcuts) lists the table.
- **Add new shortcuts to the table, not as ad-hoc `skald.shortcut` calls.** User-editable keymaps
  (loaded from a file) are planned.

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
- **Import** (Ctrl+I or the + button): Skald's native dialog, which picks one file at a time.
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
- The search box has focus when it opens and filters by name or description, case-insensitive.
- Up/Down move the highlight, Enter or a click adds that kind, Escape cancels.
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
- **Context menu**: `skald.context_menu` wraps the tree's scroll area; items are `SCENE_TREE_MENU`.
  A right-click first selects the row under the cursor (`Node_Right_Clicked`; below the rows it
  deselects). Skald builds the tree before the menu that wraps it, so the tree would see a click on
  a menu item first and select the row under it: `sceneTreeView` hides that press from the tree.
- **Drag to move** (`sceneTreeMouse`): a press on a row records `treeDrag`; moving
  `TREE_DRAG_THRESHOLD` px starts the drag. Top/bottom quarter of a row = before/after it as a
  sibling, the middle = its last child, below the rows = last top-level node. The bottom edge of an
  open parent means before its first child. A line or box overlay shows the spot.
  `Scene_MoveNode` rebuilds the depth-first order and keeps the node's world transform under its new
  parent. A node can't go into its own subtree (`Scene_CanMoveNode`).

### Play mode (implemented, `play.odin`)

Play runs the project in the engine's **player** (`<engine>/player`), a separate program that loads
`project.xml` and runs the start scene. A crashing game can't take the editor down, and the player is
the same runtime exports will ship.

1. Save the project (`Project_Save`).
2. If `build/player/player` is missing or older than any engine `.odin` file, run
   `odin build <engine>/player`. Output goes to the **Output** tab.
3. Run `player <absolute project folder>`. Its output goes to the **Console**, with the engine
   logger's level tag and timestamp stripped (`parseLogLine`).

Both are child processes (`core:os` `process_start` with a pipe). A `Play_Tick` message every 0.1 s
(`skald.cmd_delay`) drains the pipe and checks for exit with `process_wait(…, 0)`, so there are no
threads. **Stop** kills the child. **Pause/Resume** send SIGSTOP/SIGCONT; they aren't supported on
Windows yet. Quitting the editor stops the game.

### Undo / redo (planned)

Every edit to the project model is a `Msg` that the undo system will record, so the undo history
belongs in editor `State`. Build it before editing features multiply further; retrofitting it gets
harder with every new edit message.

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
  .editor/                 per-user editor state (gitignored; not used yet)
  build/                   export output (gitignored; not used yet)
```

- **Version 2:** node positions, rotation and scale are relative to the parent. Version 1 files
  (world positions) are migrated when parsed.
- **Node kinds** are the engine's `SceneNodeKind` (the editor's `NodeKind` is an alias):
  Node2D, Sprite, AnimatedSprite, Camera, Label, Menu.
  - Menu buttons carry an action: `scene:<Name>` or `quit`.
  - Hidden nodes and their children aren't drawn at runtime.
- **Writer rules:** attributes are written in a fixed order, and only the ones that apply to the
  node's kind and differ from `e.DEFAULT_SCENE_NODE`. Values are escaped (`EscapeXML`). Output is
  deterministic, so saving an unchanged project produces identical files; a test checks it.
- **Round trips:** `editor_test.odin` saves the demo with tricky values (escapes, non-default
  fields), reloads it, and compares every field. Extend it whenever a property is added.
- **Not handled yet:**
  - Scene files of deleted or renamed scenes aren't removed.
  - The editor only imports assets one at a time and doesn't scan `assets/` for files added
    outside the editor.

## Export (planned)

Pipeline:
1. Validate the project.
2. Build the engine's player (`<engine>/player`) for the target with `odin build`, as Play does for
   the host. Once users can write game code, their packages get compiled into the player.
3. Copy the project's files (project.xml, scenes/, assets/) and the runtime libraries next to it.
   Release builds should make the player find the project relative to itself rather than taking
   it on the command line.
4. Package the result into `build/<preset>/`.

Run the build as a child process and stream its output to the Output tab, the way `play.odin` does.

| Target | Odin target | Ships with it | Notes |
|---|---|---|---|
| Linux | `linux_amd64` (+ `linux_arm64`) | `libSDL3*.so` next to the binary, rpath `$ORIGIN` | AppImage later |
| Windows | `windows_amd64` | `SDL3.dll`, `SDL3_image.dll`, `SDL3_ttf.dll`, `SDL3_mixer.dll` | `-subsystem:windows` for release |
| macOS | `darwin_arm64`, `darwin_amd64` | `.app` bundle, dylibs in `Contents/Frameworks` | Code signing and notarization needed to distribute |
| Web | `js_wasm32` | `index.html`, `.wasm`, `.js`, preloaded assets | Odin's `vendor:sdl3` links an Emscripten-built SDL object on wasm (`SDL3_WASM_LIB`, default `env.o`), so this needs Emscripten (`emcc`) |
| Steam (later) | desktop targets | Steamworks SDK, depots via `steamcmd` | Steam Deck = Linux build plus controller support |
| Consoles / handhelds (later) | platform SDKs | NDA toolchains | Out of scope until the desktop and web targets are solid |

Things to know before promising any target:
- **Cross-compiling:** Odin can target other OSes, but linking needs that platform's toolchain and
  SDKs. Export for the **host OS** from the editor first. Other desktop targets build on CI (a GitHub
  Actions matrix with one runner per OS). Don't promise one-machine cross-export until it's
  demonstrated.
- **Engine changes needed before export works** (they belong in the engine repo):
  - `app.odin` hard-codes the `"opengl"` renderer. Web needs WebGL/GLES and macOS should use Metal,
    so pass `nil` (SDL picks the best available) or choose per platform.
  - `Application_Run` is a blocking `for` loop. The browser needs a callback-driven frame loop (SDL3's
    main-callbacks API, or Emscripten's main loop).
  - On the web, SDL3_image, SDL3_ttf and SDL3_mixer must also be built for Emscripten. Verify they're
    available before committing to the web target.

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

## UI tests (input injection)

`odin_sdl_editor <project> --script <file>` runs a test script inside the editor.
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
  - trees `browser-tree` / `scene-tree`, the search box `browser-search`
  - dialog buttons `dialog-<name>`, the viewport `viewport-canvas`
  - Add Node dialog: `add-node-search`, rows `add-node-<Kind>` (e.g. `add-node-Sprite`), `add-node-cancel`
  - the scene tree's context menu `scene-tree-menu` (`right_click_row`, `click_menu_item`)
- **Rows must be in view.** `click_row`, `right_click_row` and `drag_row` fail on a row scrolled
  out of the tree's visible area. The scene tree pane is short; collapse nodes to keep rows in view.
- **Tree rows** are clicked by row index using `TREE_ROW_HEIGHT`; keep trees on that row height.
- **Never read the screen.** The driver checks editor state, never pixels, and nothing here may
  screenshot the desktop: the user's other windows can be on screen. To check rendering, call
  `Preview_Render` from a scratch test and save its pixels. Skald's own off-screen renderer is
  private to Skald, so snapshots of the UI would need a public Skald API first.
- `task test:ui` runs every script on a scratch copy of the demo project (`build/ui_project`),
  because Play and imports change the project. The editor window opens while it runs. On a
  workspace that isn't visible, the compositor may throttle it, and the run takes minutes instead
  of seconds.
- Add a script, or extend one, for each new interactive feature.

## Verifying work

- `task verify` (check + tests) must pass before saying anything works. The vet flags are limited to
  this package (`-vet-packages:editor`) because Skald itself has unused imports.
- Logic (the serializer, model, undo, export command lines) gets `odin test` tests. Pay particular
  attention to XML round trips.
- Interaction: add or extend a `tests/ui` script and run `task test:ui`.
- Layout: run the editor and look at it yourself (or ask the user). A type check proves nothing
  about layout, and automated checks must not capture the screen.
- Exports: build the exported game and launch it. Report each target honestly as verified, untested,
  or blocked.
- **Editing files with scripts:** never `open(path, 'w')` before the new content is ready; a failure
  in between empties the file. (That happened to this file once.)

## Decisions made

- **The editor gets the engine through a workspace path.** The `engine` collection is set from
  `ENGINE_DIR` in the Taskfile, not a submodule.
- **Scenes load at runtime from XML.** An engine-side loader and a generic player read them; no
  code generation.
- **Game code is written in Odin, not a scripting language.** A project's `src/` package is
  compiled into the player and registers its own node types, which scene files refer to by kind
  name. Hot reload (a shared library loaded with `core:dynlib`) is a possible later step for
  development only; exports link the code in statically. Lua (`vendor:lua`) stays out unless
  modding support is wanted.
- **Node transforms are relative to the parent**, with UI nodes (Label, Menu) following position only.
  The camera is a node.

## Open decisions (confirm with the user before building on them)

- The details of game code: how `src/` is wired into the player build (collection flag or a
  generated import), the node-kind registry API, and how custom node properties reach the
  inspector and scene files.
- Minimum supported OS versions and CPU architectures for each export target.
