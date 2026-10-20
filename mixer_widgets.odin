package crossfire_editor

import "core:fmt"
import "core:math"
import "core:time"
import "gui:skald"
import e "engine:."

/*
Widgets for a DAW-style mixer, generic over the message type and keeping their state here (like
`valueSlider`), so they can move into a widget package later:
- `hScroll`: content wider than its box, scrolled sideways (the wheel, or the bar under it);
  Skald's own scroll is vertical only
- `fader`: a vertical volume fader in decibels (-inf to +6 dB; unity at 0 dB)
- `panControl`: a small horizontal balance control, centered at 0
- `levelMeter`: a stereo peak meter on the fader's scale, with peak hold and a clip light

Faders and pan controls: drag to move (Shift is ten times finer), double-click or Ctrl+click to
reset. The meter's level falls at `METER_FALL_DB` per second; its peak holds `METER_HOLD`.
*/

// The fader's range: its bottom is silence, its top +6 dB (a gain of 2)
FADER_MIN_DB :: f32(-60)
FADER_MAX_DB :: f32(6.0206)
// Below the fader's range, a gain is shown as silence
FADER_SILENT_GAIN :: f32(0.001)
METER_FALL_DB :: f32(24)
METER_HOLD :: 1500 * time.Millisecond
METER_CLIP_HOLD :: 2 * time.Second
H_SCROLL_BAR :: f32(10)
H_SCROLL_THIN :: f32(3)

/*
Where a gain sits on a fader (0 bottom, 1 top), in decibels: the same scale as the meter.

Example:
	assert(Fader_GainToPosition(2) == 1)
*/
Fader_GainToPosition :: proc(gain: f32) -> f32 {
	if gain <= FADER_SILENT_GAIN do return 0
	db := 20 * math.log10(gain)
	return math.clamp((db - FADER_MIN_DB) / (FADER_MAX_DB - FADER_MIN_DB), 0, 1)
}

// The gain at a fader position (0 is silence); within 0.25 dB of unity it's exactly 1
Fader_PositionToGain :: proc(position: f32) -> f32 {
	if position <= 0 do return 0
	db := FADER_MIN_DB + math.clamp(position, 0, 1) * (FADER_MAX_DB - FADER_MIN_DB)
	if abs(db) < 0.25 do return 1
	// Rounded to a tenth of a dB, so saved values stay short-ish and repeatable
	db = math.round(db * 10) / 10
	return math.pow(10, db / 20)
}

// "-3.2 dB", "+6.0 dB", "-inf"
Fader_Text :: proc(gain: f32) -> string {
	if gain <= FADER_SILENT_GAIN do return "-inf"
	db := 20 * math.log10(gain)
	if abs(db) < 0.05 do return "0.0 dB"
	return fmt.tprintf("%+.1f dB", db)
}

// "C", "L40", "R25"
Pan_Text :: proc(pan: f32) -> string {
	p := int(math.round(pan * 100))
	if p == 0 do return "C"
	return p < 0 ? fmt.tprintf("L%d", -p) : fmt.tprintf("R%d", p)
}

