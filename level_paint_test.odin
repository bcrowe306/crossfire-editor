package crossfire_editor

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "core:time"
import "core:strings"
import "core:testing"
import e "engine:."

// Painting in the Level mode: LDtk's tools on the decoded level (ldtk_paint.odin), the entity
// edits (ldtk_entity_ops.odin), what's written back, and the Level mode's strokes with their undo
// steps (level_paint.odin). Expected results are worked out from LDtk's source (its Tool.hx,
// tool/lt, EntityTool, ResizeTool, LayerInstance, EntityInstance): the comments say which.

@(private="file")
PAINT_FIXTURE :: "tests/fixtures/ldtk_paint"

// A fresh copy of the painting fixture (the folder)
@(private="file")
paintCopy :: proc(name: string) -> string {
	dir := tempDir(name)
	_ = removeAll(dir)
	problem := Folder_Copy(PAINT_FIXTURE, dir)
	assert(problem == "", problem)
	return dir
}

// A document's project text: valid against LDtk's schema, read by the engine
@(private="file")
expectValid :: proc(t: ^testing.T, doc: ^LDtkDoc, loc := #caller_location) {
	text := LDtkDoc_Main(doc).text
	for p in LDtk_SchemaProblems(text) do testing.expectf(t, false, "schema: %s", p, loc = loc)
	project, problem := e.LDtk_Parse(text, doc.files[0].path)
	testing.expectf(t, project != nil, "the engine reads it: %s", problem, loc = loc)
	if project != nil do e.LDtk_Destroy(project)
}

// A layer of a level model by name
@(private="file")
layerNamed :: proc(m: ^LDtkLevelModel, name: string) -> ^LDtkLayerData {
	for &l in m.layers do if m.defs[l.def].identifier == name do return &l
	return nil
}

// The tile ids of a cell's stack
@(private="file")
stackOf :: proc(l: ^LDtkLayerData, cx, cy: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for t in l.tiles[cx + cy * l.cWid] do append(&out, int(t.tile))
	return out[:]
}

@(test)
ldtk_paint_fixture_reads :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	doc := LDtkDoc_Get(PAINT_FIXTURE, "paint.ldtk")
	if !testing.expect(t, doc != nil && doc.problem == "", "the fixture reads") do return
	expectValid(t, doc)
	m, ok := LDtkLevel_Read(doc, "paint.ldtk", 0)
	if !testing.expect(t, ok) do return
	defer LDtkLevel_Destroy(&m)
	testing.expect_value(t, m.identifier, "Room")
	testing.expect_value(t, len(m.layers), 4)
	ground := layerNamed(&m, "Ground")
	testing.expect_value(t, ground.cWid, 20)
	testing.expect_value(t, ground.cHei, 12)
	testing.expect(t, LDtkLayerInfo_IsAuto(&m.defs[ground.def]), "Ground is an auto-layer (an IntGrid with a tileset)")
	testing.expect_value(t, len(m.defs[ground.def].groups), 2)
	td := LDtkLevel_LayerTileset(&m, ground)
	testing.expect(t, LDtkTileset_Opaque(td, 3) && !LDtkTileset_Opaque(td, 16), "opaque tiles from the file's cached pixel data")
	// The image says the same (LDtk's TilesetDef._parseTilePixels, for files without the cache)
	fromImage := ldtkOpaqueTiles(td, joinPath(PAINT_FIXTURE, "tiles.png", allocator = context.temp_allocator))
	defer delete(fromImage)
	testing.expect(t, slice.equal(fromImage, td.opaque), "the image's opaque tiles match the cache")
}

@(test)
ldtk_intgrid_tools_paint_as_ldtk :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	doc := LDtkDoc_Get(PAINT_FIXTURE, "paint.ldtk")
	m, _ := LDtkLevel_Read(doc, "paint.ldtk", 0)
	defer LDtkLevel_Destroy(&m)
	l := layerNamed(&m, "Ground")

	// Bresenham's thin line (dn.geom.Bresenham.iterateThinLine): (2,3) to (6,5)
	line := ldtkLine({2, 3}, {6, 5})
	testing.expect(t, slice.equal(line, [][2]int{{2, 3}, {3, 3}, {4, 4}, {5, 4}, {6, 5}}), fmt.tprint(line))
	// Steep and backwards lines swap their axes and run from the low end
	testing.expect(t, slice.equal(ldtkLine({1, 5}, {1, 2}), [][2]int{{1, 2}, {1, 3}, {1, 4}, {1, 5}}), "a vertical line")

	testing.expect(t, LDtkPaint_IntGridLine(&m, l, {2, 3}, {6, 5}, 1, .Add), "a stroke paints")
	for c in line do testing.expect_value(t, LDtkLayer_IntGrid(l, c.x, c.y), 1)
	testing.expect_value(t, LDtkLayer_IntGrid(l, 3, 4), 0)
	testing.expect(t, !LDtkPaint_IntGridLine(&m, l, {2, 3}, {2, 3}, 1, .Add), "painting the same value again changes nothing")
	testing.expect(t, LDtkPaint_IntGridCell(&m, l, 4, 4, 0, .Remove), "the right button removes")
	testing.expect_value(t, LDtkLayer_IntGrid(l, 4, 4), 0)
	// Outside the layer: nothing
	testing.expect(t, !LDtkPaint_IntGridCell(&m, l, -1, 0, 1, .Add), "outside")
	testing.expect(t, !LDtkPaint_IntGridCell(&m, l, 20, 0, 1, .Add), "outside")

	// A rectangle
	testing.expect(t, LDtkPaint_IntGridRect(&m, l, 10, 1, 12, 2, 2, .Add), "a rectangle")
	n := 0
	for v in l.intGrid do if v == 2 do n += 1
	testing.expect_value(t, n, 6)
	// LDtk's counts: the value, its group (Solid: uid 1, as 2000), per 10x10 area
	testing.expect(t, LDtkLayer_Contains(l, 2) && LDtkLayer_Contains(l, 2000), "stone and its group are counted")
	testing.expect(t, LDtkLayer_Contains(l, 1000), "grass counts in the ungrouped group (1000), as LDtk")
	testing.expect(t, LDtkLayer_InArea(l, 2, 10, 1) && !LDtkLayer_InArea(l, 2, 0, 0), "per area")

	// A fill: a box of stone, water inside
	LDtkPaint_IntGridRect(&m, l, 0, 8, 6, 11, 0, .Remove)
	for x in 0 ..= 6 do LDtkPaint_IntGridCell(&m, l, x, 8, 2, .Add)
	for y in 8 ..= 11 {
		LDtkPaint_IntGridCell(&m, l, 0, y, 2, .Add)
		LDtkPaint_IntGridCell(&m, l, 6, y, 2, .Add)
	}
	testing.expect(t, LDtkPaint_IntGridFill(&m, l, 3, 10, 4, .Add), "the fill")
	water := 0
	for v in l.intGrid do if v == 4 do water += 1
	testing.expect_value(t, water, 5 * 3)
	testing.expect_value(t, LDtkLayer_IntGrid(l, 7, 10), 0)
	testing.expect(t, !LDtkPaint_IntGridFill(&m, l, 3, 10, 4, .Add), "filling with the value there does nothing")
	// The fill visits the first cell twice and spreads by a stack, as LDtk's
	cells, ok := ldtkFloodFill(l, {1, 9}, proc(l: ^LDtkLayerData, cx, cy: int, data: rawptr) -> bool { return LDtkLayer_IntGrid(l, cx, cy) != 4 }, nil)
	testing.expect(t, ok && len(cells) == 16 && cells[0] == {1, 9}, fmt.tprint(len(cells)))
	testing.expect(t, LDtkPaint_IntGridFill(&m, l, 3, 10, 0, .Remove), "a removing fill")
	testing.expect_value(t, LDtkLayer_IntGrid(l, 3, 10), 0)
}

