package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "gui:skald"

/*
LDtk's selection in the focused level (phase 5 of TODO.md's "LDtk level editor": its
tool/SelectionTool.hx, GenericLevelElementGroup.hx): grid cells (IntGrid values, tile stacks),
entities and their points, picked and then moved, copied or deleted together.

- **Selecting:** with the Select tool a drag on the level (not on an entity) draws a rectangle,
  Alt + Shift + drag with any tool too: everything in it is selected, in every visible layer that
  allows it (`canSelectWhenInactive`, or the selected layer), only the selected layer in single
  layer mode (LDtk's useOnRectangle: the rectangle snapped to the selected layer's cells). With
  "select empty spaces" (Shift+E) the rectangle itself is selected too, so a move clears where it
  lands. Ctrl+A selects everything (selectAllInLayers); a click with the Select tool on an element
  selects it; Esc clears.
- **Moving:** a drag that starts on the selection moves it by whole cells of the selection's
  biggest grid (LDtk's smart grid), a ghost and an arrow showing where; Ctrl + Alt copies it.
  The release is one `Selection_Edit` (ldtk_selection_ops.odin): one undo step.
- **Deleting:** Del removes everything selected.

State: `LevelMode.selection` (the elements, their iids owned), the drag's `.Select_Rect` /
`.Select_Move` modes, `LevelPaint.emptySpace`.
*/

// Frees a selection's strings and empties it
LevelSelection_Clear :: proc(sel: ^[dynamic]LDtkSelElem) {
	for e in sel do delete(e.iid)
	clear(sel)
}

// Adds an element (once; its iid copied)
@(private="file")
selAdd :: proc(sel: ^[dynamic]LDtkSelElem, e: LDtkSelElem) {
	for x in sel {
		if x.kind != e.kind do continue
		switch e.kind {
		case .Cell: if x.layer == e.layer && x.cx == e.cx && x.cy == e.cy do return
		case .Entity: if x.iid == e.iid do return
		case .Point: if x.iid == e.iid && x.field == e.field && x.index == e.index do return
		case .Rect: if x.rect == e.rect do return
		}
	}
	c := e
	c.iid = strings.clone(e.iid)
	append(sel, c)
}

// The layers a selection may take from (visible; the selected one, or those allowing it; one in single layer mode)
@(private="file")
selLayers :: proc(state: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel) -> []^LDtkLayerData {
	out := make([dynamic]^LDtkLayerData, context.temp_allocator)
	main := LDtkDoc_Main(doc)
	cur, _ := LevelPaint_Layer(state, m)
	for &l in m.layers {
		if !l.visible do continue
		if state.level.paint.singleLayer && &l != cur do continue
		def := LDtkDoc_DefByUid(doc, "layers", m.defs[l.def].uid)
		if &l != cur && !Json_Bool(main, Json_Get(main, def, "canSelectWhenInactive"), true) do continue
		append(&out, &l)
	}
	return out[:]
}

/*
What's in a rectangle of the focused level (level pixels, `left`..`right`, `top`..`bottom`
inclusive): cells with values, entities whose cell is in it, points (LDtk's useOnRectangle).
*/
LevelSelection_InRect :: proc(state: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel, level: int, r: [4]int) -> []LDtkSelElem {
	out := make([dynamic]LDtkSelElem, context.temp_allocator)
	for l in selLayers(state, doc, m) {
		d := &m.defs[l.def]
		off := LDtkLayer_Offset(m, l)
		g := d.gridSize
		cl, cr := (r[0] - off.x) / g, (r[1] - off.x) / g
		ct, cb := (r[2] - off.y) / g, (r[3] - off.y) / g
		switch d.kind {
		case .IntGrid, .Tiles:
			for cy in max(ct, 0) ..= min(cb, l.cHei - 1) do for cx in max(cl, 0) ..= min(cr, l.cWid - 1) {
				coord := LDtkLayer_Coord(l, cx, cy)
				has := d.kind == .IntGrid ? l.intGrid[coord] != 0 : len(l.tiles[coord]) > 0
				if has do append(&out, LDtkSelElem{kind = .Cell, layer = d.uid, cx = cx, cy = cy})
			}
		case .Entities:
			for b in LevelPaint_Entities(doc, level) {
				if b.layer != d.uid do continue
				cx := (b.at.x + (b.pivot.x == 1 ? -1 : 0)) / g
				cy := (b.at.y + (b.pivot.y == 1 ? -1 : 0)) / g
				if cx >= cl && cx <= cr && cy >= ct && cy <= cb do append(&out, LDtkSelElem{kind = .Entity, iid = b.iid})
				for pt in LevelPaint_Points(doc, b.iid) {
					if pt.cell.x >= cl && pt.cell.x <= cr && pt.cell.y >= ct && pt.cell.y <= cb {
						append(&out, LDtkSelElem{kind = .Point, iid = b.iid, field = pt.field, index = pt.index})
					}
				}
			}
		case .AutoLayer:
		}
	}
	return out[:]
}

