package crossfire_editor

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import e "engine:."

// Painting tilemaps: every tool on Aseprite's terrain tileset (tests/fixtures/aseprite/terrain:
// a 4 x 4 grid of 4 x 4 tiles, tile i+1 the grass for edges i; 17 dirt), strokes as undo steps,
// grids growing, new layers, back to the file's tiles, saved and drawn

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

// A stroke from one cell to another (cells of 4 px, the TileMap at the origin)
@(private="file")
stroke :: proc(state: ^State, from, to: [2]int, erase := false) {
	world :: proc(c: [2]int) -> [2]f32 { return {f32(c.x) * 4 + 2, f32(c.y) * 4 + 2} }
	sendTo(state, Tile_Brush{world = world(from), phase = .Begin, erase = erase})
	if from != to do sendTo(state, Tile_Brush{world = world(to), phase = .Move})
	sendTo(state, Tile_Brush{world = world(to), phase = .End})
}

@(test)
tilemaps_are_painted_in_the_editor :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_tile_paint"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	testing.expect_value(t, Project_Save(&state.project), "")
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/aseprite/terrain.aseprite")
	testing.expect_value(t, problem, "")
	if index < 0 do return
	level := Scene_AddTileMapAt(&state.project.scenes[0], state.project.assets[index].path, -1, {0, 0})
	state.selectedNode = level
	tilemap :: proc(state: ^State, at: int) -> ^e.TileMapSettings { return &state.project.scenes[0].nodes[at].tilemap }

	// Nothing paints until the Tiles tab shows
	stroke(&state, {0, 0}, {0, 0})
	testing.expect_value(t, len(tilemap(&state, level).painted), 0)
	sendTo(&state, Bottom_Tab_Changed(int(BottomTab.Tiles)))
	node, ase := TilePaint_Node(&state)
	testing.expect(t, node != nil && ase != nil, "the TileMap paints")
	testing.expect_value(t, TilePaint_Layer(&state, node, ase), "Ground")

	// Paint: the first stroke copies the file's tiles, then the brush (dirt) goes on two cells
	sendTo(&state, Tile_Brush_Chosen(17))
	stroke(&state, {0, 0}, {1, 0})
	painted := tilemap(&state, level).painted
	testing.expect_value(t, len(painted), 1)
	if len(painted) != 1 do return
	ground := &painted[0]
	testing.expect(t, ground.layer == "Ground" && ground.columns == 4 && ground.rows == 4, "the file's grid")
	testing.expect(t, ground.tiles[0] == 17 && ground.tiles[1] == 17 && ground.tiles[2] == 3, "two dirt tiles, the rest the file's")
	// One undo step for the stroke
	sendTo(&state, Action.Undo)
	testing.expect_value(t, len(tilemap(&state, level).painted), 0)
	sendTo(&state, Action.Redo)
	ground = &tilemap(&state, level).painted[0]
	testing.expect_value(t, ground.tiles[1], u32(17))

	// Flips ride on the brush; right erases; painting off the grid grows it (left: it moves)
	sendTo(&state, Tile_Brush_Turned(0))
	stroke(&state, {3, 3}, {3, 3})
	ground = &tilemap(&state, level).painted[0]
	testing.expect_value(t, ground.tiles[15], 17 | e.ASEPRITE_TILE_FLIP_X)
	stroke(&state, {3, 3}, {3, 3}, erase = true)
	ground = &tilemap(&state, level).painted[0]
	testing.expect_value(t, ground.tiles[15], u32(0))
	sendTo(&state, Tile_Brush_Turned(0))
	stroke(&state, {-1, 0}, {-1, 0})
	ground = &tilemap(&state, level).painted[0]
	testing.expect(t, ground.columns == 5 && ground.x == -4 && ground.tiles[0] == 17 && ground.tiles[1] == 17, "grown left")

	// Pick, Rectangle, Fill
	sendTo(&state, Tile_Tool_Chosen(.Pick))
	stroke(&state, {2, 1}, {2, 1})
	testing.expect_value(t, state.tilePainter.tile, u32(7))
	sendTo(&state, Tile_Tool_Chosen(.Rectangle))
	stroke(&state, {0, 2}, {1, 3})
	ground = &tilemap(&state, level).painted[0]
	at :: proc(g: ^e.TileLayerData, column, row: int) -> u32 { return g.tiles[row * g.columns + column - g.x / 4] }
	testing.expect(t, at(ground, 0, 2) == 7 && at(ground, 1, 3) == 7 && at(ground, 2, 2) != 7, "a 2 x 2 rectangle")
	sendTo(&state, Tile_Brush_Chosen(1))
	sendTo(&state, Tile_Tool_Chosen(.Fill))
	stroke(&state, {0, 2}, {0, 2})
	ground = &tilemap(&state, level).painted[0]
	testing.expect(t, at(ground, 0, 2) == 1 && at(ground, 1, 3) == 1, "the rectangle filled")

	// Terrain: a cell of grass beside grass, the neighbours following
	sendTo(&state, Tile_Terrain_Chosen("grass"))
	testing.expect_value(t, state.tilePainter.tool, TilePaintTool.Terrain)
	stroke(&state, {3, 3}, {3, 3})
	ground = &tilemap(&state, level).painted[0]
	testing.expect(t, e.Tileset_TerrainOf(&ase.tilesets[0], at(ground, 3, 3)) == "grass", "grass painted")

	// A layer of the scene's own, then Ground back to the file's tiles
	sendTo(&state, Tile_Layer_Added{})
	testing.expect_value(t, state.tilePainter.layer, "Layer 2")
	sendTo(&state, Tile_Tool_Chosen(.Paint))
	sendTo(&state, Tile_Brush_Chosen(16))
	stroke(&state, {1, 1}, {1, 1})
	painted = tilemap(&state, level).painted
	testing.expect(t, len(painted) == 2 && painted[1].layer == "Layer 2" && painted[1].columns == 2 && painted[1].tiles[3] == 16, "the new layer, grown to its cell")
	sendTo(&state, Tile_Layer_Chosen("Ground"))
	sendTo(&state, Tile_Layer_Reverted{})
	painted = tilemap(&state, level).painted
	testing.expect(t, len(painted) == 1 && painted[0].layer == "Layer 2", "Ground is the file's again")
	sendTo(&state, Tile_Layer_Chosen("Layer 2"))
	sendTo(&state, Tile_Layer_Reverted{})
	testing.expect_value(t, len(tilemap(&state, level).painted), 1)

	// Saved and loaded: the same tiles
	xml := SceneToXML(&state.project.scenes[0], context.temp_allocator)
	testing.expect(t, strings.contains(xml, `<tiles layer="Layer 2"`), xml)
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect(t, TileMapSettings_Equal(loaded.scenes[0].nodes[level].tilemap, tilemap(&state, level)^), "round trip")

	// The viewport draws the painted layer over the file's: the full grass tile at (4, 4)
	state.viewport = {center = {8, 8}, zoom = 1, size = {16, 16}}
	pixels, ok := Preview_Render(&state, {16, 16}, 1)
	testing.expect(t, ok, "rendered")
	if ok {
		p := pixels[(4 * 16 + 4) * 4:][:4]
		testing.expectf(t, p[0] == 240 && p[1] == 15, "the painted tile: %v", p)
	}
	free_all(context.temp_allocator)
}
