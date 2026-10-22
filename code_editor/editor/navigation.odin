// Code navigation over LSP: Go to Definition (F12 / Cmd-or-Ctrl+click),
// Peek Definition (Alt+F12: an inline window under the caret showing the
// definition's source), Find All References (Shift+F12: a panel listing
// every use, F4 / Shift+F4 step through them), and Back / Forward through
// the places you jumped from (Ctrl+- / Ctrl+Shift+- on macOS, Alt+Left /
// Alt+Right elsewhere — VSCode's keys). Targets in other files go through
// the host's open-file request (editor_take_open_request).
package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

PEEK_CONTEXT_BEFORE :: 3
PEEK_LINES :: 12
STATUS_DURATION :: 2500 * time.Millisecond

Nav_Purpose :: enum {
	None,
	Goto,
	Peek,
	References,
}

// Nav_Entry is a history position in LSP coordinates (UTF-16 column) so it
// can be handed to the host for other files unchanged.
Nav_Entry :: struct {
	key:       string, // owned
	line, character: int,
}

Peek_View :: struct {
	open:        bool,
	key:         string,            // owned: target document
	target_line: int,
	target_char: int,
	first_line:  int,               // line number of lines[0]
	lines:       [dynamic]string,   // owned copies
	// The first of `lines` shown, when the view is too short for them all
	scroll:      int,
}

Ref_Item :: struct {
	key:       string, // owned
	line:      int,
	character: int,    // UTF-16
	preview:   string, // owned, trimmed line text
}

Refs_Panel :: struct {
	open:     bool,
	items:    [dynamic]Ref_Item,
	selected: int,
	scroll:   int,
	symbol:   string, // owned
}

Navigation :: struct {
	purpose:  Nav_Purpose,
	waiting:  bool,
	seen_seq: int,
	history:  [dynamic]Nav_Entry,
	index:    int, // len(history) = "at the present position"
	peek:     Peek_View,
	refs:     Refs_Panel,
	status:       string, // owned transient message (header)
	status_since: time.Tick,
}

@(private)
navigation_destroy :: proc(n: ^Navigation) {
	for e in n.history {
		delete(e.key)
	}
	delete(n.history)
	peek_clear(&n.peek)
	delete(n.peek.lines)
	refs_clear(&n.refs)
	delete(n.refs.items)
	delete(n.status)
}

@(private)
peek_clear :: proc(p: ^Peek_View) {
	for l in p.lines {
		delete(l)
	}
	clear(&p.lines)
	delete(p.key)
	p.key = ""
	p.open = false
	p.scroll = 0
}

@(private)
refs_clear :: proc(r: ^Refs_Panel) {
	for it in r.items {
		delete(it.key)
		delete(it.preview)
	}
	clear(&r.items)
	delete(r.symbol)
	r.symbol = ""
	r.selected = 0
	r.scroll = 0
}

// editor_set_status shows a short message in the header for a moment.
editor_set_status :: proc(ed: ^Editor, msg: string) {
	delete(ed.nav.status)
	ed.nav.status = strings.clone(msg)
	ed.nav.status_since = time.tick_now()
}

editor_status_text :: proc(ed: ^Editor) -> string {
	if len(ed.nav.status) == 0 || time.tick_since(ed.nav.status_since) > STATUS_DURATION {
		return ""
	}
	return ed.nav.status
}

// --- requests ----------------------------------------------------------------------

// editor_request_navigation asks the server about the symbol at the caret.
editor_request_navigation :: proc(ed: ^Editor, purpose: Nav_Purpose) {
	if !editor_lsp_ready(ed) {
		editor_set_status(ed, "No language server")
		return
	}
	editor_sync_lsp(ed)
	editor_close_completion(ed)
	c := editor_primary_cursor(ed)
	n := &ed.nav
	n.purpose = purpose
	n.waiting = true
	switch purpose {
	case .None:
	case .Goto, .Peek:
		lspc.client_request_definition(&ed.lsp, ed.document_uri, c.pos.line, editor_lsp_col(ed, c.pos))
	case .References:
		delete(n.refs.symbol)
		start := editor_word_start_before(ed, c.pos)
		line := buf.buffer_line_str(&ed.buf, c.pos.line)
		end := c.pos.col
		for end < len(line) && is_ident_byte(line[end]) {
			end += 1
		}
		n.refs.symbol = strings.clone(line[start:end])
		lspc.client_request_references(&ed.lsp, ed.document_uri, c.pos.line, editor_lsp_col(ed, c.pos))
	}
	n.seen_seq = ed.lsp.location_seq
}

