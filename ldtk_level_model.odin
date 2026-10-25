package crossfire_editor

import "core:strings"
import stbi "vendor:stb/image"

/*
One level of an LDtk document decoded for painting (the Level mode's tools: level_paint.odin): its
grid layers as arrays (IntGrid values, tile stacks, auto-layer tiles per cell), the definitions
they use (layers, IntGrid values, auto-layer rules, tilesets), as LDtk's own `LayerInstance` holds
them. The tools change it in place, the auto-layer rules run on it (ldtk_rules.odin), the canvas
draws it (level_layers_render.odin), and a stroke's end writes the changed layers back into the
document as LDtk writes them (`LDtkLevel_Patches`: `intGridCsv`, `gridTiles`, `autoLayerTiles`,
with LDtk's own JSON layout: ldtk_json_pretty.odin), one undo step.

- **Decoded once per document version** (`LDtkLevel_For`): while painting the model is ahead of
  the document; a stroke's commit makes the document catch up, and the model is kept (its
  `version` moved to the document's). Anything else that changes the document (undo, another
  edit, LDtk's save) decodes it again.
- **Cells:** `cx + cy * cWid` (LDtk's coordId); a tile layer's cell holds a stack of tiles
  (`LDtkGridTile`: tile id and flips, bottom first), an auto layer's cell the tiles each rule put
  there (`LDtkAutoTile`, keyed by the cell the rule matched at: a tile can be drawn elsewhere,
  with offsets or stamps).
- **IntGrid counts** (`LDtkLayerData.counts`, `areas`): how many cells hold each value (and each
  value group) in the layer and in each 10x10 area, as LDtk counts them: a rule that needs a value
  the layer or the cell's corners' areas lack isn't tried (`AutoLayerRuleDef.isRelevantInLayerAt`).
  Rules see the same thing in LDtk.
- **Opaque tiles** (break-on-match locks: ldtk_rules.odin) come from the tileset's
  `cachedPixelData.opaqueTiles`, or from its image when the file has none (LDtk computes it when
  it loads the image: `TilesetDef.buildPixelData`).
*/

// What a layer is (LDtk's `__type`)
LDtkLayerKind :: enum u8 {
	IntGrid,
	Tiles,
	Entities,
	AutoLayer,
}

// A tileset definition as painting needs it
LDtkTilesetInfo :: struct {
	uid: int,
	// The image, relative to the project file (owned)
	relPath: string,
	pxWid, pxHei, tileGridSize, spacing, padding: int,
	// Tiles across and down (`__cWid`, `__cHei`)
	cWid, cHei: int,
	// Which tiles have no transparent pixel (owned; nil: unknown, none counts as opaque)
	opaque: []bool,
}

// An IntGrid value of a layer definition
LDtkValueInfo :: struct {
	value: int,
	// Its group's uid (0: none)
	group: int,
	color: u32,
	// Its name (owned; "" none)
	identifier: string,
}

// A layer definition as painting needs it
LDtkLayerInfo :: struct {
	uid: int,
	// Its name (owned)
	identifier: string,
	kind: LDtkLayerKind,
	gridSize: int,
	displayOpacity, inactiveOpacity: f64,
	// Drawn in other levels' pictures (`renderInWorldView`: LDtk's world view)
	inWorldView: bool,
	pxOffset: [2]int,
	// Uids, -1 when none: its tileset, an auto layer's IntGrid source, the Tiles layer whose
	// tiles remove its auto tiles, the level field picking rule groups (biomes)
	tileset, autoSource, killedBy, biomeField: int,
	tilePivot: [2]f64,
	values: [dynamic]LDtkValueInfo,
	groups: [dynamic]LDtkRuleGroup,
}

// A tile painted in a cell (LDtk's GridTileInfos)
LDtkGridTile :: struct {
	tile: i32,
	// Bit 0: flipped on X, bit 1: on Y
	flips: u8,
}

// A tile an auto-layer rule put (LDtk's autoTilesCache entries)
LDtkAutoTile :: struct {
	// The rule's uid
	rule: i32,
	// Where it's drawn in the layer (pixels, without the layer's offsets)
	x, y: i32,
	srcX, srcY: i32,
	tile: i32,
	flips: u8,
	alpha: f64,
}

// What a stroke changed in a layer (what its commit writes)
LDtkLayerPart :: enum {
	IntGrid,
	Tiles,
	Auto,
}

// A layer instance of the level
LDtkLayerData :: struct {
	// Its definition (an index into LDtkLevelModel.defs)
	def: int,
	// Its iid (owned)
	iid: string,
	cWid, cHei: int,
	// The instance's own offset (pixels; the definition's adds to it)
	pxOffset: [2]int,
	visible: bool,
	seed: int,
	// The optional rule groups turned on here (uids)
	optionalRules: [dynamic]int,
	// A tileset that replaces the definition's (-1 none)
	overrideTileset: int,
	// IntGrid values per cell (0 empty)
	intGrid: []i32,
	// Tile stacks per cell (a Tiles layer)
	tiles: [][dynamic]LDtkGridTile,
	// Auto-layer tiles per cell (an auto layer); `autoKnown` false: none were read (LDtk's null
	// cache: the first edit applies every rule)
	auto: [][dynamic]LDtkAutoTile,
	autoKnown: bool,
	// IntGrid counts: per value (groups as `(uid + 1) * 1000`), and per value and 10x10 area
	counts: map[int]int,
	areas: map[[2]int]int,
	// What changed since the document last had it
	changed: bit_set[LDtkLayerPart],
	// The cells changed since the canvas last drew it (left, top, right, bottom; `dirtyAny`
	// false: none)
	dirty: [4]int,
	dirtyAny: bool,
	// The cells a tool changed since the rules last ran on them (`editedAny` false: none)
	edited: [4]int,
	editedAny: bool,
}

