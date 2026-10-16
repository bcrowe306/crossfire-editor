# Odin SDL Editor

A game editor for [odin_sdl_engine](../odin_sdl_engine), written in [Odin](https://odin-lang.org)
with the [Skald](https://github.com/bcrowe306/Skald) GUI framework.

**Status:** early. Projects load from and save to XML. You can edit scenes in the node tree and
inspector, and **Play** runs the project in the engine. The scene view is still a placeholder
(not engine-rendered), and export and undo aren't implemented yet.

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

To open a different project: `task run -- path/to/project`. To use an engine checkout somewhere
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
| `task test:ui` | Run the UI test scripts in `tests/ui`, which drive the editor with injected input (opens the editor window) |
| `task build` | Debug build into `build/odin_sdl_editor` |
| `task build:release` | Optimized build into `build/release/odin_sdl_editor` |
| `task run` | Build and run (debug). Program arguments go after `--` |
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

## Projects

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
