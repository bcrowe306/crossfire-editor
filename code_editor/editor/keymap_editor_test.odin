package code_editor

import km "../keymap"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

@(private = "file")
make_temp_dir :: proc(tag: string) -> string {
	dir := fmt.tprintf("/tmp/oe_%s_%d", tag, time.tick_now()._nsec)
	_ = os.make_directory_all(dir)
	return dir
}

@(test)
test_line_commands_via_keys :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("a\n\tb\nc")
		defer editor_destroy(&ed)
		ed.buf.cursors[0].pos = {1, 1}
		key_and_update(&ed, sdl.K_DOWN, sdl.KMOD_LALT | sdl.KMOD_LSHIFT) // duplicate down
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "a\n\tb\n\tb\nc")
		testing.expect_value(t, ed.buf.cursors[0].pos.line, 2)
		key_and_update(&ed, sdl.K_UP, sdl.KMOD_LALT) // move up
		key_and_update(&ed, sdl.K_UP, sdl.KMOD_LALT)
		testing.expect_value(t, ed.buf.cursors[0].pos.line, 0)
		key_and_update(&ed, sdl.K_SLASH, sdl.KMOD_LCTRL) // toggle comment
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "\t// b\na\n\tb\nc")
		key_and_update(&ed, sdl.K_SLASH, sdl.KMOD_LCTRL)
		key_and_update(&ed, sdl.K_K, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT) // delete line
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "a\n\tb\nc")
		key_and_update(&ed, sdl.K_Z, sdl.KMOD_LCTRL)
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "\tb\na\n\tb\nc")
	})
}

@(test)
test_keymap_editor_rebind_persists :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		dir := make_temp_dir("kmcfg")
		defer os.remove_all(dir)

		ed := make_mouse_test_editor("x")
		editor_set_config_dir(&ed, dir)
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		type_and_update(&ed, "keymap editor")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect_value(t, ed.window, Editor_Window.Keymap)

		// Typing filters; the text view is untouched.
		type_and_update(&ed, "toggle line comment")
		row, ok := keymap_editor_selected_row(&ed)
		testing.expect(t, ok && row.action == .ToggleLineComment, "filter finds the command")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "x")

		// Enter records; modifier presses wait; the next chord binds.
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, ed.keymap_editor.capturing, "recording")
		key_and_update(&ed, sdl.K_LSHIFT)
		testing.expect(t, ed.keymap_editor.capturing, "modifier alone keeps recording")
		key_and_update(&ed, sdl.K_J, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		testing.expect(t, !ed.keymap_editor.capturing, "chord recorded")
		a, bound := km.keymap_resolve(&ed.keymap, {.J, {.Ctrl, .Shift}})
		testing.expect(t, bound && a == .ToggleLineComment, "new chord bound")
		_, bound = km.keymap_resolve(&ed.keymap, {.Slash, {.Ctrl}})
		testing.expect(t, !bound, "old chord replaced")
		row, _ = keymap_editor_selected_row(&ed)
		testing.expect(t, row.user, "marked as user binding")

		// Shift+Enter adds instead of replacing.
		key_and_update(&ed, sdl.K_RETURN, sdl.KMOD_LSHIFT)
		key_and_update(&ed, sdl.K_F4, sdl.KMOD_LALT)
		testing.expect_value(t, len(km.keymap_chords_for(&ed.keymap, .ToggleLineComment)), 2)

		// Escape: clear the filter, then close.
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect_value(t, strings.to_string(ed.keymap_editor.filter), "")
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect_value(t, ed.window, Editor_Window.Text)
		editor_destroy(&ed)

		// A new editor with the same config dir gets the binding back.
		data, err := os.read_entire_file(filepath.join({dir, KEYMAP_FILE}, context.temp_allocator) or_else "", context.temp_allocator)
		testing.expect(t, err == nil && strings.contains(string(data), "ToggleLineComment"), "saved to keymap.json")
		ed2 := make_mouse_test_editor("y")
		defer editor_destroy(&ed2)
		editor_set_config_dir(&ed2, dir)
		a, bound = km.keymap_resolve(&ed2.keymap, {.J, {.Ctrl, .Shift}})
		testing.expect(t, bound && a == .ToggleLineComment, "binding loaded")
		key_and_update(&ed2, sdl.K_J, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		testing.expect_value(t, editor_to_string(&ed2, context.temp_allocator), "// y")

		// Reset restores the default; Delete removes all.
		editor_show_window(&ed2, .Keymap)
		editor_keymap_select_action(&ed2, .ToggleLineComment)
		key_and_update(&ed2, sdl.K_R, sdl.KMOD_LCTRL)
		testing.expect_value(t, len(km.keymap_chords_for(&ed2.keymap, .ToggleLineComment)), 1)
		a, bound = km.keymap_resolve(&ed2.keymap, {.Slash, {.Ctrl}})
		testing.expect(t, bound && a == .ToggleLineComment, "default back")
		key_and_update(&ed2, sdl.K_DELETE)
		testing.expect_value(t, len(km.keymap_chords_for(&ed2.keymap, .ToggleLineComment)), 0)
	})
}

