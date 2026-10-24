package crossfire_editor

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import vmem "core:mem/virtual"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import syn "code_editor/syntax"
import e "engine:."

// The engine's name parameters, read from its source: every kind, groups, named arguments, and
// which procedures declare names
@(test)
name_table_reads_the_engines_name_parameters :: proc(t: ^testing.T) {
	arena: vmem.Arena
	_ = vmem.arena_init_growing(&arena)
	defer vmem.arena_destroy(&arena)
	table := NameTable_Read(ENGINE_DIR, vmem.arena_allocator(&arena))
	if !testing.expect(t, table != nil, "the engine has name types") do return
	log.infof("name table: %d procedures from %d files in %v", len(table.procs), table.files, table.took)

	Want :: struct { procName: string, index: int, argName: string, kind: NameKind, declares: bool }
	wants := [?]Want{
		{"Node_FindPath", 1, "", .Node_Path, false},
		{"Camera2D_SetFollowTargetPath", 1, "", .Node_Path, false},
		{"Node_FindChild", 1, "", .Child_Path, false},
		{"Scene_FindNode", 1, "", .Scene_Path, false},
		// A group: its members' parameters
		{"AnimationPlayer_Play", 1, "", .Animation, false},
		{"AnimationPlayer_IsPlaying", 1, "", .Animation, false},
		{"Input_IsActionJustPressed", 0, "", .Action, false},
		{"Input_GetVector", 3, "", .Action, false},
		{"Player_IsActionPressed", 1, "", .Action, false},
		{"Input_AddAction", 0, "", .Action, true},
		{"Scene_GetGroup", 1, "", .Group, false},
		{"Node_AddToGroup", 1, "", .Group, true},
		{"Audio_SetBusEffects", 0, "", .Bus, false},
		{"Audio_AddBus", 0, "", .Bus, true},
		// A group whose members differ: a path at 1 in one, a handle in the other; named `bus`
		{"Game_PlaySound", 1, "", .Sound_Path, false},
		{"Game_PlaySound", 0, "bus", .Bus, false},
		{"Game_ChangeScene", 1, "", .Scene, false},
		{"Game_PushScene", 1, "", .Scene, false},
		{"Game_CreateScene", 1, "", .Scene, true},
		{"StateMachine_Travel", 1, "", .State, false},
		{"StateMachine_SetBool", 1, "", .State_Param, false},
		{"Animator_Play", 1, "", .Clip, false},
		{"Dialogue_Start", 2, "", .Dialogue_Node, false},
		{"DialogueBox_Start", 1, "", .Dialogue_Node, false},
		// "Create" without "_": a use (the box's first node)
		{"CreateDialogueBox", 2, "", .Dialogue_Node, false},
		{"Steam_UnlockAchievement", 0, "", .Achievement, false},
		// A declaring procedure's path is still a use
		{"MusicPlayer_AddLayer", 2, "", .Sound_Path, false},
	}
	for w in wants {
		kind, declares := NameTable_ParamKind(table, w.procName, w.index, w.argName)
		testing.expectf(t, kind == w.kind && declares == w.declares, "%s(%d %s): %v declares %v (got %v %v)", w.procName, w.index, w.argName, w.kind, w.declares, kind, declares)
	}
	// Not names: another argument, another procedure
	kind, _ := NameTable_ParamKind(table, "Node_FindPath", 0)
	testing.expect_value(t, kind, NameKind.None)
	kind, _ = NameTable_ParamKind(table, "Game_SetFullscreen", 1)
	testing.expect_value(t, kind, NameKind.None)
	// Every kind is taken somewhere
	used: bit_set[NameKind]
	for _, p in table.procs do for param in p.params do used += {param.kind}
	for k in NameKind do if k != .None do testing.expectf(t, k in used, "a procedure takes %v", k)
}

