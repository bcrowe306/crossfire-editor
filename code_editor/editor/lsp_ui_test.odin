package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

// make_lsp_test_editor returns an editor with an LSP client attached but
// no server process: requests are recorded (ids, pending kinds) but go
// nowhere, and tests play the server's part by feeding synthetic
// responses through `lspc.client_feed_bytes`.
@(private)
make_lsp_test_editor :: proc(text: string) -> Editor {
	ed := editor_init(.Other)
	ed.lsp = lspc.client_init()
	ed.lsp_enabled = true
	ed.lsp.initialized = true
	editor_set_text(&ed, text)
	ed.document_uri = strings.clone("file:///tmp/lsp_ui_test.odin")
	ed.document_key = lspc.uri_key(ed.document_uri)
	return ed
}

@(private)
fake_completion_response :: proc(ed: ^Editor, items_json: string) {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":[%s]}}`, ed.lsp.latest_completion_id, items_json)
	lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(body, context.temp_allocator))
}

@(private)
fake_signature_response :: proc(ed: ^Editor, result_json: string) {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":%s}}`, ed.lsp.latest_signature_id, result_json)
	lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(body, context.temp_allocator))
}

@(private)
type_and_update :: proc(ed: ^Editor, text: string) {
	editor_inject_text(ed, text)
	editor_update(ed)
}

@(private)
key_and_update :: proc(ed: ^Editor, key: sdl.Keycode, mod: sdl.Keymod = {}) {
	editor_inject_key(ed, key, mod)
	editor_update(ed)
}

FMT_ITEMS :: `{"label":"println","kind":3,"detail":"proc(args: ..any)"},` +
	`{"label":"printf","kind":3,"detail":"proc(fmt: string, args: ..any)"},` +
	`{"label":"sbprint","kind":3},` +
	`{"label":"tprintf","kind":3}`

@(test)
test_dot_triggers_completion_and_filters_as_you_type :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)

		type_and_update(&ed, "fmt.")
		testing.expect(t, ed.completion.active, "typing '.' opens completion")
		testing.expect(t, ed.completion.waiting, "popup waits for the server")
		testing.expect(t, !editor_completion_visible(&ed), "nothing shown before the response")
		testing.expect_value(t, ed.completion.anchor, buf.Position{0, 4})

		fake_completion_response(&ed, FMT_ITEMS)
		editor_update(&ed)
		testing.expect(t, editor_completion_visible(&ed), "response shows the popup")
		testing.expect_value(t, len(ed.completion.filtered), 4)

		type_and_update(&ed, "pr")
		testing.expect_value(t, len(ed.completion.filtered), 2)
		item, _ := editor_completion_selected_item(&ed)
		testing.expect_value(t, item.label, "println")

		// "tf" isn't a prefix of anything, and fuzzy matches must share
		// the first character, so "printf" stays and "tprintf" doesn't.
		type_and_update(&ed, "tf")
		testing.expect_value(t, len(ed.completion.filtered), 1)
		item, _ = editor_completion_selected_item(&ed)
		testing.expect_value(t, item.label, "printf")
	})
}

@(test)
test_accept_completion_replaces_prefix_as_one_undo_step :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)

		type_and_update(&ed, "fmt.")
		fake_completion_response(&ed, FMT_ITEMS)
		editor_update(&ed)
		type_and_update(&ed, "pri")
		key_and_update(&ed, sdl.K_DOWN) // println -> printf
		key_and_update(&ed, sdl.K_RETURN)

		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "fmt.printf")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 10})
		testing.expect(t, !ed.completion.active, "accept closes the popup")
		testing.expect_value(t, buf.buffer_line_count(&ed.buf), 1)

		editor_apply_action(&ed, .Undo)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "fmt.pri")
	})
}

@(test)
test_accept_uses_text_edit_range :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("x := foo")
		defer editor_destroy(&ed)
		ed.buf.cursors[0].pos = {0, 8}

		editor_request_completion(&ed)
		testing.expect_value(t, ed.completion.anchor, buf.Position{0, 5})
		// The server says to replace from column 5 with "foobar".
		fake_completion_response(&ed,
			`{"label":"foobar","kind":6,"textEdit":{"newText":"foobar","range":{"start":{"line":0,"character":5},"end":{"line":0,"character":8}}}}`)
		editor_update(&ed)
		key_and_update(&ed, sdl.K_TAB)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "x := foobar")
	})
}

