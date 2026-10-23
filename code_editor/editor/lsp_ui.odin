// LSP-driven UI state: the code-completion popup and the signature-help
// tooltip. Pure state logic (no SDL rendering) — triggering, filtering,
// keyboard navigation, and accepting completions. Requests go out through
// the attached `lsp.Client`; responses are picked up in `editor_update` by
// comparing the client's completion_seq/signature_seq counters against the
// last value seen here. Rendering lives in render_popups.odin.
package code_editor

import buf "../buffer"
import lspc "../lsp"
import syn "../syntax"
import "core:slice"
import "core:strings"

COMPLETION_MAX_VISIBLE :: 10
// How far back editor_cursor_in_call looks for an unclosed '('.
SIGNATURE_SCAN_LINES :: 50

Completion_State :: struct {
	active:   bool,
	// A request is in flight and its response hasn't been seen yet.
	waiting:  bool,
	seen_seq: int,
	// Start of the word being completed. The typed prefix is the text
	// between `anchor` and the primary cursor.
	anchor:   buf.Position,
	// Indices into `items` matching the typed prefix, in display order.
	filtered: [dynamic]int,
	// The merged list: the server's last items and the providers' (providers.odin,
	// editor_merge_completions), rebuilt when either answers; items_seq counts the rebuilds
	items:     [dynamic]Completion_Entry,
	items_seq: int,
	// What the completion providers offered at the last request (owned)
	provided:  [dynamic]Provider_Completion,
	selected: int,
	// First visible row of the popup list (for lists longer than
	// COMPLETION_MAX_VISIBLE).
	scroll:   int,
	// Cursor position / buffer version the filter was last computed for.
	last_pos:     buf.Position,
	last_version: int,
	// Typed-prefix length when the request went out; with an incomplete
	// list, a different prefix triggers a re-query.
	request_prefix_len: int,
	// The docs panel's scroll (for the item it shows)
	doc_scroll: Popup_Scroll,
}

Signature_State :: struct {
	active:   bool,
	// Overload chosen with Up/Down (-1: the server's activeSignature);
	// kept across re-queries while the overload count stays the same.
	selected:   int,
	last_count: int,
	waiting:  bool,
	seen_seq: int,
	// Cursor position / buffer version at the last request. While active,
	// any change re-requests so the active parameter tracks the cursor and
	// the tooltip closes once the cursor leaves the call.
	last_pos:     buf.Position,
	last_version: int,
	// The tooltip's scroll, when it's taller than the view leaves it
	scroll: Popup_Scroll,
}

@(private)
is_ident_byte :: proc(ch: u8) -> bool {
	return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch >= 0x80
}

// editor_word_start_before returns the column where the identifier ending
// at `pos` begins (== pos.col if the cursor isn't right after an
// identifier character).
editor_word_start_before :: proc(ed: ^Editor, pos: buf.Position) -> int {
	line := buf.buffer_line_str(&ed.buf, pos.line)
	col := min(pos.col, len(line))
	for col > 0 && is_ident_byte(line[col - 1]) {
		col -= 1
	}
	return col
}

// --- requests -------------------------------------------------------------

// editor_lsp_col converts a buffer position's byte column to the UTF-16
// `character` offset LSP expects.
editor_lsp_col :: proc(ed: ^Editor, pos: buf.Position) -> int {
	return lspc.byte_col_to_utf16(buf.buffer_line_str(&ed.buf, pos.line), pos.col)
}

// editor_request_completion opens the completion popup for the word at the
// primary cursor, asks the completion providers and the attached LSP for
// candidates, and merges them. No-op without either.
editor_request_completion :: proc(ed: ^Editor, trigger := Provider_Trigger.Invoked, trigger_char: u8 = 0) {
	server := editor_lsp_ready(ed)
	if !server && !editor_has_provider(ed, .Completion) {
		return
	}
	if server do editor_sync_lsp(ed)
	c := editor_primary_cursor(ed)
	cs := &ed.completion
	cs.active = true
	cs.waiting = true
	cs.anchor = buf.Position{c.pos.line, editor_word_start_before(ed, c.pos)}
	cs.selected = 0
	cs.scroll = 0
	clear(&cs.filtered)
	cs.request_prefix_len = c.pos.col - cs.anchor.col
	line := buf.buffer_line_str(&ed.buf, c.pos.line)
	editor_query_completion_providers(ed, c.pos, line[cs.anchor.col:min(c.pos.col, len(line))], trigger, trigger_char)
	if !server {
		// Only the providers: their items show now
		cs.waiting = false
		editor_merge_completions(ed)
		editor_refilter_completion(ed)
		return
	}
	lspc.client_request_completion(&ed.lsp, ed.document_uri, c.pos.line, editor_lsp_col(ed, c.pos))
	cs.seen_seq = ed.lsp.completion_seq
}

