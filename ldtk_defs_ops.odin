package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

/*
The definitions editors' member edits (`Def_Set`), definitions added, removed, duplicated and
moved, and field type conversions, as LDtk's panels make them (see ldtk_defs.odin's doc block).
A grid change remaps every level's cells as LDtk's LayerInstance.remapToGridSize does: IntGrid
values and tiles keep their cell (those past the new size are dropped), entities move by the ratio.
*/

// --- Def_Set -------------------------------------------------------------------------------

@(private)
defSet :: proc(op: ^DefOp) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	uid := edit.kind == .Field ? edit.field : edit.def
	node := LDtkDefs_Node(doc, edit.kind, uid)
	if node < 0 do return "no such definition"
	m := LDtkDefs_Member(edit.kind, edit.key)
	if m == nil do return fmt.tprintf("%q can't be set here", edit.key)
	if edit.kind == .Enum && Json_Kind(main, Json_Get(main, node, "externalRelPath")) == .String {
		// External enums are their file's (EnumDef.allowValueCustomization: only icons, not CastleDB's)
		ext := strings.to_lower(Json_String(main, Json_Get(main, node, "externalRelPath")), context.temp_allocator)
		if edit.key != "iconTilesetUid" || strings.has_suffix(ext, ".cdb") do return "this enum comes from an external file: edit that file"
	}
	p := LDtkPatches{}
	if m.type == .Special {
		if why := defSpecial(op, &p, node, m); why != "" do return why
	} else {
		v, why := memberValue(doc, m, edit)
		if why != "" do return why
		if why = defConsequences(op, &p, node, m, &v); why != "" do return why
		defWrite(&p, doc, node, m.key, v)
	}
	return stagesApply(op.s, &p)
}

// Whether a uid is a definition of a list (and, for layers, of a type: "" any)
@(private)
isDef :: proc(doc: ^LDtkDoc, list: string, uid: int, type := "") -> bool {
	node := LDtkDoc_DefByUid(doc, list, uid)
	if node < 0 do return false
	if type == "" do return true
	main := LDtkDoc_Main(doc)
	return Json_String(main, Json_Get(main, node, "type")) == type
}

// The entity definition holding a field definition (-1: a level field)
@(private)
fieldEntity :: proc(doc: ^LDtkDoc, fieldUid: int) -> int {
	owner, _ := LDtkDoc_FieldDef(doc, fieldUid)
	if owner == LDtkDoc_Defs(doc, "levelFields") do return -1
	return owner
}

/*
What LDtk's panel does beside a member's change (its input's onChange / fixValue), as more
patches; `v` may be changed (a value LDtk fixes).

Returns:
- "" or why the value isn't accepted
*/
@(private)
defConsequences :: proc(op: ^DefOp, p: ^LDtkPatches, node: int, m: ^LDtkMember, v: ^LDtkJV) -> string {
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	uidOf :: proc(v: LDtkJV) -> int {
		if n, ok := v.(i64); ok do return int(n)
		return -1
	}
	switch m.kind {
	case .Layer:
		layerUid := Json_Int(main, Json_Get(main, node, "uid"))
		type := Json_String(main, Json_Get(main, node, "type"))
		switch m.key {
		case "guideGridWid", "guideGridHei":
			// fixValue: 1 or less is no guide
			if n, ok := v.(i64); ok && n <= 1 do v^ = i64(0)
		case "parallaxFactorX":
			// Y follows X while they were the same
			x, y := Json_Float(main, Json_Get(main, node, "parallaxFactorX")), Json_Float(main, Json_Get(main, node, "parallaxFactorY"))
			if x == y do defWrite(p, doc, node, "parallaxFactorY", v^)
		case "parallaxFactorY":
			if Json_Bool(main, Json_Get(main, node, "parallaxScaling"), true) do return "parallax Y follows X while parallax scaling is on"
		case "parallaxScaling":
			if b, _ := v.(bool); b do defWrite(p, doc, node, "parallaxFactorY", ldtkJV(main, Json_Get(main, node, "parallaxFactorX")))
		case "tilesetDefUid":
			ts := uidOf(v^)
			if ts >= 0 && !isDef(doc, "tilesets", ts) do return "no such tileset"
			if type == "Entities" do return "an Entities layer has no tileset"
			if ts >= 0 {
				tsNode := LDtkDoc_DefByUid(doc, "tilesets", ts)
				grid := Json_Int(main, Json_Get(main, tsNode, "tileGridSize"), 16)
				// A Tiles layer takes its tileset's grid; an IntGrid or auto-layer too while it's empty
				if type == "Tiles" || layerIsEmpty(doc, layerUid) {
					if why := layerGrid(op, p, layerUid, grid); why != "" do return why
				}
			}
			op.scope.gridTiles = true
			op.rerun[layerUid] = true
		case "autoSourceLayerDefUid":
			if type != "AutoLayer" do return "only an auto-layer has a source layer"
			source := uidOf(v^)
			if source >= 0 {
				if !isDef(doc, "layers", source, "IntGrid") do return "an auto-layer's source must be an IntGrid layer"
				grid := Json_Int(main, Json_Get(main, LDtkDoc_DefByUid(doc, "layers", source), "gridSize"), 16)
				if why := layerGrid(op, p, layerUid, grid); why != "" do return why
			}
			op.rerun[layerUid] = true
		case "autoTilesKilledByOtherLayerUid":
			other := uidOf(v^)
			if other >= 0 && !isDef(doc, "layers", other, "Tiles") do return "only a Tiles layer can remove an auto-layer's tiles"
			op.rerun[layerUid] = true
		case "biomeFieldUid":
			field := uidOf(v^)
			if field >= 0 {
				owner, fd := LDtkDoc_FieldDef(doc, field)
				if fd < 0 || owner != LDtkDoc_Defs(doc, "levelFields") || LDtkDoc_FieldInfo(doc, fd).type != .Enum do return "a biome field must be a level field of an enum"
			}
			op.rerun[layerUid] = true
		case "requiredTags", "excludedTags":
			if type != "Entities" do return "only an Entities layer filters entities by tags"
		case "tilePivotX", "tilePivotY":
			if type != "Tiles" do return "only a Tiles layer has a tile pivot"
		}
	case .Entity:
		switch m.key {
		case "width", "height":
			// Entities without a size of their own (the type's) follow it (EntityInstance.width)
			old := Json_Int(main, Json_Get(main, node, m.key))
			uid := Json_Int(main, Json_Get(main, node, "uid"))
			for e in ldtkEntitiesOf(doc, uid) {
				json := LDtkDoc_Json(doc, e.file)
				if Json_Int(json, Json_Get(json, e.node, m.key)) == old do LDtkPatches_Set(p, doc, e.file, Json_Get(json, e.node, m.key), writeAt(json, e.node, v^, Json_Minified(json)))
			}
		case "resizableX", "resizableY":
			// Turned off: no limits; on: the minimum is the size
			x := m.key == "resizableX"
			minKey, maxKey, size := x ? "minWidth" : "minHeight", x ? "maxWidth" : "maxHeight", x ? "width" : "height"
			if b, _ := v.(bool); b {
				defWrite(p, doc, node, minKey, i64(Json_Int(main, Json_Get(main, node, size), 16)))
			} else {
				defWrite(p, doc, node, minKey, LDtkJNull{})
				defWrite(p, doc, node, maxKey, LDtkJNull{})
			}
		case "minWidth", "maxWidth", "minHeight", "maxHeight":
			// fixValue: 0 or less is none; a minimum up to the maximum, a maximum down to the minimum
			n, isInt := v.(i64)
			if !isInt do break
			if n <= 0 {
				v^ = LDtkJNull{}
				break
			}
			switch m.key {
			case "minWidth": if hi, ok := Json_Number(main, Json_Get(main, node, "maxWidth")); ok do v^ = i64(min(f64(n), hi))
			case "minHeight": if hi, ok := Json_Number(main, Json_Get(main, node, "maxHeight")); ok do v^ = i64(min(f64(n), hi))
			case "maxWidth": if lo, ok := Json_Number(main, Json_Get(main, node, "minWidth")); ok do v^ = i64(max(f64(n), lo))
			case "maxHeight": if lo, ok := Json_Number(main, Json_Get(main, node, "minHeight")); ok do v^ = i64(max(f64(n), lo))
			}
		case "keepAspectRatio":
			if b, _ := v.(bool); b && !(Json_Bool(main, Json_Get(main, node, "resizableX")) && Json_Bool(main, Json_Get(main, node, "resizableY"))) do return "only an entity type resizable both ways keeps its aspect"
		case "exportToToc":
			// Its fields leave the table of contents either way (EditEntityDefs)
			for fd in Json_Items(main, Json_Get(main, node, "fieldDefs")) do defWrite(p, doc, fd, "exportToToc", false)
		case "tileRect":
			if Json_String(main, Json_Get(main, node, "renderMode")) != "Tile" || Json_Kind(main, Json_Get(main, node, "tilesetId")) != .Number do return "pick a tileset to draw the entity type with first"
			if obj, ok := v.(LDtkJObject); ok do obj[0].value = i64(Json_Int(main, Json_Get(main, node, "tilesetId")))
		case "uiTileRect":
			current := Json_Get(main, node, "uiTileRect")
			if Json_Kind(main, current) != .Object do return "pick the editor tile's tileset first"
			if obj, ok := v.(LDtkJObject); ok do obj[0].value = i64(Json_Int(main, Json_Get(main, current, "tilesetUid")))
		}
	case .Field:
		info := LDtkDoc_FieldInfo(doc, node)
		entity := fieldEntity(doc, info.uid)
		switch m.key {
		case "editorDisplayMode":
			mode, _ := v.(string)
			if !LDtk_DisplayModeAllowed(info, entity >= 0, mode) do return fmt.tprintf("a %v field can't show as %s", info.type, mode)
		case "arrayMinLength", "arrayMaxLength":
			if !info.isArray do return "only an array has a size limit"
			n, isInt := v.(i64)
			if isInt && n <= 0 do v^ = LDtkJNull{}
			n, isInt = v.(i64)
			if !isInt do break
			// The other limit follows (FieldDefsForm)
			if m.key == "arrayMinLength" {
				if hi, ok := Json_Number(main, Json_Get(main, node, "arrayMaxLength")); ok do defWrite(p, doc, node, "arrayMaxLength", i64(max(f64(n), hi)))
			} else {
				if lo, ok := Json_Number(main, Json_Get(main, node, "arrayMinLength")); ok do defWrite(p, doc, node, "arrayMinLength", i64(min(f64(n), lo)))
			}
		case "tilesetUid":
			ts := uidOf(v^)
			if ts >= 0 && !isDef(doc, "tilesets", ts) do return "no such tileset"
			if info.type != .Tile do return "only a Tile field has a tileset"
		case "allowedRefsEntityUid":
			if info.type != .EntityRef do return "only an entity reference points at entities"
			if !isDef(doc, "entities", uidOf(v^)) do return "no such entity type"
		case "allowedRefTags", "allowOutOfLevelRef", "autoChainRef":
			if info.type != .EntityRef do return "only an entity reference points at entities"
		case "symmetricalRef":
			if info.type != .EntityRef do return "only an entity reference points at entities"
			if b, _ := v.(bool); b && info.allowedRefs != "OnlySame" do return "only references to the same entity type can be symmetrical"
		case "exportToToc":
			if entity < 0 || !Json_Bool(main, Json_Get(main, entity, "exportToToc")) do return "export the entity type to the table of contents first"
		case "searchable":
			if entity < 0 do return "only entities' fields are searchable"
		case "editorShowInWorld":
			if entity >= 0 do return "only level fields show in the world view"
		case "textLanguageMode":
			if info.type != .Text do return "only a Multilines field has a language"
		}
	case .Enum:
		switch m.key {
		case "iconTilesetUid":
			ts := uidOf(v^)
			if ts >= 0 && !isDef(doc, "tilesets", ts) do return "no such tileset"
			// The values' icons were the old tileset's (EditEnumDefs: clearAllTileIds)
			for value in Json_Items(main, Json_Get(main, node, "values")) do defWrite(p, doc, value, "tileRect", LDtkJNull{})
		}
	case .Tileset:
		switch m.key {
		case "spacing", "padding":
			// Bounded by the image (getMaxTileGridSize); the tiles' sources and the auto-layers' tiles follow
			limit := tilesetMaxGrid(main, node)
			if n, ok := v.(i64); ok do v^ = i64(min(int(n), limit))
			op.scope.gridTiles = true
			rerunTileset(op, Json_Int(main, Json_Get(main, node, "uid")))
			// LDtk builds the pixel data again (TilesetDefChanged)
			op.pixels[Json_Int(main, Json_Get(main, node, "uid"))] = true
		case "tagsSourceEnumUid":
			enumUid := uidOf(v^)
			if enumUid >= 0 {
				if !isDef(doc, "enums", enumUid) do return "pick an enum of the project (external enums can't tag tiles)"
			}
		}
	}
	return ""
}

