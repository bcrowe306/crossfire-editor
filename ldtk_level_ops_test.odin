package crossfire_editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import e "engine:."

// Phase 5 of the LDtk level editor: levels, worlds and the Project tab's settings
// (ldtk_level_ops.odin, ldtk_project_ops.odin), as LDtk makes them, checked against LDtk's own
// samples (when the workspace has its source: ../ldtk) and the fixtures.

@(private="file")
SAMPLES :: "../ldtk/app/extraFiles/samples"

// Whether LDtk's samples are here (the checks against LDtk's own files need them)
@(private="file")
haveSamples :: proc() -> bool {
	if os.exists(joinPath(SAMPLES, "Typical_2D_platformer_example.ldtk", allocator = context.temp_allocator)) do return true
	log.infof("LDtk's samples aren't here (%s): skipped", SAMPLES)
	return false
}

// Where two texts first differ (temp)
@(private="file")
diffAt :: proc(a, b: string) -> string {
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] do i += 1
	from := max(0, i - 100)
	return fmt.tprintf("at %d of %d / %d:\n  ours: %q\n  want: %q", i, len(a), len(b), a[from:min(len(a), i + 100)], b[from:min(len(b), i + 100)])
}

// An edit of a document (why it wasn't made, "" when it was)
@(private="file")
lvApply :: proc(root, file: string, edit: LDtk_Edit) -> string {
	x := edit
	x.file = file
	problem, _ := LDtkOps_Apply(root, x)
	return problem
}

/*
An edit made, then the document checked: its files against LDtk's schema, read by the engine, and
already tidy (LDtk's tidy changes nothing in it).
*/
@(private="file")
lvMust :: proc(t: ^testing.T, root, file: string, edit: LDtk_Edit, loc := #caller_location) {
	problem := lvApply(root, file, edit)
	testing.expectf(t, problem == "", "%v %q: %s", edit.op, edit.key, problem, loc = loc)
	lvCheck(t, root, file, loc)
}

@(private="file")
lvCheck :: proc(t: ^testing.T, root, file: string, loc := #caller_location) {
	doc := LDtkDoc_Get(root, file)
	if !testing.expect(t, doc != nil && doc.problem == "", "the document reads", loc = loc) do return
	for f, i in doc.files {
		for p in LDtk_SchemaProblems(f.json.text, i == 0 ? "" : "Level") do testing.expectf(t, false, "%s: %s", filepath.base(f.path), p, loc = loc)
	}
	project, problem := e.LDtk_Parse(LDtkDoc_GameText(doc), doc.files[0].path)
	testing.expectf(t, project != nil, "the engine reads it: %s", problem, loc = loc)
	if project != nil do e.LDtk_Destroy(project)
	s := stagesMake(doc)
	testing.expect_value(t, LDtkTidy_Run(&s, {intGrid = true, gridTiles = true}), "", loc = loc)
	after := LDtkDoc_TextsByPath(s.cur)
	testing.expectf(t, len(after) == len(doc.files), "the tidy keeps the files (%d, %d)", len(after), len(doc.files), loc = loc)
	for f in doc.files {
		text, found := after[f.path]
		if !found || text != f.json.text do testing.expectf(t, false, "not tidy after the edit (%s): %s", filepath.base(f.path), diffAt(text, f.json.text), loc = loc)
	}
	for m in s.made do LDtkDoc_Free(m)
}

// A value of a document as the editor has it (its JSON text; "" when missing)
@(private="file")
lvValue :: proc(root, file, at: string) -> string {
	doc := LDtkDoc_Get(root, file)
	if doc == nil do return ""
	main := LDtkDoc_Main(doc)
	node := Json_Path(main, at)
	if node < 0 do return ""
	return strings.clone(Json_Text(main, node), context.temp_allocator)
}

// A copy of every text of a document (by path; temp)
@(private="file")
lvTexts :: proc(root, file: string) -> map[string]string {
	doc := LDtkDoc_Get(root, file)
	out := make(map[string]string, context.temp_allocator)
	for f in doc.files do out[strings.clone(f.path, context.temp_allocator)] = strings.clone(f.json.text, context.temp_allocator)
	return out
}

// The document is these texts again, byte for byte
@(private="file")
lvSameAs :: proc(t: ^testing.T, root, file: string, want: map[string]string, what: string, loc := #caller_location) {
	doc := LDtkDoc_Get(root, file)
	testing.expectf(t, len(doc.files) == len(want), "%s: %d files, %d before", what, len(doc.files), len(want), loc = loc)
	for f in doc.files {
		w, found := want[f.path]
		if !testing.expectf(t, found, "%s: %s wasn't there before", what, filepath.base(f.path), loc = loc) do continue
		if f.json.text != w do testing.expectf(t, false, "%s: %s isn't as it was %s", what, filepath.base(f.path), diffAt(f.json.text, w), loc = loc)
	}
}

