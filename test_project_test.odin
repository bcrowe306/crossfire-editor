package crossfire_editor

import e "engine:."
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

/*
The unit tests' sample project (it was the built-in demo before the demo became a platformer):
a menu, a play scene with a tree of sprites and animations to edit (World, Camera, Spaceship and
its ShipLight, Props and four animated children, a HUD with a menu), and an options screen. Its
image paths are the UI fixture's (tests/fixtures/ui_project/assets).

Inputs:
- rootPath: Folder the project is saved in

Returns:
- The project. Its strings are heap-allocated and owned by the project
*/
Project_CreateTestProject :: proc(rootPath: string) -> Project {
	project := Project{
		name = strings.clone("Test Game"),
		rootPath = strings.clone(rootPath),
		gameSize = {1280, 720},
		scaleMode = .Letterbox,
		background = {15, 18, 30, 255},
		startScene = strings.clone("MenuScene"),
		physics = e.DEFAULT_PHYSICS,
		window = e.DEFAULT_WINDOW_SETTINGS,
		grid = e.DEFAULT_GRID_SETTINGS,
		players = e.DEFAULT_PLAYER_SETTINGS,
		audioOutput = e.DEFAULT_AUDIO_OUTPUT,
		exports = ExportSettings_Default(),
	}
	TITLE_COLOR :: sdl.Color{235, 240, 255, 255}
	TEXT_COLOR :: sdl.Color{150, 160, 185, 255}

	menu := SceneDef{name = strings.clone("MenuScene")}
	fixtureText(&menu, fixtureNode(&menu, "Title", .Label, -1, {640, 180}), "ASTEROIDS", 80, TITLE_COLOR)
	mainMenu := fixtureNode(&menu, "MainMenu", .Menu, -1, {640, 320})
	fixtureItem(&menu, mainMenu, "Play", "scene:PlayScene")
	fixtureItem(&menu, mainMenu, "Options", "scene:OptionsScene")
	fixtureItem(&menu, mainMenu, "Quit", "quit")
	append(&project.scenes, menu)

	play := SceneDef{name = strings.clone("PlayScene")}
	// Positions are relative to the parent
	world := fixtureNode(&play, "World", .Node2D, -1, {0, 0})
	fixtureNode(&play, "Camera", .Camera, world, {640, 360})
	ship := fixtureNode(&play, "Spaceship", .Sprite, world, {640, 430})
	fixtureTexture(&play, ship, "assets/ship.png")
	// Rides along with the ship
	fixtureAnimation(&play, fixtureNode(&play, "ShipLight", .AnimatedSprite, ship, {0, 60}), "assets/light.png", 2, 1, 4, .Forward)
	play.nodes[len(play.nodes) - 1].scale = {0.4, 0.4}
	props := fixtureNode(&play, "Props", .Node2D, world, {640, 360})
	fixtureAnimation(&play, fixtureNode(&play, "Balloon", .AnimatedSprite, props, {-340, -60}), "assets/balloons.png", 4, 1, 3, .Forward)
	fixtureAnimation(&play, fixtureNode(&play, "BalloonPingPong", .AnimatedSprite, props, {340, -100}), "assets/balloons.png", 4, 1, 5, .PingPong)
	fixtureAnimation(&play, fixtureNode(&play, "WarningLight", .AnimatedSprite, props, {-480, 260}), "assets/light.png", 2, 1, 2, .Forward)
	fixtureAnimation(&play, fixtureNode(&play, "WarningLight2", .AnimatedSprite, props, {480, 260}), "assets/light.png", 2, 1, 3, .Forward)
	hud := fixtureNode(&play, "HUD", .Node2D, -1, {1240, 24})
	back := fixtureNode(&play, "BackMenu", .Menu, hud, {-180, 0})
	fixtureItem(&play, back, "Menu", "scene:MenuScene")
	play.nodes[hud].layer = 7
	play.nodes[back].layer = 7
	append(&project.scenes, play)

	options := SceneDef{name = strings.clone("OptionsScene")}
	fixtureText(&options, fixtureNode(&options, "Title", .Label, -1, {640, 120}), "Options", 64, TITLE_COLOR)
	fixtureText(&options, fixtureNode(&options, "Info", .Label, -1, {640, 260}), "Settings will live here.", 28, TEXT_COLOR)
	optionsMenu := fixtureNode(&options, "OptionsMenu", .Menu, -1, {640, 420})
	fixtureItem(&options, optionsMenu, "Back", "scene:MenuScene")
	append(&project.scenes, options)

	for path in ([]string{"assets/ship.png", "assets/balloons.png", "assets/light.png"}) {
		append(&project.assets, AssetDef{path = strings.clone(path), kind = .Image})
	}
	project.buses = Buses_FromData(nil)
	project.actions = DefaultActions()
	return project
}


