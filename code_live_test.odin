package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"

// Lines: 5 Hero :: struct, 7 speed, 8 spawn, 9 lives, 10 hp (0-based)
@(private="file")
LIVE_HERO_SOURCE :: "package scripts\n\nimport e \"engine:.\"\n\n// The hero\nHero :: struct {\n\tusing script: e.Script,\n\tspeed: f32 `export:\"default=250 min=0 max=400\"`,\n\tspawn: [2]f32 `export:\"default=10, 20\"`,\n\tlives: int `export:\"default=3\"`,\n\thp: int,\n}\n\n@(init)\nregister_Hero :: proc \"contextless\" () {\n\te.Script_Register(Hero, {})\n}\n"

// A state with Hero on PlayScene's Spaceship (its own speed 300) and a game "running" with two
// nodes running Hero: Spaceship (/World/Spaceship) and Clone
@(private="file")
liveTestState :: proc(t: ^testing.T, dir: string) -> (state: State, path: string) {
	folder := joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	path = absolutePath(joinPath(folder, "hero.odin", allocator = context.temp_allocator))
	_ = os.write_entire_file(path, transmute([]u8)string(LIVE_HERO_SOURCE))
	state = State{project = Project_CreateTestProject(dir), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(), currentScene = 1}
	state.settings.olsPath = FixedText_Make("/nonexistent/ols")
	state.settings.builtInCodeEditor = true
	sources := ScriptIndex_Plan(&state.scriptIndex, absolutePath(folder))
	files, _ := ScriptIndex_ParseAll(sources[:])
	for s in sources { delete(s.path); delete(s.text) }
	delete(sources)
	ScriptIndex_Take(&state.scriptIndex, files)
	delete(files)
	ScriptIndex_Apply(&state)
	play := &state.project.scenes[1]
	for &n in play.nodes do if n.name == "Spaceship" {
		delete(n.script)
		n.script = strings.clone("Hero")
		NodeDef_SetScriptValue(&n, "speed", "300", "250")
	}
	// The running game
	state.playState = .Playing
	state.play.stage = .Running
	Live_Ingest(&state, `{"type":"tree","scene":"PlayScene","nodes":[{"id":"w","name":"World","type":"Node2D","parent":"","visible":true},{"id":"s","name":"Spaceship","type":"Sprite","parent":"w","visible":true,"scripts":["Hero"]},{"id":"c","name":"Clone","type":"Node2D","parent":"w","visible":true,"scripts":["Hero"]}]}`)
	Live_Ingest(&state, `{"type":"fields","script":"Hero","id":"s","values":[{"name":"speed","value":"312"},{"name":"spawn","value":"[10, 20]"},{"name":"hp","value":"7"}]}`)
	return
}

@(private="file")
liveRunProviders :: proc(state: ^State, c: ^CodeEditor) {
	CodeProviders_Begin(state)
	ce.editor_run_cached_providers(&c.ed)
	CodeProviders_End()
}

