package crossfire_editor

import "core:math/rand"

/*
LDtk's painting tools on a decoded level (ldtk_level_model.odin), ported from its source
(`ldtk/src/electron.renderer`: Tool.hx, tool/lt/IntGridTool.hx, tool/lt/TileTool.hx,
dn.geom.Bresenham). The Level mode's strokes (level_paint.odin) call them; unit tests compare what
they do with what LDtk does.

- **Strokes** follow the pointer cell to cell along a thin Bresenham line from the last cell
  (`ldtkLine`: LDtk's `iterateThinLine`), so a fast drag leaves no gaps.
- **Add or remove:** the left button adds (an IntGrid value, the picked tiles), the right one
  removes (LDtk's `curMode`).
- **Rectangles** (Shift + drag, or the Rectangle tool) paint every cell between the press and the
  release; **fills** (Shift + a quick click, or the Fill tool) flood the cells like the one clicked
  (4-connected, `_floodFillImpl`'s order, which visits the first cell twice as LDtk does).
- **Tiles:** a stamp paints the picked tiles in the shape they have in the tileset (flipped as the
  brush is: X mirrors it), a random brush one of them per cell; with tile stacking (LDtk's
  default, Shift+T), a tile that isn't opaque goes over what's in the cell instead of replacing
  it, and a stroke paints a cell once (`LDtkPaintStroke.painted`). A tileset whose tiles are
  bigger than the layer's grid paints every `tileGridSize / gridSize` cells.
*/

// What a press does (LDtk's ToolEditMode): the left button adds, the right one removes
LDtkPaintMode :: enum u8 {
	Add,
	Remove,
}

// A tile brush: the picked tiles (tile ids), stamp or random, flips, stacking
LDtkTileBrush :: struct {
	ids: []int,
	random: bool,
	// Bit 0: flip X, bit 1: flip Y
	flips: u8,
	// LDtk's tile stacking setting (on by default)
	stacking: bool,
}

// One stroke's memory: the cells painted (tile stacking paints a cell once a stroke), its dice
LDtkPaintStroke :: struct {
	painted: map[int]bool,
	rng: rand.Default_Random_State,
}

// Starts a stroke's memory (free it with `LDtkPaintStroke_Destroy`)
LDtkPaintStroke_Make :: proc(seed: u64) -> LDtkPaintStroke {
	return {rng = rand.create(seed)}
}

// Frees a stroke's memory
LDtkPaintStroke_Destroy :: proc(s: ^LDtkPaintStroke) {
	delete(s.painted)
	s.painted = nil
}

// A random index below n (LDtk's Std.random), from the stroke's dice
@(private="file")
roll :: proc(s: ^LDtkPaintStroke, n: int) -> int {
	if n <= 1 do return 0
	return rand.int_max(n, rand.default_random_generator(&s.rng))
}

/*
The cells of a thin line between two cells, as dn.geom.Bresenham.iterateThinLine walks them
(diagonal steps allowed; the start cell first unless the line was flipped to run left to right).

Returns:
- The cells (temp allocated)
*/
ldtkLine :: proc(from, to: [2]int) -> [][2]int {
	x0, y0, x1, y1 := from.x, from.y, to.x, to.y
	swapXY := abs(y1 - y0) > abs(x1 - x0)
	if swapXY {
		x0, y0 = y0, x0
		x1, y1 = y1, x1
	}
	if x0 > x1 {
		x0, x1 = x1, x0
		y0, y1 = y1, y0
	}
	deltax := x1 - x0
	deltay := abs(y1 - y0)
	error := deltax / 2
	y := y0
	ystep := y0 < y1 ? 1 : -1
	out := make([dynamic][2]int, 0, deltax + 1, context.temp_allocator)
	for x in x0 ..= x1 {
		append(&out, swapXY ? [2]int{y, x} : [2]int{x, y})
		error -= deltay
		if error < 0 {
			y += ystep
			error += deltax
		}
	}
	return out[:]
}

