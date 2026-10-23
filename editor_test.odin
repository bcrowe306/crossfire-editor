package crossfire_editor

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import e "engine:."
import ce "code_editor/editor"
import "gui:skald"
import sdl "vendor:sdl3"

// Tests for the editor's logic: the project model, XML saving and loading, tree flattening
// and update. Run with: task test

// Editor state with the demo project in memory, independent of what's on disk
@(private="file")
testState :: proc() -> State {
	state := State{
		project = Project_CreateDemo("unused"),
		browserSelection = {kind = .None},
		currentScene = 1, // PlayScene
		selectedNode = -1,
		busSelection = -1,
		browserOpen = {.Scenes = true, .Scripts = true, .Images = true, .Audio = false, .Music = false, .Fonts = false, .Data = true, .Components = true, .Levels = true, .Translations = true, .Animations = true, .Themes = true, .Materials = true, .Shaders = true, .Atlases = true, .Dialogues = true},
		layout = {bottomOpen = true},
		settings = Settings_Default(),
	}
	// Scripts open in the external program (`true` in tests that open one): the built-in code
	// editor's package state is the code editor tests' (they take turns)
	state.settings.builtInCodeEditor = false
	state.selectedNode = nodeIndex(&state.project.scenes[1], "Spaceship")
	return state
}

@(private="file")
nodeIndex :: proc(scene: ^SceneDef, name: string) -> int {
	for node, i in scene.nodes do if node.name == name do return i
	return -1
}

@(private="file")
playScene :: proc(state: ^State) -> ^SceneDef {
	return &state.project.scenes[1]
}

@(private="file")
send :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

// A fresh empty folder under the system temp directory
@(private="file")
tempDir :: proc(name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, name}, context.temp_allocator)
	_ = removeAll(dir)
	_ = os.make_directory_all(dir)
	return dir
}

// A program that exits at once, standing in for the external code editor (Windows has no `true`)
TEST_NOOP_PROGRAM :: "whoami" when ODIN_OS == .Windows else "true"

@(test)
scene_tree_rows_hide_collapsed_subtrees :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)

	testing.expect_value(t, len(SceneTreeRows(scene)), len(scene.nodes))

	scene.nodes[nodeIndex(scene, "World")].expanded = false
	rows := SceneTreeRows(scene)
	testing.expect_value(t, len(rows), 3) // World, HUD, BackMenu
	testing.expect_value(t, scene.nodes[rows[0]].name, "World")
	testing.expect_value(t, scene.nodes[rows[1]].name, "HUD")
	testing.expect_value(t, scene.nodes[rows[2]].name, "BackMenu")
}

@(test)
insert_node_keeps_depth_first_order :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)

	props := nodeIndex(scene, "Props")
	added := Scene_InsertNode(scene, "Shield", .Sprite, props)

	// Becomes Props' last child
	testing.expect_value(t, added, nodeIndex(scene, "WarningLight2") + 1)
	testing.expect_value(t, scene.nodes[added].parent, props)
	// Nodes after it still point at the right parents
	testing.expect_value(t, scene.nodes[nodeIndex(scene, "BackMenu")].parent, nodeIndex(scene, "HUD"))
}

@(test)
remove_node_removes_subtree_and_fixes_parents :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	before := len(scene.nodes)

	Scene_RemoveNode(scene, nodeIndex(scene, "Props")) // Props + 4 children

	testing.expect_value(t, len(scene.nodes), before - 5)
	testing.expect_value(t, nodeIndex(scene, "Balloon"), -1)
	testing.expect_value(t, scene.nodes[nodeIndex(scene, "BackMenu")].parent, nodeIndex(scene, "HUD"))
	testing.expect_value(t, scene.nodes[nodeIndex(scene, "HUD")].parent, -1)
}

@(test)
selecting_tree_rows_maps_to_nodes :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)

	// Collapse World so the row numbers no longer match node indexes
	send(&state, Node_Toggled(0))
	send(&state, Node_Selected(1))
	testing.expect_value(t, scene.nodes[state.selectedNode].name, "HUD")
}

@(test)
rename_copies_the_message_string :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)

	name := make([]u8, 6)
	copy(name, "Player")
	send(&state, Node_Renamed(string(name)))
	delete(name) // Skald frees message strings at the end of the frame

	testing.expect_value(t, playScene(&state).nodes[state.selectedNode].name, "Player")
}

@(test)
inspector_edits_change_the_selected_node :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)

	send(&state, Node_Field_Changed{.Position_X, 100})
	send(&state, Node_Field_Changed{.Layer, 42})
	send(&state, Node_Visibility_Changed(false))
	send(&state, Node_Text_Changed{.Texture, "assets/light.png"})

	node := playScene(&state).nodes[state.selectedNode]
	testing.expect_value(t, node.position.x, 100)
	testing.expect_value(t, node.layer, 7) // Clamped to the engine's 8 layers
	testing.expect_value(t, node.visible, false)
	testing.expect_value(t, node.texture, "assets/light.png")
}

@(test)
kind_property_edits :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)

	state.selectedNode = nodeIndex(scene, "Balloon")
	send(&state, Anim_Field_Changed{.Columns, 0}) // Clamped to at least 1
	send(&state, Anim_Field_Changed{.Spacing, -3}) // At least 0
	send(&state, Anim_Field_Changed{.Margin, 2})
	send(&state, Anim_Mode_Changed("Reverse"))
	send(&state, Anim_Mode_Changed("NotAMode")) // Ignored
	send(&state, Anim_Loop_Changed(false))
	balloon := scene.nodes[state.selectedNode]
	testing.expect_value(t, balloon.animations[0].grid.columns, 1)
	testing.expect_value(t, balloon.animations[0].grid.spacing, 0)
	testing.expect_value(t, balloon.animations[0].grid.margin, 2)
	testing.expect_value(t, balloon.animations[0].playMode, e.AnimationPlayMode.Reverse)
	testing.expect_value(t, balloon.animations[0].loop, false)

	label := &state.project.scenes[0].nodes[0] // MenuScene Title
	state.currentScene = 0
	state.selectedNode = 0
	send(&state, Node_Text_Changed{.Color, "#ff8000"})
	send(&state, Node_Text_Changed{.Color, "orange"}) // Ignored
	testing.expect_value(t, label.color, sdl.Color{255, 128, 0, 255})
}

@(test)
add_and_delete_node_actions :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	before := len(scene.nodes)

	// Add Node opens the dialog; picking a kind adds it
	send(&state, Action.Add_Node)
	testing.expect(t, state.addNode.open)
	testing.expect_value(t, len(scene.nodes), before)
	send(&state, Add_Node_Kind_Chosen(.Node2D))
	testing.expect(t, !state.addNode.open)
	testing.expect_value(t, len(scene.nodes), before + 1)
	testing.expect_value(t, scene.nodes[state.selectedNode].name, "Node2D")

	send(&state, Action.Delete_Node)
	testing.expect_value(t, len(scene.nodes), before)
	testing.expect_value(t, state.selectedNode, -1)

	// Nothing selected: delete does nothing
	send(&state, Action.Delete_Node)
	testing.expect_value(t, len(scene.nodes), before)
}

@(test)
browser_opens_scenes_and_toggles_folders :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)

	// Row 0 is the Scenes folder, row 1 its first scene
	send(&state, Browser_Selected(1))
	testing.expect_value(t, state.currentScene, 0)
	testing.expect_value(t, state.selectedNode, -1)

	send(&state, Browser_Toggled(0))
	testing.expect_value(t, state.browserOpen[.Scenes], false)
	// Only Images is open, with 3 images; the Scripts, Animations, Themes, Materials, Shaders,
	// Atlases and Dialogues folders are hidden (the project has none of them)
	testing.expect_value(t, len(BrowserRows(&state)), len(BrowserFolder) - 7 + 3)
}

@(test)
divider_drags_round_trip_through_layout :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	state.layout = {leftWidth = 240, rightWidth = 300, bottomHeight = 200, sceneTreeHeight = 280, bottomOpen = true}
	send(&state, Workspace_Measured({1400, 800}))
	layout := &state.layout

	// Dragging the right divider to where it already is changes nothing
	left, right := FittedSidebarWidths(layout)
	center := layout.workspace.x - left - right - DIVIDER * 2
	send(&state, Center_Resized(center))
	testing.expect_value(t, layout.rightWidth, right)

	// Dragging it 50 px left makes the right sidebar 50 px wider
	send(&state, Center_Resized(center - 50))
	testing.expect_value(t, layout.rightWidth, right + 50)

	viewportHeight := layout.workspace.y - FittedBottomHeight(layout) - DIVIDER
	send(&state, Viewport_Resized(viewportHeight - 30))
	testing.expect_value(t, layout.bottomHeight, 230)
}

@(test)
sidebars_shrink_to_fit_narrow_windows :: proc(t: ^testing.T) {
	// Too narrow for 240 + 300 plus the minimum viewport
	width: f32 = 240 + 300 + MIN_CENTER_WIDTH + DIVIDER * 2 - 100
	layout := Layout{leftWidth = 240, rightWidth = 300, workspace = {width, 600}}
	left, right := FittedSidebarWidths(&layout)
	testing.expect(t, left + right + MIN_CENTER_WIDTH + DIVIDER * 2 <= width + 0.01, "sidebars should leave room for the viewport")
	testing.expect(t, left < 240 && right < 300, "both sidebars shrink")

	wide := Layout{leftWidth = 240, rightWidth = 300, workspace = {1600, 900}}
	left, right = FittedSidebarWidths(&wide)
	testing.expect_value(t, left, 240)
	testing.expect_value(t, right, 300)
}

@(test)
bottom_tab_opens_collapsed_panel :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)

	send(&state, Action.Toggle_Bottom_Panel)
	testing.expect_value(t, state.layout.bottomOpen, false)
	send(&state, Bottom_Tab_Changed(int(BottomTab.Output)))
	testing.expect_value(t, state.layout.bottomOpen, true)
	testing.expect_value(t, state.bottomTab, BottomTab.Output)
}

// XML

@(test)
escape_xml_covers_special_characters :: proc(t: ^testing.T) {
	escaped := EscapeXML(`a&b <c> "d" 'e'`, context.temp_allocator)
	testing.expect_value(t, escaped, "a&amp;b &lt;c&gt; &quot;d&quot; &apos;e&apos;")
}

@(test)
project_round_trips_through_xml :: proc(t: ^testing.T) {
	dir := tempDir("odin_sdl_editor_round_trip")
	defer removeAll(dir)

	original := Project_CreateDemo(dir)
	defer Project_Destroy(&original)
	// Characters that need escaping, and non-default values, must survive
	label := &original.scenes[0].nodes[0]
	delete(label.text)
	label.text = strings.clone(`Tom & "Jerry" <3`)
	label.centered = false
	original.scenes[1].nodes[1].zoom = 2.5
	// A Camera's follow target and settings (only enabled limits are written)
	cam := &original.scenes[1].nodes[1]
	assert(cam.kind == .Camera)
	delete(cam.cameraTarget)
	cam.cameraTarget = Scene_NodePath(&original.scenes[1], 1, 2)
	cam.camera.follow = {mode = .SmoothDamp, smoothing = 3, smoothTime = 0.4, speed = 250, maxSpeed = 900, deadzone = {64, 32}, offset = {0, -40}, lookAhead = {80, 0}, lookAheadSmoothing = 0}
	cam.camera.limits = {.Left, .Bottom}
	cam.camera.limitMin = {-16, 0}
	cam.camera.limitMax = {0, 720.5}
	cam.camera.shake = {strength = 7, duration = 0.35, frequency = 25}
	original.scenes[1].nodes[2].visible = false
	original.scenes[1].nodes[2].rotation = 45
	// Format 13's per-node settings
	tagged := &original.scenes[1].nodes[1]
	tagged.processMode = .WhenPaused
	tagged.blendMode = .Add
	tagged.zIndex = -3
	tagged.ySort = true
	delete(tagged.groups)
	tagged.groups = strings.clone("enemies,flying")
	original.window = {fullscreen = true, vsync = false, highDPI = true}
	original.grid = {size = {16, 24}, majorEvery = 0, opacity = 12, majorOpacity = 40}
	original.audioOutput = {frequency = 44100, channels = 1}
	original.locale = strings.clone("fr")
	original.icon = strings.clone("assets/ship.png")
	append(&original.assets, AssetDef{path = strings.clone("i18n/strings.csv"), kind = .Translation})

	testing.expect_value(t, Project_Save(&original), "")
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")

	testing.expect_value(t, loaded.name, original.name)
	testing.expect_value(t, loaded.gameSize, original.gameSize)
	testing.expect_value(t, loaded.scaleMode, original.scaleMode)
	testing.expect_value(t, loaded.background, original.background)
	testing.expect_value(t, loaded.startScene, original.startScene)
	testing.expect_value(t, loaded.window, original.window)
	testing.expect_value(t, loaded.grid, original.grid)
	testing.expect_value(t, loaded.audioOutput, original.audioOutput)
	testing.expect_value(t, loaded.locale, "fr")
	testing.expect_value(t, loaded.icon, "assets/ship.png")
	testing.expect_value(t, len(loaded.assets), len(original.assets))
	testing.expect(t, loaded.assets[len(loaded.assets) - 1].kind == .Translation, "a translation table stays one")
	testing.expect_value(t, len(loaded.scenes), len(original.scenes))

	for &scene, s in original.scenes {
		other := &loaded.scenes[s]
		testing.expect_value(t, other.name, scene.name)
		if !testing.expect_value(t, len(other.nodes), len(scene.nodes)) do continue
		for &a, i in scene.nodes {
			b := &other.nodes[i]
			testing.expectf(t, a.name == b.name && a.kind == b.kind && a.parent == b.parent, "%s/%s: identity", scene.name, a.name)
			testing.expectf(t, a.position == b.position && a.rotation == b.rotation && a.scale == b.scale, "%s/%s: transform", scene.name, a.name)
			testing.expectf(t, a.layer == b.layer && a.visible == b.visible, "%s/%s: layer/visible", scene.name, a.name)
			testing.expectf(t, a.processMode == b.processMode && a.blendMode == b.blendMode && a.zIndex == b.zIndex && a.ySort == b.ySort && a.groups == b.groups,
				"%s/%s: process, blend, z, y-sort, groups (%v %v %v %v %q)", scene.name, a.name, b.processMode, b.blendMode, b.zIndex, b.ySort, b.groups)
			testing.expectf(t, a.texture == b.texture && animationsEqual(a.animations[:], b.animations[:]) && a.autoplay == b.autoplay, "%s/%s: sprite", scene.name, a.name)
			if a.kind == .Label {
				testing.expectf(t, a.text == b.text && a.fontSize == b.fontSize && a.color == b.color && a.centered == b.centered, "%s/%s: label", scene.name, a.name)
			}
			if a.kind == .Camera do testing.expect_value(t, b.zoom, a.zoom)
			if a.kind == .Camera do testing.expectf(t, b.camera == a.camera && b.cameraTarget == a.cameraTarget, "%s/%s: camera settings %v %q", scene.name, a.name, b.camera, b.cameraTarget)
			if testing.expect_value(t, len(b.items), len(a.items)) {
				for item, k in a.items {
					testing.expect_value(t, b.items[k].label, item.label)
					testing.expect_value(t, b.items[k].action, item.action)
				}
			}
		}
	}
}

@(test)
saving_is_deterministic :: proc(t: ^testing.T) {
	project := Project_CreateDemo("unused")
	defer Project_Destroy(&project)
	for &scene in project.scenes {
		testing.expect_value(t, SceneToXML(&scene, context.temp_allocator), SceneToXML(&scene, context.temp_allocator))
	}
	testing.expect_value(t, ProjectToXML(&project, context.temp_allocator), ProjectToXML(&project, context.temp_allocator))
}

@(test)
scene_xml_nests_children :: proc(t: ^testing.T) {
	project := Project_CreateDemo("unused")
	defer Project_Destroy(&project)
	text := SceneToXML(&project.scenes[1], context.temp_allocator)

	// Every node with children has a matching close tag, and the file parses
	// World, Spaceship, Props and HUD have children; BackMenu has button items; the five
	// AnimatedSprites have <animation> elements
	testing.expect_value(t, strings.count(text, "</node>"), 10)
	testing.expect_value(t, strings.count(text, "<animation "), 5)
	parsed, err := e.ParseScene(text)
	defer e.SceneData_Destroy(&parsed)
	testing.expect_value(t, err, e.ProjectError.None)
	testing.expect_value(t, len(parsed.nodes), len(project.scenes[1].nodes))
}

@(test)
world_transforms_combine_parents :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)

	world := Scene_WorldTransforms(scene)
	ship := nodeIndex(scene, "Spaceship")
	light := nodeIndex(scene, "ShipLight")
	testing.expect_value(t, world[light].origin, world[ship].origin + scene.nodes[light].position)

	// Rotating and scaling the ship moves its child with it
	scene.nodes[ship].rotation = 90
	scene.nodes[ship].scale = {2, 2}
	world = Scene_WorldTransforms(scene)
	got := world[light].origin
	want := world[ship].origin + {-120, 0} // (0, 60) local, doubled, turned 90° clockwise
	testing.expectf(t, abs(got.x - want.x) < 0.01 && abs(got.y - want.y) < 0.01, "child world position %v, want %v", got, want)
}

@(test)
new_child_starts_at_parent_origin :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)

	ship := nodeIndex(scene, "Spaceship")
	added := Scene_InsertNode(scene, "Child", .Node2D, ship)
	world := Scene_WorldTransforms(scene)
	testing.expect_value(t, scene.nodes[added].position, [2]f32{0, 0})
	testing.expect_value(t, world[added].origin, world[ship].origin)
}

// VIEWPORT

@(private="file")
nearly :: proc(a, b: [2]f32, eps: f32 = 0.01) -> bool {
	return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
}

@(test)
viewport_view_math :: proc(t: ^testing.T) {
	v := ViewportState{center = {640, 360}, zoom = 2, size = {800, 600}}
	testing.expect(t, nearly(Viewport_WorldToView(&v, {640, 360}), {400, 300}), "center maps to the middle")
	p := [2]f32{123, -45}
	testing.expect(t, nearly(Viewport_ViewToWorld(&v, Viewport_WorldToView(&v, p)), p), "round trip")
	testing.expect(t, nearly(e.Transform2D_Apply(Viewport_Transform(&v, 1.5), p), Viewport_WorldToView(&v, p) * 1.5), "render transform matches, scaled")

	// Zooming keeps the anchor point under the same pixel
	anchor := [2]f32{900, 100}
	before := Viewport_WorldToView(&v, anchor)
	Viewport_ZoomAt(&v, 1.7, anchor)
	testing.expect(t, nearly(Viewport_WorldToView(&v, anchor), before, 0.05), "zoom anchored")
	Viewport_ZoomAt(&v, 1000, anchor)
	testing.expect_value(t, v.zoom, f32(VIEWPORT_MAX_ZOOM))

	Viewport_Fit(&v, {1280, 720})
	testing.expect(t, nearly(v.center, {640, 360}), "fit centers the game area")
	testing.expect(t, abs(v.zoom - 800.0 / 1280 * VIEWPORT_FIT_MARGIN) < 0.001, "fit zoom")

	// A rectangle fits around its middle; a tiny one shows at the minimum size
	Viewport_FitRect(&v, {100, 50, 200, 100})
	testing.expect(t, nearly(v.center, {200, 100}), "fit rect centers it")
	testing.expect(t, abs(v.zoom - min(v.size.x / 200, v.size.y / 100) * VIEWPORT_FIT_MARGIN) < 0.001, "fit rect zoom")
	Viewport_FitRect(&v, {0, 0, 4, 4})
	testing.expect(t, abs(v.zoom - min(v.size.x, v.size.y) / VIEWPORT_FIT_MIN_SIZE * VIEWPORT_FIT_MARGIN) < 0.001, "tiny content isn't magnified without end")

	// The wheel: zooms; Shift pans sideways, Ctrl up and down; sideways scrolling pans; with
	// wheelPans (touchpads) it pans and Ctrl zooms
	zoom, pan := wheelAction({0, 2}, {}, false)
	testing.expect(t, zoom == 2 && pan == {}, "the wheel zooms")
	zoom, pan = wheelAction({0, 1}, {.Shift}, false)
	testing.expect(t, zoom == 0 && pan == {WHEEL_PAN_PIXELS, 0}, "Shift + wheel pans sideways")
	zoom, pan = wheelAction({0, -1}, {.Ctrl}, false)
	testing.expect(t, zoom == 0 && pan == {0, -WHEEL_PAN_PIXELS}, "Ctrl + wheel pans up and down")
	zoom, pan = wheelAction({1, 0}, {}, false)
	testing.expect(t, zoom == 0 && pan == {WHEEL_PAN_PIXELS, 0}, "sideways scrolling pans")
	zoom, pan = wheelAction({1, 1}, {}, true)
	testing.expect(t, zoom == 0 && pan == {WHEEL_PAN_PIXELS, WHEEL_PAN_PIXELS}, "a touchpad pans both ways")
	zoom, pan = wheelAction({0, 1}, {.Ctrl}, true)
	testing.expect(t, zoom == 1 && pan == {}, "Ctrl + touchpad zooms")

	v.zoom = 1
	v.center = {640, 360}
	Viewport_Pan(&v, {10, -20})
	testing.expect(t, nearly(v.center, {630, 380}), "pan moves the content with the mouse")

	testing.expect_value(t, Viewport_RulerStep(1), f32(100))
	testing.expect_value(t, Viewport_RulerStep(0.25), f32(500))
	testing.expect_value(t, Viewport_RulerStep(10), f32(10))
}

@(test)
viewport_drags :: proc(t: ^testing.T) {
	// A node inside a parent that is moved, rotated 90° and doubled
	parentWorld := e.Transform2D_Make({100, 100}, 90, {2, 2})
	node := NodeDef{position = {10, 0}, scale = {1, 1}}
	local := e.Transform2D_Make(node.position, node.rotation, node.scale)
	drag := ViewportDrag{
		node = 0, startMouse = {100, 120},
		startPosition = node.position, startScale = node.scale,
		startWorld = e.Transform2D_Multiply(parentWorld, local), parentWorld = parentWorld,
	}

	// Moving 40 world units right is 20 local units along the parent's (rotated) -Y
	drag.mode = .Move
	Viewport_ApplyDrag(&node, &drag, {140, 120}, false)
	testing.expectf(t, nearly(node.position, {10, -20}), "move in parent space: %v", node.position)
	testing.expect(t, nearly(e.Transform2D_Apply(parentWorld, node.position), {140, 120}), "lands under the mouse")

	drag.mode = .Move_Y
	Viewport_ApplyDrag(&node, &drag, {170, 150}, false)
	testing.expect(t, nearly(e.Transform2D_Apply(parentWorld, node.position), {100, 150}), "axis move ignores X")

	drag.mode = .Move
	Viewport_ApplyDrag(&node, &drag, {150, 105}, true)
	testing.expect(t, nearly(e.Transform2D_Apply(parentWorld, node.position), {150, 120}), "shift keeps the larger axis")

	// Rotate a quarter turn around the node's origin (100, 120), snapping with shift
	node.position = drag.startPosition
	drag.mode = .Rotate
	drag.startMouse = {200, 120}
	Viewport_ApplyDrag(&node, &drag, {100, 220}, false)
	testing.expect(t, abs(node.rotation - 90) < 0.01, "rotate follows the mouse angle")
	Viewport_ApplyDrag(&node, &drag, {100 + 100 * 0.996, 120 + 100 * 0.087}, true)
	testing.expect(t, abs(node.rotation - 0) < 0.01, "shift snaps to 15° steps")

	// Uniform scale by distance from the origin
	drag.mode = .Scale
	Viewport_ApplyDrag(&node, &drag, {300, 120}, false)
	testing.expect(t, nearly(node.scale, {2, 2}), "uniform scale")
}

// The Transform and Scale tools' side handles, moving along a node's own axes, the snapping steps
@(test)
viewport_tool_drags :: proc(t: ^testing.T) {
	// A top-level node turned 90°: its own x axis points down the world's y
	node := NodeDef{position = {100, 100}, rotation = 90, scale = {1, 1}}
	drag := ViewportDrag{
		node = 0, startMouse = {100, 100}, startPosition = node.position, startRotation = 90, startScale = node.scale,
		startWorld = e.Transform2D_Make(node.position, 90, {1, 1}), parentWorld = e.TRANSFORM2D_IDENTITY,
	}
	// Along its own x: a mouse moved right and down only moves it down
	drag.mode, drag.localAxes = .Move_X, true
	Viewport_ApplyDrag(&node, &drag, {130, 140}, false)
	testing.expectf(t, nearly(node.position, {100, 140}), "local x axis: %v", node.position)
	// The world's x
	drag.localAxes = false
	Viewport_ApplyDrag(&node, &drag, {130, 140}, false)
	testing.expectf(t, nearly(node.position, {130, 100}), "world x axis: %v", node.position)

	// A side handle scales one of its axes (its x is the world's y here)
	node = NodeDef{position = {100, 100}, rotation = 90, scale = {1, 1}}
	drag.mode, drag.startMouse = .Scale_X, {100, 120}
	Viewport_ApplyDrag(&node, &drag, {150, 140}, false)
	testing.expectf(t, nearly(node.scale, {2, 1}), "scale x only: %v", node.scale)
	drag.mode, drag.startMouse = .Scale_Y, {80, 100}
	node.scale = {1, 1}
	Viewport_ApplyDrag(&node, &drag, {60, 110}, false)
	testing.expectf(t, nearly(node.scale, {1, 2}), "scale y only: %v", node.scale)

	// Settings' steps: rotation in 45° steps, scale in 0.5s
	node = NodeDef{position = {0, 0}, scale = {1, 1}}
	drag = ViewportDrag{mode = .Rotate, startMouse = {100, 0}, startScale = {1, 1}, startWorld = e.TRANSFORM2D_IDENTITY, parentWorld = e.TRANSFORM2D_IDENTITY}
	Viewport_ApplyDrag(&node, &drag, {100, 70}, true, rotateStep = 45)
	testing.expectf(t, abs(node.rotation - 45) < 0.01, "45° step: %v", node.rotation)
	drag.mode = .Scale
	Viewport_ApplyDrag(&node, &drag, {170, 0}, false, grid = {16, 16}, scaleStep = 0.5)
	testing.expectf(t, nearly(node.scale, {1.5, 1.5}), "0.5 scale step: %v", node.scale)
}

// The Zoom tool: a click zooms in (Alt: out) where it was, a box fits the view to it
@(test)
zoom_tool_clicks_and_boxes :: proc(t: ^testing.T) {
	v := ViewportState{center = {0, 0}, zoom = 1, size = {400, 300}}
	ViewportTools_ZoomBox(&v, {startMouse = {100, 0}, current = {101, 1}})
	testing.expectf(t, abs(v.zoom - 2) < 0.001, "click zooms in: %v", v.zoom)
	testing.expectf(t, nearly(v.center, {50, 0}), "about the point: %v", v.center)
	ViewportTools_ZoomBox(&v, {startMouse = {100, 0}, current = {100, 0}, additive = true})
	testing.expectf(t, abs(v.zoom - 1) < 0.001, "Alt zooms out: %v", v.zoom)
	ViewportTools_ZoomBox(&v, {startMouse = {0, 0}, current = {200, 150}})
	testing.expectf(t, nearly(v.center, {100, 75}), "box centered: %v", v.center)
	testing.expect(t, v.zoom > 1.5 && v.zoom <= 2, "box fills the view")
}