/*
Which display modes a field may take (FieldDefsForm's EnumSelect filter): every field Hidden and
NameAndValue, ValueOnly but points, array counts for arrays, entity tiles for entities' enum and
tile fields, level tiles for levels', reference links for references, points for entities'
points, paths for arrays of them, radii for entities' single numbers.
*/
LDtk_DisplayModeAllowed :: proc(info: LDtkFieldInfo, entityField: bool, mode: string) -> bool {
	switch mode {
	case "Hidden", "NameAndValue": return true
	case "ValueOnly": return info.type != .Point
	case "ArrayCountNoLabel", "ArrayCountWithLabel": return info.isArray
	case "EntityTile": return entityField && (info.type == .Enum || info.type == .Tile)
	case "LevelTile": return !entityField && (info.type == .Enum || info.type == .Tile)
	case "RefLinkBetweenCenters", "RefLinkBetweenPivots": return info.type == .EntityRef
	case "Points", "PointStar": return info.type == .Point && entityField
	case "PointPath", "PointPathLoop": return info.type == .Point && info.isArray && entityField
	case "RadiusPx", "RadiusGrid": return !info.isArray && (info.type == .Int || info.type == .Float) && entityField
	}
	return false
}

// Whether a layer has nothing in any level (no IntGrid value, tile or entity)
@(private)
layerIsEmpty :: proc(doc: ^LDtkDoc, layerUid: int) -> bool {
	for _, level in doc.levels {
		file, array := LDtkDoc_LayerInstances(doc, level)
		json := LDtkDoc_Json(doc, file)
		for li in Json_Items(json, array) {
			if Json_Int(json, Json_Get(json, li, "layerDefUid"), -1) != layerUid do continue
			if Json_Count(json, Json_Get(json, li, "gridTiles")) > 0 || Json_Count(json, Json_Get(json, li, "entityInstances")) > 0 do return false
			for c in Json_Items(json, Json_Get(json, li, "intGridCsv")) do if Json_Text(json, c) != "0" do return false
		}
	}
	return true
}

// A tileset's largest grid, spacing or padding (TilesetDef.getMaxTileGridSize)
@(private)
tilesetMaxGrid :: proc(main: ^JsonDoc, node: int) -> int {
	if Json_Kind(main, Json_Get(main, node, "relPath")) != .String && Json_Kind(main, Json_Get(main, node, "embedAtlas")) != .String do return 100
	return max(min(Json_Int(main, Json_Get(main, node, "pxWid")), Json_Int(main, Json_Get(main, node, "pxHei"))), 2)
}

