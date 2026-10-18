// Cursor/selection movement commands. Each proc mutates a single Cursor in
// place; multi-cursor orchestration lives in cursor_set.odin.
package buffer

import "core:unicode/utf8"

// rune_at_byte returns the rune starting at byte offset `col` in `s`,
// plus its width in bytes.
rune_at_byte :: proc(s: string, col: int) -> (rune, int) {
	if col < 0 || col >= len(s) {
		return 0, 0
	}
	r, width := utf8.decode_rune_in_string(s[col:])
	return r, width
}

// prev_rune_width returns the byte width of the rune immediately before
// byte offset `col` in `s`.
prev_rune_width :: proc(s: string, col: int) -> int {
	if col <= 0 || col > len(s) {
		return 0
	}
	_, width := utf8.decode_last_rune_in_string(s[:col])
	return width
}

is_word_byte :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_'
}

cursor_move_left :: proc(b: ^Buffer, c: ^Cursor, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	if c.pos.col > 0 {
		line := buffer_line_str(b, c.pos.line)
		c.pos.col -= prev_rune_width(line, c.pos.col)
	} else if c.pos.line > 0 {
		c.pos.line -= 1
		c.pos.col = buffer_line_len(b, c.pos.line)
	}
	cursor_maybe_clear_selection(c, extend_selection)
}

cursor_move_right :: proc(b: ^Buffer, c: ^Cursor, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	line_len := buffer_line_len(b, c.pos.line)
	if c.pos.col < line_len {
		line := buffer_line_str(b, c.pos.line)
		_, width := rune_at_byte(line, c.pos.col)
		if width == 0 {
			width = 1
		}
		c.pos.col += width
	} else if c.pos.line < buffer_line_count(b) - 1 {
		c.pos.line += 1
		c.pos.col = 0
	}
	cursor_maybe_clear_selection(c, extend_selection)
}

cursor_move_up :: proc(b: ^Buffer, c: ^Cursor, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	if c.pos.line > 0 {
		c.pos.line -= 1
		c.pos.col = min(c.pos.col, buffer_line_len(b, c.pos.line))
	} else {
		c.pos.col = 0
	}
	cursor_maybe_clear_selection(c, extend_selection)
}

cursor_move_down :: proc(b: ^Buffer, c: ^Cursor, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	if c.pos.line < buffer_line_count(b) - 1 {
		c.pos.line += 1
		c.pos.col = min(c.pos.col, buffer_line_len(b, c.pos.line))
	} else {
		c.pos.col = buffer_line_len(b, c.pos.line)
	}
	cursor_maybe_clear_selection(c, extend_selection)
}

cursor_move_line_start :: proc(b: ^Buffer, c: ^Cursor, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	line := buffer_line_str(b, c.pos.line)
	// First press goes to first non-whitespace char; if already there (or
	// at col 0 with no leading whitespace), go to column 0.
	first_non_ws := 0
	for first_non_ws < len(line) && (line[first_non_ws] == ' ' || line[first_non_ws] == '\t') {
		first_non_ws += 1
	}
	if c.pos.col == first_non_ws && first_non_ws != 0 {
		c.pos.col = 0
	} else {
		c.pos.col = first_non_ws
	}
	cursor_maybe_clear_selection(c, extend_selection)
}

cursor_move_line_end :: proc(b: ^Buffer, c: ^Cursor, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	c.pos.col = buffer_line_len(b, c.pos.line)
	cursor_maybe_clear_selection(c, extend_selection)
}

cursor_move_doc_start :: proc(b: ^Buffer, c: ^Cursor, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	c.pos = Position{0, 0}
	cursor_maybe_clear_selection(c, extend_selection)
}

cursor_move_doc_end :: proc(b: ^Buffer, c: ^Cursor, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	c.pos = buffer_end_position(b)
	cursor_maybe_clear_selection(c, extend_selection)
}

