# Odin SDL Editor

[![Build](https://github.com/bcrowe306/odin_sdl_editor/actions/workflows/build.yml/badge.svg)](https://github.com/bcrowe306/odin_sdl_editor/actions/workflows/build.yml)
[![Engine build](https://github.com/bcrowe306/odin_sdl_engine/actions/workflows/build.yml/badge.svg)](https://github.com/bcrowe306/odin_sdl_engine/actions/workflows/build.yml)

A game editor for [odin_sdl_engine](../odin_sdl_engine), written in [Odin](https://odin-lang.org)
with the [Skald](https://github.com/bcrowe306/Skald) GUI framework.

**Status:** early. Projects load from and save to XML. You can edit scenes in the engine-rendered
viewport, the node tree and the inspector, undo and redo edits, and **Play** runs the project in
the engine. **Export** builds the game for Linux x86_64 and the web (other targets are listed, but
not implemented yet).

## Requirements

- Odin (`dev-2026-10` nightly or newer)
- [Task](https://taskfile.dev) to run the build commands
- SDL3 (plus SDL3_image, SDL3_ttf, SDL3_mixer for the engine) and a Vulkan loader. Per-platform
  setup is in `Skald/PLATFORMS.md`.
- For web exports only: Python 3 and `task emsdk` (Emscripten, about 1 GB, installed into the
  `third_party/emsdk` submodule; it also builds SDL3_mixer from the `third_party/SDL_mixer`
  submodule for game sound).
- A checkout of [odin_sdl_engine](../odin_sdl_engine). By default it's expected next to this repo
  (`../odin_sdl_engine`); set `ENGINE_DIR` to use another location.

## Getting started

```bash
git clone --recursive <this repo>
cd odin_sdl_editor
task setup    # fetch the Skald submodule, build Odin's STB libraries (once per Odin install)
task run      # build and run the editor; it opens the demo project
```

Press **Play** (F5) to run the open project. The first time, the editor builds the engine's game
player (progress in the **Output** tab), then starts the game; its log appears in the **Console**.
**Stop** (Shift+F5) closes it.

To open a different project: File > Open Project (Ctrl+O), or `task run -- path/to/project`. To use an engine checkout somewhere
else: `task run ENGINE_DIR=/path/to/odin_sdl_engine`.

## Commands

Run `task` to list them all.

| Command | What it does |
|---|---|
| `task setup` | One-time setup: `task submodules` + `task stb` |
| `task submodules` | Fetch or update the submodules (Skald, emsdk) |
| `task box2d` | Build the engine's Box2D (once; builds and checks do it when needed) |
| `task emsdk` | Install the Emscripten toolchain web exports need (about 1 GB into `third_party/emsdk`, once per machine), and build SDL3_mixer for the web |
| `task web:mixer` | Rebuild SDL3_mixer for the web (`build/web/`); exports build it themselves when it's missing |
| `task stb` | Build Odin's STB libraries, which Skald needs. Skipped if already built |
| `task check` | Type-check the editor, with vet |
| `task test` | Run the unit tests |
| `task verify` | `check` + `test` |
| `task test:ui` | Run the UI test scripts in `tests/ui`, which drive the editor with injected input (opens the editor window). They use a copy of `tests/fixtures/ui_project` and default settings |
| `task build` | Debug build into `build/odin_sdl_editor` |
| `task build:release` | Optimized build into `build/release/odin_sdl_editor` |
| `task run` | Build optimized and run. Program arguments go after `--` |
| `task run:debug` | Build with debug info (unoptimized, several times slower) and run |
| `task run:fullscreen` | Run fullscreen. Useful on tiling window managers, which shrink the window into a tile |
| `task player` | Build the engine's game player into `build/player/` |
| `task play:demo` | Run the demo project in the player, without the editor |
| `task clean` | Delete build output |

The Taskfile passes the flags every build needs:
- `-collection:gui=Skald`: Skald is imported as `gui:skald`.
- `-collection:engine=$ENGINE_DIR` and `-define:ENGINE_DIR=...`: the engine is imported as `engine:.`,
  and Play builds the player from it.
- `-vet-unused -vet-packages:editor`: vet only this package; Skald itself doesn't pass vet.

## Layout

| Area | Contents |
|---|---|
| Top | Menu bar and toolbar: file actions, undo/redo, tools, play controls, export |
| Left | Project browser: scenes and assets |
| Center | Scene tabs and the scene view |
| Right | Scene node tree and the inspector for the selected node |
| Bottom | Console / Output / Animation tabs, collapsible (Ctrl+J) |

## Project browser

- **Search** at the top filters scenes and assets by name (Escape clears it).
- **Preview** (bottom, collapsible): shows the selected image with its size, or plays the
  selected sound.
- **Import** (Ctrl+I or +): copies an image, sound or font into the project's `assets/` folder.
- **Remove** (trash): removes the asset from the project, optionally deleting the file.
  It warns when nodes still use it.

Imported and removed assets are saved to project.xml on Save (Ctrl+S) or Play.

## Scene tree

- **Right-click** a node for Add Node, Duplicate, Copy, Cut, Paste and Delete. Right-click below
  the nodes to paste at the top level.
- **Drag** a node onto another: near the top or bottom edge of a row puts it before or after that
  node, the middle makes it a child. Drop it below the rows to make it a top-level node. It keeps
  its place in the scene; its position is adjusted for the new parent.
- **Keys:** Ctrl+D duplicate, Ctrl+C / Ctrl+X / Ctrl+V copy, cut and paste (into the selected
  node). They're left to text fields while you type.

## Adding nodes

**Add Node** (Ctrl+Shift+A, or + above the scene tree) opens a list of the node types the engine
supports. Type to search by name or description, use Up/Down and Enter or click a type to add it,
and Escape to cancel. The new node is added as a child of the selected node, or at the top level
when nothing is selected.

## Undo and settings

- **Undo / redo:** Ctrl+Z, and Ctrl+Shift+Z or Ctrl+Y (also the toolbar and Edit menu, which
  names the step). Every scene edit is undoable. Quick edits to the same thing (typing a name,
  dragging a number, nudging) undo as one step; a viewport drag is always one step.
- **Settings** (Edit > Settings, Ctrl+,):
  - Appearance: dark or light theme, text size, spacing, row height
  - Editor: how undo merges edits, and how many steps it keeps
  - Keyboard: every shortcut, two per command. Click one and press the new keys
- Settings are saved to `editor.ini` next to the editor's executable. The defaults are in
  [`settings.default.ini`](settings.default.ini). Use `--settings <file>` to keep them elsewhere.

## Viewport and keyboard

The viewport renders the open scene with the engine (animations play; P toggles them).

| Input | Does |
|---|---|
| Click / drag | Select the node under the cursor and drag it with the active tool |
| Q / W / E / R | Select, Move, Rotate, Scale tool |
| Shift while dragging | Move along one axis, snap rotation to 15°, scale axes separately |
| Mouse wheel | Zoom around the cursor |
| Middle or right drag, Space + drag | Pan |
| F | Frame the selected node |
| Ctrl+0 / Ctrl+1 / Ctrl+= / Ctrl+- | Fit game area / 100% / zoom in / zoom out |
| Arrow keys (Shift for ×10) | Nudge the selected node (mouse over the viewport) |
| Esc / Delete | Deselect / delete node |

Single-letter shortcuts are ignored while typing in a field. Help > Keyboard Shortcuts lists them all.

## Scripts

Game code is Odin, in the project's `scripts/` folder, and attaches to nodes:

1. Select a node, and in the inspector's **Script** section click **+** (or Scripts > New Script).
   Name it (`PlayerController`); the editor writes `scripts/player_controller.odin`, attaches it,
   and opens it in your code editor.
2. Write the struct's fields and its `ready` / `update` procedures. Fields tagged `export:""`
   (options: `default=`, `min=`, `max=`, `kind=scene`) appear in the inspector after a build.
3. **Build Scripts** (Ctrl+B) compiles them, which also happens when you Play and when a project
   with scripts opens. Errors show in the Output tab.

```odin
Player :: struct {
    using script: e.Script,
    speed: f32 `export:"default=250 min=0"`,
}

@(init)
register_Player :: proc "contextless" () {
    e.Script_Register(Player, {
        update = proc(self: ^Player, events: []sdl.Event, dt: f64) {
            self.node.position.x += self.speed * f32(dt)
        },
    })
}
```

The code editor is set in Settings > Editor: the program (a path, Browse..., or a name found in
PATH; `zed` by default) and its arguments (`{file}:{line}` by default; `{file}` and `{line}` are
replaced; `{folder}` is the scripts folder). It runs in the project's scripts folder with the
editor's environment; if it exits with an error, the Console says so.

**Code completion:** the editor writes `scripts/ols.json`, so the Odin language server (OLS, which
Zed's Odin extension and other editors use) knows where the engine is: completion, hover and
go-to-definition work for `e.` and the rest of the engine. The default arguments open the scripts
folder as the editor's workspace, which is where OLS looks for the file. To keep your own changes
to ols.json, delete its `_generated_by` line. Play builds unoptimized (about 4 s); turn on Optimized Play for speed tests. Scripts
don't run in the viewport. One script per node for now.

## Scenes

Scenes are managed in the project browser's **Scenes** folder:

- **Right-click** a scene for Open, Play Scene, Rename, Duplicate, Copy, Cut, Paste, Delete, Set as
  Start Scene and New Scene. Right-click the folder (or below the rows) for New Scene and Paste.
- With the browser focused, the node keys act on the selected scene: **F2** rename, **Ctrl+D**
  duplicate, **Ctrl+C / Ctrl+X / Ctrl+V**, **Delete**. Double-click a scene to rename it.
- Renaming a scene updates what refers to it: the start scene, menu buttons that switch to it, and
  script fields that name it. Old scene files are removed on Save. Everything can be undone.
- **Play** (F5) starts at the project's start scene, marked "(start)" and set in **File > Project
  Settings** (with the game's name, resolution, scaling and background) or with Set as Start
  Scene. **Play Scene** (Ctrl+F5) starts at the scene open in the viewport.

## Physics

Games get 2D physics from the engine (Box2D). Add these nodes like any other (Ctrl+Shift+A):

| Node | What it is |
|---|---|
| StaticBody | Doesn't move by itself: walls, floors, platforms |
| DynamicBody | Moved by gravity, collisions and forces: crates, balls, debris |
| CharacterMover | Moved by your script (`e.CharacterMover_Move`), sliding along walls and floors: players, enemies |
| Area | Reports bodies entering and leaving it: pickups, triggers, damage zones |
| CollisionShape | The shape of the body above it: rectangle, circle, capsule, polygon, segment |
| RayCast | Reports the first body in its way: line of sight, ground checks |
| Joint | Connects two bodies at its position: a hinge (Revolute), a rod, rope or spring (Distance), a slider (Prismatic), glue (Weld) or a wheel's suspension (Wheel), with limits, motors and springs |

A body needs a CollisionShape under it. The inspector edits each body's collision layers (which
of layers 1-16 it's on, and which it collides with), friction, bounce, mass and more. Shapes and
rays and joints are drawn in the viewport (Shift+C, or the viewport's shapes button, hides them).
**Scene > Show Collision Shapes in Game** (or Project Settings > Show shapes) makes the game draw
them when you Play; it's saved with the project, and **exports never draw them**. While a game
runs from the editor, **F9** shows and hides them. Project Settings also has the world's scale
(pixels per meter), gravity and Smooth motion (moving bodies glide on high-refresh screens).

Scripts react to collisions with the `collisionEnter` / `collisionExit` hooks, and to Areas with
`areaEnter` / `areaExit` (or the bodies' events), and can ask at any time:
`e.PhysicsBody_IsInArea(body, area)`, `e.PhysicsBody_GetAreas(body)`,
`e.PhysicsBody_IsTouching(a, b)`.

## Game state, data and assets in code

- **Global scripts** run once for the whole game, across scenes: game state, settings, a HUD.
  Make one with New Script (kind **Global script**); **File > Project Settings > Globals** lists
  them, sets their fields and their order. Any script reaches one with `e.Global(GameState)`. A
  global can draw over the game (its `draw` hook) and hide itself (`self.hidden`).
- **Saves:** `e.Save_Game()` / `e.Load_Game()` write and read the globals' state as JSON (fields
  that aren't exported; exported ones are editor settings, unless tagged `save:""`).
- **Data resources** are reusable data in files: make a type with New Script (kind **Data
  type**), then right-click the browser's **Data** folder > **New Data Resource**. Select one to
  edit it in the inspector. Load it in code with `e.Data(EnemyStats, DATA_GOBLIN)`.
- **Assets from code:** the editor writes `scripts/assets.odin` with a typed constant for every
  asset (`TEXTURE_SHIP`, `SOUND_LASER`, `DATA_GOBLIN`, ...): `e.Game_PlaySound(game, SOUND_LASER)`,
  `e.Asset_Texture(game, TEXTURE_SHIP)`. Fields of type `e.SoundAsset` (and Texture, Font, Data)
  get an asset picker in the inspector.

The demo project (`examples/demo_project`, see its README) uses all of these.

## Exporting

**File > Project Settings > Export** lists every target. Check the ones you want, set each one's
options, then **File > Export** (Ctrl+Shift+E) exports all checked targets; the Export button in the
tab exports the target shown. Exporting saves the project first; progress is in the **Output** tab.
Settings are saved in the project's `export.ini`, and output goes to `export/<target>` in the
project folder unless you choose another folder.

| Target | Status | What you get |
|---|---|---|
| Linux x86_64 | Works (on Linux x86_64) | The game, `data/` (project files) and `lib/` (the SDL3 libraries); optional `.tar.gz`. Runs from anywhere: no arguments needed |
| Web (WebAssembly) | Works | `index.html`, `.js`, `.wasm`, `.data`: serve the folder over HTTP (`python3 -m http.server`); optional `.zip` for itch.io. Sound works (WAV, OGG, MP3, FLAC) and starts after the first click or key press, as browsers require; images must be PNG or BMP. Needs `task emsdk` |
| Linux ARM64, Windows, macOS | Not implemented | Planned: built on CI, one runner per OS |
| Steam | Not implemented | Planned: uploads desktop builds |
| PlayStation 5, Xbox Series, Switch | Not implemented | Need the platforms' licensed SDKs |

Options per target include the executable name or page title, optimization (on by default),
bundling libraries and the archive.

## Selecting and editing

- **Multi-select:** Ctrl+click toggles a node (viewport or scene tree), Shift+click adds (a range
  in the tree), drag on empty viewport space to box select, Ctrl+A selects all. Delete, copy, cut,
  duplicate, nudge and dragging act on every selected node; the inspector edits the last one.
- **Grid and snapping:** G shows the grid, Shift+G snaps moves to it (rotation to 15°, scale to
  0.1). The grid size is in Settings > Editor.
- **Rename in place:** F2 or double-click a node in the scene tree; Enter keeps it, Escape cancels.
- **Images into the scene:** drag an image from the project browser into the viewport to add a
  Sprite there.
- **Inspector:** a sprite's image is picked from the project's images (or None); a label's color
  has a color picker. Number fields take typed values, or step with their − and + buttons. The
  chain button next to Position X and Scale X links the pair: changing one axis changes the other
  in proportion.
- **Colors:** the scene tree shows each node kind in its own color (the same as its viewport
  marker), and the project browser colors scenes, images, audio and fonts.

The status bar shows whether the project has unsaved changes (also a `*` in the window title), and
the frame rate and the last viewport render time.

## Projects

**File > New Project** (Ctrl+N) creates a project folder with a Main scene. **Open Project**
(Ctrl+O) opens a project folder. Both, and Quit, ask to save unsaved changes first.

A project is a folder with `project.xml`, a `scenes/` folder with one XML file per scene, and
`assets/`. The format is specified in the engine's `project_format.odin`.
[`examples/demo_project`](examples/demo_project) is a small example with a menu, a play scene with
sprites and animations, and an options screen. Its images were generated for this repo.

## Releases

Pushing a version tag (`v0.2.0`, or `v0.2.0-dev.1` for a pre-release) builds and tests the editor
with the engine on Linux x86_64, Windows x86_64 and macOS arm64 (`.github/workflows/build.yml`)
and, when all three pass, publishes them as a [release](https://github.com/bcrowe306/odin_sdl_editor/releases):
one archive per platform with the editor, its libraries, the demo and the engine. The badges
above show the latest build. Play and Export in a release still need Odin (`dev-2026-10`).

## Documentation

Source code uses Odin-style doc comments; `odin doc .` prints them. Contributor and design notes,
including the planned project format and export targets, are in [CLAUDE.md](CLAUDE.md).

## License

Not yet chosen. Bundled third-party assets: Font Awesome Free icons (SIL OFL 1.1,
`assets/fonts/LICENSE.fa.txt`).
