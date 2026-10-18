package code_editor

import buf "../buffer"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// --- visual columns ----------------------------------------------------------

@(test)
test_visual_col_expands_tabs_to_stops :: proc(t: ^testing.T) {
	line := "\tab\tc"
	testing.expect_value(t, visual_col_of(line, 0, 4), 0)
	testing.expect_value(t, visual_col_of(line, 1, 4), 4) // after the tab
	testing.expect_value(t, visual_col_of(line, 3, 4), 6)
	testing.expect_value(t, visual_col_of(line, 4, 4), 8) // tab from 6 -> 8
	testing.expect_value(t, line_visual_width(line, 4), 9)
	testing.expect_value(t, line_visual_width("héllo", 4), 5) // runes, not bytes
}

@(test)
test_byte_col_at_visual_snaps_to_nearest_boundary :: proc(t: ^testing.T) {
	line := "\tab"
	testing.expect_value(t, byte_col_at_visual(line, 1.0, 4), 0) // left half of the tab
	testing.expect_value(t, byte_col_at_visual(line, 3.0, 4), 1) // right half
	testing.expect_value(t, byte_col_at_visual(line, 4.4, 4), 1) // before 'a'
	testing.expect_value(t, byte_col_at_visual(line, 4.6, 4), 2) // after 'a'
	testing.expect_value(t, byte_col_at_visual(line, 99, 4), 3)  // past the end
	testing.expect_value(t, byte_col_at_visual(line, -2, 4), 0)
	testing.expect_value(t, byte_col_at_visual("héllo", 2.0, 4), 3) // after 'é' (2 bytes)
}

// --- helpers -------------------------------------------------------------------

@(private)
make_mouse_test_editor :: proc(text: string) -> Editor {
	ed := editor_init(.Other)
	editor_set_text(&ed, text)
	ed.char_w, ed.char_h = 10, 20
	ed.visible_rows, ed.visible_cols = 10, 40
	ed.origin_x, ed.origin_y = 0, 0
	return ed
}

// px returns a window point that hits caret position (line, col).
@(private)
px :: proc(ed: ^Editor, line, col: int) -> (x, y: f32) {
	x, y = editor_position_to_screen(ed, {line, col})
	return x + 1, y + ed.char_h / 2
}

@(private)
mouse_button :: proc(ed: ^Editor, down: bool, x, y: f32, clicks: u8 = 1) {
	ev: sdl.Event
	ev.type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP
	ev.button.button = 1
	ev.button.down = down
	ev.button.clicks = clicks
	ev.button.x, ev.button.y = x, y
	editor_handle_event(ed, ev)
}

@(private)
mouse_click :: proc(ed: ^Editor, x, y: f32, clicks: u8 = 1) {
	mouse_button(ed, true, x, y, clicks)
	mouse_button(ed, false, x, y, clicks)
}

@(private)
mouse_move :: proc(ed: ^Editor, x, y: f32) {
	ev: sdl.Event
	ev.type = .MOUSE_MOTION
	ev.motion.x, ev.motion.y = x, y
	editor_handle_event(ed, ev)
}

@(private)
mouse_wheel :: proc(ed: ^Editor, x, y, dx, dy: f32) {
	ev: sdl.Event
	ev.type = .MOUSE_WHEEL
	ev.wheel.x, ev.wheel.y = dx, dy
	ev.wheel.mouse_x, ev.wheel.mouse_y = x, y
	editor_handle_event(ed, ev)
}

@(private)
modifier_key :: proc(ed: ^Editor, key: sdl.Keycode, down: bool) {
	ev: sdl.Event
	ev.type = .KEY_DOWN if down else .KEY_UP
	ev.key.key = key
	ev.key.down = down
	editor_handle_event(ed, ev)
}

@(private)
sel :: proc(ed: ^Editor, i := 0) -> (start, end: buf.Position, ok: bool) {
	return buf.selection_range(ed.buf.cursors[i])
}

// --- tests -----------------------------------------------------------------------

@(test)
test_click_places_caret_respecting_tabs :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("\tfoo\nbar")
		defer editor_destroy(&ed)

		// Visual col 5 on line 0 is between 'f' and 'o' (tab = 4 cells).
		mouse_click(&ed, editor_gutter_width(&ed) + 5 * 10 + 1, 10)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 2})

		// Clicking in the right half of the tab lands after it.
		mouse_click(&ed, editor_gutter_width(&ed) + 3 * 10, 10)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 1})

		// Past the end of a line clamps to its end; below the doc -> end.
		mouse_click(&ed, editor_gutter_width(&ed) + 30 * 10, 30)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{1, 3})
		mouse_click(&ed, editor_gutter_width(&ed) + 10, 9 * 20 + 5)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{1, 3})
	})
}

