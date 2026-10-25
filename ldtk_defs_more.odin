package crossfire_editor

import "core:crypto/legacy/md5"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

/*
The definitions editors' edits of IntGrid values and groups (EditLayerDefs), enum values and
external enums (EditEnumDefs, importer/ExternalEnum.hx and its enu/ parsers: text files, JSON,
Haxe source, CastleDB), and tilesets (EditTilesetDefs, TilesetDef: images, grids and the tile ids
remapped after them, pixel data, LDtk's internal icons, tiles' enum tags and custom data:
ui/ts/TileTagger.hx), as LDtk makes them (see ldtk_defs.odin).
*/

// --- IntGrid values and groups ---------------------------------------------------------------

// An IntGrid layer's value node by value (-1 none)
@(private)
intGridValueNode :: proc(main: ^JsonDoc, layer, value: int) -> int {
	for v in Json_Items(main, Json_Get(main, layer, "intGridValues")) do if Json_Int(main, Json_Get(main, v, "value"), -1) == value do return v
	return -1
}

// An IntGrid layer's group node by uid (-1 none)
@(private)
intGridGroupNode :: proc(main: ^JsonDoc, layer, uid: int) -> int {
	for g in Json_Items(main, Json_Get(main, layer, "intGridValuesGroups")) do if Json_Int(main, Json_Get(main, g, "uid"), -1) == uid do return g
	return -1
}

@(private)
intGridEdit :: proc(op: ^DefOp) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	layer := LDtkDoc_DefByUid(doc, "layers", edit.def)
	if layer < 0 do return "no such layer"
	if Json_String(main, Json_Get(main, layer, "type")) != "IntGrid" do return "only an IntGrid layer has values"
	values := Json_Get(main, layer, "intGridValues")
	groups := Json_Get(main, layer, "intGridValuesGroups")
	minified := Json_Minified(main)
	p := LDtkPatches{}
	#partial switch edit.op {
	case .IntGrid_Value_Added:
		// LayerDef.addIntGridValue: the next value, a nice color, in the group asked
		next := 1
		colors := make([dynamic]int, context.temp_allocator)
		for v in Json_Items(main, values) {
			next = max(next, Json_Int(main, Json_Get(main, v, "value")))
			c, _ := LDtk_ParseColor(Json_String(main, Json_Get(main, v, "color")))
			append(&colors, c)
		}
		if Json_Count(main, values) > 0 do next += 1
		group := edit.index
		if group != 0 && intGridGroupNode(main, layer, group) < 0 do return "no such group"
		item := jobject(jpair("value", i64(next)), jpair("identifier", LDtkJNull{}), jpair("color", LDtk_FormatColor(LDtk_SuggestColor(colors[:]))),
			jpair("tile", LDtkJNull{}), jpair("groupUid", i64(group)))
		appendItem(&p, doc, 0, values, item, minified)
	case .IntGrid_Value_Removed:
		node := intGridValueNode(main, layer, edit.index)
		if node < 0 do return "no such value"
		LDtkPatches_Add(&p, 0, Json_RemovePatch(main, node))
		// Its cells become empty in every level (LayerInstance.tidy) and the rules run again
		op.scope.intGrid = true
		op.rerun[edit.def] = true
	case .IntGrid_Value_Moved:
		// Into the group `number` at `number2` of its values (LayerDef.sortIntGridValueDef's result)
		node := intGridValueNode(main, layer, edit.index)
		if node < 0 do return "no such value"
		to := int(math.round(edit.number))
		if to != 0 && intGridGroupNode(main, layer, to) < 0 do return "no such group"
		// The other values, in order, and which of them are in the target group
		texts := make([dynamic]string, context.temp_allocator)
		inGroup := make([dynamic]int, context.temp_allocator)
		for v in Json_Items(main, values) {
			if v == node do continue
			if Json_Int(main, Json_Get(main, v, "groupUid")) == to do append(&inGroup, len(texts))
			append(&texts, strings.clone(Json_Text(main, v), context.temp_allocator))
		}
		// The moved value with its new group
		obj := ldtkJV(main, node).(LDtkJObject)
		for &pair in obj do if pair.key == "groupUid" do pair.value = i64(to)
		moved := LDtk_PrettyJson(obj, minified, LDtk_IndentAt(main.text, int(main.nodes[node].start)))
		// Where it goes: before the group's `number2`-th value, else after its last
		position := int(math.round(edit.number2))
		at := len(texts)
		if len(inGroup) > 0 {
			if position < len(inGroup) do at = inGroup[max(position, 0)]
			else do at = inGroup[len(inGroup) - 1] + 1
		}
		inject_at(&texts, at, moved)
		ldtkRebuildItems(&p, doc, 0, values, texts[:])
	case .IntGrid_Value_Tile:
		set :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, node: int, v: LDtkJV) { defWrite(p, doc, node, "tile", v) }
		if edit.index == -1 {
			// The icons' tileset changed: every value's tile goes (EditLayerDefs)
			for v in Json_Items(main, values) do set(&p, doc, v, LDtkJNull{})
			break
		}
		node := intGridValueNode(main, layer, edit.index)
		if node < 0 do return "no such value"
		t := strings.trim_space(edit.text)
		if t == "" {
			set(&p, doc, node, LDtkJNull{})
			break
		}
		r, ok := LDtk_ParseRect(t)
		ts := int(math.round(edit.number))
		if !ok || !isDef(doc, "tilesets", ts) do return "pick a tile of a tileset"
		set(&p, doc, node, rectJV(ts, r))
	case .IntGrid_Group_Added:
		// LayerDef.addIntGridGroup: the next uid from 1
		uid := 1
		for g in Json_Items(main, groups) do uid = max(uid, Json_Int(main, Json_Get(main, g, "uid")) + 1)
		appendItem(&p, doc, 0, groups, jobject(jpair("uid", i64(uid)), jpair("identifier", LDtkJNull{}), jpair("color", LDtkJNull{})), minified)
	case .IntGrid_Group_Removed:
		node := intGridGroupNode(main, layer, edit.index)
		if node < 0 do return "no such group"
		// Its values go back to no group (EditLayerDefs' delete group)
		for v in Json_Items(main, values) do if Json_Int(main, Json_Get(main, v, "groupUid")) == edit.index do defWrite(&p, doc, v, "groupUid", i64(0))
		LDtkPatches_Add(&p, 0, Json_RemovePatch(main, node))
	case .IntGrid_Group_Set:
		node := intGridGroupNode(main, layer, edit.index)
		if node < 0 do return "no such group"
		t := strings.trim_space(edit.text)
		switch edit.key {
		case "identifier":
			if t == "" {
				defWrite(&p, doc, node, "identifier", LDtkJNull{})
				break
			}
			id, ok := LDtk_CleanIdentifier(t, "Free")
			if !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text)
			defWrite(&p, doc, node, "identifier", id)
		case "color":
			if t == "" {
				defWrite(&p, doc, node, "color", LDtkJNull{})
				break
			}
			c, ok := LDtk_ParseColor(t)
			if !ok do return fmt.tprintf("%q isn't a color (#RRGGBB)", edit.text)
			// Groups' colors are written as CSS writes them (Col.toHex: lower case)
			defWrite(&p, doc, node, "color", strings.to_lower(LDtk_FormatColor(c), context.temp_allocator))
		case: return fmt.tprintf("a group has no %q", edit.key)
		}
	case .IntGrid_Group_Moved:
		node := intGridGroupNode(main, layer, edit.index)
		if node < 0 do return "no such group"
		return moveItem(op, node, int(math.round(edit.number)))
	}
	return stagesApply(op.s, &p)
}

