package code_editor

import km "../keymap"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

@(private = "file")
run_palette :: proc(ed: ^Editor, query: string) {
	key_and_update(ed, sdl.K_P, sdl.KMOD_LCTRL)
	type_and_update(ed, query)
	key_and_update(ed, sdl.K_RETURN)
}

@(test)
test_palette_switches_between_windows :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("alpha")
		defer editor_destroy(&ed)

		// With an empty query the windows follow the recent commands.
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL)
		entries, matches := editor_palette_matches(&ed)
		testing.expect_value(t, entries[matches[0].entry].kind, Palette_Entry_Kind.Window)
		key_and_update(&ed, sdl.K_ESCAPE)

		run_palette(&ed, "keymap editor")
		testing.expect_value(t, ed.window, Editor_Window.Keymap)
		run_palette(&ed, "theme editor") // palette works from a tool window
		testing.expect_value(t, ed.window, Editor_Window.Theme)
		run_palette(&ed, "utilities")
		testing.expect_value(t, ed.window, Editor_Window.Utilities)
		run_palette(&ed, "find / replace")
		testing.expect_value(t, ed.window, Editor_Window.Text)
		testing.expect(t, ed.find.open && ed.find.focused, "find bar opened")
		key_and_update(&ed, sdl.K_ESCAPE)
		run_palette(&ed, "keymap editor")
		run_palette(&ed, "editor")
		testing.expect_value(t, ed.window, Editor_Window.Text)
	})
}

@(test)
test_utilities_reset_actions :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("x")
		defer editor_destroy(&ed)
		ed.visible_rows = 30 // room for the whole window
		km.keymap_unbind(&ed.keymap, {.A, {.Ctrl}})
		ed.theme.text_keyword = {1, 2, 3, 255}

		editor_show_window(&ed, .Utilities)
		ed.utilities.selected = int(Utility.Reset_Keymap)
		key_and_update(&ed, sdl.K_RETURN)
		a, ok := km.keymap_resolve(&ed.keymap, {.A, {.Ctrl}})
		testing.expect(t, ok && a == .SelectAll, "key bindings reset")

		// Clicking an action runs it.
		top := editor_utilities_layout(&ed)
		mouse_click(&ed, ed.origin_x + 40, top + f32(int(Utility.Reset_Theme)) * ed.char_h + ed.char_h / 2)
		testing.expect(t, ed.theme == ayu_dark_theme(), "theme reset")
		testing.expect_value(t, ed.utilities.selected, int(Utility.Reset_Theme))

		// Up wraps; Escape closes.
		ed.utilities.selected = 0
		key_and_update(&ed, sdl.K_UP)
		testing.expect_value(t, ed.utilities.selected, len(Utility) - 1)
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect_value(t, ed.window, Editor_Window.Text)
	})
}

@(test)
test_utilities_stop_and_restart_server :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("x")
		defer editor_destroy(&ed)
		testing.expect(t, !editor_lsp_restart(&ed), "nothing to restart without a server")
		testing.expect(t, strings.contains(editor_lsp_info(&ed)[0], "Off"), "status off")

		testing.expect(t, editor_attach_lsp(&ed, []string{"/bin/sh", "-c", "sleep 30"}, "/tmp"), "attached")
		first := ed.lsp.process.pid
		testing.expect(t, strings.contains(editor_lsp_info(&ed)[0], "pid"), "pid shown")

		editor_run_utility(&ed, .Toggle_Server) // stop
		testing.expect(t, !ed.lsp_enabled, "stopped")
		testing.expect_value(t, editor_lsp_status(&ed), Lsp_Status.Off)
		testing.expect_value(t, utility_label(&ed, .Toggle_Server), "Language Server: Start")

		editor_run_utility(&ed, .Toggle_Server) // start
		testing.expect(t, ed.lsp_enabled && ed.lsp.has_process, "started")
		testing.expect(t, ed.lsp.process.pid != first, "new process")

		// Restart also revives a server the supervisor gave up on.
		ed.lsp_supervisor.failed = true
		second := ed.lsp.process.pid
		editor_run_utility(&ed, .Restart_Server)
		testing.expect(t, !ed.lsp_supervisor.failed && ed.lsp.process.pid != second, "restarted")
		testing.expect_value(t, editor_status_text(&ed), "Language server restarted")
	})
}
