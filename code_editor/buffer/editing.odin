// Low-level and history-recording text mutation for Buffer. Low-level
// `raw_` procs never touch undo/redo; the public `buffer_insert_text` /
// `buffer_delete_range` wrap them and push onto the undo stack.
package buffer

import "core:strings"

// buffer_raw_insert inserts `text` at `pos`, splitting it across newlines as
// needed, and returns the position immediately after the inserted text.
// Does not record undo history.
buffer_raw_insert :: proc(b: ^Buffer, pos: Position, text: string) -> Position {
	if len(text) == 0 {
		return pos
	}
	b.version += 1
	p := buffer_clamp_position(b, pos)
	line_str := buffer_line_str(b, p.line)
	before := line_str[:p.col]
	after := line_str[p.col:]
	p_u16 := utf16_len(before) if b.track_changes else 0

	// Split incoming text on '\n'.
	segments := make([dynamic]string, 0, 4, context.temp_allocator)
	start := 0
	for i := 0; i <= len(text); i += 1 {
		if i == len(text) || text[i] == '\n' {
			segment := text[start:i]
			if len(segment) > 0 && segment[len(segment) - 1] == '\r' {
				segment = segment[:len(segment) - 1]
			}
			append(&segments, segment)
			start = i + 1
		}
	}

	if len(segments) == 1 {
		// Single-line insert: just splice into the existing line builder.
		new_line := strings.builder_make(b.allocator)
		strings.write_string(&new_line, before)
		strings.write_string(&new_line, segments[0])
		strings.write_string(&new_line, after)
		strings.builder_destroy(&b.lines[p.line])
		b.lines[p.line] = new_line
		end := Position{line = p.line, col = len(before) + len(segments[0])}
		b.dirty = true
		buffer_record_change(b, {start = p, old_end = p, new_end = end, start_u16 = p_u16, old_end_u16 = p_u16, text = segments[0]})
		return end
	}

	// Multi-line insert: first segment stays on the original line, middle
	// segments become new lines, last segment + `after` becomes the final
	// new line.
	//
	// IMPORTANT: `before`/`after` are string views into the *old*
	// `b.lines[p.line]` builder's backing array (via buffer_line_str), so
	// every read of them must happen before that builder is destroyed
	// below -- otherwise `after` would be read from freed memory.
	first_line := strings.builder_make(b.allocator)
	strings.write_string(&first_line, before)
	strings.write_string(&first_line, segments[0])

	new_lines := make([dynamic]strings.Builder, 0, len(segments) - 1, context.temp_allocator)
	for i := 1; i < len(segments) - 1; i += 1 {
		sb := strings.builder_make(b.allocator)
		strings.write_string(&sb, segments[i])
		append(&new_lines, sb)
	}
	last_line := strings.builder_make(b.allocator)
	strings.write_string(&last_line, segments[len(segments) - 1])
	strings.write_string(&last_line, after)
	append(&new_lines, last_line)

	strings.builder_destroy(&b.lines[p.line])
	b.lines[p.line] = first_line

	// Shift existing lines down and insert new_lines after p.line.
	insert_at := p.line + 1
	for nl, i in new_lines {
		inject_at(&b.lines, insert_at + i, nl)
	}

	end := Position{
		line = p.line + len(segments) - 1,
		col  = len(segments[len(segments) - 1]),
	}
	b.dirty = true
	if b.track_changes {
		joined := strings.join(segments[:], "\n", context.temp_allocator)
		buffer_record_change(b, {start = p, old_end = p, new_end = end, start_u16 = p_u16, old_end_u16 = p_u16, text = joined})
	}
	return end
}