// An array of small items rebuilt from texts (written as LDtk writes it: its pretty writer)
@(private)
ldtkRebuildItems :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, file, array: int, texts: []string) {
	json := LDtkDoc_Json(doc, file)
	items := make([dynamic]LDtkJV, context.temp_allocator)
	for t in texts do append(&items, textJV(t))
	LDtkPatches_Set(p, doc, file, array, writeAt(json, array, LDtkJArray(items[:]), Json_Minified(json)))
}

// An array item moved by places (the items between shift by one)
@(private)
moveItem :: proc(op: ^DefOp, node, steps: int) -> string {
	main := LDtkDoc_Main(op.s.cur)
	parent := int(main.nodes[node].parent)
	items := Json_Items(main, parent)
	at, _ := slice.linear_search(items, node)
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

// --- Enum values -----------------------------------------------------------------------------

@(private)
enumValueEdit :: proc(op: ^DefOp) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	def := LDtkDefs_Node(doc, .Enum, edit.def)
	if def < 0 do return "no such enum"
	external := Json_Kind(main, Json_Get(main, def, "externalRelPath")) == .String
	value := Json_At(main, Json_Get(main, def, "values"), edit.index)
	if value < 0 do return "no such value"
	p := LDtkPatches{}
	#partial switch edit.op {
	case .Enum_Value_Removed:
		if external do return "this enum comes from an external file: edit that file"
		// Fields set to it lose it, so do defaults, tiles' tags and biomes (tidy)
		LDtkPatches_Add(&p, 0, Json_RemovePatch(main, value))
	case .Enum_Value_Moved:
		if external do return "this enum's values are in its file's order"
		return moveItem(op, value, int(math.round(edit.number)))
	case .Enum_Value_Tile:
		// EnumDef.setValueTile: only with an icons tileset (not CastleDB's own)
		if external && strings.has_suffix(strings.to_lower(Json_String(main, Json_Get(main, def, "externalRelPath")), context.temp_allocator), ".cdb") do return "CastleDB's icons are its own"
		icons := nodeUid(main, Json_Get(main, def, "iconTilesetUid"))
		if icons < 0 do return "pick the enum's icons tileset first"
		t := strings.trim_space(edit.text)
		if t == "" {
			defWrite(&p, doc, value, "tileRect", LDtkJNull{})
			break
		}
		r, ok := LDtk_ParseRect(t)
		if !ok do return fmt.tprintf("%q isn't a tile rectangle (x,y,w,h)", edit.text)
		defWrite(&p, doc, value, "tileRect", rectJV(icons, r))
	}
	return stagesApply(op.s, &p)
}

// --- External enums ------------------------------------------------------------------------

// An enum read from an external file (EditorTypes.ParsedExternalEnum)
LDtkParsedEnum :: struct {
	id: string,
	values: [dynamic]LDtkParsedValue,
	// CastleDB's icons: the tileset's image (relative to the .ldtk file, "" none)
	iconImage: string,
}

// One of its values: its id, and CastleDB's color and icon
LDtkParsedValue :: struct {
	id: string,
	color: Maybe(int),
	tile: Maybe([4]int),
}

/*
Values from one string (ExternalEnum.parseValuesFromString): split on the first of ",", ";" or
" " it has, each trimmed, empty ones dropped.
*/
@(private)
parseValueList :: proc(raw: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	t := strings.trim_space(raw)
	if t == "" do return out[:]
	sep := ""
	for s in ([]string{",", ";", " "}) do if strings.contains(t, s) {
		sep = s
		break
	}
	if sep == "" do return out[:]
	for part in strings.split(t, sep, context.temp_allocator) {
		v := strings.trim_space(part)
		if v != "" do append(&out, v)
	}
	return out[:]
}

/*
The enums of an external file by its kind (LDtk's importer.enu: TextFileEnum, JsonEnum, HxEnum,
CastleDb).

Inputs:
- ext: Its extension, lower case ("txt", "json", "hx", "cdb")
- text: Its contents
- folder: The file's folder relative to the .ldtk file (CastleDB's icon images)

Returns:
- The enums (temp allocated), and why when the file isn't one of them
*/
LDtk_ParseExternalEnums :: proc(ext, text, folder: string) -> ([]LDtkParsedEnum, string) {
	out := make([dynamic]LDtkParsedEnum, context.temp_allocator)
	add :: proc(out: ^[dynamic]LDtkParsedEnum, id: string, values: []string) {
		e := LDtkParsedEnum{id = strings.clone(id, context.temp_allocator), values = make([dynamic]LDtkParsedValue, context.temp_allocator)}
		for v in values do append(&e.values, LDtkParsedValue{id = strings.clone(v, context.temp_allocator)})
		append(out, e)
	}
	switch ext {
	case "txt":
		// One enum a line: "MyEnum : a, b, c"
		for line in strings.split_lines(text, context.temp_allocator) {
			if !strings.contains(line, ":") do continue
			id, _, rest := strings.partition(line, ":")
			add(&out, strings.trim_space(id), parseValueList(rest))
		}
	case "json":
		// { "MyEnum1": "a,b,c", "MyEnum2": ["a", "b"] }
		doc, problem := Json_Parse(text, context.temp_allocator)
		if problem != "" do return nil, fmt.tprintf("not JSON: %s", problem)
		for member in Json_Items(&doc, 0) {
			key := Json_Key(&doc, member)
			#partial switch Json_Kind(&doc, member) {
			case .String: add(&out, key, parseValueList(Json_String(&doc, member)))
			case .Array:
				items := Json_Items(&doc, member)
				if len(items) == 0 || Json_Kind(&doc, items[0]) != .String do continue
				values := make([dynamic]string, context.temp_allocator)
				for item in items do append(&values, Json_String(&doc, item))
				add(&out, key, values[:])
			}
		}
	case "hx":
		parsed := parseHaxeEnums(text)
		if len(parsed) == 0 do return nil, "Couldn't find any simple Enum in this source file."
		append(&out, ..parsed)
	case "cdb":
		parsed, problem := parseCastleDb(text, folder)
		if problem != "" do return nil, problem
		append(&out, ..parsed)
	case:
		return nil, fmt.tprintf("Unsupported extension %q for imported enum file.", ext)
	}
	return out[:], ""
}

