package crossfire_editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:strconv"
import "core:testing"
import e "engine:."

// The definitions editors (ldtk_defs.odin) and LDtk's tidy (ldtk_tidy.odin): each kind of
// definition created, edited, removed, with what LDtk brings in step in the levels, undone,
// schema-checked and read by the engine

// LDtk's samples, saved by LDtk 1.5.3 (when the workspace has LDtk's source)
@(private="file")
LDTK_SAMPLES_DIR :: "../ldtk/app/extraFiles/samples"

// Where two texts first differ, with some context (temp)
@(private="file")
textDifference :: proc(a, b: string) -> string {
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] do i += 1
	from := max(0, i - 120)
	return fmt.tprintf("at byte %d of %d / %d:\n  ours:   %q\n  file:   %q", i, len(a), len(b), a[from:min(len(a), i + 120)], b[from:min(len(b), i + 120)])
}

/*
LDtk's tidy changes nothing in a file LDtk wrote (its samples: every derived value is already
what LDtk derives), nor in the fixtures made to LDtk's rules. Not the oldest fixture,
tests/fixtures/ldtk/world.ldtk (written by hand: its coins have a field without a definition), nor
the demo's legacy.ldtk (make_demo.py wrote only the fields it set: LDtk's first save adds the others
at their defaults, as the tidy does).
*/
@(test)
ldtk_tidy_leaves_ldtks_own_files_alone :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	Place :: struct { root, path: string }
	places := make([dynamic]Place, context.temp_allocator)
	append(&places, Place{"tests/fixtures/ldtk_world", "world.ldtk"}, Place{"tests/fixtures/ldtk_world", "external.ldtk"},
		Place{"tests/fixtures/ldtk_world", "worlds.ldtk"}, Place{"tests/fixtures/ldtk_paint", "paint.ldtk"})
	if entries, err := os.read_all_directory_by_path(LDTK_SAMPLES_DIR, context.temp_allocator); err == nil {
		for entry in entries do if strings.has_suffix(entry.name, ".ldtk") do append(&places, Place{LDTK_SAMPLES_DIR, strings.clone(entry.name, context.temp_allocator)})
	} else {
		log.infof("LDtk's samples aren't here (%s): only the fixtures", LDTK_SAMPLES_DIR)
	}
	// LDtk's own test files saved by 1.5 (older ones LDtk updates when it reads them)
	for folder in ([]string{"../ldtk/tests", "../ldtk/tests/bugs", "../ldtk/tests/largeLevels"}) {
		entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
		if err != nil do continue
		for entry in entries {
			if !strings.has_suffix(entry.name, ".ldtk") do continue
			text, _ := os.read_entire_file(joinPath(folder, entry.name, allocator = context.temp_allocator), context.temp_allocator)
			if strings.contains(string(text[:min(len(text), 4096)]), `"jsonVersion": "1.5`) do append(&places, Place{folder, strings.clone(entry.name, context.temp_allocator)})
		}
	}
	for place in places {
		if !os.exists(joinPath(place.root, place.path, allocator = context.temp_allocator)) do continue
		doc := LDtkDoc_Get(place.root, place.path)
		if !testing.expectf(t, doc != nil && doc.problem == "", "%s reads", place.path) do continue
		s := stagesMake(doc)
		problem := LDtkTidy_Run(&s, {intGrid = true, gridTiles = true})
		testing.expectf(t, problem == "", "%s: tidy ran: %s", place.path, problem)
		for text, i in s.texts {
			original := doc.files[i].json.text
			if text != original do testing.expectf(t, false, "%s (file %d): tidy changed it %s", place.path, i, textDifference(text, original))
		}
		for d in s.made do LDtkDoc_Free(d)
	}
}

// A tileset's pixel data as LDtk caches it: every sample tileset's, made again from its image
@(test)
ldtk_tileset_pixel_data_matches_ldtk :: proc(t: ^testing.T) {
	entries, err := os.read_all_directory_by_path(LDTK_SAMPLES_DIR, context.temp_allocator)
	if err != nil {
		log.infof("LDtk's samples aren't here (%s): skipped", LDTK_SAMPLES_DIR)
		return
	}
	checked := 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".ldtk") do continue
		text, _ := os.read_entire_file(joinPath(LDTK_SAMPLES_DIR, entry.name, allocator = context.temp_allocator), context.temp_allocator)
		doc, _ := Json_Parse(string(text), context.temp_allocator)
		for td in Json_Items(&doc, Json_Path(&doc, "defs.tilesets")) {
			rel := Json_String(&doc, Json_Get(&doc, td, "relPath"))
			cached := Json_Get(&doc, td, "cachedPixelData")
			if rel == "" || Json_Kind(&doc, cached) != .Object do continue
			size := [2]int{Json_Int(&doc, Json_Get(&doc, td, "pxWid")), Json_Int(&doc, Json_Get(&doc, td, "pxHei"))}
			opaque, avg, ok := LDtk_PixelData(joinPath(LDTK_SAMPLES_DIR, rel, allocator = context.temp_allocator), size,
				Json_Int(&doc, Json_Get(&doc, td, "tileGridSize")), Json_Int(&doc, Json_Get(&doc, td, "spacing")), Json_Int(&doc, Json_Get(&doc, td, "padding")))
			if !testing.expectf(t, ok, "%s: %s reads", entry.name, rel) do continue
			wantOpaque := Json_String(&doc, Json_Get(&doc, cached, "opaqueTiles"))
			wantAvg := Json_String(&doc, Json_Get(&doc, cached, "averageColors"))
			testing.expectf(t, opaque == wantOpaque, "%s %s: opaque tiles %s", entry.name, rel, textDifference(opaque, wantOpaque))
			testing.expectf(t, avg == wantAvg, "%s %s: average colors %s", entry.name, rel, textDifference(avg, wantAvg))
			checked += 1
		}
	}
	log.infof("%d tilesets' pixel data checked against LDtk's", checked)
}

// A copy of the LDtk tabs' fixture (tests/fixtures/ldtk_world) for one test
@(private="file")
Defs :: struct {
	dir, path: string,
}

@(private="file")
defsCopy :: proc(name: string) -> Defs {
	dir := worldCopy(name)
	return {dir, joinPath(dir, "world.ldtk", allocator = context.temp_allocator)}
}

// An edit of the copy's world.ldtk (why it wasn't made, "" when it was)
@(private="file")
defsApply :: proc(d: Defs, edit: LDtk_Edit) -> string {
	e := edit
	if e.file == "" do e.file = "world.ldtk"
	problem, _ := LDtkOps_Apply(d.dir, e)
	return problem
}

/*
An edit made, then the document checked: every file against LDtk's schema, read by the engine,
and already tidy (LDtk's tidy changes nothing in it).
*/
@(private="file")
defsMust :: proc(t: ^testing.T, d: Defs, edit: LDtk_Edit, loc := #caller_location) {
	problem := defsApply(d, edit)
	testing.expectf(t, problem == "", "%v %v %q: %s", edit.op, edit.kind, edit.key, problem, loc = loc)
	file := edit.file != "" ? edit.file : "world.ldtk"
	defsCheck(t, d.dir, file, loc)
}

@(private="file")
defsCheck :: proc(t: ^testing.T, dir, file: string, loc := #caller_location) {
	doc := LDtkDoc_Get(dir, file)
	if !testing.expect(t, doc != nil && doc.problem == "", "the document reads", loc = loc) do return
	for f, i in doc.files {
		for p in LDtk_SchemaProblems(f.json.text, i == 0 ? "" : "Level") do testing.expectf(t, false, "%s: %s", filepath.base(f.path), p, loc = loc)
	}
	project, problem := e.LDtk_Parse(LDtkDoc_GameText(doc), doc.files[0].path)
	testing.expectf(t, project != nil, "the engine reads it: %s", problem, loc = loc)
	if project != nil do e.LDtk_Destroy(project)
	s := stagesMake(doc)
	testing.expect_value(t, LDtkTidy_Run(&s, {intGrid = true, gridTiles = true}), "", loc = loc)
	for text, i in s.texts do if text != doc.files[i].json.text do testing.expectf(t, false, "not tidy after the edit (file %d): %s", i, textDifference(text, doc.files[i].json.text), loc = loc)
	for m in s.made do LDtkDoc_Free(m)
}

