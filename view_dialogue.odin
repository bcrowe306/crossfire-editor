package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The Dialogue tab (the bottom panel's): the shown dialogue (dialogue_edit.odin) as a graph of its
nodes, and the selected node's steps.

	+--------------------------------------------------------------------------------------+
	| [talk.dialogue.xml v]  + Node   Starts in [Start v]                          Manual   |
	|   [ Start ★ ] --- Buy a sword --->  [ Buy ]                                           |
	|        \\----------- Goodbye ------> [ End ]                                           |
	+--------------------------------------------------------------------------------------+
	| Node Start: Name [Start]  Remove Node                                                |
	| 1 Line   Speaker [Guide] Text [Welcome!..........]  If [      ]   ^ v ×               |
	| 2 Options  Buy a sword -> [Buy v] If [$gold >= 5] ×  + Option                          |
	| + Line + Options + Jump + Set + Command + Stop                                       |
	+--------------------------------------------------------------------------------------+

In the graph a click selects a node (dragging moves it), a double-click on empty space adds one.
Arrows are jumps and options, labeled with the option's text.

Widget keys: `dialogue-choose`, `dialogue-add-node`, `dialogue-start`, `dialogue-graph`,
`dialogue-node-name`, `dialogue-node-remove`, `dialogue-add-<Kind>`, step rows
`dialogue-step-<i>-<field>`, `dialogue-step-<i>-up|down|remove`, options
`dialogue-step-<i>-option-<k>-<field>`, `dialogue-step-<i>-option-add`, `dialogue-manual`.
*/

// A node's box in the graph
DIALOGUE_BOX :: [2]f32{130, 38}

// The last graph's top left on screen (UI tests aim at nodes through it)
dialogueGraphOrigin: [2]f32

DialoguePanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.sm * 2 - INSPECTOR_SCROLLBAR_WIDTH
	small :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View { return uiText(ctx.theme, .Muted, text) }
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg) -> skald.View {
		tk := uiTokens(ctx)
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.bg, fg = th.color.fg,
			padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	labeled :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
		return skald.row(uiText(ctx.theme, .Muted, label), control, spacing = ctx.theme.spacing.xs, cross_align = .Center)
	}
	rows := make([dynamic]skald.View, context.temp_allocator)
	bar := make([dynamic]skald.View, context.temp_allocator)
	paths := make([dynamic]string, context.temp_allocator)
	for d in s.project.dialogues do append(&paths, d.path)
	def := Dialogue_Shown(s)
	if len(paths) > 0 {
		append(&bar, skald.select(ctx, def != nil ? strings.clone(def.path, context.temp_allocator) : "", paths[:],
			proc(v: string) -> Msg { return Dialogue_View{op = .Show, path = v} }, id = skald.hash_id("dialogue-choose"), width = tk.fieldL, placeholder = "Choose a dialogue"))
	}
	append(&bar, button(ctx, "dialogue-new", fmt.tprintf("%s  New Dialogue", ACTION_ICONS[.Add]), Msg(Dialogue_Created{})))
	if def == nil {
		append(&bar, button(ctx, "dialogue-manual", fmt.tprintf("%s  Manual", ACTION_ICONS[.Manual]), Msg(Manual_Opened("dialogue"))))
		append(&rows, skald.wrap_row(..bar[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width, bg = th.color.surface))
		append(&rows, uiText(th, .Label, "Conversations: who says what, and the choices the player makes. Make one with New Dialogue (or import a Yarn Spinner .yarn file), then show it in the game with a DialogueBox node.", max_width = tk.textWide))
		return skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.sm)
	}
	data := &def.data
	ed := &s.dialogue
	free := [2]f32{20, 20}
	for n in data.nodes do free.x = max(free.x, n.position.x + DIALOGUE_BOX.x + 30)
	append(&bar, button(ctx, "dialogue-add-node", fmt.tprintf("%s  Node", ACTION_ICONS[.Add]), Msg(Dialogue_Changed{op = .Node_Added, position = {free.x, 20}})))
	names := make([dynamic]string, context.temp_allocator)
	for n in data.nodes do append(&names, strings.clone(n.name, context.temp_allocator))
	append(&bar, labeled(ctx, "Starts in", skald.select(ctx, strings.clone(data.start, context.temp_allocator), names[:],
		proc(v: string) -> Msg { return Dialogue_Changed{op = .Start_Set, text = v} }, id = skald.hash_id("dialogue-start"), width = tk.fieldS)))
	append(&bar, small(ctx, fmt.tprintf("%d nodes", len(data.nodes))))
	append(&bar, button(ctx, "dialogue-manual", fmt.tprintf("%s  Manual", ACTION_ICONS[.Manual]), Msg(Manual_Opened("dialogue"))))
	append(&rows, skald.wrap_row(..bar[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width, bg = th.color.surface))
	append(&rows, dialogueGraph(ctx, s, data, max(width - th.spacing.sm * 2, 200)))

	// The selected node's steps
	if ed.node < 0 || ed.node >= len(data.nodes) {
		append(&rows, small(ctx, "Click a node to edit its steps; double-click empty space for a new node; drag nodes to arrange them."))
		return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, width = width, padding = th.spacing.sm), id = skald.hash_id("dialogue-scroll"))
	}
	node := &data.nodes[ed.node]
	head := make([dynamic]skald.View, context.temp_allocator)
	append(&head, uiText(th, .Value, fmt.tprintf("Node %s", node.name)))
	append(&head, labeled(ctx, "Name", skald.text_input(ctx, strings.clone(node.name, context.temp_allocator), proc(v: string) -> Msg { return Dialogue_Changed{op = .Node_Renamed, text = v} },
		id = skald.hash_id("dialogue-node-name"), width = tk.fieldS)))
	append(&head, button(ctx, "dialogue-node-remove", fmt.tprintf("%s  Remove Node", ACTION_ICONS[.Delete]), Msg(Dialogue_Changed{op = .Node_Removed})))
	append(&rows, skald.wrap_row(..head[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width))

	targets := make([dynamic]string, context.temp_allocator)
	append(&targets, TEXTURE_NONE)
	append(&targets, ..names[:])
	Field :: struct { step, option: int, field: DialogueField }
	input :: proc(ctx: ^skald.Ctx(Msg), f: Field, value, placeholder: string, width: f32) -> skald.View {
		key := f.option >= 0 ? fmt.tprintf("dialogue-step-%d-option-%d-%v", f.step, f.option, f.field) : fmt.tprintf("dialogue-step-%d-%v", f.step, f.field)
		return skald.text_input(ctx, strings.clone(value, context.temp_allocator), f, proc(f: Field, v: string) -> Msg {
			return Dialogue_Changed{op = f.option >= 0 ? .Option_Field : .Step_Field, step = f.step, option = f.option, field = f.field, text = v}
		}, id = skald.hash_id(key), width = width, placeholder = placeholder)
	}
	target :: proc(ctx: ^skald.Ctx(Msg), f: Field, value: string, names: []string) -> skald.View {
		tk := uiTokens(ctx)
		key := f.option >= 0 ? fmt.tprintf("dialogue-step-%d-option-%d-Target", f.step, f.option) : fmt.tprintf("dialogue-step-%d-Target", f.step)
		return skald.select(ctx, value == "" ? TEXTURE_NONE : strings.clone(value, context.temp_allocator), names, f, proc(f: Field, v: string) -> Msg {
			return Dialogue_Changed{op = f.option >= 0 ? .Option_Field : .Step_Field, step = f.step, option = f.option, field = .Target, text = v}
		}, id = skald.hash_id(key), width = tk.fieldS)
	}
	for st, i in node.steps {
		line := make([dynamic]skald.View, context.temp_allocator)
		selected := i == ed.step
		// A right-click on the step: its menu (move, insert after, delete: context_menus_panels.odin)
		// (it's selected first: Insert After goes after the selected step)
		if rightPressOpens(ctx, lastRect(ctx, skald.hash_id(fmt.tprintf("dialogue-step-%d", i))), Ctx_Graph{graph = .Dialogue_Step, item = i, sub = -1}) {
			skald.send(ctx, Msg(Dialogue_View{op = .Select_Step, index = i}))
		}
		append(&line, skald.button(ctx, fmt.tprintf("%d %v", i + 1, st.kind), Msg(Dialogue_View{op = .Select_Step, index = i}), id = skald.hash_id(fmt.tprintf("dialogue-step-%d", i)),
			bg = selected ? th.color.primary : th.color.surface, fg = selected ? th.color.on_primary : th.color.fg, padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm))
		switch st.kind {
		case .Line:
			append(&line, labeled(ctx, "Speaker", input(ctx, {i, -1, .Speaker}, st.speaker, "nobody", 90)))
			append(&line, labeled(ctx, "Says", input(ctx, {i, -1, .Text}, st.text, "what they say ({$var} puts a variable in)", 280)))
		case .Options:
			for o, k in st.options {
				Remove :: struct { step, option: int }
				append(&line, skald.row(
					input(ctx, {i, k, .Text}, o.text, "the choice", 140),
					small(ctx, "→"),
					target(ctx, {i, k, .Target}, o.target, targets[:]),
					input(ctx, {i, k, .Condition}, o.condition, "shown if...", 100),
					button(ctx, fmt.tprintf("dialogue-step-%d-option-%d-remove", i, k), ACTION_ICONS[.Remove], Msg(Dialogue_Changed{op = .Option_Removed, step = i, option = k})),
					spacing = th.spacing.xs, cross_align = .Center,
				))
			}
			append(&line, button(ctx, fmt.tprintf("dialogue-step-%d-option-add", i), fmt.tprintf("%s  Option", ACTION_ICONS[.Add]), Msg(Dialogue_Changed{op = .Option_Added, step = i})))
		case .Jump:
			append(&line, labeled(ctx, "Go to", target(ctx, {i, -1, .Target}, st.target, targets[:])))
		case .Set:
			append(&line, input(ctx, {i, -1, .Variable}, st.variable, "$name", 90))
			append(&line, small(ctx, "="))
			append(&line, input(ctx, {i, -1, .Expression}, st.expression, "a value: 5, $gold - 5, true", 180))
		case .Command:
			append(&line, input(ctx, {i, -1, .Command}, st.command, "shake 2 (onCommand); wait 1 waits", 200))
		case .Stop:
			append(&line, small(ctx, "The conversation ends here."))
		}
		append(&line, labeled(ctx, "If", input(ctx, {i, -1, .Condition}, st.condition, "always", 110)))
		append(&line, button(ctx, fmt.tprintf("dialogue-step-%d-up", i), "↑", Msg(Dialogue_Changed{op = .Step_Moved, step = i, delta = -1})))
		append(&line, button(ctx, fmt.tprintf("dialogue-step-%d-down", i), "↓", Msg(Dialogue_Changed{op = .Step_Moved, step = i, delta = 1})))
		append(&line, button(ctx, fmt.tprintf("dialogue-step-%d-remove", i), ACTION_ICONS[.Delete], Msg(Dialogue_Changed{op = .Step_Removed, step = i})))
		append(&rows, skald.wrap_row(..line[:], spacing = th.spacing.sm, line_spacing = th.spacing.xs, padding = th.spacing.xs, width = width))
		// Its condition's mistakes
		if st.condition != "" {
			if _, ok := e.Dialogue_Evaluate(nil, st.condition); !ok do append(&rows, uiText(th, .Muted, fmt.tprintf("Step %d: \"%s\" isn't an expression", i + 1, st.condition), color = th.color.warning))
		}
	}
	if len(node.steps) == 0 do append(&rows, small(ctx, "No steps yet: add a line below. A node runs its steps in order; when it runs out, the conversation ends."))
	add := make([dynamic]skald.View, context.temp_allocator)
	append(&add, small(ctx, ed.step >= 0 ? "Add after the selected step:" : "Add:"))
	for kind in e.DialogueStepKind {
		append(&add, button(ctx, fmt.tprintf("dialogue-add-%v", kind), fmt.tprintf("+ %v", kind), Msg(Dialogue_Changed{op = .Step_Added, kind = kind})))
	}
	append(&rows, skald.wrap_row(..add[:], spacing = th.spacing.sm, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width))
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, width = width, padding = th.spacing.sm), id = skald.hash_id("dialogue-scroll"))
}

