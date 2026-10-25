package crossfire_editor

import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
State machines in the editor (the engine's state_machine.odin): StateMachine nodes, edited as a
graph in the bottom panel's **States** tab (view_states.odin) and in the inspector.

- **Data:** `NodeDef.stateMachine` is the engine's `e.StateMachineSettings` (owned: its Clone /
  Destroy / Equal). Written as `<param>`, `<state>` (with its graph position) and `<transition>`
  children.
- **Which machine:** like the Timeline, the selected StateMachine, kept while other nodes are
  selected (`StatesEditor.node`, `States_Follow`).
- **Messages:** `SM_Changed{op, ...}` edits (node steps on the machine; dragging a state is one
  sticky step, typing merges), `SM_View{op, ...}` the tab's selection and drags.
- **Renames** follow: a state renamed is renamed in the transitions and the start; a parameter
  renamed is renamed in the conditions, guards and exit guards (whole words).
- **Conditions** (a transition's `condition` and `guard`, a state's `canExit`) are text; the
  sidebar's rows edit flat ones through the engine's `StateMachine_SplitCondition` /
  `JoinCondition` (`Clause_*` ops: the text is split, the clause changed, joined again), and the
  text field edits any.
- **Code guards** are the scripts' `e.StateMachine_RegisterGuard("name", ...)` and
  `e.StateMachine_SetGuard(sm, "name", ...)` calls, read from the script index
  (`States_GuardNames`: no build needed).
- **Live:** while a game runs, the shown machine's running node (`States_LiveTarget`) is watched
  over the live link (`machine <id>`, `States_LiveFrame`), and the sidebar shows which clauses
  hold, which guard blocks (`LiveView.machine`).
*/

// The States tab's own state (not undone)
StatesEditor :: struct {
	// The StateMachine shown: its scene and node index (-1: none)
	scene, node: int,
	// The selected state and transition (-1: none; one at a time)
	state, transition: int,
	// A state is being dragged, from where the pointer grabbed it (its offset in the box)
	dragging: bool,
	grab: [2]f32,
}

// What an `SM_Changed` edits
SMOp :: enum {
	State_Added,
	State_Removed,
	State_Renamed,
	State_Animation,
	// Dragging a state: `position`; sticky, one step per drag
	State_Moved,
	Start_Set,
	Target_Set,
	// From the selected state to `text` ("*": from any state, to the selected one)
	Transition_Added,
	Transition_Removed,
	Transition_Condition,
	Transition_After,
	Transition_On_Finished,
	// A transition's guard (`text`), priority (`number`), whether it interrupts (`flag`)
	Transition_Guard,
	Transition_Priority,
	Transition_Interrupts,
	// A state's exit guard (`text`), speed (`number`), loop (`text`: an AnimationLoopRule's name),
	// enter and exit events (`text`)
	State_Can_Exit,
	State_Speed,
	State_Loop,
	State_Enter_Event,
	State_Exit_Event,
	// A clause of the selected item's `condition` (When, Guard, Exit): added (`text`: its name, ""
	// the first parameter), removed and changed (`index`, `part`, `text`); `flag` joins them by
	// `or` (Clause_Mode)
	Clause_Added,
	Clause_Removed,
	Clause_Changed,
	Clause_Mode,
	Param_Added,
	Param_Removed,
	Param_Renamed,
	Param_Kind,
	Param_Value,
}

// An edit of the shown StateMachine
SM_Changed :: struct {
	op: SMOp,
	// The parameter it's about (Param_*)
	index: int,
	text: string,
	number: f32,
	flag: bool,
	position: [2]f32,
	// Which condition a Clause_* op edits, and which part of the clause
	condition: SMCondition,
	part: SMClausePart,
}

// The conditions the sidebar edits: the selected transition's condition and guard, the selected
// state's exit guard
SMCondition :: enum {
	When,
	Guard,
	Exit,
}

// A clause's parts (`SM_Changed.part`): what it reads (a parameter, or a code guard as
// "name()"), its comparison, its value, whether it's negated (`text` "true" / "false")
SMClausePart :: enum {
	Name,
	Op,
	Value,
	Negated,
}