// Align and Distribute: boxes moved to the selection's edges and middles, gaps made equal
@(test)
align_and_distribute :: proc(t: ^testing.T) {
	boxes := []AlignBox{{{0, 0}, {10, 10}}, {{30, 5}, {50, 25}}, {{100, 40}, {110, 50}}}
	left := Align_Moves(boxes, .Left)
	testing.expect(t, left[0] == {0, 0} && left[1] == {-30, 0} && left[2] == {-100, 0}, "left edges")
	right := Align_Moves(boxes, .Right)
	testing.expect(t, right[2] == {0, 0} && right[0] == {100, 0}, "right edges")
	middle := Align_Moves(boxes, .Middle)
	testing.expectf(t, middle[0] == {0, 20} && middle[1] == {0, 10}, "middles: %v", middle)
	// Widths 10, 20, 10 across 0..110: gaps of 35
	across := Align_Moves(boxes, .Distribute_Horizontally)
	testing.expectf(t, across[0] == {0, 0} && across[2] == {0, 0}, "the outer two stay: %v", across)
	testing.expectf(t, across[1] == {15, 0}, "the middle one moves to 45: %v", across[1])

	// Through the editor: two nodes that draw nothing (no preview here) line up by their origins
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	props, hud := nodeNamed(scene, "Props"), nodeNamed(scene, "HUD")
	send(&state, Node_Picked(props))
	send(&state, Node_Pick_Toggled(hud))
	send(&state, Align_Nodes{.Bottom})
	testing.expect_value(t, scene.nodes[hud].position.y, scene.nodes[props].position.y)
	testing.expect_value(t, len(state.history.undo), 1)
	send(&state, Action.Undo)
	testing.expect_value(t, scene.nodes[hud].position.y, 24)
	free_all(context.temp_allocator)
}

// Alt+drag duplicates the dragged node and moves the copy: one undo step takes both back
@(test)
alt_drag_moves_a_copy :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	ship := nodeNamed(scene, "Spaceship")
	count := len(scene.nodes)
	start := scene.nodes[ship].position
	send(&state, Viewport_Drag_Begin{mode = .Move, node = ship, mouse = {100, 100}, duplicate = true})
	send(&state, Viewport_Drag_Move{mouse = {140, 100}})
	send(&state, Viewport_Drag_End{})
	testing.expect(t, len(scene.nodes) > count, "copied")
	testing.expect_value(t, scene.nodes[ship].position, start)
	copy := state.selectedNode
	testing.expect(t, copy != ship && scene.nodes[copy].name == "Spaceship2", "the copy is selected")
	testing.expect_value(t, scene.nodes[copy].position, start + {40, 0})
	testing.expect_value(t, len(state.history.undo), 1)
	send(&state, Action.Undo)
	testing.expect_value(t, len(scene.nodes), count)
	free_all(context.temp_allocator)
}

// The context menus' commands: node visibility, transform, order, selection, here; each undoes
@(test)
context_menu_commands :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	ship := nodeNamed(scene, "Spaceship")
	count := len(scene.nodes)

	// Opening on a node selects it; its items are there, by label
	send(&state, Context_Menu_Opened{at = {10, 10}, target = Ctx_Node{node = ship, viewport = true, world = {5, 6}}})
	testing.expect(t, state.contextMenu.open && state.selectedNode == ship, "open, on the ship")
	labels := make([dynamic]string, context.temp_allocator)
	for item in ContextMenu_Items(&state) do append(&labels, item.label)
	for want in ([]string{"Add Child Node...", "Add Node Here...", "Cut", "Copy", "Paste", "Duplicate", "Delete", "Rename", "Hide", "Transform", "Order", "Select", "Frame Selected"}) {
		testing.expectf(t, slice.contains(labels[:], want), "%s missing from %v", want, labels)
	}
	send(&state, Context_Menu_Closed{})
	testing.expect(t, !state.contextMenu.open, "closed")

	send(&state, Node_Command{.Toggle_Visible})
	testing.expect(t, !scene.nodes[ship].visible, "hidden")
	send(&state, Node_Command{.Reset_Transform})
	testing.expect_value(t, scene.nodes[ship].position, [2]f32{})
	send(&state, Node_Command{.Bring_Forward})
	testing.expect_value(t, scene.nodes[ship].zIndex, 1)
	testing.expect_value(t, len(state.history.undo), 3)
	send(&state, Action.Undo)
	send(&state, Action.Undo)
	send(&state, Action.Undo)
	testing.expect(t, scene.nodes[ship].visible && scene.nodes[ship].zIndex == 0 && scene.nodes[ship].position != {}, "all undone")

	// Children, then their parent
	send(&state, Node_Command{.Select_Children})
	testing.expect(t, state.selectedNode >= 0 && scene.nodes[state.selectedNode].parent == ship, "a child")
	send(&state, Node_Command{.Select_Parent})
	testing.expect_value(t, state.selectedNode, ship)

	// Move Down: after its next sibling; undo puts it back
	name := scene.nodes[ship].name
	send(&state, Node_Command{.Move_Down})
	testing.expect(t, scene.nodes[state.selectedNode].name == name && state.selectedNode != ship, "moved")
	send(&state, Action.Undo)
	testing.expect_value(t, scene.nodes[ship].name, name)

	// Add Node Here: the dialog remembers the point, and the node goes there
	send(&state, Action.Deselect)
	send(&state, Add_Node_Here({300, 200}))
	testing.expect(t, state.addNode.open, "the dialog")
	send(&state, Add_Node_Kind_Chosen(NodeKind.Node2D))
	testing.expect_value(t, scene.nodes[state.selectedNode].position, [2]f32{300, 200})
	testing.expect_value(t, len(scene.nodes), count + 1)
	send(&state, Action.Undo)

	// Paste Here: the copy's origin lands on the point
	send(&state, Node_Picked(ship))
	send(&state, Action.Copy_Node)
	send(&state, Paste_Here({-50, 75}))
	pasted := state.selectedNode
	testing.expect(t, pasted != ship && scene.nodes[pasted].parent < 0, "a top-level copy")
	testing.expect_value(t, scene.nodes[pasted].position, [2]f32{-50, 75})
	free_all(context.temp_allocator)
}

@(test)
nudge_moves_in_world_units_inside_rotated_parents :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	ship := nodeIndex(scene, "Spaceship")
	light := nodeIndex(scene, "ShipLight")
	scene.nodes[ship].rotation = 90
	state.selectedNode = light
	before := Scene_WorldTransforms(scene)[light].origin

	send(&state, Action.Nudge_Right_Large)
	after := Scene_WorldTransforms(scene)[light].origin
	testing.expectf(t, nearly(after - before, {NUDGE_LARGE, 0}), "nudge right moves right on screen: %v", after - before)
}

@(test)
keymap_rules :: proc(t: ^testing.T) {
	settings := Settings_Default()
	keymap := &settings.keymap
	// No two default bindings share a chord
	for chords, action in keymap {
		for chord in chords {
			other, used := Keymap_FindChord(keymap, chord, action)
			testing.expectf(t, !used, "%v and %v share %s", action, other, skald.shortcut_format(chord))
		}
	}
	// Plain keys are hidden from menus while typing; modified ones stay
	testing.expect_value(t, Keymap_Shortcut(keymap, .Delete_Node, typing = true), skald.Shortcut{})
	testing.expect_value(t, Keymap_Shortcut(keymap, .Delete_Node), skald.Shortcut{.Delete, {}})
	testing.expect_value(t, Keymap_Shortcut(keymap, .Save_Project, typing = true), skald.Shortcut{.S, {.Ctrl}})
	// Every tool has a key
	for action in ([]Action{.Tool_Select, .Tool_Move, .Tool_Rotate, .Tool_Scale, .Tool_Transform, .Tool_Zoom, .Tool_Pan}) {
		testing.expectf(t, Keymap_Shortcut(keymap, action) != {}, "%v has no shortcut", action)
	}
	free_all(context.temp_allocator)
}

@(test)
tool_and_view_actions :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	state.viewport.size = {800, 450}

	send(&state, Action.Tool_Rotate)
	testing.expect_value(t, state.tool, Tool.Rotate)
	send(&state, Action.View_Fit)
	testing.expect(t, nearly(state.viewport.center, state.project.gameSize * 0.5), "fit")
	send(&state, Action.Zoom_100)
	testing.expect_value(t, state.viewport.zoom, f32(1))
	send(&state, Action.Zoom_In)
	testing.expect_value(t, state.viewport.zoom, f32(VIEWPORT_ZOOM_STEP))
	send(&state, Action.Frame_Selected)
	testing.expect(t, nearly(state.viewport.center, Scene_WorldTransforms(playScene(&state))[state.selectedNode].origin), "frame selected")
	send(&state, Action.Deselect)
	testing.expect_value(t, state.selectedNode, -1)
}

@(test)
opening_a_scene_fits_the_view :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)

	// Before the viewport is measured, fitting waits for the first measurement
	send(&state, Scene_Tab_Changed(0))
	testing.expect_value(t, state.viewport.zoom, f32(0))
	send(&state, Viewport_Measured({800, 450}))
	fitted := state.viewport.zoom
	testing.expect(t, fitted > 0, "fitted on first measure")

	// Zoom and pan away, then open another scene: back to the fitted view
	send(&state, Action.Zoom_In)
	send(&state, Viewport_Panned({120, -40}))
	send(&state, Scene_Tab_Changed(1))
	testing.expect_value(t, state.viewport.zoom, fitted)
	testing.expect(t, nearly(state.viewport.center, state.project.gameSize * 0.5), "centered on the game area")

	// Re-selecting the scene that's already open keeps the current view
	send(&state, Action.Zoom_In)
	send(&state, Scene_Tab_Changed(1))
	testing.expect(t, state.viewport.zoom != fitted, "same scene: view kept")
}

// ASSETS

// A temp project folder with the demo project saved in it
@(private="file")
tempProject :: proc(name: string) -> Project {
	project := Project_CreateDemo(tempDir(name))
	Project_Save(&project)
	return project
}

@(test)
asset_kinds_from_extensions :: proc(t: ^testing.T) {
	cases := [?]struct{path: string, kind: AssetKind, ok: bool}{
		{"a/ship.PNG", .Image, true}, {"x.jpeg", .Image, true}, {"song.ogg", .Audio, true},
		{"beep.wav", .Audio, true}, {"font.ttf", .Font, true}, {"notes.txt", .Image, false},
		{"i18n/Strings.CSV", .Translation, true},
	}
	for c in cases {
		kind, ok := AssetKindForPath(c.path)
		testing.expectf(t, ok == c.ok && (!ok || kind == c.kind), "%s: got %v %v", c.path, kind, ok)
	}
}

// The editor's look: colors set over the base, corners, presets; saved and read back
@(test)
editor_theme_settings :: proc(t: ^testing.T) {
	settings := Settings_Default()
	testing.expect_value(t, settings.cornerRadius, 100)
	testing.expect_value(t, settings.themeColorsSet, bit_set[ThemeColor]{})
	base := Settings_Theme(&settings)
	testing.expect_value(t, base.color, skald.theme_dark().color)

	// A color set, the corners squared: the theme has them, the rest is the base's
	settings.themeColors[.Primary] = skald.rgb(0xE8833A)
	settings.themeColorsSet += {.Primary}
	settings.cornerRadius = 0
	theme := Settings_Theme(&settings)
	testing.expect_value(t, skald.color_to_hex(theme.color.primary), "E8833A")
	testing.expect_value(t, theme.color.bg, base.color.bg)
	testing.expect_value(t, theme.radius.md, 0)
	// It stays on the light base too
	settings.theme = .Light
	testing.expect_value(t, skald.color_to_hex(Settings_Theme(&settings).color.primary), "E8833A")

	// Colors as editor.ini writes them, alpha only when see-through
	testing.expect_value(t, ThemeColor_Format(skald.rgb(0x1E2130)), "#1E2130")
	testing.expect_value(t, ThemeColor_Format(skald.rgba(0x5B8CFF55)), "#5B8CFF55")
	c, ok := ThemeColor_Parse("#5B8CFF55")
	testing.expect(t, ok && ThemeColor_Format(c) == "#5B8CFF55", "round trip with alpha")
	_, bad := ThemeColor_Parse("#12345")
	testing.expect(t, !bad, "a short color is refused")

	// Presets: exactly their colors, and recognized afterwards
	testing.expect(t, EditorTheme_ApplyPreset(&settings, "Midnight"), "Midnight")
	testing.expect_value(t, settings.theme, ThemeChoice.Dark)
	testing.expect_value(t, EditorTheme_PresetName(&settings), "Midnight")
	testing.expect_value(t, ThemeColor_Format(Settings_Theme(&settings).color.bg), "#0F1420")
	settings.themeColors[.Danger] = skald.rgb(0xFF0000)
	testing.expect_value(t, EditorTheme_PresetName(&settings), "")
	testing.expect(t, EditorTheme_ApplyPreset(&settings, "Dark") && settings.themeColorsSet == {}, "Dark sets none")
	testing.expect(t, !EditorTheme_ApplyPreset(&settings, "Nope"), "unknown preset")

	// Saved and read back
	EditorTheme_ApplyPreset(&settings, "Graphite")
	settings.cornerRadius = 150
	path := "build/test_theme_settings.ini"
	defer os.remove(path)
	testing.expect_value(t, Settings_Save(&settings, path), "")
	loaded, problems := Settings_Load(path)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, loaded.cornerRadius, 150)
	testing.expect_value(t, loaded.themeColorsSet, settings.themeColorsSet)
	testing.expect_value(t, EditorTheme_PresetName(&loaded), "Graphite")
	free_all(context.temp_allocator)
}

// The keymap's Ctrl is Cmd on a Mac: matched, shown and captured that way; files stay the same
@(test)
chords_follow_the_platform :: proc(t: ^testing.T) {
	save, _ := Shortcut_Parse("Ctrl+S")
	redo, _ := Shortcut_Parse("Ctrl+Shift+Z")
	other, _ := Shortcut_Parse("Super+Alt+K")
	// Elsewhere: as written
	testing.expect_value(t, Chord_OnPlatform(save, mac = false), save)
	testing.expect_value(t, Chord_Format(redo, mac = false), "Ctrl+Shift+Z")
	// A Mac: Ctrl is Cmd (Super), Super is Ctrl, Alt is Option
	testing.expect_value(t, Chord_OnPlatform(save, mac = true), skald.Shortcut{.S, {.Super}})
	testing.expect_value(t, Chord_Format(save, mac = true), "Cmd+S")
	testing.expect_value(t, Chord_Format(redo, mac = true), "Shift+Cmd+Z")
	testing.expect_value(t, Chord_Format(other, mac = true), "Ctrl+Option+K")
	// Keys pressed on a Mac are stored the keymap's way, so the file reads the same everywhere
	testing.expect_value(t, Chord_FromPlatform({.S, {.Super}}, mac = true), save)
	testing.expect_value(t, Keymap_FormatChords({Chord_FromPlatform({.S, {.Super}}, mac = true), {}}), "Ctrl+S")
	// No shortcut stays none
	testing.expect_value(t, Chord_Format({}, mac = true), "")
}

// Lists show the editor's own formats by name; real file types keep their extension
@(test)
assets_are_listed_by_name :: proc(t: ^testing.T) {
	testing.expect_value(t, Asset_DisplayName("components/coin.component.xml"), "coin")
	testing.expect_value(t, Asset_DisplayName("components/Coin.Component.XML"), "Coin")
	testing.expect_value(t, Asset_DisplayName("data/goblin.data.json"), "goblin")
	testing.expect_value(t, Asset_DisplayName("animations/hero.anim.xml"), "hero")
	testing.expect_value(t, Asset_DisplayName("themes/dark.theme.xml"), "dark")
	testing.expect_value(t, Asset_DisplayName("materials/ice.material.xml"), "ice")
	testing.expect_value(t, Asset_DisplayName("atlases/items.atlas.xml"), "items")
	testing.expect_value(t, Asset_DisplayName("dialogues/shop.dialogue.xml"), "shop")
	testing.expect_value(t, Asset_DisplayName("assets/hero.png"), "hero.png")
	testing.expect_value(t, Asset_DisplayName("assets/level.ldtk"), "level.ldtk")
	labels := Asset_DisplayNames({TEXTURE_NONE, "components/coin.component.xml"})
	testing.expect_value(t, labels[0], TEXTURE_NONE)
	testing.expect_value(t, labels[1], "coin")
}

@(test)
importing_copies_files_into_assets :: proc(t: ^testing.T) {
	project := tempProject("odin_sdl_editor_import")
	defer { removeAll(project.rootPath); Project_Destroy(&project) }
	before := len(project.assets)

	index, message := Project_ImportAsset(&project, "tests/fixtures/beep.wav")
	testing.expect_value(t, message, "")
	testing.expect_value(t, len(project.assets), before + 1)
	testing.expect_value(t, project.assets[index].path, "assets/beep.wav")
	testing.expect_value(t, project.assets[index].kind, AssetKind.Audio)
	testing.expect(t, os.exists(AssetFilePath(&project, project.assets[index])), "file copied")

	// Same file name again: copied under a new name, not overwritten
	second, _ := Project_ImportAsset(&project, "tests/fixtures/beep.wav")
	testing.expect_value(t, project.assets[second].path, "assets/beep_1.wav")

	// A file already inside the project folder is referenced, not copied
	_ = os.remove(AssetFilePath(&project, project.assets[second]))
	inside, _ := filepath.join({project.rootPath, "assets", "beep.wav"}, context.temp_allocator)
	again, msg := Project_ImportAsset(&project, inside)
	testing.expect_value(t, msg, "")
	testing.expect_value(t, again, index) // Already listed: same asset

	_, bad := Project_ImportAsset(&project, "README.md")
	testing.expect(t, bad != "", "unsupported type is refused")
	_, missing := Project_ImportAsset(&project, "tests/fixtures/nope.wav")
	testing.expect(t, missing != "", "missing file is refused")
}

@(test)
removing_assets :: proc(t: ^testing.T) {
	project := tempProject("odin_sdl_editor_remove")
	defer { removeAll(project.rootPath); Project_Destroy(&project) }
	index, _ := Project_ImportAsset(&project, "tests/fixtures/beep.wav")
	file := strings.clone(AssetFilePath(&project, project.assets[index]), context.temp_allocator)

	// Remove from the project only: the file stays
	testing.expect_value(t, Project_RemoveAsset(&project, index, false), "")
	testing.expect(t, os.exists(file), "file kept")
	for asset in project.assets do testing.expect(t, asset.path != "assets/beep.wav", "removed from list")

	// Remove and delete
	index, _ = Project_ImportAsset(&project, file)
	testing.expect_value(t, Project_RemoveAsset(&project, index, true), "")
	testing.expect(t, !os.exists(file), "file deleted")

	// Usage counts nodes that reference an asset
	testing.expect_value(t, AssetUsage(&project, "assets/balloons.png"), 2)
	testing.expect_value(t, AssetUsage(&project, "assets/nothing.png"), 0)
}

// Several files at once: every one imported, their folder remembered; names with dashes and spaces
// make valid constants in scripts/assets.odin
@(test)
import_several_files_with_awkward_names :: proc(t: ^testing.T) {
	state := State{project = tempProject("odin_sdl_editor_import_many"), browserSelection = {kind = .None}}
	defer { removeAll(state.project.rootPath); State_Destroy(&state) }
	source := joinPath(state.project.rootPath, "..", "odin_sdl_editor_import_many_source", allocator = context.temp_allocator)
	_ = os.make_directory_all(source)
	defer removeAll(source)
	beep, _ := os.read_entire_file("tests/fixtures/beep.wav", context.temp_allocator)
	ship, _ := os.read_entire_file("tests/fixtures/ui_project/assets/ship.png", context.temp_allocator)
	names := []string{"hero-run.wav", "boss fight.wav", "tiles-1.png"}
	paths := make([]string, len(names), context.temp_allocator)
	for name, i in names {
		paths[i] = joinPath(source, name, allocator = context.temp_allocator)
		_ = os.write_entire_file(paths[i], strings.has_suffix(name, ".png") ? ship : beep)
	}
	before := len(state.project.assets)
	send(&state, Asset_Import_Result{path = paths[0], paths = paths})
	testing.expect_value(t, len(state.project.assets), before + 3)
	testing.expect_value(t, FixedText_String(&state.settings.importFolder), filepath.dir(paths[0]))

	text := Scripts_AssetsSource(&state.project)
	testing.expect(t, strings.contains(text, "SOUND_HERO_RUN ::"), "hero-run.wav")
	testing.expect(t, strings.contains(text, "SOUND_BOSS_FIGHT ::"), "boss fight.wav")
	testing.expect(t, strings.contains(text, "TEXTURE_TILES_1 ::"), "tiles-1.png")
	// Every constant's name is an Odin name
	for line in strings.split_lines(text, context.temp_allocator) {
		name, _, rest := strings.partition(line, " :: ")
		if rest == "" || strings.has_prefix(line, "//") do continue
		for r in name do testing.expectf(t, (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_', "%s isn't a valid name", name)
	}
	testing.expect_value(t, ConstantName("hero-run 2"), "HERO_RUN_2")
	testing.expect_value(t, ConstantName("__x--y__"), "X_Y")
	testing.expect_value(t, ConstantName("é"), "UNNAMED")
	free_all(context.temp_allocator)
}

@(test)
browser_search_filters_rows :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)

	send(&state, Browser_Search_Changed("BALL"))
	rows := BrowserRows(&state)
	// Only the Images folder (shown open) with balloons.png
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[0].kind, BrowserItemKind.Folder)
	testing.expect_value(t, state.project.assets[rows[1].index].path, "assets/balloons.png")

	send(&state, Browser_Search_Changed("scene"))
	testing.expect_value(t, len(BrowserRows(&state)), 1 + len(state.project.scenes))

	send(&state, Browser_Search_Changed("zzz"))
	testing.expect_value(t, len(BrowserRows(&state)), 0)

	send(&state, Browser_Search_Changed(""))
	testing.expect(t, len(BrowserRows(&state)) > 3, "cleared search shows everything again")
}

@(test)
import_and_remove_through_messages :: proc(t: ^testing.T) {
	state := State{project = tempProject("odin_sdl_editor_import_msgs"), browserSelection = {kind = .None}}
	defer { removeAll(state.project.rootPath); State_Destroy(&state) }
	before := len(state.project.assets)

	send(&state, Asset_Import_Result{path = "tests/fixtures/beep.wav"})
	testing.expect_value(t, len(state.project.assets), before + 1)
	testing.expect_value(t, state.browserSelection.kind, BrowserItemKind.Asset)
	testing.expect_value(t, state.browserOpen[.Audio], true)

	send(&state, Asset_Import_Result{cancelled = true})
	testing.expect_value(t, len(state.project.assets), before + 1)

	send(&state, Action.Remove_Asset)
	testing.expect(t, state.removeConfirm.open, "dialog opens")
	send(&state, Asset_Remove_Cancelled{})
	testing.expect(t, !state.removeConfirm.open, "cancel closes it")
	testing.expect_value(t, len(state.project.assets), before + 1)

	send(&state, Action.Remove_Asset)
	send(&state, Asset_Remove_Confirmed{deleteFile = true})
	testing.expect_value(t, len(state.project.assets), before)
	testing.expect_value(t, state.browserSelection.kind, BrowserItemKind.None)
	AudioPreview_Unload()
}

@(test)
add_node_search_filters_kinds :: proc(t: ^testing.T) {
	testing.expect_value(t, len(AddNode_Kinds("")), len(NodeKind))
	// By name, case-insensitive
	sprites := AddNode_Kinds("SPRITE")
	testing.expect_value(t, len(sprites), 2)
	testing.expect_value(t, sprites[0], NodeKind.Sprite)
	testing.expect_value(t, sprites[1], NodeKind.AnimatedSprite)
	// By description: "Draws an image"
	images := AddNode_Kinds("image")
	testing.expect_value(t, len(images), 1)
	testing.expect_value(t, images[0], NodeKind.Sprite)
	testing.expect_value(t, len(AddNode_Kinds("zzz")), 0)
	// Listed by category, as the dialog shows them; a category's name lists all of it
	all := AddNode_Kinds("")
	for i in 1 ..< len(all) {
		testing.expect(t, e.SCENE_NODE_KINDS[all[i - 1]].category <= e.SCENE_NODE_KINDS[all[i]].category, "kinds are grouped by category")
	}
	testing.expect_value(t, all[0], NodeKind.Node2D)
	physics := AddNode_Kinds("physics")
	testing.expect_value(t, len(physics), 7)
	for kind in physics do testing.expect_value(t, e.SCENE_NODE_KINDS[kind].category, e.SceneNodeCategory.Physics)
	free_all(context.temp_allocator)
}

@(test)
add_node_dialog_keys_and_naming :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	before := len(scene.nodes)

	// Nothing selected: a top-level node
	send(&state, Action.Deselect)
	send(&state, Action.Add_Node)
	send(&state, Add_Node_Search_Changed("sprite"))
	send(&state, Add_Node_Highlight_Moved(1))
	send(&state, Add_Node_Highlight_Moved(1)) // stays on the last match
	testing.expect_value(t, state.addNode.highlight, 1)
	send(&state, Add_Node_Confirmed{})
	first := state.selectedNode
	testing.expect_value(t, scene.nodes[first].kind, NodeKind.AnimatedSprite)
	testing.expect_value(t, scene.nodes[first].parent, -1)

	// Reopening clears the search; the new node becomes the parent and the name is numbered
	send(&state, Action.Add_Node)
	testing.expect_value(t, state.addNode.search, "")
	testing.expect_value(t, state.addNode.highlight, 0)
	send(&state, Add_Node_Kind_Chosen(.AnimatedSprite))
	second := state.selectedNode
	testing.expect_value(t, scene.nodes[second].name, "AnimatedSprite2")
	testing.expect_value(t, scene.nodes[second].parent, first)
	testing.expect_value(t, len(scene.nodes), before + 2)

	// Cancel adds nothing
	send(&state, Action.Add_Node)
	send(&state, Add_Node_Cancelled{})
	testing.expect(t, !state.addNode.open)
	testing.expect_value(t, len(scene.nodes), before + 2)
	free_all(context.temp_allocator)
}

// Every node comes after its parent and inside its parent's subtree (depth-first order)
@(private="file")
expectValidTree :: proc(t: ^testing.T, scene: ^SceneDef, loc := #caller_location) {
	for node, i in scene.nodes {
		if node.parent < 0 do continue
		testing.expect(t, node.parent < i, "parent comes first", loc = loc)
		testing.expect(t, i <= node.parent + Scene_DescendantCount(scene, node.parent), "inside the parent's subtree", loc = loc)
	}
}

@(private="file")
nodeNamed :: proc(scene: ^SceneDef, name: string) -> int {
	for node, i in scene.nodes do if node.name == name do return i
	return -1
}

@(test)
duplicate_node_copies_subtree_as_next_sibling :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	before := len(scene.nodes)

	state.selectedNode = nodeNamed(scene, "Spaceship")
	send(&state, Action.Duplicate_Node)
	copy := state.selectedNode
	testing.expect_value(t, len(scene.nodes), before + 2)
	testing.expect_value(t, scene.nodes[copy].name, "Spaceship2")
	testing.expect_value(t, scene.nodes[copy].parent, nodeNamed(scene, "World"))
	testing.expect_value(t, copy, nodeNamed(scene, "ShipLight") + 1)
	testing.expect_value(t, scene.nodes[copy + 1].name, "ShipLight")
	testing.expect_value(t, scene.nodes[copy + 1].parent, copy)
	expectValidTree(t, scene)

	// Duplicating the copy numbers on from it
	send(&state, Action.Duplicate_Node)
	testing.expect_value(t, scene.nodes[state.selectedNode].name, "Spaceship3")
	expectValidTree(t, scene)
	free_all(context.temp_allocator)
}

