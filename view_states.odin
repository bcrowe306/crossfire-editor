package crossfire_editor

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The States tab (the bottom panel's): the shown StateMachine as a graph (state_machine_edit.odin).

	+--------------------------------------------------------------------------------------+
	| + State   + Parameter   Starts in [idle v]                             Manual          |
	| [Any state]                                                                            |
	|        [ idle ★ ] ---- speed > 10 ---->  [ run ]                                       |
	|            ^ <------- speed <= 10 -------                                              |
	+--------------------------------------------------------------------------------------+
	| State idle: Name [idle]  Animation [idle v]  Starts here  + Transition to [run v]  Remove|
	| Parameters: speed Float 0 ×   grounded Bool true ×                                     |
	+--------------------------------------------------------------------------------------+

In the graph: a click selects a state (and dragging moves it) or a transition (click its arrow),
a double-click on empty space adds a state there.

Widget keys: `states-add`, `states-add-param`, `states-graph`, `states-name`, `states-animation`,
`states-start`, `states-connect`, `states-remove`, `states-condition`, `states-after`,
`states-on-finished`, `states-remove-transition`, `states-param-name-<i>`, `states-param-kind-<i>`,
`states-param-value-<i>`, `states-param-remove-<i>`, `states-manual`.
*/

// A state's box in the graph
STATE_BOX :: [2]f32{110, 34}
// Where "Any state" sits (the source of `*` transitions)
@(private="file")
ANY_BOX :: [4]f32{8, 8, 84, 24}

StatesPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	node, index := States_Machine(s)
	if node == nil {
		text := "Select a StateMachine node to edit its states: what a character is doing (idle, run, jump, attack), the conditions that move it from one to another, and the animation each plays. Add Node > StateMachine makes one (inside the AnimatedSprite it animates)."
		return skald.col(skald.text(text, th.color.fg_muted, th.font.size_sm, max_width = 600), padding = th.spacing.md)
	}
	ed := &s.states
	sm := &node.stateMachine
	scene := &s.project.scenes[s.currentScene]
	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.sm * 2 - INSPECTOR_SCROLLBAR_WIDTH
	small :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View { return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs) }
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.bg, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	labeled :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
		return skald.row(skald.text(label, ctx.theme.color.fg_muted, ctx.theme.font.size_xs), control, spacing = ctx.theme.spacing.xs, cross_align = .Center)
	}
	rows := make([dynamic]skald.View, context.temp_allocator)
	bar := make([dynamic]skald.View, context.temp_allocator)
	free := [2]f32{40, 60}
	for st in sm.states do free.y = max(free.y, st.position.y + STATE_BOX.y + 20)
	append(&bar, button(ctx, "states-add", fmt.tprintf("%s  State", ICON_PLUS), Msg(SM_Changed{op = .State_Added, position = free})))
	append(&bar, button(ctx, "states-add-param", fmt.tprintf("%s  Parameter", ICON_PLUS), Msg(SM_Changed{op = .Param_Added})))
	append(&bar, small(ctx, fmt.tprintf("%s: %d states, %d transitions", node.name, len(sm.states), len(sm.transitions))))
	append(&bar, button(ctx, "states-manual", fmt.tprintf("%s  Manual", ICON_CIRCLE_INFO), Msg(Manual_Opened("state_machines"))))
	append(&rows, skald.wrap_row(..bar[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width, bg = th.color.surface))
	append(&rows, graphCanvas(ctx, s, sm, max(width - th.spacing.sm * 2, 200)))

	// The selected state or transition
	edit := make([dynamic]skald.View, context.temp_allocator)
	if ed.state >= 0 && ed.state < len(sm.states) {
		st := sm.states[ed.state]
		append(&edit, skald.text(fmt.tprintf("State %s", st.name), th.color.fg, th.font.size_sm))
		append(&edit, labeled(ctx, "Name", skald.text_input(ctx, strings.clone(st.name, context.temp_allocator), proc(v: string) -> Msg { return SM_Changed{op = .State_Renamed, text = v} },
			id = skald.hash_id("states-name"), width = 110)))
		animations := make([dynamic]string, context.temp_allocator)
		append(&animations, ANIMATION_NONE)
		append(&animations, ..States_Animations(s, scene, index))
		append(&edit, labeled(ctx, "Plays", skald.select(ctx, st.animation == "" ? ANIMATION_NONE : strings.clone(st.animation, context.temp_allocator), animations[:],
			proc(v: string) -> Msg { return SM_Changed{op = .State_Animation, text = v} }, id = skald.hash_id("states-animation"), width = 120)))
		if sm.start != st.name do append(&edit, button(ctx, "states-start", "Starts Here", Msg(SM_Changed{op = .Start_Set, text = strings.clone(st.name, context.temp_allocator)})))
		targets := make([dynamic]string, context.temp_allocator)
		for other in sm.states do if other.name != st.name do append(&targets, other.name)
		append(&targets, "*")
		Connect :: struct {}
		append(&edit, labeled(ctx, "+ Transition to", skald.select(ctx, "", targets[:], Connect{}, proc(_: Connect, v: string) -> Msg { return SM_Changed{op = .Transition_Added, text = v} },
			id = skald.hash_id("states-connect"), width = 110, placeholder = "a state")))
		append(&edit, small(ctx, "(* : from any state to this one)"))
		append(&edit, button(ctx, "states-remove", fmt.tprintf("%s  Remove State", ICON_TRASH), Msg(SM_Changed{op = .State_Removed})))
	} else if ed.transition >= 0 && ed.transition < len(sm.transitions) {
		t := sm.transitions[ed.transition]
		from := t.from == "*" ? "any state" : t.from
		append(&edit, skald.text(fmt.tprintf("Transition %s → %s", from, t.to), th.color.fg, th.font.size_sm))
		append(&edit, labeled(ctx, "When", skald.text_input(ctx, strings.clone(t.condition, context.temp_allocator), proc(v: string) -> Msg { return SM_Changed{op = .Transition_Condition, text = v} },
			id = skald.hash_id("states-condition"), width = 180, placeholder = "always")))
		if problem := e.StateMachine_ConditionProblem(sm, t.condition); problem != "" do append(&edit, skald.text(problem, th.color.warning, th.font.size_xs))
		append(&edit, labeled(ctx, "After (s)", numberField(ctx, s, "states-after", SMAfterTarget{}, f64(t.after), 0.1, 2, 100, 0, 3600)))
		append(&edit, skald.checkbox(ctx, t.onFinished, "When its animation ends", proc(v: bool) -> Msg { return SM_Changed{op = .Transition_On_Finished, flag = v} },
			id = skald.hash_id("states-on-finished")))
		append(&edit, button(ctx, "states-remove-transition", fmt.tprintf("%s  Remove Transition", ICON_TRASH), Msg(SM_Changed{op = .Transition_Removed})))
	} else {
		append(&edit, small(ctx, "Click a state or an arrow to edit it; double-click empty space for a new state; drag states to arrange them."))
	}
	append(&rows, skald.wrap_row(..edit[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width))

	// The parameters
	params := make([dynamic]skald.View, context.temp_allocator)
	append(&params, skald.text("Parameters", th.color.fg, th.font.size_sm))
	kinds := reflect.enum_field_names(e.StateMachineParamKind)
	for p, i in sm.params {
		Payload :: struct { index: int }
		row := skald.row(
			skald.text_input(ctx, strings.clone(p.name, context.temp_allocator), Payload{i}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Param_Renamed, index = pl.index, text = v} },
				id = skald.hash_id(fmt.tprintf("states-param-name-%d", i)), width = 100),
			skald.select(ctx, fmt.tprint(p.kind), kinds, Payload{i}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Param_Kind, index = pl.index, text = v} },
				id = skald.hash_id(fmt.tprintf("states-param-kind-%d", i)), width = 80),
			p.kind == .Trigger ? small(ctx, "(set by code)") : skald.text_input(ctx, strings.clone(p.value, context.temp_allocator), Payload{i}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Param_Value, index = pl.index, text = v} },
				id = skald.hash_id(fmt.tprintf("states-param-value-%d", i)), width = 60),
			button(ctx, fmt.tprintf("states-param-remove-%d", i), ICON_TRASH, Msg(SM_Changed{op = .Param_Removed, index = i})),
			spacing = th.spacing.xs, cross_align = .Center,
		)
		append(&params, row)
	}
	if len(sm.params) == 0 do append(&params, small(ctx, "None yet: + Parameter. Scripts set them (e.StateMachine_SetFloat, SetBool, SetTrigger); conditions read them: speed > 10 and grounded."))
	append(&rows, skald.wrap_row(..params[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width))
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, width = width, padding = th.spacing.sm), id = skald.hash_id("states-scroll"))
}