// A level decoded for painting
LDtkLevelModel :: struct {
	// The document's file (relative to the project, owned), the level's index and names (owned)
	file: string,
	level: int,
	iid, identifier: string,
	pxWid, pxHei: int,
	// The document version it was read from (or caught up with)
	version: int,
	// Which decoding this is (each `LDtkLevel_Read` takes the next: pictures drawn from another
	// are drawn again)
	gen: int,
	defs: [dynamic]LDtkLayerInfo,
	tilesets: [dynamic]LDtkTilesetInfo,
	// The level's layer instances, top first (the file's order)
	layers: [dynamic]LDtkLayerData,
	// The level's enum field values by field definition uid (biomes; owned)
	fields: map[int][dynamic]string,
	// A minified document (the values written are minified too)
	minified: bool,
}

// The size of LDtk's IntGrid count areas (LayerInstance.intGridAreaSize)
LDTK_AREA_SIZE :: 10

// LDtk's coordId of a cell
LDtkLayer_Coord :: #force_inline proc(l: ^LDtkLayerData, cx, cy: int) -> int {
	return cx + cy * l.cWid
}

// Whether a cell is in a layer
LDtkLayer_Valid :: #force_inline proc(l: ^LDtkLayerData, cx, cy: int) -> bool {
	return cx >= 0 && cx < l.cWid && cy >= 0 && cy < l.cHei
}

// A layer's IntGrid value at a cell (0 outside or empty)
LDtkLayer_IntGrid :: #force_inline proc(l: ^LDtkLayerData, cx, cy: int) -> int {
	if !LDtkLayer_Valid(l, cx, cy) || len(l.intGrid) == 0 do return 0
	return int(l.intGrid[cx + cy * l.cWid])
}

// A layer's definition
LDtkLevel_Def :: #force_inline proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) -> ^LDtkLayerInfo {
	return &m.defs[l.def]
}

// A layer instance by its definition's uid (nil: the level has none)
LDtkLevel_LayerByDef :: proc(m: ^LDtkLevelModel, defUid: int) -> ^LDtkLayerData {
	for &l in m.layers do if m.defs[l.def].uid == defUid do return &l
	return nil
}

// A tileset by uid (nil: none)
LDtkLevel_Tileset :: proc(m: ^LDtkLevelModel, uid: int) -> ^LDtkTilesetInfo {
	if uid < 0 do return nil
	for &t in m.tilesets do if t.uid == uid do return &t
	return nil
}

// The tileset a layer instance uses (its override, else its definition's; nil: none)
LDtkLevel_LayerTileset :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) -> ^LDtkTilesetInfo {
	if l.overrideTileset >= 0 do return LDtkLevel_Tileset(m, l.overrideTileset)
	return LDtkLevel_Tileset(m, m.defs[l.def].tileset)
}

// A layer definition's IntGrid value (nil: not one of its values)
LDtkLayerInfo_Value :: proc(d: ^LDtkLayerInfo, value: int) -> ^LDtkValueInfo {
	for &v in d.values do if v.value == value do return &v
	return nil
}

// A tile's column and row in its tileset (TilesetDef.getTileCx / getTileCy)
LDtkTileset_TileCell :: #force_inline proc(t: ^LDtkTilesetInfo, tile: int) -> [2]int {
	w := max(t.cWid, 1)
	return {tile - w * (tile / w), tile / w}
}

// A tile's id from its column and row
LDtkTileset_TileId :: #force_inline proc(t: ^LDtkTilesetInfo, cx, cy: int) -> int {
	return cx + cy * t.cWid
}

// Where a tile is in its tileset's image (TilesetDef.getTileSourceX / Y)
LDtkTileset_Source :: #force_inline proc(t: ^LDtkTilesetInfo, tile: int) -> [2]int {
	c := LDtkTileset_TileCell(t, tile)
	return {t.padding + c.x * (t.tileGridSize + t.spacing), t.padding + c.y * (t.tileGridSize + t.spacing)}
}

// Whether a tile has no transparent pixel (false when unknown)
LDtkTileset_Opaque :: #force_inline proc(t: ^LDtkTilesetInfo, tile: int) -> bool {
	return t != nil && tile >= 0 && tile < len(t.opaque) && t.opaque[tile]
}