// editor_request_signature_help opens (or refreshes) the signature-help
// tooltip for the call surrounding the primary cursor.
editor_request_signature_help :: proc(ed: ^Editor) {
	if !editor_lsp_ready(ed) {
		return
	}
	editor_sync_lsp(ed)
	c := editor_primary_cursor(ed)
	ss := &ed.signature
	ss.active = true
	ss.waiting = true
	ss.last_pos = c.pos
	ss.last_version = ed.buf.version
	lspc.client_request_signature_help(&ed.lsp, ed.document_uri, c.pos.line, editor_lsp_col(ed, c.pos))
	ss.seen_seq = ed.lsp.signature_seq
}

editor_close_completion :: proc(ed: ^Editor) {
	ed.completion.active = false
	ed.completion.waiting = false
	clear(&ed.completion.filtered)
}

editor_close_signature_help :: proc(ed: ^Editor) {
	ed.signature.active = false
	ed.signature.waiting = false
}

// --- auto-triggers ----------------------------------------------------------

// editor_after_text_input applies typing-driven triggers after `text` has
// been inserted: '.' opens member completion, the first identifier
// character of a word opens completion, and '(' / ',' open signature help.
// Only applies with a single cursor (popups track the primary cursor).
editor_after_text_input :: proc(ed: ^Editor, text: string) {
	if !editor_completion_available(ed) || len(ed.buf.cursors) != 1 || len(text) == 0 {
		return
	}
	last := text[len(text) - 1]
	switch {
	case last == '.':
		editor_request_completion(ed, .Typed, '.')
	case last == '(' || last == ',':
		editor_request_signature_help(ed)
	case is_ident_byte(last) && ed.completion.active && !completion_prefix_ok(ed):
		// The list was for an earlier word (text typed faster than frames: the update that
		// would close it hasn't run): start again for this one
		editor_close_completion(ed)
		editor_after_text_input(ed, text)
	case is_ident_byte(last) && !ed.completion.active:
		c := editor_primary_cursor(ed)
		start := editor_word_start_before(ed, c.pos)
		line := buf.buffer_line_str(&ed.buf, c.pos.line)
		// Don't pop up for numeric literals.
		if start < c.pos.col && !(line[start] >= '0' && line[start] <= '9') {
			editor_request_completion(ed, .Typed, last)
		}
	}
}

// --- per-frame update -------------------------------------------------------

// editor_update_lsp_ui picks up fresh LSP responses and keeps both popups
// consistent with the current cursor/buffer. Called from editor_update.
editor_update_lsp_ui :: proc(ed: ^Editor) {
	c := editor_primary_cursor(ed)

	cs := &ed.completion
	if cs.active {
		fresh := cs.waiting && ed.lsp_enabled && ed.lsp.completion_seq != cs.seen_seq
		if fresh {
			cs.waiting = false
			cs.seen_seq = ed.lsp.completion_seq
			editor_merge_completions(ed)
		}
		if fresh || c.pos != cs.last_pos || ed.buf.version != cs.last_version {
			editor_refilter_completion(ed)
			// isIncomplete: the server only sent part of the list, so a
			// longer/shorter prefix needs a fresh query, not just filtering.
			if cs.active && !cs.waiting && ed.lsp_enabled && ed.lsp.completion_incomplete {
				if prefix, ok := editor_completion_prefix(ed); ok && len(prefix) != cs.request_prefix_len {
					editor_request_completion(ed)
				}
			}
		}
	}

	if !ed.lsp_enabled {
		return
	}
	ss := &ed.signature
	if ss.active && !editor_cursor_in_call(ed) {
		// OLS treats the position just past a call's ')' as still inside
		// the call, so it keeps answering; close as soon as the cursor is
		// no longer within an unclosed '(' instead.
		editor_close_signature_help(ed)
	}
	if ss.active {
		if ss.waiting && ed.lsp.signature_seq != ss.seen_seq {
			ss.waiting = false
			ss.seen_seq = ed.lsp.signature_seq
			if len(ed.lsp.last_signatures) != ss.last_count {
				ss.selected = -1
				ss.last_count = len(ed.lsp.last_signatures)
			}
			if len(ed.lsp.last_signatures) == 0 {
				editor_close_signature_help(ed)
			}
		}
		if ss.active && !ss.waiting && (c.pos != ss.last_pos || ed.buf.version != ss.last_version) {
			if len(ed.buf.cursors) != 1 {
				editor_close_signature_help(ed)
			} else {
				editor_request_signature_help(ed)
			}
		}
	}
}