// The auto-layers drawing with a tileset get their rules applied again (their tiles' sources moved)
@(private)
rerunTileset :: proc(op: ^DefOp, tileset: int) {
	main := LDtkDoc_Main(op.s.cur)
	for d in Json_Items(main, LDtkDoc_Defs(op.s.cur, "layers")) {
		if nodeUid(main, Json_Get(main, d, "tilesetDefUid")) == tileset do op.rerun[Json_Int(main, Json_Get(main, d, "uid"))] = true
	}
}

// The members written by their own rules (`.Special`)
@(private)
defSpecial :: proc(op: ^DefOp, p: ^LDtkPatches, node: int, m: ^LDtkMember) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	t := strings.trim_space(edit.text)
	switch m.kind {
	case .Layer:
		switch m.key {
		case "gridSize":
			uid := Json_Int(main, Json_Get(main, node, "uid"))
			if Json_Kind(main, Json_Get(main, node, "autoSourceLayerDefUid")) == .Number do return "an auto-layer takes its source layer's grid"
			v, ok := editNumber(edit)
			if !ok do return fmt.tprintf("%q isn't a whole number", edit.text)
			return layerGrid(op, p, uid, int(clamp(math.round(v), m.lo, m.hi)))
		}
	case .Entity:
		switch m.key {
		case "render":
			return entityRender(op, p, node, t)
		case "uiTileset":
			if t == "" || t == "-1" {
				defWrite(p, doc, node, "uiTileRect", LDtkJNull{})
				return ""
			}
			ts, ok := strconv.parse_int(t)
			if !ok || !isDef(doc, "tilesets", ts) do return "no such tileset"
			defWrite(p, doc, node, "uiTileRect", rectJV(ts, {0, 0, 0, 0}))
		case "nineSliceBorders":
			// Each side (`index` 0 up, 1 right, 2 down, 3 left); the first sets the others while
			// they were all the same (EditEntityDefs)
			if Json_String(main, Json_Get(main, node, "tileRenderMode")) != "NineSlice" do return "only the 9-slices tile mode has borders"
			borders := [4]i64{2, 2, 2, 2}
			for b, i in Json_Items(main, Json_Get(main, node, "nineSliceBorders")) do if i < 4 do borders[i] = i64(Json_Int(main, b))
			side := clamp(edit.index, 0, 3)
			v, ok := editNumber(edit)
			n := ok ? i64(max(math.round(v), 1)) : (side == 0 ? 1 : borders[0])
			if side == 0 && borders[1] == borders[0] && borders[2] == borders[0] && borders[3] == borders[0] {
				borders = {n, n, n, n}
			}
			borders[side] = n
			defWrite(p, doc, node, "nineSliceBorders", jarray(borders[0], borders[1], borders[2], borders[3]))
		}
	case .Field:
		info := LDtkDoc_FieldInfo(doc, node)
		switch m.key {
		case "min", "max":
			return fieldRange(op, p, node, info, m.key, t)
		case "defaultOverride":
			return fieldDefault(op, p, node, info, edit.text)
		case "regex":
			if info.type != .String do return "only a String field has a regular expression"
			flags := regexFlags(Json_String(main, Json_Get(main, node, "regex")))
			defWrite(p, doc, node, "regex", t == "" ? LDtkJV(LDtkJNull{}) : LDtkJV(fmt.tprintf("/%s/%s", t, flags)))
		case "regexFlagI":
			raw := Json_String(main, Json_Get(main, node, "regex"))
			if raw == "" do return "type a regular expression first"
			content := regexContent(raw)
			flags := strings.builder_make(context.temp_allocator)
			// FieldDef.setRegexFlag: the flags kept, "i" on or off
			for c in regexFlags(raw) do if c != 'i' && c != 'I' do strings.write_rune(&flags, c)
			if edit.flag do strings.write_byte(&flags, 'i')
			defWrite(p, doc, node, "regex", fmt.tprintf("/%s/%s", content, strings.to_string(flags)))
		case "acceptFileTypes":
			if info.type != .Path do return "only a FilePath field has file types"
			defWrite(p, doc, node, "acceptFileTypes", LDtk_ParseFileTypes(edit.text))
		case "allowedRefs":
			if info.type != .EntityRef do return "only an entity reference points at entities"
			if t != "Any" && t != "OnlySame" && t != "OnlyTags" && t != "OnlySpecificEntity" do return fmt.tprintf("%q isn't a kind of reference", t)
			switch t {
			case "Any", "OnlyTags":
				// Not compatible with symmetry
				defWrite(p, doc, node, "symmetricalRef", false)
			case "OnlySpecificEntity":
				entity := fieldEntity(doc, info.uid)
				if entity >= 0 do defWrite(p, doc, node, "allowedRefsEntityUid", i64(Json_Int(main, Json_Get(main, entity, "uid"))))
			}
			defWrite(p, doc, node, "allowedRefs", strings.clone(t, context.temp_allocator))
		}
	case .Tileset:
		switch m.key {
		case "identifier":
			id, ok := LDtk_CleanIdentifier(t, defStyle(doc))
			if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text)
			if id in defIdentifiers(main, LDtkDoc_Defs(doc, "tilesets"), except = node) do return fmt.tprintf("another tileset is named %s", id)
			if Json_Kind(main, Json_Get(main, node, "embedAtlas")) == .String do return "LDtk's internal icons keep their name"
			defWrite(p, doc, node, "identifier", id)
		case "relPath":
			return tilesetImage(op, p, node, t)
		case "tileGridSize":
			v, ok := editNumber(edit)
			if !ok do return fmt.tprintf("%q isn't a whole number", edit.text)
			return tilesetGrid(op, p, node, int(clamp(math.round(v), 2, f64(tilesetMaxGrid(main, node)))))
		}
	case .Enum:
	}
	return ""
}

// A regular expression's content and flags as LDtk stores them ("/content/flags")
@(private)
regexContent :: proc(raw: string) -> string {
	if len(raw) < 2 || raw[0] != '/' do return ""
	end := strings.last_index_byte(raw, '/')
	if end <= 0 do return ""
	return raw[1:end]
}

@(private)
regexFlags :: proc(raw: string) -> string {
	if len(raw) < 2 || raw[0] != '/' do return "g"
	end := strings.last_index_byte(raw, '/')
	if end <= 0 do return "g"
	return raw[end + 1:]
}

