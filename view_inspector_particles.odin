package editor

import "core:fmt"
import "core:math"
import "core:strconv"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
The inspector's ParticleEmitter properties: every field of the engine's `e.ParticleSettings`, by
its type and tags (`e.ParticleSettings_Fields`), so a field added there shows up here:
- numbers with a `min` / `max` range: sliders (with the value beside them)
- `[2]f32`: a slider per axis, with a link toggle (linked, one axis drags the other in proportion)
- `bool`: checkboxes; enums: dropdowns
- colors: a color picker and an alpha slider
- the color ramp: a gradient bar with a marker per stop (`colorRampEditor`)
The Texture shape adds the node's texture; Reset puts every setting back to the defaults.

Edits are `Particle_Field_Changed` (a setting as text) and `Particle_Axis_Changed`; both are
undoable, merged per field. Widget keys: `inspector-particle-<field>-<node>` (`-x` / `-y`,
`-alpha`), `inspector-particle-link-<field>`, `inspector-particles-reset-<node>`,
`inspector-ramp-<node>` (the bar), `inspector-ramp-add-<node>`, `inspector-ramp-remove-<node>`,
`inspector-ramp-position-<node>`, `inspector-ramp-color-<node>`, `inspector-ramp-alpha-<node>`.
*/

// Width of the value shown beside a slider
@(private="file")
SLIDER_VALUE_WIDTH :: 40
@(private="file")
RAMP_BAR_HEIGHT :: 22
@(private="file")
RAMP_MARKER_HEIGHT :: 14
// How close (px) a press must be to a stop's marker to grab it
@(private="file")
RAMP_GRAB_DISTANCE :: 6

@(private="package")
particleInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	settings := node.particles
	resetButton := skald.button(ctx, fmt.tprintf("%s  Reset to defaults", ICON_UNDO), Msg(Particles_Reset{}),
		id = skald.hash_id(fmt.tprintf("inspector-particles-reset-%d", key)),
		bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	append(&rows, inspectorRow(ctx, "", skald.tooltip(ctx, resetButton, "Put every particle setting back to its default (undoable)",
		id = skald.hash_id(fmt.tprintf("inspector-particles-reset-tip-%d", key)))))

	for field, index in e.ParticleSettings_Fields() {
		if field.group != "" {
			append(&rows, skald.spacer(th.spacing.xs), skald.text(field.group, th.color.fg, th.font.size_xs))
		}
		// The ramp replaces the start and end colors when it's on
		switch field.name {
		case "colorRamp":
			if !settings.useColorRamp do continue
			append(&rows, ..colorRampEditor(ctx, s, settings.colorRamp, key, controlWidth))
			continue
		case "particleColor", "colorEnd":
			if settings.useColorRamp do continue
		}
		value, _ := e.ParticleSettings_Get(settings, field.name)
		append(&rows, inspectorRow(ctx, field.label, particleControl(ctx, s, field, index, value, key, controlWidth)))
		// The Texture shape's image, under the shape
		if field.name == "shape" && settings.shape == .Texture {
			images := make([dynamic]string, context.temp_allocator)
			append(&images, TEXTURE_NONE)
			for asset in s.project.assets do if asset.kind == .Image do append(&images, asset.path)
			append(&rows, inspectorRow(ctx, "Texture", skald.select(ctx, node.texture == "" ? TEXTURE_NONE : node.texture, images[:], NodeTextField.Texture,
				proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} },
				id = skald.hash_id(fmt.tprintf("inspector-texture-%d", key)), width = controlWidth, placeholder = "Choose an image")))
		}
	}
	return rows[:]
}

// What a setting's control sends: which setting, and what the slider needs to turn a value into text
@(private="file")
ParticlePayload :: struct {
	name: string,
	axis: int,
	integer: bool,
	step: f32,
}

