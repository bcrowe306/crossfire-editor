# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

## UX round 3 (asked 2026-10-23)

3. **Clickable errors in the code editor:** compile errors (Output tab, Console, the problems
   panel) open the file at the line and column in a code tab.
8. **Restart** on the toolbar beside Play / Pause / Stop: stops the running game and plays it
   again (rebuilding scripts when they changed).

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
