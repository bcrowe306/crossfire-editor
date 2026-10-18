// End-to-end test suite for odin_editor, driven entirely through the
// SDL event-injection hook (editor_inject_key/editor_inject_text) rather
// than by calling internal functions directly. This exercises the editor
// the same way a real user's keystrokes would, routed through the exact
// same `editor_handle_event` path the interactive demo uses.
//
// Run via: `./<demo-binary> --e2e` (see main.odin). Opens a real SDL3
// window + renderer (so the render path is exercised too), runs every
// check, prints a PASS/FAIL table, and exits 0 only if everything passed.
package main

import buf "../buffer"
import ed "../editor"
import lspc "../lsp"
import syn "../syntax"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Check :: struct {
	group:  string,
	name:   string,
	pass:   bool,
	detail: string,
}

E2E_Ctx :: struct {
	results: [dynamic]Check,
	group:   string,
}

e2e_check :: proc(ctx: ^E2E_Ctx, name: string, cond: bool, detail: string = "") {
	append(&ctx.results, Check{ctx.group, name, cond, detail})
}

@(private)
e2e_reset :: proc(e: ^ed.Editor, text: string) {
	ed.editor_set_text(e, text)
	e.scroll_line = 0
	e.scroll_col = 0
}

// ---------------------------------------------------------------------
// 1. Typing
// ---------------------------------------------------------------------
e2e_test_typing :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx) {
	ctx.group = "typing"
	e2e_reset(e, "")
	ed.editor_inject_text(e, "hello")
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "typed text appears on line 0", buf.buffer_line_str(&e.buf, 0) == "hello")
	e2e_check(ctx, "cursor advances to end of typed text", e.buf.cursors[0].pos == buf.Position{0, 5})

	ed.editor_inject_text(e, " world")
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "subsequent typing appends", buf.buffer_line_str(&e.buf, 0) == "hello world")
}

// ---------------------------------------------------------------------
// 2. Navigation
// ---------------------------------------------------------------------
e2e_test_navigation :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx, word_mod, primary_mod: sdl.Keymod) {
	ctx.group = "navigation"
	e2e_reset(e, "")
	ed.editor_inject_text(e, "hello world")
	ed.editor_pump_injected_events(e)
	// cursor at (0, 11)

	ed.editor_inject_key(e, sdl.K_HOME)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "Home moves to column 0", e.buf.cursors[0].pos == buf.Position{0, 0})

	ed.editor_inject_key(e, sdl.K_END)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "End moves to end of line", e.buf.cursors[0].pos == buf.Position{0, 11})

	ed.editor_inject_key(e, sdl.K_LEFT, word_mod)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "word-left stops at start of 'world'", e.buf.cursors[0].pos == buf.Position{0, 6})

	ed.editor_inject_key(e, sdl.K_LEFT, word_mod)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "word-left stops at start of 'hello'", e.buf.cursors[0].pos == buf.Position{0, 0})

	ed.editor_inject_key(e, sdl.K_RIGHT, word_mod)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "word-right jumps across 'hello'", e.buf.cursors[0].pos == buf.Position{0, 5})

	e2e_reset(e, "line one\nline two\nline three")
	ed.editor_inject_key(e, sdl.K_END, primary_mod)
	ed.editor_pump_injected_events(e)
	last_line := buf.buffer_line_count(&e.buf) - 1
	e2e_check(ctx, "doc-end lands on last line", e.buf.cursors[0].pos.line == last_line)

	ed.editor_inject_key(e, sdl.K_HOME, primary_mod)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "doc-start lands on line 0 col 0", e.buf.cursors[0].pos == buf.Position{0, 0})

	ed.editor_inject_key(e, sdl.K_DOWN)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "down moves to next line", e.buf.cursors[0].pos.line == 1)

	ed.editor_inject_key(e, sdl.K_UP)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "up moves back to previous line", e.buf.cursors[0].pos.line == 0)
}

