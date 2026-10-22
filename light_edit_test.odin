package crossfire_editor

import "core:os"
import "core:sync"
import "core:testing"
import e "engine:."

// 2D lighting in the editor: a scene lit, a light and an occluder edited and undone, saved and
// read back, the viewport dark outside the light (and unlit when asked)

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
lighting_in_the_editor :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_light_edit"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, themeSelection = -1, dataSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	// A white game area, so the light map's darkness shows
	state.project.background = {255, 255, 255, 255}
	scene := &state.project.scenes[0]
	lamp := Scene_InsertNode(scene, "Lamp", .Light2D, -1)
	wall := Scene_InsertNode(scene, "Wall", .LightOccluder, -1)
	scene.nodes[wall].position = {20, 0}
	scene.nodes[wall].shapeSize = {4, 40}

	// The scene lit (a project step)
	sendTo(&state, Scene_Lighting_Changed{0, true, {0, 0, 0, 255}, false})
	testing.expect(t, state.project.scenes[0].settings.lighting, "lit")
	sendTo(&state, Action.Undo)
	testing.expect(t, !state.project.scenes[0].settings.lighting, "undone")
	sendTo(&state, Action.Redo)

	// The light: a short reach
	state.selectedNode = lamp
	sendTo(&state, Light_Setting_Changed{field = .Radius, value = 30})
	sendTo(&state, Light_Setting_Changed{field = .Color, text = "#ffffff"})
	sendTo(&state, Light_Setting_Changed{field = .Kind, text = "Spot"})
	l := state.project.scenes[0].nodes[lamp].light
	testing.expect(t, l.radius == 30 && l.color == {255, 255, 255, 255} && l.kind == .Spot, "edited")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[0].nodes[lamp].light.kind, e.LightKind.Point)

	// The viewport (centered on the lamp, 1:1): bright at the lamp, dark past its reach and
	// behind the wall; all white unlit
	state.viewport = {center = {0, 0}, zoom = 1, size = {80, 80}}
	pixel :: proc(pixels: []u8, x, y: int) -> u8 { return pixels[(y * 80 + x) * 4] }
	pixels, ok := Preview_Render(&state, {80, 80}, 1)
	testing.expect(t, ok, "rendered")
	if ok {
		testing.expectf(t, pixel(pixels, 40, 40) > 200, "at the lamp: %d", pixel(pixels, 40, 40))
		testing.expectf(t, pixel(pixels, 40, 75) < 10, "past its reach: %d", pixel(pixels, 40, 75))
		testing.expectf(t, pixel(pixels, 65, 40) < 10, "behind the wall: %d", pixel(pixels, 65, 40))
	}
	sendTo(&state, Action.Toggle_Lighting)
	pixels, ok = Preview_Render(&state, {80, 80}, 1)
	if ok do testing.expectf(t, pixel(pixels, 40, 75) > 240, "unlit: %d", pixel(pixels, 40, 75))
	sendTo(&state, Action.Toggle_Lighting)

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, loaded.scenes[0].settings == state.project.scenes[0].settings, "the scene's lighting")
	for n, i in loaded.scenes[0].nodes {
		original := state.project.scenes[0].nodes[i]
		testing.expectf(t, n.light == original.light && n.shape == original.shape && n.shapeSize == original.shapeSize, "%s", n.name)
	}
	free_all(context.temp_allocator)
}
