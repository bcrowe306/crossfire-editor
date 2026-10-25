package crossfire_editor

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:slice"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The States tab (the bottom panel's): the shown StateMachine as a graph (state_machine_edit.odin),
with a sidebar of the selected state's or transition's properties on its right.

	+------------------------------------------------------------------------------------------+
	| + State   + Parameter   Brain: 3 states, 4 transitions                         Manual      |
	| [Any state]                                          | Transition idle → run              |
	|        [ idle ★ ] ---- speed > 10 ---->  [ run ]     | When  [All of v]                   |
	|            ^ <------- speed <= 10 -------            |  ✓ [speed v] [> v] [10]  ×         |
	|                                                      |  + Condition  + Code guard [v]     |
	| Parameters: speed Float 0 ×   grounded Bool true ×   | Guard ...  Priority [0]  Exit after |
	+------------------------------------------------------------------------------------------+

Under `STATES_SIDEBAR_SPLIT_WIDTH` (a tiled or short window) the sidebar goes under the graph
instead, and under `STATES_STACK_WIDTH` its rows put their labels over their controls. One scroll
holds it all (`states-scroll`).

In the graph: a click selects a state (and dragging moves it) or a transition (click its arrow),
a double-click on empty space adds a state there. While the game runs (Play), the machine's
running node is watched over the live link: its current state is lit, transitions that would be
taken are green, and the sidebar marks each clause that holds (✓) or not (×) and says what
keeps a transition (its exit time, its condition, its guard, the state's exit guard).

Conditions (a transition's When and Guard, a state's Can exit when) show as rows when they're
flat (all of, or any of, their clauses): a clause reads a parameter (compared with a number) or
calls a code guard (`name()`, from the scripts' `e.StateMachine_RegisterGuard` /
`e.StateMachine_SetGuard`, read by the script index). Any condition can be typed as text.

Widget keys: `states-add`, `states-add-param`, `states-graph`, `states-sidebar`, `states-name`,
`states-animation`, `states-speed`, `states-loop`, `states-enter-event`, `states-exit-event`,
`states-start`, `states-connect`, `states-remove`, `states-condition`, `states-guard`,
`states-can-exit` (the text fields), per condition (`when`, `guard`, `exit`) `states-<c>-mode`,
`states-<c>-add`, `states-<c>-add-guard`, and per clause `states-<c>-neg-<i>`,
`states-<c>-name-<i>`, `states-<c>-op-<i>`, `states-<c>-value-<i>`, `states-<c>-remove-<i>`;
`states-priority`, `states-after`, `states-on-finished`, `states-interrupts`,
`states-remove-transition`, `states-param-name-<i>`, `states-param-kind-<i>`,
`states-param-value-<i>`, `states-param-remove-<i>`, `states-manual`.
*/

// The panel's width from which the sidebar sits beside the graph (else under it)
STATES_SIDEBAR_SPLIT_WIDTH :: 620
// The sidebar's width beside the graph: a share of the panel, within these
STATES_SIDEBAR_MIN :: 280
STATES_SIDEBAR_MAX :: 380
// Under this width the sidebar's rows put their labels over their controls
STATES_STACK_WIDTH :: 250

// How the sidebar shows a loop rule (the engine's AnimationLoopRule, in its order)
STATES_LOOP_LABELS := [e.AnimationLoopRule]string{
	.As_Made = "As made",
	.Loop = "Loop",
	.Once = "Once",
}

StatesPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	content, scrolls := StatesPanel_Content(s, ctx)
	if !scrolls do return content
	return skald.scroll(ctx, {0, 0}, content, id = skald.hash_id("states-scroll"))
}