// The editor in the Level mode on a project folder with one LDtk file
@(private="file")
lvState :: proc(dir, file: string) -> State {
	state := State{project = Project_CreateEmpty(dir, "Levels"), browserSelection = {kind = .None}, selectedNode = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	state.mode = .Level
	append(&state.project.assets, AssetDef{path = strings.clone(file), kind = .LDtk})
	return state
}

// Steps the State through a pointer (a State value per step is 35 KB of the test's frame)
@(private="file")
send :: proc(state: ^State, m: Msg) {
	state^, _ = update(state^, m)
}

// A level's index by identifier
@(private="file")
lvLevel :: proc(root, file, name: string) -> int {
	return LDtkDoc_FindLevel(LDtkDoc_Get(root, file), name)
}

/*
LDtk's writer (ldtk_json_pretty.odin) writes LDtk's own files again byte for byte, whole: every
sample and test file LDtk 1.5 saved, read as values and written back. The Project tab's options
that make LDtk write files whole (minified JSON, levels in separate files, Multi-worlds) rely on it.
*/
@(test)
ldtk_writer_remakes_ldtks_files_whole :: proc(t: ^testing.T) {
	if !haveSamples() do return
	files := make([dynamic]string, context.temp_allocator)
	for folder in ([]string{SAMPLES, "../ldtk/tests", "../ldtk/app/extraFiles/samples/SeparateLevelFiles"}) {
		entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
		if err != nil do continue
		for entry in entries do if strings.has_suffix(entry.name, ".ldtk") || strings.has_suffix(entry.name, ".ldtkl") do append(&files, joinPath(folder, entry.name, allocator = context.temp_allocator))
	}
	checked := 0
	for path in files {
		data, _ := os.read_entire_file(path, context.temp_allocator)
		text := string(data)
		if !strings.contains(text[:min(len(text), 4096)], `"appVersion": "1.5`) do continue
		json, problem := Json_Parse(text, context.temp_allocator)
		if !testing.expectf(t, problem == "", "%s reads", path) do continue
		out := LDtk_PrettyJson(ldtkJV(&json, 0), Json_Minified(&json), 0)
		testing.expectf(t, out == text, "%s written again %s", filepath.base(path), diffAt(out, text))
		checked += 1
	}
	log.infof("%d of LDtk's files written again whole, byte for byte", checked)
	testing.expect(t, checked >= 15, "LDtk's files were checked")
}

/*
New levels where LDtk puts them (LevelSpotPicker): centered on the point in a Free world (snapped
to the project's grid when shown), pushed off the level they'd overlap, on a GridVania grid,
refused on a level; in a linear world's order where the point is. A new level is LDtk's: its keys
in Level.toJson's order (the sample's), its uid from nextUid, its automatic name from the
project's pattern, a layer instance per layer and a field per level field, its neighbours.
*/
@(test)
ldtk_levels_are_added_where_ldtk_adds_them :: proc(t: ^testing.T) {
	if !haveSamples() do return
	defer LDtkDoc_DestroyAll()
	file := "Typical_2D_platformer_example.ldtk"
	doc := LDtkDoc_Get(SAMPLES, file)
	main := LDtkDoc_Main(doc)
	sampleKeys := make([dynamic]string, context.temp_allocator)
	for c in Json_Items(main, doc.levels[0].entry) do append(&sampleKeys, strings.clone(Json_Key(main, c), context.temp_allocator))
	nextUid := Json_Int(main, Json_Get(main, Json_Root(main), "nextUid"))
	layers := Json_Count(main, LDtkDoc_Defs(doc, "layers"))
	before := len(doc.levels)
	// Far from every level: centered on the point, on the 16 px grid
	spot := LDtk_LevelSpot(doc, 0, {5000, 5000}, 0, true)
	size := LDtkDoc_WorldLevelSize(doc, 0)
	testing.expect(t, spot.ok && !spot.overlaps, "there's room far away")
	testing.expect_value(t, spot.x, f64(LDtk_SnapToGrid(5000 - size.x / 2, 16)))
	lvMust(t, SAMPLES, file, {op = .Level_Added, world = 0, number = 5000, number2 = 5000, flag = true, text = "new-level-iid"})
	doc = LDtkDoc_Get(SAMPLES, file)
	main = LDtkDoc_Main(doc)
	testing.expect_value(t, len(doc.levels), before + 1)
	level := LDtkDoc_FindLevel(doc, "new-level-iid")
	if !testing.expect(t, level == before, "the new level is last in its world") do return
	entry := doc.levels[level].entry
	keys := make([dynamic]string, context.temp_allocator)
	for c in Json_Items(main, entry) do append(&keys, Json_Key(main, c))
	testing.expect_value(t, strings.join(keys[:], ",", context.temp_allocator), strings.join(sampleKeys[:], ",", context.temp_allocator))
	testing.expect_value(t, Json_Int(main, Json_Get(main, entry, "uid")), nextUid)
	testing.expect_value(t, Json_Int(main, Json_Get(main, Json_Root(main), "nextUid")), nextUid + 1)
	// The project's pattern %world_Level_%idx: its index in the world
	identifier, _ := LDtkDoc_LevelNames(doc, level)
	testing.expect_value(t, identifier, fmt.tprintf("World_Level_%d", before))
	testing.expect_value(t, Json_Count(main, Json_Get(main, entry, "layerInstances")), layers)
	testing.expect(t, Json_Bool(main, Json_Get(main, entry, "useAutoIdentifier")), "new levels are named automatically")
	// On a level: no room
	r := LDtkDoc_LevelRect(doc, 0)
	testing.expect(t, lvApply(SAMPLES, file, {op = .Level_Added, world = 0, number = r[0] + 5, number2 = r[1] + 5}) != "", "no level on a level")
	// Just right of a level: pushed beside it
	spot = LDtk_LevelSpot(doc, 0, {r[0] + r[2] + 10, r[1] + r[3] * 0.5}, 0, false)
	if spot.ok && !spot.overlaps do testing.expect_value(t, spot.x, r[0] + r[2])

	// GridVania: on the world grid
	file = "Typical_TopDown_example.ldtk"
	doc = LDtkDoc_Get(SAMPLES, file)
	grid := LDtkDoc_WorldGrid(doc, 0)
	lvMust(t, SAMPLES, file, {op = .Level_Added, world = 0, number = 4000, number2 = 4000, text = "grid-level"})
	doc = LDtkDoc_Get(SAMPLES, file)
	gr := LDtkDoc_LevelRect(doc, LDtkDoc_FindLevel(doc, "grid-level"))
	testing.expect(t, int(gr[0]) % grid.x == 0 && int(gr[1]) % grid.y == 0, "on the world grid")

	// A linear world: inserted where the point is, laid out by its order
	file = "SeparateLevelFiles.ldtk"
	doc = LDtkDoc_Get(SAMPLES, file)
	second := LDtkDoc_LevelRect(doc, 1)
	files := len(doc.files)
	lvMust(t, SAMPLES, file, {op = .Level_Added, world = 0, number = second[0] + 1, number2 = 10, text = "linear-level"})
	doc = LDtkDoc_Get(SAMPLES, file)
	testing.expect_value(t, LDtkDoc_FindLevel(doc, "linear-level"), 1)
	// Saved apart: a file of its own, named as LDtk names it
	testing.expect_value(t, len(doc.files), files + 1)
	testing.expect_value(t, lvValue(SAMPLES, file, "levels.1.externalRelPath"), `"SeparateLevelFiles/World_Level_1.ldtkl"`)
	testing.expect_value(t, lvValue(SAMPLES, file, "levels.2.externalRelPath"), `"SeparateLevelFiles/World_Level_2.ldtkl"`)
	testing.expect_value(t, lvValue(SAMPLES, file, "levels.1.worldX"), "-1")
	testing.expect(t, LDtkDoc_Unsaved(doc), "unsaved: nothing is written")
}

/*
Duplicated and deleted levels (World.duplicateLevel, removeLevel): the copy after the original with
new iids and uid, its own references pointing at its copies, references out of it dropped, moved
by four default cells; deleting it gives the file back but for `nextUid` (LDtk never reuses uids).
The world's last level can't go. References to a deleted level's entities go with it.
*/
@(test)
ldtk_levels_are_duplicated_and_deleted_as_ldtk_does :: proc(t: ^testing.T) {
	dir := worldCopy("ldtk_levels_dup")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	file := "world.ldtk"
	original := lvTexts(dir, file)
	doc := LDtkDoc_Get(dir, file)
	start := LDtkDoc_FindLevel(doc, "Start")
	r := LDtkDoc_LevelRect(doc, start)
	lvMust(t, dir, file, {op = .Level_Duplicated, level = "lvl-start", text = "copy-iid", flag = true})
	doc = LDtkDoc_Get(dir, file)
	copy := LDtkDoc_FindLevel(doc, "copy-iid")
	testing.expect_value(t, copy, start + 1)
	name, _ := LDtkDoc_LevelNames(doc, copy)
	testing.expect_value(t, name, "Start2")
	cr := LDtkDoc_LevelRect(doc, copy)
	testing.expect_value(t, cr[0], r[0] + 64)
	testing.expect_value(t, cr[1], r[1] + 64)
	// New iids for its entities; its door's reference to Cave's door dropped (out of the level)
	iids := make(map[string]bool, context.temp_allocator)
	for en in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, en.file)
		iid := Json_String(json, Json_Get(json, en.node, "iid"))
		testing.expectf(t, iid not_in iids, "%s is one entity's iid", iid)
		iids[strings.clone(iid, context.temp_allocator)] = true
		if en.level != copy || Json_String(json, Json_Get(json, en.node, "__identifier")) != "Door" do continue
		for fi in Json_Items(json, Json_Get(json, en.node, "fieldInstances")) {
			if Json_String(json, Json_Get(json, fi, "__type")) == "EntityRef" do testing.expect_value(t, Json_Text(json, Json_Get(json, fi, "__value")), "null")
		}
	}
	// Deleted: the file as it was but for nextUid
	lvMust(t, dir, file, {op = .Level_Removed, level = "copy-iid"})
	doc = LDtkDoc_Get(dir, file)
	main := LDtkDoc_Main(doc)
	text := doc.files[0].json.text
	uid := Json_Get(main, Json_Root(main), "nextUid")
	was := original[doc.files[0].path]
	wasDoc, _ := Json_Parse(was, context.temp_allocator)
	wasUid := Json_Get(&wasDoc, Json_Root(&wasDoc), "nextUid")
	testing.expect_value(t, Json_Int(main, uid), Json_Int(&wasDoc, wasUid) + 1)
	// (as values: the fixture isn't written by LDtk's writer, and the table of contents was written again)
	putBack := strings.concatenate({text[:main.nodes[uid].start], Json_Text(&wasDoc, wasUid), text[main.nodes[uid].end:]}, context.temp_allocator)
	back, _ := Json_Parse(putBack, context.temp_allocator)
	testing.expectf(t, jsonSameValue(&back, 0, &wasDoc, 0), "the file as it was but for nextUid %s", diffAt(text, was))
	// Deleting Cave: Start's door no longer points at Cave's
	lvMust(t, dir, file, {op = .Level_Removed, level = "Cave"})
	doc = LDtkDoc_Get(dir, file)
	for en in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, en.file)
		if Json_String(json, Json_Get(json, en.node, "__identifier")) != "Door" do continue
		for fi in Json_Items(json, Json_Get(json, en.node, "fieldInstances")) {
			if Json_String(json, Json_Get(json, fi, "__type")) == "EntityRef" do testing.expect_value(t, Json_Text(json, Json_Get(json, fi, "__value")), "null")
		}
	}
	// The world's last level stays
	lvMust(t, dir, file, {op = .Level_Removed, level = "Tower"})
	testing.expect(t, lvApply(dir, file, {op = .Level_Removed, level = "Start"}) != "", "the last level can't go")
}

