package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:fmt"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

@(private)
right_click :: proc(ed: ^Editor, x, y: f32) {
	ev: sdl.Event
	ev.type = .MOUSE_BUTTON_DOWN
	ev.button.button = 3
	ev.button.down = true
	ev.button.clicks = 1
	ev.button.x, ev.button.y = x, y
	editor_handle_event(ed, ev)
}

@(test)
test_context_menu_opens_moves_caret_and_runs_actions :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("alpha beta\ngamma")
		defer editor_destroy(&ed)
		x, y := px(&ed, 1, 2)
		right_click(&ed, x, y)
		testing.expect(t, ed.menu.open, "right-click opens the menu")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{1, 2}) // caret moved there

		items := editor_context_menu_items(&ed)
		cut := 4 // after Go to Definition / Peek / Find References / separator
		testing.expect(t, !items[cut].enabled && !items[cut + 1].enabled, "Cut/Copy disabled without a selection")
		testing.expect_value(t, chord_label(&ed, .SelectAll), "Ctrl+A")

		// Keyboard: Down skips disabled items -> Paste, Select All.
		key_and_update(&ed, sdl.K_DOWN)
		testing.expect_value(t, items[ed.menu.selected].label, "Paste")
		key_and_update(&ed, sdl.K_DOWN)
		testing.expect_value(t, items[ed.menu.selected].label, "Select All")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, !ed.menu.open, "activating closes the menu")
		_, e, ok := buf.selection_range(ed.buf.cursors[0])
		testing.expect(t, ok && e == buf.Position{1, 5}, "Select All ran")

		// Right-click inside the selection keeps it; click an item.
		right_click(&ed, x, y)
		testing.expect(t, editor_context_menu_items(&ed)[cut + 1].enabled, "Copy enabled with a selection")
		rect, _ := editor_context_menu_layout(&ed)
		find_row := cut + 8 // "Find"
		// The 10-row view is too short for all 14 items: the menu fits inside it and scrolls
		testing.expect(t, rect.y >= ed.origin_y && rect.y + rect.h <= ed.origin_y + f32(ed.visible_rows) * ed.char_h, "the menu fits the view")
		rows := popup_rows_of(&ed, rect)
		testing.expect(t, rows < len(editor_context_menu_items(&ed)), "fewer rows than items")
		for i := 0; i < 20 && ed.menu.scroll + rows <= find_row; i += 1 {
			mouse_wheel(&ed, rect.x + 10, rect.y + 10, 0, -1)
		}
		testing.expect(t, ed.menu.scroll > 0, "the wheel scrolled the menu")
		mouse_click(&ed, rect.x + 10, rect.y + POPUP_PAD + f32(find_row - ed.menu.scroll) * ed.char_h + 5)
		testing.expect(t, ed.find.open, "clicking Find opened the find bar")

		right_click(&ed, x, y)
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.menu.open, "Escape closes")
		right_click(&ed, x, y)
		mouse_click(&ed, editor_gutter_width(&ed) + 2, 3)
		testing.expect(t, !ed.menu.open, "clicking elsewhere closes")
	})
}

