// Quick fixes / code actions (textDocument/codeAction): Ctrl/Cmd+. asks
// the server for actions at the cursor (or selection), passing the
// diagnostics there; the results show in a popup list at the caret
// (Up/Down/Enter/Tab/Escape or click). Applying an action performs its
// WorkspaceEdit on the open document as one undo step; edits aimed at
// other files are skipped (and counted) since the editor only owns this
// buffer.
package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:slice"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

CODE_ACTION_MAX_VISIBLE :: 8

Code_Action_Menu :: struct {
	active:   bool,
	waiting:  bool,
	seen_seq: int,
	selected: int,
	// The first action shown (a long list, or a short view, scrolls)
	scroll:   int,
	anchor:   buf.Position, // caret position when requested
	// Result of the last apply, for hosts/tests: edits applied and edits
	// skipped because they targeted another file.
	last_applied, last_skipped: int,
}

// editor_request_code_actions opens the menu and asks the server for
// actions over the primary selection (or at the caret).
editor_request_code_actions :: proc(ed: ^Editor) {
	if !editor_lsp_ready(ed) {
		return
	}
	editor_sync_lsp(ed)
	editor_close_completion(ed)
	c := editor_primary_cursor(ed)
	start, end, has_sel := buf.selection_range(c^)
	if !has_sel {
		start, end = c.pos, c.pos
	}
	rng := lspc.Range{
		start = {start.line, editor_lsp_col(ed, start)},
		end   = {end.line, editor_lsp_col(ed, end)},
	}
	// Pass along the server's own diagnostics touching these lines.
	ctx := make([dynamic]lspc.Diagnostic, context.temp_allocator)
	for d in lspc.client_diagnostics_for_key(&ed.lsp, ed.document_key) {
		if d.range.start.line <= end.line && d.range.end.line >= start.line {
			append(&ctx, d)
		}
	}
	m := &ed.actions
	m.active = true
	m.waiting = true
	m.selected = 0
	m.scroll = 0
	m.anchor = c.pos
	lspc.client_request_code_action(&ed.lsp, ed.document_uri, rng, ctx[:])
	m.seen_seq = ed.lsp.code_action_seq
}

editor_close_code_actions :: proc(ed: ^Editor) {
	ed.actions.active = false
	ed.actions.waiting = false
}

// editor_code_actions_visible: the menu is showing (possibly with a "no
// actions" placeholder once the server answered with nothing).
editor_code_actions_visible :: proc(ed: ^Editor) -> bool {
	return ed.actions.active && !ed.actions.waiting
}

// editor_update_code_actions picks up the response and closes the menu if
// the caret moved away. Called from editor_update.
editor_update_code_actions :: proc(ed: ^Editor) {
	m := &ed.actions
	if !m.active {
		return
	}
	if editor_primary_cursor(ed).pos != m.anchor || !ed.lsp_enabled {
		editor_close_code_actions(ed)
		return
	}
	if m.waiting && ed.lsp.code_action_seq != m.seen_seq {
		m.waiting = false
		m.seen_seq = ed.lsp.code_action_seq
		// Preferred actions first, like VSCode.
		for a, i in ed.lsp.last_code_actions {
			if a.preferred {
				m.selected = i
				break
			}
		}
	}
}

editor_code_actions_move :: proc(ed: ^Editor, delta: int) {
	n := len(ed.lsp.last_code_actions)
	if n > 0 {
		ed.actions.selected = (ed.actions.selected + delta + n) % n
		ed.actions.scroll = overlay_scroll_reveal(ed.actions.scroll, ed.actions.selected, n, editor_code_actions_rows(ed))
	}
}

