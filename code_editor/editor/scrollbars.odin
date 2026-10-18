// Scrollbars: a vertical bar at the right of the text area (always shown
// when the document is taller than the view) and a horizontal bar at the
// bottom (shown when a line is wider than the view). Drag a thumb to
// scroll; click the track to jump there. The vertical track doubles as an
// overview ruler with marks for diagnostics, find matches and the caret.
package code_editor

import buf "../buffer"
import sdl "vendor:sdl3"

SCROLLBAR_SIZE :: 12
SCROLLBAR_MIN_THUMB :: 24

Scroll_Drag :: enum {
	None,
	Vertical,
	Horizontal,
}

Scrollbar_Layout :: struct {
	v_track, v_thumb: sdl.FRect,
	v_shown:          bool,
	h_track, h_thumb: sdl.FRect,
	h_shown:          bool,
}

@(private)
max_scroll_line :: proc(ed: ^Editor) -> int {
	return max(0, buf.buffer_line_count(&ed.buf) - 1)
}

@(private)
max_scroll_col :: proc(ed: ^Editor) -> int {
	return max(0, editor_max_visual_width(ed) - max(1, ed.visible_cols) + 1)
}

// editor_scrollbar_layout computes tracks and thumbs in window pixels.
editor_scrollbar_layout :: proc(ed: ^Editor) -> (l: Scrollbar_Layout) {
	if ed.char_w <= 0 || ed.char_h <= 0 {
		return
	}
	rows := editor_text_rows(ed)
	text_left := ed.origin_x + editor_gutter_width(ed)
	text_right := text_left + f32(ed.visible_cols) * ed.char_w
	text_h := f32(rows) * ed.char_h
	count := buf.buffer_line_count(&ed.buf)

	if count > rows {
		l.v_shown = true
		l.v_track = {text_right, ed.origin_y, SCROLLBAR_SIZE, text_h}
		// The scroll range lets the last line reach the top, so the
		// content height is (count - 1) + rows lines.
		total := f32(count - 1 + rows)
		th := max(text_h * f32(rows) / total, SCROLLBAR_MIN_THUMB)
		ty := ed.origin_y + (text_h - th) * f32(ed.scroll_line) / f32(max(1, max_scroll_line(ed)))
		l.v_thumb = {text_right + 2, ty, SCROLLBAR_SIZE - 4, th}
	}
	if max_col := max_scroll_col(ed); max_col > 0 && ed.scroll_col >= 0 && editor_max_visual_width(ed) > ed.visible_cols {
		l.h_shown = true
		track_w := text_right - text_left
		l.h_track = {text_left, ed.origin_y + text_h, track_w, SCROLLBAR_SIZE}
		total := f32(max_col + ed.visible_cols)
		tw := max(track_w * f32(ed.visible_cols) / total, SCROLLBAR_MIN_THUMB)
		tx := text_left + (track_w - tw) * f32(ed.scroll_col) / f32(max_col)
		l.h_thumb = {tx, ed.origin_y + text_h + 2, tw, SCROLLBAR_SIZE - 4}
	}
	return
}

// editor_scroll_to_track_pos scrolls so the thumb centre follows a pointer
// position (minus `grab`, the pointer's offset into the thumb).
@(private)
editor_scroll_to_track_pos :: proc(ed: ^Editor, drag: Scroll_Drag, x, y, grab: f32) {
	l := editor_scrollbar_layout(ed)
	switch drag {
	case .None:
	case .Vertical:
		if !l.v_shown {
			return
		}
		span := l.v_track.h - l.v_thumb.h
		frac := clamp((y - grab - l.v_track.y) / max(span, 1), 0, 1)
		ed.scroll_line = int(frac * f32(max_scroll_line(ed)) + 0.5)
	case .Horizontal:
		if !l.h_shown {
			return
		}
		span := l.h_track.w - l.h_thumb.w
		frac := clamp((x - grab - l.h_track.x) / max(span, 1), 0, 1)
		ed.scroll_col = int(frac * f32(max_scroll_col(ed)) + 0.5)
	}
	editor_clamp_scroll(ed)
}

// editor_scrollbar_press starts a thumb drag (or jumps when the track is
// clicked outside the thumb). Returns true if the press hit a scrollbar.
@(private)
editor_scrollbar_press :: proc(ed: ^Editor, x, y: f32) -> bool {
	l := editor_scrollbar_layout(ed)
	m := &ed.mouse
	switch {
	case l.v_shown && in_rect(l.v_track, x, y):
		m.scroll_drag = .Vertical
		if in_rect(l.v_thumb, x, y) {
			m.scroll_grab = y - l.v_thumb.y
		} else {
			m.scroll_grab = l.v_thumb.h / 2 // jump: centre the thumb here
			editor_scroll_to_track_pos(ed, .Vertical, x, y, m.scroll_grab)
		}
		return true
	case l.h_shown && in_rect(l.h_track, x, y):
		m.scroll_drag = .Horizontal
		if in_rect(l.h_thumb, x, y) {
			m.scroll_grab = x - l.h_thumb.x
		} else {
			m.scroll_grab = l.h_thumb.w / 2
			editor_scroll_to_track_pos(ed, .Horizontal, x, y, m.scroll_grab)
		}
		return true
	}
	return false
}

@(private)
render_scrollbars :: proc(ed: ^Editor, renderer: ^sdl.Renderer, theme: Theme) {
	l := editor_scrollbar_layout(ed)
	m := &ed.mouse
	if l.v_shown {
		fill_rect(renderer, l.v_track, theme.scrollbar_track)
		// Overview marks: where the problems, matches and caret are.
		count := f32(max(1, buf.buffer_line_count(&ed.buf)))
		mark_y :: proc(l: Scrollbar_Layout, line: int, count: f32) -> f32 {
			return l.v_track.y + l.v_track.h * f32(line) / count
		}
		if ed.find.open {
			for mt in ed.find.matches {
				fill_rect(renderer, {l.v_track.x + 2, mark_y(l, mt.start.line, count), 4, 2}, theme.find_current)
			}
		}
		for d in editor_diagnostics(ed) {
			fill_rect(renderer, {l.v_track.x + l.v_track.w - 5, mark_y(l, d.start.line, count), 4, 3}, severity_color(theme, d.severity))
		}
		thumb_color := theme.scrollbar_thumb
		if m.scroll_drag == .Vertical || in_rect(l.v_track, m.x, m.y) {
			thumb_color = theme.scrollbar_thumb_hover
		}
		fill_rect(renderer, l.v_thumb, thumb_color)
		cur := editor_primary_cursor(ed).pos.line
		fill_rect(renderer, {l.v_track.x, mark_y(l, cur, count), l.v_track.w, 1}, theme.text_default)
	}
	if l.h_shown {
		fill_rect(renderer, l.h_track, theme.scrollbar_track)
		thumb_color := theme.scrollbar_thumb
		if m.scroll_drag == .Horizontal || in_rect(l.h_track, m.x, m.y) {
			thumb_color = theme.scrollbar_thumb_hover
		}
		fill_rect(renderer, l.h_thumb, thumb_color)
	}
}