/*
The element under a level pixel (Editor.getGenericLevelElementAt): the selected layer first (an
entity, a point, a cell), then the others top first.
*/
LevelSelection_At :: proc(state: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel, level: int, p: [2]f32) -> (LDtkSelElem, bool) {
	for l in selLayers(state, doc, m) {
		d := &m.defs[l.def]
		switch d.kind {
		case .Entities:
			for b in LevelPaint_Entities(doc, level) {
				if b.layer != d.uid do continue
				for pt in LevelPaint_Points(doc, b.iid) {
					dd := p - pt.center
					if math.sqrt(dd.x * dd.x + dd.y * dd.y) <= f32(d.gridSize) * 0.5 do return {kind = .Point, iid = b.iid, field = pt.field, index = pt.index}, true
				}
			}
			if b, found := LevelPaint_EntityAt(doc, level, d.uid, p); found do return {kind = .Entity, iid = b.iid}, true
		case .IntGrid, .Tiles:
			c := LDtkLayer_CellAt(m, l, p)
			if !LDtkLayer_Valid(l, c.x, c.y) do continue
			coord := LDtkLayer_Coord(l, c.x, c.y)
			has := d.kind == .IntGrid ? l.intGrid[coord] != 0 : len(l.tiles[coord]) > 0
			if has do return {kind = .Cell, layer = d.uid, cx = c.x, cy = c.y}, true
		case .AutoLayer:
		}
	}
	return {}, false
}

// Whether a level pixel is over the selection (GenericLevelElementGroup.isOveringSelection)
LevelSelection_IsOver :: proc(state: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel, level: int, p: [2]f32) -> bool {
	for e in state.level.selection {
		switch e.kind {
		case .Cell:
			l := LDtkLevel_LayerByDef(m, e.layer)
			if l == nil do continue
			if LDtkLayer_CellAt(m, l, p) == {e.cx, e.cy} do return true
		case .Entity:
			for b in LevelPaint_Entities(doc, level) do if b.iid == e.iid {
				if LevelEntityBox_IsOver(b, {f64(p.x) - f64(b.offset.x), f64(p.y) - f64(b.offset.y)}) do return true
			}
		case .Point:
			for pt in LevelPaint_Points(doc, e.iid) do if pt.field == e.field && pt.index == e.index {
				d := p - pt.center
				if math.sqrt(d.x * d.x + d.y * d.y) <= 8 do return true
			}
		case .Rect:
			if p.x >= f32(e.rect[0]) && p.x <= f32(e.rect[1]) && p.y >= f32(e.rect[2]) && p.y <= f32(e.rect[3]) do return true
		}
	}
	return false
}

// The selection's biggest grid (LDtk's smart grid: moves go by its cells)
LevelSelection_Grid :: proc(state: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel) -> int {
	g := 1
	main := LDtkDoc_Main(doc)
	for e in state.level.selection {
		switch e.kind {
		case .Cell:
			if l := LDtkLevel_LayerByDef(m, e.layer); l != nil do g = max(g, m.defs[l.def].gridSize)
		case .Entity, .Point:
			if en, found := LDtkDoc_FindEntity(doc, e.iid); found {
				json := LDtkDoc_Json(doc, en.file)
				g = max(g, Json_Int(json, Json_Get(json, en.layer, "__gridSize"), 16))
			}
		case .Rect:
		}
	}
	_ = main
	return g
}