@(test)
copy_cut_and_paste_nodes :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	before := len(scene.nodes)

	// Nothing copied yet
	send(&state, Action.Paste_Node)
	testing.expect_value(t, len(scene.nodes), before)

	// Copy Props (4 children) into HUD, twice
	state.selectedNode = nodeNamed(scene, "Props")
	send(&state, Action.Copy_Node)
	testing.expect_value(t, len(state.clipboard), 5)
	testing.expect_value(t, len(scene.nodes), before)
	state.selectedNode = nodeNamed(scene, "HUD")
	send(&state, Action.Paste_Node)
	pasted := state.selectedNode
	testing.expect_value(t, scene.nodes[pasted].name, "Props2")
	testing.expect_value(t, scene.nodes[pasted].parent, nodeNamed(scene, "HUD"))
	testing.expect_value(t, Scene_DescendantCount(scene, pasted), 4)
	state.selectedNode = nodeNamed(scene, "HUD")
	send(&state, Action.Paste_Node)
	testing.expect_value(t, scene.nodes[state.selectedNode].name, "Props3")
	testing.expect_value(t, len(scene.nodes), before + 10)
	expectValidTree(t, scene)

	// Cut removes it; pasting with nothing selected makes it top-level, keeping its free name
	state.selectedNode = nodeNamed(scene, "Camera")
	send(&state, Action.Cut_Node)
	testing.expect_value(t, len(scene.nodes), before + 9)
	testing.expect_value(t, state.selectedNode, -1)
	send(&state, Action.Paste_Node)
	testing.expect_value(t, scene.nodes[state.selectedNode].name, "Camera")
	testing.expect_value(t, scene.nodes[state.selectedNode].parent, -1)
	testing.expect_value(t, state.selectedNode, len(scene.nodes) - 1)
	expectValidTree(t, scene)
	free_all(context.temp_allocator)
}

@(test)
move_node_keeps_world_transform :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)

	// ShipLight is at (640, 490) in the world; inside Props (at 640, 360) it's at (0, 130)
	light, moved := Scene_MoveNode(scene, nodeNamed(scene, "ShipLight"), nodeNamed(scene, "Props"), .Inside)
	testing.expect(t, moved)
	testing.expect_value(t, scene.nodes[light].parent, nodeNamed(scene, "Props"))
	testing.expect_value(t, scene.nodes[light].position, [2]f32{0, 130})
	testing.expect_value(t, scene.nodes[light].scale, [2]f32{0.4, 0.4})
	testing.expect_value(t, light, nodeNamed(scene, "WarningLight2") + 1)
	testing.expect(t, !Scene_HasChildren(scene, nodeNamed(scene, "Spaceship")))
	expectValidTree(t, scene)

	// HUD (with its child) before World: top-level, now first; HUD's position is unchanged
	hud, _ := Scene_MoveNode(scene, nodeNamed(scene, "HUD"), nodeNamed(scene, "World"), .Before)
	testing.expect_value(t, hud, 0)
	testing.expect_value(t, scene.nodes[1].name, "BackMenu")
	testing.expect_value(t, scene.nodes[1].parent, 0)
	testing.expect_value(t, scene.nodes[0].position, [2]f32{1240, 24})
	expectValidTree(t, scene)

	// After a sibling, and to the end of the top level
	camera, _ := Scene_MoveNode(scene, nodeNamed(scene, "Camera"), nodeNamed(scene, "Props"), .After)
	testing.expect_value(t, scene.nodes[camera].parent, nodeNamed(scene, "World"))
	testing.expect_value(t, camera, len(scene.nodes) - 1)
	camera, _ = Scene_MoveNode(scene, camera, -1, .Inside)
	testing.expect_value(t, scene.nodes[camera].parent, -1)
	testing.expect_value(t, scene.nodes[camera].position, [2]f32{640, 360})
	expectValidTree(t, scene)

	// Not into its own subtree
	before := len(scene.nodes)
	world := nodeNamed(scene, "World")
	_, moved = Scene_MoveNode(scene, world, nodeNamed(scene, "Balloon"), .Inside)
	testing.expect(t, !moved)
	_, moved = Scene_MoveNode(scene, world, world, .After)
	testing.expect(t, !moved)
	testing.expect_value(t, len(scene.nodes), before)
	free_all(context.temp_allocator)
}

@(test)
tree_drag_messages_move_the_node :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)

	send(&state, Tree_Drag_Pressed{node = nodeNamed(scene, "Camera"), start = {10, 10}})
	send(&state, Tree_Drag_Started{})
	testing.expect(t, state.treeDrag.active)
	send(&state, Tree_Drag_Dropped{target = nodeNamed(scene, "Spaceship"), position = .Inside})
	testing.expect(t, !state.treeDrag.pressed)
	testing.expect_value(t, scene.nodes[state.selectedNode].name, "Camera")
	testing.expect_value(t, scene.nodes[state.selectedNode].parent, nodeNamed(scene, "Spaceship"))
	free_all(context.temp_allocator)
}

@(test)
unique_names_and_text_chords :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	testing.expect_value(t, Scene_UniqueNodeName(scene, "Ship"), "Ship")
	testing.expect_value(t, Scene_UniqueNodeName(scene, "WarningLight"), "WarningLight3")
	testing.expect_value(t, Scene_UniqueNodeName(scene, "WarningLight2"), "WarningLight3")

	// Ctrl+C belongs to text fields while typing
	testing.expect(t, Keymap_Shortcut(&state.settings.keymap, .Copy_Node, typing = true) == {})
	testing.expect(t, Keymap_Shortcut(&state.settings.keymap, .Copy_Node) == skald.Shortcut{.C, {.Ctrl}})
	free_all(context.temp_allocator)
}

@(test)
default_settings_come_from_the_ini :: proc(t: ^testing.T) {
	settings := Settings_Default()
	testing.expect_value(t, settings.theme, ThemeChoice.Dark)
	testing.expect_value(t, settings.fontSize, 13)
	testing.expect_value(t, settings.spacing, 75)
	testing.expect_value(t, settings.rowHeight, 26)
	testing.expect_value(t, settings.undoMergeMs, 500)
	testing.expect_value(t, settings.undoGroupMaxMs, 3000)
	testing.expect_value(t, settings.undoLimit, 200)
	testing.expect_value(t, settings.keymap[.Redo], [KEYMAP_SLOTS]skald.Shortcut{{.Z, {.Ctrl, .Shift}}, {.Y, {.Ctrl}}})
	testing.expect_value(t, settings.keymap[.Zoom_In][0], skald.Shortcut{.Equals, {.Ctrl}})
	testing.expect_value(t, settings.keymap[.Open_Settings][0], skald.Shortcut{.Comma, {.Ctrl}})
	// The default file has no problems, and lists every action
	parsed: Settings
	testing.expect_value(t, len(Settings_Parse(&parsed, SETTINGS_DEFAULT_INI)), 0)
	for action in Action {
		testing.expectf(t, strings.contains(SETTINGS_DEFAULT_INI, fmt.tprintf("\n%v =", action)), "settings.default.ini has no [keymap] entry for %v", action)
	}
	free_all(context.temp_allocator)
}

@(test)
settings_round_trip_and_overlay :: proc(t: ^testing.T) {
	testing.expect(t, Settings_Default().builtInCodeEditor, "the built-in code editor is the default")
	settings := Settings_Default()
	settings.theme = .Light
	settings.fontSize = 15
	settings.undoLimit = 50
	settings.keymap[.Save_Project] = {{.S, {.Ctrl, .Alt}}, {}}
	settings.keymap[.Delete_Node] = {}
	settings.builtInCodeEditor = false
	settings.olsPath = FixedText_Make("/opt/ols/ols")
	settings.audioDevice = FixedText_Make("USB Audio Interface Out 1-2")

	parsed := Settings_Default()
	problems := Settings_Parse(&parsed, Settings_ToINI(&settings))
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, parsed, settings)

	// A partial file only changes what it names; bad lines are reported and skipped
	partial := Settings_Default()
	problems = Settings_Parse(&partial, "[appearance]\nfont_size = 99\nspacing = lots\n[keymap]\nPlay = Ctrl+P\nNot_An_Action = F1\nStop = Hyper+K\n[nope]\nx = 1\n")
	testing.expect_value(t, partial.fontSize, SETTINGS_FONT_SIZE_RANGE[1])
	testing.expect_value(t, partial.spacing, 75)
	testing.expect_value(t, partial.keymap[.Play][0], skald.Shortcut{.P, {.Ctrl}})
	testing.expect_value(t, partial.keymap[.Stop], Settings_Default().keymap[.Stop])
	testing.expect_value(t, len(problems), 4)

	// Older files' grid settings (the project's now) are skipped without a problem
	old := Settings_Default()
	testing.expect_value(t, len(Settings_Parse(&old, "[editor]\ngrid_size = 48\ngrid_width = 16\n")), 0)
	free_all(context.temp_allocator)
}

@(test)
shortcut_text_round_trips :: proc(t: ^testing.T) {
	for key in skald.Key {
		for mods in ([]skald.Modifiers{{}, {.Ctrl}, {.Ctrl, .Shift}, {.Alt, .Super}}) {
			chord := skald.Shortcut{key, mods}
			if chord == {} do continue
			// Files use the same names everywhere; the Mac's names (Option, Cmd) read back too
			for mac in ([]bool{false, true}) {
				text := skald.shortcut_format_for(chord, mac)
				parsed, ok := Shortcut_Parse(text)
				testing.expectf(t, ok && parsed == chord, "%v didn't round trip (%s)", chord, text)
			}
		}
	}
	_, ok := Shortcut_Parse("Backspace")
	testing.expect(t, !ok)
	parsed, _ := Shortcut_Parse("ctrl+delete")
	testing.expect_value(t, parsed, skald.Shortcut{.Delete, {.Ctrl}})
	free_all(context.temp_allocator)
}

@(test)
settings_theme_scales_text_and_spacing :: proc(t: ^testing.T) {
	settings := Settings_Default()
	theme := Settings_Theme(&settings)
	testing.expect_value(t, theme.font.size_md, 13)
	testing.expect_value(t, theme.font.size_sm, 12)
	testing.expect_value(t, theme.spacing.sm, 6)
	testing.expect_value(t, theme.spacing.lg, 12)
	settings.fontSize, settings.spacing, settings.theme = 14, 100, .Light
	theme = Settings_Theme(&settings)
	testing.expect_value(t, theme.font, skald.theme_light().font)
	testing.expect_value(t, theme.spacing, skald.theme_light().spacing)
	testing.expect_value(t, theme.color, skald.theme_light().color)
}

@(test)
settings_dialog_edits_a_draft :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	os.make_directory("build")
	state.settingsPath = strings.clone("build/test_settings.ini")

	send(&state, Action.Open_Settings)
	testing.expect(t, state.settingsDialog.open)
	send(&state, Settings_Value_Changed{.Font_Size, 16})
	send(&state, Settings_Capture_Started{.Play, 1})
	send(&state, Settings_Key_Captured(skald.Shortcut{.R, {.Ctrl}}))
	testing.expect_value(t, state.settingsDialog.draft.keymap[.Play][1], skald.Shortcut{.R, {.Ctrl}})
	testing.expect(t, !state.settingsDialog.capture.active)
	// Not applied yet
	testing.expect_value(t, state.settings.fontSize, 13)

	// Cancel drops the draft
	send(&state, Settings_Cancelled{})
	testing.expect(t, !state.settingsDialog.open)
	testing.expect_value(t, state.settings.keymap[.Play][1], skald.Shortcut{})

	// Save applies and writes it
	send(&state, Action.Open_Settings)
	send(&state, Settings_Value_Changed{.Font_Size, 16})
	send(&state, Settings_Value_Changed{.Undo_Limit, -5})
	send(&state, Settings_Key_Cleared{.Delete_Node, 0})
	send(&state, Settings_Applied{close = true})
	testing.expect(t, !state.settingsDialog.open)
	testing.expect_value(t, state.settings.fontSize, 16)
	testing.expect_value(t, state.settings.undoLimit, 1)
	testing.expect_value(t, state.settings.keymap[.Delete_Node][0], skald.Shortcut{})
	loaded, problems := Settings_Load(state.settingsPath)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, loaded, state.settings)

	// Reset the open tab
	send(&state, Action.Open_Settings)
	send(&state, Settings_Tab_Changed(int(SettingsTab.Keyboard)))
	send(&state, Settings_Tab_Reset{})
	testing.expect_value(t, state.settingsDialog.draft.keymap, Settings_Default().keymap)
	testing.expect_value(t, state.settingsDialog.draft.fontSize, 16)
	os.remove(state.settingsPath)
	free_all(context.temp_allocator)
}

@(test)
undo_and_redo_edits :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	ship := state.selectedNode
	before := len(scene.nodes)
	original := scene.nodes[ship].position

	// A property edit, then a structural one
	send(&state, Node_Field_Changed{.Position_X, 100})
	send(&state, Action.Duplicate_Node)
	testing.expect_value(t, len(state.history.undo), 2)
	testing.expect_value(t, History_NextLabel(&state.history, false), "Duplicate Spaceship")

	send(&state, Action.Undo)
	testing.expect_value(t, len(scene.nodes), before)
	testing.expect_value(t, state.selectedNode, ship)
	send(&state, Action.Undo)
	testing.expect_value(t, scene.nodes[ship].position, original)
	testing.expect_value(t, len(state.history.redo), 2)
	// Nothing left: no change
	send(&state, Action.Undo)
	testing.expect_value(t, scene.nodes[ship].position, original)

	send(&state, Action.Redo)
	testing.expect_value(t, scene.nodes[ship].position.x, 100)
	send(&state, Action.Redo)
	testing.expect_value(t, len(scene.nodes), before + 2)
	testing.expect_value(t, scene.nodes[state.selectedNode].name, "Spaceship2")

	// A new edit clears the redo stack
	send(&state, Action.Undo)
	send(&state, Node_Renamed("Ship"))
	testing.expect_value(t, len(state.history.redo), 0)

	// Selecting and expanding aren't edits
	count := len(state.history.undo)
	send(&state, Node_Picked(0))
	send(&state, Node_Toggled(0))
	testing.expect_value(t, len(state.history.undo), count)
	free_all(context.temp_allocator)
}

@(test)
undo_merges_edits_to_the_same_thing :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	ship := state.selectedNode

	// Typing a name quickly is one step
	send(&state, Node_Renamed("S"))
	send(&state, Node_Renamed("Sh"))
	send(&state, Node_Renamed("Shi"))
	testing.expect_value(t, len(state.history.undo), 1)
	// A different field starts a new step
	send(&state, Node_Field_Changed{.Rotation, 10})
	send(&state, Node_Field_Changed{.Rotation, 20})
	testing.expect_value(t, len(state.history.undo), 2)
	send(&state, Action.Undo)
	testing.expect_value(t, scene.nodes[ship].rotation, 0)
	send(&state, Action.Undo)
	testing.expect_value(t, scene.nodes[ship].name, "Spaceship")

	// No merging when the window is 0
	History_Destroy(&state.history)
	state.settings.undoMergeMs = 0
	send(&state, Node_Renamed("A"))
	send(&state, Node_Renamed("AB"))
	testing.expect_value(t, len(state.history.undo), 2)

	// The limit drops the oldest steps
	state.settings.undoLimit = 3
	for i in 0..<5 do send(&state, Node_Field_Changed{.Layer, f64(i + 1)})
	testing.expect_value(t, len(state.history.undo), 3)
	free_all(context.temp_allocator)
}

@(test)
undo_merge_timing :: proc(t: ^testing.T) {
	// History_Push with made-up times: debounce at 500 ms, throttle at 3000 ms
	settings := Settings_Default()
	h: History
	defer History_Destroy(&h)
	node := NodeDef_Make("N", .Node2D, -1)
	defer NodeDef_Destroy(&node)
	push :: proc(h: ^History, settings: ^Settings, node: NodeDef, ms: i64, sticky := false) {
		command := UndoCommand{
			label = strings.clone("Edit"), mergeKey = 7, sticky = sticky,
			change = NodeChange{0, NodeDef_Clone(node), NodeDef_Clone(node)},
		}
		now := time.Tick{ms * i64(time.Millisecond)}
		command.started, command.last = now, now
		History_Push(h, command, settings, now)
	}
	push(&h, &settings, node, 0)
	push(&h, &settings, node, 400)
	push(&h, &settings, node, 800)
	testing.expect_value(t, len(h.undo), 1)
	// A pause longer than the merge window
	push(&h, &settings, node, 1400)
	testing.expect_value(t, len(h.undo), 2)
	// Steady edits every 400 ms: cut after 3000 ms
	for ms := i64(1800); ms <= 4600; ms += 400 do push(&h, &settings, node, ms)
	testing.expect_value(t, len(h.undo), 3)
	// Sticky (a drag) merges however long it takes
	push(&h, &settings, node, 20000, sticky = true)
	push(&h, &settings, node, 60000, sticky = true)
	testing.expect_value(t, len(h.undo), 4)
}

@(test)
viewport_drag_is_one_undo_step :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	ship := state.selectedNode
	start := scene.nodes[ship].position

	send(&state, Viewport_Drag_Begin{mode = .Move, node = ship, mouse = {100, 100}})
	send(&state, Viewport_Drag_Move{mouse = {120, 100}})
	send(&state, Viewport_Drag_Move{mouse = {160, 130}})
	send(&state, Viewport_Drag_End{})
	testing.expect_value(t, len(state.history.undo), 1)
	testing.expect(t, scene.nodes[ship].position != start)
	// A second drag is its own step
	send(&state, Viewport_Drag_Begin{mode = .Move, node = ship, mouse = {100, 100}})
	send(&state, Viewport_Drag_Move{mouse = {90, 100}})
	send(&state, Viewport_Drag_End{})
	testing.expect_value(t, len(state.history.undo), 2)
	send(&state, Action.Undo)
	send(&state, Action.Undo)
	testing.expect_value(t, scene.nodes[ship].position, start)
	free_all(context.temp_allocator)
}

@(test)
multi_selection_edits_act_on_every_selected_node :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	before := len(scene.nodes)
	ship, props := nodeNamed(scene, "Spaceship"), nodeNamed(scene, "Props")
	light := nodeNamed(scene, "ShipLight")

	// Ctrl+click adds; a child of a selected node isn't a separate root
	send(&state, Node_Picked(ship))
	send(&state, Node_Pick_Toggled(props))
	send(&state, Node_Pick_Toggled(light))
	testing.expect_value(t, len(state.selection), 3)
	testing.expect_value(t, state.selectedNode, light)
	testing.expect_value(t, len(Selection_Roots(&state)), 2)
	// Toggling again removes it
	send(&state, Node_Pick_Toggled(light))
	testing.expect_value(t, len(state.selection), 2)
	testing.expect_value(t, state.selectedNode, props)

	// Nudge moves both, one undo step
	shipX, propsX := scene.nodes[ship].position.x, scene.nodes[props].position.x
	send(&state, Action.Nudge_Right_Large)
	testing.expect_value(t, scene.nodes[ship].position.x, shipX + NUDGE_LARGE)
	testing.expect_value(t, scene.nodes[props].position.x, propsX + NUDGE_LARGE)
	testing.expect_value(t, len(state.selection), 2)

	// Duplicate both: the copies are selected
	send(&state, Action.Duplicate_Node)
	testing.expect_value(t, len(scene.nodes), before + 2 + 5)
	testing.expect_value(t, len(state.selection), 2)
	names := [2]string{scene.nodes[state.selection[0]].name, scene.nodes[state.selection[1]].name}
	testing.expect_value(t, names, [2]string{"Spaceship2", "Props2"})
	expectValidTree(t, scene)

	// Copy and paste both into HUD
	send(&state, Action.Copy_Node)
	testing.expect_value(t, len(state.clipboard), 7)
	send(&state, Node_Picked(nodeNamed(scene, "HUD")))
	send(&state, Action.Paste_Node)
	testing.expect_value(t, len(state.selection), 2)
	for node in state.selection do testing.expect_value(t, scene.nodes[node].parent, nodeNamed(scene, "HUD"))
	testing.expect_value(t, scene.nodes[state.selection[0]].name, "Spaceship3")
	expectValidTree(t, scene)

	// Delete both pasted subtrees, and undo it
	count := len(scene.nodes)
	send(&state, Action.Delete_Node)
	testing.expect_value(t, len(scene.nodes), count - 7)
	testing.expect_value(t, len(state.selection), 0)
	send(&state, Action.Undo)
	testing.expect_value(t, len(scene.nodes), count)
	expectValidTree(t, scene)

	// Select all, then a plain pick goes back to one node
	send(&state, Action.Select_All)
	testing.expect_value(t, len(state.selection), len(scene.nodes))
	send(&state, Node_Picked(ship))
	testing.expect_value(t, len(state.selection), 1)
	// A structural edit of one node drops the old multi-selection
	send(&state, Action.Select_All)
	send(&state, Action.Deselect)
	testing.expect_value(t, len(state.selection), 0)
	free_all(context.temp_allocator)
}

@(test)
tree_shift_click_selects_a_range :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	// Rows: 0 World, 1 Camera, 2 Spaceship, 3 ShipLight, 4 Props
	send(&state, Node_Selected(1))
	send(&state, Tree_Selection_Clicked{row = 4, range = true})
	testing.expect_value(t, len(state.selection), 4)
	testing.expect_value(t, state.selectedNode, nodeNamed(playScene(&state), "Props"))
	send(&state, Tree_Selection_Clicked{row = 2, range = false})
	testing.expect_value(t, len(state.selection), 3)
	free_all(context.temp_allocator)
}

@(test)
box_select_and_multi_drag :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	// Nothing is rendered in tests, so nodes are picked by their origin
	camera, ship := nodeNamed(scene, "Camera"), nodeNamed(scene, "Spaceship")
	send(&state, Viewport_Drag_Begin{mode = .Box, node = -1, mouse = {600, 340}})
	send(&state, Viewport_Drag_Move{mouse = {700, 440}})
	send(&state, Viewport_Drag_End{})
	// Camera (640, 360), Spaceship (640, 430), Props (640, 360)
	testing.expect_value(t, len(state.selection), 3)
	testing.expect(t, Selection_Contains(&state, camera) && Selection_Contains(&state, ship))

	// Dragging one moves all of them, as one undo step
	cameraStart := scene.nodes[camera].position
	send(&state, Viewport_Drag_Begin{mode = .Move, node = ship, mouse = {640, 430}})
	send(&state, Viewport_Drag_Move{mouse = {660, 440}})
	send(&state, Viewport_Drag_Move{mouse = {700, 450}})
	send(&state, Viewport_Drag_End{})
	testing.expect_value(t, scene.nodes[camera].position, cameraStart + {60, 20})
	testing.expect_value(t, len(state.selection), 3)
	testing.expect_value(t, len(state.history.undo), 1)
	send(&state, Action.Undo)
	testing.expect_value(t, scene.nodes[camera].position, cameraStart)

	// A box on empty space clears the selection; with additive it keeps it
	send(&state, Action.Select_All)
	send(&state, Viewport_Drag_Begin{mode = .Box, node = -1, mouse = {-900, -900}, additive = true})
	send(&state, Viewport_Drag_Move{mouse = {-800, -800}})
	send(&state, Viewport_Drag_End{})
	testing.expect_value(t, len(state.selection), len(scene.nodes))
	free_all(context.temp_allocator)
}

@(test)
snapping_drags_to_the_grid :: proc(t: ^testing.T) {
	node := NodeDef_Make("N", .Sprite, -1)
	defer NodeDef_Destroy(&node)
	node.position = {10, 10}
	drag := ViewportDrag{mode = .Move, startMouse = {10, 10}, startPosition = {10, 10}, startScale = {1, 1}, parentWorld = e.TRANSFORM2D_IDENTITY}
	drag.startWorld = e.Transform2D_Make({10, 10}, 0, {1, 1})
	Viewport_ApplyDrag(&node, &drag, {30, 52}, false, 32)
	testing.expect_value(t, node.position, [2]f32{32, 64})
	drag.mode = .Rotate
	Viewport_ApplyDrag(&node, &drag, {10 + 10, 10 + 3}, false, 32)
	testing.expect_value(t, node.rotation, 15)
	// Uniform scale by the distance from the origin: 10 -> 13.7 is x1.37, snapped to 1.4
	drag = ViewportDrag{mode = .Scale, startMouse = {20, 10}, startScale = {1, 1}, startWorld = e.Transform2D_Make({10, 10}, 0, {1, 1})}
	Viewport_ApplyDrag(&node, &drag, {23.7, 10}, false, 32)
	testing.expect(t, abs(node.scale.x - 1.4) < 1e-4, "scale snaps to 0.1")
}

@(test)
dropping_an_image_adds_a_sprite_there :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	image := -1
	for asset, i in state.project.assets do if asset.path == "assets/ship.png" do image = i
	testing.expect(t, image >= 0)

	// Into the selected Spaceship (at 640, 430): local position relative to it
	send(&state, Asset_Drag_Pressed{asset = image, start = {0, 0}})
	send(&state, Asset_Drag_Started{})
	send(&state, Asset_Dropped{world = {700, 400}})
	sprite := state.selectedNode
	testing.expect_value(t, scene.nodes[sprite].name, "ship")
	testing.expect_value(t, scene.nodes[sprite].texture, "assets/ship.png")
	testing.expect_value(t, scene.nodes[sprite].parent, nodeNamed(scene, "Spaceship"))
	testing.expect_value(t, scene.nodes[sprite].position, [2]f32{60, -30})
	testing.expect(t, !state.assetDrag.pressed)
	send(&state, Action.Undo)
	testing.expect_value(t, nodeNamed(scene, "ship"), -1)
	free_all(context.temp_allocator)
}

@(test)
inline_rename :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	ship := state.selectedNode

	send(&state, Action.Rename_Node)
	testing.expect(t, state.rename.active)
	testing.expect_value(t, state.rename.text, "Spaceship")
	send(&state, Rename_Text_Changed("Hero"))
	send(&state, Rename_Committed{})
	testing.expect(t, !state.rename.active)
	testing.expect_value(t, scene.nodes[ship].name, "Hero")
	testing.expect_value(t, History_NextLabel(&state.history, false), "Rename Spaceship")

	// Escape and empty names change nothing
	send(&state, Rename_Started(ship))
	send(&state, Rename_Text_Changed("Nope"))
	send(&state, Rename_Cancelled{})
	send(&state, Rename_Started(ship))
	send(&state, Rename_Text_Changed("   "))
	send(&state, Rename_Committed{})
	testing.expect_value(t, scene.nodes[ship].name, "Hero")
	send(&state, Action.Undo)
	testing.expect_value(t, scene.nodes[ship].name, "Spaceship")
	free_all(context.temp_allocator)
}

@(test)
texture_none_clears_it :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	send(&state, Node_Text_Changed{.Texture, TEXTURE_NONE})
	testing.expect_value(t, playScene(&state).nodes[state.selectedNode].texture, "")
	free_all(context.temp_allocator)
}