// editor_update_navigation handles the server's answer. Called from
// editor_update.
editor_update_navigation :: proc(ed: ^Editor) {
	n := &ed.nav
	if !n.waiting || !ed.lsp_enabled || ed.lsp.location_seq == n.seen_seq {
		return
	}
	n.waiting = false
	n.seen_seq = ed.lsp.location_seq
	locs := ed.lsp.last_locations[:]
	if len(locs) == 0 {
		editor_set_status(ed, "No references found" if n.purpose == .References else "No definition found")
		return
	}
	switch n.purpose {
	case .None:
	case .Goto:
		l := locs[0]
		editor_jump_to(ed, l.key, l.range.start.line, l.range.start.character, record = true)
	case .Peek:
		editor_open_peek(ed, locs[0])
	case .References:
		editor_open_references(ed, locs)
	}
}

// --- history & jumping -----------------------------------------------------------

@(private)
current_entry :: proc(ed: ^Editor) -> Nav_Entry {
	p := editor_primary_cursor(ed).pos
	return {strings.clone(ed.document_key), p.line, editor_lsp_col(ed, p)}
}

// editor_jump_to moves to (line, UTF-16 character) in document `key`; for
// another file the host is asked to open it. With `record`, the current
// position is pushed onto the back/forward history first.
editor_jump_to :: proc(ed: ^Editor, key: string, line, character: int, record := false) {
	n := &ed.nav
	if record {
		for e in n.history[n.index:] {
			delete(e.key)
		}
		resize(&n.history, n.index)
		append(&n.history, current_entry(ed))
		n.index = len(n.history)
	}
	peek_clear(&n.peek)
	if key == ed.document_key {
		editor_goto_lsp_position(ed, line, character)
		// Put the target a little below the top rather than at the edge.
		rows := editor_text_rows(ed)
		if line < ed.scroll_line || line >= ed.scroll_line + rows {
			ed.scroll_line = max(0, line - rows / 3)
			editor_clamp_scroll(ed)
		}
		return
	}
	pr := &ed.problems
	delete(pr.open_request_path)
	pr.open_request = true
	pr.open_request_path = strings.clone(key)
	pr.open_request_pos = {line, character}
}

// editor_navigate_back / editor_navigate_forward walk the jump history.
editor_navigate_back :: proc(ed: ^Editor) {
	n := &ed.nav
	if n.index == len(n.history) {
		append(&n.history, current_entry(ed))
	}
	if n.index == 0 {
		return
	}
	n.index -= 1
	e := n.history[n.index]
	editor_jump_to(ed, e.key, e.line, e.character)
}

editor_navigate_forward :: proc(ed: ^Editor) {
	n := &ed.nav
	if n.index + 1 >= len(n.history) {
		return
	}
	n.index += 1
	e := n.history[n.index]
	editor_jump_to(ed, e.key, e.line, e.character)
}

// --- source lines for previews -------------------------------------------------

// document_lines returns the text lines of `key`: the buffer for the open
// document, otherwise the file on disk (temp-allocated).
@(private)
document_lines :: proc(ed: ^Editor, key: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if key == ed.document_key {
		for ln in 0 ..< buf.buffer_line_count(&ed.buf) {
			append(&out, buf.buffer_line_str(&ed.buf, ln))
		}
		return out[:]
	}
	data, err := os.read_entire_file(key, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		append(&out, strings.trim_right(line, "\r"))
	}
	return out[:]
}

// --- peek ------------------------------------------------------------------------------