@(private="file")
NAMES_SOURCE :: `package scripts

import e "engine:."

Probe :: struct {
	using script: e.Script,
	sprite: ^e.AnimatedSprite ` + "`export:\"default=Sprite\"`" + `,
	brain: ^e.StateMachine ` + "`export:\"default=Brain\"`" + `,
}

@(init)
register_Probe :: proc "contextless" () {
	e.Script_Register(Probe, {
		ready = proc(self: ^Probe) {
			_ = e.Node_FindPath(self.node, "../Camera")
			_ = e.Node_FindPath(self.node, "Sprit")
			_ = e.Node_FindChild(self.node, "Sprite/Missing")
			e.AnimationPlayer_Play(&self.sprite.animation, "runn")
			_ = e.StateMachine_Is(self.brain, "atack")
			e.StateMachine_SetFloat(self.brain, "speed", 1)
			e.Game_ChangeScene(self.game, "PlayScen")
			_ = e.Input_IsActionPressed("ui_acept")
			e.Node_AddToGroup(self.node, "fresh")
			_ = e.Scene_GetGroup(self.scene, "fresh")
			_ = e.Scene_GetGroup(self.scene, "enemiez")
			e.Audio_SetBusVolume("Musik", 1)
			name := "PlayScen"
			e.Game_ChangeScene(self.game, name)
			e.Game_PlaySound(self.game, "assets/nope.wav", bus = "SFXX")
			_ = e.Scene_FindNode(self.scene, "HUD")
			_ = e.Node_FindPath(self.node, "Sprite")
			_ = e.Node_FindPath(self.node, "")
			_ = e.Node_FindPath(self.node, "")
			e.Game_ChangeScene(self.game, )
			e.Game_PlaySound(self.game, "x.wav", bus = "")
		},
	})
}
`

// A project for the name providers: a component Hero (a sprite, a state machine) whose root runs
// Probe, instanced in PlayScene under World and at OptionsScene's top level (two trees)
@(private="file")
namesState :: proc(t: ^testing.T, dir: string) -> (state: State, path: string) {
	_ = removeAll(dir)
	folder := joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	path = absolutePath(joinPath(folder, "probe.odin", allocator = context.temp_allocator))
	_ = os.write_entire_file(path, transmute([]u8)string(NAMES_SOURCE))
	path = absolutePath(path)

	state = State{project = Project_CreateTestProject(dir), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(), currentScene = 1}
	append(&state.project.buses, BusDef{name = strings.clone("Music"), volume = 1}, BusDef{name = strings.clone("SFX"), volume = 1})
	hero := SceneDef{name = strings.clone("hero"), component = strings.clone("components/hero.component.xml")}
	root := NodeDef_Make("Hero", .Node2D, -1)
	root.script = strings.clone("Probe")
	append(&hero.nodes, root)
	sprite := NodeDef_Make("Sprite", .AnimatedSprite, 0)
	for &a in sprite.animations { delete(a.name); delete(a.sheet); delete(a.durations) }
	clear(&sprite.animations)
	append(&sprite.animations, AnimationDef{name = strings.clone("run")}, AnimationDef{name = strings.clone("idle")})
	append(&hero.nodes, sprite)
	brain := NodeDef_Make("Brain", .StateMachine, 0)
	append(&brain.stateMachine.states, e_State("idle"), e_State("attack"))
	append(&brain.stateMachine.params, e_Param("speed"))
	append(&hero.nodes, brain)
	append(&state.project.scenes, hero)
	play := &state.project.scenes[1]
	world := -1
	for n, i in play.nodes do if n.name == "World" do world = i
	instance := NodeDef_Make("Hero", .Component, world)
	instance.component = strings.clone("components/hero.component.xml")
	append(&play.nodes, instance)
	options := &state.project.scenes[2]
	other := NodeDef_Make("Hero", .Component, -1)
	other.component = strings.clone("components/hero.component.xml")
	append(&options.nodes, other)

	sources := ScriptIndex_Plan(&state.scriptIndex, absolutePath(folder))
	files, _ := ScriptIndex_ParseAll(sources[:])
	for s in sources { delete(s.path); delete(s.text) }
	delete(sources)
	ScriptIndex_Take(&state.scriptIndex, files)
	delete(files)
	ScriptIndex_Apply(&state)
	testing.expect(t, ScriptCatalog_Find(&state.scripts, "Probe") != nil, "Probe indexed")
	return
}

@(private="file")
e_State :: proc(name: string) -> (s: e.StateMachineState) {
	s.name = strings.clone(name)
	return
}

@(private="file")
e_Param :: proc(name: string) -> (p: e.StateMachineParam) {
	p.name = strings.clone(name)
	return
}

