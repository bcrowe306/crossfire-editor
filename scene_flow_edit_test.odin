package crossfire_editor

import "core:os"
import "core:testing"
import e "engine:."

// Scene changes in the editor: the project's transition and loading scene through Project
// Settings (undone, saved, read back), renamed with their scene, Button actions that open a
// scene over another and close it

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
scene_changes_in_the_editor :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_scene_flow"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, themeSelection = -1, dataSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	Project_AddScene(&state.project, "Loading")
	Project_AddScene(&state.project, "Pause")

	// Project Settings: a red wipe of a second, the Loading scene; applied as one step
	sendTo(&state, Action.Open_Project_Settings)
	sendTo(&state, Project_Settings_Transition_Changed{field = .Kind, text = "Wipe_Left"})
	sendTo(&state, NumberTarget_Msg(TransitionTimeTarget{}, 1))
	sendTo(&state, Project_Settings_Transition_Changed{field = .Color, text = "#ff0000"})
	sendTo(&state, Project_Settings_Loading_Changed("Loading"))
	testing.expect_value(t, state.project.transition.kind, e.TransitionKind.None)
	sendTo(&state, Project_Settings_Applied{})
	tr := state.project.transition
	testing.expect(t, tr.kind == .Wipe_Left && tr.duration == 1 && tr.color == {255, 0, 0, 255} && state.project.loadingScene == "Loading", "applied")
	sendTo(&state, Action.Undo)
	testing.expect(t, state.project.transition.kind == .None && state.project.loadingScene == "", "undone")
	sendTo(&state, Action.Redo)
	testing.expect_value(t, state.project.loadingScene, "Loading")

	// A Button opening Pause over the scene, and one closing it
	scene := &state.project.scenes[0]
	open := Scene_InsertNode(scene, "Open", .Button, -1)
	state.selectedNode = open
	sendTo(&state, UI_Setting_Changed{field = .Action, text = "Open Pause over this"})
	testing.expect_value(t, state.project.scenes[0].nodes[open].ui.action, "push:Pause")
	close := Scene_InsertNode(&state.project.scenes[0], "Close", .Button, -1)
	state.selectedNode = close
	sendTo(&state, UI_Setting_Changed{field = .Action, text = "Close this (back to the scene under it)"})
	testing.expect_value(t, state.project.scenes[0].nodes[close].ui.action, "pop")

	// Renamed scenes: the loading scene and the actions follow
	pause := Project_FindScene(&state.project, "Pause")
	refs, problem := Project_RenameScene(&state.project, pause, "Menu", &state.scripts)
	testing.expect(t, problem == "" && refs == 1, "the push action")
	testing.expect_value(t, state.project.scenes[0].nodes[open].ui.action, "push:Menu")
	loading := Project_FindScene(&state.project, "Loading")
	Project_RenameScene(&state.project, loading, "Wait", &state.scripts)
	testing.expect_value(t, state.project.loadingScene, "Wait")

	// Saved and read back; the loading scene removed clears it
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, loaded.transition == state.project.transition && loaded.loadingScene == "Wait", "read back")
	Project_RemoveScene(&state.project, Project_FindScene(&state.project, "Wait"))
	testing.expect_value(t, state.project.loadingScene, "")
}
