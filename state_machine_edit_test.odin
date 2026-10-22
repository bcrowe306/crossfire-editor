package crossfire_editor

import "core:os"
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