@(private="file")
defsValue :: proc(d: Defs, at: string) -> string {
	return valueAt(d.path, at)
}

// An object's keys in order, as one text ("a,b,c")
@(private="file")
keysOf :: proc(json: ^JsonDoc, node: int) -> string {
	keys := make([dynamic]string, context.temp_allocator)
	for c in Json_Items(json, node) do append(&keys, Json_Key(json, c))
	return strings.join(keys[:], ",", context.temp_allocator)
}

// The keys of a node of the copy's document
@(private="file")
defsKeys :: proc(d: Defs, at: string) -> string {
	text, _ := LDtkDoc_CachedText(d.path)
	doc, _ := Json_Parse(text, context.temp_allocator)
	return keysOf(&doc, Json_Path(&doc, at))
}

// LDtk's sample with every kind of definition (its keys in LDtk's order), nil without the samples
@(private="file")
defsSample :: proc() -> ^JsonDoc {
	text, err := os.read_entire_file(joinPath(LDTK_SAMPLES_DIR, "Test_file_for_API_showing_all_features.ldtk", allocator = context.temp_allocator), context.temp_allocator)
	if err != nil do return nil
	doc := new(JsonDoc, context.temp_allocator)
	doc^, _ = Json_Parse(string(text), context.temp_allocator)
	return doc
}

/*
New definitions as LDtk writes them: every layer type, entity types and presets, every field type
(entities' and levels'), enums, tilesets from an image and LDtk's internal icons; their keys in
LDtk's order (its sample's), its defaults and names, every level given what it needs (layer
instances, field instances at their defaults).
*/
@(test)
ldtk_new_definitions_are_written_as_ldtk_writes_them :: proc(t: ^testing.T) {
	d := defsCopy("ldtk_defs_new")
	defer removeAll(d.dir)
	defer LDtkDoc_DestroyAll()
	sample := defsSample()
	sampleKeys :: proc(sample: ^JsonDoc, at: string) -> string {
		if sample == nil do return ""
		return keysOf(sample, Json_Path(sample, at))
	}

	// Layers: new ones on top, named by type, LDtk's defaults; every level gets an empty instance
	// (the fixture has an Entities and a Tiles layer: the new ones are numbered)
	Layer :: struct { type, name: string }
	for l, i in ([]Layer{{"IntGrid", "IntGrid"}, {"Entities", "Entities2"}, {"Tiles", "Tiles2"}, {"AutoLayer", "AutoLayer"}}) {
		defsMust(t, d, {op = .Def_Added, kind = .Layer, text = l.type})
		testing.expect_value(t, defsValue(d, "defs.layers.0.identifier"), l.name)
		testing.expect_value(t, defsValue(d, "defs.layers.0.uid"), fmt.tprint(60 + i))
		testing.expect_value(t, defsValue(d, "levels.identifier=Cave.layerInstances.0.layerDefUid"), fmt.tprint(60 + i))
		testing.expect_value(t, defsValue(d, "levels.identifier=Cave.layerInstances.0.__identifier"), l.name)
		if sample != nil do testing.expect_value(t, defsKeys(d, "defs.layers.0"), sampleKeys(sample, "defs.layers.0"))
		if sample != nil do testing.expect_value(t, defsKeys(d, "levels.0.layerInstances.0"), sampleKeys(sample, "levels.0.layerInstances.0"))
	}
	testing.expect_value(t, defsValue(d, "nextUid"), "64")
	testing.expect_value(t, defsValue(d, "defs.layers.identifier=IntGrid.intGridValues"), `[{"value":1,"identifier":null,"color":"#000000","tile":null,"groupUid":0}]`)
	// An IntGrid layer's cells: one per cell of each level (Start: 256 x 128 at 16 px)
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=60.__cWid"), "16")
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=60.intGridCsv.127"), "0")
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=60.intGridCsv.128"), "")
	// LDtk's other defaults: an Entities layer fades and hides its fields, a Tiles layer takes the only tileset
	testing.expect_value(t, defsValue(d, "defs.layers.identifier=Entities2.inactiveOpacity"), "0.6")
	testing.expect_value(t, defsValue(d, "defs.layers.identifier=Entities2.hideFieldsWhenInactive"), "true")
	testing.expect_value(t, defsValue(d, "defs.layers.identifier=Tiles2.tilesetDefUid"), "5")
	testing.expect_value(t, defsValue(d, "levels.identifier=Tower.layerInstances.layerDefUid=62.__tilesetDefUid"), "5")
	testing.expect_value(t, defsValue(d, "levels.identifier=Tower.layerInstances.layerDefUid=62.__tilesetRelPath"), "tiles.png")
	// A second IntGrid layer: IntGrid2
	defsMust(t, d, {op = .Def_Added, kind = .Layer, text = "IntGrid"})
	testing.expect_value(t, defsValue(d, "defs.layers.0.identifier"), "IntGrid2")
	testing.expect(t, defsApply(d, {op = .Def_Added, kind = .Layer, text = "Sprites"}) != "", "not a layer type")

	// Entity types: "Entity", a nice color, the project's default size and pivot; the presets
	defsMust(t, d, {op = .Def_Added, kind = .Entity})
	testing.expect_value(t, defsValue(d, "defs.entities.3.identifier"), "Entity")
	testing.expect_value(t, defsValue(d, "defs.entities.3.width"), "16")
	testing.expect_value(t, defsValue(d, "defs.entities.3.pivotY"), "1")
	testing.expect_value(t, defsValue(d, "defs.entities.3.limitBehavior"), "MoveLastOne")
	if sample != nil do testing.expect_value(t, defsKeys(d, "defs.entities.3"), sampleKeys(sample, "defs.entities.0"))
	defsMust(t, d, {op = .Def_Added, kind = .Entity})
	testing.expect_value(t, defsValue(d, "defs.entities.4.identifier"), "Entity2")
	testing.expect(t, defsValue(d, "defs.entities.4.color") != defsValue(d, "defs.entities.3.color"), "another nice color")
	defsMust(t, d, {op = .Def_Added, kind = .Entity, text = "CircleRegion"})
	testing.expect_value(t, defsValue(d, "defs.entities.5.identifier"), "CircleRegion")
	testing.expect_value(t, defsValue(d, "defs.entities.5.renderMode"), "Ellipse")
	testing.expect_value(t, defsValue(d, "defs.entities.5.hollow"), "true")
	testing.expect_value(t, defsValue(d, "defs.entities.5.keepAspectRatio"), "true")
	testing.expect_value(t, defsValue(d, "defs.entities.5.tags"), `["region"]`)
	testing.expect_value(t, defsValue(d, "defs.entities.5.pivotX"), "0.5")

	// Fields of every type on Player: named by type (Free style), LDtk's defaults; every Player
	// gets one at its default
	Case :: struct { type, name, value: string, array: bool }
	cases := []Case{
		{"F_Int", "Integer", "0", false}, {"F_Float", "Float", "0", false}, {"F_Bool", "Boolean", "false", false},
		{"F_String", "String", "null", false}, {"F_Text", "Multilines", "null", false}, {"F_Color", "Color", "#000000", false},
		{"F_Enum(30)", "Mood", "null", false}, {"F_Path", "File_path", "null", false}, {"F_Tile", "Tile", "null", false},
		{"F_EntityRef", "Entity_ref", "null", false}, {"F_Point", "Point", "null", false}, {"F_Int", "Integer2", "[]", true},
	}
	for c, i in cases {
		defsMust(t, d, {op = .Def_Added, kind = .Field, def = 10, text = c.type, flag = c.array})
		at := fmt.tprintf("defs.entities.uid=10.fieldDefs.%d", 7 + i)
		testing.expectf(t, defsValue(d, fmt.tprintf("%s.identifier", at)) == c.name, "%s is named %s: %s", c.type, c.name, defsValue(d, fmt.tprintf("%s.identifier", at)))
		uid := defsValue(d, fmt.tprintf("%s.uid", at))
		value := defsValue(d, fmt.tprintf("levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.defUid=%s.__value", uid))
		testing.expectf(t, value == c.value, "a new %s's value is %s: %s", c.type, c.value, value)
	}
	if sample != nil do testing.expect_value(t, defsKeys(d, "defs.entities.uid=10.fieldDefs.7"), sampleKeys(sample, "defs.entities.0.fieldDefs.0"))
	if sample != nil do testing.expect_value(t, defsKeys(d, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.fieldInstances.7"), sampleKeys(sample, "levels.0.layerInstances.0.entityInstances.0.fieldInstances.0"))
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.identifier=Mood.__type"), "LocalEnum.Mood")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.identifier=Point.editorDisplayMode"), "PointPath")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.identifier=Entity_ref.editorLinkStyle"), "CurvedArrow")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.identifier=Color.useForSmartColor"), "true")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.identifier=Integer2.__type"), "Array<Int>")
	// The new Color field gives the entity its color now (its default, black: LDtk's smart color)
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1.__smartColor"), "#000000")
	testing.expect(t, defsApply(d, {op = .Def_Added, kind = .Field, def = -1, text = "F_Point"}) != "", "levels have no points")
	// A level field: every level gets it
	defsMust(t, d, {op = .Def_Added, kind = .Field, def = -1, text = "F_Bool"})
	testing.expect_value(t, defsValue(d, "defs.levelFields.3.identifier"), "Boolean")
	testing.expect_value(t, defsValue(d, "levels.identifier=Tower.fieldInstances.3.__value"), "false")

	// Enums: "Enum", then numbered; named
	defsMust(t, d, {op = .Def_Added, kind = .Enum})
	testing.expect_value(t, defsValue(d, "defs.enums.2.identifier"), "Enum")
	defsMust(t, d, {op = .Def_Added, kind = .Enum})
	testing.expect_value(t, defsValue(d, "defs.enums.3.identifier"), "Enum2")
	if sample != nil do testing.expect_value(t, defsKeys(d, "defs.enums.3"), sampleKeys(sample, "defs.enums.0"))

	// Tilesets: from an image (named after it, its size and pixel data), without one, LDtk's icons
	defsMust(t, d, {op = .Def_Added, kind = .Tileset, text = "tiles.png"})
	testing.expect_value(t, defsValue(d, "defs.tilesets.1.identifier"), "Tiles2")
	testing.expect_value(t, defsValue(d, "defs.tilesets.1.pxWid"), "32")
	testing.expect_value(t, defsValue(d, "defs.tilesets.1.__cWid"), "2")
	testing.expect_value(t, defsValue(d, "defs.tilesets.1.cachedPixelData.opaqueTiles"), "1111")
	if sample != nil do testing.expect_value(t, defsKeys(d, "defs.tilesets.1"), sampleKeys(sample, "defs.tilesets.0"))
	defsMust(t, d, {op = .Def_Added, kind = .Tileset})
	testing.expect_value(t, defsValue(d, "defs.tilesets.2.identifier"), "Tileset")
	testing.expect_value(t, defsValue(d, "defs.tilesets.2.__cWid"), "0")
	testing.expect(t, defsApply(d, {op = .Def_Added, kind = .Tileset, text = "missing.png"}) != "", "an image that isn't there")
	// An entity drawn with LDtk's icons: the tileset made, the tile opacities LDtk starts with
	defsMust(t, d, {op = .Def_Set, kind = .Entity, def = 11, key = "render", text = "LdtkIcons"})
	icons := defsValue(d, "defs.tilesets.identifier=Internal_Icons.uid")
	testing.expect(t, icons != "", "LDtk's icons' tileset")
	testing.expect_value(t, defsValue(d, "defs.tilesets.identifier=Internal_Icons.embedAtlas"), "LdtkIcons")
	testing.expect_value(t, defsValue(d, "defs.tilesets.identifier=Internal_Icons.__cHei"), "64")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.tilesetId"), icons)
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.renderMode"), "Tile")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.fillOpacity"), "0.08")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.lineOpacity"), "0")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.tileRect"), "null")
	defsMust(t, d, {op = .Def_Set, kind = .Entity, def = 11, key = "render", text = "!Cross"})
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.renderMode"), "Cross")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.fillOpacity"), "1")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.tilesetId"), "null")
	// Saved as Save writes it
	testing.expect_value(t, LDtkDoc_Save(d.dir, "world.ldtk"), "")
	expectValidFile(t, d.path)
}