/*
A level resized as LDtk resizes it (Level.applyNewBounds): grown up and left, its cells and
entities stay where they are in the world (they move in the level by the cells the edges moved),
its world position follows its edge; cropped, what's outside goes (cells, entities unless their
type allows it); auto-layers are worked out again. Grown back, the cells cropped away don't return.
*/
@(test)
ldtk_levels_are_resized_as_ldtk_resizes_them :: proc(t: ^testing.T) {
	dir := worldCopy("ldtk_levels_resize")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	file := "world.ldtk"
	doc := LDtkDoc_Get(dir, file)
	level := LDtkDoc_FindLevel(doc, "Start")
	r := LDtkDoc_LevelRect(doc, level)
	m, _ := LDtkLevel_Read(doc, "", level)
	walls := LDtkLevel_LayerByDef(&m, LDtkLevel_DefUid(&m, "Walls"))
	cw, ch := walls.cWid, walls.cHei
	bottom := LDtkLayer_IntGrid(walls, 3, ch - 1)
	LDtkLevel_Destroy(&m)
	testing.expect_value(t, bottom, 1)
	playerX := lvEntityX(dir, file, "player1")
	// Two cells more on the left and one on top
	lvMust(t, dir, file, {op = .Level_Resized, level = "Start", number = -32, number2 = -16, number3 = r[2] + 32, number4 = r[3] + 16})
	doc = LDtkDoc_Get(dir, file)
	level = LDtkDoc_FindLevel(doc, "Start")
	nr := LDtkDoc_LevelRect(doc, level)
	testing.expect_value(t, nr[0], r[0] - 32)
	testing.expect_value(t, nr[1], r[1] - 16)
	testing.expect_value(t, nr[2], r[2] + 32)
	m, _ = LDtkLevel_Read(doc, "", level)
	walls = LDtkLevel_LayerByDef(&m, LDtkLevel_DefUid(&m, "Walls"))
	testing.expect_value(t, walls.cWid, cw + 2)
	testing.expect_value(t, walls.cHei, ch + 1)
	testing.expect_value(t, LDtkLayer_IntGrid(walls, 3 + 2, ch), 1)
	testing.expect_value(t, LDtkLayer_IntGrid(walls, 0, ch), 0)
	LDtkLevel_Destroy(&m)
	testing.expect_value(t, lvEntityX(dir, file, "player1"), playerX + 32)
	// Cropped to 4 cells: the player (x 32+32) stays, the coin and door go
	lvMust(t, dir, file, {op = .Level_Resized, level = "Start", number = 0, number2 = 0, number3 = 64 + 32, number4 = r[3] + 16})
	testing.expect(t, lvEntityX(dir, file, "player1") >= 0, "the player is still in the level")
	testing.expect_value(t, lvEntityX(dir, file, "door1"), -1)
	// The project's grid is the smallest size
	testing.expect(t, lvApply(dir, file, {op = .Level_Resized, level = "Start", number3 = 8, number4 = 8}) != "", "too small")
}

