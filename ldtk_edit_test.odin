package editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import e "engine:."

// LDtk in the editor: importing with the files a project needs, LDtkLevel nodes' settings
// (messages, undo, saving and loading), exports and the assets file

@(private="file")
ldtkState :: proc(root: string) -> State {
	project := Project_CreateEmpty(root, "Levels")
	state := State{
		project = project,
		browserSelection = {kind = .None},
		selectedNode = -1,
		layout = {bottomOpen = true},
		settings = Settings_Default(),
	}
	state.settings.builtInCodeEditor = false
	return state
}

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
ldtk_import_settings_and_export :: proc(t: ^testing.T) {
	// It renders a thumbnail: the preview's package state is shared
	sync.guard(&previewTestLock)
	os.make_directory("build")
	dir := "build/test_ldtk"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := ldtkState(root)
	defer State_Destroy(&state)
	testing.expect_value(t, Project_Save(&state.project), "")

	// Imported from outside: into assets/world/, with its tileset beside it
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/ldtk/world.ldtk")
	testing.expect_value(t, problem, "")
	if index < 0 do return
	asset := state.project.assets[index]
	testing.expect_value(t, asset.kind, AssetKind.LDtk)
	testing.expect_value(t, asset.path, "assets/world/world.ldtk")
	testing.expect(t, os.exists(joinPath(root, "assets/world/tiles.png", allocator = context.temp_allocator)), "the tileset came along")
	testing.expect_value(t, AssetFolder(asset.kind), BrowserFolder.Levels)

	// The inspector's copy reads it: one level, the Walls IntGrid
	project := LDtkEdit_Project(root, asset.path)
	testing.expect(t, project != nil, "parsed")
	if project != nil {
		testing.expect_value(t, project.worlds[0].levels[0].identifier, "Level_0")
		testing.expect(t, e.LDtk_FindLayerDef(project, "Walls") != nil, "its layers")
	}

	// A node dropped into the viewport, then set up in the inspector
	scene := &state.project.scenes[0]
	nodeAt := Scene_AddLDtkAt(scene, asset.path, -1, {32.7, 64.2})
	state.selectedNode = nodeAt
	node := &scene.nodes[nodeAt]
	testing.expect_value(t, node.kind, NodeKind.LDtkLevel)
	testing.expect_value(t, node.position, [2]f32{32, 64})
	testing.expect(t, node.ldtk.spawnEntities && node.ldtk.background, "the defaults")
	sendTo(&state, LDtk_Setting_Changed{field = .Collision_Layer, text = "Walls"})
	sendTo(&state, LDtk_Setting_Changed{field = .Collision_Values, text = "1, 3 x"})
	sendTo(&state, LDtk_Setting_Changed{field = .Level, text = "Level_0"})
	sendTo(&state, LDtk_Setting_Changed{field = .Smooth_Tiles, flag = true})
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Component, name = "Coin", text = "components/coin.component.xml"})
	node = &state.project.scenes[0].nodes[nodeAt]
	testing.expect_value(t, node.ldtk.collisionLayer, "Walls")
	testing.expect_value(t, len(node.ldtk.collisionValues), 2)
	testing.expect_value(t, node.ldtk.entityComponents[0].entity, "Coin")
	testing.expect(t, node.ldtk.smoothTiles, "smooth")

	// Undo takes the last change back
	sendTo(&state, Action.Undo)
	node = &state.project.scenes[0].nodes[nodeAt]
	testing.expect_value(t, len(node.ldtk.entityComponents), 0)
	sendTo(&state, Action.Redo)
	node = &state.project.scenes[0].nodes[nodeAt]
	testing.expect_value(t, len(node.ldtk.entityComponents), 1)
	// No component: the mapping goes
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Component, name = "Coin", text = TEXTURE_NONE})
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Component, name = "Coin", text = "components/coin.component.xml"})

	// Saved and opened again: the same settings
	xml := SceneToXML(&state.project.scenes[0], context.temp_allocator)
	testing.expect(t, strings.contains(xml, `kind="LDtkLevel"`) && strings.contains(xml, `ldtk="assets/world/world.ldtk"`), xml)
	testing.expect(t, strings.contains(xml, `intGridCollision="Walls"`) && strings.contains(xml, `collisionValues="1 3"`), xml)
	testing.expect(t, strings.contains(xml, `<entity name="Coin" component="components/coin.component.xml"/>`), xml)
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	if len(loaded.scenes) > 0 && nodeAt < len(loaded.scenes[0].nodes) {
		testing.expect(t, LDtkSettings_Equal(loaded.scenes[0].nodes[nodeAt].ldtk, state.project.scenes[0].nodes[nodeAt].ldtk), "round trip")
	}
	testing.expect_value(t, loaded.assets[0].kind, AssetKind.LDtk)

	// Exports ship the tileset; scripts get a constant
	files := Export_ProjectFiles(&state.project, context.temp_allocator)
	found := false
	for f in files do if f == "assets/world/tiles.png" do found = true
	testing.expect(t, found, "the tileset is exported")
	testing.expect(t, strings.contains(Scripts_AssetsSource(&state.project), `LDTK_WORLD :: e.LDtkAsset{"assets/world/world.ldtk"}`), "the LDTK_ constant")

	// A picture of the level for the inspector: the tileset's stone and grass show (not just the
	// background), and the same request is cached
	pixels, key, ok := Preview_RenderLDtk(&state, .Inspector, asset.path, "", false, {128, 64})
	testing.expect(t, ok, "the level renders")
	if ok {
		stone, grass := 0, 0
		for i := 0; i + 3 < len(pixels); i += 4 {
			r, g, b := int(pixels[i]), int(pixels[i + 1]), int(pixels[i + 2])
			if abs(r - 110) < 30 && abs(g - 110) < 30 && abs(b - 120) < 30 do stone += 1
			if g > 140 && r < 110 && b < 110 do grass += 1
		}
		testing.expectf(t, stone > 100 && grass > 20, "stone %d, grass %d pixels", stone, grass)
		_, again, _ := Preview_RenderLDtk(&state, .Inspector, asset.path, "", false, {128, 64})
		testing.expect_value(t, again, key)
	}
	defer Preview_Destroy()

	// Copying the node copies its settings
	copy := NodeDef_Clone(state.project.scenes[0].nodes[nodeAt])
	defer NodeDef_Destroy(&copy)
	testing.expect(t, LDtkSettings_Equal(copy.ldtk, state.project.scenes[0].nodes[nodeAt].ldtk), "a copy")
	free_all(context.temp_allocator)
}

