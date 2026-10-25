package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "gui:skald"

/*
Painting in the Level mode (phase 2 of TODO.md's "LDtk level editor"): LDtk's tools on the
focused level, as LDtk behaves (its Tool.hx, the tool/lt folder, SelectionTool, ResizeTool, Editor.hx).

- **Where:** the focused level (LDtk's level view), on the selected layer (`LevelMode.layerDef`).
  A press there goes to the tool (the world view, the Select tool on grid layers and presses
  outside levels keep panning and picking levels as before).
- **The model:** the focused level decoded (`LevelPaint_Model`: ldtk_level_model.odin), changed in
  place while a stroke runs (the auto-layer rules on the cells around each change:
  ldtk_rules.odin), drawn from it (level_layers_render.odin); the stroke's end writes the changed
  layers into the document (`LevelPaint_Commit`: one `LDtkDoc_Commit`, one undo step). The
  document is only re-read when something else changed it (undo, another edit, LDtk's save).
- **Buttons and keys** (LDtk's): left adds, right removes (erases); Shift + drag a rectangle,
  Shift + a quick click (0.22 s) fills; Alt + click picks what's under the pointer in any layer
  (its value, its tile with its flips, an entity: selected; Ctrl + Alt + drag copies it); the
  tool row's Rectangle, Fill, Eraser and Picker do the same without keys. X / Y flip the tile
  brush, R random tiles, G the grid (lines and snapping), Shift+A fades the other layers, Shift+T
  tile stacking, Shift+R auto-layer tiles shown, Del / Ctrl+D the selected entity, Esc cancels.
- **Entities:** Place puts the picked type at the pointer (its pivot on a cell's: LDtk's
  getPlacementX), then drags it (or resizes it when the type is resizable, as LDtk starts its
  resize tool); a press on an entity of the layer selects and moves it; the right button removes
  what's under it (a stroke: one step). The selected entity's handles resize it (ResizeTool), its
  point fields' points drag; a reference or a point picked from the Entities tab waits for a click
  on the canvas (`LevelPick`). Placing chains references (`autoChainRef`) as LDtk does.

Widgets: the palette's (view_level_palette.odin), the canvas's key `ldtk-map-Level`. Driver:
`level_paint`, `level_drag_world`, `level_palette_tiles`, checks `level value|tiles|random|flip|
grid|single_layer|stacking|auto_layers|stroke|pick|entity_type`, `ldtk_cell`, `ldtk_tiles`,
`ldtk_count`, `level_entities` (test_driver.odin; tests/ui/level_paint.script).
*/

// What a stroke does, press to release
LevelStrokeKind :: enum u8 {
	None,
	// Painting a grid layer (IntGrid values, tiles): cells, a rectangle, a fill
	Grid,
	// Removing entities and points (the right button, the Eraser): what's crossed
	Erase_Entities,
	// The selected entity's handle (ResizeTool)
	Resize,
	// A point of the selected entity's point field
	Point,
}

// A resize handle (LDtk's RectHandlePos)
LevelHandle :: enum u8 {
	Top,
	Bottom,
	Left,
	Right,
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
}

// A stroke on the focused level
LevelStroke :: struct {
	kind: LevelStrokeKind,
	mode: LDtkPaintMode,
	// Shift at the press or the Rectangle tool; the Fill tool
	rectangle, fill: bool,
	// The pressed with Alt (no fill on a quick Shift + Alt click, as LDtk)
	alt: bool,
	// The painted layer (its index in the model's layers)
	layer: int,
	// Cells: where it started, where the pointer last was
	origin, last: [2]int,
	// Pressed outside the level: nothing is painted until the pointer comes in (LDtk's
	// clickingOutsideBounds)
	outside: bool,
	started: time.Tick,
	paint: LDtkPaintStroke,
	// Something changed (the commit has work)
	changed: bool,
	// Removing entities: the iids crossed (owned)
	removed: [dynamic]string,
	// Resizing or dragging a point: the entity (owned), the handle, its rectangle as it goes
	// (x, y the entity's position, w, h its size), the field and the point's index
	entity: string,
	handle: LevelHandle,
	at: [2]int,
	size: [2]int,
	field, index: int,
}

// A reference or a point waiting for a click on the canvas (the Entities tab's Pick)
LevelPickKind :: enum u8 {
	None,
	Ref,
	Point,
}

// What a click on the canvas picks for the Entities tab
LevelPick :: struct {
	kind: LevelPickKind,
	// The entity (owned), its field (uid), the array index (-1: a new item)
	entity: string,
	field, index: int,
}

// The Level mode's painting state (`LevelMode.paint`)
LevelPaint :: struct {
	// The IntGrid value picked per layer (by definition uid; LDtk's selection memory)
	values: map[int]int,
	// The tiles picked per tileset (by uid; owned)
	tiles: map[int][dynamic]int,
	// The entity type Place puts (uid; -1: the first the layer takes)
	entityDef: int,
	flipX, flipY: bool,
	// Random tiles rather than the stamp (R, the Random tool)
	random: bool,
	// LDtk's settings, kept inverted so the zero value is LDtk's default: tile stacking on, the
	// grid shown and snapped to, auto-layer tiles shown
	noStacking, noGrid, hideAutoLayers: bool,
	// The other layers faded (LDtk's single layer mode, Shift+A)
	singleLayer: bool,
	stroke: LevelStroke,
	pick: LevelPick,
	// The entity placed last: the next placed one may be referenced from it (owned)
	chain: string,
}

// A palette pick: an IntGrid value of a layer
Level_Value_Picked :: struct {
	layer, value: int,
}

// A palette pick: tiles of a tileset (ids: only lives for the frame)
Level_Tiles_Picked :: struct {
	tileset: int,
	ids: []int,
}

// A palette pick: the entity type Place puts
Level_Entity_Type_Picked :: distinct int

// The Entities tab's Pick: a reference or a point to pick on the canvas (entity "" cancels)
Level_Pick_Started :: struct {
	kind: LevelPickKind,
	entity: string,
	field, index: int,
}

// Frees the painting state
LevelPaint_Destroy :: proc(p: ^LevelPaint) {
	delete(p.values)
	for _, ids in p.tiles do delete(ids)
	delete(p.tiles)
	strokeEnd(&p.stroke)
	delete(p.pick.entity)
	delete(p.chain)
	p^ = {}
}

@(private="file")
strokeEnd :: proc(s: ^LevelStroke) {
	LDtkPaintStroke_Destroy(&s.paint)
	for iid in s.removed do delete(iid)
	delete(s.removed)
	delete(s.entity)
	s^ = {}
}

// The focused level decoded for painting (package state: the view draws it)
@(private="file", thread_local)
paintModel: struct {
	m: LDtkLevelModel,
	ok: bool,
}

// Frees the painting model (tests, quitting, another project)
LevelPaint_DestroyModel :: proc() {
	if paintModel.ok do LDtkLevel_Destroy(&paintModel.m)
	paintModel = {}
}

/*
The focused level as painting has it: decoded from the document once per version (kept while a
stroke runs, which is ahead of the document).

Returns:
- The model, nil when no level is focused (or the document can't be read)
*/
LevelPaint_Model :: proc(state: ^State) -> ^LDtkLevelModel {
	if state.level.focus == "" do return nil
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	if doc == nil || doc.problem != "" do return nil
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	if level < 0 do return nil
	_, iid := LDtkDoc_LevelNames(doc, level)
	m := &paintModel.m
	if paintModel.ok && m.file == file && m.iid == iid && m.level == level {
		if m.version == doc.version do return m
		// The document changed under a stroke (an undo, LDtk's save): the stroke is dropped
	}
	if paintModel.ok do LDtkLevel_Destroy(m)
	paintModel.ok = false
	// A grid stroke was ahead of the old model: dropped (the others work on the document)
	if state.level.paint.stroke.kind == .Grid do strokeEnd(&state.level.paint.stroke)
	read, ok := LDtkLevel_Read(doc, file, level)
	if !ok do return nil
	paintModel.m = read
	paintModel.ok = true
	return m
}