/*
LDtk's flood fill (Tool._floodFillImpl): from a cell, the 4-connected cells `blocking` doesn't
stop, in the order LDtk visits them (a stack; the first cell is visited twice, as there).

Returns:
- The cells in visit order (temp allocated), false when the first cell is blocking
*/
ldtkFloodFill :: proc(l: ^LDtkLayerData, start: [2]int, blocking: proc(l: ^LDtkLayerData, cx, cy: int, data: rawptr) -> bool, data: rawptr) -> ([][2]int, bool) {
	if blocking(l, start.x, start.y, data) do return nil, false
	pending := make([dynamic][2]int, context.temp_allocator)
	append(&pending, start)
	done := make(map[int]bool, 256, context.temp_allocator)
	out := make([dynamic][2]int, context.temp_allocator)
	check :: proc(l: ^LDtkLayerData, pending: ^[dynamic][2]int, done: ^map[int]bool, cx, cy: int, blocking: proc(l: ^LDtkLayerData, cx, cy: int, data: rawptr) -> bool, data: rawptr) {
		id := cx + cy * l.cWid
		if LDtkLayer_Valid(l, cx, cy) && id not_in done^ && !blocking(l, cx, cy, data) {
			done[id] = true
			append(pending, [2]int{cx, cy})
		}
	}
	for len(pending) > 0 {
		cur := pop(&pending)
		check(l, &pending, &done, cur.x - 1, cur.y, blocking, data)
		check(l, &pending, &done, cur.x + 1, cur.y, blocking, data)
		check(l, &pending, &done, cur.x, cur.y - 1, blocking, data)
		check(l, &pending, &done, cur.x, cur.y + 1, blocking, data)
		append(&out, cur)
	}
	return out[:], true
}

// The bounds of a list of cells (left, top, right, bottom)
ldtkCellsBounds :: proc(cells: [][2]int) -> [4]int {
	if len(cells) == 0 do return {}
	b := [4]int{cells[0].x, cells[0].y, cells[0].x, cells[0].y}
	for c in cells do b = {min(b[0], c.x), min(b[1], c.y), max(b[2], c.x), max(b[3], c.y)}
	return b
}

// ---------------------------------------------------------------------------------------------
// IntGrid (tool/lt/IntGridTool.hx)

// One cell (IntGridTool.useAtInterpolatedGrid); whether it changed
LDtkPaint_IntGridCell :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, cx, cy, value: int, mode: LDtkPaintMode) -> bool {
	switch mode {
	case .Add:
		// LDtk's selected value is -1 without values: setIntGrid(-1) removes
		return LDtkLayer_SetIntGrid(m, l, cx, cy, value)
	case .Remove:
		return LDtkLayer_SetIntGrid(m, l, cx, cy, 0)
	}
	return false
}

// A stroke's segment from the last cell to the pointer's (Tool.useAt); whether anything changed
LDtkPaint_IntGridLine :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, from, to: [2]int, value: int, mode: LDtkPaintMode) -> bool {
	any := false
	for c in ldtkLine(from, to) do any = LDtkPaint_IntGridCell(m, l, c.x, c.y, value, mode) || any
	return any
}

// A rectangle of cells (IntGridTool.useOnRectangle)
LDtkPaint_IntGridRect :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, left, top, right, bottom, value: int, mode: LDtkPaintMode) -> bool {
	any := false
	for cx in left ..= right do for cy in top ..= bottom do any = LDtkPaint_IntGridCell(m, l, cx, cy, value, mode) || any
	return any
}

/*
A flood fill (IntGridTool.useFloodfillAt): the cells holding the clicked one's value, set to the
brush's value (or emptied). Filling with the value already there does nothing.

Returns:
- Whether LDtk counts it as a change (it does whenever the clicked cell isn't blocked)
*/
LDtkPaint_IntGridFill :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, cx, cy, value: int, mode: LDtkPaintMode) -> bool {
	initial := LDtkLayer_IntGrid(l, cx, cy)
	if initial == value && mode == .Add do return false
	Data :: struct {
		initial: int,
	}
	data := Data{initial}
	cells, ok := ldtkFloodFill(l, {cx, cy}, proc(l: ^LDtkLayerData, cx, cy: int, data: rawptr) -> bool {
		return LDtkLayer_IntGrid(l, cx, cy) != (^Data)(data).initial
	}, &data)
	if !ok do return false
	for c in cells do LDtkPaint_IntGridCell(m, l, c.x, c.y, value, mode)
	return true
}

// ---------------------------------------------------------------------------------------------
// Tiles (tool/lt/TileTool.hx)

// How many layer cells a tileset tile covers (TileTool's gridDiffScale)
@(private="file")
gridScale :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, td: ^LDtkTilesetInfo) -> int {
	return max(1, int(f64(td.tileGridSize) / f64(m.defs[l.def].gridSize) + 0.5))
}

