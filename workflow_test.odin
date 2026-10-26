package crossfire_editor

// Workflow (TODO.md's "UI and UX" round, 2026-10-25): the tools' hints (tool_hints.odin),
// maximized panels and layout presets (layouts.odin).
// Run with: task test

import "core:os"
import "core:strings"
import "core:testing"
import "gui:skald"

// The test project in memory (its root `root`), PlayScene open, nothing selected
@(private="file")
workflowState :: proc(root := "unused") -> State {
	state := State{
		project = Project_CreateTestProject(root),
		browserSelection = {kind = .None},
		currentScene = 1,
		selectedNode = -1,
		busSelection = -1,
		layout = Layout_Defaults(),
		level = {layout = LEVEL_LAYOUT_DEFAULT, bottomTab = .World},
		settings = Settings_Default(),
	}
	state.settings.builtInCodeEditor = false
	return state
}

@(private="file")
workflowSend :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
tool_hints_name_each_tools_keys :: proc(t: ^testing.T) {
	state := workflowState()
	defer State_Destroy(&state)
	for tool in Tool {
		state.tool = tool
		testing.expectf(t, Tool_Hint(&state) != "", "%v has a hint", tool)
	}
	state.tool = .Move
	testing.expect(t, strings.contains(Tool_Hint(&state), "Alt+drag: duplicate"), "Move: Alt duplicates")
	state.tool = .Zoom
	testing.expect(t, strings.contains(Tool_Hint(&state), "Alt+click: zoom out"), "Zoom: Alt zooms out")
	state.mode = .Level
	for tool in LevelTool {
		state.level.tool = tool
		testing.expectf(t, Tool_Hint(&state) != "", "the Level mode's %v has a hint", tool)
	}
	state.level.tool = .Pencil
	testing.expect(t, strings.contains(Tool_Hint(&state), "Right button: erase"), "Pencil: the right button erases")
}

@(test)
panels_maximize_and_restore :: proc(t: ^testing.T) {
	state := workflowState()
	defer State_Destroy(&state)
	workflowSend(&state, Panel_Maximized(.Inspector))
	testing.expect_value(t, state.layout.maximized, MaxPanel.Inspector)
	// The same panel again restores; Escape (Deselect) too, before it deselects
	workflowSend(&state, Panel_Maximized(.Inspector))
	testing.expect_value(t, state.layout.maximized, MaxPanel.None)
	state.selectedNode = 0
	workflowSend(&state, Panel_Maximized(.Bottom))
	testing.expect_value(t, state.layout.maximized, MaxPanel.Bottom)
	workflowSend(&state, Action.Deselect)
	testing.expect_value(t, state.layout.maximized, MaxPanel.None)
	testing.expect_value(t, state.selectedNode, 0)
	// A collapsed bottom panel opens when it's maximized
	state.layout.bottomOpen = false
	workflowSend(&state, Panel_Maximized(.Bottom))
	testing.expect(t, state.layout.bottomOpen, "maximized, the bottom panel is open")
	// The shortcut restores a maximized panel; with none, it maximizes (the center by default)
	workflowSend(&state, Action.Maximize_Panel)
	testing.expect_value(t, state.layout.maximized, MaxPanel.None)
	workflowSend(&state, Action.Maximize_Panel)
	testing.expect_value(t, state.layout.maximized, MaxPanel.Center)
	// Per mode: the Level mode has its own, and no scene tree or inspector
	workflowSend(&state, Mode_Changed(.Level))
	testing.expect_value(t, state.level.layout.maximized, MaxPanel.None)
	workflowSend(&state, Panel_Maximized(.Inspector))
	testing.expect_value(t, state.level.layout.maximized, MaxPanel.None)
	workflowSend(&state, Panel_Maximized(.Right))
	testing.expect_value(t, state.level.layout.maximized, MaxPanel.Right)
	workflowSend(&state, Action.Level_Cancel)
	testing.expect_value(t, state.level.layout.maximized, MaxPanel.None)
	testing.expect_value(t, state.layout.maximized, MaxPanel.Center)
	// The default keys
	testing.expect(t, state.settings.keymap[.Maximize_Panel][0] != {}, "Maximize_Panel has a key")
}

