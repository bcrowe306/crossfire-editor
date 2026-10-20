# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

## Engine hardening (in progress, in this order)

1. **Correctness, tests, memory** for Node / Scene / Game / Application: a test for every public
   lifecycle procedure (create, add, remove, find, reparent, switch, rebuild, destroy and their
   edge cases), each run under the leak-tracking allocator, keeping the arena-per-lifetime
   pattern. Known from the audit: removing the camera leaves `scene.camera` dangling;
   `Scene_Destroy` destroys parents before children and sends no `onExit`; nodes made with
   `addToScene = false` and never added leak; reparenting across scenes isn't refused; nodes
   made in an `onEnter` handler can be lost; subscribing or unsubscribing while notifying is
   unsafe; `Timer` (whole-second durations, nil `start`, `onTick` never sent) and `Ticker`
   (divide by zero at 0 fps, drift) are broken; game swap and `Game_Destroy` leave dangling
   pointers; `game.name` leaks.
2. **Optimization, measured first** (benchmarks: frame breakdown, node churn, LDtk, particles,
   physics, removals, text): LDtk tile culling by grid and cached vertices, a one-pass draw
   order, cached world transforms, physics syncing only moved bodies and Box2D's worker
   threads, `#soa` particles packed to their count with a grid for collisions, cheaper node
   allocation, O(1) removal and id lookup, `Node` / `PhysicsBody` layout (u8 enums, hot fields
   first). API changes (EventSubject without proc fields, pooled node storage) only with numbers.
   Also: LDtk tiles as separate triangles in SDL's software renderer (the fix for vanishing
   tiles) made software rendering of the forest slow (the headless demo run went to ~3 min);
   the editor's viewport uses the GPU now, so this hits only the software fallback and headless
   tests: worth a faster correct path (e.g. drawing static layers to a texture once).
3. **Features:** pause and process modes and a time scale, tweens, groups/tags, z-index and
   y-sort, render targets and blend modes, window settings (fullscreen, vsync, HiDPI), physics
   queries and one-way platforms, a debug overlay, UI navigation by gamepad and actions,
   localization, input rebinding saved and rumble.
4. **API documentation for OLS:** `doc.odin`, every public declaration in Odin core style, a
   comment on every struct field (OLS shows a comment only on the field right below it), internal
   plumbing made `@(private)` (except what the editor uses).

## Editor UI

- **Pan and scroll the viewport.** Scroll horizontally and vertically, not only zoom. A pan tool
  of its own is fine; also a modifier with the wheel (say Shift + wheel pans sideways, Ctrl +
  wheel up and down, plain wheel zooms as now) and a touchpad's two-finger scroll. Today the
  wheel only zooms; panning is a right or middle drag, or Space + left drag (`Viewport_Panned`).
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
