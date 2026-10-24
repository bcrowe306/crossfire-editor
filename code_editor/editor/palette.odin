// Command palette (Cmd/Ctrl+P, Cmd/Ctrl+Shift+P, F1): a searchable list of
// every editor command with its shortcut. Typing filters with fuzzy
// matching (word starts and consecutive letters score higher, matched
// letters highlighted); Up/Down/PageUp/PageDown select, Enter runs, Escape
// closes; recently used commands come first when the query is empty.
// Entries are generic (`Palette_Entry`), so other sources — editor
// windows, files — can be listed alongside commands.
package code_editor

import km "../keymap"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

PALETTE_COLS :: 64
PALETTE_ROWS :: 12
PALETTE_MRU :: 8

Palette_Entry_Kind :: enum {
	Command,
	Window, // switch to an editor window (keymap editor, theme editor, ...)
	Preset, // switch the colour theme
	Utility, // a utilities-window action (language server, settings)
}

Palette_Entry :: struct {
	kind:   Palette_Entry_Kind,
	label:  string,
	detail: string, // shortcut (commands) or description
	action: km.Action,
	window: Editor_Window,
	preset: Theme_Preset,
	utility: Utility,
}

Palette_Match :: struct {
	entry:     int, // index into the entry list
	score:     int,
	positions: [8]u8, // first matched label byte offsets (for highlighting)
	n_pos:     int,
}

Palette_State :: struct {
	open:     bool,
	query:    strings.Builder,
	selected: int,
	scroll:   int,
	mru:      [dynamic]km.Action, // most recent first
}

@(private)
palette_init :: proc(p: ^Palette_State) {
	p.query = strings.builder_make()
	p.mru = make([dynamic]km.Action)
}

@(private)
palette_destroy :: proc(p: ^Palette_State) {
	strings.builder_destroy(&p.query)
	delete(p.mru)
}

// action_label is the palette name of an action ("" = not listed).
action_label :: proc(a: km.Action) -> string {
	switch a {
	case .None, .Escape: return ""
	case .MoveLeft: return "Cursor Left"
	case .MoveRight: return "Cursor Right"
	case .MoveUp: return "Cursor Up"
	case .MoveDown: return "Cursor Down"
	case .MoveWordLeft: return "Cursor Word Left"
	case .MoveWordRight: return "Cursor Word Right"
	case .MoveLineStart: return "Go to Line Start"
	case .MoveLineEnd: return "Go to Line End"
	case .MoveDocStart: return "Go to Top of File"
	case .MoveDocEnd: return "Go to End of File"
	case .MovePageUp: return "Page Up"
	case .MovePageDown: return "Page Down"
	case .ExtendLeft: return "Select Left"
	case .ExtendRight: return "Select Right"
	case .ExtendUp: return "Select Up"
	case .ExtendDown: return "Select Down"
	case .ExtendWordLeft: return "Select Word Left"
	case .ExtendWordRight: return "Select Word Right"
	case .ExtendLineStart: return "Select to Line Start"
	case .ExtendLineEnd: return "Select to Line End"
	case .ExtendDocStart: return "Select to Top of File"
	case .ExtendDocEnd: return "Select to End of File"
	case .ExtendPageUp: return "Select Page Up"
	case .ExtendPageDown: return "Select Page Down"
	case .SelectAll: return "Select All"
	case .SelectLine: return "Select Line"
	case .SelectWord: return "Select Word"
	case .Backspace: return "Delete Left"
	case .BackspaceWord: return "Delete Word Left"
	case .DeleteForward: return "Delete Right"
	case .DeleteForwardWord: return "Delete Word Right"
	case .Newline: return "Insert Line Break"
	case .IndentOrTab: return "Indent"
	case .DuplicateLineUp: return "Duplicate Line Up"
	case .DuplicateLineDown: return "Duplicate Line Down"
	case .MoveLineUp: return "Move Line Up"
	case .MoveLineDown: return "Move Line Down"
	case .ToggleLineComment: return "Toggle Line Comment"
	case .DeleteLine: return "Delete Line"
	case .InsertLineBelow: return "Insert Line Below"
	case .InsertLineAbove: return "Insert Line Above"
	case .OpenKeymapEditor: return "" // listed as a window
	case .ImportZedKeymap: return "Preferences: Import Keybindings from Zed"
	case .ImportVSCodeKeymap: return "Preferences: Import Keybindings from VSCode"
	case .Outdent: return "Outdent"
	case .Cut: return "Cut"
	case .Copy: return "Copy"
	case .Paste: return "Paste"
	case .Undo: return "Undo"
	case .Redo: return "Redo"
	case .Save: return "File: Save"
	case .SaveAs, .Open: return "" // need the host's file dialogs
	case .AddCursorAbove: return "Add Cursor Above"
	case .AddCursorBelow: return "Add Cursor Below"
	case .TriggerCompletion: return "Trigger Suggestions"
	case .TriggerSignatureHelp: return "Trigger Parameter Hints"
	case .NextDiagnostic: return "Go to Next Problem"
	case .PrevDiagnostic: return "Go to Previous Problem"
	case .QuickFix: return "Quick Fix..."
	case .ToggleProblems: return "View: Toggle Problems Panel"
	case .GotoDefinition: return "Go to Definition"
	case .PeekDefinition: return "Peek Definition"
	case .FindReferences: return "Find All References"
	case .NextReference: return "Go to Next Reference"
	case .PrevReference: return "Go to Previous Reference"
	case .Rename: return "Rename Symbol"
	case .FindUsages: return "Find Usages in Project"
	case .NavigateBack: return "Go Back"
	case .NavigateForward: return "Go Forward"
	case .Find: return "Find"
	case .Replace: return "Replace"
	case .FindNext: return "Find Next"
	case .FindPrev: return "Find Previous"
	case .SelectNextOccurrence: return "Add Selection to Next Find Match"
	case .SelectAllOccurrences: return "Select All Occurrences"
	case .ZoomIn: return "View: Zoom In"
	case .ZoomOut: return "View: Zoom Out"
	case .ZoomReset: return "View: Reset Zoom"
	case .CommandPalette: return ""
	}
	return ""
}