// editor_cursor_in_call reports whether the primary cursor sits inside an
// unclosed '(' (looking back up to SIGNATURE_SCAN_LINES lines). Parens in
// strings and comments are ignored, using the buffer's tokenizer.
editor_cursor_in_call :: proc(ed: ^Editor) -> bool {
	c := editor_primary_cursor(ed)
	first := max(0, c.pos.line - SIGNATURE_SCAN_LINES)
	depth := 0
	state := syn.LINE_STATE_NORMAL
	for ln in first ..= c.pos.line {
		line := buf.buffer_line_str(&ed.buf, ln)
		limit := c.pos.col if ln == c.pos.line else len(line)
		tokens, next := ed.language.tokenize(line, state, context.temp_allocator)
		for tok in tokens {
			if tok.kind == .String || tok.kind == .Comment || tok.start >= limit {
				continue
			}
			for i in tok.start ..< min(tok.end, limit) {
				switch line[i] {
				case '(': depth += 1
				case ')': depth = max(0, depth - 1)
				}
			}
		}
		delete(tokens, context.temp_allocator)
		state = next
	}
	return depth > 0
}

@(private)
completion_prefix_ok :: proc(ed: ^Editor) -> bool {
	_, ok := editor_completion_prefix(ed)
	return ok
}

// editor_completion_prefix returns the text typed since the popup opened
// (anchor..cursor). `ok` is false if the cursor has left the word, which
// means the popup should close.
editor_completion_prefix :: proc(ed: ^Editor) -> (prefix: string, ok: bool) {
	cs := &ed.completion
	c := editor_primary_cursor(ed)
	if len(ed.buf.cursors) != 1 || c.pos.line != cs.anchor.line || c.pos.col < cs.anchor.col {
		return "", false
	}
	line := buf.buffer_line_str(&ed.buf, c.pos.line)
	if c.pos.col > len(line) {
		return "", false
	}
	prefix = line[cs.anchor.col:c.pos.col]
	for i in 0 ..< len(prefix) {
		if !is_ident_byte(prefix[i]) {
			return "", false
		}
	}
	return prefix, true
}

// completion_match scores `candidate` against the typed `prefix`
// (case-insensitive): 2 = prefix match, 1 = in-order subsequence match
// starting with the same first character, 0 = no match.
completion_match :: proc(candidate, prefix: string) -> int {
	if len(prefix) == 0 {
		return 2
	}
	if len(candidate) < len(prefix) {
		return 0
	}
	if strings.equal_fold(candidate[:len(prefix)], prefix) {
		return 2
	}
	if to_lower_byte(candidate[0]) != to_lower_byte(prefix[0]) {
		return 0
	}
	pi := 0
	for i in 0 ..< len(candidate) {
		if pi < len(prefix) && to_lower_byte(candidate[i]) == to_lower_byte(prefix[pi]) {
			pi += 1
		}
	}
	return pi == len(prefix) ? 1 : 0
}

@(private)
to_lower_byte :: proc(ch: u8) -> u8 {
	return ch + 32 if ch >= 'A' && ch <= 'Z' else ch
}

