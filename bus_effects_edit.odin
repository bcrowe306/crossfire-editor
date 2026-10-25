package crossfire_editor

import "core:fmt"
import "core:math"
import "gui:skald"
import e "engine:."

/*
Bus effects in the editor (the engine's audio_effects.odin): each mix bus has a chain of up to
`e.AUDIO_MAX_EFFECTS` effects (low-pass, high-pass, echo, reverb), edited in the inspector when
a Mixer strip's FX button opens the bus (`State.busSelection`).

- **Data:** `BusDef.effects` / `effectCount` (a plain array: buses stay comparable and copy by
  value), from project.xml's `<effect>` children of `<bus>` and written back.
- **Edits** (`Bus_Effect_Added` / `_Removed` / `_Moved` / `_Changed`) are `.Project` undo steps,
  merged while a slider drags (History_Classify).
- **Hearing them:** the editor's previews play through the bus's effects and Master's
  (`Mixer_RoutePreview` hands them to the preview's chains), so a filter or reverb is heard
  before Play.
*/

// An effect's setting (`Bus_Effect_Changed`)
BusEffectField :: enum {
	Bypass,
	Cutoff,
	Resonance,
	Delay,
	Feedback,
	Room_Size,
	Damping,
	Mix,
}

// The inspector shows a bus's effects (its index in project.buses)
Bus_Effects_Opened :: distinct int
// An effect added to a bus, removed, moved up or down (`delta`), or changed
Bus_Effect_Added :: struct {
	bus: int,
	kind: e.AudioEffectKind,
}
Bus_Effect_Removed :: struct {
	bus, index: int,
}
Bus_Effect_Moved :: struct {
	bus, index, delta: int,
}
Bus_Effect_Changed :: struct {
	bus, index: int,
	field: BusEffectField,
	value: f32,
	flag: bool,
}

// A bus's effects as a slice of its array
BusDef_Effects :: proc(b: ^BusDef) -> []e.AudioEffect {
	return b.effects[:clamp(b.effectCount, 0, e.AUDIO_MAX_EFFECTS)]
}

// The bus effect messages; returns whether `m` was one
BusEffects_Update :: proc(s: ^State, m: Msg) -> bool {
	p := &s.project
	bus :: proc(p: ^Project, i: int) -> ^BusDef { return i >= 0 && i < len(p.buses) ? &p.buses[i] : nil }
	#partial switch v in m {
	case Bus_Effects_Opened:
		s.busSelection = int(v)
		s.selectedNode = -1
		s.themeSelection, s.materialSelection, s.dataSelection = -1, -1, -1
	case Bus_Effect_Added:
		b := bus(p, v.bus)
		if b == nil || b.effectCount >= e.AUDIO_MAX_EFFECTS do break
		b.effects[b.effectCount] = e.AudioEffect_Make(v.kind)
		b.effectCount += 1
	case Bus_Effect_Removed:
		b := bus(p, v.bus)
		if b == nil || v.index < 0 || v.index >= b.effectCount do break
		for i in v.index ..< b.effectCount - 1 do b.effects[i] = b.effects[i + 1]
		b.effectCount -= 1
		b.effects[b.effectCount] = {}
	case Bus_Effect_Moved:
		b := bus(p, v.bus)
		to := v.index + v.delta
		if b == nil || v.index < 0 || v.index >= b.effectCount || to < 0 || to >= b.effectCount do break
		b.effects[v.index], b.effects[to] = b.effects[to], b.effects[v.index]
	case Bus_Effect_Changed:
		b := bus(p, v.bus)
		if b == nil || v.index < 0 || v.index >= b.effectCount do break
		fx := &b.effects[v.index]
		// Short numbers in project.xml (a slider lands between steps)
		value := math.round(v.value * 1000) / 1000
		switch v.field {
		case .Bypass:    fx.bypass = v.flag
		case .Cutoff:    fx.cutoff = clamp(math.round(v.value), 20, 20000)
		case .Resonance: fx.resonance = clamp(value, 0.3, 10)
		case .Delay:     fx.delay = clamp(value, 0.01, e.AUDIO_MAX_ECHO)
		case .Feedback:  fx.feedback = clamp(value, 0, 0.95)
		case .Room_Size: fx.roomSize = clamp(value, 0, 1)
		case .Damping:   fx.damping = clamp(value, 0, 1)
		case .Mix:       fx.mix = clamp(value, 0, 1)
		}
	case:
		return false
	}
	// What the editor's preview plays through follows
	Mixer_RoutePreview(p, AudioPreview_Bus())
	return true
}