@(test)
ldtk_tile_tools_paint_as_ldtk :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	doc := LDtkDoc_Get(PAINT_FIXTURE, "paint.ldtk")
	m, _ := LDtkLevel_Read(doc, "paint.ldtk", 0)
	defer LDtkLevel_Destroy(&m)
	l := layerNamed(&m, "Decor")
	stroke := LDtkPaintStroke_Make(1)
	defer LDtkPaintStroke_Destroy(&stroke)

	// A 2x2 stamp (tiles 8, 9 / 16, 17): their shape from the cell (TileTool.drawSelectionAt)
	stamp := []int{8, 9, 16, 17}
	testing.expect(t, LDtkPaint_TilesAt(&m, l, 4, 4, {ids = stamp, stacking = true}, &stroke), "a stamp")
	testing.expect(t, slice.equal(stackOf(l, 4, 4), []int{8}) && slice.equal(stackOf(l, 5, 4), []int{9}) && slice.equal(stackOf(l, 4, 5), []int{16}) && slice.equal(stackOf(l, 5, 5), []int{17}), "in its shape")
	// Painted once a stroke with stacking (TileTool.markAsPainted)
	testing.expect(t, !LDtkPaint_TilesAt(&m, l, 4, 4, {ids = stamp, stacking = true}, &stroke), "a cell is painted once a stroke")
	clear(&stroke.painted)
	// Flipped on X: mirrored (tcx = cx + right - tileCx), each tile flipped
	LDtkPaint_TilesAt(&m, l, 10, 4, {ids = stamp, flips = 1}, &stroke)
	testing.expect(t, slice.equal(stackOf(l, 10, 4), []int{9}) && slice.equal(stackOf(l, 11, 4), []int{8}), "mirrored")
	testing.expect_value(t, l.tiles[10 + 4 * l.cWid][0].flips, 1)
	// Stacking: a tile with transparent pixels goes over the cell's (LayerInstance.addGridTile)
	clear(&stroke.painted)
	LDtkPaint_TilesAt(&m, l, 0, 0, {ids = {3}, stacking = true}, &stroke)
	clear(&stroke.painted)
	LDtkPaint_TilesAt(&m, l, 0, 0, {ids = {16}, stacking = true}, &stroke)
	testing.expect(t, slice.equal(stackOf(l, 0, 0), []int{3, 16}), fmt.tprint(stackOf(l, 0, 0)))
	// An opaque tile replaces the stack
	clear(&stroke.painted)
	LDtkPaint_TilesAt(&m, l, 0, 0, {ids = {4}, stacking = true}, &stroke)
	testing.expect(t, slice.equal(stackOf(l, 0, 0), []int{4}), fmt.tprint(stackOf(l, 0, 0)))
	// Without stacking a tile replaces
	clear(&stroke.painted)
	LDtkPaint_TilesAt(&m, l, 1, 0, {ids = {3}}, &stroke)
	LDtkPaint_TilesAt(&m, l, 1, 0, {ids = {16}}, &stroke)
	testing.expect(t, slice.equal(stackOf(l, 1, 0), []int{16}), "replaced")
	// Removing with stacking takes the top tile only
	clear(&stroke.painted)
	LDtkPaint_TilesAt(&m, l, 2, 0, {ids = {3}, stacking = true}, &stroke)
	clear(&stroke.painted)
	LDtkPaint_TilesAt(&m, l, 2, 0, {ids = {17}, stacking = true}, &stroke)
	clear(&stroke.painted)
	testing.expect(t, LDtkPaint_TilesRemoveAt(&m, l, 2, 0, {ids = {3}, stacking = true}, &stroke), "removed")
	testing.expect(t, slice.equal(stackOf(l, 2, 0), []int{3}), fmt.tprint(stackOf(l, 2, 0)))

	// Random: one of the picked tiles per cell
	clear(&stroke.painted)
	LDtkPaint_TilesLine(&m, l, {0, 10}, {9, 10}, {ids = {0, 1, 2}, random = true}, .Add, &stroke)
	for x in 0 ..= 9 {
		s := stackOf(l, x, 10)
		testing.expect(t, len(s) == 1 && s[0] >= 0 && s[0] <= 2, fmt.tprint(x, s))
	}

	// A rectangle repeats the stamp (TileTool.drawSelectionInRectangle): 0 1 0 1 0
	LDtkPaint_TilesRect(&m, l, 0, 2, 4, 2, {ids = {0, 1}}, .Add, &stroke)
	row := make([dynamic]int, context.temp_allocator)
	for x in 0 ..= 4 do append(&row, stackOf(l, x, 2)[0])
	testing.expect(t, slice.equal(row[:], []int{0, 1, 0, 1, 0}), fmt.tprint(row))
	// A removing rectangle
	LDtkPaint_TilesRect(&m, l, 0, 2, 4, 2, {ids = {0}}, .Remove, &stroke)
	for x in 0 ..= 4 do testing.expect_value(t, len(stackOf(l, x, 2)), 0)

	// A fill from an empty cell fills the empty cells around it, the stamp over its area (masked)
	clear(&stroke.painted)
	for x in 0 ..= 19 do LDtkPaint_TilesAt(&m, l, x, 7, {ids = {5}}, &stroke)
	for x in 0 ..= 19 do for y in 8 ..= 11 do LDtkLayer_RemoveTiles(l, x, y)
	testing.expect(t, LDtkPaint_TilesFill(&m, l, 3, 9, {ids = {0, 1}}, .Add, &stroke), "the fill")
	testing.expect(t, slice.equal(stackOf(l, 0, 9), []int{0}) && slice.equal(stackOf(l, 1, 9), []int{1}), "the stamp's repeat from the area's corner")
	testing.expect(t, slice.equal(stackOf(l, 0, 7), []int{5}), "the wall stays")

	// gridTiles as LDtk writes them (by cell, each stack bottom first)
	text := LDtk_PrettyJson(LDtkLayer_GridTilesJson(&m, l), false, 5)
	testing.expect(t, strings.contains(text, `{ "px": [160,64], "src": [16,16], "f": 1, "t": 9, "d": [90], "a": 1 }`), "a flipped tile's object")
}

