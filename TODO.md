# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

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

- Parallax layers (the data is read: `LDtkLayer.parallax`, `parallaxScaling`).
- Entity references (`EntityRef` fields) resolved to the entities' nodes.
- LDtk's tile render modes for entity tiles (Cover, Repeat, Stretch, NineSlice...); they're all
  fitted inside today.
- LDtk's internal icon atlas (`embedAtlas: LdtkIcons`): entities using it show as outlined boxes.
- Culling large tile layers to the view.
- The generated collision body's physics layers, mask, friction and restitution in the
  inspector (the engine and the scene format have them).
- A level picker with thumbnails; hot reload of a level while the game plays.

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