// editor_palette_entries lists every palette entry (temp-allocated).
editor_palette_entries :: proc(ed: ^Editor) -> []Palette_Entry {
	out := make([dynamic]Palette_Entry, context.temp_allocator)
	for a in km.Action {
		if label := action_label(a); len(label) > 0 {
			append(&out, Palette_Entry{kind = .Command, label = label, detail = chord_label(ed, a), action = a})
		}
	}
	for w in Editor_Window {
		if label := window_label(w); len(label) > 0 {
			append(&out, Palette_Entry{kind = .Window, label = label, detail = window_detail(w), window = w})
		}
	}
	// The find bar is listed with the windows too.
	append(&out, Palette_Entry{kind = .Window, label = "Find / Replace", detail = "window", window = .Text, action = .Find})
	for u in Utility {
		append(&out, Palette_Entry{kind = .Utility, label = utility_label(ed, u), detail = "utility", utility = u})
	}
	for p in Theme_Preset {
		label := fmt.tprintf("Color Theme: %s", preset_name(p))
		append(&out, Palette_Entry{kind = .Preset, label = label, detail = "current" if p == ed.theme_editor.base else "theme", preset = p})
	}
	return out[:]
}

// fuzzy_score matches `query` as a case-insensitive subsequence of
// `label`. Word starts and runs of consecutive letters score higher.
fuzzy_score :: proc(label, query: string) -> (m: Palette_Match, ok: bool) {
	if len(query) == 0 {
		return m, true
	}
	lower :: proc(c: u8) -> u8 {return c + 32 if c >= 'A' && c <= 'Z' else c}
	qi := 0
	prev_hit := -2
	for i in 0 ..< len(label) {
		if qi >= len(query) {
			break
		}
		if lower(label[i]) != lower(query[qi]) {
			continue
		}
		m.score += 1
		word_start := i == 0 || label[i - 1] == ' ' || label[i - 1] == ':' || label[i - 1] == '_'
		if word_start {
			m.score += 8
		}
		if prev_hit == i - 1 {
			m.score += 5
		}
		if m.n_pos < len(m.positions) {
			m.positions[m.n_pos] = u8(min(i, 255))
			m.n_pos += 1
		}
		prev_hit = i
		qi += 1
	}
	if qi < len(query) {
		return {}, false
	}
	m.score -= len(label) / 8 // prefer shorter labels on ties
	return m, true
}

