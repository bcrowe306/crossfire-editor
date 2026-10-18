package code_editor

import buf "../buffer"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_find_matches_modes :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		b := buf.buffer_init()
		defer buf.buffer_destroy(&b)
		buf.buffer_set_text(&b, "Foo foo food\nbar_foo FOO")

		m, bad := find_matches(&b, "foo", {}, context.temp_allocator)
		testing.expect(t, !bad, "plain never errors")
		testing.expect_value(t, len(m), 5) // case-insensitive, substrings: Foo foo foo(d) (bar_)foo FOO
		m, _ = find_matches(&b, "foo", {case_sensitive = true}, context.temp_allocator)
		testing.expect_value(t, len(m), 3)
		m, _ = find_matches(&b, "foo", {whole_word = true}, context.temp_allocator)
		testing.expect_value(t, len(m), 3) // Foo, foo, FOO (not food / bar_foo)
		testing.expect_value(t, m[2], Find_Match{{1, 8}, {1, 11}})

		m, _ = find_matches(&b, "f[o]+d?", {regex = true, case_sensitive = true}, context.temp_allocator)
		testing.expect_value(t, len(m), 3)
		testing.expect_value(t, m[1], Find_Match{{0, 8}, {0, 12}}) // "food"
		_, bad = find_matches(&b, "f(o", {regex = true}, context.temp_allocator)
		testing.expect(t, bad, "invalid regex is reported")
	})
}

@(test)
test_find_bar_incremental_search_and_navigation :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "alpha\nbeta alpha\ngamma alpha")
		ed.buf.cursors[0].pos = {1, 0}

		key_and_update(&ed, sdl.K_F, sdl.KMOD_LCTRL)
		testing.expect(t, ed.find.open && ed.find.focused, "Ctrl+F opens and focuses the bar")
		type_and_update(&ed, "alp")
		// Starts searching from the caret: first hit is on line 1.
		s, e, _ := buf.selection_range(ed.buf.cursors[0])
		testing.expect_value(t, s, buf.Position{1, 5})
		testing.expect_value(t, e, buf.Position{1, 8})
		testing.expect_value(t, editor_find_status(&ed), "2 of 3")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "alpha\nbeta alpha\ngamma alpha") // typing went to the bar

		key_and_update(&ed, sdl.K_RETURN)
		testing.expect_value(t, editor_find_status(&ed), "3 of 3")
		key_and_update(&ed, sdl.K_RETURN) // wraps
		testing.expect_value(t, editor_find_status(&ed), "1 of 3")
		key_and_update(&ed, sdl.K_RETURN, sdl.KMOD_LSHIFT) // back, wraps
		testing.expect_value(t, editor_find_status(&ed), "3 of 3")

		key_and_update(&ed, sdl.K_BACKSPACE)
		key_and_update(&ed, sdl.K_BACKSPACE)
		key_and_update(&ed, sdl.K_BACKSPACE)
		type_and_update(&ed, "zzz")
		testing.expect_value(t, editor_find_status(&ed), "No results")

		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.find.open, "Escape closes")
		type_and_update(&ed, "X")
		testing.expect(t, strings.contains(editor_to_string(&ed, context.temp_allocator), "X"), "typing edits the document again")
	})
}

@(test)
test_find_options_toggle_by_alt_keys_and_click :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "Foo foo food")
		ed.char_w, ed.char_h = 10, 20
		ed.visible_cols, ed.visible_rows = 80, 20
		key_and_update(&ed, sdl.K_F, sdl.KMOD_LCTRL)
		type_and_update(&ed, "foo")
		testing.expect_value(t, len(ed.find.matches), 3)
		key_and_update(&ed, sdl.K_C, sdl.KMOD_LALT)
		testing.expect_value(t, len(ed.find.matches), 2)
		key_and_update(&ed, sdl.K_W, sdl.KMOD_LALT)
		testing.expect_value(t, len(ed.find.matches), 1)

		l, ok := editor_find_layout(&ed)
		testing.expect(t, ok, "bar has a layout")
		mouse_click(&ed, l.opt_word.x + 2, l.opt_word.y + 2)
		testing.expect(t, !ed.find.opts.whole_word, "clicking W toggles it off")
		testing.expect_value(t, len(ed.find.matches), 2)

		// Clicking the text gives focus back to the document.
		mouse_click(&ed, editor_gutter_width(&ed) + 5, 10)
		testing.expect(t, ed.find.open && !ed.find.focused, "bar stays open, loses focus")
	})
}