// An entity's x in its level (-1 when it's gone)
@(private="file")
lvEntityX :: proc(root, file, iid: string) -> int {
	doc := LDtkDoc_Get(root, file)
	en, found := LDtkDoc_FindEntity(doc, iid)
	if !found do return -1
	json := LDtkDoc_Json(doc, en.file)
	return Json_Int(json, Json_At(json, Json_Get(json, en.node, "px"), 0))
}

// A layer definition's uid by its name in a level model (-1: none)
LDtkLevel_DefUid :: proc(m: ^LDtkLevelModel, identifier: string) -> int {
	for d in m.defs do if d.identifier == identifier do return d.uid
	return -1
}

/*
A level's settings as LDtk's level form sets them, each undone by its opposite giving LDtk's file
back byte for byte: a background color (the default is none of its own), a background image's
position and pivot (`__bgPos` worked out as LDtk works it out: LDtk's sample's), the depth further
and back, the automatic name and a name typed (refused while automatic).
*/
@(test)
ldtk_level_settings_change_as_ldtk_changes_them :: proc(t: ^testing.T) {
	if !haveSamples() do return
	defer LDtkDoc_DestroyAll()
	file := "Test_file_for_API_showing_all_features.ldtk"
	original := lvTexts(SAMPLES, file)
	at := lvLevel(SAMPLES, file, "Background_image")
	_, iid := LDtkDoc_LevelNames(LDtkDoc_Get(SAMPLES, file), at)
	level := strings.clone(iid, context.temp_allocator)
	wantPos := lvValue(SAMPLES, file, fmt.tprintf("levels.%d.__bgPos", at))
	lvMust(t, SAMPLES, file, {op = .Level_Set, level = level, key = "bgPos", text = "Contain"})
	testing.expect(t, lvValue(SAMPLES, file, fmt.tprintf("levels.%d.__bgPos", at)) != wantPos, "the image's place follows its position mode")
	lvMust(t, SAMPLES, file, {op = .Level_Set, level = level, key = "bgPos", text = "Cover"})
	testing.expect_value(t, lvValue(SAMPLES, file, fmt.tprintf("levels.%d.__bgPos", at)), wantPos)
	lvMust(t, SAMPLES, file, {op = .Level_Set, level = level, key = "bgPivot", number = 0, number2 = 1})
	lvMust(t, SAMPLES, file, {op = .Level_Set, level = level, key = "bgPivot", number = 0.5, number2 = 0.5})
	bg := lvValue(SAMPLES, file, fmt.tprintf("levels.%d.bgColor", at))
	lvMust(t, SAMPLES, file, {op = .Level_Set, level = level, key = "bgColor", text = "#102030"})
	testing.expect_value(t, lvValue(SAMPLES, file, fmt.tprintf("levels.%d.__bgColor", at)), `"#102030"`)
	lvMust(t, SAMPLES, file, {op = .Level_Set, level = level, key = "bgColor", text = bg == "null" ? "" : strings.trim(bg, `"`)})
	lvMust(t, SAMPLES, file, {op = .Level_Depth, level = level, number = 1})
	testing.expect_value(t, lvValue(SAMPLES, file, fmt.tprintf("levels.%d.worldDepth", at)), "1")
	lvMust(t, SAMPLES, file, {op = .Level_Depth, level = level, number = -1})
	lvSameAs(t, SAMPLES, file, original, "settings put back")
	// Named by the pattern: typing a name is refused until it's turned off
	lvMust(t, SAMPLES, file, {op = .Level_Set, level = level, key = "useAutoIdentifier", flag = true})
	testing.expect_value(t, lvValue(SAMPLES, file, fmt.tprintf("levels.%d.identifier", at)), fmt.tprintf(`"World_Level_%d"`, at))
	testing.expect(t, lvApply(SAMPLES, file, {op = .Level_Set, level = level, key = "identifier", text = "Mine"}) != "", "no name typed while automatic")
	lvMust(t, SAMPLES, file, {op = .Level_Set, level = level, key = "useAutoIdentifier", flag = false})
	lvMust(t, SAMPLES, file, {op = .Level_Set, level = level, key = "identifier", text = "Background image"})
	lvSameAs(t, SAMPLES, file, original, "named again as it was")
	// A name another level has is made unique, LDtk's way
	lvMust(t, SAMPLES, file, {op = .Level_Set, level = level, key = "identifier", text = "Everything"})
	testing.expect_value(t, lvValue(SAMPLES, file, fmt.tprintf("levels.%d.identifier", at)), `"Everything2"`)
}

