// Theme editor window: every theme colour with a swatch; the selected one
// is edited with R/G/B/A sliders (drag or click, or Left/Right) or by
// typing a hex value, and a live preview shows the result.
//   Up/Down/PageUp/PageDown  select a colour
//   Tab / Shift+Tab          choose the R/G/B/A channel
//   Left/Right               adjust the channel (Shift: by 16)
//   Enter                    type a hex colour (Enter applies, Esc cancels)
//   Delete                   reset the colour to the preset's
//   P / Shift+P              next / previous preset (drops edits)
//   Escape                   close
// Every change is saved to the config dir's theme.json.
package code_editor

import km "../keymap"
import syn "../syntax"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

CHANNEL_NAMES :: [4]string{"R", "G", "B", "A"}

Theme_Editor :: struct {
	base:     Theme_Preset, // the preset the theme is based on
	selected: int,          // Theme field index
	scroll:   int,
	channel:  int,          // 0..3 = R, G, B, A
	editing:  bool,         // typing a hex value
	hex:      strings.Builder,
	drag:     int,          // channel slider being dragged, -1 = none
}

theme_editor_init :: proc(t: ^Theme_Editor, allocator := context.allocator) {
	t.hex = strings.builder_make(allocator)
	t.drag = -1
}

theme_editor_destroy :: proc(t: ^Theme_Editor) {
	strings.builder_destroy(&t.hex)
}

@(private)
channel_ptr :: proc(c: ^sdl.Color, ch: int) -> ^u8 {
	return &(^[4]u8)(c)[clamp(ch, 0, 3)]
}

editor_theme_selected_color :: proc(ed: ^Editor) -> ^sdl.Color {
	return theme_color_ptr(&ed.theme, ed.theme_editor.selected)
}

// editor_theme_set_channel sets one channel of the selected colour.
editor_theme_set_channel :: proc(ed: ^Editor, ch: int, value: int, save := true) {
	channel_ptr(editor_theme_selected_color(ed), ch)^ = u8(clamp(value, 0, 255))
	if save {
		editor_save_theme(ed)
	}
}

editor_theme_reset_selected :: proc(ed: ^Editor) {
	ref := preset_theme(ed.theme_editor.base)
	editor_theme_selected_color(ed)^ = theme_color_ptr(&ref, ed.theme_editor.selected)^
	editor_save_theme(ed)
}

// editor_theme_modified reports whether field i differs from the preset.
editor_theme_modified :: proc(ed: ^Editor, i: int) -> bool {
	ref := preset_theme(ed.theme_editor.base)
	return theme_color_ptr(&ed.theme, i)^ != theme_color_ptr(&ref, i)^
}

editor_theme_text_input :: proc(ed: ^Editor, text: string) {
	t := &ed.theme_editor
	if !t.editing {
		return
	}
	for ch in text {
		if ((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')) && len(t.hex.buf) < 8 {
			strings.write_rune(&t.hex, ch)
		}
	}
	// Live preview while the value is complete.
	if c, ok := parse_color_hex(strings.to_string(t.hex)); ok && len(t.hex.buf) >= 6 {
		editor_theme_selected_color(ed)^ = c
	}
}

@(private)
theme_editor_clamp_scroll :: proc(ed: ^Editor) {
	t := &ed.theme_editor
	n := theme_field_count()
	_, rows := editor_theme_layout(ed)
	t.selected = clamp(t.selected, 0, n - 1)
	if t.selected < t.scroll {
		t.scroll = t.selected
	} else if t.selected >= t.scroll + rows {
		t.scroll = t.selected - rows + 1
	}
	t.scroll = clamp(t.scroll, 0, max(0, n - rows))
}

editor_theme_handle_key :: proc(ed: ^Editor, chord: km.Chord) -> bool {
	t := &ed.theme_editor
	n := theme_field_count()
	if t.editing {
		#partial switch chord.key {
		case .Enter:
			t.editing = false
			if c, ok := parse_color_hex(strings.to_string(t.hex)); ok {
				editor_theme_selected_color(ed)^ = c
				editor_save_theme(ed)
				editor_set_status(ed, fmt.tprintf("%s = %s", theme_field_title(theme_field_names()[t.selected]), color_hex(c)))
			} else {
				editor_set_status(ed, "Not a colour (use rgb, rrggbb or rrggbbaa)")
			}
		case .Escape:
			t.editing = false
			editor_load_theme_field(ed)
		case .Backspace:
			if len(t.hex.buf) > 0 {
				resize(&t.hex.buf, len(t.hex.buf) - 1)
			}
		}
		return true
	}
	_, page := editor_theme_layout(ed)
	step := 16 if .Shift in chord.mods else 1
	#partial switch chord.key {
	case .Escape:
		editor_show_window(ed, .Text)
	case .Up:
		t.selected = max(0, t.selected - 1)
	case .Down:
		t.selected = min(n - 1, t.selected + 1)
	case .PageUp:
		t.selected = max(0, t.selected - page)
	case .PageDown:
		t.selected = min(n - 1, t.selected + page)
	case .Home:
		t.selected = 0
	case .End:
		t.selected = n - 1
	case .Tab:
		t.channel = (t.channel + (3 if .Shift in chord.mods else 1)) % 4
	case .Left, .Right:
		v := int(channel_ptr(editor_theme_selected_color(ed), t.channel)^)
		editor_theme_set_channel(ed, t.channel, v + (step if chord.key == .Right else -step))
	case .Enter:
		t.editing = true
		strings.builder_reset(&t.hex)
		strings.write_string(&t.hex, color_hex(editor_theme_selected_color(ed)^)[1:])
	case .Delete:
		editor_theme_reset_selected(ed)
	case .P:
		count := len(Theme_Preset)
		next := (int(t.base) + (count - 1 if .Shift in chord.mods else 1)) % count
		editor_apply_preset(ed, Theme_Preset(next))
	}
	theme_editor_clamp_scroll(ed)
	return true
}

