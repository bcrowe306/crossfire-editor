// Mouse extras: the right-click context menu, drag-and-drop of selected
// text (move, or copy with Alt/Option on macOS and Ctrl elsewhere — like
// VSCode; either modifier works everywhere), and LSP hover info shown after the pointer rests on code.
package code_editor

import buf "../buffer"
import km "../keymap"
import lspc "../lsp"
import "core:fmt"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

DRAG_MOVE_THRESHOLD :: 4 // pixels before a press inside a selection becomes a drag

// --- context menu ---------------------------------------------------------------

Context_Menu :: struct {
	open:     bool,
	x, y:     f32, // where it was opened (window pixels)
	selected: int,
	// The first item shown, when the view is too short for them all
	scroll:   int,
}

Menu_Item :: struct {
	label:   string,
	action:  km.Action,
	enabled: bool, // separators have label == ""
}

// editor_context_menu_items lists the menu entries for the current state.
editor_context_menu_items :: proc(ed: ^Editor) -> []Menu_Item {
	_, _, has_sel := buf.selection_range(editor_primary_cursor(ed)^)
	items := make([dynamic]Menu_Item, context.temp_allocator)
	ready := editor_lsp_ready(ed)
	append(&items, Menu_Item{"Go to Definition", .GotoDefinition, ready})
	append(&items, Menu_Item{"Peek Definition", .PeekDefinition, ready})
	append(&items, Menu_Item{"Find All References", .FindReferences, ready})
	append(&items, Menu_Item{"", .None, false})
	append(&items, Menu_Item{"Cut", .Cut, has_sel})
	append(&items, Menu_Item{"Copy", .Copy, has_sel})
	append(&items, Menu_Item{"Paste", .Paste, true})
	append(&items, Menu_Item{"", .None, false})
	append(&items, Menu_Item{"Select All", .SelectAll, true})
	append(&items, Menu_Item{"Select All Occurrences", .SelectAllOccurrences, true})
	append(&items, Menu_Item{"", .None, false})
	append(&items, Menu_Item{"Quick Fix...", .QuickFix, editor_lsp_ready(ed)})
	append(&items, Menu_Item{"Find", .Find, true})
	append(&items, Menu_Item{"Go to Next Problem", .NextDiagnostic, len(editor_diagnostics(ed)) > 0})
	return items[:]
}

// chord_label renders the key bound to `action` ("Ctrl+X", "Cmd+Shift+L").
chord_label :: proc(ed: ^Editor, action: km.Action) -> string {
	best: km.Chord
	found := false
	for chord, a in ed.keymap.bindings {
		if a == action && (!found || card(chord.mods) < card(best.mods) || (card(chord.mods) == card(best.mods) && chord.key < best.key)) {
			best, found = chord, true
		}
	}
	if !found {
		return ""
	}
	return chord_text(best)
}

// chord_text renders a chord for display ("Cmd+Shift+/").
chord_text :: proc(best: km.Chord) -> string {
	sb := strings.builder_make(context.temp_allocator)
	if .Ctrl in best.mods {strings.write_string(&sb, "Ctrl+")}
	if .Super in best.mods {strings.write_string(&sb, "Cmd+")}
	if .Alt in best.mods {strings.write_string(&sb, "Alt+")}
	if .Shift in best.mods {strings.write_string(&sb, "Shift+")}
	name := fmt.tprint(best.key)
	#partial switch best.key {
	case .Period: name = "."
	case .Comma: name = ","
	case .Equals: name = "="
	case .Minus: name = "-"
	case .Slash: name = "/"
	case .Backslash: name = "\\"
	case .LeftBracket: name = "["
	case .RightBracket: name = "]"
	case .Semicolon: name = ";"
	case .Quote: name = "'"
	case .Grave: name = "`"
	case .Num0 ..= .Num9: name = name[3:]
	}
	strings.write_string(&sb, name)
	return strings.to_string(sb)
}

editor_open_context_menu :: proc(ed: ^Editor, x, y: f32) {
	editor_close_completion(ed)
	ed.menu = {open = true, x = x, y = y, selected = -1}
}

editor_close_context_menu :: proc(ed: ^Editor) {
	ed.menu.open = false
}

