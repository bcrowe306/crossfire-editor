package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"

/*
The Particles tab (the bottom panel's): the shown ParticleEmitter's settings, one category at a
time (particles_edit.odin has the model).

	+--------------------------------------------------------------------------------------+
	| Sparks  42 alive   [Restart] [Emitting] [One-shot] [Preset v] [Reset]       [Manual]  |
	| [Emission ]  | Emitting    [x]                                                        |
	| [GPU      ]  | Continuous  [ ]                                                        |
	| [Shape    ]  | Amount      [====o--------------] 40                                   |
	| [Rotation ]  | Lifetime    [=o-----------------] 0.7                                  |
	| [Color    ]  | ...                                                                    |
	+--------------------------------------------------------------------------------------+

The left column has a tab per category (the engine's settings groups, then All); from
`PARTICLES_TAB_NAMES_WIDTH` of panel with their names, from `PARTICLES_TAB_ICONS_WIDTH` icons
only (the name in a tooltip), and narrower (a tiled window's panel is about 200 px) a choice
(`particles-tab-select`) over the settings, all in one scroll with the header. The settings are
the inspector's own rows (`particleSettingRows`), wider: rows stack their labels when the column
is narrow (`inspectorStacked`).

The header: Restart (the viewport's emitter starts again, its particles cleared), Emitting and
One-shot (`emitting`, `continuous`), a preset (`PARTICLE_PRESETS`), Reset and the live count
from the viewport.

Widget keys: `particles-tab-cat-<Category>`, `particles-tab-select`, `particles-tab-scroll`,
`particles-tab-restart`, `particles-tab-emitting`, `particles-tab-one-shot`,
`particles-tab-preset`, `particles-tab-reset`, `particles-tab-manual`, `particles-tab-add`
(without an emitter), and the settings' `particles-tab-particle-<field>-<node>`,
`particles-tab-ramp-<node>`... (view_inspector_particles.odin's doc block).
*/

// From this panel width the categories show their names
PARTICLES_TAB_NAMES_WIDTH :: 560
// From this panel width they're icons; narrower, a choice over the settings
PARTICLES_TAB_ICONS_WIDTH :: 340

// Room the categories' column keeps for its scrollbar (a short panel scrolls it)
@(private="file")
SIDEBAR_SCROLLBAR :: 10
@(private="file")
SIDEBAR_NAMES :: 124
@(private="file")
SIDEBAR_ICONS :: 52
// Rows stack their labels under this content width
@(private="file")
STACK_WIDTH :: INSPECTOR_LABEL_WIDTH + 170

// Each category's icon (the engine's groups; another group gets ICON_SLIDERS)
@(private="file")
categoryIcon :: proc(name: string) -> string {
	switch name {
	case "Emission":  return ICON_FIRE
	case "GPU":       return ICON_CUBES
	case "Shape":     return ICON_SQUARE
	case "Rotation":  return ICON_ROTATE
	case "Color":     return ICON_PALETTE
	case "Motion":    return ICON_ARROW_RIGHT
	case "Forces":    return ICON_WIND
	case "Collision": return ICON_BULLSEYE
	case PARTICLES_ALL: return ICON_LIST
	}
	return ICON_SLIDERS
}

// What each category is for (its tab's tooltip, and the inspector's link to it)
Particles_CategoryAbout :: proc(name: string) -> string {
	switch name {
	case "Emission":  return "Emission: how many particles a cycle, how long they live, where they start"
	case "GPU":       return "GPU: run the particles on the graphics card, tens of thousands at once"
	case "Shape":     return "Shape: what a particle is drawn as, its size and scale over its life"
	case "Rotation":  return "Rotation: each particle's starting angle and spin"
	case "Color":     return "Color: the color ramp, or start and end colors"
	case "Motion":    return "Motion: the direction and speed particles are emitted with"
	case "Forces":    return "Forces: gravity and wind"
	case "Collision": return "Collision: particles bouncing off each other and the view's edges"
	case PARTICLES_ALL: return "All: every setting, in their groups"
	}
	return name
}

// How the Particles tab lays out at a panel width (`Particles_TabLayout`)
ParticlesTabLayout :: struct {
	// The categories with their names, or (not `names`) icons; `compact`: a choice instead
	names, compact: bool,
	// The categories' column, and the settings' (inside its padding and scrollbar)
	sidebar, content: f32,
	// Rows put their labels over their controls
	stacked: bool,
	// A control's width, the ramp bar's
	controlWidth, rampWidth: f32,
}

