// Keymap editor window: every action with its key bindings, filtered by
// typing (matches the command name fuzzily, or a key like "cmd+shift").
//   Up/Down/PageUp/PageDown  select
//   Enter                    record a new binding (replaces the old ones)
//   Shift+Enter              record an additional binding
//   Delete                   remove the selected action's bindings
//   Cmd/Ctrl+R               reset the selected action to its defaults
//   Escape                   cancel recording / clear the filter / close
// While recording, the next key combination is bound (Escape cancels).
// Every change is saved to the config dir's keymap.json.
package code_editor

import km "../keymap"
import "core:fmt"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Keymap_Editor :: struct {
	filter:    strings.Builder,
	selected:  int,
	scroll:    int,
	capturing: bool,
	adding:    bool, // the capture adds a binding rather than replacing
}

Keymap_Row :: struct {
	action: km.Action,
	title:  string,
	chords: []km.Chord,
	user:   bool, // differs from the default bindings
}

keymap_editor_destroy :: proc(k: ^Keymap_Editor) {
	strings.builder_destroy(&k.filter)
}

// keymap_action_title: the command name shown in the keymap editor.
keymap_action_title :: proc(a: km.Action) -> string {
	#partial switch a {
	case .OpenKeymapEditor: return "Preferences: Open Keymap Editor"
	case .CommandPalette: return "View: Command Palette"
	}
	if l := action_label(a); len(l) > 0 {
		return l
	}
	return km.action_name(a)
}

@(private)
same_chords :: proc(a, b: []km.Chord) -> bool {
	if len(a) != len(b) {
		return false
	}
	for c, i in a {
		if c != b[i] {
			return false
		}
	}
	return true
}

// editor_keymap_rows lists the actions matching the filter, by title.
editor_keymap_rows :: proc(ed: ^Editor) -> []Keymap_Row {
	defaults := km.keymap_default(ed.platform, context.temp_allocator)
	q := strings.to_string(ed.keymap_editor.filter)
	rows := make([dynamic]Keymap_Row, context.temp_allocator)
	for a in km.Action {
		if a == .None {
			continue
		}
		r := Keymap_Row{action = a, title = keymap_action_title(a), chords = km.keymap_chords_for(&ed.keymap, a)}
		r.user = !same_chords(r.chords, km.keymap_chords_for(&defaults, a))
		if len(q) > 0 {
			_, ok := fuzzy_score(r.title, q)
			for c in r.chords {
				ok ||= strings.contains(strings.to_lower(chord_text(c), context.temp_allocator), strings.to_lower(q, context.temp_allocator))
			}
			if !ok {
				continue
			}
		}
		append(&rows, r)
	}
	slice.sort_by(rows[:], proc(x, y: Keymap_Row) -> bool {return x.title < y.title})
	return rows[:]
}

@(private)
keymap_editor_selected_row :: proc(ed: ^Editor) -> (Keymap_Row, bool) {
	rows := editor_keymap_rows(ed)
	if ed.keymap_editor.selected < 0 || ed.keymap_editor.selected >= len(rows) {
		return {}, false
	}
	return rows[ed.keymap_editor.selected], true
}

// editor_keymap_bind_selected binds `chord` to the selected action
// (replacing its bindings unless `add`), taking it from any other action.
editor_keymap_bind_selected :: proc(ed: ^Editor, chord: km.Chord, add := false) -> bool {
	row, ok := keymap_editor_selected_row(ed)
	if !ok {
		return false
	}
	if !add {
		for c in row.chords {
			km.keymap_unbind(&ed.keymap, c)
		}
	}
	if prev, bound := km.keymap_resolve(&ed.keymap, chord); bound && prev != row.action {
		editor_set_status(ed, fmt.tprintf("%s now runs %s (was %s)", chord_text(chord), row.title, keymap_action_title(prev)))
	} else {
		editor_set_status(ed, fmt.tprintf("%s now runs %s", chord_text(chord), row.title))
	}
	km.keymap_bind(&ed.keymap, chord, row.action)
	editor_save_keymap(ed)
	editor_keymap_select_action(ed, row.action)
	return true
}

// editor_keymap_remove_selected removes the selected action's bindings.
editor_keymap_remove_selected :: proc(ed: ^Editor) {
	row, ok := keymap_editor_selected_row(ed)
	if !ok {
		return
	}
	for c in row.chords {
		km.keymap_unbind(&ed.keymap, c)
	}
	editor_save_keymap(ed)
	editor_set_status(ed, fmt.tprintf("Removed bindings of %s", row.title))
}