@(test)
test_completion_navigation_and_dismiss :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)

		type_and_update(&ed, "fmt.")
		fake_completion_response(&ed, FMT_ITEMS)
		editor_update(&ed)

		key_and_update(&ed, sdl.K_UP)
		testing.expect_value(t, ed.completion.selected, 3) // wraps to last
		key_and_update(&ed, sdl.K_DOWN)
		testing.expect_value(t, ed.completion.selected, 0) // wraps to first
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 4}) // cursor untouched

		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.completion.active, "Escape closes completion")
		key_and_update(&ed, sdl.K_DOWN)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 4}) // single line: Down is a no-op move
	})
}

@(test)
test_completion_closes_when_cursor_leaves_word :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)

		type_and_update(&ed, "fmt.")
		fake_completion_response(&ed, FMT_ITEMS)
		editor_update(&ed)
		testing.expect(t, editor_completion_visible(&ed), "setup: popup visible")

		key_and_update(&ed, sdl.K_LEFT) // back before the '.' anchor
		testing.expect(t, !ed.completion.active, "moving left of the anchor closes the popup")
	})
}

@(test)
test_completion_closes_when_nothing_matches :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)

		type_and_update(&ed, "fmt.")
		fake_completion_response(&ed, FMT_ITEMS)
		editor_update(&ed)
		type_and_update(&ed, "zz")
		testing.expect(t, !ed.completion.active, "no matches closes the popup")
	})
}

@(test)
test_identifier_typing_triggers_completion_but_numbers_dont :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)

		type_and_update(&ed, "1")
		testing.expect(t, !ed.completion.active, "numeric literal doesn't trigger completion")
		type_and_update(&ed, " a")
		testing.expect(t, ed.completion.active, "first identifier char triggers completion")
		testing.expect_value(t, ed.completion.anchor, buf.Position{0, 2})
	})
}

// sig_add builds a signatureHelp result for `add(a, b)` with the given
// active parameter. (Built by concatenation: JSON braces would be
// interpreted by fmt's format-string syntax.)
@(private)
sig_add :: proc(active_param: int) -> string {
	return strings.concatenate({
		`{"activeSignature":0,"activeParameter":`, fmt.tprint(active_param),
		`,"signatures":[{"label":"add :: proc(a: int, b: int) -> int","parameters":[{"label":"a: int"},{"label":"b: int"}]}]}`,
	}, context.temp_allocator)
}

@(test)
test_signature_help_wraps_long_signatures :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		type_and_update(&ed, "add(")
		fake_signature_response(&ed, sig_add(1))
		editor_update(&ed)
		text :: proc(line: Signature_Line) -> string { return utf8.runes_to_string(line.runes, context.temp_allocator) }

		// Wide enough: one line
		lines, cols := signature_wrapped(&ed, 100)
		testing.expect_value(t, len(lines), 1)
		testing.expect_value(t, cols, len("add :: proc(a: int, b: int) -> int"))
		// Narrow: broken after spaces, continuations indented, nothing lost, the active
		// parameter still marked
		lines, cols = signature_wrapped(&ed, 16)
		testing.expect(t, len(lines) > 1, "wrapped")
		testing.expect(t, cols <= 16, "within the width")
		joined := strings.builder_make(context.temp_allocator)
		active := strings.builder_make(context.temp_allocator)
		for line, i in lines {
			if i > 0 do testing.expect(t, strings.has_prefix(text(line), "    "), "indented")
			strings.write_string(&joined, strings.trim_space(text(line)))
			strings.write_byte(&joined, ' ')
			for r, j in line.runes do if line.styles[j] == .Active do strings.write_rune(&active, r)
		}
		testing.expect_value(t, strings.trim_space(strings.to_string(joined)), "add :: proc(a: int, b: int) -> int")
		testing.expect_value(t, strings.to_string(active), "b: int")
		testing.expect_value(t, text(lines[0]), "add :: proc(a: ")
		// The tooltip is laid out as tall as its lines
		ed.visible_cols = 18
		layout := editor_popup_layout(&ed)
		wrapped, _ := signature_wrapped(&ed, signature_max_cols(&ed))
		testing.expect_value(t, layout.signature.h, f32(len(wrapped)) * ed.char_h + 2 * POPUP_PAD)
	})
}