/*
Layer definitions changed as LDtk's EditLayerDefs changes them: members and their bounds, the
parallax rules, tags, offsets in the instances, a Tiles layer's tileset and grid, an auto-layer's
source and grid, IntGrid values (added, moved into a group, removed with their cells) and groups,
copies, removal, order.
*/
@(test)
ldtk_layer_definitions_change_as_ldtk_changes_them :: proc(t: ^testing.T) {
	d := defsCopy("ldtk_defs_layers")
	defer removeAll(d.dir)
	defer LDtkDoc_DestroyAll()
	set :: proc(t: ^testing.T, d: Defs, layer: int, key, text: string, number: f64 = 0, flag := false, loc := #caller_location) {
		defsMust(t, d, {op = .Def_Set, kind = .Layer, def = layer, key = key, text = text, number = number, flag = flag}, loc)
	}
	// Plain members, within LDtk's bounds; documentation and color null when empty
	set(t, d, 3, "doc", "  ")
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.doc"), "null")
	set(t, d, 3, "doc", "Solid ground")
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.doc"), "Solid ground")
	set(t, d, 3, "uiColor", "#ff8800")
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.uiColor"), "#FF8800")
	set(t, d, 3, "displayOpacity", "", 0.01)
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.displayOpacity"), "0.1")
	set(t, d, 3, "inactiveOpacity", "0.25")
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.inactiveOpacity"), "0.25")
	set(t, d, 3, "guideGridWid", "", 1)
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.guideGridWid"), "0")
	set(t, d, 3, "guideGridWid", "", 4)
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.guideGridWid"), "4")
	set(t, d, 3, "hideInList", "", 0, true)
	set(t, d, 3, "renderInWorldView", "", 0, false)
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.renderInWorldView"), "false")
	set(t, d, 3, "uiFilterTags", "front, solid front ,x-y")
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.uiFilterTags"), `["front","solid","x_y"]`)
	// The offset adds to each instance's own in `__pxTotalOffsetX`
	set(t, d, 3, "pxOffsetX", "", 5)
	testing.expect_value(t, defsValue(d, "levels.identifier=Cave.layerInstances.layerDefUid=3.__pxTotalOffsetX"), "5")
	// Parallax: Y follows X while they're the same; with scaling on, Y is X's
	set(t, d, 2, "parallaxScaling", "", 0, false)
	set(t, d, 2, "parallaxFactorX", "", 0.5)
	testing.expect_value(t, defsValue(d, "defs.layers.uid=2.parallaxFactorY"), "0.5")
	set(t, d, 2, "parallaxFactorY", "", -0.25)
	set(t, d, 2, "parallaxFactorX", "", 0.75)
	testing.expect_value(t, defsValue(d, "defs.layers.uid=2.parallaxFactorY"), "-0.25")
	set(t, d, 2, "parallaxScaling", "", 0, true)
	testing.expect_value(t, defsValue(d, "defs.layers.uid=2.parallaxFactorY"), "0.75")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Layer, def = 2, key = "parallaxFactorY", number = 0}) != "", "Y follows X while scaling")
	// Entity tags only for an Entities layer
	set(t, d, 1, "requiredTags", "pickup")
	set(t, d, 1, "excludedTags", "boss")
	testing.expect_value(t, defsValue(d, "defs.layers.uid=1.requiredTags"), `["pickup"]`)
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Layer, def = 3, key = "requiredTags", text = "a"}) != "", "not an Entities layer")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Layer, def = 3, key = "tilePivotX", number = 1}) != "", "not a Tiles layer")
	set(t, d, 2, "tilePivotX", "", 1)
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Layer, def = 3, key = "nonsense", text = "1"}) != "", "no such member")

	// An IntGrid layer with a tileset becomes an auto-layer; a new AutoLayer built from it takes its grid
	set(t, d, 3, "tilesetDefUid", "5")
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=3.__tilesetDefUid"), "5")
	defsMust(t, d, {op = .Def_Added, kind = .Layer, text = "AutoLayer"})
	auto := 60
	set(t, d, 3, "gridSize", "", 8)
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=3.__cWid"), "32")
	set(t, d, auto, "autoSourceLayerDefUid", "3")
	testing.expect_value(t, defsValue(d, "defs.layers.uid=60.gridSize"), "8")
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=60.__cWid"), "32")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Layer, def = auto, key = "gridSize", number = 16}) != "", "an auto-layer takes its source's grid")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Layer, def = auto, key = "autoSourceLayerDefUid", text = "2"}) != "", "a source must be IntGrid")
	// The source's grid changes: the auto-layer follows
	set(t, d, 3, "gridSize", "", 16)
	testing.expect_value(t, defsValue(d, "defs.layers.uid=60.gridSize"), "16")
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=60.__cWid"), "16")
	set(t, d, auto, "autoTilesKilledByOtherLayerUid", "2")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Layer, def = auto, key = "autoTilesKilledByOtherLayerUid", text = "3"}) != "", "only a Tiles layer")
	// A biome field: a level field of an enum
	set(t, d, auto, "biomeFieldUid", "52")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Layer, def = auto, key = "biomeFieldUid", text = "51"}) != "", "not an enum field")
	// Its tileset removed: the IntGrid layer is no auto-layer, the AutoLayer has no tileset
	set(t, d, 3, "tilesetDefUid", "")
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=3.__tilesetDefUid"), "null")

	// IntGrid values: added (the next value, a nice color), into a group, removed with their cells
	defsMust(t, d, {op = .IntGrid_Value_Added, def = 3})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValues.3.value"), "4")
	testing.expect(t, defsValue(d, "defs.layers.uid=3.intGridValues.3.color") != "", "a color")
	defsMust(t, d, {op = .IntGrid_Group_Added, def = 3})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValuesGroups"), `[{"uid":1,"identifier":null,"color":null}]`)
	defsMust(t, d, {op = .IntGrid_Group_Set, def = 3, index = 1, key = "identifier", text = "solid things"})
	defsMust(t, d, {op = .IntGrid_Group_Set, def = 3, index = 1, key = "color", text = "#AA0000"})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValuesGroups.0.identifier"), "solid_things")
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValuesGroups.0.color"), "#aa0000")
	defsMust(t, d, {op = .IntGrid_Value_Moved, def = 3, index = 4, number = 1, number2 = 0})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValues.value=4.groupUid"), "1")
	defsMust(t, d, {op = .IntGrid_Value_Moved, def = 3, index = 2, number = 1, number2 = 0})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValues.2.value"), "2") // before 4 in the group, after 3 (the order of all values)
	defsMust(t, d, {op = .IntGrid_Value_Moved, def = 3, index = 2, number = 0, number2 = 0})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValues.0.value"), "2")
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=3.intGridCsv.112"), "1")
	defsMust(t, d, {op = .IntGrid_Value_Removed, def = 3, index = 1})
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=3.intGridCsv.112"), "0") // its cells are empty
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=3.intGridCsv.82"), "2") // the others stay
	defsMust(t, d, {op = .IntGrid_Value_Tile, def = 3, index = 2, text = "0,0,16,16", number = 5})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValues.value=2.tile"), `{"tilesetUid":5,"x":0,"y":0,"w":16,"h":16}`)
	defsMust(t, d, {op = .IntGrid_Value_Tile, def = 3, index = -1})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValues.value=2.tile"), "null")
	defsMust(t, d, {op = .IntGrid_Group_Removed, def = 3, index = 1})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValues.value=4.groupUid"), "0")
	testing.expect_value(t, defsValue(d, "defs.layers.uid=3.intGridValuesGroups"), "[]")

	// A copy (after it, numbered, new uids), moved, removed: every level's instances follow
	defsMust(t, d, {op = .Def_Duplicated, kind = .Layer, def = 3})
	copyUid := defsValue(d, "defs.layers.identifier=Walls2.uid")
	testing.expect(t, copyUid != "", "Walls2")
	testing.expect_value(t, defsValue(d, fmt.tprintf("levels.identifier=Tower.layerInstances.layerDefUid=%s.__identifier", copyUid)), "Walls2")
	testing.expect_value(t, defsValue(d, fmt.tprintf("levels.identifier=Tower.layerInstances.layerDefUid=%s.intGridCsv.0", copyUid)), "0") // a copy's levels are empty
	// (AutoLayer 60, Entities 1, Tiles 2, Walls 3, Walls2: Entities two places down)
	defsMust(t, d, {op = .Layer_Move, def = 1, number = 2})
	testing.expect_value(t, defsValue(d, "levels.identifier=Cave.layerInstances.3.layerDefUid"), "1")
	defsMust(t, d, {op = .Def_Removed, kind = .Layer, def = 2})
	testing.expect_value(t, defsValue(d, "levels.identifier=Cave.layerInstances.layerDefUid=2"), "")
	// The auto-layer keeps the lost layer's uid as what kills its tiles: LDtk's tidy leaves it too
	testing.expect_value(t, defsValue(d, "defs.layers.uid=60.autoTilesKilledByOtherLayerUid"), "2")
	testing.expect_value(t, LDtkDoc_Save(d.dir, "world.ldtk"), "")
	expectValidFile(t, d.path)
}