/*
Haxe source's simple enums (HxEnum): comments removed, every `enum Name {` block whose values have
no parameters, each value a capitalized name followed by ";".
*/
@(private="file")
parseHaxeEnums :: proc(source: string) -> []LDtkParsedEnum {
	// Comments: line comments, then blocks
	b := strings.builder_make(context.temp_allocator)
	for line in strings.split_lines(source, context.temp_allocator) {
		cut := line
		if i := strings.index(line, "//"); i >= 0 {
			// ^([^/\n]*)(//.*)$: only when no "/" comes before it
			if !strings.contains(line[:i], "/") do cut = line[:i]
		}
		strings.write_string(&b, cut)
		strings.write_byte(&b, '\n')
	}
	text := strings.to_string(b)
	for {
		start := strings.index(text, "/*")
		if start < 0 do break
		end := strings.index(text[start + 2:], "*/")
		if end < 0 do break
		text = fmt.tprintf("%s%s", text[:start], text[start + 2 + end + 2:])
	}
	out := make([dynamic]LDtkParsedEnum, context.temp_allocator)
	isWord :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' }
	lines := strings.split_lines(text, context.temp_allocator)
	offset := 0
	for line in lines {
		lineStart := offset
		offset += len(line) + 1
		// ^\s*enum\s+([a-z0-9_]+)\s*{ (case-insensitive)
		t := strings.trim_left_space(line)
		if len(t) < 5 || strings.to_lower(t[:4], context.temp_allocator) != "enum" || (t[4] != ' ' && t[4] != '\t') do continue
		rest := strings.trim_left_space(t[4:])
		n := 0
		for n < len(rest) && isWord(rest[n]) do n += 1
		if n == 0 do continue
		id := rest[:n]
		after := strings.trim_left_space(rest[n:])
		if !strings.has_prefix(after, "{") do continue
		// The block, brackets counted
		bodyStart := lineStart + (len(line) - len(after)) + 1
		depth, pos := 1, bodyStart
		for pos < len(text) && depth >= 1 {
			if text[pos] == '{' do depth += 1
			else if text[pos] == '}' do depth -= 1
			pos += 1
		}
		body := text[bodyStart:max(pos - 1, bodyStart)]
		// Values with parameters: not a simple enum
		parametered := false
		values := make([dynamic]string, context.temp_allocator)
		i := 0
		for i < len(body) {
			if body[i] >= 'A' && body[i] <= 'Z' && (i == 0 || !isWord(body[i - 1])) {
				j := i
				for j < len(body) && isWord(body[j]) do j += 1
				k := j
				for k < len(body) && (body[k] == ' ' || body[k] == '\t') do k += 1
				if k < len(body) && body[k] == '(' do parametered = true
				if k < len(body) && body[k] == ';' do append(&values, body[i:j])
				i = j
				continue
			}
			i += 1
		}
		if !parametered && len(values) > 0 {
			e := LDtkParsedEnum{id = strings.clone(id, context.temp_allocator), values = make([dynamic]LDtkParsedValue, context.temp_allocator)}
			for v in values do append(&e.values, LDtkParsedValue{id = strings.clone(v, context.temp_allocator)})
			append(&out, e)
		}
	}
	return out[:]
}

/*
CastleDB's sheets with a unique identifier column (CastleDb: column type "0"), their lines' ids, a
color column's colors (type "11"), the display icon's tiles.
*/
@(private="file")
parseCastleDb :: proc(text, folder: string) -> ([]LDtkParsedEnum, string) {
	doc, problem := Json_Parse(text, context.temp_allocator)
	if problem != "" do return nil, fmt.tprintf("not a CastleDB file: %s", problem)
	out := make([dynamic]LDtkParsedEnum, context.temp_allocator)
	for sheet in Json_Items(&doc, Json_Get(&doc, 0, "sheets")) {
		idColumn, colorColumn, tileColumn := "", "", ""
		icon := Json_String(&doc, Json_Get(&doc, Json_Get(&doc, sheet, "props"), "displayIcon"))
		for col in Json_Items(&doc, Json_Get(&doc, sheet, "columns")) {
			name := Json_String(&doc, Json_Get(&doc, col, "name"))
			switch Json_String(&doc, Json_Get(&doc, col, "typeStr")) {
			case "0": idColumn = name
			case "11": if colorColumn == "" do colorColumn = name
			}
			if icon != "" && icon == name do tileColumn = name
		}
		if idColumn == "" do continue
		e := LDtkParsedEnum{id = strings.clone(Json_String(&doc, Json_Get(&doc, sheet, "name")), context.temp_allocator), values = make([dynamic]LDtkParsedValue, context.temp_allocator)}
		seen := make(map[string]bool, context.temp_allocator)
		for line in Json_Items(&doc, Json_Get(&doc, sheet, "lines")) {
			id := strings.trim_space(Json_String(&doc, Json_Get(&doc, line, idColumn)))
			if id == "" || id in seen do continue
			seen[id] = true
			v := LDtkParsedValue{id = strings.clone(id, context.temp_allocator)}
			if colorColumn != "" do if c, ok := Json_Number(&doc, Json_Get(&doc, line, colorColumn)); ok do v.color = int(c)
			if tileColumn != "" {
				t := Json_Get(&doc, line, tileColumn)
				if file := Json_String(&doc, Json_Get(&doc, t, "file")); file != "" {
					if e.iconImage == "" do e.iconImage = strings.clone(joinForward(folder, file), context.temp_allocator)
					size := Json_Int(&doc, Json_Get(&doc, t, "size"), 16)
					w, h := Json_Int(&doc, Json_Get(&doc, t, "width"), 1), Json_Int(&doc, Json_Get(&doc, t, "height"), 1)
					v.tile = [4]int{Json_Int(&doc, Json_Get(&doc, t, "x")) * size, Json_Int(&doc, Json_Get(&doc, t, "y")) * size, size * w, size * h}
				}
			}
			append(&e.values, v)
		}
		append(&out, e)
	}
	return out[:], ""
}

// A path joined with "/" (LDtk's paths)
@(private)
joinForward :: proc(a, b: string) -> string {
	if a == "" || a == "." do return b
	return fmt.tprintf("%s/%s", strings.trim_right(a, "/"), b)
}

// A file's MD5 as LDtk keeps external enums' checksums (haxe.crypto.Md5.encode: lower-case hex)
LDtk_Checksum :: proc(text: string) -> string {
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, transmute([]byte)text)
	digest: [md5.DIGEST_SIZE]byte
	md5.final(&ctx, digest[:])
	b := strings.builder_make(context.temp_allocator)
	for d in digest do fmt.sbprintf(&b, "%02x", d)
	return strings.to_string(b)
}

/*
A path relative to the .ldtk file's folder, with "/" (LDtk's relative paths: Project.makeRelativeFilePath).

Inputs:
- folder: The .ldtk file's folder
- path: The file, absolute or relative to the working folder
*/
LDtk_RelativePath :: proc(folder, path: string) -> (string, bool) {
	rel, err := filepath.rel(absolutePath(folder), absolutePath(path), context.temp_allocator)
	if err != nil do return "", false
	out, _ := strings.replace_all(rel, "\\", "/", context.temp_allocator)
	return out, true
}

// What a sync of an external file would do: values and enums added and removed, and which of
// those removed something uses (ExternalEnum.importToProject's diff)
LDtkEnumSync :: struct {
	added, removed, removedUsed: int,
	problem: string,
}