@(test)
unsaved_changes_new_and_open_project :: proc(t: ^testing.T) {
	// The failures below are logged as errors, which the test runner would count as failing
	context.logger = log.nil_logger()
	state := testState()
	defer State_Destroy(&state)
	os.make_directory("build")
	dir := "build/test_projects"
	removeAll(dir)
	os.make_directory(dir)
	defer removeAll(dir)
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone("build/test_projects/Demo")

	testing.expect(t, !Project_IsModified(&state))
	send(&state, Node_Field_Changed{.Rotation, 45})
	testing.expect(t, Project_IsModified(&state))

	// New Project with unsaved changes asks first; Cancel keeps everything
	send(&state, Action.New_Project)
	testing.expect(t, state.session.confirm.open)
	send(&state, Confirm_Chosen(.Cancel))
	testing.expect(t, !state.session.newProject.open)
	// Save from the prompt, then the New Project dialog opens next to the project
	send(&state, Action.New_Project)
	send(&state, Confirm_Chosen(.Save))
	testing.expect(t, !Project_IsModified(&state))
	testing.expect(t, os.exists("build/test_projects/Demo/project.xml"))
	testing.expect(t, state.session.newProject.open)
	testing.expect_value(t, state.session.newProject.location, "build/test_projects")

	// A bad name is refused; a good one creates and opens the project
	send(&state, New_Project_Name_Changed("a/b"))
	send(&state, New_Project_Created{})
	testing.expect(t, state.session.newProject.open)
	send(&state, New_Project_Name_Changed("Fresh"))
	send(&state, New_Project_Created{})
	testing.expect(t, !state.session.newProject.open)
	testing.expect_value(t, state.project.name, "Fresh")
	testing.expect_value(t, state.project.scenes[state.currentScene].name, "Main")
	testing.expect_value(t, len(state.history.undo), 0)
	testing.expect(t, !Project_IsModified(&state))
	// Creating it again fails: the folder exists
	send(&state, Action.New_Project)
	send(&state, New_Project_Name_Changed("Fresh"))
	send(&state, New_Project_Created{})
	testing.expect(t, state.session.newProject.open)
	send(&state, New_Project_Cancelled{})

	// Open the first project back (no changes, so no prompt)
	send(&state, Open_Project_Chosen{path = "build/test_projects/Demo"})
	testing.expect_value(t, state.project.name, "Asteroids Demo")
	testing.expect_value(t, len(state.project.scenes), 3)
	// A folder that isn't a project leaves the current one open
	send(&state, Open_Project_Chosen{path = "build/test_projects/nothing"})
	testing.expect_value(t, state.project.name, "Asteroids Demo")

	// Quit with changes asks; Don't Save quits
	send(&state, Node_Picked(0))
	send(&state, Node_Field_Changed{.Rotation, 10})
	state, _ = update(state, Msg(Action.Quit))
	testing.expect(t, state.session.confirm.open)
	testing.expect_value(t, state.session.confirm.pending, PendingAction.Quit)
	free_all(context.temp_allocator)
}

@(test)
number_field_typing :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	ship := state.selectedNode
	id := skald.hash_id("inspector-Position_X-2")

	// Half-typed text is kept but not applied; a number applies (clamped to the range)
	send(&state, Number_Text_Changed{NodeField.Position_X, id, "-", min(f64), max(f64)})
	testing.expect_value(t, state.numberEdit.text, "-")
	testing.expect_value(t, scene.nodes[ship].position.x, 640)
	send(&state, Number_Text_Changed{NodeField.Position_X, id, "-12.5", min(f64), max(f64)})
	testing.expect_value(t, scene.nodes[ship].position.x, -12.5)
	send(&state, Number_Text_Changed{NodeField.Layer, id, "99", 0, 7})
	testing.expect_value(t, scene.nodes[ship].layer, 7)
	// Typing is undoable like any field change
	testing.expect_value(t, History_NextLabel(&state.history, false), "Change layer of Spaceship")
	send(&state, Number_Edit_Ended(id))
	testing.expect_value(t, state.numberEdit.text, "")

	// Settings fields work the same way
	send(&state, Action.Open_Settings)
	send(&state, Number_Text_Changed{SettingsField.Font_Size, id, "15", 9, 24})
	testing.expect_value(t, state.settingsDialog.draft.fontSize, 15)
	free_all(context.temp_allocator)
}

@(test)
linked_xy_fields_keep_their_ratio :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	ship := state.selectedNode

	// Unlinked: only X changes
	send(&state, Node_Field_Changed{.Scale_X, 2})
	testing.expect_value(t, scene.nodes[ship].scale, [2]f32{2, 1})
	// Linked: 2 x 1 -> 4 x 2, then Y 2 -> 1 gives 2 x 1
	send(&state, Inspector_Link_Toggled(.Scale))
	send(&state, Node_Field_Changed{.Scale_X, 4})
	testing.expect_value(t, scene.nodes[ship].scale, [2]f32{4, 2})
	send(&state, Node_Field_Changed{.Scale_Y, 1})
	testing.expect_value(t, scene.nodes[ship].scale, [2]f32{2, 1})
	// Typing goes through the same path
	send(&state, Number_Text_Changed{NodeField.Scale_X, skald.hash_id("x"), "6", min(f64), max(f64)})
	testing.expect_value(t, scene.nodes[ship].scale, [2]f32{6, 3})

	// Position: 640 x 430 -> 1280 x 860; from 0 there's no ratio, so the same amount
	send(&state, Inspector_Link_Toggled(.Position))
	send(&state, Node_Field_Changed{.Position_X, 1280})
	testing.expect_value(t, scene.nodes[ship].position, [2]f32{1280, 860})
	testing.expect_value(t, LinkedAxis(0, 5, 3), 8)
	testing.expect_value(t, LinkedAxis(2, 3, 0), 1)
	free_all(context.temp_allocator)
}

// A described catalog like the player prints, after some log lines
@(private="file")
TEST_DESCRIPTION :: `[INFO ] --- [2026-10-16 05:00:52] [player.odin:20:run()] starting
{"scripts": [{"name": "Mover", "file": "/p/scripts/mover.odin", "line": 18, "fields": [{"name": "speed", "type": "Float", "default": "100", "hint": "", "min": 0}, {"name": "target", "type": "String", "default": "", "hint": "scene"}, {"name": "mood", "type": "Enum", "default": "Calm", "hint": "", "enum": ["Calm", "Angry"]}]}]}`

@(test)
script_catalog_parses_the_player_description :: proc(t: ^testing.T) {
	scripts, ok := ScriptCatalog_Parse(TEST_DESCRIPTION)
	catalog := ScriptCatalog{scripts = scripts}
	defer ScriptCatalog_Clear(&catalog)
	testing.expect(t, ok)
	testing.expect_value(t, len(scripts), 1)
	mover := ScriptCatalog_Find(&catalog, "Mover")
	testing.expect(t, mover != nil)
	if mover == nil do return
	testing.expect_value(t, mover.line, 18)
	testing.expect_value(t, len(mover.fields), 3)
	testing.expect_value(t, mover.fields[0].type, e.ScriptFieldType.Float)
	testing.expect_value(t, mover.fields[0].min.? or_else -1, 0)
	testing.expect_value(t, mover.fields[1].hint, "scene")
	testing.expect_value(t, mover.fields[2].enumNames[1], "Angry")
	_, bad := ScriptCatalog_Parse("compile error")
	testing.expect(t, !bad)
	free_all(context.temp_allocator)
}

@(test)
attaching_scripts_and_editing_values :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scripts, _ := ScriptCatalog_Parse(TEST_DESCRIPTION)
	state.scripts = {status = .Ready, scripts = scripts}
	node := &playScene(&state).nodes[state.selectedNode]

	send(&state, Node_Script_Changed("Mover"))
	testing.expect_value(t, node.script, "Mover")
	// A value differing from the default is stored; setting the default removes it
	send(&state, Script_Prop_Changed{"speed", "250", "100", SelectedNodeTarget{}})
	testing.expect_value(t, NodeDef_ScriptValue(node, &state.scripts.scripts[0].fields[0]), "250")
	testing.expect_value(t, len(node.props), 1)
	send(&state, Script_Prop_Changed{"speed", "100", "100", SelectedNodeTarget{}})
	testing.expect_value(t, len(node.props), 0)
	// Number fields send typed text through the same path
	target := ScriptPropTarget{name = "speed", defaultValue = "100", component = -1}
	send(&state, Number_Text_Changed{target, skald.hash_id("x"), "42", 0, max(f64)})
	testing.expect_value(t, node.props[0].value, "42")
	testing.expect_value(t, History_NextLabel(&state.history, false), "Change speed of Spaceship")
	// Vector components keep the other one
	vec := ScriptPropTarget{name = "spawn", defaultValue = "0, 0", component = 1, other = 3}
	send(&state, Number_Text_Changed{vec, skald.hash_id("y"), "4", min(f64), max(f64)})
	testing.expect_value(t, node.props[1].value, "3, 4")

	// Detaching clears the values; undo brings both back
	send(&state, Node_Script_Changed(TEXTURE_NONE))
	testing.expect_value(t, node.script, "")
	testing.expect_value(t, len(node.props), 0)
	send(&state, Action.Undo)
	node = &playScene(&state).nodes[state.selectedNode]
	testing.expect_value(t, node.script, "Mover")
	testing.expect_value(t, len(node.props), 2)
	free_all(context.temp_allocator)
}

@(test)
scripts_round_trip_through_scene_files :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	node := &scene.nodes[state.selectedNode]
	delete(node.script)
	node.script = strings.clone("Mover")
	append(&node.props, ScriptPropDef{strings.clone("title"), strings.clone(`Say "hi" & <go>`)})

	text := SceneToXML(scene, context.temp_allocator)
	testing.expect(t, strings.contains(text, `<script name="Mover">`))
	testing.expect(t, strings.contains(text, fmt.tprintf(`formatVersion="%d"`, e.PROJECT_FORMAT_VERSION)))
	parsed, err := e.ParseScene(text)
	defer e.SceneData_Destroy(&parsed)
	testing.expect_value(t, err, e.ProjectError.None)
	ship := parsed.nodes[state.selectedNode]
	testing.expect_value(t, ship.script, "Mover")
	testing.expect_value(t, ship.props[0].value, `Say "hi" & <go>`)
	// Its children are still its children
	testing.expect_value(t, parsed.nodes[state.selectedNode + 1].parent, state.selectedNode)
	free_all(context.temp_allocator)
}

@(test)
new_script_files :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	testing.expect_value(t, ScriptFileFor("PlayerController"), "scripts/player_controller.odin")
	testing.expect_value(t, ScriptNameProblem("PlayerController"), "")
	testing.expect(t, ScriptNameProblem("player") != "")
	testing.expect(t, ScriptNameProblem("9Lives") != "")
	testing.expect(t, ScriptNameProblem("Bad-Name") != "")

	state := testState()
	defer State_Destroy(&state)
	// Never open a real editor from a test
	state.settings.codeEditorPath = FixedText_Make(TEST_NOOP_PROGRAM)
	os.make_directory("build")
	dir := "build/test_script_project"
	removeAll(dir)
	defer removeAll(dir)
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone(dir)
	os.make_directory(dir)

	send(&state, New_Script_Opened{})
	send(&state, New_Script_Name_Changed("Mover"))
	state, _ = update(state, Msg(New_Script_Created{}))
	testing.expect(t, !state.newScript.open)
	testing.expect(t, os.exists("build/test_script_project/scripts/mover.odin"))
	testing.expect_value(t, len(state.scriptFiles), 1)
	testing.expect_value(t, playScene(&state).nodes[state.selectedNode].script, "Mover")
	// The same name again fails and keeps the dialog open
	send(&state, New_Script_Opened{})
	send(&state, New_Script_Name_Changed("Mover"))
	send(&state, New_Script_Created{})
	testing.expect(t, state.newScript.open)
	free_all(context.temp_allocator)
}

@(test)
code_editor_command :: proc(t: ^testing.T) {
	// Looks programs up in a POSIX PATH (sh, true) and expects / paths
	if ODIN_OS == .Windows do return
	expect :: proc(t: ^testing.T, got: []string, want: []string, loc := #caller_location) {
		testing.expect_value(t, len(got), len(want), loc = loc)
		for w, i in want do if i < len(got) do testing.expect_value(t, got[i], w, loc = loc)
	}
	// The program first, then the arguments with {file} and {line} replaced
	expect(t, Script_EditorCommand("/usr/bin/zed", "{file}:{line}", "/p/a.odin", 12), {"/usr/bin/zed", "/p/a.odin:12"})
	expect(t, Script_EditorCommand("code", "  --goto {file}:{line} ", "/p/a.odin", 0), {"code", "--goto", "/p/a.odin:1"})
	// No {file}: it goes at the end. Empty arguments: the default
	expect(t, Script_EditorCommand("gedit", "--new-window", "/p/a.odin", 3), {"gedit", "--new-window", "/p/a.odin"})
	expect(t, Script_EditorCommand("zed", "", "/p/a.odin", 3), {"zed", "/p/a.odin:3"})
	// {folder}: the scripts folder, opened as the workspace (the default arguments use it)
	expect(t, Script_EditorCommand("zed", "", "/p/scripts/a.odin", 3, "/p/scripts"), {"zed", "/p/scripts", "/p/scripts/a.odin:3"})

	// A bare name is looked up in PATH; a path must exist; ~ is the home folder
	sh, found := Script_FindEditorProgram("sh")
	testing.expect(t, found && strings.has_suffix(sh, "/sh"))
	_, missing := Script_FindEditorProgram("/no/such/editor")
	testing.expect(t, !missing)
	_, notInPath := Script_FindEditorProgram("no-such-editor-anywhere")
	testing.expect(t, !notInPath)
	home, _ := Script_FindEditorProgram("~/x")
	testing.expect(t, !strings.has_prefix(home, "~"))

	// Settings files from before the split: one command line
	settings := Settings_Default()
	_ = Settings_Parse(&settings, "[editor]\ncode_editor = code --goto {file}:{line}\n")
	testing.expect_value(t, FixedText_String(&settings.codeEditorPath), "code")
	testing.expect_value(t, FixedText_String(&settings.codeEditorArgs), "--goto {file}:{line}")
	defaults := Settings_Default()
	testing.expect_value(t, FixedText_String(&defaults.codeEditorPath), "zed")
	free_all(context.temp_allocator)
}

@(test)
zed_app_binary_is_swapped_for_its_cli :: proc(t: ^testing.T) {
	// Symlinks (Windows needs extra rights to make them) and Zed's Linux layout
	if ODIN_OS == .Windows do return
	// A fake Zed install: <dir>/libexec/zed-editor (the app), <dir>/bin/zed (the CLI), and a
	// symlink to the app like ~/.local/bin/zed
	os.make_directory("build")
	dir := "build/test_zed"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory_all("build/test_zed/libexec")
	os.make_directory_all("build/test_zed/bin")
	os.make_directory_all("build/test_zed/links")
	_ = os.write_entire_file("build/test_zed/libexec/zed-editor", transmute([]byte)string("app"))
	_ = os.write_entire_file("build/test_zed/bin/zed", transmute([]byte)string("cli"))
	app, _ := os.get_absolute_path("build/test_zed/libexec/zed-editor", context.temp_allocator)
	_ = os.symlink(app, "build/test_zed/links/zed")

	_, isApp := Script_ZedCLIFor("build/test_zed/bin/zed")
	testing.expect(t, !isApp)
	_, isApp = Script_ZedCLIFor("/usr/bin/true")
	testing.expect(t, !isApp)
	// Through the symlink, it's the app; the CLI is found (zeditor in PATH first, if installed)
	cli, viaLink := Script_ZedCLIFor("build/test_zed/links/zed")
	testing.expect(t, viaLink)
	testing.expect(t, strings.has_suffix(cli, "zeditor") || strings.has_suffix(cli, "test_zed/bin/zed"))
	free_all(context.temp_allocator)
}

@(test)
ols_config_for_code_completion :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_ols_project"
	removeAll(dir)
	defer removeAll(dir)
	project := Project_CreateEmpty(dir, "OLS")
	defer Project_Destroy(&project)
	config := "build/test_ols_project/scripts/ols.json"

	// No scripts folder: nothing written
	testing.expect_value(t, Scripts_WriteOLSConfig(&project), "")
	testing.expect(t, !os.exists(config))

	os.make_directory_all("build/test_ols_project/scripts")
	testing.expect_value(t, Scripts_WriteOLSConfig(&project), "")
	data, err := os.read_entire_file(config, context.temp_allocator)
	testing.expect(t, err == nil)
	// Valid JSON naming the two collections the scripts import, with absolute paths
	value, parseErr := json.parse(data, allocator = context.temp_allocator)
	testing.expect_value(t, parseErr, json.Error.None)
	collections := value.(json.Object)["collections"].(json.Array)
	testing.expect_value(t, len(collections), 2)
	engine := collections[0].(json.Object)
	testing.expect_value(t, engine["name"].(json.String), "engine")
	testing.expect(t, filepath.is_abs(engine["path"].(json.String)))
	testing.expect(t, os.exists(fmt.tprintf("%s/script.odin", engine["path"].(json.String))))
	testing.expect_value(t, collections[1].(json.Object)["name"].(json.String), "project")

	// A file without the generated marker is the user's: left alone
	_ = os.write_entire_file(config, transmute([]byte)string(`{"collections": []}`))
	testing.expect_value(t, Scripts_WriteOLSConfig(&project), "")
	kept, _ := os.read_entire_file(config, context.temp_allocator)
	testing.expect_value(t, string(kept), `{"collections": []}`)
	free_all(context.temp_allocator)
}

@(private="file")
sceneNames :: proc(state: ^State) -> []string {
	names := make([]string, len(state.project.scenes), context.temp_allocator)
	for scene, i in state.project.scenes do names[i] = scene.name
	return names
}

@(private="file")
countActions :: proc(state: ^State, action: string) -> int {
	n := 0
	for &scene in state.project.scenes do for &node in scene.nodes do for item in node.items do if item.action == action do n += 1
	return n
}

@(test)
scene_operations_and_undo :: proc(t: ^testing.T) {
	// The refused rename below is logged as an error, which the runner would count as failing
	context.logger = log.nil_logger()
	state := testState()
	defer State_Destroy(&state)
	// Scenes: 0 MenuScene (start), 1 PlayScene (open), 2 OptionsScene
	testing.expect_value(t, len(state.project.scenes), 3)

	// New, after PlayScene: the open scene moves to it
	send(&state, Scene_Action{.New, 1})
	testing.expect_value(t, sceneNames(&state)[2], "Scene")
	testing.expect_value(t, state.currentScene, 2)
	testing.expect(t, state.rename.active && state.rename.target == .Scene)
	send(&state, Rename_Text_Changed("Level2"))
	send(&state, Rename_Committed{})
	testing.expect_value(t, sceneNames(&state)[2], "Level2")

	// Duplicate goes after it, numbered from it
	send(&state, Scene_Action{.Duplicate, 2})
	testing.expect_value(t, sceneNames(&state)[3], "Level3")
	testing.expect_value(t, len(state.project.scenes[3].nodes), len(state.project.scenes[2].nodes))

	// Copy MenuScene, paste at the end
	send(&state, Scene_Action{.Copy, 0})
	send(&state, Scene_Action{.Paste, -1})
	testing.expect_value(t, sceneNames(&state)[5], "MenuScene2")

	// Renaming MenuScene updates the start scene and the menu buttons that go back to it
	testing.expect_value(t, countActions(&state, "scene:MenuScene"), 2 + 0)
	send(&state, Rename_Started(0))
	delete(state.rename.text)
	state.rename = {active = true, target = .Scene, node = 0, text = strings.clone("Title")}
	send(&state, Rename_Committed{})
	testing.expect_value(t, state.project.startScene, "Title")
	testing.expect_value(t, countActions(&state, "scene:Title"), 2)
	testing.expect_value(t, countActions(&state, "scene:MenuScene"), 0)
	// A name that's taken is refused
	state.rename = {active = true, target = .Scene, node = 0, text = strings.clone("PlayScene")}
	send(&state, Rename_Committed{})
	testing.expect_value(t, sceneNames(&state)[0], "Title")

	// Deleting the start scene makes the first remaining one the start
	send(&state, Scene_Action{.Delete, 0})
	testing.expect_value(t, len(state.project.scenes), 5)
	testing.expect_value(t, state.project.startScene, "PlayScene")
	// Set another start scene
	send(&state, Scene_Action{.Set_Start, 1})
	testing.expect_value(t, state.project.startScene, "Level2")

	// Undo all the way back, one scene step at a time
	for len(state.history.undo) > 0 do send(&state, Action.Undo)
	testing.expect_value(t, len(state.project.scenes), 3)
	testing.expect_value(t, sceneNames(&state)[0], "MenuScene")
	testing.expect_value(t, state.project.startScene, "MenuScene")
	testing.expect_value(t, countActions(&state, "scene:MenuScene"), 2)
	// And redo all of it
	for len(state.history.redo) > 0 do send(&state, Action.Redo)
	testing.expect_value(t, state.project.startScene, "Level2")
	testing.expect_value(t, len(state.project.scenes), 5)
	free_all(context.temp_allocator)
}

@(test)
the_last_scene_stays :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	state := testState()
	defer State_Destroy(&state)
	send(&state, Scene_Action{.Delete, 2})
	send(&state, Scene_Action{.Delete, 1})
	testing.expect_value(t, state.currentScene, 0)
	send(&state, Scene_Action{.Delete, 0})
	testing.expect_value(t, len(state.project.scenes), 1)
	testing.expect_value(t, SceneNameProblem(&state.project, "a/b"), "the name can't contain / \\ : * ? \" < > |")
	testing.expect(t, SceneNameProblem(&state.project, "menuscene") != "")
	testing.expect_value(t, SceneNameProblem(&state.project, "Fresh"), "")
	free_all(context.temp_allocator)
}

@(test)
browser_keys_act_on_scenes :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	nodes := len(scene.nodes)
	// Browser focused, PlayScene selected: Ctrl+D duplicates the scene, not a node
	send(&state, Browser_Focus_Changed(true))
	state.browserSelection = {kind = .Scene, folder = .Scenes, index = 1}
	send(&state, Action.Duplicate_Node)
	testing.expect_value(t, len(state.project.scenes), 4)
	testing.expect_value(t, len(playScene(&state).nodes), nodes)
	testing.expect_value(t, History_NextLabel(&state.history, false), "Duplicate scene PlayScene")
	// Delete deletes the selected scene
	state.browserSelection = {kind = .Scene, folder = .Scenes, index = 2}
	send(&state, Action.Delete_Node)
	testing.expect_value(t, len(state.project.scenes), 3)
	// Focus back on the scene tree: keys act on nodes again
	send(&state, Browser_Focus_Changed(false))
	state.selectedNode = nodeNamed(playScene(&state), "Spaceship")
	send(&state, Action.Duplicate_Node)
	testing.expect_value(t, len(state.project.scenes), 3)
	testing.expect_value(t, len(playScene(&state).nodes), nodes + 2)
	free_all(context.temp_allocator)
}

@(test)
save_removes_files_of_renamed_and_deleted_scenes :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	os.make_directory("build")
	dir := "build/test_scene_files"
	removeAll(dir)
	defer removeAll(dir)
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone(dir)
	testing.expect_value(t, Project_Save(&state.project), "")
	testing.expect(t, os.exists("build/test_scene_files/scenes/OptionsScene.scene.xml"))
	// A file of the user's in the folder isn't the editor's to delete
	_ = os.write_entire_file("build/test_scene_files/scenes/notes.txt", transmute([]byte)string("mine"))

	state.rename = {active = true, target = .Scene, node = 2, text = strings.clone("Settings")}
	send(&state, Rename_Committed{})
	send(&state, Scene_Action{.Delete, 1})
	testing.expect_value(t, Project_Save(&state.project), "")
	testing.expect(t, !os.exists("build/test_scene_files/scenes/OptionsScene.scene.xml"))
	testing.expect(t, !os.exists("build/test_scene_files/scenes/PlayScene.scene.xml"))
	testing.expect(t, os.exists("build/test_scene_files/scenes/Settings.scene.xml"))
	testing.expect(t, os.exists("build/test_scene_files/scenes/notes.txt"))
	// The saved project loads back with the new list
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, len(loaded.scenes), 2)
	testing.expect_value(t, loaded.scenes[1].name, "Settings")
	free_all(context.temp_allocator)
}

@(test)
project_settings_dialog :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	send(&state, Action.Open_Project_Settings)
	testing.expect(t, state.projectSettings.open)
	send(&state, Project_Settings_Name_Changed("Space Game"))
	send(&state, Project_Settings_Size_Changed{0, 640})
	send(&state, Project_Settings_Scale_Changed("IntegerScale"))
	send(&state, Project_Settings_Start_Changed("OptionsScene"))
	// Nothing changes until Apply
	testing.expect_value(t, state.project.startScene, "MenuScene")
	send(&state, Project_Settings_Applied{})
	testing.expect(t, !state.projectSettings.open)
	testing.expect_value(t, state.project.name, "Space Game")
	testing.expect_value(t, state.project.gameSize.x, 640)
	testing.expect_value(t, state.project.scaleMode, e.ScaleMode.IntegerScale)
	testing.expect_value(t, state.project.startScene, "OptionsScene")
	testing.expect(t, Project_IsModified(&state))
	send(&state, Action.Undo)
	testing.expect_value(t, state.project.name, "Asteroids Demo")
	testing.expect_value(t, state.project.startScene, "MenuScene")
	free_all(context.temp_allocator)
}

// An export input for a project at /games/Space, with made-up tool paths
@(private="file")
exportTestInput :: proc(target: ExportTarget) -> ExportInput {
	files := make([]string, 2, context.temp_allocator)
	files[0], files[1] = "scenes/Main.scene.xml", "assets/ship.png"
	return {
		target = target,
		settings = ExportSettings_Default().targets[target],
		projectDir = "/games/Space",
		projectName = "Space Game",
		files = files,
		projectXML = `<project name="Space Game"/>`,
		engineDir = "/src/engine",
		emsdkDir = "/src/emsdk",
		mixerDir = "/src/editor/third_party/SDL_mixer",
		mixerBuildScript = "/src/editor/tools/build_web_mixer.sh",
		webLibDir = "/src/editor/build/web",
		webMixerBuilt = true,
		webBox2DBuilt = true,
		workDir = "/src/editor/build/exports/Space-1",
	}
}

@(private="file")
hasArg :: proc(command: []string, arg: string) -> bool {
	for a in command do if a == arg do return true
	return false
}

@(test)
export_settings_ini :: proc(t: ^testing.T) {
	settings := ExportSettings_Default()
	// Untouched settings write nothing
	testing.expect_value(t, ExportSettings_ToINI(&settings, context.temp_allocator), "")

	settings.targets[.Linux_x64].enabled = true
	settings.targets[.Linux_x64].name = FixedText_Make("space")
	settings.targets[.Linux_x64].archive = true
	settings.targets[.Web].enabled = true
	settings.targets[.Web].optimize = false
	settings.targets[.Web].name = FixedText_Make("Space <Game> & Co")
	settings.targets[.Steam].identifier = FixedText_Make("480")
	text := ExportSettings_ToINI(&settings, context.temp_allocator)
	testing.expect(t, strings.contains(text, "[Linux_x64]\nenabled = true\n"))
	testing.expect(t, strings.contains(text, "executable_name = space\n"))
	testing.expect(t, strings.contains(text, "page_title = Space <Game> & Co\n"))
	testing.expect(t, !strings.contains(text, "[Windows_x64]"))

	loaded := ExportSettings_Default()
	problems := ExportSettings_Parse(&loaded, text)
	testing.expect_value(t, len(problems), 0)
	testing.expect(t, loaded == settings)
	// The same text again: deterministic
	testing.expect_value(t, ExportSettings_ToINI(&loaded, context.temp_allocator), text)

	// Bad lines are reported and skipped
	bad := ExportSettings_Default()
	problems = ExportSettings_Parse(&bad, "[Amiga]\nenabled = true\n[Web]\nexecutable_name = x\nenabled = maybe\npage_title = Ok\n")
	testing.expect_value(t, len(problems), 3)
	testing.expect_value(t, FixedText_String(&bad.targets[.Web].name), "Ok")
	testing.expect(t, !bad.targets[.Web].enabled)
	free_all(context.temp_allocator)
}

