package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"
import e "engine:."

// State machines in the editor: states and transitions added, parameters, renames that follow,
// a dragged state as one step, the target's animations, saved and read back

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
state_machines_in_the_editor :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_states"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	scene := &state.project.scenes[0]
	hero := Scene_InsertNode(scene, "Hero", .AnimatedSprite, -1)
	brain := Scene_InsertNode(scene, "Brain", .StateMachine, hero)
	sm :: proc(state: ^State, i: int) -> ^e.StateMachineSettings { return &state.project.scenes[0].nodes[i].stateMachine }
	testing.expect(t, len(sm(&state, brain).states) == 1 && sm(&state, brain).start == "idle", "a first state")
	// Its target: the parent sprite, with its animation
	testing.expect_value(t, States_Target(scene, brain), hero)
	testing.expect_value(t, States_Animations(&state, scene, brain)[0], "default")

	state.selectedNode = brain
	sendTo(&state, Bottom_Tab_Changed(int(BottomTab.States)))
	_, shown := States_Machine(&state)
	testing.expect_value(t, shown, brain)

	// A second state, a transition, a parameter its condition reads
	sendTo(&state, SM_Changed{op = .State_Added, position = {200, 60}})
	testing.expect_value(t, sm(&state, brain).states[1].name, "state")
	sendTo(&state, SM_Changed{op = .State_Renamed, text = "run"})
	sendTo(&state, SM_Changed{op = .State_Animation, text = "default"})
	sendTo(&state, SM_View{op = .Select_State, index = 0})
	sendTo(&state, SM_Changed{op = .Transition_Added, text = "run"})
	testing.expect_value(t, state.states.transition, 0)
	sendTo(&state, SM_Changed{op = .Param_Added})
	sendTo(&state, SM_Changed{op = .Param_Renamed, index = 0, text = "speed"})
	sendTo(&state, SM_Changed{op = .Transition_Condition, text = "speed > 10"})
	m := sm(&state, brain)
	testing.expect(t, m.transitions[0].from == "idle" && m.transitions[0].to == "run" && m.transitions[0].condition == "speed > 10", "a transition")
	testing.expect_value(t, e.StateMachine_ConditionProblem(m, m.transitions[0].condition), "")
	// Renames follow: the state in transitions and the start, the parameter in conditions
	sendTo(&state, SM_View{op = .Select_State, index = 0})
	sendTo(&state, SM_Changed{op = .State_Renamed, text = "rest"})
	sendTo(&state, SM_Changed{op = .Param_Renamed, index = 0, text = "pace"})
	m = sm(&state, brain)
	testing.expect(t, m.start == "rest" && m.transitions[0].from == "rest" && m.transitions[0].condition == "pace > 10", "renamed everywhere")
	// Any state: from the selected one's menu, "*" makes a transition into it
	sendTo(&state, SM_View{op = .Select_State, index = 1})
	sendTo(&state, SM_Changed{op = .Transition_Added, text = "*"})
	testing.expect(t, sm(&state, brain).transitions[1].from == "*" && sm(&state, brain).transitions[1].to == "run", "from any state")

	// A drag is one step; the Box selected while the graph stays on the machine
	state.selectedNode = hero
	sendTo(&state, SM_View{op = .Select_State, index = 1})
	sendTo(&state, SM_View{op = .Drag_Begin})
	sendTo(&state, SM_Changed{op = .State_Moved, position = {220, 70}})
	sendTo(&state, SM_Changed{op = .State_Moved, position = {300, 90}})
	sendTo(&state, SM_View{op = .Drag_End})
	testing.expect_value(t, sm(&state, brain).states[1].position, [2]f32{300, 90})
	sendTo(&state, Action.Undo)
	testing.expect_value(t, sm(&state, brain).states[1].position, [2]f32{200, 60})
	sendTo(&state, Action.Redo)

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, e.StateMachineSettings_Equal(loaded.scenes[0].nodes[brain].stateMachine, sm(&state, brain)^), "the same machine")

	// Removing a state takes its transitions
	sendTo(&state, SM_View{op = .Select_State, index = 1})
	sendTo(&state, SM_Changed{op = .State_Removed})
	testing.expect(t, len(sm(&state, brain).states) == 1 && len(sm(&state, brain).transitions) == 0, "removed with its transitions")
}

@(private="file")
GUARDS_SOURCE :: `package scripts

import e "engine:."

Hero :: struct {
	using script: e.Script,
	stamina: f32,
}

@(init)
register_hero_guards :: proc "contextless" () {
	e.StateMachine_RegisterGuard("can_attack", proc(sm: ^e.StateMachine) -> bool { return true })
}

Hero_ready :: proc(self: ^Hero, brain: ^e.StateMachine) {
	e.StateMachine_SetGuard(brain, "has_stamina", proc(self: ^Hero) -> bool { return self.stamina > 1 }, self)
}
`