// The live values beside the fields, which node they come from, the watches asked for, the hint's
// menu, and none once the game stops
@(test)
code_live_values_in_a_code_tab :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	base := testTempBase()
	dir, _ := filepath.join({base, "editor_test_code_live"}, context.temp_allocator)
	_ = removeAll(dir)
	defer removeAll(dir)
	state, path := liveTestState(t, dir)
	defer State_Destroy(&state)
	testing.expect(t, CodeLive_Active(&state), "a game plays")
	testing.expect_value(t, len(state.live.nodes), 3)
	testing.expect_value(t, len(state.live.nodes[1].scripts), 1)

	_ = Script_Open(&state, path, 1)
	c := CodeEditor_Find(path)
	if !testing.expect(t, c != nil, "the code tab opened") do return
	liveRunProviders(&state, c)
	notes, _ := CodeEditor_LineNotes(path, 5)
	testing.expectf(t, strings.contains(notes, "live: Spaceship (1 of 2)"), "the struct says whose: %q", notes)
	notes, _ = CodeEditor_LineNotes(path, 7)
	testing.expectf(t, strings.contains(notes, "= 312  (Spaceship's own: 300)"), "the game's speed and the node's own: %q", notes)
	notes, _ = CodeEditor_LineNotes(path, 10)
	testing.expectf(t, strings.contains(notes, "= 7"), "a field that isn't exported: %q", notes)
	notes, _ = CodeEditor_LineNotes(path, 9)
	testing.expectf(t, !strings.contains(notes, "="), "lives wasn't sent: %q", notes)

	// The watches: the fields on the lines shown, the target's id
	watches := CodeLive_Watches(&state, path, 0, 30)
	testing.expect_value(t, len(watches), 1)
	if len(watches) == 1 do testing.expect_value(t, watches[0], "Hero s speed spawn lives hp")
	testing.expect_value(t, len(CodeLive_Watches(&state, path, 40, 60)), 0)
	Live_Watch(&state, watches)
	testing.expect_value(t, len(state.live.watches), 1)
	Live_Watch(&state, nil)
	testing.expect_value(t, len(state.live.watches), 0)
	testing.expect_value(t, len(state.live.fields), 0)
	Live_Ingest(&state, `{"type":"fields","script":"Hero","id":"s","values":[{"name":"speed","value":"312"},{"name":"hp","value":"7"}]}`)

	// Which node: the first, the Live tab's choice, the scene's selection, a pick in the hint
	node, candidates := CodeLive_Target(&state, "Hero")
	testing.expect_value(t, len(candidates), 2)
	testing.expect_value(t, state.live.nodes[node].name, "Spaceship")
	send(&state, Msg(Live_Selected("c")))
	node, _ = CodeLive_Target(&state, "Hero")
	testing.expect_value(t, state.live.nodes[node].name, "Clone")
	send(&state, Msg(Live_Selected("w")))
	for n, i in state.project.scenes[1].nodes do if n.name == "Spaceship" do state.selectedNode = i
	node, _ = CodeLive_Target(&state, "Hero")
	testing.expect_value(t, state.live.nodes[node].name, "Spaceship")
	sc, ni := CodeLive_ProjectNode(&state, node)
	testing.expect(t, sc == 1 && ni == state.selectedNode, "the project's node")
	// The hint's menu picks Clone; choosing in the Live tab again gives way
	CodeProviders_Begin(&state)
	liveInlayClicked(ce.editor_provider_document(&c.ed), ce.Inlay_Hint{id = 0, choice = 1}, nil)
	CodeProviders_End()
	for m in CodeLive_Messages() do send(&state, m)
	node, _ = CodeLive_Target(&state, "Hero")
	testing.expect_value(t, state.live.nodes[node].name, "Clone")
	send(&state, Msg(Live_Selected("s")))
	node, _ = CodeLive_Target(&state, "Hero")
	testing.expect_value(t, state.live.nodes[node].name, "Spaceship")

	// The game stops: no hints
	endSession(&state)
	liveRunProviders(&state, c)
	notes, _ = CodeEditor_LineNotes(path, 7)
	testing.expectf(t, !strings.contains(notes, "= 312"), "gone: %q", notes)
	notes, _ = CodeEditor_LineNotes(path, 5)
	testing.expectf(t, !strings.contains(notes, "live:"), "gone: %q", notes)
	free_all(context.temp_allocator)
}

// The literals a scrub takes (only numbers in a tag's default), the numbers in a value, a range
@(test)
code_scrub_literals :: proc(t: ^testing.T) {
	line := "\tspeed: f32 `export:\"default=250 min=0 max=400\"`,"
	at := strings.index(line, "250")
	lit, ok := CodeScrub_Literal(line, at + 1)
	testing.expect(t, ok && lit.start == at && lit.end == at + 3 && lit.component == 0, "the default")
	testing.expect_value(t, lit.defaultText, "250")
	_, ok = CodeScrub_Literal(line, strings.index(line, "400") + 1)
	testing.expect(t, !ok, "not max=")
	_, ok = CodeScrub_Literal(line, 2)
	testing.expect(t, !ok, "not the name")
	vector := "\tspawn: [2]f32 `export:\"default=10, -20.5\"`,"
	lit, ok = CodeScrub_Literal(vector, strings.index(vector, "-20.5") + 2)
	testing.expect(t, ok && lit.component == 1 && vector[lit.start:lit.end] == "-20.5", "a vector's second number")
	testing.expect_value(t, lit.defaultText, "10, -20.5")
	_, ok = CodeScrub_Literal("\tx := 250", 7)
	testing.expect(t, !ok, "a body's number isn't scrubbed")
	_, ok = CodeScrub_Literal("\tname: string `export:\"default=Hero min=1\"`", 30)
	testing.expect(t, !ok, "no number there")

	numbers := CodeScrub_Numbers("[10, -20.5]")
	testing.expect(t, len(numbers) == 2 && numbers[0] == 10 && numbers[1] == -20.5, "a vector's numbers")
	testing.expect_value(t, len(CodeScrub_Numbers("\"text\"")), 0)
	lo, hi := CodeScrub_Range(line)
	testing.expect(t, (lo.? or_else -1) == 0 && (hi.? or_else -1) == 400, "the range")
	lo, hi = CodeScrub_Range(vector)
	_, hasLo := lo.?
	_, hasHi := hi.?
	testing.expect(t, !hasLo && !hasHi, "none")
	free_all(context.temp_allocator)
}

