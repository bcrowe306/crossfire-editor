package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

// publish feeds a publishDiagnostics notification for the test document.
// Each entry: {line, start_char, end_line, end_char, severity, message}.
@(private)
Fake_Diag :: struct {
	l0, c0, l1, c1, sev: int,
	msg:                 string,
}

@(private)
publish :: proc(ed: ^Editor, diags: []Fake_Diag) {
	sb := strings.builder_make(context.temp_allocator)
	for d, i in diags {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		fmt.sbprintf(&sb, `{{"range":{{"start":{{"line":%d,"character":%d}},"end":{{"line":%d,"character":%d}}}},"severity":%d,"message":%q,"source":"test"}}`,
			d.l0, d.c0, d.l1, d.c1, d.sev, d.msg)
	}
	body := fmt.tprintf(`{{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{{"uri":"%s","diagnostics":[%s]}}}}`,
		ed.document_uri, strings.to_string(sb))
	lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(body, context.temp_allocator))
}

@(private)
make_diag_editor :: proc(text: string) -> Editor {
	ed := make_lsp_test_editor(text)
	ed.char_w, ed.char_h = 10, 20
	ed.visible_rows, ed.visible_cols = 20, 60
	return ed
}

@(test)
test_diagnostics_convert_utf16_and_widen_empty_ranges :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("s := \"😀\"; bad\nok\nx")
		defer editor_destroy(&ed)
		// "bad" is at UTF-16 10..13 (😀 = 2 units) but bytes 12..15.
		publish(&ed, {{0, 10, 0, 13, 1, "undeclared 'bad'"}, {2, 1, 2, 1, 2, "expected ';'"}, {1, 0, 1, 1, 3, "note"}})

		diags := editor_diagnostics(&ed)
		testing.expect_value(t, len(diags), 3)
		testing.expect_value(t, diags[0].start, buf.Position{0, 12})
		testing.expect_value(t, diags[0].end, buf.Position{0, 15})
		testing.expect_value(t, diags[1].severity, Diagnostic_Severity.Information)
		// Zero-width at end of line 2 ("x") covers the phantom EOL cell.
		testing.expect_value(t, diags[2].start, buf.Position{2, 1})
		testing.expect_value(t, diags[2].end, buf.Position{2, 1}) // stored as sent
		_, wide_end := diag_extent(&ed, diags[2])
		testing.expect_value(t, wide_end, buf.Position{2, 2}) // drawn one cell wide

		counts := editor_diagnostic_counts(&ed)
		testing.expect_value(t, counts[.Error], 1)
		testing.expect_value(t, counts[.Warning], 1)
		testing.expect_value(t, counts[.Information], 1)
	})
}

@(test)
test_line_severity_picks_most_severe :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("aaaa\nbbbb\ncccc")
		defer editor_destroy(&ed)
		publish(&ed, {{0, 0, 0, 1, 2, "w"}, {0, 2, 0, 3, 1, "e"}, {1, 0, 2, 2, 4, "multi-line hint"}})
		diags := editor_diagnostics(&ed)
		sev, ok := line_severity(diags, 0)
		testing.expect(t, ok && sev == .Error, "error beats warning")
		sev, ok = line_severity(diags, 2)
		testing.expect(t, ok && sev == .Hint, "multi-line range covers its last line")
		_, ok = line_severity(diags, 3)
		testing.expect(t, !ok, "no diagnostics past the end")
	})
}

@(test)
test_f8_navigates_diagnostics_and_shows_tooltip :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("one\ntwo\nthree\nfour")
		defer editor_destroy(&ed)
		publish(&ed, {{3, 1, 3, 2, 1, "fourth"}, {1, 0, 1, 3, 2, "second"}})
		ed.buf.cursors[0].pos = {0, 0}

		key_and_update(&ed, sdl.K_F8)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{1, 0})
		items := editor_diag_tooltip_items(&ed)
		testing.expect(t, len(items) == 1 && items[0].message == "second", "tooltip shows the diagnostic")

		key_and_update(&ed, sdl.K_F8)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{3, 1})
		key_and_update(&ed, sdl.K_F8) // wraps
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{1, 0})
		key_and_update(&ed, sdl.K_F8, sdl.KMOD_LSHIFT) // previous, wraps backwards
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{3, 1})

		key_and_update(&ed, sdl.K_LEFT)
		testing.expect(t, len(editor_diag_tooltip_items(&ed)) == 0, "moving the caret hides a keyboard tooltip")

		key_and_update(&ed, sdl.K_F8)
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, len(editor_diag_tooltip_items(&ed)) == 0, "Escape hides it")
	})
}