// editor_refilter_completion recomputes `filtered` from the latest server
// items and the current prefix, closing the popup when the cursor has left
// the word or (once the response is in) nothing matches.
editor_refilter_completion :: proc(ed: ^Editor) {
	cs := &ed.completion
	cs.last_pos = editor_primary_cursor(ed).pos
	cs.last_version = ed.buf.version

	prefix, ok := editor_completion_prefix(ed)
	if !ok {
		editor_close_completion(ed)
		return
	}
	if cs.waiting {
		// Keep the popup open (empty) until the server answers.
		return
	}

	prev_label := ""
	if cs.selected >= 0 && cs.selected < len(cs.filtered) && cs.filtered[cs.selected] < len(cs.items) {
		prev_label = cs.items[cs.filtered[cs.selected]].item.label
	}

	clear(&cs.filtered)
	// Prefix matches first, then fuzzy matches; within each, higher provider priority first,
	// then the merged list's order (the server's, then the providers')
	for want in ([]int{2, 1}) {
		first := len(cs.filtered)
		for en, i in cs.items {
			key := en.item.filter_text if len(en.item.filter_text) > 0 else en.item.label
			if completion_match(key, prefix) == want {
				append(&cs.filtered, i)
			}
		}
		Ranked :: struct { items: []Completion_Entry }
		context.user_ptr = &Ranked{cs.items[:]}
		slice.stable_sort_by(cs.filtered[first:], proc(a, b: int) -> bool {
			items := (^Ranked)(context.user_ptr).items
			return items[a].priority > items[b].priority
		})
	}
	if len(cs.filtered) == 0 {
		editor_close_completion(ed)
		return
	}

	// Keep the same item selected across refilters when it's still listed.
	cs.selected = 0
	for idx, row in cs.filtered {
		if cs.items[idx].item.label == prev_label {
			cs.selected = row
			break
		}
	}
	editor_completion_clamp_scroll(ed)
}

// --- popup interaction ------------------------------------------------------

// editor_completion_visible reports whether the completion list is
// currently shown (active and has at least one matching item).
editor_completion_visible :: proc(ed: ^Editor) -> bool {
	return ed.completion.active && len(ed.completion.filtered) > 0
}

editor_signature_visible :: proc(ed: ^Editor) -> bool {
	return ed.signature.active && len(ed.lsp.last_signatures) > 0
}

// editor_completion_selected_item returns the highlighted completion item.
editor_completion_selected_item :: proc(ed: ^Editor) -> (item: lspc.CompletionItem, ok: bool) {
	if !editor_completion_visible(ed) {
		return {}, false
	}
	return ed.completion.items[ed.completion.filtered[ed.completion.selected]].item, true
}

editor_completion_move :: proc(ed: ^Editor, delta: int) {
	cs := &ed.completion
	n := len(cs.filtered)
	if n == 0 {
		return
	}
	if delta == 1 || delta == -1 {
		// Single steps wrap around, like VSCode.
		cs.selected = (cs.selected + delta + n) % n
	} else {
		cs.selected = clamp(cs.selected + delta, 0, n - 1)
	}
	editor_completion_clamp_scroll(ed)
}

@(private)
editor_completion_clamp_scroll :: proc(ed: ^Editor) {
	cs := &ed.completion
	cs.scroll = overlay_scroll_reveal(cs.scroll, cs.selected, len(cs.filtered), editor_completion_rows(ed))
}

// editor_completion_rows is how many rows the completion list shows: up to
// COMPLETION_MAX_VISIBLE, fewer when the view is too short for them (the list scrolls).
editor_completion_rows :: proc(ed: ^Editor) -> int {
	if rows := editor_popup_layout(ed).completion_rows; rows > 0 {
		return rows
	}
	return COMPLETION_MAX_VISIBLE
}

