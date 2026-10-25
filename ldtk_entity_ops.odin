package crossfire_editor

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strconv"
import "core:strings"

/*
The Level mode's entity edits (ldtk_ops.odin's `Entity_Added`, `Entity_Removed`,
`Entity_Resized`, `Entity_Duplicated`, `Entity_Point`, and entity references in arrays or
symmetrical ones), as LDtk makes them (its EntityTool, SelectionTool, ResizeTool, EntityInstance,
FieldInstance and Project):

- **Placing** (EntityTool.startUsing): a new instance with every field at its default
  (`realEditorValues` empty), its `__grid`, `__pivot`, `__tags`, `__tile` and `__smartColor`
  (EntityInstance.toJson: a field's tile or color when the field says so, else the definition's),
  `__worldX` / `__worldY` in Free and GridVania worlds. A type with a count limit (`maxCount`,
  `limitScope` per layer, level or world) discards its oldest instance (`DiscardOldOnes`), refuses
  (`PreventAdding`: LDtk's message) or moves its last one there (`MoveLastOne`).
- **Removing** (LayerInstance.removeEntityInstance) also removes every entity reference to it
  (Project.removeAnyFieldRefsTo: a single reference becomes the default, an array loses the item).
- **Resizing** (ResizeTool): the size within the type's minimum and maximum, the position moved
  when the pivot is on the dragged side (0 or 1), as there; the type's own size is written as
  such (no custom size).
- **Duplicating** (LayerInstance.duplicateEntityInstance): the instance's JSON copied whole with a
  new iid, then moved.
- **Points** (a `Point` field, `{cx, cy}` cells): set, added to an array, removed.
- **References** (FieldInstance.setEntityRefTo): an array gets one more (or one replaced); a
  symmetrical field also points the target back, and the old target forgets the source.
- The table of contents (`toc`) is built again as LDtk builds it (Project.updateTableOfContent),
  written only when it differs.

Values are written with LDtk's JSON writer (ldtk_json_pretty.odin), at the place's indentation.
*/

// A UUID for a new instance (LDtk's are version 1, time-based: any unique one reads the same)
LDtk_NewIid :: proc(allocator := context.temp_allocator) -> string {
	a, b := rand.uint64(), rand.uint64()
	return fmt.aprintf("%08x-%04x-1%03x-%04x-%012x", u32(a >> 32), u16(a >> 16), u16(a) & 0xFFF, (u16(b >> 48) & 0x3FFF) | 0x8000, b & 0xFFFFFFFFFFFF, allocator = allocator)
}

/*
A JSON value of a document as a value to write again (temp allocated): whole numbers as
integers, others as floats, as LDtk would have them.
*/
ldtkJV :: proc(json: ^JsonDoc, node: int) -> LDtkJV {
	switch Json_Kind(json, node) {
	case .Null:  return LDtkJNull{}
	case .True:  return true
	case .False: return false
	case .Number:
		text := Json_Text(json, node)
		if i, ok := strconv.parse_i64(text); ok do return i
		v, _ := strconv.parse_f64(text)
		return v
	case .String: return strings.clone(Json_String(json, node), context.temp_allocator)
	case .Array:
		items := Json_Items(json, node)
		out := make([]LDtkJV, len(items), context.temp_allocator)
		for item, i in items do out[i] = ldtkJV(json, item)
		return LDtkJArray(out)
	case .Object:
		items := Json_Items(json, node)
		out := make([]LDtkJPair, len(items), context.temp_allocator)
		for item, i in items do out[i] = {strings.clone(Json_Key(json, item), context.temp_allocator), ldtkJV(json, item)}
		return LDtkJObject(out)
	}
	return LDtkJNull{}
}

// A JSON text as a value to write (temp; null when it doesn't parse)
@(private)
textJV :: proc(text: string) -> LDtkJV {
	doc, problem := Json_Parse(text, context.temp_allocator)
	if problem != "" do return LDtkJNull{}
	return ldtkJV(&doc, 0)
}

// The text of a value as LDtk writes it at a node's place (its line's indentation)
@(private)
writeAt :: proc(json: ^JsonDoc, node: int, v: LDtkJV, minified: bool) -> string {
	return LDtk_PrettyJson(v, minified, LDtk_IndentAt(json.text, int(json.nodes[node].start)))
}

// An object member as a pair
@(private)
jpair :: #force_inline proc(key: string, value: LDtkJV) -> LDtkJPair {
	return {key, value}
}

// A list of values as an array (temp)
@(private)
jarray :: proc(items: ..LDtkJV) -> LDtkJV {
	out := make([]LDtkJV, len(items), context.temp_allocator)
	copy(out, items)
	return LDtkJArray(out)
}

// A list of pairs as an object (temp)
@(private)
jobject :: proc(pairs: ..LDtkJPair) -> LDtkJV {
	out := make([]LDtkJPair, len(pairs), context.temp_allocator)
	copy(out, pairs)
	return LDtkJObject(out)
}

