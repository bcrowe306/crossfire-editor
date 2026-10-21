package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The Timeline panel (the bottom panel's Timeline tab): an Animator's clips (timeline_edit.odin).

	+-------------------------------------------------------------------------------------+
	| Clip [intro v] + Clip  Name [intro]  Length [2]  Loop  Starts with this  Remove Clip |
	| > Play  |< Start  0.50 s   Track: [Hero v] [position v] + Track  + Event Track  Manual |
	+-------------------------------------------------------------------------------------+
	|               0s        0.5s        1s        1.5s        2s    (the ruler: scrub)    |
	| Hero position |  <>          <>                    <>          (keys: drag to move)  |
	| Events        |          <>                                                         |
	+-------------------------------------------------------------------------------------+
	| Track: Hero position  Key  Key All  Steps  Remove Track                                |
	| Key: Time [0.5]  Value [10, 0]  Curve [InOutQuad v]  Remove Key                        |
	+-------------------------------------------------------------------------------------+

In the tracks: a click on the ruler (or an empty spot) moves the playhead, a click on a key
selects it and dragging moves it (snapped to 0.05 s; Shift: freely), a double-click on a track
adds a key there from its node's value now.

Widget keys: `timeline-clip`, `timeline-add-clip`, `timeline-clip-name`, `timeline-length`,
`timeline-loop`, `timeline-autoplay`, `timeline-remove-clip`, `timeline-play`, `timeline-rewind`,
`timeline-track-node`, `timeline-track-property`, `timeline-add-track`, `timeline-add-event-track`,
`timeline-canvas`, `timeline-key`, `timeline-key-all`, `timeline-track-step`,
`timeline-remove-track`, `timeline-key-time`, `timeline-key-value`, `timeline-key-ease`,
`timeline-remove-key`, `timeline-manual`.
*/

// The canvas's measures: the track names' column (at most), the ruler, a track's row
TIMELINE_NAME_WIDTH :: 170
TIMELINE_RULER_HEIGHT :: 20
TIMELINE_ROW_HEIGHT :: 22
// Margin right of the last second, so the end's keys can be grabbed
@(private="file")
TIMELINE_END_MARGIN :: 10

TimelinePanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	node, index := Timeline_Animator(s)
	if node == nil {
		text := "Select an Animator node to edit its clips: keyframes that move, turn, scale, color, show and hide other nodes, or change their script's fields, over time. Add Node > Animator makes one."
		return skald.col(skald.text(text, th.color.fg_muted, th.font.size_sm, max_width = 560), padding = th.spacing.md)
	}
	t := &s.timeline
	scene := &s.project.scenes[s.currentScene]
	small :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View { return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs) }
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg, on := false) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = on ? th.color.primary : th.color.bg, fg = on ? th.color.on_primary : th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	labeled :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
		return skald.row(skald.text(label, ctx.theme.color.fg_muted, ctx.theme.font.size_xs), control, spacing = ctx.theme.spacing.xs, cross_align = .Center)
	}
	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.sm * 2 - INSPECTOR_SCROLLBAR_WIDTH

	// The clip: choice, add, name, length, loop, autoplay, remove
	toolbar := make([dynamic]skald.View, context.temp_allocator)
	clip := Timeline_Clip(s)
	if clip != nil {
		names := make([]string, len(node.animator.clips), context.temp_allocator)
		for c, i in node.animator.clips do names[i] = c.name == node.animator.autoplay ? fmt.tprintf("%s ★", c.name) : c.name
		Choices :: struct { names: []string }
		append(&toolbar, labeled(ctx, "Clip", skald.select(ctx, names[t.clip], names, Choices{names}, proc(c: Choices, v: string) -> Msg {
			for n, i in c.names do if n == v do return Timeline_View{op = .Clip_Chosen, index = i}
			return {}
		}, id = skald.hash_id("timeline-clip"), width = 130)))
	}
	append(&toolbar, button(ctx, "timeline-add-clip", fmt.tprintf("%s  Clip", ICON_PLUS), Msg(Timeline_Changed{op = .Clip_Added})))
	if clip != nil {
		name := t.nameEdit != "" ? t.nameEdit : clip.name
		nameRow := labeled(ctx, "Name", skald.text_input(ctx, strings.clone(name, context.temp_allocator), proc(v: string) -> Msg { return Timeline_View{op = .Name_Typed, text = v} },
			id = skald.hash_id("timeline-clip-name"), width = 110))
		if t.nameEdit != "" {
			nameRow = skald.row(nameRow, skald.text(Timeline_ClipNameProblem(node, t.clip, t.nameEdit), th.color.warning, th.font.size_xs), spacing = th.spacing.xs, cross_align = .Center)
		}
		append(&toolbar, nameRow)
		append(&toolbar, labeled(ctx, "Length", numberField(ctx, s, "timeline-length", TimelineNumber.Length, f64(clip.length), 0.1, 2, 110, 0.01, 3600)))
		append(&toolbar, skald.checkbox(ctx, clip.loop, "Loop", proc(v: bool) -> Msg { return Timeline_Changed{op = .Clip_Loop, flag = v} }, id = skald.hash_id("timeline-loop")))
		autoplay := node.animator.autoplay == clip.name
		append(&toolbar, button(ctx, "timeline-autoplay", "Starts with this", Msg(Timeline_Changed{op = .Clip_Autoplay, flag = !autoplay}), autoplay))
		append(&toolbar, button(ctx, "timeline-remove-clip", fmt.tprintf("%s  Remove Clip", ICON_TRASH), Msg(Timeline_Changed{op = .Clip_Removed})))
	}
	append(&toolbar, button(ctx, "timeline-manual", fmt.tprintf("%s  Manual", ICON_CIRCLE_INFO), Msg(Manual_Opened("animation"))))

	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.wrap_row(..toolbar[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width, bg = th.color.surface))
	if clip == nil {
		append(&rows, small(ctx, "This Animator has no clips yet: + Clip makes one. A clip is a length of time with tracks; each track moves one property of one node through its keys."))
		return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, width = width, padding = th.spacing.sm), id = skald.hash_id("timeline-scroll"))
	}

	// Playing, and the new track's node and property
	transport := make([dynamic]skald.View, context.temp_allocator)
	append(&transport, button(ctx, "timeline-play", t.playing ? fmt.tprintf("%s  Pause", ICON_PAUSE) : fmt.tprintf("%s  Play", ICON_PLAY), Msg(Timeline_View{op = .Play_Toggled}), t.playing))
	append(&transport, button(ctx, "timeline-rewind", "To the Start", Msg(Timeline_View{op = .Rewound})))
	append(&transport, small(ctx, fmt.tprintf("%.2f s of %.2f", t.playhead, clip.length)))
	if t.playing && !t.tickPending && EditorFocused() do skald.send(ctx, Msg(Timeline_Tick_Requested{}))
	// Nodes a track can animate: the Animator's parent and what's under it, else the scene's
	nodePaths := make([dynamic]string, context.temp_allocator)
	for _, i in scene.nodes do if i != index do append(&nodePaths, Timeline_PathTo(scene, index, i, context.temp_allocator))
	newNode := t.newNode
	if Timeline_ResolvePath(scene, index, newNode) < 0 {
		// The selected node, else the Animator's parent, else the first
		newNode = ""
		if s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) && s.selectedNode != index do newNode = Timeline_PathTo(scene, index, s.selectedNode, context.temp_allocator)
		else if scene.nodes[index].parent >= 0 do newNode = "."
		else if len(nodePaths) > 0 do newNode = nodePaths[0]
	}
	if len(nodePaths) > 0 {
		append(&transport, labeled(ctx, "Track", skald.select(ctx, newNode, nodePaths[:], proc(v: string) -> Msg { return Timeline_View{op = .New_Node_Chosen, text = v} },
			id = skald.hash_id("timeline-track-node"), width = 130)))
		if target := Timeline_ResolvePath(scene, index, newNode); target >= 0 {
			properties := Timeline_Properties(s, &scene.nodes[target], context.temp_allocator)
			property := t.newProperty
			known := false
			for p in properties do if p == property do known = true
			if !known && len(properties) > 0 do property = properties[0]
			labels := make([]string, len(properties), context.temp_allocator)
			for p, i in properties do labels[i] = Timeline_PropertyLabel(p)
			Props :: struct { names, labels: []string }
			shown := property
			for p, i in properties do if p == property do shown = labels[i]
			append(&transport, skald.select(ctx, shown, labels, Props{properties, labels}, proc(c: Props, v: string) -> Msg {
				for l, i in c.labels do if l == v do return Timeline_View{op = .New_Property_Chosen, text = c.names[i]}
				return {}
			}, id = skald.hash_id("timeline-track-property"), width = 130))
			// Adding takes what's shown
			if len(properties) > 0 {
				append(&transport, button(ctx, "timeline-add-track", fmt.tprintf("%s  Track", ICON_PLUS),
					Msg(Timeline_Changed{op = .Track_Added, path = strings.clone(newNode, context.temp_allocator), text = strings.clone(property, context.temp_allocator)})))
			}
		}
	}
	append(&transport, button(ctx, "timeline-add-event-track", fmt.tprintf("%s  Event Track", ICON_PLUS), Msg(Timeline_Changed{op = .Track_Added, text = e.ANIMATOR_EVENT_PROPERTY})))
	append(&rows, skald.wrap_row(..transport[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width))
	append(&rows, skald.divider(ctx))
	append(&rows, tracksCanvas(ctx, s, node, index, clip, max(width - th.spacing.sm * 2, 160)))

	// The selected track and key
	if t.track >= 0 && t.track < len(clip.tracks) {
		track := &clip.tracks[t.track]
		edit := make([dynamic]skald.View, context.temp_allocator)
		append(&edit, small(ctx, fmt.tprintf("Track: %s", trackName(track))))
		if track.property != e.ANIMATOR_EVENT_PROPERTY {
			append(&edit, button(ctx, "timeline-key", fmt.tprintf("%s  Key", ICON_PLUS), Msg(Timeline_Changed{op = .Key_Added})))
			kind, _ := e.Animator_PropertyKind(track.property)
			if kind != .Bool && kind != .Text {
				append(&edit, skald.checkbox(ctx, track.step, "Steps", proc(v: bool) -> Msg { return Timeline_Changed{op = .Track_Step, flag = v} }, id = skald.hash_id("timeline-track-step")))
			}
			if Timeline_ResolvePath(scene, index, track.node) < 0 do append(&edit, skald.text(fmt.tprintf("No node at %q", track.node), th.color.warning, th.font.size_xs))
		} else {
			append(&edit, button(ctx, "timeline-key", fmt.tprintf("%s  Event", ICON_PLUS), Msg(Timeline_Changed{op = .Key_Added})))
		}
		append(&edit, button(ctx, "timeline-key-all", "Key All Tracks", Msg(Timeline_Changed{op = .Keys_Recorded})))
		append(&edit, button(ctx, "timeline-remove-track", fmt.tprintf("%s  Remove Track", ICON_TRASH), Msg(Timeline_Changed{op = .Track_Removed})))
		append(&rows, skald.wrap_row(..edit[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width))
		if t.key >= 0 && t.key < len(track.keys) {
			key := track.keys[t.key]
			keyRow := make([dynamic]skald.View, context.temp_allocator)
			append(&keyRow, labeled(ctx, "Key at", numberField(ctx, s, "timeline-key-time", TimelineNumber.Key_Time, f64(key.time), 0.05, 2, 110, 0, f64(clip.length))))
			valueLabel := track.property == e.ANIMATOR_EVENT_PROPERTY ? "Event" : "Value"
			append(&keyRow, labeled(ctx, valueLabel, skald.text_input(ctx, strings.clone(key.value, context.temp_allocator), proc(v: string) -> Msg { return Timeline_Changed{op = .Key_Value, text = v} },
				id = skald.hash_id("timeline-key-value"), width = 120)))
			if track.property != e.ANIMATOR_EVENT_PROPERTY && !track.step {
				eases := make([]string, len(e.EaseType), context.temp_allocator)
				for ease in e.EaseType do eases[ease] = fmt.tprint(ease)
				append(&keyRow, labeled(ctx, "Curve to the next", skald.select(ctx, fmt.tprint(key.ease), eases, proc(v: string) -> Msg { return Timeline_Changed{op = .Key_Ease, text = v} },
					id = skald.hash_id("timeline-key-ease"), width = 110)))
			}
			append(&keyRow, button(ctx, "timeline-remove-key", fmt.tprintf("%s  Remove Key", ICON_TRASH), Msg(Timeline_Changed{op = .Key_Removed})))
			append(&rows, skald.wrap_row(..keyRow[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width))
		}
	}
	append(&rows, small(ctx, "Move the playhead on the ruler. Key records the track's node as it is now: move or change the node, then Key. Double-click a track to key it there; drag keys to move them (Shift: without snapping). Event keys fire the Animator's onEvent: listen to it in the inspector's Events."))
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, width = width, padding = th.spacing.sm), id = skald.hash_id("timeline-scroll"))
}