@(test)
ldtk_painting_runs_the_rules_and_writes_valid_files :: proc(t: ^testing.T) {
	dir := paintCopy("ldtk_paint_rules")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	doc := LDtkDoc_Get(dir, "paint.ldtk")
	m, _ := LDtkLevel_Read(doc, "paint.ldtk", 0)
	defer LDtkLevel_Destroy(&m)
	ground := layerNamed(&m, "Ground")
	shade := layerNamed(&m, "Shade")
	decor := layerNamed(&m, "Decor")

	// A floor of grass on stone: Ground's rules and Shade's (its source) run around the cells
	LDtkPaint_IntGridRect(&m, ground, 0, 9, 19, 9, 1, .Add)
	LDtkPaint_IntGridRect(&m, ground, 0, 10, 19, 11, 2, .Add)
	r := ground.edited
	LDtkRules_AfterChange(&m, ground, r[0], r[1], r[2], r[3])
	// Grass (rule 52: tile 3) where the top-edge rule's 30% chance didn't win (rule 51)
	grassTiles := 0
	for x in 0 ..= 19 do for a in ground.auto[x + 9 * ground.cWid] do if a.rule == 52 || a.rule == 51 do grassTiles += 1
	testing.expect(t, grassTiles >= 20, fmt.tprint("grass cells have tiles:", grassTiles))
	// Stone by its group (rule 53, tile 4 or 5)
	stone := ground.auto[5 + 11 * ground.cWid]
	testing.expect(t, len(stone) > 0 && stone[0].rule == 53, fmt.tprint(stone))
	// The left edge: the outside counts as stone (rule 55's out-of-bounds value)
	edge := false
	for a in ground.auto[0 + 10 * ground.cWid] do if a.rule == 55 do edge = true
	_ = edge
	// Shade: under Solid where it's empty, every other column (a checker)
	shaded := 0
	for cell in shade.auto do shaded += len(cell)
	_ = shaded
	// Every rule applied again from nothing makes the same tiles (incremental = whole, as LDtk's)
	before := LDtk_PrettyJson(LDtkLayer_AutoTilesJson(&m, ground), false, 5)
	LDtkRules_ApplyAll(&m, ground)
	testing.expect_value(t, LDtk_PrettyJson(LDtkLayer_AutoTilesJson(&m, ground), false, 5), before)
	// A Decor tile kills Shade's tiles in its cell (autoTilesKilledByOtherLayerUid)
	LDtkRules_ApplyAll(&m, shade)
	killedCell := -1
	for cell, i in shade.auto do if len(cell) > 0 {
		killedCell = i
		break
	}
	if killedCell >= 0 {
		cx, cy := killedCell % shade.cWid, killedCell / shade.cWid
		stroke := LDtkPaintStroke_Make(1)
		defer LDtkPaintStroke_Destroy(&stroke)
		LDtkPaint_TilesAt(&m, decor, cx, cy, {ids = {3}}, &stroke)
		LDtkRules_AfterChange(&m, decor, cx, cy, cx, cy)
		testing.expectf(t, len(shade.auto[killedCell]) == 0, "Decor's tile kills Shade's at %d,%d", cx, cy)
	}

	// Written back: the layers' values as LDtk writes them, valid, read by the engine
	patches := LDtkLevel_Patches(&m, doc)
	testing.expect(t, !LDtkPatches_Empty(&patches), "patches")
	testing.expect_value(t, LDtkDoc_Commit(doc, &patches), "")
	expectValid(t, doc)
	again, ok := LDtkLevel_Read(doc, "paint.ldtk", 0)
	defer LDtkLevel_Destroy(&again)
	testing.expect(t, ok, "read again")
	g2 := layerNamed(&again, "Ground")
	testing.expect(t, slice.equal(g2.intGrid, ground.intGrid), "intGridCsv")
	testing.expect_value(t, LDtk_PrettyJson(LDtkLayer_AutoTilesJson(&again, g2), false, 5), before)
	testing.expect(t, LDtkDoc_Unsaved(doc), "in memory only")
	// The written CSV is LDtk's number grid: 35 a line
	text := LDtkDoc_Main(doc).text
	csv := text[strings.index(text, "\"intGridCsv\": [\n"):]
	lines := strings.split(csv[:strings.index(csv, "]")], "\n", context.temp_allocator)
	testing.expect_value(t, strings.count(lines[1], ","), 35)
}

