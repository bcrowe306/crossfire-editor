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

## LDtk level editor: parity with LDtk (asked 2026-10-24; build in phases, each released)

**Phase 1 done (2026-10-24):** the Level mode in the design's layout with what existed (the tool
row with LDtk's tools per layer type, Select working, painting greyed out; the Levels and Layers
sidebars; focus; several worlds; LDtk's panels as the bottom tabs; narrow windows), and the
saving switch: edits in memory, written on Save, Play, exports and Open in LDtk, LDtk's saves
merged or asked about. CLAUDE.md's "The Level mode: LDtk's layout" and "Editing LDtk projects"
describe it, the manual's level_mode.md is the guide.

**Phase 2 done (2026-10-24):** painting the focused level as LDtk does, its buttons and keys
(labelled, in settings.default.ini): IntGrid values (Pencil, Rectangle, Fill, Eraser, Picker, the
palette), auto-layers worked out by LDtk's rules ported (identical to LDtk's samples), tiles
(stamps, random, flips, stacking, the tileset palette), entities (placed from the palette,
selected, moved, resized, copied with Ctrl + Alt + drag or Ctrl+D, removed; count limits; points
dragged and references and points picked on the canvas), grid lines, the brush's preview, layer
opacities and single layer mode; one undo step a stroke (big files' steps keep only hunks),
saved on Save. CLAUDE.md's "Painting in the Level mode" describes it (with the performance
numbers), the manual's level_mode.md "Painting" is the guide. Left for later phases or not
built: LDtk's grid-cell selection tool (select, move and copy rectangles of cells), saved tile
selections, rule groups toggled from the canvas, picking references in another level, field
values drawn on the canvas (LDtk's field display modes), NineSlice / Repeat tile render modes (drawn approximately), a release
hitch of about 120 ms on a 6.5 MB level (the document's text parsed again).

**Phase 3 done (2026-10-25):** the definitions editors, LDtk's panels in the bottom tabs: layers
(made by type, copied, deleted, reordered; every setting; grids remapping every level's cells;
IntGrid values and groups with their tiles; tilesets, auto-layer sources, kill layers, biomes;
entity tags), entity types (presets, size, resizing limits, pivot, look, render modes and tiles,
9-slices, limits, tags, table of contents) and their fields (every type, single or array; defaults,
ranges, nullability, regexes, file types, languages, tilesets, reference rules, display; type
conversions), enums (values, colors, icons, tags; external enums from text, JSON, Haxe and
CastleDB files, synced), tilesets (from the project's images, grid, spacing, padding, tags, a tag
enum, tiles tagged and given custom data on their picture, LDtk's internal icons), level fields
(the Level tab). Every level kept in step by LDtk's tidy, ported (a no-op on all of LDtk's
samples); new definitions in LDtk's key order; tilesets' pixel data byte-identical to LDtk's; one
undo step each. CLAUDE.md's "The definitions editors" describes it, the manual's
level_definitions.md is the guide. Not built here: copy / paste of definitions between projects
(LDtk's clipboard), LDtk's "bake" of an auto-layer into a Tiles layer, moving entities between
layers (MoveEntitiesBetweenLayers), confirmations before deleting used definitions (undo instead),
the IntGrid values' drag between groups (a group choice and Up / Down instead).

**Phase 4 done (2026-10-25):** the auto-layer rules, LDtk's rule panel and rule editor as the
Auto-layer Rules tab's pages: groups (added empty or by the Rule Assistant, renamed, deleted,
copied, cut and pasted, duplicated, duplicated and remapped, dragged into place, on and off,
opened and closed, colors, icons, every rule's out-of-bounds policy, biomes with AND / OR,
optional and turned on per level: the phase 2 leftover), rules (added before or after, deleted,
copied, cut and pasted across groups and layers, duplicated, dragged into another group, on and
off) and their editor (tiles one by one or as stamps with a pivot, picked on the tileset; the 9 x 9
pattern with LDtk's three buttons and drags, values, groups, any / none; the out-of-bounds policy;
chance, opacity, break on match, mirrors, modulos with offsets and the checker, tile offsets and
linked random offsets, Perlin with its preview on the level), the Rule Assistant (LDtk's 47 wall
parts, mirrored parts, stacking; editing its groups again, Advanced mode), Randomize, Render, the
level's own tileset. Every edit written as LDtk's toJson writes it (its rule tidy ported), then its
tidy and the rules applied again in every level; the canvas outlines a hovered rule's or group's
cells and the tab highlights the rules of the cell under the pointer; one undo step each. Checked
against LDtk: every sample group written back byte for byte, edits undone by their opposite give
LDtk's sample files back byte for byte (tiles included), the Assistant remakes LDtk's sample
group. CLAUDE.md's "The Auto-layer Rules tab" describes it, the manual's level_rules.md is the
guide. Not built: LDtk's color wheel (its palette or a typed color instead), the value palette's
column layouts, the editor's per-control help tips (one help text instead), the system clipboard
(the editor's own, like LDtk's), an empty new rule removed when its editor closes.

**Left for phase 5's parity audit** (from phases 2 to 4): LDtk's grid-cell selection tool
(select, move and copy rectangles of cells); saved tile selections (TilesetDef.savedSelections:
kept and remapped, not made); picking references in another
level; field values drawn on the canvas (LDtk's display modes: they're set, not drawn); NineSlice
and Repeat tile render modes drawn exactly; the release hitch on huge levels (the document parsed
again, about 120 ms at 6.5 MB); definitions copied, pasted and baked as above; the project's
settings (identifier style, default sizes, flags, separate level files) in the Project tab; from
phase 4: a color wheel for groups, the rule palette's column layouts, per-control help tips, rule
edits applied in the focused level first and the others in the background (every level of the
layer is evaluated again per edit today), the rules' tile picker's saved selections.

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
  unsaved until then. (Done in phase 1.)
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
