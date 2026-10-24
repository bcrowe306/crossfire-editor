package crossfire_editor

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import e "engine:."

@(private="file")
HERO_SOURCE :: `package scripts

import e "engine:."

Hero :: struct {
	using script: e.Script,
	speed: f32 ` + "`export:\"default=175\"`" + `,
	hit: e.EventSubject ` + "`event:\"Hit by something\"`" + `,
	tuning: e.DataAsset ` + "`export:\"kind=Tuning\"`" + `,
	camera: ^e.Camera2D ` + "`export:\"default=../Camera\"`" + `,
}

currentHero: ^Hero

Hero_Speed :: proc(hero: ^Hero) -> f32 {
	return hero.speed * 2
}

Hero_Get :: proc() -> ^Hero {
	return currentHero
}

@(init)
register_Hero :: proc "contextless" () {
	e.Script_Register(Hero, {
		ready = proc(self: ^Hero) {
			self.speed = 3
			other := e.Node_GetScript(self.node, Hero)
			other.speed += 1
			h := Hero_Get()
			h.speed = 2
			list: [dynamic]^Hero
			for x in list do x.speed = 0
			e.Event_Notify(&self.hit, self, {})
			_ = e.Node_FindEvent(self.node, "script.hit")
			copy := Hero{speed = 5}
			_ = copy
		},
	})
}
`

@(private="file")
ENEMY_SOURCE :: `package scripts

import e "engine:."

Enemy :: struct {
	using script: e.Script,
	// Another struct's speed: never renamed with Hero's
	speed: f32 ` + "`export:\"default=50\"`" + `,
}

Tuning :: struct {
	gravity: f32 ` + "`export:\"default=10\"`" + `,
}

lookup :: proc() -> rawptr { return nil }

enemyTick :: proc(enemy: ^Enemy, thing: rawptr) {
	enemy.speed = 1
	hero := (^Hero)(thing)
	hero.speed = 4
	// Something whose type the code doesn't show (an undeclared table)
	unknown := things[0]
	unknown.speed = 9
	// The engine's type: known, not Hero's
	body := e.Node_GetParent(enemy.node)
	body.speed = 2
}

@(init)
register_Enemy :: proc "contextless" () {
	e.Script_Register(Enemy, {})
	e.Data_Register(Tuning)
}
`

@(private="file")
linksTestState :: proc() -> State {
	state := State{
		project = Project_CreateTestProject("unused"),
		browserSelection = {kind = .None},
		currentScene = 1,
		selectedNode = -1,
		busSelection = -1,
		layout = {bottomOpen = true},
		settings = Settings_Default(),
	}
	state.settings.builtInCodeEditor = false
	return state
}

@(private="file")
linkNode :: proc(scene: ^SceneDef, name: string, kind: NodeKind, parent: int, position: [2]f32) -> int {
	node := NodeDef_Make(name, kind, parent)
	node.position = position
	append(&scene.nodes, node)
	return len(scene.nodes) - 1
}

@(private="file")
deliver :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

// The scripts as sources at made-up paths, and a state whose catalog the index describes
@(private="file")
linksSources :: proc() -> []CodeSource {
	out := make([]CodeSource, 2, context.temp_allocator)
	out[0] = {path = "/project/scripts/hero.odin", text = HERO_SOURCE}
	out[1] = {path = "/project/scripts/enemy.odin", text = ENEMY_SOURCE}
	return out
}

@(private="file")
indexSources :: proc(state: ^State, sources: []CodeSource) {
	files := make([dynamic]IndexFile)
	defer delete(files)
	for s in sources do append(&files, ScriptIndex_ParseSource(s.path, s.text))
	ScriptIndex_Take(&state.scriptIndex, files[:])
	ScriptIndex_Apply(state)
}

// The 0-based line and the column of the first `text` in a source at or after a line
@(private="file")
findIn :: proc(source, text: string, fromLine := 0) -> (line, column: int) {
	lines := strings.split_lines(source, context.temp_allocator)
	for l, i in lines {
		if i < fromLine do continue
		if at := strings.index(l, text); at >= 0 do return i, at
	}
	return -1, -1
}