/*
A press the selection takes (before the tools): a move of the selection, a rectangle (the Select
tool, or Alt + Shift), a click selecting what's under it. Returns whether it took it.
*/
LevelSelect_Press :: proc(state: ^State, v: Level_Canvas_Pressed) -> bool {
	if v.pan || v.right || state.level.focus == "" do return false
	doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
	if doc == nil || doc.problem != "" do return false
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	if level < 0 do return false
	m := LevelPaint_Model(state)
	if m == nil do return false
	r := LDtkDoc_LevelRect(doc, level)
	p := v.world - {f32(r[0]), f32(r[1])}
	// Outside the focused level, or a double-click: the level view's own (another level focused,
	// back to the world)
	if v.double || p.x < 0 || p.y < 0 || p.x >= f32(r[2]) || p.y >= f32(r[3]) do return false
	drag := &state.level.drag
	if len(state.level.selection) > 0 && LevelSelection_IsOver(state, doc, m, level, p) {
		delete(drag.target)
		drag^ = {mode = .Select_Move, start = v.world, copy = v.alt && v.ctrl}
		return true
	}
	rect := v.alt && v.free
	if !rect && state.level.tool == .Select && !v.alt {
		// The Select tool: not on an entity (pressed, it's moved as before) nor its handles
		if _, found := LevelPaint_EntityAt(doc, level, -1, p); !found {
			if len(LevelPaint_Points(doc, state.level.entity)) == 0 || !selPointNear(doc, state.level.entity, p) do rect = true
		}
	}
	if !rect {
		// Another tool's press: the selection goes (LDtk's tools clear it)
		LevelSelection_Clear(&state.level.selection)
		return false
	}
	if !v.free do LevelSelection_Clear(&state.level.selection)
	delete(drag.target)
	drag^ = {mode = .Select_Rect, start = v.world, free = v.free}
	return true
}

@(private="file")
selPointNear :: proc(doc: ^LDtkDoc, iid: string, p: [2]f32) -> bool {
	for pt in LevelPaint_Points(doc, iid) {
		d := p - pt.center
		if math.sqrt(d.x * d.x + d.y * d.y) <= 8 do return true
	}
	return false
}

/*
The rectangle a selection drag covers (level pixels, inclusive), snapped to the selected layer's
cells (Tool's rectangle: from the cell pressed to the cell under the pointer).
*/
LevelSelect_DragRect :: proc(state: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel, level: int) -> [4]int {
	r := LDtkDoc_LevelRect(doc, level)
	a := state.level.drag.start - {f32(r[0]), f32(r[1])}
	b := a + state.level.drag.offset
	g := 16
	off := [2]int{}
	if l, _ := LevelPaint_Layer(state, m); l != nil {
		g = m.defs[l.def].gridSize
		off = LDtkLayer_Offset(m, l)
	}
	ca := [2]int{int(math.floor((a.x - f32(off.x)) / f32(g))), int(math.floor((a.y - f32(off.y)) / f32(g)))}
	cb := [2]int{int(math.floor((b.x - f32(off.x)) / f32(g))), int(math.floor((b.y - f32(off.y)) / f32(g)))}
	lo := [2]int{min(ca.x, cb.x), min(ca.y, cb.y)}
	hi := [2]int{max(ca.x, cb.x), max(ca.y, cb.y)}
	return {lo.x * g + off.x, (hi.x + 1) * g + off.x - 1, lo.y * g + off.y, (hi.y + 1) * g + off.y - 1}
}

