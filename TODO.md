# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

## LDtk level editor: parity with LDtk (asked 2026-10-24; build in phases, each released)

The Level mode becomes a better interface for editing LDtk projects, with full parity with LDtk
itself (its source: the workspace's `ldtk/`). The layout comes from the user's design,
`LDtk_interface.html` (a Penpot export, 1920x1080: rendered, it shows):
- a **tool row** across the top (75 px; seven 45 px square icon buttons, centered);
- **left sidebar** (300 px): "Levels" header, then a row per level (60 px: a document icon,
  the level's name; the selected row highlighted);
- **center**: the canvas (the world / level);
- **bottom panel** under the canvas (about a third of the height): a row of tabs (40 px) over
  the selected tab's content;
- **right sidebar** (300 px): "Layers" header, then a row per layer of the selected level
  (60 px: a drag handle to reorder, the layer's name and type, an eye toggle on the right).

The user's decisions (2026-10-24):
- **Phases, each released and usable:** 1) the new layout with what exists today; 2) painting
  in the level: IntGrid values, tiles, entities placed / moved / resized, with LDtk's tools;
  3) the definitions editors: layers, entities and their fields, enums, tilesets, level fields;
  4) auto-layer rules; 5) worlds (several, layouts), project settings and everything else
  LDtk does (a parity audit against `ldtk/`).
- **Tools:** LDtk's (select / move, pencil, rectangle, fill, eraser, picker, tile stamp and
  random), the set adapting to the selected layer's type as LDtk's does; the mock's seven icons
  are placeholders.
- **Bottom tabs:** LDtk's panels: World, Level (its fields and settings), Layers, Entities,
  Enums, Tilesets, Auto-layer Rules, Project; Console and Output kept at the end.
- **Saving:** edits change the document in memory (fast painting, an undo step per stroke);
  Save (Ctrl+S), Play and exports write the .ldtk / .ldtkl files, as LDtk does. The file shows
  unsaved until then. (Today every edit is written at once: phase 1 or 2 changes that.)
- **Chrome:** the menu bar with the mode bar stays; the design's tool row replaces the editor's
  toolbar in the Level mode (play controls kept at its end); the Levels list replaces the
  project browser there.
- **Colors:** the layout and sizes only; the editor keeps its theme (Settings > Appearance).
- **Several worlds:** supported, with a world picker (Levels sidebar, World tab).

## Code editor integration (asked 2026-10-23; done 2026-10-24)

Built in seven steps: providers, the script index and typed constants; names in strings; code and
scene links; drops; hovers; the running game in the code; engine-aware code actions. CLAUDE.md's
"The project in the code" describes it, the manual's code editor page is the guide. Not doing: a
debugger (DAP), for now.

Also queued (advised 2026-10-23, not yet approved): noticing assets added outside the editor
(scan on project open and window focus; auto-add, mark missing, a Refresh); the Mixer showing a
running game's levels and sending fader/effect edits to it live.

## Later (decided not to build yet)

- **Shader editing in the code editor** (asked 2026-10-22, for later). `.frag` files open in code
  tabs today but are treated as Odin. Four parts:
  1. Send only `.odin` files to OLS: every open document goes to the one shared server as
     `languageId "odin"`, so shaders likely reach OLS too (check what it does with them first).
  2. GLSL syntax highlighting: a GLSL tokenizer in code_editor/syntax (it supports a `Language`
     per file type; only `odin_language` exists), picked for `.frag` / `.glsl`.
  3. glslang's compile errors in the code tab (problems panel, squiggles) on save, not only in
     the Console: no language server needed.
  4. Completion, signature help, hover and diagnostics from a GLSL language server
     (glsl_analyzer, MIT, prebuilt for Linux / macOS / Windows): the code editor host runs one
     server per language instead of one for all tabs, and knows the engine's shader inputs
     (`v_color`, `v_uv`, `u_texture`, the Params block). Undecided: ship it in releases like the
     shader compilers, or use it only when installed (like OLS from PATH).

- **Mobile export targets** (Android, iOS): Odin can target both (`-subtarget:android`,
  `-subtarget:iphone`); needs the Android SDK/NDK here and CI's Mac for iOS (decided
  2026-10-22: later).
- **Steam's real backend**: the Steamworks SDK (a partner download) behind the engine's Steam API
  (built with a stub backend: steam.odin, 2026-10-22).

## Builds and releases

- **macOS bundle signing and notarization**, deferred until the version 1 release (decided
  2026-10-20; the Apple developer account exists). Then CI's
  `combine-macos` signs with the Developer ID (a temporary keychain, hardened runtime,
  `entitlements.plist`) and notarizes and staples the disk image with `xcrun notarytool`,
  falling back to ad hoc without the secrets. The secrets come from a gitignored `.env`
  (`tools/macos/signing.env.example`, `tools/macos/set_signing_secrets.sh`).