// Appends a node to the end of the scene and returns its index (children right after their parent)
@(private="file")
fixtureNode :: proc(scene: ^SceneDef, name: string, kind: NodeKind, parent: int, position: [2]f32) -> int {
	node := NodeDef_Make(name, kind, parent)
	node.position = position
	if kind == .Menu {
		// Its menus define their own buttons
		for item in node.items { delete(item.label); delete(item.action) }
		clear(&node.items)
	}
	append(&scene.nodes, node)
	return len(scene.nodes) - 1
}

@(private="file")
fixtureText :: proc(scene: ^SceneDef, index: int, text: string, size: f32, color: sdl.Color) {
	node := &scene.nodes[index]
	delete(node.text)
	node.text = strings.clone(text)
	node.fontSize = size
	node.color = color
	node.layer = 7
}

@(private="file")
fixtureTexture :: proc(scene: ^SceneDef, index: int, path: string) {
	node := &scene.nodes[index]
	delete(node.texture)
	node.texture = strings.clone(path)
}

@(private="file")
fixtureAnimation :: proc(scene: ^SceneDef, index: int, path: string, columns, rows: int, fps: f32, mode: e.AnimationPlayMode) {
	node := &scene.nodes[index]
	delete(node.animations[0].sheet)
	node.animations[0].sheet = strings.clone(path)
	node.animations[0].grid = {mode = .Cells, columns = columns, rows = rows}
	node.animations[0].fps = fps
	node.animations[0].loop = true
	node.animations[0].playMode = mode
}

@(private="file")
fixtureItem :: proc(scene: ^SceneDef, index: int, label, action: string) {
	append(&scene.nodes[index].items, MenuItemDef{strings.clone(label), strings.clone(action)})
}

@(test)
built_in_demo_outline_saves_and_loads :: proc(t: ^testing.T) {
	dir := "build/test_demo_outline"
	removeAll(dir)
	defer removeAll(dir)
	project := Project_CreateDemo(dir)
	defer Project_Destroy(&project)
	testing.expect_value(t, Project_Save(&project), "")
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, loaded.name, "Legacy of the Wardens")
	testing.expect_value(t, loaded.startScene, "TitleScene")
	testing.expect_value(t, len(loaded.scenes), 3)
	// The title's menu: three buttons whose actions go to the level, open the options, quit
	title := &loaded.scenes[0]
	actions := make([dynamic]string, context.temp_allocator)
	for node in title.nodes do if node.kind == .Button do append(&actions, node.ui.action)
	testing.expect_value(t, len(actions), 3)
	if len(actions) == 3 {
		testing.expect_value(t, actions[0], "scene:LevelScene")
		testing.expect_value(t, actions[1], "push:OptionsScene")
		testing.expect_value(t, actions[2], "quit")
	}
	// The options have a slider and a check box; the level's UI is on a screen layer
	kinds := make(map[NodeKind]bool, allocator = context.temp_allocator)
	for node in loaded.scenes[1].nodes do kinds[node.kind] = true
	testing.expect(t, kinds[.Slider] && kinds[.CheckBox], "a slider and a check box")
	testing.expect_value(t, loaded.scenes[2].settings.screenLayers, bit_set[e.RenderLayer]{.Layer8})
}

// The shipped demo is saved by the editor's writer: loading and saving it changes no file and
// writes none it doesn't have (hand edits to it must keep that, or opening it marks it changed).
// DEMO_RESAVE=1 copies what the writer wrote back into the demo instead (after a hand edit)
@(test)
shipped_demo_saves_unchanged :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_demo_resave"
	removeAll(dir)
	defer removeAll(dir)
	root := joinPath(dir, "demo_project", allocator = context.temp_allocator)
	testing.expect_value(t, Folder_Copy(DEMO_PROJECT, root), "")

	project, message, _ := Project_Load(root)
	defer Project_Destroy(&project)
	testing.expect_value(t, message, "")
	testing.expect_value(t, Project_Save(&project), "")

	saved := Project_OwnFiles(&project)
	for name in saved {
		was, readErr := os.read_entire_file(joinPath(DEMO_PROJECT, name, allocator = context.temp_allocator), context.temp_allocator)
		testing.expectf(t, readErr == nil, "saving wrote %s, which the demo doesn't have", name)
		if readErr != nil do continue
		now, _ := os.read_entire_file(joinPath(root, name, allocator = context.temp_allocator), context.temp_allocator)
		if string(was) == string(now) do continue
		if os.get_env("DEMO_RESAVE", context.temp_allocator) != "" {
			_ = os.write_entire_file(joinPath(DEMO_PROJECT, name, allocator = context.temp_allocator), now)
			continue
		}
		testing.expectf(t, false, "saving changed %s", name)
	}
}