/*
How the Particles tab lays out at a panel width: the categories' column (names, icons, or a choice
over the settings when narrow) and the settings' widths, so every row fits the column: beside its
label, a control is at most what the column leaves after the label; stacked, the column's width.

Inputs:
- th: The theme (its spacing)
- panel: The bottom panel's width

Returns:
- The layout
*/
Particles_TabLayout :: proc(th: ^skald.Theme, panel: f32) -> ParticlesTabLayout {
	l: ParticlesTabLayout
	l.names = panel >= PARTICLES_TAB_NAMES_WIDTH
	l.compact = panel < PARTICLES_TAB_ICONS_WIDTH
	l.sidebar = l.compact ? 0 : l.names ? SIDEBAR_NAMES : SIDEBAR_ICONS
	l.content = max(panel - l.sidebar - th.spacing.sm * 2 - INSPECTOR_SCROLLBAR_WIDTH, 120)
	l.stacked = l.content < STACK_WIDTH
	beside := l.content - INSPECTOR_LABEL_WIDTH - th.spacing.sm
	l.controlWidth = l.stacked ? min(l.content, 360) : min(beside, 360)
	l.rampWidth = l.stacked ? l.controlWidth : min(beside, 560)
	return l
}

ParticlesPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	node, index := Particles_Emitter(s)
	if node == nil {
		text := "Select a ParticleEmitter node to edit its settings here, a category at a time, with presets (fire, smoke, sparks, dust, rain). Sparks, smoke, rain, explosions: an emitter sends out small dots, shapes or pictures that move and fade."
		add := skald.button(ctx, fmt.tprintf("%s  Add ParticleEmitter", ICON_PLUS), Msg(Add_Node_Kind_Chosen(NodeKind.ParticleEmitter)),
			id = skald.hash_id("particles-tab-add"), padding = tk.fieldPadding, font_size = th.font.size_sm)
		return skald.col(
			uiText(th, .Label, text, max_width = tk.textWide),
			skald.tooltip(ctx, add, "A new ParticleEmitter in the open scene, inside the selected node", id = skald.hash_id("particles-tab-add-tip")),
			spacing = th.spacing.sm, padding = th.spacing.md,
		)
	}

	// The panel's width: the Scene mode's center column
	left, right := FittedSidebarWidths(&s.layout)
	panel := max(s.layout.workspace.x - left - right - DIVIDER * 2, 160)
	l := Particles_TabLayout(th, panel)
	names, compact, sidebar, content, stacked := l.names, l.compact, l.sidebar, l.content, l.stacked
	controlWidth, rampWidth := l.controlWidth, l.rampWidth

	categories := Particles_Categories()
	category := Particles_CategoryName(s)
	header := particlesHeader(ctx, s, node, index, compact ? content : panel - th.spacing.sm * 2)

	rows := make([dynamic]skald.View, context.temp_allocator)
	if compact {
		append(&rows, header)
		append(&rows, skald.select(ctx, category, categories, proc(name: string) -> Msg {
			for c, i in Particles_Categories() do if c == name do return Particles_Category_Picked(i)
			return Particles_Category_Picked(0)
		}, id = skald.hash_id("particles-tab-select"), width = min(content, tk.fieldL)))
	}
	saved := inspectorStacked
	inspectorStacked = stacked
	group := category == PARTICLES_ALL ? "" : category
	settings := particleSettingRows(ctx, s, node, index, {group = group, controlWidth = controlWidth, rampWidth = rampWidth})
	inspectorStacked = saved
	if len(settings) == 0 do append(&rows, uiText(th, .Label, "Nothing in this category."))
	append(&rows, ..settings)
	body := skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.sm, padding = th.spacing.sm), id = skald.hash_id("particles-tab-scroll"))
	if compact do return body

	tabs := make([dynamic]skald.View, context.temp_allocator)
	for name, i in categories {
		active := name == category
		label := names ? fmt.tprintf("%s  %s", categoryIcon(name), name) : categoryIcon(name)
		key := fmt.tprintf("particles-tab-cat-%s", name)
		button := skald.button(ctx, label, Msg(Particles_Category_Picked(i)), id = skald.hash_id(key),
			bg = active ? th.color.primary : th.color.surface, fg = active ? th.color.on_primary : th.color.fg,
			padding = {tk.s, tk.xs}, font_size = th.font.size_xs, radius = th.radius.sm, width = sidebar - th.spacing.xs * 2 - SIDEBAR_SCROLLBAR)
		append(&tabs, skald.tooltip(ctx, button, Particles_CategoryAbout(name), id = skald.hash_id(fmt.tprintf("%s-tip", key))))
	}
	side := skald.scroll(ctx, {0, 0}, skald.col(..tabs[:], spacing = tk.xxs, padding = th.spacing.xs), id = skald.hash_id("particles-tab-sidebar"))
	return skald.col(
		skald.row(header, padding = th.spacing.xs, bg = th.color.surface),
		skald.flex(1, skald.row(
			skald.col(skald.flex(1, side), width = sidebar, cross_align = .Stretch),
			skald.flex(1, body),
			spacing = 0, cross_align = .Stretch,
		)),
		cross_align = .Stretch,
	)
}

