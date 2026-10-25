package crossfire_editor

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import e "engine:."

// The LDtk tab's write-back: the JSON that keeps its text, LDtk's schema, every edit kind, external
// levels, and the files staying readable by the engine

// LDtk's JSON schema (1.5.3, MIT: its LICENSE beside it)
@(private="file")
LDTK_SCHEMA_PATH :: "tests/fixtures/ldtk_schema/JSON_SCHEMA.json"

/*
Checks JSON against LDtk's schema: the keywords it uses (`$ref`, `type`, `required`,
`properties`, `additionalProperties: false`, `items`, `oneOf`, `enum`). Returns the problems
(temp allocated), at most `limit`.

Inputs:
- text: The JSON
- type: "" for a project (`LdtkJsonRoot`), else one of `otherTypes` ("Level" for a .ldtkl file,
  whose `__header__` is skipped)
*/
LDtk_SchemaProblems :: proc(text: string, type := "", limit := 20) -> []string {
	SchemaCheck :: struct {
		root: json.Object,
		problems: [dynamic]string,
		limit: int,
	}
	schemaText, err := os.read_entire_file(LDTK_SCHEMA_PATH, context.temp_allocator)
	if err != nil do return oneProblem(fmt.tprintf("can't read the schema: %v", err))
	schema, schemaErr := json.parse(schemaText, allocator = context.temp_allocator)
	if schemaErr != nil do return oneProblem(fmt.tprintf("the schema isn't JSON: %v", schemaErr))
	value, valueErr := json.parse(transmute([]byte)text, parse_integers = true, allocator = context.temp_allocator)
	if valueErr != nil do return oneProblem(fmt.tprintf("not JSON: %v", valueErr))
	c := SchemaCheck{root = schema.(json.Object), problems = make([dynamic]string, context.temp_allocator), limit = limit}
	resolve :: proc(c: ^SchemaCheck, ref: string) -> json.Object {
		path := strings.trim_prefix(ref, "#/")
		node := json.Value(c.root)
		for part in strings.split(path, "/", context.temp_allocator) {
			obj, ok := node.(json.Object)
			if !ok do return nil
			node = obj[part]
		}
		obj, _ := node.(json.Object)
		return obj
	}
	check :: proc(c: ^SchemaCheck, s: json.Object, v: json.Value, path: string) {
		if len(c.problems) >= c.limit || s == nil do return
		if ref, has := s["$ref"]; has {
			check(c, resolve(c, ref.(json.String)), v, path)
			return
		}
		if oneOf, has := s["oneOf"]; has {
			for branch in oneOf.(json.Array) {
				sub := SchemaCheck{root = c.root, problems = make([dynamic]string, context.temp_allocator), limit = 1}
				check(&sub, branch.(json.Object), v, path)
				if len(sub.problems) == 0 do return
			}
			append(&c.problems, fmt.tprintf("%s: matches none of its forms", path))
			return
		}
		if types, has := s["type"]; has {
			matches := false
			for t in types.(json.Array) {
				switch t.(json.String) {
				case "integer": if _, ok := v.(json.Integer); ok do matches = true
				case "number":
					if _, ok := v.(json.Integer); ok do matches = true
					if _, ok := v.(json.Float); ok do matches = true
				case "string": if _, ok := v.(json.String); ok do matches = true
				case "boolean": if _, ok := v.(json.Boolean); ok do matches = true
				case "null": if _, ok := v.(json.Null); ok do matches = true
				case "object": if _, ok := v.(json.Object); ok do matches = true
				case "array": if _, ok := v.(json.Array); ok do matches = true
				}
			}
			if !matches {
				append(&c.problems, fmt.tprintf("%s: %v isn't %v", path, v, types))
				return
			}
		}
		if values, has := s["enum"]; has {
			found := false
			for allowed in values.(json.Array) {
				if a, ok := allowed.(json.String); ok {
					if b, isString := v.(json.String); isString && a == b do found = true
				}
				if _, isNull := allowed.(json.Null); isNull {
					if _, ok := v.(json.Null); ok do found = true
				}
			}
			if !found do append(&c.problems, fmt.tprintf("%s: %v isn't one of %v", path, v, values))
		}
		#partial switch x in v {
		case json.Object:
			properties, _ := s["properties"].(json.Object)
			if required, has := s["required"]; has {
				for key in required.(json.Array) do if key.(json.String) not_in x do append(&c.problems, fmt.tprintf("%s: %s is missing", path, key.(json.String)))
			}
			closed := false
			if extra, has := s["additionalProperties"]; has {
				if b, ok := extra.(json.Boolean); ok && !b do closed = true
			}
			for key, member in x {
				property, known := properties[key]
				if !known {
					if closed && key != "__header__" do append(&c.problems, fmt.tprintf("%s: %s isn't in the schema", path, key))
					continue
				}
				check(c, property.(json.Object), member, fmt.tprintf("%s.%s", path, key))
			}
		case json.Array:
			if items, has := s["items"]; has {
				for item, i in x do check(c, items.(json.Object), item, fmt.tprintf("%s[%d]", path, i))
			}
		}
	}
	start := type == "" ? resolve(&c, "#/LdtkJsonRoot") : resolve(&c, fmt.tprintf("#/otherTypes/%s", type))
	check(&c, start, value, type == "" ? "project" : type)
	return c.problems[:]
}

@(private="file")
oneProblem :: proc(text: string) -> []string {
	out := make([]string, 1, context.temp_allocator)
	out[0] = text
	return out
}

// Every file of an LDtk project against the schema: the .ldtk file and its .ldtkl files
@(private)
expectValidFile :: proc(t: ^testing.T, path: string, loc := #caller_location) {
	text, err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, err == nil, "%s reads", path, loc = loc)
	for p in LDtk_SchemaProblems(string(text)) do testing.expectf(t, false, "%s: %s", filepath.base(path), p, loc = loc)
	doc, _ := Json_Parse(string(text), context.temp_allocator)
	folder := filepath.dir(path)
	for level in Json_Items(&doc, Json_Get(&doc, 0, "levels")) {
		rel := Json_Get(&doc, level, "externalRelPath")
		if Json_Kind(&doc, rel) != .String do continue
		levelPath := joinPath(folder, Json_String(&doc, rel), allocator = context.temp_allocator)
		levelText, levelErr := os.read_entire_file(levelPath, context.temp_allocator)
		testing.expectf(t, levelErr == nil, "%s reads", levelPath, loc = loc)
		for p in LDtk_SchemaProblems(string(levelText), "Level") do testing.expectf(t, false, "%s: %s", filepath.base(levelPath), p, loc = loc)
	}
	// And the engine reads it
	project, problem := e.LDtk_Load(path)
	testing.expectf(t, project != nil, "the engine reads %s: %s", path, problem, loc = loc)
	if project != nil do e.LDtk_Destroy(project)
}