// editor_load_theme_field undoes an unfinished hex edit's live preview.
@(private)
editor_load_theme_field :: proc(ed: ^Editor) {
	saved := ed.theme
	if editor_load_theme(ed) {
		keep := theme_color_ptr(&ed.theme, ed.theme_editor.selected)^
		ed.theme = saved
		editor_theme_selected_color(ed)^ = keep
	}
}

// --- layout ------------------------------------------------------------------

// editor_theme_layout: where the colour list starts and how many rows fit.
editor_theme_layout :: proc(ed: ^Editor) -> (list_top: f32, rows: int) {
	area := editor_area_rect(ed)
	list_top = area.y + 2 * ed.char_h
	bottom := area.y + area.h - 2 * ed.char_h
	return list_top, max(1, int((bottom - list_top) / ed.char_h))
}

@(private)
theme_list_width :: proc(ed: ^Editor) -> f32 {
	return editor_area_rect(ed).w * 0.48
}

// editor_theme_row_at maps a window point to a colour index (-1 = none).
editor_theme_row_at :: proc(ed: ^Editor, x, y: f32) -> int {
	area := editor_area_rect(ed)
	top, rows := editor_theme_layout(ed)
	if x >= area.x + theme_list_width(ed) || y < top {
		return -1
	}
	r := int((y - top) / ed.char_h)
	i := ed.theme_editor.scroll + r
	if r >= rows || i >= theme_field_count() {
		return -1
	}
	return i
}

// editor_theme_slider_rect is the track of a channel slider.
editor_theme_slider_rect :: proc(ed: ^Editor, ch: int) -> sdl.FRect {
	area := editor_area_rect(ed)
	top, _ := editor_theme_layout(ed)
	px := area.x + theme_list_width(ed) + 2 * ed.char_w
	pw := area.x + area.w - px - ed.char_w
	y := top + f32(5 + ch) * ed.char_h
	return {px + 3 * ed.char_w, y, pw - 9 * ed.char_w, ed.char_h}
}

editor_theme_click :: proc(ed: ^Editor, x, y: f32) {
	t := &ed.theme_editor
	for ch in 0 ..< 4 {
		if r := editor_theme_slider_rect(ed, ch); in_rect(r, x, y) {
			t.channel, t.drag = ch, ch
			editor_theme_drag(ed, x, y)
			return
		}
	}
	if i := editor_theme_row_at(ed, x, y); i >= 0 {
		t.selected = i
		t.editing = false
	}
}

editor_theme_drag :: proc(ed: ^Editor, x, y: f32) {
	t := &ed.theme_editor
	if t.drag < 0 {
		return
	}
	r := editor_theme_slider_rect(ed, t.drag)
	frac := clamp((x - r.x) / max(r.w, 1), 0, 1)
	editor_theme_set_channel(ed, t.drag, int(frac * 255 + 0.5), save = false)
}

