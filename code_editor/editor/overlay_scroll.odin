// Scrolling for overlays (popups, menus, panels, tool windows) whose content is taller than the
// room they get: an editor hosted in a short pane (a few hundred pixels) can't show a 10-row
// completion list, a 14-item context menu or a long hover whole. Each overlay fits its height to
// the visible area (`overlay_rows_fit`), keeps a scroll offset in rows (`overlay_scroll_clamp`,
// `overlay_scroll_reveal`), takes the wheel over it (`overlay_wheel_rows`), maps clicks through
// the offset, and draws a scrollbar along its right edge when it doesn't all fit
// (`render_overlay_scrollbar`, `overlay_scrollbar_rect`).
package code_editor

import sdl "vendor:sdl3"

// The width of an overlay's scrollbar, and its thumb's shortest length (pixels)
OVERLAY_SCROLLBAR_W :: 6
OVERLAY_SCROLLBAR_MIN_THUMB :: 12

// overlay_rows_fit is how many rows of `ed.char_h` fit in `height` pixels once `chrome` (padding,
// a title row) is taken off: at least 1, at most `wanted`.
overlay_rows_fit :: proc(ed: ^Editor, height: f32, wanted: int, chrome: f32 = 2 * POPUP_PAD) -> int {
	if ed.char_h <= 0 {
		return max(wanted, 1)
	}
	return clamp(int((height - chrome) / ed.char_h), 1, max(wanted, 1))
}

// overlay_view_top / overlay_view_bottom bound the text area overlays live in (above the problems
// and references panels).
overlay_view_top :: proc(ed: ^Editor) -> f32 {
	return ed.origin_y
}

overlay_view_bottom :: proc(ed: ^Editor) -> f32 {
	return ed.origin_y + f32(editor_text_rows(ed)) * ed.char_h
}

// overlay_scroll_clamp keeps a scroll offset (the first row shown) within 0 .. total - visible.
overlay_scroll_clamp :: proc(scroll, total, visible: int) -> int {
	return clamp(scroll, 0, max(0, total - visible))
}

// overlay_scroll_reveal is the scroll offset that shows row `index`, moving as little as possible.
overlay_scroll_reveal :: proc(scroll, index, total, visible: int) -> int {
	s := scroll
	if index < s {
		s = index
	} else if index >= s + visible {
		s = index - visible + 1
	}
	return overlay_scroll_clamp(s, total, visible)
}

// overlay_wheel_rows turns a wheel event's delta into rows to scroll an overlay by (wheel down:
// positive), carrying trackpads' fractions over between events like the text view does.
overlay_wheel_rows :: proc(ed: ^Editor, dy: f32) -> int {
	m := &ed.mouse
	m.wheel_acc_y += -dy
	rows := int(m.wheel_acc_y)
	m.wheel_acc_y -= f32(rows)
	return rows
}

// overlay_scrollbar_rect is the track of the scrollbar along `rect`'s right edge (inside its
// border), and whether there is one (the content doesn't all fit).
overlay_scrollbar_rect :: proc(rect: sdl.FRect, total, visible: int) -> (track: sdl.FRect, shown: bool) {
	if total <= visible || visible <= 0 {
		return {}, false
	}
	return {rect.x + rect.w - OVERLAY_SCROLLBAR_W - 1, rect.y + 1, OVERLAY_SCROLLBAR_W, rect.h - 2}, true
}

// render_overlay_scrollbar draws the scrollbar of an overlay showing rows scroll ..
// scroll + visible of total, along `rect`'s right edge; nothing when it all fits.
render_overlay_scrollbar :: proc(renderer: ^sdl.Renderer, rect: sdl.FRect, total, visible, scroll: int, theme: Theme) {
	track, shown := overlay_scrollbar_rect(rect, total, visible)
	if !shown {
		return
	}
	fill_rect(renderer, track, theme.scrollbar_track)
	th := max(track.h * f32(visible) / f32(total), min(OVERLAY_SCROLLBAR_MIN_THUMB, track.h))
	ty := track.y + (track.h - th) * f32(scroll) / f32(max(total - visible, 1))
	fill_rect(renderer, {track.x + 1, ty, track.w - 2, th}, theme.scrollbar_thumb)
}

// The most lines a text popup (completion docs, hover, a diagnostic's message) holds; it shows
// as many as fit and scrolls through the rest
POPUP_MAX_LINES :: 400

// Popup_Scroll is a text popup's scroll offset, kept for what it shows (`key`): showing
// something else (another completion item, hover position, diagnostic) starts at the top again
// without anything having to reset it.
Popup_Scroll :: struct {
	key:    u64,
	scroll: int,
}

// popup_scroll_get is the offset for `key` (0 when the popup shows something else now).
popup_scroll_get :: proc(ps: ^Popup_Scroll, key: u64) -> int {
	return ps.scroll if ps.key == key else 0
}

// popup_scroll_by scrolls the popup showing `key` by `rows`, kept within its lines.
popup_scroll_by :: proc(ps: ^Popup_Scroll, key: u64, rows, total, visible: int) {
	ps.scroll = overlay_scroll_clamp(popup_scroll_get(ps, key) + rows, total, visible)
	ps.key = key
}

// popup_rows_of is how many rows a text popup's rect shows (its height less the padding).
popup_rows_of :: proc(ed: ^Editor, rect: sdl.FRect) -> int {
	if ed.char_h <= 0 {
		return 0
	}
	return max(int((rect.h - 2 * POPUP_PAD) / ed.char_h + 0.5), 0)
}

/*
place_popup puts a popup of `lines` lines above or below an anchor (a row from anchor_top to
anchor_bottom): whole on the preferred side when it fits there, else whole on the other, else on
the roomier side with as many lines as fit (it scrolls).

Returns:
- Its top, its height, and the lines it shows
*/
place_popup :: proc(ed: ^Editor, lines: int, anchor_top, anchor_bottom: f32, prefer_above: bool) -> (y, h: f32, rows: int) {
	room_above := anchor_top - 2 - overlay_view_top(ed)
	room_below := overlay_view_bottom(ed) - (anchor_bottom + 2)
	full := f32(lines) * ed.char_h + 2 * POPUP_PAD
	above: bool
	if prefer_above {
		above = full <= room_above || (full > room_below && room_above >= room_below)
	} else {
		above = !(full <= room_below || (full > room_above && room_below >= room_above))
	}
	rows = overlay_rows_fit(ed, above ? room_above : room_below, lines)
	h = f32(rows) * ed.char_h + 2 * POPUP_PAD
	y = above ? anchor_top - 2 - h : anchor_bottom + 2
	return
}
