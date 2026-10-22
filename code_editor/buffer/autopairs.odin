package buffer

import "core:strings"

/*
Auto-closing pairs, as most code editors do them: typing an opening bracket or quote inserts its
closer after the caret; typing the closer next to it steps over it; Backspace between an empty
pair deletes both; typing an opener with text selected wraps the selection; Enter between `{}`,
`()` or `[]` puts the closer on its own line under an indented empty one.

The pairs are `()`, `[]`, `{}`, `""`, `''`, "``" and `<>`, with the usual exceptions:
- An opener closes only before whitespace, the end of the line, or a closing character
  (`) ] } > , ; :`), so `(` typed before a word doesn't add a `)` in front of it.
- A quote doesn't close after a letter, a digit or a backslash (`don't`, `\"`), nor next to the
  same quote.
- `<` is "less than" in most code (`a < b`, `i<<2`): it closes only straight after a word
  character (`Map<`, `vec<`), or anywhere in markup (`Pair_Rules.markup`: XML, HTML).
Every caret is handled, and a pair's insertion is one undo step.
*/

// The opening and closing characters of a pair
Auto_Pair :: struct {
	open, close: u8,
}

AUTO_PAIRS := [?]Auto_Pair{{'(', ')'}, {'[', ']'}, {'{', '}'}, {'"', '"'}, {'\'', '\''}, {'`', '`'}, {'<', '>'}}

// How pairs behave in this buffer
Pair_Rules :: struct {
	// `<` closes anywhere a tag can start (XML, HTML), not only after a word
	markup: bool,
}

// pair_of returns the pair `ch` opens or closes.
pair_of :: proc(ch: u8) -> (pair: Auto_Pair, is_open, is_close: bool) {
	for p in AUTO_PAIRS {
		if p.open == ch do return p, true, p.close == ch
		if p.close == ch do return p, false, true
	}
	return {}, false, false
}

@(private="file")
is_word :: proc(ch: u8) -> bool {
	return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch >= 0x80
}

// The characters an opener may be typed before and still get its closer
@(private="file")
closes_before :: proc(next: u8, at_end: bool) -> bool {
	if at_end do return true
	switch next {
	case ' ', '\t', ')', ']', '}', '>', ',', ';', ':': return true
	}
	return false
}

// should_close is whether typing `pair.open` between `prev` and `next` adds the closer.
@(private="file")
should_close :: proc(pair: Auto_Pair, prev: u8, at_start: bool, next: u8, at_end: bool, rules: Pair_Rules) -> bool {
	if !closes_before(next, at_end) do return false
	if pair.open == pair.close {
		// Quotes: not in the middle of a word (don't), escaped (\"), or beside the same quote
		if !at_start && (is_word(prev) || prev == '\\' || prev == pair.open) do return false
		return true
	}
	if pair.open == '<' && !rules.markup {
		return !at_start && is_word(prev)
	}
	return true
}

/*
buffer_type_paired types one character with the auto-pair rules at every caret.

Returns:
- false (nothing done) when `ch` opens or closes no pair: type it as usual (buffer_type_text)
*/
buffer_type_paired :: proc(b: ^Buffer, ch: u8, rules: Pair_Rules = {}) -> bool {
	pair, is_open, is_close := pair_of(ch)
	if !is_open && !is_close do return false
	group := buffer_next_group(b)
	text := string([]u8{ch})
	order := buffer_sorted_cursor_indices(b)
	for i in order {
		c := &b.cursors[i]
		// An opener with a selection wraps it (the selection stays on the text inside)
		if start, end, has_sel := selection_range(c^); has_sel && is_open {
			buffer_insert_text(b, end, string([]u8{pair.close}), group)
			buffer_insert_text(b, start, text, group)
			inner_end := end
			if end.line == start.line do inner_end.col += 1
			inner_start := Position{start.line, start.col + 1}
			forward := position_less(c.sel.anchor, c.pos) || c.sel.anchor == c.pos
			if forward {
				c.sel.anchor, c.pos = inner_start, inner_end
			} else {
				c.sel.anchor, c.pos = inner_end, inner_start
			}
			continue
		}
		buffer_delete_selection_for_cursor(b, c, group)
		line := buffer_line_str(b, c.pos.line)
		at_end := c.pos.col >= len(line)
		at_start := c.pos.col == 0
		next := at_end ? 0 : line[c.pos.col]
		prev := at_start ? 0 : line[c.pos.col - 1]
		// The closer that's already next is stepped over (not an escaped quote: \" types one)
		if is_close && next == ch && !(pair.open == pair.close && prev == '\\') {
			c.pos.col += 1
			continue
		}
		if is_open && should_close(pair, prev, at_start, next, at_end, rules) {
			buffer_insert_text(b, c.pos, strings.concatenate({text, string([]u8{pair.close})}, context.temp_allocator), group)
			c.pos.col += 1
			c.sel.active = false
			continue
		}
		c.pos = buffer_insert_text(b, c.pos, text, group)
		c.sel.active = false
	}
	// Pairs don't join the typing run's undo step
	b.typing_group = 0
	return true
}

