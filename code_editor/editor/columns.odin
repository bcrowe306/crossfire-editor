// Visual columns: the mapping between a line's byte offsets (what the
// buffer stores) and on-screen cells (what rendering, mouse hit-testing
// and horizontal scrolling deal in). '\t' advances to the next multiple
// of the tab width; other runes take rune_cells cells — 2 for East Asian
// wide characters and emoji, 0 for combining marks, 1 otherwise. Pure
// functions — unit tested in mouse_test.odin.
package code_editor

import buf "../buffer"
import "core:unicode"
import "core:unicode/utf8"

// rune_cells is the number of monospace cells a (non-tab) rune occupies.
rune_cells :: proc(r: rune) -> int {
	if r < 0x80 {
		return 1 // fast path; control chars are drawn as one cell too
	}
	if unicode.is_nonspacing_mark(r) || unicode.is_enclosing_mark(r) {
		return 0 // combining marks draw over the previous character
	}
	return unicode.normalized_east_asian_width(r)
}

DEFAULT_TAB_WIDTH :: 4

// visual_col_of returns the cell column at which byte offset `byte_col`
// of `line` is drawn.
visual_col_of :: proc(line: string, byte_col: int, tab_width: int) -> int {
	tw := max(tab_width, 1)
	vcol := 0
	limit := min(byte_col, len(line))
	for i := 0; i < limit; {
		r, size := utf8.decode_rune_in_string(line[i:])
		if r == '\t' {
			vcol += tw - vcol % tw
		} else {
			vcol += rune_cells(r)
		}
		i += size
	}
	return vcol
}

// line_visual_width is the number of cells `line` occupies.
line_visual_width :: proc(line: string, tab_width: int) -> int {
	return visual_col_of(line, len(line), tab_width)
}

// byte_col_at_visual maps a (possibly fractional) cell position back to
// the nearest rune boundary — the caret position a click at that cell
// should produce. Positions past the end of the line clamp to its end.
byte_col_at_visual :: proc(line: string, vcol: f32, tab_width: int) -> int {
	tw := max(tab_width, 1)
	if vcol <= 0 {
		return 0
	}
	cell := 0
	for i := 0; i < len(line); {
		r, size := utf8.decode_rune_in_string(line[i:])
		w := tw - cell % tw if r == '\t' else rune_cells(r)
		// Inside this character: snap to whichever edge is closer.
		if w > 0 && vcol < f32(cell + w) {
			return i if vcol - f32(cell) < f32(w) / 2 else i + size
		}
		cell += w
		i += size
	}
	return len(line)
}

// editor_visual_col is visual_col_of for a buffer position.
editor_visual_col :: proc(ed: ^Editor, pos: buf.Position) -> int {
	return visual_col_of(buf.buffer_line_str(&ed.buf, pos.line), pos.col, ed.tab_width)
}

// editor_max_visual_width returns the widest line's width in cells
// (used to clamp horizontal scrolling).
editor_max_visual_width :: proc(ed: ^Editor) -> int {
	if ed.width_cache_version == ed.buf.version && ed.width_cache_tab == ed.tab_width {
		return ed.width_cache
	}
	widest := 0
	for ln in 0 ..< buf.buffer_line_count(&ed.buf) {
		widest = max(widest, line_visual_width(buf.buffer_line_str(&ed.buf, ln), ed.tab_width))
	}
	ed.width_cache = widest
	ed.width_cache_version = ed.buf.version
	ed.width_cache_tab = ed.tab_width
	return widest
}

// byte_col_at_cell returns the byte offset of the character drawn in cell
// `vcol` (floored), for hover hit-testing. The one cell just past the end
// of the line maps to len(line) — where LSP servers put "missing token"
// diagnostics — and `inside` is false any further right.
byte_col_at_cell :: proc(line: string, vcol: f32, tab_width: int) -> (col: int, inside: bool) {
	tw := max(tab_width, 1)
	if vcol < 0 {
		return 0, false
	}
	cell := 0
	for i := 0; i < len(line); {
		r, size := utf8.decode_rune_in_string(line[i:])
		w := tw - cell % tw if r == '\t' else rune_cells(r)
		if w > 0 && vcol < f32(cell + w) {
			return i, true
		}
		cell += w
		i += size
	}
	return len(line), vcol < f32(cell + 1)
}
