package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import e "engine:."

/*
Listening to node events from the inspector (the engine's node_events.odin). The inspector's
Events section lists the selected node's events (`e.SceneNodeKind_Events` of the kind it's built
as) with the scripts listening to each; Listen... opens a dialog of the scripts attached to nodes
of the same scene. Choosing one (`Listener_Target_Chosen`):

- adds a `NodeDef.listeners` entry to the node (a `.Node` undo step; `<listener event target
  handler/>` in the scene file, its target a path from the node);
- appends the handler to the script's file (`Listener_HandlerSource`): a procedure taking the
  script, the event's node and its data, and an `@(init)` registering it
  (`e.Script_Listener`), in the code tab when the built-in code editor is on (one undo step
  there; saved with the project), else written to the file and opened in the external editor.

The engine subscribes the handler before the scene's scripts get `ready`.
*/

// The Listen... dialog: which node's event a script will listen to
ListenerDialog :: struct {
	open: bool,
	// The node whose event it is, in the open scene
	node: int,
	// The event (owned)
	event: string,
}

// A listener's copy (strings cloned)
Listener_Clone :: proc(l: e.NodeListenerData) -> e.NodeListenerData {
	return {strings.clone(l.event), strings.clone(l.target), strings.clone(l.handler), strings.clone(l.global)}
}

// The event's name without the struct field it's in ("animation.onAnimationEnded" -> "onAnimationEnded")
Event_ShortName :: proc(event: string) -> string {
	if dot := strings.last_index_byte(event, '.'); dot >= 0 do return event[dot + 1:]
	return event
}

/*
A handler's name for a node's event: "on", the node's name, the event's without its "on":
Blood's onFinished -> "onBloodFinished". Unique among `taken`.

Inputs:
- nodeName: The node whose event it is
- event: The event
- taken: Handler names already used (by the script's file)

Returns:
- The name (temp allocated)
*/
Listener_HandlerName :: proc(nodeName, event: string, taken: []string) -> string {
	node := NodeField_Name(nodeName, nil)
	short := strings.trim_prefix(Event_ShortName(event), "on")
	upper :: proc(s: string) -> string {
		if s == "" do return s
		r, size := utf8.decode_rune_in_string(s)
		return fmt.tprintf("%c%s", unicode.to_upper(r), s[size:])
	}
	base := fmt.tprintf("on%s%s", upper(node), upper(short))
	name := base
	for n := 2; ; n += 1 {
		used := false
		for t in taken do if t == name do used = true
		if !used do return name
		name = fmt.tprintf("%s%d", base, n)
	}
}

// The handler names a script file registers (`Script_Listener(Type, "name"`)
Listener_RegisteredHandlers :: proc(text: string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	rest := text
	for {
		at := strings.index(rest, "Script_Listener(")
		if at < 0 do break
		rest = rest[at:]
		quote := strings.index_byte(rest, '"')
		if quote < 0 do break
		rest = rest[quote + 1:]
		end := strings.index_byte(rest, '"')
		if end < 0 do break
		append(&names, rest[:end])
		rest = rest[end:]
	}
	return names[:]
}

/*
The code appended to a script's file for a listener: the handler procedure (its body has the
event's data hint as a comment) and its registration.

Inputs:
- script: The script struct's name ("Hero")
- handler: The handler's name ("onBloodFinished")
- nodeName, event: Whose event it is, for the comment
- info: The event (its description and data hint)
- alias: The engine's import name in the file ("e")
- reach: Code reaching what sent it (a node's script, a global), for a comment; "" for none
*/
Listener_HandlerSource :: proc(script, handler, nodeName, event: string, info: e.NodeEventInfo, alias: string, reach := "") -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "\n// %s's %s (Events in %s's inspector): %s\n", nodeName, event, nodeName, info.description)
	fmt.sbprintf(&b, "%s_%s :: proc(self: ^%s, source: ^%s.Node, data: %s.EventData) {{\n", script, handler, script, alias, alias)
	if info.dataHint != "" {
		hint, _ := strings.replace_all(info.dataHint, "e.", fmt.tprintf("%s.", alias), context.temp_allocator)
		fmt.sbprintf(&b, "\t// %s\n", hint)
	}
	if reach != "" do fmt.sbprintf(&b, "\t// %s\n", reach)
	strings.write_string(&b, "}\n\n@(init)\n")
	fmt.sbprintf(&b, "register_%s_%s :: proc \"contextless\" () {{\n", script, handler)
	fmt.sbprintf(&b, "\t%s.Script_Listener(%s, \"%s\", %s_%s)\n}}\n", alias, script, handler, script, handler)
	return strings.to_string(b)
}

// The nodes of a scene with a script: the dialog's choices
Listener_Targets :: proc(scene: ^SceneDef) -> []int {
	found := make([dynamic]int, context.temp_allocator)
	for node, i in scene.nodes do if node.script != "" do append(&found, i)
	return found[:]
}

// The project's script file registering a script (relative to the project), or ""
Script_FileOf :: proc(state: ^State, script: string) -> string {
	for file in state.scriptFiles {
		path := joinPath(state.project.rootPath, file, allocator = context.temp_allocator)
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil do continue
		for name in ScriptFile_Registrations(string(data)).scripts do if name == script do return file
	}
	return ""
}