/*
A box `width` x `height` showing `content` scrolled sideways, with a scroll bar under it when the
content is wider (the bar's height is part of `height`). The wheel over it scrolls it.

With `thin`, the bar is a thin line under the content, and its row is there (empty) even when
nothing overflows: the whole is always `height` + H_SCROLL_THIN tall (a header that grew when its
tabs overflowed would move what's under it).

Widget keys: the box is `key`, the bar `key-bar`.
*/
hScroll :: proc(ctx: ^skald.Ctx($Msg), key: string, content: skald.View, width, height: f32, thin := false) -> skald.View {
	th := ctx.theme
	id := skald.hash_id(key)
	barId := skald.hash_id(fmt.tprintf("%s-bar", key))
	contentWidth := skald.view_size(ctx.renderer, content).x
	maxOffset := max(contentWidth - width, 0)
	if hScrollToEnd == id {
		hScrollOffsets[id] = maxOffset
		hScrollToEnd = 0
	}
	offset := math.clamp(hScrollOffsets[id], 0, maxOffset)
	popupOpen := len(ctx.widgets.overlay_rects_prev) > 0
	mouse := ctx.input.mouse_pos

	if state, drawn := ctx.widgets.states[id]; drawn && maxOffset > 0 && !popupOpen && rectHas(state.last_rect, mouse) {
		wheel := ctx.input.scroll
		delta := wheel.x != 0 ? wheel.x : wheel.y
		if delta != 0 {
			offset = math.clamp(offset - delta * 40, 0, maxOffset)
			ctx.input.scroll = {}
		}
	}
	thumbWidth := maxOffset > 0 ? max(width * width / contentWidth, 24) : width
	if state, drawn := ctx.widgets.states[barId]; drawn && maxOffset > 0 {
		rect := state.last_rect
		travel := max(rect.w - thumbWidth, 1)
		thumbX := rect.x + offset / maxOffset * travel
		if ctx.input.mouse_pressed[.Left] && !popupOpen && rectHas(rect, mouse) {
			// On the thumb: drag it; elsewhere: jump there
			if mouse.x < thumbX || mouse.x > thumbX + thumbWidth {
				offset = math.clamp((mouse.x - rect.x - thumbWidth * 0.5) / travel * maxOffset, 0, maxOffset)
			}
			hScrollDrag = {barId, mouse.x, offset}
		} else if hScrollDrag.id == barId {
			if !ctx.input.mouse_buttons[.Left] do hScrollDrag = {}
			else do offset = math.clamp(hScrollDrag.anchorOffset + (mouse.x - hScrollDrag.anchorX) / travel * maxOffset, 0, maxOffset)
		}
	}
	hScrollOffsets[id] = offset

	boxHeight := maxOffset > 0 && !thin ? height - H_SCROLL_BAR - 2 : height
	shifted := skald.row(skald.spacer(-offset), content, spacing = 0)
	inner := new(skald.View, context.temp_allocator)
	inner^ = skald.clip({width, max(boxHeight, 0)}, shifted)
	box: skald.View = skald.View_Zone{id = id, child = inner}
	if maxOffset == 0 do return thin ? skald.col(box, skald.spacer(H_SCROLL_THIN), spacing = 0) : box

	Bar :: struct { fraction, thumb: f32, rail, fill: skald.Color }
	bar := new_clone(Bar{offset / maxOffset, thumbWidth, th.color.surface, th.color.fg_muted}, context.temp_allocator)
	canvas := skald.canvas(ctx, bar, proc(b: ^Bar, p: skald.Canvas_Painter) {
		r := p.bounds
		skald.draw_rect(p.r, r, b.rail, r.h * 0.5)
		x := r.x + b.fraction * (r.w - b.thumb)
		skald.draw_rect(p.r, {x, r.y + 1, b.thumb, r.h - 2}, b.fill, (r.h - 2) * 0.5)
	}, id = barId, width = width, height = thin ? H_SCROLL_THIN : H_SCROLL_BAR)
	return skald.col(box, canvas, spacing = thin ? 0 : 2)
}