// The completions the name providers offer at a position of a buffer (labels and details)
@(private="file")
completionsAt :: proc(state: ^State, path: string, b: ^cebuf.Buffer, pos: cebuf.Position) -> []ce.Provider_Completion {
	out := make([dynamic]ce.Provider_Completion, context.temp_allocator)
	line := cebuf.buffer_line_str(b, pos.line)
	start := pos.col
	for start > 0 && (line[start - 1] == '_' || line[start - 1] >= 'a' && line[start - 1] <= 'z' || line[start - 1] >= 'A' && line[start - 1] <= 'Z' || line[start - 1] >= '0' && line[start - 1] <= '9') do start -= 1
	ctx := ce.Provider_Context{prefix = line[start:pos.col], syntax = ce.syntax_context_of(b, syn.odin_language(), pos), allocator = context.temp_allocator}
	nameCompletions({path = path, buffer = b}, pos, ctx, &out)
	return out[:]
}

@(private="file")
hasLabel :: proc(items: []ce.Provider_Completion, label: string) -> (ce.Provider_Completion, bool) {
	for c in items do if c.label == label do return c, true
	return {}, false
}

// The line of the source holding a text, and the column after it
@(private="file")
findIn :: proc(b: ^cebuf.Buffer, text: string) -> cebuf.Position {
	for i in 0 ..< cebuf.buffer_line_count(b) {
		if at := strings.index(cebuf.buffer_line_str(b, i), text); at >= 0 do return {i, at + len(text)}
	}
	return {-1, -1}
}

