package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:fmt"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_diagnostics_follow_edits_until_next_publish :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("x := bad\ny := 1")
		defer editor_destroy(&ed)
		publish(&ed, {{0, 5, 0, 8, 1, "undeclared 'bad'"}, {1, 0, 1, 1, 2, "w"}})
		testing.expect_value(t, editor_diagnostics(&ed)[0].start, buf.Position{0, 5})

		// Typing before the error pushes it right...
		ed.buf.cursors[0].pos = {0, 0}
		type_and_update(&ed, "zz")
		d := editor_diagnostics(&ed)
		testing.expect_value(t, d[0].start, buf.Position{0, 7})
		testing.expect_value(t, d[0].end, buf.Position{0, 10})
		// ...and inserting a line above moves the next one down.
		key_and_update(&ed, sdl.K_HOME)
		key_and_update(&ed, sdl.K_RETURN)
		d = editor_diagnostics(&ed)
		testing.expect_value(t, d[0].start, buf.Position{1, 7})
		testing.expect_value(t, d[1].start, buf.Position{2, 0})

		// Deleting the flagged text collapses the range.
		ed.buf.cursors[0] = {pos = {1, 10}, sel = {anchor = {1, 7}, active = true}}
		key_and_update(&ed, sdl.K_BACKSPACE)
		d = editor_diagnostics(&ed)
		testing.expect_value(t, d[0].start, d[0].end)

		// A new publish replaces the shifted copy.
		publish(&ed, {{2, 0, 2, 1, 2, "fresh"}})
		d = editor_diagnostics(&ed)
		testing.expect_value(t, len(d), 1)
		testing.expect_value(t, d[0].message, "fresh")
	})
}

@(test)
test_diagnostic_tags_reach_the_overlay :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("import \"core:fmt\"\nold()")
		defer editor_destroy(&ed)
		body := fmt.tprintf(`{{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{{"uri":"%s","diagnostics":[` +
			`{{"range":{{"start":{{"line":0,"character":0}},"end":{{"line":0,"character":17}}}},"severity":4,"message":"unused import","tags":[1]}},` +
			`{{"range":{{"start":{{"line":1,"character":0}},"end":{{"line":1,"character":3}}}},"severity":2,"message":"deprecated","tags":[2]}}]}}}}`, ed.document_uri)
		lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(body, context.temp_allocator))
		d := editor_diagnostics(&ed)
		testing.expect(t, len(d) == 2 && d[0].unnecessary && d[1].deprecated, "tags carried into the overlay")
	})
}

@(test)
test_problems_panel_lists_and_jumps :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("a\nb\nc\nd")
		defer editor_destroy(&ed)
		publish(&ed, {{3, 0, 3, 1, 2, "warn d"}, {1, 0, 1, 1, 1, "err b"}})
		// Another file in the package (e.g. from odin check).
		other := `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/other_file.odin","diagnostics":[{"range":{"start":{"line":9,"character":4},"end":{"line":9,"character":5}},"severity":1,"message":"elsewhere"}]}}`
		lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(other, context.temp_allocator))

		problems := editor_problems(&ed)
		testing.expect_value(t, len(problems), 3)
		testing.expect(t, problems[0].current && problems[0].message == "err b", "current file first, in order")
		testing.expect(t, !problems[2].current && problems[2].message == "elsewhere", "other files after")

		rows := editor_text_rows(&ed)
		key_and_update(&ed, sdl.K_M, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		testing.expect(t, ed.problems.open, "Ctrl+Shift+M opens the panel")
		testing.expect_value(t, editor_text_rows(&ed), rows - PROBLEMS_PANEL_ROWS)

		// Click the 2nd problem row (row 0 is the header).
		top := f32(editor_text_rows(&ed)) * ed.char_h
		mouse_click(&ed, 200, top + 2 * ed.char_h + 5)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{3, 0})
		testing.expect(t, len(editor_diag_tooltip_items(&ed)) == 1, "jumping shows the problem")

		// Clicking the other file's problem asks the host to open it.
		mouse_click(&ed, 200, top + 3 * ed.char_h + 5)
		path, line, ch, ok := editor_take_open_request(&ed)
		testing.expect(t, ok && strings.has_suffix(path, "other_file.odin") && line == 9 && ch == 4, "open request")
		_, _, _, again := editor_take_open_request(&ed)
		testing.expect(t, !again, "request is consumed")

		key_and_update(&ed, sdl.K_M, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		testing.expect(t, !ed.problems.open, "toggles closed")
	})
}