/*
The States tab's content (StatesPanel puts it in its scroll, `states-scroll`): the toolbar, the
graph, the sidebar and the parameters; `scrolls` false for the message shown without a machine.
*/
StatesPanel_Content :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> (content: skald.View, scrolls: bool) {
	tk := uiTokens(ctx)
	th := ctx.theme
	node, index := States_Machine(s)
	if node == nil {
		text := "Select a StateMachine node to edit its states: what a character is doing (idle, run, jump, attack), the conditions that move it from one to another, and the animation each plays. Add Node > StateMachine makes one (inside the AnimatedSprite it animates)."
		return skald.col(uiText(th, .Label, text, max_width = tk.textWide), padding = th.spacing.md), false
	}
	sm := &node.stateMachine
	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.sm * 2 - INSPECTOR_SCROLLBAR_WIDTH
	width = max(width, tk.fieldM)
	beside := width >= STATES_SIDEBAR_SPLIT_WIDTH
	sideWidth := beside ? clamp(width * 0.4, STATES_SIDEBAR_MIN, STATES_SIDEBAR_MAX) : width - th.spacing.sm * 2
	graphWidth := beside ? width - sideWidth - th.spacing.md : width

	rows := make([dynamic]skald.View, context.temp_allocator)
	bar := make([dynamic]skald.View, context.temp_allocator)
	free := [2]f32{40, 60}
	for st in sm.states do free.y = max(free.y, st.position.y + STATE_BOX.y + 20)
	append(&bar, statesButton(ctx, "states-add", fmt.tprintf("%s  State", ACTION_ICONS[.Add]), Msg(SM_Changed{op = .State_Added, position = free})))
	append(&bar, statesButton(ctx, "states-add-param", fmt.tprintf("%s  Parameter", ACTION_ICONS[.Add]), Msg(SM_Changed{op = .Param_Added})))
	append(&bar, statesSmall(ctx, fmt.tprintf("%s: %d states, %d transitions", node.name, len(sm.states), len(sm.transitions))))
	if m := States_Live(s); m != nil do append(&bar, uiText(th, .Muted, fmt.tprintf("%s  Playing: %s (%.1f s)", ICON_PLAY, m.state, m.time), color = th.color.success))
	append(&bar, statesButton(ctx, "states-manual", fmt.tprintf("%s  Manual", ACTION_ICONS[.Manual]), Msg(Manual_Opened("state_machines"))))
	append(&rows, skald.wrap_row(..bar[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width, bg = th.color.surface))

	graph := graphCanvas(ctx, s, sm, max(graphWidth - th.spacing.sm * 2, 160))
	params := statesParams(ctx, s, sm, index, graphWidth)
	sidebar := statesSidebar(ctx, s, node, index, sideWidth)
	if beside {
		append(&rows, skald.row(
			skald.col(graph, params, spacing = th.spacing.xs, width = graphWidth),
			sidebar,
			spacing = th.spacing.md, cross_align = .Start))
	} else {
		append(&rows, graph, sidebar, params)
	}
	return skald.col(..rows[:], spacing = th.spacing.xs, width = width, padding = th.spacing.sm), true
}

/*
The running machine the States tab shows, as the game last sent it over the live link (nil: no
game, or not this machine).
*/
States_Live :: proc(s: ^State) -> ^LiveMachine {
	if s.live.machineWatch == "" || s.live.machine.id != s.live.machineWatch || s.play.stdin == nil do return nil
	return &s.live.machine
}

@(private="file")
statesSmall :: proc(ctx: ^skald.Ctx(Msg), text: string, maxWidth: f32 = 0) -> skald.View {
	return uiText(ctx.theme, .Muted, text, max_width = maxWidth)
}

@(private="file")
statesButton :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.bg, fg = th.color.fg,
		padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm)
}

