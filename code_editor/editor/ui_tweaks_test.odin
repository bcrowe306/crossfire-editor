package code_editor

import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_vertical_scrollbar_layout_and_drag :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor(strings.repeat("line\n", 100, context.temp_allocator))
		defer editor_destroy(&ed)
		l := editor_scrollbar_layout(&ed)
		testing.expect(t, l.v_shown, "tall document shows a vertical bar")
		testing.expect(t, !l.h_shown, "no horizontal bar for short lines")
		testing.expect_value(t, l.v_thumb.y, ed.origin_y) // at the top
		testing.expect(t, l.v_thumb.h < l.v_track.h, "thumb smaller than track")

		// Drag the thumb to the bottom of the track.
		x := l.v_thumb.x + 2
		mouse_button(&ed, true, x, l.v_thumb.y + 2)
		testing.expect(t, ed.mouse.scroll_drag == .Vertical, "grabbed the thumb")
		mouse_move(&ed, x, l.v_track.y + l.v_track.h + 50)
		testing.expect_value(t, ed.scroll_line, max_scroll_line(&ed))
		mouse_button(&ed, false, x, l.v_track.y + l.v_track.h + 50)
		testing.expect(t, ed.mouse.scroll_drag == .None, "released")

		// Clicking the track jumps (thumb centred on the click).
		mouse_click(&ed, x, l.v_track.y + 2)
		testing.expect_value(t, ed.scroll_line, 0)
		testing.expect_value(t, ed.buf.cursors[0].pos.line, 0) // caret untouched by scrollbar clicks
	})
}

@(test)
test_horizontal_scrollbar_appears_for_long_lines :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor(strings.repeat("x", 200, context.temp_allocator))
		defer editor_destroy(&ed)
		l := editor_scrollbar_layout(&ed)
		testing.expect(t, l.h_shown && !l.v_shown, "wide line shows only the horizontal bar")
		mouse_click(&ed, l.h_track.x + l.h_track.w - 2, l.h_track.y + 4)
		testing.expect_value(t, ed.scroll_col, max_scroll_col(&ed))
	})
}

@(test)
test_zoom_requests_font_size_changes :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		key_and_update(&ed, sdl.K_EQUALS, sdl.KMOD_LCTRL)
		_, ok := editor_take_font_size_change(&ed)
		testing.expect(t, !ok, "zoom does nothing until the host opts in")

		editor_set_font_size(&ed, 16)
		key_and_update(&ed, sdl.K_EQUALS, sdl.KMOD_LCTRL)
		key_and_update(&ed, sdl.K_EQUALS, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT) // Ctrl++ on most layouts
		size, changed := editor_take_font_size_change(&ed)
		testing.expect(t, changed && size == 18, "two zoom-ins")
		_, changed = editor_take_font_size_change(&ed)
		testing.expect(t, !changed, "taken once")
		key_and_update(&ed, sdl.K_MINUS, sdl.KMOD_LCTRL)
		size, _ = editor_take_font_size_change(&ed)
		testing.expect_value(t, size, 17)
		key_and_update(&ed, sdl.K_0, sdl.KMOD_LCTRL)
		size, _ = editor_take_font_size_change(&ed)
		testing.expect_value(t, size, 16)
		for _ in 0 ..< 100 {
			editor_zoom(&ed, -1)
		}
		testing.expect_value(t, ed.font_size, f32(MIN_FONT_SIZE))
	})
}
