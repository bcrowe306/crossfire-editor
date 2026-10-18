// Package buffer implements a modular, host-agnostic text buffer with
// cursor/selection management and undo/redo history. It has no dependency
// on SDL or rendering and can be unit tested in isolation, then embedded in
// any host application.
package buffer

import "core:mem"
import "core:strings"

// Position is a (line, byte_col) location inside the buffer. `col` is a
// byte offset into the UTF-8 encoded line and is always kept aligned to a
// rune boundary by the editing/movement APIs.
Position :: struct {
	line: int,
	col:  int,
}

position_eq :: proc(a, b: Position) -> bool {
	return a.line == b.line && a.col == b.col
}

// position_less returns true if `a` comes strictly before `b` in document
// order.
position_less :: proc(a, b: Position) -> bool {
	if a.line != b.line {
		return a.line < b.line
	}
	return a.col < b.col
}

position_min :: proc(a, b: Position) -> Position {
	return a if position_less(a, b) else b
}

position_max :: proc(a, b: Position) -> Position {
	return b if position_less(a, b) else a
}

Selection :: struct {
	anchor: Position,
	active: bool,
}

Cursor :: struct {
	pos: Position,
	sel: Selection,
	// Sticky column for vertical movement, in whatever unit the host
	// uses (the editor stores a visual column): Up/Down aim for it so
	// the caret doesn't drift across short or differently-indented lines.
	has_goal: bool,
	goal:     int,
	// Where the last vertical move left the caret; the goal only applies
	// while the caret is still there (any other move/edit invalidates it
	// without every caller having to clear it).
	goal_at:  Position,
}

// selection_range returns the normalized (start, end) range of a cursor's
// selection. `ok` is false when there is no active selection.
selection_range :: proc(c: Cursor) -> (start: Position, end: Position, ok: bool) {
	if !c.sel.active || position_eq(c.sel.anchor, c.pos) {
		return {}, {}, false
	}
	return position_min(c.sel.anchor, c.pos), position_max(c.sel.anchor, c.pos), true
}

EditKind :: enum {
	Insert,
	Delete,
}

// Edit is a single undoable/redoable operation. `text` is the text that was
// inserted (for Insert) or removed (for Delete), so the inverse operation
// can be replayed without re-deriving it. Edits sharing the same
// `group_id` are undone/redone together as one logical user action.
Edit :: struct {
	kind:     EditKind,
	start:    Position,
	end:      Position,
	text:     string,
	group_id: int,
}

// Change records one content mutation: the text in [start, old_end) was
// replaced and now spans [start, new_end). Consumers (e.g. the editor's
// diagnostic overlay) use it to shift positions they hold.
Change :: struct {
	start, old_end, new_end: Position,
	// start/old_end columns in UTF-16 code units, measured on the text as
	// it was *before* this change (what an LSP incremental didChange needs;
	// later edits can change the line, so it must be captured here).
	start_u16, old_end_u16: int,
	// The inserted text ("" for deletions). Owned by the log; valid until
	// the next buffer_take_changes or mutation.
	text: string,
}

MAX_TRACKED_CHANGES :: 4096

Buffer :: struct {
	lines:      [dynamic]strings.Builder,
	cursors:    [dynamic]Cursor,
	undo_stack: [dynamic]Edit,
	redo_stack: [dynamic]Edit,
	dirty:      bool,
	file_path:  string,
	allocator:  mem.Allocator,
	group_seq:  int,
	// version increments on every content mutation (insert, delete,
	// set_text). Hosts compare it against a saved value to detect changes
	// without diffing, e.g. to know when to push LSP didChange.
	version:    int,
	// Opt-in change log (see buffer_take_changes). If it overflows or the
	// whole text is replaced, `changes_reset` is set instead: positions
	// can't be shifted and must be recomputed.
	track_changes: bool,
	changes:       [dynamic]Change,
	changes_reset: bool,
	changes_taken: bool, // the current batch was handed out; free on next use

	// Typing coalescing: consecutive single-line insertions at the caret(s)
	// share one undo group until the caret moves, another kind of edit
	// happens, or a new word starts (see buffer_type_text).
	typing_group:     int,
	typing_ends:      [dynamic]Position,
	typing_last_char: u8,
}

buffer_init :: proc(allocator := context.allocator) -> Buffer {
	b := Buffer {
		allocator = allocator,
	}
	b.lines = make([dynamic]strings.Builder, allocator)
	append(&b.lines, strings.builder_make(allocator))
	b.cursors = make([dynamic]Cursor, allocator)
	append(&b.cursors, Cursor{})
	b.undo_stack = make([dynamic]Edit, allocator)
	b.redo_stack = make([dynamic]Edit, allocator)
	b.changes = make([dynamic]Change, allocator)
	b.typing_ends = make([dynamic]Position, allocator)
	return b
}

buffer_destroy :: proc(b: ^Buffer) {
	for &line in b.lines {
		strings.builder_destroy(&line)
	}
	delete(b.lines)
	delete(b.cursors)
	buffer_clear_undo_history(b)
	delete(b.undo_stack)
	delete(b.redo_stack)
	buffer_free_changes(b)
	delete(b.changes)
	delete(b.typing_ends)
	if len(b.file_path) > 0 {
		delete(b.file_path, b.allocator)
	}
}