// The control for one setting, by its type
@(private="file")
particleControl :: proc(ctx: ^skald.Ctx(Msg), s: ^State, field: e.ParticleFieldInfo, index: int, value: string, key: int, width: f32) -> skald.View {
	th := ctx.theme
	id :: proc(field: e.ParticleFieldInfo, key: int, part := "") -> skald.Widget_ID {
		return skald.hash_id(fmt.tprintf("inspector-particle-%s%s-%d", field.name, part, key))
	}
	payload := ParticlePayload{name = field.name, axis = -1, integer = field.type == int, step = sliderStep(field)}
	onText :: proc(p: ParticlePayload, v: string) -> Msg { return Particle_Field_Changed{p.name, v} }

	switch field.type {
	case bool:
		return skald.checkbox(ctx, value == "true", "", payload,
			proc(p: ParticlePayload, v: bool) -> Msg { return Particle_Field_Changed{p.name, v ? "true" : "false"} },
			id = id(field, key))
	case e.ParticleShape:
		names := make([]string, len(e.ParticleShape), context.temp_allocator)
		for shape in e.ParticleShape do names[shape] = fmt.tprintf("%v", shape)
		return skald.select(ctx, value, names, payload, onText, id = id(field, key), width = width)
	case int, f32:
		number, _ := strconv.parse_f32(value)
		return slider(ctx, field, payload, number, id(field, key), width)
	case [2]f32:
		axes: [2]f32
		ok: bool
		axes, ok = parsePair(value)
		if !ok do return skald.text(value, th.color.fg_muted, th.font.size_sm)
		linked := index in s.particleLinks
		button := skald.button(ctx, linked ? ICON_LINK : ICON_LINK_SLASH, Msg(Particle_Link_Toggled(index)),
			id = skald.hash_id(fmt.tprintf("inspector-particle-link-%s", field.name)),
			bg = linked ? th.color.primary : th.color.surface, fg = linked ? th.color.on_primary : th.color.fg_muted,
			width = LINK_WIDTH, padding = {0, 1}, font_size = th.font.size_xs, radius = th.radius.sm)
		tip := linked ? "Unlink: change X and Y separately" : "Link X and Y: changing one changes the other in proportion"
		sliderWidth := width - LINK_WIDTH - th.spacing.xs - 12 - th.spacing.xs
		axisRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control, after: skald.View) -> skald.View {
			th := ctx.theme
			return skald.row(skald.col(skald.text(label, th.color.fg_muted, th.font.size_xs), width = 12), control, after, spacing = th.spacing.xs, cross_align = .Center)
		}
		px, py := payload, payload
		px.axis, py.axis = 0, 1
		return skald.col(
			axisRow(ctx, "X", slider(ctx, field, px, axes.x, id(field, key, "-x"), sliderWidth),
				skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("inspector-particle-link-tip-%s", field.name)))),
			axisRow(ctx, "Y", slider(ctx, field, py, axes.y, id(field, key, "-y"), sliderWidth), skald.spacer(LINK_WIDTH)),
			spacing = 2,
		)
	case sdl.Color:
		color, _ := e.ParseColor(value)
		return colorWithAlpha(ctx, color, field.name, id(field, key), id(field, key, "-alpha"), width)
	}
	return skald.text(value, th.color.fg_muted, th.font.size_sm)
}

@(private="file")
LINK_WIDTH :: 20

// A slider over the field's range, with its value beside it
@(private="file")
slider :: proc(ctx: ^skald.Ctx(Msg), field: e.ParticleFieldInfo, payload: ParticlePayload, value: f32, id: skald.Widget_ID, width: f32) -> skald.View {
	th := ctx.theme
	onSlide :: proc(p: ParticlePayload, v: f32) -> Msg {
		v := p.step > 0 ? math.round(v / p.step) * p.step : v
		if p.axis >= 0 do return Particle_Axis_Changed{p.name, p.axis, v}
		return Particle_Field_Changed{p.name, p.integer ? fmt.tprintf("%d", int(v)) : fmt.tprintf("%v", v)}
	}
	decimals := payload.integer ? 0 : clamp(int(math.ceil(-math.log10(payload.step))), 0, 3)
	return skald.row(
		skald.slider(ctx, value, payload, onSlide, id = id, min_value = field.min, max_value = field.max,
			step = payload.integer ? 1 : 0, width = max(width - SLIDER_VALUE_WIDTH - th.spacing.xs, 40)),
		skald.col(skald.text(fmt.tprintf("%.*f", decimals, value), th.color.fg_muted, th.font.size_xs), width = SLIDER_VALUE_WIDTH),
		spacing = th.spacing.xs, cross_align = .Center,
	)
}