// The picked tiles' bounds in the tileset (left, top, right, bottom)
LDtkTileBrush_Bounds :: proc(td: ^LDtkTilesetInfo, ids: []int) -> [4]int {
	b := [4]int{max(int), max(int), min(int), min(int)}
	for id in ids {
		c := LDtkTileset_TileCell(td, id)
		b = {min(b[0], c.x), min(b[1], c.y), max(b[2], c.x), max(b[3], c.y)}
	}
	return b
}

// Whether a tile goes over what's in a cell (stacking, for tiles that aren't opaque)
@(private="file")
stacks :: proc(td: ^LDtkTilesetInfo, brush: LDtkTileBrush, tile: int) -> bool {
	return brush.stacking && !LDtkTileset_Opaque(td, tile)
}

/*
Paints the brush at a cell (TileTool.drawSelectionAt): a random one of its tiles, or the whole
stamp from that cell (flipped: mirrored).

Returns:
- Whether anything changed
*/
LDtkPaint_TilesAt :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, cx, cy: int, brush: LDtkTileBrush, stroke: ^LDtkPaintStroke) -> bool {
	td := LDtkLevel_LayerTileset(m, l)
	if td == nil || len(brush.ids) == 0 do return false
	if brush.random {
		tile := brush.ids[roll(stroke, len(brush.ids))]
		if !LDtkLayer_Valid(l, cx, cy) || (cx + cy * l.cWid) in stroke.painted do return false
		LDtkLayer_AddTile(l, cx, cy, tile, brush.flips, stacks(td, brush, tile))
		if brush.stacking do stroke.painted[cx + cy * l.cWid] = true
		return true
	}
	// The stamp (LDtk's bounds start at 0 on the right and bottom, as there)
	left, top, right, bottom := max(int), max(int), 0, 0
	for id in brush.ids {
		c := LDtkTileset_TileCell(td, id)
		left, right = min(left, c.x), max(right, c.x)
		top, bottom = min(top, c.y), max(bottom, c.y)
	}
	scale := gridScale(m, l, td)
	flipX, flipY := brush.flips & 1 != 0, brush.flips & 2 != 0
	any := false
	for id in brush.ids {
		c := LDtkTileset_TileCell(td, id)
		tcx := cx + (flipX ? right - c.x : c.x - left) * scale
		tcy := cy + (flipY ? bottom - c.y : c.y - top) * scale
		if !LDtkLayer_Valid(l, tcx, tcy) || (tcx + tcy * l.cWid) in stroke.painted do continue
		LDtkLayer_AddTile(l, tcx, tcy, id, brush.flips, stacks(td, brush, id))
		if brush.stacking do stroke.painted[tcx + tcy * l.cWid] = true
		any = true
	}
	return any
}

/*
Removes at a cell (TileTool.removeSelectedTileAt): with one tile or a random brush, the cell's top
tile (stacking) or all its tiles; with a stamp, every cell the stamp covers.
*/
LDtkPaint_TilesRemoveAt :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, cx, cy: int, brush: LDtkTileBrush, stroke: ^LDtkPaintStroke) -> bool {
	td := LDtkLevel_LayerTileset(m, l)
	if brush.random || len(brush.ids) <= 1 || td == nil {
		if (cx + cy * l.cWid) in stroke.painted && LDtkLayer_Valid(l, cx, cy) do return false
		if brush.stacking {
			if LDtkLayer_RemoveTopTile(l, cx, cy) {
				stroke.painted[cx + cy * l.cWid] = true
				return true
			}
			return false
		}
		return LDtkLayer_RemoveTiles(l, cx, cy)
	}
	left, top := max(int), max(int)
	for id in brush.ids {
		c := LDtkTileset_TileCell(td, id)
		left, top = min(left, c.x), min(top, c.y)
	}
	scale := gridScale(m, l, td)
	any := false
	for id in brush.ids {
		c := LDtkTileset_TileCell(td, id)
		tcx, tcy := cx + (c.x - left) * scale, cy + (c.y - top) * scale
		if LDtkLayer_Valid(l, tcx, tcy) && (tcx + tcy * l.cWid) in stroke.painted do continue
		if LDtkLayer_RemoveTiles(l, tcx, tcy) do any = true
	}
	return any
}

// A stroke's segment of tiles (Tool.useAt with TileTool.useAtInterpolatedGrid)
LDtkPaint_TilesLine :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, from, to: [2]int, brush: LDtkTileBrush, mode: LDtkPaintMode, stroke: ^LDtkPaintStroke) -> bool {
	any := false
	for c in ldtkLine(from, to) {
		switch mode {
		case .Add:    any = LDtkPaint_TilesAt(m, l, c.x, c.y, brush, stroke) || any
		case .Remove: any = LDtkPaint_TilesRemoveAt(m, l, c.x, c.y, brush, stroke) || any
		}
	}
	return any
}