@(test)
test_replace_current_and_all :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "cat cat\ncat")
		key_and_update(&ed, sdl.K_H, sdl.KMOD_LCTRL)
		testing.expect(t, ed.find.replace_mode && ed.find.field == .Query, "Ctrl+H opens replace")
		type_and_update(&ed, "cat")
		key_and_update(&ed, sdl.K_TAB)
		type_and_update(&ed, "dog")
		testing.expect_value(t, strings.to_string(ed.find.replacement), "dog")

		key_and_update(&ed, sdl.K_RETURN) // replaces the selected first match
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "dog cat\ncat")
		testing.expect_value(t, editor_find_status(&ed), "1 of 2") // moved to the next one

		key_and_update(&ed, sdl.K_RETURN, sdl.KMOD_LCTRL | sdl.KMOD_LALT) // replace all
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "dog dog\ndog")
		testing.expect_value(t, ed.find.last_replaced, 2)
		editor_apply_action(&ed, .Undo)
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "dog cat\ncat") // one undo step
	})
}

@(test)
test_regex_replace_with_groups :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "x := 1\ny := 22")
		key_and_update(&ed, sdl.K_H, sdl.KMOD_LCTRL)
		key_and_update(&ed, sdl.K_R, sdl.KMOD_LALT)
		type_and_update(&ed, "([a-z]) := ([0-9]+)")
		key_and_update(&ed, sdl.K_TAB)
		type_and_update(&ed, "$2 =: $1")
		testing.expect_value(t, editor_replace_all(&ed), 2)
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "1 =: x\n22 =: y")
	})
}

@(test)
test_f3_without_query_searches_selection :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "one two one")
		ed.buf.cursors[0] = {pos = {0, 3}, sel = {anchor = {0, 0}, active = true}}
		key_and_update(&ed, sdl.K_F3)
		s, _, _ := buf.selection_range(ed.buf.cursors[0])
		testing.expect_value(t, s, buf.Position{0, 8})
		testing.expect(t, !ed.find.focused, "F3 doesn't steal focus")
		type_and_update(&ed, "Z")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "one two Z")
	})
}

@(test)
test_select_next_and_all_occurrences :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "val value val\nval")
		ed.buf.cursors[0].pos = {0, 1}

		key_and_update(&ed, sdl.K_D, sdl.KMOD_LCTRL) // selects "val"
		key_and_update(&ed, sdl.K_D, sdl.KMOD_LCTRL) // next whole-word "val" (skips "value")
		key_and_update(&ed, sdl.K_D, sdl.KMOD_LCTRL)
		testing.expect_value(t, len(ed.buf.cursors), 3)
		s, _, _ := buf.selection_range(ed.buf.cursors[1])
		testing.expect_value(t, s, buf.Position{0, 10})
		s, _, _ = buf.selection_range(ed.buf.cursors[2])
		testing.expect_value(t, s, buf.Position{1, 0})
		key_and_update(&ed, sdl.K_D, sdl.KMOD_LCTRL) // wraps; all taken -> no change
		testing.expect_value(t, len(ed.buf.cursors), 3)
		type_and_update(&ed, "v")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "v value v\nv")

		// A manual selection matches substrings.
		editor_set_text(&ed, "val value")
		ed.buf.cursors[0] = {pos = {0, 3}, sel = {anchor = {0, 0}, active = true}}
		key_and_update(&ed, sdl.K_D, sdl.KMOD_LCTRL)
		testing.expect_value(t, len(ed.buf.cursors), 2)

		editor_set_text(&ed, "ab x ab y ab")
		key_and_update(&ed, sdl.K_L, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		testing.expect_value(t, len(ed.buf.cursors), 3)
	})
}

@(test)
test_unhandled_chords_fall_through_while_find_focused :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "abc")
		key_and_update(&ed, sdl.K_F, sdl.KMOD_LCTRL)
		key_and_update(&ed, sdl.K_LEFT) // swallowed: plain key
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 0})
		key_and_update(&ed, sdl.K_A, sdl.KMOD_LCTRL) // chord falls through: select all
		_, e, ok := buf.selection_range(ed.buf.cursors[0])
		testing.expect(t, ok && e == buf.Position{0, 3}, "Ctrl+A still works")
	})
}