/*
Decodes a level of a document for painting.

Inputs:
- doc: The document
- file: Its path relative to the project (kept in the model)
- level: The level's index in the document

Returns:
- The model (free it with `LDtkLevel_Destroy`), false when the level can't be read
*/
LDtkLevel_Read :: proc(doc: ^LDtkDoc, file: string, level: int) -> (m: LDtkLevelModel, ok: bool) {
	if doc == nil || doc.problem != "" || level < 0 || level >= len(doc.levels) do return {}, false
	main := LDtkDoc_Main(doc)
	@(thread_local) generation: int
	generation += 1
	m.gen = generation
	m.file = strings.clone(file)
	m.level = level
	m.version = doc.version
	m.minified = Json_Minified(main)
	identifier, iid := LDtkDoc_LevelNames(doc, level)
	m.identifier, m.iid = strings.clone(identifier), strings.clone(iid)
	entry := doc.levels[level].entry
	m.pxWid = Json_Int(main, Json_Get(main, entry, "pxWid"))
	m.pxHei = Json_Int(main, Json_Get(main, entry, "pxHei"))
	folder := LDtkDoc_Folder(doc)

	for td in Json_Items(main, LDtkDoc_Defs(doc, "tilesets")) do append(&m.tilesets, readTileset(main, td, folder))
	for ld in Json_Items(main, LDtkDoc_Defs(doc, "layers")) do append(&m.defs, readLayerDef(main, ld))

	// The level's enum fields (biomes pick rule groups by them)
	for fi in Json_Items(main, Json_Get(main, entry, "fieldInstances")) {
		values := make([dynamic]string)
		v := Json_Get(main, fi, "__value")
		if Json_Kind(main, v) == .Array {
			for item in Json_Items(main, v) do append(&values, strings.clone(Json_String(main, item)))
		} else if Json_Kind(main, v) == .String {
			append(&values, strings.clone(Json_String(main, v)))
		}
		m.fields[Json_Int(main, Json_Get(main, fi, "defUid"), -1)] = values
	}

	file, array := LDtkDoc_LayerInstances(doc, level)
	json := LDtkDoc_Json(doc, file)
	for li in Json_Items(json, array) {
		defUid := Json_Int(json, Json_Get(json, li, "layerDefUid"), -1)
		def := -1
		for d, i in m.defs do if d.uid == defUid do def = i
		if def < 0 do continue
		append(&m.layers, readLayer(&m, json, li, def))
	}
	return m, true
}

// Frees a level model
LDtkLevel_Destroy :: proc(m: ^LDtkLevelModel) {
	delete(m.file)
	delete(m.iid)
	delete(m.identifier)
	for &t in m.tilesets {
		delete(t.relPath)
		delete(t.opaque)
	}
	delete(m.tilesets)
	for &d in m.defs {
		delete(d.identifier)
		for v in d.values do delete(v.identifier)
		delete(d.values)
		for &g in d.groups do LDtkRuleGroup_Destroy(&g)
		delete(d.groups)
	}
	delete(m.defs)
	for &l in m.layers do layerDestroy(&l)
	delete(m.layers)
	for _, values in m.fields {
		for v in values do delete(v)
		delete(values)
	}
	delete(m.fields)
	m^ = {}
}

@(private="file")
layerDestroy :: proc(l: ^LDtkLayerData) {
	delete(l.iid)
	delete(l.optionalRules)
	delete(l.intGrid)
	for t in l.tiles do delete(t)
	delete(l.tiles)
	for a in l.auto do delete(a)
	delete(l.auto)
	delete(l.counts)
	delete(l.areas)
}

@(private="file")
readTileset :: proc(main: ^JsonDoc, td: int, folder: string) -> LDtkTilesetInfo {
	t := LDtkTilesetInfo{
		uid = Json_Int(main, Json_Get(main, td, "uid"), -1),
		relPath = strings.clone(Json_String(main, Json_Get(main, td, "relPath"))),
		pxWid = Json_Int(main, Json_Get(main, td, "pxWid")),
		pxHei = Json_Int(main, Json_Get(main, td, "pxHei")),
		tileGridSize = max(Json_Int(main, Json_Get(main, td, "tileGridSize"), 16), 1),
		spacing = Json_Int(main, Json_Get(main, td, "spacing")),
		padding = Json_Int(main, Json_Get(main, td, "padding")),
	}
	step := t.tileGridSize + t.spacing
	// TilesetDef's cWid / cHei (ceil), the file's mirrors when present
	t.cWid = Json_Int(main, Json_Get(main, td, "__cWid"), (t.pxWid - t.padding * 2 + step - 1) / max(step, 1))
	t.cHei = Json_Int(main, Json_Get(main, td, "__cHei"), (t.pxHei - t.padding * 2 + step - 1) / max(step, 1))
	count := t.cWid * t.cHei
	opaque := Json_Get(main, Json_Get(main, td, "cachedPixelData"), "opaqueTiles")
	if text := Json_String(main, opaque); len(text) == count && count > 0 {
		t.opaque = make([]bool, count)
		for i in 0 ..< count do t.opaque[i] = text[i] == '1'
	} else if t.relPath != "" && count > 0 {
		t.opaque = ldtkOpaqueTiles(&t, joinPath(folder, t.relPath, allocator = context.temp_allocator))
	}
	return t
}

/*
Which tiles of a tileset image have no transparent pixel (LDtk's TilesetDef._parseTilePixels: a
tile reaching past the image counts as opaque, as there).

Returns:
- One flag per tile (owned), nil when the image can't be read
*/
ldtkOpaqueTiles :: proc(t: ^LDtkTilesetInfo, path: string) -> []bool {
	w, h, channels: i32
	pixels := stbi.load(strings.clone_to_cstring(path, context.temp_allocator), &w, &h, &channels, 4)
	if pixels == nil do return nil
	defer stbi.image_free(pixels)
	out := make([]bool, t.cWid * t.cHei)
	for tile in 0 ..< len(out) {
		out[tile] = true
		src := LDtkTileset_Source(t, tile)
		if src.x + t.tileGridSize > t.pxWid || src.y + t.tileGridSize > t.pxHei do continue
		check: for py in src.y ..< src.y + t.tileGridSize {
			for px in src.x ..< src.x + t.tileGridSize {
				if px >= int(w) || py >= int(h) do continue
				if pixels[(py * int(w) + px) * 4 + 3] < 255 {
					out[tile] = false
					break check
				}
			}
		}
	}
	return out
}