@(private="file")
countIn :: proc(rename: CodeRename, path: string) -> int {
	n := 0
	for edit in rename.edits do if edit.path == path do n += 1
	return n
}

// The code side: what's at a position, and every edit a rename of a type, a field, an event and a
// data type makes, across files, leaving another struct's field of the same name alone
@(test)
script_rename_code_types_fields_events :: proc(t: ^testing.T) {
	state := linksTestState()
	defer State_Destroy(&state)
	sources := linksSources()
	indexSources(&state, sources)
	hero, enemy := sources[0].path, sources[1].path

	// A field through a parameter's type
	line, column := findIn(HERO_SOURCE, "hero.speed")
	symbol := ScriptRename_SymbolAt(sources, hero, line, column + 6, &state.scriptIndex, &state.scripts)
	testing.expect_value(t, symbol.kind, ScriptSymbolKind.Field)
	testing.expect_value(t, symbol.owner, "Hero")
	testing.expect_value(t, symbol.field, "speed")
	testing.expect_value(t, symbol.start, column + 5)
	// Enemy's speed is Enemy's
	line, column = findIn(ENEMY_SOURCE, "enemy.speed")
	other := ScriptRename_SymbolAt(sources, enemy, line, column + 7, &state.scriptIndex, &state.scripts)
	testing.expect_value(t, other.owner, "Enemy")
	// A field that isn't exported, and a local, aren't the project's
	line, column = findIn(HERO_SOURCE, "currentHero: ^Hero")
	testing.expect_value(t, ScriptRename_SymbolAt(sources, hero, line, column + 2, &state.scriptIndex, &state.scripts).kind, ScriptSymbolKind.None)

	renamed := ScriptRename_Code(sources, symbol, "walkSpeed")
	testing.expect_value(t, renamed.problem, "")
	// The declaration, hero.speed, self.speed, other.speed (Node_GetScript), h.speed (a package
	// procedure's result), x.speed (a ranged slice), Hero{speed}, and (^Hero)(thing).speed
	testing.expect_value(t, countIn(renamed, hero), 7)
	testing.expect_value(t, countIn(renamed, enemy), 1)
	testing.expect_value(t, len(renamed.unsure), 1) // unknown.speed: its type isn't known
	for edit in renamed.edits do testing.expect_value(t, edit.text, "walkSpeed")

	// The type: every identifier naming it, not the procedures named after it
	line, column = findIn(HERO_SOURCE, "e.Script_Register(Hero")
	typeSymbol := ScriptRename_SymbolAt(sources, hero, line, column + 20, &state.scriptIndex, &state.scripts)
	testing.expect_value(t, typeSymbol.kind, ScriptSymbolKind.Type)
	testing.expect_value(t, typeSymbol.ownerKind, IndexRegistrationKind.Script)
	types := ScriptRename_Code(sources, typeSymbol, "Player")
	// Hero ::, ^Hero x5 (global, param, result, self, list), Node_GetScript(.., Hero),
	// Script_Register(Hero), Hero{...}; enemy.odin's (^Hero)
	testing.expect_value(t, countIn(types, hero), 9)
	testing.expect_value(t, countIn(types, enemy), 1)
	// Taken names
	testing.expect(t, ScriptRename_Code(sources, typeSymbol, "Enemy").problem != "", "a declared name is taken")
	testing.expect(t, ScriptRename_Code(sources, symbol, "camera").problem != "", "a field name is taken")

	// The event: its field, &self.hit and the engine call's "script.hit"
	line, column = findIn(HERO_SOURCE, "&self.hit")
	event := ScriptRename_SymbolAt(sources, hero, line, column + 7, &state.scriptIndex, &state.scripts)
	testing.expect_value(t, event.kind, ScriptSymbolKind.Event)
	events := ScriptRename_Code(sources, event, "onHit")
	testing.expect_value(t, countIn(events, hero), 3)
	strs := 0
	for edit in events.edits do if edit.text == "script.onHit" do strs += 1
	testing.expect_value(t, strs, 1)

	// A data type: its declaration, Data_Register and the field tag's kind=
	line, column = findIn(ENEMY_SOURCE, "e.Data_Register(Tuning")
	data := ScriptRename_SymbolAt(sources, enemy, line, column + 17, &state.scriptIndex, &state.scripts)
	testing.expect_value(t, data.kind, ScriptSymbolKind.Type)
	testing.expect_value(t, data.ownerKind, IndexRegistrationKind.Data)
	tuned := ScriptRename_Code(sources, data, "Settings")
	testing.expect_value(t, countIn(tuned, enemy), 2)
	testing.expect_value(t, countIn(tuned, hero), 1) // kind=Tuning
	free_all(context.temp_allocator)
}