// The model if it's the focused level's as of now, without reading anything (the view's)
LevelPaint_Current :: proc() -> ^LDtkLevelModel {
	return paintModel.ok ? &paintModel.m : nil
}

// The selected layer's instance in the model (nil: the level has none)
LevelPaint_Layer :: proc(state: ^State, m: ^LDtkLevelModel) -> (^LDtkLayerData, int) {
	if m == nil do return nil, -1
	doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
	def := LevelMode_LayerDef(state, doc)
	if def < 0 do return nil, -1
	uid := Json_Int(LDtkDoc_Main(doc), Json_Get(LDtkDoc_Main(doc), def, "uid"), -1)
	for &l, i in m.layers do if m.defs[l.def].uid == uid do return &l, i
	return nil, -1
}

// A world point in the focused level's pixels
@(private="file")
levelPixel :: proc(state: ^State, world: [2]f32) -> [2]f32 {
	doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	if level < 0 do return world
	r := LDtkDoc_LevelRect(doc, level)
	return world - {f32(r[0]), f32(r[1])}
}

// A layer's total offset (the instance's and its definition's)
LDtkLayer_Offset :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) -> [2]int {
	return l.pxOffset + m.defs[l.def].pxOffset
}

// The layer cell under a level pixel (LDtk's Coords.cx: floored)
LDtkLayer_CellAt :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData, levelPx: [2]f32) -> [2]int {
	grid := f32(m.defs[l.def].gridSize)
	off := LDtkLayer_Offset(m, l)
	return {int(math.floor((levelPx.x - f32(off.x)) / grid)), int(math.floor((levelPx.y - f32(off.y)) / grid))}
}

// The cell under a world point in the selected layer of the focused level (false: no such layer)
LevelPaint_CellAt :: proc(state: ^State, world: [2]f32) -> ([2]int, bool) {
	m := LevelPaint_Current()
	l, _ := LevelPaint_Layer(state, m)
	if l == nil do return {}, false
	return LDtkLayer_CellAt(m, l, levelPixel(state, world)), true
}

// The IntGrid value painted on a layer (LDtk's IntGridTool: the picked one, else the first value; -1 none)
LevelPaint_Value :: proc(state: ^State, m: ^LDtkLevelModel, l: ^LDtkLayerData) -> int {
	d := &m.defs[l.def]
	if v, found := state.level.paint.values[d.uid]; found && LDtkLayerInfo_Value(d, v) != nil do return v
	return len(d.values) > 0 ? d.values[0].value : -1
}

// The tile brush of a layer: the tiles picked in its tileset (else its first tile), the flips, the options
LevelPaint_Brush :: proc(state: ^State, m: ^LDtkLevelModel, l: ^LDtkLayerData) -> LDtkTileBrush {
	p := &state.level.paint
	td := LDtkLevel_LayerTileset(m, l)
	brush := LDtkTileBrush{random = p.random, stacking = !p.noStacking, flips = (p.flipX ? 1 : 0) | (p.flipY ? 2 : 0)}
	if td == nil do return brush
	if ids, found := p.tiles[td.uid]; found && len(ids) > 0 {
		brush.ids = ids[:]
	} else {
		@(static, rodata) FIRST := [1]int{0}
		brush.ids = FIRST[:]
	}
	return brush
}

// Whether a layer's instance shows in its level (its eye: LDtk paints only visible layers)
@(private="file")
layerShown :: proc(l: ^LDtkLayerData) -> bool {
	return l.visible
}

// Whether a level pixel is inside the level (LDtk's Level.inBounds)
@(private="file")
inLevel :: proc(m: ^LDtkLevelModel, p: [2]f32) -> bool {
	return p.x >= 0 && p.y >= 0 && p.x < f32(m.pxWid) && p.y < f32(m.pxHei)
}

// ---------------------------------------------------------------------------------------------
// Entities: what's under the pointer (LDtk's EntityInstance.isOver, Editor.getGenericLevelElementAt)

// An entity of the focused level as hit-testing needs it
LevelEntityBox :: struct {
	iid: string,
	// Its layer definition's uid, its entity definition's uid and node
	layer, defUid, def: int,
	// Its position (layer pixels), size, pivot; the layer's offset
	at: [2]int,
	size: [2]int,
	pivot: [2]f64,
	offset: [2]int,
	ellipse, hollow, resizableX, resizableY, keepAspect: bool,
	minSize, maxSize: [2]int,
}

// The entities of a level (temp allocated), layers top first as the file has them
LevelPaint_Entities :: proc(doc: ^LDtkDoc, level: int) -> []LevelEntityBox {
	out := make([dynamic]LevelEntityBox, context.temp_allocator)
	main := LDtkDoc_Main(doc)
	file, layers := LDtkDoc_LayerInstances(doc, level)
	json := LDtkDoc_Json(doc, file)
	for li in Json_Items(json, layers) {
		layerUid := Json_Int(json, Json_Get(json, li, "layerDefUid"), -1)
		ld := LDtkDoc_DefByUid(doc, "layers", layerUid)
		offset := [2]int{Json_Int(json, Json_Get(json, li, "pxOffsetX")) + Json_Int(main, Json_Get(main, ld, "pxOffsetX")), Json_Int(json, Json_Get(json, li, "pxOffsetY")) + Json_Int(main, Json_Get(main, ld, "pxOffsetY"))}
		for e in Json_Items(json, Json_Get(json, li, "entityInstances")) {
			defUid := Json_Int(json, Json_Get(json, e, "defUid"), -1)
			def := LDtkDoc_DefByUid(doc, "entities", defUid)
			px := Json_Get(json, e, "px")
			b := LevelEntityBox{
				iid = Json_String(json, Json_Get(json, e, "iid")),
				layer = layerUid, defUid = defUid, def = def,
				at = {Json_Int(json, Json_At(json, px, 0)), Json_Int(json, Json_At(json, px, 1))},
				size = {Json_Int(json, Json_Get(json, e, "width"), 16), Json_Int(json, Json_Get(json, e, "height"), 16)},
				pivot = {Json_Float(main, Json_Get(main, def, "pivotX"), 0.5), Json_Float(main, Json_Get(main, def, "pivotY"), 0.5)},
				offset = offset,
				ellipse = Json_String(main, Json_Get(main, def, "renderMode")) == "Ellipse",
				hollow = Json_Bool(main, Json_Get(main, def, "hollow")),
				resizableX = Json_Bool(main, Json_Get(main, def, "resizableX")),
				resizableY = Json_Bool(main, Json_Get(main, def, "resizableY")),
				keepAspect = Json_Bool(main, Json_Get(main, def, "keepAspectRatio")),
				minSize = {Json_Int(main, Json_Get(main, def, "minWidth"), 0), Json_Int(main, Json_Get(main, def, "minHeight"), 0)},
				maxSize = {Json_Int(main, Json_Get(main, def, "maxWidth"), 0), Json_Int(main, Json_Get(main, def, "maxHeight"), 0)},
			}
			append(&out, b)
		}
	}
	return out[:]
}

