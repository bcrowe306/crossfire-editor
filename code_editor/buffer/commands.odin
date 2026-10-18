// Multi-cursor command layer: typing, backspace/delete, newline with
// auto-indent, and indent/outdent. Cursors are processed in descending
// document order so that an edit at one cursor never invalidates the
// (line, col) of a cursor positioned earlier in the document.
package buffer

import "core:strings"

// buffer_sorted_cursor_indices returns cursor indices ordered by *descending*
// document position (last cursor in the document first). Plain insertion
// sort is used since cursor counts are always small (single digits to low
// hundreds at most).
buffer_sorted_cursor_indices :: proc(b: ^Buffer, allocator := context.temp_allocator) -> []int {
	idx := make([]int, len(b.cursors), allocator)
	for i in 0 ..< len(idx) {
		idx[i] = i
	}
	for i := 1; i < len(idx); i += 1 {
		key := idx[i]
		key_pos := b.cursors[key].pos
		j := i - 1
		for j >= 0 && position_less(b.cursors[idx[j]].pos, key_pos) {
			idx[j + 1] = idx[j]
			j -= 1
		}
		idx[j + 1] = key
	}
	return idx
}

// buffer_delete_selection_for_cursor deletes the cursor's active selection
// (if any) and collapses the cursor to the selection start. Returns true if
// a selection was deleted.
buffer_delete_selection_for_cursor :: proc(b: ^Buffer, c: ^Cursor, group_id: int) -> bool {
	start, end, ok := selection_range(c^)
	if !ok {
		return false
	}
	buffer_delete_range(b, start, end, group_id)
	c.pos = start
	c.sel.active = false
	return true
}

// buffer_type_text inserts `text` at every cursor, replacing any active
// selections, and advances each cursor past the inserted text. All
// resulting edits share one undo group.
buffer_type_text :: proc(b: ^Buffer, text: string) {
	group: int
	if buffer_can_coalesce_typing(b, text) {
		group = b.typing_group
	} else {
		group = buffer_next_group(b)
	}
	order := buffer_sorted_cursor_indices(b)
	for i in order {
		c := &b.cursors[i]
		buffer_delete_selection_for_cursor(b, c, group)
		end := buffer_insert_text(b, c.pos, text, group)
		c.pos = end
		c.sel.active = false
	}

	// Remember where this run of typing ended so the next keystroke can
	// join the same undo step. Text containing a newline never coalesces.
	b.typing_group = 0
	if len(text) > 0 && strings.index_byte(text, '\n') < 0 {
		b.typing_group = group
		clear(&b.typing_ends)
		for c in b.cursors {
			append(&b.typing_ends, c.pos)
		}
		b.typing_last_char = text[len(text) - 1]
	}
}

// buffer_can_coalesce_typing reports whether typing `text` now continues
// the previous run: same undo group still on top, every caret exactly
// where the run left it with no selection, no newline, and not the first
// character of a new word (VSCode-style word granularity: "hello world"
// undoes as "world", then "hello ").
@(private)
buffer_can_coalesce_typing :: proc(b: ^Buffer, text: string) -> bool {
	if b.typing_group == 0 || len(text) == 0 || strings.index_byte(text, '\n') >= 0 {
		return false
	}
	if len(b.undo_stack) == 0 || b.undo_stack[len(b.undo_stack) - 1].group_id != b.typing_group {
		return false
	}
	if len(b.cursors) != len(b.typing_ends) {
		return false
	}
	for c, i in b.cursors {
		if c.sel.active || c.pos != b.typing_ends[i] {
			return false
		}
	}
	is_space :: proc(ch: u8) -> bool {return ch == ' ' || ch == '\t'}
	if is_space(b.typing_last_char) && !is_space(text[0]) {
		return false
	}
	return true
}

// buffer_backspace deletes the selection, or one rune to the left of the
// cursor if there is no selection, for every cursor.
buffer_backspace :: proc(b: ^Buffer, word_mode := false) {
	group := buffer_next_group(b)
	order := buffer_sorted_cursor_indices(b)
	for i in order {
		c := &b.cursors[i]
		if buffer_delete_selection_for_cursor(b, c, group) {
			continue
		}
		start := c.pos
		if word_mode {
			saved := c.pos
			cursor_move_word_left(b, c, false)
			start = c.pos
			c.pos = saved
		} else if c.pos.col > 0 {
			line := buffer_line_str(b, c.pos.line)
			start = Position{line = c.pos.line, col = c.pos.col - prev_rune_width(line, c.pos.col)}
		} else if c.pos.line > 0 {
			start = Position{line = c.pos.line - 1, col = buffer_line_len(b, c.pos.line - 1)}
		} else {
			continue
		}
		buffer_delete_range(b, start, c.pos, group)
		c.pos = start
	}
}