@(test)
ldtk_import_brings_outside_files_in :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_ldtk_outside"
	removeAll(dir)
	defer removeAll(dir)
	// An LDtk project whose tileset is in a sibling folder
	_ = os.make_directory_all(joinPath(dir, "art", allocator = context.temp_allocator))
	_ = os.make_directory_all(joinPath(dir, "levels", allocator = context.temp_allocator))
	png, _ := os.read_entire_file("tests/fixtures/ldtk/tiles.png", context.temp_allocator)
	_ = os.write_entire_file(joinPath(dir, "art/tiles.png", allocator = context.temp_allocator), png)
	text, _ := os.read_entire_file("tests/fixtures/ldtk/world.ldtk", context.temp_allocator)
	moved, _ := strings.replace_all(string(text), `"tiles.png"`, `"../art/tiles.png"`, context.temp_allocator)
	_ = os.write_entire_file(joinPath(dir, "levels/world.ldtk", allocator = context.temp_allocator), transmute([]byte)moved)

	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := ldtkState(root)
	defer State_Destroy(&state)
	testing.expect_value(t, Project_Save(&state.project), "")
	index, problem := Project_ImportAsset(&state.project, joinPath(dir, "levels/world.ldtk", allocator = context.temp_allocator))
	testing.expect_value(t, problem, "")
	if index < 0 do return
	testing.expect(t, os.exists(joinPath(root, "assets/world/external/tiles.png", allocator = context.temp_allocator)), "into external/")
	copied, _ := os.read_entire_file(joinPath(root, "assets/world/world.ldtk", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(copied), `"external/tiles.png"`) && !strings.contains(string(copied), `../art`), "the copy points there")
	project := LDtkEdit_Project(root, state.project.assets[index].path)
	testing.expect(t, project != nil && strings.has_suffix(project.tilesets[0].path, "external/tiles.png"), "and reads")
	free_all(context.temp_allocator)
}
