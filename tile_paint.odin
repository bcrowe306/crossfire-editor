package crossfire_editor

import "core:fmt"
import "core:strings"
import e "engine:."

/*
Painting tilemaps in the editor (its panel is view_tiles.odin, the bottom panel's Tiles tab; the
engine's tilemap.odin builds what's painted).

- **What's painted** is the TileMap node's `painted` layers (`e.TileLayerData`, the scene file's
  `<tiles>`): the first stroke on one of the Aseprite file's tilemap layers copies its tiles there
  (`ensurePainted`), so the scene's layer replaces the file's from then on (Use the File's Tiles
  goes back); a new layer is the scene's own, on one of the file's tilesets. The Aseprite file is
  never written.
- **Tools** (`TilePaintTool`): Paint the brush tile, Erase, Rectangle (from where the stroke
  started to where it ends), Fill (the connected cells of the same tile), Pick (the brush takes
  the cell's tile), Terrain (autotiling: the engine's `e.TileGrid_PaintTerrain`). The right mouse
  button erases with every tool (a terrain stroke: erases the terrain). The brush tile carries
  flips (`e.ASEPRITE_TILE_FLIP_*`): Flip X, Flip Y, Rotate.
- **Grids grow** to take a cell painted outside them (`growTo`), left and up too.
- **Undo:** a stroke (press to release) is one `.Node` step (History_Classify: `Tile_Brush`, keyed
  by its gesture).
- **The viewport** (view_viewport.odin) sends `Tile_Brush` instead of selecting or moving while the
  Tiles tab shows and a TileMap is selected (`TilePaint_Node`); it outlines the cell under the
  mouse and a rectangle being dragged.
*/

// What a tile stroke does
TilePaintTool :: enum {
	Paint,
	Erase,
	Rectangle,
	Fill,
	Pick,
	Terrain,
}

// The Tiles panel's state (part of State)
TilePainter :: struct {
	tool: TilePaintTool,
	// The brush: a tile index with flip bits
	tile: u32,
	// The layer painted (its name, owned; "": the TileMap's first)
	layer: string,
	// The terrain the Terrain tool paints (owned)
	terrain: string,
	// A new layer's tileset (an index in the file's tilesets)
	tileset: int,
	// A stroke is under way, erasing (the right button); the cell it started at (Rectangle)
	stroking, erasing: bool,
	start: [2]int,
	// The cell under the mouse (the viewport's outline), and whether there is one
	hover: [2]int,
	hovering: bool,
}

// A stroke's step: the mouse pressed, moved or released over the viewport (a world point)
Tile_Brush :: struct {
	world: [2]f32,
	phase: TileBrushPhase,
	erase: bool,
}

TileBrushPhase :: enum {
	Begin,
	Move,
	End,
	// The mouse moved with no button down: only the outline follows
	Hover,
}

// The Tiles panel's choices
Tile_Tool_Chosen :: distinct TilePaintTool
Tile_Brush_Chosen :: distinct u32
Tile_Layer_Chosen :: distinct string
Tile_Terrain_Chosen :: distinct string
Tile_Tileset_Chosen :: distinct int
// Flip X (0), flip Y (1) or rotate (2) the brush
Tile_Brush_Turned :: distinct int
// A new layer of the scene's own, on the chosen tileset
Tile_Layer_Added :: struct {}
// The layer goes back to the Aseprite file's tiles (its painted copy goes)
Tile_Layer_Reverted :: struct {}

/*
The selected TileMap while tiles can be painted: the Tiles tab shows (the bottom panel open) and
the node has a file that reads.

Returns:
- The node and its file, or nil
*/
TilePaint_Node :: proc(s: ^State) -> (node: ^NodeDef, ase: ^e.Aseprite) {
	if !s.layout.bottomOpen || s.bottomTab != .Tiles do return nil, nil
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) do return nil, nil
	node = &scene.nodes[s.selectedNode]
	if node.kind != .TileMap || node.tilemap.file == "" do return nil, nil
	ase = AsepriteEdit_File(s.project.rootPath, node.tilemap.file)
	if ase == nil do return nil, nil
	return node, ase
}

/*
The layers a TileMap can paint: the file's tilemap layers, then the scene's own.

Returns:
- Their names (temp allocated)
*/
TilePaint_Layers :: proc(node: ^NodeDef, ase: ^e.Aseprite) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for layer in ase.layers do if layer.type == .Tilemap do append(&names, layer.name)
	for p in node.tilemap.painted {
		known := false
		for n in names do if n == p.layer do known = true
		if !known do append(&names, p.layer)
	}
	return names[:]
}