@(test)
test_drag_selects_characters_across_lines :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("hello world\nsecond line")
		defer editor_destroy(&ed)

		x0, y0 := px(&ed, 0, 6)
		x1, y1 := px(&ed, 1, 3)
		mouse_button(&ed, true, x0, y0)
		_, _, ok := sel(&ed)
		testing.expect(t, !ok, "press alone selects nothing")
		mouse_move(&ed, x1, y1)
		testing.expect(t, ed.mouse.drag == .Chars, "dragging")
		mouse_button(&ed, false, x1, y1)

		start, end, ok2 := sel(&ed)
		testing.expect(t, ok2, "drag made a selection")
		testing.expect_value(t, start, buf.Position{0, 6})
		testing.expect_value(t, end, buf.Position{1, 3})
		testing.expect(t, ed.mouse.drag == .None, "release ends the drag")

		// Moving after release doesn't change anything.
		mouse_move(&ed, x0, y0)
		_, end, _ = sel(&ed)
		testing.expect_value(t, end, buf.Position{1, 3})
	})
}

@(test)
test_shift_click_extends_selection :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("abcdef\nghijkl")
		defer editor_destroy(&ed)

		x, y := px(&ed, 0, 2)
		mouse_click(&ed, x, y)
		modifier_key(&ed, sdl.K_LSHIFT, true)
		x, y = px(&ed, 1, 4)
		mouse_click(&ed, x, y)
		start, end, ok := sel(&ed)
		testing.expect(t, ok, "shift+click selects")
		testing.expect_value(t, start, buf.Position{0, 2})
		testing.expect_value(t, end, buf.Position{1, 4})

		// A second shift+click keeps the original anchor.
		x, y = px(&ed, 0, 5)
		mouse_click(&ed, x, y)
		start, end, _ = sel(&ed)
		testing.expect_value(t, start, buf.Position{0, 2})
		testing.expect_value(t, end, buf.Position{0, 5})

		modifier_key(&ed, sdl.K_LSHIFT, false)
		x, y = px(&ed, 1, 1)
		mouse_click(&ed, x, y)
		_, _, ok = sel(&ed)
		testing.expect(t, !ok, "after releasing Shift a click just places the caret")
	})
}

@(test)
test_double_click_word_and_word_drag :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("alpha beta gamma")
		defer editor_destroy(&ed)

		x, y := px(&ed, 0, 7) // inside "beta"
		mouse_button(&ed, true, x, y, 2)
		start, end, ok := sel(&ed)
		testing.expect(t, ok, "double-click selects")
		testing.expect_value(t, start, buf.Position{0, 6})
		testing.expect_value(t, end, buf.Position{0, 10})

		// Dragging right extends by whole words...
		x2, y2 := px(&ed, 0, 12) // inside "gamma"
		mouse_move(&ed, x2, y2)
		start, end, _ = sel(&ed)
		testing.expect_value(t, start, buf.Position{0, 6})
		testing.expect_value(t, end, buf.Position{0, 16})

		// ...and dragging left keeps "beta" selected, growing leftwards.
		x3, y3 := px(&ed, 0, 2) // inside "alpha"
		mouse_move(&ed, x3, y3)
		start, end, _ = sel(&ed)
		testing.expect_value(t, start, buf.Position{0, 0})
		testing.expect_value(t, end, buf.Position{0, 10})
		mouse_button(&ed, false, x3, y3, 2)
	})
}

@(test)
test_triple_click_and_gutter_select_lines :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("one\ntwo\nthree\nfour")
		defer editor_destroy(&ed)

		x, y := px(&ed, 1, 1)
		mouse_click(&ed, x, y, 3)
		start, end, _ := sel(&ed)
		testing.expect_value(t, start, buf.Position{1, 0})
		testing.expect_value(t, end, buf.Position{2, 0})

		// Gutter press on line 0, drag to line 2: lines 0..2 selected.
		mouse_button(&ed, true, 5, 10)
		testing.expect(t, ed.mouse.zone == .Gutter, "hit the gutter")
		mouse_move(&ed, 5, 2 * 20 + 10)
		mouse_button(&ed, false, 5, 2 * 20 + 10)
		start, end, _ = sel(&ed)
		testing.expect_value(t, start, buf.Position{0, 0})
		testing.expect_value(t, end, buf.Position{3, 0})
	})
}