// editor_accept_completion replaces the typed prefix with the selected
// item's insert text (as one undo step) and closes the popup.
editor_accept_completion :: proc(ed: ^Editor) -> bool {
	item, ok := editor_completion_selected_item(ed)
	if !ok {
		return false
	}
	c := editor_primary_cursor(ed)
	text := item.insert_text if len(item.insert_text) > 0 else item.label

	start := ed.completion.anchor
	if item.has_text_edit && item.text_edit_range.start.line == c.pos.line {
		line := buf.buffer_line_str(&ed.buf, c.pos.line)
		start.col = clamp(lspc.utf16_col_to_byte(line, item.text_edit_range.start.character), 0, c.pos.col)
	}

	b := &ed.buf
	c.sel.active = false
	end := c.pos
	// The item's other edits (an import it brings in), in the document as it was: those after
	// the completion now, those before it after it, moving the caret with them
	Pending :: struct { start, end: buf.Position, text: string }
	before := make([dynamic]Pending, context.temp_allocator)
	after := make([dynamic]Pending, context.temp_allocator)
	for e in item.additional_edits {
		to_pos :: proc(b: ^buf.Buffer, p: lspc.Position) -> buf.Position {
			line := clamp(p.line, 0, buf.buffer_line_count(b) - 1)
			return {line, lspc.utf16_col_to_byte(buf.buffer_line_str(b, line), p.character)}
		}
		p := Pending{to_pos(b, e.range.start), to_pos(b, e.range.end), strings.clone(e.new_text, context.temp_allocator)}
		if buf.position_less(p.start, start) do append(&before, p)
		else do append(&after, p)
	}
	// Last first, so earlier positions stay right
	later :: proc(a, b: Pending) -> bool { return buf.position_less(b.start, a.start) }
	slice.sort_by(before[:], later)
	slice.sort_by(after[:], later)
	extra := buf.buffer_next_group(b)
	apply :: proc(b: ^buf.Buffer, p: Pending, group: int) -> buf.Change {
		if buf.position_less(p.start, p.end) do buf.buffer_delete_range(b, p.start, p.end, group)
		new_end := p.start
		if len(p.text) > 0 do new_end = buf.buffer_insert_text(b, p.start, p.text, group)
		return {start = p.start, old_end = p.end, new_end = new_end}
	}
	for p in after do apply(b, p, extra)
	defer for p in before {
		ch := apply(b, p, extra)
		cursor := editor_primary_cursor(ed)
		cursor.pos = buf.position_after_change(cursor.pos, ch)
		editor_ensure_cursor_visible(ed)
	}
	editor_close_completion(ed)
	if item.is_snippet {
		editor_insert_snippet(ed, start, end, text)
	} else {
		group := extra
		if start.col < end.col {
			buf.buffer_delete_range(b, start, end, group)
		}
		editor_primary_cursor(ed).pos = buf.buffer_insert_text(b, start, text, group)
		editor_ensure_cursor_visible(ed)
	}
	// e.g. OLS inserts `name($0)` and asks for parameter hints.
	if item.command == "editor.action.triggerParameterHints" {
		editor_request_signature_help(ed)
	}
	return true
}

// editor_signature_active_parts splits the active signature's label into
// (before, active-parameter, after) so the renderer can highlight the
// parameter under the cursor. `active` is empty if it can't be located.
editor_signature_active_parts :: proc(ed: ^Editor) -> (label, before, active, after: string) {
	sigs := ed.lsp.last_signatures[:]
	if len(sigs) == 0 {
		return
	}
	sig := sigs[editor_signature_index(ed)]
	label = sig.label
	param_index := sig.active_parameter if sig.active_parameter >= 0 else ed.lsp.active_parameter
	if param_index < 0 || param_index >= len(sig.parameters) {
		return label, label, "", ""
	}

	// Parameter labels are substrings of the signature label; walk them in
	// order (starting after the opening paren) so repeated names like
	// `a: int, b: int` resolve to the right occurrence.
	search_from := strings.index_byte(label, '(') + 1
	for p, i in sig.parameters {
		if len(p.label) == 0 {
			continue
		}
		rel := strings.index(label[search_from:], p.label)
		if rel < 0 {
			return label, label, "", ""
		}
		start := search_from + rel
		end := start + len(p.label)
		if i == param_index {
			return label, label[:start], label[start:end], label[end:]
		}
		search_from = end
	}
	return label, label, "", ""
}

// editor_signature_index is the overload being shown: the user's Up/Down
// choice, else the server's activeSignature.
editor_signature_index :: proc(ed: ^Editor) -> int {
	n := len(ed.lsp.last_signatures)
	if n == 0 {
		return 0
	}
	if ed.signature.selected >= 0 && ed.signature.selected < n {
		return ed.signature.selected
	}
	return clamp(ed.lsp.active_signature, 0, n - 1)
}

// editor_signature_active_param returns the label of the parameter the
// cursor is currently in (empty if unknown).
editor_signature_active_param :: proc(ed: ^Editor) -> string {
	_, _, active, _ := editor_signature_active_parts(ed)
	return active
}