@(private)
editor_open_peek :: proc(ed: ^Editor, l: lspc.Location) {
	p := &ed.nav.peek
	peek_clear(p)
	lines := document_lines(ed, l.key)
	if len(lines) == 0 {
		editor_set_status(ed, "Definition source unavailable")
		return
	}
	p.open = true
	p.key = strings.clone(l.key)
	p.target_line = l.range.start.line
	p.target_char = l.range.start.character
	p.first_line = clamp(p.target_line - PEEK_CONTEXT_BEFORE, 0, len(lines) - 1)
	last := min(len(lines), p.first_line + PEEK_LINES)
	for i in p.first_line ..< last {
		append(&p.lines, strings.clone(lines[i]))
	}
}

editor_close_peek :: proc(ed: ^Editor) {
	peek_clear(&ed.nav.peek)
}

// editor_peek_layout: under the caret line, full text width.
editor_peek_layout :: proc(ed: ^Editor) -> (rect: sdl.FRect, ok: bool) {
	p := &ed.nav.peek
	if !p.open {
		return
	}
	_, cy := editor_cursor_screen_pos(ed)
	x := ed.origin_x + editor_gutter_width(ed)
	w := f32(ed.visible_cols) * ed.char_w
	// The title row and the lines, under the caret line, else above it; in a short view as many
	// lines as fit (they scroll)
	y, h, _ := place_popup(ed, len(p.lines) + 1, cy, cy + ed.char_h, prefer_above = false)
	return {x, y, w, h}, true
}

@(private)
render_peek :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	rect, ok := editor_peek_layout(ed)
	if !ok || font == nil {
		return
	}
	p := &ed.nav.peek
	draw_popup_box(renderer, rect, theme)
	fill_rect(renderer, {rect.x, rect.y, rect.w, 2}, theme.text_type) // accent bar
	x := rect.x + POPUP_PAD
	y := rect.y + POPUP_PAD
	title := fmt.tprintf("%s:%d", filepath.base(p.key), p.target_line + 1)
	draw_text(renderer, font, title, x, y, theme.popup_text, ed.char_h)
	hint := "Enter: open   Esc: close"
	draw_text(renderer, font, hint, rect.x + rect.w - POPUP_PAD - f32(text_cols(hint) + 1) * ed.char_w, y, theme.popup_text_dim, ed.char_h)
	num_w := f32(5) * ed.char_w
	rows := max(popup_rows_of(ed, rect) - 1, 0)
	scroll := overlay_scroll_clamp(p.scroll, len(p.lines), rows)
	render_overlay_scrollbar(renderer, {rect.x, y + ed.char_h, rect.w, f32(rows) * ed.char_h}, len(p.lines), rows, scroll, theme)
	for line, row in p.lines[scroll:min(len(p.lines), scroll + rows)] {
		i := scroll + row
		ly := y + f32(row + 1) * ed.char_h
		ln := p.first_line + i
		if ln == p.target_line {
			fill_rect(renderer, {rect.x + 1, ly, rect.w - 2, ed.char_h}, theme.popup_selected)
		}
		num := fmt.tprint(ln + 1)
		draw_text(renderer, font, num, x + num_w - f32(len(num) + 1) * ed.char_w, ly, theme.gutter_text, ed.char_h)
		draw_code_line(ed, renderer, font, theme, expand_tabs(line, ed.tab_width), x + num_w, ly)
	}
}

// expand_tabs replaces tabs with spaces to the next tab stop (temp).
expand_tabs :: proc(s: string, tab_width: int) -> string {
	if strings.index_byte(s, '\t') < 0 {
		return s
	}
	sb := strings.builder_make(context.temp_allocator)
	col := 0
	for r in s {
		if r == '\t' {
			n := tab_width - col % tab_width
			for _ in 0 ..< n {
				strings.write_byte(&sb, ' ')
			}
			col += n
		} else {
			strings.write_rune(&sb, r)
			col += 1
		}
	}
	return strings.to_string(sb)
}

// --- references ---------------------------------------------------------------------