// buffer_raw_delete removes text in [start, end) (document order assumed
// normalized by caller) and returns the removed text (allocated with
// `b.allocator`; caller owns it). Does not record undo history.
buffer_raw_delete :: proc(b: ^Buffer, start, end: Position) -> string {
	s := buffer_clamp_position(b, start)
	e := buffer_clamp_position(b, end)
	if position_eq(s, e) {
		return ""
	}
	b.version += 1
	if position_less(e, s) {
		s, e = e, s
	}
	s_u16, e_u16: int
	if b.track_changes {
		s_u16 = utf16_len(buffer_line_str(b, s.line)[:s.col])
		e_u16 = utf16_len(buffer_line_str(b, e.line)[:e.col])
	}

	if s.line == e.line {
		line_str := buffer_line_str(b, s.line)
		removed := strings.clone(line_str[s.col:e.col], b.allocator)
		new_line := strings.builder_make(b.allocator)
		strings.write_string(&new_line, line_str[:s.col])
		strings.write_string(&new_line, line_str[e.col:])
		strings.builder_destroy(&b.lines[s.line])
		b.lines[s.line] = new_line
		b.dirty = true
		buffer_record_change(b, {start = s, old_end = e, new_end = s, start_u16 = s_u16, old_end_u16 = e_u16})
		return removed
	}

	// Multi-line delete: build removed text from the affected lines, then
	// merge first/last remnants into s.line and remove the lines in between.
	sb := strings.builder_make(context.temp_allocator)
	first_str := buffer_line_str(b, s.line)
	strings.write_string(&sb, first_str[s.col:])
	for ln := s.line + 1; ln < e.line; ln += 1 {
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, buffer_line_str(b, ln))
	}
	strings.write_byte(&sb, '\n')
	last_str := buffer_line_str(b, e.line)
	strings.write_string(&sb, last_str[:e.col])
	removed := strings.clone(strings.to_string(sb), b.allocator)

	merged := strings.builder_make(b.allocator)
	strings.write_string(&merged, first_str[:s.col])
	strings.write_string(&merged, last_str[e.col:])
	strings.builder_destroy(&b.lines[s.line])
	b.lines[s.line] = merged

	// Remove lines (s.line+1 ..= e.line).
	remove_count := e.line - s.line
	for i := 0; i < remove_count; i += 1 {
		idx := s.line + 1
		strings.builder_destroy(&b.lines[idx])
		ordered_remove(&b.lines, idx)
	}

	b.dirty = true
	buffer_record_change(b, {start = s, old_end = e, new_end = s, start_u16 = s_u16, old_end_u16 = e_u16})
	return removed
}

// buffer_insert_text is the public editing API: inserts text at `pos` and
// records an undo entry. Returns the end position of the inserted text.
buffer_insert_text :: proc(b: ^Buffer, pos: Position, text: string, group_id := -1) -> Position {
	end := buffer_raw_insert(b, pos, text)
	append(&b.undo_stack, Edit{
		kind     = .Insert,
		start    = pos,
		end      = end,
		text     = strings.clone(text, b.allocator),
		group_id = group_id,
	})
	buffer_clear_redo(b)
	return end
}

// buffer_delete_range is the public editing API: deletes [start, end) and
// records an undo entry. Returns the removed text (caller does NOT own it;
// it is retained inside the undo stack until the edit is dropped).
buffer_delete_range :: proc(b: ^Buffer, start, end: Position, group_id := -1) -> string {
	s := position_min(start, end)
	e := position_max(start, end)
	removed := buffer_raw_delete(b, s, e)
	append(&b.undo_stack, Edit{
		kind     = .Delete,
		start    = s,
		end      = e,
		text     = removed,
		group_id = group_id,
	})
	buffer_clear_redo(b)
	return removed
}

buffer_clear_redo :: proc(b: ^Buffer) {
	for e in b.redo_stack {
		delete(e.text, b.allocator)
	}
	clear(&b.redo_stack)
}

// buffer_next_group begins a new undo group id. Pass the returned value as
// `group_id` to successive `buffer_insert_text`/`buffer_delete_range` calls
// that should undo/redo together as a single user action (e.g. multi-cursor
// edits or autocomplete expansions).
buffer_next_group :: proc(b: ^Buffer) -> int {
	// Any other kind of edit ends the current run of typing.
	b.typing_group = 0
	b.group_seq += 1
	return b.group_seq
}