// An entity's left and top (EntityInstance.left / top: rounded)
LevelEntityBox_TopLeft :: proc(b: LevelEntityBox) -> [2]int {
	return {int(math.round(f64(b.at.x) - f64(b.size.x) * b.pivot.x)), int(math.round(f64(b.at.y) - f64(b.size.y) * b.pivot.y))}
}

// Whether a layer pixel is over an entity (EntityInstance.isOver)
LevelEntityBox_IsOver :: proc(b: LevelEntityBox, p: [2]f64) -> bool {
	SHAPE_PAD :: 3
	EDGE_PAD :: 4
	w, h := f64(b.size.x), f64(b.size.y)
	if abs(p.x - f64(b.at.x)) > w + EDGE_PAD * 2 || abs(p.y - f64(b.at.y)) > h + EDGE_PAD * 2 do return false
	tl := LevelEntityBox_TopLeft(b)
	left, top := f64(tl.x), f64(tl.y)
	right, bottom := left + w, top + h
	center := [2]f64{math.round(f64(b.at.x) + (0.5 - b.pivot.x) * w), math.round(f64(b.at.y) + (0.5 - b.pivot.y) * h)}
	pow2 :: proc(v: f64) -> f64 { return v * v }
	switch {
	case b.ellipse && b.hollow:
		rxIn2, rxOut2 := pow2(w * 0.5 - EDGE_PAD), pow2(w * 0.5 + EDGE_PAD)
		ryIn2, ryOut2 := pow2(h * 0.5 - EDGE_PAD), pow2(h * 0.5 + EDGE_PAD)
		return pow2(p.x - center.x) * ryIn2 + pow2(p.y - center.y) * rxIn2 > rxIn2 * ryIn2 && pow2(p.x - center.x) * ryOut2 + pow2(p.y - center.y) * rxOut2 <= rxOut2 * ryOut2
	case b.ellipse:
		rx2, ry2 := pow2(w * 0.5 + SHAPE_PAD), pow2(h * 0.5 + SHAPE_PAD)
		return pow2(p.x - center.x) * ry2 + pow2(p.y - center.y) * rx2 <= rx2 * ry2
	case b.hollow:
		return p.x >= left - EDGE_PAD && p.x <= right + EDGE_PAD && p.y >= top - EDGE_PAD && p.y <= bottom + EDGE_PAD &&
			!(p.x >= left + EDGE_PAD && p.x <= right - EDGE_PAD && p.y >= top + EDGE_PAD && p.y <= bottom - EDGE_PAD)
	}
	return p.x >= left - SHAPE_PAD && p.x <= right + SHAPE_PAD && p.y >= top - SHAPE_PAD && p.y <= bottom + SHAPE_PAD
}

/*
The entity under a level pixel (the last one of a layer that's over it, as LDtk picks): in one
layer (`layer`, a layer definition's uid), or in any (-1: the topmost layer wins).

Returns:
- Its box, false when there's none
*/
LevelPaint_EntityAt :: proc(doc: ^LDtkDoc, level, layer: int, levelPx: [2]f32, skip: []string = nil) -> (LevelEntityBox, bool) {
	found: LevelEntityBox
	any := false
	// The file's order: layers top first; in a layer, the last entity over the point wins
	for b in LevelPaint_Entities(doc, level) {
		if layer >= 0 && b.layer != layer do continue
		if any && b.layer != found.layer do continue
		skipped := false
		for s in skip do if s == b.iid do skipped = true
		if skipped do continue
		p := [2]f64{f64(levelPx.x) - f64(b.offset.x), f64(levelPx.y) - f64(b.offset.y)}
		if LevelEntityBox_IsOver(b, p) do found, any = b, true
	}
	return found, any
}

// The handle positions of an entity being resized (ResizeTool.getHandleX / Y), level pixels
LevelPaint_HandleAt :: proc(b: LevelEntityBox, h: LevelHandle) -> [2]f32 {
	RADIUS :: 5
	tl := LevelEntityBox_TopLeft(b)
	r := [4]f32{f32(tl.x + b.offset.x), f32(tl.y + b.offset.y), f32(b.size.x), f32(b.size.y)}
	x, y: f32
	switch h {
	case .Top, .Bottom:                     x = r[0] + r[2] * 0.5
	case .Left, .Top_Left, .Bottom_Left:    x = r[0] - RADIUS
	case .Right, .Top_Right, .Bottom_Right: x = r[0] + r[2] - 1 + RADIUS
	}
	switch h {
	case .Left, .Right:                     y = r[1] + r[3] * 0.5
	case .Top, .Top_Left, .Top_Right:       y = r[1] - RADIUS
	case .Bottom, .Bottom_Left, .Bottom_Right: y = r[1] + r[3] + RADIUS
	}
	return {x, y}
}

// Whether a handle works for an entity (ResizeTool.isHandleActive)
LevelPaint_HandleActive :: proc(b: LevelEntityBox, h: LevelHandle) -> bool {
	if !b.resizableX && h != .Top && h != .Bottom do return false
	if !b.resizableY && h != .Left && h != .Right do return false
	return b.resizableX || b.resizableY
}

// The selected entity's handle under a level pixel (`radius`: level pixels), false when none
@(private="file")
handleUnder :: proc(state: ^State, doc: ^LDtkDoc, level: int, p: [2]f32, radius: f32) -> (LevelEntityBox, LevelHandle, bool) {
	if state.level.entity == "" do return {}, {}, false
	for b in LevelPaint_Entities(doc, level) {
		if b.iid != state.level.entity do continue
		for h in LevelHandle {
			if !LevelPaint_HandleActive(b, h) do continue
			c := LevelPaint_HandleAt(b, h)
			d := p - c
			if math.sqrt(d.x * d.x + d.y * d.y) <= radius do return b, h, true
		}
	}
	return {}, {}, false
}

// A point of an entity's point fields (level pixels at its cell's center)
LevelPoint :: struct {
	field, index: int,
	cell: [2]int,
	center: [2]f32,
}