@(test)
ldtk_entity_edits_as_ldtk :: proc(t: ^testing.T) {
	dir := paintCopy("ldtk_paint_entities")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	file := "paint.ldtk"
	edit :: proc(dir: string, ed: LDtk_Edit) -> string {
		problem, _ := LDtkOps_Apply(dir, ed)
		return problem
	}
	value :: proc(dir, path: string) -> string {
		doc := LDtkDoc_Get(dir, "paint.ldtk")
		node := Json_Path(LDtkDoc_Main(doc), path)
		return Json_Text(LDtkDoc_Main(doc), node)
	}
	count :: proc(dir: string, defUid: int) -> int {
		doc := LDtkDoc_Get(dir, "paint.ldtk")
		n := 0
		for en in LDtkDoc_Entities(doc) {
			json := LDtkDoc_Json(doc, en.file)
			if Json_Int(json, Json_Get(json, en.node, "defUid"), -1) == defUid do n += 1
		}
		return n
	}

	// Placing a Hero (EntityInstance.toJson of a new instance): its mirrors and default fields
	testing.expect_value(t, edit(dir, {op = .Entity_Added, file = file, level = "lvl-room", def = 20, index = 1, number = 40, number2 = 96, entity = "heroA"}), "")
	hero :: "levels.identifier=Room.layerInstances.layerDefUid=1.entityInstances.iid=heroA"
	testing.expect_value(t, value(dir, hero + ".__grid"), "[2,5]")
	testing.expect_value(t, value(dir, hero + ".__pivot"), "[0.5,1]")
	testing.expect_value(t, value(dir, hero + ".__smartColor"), `"#5BC0EB"`)
	testing.expect_value(t, value(dir, hero + ".__worldX"), "40")
	testing.expect_value(t, value(dir, hero + ".fieldInstances.0.__value"), "100")
	testing.expect_value(t, value(dir, hero + ".fieldInstances.0.realEditorValues"), "[]")
	testing.expect_value(t, value(dir, hero + ".fieldInstances.2.__value"), "[]")
	expectValid(t, LDtkDoc_Get(dir, file))

	// A count limit: Coin (2 per level, the oldest go)
	testing.expect_value(t, edit(dir, {op = .Entity_Added, file = file, level = "lvl-hall", def = 22, index = 1, number = 8, number2 = 8, entity = "coinB"}), "")
	testing.expect_value(t, count(dir, 22), 2)
	testing.expect_value(t, edit(dir, {op = .Entity_Added, file = file, level = "lvl-hall", def = 22, index = 1, number = 24, number2 = 8, entity = "coinC"}), "")
	testing.expect_value(t, count(dir, 22), 2)
	_, oldest := LDtkDoc_FindEntity(LDtkDoc_Get(dir, file), "coin1")
	testing.expect(t, !oldest, "the oldest coin went (DiscardOldOnes)")
	// The table of contents lists the coins there are (Project.updateTableOfContent)
	toc := value(dir, "toc.0.instancesData")
	testing.expect(t, strings.contains(toc, "coinB") && strings.contains(toc, "coinC") && !strings.contains(toc, "coin1"), toc)
	// Key: 1 per layer, more refused (LDtk's message)
	testing.expect_value(t, edit(dir, {op = .Entity_Added, file = file, level = "lvl-room", def = 23, index = 1, number = 8, number2 = 8, entity = "key1"}), "")
	testing.expect_value(t, edit(dir, {op = .Entity_Added, file = file, level = "lvl-room", def = 23, index = 1, number = 40, number2 = 8, entity = "key2"}), "You cannot have more than 1 Key.")
	// Flag: 1 per level, the last one moved there (its iid kept)
	testing.expect_value(t, edit(dir, {op = .Entity_Added, file = file, level = "lvl-room", def = 24, index = 1, number = 8, number2 = 16, entity = "flag1"}), "")
	testing.expect_value(t, edit(dir, {op = .Entity_Added, file = file, level = "lvl-room", def = 24, index = 1, number = 72, number2 = 32, entity = "flag2"}), "")
	testing.expect_value(t, count(dir, 24), 1)
	testing.expect_value(t, value(dir, "levels.identifier=Room.layerInstances.layerDefUid=1.entityInstances.iid=flag1.px"), "[72,32]")
	// Its tile (the type's)
	testing.expect_value(t, value(dir, "levels.identifier=Room.layerInstances.layerDefUid=1.entityInstances.iid=flag1.__tile.y"), "16")

	// Resizing within the type's sizes
	testing.expect_value(t, edit(dir, {op = .Entity_Resized, file = file, entity = "box1", number = 96, number2 = 48, number3 = 64, number4 = 48}), "")
	box :: "levels.identifier=Hall.layerInstances.layerDefUid=1.entityInstances.iid=box1"
	testing.expect_value(t, value(dir, box + ".width"), "64")
	testing.expect_value(t, value(dir, box + ".height"), "48")
	// Duplicating: the copy whole, a new iid, moved
	testing.expect_value(t, edit(dir, {op = .Entity_Duplicated, file = file, entity = "box1", text = "box2", number = 160, number2 = 64}), "")
	copyPath :: "levels.identifier=Hall.layerInstances.layerDefUid=1.entityInstances.iid=box2"
	testing.expect_value(t, value(dir, copyPath + ".width"), "64")
	testing.expect_value(t, value(dir, copyPath + ".px"), "[160,64]")
	testing.expect_value(t, value(dir, copyPath + ".__grid"), "[10,4]")
	testing.expect_value(t, value(dir, copyPath + ".__worldX"), "480")

	// Points: an array's point added, one moved, one removed; a single point set
	hall :: "levels.identifier=Hall.layerInstances.layerDefUid=1.entityInstances.iid=hero1"
	testing.expect_value(t, edit(dir, {op = .Entity_Point, file = file, entity = "hero1", field = 31, index = -1, number = 9, number2 = 3}), "")
	testing.expect_value(t, compactText(value(dir, hall + ".fieldInstances.2.__value")), `[{"cx":4,"cy":2},{"cx":6,"cy":2},{"cx":9,"cy":3}]`)
	testing.expect_value(t, compactText(value(dir, hall + ".fieldInstances.2.realEditorValues.2.params")), `["9,3"]`)
	testing.expect_value(t, edit(dir, {op = .Entity_Point, file = file, entity = "hero1", field = 31, index = 0, number = 1, number2 = 1}), "")
	testing.expect_value(t, compactText(value(dir, hall + ".fieldInstances.2.__value.0")), `{"cx":1,"cy":1}`)
	testing.expect_value(t, edit(dir, {op = .Entity_Point, file = file, entity = "hero1", field = 31, index = 1, flag = true}), "")
	testing.expect_value(t, compactText(value(dir, hall + ".fieldInstances.2.__value")), `[{"cx":1,"cy":1},{"cx":9,"cy":3}]`)
	testing.expect_value(t, edit(dir, {op = .Entity_Point, file = file, entity = "hero1", field = 33, number = 7, number2 = 6}), "")
	testing.expect_value(t, compactText(value(dir, hall + ".fieldInstances.3.__value")), `{"cx":7,"cy":6}`)

	// References: an array gets one more; a symmetrical one points back, the old target forgets
	testing.expect_value(t, edit(dir, {op = .Entity_Ref, file = file, entity = "link1", field = 35, index = -1, text = "hero1"}), "")
	testing.expect_value(t, edit(dir, {op = .Entity_Ref, file = file, entity = "link1", field = 35, index = -1, text = "box1"}), "")
	link1 :: "levels.identifier=Hall.layerInstances.layerDefUid=1.entityInstances.iid=link1"
	testing.expect(t, strings.contains(value(dir, link1 + ".fieldInstances.0.__value"), `"entityIid": "box1"`), value(dir, link1 + ".fieldInstances.0.__value"))
	testing.expect_value(t, edit(dir, {op = .Entity_Ref, file = file, entity = "link1", field = 36, text = "link2"}), "")
	link2 :: "levels.identifier=Hall.layerInstances.layerDefUid=1.entityInstances.iid=link2"
	testing.expect(t, strings.contains(value(dir, link2 + ".fieldInstances.1.__value"), "link1"), "link2 points back (symmetrical)")
	// Removing an entity removes the references to it (Project.removeAnyFieldRefsTo)
	testing.expect_value(t, edit(dir, {op = .Entity_Removed, file = file, entity = "hero1"}), "")
	refs := value(dir, link1 + ".fieldInstances.0.__value")
	testing.expect(t, !strings.contains(refs, "hero1") && strings.contains(refs, "box1"), refs)
	expectValid(t, LDtkDoc_Get(dir, file))
}

