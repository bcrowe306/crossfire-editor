# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

## Round 4 features (asked 2026-10-24; build in this order)

The user's decisions (2026-10-24): Level mode is a world/level editor (we'll eventually build our
own editor for the LDtk format); LDtk editing writes back into the .ldtk file; docs open in an
in-app popup rendering the bundled markdown (offline, with a link to the same page on
crossfireengine.io); "Handle event" code actions keep subscribing in ready code. Docs in the
editor (asked as items 2 and 4) is done (2026-10-24): CLAUDE.md's "Docs in the editor".

1. **Editor modes: a top tab bar** (item 7). The current app becomes the **Scene** mode; a second
   mode, **Level**, is a world/level editor; the structure allows more later (3D, pixel editor).
   Each mode owns its layout; shared pieces (menus, toolbar's play controls, project browser,
   Console) stay sensible across modes; the mode is remembered per project.
2. **Level mode and the LDtk tab** (item 3). Level mode: the LDtk world on a big canvas (levels
   placed, linked, opened), with the LDtk panels. A bottom **LDtk** tab: a left sidebar of
   vertical tabs (Layers, Entities, Collisions, Links, Level fields, Enums, World), the selected
   item's settings in the content area. Edits **write back into the .ldtk file** (kept valid
   against LDtk's schema; LDtk's saves reload in the editor), undoable. Tighter integration with
   LDtk itself (open at the level/entity, reload on save). Groundwork for our own LDtk-format
   editor later.
3. **State machines** (item 1): transition logic and exit guards, in code (the engine API:
   conditions, guard procedures a script provides, can-exit checks) and in the GUI (the States
   tab's graph plus a **right sidebar** showing the selected state's or transition's
   properties: conditions, guards, priorities, on-enter/exit, animation).
4. **A Particles bottom tab** (item 6): a left sidebar of vertical tabs for the particle settings'
   categories (the engine's `group` tags), the selected category's settings in the right content
   pane, for the selected ParticleEmitter.
5. **A sprite sheet slicer** (item 5): its own viewport tab; slice a sheet by grid (cells or
   cell size, margin, gap) or by auto-detecting sprites, pick frames, name animations, and load
   them into an animation asset and/or an AnimatedSprite (the animation player).

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
