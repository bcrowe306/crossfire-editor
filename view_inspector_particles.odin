package crossfire_editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strconv"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
A ParticleEmitter in the inspector, and its settings as the Particles tab's rows.

**The inspector** (`particleInspectorRows`) shows a summary (`Particles_Facts`: emitting, one-shot
or continuous, the amount and rate, the lifetime, the shape, CPU or GPU, the viewport's live
count), Emitting and a preset inline, **Edit in the Particles tab** and a link per category (the
tab opened there: `Particles_Tab_Opened`). The settings themselves are edited in the tab.

**The settings' rows** (`particleSettingRows`, the Particles tab's: view_particles.odin): every
field of the engine's `e.ParticleSettings`, by its type and tags (`e.ParticleSettings_Fields`),
so a field added there shows up with no editor change:
- numbers with a `min` / `max` range: `valueSlider`s (type a value, Shift for fine steps, reset
  to the default)
- `[2]f32`: a slider per axis, with a link toggle (linked, one axis drags the other in proportion)
- `bool`: checkboxes; enums: dropdowns
- colors: a color picker and an alpha slider
- the color ramp: a gradient bar with a marker per stop (`colorRampEditor`)
The Texture shape adds the node's texture. `ParticleRows` says which group and the widths.

Edits are `Particle_Field_Changed` (a setting as text), `Particle_Axis_Changed`, `Ramp_Edited` and
`Particles_Reset`, to `Particles_Target` (particles_edit.odin); all undoable, merged per field.
Widget keys (`PARTICLE_KEYS`, the tab's `particles-tab`): `particles-tab-particle-<field>-<node>`
(`-x` / `-y`, `-alpha`), `particles-tab-particle-link-<field>`, `particles-tab-texture-<node>`,
`particles-tab-ramp-<node>` (the bar), `particles-tab-ramp-add-<node>`,
`particles-tab-ramp-remove-<node>`, `particles-tab-ramp-position-<node>`,
`particles-tab-ramp-color-<node>`, `particles-tab-ramp-alpha-<node>`. The inspector's:
`inspector-particles-emitting-<node>`, `inspector-particles-preset-<node>`,
`inspector-particles-edit-<node>` (Edit in the Particles tab) and
`inspector-particles-cat-<Category>-<node>` (a category's link).
*/

@(private="file")
RAMP_BAR_HEIGHT :: 22
@(private="file")
RAMP_MARKER_HEIGHT :: 14
// How close (px) a press must be to a stop's marker to grab it
@(private="file")
RAMP_GRAB_DISTANCE :: 6
// The settings' widget keys start with it (the Particles tab's)
@(private="file")
PARTICLE_KEYS :: "particles-tab"

// How `particleSettingRows` builds its rows
ParticleRows :: struct {
	// Only the settings of this group (`Particles_FieldGroups`); "": every setting, under their
	// groups' headings
	group: string,
	// A control's width, and the ramp bar's (0: the control's)
	controlWidth, rampWidth: f32,
}

// One fact of an emitter's summary in the inspector: a row's label (its tooltip is `fieldTip`'s)
// and its value
ParticleFact :: struct {
	label, value: string,
}

/*
What an emitter does, as the inspector's summary rows: one-shot or continuous, how many particles
(and how many a second when continuous), how long they live, what they're drawn as, CPU or GPU,
and how many are alive in the viewport when it's drawn there.

Inputs:
- s: The editor (the viewport's live count)
- node: The emitter
- index: Its index in the open scene (-1: no live count)

Returns:
- The facts, in order (temp allocated)
*/
Particles_Facts :: proc(s: ^State, node: ^NodeDef, index: int) -> []ParticleFact {
	p := node.particles
	facts := make([dynamic]ParticleFact, context.temp_allocator)
	append(&facts, ParticleFact{"Cycle", p.continuous ? "Continuous" : "One-shot"})
	amount := p.gpu ? p.gpuAmount : p.amount
	value := fmt.tprintf("%d a cycle", amount)
	if p.continuous && p.lifetime > 0 do value = fmt.tprintf("%d a cycle, %s a second", amount, formatSliderValue(f32(amount) / p.lifetime, 1))
	append(&facts, ParticleFact{"Particles", value})
	append(&facts, ParticleFact{"Lives", fmt.tprintf("%s s", formatSliderValue(p.lifetime, 2))})
	shape := fmt.tprintf("%v", p.shape)
	if p.shape == .Texture do shape = node.texture == "" ? "Texture (none chosen)" : fmt.tprintf("Texture %s", filepath.base(node.texture))
	if p.useColorRamp do shape = fmt.tprintf("%s, color ramp", shape)
	append(&facts, ParticleFact{"Drawn as", shape})
	append(&facts, ParticleFact{"Runs on", p.gpu ? "GPU" : "CPU"})
	if index >= 0 {
		if count, onGPU, ok := Preview_EmitterAlive(s, index); ok {
			live := onGPU ? fmt.tprintf("on the GPU, %d a cycle", p.gpuAmount) : fmt.tprintf("%d in the viewport", count)
			append(&facts, ParticleFact{"Alive", live})
		}
	}
	return facts[:]
}

/*
The inspector's ParticleEmitter rows: the summary (`Particles_Facts`), Emitting and a preset, then
Edit in the Particles tab and a link per category. The settings are edited in the tab.
*/
@(private="package")
particleInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth: f32) -> []skald.View {
	th := ctx.theme
	p := node.particles
	rows := make([dynamic]skald.View, context.temp_allocator)
	rowWidth := inspectorRowWidth(controlWidth)

	// Inline: Emitting, and a preset (a select whose value stays "")
	emitting := skald.checkbox(ctx, p.emitting, "", p.emitting, proc(was: bool, v: bool) -> Msg {
		return Particle_Field_Changed{"emitting", v ? "true" : "false"}
	}, id = skald.hash_id(fmt.tprintf("inspector-particles-emitting-%d", key)))
	append(&rows, inspectorRow(ctx, "Emits", emitting))
	presets := make([dynamic]string, context.temp_allocator)
	for preset in PARTICLE_PRESETS do append(&presets, preset.name)
	choice := skald.select(ctx, "", presets[:], proc(name: string) -> Msg { return Particles_Preset_Applied(name) },
		id = skald.hash_id(fmt.tprintf("inspector-particles-preset-%d", key)), width = controlWidth, placeholder = fmt.tprintf("%s Preset", ICON_WAND))
	append(&rows, inspectorRow(ctx, "Look", choice))

	// The summary: compact rows of text
	for fact in Particles_Facts(s, node, key) {
		append(&rows, inspectorRow(ctx, fact.label, skald.text(fact.value, th.color.fg, th.font.size_xs, max_width = controlWidth)))
	}

	// The tab: the button (on its own row, the row's width), then a link per category
	edit := skald.button(ctx, fmt.tprintf("%s  Edit in the Particles tab", ICON_FIRE), Msg(Particles_Tab_Opened(-1)),
		id = skald.hash_id(fmt.tprintf("inspector-particles-edit-%d", key)), padding = {th.spacing.sm, 4},
		font_size = th.font.size_sm, width = rowWidth)
	append(&rows, skald.tooltip(ctx, edit, "Every setting, by category, in the bottom panel: sliders, the color ramp, presets, Restart and Reset",
		id = skald.hash_id(fmt.tprintf("inspector-particles-edit-tip-%d", key))))
	links := make([dynamic]skald.View, context.temp_allocator)
	for name, i in Particles_Categories() {
		if name == PARTICLES_ALL do continue
		k := fmt.tprintf("inspector-particles-cat-%s-%d", name, key)
		link := skald.button(ctx, name, Msg(Particles_Tab_Opened(i)), id = skald.hash_id(k),
			bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.xs, 1}, font_size = th.font.size_xs, radius = th.radius.sm)
		append(&links, skald.tooltip(ctx, link, fmt.tprintf("The Particles tab at %s", Particles_CategoryAbout(name)), id = skald.hash_id(fmt.tprintf("%s-tip", k))))
	}
	append(&rows, skald.wrap_row(..links[:], spacing = th.spacing.xs, line_spacing = th.spacing.xs, width = rowWidth))
	return rows[:]
}