// "Hero position", "Events"
@(private="file")
trackName :: proc(track: ^e.AnimatorTrackData) -> string {
	if track.property == e.ANIMATOR_EVENT_PROPERTY do return "Events"
	node := track.node == "" || track.node == "." ? "(parent)" : track.node
	return fmt.tprintf("%s %s", node, Timeline_PropertyLabel(track.property))
}

/*
The x of a time in the tracks canvas, from its left edge.

Inputs:
- width: The canvas's width
- length: The clip's length
- time: Seconds
*/
Timeline_TimeX :: proc(width, length, time: f32) -> f32 {
	names := Timeline_NameWidth(width)
	area := max(width - names - TIMELINE_END_MARGIN * 2, 1)
	return names + TIMELINE_END_MARGIN + (length > 0 ? time / length : 0) * area
}

/*
The track names' column in a canvas this wide: a third of it, up to `TIMELINE_NAME_WIDTH` (a
narrow panel keeps room for the keys).
*/
Timeline_NameWidth :: proc(width: f32) -> f32 {
	return clamp(width * 0.35, 60, TIMELINE_NAME_WIDTH)
}

/*
The time at an x of the tracks canvas (the inverse of `Timeline_TimeX`), clamped to the clip.
*/
Timeline_XTime :: proc(width, length, x: f32) -> f32 {
	names := Timeline_NameWidth(width)
	area := max(width - names - TIMELINE_END_MARGIN * 2, 1)
	return clamp((x - names - TIMELINE_END_MARGIN) / area * length, 0, length)
}