/*
Edits applied in stages: each stage's patches are made on the document as the stages before left
it (a removal and an addition in one array can't be one set of patches), then the document gets
the last texts once.
*/
@(private)
Stages :: struct {
	base: ^LDtkDoc,
	texts: []string,
	// The document the next patches are made on (the base, or the last stage's)
	cur: ^LDtkDoc,
	made: [dynamic]^LDtkDoc,
}

@(private)
stagesMake :: proc(doc: ^LDtkDoc) -> Stages {
	return {base = doc, texts = LDtkDoc_Texts(doc), cur = doc, made = make([dynamic]^LDtkDoc, context.temp_allocator)}
}

// Applies a stage's patches; the next stage's are made on what they made
@(private)
stagesApply :: proc(s: ^Stages, patches: ^LDtkPatches) -> string {
	if LDtkPatches_Empty(patches) do return ""
	if problem := LDtkDoc_Apply(s.cur, s.texts, patches); problem != "" do return problem
	next := new(LDtkDoc, context.temp_allocator)
	next^ = LDtkDoc_FromTexts(s.base, s.texts)
	if next.problem != "" {
		problem := fmt.tprintf("%s", next.problem)
		LDtkDoc_Free(next)
		return problem
	}
	append(&s.made, next)
	s.cur = next
	return ""
}

// Gives the document the stages' texts (and frees them)
@(private)
stagesFinish :: proc(s: ^Stages, problem: string) -> string {
	defer for d in s.made do LDtkDoc_Free(d)
	if problem != "" do return problem
	if len(s.made) == 0 do return ""
	return LDtkDoc_SetTexts(s.base, s.texts)
}

// An item added at the end of an array, at the items' indentation (an empty array gets a line of its own)
@(private)
appendItem :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, file, array: int, item: LDtkJV, minified: bool) {
	json := LDtkDoc_Json(doc, file)
	n := json.nodes[array]
	if n.count > 0 {
		indent := LDtk_IndentAt(json.text, int(json.nodes[n.first].start))
		LDtkPatches_Add(p, file, Json_AppendPatch(json, array, LDtk_PrettyJson(item, minified, indent)))
		return
	}
	indent := LDtk_IndentAt(json.text, int(n.start))
	text := LDtk_PrettyJson(item, minified, indent + 1)
	if !minified {
		tabs := strings.repeat("\t", indent, context.temp_allocator)
		text = fmt.tprintf("[\n%s\t%s\n%s]", tabs, text, tabs)
	} else {
		text = fmt.tprintf("[%s]", text)
	}
	LDtkPatches_Add(p, file, Json_SetPatch(json, array, text))
}

// An entity definition's member as a float
@(private="file")
defFloat :: proc(main: ^JsonDoc, def: int, key: string, default: f64 = 0) -> f64 {
	return Json_Float(main, Json_Get(main, def, key), default)
}

// A field definition's default as `__value` (LDtk's FieldInstance.getFullJsonValue on a new instance)
@(private="file")
fieldDefault :: proc(doc: ^LDtkDoc, fieldDef: int) -> LDtkJV {
	main := LDtkDoc_Main(doc)
	info := LDtkDoc_FieldInfo(doc, fieldDef)
	return textJV(ldtkDefaultText(info, Json_Text(main, Json_Get(main, fieldDef, "defaultOverride"))))
}

// An enum value's node (-1 none)
@(private)
enumValue :: proc(doc: ^LDtkDoc, enumUid: int, id: string) -> (def, value: int) {
	main := LDtkDoc_Main(doc)
	def = LDtkDoc_DefByUid(doc, "enums", enumUid)
	if def < 0 do def = LDtkDoc_DefByUid(doc, "externalEnums", enumUid)
	for v in Json_Items(main, Json_Get(main, def, "values")) do if Json_String(main, Json_Get(main, v, "id")) == id do return def, v
	return def, -1
}

// A new field instance's `__tile` (FieldInstance.getSmartTile: an enum value's icon, shown as the entity's tile)
@(private="file")
fieldTile :: proc(doc: ^LDtkDoc, fieldDef: int, value: LDtkJV) -> LDtkJV {
	main := LDtkDoc_Main(doc)
	info := LDtkDoc_FieldInfo(doc, fieldDef)
	if info.type != .Enum || info.isArray || Json_String(main, Json_Get(main, fieldDef, "editorDisplayMode")) != "EntityTile" do return LDtkJNull{}
	id, isString := value.(string)
	if !isString do return LDtkJNull{}
	def, v := enumValue(doc, info.enumUid, id)
	if def < 0 || v < 0 || Json_Kind(main, Json_Get(main, def, "iconTilesetUid")) != .Number do return LDtkJNull{}
	return ldtkJV(main, Json_Get(main, v, "tileRect"))
}

// A new field instance's smart color (FieldInstance.getSmartColor), false when it gives none
@(private="file")
fieldColor :: proc(doc: ^LDtkDoc, fieldDef: int, value: LDtkJV) -> (int, bool) {
	main := LDtkDoc_Main(doc)
	if !Json_Bool(main, Json_Get(main, fieldDef, "useForSmartColor")) do return 0, false
	info := LDtkDoc_FieldInfo(doc, fieldDef)
	text, isString := value.(string)
	if !isString do return 0, false
	#partial switch info.type {
	case .Color:
		return LDtk_ParseColor(text)
	case .Enum:
		_, v := enumValue(doc, info.enumUid, text)
		if v >= 0 do return Json_Int(main, Json_Get(main, v, "color")), true
	}
	return 0, false
}