/*
A vertical volume fader: `gain` from 0 to 2 on a decibel scale with marks, its cap dragged up and
down. A press off the cap jumps it there.

Widget key: `key`.
*/
fader :: proc(ctx: ^skald.Ctx($Msg), key: string, gain: f32, payload: $P, on_change: proc(payload: P, gain: f32) -> Msg, height: f32, width: f32 = FADER_WIDTH) -> skald.View {
	th := ctx.theme
	id := skald.hash_id(key)
	position := Fader_GainToPosition(gain)
	// Focused (clicked or tabbed to): the arrow keys move it a hundredth of its travel (Shift: 10)
	skald.widget_make_focusable(ctx, id)
	if steps := arrowSteps(ctx, id); steps != 0 {
		if g := Fader_PositionToGain(math.clamp(position + f32(steps) * 0.01, 0, 1)); g != gain do skald.send(ctx, on_change(payload, g))
	}
	if state, drawn := ctx.widgets.states[id]; drawn && state.last_rect.h > 0 {
		rect := state.last_rect
		usable := max(rect.h - FADER_CAP_HEIGHT, 1)
		capY := rect.y + (1 - position) * usable
		mouse := ctx.input.mouse_pos
		fine := .Shift in ctx.input.modifiers
		popupOpen := len(ctx.widgets.overlay_rects_prev) > 0
		if ctx.input.mouse_pressed[.Left] && !popupOpen && skald.widget_hovered(ctx, id) && rectHas(state.clip_rect, mouse, true) {
			skald.widget_focus(ctx, id)
			if ctx.input.mouse_click_count[.Left] >= 2 || .Ctrl in ctx.input.modifiers {
				if gain != 1 do skald.send(ctx, on_change(payload, 1))
			} else {
				p := position
				if !fine && (mouse.y < capY || mouse.y > capY + FADER_CAP_HEIGHT) {
					p = math.clamp(1 - (mouse.y - rect.y - FADER_CAP_HEIGHT * 0.5) / usable, 0, 1)
					if g := Fader_PositionToGain(p); g != gain do skald.send(ctx, on_change(payload, g))
				}
				controlDrag = {id, mouse.y, p, fine}
			}
		} else if controlDrag.id == id {
			if !ctx.input.mouse_buttons[.Left] {
				controlDrag = {}
			} else {
				if fine != controlDrag.fine do controlDrag = {id, mouse.y, position, fine}
				scale: f32 = fine ? 0.1 : 1
				p := math.clamp(controlDrag.anchorValue + (controlDrag.anchor - mouse.y) / usable * scale, 0, 1)
				if g := Fader_PositionToGain(p); g != gain do skald.send(ctx, on_change(payload, g))
			}
		}
	}

	Track :: struct { position: f32, rail, mark, cap, line: skald.Color }
	track := new_clone(Track{position, th.color.bg, th.color.fg_muted, th.color.fg, th.color.primary}, context.temp_allocator)
	return skald.canvas(ctx, track, proc(t: ^Track, p: skald.Canvas_Painter) {
		b := p.bounds
		usable := b.h - FADER_CAP_HEIGHT
		top := b.y + FADER_CAP_HEIGHT * 0.5
		// Marks: +6, 0 (longer), -6, -12, -24, -40, -60
		for db in ([]f32{6, 0, -6, -12, -24, -40, -60}) {
			y := top + (1 - (db - FADER_MIN_DB) / (FADER_MAX_DB - FADER_MIN_DB)) * usable
			long: f32 = db == 0 ? 0 : 4
			mark := t.mark
			mark[3] = db == 0 ? 0.9 : 0.5
			skald.draw_rect(p.r, {b.x + long, y, b.w - long * 2, 1}, mark)
		}
		skald.draw_rect(p.r, {b.x + b.w * 0.5 - 2, top, 4, usable}, t.rail, 2)
		capY := b.y + (1 - t.position) * usable
		skald.draw_rect(p.r, {b.x + 1, capY, b.w - 2, FADER_CAP_HEIGHT}, t.cap, 3)
		skald.draw_rect(p.r, {b.x + 3, capY + FADER_CAP_HEIGHT * 0.5 - 1, b.w - 6, 2}, t.line)
	}, id = id, width = width, height = height, cursor = .NS_Resize)
}

FADER_CAP_HEIGHT :: f32(16)
FADER_WIDTH :: f32(20)
METER_WIDTH :: f32(12)