// The last tracks canvas's width (UI tests aim at keys and times through it)
timelineCanvasWidth: f32 = 400

// The tracks: names on the left, the ruler and keys on the right
@(private="file")
tracksCanvas :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, index: int, clip: ^e.AnimatorClipData, width: f32) -> skald.View {
	th := ctx.theme
	t := &s.timeline
	id := skald.hash_id("timeline-canvas")
	timelineCanvasWidth = width
	rowCount := max(len(clip.tracks), 1)
	height := f32(TIMELINE_RULER_HEIGHT + TIMELINE_ROW_HEIGHT * rowCount)
	// The mouse, from last frame's rect (like the Tiles palette)
	if state, drawn := ctx.widgets.states[id]; drawn && state.last_rect.w > 0 && len(ctx.widgets.overlay_rects_prev) == 0 {
		rect := state.last_rect
		visible := state.clip_rect.w > 0 ? state.clip_rect : rect
		m := ctx.input.mouse_pos
		inside :: proc(r: skald.Rect, p: [2]f32) -> bool { return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h }
		local := m - {rect.x, rect.y}
		at := Timeline_XTime(width, clip.length, local.x)
		if ctx.input.mouse_pressed[.Left] && inside(rect, m) && inside(visible, m) {
			row := int((local.y - TIMELINE_RULER_HEIGHT) / TIMELINE_ROW_HEIGHT)
			onTrack := local.y >= TIMELINE_RULER_HEIGHT && row < len(clip.tracks)
			hit := -1
			names := Timeline_NameWidth(width)
			if onTrack && local.x >= names {
				for key, k in clip.tracks[row].keys do if abs(Timeline_TimeX(width, clip.length, key.time) - local.x) <= 6 do hit = k
			}
			switch {
			case onTrack && local.x < names:
				skald.send(ctx, Msg(Timeline_View{op = .Track_Selected, index = row}))
			case hit >= 0:
				skald.send(ctx, Msg(Timeline_View{op = .Key_Selected, index = row, other = hit}))
				skald.send(ctx, Msg(Timeline_View{op = .Drag_Begin}))
			case onTrack && ctx.input.mouse_click_count[.Left] >= 2:
				// A key there, from the node's value now
				skald.send(ctx, Msg(Timeline_View{op = .Track_Selected, index = row}))
				skald.send(ctx, Msg(Timeline_View{op = .Scrubbed, number = snapTime(at, .Shift in ctx.input.modifiers)}))
				skald.send(ctx, Msg(Timeline_Changed{op = .Key_Added}))
			case local.x >= names:
				if onTrack do skald.send(ctx, Msg(Timeline_View{op = .Track_Selected, index = row}))
				skald.send(ctx, Msg(Timeline_View{op = .Scrubbed, number = at}))
				skald.send(ctx, Msg(Timeline_View{op = .Scrub_Begin}))
			}
		} else if ctx.input.mouse_buttons[.Left] && ctx.input.mouse_delta != {} {
			if t.dragging {
				target := snapTime(at, .Shift in ctx.input.modifiers)
				if t.track >= 0 && t.track < len(clip.tracks) && t.key >= 0 && t.key < len(clip.tracks[t.track].keys) && clip.tracks[t.track].keys[t.key].time != target {
					skald.send(ctx, Msg(Timeline_Changed{op = .Key_Moved, number = target}))
				}
			} else if t.scrubbing {
				skald.send(ctx, Msg(Timeline_View{op = .Scrubbed, number = at}))
			}
		}
		if ctx.input.mouse_released[.Left] {
			if t.dragging do skald.send(ctx, Msg(Timeline_View{op = .Drag_End}))
			if t.scrubbing do skald.send(ctx, Msg(Timeline_View{op = .Scrub_End}))
		}
	}

	Track :: struct { name: string, keys: []f32, selected: int, event, broken: bool }
	Data :: struct {
		tracks: []Track,
		track: int,
		length, time, width: f32,
		fg, muted, lit, key, bg, line, warning, playhead: skald.Color,
		size: f32,
	}
	scene := &s.project.scenes[s.currentScene]
	tracks := make([]Track, len(clip.tracks), context.temp_allocator)
	for &track, i in clip.tracks {
		keys := make([]f32, len(track.keys), context.temp_allocator)
		for k, j in track.keys do keys[j] = k.time
		event := track.property == e.ANIMATOR_EVENT_PROPERTY
		// Cut to the names' column (about 0.6 em a character)
		name := trackName(&track)
		fits := max(int((Timeline_NameWidth(width) - 10) / (th.font.size_xs * 0.6)), 3)
		if strings.rune_count(name) > fits do name = fmt.tprintf("%s…", strings.cut(name, 0, fits - 1))
		tracks[i] = {strings.clone(name, context.temp_allocator), keys, i == t.track ? t.key : -1, event, !event && Timeline_ResolvePath(scene, index, track.node) < 0}
	}
	data := new_clone(Data{tracks, t.track, clip.length, t.playhead, width,
		th.color.fg, th.color.fg_muted, th.color.primary, th.color.fg, th.color.surface, th.color.border, th.color.warning, {1, 0.35, 0.3, 1},
		th.font.size_xs}, context.temp_allocator)
	return skald.canvas(ctx, data, proc(d: ^Data, p: skald.Canvas_Painter) {
		b := p.bounds
		skald.draw_rect(p.r, b, d.bg)
		// The ruler: a tick every tenth of a second, a number every second (or half, a quarter)
		step := f32(0.1)
		labelEvery := d.length <= 1 ? f32(0.25) : d.length <= 4 ? f32(0.5) : f32(1)
		if d.length > 20 do step, labelEvery = 1, 5
		for at := f32(0); at <= d.length + 0.0001; at += step {
			x := b.x + Timeline_TimeX(d.width, d.length, at)
			labelled := abs(at / labelEvery - math.round(at / labelEvery)) < 0.001
			skald.draw_rect(p.r, {x, b.y + (labelled ? 4 : 12), 1, labelled ? TIMELINE_RULER_HEIGHT - 4 : 8}, d.line)
			if labelled do drawTextTop(p.r, fmt.tprintf("%gs", math.round(at * 100) / 100), x + 3, b.y + 2, d.muted, d.size)
		}
		for &track, i in d.tracks {
			y := b.y + TIMELINE_RULER_HEIGHT + f32(i) * TIMELINE_ROW_HEIGHT
			if i == d.track do skald.draw_rect(p.r, {b.x, y, b.w, TIMELINE_ROW_HEIGHT}, {d.lit.r, d.lit.g, d.lit.b, 0.15})
			skald.draw_rect(p.r, {b.x, y, b.w, 1}, d.line)
			drawTextTop(p.r, track.name, b.x + 6, y + 4, track.broken ? d.warning : d.fg, d.size)
			// A line through the track's keys
			if len(track.keys) > 1 {
				x0 := b.x + Timeline_TimeX(d.width, d.length, track.keys[0])
				x1 := b.x + Timeline_TimeX(d.width, d.length, track.keys[len(track.keys) - 1])
				skald.draw_rect(p.r, {x0, y + TIMELINE_ROW_HEIGHT * 0.5, x1 - x0, 1}, d.muted)
			}
			for key, k in track.keys {
				x := b.x + Timeline_TimeX(d.width, d.length, key)
				cy := y + TIMELINE_ROW_HEIGHT * 0.5
				r := f32(k == track.selected ? 6 : 5)
				color := k == track.selected ? d.lit : track.event ? d.warning : d.key
				// A diamond: stacked bars
				for dy := -r; dy <= r; dy += 1 {
					w := (r - abs(dy)) * 2
					skald.draw_rect(p.r, {x - w * 0.5, cy + dy, w, 1}, color)
				}
			}
		}
		if len(d.tracks) == 0 {
			drawTextTop(p.r, "No tracks yet: choose a node and a property above, then + Track.", b.x + 6, b.y + TIMELINE_RULER_HEIGHT + 4, d.muted, d.size)
		}
		skald.draw_rect(p.r, {b.x + Timeline_NameWidth(d.width) - 1, b.y, 1, b.h}, d.line)
		// The playhead
		x := b.x + Timeline_TimeX(d.width, d.length, d.time)
		skald.draw_rect(p.r, {x - 1, b.y, 2, b.h}, d.playhead)
	}, id = id, width = width, height = height, cursor = .Pointer)
}