// ---------------------------------------------------------------------
// 3. Selection
// ---------------------------------------------------------------------
e2e_test_selection :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx, primary_mod: sdl.Keymod) {
	ctx.group = "selection"
	e2e_reset(e, "")
	ed.editor_inject_text(e, "hello world")
	ed.editor_inject_key(e, sdl.K_HOME)
	ed.editor_pump_injected_events(e)

	ed.editor_inject_key(e, sdl.K_END, sdl.KMOD_SHIFT)
	ed.editor_pump_injected_events(e)
	{
		start, end, ok := buf.selection_range(e.buf.cursors[0])
		e2e_check(ctx, "shift+End selects whole line", ok && start == buf.Position{0, 0} && end == buf.Position{0, 11})
	}

	e2e_reset(e, "alpha\nbeta\ngamma")
	ed.editor_inject_key(e, sdl.K_A, primary_mod)
	ed.editor_pump_injected_events(e)
	{
		start, end, ok := buf.selection_range(e.buf.cursors[0])
		last_line := buf.buffer_line_count(&e.buf) - 1
		e2e_check(ctx, "select-all spans entire document", ok && start == buf.Position{0, 0} && end.line == last_line)
	}

	e2e_reset(e, "alpha\nbeta\ngamma")
	ed.editor_inject_key(e, sdl.K_L, primary_mod)
	ed.editor_pump_injected_events(e)
	{
		// select-line extends through the trailing newline onto the start
		// of the next line (so a following Delete/typed char cleanly
		// replaces the whole line, newline included).
		start, end, ok := buf.selection_range(e.buf.cursors[0])
		e2e_check(ctx, "select-line selects current line (through trailing newline)",
			ok && start == buf.Position{0, 0} && end == buf.Position{1, 0},
			fmt.tprintf("start=%v end=%v", start, end))
	}

	e2e_reset(e, "foo bar baz")
	ed.editor_inject_key(e, sdl.K_D, primary_mod)
	ed.editor_pump_injected_events(e)
	{
		_, _, ok := buf.selection_range(e.buf.cursors[0])
		e2e_check(ctx, "select-word creates a selection", ok)
	}
}

// ---------------------------------------------------------------------
// 4. Multi-cursor
// ---------------------------------------------------------------------
e2e_test_multi_cursor :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx, primary_mod: sdl.Keymod) {
	ctx.group = "multi-cursor"
	e2e_reset(e, "aaa\nbbb\nccc")
	ed.editor_inject_key(e, sdl.K_RIGHT) // (0,1)
	ed.editor_pump_injected_events(e)

	ed.editor_inject_key(e, sdl.K_DOWN, primary_mod | sdl.KMOD_ALT)
	ed.editor_pump_injected_events(e)
	ed.editor_inject_key(e, sdl.K_DOWN, primary_mod | sdl.KMOD_ALT)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "add-cursor-below creates 3 cursors", len(e.buf.cursors) == 3,
		fmt.tprintf("got %d", len(e.buf.cursors)))

	ed.editor_inject_text(e, "X")
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "multi-cursor typing hits line 0", buf.buffer_line_str(&e.buf, 0) == "aXaa")
	e2e_check(ctx, "multi-cursor typing hits line 1", buf.buffer_line_str(&e.buf, 1) == "bXbb")
	e2e_check(ctx, "multi-cursor typing hits line 2", buf.buffer_line_str(&e.buf, 2) == "cXcc")
}

// ---------------------------------------------------------------------
// 5. Clipboard
// ---------------------------------------------------------------------
e2e_test_clipboard :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx, primary_mod: sdl.Keymod) {
	ctx.group = "clipboard"
	e2e_reset(e, "")
	ed.editor_inject_text(e, "copy me")
	ed.editor_inject_key(e, sdl.K_HOME)
	ed.editor_pump_injected_events(e)
	ed.editor_inject_key(e, sdl.K_END, sdl.KMOD_SHIFT)
	ed.editor_pump_injected_events(e)
	ed.editor_inject_key(e, sdl.K_C, primary_mod)
	ed.editor_pump_injected_events(e)

	ed.editor_inject_key(e, sdl.K_END)
	ed.editor_inject_text(e, "\n")
	ed.editor_inject_key(e, sdl.K_V, primary_mod)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "copy+paste duplicates the line", buf.buffer_line_str(&e.buf, 1) == "copy me")

	e2e_reset(e, "")
	ed.editor_inject_text(e, "cut me")
	ed.editor_inject_key(e, sdl.K_HOME)
	ed.editor_pump_injected_events(e)
	ed.editor_inject_key(e, sdl.K_END, sdl.KMOD_SHIFT)
	ed.editor_pump_injected_events(e)
	ed.editor_inject_key(e, sdl.K_X, primary_mod)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "cut removes the selected text", buf.buffer_line_str(&e.buf, 0) == "")

	ed.editor_inject_key(e, sdl.K_V, primary_mod)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "pasting cut text restores it", buf.buffer_line_str(&e.buf, 0) == "cut me")
}

