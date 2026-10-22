// Rendering for the LSP popups: the completion list (below the cursor) and
// the signature-help tooltip (above the cursor). Layout is computed by
// `editor_popup_layout`, which is pure math over editor state so it can be
// unit tested and reported by automation hooks without a renderer.
package code_editor

import buf "../buffer"
import "core:strings"
import "core:fmt"
import syn "../syntax"
import lspc "../lsp"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

POPUP_PAD :: 4
COMPLETION_KIND_COLS :: 6
COMPLETION_MIN_COLS :: 24
COMPLETION_MAX_COLS :: 72
COMPLETION_DETAIL_MAX_COLS :: 40

Popup_Layout :: struct {
	completion:         sdl.FRect,
	completion_visible: bool,
	// The list's rows shown: at most COMPLETION_MAX_VISIBLE, fewer when the view is short
	completion_rows:    int,
	signature:          sdl.FRect,
	signature_visible:  bool,
}

// completion_kind_tag returns a short label for an LSP CompletionItemKind.
completion_kind_tag :: proc(kind: int) -> string {
	switch kind {
	case 2, 3, 4: return "fn"
	case 5, 10:   return "field"
	case 6:       return "var"
	case 7, 8, 22, 25: return "type"
	case 9:       return "pkg"
	case 13:      return "enum"
	case 14:      return "kw"
	case 15:      return "snip"
	case 20:      return "case"
	case 21:      return "const"
	}
	return "  "
}

@(private)
text_cols :: proc(s: string) -> int {
	return utf8.rune_count_in_string(s)
}

// editor_cursor_screen_pos returns the top-left pixel of the primary
// cursor's cell, using the origin recorded by the last editor_render.
editor_cursor_screen_pos :: proc(ed: ^Editor) -> (x, y: f32) {
	return editor_position_to_screen(ed, editor_primary_cursor(ed).pos)
}

// editor_position_to_screen returns the top-left pixel of the cell at a
// buffer position (the caret's x for that position), using the origin
// recorded by the last editor_render.
editor_position_to_screen :: proc(ed: ^Editor, pos: buf.Position) -> (x, y: f32) {
	x = ed.origin_x + editor_gutter_width(ed) + f32(editor_visual_col(ed, pos) - ed.scroll_col) * ed.char_w
	y = ed.origin_y + f32(pos.line - ed.scroll_line) * ed.char_h
	return
}

@(private)
completion_popup_cols :: proc(ed: ^Editor) -> int {
	label_cols, detail_cols := 0, 0
	for idx in ed.completion.filtered {
		item := ed.lsp.last_completion[idx]
		label_cols = max(label_cols, text_cols(item.label))
		detail_cols = max(detail_cols, text_cols(item.detail))
	}
	detail_cols = min(detail_cols, COMPLETION_DETAIL_MAX_COLS)
	cols := COMPLETION_KIND_COLS + label_cols + (detail_cols > 0 ? 2 + detail_cols : 0)
	return clamp(cols, COMPLETION_MIN_COLS, COMPLETION_MAX_COLS)
}