buffer_clear_undo_history :: proc(b: ^Buffer) {
	for e in b.undo_stack {
		delete(e.text, b.allocator)
	}
	for e in b.redo_stack {
		delete(e.text, b.allocator)
	}
	clear(&b.undo_stack)
	clear(&b.redo_stack)
}

buffer_line_count :: proc(b: ^Buffer) -> int {
	return len(b.lines)
}

buffer_line_str :: proc(b: ^Buffer, line: int) -> string {
	if line < 0 || line >= len(b.lines) {
		return ""
	}
	return strings.to_string(b.lines[line])
}

buffer_line_len :: proc(b: ^Buffer, line: int) -> int {
	return len(buffer_line_str(b, line))
}

buffer_clamp_position :: proc(b: ^Buffer, pos: Position) -> Position {
	p := pos
	line_count := buffer_line_count(b)
	if p.line < 0 {
		p.line = 0
	}
	if p.line >= line_count {
		p.line = line_count - 1
	}
	line_len := buffer_line_len(b, p.line)
	if p.col < 0 {
		p.col = 0
	}
	if p.col > line_len {
		p.col = line_len
	}
	return p
}

buffer_end_position :: proc(b: ^Buffer) -> Position {
	last := buffer_line_count(b) - 1
	return Position{line = last, col = buffer_line_len(b, last)}
}

// buffer_set_text replaces the entire contents of the buffer with `text`.
// Resets cursors to the start and clears undo history (used for file load).
buffer_set_text :: proc(b: ^Buffer, text: string) {
	for &line in b.lines {
		strings.builder_destroy(&line)
	}
	clear(&b.lines)

	start := 0
	for i := 0; i <= len(text); i += 1 {
		if i == len(text) || text[i] == '\n' {
			segment := text[start:i]
			// Strip a trailing \r for CRLF line endings.
			if len(segment) > 0 && segment[len(segment) - 1] == '\r' {
				segment = segment[:len(segment) - 1]
			}
			sb := strings.builder_make(b.allocator)
			strings.write_string(&sb, segment)
			append(&b.lines, sb)
			start = i + 1
		}
	}
	if len(b.lines) == 0 {
		append(&b.lines, strings.builder_make(b.allocator))
	}

	clear(&b.cursors)
	append(&b.cursors, Cursor{})
	buffer_clear_undo_history(b)
	b.dirty = false
	b.version += 1
	b.typing_group = 0
	buffer_record_reset(b)
}

// buffer_free_changes drops every recorded change (and its text).
@(private)
buffer_free_changes :: proc(b: ^Buffer) {
	for ch in b.changes {
		delete(ch.text, b.allocator)
	}
	clear(&b.changes)
	b.changes_taken = false
}

// buffer_record_change appends one change; `text` is cloned.
@(private)
buffer_record_change :: proc(b: ^Buffer, ch: Change) {
	if !b.track_changes {
		return
	}
	if b.changes_taken {
		buffer_free_changes(b)
	}
	if b.changes_reset {
		return
	}
	if len(b.changes) >= MAX_TRACKED_CHANGES {
		buffer_record_reset(b)
		return
	}
	c := ch
	c.text = strings.clone(ch.text, b.allocator)
	append(&b.changes, c)
}

@(private)
buffer_record_reset :: proc(b: ^Buffer) {
	if b.track_changes {
		buffer_free_changes(b)
		b.changes_reset = true
	}
}

// buffer_take_changes returns the changes recorded since the last call
// (oldest first) and whether a reset happened (whole text replaced or log
// overflow: positions can't be mapped, re-read everything). The slice and
// its texts stay valid until the next take or mutation.
buffer_take_changes :: proc(b: ^Buffer) -> (changes: []Change, reset: bool) {
	if b.changes_taken {
		buffer_free_changes(b)
	}
	changes = b.changes[:]
	reset = b.changes_reset
	b.changes_reset = false
	b.changes_taken = true
	return
}

// utf16_len counts UTF-16 code units in `s`.
utf16_len :: proc(s: string) -> int {
	n := 0
	for r in s {
		n += 2 if r > 0xFFFF else 1
	}
	return n
}

// position_after_change maps a position through one change: positions
// before the edit stay, positions after it move with the text, and
// positions inside replaced text collapse to the end of the new text.
position_after_change :: proc(p: Position, ch: Change) -> Position {
	if position_less(p, ch.start) {
		return p
	}
	if position_less(p, ch.old_end) {
		return ch.new_end
	}
	if p.line == ch.old_end.line {
		return {ch.new_end.line, ch.new_end.col + (p.col - ch.old_end.col)}
	}
	return {p.line + (ch.new_end.line - ch.old_end.line), p.col}
}

// buffer_to_string concatenates all lines with '\n' separators. Caller owns
// the returned string (allocated with `allocator`).
buffer_to_string :: proc(b: ^Buffer, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for i := 0; i < len(b.lines); i += 1 {
		strings.write_string(&sb, strings.to_string(b.lines[i]))
		if i != len(b.lines) - 1 {
			strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb)
}