/*
Entity types and fields changed as LDtk changes them: sizes the instances follow, resizable limits,
the table of contents, copies with new field uids, removal (instances and references to them go);
fields' defaults by type, ranges swapped and clamped, nullability, display modes per type, array
limits, references' rules, regular expressions, file types, moves, conversions of type, removal.
*/
@(test)
ldtk_entity_definitions_and_fields_change_as_ldtk_changes_them :: proc(t: ^testing.T) {
	d := defsCopy("ldtk_defs_entities")
	defer removeAll(d.dir)
	defer LDtkDoc_DestroyAll()
	entity :: proc(t: ^testing.T, d: Defs, uid: int, key, text: string, number: f64 = 0, flag := false, index := 0, loc := #caller_location) {
		defsMust(t, d, {op = .Def_Set, kind = .Entity, def = uid, key = key, text = text, number = number, flag = flag, index = index}, loc)
	}
	field :: proc(t: ^testing.T, d: Defs, uid: int, key, text: string, number: f64 = 0, flag := false, loc := #caller_location) {
		defsMust(t, d, {op = .Def_Set, kind = .Field, field = uid, key = key, text = text, number = number, flag = flag}, loc)
	}
	coin1 := "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=coin1"
	player := "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1"

	// Size: instances of the type's size follow it; bounds 1..2048
	entity(t, d, 11, "width", "", 24)
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.width", coin1)), "24")
	entity(t, d, 11, "height", "", 5000)
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.height"), "2048")
	// Resizable: the minimum starts at the size, off clears the limits; limits stay ordered
	entity(t, d, 11, "resizableX", "", 0, true)
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.minWidth"), "24")
	entity(t, d, 11, "maxWidth", "10")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.maxWidth"), "24")
	entity(t, d, 11, "maxWidth", "0")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.maxWidth"), "null")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Entity, def = 11, key = "keepAspectRatio", flag = true}) != "", "only resizable both ways")
	entity(t, d, 11, "resizableX", "", 0, false)
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.minWidth"), "null")
	// Shape and look
	entity(t, d, 11, "hollow", "", 0, true)
	entity(t, d, 11, "lineOpacity", "0.5")
	entity(t, d, 11, "tileRenderMode", "NineSlice")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.nineSliceBorders"), "[2,2,2,2]")
	entity(t, d, 11, "nineSliceBorders", "", 4, false, 0)
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.nineSliceBorders"), "[4,4,4,4]")
	entity(t, d, 11, "nineSliceBorders", "", 1, false, 2)
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.nineSliceBorders"), "[4,4,1,4]")
	entity(t, d, 11, "tileRenderMode", "Cover")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.nineSliceBorders"), "[]")
	entity(t, d, 11, "render", "5")
	entity(t, d, 11, "tileRect", "16,0,16,16")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.tileRect"), `{"tilesetUid":5,"x":16,"y":0,"w":16,"h":16}`)
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.__tile", coin1)), `{"tilesetUid":5,"x":16,"y":0,"w":16,"h":16}`)
	entity(t, d, 11, "uiTileset", "5")
	entity(t, d, 11, "uiTileRect", "0,16,16,16")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.uiTileRect"), `{"tilesetUid":5,"x":0,"y":16,"w":16,"h":16}`)
	entity(t, d, 11, "maxCount", "", 3)
	entity(t, d, 11, "limitScope", "PerWorld")
	entity(t, d, 11, "limitBehavior", "PreventAdding")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Entity, def = 11, key = "limitScope", text = "PerGalaxy"}) != "", "not a scope")
	entity(t, d, 11, "tags", "pickup, shiny")
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.__tags", coin1)), `["pickup","shiny"]`)
	entity(t, d, 11, "pivotX", "", 0)
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.__pivot", coin1)), "[0,1]")
	entity(t, d, 11, "color", "#00ff00")
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.__smartColor", coin1)), "#00FF00")
	// The table of contents: turning it off takes the fields out too
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.fieldDefs.0.exportToToc"), "true")
	entity(t, d, 11, "exportToToc", "", 0, false)
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.fieldDefs.0.exportToToc"), "false")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Field, field = 47, key = "exportToToc", flag = true}) != "", "the type isn't exported")

	// Fields' defaults by type: the instances using the default follow
	field(t, d, 47, "defaultOverride", "12abc")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.fieldDefs.0.defaultOverride"), `{"id":"V_Int","params":[12]}`)
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.0.__value", coin1)), "12")
	testing.expect_value(t, defsValue(d, "levels.identifier=Cave.layerInstances.layerDefUid=1.entityInstances.iid=coin2.fieldInstances.0.__value"), "5") // its own value
	// A range: swapped when reversed, the default clamped into it, values read clamped
	field(t, d, 47, "max", "8")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.fieldDefs.0.defaultOverride.params.0"), "8")
	field(t, d, 47, "min", "10")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.fieldDefs.0.min"), "8")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=11.fieldDefs.0.max"), "10")
	testing.expect_value(t, defsValue(d, "levels.identifier=Cave.layerInstances.layerDefUid=1.entityInstances.iid=coin2.fieldInstances.0.__value"), "8") // 5, clamped
	field(t, d, 47, "min", "")
	field(t, d, 47, "max", "")
	testing.expect_value(t, defsValue(d, "levels.identifier=Cave.layerInstances.layerDefUid=1.entityInstances.iid=coin2.fieldInstances.0.__value"), "5")
	field(t, d, 47, "defaultOverride", "")
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.0.__value", coin1)), "0")
	field(t, d, 47, "canBeNull", "", 0, true)
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.0.__value", coin1)), "null")
	// Player's fields: speed 40 (Float), lives 41 (Int), name 42 (String), mood 43 (enum), tint
	// 44 (Color), home 45 (Point), friend 46 (EntityRef)
	field(t, d, 44, "defaultOverride", "#123456")
	field(t, d, 42, "defaultOverride", "  Hero  ")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=42.defaultOverride.params.0"), "Hero")
	field(t, d, 43, "defaultOverride", "Sad")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Field, field = 43, key = "defaultOverride", text = "Bored"}) != "", "not a value")
	field(t, d, 45, "defaultOverride", "3,4")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=45.defaultOverride"), `{"id":"V_String","params":["3,4"]}`)
	field(t, d, 40, "defaultOverride", "2.5")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=40.defaultOverride"), `{"id":"V_Float","params":[2.5]}`)
	// Display modes allowed by type
	field(t, d, 45, "editorDisplayMode", "PointStar")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Field, field = 45, key = "editorDisplayMode", text = "ValueOnly"}) != "", "points don't show as a value")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Field, field = 41, key = "editorDisplayMode", text = "PointPath"}) != "", "only points")
	field(t, d, 41, "editorDisplayMode", "RadiusGrid")
	field(t, d, 41, "editorDisplayPos", "Beneath")
	field(t, d, 41, "editorDisplayScale", "0")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=41.editorDisplayScale"), "0.1")
	field(t, d, 41, "editorTextPrefix", "x ")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=41.editorTextPrefix"), "x ")
	field(t, d, 41, "editorDisplayColor", "#abcdef")
	field(t, d, 41, "searchable", "", 0, true)
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Field, field = 41, key = "editorShowInWorld", flag = false}) != "", "only level fields")
	// References' rules: symmetry only to the same type
	field(t, d, 46, "allowedRefs", "OnlySpecificEntity")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=46.allowedRefsEntityUid"), "10")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Field, field = 46, key = "symmetricalRef", flag = true}) != "", "only OnlySame refs are symmetrical")
	field(t, d, 46, "allowedRefs", "OnlySame")
	field(t, d, 46, "symmetricalRef", "", 0, true)
	field(t, d, 46, "allowedRefs", "OnlyTags")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=46.symmetricalRef"), "false")
	field(t, d, 46, "allowedRefTags", "pickup")
	field(t, d, 46, "allowOutOfLevelRef", "", 0, false)
	// A regular expression and its i flag
	field(t, d, 42, "regex", "[a-z]+")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=42.regex"), "/[a-z]+/g")
	field(t, d, 42, "regexFlagI", "", 0, true)
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=42.regex"), "/[a-z]+/gi")
	// File types of a FilePath field
	defsMust(t, d, {op = .Def_Added, kind = .Field, def = 10, text = "F_Path"})
	path := defsValue(d, "defs.entities.uid=10.fieldDefs.identifier=File_path.uid")
	pathUid, _ := strconv.parse_int(path)
	field(t, d, pathUid, "acceptFileTypes", "png, .JPG  ..x jpg")
	// LDtk's reading: "..x" is ".x" after its dot, written "..x"
	testing.expect_value(t, defsValue(d, fmt.tprintf("defs.entities.uid=10.fieldDefs.uid=%d.acceptFileTypes", pathUid)), `[".png",".jpg","..x"]`)
	// An array's limits
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Field, field = 41, key = "arrayMinLength", text = "1"}) != "", "not an array")

	// Conversions: Int to Float keeps values, Float to Int rounds, Bool to Int, to an array
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.defUid=41.__value", player)), "3")
	defsMust(t, d, {op = .Field_Converted, field = 41, text = "IntToFloat"})
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=41.type"), "F_Float")
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=41.__type"), "Float")
	defsMust(t, d, {op = .Def_Set, kind = .Field, field = 41, key = "defaultOverride", text = "2.6"})
	defsMust(t, d, {op = .Field_Converted, field = 41, text = "FloatToIntRound"})
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=41.defaultOverride"), `{"id":"V_Int","params":[3]}`)
	testing.expect(t, defsApply(d, {op = .Field_Converted, field = 41, text = "BoolToInt"}) != "", "not a Bool")
	defsMust(t, d, {op = .Field_Converted, field = 49, text = "BoolToInt"})
	testing.expect_value(t, defsValue(d, "levels.identifier=Cave.layerInstances.layerDefUid=1.entityInstances.iid=door2.fieldInstances.defUid=49.__value"), "1")
	defsMust(t, d, {op = .Field_Converted, field = 42, text = "ToArray"})
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.defUid=42.__value", player)), `["Hero"]`)
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=42.__type"), "Array<String>")
	defsMust(t, d, {op = .Def_Set, kind = .Field, field = 42, key = "arrayMaxLength", text = "3"})
	defsMust(t, d, {op = .Def_Set, kind = .Field, field = 42, key = "arrayMinLength", text = "5"})
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=42.arrayMaxLength"), "5")

	// Fields moved: every instance's fields in the definitions' order; renamed; removed
	defsMust(t, d, {op = .Def_Moved, kind = .Field, field = 40, number = 2})
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.2.defUid", player)), "40")
	defsMust(t, d, {op = .Field_Name, field = 40, text = "run speed"})
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.2.__identifier", player)), "run_speed")
	defsMust(t, d, {op = .Def_Duplicated, kind = .Field, field = 40})
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.3.identifier"), "run_speed2")
	defsMust(t, d, {op = .Def_Removed, kind = .Field, field = 44})
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.defUid=44", player)), "")

	// An entity type copied (new uids for its fields), moved, removed: its instances go, so do references to them
	defsMust(t, d, {op = .Def_Duplicated, kind = .Entity, def = 12})
	testing.expect_value(t, defsValue(d, "defs.entities.3.identifier"), "Door2")
	testing.expect(t, defsValue(d, "defs.entities.3.fieldDefs.0.uid") != "48", "its fields' new uids")
	defsMust(t, d, {op = .Def_Moved, kind = .Entity, def = 12, number = -2})
	testing.expect_value(t, defsValue(d, "defs.entities.0.identifier"), "Door")
	testing.expect(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=door1.fieldInstances.defUid=48.__value") != "null", "door1 points at door2")
	defsMust(t, d, {op = .Def_Removed, kind = .Entity, def = 12})
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=door1"), "")
	testing.expect_value(t, defsValue(d, "toc"), "[]") // Coin left the table of contents above

	// Level fields as entity fields: a default every level without a value shows
	defsMust(t, d, {op = .Def_Set, kind = .Field, field = 51, key = "defaultOverride", text = "4"})
	testing.expect_value(t, defsValue(d, "levels.identifier=Tower.fieldInstances.defUid=51.__value"), "4")
	testing.expect_value(t, defsValue(d, "levels.identifier=Cave.fieldInstances.defUid=51.__value"), "2")
	defsMust(t, d, {op = .Def_Set, kind = .Field, field = 51, key = "editorShowInWorld", flag = false})
	defsMust(t, d, {op = .Def_Moved, kind = .Field, field = 52, number = -2})
	testing.expect_value(t, defsValue(d, "levels.identifier=Tower.fieldInstances.0.defUid"), "52")
	defsMust(t, d, {op = .Def_Removed, kind = .Field, field = 50})
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.fieldInstances.defUid=50"), "")
	testing.expect_value(t, LDtkDoc_Save(d.dir, "world.ldtk"), "")
	expectValidFile(t, d.path)
}