// buffer_delete_forward deletes the selection, or one rune to the right of
// the cursor if there is no selection, for every cursor.
buffer_delete_forward :: proc(b: ^Buffer, word_mode := false) {
	group := buffer_next_group(b)
	order := buffer_sorted_cursor_indices(b)
	for i in order {
		c := &b.cursors[i]
		if buffer_delete_selection_for_cursor(b, c, group) {
			continue
		}
		end := c.pos
		if word_mode {
			saved := c.pos
			cursor_move_word_right(b, c, false)
			end = c.pos
			c.pos = saved
		} else {
			line_len := buffer_line_len(b, c.pos.line)
			if c.pos.col < line_len {
				line := buffer_line_str(b, c.pos.line)
				_, width := rune_at_byte(line, c.pos.col)
				if width == 0 {
					width = 1
				}
				end = Position{line = c.pos.line, col = c.pos.col + width}
			} else if c.pos.line < buffer_line_count(b) - 1 {
				end = Position{line = c.pos.line + 1, col = 0}
			} else {
				continue
			}
		}
		buffer_delete_range(b, c.pos, end, group)
	}
}

// buffer_newline inserts a line break at every cursor, auto-indenting the
// new line to match the leading whitespace of the current line.
buffer_newline :: proc(b: ^Buffer) {
	group := buffer_next_group(b)
	order := buffer_sorted_cursor_indices(b)
	for i in order {
		c := &b.cursors[i]
		buffer_delete_selection_for_cursor(b, c, group)
		line := buffer_line_str(b, c.pos.line)
		indent_end := 0
		for indent_end < len(line) && (line[indent_end] == ' ' || line[indent_end] == '\t') {
			indent_end += 1
		}
		indent := line[:indent_end]
		sb := strings.builder_make(context.temp_allocator)
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, indent)
		end := buffer_insert_text(b, c.pos, strings.to_string(sb), group)
		c.pos = end
		c.sel.active = false
	}
}

INDENT_WIDTH :: 4

// buffer_indent inserts a tab/indent at the cursor (if no selection), or
// indents every selected line by INDENT_WIDTH spaces.
buffer_indent :: proc(b: ^Buffer, use_tabs := false) {
	group := buffer_next_group(b)
	order := buffer_sorted_cursor_indices(b)
	for i in order {
		c := &b.cursors[i]
		start, end, has_sel := selection_range(c^)
		if !has_sel {
			text := use_tabs ? "\t" : strings.repeat(" ", INDENT_WIDTH, context.temp_allocator)
			new_pos := buffer_insert_text(b, c.pos, text, group)
			c.pos = new_pos
			continue
		}
		pad := use_tabs ? "\t" : strings.repeat(" ", INDENT_WIDTH, context.temp_allocator)
		for ln := end.line; ln >= start.line; ln -= 1 {
			buffer_insert_text(b, Position{line = ln, col = 0}, pad, group)
		}
		c.sel.anchor = Position{line = start.line, col = 0}
		c.pos = Position{line = end.line, col = buffer_line_len(b, end.line)}
	}
}

// buffer_outdent removes up to INDENT_WIDTH leading whitespace columns (or
// one leading tab) from every selected line (or the cursor's line if there
// is no selection).
buffer_outdent :: proc(b: ^Buffer) {
	group := buffer_next_group(b)
	order := buffer_sorted_cursor_indices(b)
	for i in order {
		c := &b.cursors[i]
		start, end, has_sel := selection_range(c^)
		first_line, last_line := c.pos.line, c.pos.line
		if has_sel {
			first_line, last_line = start.line, end.line
		}
		for ln := last_line; ln >= first_line; ln -= 1 {
			line := buffer_line_str(b, ln)
			remove_n := 0
			if len(line) > 0 && line[0] == '\t' {
				remove_n = 1
			} else {
				for remove_n < len(line) && remove_n < INDENT_WIDTH && line[remove_n] == ' ' {
					remove_n += 1
				}
			}
			if remove_n > 0 {
				buffer_delete_range(b, Position{line = ln, col = 0}, Position{line = ln, col = remove_n}, group)
				if ln == c.pos.line {
					c.pos.col = max(0, c.pos.col - remove_n)
				}
			}
		}
	}
}