/*
What syncing an external enum file would change (for the tab to say before it's done).

Inputs:
- relPath: The file, relative to the .ldtk file (an `externalRelPath`)
*/
LDtkEnums_SyncPreview :: proc(doc: ^LDtkDoc, relPath: string) -> LDtkEnumSync {
	parsed, _, problem := readExternal(doc, relPath)
	if problem != "" do return {problem = problem}
	main := LDtkDoc_Main(doc)
	out := LDtkEnumSync{}
	style := defStyle(doc)
	used := ldtkUsedEnumValues(doc)
	for d in Json_Items(main, LDtkDoc_Defs(doc, "externalEnums")) {
		if Json_String(main, Json_Get(main, d, "externalRelPath")) != relPath do continue
		id := Json_String(main, Json_Get(main, d, "identifier"))
		uid := Json_Int(main, Json_Get(main, d, "uid"))
		pe: ^LDtkParsedEnum
		for &e in parsed do if e.id == id do pe = &e
		for v in Json_Items(main, Json_Get(main, d, "values")) {
			vid := Json_String(main, Json_Get(main, v, "id"))
			found := false
			if pe != nil do for pv in pe.values do if pv.id == vid do found = true
			if !found {
				out.removed += 1
				if fmt.tprintf("%d.%s", uid, vid) in used do out.removedUsed += 1
			}
		}
	}
	for e in parsed {
		d := -1
		for x in Json_Items(main, LDtkDoc_Defs(doc, "externalEnums")) do if Json_String(main, Json_Get(main, x, "identifier")) == e.id do d = x
		for v in e.values {
			found := false
			if d >= 0 do for x in Json_Items(main, Json_Get(main, d, "values")) do if Json_String(main, Json_Get(main, x, "id")) == v.id do found = true
			if !found do out.added += 1
		}
	}
	_ = style
	return out
}

// Every enum value fields use, as "<enum uid>.<value>" (temp)
@(private)
ldtkUsedEnumValues :: proc(doc: ^LDtkDoc) -> map[string]bool {
	out := make(map[string]bool, context.temp_allocator)
	enumOf := make(map[int]int, context.temp_allocator)
	main := LDtkDoc_Main(doc)
	for e in Json_Items(main, LDtkDoc_Defs(doc, "entities")) do for f in Json_Items(main, Json_Get(main, e, "fieldDefs")) {
		info := LDtkDoc_FieldInfo(doc, f)
		if info.type == .Enum do enumOf[info.uid] = info.enumUid
	}
	for f in Json_Items(main, LDtkDoc_Defs(doc, "levelFields")) {
		info := LDtkDoc_FieldInfo(doc, f)
		if info.type == .Enum do enumOf[info.uid] = info.enumUid
	}
	for fi in ldtkAllFieldInstances(doc) {
		json := LDtkDoc_Json(doc, fi.file)
		enumUid, isEnum := enumOf[Json_Int(json, Json_Get(json, fi.node, "defUid"), -1)]
		if !isEnum do continue
		v := Json_Get(json, fi.node, "__value")
		items := Json_Kind(json, v) == .Array ? Json_Items(json, v) : []int{v}
		for item in items do if Json_Kind(json, item) == .String do out[fmt.tprintf("%d.%s", enumUid, Json_String(json, item))] = true
	}
	return out
}

// An external file's enums, cleaned up as LDtk cleans them (ExternalEnum.load), and its checksum
@(private)
readExternal :: proc(doc: ^LDtkDoc, relPath: string) -> (parsed: []LDtkParsedEnum, checksum, problem: string) {
	full := joinPath(LDtkDoc_Folder(doc), relPath, allocator = context.temp_allocator)
	data, err := os.read_entire_file(full, context.temp_allocator)
	if err != nil do return nil, "", fmt.tprintf("File not found: %s", relPath)
	if len(data) == 0 do return nil, "", fmt.tprintf("This file is empty: %s", relPath)
	text := string(data)
	ext := strings.to_lower(strings.trim_prefix(filepath.ext(relPath), "."), context.temp_allocator)
	folder := filepath.dir(relPath)
	if folder == "." do folder = ""
	list, why := LDtk_ParseExternalEnums(ext, text, folder)
	if why != "" do return nil, "", why
	style := defStyle(doc)
	out := make([dynamic]LDtkParsedEnum, context.temp_allocator)
	for &e in list {
		id, ok := LDtk_CleanIdentifier(e.id, style)
		if !ok do continue
		e.id = id
		existing := make(map[string]bool, context.temp_allocator)
		for &v in e.values {
			v.id = ldtkUniqueId(v.id, style, existing)
			existing[v.id] = true
		}
		append(&out, e)
	}
	return out[:], LDtk_Checksum(text), ""
}

