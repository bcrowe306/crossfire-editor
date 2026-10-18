// Snippets (LSP insertTextFormat 2): parse the snippet grammar into plain
// text plus tab stops, insert it, and run a "snippet session" where Tab /
// Shift+Tab move between the stops ($1, $2, ... then $0) with each
// placeholder selected. Stops are buffer positions kept up to date as the
// user types (via editor_consume_buffer_changes). The session ends on
// Escape, on reaching $0, or when the caret leaves the current stop.
//
// Supported grammar: $N, ${N}, ${N:placeholder} (nestable),
// ${N|one,two|} (first choice), $VAR / ${VAR} / ${VAR:default}
// (variables expand to their default or nothing), and \ escapes.
package code_editor

import buf "../buffer"
import "core:strings"

Snippet_Stop :: struct {
	index:      int, // 0 = final caret position
	start, end: int, // byte offsets into the expanded text
}

Snippet_Session :: struct {
	active:  bool,
	stops:   [dynamic]Session_Stop, // navigation order: 1, 2, ..., then 0
	current: int,
}

Session_Stop :: struct {
	index:      int,
	start, end: buf.Position,
}

// parse_snippet expands `src` into plain text and its tab stops (first
// occurrence of each index; offsets into `text`). Both are allocated with
// `allocator`.
parse_snippet :: proc(src: string, allocator := context.allocator) -> (text: string, stops: [dynamic]Snippet_Stop) {
	sb := strings.builder_make(allocator)
	stops = make([dynamic]Snippet_Stop, allocator)
	i := 0
	snippet_parse_seq(src, &i, false, &sb, &stops)
	return strings.to_string(sb), stops
}

@(private)
snippet_add_stop :: proc(stops: ^[dynamic]Snippet_Stop, index, start, end: int) {
	for s in stops {
		if s.index == index {
			return // mirrors: only the first occurrence is navigable
		}
	}
	append(stops, Snippet_Stop{index, start, end})
}

@(private)
is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}

@(private)
is_var_char :: proc(c: u8) -> bool {return c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || is_digit(c)}

// snippet_parse_seq consumes text until the end (or an unescaped '}' when
// `in_brace`), writing expanded text to `sb`.
@(private)
snippet_parse_seq :: proc(s: string, i: ^int, in_brace: bool, sb: ^strings.Builder, stops: ^[dynamic]Snippet_Stop) {
	for i^ < len(s) {
		c := s[i^]
		switch {
		case c == '\\' && i^ + 1 < len(s) && strings.index_byte("$}\\,|", s[i^ + 1]) >= 0:
			strings.write_byte(sb, s[i^ + 1])
			i^ += 2
		case c == '}' && in_brace:
			return
		case c == '$' && i^ + 1 < len(s) && is_digit(s[i^ + 1]):
			i^ += 1
			n := 0
			for i^ < len(s) && is_digit(s[i^]) {
				n = n * 10 + int(s[i^] - '0')
				i^ += 1
			}
			off := strings.builder_len(sb^)
			snippet_add_stop(stops, n, off, off)
		case c == '$' && i^ + 1 < len(s) && s[i^ + 1] == '{':
			i^ += 2
			if i^ < len(s) && is_digit(s[i^]) {
				n := 0
				for i^ < len(s) && is_digit(s[i^]) {
					n = n * 10 + int(s[i^] - '0')
					i^ += 1
				}
				start := strings.builder_len(sb^)
				if i^ < len(s) && s[i^] == ':' {
					i^ += 1
					snippet_parse_seq(s, i, true, sb, stops)
				} else if i^ < len(s) && s[i^] == '|' {
					// Choice: insert the first option.
					i^ += 1
					first := true
					for i^ < len(s) && s[i^] != '|' {
						if s[i^] == ',' {
							first = false
						} else if first {
							if s[i^] == '\\' && i^ + 1 < len(s) {
								i^ += 1
							}
							strings.write_byte(sb, s[i^])
						}
						i^ += 1
					}
					i^ += 1 // '|'
				}
				if i^ < len(s) && s[i^] == '}' {
					i^ += 1
				}
				snippet_add_stop(stops, n, start, strings.builder_len(sb^))
			} else {
				// ${VAR} or ${VAR:default}: keep only the default.
				for i^ < len(s) && is_var_char(s[i^]) {
					i^ += 1
				}
				if i^ < len(s) && s[i^] == ':' {
					i^ += 1
					snippet_parse_seq(s, i, true, sb, stops)
				} else {
					for i^ < len(s) && s[i^] != '}' {
						i^ += 1
					}
				}
				if i^ < len(s) && s[i^] == '}' {
					i^ += 1
				}
			}
		case c == '$' && i^ + 1 < len(s) && is_var_char(s[i^ + 1]):
			// $VAR: unknown variables expand to nothing.
			i^ += 1
			for i^ < len(s) && is_var_char(s[i^]) {
				i^ += 1
			}
		case:
			strings.write_byte(sb, c)
			i^ += 1
		}
	}
}