/*
The stamp repeated over a rectangle (TileTool.drawSelectionInRectangle), only on the cells of
`mask` when there's one (a fill's cells): each cell takes the stamp's tile at its place in the
repeat; a tile not picked (a gap in the selection) leaves the cell.
*/
LDtkPaint_StampRect :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, cx, cy, wid, hei: int, brush: LDtkTileBrush, mask: map[int]bool = nil) -> bool {
	td := LDtkLevel_LayerTileset(m, l)
	if td == nil || len(brush.ids) == 0 do return false
	selected := make(map[int]bool, len(brush.ids), context.temp_allocator)
	for id in brush.ids do selected[id] = true
	b := LDtkTileBrush_Bounds(td, brush.ids)
	selWid, selHei := b[2] - b[0] + 1, b[3] - b[1] + 1
	scale := gridScale(m, l, td)
	any := false
	for dx in 0 ..< wid do for dy in 0 ..< hei {
		if dx % scale != 0 || dy % scale != 0 do continue
		x, y := cx + dx, cy + dy
		tile := LDtkTileset_TileId(td, b[0] + (dx / scale) % selWid, b[1] + (dy / scale) % selHei)
		if mask != nil && (x + y * l.cWid) not_in mask do continue
		if LDtkLayer_Valid(l, x, y) && tile in selected {
			LDtkLayer_AddTile(l, x, y, tile, brush.flips, stacks(td, brush, tile))
			any = true
		}
	}
	return any
}

/*
A rectangle of tiles (TileTool.useOnRectangle): the stamp repeated over it, a random tile per
cell, or (removing) every cell's top tile (stacking) or all its tiles.
*/
LDtkPaint_TilesRect :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, left, top, right, bottom: int, brush: LDtkTileBrush, mode: LDtkPaintMode, stroke: ^LDtkPaintStroke) -> bool {
	if mode == .Add && !brush.random do return LDtkPaint_StampRect(m, l, left, top, right - left + 1, bottom - top + 1, brush)
	any := false
	for cx in left ..= right do for cy in top ..= bottom {
		switch mode {
		case .Add:
			if LDtkPaint_TilesAt(m, l, cx, cy, brush, stroke) do any = true
		case .Remove:
			if brush.stacking {
				if LDtkLayer_RemoveTopTile(l, cx, cy) do any = true
			} else if LDtkLayer_RemoveTiles(l, cx, cy) {
				any = true
			}
		}
	}
	return any
}

/*
A flood fill of tiles (TileTool.useFloodfillAt): the cells with the clicked cell's top tile
anywhere in their stack (or, from an empty cell, the empty cells) get a random tile each, or the
stamp repeated over the filled area; removing empties them.
*/
LDtkPaint_TilesFill :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, cx, cy: int, brush: LDtkTileBrush, mode: LDtkPaintMode, stroke: ^LDtkPaintStroke) -> bool {
	td := LDtkLevel_LayerTileset(m, l)
	Data :: struct {
		initial: int,
		empty: bool,
	}
	data := Data{-1, true}
	if top, ok := LDtkLayer_TopTile(l, cx, cy); ok do data = {int(top.tile), false}
	cells, ok := ldtkFloodFill(l, {cx, cy}, proc(l: ^LDtkLayerData, cx, cy: int, data: rawptr) -> bool {
		d := (^Data)(data)
		if d.empty do return LDtkLayer_HasTile(l, cx, cy)
		return !LDtkLayer_HasSpecificTile(l, cx, cy, d.initial)
	}, &data)
	if !ok do return false
	for c in cells {
		switch mode {
		case .Add:
			if brush.random && td != nil && len(brush.ids) > 0 {
				tile := brush.ids[roll(stroke, len(brush.ids))]
				LDtkLayer_AddTile(l, c.x, c.y, tile, brush.flips, stacks(td, brush, tile))
			}
		case .Remove:
			LDtkLayer_RemoveTiles(l, c.x, c.y)
		}
	}
	if !brush.random && mode == .Add {
		mask := make(map[int]bool, len(cells), context.temp_allocator)
		for c in cells do mask[c.x + c.y * l.cWid] = true
		b := ldtkCellsBounds(cells)
		LDtkPaint_StampRect(m, l, b[0], b[1], b[2] - b[0] + 1, b[3] - b[1] + 1, brush, mask)
	}
	return true
}
