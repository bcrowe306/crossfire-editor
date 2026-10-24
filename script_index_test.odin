package crossfire_editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import e "engine:."

@(private="file")
HERO_SOURCE :: `package scripts

import e "engine:."
import sdl "vendor:sdl3"

Mood :: enum { Calm, Angry = 3 }

// Not a script: nothing registers it
Loose :: struct {
	x: f32 ` + "`export:\"\"`" + `,
}

Hero :: struct {
	using script: e.Script,
	// Top speed, px/s
	speed: f32 ` + "`export:\"default=175 min=40 max=400\"`" + `,
	lives: int ` + "`export:\"\"`" + `,
	name: string ` + "`export:\"default=Lyra\"`" + `,
	tint: sdl.Color ` + "`export:\"default=#ff0000\"`" + `,
	mood: Mood ` + "`export:\"\"`" + `,
	camera: ^e.Camera2D ` + "`export:\"default=../Camera\"`" + `,
	buddy: ^Player ` + "`export:\"\"`" + `,
	coin: e.SoundAsset ` + "`export:\"\"`" + `,
	stats: e.DataAsset ` + "`export:\"kind=EnemyStats\"`" + `,
	onHit: e.EventSubject ` + "`event:\"It was hit\" data:\"damage := data.(int)\"`" + `,
	grid: [3]f32 ` + "`export:\"\"`" + `,
	typo: f32 ` + "`export:\"defualt=3\"`" + `,
	wrong: int ` + "`export:\"min=lots\"`" + `,
	other: e.Direction ` + "`export:\"\"`" + `,
	state: int,
}

Player :: struct {
	using sprite: e.Sprite,
	jump: f32 ` + "`export:\"default=300\"`" + `,
}

EnemyStats :: struct {
	health: int ` + "`export:\"default=10 min=1\"`" + `,
}

@(init)
register :: proc "contextless" () {
	e.Script_Register(Hero, {})
	e.NodeType_Register(Player, .Sprite, {})
	e.Data_Register(EnemyStats)
}
`

// A fresh folder under the system temp directory (temp allocated)
@(private="file")
indexTestDir :: proc(name: string) -> string {
	base := testTempBase()
	dir, _ := filepath.join({base, name}, context.temp_allocator)
	_ = removeAll(dir)
	_ = os.make_directory_all(dir)
	return dir
}

@(private="file")
fieldOf :: proc(desc: ^ScriptDesc, name: string) -> ^ScriptFieldDesc {
	for &f in desc.fields do if f.name == name do return &f
	return nil
}

@(test)
script_index_reads_scripts_fields_events_and_types :: proc(t: ^testing.T) {
	index: ScriptIndex
	defer ScriptIndex_Destroy(&index)
	f := ScriptIndex_ParseSource("/p/scripts/hero.odin", HERO_SOURCE)
	testing.expect_value(t, f.errors, 0)
	ScriptIndex_Take(&index, {f})

	testing.expect_value(t, len(index.scripts), 1)
	if len(index.scripts) != 1 do return
	hero := &index.scripts[0]
	testing.expect(t, hero.name == "Hero" && hero.fromIndex && hero.file == "/p/scripts/hero.odin", "Hero, from the index")
	testing.expect_value(t, hero.line, 44)
	speed := fieldOf(hero, "speed")
	testing.expect(t, speed != nil && speed.type == .Float && speed.defaultValue == "175" && speed.min.? == 40 && speed.max.? == 400, "speed's tag")
	testing.expect(t, speed != nil && speed.comment == "Top speed, px/s" && speed.line == 16, "speed's comment and line")
	expect :: proc(t: ^testing.T, hero: ^ScriptDesc, name: string, type: e.ScriptFieldType, def: string, hint := "") {
		f := fieldOf(hero, name)
		testing.expectf(t, f != nil, "has %s", name)
		if f == nil do return
		testing.expectf(t, f.type == type && f.defaultValue == def && f.hint == hint, "%s: %v %q %q", name, f.type, f.defaultValue, f.hint)
	}
	expect(t, hero, "lives", .Int, "0")
	expect(t, hero, "name", .String, "Lyra")
	expect(t, hero, "tint", .Color, "#ff0000")
	expect(t, hero, "mood", .Enum, "Calm")
	expect(t, hero, "camera", .Node, "../Camera", "Camera2D")
	expect(t, hero, "buddy", .Node, "", "Player")
	expect(t, hero, "coin", .Sound, "")
	expect(t, hero, "stats", .Data, "", "EnemyStats")
	mood := fieldOf(hero, "mood")
	testing.expect(t, mood != nil && len(mood.enumNames) == 2 && mood.enumNames[1] == "Angry", "the enum's names")
	// Another package's type is left to the build; untagged fields aren't exported
	testing.expect(t, fieldOf(hero, "other") == nil && fieldOf(hero, "state") == nil && fieldOf(hero, "grid") == nil, "skipped")
	testing.expect(t, len(hero.events) == 1 && hero.events[0].name == "script.onHit" && hero.events[0].description == "It was hit" && hero.events[0].dataHint == "damage := data.(int)", "the event")

	// The problems: a type that can't be exported, an option that isn't one, a min that isn't a number
	testing.expect_value(t, len(index.problems), 3)
	messages := make([dynamic]string, context.temp_allocator)
	for p in index.problems do append(&messages, p.message)
	joined := strings.join(messages[:], "|", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, "[3]f32 can't be exported") && strings.contains(joined, "defualt") && strings.contains(joined, "min=lots isn't a number"), "problems: %s", joined)
	for p in index.problems do if strings.contains(p.message, "can't be exported") {
		testing.expect(t, p.line == 26 && p.column == 1 && p.endColumn == 5 && strings.contains(p.lineText, "grid:"), "where")
	}

	testing.expect(t, len(index.nodeTypes) == 1 && index.nodeTypes[0].name == "Player" && index.nodeTypes[0].base == .Sprite, "the node type and its base")
	testing.expect(t, len(index.dataTypes) == 1 && index.dataTypes[0].name == "EnemyStats" && len(index.dataTypes[0].fields) == 1, "the data type")
	free_all(context.temp_allocator)
}