// The parameters: name, kind, starting value
@(private="file")
statesParams :: proc(ctx: ^skald.Ctx(Msg), s: ^State, sm: ^e.StateMachineSettings, index: int, width: f32) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	params := make([dynamic]skald.View, context.temp_allocator)
	append(&params, uiText(th, .Value, "Parameters"))
	kinds := reflect.enum_field_names(e.StateMachineParamKind)
	live := States_Live(s)
	for p, i in sm.params {
		Payload :: struct { index: int }
		value := p.kind == .Trigger ? statesSmall(ctx, "(set by code)") : skald.text_input(ctx, strings.clone(p.value, context.temp_allocator), Payload{i}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Param_Value, index = pl.index, text = v} },
			id = skald.hash_id(fmt.tprintf("states-param-value-%d", i)), width = tk.fieldXS)
		row := make([dynamic]skald.View, context.temp_allocator)
		append(&row,
			CodeDrag_Handle(ctx, s, fmt.tprintf("states-param-drag-%d", i), DropSource{kind = .State_Param, name = p.name, node = index, index = -1, detail = fmt.tprint(p.kind)}),
			skald.text_input(ctx, strings.clone(p.name, context.temp_allocator), Payload{i}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Param_Renamed, index = pl.index, text = v} },
				id = skald.hash_id(fmt.tprintf("states-param-name-%d", i)), width = tk.fieldS),
			skald.select(ctx, fmt.tprint(p.kind), kinds, Payload{i}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Param_Kind, index = pl.index, text = v} },
				id = skald.hash_id(fmt.tprintf("states-param-kind-%d", i)), width = tk.fieldXS),
			value,
			statesButton(ctx, fmt.tprintf("states-param-remove-%d", i), ACTION_ICONS[.Delete], Msg(SM_Changed{op = .Param_Removed, index = i})))
		// Its value in the running game
		if live != nil do for lp in live.params do if lp.name == p.name do append(&row, uiText(th, .Muted, fmt.tprintf("now %s", lp.value), color = th.color.success))
		// Wraps in a narrow panel (a tiled window's is about 200 px)
		append(&params, skald.wrap_row(..row[:], spacing = th.spacing.xs, line_spacing = 2, width = min(width - th.spacing.sm * 2, tk.textMeasure)))
	}
	if len(sm.params) == 0 do append(&params, statesSmall(ctx, "None yet: + Parameter. Scripts set them (e.StateMachine_SetFloat, SetBool, SetTrigger); conditions read them: speed > 10 and grounded.", width - th.spacing.sm * 2))
	return skald.wrap_row(..params[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width)
}

// What a live transition status says in the sidebar
@(private="file")
statusText :: proc(status: e.StateMachineTransitionStatus) -> string {
	switch status {
	case .Not_From_Here:   return "Not from the current state"
	case .Waiting:         return "Waiting for its exit time"
	case .Condition_False: return "Its condition doesn't hold"
	case .Guard_Failed:    return "Blocked by its guard"
	case .Exit_Blocked:    return "Blocked by the state's exit guard"
	case .Ready:           return "Ready: it would be taken"
	}
	return ""
}

