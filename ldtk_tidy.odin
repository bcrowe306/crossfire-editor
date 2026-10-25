package crossfire_editor

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:strconv"
import "core:strings"

/*
LDtk's tidy, ported (its Project.tidy, Definitions.tidy, Level.tidy, LayerInstance.tidy,
EntityInstance.tidy, FieldInstance.tidy, and what their toJson derive from the definitions): after
a definition changes (ldtk_defs.odin), the levels' instances are brought in step with the
definitions as LDtk brings them, in two passes over the document:

1. **The definitions** (`tidyDefs`): a layer's lost tileset, source layer or biome field becomes
   null (and an IntGrid layer without a tileset keeps no rules: LayerDef.toJson); an entity's lost
   tileset makes it a Rectangle; enum fields of a lost enum are removed, a lost tileset or enum
   default cleared (FieldDef.tidy), `__type` written again (LocalEnum / ExternEnum, Array<>,
   Multilines with the project's flag); an enum's lost icon tileset clears its tiles; a tileset's
   `__cWid` / `__cHei`, its lost tag enum cleared, its `enumTags` one entry per value of its enum
   (TilesetDef.toJson); nine-slice borders only for NineSlice.
2. **The instances** (`tidyStructure`, then `tidyValues`): every level has a layer instance per
   layer definition, in their order (new ones empty: LayerInstance.toJson), lost ones removed;
   entities of a lost type removed; field instances one per field definition, in its order (new
   ones at the default), lost ones removed; then every derived value written where it differs:
   a layer instance's `__identifier`, `__type`, `__cWid`, `__cHei`, `__gridSize`, `__opacity`,
   `__pxTotalOffsetX/Y`, `__tilesetDefUid`, `__tilesetRelPath`, its lost optional rule groups and
   lost rules' tiles; an entity's `__identifier`, `__grid`, `__pivot`, `__tags`, `__tile`,
   `__smartColor`; a field's `__identifier`, `__type`, `__value` (from `realEditorValues` and the
   definition: FieldInstance.getJsonValue, its clamps and defaults), `__tile`, its lost enum
   values, tiles and references cleared, points outside the layer removed; a level's
   `__smartColor` (Level.getSmartColor).

Nothing changes in a file that's already as LDtk would write it (a test runs it over LDtk's own
samples): values are compared, not texts, and only those that differ are written, LDtk's way
(ldtk_json_pretty.odin). Scanning every IntGrid cell for lost values and writing Tiles layers'
`src` again are asked for (`LDtkTidyScope`): the edits that can change them say so.
*/

// What a tidy also looks at (beyond what any definition edit can change)
LDtkTidyScope :: struct {
	// IntGrid cells whose value the layer no longer has become 0 (an IntGrid value removed)
	intGrid: bool,
	// Tiles layers' tiles get their `src` from their tileset again (a tileset's grid, spacing,
	// padding or image changed)
	gridTiles: bool,
}

/*
Brings a document's instances in step with its definitions, as LDtk's tidy does (the stages'
current document; each pass's patches applied before the next is made).

Returns:
- "" or what went wrong
*/
LDtkTidy_Run :: proc(s: ^Stages, scope: LDtkTidyScope = {}) -> string {
	p := LDtkPatches{}
	tidyDefs(&p, s.cur)
	if problem := stagesApply(s, &p); problem != "" do return problem
	p = {}
	tidyStructure(&p, s.cur)
	if problem := stagesApply(s, &p); problem != "" do return problem
	p = {}
	tidyValues(&p, s.cur, scope)
	if problem := stagesApply(s, &p); problem != "" do return problem
	p = {}
	ldtkTocPatches(&p, s.cur)
	return stagesApply(s, &p)
}

// --- Values compared and written -------------------------------------------------------------

// Whether a node holds a value (missing counts as null)
@(private)
jvSame :: proc(json: ^JsonDoc, node: int, v: LDtkJV) -> bool {
	switch x in v {
	case LDtkJNull: return Json_Kind(json, node) == .Null
	case i64:
		n, ok := Json_Number(json, node)
		return ok && n == f64(x)
	case f64:
		n, ok := Json_Number(json, node)
		return ok && n == x
	case bool:
		k := Json_Kind(json, node)
		return (k == .True && x) || (k == .False && !x)
	case string: return Json_Kind(json, node) == .String && Json_String(json, node) == x
	case LDtkJArray:
		if Json_Kind(json, node) != .Array || Json_Count(json, node) != len(x) do return false
		i := 0
		for c := json.nodes[node].first; c >= 0; c = json.nodes[c].next {
			if !jvSame(json, int(c), x[i]) do return false
			i += 1
		}
		return true
	case LDtkJObject:
		if Json_Kind(json, node) != .Object || Json_Count(json, node) != len(x) do return false
		for pair in x do if !jvSame(json, Json_Get(json, node, pair.key), pair.value) do return false
		return true
	}
	return false
}

// Writes an object's member where its value differs (a member the object lacks is left: LDtk's
// files have them all, and other files keep their own shape)
@(private)
tidySet :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, file, object: int, key: string, v: LDtkJV) {
	json := LDtkDoc_Json(doc, file)
	member := Json_Get(json, object, key)
	if member < 0 || jvSame(json, member, v) do return
	LDtkPatches_Add(p, file, Json_SetPatch(json, member, writeAt(json, member, v, Json_Minified(json))))
}

/*
Rebuilds an array of big objects (layer and entity instances: LDtk writes each on lines of its
own) from item texts: kept items keep their text, new ones are written at the items'
indentation (`ldtkItemText`).
*/
@(private)
ldtkRebuildRows :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, file, array: int, items: []string) {
	json := LDtkDoc_Json(doc, file)
	if len(items) == 0 {
		LDtkPatches_Set(p, doc, file, array, "[]")
		return
	}
	minified := Json_Minified(json)
	if minified {
		LDtkPatches_Set(p, doc, file, array, fmt.tprintf("[%s]", strings.join(items, ",", context.temp_allocator)))
		return
	}
	outer := LDtk_IndentAt(json.text, int(json.nodes[array].start))
	inner := strings.repeat("\t", outer + 1, context.temp_allocator)
	sep := fmt.tprintf(",\n%s", inner)
	LDtkPatches_Set(p, doc, file, array, fmt.tprintf("[\n%s%s\n%s]", inner, strings.join(items, sep, context.temp_allocator), strings.repeat("\t", outer, context.temp_allocator)))
}

// A new item's text for `ldtkRebuildRows` (written at the array's items' indentation)
@(private)
ldtkItemText :: proc(doc: ^LDtkDoc, file, array: int, v: LDtkJV) -> string {
	json := LDtkDoc_Json(doc, file)
	return LDtk_PrettyJson(v, Json_Minified(json), LDtk_IndentAt(json.text, int(json.nodes[array].start)) + 1)
}