// reindent_snippet prefixes every line after the first with `indent`,
// remapping stop offsets to match.
reindent_snippet :: proc(text: string, stops: []Snippet_Stop, indent: string) -> (string, []Snippet_Stop) {
	if len(indent) == 0 || strings.index_byte(text, '\n') < 0 {
		return text, stops
	}
	shift :: proc(text: string, off, n: int) -> int {
		return off + n * strings.count(text[:min(off, len(text))], "\n")
	}
	out, _ := strings.replace_all(text, "\n", strings.concatenate({"\n", indent}, context.temp_allocator), context.temp_allocator)
	moved := make([]Snippet_Stop, len(stops), context.temp_allocator)
	for st, i in stops {
		moved[i] = {st.index, shift(text, st.start, len(indent)), shift(text, st.end, len(indent))}
	}
	return out, moved
}

// offset_to_position maps a byte offset inside `text` inserted at `at` to
// a buffer position.
@(private)
offset_to_position :: proc(at: buf.Position, text: string, off: int) -> buf.Position {
	p := at
	for i in 0 ..< min(off, len(text)) {
		if text[i] == '\n' {
			p.line += 1
			p.col = 0
		} else {
			p.col += 1
		}
	}
	return p
}

// editor_insert_snippet replaces [start, end) with the expanded snippet
// (one undo step), then selects the first tab stop and starts a session
// if there's anywhere to Tab to.
editor_insert_snippet :: proc(ed: ^Editor, start, end: buf.Position, snippet: string) {
	raw_text, raw_stops := parse_snippet(snippet, context.temp_allocator)
	b := &ed.buf
	// Continuation lines take the insertion line's indentation, like
	// VSCode (snippets are written relative to column 0).
	line := buf.buffer_line_str(b, start.line)
	indent_len := 0
	for indent_len < min(start.col, len(line)) && (line[indent_len] == ' ' || line[indent_len] == '\t') {
		indent_len += 1
	}
	text, stops := reindent_snippet(raw_text, raw_stops[:], line[:indent_len])
	group := buf.buffer_next_group(b)
	if start != end {
		buf.buffer_delete_range(b, start, end, group)
	}
	after := buf.buffer_insert_text(b, start, text, group)
	editor_end_snippet(ed)
	// Hand this insertion to the change consumers now, so it isn't applied
	// a second time to the stops built below (they're already post-edit).
	editor_consume_buffer_changes(ed)

	// Navigation order: 1..n ascending, then $0 (or the end of the text).
	s := &ed.snippet
	for idx in 1 ..= 99 {
		for st in stops {
			if st.index == idx {
				append(&s.stops, Session_Stop{idx, offset_to_position(start, text, st.start), offset_to_position(start, text, st.end)})
			}
		}
	}
	final := after
	for st in stops {
		if st.index == 0 {
			final = offset_to_position(start, text, st.start)
		}
	}
	append(&s.stops, Session_Stop{0, final, final})

	resize(&b.cursors, 1)
	if len(s.stops) > 1 {
		s.active = true
		s.current = 0
		editor_select_snippet_stop(ed)
	} else {
		b.cursors[0] = {pos = final}
		clear(&s.stops)
	}
	editor_ensure_cursor_visible(ed)
}

@(private)
editor_select_snippet_stop :: proc(ed: ^Editor) {
	s := &ed.snippet
	st := s.stops[s.current]
	ed.buf.cursors[0] = {pos = st.end, sel = {anchor = st.start, active = st.start != st.end}}
	editor_ensure_cursor_visible(ed)
}

// editor_snippet_step moves to the next (+1) / previous (-1) stop; moving
// onto the final ($0) stop ends the session.
editor_snippet_step :: proc(ed: ^Editor, dir: int) {
	s := &ed.snippet
	if !s.active {
		return
	}
	s.current = clamp(s.current + dir, 0, len(s.stops) - 1)
	editor_select_snippet_stop(ed)
	if s.current == len(s.stops) - 1 {
		editor_end_snippet(ed)
	}
}

editor_end_snippet :: proc(ed: ^Editor) {
	ed.snippet.active = false
	clear(&ed.snippet.stops)
	ed.snippet.current = 0
}

// snippet_shift_stops keeps stop ranges glued to their text across an
// edit: a stop's start sticks to the left (typing at the start of a
// placeholder grows the stop rather than moving past it).
@(private)
snippet_shift_stops :: proc(ed: ^Editor, ch: buf.Change) {
	for &st in ed.snippet.stops {
		if st.start != ch.start {
			st.start = buf.position_after_change(st.start, ch)
		}
		st.end = buf.position_after_change(st.end, ch)
	}
}

// editor_update_snippet ends the session when the caret leaves the
// current stop (or multiple cursors appear). Called from editor_update.
editor_update_snippet :: proc(ed: ^Editor) {
	s := &ed.snippet
	if !s.active {
		return
	}
	if len(ed.buf.cursors) != 1 {
		editor_end_snippet(ed)
		return
	}
	st := s.stops[s.current]
	p := ed.buf.cursors[0].pos
	if buf.position_less(p, st.start) || buf.position_less(st.end, p) {
		editor_end_snippet(ed)
	}
}
