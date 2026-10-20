# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

## Engine

- A faster correct software path for LDtk tiles (SDL's software renderer draws them as separate
  triangles, correct but slow: the headless demo run takes ~3 min).

## Editor UI

- **Arrow keys change a focused dropdown's choice** (Up/Down while it's closed). Value sliders,
  number fields, the fader and pan control already step with them, and Skald's slider does; its
  `select` only opens on Space/Enter, so this one is a change in Skald.

- **Edit components in the viewport without putting them in a scene.** Opening a component
  (double-click or Open in the browser's Components folder) already gives it a tab of its own;
  make that the obvious way in (an Edit button on the component's preview and inspector, the
  same from an instance's inspector) and check that every editing tool works in a component
  tab as in a scene. **Empty components that start with a node of your choice:** New Component
  makes a Node2D root today; let it pick the root's kind (a Sprite, an Area, a CharacterMover...)
  as Add Node does.
- **Tooltips on the GUI's controls**, so it's easier to learn: every toolbar and panel button,
  the inspector's fields (what the setting does, its range), the Project Settings and Settings
  controls, the bottom panel's tabs. Some buttons have one (`skald.tooltip`, with the shortcut
  from `actionTip`); most controls don't.

## Builds and releases

- **macOS bundle signing and notarization** with gon (`brew install mitchellh/gon/gon`, a
  checked-in `.json` config), once an Apple developer account is available: `task
  macos:notarize`, `tools/macos/gon.json.example`, `entitlements.plist`.
- A disk image background (the volume and app have the Crossfire icon).
- **Linux and Windows bundles** the same way: Taskfile.linux.yml (an AppImage?) and
  Taskfile.windows.yml (an installer?), with CI calling them as it does for macOS.
- Windows and macOS **game exports** (exports only build Linux x86_64 so far). macOS games keep
  their data in the `.app`'s Resources instead of a pack (appending breaks code signing).
- **Prebuilt players for every platform** in every release archive (each archive has only its
  own platform's today; enough while exports only build for the host).
- **The zig experiment**: one linker everywhere, and Linux builds against an old glibc (a build
  made on this Arch machine needs GLIBC 2.43).
- **Download Emscripten for the user** the first time a web export needs it (today: `task emsdk`
  by hand; a release has no emsdk), and fold the SDL3_mixer web build into it.

## Branding (Crossfire)

- An **About** dialog with the logo and the version (Help > About only logs "not implemented").
- The engine's player: a window icon for games (the project's own, or Crossfire's by default).
- Optional, bigger renames: the executable (`odin_sdl_editor` -> `crossfire-editor`), the GitHub
  repositories, the Odin packages. Only display names, archives, the app bundle, the data folder
  and the app ID are Crossfire so far.

## LDtk levels

- Pick a level by clicking it in the browser's world map (the inspector shows the chosen one).
- Hot reload of entities and of layers added or removed (Play reloads tiles, collision and
  backgrounds; entities would need scripts to let go of their nodes).

## Version control (Git tab)

- Diffs of a change, discarding changes, merge conflicts, Git LFS for large assets, the branch
  in the status bar.

## Project archives

- Optionally include `.git` (the project's history) in an archive.
- Open an archive given on the command line (`odin_sdl_editor game.odinsdl`).

## Tests

- Small memory leaks reported by older unit tests (animation_panel_edits, components_*,
  export_settings_dialog, globals_dialog_and_data_edits, input_settings_edits,
  physics_project_settings, project_settings_dialog, renderer_setting_round_trip_and_undo).
- `tests/ui/scene_tree.script` failed once in a fullscreen run at the paste-into-parent check
  (line 95), then passed twice alone: a timing flake to find.