// A selection move's distance (level pixels, whole cells of the selection's grid)
LevelSelect_MoveDelta :: proc(state: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel) -> [2]int {
	g := f32(LevelSelection_Grid(state, doc, m))
	r := LDtkDoc_LevelRect(doc, LDtkDoc_FindLevel(doc, state.level.focus))
	a := state.level.drag.start - {f32(r[0]), f32(r[1])}
	b := a + state.level.drag.offset
	return {int(math.floor(b.x / g) - math.floor(a.x / g)) * int(g), int(math.floor(b.y / g) - math.floor(a.y / g)) * int(g)}
}

/*
A selection drag's release: the rectangle's elements selected (a click: the element under it), or
the selection moved (one `Selection_Edit`). Returns whether it was one.
*/
LevelSelect_Released :: proc(state: ^State) -> bool {
	drag := state.level.drag
	if drag.mode != .Select_Rect && drag.mode != .Select_Move do return false
	defer levelDragEnd(state)
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	m := LevelPaint_Model(state)
	if doc == nil || m == nil do return true
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	if level < 0 do return true
	sel := &state.level.selection
	if drag.mode == .Select_Rect {
		if !drag.moved {
			// A click: the element under it (an entity: selected as before, for the Entities tab)
			r := LDtkDoc_LevelRect(doc, level)
			if e, found := LevelSelection_At(state, doc, m, level, drag.start - {f32(r[0]), f32(r[1])}); found {
				if e.kind == .Entity && len(sel) == 0 {
					levelSelectEntity(state, e.iid, center = false)
					return true
				}
				selAdd(sel, e)
			}
			return true
		}
		rect := LevelSelect_DragRect(state, doc, m, level)
		found := LevelSelection_InRect(state, doc, m, level, rect)
		for e in found do selAdd(sel, e)
		if state.level.paint.emptySpace && len(sel) > 0 {
			rl := LDtkDoc_LevelRect(doc, level)
			selAdd(sel, {kind = .Rect, rect = {max(rect[0], 0), min(rect[1], int(rl[2])), max(rect[2], 0), min(rect[3], int(rl[3]))}})
		}
		setOwned(&state.level.entity, "")
		return true
	}
	// A move (a click on the selection without moving does nothing)
	if !drag.moved do return true
	delta := LevelSelect_MoveDelta(state, doc, m)
	if delta == {0, 0} do return true
	_, iid := LDtkDoc_LevelNames(doc, level)
	single := 0
	if state.level.paint.singleLayer {
		if l, _ := LevelPaint_Layer(state, m); l != nil do single = m.defs[l.def].uid
	}
	levelApplyEdit(state, {op = .Selection_Edit, file = file, level = strings.clone(iid, context.temp_allocator), key = "move",
		text = LDtk_SelectionText(sel[:]), number = f64(delta.x), number2 = f64(delta.y), number3 = f64(single), flag = drag.copy})
	if state.level.problem != "" do return true
	// The selection follows its cells (entities' copies aren't selected: their iids are new)
	doc = LDtkDoc_Get(state.project.rootPath, file)
	m = LevelPaint_Model(state)
	keep := make([dynamic]LDtkSelElem, context.temp_allocator)
	for e in sel {
		switch e.kind {
		case .Cell:
			if m == nil do continue
			l := LDtkLevel_LayerByDef(m, e.layer)
			if l == nil do continue
			g := m.defs[l.def].gridSize
			n := e
			n.cx, n.cy = e.cx + delta.x / g, e.cy + delta.y / g
			if LDtkLayer_Valid(l, n.cx, n.cy) do append(&keep, n)
		case .Rect:
			n := e
			n.rect += {delta.x, delta.x, delta.y, delta.y}
			append(&keep, n)
		case .Entity, .Point:
			if drag.copy do continue
			if _, found := LDtkDoc_FindEntity(doc, e.iid); found do append(&keep, LDtkSelElem{kind = e.kind, iid = strings.clone(e.iid, context.temp_allocator), field = e.field, index = e.index})
		}
	}
	LevelSelection_Clear(sel)
	for e in keep do selAdd(sel, e)
	return true
}

