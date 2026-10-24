package crossfire_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import e "engine:."

// Lines (0-based): 5 Hero :: struct, 7 speed, 8 lives, 9 camera, 10 brain, 11 label, 16
// register, 17 ready, 18 self.speed = 250, 19 blank, 24 Loose :: struct
@(private="file")
actionsSource :: proc(brainPath: string) -> string {
	source, _ := strings.replace(`package scripts

import e "engine:."

// The hero
Hero :: struct {
	using script: e.Script,
	speed: f32,
	lives: int `+"`export:\"default=3\"`"+`,
	camera: ^e.Camera2D `+"`export:\"default=../Camera\"`"+`,
	brain: ^e.StateMachine `+"`export:\"default=BRAIN\"`"+`,
	label: string,
}

@(init)
register_Hero :: proc "contextless" () {
	e.Script_Register(Hero, {
		ready = proc(self: ^Hero) {
			self.speed = 250

		},
	})
}

// Not registered yet
Loose :: struct {
	using script: e.Script,
	hp: int,
}
`, "BRAIN", brainPath, 1, context.temp_allocator)
	return source
}

@(private="file") LINE_SPEED :: 7
@(private="file") LINE_LIVES :: 8
@(private="file") LINE_CAMERA :: 9
@(private="file") LINE_LABEL :: 11
@(private="file") LINE_REGISTER :: 16
@(private="file") LINE_BLANK :: 19
@(private="file") LINE_LOOSE :: 25

// A project whose Spaceship runs Hero (in a code tab), with a state machine Brain
@(private="file")
ActionsFixture :: struct {
	state: State,
	dir, path, source: string,
	c: ^CodeEditor,
	ship, brain: int,
}