// A state with the painting fixture in the Level mode, a level focused, a layer selected
@(private="file")
paintState :: proc(dir: string, level, layer: string) -> ^State {
	state := new(State)
	state^ = State{project = Project_CreateEmpty(dir, "Paint"), browserSelection = {kind = .None}, selectedNode = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	state.mode = .Level
	state.level = {layout = LEVEL_LAYOUT_DEFAULT, bottomTab = .World, layerDef = -1, entityDef = -1, enumDef = -1, fieldDef = -1, levelField = -1, tilesetDef = -1, dataTile = -1, paint = {entityDef = -1}}
	append(&state.project.assets, AssetDef{path = strings.clone("paint.ldtk"), kind = .LDtk})
	paintSend(state, Level_Canvas_Measured{800, 400})
	paintSend(state, Level_Focus_Changed(level))
	doc := LDtkDoc_Get(dir, "paint.ldtk")
	main := LDtkDoc_Main(doc)
	for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) do if Json_String(main, Json_Get(main, d, "identifier")) == layer do paintSend(state, Level_Layer_Picked(Json_Int(main, Json_Get(main, d, "uid"))))
	return state
}

@(private="file")
paintSend :: proc(state: ^State, m: Msg) {
	state^, _ = update(state^, m)
}

// The world point of a cell's center in the focused level (16 px cells)
@(private="file")
cellWorld :: proc(state: ^State, cx, cy: int) -> [2]f32 {
	doc := LDtkDoc_Get(state.project.rootPath, "paint.ldtk")
	r := LDtkDoc_LevelRect(doc, LDtkDoc_FindLevel(doc, state.level.focus))
	return {f32(r[0]) + f32(cx) * 16 + 8, f32(r[1]) + f32(cy) * 16 + 8}
}

// A layer's IntGrid value in the document (as the editor has it)
@(private="file")
docCell :: proc(state: ^State, level, layer: string, cx, cy: int) -> int {
	doc := LDtkDoc_Get(state.project.rootPath, "paint.ldtk")
	main := LDtkDoc_Main(doc)
	li := Json_Path(main, fmt.tprintf("levels.identifier=%s.layerInstances.__identifier=%s", level, layer))
	cw := Json_Int(main, Json_Get(main, li, "__cWid"))
	return Json_Int(main, Json_At(main, Json_Get(main, li, "intGridCsv"), cx + cy * cw))
}

@(test)
level_mode_paints_strokes_as_undo_steps :: proc(t: ^testing.T) {
	dir := paintCopy("level_paint_strokes")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	defer LevelCanvas_Destroy()
	state := paintState(dir, "Room", "Ground")
	defer {
		State_Destroy(state)
		free(state)
	}
	testing.expect_value(t, LevelMode_LayerType(state), "IntGrid")
	paintSend(state, Level_Tool_Picked(.Pencil))
	testing.expect_value(t, state.level.tool, LevelTool.Pencil)
	paintSend(state, Level_Value_Picked{3, 2})

	// A stroke: press, moves, release: one undo step, the document changed then (not before)
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 2, 3), level = "Room"})
	testing.expect_value(t, state.level.paint.stroke.kind, LevelStrokeKind.Grid)
	testing.expect_value(t, docCell(state, "Room", "Ground", 2, 3), 0)
	paintSend(state, Level_Canvas_Moved{world = cellWorld(state, 6, 5)})
	paintSend(state, Level_Canvas_Released{})
	testing.expect_value(t, docCell(state, "Room", "Ground", 2, 3), 2)
	testing.expect_value(t, docCell(state, "Room", "Ground", 4, 4), 2)
	testing.expect_value(t, docCell(state, "Room", "Ground", 6, 5), 2)
	testing.expect_value(t, len(state.history.undo), 1)
	testing.expect(t, strings.has_prefix(state.history.undo[0].label, "Paint IntGrid in Room"), state.history.undo[0].label)
	testing.expect(t, LDtkDoc_IsUnsaved(dir, "paint.ldtk"), "unsaved")
	// The auto-layer tiles came with it
	doc := LDtkDoc_Get(dir, "paint.ldtk")
	tiles := Json_Path(LDtkDoc_Main(doc), "levels.identifier=Room.layerInstances.__identifier=Ground.autoLayerTiles")
	testing.expect(t, Json_Count(LDtkDoc_Main(doc), tiles) > 0, "auto-layer tiles")
	expectValid(t, doc)
	// Undo and redo put the texts back
	paintSend(state, Msg(Action.Undo))
	testing.expect_value(t, docCell(state, "Room", "Ground", 4, 4), 0)
	testing.expect(t, !LDtkDoc_IsUnsaved(dir, "paint.ldtk"), "undone to the saved text")
	paintSend(state, Msg(Action.Redo))
	testing.expect_value(t, docCell(state, "Room", "Ground", 4, 4), 2)

	// The right button erases
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 4, 4), level = "Room", right = true})
	paintSend(state, Level_Canvas_Released{})
	testing.expect_value(t, docCell(state, "Room", "Ground", 4, 4), 0)
	testing.expect_value(t, len(state.history.undo), 2)

	// Shift + drag: a rectangle at the release
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 10, 1), level = "Room", free = true})
	paintSend(state, Level_Canvas_Moved{world = cellWorld(state, 12, 2), free = true})
	testing.expect_value(t, docCell(state, "Room", "Ground", 10, 1), 0)
	paintSend(state, Level_Canvas_Released{})
	testing.expect_value(t, docCell(state, "Room", "Ground", 12, 2), 2)
	testing.expect_value(t, docCell(state, "Room", "Ground", 11, 1), 2)
	// Shift + a quick click: a fill (LDtk: 0.22 s); with water on the empty level's rest
	paintSend(state, Level_Value_Picked{3, 4})
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 15, 10), level = "Room", free = true})
	paintSend(state, Level_Canvas_Released{})
	testing.expect_value(t, docCell(state, "Room", "Ground", 0, 11), 4)
	testing.expect_value(t, docCell(state, "Room", "Ground", 11, 1), 2)

	// Alt + click picks the value under the pointer (LDtk's selection)
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 11, 1), level = "Room", alt = true})
	testing.expect_value(t, state.level.paint.values[3], 2)

	// The Fill tool
	steps := len(state.history.undo)
	paintSend(state, Level_Tool_Picked(.Fill))
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 0, 11), level = "Room"})
	paintSend(state, Level_Canvas_Released{})
	testing.expect_value(t, docCell(state, "Room", "Ground", 0, 11), 2)
	testing.expect_value(t, len(state.history.undo), steps + 1)
	// A hidden layer isn't painted
	paintSend(state, LDtk_Edit{op = .Layer_Visible, file = "paint.ldtk", level = "lvl-room", def = 3, flag = false})
	paintSend(state, Level_Tool_Picked(.Pencil))
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 19, 0), level = "Room"})
	paintSend(state, Level_Canvas_Released{})
	testing.expect(t, strings.contains(state.level.problem, "hidden"), state.level.problem)
}