@(test)
test_hover_shows_tooltip_after_dwell :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("good bad good\nline two")
		defer editor_destroy(&ed)
		publish(&ed, {{0, 5, 0, 8, 1, "bad is bad"}, {1, 0, 1, 4, 2, "warn two"}})

		// Over 'a' of "bad".
		mouse_move(&ed, editor_gutter_width(&ed) + 6 * 10 + 5, 10)
		editor_update(&ed)
		testing.expect(t, len(editor_diag_tooltip_items(&ed)) == 0, "no tooltip before the dwell time")
		ed.diag_tip.hover_since = time.tick_add(time.tick_now(), -DIAG_HOVER_DELAY)
		editor_update(&ed)
		items := editor_diag_tooltip_items(&ed)
		testing.expect(t, len(items) == 1 && items[0].message == "bad is bad", "dwell shows the tooltip")

		// Moving onto the tooltip keeps it open...
		layout, ok := editor_diag_tooltip_layout(&ed)
		testing.expect(t, ok, "tooltip has a layout")
		mouse_move(&ed, layout.rect.x + 5, layout.rect.y + 5)
		testing.expect(t, len(editor_diag_tooltip_items(&ed)) == 1, "pointer over the tooltip keeps it")

		// ...moving to clean text hides it.
		mouse_move(&ed, editor_gutter_width(&ed) + 1 * 10 + 5, 10)
		testing.expect(t, len(editor_diag_tooltip_items(&ed)) == 0, "clean text hides the tooltip")

		// Hovering the gutter shows every diagnostic on that line.
		mouse_move(&ed, 10, 20 + 10)
		ed.diag_tip.hover_since = time.tick_add(time.tick_now(), -DIAG_HOVER_DELAY)
		editor_update(&ed)
		items = editor_diag_tooltip_items(&ed)
		testing.expect(t, len(items) == 1 && items[0].message == "warn two", "gutter hover shows the line's diagnostics")
	})
}

@(test)
test_diag_tooltip_layout_and_wrapping :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("\n\n\n\n\nx := y")
		defer editor_destroy(&ed)
		long := "this message is long enough that it has to wrap across more than one line of the tooltip because it exceeds eighty columns"
		publish(&ed, {{5, 5, 5, 6, 1, long}})
		ed.buf.cursors[0].pos = {0, 0}
		key_and_update(&ed, sdl.K_F8)

		layout, ok := editor_diag_tooltip_layout(&ed)
		testing.expect(t, ok, "visible")
		testing.expect(t, len(layout.lines) >= 2, "long message wraps")
		testing.expect(t, strings.has_prefix(layout.lines[0].text, "error: "), "first line carries the severity label")
		for l in layout.lines {
			testing.expectf(t, text_cols(l.text) <= DIAG_TOOLTIP_MAX_COLS, "line too long: %q", l.text)
		}
		_, ly := editor_position_to_screen(&ed, {5, 5})
		testing.expect(t, layout.rect.y + layout.rect.h <= ly, "tooltip sits above the diagnostic's line")

		testing.expect_value(t, len(wrap_text("a b\n\nc", 80)), 3)
		testing.expect_value(t, wrap_text("abcdef ghij", 6)[1], "ghij")
	})
}

@(test)
test_completion_text_edit_honors_utf16 :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("é := foo")
		defer editor_destroy(&ed)
		ed.buf.cursors[0].pos = {0, 9} // bytes: é is 2
		editor_request_completion(&ed)
		// Server range starts at UTF-16 5 = byte 6 ("foo").
		fake_completion_response(&ed,
			`{"label":"foobar","textEdit":{"newText":"foobar","range":{"start":{"line":0,"character":5},"end":{"line":0,"character":8}}}}`)
		editor_update(&ed)
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "é := foobar")
	})
}