/*
File types typed as LDtk keeps them (FieldDef.setAcceptFileTypes, its regex `\.?([a-z_\-.0-9]+)`):
each run of letters, digits, "_", "-" and "." is an extension (one leading dot dropped), lower
case, with a dot; runs with ".." or without a letter or digit are skipped, and each is kept once.
None (null) when there are none.
*/
LDtk_ParseFileTypes :: proc(text: string) -> LDtkJV {
	out := make([dynamic]LDtkJV, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	class :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' }
	i := 0
	for i < len(text) {
		for i < len(text) && !class(text[i]) do i += 1
		if i >= len(text) do break
		// `\.?`: one dot, then the group's run
		if text[i] == '.' do i += 1
		start := i
		for i < len(text) && class(text[i]) do i += 1
		if i == start do continue
		ext := strings.to_lower(text[start:i], context.temp_allocator)
		alnum := false
		for c in transmute([]u8)ext do if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') do alnum = true
		if !alnum || strings.contains(ext, "..") || ext in seen do continue
		seen[ext] = true
		append(&out, fmt.tprintf(".%s", ext))
	}
	if len(out) == 0 do return LDtkJNull{}
	return LDtkJArray(out[:])
}

// Haxe's Std.parseInt: the leading integer of a text (hex with 0x), false without one
@(private)
haxeParseInt :: proc(text: string) -> (int, bool) {
	t := strings.trim_space(text)
	if strings.has_prefix(t, "0x") || strings.has_prefix(t, "0X") do return strconv.parse_int(t[2:], 16)
	end := 0
	if end < len(t) && (t[end] == '-' || t[end] == '+') do end += 1
	digits := end
	for end < len(t) && t[end] >= '0' && t[end] <= '9' do end += 1
	if end == digits do return 0, false
	return strconv.parse_int(t[:end])
}

// JavaScript's parseFloat: the leading number of a text, false without one
@(private)
jsParseFloat :: proc(text: string) -> (f64, bool) {
	t := strings.trim_space(text)
	end := 0
	if end < len(t) && (t[end] == '-' || t[end] == '+') do end += 1
	for end < len(t) && ((t[end] >= '0' && t[end] <= '9') || t[end] == '.') do end += 1
	if end < len(t) && (t[end] == 'e' || t[end] == 'E') {
		e := end + 1
		if e < len(t) && (t[e] == '-' || t[e] == '+') do e += 1
		if e < len(t) && t[e] >= '0' && t[e] <= '9' {
			for e < len(t) && t[e] >= '0' && t[e] <= '9' do e += 1
			end = e
		}
	}
	return strconv.parse_f64(t[:end])
}

// A field's minimum or maximum (FieldDef.setMin / setMax, then checkMinMax: swapped when
// reversed, the default clamped into them)
@(private)
fieldRange :: proc(op: ^DefOp, p: ^LDtkPatches, node: int, info: LDtkFieldInfo, key, text: string) -> string {
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	if info.type != .Int && info.type != .Float do return "only a number field has a range"
	lo, hi := info.min, info.max
	v: Maybe(f64)
	if text != "" {
		if info.type == .Int {
			n, ok := haxeParseInt(text)
			if ok do v = f64(n)
		} else {
			f, ok := jsParseFloat(text)
			if ok do v = f
		}
	}
	if key == "min" do lo = v
	else do hi = v
	if a, aok := lo.?; aok {
		if b, bok := hi.?; bok && b < a do lo, hi = hi, lo
	}
	num :: proc(v: Maybe(f64)) -> LDtkJV {
		if x, ok := v.?; ok do return jvNumber(ldtkWriteFloat(x))
		return LDtkJNull{}
	}
	defWrite(p, doc, node, "min", num(lo))
	defWrite(p, doc, node, "max", num(hi))
	// The default clamped into the range
	over := Json_Get(main, node, "defaultOverride")
	param := Json_At(main, Json_Get(main, over, "params"), 0)
	if d, ok := Json_Number(main, param); ok {
		c := d
		if info.type == .Int {
			if a, has := lo.?; has do c = max(c, ldtkRound(a))
			if b, has := hi.?; has do c = min(c, ldtkRound(b))
		} else {
			if a, has := lo.?; has do c = max(c, a)
			if b, has := hi.?; has do c = min(c, b)
		}
		if c != d do LDtkPatches_Set(p, doc, 0, param, LDtk_JsNumber(c))
	}
	return ""
}

// A value wrapper as LDtk writes one (`{ "id": "V_Int", "params": [5] }`)
@(private)
wrapperJV :: proc(id: string, param: LDtkJV) -> LDtkJV {
	return jobject(jpair("id", id), jpair("params", jarray(param)))
}

/*
A field's default from typed text (FieldDef.setDefault): parsed by the field's type, clamped to
its range; empty or not a value of the type is no default.
*/
@(private)
fieldDefault :: proc(op: ^DefOp, p: ^LDtkPatches, node: int, info: LDtkFieldInfo, raw: string) -> string {
	doc := op.s.cur
	clampI :: proc(info: LDtkFieldInfo, v: f64) -> f64 {
		x := v
		if lo, ok := info.min.?; ok do x = max(x, ldtkRound(lo))
		if hi, ok := info.max.?; ok do x = min(x, ldtkRound(hi))
		return x
	}
	clampF :: proc(info: LDtkFieldInfo, v: f64) -> f64 {
		x := v
		if lo, ok := info.min.?; ok do x = max(x, lo)
		if hi, ok := info.max.?; ok do x = min(x, hi)
		return x
	}
	if info.isArray do return "an array's items have no default"
	t := strings.trim_space(raw)
	value := LDtkJV(LDtkJNull{})
	#partial switch info.type {
	case .Int:
		if n, ok := haxeParseInt(raw); ok do value = wrapperJV("V_Int", i64(clampI(info, f64(n))))
	case .Float:
		if f, ok := jsParseFloat(raw); ok do value = wrapperJV("V_Float", jvNumber(clampF(info, f)))
	case .Color:
		if c, ok := LDtk_ParseColor(t); ok do value = wrapperJV("V_Int", i64(c))
	case .Text:
		if raw != "" do value = wrapperJV("V_String", strings.clone(raw, context.temp_allocator))
	case .String, .Path, .EntityRef:
		if t != "" do value = wrapperJV("V_String", strings.clone(t, context.temp_allocator))
	case .Bool:
		switch strings.to_lower(t, context.temp_allocator) {
		case "true": value = wrapperJV("V_Bool", true)
		case "false": value = wrapperJV("V_Bool", false)
		}
	case .Point:
		xs, sep, ys := strings.partition(t, ",")
		x, xok := haxeParseInt(xs)
		y, yok := haxeParseInt(ys)
		if sep != "" && xok && yok do value = wrapperJV("V_String", fmt.tprintf("%d,%d", x, y))
	case .Enum:
		if t != "" {
			found := false
			for v in LDtkDoc_EnumValues(doc, info.enumUid) do if v == t do found = true
			if !found do return fmt.tprintf("%q isn't one of the enum's values", t)
			value = wrapperJV("V_String", strings.clone(t, context.temp_allocator))
		}
	case .Tile:
		// "x,y,w,h": the numbers kept; a default tile makes the field nullable (FieldDefsForm)
		nums := make([dynamic]string, context.temp_allocator)
		for part in strings.split(t, ",", context.temp_allocator) do if n, ok := haxeParseInt(part); ok do append(&nums, fmt.tprint(n))
		if len(nums) > 0 {
			value = wrapperJV("V_String", strings.join(nums[:], ",", context.temp_allocator))
			defWrite(p, doc, node, "canBeNull", true)
		}
	case:
		return fmt.tprintf("%v fields have no default", info.type)
	}
	defWrite(p, doc, node, "defaultOverride", value)
	return ""
}

/*
How an entity type is drawn (EditEntityDefs' render select): "!Rectangle", "!Ellipse", "!Cross"
(a shape), a tileset's uid (its tiles), or "LdtkIcons" (LDtk's internal icons, the tileset made
when missing). Its tile is cleared; the opacities start again when it turns to or from tiles.
*/
@(private)
entityRender :: proc(op: ^DefOp, p: ^LDtkPatches, node: int, choice: string) -> string {
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	oldMode := Json_String(main, Json_Get(main, node, "renderMode"))
	mode := ""
	tileset := LDtkJV(LDtkJNull{})
	switch {
	case strings.has_prefix(choice, "!"):
		mode = choice[1:]
		if mode != "Rectangle" && mode != "Ellipse" && mode != "Cross" do return fmt.tprintf("%q isn't a shape", mode)
	case choice == "LdtkIcons":
		uid, problem := embedTileset(op)
		if problem != "" do return problem
		mode, tileset = "Tile", i64(uid)
	case:
		uid, ok := strconv.parse_int(choice)
		if !ok || !isDef(doc, "tilesets", uid) do return "no such tileset"
		mode, tileset = "Tile", i64(uid)
	}
	defWrite(p, doc, node, "renderMode", mode)
	defWrite(p, doc, node, "tilesetId", tileset)
	defWrite(p, doc, node, "tileRect", LDtkJNull{})
	if oldMode != "Tile" && mode == "Tile" {
		defWrite(p, doc, node, "tileOpacity", i64(1))
		defWrite(p, doc, node, "fillOpacity", 0.08)
		defWrite(p, doc, node, "lineOpacity", i64(0))
	}
	if oldMode == "Tile" && mode != "Tile" {
		defWrite(p, doc, node, "tileOpacity", i64(1))
		defWrite(p, doc, node, "fillOpacity", i64(1))
		defWrite(p, doc, node, "lineOpacity", i64(1))
	}
	return ""
}