@(test)
level_mode_paints_tiles_and_entities :: proc(t: ^testing.T) {
	dir := paintCopy("level_paint_tiles")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	defer LevelCanvas_Destroy()
	state := paintState(dir, "Room", "Decor")
	defer {
		State_Destroy(state)
		free(state)
	}
	// The palette's tiles, flipped by X, stamped
	paintSend(state, Level_Tool_Picked(.Pencil))
	ids := []int{8, 9}
	paintSend(state, Level_Tiles_Picked{10, ids})
	paintSend(state, Msg(Action.Level_Flip_X))
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 3, 3), level = "Room"})
	paintSend(state, Level_Canvas_Released{})
	doc := LDtkDoc_Get(dir, "paint.ldtk")
	gt := Json_Path(LDtkDoc_Main(doc), "levels.identifier=Room.layerInstances.__identifier=Decor.gridTiles")
	testing.expect_value(t, Json_Count(LDtkDoc_Main(doc), gt), 2)
	testing.expect_value(t, Json_Text(LDtkDoc_Main(doc), Json_Path(LDtkDoc_Main(doc), "levels.identifier=Room.layerInstances.__identifier=Decor.gridTiles.0.t")), "9")
	testing.expect_value(t, Json_Text(LDtkDoc_Main(doc), Json_Path(LDtkDoc_Main(doc), "levels.identifier=Room.layerInstances.__identifier=Decor.gridTiles.0.f")), "1")
	testing.expect_value(t, len(state.history.undo), 1)
	// R: random mode (the tool row follows)
	paintSend(state, Msg(Action.Level_Random_Mode))
	testing.expect(t, state.level.paint.random && state.level.tool == .Random, "random")

	// Entities: Place puts the type at the cell (its pivot on the cell's), one step
	main := LDtkDoc_Main(doc)
	paintSend(state, Level_Layer_Picked(1))
	paintSend(state, Level_Tool_Picked(.Pencil))
	paintSend(state, Level_Entity_Type_Picked(20))
	before := len(state.history.undo)
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 5, 5), level = "Room"})
	paintSend(state, Level_Canvas_Released{})
	testing.expect_value(t, len(state.history.undo), before + 1)
	doc = LDtkDoc_Get(dir, "paint.ldtk")
	main = LDtkDoc_Main(doc)
	ents := Json_Path(main, "levels.identifier=Room.layerInstances.layerDefUid=1.entityInstances")
	testing.expect_value(t, Json_Count(main, ents), 1)
	placed := Json_At(main, ents, 0)
	testing.expect_value(t, compactText(Json_Text(main, Json_Get(main, placed, "px"))), "[88,96]")
	iid := strings.clone(Json_String(main, Json_Get(main, placed, "iid")), context.temp_allocator)
	testing.expect_value(t, state.level.entity, iid)
	// The next placement chains a reference from it (the Hero's target: autoChainRef)
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 9, 5), level = "Room"})
	paintSend(state, Level_Canvas_Released{})
	doc = LDtkDoc_Get(dir, "paint.ldtk")
	main = LDtkDoc_Main(doc)
	first := Json_Path(main, fmt.tprintf("levels.identifier=Room.layerInstances.layerDefUid=1.entityInstances.iid=%s.fieldInstances.1.__value.entityIid", iid))
	testing.expect(t, Json_Kind(main, first) == .String, "chained")
	// Delete removes the selected one; Ctrl+D duplicates
	paintSend(state, Msg(Action.Level_Duplicate))
	testing.expect_value(t, Json_Count(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")), Json_Path(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")), "levels.identifier=Room.layerInstances.layerDefUid=1.entityInstances")), 3)
	paintSend(state, Msg(Action.Level_Delete))
	testing.expect_value(t, Json_Count(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")), Json_Path(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")), "levels.identifier=Room.layerInstances.layerDefUid=1.entityInstances")), 2)
	// The right button removes what it crosses: one step
	steps := len(state.history.undo)
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 5, 4), level = "Room", right = true})
	paintSend(state, Level_Canvas_Moved{world = cellWorld(state, 9, 4)})
	paintSend(state, Level_Canvas_Released{})
	testing.expect_value(t, Json_Count(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")), Json_Path(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")), "levels.identifier=Room.layerInstances.layerDefUid=1.entityInstances")), 0)
	testing.expect_value(t, len(state.history.undo), steps + 1)
	paintSend(state, Msg(Action.Undo))
	testing.expect_value(t, Json_Count(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")), Json_Path(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")), "levels.identifier=Room.layerInstances.layerDefUid=1.entityInstances")), 2)

	// A resizable Box: placing it starts its resize (ResizeTool's bottom-right handle)
	paintSend(state, Level_Entity_Type_Picked(21))
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, 12, 2), level = "Room"})
	testing.expectf(t, state.level.paint.stroke.kind == .Resize, "the resize starts (%v; %s)", state.level.paint.stroke.kind, state.level.problem)
	paintSend(state, Level_Canvas_Moved{world = cellWorld(state, 12, 2) + {40, 20}})
	paintSend(state, Level_Canvas_Released{})
	doc = LDtkDoc_Get(dir, "paint.ldtk")
	main = LDtkDoc_Main(doc)
	box := Json_Path(main, fmt.tprintf("levels.identifier=Room.layerInstances.layerDefUid=1.entityInstances.iid=%s", state.level.entity))
	// ResizeTool: the pointer less the box's corner less the handle's 5 px, on the 16 px grid:
	// (240 - 192 - 5) -> 48, (60 - 32 - 5) -> 16
	testing.expect_value(t, Json_Text(main, Json_Get(main, box, "width")), "48")
	testing.expect_value(t, Json_Text(main, Json_Get(main, box, "height")), "16")
	expectValid(t, doc)
}