@(test)
layout_presets_apply_save_and_load :: proc(t: ^testing.T) {
	dir := "build/test_layouts"
	removeAll(dir)
	os.make_directory_all(dir)
	defer removeAll(dir)
	state := workflowState(dir)
	defer State_Destroy(&state)

	// Built-in presets: sizes, open panels and the bottom tab
	workflowSend(&state, Layout_Preset_Applied{builtin = .Wide_Viewport, user = -1})
	testing.expect_value(t, state.layout.leftWidth, f32(MIN_SIDEBAR_WIDTH))
	testing.expect_value(t, state.layout.rightWidth, f32(MIN_SIDEBAR_WIDTH))
	testing.expect(t, !state.layout.bottomOpen, "Wide Viewport closes the bottom panel")
	workflowSend(&state, Layout_Preset_Applied{builtin = .Level, user = -1})
	testing.expect_value(t, state.bottomTab, BottomTab.Tiles)
	testing.expect(t, state.layout.bottomOpen, "Level opens the bottom panel")
	// A preset restores a maximized panel
	workflowSend(&state, Panel_Maximized(.Center))
	workflowSend(&state, Layout_Preset_Applied{builtin = .Code, user = -1})
	testing.expect_value(t, state.layout.maximized, MaxPanel.None)
	testing.expect_value(t, state.bottomTab, BottomTab.Console)

	// Save Current Layout As...: a name, then Save
	state.layout.leftWidth = 333
	state.bottomTab = .Mixer
	workflowSend(&state, Layout_Save_Opened{})
	testing.expect(t, state.layouts.saveOpen, "the dialog opens")
	workflowSend(&state, Layout_Save_Name_Changed("[bad]"))
	workflowSend(&state, Layout_Save_Confirmed{})
	testing.expect(t, state.layouts.saveOpen, "a bad name isn't saved")
	workflowSend(&state, Layout_Save_Name_Changed("Mixing"))
	workflowSend(&state, Layout_Save_Confirmed{})
	testing.expect(t, !state.layouts.saveOpen, "saved, the dialog closes")
	testing.expect_value(t, len(state.layouts.presets), 1)
	// The same name replaces it
	state.layout.leftWidth = 350
	workflowSend(&state, Layout_Save_Opened{})
	workflowSend(&state, Layout_Save_Name_Changed("Mixing"))
	workflowSend(&state, Layout_Save_Confirmed{})
	testing.expect_value(t, len(state.layouts.presets), 1)
	testing.expect_value(t, state.layouts.presets[0].leftWidth, f32(350))

	// Reset, then the saved one again
	workflowSend(&state, Layout_Preset_Applied{builtin = .Default, user = -1})
	testing.expect_value(t, state.layout.leftWidth, f32(DEFAULT_LEFT_WIDTH))
	testing.expect_value(t, state.bottomTab, BottomTab.Console)
	workflowSend(&state, Layout_Preset_Applied{user = 0})
	testing.expect_value(t, state.layout.leftWidth, f32(350))
	testing.expect_value(t, state.bottomTab, BottomTab.Mixer)

	// Written to the project's .editor/layout.ini; another state on the project reads it back
	path := joinPath(state.project.rootPath, LAYOUT_FILE, allocator = context.temp_allocator)
	testing.expect(t, os.exists(path), "the layout file is written")
	other := State{project = state.project, layout = Layout_Defaults(), level = {layout = LEVEL_LAYOUT_DEFAULT, bottomTab = .World}}
	Layouts_Load(&other)
	testing.expect_value(t, other.layout.leftWidth, f32(350))
	testing.expect_value(t, other.bottomTab, BottomTab.Mixer)
	testing.expect_value(t, len(other.layouts.presets), 1)
	if len(other.layouts.presets) == 1 do testing.expect_value(t, other.layouts.presets[0].name, "Mixing")
	LayoutState_Destroy(&other.layouts)
}