// What an `SM_View` changes
SMViewOp :: enum {
	Select_State,
	Select_Transition,
	Drag_Begin,
	Drag_End,
}

// A change to the States tab only
SM_View :: struct {
	op: SMViewOp,
	index: int,
	grab: [2]f32,
}

// The States tab's number fields (number_field.odin): a transition's wait and priority, a
// state's speed
SMNumberTarget :: enum {
	After,
	Priority,
	Speed,
}

// A new state machine's: one state, idle
StateMachine_Default :: proc() -> e.StateMachineSettings {
	s := e.StateMachineSettings{start = strings.clone("idle"), target = strings.clone("")}
	s.params = make([dynamic]e.StateMachineParam)
	s.states = make([dynamic]e.StateMachineState)
	s.transitions = make([dynamic]e.StateMachineTransition)
	append(&s.states, e.StateMachineState{name = strings.clone("idle"), animation = strings.clone(""), position = {40, 60}, speed = 1})
	return s
}

/*
The StateMachine the States tab shows: the stored one when it's still one of the open scene.
*/
States_Machine :: proc(s: ^State) -> (^NodeDef, int) {
	ed := &s.states
	if ed.scene != s.currentScene || s.currentScene < 0 || s.currentScene >= len(s.project.scenes) do return nil, -1
	scene := &s.project.scenes[s.currentScene]
	if ed.node < 0 || ed.node >= len(scene.nodes) || scene.nodes[ed.node].kind != .StateMachine do return nil, -1
	return &scene.nodes[ed.node], ed.node
}

/*
Keeps the States tab on the selected StateMachine, its selection in range (after every message).
*/
States_Follow :: proc(s: ^State) {
	ed := &s.states
	if s.currentScene >= 0 && s.currentScene < len(s.project.scenes) {
		scene := &s.project.scenes[s.currentScene]
		if s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) && scene.nodes[s.selectedNode].kind == .StateMachine {
			if ed.node != s.selectedNode || ed.scene != s.currentScene {
				ed.node, ed.scene = s.selectedNode, s.currentScene
				ed.state, ed.transition = -1, -1
			}
		}
	}
	node, _ := States_Machine(s)
	if node == nil do return
	sm := &node.stateMachine
	if ed.state >= len(sm.states) do ed.state = -1
	if ed.transition >= len(sm.transitions) do ed.transition = -1
}

/*
The node a path leads to from another, as the engine's `Node_FindPath` reads it ("." itself,
".." its parent, a leading "/" from the top level).

Returns:
- Its index, or -1
*/
Scene_ResolvePath :: proc(scene: ^SceneDef, from: int, path: string) -> int {
	path := strings.trim_space(path)
	if path == "" do return -1
	at := from
	atRoot := false
	if path[0] == '/' {
		at, atRoot = -1, true
		path = path[1:]
	}
	rest := path
	for part in strings.split_iterator(&rest, "/") {
		switch part {
		case "", ".":
			continue
		case "..":
			if atRoot do return -1
			at = scene.nodes[at].parent
			atRoot = at < 0
		case:
			next := -1
			for n, i in scene.nodes do if n.parent == at && n.name == part {
				next = i
				break
			}
			if next < 0 do return -1
			at, atRoot = next, false
		}
	}
	return atRoot ? -1 : at
}

/*
The AnimatedSprite a StateMachine animates (its `target` path, "" its parent), or -1.
*/
States_Target :: proc(scene: ^SceneDef, machine: int) -> int {
	node := &scene.nodes[machine]
	t := node.stateMachine.target == "" ? node.parent : Scene_ResolvePath(scene, machine, node.stateMachine.target)
	if t < 0 || scene.nodes[t].kind != .AnimatedSprite do return -1
	return t
}