// The layer painted: the panel's choice when the TileMap has it, else its first
TilePaint_Layer :: proc(s: ^State, node: ^NodeDef, ase: ^e.Aseprite) -> string {
	layers := TilePaint_Layers(node, ase)
	for name in layers do if name == s.tilePainter.layer do return name
	return len(layers) > 0 ? layers[0] : ""
}

/*
The tileset a layer paints with: a file layer's own, a scene layer's choice.

Returns:
- The tileset (in the file), its index, or nil
*/
TilePaint_Tileset :: proc(node: ^NodeDef, ase: ^e.Aseprite, layer: string) -> (^e.AsepriteTileset, int) {
	if i := e.Aseprite_FindLayer(ase, layer); i >= 0 && ase.layers[i].type == .Tilemap {
		t := ase.layers[i].tileset
		if t >= 0 && t < len(ase.tilesets) do return &ase.tilesets[t], t
	}
	for p in node.tilemap.painted do if p.layer == layer && p.tileset >= 0 && p.tileset < len(ase.tilesets) do return &ase.tilesets[p.tileset], p.tileset
	return nil, -1
}

// The painted layer of a name (nil if there's none)
@(private="file")
paintedLayer :: proc(node: ^NodeDef, name: string) -> ^e.TileLayerData {
	for &p in node.tilemap.painted do if p.layer == name do return &p
	return nil
}

/*
A layer's painted copy, made on its first stroke: a file layer's tiles in the TileMap's frame
(its place and size), or an empty grid for a layer of the scene's own.
*/
@(private="file")
ensurePainted :: proc(node: ^NodeDef, ase: ^e.Aseprite, name: string, tileset: int) -> ^e.TileLayerData {
	if p := paintedLayer(node, name); p != nil do return p
	layer := e.TileLayerData{layer = strings.clone(name), tileset = max(tileset, 0)}
	layer.tiles = make([dynamic]u32)
	if i := e.Aseprite_FindLayer(ase, name); i >= 0 && ase.layers[i].type == .Tilemap {
		layer.tileset = ase.layers[i].tileset
		if cel := e.Aseprite_Cel(ase, clamp(node.tilemap.frame, 0, max(len(ase.frames) - 1, 0)), i); cel != nil && cel.tiles != nil {
			layer.x, layer.y, layer.columns, layer.rows = cel.x, cel.y, cel.width, cel.height
			append(&layer.tiles, ..cel.tiles)
		}
	}
	append(&node.tilemap.painted, layer)
	return &node.tilemap.painted[len(node.tilemap.painted) - 1]
}

// Grows a layer's grid to hold a cell (left and up too: its place moves), keeping its tiles
@(private="file")
growTo :: proc(p: ^e.TileLayerData, column, row: int, tileSize: [2]int) -> (int, int) {
	left, top := min(column, 0), min(row, 0)
	right, bottom := max(column + 1, p.columns), max(row + 1, p.rows)
	if left == 0 && top == 0 && right == p.columns && bottom == p.rows do return column, row
	columns, rows := right - left, bottom - top
	grown := make([dynamic]u32, columns * rows)
	for y in 0..<p.rows do for x in 0..<p.columns do grown[(y - top) * columns + x - left] = p.tiles[y * p.columns + x]
	delete(p.tiles)
	p.tiles = grown
	p.x += left * tileSize.x
	p.y += top * tileSize.y
	p.columns, p.rows = columns, rows
	return column - left, row - top
}

/*
The cell of a layer under a world point (in its grid; it may be outside it).

Returns:
- The column and row, and false when the layer has no tileset
*/
TilePaint_CellAt :: proc(s: ^State, node: ^NodeDef, ase: ^e.Aseprite, layer: string, world: [2]f32) -> (column, row: int, ok: bool) {
	tileset, _ := TilePaint_Tileset(node, ase, layer)
	if tileset == nil || tileset.tileWidth <= 0 || tileset.tileHeight <= 0 do return
	scene := &s.project.scenes[s.currentScene]
	local := e.Transform2D_Apply(e.Transform2D_Inverse(Scene_WorldTransforms(scene)[s.selectedNode]), world)
	origin := TilePaint_Origin(node, ase, layer)
	cell := (local - origin) / [2]f32{f32(tileset.tileWidth), f32(tileset.tileHeight)}
	return int(floorf(cell.x)), int(floorf(cell.y)), true
}

// Where a layer's grid starts in the node's space: its painted copy's place, else the file cel's
TilePaint_Origin :: proc(node: ^NodeDef, ase: ^e.Aseprite, layer: string) -> [2]f32 {
	if p := paintedLayer(node, layer); p != nil do return {f32(p.x), f32(p.y)}
	if i := e.Aseprite_FindLayer(ase, layer); i >= 0 {
		if cel := e.Aseprite_Cel(ase, clamp(node.tilemap.frame, 0, max(len(ase.frames) - 1, 0)), i); cel != nil do return {f32(cel.x), f32(cel.y)}
	}
	return {}
}