// A project naming Hero everywhere it can: scripts, more scripts, a component and its instance,
// a global, listeners, a Timeline track, a data resource
@(private="file")
linksProject :: proc(state: ^State) -> (ship, extra, listener, animator, component: int) {
	play := &state.project.scenes[1]
	// The Animator first (it's inserted in World's subtree, renumbering what follows)
	world := -1
	for n, i in play.nodes do if n.name == "World" do world = i
	animator = Scene_InsertNode(play, "Anim", .Animator, world)
	ship = -1
	for n, i in play.nodes do if n.name == "Spaceship" do ship = i
	node := &play.nodes[ship]
	delete(node.script)
	node.script = strings.clone("Hero")
	append(&node.props, ScriptPropDef{strings.clone("speed"), strings.clone("250")})
	extra = linkNode(play, "Sidekick", .Sprite, -1, {0, 0})
	append(&play.nodes[extra].moreScripts, NodeScriptDef{name = strings.clone("Hero")})
	append(&play.nodes[extra].moreScripts[0].props, ScriptPropDef{strings.clone("speed"), strings.clone("90")})
	// Listens to the ship's hit, and to the global's
	listener = linkNode(play, "Watcher", .Node2D, -1, {0, 0})
	append(&play.nodes[ship].listeners, e.NodeListenerData{event = strings.clone("script.hit"), target = strings.clone("../Watcher"), handler = strings.clone("onShipHit"), global = strings.clone("")})
	append(&play.nodes[listener].listeners, e.NodeListenerData{event = strings.clone("script.hit"), target = strings.clone("."), handler = strings.clone("onAnyHit"), global = strings.clone("Hero")})
	// A track of the ship's speed (paths from the Animator's parent: World)
	clip := e.AnimatorClipData{name = strings.clone("intro"), length = 1, tracks = make([dynamic]e.AnimatorTrackData)}
	append(&clip.tracks, e.AnimatorTrackData{node = strings.clone("Spaceship"), property = strings.clone("script.speed"), keys = make([dynamic]e.AnimatorKeyData)})
	append(&play.nodes[animator].animator.clips, clip)
	// A component whose root runs Hero, and an instance of it
	comp := SceneDef{name = strings.clone("hero"), component = strings.clone("components/hero.component.xml")}
	root := linkNode(&comp, "HeroRoot", .Sprite, -1, {0, 0})
	delete(comp.nodes[root].script)
	comp.nodes[root].script = strings.clone("Hero")
	append(&comp.nodes[root].props, ScriptPropDef{strings.clone("speed"), strings.clone("300")})
	append(&state.project.scenes, comp)
	component = len(state.project.scenes) - 1
	play = &state.project.scenes[1]
	instance := linkNode(play, "HeroInstance", .Component, -1, {0, 0})
	delete(play.nodes[instance].component)
	play.nodes[instance].component = strings.clone("components/hero.component.xml")
	// A global, and a data resource of Tuning
	global := GlobalDef{script = strings.clone("Hero")}
	append(&global.props, ScriptPropDef{strings.clone("speed"), strings.clone("1")})
	append(&state.project.globals, global)
	data := DataDef{path = strings.clone("data/tuning.data.xml"), type = strings.clone("Tuning")}
	append(&data.values, ScriptPropDef{strings.clone("gravity"), strings.clone("9.8")})
	append(&state.project.data, data)
	return
}

@(private="file")
propNamed :: proc(props: []ScriptPropDef, name: string) -> string {
	for p in props do if p.name == name do return p.value
	return "(none)"
}