@(private)
editor_open_references :: proc(ed: ^Editor, locs: []lspc.Location) {
	r := &ed.nav.refs
	symbol := strings.clone(r.symbol, context.temp_allocator)
	refs_clear(r)
	r.symbol = strings.clone(symbol)
	cache := make(map[string][]string, context.temp_allocator)
	for l in locs {
		lines, have := cache[l.key]
		if !have {
			lines = document_lines(ed, l.key)
			cache[l.key] = lines
		}
		preview := ""
		if l.range.start.line < len(lines) {
			preview = strings.trim_space(lines[l.range.start.line])
		}
		append(&r.items, Ref_Item{strings.clone(l.key), l.range.start.line, l.range.start.character, strings.clone(preview)})
	}
	// Current document first, then by path and line.
	Ctx :: struct {
		cur: string,
	}
	ctx := Ctx{ed.document_key}
	context.user_ptr = &ctx
	slice.sort_by(r.items[:], proc(a, b: Ref_Item) -> bool {
		cur := (^Ctx)(context.user_ptr).cur
		if (a.key == cur) != (b.key == cur) {
			return a.key == cur
		}
		if a.key != b.key {
			return a.key < b.key
		}
		return a.line < b.line || (a.line == b.line && a.character < b.character)
	})
	r.open = true
	ed.problems.open = false
	editor_ensure_cursor_visible(ed)
}

editor_close_references :: proc(ed: ^Editor) {
	ed.nav.refs.open = false
}

// editor_open_reference jumps to reference `index` (history recorded).
editor_open_reference :: proc(ed: ^Editor, index: int) {
	r := &ed.nav.refs
	if index < 0 || index >= len(r.items) {
		return
	}
	r.selected = index
	it := r.items[index]
	editor_jump_to(ed, it.key, it.line, it.character, record = true)
}

// editor_step_reference moves to the next (+1) / previous (-1) reference.
editor_step_reference :: proc(ed: ^Editor, dir: int) {
	r := &ed.nav.refs
	n := len(r.items)
	if n == 0 {
		return
	}
	editor_open_reference(ed, (r.selected + dir + n) % n)
	refs_keep_visible(ed)
}

@(private)
refs_keep_visible :: proc(ed: ^Editor) {
	r := &ed.nav.refs
	r.scroll = overlay_scroll_reveal(r.scroll, r.selected, len(r.items), editor_panel_entries(ed))
}

@(private)
render_references_panel :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme, origin_x, origin_y: f32) {
	r := &ed.nav.refs
	if !r.open || font == nil {
		return
	}
	top := origin_y + f32(editor_text_rows(ed)) * ed.char_h
	width := editor_gutter_width(ed) + f32(ed.visible_cols) * ed.char_w
	fill_rect(renderer, {origin_x, top, width, f32(editor_panel_rows(ed)) * ed.char_h}, theme.popup_bg)
	fill_rect(renderer, {origin_x, top, width, 1}, theme.popup_border)
	entries := editor_panel_entries(ed)
	render_overlay_scrollbar(renderer, {origin_x, top + ed.char_h, width, f32(entries) * ed.char_h}, len(r.items), entries, r.scroll, theme)
	header := fmt.tprintf("REFERENCES  %d result%s for '%s'   (F4 / Shift+F4 to step, Esc to close)", len(r.items), "" if len(r.items) == 1 else "s", r.symbol)
	draw_text(renderer, font, header, origin_x + POPUP_PAD, top, theme.popup_text_dim, ed.char_h)
	last := min(len(r.items), r.scroll + entries)
	for i in r.scroll ..< last {
		it := r.items[i]
		y := top + f32(i - r.scroll + 1) * ed.char_h
		hovered := ed.mouse.zone == .References && problems_row_at(ed, ed.mouse.y) == i
		if i == r.selected || hovered {
			fill_rect(renderer, {origin_x, y, width, ed.char_h}, theme.popup_selected)
		}
		loc := fmt.tprintf("%s:%d:%d", filepath.base(it.key), it.line + 1, it.character + 1)
		x := origin_x + 2 * POPUP_PAD
		draw_text(renderer, font, loc, x, y, theme.text_type, ed.char_h)
		x += f32(max(text_cols(loc) + 2, 22)) * ed.char_w
		room := int((origin_x + width - x) / ed.char_w) - 1
		draw_code_line(ed, renderer, font, theme, truncate_cols(it.preview, room), x, y)
	}
}
