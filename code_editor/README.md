# odin_editor

A modular, embeddable code editor for Odin + SDL3 projects, with VSCode/Zed-style
editing, Odin-aware syntax highlighting, and an embedded
[Odin Language Server (OLS)](https://github.com/DanielGavin/ols) client for
completion, signature help, and diagnostics.

See `REQUIREMENTS.md` for the full feature scope this module implements.

## Package layout

```
odin_editor/
  buffer/     text buffer core: lines, cursors/selections, undo/redo, file IO
  keymap/     platform-aware hotkey table (VSCode/Zed-equivalent defaults)
  syntax/     pluggable tokenizer; ships an Odin-language highlighter
  lsp/        JSON-RPC client implementing the LSP subset OLS needs
  editor/     SDL3 glue: input, actions, rendering, clipboard, file API,
              completion/signature-help popups, event injection hook --
              this is the package a host embeds
  control/    remote-control hook: localhost TCP server that pushes real SDL
              events into a running host app, reports state, takes screenshots
  example/    standalone SDL3 demo/test app (package main)
  tools/edctl command-line client for the control hook (package main)
  third_party/ols  fetched on demand by `task ols:fetch`/`ols:build`, not vendored
```

Every package except `editor` and `example` is SDL-independent and unit
tested on its own (`buffer`, `keymap`, `syntax`, `lsp`). `editor` depends on
`vendor:sdl3`/`vendor:sdl3/ttf` for input translation, clipboard, and
rendering, but its logic (action dispatch, viewport math, event injection)
is still unit tested without needing a real window.

## Building & testing

This project uses [Task](https://taskfile.dev) (`brew install go-task` or
see their install docs). From inside `odin_editor/`:

```sh
task check          # odin check every package (fast type-check)
task test           # unit tests, all packages in parallel (~4 s)
task test:all       # check + unit + e2e + full visual suite (before merging)
task test:e2e       # in-process end-to-end suite (real window, real OLS if built)
task test:visual    # visual UI tests: drive the running demo via the control hook,
                    # verify state, save screenshots + gallery (needs OLS);
                    # SUITE=find_smoke runs one script (~2 s)
task build          # build the standalone example app
task build:edctl    # build the control-hook CLI client (tools/edctl/edctl)
task run            # build & launch the standalone example app
task fmt             # odin fmt every package
task ols:fetch       # clone OLS and check out a known-compatible commit
task ols:build       # build the `ols` binary (needed for live LSP features)
task clean           # remove build outputs
```

You can also drive each package directly without Task:

```sh
odin check buffer -no-entry-point
odin test buffer -define:ODIN_TEST_THREADS=1
odin build example -out:/tmp/odin_editor_demo
```

## Embedding in a host application

```odin
import ed "odin_editor/editor"
import km "odin_editor/keymap"

editor := ed.editor_init(km.Platform.MacOS) // or .Other for Win/Linux
defer ed.editor_destroy(&editor)

// Cell width + font line height; rows get editor.line_spacing (1.4).
ed.editor_set_font(&editor, char_w, glyph_h)
// Pixel size of the editor area (header + gutter accounted for); call
// again on resize.
ed.editor_set_viewport(&editor, width, height)

ed.editor_load_file(&editor, "some/file.odin")
// Optional: persist keymap/theme edits there (loads them now).
ed.editor_set_config_dir(&editor, "~/.config/my_app/editor")

// per frame:
for sdl.PollEvent(&event) {
    ed.editor_handle_event(&editor, event)
}
ed.editor_update(&editor)           // polls LSP responses, drains injected events
ed.editor_render(&editor, renderer, font, x, y) // uses editor.theme (editor_set_theme)
```

Text is drawn through SDL_ttf's renderer text engine: one glyph atlas per renderer, made on
first use, so each glyph is uploaded once (a GPU renderer, such as SDL's Vulkan one, would
otherwise upload and wait for a texture per run of text). Free it before destroying the renderer:

```odin
ed.editor_forget_renderer(renderer)
sdl.DestroyRenderer(renderer)
```

Save/load is a plain API the host drives explicitly — there is no global
editor state, so multiple `Editor` instances can coexist (e.g. multiple open
tabs/panes), each owning its own buffer, keymap, and (optionally) its own
LSP client instance via `editor_attach_lsp`.

### Providers: what the host adds to the language server

A host knows things OLS doesn't (its project's assets, scenes, which code is used where). It
adds them through **providers** (`editor/providers.odin`): plain procedures with a user-data
pointer, so the editor stays independent of any host. Register them once in a
`Provider_Registry` the host owns, and point every editor at it:

```odin
reg: ed.Provider_Registry
ed.provider_register(&reg, ed.Provider{kind = .Completion, name = "project", completion = my_completions, user_data = &my_data})
ed.provider_register(&reg, ed.Provider{kind = .Gutter, name = "users", gutter = my_markers, on_click = my_marker_clicked})
ed.editor_set_providers(&editor, &reg)
// when the host's own data changed (re-run diagnostics, gutter and inlay providers):
ed.provider_registry_invalidate(&reg)
```