@(test)
layout_file_skips_the_untouched_defaults :: proc(t: ^testing.T) {
	dir := "build/test_layouts_default"
	removeAll(dir)
	os.make_directory_all(dir)
	defer removeAll(dir)
	state := workflowState(dir)
	defer State_Destroy(&state)
	workflowSend(&state, Frame_Requested{})
	workflowSend(&state, Action.Deselect)
	path := joinPath(state.project.rootPath, LAYOUT_FILE, allocator = context.temp_allocator)
	testing.expect(t, !os.exists(path), "nothing is written for the default layout")
	// A hand-written file with unknown keys and a missing one: the rest is read
	Layouts_Parse(&state, "[Scene]\nleft = 300\nbogus = 1\nbottom_tab = Git\n[Nowhere]\nleft = 5\n[preset  ]\nleft = 1\n")
	testing.expect_value(t, state.layout.leftWidth, f32(300))
	testing.expect_value(t, state.layout.rightWidth, f32(DEFAULT_RIGHT_WIDTH))
	testing.expect_value(t, state.bottomTab, BottomTab.Git)
	testing.expect_value(t, len(state.layouts.presets), 0)
}

@(test)
welcome_screen_opens_closes_and_keeps_the_placeholder_unsaved :: proc(t: ^testing.T) {
	// Without a project: the placeholder has no folder, and the screen can't be closed
	state := workflowState()
	defer State_Destroy(&state)
	Project_Destroy(&state.project)
	state.project = Project_CreatePlaceholder()
	state.currentScene = 0
	state.welcome = {open = true, noProject = true}
	testing.expect_value(t, state.project.rootPath, "")
	workflowSend(&state, Welcome_Closed{})
	testing.expect(t, state.welcome.open, "with no project the welcome screen stays")
	workflowSend(&state, Action.Deselect)
	testing.expect(t, state.welcome.open, "Escape doesn't close it either")
	testing.expect_value(t, Layouts_Save(&state), "")
	testing.expect_value(t, Mode_Save(&state), "")

	// Over an open project: File > Welcome, then Back or Escape
	other := workflowState()
	defer State_Destroy(&other)
	workflowSend(&other, Welcome_Opened{})
	testing.expect(t, other.welcome.open, "File > Welcome opens it")
	workflowSend(&other, Action.Deselect)
	testing.expect(t, !other.welcome.open, "Escape goes back")
	workflowSend(&other, Welcome_Opened{})
	workflowSend(&other, Welcome_Closed{})
	testing.expect(t, !other.welcome.open, "Back goes back")

	// A recent project taken off the list
	append(&other.recentProjects.folders, strings.clone("/nowhere/One"), strings.clone("/nowhere/Two"))
	workflowSend(&other, Welcome_Recent_Removed(0))
	testing.expect_value(t, len(other.recentProjects.folders), 1)
	testing.expect_value(t, other.recentProjects.folders[0], "/nowhere/Two")
}

@(test)
multi_edit_sets_every_selected_node_in_one_step :: proc(t: ^testing.T) {
	state := workflowState()
	defer State_Destroy(&state)
	scene := &state.project.scenes[state.currentScene]
	if !testing.expect(t, len(scene.nodes) >= 3, "the test scene has nodes") do return
	scene.nodes[0].position.x = 10
	scene.nodes[1].position.x = 20
	scene.nodes[0].visible, scene.nodes[1].visible = true, false
	Selection_Set(&state, {0, 1}, 0)
	state.selectionSet = false

	// Mixed values: the X and the visibility differ, the scale doesn't
	mixed := MultiEdit_Mixed(&state)
	testing.expect(t, .Position_X in mixed, "X is mixed")
	testing.expect(t, .Visible in mixed, "visibility is mixed")
	testing.expect(t, .Scale_X not_in mixed, "the scale isn't")

	undos := len(state.history.undo)
	workflowSend(&state, Node_Field_Changed{.Position_X, 50})
	scene = &state.project.scenes[state.currentScene]
	testing.expect_value(t, scene.nodes[0].position.x, f32(50))
	testing.expect_value(t, scene.nodes[1].position.x, f32(50))
	testing.expect_value(t, len(state.selection), 2)
	testing.expect_value(t, state.selectedNode, 0)
	testing.expect_value(t, len(state.history.undo), undos + 1)
	testing.expect(t, .Position_X not_in MultiEdit_Mixed(&state), "set on both, X isn't mixed")
	// Typing in the number field: the text is kept once and the value goes to both, merged
	workflowSend(&state, Number_Text_Changed{target = NodeField.Position_Y, text = "7", lo = min(f64), hi = max(f64)})
	workflowSend(&state, Number_Text_Changed{target = NodeField.Position_Y, text = "75", lo = min(f64), hi = max(f64)})
	scene = &state.project.scenes[state.currentScene]
	testing.expect_value(t, scene.nodes[0].position.y, f32(75))
	testing.expect_value(t, scene.nodes[1].position.y, f32(75))
	testing.expect_value(t, len(state.history.undo), undos + 2)
	workflowSend(&state, Node_Visibility_Changed(true))
	scene = &state.project.scenes[state.currentScene]
	testing.expect(t, scene.nodes[0].visible && scene.nodes[1].visible, "both shown")

	// One undo puts both back
	workflowSend(&state, Action.Undo)
	workflowSend(&state, Action.Undo)
	workflowSend(&state, Action.Undo)
	scene = &state.project.scenes[state.currentScene]
	testing.expect_value(t, scene.nodes[0].position.x, f32(10))
	testing.expect_value(t, scene.nodes[1].position.x, f32(20))
	testing.expect(t, !scene.nodes[1].visible, "visibility back")

	// One node selected: the edit is that node's alone
	Selection_Set(&state, {1}, 1)
	workflowSend(&state, Node_Field_Changed{.Rotation, 45})
	scene = &state.project.scenes[state.currentScene]
	testing.expect_value(t, scene.nodes[1].rotation, f32(45))
	testing.expect(t, scene.nodes[0].rotation != 45, "the other node isn't changed")
}

