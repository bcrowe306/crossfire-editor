package crossfire_editor

// Workflow (TODO.md's "UI and UX" round, 2026-10-25): the tools' hints (tool_hints.odin),
// maximized panels and layout presets (layouts.odin).
// Run with: task test

import "core:os"
import "core:strings"
import "core:testing"

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