// editor_context_menu_layout returns the menu rectangle (clamped into the
// editor) and the label / shortcut column widths in cells.
editor_context_menu_layout :: proc(ed: ^Editor) -> (rect: sdl.FRect, ok: bool) {
	if !ed.menu.open {
		return
	}
	items := editor_context_menu_items(ed)
	cols := 0
	for it in items {
		cols = max(cols, text_cols(it.label) + 4 + text_cols(chord_label(ed, it.action)))
	}
	// Room for the scrollbar
	w := f32(cols + 1) * ed.char_w + 2 * POPUP_PAD
	left := ed.origin_x
	right := ed.origin_x + editor_gutter_width(ed) + f32(ed.visible_cols) * ed.char_w
	bottom := ed.origin_y + f32(ed.visible_rows) * ed.char_h
	w = min(w, right - left) // labels are cut to fit
	x := clamp(ed.menu.x, left, max(left, right - w))
	// Below the pointer, else above it; in a short view on the roomier side, as many items as fit
	full := f32(len(items)) * ed.char_h + 2 * POPUP_PAD
	room_below := bottom - ed.menu.y
	room_above := ed.menu.y - ed.origin_y
	below := full <= room_below || (full > room_above && room_below >= room_above)
	rows := overlay_rows_fit(ed, below ? room_below : room_above, len(items))
	h := f32(rows) * ed.char_h + 2 * POPUP_PAD
	y := below ? ed.menu.y : ed.menu.y - h
	return {x, y, w, h}, true
}

// editor_context_menu_activate runs item `index` (if enabled) and closes.
editor_context_menu_activate :: proc(ed: ^Editor, index: int) {
	items := editor_context_menu_items(ed)
	editor_close_context_menu(ed)
	if index < 0 || index >= len(items) || !items[index].enabled {
		return
	}
	editor_run_action(ed, items[index].action)
}

// editor_context_menu_move steps the highlight, skipping separators and
// disabled entries.
editor_context_menu_move :: proc(ed: ^Editor, dir: int) {
	items := editor_context_menu_items(ed)
	n := len(items)
	i := ed.menu.selected
	for _ in 0 ..< n {
		i = (i + dir + n) % n if i >= 0 else (0 if dir > 0 else n - 1)
		if items[i].enabled {
			ed.menu.selected = i
			if rect, ok := editor_context_menu_layout(ed); ok {
				ed.menu.scroll = overlay_scroll_reveal(ed.menu.scroll, i, n, popup_rows_of(ed, rect))
			}
			return
		}
	}
}

@(private)
render_context_menu :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	rect, ok := editor_context_menu_layout(ed)
	if !ok || font == nil {
		return
	}
	draw_popup_box(renderer, rect, theme)
	items := editor_context_menu_items(ed)
	rows := popup_rows_of(ed, rect)
	scroll := overlay_scroll_clamp(ed.menu.scroll, len(items), rows)
	render_overlay_scrollbar(renderer, rect, len(items), rows, scroll, theme)
	hover_row := -1
	if ed.mouse.zone == .Context_Menu {
		hover_row = scroll + int((ed.mouse.y - rect.y - POPUP_PAD) / ed.char_h)
	}
	for it, row in items[scroll:min(len(items), scroll + rows)] {
		i := scroll + row
		y := rect.y + POPUP_PAD + f32(row) * ed.char_h
		if len(it.label) == 0 {
			fill_rect(renderer, {rect.x + POPUP_PAD, y + ed.char_h / 2, rect.w - 2 * POPUP_PAD, 1}, theme.popup_border)
			continue
		}
		if it.enabled && (i == ed.menu.selected || i == hover_row) {
			fill_rect(renderer, {rect.x + 1, y, rect.w - 2, ed.char_h}, theme.popup_selected)
		}
		color := theme.popup_text if it.enabled else theme.popup_text_dim
		// A narrow menu cuts the label before its shortcut
		sc := chord_label(ed, it.action)
		room := int((rect.w - 2 * POPUP_PAD) / ed.char_w) - 2 - (text_cols(sc) + 2 if len(sc) > 0 else 0)
		draw_text(renderer, font, truncate_cols(it.label, max(room, 1)), rect.x + POPUP_PAD + ed.char_w, y, color, ed.char_h)
		if len(sc) > 0 {
			draw_text(renderer, font, sc, rect.x + rect.w - POPUP_PAD - f32(text_cols(sc) + 1) * ed.char_w, y, theme.popup_text_dim, ed.char_h)
		}
	}
}