// buffer_undo reverts the most recent edit (or group of edits sharing a
// group_id). Returns true if an edit was undone.
buffer_undo :: proc(b: ^Buffer) -> bool {
	b.typing_group = 0
	if len(b.undo_stack) == 0 {
		return false
	}
	group_id := b.undo_stack[len(b.undo_stack) - 1].group_id
	carets := make([dynamic]Edit_Caret, context.temp_allocator)
	for len(b.undo_stack) > 0 {
		top := b.undo_stack[len(b.undo_stack) - 1]
		if group_id != -1 && top.group_id != group_id {
			break
		}
		pop(&b.undo_stack)
		switch top.kind {
		case .Insert:
			discarded := buffer_raw_delete(b, top.start, top.end)
			delete(discarded, b.allocator)
			append(&b.redo_stack, top)
			add_caret(&carets, top.start, top.start, chain = top.end)
		case .Delete:
			end := buffer_raw_insert(b, top.start, top.text)
			append(&b.redo_stack, top)
			add_caret(&carets, top.start, end, chain = top.start)
		}
		if group_id == -1 {
			break
		}
	}
	place_carets(b, carets[:], descending = false)
	return true
}

// Edit_Caret is where a cursor should land after undoing/redoing one edit;
// `key` (the edit's start) merges the delete+insert pair a single cursor
// produces when typing over a selection.
@(private)
Edit_Caret :: struct {
	key, pos: Position,
}

@(private)
add_caret :: proc(carets: ^[dynamic]Edit_Caret, key, pos: Position, chain: Position) {
	for &c in carets {
		// Same site (delete+insert of one typed-over selection), or a
		// caret this edit continues (coalesced typing: undoing "abc" walks
		// one caret back from after 'c' to before 'a').
		if c.key == key || c.pos == chain {
			c.key = key
			c.pos = pos
			return
		}
	}
	append(carets, Edit_Caret{key, pos})
}

// place_carets moves the cursors to where the undone/redone edits
// happened (one cursor per edit site), like VSCode — so undoing a
// multi-cursor edit restores the multi-cursor state at the right columns.
// Cursors are listed in ascending document order; `carets` arrive
// ascending from undo (which pops the earliest-in-document edit first,
// since edits are recorded in descending order) and descending from redo.
@(private)
place_carets :: proc(b: ^Buffer, carets: []Edit_Caret, descending: bool) {
	if len(carets) == 0 {
		return
	}
	clear(&b.cursors)
	for i in 0 ..< len(carets) {
		c := carets[len(carets) - 1 - i] if descending else carets[i]
		append(&b.cursors, Cursor{pos = buffer_clamp_position(b, c.pos)})
	}
}

// buffer_redo re-applies the most recently undone edit (or group). Returns
// true if an edit was redone.
buffer_redo :: proc(b: ^Buffer) -> bool {
	b.typing_group = 0
	if len(b.redo_stack) == 0 {
		return false
	}
	group_id := b.redo_stack[len(b.redo_stack) - 1].group_id
	carets := make([dynamic]Edit_Caret, context.temp_allocator)
	for len(b.redo_stack) > 0 {
		top := b.redo_stack[len(b.redo_stack) - 1]
		if group_id != -1 && top.group_id != group_id {
			break
		}
		pop(&b.redo_stack)
		switch top.kind {
		case .Insert:
			end := buffer_raw_insert(b, top.start, top.text)
			append(&b.undo_stack, top)
			add_caret(&carets, top.start, end, chain = top.start)
		case .Delete:
			discarded := buffer_raw_delete(b, top.start, top.end)
			delete(discarded, b.allocator)
			append(&b.undo_stack, top)
			add_caret(&carets, top.start, top.start, chain = top.end)
		}
		if group_id == -1 {
			break
		}
	}
	place_carets(b, carets[:], descending = true)
	return true
}
