// Quick fixes / code actions (textDocument/codeAction): Ctrl/Cmd+. asks
// the server for actions at the cursor (or selection), passing the
// diagnostics there; the results show in a popup list at the caret
// (Up/Down/Enter/Tab/Escape or click). Applying an action performs its
// WorkspaceEdit on the open document as one undo step; edits aimed at
// other files are skipped (and counted) since the editor only owns this
// buffer. Quick fixes of the providers' diagnostics at the caret
// (`Provider_Diagnostic.fixes`) come first, and show at once (also without
// a server). The same menu lists a gutter marker's choices when it has several
// (`Gutter_Marker.choices`: the nodes using a script, say); picking one calls
// the marker's provider with it. A drop asking for its menu
// (`Drop_Request.menu`) lists the drop provider's choices here too, with a
// preview of the selected one's code beside the menu.
package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:slice"
import "core:strings"
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
	// The providers' quick fixes at the caret when it opened (owned), listed
	// before the server's actions
	fixes: []Provider_Fix,
	// A gutter marker's choices (owned): listed instead of fixes and actions,
	// and the gutter provider (its index) and marker they're for (its line,
	// icon and id; not its strings)
	choices:         []string,
	choice_provider: int,
	choice_marker:   Gutter_Marker,
	// A drop's choices (owned): listed instead of the rest, the selected one's preview shown
	drops:           []Drop_Choice,
	// The message of the last drop choice applied ("" none), for the host's log (owned)
	drop_message:    string,
}

// How many entries the menu lists: the providers' fixes, then the server's actions
editor_code_action_count :: proc(ed: ^Editor) -> int {
	if ed.actions.choices != nil do return len(ed.actions.choices)
	if ed.actions.drops != nil do return len(ed.actions.drops)
	return len(ed.actions.fixes) + (len(ed.lsp.last_code_actions) if ed.lsp_enabled && !ed.actions.waiting else 0)
}

// An entry's title, and whether it's preferred
editor_code_action_title :: proc(ed: ^Editor, index: int) -> (title: string, preferred: bool) {
	if ed.actions.choices != nil do return ed.actions.choices[index], false
	if ed.actions.drops != nil do return ed.actions.drops[index].title, index == 0
	if index < len(ed.actions.fixes) do return ed.actions.fixes[index].title, ed.actions.fixes[index].preferred
	a := ed.lsp.last_code_actions[index - len(ed.actions.fixes)]
	return a.title, a.preferred
}

// editor_request_code_actions opens the menu and asks the server for
// actions over the primary selection (or at the caret).
editor_request_code_actions :: proc(ed: ^Editor) {
	server := editor_lsp_ready(ed)
	c := editor_primary_cursor(ed)
	editor_consume_buffer_changes(ed)
	fixes := editor_provider_fixes_at(ed, c.pos)
	if !server && len(fixes) == 0 {
		return
	}
	editor_close_completion(ed)
	m := &ed.actions
	provider_fixes_free(m.fixes)
	m.fixes = provider_fixes_clone(fixes)
	m.active = true
	m.waiting = server
	m.selected = 0
	m.scroll = 0
	m.anchor = c.pos
	for f, i in m.fixes {
		if f.preferred {
			m.selected = i
			break
		}
	}
	if !server {
		return
	}
	editor_sync_lsp(ed)
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
	lspc.client_request_code_action(&ed.lsp, ed.document_uri, rng, ctx[:])
	m.seen_seq = ed.lsp.code_action_seq
}

editor_close_code_actions :: proc(ed: ^Editor) {
	ed.actions.active = false
	ed.actions.waiting = false
	provider_fixes_free(ed.actions.fixes)
	ed.actions.fixes = nil
	marker_choices_free(ed.actions.choices)
	ed.actions.choices = nil
	drop_choices_free(ed.actions.drops)
	ed.actions.drops = nil
}

// Frees a drop menu's choices
@(private)
drop_choices_free :: proc(drops: []Drop_Choice) {
	for d in drops {
		delete(d.title)
		delete(d.preview)
		delete(d.message)
		for e in d.edits do delete(e.text)
		delete(d.edits)
	}
	delete(drops)
}

