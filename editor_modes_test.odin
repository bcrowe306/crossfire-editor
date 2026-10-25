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
	testing.expect_value(t, Mode_BottomTab(&state), BottomTab.World)
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

	// The toolbar is every mode's: the Level mode's tools (by the layer's type) overflow as the
	// viewport's do, a mode without tools only its file buttons
	testing.expect_value(t, Toolbar_Overflow(560, 31, 4, 6, tools = 0), ToolbarOverflow.None)
	testing.expect_value(t, Toolbar_Overflow(560, 31, 4, 6), ToolbarOverflow.Tools)
	testing.expect_value(t, Toolbar_Overflow(560, 31, 4, 6, tools = 1), ToolbarOverflow.None)
	testing.expect_value(t, Toolbar_Overflow(560, 31, 4, 6, tools = len(LevelTools_For("Tiles"))), ToolbarOverflow.Tools)
	testing.expect_value(t, Toolbar_Overflow(300, 31, 4, 6, tools = 0), ToolbarOverflow.Files)
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

/*
The Level mode's layout (phase 1 of the LDtk level editor): its sidebars at each window width, the
toolbar's Level tools per layer type (Select only works yet), the Levels sidebar's rows (a click
selects, a double-click focuses), the canvas's focus and the world view, several worlds, the
Layers sidebar's selection and a layer dragged several places (one undo step).
*/
@(test)
level_mode_layout_tools_worlds_and_layers :: proc(t: ^testing.T) {
	// The sidebars start as the Scene mode's and fit the window as they do (FittedSidebarWidths,
	// the user's correction of 2026-10-25: the Level mode is the editor's, not another app)
	{
		testing.expect(t, LEVEL_LAYOUT_DEFAULT.leftWidth == DEFAULT_LEFT_WIDTH && LEVEL_LAYOUT_DEFAULT.rightWidth == DEFAULT_RIGHT_WIDTH, "the Scene mode's widths")
		for width in ([]f32{1920, 1280, 900, 640}) {
			layout := LEVEL_LAYOUT_DEFAULT
			layout.workspace = {width, 600}
			sceneLayout := Layout{leftWidth = DEFAULT_LEFT_WIDTH, rightWidth = DEFAULT_RIGHT_WIDTH, workspace = {width, 600}}
			left, right := FittedSidebarWidths(&layout)
			sceneLeft, sceneRight := FittedSidebarWidths(&sceneLayout)
			testing.expectf(t, left == sceneLeft && right == sceneRight, "%v: the Scene mode's sidebars (%v, %v against %v, %v)", width, left, right, sceneLeft, sceneRight)
			testing.expectf(t, width - left - right - DIVIDER * 2 >= MIN_CENTER_WIDTH, "%v: the canvas keeps the center's minimum", width)
		}
	}
	// LDtk's tools per layer type; every one works since phase 2 (painting the focused level)
	testing.expect_value(t, len(LevelTools_For("IntGrid")), 6)
	testing.expect_value(t, len(LevelTools_For("Tiles")), 7)
	testing.expect_value(t, len(LevelTools_For("Entities")), 4)
	testing.expect_value(t, len(LevelTools_For("AutoLayer")), 1)
	for info, tool in LEVEL_TOOLS do testing.expectf(t, info.works, "%v works", tool)
	testing.expect(t, strings.contains(LevelTool_Tip(.Fill, "IntGrid"), "focused level"), "the tooltip says where it paints")
	icon, name, _ := LevelTool_Look(.Pencil, "Tiles")
	testing.expect(t, icon == ICON_STAMP && name == "Stamp", "tiles paint with a stamp")

	dir := joinPath(testTempBase(), "crossfire_level_layout", allocator = context.temp_allocator)
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	state, ok := modeLevelState(t, dir)
	defer State_Destroy(&state)
	if !ok do return
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/ldtk_world/worlds.ldtk")
	if !testing.expect_value(t, problem, "") || index < 0 do return
	modeSend(&state, Mode_Changed(.Level))
	modeSend(&state, Level_File_Chosen(state.project.assets[index].path))
	file := LevelMode_File(&state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	if !testing.expect(t, doc != nil && doc.problem == "", "read") do return
	testing.expect_value(t, len(doc.worlds), 2)
	modeSend(&state, Workspace_Measured({1280, 600}))
	modeSend(&state, Level_Canvas_Measured({600, 300}))

	// The first world's levels; another world picked shows its own
	names :: proc(state: ^State, doc: ^LDtkDoc) -> string {
		out := make([dynamic]string, context.temp_allocator)
		for i in LevelMode_WorldLevels(state, doc) {
			name, _ := LDtkDoc_LevelNames(doc, i)
			append(&out, name)
		}
		return strings.join(out[:], ",", context.temp_allocator)
	}
	testing.expect_value(t, names(&state, doc), "Meadow,Hill")
	levels, entities, _ := LevelCanvas_Content(&state, doc)
	testing.expect_value(t, len(levels), 2)
	testing.expect_value(t, len(entities), 3)
	modeSend(&state, Level_World_Chosen("world-under"))
	testing.expect_value(t, names(&state, doc), "Crypt")
	levels, entities, _ = LevelCanvas_Content(&state, doc)
	testing.expect_value(t, len(levels), 1)
	testing.expect_value(t, len(entities), 1)
	// A level of the other world, selected (the browser's map, a test): its world shows
	modeSend(&state, Level_Row_Clicked{level = "Hill"})
	testing.expect_value(t, state.level.world, "world-over")
	testing.expect_value(t, state.level.level, "Hill")

	// A double-click focuses the level: the view fits it, others dimmed; another picked is focused
	modeSend(&state, Level_Row_Clicked{level = "Meadow", double = true})
	testing.expect_value(t, state.level.focus, "Meadow")
	focusedZoom := state.level.view.zoom
	testing.expect(t, abs(state.level.view.center.x - 128) < 0.5, "centered on Meadow")
	levels, _, _ = LevelCanvas_Content(&state, doc)
	for l in levels do testing.expectf(t, l.dim == (l.identifier != "Meadow"), "%s dimmed: %v", l.identifier, l.dim)
	modeSend(&state, Level_Row_Clicked{level = "Hill"})
	testing.expect_value(t, state.level.focus, "Hill")
	// On the canvas: another level focuses it; the focused one doesn't move (the press pans)
	modeSend(&state, Level_Canvas_Pressed{world = {100, 64}, level = "Meadow"})
	testing.expect_value(t, state.level.focus, "Meadow")
	modeSend(&state, Level_Canvas_Pressed{world = {100, 64}, level = "Meadow"})
	testing.expect_value(t, state.level.drag.mode, LevelDragMode.Pan)
	modeSend(&state, Level_Canvas_Released{})
	// A double-click outside goes back to the world (the view fits it)
	modeSend(&state, Level_Canvas_Pressed{world = {-500, -500}, double = true})
	testing.expect_value(t, state.level.focus, "")
	testing.expect(t, state.level.view.zoom < focusedZoom, "the world is bigger than a level")
	modeSend(&state, Level_Focus_Changed("Hill"))
	testing.expect_value(t, state.level.focus, "Hill")
	modeSend(&state, Level_Focus_Changed(""))
	testing.expect_value(t, state.level.focus, "")
	testing.expect_value(t, state.level.level, "Hill")

	// The Layers sidebar: the first layer until one's picked; the tools follow its type
	testing.expect_value(t, LevelMode_LayerType(&state), "Entities")
	modeSend(&state, Level_Layer_Picked(3))
	testing.expect_value(t, LevelMode_LayerType(&state), "IntGrid")
	testing.expect(t, LevelTool_Available(&state, .Fill), "IntGrid fills")
	modeSend(&state, Level_Tool_Picked(.Fill))
	testing.expect_value(t, state.level.tool, LevelTool.Fill)
	// A layer without the tool goes back to Select (an Entities layer has no Fill)
	modeSend(&state, Level_Layer_Picked(1))
	testing.expect_value(t, state.level.tool, LevelTool.Select)

	// A layer dragged two places down (Entities 1, Tiles 2, Walls 3): every level follows; one step
	main := LDtkDoc_Main(doc)
	order :: proc(doc: ^LDtkDoc) -> string {
		main := LDtkDoc_Main(doc)
		out := make([dynamic]string, context.temp_allocator)
		for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) do append(&out, Json_String(main, Json_Get(main, d, "identifier")))
		return strings.join(out[:], ",", context.temp_allocator)
	}
	_ = main
	undo := len(state.history.undo)
	modeSend(&state, LDtk_Edit{op = .Layer_Move, file = file, def = 1, number = 2})
	doc = LDtkDoc_Get(state.project.rootPath, file)
	testing.expect_value(t, order(doc), "Tiles,Walls,Entities")
	testing.expect_value(t, len(state.history.undo), undo + 1)
	level := LDtkDoc_FindLevel(doc, "Crypt")
	lf, layers := LDtkDoc_LayerInstances(doc, level)
	json := LDtkDoc_Json(doc, lf)
	testing.expect_value(t, Json_String(json, Json_Get(json, Json_At(json, layers, 2), "__identifier")), "Entities")
	modeSend(&state, LDtk_Edit{op = .Layer_Move, file = file, def = 1, number = -1})
	doc = LDtkDoc_Get(state.project.rootPath, file)
	testing.expect_value(t, order(doc), "Tiles,Entities,Walls")
	modeSend(&state, Action.Undo)
	modeSend(&state, Action.Undo)
	doc = LDtkDoc_Get(state.project.rootPath, file)
	testing.expect_value(t, order(doc), "Entities,Tiles,Walls")
	testing.expect(t, !LDtkDoc_IsUnsaved(state.project.rootPath, file), "undone: as saved")

	// The world is remembered with the file
	modeSend(&state, Level_World_Chosen("world-under"))
	world := strings.clone(state.level.world, context.temp_allocator)
	Mode_Load(&state)
	testing.expect_value(t, state.level.world, world)
}

