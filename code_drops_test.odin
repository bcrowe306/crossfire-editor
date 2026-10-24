package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import e "engine:."

// Drops into code (code_drops.odin): the table and the keys of the engine's uses, then each kind
// of source in a struct, a procedure and on an argument in a real code tab, the menu's choices,
// and every engine use filled in and compiled.

@(private="file")
DROP_SOURCE :: `package scripts

import e "engine:."

Probe :: struct {
	using script: e.Script,
	speed: f32 ` + "`export:\"default=1\"`" + `,
}

@(init)
register_Probe :: proc "contextless" () {
	e.Script_Register(Probe, {
		ready = proc(self: ^Probe) {
			e.Input_IsActionPressed()
			_ = e.Node_FindPath(self.node, "")

		},
	})
}
`

// Lines of DROP_SOURCE (0-based)
@(private="file") LINE_FIELD :: 6
@(private="file") LINE_CALL :: 13
@(private="file") LINE_STRING :: 14
@(private="file") LINE_BLANK :: 15

@(test)
code_drops_table_and_use_keys :: proc(t: ^testing.T) {
	field, _, ok := CodeDrops_PropertyField(.Label, "Font size")
	testing.expect(t, ok && field == "size", "a Label's font size is its size")
	field, _, ok = CodeDrops_PropertyField(.Sprite, "Position X")
	testing.expect(t, ok && field == "position.x", "a component of a vector")
	field, _, ok = CodeDrops_PropertyField(.Sprite, "Z index")
	testing.expect(t, ok && field == "zIndex", "words in lowerCamelCase")
	field, _, ok = CodeDrops_PropertyField(.Sprite, "Blend")
	testing.expect(t, ok && field == "blendMode", "an alias")
	_, _, ok = CodeDrops_PropertyField(.Sprite, "Type")
	testing.expect(t, !ok, "a typeid isn't a property code sets")
	_, _, ok = CodeDrops_PropertyField(.Sprite, "Sheets")
	testing.expect(t, !ok, "no such field")
	chain := CodeDrops_TypeChain(.Button)
	testing.expectf(t, len(chain) == 3 && chain[0] == "Button" && chain[1] == "Control" && chain[2] == "Node", "a node kind's types, its own first: %v", chain)

	state := State{project = Project_CreateTestProject("/nowhere"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(), currentScene = 1}
	defer State_Destroy(&state)
	keys := codeUseKeys(&state, DropSource{kind = .State_Param, name = "attack", node = -1, index = -1, detail = "Trigger"})
	testing.expect(t, len(keys) == 2 && keys[0] == "StateParamName:Trigger" && keys[1] == "StateParamName", "a parameter's kind first")
	keys = codeUseKeys(&state, DropSource{kind = .Asset, node = -1, index = 0})
	testing.expect(t, len(keys) == 1 && keys[0] == "TextureAsset", "an image's handle type")
	// Every kind of name the table names has uses in the engine
	for k, kind in CODE_DROP_KINDS {
		if k.nameKind == .None || kind == .Node do continue
		testing.expectf(t, len(e.CodeUses_For(NAME_KIND_TYPES[k.nameKind])) > 0, "%v: the engine has uses of %s", kind, NAME_KIND_TYPES[k.nameKind])
	}
}

// A project with a script on Spaceship in a code tab, and nodes of every kind a drop names
@(private="file")
DropFixture :: struct {
	state: State,
	dir, path: string,
	c: ^CodeEditor,
	ship, light, brain, animator, player: int,
	animation: string,
}

@(private="file")
dropFixture :: proc(t: ^testing.T, f: ^DropFixture, name: string) -> bool {
	base := testTempBase()
	f.dir, _ = filepath.join({base, name}, context.temp_allocator)
	_ = removeAll(f.dir)
	folder := joinPath(f.dir, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	f.path = absolutePath(joinPath(folder, "probe.odin", allocator = context.temp_allocator))
	_ = os.write_entire_file(f.path, transmute([]u8)string(DROP_SOURCE))
	f.path = absolutePath(f.path)

	f.state = State{project = Project_CreateTestProject(f.dir), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(), currentScene = 1}
	f.state.settings.olsPath = FixedText_Make("/nonexistent/ols")
	f.state.settings.builtInCodeEditor = true
	play := &f.state.project.scenes[1]
	for n, i in play.nodes {
		if n.name == "Spaceship" do f.ship = i
		if n.name == "ShipLight" do f.light = i
	}
	delete(play.nodes[f.ship].script)
	play.nodes[f.ship].script = strings.clone("Probe")
	play.nodes[f.ship].groups = strings.clone("ships")
	f.animation = play.nodes[f.light].animations[0].name
	// A state machine, an Animator and a sound player at the top level
	brain := NodeDef_Make("Brain", .StateMachine, -1)
	append(&brain.stateMachine.params, e.StateMachineParam{name = strings.clone("attack"), kind = .Trigger, value = strings.clone("")})
	append(&brain.stateMachine.states, e.StateMachineState{name = strings.clone("idle"), animation = strings.clone("")})
	append(&play.nodes, brain)
	f.brain = len(play.nodes) - 1
	animator := NodeDef_Make("Intro", .Animator, -1)
	append(&animator.animator.clips, e.AnimatorClipData{name = strings.clone("fly"), length = 1})
	append(&play.nodes, animator)
	f.animator = len(play.nodes) - 1
	append(&play.nodes, NodeDef_Make("Jump", .AudioPlayer, -1))
	f.player = len(play.nodes) - 1

	// The index reads the script: its fields are known before a build
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

// Drops a source at a position; returns the result and the line(s) there after
@(private="file")
dropAt :: proc(f: ^DropFixture, src: DropSource, line, col: int, menu := false) -> (message: string, handled: bool) {
	CodeProviders_Begin(&f.state)
	defer CodeProviders_End()
	source := src
	message, handled = ce.editor_drop_at(&f.c.ed, {line, col}, ce.Drop_Request{kind = CODE_DROP_SOURCE, data = &source, menu = menu})
	if problem := CodeProviders_TakeDropProblem(); problem != "" do message = problem
	return
}

@(private="file")
dropText :: proc(f: ^DropFixture) -> string {
	return CodeEditor_Text(f.path)
}

// Undoes the drop: one step, back to the file as it was
@(private="file")
undone :: proc(t: ^testing.T, f: ^DropFixture, what: string) {
	cebuf.buffer_undo(&f.c.ed.buf)
	testing.expectf(t, dropText(f) == DROP_SOURCE, "%s: one undo step takes it all back:\n%s", what, dropText(f))
}

@(test)
code_drops_by_context :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	f: DropFixture
	if !dropFixture(t, &f, "editor_test_code_drops") do return
	defer removeAll(f.dir)
	defer State_Destroy(&f.state)

	call := strings.index(DROP_SOURCE_LINES()[LINE_CALL], "()") + 1
	quote := strings.index(DROP_SOURCE_LINES()[LINE_STRING], "\"\"") + 1

	// An input action: a condition in a procedure (the caret inside), its constant on an argument,
	// a field of its name type in the struct
	action := DropSource{kind = .Action, name = "ui_accept", node = -1, index = -1}
	_, ok := dropAt(&f, action, LINE_BLANK, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "\t\t\tif e.Input_IsActionJustPressed(ACTION_UI_ACCEPT) {\n\t\t\t\t\n\t\t\t}\n"), "a condition, indented like the block")
	testing.expect_value(t, f.c.ed.buf.cursors[0].pos, cebuf.Position{LINE_BLANK + 1, 4})
	undone(t, &f, "the action's condition")
	_, ok = dropAt(&f, action, LINE_CALL, call)
	testing.expect(t, ok && strings.contains(dropText(&f), "e.Input_IsActionPressed(ACTION_UI_ACCEPT)"), "its constant on the argument")
	undone(t, &f, "the action's constant")
	message: string
	message, ok = dropAt(&f, action, LINE_FIELD, 1)
	testing.expect(t, ok && strings.contains(dropText(&f), "\tui_acceptAction: e.ActionName `export:\"default=ui_accept\"`,\n}"), "a name field before the struct's brace")
	testing.expect(t, strings.contains(message, "Added ui_acceptAction to Probe"), "said so")
	undone(t, &f, "the action's field")
	// Inside a string: the name itself
	_, ok = dropAt(&f, DropSource{kind = .Node, name = "ShipLight", node = f.light, index = -1}, LINE_STRING, quote)
	testing.expect(t, ok && strings.contains(dropText(&f), "e.Node_FindPath(self.node, \"ShipLight\")"), "a node's path from the script's node, in the string")
	undone(t, &f, "the path in the string")

	// An animation: played on its sprite, which the script reaches through a new field (one undo step)
	anim := DropSource{kind = .Animation, name = f.animation, node = f.light, index = -1}
	_, ok = dropAt(&f, anim, LINE_BLANK, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "\tshipLight: ^e.AnimatedSprite `export:\"default=ShipLight\"`,\n}"), "the sprite's field added")
	// Its constant: the sprite's own animations have them, listed under the sprite (the providers'
	// cache of the constants lost their groups until round 7, so this got the quoted name)
	testing.expectf(t, strings.contains(dropText(&f), "\t\t\te.AnimationPlayer_Play(&self.shipLight.animation, ANIM_PLAY_SCENE_SHIP_LIGHT_DEFAULT)\n"), "played through it, by its constant:\n%s", dropText(&f))
	// The caret at the statement's end, moved down by the field above
	testing.expect_value(t, f.c.ed.buf.cursors[0].pos.line, LINE_BLANK + 1)
	undone(t, &f, "the animation")

	// A node the struct has a field for: the field, no new lookup
	cebuf.buffer_insert_text(&f.c.ed.buf, {LINE_FIELD + 1, 0}, "\tlight: ^e.AnimatedSprite `export:\"default=ShipLight\"`,\n")
	_, ok = dropAt(&f, anim, LINE_BLANK + 1, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "e.AnimationPlayer_Play(&self.light.animation, ") && !strings.contains(dropText(&f), "shipLight"), "the existing field")
	cebuf.buffer_undo(&f.c.ed.buf)
	cebuf.buffer_undo(&f.c.ed.buf)
	testing.expect_value(t, dropText(&f), DROP_SOURCE)

	// A property of the script's own node: set through self.node
	_, ok = dropAt(&f, DropSource{kind = .Property, name = "Position X", node = f.ship, index = -1}, LINE_BLANK, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "\t\t\tself.node.position.x = 0\n"), "a setter")
	undone(t, &f, "the property")
	_, ok = dropAt(&f, DropSource{kind = .Property, name = "Visible", node = f.ship, index = -1}, LINE_CALL, call)
	testing.expect(t, ok && strings.contains(dropText(&f), "e.Input_IsActionPressed(self.node.visible)"), "its value on an argument")
	undone(t, &f, "the property's value")
	// The script's own field
	_, ok = dropAt(&f, DropSource{kind = .Script_Field, name = "speed", node = f.ship, index = -1, script = "Probe"}, LINE_BLANK, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "\t\t\tself.speed = "), "the script's field through self")
	undone(t, &f, "the script field")

	// A state machine's Trigger parameter: fired (its kind's use first)
	_, ok = dropAt(&f, DropSource{kind = .State_Param, name = "attack", node = f.brain, index = -1, detail = "Trigger"}, LINE_BLANK, 0)
	testing.expectf(t, ok && strings.contains(dropText(&f), "e.StateMachine_SetTrigger(self.brain, PARAM_PLAY_SCENE_BRAIN_ATTACK)"), "fired:\n%s", dropText(&f))
	testing.expect(t, strings.contains(dropText(&f), "brain: ^e.StateMachine `export:\"default=../../Brain\"`"), "the machine's field, its path from Spaceship")
	undone(t, &f, "the parameter")
	// A clip: no constant, its name as text
	_, ok = dropAt(&f, DropSource{kind = .Clip, name = "fly", node = f.animator, index = -1}, LINE_BLANK, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "e.Animator_Play(self.intro, \"fly\")"), "an Animator's clip")
	undone(t, &f, "the clip")
	// A scene: changed to
	_, ok = dropAt(&f, DropSource{kind = .Scene, name = "MenuScene", node = -1, index = 0}, LINE_BLANK, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "e.Game_ChangeScene(self.game, SCENE_MENU_SCENE)"), "a scene change")
	undone(t, &f, "the scene")
	// A group of the script's node
	_, ok = dropAt(&f, DropSource{kind = .Group, name = "ships", node = f.ship, index = -1}, LINE_BLANK, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "for node in e.Scene_GetGroup(self.scene, GROUP_SHIPS) {"), "the group's loop")
	undone(t, &f, "the group")
	// A bus
	_, ok = dropAt(&f, DropSource{kind = .Bus, name = "Master", node = -1, index = -1}, LINE_BLANK, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "e.Audio_SetBusVolume(BUS_MASTER, 1)"), "the bus's volume")
	undone(t, &f, "the bus")
	// An event of the node: a subscription reading the script back from user data
	_, ok = dropAt(&f, DropSource{kind = .Event, name = "onExit", node = f.ship, index = -1}, LINE_BLANK, 0)
	testing.expectf(t, ok && strings.contains(dropText(&f), "e.Event_Subscribe(&self.node.onExit, proc(_: ^e.EventSubject, source: rawptr, data: e.EventData, user: rawptr) {\n\t\t\t\tself := (^Probe)(user)\n"), "a subscription:\n%s", dropText(&f))
	undone(t, &f, "the event")
	// A node with uses of its type: played
	_, ok = dropAt(&f, DropSource{kind = .Node, name = "Jump", node = f.player, index = -1}, LINE_BLANK, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "e.AudioPlayer_Play(self.jump)"), "a sound player played")
	undone(t, &f, "the sound player")
	// An image: in a procedure, loaded
	_, ok = dropAt(&f, DropSource{kind = .Asset, node = -1, index = 0}, LINE_BLANK, 0)
	testing.expect(t, ok && strings.contains(dropText(&f), "texture := e.Asset_Texture(self.game, TEXTURE_SHIP)"), "an image loaded")
	undone(t, &f, "the image")
	// A node in the struct: its field, as before
	message, ok = dropAt(&f, DropSource{kind = .Node, name = "Camera", node = 1, index = -1}, LINE_FIELD, 1)
	testing.expect(t, ok && strings.contains(dropText(&f), "\tcamera: ^e.Camera2D `export:\"default=../Camera\"`,\n}"), "a node field")
	testing.expect(t, strings.contains(message, "Added camera to Probe"), "said so")
	undone(t, &f, "the node field")
}

