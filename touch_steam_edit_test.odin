package crossfire_editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import e "engine:."

// Touch controls (touch_edit.odin) and Steam (steam_edit.odin) in the editor: made, edited,
// undone, saved and read back; the Steam tab's draft applied as one step; assets.odin constants

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
		materialSelection = -1, trace = DEFAULT_TRACE_SETTINGS, busSelection = -1}
	state.settings.builtInCodeEditor = false
	testing.expect_value(nil, Project_Save(&state.project), "")
	return state
}

@(test)
touch_controls_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_touch_controls"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)

	// A joystick: its defaults, actions chosen one by one, settings clamped and rounded
	sendTo(&state, Add_Node_Kind_Chosen(.VirtualJoystick))
	stick := state.selectedNode
	node := &state.project.scenes[state.currentScene].nodes[stick]
	testing.expect_value(t, node.touch, e.DEFAULT_TOUCH_CONTROL_SETTINGS)
	sendTo(&state, Touch_Setting_Changed{field = .Action, index = 1, text = "move_right"})
	sendTo(&state, Touch_Setting_Changed{field = .Action, index = 3, text = "move_down"})
	node = &state.project.scenes[state.currentScene].nodes[stick]
	testing.expect_value(t, node.touchActions, ",move_right,,move_down")
	sendTo(&state, Touch_Setting_Changed{field = .Action, index = 3, text = TOUCH_ACTION_NONE})
	node = &state.project.scenes[state.currentScene].nodes[stick]
	testing.expect_value(t, node.touchActions, ",move_right")
	sendTo(&state, Touch_Setting_Changed{field = .Radius, value = 80.4})
	sendTo(&state, Touch_Setting_Changed{field = .Deadzone, value = 2})
	sendTo(&state, Touch_Setting_Changed{field = .Zone_Width, value = 300})
	sendTo(&state, Touch_Setting_Changed{field = .Zone_Height, value = 200})
	sendTo(&state, Touch_Setting_Changed{field = .Floating, flag = true})
	sendTo(&state, Touch_Setting_Changed{field = .Visibility, text = "Always"})
	sendTo(&state, Touch_Setting_Changed{field = .Mouse, flag = false})
	sendTo(&state, Touch_Setting_Changed{field = .Color, text = "#ff8000"})
	sendTo(&state, Touch_Setting_Changed{field = .Opacity, value = 0.756})
	node = &state.project.scenes[state.currentScene].nodes[stick]
	want := e.TouchControlSettings{radius = 80, deadzone = 0.95, zone = {300, 200}, floating = true, visibility = .Always, mouse = false, color = {255, 128, 0, 255}, opacity = 0.76}
	testing.expect_value(t, node.touch, want)

	// Undo takes back the opacity
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[state.currentScene].nodes[stick].touch.opacity, e.DEFAULT_TOUCH_CONTROL_SETTINGS.opacity)
	sendTo(&state, Action.Redo)

	// A button: smaller by default, its label and action
	sendTo(&state, Action.Deselect)
	sendTo(&state, Add_Node_Kind_Chosen(.TouchButton))
	button := state.selectedNode
	testing.expect_value(t, state.project.scenes[state.currentScene].nodes[button].touch.radius, f32(e.TOUCH_BUTTON_RADIUS))
	sendTo(&state, Touch_Setting_Changed{field = .Action, index = 0, text = "jump"})
	sendTo(&state, Node_Text_Changed{.Text, "A"})

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(state.project.rootPath)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	found := 0
	for &s in loaded.scenes do for &n in s.nodes {
		#partial switch n.kind {
		case .VirtualJoystick:
			found += 1
			testing.expect_value(t, n.touch, want)
			testing.expect_value(t, n.touchActions, ",move_right")
		case .TouchButton:
			found += 1
			testing.expect_value(t, n.touch.radius, f32(e.TOUCH_BUTTON_RADIUS))
			testing.expect_value(t, n.touchActions, "jump")
			testing.expect_value(t, n.text, "A")
		}
	}
	testing.expect_value(t, found, 2)
	copy := NodeDef_Clone(state.project.scenes[state.currentScene].nodes[stick])
	defer NodeDef_Destroy(&copy)
	testing.expect(t, raw_data(copy.touchActions) != raw_data(state.project.scenes[state.currentScene].nodes[stick].touchActions), "a clone owns its actions")
}

