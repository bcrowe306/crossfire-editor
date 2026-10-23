package crossfire_editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import e "engine:."
import sdl "vendor:sdl3"

// UI controls and themes in the editor: settings edited and undone (sliders and check boxes
// too), a theme made, edited and made the project's, saved and read back, and the viewport's
// engine controls using them

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
ui_controls_and_themes_in_the_editor :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_ui_edit"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, themeSelection = -1, dataSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	scene := &state.project.scenes[0]
	panel := Scene_InsertNode(scene, "Menu", .Panel, -1)
	button := Scene_InsertNode(scene, "Play", .Button, panel)
	slider := Scene_InsertNode(scene, "Volume", .Slider, panel)
	checkBox := Scene_InsertNode(scene, "Fullscreen", .CheckBox, panel)
	nodeAt :: proc(state: ^State, i: int) -> ^NodeDef { return &state.project.scenes[0].nodes[i] }

	// The panel: a centered column
	state.selectedNode = panel
	sendTo(&state, UI_Setting_Changed{field = .Layout, text = "Column"})
	sendTo(&state, UI_Setting_Changed{field = .Anchor, text = "Center"})
	testing.expect(t, nodeAt(&state, panel).ui.layout == .Column && nodeAt(&state, panel).ui.anchor == .Center, "a centered column")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, nodeAt(&state, panel).ui.anchor, e.UIAnchor.Top_Left)
	sendTo(&state, Action.Redo)

	// The button: its text, size, action
	state.selectedNode = button
	sendTo(&state, Node_Text_Changed{.Text, "Play"})
	sendTo(&state, NumberTarget_Msg(UINumberTarget(UIField.Width), 120))
	sendTo(&state, UI_Setting_Changed{field = .Action, text = "Go to Main"})
	b := nodeAt(&state, button)
	testing.expect(t, b.text == "Play" && b.ui.size.x == 120 && b.ui.action == "scene:Main", "the button's settings")
	sendTo(&state, UI_Setting_Changed{field = .Action, text = UI_ACTION_NONE})
	testing.expect_value(t, nodeAt(&state, button).ui.action, "")
	sendTo(&state, UI_Setting_Changed{field = .Action, text = "Quit the game"})

	// A slider: its value, range, step, percentage; undone and redone
	state.selectedNode = slider
	sendTo(&state, NumberTarget_Msg(UINumberTarget(UIField.Max), 100))
	sendTo(&state, NumberTarget_Msg(UINumberTarget(UIField.Value), 80))
	sendTo(&state, NumberTarget_Msg(UINumberTarget(UIField.Step), 5))
	sendTo(&state, UI_Setting_Changed{field = .Show_Value, flag = true})
	v := nodeAt(&state, slider)
	testing.expect(t, v.ui.maxValue == 100 && v.ui.value == 80 && v.ui.step == 5 && v.ui.showValue, "the slider's settings")
	sendTo(&state, NumberTarget_Msg(UINumberTarget(UIField.Step), -2))
	testing.expect_value(t, nodeAt(&state, slider).ui.step, f32(0))
	sendTo(&state, Action.Undo)
	testing.expect_value(t, nodeAt(&state, slider).ui.step, f32(5))

	// A check box: its text, ticked, disabled and back
	state.selectedNode = checkBox
	sendTo(&state, Node_Text_Changed{.Text, "Fullscreen"})
	sendTo(&state, UI_Setting_Changed{field = .Checked, flag = true})
	testing.expect(t, nodeAt(&state, checkBox).ui.checked && nodeAt(&state, checkBox).text == "Fullscreen", "ticked")
	sendTo(&state, UI_Setting_Changed{field = .Disabled, flag = true})
	sendTo(&state, Action.Undo)
	testing.expect(t, nodeAt(&state, checkBox).ui.checked && !nodeAt(&state, checkBox).ui.disabled, "undone")

	// A theme of its own for the panel: made, chosen, the panel still selected
	state.selectedNode = panel
	sendTo(&state, Theme_Created{forSelected = true})
	testing.expect_value(t, len(state.project.themes), 1)
	path := state.project.themes[0].path
	testing.expect_value(t, path, "themes/theme.theme.xml")
	testing.expect_value(t, nodeAt(&state, panel).ui.theme, path)
	testing.expect_value(t, state.selectedNode, panel)
	testing.expect(t, os.exists(joinPath(root, path, allocator = context.temp_allocator)), "its file")

	// Edited in the inspector (selected in the browser): project steps
	state.selectedNode = -1
	state.themeSelection = 0
	sendTo(&state, Theme_Field_Changed{"buttonColor", "#ff0000"})
	sendTo(&state, Theme_Field_Changed{"textSize", "30"})
	testing.expect(t, state.project.themes[0].theme.buttonColor == {255, 0, 0, 255} && state.project.themes[0].theme.textSize == 30, "edited")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.themes[0].theme.textSize, e.DEFAULT_UI_THEME.textSize)
	sendTo(&state, Action.Redo)
	sendTo(&state, Theme_Project_Set(true))
	testing.expect_value(t, state.project.uiTheme, path)

	// The viewport's engine controls: the column laid out, the button with the theme's color
	_, ok := Preview_Render(&state, {320, 240}, 1)
	testing.expect(t, ok, "rendered")
	built := Preview_Node(button)
	testing.expect(t, built != nil && e.Node_IsControl(built), "a built Button")
	if built != nil && e.Node_IsControl(built) {
		control := cast(^e.Control)built
		testing.expect_value(t, control.size.x, f32(120))
		theme, _ := e.Control_Theme(control)
		testing.expect_value(t, theme.buttonColor, sdl.Color{255, 0, 0, 255})
	}
	builtSlider := Preview_Node(slider)
	testing.expect(t, builtSlider != nil && e.Node_Is(builtSlider, e.Slider), "a built Slider")
	if builtSlider != nil && e.Node_Is(builtSlider, e.Slider) do testing.expect_value(t, (cast(^e.Slider)builtSlider).settings.value, f32(80))
	builtBox := Preview_Node(checkBox)
	testing.expect(t, builtBox != nil && e.Node_Is(builtBox, e.CheckBox) && (cast(^e.CheckBox)builtBox).settings.checked, "a built, ticked CheckBox")

	// Written: a slider's step and a check box's checked, only for their kinds
	text := SceneToXML(&state.project.scenes[0], context.temp_allocator)
	testing.expect(t, strings.contains(text, `kind="Slider" name="Volume" x="0" y="0" value="80" max="100" showValue="true" step="5"`), "the slider's attributes")
	testing.expect(t, strings.contains(text, `kind="CheckBox" name="Fullscreen" x="0" y="0" text="Fullscreen" checked="true"`), "the check box's attributes")

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, loaded.uiTheme, path)
	testing.expect(t, len(loaded.themes) == 1 && loaded.themes[0].theme == state.project.themes[0].theme, "the theme")
	for n, i in loaded.scenes[0].nodes {
		original := &state.project.scenes[0].nodes[i]
		testing.expectf(t, UISettings_Equal(n.ui, original.ui) && n.text == original.text, "%s's settings", n.name)
	}
	free_all(context.temp_allocator)
}