// Transition logic in the editor: a transition's clauses built in rows (added, changed, negated,
// any of), its guard, priority, interrupts; a state's exit guard, speed, loop and events; code
// guards from the script index; renames into guards and exit guards; undo; saved and read back
@(test)
state_machine_guards_in_the_editor :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_state_guards"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	scene := &state.project.scenes[0]
	hero := Scene_InsertNode(scene, "Hero", .AnimatedSprite, -1)
	brain := Scene_InsertNode(scene, "Brain", .StateMachine, hero)
	sm :: proc(state: ^State, i: int) -> ^e.StateMachineSettings { return &state.project.scenes[0].nodes[i].stateMachine }
	state.selectedNode = brain
	sendTo(&state, Bottom_Tab_Changed(int(BottomTab.States)))
	sendTo(&state, SM_Changed{op = .Param_Added})
	sendTo(&state, SM_Changed{op = .Param_Renamed, index = 0, text = "speed"})
	sendTo(&state, SM_Changed{op = .Param_Added})
	sendTo(&state, SM_Changed{op = .Param_Renamed, index = 1, text = "grounded"})
	sendTo(&state, SM_Changed{op = .Param_Kind, index = 1, text = "Bool"})
	sendTo(&state, SM_Changed{op = .State_Added, position = {200, 60}})
	testing.expect_value(t, sm(&state, brain).states[1].speed, f32(1))
	sendTo(&state, SM_View{op = .Select_State, index = 0})
	sendTo(&state, SM_Changed{op = .Transition_Added, text = "state"})

	// Clauses: the first parameter (a Float compares), a Bool, negated, any of
	sendTo(&state, SM_Changed{op = .Clause_Added, condition = .When})
	testing.expect_value(t, sm(&state, brain).transitions[0].condition, "speed > 0")
	sendTo(&state, SM_Changed{op = .Clause_Changed, condition = .When, index = 0, part = .Value, text = "10"})
	sendTo(&state, SM_Changed{op = .Clause_Changed, condition = .When, index = 0, part = .Op, text = ">="})
	sendTo(&state, SM_Changed{op = .Clause_Added, condition = .When, text = "grounded"})
	sendTo(&state, SM_Changed{op = .Clause_Changed, condition = .When, index = 1, part = .Negated, text = "true"})
	testing.expect_value(t, sm(&state, brain).transitions[0].condition, "speed >= 10 and !grounded")
	sendTo(&state, SM_Changed{op = .Clause_Mode, condition = .When, flag = true})
	testing.expect_value(t, sm(&state, brain).transitions[0].condition, "speed >= 10 or !grounded")
	sendTo(&state, SM_Changed{op = .Clause_Changed, condition = .When, index = 1, part = .Op, text = "=="})
	testing.expect_value(t, sm(&state, brain).transitions[0].condition, "speed >= 10 or !grounded == 0")
	sendTo(&state, SM_Changed{op = .Clause_Changed, condition = .When, index = 1, part = .Op, text = CLAUSE_IS_TRUE})
	sendTo(&state, SM_Changed{op = .Clause_Removed, condition = .When, index = 1})
	testing.expect_value(t, sm(&state, brain).transitions[0].condition, "speed >= 10")
	// A value that isn't a clause's is refused (the text stays)
	sendTo(&state, SM_Changed{op = .Clause_Changed, condition = .When, index = 0, part = .Name, text = "two words"})
	testing.expect_value(t, sm(&state, brain).transitions[0].condition, "speed >= 10")
	// Not flat: the rows don't edit it, the text does
	sendTo(&state, SM_Changed{op = .Transition_Condition, text = "(speed > 1 or grounded) and speed < 5"})
	sendTo(&state, SM_Changed{op = .Clause_Removed, condition = .When, index = 0})
	testing.expect_value(t, sm(&state, brain).transitions[0].condition, "(speed > 1 or grounded) and speed < 5")

	// Code guards: from the script index, no build
	f := ScriptIndex_ParseSource(joinPath(root, "scripts", "hero.odin", allocator = context.temp_allocator), GUARDS_SOURCE)
	ScriptIndex_Take(&state.scriptIndex, {f})
	guards := States_GuardNames(&state)
	testing.expect(t, len(guards) == 2 && guards[0] == "can_attack" && guards[1] == "has_stamina", "the scripts' guards")
	sendTo(&state, SM_Changed{op = .Clause_Added, condition = .Guard, text = "can_attack()"})
	sendTo(&state, SM_Changed{op = .Clause_Added, condition = .Guard, text = "grounded"})
	m := sm(&state, brain)
	testing.expect_value(t, m.transitions[0].guard, "can_attack() and grounded")
	testing.expect_value(t, e.StateMachine_ConditionProblem(m, m.transitions[0].guard, guards, checkGuards = true), "")
	testing.expect(t, e.StateMachine_ConditionProblem(m, "nope()", guards, checkGuards = true) != "", "an unknown guard")
	sendTo(&state, SM_Changed{op = .Transition_Priority, number = 3})
	sendTo(&state, SM_Changed{op = .Transition_Interrupts, flag = true})
	testing.expect(t, sm(&state, brain).transitions[0].priority == 3 && sm(&state, brain).transitions[0].interrupts, "priority, interrupts")

	// A state's exit guard, speed, loop, events
	sendTo(&state, SM_View{op = .Select_State, index = 0})
	sendTo(&state, SM_Changed{op = .Clause_Added, condition = .Exit, text = "has_stamina()"})
	sendTo(&state, SM_Changed{op = .Clause_Changed, condition = .Exit, index = 0, part = .Negated, text = "true"})
	sendTo(&state, SM_Changed{op = .State_Speed, number = 1.5})
	sendTo(&state, SM_Changed{op = .State_Loop, text = "Once"})
	sendTo(&state, SM_Changed{op = .State_Enter_Event, text = " swing "})
	sendTo(&state, SM_Changed{op = .State_Exit_Event, text = "sheathe"})
	st := sm(&state, brain).states[0]
	testing.expect(t, st.canExit == "!has_stamina()" && st.speed == 1.5 && st.loop == .Once && st.enterEvent == "swing" && st.exitEvent == "sheathe", "a state's settings")
	// Undo: one step each
	sendTo(&state, Action.Undo)
	testing.expect_value(t, sm(&state, brain).states[0].exitEvent, "")
	sendTo(&state, Action.Undo)
	sendTo(&state, Action.Undo)
	testing.expect_value(t, sm(&state, brain).states[0].loop, e.AnimationLoopRule.As_Made)
	sendTo(&state, Action.Redo)
	sendTo(&state, Action.Redo)
	sendTo(&state, Action.Redo)
	testing.expect_value(t, sm(&state, brain).states[0].exitEvent, "sheathe")

	// A parameter renamed: into conditions, guards and exit guards
	sendTo(&state, SM_Changed{op = .Param_Renamed, index = 1, text = "onFloor"})
	sendTo(&state, SM_Changed{op = .State_Can_Exit, text = "onFloor and !has_stamina()"})
	sendTo(&state, SM_Changed{op = .Param_Renamed, index = 1, text = "floor"})
	m = sm(&state, brain)
	testing.expect_value(t, m.transitions[0].guard, "can_attack() and floor")
	testing.expect_value(t, m.states[0].canExit, "floor and !has_stamina()")

	// Saved and read back: the same machine
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, e.StateMachineSettings_Equal(loaded.scenes[0].nodes[brain].stateMachine, sm(&state, brain)^), "the same machine")

	// Removing the transition and the state frees their strings (the test's allocator checks)
	sendTo(&state, SM_View{op = .Select_Transition, index = 0})
	sendTo(&state, SM_Changed{op = .Transition_Removed})
	sendTo(&state, SM_View{op = .Select_State, index = 1})
	sendTo(&state, SM_Changed{op = .State_Removed})
	testing.expect(t, len(sm(&state, brain).states) == 1 && len(sm(&state, brain).transitions) == 0, "removed")
}