@(private="file")
readLayerDef :: proc(main: ^JsonDoc, ld: int) -> LDtkLayerInfo {
	d := LDtkLayerInfo{
		uid = Json_Int(main, Json_Get(main, ld, "uid"), -1),
		identifier = strings.clone(Json_String(main, Json_Get(main, ld, "identifier"))),
		gridSize = max(Json_Int(main, Json_Get(main, ld, "gridSize"), 16), 1),
		displayOpacity = Json_Float(main, Json_Get(main, ld, "displayOpacity"), 1),
		inactiveOpacity = Json_Float(main, Json_Get(main, ld, "inactiveOpacity"), 1),
		inWorldView = Json_Bool(main, Json_Get(main, ld, "renderInWorldView"), true),
		pxOffset = {Json_Int(main, Json_Get(main, ld, "pxOffsetX")), Json_Int(main, Json_Get(main, ld, "pxOffsetY"))},
		tileset = jsonUid(main, Json_Get(main, ld, "tilesetDefUid")),
		autoSource = jsonUid(main, Json_Get(main, ld, "autoSourceLayerDefUid")),
		killedBy = jsonUid(main, Json_Get(main, ld, "autoTilesKilledByOtherLayerUid")),
		biomeField = jsonUid(main, Json_Get(main, ld, "biomeFieldUid")),
		tilePivot = {Json_Float(main, Json_Get(main, ld, "tilePivotX")), Json_Float(main, Json_Get(main, ld, "tilePivotY"))},
	}
	switch Json_String(main, Json_Get(main, ld, "type")) {
	case "IntGrid":   d.kind = .IntGrid
	case "Tiles":     d.kind = .Tiles
	case "Entities":  d.kind = .Entities
	case "AutoLayer": d.kind = .AutoLayer
	}
	for v in Json_Items(main, Json_Get(main, ld, "intGridValues")) {
		color, _ := LDtk_ParseColor(Json_String(main, Json_Get(main, v, "color")))
		append(&d.values, LDtkValueInfo{
			value = Json_Int(main, Json_Get(main, v, "value")),
			group = Json_Int(main, Json_Get(main, v, "groupUid")),
			color = u32(color),
			identifier = strings.clone(Json_String(main, Json_Get(main, v, "identifier"))),
		})
	}
	for g in Json_Items(main, Json_Get(main, ld, "autoRuleGroups")) do append(&d.groups, LDtkRuleGroup_Read(main, g))
	return d
}

// A uid that may be null (-1)
@(private="file")
jsonUid :: proc(json: ^JsonDoc, node: int) -> int {
	return Json_Kind(json, node) == .Number ? Json_Int(json, node) : -1
}

@(private="file")
readLayer :: proc(m: ^LDtkLevelModel, json: ^JsonDoc, li: int, def: int) -> LDtkLayerData {
	d := &m.defs[def]
	l := LDtkLayerData{
		def = def,
		iid = strings.clone(Json_String(json, Json_Get(json, li, "iid"))),
		cWid = Json_Int(json, Json_Get(json, li, "__cWid")),
		cHei = Json_Int(json, Json_Get(json, li, "__cHei")),
		pxOffset = {Json_Int(json, Json_Get(json, li, "pxOffsetX")), Json_Int(json, Json_Get(json, li, "pxOffsetY"))},
		visible = Json_Bool(json, Json_Get(json, li, "visible"), true),
		seed = Json_Int(json, Json_Get(json, li, "seed")),
		overrideTileset = jsonUid(json, Json_Get(json, li, "overrideTilesetUid")),
	}
	for uid in Json_Items(json, Json_Get(json, li, "optionalRules")) do append(&l.optionalRules, Json_Int(json, uid))
	cells := max(l.cWid * l.cHei, 0)
	switch d.kind {
	case .IntGrid:
		l.intGrid = make([]i32, cells)
		csv := Json_Get(json, li, "intGridCsv")
		i := 0
		for c := json.nodes[csv].first if csv >= 0 else -1; c >= 0 && i < cells; c = json.nodes[c].next {
			v := Json_Int(json, int(c))
			// LDtk keeps values >= 0 (LayerInstance.fromJson)
			l.intGrid[i] = i32(max(v, 0))
			i += 1
		}
		LDtkLayer_Recount(m, &l)
	case .Tiles:
		l.tiles = make([][dynamic]LDtkGridTile, cells)
		gt := Json_Get(json, li, "gridTiles")
		for c := json.nodes[gt].first if gt >= 0 else -1; c >= 0; c = json.nodes[c].next {
			t := int(c)
			coord := Json_Int(json, Json_At(json, Json_Get(json, t, "d"), 0), -1)
			if coord < 0 || coord >= cells do continue
			append(&l.tiles[coord], LDtkGridTile{tile = i32(Json_Int(json, Json_Get(json, t, "t"))), flips = u8(Json_Int(json, Json_Get(json, t, "f")))})
		}
	case .Entities, .AutoLayer:
	}
	if d.kind == .IntGrid || d.kind == .AutoLayer {
		l.auto = make([][dynamic]LDtkAutoTile, cells)
		at := Json_Get(json, li, "autoLayerTiles")
		l.autoKnown = Json_Kind(json, at) == .Array
		for c := json.nodes[at].first if at >= 0 else -1; c >= 0; c = json.nodes[c].next {
			t := int(c)
			dn := Json_Get(json, t, "d")
			coord := Json_Int(json, Json_At(json, dn, 1), -1)
			if coord < 0 || coord >= cells do continue
			px := Json_Get(json, t, "px")
			src := Json_Get(json, t, "src")
			append(&l.auto[coord], LDtkAutoTile{
				rule = i32(Json_Int(json, Json_At(json, dn, 0))),
				x = i32(Json_Int(json, Json_At(json, px, 0))), y = i32(Json_Int(json, Json_At(json, px, 1))),
				srcX = i32(Json_Int(json, Json_At(json, src, 0))), srcY = i32(Json_Int(json, Json_At(json, src, 1))),
				tile = i32(Json_Int(json, Json_Get(json, t, "t"))),
				flips = u8(Json_Int(json, Json_Get(json, t, "f"))),
				alpha = Json_Float(json, Json_Get(json, t, "a"), 1),
			})
		}
	}
	return l
}