/*
The animations a StateMachine's states can play: its target's (its own, or its animation set's).
*/
States_Animations :: proc(s: ^State, scene: ^SceneDef, machine: int) -> []string {
	list := make([dynamic]string, context.temp_allocator)
	t := States_Target(scene, machine)
	if t < 0 do return nil
	target := &scene.nodes[t]
	animations := target.animations[:]
	if target.animationSet != "" {
		animations = nil
		if i := Project_FindAnimationSet(&s.project, target.animationSet); i >= 0 {
			animations = s.project.animationSets[i].animations[:]
		} else if set := AsepriteEdit_AnimationSet(s.project.rootPath, target.animationSet); set != nil {
			animations = set.animations[:]
		}
	}
	for a in animations do append(&list, a.name)
	return list[:]
}

/*
Handles the States tab's messages.

Returns:
- Whether the message was this file's
*/
States_Update :: proc(s: ^State, m: Msg) -> bool {
	ed := &s.states
	#partial switch v in m {
	case SM_View:
		switch v.op {
		case .Select_State: ed.state, ed.transition = v.index, -1
		case .Select_Transition: ed.transition, ed.state = v.index, -1
		case .Drag_Begin:
			ed.dragging = true
			ed.grab = v.grab
			s.history.gesture += 1
		case .Drag_End: ed.dragging = false
		}
	case SM_Changed:
		statesEdit(s, v)
	case States_Live_Watch:
		if string(v) == s.live.machineWatch do break
		Live_Send(s, fmt.tprintf("machine %s", string(v)))
		delete(s.live.machineWatch)
		s.live.machineWatch = strings.clone(string(v))
		LiveMachine_Clear(&s.live.machine)
	case:
		return false
	}
	return true
}