@(test)
steam_settings_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_steam_settings"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)

	// The draft: nothing changes until Apply
	sendTo(&state, Action.Open_Project_Settings)
	sendTo(&state, Project_Settings_Tab_Changed(.Steam))
	sendTo(&state, Steam_Setting_Changed{field = .App_ID, text = "480"})
	sendTo(&state, Steam_Setting_Changed{field = .App_ID, text = "not a number"})
	sendTo(&state, Steam_Setting_Changed{field = .Cloud_Saves, flag = true})
	sendTo(&state, Steam_Achievement_Added{})
	sendTo(&state, Steam_Achievement_Added{})
	sendTo(&state, Steam_Achievement_Added{})
	testing.expect_value(t, len(state.projectSettings.achievements), 3)
	testing.expect_value(t, state.projectSettings.achievements[1].name, "ACHIEVEMENT_2")
	sendTo(&state, Steam_Setting_Changed{field = .Name, index = 0, text = " FIRST_BLOOD "})
	sendTo(&state, Steam_Setting_Changed{field = .Title, index = 0, text = "First Blood"})
	sendTo(&state, Steam_Setting_Changed{field = .Description, index = 0, text = "Defeat an enemy"})
	sendTo(&state, Steam_Setting_Changed{field = .Hidden, index = 1, flag = true})
	sendTo(&state, Steam_Setting_Changed{field = .Name, index = 1, text = "FIRST_BLOOD"})
	testing.expect_value(t, AchievementNameProblem(state.projectSettings.achievements[:], 1), "Another achievement has this name.")
	sendTo(&state, Steam_Setting_Changed{field = .Name, index = 1, text = "secret one"})
	testing.expect_value(t, AchievementNameProblem(state.projectSettings.achievements[:], 1), "Use letters, digits and _ (Steam's API names).")
	sendTo(&state, Steam_Setting_Changed{field = .Name, index = 1, text = "SECRET"})
	testing.expect_value(t, AchievementNameProblem(state.projectSettings.achievements[:], 1), "")
	sendTo(&state, Steam_Achievement_Removed(2))
	testing.expect_value(t, state.project.steam.appId, 0)
	testing.expect_value(t, len(state.project.achievements), 0)
	sendTo(&state, Project_Settings_Applied{})
	testing.expect_value(t, state.project.steam, e.SteamSettings{appId = 480, cloudSaves = true})
	testing.expect_value(t, len(state.project.achievements), 2)
	testing.expect_value(t, state.project.achievements[0], AchievementDef{"FIRST_BLOOD", "First Blood", "Defeat an enemy", false})
	testing.expect(t, state.project.achievements[1].hidden, "hidden")

	// One undo step takes it all back; redo brings it back
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.steam.appId, 0)
	testing.expect_value(t, len(state.project.achievements), 0)
	sendTo(&state, Action.Redo)
	testing.expect_value(t, len(state.project.achievements), 2)

	// Saved, read back by the engine's parser, and constants for scripts
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(state.project.rootPath)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, loaded.steam, state.project.steam)
	testing.expect(t, Achievements_Equal(loaded.achievements[:], state.project.achievements[:]), "achievements survive saving")
	source := Scripts_AssetsSource(&state.project)
	testing.expect(t, strings.contains(source, `ACHIEVEMENT_FIRST_BLOOD :: "FIRST_BLOOD"`), "a constant per achievement")
	testing.expect(t, strings.contains(source, `ACHIEVEMENT_SECRET :: "SECRET"`), "and the second")
}

@(test)
touch_controls_draw_in_the_viewport :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	dir := "build/test_touch_viewport"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	state.project.background = {0, 0, 0, 255}
	scene := &state.project.scenes[0]
	// Shown only on touch screens in a game, but always in the editor
	stick := Scene_InsertNode(scene, "Stick", .VirtualJoystick, -1)
	testing.expect_value(t, scene.nodes[stick].touch.visibility, e.TouchVisibility.Touch_Screens)
	state.viewport = {center = {0, 0}, zoom = 1, size = {200, 200}}
	pixels, ok := Preview_Render(&state, {200, 200}, 1)
	if !ok do return
	// Its knob (the brightest part) at the middle; black well outside its radius
	r := int(pixels[(100 * 200 + 100) * 4])
	testing.expectf(t, r > 60, "the knob draws: %d", r)
	// (190, 190) is world (90, 90): in the game area, past the radius
	testing.expectf(t, pixels[(190 * 200 + 190) * 4] < 10, "nothing outside: %d", pixels[(190 * 200 + 190) * 4])
}

@(test)
local_players_settings_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_players_settings"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	testing.expect_value(t, state.project.players, e.DEFAULT_PLAYER_SETTINGS)
	// The defaults aren't written
	text, _ := os.read_entire_file(joinPath(state.project.rootPath, "project.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, !strings.contains(string(text), "<players"), "no <players> by default")

	sendTo(&state, Action.Open_Project_Settings)
	sendTo(&state, Players_Setting_Changed{field = .Max_Players, text = "2"})
	sendTo(&state, Players_Setting_Changed{field = .Max_Players, text = "99"})
	sendTo(&state, Players_Setting_Changed{field = .Keyboard, flag = false})
	sendTo(&state, Players_Setting_Changed{field = .Join_Action, text = "ui_accept"})
	testing.expect_value(t, state.projectSettings.players.maxPlayers, e.MAX_LOCAL_PLAYERS)
	// Renaming the action in the Input tab renames the join action
	accept := -1
	for a, i in state.projectSettings.actions do if a.name == "ui_accept" do accept = i
	testing.expect(t, accept >= 0, "the default actions")
	sendTo(&state, Input_Action_Selected(accept))
	sendTo(&state, Input_Action_Renamed("join"))
	testing.expect_value(t, state.projectSettings.players.joinAction, "join")
	testing.expect_value(t, state.project.players, e.DEFAULT_PLAYER_SETTINGS)
	sendTo(&state, Project_Settings_Applied{})
	testing.expect_value(t, state.project.players.maxPlayers, e.MAX_LOCAL_PLAYERS)
	testing.expect(t, !state.project.players.keyboard, "no keyboard player")
	testing.expect_value(t, state.project.players.joinAction, "join")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.players, e.DEFAULT_PLAYER_SETTINGS)
	sendTo(&state, Action.Redo)
	testing.expect_value(t, state.project.players.joinAction, "join")

	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(state.project.rootPath)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, loaded.players, state.project.players)

	// Removing the join action falls back to the default buttons
	sendTo(&state, Action.Open_Project_Settings)
	for a, i in state.projectSettings.actions do if a.name == "join" do sendTo(&state, Input_Action_Removed(i))
	testing.expect_value(t, state.projectSettings.players.joinAction, "")
	sendTo(&state, Project_Settings_Cancelled{})
}