@(test)
test_keymap_editor_rebind_takes_chord_from_other_action :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("x")
		defer editor_destroy(&ed)
		editor_show_window(&ed, .Keymap)
		editor_keymap_select_action(&ed, .DeleteLine)
		key_and_update(&ed, sdl.K_RETURN)
		key_and_update(&ed, sdl.K_A, sdl.KMOD_LCTRL) // was Select All
		a, _ := km.keymap_resolve(&ed.keymap, {.A, {.Ctrl}})
		testing.expect_value(t, a, km.Action.DeleteLine)
		testing.expect(t, strings.contains(editor_status_text(&ed), "was Select All"), "status names the old action")
		// Escape while recording cancels without binding.
		key_and_update(&ed, sdl.K_RETURN)
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.keymap_editor.capturing && ed.window == .Keymap, "cancelled, still open")
		testing.expect_value(t, len(km.keymap_chords_for(&ed.keymap, .DeleteLine)), 1)
		// Clicking a row selects it; the palette shortcut still works.
		top, _ := editor_keymap_layout(&ed)
		mouse_click(&ed, ed.origin_x + 40, top + ed.char_h / 2)
		testing.expect_value(t, ed.keymap_editor.selected, ed.keymap_editor.scroll)
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL)
		testing.expect(t, ed.palette.open, "palette opens over the keymap editor")
	})
}

@(test)
test_import_keymap_from_file :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		dir := make_temp_dir("kmimport")
		defer os.remove_all(dir)
		zed_path := filepath.join({dir, "zed.json"}, context.temp_allocator) or_else ""
		zed := `// my keys
[
  { "context": "Editor", "bindings": { "ctrl-shift-j": "editor::DuplicateLineDown", "ctrl-shift-u": "editor::Frobnicate", "ctrl-k ctrl-c": "editor::ToggleComments" } },
]`
		_ = os.write_entire_file(zed_path, transmute([]u8)zed)
		ed := make_mouse_test_editor("x")
		defer editor_destroy(&ed)
		editor_set_config_dir(&ed, dir)
		editor_set_import_path(&ed, .Zed, zed_path)
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		type_and_update(&ed, "import keybindings from zed")
		key_and_update(&ed, sdl.K_RETURN)
		a, bound := km.keymap_resolve(&ed.keymap, {.J, {.Ctrl, .Shift}})
		testing.expect(t, bound && a == .DuplicateLineDown, "imported binding")
		testing.expect_value(t, ed.config.last_import, "Imported from Zed: 1 bound, 1 unsupported (editor::Frobnicate), 1 key sequence skipped")
		testing.expect(t, os.exists(filepath.join({dir, KEYMAP_FILE}, context.temp_allocator) or_else ""), "saved")

		// A missing file is reported, not fatal.
		editor_set_import_path(&ed, .VSCode, filepath.join({dir, "nope.json"}, context.temp_allocator) or_else "")
		testing.expect(t, !editor_import_keymap(&ed, .VSCode), "missing file")
		testing.expect(t, strings.has_prefix(ed.config.last_import, "No VSCode keymap at"), "reported")
	})
}