@(test)
test_signature_help_tracks_active_parameter_and_closes :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)

		type_and_update(&ed, "add(")
		testing.expect(t, ed.signature.active, "'(' opens signature help")
		testing.expect(t, ed.signature.waiting, "waits for the server")
		fake_signature_response(&ed, sig_add(0))
		editor_update(&ed)
		testing.expect(t, editor_signature_visible(&ed), "signature visible after response")
		testing.expect_value(t, editor_signature_active_param(&ed), "a: int")

		// Typing re-requests; ',' moves to the 2nd parameter.
		first_id := ed.lsp.latest_signature_id
		type_and_update(&ed, "1,")
		testing.expect(t, ed.lsp.latest_signature_id > first_id, "edit re-requests signature help")
		fake_signature_response(&ed, sig_add(1))
		editor_update(&ed)
		label, before, active, after := editor_signature_active_parts(&ed)
		testing.expect_value(t, active, "b: int")
		testing.expect_value(t, strings.concatenate({before, active, after}, context.temp_allocator), label)
		// "b: int" must resolve to the 2nd param's occurrence, after "a: int, ".
		testing.expect(t, strings.has_suffix(before, "a: int, "), "active part located after the first param")

		// The server returning null (to the re-request the edit sends)
		// closes the tooltip.
		type_and_update(&ed, "2")
		fake_signature_response(&ed, "null")
		editor_update(&ed)
		testing.expect(t, !ed.signature.active, "null response closes signature help")
	})
}

@(test)
test_signature_help_closes_after_closing_paren :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)

		type_and_update(&ed, "add(")
		fake_signature_response(&ed, sig_add(0))
		editor_update(&ed)
		// Parens inside strings don't count.
		type_and_update(&ed, `")"`)
		fake_signature_response(&ed, sig_add(0))
		editor_update(&ed)
		testing.expect(t, editor_signature_visible(&ed), "')' inside a string keeps the tooltip open")

		// OLS keeps answering just past ')', so the client closes it.
		type_and_update(&ed, ", 2)")
		testing.expect(t, !ed.signature.active, "closing paren closes the tooltip even if the server still answers")
	})
}

@(test)
test_cursor_in_call_spans_lines :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("fmt.println(\n\tx, // ) comment\n\ty)")
		defer editor_destroy(&ed)
		ed.buf.cursors[0].pos = {2, 2}
		testing.expect(t, editor_cursor_in_call(&ed), "unclosed '(' on an earlier line counts")
		ed.buf.cursors[0].pos = {2, 3}
		testing.expect(t, !editor_cursor_in_call(&ed), "after the final ')' we're outside")
	})
}

@(test)
test_escape_closes_signature_help :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)

		type_and_update(&ed, "add(")
		fake_signature_response(&ed, sig_add(0))
		editor_update(&ed)
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.signature.active, "Escape closes signature help")
	})
}

@(test)
test_edits_are_synced_to_lsp_before_requests :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("package p")
		defer editor_destroy(&ed)

		editor_update(&ed)
		testing.expect(t, ed.lsp_doc_open, "didOpen sent once initialized")
		testing.expect_value(t, ed.lsp_synced_version, ed.buf.version)
		opened_version := ed.lsp_version

		ed.buf.cursors[0].pos = {0, 9}
		editor_inject_text(&ed, "\n")
		editor_pump_injected_events(&ed)
		testing.expect(t, ed.lsp_synced_version != ed.buf.version, "edit not yet synced")

		editor_request_completion(&ed)
		testing.expect_value(t, ed.lsp_synced_version, ed.buf.version)
		testing.expect_value(t, ed.lsp_version, opened_version + 1)
	})
}