// A node's box in the graph (canvas coordinates)
Dialogue_BoxRect :: proc(n: e.DialogueNode) -> [4]f32 {
	return {n.position.x, n.position.y, DIALOGUE_BOX.x, DIALOGUE_BOX.y}
}

@(private="file")
dialogueGraph :: proc(ctx: ^skald.Ctx(Msg), s: ^State, data: ^e.DialogueData, width: f32) -> skald.View {
	th := ctx.theme
	ed := &s.dialogue
	id := skald.hash_id("dialogue-graph")
	height: f32 = 180
	for n in data.nodes do height = max(height, n.position.y + DIALOGUE_BOX.y + 30)
	if state, drawn := ctx.widgets.states[id]; drawn && state.last_rect.w > 0 && len(ctx.widgets.overlay_rects_prev) == 0 {
		rect := state.last_rect
		dialogueGraphOrigin = {rect.x, rect.y}
		visible := state.clip_rect.w > 0 ? state.clip_rect : rect
		m := ctx.input.mouse_pos
		local := m - {rect.x, rect.y}
		inside :: proc(r: skald.Rect, p: [2]f32) -> bool { return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h }
		inBox :: proc(r: [4]f32, p: [2]f32) -> bool { return p.x >= r[0] && p.x < r[0] + r[2] && p.y >= r[1] && p.y < r[1] + r[3] }
		// A right-click: the node under it is selected and its menu opens (context_menus_panels.odin)
		if ctx.input.mouse_pressed[.Right] && inside(rect, m) && inside(visible, m) {
			hit := -1
			for n, i in data.nodes do if inBox(Dialogue_BoxRect(n), local) do hit = i
			if hit >= 0 do skald.send(ctx, Msg(Dialogue_View{op = .Select_Node, index = hit}))
			skald.send(ctx, Msg(Context_Menu_Opened{at = m, target = Ctx_Graph{graph = .Dialogue, item = hit, sub = -1, local = local}}))
			ctx.input.mouse_pressed[.Right] = false
		}
		if ctx.input.mouse_pressed[.Left] && inside(rect, m) && inside(visible, m) {
			hit := -1
			for n, i in data.nodes do if inBox(Dialogue_BoxRect(n), local) do hit = i
			switch {
			case hit >= 0:
				skald.send(ctx, Msg(Dialogue_View{op = .Select_Node, index = hit}))
				skald.send(ctx, Msg(Dialogue_View{op = .Drag_Begin, grab = local - data.nodes[hit].position}))
			case ctx.input.mouse_click_count[.Left] >= 2:
				skald.send(ctx, Msg(Dialogue_Changed{op = .Node_Added, position = local - DIALOGUE_BOX * 0.5}))
			case:
				skald.send(ctx, Msg(Dialogue_View{op = .Select_Node, index = -1}))
			}
		} else if ed.dragging && ctx.input.mouse_buttons[.Left] && ctx.input.mouse_delta != {} && ed.node >= 0 {
			skald.send(ctx, Msg(Dialogue_Changed{op = .Node_Moved, position = local - ed.grab}))
		}
		if ctx.input.mouse_released[.Left] && ed.dragging do skald.send(ctx, Msg(Dialogue_View{op = .Drag_End}))
	}

	Box :: struct { rect: [4]f32, name, first: string, start, selected: bool }
	Arrow :: struct { a, b: [2]f32, label: string }
	Data :: struct {
		boxes: []Box,
		arrows: []Arrow,
		fg, muted, lit, box, line, bg, start: skald.Color,
		size: f32,
	}
	boxes := make([]Box, len(data.nodes), context.temp_allocator)
	arrows := make([dynamic]Arrow, context.temp_allocator)
	center :: proc(r: [4]f32) -> [2]f32 { return {r[0] + r[2] * 0.5, r[1] + r[3] * 0.5} }
	link :: proc(arrows: ^[dynamic]Arrow, data: ^e.DialogueData, from: int, to: string, label: string) {
		t := e.Dialogue_FindNode(data, to)
		if t < 0 || t == from do return
		a, b := center(Dialogue_BoxRect(data.nodes[from])), center(Dialogue_BoxRect(data.nodes[t]))
		d := b - a
		length := math.sqrt(d.x * d.x + d.y * d.y)
		if length < 1 do return
		dir := d / length
		edge :: proc(dir: [2]f32) -> f32 {
			tx := abs(dir.x) > 0.0001 ? DIALOGUE_BOX.x * 0.5 / abs(dir.x) : max(f32)
			ty := abs(dir.y) > 0.0001 ? DIALOGUE_BOX.y * 0.5 / abs(dir.y) : max(f32)
			return min(tx, ty)
		}
		side := [2]f32{-dir.y, dir.x} * 5
		append(arrows, Arrow{a + dir * edge(dir) + side, b - dir * edge(dir) + side, strings.clone(label, context.temp_allocator)})
	}
	for n, i in data.nodes {
		first := ""
		for st in n.steps do if st.kind == .Line {
			first = st.speaker != "" ? fmt.tprintf("%s: %s", st.speaker, st.text) : st.text
			break
		}
		if len(first) > 22 do first = fmt.tprintf("%s…", first[:20])
		boxes[i] = {Dialogue_BoxRect(n), strings.clone(n.name, context.temp_allocator), strings.clone(first, context.temp_allocator), n.name == data.start, i == ed.node}
		for st in n.steps {
			if st.kind == .Jump do link(&arrows, data, i, st.target, "")
			if st.kind == .Options do for o in st.options do link(&arrows, data, i, o.target, o.text)
		}
	}
	d := new_clone(Data{boxes, arrows[:], th.color.fg, th.color.fg_muted, th.color.primary, th.color.surface, th.color.border, th.color.bg, th.color.warning, th.font.size_xs}, context.temp_allocator)
	return skald.canvas(ctx, d, proc(d: ^Data, p: skald.Canvas_Painter) {
		o := [2]f32{p.bounds.x, p.bounds.y}
		skald.draw_rect(p.r, p.bounds, d.bg)
		for a in d.arrows {
			skald.draw_line(p.r, o + a.a, o + a.b, 1.2, d.muted, aa = true)
			dir := a.b - a.a
			length := math.sqrt(dir.x * dir.x + dir.y * dir.y)
			if length > 0 {
				dir /= length
				side := [2]f32{-dir.y, dir.x}
				tip := o + a.b
				skald.draw_polygon(p.r, {tip, tip - dir * 9 + side * 4, tip - dir * 9 - side * 4}, d.muted, aa = true)
			}
			if a.label != "" {
				mid := o + (a.a + a.b) * 0.5
				drawTextTop(p.r, a.label, mid.x + 4, mid.y - 14, d.muted, d.size)
			}
		}
		for b in d.boxes {
			r := skald.Rect{o.x + b.rect[0], o.y + b.rect[1], b.rect[2], b.rect[3]}
			skald.draw_rect(p.r, r, d.box, 6)
			edge := b.selected ? d.lit : b.start ? d.start : d.line
			skald.draw_rect_outline(p.r, r, b.selected || b.start ? 2 : 1, edge, 6)
			drawTextTop(p.r, b.start ? fmt.tprintf("%s ★", b.name) : b.name, r.x + 8, r.y + 3, d.fg, d.size)
			if b.first != "" do drawTextTop(p.r, b.first, r.x + 8, r.y + 19, d.muted, d.size)
		}
	}, id = id, width = width, height = height, cursor = .Pointer)
}
