// Find / replace and occurrence selection.
//
// - Find bar (Ctrl/Cmd+F; replace: Ctrl+H, or Cmd+Alt+F on macOS): a small
//   widget at the top right of the editor with a query field (and a
//   replace field), match count, and toggles for case sensitivity (Alt+C),
//   whole word (Alt+W) and regular expressions (Alt+R, `core:text/regex`,
//   `$0`-`$9` in replacements). While it has focus, typing edits the active
//   field; Enter / Shift+Enter (or F3 / Ctrl+G and Shift variants anywhere)
//   go to the next / previous match; in the replace field Enter replaces
//   the current match and Ctrl/Cmd+Alt+Enter replaces all (one undo step);
//   Tab switches fields; Escape closes. Every match in view is
//   highlighted, the current one more strongly.
// - Ctrl/Cmd+D: select the word at the caret, then add a cursor at each
//   next occurrence (whole-word when started from a bare caret, like
//   VSCode). Ctrl/Cmd+Shift+L: select all occurrences.
//
// The search itself (find_matches) is a pure function over the buffer.
package code_editor

import buf "../buffer"
import km "../keymap"
import "core:fmt"
import "core:strings"
import "core:text/regex"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

FIND_MAX_MATCHES :: 10_000
FIND_BAR_COLS :: 52

Find_Options :: struct {
	case_sensitive: bool,
	whole_word:     bool,
	regex:          bool,
}

Find_Match :: struct {
	start, end: buf.Position,
}

Find_Field :: enum {
	Query,
	Replace,
}

Find_State :: struct {
	open:         bool,
	focused:      bool,
	replace_mode: bool,
	field:        Find_Field,
	query:        strings.Builder,
	replacement:  strings.Builder,
	opts:         Find_Options,

	matches:      [dynamic]Find_Match,
	current:      int,  // index into matches, -1 = none
	regex_error:  bool, // the query isn't a valid regex
	// Inputs the match list was computed for.
	built_query:   string,
	built_opts:    Find_Options,
	built_version: int,
	// Caret position when the bar opened: incremental search starts here.
	origin:        buf.Position,
	last_replaced: int,

	// Ctrl/Cmd+D: whole-word matching applies when the first press picked
	// the word itself (this is the selection it made).
	occ_whole_word:   bool,
	occ_auto_sel:     Find_Match,
	occ_auto_version: int, // buffer version when it was made
}


@(private)
find_init :: proc(f: ^Find_State) {
	f.query = strings.builder_make()
	f.replacement = strings.builder_make()
	f.matches = make([dynamic]Find_Match)
	f.current = -1
	f.built_version = -1
}

@(private)
find_destroy :: proc(f: ^Find_State) {
	strings.builder_destroy(&f.query)
	strings.builder_destroy(&f.replacement)
	delete(f.matches)
	delete(f.built_query)
}

// --- the search -----------------------------------------------------------------

@(private)
word_boundary_ok :: proc(line: string, a, b: int) -> bool {
	return (a == 0 || !is_ident_byte(line[a - 1])) && (b >= len(line) || !is_ident_byte(line[b]))
}