/*
A balance control from -1 (left) to 1 (right): a bar filled from the center, dragged sideways.

Widget key: `key`.
*/
panControl :: proc(ctx: ^skald.Ctx($Msg), key: string, pan: f32, payload: $P, on_change: proc(payload: P, pan: f32) -> Msg, width: f32) -> skald.View {
	th := ctx.theme
	id := skald.hash_id(key)
	settle :: proc(v: f32) -> f32 { return math.clamp(math.round(v * 100) / 100, -1, 1) }
	// Focused: the arrow keys move it by 0.01 (Shift: 0.1)
	skald.widget_make_focusable(ctx, id)
	if steps := arrowSteps(ctx, id); steps != 0 {
		if v := settle(pan + f32(steps) * 0.01); v != pan do skald.send(ctx, on_change(payload, v))
	}
	if state, drawn := ctx.widgets.states[id]; drawn && state.last_rect.w > 0 {
		rect := state.last_rect
		mouse := ctx.input.mouse_pos
		fine := .Shift in ctx.input.modifiers
		popupOpen := len(ctx.widgets.overlay_rects_prev) > 0
		if ctx.input.mouse_pressed[.Left] && !popupOpen && skald.widget_hovered(ctx, id) && rectHas(state.clip_rect, mouse, true) {
			skald.widget_focus(ctx, id)
			if ctx.input.mouse_click_count[.Left] >= 2 || .Ctrl in ctx.input.modifiers {
				if pan != 0 do skald.send(ctx, on_change(payload, 0))
			} else {
				controlDrag = {id, mouse.x, pan, fine}
			}
		} else if controlDrag.id == id {
			if !ctx.input.mouse_buttons[.Left] {
				controlDrag = {}
			} else {
				if fine != controlDrag.fine do controlDrag = {id, mouse.x, pan, fine}
				scale: f32 = fine ? 0.1 : 1
				v := settle(controlDrag.anchorValue + (mouse.x - controlDrag.anchor) / rect.w * 2 * scale)
				if v != pan do skald.send(ctx, on_change(payload, v))
			}
		}
	}
	Bar :: struct { pan: f32, rail, fill, mark: skald.Color }
	bar := new_clone(Bar{pan, th.color.bg, th.color.primary, th.color.fg}, context.temp_allocator)
	return skald.canvas(ctx, bar, proc(b: ^Bar, p: skald.Canvas_Painter) {
		r := p.bounds
		y := r.y + r.h * 0.5 - 3
		skald.draw_rect(p.r, {r.x, y, r.w, 6}, b.rail, 3)
		center := r.x + r.w * 0.5
		x := center + b.pan * r.w * 0.5
		skald.draw_rect(p.r, {min(center, x), y, abs(x - center), 6}, b.fill, 3)
		skald.draw_rect(p.r, {center - 0.5, r.y + 1, 1, r.h - 2}, b.mark)
		skald.draw_rect(p.r, {x - 2, r.y, 4, r.h}, b.mark, 2)
	}, id = id, width = width, height = 14, cursor = .EW_Resize)
}

/*
A stereo peak meter `height` tall on the fader's scale (0 dB level with the fader's 0 dB), fed
with the levels read this frame (0 to 1 per side). It keeps what it shows under `key`.

Returns:
- The meter, and whether it's still moving (keep frames coming)
*/
levelMeter :: proc(ctx: ^skald.Ctx($Msg), key: string, level: [2]f32, height: f32, width: f32 = METER_WIDTH) -> (view: skald.View, moving: bool) {
	th := ctx.theme
	id := skald.hash_id(key)
	now := time.now()
	m, known := meters[id]
	if !known do m = {shown = e.AUDIO_SILENCE_DB, hold = e.AUDIO_SILENCE_DB, last = now}
	dt := f32(time.duration_seconds(time.diff(m.last, now)))
	m.last = now
	for side in 0 ..< 2 {
		db := e.AudioLevel_ToDecibels(level[side])
		m.shown[side] = max(db, m.shown[side] - METER_FALL_DB * min(dt, 0.25))
		if m.shown[side] < FADER_MIN_DB do m.shown[side] = e.AUDIO_SILENCE_DB
		// The peak holds, then falls with the level
		if db >= m.hold[side] {
			m.hold[side] = db
			m.holdAt[side] = now
		} else if time.diff(m.holdAt[side], now) > METER_HOLD {
			m.hold[side] = m.shown[side]
		}
		if level[side] > 1 do m.clipAt = now
	}
	clip := m.clipAt != {} && time.diff(m.clipAt, now) < METER_CLIP_HOLD
	meters[id] = m
	moving = m.shown[0] > FADER_MIN_DB || m.shown[1] > FADER_MIN_DB || m.hold[0] > FADER_MIN_DB || m.hold[1] > FADER_MIN_DB || clip

	Bars :: struct { shown, hold: [2]f32, clip: bool, rail, low, mid, high: skald.Color }
	bars := new_clone(Bars{m.shown, m.hold, clip, th.color.bg, skald.rgb(0x4cc26a), skald.rgb(0xe0c341), skald.rgb(0xe0533d)}, context.temp_allocator)
	view = skald.canvas(ctx, bars, proc(b: ^Bars, p: skald.Canvas_Painter) {
		r := p.bounds
		usable := r.h - FADER_CAP_HEIGHT
		top := r.y + FADER_CAP_HEIGHT * 0.5
		yOf :: proc(db, top, usable: f32) -> f32 {
			return top + (1 - math.clamp((db - FADER_MIN_DB) / (FADER_MAX_DB - FADER_MIN_DB), 0, 1)) * usable
		}
		// The clip light, above the scale
		light := b.clip ? b.high : b.rail
		skald.draw_rect(p.r, {r.x, r.y, r.w, FADER_CAP_HEIGHT * 0.5 - 2}, light, 1)
		barW := (r.w - 2) * 0.5
		for side in 0 ..< 2 {
			x := r.x + f32(side) * (barW + 2)
			skald.draw_rect(p.r, {x, top, barW, usable}, b.rail, 1)
			if b.shown[side] > FADER_MIN_DB {
				// Green to -12 dB, yellow to -3 dB, red above
				y := yOf(b.shown[side], top, usable)
				bottom := top + usable
				for zone in ([][3]f32{{FADER_MIN_DB, -12, 0}, {-12, -3, 1}, {-3, FADER_MAX_DB, 2}}) {
					zoneTop := max(yOf(zone[1], top, usable), y)
					zoneBottom := min(yOf(zone[0], top, usable), bottom)
					if zoneBottom <= zoneTop do continue
					color := zone[2] == 0 ? b.low : zone[2] == 1 ? b.mid : b.high
					skald.draw_rect(p.r, {x, zoneTop, barW, zoneBottom - zoneTop}, color)
				}
			}
			if b.hold[side] > FADER_MIN_DB {
				color := b.hold[side] > -3 ? b.high : b.hold[side] > -12 ? b.mid : b.low
				skald.draw_rect(p.r, {x, yOf(b.hold[side], top, usable), barW, 2}, color)
			}
		}
	}, id = id, width = width, height = height)
	return
}