// Scrubbing a default: from the game's value, each value sent to the game, then written to the
// code (one undo step in the tab), to the node's own value (an undo step), or to neither
@(test)
code_scrub_sends_and_writes_back :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	base := testTempBase()
	dir, _ := filepath.join({base, "editor_test_code_scrub"}, context.temp_allocator)
	_ = removeAll(dir)
	defer removeAll(dir)
	state, path := liveTestState(t, dir)
	defer State_Destroy(&state)
	_ = Script_Open(&state, path, 1)
	c := CodeEditor_Find(path)
	if !testing.expect(t, c != nil, "the code tab opened") do return
	doc := ce.editor_provider_document(&c.ed)
	speedLine := cebuf.buffer_line_str(&c.ed.buf, 7)
	at := strings.index(speedLine, "250")

	CodeProviders_Begin(&state)
	target := ce.Scrub_Target{decimals = -1}
	ok := liveScrubTarget(doc, {7, at + 1}, {}, &target)
	testing.expect(t, ok, "the default can be scrubbed")
	testing.expect_value(t, target.value, 312)
	testing.expect(t, (target.max.? or_else -1) == 400 && (target.min.? or_else -1) == 0, "its range")
	testing.expect(t, !target.integer, "a float")
	notDefault := ce.Scrub_Target{decimals = -1}
	testing.expect(t, !liveScrubTarget(doc, {7, strings.index(speedLine, "400") + 1}, {}, &notDefault), "not max=")
	choices := make([dynamic]string, context.temp_allocator)
	liveScrubbed(doc, target, 320, "320", .Change, nil, &choices)
	liveScrubbed(doc, target, 320, "320", .End, nil, &choices)
	CodeProviders_End()
	messages := CodeLive_Messages()
	testing.expect_value(t, len(messages), 1)
	if changed, isChange := messages[0].(Code_Scrub_Changed); isChange {
		testing.expect_value(t, changed.id, "s")
		testing.expect_value(t, changed.property, "script.speed")
		testing.expect_value(t, changed.value, "320")
	}
	// Spaceship has its own speed: its value first, then the code's default (saying it keeps its own), the game only
	testing.expect_value(t, len(choices), 3)
	testing.expectf(t, strings.contains(choices[0], "Spaceship's own value"), "%q", choices[0])
	testing.expectf(t, strings.contains(choices[1], "default in the code (Spaceship keeps its own 300)"), "%q", choices[1])
	testing.expectf(t, strings.contains(choices[2], "running game only"), "%q", choices[2])

	// The code's default: written in the tab, one undo step
	CodeProviders_Begin(&state)
	liveScrubChosen(doc, target, 320, "320", 1, nil)
	CodeProviders_End()
	for m in CodeLive_Messages() do send(&state, m)
	testing.expect(t, strings.contains(cebuf.buffer_line_str(&c.ed.buf, 7), "default=320 min=0"), "written")
	cebuf.buffer_undo(&c.ed.buf)
	testing.expect(t, strings.contains(cebuf.buffer_line_str(&c.ed.buf, 7), "default=250 min=0"), "undone")

	// The node's own value: an undo step
	ship := -1
	for n, i in state.project.scenes[1].nodes do if n.name == "Spaceship" do ship = i
	CodeProviders_Begin(&state)
	target = {decimals = -1}
	_ = liveScrubTarget(doc, {7, at + 1}, {}, &target)
	clear(&choices)
	liveScrubbed(doc, target, 330, "330", .End, nil, &choices)
	liveScrubChosen(doc, target, 330, "330", 0, nil)
	CodeProviders_End()
	for m in CodeLive_Messages() do send(&state, m)
	value := ""
	for p in state.project.scenes[1].nodes[ship].props do if p.name == "speed" do value = p.value
	testing.expect_value(t, value, "330")
	send(&state, Msg(Action.Undo))
	for p in state.project.scenes[1].nodes[ship].props do if p.name == "speed" do value = p.value
	testing.expect_value(t, value, "300")
	testing.expect(t, strings.contains(cebuf.buffer_line_str(&c.ed.buf, 7), "default=250"), "the code untouched")

	// The game only: nothing written
	CodeProviders_Begin(&state)
	_ = liveScrubTarget(doc, {7, at + 1}, {}, &target)
	clear(&choices)
	liveScrubbed(doc, target, 340, "340", .End, nil, &choices)
	liveScrubChosen(doc, target, 340, "340", 2, nil)
	CodeProviders_End()
	for m in CodeLive_Messages() do send(&state, m)
	testing.expect(t, strings.contains(cebuf.buffer_line_str(&c.ed.buf, 7), "default=250"), "the code untouched")

	// A vector's number: the property keeps the other one
	spawnLine := cebuf.buffer_line_str(&c.ed.buf, 8)
	CodeProviders_Begin(&state)
	target = {decimals = -1}
	ok = liveScrubTarget(doc, {8, strings.index(spawnLine, "20") + 1}, {}, &target)
	testing.expect(t, ok && target.value == 20, "spawn's y from the game")
	liveScrubbed(doc, target, 25, "25", .Change, nil, &choices)
	CodeProviders_End()
	messages = CodeLive_Messages()
	if len(messages) == 1 {
		if changed, isChange := messages[0].(Code_Scrub_Changed); isChange do testing.expect_value(t, changed.value, "10, 25")
	} else {
		testing.expect(t, false, fmt.tprintf("one change, got %d", len(messages)))
	}
	// An int field: whole numbers
	livesLine := cebuf.buffer_line_str(&c.ed.buf, 9)
	CodeProviders_Begin(&state)
	target = {decimals = -1}
	ok = liveScrubTarget(doc, {9, strings.index(livesLine, "3") + 1}, {}, &target)
	CodeProviders_End()
	testing.expect(t, ok && target.integer && target.value == 3, "lives (not sent: its default)")
	_ = CodeLive_Messages()
	free_all(context.temp_allocator)
}