/*
Worlds as LDtk's Multi-worlds makes them: a world added turns the option on (the project's world
becomes the first of `worlds`, its iid the root's dummyWorldIid), with a level of its own; the
option off and on gives LDtk's file back byte for byte; a level moved to another world and back;
the last world can't go.
*/
@(test)
ldtk_worlds_are_made_as_ldtk_makes_them :: proc(t: ^testing.T) {
	if !haveSamples() do return
	defer LDtkDoc_DestroyAll()
	file := "Typical_2D_platformer_example.ldtk"
	original := lvTexts(SAMPLES, file)
	lvMust(t, SAMPLES, file, {op = .Project_Flag, key = "MultiWorlds", flag = true})
	doc := LDtkDoc_Get(SAMPLES, file)
	testing.expect_value(t, len(doc.worlds), 1)
	testing.expect_value(t, lvValue(SAMPLES, file, "worlds.0.iid"), lvValue(SAMPLES, file, "dummyWorldIid"))
	testing.expect_value(t, lvValue(SAMPLES, file, "worldLayout"), "null")
	testing.expect_value(t, lvValue(SAMPLES, file, "levels"), "[]")
	lvMust(t, SAMPLES, file, {op = .Project_Flag, key = "MultiWorlds", flag = false})
	lvSameAs(t, SAMPLES, file, original, "Multi-worlds on and off")
	lvMust(t, SAMPLES, file, {op = .World_Added, entity = "second-world-level"})
	doc = LDtkDoc_Get(SAMPLES, file)
	testing.expect_value(t, len(doc.worlds), 2)
	name, _ := LDtkDoc_WorldNames(doc, 1)
	testing.expect_value(t, name, "World2")
	testing.expect_value(t, doc.levels[LDtkDoc_FindLevel(doc, "second-world-level")].world, 1)
	testing.expect(t, LDtkDoc_MultiWorlds(doc), "Multi-worlds is on")
	testing.expect(t, lvApply(SAMPLES, file, {op = .Project_Flag, key = "MultiWorlds", flag = false}) != "", "not off with two worlds")
	// A level to the new world and back (last in its world's order then)
	lvMust(t, SAMPLES, file, {op = .Level_World_Moved, level = "Top", world = 1})
	doc = LDtkDoc_Get(SAMPLES, file)
	testing.expect_value(t, doc.levels[LDtkDoc_FindLevel(doc, "Top")].world, 1)
	lvMust(t, SAMPLES, file, {op = .World_Set, world = 1, key = "identifier", text = "under world"})
	name, _ = LDtkDoc_WorldNames(LDtkDoc_Get(SAMPLES, file), 1)
	testing.expect_value(t, name, "Under_world")
	lvMust(t, SAMPLES, file, {op = .World_Removed, world = 1})
	doc = LDtkDoc_Get(SAMPLES, file)
	testing.expect_value(t, len(doc.worlds), 1)
	testing.expect_value(t, LDtkDoc_FindLevel(doc, "Top"), -1)
	testing.expect(t, lvApply(SAMPLES, file, {op = .World_Removed, world = 0}) != "", "the last world stays")
}

