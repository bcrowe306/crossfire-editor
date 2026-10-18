package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

@(private)
fake_locations :: proc(ed: ^Editor, result: string) {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":%s}}`, ed.lsp.latest_location_id, result)
	lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(body, context.temp_allocator))
}

@(private)
loc_json :: proc(uri: string, line, ch: int) -> string {
	return fmt.tprintf(`{{"uri":"%s","range":{{"start":{{"line":%d,"character":%d}},"end":{{"line":%d,"character":%d}}}}}}`, uri, line, ch, line, ch + 3)
}

NAV_TEXT :: "add :: proc(a, b: int) -> int {\n\treturn a + b\n}\n\nmain :: proc() {\n\tx := add(1, 2)\n\ty := add(x, 3)\n}"

@(test)
test_goto_definition_and_back_forward :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor(NAV_TEXT)
		defer editor_destroy(&ed)
		ed.buf.cursors[0].pos = {5, 7} // on "add" in main
		key_and_update(&ed, sdl.K_F12)
		testing.expect(t, ed.nav.waiting, "F12 asks the server")
		fake_locations(&ed, loc_json(ed.document_uri, 0, 0))
		editor_update(&ed)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 0})

		editor_navigate_back(&ed)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{5, 7})
		editor_navigate_forward(&ed)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 0})

		// Nothing found: a status message, the caret stays.
		key_and_update(&ed, sdl.K_F12)
		fake_locations(&ed, "[]")
		editor_update(&ed)
		testing.expect_value(t, editor_status_text(&ed), "No definition found")

		// LocationLink in another file -> the host is asked to open it.
		key_and_update(&ed, sdl.K_F12)
		fake_locations(&ed, `[{"targetUri":"file:///tmp/other_def.odin","targetRange":{"start":{"line":3,"character":0},"end":{"line":9,"character":1}},"targetSelectionRange":{"start":{"line":3,"character":2},"end":{"line":3,"character":6}}}]`)
		editor_update(&ed)
		path, line, ch, ok := editor_take_open_request(&ed)
		testing.expect(t, ok && strings.has_suffix(path, "other_def.odin") && line == 3 && ch == 2, "open request for the other file")
	})
}

@(test)
test_peek_definition_shows_source_and_enter_opens :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor(NAV_TEXT)
		defer editor_destroy(&ed)
		ed.buf.cursors[0].pos = {6, 7}
		key_and_update(&ed, sdl.K_F12, sdl.KMOD_LALT)
		fake_locations(&ed, loc_json(ed.document_uri, 0, 0))
		editor_update(&ed)
		p := &ed.nav.peek
		testing.expect(t, p.open && p.target_line == 0 && p.first_line == 0, "peek opened at the definition")
		testing.expect_value(t, p.lines[0], "add :: proc(a, b: int) -> int {")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{6, 7}) // caret didn't move
		_, ok := editor_peek_layout(&ed)
		testing.expect(t, ok, "peek has a layout")

		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, !ed.nav.peek.open, "Enter closes the peek")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 0})

		key_and_update(&ed, sdl.K_F12, sdl.KMOD_LALT)
		fake_locations(&ed, loc_json(ed.document_uri, 0, 0))
		editor_update(&ed)
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.nav.peek.open, "Escape closes the peek")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 0})
	})
}

@(test)
test_find_references_panel :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		other :: "/tmp/odin_editor_refs_other.odin"
		_ = os.write_entire_file(other, transmute([]u8)string("package p\nz := add(9, 9)\n"))
		defer os.remove(other)

		ed := make_diag_editor(NAV_TEXT)
		defer editor_destroy(&ed)
		ed.buf.cursors[0].pos = {0, 1}
		key_and_update(&ed, sdl.K_F12, sdl.KMOD_LSHIFT)
		fake_locations(&ed, fmt.tprintf("[%s,%s,%s,%s]",
			loc_json("file://" + other, 1, 5), loc_json(ed.document_uri, 6, 6), loc_json(ed.document_uri, 0, 0), loc_json(ed.document_uri, 5, 6)))
		editor_update(&ed)
		r := &ed.nav.refs
		testing.expect(t, r.open, "panel open")
		testing.expect_value(t, r.symbol, "add")
		testing.expect_value(t, len(r.items), 4)
		testing.expect(t, r.items[0].line == 0 && r.items[1].line == 5 && r.items[2].line == 6, "current file first, by line")
		testing.expect_value(t, r.items[1].preview, "x := add(1, 2)")
		testing.expect_value(t, r.items[3].preview, "z := add(9, 9)") // read from disk
		testing.expect_value(t, editor_text_rows(&ed), ed.visible_rows - PROBLEMS_PANEL_ROWS)

		top := f32(editor_text_rows(&ed)) * ed.char_h
		mouse_click(&ed, 200, top + 2 * ed.char_h + 5) // row 1
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{5, 6})
		key_and_update(&ed, sdl.K_F4)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{6, 6})
		key_and_update(&ed, sdl.K_F4) // into the other file: open request
		path, _, _, ok := editor_take_open_request(&ed)
		testing.expect(t, ok && strings.has_suffix(path, "odin_editor_refs_other.odin"), "stepping into another file asks the host")

		key_and_update(&ed, sdl.K_M, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		testing.expect(t, ed.problems.open && !r.open, "problems panel replaces references")
		key_and_update(&ed, sdl.K_M, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		key_and_update(&ed, sdl.K_F12, sdl.KMOD_LSHIFT)
		fake_locations(&ed, fmt.tprintf("[%s]", loc_json(ed.document_uri, 0, 0)))
		editor_update(&ed)
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.nav.refs.open, "Escape closes the references panel")
	})
}

@(test)
test_ctrl_click_goes_to_definition :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor(NAV_TEXT)
		defer editor_destroy(&ed)
		before := ed.lsp.latest_location_id
		modifier_key(&ed, sdl.K_LCTRL, true)
		x, y := px(&ed, 5, 7)
		mouse_click(&ed, x, y)
		modifier_key(&ed, sdl.K_LCTRL, false)
		testing.expect(t, ed.lsp.latest_location_id > before, "Ctrl+click requested the definition")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{5, 7})
	})
}