// A project opened through a symbolic link (as macOS's temporary folder, /var linking to
// /private/var) behaves as through its real folder: the paths a test or an error line spells
// through the link find the tab, the index's file, the live values and the providers
@(test)
code_paths_through_a_link :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	real := tempDir("editor_test_code_link_real")
	link := joinPath(testTempBase(), "editor_test_code_link", allocator = context.temp_allocator)
	_ = os.remove(link)
	if !testing.expectf(t, os.symlink(real, link) == nil, "a link to %s", real) do return
	defer os.remove(link)
	defer removeAll(real)
	state, _ := liveTestState(t, link)
	defer State_Destroy(&state)
	testing.expect_value(t, state.project.rootPath, real)
	// The script spelled through the link, as a path from elsewhere would be
	path := joinPath(link, SCRIPTS_FOLDER, "hero.odin", allocator = context.temp_allocator)
	_ = Script_Open(&state, path, 1)
	c := CodeEditor_Find(path)
	if !testing.expect(t, c != nil, "the tab, found through the link") do return
	testing.expect(t, isProjectScript(&state, path), "a project script through the link")
	testing.expect(t, ScriptIndex_File(&state.scriptIndex, absolutePath(path)) != nil, "the index's file")
	liveRunProviders(&state, c)
	notes, _ := CodeEditor_LineNotes(path, 7)
	testing.expectf(t, strings.contains(notes, "= 312"), "the live value: %q", notes)
	watches := CodeLive_Watches(&state, path, 0, 30)
	testing.expect_value(t, len(watches), 1)
	testing.expect(t, Paths_Same(path, joinPath(real, SCRIPTS_FOLDER, "hero.odin", allocator = context.temp_allocator)), "one file, two spellings")
}

// Steps the State through a pointer (a State value per step kept 35 KB each in the test's frame)
@(private="file")
send :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}