/*
A ParticleEmitter's settings as rows (the Particles tab's): one group's or all of them
(`ParticleRows`), each by its type (`particleControl`); the color ramp replaces the start and end
colors when it's on, and the Texture shape adds the node's picture under the shape.
*/
@(private="package")
particleSettingRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, r: ParticleRows) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	settings := node.particles
	groups := Particles_FieldGroups()
	controlWidth := r.controlWidth
	for field, index in e.ParticleSettings_Fields() {
		if r.group != "" && groups[index] != r.group do continue
		if r.group == "" && field.group != "" {
			append(&rows, skald.spacer(th.spacing.xs), skald.text(field.group, th.color.fg, th.font.size_xs))
		}
		// The ramp replaces the start and end colors when it's on
		switch field.name {
		case "colorRamp":
			if !settings.useColorRamp do continue
			append(&rows, ..colorRampEditor(ctx, s, settings.colorRamp, key, r))
			continue
		case "particleColor", "colorEnd":
			if settings.useColorRamp do continue
		}
		value, _ := e.ParticleSettings_Get(settings, field.name)
		control := particleControl(ctx, s, field, index, value, key, controlWidth)
		// Its range and default, after any general explanation (tooltips.odin)
		defaultText, _ := e.ParticleSettings_Get(e.DEFAULT_PARTICLE_SETTINGS, field.name)
		tip := field.ranged ? fmt.tprintf("From %v to %v; default %s.", field.min, field.max, defaultText) : fmt.tprintf("Default %s.", defaultText)
		if field.type == [2]f32 {
			// The link button goes with the label: beside the sliders it ran into the scrollbar
			// strip in a narrow inspector (a click there paged the inspector instead)
			label := tipLabel(ctx, field.label, skald.text(field.label, th.color.fg_muted, th.font.size_sm), tip)
			// Stacked, the button goes beside the label
			labelled: skald.View
			if inspectorStacked {
				labelled = skald.row(label, linkButton(ctx, s, field, index), spacing = th.spacing.sm, cross_align = .Center)
			} else {
				labelled = skald.col(label, linkButton(ctx, s, field, index), spacing = 2)
			}
			append(&rows, inspectorLabelled(ctx, labelled, control))
		} else {
			append(&rows, particleRow(ctx, field.label, control, tip))
		}
		// The Texture shape's image, under the shape
		if field.name == "shape" && settings.shape == .Texture {
			images := make([dynamic]string, context.temp_allocator)
			append(&images, TEXTURE_NONE)
			for asset in s.project.assets do if asset.kind == .Image do append(&images, asset.path)
			append(&rows, particleRow(ctx, "Texture", skald.select(ctx, node.texture == "" ? TEXTURE_NONE : node.texture, images[:], NodeTextField.Texture,
				proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} },
				id = skald.hash_id(fmt.tprintf("%s-texture-%d", PARTICLE_KEYS, key)), width = controlWidth, placeholder = "Choose an image")))
		}
	}
	return rows[:]
}

