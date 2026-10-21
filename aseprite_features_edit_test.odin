package crossfire_editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import e "engine:."

// Aseprite's slices, layers and events in the editor: a sprite's layers ticked, its pivot and
// 9-patch slices, a hitbox following a slice in the viewport, frame events in the Animation panel,
// an animated TileMap; saved and loaded

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
aseprite_slices_layers_and_events_in_the_editor :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_aseprite_features"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	testing.expect_value(t, Project_Save(&state.project), "")
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/aseprite/features.aseprite")
	testing.expect_value(t, problem, "")
	if index < 0 do return
	path := state.project.assets[index].path
	scene := &state.project.scenes[0]

	// A sprite of it: Body unticked (Sword stays: the hidden events layer isn't drawn)
	sprite := Scene_AddSpriteAt(scene, path, -1, {0, 0})
	state.selectedNode = sprite
	testing.expect_value(t, AsepriteEdit_NodeSource(&scene.nodes[sprite]), path)
	sendTo(&state, Aseprite_Layer_Toggled{"Body", false})
	testing.expect_value(t, state.project.scenes[0].nodes[sprite].asepriteLayers, "Sword")
	sendTo(&state, Aseprite_Layer_Toggled{"Sword", false})
	testing.expect_value(t, state.project.scenes[0].nodes[sprite].asepriteLayers, "Sword")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[0].nodes[sprite].asepriteLayers, "")
	sendTo(&state, Action.Redo)
	// Its pivot and 9-patch
	sendTo(&state, Node_Text_Changed{.Pivot_Slice, "feet"})
	sendTo(&state, Node_Text_Changed{.Nine_Slice, "panel"})
	sendTo(&state, Node_Field_Changed{.Nine_Width, 40})
	node := &state.project.scenes[0].nodes[sprite]
	testing.expect(t, node.pivotSlice == "feet" && node.nineSlice == "panel" && node.nineSize.x == 40, "its slices")
	sendTo(&state, Node_Text_Changed{.Nine_Slice, SLICE_NONE})

	// A body whose shape follows the hitbox slice of a sprite beside it
	scene = &state.project.scenes[0]
	body := Scene_InsertNode(scene, "Hero", .StaticBody, -1)
	heroSprite := Scene_InsertNode(scene, "Sprite", .Sprite, body)
	delete(scene.nodes[heroSprite].texture)
	scene.nodes[heroSprite].texture = strings.clone(path)
	shape := Scene_InsertNode(scene, "Hit", .CollisionShape, body)
	testing.expect_value(t, AsepriteEdit_ShapeSprite(scene, shape), heroSprite)
	state.selectedNode = shape
	sendTo(&state, Node_Text_Changed{.Slice, "hitbox"})
	testing.expect_value(t, state.project.scenes[0].nodes[shape].slice, "hitbox")

	// An animated sprite of it: its tag's frame events, read only in the panel
	scene = &state.project.scenes[0]
	hero := Scene_AddAnimatedSpriteAt(scene, path, -1, {0, 0})
	state.selectedNode = hero
	src := AnimEdit_Source(&state)
	testing.expect(t, src.kind == .Aseprite && len(src.animations^) == 1, "its tag")
	if src.kind == .Aseprite && len(src.animations^) == 1 {
		events := src.animations[0].events
		testing.expect(t, len(events) == 3 && events[0] == "" && events[1] == "step" && events[2] == "hit", "its events")
	}

	// An animated TileMap
	tm, tmProblem := Project_ImportAsset(&state.project, "tests/fixtures/aseprite/tilemap_animated.aseprite")
	testing.expect_value(t, tmProblem, "")
	scene = &state.project.scenes[0]
	water := Scene_AddTileMapAt(scene, state.project.assets[tm].path, -1, {0, 0})
	state.selectedNode = water
	sendTo(&state, TileMap_Setting_Changed{field = .Animate, flag = true})
	sendTo(&state, TileMap_Setting_Changed{field = .Tag, text = "flow"})
	testing.expect(t, state.project.scenes[0].nodes[water].tilemap.animate && state.project.scenes[0].nodes[water].tilemap.tag == "flow", "it plays its tag")

	// The viewport: the hitbox in place (the slice at 10, 6, 4 x 4 of the 16 x 16 picture,
	// centered on the sprite: 4, 0 from it), the sprite's pivot
	state.viewport = {center = {0, 0}, zoom = 1, size = {64, 64}}
	_, ok := Preview_Render(&state, {64, 64}, 1)
	testing.expect(t, ok, "rendered")
	if built := Preview_Node(shape); built != nil {
		hit := cast(^e.CollisionShape)built
		testing.expectf(t, hit.position == {4, 0} && hit.size == {4, 4}, "the hitbox: %v, %v", hit.position, hit.size)
	} else {
		testing.expect(t, false, "the hitbox was built")
	}
	if built := Preview_Node(sprite); built != nil {
		bounds, _ := e.Node_GetLocalBounds(built)
		testing.expect_value(t, bounds.x, f32(-8))
		testing.expect_value(t, bounds.y, f32(-16))
	}

	// Saved and loaded: the same settings
	xml := SceneToXML(&state.project.scenes[0], context.temp_allocator)
	testing.expect(t, strings.contains(xml, `layers="Sword"`) && strings.contains(xml, `pivotSlice="feet"`) && strings.contains(xml, `slice="hitbox"`) &&
		strings.contains(xml, `animate="true"`) && strings.contains(xml, `tag="flow"`), xml)
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	a, b := &loaded.scenes[0].nodes, &state.project.scenes[0].nodes
	testing.expect(t, a[sprite].asepriteLayers == b[sprite].asepriteLayers && a[sprite].pivotSlice == b[sprite].pivotSlice, "the sprite")
	testing.expect_value(t, a[shape].slice, "hitbox")
	testing.expect(t, TileMapSettings_Equal(a[water].tilemap, b[water].tilemap), "the TileMap")
	free_all(context.temp_allocator)
}