@(private="file")
statesEdit :: proc(s: ^State, v: SM_Changed) {
	ed := &s.states
	node, _ := States_Machine(s)
	if node == nil do return
	sm := &node.stateMachine
	setText :: proc(to: ^string, text: string) {
		delete(to^)
		to^ = strings.clone(text)
	}
	state: ^e.StateMachineState
	if ed.state >= 0 && ed.state < len(sm.states) do state = &sm.states[ed.state]
	transition: ^e.StateMachineTransition
	if ed.transition >= 0 && ed.transition < len(sm.transitions) do transition = &sm.transitions[ed.transition]
	param: ^e.StateMachineParam
	if v.index >= 0 && v.index < len(sm.params) do param = &sm.params[v.index]
	switch v.op {
	case .State_Added:
		name := uniqueName(sm, "state")
		append(&sm.states, e.StateMachineState{name = strings.clone(name), animation = strings.clone(""), position = v.position, speed = 1})
		ed.state, ed.transition = len(sm.states) - 1, -1
		if len(sm.states) == 1 do setText(&sm.start, name)
	case .State_Removed:
		if state == nil do break
		name := strings.clone(state.name, context.temp_allocator)
		e.StateMachineState_Destroy(state)
		ordered_remove(&sm.states, ed.state)
		// Its transitions go with it
		for i := len(sm.transitions) - 1; i >= 0; i -= 1 {
			t := &sm.transitions[i]
			if t.from != name && t.to != name do continue
			e.StateMachineTransition_Destroy(t)
			ordered_remove(&sm.transitions, i)
		}
		if sm.start == name do setText(&sm.start, len(sm.states) > 0 ? sm.states[0].name : "")
		ed.state = -1
	case .State_Renamed:
		if state == nil do break
		name := strings.trim_space(v.text)
		if name == "" || name == "*" || name == state.name do break
		for st in sm.states do if st.name == name do return
		old := strings.clone(state.name, context.temp_allocator)
		setText(&state.name, name)
		for &t in sm.transitions {
			if t.from == old do setText(&t.from, name)
			if t.to == old do setText(&t.to, name)
		}
		if sm.start == old do setText(&sm.start, name)
	case .State_Animation:
		if state != nil do setText(&state.animation, v.text == ANIMATION_NONE ? "" : v.text)
	case .State_Moved:
		if state != nil do state.position = {max(v.position.x, 0), max(v.position.y, 0)}
	case .Start_Set:
		setText(&sm.start, v.text)
	case .Target_Set:
		setText(&sm.target, v.text == TARGET_PARENT ? "" : v.text)
	case .Transition_Added:
		if state == nil do break
		from, to := state.name, v.text
		if v.text == "*" do from, to = "*", state.name
		append(&sm.transitions, e.StateMachineTransition{from = strings.clone(from), to = strings.clone(to), condition = strings.clone("")})
		ed.transition, ed.state = len(sm.transitions) - 1, -1
	case .Transition_Removed:
		if transition == nil do break
		e.StateMachineTransition_Destroy(transition)
		ordered_remove(&sm.transitions, ed.transition)
		ed.transition = -1
	case .Transition_Condition:
		if transition != nil do setText(&transition.condition, v.text)
	case .Transition_After:
		if transition != nil do transition.after = max(v.number, 0)
	case .Transition_On_Finished:
		if transition != nil do transition.onFinished = v.flag
	case .Transition_Guard:
		if transition != nil do setText(&transition.guard, v.text)
	case .Transition_Priority:
		if transition != nil do transition.priority = int(clamp(v.number, -1000, 1000))
	case .Transition_Interrupts:
		if transition != nil do transition.interrupts = v.flag
	case .State_Can_Exit:
		if state != nil do setText(&state.canExit, v.text)
	case .State_Speed:
		if state != nil do state.speed = clamp(v.number, 0.01, 100)
	case .State_Loop:
		if state == nil do break
		if rule, ok := reflect.enum_from_name(e.AnimationLoopRule, v.text); ok do state.loop = rule
	case .State_Enter_Event:
		if state != nil do setText(&state.enterEvent, strings.trim_space(v.text))
	case .State_Exit_Event:
		if state != nil do setText(&state.exitEvent, strings.trim_space(v.text))
	case .Clause_Added, .Clause_Removed, .Clause_Changed, .Clause_Mode:
		text := States_ConditionText(sm, ed, v.condition)
		if text == nil do break
		if edited, ok := States_EditClause(sm, text^, v); ok do setText(text, edited)
	case .Param_Added:
		name := "param"
		for n := 2; ; n += 1 {
			taken := false
			for p in sm.params do if p.name == name do taken = true
			if !taken do break
			name = fmt.tprintf("param%d", n)
		}
		append(&sm.params, e.StateMachineParam{name = strings.clone(name), kind = .Float, value = strings.clone("0")})
	case .Param_Removed:
		if param == nil do break
		delete(param.name)
		delete(param.value)
		ordered_remove(&sm.params, v.index)
	case .Param_Renamed:
		if param == nil do break
		name := strings.trim_space(v.text)
		if name == "" || strings.contains_any(name, " <>=!&") do break
		for p in sm.params do if p.name == name do return
		old := strings.clone(param.name, context.temp_allocator)
		setText(&param.name, name)
		for &t in sm.transitions {
			if strings.contains(t.condition, old) do setText(&t.condition, renameWord(t.condition, old, name))
			if strings.contains(t.guard, old) do setText(&t.guard, renameWord(t.guard, old, name))
		}
		for &st in sm.states do if strings.contains(st.canExit, old) do setText(&st.canExit, renameWord(st.canExit, old, name))
	case .Param_Kind:
		if param == nil do break
		if k, ok := reflect.enum_from_name(e.StateMachineParamKind, v.text); ok {
			param.kind = k
			setText(&param.value, k == .Float ? "0" : "false")
		}
	case .Param_Value:
		if param != nil do setText(&param.value, strings.trim_space(v.text))
	}
}

/*
The condition text a Clause_* op edits: the selected transition's condition or guard, the
selected state's exit guard (nil when that isn't selected).
*/
States_ConditionText :: proc(sm: ^e.StateMachineSettings, ed: ^StatesEditor, which: SMCondition) -> ^string {
	switch which {
	case .When, .Guard:
		if ed.transition < 0 || ed.transition >= len(sm.transitions) do return nil
		return which == .When ? &sm.transitions[ed.transition].condition : &sm.transitions[ed.transition].guard
	case .Exit:
		if ed.state < 0 || ed.state >= len(sm.states) do return nil
		return &sm.states[ed.state].canExit
	}
	return nil
}