// Ctrl+A: everything of the selectable layers (SelectionTool.selectAllInLayers)
LevelSelect_All :: proc(state: ^State) {
	doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
	m := LevelPaint_Model(state)
	if doc == nil || m == nil do return
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	if level < 0 do return
	LevelSelection_Clear(&state.level.selection)
	r := LDtkDoc_LevelRect(doc, level)
	for e in LevelSelection_InRect(state, doc, m, level, {-100000, 100000, -100000, 100000}) do selAdd(&state.level.selection, e)
	if state.level.paint.emptySpace && len(state.level.selection) > 0 do selAdd(&state.level.selection, {kind = .Rect, rect = {0, int(r[2]), 0, int(r[3])}})
	setOwned(&state.level.entity, "")
}

// Del: the selection removed (one `Selection_Edit`)
LevelSelect_Delete :: proc(state: ^State) -> bool {
	if len(state.level.selection) == 0 do return false
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	if level < 0 do return false
	_, iid := LDtkDoc_LevelNames(doc, level)
	levelApplyEdit(state, {op = .Selection_Edit, file = file, level = strings.clone(iid, context.temp_allocator), key = "delete", text = LDtk_SelectionText(state.level.selection[:])})
	if state.level.problem == "" do LevelSelection_Clear(&state.level.selection)
	return true
}

// What the selection draws over the canvas (screen pixels; temp)
LevelSelectOverlay :: struct {
	cells: [dynamic][4]f32,
	rects: [dynamic][4]f32,
	points: [dynamic][3]f32,
	// A rectangle being drawn, a move's ghost offset and its arrow
	dragRect: [4]f32,
	dragging: bool,
	offset: [2]f32,
	arrow: [2][2]f32,
	moving, copying: bool,
}

/*
The selection's overlay for the canvas's view (the focused level at `origin`, world pixels).
*/
LevelSelectOverlay_Build :: proc(state: ^State, doc: ^LDtkDoc, origin: [2]f32, center: [2]f32, zoom: f32, size: [2]f32) -> ^LevelSelectOverlay {
	m := LevelPaint_Current()
	drag := state.level.drag
	if m == nil || (len(state.level.selection) == 0 && drag.mode != .Select_Rect) do return nil
	o := new(LevelSelectOverlay, context.temp_allocator)
	o.cells = make([dynamic][4]f32, context.temp_allocator)
	o.rects = make([dynamic][4]f32, context.temp_allocator)
	o.points = make([dynamic][3]f32, context.temp_allocator)
	toScreen :: proc(p, center: [2]f32, zoom: f32, size: [2]f32) -> [2]f32 { return size * 0.5 + (p - center) * zoom }
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	for e in state.level.selection {
		switch e.kind {
		case .Cell:
			l := LDtkLevel_LayerByDef(m, e.layer)
			if l == nil do continue
			g := f32(m.defs[l.def].gridSize)
			off := LDtkLayer_Offset(m, l)
			a := toScreen(origin + {f32(e.cx) * g + f32(off.x), f32(e.cy) * g + f32(off.y)}, center, zoom, size)
			append(&o.cells, [4]f32{a.x, a.y, g * zoom, g * zoom})
		case .Entity:
			if level >= 0 do for b in LevelPaint_Entities(doc, level) do if b.iid == e.iid {
				tl := [2]f32{f32(b.at.x) - f32(b.pivot.x) * f32(b.size.x), f32(b.at.y) - f32(b.pivot.y) * f32(b.size.y)} + {f32(b.offset.x), f32(b.offset.y)}
				a := toScreen(origin + tl, center, zoom, size)
				append(&o.cells, [4]f32{a.x, a.y, f32(b.size.x) * zoom, f32(b.size.y) * zoom})
			}
		case .Point:
			for pt in LevelPaint_Points(doc, e.iid) do if pt.field == e.field && pt.index == e.index {
				a := toScreen(origin + pt.center, center, zoom, size)
				append(&o.points, [3]f32{a.x, a.y, 6})
			}
		case .Rect:
			a := toScreen(origin + {f32(e.rect[0]), f32(e.rect[2])}, center, zoom, size)
			append(&o.rects, [4]f32{a.x, a.y, f32(e.rect[1] - e.rect[0]) * zoom, f32(e.rect[3] - e.rect[2]) * zoom})
		}
	}
	if drag.mode == .Select_Rect && drag.moved && level >= 0 {
		r := LevelSelect_DragRect(state, doc, m, level)
		a := toScreen(origin + {f32(r[0]), f32(r[2])}, center, zoom, size)
		o.dragRect = {a.x, a.y, f32(r[1] - r[0] + 1) * zoom, f32(r[3] - r[2] + 1) * zoom}
		o.dragging = true
	}
	if drag.mode == .Select_Move && drag.moved {
		d := LevelSelect_MoveDelta(state, doc, m)
		o.offset = {f32(d.x), f32(d.y)} * zoom
		o.moving, o.copying = true, drag.copy
		from := toScreen(drag.start, center, zoom, size)
		o.arrow = {from, from + o.offset}
	}
	return o
}