/*
External enums (ExternalEnum.importToProject): a file imported (its enums made, external), synced
again (values and enums added and removed, the file's order kept, CastleDB's colors and icons
copied, the checksum written), its enums removed.
*/
@(private)
externalEnumEdit :: proc(op: ^DefOp) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	minified := Json_Minified(main)
	style := defStyle(doc)
	list := LDtkDoc_Defs(doc, "externalEnums")
	relPath := strings.trim_space(edit.text)
	if edit.op == .Enum_Import {
		// A path from the project folder, or one relative to the .ldtk file
		full := joinPath(op.root, relPath, allocator = context.temp_allocator)
		if !os.exists(full) do full = joinPath(LDtkDoc_Folder(doc), relPath, allocator = context.temp_allocator)
		rel, ok := LDtk_RelativePath(LDtkDoc_Folder(doc), full)
		if !ok do return fmt.tprintf("%s can't be reached from the LDtk file", relPath)
		relPath = rel
	}
	p := LDtkPatches{}
	if edit.op == .Enum_External_Removed {
		any := false
		for d in Json_Items(main, list) do if Json_String(main, Json_Get(main, d, "externalRelPath")) == relPath {
			LDtkPatches_Add(&p, 0, Json_RemovePatch(main, d))
			any = true
		}
		if !any do return fmt.tprintf("no enum comes from %s", relPath)
		// Removals of several items of one array: rebuilt instead (the patches would touch)
		if p.files != nil && len(p.files[0]) > 1 {
			p = {}
			kept := make([dynamic]string, context.temp_allocator)
			for d in Json_Items(main, list) do if Json_String(main, Json_Get(main, d, "externalRelPath")) != relPath do append(&kept, strings.clone(Json_Text(main, d), context.temp_allocator))
			ldtkRebuildItems(&p, doc, 0, list, kept[:])
		}
		return stagesApply(op.s, &p)
	}
	parsed, checksum, problem := readExternal(doc, relPath)
	if problem != "" do return problem
	if len(parsed) == 0 do return "the file has no enums"
	// An enum of the file named like one of the project's (not from this file) stops it
	for e in parsed {
		for d in Json_Items(main, LDtkDoc_Defs(doc, "enums")) do if Json_String(main, Json_Get(main, d, "identifier")) == e.id do return fmt.tprintf("Import failed: the file contains the Enum %q which is already used in this project.", e.id)
		for d in Json_Items(main, list) do if Json_String(main, Json_Get(main, d, "identifier")) == e.id && Json_String(main, Json_Get(main, d, "externalRelPath")) != relPath do return fmt.tprintf("Import failed: the file contains the Enum %q which is already used in this project.", e.id)
	}
	cdb := strings.has_suffix(strings.to_lower(relPath, context.temp_allocator), ".cdb")
	uids := uidsMake(doc)
	// The enums of the file as they'll be: the existing ones' values kept where the file still
	// has them (colors and icons), new ones added, the file's order
	byId := make(map[string]int, context.temp_allocator)
	for d in Json_Items(main, list) do if Json_String(main, Json_Get(main, d, "externalRelPath")) == relPath do byId[strings.clone(Json_String(main, Json_Get(main, d, "identifier")), context.temp_allocator)] = d
	// CastleDB icons: their tileset (an existing one with the image, else a new one)
	iconTileset := make(map[string]int, context.temp_allocator)
	newTilesets := make([dynamic]LDtkJV, context.temp_allocator)
	if cdb do for e in parsed {
		if e.iconImage == "" || e.iconImage in iconTileset do continue
		found := -1
		for td in Json_Items(main, LDtkDoc_Defs(doc, "tilesets")) do if Json_String(main, Json_Get(main, td, "relPath")) == e.iconImage do found = Json_Int(main, Json_Get(main, td, "uid"))
		if found < 0 {
			found = uidTake(&uids)
			ts, why := newTilesetJV(op, found, e.iconImage)
			if why != "" do return why
			obj := ts.(LDtkJObject)
			for &pair in obj {
				if pair.key == "identifier" do pair.value = ldtkUniqueId(fmt.tprintf("%s_%s", filepath.base(relPath), filepath.base(e.iconImage)), style, defIdentifiers(main, LDtkDoc_Defs(doc, "tilesets")))
				if pair.key == "tags" do pair.value = jarray("CastleDB")
			}
			append(&newTilesets, ts)
		}
		iconTileset[e.iconImage] = found
	}
	result := make([dynamic]string, context.temp_allocator)
	for e in parsed {
		existing, has := byId[e.id]
		item: LDtkJObject
		if has {
			item = ldtkJV(main, existing).(LDtkJObject)
		} else {
			// createEnumDef(relSourcePath)
			item = newEnumJV(uidTake(&uids), e.id, relPath, checksum).(LDtkJObject)
		}
		oldValues := make(map[string]LDtkJV, context.temp_allocator)
		colors := make([dynamic]int, context.temp_allocator)
		if has do for v in Json_Items(main, Json_Get(main, existing, "values")) {
			oldValues[strings.clone(Json_String(main, Json_Get(main, v, "id")), context.temp_allocator)] = ldtkJV(main, v)
			append(&colors, Json_Int(main, Json_Get(main, v, "color")))
		}
		values := make([dynamic]LDtkJV, context.temp_allocator)
		icons := -1
		if e.iconImage != "" do icons = iconTileset[e.iconImage]
		for pv in e.values {
			v, kept := oldValues[pv.id]
			if !kept {
				// EnumDef.addValue: a nice color apart from the others
				c := LDtk_SuggestColor(colors[:])
				append(&colors, c)
				v = jobject(jpair("id", pv.id), jpair("tileRect", LDtkJNull{}), jpair("color", i64(c)))
			}
			// CastleDB's colors and icons (copyParsedValuesData)
			if cdb {
				vo := v.(LDtkJObject)
				for &pair in vo {
					if pair.key == "color" do if c, ok := pv.color.?; ok do pair.value = i64(c)
					if pair.key == "tileRect" {
						if r, ok := pv.tile.?; ok && icons >= 0 do pair.value = rectJV(icons, r)
						else do pair.value = LDtkJNull{}
					}
				}
			}
			append(&values, v)
		}
		for &pair in item {
			switch pair.key {
			case "values": pair.value = LDtkJArray(values[:])
			case "externalFileChecksum": pair.value = checksum
			case "iconTilesetUid": if cdb do pair.value = jvUid(icons)
			}
		}
		indent := LDtk_IndentAt(main.text, int(main.nodes[list].start)) + 1
		append(&result, LDtk_PrettyJson(item, minified, indent))
	}
	// The other files' enums stay where they are; this file's take its place (new files: the end)
	texts := make([dynamic]string, context.temp_allocator)
	placed := false
	for d in Json_Items(main, list) {
		if Json_String(main, Json_Get(main, d, "externalRelPath")) == relPath {
			if !placed do append(&texts, ..result[:])
			placed = true
			continue
		}
		append(&texts, strings.clone(Json_Text(main, d), context.temp_allocator))
	}
	if !placed do append(&texts, ..result[:])
	ldtkRebuildItems(&p, doc, 0, list, texts[:])
	for ts in newTilesets do appendItem(&p, doc, 0, LDtkDoc_Defs(doc, "tilesets"), ts, minified)
	uidsDone(&p, doc, uids)
	return stagesApply(op.s, &p)
}

// --- Tilesets -------------------------------------------------------------------------------

// LDtk's internal icons (Lang.getEmbedAtlasInfos, Project.getOrLoadEmbedImage): the image's size
LDTK_ICONS_SIZE :: [2]int{512, 1024}

// An image's size (false when it can't be read; Aseprite files too, as LDtk reads them)
@(private)
imageSize :: proc(path: string) -> ([2]int, bool) {
	return Image_Size(path)
}

/*
A new tileset as LDtk writes one (Definitions.createTilesetDef, then importAtlasImage and
autoRenameTilesetIdentifier; getEmbedTileset for LDtk's icons).

Inputs:
- image: Its image relative to the .ldtk file, "LdtkIcons" (LDtk's internal icons), or "" none
*/
@(private)
newTilesetJV :: proc(op: ^DefOp, uid: int, image: string) -> (LDtkJV, string) {
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	style := defStyle(doc)
	taken := defIdentifiers(main, LDtkDoc_Defs(doc, "tilesets"))
	id := ldtkUniqueId("Tileset", style, taken)
	relPath := LDtkJV(LDtkJNull{})
	embed := LDtkJV(LDtkJNull{})
	size := [2]int{}
	grid := 16
	pixels := LDtkJV(LDtkJNull{})
	switch image {
	case "":
	case "LdtkIcons":
		for td in Json_Items(main, LDtkDoc_Defs(doc, "tilesets")) do if Json_String(main, Json_Get(main, td, "embedAtlas")) == "LdtkIcons" do return nil, "the project has LDtk's internal icons already"
		clean, _ := LDtk_CleanIdentifier("Internal_Icons", style)
		id = ldtkUniqueId(clean, style, taken)
		embed = "LdtkIcons"
		size = LDTK_ICONS_SIZE
		// The pixel data from the image when the project has a copy (LDTK_ICONS_FILE in the engine)
		icons := joinPath(LDtkDoc_Folder(doc), "finalbossblues-icons_full_16.png", allocator = context.temp_allocator)
		if opaque, avg, ok := LDtk_PixelData(icons, size, grid, 0, 0); ok do pixels = jobject(jpair("opaqueTiles", opaque), jpair("averageColors", avg))
	case:
		full := joinPath(LDtkDoc_Folder(doc), image, allocator = context.temp_allocator)
		s, ok := imageSize(full)
		if !ok do return nil, fmt.tprintf("%s isn't an image the editor can read", image)
		size = s
		path, _ := strings.replace_all(image, "\\", "/", context.temp_allocator)
		relPath = path
		grid = min(grid, max(min(size.x, size.y), 2))
		// autoRenameTilesetIdentifier: named after its file
		if base, valid := LDtk_CleanIdentifier(strings.trim_suffix(filepath.base(path), filepath.ext(path)), style); valid do id = ldtkUniqueId(base, style, taken)
		if opaque, avg, read := LDtk_PixelData(full, size, grid, 0, 0); read do pixels = jobject(jpair("opaqueTiles", opaque), jpair("averageColors", avg))
	}
	has := image != ""
	step := f64(grid)
	cWid := has ? int(math.ceil(f64(size.x) / step)) : 0
	cHei := has ? int(math.ceil(f64(size.y) / step)) : 0
	return jobject(
		jpair("__cWid", i64(cWid)),
		jpair("__cHei", i64(cHei)),
		jpair("identifier", id),
		jpair("uid", i64(uid)),
		jpair("relPath", relPath),
		jpair("embedAtlas", embed),
		jpair("pxWid", i64(size.x)),
		jpair("pxHei", i64(size.y)),
		jpair("tileGridSize", i64(grid)),
		jpair("spacing", i64(0)),
		jpair("padding", i64(0)),
		jpair("tags", LDtkJArray{}),
		jpair("tagsSourceEnumUid", LDtkJNull{}),
		jpair("enumTags", LDtkJArray{}),
		jpair("customData", LDtkJArray{}),
		jpair("savedSelections", LDtkJArray{}),
		jpair("cachedPixelData", pixels),
	), ""
}

