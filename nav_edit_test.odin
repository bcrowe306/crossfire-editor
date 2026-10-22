package crossfire_editor

import "core:os"
import "core:sync"
import "core:testing"
import e "engine:."

// Navigation in the editor: a region's settings edited and undone, its grid (in the viewport's
// engine scene) following a wall as it moves, an agent's settings, saved and read back

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
navigation_in_the_editor :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_nav_edit"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, themeSelection = -1, dataSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	scene := &state.project.scenes[0]
	region := Scene_InsertNode(scene, "Floor", .NavRegion, -1)
	testing.expect_value(t, scene.nodes[region].shapeSize, [2]f32{640, 360})
	body := Scene_InsertNode(scene, "Wall", .StaticBody, -1)
	scene.nodes[body].position = {100, 100}
	box := Scene_InsertNode(scene, "Box", .CollisionShape, body)
	scene.nodes[box].shapeSize = {40, 40}
	walker := Scene_InsertNode(scene, "Walker", .Node2D, -1)
	agent := Scene_InsertNode(scene, "Nav", .NavAgent, walker)

	// The region: bigger cells; undo
	state.selectedNode = region
	sendTo(&state, NumberTarget_Msg(NavNumberTarget(NavField.Cell_Size), 20))
	testing.expect_value(t, state.project.scenes[0].nodes[region].nav.cellSize, f32(20))
	sendTo(&state, Nav_Setting_Changed{field = .Agent_Radius, value = 0})
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[0].nodes[region].nav.agentRadius, e.DEFAULT_NAV_SETTINGS.agentRadius)
	sendTo(&state, Action.Redo)

	// The viewport's grid: the wall's cells blocked; moved, they follow
	_, ok := Preview_Render(&state, {64, 64}, 1)
	testing.expect(t, ok, "rendered")
	built := Preview_Node(region)
	testing.expect(t, built != nil && e.Node_Is(built, e.NavRegion), "a built NavRegion")
	if built != nil && e.Node_Is(built, e.NavRegion) {
		grid := &(cast(^e.NavRegion)built).grid
		testing.expect_value(t, grid.cellSize, f32(20))
		testing.expect(t, e.NavGrid_IsBlocked(grid, {5, 5}), "the wall's cell (100, 100)")
		testing.expect(t, !e.NavGrid_IsBlocked(grid, {15, 5}), "open further on")
		state.project.scenes[0].nodes[body].position = {300, 100}
		Preview_Render(&state, {64, 64}, 1)
		grid = &(cast(^e.NavRegion)Preview_Node(region)).grid
		testing.expect(t, !e.NavGrid_IsBlocked(grid, {5, 5}) && e.NavGrid_IsBlocked(grid, {15, 5}), "followed the wall")
	}

	// The agent
	state.selectedNode = agent
	sendTo(&state, NumberTarget_Msg(NavNumberTarget(NavField.Speed), 250))
	sendTo(&state, Nav_Setting_Changed{field = .Auto_Move, flag = false})
	n := state.project.scenes[0].nodes[agent].nav
	testing.expect(t, n.speed == 250 && !n.autoMove, "the agent's settings")

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	for node, i in loaded.scenes[0].nodes {
		original := state.project.scenes[0].nodes[i]
		testing.expectf(t, node.nav == original.nav, "%s's settings", node.name)
		if node.kind == .NavRegion do testing.expect_value(t, node.shapeSize, original.shapeSize)
	}
	free_all(context.temp_allocator)
}
