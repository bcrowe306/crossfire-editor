package crossfire_editor

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

// The demo that ships with the editor (archives, the macOS bundle) copies and loads with its
// LDtk level: the scene's LDtkLevel node, its entity components, and the files exports need
@(test)
shipped_demo_copies_with_its_level :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_shipped_demo"
	removeAll(dir)
	defer removeAll(dir)
	root := joinPath(dir, "demo_project", allocator = context.temp_allocator)
	testing.expect_value(t, Folder_Copy(DEMO_PROJECT, root), "")

	project, message, _ := Project_Load(root)
	defer Project_Destroy(&project)
	testing.expect_value(t, message, "")
	forest := Project_FindScene(&project, "ForestScene")
	testing.expect(t, forest >= 0, "the forest scene")
	if forest < 0 do return
	level: ^NodeDef
	for &node in project.scenes[forest].nodes do if node.kind == .LDtkLevel do level = &node
	testing.expect(t, level != nil, "an LDtkLevel node")
	if level == nil do return
	testing.expect_value(t, level.ldtk.file, "assets/forest/forest.ldtk")
	testing.expect_value(t, level.ldtk.collisionLayer, "Collisions")
	testing.expect_value(t, len(level.ldtk.entityComponents), 8)
	for m in level.ldtk.entityComponents {
		testing.expectf(t, os.exists(joinPath(root, m.component, allocator = context.temp_allocator)), "%s's component %s", m.entity, m.component)
	}

	// The level's file reads, and an export takes its tilesets and background
	ldtk, problem := e.LDtk_Load(joinPath(root, level.ldtk.file, allocator = context.temp_allocator))
	testing.expect_value(t, problem, "")
	if ldtk != nil {
		testing.expect(t, e.LDtk_FindLevel(ldtk, "Forest") != nil, "the Forest level")
		e.LDtk_Destroy(ldtk)
	}
	files := LDtkEdit_ExportFiles(&project, context.temp_allocator)
	for name in ([]string{"assets/forest/tiles.png", "assets/forest/trees.png", "assets/forest/sky.png"}) {
		found := false
		for f in files do if f == name do found = true
		testing.expectf(t, found, "exports take %s (%v)", name, files)
	}
}