@(test)
test_alt_click_toggles_extra_cursors :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("aaa\nbbb\nccc")
		defer editor_destroy(&ed)

		x, y := px(&ed, 0, 1)
		mouse_click(&ed, x, y)
		modifier_key(&ed, sdl.K_LALT, true)
		x, y = px(&ed, 1, 2)
		mouse_click(&ed, x, y)
		x, y = px(&ed, 2, 3)
		mouse_click(&ed, x, y)
		testing.expect_value(t, len(ed.buf.cursors), 3)

		// Alt+click on an existing cursor removes it.
		x, y = px(&ed, 1, 2)
		mouse_click(&ed, x, y)
		testing.expect_value(t, len(ed.buf.cursors), 2)
		modifier_key(&ed, sdl.K_LALT, false)

		editor_inject_text(&ed, "X")
		editor_update(&ed)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "aXaa")
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 1), "bbb")
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 2), "cccX")
	})
}

@(test)
test_wheel_scrolls_vertically_and_horizontally :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		long := "0123456789012345678901234567890123456789012345678901234567890123456789"
		text := ""
		for i in 0 ..< 30 {
			text = i == 0 ? long : text_join(text, long)
		}
		ed := make_mouse_test_editor(text)
		defer editor_destroy(&ed)

		mouse_wheel(&ed, 100, 50, 0, -2) // wheel towards user: down
		testing.expect_value(t, ed.scroll_line, 2 * WHEEL_LINES)
		mouse_wheel(&ed, 100, 50, 1, 0)
		testing.expect_value(t, ed.scroll_col, WHEEL_LINES)

		// Shift+wheel scrolls horizontally.
		modifier_key(&ed, sdl.K_LSHIFT, true)
		mouse_wheel(&ed, 100, 50, 0, -1)
		modifier_key(&ed, sdl.K_LSHIFT, false)
		testing.expect_value(t, ed.scroll_col, 2 * WHEEL_LINES)

		// Horizontal scroll is clamped to the widest line.
		for _ in 0 ..< 50 {
			mouse_wheel(&ed, 100, 50, 1, 0)
		}
		testing.expect_value(t, ed.scroll_col, len(long) - ed.visible_cols + 1)

		// Outside the editor the wheel isn't consumed.
		ev: sdl.Event
		ev.type = .MOUSE_WHEEL
		ev.wheel.y = -1
		ev.wheel.mouse_x, ev.wheel.mouse_y = 5000, 5000
		testing.expect(t, !editor_handle_event(&ed, ev), "wheel outside is not handled")
	})
}

@(private)
text_join :: proc(a, b: string) -> string {
	return strings_concat({a, "\n", b})
}

@(test)
test_drag_past_bottom_autoscrolls :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		text := ""
		for i in 0 ..< 50 {
			text = i == 0 ? "line" : text_join(text, "line")
		}
		ed := make_mouse_test_editor(text)
		defer editor_destroy(&ed)

		x, y := px(&ed, 2, 0)
		mouse_button(&ed, true, x, y)
		mouse_move(&ed, x, f32(ed.visible_rows) * ed.char_h + 30) // below the view
		for _ in 0 ..< 5 {
			ed.mouse.last_autoscroll = {} // don't wait out the interval
			editor_update(&ed)
		}
		testing.expect(t, ed.scroll_line > 0, "view scrolled while dragging below it")
		_, end, ok := sel(&ed)
		testing.expect(t, ok && end.line >= ed.scroll_line + ed.visible_rows - 1, "selection follows the scroll")
		mouse_button(&ed, false, x, f32(ed.visible_rows) * ed.char_h + 30)
		scrolled := ed.scroll_line
		editor_update(&ed)
		testing.expect_value(t, ed.scroll_line, scrolled) // stops after release
	})
}

@(test)
test_mouse_cursor_shape_and_zones :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("text")
		defer editor_destroy(&ed)

		mouse_move(&ed, editor_gutter_width(&ed) + 15, 10)
		testing.expect(t, ed.mouse.zone == .Text, "over text")
		testing.expect(t, editor_mouse_cursor(&ed) == .Text, "I-beam over text")
		mouse_move(&ed, 10, 10)
		testing.expect(t, ed.mouse.zone == .Gutter, "over gutter")
		testing.expect(t, editor_mouse_cursor(&ed) == .Default, "arrow over gutter")
		mouse_move(&ed, 4000, 10)
		testing.expect(t, ed.mouse.zone == .Outside, "outside")

		// Clicks outside the editor are left for the host.
		ev: sdl.Event
		ev.type = .MOUSE_BUTTON_DOWN
		ev.button.button = 1
		ev.button.x, ev.button.y = 4000, 10
		testing.expect(t, !editor_handle_event(&ed, ev), "outside click not consumed")
	})
}

