# Odin Code Editor — Requirements

A modular, embeddable code editor written in Odin, using SDL3 for windowing
and rendering. It must be usable both as a standalone demo application and as
a library embedded inside another game engine editor (e.g. the
`odin_raylib_engine` editor tooling). Scope of work is strictly limited to
the `odin_editor/` folder — no other folder in this repository is modified
as part of this effort.

## 1. Build & Task Automation
- Provide a `Taskfile.yml` inside `odin_editor/` (https://taskfile.dev) with
  tasks for at least:
  - `run` — build & run the standalone example app.
  - `build` — build the standalone example app binary.
  - `test` — run all unit tests across every package (`buffer`, `keymap`,
    `syntax`, `lsp`, `editor`, ...).
  - `check` — `odin check` across all packages (fast type-check, no codegen).
  - `fmt`/`vet` (optional helpers) as needed.
  - `ols:fetch` — clone/update the Daniel Gavin OLS (Odin Language Server)
    source under `odin_editor/third_party/ols`.
  - `ols:build` — build the `ols` binary so the editor can spawn it.

## 2. Testing
- Every feature/package must ship with Odin `testing` package unit tests
  (`*_test.odin`, run via `odin test <package>`).
- Tests must cover: buffer mutation (insert/delete/undo/redo), cursor &
  selection movement, multi-cursor behavior, keymap dispatch/resolution,
  syntax tokenization, LSP JSON-RPC message framing/parsing, and file
  load/save API round-trips.
- `task test` must run clean with zero failures and zero tracked memory
  leaks (mirrors the existing `engine` package convention of using the
  testing allocator / tracking allocator in tests).

## 3. Language Server Integration
- Embed/launch the Odin Language Server (OLS) from
  https://github.com/DanielGavin/ols as a child process communicating over
  stdio using the Language Server Protocol (JSON-RPC 2.0, `Content-Length`
  framed messages).
- The editor process is the LSP *client*. It must implement, at minimum:
  - `initialize` / `initialized` handshake.
  - `textDocument/didOpen`, `didChange` (incremental or full-sync),
    `didClose`, `didSave`.
  - `textDocument/completion` (code completion).
  - `textDocument/signatureHelp` (function signature help).
  - `textDocument/publishDiagnostics` (receive & surface diagnostics).
  - `textDocument/hover` (nice-to-have, included if time allows).
- LSP client must be isolated in its own package so it can be swapped/tested
  independently of SDL/rendering code.

## 4. Core Editor Functionality
Standard code-editor behavior is required, including:
- Multi-line text buffer with efficient insert/delete.
- Cursor movement: by character, word, line, page, start/end of
  line/document.
- Selections: shift+move to extend, select word/line, select all.
- Multiple cursors / multiple selections.
- Clipboard: cut/copy/paste (via SDL3 clipboard API).
- Undo/redo history.
- Line numbers gutter, current-line highlight.
- Indentation (tab/space), auto-indent on newline.
- Scrolling (vertical + horizontal) with viewport clamping.
- Find (and later find/replace) is a stretch goal noted in the backlog.

## 5. Syntax Highlighting & Language Features
- Tokenizer/highlighter architecture that is pluggable per-language; ship an
  Odin-language tokenizer (keywords, strings, numbers, comments, operators,
  identifiers) by default.
- Code completion popup driven by LSP `completion` responses.
- Function signature help popup driven by LSP `signatureHelp` responses.
- Diagnostics (errors/warnings) rendered as gutter markers / underline
  squiggles using `publishDiagnostics` data.

## 6. Keybindings
- Keymap module providing VSCode/Zed-equivalent default hotkeys, including
  (non-exhaustive):
  - Navigation: arrows, Home/End, Ctrl/Cmd+Home/End, Ctrl/Cmd+Left/Right
    (word jump), Page Up/Down.
  - Selection: Shift + any navigation key, Ctrl/Cmd+A (select all),
    Ctrl/Cmd+D (select word / add next occurrence — stretch), Ctrl/Cmd+L
    (select line).
  - Editing: Backspace, Delete, Tab/Shift+Tab (indent/outdent), Enter
    (newline + auto-indent), Ctrl/Cmd+Backspace/Delete (delete word).
  - Clipboard: Ctrl/Cmd+C/X/V.
  - Undo/redo: Ctrl/Cmd+Z, Ctrl/Cmd+Shift+Z (or Ctrl+Y on Windows/Linux).
  - File: Ctrl/Cmd+S (save), Ctrl/Cmd+O (open — host app hook).
  - Multi-cursor: Alt+Click (add cursor), Ctrl/Cmd+Alt+Up/Down (add cursor
    above/below) — stretch goal.
- Keymap must be data-driven (table of chord -> action) so hosts can remap.

## 7. Source Control Workflow
- Use local git only (no remote push) during development.
- Work happens on feature branches (e.g. `feature/odin-editor-<topic>`),
  merged back to `main`/base branch via local commits as features land.
- Commit messages describe the feature/package added.

## 8. File I/O API
- Public API for the host application:
  - `editor_load_file(ed: ^Editor, path: string) -> bool`
  - `editor_save_file(ed: ^Editor, path: string) -> bool`
  - `editor_save_file_as(ed: ^Editor, path: string) -> bool`
  - Buffer <-> string conversion helpers for in-memory round trips (hosts
    that don't use disk files, e.g. embedded script buffers).
- Must be modular/embeddable: no global singleton state required to run
  multiple editor instances; the engine/editor is a value type
  (`^Editor`) the host owns and drives explicitly (`editor_update`,
  `editor_handle_event`, `editor_render`).

## 9. Example / Demo Application & Event Injection
- `odin_editor/example/` — standalone SDL3 app that creates a window,
  instantiates one `Editor`, pumps SDL events into it, and renders it every
  frame. This doubles as a manual test harness and a reference for how a
  host integrates the editor.
- Provide an **event injection hook** — an API to push synthetic
  `sdl3.Event` values into the editor's input queue bypassing
  `SDL_PollEvent`. This allows:
  - Automated/scripted tests that simulate keystrokes end-to-end (type
    text, move cursor, trigger hotkeys) without a real display/input
    device.
  - Interactive manual exploration by feeding recorded event scripts.

## 10. Standalone Launch
- `task run` (or a built binary `odin_editor/example/editor_demo`) launches
  a usable window where a developer can open/edit/save a real file using
  the editor, to manually verify behavior end-to-end.

## Package Layout
```
odin_editor/
  Taskfile.yml
  REQUIREMENTS.md
  README.md
  buffer/     -- text buffer, cursor/selection, undo-redo (package buffer)
  keymap/     -- hotkey table + action dispatch (package keymap)
  syntax/     -- tokenizer + Odin highlighter (package syntax)
  lsp/        -- JSON-RPC + LSP client talking to OLS (package lsp)
  editor/     -- glue: SDL3 rendering, view/viewport, file IO API,
                 event injection hook (package editor)
  example/    -- standalone demo app (package main)
  third_party/ols -- vendored OLS source/build output (git-ignored build
                      artifacts; fetched via Taskfile)
```

## Status / Backlog
See `TODO.md` in this folder for live progress tracking as features land.
