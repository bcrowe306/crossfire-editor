// Utilities window: language-server status (state, process, command,
// root, document sync, diagnostics, crash count) and maintenance actions —
// restart / stop / start the server, resync the document, copy the server
// info, reset key bindings or the theme, reload settings. The actions are
// also palette commands ("Language Server: Restart", ...).
//   Up/Down  choose an action   Enter / click  run it   Escape  close
package code_editor

import km "../keymap"
import lspc "../lsp"
import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Utility :: enum {
	Restart_Server,
	Toggle_Server, // stop when running, start when stopped
	Resync_Document,
	Copy_Server_Info,
	Reset_Keymap,
	Reset_Theme,
	Reload_Settings,
}

Utilities_State :: struct {
	selected: int,
	// The first row shown, when the window is too short for it all (the wheel, or the selected
	// action kept in view)
	scroll:   int,
}

// utilities_content_rows is the window's content in rows: the server's lines, the actions,
// the settings (with their headings and gaps)
@(private)
utilities_content_rows :: proc(ed: ^Editor) -> int {
	return len(editor_lsp_info(ed)) + 3 + len(Utility) + 4
}

// utilities_content_rect is where the content shows: between the title bar and the footer
@(private)
utilities_content_rect :: proc(ed: ^Editor) -> (rect: sdl.FRect, rows: int) {
	area := editor_area_rect(ed)
	rect = {area.x, area.y + 2 * ed.char_h, area.w, max(area.h - 4 * ed.char_h, ed.char_h)}
	return rect, max(int(rect.h / ed.char_h), 1)
}

// editor_utilities_scroll scrolls the window's content by `lines` (the wheel)
editor_utilities_scroll :: proc(ed: ^Editor, lines: int) {
	_, rows := utilities_content_rect(ed)
	ed.utilities.scroll = overlay_scroll_clamp(ed.utilities.scroll + lines, utilities_content_rows(ed), rows)
}

utility_label :: proc(ed: ^Editor, u: Utility) -> string {
	switch u {
	case .Restart_Server: return "Language Server: Restart"
	case .Toggle_Server: return "Language Server: Stop" if ed.lsp_enabled else "Language Server: Start"
	case .Resync_Document: return "Language Server: Resync Document"
	case .Copy_Server_Info: return "Language Server: Copy Status Info"
	case .Reset_Keymap: return "Preferences: Reset Key Bindings to Defaults"
	case .Reset_Theme: return "Preferences: Reset Theme to Ayu Dark"
	case .Reload_Settings: return "Preferences: Reload Settings from Disk"
	}
	return ""
}

// editor_lsp_respawn starts a fresh server process with the supervised
// command (the old client, dead or alive, is discarded).
editor_lsp_respawn :: proc(ed: ^Editor) -> bool {
	s := &ed.lsp_supervisor
	if len(s.command) == 0 {
		return false
	}
	editor_close_completion(ed)
	editor_close_signature_help(ed)
	lspc.client_destroy(&ed.lsp)
	ed.lsp = lspc.client_init()
	ed.lsp.init_options = strings.clone(s.init_options, ed.lsp.allocator)
	ed.lsp_doc_open = false
	ed.lsp_enabled = true
	if !lspc.client_start(&ed.lsp, s.command, s.root) {
		ed.lsp.dead = true
		return false
	}
	lspc.client_initialize(&ed.lsp, lspc.file_uri(s.root, context.temp_allocator))
	// didOpen is re-sent by editor_sync_lsp once initialize completes.
	return true
}

// editor_lsp_restart restarts the server on request (also after the
// supervisor gave up), resetting the crash budget.
editor_lsp_restart :: proc(ed: ^Editor) -> bool {
	s := &ed.lsp_supervisor
	if len(s.command) == 0 {
		editor_set_status(ed, "No language server configured")
		return false
	}
	s.failed, s.restart_due, s.restarts = false, false, 0
	ok := editor_lsp_respawn(ed)
	editor_set_status(ed, "Language server restarted" if ok else "Language server failed to start")
	return ok
}

// editor_lsp_stop shuts the server down; the editor carries on as a plain
// text editor until it's started again.
editor_lsp_stop :: proc(ed: ^Editor) {
	if !ed.lsp_enabled {
		return
	}
	editor_close_completion(ed)
	editor_close_signature_help(ed)
	lspc.client_destroy(&ed.lsp)
	ed.lsp = {}
	ed.lsp_enabled = false
	ed.lsp_doc_open = false
	ed.lsp_supervisor.restart_due = false
	editor_set_status(ed, "Language server stopped")
}