/*
Enums as LDtk's EditEnumDefs edits them: values removed (fields using them lose them, defaults
too), moved, their icons; tags, the icons' tileset; copies and removal (fields of the enum go);
external enums imported from every format LDtk reads (text, JSON, Haxe, CastleDB), synced after
their file changed, removed; and LDtk's own sample synced, unchanged byte for byte.
*/
@(test)
ldtk_enums_and_external_enums_follow_ldtk :: proc(t: ^testing.T) {
	d := defsCopy("ldtk_defs_enums")
	defer removeAll(d.dir)
	defer LDtkDoc_DestroyAll()
	player := "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=player1"
	// Mood (30): Happy, Sad, Angry; Player's mood (43) is Happy
	defsMust(t, d, {op = .Def_Set, kind = .Field, field = 43, key = "defaultOverride", text = "Angry"})
	defsMust(t, d, {op = .Enum_Value_Moved, def = 30, index = 2, number = -2})
	testing.expect_value(t, defsValue(d, "defs.enums.uid=30.values.0.id"), "Angry")
	defsMust(t, d, {op = .Enum_Value_Removed, def = 30, index = 1})
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.defUid=43.__value", player)), "Angry") // its value is gone: the default
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.defUid=43.realEditorValues", player)), "[null]")
	defsMust(t, d, {op = .Enum_Value_Removed, def = 30, index = 0})
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.uid=43.defaultOverride"), "null")
	// A new value: the enum's name and a number (LDtk's create value), then renamed
	defsMust(t, d, {op = .Enum_Value_Added, def = 30, text = "Calm"})
	testing.expect(t, defsApply(d, {op = .Enum_Value_Tile, def = 30, index = 0, text = "0,0,16,16"}) != "", "no icons tileset yet")
	defsMust(t, d, {op = .Def_Set, kind = .Enum, def = 30, key = "iconTilesetUid", text = "5"})
	defsMust(t, d, {op = .Enum_Value_Tile, def = 30, index = 0, text = "0,0,16,16"})
	testing.expect_value(t, defsValue(d, "defs.enums.uid=30.values.0.tileRect"), `{"tilesetUid":5,"x":0,"y":0,"w":16,"h":16}`)
	defsMust(t, d, {op = .Def_Set, kind = .Enum, def = 30, key = "iconTilesetUid", text = ""})
	testing.expect_value(t, defsValue(d, "defs.enums.uid=30.values.0.tileRect"), "null") // the icons went with their tileset
	defsMust(t, d, {op = .Def_Set, kind = .Enum, def = 30, key = "tags", text = "moods"})
	testing.expect_value(t, defsValue(d, "defs.enums.uid=30.tags"), `["moods"]`)
	// A copy, moved; removing an enum removes the fields of it
	defsMust(t, d, {op = .Def_Duplicated, kind = .Enum, def = 31})
	testing.expect_value(t, defsValue(d, "defs.enums.2.identifier"), "Weather2")
	defsMust(t, d, {op = .Def_Moved, kind = .Enum, def = 31, number = 1})
	testing.expect_value(t, defsValue(d, "defs.enums.2.identifier"), "Weather")
	defsMust(t, d, {op = .Def_Removed, kind = .Enum, def = 31})
	testing.expect_value(t, defsValue(d, "defs.levelFields.uid=52"), "")
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.fieldInstances.defUid=52"), "")

	// External enums: copied beside the project file, imported, synced, removed
	for name in ([]string{"enums.txt", "enums.json", "Enums.hx", "enums.cdb"}) {
		text, _ := os.read_entire_file(joinPath("tests/fixtures/ldtk_enums", name, allocator = context.temp_allocator), context.temp_allocator)
		_ = os.write_entire_file(joinPath(d.dir, name, allocator = context.temp_allocator), text)
	}
	defsMust(t, d, {op = .Enum_Import, text = "enums.txt"})
	testing.expect_value(t, defsValue(d, "defs.externalEnums.0.identifier"), "Fruit")
	testing.expect_value(t, defsValue(d, "defs.externalEnums.0.externalRelPath"), "enums.txt")
	testing.expect_value(t, defsValue(d, "defs.externalEnums.0.values.2.id"), "Cherry") // cleaned up with the project's style
	testing.expect_value(t, defsValue(d, "defs.externalEnums.1.identifier"), "Tool")
	testing.expect_value(t, defsValue(d, "defs.externalEnums.1.values.1.id"), "Saw")
	text, _ := os.read_entire_file(joinPath(d.dir, "enums.txt", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, defsValue(d, "defs.externalEnums.0.externalFileChecksum"), LDtk_Checksum(string(text)))
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Enum, def = Json_Int_Of(d, "defs.externalEnums.0.uid"), key = "tags", text = "x"}) != "", "an external enum is its file's")
	// A field of it, set to one of its values
	defsMust(t, d, {op = .Def_Added, kind = .Field, def = 10, text = fmt.tprintf("F_Enum(%d)", Json_Int_Of(d, "defs.externalEnums.0.uid"))})
	testing.expect_value(t, defsValue(d, "defs.entities.uid=10.fieldDefs.identifier=Fruit.__type"), "ExternEnum.Fruit")
	fruit := Json_Int_Of(d, "defs.entities.uid=10.fieldDefs.identifier=Fruit.uid")
	defsMust(t, d, {op = .Entity_Field, entity = "player1", field = fruit, text = "Banana"})
	// The file changes: Banana goes, Date comes; the field loses its value; the order is the file's
	_ = os.write_entire_file(joinPath(d.dir, "enums.txt", allocator = context.temp_allocator), transmute([]byte)string("Fruit : date, apple, cherry\nTool: hammer;saw\n"))
	doc := LDtkDoc_Get(d.dir, "world.ldtk")
	preview := LDtkEnums_SyncPreview(doc, "enums.txt")
	testing.expect_value(t, preview.added, 1)
	testing.expect_value(t, preview.removed, 1)
	testing.expect_value(t, preview.removedUsed, 1)
	defsMust(t, d, {op = .Enum_Sync, text = "enums.txt"})
	testing.expect_value(t, defsValue(d, "defs.externalEnums.0.values.0.id"), "Date")
	testing.expect_value(t, defsValue(d, "defs.externalEnums.0.values.1.id"), "Apple")
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.fieldInstances.defUid=%d.__value", player, fruit)), "null")
	// Every other format LDtk imports
	defsMust(t, d, {op = .Enum_Import, text = "enums.json"})
	testing.expect_value(t, defsValue(d, "defs.externalEnums.identifier=Gem.values.1.id"), "Emerald")
	testing.expect_value(t, defsValue(d, "defs.externalEnums.identifier=Metal.values.1.id"), "Gold")
	testing.expect_value(t, defsValue(d, "defs.externalEnums.identifier=Ignored"), "")
	defsMust(t, d, {op = .Enum_Import, text = "Enums.hx"})
	testing.expect_value(t, defsValue(d, "defs.externalEnums.identifier=Weapon.values.0.id"), "Sword")
	testing.expect_value(t, defsValue(d, "defs.externalEnums.identifier=Weapon.values.1.id"), "Bow")
	testing.expect_value(t, defsValue(d, "defs.externalEnums.identifier=Weapon.values.2"), "") // Hidden is in a comment
	testing.expect_value(t, defsValue(d, "defs.externalEnums.identifier=Effect"), "") // a value with parameters
	defsMust(t, d, {op = .Enum_Import, text = "enums.cdb"})
	testing.expect_value(t, defsValue(d, "defs.externalEnums.identifier=Monsters.values.0.color"), "65280") // CastleDB's colors
	testing.expect_value(t, defsValue(d, "defs.externalEnums.identifier=Monsters.values.1.id"), "Bat")
	testing.expect(t, defsApply(d, {op = .Enum_Import, text = "missing.txt"}) != "", "a missing file")
	// A file naming an enum the project has stops the import
	_ = os.write_entire_file(joinPath(d.dir, "clash.txt", allocator = context.temp_allocator), transmute([]byte)string("Mood: a, b\n"))
	testing.expect(t, strings.contains(defsApply(d, {op = .Enum_Import, text = "clash.txt"}), "already used"), "a clash")
	// Removed with its file's enums: the fields of them go
	defsMust(t, d, {op = .Enum_External_Removed, text = "enums.txt"})
	testing.expect_value(t, defsValue(d, "defs.externalEnums.identifier=Fruit"), "")
	testing.expect_value(t, defsValue(d, fmt.tprintf("defs.entities.uid=10.fieldDefs.uid=%d", fruit)), "")
	testing.expect_value(t, LDtkDoc_Save(d.dir, "world.ldtk"), "")
	expectValidFile(t, d.path)

	// LDtk's sample with an external enum, synced with its file as it is: not a byte changes
	if !os.exists(joinPath(LDTK_SAMPLES_DIR, "externEnums.txt", allocator = context.temp_allocator)) do return
	sampleDir := tempDir("ldtk_defs_sample_sync")
	defer removeAll(sampleDir)
	for name in ([]string{"Test_file_for_API_showing_all_features.ldtk", "externEnums.txt"}) {
		data, _ := os.read_entire_file(joinPath(LDTK_SAMPLES_DIR, name, allocator = context.temp_allocator), context.temp_allocator)
		_ = os.write_entire_file(joinPath(sampleDir, name, allocator = context.temp_allocator), data)
	}
	sampleDoc := LDtkDoc_Get(sampleDir, "Test_file_for_API_showing_all_features.ldtk")
	before := strings.clone(LDtkDoc_Main(sampleDoc).text, context.temp_allocator)
	problem, _ := LDtkOps_Apply(sampleDir, {op = .Enum_Sync, file = "Test_file_for_API_showing_all_features.ldtk", text = "externEnums.txt"})
	testing.expect_value(t, problem, "")
	testing.expect(t, LDtkDoc_Main(LDtkDoc_Get(sampleDir, "Test_file_for_API_showing_all_features.ldtk")).text == before, "LDtk's file unchanged")
}

