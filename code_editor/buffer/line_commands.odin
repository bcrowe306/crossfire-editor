// Line-oriented editing commands (VSCode/Zed equivalents): duplicate
// lines up/down, move lines up/down, toggle line comments, delete lines,
// insert a line above/below. Each is one undo step. Duplicate/move act on
// the primary cursor's lines; comment, delete and insert-line act on every
// cursor.
package buffer

import "core:slice"
import "core:strings"

// cursor_line_span returns the lines a cursor covers: its selection's
// lines (a selection ending at column 0 doesn't include that last line),
// or just its own line.
cursor_line_span :: proc(c: Cursor) -> (first, last: int) {
	s, e, ok := selection_range(c)
	if !ok {
		return c.pos.line, c.pos.line
	}
	last = e.line
	if e.col == 0 && e.line > s.line {
		last -= 1
	}
	return s.line, last
}

@(private)
shift_cursor_lines :: proc(c: ^Cursor, delta: int) {
	c.pos.line += delta
	if c.sel.active {
		c.sel.anchor.line += delta
	}
}

@(private)
lines_text :: proc(b: ^Buffer, first, last: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for ln in first ..= last {
		if ln > first {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, buffer_line_str(b, ln))
	}
	return strings.to_string(sb)
}

// buffer_duplicate_lines copies the primary cursor's lines below
// themselves. Down: the caret moves to the copy; up: it stays on the upper
// copy (the original position), like VSCode's Shift+Alt+Down / Up.
buffer_duplicate_lines :: proc(b: ^Buffer, down: bool) {
	c := &b.cursors[0]
	first, last := cursor_line_span(c^)
	text := lines_text(b, first, last)
	group := buffer_next_group(b)
	buffer_insert_text(b, {last, buffer_line_len(b, last)}, strings.concatenate({"\n", text}, context.temp_allocator), group)
	if down {
		shift_cursor_lines(c, last - first + 1)
	}
}

// buffer_move_lines moves the primary cursor's lines up (dir < 0) or down
// (dir > 0) by one, swapping with the neighbouring line.
buffer_move_lines :: proc(b: ^Buffer, dir: int) -> bool {
	c := &b.cursors[0]
	first, last := cursor_line_span(c^)
	count := buffer_line_count(b)
	group := buffer_next_group(b)
	if dir < 0 {
		if first == 0 {
			return false
		}
		above := strings.clone(buffer_line_str(b, first - 1), context.temp_allocator)
		buffer_delete_range(b, {first - 1, 0}, {first, 0}, group)
		// The block now spans first-1 .. last-1; put the old line after it.
		if last < count - 1 {
			buffer_insert_text(b, {last, 0}, strings.concatenate({above, "\n"}, context.temp_allocator), group)
		} else {
			buffer_insert_text(b, {last - 1, buffer_line_len(b, last - 1)}, strings.concatenate({"\n", above}, context.temp_allocator), group)
		}
		shift_cursor_lines(c, -1)
	} else {
		if last >= count - 1 {
			return false
		}
		below := strings.clone(buffer_line_str(b, last + 1), context.temp_allocator)
		buffer_delete_range(b, {last, buffer_line_len(b, last)}, {last + 1, buffer_line_len(b, last + 1)}, group)
		buffer_insert_text(b, {first, 0}, strings.concatenate({below, "\n"}, context.temp_allocator), group)
		shift_cursor_lines(c, 1)
	}
	return true
}

// covered_lines lists the distinct lines all cursors cover, descending.
@(private)
covered_lines :: proc(b: ^Buffer) -> []int {
	seen := make(map[int]bool, context.temp_allocator)
	out := make([dynamic]int, context.temp_allocator)
	for c in b.cursors {
		first, last := cursor_line_span(c)
		for ln in first ..= last {
			if !seen[ln] {
				seen[ln] = true
				append(&out, ln)
			}
		}
	}
	slice.reverse_sort(out[:])
	return out[:]
}

@(private)
leading_ws :: proc(s: string) -> int {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	return i
}