/*
A new instance of an entity type as LDtk writes it (EntityInstance.toJson after `tidy`: every
field at its default).

Inputs:
- def: The entity definition's node
- grid: Its layer's grid size
- world: The level's world position, and whether the world stores entities' world positions
*/
@(private="file")
newEntityJson :: proc(doc: ^LDtkDoc, def: int, iid: string, x, y, grid: int, world: [2]int, worldPositions: bool) -> LDtkJV {
	main := LDtkDoc_Main(doc)
	pivotX, pivotY := defFloat(main, def, "pivotX", 0.5), defFloat(main, def, "pivotY", 0.5)
	width := Json_Int(main, Json_Get(main, def, "width"), 16)
	height := Json_Int(main, Json_Get(main, def, "height"), 16)
	tags := make([dynamic]LDtkJV, context.temp_allocator)
	for t in Json_Items(main, Json_Get(main, def, "tags")) do append(&tags, strings.clone(Json_String(main, t), context.temp_allocator))
	fields := make([dynamic]LDtkJV, context.temp_allocator)
	tile := LDtkJV(LDtkJNull{})
	tiled := false
	color, colored := 0, false
	for fd in Json_Items(main, Json_Get(main, def, "fieldDefs")) {
		value := fieldDefault(doc, fd)
		ft := fieldTile(doc, fd, value)
		if _, none := ft.(LDtkJNull); !none && !tiled do tile, tiled = ft, true
		if c, ok := fieldColor(doc, fd, value); ok && !colored do color, colored = c, true
		append(&fields, jobject(
			jpair("__identifier", strings.clone(Json_String(main, Json_Get(main, fd, "identifier")), context.temp_allocator)),
			jpair("__type", strings.clone(Json_String(main, Json_Get(main, fd, "__type")), context.temp_allocator)),
			jpair("__value", value),
			jpair("__tile", ft),
			jpair("defUid", i64(Json_Int(main, Json_Get(main, fd, "uid")))),
			jpair("realEditorValues", jarray()),
		))
	}
	// EntityDef.getDefaultTile: the entity's own tile when the fields give none
	if !tiled {
		rect := Json_Get(main, def, "tileRect")
		if Json_Kind(main, rect) == .Object && Json_Kind(main, Json_Get(main, def, "tilesetId")) == .Number do tile = ldtkJV(main, rect)
	}
	if !colored do color, _ = LDtk_ParseColor(Json_String(main, Json_Get(main, def, "color")))
	cx := (x + (pivotX == 1 ? -1 : 0)) / max(grid, 1)
	cy := (y + (pivotY == 1 ? -1 : 0)) / max(grid, 1)
	pairs := make([dynamic]LDtkJPair, context.temp_allocator)
	append(&pairs,
		jpair("__identifier", strings.clone(Json_String(main, Json_Get(main, def, "identifier")), context.temp_allocator)),
		jpair("__grid", jarray(i64(cx), i64(cy))),
		jpair("__pivot", jarray(pivotX, pivotY)),
		jpair("__tags", LDtkJArray(tags[:])),
		jpair("__tile", tile),
		jpair("__smartColor", LDtk_FormatColor(color)),
		jpair("iid", iid),
		jpair("width", i64(width)),
		jpair("height", i64(height)),
		jpair("defUid", i64(Json_Int(main, Json_Get(main, def, "uid")))),
		jpair("px", jarray(i64(x), i64(y))),
		jpair("fieldInstances", LDtkJArray(fields[:])),
	)
	if worldPositions do append(&pairs, jpair("__worldX", i64(world.x + x)), jpair("__worldY", i64(world.y + y)))
	return LDtkJObject(pairs[:])
}

// Whether a level's world stores entities' world positions (Free and GridVania worlds)
@(private)
storesWorldPositions :: proc(doc: ^LDtkDoc, level: int) -> bool {
	layout := LDtkDoc_WorldLayout(doc, doc.levels[level].world)
	return layout == "Free" || layout == "GridVania" || layout == ""
}

// The patches removing every entity reference to an iid (Project.removeAnyFieldRefsTo)
@(private)
removeRefsTo :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, iid: string, minified: bool) {
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		for fi in Json_Items(json, Json_Get(json, e.node, "fieldInstances")) {
			t := Json_String(json, Json_Get(json, fi, "__type"))
			if t != "EntityRef" && t != "Array<EntityRef>" do continue
			value := Json_Get(json, fi, "__value")
			raw := Json_Get(json, fi, "realEditorValues")
			if t == "EntityRef" {
				if Json_String(json, Json_Get(json, value, "entityIid")) == iid {
					LDtkPatches_Set(p, doc, e.file, value, "null")
					LDtkPatches_Set(p, doc, e.file, raw, "[]")
				}
				continue
			}
			values := Json_Items(json, value)
			raws := Json_Items(json, raw)
			keptValues := make([dynamic]LDtkJV, context.temp_allocator)
			keptRaws := make([dynamic]LDtkJV, context.temp_allocator)
			removed := false
			for v, i in values {
				if Json_String(json, Json_Get(json, v, "entityIid")) == iid {
					removed = true
					continue
				}
				append(&keptValues, ldtkJV(json, v))
				if i < len(raws) do append(&keptRaws, ldtkJV(json, raws[i]))
			}
			if !removed do continue
			LDtkPatches_Set(p, doc, e.file, value, writeAt(json, fi, LDtkJArray(keptValues[:]), minified))
			LDtkPatches_Set(p, doc, e.file, raw, writeAt(json, fi, LDtkJArray(keptRaws[:]), minified))
		}
	}
}