@(test)
test_click_completion_item_accepts_it :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		ed.char_w, ed.char_h = 10, 20
		ed.visible_rows, ed.visible_cols = 20, 60

		type_and_update(&ed, "fmt.")
		fake_completion_response(&ed, FMT_ITEMS)
		editor_update(&ed)
		layout := editor_popup_layout(&ed)
		testing.expect(t, layout.completion_visible, "popup up")

		// Hovering over the popup shows an arrow and doesn't move the caret.
		row2_y := layout.completion.y + POPUP_PAD + 2 * ed.char_h + ed.char_h / 2
		mouse_move(&ed, layout.completion.x + 20, row2_y)
		testing.expect(t, ed.mouse.zone == .Completion, "over the popup")
		testing.expect(t, editor_mouse_cursor(&ed) == .Default, "arrow over popup")

		mouse_click(&ed, layout.completion.x + 20, row2_y) // 3rd item: sbprint
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "fmt.sbprint")
		testing.expect(t, !ed.completion.active, "click accepted and closed the popup")
	})
}

@(test)
test_wheel_over_completion_scrolls_the_list :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		ed.char_w, ed.char_h = 10, 20
		ed.visible_rows, ed.visible_cols = 30, 60

		items := ""
		for i in 0 ..< 25 {
			items = strings_concat({items, i > 0 ? "," : "", `{"label":"item`, digits(i), `"}`})
		}
		type_and_update(&ed, "x.")
		fake_completion_response(&ed, items)
		editor_update(&ed)
		layout := editor_popup_layout(&ed)
		mouse_wheel(&ed, layout.completion.x + 5, layout.completion.y + 5, 0, -3)
		testing.expect_value(t, ed.completion.scroll, 3)
		testing.expect_value(t, ed.completion.selected, 0) // selection unchanged
		testing.expect_value(t, ed.scroll_line, 0)         // editor didn't scroll
	})
}

@(private)
digits :: proc(i: int) -> string {
	d := [10]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
	if i < 10 {
		return d[i]
	}
	return strings_concat({d[i / 10], d[i % 10]})
}

@(private)
strings_concat :: proc(parts: []string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

@(test)
test_vertical_moves_keep_visual_goal_column :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		// Line 0 tab-indented, line 1 short, line 2 space-indented.
		editor_set_text(&ed, "\tvalue := 1\nx\n    other := 2")
		ed.buf.cursors[0].pos = {0, 3} // after "\tva" = visual col 6

		key_and_update(&ed, sdl.K_DOWN)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{1, 1}) // clamped on the short line
		key_and_update(&ed, sdl.K_DOWN)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{2, 6}) // back to visual col 6
		key_and_update(&ed, sdl.K_UP)
		key_and_update(&ed, sdl.K_UP)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 3})

		// Moving horizontally resets the goal.
		key_and_update(&ed, sdl.K_RIGHT) // col 4 -> visual 7
		key_and_update(&ed, sdl.K_DOWN)
		key_and_update(&ed, sdl.K_DOWN)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{2, 7})
	})
}

@(test)
test_vertical_move_never_splits_a_multibyte_char :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "abcd\nééé")
		ed.buf.cursors[0].pos = {0, 3}
		key_and_update(&ed, sdl.K_DOWN)
		// Visual col 3 on "ééé" is byte 6, never byte 3 (inside 'é').
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{1, 6})
	})
}

@(test)
test_wide_characters_take_two_cells :: proc(t: ^testing.T) {
	testing.expect_value(t, rune_cells('a'), 1)
	testing.expect_value(t, rune_cells('é'), 1)
	testing.expect_value(t, rune_cells('漢'), 2)
	testing.expect_value(t, rune_cells('😀'), 2)
	testing.expect_value(t, rune_cells(0x0301), 0) // combining acute

	line := "a漢😀b" // bytes: a=1, 漢=3, 😀=4, b=1
	testing.expect_value(t, visual_col_of(line, 1, 4), 1)
	testing.expect_value(t, visual_col_of(line, 4, 4), 3)
	testing.expect_value(t, visual_col_of(line, 8, 4), 5)
	testing.expect_value(t, line_visual_width(line, 4), 6)
	// Clicks: the left half of 漢 (cells 1-2) snaps before it, the right half after.
	testing.expect_value(t, byte_col_at_visual(line, 1.5, 4), 1)
	testing.expect_value(t, byte_col_at_visual(line, 2.5, 4), 4)
	col, inside := byte_col_at_cell(line, 3.5, 4) // a cell of 😀
	testing.expect(t, inside && col == 4, "hover cell maps to the emoji's start")
}

@(test)
test_click_after_emoji_places_caret_correctly :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("x := \"😀\" + y")
		defer editor_destroy(&ed)
		// 'y' is at byte 14, visual col 12 (emoji = 2 cells, 4 bytes).
		mouse_click(&ed, editor_gutter_width(&ed) + 12 * 10 + 1, 10)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 14})
		x, _ := editor_position_to_screen(&ed, {0, 14})
		testing.expect_value(t, x, editor_gutter_width(&ed) + 120)
	})
}