/*
The sidebar: the selected state's properties (name, animation, speed, loop, exit guard, events)
or the selected transition's (condition, guard, priority, exit time, interrupts), with what the
running game says about them.
*/
@(private="file")
statesSidebar :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, index: int, width: f32) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	ed := &s.states
	sm := &node.stateMachine
	scene := &s.project.scenes[s.currentScene]
	live := States_Live(s)
	stacked := width < STATES_STACK_WIDTH
	saved := inspectorStacked
	inspectorStacked = stacked
	defer inspectorStacked = saved
	control := stacked ? width - th.spacing.sm * 2 : width - th.spacing.sm * 2 - INSPECTOR_LABEL_WIDTH - th.spacing.sm
	rows := make([dynamic]skald.View, context.temp_allocator)
	line :: proc(ctx: ^skald.Ctx(Msg), text: string, color: skald.Color, width: f32) -> skald.View {
		return skald.text(text, color, ctx.theme.font.size_xs, max_width = width)
	}
	inner := width - th.spacing.sm * 2
	switch {
	case ed.state >= 0 && ed.state < len(sm.states):
		st := sm.states[ed.state]
		append(&rows, skald.row(uiText(th, .Value, fmt.tprintf("State %s", st.name)),
			// It drags into code by its grip (code_drag.odin)
			CodeDrag_Handle(ctx, s, "states-drag", DropSource{kind = .State, name = st.name, node = index, index = -1}),
			spacing = th.spacing.xs, cross_align = .Center))
		if live != nil {
			if live.state == st.name {
				append(&rows, line(ctx, fmt.tprintf("%s  The game is in it (%.1f s); %s", ICON_PLAY, live.time, live.canExit ? "it can be left" : "its exit guard keeps it"), live.canExit ? th.color.success : th.color.warning, inner))
			} else {
				append(&rows, line(ctx, fmt.tprintf("The game is in %s", live.state), th.color.fg_muted, inner))
			}
		}
		append(&rows, inspectorRow(ctx, "State name", skald.text_input(ctx, strings.clone(st.name, context.temp_allocator), proc(v: string) -> Msg { return SM_Changed{op = .State_Renamed, text = v} },
			id = skald.hash_id("states-name"), width = control)))
		animations := make([dynamic]string, context.temp_allocator)
		append(&animations, ANIMATION_NONE)
		append(&animations, ..States_Animations(s, scene, index))
		append(&rows, inspectorRow(ctx, "Plays", skald.select(ctx, st.animation == "" ? ANIMATION_NONE : strings.clone(st.animation, context.temp_allocator), animations[:],
			proc(v: string) -> Msg { return SM_Changed{op = .State_Animation, text = v} }, id = skald.hash_id("states-animation"), width = control)))
		append(&rows, inspectorRow(ctx, "Play speed", numberField(ctx, s, "states-speed", SMNumberTarget.Speed, f64(st.speed > 0 ? st.speed : 1), 0.1, 2, control, 0.01, 100)))
		loops := make([dynamic]string, context.temp_allocator)
		for label in STATES_LOOP_LABELS do append(&loops, label)
		append(&rows, inspectorRow(ctx, "Play loop", skald.select(ctx, STATES_LOOP_LABELS[st.loop], loops[:], proc(v: string) -> Msg {
			for label, rule in STATES_LOOP_LABELS do if label == v do return SM_Changed{op = .State_Loop, text = fmt.tprint(rule)}
			return SM_Changed{op = .State_Loop, text = ""}
		}, id = skald.hash_id("states-loop"), width = control)))
		append(&rows, conditionEditor(ctx, s, sm, .Exit, st.canExit, live != nil && live.state == st.name ? live.exit[:] : nil, width, control))
		append(&rows, inspectorRow(ctx, "Enter event", skald.text_input(ctx, strings.clone(st.enterEvent, context.temp_allocator), proc(v: string) -> Msg { return SM_Changed{op = .State_Enter_Event, text = v} },
			id = skald.hash_id("states-enter-event"), width = control, placeholder = "none")))
		append(&rows, inspectorRow(ctx, "Exit event", skald.text_input(ctx, strings.clone(st.exitEvent, context.temp_allocator), proc(v: string) -> Msg { return SM_Changed{op = .State_Exit_Event, text = v} },
			id = skald.hash_id("states-exit-event"), width = control, placeholder = "none")))
		buttons := make([dynamic]skald.View, context.temp_allocator)
		if sm.start != st.name do append(&buttons, statesButton(ctx, "states-start", "Starts Here", Msg(SM_Changed{op = .Start_Set, text = strings.clone(st.name, context.temp_allocator)})))
		targets := make([dynamic]string, context.temp_allocator)
		for other in sm.states do if other.name != st.name do append(&targets, other.name)
		append(&targets, "*")
		Connect :: struct {}
		append(&buttons, skald.row(statesSmall(ctx, "+ Transition to"), skald.select(ctx, "", targets[:], Connect{}, proc(_: Connect, v: string) -> Msg { return SM_Changed{op = .Transition_Added, text = v} },
			id = skald.hash_id("states-connect"), width = min(tk.fieldS, inner), placeholder = "a state"), spacing = th.spacing.xs, cross_align = .Center))
		append(&buttons, statesButton(ctx, "states-remove", fmt.tprintf("%s  Remove State", ACTION_ICONS[.Delete]), Msg(SM_Changed{op = .State_Removed})))
		append(&rows, skald.wrap_row(..buttons[:], spacing = th.spacing.sm, line_spacing = th.spacing.xs, width = inner))
		append(&rows, statesSmall(ctx, "(+ Transition to *: from any state to this one)", inner))
	case ed.transition >= 0 && ed.transition < len(sm.transitions):
		t := sm.transitions[ed.transition]
		from := t.from == "*" ? "any state" : t.from
		append(&rows, uiText(th, .Value, fmt.tprintf("Transition %s → %s", from, t.to), max_width = inner))
		lt: ^LiveTransition
		if live != nil && ed.transition < len(live.transitions) do lt = &live.transitions[ed.transition]
		if lt != nil do append(&rows, line(ctx, fmt.tprintf("%s  %s", lt.status == .Ready ? ICON_CHECK : ICON_XMARK, statusText(lt.status)), lt.status == .Ready ? th.color.success : th.color.fg_muted, inner))
		append(&rows, conditionEditor(ctx, s, sm, .When, t.condition, lt != nil ? lt.condition[:] : nil, width, control))
		append(&rows, conditionEditor(ctx, s, sm, .Guard, t.guard, lt != nil ? lt.guard[:] : nil, width, control))
		append(&rows, inspectorRow(ctx, "Priority", numberField(ctx, s, "states-priority", SMNumberTarget.Priority, f64(t.priority), 1, 0, control, -1000, 1000)))
		append(&rows, inspectorRow(ctx, "Exit after (s)", numberField(ctx, s, "states-after", SMNumberTarget.After, f64(t.after), 0.1, 2, control, 0, 3600)))
		append(&rows, skald.checkbox(ctx, t.onFinished, "When its animation ends", proc(v: bool) -> Msg { return SM_Changed{op = .Transition_On_Finished, flag = v} },
			id = skald.hash_id("states-on-finished")))
		append(&rows, skald.checkbox(ctx, t.interrupts, "Ignores the exit guard", proc(v: bool) -> Msg { return SM_Changed{op = .Transition_Interrupts, flag = v} },
			id = skald.hash_id("states-interrupts")))
		append(&rows, statesButton(ctx, "states-remove-transition", fmt.tprintf("%s  Remove Transition", ACTION_ICONS[.Delete]), Msg(SM_Changed{op = .Transition_Removed})))
	case:
		append(&rows, uiText(th, .Value, "Properties"))
		append(&rows, statesSmall(ctx, "Click a state or an arrow to edit it here; double-click empty space for a new state; drag states to arrange them.", inner))
		append(&rows, statesSmall(ctx, "Transitions are tried highest priority first; the first whose condition and guard hold, and whose state can be left, is taken.", inner))
		if guards := States_GuardNames(s); len(guards) > 0 {
			append(&rows, statesSmall(ctx, fmt.tprintf("Code guards the scripts provide: %s", strings.join(guards, ", ", context.temp_allocator)), inner))
		}
	}
	return skald.zone(ctx, skald.col(..rows[:], spacing = th.spacing.xs, width = width, padding = th.spacing.sm, bg = th.color.surface, radius = th.radius.sm), skald.hash_id("states-sidebar"))
}