@(private="file")
actionsFixture :: proc(t: ^testing.T, f: ^ActionsFixture, name: string) -> bool {
	f.dir = tempDir(name)
	folder := joinPath(f.dir, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	f.state = State{project = Project_CreateTestProject(f.dir), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(), currentScene = 1}
	f.state.settings.olsPath = FixedText_Make("/nonexistent/ols")
	f.state.settings.builtInCodeEditor = true
	play := &f.state.project.scenes[1]
	for n, i in play.nodes do if n.name == "Spaceship" do f.ship = i
	delete(play.nodes[f.ship].script)
	play.nodes[f.ship].script = strings.clone("Hero")
	brain := NodeDef_Make("Brain", .StateMachine, -1)
	append(&brain.stateMachine.states, e.StateMachineState{name = strings.clone("attack"), animation = strings.clone("")})
	append(&play.nodes, brain)
	f.brain = len(play.nodes) - 1
	f.source = strings.clone(actionsSource(Scene_NodePath(play, f.ship, f.brain, context.temp_allocator)), context.temp_allocator)
	f.path = absolutePath(joinPath(folder, "hero.odin", allocator = context.temp_allocator))
	_ = os.write_entire_file(f.path, transmute([]u8)f.source)

	sources := ScriptIndex_Plan(&f.state.scriptIndex, absolutePath(folder))
	files, _ := ScriptIndex_ParseAll(sources[:])
	for src in sources { delete(src.path); delete(src.text) }
	delete(sources)
	ScriptIndex_Take(&f.state.scriptIndex, files)
	delete(files)
	ScriptIndex_Apply(&f.state)
	_ = Script_Open(&f.state, f.path, 1)
	f.c = CodeEditor_Find(f.path)
	return testing.expectf(t, f.c != nil, "the script opens (%q)", f.path)
}

// The titles Ctrl+. lists at a position (the menu stays open)
@(private="file")
actionTitles :: proc(f: ^ActionsFixture, line, col: int) -> []string {
	CodeProviders_Begin(&f.state)
	defer CodeProviders_End()
	f.c.ed.buf.cursors[0] = {pos = {line, col}}
	ce.editor_request_code_actions(&f.c.ed)
	out := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< ce.editor_code_action_count(&f.c.ed) {
		title, _ := ce.editor_code_action_title(&f.c.ed, i)
		append(&out, strings.clone(title, context.temp_allocator))
	}
	return out[:]
}

// Picks the action whose title starts with `title` at a position; false when it isn't offered
@(private="file")
pickAction :: proc(f: ^ActionsFixture, line, col: int, title: string) -> bool {
	titles := actionTitles(f, line, col)
	CodeProviders_Begin(&f.state)
	defer CodeProviders_End()
	for t, i in titles do if strings.has_prefix(t, title) do return ce.editor_apply_code_action(&f.c.ed, i)
	ce.editor_close_code_actions(&f.c.ed)
	return false
}

@(private="file")
hasTitle :: proc(titles: []string, title: string) -> bool {
	for t in titles do if strings.has_prefix(t, title) do return true
	return false
}

// One undo step takes an action back
@(private="file")
undoneAction :: proc(t: ^testing.T, f: ^ActionsFixture, what: string) {
	cebuf.buffer_undo(&f.c.ed.buf)
	testing.expectf(t, CodeEditor_Text(f.path) == f.source, "%s: one undo step takes it back:\n%s", what, CodeEditor_Text(f.path))
}

@(test)
code_actions_read_the_code :: proc(t: ^testing.T) {
	code := CodeActions_Read("hero.odin", actionsSource("Brain"))
	testing.expect_value(t, len(code.structs), 2)
	hero := code.structs[0]
	testing.expect(t, hero.name == "Hero" && hero.line == 5 && hero.closeLine == 12 && hero.embeds == "e.Script", "the struct, its brace, what it embeds")
	lives := hero.fields[2]
	testing.expect(t, lives.name == "lives" && lives.tag == `export:"default=3"` && lives.typeEnd == len("\tlives: int"), "a field's type end and tag")
	testing.expect_value(t, actionsSource("Brain")[:0], "")
	line := strings.split_lines(actionsSource("Brain"), context.temp_allocator)[LINE_LIVES]
	testing.expect_value(t, line[lives.tagStart:lives.tagEnd], "`export:\"default=3\"`")
	testing.expect_value(t, len(code.registrations), 1)
	reg := code.registrations[0]
	testing.expect(t, reg.kind == .Script && reg.declLine == 14 && reg.hasHooks && reg.openLine == LINE_REGISTER && reg.closeLine == 21, "the registration, its attribute line and its literal")
	testing.expect(t, len(reg.hooks) == 1 && reg.hooks[0].name == "ready" && reg.hooks[0].param == "self" && reg.hooks[0].closeLine == 20, "the ready hook and its body's brace")
	testing.expect(t, code.engineAlias == "e" && code.sdlAlias == "" && code.lastImportLine == 2, "the imports")
	free_all(context.temp_allocator)
}

// Each action: offered where it applies (and not elsewhere), what it writes, one undo step
@(test)
code_actions_in_a_code_tab :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	f: ActionsFixture
	if !actionsFixture(t, &f, "editor_test_code_actions") do return
	defer removeAll(f.dir)
	defer State_Destroy(&f.state)

	// Export: the default from ready's assignment
	titles := actionTitles(&f, LINE_SPEED, 2)
	testing.expectf(t, hasTitle(titles, "Export speed") && hasTitle(titles, "Export speed with a range...") && !hasTitle(titles, "Remove export"), "an unexported number: %v", titles)
	testing.expect(t, pickAction(&f, LINE_SPEED, 2, "Export speed"), "exported")
	testing.expect(t, strings.contains(CodeEditor_Text(f.path), "\tspeed: f32 `export:\"default=250\"`,\n"), "the tag with its default")
	undoneAction(t, &f, "export")
	testing.expect(t, pickAction(&f, LINE_LABEL, 2, "Export label"), "a string")
	testing.expect(t, strings.contains(CodeEditor_Text(f.path), "\tlabel: string `export:\"\"`,\n"), "no default to give")
	undoneAction(t, &f, "export a string")

	// An exported field: remove, a range, the inspector
	titles = actionTitles(&f, LINE_LIVES, 2)
	testing.expectf(t, hasTitle(titles, "Remove export from lives") && hasTitle(titles, "Set lives's range...") && hasTitle(titles, "Show lives in the inspector") && !hasTitle(titles, "Export lives"), "an exported number: %v", titles)
	testing.expect(t, pickAction(&f, LINE_LIVES, 2, "Remove export"), "removed")
	testing.expect(t, strings.contains(CodeEditor_Text(f.path), "\tlives: int,\n"), "the tag gone")
	undoneAction(t, &f, "remove export")

	// The range: the dialog, a refusal, then the tag written (one undo step)
	testing.expect(t, pickAction(&f, LINE_LIVES, 2, "Set lives's range"), "picked")
	command, pending := CodeActions_TakePending()
	request, isRange := command.(Code_Range_Requested)
	testing.expect(t, pending && isRange && request.field == "lives" && request.whole && request.defaultValue == "3", "the dialog's request")
	_, _ = CodeActions_Update(&f.state, Msg(request))
	testing.expect(t, f.state.codeRange.open, "the dialog opens")
	_, _ = CodeActions_Update(&f.state, Msg(Code_Range_Field_Changed{0, "10"}))
	_, _ = CodeActions_Update(&f.state, Msg(Code_Range_Field_Changed{1, "5"}))
	_, _ = CodeActions_Update(&f.state, Msg(Code_Range_Applied{}))
	testing.expect(t, f.state.codeRange.open && f.state.codeRange.problem == "Min is over Max", "min over max is refused")
	_, _ = CodeActions_Update(&f.state, Msg(Code_Range_Field_Changed{0, "0"}))
	_, _ = CodeActions_Update(&f.state, Msg(Code_Range_Field_Changed{1, "9"}))
	_, _ = CodeActions_Update(&f.state, Msg(Code_Range_Applied{}))
	testing.expect(t, !f.state.codeRange.open, "OK closes it")
	testing.expect(t, strings.contains(CodeEditor_Text(f.path), "\tlives: int `export:\"default=3 min=0 max=9\"`,\n"), "the range in the tag")
	undoneAction(t, &f, "range")

	// The inspector: Spaceship selected, its row asked for; and back to the declaration
	testing.expect(t, pickAction(&f, LINE_LIVES, 2, "Show lives in the inspector"), "picked")
	command, pending = CodeActions_TakePending()
	reveal, isReveal := command.(Code_Field_Reveal_Requested)
	testing.expect(t, pending && isReveal && reveal.script == "Hero" && reveal.field == "lives", "the reveal")
	_, _ = CodeActions_Update(&f.state, Msg(reveal))
	testing.expect(t, f.state.selectedNode == f.ship && f.state.currentScene == 1, "the node running it is selected")
	path, line, column, found := ScriptField_Declaration(&f.state, "Hero", "lives")
	testing.expect(t, found && path == f.path && line == LINE_LIVES + 1 && column == 2, "the declaration")
	f.state.codeTab = 0
	_, _ = CodeActions_Update(&f.state, Msg(Script_Field_Declaration_Requested{"Hero", "lives"}))
	caretLine, _ := CodeEditor_Caret(f.path)
	testing.expect(t, f.state.codeTab > 0 && f.state.codeTabs[f.state.codeTab - 1] == f.path && caretLine == LINE_LIVES + 1, "the inspector's label opens the declaration")

	// A handler for a node field's event: the handler before the registration, the subscription in ready
	titles = actionTitles(&f, LINE_CAMERA, 2)
	testing.expectf(t, hasTitle(titles, "Handle camera's onExit"), "a node field's events: %v", titles)
	testing.expect(t, pickAction(&f, LINE_CAMERA, 2, "Handle camera's onExit"), "picked")
	text := CodeEditor_Text(f.path)
	testing.expect(t, strings.contains(text, "Hero_onCameraExit :: proc(_: ^e.EventSubject, source: rawptr, data: e.EventData, user: rawptr) {\n\tself := cast(^Hero)user\n}\n\n@(init)"), "the handler before the registration")
	testing.expect(t, strings.contains(text, "\t\t\tself.speed = 250\n\n\t\t\tif self.camera != nil do e.Event_Subscribe(&self.camera.onExit, Hero_onCameraExit, self)\n\t\t},"), "subscribed at the end of ready")
	undoneAction(t, &f, "handler")
	// From the code too (self.camera in a procedure); the node's own events on the struct's line
	titles = actionTitles(&f, LINE_SPEED + 11, 8)
	testing.expectf(t, !hasTitle(titles, "Handle"), "self.speed has no events: %v", titles)
	titles = actionTitles(&f, 5, 0)
	testing.expectf(t, hasTitle(titles, "Handle its Sprite's onExit"), "the node it runs on (a Sprite): %v", titles)
	testing.expect(t, pickAction(&f, 5, 0, "Handle its Sprite's onExit"), "picked")
	testing.expect(t, strings.contains(CodeEditor_Text(f.path), "if e.Node_Is(self.node, e.Sprite) do e.Event_Subscribe(&(cast(^e.Sprite)self.node).onExit, Hero_onExit, self)"), "the own node's event, through a cast")
	undoneAction(t, &f, "own handler")

	// A switch over the brain's states, on a blank line of ready
	titles = actionTitles(&f, LINE_BLANK, 3)
	testing.expectf(t, hasTitle(titles, "Insert a switch over brain's states (2)"), "the machine's states: %v", titles)
	testing.expect(t, pickAction(&f, LINE_BLANK, 3, "Insert a switch"), "picked")
	testing.expect(t, strings.contains(CodeEditor_Text(f.path), "\t\t\tif self.brain != nil {\n\t\t\t\tswitch e.StateMachine_Current(self.brain) {\n\t\t\t\tcase STATE_PLAY_SCENE_BRAIN_IDLE:\n\t\t\t\tcase STATE_PLAY_SCENE_BRAIN_ATTACK:\n\t\t\t\t}\n\t\t\t}\n"), "a case per STATE_ constant")
	testing.expect_value(t, f.c.ed.buf.cursors[0].pos, cebuf.Position{LINE_BLANK + 2, len("\t\t\t\tcase STATE_PLAY_SCENE_BRAIN_IDLE:")})
	undoneAction(t, &f, "switch")

	// Registering a struct: only one nothing registers
	titles = actionTitles(&f, LINE_LOOSE, 0)
	testing.expectf(t, hasTitle(titles, "Register Loose as a script"), "Loose: %v", titles)
	testing.expect(t, !hasTitle(actionTitles(&f, 5, 0), "Register"), "Hero is registered")
	testing.expect(t, pickAction(&f, LINE_LOOSE, 0, "Register Loose"), "picked")
	text = CodeEditor_Text(f.path)
	testing.expect(t, strings.contains(text, "@(init)\nregister_Loose :: proc \"contextless\" () {\n\te.Script_Register(Loose, {") && strings.contains(text, "update = proc(self: ^Loose, events: []sdl.Event, dt: f64) {"), "New Script's registration")
	testing.expect(t, strings.contains(text, "import e \"engine:.\"\nimport sdl \"vendor:sdl3\"\n"), "the sdl import it needs")
	undoneAction(t, &f, "register")

	// Hooks the registration lacks
	titles = actionTitles(&f, LINE_REGISTER, 2)
	testing.expectf(t, hasTitle(titles, "Add the update hook") && hasTitle(titles, "Add the destroy hook") && !hasTitle(titles, "Add the ready hook") && !hasTitle(titles, "Add the collisionEnter hook"), "the missing hooks: %v", titles)
	testing.expect(t, pickAction(&f, LINE_REGISTER, 2, "Add the destroy hook"), "picked")
	testing.expect(t, strings.contains(CodeEditor_Text(f.path), "\t\t},\n\t\t// When the node is freed\n\t\tdestroy = proc(self: ^Hero) {\n\t\t},\n\t})\n"), "before the literal's brace")
	undoneAction(t, &f, "hook")

	// A struct at the very end of the file (no line break after it): registered after its brace
	testing.expect(t, CodeEditor_ApplyEdits(f.path, {{start = {LINE_LOOSE + 3, 1}, end = {LINE_LOOSE + 4, 0}, text = ""}}), "the last line break gone")
	testing.expect(t, pickAction(&f, LINE_LOOSE, 0, "Register Loose"), "registered at the end")
	text = CodeEditor_Text(f.path)
	testing.expectf(t, strings.contains(text, "\thp: int,\n}\n\n@(init)\nregister_Loose") && strings.has_suffix(text, "\t})\n}"), "after the brace:\n%s", text)
	cebuf.buffer_undo(&f.c.ed.buf)
	cebuf.buffer_undo(&f.c.ed.buf)
	testing.expect(t, CodeEditor_Text(f.path) == f.source, "both undone")
	half := CodeActions_Read("half.odin", "package scripts\n\nimport e \"engine:.\"\n\nHalf :: struct {\n\tusing script: e.Script,\n")
	testing.expect_value(t, len(half.structs), 0)

	// Nothing where none applies: a comment, the using line
	testing.expect_value(t, len(actionTitles(&f, 4, 3)), 0)
	testing.expect_value(t, len(actionTitles(&f, 13, 0)), 0)
	free_all(context.temp_allocator)
}