/*
The step a slider's values are rounded to: about a thousandth of its range, as a power of ten
(0-1: 0.001, 0-359: 0.1, 0-2000: 1), so scene files get short numbers. Whole numbers for ints.
*/
@(private="file")
sliderStep :: proc(field: e.ParticleFieldInfo) -> f32 {
	if field.type == int do return 1
	if !field.ranged || field.max <= field.min do return 0
	return math.pow(10, math.floor(math.log10((field.max - field.min) / 1000)))
}

@(private="file")
parsePair :: proc(text: string) -> ([2]f32, bool) {
	settings: e.ParticleSettings
	if !e.ParticleSettings_Set(&settings, "size", text) do return {}, false
	return settings.size, true
}

/*
A color picker (Skald's has no alpha) and an alpha slider under it, editing the setting `name`
as `#rrggbbaa` text.
*/
@(private="file")
colorWithAlpha :: proc(ctx: ^skald.Ctx(Msg), color: sdl.Color, name: string, pickerId, alphaId: skald.Widget_ID, width: f32) -> skald.View {
	th := ctx.theme
	Payload :: struct { name: string, color: sdl.Color }
	payload := Payload{name, color}
	linear := skald.rgb(u32(color.r) << 16 | u32(color.g) << 8 | u32(color.b))
	return skald.col(
		skald.color_picker(ctx, linear, payload, proc(p: Payload, c: skald.Color) -> Msg {
			picked, _ := e.ParseColor(fmt.tprintf("#%s", skald.color_to_hex(c)))
			picked.a = p.color.a
			return Particle_Field_Changed{p.name, e.FormatColor(picked, context.temp_allocator)}
		}, id = pickerId, width = width),
		skald.row(
			skald.col(skald.text("Alpha", th.color.fg_muted, th.font.size_xs), width = 34),
			skald.slider(ctx, f32(color.a), payload, proc(p: Payload, v: f32) -> Msg {
				c := p.color
				c.a = u8(math.clamp(math.round(v), 0, 255))
				return Particle_Field_Changed{p.name, e.FormatColor(c, context.temp_allocator)}
			}, id = alphaId, min_value = 0, max_value = 255, step = 1, width = max(width - 34 - SLIDER_VALUE_WIDTH - th.spacing.xs * 2, 40)),
			skald.col(skald.text(fmt.tprintf("%d", color.a), th.color.fg_muted, th.font.size_xs), width = SLIDER_VALUE_WIDTH),
			spacing = th.spacing.xs, cross_align = .Center,
		),
		spacing = 2,
	)
}