// editor_lsp_resync closes and reopens the document on the server so it
// gets the full text again.
editor_lsp_resync :: proc(ed: ^Editor) {
	if !editor_lsp_ready(ed) {
		editor_set_status(ed, "No language server")
		return
	}
	if ed.lsp_doc_open {
		lspc.client_did_close(&ed.lsp, ed.document_uri)
		ed.lsp_doc_open = false
	}
	editor_set_status(ed, "Document resynced with the language server")
}

// editor_lsp_info lists "label: value" lines describing the server.
editor_lsp_info :: proc(ed: ^Editor) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	s := &ed.lsp_supervisor
	status := editor_lsp_status(ed)
	state := fmt.tprint(status)
	if ed.lsp_enabled && ed.lsp.has_process {
		state = fmt.tprintf("%v (pid %d)", status, ed.lsp.process.pid)
	}
	append(&out, fmt.tprintf("Status: %s", state))
	cmd := strings.join(s.command, " ", context.temp_allocator) if len(s.command) > 0 else "(none)"
	append(&out, fmt.tprintf("Command: %s", cmd))
	append(&out, fmt.tprintf("Root: %s", s.root if len(s.root) > 0 else "-"))
	name, _ := editor_display_name(ed)
	sync := "open" if ed.lsp_doc_open else "not open"
	if ed.lsp_doc_open {
		sync = fmt.tprintf("open, version %d%s", ed.lsp_synced_version, "" if ed.lsp_synced_version == ed.buf.version else " (edits pending)")
	}
	append(&out, fmt.tprintf("Document: %s (%s)", name, sync))
	errors, warnings, others := 0, 0, 0
	for d in editor_diagnostics(ed) {
		#partial switch d.severity {
		case .Error: errors += 1
		case .Warning: warnings += 1
		case: others += 1
		}
	}
	append(&out, fmt.tprintf("Diagnostics: %d errors, %d warnings, %d other", errors, warnings, others))
	append(&out, fmt.tprintf("Crashes: %d total, %d restarts in the last minute%s", s.total_crashes, s.restarts, " (gave up)" if s.failed else ""))
	return out[:]
}

editor_run_utility :: proc(ed: ^Editor, u: Utility) {
	switch u {
	case .Restart_Server:
		editor_lsp_restart(ed)
	case .Toggle_Server:
		if ed.lsp_enabled {
			editor_lsp_stop(ed)
		} else {
			editor_lsp_restart(ed)
		}
	case .Resync_Document:
		editor_lsp_resync(ed)
	case .Copy_Server_Info:
		text := strings.join(editor_lsp_info(ed), "\n", context.temp_allocator)
		_ = sdl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
		editor_set_status(ed, "Server info copied")
	case .Reset_Keymap:
		km.keymap_destroy(&ed.keymap)
		ed.keymap = km.keymap_default(ed.platform)
		editor_save_keymap(ed)
		editor_set_status(ed, "Key bindings reset to defaults")
	case .Reset_Theme:
		editor_apply_preset(ed, .Ayu_Dark)
	case .Reload_Settings:
		editor_load_keymap(ed)
		if !editor_load_theme(ed) {
			ed.theme = preset_theme(ed.theme_editor.base)
		}
		src := ed.config.dir if len(ed.config.dir) > 0 else "defaults (no config folder)"
		editor_set_status(ed, fmt.tprintf("Settings reloaded from %s", src))
	}
}

editor_utilities_handle_key :: proc(ed: ^Editor, chord: km.Chord) -> bool {
	u := &ed.utilities
	n := len(Utility)
	#partial switch chord.key {
	case .Escape:
		editor_show_window(ed, .Text)
	case .Up:
		u.selected = (u.selected - 1 + n) % n
	case .Down:
		u.selected = (u.selected + 1) % n
	case .Enter:
		editor_run_utility(ed, Utility(u.selected))
	}
	// The selected action stays in view
	_, rows := utilities_content_rect(ed)
	u.scroll = overlay_scroll_reveal(u.scroll, len(editor_lsp_info(ed)) + 3 + u.selected, utilities_content_rows(ed), rows)
	return true
}