// ---------------------------------------------------------------------
// 6. Undo / redo
// ---------------------------------------------------------------------
e2e_test_undo_redo :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx, primary_mod: sdl.Keymod) {
	ctx.group = "undo-redo"
	e2e_reset(e, "")
	ed.editor_inject_text(e, "abc")
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "setup: typed 'abc'", buf.buffer_line_str(&e.buf, 0) == "abc")

	ed.editor_inject_key(e, sdl.K_Z, primary_mod)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "undo reverts typed text", buf.buffer_line_str(&e.buf, 0) == "")

	ed.editor_inject_key(e, sdl.K_Z, primary_mod | sdl.KMOD_SHIFT)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "redo restores typed text", buf.buffer_line_str(&e.buf, 0) == "abc")
}

// ---------------------------------------------------------------------
// 7. Indent / outdent
// ---------------------------------------------------------------------
e2e_test_indent :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx) {
	ctx.group = "indent"
	e2e_reset(e, "line")
	ed.editor_inject_key(e, sdl.K_HOME)
	ed.editor_pump_injected_events(e)
	ed.editor_inject_key(e, sdl.K_TAB)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "Tab indents with 4 spaces", buf.buffer_line_str(&e.buf, 0) == "    line",
		fmt.tprintf("got %q", buf.buffer_line_str(&e.buf, 0)))

	ed.editor_inject_key(e, sdl.K_TAB, sdl.KMOD_SHIFT)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "Shift+Tab outdents back", buf.buffer_line_str(&e.buf, 0) == "line",
		fmt.tprintf("got %q", buf.buffer_line_str(&e.buf, 0)))
}

// ---------------------------------------------------------------------
// 8. Newline auto-indent
// ---------------------------------------------------------------------
e2e_test_newline_autoindent :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx) {
	ctx.group = "newline"
	e2e_reset(e, "    indented")
	ed.editor_inject_key(e, sdl.K_END)
	ed.editor_pump_injected_events(e)
	ed.editor_inject_key(e, sdl.K_RETURN)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "Enter creates a new line", buf.buffer_line_count(&e.buf) == 2)
	e2e_check(ctx, "new line copies leading indentation", buf.buffer_line_str(&e.buf, 1) == "    ",
		fmt.tprintf("got %q", buf.buffer_line_str(&e.buf, 1)))

	// Regression: pressing Enter between a pair of brackets must split the
	// line cleanly, not corrupt/drop the trailing character (a prior bug
	// read the old line's backing memory after it had been freed).
	e2e_reset(e, "()")
	e.buf.cursors[0].pos = buf.Position{0, 1}
	ed.editor_inject_key(e, sdl.K_RETURN)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "Enter between brackets keeps the opening bracket on line 0",
		buf.buffer_line_str(&e.buf, 0) == "(", fmt.tprintf("got %q", buf.buffer_line_str(&e.buf, 0)))
	e2e_check(ctx, "Enter between brackets preserves the closing bracket on line 1",
		buf.buffer_line_str(&e.buf, 1) == ")", fmt.tprintf("got %q", buf.buffer_line_str(&e.buf, 1)))
}

// ---------------------------------------------------------------------
// 9. Backspace / delete-forward
// ---------------------------------------------------------------------
e2e_test_backspace_delete :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx) {
	ctx.group = "backspace-delete"
	e2e_reset(e, "ab\ncd")
	ed.editor_inject_key(e, sdl.K_DOWN)
	ed.editor_inject_key(e, sdl.K_HOME)
	ed.editor_pump_injected_events(e)
	ed.editor_inject_key(e, sdl.K_BACKSPACE)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "backspace at line start merges lines", buf.buffer_line_count(&e.buf) == 1 && buf.buffer_line_str(&e.buf, 0) == "abcd")
	e2e_check(ctx, "cursor lands at merge point", e.buf.cursors[0].pos == buf.Position{0, 2})

	ed.editor_inject_key(e, sdl.K_DELETE)
	ed.editor_pump_injected_events(e)
	e2e_check(ctx, "delete-forward removes next char", buf.buffer_line_str(&e.buf, 0) == "abd",
		fmt.tprintf("got %q", buf.buffer_line_str(&e.buf, 0)))
}