/*
The table of contents as LDtk builds it (Project.updateTableOfContent): an entry per entity type
exported to it, its instances' references, world positions, sizes and exported fields; written
when it differs from the file's (the same values in another layout are left as written).
*/
ldtkTocPatches :: proc(p: ^LDtkPatches, doc: ^LDtkDoc) {
	main := LDtkDoc_Main(doc)
	rootNode := Json_Root(main)
	toc := Json_Get(main, rootNode, "toc")
	if toc < 0 do return
	oldData := false
	for f in Json_Items(main, Json_Get(main, rootNode, "flags")) do if Json_String(main, f) == "ExportOldTableOfContentData" do oldData = true
	minified := Json_Minified(main)
	entries := make([dynamic]LDtkJV, context.temp_allocator)
	for ed in Json_Items(main, LDtkDoc_Defs(doc, "entities")) {
		if !Json_Bool(main, Json_Get(main, ed, "exportToToc")) do continue
		uid := Json_Int(main, Json_Get(main, ed, "uid"))
		exported := make(map[int]bool, context.temp_allocator)
		for fd in Json_Items(main, Json_Get(main, ed, "fieldDefs")) do if Json_Bool(main, Json_Get(main, fd, "exportToToc")) do exported[Json_Int(main, Json_Get(main, fd, "uid"))] = true
		instances := make([dynamic]LDtkJV, context.temp_allocator)
		data := make([dynamic]LDtkJV, context.temp_allocator)
		for e in LDtkDoc_Entities(doc) {
			json := LDtkDoc_Json(doc, e.file)
			if Json_Int(json, Json_Get(json, e.node, "defUid"), -1) != uid do continue
			_, levelIid := LDtkDoc_LevelNames(doc, e.level)
			_, worldIid := LDtkDoc_WorldNames(doc, doc.levels[e.level].world)
			ref := jobject(
				jpair("worldIid", strings.clone(worldIid, context.temp_allocator)),
				jpair("levelIid", strings.clone(levelIid, context.temp_allocator)),
				jpair("layerIid", strings.clone(Json_String(json, Json_Get(json, e.layer, "iid")), context.temp_allocator)),
				jpair("entityIid", strings.clone(Json_String(json, Json_Get(json, e.node, "iid")), context.temp_allocator)),
			)
			if oldData do append(&instances, ref)
			fields := make([dynamic]LDtkJPair, context.temp_allocator)
			for fi in Json_Items(json, Json_Get(json, e.node, "fieldInstances")) {
				if Json_Int(json, Json_Get(json, fi, "defUid"), -1) not_in exported do continue
				append(&fields, jpair(strings.clone(Json_String(json, Json_Get(json, fi, "__identifier")), context.temp_allocator), ldtkJV(json, Json_Get(json, fi, "__value"))))
			}
			rect := LDtkDoc_LevelRect(doc, e.level)
			px := Json_Get(json, e.node, "px")
			append(&data, jobject(
				jpair("iids", ref),
				jpair("worldX", i64(int(rect[0]) + Json_Int(json, Json_At(json, px, 0)))),
				jpair("worldY", i64(int(rect[1]) + Json_Int(json, Json_At(json, px, 1)))),
				jpair("widPx", i64(Json_Int(json, Json_Get(json, e.node, "width")))),
				jpair("heiPx", i64(Json_Int(json, Json_Get(json, e.node, "height")))),
				jpair("fields", LDtkJObject(fields[:])),
			))
		}
		append(&entries, jobject(
			jpair("identifier", strings.clone(Json_String(main, Json_Get(main, ed, "identifier")), context.temp_allocator)),
			jpair("instances", LDtkJArray(instances[:])),
			jpair("instancesData", LDtkJArray(data[:])),
		))
	}
	text := writeAt(main, toc, LDtkJArray(entries[:]), minified)
	made, problem := Json_Parse(text, context.temp_allocator)
	if problem != "" || jsonSameValue(main, toc, &made, 0) do return
	LDtkPatches_Set(p, doc, 0, toc, text)
}