// A row: a label with its tooltip beside or over the control (`inspectorLabelled`)
@(private="file")
particleRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View, tip := "") -> skald.View {
	th := ctx.theme
	return inspectorLabelled(ctx, tipLabel(ctx, label, skald.text(label, th.color.fg_muted, th.font.size_sm), tip), control)
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
particleControl :: proc(ctx: ^skald.Ctx(Msg), s: ^State, field: e.ParticleFieldInfo, index: int, value: string, node: int, width: f32) -> skald.View {
	th := ctx.theme
	Key :: struct { prefix: string, node: int }
	k := Key{PARTICLE_KEYS, node}
	key :: proc(field: e.ParticleFieldInfo, k: Key, part := "") -> string {
		return fmt.tprintf("%s-particle-%s%s-%d", k.prefix, field.name, part, k.node)
	}
	id :: proc(field: e.ParticleFieldInfo, k: Key, part := "") -> skald.Widget_ID {
		return skald.hash_id(key(field, k, part))
	}
	payload := ParticlePayload{name = field.name, axis = -1, integer = field.type == int, step = sliderStep(field)}
	// The default, to reset to
	defaultText, _ := e.ParticleSettings_Get(e.DEFAULT_PARTICLE_SETTINGS, field.name)
	onText :: proc(p: ParticlePayload, v: string) -> Msg { return Particle_Field_Changed{p.name, v} }

	switch field.type {
	case bool:
		return skald.checkbox(ctx, value == "true", "", payload,
			proc(p: ParticlePayload, v: bool) -> Msg { return Particle_Field_Changed{p.name, v ? "true" : "false"} },
			id = id(field, k))
	case e.ParticleShape:
		names := make([]string, len(e.ParticleShape), context.temp_allocator)
		for shape in e.ParticleShape do names[shape] = fmt.tprintf("%v", shape)
		return skald.select(ctx, value, names, payload, onText, id = id(field, k), width = width)
	case int, f32:
		number, _ := strconv.parse_f32(value)
		defaultNumber, _ := strconv.parse_f32(defaultText)
		return slider(ctx, field, payload, number, defaultNumber, key(field, k), width)
	case [2]f32:
		axes: [2]f32
		ok: bool
		axes, ok = parsePair(value)
		if !ok do return skald.text(value, th.color.fg_muted, th.font.size_sm)
		defaults, _ := parsePair(defaultText)
		sliderWidth := width - AXIS_LABEL_WIDTH - th.spacing.xs
		axisRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
			th := ctx.theme
			return skald.row(skald.col(skald.text(label, th.color.fg_muted, th.font.size_xs), width = AXIS_LABEL_WIDTH), control, spacing = th.spacing.xs, cross_align = .Center)
		}
		px, py := payload, payload
		px.axis, py.axis = 0, 1
		return skald.col(
			axisRow(ctx, "X", slider(ctx, field, px, axes.x, defaults.x, key(field, k, "-x"), sliderWidth)),
			axisRow(ctx, "Y", slider(ctx, field, py, axes.y, defaults.y, key(field, k, "-y"), sliderWidth)),
			spacing = 2,
		)
	case sdl.Color:
		color, _ := e.ParseColor(value)
		defaultColor, _ := e.ParseColor(defaultText)
		return colorWithAlpha(ctx, color, defaultColor.a, field.name, id(field, k), key(field, k, "-alpha"), width)
	}
	return skald.text(value, th.color.fg_muted, th.font.size_sm)
}