@(test)
inspector_pins_and_sections_are_kept_per_type :: proc(t: ^testing.T) {
	dir := "build/test_inspector_prefs"
	removeAll(dir)
	os.make_directory_all(dir)
	defer removeAll(dir)
	state := workflowState(dir)
	defer State_Destroy(&state)

	workflowSend(&state, Inspector_Pin_Toggled{kind = .Sprite, label = "Texture"})
	workflowSend(&state, Inspector_Pin_Toggled{kind = .Sprite, label = "Rotation"})
	workflowSend(&state, Inspector_Pin_Toggled{kind = .Label, label = "Text"})
	workflowSend(&state, Inspector_Section_Toggled{kind = .Sprite, section = "Node"})
	p := &state.inspectorPrefs
	testing.expect_value(t, InspectorPrefs_PinIndex(p, .Sprite, "Texture"), 0)
	testing.expect_value(t, InspectorPrefs_PinIndex(p, .Sprite, "Rotation"), 1)
	testing.expect_value(t, InspectorPrefs_PinIndex(p, .Label, "Rotation"), -1)
	testing.expect(t, InspectorPrefs_Collapsed(p, .Sprite, "Node"), "the Sprite's Node section is collapsed")
	testing.expect(t, !InspectorPrefs_Collapsed(p, .Label, "Node"), "the Label's isn't")
	// Toggling again unpins and opens
	workflowSend(&state, Inspector_Pin_Toggled{kind = .Sprite, label = "Texture"})
	testing.expect_value(t, InspectorPrefs_PinIndex(p, .Sprite, "Rotation"), 0)

	// Saved in the project; read back by another state
	path := joinPath(state.project.rootPath, INSPECTOR_PREFS_FILE, allocator = context.temp_allocator)
	testing.expect(t, os.exists(path), "the file is written")
	other := State{project = state.project}
	InspectorPrefs_Load(&other)
	testing.expect_value(t, InspectorPrefs_PinIndex(&other.inspectorPrefs, .Sprite, "Rotation"), 0)
	testing.expect_value(t, InspectorPrefs_PinIndex(&other.inspectorPrefs, .Label, "Text"), 0)
	testing.expect(t, InspectorPrefs_Collapsed(&other.inspectorPrefs, .Sprite, "Node"), "collapsed, read back")
	InspectorPrefs_Destroy(&other.inspectorPrefs)
	// Unknown types and keys are skipped
	InspectorPrefs_Parse(&other.inspectorPrefs, "[Nope]\npinned = A\n[Sprite]\nbogus = 1\npinned = Scale X | Layer\n")
	testing.expect_value(t, InspectorPrefs_PinIndex(&other.inspectorPrefs, .Sprite, "Layer"), 1)
	InspectorPrefs_Destroy(&other.inspectorPrefs)

	// The placeholder a pinned row leaves is dropped, a plain spacer isn't
	rows := []skald.View{pinnedPlaceholder(), skald.spacer(0)}
	testing.expect_value(t, len(Inspector_DropPlaceholders(rows)), 1)
}