// --- drag and drop ----------------------------------------------------------------

// editor_press_in_selection reports whether `pos` is inside the primary
// (only) cursor's selection.
@(private)
editor_press_in_selection :: proc(ed: ^Editor, pos: buf.Position) -> bool {
	if len(ed.buf.cursors) != 1 {
		return false
	}
	s, e, ok := buf.selection_range(ed.buf.cursors[0])
	return ok && !buf.position_less(pos, s) && buf.position_less(pos, e)
}

// editor_finish_drag_move drops the dragged selection at m.drop_pos:
// moved (or copied when `copy`) as one undo step, then selected.
@(private)
editor_finish_drag_move :: proc(ed: ^Editor, copy: bool) {
	b := &ed.buf
	m := &ed.mouse
	s, e, ok := buf.selection_range(b.cursors[0])
	if !ok {
		return
	}
	drop := m.drop_pos
	if !buf.position_less(drop, s) && !buf.position_less(e, drop) {
		return // dropped back onto itself
	}
	text := strings.clone(selection_string(ed, s, e), context.temp_allocator)
	group := buf.buffer_next_group(b)
	start, end: buf.Position
	switch {
	case copy:
		start = drop
		end = buf.buffer_insert_text(b, drop, text, group)
	case buf.position_less(e, drop):
		// Insert first (after the selection), then delete it: the insert
		// position shifts back by the deleted span.
		ins_end := buf.buffer_insert_text(b, drop, text, group)
		buf.buffer_delete_range(b, s, e, group)
		ch := buf.Change{start = s, old_end = e, new_end = s}
		start = buf.position_after_change(drop, ch)
		end = buf.position_after_change(ins_end, ch)
	case:
		buf.buffer_delete_range(b, s, e, group)
		start = drop
		end = buf.buffer_insert_text(b, drop, text, group)
	}
	b.cursors[0] = {pos = end, sel = {anchor = start, active = true}}
	editor_ensure_cursor_visible(ed)
}

// selection_string returns the buffer text in [s, e) (temp allocated).
selection_string :: proc(ed: ^Editor, s, e: buf.Position) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for ln in s.line ..= e.line {
		line := buf.buffer_line_str(&ed.buf, ln)
		a := s.col if ln == s.line else 0
		z := e.col if ln == e.line else len(line)
		strings.write_string(&sb, line[min(a, len(line)):min(z, len(line))])
		if ln != e.line {
			strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb)
}

// render_drop_caret shows where a dragged selection would land.
@(private)
render_drop_caret :: proc(ed: ^Editor, renderer: ^sdl.Renderer, theme: Theme) {
	if ed.mouse.drag != .Move {
		return
	}
	x, y := editor_position_to_screen(ed, ed.mouse.drop_pos)
	fill_rect(renderer, {x - 1, y + 2, 2, ed.char_h - 4}, theme.popup_active_param)
}

// --- LSP hover info -----------------------------------------------------------------

Hover_Info :: struct {
	// Waiting for the server's answer about `pos`
	requested: bool,
	pos:       buf.Position,
	// A gutter hover (a marker's tooltip): only `pos.line` counts, the server isn't asked
	line_only: bool,
	seen_seq:  int,
	visible:   bool,
	// The providers were asked about `pos` (their blocks: ed.provided.hover); shown_seq counts
	// what was shown, for the scroll key
	asked:     bool,
	shown_seq: int,
	// Its scroll, when it's taller than the view leaves it (per answer)
	scroll:    Popup_Scroll,
}

// The hover's scroll key: the server's answer and what was shown
editor_hover_scroll_key :: proc(ed: ^Editor) -> u64 {
	return u64(ed.hover.seen_seq) | u64(ed.hover.shown_seq) << 32
}