// Draws the selection (LDtk's: selected cells yellow, empty spaces blue, the ghost where a move lands)
LevelSelectOverlay_Draw :: proc(r: ^skald.Renderer, b: skald.Rect, o: ^LevelSelectOverlay) {
	yellow := skald.rgb(0xFFCC00)
	blue := skald.rgb(0x8AB7FF)
	at := [2]f32{b.x, b.y}
	for x in o.rects {
		skald.draw_rect(r, {b.x + x[0], b.y + x[1], x[2], x[3]}, {blue.r, blue.g, blue.b, 0.25})
		skald.draw_rect_outline(r, {b.x + x[0], b.y + x[1], x[2], x[3]}, 1, blue)
	}
	for c in o.cells {
		skald.draw_rect(r, {b.x + c[0], b.y + c[1], c[2], c[3]}, {yellow.r, yellow.g, yellow.b, 0.3})
		skald.draw_rect_outline(r, {b.x + c[0], b.y + c[1], c[2], c[3]}, 1, yellow)
	}
	for p in o.points do skald.draw_ring(r, at + {p[0], p[1]}, p[2], 2, yellow)
	if o.dragging do skald.draw_rect_outline(r, {b.x + o.dragRect[0], b.y + o.dragRect[1], o.dragRect[2], o.dragRect[3]}, 2, {1, 1, 1, 0.9})
	if o.moving {
		ghost := o.copying ? yellow : skald.Color{1, 1, 1, 1}
		for c in o.cells do skald.draw_rect_outline(r, {b.x + c[0] + o.offset.x, b.y + c[1] + o.offset.y, c[2], c[3]}, 1, ghost)
		for x in o.rects do skald.draw_rect_outline(r, {b.x + x[0] + o.offset.x, b.y + x[1] + o.offset.y, x[2], x[3]}, 1, ghost)
		a, c := at + o.arrow[0], at + o.arrow[1]
		d := c - a
		length := math.sqrt(d.x * d.x + d.y * d.y)
		if length > 4 {
			skald.draw_line(r, a, c, 2, ghost, aa = true)
			dir := d / length
			side := [2]f32{-dir.y, dir.x}
			skald.draw_line(r, c, c - dir * 8 + side * 5, 2, ghost, aa = true)
			skald.draw_line(r, c, c - dir * 8 - side * 5, 2, ghost, aa = true)
		}
	}
}

// The selection's size for the status line ("" none)
LevelSelect_Summary :: proc(state: ^State) -> string {
	if len(state.level.selection) == 0 do return ""
	cells, entities, points := 0, 0, 0
	for e in state.level.selection {
		switch e.kind {
		case .Cell: cells += 1
		case .Entity: entities += 1
		case .Point: points += 1
		case .Rect:
		}
	}
	return fmt.tprintf("Selected: %d cell%s, %d entit%s, %d point%s (drag to move, Ctrl + Alt to copy, Del removes)", cells, cells == 1 ? "" : "s", entities, entities == 1 ? "y" : "ies", points, points == 1 ? "" : "s")
}