// The instances of an entity type in a limit's scope (Project.getAllEntitiesFromLimitScope), in order
@(private="file")
inScope :: proc(doc: ^LDtkDoc, defUid: int, scope: string, level, layerDef: int) -> []LDtkDocEntity {
	out := make([dynamic]LDtkDocEntity, context.temp_allocator)
	world := doc.levels[level].world
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		if Json_Int(json, Json_Get(json, e.node, "defUid"), -1) != defUid do continue
		switch scope {
		case "PerLevel":
			if e.level != level do continue
		case "PerWorld":
			if doc.levels[e.level].world != world do continue
		case:
			// PerLayer (LDtk's default)
			if e.level != level || Json_Int(json, Json_Get(json, e.layer, "layerDefUid"), -1) != layerDef do continue
		}
		append(&out, e)
	}
	return out[:]
}

// A level's layer instance of a layer definition (-1 none)
@(private="file")
layerInstanceOf :: proc(doc: ^LDtkDoc, level, layerDef: int) -> (file, node: int) {
	f, array := LDtkDoc_LayerInstances(doc, level)
	json := LDtkDoc_Json(doc, f)
	for li in Json_Items(json, array) do if Json_Int(json, Json_Get(json, li, "layerDefUid"), -1) == layerDef do return f, li
	return f, -1
}

/*
The entity edits painting makes (ldtk_ops.odin's `Entity_Added`, `Entity_Removed`,
`Entity_Resized`, `Entity_Duplicated`, `Entity_Point`; array and symmetrical `Entity_Ref`s).

Returns:
- "" or why nothing changed
*/
LDtkOps_EntityEdit :: proc(doc: ^LDtkDoc, edit: LDtk_Edit) -> string {
	main := LDtkDoc_Main(doc)
	minified := Json_Minified(main)
	s := stagesMake(doc)
	problem := ""
	defer if problem != "" do for d in s.made do LDtkDoc_Free(d)
	#partial switch edit.op {
	case .Entity_Added:
		level := LDtkDoc_FindLevel(doc, edit.level)
		if level < 0 do return "no such level"
		def := LDtkDoc_DefByUid(doc, "entities", edit.def)
		if def < 0 do return "no such entity type"
		file, li := layerInstanceOf(doc, level, edit.index)
		if li < 0 do return "the level has no such layer"
		x, y := int(math.round(edit.number)), int(math.round(edit.number2))
		maxCount := Json_Int(main, Json_Get(main, def, "maxCount"))
		identifier := Json_String(main, Json_Get(main, def, "identifier"))
		moved := ""
		if maxCount > 0 {
			scope := Json_String(main, Json_Get(main, def, "limitScope"))
			all := inScope(doc, edit.def, scope, level, edit.index)
			switch Json_String(main, Json_Get(main, def, "limitBehavior")) {
			case "PreventAdding":
				if len(all) >= maxCount do return fmt.tprintf("You cannot have more than %d %s.", maxCount, identifier)
			case "DiscardOldOnes":
				if len(all) >= maxCount {
					// The oldest go, and every reference to them
					p := LDtkPatches{}
					for e, i in all {
						if i > len(all) - maxCount do break
						json := LDtkDoc_Json(doc, e.file)
						LDtkPatches_Add(&p, e.file, Json_RemovePatch(json, e.node))
					}
					if problem = stagesApply(&s, &p); problem != "" do return problem
					refs := LDtkPatches{}
					for e, i in all {
						if i > len(all) - maxCount do break
						json := LDtkDoc_Json(doc, e.file)
						removeRefsTo(&refs, s.cur, Json_String(json, Json_Get(json, e.node, "iid")), minified)
					}
					if problem = stagesApply(&s, &refs); problem != "" do return problem
				}
			case "MoveLastOne":
				if len(all) >= maxCount && len(all) > 0 {
					// The last one moves here (kept whole: its iid and fields)
					last := all[len(all) - 1]
					json := LDtkDoc_Json(doc, last.file)
					moved = strings.clone(Json_String(json, Json_Get(json, last.node, "iid")), context.temp_allocator)
					item := ldtkJV(json, last.node)
					p := LDtkPatches{}
					LDtkPatches_Add(&p, last.file, Json_RemovePatch(json, last.node))
					if problem = stagesApply(&s, &p); problem != "" do return problem
					f2, li2 := layerInstanceOf(s.cur, level, edit.index)
					add := LDtkPatches{}
					appendItem(&add, s.cur, f2, Json_Get(LDtkDoc_Json(s.cur, f2), li2, "entityInstances"), item, minified)
					if problem = stagesApply(&s, &add); problem != "" do return problem
				}
			}
		}
		if moved != "" {
			// The moved one takes the new place
			if problem = moveEntity(&s, moved, x, y, minified); problem != "" do return problem
		} else {
			f2, li2 := layerInstanceOf(s.cur, level, edit.index)
			if li2 < 0 do return "the level has no such layer"
			_ = file
			_ = li
			rect := LDtkDoc_LevelRect(s.cur, level)
			grid := max(Json_Int(LDtkDoc_Json(s.cur, f2), Json_Get(LDtkDoc_Json(s.cur, f2), li2, "__gridSize"), 16), 1)
			iid := edit.entity != "" ? edit.entity : LDtk_NewIid()
			item := newEntityJson(s.cur, LDtkDoc_DefByUid(s.cur, "entities", edit.def), iid, x, y, grid, {int(rect[0]), int(rect[1])}, storesWorldPositions(s.cur, level))
			add := LDtkPatches{}
			appendItem(&add, s.cur, f2, Json_Get(LDtkDoc_Json(s.cur, f2), li2, "entityInstances"), item, minified)
			if problem = stagesApply(&s, &add); problem != "" do return problem
		}
	case .Entity_Removed:
		e, found := LDtkDoc_FindEntity(doc, edit.entity)
		if !found do return "no such entity"
		json := LDtkDoc_Json(doc, e.file)
		p := LDtkPatches{}
		LDtkPatches_Add(&p, e.file, Json_RemovePatch(json, e.node))
		if problem = stagesApply(&s, &p); problem != "" do return problem
		refs := LDtkPatches{}
		removeRefsTo(&refs, s.cur, edit.entity, minified)
		if problem = stagesApply(&s, &refs); problem != "" do return problem
	case .Entity_Resized:
		e, found := LDtkDoc_FindEntity(doc, edit.entity)
		if !found do return "no such entity"
		json := LDtkDoc_Json(doc, e.file)
		def := LDtkDoc_DefByUid(doc, "entities", Json_Int(json, Json_Get(json, e.node, "defUid"), -1))
		w := max(int(math.round(edit.number3)), 1)
		h := max(int(math.round(edit.number4)), 1)
		p := LDtkPatches{}
		LDtkPatches_Set(&p, doc, e.file, Json_Get(json, e.node, "width"), fmt.tprint(w))
		LDtkPatches_Set(&p, doc, e.file, Json_Get(json, e.node, "height"), fmt.tprint(h))
		x, y := int(math.round(edit.number)), int(math.round(edit.number2))
		LDtkPatches_Set(&p, doc, e.file, Json_Get(json, e.node, "px"), LDtk_PrettyJson(jarray(i64(x), i64(y)), minified))
		ldtkSetGridPivot(&p, doc, e.file, e.node, ldtkInstanceGrid(doc, e), defFloat(main, def, "pivotX", 0.5), defFloat(main, def, "pivotY", 0.5), [2]int{x, y})
		if problem = stagesApply(&s, &p); problem != "" do return problem
	case .Entity_Duplicated:
		e, found := LDtkDoc_FindEntity(doc, edit.entity)
		if !found do return "no such entity"
		json := LDtkDoc_Json(doc, e.file)
		copyIid := edit.text != "" ? edit.text : LDtk_NewIid()
		item := ldtkJV(json, e.node)
		if obj, ok := item.(LDtkJObject); ok do for &pair in obj do if pair.key == "iid" do pair.value = copyIid
		p := LDtkPatches{}
		appendItem(&p, doc, e.file, Json_Get(json, e.layer, "entityInstances"), item, minified)
		if problem = stagesApply(&s, &p); problem != "" do return problem
		if problem = moveEntity(&s, copyIid, int(math.round(edit.number)), int(math.round(edit.number2)), minified); problem != "" do return problem
	case .Entity_Point:
		if problem = setPoint(&s, edit, minified); problem != "" do return problem
	case .Entity_Ref:
		if problem = setRef(&s, edit, minified); problem != "" do return problem
	}
	// What LDtk derives: world positions, the table of contents
	more := LDtkPatches{}
	refreshEntityWorlds(&more, s.cur)
	ldtkTocPatches(&more, s.cur)
	if problem = stagesApply(&s, &more); problem != "" do return problem
	result := stagesFinish(&s, "")
	s.made = nil
	return result
}

