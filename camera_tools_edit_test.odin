package crossfire_editor

import "core:os"
import "core:sync"
import "core:testing"
import e "engine:."

// Camera tools in the editor: a parallax layer, a camera zone and a camera view edited and undone,
// built in the viewport, saved and read back

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
camera_tools_in_the_editor :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_camera_tools"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	scene := &state.project.scenes[0]
	layer := Scene_InsertNode(scene, "Hills", .ParallaxLayer, -1)
	zone := Scene_InsertNode(scene, "Room", .CameraZone, -1)
	camera := Scene_InsertNode(scene, "MapCam", .Camera, -1)
	view := Scene_InsertNode(scene, "Map", .CameraView, -1)
	testing.expect(t, scene.nodes[zone].shapeSize == {640, 360} && scene.nodes[view].shapeSize == {160, 90}, "default sizes")
	nodeAt :: proc(state: ^State, i: int) -> ^NodeDef { return &state.project.scenes[0].nodes[i] }

	state.selectedNode = layer
	sendTo(&state, Camera_Tool_Changed{field = .Factor_X, value = 0.3})
	sendTo(&state, Camera_Tool_Changed{field = .Repeat_X, flag = true})
	testing.expect(t, nodeAt(&state, layer).cameraTools.factor.x == 0.3 && nodeAt(&state, layer).cameraTools.repeatX, "the layer")
	sendTo(&state, Action.Undo)
	testing.expect(t, !nodeAt(&state, layer).cameraTools.repeatX, "undone")
	sendTo(&state, Action.Redo)
	state.selectedNode = zone
	sendTo(&state, NumberTarget_Msg(CameraToolNumber(CameraToolField.Transition), 1.5))
	testing.expect_value(t, nodeAt(&state, zone).cameraTools.transition, f32(1.5))
	state.selectedNode = view
	path := Scene_NodePath(&state.project.scenes[0], view, camera, context.temp_allocator)
	sendTo(&state, Camera_Tool_Changed{field = .Camera, text = path})
	sendTo(&state, NumberTarget_Msg(CameraToolNumber(CameraToolField.Zoom), 0.25))
	testing.expect(t, nodeAt(&state, view).viewCamera == path && nodeAt(&state, view).cameraTools.zoom == 0.25, "the view")

	// Built in the viewport: the engine's nodes with their settings
	_, ok := Preview_Render(&state, {64, 64}, 1)
	testing.expect(t, ok, "rendered")
	built := Preview_Node(view)
	testing.expect(t, built != nil && e.Node_Is(built, e.CameraView), "a built CameraView")
	if built != nil && e.Node_Is(built, e.CameraView) {
		v := cast(^e.CameraView)built
		testing.expect(t, v.cameraPath == path && v.settings.zoom == 0.25 && v.size == {160, 90}, "its settings")
	}

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	for n, i in loaded.scenes[0].nodes {
		original := nodeAt(&state, i)
		testing.expectf(t, n.cameraTools == original.cameraTools && n.viewCamera == original.viewCamera, "%s", n.name)
		if n.kind == .CameraZone || n.kind == .CameraView do testing.expect_value(t, n.shapeSize, original.shapeSize)
	}
}