// The project side of renames, through the message the code view sends: one undo step each,
// undone and redone; a type, a field, an event and a data type; and the usages listed
@(test)
script_rename_project_side_and_undo :: proc(t: ^testing.T) {
	state := linksTestState()
	defer State_Destroy(&state)
	indexSources(&state, linksSources())
	ship, extra, listener, animator, component := linksProject(&state)
	play := &state.project.scenes[1]

	// Usages: the type's (nodes, the instance, the component's root, the global), the field's
	// (values set first)
	usages := ScriptLinks_TypeUsages(&state, "Hero", .Script)
	testing.expect_value(t, len(usages), 5)
	fields := ScriptLinks_FieldUsages(&state, "Hero", .Script, "speed")
	testing.expect(t, len(fields) >= 5 && fields[0].sets && strings.contains(fields[0].preview, "speed = 250"), "the ship's override first")
	tracks := 0
	for u in fields do if strings.has_prefix(u.preview, "Timeline clip intro") do tracks += 1
	testing.expect_value(t, tracks, 1)
	testing.expect_value(t, len(ScriptLinks_EventUsages(&state, "Hero", .Script, "hit")), 2)

	// The field: stored values everywhere, the track
	speed := ScriptSymbol{kind = .Field, owner = "Hero", ownerKind = .Script, field = "speed"}
	dry := ScriptRename_Project(&state, speed, "walkSpeed", dryRun = true)
	testing.expect_value(t, dry.values, 4)
	testing.expect_value(t, propNamed(play.nodes[ship].props[:], "speed"), "250")
	deliver(&state, Code_Rename_Requested{symbol = speed, newName = "walkSpeed"})
	play = &state.project.scenes[1]
	testing.expect_value(t, propNamed(play.nodes[ship].props[:], "walkSpeed"), "250")
	testing.expect_value(t, propNamed(play.nodes[extra].moreScripts[0].props[:], "walkSpeed"), "90")
	testing.expect_value(t, propNamed(state.project.scenes[component].nodes[0].props[:], "walkSpeed"), "300")
	testing.expect_value(t, propNamed(state.project.globals[0].props[:], "walkSpeed"), "1")
	testing.expect_value(t, play.nodes[animator].animator.clips[0].tracks[0].property, "script.walkSpeed")
	deliver(&state, Action.Undo)
	play = &state.project.scenes[1]
	testing.expect_value(t, propNamed(play.nodes[ship].props[:], "speed"), "250")
	testing.expect_value(t, propNamed(state.project.globals[0].props[:], "speed"), "1")
	testing.expect_value(t, play.nodes[animator].animator.clips[0].tracks[0].property, "script.speed")
	deliver(&state, Action.Redo)
	play = &state.project.scenes[1]
	testing.expect_value(t, propNamed(state.project.scenes[component].nodes[0].props[:], "walkSpeed"), "300")
	deliver(&state, Action.Undo)

	// The event: the ship's listener (it runs Hero) and the global's
	hit := ScriptSymbol{kind = .Event, owner = "Hero", ownerKind = .Script, field = "hit"}
	deliver(&state, Code_Rename_Requested{symbol = hit, newName = "onHit"})
	play = &state.project.scenes[1]
	testing.expect_value(t, play.nodes[ship].listeners[0].event, "script.onHit")
	testing.expect_value(t, play.nodes[listener].listeners[0].event, "script.onHit")
	deliver(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[1].nodes[ship].listeners[0].event, "script.hit")

	// The type: scripts, more scripts, the component's root, the global, the global listener
	hero := ScriptSymbol{kind = .Type, owner = "Hero", ownerKind = .Script}
	deliver(&state, Code_Rename_Requested{symbol = hero, newName = "Player"})
	play = &state.project.scenes[1]
	testing.expect_value(t, play.nodes[ship].script, "Player")
	testing.expect_value(t, play.nodes[extra].moreScripts[0].name, "Player")
	testing.expect_value(t, state.project.scenes[component].nodes[0].script, "Player")
	testing.expect_value(t, state.project.globals[0].script, "Player")
	testing.expect_value(t, play.nodes[listener].listeners[0].global, "Player")
	testing.expect_value(t, len(ScriptLinks_TypeUsages(&state, "Player", .Script)), 5)
	testing.expect_value(t, len(ScriptLinks_TypeUsages(&state, "Hero", .Script)), 0)
	deliver(&state, Action.Undo)
	play = &state.project.scenes[1]
	testing.expect_value(t, play.nodes[ship].script, "Hero")
	testing.expect_value(t, state.project.globals[0].script, "Hero")
	testing.expect_value(t, play.nodes[listener].listeners[0].global, "Hero")

	// A data type and its field
	tuning := ScriptSymbol{kind = .Type, owner = "Tuning", ownerKind = .Data}
	deliver(&state, Code_Rename_Requested{symbol = tuning, newName = "Settings"})
	testing.expect_value(t, state.project.data[0].type, "Settings")
	deliver(&state, Action.Undo)
	gravity := ScriptSymbol{kind = .Field, owner = "Tuning", ownerKind = .Data, field = "gravity"}
	deliver(&state, Code_Rename_Requested{symbol = gravity, newName = "fall"})
	testing.expect_value(t, propNamed(state.project.data[0].values[:], "fall"), "9.8")
	deliver(&state, Action.Undo)
	testing.expect_value(t, propNamed(state.project.data[0].values[:], "gravity"), "9.8")
	free_all(context.temp_allocator)
}