// The area of a cell in LDtk's counts (LayerInstance.areaCoordId: truncated, so cells left of
// or above the layer count in the first area)
@(private="file")
areaOf :: #force_inline proc(cx, cy: int) -> int {
	return cx / LDTK_AREA_SIZE + (cy / LDTK_AREA_SIZE) * 10000
}

// A value's group as rules name it (LayerDef.getRuleValueFromGroupUid), -1 when it isn't a value
@(private="file")
groupRuleValue :: proc(d: ^LDtkLayerInfo, value: int) -> int {
	v := LDtkLayerInfo_Value(d, value)
	if v == nil || v.group < 0 do return -1
	// Ungrouped values (group 0) count as 1000, as in LDtk
	return (v.group + 1) * 1000
}

// LayerInstance.increaseAreaIntGridValueCount / decrease
@(private="file")
countValue :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, value, cx, cy, by: int) {
	if value == 0 do return
	key := [2]int{value, areaOf(cx, cy)}
	n := l.areas[key] + by
	if n <= 0 do delete_key(&l.areas, key)
	else do l.areas[key] = n
	c := l.counts[value] + by
	if c <= 0 do delete_key(&l.counts, value)
	else do l.counts[value] = c
	if value < 1000 {
		if g := groupRuleValue(&m.defs[l.def], value); g > 0 do countValue(m, l, g, cx, cy, by)
	}
}

// Counts an IntGrid layer's values again (LayerInstance.recountAllIntGridValues)
LDtkLayer_Recount :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) {
	clear(&l.counts)
	clear(&l.areas)
	for cy in 0 ..< l.cHei do for cx in 0 ..< l.cWid {
		if v := int(l.intGrid[cx + cy * l.cWid]); v != 0 do countValue(m, l, v, cx, cy, 1)
	}
}

// Whether a layer has a value (or group) anywhere (LayerInstance.containsIntGridValueOrGroup)
LDtkLayer_Contains :: #force_inline proc(l: ^LDtkLayerData, value: int) -> bool {
	return value in l.counts
}

// Whether a value (or group) is in a cell's area (LayerInstance.hasIntGridValueInArea)
LDtkLayer_InArea :: #force_inline proc(l: ^LDtkLayerData, value, cx, cy: int) -> bool {
	return l.areas[{value, areaOf(cx, cy)}] > 0
}

/*
Sets an IntGrid cell (LayerInstance.setIntGrid; a negative value removes it, as there), keeping the
counts.

Returns:
- Whether the cell changed
*/
LDtkLayer_SetIntGrid :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, cx, cy, value: int) -> bool {
	if !LDtkLayer_Valid(l, cx, cy) || len(l.intGrid) == 0 do return false
	v := max(value, 0)
	i := cx + cy * l.cWid
	old := int(l.intGrid[i])
	if old == v do return false
	countValue(m, l, old, cx, cy, -1)
	countValue(m, l, v, cx, cy, 1)
	l.intGrid[i] = i32(v)
	l.changed += {.IntGrid}
	LDtkLayer_MarkEdited(l, cx, cy, cx, cy)
	return true
}

// Marks cells for the canvas to draw again (level_layers_render.odin)
LDtkLayer_MarkDirty :: proc(l: ^LDtkLayerData, left, top, right, bottom: int) {
	if !l.dirtyAny {
		l.dirty = {left, top, right, bottom}
		l.dirtyAny = true
		return
	}
	l.dirty = {min(l.dirty[0], left), min(l.dirty[1], top), max(l.dirty[2], right), max(l.dirty[3], bottom)}
}

// Marks cells a tool changed: drawn again, and the auto-layer rules run around them (level_paint.odin)
LDtkLayer_MarkEdited :: proc(l: ^LDtkLayerData, left, top, right, bottom: int) {
	LDtkLayer_MarkDirty(l, left, top, right, bottom)
	if !l.editedAny {
		l.edited = {left, top, right, bottom}
		l.editedAny = true
		return
	}
	l.edited = {min(l.edited[0], left), min(l.edited[1], top), max(l.edited[2], right), max(l.edited[3], bottom)}
}