/*
The bottom tabs' shared layout (view_list_tab.odin, the user's sketch of 2026-10-25): a list
beside the settings from LIST_TAB_COMPACT_WIDTH, a dropdown narrower (a tiled window's panel is
about 200 px), the Project tab without a list; the sidebar's kept width clamped to leave the
settings their minimum; the settings' rows laid out as the inspector's at the content's width.
*/
@(test)
list_tabs_share_one_layout :: proc(t: ^testing.T) {
	settings := Settings_Default()
	th := Settings_Theme(&settings)
	// A tiled window's panel: a dropdown, the rows stacked as a narrow inspector's
	tiled := ListTab_Layout(&th, 200, true, 0)
	testing.expect(t, tiled.compact && tiled.sidebar == 0, "a narrow panel's list is a dropdown")
	width, stacked := Inspector_Layout(&th, 200)
	testing.expect(t, tiled.stacked == stacked && tiled.controlWidth == min(width, LIST_TAB_MAX_CONTROL), "the inspector's rows at that width")
	// A wide one: the list at its default width, then the width the user left, kept within bounds
	wide := ListTab_Layout(&th, 728, true, 0)
	testing.expect(t, !wide.compact && wide.sidebar == LIST_TAB_WIDTH, "the list beside the settings")
	testing.expect_value(t, wide.content, 728 - LIST_TAB_WIDTH - DIVIDER)
	testing.expect_value(t, ListTab_Layout(&th, 728, true, 300).sidebar, 300)
	testing.expect_value(t, ListTab_Layout(&th, 728, true, 60).sidebar, f32(LIST_TAB_MIN_WIDTH))
	testing.expect_value(t, ListTab_Layout(&th, 728, true, 700).sidebar, 728 - DIVIDER - LIST_TAB_MIN_CONTENT)
	// The Project tab: no list at any width
	project := ListTab_Layout(&th, 1368, false, 0)
	testing.expect(t, project.compact && project.sidebar == 0 && project.content == 1368, "no list")
}
