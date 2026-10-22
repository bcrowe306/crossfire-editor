package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Editor plugins (plugin_host.odin): the sample plugin (tests/fixtures/plugins/grid_tools) built,
// loaded and used: its command (undone), its inspector rows, its importer; New Plugin's template
// built too; unloaded

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
plugins_build_load_and_run :: proc(t: ^testing.T) {
	if Toolchain_Odin("") == "" {
		testing.fail_now(t, "no Odin compiler to build plugins with")
	}
	os.make_directory("build")
	dir := "build/test_plugins"
	removeAll(dir)
	os.make_directory(dir)
	defer removeAll(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1,
		materialSelection = -1, atlasSelection = -1, trace = DEFAULT_TRACE_SETTINGS, busSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	defer Plugins_Unload()
	testing.expect_value(t, Project_Save(&state.project), "")
	// The sample plugin in the project
	folder := joinPath(root, PLUGINS_FOLDER, "grid_tools", allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	source, _ := os.read_entire_file("tests/fixtures/plugins/grid_tools/grid_tools.odin", context.temp_allocator)
	_ = os.write_entire_file(joinPath(folder, "grid_tools.odin", allocator = context.temp_allocator), source)
	testing.expect(t, Plugins_Present(&state), "a plugins folder")

	// Built and loaded by the ticks
	waitLoaded :: proc(state: ^State, count: int) -> bool {
		deadline := time.tick_now()
		for time.duration_seconds(time.tick_since(deadline)) < 120 {
			sendTo(state, Plugins_Tick{})
			loaded := 0
			for p in Plugins_List() do if p.status == .Loaded do loaded += 1
			if loaded >= count do return true
			for p in Plugins_List() do if p.status == .Failed do return false
			time.sleep(100 * time.Millisecond)
		}
		return false
	}
	testing.expect(t, waitLoaded(&state, 1), "loaded")
	list := Plugins_List()
	if len(list) != 1 || list[0].status != .Loaded {
		for line in state.output do testing.expectf(t, false, "%s", line.text)
		return
	}
	testing.expect_value(t, list[0].name, "Grid Tools")
	testing.expect_value(t, len(list[0].commands), 1)
	testing.expect_value(t, list[0].importers[0].extensions[0], "csv")

	// Its command: the selected node's children in a grid; one undo step
	scene := &state.project.scenes[state.currentScene]
	parent := Scene_InsertNode(scene, "Box", .Node2D, -1)
	for _ in 0 ..< 5 do _ = Scene_InsertNode(scene, "Child", .Sprite, parent)
	state.selectedNode = parent
	sendTo(&state, Plugin_Command_Run{0, 0})
	scene = &state.project.scenes[state.currentScene]
	testing.expect_value(t, scene.nodes[parent + 2].position, [2]f32{48, 0})
	testing.expect_value(t, scene.nodes[parent + 5].position, [2]f32{0, 48})
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[state.currentScene].nodes[parent + 2].position, [2]f32{0, 0})
	sendTo(&state, Action.Redo)

	// Its inspector rows for a Sprite, and a row's change
	sprite := parent + 2
	state.selectedNode = sprite
	groups := Plugins_InspectorRows(&state, sprite)
	testing.expect(t, len(groups) == 1 && len(groups[0].rows) == 3, "three rows")
	if len(groups) == 1 do testing.expect_value(t, groups[0].rows[0].value, "48, 0")
	state.project.scenes[state.currentScene].nodes[sprite].position = {50, 13}
	sendTo(&state, Plugin_Row_Changed{0, 0, sprite, "snap", ""})
	testing.expect_value(t, state.project.scenes[state.currentScene].nodes[sprite].position, [2]f32{64, 0})
	testing.expect_value(t, len(Plugins_InspectorRows(&state, parent)), 0)

	// Its importer: a CSV of lines into a dialogue
	csv := joinPath(dir, "talk.csv", allocator = context.temp_allocator)
	_ = os.write_entire_file(csv, transmute([]byte)string("Guide,Hello there\nGuide,Bye\n"))
	sendTo(&state, Asset_Import_Result{path = csv})
	talk := Project_FindDialogue(&state.project, "dialogues/talk.dialogue.xml")
	testing.expect(t, talk >= 0, "a dialogue imported by the plugin")
	if talk >= 0 do testing.expect_value(t, len(state.project.dialogues[talk].data.nodes[0].steps), 2)

	// New Plugin's template builds and loads as well
	path, problem := Plugin_Create(&state.project, "my_plugin")
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_suffix(path, "my_plugin/my_plugin.odin"), "its file")
	testing.expect(t, waitLoaded(&state, 2), "the template loaded")

	// Changed: rebuilt and reloaded
	time.sleep(1100 * time.Millisecond)
	changed, _ := strings.replace(string(source), "Grid Tools\"", "Grid Tools 2\"", 1, context.temp_allocator)
	_ = os.write_entire_file(joinPath(folder, "grid_tools.odin", allocator = context.temp_allocator), transmute([]byte)changed)
	deadline := time.tick_now()
	renamed := false
	for !renamed && time.duration_seconds(time.tick_since(deadline)) < 120 {
		sendTo(&state, Plugins_Tick{})
		for p in Plugins_List() do if p.name == "Grid Tools 2" && p.status == .Loaded do renamed = true
		time.sleep(100 * time.Millisecond)
	}
	testing.expect(t, renamed, "reloaded after a change")
}