@(test)
test_did_open_deferred_until_initialized :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("package p")
		defer editor_destroy(&ed)
		ed.lsp.initialized = false

		editor_update(&ed)
		testing.expect(t, !ed.lsp_doc_open, "no didOpen before initialize completes")
		editor_request_completion(&ed)
		testing.expect(t, !ed.completion.active, "no completion before initialize completes")

		ed.lsp.initialized = true
		editor_update(&ed)
		testing.expect(t, ed.lsp_doc_open, "didOpen sent after initialize")
	})
}

@(test)
test_completion_match_scoring :: proc(t: ^testing.T) {
	testing.expect_value(t, completion_match("println", ""), 2)
	testing.expect_value(t, completion_match("println", "PRI"), 2)
	testing.expect_value(t, completion_match("println", "pln"), 1)
	testing.expect_value(t, completion_match("println", "ln"), 0)
	testing.expect_value(t, completion_match("p", "pr"), 0)
}

@(test)
test_popup_layout_places_signature_above_and_completion_below :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("\n\n\n")
		defer editor_destroy(&ed)
		ed.buf.cursors[0].pos = {3, 0}

		type_and_update(&ed, "add(")
		fake_signature_response(&ed, sig_add(0))
		editor_update(&ed)
		type_and_update(&ed, "x.")
		fake_completion_response(&ed, FMT_ITEMS)
		editor_update(&ed)
		testing.expect(t, editor_signature_visible(&ed), "signature still visible")
		testing.expect(t, editor_completion_visible(&ed), "completion visible")

		layout := editor_popup_layout(&ed)
		_, cy := editor_cursor_screen_pos(&ed)
		testing.expect(t, layout.signature.y + layout.signature.h <= cy, "signature above the cursor line")
		testing.expect(t, layout.completion.y >= cy + ed.char_h, "completion below the cursor line")

		// On line 0 there's no room above: both go below, without overlap.
		ed2 := make_lsp_test_editor("")
		defer editor_destroy(&ed2)
		type_and_update(&ed2, "add(")
		fake_signature_response(&ed2, sig_add(0))
		editor_update(&ed2)
		type_and_update(&ed2, "x.")
		fake_completion_response(&ed2, FMT_ITEMS)
		editor_update(&ed2)
		l2 := editor_popup_layout(&ed2)
		testing.expect(t, l2.signature.y >= ed2.char_h, "signature flips below on line 0")
		testing.expect(t, l2.completion.y >= l2.signature.y + l2.signature.h, "completion stacks under signature")
	})
}

@(test)
test_mouse_click_accounts_for_gutter_and_origin :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "hello world\nsecond")
		ed.origin_x, ed.origin_y = 100, 50

		ev: sdl.Event
		ev.type = .MOUSE_BUTTON_DOWN
		ev.button.button = 1
		ev.button.clicks = 1
		ev.button.x = 100 + editor_gutter_width(&ed) + 3 * ed.char_w
		ev.button.y = 50 + 1.5 * ed.char_h
		editor_handle_event(&ed, ev)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{1, 3})
	})
}

// OLS completes a package that isn't imported with an additionalTextEdit adding the import
// (what Zed applies on Tab): accepting it inserts both, the caret staying after the completion
@(test)
test_accepting_a_package_imports_it :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("package scripts\n\nmain :: proc() {\n\t\n}\n")
		defer editor_destroy(&ed)
		clear(&ed.buf.cursors)
		append(&ed.buf.cursors, buf.Cursor{pos = {3, 1}})
		_ = editor_run_action(&ed, .TriggerCompletion)
		editor_update(&ed)
		fake_completion_response(&ed, `{"label":"fmt","kind":9,"insertText":"fmt","additionalTextEdits":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":0}},"newText":"import \"core:fmt\"\n"}]}`)
		editor_update(&ed)
		testing.expect(t, editor_completion_visible(&ed), "the package is offered")
		type_and_update(&ed, "fm")
		key_and_update(&ed, sdl.K_TAB)

		text := buf.buffer_to_string(&ed.buf, context.temp_allocator)
		testing.expect_value(t, text, "package scripts\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt\n}\n")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{4, 4}) // after "fmt", a line further down
		editor_apply_action(&ed, .Undo)
		testing.expect_value(t, buf.buffer_to_string(&ed.buf, context.temp_allocator), "package scripts\n\nmain :: proc() {\n\tfm\n}\n")
	})
}