/*
The Project tab's options that make LDtk write files differently, on and off giving LDtk's files
back byte for byte: levels in separate files (LDtk's sample saved apart, and one that isn't),
minified JSON; the prefixed file names; the default sizes and colors (levels using the default
background follow).
*/
@(test)
ldtk_project_settings_write_files_as_ldtk_writes_them :: proc(t: ^testing.T) {
	if !haveSamples() do return
	defer LDtkDoc_DestroyAll()
	file := "SeparateLevelFiles.ldtk"
	original := lvTexts(SAMPLES, file)
	lvMust(t, SAMPLES, file, {op = .Project_Set, key = "externalLevels", flag = false})
	testing.expect_value(t, len(LDtkDoc_Get(SAMPLES, file).files), 1)
	lvMust(t, SAMPLES, file, {op = .Project_Set, key = "externalLevels", flag = true})
	lvSameAs(t, SAMPLES, file, original, "levels in the project file and apart again")
	lvMust(t, SAMPLES, file, {op = .Project_Flag, key = "PrependIndexToLevelFileNames", flag = true})
	testing.expect_value(t, lvValue(SAMPLES, file, "levels.2.externalRelPath"), `"SeparateLevelFiles/0002-World_Level_2.ldtkl"`)
	lvMust(t, SAMPLES, file, {op = .Project_Flag, key = "PrependIndexToLevelFileNames", flag = false})
	lvSameAs(t, SAMPLES, file, original, "file names prefixed and not")
	lvMust(t, SAMPLES, file, {op = .Project_Set, key = "minifyJson", flag = true})
	testing.expect(t, Json_Minified(LDtkDoc_Main(LDtkDoc_Get(SAMPLES, file))), "minified")
	lvMust(t, SAMPLES, file, {op = .Project_Set, key = "minifyJson", flag = false})
	lvSameAs(t, SAMPLES, file, original, "minified and back")

	file = "Entities.ldtk"
	original = lvTexts(SAMPLES, file)
	lvMust(t, SAMPLES, file, {op = .Project_Set, key = "externalLevels", flag = true})
	testing.expect_value(t, len(LDtkDoc_Get(SAMPLES, file).files), 2)
	testing.expect_value(t, lvValue(SAMPLES, file, "levels.0.externalRelPath"), `"Entities/Entities_demo.ldtkl"`)
	lvMust(t, SAMPLES, file, {op = .Project_Set, key = "externalLevels", flag = false})
	lvSameAs(t, SAMPLES, file, original, "levels apart and back")
	for kv in ([][2]string{{"defaultGridSize", "24"}, {"defaultEntityWidth", "32"}, {"defaultEntityHeight", "8"}, {"levelNamePattern", "Room_%idx1"}}) {
		lvMust(t, SAMPLES, file, {op = .Project_Set, key = kv[0], text = kv[1]})
	}
	testing.expect_value(t, lvValue(SAMPLES, file, "defaultGridSize"), "24")
	lvMust(t, SAMPLES, file, {op = .Project_Set, key = "defaultLevelBgColor", text = "#123456"})
	for level, i in LDtkDoc_Get(SAMPLES, file).levels {
		_ = level
		if lvValue(SAMPLES, file, fmt.tprintf("levels.%d.bgColor", i)) == "null" do testing.expect_value(t, lvValue(SAMPLES, file, fmt.tprintf("levels.%d.__bgColor", i)), `"#123456"`)
	}
	lvMust(t, SAMPLES, file, {op = .Project_Command, key = "add"})
	lvMust(t, SAMPLES, file, {op = .Project_Command, key = "command", index = 0, text = `echo "saved"`})
	lvMust(t, SAMPLES, file, {op = .Project_Command, key = "when", index = 0, text = "AfterSave"})
	testing.expect_value(t, lvValue(SAMPLES, file, "customCommands.0.when"), `"AfterSave"`)
	lvMust(t, SAMPLES, file, {op = .Project_Command, key = "remove", index = 0})
	testing.expect_value(t, lvValue(SAMPLES, file, "customCommands"), "[]")
	// The identifier style: every name follows
	lvMust(t, SAMPLES, file, {op = .Project_Set, key = "identifierStyle", text = "Uppercase"})
	testing.expect_value(t, lvValue(SAMPLES, file, "levels.0.identifier"), `"ENTITIES_DEMO"`)
	testing.expect_value(t, lvValue(SAMPLES, file, "defs.layers.0.identifier"), strings.to_upper(lvValue(SAMPLES, file, "defs.layers.0.identifier"), context.temp_allocator))
}

/*
The editor's side: a level added to a project saving levels apart is a new file, in memory until
Save writes it; undo takes it away, redo brings it back; a level deleted and the project saved
removes its file from LDtk's folder, and turning the option off and saving removes the folder.
*/
@(test)
ldtk_level_files_come_and_go_with_undo_and_save :: proc(t: ^testing.T) {
	dir := worldCopy("ldtk_level_files")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	file := "external.ldtk"
	state := lvState(dir, file)
	defer State_Destroy(&state)
	setOwned(&state.level.file, file)
	folder := joinPath(dir, "external", allocator = context.temp_allocator)
	send(&state, Msg(LDtk_Edit{op = .Level_Added, file = file, world = 0, number = 0, number2 = 600, text = "added-level"}))
	testing.expect_value(t, state.level.problem, "")
	doc := LDtkDoc_Get(dir, file)
	testing.expect_value(t, len(doc.files), 4)
	testing.expect(t, !os.exists(joinPath(folder, "0002-Level_2.ldtkl", allocator = context.temp_allocator)), "nothing on disk yet")
	send(&state, Msg(Action.Undo))
	testing.expect_value(t, len(LDtkDoc_Get(dir, file).files), 3)
	send(&state, Msg(Action.Redo))
	testing.expect_value(t, len(LDtkDoc_Get(dir, file).files), 4)
	testing.expect_value(t, LDtkDoc_Save(dir, file), "")
	testing.expect(t, os.exists(joinPath(folder, "0002-Level_2.ldtkl", allocator = context.temp_allocator)), "saved")
	send(&state, Msg(LDtk_Edit{op = .Level_Removed, file = file, level = "lvl-north"}))
	testing.expect_value(t, state.level.problem, "")
	testing.expect_value(t, LDtkDoc_Save(dir, file), "")
	// South is the first level now: its file is named again, North's went
	testing.expect(t, !os.exists(joinPath(folder, "0000-North.ldtkl", allocator = context.temp_allocator)), "North's file went")
	testing.expect(t, os.exists(joinPath(folder, "0000-South.ldtkl", allocator = context.temp_allocator)), "South's file named again")
	testing.expect(t, !os.exists(joinPath(folder, "0001-South.ldtkl", allocator = context.temp_allocator)), "its old name went")
	send(&state, Msg(LDtk_Edit{op = .Project_Set, file = file, key = "externalLevels", flag = false}))
	testing.expect_value(t, state.level.problem, "")
	testing.expect_value(t, LDtkDoc_Save(dir, file), "")
	testing.expect(t, !os.exists(folder), "the level files' folder went")
	// Undone: apart again (files in memory, written on Save)
	send(&state, Msg(Action.Undo))
	testing.expect_value(t, len(LDtkDoc_Get(dir, file).files), 3)
	testing.expect_value(t, LDtkDoc_Save(dir, file), "")
	testing.expect(t, os.exists(joinPath(folder, "0000-South.ldtkl", allocator = context.temp_allocator)), "written again")
	lvCheck(t, dir, file)
}

