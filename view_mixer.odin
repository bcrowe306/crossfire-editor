package editor

import "core:fmt"
import "gui:skald"
import e "engine:."

/*
The bottom panel's Mixer tab, laid out like a DAW's mixer: a channel strip per bus (mixer.odin),
Master always on the far right, the other buses scrolling sideways when they don't fit. A strip,
top to bottom: remove (not Master), pan, the volume fader beside its level meter, the level in
dB, mute, and the bus's name (Master's is fixed). The + beside Master adds a bus (scrolled into
view). Every edit is a `.Project` undo step.

The meters show what the editor plays (a sound node's Preview, through its bus; the browser's
previews through Master), measured after each fader (audio_preview.odin). A game started with
Play runs in its own process: its levels aren't shown.

Widget keys, per bus index (Master is 0): `mixer-fader-<i>`, `mixer-pan-<i>`, `mixer-meter-<i>`,
`mixer-mute-<i>`, `mixer-remove-<i>`, `mixer-name-<i>`; `mixer-add`, `mixer-buses` (the
scrolling strips) and its bar `mixer-buses-bar`.
*/
MixerPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	return skald.sized(ctx, s, mixerBody)
}

@(private="file")
STRIP_WIDTH :: f32(72)
// The shortest a fader gets; the strips are as tall as the panel, the fader takes what's left
@(private="file")
FADER_MIN_HEIGHT :: f32(60)

@(private="file")
mixerBody :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	th := ctx.theme
	gap := th.spacing.sm
	buses := s.project.buses[:]
	if len(buses) == 0 {
		context.allocator = context.temp_allocator
		buses = Buses_FromData(nil)[:]
	}

	// This frame's levels: the bus the preview plays on, and the final mix
	busLevel, masterLevel := AudioPreview_Levels()
	previewBus := AudioPreview_Bus()
	moving := AudioPreview_IsPlaying()

	height := max(size.y - gap * 2, 0)
	stripsWidth := f32(len(buses) - 1) * (STRIP_WIDTH + gap) - gap
	areaWidth := max(size.x - STRIP_WIDTH - ADD_WIDTH - gap * 5 - 1, STRIP_WIDTH)
	// The strips fill the height the scroll bar (when there is one) leaves
	bar: f32 = stripsWidth > areaWidth ? H_SCROLL_BAR + 2 : 0
	stripHeight := max(height - bar, 0)

	strips := make([dynamic]skald.View, context.temp_allocator)
	for b, i in buses {
		if i == 0 do continue
		level := b.name == previewBus ? busLevel : [2]f32{}
		append(&strips, channelStrip(ctx, s, b, i, level, stripHeight))
	}
	add := skald.tooltip(ctx, skald.button(ctx, ICON_PLUS, Msg(Bus_Added{}), id = skald.hash_id("mixer-add"),
		bg = th.color.surface, fg = th.color.fg, width = ADD_WIDTH, padding = {0, th.spacing.md}, radius = th.radius.sm),
		"Add a bus", id = skald.hash_id("mixer-add-tip"))
	if len(strips) == 0 do append(&strips, skald.text("No buses yet: + adds one", th.color.fg_muted, th.font.size_xs))
	master := channelStrip(ctx, s, buses[0], 0, masterLevel, stripHeight)
	// Keep frames coming while the preview plays (meters that are still falling ask too)
	if moving do skald.send(ctx, Msg(Preview_Tick{}))

	return skald.row(
		hScroll(ctx, "mixer-buses", skald.row(..strips[:], spacing = gap), areaWidth, height),
		skald.flex(1, skald.spacer(0)),
		add,
		skald.rect({1, height}, th.color.border),
		master,
		spacing = gap,
		padding = gap,
	)
}

@(private="file")
ADD_WIDTH :: f32(32)