// Whether a cell has any tile (LayerInstance.hasAnyGridTile)
LDtkLayer_HasTile :: #force_inline proc(l: ^LDtkLayerData, cx, cy: int) -> bool {
	return LDtkLayer_Valid(l, cx, cy) && len(l.tiles) > 0 && len(l.tiles[cx + cy * l.cWid]) > 0
}

// Whether a cell has a tile (with these flips, unless nil) anywhere in its stack
LDtkLayer_HasSpecificTile :: proc(l: ^LDtkLayerData, cx, cy, tile: int, flips: Maybe(u8) = nil) -> bool {
	if !LDtkLayer_HasTile(l, cx, cy) do return false
	for t in l.tiles[cx + cy * l.cWid] do if int(t.tile) == tile && (flips == nil || t.flips == flips.?) do return true
	return false
}

// The top tile of a cell's stack (false: none)
LDtkLayer_TopTile :: proc(l: ^LDtkLayerData, cx, cy: int) -> (LDtkGridTile, bool) {
	if !LDtkLayer_HasTile(l, cx, cy) do return {}, false
	stack := l.tiles[cx + cy * l.cWid]
	return stack[len(stack) - 1], true
}

/*
Puts a tile in a cell (LayerInstance.addGridTile): stacked over what's there (the same tile with
the same flips moves to the top), or alone.
*/
LDtkLayer_AddTile :: proc(l: ^LDtkLayerData, cx, cy, tile: int, flips: u8, stack: bool) {
	if !LDtkLayer_Valid(l, cx, cy) || len(l.tiles) == 0 do return
	cell := &l.tiles[cx + cy * l.cWid]
	t := LDtkGridTile{i32(tile), flips}
	if len(cell) == 0 || !stack {
		clear(cell)
		append(cell, t)
	} else {
		for i in 0 ..< len(cell) do if cell[i] == t {
			ordered_remove(cell, i)
			break
		}
		append(cell, t)
	}
	l.changed += {.Tiles}
	LDtkLayer_MarkEdited(l, cx, cy, cx, cy)
}

// Removes every tile of a cell (LayerInstance.removeAllGridTiles); whether it had any
LDtkLayer_RemoveTiles :: proc(l: ^LDtkLayerData, cx, cy: int) -> bool {
	if !LDtkLayer_HasTile(l, cx, cy) do return false
	clear(&l.tiles[cx + cy * l.cWid])
	l.changed += {.Tiles}
	LDtkLayer_MarkEdited(l, cx, cy, cx, cy)
	return true
}

// Removes a cell's top tile (LayerInstance.removeTopMostGridTile); whether it had one
LDtkLayer_RemoveTopTile :: proc(l: ^LDtkLayerData, cx, cy: int) -> bool {
	if !LDtkLayer_HasTile(l, cx, cy) do return false
	pop(&l.tiles[cx + cy * l.cWid])
	l.changed += {.Tiles}
	LDtkLayer_MarkEdited(l, cx, cy, cx, cy)
	return true
}

/*
The patches writing a level's changed layers back into the document, as LDtk writes them
(`intGridCsv`, `gridTiles`, `autoLayerTiles`; LDtk's JSON layout, the file's style: minified or
not). The level's layers must be where the model read them.

Returns:
- The patches (temp allocated), empty when nothing changed
*/
LDtkLevel_Patches :: proc(m: ^LDtkLevelModel, doc: ^LDtkDoc) -> LDtkPatches {
	patches: LDtkPatches
	file, array := LDtkDoc_LayerInstances(doc, m.level)
	json := LDtkDoc_Json(doc, file)
	for &l in m.layers {
		if l.changed == {} do continue
		li := -1
		for item in Json_Items(json, array) do if Json_String(json, Json_Get(json, item, "iid")) == l.iid do li = item
		if li < 0 do continue
		// Written straight as text (the same as LDtk_PrettyJson of LDtkLayer_*Json: a test compares
		// them), the arrays are big
		setText :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, json: ^JsonDoc, file, li: int, key, text: string) {
			if node := Json_Get(json, li, key); node >= 0 {
				LDtkPatches_Set(p, doc, file, node, text)
			} else {
				LDtkPatches_Add(p, file, Json_AddMemberPatch(json, li, key, text))
			}
		}
		indentOf :: proc(json: ^JsonDoc, li: int, key: string) -> int {
			node := Json_Get(json, li, key)
			if node >= 0 do return LDtk_IndentAt(json.text, int(json.nodes[node].start))
			return LDtk_IndentAt(json.text, int(json.nodes[li].start)) + 1
		}
		if .IntGrid in l.changed do setText(&patches, doc, json, file, li, "intGridCsv", LDtkLayer_IntGridText(&l, m.minified, indentOf(json, li, "intGridCsv")))
		if .Tiles in l.changed do setText(&patches, doc, json, file, li, "gridTiles", LDtkLayer_GridTilesText(m, &l, m.minified, indentOf(json, li, "gridTiles")))
		if .Auto in l.changed do setText(&patches, doc, json, file, li, "autoLayerTiles", LDtkLayer_AutoTilesText(m, &l, m.minified, indentOf(json, li, "autoLayerTiles")))
	}
	return patches
}

