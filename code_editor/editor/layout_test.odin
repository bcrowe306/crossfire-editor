package code_editor

import "core:strings"
import "core:testing"

@(test)
test_font_metrics_apply_line_spacing :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_font(&ed, 9, 18)
		testing.expect_value(t, ed.char_w, 9)
		testing.expect_value(t, ed.char_h, 25) // 18 x 1.4 = 25.2 -> 25
		testing.expect_value(t, editor_glyph_height(&ed), 18)
		ed.line_spacing = 1.0
		editor_set_font(&ed, 9, 18)
		testing.expect_value(t, ed.char_h, 18)
	})
}

@(test)
test_viewport_accounts_for_header_and_gutter :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_font(&ed, 10, 20) // rows 28 px
		editor_set_viewport(&ed, 1000, 700)
		header := editor_header_height(&ed)
		testing.expect(t, header > 0, "header shown by default")
		testing.expect_value(t, ed.visible_rows, int((700 - header - SCROLLBAR_SIZE) / 28))
		testing.expect_value(t, ed.visible_cols, int((1000 - editor_gutter_width(&ed) - SCROLLBAR_SIZE) / 10))

		ed.show_header = false
		editor_set_viewport(&ed, 1000, 700)
		testing.expect_value(t, editor_header_height(&ed), 0)
		testing.expect_value(t, ed.visible_rows, int((700 - SCROLLBAR_SIZE) / 28))
	})
}

@(test)
test_gutter_grows_with_line_count :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_font(&ed, 10, 20)
		editor_set_text(&ed, "one line")
		small := editor_gutter_width(&ed)
		testing.expect_value(t, small, f32(MIN_GUTTER_WIDTH))
		editor_set_text(&ed, strings.repeat("x\n", 123456, context.temp_allocator))
		testing.expect(t, editor_gutter_width(&ed) >= 6 * 10 + GUTTER_MARKER_SPACE, "6-digit numbers fit")
	})
}

@(test)
test_display_name :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		name, dir := editor_display_name(&ed)
		testing.expect(t, name == "untitled" && dir == "", "no file")
		ok := editor_save_file(&ed, "/tmp/odin_editor_display_name_test.odin")
		testing.expect(t, ok, "saved")
		name, dir = editor_display_name(&ed)
		testing.expect_value(t, name, "odin_editor_display_name_test.odin")
		testing.expect_value(t, dir, "/tmp")
	})
}