// Per entity type, what it becomes and the script it runs; per IntGrid value, what it becomes.
// Each choice is an undo step, saved and loaded back; Auto choices leave nothing in the file
@(test)
ldtk_entity_rules_and_collision_kinds_in_the_inspector :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_ldtk_rules"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := ldtkState(root)
	defer State_Destroy(&state)
	testing.expect_value(t, Project_Save(&state.project), "")
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/ldtk/world.ldtk")
	testing.expect_value(t, problem, "")
	if index < 0 do return
	path := state.project.assets[index].path
	nodeAt := Scene_AddLDtkAt(&state.project.scenes[0], path, -1, {})
	state.selectedNode = nodeAt
	settings :: proc(state: ^State, at: int) -> ^e.LDtkLevelSettings { return &state.project.scenes[0].nodes[at].ldtk }

	// Entities: Coin skipped, Player a rectangle running no script, then a named script
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Make, name = "Coin", text = LDTK_MAKE_LABELS[.Skip]})
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Make, name = "Player", text = LDTK_MAKE_LABELS[.Rectangle]})
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Script, name = "Player", text = LDTK_SCRIPT_NONE})
	testing.expect_value(t, e.LDtk_EntityMade(settings(&state, nodeAt), "Coin"), e.LDtkEntityMake.Skip)
	testing.expect_value(t, e.LDtk_EntityMade(settings(&state, nodeAt), "Player"), e.LDtkEntityMake.Rectangle)
	name, _ := e.LDtk_EntityScript(settings(&state, nodeAt), "Player", false)
	testing.expect_value(t, name, "")
	lines, bare := LDtkEdit_EntityPlan(&state, settings(&state, nodeAt), "Coin", nil)
	testing.expect(t, len(lines) == 1 && strings.contains(lines[0], "nothing") && !bare, "skipped")
	_, bare = LDtkEdit_EntityPlan(&state, settings(&state, nodeAt), "Player", nil)
	testing.expect(t, !bare, "a rectangle without a script, chosen: no warning")
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Script, name = "Player", text = "Hero"})
	name, _ = e.LDtk_EntityScript(settings(&state, nodeAt), "Player", false)
	testing.expect_value(t, name, "Hero")
	// A component chosen; undo takes it back to the rectangle
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Make, name = "Player", text = "components/hero.component.xml"})
	testing.expect_value(t, e.LDtk_EntityComponent(settings(&state, nodeAt), "Player"), "components/hero.component.xml")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, e.LDtk_EntityMade(settings(&state, nodeAt), "Player"), e.LDtkEntityMake.Rectangle)
	sendTo(&state, Action.Redo)

	// Collision: the Walls' value 1 an Area, then one-way; all solid again leaves no list
	sendTo(&state, LDtk_Setting_Changed{field = .Collision_Layer, text = "Walls"})
	sendTo(&state, LDtk_Setting_Changed{field = .Collision_Value_Kind, name = "1", text = LDTK_KIND_LABELS[.Area]})
	testing.expect_value(t, e.LDtk_CollisionKind(settings(&state, nodeAt), 1), e.LDtkCollisionKind.Area)
	testing.expect_value(t, len(settings(&state, nodeAt).collisionValues), 1)
	testing.expect_value(t, settings(&state, nodeAt).collisionValues[0], 0)
	sendTo(&state, LDtk_Setting_Changed{field = .Collision_Value_Kind, name = "1", text = LDTK_KIND_LABELS[.One_Way]})
	testing.expect_value(t, e.LDtk_CollisionKind(settings(&state, nodeAt), 1), e.LDtkCollisionKind.One_Way)
	testing.expect_value(t, len(settings(&state, nodeAt).areaValues), 0)

	// Saved and loaded: the same rules
	xml := SceneToXML(&state.project.scenes[0], context.temp_allocator)
	testing.expect(t, strings.contains(xml, `<entity name="Coin" make="Skip"/>`), xml)
	testing.expect(t, strings.contains(xml, `<entity name="Player" component="components/hero.component.xml" make="Component" script="Hero"/>`), xml)
	testing.expect(t, strings.contains(xml, `collisionValues="0"`) && strings.contains(xml, `oneWayValues="1"`), xml)
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	if len(loaded.scenes) > 0 && nodeAt < len(loaded.scenes[0].nodes) {
		testing.expect(t, LDtkSettings_Equal(loaded.scenes[0].nodes[nodeAt].ldtk, settings(&state, nodeAt)^), "round trip")
	}

	// Back to Auto: the rules and lists go
	sendTo(&state, LDtk_Setting_Changed{field = .Collision_Value_Kind, name = "1", text = LDTK_KIND_LABELS[.Solid]})
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Make, name = "Coin", text = LDTK_MAKE_LABELS[.Auto]})
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Make, name = "Player", text = LDTK_MAKE_LABELS[.Auto]})
	sendTo(&state, LDtk_Setting_Changed{field = .Entity_Script, name = "Player", text = LDTK_SCRIPT_AUTO})
	testing.expect_value(t, len(settings(&state, nodeAt).entityComponents), 0)
	testing.expect_value(t, len(settings(&state, nodeAt).collisionValues) + len(settings(&state, nodeAt).oneWayValues), 0)
	free_all(context.temp_allocator)
}