@(private="file")
LINK_WIDTH :: 20
@(private="file")
AXIS_LABEL_WIDTH :: 10

// An [2]f32 setting's link toggle (linked, one axis drags the other in proportion)
@(private="file")
linkButton :: proc(ctx: ^skald.Ctx(Msg), s: ^State, field: e.ParticleFieldInfo, index: int) -> skald.View {
	prefix :: PARTICLE_KEYS
	th := ctx.theme
	linked := index in s.particleLinks
	button := skald.button(ctx, linked ? ICON_LINK : ICON_LINK_SLASH, Msg(Particle_Link_Toggled(index)),
		id = skald.hash_id(fmt.tprintf("%s-particle-link-%s", prefix, field.name)),
		bg = linked ? th.color.primary : th.color.surface, fg = linked ? th.color.on_primary : th.color.fg_muted,
		width = LINK_WIDTH, padding = {0, 1}, font_size = th.font.size_xs, radius = th.radius.sm)
	tip := linked ? "Unlink: change X and Y separately" : "Link X and Y: changing one changes the other in proportion"
	return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("%s-particle-link-tip-%s", prefix, field.name)))
}

// A slider over the field's range (valueSlider: type a value, Shift for fine steps, reset)
@(private="file")
slider :: proc(ctx: ^skald.Ctx(Msg), field: e.ParticleFieldInfo, payload: ParticlePayload, value, defaultValue: f32, key: string, width: f32) -> skald.View {
	onSlide :: proc(p: ParticlePayload, v: f32) -> Msg {
		if p.axis >= 0 do return Particle_Axis_Changed{p.name, p.axis, v}
		return Particle_Field_Changed{p.name, p.integer ? fmt.tprintf("%d", int(math.round(v))) : formatSliderValue(v, stepDecimals(p.step) + 1)}
	}
	return valueSlider(ctx, key, value, payload, onSlide, field.min, field.max, step = payload.step,
		decimals = payload.integer ? 0 : stepDecimals(payload.step), defaultValue = defaultValue, width = width)
}