// --- Grids -----------------------------------------------------------------------------------

/*
A layer's grid changed (EditLayerDefs' gridSize: LayerInstance.remapToGridSize in every level, for
the layer and the auto-layers built from it, which take the same grid): IntGrid values and tiles
keep their cell (those past the new size go), entities move by the ratio (as their custom sizes),
auto-layers' rules are applied again.
*/
@(private)
layerGrid :: proc(op: ^DefOp, p: ^LDtkPatches, layerUid, grid: int) -> string {
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	def := LDtkDoc_DefByUid(doc, "layers", layerUid)
	if def < 0 do return "no such layer"
	old := max(Json_Int(main, Json_Get(main, def, "gridSize"), 16), 1)
	targets := make(map[int]bool, context.temp_allocator)
	targets[layerUid] = true
	for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) {
		if nodeUid(main, Json_Get(main, d, "autoSourceLayerDefUid")) == layerUid do targets[Json_Int(main, Json_Get(main, d, "uid"))] = true
	}
	for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) {
		uid := Json_Int(main, Json_Get(main, d, "uid"))
		if uid not_in targets do continue
		defWrite(p, doc, d, "gridSize", i64(grid))
		op.rerun[uid] = true
	}
	if grid == old do return ""
	op.scope.gridTiles = true
	ratio := f64(grid) / f64(old)
	for _, level in doc.levels {
		m, ok := LDtkLevel_Read(doc, "", level)
		if !ok do continue
		defer LDtkLevel_Destroy(&m)
		file, array := LDtkDoc_LayerInstances(doc, level)
		json := LDtkDoc_Json(doc, file)
		minified := Json_Minified(json)
		for &l in m.layers {
			d := &m.defs[l.def]
			if d.uid not_in targets do continue
			li := -1
			for item in Json_Items(json, array) do if Json_String(json, Json_Get(json, item, "iid")) == l.iid do li = item
			if li < 0 do continue
			pxWid, pxHei := m.pxWid - l.pxOffset.x, m.pxHei - l.pxOffset.y
			newW, newH := int(math.ceil(f64(pxWid) / f64(grid))), int(math.ceil(f64(pxHei) / f64(grid)))
			switch d.kind {
			case .IntGrid:
				cells := make([]i32, newW * newH, context.temp_allocator)
				for cy in 0 ..< l.cHei do for cx in 0 ..< l.cWid {
					v := l.intGrid[cx + cy * l.cWid]
					if v != 0 && cx < newW && cy < newH do cells[cx + cy * newW] = v
				}
				fake := LDtkLayerData{intGrid = cells, cWid = newW, cHei = newH}
				csv := Json_Get(json, li, "intGridCsv")
				LDtkPatches_Set(p, doc, file, csv, LDtkLayer_IntGridText(&fake, minified, LDtk_IndentAt(json.text, int(json.nodes[csv].start))))
			case .Tiles:
				stacks := make([][dynamic]LDtkGridTile, newW * newH, context.temp_allocator)
				for cy in 0 ..< l.cHei do for cx in 0 ..< l.cWid {
					stack := l.tiles[cx + cy * l.cWid]
					if len(stack) == 0 || cx >= newW || cy >= newH do continue
					s := make([dynamic]LDtkGridTile, context.temp_allocator)
					append(&s, ..stack[:])
					stacks[cx + cy * newW] = s
				}
				fake := LDtkLayerData{def = l.def, tiles = stacks, cWid = newW, cHei = newH, overrideTileset = l.overrideTileset}
				saved := d.gridSize
				d.gridSize = grid
				tiles := Json_Get(json, li, "gridTiles")
				LDtkPatches_Set(p, doc, file, tiles, LDtkLayer_GridTilesText(&m, &fake, minified, LDtk_IndentAt(json.text, int(json.nodes[tiles].start))))
				d.gridSize = saved
			case .Entities:
				ed := ""
				_ = ed
				for e in Json_Items(json, Json_Get(json, li, "entityInstances")) {
					px := Json_Get(json, e, "px")
					x, y := Json_Int(json, Json_At(json, px, 0)), Json_Int(json, Json_At(json, px, 1))
					LDtkPatches_Set(p, doc, file, px, writeAt(json, px, jarray(i64(math.floor(ratio * f64(x))), i64(math.floor(ratio * f64(y)))), minified))
					// Custom sizes (not the type's) scale too
					etype := LDtkDoc_DefByUid(doc, "entities", Json_Int(json, Json_Get(json, e, "defUid"), -1))
					for key in ([]string{"width", "height"}) {
						size := Json_Int(json, Json_Get(json, e, key))
						if size != Json_Int(main, Json_Get(main, etype, key)) do LDtkPatches_Set(p, doc, file, Json_Get(json, e, key), fmt.tprint(int(math.floor(ratio * f64(size)))))
					}
				}
			case .AutoLayer:
			}
		}
	}
	return ""
}

// --- New definitions -------------------------------------------------------------------------

// A new layer definition as LDtk writes one (Definitions.createLayerDef, LayerDef.toJson)
@(private)
newLayerJV :: proc(doc: ^LDtkDoc, uid: int, type, identifier: string) -> LDtkJV {
	main := LDtkDoc_Main(doc)
	grid := i64(Json_Int(main, Json_Get(main, Json_Root(main), "defaultGridSize"), 16))
	tileset := LDtkJV(LDtkJNull{})
	sets := Json_Items(main, LDtkDoc_Defs(doc, "tilesets"))
	if type == "Tiles" && len(sets) == 1 {
		// The only tileset, and its grid
		grid = i64(Json_Int(main, Json_Get(main, sets[0], "tileGridSize"), 16))
		tileset = i64(Json_Int(main, Json_Get(main, sets[0], "uid")))
	}
	values := LDtkJV(LDtkJArray{})
	if type == "IntGrid" {
		// LayerDef's first value (addIntGridValue(0x0))
		values = jarray(jobject(jpair("value", i64(1)), jpair("identifier", LDtkJNull{}), jpair("color", "#000000"), jpair("tile", LDtkJNull{}), jpair("groupUid", i64(0))))
	}
	entities := type == "Entities"
	return jobject(
		jpair("__type", type),
		jpair("identifier", identifier),
		jpair("type", type),
		jpair("uid", i64(uid)),
		jpair("doc", LDtkJNull{}),
		jpair("uiColor", LDtkJNull{}),
		jpair("gridSize", grid),
		jpair("guideGridWid", i64(0)),
		jpair("guideGridHei", i64(0)),
		jpair("displayOpacity", i64(1)),
		jpair("inactiveOpacity", entities ? LDtkJV(0.6) : LDtkJV(i64(1))),
		jpair("hideInList", false),
		jpair("hideFieldsWhenInactive", entities),
		jpair("canSelectWhenInactive", true),
		jpair("renderInWorldView", true),
		jpair("pxOffsetX", i64(0)),
		jpair("pxOffsetY", i64(0)),
		jpair("parallaxFactorX", i64(0)),
		jpair("parallaxFactorY", i64(0)),
		jpair("parallaxScaling", true),
		jpair("requiredTags", LDtkJArray{}),
		jpair("excludedTags", LDtkJArray{}),
		jpair("autoTilesKilledByOtherLayerUid", LDtkJNull{}),
		jpair("uiFilterTags", LDtkJArray{}),
		jpair("useAsyncRender", false),
		jpair("intGridValues", values),
		jpair("intGridValuesGroups", LDtkJArray{}),
		jpair("autoRuleGroups", LDtkJArray{}),
		jpair("autoSourceLayerDefUid", LDtkJNull{}),
		jpair("tilesetDefUid", tileset),
		jpair("tilePivotX", i64(0)),
		jpair("tilePivotY", i64(0)),
		jpair("biomeFieldUid", LDtkJNull{}),
	)
}