@(test)
export_plan_linux :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		input := exportTestInput(.Linux_x64)
		// Single file (the default): the project's files go inside the game
		single, singleProblem := Export_Plan(input, context.temp_allocator)
		testing.expect_value(t, singleProblem, "")
		packed := false
		for step in single.steps {
			testing.expect(t, step.kind != .Copy_Files && step.kind != .Write_File, "no data/")
			if step.kind == .Append_Pack {
				packed = true
				testing.expect_value(t, step.path, "/games/Space/export/linux_x64/Space_Game")
				testing.expect_value(t, len(step.files), 2)
				testing.expect_value(t, step.content, input.projectXML)
			}
		}
		testing.expect(t, packed, "a data pack")

		// Single file off: data/ beside the game
		input.settings.singleFile = false
		plan, problem := Export_Plan(input, context.temp_allocator)
		testing.expect_value(t, problem, "")
		testing.expect_value(t, plan.outputDir, "/games/Space/export/linux_x64")
		testing.expect_value(t, plan.archive, "")
		kinds := make([dynamic]ExportStepKind, context.temp_allocator)
		for step in plan.steps do append(&kinds, step.kind)
		testing.expect(t, len(kinds) == 6 && kinds[0] == .Make_Folder && kinds[1] == .Command && kinds[2] == .Copy_Files &&
			kinds[3] == .Write_File && kinds[4] == .Command && kinds[5] == .Bundle_Libraries)
		testing.expect_value(t, plan.steps[0].path, plan.outputDir)

		build := plan.steps[1].command
		testing.expect_value(t, build[2], "/src/engine/player")
		testing.expect(t, hasArg(build, "-collection:engine=/src/engine"))
		testing.expect(t, hasArg(build, "-o:speed"))
		testing.expect(t, hasArg(build, "-out:/games/Space/export/linux_x64/Space_Game"))
		testing.expect(t, hasArg(build, "-extra-linker-flags:-Wl,-rpath,$ORIGIN/lib"))
		testing.expect_value(t, plan.steps[2].path, "/games/Space/export/linux_x64/data")
		testing.expect_value(t, len(plan.steps[2].files), 2)
		// project.xml is written, not copied
		testing.expect(t, plan.steps[3].path == "/games/Space/export/linux_x64/data/project.xml" && plan.steps[3].content == input.projectXML)
		testing.expect(t, plan.steps[4].capture && plan.steps[4].command[0] == "ldd")
		testing.expect_value(t, plan.steps[5].path, "/games/Space/export/linux_x64/lib")

		// With the engine's static SDL, SDL is inside the game: no rpath, nothing to bundle
		input.staticSDL = true
		plan, problem = Export_Plan(input, context.temp_allocator)
		testing.expect_value(t, problem, "")
		for step in plan.steps {
			testing.expect(t, step.kind != .Bundle_Libraries, "nothing to bundle")
			for arg in step.command do testing.expect(t, !strings.contains(arg, "rpath"), "no rpath")
		}
		input.staticSDL = false

		// Scripts: a generated main that links them; no bundling; an archive; a name of its own
		input.hasScripts = true
		input.settings.bundleLibraries = false
		input.settings.optimize = false
		input.settings.archive = true
		input.settings.name = FixedText_Make("space")
		plan, problem = Export_Plan(input, context.temp_allocator)
		testing.expect_value(t, problem, "")
		testing.expect_value(t, plan.steps[1].kind, ExportStepKind.Write_File)
		testing.expect_value(t, plan.steps[1].path, "/src/editor/build/exports/Space-1/main/main.odin")
		testing.expect(t, strings.contains(plan.steps[1].content, `import scripts "project:scripts"`))
		build = plan.steps[2].command
		testing.expect_value(t, build[2], "/src/editor/build/exports/Space-1/main")
		testing.expect(t, hasArg(build, "-collection:project=/games/Space"))
		testing.expect(t, !hasArg(build, "-o:speed"))
		testing.expect(t, hasArg(build, "-out:/games/Space/export/linux_x64/space"))
		testing.expect(t, !hasArg(build, "-extra-linker-flags:-Wl,-rpath,$ORIGIN/lib"))
		last := plan.steps[len(plan.steps) - 1].command
		testing.expect_value(t, plan.archive, "/games/Space/export/linux_x64.tar.gz")
		testing.expect(t, len(last) == 6 && last[0] == "tar" && last[2] == plan.archive && last[4] == "/games/Space/export" && last[5] == "linux_x64")
	}
	free_all(context.temp_allocator)
}

@(test)
export_plan_web :: proc(t: ^testing.T) {
	// The expected paths are POSIX paths (Windows joins with \ and has no root like /src)
	if ODIN_OS == .Windows do return
	input := exportTestInput(.Web)
	input.settings.outputFolder = FixedText_Make("/srv/www/space")
	input.settings.archive = true
	plan, problem := Export_Plan(input, context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, plan.outputDir, "/srv/www/space")
	testing.expect(t, plan.steps[0].kind == .Make_Folder && plan.steps[0].path == "/srv/www/space")
	testing.expect(t, plan.steps[1].kind == .Make_Folder && plan.steps[1].path == "/src/editor/build/exports/Space-1/web")
	plan.steps = plan.steps[2:]
	build := plan.steps[0].command
	testing.expect(t, hasArg(build, "-target:js_wasm32") && hasArg(build, "-build-mode:obj"))
	testing.expect(t, hasArg(build, "-out:/src/editor/build/exports/Space-1/web/game.wasm.o"))
	testing.expect_value(t, plan.steps[1].kind, ExportStepKind.Remove_Folder)
	testing.expect_value(t, plan.steps[1].path, "/src/editor/build/exports/Space-1/web/data")
	testing.expect_value(t, plan.steps[2].kind, ExportStepKind.Copy_Files)
	testing.expect(t, plan.steps[3].kind == .Write_File && plan.steps[3].path == "/src/editor/build/exports/Space-1/web/data/project.xml")
	testing.expect_value(t, plan.steps[4].kind, ExportStepKind.Write_File)
	testing.expect(t, strings.contains(plan.steps[4].content, "<title>Space Game</title>"))
	testing.expect(t, strings.contains(plan.steps[4].content, "{{{ SCRIPT }}}"))
	link := plan.steps[5].command
	testing.expect_value(t, link[0], "/src/emsdk/upstream/emscripten/emcc")
	testing.expect_value(t, link[1], "/src/engine/web/main.c")
	testing.expect_value(t, link[3], "/src/editor/build/web/libSDL3_mixer.a")
	testing.expect_value(t, link[4], "/src/engine/box2d/lib/box2d_web.o")
	testing.expect(t, hasArg(link, "/srv/www/space/index.html"))
	testing.expect(t, hasArg(link, "-sUSE_SDL=3") && hasArg(link, "-sUSE_SDL_TTF=3") && hasArg(link, "-O2"))
	testing.expect(t, hasArg(link, "--preload-file=/src/editor/build/exports/Space-1/web/data@/data"))
	testing.expect(t, hasArg(link, "/src/engine/web/odin_env.js") && hasArg(link, "/src/engine/web/odin_env_pre.js"))
	zip := plan.steps[6]
	testing.expect_value(t, plan.archive, "/srv/www/space.zip")
	testing.expect(t, zip.command[0] == "python3" && zip.workingDir == "/srv/www/space" && hasArg(zip.command, "index.wasm"))
	// Without a built SDL3_mixer, the export builds it first
	input.webMixerBuilt = false
	plan, problem = Export_Plan(input, context.temp_allocator)
	testing.expect_value(t, problem, "")
	mixer := plan.steps[2].command
	testing.expect(t, len(mixer) == 5 && mixer[0] == "bash" && mixer[1] == "/src/editor/tools/build_web_mixer.sh" &&
		mixer[2] == "/src/emsdk" && mixer[3] == "/src/editor/third_party/SDL_mixer" && mixer[4] == "/src/editor/build/web")
	testing.expect(t, hasArg(plan.steps[3].command, "-target:js_wasm32"))
	input.webMixerBuilt = true
	input.webBox2DBuilt = false
	plan, problem = Export_Plan(input, context.temp_allocator)
	box2d := plan.steps[2].command
	testing.expect(t, problem == "" && len(box2d) == 3 && box2d[1] == "/src/engine/tools/build_box2d.sh" && box2d[2] == "/src/emsdk")
	// The title is escaped for HTML
	testing.expect(t, strings.contains(Export_WebShell("A <b> & C", context.temp_allocator), "<title>A &lt;b&gt; &amp; C</title>"))
	free_all(context.temp_allocator)
}

@(test)
export_plan_refusals :: proc(t: ^testing.T) {
	// Targets that aren't done yet say so
	host, _ := Toolchain_HostTarget()
	for target in ([]ExportTarget{.Windows_x64, .macOS_ARM64, .Steam, .PlayStation_5, .Xbox_Series, .Nintendo_Switch, .Linux_ARM64}) {
		// This machine's own target is exportable here (the test input's host is Linux x86_64)
		if target == host do continue
		_, problem := Export_Plan(exportTestInput(target), context.temp_allocator)
		testing.expectf(t, problem != "", "%v should be refused", target)
		testing.expectf(t, !Export_Implemented(target), "%v isn't exportable here", target)
	}
	testing.expect(t, Export_Implemented(.Web))
	// Output folders that would copy the project into itself, or into its own folders (relative
	// ones on every OS: Windows paths use \; the absolute ones are POSIX paths)
	refused := make([dynamic]string, context.temp_allocator)
	fine := make([dynamic]string, context.temp_allocator)
	append(&refused, ".", "assets/out", "scenes", "scripts/x")
	append(&fine, "export/web", "../Space-builds")
	if ODIN_OS != .Windows {
		append(&refused, "/games", "/games/Space")
		append(&fine, "/games/Space-web")
	}
	for folder in refused {
		input := exportTestInput(.Web)
		input.settings.outputFolder = FixedText_Make(folder)
		_, problem := Export_Plan(input, context.temp_allocator)
		testing.expectf(t, problem != "", "output folder %s should be refused", folder)
	}
	for folder in fine {
		input := exportTestInput(.Web)
		input.settings.outputFolder = FixedText_Make(folder)
		_, problem := Export_Plan(input, context.temp_allocator)
		testing.expectf(t, problem == "", "output folder %s should be fine, got: %s", folder, problem)
	}
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		input := exportTestInput(.Linux_x64)
		input.settings.name = FixedText_Make("bin/game")
		_, problem := Export_Plan(input, context.temp_allocator)
		testing.expect(t, strings.contains(problem, "slash"))
	}
	free_all(context.temp_allocator)
}

@(test)
export_parse_ldd :: proc(t: ^testing.T) {
	text := "\tlinux-vdso.so.1 (0x00007ffd)\n" +
		"\tlibSDL3.so.0 => /usr/lib/libSDL3.so.0 (0x00007f01)\n" +
		"\tlibSDL3_ttf.so.0 => /usr/local/lib/libSDL3_ttf.so.0 (0x00007f02)\n" +
		"\tlibSDL3_mixer.so.0 => not found\n" +
		"\tlibc.so.6 => /usr/lib/libc.so.6 (0x00007f03)\n"
	libraries := Export_ParseLdd(text, context.temp_allocator)
	testing.expect_value(t, len(libraries), 2)
	testing.expect_value(t, libraries[0], "/usr/lib/libSDL3.so.0")
	testing.expect_value(t, libraries[1], "/usr/local/lib/libSDL3_ttf.so.0")
	free_all(context.temp_allocator)
}

@(test)
export_settings_saved_with_project :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_export_settings")
	defer removeAll(dir)
	project := Project_CreateDemo(dir)
	defer Project_Destroy(&project)
	testing.expect_value(t, Project_Save(&project), "")
	file, _ := filepath.join({dir, EXPORT_SETTINGS_FILE}, context.temp_allocator)
	// Default settings don't need a file
	testing.expect(t, !os.exists(file))

	project.exports.targets[.Web].enabled = true
	project.exports.targets[.Web].name = FixedText_Make("Play Space")
	testing.expect_value(t, Project_Save(&project), "")
	testing.expect(t, os.exists(file))
	loaded, message, warnings := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, len(warnings), 0)
	testing.expect(t, loaded.exports == project.exports)

	// Back to the defaults: the file stays, with nothing in it
	project.exports = ExportSettings_Default()
	testing.expect_value(t, Project_Save(&project), "")
	data, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "")
	free_all(context.temp_allocator)
}

@(test)
export_settings_dialog :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	// Export with nothing enabled opens the Export tab
	send(&state, Action.Export)
	testing.expect(t, state.projectSettings.open)
	testing.expect_value(t, state.projectSettings.tab, ProjectSettingsTab.Export)
	testing.expect(t, !Export_Busy(&state))

	send(&state, Export_Target_Selected(.Web))
	send(&state, Export_Target_Enabled{.Web, true})
	send(&state, Export_Text_Changed{.Web, .Page_Title, "Space"})
	send(&state, Export_Flag_Changed{.Web, .Archive, true})
	// Nothing changes until Apply
	testing.expect(t, !state.project.exports.targets[.Web].enabled)
	send(&state, Project_Settings_Applied{})
	web := state.project.exports.targets[.Web]
	testing.expect(t, web.enabled && web.archive)
	testing.expect_value(t, FixedText_String(&web.name), "Space")
	// Reopening keeps the shown target
	send(&state, Action.Open_Project_Settings)
	testing.expect_value(t, state.projectSettings.exportTarget, ExportTarget.Web)
	testing.expect_value(t, state.projectSettings.tab, ProjectSettingsTab.General)
	send(&state, Project_Settings_Cancelled{})
	send(&state, Action.Undo)
	testing.expect(t, !state.project.exports.targets[.Web].enabled)
	send(&state, Action.Redo)
	testing.expect(t, state.project.exports.targets[.Web].enabled)
	free_all(context.temp_allocator)
}

@(test)
physics_nodes_round_trip :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_physics")
	defer removeAll(dir)
	project := Project_CreateDemo(dir)
	defer Project_Destroy(&project)
	project.physics = {pixelsPerMeter = 64, gravity = {5, 600}, debugDraw = true}
	scene := &project.scenes[1]
	ground := Scene_InsertNode(scene, "Ground", .StaticBody, -1)
	scene.nodes[ground].collisionLayer = 0b101
	scene.nodes[ground].friction = 0.25
	groundShape := Scene_InsertNode(scene, "GroundShape", .CollisionShape, ground)
	scene.nodes[groundShape].shapeSize = {500, 24}
	crate := Scene_InsertNode(scene, "Crate", .DynamicBody, -1)
	c := &scene.nodes[crate]
	c.restitution, c.density, c.gravityScale, c.linearDamping, c.angularDamping = 0.5, 2.5, 0.5, 0.1, 0.2
	c.fixedRotation, c.bullet = true, true
	c.collisionMask = 0b11
	poly := Scene_InsertNode(scene, "Hull", .CollisionShape, crate)
	scene.nodes[poly].shape = .Polygon
	append(&scene.nodes[poly].points, [2]f32{-10, 0}, [2]f32{10, 0}, [2]f32{0, -12.5})
	scene.nodes[poly].disabled = true
	scene.nodes[poly].oneWay = true
	hero := Scene_InsertNode(scene, "Hero", .CharacterMover, -1)
	scene.nodes[hero].floorMaxAngle = 30
	capsule := Scene_InsertNode(scene, "Body", .CollisionShape, hero)
	scene.nodes[capsule].shape = .Capsule
	scene.nodes[capsule].radius = 9
	scene.nodes[capsule].shapeSize.y = 40
	ray := Scene_InsertNode(scene, "Eyes", .RayCast, hero)
	scene.nodes[ray].target = {120, -4}
	scene.nodes[ray].enabled = false
	scene.nodes[ray].excludeParent = false
	scene.nodes[ray].collisionMask = 1 << 63
	zone := Scene_InsertNode(scene, "Zone", .Area, -1)
	edge := Scene_InsertNode(scene, "Edge", .CollisionShape, zone)
	scene.nodes[edge].shape = .Segment
	append(&scene.nodes[edge].points, [2]f32{0, 0}, [2]f32{64, 8})
	circle := Scene_InsertNode(scene, "Ring", .CollisionShape, zone)
	scene.nodes[circle].shape = .Circle
	scene.nodes[circle].radius = 33

	testing.expect_value(t, Project_Save(&project), "")
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, loaded.physics == project.physics)
	got := &loaded.scenes[1]
	testing.expect_value(t, len(got.nodes), len(scene.nodes))
	for node, i in scene.nodes {
		testing.expectf(t, NodeDef_Equal(node, got.nodes[i]), "node %s differs after loading", node.name)
	}
	// Saving again changes nothing
	file, _ := filepath.join({dir, "scenes", "PlayScene.scene.xml"}, context.temp_allocator)
	first, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, Project_Save(&loaded), "")
	second, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect(t, string(first) == string(second))
	text := string(first)
	testing.expect(t, strings.contains(text, `collisionLayer="1 3"`))
	testing.expect(t, strings.contains(text, `points="-10,0 10,0 0,-12.5"`))
	testing.expect(t, strings.contains(text, `collisionMask="64"`))
	free_all(context.temp_allocator)
}

@(test)
physics_defaults_write_little :: proc(t: ^testing.T) {
	scene := SceneDef{name = strings.clone("S")}
	defer SceneDef_Destroy(&scene)
	body := Scene_InsertNode(&scene, "Body", .DynamicBody, -1)
	_ = Scene_InsertNode(&scene, "Shape", .CollisionShape, body)
	text := SceneToXML(&scene, context.temp_allocator)
	testing.expect(t, strings.contains(text, `<node kind="DynamicBody" name="Body" x="0" y="0">`))
	testing.expect(t, strings.contains(text, `<node kind="CollisionShape" name="Shape" x="0" y="0" shape="Rectangle" width="32" height="32"/>`))
	// Defaults match the engine's: a node made in the editor builds like one from an empty element
	defaults := e.DEFAULT_SCENE_NODE
	def := scene.nodes[body]
	testing.expect(t, def.collisionLayer == defaults.collisionLayer && def.collisionMask == defaults.collisionMask &&
		def.friction == defaults.friction && def.density == defaults.density && def.gravityScale == defaults.gravityScale)
	free_all(context.temp_allocator)
}

@(test)
physics_inspector_edits :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	body := Scene_InsertNode(scene, "Crate", .DynamicBody, -1)
	shape := Scene_InsertNode(scene, "Shape", .CollisionShape, body)
	state.selectedNode = body
	send(&state, Node_Field_Changed{.Density, 3})
	send(&state, Node_Field_Changed{.Restitution, 7}) // clamped to 1
	send(&state, Node_Flag_Changed{.Fixed_Rotation, true})
	send(&state, Node_Layer_Toggled{mask = false, layer = 3})
	send(&state, Node_Layer_Toggled{mask = true, layer = 1})
	crate := &playScene(&state).nodes[body]
	testing.expect(t, crate.density == 3 && crate.restitution == 1 && crate.fixedRotation)
	testing.expect_value(t, crate.collisionLayer, u64(0b101))
	testing.expect_value(t, crate.collisionMask, e.PHYSICS_ALL_LAYERS &~ 1)
	send(&state, Action.Undo)
	testing.expect_value(t, playScene(&state).nodes[body].collisionMask, e.PHYSICS_ALL_LAYERS)

	state.selectedNode = shape
	send(&state, Node_Text_Changed{.Shape, "Polygon"})
	send(&state, Node_Points_Changed{id = 7, text = "0,0 10,0 5,"})
	// Half-typed: kept as text, not applied
	testing.expect_value(t, len(playScene(&state).nodes[shape].points), 0)
	testing.expect_value(t, state.numberEdit.text, "0,0 10,0 5,")
	send(&state, Node_Points_Changed{id = 7, text = "0,0 10,0 5,8"})
	got := &playScene(&state).nodes[shape]
	testing.expect(t, got.shape == .Polygon && len(got.points) == 3 && got.points[2] == {5, 8})
	testing.expect_value(t, shapeBody(playScene(&state), shape), body)
	send(&state, Number_Edit_Ended(7))
	free_all(context.temp_allocator)
}

@(test)
physics_project_settings :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	send(&state, Action.Open_Project_Settings)
	send(&state, Project_Settings_Physics_Changed{.Pixels_Per_Meter, 50})
	send(&state, Project_Settings_Physics_Changed{.Gravity_Y, 400})
	send(&state, Project_Settings_Physics_Debug_Changed(true))
	testing.expect(t, state.project.physics == e.DEFAULT_PHYSICS)
	send(&state, Project_Settings_Applied{})
	testing.expect(t, state.project.physics == e.PhysicsSettings{pixelsPerMeter = 50, gravity = {0, 400}, debugDraw = true, smoothing = true})
	send(&state, Action.Undo)
	testing.expect(t, state.project.physics == e.DEFAULT_PHYSICS)
	text := ProjectToXML(&state.project, context.temp_allocator)
	testing.expect(t, !strings.contains(text, "pixelsPerMeter"))
	free_all(context.temp_allocator)
}

@(test)
physics_joints_in_editor :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_joints")
	defer removeAll(dir)
	project := Project_CreateDemo(dir)
	defer Project_Destroy(&project)
	project.physics.smoothing = false
	scene := &project.scenes[1]
	door := Scene_InsertNode(scene, "Door", .DynamicBody, -1)
	frame := Scene_InsertNode(scene, "Frame", .StaticBody, -1)
	hinge := Scene_InsertNode(scene, "Hinge", .Joint, frame)
	j := &scene.nodes[hinge]
	delete(j.bodyB)
	j.bodyB = strings.clone("Door")
	j.enableLimit, j.lower, j.upper = true, -45, 30
	j.enableMotor, j.motorSpeed, j.maxMotor = true, 90, 5000
	j.enableSpring, j.hertz, j.dampingRatio = true, 2, 0.25
	j.collideConnected = true
	rope := Scene_InsertNode(scene, "Rope", .Joint, -1)
	r := &scene.nodes[rope]
	r.jointKind = .Distance
	delete(r.bodyA)
	r.bodyA = strings.clone("Frame")
	delete(r.bodyB)
	r.bodyB = strings.clone("Door")
	r.jointOffset = {10, 80}
	testing.expect_value(t, Project_Save(&project), "")
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, !loaded.physics.smoothing)
	for node, i in scene.nodes {
		testing.expectf(t, NodeDef_Equal(node, loaded.scenes[1].nodes[i]), "node %s differs after loading", node.name)
	}
	a, b := jointBodies(scene, hinge)
	testing.expect(t, a == frame && b == door)
	a, b = jointBodies(scene, rope)
	testing.expect(t, a == frame && b == door)
	_ = door
	free_all(context.temp_allocator)
}

@(test)
physics_joint_edits_and_renames :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	body := Scene_InsertNode(scene, "Crate", .DynamicBody, -1)
	joint := Scene_InsertNode(scene, "Pin", .Joint, -1)
	state.selectedNode = joint
	send(&state, Node_Text_Changed{.Joint_Kind, "Prismatic"})
	send(&state, Node_Text_Changed{.Body_B, "Crate"})
	send(&state, Node_Text_Changed{.Body_A, JOINT_BODY_DEFAULT})
	send(&state, Node_Flag_Changed{.Limit, true})
	send(&state, Node_Field_Changed{.Upper, 120})
	send(&state, Node_Field_Changed{.Max_Motor, -5}) // clamped
	pin := &playScene(&state).nodes[joint]
	testing.expect(t, pin.jointKind == .Prismatic && pin.bodyB == "Crate" && pin.bodyA == "" && pin.enableLimit && pin.upper == 120 && pin.maxMotor == 0)

	// Renaming the body updates the joint, as one undo step
	state.selectedNode = body
	state.rename = {active = true, target = .Node, node = body, text = strings.clone("Box")}
	send(&state, Rename_Committed{})
	testing.expect_value(t, playScene(&state).nodes[joint].bodyB, "Box")
	send(&state, Action.Undo)
	testing.expect_value(t, playScene(&state).nodes[body].name, "Crate")
	testing.expect_value(t, playScene(&state).nodes[joint].bodyB, "Crate")

	// The toggles
	shown := state.viewport.showShapes
	send(&state, Action.Toggle_Collision_Shapes)
	testing.expect(t, state.viewport.showShapes == !shown)
	// Collision shapes in the game: the project's setting, undoable
	testing.expect(t, !state.project.physics.debugDraw)
	send(&state, Action.Toggle_Physics_Debug)
	testing.expect(t, state.project.physics.debugDraw)
	send(&state, Action.Undo)
	testing.expect(t, !state.project.physics.debugDraw)
	send(&state, Action.Redo)
	testing.expect(t, state.project.physics.debugDraw)
	// Exports never draw them; the project keeps the setting
	exported := Export_ProjectXML(&state.project, context.temp_allocator)
	testing.expect(t, !strings.contains(exported, "physicsDebug"))
	testing.expect(t, strings.contains(ProjectToXML(&state.project, context.temp_allocator), `physicsDebug="true"`))
	// Older editor.ini files with the editor-level setting load without complaint
	parsed := Settings_Default()
	testing.expect_value(t, len(Settings_Parse(&parsed, "[editor]\nplay_collision_shapes = true\n")), 0)
	free_all(context.temp_allocator)
}

@(test)
globals_and_data_round_trip :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_globals_data")
	defer removeAll(dir)
	project := Project_CreateDemo(dir)
	defer Project_Destroy(&project)
	g := GlobalDef{script = strings.clone("GameState")}
	Props_Set(&g.props, "lives", "5", "3")
	append(&project.globals, g, GlobalDef{script = strings.clone("Hud")})
	index, problem := Project_CreateData(&project, "Fast Ship", "ShipStats")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, project.data[index].path, "data/fast_ship.data.json")
	Props_Set(&project.data[index].values, "speed", "300", "100")
	Props_Set(&project.data[index].values, "sprite", "assets/ship.png", "")
	// The same name twice, odd names, no type: refused
	_, problem = Project_CreateData(&project, "fast ship", "ShipStats")
	testing.expect(t, problem != "")
	_, problem = Project_CreateData(&project, "a/b", "ShipStats")
	testing.expect(t, problem != "")
	_, problem = Project_CreateData(&project, "Slow", "")
	testing.expect(t, problem != "")

	testing.expect_value(t, Project_Save(&project), "")
	xml := string(os.read_entire_file(joinPath(dir, "project.xml", allocator = context.temp_allocator), context.temp_allocator) or_else nil)
	testing.expect(t, strings.contains(xml, `<asset path="data/fast_ship.data.json" kind="Data"/>`))
	testing.expect(t, strings.contains(xml, `<global script="GameState">`) && strings.contains(xml, `<prop name="lives" value="5"/>`))
	testing.expect(t, strings.contains(xml, `<global script="Hud"/>`))
	file := string(os.read_entire_file(joinPath(dir, "data/fast_ship.data.json", allocator = context.temp_allocator), context.temp_allocator) or_else nil)
	testing.expect(t, strings.contains(file, `"type": "ShipStats"`) && strings.contains(file, `"speed": "300"`))

	loaded, message, warnings := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, len(warnings), 0)
	testing.expect_value(t, len(loaded.globals), 2)
	testing.expect(t, loaded.globals[0].script == "GameState" && Props_Value(loaded.globals[0].props[:], "lives", "3") == "5")
	testing.expect_value(t, len(loaded.data), 1)
	d := loaded.data[0]
	testing.expect(t, d.type == "ShipStats" && Props_Value(d.values[:], "speed", "100") == "300" && Props_Value(d.values[:], "sprite", "") == "assets/ship.png")
	// Saving again changes nothing
	before := file
	testing.expect_value(t, Project_Save(&loaded), "")
	after := string(os.read_entire_file(joinPath(dir, "data/fast_ship.data.json", allocator = context.temp_allocator), context.temp_allocator) or_else nil)
	testing.expect(t, before == after)
	// Removing the asset removes the resource
	for asset, i in loaded.assets do if asset.kind == .Data {
		testing.expect_value(t, Project_RemoveAsset(&loaded, i, true), "")
		break
	}
	testing.expect_value(t, len(loaded.data), 0)
	testing.expect(t, !os.exists(joinPath(dir, "data/fast_ship.data.json", allocator = context.temp_allocator)))
	free_all(context.temp_allocator)
}