// In a real code tab: F2's provider renames the field in the shown file as one undo step, the
// other file in its own (hidden) tab, and the project in one step; Find Usages lists the nodes;
// the field's marker lists who sets it
@(test)
script_rename_in_code_tabs :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	defer CodeProviders_Shutdown()
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, "editor_test_script_rename"}, context.temp_allocator)
	_ = removeAll(dir)
	defer removeAll(dir)
	folder := joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	_ = os.write_entire_file(joinPath(folder, "hero.odin", allocator = context.temp_allocator), transmute([]u8)string(HERO_SOURCE))
	_ = os.write_entire_file(joinPath(folder, "enemy.odin", allocator = context.temp_allocator), transmute([]u8)string(ENEMY_SOURCE))
	heroPath := absolutePath(joinPath(folder, "hero.odin", allocator = context.temp_allocator))
	enemyPath := absolutePath(joinPath(folder, "enemy.odin", allocator = context.temp_allocator))

	state := State{project = Project_CreateTestProject(dir), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(), currentScene = 1}
	defer State_Destroy(&state)
	state.settings.olsPath = FixedText_Make("/nonexistent/ols")
	state.settings.builtInCodeEditor = true
	ship, _, _, _, _ := linksProject(&state)
	sources := ScriptIndex_Plan(&state.scriptIndex, absolutePath(folder))
	files, _ := ScriptIndex_ParseAll(sources[:])
	for s in sources { delete(s.path); delete(s.text) }
	delete(sources)
	ScriptIndex_Take(&state.scriptIndex, files)
	delete(files)
	ScriptIndex_Apply(&state)

	_ = Script_Open(&state, heroPath, 1)
	c := CodeEditor_Find(heroPath)
	if c == nil {
		testing.expectf(t, false, "open %q", heroPath)
		return
	}
	testing.expect_value(t, len(state.codeTabs), 1)

	// The field's marker: who sets it, a menu of them
	CodeProviders_Begin(&state)
	ce.editor_run_cached_providers(&c.ed)
	CodeProviders_End()
	speedLine, speedColumn := findIn(HERO_SOURCE, "speed: f32")
	inlays, marker := CodeEditor_LineNotes(heroPath, speedLine)
	testing.expect(t, marker, "a marker on the speed field")
	testing.expect(t, strings.contains(inlays, "3 nodes override it, a global sets it, 1 Timeline track"), inlays)
	markers := ce.editor_gutter_markers_on(&c.ed, speedLine)
	testing.expect(t, len(markers) == 1 && len(markers[0].choices) == 5, "the 3 nodes, the global and the track")
	// Choosing the first opens the ship
	CodeProviders_Begin(&state)
	m := markers[0]
	m.choice = 0
	for p in CodeProviders_Registry().providers do if p.kind == .Gutter do p.on_click(ce.editor_provider_document(&c.ed), m, nil)
	CodeProviders_End()
	target, _, opened := CodeProviders_TakeOpen()
	testing.expect(t, opened && target.kind == .Node && target.scene == 1 && target.node == ship, "the ship")
	deliver(&state, Code_Usage_Opened{target = target})
	testing.expect_value(t, state.selectedNode, ship)

	// Find Usages on the field
	CodeProviders_Begin(&state)
	c.ed.buf.cursors[0] = {pos = {speedLine, speedColumn + 1}}
	ce.editor_find_usages(&c.ed)
	CodeProviders_End()
	_, refsOpen, refs := CodeEditor_Navigation(heroPath)
	testing.expect(t, refsOpen && refs >= 5, "the usages in the references panel")

	// F2 on it, a new name, Enter
	CodeProviders_Begin(&state)
	ce.editor_start_rename(&c.ed)
	testing.expect(t, ce.editor_rename_open(&c.ed), "the rename box")
	testing.expect(t, strings.contains(c.ed.rename.target.note, "4 stored values"), c.ed.rename.target.note)
	ce.editor_rename_text_input(&c.ed, "walkSpeed")
	ce.editor_commit_rename(&c.ed)
	CodeProviders_End()
	testing.expect(t, !ce.editor_rename_open(&c.ed), "closed")
	text := CodeEditor_Text(heroPath)
	testing.expect(t, strings.contains(text, "walkSpeed: f32") && strings.contains(text, "self.walkSpeed = 3") && !strings.contains(text, ".speed"), "this file renamed")
	rename, has := CodeProviders_TakeRename()
	testing.expect(t, has, "the project side waits for the view")
	deliver(&state, rename)
	testing.expect_value(t, propNamed(state.project.scenes[1].nodes[ship].props[:], "walkSpeed"), "250")
	// The other file: a hidden tab with its edit, unsaved; the shown tab stays
	testing.expect_value(t, len(state.codeTabs), 2)
	testing.expect_value(t, CodeTabs_Active(&state), heroPath)
	testing.expect(t, strings.contains(CodeEditor_Text(enemyPath), "hero.walkSpeed = 4"), "the other file")
	testing.expect(t, strings.contains(CodeEditor_Text(enemyPath), "enemy.speed = 1"), "Enemy's speed stays")
	testing.expect(t, CodeEditor_IsDirty(enemyPath), "left unsaved")
	// Undo: each tab's own, and the project's step
	other := CodeEditor_Find(enemyPath)
	_ = cebuf.buffer_undo(&other.ed.buf)
	testing.expect(t, strings.contains(CodeEditor_Text(enemyPath), "hero.speed = 4"), "the other file's undo")
	_ = cebuf.buffer_undo(&c.ed.buf)
	testing.expect(t, strings.contains(CodeEditor_Text(heroPath), "self.speed = 3"), "this file's undo, one step")
	deliver(&state, Action.Undo)
	testing.expect_value(t, propNamed(state.project.scenes[1].nodes[ship].props[:], "speed"), "250")
	free_all(context.temp_allocator)
}