// A new entity definition as LDtk writes one (Definitions.createEntityDef, EntityDef.toJson)
@(private)
newEntityDefJV :: proc(doc: ^LDtkDoc, uid: int, identifier: string) -> LDtkJV {
	main := LDtkDoc_Main(doc)
	root := Json_Root(main)
	colors := make([dynamic]int, context.temp_allocator)
	for e in Json_Items(main, LDtkDoc_Defs(doc, "entities")) {
		c, _ := LDtk_ParseColor(Json_String(main, Json_Get(main, e, "color")))
		append(&colors, c)
	}
	return jobject(
		jpair("identifier", identifier),
		jpair("uid", i64(uid)),
		jpair("tags", LDtkJArray{}),
		jpair("exportToToc", false),
		jpair("allowOutOfBounds", false),
		jpair("doc", LDtkJNull{}),
		jpair("width", i64(Json_Int(main, Json_Get(main, root, "defaultEntityWidth"), 16))),
		jpair("height", i64(Json_Int(main, Json_Get(main, root, "defaultEntityHeight"), 16))),
		jpair("resizableX", false),
		jpair("resizableY", false),
		jpair("minWidth", LDtkJNull{}),
		jpair("maxWidth", LDtkJNull{}),
		jpair("minHeight", LDtkJNull{}),
		jpair("maxHeight", LDtkJNull{}),
		jpair("keepAspectRatio", false),
		jpair("tileOpacity", i64(1)),
		jpair("fillOpacity", i64(1)),
		jpair("lineOpacity", i64(1)),
		jpair("hollow", false),
		jpair("color", LDtk_FormatColor(LDtk_SuggestColor(colors[:]))),
		jpair("renderMode", "Rectangle"),
		jpair("showName", true),
		jpair("tilesetId", LDtkJNull{}),
		jpair("tileRenderMode", "FitInside"),
		jpair("tileRect", LDtkJNull{}),
		jpair("uiTileRect", LDtkJNull{}),
		jpair("nineSliceBorders", LDtkJArray{}),
		jpair("maxCount", i64(0)),
		jpair("limitScope", "PerLevel"),
		jpair("limitBehavior", "MoveLastOne"),
		jpair("pivotX", jvNumber(Json_Float(main, Json_Get(main, root, "defaultPivotX")))),
		jpair("pivotY", jvNumber(Json_Float(main, Json_Get(main, root, "defaultPivotY")))),
		jpair("fieldDefs", LDtkJArray{}),
	)
}

// A field type as LDtk writes it ("F_Int", "F_Enum(30)") and its kind; false when it isn't one
@(private)
fieldTypeOf :: proc(text: string) -> (LDtkFieldType, int, bool) {
	switch text {
	case "F_Int": return .Int, -1, true
	case "F_Float": return .Float, -1, true
	case "F_String": return .String, -1, true
	case "F_Text": return .Text, -1, true
	case "F_Bool": return .Bool, -1, true
	case "F_Color": return .Color, -1, true
	case "F_Point": return .Point, -1, true
	case "F_Path": return .Path, -1, true
	case "F_EntityRef": return .EntityRef, -1, true
	case "F_Tile": return .Tile, -1, true
	}
	if strings.has_prefix(text, "F_Enum(") && strings.has_suffix(text, ")") {
		uid, ok := strconv.parse_int(text[len("F_Enum("):len(text) - 1])
		return .Enum, uid, ok
	}
	return .Unknown, -1, false
}

// A field type's name as LDtk names new fields (Lang.getFieldType)
@(private)
fieldTypeName :: proc(t: LDtkFieldType) -> string {
	#partial switch t {
	case .Int: return "Integer"
	case .Color: return "Color"
	case .Float: return "Float"
	case .String: return "String"
	case .Text: return "Multilines"
	case .Bool: return "Boolean"
	case .Point: return "Point"
	case .Path: return "File path"
	case .EntityRef: return "Entity ref"
	case .Tile: return "Tile"
	}
	return "Field"
}

// A new field definition as LDtk writes one (new FieldDef, FieldDef.toJson)
@(private)
newFieldJV :: proc(doc: ^LDtkDoc, uid: int, typeText, identifier, jsonType: string, isArray: bool) -> LDtkJV {
	t, _, _ := fieldTypeOf(typeText)
	canBeNull := t == .String || t == .Text || t == .Path || t == .Point || (t == .EntityRef && !isArray)
	mode := "Hidden"
	#partial switch t {
	case .Point: mode = "PointPath"
	case .EntityRef: mode = "RefLinkBetweenCenters"
	case .Tile: mode = "EntityTile"
	}
	return jobject(
		jpair("identifier", identifier),
		jpair("doc", LDtkJNull{}),
		jpair("__type", jsonType),
		jpair("uid", i64(uid)),
		jpair("type", typeText),
		jpair("isArray", isArray),
		jpair("canBeNull", canBeNull),
		jpair("arrayMinLength", LDtkJNull{}),
		jpair("arrayMaxLength", LDtkJNull{}),
		jpair("editorDisplayMode", mode),
		jpair("editorDisplayScale", i64(1)),
		jpair("editorDisplayPos", "Above"),
		jpair("editorLinkStyle", t == .EntityRef ? "CurvedArrow" : "StraightArrow"),
		jpair("editorDisplayColor", LDtkJNull{}),
		jpair("editorAlwaysShow", false),
		jpair("editorShowInWorld", true),
		jpair("editorCutLongValues", true),
		jpair("editorTextSuffix", LDtkJNull{}),
		jpair("editorTextPrefix", LDtkJNull{}),
		jpair("useForSmartColor", t == .Color),
		jpair("exportToToc", false),
		jpair("searchable", false),
		jpair("min", LDtkJNull{}),
		jpair("max", LDtkJNull{}),
		jpair("regex", LDtkJNull{}),
		jpair("acceptFileTypes", LDtkJNull{}),
		jpair("defaultOverride", LDtkJNull{}),
		jpair("textLanguageMode", LDtkJNull{}),
		jpair("symmetricalRef", false),
		jpair("autoChainRef", true),
		jpair("allowOutOfLevelRef", true),
		jpair("allowedRefs", "OnlySame"),
		jpair("allowedRefsEntityUid", LDtkJNull{}),
		jpair("allowedRefTags", LDtkJArray{}),
		jpair("tilesetUid", LDtkJNull{}),
	)
}

// A new local enum as LDtk writes one (Definitions.createEnumDef, EnumDef.toJson)
@(private)
newEnumJV :: proc(uid: int, identifier: string, external: LDtkJV = nil, checksum: LDtkJV = nil) -> LDtkJV {
	return jobject(
		jpair("identifier", identifier),
		jpair("uid", i64(uid)),
		jpair("values", LDtkJArray{}),
		jpair("iconTilesetUid", LDtkJNull{}),
		jpair("externalRelPath", external != nil ? external : LDtkJNull{}),
		jpair("externalFileChecksum", checksum != nil ? checksum : LDtkJNull{}),
		jpair("tags", LDtkJArray{}),
	)
}

// An item put into an array at an index (past the end: appended), at the items' indentation
@(private)
insertItem :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, file, array, index: int, item: LDtkJV) {
	json := LDtkDoc_Json(doc, file)
	minified := Json_Minified(json)
	n := json.nodes[array]
	if index >= int(n.count) || n.count == 0 {
		appendItem(p, doc, file, array, item, minified)
		return
	}
	at := Json_At(json, array, index)
	indent := LDtk_IndentAt(json.text, int(json.nodes[at].start))
	LDtkPatches_Add(p, file, Json_InsertPatch(json, array, index, LDtk_PrettyJson(item, minified, indent)))
}