// editor_popup_layout positions the popups relative to the primary
// cursor. The signature tooltip prefers the line above the cursor and the
// completion list prefers the space below; each flips to the other side
// when it would run off the editor's visible area.
editor_popup_layout :: proc(ed: ^Editor) -> (layout: Popup_Layout) {
	if !editor_completion_visible(ed) && !editor_signature_visible(ed) {
		return
	}
	cx, cy := editor_cursor_screen_pos(ed)
	view_top := ed.origin_y
	view_bottom := ed.origin_y + f32(editor_text_rows(ed)) * ed.char_h
	view_right := ed.origin_x + editor_gutter_width(ed) + f32(ed.visible_cols) * ed.char_w

	below_y := cy + ed.char_h + 2

	if editor_signature_visible(ed) {
		lines, cols := signature_wrapped(ed, signature_max_cols(ed))
		w := f32(cols) * ed.char_w + 2 * POPUP_PAD
		// Above the cursor, else below; in a short view as many lines as fit (it scrolls)
		y, h, _ := place_popup(ed, len(lines), cy, cy + ed.char_h, prefer_above = true)
		if y > cy {
			below_y += h + 2
		}
		x := min(cx, max(ed.origin_x + editor_gutter_width(ed), view_right - w))
		layout.signature = {x, y, w, h}
		layout.signature_visible = true
	}

	if editor_completion_visible(ed) {
		wanted := min(len(ed.completion.filtered), COMPLETION_MAX_VISIBLE)
		w := f32(completion_popup_cols(ed)) * ed.char_w + 2 * POPUP_PAD
		// Below the cursor if it fits, else above (over the signature tooltip if that's above
		// too); in a short view, on the roomier side with as many rows as fit (it scrolls)
		above_bottom := cy - 2
		if layout.signature_visible && layout.signature.y < cy {
			above_bottom = layout.signature.y - 2
		}
		room_below := view_bottom - below_y
		room_above := above_bottom - view_top
		full := f32(wanted) * ed.char_h + 2 * POPUP_PAD
		below := full <= room_below || room_below >= room_above
		rows := overlay_rows_fit(ed, below ? room_below : room_above, wanted)
		h := f32(rows) * ed.char_h + 2 * POPUP_PAD
		y := below ? below_y : above_bottom - h
		layout.completion_rows = rows
		// Align the list's label column under the start of the word.
		ax, _ := editor_position_to_screen(ed, ed.completion.anchor)
		x := ax - f32(COMPLETION_KIND_COLS) * ed.char_w - POPUP_PAD
		// No wider than the text area (its scrollbar on the right must show; labels are cut)
		w = min(w, view_right - (ed.origin_x + editor_gutter_width(ed)))
		x = clamp(x, ed.origin_x + editor_gutter_width(ed), max(ed.origin_x + editor_gutter_width(ed), view_right - w))
		layout.completion = {x, y, w, h}
		layout.completion_visible = true
	}
	return
}

@(private)
render_popups :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme, origin_x, origin_y: f32) {
	if font == nil {
		return
	}
	layout := editor_popup_layout(ed)
	if layout.signature_visible {
		render_signature_popup(ed, renderer, font, theme, layout.signature)
	}
	if layout.completion_visible {
		render_completion_popup(ed, renderer, font, theme, layout.completion)
		render_completion_docs(ed, renderer, font, theme)
	}
}

@(private)
fill_rect :: proc(renderer: ^sdl.Renderer, rect: sdl.FRect, color: sdl.Color) {
	r := rect
	sdl.SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a)
	sdl.RenderFillRect(renderer, &r)
}

@(private)
draw_popup_box :: proc(renderer: ^sdl.Renderer, rect: sdl.FRect, theme: Theme) {
	fill_rect(renderer, rect, theme.popup_bg)
	r := rect
	sdl.SetRenderDrawColor(renderer, theme.popup_border.r, theme.popup_border.g, theme.popup_border.b, theme.popup_border.a)
	sdl.RenderRect(renderer, &r)
}

// truncate_cols cuts `s` to at most `cols` runes, ending in "…" if cut.
@(private)
truncate_cols :: proc(s: string, cols: int) -> string {
	if cols <= 0 {
		return ""
	}
	if text_cols(s) <= cols {
		return s
	}
	n := 0
	for _, i in s {
		if n == cols - 1 {
			return concat_ellipsis(s[:i])
		}
		n += 1
	}
	return s
}

@(private)
concat_ellipsis :: proc(s: string) -> string {
	out := make([]u8, len(s) + 3, context.temp_allocator)
	copy(out, s)
	copy(out[len(s):], "…")
	return string(out)
}

@(private)
render_completion_popup :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme, rect: sdl.FRect) {
	draw_popup_box(renderer, rect, theme)
	cs := &ed.completion
	prefix, _ := editor_completion_prefix(ed)
	total_cols := int((rect.w - 2 * POPUP_PAD) / ed.char_w)

	visible := editor_completion_rows(ed)
	last := min(cs.scroll + visible, len(cs.filtered))
	for row in cs.scroll ..< last {
		item := ed.lsp.last_completion[cs.filtered[row]]
		y := rect.y + POPUP_PAD + f32(row - cs.scroll) * ed.char_h
		x := rect.x + POPUP_PAD

		if row == cs.selected {
			fill_rect(renderer, {rect.x + 1, y, rect.w - 2, ed.char_h}, theme.popup_selected)
		}

		draw_text(renderer, font, completion_kind_tag(item.kind), x, y, theme.text_type, ed.char_h)
		x += f32(COMPLETION_KIND_COLS) * ed.char_w

		label_cols := min(text_cols(item.label), total_cols - COMPLETION_KIND_COLS)
		label := truncate_cols(item.label, label_cols)
		// Highlight the typed prefix when it matches the label's start.
		match_len := 0
		if completion_match(label, prefix) == 2 && len(prefix) <= len(label) {
			match_len = len(prefix)
		}
		draw_text(renderer, font, label[:match_len], x, y, theme.popup_match, ed.char_h)
		draw_text(renderer, font, label[match_len:], x + f32(text_cols(label[:match_len])) * ed.char_w, y, theme.popup_text, ed.char_h)

		// The scrollbar's room comes off the detail column
		detail_cols := total_cols - COMPLETION_KIND_COLS - label_cols - 2 - (len(cs.filtered) > visible ? 1 : 0)
		if len(item.detail) > 0 && detail_cols > 3 {
			detail := truncate_cols(item.detail, min(detail_cols, COMPLETION_DETAIL_MAX_COLS))
			dx := rect.x + rect.w - POPUP_PAD - f32(text_cols(detail)) * ed.char_w
			draw_text(renderer, font, detail, dx, y, theme.popup_text_dim, ed.char_h)
		}
	}

	render_overlay_scrollbar(renderer, rect, len(cs.filtered), visible, cs.scroll, theme)
}

