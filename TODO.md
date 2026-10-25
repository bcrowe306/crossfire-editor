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

**Built (2026-10-24):** Spall profiling in Skald, the engine and the editor, the editor's harness
(`task profile`, `tools/profile.sh`, `tests/profile/`) and the engine's (`tools/profile_game.sh`),
and the report tool (the engine's `tools/spall_report`). The editor's CLAUDE.md "Profiling" and the
engine's "Profiling with Spall" describe them. **Measure every item below with them**: a
`task profile:baseline` before, `task profile:compare` after (and `profile_game.sh --compare` for
the engine), on a quiet machine (the harness warns when it isn't).

First traces (2026-10-24, the machine busy: load 11-15 on 8 CPUs, so the absolute numbers are
high): the editor at rest on the title scene spent its frame in `measure_text` (31% of the main
thread's self time, 1382 calls a frame), `render_view` (17%), the viewport's `lighting` (15%:
the title scene is lit, 9 ms each render), `draw_text` (13%); the forest level played by the
player spent 61% of its frame in `nodes_update` (8.4 ms a frame), 19% in `present`, 15% in
`nodes_draw`.

### 3. Making Skald faster (each item measured with the harness)

**Done (2026-10-24), measured with `task profile` (Skald's CHANGELOG has the numbers):** text
measurements cached across frames (`measure_text`: 3.7 -> 0.8 ms a frame at rest), stacks
measured once a frame (1383 -> 919 measurements a frame), drawn text's glyphs cached across
frames (`draw_text` 3.2 -> 1.2 us a call). Mean frame against the first baseline: at rest 18.7
-> about 9 ms, the inspector scrolling 21.2 -> 11.2, the Level mode 14.6 -> 3.3, typing in code
11.3 -> 7.2. **Measured and dropped:** pre-sizing the frame arena (frames fit its first 4 MB block
once the text caches were in; it grew only at startup).

**The whole day, measured on a quiet machine** (2026-10-24 evening: the first profiled build,
editor ae9c1c6 / Skald e316589 / engine 5f65b22, against today's, ABBA, four runs each, wall
time): mean frame browser 15.5 -> 10.4 ms, code 12.6 -> 5.4, console 20.6 -> 10.5, at rest
20.6 -> 11.6, inspector 22.2 -> 10.0, Level mode 5.6 -> 2.0, viewport 12.3 -> 5.9 (33-65% less;
p95 31-58% less). With the engine's lighting (GPU renderers add lights straight into the light
map) and font path fix (no lowercase copy per string) besides Skald's caches.

**Measured and dropped:** float-free cache keys (a SPALL_AUTO trace made the map hashers look big;
a microbenchmark put it at 2-4% of a 31 ns lookup).

**Off-screen rows aren't drawn** (2026-10-24): Skald's stacks lay out a child wholly outside
the active clip with drawing suppressed (`Renderer.draw_suppressed`), so its widgets keep their
rects for the reveal code, and hit tests skip widgets not laid out last frame
(`widget_drawn_last_frame`). Mean frame on the CPU clock, ABBA against the build before: browser
5.8 -> 5.3 ms, code 5.9 -> 5.1, console 6.2 -> 5.2, idle 8.9 -> 8.5, inspector 9.0 -> 8.2, Level
mode 3.3 -> 2.8, viewport 4.6 -> 4.2 (5-17% less). Building the culled rows' views is still paid;
item 1 below would skip that.

Left:
1. **Reuse unchanged parts of the tree:** something like `cached(key, version, builder)`, which
   returns last frame's subtree when its version hasn't changed.
2. **The remaining text calls:** about 900 `measure_text` and 500 `draw_text` calls a frame at
   rest, each now a hash and a lookup (0.7-1.2 us); fewer calls (the item above) is what's
   left there. `wrap_text` keeps its lines across frames now (2026-10-25: the inspector's
   0.65 -> 0.19 ms a frame, its median frame 4.6% less). Stacks lay their children out from
   the sizes measuring them found (each label measured about once a frame, not three times:
   `measure_text` a third fewer calls, the frame 11-18% less in every scenario).
3. Offer Skald's general fixes to its upstream (Lee Fry's Skald) when they're done.

### 4. The editor and the engine (found by the same profile)

- **The viewport's lighting** (`Lighting_Apply` in `Preview_Render`, 15% of the editor's
  frame on the lit title scene): render the light map less often, or cache it while nothing
  moves.
- **The engine's node updates** (`nodes_update`, 61% of the forest level's frame): find which
  nodes (a SPALL_AUTO run of `profile_game.sh`), then fix.
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
Save, Play and exports; the menu bar and mode bar kept; the editor's theme; several worlds with a
world picker.

**The user's correction (2026-10-25), done the same day:** "The UI needs to be consistent with
the Scene UI. List items in the panels need to be the same size. Toolbar buttons as well. The
Level editor looks like a different app. That wasn't my intention." The mockup gives the
arrangement only, not its sizes: the Level mode uses the editor's shared widgets and sizes. Its
tools are on the editor's toolbar (the Scene mode's buttons, sizes, overflow, file, undo, play and
Export buttons; no 75 px tool row of 45 px buttons); its Levels and Layers sidebars have the
panels' headers and the scene tree's rows (`settings.rowHeight`, not 60 px rows; a layer dragged
by its row, not a grip), the Scene mode's sidebar widths and fitting (no 300 px sidebars, no
one-sidebar narrow layout). And the bottom tabs that manage a list (World, Level, Layers,
Entities, Enums, Tilesets, Auto-layer Rules; the Project tab without a list) share one layout,
the user's sketch: the tab strip, a toolbar row (the list's buttons and a text), then the list in
a resizable sidebar beside the selected item's settings in the inspector's rows (a dropdown in a
narrow panel): view_list_tab.odin.

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