cursor_move_page :: proc(b: ^Buffer, c: ^Cursor, lines: int, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	target := c.pos.line + lines
	if target < 0 {
		target = 0
	}
	if target > buffer_line_count(b) - 1 {
		target = buffer_line_count(b) - 1
	}
	c.pos.line = target
	c.pos.col = min(c.pos.col, buffer_line_len(b, c.pos.line))
	cursor_maybe_clear_selection(c, extend_selection)
}

// cursor_move_word_left/right jump across a "word" the way VSCode/Zed do:
// skip whitespace, then skip a run of word or non-word punctuation chars.
cursor_move_word_left :: proc(b: ^Buffer, c: ^Cursor, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	if c.pos.col == 0 {
		if c.pos.line > 0 {
			c.pos.line -= 1
			c.pos.col = buffer_line_len(b, c.pos.line)
		}
		cursor_maybe_clear_selection(c, extend_selection)
		return
	}
	line := buffer_line_str(b, c.pos.line)
	col := c.pos.col
	for col > 0 && (line[col - 1] == ' ' || line[col - 1] == '\t') {
		col -= 1
	}
	if col > 0 {
		word_mode := is_word_byte(line[col - 1])
		for col > 0 && is_word_byte(line[col - 1]) == word_mode && line[col - 1] != ' ' && line[col - 1] != '\t' {
			col -= 1
		}
	}
	c.pos.col = col
	cursor_maybe_clear_selection(c, extend_selection)
}

cursor_move_word_right :: proc(b: ^Buffer, c: ^Cursor, extend_selection: bool) {
	cursor_maybe_begin_selection(c, extend_selection)
	line := buffer_line_str(b, c.pos.line)
	line_len := len(line)
	if c.pos.col >= line_len {
		if c.pos.line < buffer_line_count(b) - 1 {
			c.pos.line += 1
			c.pos.col = 0
		}
		cursor_maybe_clear_selection(c, extend_selection)
		return
	}
	col := c.pos.col
	for col < line_len && (line[col] == ' ' || line[col] == '\t') {
		col += 1
	}
	if col < line_len {
		word_mode := is_word_byte(line[col])
		for col < line_len && is_word_byte(line[col]) == word_mode && line[col] != ' ' && line[col] != '\t' {
			col += 1
		}
	}
	c.pos.col = col
	cursor_maybe_clear_selection(c, extend_selection)
}

cursor_maybe_begin_selection :: proc(c: ^Cursor, extend_selection: bool) {
	if extend_selection && !c.sel.active {
		c.sel.anchor = c.pos
		c.sel.active = true
	}
}

cursor_maybe_clear_selection :: proc(c: ^Cursor, extend_selection: bool) {
	if !extend_selection {
		c.sel.active = false
	}
}

cursor_select_all :: proc(b: ^Buffer, c: ^Cursor) {
	c.sel.anchor = Position{0, 0}
	c.sel.active = true
	c.pos = buffer_end_position(b)
}

cursor_select_line :: proc(b: ^Buffer, c: ^Cursor) {
	c.sel.anchor = Position{line = c.pos.line, col = 0}
	c.sel.active = true
	if c.pos.line < buffer_line_count(b) - 1 {
		c.pos = Position{line = c.pos.line + 1, col = 0}
	} else {
		c.pos = Position{line = c.pos.line, col = buffer_line_len(b, c.pos.line)}
	}
}

cursor_select_word :: proc(b: ^Buffer, c: ^Cursor) {
	line := buffer_line_str(b, c.pos.line)
	col := c.pos.col
	if col >= len(line) {
		col = max(0, len(line) - 1)
	}
	if col >= len(line) {
		return
	}
	start := col
	end := col
	word_mode := is_word_byte(line[col])
	for start > 0 && is_word_byte(line[start - 1]) == word_mode {
		start -= 1
	}
	for end < len(line) && is_word_byte(line[end]) == word_mode {
		end += 1
	}
	c.sel.anchor = Position{line = c.pos.line, col = start}
	c.sel.active = true
	c.pos = Position{line = c.pos.line, col = end}
}
