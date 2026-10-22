package crossfire_editor

import "core:fmt"
import "core:reflect"
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
  renamed is renamed in the conditions (whole words).
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

// The States tab's number fields (number_field.odin): a transition's wait
SMAfterTarget :: struct {}

// A new state machine's: one state, idle
StateMachine_Default :: proc() -> e.StateMachineSettings {
	s := e.StateMachineSettings{start = strings.clone("idle"), target = strings.clone("")}
	s.params = make([dynamic]e.StateMachineParam)
	s.states = make([dynamic]e.StateMachineState)
	s.transitions = make([dynamic]e.StateMachineTransition)
	append(&s.states, e.StateMachineState{name = strings.clone("idle"), animation = strings.clone(""), position = {40, 60}})
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
		append(&sm.states, e.StateMachineState{name = strings.clone(name), animation = strings.clone(""), position = v.position})
		ed.state, ed.transition = len(sm.states) - 1, -1
		if len(sm.states) == 1 do setText(&sm.start, name)
	case .State_Removed:
		if state == nil do break
		name := strings.clone(state.name, context.temp_allocator)
		delete(state.name)
		delete(state.animation)
		ordered_remove(&sm.states, ed.state)
		// Its transitions go with it
		for i := len(sm.transitions) - 1; i >= 0; i -= 1 {
			t := sm.transitions[i]
			if t.from != name && t.to != name do continue
			delete(t.from)
			delete(t.to)
			delete(t.condition)
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
		delete(transition.from)
		delete(transition.to)
		delete(transition.condition)
		ordered_remove(&sm.transitions, ed.transition)
		ed.transition = -1
	case .Transition_Condition:
		if transition != nil do setText(&transition.condition, v.text)
	case .Transition_After:
		if transition != nil do transition.after = max(v.number, 0)
	case .Transition_On_Finished:
		if transition != nil do transition.onFinished = v.flag
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
		for &t in sm.transitions do if strings.contains(t.condition, old) do setText(&t.condition, renameWord(t.condition, old, name))
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
		append(&rows, skald.text("It animates no AnimatedSprite: states' animations do nothing (scripts still read its state).", th.color.fg_muted, th.font.size_xs, max_width = controlWidth + INSPECTOR_LABEL_WIDTH))
	}
	append(&rows, skald.text(fmt.tprintf("%d states, %d transitions, %d parameters", len(sm.states), len(sm.transitions), len(sm.params)), th.color.fg_muted, th.font.size_xs))
	append(&rows, skald.button(ctx, fmt.tprintf("%s  Edit in the States tab", ICON_SITEMAP), Msg(Bottom_Tab_Changed(int(BottomTab.States))),
		id = skald.hash_id(fmt.tprintf("inspector-sm-edit-%d", key)), padding = {th.spacing.sm, 2}, font_size = th.font.size_sm))
	_ = numberWidth
	return rows[:]
}
