package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "gui:skald"

/*
A slider for a number, with what Skald's slider doesn't have:
- the value beside it is a text box: type a number (it applies as soon as it parses, clamped to
  the range; the box shows the value again when it loses focus)
- hold Shift while dragging to move ten times finer (pressing with Shift held doesn't jump to the
  pointer, so a value can be nudged from where it is)
- a reset button that puts the default back (shown when there is a default; dimmed at it)

It's generic over the app's message type and keeps its state (the drag, the typed text) here,
not in the app's State, so it can move into a widget package of its own later.

Widget keys: the track is `key`, the text box `key-value`, the reset button `key-reset`.

Example:
	onAmount :: proc(name: string, v: f32) -> Msg { return Particle_Field_Changed{name, fmt.tprintf("%d", int(v))} }
	valueSlider(ctx, "amount-slider", 50, "amount", onAmount, 1, 500, step = 1, decimals = 0, defaultValue = 50, width = 200)
*/
valueSlider :: proc(
	ctx: ^skald.Ctx($Msg),
	key: string,
	value: f32,
	payload: $P,
	on_change: proc(payload: P, value: f32) -> Msg,
	minValue, maxValue: f32,
	step: f32 = 0,
	decimals := 2,
	defaultValue: Maybe(f32) = nil,
	width: f32 = 160,
) -> skald.View {
	th := ctx.theme
	trackId := skald.hash_id(key)
	textId := skald.hash_id(fmt.tprintf("%s-value", key))
	resetId := skald.hash_id(fmt.tprintf("%s-reset", key))
	span := max(maxValue - minValue, 1e-6)
	// To the step (a tenth of it while fine-tuning), within the range
	settle :: proc(v, lo, hi, step: f32) -> f32 {
		v := step > 0 ? math.round(v / step) * step : v
		v = math.clamp(v, lo, hi)
		// Rounding a little under zero gives -0, which files would get as "-0"
		if v == 0 do v = 0
		return v
	}

	// Tab reaches the track; while it has focus the arrow keys step it (Shift: 10 steps)
	skald.widget_make_focusable(ctx, trackId)
	trackFocused := skald.widget_has_focus(ctx, trackId)
	if steps := arrowSteps(ctx, trackId); steps != 0 {
		unit := step > 0 ? step : span / 100
		if v := settle(value + f32(steps) * unit, minValue, maxValue, step); v != value do skald.send(ctx, on_change(payload, v))
	}

	// The track: from last frame's rect, like Skald's own widgets
	if state, drawn := ctx.widgets.states[trackId]; drawn && state.last_rect.w > 0 {
		rect := state.last_rect
		mouse := ctx.input.mouse_pos
		fine := .Shift in ctx.input.modifiers
		// While a popup is open, a press outside it only closes it
		popupOpen := len(ctx.widgets.overlay_rects_prev) > 0
		if ctx.input.mouse_pressed[.Left] && !popupOpen && skald.widget_hovered(ctx, trackId) {
			v := value
			if !fine do v = settle(minValue + math.clamp((mouse.x - rect.x) / rect.w, 0, 1) * span, minValue, maxValue, step)
			sliderDrag = {trackId, mouse.x, v, fine}
			skald.widget_focus(ctx, trackId)
			if v != value do skald.send(ctx, on_change(payload, v))
		} else if sliderDrag.id == trackId {
			if !ctx.input.mouse_buttons[.Left] {
				sliderDrag = {}
			} else {
				// Shift pressed or let go mid-drag: carry on from here at the new speed
				if fine != sliderDrag.fine do sliderDrag = {trackId, mouse.x, value, fine}
				scale: f32 = fine ? 0.1 : 1
				v := settle(sliderDrag.anchorValue + (mouse.x - sliderDrag.anchorX) / rect.w * span * scale, minValue, maxValue, fine ? step * 0.1 : step)
				if v != value do skald.send(ctx, on_change(payload, v))
			}
		}
	}

	// The value: typed text while the box has focus
	focused := skald.widget_has_focus(ctx, textId)
	if sliderEdit.id == textId && !focused {
		delete(sliderEdit.text)
		sliderEdit = {}
	}
	// Narrow sliders get a narrower box; the whole row always fits `width`
	textWidth := math.clamp(width * 0.3, 32, SLIDER_TEXT_WIDTH)
	text := sliderEdit.id == textId ? strings.clone(sliderEdit.text, context.temp_allocator) : formatSliderValue(value, decimals)
	Typed :: struct {
		inner: P,
		on_change: proc(payload: P, value: f32) -> Msg,
		id: skald.Widget_ID,
		lo, hi: f32,
	}
	box := skald.text_input(ctx, text, Typed{payload, on_change, textId, minValue, maxValue}, proc(t: Typed, typed: string) -> Msg {
		delete(sliderEdit.text)
		sliderEdit = {t.id, strings.clone(typed)}
		v, ok := strconv.parse_f32(strings.trim_space(typed))
		if !ok do return {}
		return t.on_change(t.inner, math.clamp(v, t.lo, t.hi))
	}, id = textId, width = textWidth, padding = {th.spacing.xs, 1}, font_size = th.font.size_xs)

	reset: skald.View = skald.View_Spacer{size = 0}
	resetWidth: f32 = 0
	if d, hasDefault := defaultValue.?; hasDefault {
		atDefault := abs(value - d) < 1e-6
		resetWidth = SLIDER_RESET_WIDTH
		button := skald.button(ctx, ICON_UNDO, on_change(payload, d), id = resetId,
			bg = th.color.surface, fg = atDefault ? th.color.fg_muted : th.color.fg,
			width = SLIDER_RESET_WIDTH, padding = {0, 1}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = atDefault)
		reset = skald.tooltip(ctx, button, fmt.tprintf("Reset to %s", formatSliderValue(d, decimals)), id = skald.hash_id(fmt.tprintf("%s-reset-tip", key)))
	}

	Track :: struct { fraction: f32, fill, rail, thumb: skald.Color }
	// A focused track's thumb takes the accent color: the arrow keys move it
	track := new_clone(Track{math.clamp((value - minValue) / span, 0, 1), th.color.primary, th.color.border, trackFocused ? th.color.primary : th.color.fg}, context.temp_allocator)
	trackWidth := max(width - textWidth - resetWidth - th.spacing.xs * 2, 16)
	canvas := skald.canvas(ctx, track, proc(t: ^Track, p: skald.Canvas_Painter) {
		b := p.bounds
		THUMB :: 6
		railY := b.y + b.h * 0.5 - 2
		usable := b.w - THUMB * 2
		x := b.x + THUMB + usable * t.fraction
		skald.draw_rect(p.r, {b.x + THUMB, railY, usable, 4}, t.rail, 2)
		skald.draw_rect(p.r, {b.x + THUMB, railY, x - b.x - THUMB, 4}, t.fill, 2)
		skald.draw_rect(p.r, {x - THUMB, b.y + b.h * 0.5 - THUMB, THUMB * 2, THUMB * 2}, t.thumb, THUMB)
	}, id = trackId, width = trackWidth, height = 18, cursor = .EW_Resize)
	return skald.row(canvas, box, reset, spacing = th.spacing.xs, cross_align = .Center)
}