// The loudest side a level meter shows now, in dB (AUDIO_SILENCE_DB before it has shown anything)
levelMeter_Shown :: proc(key: string) -> f32 {
	m, known := meters[skald.hash_id(key)]
	return known ? max(m.shown[0], m.shown[1]) : e.AUDIO_SILENCE_DB
}

@(private="file")
rectHas :: proc(r: skald.Rect, p: [2]f32, emptyIsAll := false) -> bool {
	if emptyIsAll && r.w <= 0 && r.h <= 0 do return true
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

/*
Scrolls an hScroll just enough to show a widget inside it (from last frame's layout), when that
widget changed since the last call: a newly chosen tab comes into view, and scrolling away from it
afterwards stays put. Call it before building the hScroll.
*/
hScroll_Reveal :: proc(ctx: ^skald.Ctx($Msg), key: string, widget: skald.Widget_ID) {
	id := skald.hash_id(key)
	if hScrollRevealed[id] == widget do return
	box, boxDrawn := ctx.widgets.states[id]
	target, drawn := ctx.widgets.states[widget]
	if !boxDrawn || !drawn || box.last_rect.w <= 0 || target.last_rect.w <= 0 do return
	hScrollRevealed[id] = widget
	b, t := box.last_rect, target.last_rect
	switch {
	case t.x < b.x:                 hScrollOffsets[id] -= b.x - t.x
	case t.x + t.w > b.x + b.w:     hScrollOffsets[id] += t.x + t.w - (b.x + b.w)
	case:                           return
	}
	hScrollOffsets[id] = max(hScrollOffsets[id], 0)
}

@(private="file")
hScrollRevealed: map[skald.Widget_ID]skald.Widget_ID

// Scrolls an hScroll to its end the next time it's built (to show what was just added there)
hScroll_ScrollToEnd :: proc(key: string) {
	hScrollToEnd = skald.hash_id(key)
}

@(private="file")
hScrollToEnd: skald.Widget_ID

// Each hScroll's offset, by widget id
@(private="file")
hScrollOffsets: map[skald.Widget_ID]f32

@(private="file")
hScrollDrag: struct {
	id: skald.Widget_ID,
	anchorX, anchorOffset: f32,
}

// The fader or pan control being dragged: where it started (or last changed speed), from what value
@(private="file")
controlDrag: struct {
	id: skald.Widget_ID,
	anchor, anchorValue: f32,
	fine: bool,
}

@(private="file")
MeterState :: struct {
	// What it shows and its peak hold, in dB; when the hold and the clip light were set
	shown, hold: [2]f32,
	holdAt: [2]time.Time,
	clipAt: time.Time,
	last: time.Time,
}

@(private="file")
meters: map[skald.Widget_ID]MeterState