editor_theme_release :: proc(ed: ^Editor) {
	if ed.theme_editor.drag >= 0 {
		ed.theme_editor.drag = -1
		editor_save_theme(ed)
	}
}

editor_theme_scroll :: proc(ed: ^Editor, lines: int) {
	t := &ed.theme_editor
	_, rows := editor_theme_layout(ed)
	t.scroll = clamp(t.scroll + lines, 0, max(0, theme_field_count() - rows))
}

// --- rendering -----------------------------------------------------------------

THEME_PREVIEW :: []string{
	"// Preview",
	"import \"core:fmt\"",
	"Point :: struct { x, y: f32 }",
	"@(private)",
	"scale :: proc(p: Point, k: f32) -> Point {",
	"    return {p.x * k, p.y * k} // fields",
	"}",
	"main :: proc() {",
	"    n := 42",
	"    fmt.println(\"hello\", scale({1, 2}, 0.5), #location())",
	"    if len(\"abc\") > n { return }",
	"}",
}

@(private)
draw_swatch :: proc(renderer: ^sdl.Renderer, r: sdl.FRect, c: sdl.Color, theme: Theme) {
	// A checkerboard behind translucent colours shows the alpha.
	if c.a < 255 {
		cell := r.h / 2
		for yi in 0 ..< 2 {
			for xi := 0; f32(xi) * cell < r.w; xi += 1 {
				shade := u8(200) if (xi + yi) % 2 == 0 else u8(120)
				w := min(cell, r.w - f32(xi) * cell)
				fill_rect(renderer, {r.x + f32(xi) * cell, r.y + f32(yi) * cell, w, cell}, {shade, shade, shade, 255})
			}
		}
	}
	fill_rect(renderer, r, c)
	fill_rect(renderer, {r.x, r.y, r.w, 1}, theme.popup_border)
	fill_rect(renderer, {r.x, r.y + r.h - 1, r.w, 1}, theme.popup_border)
	fill_rect(renderer, {r.x, r.y, 1, r.h}, theme.popup_border)
	fill_rect(renderer, {r.x + r.w - 1, r.y, 1, r.h}, theme.popup_border)
}

