package code_editor

import buf "../buffer"
import km "../keymap"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

run_leak_free :: proc(t: ^testing.T, body: proc(t: ^testing.T)) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	old := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	body(t)
	context.allocator = old

	for _, entry in track.allocation_map {
		testing.expectf(t, false, "Memory leak: %v bytes at %v", entry.size, entry.location)
	}
	for bf in track.bad_free_array {
		testing.expectf(t, false, "Bad free: %p at %v", bf.memory, bf.location)
	}
}

@(test)
test_sdl_key_translation :: proc(t: ^testing.T) {
	testing.expect_value(t, sdl_keycode_to_key(sdl.K_A), km.Key.A)
	testing.expect_value(t, sdl_keycode_to_key(sdl.K_LEFT), km.Key.Left)
	testing.expect_value(t, sdl_keycode_to_key(sdl.K_RETURN), km.Key.Enter)
	testing.expect_value(t, sdl_keycode_to_key(sdl.K_F5), km.Key.Unknown)
	testing.expect_value(t, sdl_keycode_to_key(sdl.K_F8), km.Key.F8)
	testing.expect_value(t, sdl_keycode_to_key(sdl.K_F2), km.Key.F2)
}

@(test)
test_sdl_mod_translation :: proc(t: ^testing.T) {
	mods := sdl_mod_to_keymap_mods(sdl.KMOD_LCTRL)
	testing.expect_value(t, mods, km.Modifiers{.Ctrl})

	mods2 := sdl_mod_to_keymap_mods(sdl.KMOD_LSHIFT | sdl.KMOD_LGUI)
	testing.expect(t, .Shift in mods2, "expected Shift")
	testing.expect(t, .Super in mods2, "expected Super")
	testing.expect(t, .Ctrl not_in mods2, "unexpected Ctrl")
}

@(test)
test_editor_init_destroy_no_leaks :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		testing.expect_value(t, buf.buffer_line_count(&ed.buf), 1)
	})
}

@(test)
test_apply_action_typing_and_movement :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)

		editor_insert_text(&ed, "hello")
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "hello")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 5})

		editor_apply_action(&ed, .MoveLineStart)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 0})

		editor_apply_action(&ed, .MoveWordRight)
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 5})
	})
}

@(test)
test_apply_action_select_all_and_delete :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "hello world")

		editor_apply_action(&ed, .SelectAll)
		_, _, ok := buf.selection_range(ed.buf.cursors[0])
		testing.expect(t, ok, "expected select-all to create a selection")

		editor_apply_action(&ed, .Backspace)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "")
	})
}

@(test)
test_apply_action_undo_redo :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_insert_text(&ed, "abc")
		editor_apply_action(&ed, .Undo)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "")
		editor_apply_action(&ed, .Redo)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "abc")
	})
}

@(test)
test_add_cursor_above_below :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "aaa\nbbb\nccc")
		ed.buf.cursors[0].pos = buf.Position{1, 2}

		editor_apply_action(&ed, .AddCursorBelow)
		testing.expect_value(t, len(ed.buf.cursors), 2)
		testing.expect_value(t, ed.buf.cursors[1].pos, buf.Position{2, 2})
	})
}

@(test)
test_handle_key_down_resolves_and_applies :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "hello")
		ed.buf.cursors[0].pos = buf.Position{0, 5}

		key_ev := sdl.KeyboardEvent{key = sdl.K_LEFT}
		handled := editor_handle_key_down(&ed, key_ev)
		testing.expect(t, handled, "expected Left arrow to be handled")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 4})
	})
}

@(test)
test_handle_event_text_input :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)

		ev: sdl.Event
		ev.type = .TEXT_INPUT
		ev.text.text = "hi"
		handled := editor_handle_event(&ed, ev)
		testing.expect(t, handled, "expected text input to be handled")
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "hi")
	})
}

@(test)
test_injected_events_roundtrip :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)

		editor_inject_text(&ed, "ab")
		editor_inject_key(&ed, sdl.K_LEFT)
		editor_pump_injected_events(&ed)

		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "ab")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 1})
	})
}

@(test)
test_ensure_cursor_visible_scrolls_down :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		ed.visible_rows = 5

		sb := strings.builder_make(context.temp_allocator)
		for i in 0 ..< 20 {
			if i > 0 {
				strings.write_byte(&sb, '\n')
			}
			fmt.sbprintf(&sb, "line%d", i)
		}
		editor_set_text(&ed, strings.to_string(sb))
		ed.buf.cursors[0].pos = buf.Position{15, 0}

		editor_ensure_cursor_visible(&ed)
		testing.expect(t, ed.scroll_line <= 15, "expected scroll_line to bring cursor into view")
		testing.expect(t, ed.scroll_line + ed.visible_rows > 15, "expected cursor row to be visible")
	})
}

@(test)
test_selected_text_single_line :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "hello world")
		ed.buf.cursors[0] = buf.Cursor{
			pos = buf.Position{0, 11},
			sel = buf.Selection{anchor = buf.Position{0, 6}, active = true},
		}
		text := editor_selected_text(&ed, context.temp_allocator)
		testing.expect_value(t, text, "world")
	})
}

@(test)
test_file_load_save_roundtrip :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "package main\n\nmain :: proc() {}\n")

		path := "/tmp/odin_editor_editor_test.odin"
		ok := editor_save_file(&ed, path)
		testing.expect(t, ok, "expected save to succeed")

		ed2 := editor_init(.Other)
		defer editor_destroy(&ed2)
		ok2 := editor_load_file(&ed2, path)
		testing.expect(t, ok2, "expected load to succeed")
		testing.expect_value(t, editor_to_string(&ed2, context.temp_allocator), "package main\n\nmain :: proc() {}\n")
	})
}