@(private="file")
DROP_SOURCE_LINES :: proc() -> []string {
	return strings.split_lines(DROP_SOURCE, context.temp_allocator)
}

@(test)
code_drops_menu_of_choices :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	f: DropFixture
	if !dropFixture(t, &f, "editor_test_code_drops_menu") do return
	defer removeAll(f.dir)
	defer State_Destroy(&f.state)
	ce.editor_set_viewport(&f.c.ed, 900, 600)

	// Shift: the menu, nothing inserted yet, at most CODE_DROP_MAX_CHOICES, the plain drop first
	action := DropSource{kind = .Action, name = "ui_accept", node = -1, index = -1}
	message, ok := dropAt(&f, action, LINE_BLANK, 0, menu = true)
	testing.expect(t, ok && message == "", "a menu")
	testing.expect_value(t, dropText(&f), DROP_SOURCE)
	testing.expect_value(t, ce.editor_code_action_count(&f.c.ed), 4)
	first, _ := ce.editor_code_action_title(&f.c.ed, 0)
	testing.expect_value(t, first, "If it was just pressed")
	held, _ := ce.editor_code_action_title(&f.c.ed, 1)
	testing.expect_value(t, held, "If it's held")
	testing.expect(t, strings.contains(f.c.ed.actions.drops[0].preview, "if e.Input_IsActionJustPressed(ACTION_UI_ACCEPT) {"), "the first's preview")
	// The strength: a value
	testing.expect(t, ce.editor_apply_code_action(&f.c.ed, 3), "picked")
	testing.expect(t, strings.contains(dropText(&f), "\t\t\tstrength := e.Input_GetActionStrength(ACTION_UI_ACCEPT)\n"), "a value")
	testing.expect(t, strings.contains(ce.editor_take_drop_message(&f.c.ed), "strength :="), "its message")
	undone(t, &f, "the picked choice")

	// On an argument: the constant, the name as text, the condition
	call := strings.index(DROP_SOURCE_LINES()[LINE_CALL], "()") + 1
	_, ok = dropAt(&f, action, LINE_CALL, call, menu = true)
	testing.expect(t, ok && ce.editor_code_action_count(&f.c.ed) >= 2, "choices on an argument")
	second, _ := ce.editor_code_action_title(&f.c.ed, 1)
	testing.expect_value(t, second, "Its name as text")
	testing.expect(t, ce.editor_apply_code_action(&f.c.ed, 1), "picked")
	testing.expect(t, strings.contains(dropText(&f), "e.Input_IsActionPressed(\"ui_accept\")"), "the literal")
	undone(t, &f, "the literal")

	// A field the choice needs is in its preview
	_, ok = dropAt(&f, DropSource{kind = .Animation, name = f.animation, node = f.light, index = -1}, LINE_BLANK, 0, menu = true)
	testing.expect(t, ok && strings.contains(f.c.ed.actions.drops[0].preview, "// and in Probe:\nshipLight: ^e.AnimatedSprite"), "the field in the preview")
	ce.editor_close_code_actions(&f.c.ed)
	testing.expect_value(t, dropText(&f), DROP_SOURCE)
}