// The points of an entity's point fields (temp allocated), in its layer's cells
LevelPaint_Points :: proc(doc: ^LDtkDoc, iid: string) -> []LevelPoint {
	out := make([dynamic]LevelPoint, context.temp_allocator)
	e, found := LDtkDoc_FindEntity(doc, iid)
	if !found do return out[:]
	main := LDtkDoc_Main(doc)
	json := LDtkDoc_Json(doc, e.file)
	grid := f32(max(Json_Int(json, Json_Get(json, e.layer, "__gridSize"), 16), 1))
	ld := LDtkDoc_DefByUid(doc, "layers", Json_Int(json, Json_Get(json, e.layer, "layerDefUid"), -1))
	off := [2]f32{f32(Json_Int(json, Json_Get(json, e.layer, "pxOffsetX")) + Json_Int(main, Json_Get(main, ld, "pxOffsetX"))), f32(Json_Int(json, Json_Get(json, e.layer, "pxOffsetY")) + Json_Int(main, Json_Get(main, ld, "pxOffsetY")))}
	for fi in Json_Items(json, Json_Get(json, e.node, "fieldInstances")) {
		t := Json_String(json, Json_Get(json, fi, "__type"))
		if t != "Point" && t != "Array<Point>" do continue
		field := Json_Int(json, Json_Get(json, fi, "defUid"), -1)
		value := Json_Get(json, fi, "__value")
		items := t == "Point" ? []int{value} : Json_Items(json, value)
		for item, i in items {
			if Json_Kind(json, item) != .Object do continue
			c := [2]int{Json_Int(json, Json_Get(json, item, "cx")), Json_Int(json, Json_Get(json, item, "cy"))}
			append(&out, LevelPoint{field, t == "Point" ? 0 : i, c, off + ([2]f32{f32(c.x), f32(c.y)} + 0.5) * grid})
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------------------------
// Presses, moves, releases

// What a press on the focused level does (worked out once: History_Classify asks too)
LevelPressKind :: enum u8 {
	// Not painting: the canvas's own press (select, move, pan)
	None,
	// A grid stroke, a fill, an entity removal stroke, a resize, a point drag
	Stroke,
	// Placing an entity (an edit at once)
	Place,
	// A pick for the Entities tab (an edit at once), or its cancel
	Pick,
	Pick_Cancel,
	// Alt / the Picker: what's under the pointer is picked (no edit)
	Select_Pick,
	// An entity of the layer pressed with the Place tool: selected and moved (Ctrl + Alt: copied)
	Move_Entity,
	// Nothing (a hidden layer, an old file: why in `problem`)
	Refused,
}

// What a press does
LevelPressPlan :: struct {
	kind: LevelPressKind,
	stroke: LevelStrokeKind,
	// The entity under the pointer (temp), the handle or point pressed
	entity: LevelEntityBox,
	handle: LevelHandle,
	point: LevelPoint,
	problem: string,
}

// Whether a tool paints (anything but Select)
@(private="file")
painting :: proc(tool: LevelTool) -> bool {
	return tool != .Select
}

/*
What a press on the canvas does while a level is focused: the tools' presses on its selected
layer (see the file's doc block), else `.None` (the canvas's select / move / pan).
*/
LevelPaint_PlanPress :: proc(state: ^State, v: Level_Canvas_Pressed) -> LevelPressPlan {
	if v.pan || state.level.focus == "" do return {}
	doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
	if doc == nil || doc.problem != "" do return {}
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	if level < 0 do return {}
	p := levelPixel(state, v.world)
	rect := LDtkDoc_LevelRect(doc, level)
	insideLevel := p.x >= 0 && p.y >= 0 && f64(p.x) < rect[2] && f64(p.y) < rect[3]
	paint := &state.level.paint
	zoom := max(state.level.view.zoom, 0.01)
	// A pick for the Entities tab
	if paint.pick.kind != .None {
		if v.right do return {kind = .Pick_Cancel}
		switch paint.pick.kind {
		case .None:
		case .Ref:
			if b, found := LevelPaint_EntityAt(doc, level, -1, p); found do return {kind = .Pick, entity = b}
			return {kind = .Pick_Cancel}
		case .Point:
			if insideLevel do return {kind = .Pick}
			return {kind = .Pick_Cancel}
		}
	}
	// The selected entity's handles and points (any tool)
	if !v.right {
		if b, h, found := handleUnder(state, doc, level, p, max(5, 6 / zoom)); found do return {kind = .Stroke, stroke = .Resize, entity = b, handle = h}
		if state.level.entity != "" {
			for pt in LevelPaint_Points(doc, state.level.entity) {
				d := p - pt.center
				if math.sqrt(d.x * d.x + d.y * d.y) <= max(4, 6 / zoom) do return {kind = .Stroke, stroke = .Point, point = pt}
			}
		}
	}
	// Alt: LDtk's selection (pick what's under the pointer; Ctrl + Alt drags a copy of an entity)
	if v.alt {
		if !insideLevel && !v.right do return {}
		if b, found := LevelPaint_EntityAt(doc, level, -1, p); found do return {kind = .Move_Entity, entity = b}
		return {kind = .Select_Pick}
	}
	tool := state.level.tool
	layerType := LevelMode_LayerType(state)
	if !painting(tool) && !v.right do return {}
	if tool == .Select && v.right do return {}
	if !insideLevel && (layerType == "Entities" || tool == .Picker || tool == .Fill) do return {}
	m := LevelPaint_Model(state)
	l, _ := LevelPaint_Layer(state, m)
	if l == nil do return {}
	if !layerShown(l) do return {kind = .Refused, problem = "This layer is hidden in this level: show it (its eye) to paint it"}
	if old := LDtkOps_TooOld(doc); old != "" do return {kind = .Refused, problem = old}
	if tool == .Picker do return {kind = .Select_Pick}
	switch layerType {
	case "IntGrid", "Tiles":
		if layerType == "Tiles" && LDtkLevel_LayerTileset(m, l) == nil do return {kind = .Refused, problem = "This layer has no tileset: pick one in LDtk's Layers panel"}
		if layerType == "IntGrid" && !v.right && tool != .Eraser && LevelPaint_Value(state, m, l) <= 0 do return {kind = .Refused, problem = "This IntGrid layer has no values: add one in its Layers tab"}
		return {kind = .Stroke, stroke = .Grid}
	case "Entities":
		under, found := LevelPaint_EntityAt(doc, level, m.defs[l.def].uid, p)
		if v.right || tool == .Eraser do return {kind = .Stroke, stroke = .Erase_Entities}
		if found do return {kind = .Move_Entity, entity = under}
		if levelPlaceDef(state, doc, m, l) < 0 do return {kind = .Refused, problem = "No entity type to place: add one in the Entities tab"}
		return {kind = .Place}
	}
	return {}
}

/*
A press on the focused level that goes to the tools.

Returns:
- Whether the press was the tools' (else the canvas's: select, move, pan)
*/
LevelPaint_Press :: proc(state: ^State, v: Level_Canvas_Pressed) -> bool {
	plan := LevelPaint_PlanPress(state, v)
	doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
	switch plan.kind {
	case .None:
		return false
	case .Refused:
		setOwned(&state.level.problem, plan.problem)
		return true
	case .Pick_Cancel:
		levelPickCancel(state)
		return true
	case .Pick:
		levelPickApply(state, doc, v, plan)
		return true
	case .Select_Pick:
		levelSelectPick(state, doc, levelPixel(state, v.world))
		return true
	case .Move_Entity:
		// LDtk's EntityTool: a press on an entity chains a reference to it, then selects and moves
		// it (the iid copied: an edit reads the document again)
		iid := strings.clone(plan.entity.iid, context.temp_allocator)
		if state.level.tool == .Pencil && !v.alt do levelChainTo(state, iid)
		levelSelectEntity(state, iid, center = false)
		// Its type is Place's (LDtk's SelectionTool: the entity tool's value)
		state.level.paint.entityDef = plan.entity.defUid
		drag := &state.level.drag
		delete(drag.target)
		drag^ = {mode = .Entity, target = strings.clone(iid), start = v.world, origin = {f32(plan.entity.at.x), f32(plan.entity.at.y)}, free = v.free, copy = v.alt && v.ctrl}
		return true
	case .Place:
		levelPlace(state, doc, v)
		return true
	case .Stroke:
		levelStrokeStart(state, doc, v, plan)
		return true
	}
	return false
}

// Starts a stroke
@(private="file")
levelStrokeStart :: proc(state: ^State, doc: ^LDtkDoc, v: Level_Canvas_Pressed, plan: LevelPressPlan) {
	paint := &state.level.paint
	strokeEnd(&paint.stroke)
	setOwned(&state.level.problem, "")
	s := &paint.stroke
	s.kind = plan.stroke
	s.started = time.tick_now()
	s.alt = v.alt
	switch plan.stroke {
	case .None:
	case .Grid:
		m := LevelPaint_Model(state)
		l, index := LevelPaint_Layer(state, m)
		if l == nil {
			s^ = {}
			return
		}
		tool := state.level.tool
		s.mode = v.right || tool == .Eraser ? .Remove : .Add
		s.rectangle = v.free || tool == .Rectangle
		s.fill = tool == .Fill
		s.layer = index
		p := levelPixel(state, v.world)
		s.origin = LDtkLayer_CellAt(m, l, p)
		s.last = s.origin
		s.outside = !inLevel(m, p)
		s.paint = LDtkPaintStroke_Make(u64(time.tick_now()._nsec))
		if s.fill {
			levelGridFill(state, m, l)
		} else if !s.rectangle && !s.outside {
			levelGridLine(state, m, l, s.origin, s.origin)
		}
	case .Erase_Entities:
		levelEraseAt(state, doc, levelPixel(state, v.world))
	case .Resize:
		b := plan.entity
		s.entity = strings.clone(b.iid)
		s.handle = plan.handle
		s.at, s.size = b.at, b.size
	case .Point:
		s.entity = strings.clone(state.level.entity)
		s.field, s.index = plan.point.field, plan.point.index
		s.at = plan.point.cell
	}
}

// A stroke's segment of grid cells, with the rules run around what changed
@(private="file")
levelGridLine :: proc(state: ^State, m: ^LDtkLevelModel, l: ^LDtkLayerData, from, to: [2]int) {
	s := &state.level.paint.stroke
	changed := false
	switch m.defs[l.def].kind {
	case .IntGrid:
		changed = LDtkPaint_IntGridLine(m, l, from, to, LevelPaint_Value(state, m, l), s.mode)
	case .Tiles:
		changed = LDtkPaint_TilesLine(m, l, from, to, LevelPaint_Brush(state, m, l), s.mode, &s.paint)
	case .Entities, .AutoLayer:
	}
	if changed do levelAfterChange(state, m, l)
}

// The rules around a layer's changed cells (LDtk's invalidateLayerArea then applyAllRulesAt)
@(private="file")
levelAfterChange :: proc(state: ^State, m: ^LDtkLevelModel, l: ^LDtkLayerData) {
	state.level.paint.stroke.changed = true
	if !l.editedAny do return
	r := l.edited
	l.editedAny = false
	LDtkRules_AfterChange(m, l, r[0], r[1], r[2], r[3])
}

// A fill at the stroke's first cell
@(private="file")
levelGridFill :: proc(state: ^State, m: ^LDtkLevelModel, l: ^LDtkLayerData) {
	s := &state.level.paint.stroke
	c := s.origin
	changed := false
	switch m.defs[l.def].kind {
	case .IntGrid: changed = LDtkPaint_IntGridFill(m, l, c.x, c.y, LevelPaint_Value(state, m, l), s.mode)
	case .Tiles:   changed = LDtkPaint_TilesFill(m, l, c.x, c.y, LevelPaint_Brush(state, m, l), s.mode, &s.paint)
	case .Entities, .AutoLayer:
	}
	if changed do levelAfterChange(state, m, l)
}

// The pointer moved during a stroke (true: it was the tools')
LevelPaint_Moved :: proc(state: ^State, v: Level_Canvas_Moved) -> bool {
	s := &state.level.paint.stroke
	switch s.kind {
	case .None:
		return false
	case .Grid:
		m := LevelPaint_Model(state)
		if m == nil || s.layer >= len(m.layers) do return true
		l := &m.layers[s.layer]
		p := levelPixel(state, v.world)
		cell := LDtkLayer_CellAt(m, l, p)
		if s.outside && inLevel(m, p) do s.outside = false
		if !s.rectangle && !s.fill && !s.outside && cell != s.last do levelGridLine(state, m, l, s.last, cell)
		s.last = cell
	case .Erase_Entities:
		doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
		if doc != nil do levelEraseAt(state, doc, levelPixel(state, v.world))
	case .Resize:
		levelResizeMove(state, levelPixel(state, v.world))
	case .Point:
		m := LevelPaint_Model(state)
		doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
		e, found := LDtkDoc_FindEntity(doc, s.entity)
		if m == nil || !found do return true
		json := LDtkDoc_Json(doc, e.file)
		for &l in m.layers do if l.iid == Json_String(json, Json_Get(json, e.layer, "iid")) do s.at = LDtkLayer_CellAt(m, &l, levelPixel(state, v.world))
	}
	return true
}

/*
The stroke's end (true: there was one): a rectangle, a quick Shift + click's fill, the last
segment; then the document gets the changed layers (one undo step), or the removals, the
resize, the point.
*/
LevelPaint_Released :: proc(state: ^State) -> bool {
	paint := &state.level.paint
	s := &paint.stroke
	defer strokeEnd(s)
	file := LevelMode_File(state)
	switch s.kind {
	case .None:
		return false
	case .Grid:
		m := LevelPaint_Model(state)
		if m == nil || s.layer >= len(m.layers) do return true
		l := &m.layers[s.layer]
		quick := time.duration_seconds(time.tick_since(s.started)) <= 0.22
		switch {
		case s.fill:
		case s.rectangle && s.origin == s.last && quick && !s.alt:
			// LDtk: Shift + a quick click fills
			levelGridFill(state, m, l)
		case s.rectangle && !s.outside:
			left, right := min(s.origin.x, s.last.x), max(s.origin.x, s.last.x)
			top, bottom := min(s.origin.y, s.last.y), max(s.origin.y, s.last.y)
			changed := false
			switch m.defs[l.def].kind {
			case .IntGrid: changed = LDtkPaint_IntGridRect(m, l, left, top, right, bottom, LevelPaint_Value(state, m, l), s.mode)
			case .Tiles:   changed = LDtkPaint_TilesRect(m, l, left, top, right, bottom, LevelPaint_Brush(state, m, l), s.mode, &s.paint)
			case .Entities, .AutoLayer:
			}
			if changed do levelAfterChange(state, m, l)
		}
		if s.changed do if problem := LevelPaint_Commit(state); problem != "" do logLine(state, .Warning, fmt.aprintf("Not painted: %s", problem))
	case .Erase_Entities:
		for iid in s.removed do levelApplyEdit(state, {op = .Entity_Removed, file = file, entity = iid})
		if state.level.entity != "" do for iid in s.removed do if iid == state.level.entity do setOwned(&state.level.entity, "")
	case .Resize:
		levelApplyEdit(state, {op = .Entity_Resized, file = file, entity = s.entity, number = f64(s.at.x), number2 = f64(s.at.y), number3 = f64(s.size.x), number4 = f64(s.size.y)})
	case .Point:
		levelApplyEdit(state, {op = .Entity_Point, file = file, entity = s.entity, field = s.field, index = s.index, number = f64(s.at.x), number2 = f64(s.at.y)})
	}
	return true
}

/*
Writes the focused level's changed layers into the document (`intGridCsv`, `gridTiles`,
`autoLayerTiles` as LDtk writes them): the stroke's undo step. The model is then the document's
version (nothing is read again).

Returns:
- "" or why nothing changed
*/
LevelPaint_Commit :: proc(state: ^State) -> string {
	m := LevelPaint_Current()
	if m == nil do return ""
	doc := LDtkDoc_Get(state.project.rootPath, m.file)
	if doc == nil || doc.version != m.version do return "the file changed meanwhile"
	patches := LDtkLevel_Patches(m, doc)
	for &l in m.layers do l.changed = {}
	if LDtkPatches_Empty(&patches) do return ""
	if problem := LDtkDoc_Commit(doc, &patches); problem != "" {
		LevelPaint_DestroyModel()
		return problem
	}
	m.version = doc.version
	return ""
}

// Removes what's under a level pixel in the selected Entities layer (an entity, or a point of
// the selected entity): kept for the release (one step)
@(private="file")
levelEraseAt :: proc(state: ^State, doc: ^LDtkDoc, p: [2]f32) {
	s := &state.level.paint.stroke
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	m := LevelPaint_Model(state)
	l, _ := LevelPaint_Layer(state, m)
	if l == nil || level < 0 do return
	if b, found := LevelPaint_EntityAt(doc, level, m.defs[l.def].uid, p, s.removed[:]); found {
		append(&s.removed, strings.clone(b.iid))
		s.changed = true
	}
}

// The resize's new rectangle from the pointer (ResizeTool.onMouseMove)
@(private="file")
levelResizeMove :: proc(state: ^State, p: [2]f32) {
	s := &state.level.paint.stroke
	doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	b: LevelEntityBox
	found := false
	for e in LevelPaint_Entities(doc, level) do if e.iid == s.entity do b, found = e, true
	if !found do return
	RADIUS :: 5
	main := LDtkDoc_Main(doc)
	defW, defH := Json_Int(main, Json_Get(main, b.def, "width"), 16), Json_Int(main, Json_Get(main, b.def, "height"), 16)
	// The rectangle as it is now (the stroke's), in level pixels
	b.at, b.size = s.at, s.size
	tl := LevelEntityBox_TopLeft(b)
	rx, ry := f32(tl.x + b.offset.x), f32(tl.y + b.offset.y)
	rw, rh := f32(b.size.x), f32(b.size.y)
	snap := f32(1)
	if !state.level.paint.noGrid {
		m := LevelPaint_Model(state)
		if l := LevelPaint_LayerByDef(m, b.layer); l != nil do snap = f32(m.defs[l.def].gridSize)
	}
	newW, newH := rw, rh
	#partial switch s.handle {
	case .Left, .Top_Left, .Bottom_Left:    newW = (rx + rw) - RADIUS - p.x
	case .Right, .Top_Right, .Bottom_Right: newW = p.x - rx - RADIUS
	}
	if newW != rw do newW = math.round(newW / snap) * snap
	#partial switch s.handle {
	case .Top, .Top_Left, .Top_Right:          newH = (ry + rh) - RADIUS - p.y
	case .Bottom, .Bottom_Left, .Bottom_Right: newH = p.y - ry - RADIUS
	}
	if newH != rh do newH = math.round(newH / snap) * snap
	if b.resizableX && b.resizableY && b.keepAspect {
		ar := f32(defH) / f32(max(defW, 1))
		#partial switch s.handle {
		case .Top, .Bottom: newW = math.round(newH / ar)
		case:               newH = math.round(newW * ar)
		}
	}
	w, h := int(newW), int(newH)
	if b.minSize.x > 0 do w = max(b.minSize.x, w)
	if b.maxSize.x > 0 do w = min(b.maxSize.x, w)
	if b.minSize.y > 0 do h = max(b.minSize.y, h)
	if b.maxSize.y > 0 do h = min(b.maxSize.y, h)
	w, h = max(1, w), max(1, h)
	oldW, oldH := s.size.x, s.size.y
	#partial switch s.handle {
	case .Left, .Top_Left, .Bottom_Left:    if b.pivot.x == 0 do s.at.x -= w - oldW
	case .Right, .Top_Right, .Bottom_Right: if b.pivot.x == 1 do s.at.x += w - oldW
	}
	#partial switch s.handle {
	case .Top, .Top_Left, .Top_Right:          if b.pivot.y == 0 do s.at.y -= h - oldH
	case .Bottom, .Bottom_Left, .Bottom_Right: if b.pivot.y == 1 do s.at.y += h - oldH
	}
	s.size = {w, h}
}

