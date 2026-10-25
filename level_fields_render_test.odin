package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"
import "gui:skald"

// Steps the State through a pointer (see CLAUDE.md's conventions)
@(private="file")
lfSend :: proc(state: ^State, m: Msg) {
	state^, _ = update(state^, m)
}

// Every row's values of an entity, one a line
@(private="file")
fieldTexts :: proc(entities: []LevelCanvasEntity, iid: string) -> string {
	out := make([dynamic]string, context.temp_allocator)
	for en in entities do if en.iid == iid && !en.ghost {
		for r in en.fields.rows {
			parts := make([dynamic]string, context.temp_allocator)
			for item in r.items do append(&parts, item.disc ? "(disc)" : item.text)
			line := strings.join(parts[:], " ", context.temp_allocator)
			append(&out, r.label != "" ? strings.concatenate({r.label, " ", line}, context.temp_allocator) : line)
		}
	}
	return strings.join(out[:], "|", context.temp_allocator)
}

@(private="file")
entityMarks :: proc(entities: []LevelCanvasEntity, iid: string) -> []LevelFieldMark {
	for en in entities do if en.iid == iid && !en.ghost do return en.fields.marks
	return nil
}

/*
Field values on the canvas as LDtk's FieldInstanceRender shows them: which fields show (not
Hidden, not on their default unless always shown, in the world view only those shown there, a
layer hiding them while inactive), what each display mode writes or draws, the prefix and suffix,
cut long values, level fields, references' links whole or cut.
*/
@(test)
level_fields_show_on_the_canvas_as_ldtk_shows_them :: proc(t: ^testing.T) {
	dir := joinPath(testTempBase(), "crossfire_level_fields", allocator = context.temp_allocator)
	removeAll(dir)
	os.make_directory_all(dir)
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	state := State{project = Project_CreateEmpty(joinPath(dir, "Game", allocator = context.temp_allocator), "Fields"), browserSelection = {kind = .None},
		selectedNode = -1, busSelection = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	if !testing.expect_value(t, Project_Save(&state.project), "") do return
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/ldtk_world/world.ldtk")
	if !testing.expect_value(t, problem, "") || index < 0 do return
	lfSend(&state, Mode_Changed(.Level))
	lfSend(&state, Level_File_Chosen(state.project.assets[index].path))
	lfSend(&state, Workspace_Measured({1280, 600}))
	lfSend(&state, Level_Canvas_Measured({600, 300}))
	root, file := state.project.rootPath, LevelMode_File(&state)
	doc := LDtkDoc_Get(root, file)
	if !testing.expect(t, doc != nil && doc.problem == "", "read") do return
	edit :: proc(t: ^testing.T, root, file: string, x: LDtk_Edit, loc := #caller_location) {
		e := x
		e.file = file
		problem, _ := LDtkOps_Apply(root, e)
		testing.expectf(t, problem == "", "%v %s: %s", e.op, e.key, problem, loc = loc)
	}

	// The world view: every field shows in the world (LDtk's default), its value, not its default
	_, entities, _ := LevelCanvas_Content(&state, doc)
	testing.expect_value(t, fieldTexts(entities, "player1"), "150|\"Hero\"|Happy|(disc)|2,5")
	testing.expect_value(t, fieldTexts(entities, "coin1"), "")
	testing.expect_value(t, fieldTexts(entities, "coin2"), "5")
	testing.expect_value(t, fieldTexts(entities, "door2"), "+locked")
	// References between centers: a link each (the door's to another level, same world and depth: whole)
	marks := entityMarks(entities, "player1")
	if testing.expect_value(t, len(marks), 1) {
		testing.expect(t, marks[0].kind == .Ref && marks[0].ending == .Full && marks[0].style == "CurvedArrow", "the friend's link")
	}
	door := entityMarks(entities, "door1")
	testing.expect(t, len(door) == 1 && door[0].ending == .Full, "the door's link to the cave")
	// Level fields: the values set
	levels, _, _ := LevelCanvas_Content(&state, doc)
	for l in levels {
		parts := make([dynamic]string, context.temp_allocator)
		for r in l.fields.rows do for item in r.items do append(&parts, item.text)
		got := strings.join(parts[:], ",", context.temp_allocator)
		switch l.identifier {
		case "Start": testing.expect_value(t, got, "\"intro\",1,Sunny")
		case "Cave":  testing.expect_value(t, got, "\"cave\",2")
		case "Tower": testing.expect_value(t, got, "")
		}
	}

	// Display modes: name and value, a prefix and suffix, always shown, hidden, a radius
	edit(t, root, file, {op = .Def_Set, kind = .Field, field = 40, key = "editorDisplayMode", text = "NameAndValue"})
	edit(t, root, file, {op = .Def_Set, kind = .Field, field = 40, key = "editorTextPrefix", text = "~"})
	edit(t, root, file, {op = .Def_Set, kind = .Field, field = 40, key = "editorTextSuffix", text = " px/s"})
	edit(t, root, file, {op = .Def_Set, kind = .Field, field = 41, key = "editorAlwaysShow", flag = true})
	edit(t, root, file, {op = .Def_Set, kind = .Field, field = 41, key = "editorDisplayMode", text = "RadiusGrid"})
	edit(t, root, file, {op = .Def_Set, kind = .Field, field = 42, key = "editorDisplayMode", text = "Hidden"})
	edit(t, root, file, {op = .Def_Set, kind = .Field, field = 43, key = "editorDisplayPos", text = "Beneath"})
	doc = LDtkDoc_Get(root, file)
	_, entities, _ = LevelCanvas_Content(&state, doc)
	testing.expect_value(t, fieldTexts(entities, "player1"), "speed = ~150 px/s|Happy|(disc)|2,5")
	marks = entityMarks(entities, "player1")
	radius := false
	for m in marks do if m.kind == .Radius do radius = m.radius == 3 * 16
	testing.expect(t, radius, "lives as a radius of 3 cells, shown though it's the default")
	for en in entities do if en.iid == "player1" {
		for r in en.fields.rows do if len(r.items) > 0 && r.items[0].text == "Happy" do testing.expect(t, r.pos == .Beneath, "the mood beneath")
	}

	// In the world view only fields shown in the world (a level field's option in LDtk)
	edit(t, root, file, {op = .Def_Set, kind = .Field, field = 52, key = "editorShowInWorld", flag = false})
	doc = LDtkDoc_Get(root, file)
	levels, _, _ = LevelCanvas_Content(&state, doc)
	for l in levels do if l.identifier == "Start" do testing.expect_value(t, len(l.fields.rows), 2)
	// Focused: the Entities layer hides its fields while another layer is selected
	lfSend(&state, Level_Row_Clicked{level = "Cave", double = true})
	_, entities, _ = LevelCanvas_Content(&state, doc)
	testing.expect_value(t, fieldTexts(entities, "coin2"), "5")
	lfSend(&state, Level_Layer_Picked(3))
	_, entities, _ = LevelCanvas_Content(&state, doc)
	testing.expect_value(t, fieldTexts(entities, "coin2"), "")
	for en in entities do if en.iid == "coin2" do testing.expect(t, en.nameHidden, "its name hidden too")

	// Points: a star, a line from the entity to each point; a long string cut to 70 characters
	edit(t, root, file, {op = .Def_Set, kind = .Field, field = 45, key = "editorDisplayMode", text = "PointStar"})
	edit(t, root, file, {op = .Def_Set, kind = .Field, field = 42, key = "editorDisplayMode", text = "ValueOnly"})
	edit(t, root, file, {op = .Field_Value, entity = "player1", field = 42, key = "set", text = strings.repeat("x", 100, context.temp_allocator)})
	lfSend(&state, Level_Layer_Picked(1))
	lfSend(&state, Level_Row_Clicked{level = "Start", double = true})
	doc = LDtkDoc_Get(root, file)
	_, entities, _ = LevelCanvas_Content(&state, doc)
	lines, points := 0, 0
	for m in entityMarks(entities, "player1") {
		if m.kind == .Line do lines += 1
		if m.kind == .Point do points += 1
	}
	testing.expect(t, lines == 1 && points == 1, "a line to the point and its diamond")
	found := false
	for en in entities do if en.iid == "player1" do for r in en.fields.rows do for item in r.items do if strings.has_prefix(item.text, "\"x") {
		found = true
		testing.expect_value(t, len(item.text), 70)
	}
	testing.expect(t, found, "the string shows")

	// A reference picked in another level of the world (the friend field allows it): coin2 in the Cave
	lfSend(&state, Level_Pick_Started{kind = .Ref, entity = "player1", field = 46, index = -1})
	lfSend(&state, Level_Canvas_Pressed{world = {256 + 64, 72}, level = "Cave"})
	lfSend(&state, Level_Canvas_Released{})
	testing.expect_value(t, state.level.problem, "")
	testing.expect_value(t, state.level.focus, "Start")
	main := LDtkDoc_Main(LDtkDoc_Get(root, file))
	friend := Json_Path(main, "levels.identifier=Start.layerInstances.__identifier=Entities.entityInstances.iid=player1.fieldInstances.__identifier=friend.__value")
	testing.expect_value(t, Json_String(main, Json_Get(main, friend, "entityIid")), "coin2")
	testing.expect_value(t, Json_String(main, Json_Get(main, friend, "levelIid")), "lvl-cave")
}

/*
LDtk's keys in the Level mode: P, L, E, U, T, C show a panel (again: the panel closes), the number
keys pick a layer (1 the first, 0 the tenth).
*/
@(test)
level_keys_show_panels_and_pick_layers :: proc(t: ^testing.T) {
	settings := Settings_Default()
	testing.expect_value(t, settings.keymap[.Level_Layer_1][0], skald.Shortcut{.N1, {}})
	testing.expect_value(t, settings.keymap[.Level_Layer_10][0], skald.Shortcut{.N0, {}})
	testing.expect_value(t, settings.keymap[.Level_Panel_Entities][0], skald.Shortcut{.E, {}})
	dir := joinPath(testTempBase(), "crossfire_level_keys", allocator = context.temp_allocator)
	removeAll(dir)
	os.make_directory_all(dir)
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	state := State{project = Project_CreateEmpty(joinPath(dir, "Game", allocator = context.temp_allocator), "Keys"), browserSelection = {kind = .None},
		selectedNode = -1, busSelection = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	if !testing.expect_value(t, Project_Save(&state.project), "") do return
	index, problem := Project_ImportAsset(&state.project, "tests/fixtures/ldtk_world/world.ldtk")
	if !testing.expect_value(t, problem, "") || index < 0 do return
	lfSend(&state, Mode_Changed(.Level))
	lfSend(&state, Level_File_Chosen(state.project.assets[index].path))
	lfSend(&state, Action.Level_Panel_Entities)
	testing.expect_value(t, state.level.bottomTab, BottomTab.Entities)
	testing.expect(t, Mode_Layout(&state).bottomOpen, "the panel shows")
	lfSend(&state, Action.Level_Panel_Entities)
	testing.expect(t, !Mode_Layout(&state).bottomOpen, "again: it closes")
	lfSend(&state, Action.Level_Panel_Project)
	testing.expect(t, state.level.bottomTab == .LDtk_Project && Mode_Layout(&state).bottomOpen, "the Project tab")
	lfSend(&state, Action.Level_Layer_2)
	testing.expect_value(t, state.level.layerDef, 2)
	lfSend(&state, Action.Level_Layer_3)
	testing.expect_value(t, state.level.layerDef, 3)
	lfSend(&state, Action.Level_Layer_9)
	testing.expect_value(t, state.level.layerDef, 3)
}
