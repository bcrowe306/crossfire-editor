// Diagnostics rendering: a severity marker in the gutter, a wavy underline
// ("squiggle") under each diagnostic's range (dotted for hints), and the
// message tooltip. Tooltip layout is pure (editor_diag_tooltip_layout) so
// it can be hit-tested and reported by the control hook.
package code_editor

import buf "../buffer"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

DIAG_TOOLTIP_MAX_COLS :: 80
DIAG_TOOLTIP_MAX_LINES :: 12

severity_color :: proc(theme: Theme, sev: Diagnostic_Severity) -> sdl.Color {
	switch sev {
	case .Error: return theme.diag_error
	case .Warning: return theme.diag_warning
	case .Information: return theme.diag_info
	case .Hint: return theme.diag_hint
	}
	return theme.diag_error
}

severity_label :: proc(sev: Diagnostic_Severity) -> string {
	switch sev {
	case .Error: return "error"
	case .Warning: return "warning"
	case .Information: return "info"
	case .Hint: return "hint"
	}
	return "error"
}

// render_gutter_marker draws a small severity marker at the right edge of
// the gutter for a line with diagnostics.
@(private)
render_gutter_marker :: proc(ed: ^Editor, renderer: ^sdl.Renderer, diags: []Diag, line: int, origin_x, y: f32, theme: Theme) {
	sev, ok := line_severity(diags, line)
	if !ok {
		return
	}
	size := max(ed.char_h * 0.35, 4)
	fill_rect(renderer, {origin_x + editor_gutter_width(ed) - size - 3, y + (ed.char_h - size) / 2, size, size}, severity_color(theme, sev))
}

// render_squiggles decorates the parts of `line` covered by diagnostics:
// a wavy underline by severity (dotted for hints), plus the tag styles —
// faded text for `unnecessary` (e.g. an unused import; a tagged hint gets
// only the fade, like VSCode) and a strikethrough for `deprecated`. Less
// severe diagnostics draw first so errors end up on top.
@(private)
render_squiggles :: proc(ed: ^Editor, renderer: ^sdl.Renderer, diags: []Diag, line: int, x, y: f32, theme: Theme) {
	text := buf.buffer_line_str(&ed.buf, line)
	for sev := Diagnostic_Severity.Hint; sev >= .Error; sev = Diagnostic_Severity(int(sev) - 1) {
		for d in diags {
			if d.severity != sev || !diag_covers_line(d, line) {
				continue
			}
			ds, de := diag_extent(ed, d)
			a := ds.col if ds.line == line else 0
			b := de.col if de.line == line else len(text)
			va := visual_col_of(text, a, ed.tab_width)
			vb := visual_col_of(text, min(b, len(text)), ed.tab_width) + max(0, b - len(text)) // phantom EOL cell
			if vb <= va {
				vb = va + 1
			}
			x0 := x + f32(va - ed.scroll_col) * ed.char_w
			x1 := x + f32(vb - ed.scroll_col) * ed.char_w
			if d.unnecessary {
				bg := theme.background
				fill_rect(renderer, {x0, y, x1 - x0, ed.char_h}, {bg.r, bg.g, bg.b, 150})
			}
			if d.deprecated {
				c := theme.text_default
				fill_rect(renderer, {x0, y + ed.char_h / 2, x1 - x0, 1}, {c.r, c.g, c.b, 200})
			}
			if !(d.unnecessary && sev == .Hint) {
				// Just under the glyphs, not at the bottom of a spaced-out row.
			base := y + (ed.char_h + editor_glyph_height(ed)) / 2 + 1
			draw_squiggle(renderer, x0, x1, base, severity_color(theme, sev), sev == .Hint)
			}
		}
	}
}

// draw_squiggle draws a zig-zag (period 4px, amplitude 2px) from x0 to x1
// with its lower edge at `base_y`, or a dotted line for hints.
@(private)
draw_squiggle :: proc(renderer: ^sdl.Renderer, x0, x1, base_y: f32, color: sdl.Color, dotted: bool) {
	sdl.SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a)
	if dotted {
		for x := x0; x < x1; x += 3 {
			r := sdl.FRect{x, base_y - 1, 1, 1}
			sdl.RenderFillRect(renderer, &r)
		}
		return
	}
	points := make([dynamic]sdl.FPoint, 0, int((x1 - x0) / 2) + 2, context.temp_allocator)
	up := false
	for x := x0; x < x1; x += 2 {
		append(&points, sdl.FPoint{x, base_y - (2 if up else 0)})
		up = !up
	}
	append(&points, sdl.FPoint{x1, base_y - (2 if up else 0)})
	sdl.RenderLines(renderer, raw_data(points), i32(len(points)))
}