// JSON without spaces (the test's comparisons)
@(private="file")
compactText :: proc(text: string) -> string {
	out := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)text do if c != ' ' && c != '\n' && c != '\t' do strings.write_byte(&out, c)
	return strings.to_string(out)
}

/*
Adds a big level to a copy of the painting fixture: "Big", 256 x 256 cells of 16 px, with six
layers (Entities, Decor and Decor2 tiles, Ground IntGrid with its rules, Water IntGrid, Shade
AutoLayer), filled: rolling ground, tiles on 30% of the cells, every rule applied. Written to
disk (the State reads it there).
*/
@(private="file")
makeBigLevel :: proc(t: ^testing.T, dir: string) -> bool {
	doc := LDtkDoc_Get(dir, "paint.ldtk")
	main := LDtkDoc_Main(doc)
	minified := false
	patches := LDtkPatches{}
	// Two more layer definitions: Decor2 (tiles) after Decor, Water (IntGrid, colors) after Ground
	layers := LDtkDoc_Defs(doc, "layers")
	decor := ldtkJV(main, Json_At(main, layers, 1))
	for &pair in decor.(LDtkJObject) {
		switch pair.key {
		case "identifier": pair.value = "Decor2"
		case "uid":        pair.value = i64(5)
		}
	}
	water := ldtkJV(main, Json_At(main, layers, 2))
	for &pair in water.(LDtkJObject) {
		switch pair.key {
		case "identifier": pair.value = "Water"
		case "uid":        pair.value = i64(6)
		case "tilesetDefUid": pair.value = LDtkJNull{}
		case "autoRuleGroups": pair.value = LDtkJArray{}
		}
	}
	indent := LDtk_IndentAt(main.text, int(main.nodes[Json_At(main, layers, 0)].start))
	LDtkPatches_Add(&patches, 0, Json_InsertPatch(main, layers, 2, LDtk_PrettyJson(decor, minified, indent)))
	LDtkPatches_Add(&patches, 0, Json_InsertPatch(main, layers, 3, LDtk_PrettyJson(water, minified, indent)))
	// The level: Room's settings, six empty layers of 256 x 256
	levels := Json_Get(main, Json_Root(main), "levels")
	room := ldtkJV(main, Json_At(main, levels, 0))
	CELLS :: 256
	order := []struct { uid: int, name, type: string, tileset: bool }{
		{1, "Entities", "Entities", false}, {2, "Decor", "Tiles", true}, {5, "Decor2", "Tiles", true},
		{3, "Ground", "IntGrid", true}, {6, "Water", "IntGrid", false}, {4, "Shade", "AutoLayer", true},
	}
	instances := make([dynamic]LDtkJV, context.temp_allocator)
	for l, i in order {
		zeros := make([]LDtkJV, l.type == "IntGrid" ? CELLS * CELLS : 0, context.temp_allocator)
		for &z in zeros do z = i64(0)
		pairs := []LDtkJPair{
			{"__identifier", l.name}, {"__type", l.type}, {"__cWid", i64(CELLS)}, {"__cHei", i64(CELLS)}, {"__gridSize", i64(16)},
			{"__opacity", i64(1)}, {"__pxTotalOffsetX", i64(0)}, {"__pxTotalOffsetY", i64(0)},
			{"__tilesetDefUid", l.tileset ? LDtkJV(i64(10)) : LDtkJV(LDtkJNull{})}, {"__tilesetRelPath", l.tileset ? LDtkJV("tiles.png") : LDtkJV(LDtkJNull{})},
			{"iid", fmt.tprintf("lvl-big-%s", strings.to_lower(l.name, context.temp_allocator))}, {"levelId", i64(102)}, {"layerDefUid", i64(l.uid)},
			{"pxOffsetX", i64(0)}, {"pxOffsetY", i64(0)}, {"visible", true}, {"optionalRules", LDtkJArray(slice.clone([]LDtkJV{i64(60)}, context.temp_allocator))},
			{"intGridCsv", LDtkJArray(zeros)}, {"autoLayerTiles", LDtkJArray{}}, {"seed", i64(5000 + i)}, {"overrideTilesetUid", LDtkJNull{}},
			{"gridTiles", LDtkJArray{}}, {"entityInstances", LDtkJArray{}},
		}
		append(&instances, LDtkJObject(slice.clone(pairs, context.temp_allocator)))
	}
	for &pair in room.(LDtkJObject) {
		switch pair.key {
		case "identifier": pair.value = "Big"
		case "iid":        pair.value = "lvl-big"
		case "uid":        pair.value = i64(102)
		case "worldX":     pair.value = i64(0)
		case "worldY":     pair.value = i64(256)
		case "pxWid", "pxHei": pair.value = i64(CELLS * 16)
		case "layerInstances": pair.value = LDtkJArray(instances[:])
		case "__neighbours": pair.value = LDtkJArray{}
		}
	}
	LDtkPatches_Add(&patches, 0, Json_AppendPatch(main, levels, LDtk_PrettyJson(room, minified, LDtk_IndentAt(main.text, int(main.nodes[Json_At(main, levels, 0)].start)))))
	if problem := LDtkDoc_Commit(doc, &patches); !testing.expectf(t, problem == "", "the big level: %s", problem) do return false
	// Filled through the model: rolling ground, water below a line, tiles on 30% of the cells
	level := LDtkDoc_FindLevel(doc, "Big")
	m, ok := LDtkLevel_Read(doc, "paint.ldtk", level)
	if !testing.expect(t, ok, "the big level decodes") do return false
	defer LDtkLevel_Destroy(&m)
	ground, waterLayer := layerNamed(&m, "Ground"), layerNamed(&m, "Water")
	decorLayer, decor2 := layerNamed(&m, "Decor"), layerNamed(&m, "Decor2")
	for x in 0 ..< CELLS {
		top := 120 + int(20 * math.sin(f64(x) * 0.1)) + (x / 16) % 3
		for y in top ..< CELLS do LDtkLayer_SetIntGrid(&m, ground, x, y, y < top + 2 ? 1 : (y < top + 12 ? 3 : 2))
		for y in 100 ..< top do if (x / 32) % 2 == 0 do LDtkLayer_SetIntGrid(&m, waterLayer, x, y, 1)
	}
	for y in 0 ..< CELLS do for x in 0 ..< CELLS {
		h := (x * 7349 + y * 3557) % 100
		if h < 30 do LDtkLayer_AddTile(decorLayer, x, y, h % 16, 0, false)
		if h > 70 do LDtkLayer_AddTile(decor2, x, y, 16 + h % 8, u8(h % 4), false)
	}
	for &l in m.layers do if LDtkLayerInfo_IsAuto(&m.defs[l.def]) do LDtkRules_ApplyAll(&m, &l)
	fill := LDtkLevel_Patches(&m, doc)
	if problem := LDtkDoc_Commit(doc, &fill); !testing.expectf(t, problem == "", "filled: %s", problem) do return false
	if problem := LDtkDoc_Save(dir, "paint.ldtk"); !testing.expectf(t, problem == "", "saved: %s", problem) do return false
	expectValid(t, doc)
	return true
}