// editor_palette_matches filters and orders the entries for the current
// query (empty query: recently used commands first, then alphabetical).
editor_palette_matches :: proc(ed: ^Editor) -> (entries: []Palette_Entry, matches: []Palette_Match) {
	entries = editor_palette_entries(ed)
	q := strings.trim_space(strings.to_string(ed.palette.query))
	out := make([dynamic]Palette_Match, context.temp_allocator)
	for e, i in entries {
		if m, ok := fuzzy_score(e.label, q); ok {
			m.entry = i
			if len(q) == 0 {
				// MRU rank, then alphabetical.
				// Windows come right after the recently used commands.
				m.score = 500 if e.kind == .Window else 0
				for a, r in ed.palette.mru {
					if e.kind == .Command && e.action == a {
						m.score = 1000 - r
					}
				}
			}
			append(&out, m)
		}
	}
	Sort_Ctx :: struct {
		entries: []Palette_Entry,
	}
	ctx := Sort_Ctx{entries}
	context.user_ptr = &ctx
	slice.sort_by(out[:], proc(a, b: Palette_Match) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		c := (^Sort_Ctx)(context.user_ptr)
		return c.entries[a.entry].label < c.entries[b.entry].label
	})
	return entries, out[:]
}

editor_open_palette :: proc(ed: ^Editor) {
	p := &ed.palette
	p.open = true
	strings.builder_reset(&p.query)
	p.selected = 0
	p.scroll = 0
	editor_close_completion(ed)
	editor_close_context_menu(ed)
	editor_hide_hover(ed)
}

editor_close_palette :: proc(ed: ^Editor) {
	ed.palette.open = false
}

editor_palette_text_input :: proc(ed: ^Editor, text: string) {
	strings.write_string(&ed.palette.query, text)
	ed.palette.selected = 0
	ed.palette.scroll = 0
}

// editor_palette_run runs match `row` (in display order) and closes.
editor_palette_run :: proc(ed: ^Editor, row: int) {
	entries, matches := editor_palette_matches(ed)
	editor_close_palette(ed)
	if row < 0 || row >= len(matches) {
		return
	}
	e := entries[matches[row].entry]
	switch e.kind {
	case .Command:
		// Remember it for the empty-query ordering.
		p := &ed.palette
		for a, i in p.mru {
			if a == e.action {
				ordered_remove(&p.mru, i)
				break
			}
		}
		inject_at(&p.mru, 0, e.action)
		if len(p.mru) > PALETTE_MRU {
			resize(&p.mru, PALETTE_MRU)
		}
		if e.action == .Save {
			editor_save(ed)
		} else {
			editor_run_action(ed, e.action)
		}
	case .Window:
		editor_show_window(ed, e.window)
		if e.action != .None {
			editor_run_action(ed, e.action)
		}
	case .Utility:
		editor_run_utility(ed, e.utility)
	case .Preset:
		editor_apply_preset(ed, e.preset)
	}
}

// editor_palette_handle_key: navigation/run/close while open; every key
// is consumed so nothing leaks into the document.
editor_palette_handle_key :: proc(ed: ^Editor, chord: km.Chord) -> bool {
	p := &ed.palette
	_, matches := editor_palette_matches(ed)
	n := len(matches)
	#partial switch chord.key {
	case .Escape:
		editor_close_palette(ed)
	case .Enter:
		editor_palette_run(ed, p.selected)
	case .Up:
		if n > 0 {p.selected = (p.selected - 1 + n) % n}
	case .Down:
		if n > 0 {p.selected = (p.selected + 1) % n}
	case .PageUp:
		p.selected = max(0, p.selected - editor_palette_rows(ed))
	case .PageDown:
		p.selected = clamp(p.selected + editor_palette_rows(ed), 0, max(0, n - 1))
	case .Backspace:
		s := strings.to_string(p.query)
		if len(s) > 0 {
			k := len(s) - 1
			for k > 0 && s[k] & 0xC0 == 0x80 {
				k -= 1
			}
			resize(&p.query.buf, k)
		}
		p.selected = 0
	case:
		if chord.key == .P && (.Super in chord.mods || .Ctrl in chord.mods) {
			editor_close_palette(ed) // the palette shortcut toggles
		}
	}
	p.scroll = overlay_scroll_reveal(p.scroll, p.selected, n, editor_palette_rows(ed))
	return true
}

// editor_palette_rows is how many results the palette shows (up to PALETTE_ROWS, fewer in a
// short view: the rest scroll)
editor_palette_rows :: proc(ed: ^Editor) -> int {
	_, rows, ok := editor_palette_layout(ed)
	return max(rows, 1) if ok else PALETTE_ROWS
}

