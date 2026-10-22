package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"

/*
The Live tab (the bottom panel's): the game running from Play, as it plays (live_edit.odin).

	+--------------------------------------------------------------------------------------+
	| [Pause] [Step]  Playing MenuScene        60 fps  frame 16.6 ms  update 0.4  physics 0.1 |
	| ▁▂▁▁▃▁▁▂▁▁▁ (frame times: the line is 16.7 ms, 60 fps)  draw 1.2 ms  42 nodes, 30 drawn  |
	+------------------------------+-------------------------------------------------------+
	| World                        | Hero (CharacterMover)                                 |
	|   Hero                       | position   [120, 340]                                 |
	|   Enemies                    | rotation   [0]                                        |
	|     Bee                      | speed (script) [250]                                  |
	+------------------------------+-------------------------------------------------------+

Widget keys: `live-pause` (Pause / Resume), `live-step`, `live-node-<i>` (the nodes' rows),
`live-prop-<name>` (the properties' fields), `live-graph`.
*/

LivePanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	live := &s.live
	running := s.playState != .Stopped && s.play.stage == .Running
	if !running || !live.connected {
		text := running ? "Waiting for the game..." : "Press Play (F5): the running game shows here. Pause it, step it a frame at a time, see how long its frames take, look at its nodes and change their values while it plays."
		return skald.col(skald.text(text, th.color.fg_muted, th.font.size_sm, max_width = 560), padding = th.spacing.md)
	}
	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.sm * 2
	small :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View { return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs) }
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg, on := false) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = on ? th.color.primary : th.color.bg, fg = on ? th.color.on_primary : th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	st := live.stats
	bar := make([dynamic]skald.View, context.temp_allocator)
	append(&bar, button(ctx, "live-pause", live.paused ? fmt.tprintf("%s  Resume", ICON_PLAY) : fmt.tprintf("%s  Pause", ICON_PAUSE), Msg(Live_Command(live.paused ? "resume" : "pause")), live.paused))
	if live.paused do append(&bar, button(ctx, "live-step", "Step a Frame", Msg(Live_Command("step"))))
	append(&bar, skald.text(fmt.tprintf("%s %s", live.paused ? "Paused in" : "Playing", live.scene), th.color.fg, th.font.size_sm))
	append(&bar, small(ctx, fmt.tprintf("%.0f fps   frame %.1f ms   update %.2f   physics %.2f   draw %.2f ms   %d nodes, %d drawn", st.fps, st.frame, st.update, st.physics, st.draw, st.nodes, st.drawn)))
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.wrap_row(..bar[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width, bg = th.color.surface))
	append(&rows, frameGraph(ctx, live, max(width - th.spacing.sm * 2, 100)))

	// The nodes, and the chosen one's properties: side by side, or one under the other in a
	// narrow panel (a tiled window's is about 200 px)
	narrow := width < 560
	treeWidth := narrow ? width - th.spacing.sm * 2 : clamp(width * 0.4, 140, 320)
	nodes := make([dynamic]skald.View, context.temp_allocator)
	for n, i in live.nodes {
		label := fmt.tprintf("%s%s", strings.repeat("   ", n.depth, context.temp_allocator), n.name)
		on := n.id == live.selected
		append(&nodes, skald.button(ctx, label, Msg(Live_Selected(n.id)), id = skald.hash_id(fmt.tprintf("live-node-%d", i)),
			bg = on ? th.color.primary : th.color.bg, fg = on ? th.color.on_primary : (n.visible ? th.color.fg : th.color.fg_muted),
			padding = {th.spacing.sm, 1}, font_size = th.font.size_xs, radius = th.radius.sm, width = treeWidth - th.spacing.md))
	}
	if len(nodes) == 0 do append(&nodes, small(ctx, "No nodes."))
	props := make([dynamic]skald.View, context.temp_allocator)
	propWidth := narrow ? width - th.spacing.sm * 2 : max(width - treeWidth - th.spacing.lg * 2, 160)
	labelWidth := min(f32(130), propWidth * 0.4)
	if live.selected == "" {
		append(&props, small(ctx, "Choose a node to see its values. Typing a value changes it in the game at once (the project isn't changed)."))
	} else {
		name := ""
		for n in live.nodes do if n.id == live.selected do name = fmt.tprintf("%s (%s)", n.name, n.type)
		append(&props, skald.text(name == "" ? "(gone from the scene)" : name, th.color.fg, th.font.size_sm))
		for p in live.properties {
			value := p.value
			if typed, found := live.edits[p.name]; found do value = typed
			Payload :: struct { name: string }
			append(&props, skald.row(
				skald.col(skald.text(Timeline_PropertyLabel(p.name), th.color.fg_muted, th.font.size_xs), width = labelWidth),
				skald.text_input(ctx, strings.clone(value, context.temp_allocator), Payload{strings.clone(p.name, context.temp_allocator)}, proc(pl: Payload, v: string) -> Msg {
					return Live_Property_Edited{pl.name, v}
				}, id = skald.hash_id(fmt.tprintf("live-prop-%s", p.name)), width = max(min(propWidth - labelWidth - th.spacing.xs, 260), 60)),
				spacing = th.spacing.xs, cross_align = .Center,
			))
		}
	}
	if narrow {
		append(&rows, skald.col(..nodes[:], spacing = 1, width = treeWidth))
		append(&rows, skald.divider(ctx))
		append(&rows, skald.col(..props[:], spacing = th.spacing.xs, width = propWidth))
	} else {
		append(&rows, skald.row(
			skald.col(..nodes[:], spacing = 1, width = treeWidth),
			skald.col(..props[:], spacing = th.spacing.xs, width = propWidth),
			spacing = th.spacing.lg,
		))
	}
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, width = width, padding = th.spacing.sm), id = skald.hash_id("live-scroll"))
}

// The frame times: a bar per stats report, a line at 16.7 ms (60 fps)
@(private="file")
frameGraph :: proc(ctx: ^skald.Ctx(Msg), live: ^LiveView, width: f32) -> skald.View {
	th := ctx.theme
	Data :: struct { times: []f32, bar, line, bg: skald.Color }
	times := make([]f32, len(live.history), context.temp_allocator)
	copy(times, live.history[:])
	data := new_clone(Data{times, th.color.primary, th.color.warning, th.color.surface}, context.temp_allocator)
	return skald.canvas(ctx, data, proc(d: ^Data, p: skald.Canvas_Painter) {
		b := p.bounds
		skald.draw_rect(p.r, b, d.bg)
		top: f32 = 33.4
		for t in d.times do top = max(top, t)
		step := b.w / f32(LIVE_HISTORY)
		for t, i in d.times {
			h := min(t / top, 1) * b.h
			skald.draw_rect(p.r, {b.x + f32(i) * step, b.y + b.h - h, max(step - 1, 1), h}, d.bar)
		}
		y := b.y + b.h - (16.7 / top) * b.h
		skald.draw_rect(p.r, {b.x, y, b.w, 1}, d.line)
	}, id = skald.hash_id("live-graph"), width = width, height = 40)
}