// The signature tooltip's scroll key: the server's answer and the overload shown
@(private)
signature_scroll_key :: proc(ed: ^Editor) -> u64 {
	return u64(ed.signature.seen_seq) << 20 | u64(editor_signature_index(ed) + 1)
}

@(private)
render_signature_popup :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme, rect: sdl.FRect) {
	draw_popup_box(renderer, rect, theme)
	all_lines, _ := signature_wrapped(ed, signature_max_cols(ed))
	rows := popup_rows_of(ed, rect)
	scroll := overlay_scroll_clamp(popup_scroll_get(&ed.signature.scroll, signature_scroll_key(ed)), len(all_lines), rows)
	lines := all_lines[scroll:min(scroll + rows, len(all_lines))]
	render_overlay_scrollbar(renderer, rect, len(all_lines), rows, scroll, theme)
	for line, row in lines {
		y := rect.y + POPUP_PAD + f32(row) * ed.char_h
		// Each run of one style is drawn at once
		start := 0
		for start < len(line.runes) {
			end := start + 1
			for end < len(line.runes) && line.styles[end] == line.styles[start] do end += 1
			x := rect.x + POPUP_PAD + f32(start) * ed.char_w
			text := utf8.runes_to_string(line.runes[start:end], context.temp_allocator)
			switch line.styles[start] {
			case .Dim:  draw_text(renderer, font, text, x, y, theme.popup_text_dim, ed.char_h)
			case .Text: draw_text(renderer, font, text, x, y, theme.popup_text, ed.char_h)
			case .Active:
				draw_text(renderer, font, text, x, y, theme.popup_active_param, ed.char_h)
				// Underline the active parameter so it reads even without color.
				fill_rect(renderer, {x, y + ed.char_h - 2, f32(end - start) * ed.char_w, 1}, theme.popup_active_param)
			}
			start = end
		}
	}
}

// How the signature tooltip draws a character: the overload counter, the signature, the active
// parameter
Signature_Style :: enum u8 {
	Dim,
	Text,
	Active,
}

// One line of the wrapped signature tooltip: its characters and how each is drawn
Signature_Line :: struct {
	runes:  []rune,
	styles: []Signature_Style,
}

// The signature tooltip is at most this many columns wide (less in a narrow editor)
SIGNATURE_MAX_COLS :: 100
// Continuation lines of a wrapped signature are indented this much
SIGNATURE_INDENT :: 4

// signature_max_cols is how wide the tooltip may be: the text area's
// width (less a margin), at most SIGNATURE_MAX_COLS, at least 20.
signature_max_cols :: proc(ed: ^Editor) -> int {
	return clamp(ed.visible_cols - 2, 20, SIGNATURE_MAX_COLS)
}