// editor_keymap_reset_selected restores the selected action's default
// bindings (taking those chords back from whatever they were rebound to).
editor_keymap_reset_selected :: proc(ed: ^Editor) {
	row, ok := keymap_editor_selected_row(ed)
	if !ok {
		return
	}
	for c in row.chords {
		km.keymap_unbind(&ed.keymap, c)
	}
	defaults := km.keymap_default(ed.platform, context.temp_allocator)
	for c in km.keymap_chords_for(&defaults, row.action) {
		km.keymap_bind(&ed.keymap, c, row.action)
	}
	editor_save_keymap(ed)
	editor_set_status(ed, fmt.tprintf("Reset %s", row.title))
}

// editor_keymap_select_action moves the selection to `a` if it's listed.
editor_keymap_select_action :: proc(ed: ^Editor, a: km.Action) {
	for r, i in editor_keymap_rows(ed) {
		if r.action == a {
			ed.keymap_editor.selected = i
			keymap_editor_clamp_scroll(ed)
			return
		}
	}
}

@(private)
keymap_editor_clamp_scroll :: proc(ed: ^Editor) {
	k := &ed.keymap_editor
	_, rows := editor_keymap_layout(ed)
	n := len(editor_keymap_rows(ed))
	k.selected = clamp(k.selected, 0, max(0, n - 1))
	if k.selected < k.scroll {
		k.scroll = k.selected
	} else if k.selected >= k.scroll + rows {
		k.scroll = k.selected - rows + 1
	}
	k.scroll = clamp(k.scroll, 0, max(0, n - rows))
}

editor_keymap_text_input :: proc(ed: ^Editor, text: string) {
	k := &ed.keymap_editor
	if k.capturing {
		return
	}
	strings.write_string(&k.filter, text)
	k.selected, k.scroll = 0, 0
}

@(private)
is_modifier_only :: proc(c: km.Chord) -> bool {
	return c.key == .Unknown
}

editor_keymap_handle_key :: proc(ed: ^Editor, chord: km.Chord) -> bool {
	k := &ed.keymap_editor
	if k.capturing {
		if is_modifier_only(chord) {
			return true // wait for the actual key
		}
		k.capturing = false
		if chord.key == .Escape && chord.mods == {} {
			editor_set_status(ed, "Recording cancelled")
			return true
		}
		editor_keymap_bind_selected(ed, chord, k.adding)
		return true
	}
	_, page := editor_keymap_layout(ed)
	n := len(editor_keymap_rows(ed))
	primary := .Super in chord.mods || .Ctrl in chord.mods
	#partial switch chord.key {
	case .Escape:
		if len(k.filter.buf) > 0 {
			strings.builder_reset(&k.filter)
			k.selected, k.scroll = 0, 0
		} else {
			editor_show_window(ed, .Text)
		}
	case .Enter:
		if n > 0 {
			k.capturing = true
			k.adding = .Shift in chord.mods
		}
	case .Up:
		k.selected = max(0, k.selected - 1)
	case .Down:
		k.selected = min(n - 1, k.selected + 1)
	case .PageUp:
		k.selected = max(0, k.selected - page)
	case .PageDown:
		k.selected = min(n - 1, k.selected + page)
	case .Home:
		if primary {k.selected = 0}
	case .End:
		if primary {k.selected = n - 1}
	case .Delete:
		editor_keymap_remove_selected(ed)
	case .R:
		if primary {
			editor_keymap_reset_selected(ed)
		}
	case .Backspace:
		s := strings.to_string(k.filter)
		if len(s) > 0 {
			i := len(s) - 1
			for i > 0 && s[i] & 0xC0 == 0x80 {
				i -= 1
			}
			resize(&k.filter.buf, i)
			k.selected, k.scroll = 0, 0
		}
	}
	keymap_editor_clamp_scroll(ed)
	return true
}

// editor_keymap_layout: where the list starts and how many rows fit.
editor_keymap_layout :: proc(ed: ^Editor) -> (list_top: f32, rows: int) {
	area := editor_area_rect(ed)
	list_top = area.y + 4 * ed.char_h + 8 // title, filter, column header
	bottom := area.y + area.h - 2 * ed.char_h // hint + status footer
	return list_top, max(1, int((bottom - list_top) / ed.char_h))
}

// editor_keymap_row_at maps a window y to a row index (-1 = none).
editor_keymap_row_at :: proc(ed: ^Editor, y: f32) -> int {
	top, rows := editor_keymap_layout(ed)
	if y < top {
		return -1
	}
	r := int((y - top) / ed.char_h)
	if r >= rows {
		return -1
	}
	i := ed.keymap_editor.scroll + r
	return i if i < len(editor_keymap_rows(ed)) else -1
}

