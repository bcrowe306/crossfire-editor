package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"
import e "engine:."

// A Camera's follow target and settings in the editor: edits and undo, clones and equality,
// paths kept through renames and moves, saved and read back, built by the engine

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
camera_follow_settings_in_the_editor :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_camera_edit"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	scene := &state.project.scenes[0]
	level := Scene_InsertNode(scene, "Level", .Node2D, -1)
	hero := Scene_InsertNode(scene, "Hero", .Sprite, level)
	camera := Scene_InsertNode(scene, "Cam", .Camera, -1)
	nodeAt :: proc(state: ^State, i: int) -> ^NodeDef { return &state.project.scenes[0].nodes[i] }
	testing.expect(t, nodeAt(&state, camera).camera == e.DEFAULT_CAMERA_SETTINGS && nodeAt(&state, camera).cameraTarget == "", "defaults")

	// Every setting through its message; each an undo step
	state.selectedNode = camera
	path := Scene_NodePath(scene, camera, hero, context.temp_allocator)
	testing.expect_value(t, path, "../Level/Hero")
	sendTo(&state, Camera_Changed{field = .Target, text = path})
	sendTo(&state, Camera_Changed{field = .Follow_Mode, text = "SmoothDamp"})
	sendTo(&state, NumberTarget_Msg(CameraNumber(CameraField.Smooth_Time), 0.4))
	sendTo(&state, NumberTarget_Msg(CameraNumber(CameraField.Deadzone_X), 96))
	sendTo(&state, NumberTarget_Msg(CameraNumber(CameraField.Offset_Y), -40))
	sendTo(&state, NumberTarget_Msg(CameraNumber(CameraField.Look_Ahead_X), 80))
	sendTo(&state, NumberTarget_Msg(CameraNumber(CameraField.Max_Speed), -5)) // clamped
	sendTo(&state, Camera_Changed{field = .Limit_Left_On, flag = true})
	sendTo(&state, Camera_Changed{field = .Limit_Bottom_On, flag = true})
	sendTo(&state, NumberTarget_Msg(CameraNumber(CameraField.Limit_Left), -32))
	sendTo(&state, NumberTarget_Msg(CameraNumber(CameraField.Shake_Strength), 9))
	sendTo(&state, NumberTarget_Msg(NodeField.Zoom, 2))
	c := nodeAt(&state, camera).camera
	testing.expect(t, nodeAt(&state, camera).cameraTarget == path && c.follow.mode == .SmoothDamp && c.follow.smoothTime == 0.4, "target and mode")
	testing.expect(t, c.follow.deadzone == {96, 0} && c.follow.offset == {0, -40} && c.follow.lookAhead == {80, 0} && c.follow.maxSpeed == 0, "dead zone, offset, look-ahead")
	// A bottom limit turned on at 0 starts at the game's bottom edge
	testing.expectf(t, c.limits == {.Left, .Bottom} && c.limitMin.x == -32 && c.limitMax.y == state.project.gameSize.y, "limits: %v", c)
	testing.expect(t, c.shake.strength == 9 && nodeAt(&state, camera).zoom == 2, "shake and zoom")
	sendTo(&state, Action.Undo) // the zoom
	sendTo(&state, Action.Undo) // the shake
	testing.expect(t, nodeAt(&state, camera).camera.shake.strength == e.DEFAULT_CAMERA_SHAKE_SETTINGS.strength && nodeAt(&state, camera).zoom == 1, "undone")
	sendTo(&state, Action.Redo)
	sendTo(&state, Camera_Changed{field = .Limit_Left_On, flag = false})
	testing.expect_value(t, nodeAt(&state, camera).camera.limits, e.CameraSides{.Bottom})
	sendTo(&state, Action.Undo)
	testing.expect_value(t, nodeAt(&state, camera).camera.limits, e.CameraSides{.Left, .Bottom})
	sendTo(&state, Camera_Changed{field = .Target, text = CAMERA_TARGET_NONE})
	testing.expect_value(t, nodeAt(&state, camera).cameraTarget, "")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, nodeAt(&state, camera).cameraTarget, path)

	// Clones are equal; a different target or setting isn't
	copy := NodeDef_Clone(nodeAt(&state, camera)^)
	defer NodeDef_Destroy(&copy)
	testing.expect(t, NodeDef_Equal(copy, nodeAt(&state, camera)^), "a clone is equal")
	copy.camera.follow.lookAhead.y = 5
	testing.expect(t, !NodeDef_Equal(copy, nodeAt(&state, camera)^), "a setting differs")
	copy.camera = nodeAt(&state, camera).camera
	delete(copy.cameraTarget)
	copy.cameraTarget = strings.clone("../Other")
	testing.expect(t, !NodeDef_Equal(copy, nodeAt(&state, camera)^), "the target differs")

	// Renaming the target, or a node on its path, keeps the path leading to it (one undo step)
	state.selectedNode = hero
	sendTo(&state, Node_Renamed("Player"))
	testing.expect_value(t, nodeAt(&state, camera).cameraTarget, "../Level/Player")
	state.selectedNode = level
	sendTo(&state, Node_Renamed("Stage"))
	testing.expect_value(t, nodeAt(&state, camera).cameraTarget, "../Stage/Player")
	sendTo(&state, Action.Undo)
	testing.expect(t, nodeAt(&state, camera).cameraTarget == "../Level/Player" && nodeAt(&state, level).name == "Level", "undoing the rename puts the path back")
	sendTo(&state, Action.Redo)
	// Moving the camera under the level, then the hero to the top: still the hero
	scene = &state.project.scenes[0]
	moved, ok := Scene_MoveNode(scene, camera, level, .Inside)
	testing.expect(t, ok, "moved")
	testing.expect_value(t, scene.nodes[moved].cameraTarget, "../Player")
	player := Scene_ResolvePath(scene, moved, scene.nodes[moved].cameraTarget)
	testing.expect(t, player >= 0 && scene.nodes[player].name == "Player", "leads to the hero")
	_, ok = Scene_MoveNode(scene, player, -1, .After)
	testing.expect(t, ok, "moved the hero")
	cam := -1
	for n, i in scene.nodes do if n.kind == .Camera do cam = i
	testing.expect_value(t, scene.nodes[cam].cameraTarget, "../../Player")

	// Saved and read back; the engine builds the camera with its settings
	before := scene.nodes[cam].camera
	beforePath := strings.clone(scene.nodes[cam].cameraTarget, context.temp_allocator)
	testing.expect_value(t, Project_Save(&state.project), "")
	text, _ := os.read_entire_file(joinPath(root, "scenes", "Main.scene.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expectf(t, strings.contains(string(text), `target="../../Player"`) && strings.contains(string(text), `limitLeft="-32"`) && !strings.contains(string(text), "limitTop"), "the file: %s", string(text))
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	for n in loaded.scenes[0].nodes do if n.kind == .Camera {
		testing.expectf(t, n.camera == before && n.cameraTarget == beforePath, "read back: %v %q", n.camera, n.cameraTarget)
	}
	data, err := e.ParseScene(string(text))
	defer e.SceneData_Destroy(&data)
	testing.expect_value(t, err, e.ProjectError.None)
	for n in data.nodes do if n.kind == .Camera do testing.expect(t, n.camera == before && n.cameraTarget == "../../Player", "the engine reads it")
	free_all(context.temp_allocator)
}