// LDtk's JsonTools.unescapeString: `\\` then `\n` (temp)
@(private)
ldtkUnescape :: proc(s: string) -> string {
	if !strings.contains_rune(s, '\\') do return s
	a, _ := strings.replace_all(s, `\\`, `\`, context.temp_allocator)
	b, _ := strings.replace_all(a, `\n`, "\n", context.temp_allocator)
	return b
}

// A nullable uid's value (-1: null)
@(private)
jvUid :: proc(uid: int) -> LDtkJV {
	return uid < 0 ? LDtkJV(LDtkJNull{}) : LDtkJV(i64(uid))
}

// A uid that may be null (-1)
@(private)
nodeUid :: proc(json: ^JsonDoc, node: int) -> int {
	return Json_Kind(json, node) == .Number ? Json_Int(json, node) : -1
}

// A number as written, kept as LDtk read it (an int when whole)
@(private)
jvNumber :: proc(v: f64) -> LDtkJV {
	if v == math.trunc(v) && abs(v) < 1e15 do return i64(v)
	return v
}

// LDtk's JsonTools.writeFloat: 3 decimals at most
@(private)
ldtkWriteFloat :: proc(v: f64) -> f64 {
	return ldtkRound(v * 1000) / 1000
}

// Haxe's M.round on JavaScript (Math.round: halves up)
@(private)
ldtkRound :: proc(v: f64) -> f64 {
	return math.floor(v + 0.5)
}

// dn's Color.toWhite: a color brought toward white by `ratio` (each channel, rounded: checked
// against LDtk's samples' levels)
@(private)
ldtkToWhite :: proc(c: int, ratio: f64) -> int {
	r, g, b := f64((c >> 16) & 0xFF), f64((c >> 8) & 0xFF), f64(c & 0xFF)
	ch :: proc(v, ratio: f64) -> int { return int(ldtkRound(v + (255 - v) * ratio)) }
	return (ch(r, ratio) << 16) | (ch(g, ratio) << 8) | ch(b, ratio)
}

// --- What tidy knows of the definitions -------------------------------------------------------

@(private="file")
TidyTileset :: struct {
	node, uid: int,
	relPath: string,
	hasPath, embed: bool,
	grid, spacing, padding, cWid, cHei: int,
}

@(private="file")
TidyEnum :: struct {
	node, uid: int,
	external: bool,
	identifier: string,
	iconTileset: int,
	// Value ids in order, and each one's node
	order: [dynamic]string,
	values: map[string]int,
}

@(private="file")
TidyField :: struct {
	node, uid: int,
	info: LDtkFieldInfo,
	identifier, typeText, mode: string,
	// The default's param (null: none) and its wrapper ("V_Int"...)
	override: LDtkJV,
	overrideId: string,
	tileset: int,
	smartColor: bool,
}

@(private="file")
TidyLayer :: struct {
	node, uid: int,
	identifier, type: string,
	grid: int,
	opacity: LDtkJV,
	offset: [2]int,
	tileset: int,
	isAuto, rulesUsable: bool,
	values, rules, optional: map[int]bool,
}

@(private="file")
TidyEntityDef :: struct {
	node, uid: int,
	identifier: string,
	pivot: [2]f64,
	tags: LDtkJV,
	color: int,
	fields: [dynamic]int,
	defaultTile: LDtkJV,
}

@(private="file")
Tidy :: struct {
	doc: ^LDtkDoc,
	main: ^JsonDoc,
	multilines: bool,
	// The project's identifier style (enum values are looked up cleaned with it)
	style: string,
	tilesets: map[int]TidyTileset,
	enums: map[int]TidyEnum,
	fields: map[int]TidyField,
	levelFields: [dynamic]int,
	layers: map[int]TidyLayer,
	layerOrder: [dynamic]int,
	entities: map[int]TidyEntityDef,
	// Entity iids: where each is (references' targets)
	iids: map[string]LDtkDocEntity,
}

// What tidy needs of the document's definitions (temp allocated)
@(private="file")
tidyRead :: proc(doc: ^LDtkDoc, withIids := false) -> Tidy {
	main := LDtkDoc_Main(doc)
	t := Tidy{doc = doc, main = main, style = Json_String(main, Json_Get(main, Json_Root(main), "identifierStyle"))}
	t.tilesets = make(map[int]TidyTileset, context.temp_allocator)
	t.enums = make(map[int]TidyEnum, context.temp_allocator)
	t.fields = make(map[int]TidyField, context.temp_allocator)
	t.layers = make(map[int]TidyLayer, context.temp_allocator)
	t.entities = make(map[int]TidyEntityDef, context.temp_allocator)
	t.levelFields = make([dynamic]int, context.temp_allocator)
	t.layerOrder = make([dynamic]int, context.temp_allocator)
	for f in Json_Items(main, Json_Get(main, Json_Root(main), "flags")) do if Json_String(main, f) == "UseMultilinesType" do t.multilines = true
	for td in Json_Items(main, LDtkDoc_Defs(doc, "tilesets")) {
		x := TidyTileset{node = td, uid = Json_Int(main, Json_Get(main, td, "uid"), -1)}
		rel := Json_Get(main, td, "relPath")
		x.hasPath = Json_Kind(main, rel) == .String
		x.relPath = Json_String(main, rel)
		x.embed = Json_Kind(main, Json_Get(main, td, "embedAtlas")) == .String
		x.grid = Json_Int(main, Json_Get(main, td, "tileGridSize"), 16)
		x.spacing = Json_Int(main, Json_Get(main, td, "spacing"))
		x.padding = Json_Int(main, Json_Get(main, td, "padding"))
		if x.hasPath || x.embed {
			step := f64(max(x.grid + x.spacing, 1))
			x.cWid = int(math.ceil((f64(Json_Int(main, Json_Get(main, td, "pxWid"))) - f64(x.padding * 2)) / step))
			x.cHei = int(math.ceil((f64(Json_Int(main, Json_Get(main, td, "pxHei"))) - f64(x.padding * 2)) / step))
		}
		t.tilesets[x.uid] = x
	}
	for list in ([]string{"enums", "externalEnums"}) do for ed in Json_Items(main, LDtkDoc_Defs(doc, list)) {
		x := TidyEnum{node = ed, uid = Json_Int(main, Json_Get(main, ed, "uid"), -1), external = Json_Kind(main, Json_Get(main, ed, "externalRelPath")) == .String}
		x.identifier = Json_String(main, Json_Get(main, ed, "identifier"))
		x.iconTileset = nodeUid(main, Json_Get(main, ed, "iconTilesetUid"))
		x.order = make([dynamic]string, context.temp_allocator)
		x.values = make(map[string]int, context.temp_allocator)
		for v in Json_Items(main, Json_Get(main, ed, "values")) {
			id := Json_String(main, Json_Get(main, v, "id"))
			append(&x.order, id)
			x.values[id] = v
		}
		t.enums[x.uid] = x
	}
	readField :: proc(t: ^Tidy, f: int) -> int {
		main := t.main
		info := LDtkDoc_FieldInfo(t.doc, f)
		x := TidyField{node = f, uid = info.uid, info = info, identifier = info.identifier, override = LDtkJNull{}}
		x.mode = Json_String(main, Json_Get(main, f, "editorDisplayMode"))
		x.tileset = nodeUid(main, Json_Get(main, f, "tilesetUid"))
		x.smartColor = Json_Bool(main, Json_Get(main, f, "useForSmartColor"))
		over := Json_Get(main, f, "defaultOverride")
		if Json_Kind(main, over) == .Object {
			x.overrideId = Json_String(main, Json_Get(main, over, "id"))
			x.override = ldtkJV(main, Json_At(main, Json_Get(main, over, "params"), 0))
		}
		x.typeText = fieldTypeText(t, f, info)
		t.fields[x.uid] = x
		return x.uid
	}
	for f in Json_Items(main, LDtkDoc_Defs(doc, "levelFields")) do append(&t.levelFields, readField(&t, f))
	for ed in Json_Items(main, LDtkDoc_Defs(doc, "entities")) {
		x := TidyEntityDef{node = ed, uid = Json_Int(main, Json_Get(main, ed, "uid"), -1), defaultTile = LDtkJNull{}}
		x.identifier = Json_String(main, Json_Get(main, ed, "identifier"))
		x.pivot = {Json_Float(main, Json_Get(main, ed, "pivotX")), Json_Float(main, Json_Get(main, ed, "pivotY"))}
		x.tags = ldtkJV(main, Json_Get(main, ed, "tags"))
		if _, isArray := x.tags.(LDtkJArray); !isArray do x.tags = LDtkJArray{}
		x.color, _ = LDtk_ParseColor(Json_String(main, Json_Get(main, ed, "color")))
		x.fields = make([dynamic]int, context.temp_allocator)
		for f in Json_Items(main, Json_Get(main, ed, "fieldDefs")) do append(&x.fields, readField(&t, f))
		// EntityDef.getDefaultTile: a Tile field's default shown as the entity's tile, else its own tile
		found := false
		for uid in x.fields {
			fd := t.fields[uid]
			if fd.info.type != .Tile || fd.mode != "EntityTile" do continue
			if rect := tileRectFrom(fd.override, fd.tileset); rect != nil {
				x.defaultTile = rect
				found = true
				break
			}
		}
		if !found && Json_Kind(main, Json_Get(main, ed, "tilesetId")) == .Number && Json_Kind(main, Json_Get(main, ed, "tileRect")) == .Object {
			x.defaultTile = ldtkJV(main, Json_Get(main, ed, "tileRect"))
		}
		t.entities[x.uid] = x
	}
	for ld in Json_Items(main, LDtkDoc_Defs(doc, "layers")) {
		x := TidyLayer{node = ld, uid = Json_Int(main, Json_Get(main, ld, "uid"), -1)}
		x.identifier = Json_String(main, Json_Get(main, ld, "identifier"))
		x.type = Json_String(main, Json_Get(main, ld, "type"))
		x.grid = max(Json_Int(main, Json_Get(main, ld, "gridSize"), 16), 1)
		x.opacity = ldtkJV(main, Json_Get(main, ld, "displayOpacity"))
		x.offset = {Json_Int(main, Json_Get(main, ld, "pxOffsetX")), Json_Int(main, Json_Get(main, ld, "pxOffsetY"))}
		x.tileset = nodeUid(main, Json_Get(main, ld, "tilesetDefUid"))
		x.isAuto = (x.type == "IntGrid" && x.tileset >= 0) || x.type == "AutoLayer"
		x.rulesUsable = x.isAuto && x.tileset >= 0 && (x.type != "AutoLayer" || Json_Kind(main, Json_Get(main, ld, "autoSourceLayerDefUid")) == .Number)
		x.values = make(map[int]bool, context.temp_allocator)
		x.rules = make(map[int]bool, context.temp_allocator)
		x.optional = make(map[int]bool, context.temp_allocator)
		for v in Json_Items(main, Json_Get(main, ld, "intGridValues")) do x.values[Json_Int(main, Json_Get(main, v, "value"))] = true
		for g in Json_Items(main, Json_Get(main, ld, "autoRuleGroups")) {
			if Json_Bool(main, Json_Get(main, g, "isOptional")) do x.optional[Json_Int(main, Json_Get(main, g, "uid"))] = true
			for r in Json_Items(main, Json_Get(main, g, "rules")) do x.rules[Json_Int(main, Json_Get(main, r, "uid"))] = true
		}
		t.layers[x.uid] = x
		append(&t.layerOrder, x.uid)
	}
	if withIids {
		t.iids = make(map[string]LDtkDocEntity, context.temp_allocator)
		for e in LDtkDoc_Entities(doc) {
			json := LDtkDoc_Json(doc, e.file)
			t.iids[Json_String(json, Json_Get(json, e.node, "iid"))] = e
		}
	}
	return t
}

/*
An enum's value by id (EnumDef.getValue: a local enum's id is cleaned up with the project's style
first, so "Heavy sword" finds Heavy_sword).

Returns:
- The value's node and its id, false when the enum has none
*/
@(private="file")
enumFind :: proc(t: ^Tidy, enumUid: int, id: string) -> (node: int, canonical: string, ok: bool) {
	e, has := &t.enums[enumUid]
	if !has do return -1, "", false
	if v, found := e.values[id]; found do return v, id, true
	if e.external do return -1, "", false
	clean, valid := LDtk_CleanIdentifier(id, t.style)
	if !valid do return -1, "", false
	if v, found := e.values[clean]; found do return v, clean, true
	return -1, "", false
}

// A field definition's `__type` (FieldDef.getJsonTypeString)
@(private="file")
fieldTypeText :: proc(t: ^Tidy, f: int, info: LDtkFieldInfo) -> string {
	desc := ""
	#partial switch info.type {
	case .Int: desc = "Int"
	case .Float: desc = "Float"
	case .String: desc = "String"
	case .Text: desc = t.multilines ? "Multilines" : "String"
	case .Bool: desc = "Bool"
	case .Color: desc = "Color"
	case .Point: desc = "Point"
	case .Path: desc = "FilePath"
	case .EntityRef: desc = "EntityRef"
	case .Tile: desc = "Tile"
	case .Enum:
		main := t.main
		ed := LDtkDoc_DefByUid(t.doc, "enums", info.enumUid)
		external := false
		if ed < 0 {
			ed = LDtkDoc_DefByUid(t.doc, "externalEnums", info.enumUid)
			external = true
		}
		if ed < 0 do return Json_String(t.main, Json_Get(t.main, f, "__type"))
		desc = fmt.tprintf("%s.%s", external ? "ExternEnum" : "LocalEnum", Json_String(main, Json_Get(main, ed, "identifier")))
	case: return Json_String(t.main, Json_Get(t.main, f, "__type"))
	}
	return info.isArray ? fmt.tprintf("Array<%s>", desc) : desc
}

// A tile rectangle from LDtk's "x,y,w,h" text (FieldDef.getTileRectDefaultObj), nil when it isn't one
@(private="file")
tileRectFrom :: proc(v: LDtkJV, tileset: int) -> LDtkJV {
	text, ok := v.(string)
	if !ok do return nil
	parts := strings.split(text, ",", context.temp_allocator)
	if len(parts) != 4 do return nil
	n: [4]i64
	for part, i in parts {
		x, parsed := strconv.parse_i64(strings.trim_space(part))
		if !parsed do return LDtkJNull{}
		n[i] = x
	}
	return jobject(jpair("tilesetUid", jvUid(tileset)), jpair("x", n[0]), jpair("y", n[1]), jpair("w", n[2]), jpair("h", n[3]))
}

// --- Pass 1: the definitions ------------------------------------------------------------------

@(private="file")
tidyDefs :: proc(p: ^LDtkPatches, doc: ^LDtkDoc) {
	t := tidyRead(doc)
	main := t.main
	style := Json_String(main, Json_Get(main, Json_Root(main), "identifierStyle"))
	hasTileset :: proc(t: ^Tidy, uid: int) -> bool { return uid >= 0 && uid in t.tilesets }
	// Field definitions (entities' and the levels'): FieldDef.tidy, tidyFieldDefsArray
	tidyFieldList :: proc(p: ^LDtkPatches, t: ^Tidy, list: int) {
		main := t.main
		keep := make([dynamic]int, context.temp_allocator)
		lost := false
		for f in Json_Items(main, list) {
			fd := t.fields[Json_Int(main, Json_Get(main, f, "uid"), -1)]
			if fd.info.type == .Enum && fd.info.enumUid not_in t.enums {
				lost = true
				continue
			}
			append(&keep, f)
			if Json_Float(main, Json_Get(main, f, "editorDisplayScale"), 1) == 0 do tidySet(p, t.doc, 0, f, "editorDisplayScale", i64(1))
			tidySet(p, t.doc, 0, f, "__type", fd.typeText)
			if fd.info.type == .Enum && fd.overrideId != "" {
				id, _ := fd.override.(string)
				if _, _, found := enumFind(t, fd.info.enumUid, id); !found do tidySet(p, t.doc, 0, f, "defaultOverride", LDtkJNull{})
			}
			if fd.tileset >= 0 && fd.tileset not_in t.tilesets {
				tidySet(p, t.doc, 0, f, "tilesetUid", LDtkJNull{})
				tidySet(p, t.doc, 0, f, "defaultOverride", LDtkJNull{})
			}
			if fd.info.type != .Path do tidySet(p, t.doc, 0, f, "acceptFileTypes", LDtkJNull{})
			if fd.info.type != .Text do tidySet(p, t.doc, 0, f, "textLanguageMode", LDtkJNull{})
		}
		if lost {
			items := make([dynamic]LDtkJV, context.temp_allocator)
			for f in keep do append(&items, ldtkJV(main, f))
			LDtkPatches_Set(p, t.doc, 0, list, writeAt(main, list, LDtkJArray(items[:]), Json_Minified(main)))
		}
	}
	for ld in Json_Items(main, LDtkDoc_Defs(doc, "layers")) {
		l := t.layers[Json_Int(main, Json_Get(main, ld, "uid"), -1)]
		tidySet(p, doc, 0, ld, "__type", l.type)
		if l.tileset >= 0 && !hasTileset(&t, l.tileset) do tidySet(p, doc, 0, ld, "tilesetDefUid", LDtkJNull{})
		tileset := hasTileset(&t, l.tileset) ? l.tileset : -1
		source := nodeUid(main, Json_Get(main, ld, "autoSourceLayerDefUid"))
		if source >= 0 && source not_in t.layers do tidySet(p, doc, 0, ld, "autoSourceLayerDefUid", LDtkJNull{})
		// The biome field: a lost one (or no longer an enum) is cleared, and the groups' values with it
		biome := nodeUid(main, Json_Get(main, ld, "biomeFieldUid"))
		biomeEnum := -1
		if biome >= 0 {
			if fd, ok := t.fields[biome]; ok && fd.info.type == .Enum && fd.info.enumUid in t.enums do biomeEnum = fd.info.enumUid
			if biomeEnum < 0 do tidySet(p, doc, 0, ld, "biomeFieldUid", LDtkJNull{})
		}
		isAuto := (l.type == "IntGrid" && tileset >= 0) || l.type == "AutoLayer"
		groups := Json_Get(main, ld, "autoRuleGroups")
		if !isAuto && Json_Count(main, groups) > 0 {
			LDtkPatches_Set(p, doc, 0, groups, "[]")
		} else {
			for g in Json_Items(main, groups) {
				values := Json_Get(main, g, "requiredBiomeValues")
				if Json_Count(main, values) == 0 do continue
				kept := make([dynamic]LDtkJV, context.temp_allocator)
				if biomeEnum >= 0 do for v in Json_Items(main, values) {
					if _, _, found := enumFind(&t, biomeEnum, Json_String(main, v)); found do append(&kept, strings.clone(Json_String(main, v), context.temp_allocator))
				}
				if len(kept) != Json_Count(main, values) {
					LDtkPatches_Set(p, doc, 0, values, writeAt(main, values, LDtkJArray(kept[:]), Json_Minified(main)))
					if len(kept) <= 1 do tidySet(p, doc, 0, g, "biomeRequirementMode", i64(0))
				}
			}
		}
		if l.type != "IntGrid" {
			if values := Json_Get(main, ld, "intGridValues"); Json_Count(main, values) > 0 do LDtkPatches_Set(p, doc, 0, values, "[]")
			if groups := Json_Get(main, ld, "intGridValuesGroups"); Json_Count(main, groups) > 0 do LDtkPatches_Set(p, doc, 0, groups, "[]")
		}
	}
	for ed in Json_Items(main, LDtkDoc_Defs(doc, "entities")) {
		set := Json_Get(main, ed, "tilesetId")
		if Json_Kind(main, set) == .Number && !hasTileset(&t, Json_Int(main, set)) {
			tidySet(p, doc, 0, ed, "tilesetId", LDtkJNull{})
			tidySet(p, doc, 0, ed, "renderMode", "Rectangle")
		}
		borders := Json_Get(main, ed, "nineSliceBorders")
		if Json_String(main, Json_Get(main, ed, "tileRenderMode")) == "NineSlice" {
			if Json_Count(main, borders) != 4 do tidySet(p, doc, 0, ed, "nineSliceBorders", jarray(i64(2), i64(2), i64(2), i64(2)))
		} else if Json_Count(main, borders) > 0 {
			tidySet(p, doc, 0, ed, "nineSliceBorders", LDtkJArray{})
		}
		tidyFieldList(p, &t, Json_Get(main, ed, "fieldDefs"))
	}
	tidyFieldList(p, &t, LDtkDoc_Defs(doc, "levelFields"))
	for list in ([]string{"enums", "externalEnums"}) do for ed in Json_Items(main, LDtkDoc_Defs(doc, list)) {
		icon := nodeUid(main, Json_Get(main, ed, "iconTilesetUid"))
		if icon >= 0 && !hasTileset(&t, icon) {
			tidySet(p, doc, 0, ed, "iconTilesetUid", LDtkJNull{})
			for v in Json_Items(main, Json_Get(main, ed, "values")) do tidySet(p, doc, 0, v, "tileRect", LDtkJNull{})
		}
	}
	for td in Json_Items(main, LDtkDoc_Defs(doc, "tilesets")) {
		x := t.tilesets[Json_Int(main, Json_Get(main, td, "uid"), -1)]
		tidySet(p, doc, 0, td, "__cWid", i64(x.cWid))
		tidySet(p, doc, 0, td, "__cHei", i64(x.cHei))
		if x.embed {
			if id, ok := LDtk_CleanIdentifier("Internal_Icons", style); ok do tidySet(p, doc, 0, td, "identifier", id)
		}
		source := nodeUid(main, Json_Get(main, td, "tagsSourceEnumUid"))
		if source >= 0 && source not_in t.enums {
			tidySet(p, doc, 0, td, "tagsSourceEnumUid", LDtkJNull{})
			source = -1
		}
		// enumTags: one entry per value of the source enum, its tiles in order (TilesetDef.toJson)
		tags := Json_Get(main, td, "enumTags")
		if tags < 0 do continue
		if source < 0 {
			tidySet(p, doc, 0, td, "enumTags", LDtkJArray{})
			continue
		}
		existing := make(map[string][dynamic]int, context.temp_allocator)
		for entry in Json_Items(main, tags) {
			id := Json_String(main, Json_Get(main, entry, "enumValueId"))
			ids := make([dynamic]int, context.temp_allocator)
			for tid in Json_Items(main, Json_Get(main, entry, "tileIds")) do append(&ids, Json_Int(main, tid))
			existing[id] = ids
		}
		entries := make([dynamic]LDtkJV, context.temp_allocator)
		for id in t.enums[source].order {
			ids := existing[id]
			slice.sort(ids[:])
			list := make([dynamic]LDtkJV, context.temp_allocator)
			for tid, i in ids do if i == 0 || tid != ids[i - 1] do append(&list, i64(tid))
			append(&entries, jobject(jpair("enumValueId", id), jpair("tileIds", LDtkJArray(list[:]))))
		}
		tidySet(p, doc, 0, td, "enumTags", LDtkJArray(entries[:]))
	}
}

// --- Pass 2: the instances' structure --------------------------------------------------------

// A new layer instance of a level, empty, as LDtk writes one (Level.createLayerInstance, LayerInstance.toJson)
@(private)
ldtkNewLayerInstance :: proc(doc: ^LDtkDoc, level, layerUid: int) -> LDtkJV {
	main := LDtkDoc_Main(doc)
	t := tidyRead(doc)
	l := t.layers[layerUid]
	entry := doc.levels[level].entry
	pxWid, pxHei := Json_Int(main, Json_Get(main, entry, "pxWid")), Json_Int(main, Json_Get(main, entry, "pxHei"))
	cWid, cHei := int(math.ceil(f64(pxWid) / f64(l.grid))), int(math.ceil(f64(pxHei) / f64(l.grid)))
	ts, hasTs := t.tilesets[l.tileset]
	csv := make([]LDtkJV, l.type == "IntGrid" ? cWid * cHei : 0, context.temp_allocator)
	for &c in csv do c = i64(0)
	return jobject(
		jpair("__identifier", l.identifier),
		jpair("__type", l.type),
		jpair("__cWid", i64(cWid)),
		jpair("__cHei", i64(cHei)),
		jpair("__gridSize", i64(l.grid)),
		jpair("__opacity", l.opacity),
		jpair("__pxTotalOffsetX", i64(l.offset.x)),
		jpair("__pxTotalOffsetY", i64(l.offset.y)),
		jpair("__tilesetDefUid", hasTs ? LDtkJV(i64(l.tileset)) : LDtkJNull{}),
		jpair("__tilesetRelPath", hasTs && ts.hasPath ? LDtkJV(ts.relPath) : LDtkJNull{}),
		jpair("iid", LDtk_NewIid()),
		jpair("levelId", i64(Json_Int(main, Json_Get(main, entry, "uid")))),
		jpair("layerDefUid", i64(layerUid)),
		jpair("pxOffsetX", i64(0)),
		jpair("pxOffsetY", i64(0)),
		jpair("visible", true),
		jpair("optionalRules", LDtkJArray{}),
		jpair("intGridCsv", LDtkJArray(csv)),
		jpair("autoLayerTiles", LDtkJArray{}),
		jpair("seed", i64(rand.int_max(9999999))),
		jpair("overrideTilesetUid", LDtkJNull{}),
		jpair("gridTiles", LDtkJArray{}),
		jpair("entityInstances", LDtkJArray{}),
	)
}

// A new field instance at its definition's default, as LDtk writes one (FieldInstance.toJson)
@(private="file")
newFieldInstance :: proc(t: ^Tidy, uid: int) -> LDtkJV {
	fd := &t.fields[uid]
	return jobject(
		jpair("__identifier", fd.identifier),
		jpair("__type", fd.typeText),
		jpair("__value", fieldValue(t, fd, nil, nil)),
		jpair("__tile", LDtkJNull{}),
		jpair("defUid", i64(uid)),
		jpair("realEditorValues", LDtkJArray{}),
	)
}

/*
An object's field instances as its definitions want them (one per definition, in their order),
written again when they aren't: kept ones as they are, new ones at the default.
*/
@(private="file")
tidyFieldInstances :: proc(p: ^LDtkPatches, t: ^Tidy, file, owner: int, defs: []int) {
	json := LDtkDoc_Json(t.doc, file)
	array := Json_Get(json, owner, "fieldInstances")
	if Json_Kind(json, array) != .Array do return
	items := Json_Items(json, array)
	same := len(items) == len(defs)
	if same do for item, i in items do if Json_Int(json, Json_Get(json, item, "defUid"), -1) != defs[i] do same = false
	if same do return
	byUid := make(map[int]int, context.temp_allocator)
	for item in items do byUid[Json_Int(json, Json_Get(json, item, "defUid"), -1)] = item
	out := make([dynamic]LDtkJV, context.temp_allocator)
	for uid in defs {
		if item, found := byUid[uid]; found do append(&out, ldtkJV(json, item))
		else do append(&out, newFieldInstance(t, uid))
	}
	LDtkPatches_Set(p, t.doc, file, array, writeAt(json, array, LDtkJArray(out[:]), Json_Minified(json)))
}

@(private="file")
tidyStructure :: proc(p: ^LDtkPatches, doc: ^LDtkDoc) {
	t := tidyRead(doc)
	for _, level in doc.levels {
		for place in LDtkDoc_LevelObjects(doc, level) do tidyFieldInstances(p, &t, place.file, place.node, t.levelFields[:])
		file, array := LDtkDoc_LayerInstances(doc, level)
		if array < 0 do continue
		json := LDtkDoc_Json(doc, file)
		items := Json_Items(json, array)
		// Every layer definition's instance, in their order (Level.tidy)
		same := len(items) == len(t.layerOrder)
		if same do for item, i in items do if Json_Int(json, Json_Get(json, item, "layerDefUid"), -1) != t.layerOrder[i] do same = false
		if !same {
			byUid := make(map[int]int, context.temp_allocator)
			for item in items do byUid[Json_Int(json, Json_Get(json, item, "layerDefUid"), -1)] = item
			texts := make([dynamic]string, context.temp_allocator)
			for uid in t.layerOrder {
				if item, found := byUid[uid]; found do append(&texts, Json_Text(json, item))
				else do append(&texts, ldtkItemText(doc, file, array, ldtkNewLayerInstance(doc, level, uid)))
			}
			ldtkRebuildRows(p, doc, file, array, texts[:])
			// The kept layers' contents are tidied in the next pass (their places moved)
			continue
		}
		for li in items {
			l := t.layers[Json_Int(json, Json_Get(json, li, "layerDefUid"), -1)]
			// Content a layer of its type doesn't hold
			if l.type != "IntGrid" do if csv := Json_Get(json, li, "intGridCsv"); Json_Count(json, csv) > 0 do LDtkPatches_Set(p, doc, file, csv, "[]")
			if !l.rulesUsable do if auto := Json_Get(json, li, "autoLayerTiles"); Json_Count(json, auto) > 0 do LDtkPatches_Set(p, doc, file, auto, "[]")
			if l.type != "Tiles" do if tiles := Json_Get(json, li, "gridTiles"); Json_Count(json, tiles) > 0 do LDtkPatches_Set(p, doc, file, tiles, "[]")
			entities := Json_Get(json, li, "entityInstances")
			if Json_Count(json, entities) == 0 do continue
			if l.type != "Entities" {
				LDtkPatches_Set(p, doc, file, entities, "[]")
				continue
			}
			// Entities of a lost type removed (LayerInstance.tidy); their fields as their type wants them
			kept := make([dynamic]string, context.temp_allocator)
			lost := false
			for e in Json_Items(json, entities) {
				ed, found := t.entities[Json_Int(json, Json_Get(json, e, "defUid"), -1)]
				if !found {
					lost = true
					continue
				}
				append(&kept, Json_Text(json, e))
				if !lost do tidyFieldInstances(p, &t, file, e, ed.fields[:])
			}
			if lost do ldtkRebuildRows(p, doc, file, entities, kept[:])
		}
	}
}

// --- Pass 2: the instances' values ------------------------------------------------------------

/*
A field's `__value` (FieldInstance.getFullJsonValue): each editor value, or the definition's
default where there's none, clamped as LDtk clamps it.

Inputs:
- raw: The instance's `realEditorValues` (nil: none, a new instance)
- json: Its document
*/
@(private="file")
fieldValue :: proc(t: ^Tidy, fd: ^TidyField, json: ^JsonDoc, raw: []LDtkJV) -> LDtkJV {
	if !fd.info.isArray do return fieldValueAt(t, fd, len(raw) > 0 ? raw[0] : nil)
	out := make([]LDtkJV, len(raw), context.temp_allocator)
	for r, i in raw do out[i] = fieldValueAt(t, fd, r)
	return LDtkJArray(out)
}

// An editor value's param (nil: the default)
@(private="file")
paramOf :: proc(raw: LDtkJV) -> LDtkJV {
	o, ok := raw.(LDtkJObject)
	if !ok do return nil
	for pair in o do if pair.key == "params" {
		if a, isArray := pair.value.(LDtkJArray); isArray && len(a) > 0 do return a[0]
	}
	return nil
}

@(private="file")
jvFloat :: proc(v: LDtkJV) -> (f64, bool) {
	#partial switch x in v {
	case i64: return f64(x), true
	case f64: return x, true
	}
	return 0, false
}

// One value of a field (FieldInstance.getJsonValue)
@(private="file")
fieldValueAt :: proc(t: ^Tidy, fd: ^TidyField, raw: LDtkJV) -> LDtkJV {
	param := paramOf(raw)
	info := fd.info
	iClamp :: proc(info: LDtkFieldInfo, v: f64) -> f64 {
		x := v
		if lo, ok := info.min.?; ok do x = max(x, ldtkRound(lo))
		if hi, ok := info.max.?; ok do x = min(x, ldtkRound(hi))
		return x
	}
	fClamp :: proc(info: LDtkFieldInfo, v: f64) -> f64 {
		x := v
		if lo, ok := info.min.?; ok do x = max(x, lo)
		if hi, ok := info.max.?; ok do x = min(x, hi)
		return x
	}
	#partial switch info.type {
	case .Int:
		if v, ok := jvFloat(param); ok do return i64(iClamp(info, v))
		if v, ok := jvFloat(fd.override); ok && fd.overrideId == "V_Int" do return i64(iClamp(info, v))
		return info.canBeNull ? LDtkJV(LDtkJNull{}) : LDtkJV(i64(iClamp(info, 0)))
	case .Float:
		v, ok := jvFloat(param)
		if !ok {
			if d, has := jvFloat(fd.override); has && fd.overrideId == "V_Float" {
				v, ok = d, true
			} else if !info.canBeNull {
				v, ok = 0, true
			}
		}
		if !ok do return LDtkJNull{}
		return jvNumber(ldtkWriteFloat(fClamp(info, v)))
	case .String, .Text:
		// A Multilines value is kept escaped in the editor values (FieldInstance.fromJson unescapes it)
		if s, ok := param.(string); ok do return info.type == .Text ? ldtkUnescape(s) : s
		if s, ok := fd.override.(string); ok && fd.overrideId == "V_String" do return s
		return info.canBeNull ? LDtkJV(LDtkJNull{}) : LDtkJV("")
	case .Path:
		if s, ok := param.(string); ok do return s
		return LDtkJNull{}
	case .Bool:
		if b, ok := param.(bool); ok do return b
		if b, ok := fd.override.(bool); ok && fd.overrideId == "V_Bool" do return b
		return info.canBeNull ? LDtkJV(LDtkJNull{}) : LDtkJV(false)
	case .Color:
		if v, ok := jvFloat(param); ok do return LDtk_FormatColor(int(v))
		if v, ok := jvFloat(fd.override); ok && fd.overrideId == "V_Int" do return LDtk_FormatColor(int(v))
		return info.canBeNull ? LDtkJV(LDtkJNull{}) : LDtkJV(LDtk_FormatColor(0))
	case .Point:
		s, ok := param.(string)
		if !ok do return LDtkJNull{}
		xs, _, ys := strings.partition(s, ",")
		x, _ := strconv.parse_i64(strings.trim_space(xs))
		y, _ := strconv.parse_i64(strings.trim_space(ys))
		return jobject(jpair("cx", x), jpair("cy", y))
	case .Enum:
		if s, ok := param.(string); ok do return s
		if s, ok := fd.override.(string); ok && fd.overrideId == "V_String" {
			if _, id, found := enumFind(t, info.enumUid, s); found do return id
		}
		return LDtkJNull{}
	case .EntityRef:
		iid, ok := param.(string)
		if !ok do return LDtkJNull{}
		layerIid, levelIid, worldIid := "?", "?", "?"
		if e, found := t.iids[iid]; found {
			json := LDtkDoc_Json(t.doc, e.file)
			layerIid = Json_String(json, Json_Get(json, e.layer, "iid"))
			_, levelIid = LDtkDoc_LevelNames(t.doc, e.level)
			_, worldIid = LDtkDoc_WorldNames(t.doc, t.doc.levels[e.level].world)
		}
		return jobject(jpair("entityIid", iid), jpair("layerIid", layerIid), jpair("levelIid", levelIid), jpair("worldIid", worldIid))
	case .Tile:
		v := param
		if _, has := v.(string); !has do v = fd.override
		if rect := tileRectFrom(v, fd.tileset); rect != nil do return rect
		return LDtkJNull{}
	}
	return raw != nil ? param : LDtkJNull{}
}

// A field's `__tile` (FieldInstance.getSmartTile): an enum value's icon or a tile, shown as the entity's
@(private="file")
fieldSmartTile :: proc(t: ^Tidy, fd: ^TidyField, first: LDtkJV) -> LDtkJV {
	if fd.mode != "EntityTile" do return LDtkJNull{}
	#partial switch fd.info.type {
	case .Enum:
		id, ok := first.(string)
		if !ok do return LDtkJNull{}
		e, has := t.enums[fd.info.enumUid]
		if !has || e.iconTileset < 0 || e.iconTileset not_in t.tilesets do return LDtkJNull{}
		v, _, found := enumFind(t, fd.info.enumUid, id)
		if !found do return LDtkJNull{}
		return ldtkJV(t.main, Json_Get(t.main, v, "tileRect"))
	case .Tile:
		if _, isNull := first.(LDtkJNull); isNull || first == nil do return LDtkJNull{}
		return first
	}
	return LDtkJNull{}
}

// A field's smart color (FieldInstance.getSmartColor), false when it gives none
@(private="file")
fieldSmartColor :: proc(t: ^Tidy, fd: ^TidyField, values: []LDtkJV) -> (int, bool) {
	if !fd.smartColor do return 0, false
	for v in values {
		s, ok := v.(string)
		if !ok do continue
		#partial switch fd.info.type {
		case .Color:
			if c, parsed := LDtk_ParseColor(s); parsed do return c, true
		case .Enum:
			if node, _, found := enumFind(t, fd.info.enumUid, s); found do return Json_Int(t.main, Json_Get(t.main, node, "color")), true
		}
	}
	return 0, false
}

/*
A field instance tidied (FieldInstance.tidy) and its derived values written.

Inputs:
- cells: The owning layer instance's size (points outside it are removed); zero for a level's field

Returns:
- Its values (as `__value` holds them, one per item; a single value's one) for smart colors and
  tiles
*/
@(private="file")
tidyFieldInstance :: proc(p: ^LDtkPatches, t: ^Tidy, file, fi: int, cells: [2]int) -> (fd: ^TidyField, values: []LDtkJV) {
	json := LDtkDoc_Json(t.doc, file)
	uid := Json_Int(json, Json_Get(json, fi, "defUid"), -1)
	found: bool
	fd, found = &t.fields[uid]
	if !found do return nil, nil
	minified := Json_Minified(json)
	rawNode := Json_Get(json, fi, "realEditorValues")
	raws := make([dynamic]LDtkJV, context.temp_allocator)
	for r in Json_Items(json, rawNode) do append(&raws, ldtkJV(json, r))
	// Lost values (FieldInstance.tidy): tiles without a tileset, lost references, enum values the
	// enum lost, points outside the layer
	changed := false
	#partial switch fd.info.type {
	case .Tile, .EntityRef, .Point:
		i := 0
		for i < len(raws) {
			param := paramOf(raws[i])
			lost := false
			if s, ok := param.(string); ok {
				switch fd.info.type {
				case .Tile: lost = fd.tileset < 0 || fd.tileset not_in t.tilesets
				case .EntityRef: lost = s not_in t.iids
				case .Point:
					if cells != {} {
						xs, _, ys := strings.partition(s, ",")
						x, _ := strconv.parse_int(strings.trim_space(xs))
						y, _ := strconv.parse_int(strings.trim_space(ys))
						lost = x < 0 || x >= cells.x || y < 0 || y >= cells.y
					}
				case .Unknown, .Int, .Float, .String, .Text, .Bool, .Color, .Enum, .Path:
				}
			}
			if !lost {
				i += 1
				continue
			}
			changed = true
			// Arrays lose the item, a single value becomes null (points are removed either way)
			if fd.info.isArray || fd.info.type == .Point do ordered_remove(&raws, i)
			else {
				raws[i] = LDtkJNull{}
				i += 1
			}
		}
	case .Enum:
		for &r in raws {
			if s, ok := paramOf(r).(string); ok {
				if _, _, found := enumFind(t, fd.info.enumUid, s); found do continue
				r = LDtkJNull{}
				changed = true
			}
		}
	}
	if changed do LDtkPatches_Set(p, t.doc, file, rawNode, writeAt(json, rawNode, LDtkJArray(raws[:]), minified))
	tidySet(p, t.doc, file, fi, "__identifier", fd.identifier)
	tidySet(p, t.doc, file, fi, "__type", fd.typeText)
	value := fieldValue(t, fd, json, raws[:])
	tidySet(p, t.doc, file, fi, "__value", value)
	if a, isArray := value.(LDtkJArray); isArray {
		values = ([]LDtkJV)(a)
	} else {
		one := make([]LDtkJV, 1, context.temp_allocator)
		one[0] = value
		values = one
	}
	first := len(values) > 0 ? values[0] : fieldValueAt(t, fd, nil)
	tidySet(p, t.doc, file, fi, "__tile", fieldSmartTile(t, fd, first))
	return fd, values
}

@(private="file")
tidyValues :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, scope: LDtkTidyScope) {
	t := tidyRead(doc, withIids = true)
	main := t.main
	for _, level in doc.levels {
		entry := doc.levels[level].entry
		pxWid, pxHei := Json_Int(main, Json_Get(main, entry, "pxWid")), Json_Int(main, Json_Get(main, entry, "pxHei"))
		for place in LDtkDoc_LevelObjects(doc, level) {
			json := LDtkDoc_Json(doc, place.file)
			// Level.getSmartColor: the first level field giving one, else the background, made brighter
			color, colored := 0, false
			for fi in Json_Items(json, Json_Get(json, place.node, "fieldInstances")) {
				fd, values := tidyFieldInstance(p, &t, place.file, fi, {})
				if fd != nil && !colored do color, colored = fieldSmartColor(&t, fd, values)
			}
			if !colored {
				bg, ok := LDtk_ParseColor(Json_String(json, Json_Get(json, place.node, "__bgColor")))
				if !ok do continue
				color = bg
			}
			tidySet(p, doc, place.file, place.node, "__smartColor", LDtk_FormatColor(ldtkToWhite(color, 0.45)))
		}
		file, array := LDtkDoc_LayerInstances(doc, level)
		if array < 0 do continue
		json := LDtkDoc_Json(doc, file)
		minified := Json_Minified(json)
		for li in Json_Items(json, array) {
			l, known := t.layers[Json_Int(json, Json_Get(json, li, "layerDefUid"), -1)]
			if !known do continue
			offset := [2]int{Json_Int(json, Json_Get(json, li, "pxOffsetX")), Json_Int(json, Json_Get(json, li, "pxOffsetY"))}
			cWid := int(math.ceil(f64(pxWid - offset.x) / f64(l.grid)))
			cHei := int(math.ceil(f64(pxHei - offset.y) / f64(l.grid)))
			override := nodeUid(json, Json_Get(json, li, "overrideTilesetUid"))
			tsUid := override >= 0 ? override : l.tileset
			ts, hasTs := t.tilesets[tsUid]
			tidySet(p, doc, file, li, "__identifier", l.identifier)
			tidySet(p, doc, file, li, "__type", l.type)
			tidySet(p, doc, file, li, "__cWid", i64(cWid))
			tidySet(p, doc, file, li, "__cHei", i64(cHei))
			tidySet(p, doc, file, li, "__gridSize", i64(l.grid))
			tidySet(p, doc, file, li, "__opacity", l.opacity)
			tidySet(p, doc, file, li, "__pxTotalOffsetX", i64(offset.x + l.offset.x))
			tidySet(p, doc, file, li, "__pxTotalOffsetY", i64(offset.y + l.offset.y))
			tidySet(p, doc, file, li, "__tilesetDefUid", hasTs ? LDtkJV(i64(tsUid)) : LDtkJNull{})
			tidySet(p, doc, file, li, "__tilesetRelPath", hasTs && ts.hasPath ? LDtkJV(ts.relPath) : LDtkJNull{})
			// Optional rule groups the layer no longer has
			if opt := Json_Get(json, li, "optionalRules"); Json_Count(json, opt) > 0 {
				kept := make([dynamic]LDtkJV, context.temp_allocator)
				for g in Json_Items(json, opt) do if Json_Int(json, g) in l.optional do append(&kept, i64(Json_Int(json, g)))
				if len(kept) != Json_Count(json, opt) do LDtkPatches_Set(p, doc, file, opt, writeAt(json, opt, LDtkJArray(kept[:]), minified))
			}
			// Lost IntGrid values (asked for: every cell is read)
			if scope.intGrid && l.type == "IntGrid" {
				csv := Json_Get(json, li, "intGridCsv")
				for c := json.nodes[csv].first if csv >= 0 else -1; c >= 0; c = json.nodes[c].next {
					text := Json_Text(json, int(c))
					if text == "0" do continue
					if Json_Int(json, int(c)) not_in l.values do LDtkPatches_Add(p, file, Json_SetPatch(json, int(c), "0"))
				}
			}
			// Tiles of rules the layer lost
			if auto := Json_Get(json, li, "autoLayerTiles"); l.rulesUsable && Json_Count(json, auto) > 0 {
				lost := false
				for c := json.nodes[auto].first; c >= 0; c = json.nodes[c].next {
					if Json_Int(json, Json_At(json, Json_Get(json, int(c), "d"), 0)) not_in l.rules {
						lost = true
						break
					}
				}
				if lost {
					kept := make([dynamic]LDtkJV, context.temp_allocator)
					for c := json.nodes[auto].first; c >= 0; c = json.nodes[c].next {
						if Json_Int(json, Json_At(json, Json_Get(json, int(c), "d"), 0)) in l.rules do append(&kept, ldtkJV(json, int(c)))
					}
					LDtkPatches_Set(p, doc, file, auto, writeAt(json, auto, LDtkJArray(kept[:]), minified))
				}
			}
			// Tiles' sources from their tileset (asked for)
			if scope.gridTiles && l.type == "Tiles" {
				gt := Json_Get(json, li, "gridTiles")
				for c := json.nodes[gt].first if gt >= 0 else -1; c >= 0; c = json.nodes[c].next {
					tile := Json_Int(json, Json_Get(json, int(c), "t"))
					src := jarray(i64(-1), i64(-1))
					if hasTs {
						w := max(ts.cWid, 1)
						src = jarray(i64(ts.padding + (tile - w * (tile / w)) * (ts.grid + ts.spacing)), i64(ts.padding + (tile / w) * (ts.grid + ts.spacing)))
					}
					tidySet(p, doc, file, int(c), "src", src)
				}
			}
			if l.type != "Entities" do continue
			for e in Json_Items(json, Json_Get(json, li, "entityInstances")) {
				ed, found := t.entities[Json_Int(json, Json_Get(json, e, "defUid"), -1)]
				if !found do continue
				tidySet(p, doc, file, e, "__identifier", ed.identifier)
				px := Json_Get(json, e, "px")
				x, y := Json_Int(json, Json_At(json, px, 0)), Json_Int(json, Json_At(json, px, 1))
				cx := (x + (ed.pivot.x == 1 ? -1 : 0)) / l.grid
				cy := (y + (ed.pivot.y == 1 ? -1 : 0)) / l.grid
				tidySet(p, doc, file, e, "__grid", jarray(i64(cx), i64(cy)))
				tidySet(p, doc, file, e, "__pivot", jarray(jvNumber(ldtkWriteFloat(ed.pivot.x)), jvNumber(ldtkWriteFloat(ed.pivot.y))))
				tidySet(p, doc, file, e, "__tags", ed.tags)
				// EntityInstance.getSmartTile / getSmartColor: the first field giving one, else the type's
				tile := LDtkJV(LDtkJNull{})
				tiled := false
				color, colored := ed.color, false
				for fi in Json_Items(json, Json_Get(json, e, "fieldInstances")) {
					fd, values := tidyFieldInstance(p, &t, file, fi, {cWid, cHei})
					if fd == nil do continue
					if !tiled {
						first := len(values) > 0 ? values[0] : fieldValueAt(&t, fd, nil)
						if ft := fieldSmartTile(&t, fd, first); ft != nil {
							if _, isNull := ft.(LDtkJNull); !isNull do tile, tiled = ft, true
						}
					}
					if !colored do if c, ok := fieldSmartColor(&t, fd, values); ok do color, colored = c, true
				}
				if !tiled do tile = ed.defaultTile
				tidySet(p, doc, file, e, "__tile", tile)
				tidySet(p, doc, file, e, "__smartColor", LDtk_FormatColor(color))
			}
		}
	}
}