/*
A renamed level is followed: the Level mode's selection and the scenes' LDtkLevel nodes naming it,
in one undo step with the rename (undone together).
*/
@(test)
ldtk_level_renames_follow_into_scenes :: proc(t: ^testing.T) {
	dir := worldCopy("ldtk_level_rename")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	file := "world.ldtk"
	state := lvState(dir, file)
	defer State_Destroy(&state)
	setOwned(&state.level.file, file)
	if len(state.project.scenes) == 0 do return
	scene := &state.project.scenes[0]
	node := Scene_AddLDtkAt(scene, file, 0, {0, 0})
	setOwned(&scene.nodes[node].ldtk.level, "Cave")
	send(&state, Msg(Level_Row_Clicked{level = "Cave"}))
	send(&state, Msg(LDtk_Edit{op = .Level_Set, file = file, level = "lvl-cave", key = "identifier", text = "Deep cave"}))
	testing.expect_value(t, state.level.problem, "")
	testing.expect_value(t, state.level.level, "Deep_cave")
	testing.expect_value(t, state.project.scenes[0].nodes[node].ldtk.level, "Deep_cave")
	send(&state, Msg(Action.Undo))
	testing.expect_value(t, state.level.level, "Cave")
	testing.expect_value(t, state.project.scenes[0].nodes[node].ldtk.level, "Cave")
}

/*
What Save writes besides the files (ldtk_save_extras.odin), against what LDtk wrote: LDtk's
levelBgs test project's PNG export (One PNG per layer, with backgrounds) made again: the same files,
the IntGrid pictures pixel for pixel, the backgrounds and layers within a few levels of LDtk's
(LDtk draws them on the GPU); the simplified export's data.json and CSV; backups kept to their limit.
*/
@(test)
ldtk_save_writes_ldtks_pictures_and_backups :: proc(t: ^testing.T) {
	if !haveSamples() || !os.exists("../ldtk/tests/levelBgs.ldtk") do return
	defer LDtkDoc_DestroyAll()
	defer LevelPictures_Destroy()
	dir := tempDir("ldtk_save_extras")
	_ = removeAll(dir)
	defer removeAll(dir)
	_ = os.make_directory_all(dir)
	testing.expect_value(t, Folder_Copy("../ldtk/tests/bg", joinPath(dir, "bg", allocator = context.temp_allocator)), "")
	testing.expect_value(t, Folder_Copy("../ldtk/tests/atlas", joinPath(dir, "atlas", allocator = context.temp_allocator)), "")
	testing.expect_value(t, os.copy_file(joinPath(dir, "levelBgs.ldtk", allocator = context.temp_allocator), "../ldtk/tests/levelBgs.ldtk"), nil)
	doc := LDtkDoc_Get(dir, "levelBgs.ldtk")
	if !testing.expect(t, doc != nil && doc.problem == "", "it reads") do return
	testing.expect_value(t, LDtkSave_Exports(doc), "")
	want := "../ldtk/tests/levelBgs/png"
	entries, _ := os.read_all_directory_by_path(want, context.temp_allocator)
	made := joinPath(dir, "levelBgs", "png", allocator = context.temp_allocator)
	for entry in entries {
		ours := joinPath(made, entry.name, allocator = context.temp_allocator)
		if !testing.expectf(t, os.exists(ours), "%s made", entry.name) do continue
		a, aw, ah, okA := lvReadPng(ours)
		b, bw, bh, okB := lvReadPng(entry.fullpath)
		if !testing.expectf(t, okA && okB && aw == bw && ah == bh, "%s: %dx%d, LDtk's %dx%d", entry.name, aw, ah, bw, bh) do continue
		worst, off := 0, 0
		for i in 0 ..< len(a) {
			d := abs(int(a[i]) - int(b[i]))
			worst = max(worst, d)
			if d > 8 do off += 1
		}
		if strings.has_suffix(entry.name, "-int.png") {
			testing.expectf(t, worst == 0, "%s: pixel for pixel (worst %d)", entry.name, worst)
		} else {
			testing.expectf(t, off * 100 <= len(a), "%s: within LDtk's (%d of %d bytes off by more than 8)", entry.name, off, len(a))
		}
	}
	// The simplified export
	testing.expect_value(t, lvApply(dir, "levelBgs.ldtk", {op = .Project_Set, key = "simplifiedExport", flag = true}), "")
	doc = LDtkDoc_Get(dir, "levelBgs.ldtk")
	testing.expect_value(t, LDtkSave_Exports(doc), "")
	level := joinPath(dir, "levelBgs", "simplified", "Level_0", allocator = context.temp_allocator)
	for name in ([]string{"data.json", "Collisions.csv", "_bg.png", "Collisions.png", "Collisions-int.png", "_composite.png"}) {
		testing.expectf(t, os.exists(joinPath(level, name, allocator = context.temp_allocator)), "simplified %s", name)
	}
	testing.expect(t, !os.exists(made), "the png folder went (the simplified export has its own)")
	data, _ := os.read_entire_file(joinPath(level, "data.json", allocator = context.temp_allocator), context.temp_allocator)
	parsed, problem := Json_Parse(string(data), context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, Json_String(&parsed, Json_Get(&parsed, 0, "identifier")), "Level_0")
	testing.expect(t, strings.has_prefix(string(data), "{\n\t\"identifier\": \"Level_0\",\n\t\"uniqueIdentifer\""), "LDtk's Full layout and keys")
	// Backups: on, three saves at a limit of 3 keep 3 (a fourth's oldest goes)
	testing.expect_value(t, lvApply(dir, "levelBgs.ldtk", {op = .Project_Set, key = "backupOnSave", flag = true}), "")
	testing.expect_value(t, lvApply(dir, "levelBgs.ldtk", {op = .Project_Set, key = "backupLimit", number = 3}), "")
	backups := LDtk_BackupFolder(LDtkDoc_Get(dir, "levelBgs.ldtk"))
	main := LDtkDoc_Main(LDtkDoc_Get(dir, "levelBgs.ldtk"))
	iid := strings.clone(Json_String(main, Json_Get(main, Json_Root(main), "iid")), context.temp_allocator)
	for i in 0 ..< 4 {
		folder := joinPath(backups, fmt.tprintf("%s_2026-01-0%d_10-00-00", iid, i + 1), allocator = context.temp_allocator)
		_ = os.make_directory_all(folder)
		_ = os.write_entire_file(joinPath(folder, "levelBgs.ldtk", allocator = context.temp_allocator), transmute([]u8)string("{}"))
	}
	testing.expect_value(t, LDtkSave_Backup(LDtkDoc_Get(dir, "levelBgs.ldtk")), "")
	kept, _ := os.read_all_directory_by_path(backups, context.temp_allocator)
	testing.expect_value(t, len(kept), 3)
	newest := false
	for k in kept do if !strings.has_prefix(k.name, fmt.tprintf("%s_2026-01", iid)) do newest = true
	testing.expect(t, newest, "the new backup is kept")
}