// Where a state's box is in the graph (its position, from the canvas's top left)
States_BoxRect :: proc(st: e.StateMachineState) -> [4]f32 {
	return {st.position.x, st.position.y, STATE_BOX.x, STATE_BOX.y}
}

// A transition's arrow: from its source's box edge to its target's, nudged sideways so the two
// ways between two states don't overlap (canvas coordinates)
States_Arrow :: proc(sm: ^e.StateMachineSettings, t: e.StateMachineTransition) -> (a, b: [2]f32, ok: bool) {
	from, to := -1, -1
	for st, i in sm.states {
		if st.name == t.from do from = i
		if st.name == t.to do to = i
	}
	if to < 0 || (from < 0 && t.from != "*") do return
	box :: proc(r: [4]f32) -> ([2]f32, [2]f32) { return {r[0] + r[2] * 0.5, r[1] + r[3] * 0.5}, {r[2] * 0.5, r[3] * 0.5} }
	fromRect := from >= 0 ? States_BoxRect(sm.states[from]) : ANY_BOX
	c1, h1 := box(fromRect)
	c2, h2 := box(States_BoxRect(sm.states[to]))
	d := c2 - c1
	length := math.sqrt(d.x * d.x + d.y * d.y)
	if length < 1 do return
	dir := d / length
	side := [2]f32{-dir.y, dir.x} * 5
	// The box edge along the line: the smaller of the two axes' reach
	edge :: proc(dir, half: [2]f32) -> f32 {
		tx := abs(dir.x) > 0.0001 ? half.x / abs(dir.x) : max(f32)
		ty := abs(dir.y) > 0.0001 ? half.y / abs(dir.y) : max(f32)
		return min(tx, ty)
	}
	a = c1 + dir * edge(dir, h1) + side
	b = c2 - dir * edge(dir, h2) + side
	return a, b, true
}