// editor_update_hover shows hover info once the pointer has rested on a code
// cell without diagnostics: the hover providers' blocks at once, the server's
// answer (asked then) when it comes; on the gutter, a marker's tooltip. Called
// from editor_update_diagnostics.
@(private)
editor_update_hover :: proc(ed: ^Editor) {
	tip := &ed.diag_tip
	h := &ed.hover
	if h.requested && ed.lsp_enabled && ed.lsp.hover_seq != h.seen_seq {
		h.requested = false
		h.seen_seq = ed.lsp.hover_seq
		still := tip.hover_valid && !tip.hover_line_only && tip.hover_pos == h.pos
		h.visible = still && (len(strings.trim_space(ed.lsp.last_hover)) > 0 || len(ed.provided.hover) > 0)
		h.shown_seq += 1
	}
	if h.visible || h.requested || !tip.hover_valid || tip.source != .None {
		return
	}
	if ed.mouse.drag != .None || ed.menu.open || time.tick_since(tip.hover_since) < DIAG_HOVER_DELAY {
		return
	}
	if len(editor_diagnostics_at(ed, tip.hover_pos, tip.hover_line_only)) > 0 {
		return // the diagnostic's tooltip shows
	}
	if tip.hover_line_only {
		if h.asked && h.line_only && h.pos.line == tip.hover_pos.line {
			return // already asked about this line
		}
		h.pos, h.line_only, h.asked = {tip.hover_pos.line, 0}, true, true
		editor_query_hover_providers(ed, h.pos, true)
		h.visible = len(ed.provided.hover) > 0
		h.shown_seq += 1
		return
	}
	if h.asked && !h.line_only && h.pos == tip.hover_pos {
		return // already asked about this cell; the answer was empty
	}
	h.pos, h.line_only, h.asked = tip.hover_pos, false, true
	editor_query_hover_providers(ed, h.pos, false)
	h.visible = len(ed.provided.hover) > 0
	h.shown_seq += 1
	if editor_lsp_ready(ed) {
		editor_sync_lsp(ed)
		h.requested = true
		lspc.client_request_hover(&ed.lsp, ed.document_uri, h.pos.line, editor_lsp_col(ed, h.pos))
		h.seen_seq = ed.lsp.hover_seq
	}
}

editor_hide_hover :: proc(ed: ^Editor) {
	ed.hover.visible = false
	ed.hover.requested = false
}

// The hover tooltip is at most this many columns wide (less in a narrow editor)
HOVER_MAX_COLS :: 100

// The size a hover image or widget is drawn at (images scaled down to HOVER_IMAGE_MAX)
@(private)
hover_block_size :: proc(b: Hover_Block) -> (w, h: f32) {
	switch v in b {
	case Hover_Image:
		scale := min(1, f32(HOVER_IMAGE_MAX) / f32(max(v.width, v.height)))
		return f32(v.width) * scale, f32(v.height) * scale
	case Hover_Widget:
		return v.width, v.height
	case Hover_Text:
	}
	return 0, 0
}

// editor_hover_lines lays out what the hover shows: the providers' blocks, then the server's
// answer, a blank line between them. An image or widget takes as many lines as it's tall
// (`Doc_Line.block`, `block_row`)
editor_hover_lines :: proc(ed: ^Editor, cols: int) -> []Doc_Line {
	out := make([dynamic]Doc_Line, context.temp_allocator)
	gap :: proc(out: ^[dynamic]Doc_Line) { if len(out) > 0 do append(out, Doc_Line{text = ""}) }
	for b, i in ed.provided.hover {
		switch v in b {
		case Hover_Text:
			lines := completion_doc_lines(lspc.CompletionItem{documentation = v.text, doc_markdown = v.markdown}, cols, POPUP_MAX_LINES)
			if len(lines) == 0 do continue
			gap(&out)
			append(&out, ..lines)
		case Hover_Image, Hover_Widget:
			_, h := hover_block_size(b)
			rows := max(1, int((h + ed.char_h - 1) / max(ed.char_h, 1)))
			gap(&out)
			for r in 0 ..< rows do append(&out, Doc_Line{block = i + 1, block_row = r})
		}
	}
	if !ed.hover.line_only && ed.lsp_enabled && len(strings.trim_space(ed.lsp.last_hover)) > 0 && ed.hover.seen_seq == ed.lsp.hover_seq && !ed.hover.requested {
		lines := completion_doc_lines(lspc.CompletionItem{documentation = ed.lsp.last_hover, doc_markdown = ed.lsp.last_hover_markdown}, cols, POPUP_MAX_LINES)
		if len(lines) > 0 {
			gap(&out)
			append(&out, ..lines)
		}
	}
	return out[:]
}