// Tabs for JsonPretty's indentation
@(private="file")
writeTabs :: #force_inline proc(b: ^strings.Builder, n: int) {
	for _ in 0 ..< n do strings.write_byte(b, '\t')
}

/*
A layer's `intGridCsv` as LDtk writes it (JsonPretty: a grid of 35 numbers a line past 85 of them,
one per line from 50, else one line), without building a tree: the same text as
`LDtk_PrettyJson(LDtkLayer_IntGridJson(l), ...)`.

Returns:
- The text (temp allocated)
*/
LDtkLayer_IntGridText :: proc(l: ^LDtkLayerData, minified: bool, indent: int) -> string {
	n := len(l.intGrid)
	if n == 0 do return "[]"
	b := strings.builder_make(0, n * 3 + 64, context.temp_allocator)
	switch {
	case !minified && n > 85:
		strings.write_string(&b, "[\n")
		writeTabs(&b, indent + 1)
		line := 0
		for v, i in l.intGrid {
			strings.write_int(&b, int(v))
			if i < n - 1 do strings.write_byte(&b, ',')
			line += 1
			if line >= 35 {
				strings.write_byte(&b, '\n')
				writeTabs(&b, indent + 1)
				line = 0
			}
		}
		strings.write_byte(&b, '\n')
		writeTabs(&b, indent)
		strings.write_byte(&b, ']')
	case !minified && n >= 50:
		strings.write_string(&b, "[\n")
		for v, i in l.intGrid {
			writeTabs(&b, indent + 1)
			strings.write_int(&b, int(v))
			if i < n - 1 do strings.write_string(&b, ",\n")
		}
		strings.write_byte(&b, '\n')
		writeTabs(&b, indent)
		strings.write_byte(&b, ']')
	case:
		strings.write_byte(&b, '[')
		for v, i in l.intGrid {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_int(&b, int(v))
		}
		strings.write_byte(&b, ']')
	}
	return strings.to_string(b)
}

// A tile object as JsonPretty writes it (`{ "px": [x,y], "src": [x,y], "f": f, "t": t, "d": [...], "a": a }`)
@(private="file")
writeTileText :: proc(b: ^strings.Builder, minified: bool, px, src: [2]int, f, t: int, d: []int, a: f64) {
	sep := minified ? ":" : ": "
	strings.write_string(b, minified ? "{\"px\"" : "{ \"px\"")
	strings.write_string(b, sep)
	strings.write_byte(b, '[')
	strings.write_int(b, px.x)
	strings.write_byte(b, ',')
	strings.write_int(b, px.y)
	strings.write_string(b, minified ? "],\"src\"" : "], \"src\"")
	strings.write_string(b, sep)
	strings.write_byte(b, '[')
	strings.write_int(b, src.x)
	strings.write_byte(b, ',')
	strings.write_int(b, src.y)
	strings.write_string(b, minified ? "],\"f\"" : "], \"f\"")
	strings.write_string(b, sep)
	strings.write_int(b, f)
	strings.write_string(b, minified ? ",\"t\"" : ", \"t\"")
	strings.write_string(b, sep)
	strings.write_int(b, t)
	strings.write_string(b, minified ? ",\"d\"" : ", \"d\"")
	strings.write_string(b, sep)
	strings.write_byte(b, '[')
	for v, i in d {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_int(b, v)
	}
	strings.write_string(b, minified ? "],\"a\"" : "], \"a\"")
	strings.write_string(b, sep)
	if a == f64(i64(a)) && a >= -2147483648 && a < 2147483648 do strings.write_i64(b, i64(a))
	else do strings.write_string(b, LDtk_JsNumber(a))
	strings.write_string(b, minified ? "}" : " }")
}

// An array of tile objects as JsonPretty writes it (one alone on one line, else one a line)
@(private="file")
TileText :: struct {
	px, src: [2]int,
	f, t: int,
	d: [2]int,
	nd: int,
	a: f64,
}

@(private="file")
writeTilesText :: proc(tiles: []TileText, minified: bool, indent: int) -> string {
	if len(tiles) == 0 do return "[]"
	b := strings.builder_make(0, len(tiles) * 80 + 64, context.temp_allocator)
	if minified || len(tiles) == 1 {
		strings.write_byte(&b, '[')
		for t, i in tiles {
			if i > 0 do strings.write_byte(&b, ',')
			d := t.d
			writeTileText(&b, minified, t.px, t.src, t.f, t.t, d[:t.nd], t.a)
		}
		strings.write_byte(&b, ']')
		return strings.to_string(b)
	}
	strings.write_string(&b, "[\n")
	for t, i in tiles {
		writeTabs(&b, indent + 1)
		d := t.d
		writeTileText(&b, minified, t.px, t.src, t.f, t.t, d[:t.nd], t.a)
		if i < len(tiles) - 1 do strings.write_string(&b, ",\n")
	}
	strings.write_byte(&b, '\n')
	writeTabs(&b, indent)
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// A Tiles layer's `gridTiles` as text (the same as LDtk_PrettyJson(LDtkLayer_GridTilesJson(...)))
LDtkLayer_GridTilesText :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, minified: bool, indent: int) -> string {
	td := LDtkLevel_LayerTileset(m, l)
	grid := m.defs[l.def].gridSize
	tiles := make([dynamic]TileText, context.temp_allocator)
	for stack, coord in l.tiles {
		for t in stack {
			src := td != nil ? LDtkTileset_Source(td, int(t.tile)) : [2]int{-1, -1}
			cx, cy := coord % max(l.cWid, 1), coord / max(l.cWid, 1)
			append(&tiles, TileText{px = {cx * grid, cy * grid}, src = src, f = int(t.flips), t = int(t.tile), d = {coord, 0}, nd = 1, a = 1})
		}
	}
	return writeTilesText(tiles[:], minified, indent)
}