/*
A definition created (EditLayerDefs' create, EditEntityDefs' create and presets, FieldDefsForm's
create, EditEnumDefs' create, EditTilesetDefs' create).
*/
@(private)
defAdded :: proc(op: ^DefOp) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	style := defStyle(doc)
	p := LDtkPatches{}
	uids := uidsMake(doc)
	switch edit.kind {
	case .Layer:
		type := strings.trim_space(edit.text)
		found := false
		for t in LDTK_LAYER_TYPES do if t == type do found = true
		if !found do return fmt.tprintf("%q isn't a layer type", edit.text)
		list := LDtkDoc_Defs(doc, "layers")
		uid := uidTake(&uids)
		id := ldtkUniqueId(type, style, defIdentifiers(main, list))
		// New layers go on top (layers.insert(0, l))
		insertItem(&p, doc, 0, list, 0, newLayerJV(doc, uid, type, id))
	case .Entity:
		list := LDtkDoc_Defs(doc, "entities")
		uid := uidTake(&uids)
		taken := defIdentifiers(main, list)
		item := newEntityDefJV(doc, uid, ldtkUniqueId("Entity", style, taken))
		// The presets (EditEntityDefs): a rectangle or a circle region
		obj := item.(LDtkJObject)
		set :: proc(obj: LDtkJObject, key: string, v: LDtkJV) {
			for &pair in obj do if pair.key == key do pair.value = v
		}
		switch edit.text {
		case "":
		case "RectRegion", "CircleRegion":
			set(obj, "identifier", ldtkUniqueId(edit.text, style, taken))
			set(obj, "hollow", true)
			set(obj, "resizableX", true)
			set(obj, "resizableY", true)
			set(obj, "tags", jarray("region"))
			if edit.text == "RectRegion" {
				set(obj, "pivotX", i64(0))
				set(obj, "pivotY", i64(0))
			} else {
				set(obj, "renderMode", "Ellipse")
				set(obj, "keepAspectRatio", true)
				set(obj, "pivotX", 0.5)
				set(obj, "pivotY", 0.5)
			}
		case: return fmt.tprintf("%q isn't a preset", edit.text)
		}
		appendItem(&p, doc, 0, list, item, Json_Minified(main))
	case .Field:
		t, enumUid, ok := fieldTypeOf(edit.text)
		if !ok do return fmt.tprintf("%q isn't a field type", edit.text)
		if t == .Enum && LDtkDefs_Node(doc, .Enum, enumUid) < 0 do return "no such enum"
		level := edit.def < 0
		if level && (t == .EntityRef || t == .Point) do return "levels' fields can't be entity references or points"
		list := level ? LDtkDoc_Defs(doc, "levelFields") : Json_Get(main, LDtkDoc_DefByUid(doc, "entities", edit.def), "fieldDefs")
		if list < 0 do return "no such entity type"
		uid := uidTake(&uids)
		base := fieldTypeName(t)
		if t == .Enum do base = Json_String(main, Json_Get(main, LDtkDefs_Node(doc, .Enum, enumUid), "identifier"))
		id := ldtkUniqueId(base, "Free", defIdentifiers(main, list))
		appendItem(&p, doc, 0, list, newFieldJV(doc, uid, edit.text, id, "", edit.flag), Json_Minified(main))
	case .Enum:
		list := LDtkDoc_Defs(doc, "enums")
		taken := defIdentifiers(main, list)
		for d in Json_Items(main, LDtkDoc_Defs(doc, "externalEnums")) do taken[strings.clone(Json_String(main, Json_Get(main, d, "identifier")), context.temp_allocator)] = true
		name := strings.trim_space(edit.text)
		id := ""
		if name == "" {
			id = ldtkUniqueId("Enum", style, taken)
		} else {
			clean, ok := LDtk_CleanIdentifier(name, style)
			if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text)
			if clean in taken do return fmt.tprintf("another enum is named %s", clean)
			id = clean
		}
		appendItem(&p, doc, 0, list, newEnumJV(uidTake(&uids), id), Json_Minified(main))
	case .Tileset:
		uid := uidTake(&uids)
		item, problem := newTilesetJV(op, uid, strings.trim_space(edit.text))
		if problem != "" do return problem
		appendItem(&p, doc, 0, LDtkDoc_Defs(doc, "tilesets"), item, Json_Minified(main))
	}
	uidsDone(&p, doc, uids)
	return stagesApply(op.s, &p)
}

// --- Removed, duplicated, moved --------------------------------------------------------------

/*
A definition removed (Definitions.removeLayerDef, removeEntityDef, removeEnumDef,
removeTilesetDef, FieldDefsForm.deleteField): what used it is tidied (instances removed, references
cleared).
*/
@(private)
defRemoved :: proc(op: ^DefOp) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	uid := edit.kind == .Field ? edit.field : edit.def
	node := LDtkDefs_Node(doc, edit.kind, uid)
	if node < 0 do return "no such definition"
	if edit.kind == .Enum && Json_Kind(main, Json_Get(main, node, "externalRelPath")) == .String do return "an external enum goes with its file (Remove the file's enums)"
	p := LDtkPatches{}
	LDtkPatches_Add(&p, 0, Json_RemovePatch(main, node))
	if edit.kind == .Tileset do op.scope.gridTiles = true
	return stagesApply(op.s, &p)
}

// A copy of a definition's JSON with a new uid and identifier (the paste functions of Definitions)
@(private)
defDuplicated :: proc(op: ^DefOp) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	style := defStyle(doc)
	uid := edit.kind == .Field ? edit.field : edit.def
	node := LDtkDefs_Node(doc, edit.kind, uid)
	if node < 0 do return "no such definition"
	if edit.kind == .Enum && Json_Kind(main, Json_Get(main, node, "externalRelPath")) == .String do return "an external enum can't be copied"
	if edit.kind == .Tileset && Json_Kind(main, Json_Get(main, node, "embedAtlas")) == .String do return "LDtk's internal icons can't be copied"
	uids := uidsMake(doc)
	item := ldtkJV(main, node)
	obj := item.(LDtkJObject)
	set :: proc(obj: LDtkJObject, key: string, v: LDtkJV) {
		for &pair in obj do if pair.key == key do pair.value = v
	}
	get :: proc(obj: LDtkJObject, key: string) -> LDtkJV {
		for pair in obj do if pair.key == key do return pair.value
		return nil
	}
	parent := main.nodes[node].parent
	idStyle := edit.kind == .Field ? "Free" : style
	taken := defIdentifiers(main, int(parent))
	if edit.kind == .Enum do for d in Json_Items(main, LDtkDoc_Defs(doc, "externalEnums")) do taken[strings.clone(Json_String(main, Json_Get(main, d, "identifier")), context.temp_allocator)] = true
	set(obj, "uid", i64(uidTake(&uids)))
	set(obj, "identifier", ldtkUniqueId(Json_String(main, Json_Get(main, node, "identifier")), idStyle, taken))
	#partial switch edit.kind {
	case .Layer:
		// Its rule groups and rules get new uids (pasteLayerDef)
		if groups, ok := get(obj, "autoRuleGroups").(LDtkJArray); ok do for g in groups {
			go := g.(LDtkJObject) or_continue
			set(go, "uid", i64(uidTake(&uids)))
			if rules, isArray := get(go, "rules").(LDtkJArray); isArray do for r in rules {
				if ro, isObj := r.(LDtkJObject); isObj do set(ro, "uid", i64(uidTake(&uids)))
			}
		}
	case .Entity:
		// Its fields get new uids (pasteEntityDef)
		if fields, ok := get(obj, "fieldDefs").(LDtkJArray); ok do for f in fields {
			if fo, isObj := f.(LDtkJObject); isObj do set(fo, "uid", i64(uidTake(&uids)))
		}
	}
	p := LDtkPatches{}
	// After the original
	at := 0
	for item, i in Json_Items(main, int(parent)) do if item == node do at = i
	insertItem(&p, doc, 0, int(parent), at + 1, item)
	uidsDone(&p, doc, uids)
	return stagesApply(op.s, &p)
}