/*
The tab's header: the emitter's name and live particles, Restart, Emitting, One-shot, a preset,
Reset and the manual. A `wrap_row` of `width`, so it wraps in a narrow panel.
*/
@(private="file")
particlesHeader :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, index: int, width: f32) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	p := node.particles
	items := make([dynamic]skald.View, context.temp_allocator)
	append(&items, uiText(th, .Value, strings.clone(node.name, context.temp_allocator)))
	if count, onGPU, ok := Preview_EmitterAlive(s, index); ok {
		live := onGPU ? fmt.tprintf("on the GPU, %d a cycle", p.gpuAmount) : fmt.tprintf("%d alive", count)
		append(&items, uiText(th, .Muted, live))
	}
	button :: proc(ctx: ^skald.Ctx(Msg), key, label, tip: string, msg: Msg, on := false) -> skald.View {
		tk := uiTokens(ctx)
		th := ctx.theme
		b := skald.button(ctx, label, msg, id = skald.hash_id(key),
			bg = on ? th.color.primary : th.color.bg, fg = on ? th.color.on_primary : th.color.fg,
			padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm)
		return skald.tooltip(ctx, b, tip, id = skald.hash_id(fmt.tprintf("%s-tip", key)))
	}
	append(&items,
		button(ctx, "particles-tab-restart", fmt.tprintf("%s  Restart", ICON_RESTART),
			"Start the emitter again in the viewport, its particles cleared (a one-shot plays again). Needs Emitting on and the viewport's animations playing (P)",
			Msg(Particles_Restart{})),
		button(ctx, "particles-tab-emitting", fmt.tprintf("%s  Emitting", p.emitting ? ICON_PLAY : ICON_PAUSE),
			p.emitting ? "Emits from the start: click to start it stopped (a script starts it)" : "Starts stopped: click to emit from the start",
			Msg(Particle_Field_Changed{"emitting", p.emitting ? "false" : "true"}), on = p.emitting),
		button(ctx, "particles-tab-one-shot", fmt.tprintf("%s  One-shot", ICON_STAR),
			p.continuous ? "Continuous: a new cycle starts when one ends. Click to emit one cycle and stop (an explosion)" : "One-shot: one cycle, then it stops. Click to make it continuous",
			Msg(Particle_Field_Changed{"continuous", p.continuous ? "false" : "true"}), on = !p.continuous),
	)
	presets := make([dynamic]string, context.temp_allocator)
	for preset in PARTICLE_PRESETS do append(&presets, preset.name)
	choice := skald.select(ctx, "", presets[:], proc(name: string) -> Msg { return Particles_Preset_Applied(name) },
		id = skald.hash_id("particles-tab-preset"), width = tk.fieldS, placeholder = fmt.tprintf("%s Preset", ICON_WAND))
	tip := strings.builder_make(context.temp_allocator)
	strings.write_string(&tip, "A starting point to tune (every setting but the GPU's; undoable):")
	for preset in PARTICLE_PRESETS do fmt.sbprintf(&tip, " %s: %s.", preset.name, preset.about)
	append(&items, skald.tooltip(ctx, choice, strings.to_string(tip), id = skald.hash_id("particles-tab-preset-tip")))
	append(&items,
		button(ctx, "particles-tab-reset", fmt.tprintf("%s  Reset", ICON_UNDO), "Put every particle setting back to its default (undoable)", Msg(Particles_Reset{})),
		button(ctx, "particles-tab-manual", fmt.tprintf("%s  Manual", ICON_CIRCLE_INFO), "The Particles page of the manual", Msg(Manual_Opened("particles#the-particles-tab"))),
	)
	return skald.wrap_row(..items[:], spacing = th.spacing.sm, line_spacing = th.spacing.xs, width = width)
}