Tip_Line :: struct {
	text:     string,
	color_of: Diagnostic_Severity,
	label:    bool, // first line of a diagnostic: starts with "<severity>: "
}

Diag_Tooltip_Layout :: struct {
	rect:  sdl.FRect,
	lines: []Tip_Line,
}

// wrap_text splits `s` at newlines and wraps each paragraph at word
// boundaries to at most `cols` runes (temp-allocated).
wrap_text :: proc(s: string, cols: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	rest := s
	for para in strings.split_lines_iterator(&rest) {
		p := strings.trim_right_space(para)
		if len(p) == 0 {
			append(&out, "")
			continue
		}
		for len(p) > 0 {
			if text_cols(p) <= cols {
				append(&out, p)
				break
			}
			// Byte index of the cut point (rune `cols`), then back up to
			// the last space if there is one.
			cut, n := len(p), 0
			for _, i in p {
				if n == cols {
					cut = i
					break
				}
				n += 1
			}
			if sp := strings.last_index_byte(p[:cut], ' '); sp > 0 {
				cut = sp
			}
			append(&out, strings.trim_right_space(p[:cut]))
			p = strings.trim_left_space(p[cut:])
		}
	}
	return out[:]
}

// editor_diag_tooltip_layout computes the tooltip's lines and rectangle.
// It sits just above the line of the first diagnostic shown (below it
// when there's no room), aligned with the diagnostic's start column.
editor_diag_tooltip_layout :: proc(ed: ^Editor) -> (layout: Diag_Tooltip_Layout, ok: bool) {
	items := editor_diag_tooltip_items(ed)
	if len(items) == 0 {
		return
	}
	lines := make([dynamic]Tip_Line, context.temp_allocator)
	widest := 0
	for d, i in items {
		if i > 0 {
			append(&lines, Tip_Line{text = ""})
		}
		msg := strings.concatenate({severity_label(d.severity), ": ", d.message}, context.temp_allocator)
		if len(d.source) > 0 {
			msg = strings.concatenate({msg, "  (", d.source, ")"}, context.temp_allocator)
		}
		for w, j in wrap_text(msg, popup_max_cols(ed, DIAG_TOOLTIP_MAX_COLS)) {
			append(&lines, Tip_Line{text = w, color_of = d.severity, label = j == 0})
			widest = max(widest, text_cols(w))
		}
	}
	if len(lines) > DIAG_TOOLTIP_MAX_LINES {
		resize(&lines, DIAG_TOOLTIP_MAX_LINES)
		lines[DIAG_TOOLTIP_MAX_LINES - 1] = Tip_Line{text = "…"}
	}

	w := f32(widest) * ed.char_w + 2 * POPUP_PAD
	h := f32(len(lines)) * ed.char_h + 2 * POPUP_PAD
	anchor := items[0].start
	if ed.diag_tip.line_only {
		anchor = {ed.diag_tip.pos.line, items[0].start.col if items[0].start.line == ed.diag_tip.pos.line else 0}
	}
	ax, ay := editor_position_to_screen(ed, anchor)
	view_top := ed.origin_y
	view_bottom := ed.origin_y + f32(editor_text_rows(ed)) * ed.char_h
	view_left := ed.origin_x + editor_gutter_width(ed)
	view_right := view_left + f32(ed.visible_cols) * ed.char_w

	y := ay - h - 2
	if y < view_top {
		y = ay + ed.char_h + 2
	}
	if y + h > view_bottom {
		y = max(view_top, view_bottom - h)
	}
	x := clamp(ax, view_left, max(view_left, view_right - w))
	return {rect = {x, y, w, h}, lines = lines[:]}, true
}

@(private)
render_diag_tooltip :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	layout, ok := editor_diag_tooltip_layout(ed)
	if !ok || font == nil {
		return
	}
	draw_popup_box(renderer, layout.rect, theme)
	x := layout.rect.x + POPUP_PAD
	for line, i in layout.lines {
		y := layout.rect.y + POPUP_PAD + f32(i) * ed.char_h
		text := line.text
		if line.label {
			// Colour the "error:" / "warning:" prefix.
			label_len := len(severity_label(line.color_of)) + 1
			draw_text(renderer, font, text[:label_len], x, y, severity_color(theme, line.color_of), ed.char_h)
			draw_text(renderer, font, text[label_len:], x + f32(text_cols(text[:label_len])) * ed.char_w, y, theme.popup_text, ed.char_h)
		} else {
			draw_text(renderer, font, text, x, y, theme.popup_text, ed.char_h)
		}
	}
}