// LDtk's internal icons' tileset, made when the project has none (Definitions.getEmbedTileset)
@(private)
embedTileset :: proc(op: ^DefOp) -> (int, string) {
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	for td in Json_Items(main, LDtkDoc_Defs(doc, "tilesets")) do if Json_String(main, Json_Get(main, td, "embedAtlas")) == "LdtkIcons" do return Json_Int(main, Json_Get(main, td, "uid")), ""
	uids := uidsMake(doc)
	uid := uidTake(&uids)
	item, problem := newTilesetJV(op, uid, "LdtkIcons")
	if problem != "" do return -1, problem
	p := LDtkPatches{}
	appendItem(&p, doc, 0, LDtkDoc_Defs(doc, "tilesets"), item, Json_Minified(main))
	uidsDone(&p, doc, uids)
	// Its own stage: the entity's edit comes after it
	if problem = stagesApply(op.s, &p); problem != "" do return -1, problem
	return uid, ""
}

/*
A tileset's pixel data as LDtk caches it (TilesetDef.buildPixelData, _parseTilePixels): a "1" or
"0" per tile (no transparent pixel), and per tile its average color in 4 hex digits ARGB (the
square root of the alpha-weighted mean of squares per channel, each byte then rounded to 16 steps:
LDtk's intToHex3_ARGB). A tile past
the image is opaque and black.

Returns:
- The two strings (temp allocated), false when the image can't be read
*/
LDtk_PixelData :: proc(path: string, size: [2]int, grid, spacing, padding: int) -> (opaque, average: string, ok: bool) {
	pixels, iw, ih, read := Image_LoadRGBA(path)
	if !read do return "", "", false
	w, h := i32(iw), i32(ih)
	step := max(grid + spacing, 1)
	cWid := int(math.ceil(f64(size.x - padding * 2) / f64(step)))
	cHei := int(math.ceil(f64(size.y - padding * 2) / f64(step)))
	ob := strings.builder_make(0, cWid * cHei, context.temp_allocator)
	ab := strings.builder_make(0, cWid * cHei * 4, context.temp_allocator)
	HEX := "0123456789abcdef"
	for tid in 0 ..< cWid * cHei {
		tx := padding + (tid % cWid) * step
		ty := padding + (tid / cWid) * step
		isOpaque := true
		argb := [4]int{}
		if tx + grid <= size.x && ty + grid <= size.y {
			a, r, g, b, nRGB, nA: f64
			for py in ty ..< ty + grid do for px in tx ..< tx + grid {
				if px >= int(w) || py >= int(h) {
					nA += 1
					isOpaque = false
					continue
				}
				i := (py * int(w) + px) * 4
				R, G, B, A := f64(pixels[i]) / 255, f64(pixels[i + 1]) / 255, f64(pixels[i + 2]) / 255, f64(pixels[i + 3]) / 255
				if A < 1 do isOpaque = false
				a += A
				r += R * R * A
				g += G * G * A
				b += B * B * A
				nRGB += A
				nA += 1
			}
			channel :: proc(v: f64) -> int {
				if v != v do return 0
				return clamp(int(v * 255), 0, 255)
			}
			argb = {channel(a / nA), channel(math.sqrt(r / nRGB)), channel(math.sqrt(g / nRGB)), channel(math.sqrt(b / nRGB))}
		}
		strings.write_byte(&ob, isOpaque ? '1' : '0')
		// intToHex3_ARGB: each byte to its nearest of 16 steps (checked against LDtk's samples)
		for c in argb do strings.write_byte(&ab, HEX[clamp(int(f64(c) / 17 + 0.5), 0, 15)])
	}
	return strings.to_string(ob), strings.to_string(ab), true
}

// The pixel data written again for the tilesets asked (after their spacing, padding, grid or image changed)
@(private)
pixelsStage :: proc(op: ^DefOp) -> string {
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	p := LDtkPatches{}
	for uid in op.pixels {
		td := LDtkDoc_DefByUid(doc, "tilesets", uid)
		if td < 0 do continue
		path := ""
		if rel := Json_String(main, Json_Get(main, td, "relPath")); rel != "" do path = joinPath(LDtkDoc_Folder(doc), rel, allocator = context.temp_allocator)
		else if Json_String(main, Json_Get(main, td, "embedAtlas")) == "LdtkIcons" do path = joinPath(LDtkDoc_Folder(doc), "finalbossblues-icons_full_16.png", allocator = context.temp_allocator)
		size := [2]int{Json_Int(main, Json_Get(main, td, "pxWid")), Json_Int(main, Json_Get(main, td, "pxHei"))}
		value := LDtkJV(LDtkJNull{})
		if opaque, avg, ok := LDtk_PixelData(path, size, Json_Int(main, Json_Get(main, td, "tileGridSize"), 16), Json_Int(main, Json_Get(main, td, "spacing")), Json_Int(main, Json_Get(main, td, "padding"))); ok {
			value = jobject(jpair("opaqueTiles", opaque), jpair("averageColors", avg))
		}
		defWrite(&p, doc, td, "cachedPixelData", value)
	}
	return stagesApply(op.s, &p)
}