/*
A condition's rows: its clauses (when it's flat) with All of / Any of, + Condition and + Code
guard, then the condition as text and what's wrong with it. `live`: whether each clause holds
in the running game (nil: no game).
*/
@(private="file")
conditionEditor :: proc(ctx: ^skald.Ctx(Msg), s: ^State, sm: ^e.StateMachineSettings, which: SMCondition, text: string, live: []bool, width, control: f32) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	keys := [SMCondition]string{.When = "when", .Guard = "guard", .Exit = "exit"}
	key := keys[which]
	labels := [SMCondition]string{.When = "When", .Guard = "Guard", .Exit = "Can exit when"}
	label := labels[which]
	inner := width - th.spacing.sm * 2
	rows := make([dynamic]skald.View, context.temp_allocator)
	clauses, any, flat := e.StateMachine_SplitCondition(text, context.temp_allocator)
	Payload :: struct { which: SMCondition, index: int }
	modes := []string{"All of", "Any of"}
	header: skald.View
	switch {
	case flat && len(clauses) >= 2:
		header = skald.select(ctx, any ? modes[1] : modes[0], modes, Payload{which, -1}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Clause_Mode, condition = pl.which, flag = v == "Any of"} },
			id = skald.hash_id(fmt.tprintf("states-%s-mode", key)), width = min(control, tk.fieldS))
	case len(clauses) == 0 && flat:
		header = statesSmall(ctx, which == .Exit ? "always (it can be left any time)" : which == .Guard ? "none" : "always")
	case !flat:
		header = statesSmall(ctx, "as text (below)")
	case:
		header = skald.spacer(0)
	}
	append(&rows, inspectorRow(ctx, label, header))
	guards := States_GuardNames(s)
	names := make([dynamic]string, context.temp_allocator)
	for p in sm.params do append(&names, p.name)
	for g in guards do append(&names, fmt.tprintf("%s()", g))
	ops := []string{CLAUSE_IS_TRUE, "==", "!=", "<", "<=", ">", ">="}
	if flat do for c, i in clauses {
		parts := make([dynamic]skald.View, context.temp_allocator)
		if i < len(live) do append(&parts, skald.text(live[i] ? ICON_CHECK : ICON_XMARK, live[i] ? th.color.success : th.color.danger, th.font.size_xs))
		append(&parts, skald.button(ctx, c.negated ? "not" : "is", Msg(SM_Changed{op = .Clause_Changed, condition = which, index = i, part = .Negated, text = c.negated ? "false" : "true"}),
			id = skald.hash_id(fmt.tprintf("states-%s-neg-%d", key, i)), bg = c.negated ? th.color.warning : th.color.bg, fg = th.color.fg,
			padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm))
		name := c.guard ? fmt.tprintf("%s()", c.name) : c.name
		options := names
		if !slice.contains(names[:], name) {
			options = make([dynamic]string, context.temp_allocator)
			append(&options, name)
			append(&options, ..names[:])
		}
		append(&parts, skald.select(ctx, name, options[:], Payload{which, i}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Clause_Changed, condition = pl.which, index = pl.index, part = .Name, text = v} },
			id = skald.hash_id(fmt.tprintf("states-%s-name-%d", key, i)), width = min(tk.fieldS, inner)))
		if !c.guard {
			append(&parts, skald.select(ctx, c.op == "" ? CLAUSE_IS_TRUE : c.op, ops, Payload{which, i}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Clause_Changed, condition = pl.which, index = pl.index, part = .Op, text = v} },
				id = skald.hash_id(fmt.tprintf("states-%s-op-%d", key, i)), width = tk.fieldXS))
			if c.op != "" {
				append(&parts, skald.text_input(ctx, c.value, Payload{which, i}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Clause_Changed, condition = pl.which, index = pl.index, part = .Value, text = v} },
					id = skald.hash_id(fmt.tprintf("states-%s-value-%d", key, i)), width = tk.fieldXXS))
			}
		}
		append(&parts, statesButton(ctx, fmt.tprintf("states-%s-remove-%d", key, i), ACTION_ICONS[.Delete], Msg(SM_Changed{op = .Clause_Removed, condition = which, index = i})))
		append(&rows, skald.wrap_row(..parts[:], spacing = th.spacing.xs, line_spacing = 2, width = inner))
	}
	if flat {
		adds := make([dynamic]skald.View, context.temp_allocator)
		if len(sm.params) > 0 do append(&adds, statesButton(ctx, fmt.tprintf("states-%s-add", key), fmt.tprintf("%s  Condition", ACTION_ICONS[.Add]), Msg(SM_Changed{op = .Clause_Added, condition = which})))
		if len(guards) > 0 {
			calls := make([dynamic]string, context.temp_allocator)
			for g in guards do append(&calls, fmt.tprintf("%s()", g))
			append(&adds, skald.select(ctx, "", calls[:], Payload{which, -1}, proc(pl: Payload, v: string) -> Msg { return SM_Changed{op = .Clause_Added, condition = pl.which, text = v} },
				id = skald.hash_id(fmt.tprintf("states-%s-add-guard", key)), width = min(tk.fieldS, inner), placeholder = "+ Code guard"))
		}
		if len(adds) > 0 do append(&rows, skald.wrap_row(..adds[:], spacing = th.spacing.xs, line_spacing = 2, width = inner))
	}
	// The text: anything (or, not, parentheses)
	textKeys := [SMCondition]string{.When = "states-condition", .Guard = "states-guard", .Exit = "states-can-exit"}
	textKey := textKeys[which]
	textOps := [SMCondition]SMOp{.When = .Transition_Condition, .Guard = .Transition_Guard, .Exit = .State_Can_Exit}
	textOp := textOps[which]
	OpPayload :: struct { op: SMOp }
	append(&rows, skald.text_input(ctx, strings.clone(text, context.temp_allocator), OpPayload{textOp}, proc(pl: OpPayload, v: string) -> Msg { return SM_Changed{op = pl.op, text = v} },
		id = skald.hash_id(textKey), width = inner, placeholder = which == .When ? "always" : "none"))
	if problem := e.StateMachine_ConditionProblem(sm, text, guards, checkGuards = true); problem != "" {
		append(&rows, uiText(th, .Muted, problem, max_width = inner, color = th.color.warning))
	}
	return skald.col(..rows[:], spacing = tk.xs)
}