// The script a node runs: its own, or for a Component instance its component's root's
NodeDef_Script :: proc(project: ^Project, node: ^NodeDef) -> string {
	if node.kind != .Component do return node.script
	if i := Project_FindComponent(project, node.component); i >= 0 && len(project.scenes[i].nodes) > 0 {
		return NodeDef_Script(project, &project.scenes[i].nodes[0])
	}
	return ""
}

// A built script's events (the catalog's; none before a build)
Script_Events :: proc(state: ^State, script: string) -> []e.NodeEventInfo {
	if desc := ScriptCatalog_Find(&state.scripts, script); desc != nil do return desc.events[:]
	if desc := ScriptCatalog_FindNodeType(&state.scripts, script); desc != nil do return desc.events[:]
	return nil
}

/*
An event a listener names: one of the node kind's, one of its script's ("script.x"), or a
global's (`global` set).

Returns:
- The event, and false when nothing has it (not built yet, renamed, removed)
*/
Listener_EventInfo :: proc(state: ^State, node: ^NodeDef, event, global: string) -> (e.NodeEventInfo, bool) {
	events := global != "" ? Script_Events(state, global) : strings.has_prefix(event, e.SCRIPT_EVENT_PREFIX) ? Script_Events(state, NodeDef_Script(&state.project, node)) : e.SceneNodeKind_Events(NodeDef_BuiltKind(&state.project, node))
	for ev in events do if ev.name == event do return ev, true
	return {}, false
}

/*
Connects an event to a script: the listener on `carrier` (the emitting node for its own and its
script's events; the listening node for a global's), the handler appended to the listening node's
script's file (see the file's comment).

Inputs:
- state: The editor state
- carrier: The node the listener is stored on, in the open scene
- listening: The node whose script listens
- event: The event's name
- global: The global's script name for a global's event, else ""

Returns:
- What happened, for the Console, and false when nothing was connected
*/
Listener_Connect :: proc(state: ^State, carrier, listening: int, event, global: string) -> (message: string, ok: bool) {
	scene := &state.project.scenes[state.currentScene]
	if carrier < 0 || carrier >= len(scene.nodes) || listening < 0 || listening >= len(scene.nodes) do return "No node", false
	script := scene.nodes[listening].script
	if script == "" do return fmt.tprintf("%s has no script to listen with", scene.nodes[listening].name), false
	file := Script_FileOf(state, script)
	if file == "" do return fmt.tprintf("No file in scripts/ registers %s", script), false
	source := &scene.nodes[carrier]
	info, _ := Listener_EventInfo(state, source, event, global)

	// The file's text: the code tab's (with unsaved edits), else the disk's
	absolute := absolutePath(joinPath(state.project.rootPath, file, allocator = context.temp_allocator))
	builtIn := state.settings.builtInCodeEditor
	if builtIn do CodeTabs_Open(state, absolute, 0)
	path := builtIn && state.codeTab > 0 ? state.codeTabs[state.codeTab - 1] : absolute
	text := builtIn ? CodeEditor_Text(path) : ""
	if !builtIn {
		data, err := os.read_entire_file(absolute, context.temp_allocator)
		if err != nil do return fmt.tprintf("Couldn't read %s", file), false
		text = string(data)
	}
	st, _ := NodeField_FindStruct(text)
	alias := st.engineAlias != "" ? st.engineAlias : "e"
	whose := global != "" ? global : source.name
	handler := Listener_HandlerName(whose, event, Listener_RegisteredHandlers(text))
	// How to reach what sent it: a node's script, or the global
	reach := ""
	if global != "" {
		reach = fmt.tprintf("%s%s := %s.Global(%s)", strings.to_lower(global[:1], context.temp_allocator), global[1:], alias, global)
	} else if sender := NodeDef_Script(&state.project, source); strings.has_prefix(event, e.SCRIPT_EVENT_PREFIX) && sender != "" {
		reach = fmt.tprintf("sender := %s.Node_GetScript(source, %s)", alias, sender)
	}
	code := Listener_HandlerSource(script, handler, whose, event, info, alias, reach)
	lines := strings.count(text, "\n") + (strings.has_suffix(text, "\n") || text == "" ? 0 : 1)
	if !strings.has_suffix(text, "\n") && text != "" do code = strings.concatenate({"\n", code}, context.temp_allocator)
	// The handler's body: the line after its signature
	bodyLine := lines + strings.count(code[:strings.index(code, ":: proc(self")], "\n") + 2
	if builtIn {
		if !CodeEditor_InsertAtLine(path, lines, code) do return "The code editor couldn't take the handler", false
		CodeEditor_GotoLine(path, bodyLine)
	} else {
		if err := os.write_entire_file(absolute, transmute([]u8)strings.concatenate({text, code}, context.temp_allocator)); err != nil {
			return fmt.tprintf("Couldn't write %s", file), false
		}
	}
	target := global != "" ? strings.clone(".") : Scene_NodePath(scene, carrier, listening)
	append(&source.listeners, e.NodeListenerData{strings.clone(event), target, strings.clone(handler), strings.clone(global)})
	return fmt.tprintf("%s now listens to %s's %s: %s_%s in %s (save to build it)", scene.nodes[listening].name, whose, event, script, handler, filepath.base(file)), true
}

// The Listen... dialog's choice (`Listener_Connect` with the dialog's node and event)
Listener_Attach :: proc(state: ^State, target: int) -> (message: string, ok: bool) {
	return Listener_Connect(state, state.listenerDialog.node, target, state.listenerDialog.event, "")
}
