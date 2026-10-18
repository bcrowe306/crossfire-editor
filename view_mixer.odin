package editor

import "core:fmt"
import "gui:skald"
import e "engine:."

/*
The bottom panel's Mixer tab: a strip per bus (mixer.odin), Master first. Each strip has its
name (Master's is fixed), volume and pan sliders, mute, remove, and how many sound nodes use it;
Add Bus makes another. Every edit is a `.Project` undo step.

Widget keys: `mixer-add`, and per bus index `mixer-name-<i>`, `mixer-volume-<i>`,
`mixer-pan-<i>`, `mixer-mute-<i>`, `mixer-remove-<i>`.
*/

@(private="file")
STRIP_WIDTH :: 180

MixerPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	buses := s.project.buses[:]
	if len(buses) == 0 {
		context.allocator = context.temp_allocator
		buses = Buses_FromData(nil)[:]
	}

	small :: proc(ctx: ^skald.Ctx(Msg), label: string, msg: Msg, key: string, active := false, disabled := false) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), disabled = disabled,
			bg = active ? th.color.danger : th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	onVolume :: proc(i: int, v: f32) -> Msg { return Bus_Volume_Changed{i, v} }
	onPan :: proc(i: int, v: f32) -> Msg { return Bus_Pan_Changed{i, v} }
	onName :: proc(i: int, name: string) -> Msg { return Bus_Renamed{i, name} }
	sliderWidth: f32 = STRIP_WIDTH - th.spacing.sm * 2

	strips := make([dynamic]skald.View, context.temp_allocator)
	for b, i in buses {
		rows := make([dynamic]skald.View, context.temp_allocator)
		if i == 0 {
			append(&rows, skald.text(fmt.tprintf("%s  %s", ICON_SLIDERS, e.MASTER_BUS), th.color.fg, th.font.size_sm))
		} else {
			// A typed name is kept until it's a valid one, with why it isn't
			text := b.name
			if s.busEdit.index == i && s.busEdit.text != b.name do text = s.busEdit.text
			append(&rows, skald.text_input(ctx, text, i, onName, id = skald.hash_id(fmt.tprintf("mixer-name-%d", i)),
				width = sliderWidth, padding = InspectorFieldPadding(ctx)))
			if problem := BusNameProblem(&s.project, i, text); problem != "" && text != b.name {
				append(&rows, skald.text(problem, th.color.danger, th.font.size_xs))
			}
		}
		append(&rows,
			skald.text("Volume", th.color.fg_muted, th.font.size_xs),
			valueSlider(ctx, fmt.tprintf("mixer-volume-%d", i), b.volume, i, onVolume, 0, 2, step = 0.01, decimals = 2, defaultValue = 1, width = sliderWidth),
			skald.text("Pan", th.color.fg_muted, th.font.size_xs),
			valueSlider(ctx, fmt.tprintf("mixer-pan-%d", i), b.pan, i, onPan, -1, 1, step = 0.01, decimals = 2, defaultValue = 0, width = sliderWidth),
		)
		buttons := make([dynamic]skald.View, context.temp_allocator)
		append(&buttons, small(ctx, fmt.tprintf("%s  %s", b.mute ? ICON_VOLUME_MUTE : ICON_VOLUME, b.mute ? "Muted" : "Mute"),
			Msg(Bus_Mute_Toggled(i)), fmt.tprintf("mixer-mute-%d", i), active = b.mute))
		if i > 0 do append(&buttons, small(ctx, ICON_TRASH, Msg(Bus_Removed(i)), fmt.tprintf("mixer-remove-%d", i)))
		append(&rows, skald.row(..buttons[:], spacing = th.spacing.xs, cross_align = .Center))
		count := Bus_NodeCount(&s.project, i == 0 ? "" : b.name)
		append(&rows, skald.text(fmt.tprintf("%d sound node%s", count, count == 1 ? "" : "s"), th.color.fg_muted, th.font.size_xs))
		append(&strips, skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.sm, width = STRIP_WIDTH,
			bg = th.color.surface, radius = th.radius.sm))
	}
	append(&strips, small(ctx, fmt.tprintf("%s  Add Bus", ICON_PLUS), Msg(Bus_Added{}), "mixer-add"))

	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.sm * 2 - INSPECTOR_SCROLLBAR_WIDTH
	return skald.scroll(ctx, {0, 0}, skald.col(
		skald.text("Every sound goes to its bus (Master unless chosen in its inspector), every bus to Master.", th.color.fg_muted, th.font.size_xs),
		skald.wrap_row(..strips[:], spacing = th.spacing.sm, line_spacing = th.spacing.sm, width = width),
		spacing = th.spacing.sm,
		padding = th.spacing.sm,
		width = width,
	), id = skald.hash_id("mixer-scroll"))
}