// A PNG's RGBA pixels
@(private="file")
lvReadPng :: proc(path: string) -> ([]u8, int, int, bool) {
	px, w, h, ok := Image_LoadRGBA(path)
	return px, w, h, ok
}

/*
Field values of every kind as LDtk's field form sets them (ldtk_field_ops.odin), on LDtk's sample
with every field type: an array's item set, added, moved, removed, a file path, the array cleared;
each undone by its opposite gives LDtk's file back byte for byte (LDtk's tidy works out `__value`).
*/
@(test)
ldtk_field_values_change_as_ldtk_changes_them :: proc(t: ^testing.T) {
	if !haveSamples() do return
	defer LDtkDoc_DestroyAll()
	file := "Test_file_for_API_showing_all_features.ldtk"
	original := lvTexts(SAMPLES, file)
	ints, enums, path, lines := 25, 29, 35, 37
	value :: proc(field: int) -> string {
		doc := LDtkDoc_Get(SAMPLES, "Test_file_for_API_showing_all_features.ldtk")
		e, _ := LDtkDoc_FindEntity(doc, "a3030e7b-66b0-11ec-9cd7-81a9b1cce297")
		json := LDtkDoc_Json(doc, e.file)
		for fi in Json_Items(json, Json_Get(json, e.node, "fieldInstances")) do if Json_Int(json, Json_Get(json, fi, "defUid")) == field {
			v := Json_Get(json, fi, "__value")
			b := strings.builder_make(context.temp_allocator)
			for c in Json_Text(json, v) do if c != ' ' && c != '\n' && c != '\t' do strings.write_rune(&b, c)
			return strings.to_string(b)
		}
		return ""
	}
	set :: proc(field, index: int, key, text: string, number: f64 = 0) -> LDtk_Edit {
		return {op = .Field_Value, entity = "a3030e7b-66b0-11ec-9cd7-81a9b1cce297", field = field, index = index, key = key, text = text, number = number}
	}
	lvMust(t, SAMPLES, file, set(ints, 1, "set", "7"))
	testing.expect_value(t, value(ints), "[1,7,3]")
	lvMust(t, SAMPLES, file, set(ints, 0, "add", ""))
	testing.expect_value(t, value(ints), "[1,7,3,0]")
	lvMust(t, SAMPLES, file, set(ints, 3, "set", "4"))
	lvMust(t, SAMPLES, file, set(ints, 3, "move", "", 0))
	testing.expect_value(t, value(ints), "[4,1,7,3]")
	lvMust(t, SAMPLES, file, set(ints, 0, "remove", ""))
	lvMust(t, SAMPLES, file, set(ints, 1, "set", "2"))
	lvMust(t, SAMPLES, file, set(enums, 2, "set", "A"))
	testing.expect_value(t, value(enums), `["A","B","A"]`)
	testing.expect(t, lvApply(SAMPLES, file, set(enums, 2, "set", "Nope")) != "", "not one of the enum's values")
	lvMust(t, SAMPLES, file, set(enums, 2, "set", "C"))
	lvMust(t, SAMPLES, file, set(path, 0, "set", "atlas/whatever.png"))
	testing.expect_value(t, value(path), `"atlas/whatever.png"`)
	lvMust(t, SAMPLES, file, set(path, 0, "set", "README.md"))
	lvMust(t, SAMPLES, file, set(lines, 1, "set", "two\nlines"))
	lvMust(t, SAMPLES, file, set(lines, 1, "set", "<hello>world</hello>"))
	lvSameAs(t, SAMPLES, file, original, "values set and put back")
	lvMust(t, SAMPLES, file, set(ints, 0, "clear", ""))
	testing.expect_value(t, value(ints), "[]")
	// A string kept to what its field's regex matches (FieldDef.applyRegex)
	testing.expect_value(t, LDtk_ApplyRegex("/[a-z]+/g", "ab12cd"), "abcd")
	testing.expect_value(t, LDtk_ApplyRegex("/^[0-9]+$/", "12a"), "")
	testing.expect_value(t, LDtk_ApplyRegex("/(foo|bar)/gi", "xFOOyBar"), "FOOBar")
}