// An entity's px and `__grid` at a new place (a stage)
@(private="file")
moveEntity :: proc(s: ^Stages, iid: string, x, y: int, minified: bool) -> string {
	e, found := LDtkDoc_FindEntity(s.cur, iid)
	if !found do return "no such entity"
	json := LDtkDoc_Json(s.cur, e.file)
	main := LDtkDoc_Main(s.cur)
	def := LDtkDoc_DefByUid(s.cur, "entities", Json_Int(json, Json_Get(json, e.node, "defUid"), -1))
	p := LDtkPatches{}
	LDtkPatches_Set(&p, s.cur, e.file, Json_Get(json, e.node, "px"), LDtk_PrettyJson(jarray(i64(x), i64(y)), minified))
	ldtkSetGridPivot(&p, s.cur, e.file, e.node, ldtkInstanceGrid(s.cur, e), defFloat(main, def, "pivotX", 0.5), defFloat(main, def, "pivotY", 0.5), [2]int{x, y})
	return stagesApply(s, &p)
}

// Entities' `__worldX` / `__worldY` from their level's place (where the file has them)
@(private="file")
refreshEntityWorlds :: proc(p: ^LDtkPatches, doc: ^LDtkDoc) {
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		rect := LDtkDoc_LevelRect(doc, e.level)
		px := Json_Get(json, e.node, "px")
		wx, wy := Json_Get(json, e.node, "__worldX"), Json_Get(json, e.node, "__worldY")
		if Json_Kind(json, wx) == .Number do LDtkPatches_Set(p, doc, e.file, wx, fmt.tprint(int(rect[0]) + Json_Int(json, Json_At(json, px, 0))))
		if Json_Kind(json, wy) == .Number do LDtkPatches_Set(p, doc, e.file, wy, fmt.tprint(int(rect[1]) + Json_Int(json, Json_At(json, px, 1))))
	}
}