@(private)
render_theme_editor :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	t := &ed.theme_editor
	area := editor_area_rect(ed)
	modified := 0
	for i in 0 ..< theme_field_count() {
		if editor_theme_modified(ed, i) {
			modified += 1
		}
	}
	title := fmt.tprintf("Color Theme: %s%s", preset_name(t.base), fmt.tprintf(" (%d edited)", modified) if modified > 0 else "")
	render_window_title(ed, renderer, font, theme, title)

	// Colour list.
	names := theme_field_names()
	top, rows := editor_theme_layout(ed)
	list_w := theme_list_width(ed)
	x := area.x + ed.char_w
	for r in 0 ..< rows {
		i := t.scroll + r
		if i >= len(names) {
			break
		}
		ry := top + f32(r) * ed.char_h
		if i == t.selected {
			fill_rect(renderer, {area.x, ry, list_w, ed.char_h}, theme.popup_selected)
		} else if ed.mouse.zone == .Tool_Window && editor_theme_row_at(ed, ed.mouse.x, ed.mouse.y) == i {
			fill_rect(renderer, {area.x, ry, list_w, ed.char_h}, theme.current_line)
		}
		c := theme_color_ptr(&ed.theme, i)^
		draw_swatch(renderer, {x, ry + 3, 2.5 * ed.char_w, ed.char_h - 6}, c, theme)
		mark := "*" if editor_theme_modified(ed, i) else " "
		draw_text(renderer, font, fmt.tprintf("%s %s", mark, theme_field_title(names[i])), x + 3 * ed.char_w, ry, theme.text_default, ed.char_h)
		hex := color_hex(c)
		draw_text(renderer, font, hex, area.x + list_w - f32(len(hex) + 1) * ed.char_w, ry, theme.popup_text_dim, ed.char_h)
	}
	fill_rect(renderer, {area.x + list_w, top, 1, f32(rows) * ed.char_h}, theme.popup_border)

	// Selected colour: name, big swatch, hex, sliders.
	px := area.x + list_w + 2 * ed.char_w
	pw := area.x + area.w - px - ed.char_w
	sel := editor_theme_selected_color(ed)^
	draw_text(renderer, font, theme_field_title(names[t.selected]), px, top, theme.header_text, ed.char_h)
	draw_swatch(renderer, {px, top + ed.char_h + 4, 8 * ed.char_w, 3 * ed.char_h - 8}, sel, theme)
	hx := px + 10 * ed.char_w
	hy := top + 2 * ed.char_h
	if t.editing {
		fill_rect(renderer, {hx - 4, hy, 12 * ed.char_w, ed.char_h}, theme.gutter_bg)
		s := strings.concatenate({"#", strings.to_string(t.hex)}, context.temp_allocator)
		draw_text(renderer, font, s, hx, hy, theme.text_default, ed.char_h)
		fill_rect(renderer, {hx + f32(len(s)) * ed.char_w, hy + 3, 2, ed.char_h - 6}, theme.cursor)
	} else {
		draw_text(renderer, font, color_hex(sel), hx, hy, theme.text_default, ed.char_h)
		draw_text(renderer, font, "Enter: type a value", hx + 11 * ed.char_w, hy, theme.popup_text_dim, ed.char_h)
	}
	names4 := CHANNEL_NAMES
	for ch in 0 ..< 4 {
		r := editor_theme_slider_rect(ed, ch)
		v := channel_ptr(&sel, ch)^
		label_color := theme.popup_match if ch == t.channel else theme.popup_text_dim
		draw_text(renderer, font, names4[ch], px, r.y, label_color, ed.char_h)
		track := sdl.FRect{r.x, r.y + r.h * 0.4, r.w, r.h * 0.2}
		fill_rect(renderer, track, theme.popup_border)
		fill_rect(renderer, {track.x, track.y, track.w * f32(v) / 255, track.h}, label_color)
		tx := r.x + r.w * f32(v) / 255
		fill_rect(renderer, {tx - 3, r.y + 3, 6, r.h - 6}, theme.text_default if ch == t.channel else theme.popup_text_dim)
		draw_text(renderer, font, fmt.tprintf("%3d", v), r.x + r.w + ed.char_w, r.y, theme.text_default, ed.char_h)
	}

	// Live preview of the text colours.
	// As many lines as fit above the footer.
	py := top + 9.5 * ed.char_h
	lines := THEME_PREVIEW
	fit := int((area.y + area.h - 2 * ed.char_h - py - 12) / ed.char_h)
	lines = lines[:clamp(fit, 0, len(lines))]
	ph := f32(len(lines)) * ed.char_h + 8
	if len(lines) >= 3 {
		box := sdl.FRect{px, py, pw, ph}
		fill_rect(renderer, box, theme.background)
		clip := sdl.Rect{i32(px), i32(py), i32(pw), i32(ph)}
		sdl.SetRenderClipRect(renderer, &clip)
		defer sdl.SetRenderClipRect(renderer, nil)
		fill_rect(renderer, {px, py, 4 * ed.char_w, ph}, theme.gutter_bg)
		state := syn.LINE_STATE_NORMAL
		for line, li in lines {
			ly := py + 4 + f32(li) * ed.char_h
			if li == 8 {
				fill_rect(renderer, {px + 4 * ed.char_w, ly, pw - 4 * ed.char_w, ed.char_h}, theme.current_line)
			}
			draw_text(renderer, font, fmt.tprint(li + 1), px + ed.char_w * (2 if li < 9 else 1), ly, theme.gutter_text, ed.char_h)
			tokens, next := ed.language.tokenize(line, state, context.temp_allocator)
			state = next
			lx := px + 5 * ed.char_w
			if li == 5 {
				// A selection over "p.x * k".
				fill_rect(renderer, {lx + 12 * ed.char_w, ly, 7 * ed.char_w, ed.char_h}, theme.selection)
			}
			for tok in tokens {
				draw_text(renderer, font, line[tok.start:tok.end], lx + f32(tok.start) * ed.char_w, ly, token_color(theme, tok.kind), ed.char_h)
			}
			if li == 8 {
				fill_rect(renderer, {lx + 9 * ed.char_w, ly + 2, 2, ed.char_h - 4}, theme.cursor)
			}
		}
	}
	render_window_footer(ed, renderer, font, theme, "Up/Down colour · Tab channel · Left/Right adjust (Shift x16) · Enter hex · Del reset · P preset · Esc close")
}