// editor_utilities_layout: the top of the action list (one row each).
editor_utilities_layout :: proc(ed: ^Editor) -> (actions_top: f32) {
	area := editor_area_rect(ed)
	info_rows := len(editor_lsp_info(ed))
	return area.y + 2 * ed.char_h + f32(info_rows + 3 - ed.utilities.scroll) * ed.char_h
}

editor_utilities_row_at :: proc(ed: ^Editor, y: f32) -> int {
	top := editor_utilities_layout(ed)
	content, _ := utilities_content_rect(ed)
	if y < top || y < content.y || y >= content.y + content.h {
		return -1
	}
	r := int((y - top) / ed.char_h)
	return r if r < len(Utility) else -1
}

editor_utilities_click :: proc(ed: ^Editor, y: f32) {
	if r := editor_utilities_row_at(ed, y); r >= 0 {
		ed.utilities.selected = r
		editor_run_utility(ed, Utility(r))
	}
}

@(private)
render_utilities :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	area := editor_area_rect(ed)
	y := render_window_title(ed, renderer, font, theme, "Utilities")
	x := area.x + 2 * ed.char_w
	// The content scrolls between the title and the footer, clipped there (the host's clip is put
	// back after)
	content, content_rows := utilities_content_rect(ed)
	scroll := overlay_scroll_clamp(ed.utilities.scroll, utilities_content_rows(ed), content_rows)
	y -= f32(scroll) * ed.char_h
	saved_clip := clip_push(renderer, content)
	draw_text(renderer, font, "Language server (OLS)", area.x + ed.char_w, y, theme.header_text, ed.char_h)
	y += ed.char_h
	for line, i in editor_lsp_info(ed) {
		colon := strings.index(line, ": ")
		label, value := line[:colon + 1], line[colon + 2:]
		draw_text(renderer, font, label, x, y, theme.popup_text_dim, ed.char_h)
		color := theme.text_default
		if i == 0 {
			switch editor_lsp_status(ed) {
			case .Running: color = theme.text_string
			case .Starting, .Restarting: color = theme.diag_warning
			case .Failed: color = theme.diag_error
			case .Off: color = theme.popup_text_dim
			}
		}
		draw_text(renderer, font, truncate_cols(value, int((area.w - 16 * ed.char_w) / ed.char_w)), x + 13 * ed.char_w, y, color, ed.char_h)
		y += ed.char_h
	}

	top := editor_utilities_layout(ed)
	draw_text(renderer, font, "Actions", area.x + ed.char_w, top - 1.5 * ed.char_h, theme.header_text, ed.char_h)
	for u in Utility {
		ry := top + f32(int(u)) * ed.char_h
		if int(u) == ed.utilities.selected {
			fill_rect(renderer, {area.x, ry, area.w, ed.char_h}, theme.popup_selected)
		} else if ed.mouse.zone == .Tool_Window && editor_utilities_row_at(ed, ed.mouse.y) == int(u) {
			fill_rect(renderer, {area.x, ry, area.w, ed.char_h}, theme.current_line)
		}
		draw_text(renderer, font, utility_label(ed, u), x, ry, theme.text_default, ed.char_h)
	}

	sy := top + f32(len(Utility) + 1) * ed.char_h
	draw_text(renderer, font, "Settings", area.x + ed.char_w, sy, theme.header_text, ed.char_h)
	folder := ed.config.dir if len(ed.config.dir) > 0 else "(not persisted: the host set no config folder)"
	draw_text(renderer, font, "Folder:", x, sy + ed.char_h, theme.popup_text_dim, ed.char_h)
	draw_text(renderer, font, folder, x + 13 * ed.char_w, sy + ed.char_h, theme.text_default, ed.char_h)
	files := make([dynamic]string, context.temp_allocator)
	for f in ([]string{KEYMAP_FILE, THEME_FILE}) {
		if p := config_path(ed, f); len(p) > 0 && os.exists(p) {
			append(&files, f)
		}
	}
	draw_text(renderer, font, "Files:", x, sy + 2 * ed.char_h, theme.popup_text_dim, ed.char_h)
	draw_text(renderer, font, strings.join(files[:], ", ", context.temp_allocator) if len(files) > 0 else "none yet", x + 13 * ed.char_w, sy + 2 * ed.char_h, theme.text_default, ed.char_h)
	clip_pop(renderer, saved_clip)
	render_overlay_scrollbar(renderer, content, utilities_content_rows(ed), content_rows, scroll, theme)
	render_window_footer(ed, renderer, font, theme, "Up/Down choose · Enter or click run · Esc close")
}