/*
Opens the menu of a drop's choices (a drop that asked for it, `Drop_Request.menu`), the caret at
the drop's position; the first is selected. Picking one applies its edits as one undo step;
Escape or a click elsewhere drops nothing.
*/
editor_open_drop_menu :: proc(ed: ^Editor, pos: buf.Position, choices: []Drop_Choice) {
	editor_close_completion(ed)
	editor_close_code_actions(ed)
	b := &ed.buf
	resize(&b.cursors, 1)
	b.cursors[0] = {pos = buf.buffer_clamp_position(b, pos)}
	m := &ed.actions
	m.active = true
	m.waiting = false
	m.selected = 0
	m.scroll = 0
	m.anchor = b.cursors[0].pos
	m.drops = make([]Drop_Choice, len(choices))
	for c, i in choices {
		edits := make([]Text_Edit, len(c.edits))
		for e, j in c.edits do edits[j] = {start = e.start, end = e.end, text = strings.clone(e.text)}
		m.drops[i] = {title = strings.clone(c.title), preview = strings.clone(c.preview), edits = edits, caret = c.caret, message = strings.clone(c.message)}
	}
	editor_ensure_cursor_visible(ed)
}

// The message of the drop choice picked last, once ("" none; temp allocated)
editor_take_drop_message :: proc(ed: ^Editor) -> string {
	message := strings.clone(ed.actions.drop_message, context.temp_allocator)
	delete(ed.actions.drop_message)
	ed.actions.drop_message = ""
	return message
}

/*
Opens the menu of a gutter marker's choices (a click on a marker with several), the caret at the
start of its line. Picking one calls the marker's provider with it (`Gutter_Marker.choice`).
*/
editor_open_marker_menu :: proc(ed: ^Editor, provider: int, marker: Gutter_Marker) {
	editor_close_completion(ed)
	editor_close_code_actions(ed)
	b := &ed.buf
	resize(&b.cursors, 1)
	b.cursors[0] = {pos = {marker.line, 0}}
	m := &ed.actions
	m.active = true
	m.waiting = false
	m.selected = 0
	m.scroll = 0
	m.anchor = b.cursors[0].pos
	m.choices = make([]string, len(marker.choices))
	for c, i in marker.choices do m.choices[i] = strings.clone(c)
	m.choice_provider = provider
	m.choice_marker = Gutter_Marker{line = marker.line, icon = marker.icon, color = marker.color, id = marker.id}
	editor_ensure_cursor_visible(ed)
}

// editor_code_actions_visible: the menu is showing (possibly with a "no
// actions" placeholder once the server answered with nothing). The providers'
// fixes show while the server's answer is still coming.
editor_code_actions_visible :: proc(ed: ^Editor) -> bool {
	return ed.actions.active && (!ed.actions.waiting || len(ed.actions.fixes) > 0)
}

// editor_update_code_actions picks up the response and closes the menu if
// the caret moved away. Called from editor_update.
editor_update_code_actions :: proc(ed: ^Editor) {
	m := &ed.actions
	if !m.active {
		return
	}
	if editor_primary_cursor(ed).pos != m.anchor || !ed.lsp_enabled && len(m.fixes) == 0 && m.choices == nil && m.drops == nil {
		editor_close_code_actions(ed)
		return
	}
	if m.waiting && !ed.lsp_enabled {
		m.waiting = false
	}
	if m.waiting && ed.lsp.code_action_seq != m.seen_seq {
		m.waiting = false
		m.seen_seq = ed.lsp.code_action_seq
		// Preferred actions first, like VSCode (a provider's preferred fix stays selected)
		preferred_fix := false
		for f in m.fixes do preferred_fix ||= f.preferred
		if !preferred_fix {
			for a, i in ed.lsp.last_code_actions {
				if a.preferred {
					m.selected = len(m.fixes) + i
					break
				}
			}
		}
	}
}

editor_code_actions_move :: proc(ed: ^Editor, delta: int) {
	n := editor_code_action_count(ed)
	if n > 0 {
		ed.actions.selected = (ed.actions.selected + delta + n) % n
		ed.actions.scroll = overlay_scroll_reveal(ed.actions.scroll, ed.actions.selected, n, editor_code_actions_rows(ed))
	}
}

