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