@(test)
script_index_updates_files_and_keeps_broken_ones :: proc(t: ^testing.T) {
	index: ScriptIndex
	defer ScriptIndex_Destroy(&index)
	v1 := "package scripts\nimport e \"engine:.\"\nA :: struct {\n\tusing script: e.Script,\n\tspeed: f32 `export:\"\"`,\n}\n@(init) r :: proc \"contextless\" () { e.Script_Register(A, {}) }\n"
	other := "package scripts\nimport e \"engine:.\"\nB :: struct {\n\tusing script: e.Script,\n}\n@(init) r2 :: proc \"contextless\" () { e.Script_Register(B, {}) }\n"
	ScriptIndex_Take(&index, {ScriptIndex_ParseSource("/p/a.odin", v1), ScriptIndex_ParseSource("/p/b.odin", other)})
	testing.expect_value(t, len(index.scripts), 2)
	generation := index.generation

	// Half-typed code: what last parsed stays, with the errors noted
	broken := "package scripts\nimport e \"engine:.\"\nA :: struct {\n\tusing script: e.Script,\n\tspeed: f32 `export:\"\"`,\n\tlives: in\n@(init) r :: proc \"contextless\" () { e.Script_Register(A, {}) \n"
	parsed := ScriptIndex_ParseSource("/p/a.odin", broken)
	testing.expect(t, parsed.errors > 0, "doesn't parse")
	ScriptIndex_Take(&index, {parsed})
	testing.expect(t, index.generation > generation, "a new generation")
	file := ScriptIndex_File(&index, "/p/a.odin")
	testing.expect(t, file != nil && file.errors > 0, "the errors noted")
	a := ScriptCatalog_Find(&ScriptCatalog{scripts = index.scripts}, "A")
	testing.expect(t, a != nil && len(a.fields) == 1 && a.fields[0].name == "speed", "the last good fields")

	// Fixed with a new field: only that file is parsed again, the other stays
	fixed := "package scripts\nimport e \"engine:.\"\nA :: struct {\n\tusing script: e.Script,\n\tspeed: f32 `export:\"\"`,\n\tlives: int `export:\"default=3\"`,\n}\n@(init) r :: proc \"contextless\" () { e.Script_Register(A, {}) }\n"
	ScriptIndex_Take(&index, {ScriptIndex_ParseSource("/p/a.odin", fixed)})
	a = ScriptCatalog_Find(&ScriptCatalog{scripts = index.scripts}, "A")
	testing.expect(t, a != nil && len(a.fields) == 2 && a.fields[1].defaultValue == "3", "the new field")
	testing.expect(t, ScriptCatalog_Find(&ScriptCatalog{scripts = index.scripts}, "B") != nil, "B is still there")
	testing.expect_value(t, ScriptIndex_File(&index, "/p/a.odin").errors, 0)

	// A struct renamed: the old name goes
	renamed, _ := strings.replace_all(fixed, "A", "Aa", context.temp_allocator)
	ScriptIndex_Take(&index, {ScriptIndex_ParseSource("/p/a.odin", renamed)})
	testing.expect(t, ScriptCatalog_Find(&ScriptCatalog{scripts = index.scripts}, "A") == nil && ScriptCatalog_Find(&ScriptCatalog{scripts = index.scripts}, "Aa") != nil, "renamed")

	// A deleted file
	ScriptIndex_Forget(&index, "/p/b.odin")
	ScriptIndex_Derive(&index)
	testing.expect_value(t, len(index.scripts), 1)
	free_all(context.temp_allocator)
}