@(private="file")
floorf :: proc(v: f32) -> f32 {
	i := f32(int(v))
	return v < 0 && i != v ? i - 1 : i
}

// A cell's tile in a layer as painted or in the file (0 outside it)
TilePaint_TileAt :: proc(node: ^NodeDef, ase: ^e.Aseprite, layer: string, column, row: int) -> u32 {
	if p := paintedLayer(node, layer); p != nil {
		if column < 0 || row < 0 || column >= p.columns || row >= p.rows do return 0
		return p.tiles[row * p.columns + column]
	}
	if i := e.Aseprite_FindLayer(ase, layer); i >= 0 {
		if cel := e.Aseprite_Cel(ase, clamp(node.tilemap.frame, 0, max(len(ase.frames) - 1, 0)), i); cel != nil && cel.tiles != nil {
			if column >= 0 && row >= 0 && column < cel.width && row < cel.height do return cel.tiles[row * cel.width + column]
		}
	}
	return 0
}

/*
Handles the Tiles panel's messages and tile strokes (on the selected TileMap).

Returns:
- Whether `m` was one of them
*/
TilePaint_Update :: proc(s: ^State, m: Msg) -> bool {
	p := &s.tilePainter
	#partial switch v in m {
	case Tile_Tool_Chosen:
		p.tool = TilePaintTool(v)
	case Tile_Brush_Chosen:
		// The tile, keeping the brush's flips
		p.tile = (u32(v) & e.ASEPRITE_TILE_ID) | (p.tile & ~e.ASEPRITE_TILE_ID)
		if p.tool == .Erase || p.tool == .Pick do p.tool = .Paint
	case Tile_Brush_Turned:
		flips := p.tile & ~e.ASEPRITE_TILE_ID
		switch int(v) {
		case 0: flips ~= e.ASEPRITE_TILE_FLIP_X
		case 1: flips ~= e.ASEPRITE_TILE_FLIP_Y
		case:
			// A quarter turn clockwise each time: none, D+X, X+Y, D+Y
			X, Y, D :: e.ASEPRITE_TILE_FLIP_X, e.ASEPRITE_TILE_FLIP_Y, e.ASEPRITE_TILE_FLIP_D
			switch flips {
			case 0:     flips = D | X
			case D | X: flips = X | Y
			case X | Y: flips = D | Y
			case:       flips = 0
			}
		}
		p.tile = (p.tile & e.ASEPRITE_TILE_ID) | flips
	case Tile_Layer_Chosen:
		delete(p.layer)
		p.layer = strings.clone(string(v))
	case Tile_Terrain_Chosen:
		delete(p.terrain)
		p.terrain = strings.clone(string(v))
		p.tool = .Terrain
	case Tile_Tileset_Chosen:
		p.tileset = max(int(v), 0)
	case Tile_Layer_Added:
		node, ase := TilePaint_Node(s)
		if node == nil do break
		// "Layer 2", "Layer 3"... a name no layer has
		names := TilePaint_Layers(node, ase)
		name := ""
		for n := len(names) + 1; ; n += 1 {
			name = fmt.tprintf("Layer %d", n)
			taken := false
			for other in names do if other == name do taken = true
			if !taken do break
		}
		ensurePainted(node, ase, name, clamp(p.tileset, 0, max(len(ase.tilesets) - 1, 0)))
		delete(p.layer)
		p.layer = strings.clone(name)
	case Tile_Layer_Reverted:
		node, ase := TilePaint_Node(s)
		if node == nil do break
		layer := TilePaint_Layer(s, node, ase)
		// Only a file layer can go back to the file's tiles
		if i := e.Aseprite_FindLayer(ase, layer); i < 0 || ase.layers[i].type != .Tilemap do break
		for &q, i in node.tilemap.painted do if q.layer == layer {
			e.TileLayerData_Destroy(&q)
			ordered_remove(&node.tilemap.painted, i)
			break
		}
	case Tile_Brush:
		brush(s, v)
	case:
		return false
	}
	return true
}