// Completion inside each kind's string arguments and outside them, and the problems with their
// quick fixes, the script running on two nodes of different trees
@(test)
names_complete_and_report_per_kind :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	if NameTable_Load(ENGINE_DIR) == nil {
		testing.expect(t, false, "the engine's names")
		return
	}
	base := testTempBase()
	dir, _ := filepath.join({base, "editor_test_code_names"}, context.temp_allocator)
	defer removeAll(dir)
	state, path := namesState(t, dir)
	defer State_Destroy(&state)
	b := cebuf.buffer_init()
	defer cebuf.buffer_destroy(&b)
	cebuf.buffer_set_text(&b, NAMES_SOURCE)
	CodeProviders_Begin(&state)
	defer CodeProviders_End()

	// --- the problems
	diags := make([dynamic]ce.Provider_Diagnostic, context.temp_allocator)
	nameDiagnostics({path = path, buffer = &b}, {allocator = context.temp_allocator}, &diags)
	find :: proc(diags: []ce.Provider_Diagnostic, text: string) -> (ce.Provider_Diagnostic, bool) {
		for d in diags do if strings.contains(d.message, text) do return d, true
		return {}, false
	}
	for d in diags do log.infof("problem: %s (%d fixes)", d.message, len(d.fixes))
	d, ok := find(diags[:], `"../Camera"`)
	testing.expect(t, ok && d.message == `No node "../Camera" from OptionsScene/Hero (it's there from PlayScene/World/Hero)`, "a path that fails from one of two nodes says which")
	testing.expect(t, ok && len(d.fixes) == 0, "no fix that fits both")
	d, ok = find(diags[:], `"Sprit"`)
	testing.expect(t, ok && strings.contains(d.message, `did you mean "Sprite"?`), "a misspelled child")
	testing.expect(t, ok && len(d.fixes) == 2 && d.fixes[0].edits[0].text == `"Sprite"` && d.fixes[0].preferred, "replace with the closest")
	testing.expect(t, ok && len(d.fixes) == 2 && d.fixes[1].title == "Use PATH_HERO_SPRITE", "or its constant")
	if ok {
		at := findIn(&b, `"Sprit"`)
		testing.expect(t, d.start == {at.line, at.col - 7} && d.end == at, "on the literal, quotes included")
	}
	_, ok = find(diags[:], `"Sprite/Missing"`)
	testing.expect(t, ok, "a child path")
	d, ok = find(diags[:], `"runn"`)
	testing.expect(t, ok && d.message == `PlayScene/World/Hero/Sprite has no animation "runn": did you mean "run"?`, "the field's sprite's animations")
	d, ok = find(diags[:], `"atack"`)
	testing.expect(t, ok && strings.contains(d.message, `did you mean "attack"?`), "the machine's states")
	_, ok = find(diags[:], `"speed"`)
	testing.expect(t, !ok, "a parameter it has")
	d, ok = find(diags[:], `"PlayScen"`)
	testing.expect(t, ok && strings.contains(d.message, `No scene "PlayScen": did you mean "PlayScene"?`), "a scene")
	testing.expect(t, ok && len(d.fixes) == 2 && d.fixes[1].edits[0].text == "SCENE_PLAY_SCENE", "its constant")
	n := 0
	for x in diags do if strings.contains(x.message, `"PlayScen"`) do n += 1
	testing.expect_value(t, n, 1) // the variable isn't checked
	d, ok = find(diags[:], `"ui_acept"`)
	testing.expect(t, ok && strings.contains(d.message, `did you mean "ui_accept"?`) && strings.contains(d.message, "Project Settings > Input"), "an action")
	_, ok = find(diags[:], `"fresh"`)
	testing.expect(t, !ok, "a group code declares")
	d, ok = find(diags[:], `"enemiez"`)
	testing.expect(t, ok && d.message == `No group "enemiez" in the project`, "a group nobody has")
	d, ok = find(diags[:], `"Musik"`)
	testing.expect(t, ok && strings.contains(d.message, `did you mean "Music"?`) && len(d.fixes) == 2 && d.fixes[1].title == "Use BUS_MUSIC", "a bus, and its constant")
	_, ok = find(diags[:], `"SFXX"`)
	testing.expect(t, ok, "a named bus argument")
	_, ok = find(diags[:], `"assets/nope.wav"`)
	testing.expect(t, ok, "a sound file that isn't there")
	d, ok = find(diags[:], `"HUD"`)
	testing.expect(t, ok && strings.contains(d.message, "from OptionsScene/Hero (it's there from PlayScene/World/Hero)"), "a scene path from the node's scene")
	_, ok = find(diags[:], `No node "Sprite" `)
	testing.expect(t, !ok, "a path that's there from both")

	// --- completion inside strings
	type :: proc(b: ^cebuf.Buffer, at: cebuf.Position, text: string) -> cebuf.Position {
		return cebuf.buffer_insert_text(b, at, text)
	}
	empty := findIn(&b, `self.node, "`)
	items := completionsAt(&state, path, &b, empty)
	_, sprite := hasLabel(items, "Sprite")
	_, brainOk := hasLabel(items, "Brain")
	up, parent := hasLabel(items, "..")
	testing.expect(t, sprite && brainOk && parent && strings.contains(up.documentation, "World"), "the node's children and its parent")
	at := type(&b, empty, "../")
	items = completionsAt(&state, path, &b, at)
	camera, cameraOk := hasLabel(items, "Camera")
	_, info := hasLabel(items, "Info")
	testing.expect(t, cameraOk && info, "the parent's children, from both nodes")
	testing.expect(t, cameraOk && strings.contains(camera.detail, "from 1 of 2 nodes") && camera.replace_start.? == empty.col + 3, "where it is, and what it replaces")
	at = type(&b, at, "Ca")
	items = completionsAt(&state, path, &b, at)
	camera, cameraOk = hasLabel(items, "Camera")
	testing.expect(t, cameraOk && camera.filter_text == "Camera", "filtered by the word")

	anim := findIn(&b, `animation, "`)
	cebuf.buffer_delete_range(&b, anim, {anim.line, anim.col + 4})
	items = completionsAt(&state, path, &b, anim)
	_, run := hasLabel(items, "run")
	_, idle := hasLabel(items, "idle")
	testing.expect(t, run && idle && len(items) == 2, "the field's sprite's animations")

	param := findIn(&b, `self.brain, "`)
	items = completionsAt(&state, path, &b, param)
	_, attack := hasLabel(items, "attack")
	testing.expect(t, attack, "the machine's states")
	param = findIn(&b, `SetFloat(self.brain, "`)
	cebuf.buffer_delete_range(&b, param, {param.line, param.col + 5})
	items = completionsAt(&state, path, &b, param)
	_, speed := hasLabel(items, "speed")
	testing.expect(t, speed && len(items) == 1, "its parameters")

	scene := findIn(&b, `self.game, "`)
	cebuf.buffer_delete_range(&b, scene, {scene.line, scene.col + 8})
	items = completionsAt(&state, path, &b, scene)
	_, playScene := hasLabel(items, "PlayScene")
	_, component := hasLabel(items, "hero")
	testing.expect(t, playScene && !component && len(items) == 3, "the scenes, not the components")

	bus := findIn(&b, `"x.wav", bus = "`)
	items = completionsAt(&state, path, &b, bus)
	_, sfx := hasLabel(items, "SFX")
	_, master := hasLabel(items, "Master")
	testing.expect(t, sfx && master, "a named argument's kind")

	// --- outside a string: the constants first
	CodeProviders_Constants(&state)
	outside := findIn(&b, "self.game, )")
	items = completionsAt(&state, path, &b, {outside.line, outside.col - 1})
	constant, constantOk := hasLabel(items, "SCENE_PLAY_SCENE")
	testing.expect(t, constantOk && constant.priority > 1, "the scenes' constants, ranked first")
	_, notScene := hasLabel(items, "BUS_SFX")
	testing.expect(t, !notScene, "only that kind")
	free_all(context.temp_allocator)
}