@(test)
generated_asset_constants :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_assets_file")
	defer removeAll(dir)
	project := Project_CreateDemo(dir)
	defer Project_Destroy(&project)
	append(&project.assets, AssetDef{path = strings.clone("assets/laser.wav"), kind = .Audio}, AssetDef{path = strings.clone("other/ship.png"), kind = .Image}, AssetDef{path = strings.clone("fonts/title font.ttf"), kind = .Font})
	_, _ = Project_CreateData(&project, "Fast Ship", "ShipStats")
	source := Scripts_AssetsSource(&project)
	testing.expect(t, strings.contains(source, "package scripts"))
	testing.expect(t, strings.contains(source, `TEXTURE_SHIP :: e.TextureAsset{"assets/ship.png"}`))
	// The second ship.png gets a number
	testing.expect(t, strings.contains(source, `TEXTURE_SHIP_2 :: e.TextureAsset{"other/ship.png"}`))
	testing.expect(t, strings.contains(source, `SOUND_LASER :: e.SoundAsset{"assets/laser.wav"}`))
	testing.expect(t, strings.contains(source, `FONT_TITLE_FONT :: e.FontAsset{"fonts/title font.ttf"}`))
	testing.expect(t, strings.contains(source, `DATA_FAST_SHIP :: e.DataAsset{"data/fast_ship.data.json"}  // ShipStats`))

	// Written only for projects with scripts, and never over a file the user wrote
	path := joinPath(dir, SCRIPTS_FOLDER, ASSETS_FILE, allocator = context.temp_allocator)
	testing.expect_value(t, Scripts_WriteAssetsFile(&project), "")
	testing.expect(t, !os.exists(path))
	_ = os.make_directory_all(joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator))
	_ = os.write_entire_file(joinPath(dir, SCRIPTS_FOLDER, "game.odin", allocator = context.temp_allocator), transmute([]byte)string("package scripts\n"))
	testing.expect_value(t, Scripts_WriteAssetsFile(&project), "")
	testing.expect(t, os.exists(path))
	_ = os.write_entire_file(path, transmute([]byte)string("package scripts // mine\n"))
	testing.expect_value(t, Scripts_WriteAssetsFile(&project), "")
	mine := string(os.read_entire_file(path, context.temp_allocator) or_else nil)
	testing.expect_value(t, mine, "package scripts // mine\n")
	free_all(context.temp_allocator)
}

@(test)
globals_dialog_and_data_edits :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	state.dataSelection = -1
	send(&state, Action.Open_Project_Settings)
	send(&state, Project_Settings_Tab_Changed(.Globals))
	send(&state, Global_Added("GameState"))
	send(&state, Global_Added("Hud"))
	send(&state, Global_Added("GameState")) // already there
	testing.expect_value(t, len(state.projectSettings.globals), 2)
	send(&state, Script_Prop_Changed{"lives", "7", "3", DraftGlobalTarget(0)})
	send(&state, Global_Moved{1, -1})
	testing.expect_value(t, state.projectSettings.globals[0].script, "Hud")
	// Nothing changes until Apply
	testing.expect_value(t, len(state.project.globals), 0)
	send(&state, Project_Settings_Applied{})
	testing.expect_value(t, len(state.project.globals), 2)
	testing.expect(t, state.project.globals[1].script == "GameState" && Props_Value(state.project.globals[1].props[:], "lives", "3") == "7")
	send(&state, Action.Undo)
	testing.expect_value(t, len(state.project.globals), 0)
	send(&state, Action.Redo)
	testing.expect_value(t, len(state.project.globals), 2)
	send(&state, Action.Open_Project_Settings)
	send(&state, Global_Removed(0))
	send(&state, Project_Settings_Applied{})
	testing.expect(t, len(state.project.globals) == 1 && state.project.globals[0].script == "GameState")

	// A data resource: chosen in the browser, edited (undoable), deselected by picking a node
	append(&state.project.assets, AssetDef{path = strings.clone("data/boss.data.json"), kind = .Data})
	append(&state.project.data, DataDef{path = strings.clone("data/boss.data.json"), type = strings.clone("EnemyStats")})
	asset := len(state.project.assets) - 1
	send(&state, Browser_Right_Clicked(-1))
	state.browserOpen[.Data] = true
	rows := BrowserRows(&state)
	for row, i in rows do if row.kind == .Asset && row.index == asset do send(&state, Browser_Right_Clicked(i))
	testing.expect_value(t, state.dataSelection, 0)
	send(&state, Script_Prop_Changed{"health", "99", "10", DataTarget(0)})
	testing.expect_value(t, Props_Value(state.project.data[0].values[:], "health", "10"), "99")
	send(&state, Action.Undo)
	testing.expect_value(t, Props_Value(state.project.data[0].values[:], "health", "10"), "10")
	send(&state, Node_Selected(1))
	testing.expect_value(t, state.dataSelection, -1)

	// The catalog lists data types
	scripts, dataTypes, _, ok := ScriptCatalog_ParseAll(`{"scripts": [], "data": [{"name": "EnemyStats", "file": "a.odin", "line": 3, "fields": [{"name": "health", "type": "Int", "default": "10", "hint": ""}, {"name": "sprite", "type": "Texture", "default": "", "hint": ""}]}]}`)
	catalog := ScriptCatalog{scripts = scripts, dataTypes = dataTypes}
	defer ScriptCatalog_Clear(&catalog)
	testing.expect(t, ok && len(dataTypes) == 1 && len(dataTypes[0].fields) == 2 && dataTypes[0].fields[1].type == .Texture)
	free_all(context.temp_allocator)
}

@(test)
particle_emitter_round_trip :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_particles")
	defer removeAll(dir)
	project := Project_CreateDemo(dir)
	defer Project_Destroy(&project)
	scene := &project.scenes[1]
	plain := Scene_InsertNode(scene, "Plain", .ParticleEmitter, -1)
	sparks := Scene_InsertNode(scene, "Sparks", .ParticleEmitter, -1)
	p := &scene.nodes[sparks].particles
	p.amount, p.burst, p.size, p.shape, p.continuous, p.localSpace = 120, 0.25, {3, 4.5}, .Texture, false, true
	p.particleColor, p.colorEnd = {1, 2, 3, 4}, {250, 251, 252, 0}
	p.gravityDirection, p.wind = {-0.5, 1}, {20, -3}
	e.ColorRamp_AddStop(&p.colorRamp, 0.75, {9, 8, 7, 6})
	delete(scene.nodes[sparks].texture)
	scene.nodes[sparks].texture = strings.clone(project.assets[0].path)

	testing.expect_value(t, Project_Save(&project), "")
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	got := &loaded.scenes[1]
	testing.expect(t, NodeDef_Equal(scene.nodes[plain], got.nodes[plain]), "default emitter")
	testing.expect(t, NodeDef_Equal(scene.nodes[sparks], got.nodes[sparks]), "emitter with settings")
	testing.expect_value(t, got.nodes[sparks].particles, scene.nodes[sparks].particles)

	file, _ := filepath.join({dir, "scenes", "PlayScene.scene.xml"}, context.temp_allocator)
	text, _ := os.read_entire_file(file, context.temp_allocator)
	// Only what differs from the defaults; a default emitter has no <particles>
	testing.expect(t, strings.contains(string(text), `<particles continuous="false" amount="120"`))
	testing.expect_value(t, strings.count(string(text), "<particles"), 1)
	testing.expect(t, strings.contains(string(text), fmt.tprintf(`formatVersion="%d"`, e.PROJECT_FORMAT_VERSION)))
}

@(test)
particle_inspector_edits :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	send(&state, Add_Node_Kind_Chosen(.ParticleEmitter))
	index := nodeIndex(scene, "ParticleEmitter")
	testing.expect(t, index >= 0, "added")
	state.selectedNode = index
	node := &scene.nodes[index]
	testing.expect_value(t, node.particles, e.DEFAULT_PARTICLE_SETTINGS)

	send(&state, Particle_Field_Changed{"amount", "80"})
	send(&state, Particle_Field_Changed{"shape", "Rectangle"})
	send(&state, Particle_Field_Changed{"useColorRamp", "false"})
	send(&state, Particle_Field_Changed{"amount", "lots"}) // Not a number: ignored
	testing.expect_value(t, node.particles.amount, 80)
	testing.expect_value(t, node.particles.shape, e.ParticleShape.Rectangle)
	testing.expect(t, !node.particles.useColorRamp)

	// Unlinked, one axis; linked, the other follows in proportion
	send(&state, Particle_Axis_Changed{"size", 0, 10})
	testing.expect_value(t, node.particles.size, [2]f32{10, 5})
	sizeIndex := ParticleField_Index("size")
	send(&state, Particle_Link_Toggled(sizeIndex))
	testing.expect(t, sizeIndex in state.particleLinks)
	send(&state, Particle_Axis_Changed{"size", 0, 20})
	testing.expect_value(t, node.particles.size, [2]f32{20, 10})

	// The ramp: edits select the stop they leave selected
	ramp := node.particles.colorRamp
	at := e.ColorRamp_AddStop(&ramp, 0.25, {0, 0, 255, 128})
	send(&state, Ramp_Edited{FormatRampText(ramp), at})
	testing.expect_value(t, node.particles.colorRamp.count, 4)
	testing.expect_value(t, state.rampStop, 1)

	// Each change is an undo step; Reset is one more
	undoBefore := len(state.history.undo)
	send(&state, Particles_Reset{})
	testing.expect_value(t, node.particles, e.DEFAULT_PARTICLE_SETTINGS)
	testing.expect_value(t, len(state.history.undo), undoBefore + 1)
	send(&state, Action.Undo)
	node = &scene.nodes[index]
	testing.expect_value(t, node.particles.amount, 80)
	testing.expect_value(t, node.particles.colorRamp.count, 4)
	free_all(context.temp_allocator)
}

// Tests that render through the viewport preview (package state, one SDL renderer) take turns,
// ldtk_edit_test.odin's too
previewTestLock: sync.Mutex

@(test)
viewport_shows_particles :: proc(t: ^testing.T) {
	// The preview is package state: one test at a time uses it, and frees it (its memory is the test's)
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	// A project without images (the preview would try to load them)
	state := testState()
	defer State_Destroy(&state)
	Project_Destroy(&state.project)
	state.project = Project_CreateEmpty("unused", "Particles")
	state.currentScene = 0
	scene := &state.project.scenes[0]
	index := Scene_InsertNode(scene, "Sparks", .ParticleEmitter, -1)
	emitter := &scene.nodes[index]
	emitter.position = {50, 50}
	emitter.particles.burst = 1
	emitter.particles.size = {12, 12}
	emitter.particles.velocity = 0
	emitter.particles.gravityVelocity = 0
	emitter.particles.useColorRamp = false
	emitter.particles.particleColor = {255, 0, 255, 255}
	emitter.particles.colorEnd = {255, 0, 255, 255}
	state.viewport = {center = {50, 50}, zoom = 1, size = {100, 100}, animate = true}

	magenta :: proc(pixels: []u8) -> int {
		count := 0
		for i := 0; i + 3 < len(pixels); i += 4 do if pixels[i] > 240 && pixels[i + 1] < 20 && pixels[i + 2] > 240 do count += 1
		return count
	}
	// The first render builds the scene; the next ones run it (particles move in real time)
	_, ok := Preview_Render(&state, {100, 100}, 1)
	testing.expect(t, ok, "rendered")
	time.sleep(20 * time.Millisecond)
	pixels, _ := Preview_Render(&state, {100, 100}, 1)
	testing.expectf(t, magenta(pixels) > 300, "particles drawn: %d px", magenta(pixels))
	// A setting edited in the inspector shows without rebuilding: smaller particles
	emitter.particles.size = {3, 3}
	time.sleep(20 * time.Millisecond)
	pixels, _ = Preview_Render(&state, {100, 100}, 1)
	testing.expect(t, Preview_IsAnimated(), "keeps frames coming")
	smaller := magenta(pixels)
	// Old particles keep their size; new ones are smaller (one burst: the next cycle hasn't come)
	testing.expectf(t, smaller > 0, "still drawn: %d px", smaller)
	free_all(context.temp_allocator)
}

@(test)
slider_values_are_short_text :: proc(t: ^testing.T) {
	testing.expect_value(t, formatSliderValue(0.94600004, 3), "0.946")
	testing.expect_value(t, formatSliderValue(100, 2), "100")
	testing.expect_value(t, formatSliderValue(0.5, 4), "0.5")
	testing.expect_value(t, formatSliderValue(-0.0001, 2), "0")
	testing.expect_value(t, formatSliderValue(12.25, 0), "12")
	// A linked pair keeps short numbers too
	settings := e.DEFAULT_PARTICLE_SETTINGS
	ParticleSettings_SetAxis(&settings, "size", 0, 0.30000001, false)
	text, _ := e.ParticleSettings_Get(settings, "size")
	testing.expect_value(t, text, "0.3,5")
}

@(test)
animation_frames_over_time :: proc(t: ^testing.T) {
	walk := AnimationDef{name = "walk", start = 2, end = 5, fps = 10, loop = true, playMode = .Forward}
	// 4 frames at 10 fps: a frame every 0.1 s, looping
	testing.expect_value(t, AnimationDef_FrameAt(walk, 8, 0), 2)
	testing.expect_value(t, AnimationDef_FrameAt(walk, 8, 0.25), 4)
	testing.expect_value(t, AnimationDef_FrameAt(walk, 8, 0.45), 2)
	once := walk
	once.loop = false
	testing.expect_value(t, AnimationDef_FrameAt(once, 8, 3), 5) // Holds the last
	back := walk
	back.playMode = .Reverse
	testing.expect_value(t, AnimationDef_FrameAt(back, 8, 0), 5)
	testing.expect_value(t, AnimationDef_FrameAt(back, 8, 0.15), 4)
	ping := walk
	ping.playMode = .PingPong
	// 2 3 4 5 4 3 | 2 ...
	frames: [8]int
	for &f, i in frames do f = AnimationDef_FrameAt(ping, 8, f64(i) * 0.1 + 0.01)
	testing.expect_value(t, frames, [8]int{2, 3, 4, 5, 4, 3, 2, 3})
	// end -1: to the last cell; out of the sheet: kept inside it
	start, end := AnimationDef_Range({name = "all", start = 0, end = -1, fps = 8, loop = true, playMode = .Forward}, 6)
	testing.expect_value(t, [2]int{start, end}, [2]int{0, 5})
	start, end = AnimationDef_Range({name = "far", start = 9, end = 20, fps = 8, loop = true, playMode = .Forward}, 6)
	testing.expect_value(t, [2]int{start, end}, [2]int{5, 5})
}

@(test)
animation_panel_edits :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	state.selectedNode = nodeIndex(scene, "Balloon") // 4x1 sheet, one "default" animation
	node := &scene.nodes[state.selectedNode]
	testing.expect_value(t, len(node.animations), 1)

	send(&state, Anim_Added{})
	send(&state, Anim_Name_Typed{1, "walk"})
	send(&state, Anim_Frame_Clicked{1, false})
	send(&state, Anim_Frame_Clicked{2, true})
	send(&state, Anim_Field_Changed{.FPS, 12})
	walk := node.animations[1]
	testing.expect_value(t, walk.name, "walk")
	testing.expect_value(t, [2]int{walk.start, walk.end}, [2]int{1, 2})
	testing.expect_value(t, walk.fps, 12)

	// A start past the end takes the end along; an end before the start, the start
	send(&state, Anim_Field_Changed{.Start, 3})
	testing.expect_value(t, [2]int{node.animations[1].start, node.animations[1].end}, [2]int{3, 3})
	send(&state, Anim_Field_Changed{.End, 0})
	testing.expect_value(t, [2]int{node.animations[1].start, node.animations[1].end}, [2]int{0, 0})

	// Names: unique when duplicated; a taken or empty name waits
	send(&state, Anim_Duplicated{})
	testing.expect_value(t, node.animations[2].name, "walk2")
	send(&state, Anim_Name_Typed{1, "default"})
	send(&state, Anim_Name_Typed{1, ""})
	testing.expect_value(t, node.animations[2].name, "walk2")
	testing.expect_value(t, state.animEditor.nameText, "")

	// Starts with: follows a rename, cleared when removed
	send(&state, Anim_Autoplay_Set{})
	testing.expect_value(t, node.autoplay, "walk2")
	send(&state, Anim_Name_Typed{1, "run"})
	testing.expect_value(t, node.autoplay, "run")
	send(&state, Anim_Moved(-1))
	testing.expect_value(t, node.animations[1].name, "run")
	testing.expect_value(t, state.animEditor.selected, 1)
	send(&state, Anim_Removed{})
	testing.expect_value(t, node.autoplay, "")
	testing.expect_value(t, len(node.animations), 2)
	send(&state, Anim_Removed{})
	send(&state, Anim_Removed{}) // Keeps one
	testing.expect_value(t, len(node.animations), 1)

	// All undoable
	for _ in 0 ..< 30 do send(&state, Action.Undo)
	node = &playScene(&state).nodes[state.selectedNode]
	testing.expect_value(t, len(node.animations), 1)
	testing.expect_value(t, node.animations[0].name, "default")
	free_all(context.temp_allocator)
}

@(test)
animations_round_trip :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_animations")
	defer removeAll(dir)
	project := Project_CreateDemo(dir)
	defer Project_Destroy(&project)
	scene := &project.scenes[1]
	hero := &scene.nodes[nodeIndex(scene, "Balloon")]
	hero.animations[0].grid.margin, hero.animations[0].grid.spacing = 1, 2
	// Another sheet, cut by cell size
	append(&hero.animations, AnimationDef{name = strings.clone("pop"), sheet = strings.clone("assets/light.png"), grid = {mode = .Size, columns = 1, rows = 1, cellSize = {64, 32}, spacing = 1},
		start = 2, end = 3, fps = 15, loop = false, playMode = .PingPong})
	delete(hero.autoplay)
	hero.autoplay = strings.clone("pop")

	testing.expect_value(t, Project_Save(&project), "")
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	for node, i in scene.nodes do testing.expectf(t, NodeDef_Equal(node, loaded.scenes[1].nodes[i]), "%s differs after loading", node.name)
	xml := SceneToXML(scene, context.temp_allocator)
	testing.expect(t, strings.contains(xml, `<animation name="pop" sheet="assets/light.png" grid="Size" cellWidth="64" cellHeight="32" spacing="1" start="2"`), xml)
	testing.expect(t, strings.contains(xml, `<animation name="default" sheet="assets/balloons.png" columns="4" rows="1" margin="1" spacing="2"`), xml)

	// A file from before format 7: its one animation comes from the node's fps, loop and play mode
	old := `<scene formatVersion="6" name="Old"><node kind="AnimatedSprite" name="Fan" texture="fan.png" columns="3" fps="6" loop="false" playMode="Reverse"/></scene>`
	path := joinPath(dir, "scenes", "Old.scene.xml", allocator = context.temp_allocator)
	_ = os.write_entire_file(path, old)
	append(&loaded.scenes, SceneDef{name = strings.clone("Old")})
	data, _ := e.LoadSceneFile(path)
	defer e.SceneData_Destroy(&data)
	testing.expect_value(t, len(data.nodes[0].animations), 1)
	text := strings.concatenate({`<?xml version="1.0"?><project formatVersion="6" name="P"><scene name="Old" path="scenes/Old.scene.xml"/></project>`}, context.temp_allocator)
	_ = os.write_entire_file(joinPath(dir, "project.xml", allocator = context.temp_allocator), text)
	again, message2, _ := Project_Load(dir)
	defer Project_Destroy(&again)
	testing.expect_value(t, message2, "")
	fan := again.scenes[0].nodes[0]
	testing.expect_value(t, len(fan.animations), 1)
	testing.expect(t, AnimationDef_Equal(fan.animations[0], AnimationDef{name = "default", sheet = "fan.png", grid = {mode = .Cells, columns = 3, rows = 1}, start = 0, end = -1, fps = 6, loop = false, playMode = .Reverse}), "fan's default animation, on the node's old sheet")
	testing.expect_value(t, fan.texture, "")
	free_all(context.temp_allocator)
}

@(test)
input_actions_round_trip :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_input")
	defer removeAll(dir)
	project := Project_CreateDemo(dir)
	defer Project_Destroy(&project)
	testing.expect_value(t, len(project.actions), 6) // The default ui_* actions
	jump := ActionDef{name = strings.clone("jump"), deadzone = 0.25}
	append(&jump.bindings, e.KeyBinding{.Space}, e.MouseBinding{.WheelUp}, e.GamepadButtonBinding{.South, 1}, e.GamepadAxisBinding{.RightTrigger, 1, -1})
	append(&project.actions, jump)
	append(&project.actions, ActionDef{name = strings.clone("empty"), deadzone = e.DEFAULT_ACTION_DEADZONE})

	testing.expect_value(t, Project_Save(&project), "")
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, actionsEqual(project.actions[:], loaded.actions[:]), "actions survive saving")

	text, _ := os.read_entire_file(joinPath(dir, "project.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(text), `<action name="jump" deadzone="0.25">`))
	testing.expect(t, strings.contains(string(text), `<gamepad button="South" device="1"/>`))
	testing.expect(t, strings.contains(string(text), `<action name="empty"/>`))
	// Scripts get a constant per action
	source := Scripts_AssetsSource(&project)
	testing.expect(t, strings.contains(source, `ACTION_JUMP :: "jump"`))
	testing.expect(t, strings.contains(source, `ACTION_UI_LEFT :: "ui_left"`))
	free_all(context.temp_allocator)
}

@(test)
input_settings_edits :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	send(&state, Action.Open_Project_Settings)
	send(&state, Project_Settings_Tab_Changed(.Input))
	d := &state.projectSettings
	count := len(d.actions)

	send(&state, Input_New_Name_Changed("jump"))
	send(&state, Input_Action_Added{})
	testing.expect_value(t, len(d.actions), count + 1)
	testing.expect_value(t, d.selectedAction, count)
	send(&state, Input_New_Name_Changed("jump"))
	send(&state, Input_Action_Added{}) // Taken
	testing.expect_value(t, len(d.actions), count + 1)

	send(&state, Input_Binding_Added{e.KeyBinding{.Space}})
	send(&state, Input_Binding_Added{e.KeyBinding{.Space}}) // Already there
	send(&state, Input_Device_Changed(0))
	send(&state, Input_Binding_Added{e.GamepadButtonBinding{.South, 0}})
	send(&state, Input_Deadzone_Changed(0.3))
	jump := &d.actions[d.selectedAction]
	testing.expect_value(t, len(jump.bindings), 2)
	testing.expect_value(t, jump.deadzone, 0.3)
	send(&state, Input_Binding_Removed(0))
	testing.expect_value(t, jump.bindings[0], e.InputBinding(e.GamepadButtonBinding{.South, 0}))

	// Renaming: a taken or empty name waits
	send(&state, Input_Action_Renamed("ui_left"))
	testing.expect_value(t, jump.name, "jump")
	send(&state, Input_Action_Renamed("leap"))
	testing.expect_value(t, jump.name, "leap")
	send(&state, Input_Action_Moved{d.selectedAction, -1})
	testing.expect_value(t, d.actions[count - 1].name, "leap")

	// Nothing changes until Apply, which is one undo step
	testing.expect_value(t, len(state.project.actions), count)
	send(&state, Project_Settings_Applied{})
	testing.expect_value(t, len(state.project.actions), count + 1)
	testing.expect_value(t, state.project.actions[count - 1].name, "leap")
	send(&state, Action.Undo)
	testing.expect_value(t, len(state.project.actions), count)
	send(&state, Action.Redo)
	testing.expect_value(t, len(state.project.actions), count + 1)

	// Skald's key names to the engine's
	testing.expect_value(t, EngineKeyFor(.Page_Up), e.Key.PageUp)
	testing.expect_value(t, EngineKeyFor(.N7), e.Key.Num7)
	testing.expect_value(t, EngineKeyFor(.Left_Bracket), e.Key.LeftBracket)
	for key in skald.Key do testing.expectf(t, EngineKeyFor(key) != .Unknown, "Skald's %v has an engine key", key)
	free_all(context.temp_allocator)
}

@(test)
components_save_open_instance :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_components")
	defer removeAll(dir)
	state := testState()
	defer State_Destroy(&state)
	Project_Destroy(&state.project)
	state.project = Project_CreateDemo(dir)
	testing.expect_value(t, Project_Save(&state.project), "")
	scene := playScene(&state)
	props := nodeIndex(scene, "Props")
	propsNode := scene.nodes[props]
	children := Scene_DescendantCount(scene, props)
	testing.expect(t, children > 0, "Props has children")
	nodeCount := len(scene.nodes)

	// Save as Component: the subtree becomes a component, the node an instance of it
	state.selectedNode = props
	send(&state, Action.Save_As_Component)
	scene = playScene(&state)
	instance := scene.nodes[props]
	testing.expect_value(t, instance.kind, NodeKind.Component)
	testing.expect_value(t, instance.component, "components/props.component.xml")
	testing.expect_value(t, instance.position, propsNode.position)
	testing.expect_value(t, len(scene.nodes), nodeCount - children)
	component := Project_FindComponent(&state.project, "components/props.component.xml")
	testing.expect(t, component >= 0, "a component")
	testing.expect_value(t, len(state.project.scenes[component].nodes), children + 1)
	testing.expect_value(t, state.project.scenes[component].nodes[0].position, [2]f32{0, 0}) // The instance has the transform
	testing.expect(t, os.exists(joinPath(dir, "components/props.component.xml", allocator = context.temp_allocator)), "its file")
	testing.expect_value(t, Project_SceneCount(&state.project), 3) // Not a scene
	testing.expect(t, strings.contains(Scripts_AssetsSource(&state.project), `COMPONENT_PROPS :: e.ComponentAsset{"components/props.component.xml"}`), "a constant")

	// Instances: more of it, at the view's middle under the selection
	asset := -1
	for a, i in state.project.assets do if a.kind == .Component do asset = i
	state.selectedNode = -1
	send(&state, Component_Instance_Added(asset))
	testing.expect_value(t, playScene(&state).nodes[state.selectedNode].name, "props")

	// Opened, it's edited like a scene; it can't hold itself
	send(&state, Component_Opened(component))
	testing.expect_value(t, state.currentScene, component)
	testing.expect(t, slice.contains(ViewportTabScenes(&state), component), "a tab")
	before := len(state.project.scenes[component].nodes)
	send(&state, Component_Instance_Added(asset))
	testing.expect_value(t, len(state.project.scenes[component].nodes), before)

	// Saving and loading keep it all
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	loadedComponent := Project_FindComponent(&loaded, "components/props.component.xml")
	testing.expect(t, loadedComponent >= 0, "loaded")
	for node, i in state.project.scenes[component].nodes {
		testing.expectf(t, NodeDef_Equal(node, loaded.scenes[loadedComponent].nodes[i]), "%s differs after loading", node.name)
	}
	project, _ := os.read_entire_file(joinPath(dir, "project.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, !strings.contains(string(project), `<scene name="props"`), "not in the scene list")
	testing.expect(t, strings.contains(string(project), `kind="Component"`), "an asset")

	// Undo brings the subtree back (the component stays, like other assets)
	openScene(&state, 1)
	for _ in 0 ..< 3 do send(&state, Action.Undo)
	testing.expect_value(t, len(playScene(&state).nodes), nodeCount)
	testing.expect(t, Project_FindComponent(&state.project, "components/props.component.xml") >= 0, "still an asset")

	// Removing the asset removes it
	state.removeConfirm = {open = true, asset = asset}
	send(&state, Asset_Remove_Confirmed{deleteFile = true})
	testing.expect_value(t, Project_FindComponent(&state.project, "components/props.component.xml"), -1)
	testing.expect(t, state.currentScene < len(state.project.scenes), "the viewport's scene is valid")
	free_all(context.temp_allocator)
}

@(test)
components_render_in_instances_and_thumbnails :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	state := testState()
	defer State_Destroy(&state)
	Project_Destroy(&state.project)
	state.project = Project_CreateEmpty("unused", "Components")
	state.currentScene = 0
	// A component (in memory: no file) of a magenta label, and an instance of it
	component := SceneDef{name = strings.clone("badge"), component = strings.clone("components/badge.component.xml")}
	label := Scene_InsertNode(&component, "Badge", .Label, -1)
	delete(component.nodes[label].text)
	component.nodes[label].text = strings.clone("BADGE")
	component.nodes[label].fontSize = 40
	component.nodes[label].color = {255, 0, 255, 255}
	append(&state.project.scenes, component)
	append(&state.project.assets, AssetDef{path = strings.clone("components/badge.component.xml"), kind = .Component})
	scene := &state.project.scenes[0]
	index := Scene_InsertNode(scene, "Badge1", .Component, -1)
	delete(scene.nodes[index].component)
	scene.nodes[index].component = strings.clone("components/badge.component.xml")
	scene.nodes[index].position = {50, 50}
	state.viewport = {center = {50, 50}, zoom = 1, size = {200, 120}}

	magenta :: proc(pixels: []u8) -> int {
		count := 0
		for i := 0; i + 3 < len(pixels); i += 4 do if pixels[i] > 200 && pixels[i + 1] < 60 && pixels[i + 2] > 200 do count += 1
		return count
	}
	pixels, ok := Preview_Render(&state, {200, 120}, 1)
	testing.expect(t, ok && magenta(pixels) > 50, "the instance is drawn in the viewport")
	thumb, key, thumbOk := Preview_RenderComponent(&state, 1, {160, 100})
	testing.expect(t, thumbOk && magenta(thumb) > 50, "and in its thumbnail")
	// Edited, the thumbnail changes
	state.project.scenes[1].nodes[0].color = {0, 255, 0, 255}
	_, again, _ := Preview_RenderComponent(&state, 1, {160, 100})
	testing.expect(t, again != key, "a new picture")
	free_all(context.temp_allocator)
}