// Times snap to TIMELINE_SNAP unless Shift is held
@(private="file")
snapTime :: proc(at: f32, free: bool) -> f32 {
	if free do return at
	return math.round(at / TIMELINE_SNAP) * TIMELINE_SNAP
}

/*
The inspector's rows for an Animator: its clips, the one it starts with, its speed, and the
Timeline.
*/
animatorInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	a := &node.animator
	names := make([dynamic]string, context.temp_allocator)
	append(&names, TEXTURE_NONE)
	for c in a.clips do append(&names, c.name)
	start := a.autoplay == "" ? TEXTURE_NONE : a.autoplay
	append(&rows, inspectorRow(ctx, "First clip", skald.select(ctx, start, names[:], proc(v: string) -> Msg {
		return Timeline_Changed{op = .Autoplay_Named, text = v == TEXTURE_NONE ? "" : v}
	}, id = skald.hash_id(fmt.tprintf("inspector-animator-autoplay-%d", key)), width = controlWidth)))
	append(&rows, inspectorRow(ctx, "Clip speed", numberField(ctx, s, fmt.tprintf("inspector-animator-speed-%d", key), TimelineNumber.Speed, f64(a.speed), 0.1, 2, numberWidth, 0, 100)))
	tracks := 0
	for c in a.clips do tracks += len(c.tracks)
	summary := len(a.clips) == 0 ? "No clips yet" : fmt.tprintf("%d clip%s, %d track%s", len(a.clips), len(a.clips) == 1 ? "" : "s", tracks, tracks == 1 ? "" : "s")
	append(&rows, skald.text(summary, th.color.fg_muted, th.font.size_xs, max_width = controlWidth + INSPECTOR_LABEL_WIDTH))
	append(&rows, skald.button(ctx, fmt.tprintf("%s  Edit in the Timeline", ICON_FILM), Msg(Bottom_Tab_Changed(int(BottomTab.Timeline))),
		id = skald.hash_id(fmt.tprintf("inspector-animator-timeline-%d", key)), padding = {th.spacing.sm, 2}, font_size = th.font.size_sm))
	return rows[:]
}