// An int at a path of the copy's document
@(private="file")
Json_Int_Of :: proc(d: Defs, at: string) -> int {
	n, _ := strconv.parse_int(defsValue(d, at))
	return n
}

/*
Tilesets as LDtk's EditTilesetDefs edits them: renamed, their grid changed (tiles keep their
column and row: Tiles layers, enum tags, custom data), spacing and padding (the tiles' sources and
the pixel data follow), their image changed, tags from an enum and custom data per tile, removed
(the layers, entities and fields using them let go).
*/
@(test)
ldtk_tilesets_change_as_ldtk_changes_them :: proc(t: ^testing.T) {
	d := defsCopy("ldtk_defs_tilesets")
	defer removeAll(d.dir)
	defer LDtkDoc_DestroyAll()
	tiles := "levels.identifier=Start.layerInstances.layerDefUid=2.gridTiles"
	set :: proc(t: ^testing.T, d: Defs, key, text: string, number: f64 = 0, loc := #caller_location) {
		defsMust(t, d, {op = .Def_Set, kind = .Tileset, def = 5, key = key, text = text, number = number}, loc)
	}
	// tiles.png is 32 x 32: four 16 px tiles; Start's Tiles layer has tile 0 along its bottom row
	set(t, d, "identifier", "ground tiles")
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.identifier"), "Ground_tiles")
	testing.expect(t, defsApply(d, {op = .Def_Set, kind = .Tileset, def = 5, key = "identifier", text = "  "}) != "", "no name")
	// Tags from an enum (Mood) and custom data
	set(t, d, "tagsSourceEnumUid", "30")
	defsMust(t, d, {op = .Tileset_Tag, def = 5, text = "Sad", flag = true, ids = {3, 1}})
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.enumTags"), `[{"enumValueId":"Happy","tileIds":[]},{"enumValueId":"Sad","tileIds":[1,3]},{"enumValueId":"Angry","tileIds":[]}]`)
	defsMust(t, d, {op = .Tileset_Tag, def = 5, text = "Sad", flag = false, ids = {1}})
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.enumTags.1.tileIds"), "[3]")
	testing.expect(t, defsApply(d, {op = .Tileset_Tag, def = 5, text = "Bored", flag = true, ids = {0}}) != "", "not a value")
	defsMust(t, d, {op = .Tileset_Custom_Data, def = 5, text = "  {\"solid\": true}  ", ids = {3}})
	defsMust(t, d, {op = .Tileset_Custom_Data, def = 5, text = "line one\nline two", ids = {1}})
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.customData.0.data"), "line one\nline two")
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.customData.1.tileId"), "3")
	defsMust(t, d, {op = .Tileset_Custom_Data, def = 5, text = " ", ids = {1}})
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.customData.0.tileId"), "3")
	// Spacing: the tiles' sources move, the pixel data is made again
	set(t, d, "spacing", "", 4)
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.__cWid"), "2")
	set(t, d, "spacing", "", 0)
	// The grid halved: each tile keeps its column and row (tile 3, column 1 row 1, is now 5)
	set(t, d, "tileGridSize", "", 8)
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.__cWid"), "4")
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.enumTags.1.tileIds"), "[5]")
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.customData.0.tileId"), "5")
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.0.t", tiles)), "0")
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.cachedPixelData.opaqueTiles"), "1111111111111111")
	set(t, d, "tileGridSize", "", 16)
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.enumTags.1.tileIds"), "[3]")
	// Removing the tag enum's value clears its tags; another tag enum keeps nothing
	set(t, d, "tagsSourceEnumUid", "31")
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.enumTags"), `[{"enumValueId":"Sunny","tileIds":[]},{"enumValueId":"Rainy","tileIds":[]}]`)
	set(t, d, "tagsSourceEnumUid", "")
	testing.expect_value(t, defsValue(d, "defs.tilesets.0.enumTags"), "[]")
	set(t, d, "tags", "terrain")
	// Removed: the Tiles layer has no tileset (its tiles have no source), a Tile field none
	defsMust(t, d, {op = .Def_Added, kind = .Field, def = 11, text = "F_Tile"})
	tile := Json_Int_Of(d, "defs.entities.uid=11.fieldDefs.identifier=Tile.uid")
	defsMust(t, d, {op = .Def_Set, kind = .Field, field = tile, key = "tilesetUid", text = "5"})
	defsMust(t, d, {op = .Def_Set, kind = .Field, field = tile, key = "defaultOverride", text = "16,16,16,16"})
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=1.entityInstances.iid=coin1.__tile"), `{"tilesetUid":5,"x":16,"y":16,"w":16,"h":16}`)
	defsMust(t, d, {op = .Def_Removed, kind = .Tileset, def = 5})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=2.tilesetDefUid"), "null")
	testing.expect_value(t, defsValue(d, fmt.tprintf("%s.0.src", tiles)), "[-1,-1]")
	testing.expect_value(t, defsValue(d, fmt.tprintf("defs.entities.uid=11.fieldDefs.uid=%d.tilesetUid", tile)), "null")
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=2.__tilesetDefUid"), "null")
	// A new one from the image, set on the layer: the layer takes its grid
	defsMust(t, d, {op = .Def_Added, kind = .Tileset, text = "tiles.png"})
	ts := Json_Int_Of(d, "defs.tilesets.0.uid")
	defsMust(t, d, {op = .Def_Set, kind = .Tileset, def = ts, key = "tileGridSize", number = 8})
	defsMust(t, d, {op = .Def_Set, kind = .Layer, def = 2, key = "tilesetDefUid", text = fmt.tprint(ts)})
	testing.expect_value(t, defsValue(d, "defs.layers.uid=2.gridSize"), "8")
	testing.expect_value(t, defsValue(d, "levels.identifier=Start.layerInstances.layerDefUid=2.__cWid"), "32")
	testing.expect_value(t, LDtkDoc_Save(d.dir, "world.ldtk"), "")
	expectValidFile(t, d.path)
}