// The demo: renaming Hero and its speed (dry runs) finds its uses across files and its LDtk
// entities (they run Hero by their name: a rule keeps them on it), and how long it takes
@(test)
script_rename_demo_project_timing :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
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

	code := scriptSources(&state)
	hero := ScriptSymbol{kind = .Type, owner = "Hero", ownerKind = .Script}
	start := time.tick_now()
	types := ScriptRename_Code(code, hero, "Lyra")
	took := time.tick_since(start)
	testing.expect_value(t, types.problem, "")
	testing.expect(t, len(types.edits) >= 15, "Hero is named all over the scripts")
	counts := ScriptRename_Project(&state, hero, "Lyra", dryRun = true)
	testing.expect(t, counts.rules > 0, "LDtk entities named Hero get a rule")
	speed := ScriptSymbol{kind = .Field, owner = "Hero", ownerKind = .Script, field = "speed"}
	fields := ScriptRename_Code(code, speed, "runSpeed")
	testing.expect_value(t, fields.problem, "")
	testing.expect(t, len(fields.edits) == 2 && len(fields.unsure) == 0, "the field and its one use; nothing left (the engine's .speed fields are known to be the engine's)")
	log.infof("demo: renaming Hero: %d edits in %v (%d files); its speed: %d edits, %d left (%v); the project: %s",
		len(types.edits), took, len(code), len(fields.edits), len(fields.unsure), fields.unsure[:], ProjectRenameCounts_Text(counts))
	free_all(context.temp_allocator)
}