// find_matches returns every match of `query` in the buffer (single-line
// matches; up to FIND_MAX_MATCHES). `bad_regex` reports an invalid
// pattern in regex mode.
find_matches :: proc(b: ^buf.Buffer, query: string, opts: Find_Options, allocator := context.allocator) -> (out: [dynamic]Find_Match, bad_regex: bool) {
	out = make([dynamic]Find_Match, allocator)
	if len(query) == 0 {
		return
	}
	if opts.regex {
		flags: regex.Flags = {.Unicode}
		if !opts.case_sensitive {
			flags += {.Case_Insensitive}
		}
		re, err := regex.create(query, flags)
		if err != nil {
			return out, true
		}
		defer regex.destroy(re)
		for ln in 0 ..< buf.buffer_line_count(b) {
			line := buf.buffer_line_str(b, ln)
			off := 0
			for off <= len(line) && len(out) < FIND_MAX_MATCHES {
				cap, ok := regex.match(re, line[off:], context.temp_allocator)
				if !ok || len(cap.pos) == 0 {
					break
				}
				s, e := off + cap.pos[0][0], off + cap.pos[0][1]
				if !opts.whole_word || word_boundary_ok(line, s, e) {
					append(&out, Find_Match{{ln, s}, {ln, e}})
				}
				off = e if e > s else e + 1 // empty matches still advance
			}
		}
		return
	}
	for ln in 0 ..< buf.buffer_line_count(b) {
		line := buf.buffer_line_str(b, ln)
		for i := 0; i + len(query) <= len(line) && len(out) < FIND_MAX_MATCHES; {
			cand := line[i:i + len(query)]
			hit := cand == query if opts.case_sensitive else strings.equal_fold(cand, query)
			if hit && (!opts.whole_word || word_boundary_ok(line, i, i + len(query))) {
				append(&out, Find_Match{{ln, i}, {ln, i + len(query)}})
				i += len(query)
			} else {
				i += 1
			}
		}
	}
	return
}

// editor_find_refresh recomputes the match list when the query, options
// or text changed. Returns true if it was recomputed.
editor_find_refresh :: proc(ed: ^Editor) -> bool {
	f := &ed.find
	q := strings.to_string(f.query)
	if q == f.built_query && f.opts == f.built_opts && ed.buf.version == f.built_version {
		return false
	}
	delete(f.matches)
	f.matches, f.regex_error = find_matches(&ed.buf, q, f.opts)
	delete(f.built_query)
	f.built_query = strings.clone(q)
	f.built_opts = f.opts
	f.built_version = ed.buf.version
	if f.current >= len(f.matches) {
		f.current = len(f.matches) - 1
	}
	return true
}

// --- opening / closing ----------------------------------------------------------

// editor_open_find opens (or focuses) the find bar, seeding the query
// from a single-line selection.
editor_open_find :: proc(ed: ^Editor, replace := false) {
	f := &ed.find
	c := editor_primary_cursor(ed)
	if start, end, ok := buf.selection_range(c^); ok && start.line == end.line {
		strings.builder_reset(&f.query)
		strings.write_string(&f.query, buf.buffer_line_str(&ed.buf, start.line)[start.col:end.col])
	}
	if !f.open {
		f.origin = c.pos
		if start, _, ok := buf.selection_range(c^); ok {
			f.origin = start
		}
	}
	f.open = true
	f.focused = true
	f.replace_mode = f.replace_mode || replace
	// Opening (find or replace) always focuses the query field, like VSCode.
	f.field = .Query
	editor_close_completion(ed)
	editor_find_jump_from_origin(ed)
}

editor_close_find :: proc(ed: ^Editor) {
	ed.find.open = false
	ed.find.focused = false
	ed.find.replace_mode = false
}

// editor_find_jump_from_origin selects the first match at/after the
// origin (incremental search while typing the query).
@(private)
editor_find_jump_from_origin :: proc(ed: ^Editor) {
	f := &ed.find
	editor_find_refresh(ed)
	f.current = -1
	for m, i in f.matches {
		if !buf.position_less(m.start, f.origin) {
			f.current = i
			break
		}
	}
	if f.current < 0 && len(f.matches) > 0 {
		f.current = 0
	}
	editor_find_select_current(ed)
}

@(private)
editor_find_select_current :: proc(ed: ^Editor) {
	f := &ed.find
	if f.current < 0 || f.current >= len(f.matches) {
		return
	}
	m := f.matches[f.current]
	resize(&ed.buf.cursors, 1)
	ed.buf.cursors[0] = {pos = m.end, sel = {anchor = m.start, active = m.start != m.end}}
	editor_ensure_cursor_visible(ed)
}

