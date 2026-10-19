<p align="center"><img src="assets/icons/crossfire_256.png" width="128" alt="Crossfire"></p>

# Crossfire Editor

[![Build](https://github.com/bcrowe306/odin_sdl_editor/actions/workflows/build.yml/badge.svg)](https://github.com/bcrowe306/odin_sdl_editor/actions/workflows/build.yml)
[![Engine build](https://github.com/bcrowe306/odin_sdl_engine/actions/workflows/build.yml/badge.svg)](https://github.com/bcrowe306/odin_sdl_engine/actions/workflows/build.yml)

The game editor for the [Crossfire Engine](https://github.com/bcrowe306/odin_sdl_engine)
(the `odin_sdl_engine` repository), written in [Odin](https://odin-lang.org)
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

## Toolchain (what building games needs)

**Settings > Toolchain** lists what the editor found, and how to get what's missing:
- **Projects without scripts** play and export with a **prebuilt player** next to the editor
  (`prebuilt/<target>/player`; `task prebuilt` builds it, releases ship it): nothing to install.
- **Projects with scripts** are compiled with Odin `dev-2026-10`: the path set in that tab, else
  `odin` in PATH, else the one **Install Odin** downloads into the editor's data folder (about 3
  minutes). The engine's sources are your checkout (`ENGINE_DIR`), or `engine/` in a release.
- Odin needs a **linker**: clang on Linux (your package manager), Xcode's command line tools on
  macOS (`xcode-select --install`), Visual Studio Build Tools on Windows ("Desktop development
  with C++").

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
| `task sdl` | Build the engine's static SDL once (needs CMake): the editor and your games then have SDL built in |
| `task test` | Run the unit tests |
| `task test:code-editor` | Unit tests of the built-in code editor's packages (`code_editor/`) |
| `task ols` | Build the Odin language server for the built-in code editor (clones OLS; not needed if `ols` is in PATH) |
| `task verify` | `check` + `test` |
| `task test:ui:fullscreen` | The same in a fullscreen editor, so wide layouts are tested too (`SCRIPT=tests/ui/animation.script` runs one) |
| `task test:ui` | Run the UI test scripts in `tests/ui`, which drive the editor with injected input (opens the editor window). They use a copy of `tests/fixtures/ui_project` and default settings |
| `task build` | Debug build into `build/odin_sdl_editor` |
| `task build:release` | Optimized build into `build/release/odin_sdl_editor` |
| `task run` | Build optimized and run. Program arguments go after `--` |
| `task run:debug` | Build with debug info (unoptimized, several times slower) and run |
| `task run:fullscreen` | Run fullscreen. Useful on tiling window managers, which shrink the window into a tile |
| `task prebuilt` | Build this platform's prebuilt player (optimized) next to the editors: projects without scripts then play and export without compiling |
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
  - Toolchain: what building games needs, found or not (see above)
  - Project: the open project's settings (the same tabs as File > Project Settings). Apply and
    Save apply them too, as one undoable step; Cancel drops them
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
   and opens it in the built-in code editor.
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

### The built-in code editor

Scripts open in a **tab next to the scene tabs**, in an Odin code editor (`code_editor/`): Odin
highlighting, multiple cursors, find and replace, a command palette (Ctrl+P), and with the Odin
language server, completion, signature help, diagnostics and Go to Definition (which opens the
other file in its own tab). Each script gets its own tab; opening one that's open shows its tab.
Close a tab with its × (or a middle click, or Ctrl+W); one with unsaved changes asks first. The
scene tabs show the scene again. **Save** (Ctrl+S), Play and Export save open scripts with the
project, and a save builds the scripts in the background so the inspector shows new fields.

While the code editor has the keyboard, keys go to it, except Save, Play, Pause, Stop, Build
Scripts, Export, Settings, the bottom panel and Quit. Its key bindings are VS Code's and Zed's
(Ctrl+D next occurrence, Alt+Up/Down move lines, Ctrl+/ comment, F12 definition, Ctrl+P
palette, ...): the palette (Ctrl+P) lists every command with its keys, and its Keymap Editor
changes them. Ctrl+O and Ctrl+Shift+S open and save as through file dialogs. Tab indents with a
tab, as Odin code does.

Scene tabs close with their × too (the scene stays in the project; opening it brings its tab
back).

A script changed by another program (or git) while it's open is read again; if you have unsaved
changes to it, a bar asks whether to reload it or keep yours. The code editor's own key bindings
and theme (its Keymap Editor and Theme Editor, in the command palette) are kept next to the
editor's settings. All tabs share one language server.

The language server is `ols`: the one in Settings > Editor > Language server, else `ols` in PATH,
else one built with `task ols` (into `code_editor/third_party/ols`), else Zed's Odin extension's.
Without one the editor still works, without completion and diagnostics.

### An external code editor

Turn off **Settings > Editor > Use the built-in code editor** to open scripts in another program
instead: the program (a path, Browse..., or a name found in PATH; `zed` by default) and its arguments (`{file}:{line}` by default; `{file}` and `{line}` are
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

## Components

A component is a node tree saved in the project's assets, to reuse: a ship with its sprite,
exhaust and collision shape, a pickup, an enemy. Right-click a node in the scene tree > **Save as
Component**: it and everything under it become `components/<name>.component.xml`, and the node
becomes an *instance* of it. Then:

- Drag it from the browser's **Components** folder into the viewport, or **Add to Scene**, to add
  more instances, in any scene. An instance has its own name, position, rotation, scale, layer and
  visibility; everything else comes from the component.
- **Open** it (double-click) to edit it in its own tab: every instance follows.
- **Rename** it (its menu in the browser): the file and every instance follow.
- An instance's **Make Unique** (inspector) gives it its own copy of the component, to change it
  without changing the others.
- The browser's preview draws it. **New Component** starts an empty one.
- In code, as many as needed: `e.Scene_Instantiate(self.scene, COMPONENT_SHIP, position = {100, 50})`
  (constants in `scripts/assets.odin`; exported `e.ComponentAsset` fields get a picker).

## LDtk levels

Levels made in [LDtk](https://ldtk.io), the level editor, play in your game:

1. **Import** the `.ldtk` file (File > Import Asset). It's copied into `assets/<name>/` with the
   tileset images and level files it uses, and listed under **Levels** in the browser. Keep
   editing that copy in LDtk (the browser's preview, or the node's inspector, has **Open in
   LDtk**; set LDtk's path in Settings > Editor if it isn't in PATH).
2. **Drag it into the viewport**, or add an **LDtkLevel** node and pick the file. The viewport
   shows the level as the game draws it, and follows LDtk's saves.
3. In the inspector, pick the **level** (or **Whole world**: every level at its place), the
   IntGrid layer that becomes **collision** (and which values; the cells are merged into a few
   rectangles of one StaticBody), and what each **entity** becomes: a component, else the script
   with the entity's name (its LDtk fields set the script's fields with the same name), else a
   rectangle that draws the entity's tile.

In code:

```odin
level := cast(^e.LDtkLevelNode)e.Scene_FindNode(self.scene, "Level")
for coin in e.LDtk_FindEntityNodes(level, "Coin") do log.infof("a coin at %v", coin.position)
entity := e.LDtk_EntityOf(self.node)                       // this node's LDtk data
hp := e.LDtk_FieldValue(entity.fields, "hp", i64(3))
onLadder := e.LDtk_IntGridAtPosition(level, "Walls", e.Node_GetWorldPosition(self.node)) == 2
```

## Input actions

**File > Project Settings > Input** lists the game's actions: named inputs like `jump` or
`ui_left` that keys, mouse buttons, the wheel, gamepad buttons and stick directions trigger (like
Godot's input map). New projects start with `ui_left`, `ui_right`, `ui_up`, `ui_down`,
`ui_accept` and `ui_cancel`. Add bindings by pressing them (**Press a key or button**) or from the
dropdowns (every key, mouse buttons, gamepad buttons and sticks, for any gamepad or one); the
deadzone says how far a stick must move.

In scripts, without SDL:

```odin
move := e.Input_GetVector("ui_left", "ui_right", "ui_up", "ui_down")  // at most 1 long
if e.Input_IsActionJustPressed(ACTION_JUMP) do jump()                  // constants in scripts/assets.odin
if e.Input_IsKeyPressed(.Space) || e.Input_IsMouseButtonJustPressed(.Left) do fire()
aim := e.Input_GetGamepadAxis(.RightX)
```

Also `e.Input_IsActionPressed` / `JustReleased`, `e.Input_GetActionStrength`, `e.Input_GetAxis`,
`e.Input_GetMousePosition`, `e.Input_IsGamepadButtonPressed`. The SDL events passed to `update`
still work for anything else.

## Animations

Select an AnimatedSprite and open the bottom panel's **Animation** tab (or the inspector's **Edit
Animations**). A sprite's image is a sprite sheet (a grid of frames: columns, rows, margin and
spacing); its animations are named runs of those frames, each with its own speed, looping and play
mode (forward, reverse, ping-pong):

- The toolbar along the top picks the animation (a dropdown) and adds, duplicates, removes and
  reorders them; the star marks the one the sprite starts with (**Starts with this**, or the
  inspector's **Starts with**). The selected animation's frames, speed, looping and mode, and the
  sprite sheet's grid, are there too.
- Every frame of the sheet is shown as a thumbnail: click one to start the animation there,
  Shift+click to end it there (or type the numbers).
- The preview plays the animation as the game will, and the viewport plays it on the sprite.

In code: `e.AnimationPlayer_Play(&sprite.animation, "jump")` (with
`sprite := cast(^e.AnimatedSprite)self.node`).

## Particles

A **ParticleEmitter** node (Ctrl+Shift+A) emits particles that move, spin, grow or shrink and
change color over their life: sparks, smoke, fire, rain, exhaust. Its inspector has every
setting, in groups (Emission, Shape, Rotation, Color, Motion, Forces, Collision):

- Numbers are sliders over their useful range. X/Y pairs (size, scale, spread, gravity, wind) have
  a link button: linked, dragging one axis takes the other along in proportion.
- Colors are a color picker and an alpha slider. With **Color ramp** on, a gradient editor sets the
  colors over a particle's life: click the bar to add a stop, drag a stop's marker to move it,
  select one to change its color, alpha or position, **Remove** deletes it.
- Shapes: circle, ellipse, rectangle, pixel, line, a texture (pick the image under the shape), or
  drawn by your script (Custom: `emitter.customDraw`).
- **Reset to defaults** puts every setting back (undoable, like every change).

The viewport plays emitters live (P pauses viewport animations), and picks up changes as you drag a
slider. In code: `e.ParticleEmitter_Start(emitter)` fires a one-shot emitter (emitting and
continuous off, burst 1), `e.ParticleEmitter_Stop`, and `emitter.settings` changes any setting.
The demo's ship exhaust and pickup sparks show both.

## Sound

Three sound nodes (Ctrl+Shift+A):
- **AudioPlayer** plays a sound: volume, pitch, pan, loop, and Autostart (plays when its scene
  starts).
- **AudioPlayer2D** is a sound in the world: panned by where it is relative to the camera, and
  quieter with distance, silent past its **Range** (the ring in the viewport); **Falloff** shapes
  the fade.
- **MusicPlayer** streams music, with speed, fade in and fade out. Music is an asset of its own:
  import the file, then right-click it in the browser > **Use as Music (streamed)**.

**Preview** in the inspector plays the node's sound as set, through its bus. Every sound node goes
to a **bus** (Master by default). The bottom panel's **Mixer** tab is laid out like a DAW's mixer:
a channel strip per bus, scrolling sideways when they don't fit, and Master always on the right
(+ beside it adds a bus). Each strip has pan, a volume fader in dB (double-click resets it to
0 dB, Shift drags finely) with a level meter beside it, mute, and the bus's name at the bottom
(type to rename). The meters show what the editor plays; removing a bus sends its nodes to
Master. Bus effects come later.

In code: `e.AudioPlayer_Play(player)`, `e.AudioPlayer_Stop`, `e.MusicPlayer_FadeOut(music, 2)`,
`e.MusicPlayer_Seek`, `e.Audio_SetBusVolume("Music", 0.5)`, `e.Audio_SetBusMute("SFX", true)`.

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

## Renderer

**File > Project Settings > General > Renderer** picks what the game draws with: **Auto** (the
default: SDL's choice, OpenGL on Linux, Direct3D 11 on Windows, Metal on macOS), OpenGL,
OpenGL ES 2, Vulkan, SDL GPU, Direct3D 11 or 12, Metal, or Software. Choices this computer
doesn't have are marked. A game whose renderer isn't available where it runs uses SDL's choice
instead, and web exports always use WebGL. The game's log says which one it got
(`Renderer: vulkan` in the Console). The engine's player also takes `--renderer <name>`.

## Exporting

**File > Project Settings > Export** lists every target. Check the ones you want, set each one's
options, then **File > Export** (Ctrl+Shift+E) exports all checked targets; the Export button in the
tab exports the target shown. Exporting saves the project first; progress is in the **Output** tab.
Settings are saved in the project's `export.ini`, and output goes to `export/<target>` in the
project folder unless you choose another folder.

| Target | Status | What you get |
|---|---|---|
| Linux x86_64 | Works (on Linux x86_64) | **One file**: the game, with the project's files inside it (Single file; off: `data/` beside it) and SDL built in (once the engine's `tools/build_sdl_static.sh` has run, `task sdl`; else its libraries go in `lib/`); optional `.tar.gz`. Runs from anywhere: no arguments needed. Runs on the glibc it was built with or newer: export on an older Linux to reach more players |
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

**Project archives:** File > **Export Project Archive...** saves the project and writes it as one
`.odinsdl` file (a zip, so any unzip tool opens it too): everything in the project folder except
exported games, `build/` and `.git/`. Assets that live outside the project folder are copied in,
and the archive's files point at the copies, so the archive works anywhere (the project itself
isn't changed). File > **Open Project Archive...** picks an archive (or a zip of a project), then
the folder to unpack it into, and opens it.

**Version control:** the bottom panel's **Git** tab (needs [Git](https://git-scm.com)).
Initialize Repository makes the project folder a repository, with a `.gitignore` that leaves out
exported games and build output, and a `.gitattributes` that keeps line endings the same on every
OS. Then: the changed files (check one to stage it; Commit with
nothing staged commits every change), the commit message, the history, branches (switch, or type
a name and Create), and Pull / Push (or Add Remote with a URL). The editor saves before git runs,
and opens the project again after a pull or a branch switch. Git needs your name and email for
commits (`git config --global user.name "..."` and `user.email`); pushing uses your usual git
credentials (it never stops to ask for a password).

A project is a folder with `project.xml`, a `scenes/` folder with one XML file per scene, and
`assets/`. The format is specified in the engine's `project_format.odin`.
[`examples/demo_project`](examples/demo_project) is a small example with a menu, a play scene with
sprites and animations, and an options screen. Its images were generated for this repo.

## Releases

Pushing a version tag (`v0.2.0`, or `v0.2.0-dev.1` for a pre-release) builds and tests the editor
with the engine on Linux x86_64, Windows x86_64 and macOS arm64 (`.github/workflows/build.yml`)
and, when all three pass, publishes them as a [release](https://github.com/bcrowe306/odin_sdl_editor/releases):
one archive per platform with the built editor and the SDL3 libraries it needs (no sources). The
badges above show the latest build. Play and Export in a release still need Odin (`dev-2026-10`)
and the engine's sources at `../odin_sdl_engine` (the archive's README.txt says how).

## macOS app

On a Mac, `task macos:deps` (once: dylibbundler, Homebrew's Vulkan loader and MoltenVK, CMake,
dmgbuild), then `task macos:dist` builds **`dist/macos/Crossfire Editor.app`** and a disk image
to install it from. The app holds everything but Odin: the editor, the Odin language server, the
prebuilt player, the engine's sources and static libraries (games compile against them), the
Vulkan loader and MoltenVK. `task macos:verify` installs the disk image's app into a temporary
folder and runs UI tests with it. Each step is a task of its own (`task --list`); CI runs the
same ones. From the app, settings live in `~/Library/Application Support/crossfire-editor` and the
demo project in `~/Documents/Crossfire Editor`.

## Documentation

Source code uses Odin-style doc comments; `odin doc .` prints them. Contributor and design notes,
including the planned project format and export targets, are in [CLAUDE.md](CLAUDE.md).

## License

Not yet chosen. Bundled third-party assets: Font Awesome Free icons (SIL OFL 1.1,
`assets/fonts/LICENSE.fa.txt`).