// editor_apply_code_action applies action `index` of the last response.
editor_apply_code_action :: proc(ed: ^Editor, index: int) -> bool {
	actions := ed.lsp.last_code_actions[:]
	editor_close_code_actions(ed)
	if index < 0 || index >= len(actions) {
		return false
	}
	Resolved :: struct {
		start, end: buf.Position,
		text:       string,
	}
	edits := make([dynamic]Resolved, context.temp_allocator)
	skipped := 0
	for e in actions[index].edits {
		if e.key != ed.document_key {
			skipped += 1
			continue
		}
		count := buf.buffer_line_count(&ed.buf)
		append(&edits, Resolved{to_buffer_pos(ed, e.range.start, count), to_buffer_pos(ed, e.range.end, count), e.new_text})
	}
	// Apply bottom-up so earlier positions stay valid.
	slice.sort_by(edits[:], proc(a, b: Resolved) -> bool {return buf.position_less(b.start, a.start)})

	b := &ed.buf
	group := buf.buffer_next_group(b)
	for e in edits {
		ch := buf.Change{start = e.start, old_end = e.end}
		if e.start != e.end {
			buf.buffer_delete_range(b, e.start, e.end, group)
		}
		ch.new_end = e.start
		if len(e.text) > 0 {
			ch.new_end = buf.buffer_insert_text(b, e.start, e.text, group)
		}
		for &c in b.cursors {
			c.pos = buf.position_after_change(c.pos, ch)
			c.sel.active = false
		}
	}
	ed.actions.last_applied = len(edits)
	ed.actions.last_skipped = skipped
	editor_ensure_cursor_visible(ed)
	return len(edits) > 0
}

// --- layout & rendering -------------------------------------------------------

// editor_code_actions_layout places the menu under the caret (above it
// near the bottom of the view).
editor_code_actions_layout :: proc(ed: ^Editor) -> (rect: sdl.FRect, ok: bool) {
	if !editor_code_actions_visible(ed) {
		return
	}
	widest := len("No code actions available")
	for a in ed.lsp.last_code_actions {
		widest = max(widest, text_cols(a.title) + 2)
	}
	wanted := clamp(len(ed.lsp.last_code_actions), 1, CODE_ACTION_MAX_VISIBLE)
	// Room for the scrollbar
	w := f32(widest + 1) * ed.char_w + 2 * POPUP_PAD
	cx, cy := editor_cursor_screen_pos(ed)
	// Under the caret, else above; in a short view as many rows as fit (it scrolls)
	y, h, _ := place_popup(ed, wanted, cy, cy + ed.char_h, prefer_above = false)
	left := ed.origin_x + editor_gutter_width(ed)
	right := left + f32(ed.visible_cols) * ed.char_w
	w = min(w, right - left) // titles are cut to fit
	return {clamp(cx, left, max(left, right - w)), y, w, h}, true
}

@(private)
render_code_actions :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	rect, ok := editor_code_actions_layout(ed)
	if !ok || font == nil {
		return
	}
	draw_popup_box(renderer, rect, theme)
	actions := ed.lsp.last_code_actions[:]
	if len(actions) == 0 {
		draw_text(renderer, font, "No code actions available", rect.x + POPUP_PAD, rect.y + POPUP_PAD, theme.popup_text_dim, ed.char_h)
		return
	}
	rows := popup_rows_of(ed, rect)
	scroll := overlay_scroll_clamp(ed.actions.scroll, len(actions), rows)
	render_overlay_scrollbar(renderer, rect, len(actions), rows, scroll, theme)
	for a, row in actions[scroll:min(len(actions), scroll + rows)] {
		i := scroll + row
		y := rect.y + POPUP_PAD + f32(row) * ed.char_h
		if i == ed.actions.selected {
			fill_rect(renderer, {rect.x + 1, y, rect.w - 2, ed.char_h}, theme.popup_selected)
		}
		marker := "* " if a.preferred else "  "
		draw_text(renderer, font, marker, rect.x + POPUP_PAD, y, theme.popup_active_param, ed.char_h)
		room := int((rect.w - 2 * POPUP_PAD) / ed.char_w) - 3
		draw_text(renderer, font, truncate_cols(a.title, max(room, 1)), rect.x + POPUP_PAD + 2 * ed.char_w, y, theme.popup_text, ed.char_h)
	}
}

// editor_code_actions_rows is how many actions the menu shows (the rest scroll)
editor_code_actions_rows :: proc(ed: ^Editor) -> int {
	rect, ok := editor_code_actions_layout(ed)
	return popup_rows_of(ed, rect) if ok else CODE_ACTION_MAX_VISIBLE
}