// editor_find_step goes to the next (+1) or previous (-1) match relative
// to the caret, wrapping around.
editor_find_step :: proc(ed: ^Editor, dir: int) {
	f := &ed.find
	if strings.builder_len(f.query) == 0 {
		// F3 with no query: search for the selection/word under the caret.
		editor_open_find(ed)
		f.focused = false
	}
	editor_find_refresh(ed)
	n := len(f.matches)
	if n == 0 {
		f.current = -1
		return
	}
	c := editor_primary_cursor(ed)
	start, end, has_sel := buf.selection_range(c^)
	if !has_sel {
		start, end = c.pos, c.pos
	}
	if dir > 0 {
		f.current = 0
		for m, i in f.matches {
			if !buf.position_less(m.start, end) && !(m.start == start && m.end == end && has_sel) {
				f.current = i
				break
			}
		}
	} else {
		f.current = n - 1
		#reverse for m, i in f.matches {
			if buf.position_less(m.start, start) {
				f.current = i
				break
			}
		}
	}
	editor_find_select_current(ed)
}

// --- replace --------------------------------------------------------------------

// expand_replacement substitutes $0-$9 from a regex match of `matched`.
@(private)
expand_replacement :: proc(ed: ^Editor, template: string, matched: string) -> string {
	if !ed.find.opts.regex || strings.index_byte(template, '$') < 0 {
		return template
	}
	flags: regex.Flags = {.Unicode}
	if !ed.find.opts.case_sensitive {
		flags += {.Case_Insensitive}
	}
	re, err := regex.create(strings.to_string(ed.find.query), flags)
	if err != nil {
		return template
	}
	defer regex.destroy(re)
	cap, ok := regex.match(re, matched, context.temp_allocator)
	if !ok {
		return template
	}
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(template); i += 1 {
		if template[i] == '$' && i + 1 < len(template) && template[i + 1] >= '0' && template[i + 1] <= '9' {
			g := int(template[i + 1] - '0')
			if g < len(cap.groups) {
				strings.write_string(&sb, cap.groups[g])
			}
			i += 1
			continue
		}
		strings.write_byte(&sb, template[i])
	}
	return strings.to_string(sb)
}

// editor_replace_current replaces the current match (if the selection is
// on it) and moves to the next one.
editor_replace_current :: proc(ed: ^Editor) {
	f := &ed.find
	editor_find_refresh(ed)
	if f.current < 0 || f.current >= len(f.matches) {
		editor_find_step(ed, 1)
		return
	}
	m := f.matches[f.current]
	c := editor_primary_cursor(ed)
	start, end, ok := buf.selection_range(c^)
	if !ok || start != m.start || end != m.end {
		// First press just selects the match, like VSCode.
		editor_find_select_current(ed)
		return
	}
	matched := buf.buffer_line_str(&ed.buf, m.start.line)[m.start.col:m.end.col]
	text := expand_replacement(ed, strings.to_string(f.replacement), matched)
	group := buf.buffer_next_group(&ed.buf)
	buf.buffer_delete_range(&ed.buf, m.start, m.end, group)
	after := buf.buffer_insert_text(&ed.buf, m.start, text, group)
	ed.buf.cursors[0] = {pos = after}
	f.last_replaced = 1
	editor_find_refresh(ed)
	editor_find_step(ed, 1)
}

// editor_replace_all replaces every match as one undo step and returns
// how many were replaced.
editor_replace_all :: proc(ed: ^Editor) -> int {
	f := &ed.find
	editor_find_refresh(ed)
	if len(f.matches) == 0 {
		return 0
	}
	template := strings.to_string(f.replacement)
	group := buf.buffer_next_group(&ed.buf)
	#reverse for m in f.matches {
		matched := buf.buffer_line_str(&ed.buf, m.start.line)[m.start.col:m.end.col]
		text := expand_replacement(ed, template, matched)
		buf.buffer_delete_range(&ed.buf, m.start, m.end, group)
		buf.buffer_insert_text(&ed.buf, m.start, text, group)
	}
	n := len(f.matches)
	resize(&ed.buf.cursors, 1)
	ed.buf.cursors[0] = {pos = editor_clamp_to_buffer(ed, f.matches[0].start.line, f.matches[0].start.col)}
	f.last_replaced = n
	editor_find_refresh(ed)
	f.current = -1
	return n
}