// editor_hover_layout places the hover tooltip above the hovered cell
// (below when there's no room).
editor_hover_layout :: proc(ed: ^Editor) -> (rect: sdl.FRect, lines: []Doc_Line, ok: bool) {
	if !ed.hover.visible || editor_completion_visible(ed) {
		return
	}
	// As wide as the text area allows (100 columns at most); as many lines as fit (it scrolls)
	lines = editor_hover_lines(ed, popup_max_cols(ed, HOVER_MAX_COLS))
	if len(lines) == 0 {
		return
	}
	widest := 0
	for l in lines {
		widest = max(widest, text_cols(l.text))
		if l.block > 0 && l.block_row == 0 {
			w, _ := hover_block_size(ed.provided.hover[l.block - 1])
			widest = max(widest, int((w + ed.char_w - 1) / max(ed.char_w, 1)))
		}
	}
	// Room for the scrollbar
	w := f32(widest + 1) * ed.char_w + 2 * POPUP_PAD
	x, y := editor_position_to_screen(ed, ed.hover.pos)
	top, hh, _ := place_popup(ed, len(lines), y, y + ed.char_h, prefer_above = true)
	left := ed.origin_x + editor_gutter_width(ed)
	right := left + f32(ed.visible_cols) * ed.char_w
	w = min(w, right - left)
	return {clamp(x, left, max(left, right - w)), top, w, hh}, lines, true
}

@(private)
render_hover :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	rect, all_lines, ok := editor_hover_layout(ed)
	if !ok || font == nil {
		return
	}
	draw_popup_box(renderer, rect, theme)
	rows := popup_rows_of(ed, rect)
	scroll := overlay_scroll_clamp(popup_scroll_get(&ed.hover.scroll, editor_hover_scroll_key(ed)), len(all_lines), rows)
	render_overlay_scrollbar(renderer, rect, len(all_lines), rows, scroll, theme)
	inner := sdl.FRect{rect.x + 1, rect.y + POPUP_PAD, rect.w - 2, f32(rows) * ed.char_h}
	drawn := make(map[int]bool, allocator = context.temp_allocator)
	for l, i in all_lines[scroll:min(scroll + rows, len(all_lines))] {
		x := rect.x + POPUP_PAD
		y := rect.y + POPUP_PAD + f32(i) * ed.char_h
		if l.block > 0 {
			// An image or widget: drawn once, from its first line (clipped when scrolled into)
			if drawn[l.block] do continue
			drawn[l.block] = true
			block := ed.provided.hover[l.block - 1]
			bw, bh := hover_block_size(block)
			box := sdl.FRect{x, y - f32(l.block_row) * ed.char_h, bw, bh}
			saved := clip_push(renderer, inner)
			switch v in block {
			case Hover_Image:
				render_hover_image(renderer, v, box)
			case Hover_Widget:
				v.draw(renderer, box, v.data)
			case Hover_Text:
			}
			clip_pop(renderer, saved)
			continue
		}
		if !l.code {
			draw_text(renderer, font, l.text, x, y, theme.popup_text, ed.char_h)
			continue
		}
		draw_code_line(ed, renderer, font, theme, l.text, x, y)
	}
}

// Draws a hover image into a box (a texture made for the frame: hovers are drawn rarely)
@(private)
render_hover_image :: proc(renderer: ^sdl.Renderer, img: Hover_Image, box: sdl.FRect) {
	texture := sdl.CreateTexture(renderer, .ABGR8888, .STATIC, i32(img.width), i32(img.height))
	if texture == nil do return
	defer sdl.DestroyTexture(texture)
	_ = sdl.SetTextureBlendMode(texture, {.BLEND})
	if !sdl.UpdateTexture(texture, nil, raw_data(img.pixels), i32(img.width * 4)) do return
	box := box
	_ = sdl.RenderTexture(renderer, texture, nil, &box)
}