// Decimals that show a step (0.001: 3); the fine mode's tenth of a step gets one more where it's stored
@(private="file")
stepDecimals :: proc(step: f32) -> int {
	return step > 0 ? clamp(int(math.ceil(-math.log10(step) - 0.0001)), 0, 4) : 2
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
colorWithAlpha :: proc(ctx: ^skald.Ctx(Msg), color: sdl.Color, defaultAlpha: u8, name: string, pickerId: skald.Widget_ID, alphaKey: string, width: f32) -> skald.View {
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
			valueSlider(ctx, alphaKey, f32(color.a), payload, proc(p: Payload, v: f32) -> Msg {
				c := p.color
				c.a = u8(math.clamp(math.round(v), 0, 255))
				return Particle_Field_Changed{p.name, e.FormatColor(c, context.temp_allocator)}
			}, 0, 255, step = 1, decimals = 0, defaultValue = f32(defaultAlpha), width = width - 34 - th.spacing.xs),
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
colorRampEditor :: proc(ctx: ^skald.Ctx(Msg), s: ^State, ramp: e.ColorRamp, key: int, r: ParticleRows) -> []skald.View {
	th := ctx.theme
	// The bar takes the ramp's width (wider than a control), the stop's controls a control's
	width := r.controlWidth
	barWidth := r.rampWidth > 0 ? r.rampWidth : width
	prefix :: PARTICLE_KEYS
	rows := make([dynamic]skald.View, context.temp_allocator)
	selected := clamp(s.rampStop, 0, max(ramp.count - 1, 0))
	barId := skald.hash_id(fmt.tprintf("%s-ramp-%d", prefix, key))
	send :: proc(ctx: ^skald.Ctx(Msg), ramp: e.ColorRamp, selected: int) {
		skald.send(ctx, Msg(Ramp_Edited{FormatRampText(ramp), selected}))
	}

	// The mouse, from where the bar was last frame (before it's built, like the scene tree's)
	if state, drawn := ctx.widgets.states[barId]; drawn && state.last_rect.w > 0 {
		bar := state.last_rect
		mouse := ctx.input.mouse_pos
		area := state.clip_rect.w > 0 ? state.clip_rect : bar
		t := math.clamp((mouse.x - bar.x) / bar.w, 0, 1)
		over := pointInRect(bar, mouse) && pointInRect(area, mouse) && len(ctx.widgets.overlay_rects_prev) == 0 && ctx.widgets.modal_rect_prev.w == 0
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
				skald.send(ctx, Msg(Ramp_Drag_Changed(barId)))
			}
		} else if s.rampDrag == barId {
			if !ctx.input.mouse_buttons[.Left] {
				skald.send(ctx, Msg(Ramp_Drag_Changed(0)))
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
	append(&rows, particleRow(ctx, "Ramp", skald.canvas(ctx, bar, proc(b: ^Bar, p: skald.Canvas_Painter) {
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
	}, id = barId, width = barWidth, height = RAMP_BAR_HEIGHT + RAMP_MARKER_HEIGHT + 2, cursor = .Pointer)))

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
	append(&rows, particleRow(ctx, fmt.tprintf("Stop %d / %d", selected + 1, ramp.count), skald.row(
		small(ctx, fmt.tprintf("%s-ramp-add-%d", prefix, key), fmt.tprintf("%s  Add", ICON_PLUS), "Add a stop next to this one (or click the bar)",
			Msg(Ramp_Edited{FormatRampText(added), addedIndex}), disabled = addedIndex < 0),
		small(ctx, fmt.tprintf("%s-ramp-remove-%d", prefix, key), fmt.tprintf("%s  Remove", ICON_TRASH), "Remove this stop (a ramp keeps two)",
			Msg(Ramp_Edited{FormatRampText(removed), min(selected, removed.count - 1)}), disabled = !removedOk),
		spacing = th.spacing.xs, cross_align = .Center,
	)))

	// The selected stop's position, color and alpha
	Stop :: struct { ramp: e.ColorRamp, index: int }
	stopPayload := Stop{ramp, selected}
	append(&rows, particleRow(ctx, "Position", valueSlider(ctx, fmt.tprintf("%s-ramp-position-%d", prefix, key), stop.position, stopPayload, proc(p: Stop, v: f32) -> Msg {
		changed := p.ramp
		index := p.index
		changed.stops[index].position = v
		e.ColorRamp_Sort(&changed, &index)
		return Ramp_Edited{FormatRampText(changed), index}
	}, 0, 1, step = 0.001, decimals = 3, width = width)))
	linear := skald.rgb(u32(stop.color.r) << 16 | u32(stop.color.g) << 8 | u32(stop.color.b))
	append(&rows,
		particleRow(ctx, "Color", skald.color_picker(ctx, linear, stopPayload, proc(p: Stop, c: skald.Color) -> Msg {
			changed := p.ramp
			picked, _ := e.ParseColor(fmt.tprintf("#%s", skald.color_to_hex(c)))
			picked.a = changed.stops[p.index].color.a
			changed.stops[p.index].color = picked
			return Ramp_Edited{FormatRampText(changed), p.index}
		}, id = skald.hash_id(fmt.tprintf("%s-ramp-color-%d", prefix, key)), width = width)),
		particleRow(ctx, "Alpha", valueSlider(ctx, fmt.tprintf("%s-ramp-alpha-%d", prefix, key), f32(stop.color.a), stopPayload, proc(p: Stop, v: f32) -> Msg {
			changed := p.ramp
			changed.stops[p.index].color.a = u8(math.clamp(math.round(v), 0, 255))
			return Ramp_Edited{FormatRampText(changed), p.index}
		}, 0, 255, step = 1, decimals = 0, width = width)),
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