// --- occurrences (Ctrl/Cmd+D, Ctrl/Cmd+Shift+L) ---------------------------------

// editor_select_next_occurrence implements Ctrl/Cmd+D.
editor_select_next_occurrence :: proc(ed: ^Editor) {
	b := &ed.buf
	any_sel := false
	for c in b.cursors {
		if _, _, ok := buf.selection_range(c); ok {
			any_sel = true
		}
	}
	f := &ed.find
	if !any_sel {
		c := &b.cursors[len(b.cursors) - 1]
		buf.cursor_select_word(b, c)
		if s, e, ok := buf.selection_range(c^); ok {
			f.occ_whole_word = true
			f.occ_auto_sel = {s, e}
			f.occ_auto_version = b.version
		}
		return
	}
	last := b.cursors[len(b.cursors) - 1]
	ls, le, ok := buf.selection_range(last)
	if !ok || ls.line != le.line {
		return
	}
	if len(b.cursors) == 1 && (f.occ_auto_sel != (Find_Match{ls, le}) || f.occ_auto_version != b.version) {
		// The user made this selection themselves: plain substring search.
		f.occ_whole_word = false
	}
	needle := buf.buffer_line_str(b, ls.line)[ls.col:le.col]
	matches, _ := find_matches(b, needle, {case_sensitive = true, whole_word = f.occ_whole_word}, context.temp_allocator)
	if len(matches) == 0 {
		return
	}
	// First match after the last cursor's selection, wrapping; skip ones
	// a cursor already covers.
	start_idx := 0
	for m, i in matches {
		if !buf.position_less(m.start, le) {
			start_idx = i
			break
		}
		start_idx = (i + 1) % len(matches)
	}
	for k in 0 ..< len(matches) {
		m := matches[(start_idx + k) % len(matches)]
		taken := false
		for c in b.cursors {
			cs, ce, has := buf.selection_range(c)
			if has && cs == m.start && ce == m.end {
				taken = true
				break
			}
		}
		if !taken {
			append(&b.cursors, buf.Cursor{pos = m.end, sel = {anchor = m.start, active = true}})
			editor_reveal(ed, m.end)
			return
		}
	}
}

// editor_select_all_occurrences implements Ctrl/Cmd+Shift+L.
editor_select_all_occurrences :: proc(ed: ^Editor) {
	b := &ed.buf
	c := editor_primary_cursor(ed)
	whole := false
	if _, _, ok := buf.selection_range(c^); !ok {
		buf.cursor_select_word(b, c)
		whole = true
	}
	s, e, ok := buf.selection_range(c^)
	if !ok || s.line != e.line {
		return
	}
	needle := buf.buffer_line_str(b, s.line)[s.col:e.col]
	matches, _ := find_matches(b, needle, {case_sensitive = true, whole_word = whole}, context.temp_allocator)
	if len(matches) == 0 {
		return
	}
	clear(&b.cursors)
	for m in matches {
		append(&b.cursors, buf.Cursor{pos = m.end, sel = {anchor = m.start, active = true}})
	}
}

// editor_reveal scrolls so `pos` is visible without moving the primary
// caret.
editor_reveal :: proc(ed: ^Editor, pos: buf.Position) {
	rows := max(1, editor_text_rows(ed))
	if pos.line < ed.scroll_line {
		ed.scroll_line = pos.line
	} else if pos.line >= ed.scroll_line + rows {
		ed.scroll_line = pos.line - rows + 1
	}
	editor_clamp_scroll(ed)
}

// --- input while the bar has focus --------------------------------------------------

@(private)
find_active_builder :: proc(f: ^Find_State) -> ^strings.Builder {
	return &f.replacement if f.field == .Replace else &f.query
}

// editor_find_text_input appends typed text to the focused field.
editor_find_text_input :: proc(ed: ^Editor, text: string) {
	f := &ed.find
	strings.write_string(find_active_builder(f), text)
	if f.field == .Query {
		editor_find_jump_from_origin(ed)
	}
}