@(test)
ldtk_collision_shows_in_the_viewport :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_ldtk_shapes"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := ldtkState(root)
	defer State_Destroy(&state)
	testing.expect_value(t, Project_Save(&state.project), "")
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/ldtk/world.ldtk")
	testing.expect_value(t, problem, "")
	if index < 0 do return
	nodeAt := Scene_AddLDtkAt(&state.project.scenes[0], state.project.assets[index].path, -1, {})
	state.selectedNode = nodeAt
	// The fixture's level at 1:1, filling a 128 x 64 view; shapes shown (the editor's default)
	state.viewport = {center = {64, 32}, zoom = 1, size = {128, 64}, showShapes = true}
	SOLID :: [3]u8{120, 200, 120}
	near :: proc(pixels: []u8, rgb: [3]u8) -> int {
		count := 0
		for i := 0; i + 3 < len(pixels); i += 4 {
			if abs(int(pixels[i]) - int(rgb.r)) <= 8 && abs(int(pixels[i + 1]) - int(rgb.g)) <= 8 && abs(int(pixels[i + 2]) - int(rgb.b)) <= 8 do count += 1
		}
		return count
	}
	kinds :: proc(state: ^State) -> (counts: [GeneratedShapeKind]int) {
		for shape in Preview_GeneratedShapes(state, context.temp_allocator) do counts[shape.kind] += 1
		return
	}

	// No collision layer: nothing generated, nothing drawn
	pixels, ok := Preview_Render(&state, {128, 64}, 1)
	testing.expect(t, ok, "rendered")
	testing.expect_value(t, len(Preview_GeneratedShapes(&state, context.temp_allocator)), 0)
	if ok do testing.expect_value(t, near(pixels, SOLID), 0)

	// The Walls layer: the floor and two walls, merged into 3 rectangles, where the cells are
	sendTo(&state, LDtk_Setting_Changed{field = .Collision_Layer, text = "Walls"})
	pixels, ok = Preview_Render(&state, {128, 64}, 1)
	shapes := Preview_GeneratedShapes(&state, context.temp_allocator)
	testing.expect_value(t, len(shapes), 3)
	floor := false
	for shape in shapes {
		testing.expect(t, shape.owner == nodeAt && shape.kind == .Solid, "solid, from the level node")
		if shape.corners[0] == {16, 48} && shape.corners[2] == {112, 64} do floor = true
	}
	testing.expect(t, floor, "the floor's cells 1-6 of the bottom row")
	if ok do testing.expectf(t, near(pixels, SOLID) > 50, "outlined in green: %d pixels", near(pixels, SOLID))
	// Moved with its node
	state.project.scenes[0].nodes[nodeAt].position = {8, 0}
	pixels, ok = Preview_Render(&state, {128, 64}, 1)
	floor = false
	for shape in Preview_GeneratedShapes(&state, context.temp_allocator) do if shape.corners[0] == {24, 48} do floor = true
	testing.expect(t, floor, "the floor moved with the node")
	state.project.scenes[0].nodes[nodeAt].position = {}

	// Hidden with the viewport's toggle (the picture changes: a new frame key); shown again
	key := Preview_FrameKey(&state, {128, 64}, 1)
	sendTo(&state, Action.Toggle_Collision_Shapes)
	testing.expect(t, !state.viewport.showShapes, "off")
	testing.expect(t, Preview_FrameKey(&state, {128, 64}, 1) != key, "a new picture")
	pixels, ok = Preview_Render(&state, {128, 64}, 1)
	if ok do testing.expect_value(t, near(pixels, SOLID), 0)
	sendTo(&state, Action.Toggle_Collision_Shapes)

	// One-way, then an Area: their own kinds and colors; undo takes the kind back
	sendTo(&state, LDtk_Setting_Changed{field = .Collision_Value_Kind, name = "1", text = LDTK_KIND_LABELS[.One_Way]})
	pixels, ok = Preview_Render(&state, {128, 64}, 1)
	counts := kinds(&state)
	testing.expectf(t, counts[.One_Way] == 3 && counts[.Solid] == 0, "one-way: %v", counts)
	if ok do testing.expect(t, near(pixels, GENERATED_SHAPE_COLORS[.One_Way]) > 50 && near(pixels, SOLID) == 0, "drawn amber")
	sendTo(&state, LDtk_Setting_Changed{field = .Collision_Value_Kind, name = "1", text = LDTK_KIND_LABELS[.Area]})
	pixels, ok = Preview_Render(&state, {128, 64}, 1)
	counts = kinds(&state)
	testing.expectf(t, counts[.Area] == 3 && counts[.One_Way] == 0, "an area: %v", counts)
	if ok do testing.expect(t, near(pixels, GENERATED_SHAPE_COLORS[.Area]) > 50, "drawn purple")
	sendTo(&state, Action.Undo)
	Preview_Render(&state, {128, 64}, 1)
	counts = kinds(&state)
	testing.expectf(t, counts[.One_Way] == 3, "undone: one-way again: %v", counts)

	// A hidden level node shows none
	state.project.scenes[0].nodes[nodeAt].visible = false
	Preview_Render(&state, {128, 64}, 1)
	testing.expect_value(t, len(Preview_GeneratedShapes(&state, context.temp_allocator)), 0)
	free_all(context.temp_allocator)
}