// The code tab's buffer the plan sees (one test uses it)
@(private="file")
planBuffer: struct { path, text: string, version: int }

@(test)
script_index_plans_only_what_changed :: proc(t: ^testing.T) {
	dir := indexTestDir("editor_test_script_index")
	defer removeAll(dir)
	folder := joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	folder = absolutePath(folder)
	a := filepath.join({folder, "a.odin"}, context.temp_allocator) or_else ""
	b := filepath.join({folder, "b.odin"}, context.temp_allocator) or_else ""
	_ = os.write_entire_file(a, transmute([]u8)string("package scripts\nA :: struct {}\n"))
	_ = os.write_entire_file(b, transmute([]u8)string("package scripts\nB :: struct {}\n"))
	index: ScriptIndex
	defer ScriptIndex_Destroy(&index)
	run :: proc(index: ^ScriptIndex, folder: string, buffer: proc(path: string, wantText: bool) -> (string, int, bool) = nil) -> int {
		sources := ScriptIndex_Plan(index, folder, buffer)
		defer delete(sources)
		n := len(sources)
		files, _ := ScriptIndex_ParseAll(sources[:])
		for s in sources { delete(s.path); delete(s.text) }
		ScriptIndex_Take(index, files)
		delete(files)
		return n
	}
	testing.expect_value(t, run(&index, folder), 2)
	testing.expect_value(t, run(&index, folder), 0)
	// One file changed on disk: only it
	_ = os.write_entire_file(b, transmute([]u8)string("package scripts\nB :: struct { x: int }\n"))
	later := time.time_add(time.now(), 2 * time.Second)
	_ = os.change_times(b, later, later)
	testing.expect_value(t, run(&index, folder), 1)
	// Saved again unchanged: no parse, the time follows
	_ = os.change_times(b, time.time_add(later, time.Second), time.time_add(later, time.Second))
	testing.expect_value(t, run(&index, folder), 0)

	// A code tab with unsaved changes: parsed once its text was the same for a look
	planBuffer = {a, "package scripts\nA :: struct { typed: f32 }\n", 7}
	buffer :: proc(path: string, wantText: bool) -> (string, int, bool) {
		if path == planBuffer.path do return wantText ? planBuffer.text : "", planBuffer.version, true
		return "", -1, false
	}
	testing.expect_value(t, run(&index, folder, buffer), 0)
	testing.expect_value(t, run(&index, folder, buffer), 1)
	testing.expect_value(t, ScriptIndex_File(&index, a).bufferVersion, 7)
	testing.expect_value(t, run(&index, folder, buffer), 0)
	// Typing on: it waits again
	planBuffer.version = 8
	testing.expect_value(t, run(&index, folder, buffer), 0)

	// A deleted file is forgotten
	_ = os.remove(b)
	testing.expect_value(t, run(&index, folder), 1) // a: the tab's gone, its file read again
	testing.expect(t, ScriptIndex_File(&index, b) == nil, "b forgotten")
	planBuffer = {}
	free_all(context.temp_allocator)
}