/*
A tileset's image changed (EditTilesetDefs' image picker: TilesetDef.importAtlasImage, then
remapAllTileIdsAfterResize and autoRenameTilesetIdentifier), or removed ("": removeAtlasImage).
*/
@(private)
tilesetImage :: proc(op: ^DefOp, p: ^LDtkPatches, node: int, image: string) -> string {
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	style := defStyle(doc)
	uid := Json_Int(main, Json_Get(main, node, "uid"))
	if Json_Kind(main, Json_Get(main, node, "embedAtlas")) == .String do return "LDtk's internal icons keep their image"
	oldPath := Json_String(main, Json_Get(main, node, "relPath"))
	oldSize := [2]int{Json_Int(main, Json_Get(main, node, "pxWid")), Json_Int(main, Json_Get(main, node, "pxHei"))}
	if image == "" {
		defWrite(p, doc, node, "relPath", LDtkJNull{})
		defWrite(p, doc, node, "pxWid", i64(0))
		defWrite(p, doc, node, "pxHei", i64(0))
		defWrite(p, doc, node, "savedSelections", LDtkJArray{})
		defWrite(p, doc, node, "cachedPixelData", LDtkJNull{})
		op.scope.gridTiles = true
		return ""
	}
	full := joinPath(LDtkDoc_Folder(doc), image, allocator = context.temp_allocator)
	size, ok := imageSize(full)
	if !ok do return fmt.tprintf("%s isn't an image the editor can read", image)
	path, _ := strings.replace_all(image, "\\", "/", context.temp_allocator)
	defWrite(p, doc, node, "relPath", path)
	defWrite(p, doc, node, "pxWid", i64(size.x))
	defWrite(p, doc, node, "pxHei", i64(size.y))
	limit := max(min(size.x, size.y), 2)
	grid := min(Json_Int(main, Json_Get(main, node, "tileGridSize"), 16), limit)
	spacing := min(Json_Int(main, Json_Get(main, node, "spacing")), limit)
	padding := min(Json_Int(main, Json_Get(main, node, "padding")), limit)
	defWrite(p, doc, node, "tileGridSize", i64(grid))
	defWrite(p, doc, node, "spacing", i64(spacing))
	// The identifier follows the file when it was the default or the old file's name
	id := Json_String(main, Json_Get(main, node, "identifier"))
	oldName := ""
	if oldPath != "" do oldName, _ = LDtk_CleanIdentifier(strings.trim_suffix(filepath.base(oldPath), filepath.ext(oldPath)), style)
	isDefault := strings.has_prefix(id, "Tileset")
	if isDefault || (oldName != "" && strings.contains(id, oldName)) {
		if base, valid := LDtk_CleanIdentifier(strings.trim_suffix(filepath.base(path), filepath.ext(path)), style); valid {
			defWrite(p, doc, node, "identifier", ldtkUniqueId(base, style, defIdentifiers(main, LDtkDoc_Defs(doc, "tilesets"), except = node)))
		}
	}
	op.pixels[uid] = true
	op.scope.gridTiles = true
	rerunTileset(op, uid)
	if oldPath == "" || oldSize == size do return ""
	// remapAllTileIdsAfterResize: a trim inside the padding, else the tile ids by the old width
	if padding > 0 && oldSize.x > size.x && oldSize.y > size.y && abs(oldSize.x - size.x) <= padding * 2 && abs(oldSize.y - size.y) <= padding * 2 && size.x % 2 == 0 && size.y % 2 == 0 {
		padding -= min(oldSize.x - size.x, oldSize.y - size.y) / 2
		defWrite(p, doc, node, "padding", i64(padding))
		return ""
	}
	defWrite(p, doc, node, "padding", i64(padding))
	oldCWid := int(math.ceil(f64(oldSize.x) / f64(max(grid, 1))))
	newCWid := int(math.ceil(f64(size.x - padding * 2) / f64(max(grid + spacing, 1))))
	newCHei := int(math.ceil(f64(size.y - padding * 2) / f64(max(grid + spacing, 1))))
	return remapTileIds(op, p, node, oldCWid, newCWid, newCHei)
}

// A tileset's grid changed (EditTilesetDefs: remapAllTileIdsAfterGridChange)
@(private)
tilesetGrid :: proc(op: ^DefOp, p: ^LDtkPatches, node, grid: int) -> string {
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	uid := Json_Int(main, Json_Get(main, node, "uid"))
	old := Json_Int(main, Json_Get(main, node, "tileGridSize"), 16)
	if old == grid do return ""
	defWrite(p, doc, node, "tileGridSize", i64(grid))
	op.pixels[uid] = true
	op.scope.gridTiles = true
	rerunTileset(op, uid)
	if Json_Kind(main, Json_Get(main, node, "relPath")) != .String && Json_Kind(main, Json_Get(main, node, "embedAtlas")) != .String do return ""
	size := [2]int{Json_Int(main, Json_Get(main, node, "pxWid")), Json_Int(main, Json_Get(main, node, "pxHei"))}
	spacing, padding := Json_Int(main, Json_Get(main, node, "spacing")), Json_Int(main, Json_Get(main, node, "padding"))
	oldCWid := int(math.ceil(f64(size.x - padding * 2) / f64(max(old + spacing, 1))))
	newCWid := int(math.ceil(f64(size.x - padding * 2) / f64(max(grid + spacing, 1))))
	newCHei := int(math.ceil(f64(size.y - padding * 2) / f64(max(grid + spacing, 1))))
	return remapTileIds(op, p, node, oldCWid, newCWid, newCHei)
}

/*
Every tile id using a tileset remapped to its new geometry (TilesetDef.remapAllTileIds): a tile
keeps its column and row, those past the new size go: Tiles layers' tiles, saved selections,
auto-layer rules' tiles, enum tags, custom data.
*/
@(private)
remapTileIds :: proc(op: ^DefOp, p: ^LDtkPatches, node, oldCWid, cWid, cHei: int) -> string {
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	minified := Json_Minified(main)
	uid := Json_Int(main, Json_Get(main, node, "uid"))
	remap :: proc(id, oldCWid, cWid, cHei: int) -> (int, bool) {
		cy := id / max(oldCWid, 1)
		cx := id - cy * max(oldCWid, 1)
		if cx >= cWid || cy >= cHei do return 0, false
		return cx + cy * cWid, true
	}
	// Tiles layers' tiles
	for _, level in doc.levels {
		m, ok := LDtkLevel_Read(doc, "", level)
		if !ok do continue
		defer LDtkLevel_Destroy(&m)
		for &l in m.layers {
			d := LDtkLevel_Def(&m, &l)
			if d.kind != .Tiles || d.tileset != uid do continue
			changed := false
			for &stack in l.tiles {
				i := 0
				for i < len(stack) {
					if id, keep := remap(int(stack[i].tile), oldCWid, cWid, cHei); keep {
						if i32(id) != stack[i].tile do changed = true
						stack[i].tile = i32(id)
						i += 1
					} else {
						ordered_remove(&stack, i)
						changed = true
					}
				}
			}
			if changed do l.changed += {.Tiles}
		}
		more := LDtkLevel_Patches(&m, doc)
		for list, file in more.files do for patch in list do LDtkPatches_Add(p, file, patch)
	}
	// Saved selections
	if sels := Json_Get(main, node, "savedSelections"); Json_Count(main, sels) > 0 {
		out := make([dynamic]LDtkJV, context.temp_allocator)
		for sel in Json_Items(main, sels) {
			ids := make([dynamic]LDtkJV, context.temp_allocator)
			for id in Json_Items(main, Json_Get(main, sel, "ids")) do if n, keep := remap(Json_Int(main, id), oldCWid, cWid, cHei); keep do append(&ids, i64(n))
			append(&out, jobject(jpair("ids", LDtkJArray(ids[:])), jpair("mode", strings.clone(Json_String(main, Json_Get(main, sel, "mode")), context.temp_allocator))))
		}
		defWrite(p, doc, node, "savedSelections", LDtkJArray(out[:]))
	}
	// Auto-layer rules' tiles (a tile past the new size is null, as LDtk leaves it)
	for ld in Json_Items(main, LDtkDoc_Defs(doc, "layers")) {
		if nodeUid(main, Json_Get(main, ld, "tilesetDefUid")) != uid do continue
		for g in Json_Items(main, Json_Get(main, ld, "autoRuleGroups")) do for r in Json_Items(main, Json_Get(main, g, "rules")) {
			rects := Json_Get(main, r, "tileRectsIds")
			if Json_Count(main, rects) == 0 do continue
			out := make([dynamic]LDtkJV, context.temp_allocator)
			for rect in Json_Items(main, rects) {
				ids := make([dynamic]LDtkJV, context.temp_allocator)
				for id in Json_Items(main, rect) {
					n, keep := remap(Json_Int(main, id), oldCWid, cWid, cHei)
					append(&ids, keep ? LDtkJV(i64(n)) : LDtkJV(LDtkJNull{}))
				}
				append(&out, LDtkJArray(ids[:]))
			}
			text := writeAt(main, rects, LDtkJArray(out[:]), minified)
			LDtkPatches_Set(p, doc, 0, rects, text)
		}
	}
	// Enum tags and custom data
	if tags := Json_Get(main, node, "enumTags"); Json_Count(main, tags) > 0 {
		out := make([dynamic]LDtkJV, context.temp_allocator)
		for entry in Json_Items(main, tags) {
			ids := make([dynamic]int, context.temp_allocator)
			for id in Json_Items(main, Json_Get(main, entry, "tileIds")) do if n, keep := remap(Json_Int(main, id), oldCWid, cWid, cHei); keep do append(&ids, n)
			slice.sort(ids[:])
			list := make([dynamic]LDtkJV, context.temp_allocator)
			for id in ids do append(&list, i64(id))
			append(&out, jobject(jpair("enumValueId", strings.clone(Json_String(main, Json_Get(main, entry, "enumValueId")), context.temp_allocator)), jpair("tileIds", LDtkJArray(list[:]))))
		}
		defWrite(p, doc, node, "enumTags", LDtkJArray(out[:]))
	}
	if data := Json_Get(main, node, "customData"); Json_Count(main, data) > 0 {
		Kept :: struct { id: int, data: string }
		kept := make([dynamic]Kept, context.temp_allocator)
		for d in Json_Items(main, data) do if n, keep := remap(Json_Int(main, Json_Get(main, d, "tileId")), oldCWid, cWid, cHei); keep do append(&kept, Kept{n, strings.clone(Json_String(main, Json_Get(main, d, "data")), context.temp_allocator)})
		slice.sort_by(kept[:], proc(a, b: Kept) -> bool { return a.id < b.id })
		out := make([dynamic]LDtkJV, context.temp_allocator)
		for k in kept do append(&out, jobject(jpair("tileId", i64(k.id)), jpair("data", k.data)))
		defWrite(p, doc, node, "customData", LDtkJArray(out[:]))
	}
	return ""
}