// signature_wrapped lays the tooltip's text (the overload counter, then the
// signature with its active parameter) out in lines of at most `max_cols`
// columns, breaking after a space (", " between parameters) where one is
// in the line's last two thirds, else mid-word. Continuation lines are
// indented by SIGNATURE_INDENT. Returns the lines (temp allocated) and the
// widest one's columns.
signature_wrapped :: proc(ed: ^Editor, max_cols: int) -> (lines: []Signature_Line, cols: int) {
	_, before, active, after := editor_signature_active_parts(ed)
	runes := make([dynamic]rune, context.temp_allocator)
	styles := make([dynamic]Signature_Style, context.temp_allocator)
	add :: proc(runes: ^[dynamic]rune, styles: ^[dynamic]Signature_Style, text: string, style: Signature_Style) {
		for r in text {
			append(runes, r)
			append(styles, style)
		}
	}
	add(&runes, &styles, signature_counter(ed), .Dim)
	add(&runes, &styles, before, .Text)
	add(&runes, &styles, active, .Active)
	add(&runes, &styles, after, .Text)

	out := make([dynamic]Signature_Line, context.temp_allocator)
	n := len(runes)
	start := 0
	indent := 0
	for start < n || len(out) == 0 {
		room := max(max_cols - indent, 8)
		end := min(start + room, n)
		if end < n {
			for i := end; i > start + room / 3; i -= 1 {
				if runes[i - 1] == ' ' {
					end = i
					break
				}
			}
		}
		line := Signature_Line{make([]rune, indent + end - start, context.temp_allocator), make([]Signature_Style, indent + end - start, context.temp_allocator)}
		for i in 0 ..< indent {
			line.runes[i] = ' '
			line.styles[i] = .Text
		}
		copy(line.runes[indent:], runes[start:end])
		copy(line.styles[indent:], styles[start:end])
		// Trailing spaces don't count toward the width
		width := len(line.runes)
		for width > indent && line.runes[width - 1] == ' ' do width -= 1
		cols = max(cols, width)
		append(&out, line)
		start = end
		for start < n && runes[start] == ' ' do start += 1
		indent = SIGNATURE_INDENT
		if n == 0 do break
	}
	return out[:], cols
}

// signature_counter is the "2/3 " overload indicator (empty for one).
signature_counter :: proc(ed: ^Editor) -> string {
	n := len(ed.lsp.last_signatures)
	if n < 2 {
		return ""
	}
	return fmt.tprintf("%d/%d  ", editor_signature_index(ed) + 1, n)
}

COMPLETION_DOC_COLS :: 56
COMPLETION_DOC_MAX_LINES :: 16

Doc_Line :: struct {
	text: string,
	code: bool, // render with syntax highlighting
}

// completion_doc_lines turns the selected item's detail + documentation
// into display lines: markdown fences become highlighted code lines,
// headings/emphasis markers are stripped, prose is wrapped.
completion_doc_lines :: proc(item: lspc.CompletionItem, cols := COMPLETION_DOC_COLS, max_lines := COMPLETION_DOC_MAX_LINES) -> []Doc_Line {
	out := make([dynamic]Doc_Line, context.temp_allocator)
	if len(item.detail) > 0 {
		for w in wrap_code(item.detail, cols) {
			append(&out, Doc_Line{w, true})
		}
	}
	doc := strings.trim_space(item.documentation)
	if len(doc) > 0 {
		if len(out) > 0 {
			append(&out, Doc_Line{"", false})
		}
		in_code := false
		rest := doc
		for line in strings.split_lines_iterator(&rest) {
			if item.doc_markdown && strings.has_prefix(strings.trim_space(line), "```") {
				in_code = !in_code
				continue
			}
			if in_code {
				// A long signature wraps too (it ran off the editor)
				for w in wrap_code(line, cols) do append(&out, Doc_Line{w, true})
				continue
			}
			if item.doc_markdown && strings.trim_space(line) == "---" {
				continue // horizontal rule
			}
			l := line
			if item.doc_markdown {
				l = strings.trim_left(l, "# ")
				l, _ = strings.remove_all(l, "`", context.temp_allocator)
				l, _ = strings.remove_all(l, "**", context.temp_allocator)
			}
			for w in wrap_text(l, cols) {
				append(&out, Doc_Line{w, false})
			}
		}
	}
	// Trim trailing blank lines and cap the height.
	for len(out) > 0 && len(strings.trim_space(out[len(out) - 1].text)) == 0 {
		pop(&out)
	}
	if len(out) > max_lines {
		resize(&out, max_lines)
		out[max_lines - 1] = Doc_Line{"…", false}
	}
	return out[:]
}