// The last graph's top left on screen (the UI tests aim at states through it)
statesGraphOrigin: [2]f32

@(private="file")
graphCanvas :: proc(ctx: ^skald.Ctx(Msg), s: ^State, sm: ^e.StateMachineSettings, width: f32) -> skald.View {
	th := ctx.theme
	ed := &s.states
	id := skald.hash_id("states-graph")
	height: f32 = 200
	for st in sm.states do height = max(height, st.position.y + STATE_BOX.y + 30)
	if state, drawn := ctx.widgets.states[id]; drawn && state.last_rect.w > 0 && len(ctx.widgets.overlay_rects_prev) == 0 {
		rect := state.last_rect
		statesGraphOrigin = {rect.x, rect.y}
		visible := state.clip_rect.w > 0 ? state.clip_rect : rect
		m := ctx.input.mouse_pos
		local := m - {rect.x, rect.y}
		inside :: proc(r: skald.Rect, p: [2]f32) -> bool { return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h }
		inBox :: proc(r: [4]f32, p: [2]f32) -> bool { return p.x >= r[0] && p.x < r[0] + r[2] && p.y >= r[1] && p.y < r[1] + r[3] }
		if ctx.input.mouse_pressed[.Left] && inside(rect, m) && inside(visible, m) {
			hitState, hitTransition := -1, -1
			for st, i in sm.states do if inBox(States_BoxRect(st), local) do hitState = i
			if hitState < 0 {
				for t, i in sm.transitions {
					a, b, ok := States_Arrow(sm, t)
					if !ok do continue
					ab := b - a
					k := clamp(((local.x - a.x) * ab.x + (local.y - a.y) * ab.y) / max(ab.x * ab.x + ab.y * ab.y, 1), 0, 1)
					q := a + ab * k - local
					if math.sqrt(q.x * q.x + q.y * q.y) < 6 do hitTransition = i
				}
			}
			switch {
			case hitState >= 0:
				skald.send(ctx, Msg(SM_View{op = .Select_State, index = hitState}))
				skald.send(ctx, Msg(SM_View{op = .Drag_Begin, grab = local - sm.states[hitState].position}))
			case hitTransition >= 0:
				skald.send(ctx, Msg(SM_View{op = .Select_Transition, index = hitTransition}))
			case ctx.input.mouse_click_count[.Left] >= 2:
				skald.send(ctx, Msg(SM_Changed{op = .State_Added, position = local - STATE_BOX * 0.5}))
			case:
				skald.send(ctx, Msg(SM_View{op = .Select_State, index = -1}))
			}
		} else if ed.dragging && ctx.input.mouse_buttons[.Left] && ctx.input.mouse_delta != {} && ed.state >= 0 {
			skald.send(ctx, Msg(SM_Changed{op = .State_Moved, position = local - ed.grab}))
		}
		if ctx.input.mouse_released[.Left] && ed.dragging do skald.send(ctx, Msg(SM_View{op = .Drag_End}))
	}

	Box :: struct { rect: [4]f32, name, animation: string, start, selected: bool }
	Arrow :: struct { a, b: [2]f32, label: string, selected: bool }
	Data :: struct {
		boxes: []Box,
		arrows: []Arrow,
		anyState: bool,
		fg, muted, lit, box, line, bg, start: skald.Color,
		size: f32,
	}
	boxes := make([]Box, len(sm.states), context.temp_allocator)
	for st, i in sm.states do boxes[i] = {States_BoxRect(st), strings.clone(st.name, context.temp_allocator), strings.clone(st.animation, context.temp_allocator), st.name == sm.start, i == ed.state}
	arrows := make([dynamic]Arrow, context.temp_allocator)
	anyState := false
	for t, i in sm.transitions {
		if t.from == "*" do anyState = true
		a, b, ok := States_Arrow(sm, t)
		if !ok do continue
		label := t.condition
		if t.after > 0 do label = fmt.tprintf("%s%safter %gs", label, label == "" ? "" : ", ", t.after)
		if t.onFinished do label = fmt.tprintf("%s%sat its end", label, label == "" ? "" : ", ")
		append(&arrows, Arrow{a, b, strings.clone(label, context.temp_allocator), i == ed.transition})
	}
	data := new_clone(Data{boxes, arrows[:], anyState,
		th.color.fg, th.color.fg_muted, th.color.primary, th.color.surface, th.color.border, th.color.bg, th.color.warning, th.font.size_xs}, context.temp_allocator)
	return skald.canvas(ctx, data, proc(d: ^Data, p: skald.Canvas_Painter) {
		o := [2]f32{p.bounds.x, p.bounds.y}
		skald.draw_rect(p.r, p.bounds, d.bg)
		if d.anyState {
			r := ANY_BOX
			skald.draw_rect(p.r, {o.x + r[0], o.y + r[1], r[2], r[3]}, d.box, 10)
			drawTextTop(p.r, "Any state", o.x + r[0] + 10, o.y + r[1] + 5, d.muted, d.size)
		}
		for a in d.arrows {
			color := a.selected ? d.lit : d.muted
			width: f32 = a.selected ? 2 : 1.2
			skald.draw_line(p.r, o + a.a, o + a.b, width, color, aa = true)
			// The head
			dir := a.b - a.a
			length := math.sqrt(dir.x * dir.x + dir.y * dir.y)
			if length > 0 {
				dir /= length
				side := [2]f32{-dir.y, dir.x}
				tip := o + a.b
				head := [][2]f32{tip, tip - dir * 9 + side * 4, tip - dir * 9 - side * 4}
				skald.draw_polygon(p.r, head, color, aa = true)
			}
			if a.label != "" {
				mid := o + (a.a + a.b) * 0.5
				drawTextTop(p.r, a.label, mid.x + 4, mid.y - 14, color, d.size)
			}
		}
		for b in d.boxes {
			r := skald.Rect{o.x + b.rect[0], o.y + b.rect[1], b.rect[2], b.rect[3]}
			skald.draw_rect(p.r, r, d.box, 6)
			edge := b.selected ? d.lit : b.start ? d.start : d.line
			skald.draw_rect_outline(p.r, r, b.selected || b.start ? 2 : 1, edge, 6)
			drawTextTop(p.r, b.start ? fmt.tprintf("%s ★", b.name) : b.name, r.x + 8, r.y + 3, d.fg, d.size)
			if b.animation != "" do drawTextTop(p.r, fmt.tprintf("plays %s", b.animation), r.x + 8, r.y + 17, d.muted, d.size)
		}
	}, id = id, width = width, height = height, cursor = .Pointer)
}
