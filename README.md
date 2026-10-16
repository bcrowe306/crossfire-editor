# Odin SDL Editor

A game editor for [odin_sdl_engine](../odin_sdl_engine), written in [Odin](https://odin-lang.org)
with the [Skald](https://github.com/bcrowe306/Skald) GUI framework.

**Status:** early. Projects load from and save to XML. You can edit scenes in the engine-rendered
viewport, the node tree and the inspector, undo and redo edits, and **Play** runs the project in
the engine. Export isn't implemented yet.

## Requirements

- Odin (`dev-2026-10` nightly or newer)
- [Task](https://taskfile.dev) to run the build commands
- SDL3 (plus SDL3_image, SDL3_ttf, SDL3_mixer for the engine) and a Vulkan loader. Per-platform
  setup is in `Skald/PLATFORMS.md`.
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
| `task submodules` | Fetch or update the Skald submodule |
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
  has a color picker. Number fields take typed values, or step with their − and + buttons.
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

## Documentation

Source code uses Odin-style doc comments; `odin doc .` prints them. Contributor and design notes,
including the planned project format and export targets, are in [CLAUDE.md](CLAUDE.md).

## License

Not yet chosen. Bundled third-party assets: Font Awesome Free icons (SIL OFL 1.1,
`assets/fonts/LICENSE.fa.txt`).