// A definition moved in its list by `number` places (LDtk's sort functions, its lists' drags)
@(private)
defMoved :: proc(op: ^DefOp) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	uid := edit.kind == .Field ? edit.field : edit.def
	node := LDtkDefs_Node(doc, edit.kind, uid)
	if node < 0 do return "no such definition"
	parent := int(main.nodes[node].parent)
	items := Json_Items(main, parent)
	at := 0
	for item, i in items do if item == node do at = i
	steps := int(math.round(edit.number))
	to := clamp(at + steps, 0, len(items) - 1)
	if to == at do return ""
	texts := make([]string, len(items), context.temp_allocator)
	for item, i in items do texts[i] = strings.clone(Json_Text(main, item), context.temp_allocator)
	order := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< len(items) do if i != at do append(&order, i)
	inject_at(&order, to, at)
	p := LDtkPatches{}
	for i in min(at, to) ..= max(at, to) do LDtkPatches_Add(&p, 0, Json_SetPatch(main, items[i], texts[order[i]]))
	return stagesApply(op.s, &p)
}

// --- Field type conversions ------------------------------------------------------------------

// LDtk's field type conversions (misc.FieldTypeConverter): id, from, to, whether values may change
LDtkConversion :: struct {
	id, label: string,
	from, to: LDtkFieldType,
	lossless: bool,
}

LDTK_CONVERSIONS := [?]LDtkConversion{
	{"ToArray", "Turn into array", .Unknown, .Unknown, true},
	{"StringToText", "To Multilines", .String, .Text, true},
	{"TextToString", "To String (remove line breaks)", .Text, .String, false},
	{"PathToString", "To String", .Path, .String, true},
	{"StringToPath", "To File path", .String, .Path, true},
	{"IntToFloat", "To Float", .Int, .Float, true},
	{"BoolToInt", "To Integer", .Bool, .Int, true},
	{"FloatToIntTruncate", "To Integer (truncate)", .Float, .Int, false},
	{"FloatToIntRound", "To Integer (round)", .Float, .Int, false},
}

// The conversions a field can take (FieldTypeConverter.getAllConvertors; temp)
LDtk_Conversions :: proc(info: LDtkFieldInfo) -> []LDtkConversion {
	out := make([dynamic]LDtkConversion, context.temp_allocator)
	for c in LDTK_CONVERSIONS {
		if c.id == "ToArray" {
			if !info.isArray do append(&out, c)
			continue
		}
		if c.from == info.type do append(&out, c)
	}
	return out[:]
}

// LDtk's type text of a kind ("F_Float")
@(private)
fieldKindText :: proc(t: LDtkFieldType) -> string {
	#partial switch t {
	case .Int: return "F_Int"
	case .Float: return "F_Float"
	case .String: return "F_String"
	case .Text: return "F_Text"
	case .Bool: return "F_Bool"
	case .Color: return "F_Color"
	case .Point: return "F_Point"
	case .Path: return "F_Path"
	case .EntityRef: return "F_EntityRef"
	case .Tile: return "F_Tile"
	}
	return ""
}

/*
A field's type converted (FieldTypeConverter.convert): each value of every instance converted
(entities' and, unlike LDtk, levels' too: LDtk leaves those, which it can't read again), then the
definition.
*/
@(private)
fieldConverted :: proc(op: ^DefOp) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	_, node := LDtkDoc_FieldDef(doc, edit.field)
	if node < 0 do return "no such field"
	info := LDtkDoc_FieldInfo(doc, node)
	conv: ^LDtkConversion
	for &c in LDtk_Conversions(info) do if c.id == edit.text do conv = &c
	if conv == nil do return fmt.tprintf("a %v field can't be converted that way", info.type)
	p := LDtkPatches{}
	if conv.id == "ToArray" {
		defWrite(&p, doc, node, "isArray", true)
		return stagesApply(op.s, &p)
	}
	// The instances' editor values
	for fi in ldtkAllFieldInstances(doc) {
		json := LDtkDoc_Json(doc, fi.file)
		if Json_Int(json, Json_Get(json, fi.node, "defUid"), -1) != edit.field do continue
		raw := Json_Get(json, fi.node, "realEditorValues")
		values := Json_Get(json, fi.node, "__value")
		out := make([dynamic]LDtkJV, context.temp_allocator)
		changed := false
		for r, i in Json_Items(json, raw) {
			if Json_Kind(json, r) != .Object {
				append(&out, LDtkJNull{})
				continue
			}
			param := Json_At(json, Json_Get(json, r, "params"), 0)
			// The value as it reads (clamped: getInt / getFloat), from `__value`
			shown := info.isArray ? Json_At(json, values, i) : values
			switch conv.id {
			case "IntToFloat":
				append(&out, wrapperJV("V_Float", jvNumber(Json_Float(json, shown))))
				changed = true
			case "BoolToInt":
				append(&out, wrapperJV("V_Int", i64(Json_Bool(json, shown) ? 1 : 0)))
				changed = true
			case "FloatToIntTruncate":
				append(&out, wrapperJV("V_Int", i64(math.trunc(Json_Float(json, shown)))))
				changed = true
			case "FloatToIntRound":
				append(&out, wrapperJV("V_Int", i64(ldtkRound(Json_Float(json, shown)))))
				changed = true
			case "TextToString":
				// Line breaks become spaces (parsed while still a Multilines field: not trimmed)
				s := ldtkUnescape(Json_String(json, param))
				s, _ = strings.replace_all(s, "\n", " ", context.temp_allocator)
				append(&out, s == "" ? LDtkJV(LDtkJNull{}) : wrapperJV("V_String", s))
				changed = true
			case:
				append(&out, ldtkJV(json, r))
			}
		}
		if changed do LDtkPatches_Set(&p, doc, fi.file, raw, writeAt(json, raw, LDtkJArray(out[:]), Json_Minified(json)))
	}
	// The definition (convertDef, then the type)
	over := Json_Get(main, node, "defaultOverride")
	param := Json_At(main, Json_Get(main, over, "params"), 0)
	switch conv.id {
	case "BoolToInt":
		b := Json_Kind(main, param) == .True
		defWrite(&p, doc, node, "defaultOverride", wrapperJV("V_Int", i64(b ? 1 : 0)))
	case "FloatToIntTruncate", "FloatToIntRound":
		round :: proc(v: f64, truncate: bool) -> f64 { return truncate ? math.trunc(v) : ldtkRound(v) }
		truncate := conv.id == "FloatToIntTruncate"
		if lo, ok := info.min.?; ok do defWrite(&p, doc, node, "min", jvNumber(round(lo, truncate)))
		if hi, ok := info.max.?; ok do defWrite(&p, doc, node, "max", jvNumber(round(hi, truncate)))
		d := Json_Float(main, param)
		if Json_Kind(main, param) != .Number do d = 0
		defWrite(&p, doc, node, "defaultOverride", wrapperJV("V_Int", i64(round(d, truncate))))
	case "TextToString":
		if Json_Kind(main, param) == .String {
			s, _ := strings.replace_all(Json_String(main, param), "\n", " ", context.temp_allocator)
			defWrite(&p, doc, node, "defaultOverride", wrapperJV("V_String", s))
		}
	}
	defWrite(&p, doc, node, "type", fieldKindText(conv.to))
	if conv.to != .Text do defWrite(&p, doc, node, "textLanguageMode", LDtkJNull{})
	if conv.to != .Path do defWrite(&p, doc, node, "acceptFileTypes", LDtkJNull{})
	return stagesApply(op.s, &p)
}