// ---------------------------------------------------------------------
// 10. File save/load API
// ---------------------------------------------------------------------
e2e_test_file_io :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx) {
	ctx.group = "file-io"
	e2e_reset(e, "package main\n\nmain :: proc() {}\n")
	path := "/tmp/odin_editor_e2e_save.odin"
	ok := ed.editor_save_file(e, path)
	e2e_check(ctx, "editor_save_file succeeds", ok)

	e2 := ed.editor_init(.Other)
	defer ed.editor_destroy(&e2)
	load_ok := ed.editor_load_file(&e2, path)
	e2e_check(ctx, "editor_load_file succeeds", load_ok)
	roundtrip := ed.editor_to_string(&e2, context.temp_allocator)
	e2e_check(ctx, "round-tripped content matches", roundtrip == "package main\n\nmain :: proc() {}\n")

	os.remove(path)
}

// ---------------------------------------------------------------------
// 11. Syntax highlighting
// ---------------------------------------------------------------------
e2e_test_syntax_highlighting :: proc(ctx: ^E2E_Ctx) {
	ctx.group = "syntax"
	lang := syn.odin_language()
	line := `if x == 10 { return } // done`
	tokens, _ := lang.tokenize(line, syn.LINE_STATE_NORMAL, context.temp_allocator)
	defer delete(tokens, context.temp_allocator)

	has_keyword, has_number, has_comment := false, false, false
	for t in tokens {
		switch t.kind {
		case .Keyword: has_keyword = true
		case .Number: has_number = true
		case .Comment: has_comment = true
		case .Identifier, .String, .Operator, .Punctuation, .Type, .Builtin, .Default, .Function, .Constant, .Property, .Directive, .Attribute:
		}
	}
	e2e_check(ctx, "tokenizer finds keyword tokens ('if'/'return')", has_keyword)
	e2e_check(ctx, "tokenizer finds number tokens ('10')", has_number)
	e2e_check(ctx, "tokenizer finds line-comment tokens", has_comment)
}

// ---------------------------------------------------------------------
// 12. Scrolling / viewport
// ---------------------------------------------------------------------
e2e_test_scroll_viewport :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx) {
	ctx.group = "viewport"
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 60 {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		fmt.sbprintf(&sb, "line %d", i)
	}
	e2e_reset(e, strings.to_string(sb))
	e.visible_rows = 10
	e.scroll_line = 0

	for _ in 0 ..< 45 {
		ed.editor_inject_key(e, sdl.K_DOWN)
	}
	ed.editor_pump_injected_events(e)

	e2e_check(ctx, "cursor followed 45 Down presses", e.buf.cursors[0].pos.line == 45)
	e2e_check(ctx, "viewport scrolled to keep cursor visible",
		e.scroll_line <= 45 && e.scroll_line + e.visible_rows > 45,
		fmt.tprintf("scroll_line=%d visible_rows=%d", e.scroll_line, e.visible_rows))
}

// ---------------------------------------------------------------------
// 13. Render smoke test
// ---------------------------------------------------------------------
e2e_test_render_smoke :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: ed.Theme) {
	ctx.group = "render"
	e2e_reset(e, "package main\n\nmain :: proc() {\n\tfmt.println(\"hi\")\n}\n")
	e.visible_rows = 20
	e.visible_cols = 80
	ed.editor_apply_action(e, .SelectAll)

	for _ in 0 ..< 5 {
		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
		sdl.RenderClear(renderer)
		ed.editor_render(e, renderer, font, 0, 0)
		sdl.RenderPresent(renderer)
	}
	// If we reach this line, 5 render passes (with an active selection,
	// multi-token lines, and the gutter) completed without crashing.
	e2e_check(ctx, "editor_render runs for 5 frames without crashing", true)
}