/*
The color ramp editor, like a graphics program's gradient editor: the gradient over a checkerboard
(so transparency shows), a marker under it for each stop, and the selected stop's position, color
and alpha. Click the bar to add a stop there (in the color the ramp has there), press a marker
to select it and drag to move it; Remove deletes the selected stop (a ramp keeps two).
*/
@(private="file")
colorRampEditor :: proc(ctx: ^skald.Ctx(Msg), s: ^State, ramp: e.ColorRamp, key: int, width: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	selected := clamp(s.rampStop, 0, max(ramp.count - 1, 0))
	barId := skald.hash_id(fmt.tprintf("inspector-ramp-%d", key))
	send :: proc(ctx: ^skald.Ctx(Msg), ramp: e.ColorRamp, selected: int) {
		skald.send(ctx, Msg(Ramp_Edited{FormatRampText(ramp), selected}))
	}

	// The mouse, from where the bar was last frame (before it's built, like the scene tree's)
	if state, drawn := ctx.widgets.states[barId]; drawn && state.last_rect.w > 0 {
		bar := state.last_rect
		mouse := ctx.input.mouse_pos
		area := state.clip_rect.w > 0 ? state.clip_rect : bar
		t := math.clamp((mouse.x - bar.x) / bar.w, 0, 1)
		over := pointInRect(bar, mouse) && pointInRect(area, mouse) && !skald.mouse_over_overlay(ctx) && ctx.widgets.modal_rect_prev.w == 0
		if ctx.input.mouse_pressed[.Left] && over {
			grabbed := -1
			for i in 0 ..< ramp.count {
				if abs(mouse.x - (bar.x + ramp.stops[i].position * bar.w)) <= RAMP_GRAB_DISTANCE do grabbed = i
			}
			if grabbed < 0 && mouse.y < bar.y + RAMP_BAR_HEIGHT {
				changed := ramp
				grabbed = e.ColorRamp_AddStop(&changed, t, e.ColorRamp_Evaluate(ramp, t))
				if grabbed >= 0 do send(ctx, changed, grabbed)
			}
			if grabbed >= 0 {
				skald.send(ctx, Msg(Ramp_Stop_Selected(grabbed)))
				skald.send(ctx, Msg(Ramp_Drag_Changed(true)))
			}
		} else if s.rampDragging {
			if !ctx.input.mouse_buttons[.Left] {
				skald.send(ctx, Msg(Ramp_Drag_Changed(false)))
			} else if selected < ramp.count && ramp.stops[selected].position != t {
				changed := ramp
				index := selected
				changed.stops[index].position = t
				e.ColorRamp_Sort(&changed, &index)
				send(ctx, changed, index)
			}
		}
	}

	Bar :: struct { ramp: e.ColorRamp, selected: int, highlight, border: skald.Color }
	bar := new_clone(Bar{ramp, selected, th.color.primary, th.color.border}, context.temp_allocator)
	append(&rows, inspectorRow(ctx, "Ramp", skald.canvas(ctx, bar, proc(b: ^Bar, p: skald.Canvas_Painter) {
		r, area := p.r, p.bounds
		strip := skald.Rect{area.x, area.y, area.w, RAMP_BAR_HEIGHT}
		// Checkerboard, then the gradient in 2 px slices
		CHECK :: 6
		for y := f32(0); y < strip.h; y += CHECK {
			for x := f32(0); x < strip.w; x += CHECK {
				light := (int(x / CHECK) + int(y / CHECK)) % 2 == 0
				skald.draw_rect(r, {strip.x + x, strip.y + y, min(CHECK, strip.w - x), min(CHECK, strip.h - y)}, skald.rgb(light ? 0xb4b4b4 : 0x828282))
			}
		}
		for x := f32(0); x < strip.w; x += 2 {
			skald.draw_rect(r, {strip.x + x, strip.y, min(2, strip.w - x), strip.h}, skaldColor(e.ColorRamp_Evaluate(b.ramp, (x + 1) / strip.w)))
		}
		outline(r, strip, b.border, 1)
		// A marker under the bar per stop: a tick into the bar and a swatch of its color
		for i in 0 ..< b.ramp.count {
			stop := b.ramp.stops[i]
			x := strip.x + stop.position * strip.w
			mark := i == b.selected ? b.highlight : skald.rgb(0xffffff)
			skald.draw_rect(r, {x - 1, strip.y + strip.h - 5, 2, 7}, mark)
			swatch := skald.Rect{x - 5, strip.y + strip.h + 2, 10, RAMP_MARKER_HEIGHT - 2}
			skald.draw_rect(r, swatch, skaldColor(stop.color))
			outline(r, swatch, mark, i == b.selected ? 2 : 1)
		}
	}, id = barId, width = width, height = RAMP_BAR_HEIGHT + RAMP_MARKER_HEIGHT + 2, cursor = .Pointer)))

	if ramp.count == 0 do return rows[:]
	stop := ramp.stops[selected]
	small :: proc(ctx: ^skald.Ctx(Msg), id, label, tip: string, msg: Msg, disabled := false) -> skald.View {
		th := ctx.theme
		button := skald.button(ctx, label, msg, id = skald.hash_id(id), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = disabled)
		return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("%s-tip", id)))
	}
	// Add: halfway between the selected stop and the next (or the previous, at the end)
	next := selected + 1 < ramp.count ? selected + 1 : max(selected - 1, 0)
	middle := (stop.position + ramp.stops[next].position) * 0.5
	added := ramp
	addedIndex := e.ColorRamp_AddStop(&added, middle, e.ColorRamp_Evaluate(ramp, middle))
	removed := ramp
	removedOk := e.ColorRamp_RemoveStop(&removed, selected)
	append(&rows, inspectorRow(ctx, fmt.tprintf("Stop %d / %d", selected + 1, ramp.count), skald.row(
		small(ctx, fmt.tprintf("inspector-ramp-add-%d", key), fmt.tprintf("%s  Add", ICON_PLUS), "Add a stop next to this one (or click the bar)",
			Msg(Ramp_Edited{FormatRampText(added), addedIndex}), disabled = addedIndex < 0),
		small(ctx, fmt.tprintf("inspector-ramp-remove-%d", key), fmt.tprintf("%s  Remove", ICON_TRASH), "Remove this stop (a ramp keeps two)",
			Msg(Ramp_Edited{FormatRampText(removed), min(selected, removed.count - 1)}), disabled = !removedOk),
		spacing = th.spacing.xs, cross_align = .Center,
	)))

	// The selected stop's position, color and alpha
	Stop :: struct { ramp: e.ColorRamp, index: int, step: f32 }
	stopPayload := Stop{ramp, selected, 0.001}
	append(&rows, inspectorRow(ctx, "Position", skald.row(
		skald.slider(ctx, stop.position, stopPayload, proc(p: Stop, v: f32) -> Msg {
			changed := p.ramp
			index := p.index
			changed.stops[index].position = math.round(v / p.step) * p.step
			e.ColorRamp_Sort(&changed, &index)
			return Ramp_Edited{FormatRampText(changed), index}
		}, id = skald.hash_id(fmt.tprintf("inspector-ramp-position-%d", key)), min_value = 0, max_value = 1,
			width = max(width - SLIDER_VALUE_WIDTH - th.spacing.xs, 40)),
		skald.col(skald.text(fmt.tprintf("%.0f%%", stop.position * 100), th.color.fg_muted, th.font.size_xs), width = SLIDER_VALUE_WIDTH),
		spacing = th.spacing.xs, cross_align = .Center,
	)))
	linear := skald.rgb(u32(stop.color.r) << 16 | u32(stop.color.g) << 8 | u32(stop.color.b))
	append(&rows,
		inspectorRow(ctx, "Color", skald.color_picker(ctx, linear, stopPayload, proc(p: Stop, c: skald.Color) -> Msg {
			changed := p.ramp
			picked, _ := e.ParseColor(fmt.tprintf("#%s", skald.color_to_hex(c)))
			picked.a = changed.stops[p.index].color.a
			changed.stops[p.index].color = picked
			return Ramp_Edited{FormatRampText(changed), p.index}
		}, id = skald.hash_id(fmt.tprintf("inspector-ramp-color-%d", key)), width = width)),
		inspectorRow(ctx, "Alpha", skald.row(
			skald.slider(ctx, f32(stop.color.a), stopPayload, proc(p: Stop, v: f32) -> Msg {
				changed := p.ramp
				changed.stops[p.index].color.a = u8(math.clamp(math.round(v), 0, 255))
				return Ramp_Edited{FormatRampText(changed), p.index}
			}, id = skald.hash_id(fmt.tprintf("inspector-ramp-alpha-%d", key)), min_value = 0, max_value = 255, step = 1,
				width = max(width - SLIDER_VALUE_WIDTH - th.spacing.xs, 40)),
			skald.col(skald.text(fmt.tprintf("%d", stop.color.a), th.color.fg_muted, th.font.size_xs), width = SLIDER_VALUE_WIDTH),
			spacing = th.spacing.xs, cross_align = .Center,
		)),
	)
	return rows[:]
}

// A ramp as setting text (temp allocated)
FormatRampText :: proc(ramp: e.ColorRamp) -> string {
	return e.FormatColorRamp(ramp, context.temp_allocator)
}

// sRGB bytes with alpha as a Skald (linear) color
@(private="file")
skaldColor :: proc(c: sdl.Color) -> skald.Color {
	return skald.rgba(u32(c.r) << 24 | u32(c.g) << 16 | u32(c.b) << 8 | u32(c.a))
}

@(private="file")
outline :: proc(r: ^skald.Renderer, b: skald.Rect, color: skald.Color, width: f32) {
	skald.draw_rect(r, {b.x, b.y, b.w, width}, color)
	skald.draw_rect(r, {b.x, b.y + b.h - width, b.w, width}, color)
	skald.draw_rect(r, {b.x, b.y, width, b.h}, color)
	skald.draw_rect(r, {b.x + b.w - width, b.y, width, b.h}, color)
}

@(private="file")
pointInRect :: proc(r: skald.Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}