// One bus's strip, `height` tall: the fader and meter take what the rest leaves
@(private="file")
channelStrip :: proc(ctx: ^skald.Ctx(Msg), s: ^State, b: BusDef, i: int, level: [2]f32, height: f32) -> skald.View {
	th := ctx.theme
	inner := STRIP_WIDTH - th.spacing.xs * 2
	tiny :: proc(ctx: ^skald.Ctx(Msg), text: string, color: skald.Color) -> skald.View {
		return skald.text(text, color, ctx.theme.font.size_xs)
	}
	onPan :: proc(i: int, v: f32) -> Msg { return Bus_Pan_Changed{i, v} }
	onName :: proc(i: int, name: string) -> Msg { return Bus_Renamed{i, name} }

	rows := make([dynamic]skald.View, context.temp_allocator)
	// Top: how many sound nodes use it, and remove (Master has none)
	count := Bus_NodeCount(&s.project, i == 0 ? "" : b.name)
	used := skald.tooltip(ctx, tiny(ctx, fmt.tprintf("%s %d", ICON_VOLUME, count), th.color.fg_muted),
		fmt.tprintf("%d sound node%s on %s", count, count == 1 ? "" : "s", i == 0 ? e.MASTER_BUS : b.name),
		id = skald.hash_id(fmt.tprintf("mixer-count-tip-%d", i)))
	if i > 0 {
		remove := skald.button(ctx, ICON_TRASH, Msg(Bus_Removed(i)), id = skald.hash_id(fmt.tprintf("mixer-remove-%d", i)),
			bg = th.color.surface, fg = th.color.fg_muted, padding = {th.spacing.xs, 1}, font_size = th.font.size_xs, radius = th.radius.sm)
		append(&rows, skald.row(used, skald.flex(1, skald.spacer(0)),
			skald.tooltip(ctx, remove, "Remove the bus (its sounds go to Master)", id = skald.hash_id(fmt.tprintf("mixer-remove-tip-%d", i))),
			width = inner, cross_align = .Center))
	} else {
		append(&rows, skald.row(used, width = inner, cross_align = .Center))
	}

	// Pan
	append(&rows,
		skald.row(tiny(ctx, Pan_Text(b.pan), th.color.fg_muted), main_align = .Center, width = inner),
		panControl(ctx, fmt.tprintf("mixer-pan-%d", i), b.pan, i, onPan, inner),
	)

	// Fader and meter, centered, as tall as the strip has room for (known at layout: `sized`)
	slot := FaderSlot{i, b.volume, level}
	append(&rows,
		skald.flex(1, skald.sized(ctx, &slot, faderAndMeter, min_w = inner, min_h = FADER_MIN_HEIGHT)),
		skald.row(tiny(ctx, Fader_Text(b.volume), th.color.fg), main_align = .Center, width = inner),
	)

	// Mute
	mute := skald.button(ctx, "M", Msg(Bus_Mute_Toggled(i)), id = skald.hash_id(fmt.tprintf("mixer-mute-%d", i)),
		bg = b.mute ? skald.rgb(0xe0a030) : th.color.bg, fg = b.mute ? skald.rgb(0x1a1a1a) : th.color.fg,
		width = inner, padding = {0, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	append(&rows, skald.tooltip(ctx, mute, b.mute ? "Muted: click to hear it" : "Mute", id = skald.hash_id(fmt.tprintf("mixer-mute-tip-%d", i))))

	// The name, at the bottom
	if i == 0 {
		append(&rows, skald.row(skald.text(e.MASTER_BUS, th.color.fg, th.font.size_sm), main_align = .Center, width = inner))
	} else {
		// A typed name is kept until it's a valid one, with why it isn't
		text := b.name
		if s.busEdit.index == i && s.busEdit.text != b.name do text = s.busEdit.text
		name := skald.text_input(ctx, text, i, onName, id = skald.hash_id(fmt.tprintf("mixer-name-%d", i)),
			width = inner, padding = {th.spacing.xs, 1}, font_size = th.font.size_xs)
		if problem := BusNameProblem(&s.project, i, text); problem != "" && text != b.name {
			name = skald.tooltip(ctx, name, problem, id = skald.hash_id(fmt.tprintf("mixer-name-tip-%d", i)))
			append(&rows, name, tiny(ctx, "Can't use it", th.color.danger))
		} else {
			append(&rows, name)
		}
	}

	return skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.xs, width = STRIP_WIDTH, height = height,
		bg = th.color.surface, radius = th.radius.sm)
}

@(private="file")
FaderSlot :: struct {
	index: int,
	volume: f32,
	level: [2]f32,
}

@(private="file")
faderAndMeter :: proc(ctx: ^skald.Ctx(Msg), slot: ^FaderSlot, size: [2]f32) -> skald.View {
	onVolume :: proc(i: int, v: f32) -> Msg { return Bus_Volume_Changed{i, v} }
	h := max(size.y, FADER_MIN_HEIGHT)
	meter, moving := levelMeter(ctx, fmt.tprintf("mixer-meter-%d", slot.index), slot.level, h)
	// A meter still falling keeps frames coming
	if moving do skald.send(ctx, Msg(Preview_Tick{}))
	return skald.row(fader(ctx, fmt.tprintf("mixer-fader-%d", slot.index), slot.volume, slot.index, onVolume, h), meter,
		spacing = ctx.theme.spacing.xs, main_align = .Center, width = size.x)
}
