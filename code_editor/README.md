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

Save/load is a plain API the host drives explicitly — there is no global
editor state, so multiple `Editor` instances can coexist (e.g. multiple open
tabs/panes), each owning its own buffer, keymap, and (optionally) its own
LSP client instance via `editor_attach_lsp`.

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
step). **Ctrl/Cmd+Shift+M** toggles a Problems panel docked at the bottom
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

- `0001-check-request-uri-lifetime.patch` — OLS hands the save-triggered
  `odin check` request a temp-allocated URI that is freed before the check
  thread reads it, so errors fixed since the previous save are never
  cleared.
- `0002-check-columns-utf16.patch` — the compiler reports code-point
  columns; OLS forwarded them as LSP (UTF-16) characters, so squiggles after
  an emoji landed early.

Drop a patch once upstream fixes the bug.

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
  Escape dismisses, and moving the cursor out of the word closes it.
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
  closing `)`, so the client checks paren depth itself) or on Escape.

Responses to superseded requests are dropped, so a slow reply can't
overwrite a newer one.


## Git workflow

All work happens locally on feature branches (e.g.
`feature/odin-editor-scaffold`) with descriptive commits per package/feature;
no remote push happens as part of this effort.
