package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

/*
LDtk's selection moved, copied or deleted (phase 5 of TODO.md's "LDtk level editor"; its
tool/SelectionTool.hx and GenericLevelElementGroup.hx): `Selection_Edit` on the level `level`
with the selection in `text`, a line per element:

	c <layer uid> <cx> <cy>        a grid cell (IntGrid value or tile stack)
	e <entity iid>                 an entity
	p <entity iid> <field uid> <i> a point of an entity's Point field
	r <left> <right> <top> <bottom> an "empty space" rectangle (level pixels)

`key` "move": by `number`, `number2` level pixels (whole cells of the selection's biggest grid:
each layer moves by as many of its own cells), `flag` a copy (Ctrl + Alt); "delete": removed.
Moving as LDtk moves (moveSelecteds): the cells' values and tile stacks go (copies stay), empty
space rectangles clear where they land (in every visible IntGrid and Tiles layer, or `number3`'s
only: single layer mode), entities move by the pixels (copies keep LDtk's count limits),
leaving the layer unless their type allows it removes them, points move by cells (copies of
points add an item after the original), points leaving the layer go; auto-layers are worked out
again, then LDtk's tidy. One undo step.
*/

// A selection's element (temp strings)
LDtkSelElem :: struct {
	kind: enum u8 {
		Cell,
		Entity,
		Point,
		Rect,
	},
	layer, cx, cy: int,
	iid: string,
	field, index: int,
	rect: [4]int,
}

// A selection as `Selection_Edit` carries it (see the file's doc block; temp)
LDtk_SelectionText :: proc(elems: []LDtkSelElem) -> string {
	b := strings.builder_make(context.temp_allocator)
	for e in elems {
		switch e.kind {
		case .Cell: fmt.sbprintf(&b, "c %d %d %d\n", e.layer, e.cx, e.cy)
		case .Entity: fmt.sbprintf(&b, "e %s\n", e.iid)
		case .Point: fmt.sbprintf(&b, "p %s %d %d\n", e.iid, e.field, e.index)
		case .Rect: fmt.sbprintf(&b, "r %d %d %d %d\n", e.rect[0], e.rect[1], e.rect[2], e.rect[3])
		}
	}
	return strings.to_string(b)
}

// A selection read back from its text (temp)
LDtk_SelectionParse :: proc(text: string) -> []LDtkSelElem {
	out := make([dynamic]LDtkSelElem, context.temp_allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 do continue
		num :: proc(f: []string, i: int) -> int {
			if i >= len(f) do return 0
			v, _ := strconv.parse_int(f[i])
			return v
		}
		switch f[0] {
		case "c": append(&out, LDtkSelElem{kind = .Cell, layer = num(f, 1), cx = num(f, 2), cy = num(f, 3)})
		case "e": if len(f) > 1 do append(&out, LDtkSelElem{kind = .Entity, iid = f[1]})
		case "p": if len(f) > 3 do append(&out, LDtkSelElem{kind = .Point, iid = f[1], field = num(f, 2), index = num(f, 3)})
		case "r": append(&out, LDtkSelElem{kind = .Rect, rect = {num(f, 1), num(f, 2), num(f, 3), num(f, 4)}})
		}
	}
	return out[:]
}

