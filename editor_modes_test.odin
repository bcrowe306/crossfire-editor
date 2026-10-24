package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"

// Editor modes (editor_modes.odin) and the Level mode (level_mode.odin): switching, what belongs to
// a mode, the keys' scope, persistence per project, one undo history across modes

@(private="file")
modeSend :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

// The unit tests' sample project in memory (no folder: nothing is written)
@(private="file")
modeTestState :: proc() -> State {
	state := State{
		project = Project_CreateTestProject("unused"),
		browserSelection = {kind = .None},
		currentScene = 1,
		selectedNode = -1,
		busSelection = -1,
		layout = {bottomOpen = true},
		settings = Settings_Default(),
	}
	state.settings.builtInCodeEditor = false
	return state
}

// A project with the LDtk fixture imported, in a scratch folder (removed by the caller)
@(private="file")
modeLevelState :: proc(t: ^testing.T, dir: string) -> (State, bool) {
	removeAll(dir)
	os.make_directory_all(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{
		project = Project_CreateEmpty(root, "Worlds"),
		browserSelection = {kind = .None},
		selectedNode = -1,
		busSelection = -1,
		layout = {bottomOpen = true},
		settings = Settings_Default(),
	}
	state.settings.builtInCodeEditor = false
	if !testing.expect_value(t, Project_Save(&state.project), "") do return state, false
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/ldtk/world.ldtk")
	if !testing.expect_value(t, problem, "") || index < 0 do return state, false
	return state, true
}

@(test)
modes_switch_by_key_menu_and_bar :: proc(t: ^testing.T) {
	state := modeTestState()
	defer State_Destroy(&state)
	testing.expect_value(t, state.mode, EditorMode.Scene)

	// The keymap's actions (the menu's View > Level Mode sends the same), the bar's message
	modeSend(&state, Action.Mode_Level)
	testing.expect_value(t, state.mode, EditorMode.Level)
	modeSend(&state, Action.Mode_Scene)
	testing.expect_value(t, state.mode, EditorMode.Scene)
	modeSend(&state, Mode_Changed(.Level))
	testing.expect_value(t, state.mode, EditorMode.Level)

	// Each mode has its own bottom tabs and panel sizes
	testing.expect_value(t, Mode_BottomTab(&state), BottomTab.Console)
	modeSend(&state, Bottom_Tab_Picked(0))
	testing.expect_value(t, Mode_BottomTab(&state), BottomTab.LDtk)
	testing.expect_value(t, state.bottomTab, BottomTab.Console)
	modeSend(&state, Workspace_Measured({1280, 700}))
	modeSend(&state, Left_Resized(300))
	testing.expect_value(t, state.level.layout.leftWidth, 300)
	testing.expect(t, state.layout.leftWidth != 300, "the Scene mode keeps its own")
	testing.expect_value(t, state.layout.workspace, [2]f32{1280, 700})
	modeSend(&state, Action.Toggle_Bottom_Panel)
	testing.expect(t, !state.level.layout.bottomOpen && state.layout.bottomOpen, "only the Level mode's panel collapsed")
	modeSend(&state, Action.Toggle_Bottom_Panel)

	// A log tab the editor brings forward shows in both, without switching
	Mode_ShowLogTab(&state, .Output)
	testing.expect_value(t, state.mode, EditorMode.Level)
	testing.expect_value(t, state.level.bottomTab, BottomTab.Output)
	testing.expect_value(t, state.bottomTab, BottomTab.Output)

	// A tab only the Scene mode has shows it (the status bar's Git branch does it with Git)
	modeSend(&state, Bottom_Tab_Changed(int(BottomTab.Timeline)))
	testing.expect_value(t, state.mode, EditorMode.Scene)
	testing.expect_value(t, state.bottomTab, BottomTab.Timeline)
	// The Scene mode's strip: a tab's index is its BottomTab
	modeSend(&state, Bottom_Tab_Picked(int(BottomTab.Mixer)))
	testing.expect_value(t, state.bottomTab, BottomTab.Mixer)

	// What belongs to the Scene mode shows it: another scene opened, a node selected
	modeSend(&state, Mode_Changed(.Level))
	modeSend(&state, Scene_Tab_Changed(0))
	testing.expect_value(t, state.mode, EditorMode.Scene)
	modeSend(&state, Mode_Changed(.Level))
	modeSend(&state, Node_Selected(0))
	testing.expect_value(t, state.mode, EditorMode.Scene)
	// The Level mode's state stays while the Scene mode shows
	testing.expect_value(t, state.level.bottomTab, BottomTab.Output)
}

@(test)
modes_scope_the_keys :: proc(t: ^testing.T) {
	// Node and viewport keys are the Scene mode's; the browser's routed keys work in every mode
	testing.expect(t, Action_InMode(.Delete_Node, .Scene), "Delete in the Scene mode")
	testing.expect(t, !Action_InMode(.Delete_Node, .Level), "not in the Level mode")
	testing.expect(t, Action_InMode(.Delete_Node, .Level, browserFocused = true), "the browser's Delete")
	testing.expect(t, !Action_InMode(.Tool_Move, .Level, browserFocused = true), "the tools aren't the browser's")
	testing.expect(t, !Action_InMode(.Zoom_100, .Level), "the viewport's zoom")
	for action in Action {
		if action == .Delete_Node || action == .Duplicate_Node || action == .Copy_Node || action == .Cut_Node || action == .Paste_Node || action == .Rename_Node do continue
		if ACTION_KEY_RULES[action].onlyIn == {} do testing.expectf(t, Action_InMode(action, .Level), "%v works in every mode", action)
	}
	for action in ([]Action{.Play, .Save_Project, .Undo, .Redo, .Mode_Scene, .Mode_Level, .Export, .Toggle_Bottom_Panel}) {
		testing.expectf(t, Action_InMode(action, .Level), "%v works in the Level mode", action)
	}

	// Ctrl+Alt+1 and 2, taken by nothing else (Ctrl+1 is the viewport's 100%)
	keymap := Settings_Default().keymap
	scene, _ := Shortcut_Parse("Ctrl+Alt+1")
	level, _ := Shortcut_Parse("Ctrl+Alt+2")
	testing.expect_value(t, keymap[.Mode_Scene][0], scene)
	testing.expect_value(t, keymap[.Mode_Level][0], level)
	_, clash := Keymap_FindChord(&keymap, scene, .Mode_Scene)
	testing.expect(t, !clash, "Ctrl+Alt+1 is free")
	_, clash = Keymap_FindChord(&keymap, level, .Mode_Level)
	testing.expect(t, !clash, "Ctrl+Alt+2 is free")
	// They work while a code tab has the keyboard
	testing.expect(t, .Mode_Scene in CODE_EDITOR_PASSTHROUGH && .Mode_Level in CODE_EDITOR_PASSTHROUGH, "passed through the code editor")
	testing.expect(t, ACTION_LABELS[.Mode_Level] != "", "labelled")

	// The toolbar has no tools in the Level mode: they don't overflow there
	testing.expect_value(t, Toolbar_Overflow(560, 31, 4, 6, tools = false), ToolbarOverflow.None)
	testing.expect_value(t, Toolbar_Overflow(560, 31, 4, 6), ToolbarOverflow.Tools)
	testing.expect_value(t, Toolbar_Overflow(300, 31, 4, 6, tools = false), ToolbarOverflow.Files)
}

@(test)
modes_are_remembered_per_project :: proc(t: ^testing.T) {
	dir := joinPath(testTempBase(), "crossfire_modes_persist", allocator = context.temp_allocator)
	defer removeAll(dir)
	state, ok := modeLevelState(t, dir)
	defer State_Destroy(&state)
	if !ok do return
	modeSend(&state, Mode_Changed(.Level))
	path := joinPath(state.project.rootPath, MODES_FILE, allocator = context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil, "written to .editor/modes.ini")
	testing.expect(t, strings.contains(string(data), "mode = Level"), "the mode")
	testing.expect(t, strings.contains(string(data), "level_file = assets/world/world.ldtk") || LevelMode_File(&state) == "assets/world/world.ldtk", "the world")

	// Another state on the same project starts in the Level mode, on that world
	other := State{project = state.project}
	Mode_Load(&other)
	testing.expect_value(t, other.mode, EditorMode.Level)
	testing.expect_value(t, LevelMode_File(&other), "assets/world/world.ldtk")
	LevelMode_Destroy(&other.level)

	// Back to the Scene mode: written again; no file: the Scene mode
	modeSend(&state, Mode_Changed(.Scene))
	other = State{project = state.project}
	Mode_Load(&other)
	testing.expect_value(t, other.mode, EditorMode.Scene)
	LevelMode_Destroy(&other.level)
	os.remove(path)
	other = State{project = state.project, mode = .Level}
	Mode_Load(&other)
	testing.expect_value(t, other.mode, EditorMode.Scene)
	LevelMode_Destroy(&other.level)
}

@(test)
level_mode_opens_and_makes_scenes_for_levels :: proc(t: ^testing.T) {
	dir := joinPath(testTempBase(), "crossfire_modes_levels", allocator = context.temp_allocator)
	defer removeAll(dir)
	state, ok := modeLevelState(t, dir)
	defer State_Destroy(&state)
	if !ok do return
	file := LevelMode_File(&state)
	testing.expect_value(t, file, "assets/world/world.ldtk")
	scenes := Project_SceneCount(&state.project)

	// A click selects a level; nothing shows it yet, so a double-click stays in the Level mode
	modeSend(&state, Mode_Changed(.Level))
	modeSend(&state, Level_Map_Clicked{file = file, level = "Level_0", double = true})
	testing.expect_value(t, state.level.level, "Level_0")
	testing.expect_value(t, state.mode, EditorMode.Level)
	testing.expect_value(t, len(LevelMode_ScenesShowing(&state, file, "Level_0")), 0)

	// New Scene with This Level: a scene named after it, its LDtkLevel node, the Scene mode
	modeSend(&state, Level_Scene_Created{})
	testing.expect_value(t, Project_SceneCount(&state.project), scenes + 1)
	testing.expect_value(t, state.mode, EditorMode.Scene)
	scene := &state.project.scenes[state.currentScene]
	testing.expect_value(t, scene.name, "Level_0")
	if node := selectedNode(&state); testing.expect(t, node != nil, "its level node selected") {
		testing.expect_value(t, node.kind, NodeKind.LDtkLevel)
		testing.expect_value(t, node.ldtk.file, file)
		testing.expect_value(t, node.ldtk.level, "Level_0")
	}
	shown := LevelMode_ScenesShowing(&state, file, "Level_0")
	testing.expect_value(t, len(shown), 1)

	// One history: undo goes back to the Level mode without the scene, redo brings both back
	modeSend(&state, Action.Undo)
	testing.expect_value(t, Project_SceneCount(&state.project), scenes)
	testing.expect_value(t, state.mode, EditorMode.Level)
	modeSend(&state, Action.Redo)
	testing.expect_value(t, Project_SceneCount(&state.project), scenes + 1)
	testing.expect_value(t, state.mode, EditorMode.Scene)

	// A node edit in the Scene mode, then the Level mode: undo shows the Scene mode again
	if len(shown) == 1 {
		state.selectedNode = shown[0].node
		modeSend(&state, Mode_Changed(.Level))
		modeSend(&state, Level_Scene_Opened{shown[0].scene, shown[0].node})
		testing.expect_value(t, state.mode, EditorMode.Scene)
		testing.expect_value(t, state.selectedNode, shown[0].node)
		modeSend(&state, Node_Renamed("Forest"))
		testing.expect_value(t, state.project.scenes[state.currentScene].nodes[state.selectedNode].name, "Forest")
		modeSend(&state, Mode_Changed(.Level))
		modeSend(&state, Action.Undo)
		testing.expect_value(t, state.mode, EditorMode.Scene)
		testing.expect_value(t, state.project.scenes[shown[0].scene].nodes[shown[0].node].name, "Level")
	}

	// In the Level mode, the browser's map selects a level there (the hidden scene isn't changed)
	modeSend(&state, Mode_Changed(.Level))
	modeSend(&state, LDtk_Level_Picked{file = file, level = "Level_0"})
	testing.expect_value(t, state.level.level, "Level_0")
	testing.expect_value(t, state.mode, EditorMode.Level)
	// A double-click on a level a scene shows opens it in the Scene mode
	modeSend(&state, Level_Map_Clicked{file = file, level = "Level_0", double = true})
	testing.expect_value(t, state.mode, EditorMode.Scene)
	testing.expect_value(t, state.project.scenes[state.currentScene].name, "Level_0")
}