// editor_find_handle_key handles keys while the bar is focused. Returns
// true if consumed; unconsumed chords with modifiers fall through to the
// normal keymap (Save, Undo, ...), plain keys are swallowed so they never
// edit the document behind the bar.
editor_find_handle_key :: proc(ed: ^Editor, chord: km.Chord) -> bool {
	f := &ed.find
	mods := chord.mods
	switch {
	case chord.key == .Escape:
		editor_close_find(ed)
		return true
	case chord.key == .Enter && f.field == .Replace && .Alt in mods && (.Ctrl in mods || .Super in mods):
		editor_replace_all(ed)
		return true
	case chord.key == .Enter && f.field == .Replace && mods == {}:
		editor_replace_current(ed)
		return true
	case chord.key == .Enter && mods == {}:
		editor_find_step(ed, 1)
		return true
	case chord.key == .Enter && mods == {.Shift}:
		editor_find_step(ed, -1)
		return true
	case chord.key == .Tab && mods == {} && f.replace_mode:
		f.field = .Replace if f.field == .Query else .Query
		return true
	case chord.key == .Backspace && mods == {}:
		sb := find_active_builder(f)
		s := strings.to_string(sb^)
		if len(s) > 0 {
			// Drop one whole UTF-8 character.
			n := len(s) - 1
			for n > 0 && s[n] & 0xC0 == 0x80 {
				n -= 1
			}
			resize(&sb.buf, n)
		}
		if f.field == .Query {
			editor_find_jump_from_origin(ed)
		}
		return true
	case .Alt in mods && mods - {.Alt} == {} && (chord.key == .C || chord.key == .W || chord.key == .R):
		#partial switch chord.key {
		case .C: f.opts.case_sensitive = !f.opts.case_sensitive
		case .W: f.opts.whole_word = !f.opts.whole_word
		case .R: f.opts.regex = !f.opts.regex
		}
		editor_find_jump_from_origin(ed)
		return true
	}
	return mods == {} || mods == {.Shift}
}

// --- layout & rendering -----------------------------------------------------------------

Find_Bar_Layout :: struct {
	rect:      sdl.FRect,
	query:     sdl.FRect, // query field row
	replace:   sdl.FRect, // replace field row (zero if hidden)
	opt_case:  sdl.FRect,
	opt_word:  sdl.FRect,
	opt_regex: sdl.FRect,
}

// editor_find_layout positions the bar at the top right of the text area.
editor_find_layout :: proc(ed: ^Editor) -> (l: Find_Bar_Layout, ok: bool) {
	if !ed.find.open {
		return
	}
	rows := 2 if ed.find.replace_mode else 1
	w := f32(FIND_BAR_COLS) * ed.char_w + 2 * POPUP_PAD
	h := f32(rows) * ed.char_h + 2 * POPUP_PAD
	right := ed.origin_x + editor_gutter_width(ed) + f32(ed.visible_cols) * ed.char_w
	x := max(ed.origin_x + editor_gutter_width(ed), right - w - 12)
	y := ed.origin_y + 2
	l.rect = {x, y, w, h}
	l.query = {x, y + POPUP_PAD, w, ed.char_h}
	if ed.find.replace_mode {
		l.replace = {x, y + POPUP_PAD + ed.char_h, w, ed.char_h}
	}
	// Toggles sit at the right end of the query row: "Aa W .*"
	ox := x + w - POPUP_PAD - 9 * ed.char_w
	l.opt_case = {ox, l.query.y, 2 * ed.char_w, ed.char_h}
	l.opt_word = {ox + 3 * ed.char_w, l.query.y, ed.char_w, ed.char_h}
	l.opt_regex = {ox + 5 * ed.char_w, l.query.y, 2 * ed.char_w, ed.char_h}
	return l, true
}