// A state's box in the graph
STATE_BOX :: [2]f32{110, 34}
// Where "Any state" sits (the source of `*` transitions)
@(private="file")
ANY_BOX :: [4]f32{8, 8, 84, 24}

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
// The state (else the transition) under a point of the graph (-1: none)
States_HitTest :: proc(sm: ^e.StateMachineSettings, local: [2]f32) -> (hitState, hitTransition: int) {
	hitState, hitTransition = -1, -1
	inBox :: proc(r: [4]f32, p: [2]f32) -> bool { return p.x >= r[0] && p.x < r[0] + r[2] && p.y >= r[1] && p.y < r[1] + r[3] }
	for st, i in sm.states do if inBox(States_BoxRect(st), local) do hitState = i
	if hitState >= 0 do return
	for t, i in sm.transitions {
		a, b, ok := States_Arrow(sm, t)
		if !ok do continue
		ab := b - a
		k := clamp(((local.x - a.x) * ab.x + (local.y - a.y) * ab.y) / max(ab.x * ab.x + ab.y * ab.y, 1), 0, 1)
		q := a + ab * k - local
		if math.sqrt(q.x * q.x + q.y * q.y) < 6 do hitTransition = i
	}
	return
}

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
		// A right-click: what's under it is selected and its menu opens (context_menus_panels.odin)
		if ctx.input.mouse_pressed[.Right] && inside(rect, m) && inside(visible, m) {
			hitState, hitTransition := States_HitTest(sm, local)
			switch {
			case hitState >= 0:      skald.send(ctx, Msg(SM_View{op = .Select_State, index = hitState}))
			case hitTransition >= 0: skald.send(ctx, Msg(SM_View{op = .Select_Transition, index = hitTransition}))
			}
			skald.send(ctx, Msg(Context_Menu_Opened{at = m, target = Ctx_Graph{graph = .States, item = hitState, sub = hitTransition, local = local}}))
			ctx.input.mouse_pressed[.Right] = false
		}
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

	Box :: struct { rect: [4]f32, name, animation: string, start, selected, current, guarded: bool }
	Arrow :: struct { a, b: [2]f32, label: string, selected, ready: bool }
	Data :: struct {
		boxes: []Box,
		arrows: []Arrow,
		anyState: bool,
		fg, muted, lit, box, line, bg, start, live: skald.Color,
		size: f32,
	}
	// The running game's machine (live): its current state is lit, transitions it would take green
	live := States_Live(s)
	boxes := make([]Box, len(sm.states), context.temp_allocator)
	for st, i in sm.states do boxes[i] = {States_BoxRect(st), strings.clone(st.name, context.temp_allocator), strings.clone(st.animation, context.temp_allocator), st.name == sm.start, i == ed.state, live != nil && live.state == st.name, st.canExit != ""}
	arrows := make([dynamic]Arrow, context.temp_allocator)
	anyState := false
	for t, i in sm.transitions {
		if t.from == "*" do anyState = true
		a, b, ok := States_Arrow(sm, t)
		if !ok do continue
		label := t.condition
		if t.guard != "" do label = fmt.tprintf("%s%s[%s]", label, label == "" ? "" : " ", t.guard)
		if t.after > 0 do label = fmt.tprintf("%s%safter %gs", label, label == "" ? "" : ", ", t.after)
		if t.onFinished do label = fmt.tprintf("%s%sat its end", label, label == "" ? "" : ", ")
		if t.priority != 0 do label = fmt.tprintf("%s%sp%d", label, label == "" ? "" : ", ", t.priority)
		if t.interrupts do label = fmt.tprintf("%s%sinterrupts", label, label == "" ? "" : ", ")
		ready := live != nil && i < len(live.transitions) && live.transitions[i].status == .Ready
		append(&arrows, Arrow{a, b, strings.clone(label, context.temp_allocator), i == ed.transition, ready})
	}
	data := new_clone(Data{boxes, arrows[:], anyState,
		th.color.fg, th.color.fg_muted, th.color.primary, th.color.surface, th.color.border, th.color.bg, th.color.warning, th.color.success, th.font.size_xs}, context.temp_allocator)
	return skald.canvas(ctx, data, proc(d: ^Data, p: skald.Canvas_Painter) {
		o := [2]f32{p.bounds.x, p.bounds.y}
		skald.draw_rect(p.r, p.bounds, d.bg)
		if d.anyState {
			r := ANY_BOX
			skald.draw_rect(p.r, {o.x + r[0], o.y + r[1], r[2], r[3]}, d.box, 10)
			drawTextTop(p.r, "Any state", o.x + r[0] + 10, o.y + r[1] + 5, d.muted, d.size)
		}
		for a in d.arrows {
			color := a.selected ? d.lit : a.ready ? d.live : d.muted
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
			edge := b.selected ? d.lit : b.current ? d.live : b.start ? d.start : d.line
			skald.draw_rect_outline(p.r, r, b.selected || b.start || b.current ? 2 : 1, edge, 6)
			// ★ the start state, ⏵ the one the game is in, ⊘ one with an exit guard
			title := b.start ? fmt.tprintf("%s ★", b.name) : b.name
			if b.guarded do title = fmt.tprintf("%s ⊘", title)
			if b.current do title = fmt.tprintf("▶ %s", title)
			drawTextTop(p.r, title, r.x + 8, r.y + 3, d.fg, d.size)
			if b.animation != "" do drawTextTop(p.r, fmt.tprintf("plays %s", b.animation), r.x + 8, r.y + 17, d.muted, d.size)
		}
	}, id = id, width = width, height = height, cursor = .Pointer)
}
