package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"

// Several scripts on a node and node types of the project's code (node_scripts_edit.odin): the
// catalog, Add Node, the inspector's messages, undo, saved and read back; hot reload's setting

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(private="file")
freshState :: proc(dir: string) -> State {
	os.make_directory("build")
	removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1,
		materialSelection = -1, trace = DEFAULT_TRACE_SETTINGS, busSelection = -1}
	state.settings.builtInCodeEditor = false
	testing.expect_value(nil, Project_Save(&state.project), "")
	return state
}

// What --describe-scripts prints for two scripts and a node type
@(private="file")
DESCRIPTION :: `{"scripts": [` +
	`{"name": "Mover", "file": "mover.odin", "line": 9, "fields": [{"name": "speed", "type": "Float", "default": "100", "hint": ""}]},` +
	`{"name": "Health", "file": "health.odin", "line": 7, "fields": [{"name": "hp", "type": "Int", "default": "10", "hint": ""}], "events": [{"name": "script.onHurt", "description": "It was hurt", "data": ""}]}` +
	`], "data": [], "nodeTypes": [` +
	`{"name": "Player", "base": "Sprite", "file": "player.odin", "line": 12, "fields": [{"name": "lives", "type": "Int", "default": "3", "hint": ""}]}` +
	`]}`

@(test)
several_scripts_and_node_types_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_node_scripts"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	node :: proc(s: ^State, i: int) -> ^NodeDef { return &s.project.scenes[s.currentScene].nodes[i] }

	// The catalog: node types with their base kind
	testing.expect(t, takeDescription(&state, DESCRIPTION, 0), "described")
	testing.expect_value(t, len(state.scripts.nodeTypes), 1)
	player := ScriptCatalog_FindNodeType(&state.scripts, "Player")
	testing.expect(t, player != nil && player.base == .Sprite && len(player.fields) == 1, "Player, a Sprite")
	path, line := Script_Location(&state, "Player")
	testing.expect(t, path == "player.odin" && line == 12, "its file")

	// Add Node lists it after the built-in kinds, found by its name or its base
	entries := AddNode_Entries("", &state.scripts)
	last := entries[len(entries) - 1]
	testing.expect(t, last.custom == "Player" && last.kind == .Sprite, "listed last")
	found := false
	for entry in AddNode_Entries("play", &state.scripts) do if entry.custom == "Player" do found = true
	testing.expect(t, found, "found by name")
	sendTo(&state, Add_Node_Type_Chosen("Player"))
	hero := state.selectedNode
	testing.expect_value(t, node(&state, hero).kind, NodeKind.Sprite)
	testing.expect_value(t, node(&state, hero).customKind, "Player")
	testing.expect_value(t, node(&state, hero).name, "Player")
	testing.expect_value(t, len(NodeTypes_On(&state.scripts, .Sprite)), 1)

	// Its own field, undone and redone
	sendTo(&state, Script_Prop_Changed{name = "lives", value = "5", defaultValue = "3", target = NodeCustomTarget{}})
	testing.expect_value(t, len(node(&state, hero).customProps), 1)
	sendTo(&state, Action.Undo)
	testing.expect_value(t, len(node(&state, hero).customProps), 0)
	sendTo(&state, Action.Redo)
	testing.expect_value(t, node(&state, hero).customProps[0].value, "5")

	// Scripts: the first, then more (one of each)
	sendTo(&state, Node_Script_Added("Mover"))
	testing.expect_value(t, node(&state, hero).script, "Mover")
	sendTo(&state, Node_Script_Added("Health"))
	sendTo(&state, Node_Script_Added("Health"))
	testing.expect_value(t, len(node(&state, hero).moreScripts), 1)
	testing.expect(t, NodeDef_Runs(node(&state, hero), "Health") && NodeDef_Runs(node(&state, hero), "Player"), "runs both")
	sendTo(&state, Script_Prop_Changed{name = "hp", value = "25", defaultValue = "10", target = NodeScriptTarget(0)})
	testing.expect_value(t, node(&state, hero).moreScripts[0].props[0].value, "25")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, len(node(&state, hero).moreScripts[0].props), 0)
	sendTo(&state, Action.Redo)
	// What it runs, in the engine's order: its type, its first script, the others
	codes := NodeDef_Codes(&state, node(&state, hero))
	testing.expect(t, len(codes) == 3 && codes[0].desc == player && codes[2].desc.name == "Health", "in order")
	props := Timeline_Properties(&state, node(&state, hero), context.temp_allocator)
	has :: proc(list: []string, name: string) -> bool {
		for p in list do if p == name do return true
		return false
	}
	testing.expect(t, has(props, "script.lives") && has(props, "script.speed") && has(props, "script.hp"), "every field animates")
	value, _ := Timeline_NodeValue(&state, node(&state, hero), "script.hp", context.temp_allocator)
	testing.expect_value(t, value, "25")
	testing.expect_value(t, len(Script_Events(&state, "Health")), 1)

	// Saved and read back alike
	testing.expect_value(t, Project_Save(&state.project), "")
	text, _ := os.read_entire_file(joinPath(state.project.rootPath, "scenes", "Main.scene.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(text), `kind="Player" baseKind="Sprite"`), "the node type")
	testing.expect(t, strings.contains(string(text), `<script name="Mover"/>`) && strings.contains(string(text), `<script name="Health">`), "both scripts")
	loaded, message, _ := Project_Load(state.project.rootPath)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	read := false
	for &s in loaded.scenes do for &n in s.nodes do if n.name == "Player" {
		read = true
		testing.expect(t, NodeDef_Equal(n, node(&state, hero)^), "read back")
	}
	testing.expect(t, read, "the node is there")

	// Copied with the rest
	sendTo(&state, Action.Duplicate_Node)
	copied := node(&state, state.selectedNode)
	testing.expect(t, copied.customKind == "Player" && len(copied.moreScripts) == 1 && copied.moreScripts[0].props[0].value == "25", "duplicated")

	// The first script removed: the next becomes the first; then the last removed
	sendTo(&state, Node_Script_Changed(TEXTURE_NONE))
	testing.expect_value(t, copied.script, "Health")
	testing.expect_value(t, len(copied.moreScripts), 0)
	testing.expect_value(t, copied.props[0].value, "25")
	sendTo(&state, Node_Script_Added("Mover"))
	sendTo(&state, Node_Script_Removed(0))
	testing.expect_value(t, len(copied.moreScripts), 0)
	// A more script chosen as the first moves there
	sendTo(&state, Node_Script_Added("Mover"))
	sendTo(&state, Node_Script_Changed("Mover"))
	testing.expect_value(t, copied.script, "Mover")
	testing.expect_value(t, len(copied.moreScripts), 0)

	// Hot reload is on by default and kept in editor.ini
	testing.expect(t, state.settings.hotReload, "on by default")
	settings := Settings_Default()
	_ = Settings_Parse(&settings, "[editor]\nhot_reload = false\n")
	testing.expect(t, !settings.hotReload, "off")
	testing.expect(t, strings.contains(Settings_ToINI(&settings), "hot_reload = false"), "written")
}