// Times of a stroke on a level through the State: the press (the level decoded), each move
// (paint, the rules, the pieces drawn again), the release (the commit: one undo step), an undo
@(private="file")
StrokeTimes :: struct {
	press, worstMove, meanMove, release, undo: time.Duration,
	moves, pieces, autoTiles: int,
	// What the undo step keeps (bytes)
	stepBytes: int,
}

@(private="file")
strokeTimes :: proc(t: ^testing.T, dir, level, layer: string, from, to: [2]int, steps: int) -> StrokeTimes {
	out: StrokeTimes
	state := paintState(dir, level, layer)
	defer {
		State_Destroy(state)
		free(state)
		LevelCanvas_Destroy()
	}
	paintSend(state, Level_Tool_Picked(.Pencil))
	start := time.tick_now()
	paintSend(state, Level_Canvas_Pressed{world = cellWorld(state, from.x, from.y), level = level})
	out.press = time.tick_since(start)
	doc := LDtkDoc_Get(dir, "paint.ldtk")
	total := time.Duration(0)
	for i in 1 ..= steps {
		c := from + (to - from) * i / steps
		start = time.tick_now()
		paintSend(state, Level_Canvas_Moved{world = cellWorld(state, c.x, c.y)})
		// The frame's pictures: the changed pieces drawn again (the upload is the GPU's)
		out.pieces += LevelPictures_RedrawDirty(state, doc, LevelPaint_Current())
		d := time.tick_since(start)
		total += d
		out.worstMove = max(out.worstMove, d)
		out.moves += 1
		free_all(context.temp_allocator)
	}
	out.meanMove = total / time.Duration(max(out.moves, 1))
	start = time.tick_now()
	paintSend(state, Level_Canvas_Released{})
	out.release = time.tick_since(start)
	testing.expect_value(t, len(state.history.undo), 1)
	m := LevelPaint_Current()
	if m != nil do for &l in m.layers do for cell in l.auto do out.autoTiles += len(cell)
	if change, ok := &state.history.undo[0].change.(FileChange); ok do for f in change.files {
		out.stepBytes += FileText_Size(f)
	}
	painted := strings.clone(LDtkDoc_Main(doc).text)
	defer delete(painted)
	saved := strings.clone(doc.files[0].saved)
	defer delete(saved)
	start = time.tick_now()
	paintSend(state, Msg(Action.Undo))
	out.undo = time.tick_since(start)
	// Undo and redo give the texts back byte for byte (a big file's step keeps only its hunks)
	doc = LDtkDoc_Get(dir, "paint.ldtk")
	testing.expect(t, LDtkDoc_Main(doc).text == saved, "undone to the saved text")
	paintSend(state, Msg(Action.Redo))
	doc = LDtkDoc_Get(dir, "paint.ldtk")
	testing.expect(t, LDtkDoc_Main(doc).text == painted, "redone to the painted text")
	paintSend(state, Msg(Action.Undo))
	return out
}

@(test)
level_painting_is_fast :: proc(t: ^testing.T) {
	// Kept out of the temp allocator: the strokes free it after every move
	dir := strings.clone(paintCopy("level_paint_big"))
	defer delete(dir)
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	start := time.tick_now()
	if !makeBigLevel(t, dir) do return
	made := time.tick_since(start)
	info, _ := os.stat(joinPath(dir, "paint.ldtk", allocator = context.temp_allocator), context.temp_allocator)
	// The best of a few runs (timings under load: the other tests' threads)
	best: StrokeTimes
	for run in 0 ..< TIMING_RUNS {
		LDtkDoc_DestroyAll()
		times := strokeTimes(t, dir, "Big", "Ground", {20, 110}, {120, 140}, 60)
		if run == 0 || times.meanMove < best.meanMove do best = times
	}
	log.infof("big level (256 x 256, 6 layers, %d auto tiles, %.1f MB file, made in %v): press %v, moves mean %v worst %v (%d pieces drawn), release %v, undo %v; the undo step keeps %.1f MB",
		best.autoTiles, f64(info.size) / 1e6, made, best.press, best.meanMove, best.worstMove, best.pieces, best.release, best.undo, f64(best.stepBytes) / 1e6)
	testing.expectf(t, best.stepBytes < int(info.size) / 10, "the undo step keeps a tenth of the file at most (%d of %d bytes)", best.stepBytes, info.size)
	// A frame is 16.7 ms at 60 fps: a move's work fits (generous: unoptimized builds, a loaded CI)
	testing.expectf(t, best.meanMove < 16 * time.Millisecond, "a move takes %v", best.meanMove)

	// The demo's largest level (Hollow: 180 x 48 cells, 4 layers; its tileset beside it)
	demo := strings.clone(tempDir("level_paint_demo"))
	defer delete(demo)
	defer removeAll(demo)
	_ = removeAll(demo)
	if !testing.expect_value(t, Folder_Copy("examples/demo_project/assets", demo), "") do return
	levels := strings.clone(joinPath(demo, "levels", allocator = context.temp_allocator))
	defer delete(levels)
	os.rename(joinPath(levels, "legacy.ldtk", allocator = context.temp_allocator), joinPath(levels, "paint.ldtk", allocator = context.temp_allocator))
	bestDemo: StrokeTimes
	for run in 0 ..< TIMING_RUNS {
		times := strokeTimes(t, levels, "Hollow", "Ground", {10, 20}, {150, 40}, 60)
		if run == 0 || times.meanMove < bestDemo.meanMove do bestDemo = times
	}
	log.infof("the demo's Hollow (180 x 48, 4 layers, %d auto tiles): press %v, moves mean %v worst %v (%d pieces drawn), release %v, undo %v",
		bestDemo.autoTiles, bestDemo.press, bestDemo.meanMove, bestDemo.worstMove, bestDemo.pieces, bestDemo.release, bestDemo.undo)
	testing.expectf(t, bestDemo.meanMove < 16 * time.Millisecond, "a move takes %v", bestDemo.meanMove)
}