// A layer instance by its definition's uid (nil: none)
LevelPaint_LayerByDef :: proc(m: ^LDtkLevelModel, uid: int) -> ^LDtkLayerData {
	if m == nil do return nil
	return LDtkLevel_LayerByDef(m, uid)
}

// The entity type Place puts on a layer (LDtk's EntityTool.getDefaultValue: the picked one, else
// the first the layer's tags allow; -1 none)
@(private="file")
levelPlaceDef :: proc(state: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel, l: ^LDtkLayerData) -> int {
	main := LDtkDoc_Main(doc)
	if state.level.paint.entityDef >= 0 && LDtkDoc_DefByUid(doc, "entities", state.level.paint.entityDef) >= 0 do return state.level.paint.entityDef
	ld := LDtkDoc_DefByUid(doc, "layers", m.defs[l.def].uid)
	return LevelPaint_FirstAllowed(doc, ld, main)
}

// The first entity type a layer's tags allow (-1 none)
LevelPaint_FirstAllowed :: proc(doc: ^LDtkDoc, layerDef: int, main: ^JsonDoc) -> int {
	for ed in Json_Items(main, LDtkDoc_Defs(doc, "entities")) {
		if LevelPaint_LayerTakes(main, layerDef, ed) do return Json_Int(main, Json_Get(main, ed, "uid"), -1)
	}
	return -1
}