@(test)
components_rename_and_make_unique :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_component_rename")
	defer removeAll(dir)
	state := testState()
	defer State_Destroy(&state)
	Project_Destroy(&state.project)
	state.project = Project_CreateDemo(dir)
	testing.expect_value(t, Project_Save(&state.project), "")
	scene := playScene(&state)
	state.selectedNode = nodeIndex(scene, "Props")
	send(&state, Action.Save_As_Component)
	asset := -1
	for a, i in state.project.assets do if a.kind == .Component do asset = i
	send(&state, Component_Instance_Added(asset)) // A second instance
	second := state.selectedNode

	// Rename: the file moves, every instance follows
	send(&state, Component_Rename_Started(asset))
	testing.expect(t, state.rename.active && state.rename.target == .Component, "renaming")
	testing.expect_value(t, ComponentNameProblem(&state.project, asset, "bad name"), "Letters, digits and _ only")
	send(&state, Rename_Text_Changed("Scenery"))
	send(&state, Rename_Committed{})
	testing.expect_value(t, state.project.assets[asset].path, "components/Scenery.component.xml")
	testing.expect(t, os.exists(joinPath(dir, "components/Scenery.component.xml", allocator = context.temp_allocator)), "moved")
	testing.expect(t, !os.exists(joinPath(dir, "components/props.component.xml", allocator = context.temp_allocator)), "not left behind")
	scene = playScene(&state)
	for node in scene.nodes do if node.kind == .Component do testing.expect_value(t, node.component, "components/Scenery.component.xml")
	component := Project_FindComponent(&state.project, "components/Scenery.component.xml")
	testing.expect_value(t, state.project.scenes[component].name, "Scenery")

	// Make Unique: the second instance gets its own copy
	state.selectedNode = second
	send(&state, Component_Made_Unique{})
	scene = playScene(&state)
	testing.expect_value(t, scene.nodes[second].component, "components/scenery_2.component.xml")
	copy := Project_FindComponent(&state.project, "components/scenery_2.component.xml")
	testing.expect(t, copy >= 0, "a new component")
	testing.expect_value(t, len(state.project.scenes[copy].nodes), len(state.project.scenes[component].nodes))
	testing.expect_value(t, Component_InstanceCount(&state.project, "components/Scenery.component.xml"), 1)
	// Undo points the instance back (the copy stays, like any asset)
	send(&state, Action.Undo)
	testing.expect_value(t, playScene(&state).nodes[second].component, "components/Scenery.component.xml")
	free_all(context.temp_allocator)
}

@(test)
sound_nodes_and_buses_round_trip :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_sound")
	defer removeAll(dir)
	project := Project_CreateDemo(dir)
	defer Project_Destroy(&project)
	testing.expect_value(t, len(project.buses), 1)
	testing.expect_value(t, project.buses[0].name, e.MASTER_BUS)
	project.buses[0].volume = 0.8
	append(&project.buses, BusDef{name = strings.clone("SFX"), volume = 0.5, pan = -0.25, mute = true}, BusDef{name = strings.clone("Music"), volume = 1})
	append(&project.assets, AssetDef{path = strings.clone("assets/theme.ogg"), kind = .Music})

	scene := &project.scenes[1]
	sound := NodeDef_Make("Laser", .AudioPlayer, -1)
	delete(sound.sound)
	sound.sound = strings.clone("assets/laser.wav")
	delete(sound.bus)
	sound.bus = strings.clone("SFX")
	sound.audio.volume, sound.audio.pitch, sound.audio.pan = 0.7, 1.5, -0.5
	sound.audio.loop, sound.audio.autostart = true, true
	append(&scene.nodes, sound)
	spatial := NodeDef_Make("Engine", .AudioPlayer2D, -1)
	spatial.audio.maxDistance, spatial.audio.attenuation = 400, 2
	append(&scene.nodes, spatial)
	music := NodeDef_Make("Theme", .MusicPlayer, -1)
	delete(music.sound)
	music.sound = strings.clone("assets/theme.ogg")
	delete(music.bus)
	music.bus = strings.clone("Music")
	music.audio.fadeIn, music.audio.fadeOut = 1.5, 2
	append(&scene.nodes, music)

	testing.expect_value(t, Project_Save(&project), "")
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, busesEqual(project.buses[:], loaded.buses[:]), "buses survive saving")
	found := 0
	for asset in loaded.assets do if asset.path == "assets/theme.ogg" && asset.kind == .Music do found += 1
	testing.expect_value(t, found, 1)
	for &node in scene.nodes {
		if !isSoundKind(node.kind) do continue
		other := &loaded.scenes[1].nodes[nodeIndex(&loaded.scenes[1], node.name)]
		testing.expect(t, NodeDef_Equal(node, other^), node.name)
		testing.expect_value(t, other.audio, node.audio)
	}
	testing.expect_value(t, Bus_NodeCount(&loaded, "SFX"), 1)
	testing.expect_value(t, Bus_NodeCount(&loaded, e.MASTER_BUS), 1)

	// Scripts get a constant per music asset
	source := Scripts_AssetsSource(&project)
	testing.expect(t, strings.contains(source, "MUSIC_THEME"), "music constant")
	free_all(context.temp_allocator)
}

@(test)
mixer_edits :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := playScene(&state)
	send(&state, Add_Node_Kind_Chosen(.AudioPlayer))
	index := nodeIndex(scene, "AudioPlayer")
	testing.expect(t, index >= 0, "added")
	state.selectedNode = index
	testing.expect_value(t, scene.nodes[index].audio, e.DEFAULT_AUDIO_SETTINGS)

	// Buses: unique names, Master stays first and can't be removed or renamed
	send(&state, Bus_Added{})
	send(&state, Bus_Added{})
	buses := &state.project.buses
	testing.expect_value(t, len(buses), 3)
	testing.expect_value(t, buses[1].name, "Bus")
	testing.expect_value(t, buses[2].name, "Bus 2")
	send(&state, Bus_Removed(0))
	send(&state, Bus_Renamed{0, "Main"})
	testing.expect_value(t, buses[0].name, e.MASTER_BUS)

	// The node goes to a bus, which it follows through a rename; a taken name waits
	send(&state, Node_Text_Changed{.Bus, "Bus"})
	testing.expect_value(t, scene.nodes[index].bus, "Bus")
	send(&state, Bus_Renamed{1, "bus 2"})
	testing.expect_value(t, buses[1].name, "Bus")
	send(&state, Bus_Renamed{1, "SFX"})
	testing.expect_value(t, buses[1].name, "SFX")
	testing.expect_value(t, scene.nodes[index].bus, "SFX")

	send(&state, Bus_Volume_Changed{1, 5})
	send(&state, Bus_Pan_Changed{1, -0.5})
	send(&state, Bus_Mute_Toggled(1))
	testing.expect_value(t, buses[1].volume, 2)
	testing.expect_value(t, buses[1].pan, -0.5)
	testing.expect(t, buses[1].mute, "muted")

	// Removing a bus sends its nodes to Master
	send(&state, Bus_Removed(1))
	testing.expect_value(t, len(buses), 2)
	testing.expect_value(t, scene.nodes[index].bus, "")
	send(&state, Action.Undo)
	testing.expect_value(t, len(state.project.buses), 3)
	testing.expect_value(t, state.project.buses[1].name, "SFX")
	testing.expect_value(t, playScene(&state).nodes[index].bus, "SFX")

	// The node's settings, clamped
	state.selectedNode = index
	send(&state, Audio_Field_Changed{.Volume, 3})
	send(&state, Audio_Field_Changed{.Pitch, 0})
	send(&state, Audio_Flag_Changed{.Loop, true})
	node := &playScene(&state).nodes[index]
	testing.expect_value(t, node.audio.volume, 2)
	testing.expect_value(t, node.audio.pitch, 0.1)
	testing.expect(t, node.audio.loop, "loops")
	send(&state, Node_Text_Changed{.Bus, e.MASTER_BUS})
	testing.expect_value(t, playScene(&state).nodes[index].bus, "")
}

@(test)
fader_scale_in_decibels :: proc(t: ^testing.T) {
	// The ends: silence and +6 dB (a gain of 2); unity snaps
	testing.expect_value(t, Fader_GainToPosition(0), 0)
	testing.expect_value(t, Fader_GainToPosition(2), 1)
	testing.expect_value(t, Fader_PositionToGain(0), 0)
	testing.expect(t, abs(Fader_PositionToGain(1) - 2) < 0.01, "top is +6 dB")
	unity := Fader_GainToPosition(1)
	testing.expect_value(t, Fader_PositionToGain(unity), 1)
	testing.expect_value(t, Fader_PositionToGain(unity + 0.002), 1)
	// Round trips within a tenth of a dB
	for gain in ([]f32{0.01, 0.1, 0.5, 0.708, 1.5}) {
		back := Fader_PositionToGain(Fader_GainToPosition(gain))
		testing.expect(t, abs(20 * math.log10(back / gain)) <= 0.06, fmt.tprint(gain))
	}
	testing.expect_value(t, Fader_Text(0), "-inf")
	testing.expect_value(t, Fader_Text(1), "0.0 dB")
	testing.expect_value(t, Fader_Text(0.5), "-6.0 dB")
	testing.expect_value(t, Pan_Text(0), "C")
	testing.expect_value(t, Pan_Text(-0.4), "L40")
	testing.expect_value(t, Pan_Text(0.25), "R25")
}

@(test)
renderer_setting_round_trip_and_undo :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	testing.expect_value(t, state.project.renderer, e.RenderBackend.Auto)
	send(&state, Action.Open_Project_Settings)
	send(&state, Project_Settings_Renderer_Changed(.Vulkan))
	testing.expect_value(t, state.project.renderer, e.RenderBackend.Auto) // A draft until Apply
	send(&state, Project_Settings_Applied{})
	testing.expect_value(t, state.project.renderer, e.RenderBackend.Vulkan)
	send(&state, Action.Undo)
	testing.expect_value(t, state.project.renderer, e.RenderBackend.Auto)
	send(&state, Action.Redo)
	testing.expect_value(t, state.project.renderer, e.RenderBackend.Vulkan)

	// Written only when it isn't Auto, and read back
	text := ProjectToXML(&state.project, context.temp_allocator)
	testing.expect(t, strings.contains(text, `renderer="Vulkan"`), "written")
	data, err := e.ParseProject(text, context.temp_allocator)
	testing.expect_value(t, err, e.ProjectError.None)
	testing.expect_value(t, data.renderer, e.RenderBackend.Vulkan)
	state.project.renderer = .Auto
	testing.expect(t, !strings.contains(ProjectToXML(&state.project, context.temp_allocator), "renderer="), "Auto isn't written")
	free_all(context.temp_allocator)
}


@(test)
code_tabs_open_switch_close :: proc(t: ^testing.T) {
	// The code editors are package state, and SDL_ttf (their font) isn't thread-safe: the tests
	// using them or the viewport preview take turns
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	dir := tempDir("editor_test_code_tabs")
	defer removeAll(dir)
	state := testState()
	defer State_Destroy(&state)
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone(dir)
	_ = os.make_directory(joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator))
	a := joinPath(dir, "scripts/a.odin", allocator = context.temp_allocator)
	b := joinPath(dir, "scripts/b.odin", allocator = context.temp_allocator)
	_ = os.write_entire_file(a, transmute([]byte)string("package scripts\n\n// a\nx := 1\n"))
	_ = os.write_entire_file(b, transmute([]byte)string("package scripts\n// b\n"))
	// No language server here: tests mustn't start one
	state.settings.olsPath = FixedText_Make("/nonexistent/ols")
	state.settings.builtInCodeEditor = true

	// Opening shows the file at a line; opening it again shows the same tab
	testing.expect_value(t, CodeTabs_Active(&state), "")
	_ = Script_Open(&state, a, 4)
	testing.expect_value(t, len(state.codeTabs), 1)
	testing.expect_value(t, filepath.base(CodeTabs_Active(&state)), "a.odin")
	line, _ := CodeEditor_Caret(CodeTabs_Active(&state))
	testing.expect_value(t, line, 4)
	testing.expect(t, state.codeFocusPending, "an opened tab takes the keyboard")
	_ = Script_Open(&state, "scripts/b.odin", 0)
	_ = Script_Open(&state, a, 0)
	testing.expect_value(t, len(state.codeTabs), 2)
	testing.expect_value(t, state.codeTab, 1)

	// A scene tab (or another scene) shows the scene
	send(&state, Scene_Tab_Changed(0))
	testing.expect_value(t, CodeTabs_Active(&state), "")
	send(&state, Code_Tab_Selected(1))
	testing.expect_value(t, filepath.base(CodeTabs_Active(&state)), "b.odin")

	// Unsaved changes count for the project, and Save writes them
	c := CodeEditor_Find(state.codeTabs[1])
	testing.expect(t, c != nil, "open")
	c.ed.buf.dirty = true
	testing.expect(t, Project_IsModified(&state), "an unsaved script is an unsaved change")
	testing.expect(t, CodeTabs_SaveAll(&state), "saved")
	testing.expect(t, !CodeEditor_AnyDirty(), "nothing unsaved")

	// Closing an unsaved tab asks; Cancel keeps it, Don't Save closes it and shows a neighbour
	c.ed.buf.dirty = true
	send(&state, Code_Tab_Close_Requested(1))
	testing.expect(t, state.codeClose.open, "asks")
	send(&state, Code_Close_Chosen(.Cancel))
	testing.expect_value(t, len(state.codeTabs), 2)
	send(&state, Code_Tab_Close_Requested(1))
	send(&state, Code_Close_Chosen(.Discard))
	testing.expect_value(t, len(state.codeTabs), 1)
	testing.expect_value(t, filepath.base(CodeTabs_Active(&state)), "a.odin")
	testing.expect(t, CodeEditor_Find(b) == nil, "its editor is gone")
	// Ctrl+W closes the one that shows; with none left the scene shows
	send(&state, Action.Close_Code_Tab)
	send(&state, Code_Tab_Close_Requested(0))
	testing.expect_value(t, len(state.codeTabs), 0)
	testing.expect_value(t, state.codeTab, 0)

	// Off in Settings: the external program instead (TEST_NOOP_PROGRAM)
	state.settings.builtInCodeEditor = false
	state.settings.codeEditorPath = FixedText_Make(TEST_NOOP_PROGRAM)
	_ = Script_Open(&state, a, 1)
	testing.expect_value(t, len(state.codeTabs), 0)
	free_all(context.temp_allocator)
}


@(test)
code_editor_settings_persist_and_disk_changes :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	dir := tempDir("editor_test_code_config")
	defer removeAll(dir)
	file := joinPath(dir, "a.odin", allocator = context.temp_allocator)
	config := joinPath(dir, "code_editor", allocator = context.temp_allocator)
	_ = os.write_entire_file(file, transmute([]byte)string("package a\n// one\n"))

	// The theme chosen in the code editor is there next time
	c, problem := CodeEditor_Open(file, "", "", config)
	testing.expect_value(t, problem, "")
	ce.editor_apply_preset(&c.ed, .Dark_Plus)
	CodeEditor_Close(file)
	c, _ = CodeEditor_Open(file, "", "", config)
	testing.expect(t, c.ed.theme == ce.preset_theme(.Dark_Plus), "theme kept")
	testing.expect(t, os.exists(joinPath(config, "theme.json", allocator = context.temp_allocator)), "theme.json")
	CodeEditor_Close(file)
	// A light editor starts the code light, until a theme is chosen
	removeAll(config)
	c, _ = CodeEditor_Open(file, "", "", config, lightTheme = true)
	testing.expect(t, c.ed.theme == ce.ayu_light_theme(), "light")

	// Changed on disk: no unsaved changes reloads; unsaved changes ask
	later := time.time_add(time.now(), 2 * time.Second)
	_ = os.write_entire_file(file, transmute([]byte)string("package a\n// two\n"))
	_ = os.change_times(file, later, later)
	testing.expect_value(t, CodeEditor_DiskChange(file, now = true), CodeDiskChange.Reloaded)
	testing.expect(t, strings.contains(CodeEditor_Text(file), "// two"), "reloaded")
	testing.expect_value(t, CodeEditor_DiskChange(file, now = true), CodeDiskChange.None)
	c.ed.buf.dirty = true
	later = time.time_add(later, time.Second)
	_ = os.write_entire_file(file, transmute([]byte)string("package a\n// three\n"))
	_ = os.change_times(file, later, later)
	testing.expect_value(t, CodeEditor_DiskChange(file, now = true), CodeDiskChange.Conflict)
	testing.expect(t, CodeEditor_HasDiskConflict(file), "asks")
	CodeEditor_ResolveDiskChange(file, reloadIt = false)
	testing.expect(t, !strings.contains(CodeEditor_Text(file), "// three"), "kept mine")
	testing.expect_value(t, CodeEditor_DiskChange(file, now = true), CodeDiskChange.None)
	// Saving isn't a change on disk
	testing.expect_value(t, CodeEditor_Save(file), "")
	testing.expect_value(t, CodeEditor_DiskChange(file, now = true), CodeDiskChange.None)
	CodeEditor_Close(file)
	free_all(context.temp_allocator)
}


@(test)
scene_tabs_close_and_come_back :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	names :: proc(s: ^State) -> string {
		list := make([dynamic]string, context.temp_allocator)
		for i in ViewportTabScenes(s) do append(&list, s.project.scenes[i].name)
		return strings.join(list[:], ",", context.temp_allocator)
	}
	all := names(&state)
	count := len(ViewportTabScenes(&state))
	testing.expect(t, count >= 3, "the demo's scenes")
	current := state.currentScene

	// Another tab closes; the scene stays in the project
	other := ViewportTabScenes(&state)[0] == current ? 1 : 0
	send(&state, Scene_Tab_Closed(other))
	testing.expect_value(t, len(ViewportTabScenes(&state)), count - 1)
	testing.expect_value(t, state.currentScene, current)
	// The tab that shows closes: a neighbour shows
	for index, i in ViewportTabScenes(&state) do if index == current {
		send(&state, Scene_Tab_Closed(i))
		break
	}
	testing.expect(t, state.currentScene != current, "another scene shows")
	testing.expect_value(t, len(ViewportTabScenes(&state)), count - 2)
	// Opening a scene brings its tab back
	send(&state, Scene_Action{.Open, current})
	testing.expect_value(t, state.currentScene, current)
	testing.expect_value(t, len(ViewportTabScenes(&state)), count - 1)
	// The last tab stays
	for len(ViewportTabScenes(&state)) > 1 do send(&state, Scene_Tab_Closed(0))
	send(&state, Scene_Tab_Closed(0))
	testing.expect_value(t, len(ViewportTabScenes(&state)), 1)
	_ = all
	free_all(context.temp_allocator)
}


@(test)
scene_tree_marks_nodes_with_scripts :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	theme := skald.theme_dark()
	scene := playScene(&state)
	ship := nodeIndex(scene, "Spaceship")
	testing.expect_value(t, SceneTree_Row(&theme, scene, ship, false).badge, "")
	delete(scene.nodes[ship].script)
	scene.nodes[ship].script = strings.clone("Mover")
	row := SceneTree_Row(&theme, scene, ship, false)
	testing.expect_value(t, row.badge, ICON_FILE_CODE)
	testing.expect_value(t, row.badgeColor, SCRIPT_COLOR)
	free_all(context.temp_allocator)
}


@(test)
export_plan_uses_a_prebuilt_player :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		input := exportTestInput(.Linux_x64)
		input.prebuiltPlayer = "/editor/prebuilt/linux_x64/player"
		input.odin = "/opt/odin/odin"
		// No scripts: the prebuilt player is copied, nothing is compiled
		plan, problem := Export_Plan(input, context.temp_allocator)
		testing.expect_value(t, problem, "")
		copied := false
		for step in plan.steps {
			testing.expect(t, step.kind != .Command, "no compiler")
			if step.kind == .Copy_File {
				copied = true
				testing.expect_value(t, step.source, "/editor/prebuilt/linux_x64/player")
				testing.expect_value(t, step.path, "/games/Space/export/linux_x64/Space_Game")
			}
		}
		testing.expect(t, copied, "the prebuilt player")
		// With scripts it's compiled, with the toolchain's odin
		input.hasScripts = true
		plan, problem = Export_Plan(input, context.temp_allocator)
		testing.expect_value(t, problem, "")
		built := false
		for step in plan.steps do if step.kind == .Command && step.command[1] == "build" {
			built = true
			testing.expect_value(t, step.command[0], "/opt/odin/odin")
		}
		testing.expect(t, built, "compiled")
		testing.expect_value(t, Toolchain_TargetFolder(.Linux_x64), "linux_x64")
		testing.expect_value(t, Toolchain_TargetFolder(.macOS_ARM64), "macos_arm64")
	}
	free_all(context.temp_allocator)
}

@(test)
new_components_start_with_a_chosen_root :: proc(t: ^testing.T) {
	dir := tempDir("editor_test_new_component")
	defer removeAll(dir)
	state := testState()
	defer State_Destroy(&state)
	Project_Destroy(&state.project)
	state.project = Project_CreateDemo(dir)
	testing.expect_value(t, Project_Save(&state.project), "")
	before := len(state.project.scenes)
	send(&state, Component_New{})
	testing.expect(t, state.addNode.open && state.addNode.forComponent, "the Add Node dialog picks the root")
	send(&state, Add_Node_Kind_Chosen(NodeKind.Area))
	testing.expect(t, !state.addNode.open && len(state.project.scenes) == before + 1, "made one")
	scene := &state.project.scenes[state.currentScene]
	testing.expect(t, Scene_IsComponent(scene) && scene.component == "components/area.component.xml", "it's open")
	testing.expect(t, len(scene.nodes) == 1 && scene.nodes[0].kind == .Area && scene.nodes[0].name == "Area", "an Area root named after it")
	testing.expect_value(t, state.selectedNode, 0)
	// Add Node afterwards adds to the scene again
	send(&state, Action.Add_Node)
	testing.expect(t, !state.addNode.forComponent, "a plain Add Node")
	free_all(context.temp_allocator)
}

// Every inspector, Settings and Project Settings row with a fixed label explains itself
// (tooltips.odin): a new row needs an entry in fieldTip
@(test)
every_row_label_has_a_tooltip :: proc(t: ^testing.T) {
	files, err := os.read_all_directory_by_path(".", context.temp_allocator)
	testing.expect(t, err == nil, "read the sources")
	for file in files {
		if !strings.has_suffix(file.name, ".odin") || strings.has_suffix(file.name, "_test.odin") do continue
		data, readErr := os.read_entire_file(file.fullpath, context.temp_allocator)
		if readErr != nil do continue
		text := string(data)
		for marker in ([]string{"inspectorRow(ctx, \"", "settingRow(ctx, \""}) {
			rest := text
			for {
				at := strings.index(rest, marker)
				if at < 0 do break
				rest = rest[at + len(marker):]
				end := strings.index_byte(rest, '"')
				label := rest[:end]
				if label != "" do testing.expectf(t, fieldTip(label) != "", "%s: the row \"%s\" has no tooltip (fieldTip)", file.name, label)
			}
		}
	}
	free_all(context.temp_allocator)
}