// editor_completion_doc_layout places the docs panel beside the completion
// list (right side, else left, else below it).
editor_completion_doc_layout :: proc(ed: ^Editor) -> (rect: sdl.FRect, lines: []Doc_Line, ok: bool) {
	layout := editor_popup_layout(ed)
	item, has := editor_completion_selected_item(ed)
	if !layout.completion_visible || !has {
		return
	}
	lines = completion_doc_lines(item, popup_max_cols(ed, COMPLETION_DOC_COLS), POPUP_MAX_LINES)
	if len(lines) == 0 {
		return
	}
	widest := 0
	for l in lines {
		widest = max(widest, text_cols(l.text))
	}
	// Room for the scrollbar
	w := f32(widest + 1) * ed.char_w + 2 * POPUP_PAD
	c := layout.completion
	left := ed.origin_x + editor_gutter_width(ed)
	right := left + f32(ed.visible_cols) * ed.char_w
	// Beside the list (as many lines as fit down to the view's bottom: it scrolls), else below it
	y := c.y
	x: f32
	switch {
	case c.x + c.w + 2 + w <= right: x = c.x + c.w + 2
	case c.x - 2 - w >= left: x = c.x - 2 - w
	case: x, y = c.x, c.y + c.h + 2
	}
	rows := overlay_rows_fit(ed, overlay_view_bottom(ed) - y, len(lines))
	return {x, y, min(w, right - left), f32(rows) * ed.char_h + 2 * POPUP_PAD}, lines, true
}

@(private)
render_completion_docs :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	rect, all_lines, ok := editor_completion_doc_layout(ed)
	if !ok || font == nil {
		return
	}
	draw_popup_box(renderer, rect, theme)
	rows := popup_rows_of(ed, rect)
	scroll := overlay_scroll_clamp(popup_scroll_get(&ed.completion.doc_scroll, completion_doc_scroll_key(ed)), len(all_lines), rows)
	render_overlay_scrollbar(renderer, rect, len(all_lines), rows, scroll, theme)
	for l, i in all_lines[scroll:min(scroll + rows, len(all_lines))] {
		x := rect.x + POPUP_PAD
		y := rect.y + POPUP_PAD + f32(i) * ed.char_h
		if !l.code {
			draw_text(renderer, font, l.text, x, y, theme.popup_text, ed.char_h)
			continue
		}
		draw_code_line(ed, renderer, font, theme, l.text, x, y)
	}
}

// The completion docs panel's scroll key: the server's answer and the item shown
@(private)
completion_doc_scroll_key :: proc(ed: ^Editor) -> u64 {
	cs := &ed.completion
	item := cs.selected >= 0 && cs.selected < len(cs.filtered) ? cs.filtered[cs.selected] : -1
	return u64(ed.lsp.completion_seq) << 32 | u64(u32(item + 1))
}

// popup_max_cols is how wide a popup's text may be: the text area's width
// (less a margin), at most `cap`, at least 20 columns.
popup_max_cols :: proc(ed: ^Editor, cap: int) -> int {
	// A narrow editor (a hosted pane) gets narrower popups, down to 8 columns
	return max(min(ed.visible_cols - 2, cap), 8)
}

// wrap_code wraps a line of code at `cols` runes: after a space (", "
// between parameters) in the line's last two thirds where there is one,
// else mid-token, continuation lines indented by SIGNATURE_INDENT past the
// line's own indentation (temp-allocated).
wrap_code :: proc(line: string, cols: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	trimmed := strings.trim_right_space(line)
	if text_cols(trimmed) <= cols {
		append(&out, trimmed)
		return out[:]
	}
	lead := len(trimmed) - len(strings.trim_left_space(trimmed))
	indent := strings.concatenate({trimmed[:lead], "    "}, context.temp_allocator)
	runes := utf8.string_to_runes(trimmed, context.temp_allocator)
	start := 0
	first := true
	for start < len(runes) {
		prefix := first ? "" : indent
		room := max(cols - text_cols(prefix), 8)
		end := min(start + room, len(runes))
		if end < len(runes) {
			for i := end; i > start + room / 3; i -= 1 {
				if runes[i - 1] == ' ' {
					end = i
					break
				}
			}
		}
		piece := strings.trim_right_space(utf8.runes_to_string(runes[start:end], context.temp_allocator))
		append(&out, strings.concatenate({prefix, piece}, context.temp_allocator))
		start = end
		for start < len(runes) && runes[start] == ' ' do start += 1
		first = false
	}
	return out[:]
}

// draw_code_line draws one line of code with the editor's syntax colours.
@(private)
draw_code_line :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme, text: string, x, y: f32) {
	tokens, _ := ed.language.tokenize(text, syn.LINE_STATE_NORMAL, context.temp_allocator)
	for tok in tokens {
		if tok.end > tok.start {
			draw_text(renderer, font, text[tok.start:tok.end], x + f32(text_cols(text[:tok.start])) * ed.char_w, y, token_color(theme, tok.kind), ed.char_h)
		}
	}
}