// Whether an Entities layer takes an entity type (its required and excluded tags)
LevelPaint_LayerTakes :: proc(main: ^JsonDoc, layerDef, entityDef: int) -> bool {
	required := Json_Items(main, Json_Get(main, layerDef, "requiredTags"))
	excluded := Json_Items(main, Json_Get(main, layerDef, "excludedTags"))
	tags := Json_Items(main, Json_Get(main, entityDef, "tags"))
	has :: proc(main: ^JsonDoc, tags, list: []int) -> bool {
		for t in tags do for x in list do if Json_String(main, t) == Json_String(main, x) do return true
		return false
	}
	if len(required) > 0 && !has(main, tags, required) do return false
	if len(excluded) > 0 && has(main, tags, excluded) do return false
	return true
}

// Places the picked entity type at the press (LDtk's EntityTool: its pivot on the cell's when
// the grid is on), then drags or resizes it
@(private="file")
levelPlace :: proc(state: ^State, docBefore: ^LDtkDoc, v: Level_Canvas_Pressed) {
	doc := docBefore
	m := LevelPaint_Model(state)
	l, _ := LevelPaint_Layer(state, m)
	if l == nil do return
	defUid := levelPlaceDef(state, doc, m, l)
	main := LDtkDoc_Main(doc)
	def := LDtkDoc_DefByUid(doc, "entities", defUid)
	p := levelPixel(state, v.world)
	grid := f64(m.defs[l.def].gridSize)
	at := [2]int{int(p.x), int(p.y)}
	if !state.level.paint.noGrid {
		cell := LDtkLayer_CellAt(m, l, p)
		pivot := [2]f64{Json_Float(main, Json_Get(main, def, "pivotX"), 0.5), Json_Float(main, Json_Get(main, def, "pivotY"), 0.5)}
		at = {int(math.round((f64(cell.x) + pivot.x) * grid)), int(math.round((f64(cell.y) + pivot.y) * grid))}
	}
	// What's needed of the type after the edit (which reads the document again: `main` goes)
	resizableX, resizableY := Json_Bool(main, Json_Get(main, def, "resizableX")), Json_Bool(main, Json_Get(main, def, "resizableY"))
	w := Json_Int(main, Json_Get(main, def, "width"), 16)
	h := Json_Int(main, Json_Get(main, def, "height"), 16)
	iid := LDtk_NewIid()
	file := LevelMode_File(state)
	_, levelIid := LDtkDoc_LevelNames(doc, LDtkDoc_FindLevel(doc, state.level.focus))
	prev := strings.clone(state.level.paint.chain, context.temp_allocator)
	levelApplyEdit(state, {op = .Entity_Added, file = file, level = strings.clone(levelIid, context.temp_allocator), def = defUid, index = m.defs[l.def].uid, number = f64(at.x), number2 = f64(at.y), entity = iid})
	if state.level.problem != "" {
		logLine(state, .Warning, fmt.aprintf("Not placed: %s", state.level.problem))
		return
	}
	doc = LDtkDoc_Get(state.project.rootPath, file)
	// The count limit's MoveLastOne keeps the moved instance's iid: whatever is there now
	placed := iid
	if _, found := LDtkDoc_FindEntity(doc, iid); !found {
		level := LDtkDoc_FindLevel(doc, state.level.focus)
		if b, ok := LevelPaint_EntityAt(doc, level, m.defs[l.def].uid, {f32(at.x + LDtkLayer_Offset(m, l).x), f32(at.y + LDtkLayer_Offset(m, l).y)}); ok do placed = strings.clone(b.iid, context.temp_allocator)
	}
	levelSelectEntity(state, placed, center = false)
	// Chained from the entity placed before
	setOwned(&state.level.paint.chain, prev)
	levelChainTo(state, placed)
	setOwned(&state.level.paint.chain, placed)
	// Resizable: the resize tool starts (LDtk: bottom right, else right, else bottom); else a drag
	if resizableX || resizableY {
		paint := &state.level.paint
		strokeEnd(&paint.stroke)
		paint.stroke = {kind = .Resize, entity = strings.clone(placed), handle = resizableX && resizableY ? .Bottom_Right : resizableX ? .Right : .Bottom, at = at, size = {w, h}, started = time.tick_now()}
		return
	}
	drag := &state.level.drag
	delete(drag.target)
	drag^ = {mode = .Entity, target = strings.clone(placed), start = v.world, origin = {f32(at.x), f32(at.y)}, free = v.free}
}