// editor_palette_layout: input row + result rows, centred near the top.
editor_palette_layout :: proc(ed: ^Editor) -> (rect: sdl.FRect, rows: int, ok: bool) {
	if !ed.palette.open {
		return
	}
	_, matches := editor_palette_matches(ed)
	// The results below the input row, as many as fit above the view's bottom (they scroll)
	top := ed.origin_y + 6
	bottom := ed.origin_y + f32(ed.visible_rows) * ed.char_h
	if ed.window != .Text {
		area := editor_area_rect(ed)
		bottom = area.y + area.h
	}
	rows = min(len(matches), PALETTE_ROWS)
	if rows > 0 {
		rows = overlay_rows_fit(ed, bottom - top, rows, ed.char_h + 2 * POPUP_PAD + 4)
	}
	area_w := editor_gutter_width(ed) + f32(ed.visible_cols) * ed.char_w
	// No wider than the editor (a narrow pane): labels are cut
	w := min(f32(PALETTE_COLS) * ed.char_w + 2 * POPUP_PAD, area_w)
	h := f32(rows + 1) * ed.char_h + 2 * POPUP_PAD + 4
	x := ed.origin_x + max(0, (area_w - w) / 2)
	return {x, ed.origin_y + 6, w, h}, rows, true
}

// editor_palette_row_at maps a window y to a result row (-1 = input row).
editor_palette_row_at :: proc(ed: ^Editor, y: f32) -> int {
	rect, _, _ := editor_palette_layout(ed)
	first := rect.y + POPUP_PAD + ed.char_h + 4
	if y < first {
		return -1
	}
	return ed.palette.scroll + int((y - first) / ed.char_h)
}

@(private)
render_palette :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	rect, rows, ok := editor_palette_layout(ed)
	if !ok || font == nil {
		return
	}
	p := &ed.palette
	draw_popup_box(renderer, rect, theme)
	x := rect.x + POPUP_PAD
	y := rect.y + POPUP_PAD
	// Input row.
	fill_rect(renderer, {x, y, rect.w - 2 * POPUP_PAD, ed.char_h}, theme.background)
	q := strings.to_string(p.query)
	if len(q) == 0 {
		draw_text(renderer, font, "Type a command or window name...", x + 4, y, theme.popup_text_dim, ed.char_h)
	} else {
		draw_text(renderer, font, q, x + 4, y, theme.popup_text, ed.char_h)
	}
	fill_rect(renderer, {x + 4 + f32(text_cols(q)) * ed.char_w, y + 3, 2, ed.char_h - 6}, theme.cursor)

	entries, matches := editor_palette_matches(ed)
	if len(matches) == 0 {
		return
	}
	first := y + ed.char_h + 4
	render_overlay_scrollbar(renderer, {rect.x, first, rect.w, f32(rows) * ed.char_h}, len(matches), rows, p.scroll, theme)
	for r in 0 ..< rows {
		i := p.scroll + r
		if i >= len(matches) {
			break
		}
		m := matches[i]
		e := entries[m.entry]
		ry := first + f32(r) * ed.char_h
		if i == p.selected || (ed.mouse.zone == .Palette && editor_palette_row_at(ed, ed.mouse.y) == i) {
			fill_rect(renderer, {rect.x + 1, ry, rect.w - 2, ed.char_h}, theme.popup_selected)
		}
		lx := x + 4
		// Label, with fuzzy-matched letters highlighted.
		hit := 0
		label_end := rect.x + rect.w - POPUP_PAD - f32(len(e.detail) > 0 ? text_cols(e.detail) + 2 : 1) * ed.char_w
		for b := 0; b < len(e.label) && lx + ed.char_w <= label_end; {
			_, size := utf8.decode_rune_in_string(e.label[b:])
			color := theme.popup_text
			if hit < m.n_pos && int(m.positions[hit]) == b {
				color = theme.popup_match
				hit += 1
			}
			draw_text(renderer, font, e.label[b:b + size], lx, ry, color, ed.char_h)
			lx += ed.char_w
			b += size
		}
		if len(e.detail) > 0 {
			dx := rect.x + rect.w - POPUP_PAD - f32(text_cols(e.detail) + 1) * ed.char_w
			draw_text(renderer, font, e.detail, dx, ry, theme.popup_text_dim, ed.char_h)
		}
	}
}