/*
buffer_backspace_pair deletes an empty pair around every caret (`(|)` -> `|`) when every caret
is inside one and nothing is selected.

Returns:
- false (nothing done) when a caret isn't inside an empty pair: Backspace as usual
*/
buffer_backspace_pair :: proc(b: ^Buffer) -> bool {
	for c in b.cursors {
		if c.sel.active do return false
		line := buffer_line_str(b, c.pos.line)
		if c.pos.col == 0 || c.pos.col >= len(line) do return false
		pair, is_open, _ := pair_of(line[c.pos.col - 1])
		if !is_open || line[c.pos.col] != pair.close do return false
	}
	group := buffer_next_group(b)
	for i in buffer_sorted_cursor_indices(b) {
		c := &b.cursors[i]
		start := Position{c.pos.line, c.pos.col - 1}
		buffer_delete_range(b, start, {c.pos.line, c.pos.col + 1}, group)
		c.pos = start
	}
	b.typing_group = 0
	return true
}

/*
buffer_newline_paired is Enter with brackets in mind: between `{}`, `()` or `[]` the closer goes
to its own line under an indented empty one where the caret goes; after an opener alone the new
line is indented one more. Elsewhere it's a plain newline keeping the line's indentation
(buffer_newline).

Inputs:
- use_tabs: Indent with a tab, else INDENT_WIDTH spaces
*/
buffer_newline_paired :: proc(b: ^Buffer, use_tabs := false) {
	group := buffer_next_group(b)
	unit := use_tabs ? "\t" : strings.repeat(" ", INDENT_WIDTH, context.temp_allocator)
	for i in buffer_sorted_cursor_indices(b) {
		c := &b.cursors[i]
		buffer_delete_selection_for_cursor(b, c, group)
		line := buffer_line_str(b, c.pos.line)
		indent_end := 0
		for indent_end < len(line) && (line[indent_end] == ' ' || line[indent_end] == '\t') do indent_end += 1
		indent := strings.clone(line[:indent_end], context.temp_allocator)
		// The last character before the caret that isn't a space
		before := c.pos.col
		for before > 0 && (line[before - 1] == ' ' || line[before - 1] == '\t') do before -= 1
		prev: u8 = before > 0 ? line[before - 1] : 0
		next: u8 = c.pos.col < len(line) ? line[c.pos.col] : 0
		bracket := prev == '{' || prev == '(' || prev == '['
		pair, _, _ := pair_of(prev)
		if bracket && next == pair.close {
			text := strings.concatenate({"\n", indent, unit, "\n", indent}, context.temp_allocator)
			buffer_insert_text(b, c.pos, text, group)
			c.pos = {c.pos.line + 1, len(indent) + len(unit)}
		} else if bracket {
			c.pos = buffer_insert_text(b, c.pos, strings.concatenate({"\n", indent, unit}, context.temp_allocator), group)
		} else {
			c.pos = buffer_insert_text(b, c.pos, strings.concatenate({"\n", indent}, context.temp_allocator), group)
		}
		c.sel.active = false
	}
	b.typing_group = 0
}