// An entity's field instance of a field definition (-1 none)
@(private="file")
fieldOf :: proc(doc: ^LDtkDoc, e: LDtkDocEntity, fieldUid: int) -> int {
	json := LDtkDoc_Json(doc, e.file)
	for fi in Json_Items(json, Json_Get(json, e.node, "fieldInstances")) do if Json_Int(json, Json_Get(json, fi, "defUid"), -1) == fieldUid do return fi
	return -1
}

// A field instance's values as lists (`__value` items and `realEditorValues` items; a single one as one item)
@(private="file")
fieldLists :: proc(json: ^JsonDoc, fi: int, isArray: bool) -> (values, raws: [dynamic]LDtkJV) {
	values = make([dynamic]LDtkJV, context.temp_allocator)
	raws = make([dynamic]LDtkJV, context.temp_allocator)
	v := Json_Get(json, fi, "__value")
	if isArray {
		for item in Json_Items(json, v) do append(&values, ldtkJV(json, item))
	} else {
		append(&values, ldtkJV(json, v))
	}
	for item in Json_Items(json, Json_Get(json, fi, "realEditorValues")) do append(&raws, ldtkJV(json, item))
	return
}

// Writes a field instance's lists back (a single value: its first item, or the default's null)
@(private="file")
writeFieldLists :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, file, fi: int, isArray: bool, values, raws: []LDtkJV, minified: bool) {
	json := LDtkDoc_Json(doc, file)
	value := LDtkJV(LDtkJArray(values))
	if !isArray do value = len(values) > 0 ? values[0] : LDtkJV(LDtkJNull{})
	LDtkPatches_Set(p, doc, file, Json_Get(json, fi, "__value"), writeAt(json, fi, value, minified))
	LDtkPatches_Set(p, doc, file, Json_Get(json, fi, "realEditorValues"), writeAt(json, fi, LDtkJArray(raws), minified))
}

// A point field's point set, added or removed (a stage)
@(private="file")
setPoint :: proc(s: ^Stages, edit: LDtk_Edit, minified: bool) -> string {
	doc := s.cur
	e, found := LDtkDoc_FindEntity(doc, edit.entity)
	if !found do return "no such entity"
	_, fieldDef := LDtkDoc_FieldDef(doc, edit.field)
	if fieldDef < 0 do return "no such field"
	info := LDtkDoc_FieldInfo(doc, fieldDef)
	if info.type != .Point do return "not a point field"
	fi := fieldOf(doc, e, edit.field)
	if fi < 0 do return "this field has no value in the file yet: open and save it in LDtk once"
	json := LDtkDoc_Json(doc, e.file)
	values, raws := fieldLists(json, fi, info.isArray)
	cx, cy := int(math.round(edit.number)), int(math.round(edit.number2))
	point := jobject(jpair("cx", i64(cx)), jpair("cy", i64(cy)))
	raw := jobject(jpair("id", "V_String"), jpair("params", jarray(fmt.tprintf("%d,%d", cx, cy))))
	if !info.isArray {
		clear(&values)
		clear(&raws)
		if edit.flag {
			// Removed: the default (FieldInstance.parseValue(null))
			append(&values, textJV(info.defaultText))
		} else {
			append(&values, point)
			append(&raws, raw)
		}
	} else {
		// realEditorValues has an item per value (null for a value at its default)
		for len(raws) < len(values) do append(&raws, LDtkJNull{})
		switch {
		case edit.flag:
			if edit.index < 0 || edit.index >= len(values) do return "no such point"
			ordered_remove(&values, edit.index)
			ordered_remove(&raws, edit.index)
		case edit.index < 0 || edit.index >= len(values):
			append(&values, point)
			append(&raws, raw)
		case:
			values[edit.index] = point
			raws[edit.index] = raw
		}
	}
	p := LDtkPatches{}
	writeFieldLists(&p, doc, e.file, fi, info.isArray, values[:], raws[:], minified)
	return stagesApply(s, &p)
}

// An entity reference's `__value` as LDtk writes it (EntityReferenceInfos)
@(private="file")
refJV :: proc(doc: ^LDtkDoc, target: LDtkDocEntity) -> LDtkJV {
	json := LDtkDoc_Json(doc, target.file)
	_, levelIid := LDtkDoc_LevelNames(doc, target.level)
	_, worldIid := LDtkDoc_WorldNames(doc, doc.levels[target.level].world)
	return jobject(
		jpair("entityIid", strings.clone(Json_String(json, Json_Get(json, target.node, "iid")), context.temp_allocator)),
		jpair("layerIid", strings.clone(Json_String(json, Json_Get(json, target.layer, "iid")), context.temp_allocator)),
		jpair("levelIid", strings.clone(levelIid, context.temp_allocator)),
		jpair("worldIid", strings.clone(worldIid, context.temp_allocator)),
	)
}