// editor_apply_code_action applies entry `index` of the menu: a provider's
// fix, or an action of the server's last response.
editor_apply_code_action :: proc(ed: ^Editor, index: int) -> bool {
	if ed.actions.choices != nil {
		provider, marker, count := ed.actions.choice_provider, ed.actions.choice_marker, len(ed.actions.choices)
		editor_close_code_actions(ed)
		if index < 0 || index >= count do return false
		editor_choose_marker(ed, provider, marker, index)
		return true
	}
	if ed.actions.drops != nil {
		drops := ed.actions.drops
		ed.actions.drops = nil
		defer drop_choices_free(drops)
		editor_close_code_actions(ed)
		if index < 0 || index >= len(drops) do return false
		editor_apply_edits(ed, drops[index].edits, drops[index].caret)
		delete(ed.actions.drop_message)
		ed.actions.drop_message = strings.clone(drops[index].message)
		ed.actions.last_applied = len(drops[index].edits)
		ed.actions.last_skipped = 0
		return true
	}
	if index >= 0 && index < len(ed.actions.fixes) {
		edits := slice.clone(ed.actions.fixes[index].edits, context.temp_allocator)
		for &e in edits do e.text = strings.clone(e.text, context.temp_allocator)
		editor_close_code_actions(ed)
		editor_apply_edits(ed, edits)
		ed.actions.last_applied = len(edits)
		ed.actions.last_skipped = 0
		return len(edits) > 0
	}
	index := index - len(ed.actions.fixes)
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
	count := editor_code_action_count(ed)
	for i in 0 ..< count {
		title, _ := editor_code_action_title(ed, i)
		widest = max(widest, text_cols(title) + 2)
	}
	wanted := clamp(count, 1, CODE_ACTION_MAX_VISIBLE)
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
	count := editor_code_action_count(ed)
	if count == 0 {
		draw_text(renderer, font, "No code actions available", rect.x + POPUP_PAD, rect.y + POPUP_PAD, theme.popup_text_dim, ed.char_h)
		return
	}
	rows := popup_rows_of(ed, rect)
	scroll := overlay_scroll_clamp(ed.actions.scroll, count, rows)
	render_overlay_scrollbar(renderer, rect, count, rows, scroll, theme)
	for i in scroll ..< min(count, scroll + rows) {
		row := i - scroll
		title, preferred := editor_code_action_title(ed, i)
		y := rect.y + POPUP_PAD + f32(row) * ed.char_h
		if i == ed.actions.selected {
			fill_rect(renderer, {rect.x + 1, y, rect.w - 2, ed.char_h}, theme.popup_selected)
		}
		marker := "* " if preferred else "  "
		draw_text(renderer, font, marker, rect.x + POPUP_PAD, y, theme.popup_active_param, ed.char_h)
		room := int((rect.w - 2 * POPUP_PAD) / ed.char_w) - 3
		draw_text(renderer, font, truncate_cols(title, max(room, 1)), rect.x + POPUP_PAD + 2 * ed.char_w, y, theme.popup_text, ed.char_h)
	}
	// A drop's choices: the selected one's code
	if lines, prect, shown := editor_drop_preview_layout(ed); shown {
		draw_popup_box(renderer, prect, theme)
		room := max(int((prect.w - 2 * POPUP_PAD) / ed.char_w), 1)
		for line, i in lines {
			draw_code_line(ed, renderer, font, theme, truncate_cols(line, room), prect.x + POPUP_PAD, prect.y + POPUP_PAD + f32(i) * ed.char_h)
		}
	}
}

// The most lines a drop choice's preview shows
DROP_PREVIEW_MAX_LINES :: 8

/*
Where the selected drop choice's preview goes: under the menu, else above it, as wide as its
longest line allows in the view. Tabs show as four spaces.

Returns:
- Its lines (temp allocated), its rect, and whether one shows
*/
editor_drop_preview_layout :: proc(ed: ^Editor) -> (lines: []string, rect: sdl.FRect, ok: bool) {
	m := &ed.actions
	if m.drops == nil || m.selected < 0 || m.selected >= len(m.drops) do return
	menu, shown := editor_code_actions_layout(ed)
	if !shown do return
	text, _ := strings.replace_all(strings.trim_right(m.drops[m.selected].preview, "\n"), "\t", "    ", context.temp_allocator)
	if text == "" do return
	all := strings.split_lines(text, context.temp_allocator)
	lines = all[:min(len(all), DROP_PREVIEW_MAX_LINES)]
	widest := 0
	for l in lines do widest = max(widest, text_cols(l))
	left := ed.origin_x + editor_gutter_width(ed)
	right := left + f32(ed.visible_cols) * ed.char_w
	w := min(f32(widest) * ed.char_w + 2 * POPUP_PAD, right - left)
	h := f32(len(lines)) * ed.char_h + 2 * POPUP_PAD
	x := clamp(menu.x, left, max(left, right - w))
	y := menu.y + menu.h + 2
	if y + h > overlay_view_bottom(ed) && menu.y - h - 2 >= overlay_view_top(ed) do y = menu.y - h - 2
	return lines, {x, y, w, h}, true
}

// editor_code_actions_rows is how many actions the menu shows (the rest scroll)
editor_code_actions_rows :: proc(ed: ^Editor) -> int {
	rect, ok := editor_code_actions_layout(ed)
	return popup_rows_of(ed, rect) if ok else CODE_ACTION_MAX_VISIBLE
}
