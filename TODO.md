# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

## Code editor integration (asked 2026-10-23; build in this order)

The goal: the best Odin editing experience there is, because the editor knows the project (scenes,
assets, actions, animations, the running game). Code and scene editing should feel like one
environment: no memorizing how to refer to things in code. Everything goes through a small
provider interface in code_editor (completion, hover, diagnostics, gutter, inlay, drop sources)
that the editor fills in, so code_editor stays engine-agnostic. Not doing: a debugger (DAP), for now.

3. **Code ↔ scene links:** find usages in scenes, renaming a script field or type carries into
   scene/component files. (Round 1 already did a marker on `Script_Register` lines listing the
   nodes using it, a click selecting the first, and the inspector following the index as fields
   are typed: build on those.)
4. **Context-aware drag and drop into code:** every editor thing is a drop source (scene-tree
   nodes, inspector property labels, animations, state machine parameters and states, input
   actions, events, scenes, components, sounds, music, dialogues, Timeline clips, buses, groups).
   Where it lands decides the shape (in a struct: a field; in a procedure: a statement; on an
   argument: the constant); a plain drop does the common thing, a menu offers the few useful
   alternatives with a preview. Inserted code uses the typed constants. Sources describe
   themselves and the engine describes which procedures act on which kind, so new node kinds
   get drops with little work. (Round 2's name types already say which parameters take which
   kind of name: the engine's names.odin, read by the editor's name_kinds.odin.)
5. **Hovers and previews:** asset constants show the image / play the sound / show the
   animation's frames / the dialogue's first line; color literals get a swatch and the picker;
   engine procedures show their doc comment and example (the website's docgen output, bundled);
   F1 opens the API page.
6. **Live game state in code:** while playing, inlay hints with the selected node's live field
   values; scrubbing a number literal of an exported default changes the running game (written
   back on demand); log points without editing code (through hot reload).
7. **Engine-aware code actions:** add a handler for this node's event, export this field (with a
   range), generate state machine constants, register this struct as a script, jump from an
   inspector field to its declaration.

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