/*
A `Selection_Edit` (see the file's doc block).

Returns:
- "" or why nothing changed
*/
LDtkOps_SelectionEdit :: proc(doc: ^LDtkDoc, edit: LDtk_Edit) -> (problem: string) {
	s := stagesMake(doc)
	defer if problem != "" do for d in s.made do LDtkDoc_Free(d)
	level := LDtkDoc_FindLevel(doc, edit.level)
	if level < 0 do return "no such level"
	elems := LDtk_SelectionParse(edit.text)
	if len(elems) == 0 do return ""
	deleting := edit.key == "delete"
	copy_ := edit.flag && !deleting
	delta := [2]int{int(math.round(edit.number)), int(math.round(edit.number2))}
	if !deleting && delta == {0, 0} && !copy_ do return ""
	minified := Json_Minified(LDtkDoc_Main(doc))

	// 1. Grid cells, in the level's model (LDtk's postRemovals then postInserts)
	m, ok := LDtkLevel_Read(doc, "", level)
	if !ok do return "the level's layers can't be read"
	defer LDtkLevel_Destroy(&m)
	changed := make(map[int]bool, context.temp_allocator)
	Insert :: struct {
		l: ^LDtkLayerData,
		cx, cy: int,
		value: i32,
		tiles: [dynamic]LDtkGridTile,
	}
	removals := make([dynamic][3]int, context.temp_allocator)
	inserts := make([dynamic]Insert, context.temp_allocator)
	layerOf :: proc(m: ^LDtkLevelModel, uid: int) -> ^LDtkLayerData {
		return LDtkLevel_LayerByDef(m, uid)
	}
	// Empty space: what's where the rectangles land is cleared first
	if !deleting {
		for e in elems {
			if e.kind != .Rect do continue
			r := e.rect + {delta.x, delta.x, delta.y, delta.y}
			for &l, li in m.layers {
				d := &m.defs[l.def]
				if d.kind != .IntGrid && d.kind != .Tiles do continue
				if !l.visible do continue
				if edit.number3 > 0 && d.uid != int(edit.number3) do continue
				off := LDtkLayer_Offset(&m, &l)
				g := d.gridSize
				for cy in (r[2] - off.y) / g ..< (r[3] + 1 - off.y) / g do for cx in (r[0] - off.x) / g ..< (r[1] + 1 - off.x) / g {
					if LDtkLayer_Valid(&l, cx, cy) do append(&removals, [3]int{li, cx, cy})
				}
			}
		}
	}
	for e in elems {
		if e.kind != .Cell do continue
		l := layerOf(&m, e.layer)
		if l == nil || !LDtkLayer_Valid(l, e.cx, e.cy) do continue
		d := &m.defs[l.def]
		li := -1
		for &x, i in m.layers do if &x == l do li = i
		coord := LDtkLayer_Coord(l, e.cx, e.cy)
		has := d.kind == .IntGrid ? l.intGrid[coord] != 0 : (d.kind == .Tiles && len(l.tiles[coord]) > 0)
		if !has do continue
		changed[d.uid] = true
		if !copy_ do append(&removals, [3]int{li, e.cx, e.cy})
		if deleting do continue
		g := d.gridSize
		tcx, tcy := e.cx + delta.x / g, e.cy + delta.y / g
		ins := Insert{l = l, cx = tcx, cy = tcy}
		if d.kind == .IntGrid {
			ins.value = l.intGrid[coord]
		} else {
			ins.tiles = make([dynamic]LDtkGridTile, context.temp_allocator)
			append(&ins.tiles, ..l.tiles[coord][:])
		}
		append(&inserts, ins)
	}
	for r in removals {
		l := &m.layers[r[0]]
		coord := LDtkLayer_Coord(l, r[1], r[2])
		switch m.defs[l.def].kind {
		case .IntGrid: l.intGrid[coord] = 0; l.changed += {.IntGrid}
		case .Tiles: clear(&l.tiles[coord]); l.changed += {.Tiles}
		case .Entities, .AutoLayer:
		}
		changed[m.defs[l.def].uid] = true
	}
	for ins in inserts {
		if !LDtkLayer_Valid(ins.l, ins.cx, ins.cy) do continue
		coord := LDtkLayer_Coord(ins.l, ins.cx, ins.cy)
		if m.defs[ins.l.def].kind == .IntGrid {
			ins.l.intGrid[coord] = ins.value
			ins.l.changed += {.IntGrid}
		} else {
			// A stack moves whole (tile stacking kept)
			clear(&ins.l.tiles[coord])
			append(&ins.l.tiles[coord], ..ins.tiles[:])
			ins.l.changed += {.Tiles}
		}
	}
	p := LDtkLevel_Patches(&m, doc)
	if problem = stagesApply(&s, &p); problem != "" do return

	// 2. Entities and points, in the JSON
	q := LDtkPatches{}
	file, array := LDtkDoc_LayerInstances(s.cur, level)
	json := LDtkDoc_Json(s.cur, file)
	main := LDtkDoc_Main(s.cur)
	removed := make(map[string]bool, context.temp_allocator)
	movedPoints := make(map[string]bool, context.temp_allocator)
	for e in elems do if e.kind == .Point do movedPoints[fmt.tprintf("%s %d %d", e.iid, e.field, e.index)] = true
	for li in Json_Items(json, array) {
		entities := Json_Get(json, li, "entityInstances")
		if Json_Count(json, entities) == 0 do continue
		grid := max(Json_Int(json, Json_Get(json, li, "__gridSize"), 16), 1)
		cWid, cHei := Json_Int(json, Json_Get(json, li, "__cWid")), Json_Int(json, Json_Get(json, li, "__cHei"))
		layerW, layerH := cWid * grid, cHei * grid
		items := make([dynamic]string, context.temp_allocator)
		dirty := false
		for en in Json_Items(json, entities) {
			iid := Json_String(json, Json_Get(json, en, "iid"))
			selected := false
			for e in elems do if e.kind == .Entity && e.iid == iid do selected = true
			hasPoints := false
			for e in elems do if e.kind == .Point && e.iid == iid do hasPoints = true
			text := strings.clone(Json_Text(json, en), context.temp_allocator)
			if !selected && !hasPoints {
				append(&items, text)
				continue
			}
			dirty = true
			v := ldtkJV(json, en)
			if selected && deleting {
				removed[strings.clone(iid, context.temp_allocator)] = true
				continue
			}
			// The points of this entity's Point fields: moved (or copied, arrays only), out of the layer: removed
			pointsMoved :: proc(v: LDtkJV, iid: string, delta: [2]int, grid: int, copy_, all, deleting: bool, selected: map[string]bool, cells: [2]int) -> LDtkJV {
				fields, _ := jvGet(v, "fieldInstances").(LDtkJArray)
				out := make([]LDtkJV, len(fields), context.temp_allocator)
				for f, i in fields {
					out[i] = f
					t, _ := jvGet(f, "__type").(string)
					if t != "Point" && t != "Array<Point>" do continue
					uid, _ := jvGet(f, "defUid").(i64)
					raws, _ := jvGet(f, "realEditorValues").(LDtkJArray)
					list := make([dynamic]LDtkJV, context.temp_allocator)
					for r, k in raws {
						on := all || selected[fmt.tprintf("%s %d %d", iid, uid, k)]
						if !on {
							append(&list, r)
							continue
						}
						if deleting do continue
						params, _ := jvGet(r, "params").(LDtkJArray)
						text := ""
						if len(params) > 0 do text, _ = params[0].(string)
						xs, _, ys := strings.partition(text, ",")
						cx, _ := strconv.parse_int(strings.trim_space(xs))
						cy, _ := strconv.parse_int(strings.trim_space(ys))
						if copy_ && !all && t == "Array<Point>" do append(&list, r)
						nx, ny := cx + delta.x / grid, cy + delta.y / grid
						if nx < 0 || ny < 0 || nx >= cells.x || ny >= cells.y do continue
						append(&list, jvWith(r, "params", jarray(fmt.tprintf("%d,%d", nx, ny))))
					}
					out[i] = jvWith(f, "realEditorValues", LDtkJArray(list[:]))
				}
				return jvWith(v, "fieldInstances", LDtkJArray(out))
			}
			if selected {
				px, _ := jvGet(v, "px").(LDtkJArray)
				x, y: i64
				if len(px) == 2 do x, _ = px[0].(i64)
				if len(px) == 2 do y, _ = px[1].(i64)
				nx, ny := int(x) + delta.x, int(y) + delta.y
				defUid := Json_Int(json, Json_Get(json, en, "defUid"))
				ed := LDtkDoc_DefByUid(s.cur, "entities", defUid)
				out := !Json_Bool(main, Json_Get(main, ed, "allowOutOfBounds")) && (nx < 0 || ny < 0 || nx >= layerW || ny >= layerH)
				moved := jvWith(v, "px", jarray(i64(nx), i64(ny)))
				// A copy's own points move with it (LDtk remaps a copied entity's points)
				moved = pointsMoved(moved, iid, delta, grid, false, copy_, false, movedPoints, {cWid, cHei})
				if copy_ {
					append(&items, text)
					if out do continue
					// LDtk's count limits for copies (moveSelecteds: refused at the limit)
					if maxCount := Json_Int(main, Json_Get(main, ed, "maxCount")); maxCount > 0 {
						count := 0
						for o in LDtkDoc_Entities(s.cur) {
							oj := LDtkDoc_Json(s.cur, o.file)
							if Json_Int(oj, Json_Get(oj, o.node, "defUid")) == defUid do count += 1
						}
						if count >= maxCount do return fmt.tprintf("You cannot have more than %d %s.", maxCount, Json_String(main, Json_Get(main, ed, "identifier")))
					}
					append(&items, ldtkItemText(s.cur, file, entities, jvWith(moved, "iid", LDtk_NewIid())))
					continue
				}
				if out {
					removed[strings.clone(iid, context.temp_allocator)] = true
					continue
				}
				append(&items, ldtkItemText(s.cur, file, entities, moved))
				continue
			}
			// Only some of its points
			append(&items, ldtkItemText(s.cur, file, entities, pointsMoved(v, iid, delta, grid, copy_, false, deleting, movedPoints, {cWid, cHei})))
		}
		if dirty do ldtkRebuildRows(&q, s.cur, file, entities, items[:])
	}
	if problem = stagesApply(&s, &q); problem != "" do return
	if len(removed) > 0 {
		refs := LDtkPatches{}
		removeRefsToAny(&refs, s.cur, removed, minified)
		if problem = stagesApply(&s, &refs); problem != "" do return
	}
	if len(s.made) == 0 do return ""
	// 3. Auto-layers worked out again where cells moved (and where a Tiles layer kills their
	// tiles), then LDtk's tidy, neighbours, the table of contents
	if len(changed) > 0 {
		main := LDtkDoc_Main(s.cur)
		for d in Json_Items(main, LDtkDoc_Defs(s.cur, "layers")) {
			killer := nodeUid(main, Json_Get(main, d, "autoTilesKilledByOtherLayerUid"))
			if killer >= 0 && killer in changed do changed[Json_Int(main, Json_Get(main, d, "uid"))] = true
		}
		if problem = rerunRules(&s, changed, only = level); problem != "" do return
	}
	return LDtkOps_LevelsFinish(&s)
}