/*
A clause edit applied to a flat condition (`SM_Changed`'s Clause_* ops): split, changed, joined.

Returns:
- The new condition (temp allocated), and false when it isn't flat or the edit doesn't apply
*/
States_EditClause :: proc(sm: ^e.StateMachineSettings, text: string, v: SM_Changed) -> (string, bool) {
	list, any, flat := e.StateMachine_SplitCondition(text, context.temp_allocator)
	if !flat do return "", false
	clauses := make([dynamic]e.StateMachineClause, context.temp_allocator)
	append(&clauses, ..list)
	#partial switch v.op {
	case .Clause_Added:
		name := strings.trim_space(v.text)
		if name == "" && len(sm.params) > 0 do name = sm.params[0].name
		if name == "" do return "", false
		c := e.StateMachineClause{}
		c.name, c.guard = clauseName(name)
		// A Float compares by default; a Bool or Trigger is true or set
		if !c.guard do for p in sm.params do if p.name == c.name && p.kind == .Float do c.op, c.value = ">", "0"
		append(&clauses, c)
	case .Clause_Removed:
		if v.index < 0 || v.index >= len(clauses) do return "", false
		ordered_remove(&clauses, v.index)
	case .Clause_Mode:
		any = v.flag
	case .Clause_Changed:
		if v.index < 0 || v.index >= len(clauses) do return "", false
		c := &clauses[v.index]
		switch v.part {
		case .Name:
			c.name, c.guard = clauseName(strings.trim_space(v.text))
			if c.guard do c.op, c.value = "", ""
		case .Op:
			c.op = v.text == CLAUSE_IS_TRUE ? "" : v.text
			if c.op != "" && c.value == "" do c.value = "0"
		case .Value:
			value := strings.trim_space(v.text)
			if value == "" do return "", false
			c.value = value
		case .Negated:
			c.negated = v.text == "true"
		}
		if c.name == "" || strings.contains_any(c.name, " <>=!&|()") do return "", false
	case:
		return "", false
	}
	return e.StateMachine_JoinCondition(clauses[:], any, context.temp_allocator), true
}

// A clause row's name: a parameter, or a code guard written "name()"
@(private="file")
clauseName :: proc(text: string) -> (name: string, guard: bool) {
	return strings.trim_suffix(text, "()"), strings.has_suffix(text, "()")
}

// The comparison choice for "the parameter is true / set / not 0"
CLAUSE_IS_TRUE :: "is true"

/*
The code guards the project's scripts provide: the names given to `e.StateMachine_RegisterGuard`
and `e.StateMachine_SetGuard` in their source (the script index: no build needed), sorted.

Returns:
- The names (temp allocated)
*/
States_GuardNames :: proc(s: ^State) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for _, f in s.scriptIndex.files {
		for c in f.calls {
			registered := c.procName == "StateMachine_RegisterGuard" && (c.argument == 0 || c.argName == "name")
			own := c.procName == "StateMachine_SetGuard" && (c.argument == 1 || c.argName == "name")
			if (registered || own) && c.value != "" && !slice.contains(out[:], c.value) do append(&out, c.value)
		}
	}
	slice.sort(out[:])
	return out[:]
}

/*
The running node the States tab's machine is (the live tree's index, -1: none): the Live tab's
chosen node when it's a StateMachine of that name, else the one at the machine's path in the
running scene, else (a component's machine, or another scene's) the first StateMachine of that
name whose path ends with the machine's path below its top node.
*/
States_LiveTarget :: proc(s: ^State) -> int {
	node, index := States_Machine(s)
	if node == nil || !s.live.connected || s.play.stdin == nil do return -1
	scene := &s.project.scenes[s.currentScene]
	live := &s.live
	for n, i in live.nodes do if n.id == live.selected && n.type == "StateMachine" && n.name == node.name do return i
	path := Scene_NodePath(scene, -1, index, context.temp_allocator)
	if scene.name == live.scene {
		for _, i in live.nodes do if CodeLive_NodePath(live, i) == path do return i
	}
	// Below its top node: "/Hero/Brain" -> "/Brain"
	tail := path
	if len(path) > 1 do if cut := strings.index_byte(path[1:], '/'); cut >= 0 do tail = path[cut + 1:]
	for n, i in live.nodes {
		if n.type != "StateMachine" || n.name != node.name do continue
		if strings.has_suffix(CodeLive_NodePath(live, i), tail) do return i
	}
	return -1
}