editor_keymap_click :: proc(ed: ^Editor, ev: sdl.MouseButtonEvent) {
	i := editor_keymap_row_at(ed, ev.y)
	if i < 0 {
		return
	}
	ed.keymap_editor.selected = i
	ed.keymap_editor.capturing = false
	if ev.clicks >= 2 {
		ed.keymap_editor.capturing = true
		ed.keymap_editor.adding = false
	}
}

editor_keymap_scroll :: proc(ed: ^Editor, lines: int) {
	k := &ed.keymap_editor
	_, rows := editor_keymap_layout(ed)
	n := len(editor_keymap_rows(ed))
	k.scroll = clamp(k.scroll + lines, 0, max(0, n - rows))
}

@(private)
render_keymap_editor :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	k := &ed.keymap_editor
	area := editor_area_rect(ed)
	pad := ed.char_w
	x := area.x + pad
	y := render_window_title(ed, renderer, font, theme, "Keyboard Shortcuts")

	// Filter input.
	fill_rect(renderer, {x, y, area.w - 2 * pad, ed.char_h}, theme.gutter_bg)
	q := strings.to_string(k.filter)
	if len(q) == 0 {
		draw_text(renderer, font, "Type to search commands or keys (e.g. \"comment\", \"cmd+shift\")", x + 4, y, theme.popup_text_dim, ed.char_h)
	} else {
		draw_text(renderer, font, q, x + 4, y, theme.text_default, ed.char_h)
	}
	if !k.capturing {
		fill_rect(renderer, {x + 4 + f32(text_cols(q)) * ed.char_w, y + 3, 2, ed.char_h - 6}, theme.cursor)
	}

	key_x := area.x + area.w * 0.55
	src_x := area.x + area.w - 9 * ed.char_w
	top, page := editor_keymap_layout(ed)
	draw_text(renderer, font, "Command", x, top - ed.char_h - 4, theme.popup_text_dim, ed.char_h)
	draw_text(renderer, font, "Keybinding", key_x, top - ed.char_h - 4, theme.popup_text_dim, ed.char_h)
	draw_text(renderer, font, "Source", src_x, top - ed.char_h - 4, theme.popup_text_dim, ed.char_h)
	fill_rect(renderer, {area.x, top - 3, area.w, 1}, theme.popup_border)

	rows := editor_keymap_rows(ed)
	render_overlay_scrollbar(renderer, {area.x, top, area.w, f32(page) * ed.char_h}, len(rows), page, k.scroll, theme)
	for r in 0 ..< page {
		i := k.scroll + r
		if i >= len(rows) {
			break
		}
		row := rows[i]
		ry := top + f32(r) * ed.char_h
		if i == k.selected {
			fill_rect(renderer, {area.x, ry, area.w, ed.char_h}, theme.popup_selected)
		} else if ed.mouse.zone == .Tool_Window && editor_keymap_row_at(ed, ed.mouse.y) == i {
			fill_rect(renderer, {area.x, ry, area.w, ed.char_h}, theme.current_line)
		}
		draw_text(renderer, font, row.title, x, ry, theme.text_default, ed.char_h)
		if i == k.selected && k.capturing {
			msg := "Press keys to add... (Esc cancels)" if k.adding else "Press keys... (Esc cancels)"
			draw_text(renderer, font, msg, key_x, ry, theme.popup_match, ed.char_h)
		} else {
			kx := key_x
			for c in row.chords {
				label := chord_text(c)
				w := f32(text_cols(label)) * ed.char_w
				fill_rect(renderer, {kx - 3, ry + 2, w + 6, ed.char_h - 4}, theme.gutter_bg)
				draw_text(renderer, font, label, kx, ry, theme.text_keyword, ed.char_h)
				kx += w + 2 * ed.char_w
				if kx > src_x - 4 * ed.char_w {
					break
				}
			}
			if len(row.chords) == 0 {
				draw_text(renderer, font, "-", kx, ry, theme.popup_text_dim, ed.char_h)
			}
		}
		draw_text(renderer, font, "User" if row.user else "Default", src_x, ry, theme.text_string if row.user else theme.popup_text_dim, ed.char_h)
	}
	render_window_footer(ed, renderer, font, theme, "Enter rebind · Shift+Enter add · Del remove · Cmd/Ctrl+R reset · Esc close")
}