/*
Every use of the engine's table, filled in as a drop fills it (constants and nodes as typed
locals), in one scratch package that `odin check` compiles: a use calling something that isn't
there, or with the wrong arguments, fails here.
*/
@(test)
code_drops_engine_uses_compile :: proc(t: ^testing.T) {
	odin := Toolchain_Odin("")
	engine, found := Toolchain_EngineDir()
	if odin == "" || !found {
		testing.expect(t, false, "odin and the engine are needed to compile the uses")
		return
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "package uses\n\nimport e \"engine:.\"\n\nS :: struct {\n\tusing script: e.Script,\n}\n\n")
	for use, i in e.CODE_USES {
		on, _, _ := strings.partition(use.on, ":")
		typeName, _, field := strings.partition(on, ".")
		name := "\"name\""
		switch {
		case strings.has_suffix(on, "Asset"): name = fmt.tprintf("e.%s{{}", on)
		case on == "Dialogue":                name = "\"d.dialogue.xml\""
		}
		value := "0"
		if field == "position" do value = "{0, 0}"
		code := use.code
		code, _ = strings.replace_all(code, "{node}", "node", context.temp_allocator)
		code, _ = strings.replace_all(code, "{name}", name, context.temp_allocator)
		code, _ = strings.replace_all(code, "{self}", "self", context.temp_allocator)
		code, _ = strings.replace_all(code, "{game}", "self.game", context.temp_allocator)
		code, _ = strings.replace_all(code, "{scene}", "self.scene", context.temp_allocator)
		code, _ = strings.replace_all(code, "{value}", value, context.temp_allocator)
		code, _ = strings.replace_all(code, "{type}", "int", context.temp_allocator)
		code, _ = strings.replace_all(code, "{caret}", "", context.temp_allocator)
		switch use.kind {
		case .Condition: code = fmt.tprintf("if %s {{}", code)
		case .Value:     code = fmt.tprintf("%s := %s\n_ = %s", use.var, code, use.var)
		case .Statement:
		}
		code, _ = strings.replace_all(code, "\n", "\n\t", context.temp_allocator)
		nodeType := use.node != "" ? use.node : (typeName != "" && field != "" ? typeName : "Node")
		fmt.sbprintf(&b, "use%d :: proc(self: ^S, node: ^e.%s) {{\n\t// %s: %s\n\t%s\n}\n\n", i, nodeType, use.on, use.title, code)
	}
	base := testTempBase()
	dir, _ := filepath.join({base, "editor_test_code_uses"}, context.temp_allocator)
	_ = removeAll(dir)
	defer removeAll(dir)
	_ = os.make_directory_all(dir)
	file := joinPath(dir, "uses.odin", allocator = context.temp_allocator)
	_ = os.write_entire_file(file, transmute([]u8)strings.to_string(b))
	state, stdout, stderr, err := Process_Exec({command = {odin, "check", dir, "-no-entry-point", fmt.tprintf("-collection:engine=%s", engine)}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "every use compiles:\n%s%s\n%s", string(stdout), string(stderr), strings.to_string(b))
}