// A bus effect's name, as the inspector shows it
BUS_EFFECT_LABELS := [e.AudioEffectKind]string{
	.LowPass  = "Low-pass filter",
	.HighPass = "High-pass filter",
	.Echo     = "Echo",
	.Reverb   = "Reverb",
}

/*
The inspector for a bus opened from the Mixer: its effects in order, each with Bypass, its
settings, move and remove; Add Effect. Keys `bus-effect-add`, `bus-effect-<i>-<field>`,
`bus-effect-<i>-remove`, `bus-effect-<i>-up`, `bus-effect-<i>-down`.
*/
busEffectsInspector :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	index := s.busSelection
	b := &s.project.buses[index]
	_, sidebarWidth := FittedSidebarWidths(&s.layout)
	controlWidth := min(inspectorControlWidth(th, sidebarWidth), INSPECTOR_MAX_TEXT_WIDTH)
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows,
		uiText(th, .Section, fmt.tprintf("%s  %s", ICON_VOLUME, b.name)),
		uiText(th, .Muted, index == 0 ? "Master bus: its effects change everything the game plays." : "Mix bus: its effects change the sounds that play on it.", max_width = inspectorRowWidth(controlWidth)),
	)
	Payload :: struct { bus, index: int, field: BusEffectField }
	slide :: proc(p: Payload, v: f32) -> Msg { return Bus_Effect_Changed{p.bus, p.index, p.field, v, false} }
	d := e.DEFAULT_AUDIO_EFFECT
	key :: proc(i: int, field: string) -> string { return fmt.tprintf("bus-effect-%d-%s", i, field) }
	for fx, i in BusDef_Effects(b) {
		append(&rows, skald.divider(ctx))
		up := skald.button(ctx, ICON_ARROW_UP, Msg(Bus_Effect_Moved{index, i, -1}), id = skald.hash_id(key(i, "up")),
			bg = th.color.surface, fg = th.color.fg_muted, font_size = th.font.size_xs, padding = {tk.xs, tk.hair})
		down := skald.button(ctx, ICON_ARROW_DOWN, Msg(Bus_Effect_Moved{index, i, 1}), id = skald.hash_id(key(i, "down")),
			bg = th.color.surface, fg = th.color.fg_muted, font_size = th.font.size_xs, padding = {tk.xs, tk.hair})
		remove := skald.button(ctx, ICON_TRASH, Msg(Bus_Effect_Removed{index, i}), id = skald.hash_id(key(i, "remove")),
			bg = th.color.surface, fg = th.color.fg_muted, font_size = th.font.size_xs, padding = {tk.xs, tk.hair})
		append(&rows, skald.row(skald.text(fmt.tprintf("%d. %s", i + 1, BUS_EFFECT_LABELS[fx.kind]), fx.bypass ? th.color.fg_muted : th.color.fg, th.font.size_sm),
			skald.flex(1, skald.spacer(0)), up, down, remove, spacing = th.spacing.xs, cross_align = .Center, width = inspectorRowWidth(controlWidth)))
		CheckPayload :: struct { bus, index: int }
		append(&rows, inspectorRow(ctx, "Bypass", skald.checkbox(ctx, fx.bypass, "", CheckPayload{index, i},
			proc(p: CheckPayload, v: bool) -> Msg { return Bus_Effect_Changed{p.bus, p.index, .Bypass, 0, v} }, id = skald.hash_id(key(i, "Bypass")))))
		slider :: proc(ctx: ^skald.Ctx(Msg), k: string, value: f32, p: Payload, lo, hi, step: f32, decimals: int, def: f32, width: f32) -> skald.View {
			return valueSlider(ctx, k, value, p, slide, lo, hi, step = step, decimals = decimals, defaultValue = def, width = width)
		}
		switch fx.kind {
		case .LowPass, .HighPass:
			append(&rows,
				inspectorRow(ctx, "Cutoff Hz", slider(ctx, key(i, "Cutoff"), fx.cutoff, {index, i, .Cutoff}, 20, 20000, 10, 0, d.cutoff, controlWidth)),
				inspectorRow(ctx, "Resonance", slider(ctx, key(i, "Resonance"), fx.resonance, {index, i, .Resonance}, 0.3, 10, 0.01, 2, d.resonance, controlWidth)),
			)
		case .Echo:
			append(&rows,
				inspectorRow(ctx, "Delay s", slider(ctx, key(i, "Delay"), fx.delay, {index, i, .Delay}, 0.01, e.AUDIO_MAX_ECHO, 0.01, 2, d.delay, controlWidth)),
				inspectorRow(ctx, "Feedback", slider(ctx, key(i, "Feedback"), fx.feedback, {index, i, .Feedback}, 0, 0.95, 0.01, 2, d.feedback, controlWidth)),
				inspectorRow(ctx, "Wet mix", slider(ctx, key(i, "Mix"), fx.mix, {index, i, .Mix}, 0, 1, 0.01, 2, d.mix, controlWidth)),
			)
		case .Reverb:
			append(&rows,
				inspectorRow(ctx, "Room size", slider(ctx, key(i, "Room_Size"), fx.roomSize, {index, i, .Room_Size}, 0, 1, 0.01, 2, d.roomSize, controlWidth)),
				inspectorRow(ctx, "Damp highs", slider(ctx, key(i, "Damping"), fx.damping, {index, i, .Damping}, 0, 1, 0.01, 2, d.damping, controlWidth)),
				inspectorRow(ctx, "Wet mix", slider(ctx, key(i, "Mix"), fx.mix, {index, i, .Mix}, 0, 1, 0.01, 2, d.mix, controlWidth)),
			)
		}
	}
	append(&rows, skald.divider(ctx))
	if b.effectCount >= e.AUDIO_MAX_EFFECTS {
		append(&rows, uiText(th, .Muted, fmt.tprintf("A bus takes %d effects at most.", e.AUDIO_MAX_EFFECTS)))
	} else {
		choices := make([dynamic]string, context.temp_allocator)
		for label in BUS_EFFECT_LABELS do append(&choices, label)
		AddPayload :: struct { bus: int }
		append(&rows, inspectorRow(ctx, "Add effect", skald.select(ctx, "", choices[:], AddPayload{index},
			proc(p: AddPayload, v: string) -> Msg {
				for label, kind in BUS_EFFECT_LABELS do if label == v do return Bus_Effect_Added{p.bus, kind}
				return Bus_Effect_Added{p.bus, .LowPass}
			}, id = skald.hash_id("bus-effect-add"), width = controlWidth, placeholder = "Choose an effect")))
	}
	append(&rows, uiText(th, .Muted, "Effects run in order on everything mixed on the bus. Preview a sound on it (its inspector's Preview) to hear them; Bypass compares with and without.", max_width = inspectorRowWidth(controlWidth)))
	manual := skald.button(ctx, fmt.tprintf("%s  Manual", ICON_CIRCLE_INFO), Msg(Manual_Opened("audio_effects_and_music")), id = skald.hash_id("bus-effect-manual"),
		bg = th.color.surface, fg = th.color.fg, padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm)
	append(&rows, manual)
	return skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.md)
}