// ---------------------------------------------------------------------
// 14. LSP integration (real `ols` binary, skipped if not built)
// ---------------------------------------------------------------------
e2e_test_lsp :: proc(e: ^ed.Editor, ctx: ^E2E_Ctx, primary_mod: sdl.Keymod, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: ed.Theme) {
	ctx.group = "lsp"
	ols_path := "third_party/ols/ols"
	if !os.exists(ols_path) {
		e2e_check(ctx, "ols binary present (run `task ols:build`)", false,
			"SKIPPED: third_party/ols/ols not found; run `task ols:build` to enable LSP checks")
		return
	}

	ok := ed.editor_attach_lsp(e, []string{ols_path}, ".")
	e2e_check(ctx, "editor_attach_lsp spawns ols", ok)
	if !ok {
		return
	}
	defer ed.editor_detach_lsp(e)

	initialized := false
	for _ in 0 ..< 50 {
		lspc.client_poll(&e.lsp)
		if e.lsp.initialized {
			initialized = true
			break
		}
		time.sleep(100 * time.Millisecond)
	}
	e2e_check(ctx, "LSP initialize handshake completes", initialized)
	if !initialized {
		return
	}

	sample_path := "/tmp/odin_editor_e2e_lsp_sample.odin"
	sample := "package sample\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.pri\n}\n"
	_ = os.write_entire_file(sample_path, transmute([]u8)sample)
	defer os.remove(sample_path)

	ed.editor_load_file(e, sample_path)
	e2e_pump_until(e, proc(e: ^ed.Editor) -> bool {return e.lsp_doc_open}, 3000)
	e2e_check(ctx, "didOpen sent once the server is initialized", e.lsp_doc_open)
	e.buf.cursors[0].pos = buf.Position{5, 8} // end of "fmt.pri"

	// --- completion popup ---
	ed.editor_inject_key(e, sdl.K_SPACE, primary_mod)
	got_completion := e2e_pump_until(e, ed.editor_completion_visible, 5000)
	e2e_check(ctx, "completion request (Ctrl/Cmd+Space) returns items from ols",
		got_completion, fmt.tprintf("got %d items", len(e.lsp.last_completion)))
	e2e_check(ctx, "completion popup is visible", ed.editor_completion_visible(e))

	println_row := -1
	for idx, row in e.completion.filtered {
		if e.lsp.last_completion[idx].label == "println" {
			println_row = row
		}
	}
	e2e_check(ctx, "popup lists 'println' for prefix 'pri'", println_row >= 0,
		fmt.tprintf("%d filtered items", len(e.completion.filtered)))
	all_match := true
	for idx in e.completion.filtered {
		label := e.lsp.last_completion[idx].label
		all_match &&= len(label) >= 3 && strings.equal_fold(label[:3], "pri")
	}
	e2e_check(ctx, "every listed item matches the typed prefix", all_match)

	e2e_render_frames(e, renderer, font, theme, 2)
	e2e_check(ctx, "renders with completion popup open", true)

	for _ in 0 ..< max(println_row, 0) {
		ed.editor_inject_key(e, sdl.K_DOWN)
	}
	ed.editor_update(e)
	selected, _ := ed.editor_completion_selected_item(e)
	e2e_check(ctx, "Down arrows move the selection to 'println'", selected.label == "println",
		fmt.tprintf("selected %q", selected.label))

	ed.editor_inject_key(e, sdl.K_RETURN)
	ed.editor_update(e)
	// OLS (snippets enabled via initializationOptions) inserts `println($0)`
	// and asks for parameter hints.
	e2e_check(ctx, "Enter accepts the completion as a snippet", buf.buffer_line_str(&e.buf, 5) == "\tfmt.println()",
		fmt.tprintf("line 5 = %q", buf.buffer_line_str(&e.buf, 5)))
	e2e_check(ctx, "caret lands inside the parentheses", e.buf.cursors[0].pos == buf.Position{5, 13})
	e2e_check(ctx, "accepting closes the popup", !e.completion.active)

	// --- signature help ---
	got_sig := e2e_pump_until(e, ed.editor_signature_visible, 5000)
	e2e_check(ctx, "accepting a procedure opens signature help", got_sig)
	label, _, active, _ := ed.editor_signature_active_parts(e)
	// Copy: `label` borrows LSP storage that later responses free.
	e2e_check(ctx, "signature label is fmt.println's", strings.contains(label, "println :: proc("), fmt.tprint(label))
	e2e_check(ctx, "first parameter is active", active == "args: ..any", fmt.tprintf("active=%q", active))

	e2e_render_frames(e, renderer, font, theme, 2)
	e2e_check(ctx, "renders with signature help open", true)

	for ch in "\"hi\"" {
		bytes, n := utf8.encode_rune(ch)
		ed.editor_inject_text(e, string(bytes[:n]))
		ed.editor_update(e)
	}
	ed.editor_inject_key(e, sdl.K_RIGHT) // step past the closing ')'
	ed.editor_update(e)
	closed := e2e_pump_until(e, proc(e: ^ed.Editor) -> bool {return !e.signature.active}, 3000)
	e2e_check(ctx, "leaving the call's parentheses dismisses signature help", closed)
	e2e_check(ctx, "argument typed inside the snippet's parens", buf.buffer_line_str(&e.buf, 5) == "\tfmt.println(\"hi\")",
		fmt.tprintf("line 5 = %q", buf.buffer_line_str(&e.buf, 5)))
	e2e_check(ctx, "edits reached ols (document synced)", e.lsp_synced_version == e.buf.version)
}