@(test)
test_drag_and_drop_moves_and_copies_selection :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("one two three")
		defer editor_destroy(&ed)
		ed.buf.cursors[0] = {pos = {0, 7}, sel = {anchor = {0, 4}, active = true}} // "two"

		x0, y0 := px(&ed, 0, 5)
		x1, y1 := px(&ed, 0, 13)
		mouse_button(&ed, true, x0, y0)
		testing.expect(t, ed.mouse.move_pending, "press inside the selection is pending")
		mouse_move(&ed, x1, y1)
		testing.expect(t, ed.mouse.drag == .Move, "moving past the threshold starts a drag")
		mouse_button(&ed, false, x1, y1)
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "one  threetwo")
		s, e, _ := buf.selection_range(ed.buf.cursors[0])
		testing.expect(t, s == {0, 10} && e == {0, 13}, "moved text stays selected")
		editor_apply_action(&ed, .Undo)
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "one two three") // one undo step

		// Copy (Ctrl on non-mac) to the start. (Undo restored a caret per
		// edit site; drag-and-drop needs a single cursor.)
		resize(&ed.buf.cursors, 1)
		ed.buf.cursors[0] = {pos = {0, 7}, sel = {anchor = {0, 4}, active = true}}
		mouse_button(&ed, true, x0, y0)
		xs, ys := px(&ed, 0, 0)
		mouse_move(&ed, xs, ys)
		modifier_key(&ed, sdl.K_LCTRL, true)
		mouse_button(&ed, false, xs, ys)
		modifier_key(&ed, sdl.K_LCTRL, false)
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "twoone two three")

		// Press + release without moving: just places the caret.
		ed.buf.cursors[0] = {pos = {0, 10}, sel = {anchor = {0, 7}, active = true}}
		xi, yi := px(&ed, 0, 8)
		mouse_click(&ed, xi, yi)
		_, _, has := buf.selection_range(ed.buf.cursors[0])
		testing.expect(t, !has && ed.buf.cursors[0].pos == buf.Position{0, 8}, "click inside selection collapses it")

		// Dropping onto itself changes nothing.
		ed.buf.cursors[0] = {pos = {0, 10}, sel = {anchor = {0, 7}, active = true}}
		before := editor_to_string(&ed, context.allocator)
		defer delete(before)
		mouse_button(&ed, true, xi, yi)
		xj, yj := px(&ed, 0, 9)
		mouse_move(&ed, xj + 20, yj)
		mouse_move(&ed, xj, yj)
		mouse_button(&ed, false, xj, yj)
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), before)
	})
}

@(private)
fake_hover :: proc(ed: ^Editor, result: string) {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":%s}}`, ed.lsp.latest_hover_id, result)
	lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(body, context.temp_allocator))
}

@(test)
test_hover_info_after_dwell :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("x := compute(1)\ny := bad")
		defer editor_destroy(&ed)
		publish(&ed, {{1, 5, 1, 8, 1, "undeclared"}})

		mouse_move(&ed, editor_gutter_width(&ed) + 7 * 10 + 5, 10) // over "compute"
		ed.diag_tip.hover_since = time.tick_add(time.tick_now(), -DIAG_HOVER_DELAY)
		editor_update(&ed)
		testing.expect(t, ed.hover.requested, "dwell asks the server")
		fake_hover(&ed, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"```odin\\ncompute :: proc(n: int) -> int\\n```\\nDoubles n.\"}}")
		editor_update(&ed)
		rect, lines, ok := editor_hover_layout(&ed)
		testing.expect(t, ok && len(lines) == 2 && lines[0].code && lines[1].text == "Doubles n.", "hover shows code + prose")
		_, y := editor_position_to_screen(&ed, {0, 5})
		testing.expect(t, ok && rect.y >= y + ed.char_h, "line 0: tooltip goes below")

		mouse_move(&ed, rect.x + 3, rect.y + 3)
		testing.expect(t, ed.hover.visible, "pointer over the tooltip keeps it")
		mouse_move(&ed, editor_gutter_width(&ed) + 1 * 10 + 5, 10) // another cell
		testing.expect(t, !ed.hover.visible, "moving to another cell hides it")

		// Over a diagnostic: the diagnostic tooltip wins, no hover request.
		id := ed.lsp.latest_hover_id
		mouse_move(&ed, editor_gutter_width(&ed) + 6 * 10 + 5, 30)
		ed.diag_tip.hover_since = time.tick_add(time.tick_now(), -DIAG_HOVER_DELAY)
		editor_update(&ed)
		testing.expect_value(t, ed.lsp.latest_hover_id, id)
		testing.expect(t, len(editor_diag_tooltip_items(&ed)) == 1, "diagnostic shown instead")
	})
}