/*
A tileset's tiles' data (TileTagger): an enum value's tag on or off on tiles (`text`, `flag`; the
tileset's tag enum), or a tile's custom data (`ids[0]`, `text` trimmed: empty removes it).
*/
@(private)
tilesetTileEdit :: proc(op: ^DefOp) -> string {
	edit := op.edit
	doc := op.s.cur
	main := LDtkDoc_Main(doc)
	node := LDtkDoc_DefByUid(doc, "tilesets", edit.def)
	if node < 0 do return "no such tileset"
	cWid, cHei := Json_Int(main, Json_Get(main, node, "__cWid")), Json_Int(main, Json_Get(main, node, "__cHei"))
	p := LDtkPatches{}
	#partial switch edit.op {
	case .Tileset_Tag:
		source := nodeUid(main, Json_Get(main, node, "tagsSourceEnumUid"))
		if source < 0 do return "pick the enum tagging the tiles first"
		value := strings.trim_space(edit.text)
		if !slice.contains(LDtkDoc_EnumValues(doc, source), value) do return fmt.tprintf("%q isn't one of the enum's values", value)
		tags := make(map[string][dynamic]int, context.temp_allocator)
		for entry in Json_Items(main, Json_Get(main, node, "enumTags")) {
			ids := make([dynamic]int, context.temp_allocator)
			for id in Json_Items(main, Json_Get(main, entry, "tileIds")) do append(&ids, Json_Int(main, id))
			tags[strings.clone(Json_String(main, Json_Get(main, entry, "enumValueId")), context.temp_allocator)] = ids
		}
		ids := tags[value]
		for tid in edit.ids {
			if tid < 0 || tid >= cWid * cHei do continue
			at, has := slice.linear_search(ids[:], tid)
			if edit.flag && !has do append(&ids, tid)
			if !edit.flag && has do ordered_remove(&ids, at)
		}
		tags[value] = ids
		out := make([dynamic]LDtkJV, context.temp_allocator)
		for v in LDtkDoc_EnumValues(doc, source) {
			list := tags[v]
			slice.sort(list[:])
			items := make([dynamic]LDtkJV, context.temp_allocator)
			for id in list do append(&items, i64(id))
			append(&out, jobject(jpair("enumValueId", strings.clone(v, context.temp_allocator)), jpair("tileIds", LDtkJArray(items[:]))))
		}
		defWrite(&p, doc, node, "enumTags", LDtkJArray(out[:]))
	case .Tileset_Custom_Data:
		if len(edit.ids) == 0 do return "pick a tile"
		tid := edit.ids[0]
		if tid < 0 || tid >= cWid * cHei do return "no such tile"
		text := strings.trim_space(edit.text)
		Kept :: struct { id: int, data: string }
		kept := make([dynamic]Kept, context.temp_allocator)
		for d in Json_Items(main, Json_Get(main, node, "customData")) {
			id := Json_Int(main, Json_Get(main, d, "tileId"))
			if id != tid do append(&kept, Kept{id, strings.clone(Json_String(main, Json_Get(main, d, "data")), context.temp_allocator)})
		}
		if text != "" do append(&kept, Kept{tid, strings.clone(text, context.temp_allocator)})
		slice.sort_by(kept[:], proc(a, b: Kept) -> bool { return a.id < b.id })
		out := make([dynamic]LDtkJV, context.temp_allocator)
		for k in kept do append(&out, jobject(jpair("tileId", i64(k.id)), jpair("data", k.data)))
		defWrite(&p, doc, node, "customData", LDtkJArray(out[:]))
	case .Tileset_Selection_Saved:
		// TilesetDef.saveSelection: the saved selections holding any of these tiles go, then the
		// selection is kept when it's more than one tile
		mode := edit.text == "Random" ? "Random" : "Stamp"
		out := make([dynamic]LDtkJV, context.temp_allocator)
		for sel in Json_Items(main, Json_Get(main, node, "savedSelections")) {
			ids := make([dynamic]LDtkJV, context.temp_allocator)
			overlaps := false
			for id in Json_Items(main, Json_Get(main, sel, "ids")) {
				v := Json_Int(main, id)
				if slice.contains(edit.ids, v) do overlaps = true
				append(&ids, i64(v))
			}
			if !overlaps do append(&out, jobject(jpair("ids", LDtkJArray(ids[:])), jpair("mode", strings.clone(Json_String(main, Json_Get(main, sel, "mode")), context.temp_allocator))))
		}
		if len(edit.ids) > 1 {
			ids := make([dynamic]LDtkJV, context.temp_allocator)
			for id in edit.ids {
				if id < 0 || id >= cWid * cHei do return "no such tile"
				append(&ids, i64(id))
			}
			append(&out, jobject(jpair("ids", LDtkJArray(ids[:])), jpair("mode", mode)))
		}
		defWrite(&p, doc, node, "savedSelections", LDtkJArray(out[:]))
	case:
	}
	return stagesApply(op.s, &p)
}

// The enums a tileset can be tagged with: the project's local ones (external ones can't)
LDtkDefs_TagEnums :: proc(doc: ^LDtkDoc) -> []int {
	main := LDtkDoc_Main(doc)
	out := make([dynamic]int, context.temp_allocator)
	for d in Json_Items(main, LDtkDoc_Defs(doc, "enums")) do append(&out, Json_Int(main, Json_Get(main, d, "uid")))
	return out[:]
}

// An image's path relative to the .ldtk file, from the editor project's root (an asset's path)
LDtkDefs_ImagePath :: proc(root: string, doc: ^LDtkDoc, assetPath: string) -> (string, bool) {
	return LDtk_RelativePath(LDtkDoc_Folder(doc), joinPath(root, assetPath, allocator = context.temp_allocator))
}