// Windows and macOS exports: compiled on their own machine, or (no scripts) made anywhere from the
// target's prebuilt player; the steps each needs
@(test)
export_plans_for_windows_and_macos :: proc(t: ^testing.T) {
	// Plans join paths the OS's way: compared with "/" and without the leading one
	same :: proc(t: ^testing.T, got, want: string, loc := #caller_location) {
		norm :: proc(p: string) -> string {
			s, _ := strings.replace_all(p, "\\", "/", context.temp_allocator)
			return strings.trim_left(s, "/")
		}
		testing.expectf(t, norm(got) == norm(want), "got %s, want %s", got, want, loc = loc)
	}
	kinds :: proc(plan: ExportPlan) -> bit_set[ExportStepKind] {
		set: bit_set[ExportStepKind]
		for step in plan.steps do set += {step.kind}
		return set
	}
	stepOf :: proc(plan: ExportPlan, kind: ExportStepKind) -> (ExportStep, bool) {
		for step in plan.steps do if step.kind == kind do return step, true
		return {}, false
	}
	// From Linux, without scripts, with Windows' prebuilt player: copied, console hidden, packed
	win := exportTestInput(.Windows_x64)
	win.host = .Linux_x64
	win.prebuiltPlayer = "/editor/prebuilt/windows_x64/player.exe"
	win.settings.hideConsole = true
	win.settings.archive = true
	plan, problem := Export_Plan(win, context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect(t, kinds(plan) >= {.Copy_File, .Patch_Subsystem, .Append_Pack, .Zip_Folder} && .Command not_in kinds(plan), "prebuilt, patched, packed, zipped")
	copy, _ := stepOf(plan, .Copy_File)
	same(t, copy.path, "/games/Space/export/windows_x64/Space_Game.exe")
	same(t, plan.archive, "/games/Space/export/windows_x64.zip")
	// With scripts: only on Windows
	win.hasScripts = true
	_, problem = Export_Plan(win, context.temp_allocator)
	testing.expect(t, problem != "", "scripts need Windows")
	// On Windows: compiled, a GUI program, Odin's DLLs beside it without the static SDL
	win.host = .Windows_x64
	win.sdlDLLs = {"C:/odin/vendor/sdl3/SDL3.dll"}
	plan, problem = Export_Plan(win, context.temp_allocator)
	testing.expect_value(t, problem, "")
	build, _ := stepOf(plan, .Command)
	testing.expect(t, slice.contains(build.command, "-subsystem:windows"), "no console")
	dlls, hasDLLs := stepOf(plan, .Copy_Libraries)
	testing.expect(t, hasDLLs && len(dlls.files) == 1, "the DLLs")
	win.staticSDL = true
	plan, _ = Export_Plan(win, context.temp_allocator)
	testing.expect(t, .Copy_Libraries not_in kinds(plan), "the static SDL needs no DLLs")

	// macOS from Linux, prebuilt: an app with its files in Resources/data, no pack, unsigned here
	mac := exportTestInput(.macOS_ARM64)
	mac.host = .Linux_x64
	mac.prebuiltPlayer = "/editor/prebuilt/macos_arm64/player"
	mac.settings.archive = true
	plan, problem = Export_Plan(mac, context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect(t, .Append_Pack not_in kinds(plan) && .Command in kinds(plan), "no pack; the archive's tar")
	copy, _ = stepOf(plan, .Copy_File)
	same(t, copy.path, "/games/Space/export/macos_arm64/Space_Game.app/Contents/MacOS/Space_Game")
	plist, _ := stepOf(plan, .Write_File)
	testing.expect(t, strings.contains(plist.content, "<string>Space_Game</string>") && strings.contains(plist.content, "io.crossfire.space_game"), plist.content)
	data, _ := stepOf(plan, .Copy_Files)
	same(t, data.path, "/games/Space/export/macos_arm64/Space_Game.app/Contents/Resources/data")
	for step in plan.steps do if step.kind == .Command do testing.expect(t, step.command[0] != "codesign", "no codesign off a Mac")
	// On a Mac: compiled (static SDL needed) and signed
	mac.host = .macOS_ARM64
	mac.hasScripts = true
	_, problem = Export_Plan(mac, context.temp_allocator)
	testing.expect(t, problem != "", "without the static SDL: refused")
	mac.staticSDL = true
	plan, problem = Export_Plan(mac, context.temp_allocator)
	testing.expect_value(t, problem, "")
	signed := false
	for step in plan.steps do if step.kind == .Command && step.command[0] == "codesign" do signed = true
	testing.expect(t, signed, "signed ad hoc")
	free_all(context.temp_allocator)
}

@(test)
export_patches_the_windows_subsystem :: proc(t: ^testing.T) {
	os.make_directory("build")
	path := "build/test_subsystem.exe"
	defer os.remove(path)
	// A minimal PE: MZ, e_lfanew at 0x3C pointing at 0x40, "PE\0\0", a file header, an optional
	// header whose Subsystem (byte 68) says console (3)
	data := make([]byte, 0x40 + 4 + 20 + 96, context.temp_allocator)
	data[0], data[1] = 'M', 'Z'
	data[0x3C] = 0x40
	copy(data[0x40:], "PE\x00\x00")
	field := 0x40 + 4 + 20 + 68
	data[field] = 3
	_ = os.write_entire_file(path, data)
	testing.expect_value(t, Export_SetWindowsSubsystem(path, gui = true), "")
	patched, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, patched[field], 2)
	testing.expect(t, Export_SetWindowsSubsystem("build/nope.exe", true) != "", "no file")
	_ = os.write_entire_file(path, transmute([]byte)string("not a program"))
	testing.expect(t, Export_SetWindowsSubsystem(path, true) != "", "not a PE")
	free_all(context.temp_allocator)
}

// A web export waiting for Emscripten: a failed install drops it (and says why)
@(test)
emscripten_install_finishing :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	state.emscriptenInstalling = true
	state.exportAfterEmscripten = {.Web}
	{
		// The failure is logged as an error (which fails a test otherwise)
		context.logger = log.nil_logger()
		send(&state, Toolchain_Emscripten_Finished{problem = strings.clone("no network")})
	}
	testing.expect(t, !state.emscriptenInstalling && state.exportAfterEmscripten == {}, "done, nothing waiting")
	found := false
	for line in LogList_Lines(&state.console) do if strings.contains(line.text, "Installing Emscripten failed: no network") do found = true
	testing.expect(t, found, "the reason is in the Console")
	free_all(context.temp_allocator)
}

// Node fields (node_fields.odin), the script and scene previews' facts, and scene settings

@(private="file")
indexOf :: proc(scene: ^SceneDef, name: string) -> int {
	for node, i in scene.nodes do if node.name == name do return i
	return -1
}

@(test)
node_paths_and_the_nodes_a_field_takes :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	scene := &state.project.scenes[1] // PlayScene: World/{Camera, Spaceship/ShipLight, Props/...}, HUD/BackMenu
	ship, light, camera, hud := nodeIndex(scene, "Spaceship"), nodeIndex(scene, "ShipLight"), nodeIndex(scene, "Camera"), nodeIndex(scene, "HUD")
	path :: proc(scene: ^SceneDef, from, to: int) -> string { return Scene_NodePath(scene, from, to, context.temp_allocator) }
	testing.expect_value(t, path(scene, ship, light), "ShipLight")
	testing.expect_value(t, path(scene, light, ship), "..")
	testing.expect_value(t, path(scene, ship, camera), "../Camera")
	testing.expect_value(t, path(scene, hud, ship), "../World/Spaceship")
	testing.expect_value(t, path(scene, light, hud), "../../../HUD")
	testing.expect_value(t, path(scene, ship, ship), ".")
	testing.expect_value(t, path(scene, -1, light), "/World/Spaceship/ShipLight")

	// The nodes that fit a field's type, as paths from the script's node (itself first)
	cameras := NodeField_Choices(&state.project, scene, ship, "Camera2D")
	testing.expect(t, len(cameras) == 1 && cameras[0] == "../Camera", "the camera")
	sprites := NodeField_Choices(&state.project, scene, ship, "Sprite")
	testing.expect(t, len(sprites) >= 1 && sprites[0] == ".", "itself first")
	testing.expect_value(t, len(NodeField_Choices(&state.project, scene, ship, "Node")), len(scene.nodes))
	testing.expect_value(t, len(NodeField_Choices(&state.project, scene, ship, "Area")), 0)
	free_all(context.temp_allocator)
}

@(test)
dropping_a_node_writes_a_field_line :: proc(t: ^testing.T) {
	text := `package scripts

import e "engine:."

Helper :: struct { x: int }

Hero :: struct {
	using script: e.Script,
	speed: f32 ` + "`export:\"default=1\"`" + `,
	camera: ^e.Camera2D,
}
`
	st, ok := NodeField_FindStruct(text)
	testing.expect(t, ok, "found")
	testing.expect_value(t, st.name, "Hero")
	testing.expect_value(t, st.closeLine, 10)
	testing.expect_value(t, st.engineAlias, "e")
	_, none := NodeField_FindStruct("package scripts\n\nPoint :: struct {\n\tx: f32,\n}\n")
	testing.expect(t, !none, "no script struct")

	testing.expect_value(t, NodeField_Name("Camera", st.fields), "camera2")
	testing.expect_value(t, NodeField_Name("Ship Light 2", st.fields), "shipLight2")
	testing.expect_value(t, NodeField_Name("3D", st.fields), "n3D")

	state := testState()
	defer State_Destroy(&state)
	scene := &state.project.scenes[1]
	line, name := NodeField_Line(st, &state.project, scene, nodeIndex(scene, "Camera"), nodeIndex(scene, "Spaceship"))
	testing.expect_value(t, name, "camera2")
	testing.expect_value(t, line, "\tcamera2: ^e.Camera2D `export:\"default=../Camera\"`,\n")
	line, _ = NodeField_Line(st, &state.project, scene, nodeIndex(scene, "ShipLight"), -1)
	testing.expect_value(t, line, "\tshipLight: ^e.AnimatedSprite `export:\"default=/World/Spaceship/ShipLight\"`,\n")

	// A field added after one without a comma (Odin allows it on the last field) gives it one,
	// before a trailing comment; one with a comma, or the struct's first line, needs none
	missing := "A :: struct {\n\tusing script: e.Script,\n\tspeed: f32 `export:\"default=1\"` // fast\n\n}\n"
	commaLine, commaColumn, needed := Struct_MissingComma(missing, 4)
	testing.expect(t, needed && commaLine == 2 && commaColumn == len("\tspeed: f32 `export:\"default=1\"`"), "after the tag, before the comment")
	_, _, needed = Struct_MissingComma("A :: struct {\n\tx: int,\n}\n", 2)
	testing.expect(t, !needed, "already has one")
	_, _, needed = Struct_MissingComma("A :: struct {\n}\n", 1)
	testing.expect(t, !needed, "an empty struct")

	// What a file registers, for the script preview
	info := ScriptFile_Registrations("e.Script_Register(Hero, {})\ne.Data_Register(Stats)\ne.Script_Register(Hero, {})\ne.Script_Register(Coin, {})")
	testing.expect(t, len(info.scripts) == 2 && info.scripts[0] == "Hero" && info.scripts[1] == "Coin", "scripts, once each")
	testing.expect(t, len(info.dataTypes) == 1 && info.dataTypes[0] == "Stats", "data types")
	free_all(context.temp_allocator)
}

@(test)
scene_settings_save_load_and_undo :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)

	// Each edit is an undo step
	send(&state, Scene_Screen_Layer_Toggled{1, .Layer8})
	testing.expect_value(t, state.project.scenes[1].settings.screenLayers, bit_set[e.RenderLayer]{.Layer8})
	send(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[1].settings.screenLayers, bit_set[e.RenderLayer]{})
	send(&state, Action.Redo)
	// Turned on, they start from the project's
	send(&state, Scene_Background_Changed{1, true, {}, true})
	testing.expect_value(t, state.project.scenes[1].settings.background, state.project.background)
	send(&state, Scene_Background_Changed{1, true, {1, 2, 3, 255}, false})
	send(&state, Scene_Gravity_Toggled{1, true})
	testing.expect_value(t, state.project.scenes[1].settings.gravity, state.project.physics.gravity)
	send(&state, Scene_Gravity_Changed{1, 1, 490})
	// Components have none
	send(&state, Scene_Screen_Layer_Toggled{len(state.project.scenes) + 3, .Layer1})

	// Written on the scene's root, read back
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, "editor_test_scene_settings"}, context.temp_allocator)
	_ = removeAll(dir)
	defer removeAll(dir)
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone(dir)
	testing.expect_value(t, Project_Save(&state.project), "")
	xml := SceneToXML(&state.project.scenes[1], context.temp_allocator)
	testing.expect(t, strings.contains(xml, `screenLayers="8" background="#010203" gravityX="0" gravityY="490"`), xml)
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, loaded.scenes[1].settings, e.SceneSettings{
		screenLayers = {.Layer8}, hasBackground = true, background = {1, 2, 3, 255}, hasGravity = true, gravity = {0, 490},
	})
	testing.expect_value(t, loaded.scenes[0].settings, e.SceneSettings{})
	free_all(context.temp_allocator)
}

@(test)
listeners_from_the_inspector :: proc(t: ^testing.T) {
	testing.expect_value(t, Listener_HandlerName("Blood", "onFinished", nil), "onBloodFinished")
	testing.expect_value(t, Listener_HandlerName("Blood", "onFinished", {"onBloodFinished"}), "onBloodFinished2")
	testing.expect_value(t, Listener_HandlerName("hero sprite", "animation.onAnimationEnded", nil), "onHeroSpriteAnimationEnded")
	handlers := Listener_RegisteredHandlers("e.Script_Listener(Hero, \"onA\", Hero_onA)\nx\ne.Script_Listener(Hero, \"onB\", Hero_onB)")
	testing.expect(t, len(handlers) == 2 && handlers[0] == "onA" && handlers[1] == "onB", "registered handlers")

	// Attaching: the listener on the node, the handler appended to the script's file (the
	// external editor here: written to the file)
	state := testState()
	defer State_Destroy(&state)
	dir := tempDir("editor_test_listeners")
	defer removeAll(dir)
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone(dir)
	_ = os.make_directory_all(filepath.join({dir, "scripts"}, context.temp_allocator) or_else "")
	hero := "package scripts\n\nimport e \"engine:.\"\n\nHero :: struct {\n\tusing script: e.Script,\n}\n\n@(init)\nregister_Hero :: proc \"contextless\" () {\n\te.Script_Register(Hero, {})\n}\n"
	_ = os.write_entire_file(filepath.join({dir, "scripts", "hero.odin"}, context.temp_allocator) or_else "", transmute([]u8)hero)
	append(&state.scriptFiles, strings.clone("scripts/hero.odin"))
	state.settings.codeEditorPath = FixedText_Make(TEST_NOOP_PROGRAM)
	scene := playScene(&state)
	ship, menu := nodeIndex(scene, "Spaceship"), nodeIndex(scene, "BackMenu")
	delete(scene.nodes[ship].script)
	scene.nodes[ship].script = strings.clone("Hero")
	testing.expect_value(t, len(Listener_Targets(scene)), 1)
	send(&state, Listener_Dialog_Opened{menu, "onButtonPressed"})
	send(&state, Listener_Target_Chosen(ship))
	testing.expect(t, !state.listenerDialog.open, "closed")
	listeners := scene.nodes[menu].listeners[:]
	testing.expect_value(t, len(listeners), 1)
	if len(listeners) == 1 do testing.expect_value(t, listeners[0], e.NodeListenerData{"onButtonPressed", "../../World/Spaceship", "onBackMenuButtonPressed", ""})
	data, _ := os.read_entire_file(filepath.join({dir, "scripts", "hero.odin"}, context.temp_allocator) or_else "", context.temp_allocator)
	text := string(data)
	testing.expect(t, strings.contains(text, "Hero_onBackMenuButtonPressed :: proc(self: ^Hero, source: ^e.Node, data: e.EventData) {\n\t// index := data.(int)\n}"), text)
	testing.expect(t, strings.contains(text, "e.Script_Listener(Hero, \"onBackMenuButtonPressed\", Hero_onBackMenuButtonPressed)"), "registered")
	// One undo step: the listener goes (the code is the code editor's to undo)
	send(&state, Action.Undo)
	testing.expect_value(t, len(scene.nodes[menu].listeners), 0)
	send(&state, Action.Redo)
	testing.expect_value(t, len(scene.nodes[menu].listeners), 1)
	// Written to the scene file and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	reloaded := &loaded.scenes[1].nodes[menu]
	testing.expect(t, len(reloaded.listeners) == 1 && reloaded.listeners[0].handler == "onBackMenuButtonPressed", "round trip")
	// × removes it (an undo step too)
	send(&state, Listener_Removed{menu, 0})
	testing.expect_value(t, len(scene.nodes[menu].listeners), 0)
	free_all(context.temp_allocator)
}

@(test)
scripts_publish_events_in_the_editor :: proc(t: ^testing.T) {
	// The catalog lists a script's events
	scripts, dataTypes, _, ok := ScriptCatalog_ParseAll(`{"scripts": [{"name": "Hero", "file": "hero.odin", "line": 9, "fields": [], "events": [{"name": "script.onPinged", "description": "It was pinged", "data": "text := data.(string)"}]}, {"name": "GameState", "file": "game_state.odin", "line": 9, "fields": [], "events": [{"name": "script.onScored", "description": "The score changed", "data": "value := data.(int)"}]}], "data": []}`)
	testing.expect(t, ok && len(scripts) == 2 && len(scripts[0].events) == 1, "events parsed")
	testing.expect_value(t, scripts[0].events[0].name, "script.onPinged")
	testing.expect_value(t, scripts[0].events[0].dataHint, "text := data.(string)")

	// The field New Event writes, with how to fire it
	testing.expect_value(t, NewEvent_Source("onPinged", `It was "pinged"`, .String, "e", false),
		"\t// It was 'pinged'. Fire it: e.Event_Notify(&self.onPinged, self.node, \"text\")\n\tonPinged: e.EventSubject `event:\"It was 'pinged'\" data:\"text := data.(string)\"`,\n")
	testing.expect(t, strings.contains(NewEvent_Source("onScored", "Scored", .Int, "e", true), "e.Event_Notify(&self.onScored, nil, 42)"), "a global fires with no node")
	testing.expect(t, !strings.contains(NewEvent_Source("onTick", "Ticked", .None, "e", false), "data:"), "no data, no hint")

	state := testState()
	defer State_Destroy(&state)
	state.scripts = {status = .Ready, scripts = scripts, dataTypes = dataTypes}
	dir := tempDir("editor_test_script_events")
	defer removeAll(dir)
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone(dir)
	_ = os.make_directory_all(filepath.join({dir, "scripts"}, context.temp_allocator) or_else "")
	write :: proc(dir, name, text: string) { _ = os.write_entire_file(filepath.join({dir, "scripts", name}, context.temp_allocator) or_else "", transmute([]u8)text) }
	read :: proc(dir, name: string) -> string {
		data, _ := os.read_entire_file(filepath.join({dir, "scripts", name}, context.temp_allocator) or_else "", context.temp_allocator)
		return string(data)
	}
	// Two scripts in one file: the event goes into the one asked for
	write(dir, "hero.odin", "package scripts\n\nimport e \"engine:.\"\n\nOther :: struct {\n\tusing script: e.Script,\n}\n\nHero :: struct {\n\tusing script: e.Script,\n\tspeed: f32,\n}\n\n@(init)\nregister_Hero :: proc \"contextless\" () {\n\te.Script_Register(Hero, {})\n\te.Script_Register(Other, {})\n}\n")
	write(dir, "game_state.odin", "package scripts\n\nimport e \"engine:.\"\n\nGameState :: struct {\n\tusing script: e.Script,\n}\n\n@(init)\nregister_GameState :: proc \"contextless\" () {\n\te.Script_Register(GameState, {})\n}\n")
	append(&state.scriptFiles, strings.clone("scripts/hero.odin"), strings.clone("scripts/game_state.odin"))
	append(&state.project.globals, GlobalDef{script = strings.clone("GameState")})
	state.settings.codeEditorPath = FixedText_Make(TEST_NOOP_PROGRAM)

	send(&state, New_Event_Opened("Hero"))
	send(&state, New_Event_Name_Changed("onPinged"))
	testing.expect(t, NewEvent_Problem(&state) != "", "Hero already has onPinged (built)")
	send(&state, New_Event_Name_Changed("onJumped"))
	send(&state, New_Event_Description_Changed("It jumped"))
	send(&state, New_Event_Kind_Changed(.Float))
	testing.expect_value(t, NewEvent_Problem(&state), "")
	send(&state, New_Event_Created{})
	testing.expect(t, !state.newEvent.open, "closed")
	hero := read(dir, "hero.odin")
	testing.expect(t, strings.contains(hero, "\tspeed: f32,\n\t// It jumped. Fire it: e.Event_Notify(&self.onJumped, self.node, 1.5)\n\tonJumped: e.EventSubject `event:\"It jumped\" data:\"value := data.(f32)\"`,\n}"), hero)
	testing.expect(t, strings.index(hero, "onJumped") > strings.index(hero, "Hero :: struct"), "in Hero, not Other")

	// A node with Hero listens to the global's onScored: the listener on that node
	scene := playScene(&state)
	ship := nodeIndex(scene, "Spaceship")
	delete(scene.nodes[ship].script)
	scene.nodes[ship].script = strings.clone("Hero")
	send(&state, Global_Listen_Requested{ship, "GameState", "script.onScored"})
	listeners := scene.nodes[ship].listeners[:]
	if testing.expect_value(t, len(listeners), 1) {
		testing.expect_value(t, listeners[0], e.NodeListenerData{"script.onScored", ".", "onGameStateScored", "GameState"})
	}
	hero = read(dir, "hero.odin")
	testing.expect(t, strings.contains(hero, "Hero_onGameStateScored :: proc(self: ^Hero, source: ^e.Node, data: e.EventData) {\n\t// value := data.(int)\n\t// gameState := e.Global(GameState)\n}"), hero)
	// A node's script event: the listener's handler can reach the sender
	send(&state, Listener_Dialog_Opened{ship, "script.onPinged"})
	send(&state, Listener_Target_Chosen(ship))
	hero = read(dir, "hero.odin")
	testing.expect(t, strings.contains(hero, "\t// sender := e.Node_GetScript(source, Hero)\n"), hero)
	// Saved with the global named
	testing.expect_value(t, Project_Save(&state.project), "")
	xml := SceneToXML(scene, context.temp_allocator)
	testing.expect(t, strings.contains(xml, `<listener global="GameState" event="script.onScored" target="." handler="onGameStateScored"/>`), xml)
	free_all(context.temp_allocator)
}

@(test)
assets_dropped_on_code_become_fields :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	st := NodeField_Struct{name = "Hero", engineAlias = "e", fields = {"coin"}}
	testing.expect_value(t, AssetField_BaseName("components/coin.component.xml"), "coin")
	line, name, ok := AssetField_Line(st, &state.project, AssetDef{path = "components/coin.component.xml", kind = .Component})
	testing.expect(t, ok && name == "coin2", "a free name")
	testing.expect_value(t, line, "\t// e.Scene_AddComponent(self.scene, self.coin2, position = e.Node_GetWorldPosition(self.node))\n\tcoin2: e.ComponentAsset `export:\"default=components/coin.component.xml\"`,\n")
	line, _, _ = AssetField_Line(st, &state.project, AssetDef{path = "assets/beep.wav", kind = .Audio})
	testing.expect(t, strings.contains(line, "beep: e.SoundAsset `export:\"default=assets/beep.wav\"`,") && strings.contains(line, "e.Game_PlaySound(self.game, self.beep)"), line)
	// A data resource: its type in the tag (the inspector lists resources of that type)
	append(&state.project.data, DataDef{path = strings.clone("data/scout.data.json"), type = strings.clone("ShipStats")})
	line, _, _ = AssetField_Line(st, &state.project, AssetDef{path = "data/scout.data.json", kind = .Data})
	testing.expect(t, strings.contains(line, "scout: e.DataAsset `export:\"default=data/scout.data.json kind=ShipStats\"`,") && strings.contains(line, "e.Data(ShipStats, self.scout)"), line)
	_, _, ok = AssetField_Line(st, &state.project, AssetDef{path = "levels/world.ldtk", kind = .LDtk})
	testing.expect(t, !ok, "no handle type")
	free_all(context.temp_allocator)
}

@(test)
project_sound_output_settings :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	testing.expect_value(t, state.project.audioOutput, e.DEFAULT_AUDIO_OUTPUT)
	// Not written while the default
	testing.expect(t, !strings.contains(ProjectToXML(&state.project, context.temp_allocator), "audioFrequency"), "default: not written")
	ProjectSettings_Open(&state)
	send(&state, Project_Settings_Audio_Changed{false, 0})
	send(&state, Project_Settings_Audio_Changed{true, 1})
	send(&state, Project_Settings_Applied{})
	testing.expect_value(t, state.project.audioOutput, e.AudioOutputSettings{frequency = 0, channels = 1})
	xml := ProjectToXML(&state.project, context.temp_allocator)
	testing.expect(t, strings.contains(xml, `audioFrequency="0" audioChannels="1"`), xml)
	send(&state, Action.Undo)
	testing.expect_value(t, state.project.audioOutput, e.DEFAULT_AUDIO_OUTPUT)
	free_all(context.temp_allocator)
}

@(test)
ldtk_inspector_says_what_entities_become :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	settings: e.LDtkLevelSettings
	settings.entityComponents = make([dynamic]e.LDtkEntityComponent, context.temp_allocator)
	sample := e.LDtkEntity{identifier = "Coin", fields = {{identifier = "Value"}, {identifier = "glow_color"}}}

	// Nothing mapped and no script: its rectangle, a warning
	state.scripts.status = .Ready
	lines, bare := LDtkEdit_EntityPlan(&state, &settings, "Coin", &sample)
	testing.expect(t, bare && strings.contains(lines[0], "rectangle"), "a bare rectangle")
	// A script named like it: it runs, its fields matched like the engine does
	fields := make([dynamic]ScriptFieldDesc, context.temp_allocator)
	append(&fields, ScriptFieldDesc{name = "value"})
	append(&state.scripts.scripts, ScriptDesc{name = strings.clone("Coin"), fields = fields})
	defer { delete(state.scripts.scripts[0].name); clear(&state.scripts.scripts) }
	lines, bare = LDtkEdit_EntityPlan(&state, &settings, "Coin", &sample)
	testing.expect(t, !bare, "not bare")
	joined := strings.join(lines, "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "runs script Coin (named like the entity)"), joined)
	testing.expect(t, strings.contains(joined, "fields: Value → Coin.value, glow_color (no script field)"), joined)
	// Mapped to a component: that's what it becomes
	append(&settings.entityComponents, e.LDtkEntityComponent{entity = "Coin", component = "components/coin.component.xml"})
	lines, _ = LDtkEdit_EntityPlan(&state, &settings, "Coin", &sample)
	testing.expect(t, strings.contains(lines[0], "component coin (mapped)"), lines[0])
	free_all(context.temp_allocator)
}

@(test)
component_tabs_show_and_ask_about_unsaved_changes :: proc(t: ^testing.T) {
	state := testState()
	defer State_Destroy(&state)
	dir := tempDir("editor_test_component_save")
	defer removeAll(dir)
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone(dir)
	index, problem := Project_NewComponent(&state.project, "ship", .Sprite)
	testing.expect_value(t, problem, "")
	state.project.scenes[index].opened = true
	testing.expect(t, !Scene_IsDirty(&state, index), "just written: clean")
	tab := -1
	for scene, i in ViewportTabScenes(&state) do if scene == index do tab = i
	if !testing.expect(t, tab >= 0, "its tab") do return

	// An edit: dirty; closing asks; Don't Save puts the file's back
	edit :: proc(state: ^State, index: int) {
		Scene_InsertNode(&state.project.scenes[index], "Gun", .Node2D, 0)
		state.history.version += 1
	}
	edit(&state, index)
	testing.expect(t, Scene_IsDirty(&state, index), "edited: dirty")
	send(&state, Scene_Tab_Closed(tab))
	testing.expect(t, state.componentClose.open && state.project.scenes[index].opened, "asks, still open")
	send(&state, Component_Close_Chosen(.Discard))
	testing.expect_value(t, len(state.project.scenes[index].nodes), 1)
	testing.expect(t, !Scene_IsDirty(&state, index) && !state.project.scenes[index].opened, "back to the file, closed")

	// Again, and Save: written in place
	state.project.scenes[index].opened = true
	edit(&state, index)
	for scene, i in ViewportTabScenes(&state) do if scene == index do tab = i
	send(&state, Scene_Tab_Closed(tab))
	send(&state, Component_Close_Chosen(.Save))
	data, _ := os.read_entire_file(filepath.join({dir, state.project.scenes[index].component}, context.temp_allocator) or_else "", context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `name="Gun"`), "saved")
	testing.expect(t, !Scene_IsDirty(&state, index) && !state.project.scenes[index].opened, "clean, closed")
	// A clean one closes without asking
	state.project.scenes[index].opened = true
	for scene, i in ViewportTabScenes(&state) do if scene == index do tab = i
	send(&state, Scene_Tab_Closed(tab))
	testing.expect(t, !state.componentClose.open && !state.project.scenes[index].opened, "no question")
	free_all(context.temp_allocator)
}
