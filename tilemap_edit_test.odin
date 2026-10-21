package crossfire_editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// TileMap nodes in the editor: dropped from an Aseprite file with tilemap layers, set up in the
// inspector (layers, frame, collision: undoable), what each layer becomes, saved and loaded,
// drawn in the viewport

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
tilemaps_in_the_editor :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_tilemaps"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	testing.expect_value(t, Project_Save(&state.project), "")
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/aseprite/tilemap.aseprite")
	testing.expect_value(t, problem, "")
	if index < 0 do return
	path := state.project.assets[index].path
	testing.expect(t, TileMapEdit_HasTilemaps(root, path), "it has tilemap layers")
	other, _ := Project_ImportAsset(&state.project, "tests/fixtures/aseprite/tags3.aseprite")
	testing.expect(t, !TileMapEdit_HasTilemaps(root, state.project.assets[other].path), "a sprite has none")

	// Dropped into the viewport: a TileMap of it
	state.assetDrag = {asset = index, pressed = true, active = true}
	sendTo(&state, Asset_Dropped{world = {10.4, 20.6}})
	scene := &state.project.scenes[0]
	at := state.selectedNode
	testing.expect(t, at >= 0 && scene.nodes[at].kind == .TileMap, "a TileMap")
	if at < 0 do return
	testing.expect_value(t, scene.nodes[at].tilemap.file, path)
	testing.expect_value(t, scene.nodes[at].position, [2]f32{10, 20})

	// What its layer becomes, as the engine builds it
	ase := AsepriteEdit_File(root, path)
	info := TileMapEdit_LayerInfo(ase, 0, 0)
	testing.expectf(t, strings.contains(info, "4 x 2 tiles of 4 x 4") && strings.contains(info, "4 solid") && strings.contains(info, "1 one-way") && strings.contains(info, "2 in spikes"), "info: %s", info)

	// The inspector's settings: a layer ticked, collision off; undone
	sendTo(&state, TileMap_Setting_Changed{field = .Layer, text = "Ground", flag = true})
	testing.expect_value(t, state.project.scenes[0].nodes[at].tilemap.layers, "Ground")
	sendTo(&state, TileMap_Setting_Changed{field = .Collision, flag = false})
	testing.expect(t, !state.project.scenes[0].nodes[at].tilemap.collision, "no collision")
	sendTo(&state, Action.Undo)
	testing.expect(t, state.project.scenes[0].nodes[at].tilemap.collision, "undone")
	sendTo(&state, Action.Redo)
	xml := SceneToXML(&state.project.scenes[0], context.temp_allocator)
	testing.expect(t, strings.contains(xml, `kind="TileMap"`) && strings.contains(xml, `tilemap="assets/tilemap.aseprite"`) && strings.contains(xml, `layers="Ground"`) && strings.contains(xml, `tileCollision="false"`), xml)
	sendTo(&state, TileMap_Setting_Changed{field = .Collision, flag = true})
	// The hidden layer too (in the file's order), then not the first; the last one stays
	sendTo(&state, TileMap_Setting_Changed{field = .Layer, text = "Decor", flag = true})
	testing.expect_value(t, state.project.scenes[0].nodes[at].tilemap.layers, "Ground,Decor")
	sendTo(&state, TileMap_Setting_Changed{field = .Layer, text = "Ground", flag = false})
	testing.expect_value(t, state.project.scenes[0].nodes[at].tilemap.layers, "Decor")
	sendTo(&state, TileMap_Setting_Changed{field = .Layer, text = "Decor", flag = false})
	testing.expect_value(t, state.project.scenes[0].nodes[at].tilemap.layers, "Decor")
	sendTo(&state, TileMap_Setting_Changed{field = .Layer, text = "Ground", flag = true})

	// Saved and opened again
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, TileMapSettings_Equal(loaded.scenes[0].nodes[at].tilemap, state.project.scenes[0].nodes[at].tilemap), "the same settings")

	// Drawn in the viewport: the red half of a solid tile, at 1:1 from the node's corner
	state.viewport = {center = {18, 24}, zoom = 1, size = {16, 8}}
	pixels, ok := Preview_Render(&state, {16, 8}, 1)
	testing.expect(t, ok, "rendered")
	if ok {
		p := pixels[(1 * 16 + 1) * 4:][:4]
		testing.expectf(t, p[0] > 200 && p[1] < 50 && p[2] < 50, "red at the first tile: %v", p)
		p = pixels[(1 * 16 + 2) * 4:][:4]
		testing.expectf(t, p[2] > 200 && p[0] < 50, "then blue: %v", p)
	}
	free_all(context.temp_allocator)
}