// How long the name providers take on the demo: its largest script's problems and a completion
@(test)
names_demo_project_timing :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	start := time.tick_now()
	if NameTable_Load(ENGINE_DIR) == nil {
		testing.expect(t, false, "the engine's names")
		return
	}
	loaded := time.tick_since(start)
	project, message, _ := Project_Load(DEMO_PROJECT)
	testing.expect_value(t, message, "")
	state := State{project = project, browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	defer State_Destroy(&state)
	folder := absolutePath(joinPath(DEMO_PROJECT, SCRIPTS_FOLDER, allocator = context.temp_allocator))
	sources := ScriptIndex_Plan(&state.scriptIndex, folder)
	files, _ := ScriptIndex_ParseAll(sources[:])
	for s in sources { delete(s.path); delete(s.text) }
	delete(sources)
	ScriptIndex_Take(&state.scriptIndex, files)
	delete(files)
	ScriptIndex_Apply(&state)
	CodeProviders_Begin(&state)
	defer CodeProviders_End()
	_ = CodeProviders_Constants(&state)

	// Every script's problems: none (the demo is right: no false positives)
	calls, slowest := 0, time.Duration(0)
	slowestFile := ""
	for file, &f in state.scriptIndex.files {
		text, _ := os.read_entire_file(file, context.temp_allocator)
		fb := cebuf.buffer_init()
		cebuf.buffer_set_text(&fb, string(text))
		diags: [dynamic]ce.Provider_Diagnostic
		took := time.Duration(max(i64))
		for _ in 0 ..< TIMING_RUNS {
			diags = make([dynamic]ce.Provider_Diagnostic, context.temp_allocator)
			start = time.tick_now()
			nameDiagnostics({path = file, buffer = &fb}, {allocator = context.temp_allocator}, &diags)
			took = min(took, time.tick_since(start))
		}
		if took > slowest do slowest, slowestFile = took, filepath.base(file)
		calls += len(f.calls)
		for d in diags do log.errorf("demo problem in %s:%d: %s", filepath.base(file), d.start.line + 1, d.message)
		testing.expectf(t, len(diags) == 0, "%s has no name problems", filepath.base(file))
		cebuf.buffer_destroy(&fb)
	}
	checked := slowest

	path := absolutePath(joinPath(folder, "hero.odin", allocator = context.temp_allocator))
	text, _ := os.read_entire_file(path, context.temp_allocator)
	b := cebuf.buffer_init()
	defer cebuf.buffer_destroy(&b)
	cebuf.buffer_set_text(&b, string(text))

	// A completion in a string: StateMachine_Is(self.brain, "|
	at := findIn(&b, `StateMachine_Is(self.brain, "`)
	items: []ce.Provider_Completion
	completed := time.Duration(max(i64))
	for _ in 0 ..< TIMING_RUNS {
		start = time.tick_now()
		items = completionsAt(&state, path, &b, at)
		completed = min(completed, time.tick_since(start))
	}
	_, attack := hasLabel(items, "attack")
	testing.expect(t, attack, "the hero's brain's states")
	// And outside one: the parameters' constants
	at = findIn(&b, "e.StateMachine_SetFloat(self.brain, ")
	constants := time.Duration(max(i64))
	for _ in 0 ..< TIMING_RUNS {
		start = time.tick_now()
		items = completionsAt(&state, path, &b, at)
		constants = min(constants, time.tick_since(start))
	}
	_, speed := hasLabel(items, "PARAM_HERO_BRAIN_SPEED")
	testing.expect(t, speed, "the brain's parameters' constants")
	log.infof("names, demo: table %v; %d literals in %d files, the slowest file (%s) checked in %v; a completion in a string %v, of constants %v", loaded, calls, len(state.scriptIndex.files), slowestFile, checked, completed, constants)
	// The best of TIMING_RUNS each; generous limits (0.07 ms and 0.6 ms here, optimized)
	testing.expectf(t, checked < 100 * time.Millisecond && completed < 50 * time.Millisecond, "fast enough: %v, %v", checked, completed)
	free_all(context.temp_allocator)
}