// A stroke's step on the selected TileMap
@(private="file")
brush :: proc(s: ^State, v: Tile_Brush) {
	p := &s.tilePainter
	node, ase := TilePaint_Node(s)
	if node == nil {
		p.stroking, p.hovering = false, false
		return
	}
	layer := TilePaint_Layer(s, node, ase)
	column, row, ok := TilePaint_CellAt(s, node, ase, layer, v.world)
	p.hover, p.hovering = {column, row}, ok
	if !ok do return
	switch v.phase {
	case .Hover:
		return
	case .Begin:
		// A new gesture: the stroke is one undo step (History_Classify)
		s.history.gesture += 1
		p.stroking, p.erasing, p.start = true, v.erase, {column, row}
		if p.tool == .Rectangle do return
	case .Move:
		if !p.stroking || p.tool == .Rectangle || p.tool == .Fill do return
	case .End:
		if !p.stroking do return
		p.stroking = false
		if p.tool != .Rectangle do return
	}
	tileset, tilesetIndex := TilePaint_Tileset(node, ase, layer)
	if tileset == nil do return
	size := [2]int{tileset.tileWidth, tileset.tileHeight}
	erasing := p.erasing || p.tool == .Erase
	tile := erasing ? 0 : p.tile
	switch p.tool {
	case .Pick:
		if picked := TilePaint_TileAt(node, ase, layer, column, row); picked != 0 do p.tile = picked
		return
	case .Paint, .Erase:
		// Erasing outside the grid changes nothing (no need to grow it)
		if erasing && TilePaint_TileAt(node, ase, layer, column, row) == 0 do return
		q := ensurePainted(node, ase, layer, tilesetIndex)
		x, y := growTo(q, column, row, size)
		q.tiles[y * q.columns + x] = tile
	case .Rectangle:
		q := ensurePainted(node, ase, layer, tilesetIndex)
		// Both corners in the grid; growing left or up moves what's already there
		sx, sy := growTo(q, p.start.x, p.start.y, size)
		dx, dy := sx - p.start.x, sy - p.start.y
		ex, ey := growTo(q, column + dx, row + dy, size)
		sx += ex - (column + dx)
		sy += ey - (row + dy)
		for y in min(sy, ey)..=max(sy, ey) do for x in min(sx, ex)..=max(sx, ex) do q.tiles[y * q.columns + x] = tile
	case .Fill:
		q := ensurePainted(node, ase, layer, tilesetIndex)
		if column < 0 || row < 0 || column >= q.columns || row >= q.rows do return
		floodFill(q, column, row, tile)
	case .Terrain:
		// The panel's terrain, else the tileset's first (what its dropdown shows)
		terrain := p.terrain
		terrains := e.Tileset_Terrains(tileset, context.temp_allocator)
		known := false
		for t in terrains do if t == terrain do known = true
		if !known do terrain = len(terrains) > 0 ? terrains[0] : ""
		if terrain == "" && !erasing do return
		q := ensurePainted(node, ase, layer, tilesetIndex)
		x, y := growTo(q, column, row, size)
		e.TileGrid_PaintTerrain(tileset, q.tiles[:], q.columns, q.rows, x, y, erasing ? "" : terrain)
	}
}

// The cells connected to (x, y) that have its tile, given another (4 neighbours)
@(private="file")
floodFill :: proc(q: ^e.TileLayerData, x, y: int, tile: u32) {
	from := q.tiles[y * q.columns + x]
	if from == tile do return
	stack := make([dynamic][2]int, context.temp_allocator)
	append(&stack, [2]int{x, y})
	for len(stack) > 0 {
		c := pop(&stack)
		if c.x < 0 || c.y < 0 || c.x >= q.columns || c.y >= q.rows || q.tiles[c.y * q.columns + c.x] != from do continue
		q.tiles[c.y * q.columns + c.x] = tile
		append(&stack, [2]int{c.x + 1, c.y}, [2]int{c.x - 1, c.y}, [2]int{c.x, c.y + 1}, [2]int{c.x, c.y - 1})
	}
}

// Frees the panel's strings (State_Destroy)
TilePainter_Destroy :: proc(p: ^TilePainter) {
	delete(p.layer)
	delete(p.terrain)
	p^ = {}
}

/*
The world corners of a block of a layer's cells (from one cell to another, either order): for
the viewport's outline.

Returns:
- Two opposite corners, and false when the layer has no tileset
*/
TilePaint_CellsRect :: proc(s: ^State, node: ^NodeDef, ase: ^e.Aseprite, layer: string, a, b: [2]int) -> (lo, hi: [2]f32, ok: bool) {
	tileset, _ := TilePaint_Tileset(node, ase, layer)
	if tileset == nil do return
	size := [2]f32{f32(tileset.tileWidth), f32(tileset.tileHeight)}
	origin := TilePaint_Origin(node, ase, layer)
	first := [2]f32{f32(min(a.x, b.x)), f32(min(a.y, b.y))}
	last := [2]f32{f32(max(a.x, b.x) + 1), f32(max(a.y, b.y) + 1)}
	world := Scene_WorldTransforms(&s.project.scenes[s.currentScene])[s.selectedNode]
	return e.Transform2D_Apply(world, origin + first * size), e.Transform2D_Apply(world, origin + last * size), true
}