// The live link's machine reply: parsed into LiveView.machine for the watched node only
@(test)
state_machines_live_in_the_editor :: proc(t: ^testing.T) {
	state := State{settings = Settings_Default(), states = {node = -1, state = -1, transition = -1}}
	defer State_Destroy(&state)
	state.live.machineWatch = strings.clone("abc")
	Live_Ingest(&state, `{"type":"machine","id":"other","state":"run","previous":"","time":1,"canExit":true,"exit":[],"params":[],"transitions":[]}`)
	testing.expect_value(t, state.live.machine.state, "")
	Live_Ingest(&state, `{"type":"machine","id":"abc","state":"attack","previous":"idle","time":0.5,"canExit":false,"exit":[false],"params":[{"name":"speed","value":"3"}],"transitions":[{"status":"Exit_Blocked","when":[true],"guard":[]},{"status":"Ready","when":[],"guard":[true,false]}]}`)
	m := &state.live.machine
	testing.expect(t, m.state == "attack" && m.previous == "idle" && !m.canExit && len(m.exit) == 1, "the state")
	testing.expect(t, len(m.transitions) == 2 && m.transitions[0].status == .Exit_Blocked && m.transitions[1].status == .Ready, "statuses")
	testing.expect(t, len(m.transitions[1].guard) == 2 && !m.transitions[1].guard[1], "guard clauses")
	testing.expect(t, len(m.params) == 1 && m.params[0].value == "3", "parameters")
	// A second reply replaces the first (the allocator checks it's freed)
	Live_Ingest(&state, `{"type":"machine","id":"abc","state":"idle","previous":"attack","time":0,"canExit":true,"exit":[],"params":[],"transitions":[]}`)
	testing.expect_value(t, state.live.machine.state, "idle")
}