/*
An entity reference set (FieldInstance.setEntityRefTo): in an array, at `index` (-1 a new item;
an empty target removes the item there); a symmetrical field points the target back and the old
target forgets the source (EntityInstance.tidyLostSymmetricalEntityRefs).
*/
@(private="file")
setRef :: proc(s: ^Stages, edit: LDtk_Edit, minified: bool) -> string {
	doc := s.cur
	e, found := LDtkDoc_FindEntity(doc, edit.entity)
	if !found do return "no such entity"
	_, fieldDef := LDtkDoc_FieldDef(doc, edit.field)
	if fieldDef < 0 do return "no such field"
	info := LDtkDoc_FieldInfo(doc, fieldDef)
	fi := fieldOf(doc, e, edit.field)
	if fi < 0 do return "this field has no value in the file yet: open and save it in LDtk once"
	json := LDtkDoc_Json(doc, e.file)
	values, raws := fieldLists(json, fi, info.isArray)
	for len(raws) < len(values) do append(&raws, LDtkJNull{})
	sourceIid := strings.clone(edit.entity, context.temp_allocator)
	// The old target (a single reference's, or the replaced item's)
	oldTarget := ""
	at := info.isArray ? edit.index : 0
	if at >= 0 && at < len(values) {
		if obj, ok := values[at].(LDtkJObject); ok do for pair in obj do if pair.key == "entityIid" do oldTarget, _ = pair.value.(string)
	}
	target: LDtkDocEntity
	if edit.text != "" {
		t, ok := LDtkDoc_FindEntity(doc, edit.text)
		if !ok do return "no such target"
		if !LDtkOps_RefAllowed(doc, info, e, t) do return "this field can't point at that entity"
		target = t
		ref := refJV(doc, t)
		raw := jobject(jpair("id", "V_String"), jpair("params", jarray(strings.clone(edit.text, context.temp_allocator))))
		if !info.isArray {
			clear(&values)
			clear(&raws)
			append(&values, ref)
			append(&raws, raw)
		} else if at < 0 || at >= len(values) {
			append(&values, ref)
			append(&raws, raw)
		} else {
			values[at] = ref
			raws[at] = raw
		}
	} else {
		if !info.isArray {
			clear(&values)
			clear(&raws)
		} else if at >= 0 && at < len(values) {
			ordered_remove(&values, at)
			ordered_remove(&raws, at)
		}
	}
	p := LDtkPatches{}
	writeFieldLists(&p, doc, e.file, fi, info.isArray, values[:], raws[:], minified)
	if problem := stagesApply(s, &p); problem != "" do return problem
	if !info.symmetrical do return ""
	// The target points back (when it has the field), the old target forgets the source
	if edit.text != "" && edit.text != sourceIid {
		doc = s.cur
		t, ok := LDtkDoc_FindEntity(doc, edit.text)
		src, _ := LDtkDoc_FindEntity(doc, sourceIid)
		if ok {
			tfi := fieldOf(doc, t, edit.field)
			if tfi >= 0 {
				tjson := LDtkDoc_Json(doc, t.file)
				tv, tr := fieldLists(tjson, tfi, info.isArray)
				for len(tr) < len(tv) do append(&tr, LDtkJNull{})
				has := false
				for v in tv do if obj, isObj := v.(LDtkJObject); isObj do for pair in obj do if pair.key == "entityIid" {
					if id, _ := pair.value.(string); id == sourceIid do has = true
				}
				if !has {
					back := refJV(doc, src)
					raw := jobject(jpair("id", "V_String"), jpair("params", jarray(sourceIid)))
					if !info.isArray {
						clear(&tv)
						clear(&tr)
					}
					append(&tv, back)
					append(&tr, raw)
					bp := LDtkPatches{}
					writeFieldLists(&bp, doc, t.file, tfi, info.isArray, tv[:], tr[:], minified)
					if problem := stagesApply(s, &bp); problem != "" do return problem
				}
			}
		}
	}
	_ = target
	if oldTarget != "" && oldTarget != edit.text {
		doc = s.cur
		if o, ok := LDtkDoc_FindEntity(doc, oldTarget); ok {
			ofi := fieldOf(doc, o, edit.field)
			if ofi >= 0 {
				ojson := LDtkDoc_Json(doc, o.file)
				ov, or_ := fieldLists(ojson, ofi, info.isArray)
				for len(or_) < len(ov) do append(&or_, LDtkJNull{})
				keptV := make([dynamic]LDtkJV, context.temp_allocator)
				keptR := make([dynamic]LDtkJV, context.temp_allocator)
				removed := false
				for v, i in ov {
					points := false
					if obj, isObj := v.(LDtkJObject); isObj do for pair in obj do if pair.key == "entityIid" {
						if id, _ := pair.value.(string); id == sourceIid do points = true
					}
					if points {
						removed = true
						continue
					}
					append(&keptV, v)
					append(&keptR, or_[i])
				}
				if removed {
					if !info.isArray {
						clear(&keptV)
						clear(&keptR)
					}
					op := LDtkPatches{}
					writeFieldLists(&op, doc, o.file, ofi, info.isArray, keptV[:], keptR[:], minified)
					if problem := stagesApply(s, &op); problem != "" do return problem
				}
			}
		}
	}
	return ""
}