// buffer_toggle_line_comment comments (or, if every non-blank covered line
// is already commented, uncomments) the cursors' lines with `prefix`
// ("//"). Comments are inserted at the shallowest indentation so the
// block stays aligned; cursors keep their place in the text.
buffer_toggle_line_comment :: proc(b: ^Buffer, prefix: string) {
	lines := covered_lines(b)
	all_commented := true
	min_indent := max(int)
	for ln in lines {
		s := buffer_line_str(b, ln)
		ind := leading_ws(s)
		if ind == len(s) {
			continue // blank lines don't count
		}
		min_indent = min(min_indent, ind)
		if !strings.has_prefix(s[ind:], prefix) {
			all_commented = false
		}
	}
	if min_indent == max(int) {
		return // only blank lines
	}
	group := buffer_next_group(b)
	Edit_At :: struct {
		line, col, delta: int,
	}
	edits := make([dynamic]Edit_At, context.temp_allocator)
	for ln in lines {
		s := buffer_line_str(b, ln)
		ind := leading_ws(s)
		if ind == len(s) {
			continue
		}
		if all_commented {
			n := len(prefix)
			if ind + n < len(s) && s[ind + n] == ' ' {
				n += 1
			}
			buffer_delete_range(b, {ln, ind}, {ln, ind + n}, group)
			append(&edits, Edit_At{ln, ind, -n})
		} else {
			text := strings.concatenate({prefix, " "}, context.temp_allocator)
			buffer_insert_text(b, {ln, min_indent}, text, group)
			append(&edits, Edit_At{ln, min_indent, len(text)})
		}
	}
	// The caret moves with the text; a selection anchor exactly at an
	// insertion point stays put (so the selection grows over the comment).
	remap :: proc(p: ^Position, edits: []Edit_At, sticky_left: bool) {
		for e in edits {
			if p.line != e.line {
				continue
			}
			if p.col > e.col || (p.col == e.col && !(sticky_left && e.delta > 0)) {
				p.col = max(e.col, p.col + e.delta)
			}
		}
	}
	for &c in b.cursors {
		remap(&c.pos, edits[:], false)
		if c.sel.active {
			remap(&c.sel.anchor, edits[:], true)
		}
	}
}

// buffer_delete_lines removes every line the cursors cover; each cursor
// lands on the line that took its place.
buffer_delete_lines :: proc(b: ^Buffer) {
	lines := covered_lines(b)
	group := buffer_next_group(b)
	for ln in lines {
		count := buffer_line_count(b)
		switch {
		case count == 1:
			buffer_delete_range(b, {0, 0}, {0, buffer_line_len(b, 0)}, group)
		case ln < count - 1:
			buffer_delete_range(b, {ln, 0}, {ln + 1, 0}, group)
		case:
			buffer_delete_range(b, {ln - 1, buffer_line_len(b, ln - 1)}, {ln, buffer_line_len(b, ln)}, group)
		}
	}
	for &c in b.cursors {
		first, _ := cursor_line_span(c)
		c.sel.active = false
		c.pos = buffer_clamp_position(b, {first, c.pos.col})
	}
	// Cursors that collapsed onto the same spot become one.
	for i := len(b.cursors) - 1; i > 0; i -= 1 {
		for j in 0 ..< i {
			if b.cursors[j].pos == b.cursors[i].pos {
				ordered_remove(&b.cursors, i)
				break
			}
		}
	}
}

// buffer_insert_line opens a new line below (or above) each cursor's line
// with the same indentation and moves the cursor onto it.
buffer_insert_line :: proc(b: ^Buffer, above: bool) {
	group := buffer_next_group(b)
	order := buffer_sorted_cursor_indices(b)
	for i in order {
		c := &b.cursors[i]
		s := buffer_line_str(b, c.pos.line)
		indent := strings.clone(s[:leading_ws(s)], context.temp_allocator)
		if above {
			buffer_insert_text(b, {c.pos.line, 0}, strings.concatenate({indent, "\n"}, context.temp_allocator), group)
			c.pos = {c.pos.line, len(indent)}
		} else {
			end := buffer_insert_text(b, {c.pos.line, len(s)}, strings.concatenate({"\n", indent}, context.temp_allocator), group)
			c.pos = end
		}
		c.sel.active = false
	}
}