@(private)
fake_code_actions :: proc(ed: ^Editor, actions_json: string) {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":[%s]}}`, ed.lsp.latest_code_action_id, actions_json)
	lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(body, context.temp_allocator))
}

@(test)
test_quick_fix_menu_applies_edit_as_one_undo :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("package p\n\nimport \"core:fmt\"\nimport \"core:os\"\n\nmain :: proc() {}")
		defer editor_destroy(&ed)
		ed.buf.cursors[0].pos = {2, 3}
		uri := ed.document_uri

		key_and_update(&ed, sdl.K_PERIOD, sdl.KMOD_LCTRL)
		testing.expect(t, ed.actions.active && ed.actions.waiting, "Ctrl+. requests code actions")
		fake_code_actions(&ed, fmt.tprintf(
			`{{"title":"Invert if","kind":"refactor.rewrite","edit":{{"changes":{{"%s":[]}}}}}},` +
			`{{"title":"Remove unused imports","kind":"quickfix","isPreferred":true,"edit":{{"changes":{{"%s":[` +
			`{{"range":{{"start":{{"line":3,"character":0}},"end":{{"line":4,"character":0}}}},"newText":""}},` +
			`{{"range":{{"start":{{"line":2,"character":0}},"end":{{"line":3,"character":0}}}},"newText":""}}],` +
			`"file:///elsewhere.odin":[{{"range":{{"start":{{"line":0,"character":0}},"end":{{"line":0,"character":0}}}},"newText":"x"}}]}}}}}}`, uri, uri))
		editor_update(&ed)
		testing.expect(t, editor_code_actions_visible(&ed), "menu shows")
		// "Invert if" had no edits and was dropped; the preferred one is selected.
		testing.expect_value(t, len(ed.lsp.last_code_actions), 1)
		testing.expect_value(t, ed.actions.selected, 0)

		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, !ed.actions.active, "applying closes the menu")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "package p\n\n\nmain :: proc() {}")
		testing.expect_value(t, ed.actions.last_applied, 2)
		testing.expect_value(t, ed.actions.last_skipped, 1)

		editor_apply_action(&ed, .Undo)
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "package p\n\nimport \"core:fmt\"\nimport \"core:os\"\n\nmain :: proc() {}")
	})
}

@(test)
test_quick_fix_menu_empty_and_dismiss :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("x")
		defer editor_destroy(&ed)
		key_and_update(&ed, sdl.K_PERIOD, sdl.KMOD_LCTRL)
		fake_code_actions(&ed, "")
		editor_update(&ed)
		_, ok := editor_code_actions_layout(&ed)
		testing.expect(t, ok, "empty result still shows a 'no actions' menu")
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.actions.active, "Escape closes it")

		key_and_update(&ed, sdl.K_PERIOD, sdl.KMOD_LCTRL)
		key_and_update(&ed, sdl.K_END)
		key_and_update(&ed, sdl.K_HOME)
		testing.expect(t, !ed.actions.active, "moving the caret closes it")
	})
}

@(test)
test_republished_diagnostic_keeps_shifted_position :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("n := bad")
		defer editor_destroy(&ed)
		publish(&ed, {{0, 5, 0, 8, 1, "check error"}})
		editor_diagnostics(&ed)
		ed.buf.cursors[0].pos = {0, 0}
		type_and_update(&ed, "zz")
		// The server re-sends its stale check result plus a new parse error.
		publish(&ed, {{0, 5, 0, 8, 1, "check error"}, {0, 0, 0, 1, 1, "new"}})
		d := editor_diagnostics(&ed)
		testing.expect_value(t, len(d), 2)
		for x in d {
			if x.message == "check error" {
				testing.expect_value(t, x.start, buf.Position{0, 7}) // kept, not snapped back to 5
			}
		}
		// A different message at the same range is a new diagnostic.
		publish(&ed, {{0, 5, 0, 8, 1, "changed"}})
		testing.expect_value(t, editor_diagnostics(&ed)[0].start, buf.Position{0, 5})
	})
}