// An auto layer's `autoLayerTiles` as text (the same as LDtk_PrettyJson(LDtkLayer_AutoTilesJson(...)))
LDtkLayer_AutoTilesText :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, minified: bool, indent: int) -> string {
	count := 0
	for cell in l.auto do count += len(cell)
	byRule := make(map[i32][dynamic]TileText, 64, context.temp_allocator)
	for cell, coord in l.auto do for t in cell {
		list, found := &byRule[t.rule]
		if !found {
			byRule[t.rule] = make([dynamic]TileText, context.temp_allocator)
			list = &byRule[t.rule]
		}
		append(list, TileText{px = {int(t.x), int(t.y)}, src = {int(t.srcX), int(t.srcY)}, f = int(t.flips), t = int(t.tile), d = {int(t.rule), coord}, nd = 2, a = t.alpha})
	}
	tiles := make([dynamic]TileText, 0, count, context.temp_allocator)
	for rule in LDtkRules_DisplayOrder(m, l) do if list, found := byRule[i32(rule.uid)]; found do append(&tiles, ..list[:])
	return writeTilesText(tiles[:], minified, indent)
}

// A layer's `intGridCsv` (LayerInstance.toJson; temp allocated)
LDtkLayer_IntGridJson :: proc(l: ^LDtkLayerData) -> LDtkJV {
	out := make([]LDtkJV, len(l.intGrid), context.temp_allocator)
	for v, i in l.intGrid do out[i] = i64(v)
	return LDtkJArray(out)
}

// A tile object as LDtk writes it: `{ "px": [x,y], "src": [x,y], "f": f, "t": t, "d": [...], "a": a }`
@(private="file")
tileJson :: proc(px, src: [2]int, f, t: int, d: []int, a: f64) -> LDtkJV {
	pair :: proc(v: [2]int) -> LDtkJV {
		out := make([]LDtkJV, 2, context.temp_allocator)
		out[0], out[1] = i64(v.x), i64(v.y)
		return LDtkJArray(out)
	}
	ds := make([]LDtkJV, len(d), context.temp_allocator)
	for v, i in d do ds[i] = i64(v)
	members := make([]LDtkJPair, 6, context.temp_allocator)
	members[0] = {"px", pair(px)}
	members[1] = {"src", pair(src)}
	members[2] = {"f", i64(f)}
	members[3] = {"t", i64(t)}
	members[4] = {"d", LDtkJArray(ds)}
	members[5] = {"a", a}
	return LDtkJObject(members)
}

/*
A Tiles layer's `gridTiles` as LDtk writes them (LayerInstance.toJson): by cell (LDtk's map of
cells iterates them in order), each cell's stack bottom first.
*/
LDtkLayer_GridTilesJson :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) -> LDtkJV {
	td := LDtkLevel_LayerTileset(m, l)
	grid := m.defs[l.def].gridSize
	out := make([dynamic]LDtkJV, context.temp_allocator)
	for stack, coord in l.tiles {
		for t in stack {
			src := td != nil ? LDtkTileset_Source(td, int(t.tile)) : [2]int{-1, -1}
			cx, cy := coord % max(l.cWid, 1), coord / max(l.cWid, 1)
			append(&out, tileJson({cx * grid, cy * grid}, src, int(t.flips), int(t.tile), {coord}, 1))
		}
	}
	return LDtkJArray(out[:])
}

/*
An auto layer's `autoLayerTiles` as LDtk writes them (LayerInstance.toJson): the active rules of
the groups applied here in display order (the last group first, its last rule first:
`LayerDef.iterateActiveRulesInDisplayOrder`), each rule's tiles by cell.
*/
LDtkLayer_AutoTilesJson :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) -> LDtkJV {
	// The tiles of each rule with their cells, by cell
	Kept :: struct {
		cell: int,
		tile: ^LDtkAutoTile,
	}
	byRule := make(map[i32][dynamic]Kept, 64, context.temp_allocator)
	for &cell, coord in l.auto do for &t in cell {
		list, found := &byRule[t.rule]
		if !found {
			byRule[t.rule] = make([dynamic]Kept, context.temp_allocator)
			list = &byRule[t.rule]
		}
		append(list, Kept{coord, &t})
	}
	out := make([dynamic]LDtkJV, context.temp_allocator)
	for rule in LDtkRules_DisplayOrder(m, l) {
		tiles, found := byRule[i32(rule.uid)]
		if !found do continue
		for k in tiles {
			t := k.tile
			append(&out, tileJson({int(t.x), int(t.y)}, {int(t.srcX), int(t.srcY)}, int(t.flips), int(t.tile), {rule.uid, k.cell}, t.alpha))
		}
	}
	return LDtkJArray(out[:])
}
