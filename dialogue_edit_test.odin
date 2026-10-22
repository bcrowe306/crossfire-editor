package crossfire_editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import e "engine:."

// Dialogues in the editor (dialogue_edit.odin): made, edited in the Dialogue tab's messages,
// undone, saved and read back, a Yarn file imported, a DialogueBox set up and shown in the viewport

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(private="file")
freshState :: proc(dir: string) -> State {
	os.make_directory("build")
	removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1,
		materialSelection = -1, atlasSelection = -1, trace = DEFAULT_TRACE_SETTINGS, busSelection = -1}
	state.settings.builtInCodeEditor = false
	testing.expect_value(nil, Project_Save(&state.project), "")
	return state
}

@(test)
dialogues_in_the_editor :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	dir := "build/test_dialogue_edit"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	root := state.project.rootPath

	// New Dialogue: a file, shown in the Dialogue tab, a Start node with a line
	sendTo(&state, Dialogue_Created{})
	testing.expect_value(t, len(state.project.dialogues), 1)
	def := Dialogue_Shown(&state)
	testing.expect(t, def != nil && def.path == "dialogues/dialogue.dialogue.xml", "shown")
	testing.expect(t, os.exists(joinPath(root, def.path, allocator = context.temp_allocator)), "its file")
	testing.expect_value(t, state.bottomTab, BottomTab.Dialogue)
	data := &Dialogue_Shown(&state).data
	testing.expect(t, len(data.nodes) == 1 && data.start == "Start", "a start node")

	// A second node, renamed (what names it follows); options to it
	sendTo(&state, Dialogue_Changed{op = .Node_Added, position = {200, 20}})
	testing.expect_value(t, state.dialogue.node, 1)
	sendTo(&state, Dialogue_View{op = .Select_Node, index = 0})
	sendTo(&state, Dialogue_Changed{op = .Step_Added, kind = .Options})
	sendTo(&state, Dialogue_Changed{op = .Option_Field, step = 1, option = 0, field = .Target, text = "Node"})
	sendTo(&state, Dialogue_Changed{op = .Option_Field, step = 1, option = 0, field = .Condition, text = "$gold >= 5"})
	sendTo(&state, Dialogue_Changed{op = .Step_Field, step = 0, field = .Text, text = "You have {$gold} gold."})
	data = &Dialogue_Shown(&state).data
	testing.expect_value(t, len(data.nodes[0].steps), 2)
	testing.expect_value(t, data.nodes[0].steps[1].options[0].target, "Node")
	sendTo(&state, Dialogue_View{op = .Select_Node, index = 1})
	sendTo(&state, Dialogue_Changed{op = .Node_Renamed, text = "Shop"})
	data = &Dialogue_Shown(&state).data
	testing.expect_value(t, data.nodes[1].name, "Shop")
	testing.expect_value(t, data.nodes[0].steps[1].options[0].target, "Shop")
	sendTo(&state, Dialogue_Changed{op = .Step_Added, kind = .Set})
	sendTo(&state, Dialogue_Changed{op = .Step_Added, kind = .Line})
	sendTo(&state, Dialogue_Changed{op = .Step_Moved, step = 1, delta = -1})
	data = &Dialogue_Shown(&state).data
	testing.expect(t, data.nodes[1].steps[0].kind == .Line && data.nodes[1].steps[1].kind == .Set, "moved up")
	// Undo and redo (project steps)
	sendTo(&state, Action.Undo)
	data = &Dialogue_Shown(&state).data
	testing.expect(t, data.nodes[1].steps[0].kind == .Set, "undone")
	sendTo(&state, Action.Redo)

	// Played by the engine the way it's edited: the options' condition holds with gold
	runner: e.DialogueRunner
	defer e.DialogueRunner_Destroy(&runner)
	e.Dialogue_SetVariable(&runner, "$gold", f64(9))
	data = &Dialogue_Shown(&state).data
	e.Dialogue_Start(&runner, data)
	testing.expect_value(t, runner.text, "You have 9 gold.")
	e.Dialogue_Continue(&runner)
	testing.expect_value(t, runner.state, e.DialogueState.Options)

	// A Yarn file imported: a dialogue asset of its nodes
	yarn := "title: Start\n---\nGuide: Hi.\n-> Bye\n    <<jump End>>\n===\ntitle: End\n---\nGuide: Bye.\n===\n"
	_ = os.write_entire_file(joinPath(dir, "talk.yarn", allocator = context.temp_allocator), transmute([]byte)string(yarn))
	sendTo(&state, Asset_Import_Result{path = joinPath(dir, "talk.yarn", allocator = context.temp_allocator)})
	talk := Project_FindDialogue(&state.project, "dialogues/talk.dialogue.xml")
	testing.expect(t, talk >= 0, "imported")
	if talk >= 0 do testing.expect(t, e.Dialogue_FindNode(&state.project.dialogues[talk].data, "End") >= 0, "its nodes")

	// A DialogueBox playing it, set up in the inspector
	sendTo(&state, Action.Deselect)
	sendTo(&state, Add_Node_Kind_Chosen(.DialogueBox))
	box := state.selectedNode
	sendTo(&state, DialogueBox_Setting_Changed{field = .Dialogue, text = "dialogues/talk.dialogue.xml"})
	sendTo(&state, DialogueBox_Setting_Changed{field = .Start, text = "End"})
	sendTo(&state, DialogueBox_Setting_Changed{field = .Background, text = "#ff0000ff"})
	sendTo(&state, DialogueBox_Setting_Changed{field = .Width, value = 200})
	n := &state.project.scenes[state.currentScene].nodes[box]
	testing.expect(t, n.dialogue == "dialogues/talk.dialogue.xml" && n.dialogueStart == "End" && n.dialogueBox.size.x == 200, "set up")
	testing.expect_value(t, state.dialogue.path, "dialogues/talk.dialogue.xml")
	// The viewport plays its first line: the box drawn in red
	n.position = {0, 0}
	state.viewport = {center = {100, 70}, zoom = 1, size = {200, 140}}
	pixels, rendered := Preview_Render(&state, {200, 140}, 1)
	testing.expect(t, rendered, "rendered")
	if rendered {
		at := (70 * 200 + 100) * 4
		testing.expectf(t, pixels[at] > 200 && pixels[at + 1] < 60, "the box: %v", pixels[at:at + 4])
	}

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, len(loaded.dialogues), 2)
	for d in loaded.dialogues {
		i := Project_FindDialogue(&state.project, d.path)
		testing.expect(t, i >= 0 && e.DialogueData_Equal(d.data, state.project.dialogues[i].data), "a dialogue read back")
	}
	for &node, i in loaded.scenes[0].nodes do testing.expectf(t, NodeDef_Equal(node, state.project.scenes[0].nodes[i]), "node %s read back", node.name)
	testing.expect(t, strings.contains(Scripts_AssetsSource(&state.project), "DIALOGUE_TALK :: \"dialogues/talk.dialogue.xml\""), "DIALOGUE_ constants")
}
