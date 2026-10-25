# TODO

Work that's decided but not built, for the editor and the engine (odin_sdl_engine). Newest
sections first. When something is done, delete it here and describe it in the CLAUDE.md that
owns it.

## Performance: Spall profiling, a harness, a faster Skald (asked 2026-10-24)

The user decided to make Skald faster rather than move the editor to Dear ImGui. Work is
**measured first**: every change is profiled before and after with the harness below. Skald
changes are committed in the Skald fork (`bcrowe306/Skald`; then the editor's submodule is bumped),
engine changes in odin_sdl_engine.

**Baseline (2026-10-24):** the editor built with `-o:speed`, `examples/demo_project`, Scene mode,
`--window-size 1680x1000`, `SKALD_BENCH_FRAMES=1500 SKALD_BENCH_UNCAP=1` (every frame drawn).
Two runs: median 4.5-7.0 ms, p95 12-19 ms, p99 15-27 ms, worst 106-230 ms. Skald's own
`00_gallery` is at 1.2 ms. A rough profile (160 main-thread stacks sampled through gdb; `perf`
isn't installed) put about 45% of the frame in **measuring text** (`view_size` → `measure_text` →
`runa::layout_paragraph`), 15% drawing text, 12% the viewport (`Preview_Render`: the scene,
lighting), 13% waiting on the GPU (`drmSyncobjWait` under `SDL_SetRenderTarget`), 11% allocation
(the temp arena growing through the heap, `mmap`/`munmap`), 3% the editor's `view`.

### 1. Spall profiling (first: everything after it is measured with it)

- **Instrumentation in all three code bases** (Skald, the editor, the engine), compiled out
  unless asked for: a `when` constant from `-define:SPALL=true`, so normal builds pay nothing.
  - Named scopes (a deferred begin/end pair, e.g. `prof_scope("render_view")`) at the places
    that matter: Skald's frame phases (pump, view, layout, measure, draw, `frame_end`), the
    editor's panels and `update`, the engine's `Scene_Update`, physics, drawing, lighting,
    particles, audio.
  - Whole-program captures with Odin's automatic instrumentation
    (`@(instrumentation_enter)` / `@(instrumentation_exit)`) for finding hot spots the scopes
    don't name. Check how much it slows things down; use it to find, scopes to measure.
  - `core:prof/spall` with a buffer per thread (the editor's workers: script index, OLS
    reading, imports), written to a `.spall` file at exit.
- One small shared package, or the same few procs in each repo: Skald and the engine must not
  depend on each other. Decide which when building it.
- Documented in each repo (CLAUDE.md, the manual, the engine's docs on the website): how to
  build with profiling, capture, and open a trace in Spall.

### 2. A profiling harness (runs without a person, and without being disturbed)

So Claude can measure, change and measure again on its own, and the numbers can be compared:
- **A fixed scenario:** a copy of a fixed project in a temporary folder (the demo's files
  never change), a separate settings file and recent-projects list (`--settings`; the user's
  own are never touched), a fixed window size and DPI scale, and a UI test script
  (`--script`, `test_driver.odin`) that drives the same steps every run: open panels, select
  nodes, scroll the inspector and browser, type in the code editor, switch modes, paint
  tiles, play.
- **No interference from the desktop:** no window, no focus taken, no input from the user's
  mouse and keyboard, no resizing by Hyprland. Run it the way `tools/ui_tests.sh` runs the
  headless UI tests: `SDL_VIDEO_DRIVER=offscreen` (Vulkan through
  `VK_EXT_headless_surface`, on the real GPU), `SDL_AUDIO_DRIVER=dummy`, `--window-size`.
  Check that the numbers match a visible window's (the swapchain path may differ). The
  driver's `frame_times <frames>` command already exists; build on it.
- **Stable numbers:** warm-up frames dropped, several runs with the median reported, the CPU
  pinned (`taskset`), every frame drawn (`SKALD_BENCH_UNCAP`), optimized builds.
- **Readable results without the Spall UI:** a small Odin tool that reads a `.spall` file and
  prints the totals per scope (count, total, self time, the slowest ones) and the frame-time
  statistics, as text and as JSON.
- **Comparison:** the results of a run saved as a baseline (per machine, gitignored); a run
  compared against it prints what got faster or slower, and fails past a threshold, so a
  change can't quietly make things worse.
- **Tasks:** `task profile` (the editor's scenario), `task profile:compare`, and the same for
  Skald's examples and for the engine. Each scenario documented with what it covers.
- **The engine too:** game scenarios that run without the editor for a fixed number of fixed
  steps with a fixed random seed (the asteroids sample, many nodes, physics, particles,
  lighting, an LDtk level, labels), profiled with Spall; alongside the existing
  `bench/main.odin` microbenchmarks, which stay.

### 3. Making Skald faster (each item measured with the harness)

1. **Cache text measurements across frames:** key on the text's content, size, font and DPI
   scale; drop entries not used for a few frames. `measure_text_runa`
   (`Skald/skald/text_runa.odin`) lays out the paragraph again (bidi, line breaking, per-glyph
   sums) for every label on every frame; only shaping is cached today. Expected to save
   35-40% of a frame.
2. **Measure each view once per layout pass:** `view_size` (`Skald/skald/layout.odin`) is called
   again at each level of nesting, so text deep in the tree is measured many times. Keep the
   measured size per node for the rest of the pass.
3. **Pre-size the temp arena** (or keep its blocks) so it stops allocating from the heap every
   frame.
4. **Don't build or lay out what's off-screen:** scrolling panels (the inspector, the browser
   tree, long lists) skip rows outside the visible area, as `virtual_list` already does.
5. **Reuse unchanged parts of the tree:** something like `cached(key, version, builder)`, which
   returns last frame's subtree when its version hasn't changed.
6. **Text drawing** (15%): look again once the measuring is cached (the same layout work
   probably happens again when drawing).
7. Offer Skald's general fixes to its upstream (Lee Fry's Skald) when they're done.

### 4. The editor and the engine (found by the same profile)

- **The viewport:** don't render the scene again in `Preview_Render` when nothing changed
  (`sceneSignature` in `viewport_preview.odin` already exists), and find the GPU wait under
  `SDL_SetRenderTarget` (13% of a frame).
- **The engine:** profile the game scenarios above and fix what they show (drawing, lighting,
  physics, particles), with numbers before and after in the engine's CLAUDE.md "Performance"
  section.

## LDtk level editor: parity with LDtk (asked 2026-10-24; done 2026-10-25)

Built in five phases, each its own release: the layout (the user's design, `LDtk_interface.html`),
painting, the definitions editors, the auto-layer rules, and levels, worlds and the project
(phase 5: levels made, copied, resized, deleted; worlds and layouts; every project panel option and
LDtk's save outputs; LDtk's selection; field values drawn on the canvas; saved tile selections;
LDtk's panel and layer keys). Everything is written as LDtk writes it, checked against LDtk's own
samples. CLAUDE.md's "Editor modes" sections describe it; the manual's level pages are the guides,
and `docs/manual/level_parity.md` checks every LDtk 1.5.3 feature (429: 305 done, 60 done
differently, 41 not done, 23 not applicable).

**Open, from the parity audit** (none needed to edit levels; LDtk opens the same file meanwhile):
- Bake an auto-layer into a Tiles layer (EditLayerDefs.bakeLayer: delete, empty or keep the
  original); move existing entities to another layer (MoveEntitiesBetweenLayers).
- A definitions clipboard between projects (LDtk's system clipboard of layers, entities, enums,
  tilesets, fields), and LDtk's confirmations (undo stands in today).
- A command palette (definitions, levels, entities, searchable field values).
- Palettes: keyboard navigation (WASD / arrows, saved selections), IntGrid and entity palettes'
  columns view and search, the rule editor's value palette columns.
- View toggles: show details (tiles only), tiles' enum tags drawn, a drag across layer eyes,
  Shift + click solo, the layer list's tag filter, a layer's documentation as a tooltip, LevelTile
  fields drawn in the world view, the world view on zooming out, zoom keys and Space + right drag,
  the pointer's coordinates in a footer, a flash on picked elements.
- Speed: the release hitch on huge levels (the document parsed again: about 120 ms at 6.5 MB);
  rule edits applied in the focused level first and the others in the background.
- Files: images (tilesets, backgrounds) reloaded when they change on disk; lost files relocated;
  renaming the project (its levels' folder too); restoring a backup; Ogmo 3 import.
- The rule editor's per-control help tips (one help text today).

The user's decisions (2026-10-24), kept: phases each released; LDtk's tools adapting to the layer
type; LDtk's panels as the bottom tabs (Console and Output at the end); edits in memory, written on
Save, Play and exports; the menu bar and mode bar kept, the tool row replacing the toolbar; the
editor's theme; several worlds with a world picker.

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