// The code every action writes compiles (`odin check` with the engine and the project's constants)
@(test)
code_actions_write_code_that_compiles :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	odin := Toolchain_Odin("")
	engine, found := Toolchain_EngineDir()
	if odin == "" || !found {
		testing.expect(t, false, "odin and the engine are needed to compile the actions' code")
		return
	}
	f: ActionsFixture
	if !actionsFixture(t, &f, "editor_test_code_actions_compile") do return
	defer removeAll(f.dir)
	defer State_Destroy(&f.state)
	// Each below the next one's line, so those stay where they are; the registration (adding an
	// import at the top) last, found by its text
	testing.expect(t, pickAction(&f, LINE_SPEED, 2, "Export speed"), "export")
	testing.expect(t, pickAction(&f, LINE_BLANK, 3, "Insert a switch"), "switch")
	testing.expect(t, pickAction(&f, LINE_REGISTER, 2, "Add the destroy hook"), "a hook")
	testing.expect(t, pickAction(&f, LINE_CAMERA, 2, "Handle camera's onExit"), "a handler")
	testing.expect(t, pickAction(&f, 5, 0, "Handle its Sprite's onExit"), "an own handler")
	loose, _ := CodeEditor_FindText(f.path, "Loose :: struct")
	testing.expect(t, pickAction(&f, loose, 0, "Register Loose"), "register")
	register, _ := CodeEditor_FindText(f.path, "e.Script_Register(Hero")
	testing.expect(t, pickAction(&f, register, 2, "Add the update hook"), "a hook using sdl")
	text := CodeEditor_Text(f.path)
	dir := tempDir("editor_test_code_actions_scratch")
	defer removeAll(dir)
	_ = os.write_entire_file(joinPath(dir, "hero.odin", allocator = context.temp_allocator), transmute([]u8)text)
	assets := Scripts_AssetsSource(&f.state.project)
	_ = os.write_entire_file(joinPath(dir, ASSETS_FILE, allocator = context.temp_allocator), transmute([]u8)assets)
	state, stdout, stderr, err := Process_Exec({command = {odin, "check", dir, "-no-entry-point", fmt.tprintf("-collection:engine=%s", engine)}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "the actions' code compiles:\n%s%s\n%s", string(stdout), string(stderr), text)
	free_all(context.temp_allocator)
}