// A value at a JSON path of a file as the editor has it (an edited document's unsaved text, else
// the file on disk; "" when it's missing)
@(private)
valueAt :: proc(path, at: string) -> string {
	text, found := LDtkDoc_CachedText(path)
	if !found {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil do return ""
		text = string(data)
	}
	doc, problem := Json_Parse(text, context.temp_allocator)
	if problem != "" do return ""
	node := Json_Path(&doc, at)
	if Json_Kind(&doc, node) == .String do return strings.clone(Json_String(&doc, node), context.temp_allocator)
	return compact(Json_Text(&doc, node))
}

// JSON without the spaces between its tokens (strings kept as they are)
@(private)
compact :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	inString := false
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if inString {
			strings.write_byte(&b, c)
			if c == '\\' && i + 1 < len(text) {
				i += 1
				strings.write_byte(&b, text[i])
			} else if c == '"' do inString = false
			continue
		}
		switch c {
		case ' ', '\t', '\n', '\r': continue
		case '"': inString = true
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// A copy of the LDtk tab's fixture in a fresh folder (the folder; a failed copy stops the test:
// its paths would be relative to the working folder)
@(private)
worldCopy :: proc(name: string) -> string {
	dir := tempDir(name)
	// Folder_Copy makes the folder itself
	_ = removeAll(dir)
	problem := Folder_Copy("tests/fixtures/ldtk_world", dir)
	assert(problem == "", problem)
	return dir
}

@(test)
ldtk_json_keeps_its_text :: proc(t: ^testing.T) {
	// Every LDtk file the tests know reads and writes back byte for byte, untouched
	files := make([dynamic]string, context.temp_allocator)
	append(&files, "tests/fixtures/ldtk/world.ldtk", "tests/fixtures/ldtk_world/world.ldtk", "tests/fixtures/ldtk_world/external.ldtk", "tests/fixtures/ldtk_world/worlds.ldtk",
		"tests/fixtures/ldtk_world/external/0000-North.ldtkl", "examples/demo_project/assets/levels/legacy.ldtk", LDTK_SCHEMA_PATH)
	// LDtk's own samples (written by LDtk itself), when the workspace has LDtk's source
	samples := "../ldtk/app/extraFiles/samples"
	if entries, err := os.read_all_directory_by_path(samples, context.temp_allocator); err == nil {
		for entry in entries do if strings.has_suffix(entry.name, ".ldtk") do append(&files, joinPath(samples, entry.name, allocator = context.temp_allocator))
	}
	for path in files {
		text, err := os.read_entire_file(path, context.temp_allocator)
		testing.expectf(t, err == nil, "%s reads", path)
		doc, problem := Json_Parse(string(text))
		defer Json_Destroy(&doc)
		testing.expectf(t, problem == "", "%s parses: %s", path, problem)
		same, ok := Json_Apply(doc.text, nil, context.temp_allocator)
		testing.expect(t, ok && same == string(text), "untouched, the text is as it was")
	}

	// A patch changes only its span; strings, numbers, nesting and paths
	source := "{\n\t\"a\": [1, 2.50, -3e2],\n\t\"b\": { \"c\": \"x\\\"y\\u00e9\", \"d\": null },\n\t\"list\": [{ \"id\": \"one\", \"n\": 1 }, { \"id\": \"two\", \"n\": 2 }]\n}"
	doc, problem := Json_Parse(source)
	defer Json_Destroy(&doc)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, Json_String(&doc, Json_Path(&doc, "b.c")), "x\"yé")
	testing.expect_value(t, Json_Float(&doc, Json_Path(&doc, "a.1")), 2.5)
	testing.expect_value(t, Json_Text(&doc, Json_Path(&doc, "a.2")), "-3e2")
	testing.expect_value(t, Json_Int(&doc, Json_Path(&doc, "list.id=two.n")), 2)
	testing.expect_value(t, Json_Kind(&doc, Json_Path(&doc, "b.d")), JsonKind.Null)
	changed, ok := Json_Apply(doc.text, {Json_SetPatch(&doc, Json_Path(&doc, "a.1"), "7")}, context.temp_allocator)
	testing.expect(t, ok, "applied")
	testing.expect_value(t, changed, strings.concatenate({source[:strings.index(source, "2.50")], "7", source[strings.index(source, "2.50") + 4:]}, context.temp_allocator))
	// Two patches on one span are refused
	_, overlap := Json_Apply(doc.text, {Json_SetPatch(&doc, Json_Path(&doc, "a"), "[]"), Json_SetPatch(&doc, Json_Path(&doc, "a.0"), "9")}, context.temp_allocator)
	testing.expect(t, !overlap, "overlapping patches refused")

	// New items are written like their neighbours
	appended, _ := Json_Apply(doc.text, {Json_AppendPatch(&doc, Json_Path(&doc, "list"), `{ "id": "three", "n": 3 }`)}, context.temp_allocator)
	testing.expect(t, strings.contains(appended, `{ "id": "two", "n": 2 }, { "id": "three", "n": 3 }]`), "inline array: inline")
	member, _ := Json_Apply(doc.text, {Json_AddMemberPatch(&doc, Json_Root(&doc), "e", "true")}, context.temp_allocator)
	testing.expect(t, strings.has_suffix(member, "}],\n\t\"e\": true\n}"), "a member on its own line, at its siblings' indentation")
	removed, _ := Json_Apply(doc.text, {Json_RemovePatch(&doc, Json_Path(&doc, "list.0"))}, context.temp_allocator)
	testing.expect(t, strings.contains(removed, `"list": [{ "id": "two", "n": 2 }]`), "the first item removed with its separator")
	minDoc, _ := Json_Parse(`{"v":[],"w":[1]}`, context.temp_allocator)
	minified, _ := Json_Apply(minDoc.text, {Json_AppendPatch(&minDoc, Json_Path(&minDoc, "v"), "5"), Json_AppendPatch(&minDoc, Json_Path(&minDoc, "w"), "6")}, context.temp_allocator)
	testing.expect_value(t, minified, `{"v":[5],"w":[1,6]}`)

	// Numbers and identifiers as LDtk writes them
	testing.expect_value(t, Json_FormatNumber(1.0), "1")
	testing.expect_value(t, Json_FormatNumber(0.5), "0.5")
	testing.expect_value(t, Json_FormatNumber(0.12345), "0.123")
	testing.expect_value(t, Json_FormatNumber(-0.0001), "0")
	clean :: proc(id, style: string) -> string { s, ok := LDtk_CleanIdentifier(id, style); return ok ? s : "(none)" }
	testing.expect_value(t, clean("my  door", "Capitalize"), "My_door")
	testing.expect_value(t, clean("2nd floor", "Free"), "_nd_floor")
	testing.expect_value(t, clean("big-boss", "Uppercase"), "BIG_BOSS")
	testing.expect_value(t, clean("   ", "Free"), "(none)")
	testing.expect_value(t, clean("__coin", "Capitalize"), "_Coin") // LDtk makes runs of "_" one
	color, colorOk := LDtk_ParseColor("#ff8800")
	testing.expect(t, colorOk && color == 0xFF8800, "colors")
	testing.expect_value(t, LDtk_FormatColor(0xFF8800), "#FF8800")
}

