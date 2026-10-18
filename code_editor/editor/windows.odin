// Editor windows: besides the text view, the editor can show full-area
// tool windows (keymap editor, theme editor, utilities), switched from the
// command palette. A tool window owns the keyboard (except the palette and
// zoom shortcuts); Escape returns to the text view.
package code_editor

import km "../keymap"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Editor_Window :: enum {
	Text,
	Keymap,
	Theme,
	Utilities,
}

// window_label is the palette name of a window ("" = not listed).
window_label :: proc(w: Editor_Window) -> string {
	switch w {
	case .Text: return "Editor"
	case .Keymap: return "Keymap Editor"
	case .Theme: return "Theme Editor"
	case .Utilities: return "Utilities (Language Server, Settings)"
	}
	return ""
}

window_detail :: proc(w: Editor_Window) -> string {
	return "window"
}

editor_show_window :: proc(ed: ^Editor, w: Editor_Window) {
	if w != .Text {
		editor_close_completion(ed)
		editor_close_context_menu(ed)
		editor_hide_hover(ed)
		ed.find.focused = false
	}
	ed.window = w
	switch w {
	case .Text:
	case .Keymap:
		ed.keymap_editor.capturing = false
		keymap_editor_clamp_scroll(ed)
	case .Theme:
		ed.theme_editor.editing = false
		theme_editor_clamp_scroll(ed)
	case .Utilities:
	}
}

// editor_area_rect is the whole editor area (header included), which a
// tool window covers.
editor_area_rect :: proc(ed: ^Editor) -> sdl.FRect {
	top := ed.origin_y - editor_header_height(ed)
	w := editor_gutter_width(ed) + f32(ed.visible_cols) * ed.char_w + SCROLLBAR_SIZE
	h := editor_header_height(ed) + f32(ed.visible_rows) * ed.char_h + SCROLLBAR_SIZE
	return {ed.origin_x, top, w, h}
}

// Shortcuts that still work inside a tool window.
@(private)
window_passthrough :: proc(a: km.Action) -> bool {
	#partial switch a {
	case .CommandPalette, .ZoomIn, .ZoomOut, .ZoomReset, .OpenKeymapEditor, .Save:
		return true
	}
	return false
}

@(private)
editor_window_handle_key :: proc(ed: ^Editor, chord: km.Chord) -> bool {
	capturing := (ed.window == .Keymap && ed.keymap_editor.capturing) || (ed.window == .Theme && ed.theme_editor.editing)
	if !capturing {
		if a, ok := km.keymap_resolve(&ed.keymap, chord); ok && window_passthrough(a) {
			if a == .OpenKeymapEditor && ed.window == .Keymap {
				editor_show_window(ed, .Text) // the shortcut toggles
				return true
			}
			return editor_run_action(ed, a)
		}
	}
	switch ed.window {
	case .Text:
	case .Keymap:
		return editor_keymap_handle_key(ed, chord)
	case .Theme:
		return editor_theme_handle_key(ed, chord)
	case .Utilities:
		return editor_utilities_handle_key(ed, chord)
	}
	return false
}

@(private)
editor_window_text_input :: proc(ed: ^Editor, text: string) {
	switch ed.window {
	case .Text:
	case .Keymap:
		editor_keymap_text_input(ed, text)
	case .Theme:
		editor_theme_text_input(ed, text)
	case .Utilities:
	}
}

@(private)
editor_window_click :: proc(ed: ^Editor, ev: sdl.MouseButtonEvent) {
	switch ed.window {
	case .Text:
	case .Keymap:
		if ev.button == 1 {
			editor_keymap_click(ed, ev)
		}
	case .Theme:
		if ev.button == 1 {
			editor_theme_click(ed, ev.x, ev.y)
		}
	case .Utilities:
		if ev.button == 1 {
			editor_utilities_click(ed, ev.y)
		}
	}
}

// editor_window_motion / editor_window_release: drags inside a tool
// window (theme sliders) follow the pointer even outside it.
@(private)
editor_window_motion :: proc(ed: ^Editor, x, y: f32) {
	if ed.window == .Theme {
		editor_theme_drag(ed, x, y)
	}
}

@(private)
editor_window_release :: proc(ed: ^Editor) {
	if ed.window == .Theme {
		editor_theme_release(ed)
	}
}

@(private)
editor_window_scroll :: proc(ed: ^Editor, lines: int) {
	switch ed.window {
	case .Text:
	case .Keymap:
		editor_keymap_scroll(ed, lines)
	case .Theme:
		editor_theme_scroll(ed, lines)
	case .Utilities:
	}
}

@(private)
render_tool_window :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	if font == nil {
		return
	}
	fill_rect(renderer, editor_area_rect(ed), theme.background)
	switch ed.window {
	case .Text:
	case .Keymap:
		render_keymap_editor(ed, renderer, font, theme)
	case .Theme:
		render_theme_editor(ed, renderer, font, theme)
	case .Utilities:
		render_utilities(ed, renderer, font, theme)
	}
}

// render_window_title draws a tool window's title bar; returns the y
// where the window's content starts.
@(private)
render_window_title :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme, title: string) -> f32 {
	area := editor_area_rect(ed)
	h := 1.5 * ed.char_h
	fill_rect(renderer, {area.x, area.y, area.w, h}, theme.header_bg)
	draw_text(renderer, font, title, area.x + ed.char_w, area.y, theme.header_text, h)
	draw_text(renderer, font, "Esc: back to editor", area.x + area.w - 21 * ed.char_w, area.y, theme.popup_text_dim, h)
	return area.y + h + 0.5 * ed.char_h
}

// render_window_footer draws the key hints and the status message.
@(private)
render_window_footer :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme, hint: string) {
	area := editor_area_rect(ed)
	y := area.y + area.h - 2 * ed.char_h
	fill_rect(renderer, {area.x, y, area.w, 2 * ed.char_h}, theme.header_bg)
	draw_text(renderer, font, hint, area.x + ed.char_w, y, theme.popup_text_dim, ed.char_h)
	if status := editor_status_text(ed); len(status) > 0 {
		draw_text(renderer, font, status, area.x + ed.char_w, y + ed.char_h, theme.header_text, ed.char_h)
	}
}