// e2e_pump_until runs editor updates (event pump + LSP poll + popup
// refresh) until `cond` holds or `timeout_ms` elapses.
e2e_pump_until :: proc(e: ^ed.Editor, cond: proc(e: ^ed.Editor) -> bool, timeout_ms: int) -> bool {
	start := time.tick_now()
	for {
		ed.editor_update(e)
		if cond(e) {
			return true
		}
		if time.duration_milliseconds(time.tick_since(start)) > f64(timeout_ms) {
			return false
		}
		time.sleep(10 * time.Millisecond)
	}
}

e2e_render_frames :: proc(e: ^ed.Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: ed.Theme, n: int) {
	for _ in 0 ..< n {
		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
		sdl.RenderClear(renderer)
		ed.editor_render(e, renderer, font, 0, 0)
		sdl.RenderPresent(renderer)
	}
}

// ---------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------
run_e2e_suite :: proc(e: ^ed.Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: ed.Theme, primary_mod, word_mod: sdl.Keymod) -> bool {
	ctx: E2E_Ctx
	ctx.results = make([dynamic]Check)
	defer delete(ctx.results)

	e2e_test_typing(e, &ctx)
	e2e_test_navigation(e, &ctx, word_mod, primary_mod)
	e2e_test_selection(e, &ctx, primary_mod)
	e2e_test_multi_cursor(e, &ctx, primary_mod)
	e2e_test_clipboard(e, &ctx, primary_mod)
	e2e_test_undo_redo(e, &ctx, primary_mod)
	e2e_test_indent(e, &ctx)
	e2e_test_newline_autoindent(e, &ctx)
	e2e_test_backspace_delete(e, &ctx)
	e2e_test_file_io(e, &ctx)
	e2e_test_syntax_highlighting(&ctx)
	e2e_test_scroll_viewport(e, &ctx)
	e2e_test_render_smoke(e, &ctx, renderer, font, theme)
	e2e_test_lsp(e, &ctx, primary_mod, renderer, font, theme)

	return e2e_print_report(&ctx)
}

e2e_print_report :: proc(ctx: ^E2E_Ctx) -> bool {
	fmt.println()
	fmt.println("=================== odin_editor end-to-end report ===================")
	all_pass := true
	last_group := ""
	pass_count, fail_count := 0, 0
	for c in ctx.results {
		if c.group != last_group {
			fmt.printfln("\n[%s]", c.group)
			last_group = c.group
		}
		status := c.pass ? "PASS" : "FAIL"
		if c.pass {
			pass_count += 1
		} else {
			fail_count += 1
			all_pass = false
		}
		if len(c.detail) > 0 {
			fmt.printfln("  [%s] %s (%s)", status, c.name, c.detail)
		} else {
			fmt.printfln("  [%s] %s", status, c.name)
		}
	}
	fmt.println()
	fmt.printfln("Total: %d passed, %d failed, %d checks", pass_count, fail_count, len(ctx.results))
	fmt.println("=======================================================================")
	return all_pass
}
