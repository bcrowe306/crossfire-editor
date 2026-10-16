package editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import e "engine:."
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
		browserOpen = {.Scenes = true, .Scripts = true, .Images = true, .Audio = false, .Fonts = false},
		layout = {bottomOpen = true},
		settings = Settings_Default(),
	}
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
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	return dir
}

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
	send(&state, Node_Field_Changed{.Columns, 0}) // Clamped to at least 1
	send(&state, Node_Text_Changed{.Play_Mode, "Reverse"})
	send(&state, Node_Text_Changed{.Play_Mode, "NotAMode"}) // Ignored
	send(&state, Node_Flag_Changed{.Loop, false})
	balloon := scene.nodes[state.selectedNode]
	testing.expect_value(t, balloon.columns, 1)
	testing.expect_value(t, balloon.playMode, e.AnimationPlayMode.Reverse)
	testing.expect_value(t, balloon.loop, false)

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
	// Only Images is open, with 3 images; the Scripts folder is hidden (the project has no scripts)
	testing.expect_value(t, len(BrowserRows(&state)), len(BrowserFolder) - 1 + 3)
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
	defer os.remove_all(dir)

	original := Project_CreateDemo(dir)
	defer Project_Destroy(&original)
	// Characters that need escaping, and non-default values, must survive
	label := &original.scenes[0].nodes[0]
	delete(label.text)
	label.text = strings.clone(`Tom & "Jerry" <3`)
	label.centered = false
	original.scenes[1].nodes[1].zoom = 2.5
	original.scenes[1].nodes[2].visible = false
	original.scenes[1].nodes[2].rotation = 45

	testing.expect_value(t, Project_Save(&original), "")
	loaded, message := Project_Load(dir)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")

	testing.expect_value(t, loaded.name, original.name)
	testing.expect_value(t, loaded.gameSize, original.gameSize)
	testing.expect_value(t, loaded.scaleMode, original.scaleMode)
	testing.expect_value(t, loaded.background, original.background)
	testing.expect_value(t, loaded.startScene, original.startScene)
	testing.expect_value(t, len(loaded.assets), len(original.assets))
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
			testing.expectf(t, a.texture == b.texture && a.columns == b.columns && a.rows == b.rows && a.fps == b.fps && a.loop == b.loop && a.playMode == b.playMode, "%s/%s: sprite", scene.name, a.name)
			if a.kind == .Label {
				testing.expectf(t, a.text == b.text && a.fontSize == b.fontSize && a.color == b.color && a.centered == b.centered, "%s/%s: label", scene.name, a.name)
			}
			if a.kind == .Camera do testing.expect_value(t, b.zoom, a.zoom)
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
	// World, Spaceship, Props and HUD have children; BackMenu has button items
	testing.expect_value(t, strings.count(text, "</node>"), 5)
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

	v.zoom = 1
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
	for action in ([]Action{.Tool_Select, .Tool_Move, .Tool_Rotate, .Tool_Scale}) {
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
	}
	for c in cases {
		kind, ok := AssetKindForPath(c.path)
		testing.expectf(t, ok == c.ok && (!ok || kind == c.kind), "%s: got %v %v", c.path, kind, ok)
	}
}

@(test)
importing_copies_files_into_assets :: proc(t: ^testing.T) {
	project := tempProject("odin_sdl_editor_import")
	defer { os.remove_all(project.rootPath); Project_Destroy(&project) }
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
	defer { os.remove_all(project.rootPath); Project_Destroy(&project) }
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
	defer { os.remove_all(state.project.rootPath); State_Destroy(&state) }
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
	settings := Settings_Default()
	settings.theme = .Light
	settings.fontSize = 15
	settings.undoLimit = 50
	settings.keymap[.Save_Project] = {{.S, {.Ctrl, .Alt}}, {}}
	settings.keymap[.Delete_Node] = {}

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
	free_all(context.temp_allocator)
}

@(test)
shortcut_text_round_trips :: proc(t: ^testing.T) {
	for key in skald.Key {
		for mods in ([]skald.Modifiers{{}, {.Ctrl}, {.Ctrl, .Shift}, {.Alt, .Super}}) {
			chord := skald.Shortcut{key, mods}
			if chord == {} do continue
			parsed, ok := Shortcut_Parse(skald.shortcut_format(chord))
			testing.expectf(t, ok && parsed == chord, "%v didn't round trip (%s)", chord, skald.shortcut_format(chord))
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
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
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
	send(&state, Script_Prop_Changed{"speed", "250", "100"})
	testing.expect_value(t, NodeDef_ScriptValue(node, &state.scripts.scripts[0].fields[0]), "250")
	testing.expect_value(t, len(node.props), 1)
	send(&state, Script_Prop_Changed{"speed", "100", "100"})
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
	testing.expect(t, strings.contains(text, `formatVersion="3"`))
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
	state.settings.codeEditor = FixedText_Make("true {file}")
	os.make_directory("build")
	dir := "build/test_script_project"
	os.remove_all(dir)
	defer os.remove_all(dir)
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
	expect :: proc(t: ^testing.T, got: []string, want: []string, loc := #caller_location) {
		testing.expect_value(t, len(got), len(want), loc = loc)
		for w, i in want do if i < len(got) do testing.expect_value(t, got[i], w, loc = loc)
	}
	expect(t, Script_EditorCommand("zed {file}:{line}", "/p/a.odin", 12), {"zed", "/p/a.odin:12"})
	expect(t, Script_EditorCommand("  code --goto {file}:{line} ", "/p/a.odin", 0), {"code", "--goto", "/p/a.odin:1"})
	// No {file}: it goes at the end. Empty: the default
	expect(t, Script_EditorCommand("xdg-open", "/p/a.odin", 3), {"xdg-open", "/p/a.odin"})
	expect(t, Script_EditorCommand("", "/p/a.odin", 3), {"zed", "/p/a.odin:3"})
	free_all(context.temp_allocator)
}