// editor_find_status is the "N of M" / "No results" text.
editor_find_status :: proc(ed: ^Editor) -> string {
	f := &ed.find
	switch {
	case f.regex_error: return "bad regex"
	case strings.builder_len(f.query) == 0: return ""
	case len(f.matches) == 0: return "No results"
	case f.current < 0: return fmt.tprintf("? of %d", len(f.matches))
	}
	return fmt.tprintf("%d of %d", f.current + 1, len(f.matches))
}

// render_find_highlights tints every match on `line` (current one stronger).
@(private)
render_find_highlights :: proc(ed: ^Editor, renderer: ^sdl.Renderer, line: int, x, y: f32, theme: Theme) {
	f := &ed.find
	if !f.open || len(f.matches) == 0 {
		return
	}
	text := buf.buffer_line_str(&ed.buf, line)
	for m, i in f.matches {
		if m.start.line < line {
			continue
		}
		if m.start.line > line {
			break
		}
		va := visual_col_of(text, m.start.col, ed.tab_width)
		vb := visual_col_of(text, m.end.col, ed.tab_width)
		color := theme.find_current if i == f.current else theme.find_match
		fill_rect(renderer, {x + f32(va - ed.scroll_col) * ed.char_w, y, f32(max(vb - va, 1)) * ed.char_w, ed.char_h}, color)
	}
}

@(private)
render_find_bar :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	l, ok := editor_find_layout(ed)
	if !ok || font == nil {
		return
	}
	f := &ed.find
	draw_popup_box(renderer, l.rect, theme)
	draw_field :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme, row: sdl.FRect, label, value: string, active: bool) {
		x := row.x + POPUP_PAD
		draw_text(renderer, font, label, x, row.y, theme.popup_text_dim, ed.char_h)
		x += f32(text_cols(label)) * ed.char_w
		shown := truncate_cols(value, 22)
		draw_text(renderer, font, shown, x, row.y, theme.popup_text, ed.char_h)
		if active {
			cx := x + f32(text_cols(shown)) * ed.char_w
			fill_rect(renderer, {cx, row.y + 2, 2, ed.char_h - 4}, theme.cursor)
		}
	}
	draw_field(ed, renderer, font, theme, l.query, "Find:    ", strings.to_string(f.query), f.focused && f.field == .Query)
	status := editor_find_status(ed)
	status_color := theme.diag_error if f.regex_error || status == "No results" else theme.popup_text_dim
	draw_text(renderer, font, status, l.opt_case.x - f32(text_cols(status) + 2) * ed.char_w, l.query.y, status_color, ed.char_h)
	toggle :: proc(renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme, r: sdl.FRect, label: string, on: bool) {
		if on {
			fill_rect(renderer, r, theme.popup_selected)
		}
		draw_text(renderer, font, label, r.x, r.y, theme.popup_match if on else theme.popup_text_dim, r.h)
	}
	toggle(renderer, font, theme, l.opt_case, "Aa", f.opts.case_sensitive)
	toggle(renderer, font, theme, l.opt_word, "W", f.opts.whole_word)
	toggle(renderer, font, theme, l.opt_regex, ".*", f.opts.regex)
	if f.replace_mode {
		draw_field(ed, renderer, font, theme, l.replace, "Replace: ", strings.to_string(f.replacement), f.focused && f.field == .Replace)
	}
}

// editor_find_click handles a click inside the bar (focus a field or flip
// a toggle).
@(private)
editor_find_click :: proc(ed: ^Editor, x, y: f32) {
	l, _ := editor_find_layout(ed)
	f := &ed.find
	f.focused = true
	switch {
	case in_rect(l.opt_case, x, y): f.opts.case_sensitive = !f.opts.case_sensitive
	case in_rect(l.opt_word, x, y): f.opts.whole_word = !f.opts.whole_word
	case in_rect(l.opt_regex, x, y): f.opts.regex = !f.opts.regex
	case f.replace_mode && in_rect(l.replace, x, y): f.field = .Replace
	case: f.field = .Query
	}
	editor_find_jump_from_origin(ed)
}