/*
Definition edits through the editor: one undo step each, the document as it was byte for byte after
undoing them all, as they made it after redoing them.
*/
@(test)
ldtk_definition_edits_undo_byte_for_byte :: proc(t: ^testing.T) {
	d := defsCopy("ldtk_defs_undo")
	defer removeAll(d.dir)
	defer LDtkDoc_DestroyAll()
	project := Project_CreateEmpty(d.dir, "Levels")
	state := State{project = project, browserSelection = {kind = .None}, selectedNode = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	state.mode = .Level
	defer State_Destroy(&state)
	send :: proc(state: ^State, m: Msg) { state^, _ = update(state^, m) }
	append(&state.project.assets, AssetDef{path = strings.clone("world.ldtk"), kind = .LDtk})
	_ = LDtkDoc_Get(d.dir, "world.ldtk")
	original := strings.clone(LDtkDoc_Main(LDtkDoc_Get(d.dir, "world.ldtk")).text, context.temp_allocator)
	edits := []LDtk_Edit{
		{op = .Def_Added, kind = .Layer, text = "IntGrid"},
		{op = .Def_Set, kind = .Layer, def = 3, key = "gridSize", number = 8},
		{op = .IntGrid_Value_Removed, def = 3, index = 2},
		{op = .Def_Added, kind = .Field, def = 11, text = "F_Color"},
		{op = .Def_Removed, kind = .Entity, def = 12},
		{op = .Def_Set, kind = .Tileset, def = 5, key = "tileGridSize", number = 8},
		{op = .Field_Converted, field = 41, text = "IntToFloat"},
	}
	texts := make([dynamic]string, context.temp_allocator)
	for edit in edits {
		e := edit
		e.file = "world.ldtk"
		before := len(state.history.undo)
		send(&state, e)
		testing.expectf(t, len(state.history.undo) == before + 1, "%v: one step (%s)", edit.op, state.level.problem)
		append(&texts, strings.clone(LDtkDoc_Main(LDtkDoc_Get(d.dir, "world.ldtk")).text, context.temp_allocator))
	}
	for _ in edits do send(&state, Action.Undo)
	testing.expect(t, LDtkDoc_Main(LDtkDoc_Get(d.dir, "world.ldtk")).text == original, "all undone: as it was")
	testing.expect(t, !LDtkDoc_IsUnsaved(d.dir, "world.ldtk"), "nothing to save")
	for text, i in texts {
		send(&state, Action.Redo)
		testing.expectf(t, LDtkDoc_Main(LDtkDoc_Get(d.dir, "world.ldtk")).text == text, "redo %d: as the edit made it", i)
	}
}

/*
Auto-layers follow the definitions their tiles come from: an IntGrid value removed empties its cells
and the rules run again (the layer's own and an AutoLayer built from it), a grid change applies them
again on the remapped cells; the tiles are then what applying every rule from nothing gives.
*/
@(test)
ldtk_auto_layers_follow_definition_edits :: proc(t: ^testing.T) {
	dir := tempDir("ldtk_defs_auto")
	_ = removeAll(dir)
	assert(Folder_Copy("tests/fixtures/ldtk_paint", dir) == "")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	apply :: proc(t: ^testing.T, dir: string, edit: LDtk_Edit, loc := #caller_location) {
		e := edit
		e.file = "paint.ldtk"
		problem, _ := LDtkOps_Apply(dir, e)
		testing.expectf(t, problem == "", "%v: %s", edit.op, problem, loc = loc)
		defsCheck(t, dir, "paint.ldtk", loc)
	}
	// The auto-layers are as applying every rule from nothing makes them
	settled :: proc(t: ^testing.T, dir: string, loc := #caller_location) -> int {
		doc := LDtkDoc_Get(dir, "paint.ldtk")
		tiles := 0
		for _, level in doc.levels {
			m, ok := LDtkLevel_Read(doc, "", level)
			if !ok do continue
			defer LDtkLevel_Destroy(&m)
			for &l in m.layers {
				d := LDtkLevel_Def(&m, &l)
				if !LDtkLayerInfo_IsAuto(d) do continue
				LDtkRules_ApplyAll(&m, &l)
				l.changed += {.Auto}
				for cell in l.auto do tiles += len(cell)
			}
			p := LDtkLevel_Patches(&m, doc)
			testing.expect(t, LDtkPatches_Empty(&p), "the auto-layers are the rules' result", loc = loc)
		}
		return tiles
	}
	// Ground (3: values 1 to 4, rules; Shade 4 built from it); the Hall has cells of 2
	apply(t, dir, {op = .Def_Set, kind = .Layer, def = 3, key = "gridSize", number = 8})
	before := settled(t, dir)
	testing.expect(t, before > 0, "the rules drew tiles")
	apply(t, dir, {op = .Def_Set, kind = .Layer, def = 3, key = "gridSize", number = 16})
	testing.expect_value(t, valueAt(joinPath(dir, "paint.ldtk", allocator = context.temp_allocator), "defs.layers.uid=4.gridSize"), "16")
	settled(t, dir)
	apply(t, dir, {op = .IntGrid_Value_Removed, def = 3, index = 2})
	after := settled(t, dir)
	doc := LDtkDoc_Get(dir, "paint.ldtk")
	for c in Json_Items(LDtkDoc_Main(doc), Json_Path(LDtkDoc_Main(doc), "levels.identifier=Hall.layerInstances.layerDefUid=3.intGridCsv")) do testing.expect(t, Json_Int(LDtkDoc_Main(doc), c) != 2, "no cell of the removed value")
	log.infof("auto tiles: %d at an 8 px grid, %d with value 2 removed", before, after)
	testing.expect_value(t, after, 0)
	// The layer loses its tileset: no rules, no tiles (LDtk drops them on save)
	apply(t, dir, {op = .Def_Set, kind = .Layer, def = 3, key = "tilesetDefUid", text = ""})
	testing.expect_value(t, valueAt(joinPath(dir, "paint.ldtk", allocator = context.temp_allocator), "levels.identifier=Hall.layerInstances.layerDefUid=3.autoLayerTiles"), "[]")
	testing.expect_value(t, valueAt(joinPath(dir, "paint.ldtk", allocator = context.temp_allocator), "defs.layers.uid=3.autoRuleGroups"), "[]")
}