/*
A reference from the entity placed last to `target`, when that entity has an entity reference
field set to chain (`autoChainRef`) that takes it (LDtk's EntityTool.tryToChainRefTo).
*/
@(private="file")
levelChainTo :: proc(state: ^State, target: string) {
	chain := state.level.paint.chain
	if chain == "" || chain == target do return
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	source, found := LDtkDoc_FindEntity(doc, chain)
	t, tfound := LDtkDoc_FindEntity(doc, target)
	if !found || !tfound do return
	main := LDtkDoc_Main(doc)
	json := LDtkDoc_Json(doc, source.file)
	def := LDtkDoc_DefByUid(doc, "entities", Json_Int(json, Json_Get(json, source.node, "defUid"), -1))
	for fd in Json_Items(main, Json_Get(main, def, "fieldDefs")) {
		info := LDtkDoc_FieldInfo(doc, fd)
		if info.type != .EntityRef || !Json_Bool(main, Json_Get(main, fd, "autoChainRef")) do continue
		if !LDtkOps_RefAllowed(doc, info, source, t) do continue
		levelApplyEdit(state, {op = .Entity_Ref, file = file, entity = strings.clone(chain, context.temp_allocator), field = info.uid, index = -1, text = strings.clone(target, context.temp_allocator)})
		return
	}
}

/*
LDtk's Alt + click (and the Picker): what's under the pointer in the focused level, topmost layer
first (the selected one first with the other layers faded): an entity is selected (its type picked
for Place), an IntGrid cell's value or a tile (with its flips) is picked and its layer selected;
nothing deselects.
*/
@(private="file")
levelSelectPick :: proc(state: ^State, doc: ^LDtkDoc, p: [2]f32) {
	m := LevelPaint_Model(state)
	if m == nil do return
	paint := &state.level.paint
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	current, _ := LevelPaint_Layer(state, m)
	// Layers bottom first, so the topmost element found is the last
	Found :: struct {
		layer: ^LDtkLayerData,
		cell: [2]int,
		entity: string,
	}
	best: Found
	any := false
	#reverse for &l in m.layers {
		d := &m.defs[l.def]
		if !l.visible || (&l != current && d.inactiveOpacity <= 0) do continue
		f := Found{layer = &l}
		hit := false
		switch d.kind {
		case .IntGrid:
			c := LDtkLayer_CellAt(m, &l, p)
			if LDtkLayer_IntGrid(&l, c.x, c.y) > 0 do f.cell, hit = c, true
		case .Tiles:
			c := LDtkLayer_CellAt(m, &l, p)
			if LDtkLayer_HasTile(&l, c.x, c.y) do f.cell, hit = c, true
		case .Entities:
			if b, ok := LevelPaint_EntityAt(doc, level, d.uid, p); ok do f.entity, hit = strings.clone(b.iid, context.temp_allocator), true
		case .AutoLayer:
		}
		if !hit do continue
		if paint.singleLayer && &l == current {
			best, any = f, true
			break
		}
		best, any = f, true
	}
	if !any {
		setOwned(&state.level.entity, "")
		return
	}
	d := &m.defs[best.layer.def]
	state.level.layerDef = d.uid
	switch d.kind {
	case .IntGrid:
		paint.values[d.uid] = LDtkLayer_IntGrid(best.layer, best.cell.x, best.cell.y)
	case .Tiles:
		top, _ := LDtkLayer_TopTile(best.layer, best.cell.x, best.cell.y)
		td := LDtkLevel_LayerTileset(m, best.layer)
		if td != nil {
			ids := make([dynamic]int)
			append(&ids, int(top.tile))
			if old, had := paint.tiles[td.uid]; had do delete(old)
			paint.tiles[td.uid] = ids
		}
		paint.flipX, paint.flipY = top.flips & 1 != 0, top.flips & 2 != 0
	case .Entities:
		levelSelectEntity(state, best.entity, center = false)
		if e, found := LDtkDoc_FindEntity(doc, best.entity); found {
			json := LDtkDoc_Json(doc, e.file)
			paint.entityDef = Json_Int(json, Json_Get(json, e.node, "defUid"), -1)
		}
	case .AutoLayer:
	}
	// The picker picked: back to painting with it
	if !LevelTool_Available(state, state.level.tool) || state.level.tool == .Picker || state.level.tool == .Select do state.level.tool = .Pencil
	if !LevelTool_Available(state, state.level.tool) do state.level.tool = .Select
}

// Applies a pick for the Entities tab: a reference to the entity clicked, a point at the cell
@(private="file")
levelPickApply :: proc(state: ^State, doc: ^LDtkDoc, v: Level_Canvas_Pressed, plan: LevelPressPlan) {
	pick := &state.level.paint.pick
	file := LevelMode_File(state)
	switch pick.kind {
	case .None:
	case .Ref:
		levelApplyEdit(state, {op = .Entity_Ref, file = file, entity = strings.clone(pick.entity, context.temp_allocator), field = pick.field, index = pick.index, text = strings.clone(plan.entity.iid, context.temp_allocator)})
		levelPickCancel(state)
	case .Point:
		e, found := LDtkDoc_FindEntity(doc, pick.entity)
		m := LevelPaint_Model(state)
		if !found || m == nil {
			levelPickCancel(state)
			return
		}
		json := LDtkDoc_Json(doc, e.file)
		layerIid := strings.clone(Json_String(json, Json_Get(json, e.layer, "iid")), context.temp_allocator)
		for &l in m.layers do if l.iid == layerIid {
			c := LDtkLayer_CellAt(m, &l, levelPixel(state, v.world))
			levelApplyEdit(state, {op = .Entity_Point, file = file, entity = strings.clone(pick.entity, context.temp_allocator), field = pick.field, index = pick.index, number = f64(c.x), number2 = f64(c.y)})
		}
		// An array's points keep coming (LDtk's point picker), a single one is done
		if pick.index >= 0 do levelPickCancel(state)
	}
}