/*
The arrow keys pressed this frame for a focused control: +1 for Right or Up, -1 for Left or
Down, times 10 with Shift. 0 when the control doesn't have focus.

Inputs:
- id: The control's widget id
- upDownOnly: Only Up and Down count (a text box, whose Left and Right move the caret)
*/
arrowSteps :: proc(ctx: ^skald.Ctx($Msg), id: skald.Widget_ID, upDownOnly := false) -> int {
	if !skald.widget_has_focus(ctx, id) do return 0
	keys := ctx.input.keys_pressed
	steps := 0
	if .Up in keys do steps += 1
	if .Down in keys do steps -= 1
	if !upDownOnly {
		if .Right in keys do steps += 1
		if .Left in keys do steps -= 1
	}
	if .Shift in ctx.input.modifiers do steps *= 10
	return steps
}

// Widest a value slider's text box gets, and its reset button's width
SLIDER_TEXT_WIDTH :: 46
SLIDER_RESET_WIDTH :: 18

// The slider being dragged: where the drag (or its last change of speed) started, at what value
@(private="file")
sliderDrag: struct {
	id: skald.Widget_ID,
	anchorX, anchorValue: f32,
	fine: bool,
}

// The text typed into a value slider's box (owned)
@(private="file")
sliderEdit: struct {
	id: skald.Widget_ID,
	text: string,
}

// A value with at most `decimals` decimals, trailing zeros dropped ("0.25", "100", not "0.2500")
formatSliderValue :: proc(value: f32, decimals: int) -> string {
	text := fmt.tprintf("%.*f", max(decimals, 0), value)
	if strings.contains_rune(text, '.') do text = strings.trim_right(strings.trim_right(text, "0"), ".")
	if text == "-0" do text = "0"
	return text
}