@(test)
ldtk_fixtures_match_the_schema :: proc(t: ^testing.T) {
	// The validator itself catches what's wrong
	broken := LDtk_SchemaProblems(`{"iid": 5}`)
	testing.expect(t, len(broken) > 0, "a broken project has problems")
	for path in ([]string{"tests/fixtures/ldtk_world/world.ldtk", "tests/fixtures/ldtk_world/external.ldtk", "tests/fixtures/ldtk_world/worlds.ldtk", "examples/demo_project/assets/levels/legacy.ldtk"}) {
		expectValidFile(t, path)
	}
}

@(test)
ldtk_edits_write_valid_files :: proc(t: ^testing.T) {
	dir := worldCopy("ldtk_edits")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	path := joinPath(dir, "world.ldtk", allocator = context.temp_allocator)
	before, _ := os.read_entire_file(path, context.temp_allocator)
	apply :: proc(t: ^testing.T, dir: string, edit: LDtk_Edit, loc := #caller_location) -> string {
		edit := edit
		edit.file = "world.ldtk"
		problem, _ := LDtkOps_Apply(dir, edit)
		return problem
	}
	// Each edit saved (written as Save writes it), then the file checked
	ok :: proc(t: ^testing.T, dir, path: string, edit: LDtk_Edit, loc := #caller_location) {
		problem := apply(t, dir, edit, loc)
		testing.expectf(t, problem == "", "%v: %s", edit.op, problem, loc = loc)
		testing.expect_value(t, LDtkDoc_Save(dir, "world.ldtk"), "", loc = loc)
		testing.expect(t, !LDtkDoc_IsUnsaved(dir, "world.ldtk"), "saved", loc = loc)
		expectValidFile(t, path, loc)
	}
	// Layers (Walls is uid 3, Tiles 2, Entities 1)
	ok(t, dir, path, {op = .Layer_Opacity, def = 3, number = 0.75})
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.75")
	testing.expect_value(t, valueAt(path, "levels.identifier=Cave.layerInstances.layerDefUid=3.__opacity"), "0.75")
	// Only the edited values changed: the file is the same length but for the new digits
	after, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, len(after) - len(before), 4) // four values, 0.5 -> 0.75: nothing else moved
	ok(t, dir, path, {op = .Layer_Name, def = 3, text = "solid ground"})
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.identifier"), "Solid_ground")
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.layerInstances.layerDefUid=3.__identifier"), "Solid_ground")
	testing.expect(t, apply(t, dir, {op = .Layer_Name, def = 3, text = "Tiles"}) != "", "a taken name is refused")
	testing.expect(t, apply(t, dir, {op = .Layer_Name, def = 3, text = "  "}) != "", "no identifier: refused")
	ok(t, dir, path, {op = .Layer_Parallax_X, def = 2, number = 0.5})
	testing.expect_value(t, valueAt(path, "defs.layers.uid=2.parallaxFactorX"), "0.5")
	ok(t, dir, path, {op = .Layer_Parallax_Scaling, def = 2, flag = false})
	ok(t, dir, path, {op = .Layer_Visible, level = "lvl-cave", def = 2, flag = false})
	testing.expect_value(t, valueAt(path, "levels.identifier=Cave.layerInstances.layerDefUid=2.visible"), "false")
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=2.visible"), "true")
	// Order: the definitions and every level's instances
	ok(t, dir, path, {op = .Layer_Move, def = 3, number = -1})
	testing.expect_value(t, valueAt(path, "defs.layers.1.uid"), "3")
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.layerInstances.1.layerDefUid"), "3")
	// Grid size: painted cells keep their cell (LDtk's remapToGridSize), entities move by the ratio
	ok(t, dir, path, {op = .Layer_Grid_Size, def = 3, number = 8})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=3.__cWid"), "32")
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=3.intGridCsv.224"), "1") // the bottom row of 16 px cells (row 7), now row 7 of 32 cells
	ok(t, dir, path, {op = .Layer_Grid_Size, def = 3, number = 16})
	ok(t, dir, path, {op = .Layer_Grid_Size, def = 1, number = 8})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.__cWid"), "32")
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=coin1.px"), "[52,36]") // half of (104, 72)
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=coin1.__grid"), "[6,4]") // the pivot's at its bottom

	// Entity definitions (Player 10, Coin 11, Door 12)
	ok(t, dir, path, {op = .Entity_Name, def = 11, text = "gem"})
	testing.expect_value(t, valueAt(path, "defs.entities.uid=11.identifier"), "Gem")
	testing.expect_value(t, valueAt(path, "levels.identifier=Cave.layerInstances.layerDefUid=1.entityInstances.iid=coin2.__identifier"), "Gem")
	testing.expect_value(t, valueAt(path, "toc.0.identifier"), "Gem")
	ok(t, dir, path, {op = .Entity_Width, def = 11, number = 24})
	testing.expect_value(t, valueAt(path, "levels.identifier=Cave.layerInstances.layerDefUid=1.entityInstances.iid=coin2.width"), "24")
	testing.expect_value(t, valueAt(path, "toc.0.instancesData.1.widPx"), "24")
	ok(t, dir, path, {op = .Entity_Color, def = 11, text = "#123abc"})
	testing.expect_value(t, valueAt(path, "defs.entities.uid=11.color"), "#123ABC")
	testing.expect_value(t, valueAt(path, "levels.identifier=Cave.layerInstances.layerDefUid=1.entityInstances.iid=coin2.__smartColor"), "#123ABC")
	ok(t, dir, path, {op = .Entity_Pivot_X, def = 10, number = 0})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.__pivot"), "[0,1]")

	// Field definitions and values
	ok(t, dir, path, {op = .Field_Name, field = 47, text = "worth"})
	testing.expect_value(t, valueAt(path, "levels.identifier=Cave.layerInstances.layerDefUid=1.entityInstances.iid=coin2.fieldInstances.0.__identifier"), "worth")
	testing.expect(t, strings.contains(string(after2(path)), `"worth": 5`), "the table of contents' field followed")
	ok(t, dir, path, {op = .Field_Default, field = 47, text = "2"})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=coin1.fieldInstances.0.__value"), "2")
	testing.expect_value(t, valueAt(path, "levels.identifier=Cave.layerInstances.layerDefUid=1.entityInstances.iid=coin2.fieldInstances.0.__value"), "5")
	ok(t, dir, path, {op = .Entity_Field, entity = "player1", field = 41, text = "7"})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=41.__value"), "7")
	testing.expect(t, strings.contains(valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=41.realEditorValues"), `"V_Int"`), "its editor value")
	ok(t, dir, path, {op = .Entity_Field, entity = "player1", field = 40, text = "5000"})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=40.__value"), "1000")
	ok(t, dir, path, {op = .Entity_Field, entity = "player1", field = 44, text = "#00ff00"})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=44.__value"), "#00FF00")
	ok(t, dir, path, {op = .Entity_Field, entity = "player1", field = 45, text = "4, 6"})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=45.__value"), `{"cx":4,"cy":6}`)
	testing.expect(t, apply(t, dir, {op = .Entity_Field, entity = "player1", field = 43, text = "Bored"}) != "", "not one of the enum's values")
	ok(t, dir, path, {op = .Entity_Field, entity = "player1", field = 42, text = ""})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=42.realEditorValues"), "[]")
	ok(t, dir, path, {op = .Level_Field, level = "lvl-cave", field = 51, text = "4"})
	testing.expect_value(t, valueAt(path, "levels.identifier=Cave.fieldInstances.defUid=51.__value"), "4")
	ok(t, dir, path, {op = .Entity_Moved, entity = "coin1", number = 40, number2 = 50})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=coin1.px"), "[40,50]")
	testing.expect_value(t, valueAt(path, "toc.0.instancesData.0.worldX"), "40")

	// Links: a reference retargeted, cleared
	ok(t, dir, path, {op = .Entity_Ref, entity = "player1", field = 46, text = "coin3"})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=46.__value.levelIid"), "lvl-tower")
	testing.expect(t, apply(t, dir, {op = .Entity_Ref, entity = "door1", field = 48, text = "coin3"}) != "", "a Door's target must be a Door")
	ok(t, dir, path, {op = .Entity_Ref, entity = "player1", field = 46, text = ""})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=46.__value"), "null")

	// IntGrid values and enums
	ok(t, dir, path, {op = .IntGrid_Name, def = 3, index = 2, text = "ledge"})
	ok(t, dir, path, {op = .IntGrid_Color, def = 3, index = 2, text = "#ABCDEF"})
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.intGridValues.value=2.color"), "#ABCDEF")
	ok(t, dir, path, {op = .Enum_Value_Name, def = 30, index = 0, text = "cheerful"})
	testing.expect_value(t, valueAt(path, "defs.enums.uid=30.values.0.id"), "Cheerful")
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=43.__value"), "Cheerful")
	ok(t, dir, path, {op = .Enum_Value_Color, def = 30, index = 0, text = "#010203"})
	testing.expect_value(t, valueAt(path, "defs.enums.uid=30.values.0.color"), fmt.tprint(0x010203))
	ok(t, dir, path, {op = .Enum_Value_Added, def = 30, text = "Calm"})
	testing.expect_value(t, valueAt(path, "defs.enums.uid=30.values.3.id"), "Calm")
	ok(t, dir, path, {op = .Enum_Name, def = 30, text = "Feeling"})
	testing.expect_value(t, valueAt(path, "defs.entities.uid=10.fieldDefs.uid=43.__type"), "LocalEnum.Feeling")
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=43.__type"), "LocalEnum.Feeling")
	ok(t, dir, path, {op = .Enum_Added, text = "Season"})
	testing.expect_value(t, valueAt(path, "defs.enums.identifier=Season.uid"), "60")
	testing.expect_value(t, valueAt(path, "nextUid"), "61")

	// The world: a level moved (neighbours follow), the layout, the grid
	ok(t, dir, path, {op = .Level_Moved, level = "lvl-tower", number = 512, number2 = 0})
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.worldX"), "512")
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.__neighbours"), `[{"levelIid":"lvl-cave","dir":"e"}]`)
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.__neighbours.0.dir"), "w")
	// coin3 at x 28 since the entities' grid was halved (56 before)
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.layerInstances.layerDefUid=1.entityInstances.iid=coin3.__worldX"), "540")
	testing.expect_value(t, valueAt(path, "toc.0.instancesData.2.worldX"), "540")
	ok(t, dir, path, {op = .World_Layout, text = "GridVania"})
	ok(t, dir, path, {op = .Level_Moved, level = "lvl-tower", number = 700, number2 = 10})
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.worldX"), "768")
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.worldY"), "0")
	ok(t, dir, path, {op = .World_Grid_Width, number = 128})
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.worldX"), "384")
	ok(t, dir, path, {op = .World_Layout, text = "LinearHorizontal"})
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.worldX"), "-1")
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.__neighbours"), "[]")
	testing.expect(t, apply(t, dir, {op = .Level_Moved, level = "lvl-tower", number = 0, number2 = 0}) != "", "linear worlds' levels don't move")
}

// A file's text as the editor has it (temp allocated)
@(private="file")
after2 :: proc(path: string) -> []byte {
	if text, found := LDtkDoc_CachedText(path); found do return transmute([]byte)strings.clone(text, context.temp_allocator)
	text, _ := os.read_entire_file(path, context.temp_allocator)
	return text
}

@(test)
ldtk_external_levels_are_written_where_they_are :: proc(t: ^testing.T) {
	dir := worldCopy("ldtk_external")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	path := joinPath(dir, "external.ldtk", allocator = context.temp_allocator)
	north := joinPath(dir, "external/0000-North.ldtkl", allocator = context.temp_allocator)
	south := joinPath(dir, "external/0001-South.ldtkl", allocator = context.temp_allocator)
	southBefore, _ := os.read_entire_file(south, context.temp_allocator)
	doc := LDtkDoc_Get(dir, "external.ldtk")
	testing.expect(t, doc != nil && doc.problem == "", "read")
	if doc == nil do return
	testing.expect_value(t, len(doc.files), 3)
	apply :: proc(dir: string, edit: LDtk_Edit) -> string {
		edit := edit
		edit.file = "external.ldtk"
		problem, _ := LDtkOps_Apply(dir, edit)
		return problem
	}
	// An entity's field: only in its level's file
	testing.expect_value(t, apply(dir, {op = .Entity_Field, entity = "player1", field = 41, text = "9"}), "")
	testing.expect_value(t, valueAt(north, "layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=41.__value"), "9")
	southNow, _ := os.read_entire_file(south, context.temp_allocator)
	testing.expect(t, string(southNow) == string(southBefore), "the other level's file is untouched")
	// A level's field: in both copies of the level
	testing.expect_value(t, apply(dir, {op = .Level_Field, level = "lvl-south", field = 50, text = "deep"}), "")
	testing.expect_value(t, valueAt(path, "levels.identifier=South.fieldInstances.defUid=50.__value"), "deep")
	testing.expect_value(t, valueAt(south, "fieldInstances.defUid=50.__value"), "deep")
	// GridVania: a move snaps to the grid (256 x 128), in both copies; the neighbours follow
	testing.expect_value(t, apply(dir, {op = .Level_Moved, level = "lvl-south", number = 300, number2 = 70}), "")
	testing.expect_value(t, valueAt(path, "levels.identifier=South.worldX"), "256")
	testing.expect_value(t, valueAt(south, "worldY"), "128")
	testing.expect_value(t, valueAt(path, "levels.identifier=North.__neighbours.0.dir"), "se")
	testing.expect_value(t, valueAt(north, "__neighbours.0.dir"), "se")
	// Layers: an opacity in every level's file
	testing.expect_value(t, apply(dir, {op = .Layer_Opacity, def = 2, number = 0.25}), "")
	testing.expect_value(t, valueAt(south, "layerInstances.layerDefUid=2.__opacity"), "0.25")
	// Nothing's on disk until it's saved: then every changed file, each a valid level
	disk, _ := os.read_entire_file(south, context.temp_allocator)
	testing.expect(t, string(disk) == string(southBefore), "unsaved: the file as it was")
	testing.expect(t, LDtkDoc_IsUnsaved(dir, "external.ldtk"), "unsaved")
	testing.expect_value(t, LDtkDoc_Save(dir, "external.ldtk"), "")
	disk, _ = os.read_entire_file(south, context.temp_allocator)
	testing.expect(t, strings.contains(string(disk), `"__opacity": 0.25`), "saved")
	expectValidFile(t, path)
}

@(test)
ldtk_edits_undo_and_redo :: proc(t: ^testing.T) {
	dir := worldCopy("ldtk_undo")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	project := Project_CreateEmpty(dir, "Levels")
	state := State{project = project, browserSelection = {kind = .None}, selectedNode = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	state.mode = .Level
	defer State_Destroy(&state)
	path := joinPath(dir, "world.ldtk", allocator = context.temp_allocator)
	// Through a pointer: `state, _ = update(state, ...)` at every step kept a copy of the State
	// (35 KB) per call in this frame, and with update's own frames it overflowed a Windows test
	// thread's 1 MB stack. Each step is logged, so a crash says where it was
	send :: proc(state: ^State, m: Msg, loc := #caller_location) {
		log.infof("ldtk_edits_undo_and_redo: the step at line %d", loc.line)
		state^, _ = update(state^, m)
	}
	append(&state.project.assets, AssetDef{path = strings.clone("world.ldtk"), kind = .LDtk})
	original, _ := os.read_entire_file(path, context.temp_allocator)
	original = transmute([]byte)strings.clone(string(original), context.temp_allocator)
	disk :: proc(path: string) -> string {
		text, _ := os.read_entire_file(path, context.temp_allocator)
		return string(text)
	}

	// Edits change the document in memory: the file stays as it was until Save
	send(&state, LDtk_Edit{op = .Layer_Opacity, file = "world.ldtk", def = 3, number = 0.2})
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.2")
	testing.expect(t, disk(path) == string(original), "not written yet")
	testing.expect(t, LDtkDoc_IsUnsaved(dir, "world.ldtk"), "unsaved")
	testing.expect(t, Project_IsModified(&state), "the project shows unsaved")
	testing.expect_value(t, len(state.history.undo), 1)
	send(&state, LDtk_Edit{op = .Entity_Moved, file = "world.ldtk", entity = "coin2", number = 10, number2 = 20})
	testing.expect_value(t, len(state.history.undo), 2)
	// A refused edit is no step
	send(&state, LDtk_Edit{op = .Layer_Name, file = "world.ldtk", def = 3, text = "Tiles"})
	testing.expect_value(t, len(state.history.undo), 2)

	send(&state, Action.Undo)
	testing.expect_value(t, valueAt(path, "levels.identifier=Cave.layerInstances.layerDefUid=1.entityInstances.iid=coin2.px"), "[64,72]")
	testing.expect_value(t, state.mode, EditorMode.Level)
	send(&state, Action.Undo)
	testing.expect(t, string(after2(path)) == string(original), "both undone: the document as it was, byte for byte")
	testing.expect(t, !LDtkDoc_IsUnsaved(dir, "world.ldtk") && !Project_IsModified(&state), "undone back to the saved text: nothing to save")
	send(&state, Action.Redo)
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.2")

	// Save writes it (and the project)
	send(&state, Action.Save_Project)
	testing.expect(t, !LDtkDoc_IsUnsaved(dir, "world.ldtk") && !Project_IsModified(&state), "saved")
	testing.expect(t, strings.contains(disk(path), `"displayOpacity": 0.2`), "written")
	expectValidFile(t, path)

	// Saved in LDtk since: the document is read again; an undo of a change elsewhere in it keeps LDtk's
	text := disk(path)
	outside, _ := strings.replace(text, `"defaultLevelBgColor": "#202838"`, `"defaultLevelBgColor": "#112233"`, 1, context.temp_allocator)
	testing.expect(t, outside != text, "the outside change applies")
	testing.expect_value(t, LDtk_WriteFile(path, outside, ldtkModified(path)), "")
	send(&state, Action.Undo)
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.5")
	testing.expect_value(t, valueAt(path, "defaultLevelBgColor"), "#112233")
	_, outsideNoted := LDtkDoc_Outside(dir, "world.ldtk")
	testing.expect(t, outsideNoted, "noted")
	// A change on the same spot asks first
	send(&state, Action.Redo)
	send(&state, Action.Save_Project)
	text = disk(path)
	clash, _ := strings.replace(text, `"displayOpacity": 0.2`, `"displayOpacity": 0.9`, 1, context.temp_allocator)
	testing.expect_value(t, LDtk_WriteFile(path, clash, ldtkModified(path)), "")
	send(&state, Action.Undo)
	testing.expect(t, state.level.conflict.open, "asked")
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.9")
	send(&state, LDtk_Conflict_Chosen(.Keep_File))
	testing.expect(t, !state.level.conflict.open, "answered")
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.9")
	expectValidFile(t, path)
}

/*
LDtk saves the file while the editor has unsaved edits in it: a change elsewhere is merged into
them; one on the same spot waits for the answer (reload the file: the edits are dropped; keep the
edits: Save writes them over it), and Save refuses until then.
*/
@(test)
ldtk_unsaved_edits_and_outside_changes :: proc(t: ^testing.T) {
	dir := worldCopy("ldtk_unsaved_outside")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	project := Project_CreateEmpty(dir, "Levels")
	state := State{project = project, browserSelection = {kind = .None}, selectedNode = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	state.mode = .Level
	append(&state.project.assets, AssetDef{path = strings.clone("world.ldtk"), kind = .LDtk})
	defer State_Destroy(&state)
	send :: proc(state: ^State, m: Msg) { state^, _ = update(state^, m) }
	path := joinPath(dir, "world.ldtk", allocator = context.temp_allocator)
	disk :: proc(path: string) -> string {
		text, _ := os.read_entire_file(path, context.temp_allocator)
		return string(text)
	}
	outside :: proc(t: ^testing.T, path, from, to: string, loc := #caller_location) {
		text := disk(path)
		changed, _ := strings.replace(text, from, to, 1, context.temp_allocator)
		testing.expect(t, changed != text, "the outside change applies", loc = loc)
		testing.expect_value(t, LDtk_WriteFile(path, changed, ldtkModified(path)), "", loc = loc)
	}

	// Elsewhere: merged into the unsaved edit, which stays unsaved
	send(&state, LDtk_Edit{op = .Layer_Opacity, file = "world.ldtk", def = 3, number = 0.3})
	outside(t, path, `"defaultLevelBgColor": "#202838"`, `"defaultLevelBgColor": "#445566"`)
	testing.expect(t, LDtkDoc_Get(dir, "world.ldtk") != nil, "read")
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.3")
	testing.expect_value(t, valueAt(path, "defaultLevelBgColor"), "#445566")
	change, noted := LDtkDoc_Outside(dir, "world.ldtk")
	testing.expect(t, noted && change.merged, "merged, and noted")
	testing.expect(t, LDtkDoc_IsUnsaved(dir, "world.ldtk"), "still unsaved")
	_, clash := LDtkDoc_DiskConflict(dir, "world.ldtk")
	testing.expect(t, !clash, "no clash")
	// Undo takes back the edit and keeps LDtk's change
	send(&state, Action.Undo)
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.5")
	testing.expect_value(t, valueAt(path, "defaultLevelBgColor"), "#445566")
	testing.expect(t, !LDtkDoc_IsUnsaved(dir, "world.ldtk"), "the document is the file again")

	// The same spot: it waits; Save refuses meanwhile; Keep My Edits, then Save writes them
	send(&state, LDtk_Edit{op = .Layer_Opacity, file = "world.ldtk", def = 3, number = 0.4})
	outside(t, path, `"displayOpacity": 0.5`, `"displayOpacity": 0.8`)
	testing.expect(t, LDtkDoc_Get(dir, "world.ldtk") != nil, "read")
	names, waiting := LDtkDoc_DiskConflict(dir, "world.ldtk")
	testing.expect(t, waiting && len(names) == 1 && names[0] == "world.ldtk", "the clash waits")
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.4")
	testing.expect(t, LDtkDoc_Save(dir, "world.ldtk") != "", "Save refuses while it waits")
	testing.expect(t, strings.contains(disk(path), `"displayOpacity": 0.8`), "the file is LDtk's")
	send(&state, LDtk_Disk_Chosen{reload = false})
	_, waiting = LDtkDoc_DiskConflict(dir, "world.ldtk")
	testing.expect(t, !waiting && LDtkDoc_IsUnsaved(dir, "world.ldtk"), "kept: still unsaved")
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.4")
	send(&state, Action.Save_Project)
	testing.expect(t, strings.contains(disk(path), `"displayOpacity": 0.4`), "written over LDtk's")
	expectValidFile(t, path)

	// Again, then Reload It: the file as LDtk saved it, the edit dropped
	send(&state, LDtk_Edit{op = .Layer_Opacity, file = "world.ldtk", def = 3, number = 0.6})
	outside(t, path, `"displayOpacity": 0.4`, `"displayOpacity": 0.7`)
	testing.expect(t, LDtkDoc_Get(dir, "world.ldtk") != nil, "read")
	_, waiting = LDtkDoc_DiskConflict(dir, "world.ldtk")
	testing.expect(t, waiting, "waits")
	send(&state, LDtk_Disk_Chosen{reload = true})
	_, waiting = LDtkDoc_DiskConflict(dir, "world.ldtk")
	testing.expect(t, !waiting && !LDtkDoc_IsUnsaved(dir, "world.ldtk"), "reloaded: nothing unsaved")
	testing.expect_value(t, valueAt(path, "defs.layers.uid=3.displayOpacity"), "0.7")

	// What the engine reads of an unsaved document: the stamp moves with each edit, the game gets it
	before := LDtkDoc_Stamp(dir, "world.ldtk")
	send(&state, LDtk_Edit{op = .Level_Moved, file = "world.ldtk", level = "lvl-tower", number = 512, number2 = 0})
	testing.expect(t, LDtkDoc_Stamp(dir, "world.ldtk") != before, "a new stamp")
	project2 := LDtkEdit_Project(dir, "world.ldtk")
	testing.expect(t, project2 != nil, "the inspector's copy")
	if project2 != nil {
		tower := e.LDtk_FindLevel(project2, "Tower")
		testing.expect(t, tower != nil && tower.world.x == 512, "the inspector reads the unsaved document")
	}
	game := new(e.Game)
	defer free(game)
	defer e.Game_ForgetLDtk(game)
	testing.expect(t, LDtkDoc_ProvideToGame(game, dir, "world.ldtk"), "given to a game")
	loaded := e.Game_LoadLDtk(game, "world.ldtk", dir)
	testing.expect(t, loaded != nil && e.LDtk_FindLevel(loaded, "Tower") != nil && e.LDtk_FindLevel(loaded, "Tower").world.x == 512, "the game builds the unsaved level")
	// Save As writes the unsaved text into the copy (unsaved texts by file)
	texts := LDtkDocs_UnsavedTexts(&state)
	testing.expect_value(t, len(texts), 1)
	testing.expect(t, path in texts, "the project file's text")
}

// A rename of an entity type or a layer is followed by the scenes' and the components' LDtkLevel
// nodes, and its undo and redo bring both back (components aren't in the project's snapshot)
@(test)
ldtk_renames_follow_into_components_and_undo :: proc(t: ^testing.T) {
	dir := worldCopy("ldtk_rename_components")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	project := Project_CreateEmpty(dir, "Levels")
	state := State{project = project, browserSelection = {kind = .None}, selectedNode = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	state.mode = .Level
	defer State_Destroy(&state)
	send :: proc(state: ^State, m: Msg) { state^, _ = update(state^, m) }
	level :: proc(scene: ^SceneDef) -> ^NodeDef {
		i := Scene_InsertNode(scene, "Level", .LDtkLevel, -1)
		node := &scene.nodes[i]
		delete(node.ldtk.file)
		node.ldtk.file = strings.clone("world.ldtk")
		delete(node.ldtk.collisionLayer)
		node.ldtk.collisionLayer = strings.clone("Walls")
		append(&node.ldtk.entityComponents, e.LDtkEntityComponent{entity = strings.clone("Player"), component = strings.clone(""), script = strings.clone("")})
		return node
	}
	_ = level(&state.project.scenes[0])
	ci, problem := Project_NewComponent(&state.project, "LevelPiece")
	testing.expect_value(t, problem, "")
	_ = level(&state.project.scenes[ci])
	entityOf :: proc(state: ^State, scene: int) -> string {
		for &n in state.project.scenes[scene].nodes do if n.kind == .LDtkLevel do return n.ldtk.entityComponents[0].entity
		return ""
	}
	layerOf :: proc(state: ^State, scene: int) -> string {
		for &n in state.project.scenes[scene].nodes do if n.kind == .LDtkLevel do return n.ldtk.collisionLayer
		return ""
	}

	send(&state, LDtk_Edit{op = .Entity_Name, file = "world.ldtk", def = 10, text = "Hero"})
	testing.expect_value(t, entityOf(&state, 0), "Hero")
	testing.expect_value(t, entityOf(&state, ci), "Hero")
	send(&state, Action.Undo)
	testing.expect_value(t, valueAt(joinPath(dir, "world.ldtk", allocator = context.temp_allocator), "defs.entities.uid=10.identifier"), "Player")
	testing.expect_value(t, entityOf(&state, 0), "Player")
	testing.expect_value(t, entityOf(&state, ci), "Player")
	send(&state, Action.Redo)
	testing.expect_value(t, entityOf(&state, 0), "Hero")
	testing.expect_value(t, entityOf(&state, ci), "Hero")
	testing.expect(t, Project_IsModified(&state), "a rename the components followed makes the project modified")
	// A layer: the same
	send(&state, LDtk_Edit{op = .Layer_Name, file = "world.ldtk", def = 3, text = "Floor"})
	testing.expect_value(t, layerOf(&state, ci), "Floor")
	send(&state, Action.Undo)
	testing.expect_value(t, layerOf(&state, ci), "Walls")
	testing.expect_value(t, layerOf(&state, 0), "Walls")
}

// The write-back's replace: over an existing file, over one another handle has open (Windows
// refuses the rename then: File_Replace tries again, then writes into it), and a refusal that
// leaves the file as it was and says why
@(test)
ldtk_files_are_replaced_even_when_open :: proc(t: ^testing.T) {
	dir := tempDir("ldtk_replace")
	defer removeAll(dir)
	path := joinPath(dir, "level.ldtk", allocator = context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("{\"a\": 1}")) == nil, "written")
	before := ldtkModified(path)
	testing.expect_value(t, LDtk_WriteFile(path, "{\"a\": 2}", before), "")
	got, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(got), "{\"a\": 2}")
	testing.expect(t, time.diff(before, ldtkModified(path)) > 0, "a newer time")
	testing.expect(t, !os.exists(fmt.tprintf("%s.crossfire-tmp", path)), "no temporary file left")
	// Open for reading meanwhile (LDtk or a scanner holding it)
	f, err := os.open(path)
	testing.expect(t, err == nil, "opened")
	testing.expect_value(t, LDtk_WriteFile(path, "{\"a\": 3}", ldtkModified(path)), "")
	if err == nil do os.close(f)
	got, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(got), "{\"a\": 3}")
	testing.expect(t, !os.exists(fmt.tprintf("%s.crossfire-tmp", path)), "no temporary file left")
	// A folder that isn't there: an error, nothing made
	missing := joinPath(dir, "nowhere", "level.ldtk", allocator = context.temp_allocator)
	testing.expect(t, LDtk_WriteFile(missing, "{}", {}) != "", "refused")
	testing.expect(t, !os.exists(missing), "not made")
}

@(test)
ldtk_opens_at_a_level :: proc(t: ^testing.T) {
	dir := tempDir("ldtk_settings")
	defer removeAll(dir)
	settings := joinPath(dir, "settings.cfg", allocator = context.temp_allocator)
	// LDtk's own style (its settings file as LDtk 1.5.3 writes it)
	text := "{\n\t\"lastKnownVersion\": \"1.5.3-64bits\",\n\t\"openLastProject\": false,\n\t\"lastProject\": null,\n\t\"uiStates\": [\n\t\t{ \"id\": \"ShowProjectColors\", \"val\": 1 }\n\t]\n}"
	_ = os.write_entire_file(settings, transmute([]byte)text)
	testing.expect_value(t, LDtk_RememberLevel(settings, "/games/w/world.ldtk", 101), "")
	got, _ := os.read_entire_file(settings, context.temp_allocator)
	want := "{\n\t\"lastKnownVersion\": \"1.5.3-64bits\",\n\t\"openLastProject\": false,\n\t\"lastProject\": { \"filePath\": \"/games/w/world.ldtk\", \"levelUid\": 101 },\n\t\"uiStates\": [\n\t\t{ \"id\": \"ShowProjectColors\", \"val\": 1 }\n\t]\n}"
	testing.expect_value(t, string(got), want)
	// Again: replaced, not added
	testing.expect_value(t, LDtk_RememberLevel(settings, "/games/w/world.ldtk", 7), "")
	testing.expect_value(t, valueAt(settings, "lastProject.levelUid"), "7")
	// LDtk never started: nothing written
	testing.expect(t, LDtk_RememberLevel(joinPath(dir, "missing.cfg", allocator = context.temp_allocator), "/x.ldtk", 1) != "", "no settings file")
	testing.expect(t, !os.exists(joinPath(dir, "missing.cfg", allocator = context.temp_allocator)), "not made")
}

@(test)
level_canvas_drags_levels_and_entities :: proc(t: ^testing.T) {
	dir := worldCopy("ldtk_canvas")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	project := Project_CreateEmpty(dir, "Levels")
	state := State{project = project, browserSelection = {kind = .None}, selectedNode = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	state.mode = .Level
	append(&state.project.assets, AssetDef{path = strings.clone("world.ldtk"), kind = .LDtk})
	defer State_Destroy(&state)
	path := joinPath(dir, "world.ldtk", allocator = context.temp_allocator)
	send :: proc(state: ^State, m: Msg) { state^, _ = update(state^, m) }

	// The first size fits the world: 512 x 256 world pixels in 800 x 400
	send(&state, Level_Canvas_Measured{800, 400})
	testing.expect_value(t, state.level.view.fitted, "world.ldtk||")
	testing.expect(t, state.level.view.zoom > 1.3 && state.level.view.zoom < 1.5, "fitted")

	// A level dragged (Free: whole pixels), one undo step
	send(&state, Level_Canvas_Pressed{world = {64, 192}, level = "Tower"})
	testing.expect_value(t, state.level.level, "Tower")
	testing.expect_value(t, state.level.drag.mode, LevelDragMode.Level)
	send(&state, Level_Canvas_Moved{world = {80, 194}, delta = {20, 3}})
	send(&state, Level_Canvas_Moved{world = {164.4, 195}, delta = {100, 1}})
	send(&state, Level_Canvas_Released{})
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.worldX"), "100")
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.worldY"), "131")
	testing.expect_value(t, len(state.history.undo), 1)
	testing.expect(t, Project_IsModified(&state), "an unsaved LDtk edit makes the project modified")
	send(&state, Msg(Action.Undo))
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.worldX"), "0")
	testing.expect(t, !Project_IsModified(&state), "undone to the saved text: nothing to save")
	// A press that doesn't move only selects
	send(&state, Level_Canvas_Pressed{world = {64, 192}, level = "Tower"})
	send(&state, Level_Canvas_Moved{world = {64.5, 192}, delta = {0.5, 0}})
	send(&state, Level_Canvas_Released{})
	testing.expect_value(t, len(state.history.undo), 0)

	// GridVania: a drag lands on the world grid (256 x 128)
	send(&state, LDtk_Edit{op = .World_Layout, file = "world.ldtk", text = "GridVania"})
	send(&state, Level_Canvas_Pressed{world = {64, 192}, level = "Tower"})
	send(&state, Level_Canvas_Moved{world = {64 + 300, 192 + 20}, delta = {300, 20}})
	send(&state, Level_Canvas_Released{})
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.worldX"), "256")
	testing.expect_value(t, valueAt(path, "levels.identifier=Tower.worldY"), "128")
	send(&state, Msg(Action.Undo))
	send(&state, Msg(Action.Undo))
	testing.expect_value(t, valueAt(path, "worldLayout"), "Free")

	// An entity: selected (its level too, the tab shows its type), dragged onto its layer's grid
	// (Coin: 16 px cells, pivot at the bottom middle), or by the pixel with Shift
	state.level.bottomTab = .World
	send(&state, Level_Canvas_Pressed{world = {104, 64}, level = "Start", entity = "coin1"})
	testing.expect_value(t, state.level.entity, "coin1")
	testing.expect_value(t, state.level.bottomTab, BottomTab.Entities)
	testing.expect_value(t, state.level.entityDef, 11)
	send(&state, Level_Canvas_Moved{world = {124, 69}, delta = {20, 5}})
	send(&state, Level_Canvas_Released{})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=coin1.px"), "[120,80]")
	send(&state, Level_Canvas_Pressed{world = {120, 72}, level = "Start", entity = "coin1", free = true})
	send(&state, Level_Canvas_Moved{world = {123, 75}, delta = {3, 3}, free = true})
	send(&state, Level_Canvas_Released{})
	testing.expect_value(t, valueAt(path, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=coin1.px"), "[123,83]")
	// Empty space: nothing selected, the drag pans
	send(&state, Level_Canvas_Pressed{world = {700, 300}})
	testing.expect_value(t, state.level.entity, "")
	testing.expect_value(t, state.level.level, "")
	center := state.level.view.center
	send(&state, Level_Canvas_Moved{world = {700, 300}, delta = {14, 0}})
	send(&state, Level_Canvas_Released{})
	testing.expect(t, state.level.view.center.x < center.x, "panned")

	// Typing a name is one undo step; a name refused on the way leaves the last good one
	undo := len(state.history.undo)
	for text in ([]string{"P", "Pl", "Pla", "Play", "Playe", "Player2"}) {
		send(&state, LDtk_Text_Typed{id = 77, edit = {op = .Entity_Name, file = "world.ldtk", def = 10, text = text}})
	}
	testing.expect_value(t, valueAt(path, "defs.entities.uid=10.identifier"), "Player2")
	testing.expect_value(t, len(state.history.undo), undo + 1)
	send(&state, Msg(Action.Undo))
	testing.expect_value(t, valueAt(path, "defs.entities.uid=10.identifier"), "Player")
	testing.expect_value(t, LDtkDoc_Save(dir, "world.ldtk"), "")
	expectValidFile(t, path)
}