@(private="file")
levelPickCancel :: proc(state: ^State) {
	delete(state.level.paint.pick.entity)
	state.level.paint.pick = {}
}

// ---------------------------------------------------------------------------------------------
// Messages and keys

/*
The painting messages: the palette's picks, the Entities tab's Pick, the keys' actions.

Returns:
- Whether `m` was one
*/
LevelPaint_Update :: proc(state: ^State, m: Msg) -> bool {
	paint := &state.level.paint
	#partial switch v in m {
	case Level_Value_Picked:
		paint.values[v.layer] = v.value
		if !LevelTool_Available(state, state.level.tool) || state.level.tool == .Select || state.level.tool == .Picker || state.level.tool == .Eraser do state.level.tool = .Pencil
		if !LevelTool_Available(state, state.level.tool) do state.level.tool = .Select
	case Level_Tiles_Picked:
		ids := make([dynamic]int)
		append(&ids, ..v.ids)
		if old, had := paint.tiles[v.tileset]; had do delete(old)
		paint.tiles[v.tileset] = ids
		if state.level.tool == .Select || state.level.tool == .Picker || state.level.tool == .Eraser do state.level.tool = paint.random ? .Random : .Pencil
		if !LevelTool_Available(state, state.level.tool) do state.level.tool = .Select
	case Level_Entity_Type_Picked:
		paint.entityDef = int(v)
		if state.level.tool != .Pencil && LevelTool_Available(state, .Pencil) do state.level.tool = .Pencil
	case Level_Pick_Started:
		levelPickCancel(state)
		if v.entity == "" || v.kind == .None do return true
		paint.pick = {kind = v.kind, entity = strings.clone(v.entity), field = v.field, index = v.index}
		// The canvas picks in a focused level: the entity's
		if state.level.focus == "" {
			doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
			if e, found := LDtkDoc_FindEntity(doc, v.entity); found {
				identifier, _ := LDtkDoc_LevelNames(doc, e.level)
				levelFocus(state, strings.clone(identifier, context.temp_allocator))
			}
		}
	case Level_Tool_Picked:
		// The Random tool is the stamp's other mode (LDtk's R)
		tool := LevelTool(v)
		if tool == .Pencil do paint.random = false
		if tool == .Random do paint.random = true
		return false
	case Action:
		#partial switch v {
		case .Level_Flip_X:        paint.flipX = !paint.flipX
		case .Level_Flip_Y:        paint.flipY = !paint.flipY
		case .Level_Random_Mode:
			paint.random = !paint.random
			if state.level.tool == .Pencil || state.level.tool == .Random do if LevelTool_Available(state, paint.random ? .Random : .Pencil) do state.level.tool = paint.random ? .Random : .Pencil
		case .Level_Toggle_Grid:   paint.noGrid = !paint.noGrid
		case .Level_Single_Layer:  paint.singleLayer = !paint.singleLayer
		case .Level_Tile_Stacking: paint.noStacking = !paint.noStacking
		case .Level_Auto_Layers:   paint.hideAutoLayers = !paint.hideAutoLayers
		case .Level_Cancel:
			if state.level.spot {
				state.level.spot = false
			} else if paint.pick.kind != .None {
				levelPickCancel(state)
			} else {
				setOwned(&state.level.entity, "")
			}
		case .Level_World_Mode:
			if state.level.focus != "" {
				levelFocus(state, "")
			} else if state.level.level != "" {
				levelFocus(state, state.level.level)
			}
		case .Level_Delete:
			if state.level.entity == "" do return true
			iid := strings.clone(state.level.entity, context.temp_allocator)
			levelApplyEdit(state, {op = .Entity_Removed, file = LevelMode_File(state), entity = iid})
			if state.level.problem == "" do setOwned(&state.level.entity, "")
		case .Level_Duplicate:
			levelDuplicateSelected(state)
		case:
			return false
		}
	case:
		return false
	}
	return true
}

// Ctrl+D: the selected entity copied a cell to the right and down (selected)
@(private="file")
levelDuplicateSelected :: proc(state: ^State) {
	if state.level.entity == "" do return
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	e, found := LDtkDoc_FindEntity(doc, state.level.entity)
	if !found do return
	json := LDtkDoc_Json(doc, e.file)
	px := Json_Get(json, e.node, "px")
	grid := ldtkInstanceGrid(doc, e)
	copyIid := LDtk_NewIid()
	levelApplyEdit(state, {op = .Entity_Duplicated, file = file, entity = strings.clone(state.level.entity, context.temp_allocator), text = copyIid,
		number = f64(Json_Int(json, Json_At(json, px, 0)) + grid), number2 = f64(Json_Int(json, Json_At(json, px, 1)) + grid)})
	if state.level.problem == "" do levelSelectEntity(state, copyIid, center = false)
}

/*
What a painting message edits, for the history (History_Classify asks): a stroke's release, a
placement or a pick's press, Delete and Duplicate. `.Files` steps of the Level mode's document.

Returns:
- The info, and whether `m` is one of these
*/
LevelPaint_Classify :: proc(s: ^State, m: Msg) -> (EditInfo, bool) {
	file := LevelMode_File(s)
	info := EditInfo{scope = .Files, ldtkFile = file}
	layer := LevelMode_LayerType(s)
	where_ := s.level.focus
	#partial switch v in m {
	case Level_Canvas_Pressed:
		plan := LevelPaint_PlanPress(s, v)
		#partial switch plan.kind {
		case .Place: info.label = fmt.tprintf("Place an entity in %s", where_)
		case .Pick:  info.label = fmt.tprintf("Pick a %s for an entity in %s", s.level.paint.pick.kind == .Ref ? "reference" : "point", where_)
		case .Move_Entity:
			// A press with the Place tool chains a reference to the entity
			if s.level.tool != .Pencil || v.alt do return {}, false
			info.label = fmt.tprintf("Reference an entity in %s", where_)
		case: return {}, false
		}
		return info, true
	case Level_Canvas_Released:
		st := s.level.paint.stroke
		switch st.kind {
		case .None:
			drag := s.level.drag
			if drag.mode == .Entity && drag.copy && drag.moved do return EditInfo{scope = .Files, ldtkFile = file, label = fmt.tprintf("Copy an entity in %s", where_)}, true
			return {}, false
		case .Grid:
			what := st.mode == .Remove ? "Erase" : st.fill ? "Fill" : st.rectangle ? "Paint a rectangle of" : "Paint"
			info.label = fmt.tprintf("%s %s in %s", what, layer, where_)
		case .Erase_Entities: info.label = fmt.tprintf("Remove entities in %s", where_)
		case .Resize:         info.label = fmt.tprintf("Resize an entity in %s", where_)
		case .Point:          info.label = fmt.tprintf("Move an entity's point in %s", where_)
		}
		return info, true
	case Action:
		#partial switch v {
		case .Level_Delete:
			if s.level.entity == "" do return {}, false
			info.label = fmt.tprintf("Remove an entity in %s", where_)
			return info, true
		case .Level_Duplicate:
			if s.level.entity == "" do return {}, false
			info.label = fmt.tprintf("Duplicate an entity in %s", where_)
			return info, true
		}
	}
	return {}, false
}

// The cursor the canvas shows over the focused level (the tool's)
LevelPaint_Cursor :: proc(state: ^State) -> skald.Cursor_Shape {
	if state.level.paint.pick.kind != .None do return .Crosshair
	if state.level.paint.stroke.kind == .Resize do return .Move
	if painting(state.level.tool) do return .Crosshair
	return .Default
}