Every provider gets a `Provider_Document` (path, the read-only `^buf.Buffer`, its version), a
position where it applies, and a `Provider_Context` (why it's called, the typed prefix and
character for completion, the `Syntax_Context` of the position, its user data, and
`ctx.allocator`, the frame's temp allocator: the editor copies what it keeps).

| Kind | Procedure | When it's called | What it gives, and how it's merged |
|---|---|---|---|
| `.Completion` | `Completion_Provider_Proc` | each completion request (typing, Ctrl+Space), and a typed character of the provider's `trigger_chars` (`"\"/"`: then only the providers are asked, the server's last items aren't listed) | `Provider_Completion`s, merged with the server's list: the server's in its order, then the providers' that aren't already there. A provider item with a server item's label folds into it (the server's insert text stays, the provider's documentation is added, the higher `priority` taken); the first provider to offer a label wins. Within prefix and fuzzy matches, higher `priority` first. Without a server, the providers' items show at once. `replace_start` replaces from another column than the typed word's start (a path, a name with spaces; the list still filters by the word, so `filter_text` is the label from there) |
| `.Hover` | `Hover_Provider_Proc` | the pointer resting on a cell (the server is asked at the same time) | `Hover_Content`: blocks of `Hover_Text` (plain or markdown), `Hover_Image` (RGBA8 pixels, drawn at most `HOVER_IMAGE_MAX` px tall and twice that wide: a strip of frames) or `Hover_Widget` (a size, a `draw(renderer, rect, data)` the host paints, and an optional `click(x, y, data)`: a left press on it calls it with the point in the block and the hover stays open, a play button), shown above the server's answer; `replace_server` says the blocks stand in for it (an engine procedure's documentation): the server isn't asked and nothing of its shows |
| `.Diagnostics` | `Diagnostic_Provider_Proc` | once per text version, after it's been still for `PROVIDER_DEBOUNCE`, and when invalidated | `Provider_Diagnostic`s (buffer positions), merged with the server's: squiggles, gutter, Problems panel, F8. One the server reports on the same line with the same message isn't repeated. They move with edits until the provider runs again, their `fixes` (`Provider_Fix`: a title, edits, `preferred`) too: Ctrl+. lists the fixes of the diagnostics at the caret (else on its line) before the server's code actions, at once and without a server |
| `.Gutter` | `Gutter_Provider_Proc` (+ `Gutter_Click_Proc`, `Gutter_Line_Proc`) | as diagnostics | `Gutter_Marker`s (line, `Gutter_Icon`, color, tooltip, an id, `choices`): drawn in the marker column (a diagnostic's mark wins), the tooltip on hover, the `on_click` of **the provider that gave the marker** called with it; a marker with several `choices` opens a menu of them first (the code actions menu, keys and clicks as there) and `on_click` gets the one picked in `marker.choice`. A click in the marker column of a line **without** a marker calls the gutter providers' `on_gutter_line` until one takes it (setting something there: a log point); `editor_marker_column_point` gives the column's place (hosts' tests) |
| `.Inlay` | `Inlay_Provider_Proc` (+ `Inlay_Click_Proc`) | as diagnostics | `Inlay_Hint`s (position, label, `Inlay_Kind`, an optional `swatch` color, an id, `clickable`, `choices`): drawn dimmed after the line's text (hints that move the text are for later), a swatch as a square of its color (`INLAY_SWATCH_COLS` cells, a checkerboard under see-through ones) before the label; a left click on a swatch, or on a `clickable` hint's label (drawn with a frame), calls the provider's `on_inlay_click` with the hint; a clickable hint with several `choices` opens a menu of them first and the callback gets `hint.choice`. The hints count in the scrollable width (`editor_max_visual_width`), so a narrow editor scrolls to them; `editor_inlay_swatch_point` / `editor_inlay_label_point` give their places (hosts' tests) |
| `.Scrub` | `Scrub_Target_Proc` + `Scrub_Proc` (+ `Scrub_Choice_Proc`) | an Alt+press on the text (`providers_scrub.odin`) | `scrub_target` says whether the number at the position can be scrubbed (`Scrub_Target`: the literal's range, the value to start from, a step (0: from the literal), decimals, `min` / `max`, whole numbers). Dragging sideways past `SCRUB_THRESHOLD` px moves it a step every `SCRUB_PIXELS_PER_STEP` px (at an 8 px cell; Shift: a tenth of a step), rounded and in range (`scrub_step`, `scrub_value`, `scrub_format`); `on_scrub` hears each new value (`.Change`) and the release (`.End`), when it may append choices: they open in the code actions menu and the one picked goes to `on_scrub_choice`. **The buffer isn't edited**: the value is drawn over the literal while dragging, the pointer is `Mouse_Cursor.Scrub`; an Alt+click that doesn't move still toggles a cursor. Hosts keep feeding it the mouse outside the editor while `editor_scrub_held` |
| `.Menu` | `Menu_Items_Proc` + `Menu_Item_Proc` | the right-click menu opening | labels for the position clicked (the caret's), listed after the editor's own entries and a separator; `on_menu_item` gets the index picked (`Menu_Item.provider` / `index`) |
| `.Usages` | `Usages_Provider_Proc` (+ `Usage_Open_Proc`) | Find Usages (Alt+Shift+F12, the context menu's Find Usages in Project) | `Usages_Result`: the symbol and `Provider_Usage`s (a location label, a preview, an id), listed in the references panel in the provider's order; picking one (click, Enter, F4) calls `on_open` with it. The first provider returning true answers; none: "No usages to find here" |
| `.Rename` | `Rename_Prepare_Proc` + `Rename_Proc` | Rename Symbol (F2, the context menu) | `prepare_rename` says what's at the caret (`Rename_Target`: the name's range, a title, a note on what else changes) and the rename box opens; on Enter `rename` gets the new name (an identifier: the editor checks) and returns `Rename_Result`: this document's edits (one undo step, which undoes to one caret), a status message, or an `error` that keeps the box open. No provider takes it: the server's `textDocument/rename` |
| `.Drop` | `Drop_Provider_Proc` | `editor_drop(ed, x, y, request)` / `editor_drop_at`, when the host drops something | the `Drop_Request` (the host's kind, value, data, and `menu`: the host's Shift) and where it landed; the first provider returning true decides: `Drop_Result.edits` (applied as one undo step, the server told), the caret, a message, and its `choices` (`Drop_Choice`: a title, edits, a caret, a preview of the code, a message; the plain drop's first). A plain drop applies `edits` (none: the first choice); with `menu` and two or more choices, the code actions menu lists them with the selected one's preview beside it (Up/Down, Enter or a click picks one as one undo step, Escape drops nothing; `editor_take_drop_message` gives the host the picked one's message once) |

**Keep providers fast and non-blocking:** they run on the editor's thread. Look things up in data
the host already has; do slow work on the host's own worker and invalidate when it's done.
`editor_provider_stats(ed)` gives each provider's calls and last and slowest times.

**The syntactic context** (`editor_syntax_context_at(ed, pos)`, `Syntax_Context`): from the
buffer and the language's tokenizer, no parse, so it works on half-typed code. `kind` is
`Top_Level`, `Struct_Body` / `Enum_Body` / `Union_Body` (with the type's `name` and its braces),
`Proc_Body` (`proc_name`: a declaration's name or a literal's field, `ready = proc...`;
`proc_params`: its parameter list as written, `self: ^Hero`),
`Call_Argument` (`call_name` as written, `e.Node_FindPath`, the `argument` index and where it
starts) or `Comment`; `in_string` says the position is inside a string literal (a call's string
argument is `Call_Argument` with it set; right at the end of one not closed yet counts), `in_proc`
whether any procedure encloses it.

**Rename Symbol** (`editor/rename.odin`): F2 opens a box under the name (the provider's title and
note, or "Rename <name>" for the server), typing replaces the selected name, Left/Right/Home/End,
Backspace/Delete, Ctrl+A, Ctrl+V edit it, Enter renames, Escape or a click elsewhere cancels.
Through the server, the edits to this document are applied as one undo step and those to other
files are kept for the host (`editor_take_file_edits`: UTF-16 ranges by path), which applies them
where those files are open (`editor_apply_lsp_edits`). The control snapshot has `rename`
(`open`, `text`, `title`, `note`, `error`, `waiting`), and `code_actions.preview` (a drop menu's
selected choice's code). Edits applied by `editor_apply_edits`
(drops, fixes, renames) undo and redo to one caret, not one per site
(`buffer_group_single_caret`).

Tests: `editor/providers_scrub_test.odin` (the scrub's step, value and text; an Alt+drag's values,
the buffer untouched, the release's menu and the pick, an Alt+click still adding a cursor; a menu
provider's entries; a gutter line click; a clickable hint's menu); `editor/providers_previews_test.odin` (a hover widget's click keeping the hover, a strip's
size, a provider standing in for the server, swatch inlays and their clicks);
`editor/providers_test.odin`'s `test_provider_drop_choices_and_their_menu` (the plain
drop, the menu, its previews, a pick, one undo step); `editor/providers_links_test.odin` (a marker's menu, Find Usages, the rename box with a
provider and through a server); `editor/providers_test.odin` (merging and ranking, without a server, hovers and gutter
tooltips and clicks, diagnostics merged, shifted and debounced, syntax contexts, drops),
`editor/providers_names_test.odin` (quick fixes in the Ctrl+. menu with and without a server,
moved by edits; trigger characters; `replace_start`; a string being typed).

### Event injection hook (automated testing / scripting)

`editor` exposes `editor_inject_key`, `editor_inject_text`,
`editor_inject_event`, and `editor_pump_injected_events` so a host, test, or
demo script can drive the editor deterministically without a real display or
input device:

```odin
ed.editor_inject_text(&editor, "hello world")
ed.editor_inject_key(&editor, sdl.K_HOME)
ed.editor_pump_injected_events(&editor)
```

`example/main.odin` demonstrates this via `--script` / `--script-only` CLI
flags (see below), and `example/e2e.odin` (`task test:e2e`) uses it for the
full end-to-end suite, including live OLS completion/signature-help checks.

### Remote control hook (drive a running app from outside)

The `control` package lets an external process drive a *running* host app
over a loopback TCP socket. Commands become real SDL events pushed with
`sdl.PushEvent`, so they arrive through the host's own `SDL_PollEvent` loop
exactly like physical keyboard/mouse input (host-level shortcuts included).
It can also dump state as JSON, block until a condition holds, assert on
state, and save PNG screenshots. Hosting it takes three calls:

```odin
import "odin_editor/control"

srv: control.Server
control.server_start(&srv, 7777, window, platform) // binds 127.0.0.1 only
defer control.server_stop(&srv)

// per frame:
control.server_poll(&srv, &editor)                   // before SDL_PollEvent
for sdl.PollEvent(&event) { ... }
ed.editor_update(&editor)
ed.editor_render(&editor, renderer, font, theme, 0, 0)
control.server_after_render(&srv, &editor, renderer) // before RenderPresent
sdl.RenderPresent(renderer)
```

Run the demo with the hook and talk to it with `tools/edctl`:

```sh
task build build:edctl
./example/editor_demo --control 7777 path/to/file.odin &
./tools/edctl/edctl --port 7777 --retry 10 \
    "wait lsp-ready 10000" "cursor 9 0" "type fmt." "wait completion" \
    "expect completion-has println" "screenshot /tmp/popup.png" state
./tools/edctl/edctl --port 7777 < tools/lsp_smoke.edctl   # or a script file
```

A `<where>` is either window pixels (`x y`) or a target resolved against the
live editor, so scripts don't depend on font size or scrolling: `@line:col`
(caret position, 0-based), `@gutter:line`, `@completion:row`, `@problem:index`, or `@find:query|replace|case|word|regex`. Targets
scrolled out of view are rejected with `err` rather than clicking elsewhere.

Protocol: one command per line, exactly one reply line per command (`ok …`,
`err <reason>`, `fail expected … got …`, `timeout <cond>`, or JSON for
`state`). A client's commands run in order; a command that pushes events
holds the next one until the following frame, so `state`/`wait`/`expect`
always observe the result of the input before them.

| command | effect |
|---|---|
| `key <chord> [n]` | press a key `n` times. Chords: `primary+space`, `shift+end`, `down`, `cmd+s`, `.`; `primary` = Cmd on macOS, Ctrl elsewhere |
| `key @<action> [n]` | press whatever chord the editor's keymap binds to an action on this platform (`key @replace`, `key @SelectNextOccurrence`) — keeps scripts portable |
| `click <where> [clicks=N] [mods=…] [button=…]` | click (N=2/3 sends a real double/triple-click sequence); `mods=shift+alt` holds those keys around it |
| `mousedown`/`mouseup <where> [opts]`, `move <where>` | individual button / motion events |
| `drag <from> <to> [steps=N] [mods=…] [clicks=N]` | press, N interpolated motions, release (`clicks=2` = word drag) |
| `wheel <dy> [dx=N] [at=<where>] [mods=…]` | scroll at a position (`mods=shift` = horizontal) |
| `locate <where>` | print the pixel a target resolves to |
| `lsp-kill` | SIGKILL the language server (crash-recovery testing) |
| `wait diagnostics` / `wait no-diagnostics` / `wait tooltip` / `wait code-actions` | block until the document has (no) diagnostics / the diagnostic tooltip shows / the quick-fix menu has the server's answer |
| `type <text>` | one TEXT_INPUT event per character (like real typing, so `.`/`(` triggers fire) |
| `text <text>` | a single TEXT_INPUT event with the whole string. Escapes: `\n` `\t` `\\` |
| `cursor <line> <col>` | place the cursor directly (0-based) |
| `open <path>` | `editor_load_file` |
| `state` | JSON: text, cursor, LSP status, completion items/selection/rect, signature label/active parameter/rect |
| `wait <cond> [ms]` | block until `completion`, `no-completion`, `signature`, `no-signature`, `lsp-ready`, `lsp-idle` or `lsp-down` (default 5000 ms) |
| `wait frames <n>` | block for `n` frames |
| `expect <field> <value>` | assert `line`, `cursor`, `text-contains`, `completion-selected`, `completion-has`, `signature` (label contains), `signature-param`, `selection` (`l1 c1 l2 c2` or `none`), `selected-text`, `cursors`, `mouse-cursor` (`text`/`default`), `scroll` (`line col`), `lsp-status`, `errors`, `warnings`, `diagnostics-has`, `line-severity` (`<line> error\|warning\|info\|hint\|none`), `tooltip` (contains, or `none`), `problems-open`, `problems-has`, `actions-has` or `diag-range` (`l1 c1 l2 c2`) |
| `screenshot <file.png>` | save the next rendered frame |
| `quit` | push SDL_EVENT_QUIT |

`--control-only` makes the demo accept input *only* from the hook: the window
is created non-focusable and real keyboard/mouse events are dropped
(`control.event_is_injected` tells them apart), so a scripted run can't be
disturbed by — or steal — the user's typing. `task test:visual` uses it.
The hook is opt-in and listens on loopback only; don't enable it in builds
you ship.

## Diagnostics

Errors and warnings from `textDocument/publishDiagnostics` are drawn as a
severity marker in the gutter and a wavy underline under each range (red
error, yellow warning, blue info, dotted grey hint). Resting the mouse on an
underlined character or a gutter marker for 350 ms shows the message(s) in a
tooltip; **F8 / Shift+F8** jump to the next/previous problem and show it
(Escape or moving the caret dismisses). `editor_diagnostic_counts(ed)` gives
per-severity totals for a host's status bar — the demo puts them in the
window title.

Diagnostic tags are honoured: *unnecessary* code (e.g. an unused import)
is drawn faded, *deprecated* code struck through. **Ctrl/Cmd+.** asks the
server for quick fixes (`textDocument/codeAction`) at the caret and shows
them in a menu (preferred first; Enter/click applies the edit as one undo
step); a host's providers' fixes for their diagnostics there come first
(see Providers). **Ctrl/Cmd+Shift+M** toggles a Problems panel docked at the bottom
listing every file's problems; clicking one jumps there — for another file
the editor raises a request the host services
(`editor_take_open_request` + `editor_load_file` +
`editor_goto_lsp_position`; see `example/main.odin`). Between server
publishes, diagnostics move with your edits (the buffer keeps an opt-in
change log), so squiggles stay on the code they describe.

OLS reports parse errors as you type; type-check errors come from
`odin check`, which OLS runs when the file is saved. Ranges arrive in UTF-16
columns and are converted to byte columns against the current text. Server
URIs are matched by their decoded, symlink-resolved path (`lsp.uri_key`),
and the editor sends OLS resolved paths, because OLS reports check results
under the compiler's resolved path (`/private/tmp/...` for a file opened as
`/tmp/...` on macOS).

## Visual UI tests

`task test:visual` is the end-to-end check every feature ships with. It
launches `example/editor_demo --control-only` once per script in `tools/`
(`lsp_smoke`, `lsp_crash`, `mouse_smoke`, `diagnostics_smoke`,
`diagnostics_extras`, `editing_smoke`, `find_smoke`) on a scratch copy of a fixture from `example/assets/`
(a single `.odin.txt` file, or a directory of them for multi-file cases), replays the script through
`edctl` — real SDL keyboard/mouse events, live OLS — and fails on any
`expect`/`wait` that doesn't hold. Along the way each script saves
screenshots of the features it demonstrates:

```
test_output/visual/
  index.md                      gallery: every suite, PASS/FAIL, captioned shots
  <suite>/NN_<feature>.png      the real window at that moment
  <suite>/contact_sheet.png     all of a suite's shots tiled and labelled
```

Add a script (and a line in `tools/visual_tests.sh`) for each new feature,
with `screenshot $SHOTS/NN_<what_it_shows>.png` at the moments worth seeing;
`tools/run_smoke.sh` fills in `$SHOTS`. `tools/contact_sheet` (SDL-only)
builds the sheets.

## Code navigation

- **F12** or **Cmd/Ctrl+click**: Go to Definition (other files open via the
  host's `editor_take_open_request`).
- **Alt+F12**: Peek Definition — the definition's source in an inline window
  (Enter opens it, Escape closes).
- **Shift+F12**: Find All References — a panel with every use and its line;
  click a row, or **F4 / Shift+F4** to step through them.
- **Alt+Shift+F12**: Find Usages — a host's uses of the symbol (its usage providers': the
  Crossfire Editor's nodes using a script) in the same panel.
- **F2**: Rename Symbol — a host's rename provider, else the server's rename.
- **Back / Forward**: Ctrl+- / Ctrl+Shift+- on macOS, Alt+Left / Alt+Right
  elsewhere.

## Look & feel

- The default theme is **Ayu Dark**; **Ayu Light** and **Dark+** are the
  other presets (palette: "Color Theme: ..."). Highlighting distinguishes
  keywords, procedures (declarations, calls, builtins), types, constants,
  fields, strings, numbers, comments, operators, `#directives` and
  `@attributes`. The editor owns its theme (`editor.theme`,
  `editor_set_theme`).
- **Theme Editor** (palette → "Theme Editor"): every theme colour with a
  swatch. Edit the selected one with the R/G/B/A sliders (drag, or
  Tab + Left/Right, Shift for steps of 16) or Enter to type a hex value;
  a live preview shows the result. Del resets a colour to the preset's,
  P / Shift+P cycles presets. Edits persist in `<config dir>/theme.json`
  (the preset plus changed colours).
- **Scrollbars** on the right and bottom: drag the thumb or click the
  track; the vertical track marks diagnostics, find matches and the caret.
- **Zoom** with **Ctrl/Cmd + / − / 0**. The host owns the fonts: call
  `editor_set_font_size` once, then on `editor_take_font_size_change`
  resize them (`TTF_SetFontSize`) and call `editor_set_font` (see
  `example/main.odin`).

## Auto-closing pairs

`Editor.auto_close_pairs` (on by default; the host's setting can turn it off) closes `()`, `[]`,
`{}`, `""`, `''`, "``" and `<>` as they're typed (`buffer/autopairs.odin`), like most code editors:

- The closer goes after the caret when the opener is typed before whitespace, the end of the line
  or another closer. Not before a word, not a quote inside a word (`don't`) or after a backslash,
  and `<` only straight after a word (`Map<`) since it's "less than" in code; in XML / HTML files
  (`Pair_Rules.markup`) `<` closes anywhere.
- Typing the closer that's next steps over it (an escaped quote, `\"`, is typed).
- Backspace between an empty pair deletes both (`buffer_backspace_pair`).
- An opener typed with text selected wraps it, the text staying selected.
- Enter between `{}`, `()` or `[]` puts the closer on its own line under an indented one
  (`buffer_newline_paired`); after an opener alone the new line is indented one more.

Every caret gets it; each pair is one undo step. Tests: `buffer/autopairs_test.odin`.

## Read-only buffers

`Buffer.read_only` refuses every edit: `buffer_raw_insert` / `buffer_raw_delete` (which every
edit goes through) change nothing and `buffer_insert_text` / `buffer_delete_range` record no
undo, so typing, pasting and line commands leave the text, its version and `dirty` alone (carets
still move). `buffer_set_text` still replaces the text: loading and reloading work. Hosts set it
for files that shouldn't be changed from there (the Crossfire Editor: files outside the project,
such as engine sources opened from an error). Test: `test_read_only_refuses_edits`.

## Overlays in a small editor

A hosted editor can be a short or narrow pane, so every overlay fits the visible area
(`editor/overlay_scroll.odin`) instead of running off it:

- **Popups and menus** (completion list, its docs, signature help, hover, diagnostic tooltips, code
  actions, the context menu, peek, the palette) go on the side of their anchor with room, as tall
  as fits there and no wider than the view (long labels are cut with "…"). What doesn't fit scrolls:
  the wheel over the overlay, the keys that move a selection (kept in view), and clicks map through
  the scroll.
- **A scrollbar** (`render_overlay_scrollbar`, the theme's scrollbar colours) shows along the
  overlay's right edge whenever its content doesn't all fit.
- **Text popups** (docs, hover, signature, diagnostics) keep up to `POPUP_MAX_LINES` and scroll
  through them; their offset is kept per thing shown (`Popup_Scroll`), so showing another item
  starts at the top.
- **The problems / references panel** is `editor_panel_rows` tall (8 rows, fewer in a short view)
  and scrolls; **tool windows** (key bindings, colour theme) show scrollbars, and Utilities and the
  colour theme's right pane (the selected colour and its sliders, `theme_pane_rect`) scroll, the
  wheel over the pane scrolling it and Tab bringing a channel's slider into view. Clipping inside
  them (`clip_push` / `clip_pop`) keeps the host's clip rect.

Tests: `overlay_scroll_test.odin` (short and narrow views).

## Command palette

**Cmd/Ctrl+P** (also Cmd/Ctrl+Shift+P and F1) opens a searchable list of
every command with its shortcut. Type to fuzzy-filter (matched letters are
highlighted), Up/Down to choose, Enter or click to run, Escape to close.
Recently used commands are listed first, then the windows.

The palette also **switches windows**: *Editor* (the text), *Find /
Replace*, *Keymap Editor*, *Theme Editor* and *Utilities* — and it works
from inside any of them. Tool windows cover the editor area and own the
keyboard (the palette and zoom shortcuts still work); Escape goes back to
the text.

**Utilities** shows the language server's state (status and pid,
command, root, document sync, diagnostics, crash count) and runs
maintenance actions — also available directly as palette commands:
*Language Server: Restart / Stop / Start / Resync Document / Copy Status
Info*, *Preferences: Reset Key Bindings to Defaults / Reset Theme / Reload
Settings from Disk*. Restart works even after the crash supervisor gave up.

## Key bindings

- **Keymap Editor** (palette → "Keymap Editor"): every command and its
  keys. Type to filter by name or by key ("cmd+shift"); **Enter** records a
  new chord (replacing the old ones), **Shift+Enter** adds one, **Del**
  removes, **Cmd/Ctrl+R** resets to the default, **Escape** closes.
- **Import Keybindings from Zed / VSCode** (palette): merges
  `~/.config/zed/keymap.json` or VSCode's `keybindings.json` into the
  keymap. Commands without an equivalent and multi-key sequences
  (`cmd+k cmd+c`) are skipped and counted in the status message.
- Changes persist in `<config dir>/keymap.json` as overrides of the
  defaults. The host picks the directory with `editor_set_config_dir`
  (the demo: `~/.config/odin_editor`, or `--config-dir`; none with
  `--control-only`); `editor_set_import_path` overrides where imports read.
- Line commands: **Alt+Up/Down** move line, **Shift+Alt+Up/Down**
  duplicate, **Cmd/Ctrl+/** toggle comment, **Cmd/Ctrl+Shift+K** delete
  line, **Cmd/Ctrl+Enter** / **Cmd/Ctrl+Shift+Enter** insert line
  below / above.

## Search

- **Ctrl/Cmd+F** opens the find bar (seeded from a single-line selection);
  typing searches incrementally from the caret and highlights every match,
  with an "N of M" count. **Enter / Shift+Enter** (or **F3 / Shift+F3**,
  **Ctrl/Cmd+G / +Shift**) step through matches; **Escape** closes.
- **Alt+C / Alt+W / Alt+R** (or click `Aa` / `W` / `.*`) toggle case
  sensitivity, whole word, and regular expressions (`core:text/regex`;
  replacements may use `$0`-`$9`).
- **Ctrl+H** (**Cmd+Alt+F** on macOS) adds a replace field: **Tab** switches
  fields, **Enter** replaces the current match, **Ctrl/Cmd+Alt+Enter**
  replaces all — each a single undo step.
- **Ctrl/Cmd+D** selects the word at the caret, then adds a cursor at each
  next occurrence; **Ctrl/Cmd+Shift+L** selects every occurrence.

## Mouse

`editor_handle_event` handles the full set of mouse gestures (pass it every
mouse, key-up and window event — key-ups are how it tracks held modifiers):

- click to place the caret; drag to select (auto-scrolls past the edges)
- double-click selects a word, triple-click a line; dragging after either
  extends by whole words/lines
- Shift+click extends the selection; Alt+click adds a cursor (Alt+click an
  existing cursor removes it)
- click/drag in the line-number gutter selects whole lines
- wheel scrolls vertically; horizontal wheel or Shift+wheel scrolls
  sideways; the wheel over the completion list scrolls the list
- click a completion item to accept it
- rest on code to see **hover info** from the server (type, docs)
- **right-click** for a context menu (Cut/Copy/Paste, Select All, Quick
  Fix, Find, Next Problem)
- **drag a selection** to move it; hold Alt/Option or Ctrl to copy

Hit-testing uses visual columns (tabs expand to `ed.tab_width`, default 4),
and clicks outside the editor's area return `false` so hosts can route them
elsewhere. `editor_mouse_cursor(ed)` says which pointer to show (I-beam over
text, arrow over the gutter and popups); the host owns the SDL cursor
objects — see `example/main.odin`.

## Standalone demo app

```sh
task run                  # interactive window, opens example/assets/sample.odin.txt
task run -- path/to/x.odin # open a specific file
task run -- --script       # runs the injection-hook script, then stays interactive
task run -- --script-only  # runs the script, prints the resulting buffer, and exits
task run -- --control 7777 # also enable the remote control hook (see above)
task run -- --no-lsp       # don't attach OLS even if it's built
```

If `third_party/ols/ols` has been built, the demo attaches it automatically
(rooted at the opened file's directory).

Interactive hotkeys follow VSCode/Zed conventions (Cmd on macOS, Ctrl
elsewhere) for navigation, selection, clipboard, undo/redo, and save
(Ctrl/Cmd+S writes back to the opened file).

## Odin Language Server (OLS)

OLS tracks Odin's development branch closely, so an arbitrary "latest" OLS
checkout frequently fails to compile against whatever Odin compiler version
is actually installed. `Taskfile.yml`'s `OLS_REF` pins a specific OLS commit
known to build cleanly against this project's target Odin version; override
it (`task ols:build OLS_REF=<sha>`) if you're on a different Odin version, or
let `task ols:repin` find one: after a compiler upgrade it searches OLS
history for the newest commit that builds and still takes `patches/ols`,
and rewrites `OLS_REF`.

```sh
task ols:fetch   # clone third_party/ols, checkout OLS_REF, apply patches/ols/*.patch
task ols:build   # odin build -collection:src=third_party/ols/src -> third_party/ols/ols
task ols:check   # does OLS_REF still build with this compiler (+ patches)?
task ols:repin   # find a compatible commit and update OLS_REF (NEWEST=1: newest compatible)
```

`patches/ols/` holds local fixes for upstream OLS bugs this editor runs into,
reapplied in order on a clean checkout by every `ols:fetch`:

- `0002-check-columns-utf16.patch` — the compiler reports code-point
  columns; OLS forwarded them as LSP (UTF-16) characters, so squiggles after
  an emoji landed early.

Drop a patch once upstream fixes the bug. (`0001-check-request-uri-lifetime`, a
check request's path freed before the check thread read it, was dropped when the
pin moved to `c96dea91` (2026-10-10): upstream clones it now. That's also the
newest OLS that builds with Odin dev-2026-10; later commits import
`core:odin/tool-format`, which needs a newer Odin.)

Then attach it to an editor instance:

```odin
ed.editor_attach_lsp(&editor, []string{"odin_editor/third_party/ols/ols"}, project_root)
```

**Crash isolation.** OLS runs as a child process so a crash in it can't take
the editor down. The client ignores SIGPIPE (otherwise writing to a dead
server's stdin would kill the editor), detects a dead server (EOF, broken
pipe, failed write, or process exit), and the editor's supervisor
(`editor/lsp_supervisor.odin`) closes any open popups, restarts the server
with backoff (250 ms, 500 ms, 1 s), and re-opens the document. After
`LSP_MAX_RESTARTS` (3) crashes within a minute it gives up
(`editor_lsp_status` = `.Failed`) and the editor carries on as a plain text
editor. `task test:visual` kills OLS mid-session to verify this.

Once attached, `editor_update` each frame polls for responses, sends the
deferred `didOpen` once `initialize` has completed, pushes a full-text
`didChange` whenever the buffer changed, and refreshes the popups.

- **Completion** opens on `.`, on the first identifier character of a word,
  or with Ctrl/Cmd+Space. The list filters locally as you type (prefix
  matches first, then fuzzy), Up/Down/PageUp/PageDown select, Enter/Tab
  accept (honoring the item's `textEdit`/`insertText`, as one undo step),
  Escape dismisses, and moving the cursor out of the word closes it. Text typed
  faster than frames (a paste of keys, a test script) opens the list again for
  the word being typed. The list is the server's items merged with the host's
  completion providers' (see "Providers" above).
- The selected item's **documentation** shows in a panel beside the list.
  **Snippets** are supported (the editor enables OLS's via
  `initializationOptions`, see `DEFAULT_LSP_INIT_OPTIONS`): placeholders
  are selected in turn with **Tab / Shift+Tab**, and accepting a procedure
  inserts `name()` with parameter hints open. Lists the server marks
  `isIncomplete` are re-queried as you type.
- **Signature help** opens on `(` / `,` or Ctrl/Cmd+Shift+Space; with
  several overloads (proc groups) **Up / Down** cycle them ("1/2"), re-queries
  as the cursor moves so the active parameter is highlighted, and closes once
  the cursor leaves the call's parentheses (OLS keeps answering just past the
  closing `)`, so the client checks paren depth itself) or on Escape. A long
  signature wraps (`signature_wrapped`: at most the text area's width, 100
  columns, breaking after spaces, continuation lines indented), the active
  parameter highlighted across the break.

Accepting a completion applies its `additionalTextEdits` too, as one undo step
with it: OLS completes a package that isn't imported (`fmt`) with the `import`
line it needs, which goes in at the top while the caret stays after the
completion (`test_accepting_a_package_imports_it`).

Popups wrap to the editor's width (`popup_max_cols`): the hover (at most 100
columns, half the view tall), the completion docs, the diagnostics tooltip, the
signature help. Code lines wrap too (`wrap_code`: after a space where it can,
continuation lines indented), so a long signature in a hover's code block stays
on screen.

Document sync is incremental when the server asks for it (OLS does). A host
that changes the buffer itself and calls `editor_notify_lsp_changed` sends the
whole text, and the incremental edits queued for it are dropped (they'd be
applied a second time). `sync_shadow_test.odin` replays exactly what the client
sends (`Client.sent_log`) after each kind of edit (typing, auto-pairs, multiple
cursors, line moves, comments, indenting, undo/redo) and checks the server's
copy matches the buffer.

Responses to superseded requests are dropped, so a slow reply can't
overwrite a newer one.


## Git workflow

All work happens locally on feature branches (e.g.
`feature/odin-editor-scaffold`) with descriptive commits per package/feature;
no remote push happens as part of this effort.
