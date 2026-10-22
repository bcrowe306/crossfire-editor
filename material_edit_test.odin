package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"
import stbi "vendor:stb/image"

// Physics materials (material_edit.odin) and collision from sprites (collision_trace_edit.odin)
// in the editor: made, edited, undone, given to a body, saved and read back; shapes traced from
// a sprite, replaced when traced again, undone

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
		materialSelection = -1, trace = DEFAULT_TRACE_SETTINGS}
	state.settings.builtInCodeEditor = false
	testing.expect_value(nil, Project_Save(&state.project), "")
	return state
}

@(test)
physics_materials_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_materials"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)

	// New Material from the browser: a file, an asset, shown in the inspector
	sendTo(&state, Material_Created{})
	testing.expect_value(t, len(state.project.materials), 1)
	path := state.project.materials[0].path
	testing.expect_value(t, path, "materials/material.material.xml")
	testing.expect(t, os.exists(joinPath(state.project.rootPath, path, allocator = context.temp_allocator)), "its file")
	testing.expect_value(t, state.materialSelection, 0)
	testing.expect(t, state.project.materials[0].material == {friction = 0.6, restitution = 0, density = 1}, "a body's defaults")

	// Edited, undone, redone
	sendTo(&state, Material_Field_Changed{.Friction, 0.05})
	sendTo(&state, Material_Field_Changed{.Restitution, 0.8})
	testing.expect(t, state.project.materials[0].material.friction == 0.05 && state.project.materials[0].material.restitution == 0.8, "edited")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.materials[0].material.restitution, f32(0))
	sendTo(&state, Action.Redo)
	testing.expect_value(t, state.project.materials[0].material.restitution, f32(0.8))

	// A body uses it (its inspector's choice)
	scene := &state.project.scenes[0]
	body := Scene_InsertNode(scene, "Puck", .DynamicBody, -1)
	state.selectedNode = body
	sendTo(&state, Node_Text_Changed{.Material, path})
	testing.expect_value(t, state.project.scenes[0].nodes[body].material, path)
	testing.expect_value(t, Material_Users(&state.project, path), 1)
	// From a body's inspector, New Material gives the body the new one
	sendTo(&state, Material_Created{forSelected = true})
	testing.expect_value(t, state.project.scenes[0].nodes[body].material, "materials/material_2.material.xml")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[0].nodes[body].material, path)

	// Saved and read back: the file's values and the body's attribute
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(state.project.rootPath)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	i := Project_FindMaterial(&loaded, path)
	testing.expect(t, i >= 0 && loaded.materials[i].material.friction == 0.05 && loaded.materials[i].material.restitution == 0.8, "the material's values")
	testing.expect_value(t, loaded.scenes[0].nodes[body].material, path)
	text, _ := os.read_entire_file(joinPath(state.project.rootPath, "scenes/Main.scene.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(text), `material="materials/material.material.xml"`), "the scene file names it")
}

@(test)
collision_from_a_sprite_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_trace"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	// An L, 20 x 10 px: the left half full height, the bottom half full width
	pixels := make([]u8, 20 * 10 * 4, context.temp_allocator)
	for y in 0 ..< 10 do for x in 0 ..< 20 do if x < 10 || y >= 5 do pixels[(y * 20 + x) * 4 + 3] = 255
	os.make_directory(joinPath(state.project.rootPath, "assets", allocator = context.temp_allocator))
	png := strings.clone_to_cstring(joinPath(state.project.rootPath, "assets/l.png", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, stbi.write_png(png, 20, 10, 4, raw_data(pixels), 20 * 4) != 0, "the fixture")

	scene := &state.project.scenes[0]
	body := Scene_InsertNode(scene, "Rock", .StaticBody, -1)
	sprite := Scene_InsertNode(scene, "Art", .Sprite, body)
	scene.nodes[sprite].texture = strings.clone("assets/l.png")
	scene.nodes[sprite].scale = {2, 2}
	testing.expect_value(t, len(Trace_Sprites(scene, body)), 1)

	state.selectedNode = body
	state.trace.detail = 0
	sendTo(&state, Collision_Traced{})
	scene = &state.project.scenes[0]
	traced := 0
	area: f32
	for n in scene.nodes {
		if n.parent != body || n.kind != .CollisionShape do continue
		testing.expect(t, n.shape == .Polygon && strings.has_prefix(n.name, "Traced") && len(n.points) <= 8, "traced polygons")
		for p in n.points do testing.expect(t, abs(p.x) <= 20 && abs(p.y) <= 10, "scaled 2x like the sprite, centered")
		pts := n.points[:]
		a: f32
		for p, i in pts { q := pts[(i + 1) % len(pts)]; a += p.x * q.y - q.x * p.y }
		area += a / 2
		traced += 1
	}
	testing.expect(t, traced >= 2, "an L needs two pieces")
	testing.expect_value(t, area, f32(150 * 4))

	// Traced again: the earlier shapes are replaced, not added to
	count := len(scene.nodes)
	sendTo(&state, Collision_Traced{})
	testing.expect_value(t, len(state.project.scenes[0].nodes), count)
	// One undo step each
	sendTo(&state, Action.Undo)
	sendTo(&state, Action.Undo)
	shapes := 0
	for n in state.project.scenes[0].nodes do if n.kind == .CollisionShape do shapes += 1
	testing.expect_value(t, shapes, 0)
}