/*
Watches the States tab's machine in the running game (every `view`): sends `States_Live_Watch`
when the node to watch changed (none: the watch stops).
*/
States_LiveFrame :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) {
	id := ""
	if s.bottomTab == .States && s.mode == .Scene {
		if i := States_LiveTarget(s); i >= 0 do id = s.live.nodes[i].id
	}
	if id != s.live.machineWatch do skald.send(ctx, Msg(States_Live_Watch(strings.clone(id, context.temp_allocator))))
}

// The States tab's machine to watch in the running game (its live node's id, "": none)
States_Live_Watch :: distinct string

// A name no state has ("state", "state2"...)
@(private="file")
uniqueName :: proc(sm: ^e.StateMachineSettings, base: string) -> string {
	for n := 1; ; n += 1 {
		name := n == 1 ? base : fmt.tprintf("%s%d", base, n)
		taken := false
		for st in sm.states do if st.name == name do taken = true
		if !taken do return name
	}
}

// `text` with the word `old` (not part of a longer name) replaced by `new` (temp allocated)
@(private="file")
renameWord :: proc(text, old, new: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	isName :: proc(c: u8) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') }
	i := 0
	for i < len(text) {
		if strings.has_prefix(text[i:], old) && (i == 0 || !isName(text[i - 1])) && (i + len(old) >= len(text) || !isName(text[i + len(old)])) {
			strings.write_string(&b, new)
			i += len(old)
			continue
		}
		strings.write_byte(&b, text[i])
		i += 1
	}
	return strings.to_string(b)
}

// The animation choice for none
ANIMATION_NONE :: "(none)"
// The target choice for the machine's parent
TARGET_PARENT :: "(its parent)"

/*
The inspector's rows for a StateMachine: its start state, the sprite it animates, a summary and
the States tab.
*/
stateMachineInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	sm := &node.stateMachine
	scene := &s.project.scenes[s.currentScene]
	states := make([dynamic]string, context.temp_allocator)
	for st in sm.states do append(&states, st.name)
	if len(states) > 0 {
		append(&rows, inspectorRow(ctx, "Starts in", skald.select(ctx, sm.start, states[:], proc(v: string) -> Msg { return SM_Changed{op = .Start_Set, text = v} },
			id = skald.hash_id(fmt.tprintf("inspector-sm-start-%d", key)), width = controlWidth)))
	}
	targets := make([dynamic]string, context.temp_allocator)
	append(&targets, TARGET_PARENT)
	for n, i in scene.nodes do if n.kind == .AnimatedSprite do append(&targets, Scene_NodePath(scene, key, i, context.temp_allocator))
	append(&rows, inspectorRow(ctx, "Animates", skald.select(ctx, sm.target == "" ? TARGET_PARENT : sm.target, targets[:], proc(v: string) -> Msg { return SM_Changed{op = .Target_Set, text = v} },
		id = skald.hash_id(fmt.tprintf("inspector-sm-target-%d", key)), width = controlWidth)))
	if States_Target(scene, key) < 0 {
		append(&rows, uiText(th, .Muted, "It animates no AnimatedSprite: states' animations do nothing (scripts still read its state).", max_width = inspectorRowWidth(controlWidth)))
	}
	append(&rows, uiText(th, .Muted, fmt.tprintf("%d states, %d transitions, %d parameters", len(sm.states), len(sm.transitions), len(sm.params))))
	append(&rows, skald.button(ctx, fmt.tprintf("%s  Edit in the States tab", ICON_SITEMAP), Msg(Bottom_Tab_Changed(int(BottomTab.States))),
		id = skald.hash_id(fmt.tprintf("inspector-sm-edit-%d", key)), padding = tk.fieldPadding, font_size = th.font.size_sm))
	_ = numberWidth
	return rows[:]
}