@(test)
script_index_merges_with_the_build :: proc(t: ^testing.T) {
	state := State{project = Project_CreateTestProject("unused"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	index := &state.scriptIndex
	built := `{"scripts": [{"name": "A", "file": "/p/scripts/a.odin", "line": 9, "fields": [{"name": "speed", "type": "Float", "default": "1", "hint": ""}], "events": []}, ` +
		`{"name": "Old", "file": "/p/scripts/a.odin", "line": 20, "fields": [], "events": []}], "data": [], "nodeTypes": []}`
	text := "package scripts\nimport e \"engine:.\"\nA :: struct {\n\tusing script: e.Script,\n\tspeed: f32 `export:\"default=2\"`,\n\tlives: int `export:\"\"`,\n}\n@(init) r :: proc \"contextless\" () { e.Script_Register(A, {}) }\n"
	f := ScriptIndex_ParseSource("/p/scripts/a.odin", text)
	f.modTime = time.time_add(time.now(), -time.Hour)
	ScriptIndex_Take(index, {f})

	// No build yet: the index's
	ScriptIndex_Apply(&state)
	a := ScriptCatalog_Find(&state.scripts, "A")
	testing.expect(t, a != nil && a.fromIndex && len(a.fields) == 2, "the index's before a build")

	// A build newer than the file: the build's, all of it
	scripts, dataTypes, nodeTypes, ok := ScriptCatalog_ParseAll(built)
	testing.expect(t, ok, "parsed")
	ScriptCatalog_Clear(&state.scripts)
	state.scripts.scripts, state.scripts.dataTypes, state.scripts.nodeTypes = scripts, dataTypes, nodeTypes
	state.scripts.status = .Ready
	state.scriptsBuildSource = time.now()
	ScriptIndex_TakeBuild(&state)
	a = ScriptCatalog_Find(&state.scripts, "A")
	testing.expect(t, a != nil && !a.fromIndex && len(a.fields) == 1 && a.fields[0].defaultValue == "1", "the build's")
	testing.expect(t, ScriptCatalog_Find(&state.scripts, "Old") != nil, "and what only it has")
	testing.expect_value(t, state.scripts.status, ScriptCatalogStatus.Ready)

	// The file changed after the build (a code tab's unsaved text): the index's for it; the
	// build's script that file no longer registers goes
	entry := &index.files["/p/scripts/a.odin"]
	entry.bufferVersion = 3
	ScriptIndex_Apply(&state)
	a = ScriptCatalog_Find(&state.scripts, "A")
	testing.expect(t, a != nil && a.fromIndex && len(a.fields) == 2 && a.fields[0].defaultValue == "2", "the source's, newer")
	testing.expect(t, ScriptCatalog_Find(&state.scripts, "Old") == nil, "gone from the changed file")
	free_all(context.temp_allocator)
}

// How long the index takes on the demo project (logged; the numbers are in the editor's CLAUDE.md)
@(test)
script_index_demo_project_timing :: proc(t: ^testing.T) {
	folder := absolutePath(joinPath(DEMO_PROJECT, SCRIPTS_FOLDER, allocator = context.temp_allocator))
	index: ScriptIndex
	defer ScriptIndex_Destroy(&index)
	start := time.tick_now()
	sources := ScriptIndex_Plan(&index, folder)
	files, parse := ScriptIndex_ParseAll(sources[:])
	ScriptIndex_Take(&index, files)
	full := time.tick_since(start)
	testing.expect(t, len(index.scripts) >= 25, "the demo's scripts")
	testing.expect_value(t, len(index.problems), 0)
	for p in index.problems do log.errorf("%s:%d: %s", filepath.base(p.path), p.line, p.message)
	lines := 0
	for s in sources do lines += strings.count(s.text, "\n")
	// One file again (the largest script; assets.odin is generated), as an edit would
	largest := 0
	for s, i in sources do if filepath.base(s.path) != ASSETS_FILE && (filepath.base(sources[largest].path) == ASSETS_FILE || len(s.text) > len(sources[largest].text)) do largest = i
	// The best of TIMING_RUNS
	again: []IndexFile
	one: time.Duration
	incremental := time.Duration(max(i64))
	for run in 0 ..< TIMING_RUNS {
		if run > 0 do delete(again)
		start = time.tick_now()
		again, one = ScriptIndex_ParseAll(sources[largest:largest + 1])
		ScriptIndex_Take(&index, again)
		incremental = min(incremental, time.tick_since(start))
	}
	log.infof("script index, demo: %d files, %d lines: full %v (parse %v), one file (%s) %v (parse %v)", len(sources), lines, full, parse, filepath.base(sources[largest].path), incremental, one)
	// Generous: it's 8-10 ms here (a catch for something gone slow, not a busy machine)
	testing.expectf(t, full < 5 * time.Second, "fast enough (%v)", full)
	// And the constants of assets.odin (written on every save; the providers' list)
	project, message, _ := Project_Load(DEMO_PROJECT)
	defer Project_Destroy(&project)
	testing.expect_value(t, message, "")
	_ = Scripts_Constants(&project) // the Aseprite files' tags read once
	start = time.tick_now()
	constants := len(Scripts_Constants(&project))
	log.infof("assets.odin, demo: %d constants in %v", constants, time.tick_since(start))
	for s in sources { delete(s.path); delete(s.text) }
	delete(sources)
	delete(files)
	delete(again)
	_ = fmt.tprint(lines)
	free_all(context.temp_allocator)
}
