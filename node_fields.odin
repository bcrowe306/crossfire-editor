package crossfire_editor

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:unicode"
import e "engine:."

/*
Script node fields: exported pointers to nodes (`sword: ^e.Area `export:"default=Sword"``),
which the engine sets just before `ready` from a path (`e.Node_FindPath`: relative to the
script's node, `..` for its parent, a leading `/` for the scene's top level). The inspector
offers the scene's nodes that fit a field (`NodeField_Choices`), and dropping a scene tree node
on a code tab adds a field for it (`NodeField_Insert`, code_tabs.odin).
*/

/*
The path from one node of a scene to another, as `e.Node_FindPath` reads it: "." for the node
itself, child names down ("Arm/Hand"), ".." up ("../Camera"). From no node (-1) it's the path
from the top level ("/World/Ship").

Inputs:
- scene: The scene
- from: The node the path starts at, or -1
- to: The node it leads to
- allocator: For the text

Returns:
- The path
*/
Scene_NodePath :: proc(scene: ^SceneDef, from, to: int, allocator := context.allocator) -> string {
	// to's chain from the top level down
	chain := make([dynamic]int, context.temp_allocator)
	for n := to; n >= 0; n = scene.nodes[n].parent do inject_at(&chain, 0, n)
	b := strings.builder_make(allocator)
	if from < 0 {
		for n in chain {
			strings.write_byte(&b, '/')
			strings.write_string(&b, scene.nodes[n].name)
		}
		return strings.to_string(b)
	}
	if from == to do return strings.clone(".", allocator)
	// Up from `from` to the first of its ancestors (or itself) on to's chain; -1: the top level
	common := from
	ups := 0
	for common >= 0 {
		found := false
		for n in chain do if n == common do found = true
		if found do break
		common = scene.nodes[common].parent
		ups += 1
	}
	start := 0
	if common >= 0 do for n, i in chain do if n == common do start = i + 1
	for _ in 0 ..< ups {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, '/')
		strings.write_string(&b, "..")
	}
	for n in chain[start:] {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, '/')
		strings.write_string(&b, scene.nodes[n].name)
	}
	return strings.to_string(b)
}

/*
The node kind a node is built as: its own, or for a Component instance its component's root's.

Inputs:
- project: The project
- node: The node

Returns:
- The kind
*/
NodeDef_BuiltKind :: proc(project: ^Project, node: ^NodeDef) -> NodeKind {
	if node.kind != .Component do return node.kind
	if i := Project_FindComponent(project, node.component); i >= 0 && len(project.scenes[i].nodes) > 0 {
		return NodeDef_BuiltKind(project, &project.scenes[i].nodes[0])
	}
	return .Node2D
}

/*
The paths, from a script's node, to every node of its scene a node field takes: nodes whose
kind is the field's type or embeds it (`e.SceneNodeKind_IsType`). The node itself comes first
(".") when it fits.

Inputs:
- project: The project
- scene: The scene
- from: The script's node
- typeName: The field's node type (`ScriptFieldDesc.hint`: "Sprite", "Node"...)

Returns:
- The paths (temp allocated)
*/
NodeField_Choices :: proc(project: ^Project, scene: ^SceneDef, from: int, typeName: string) -> []string {
	paths := make([dynamic]string, context.temp_allocator)
	for &node, i in scene.nodes {
		if !e.SceneNodeKind_IsType(NodeDef_BuiltKind(project, &node), typeName == "" ? "Node" : typeName) do continue
		path := Scene_NodePath(scene, from, i, context.temp_allocator)
		if i == from do inject_at(&paths, 0, path)
		else do append(&paths, path)
	}
	return paths[:]
}

// Where a script struct is in a file's text: its name and the line of its closing brace (0-based)
NodeField_Struct :: struct {
	name: string,
	closeLine: int,
	// The engine package's import name in the file ("e")
	engineAlias: string,
	// The struct's field names (temp allocated)
	fields: []string,
}

/*
Finds the script struct in a file's text: the first `Name :: struct {` whose body has a
`using script:` field (the one called `name` when given), with the line of its closing brace.

Returns:
- The struct, and false when the file has none
*/
NodeField_FindStruct :: proc(text: string, name := "") -> (found: NodeField_Struct, ok: bool) {
	lines := strings.split_lines(text, context.temp_allocator)
	found.engineAlias = "e"
	for line in lines {
		trimmed := strings.trim_space(line)
		// import e "engine:."
		if strings.has_prefix(trimmed, "import ") && strings.contains(trimmed, "\"engine:") {
			parts := strings.fields(trimmed, context.temp_allocator)
			if len(parts) >= 3 do found.engineAlias = strings.clone(parts[1], context.temp_allocator)
		}
	}
	for i := 0; i < len(lines); i += 1 {
		trimmed := strings.trim_space(lines[i])
		structName, _, rest := strings.partition(trimmed, "::")
		// A named one: only that struct
		if name != "" && strings.trim_space(structName) != name do continue
		if !strings.has_prefix(strings.trim_space(rest), "struct") || !strings.has_suffix(trimmed, "{") do continue
		depth := 0
		isScript := false
		fields := make([dynamic]string, context.temp_allocator)
		for j := i; j < len(lines); j += 1 {
			for c in lines[j] {
				if c == '{' do depth += 1
				if c == '}' do depth -= 1
			}
			body := strings.trim_space(lines[j])
			if j > i && strings.has_prefix(body, "using script:") do isScript = true
			if j > i && depth == 1 {
				if field, _, after := strings.partition(body, ":"); after != "" && !strings.has_prefix(body, "//") {
					append(&fields, strings.trim_space(strings.trim_prefix(field, "using ")))
				}
			}
			if depth == 0 {
				if isScript do return {strings.trim_space(structName), j, found.engineAlias, fields[:]}, true
				i = j
				break
			}
		}
	}
	return {}, false
}

// A field name for a node: its name in lowerCamelCase, letters and digits only, unique in the struct
NodeField_Name :: proc(nodeName: string, taken: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	upper := false
	for r in nodeName {
		if !unicode.is_letter(r) && !unicode.is_digit(r) && r != '_' {
			upper = strings.builder_len(b) > 0
			continue
		}
		if strings.builder_len(b) == 0 {
			if unicode.is_digit(r) do strings.write_byte(&b, 'n')
			strings.write_rune(&b, unicode.to_lower(r))
		} else {
			strings.write_rune(&b, upper ? unicode.to_upper(r) : r)
		}
		upper = false
	}
	base := strings.builder_len(b) > 0 ? strings.to_string(b) : "node"
	name := base
	for n := 2; ; n += 1 {
		used := false
		for t in taken do if t == name do used = true
		if !used do return name
		name = fmt.tprintf("%s%d", base, n)
	}
}

// The engine type's name a node kind is built as ("Area", "Camera2D", "Node")
NodeField_TypeName :: proc(kind: NodeKind) -> string {
	if named, ok := type_info_of(e.SCENE_NODE_TYPES[kind]).variant.(runtime.Type_Info_Named); ok do return named.name
	return "Node"
}

/*
The field line `NodeField_Insert` adds for a node: `\t<name>: ^e.<Type> `export:"default=<path>"`\n`.

Inputs:
- st: The script struct (its fields, so the name is unique, and the engine's import name)
- project: The project (a Component instance's type is its root's)
- scene: The scene
- node: The dropped node
- from: The script's node (the path starts there), or -1 for a path from the top level
*/
NodeField_Line :: proc(st: NodeField_Struct, project: ^Project, scene: ^SceneDef, node, from: int) -> (line, name: string) {
	name = NodeField_Name(scene.nodes[node].name, st.fields)
	type := NodeField_TypeName(NodeDef_BuiltKind(project, &scene.nodes[node]))
	path := Scene_NodePath(scene, from, node, context.temp_allocator)
	return fmt.tprintf("\t%s: ^%s.%s `export:\"default=%s\"`,\n", name, st.engineAlias, type, path), name
}

/*
The node a script's node fields are paths from: the selected node if it uses the script, else
the scene's first that does; none: a component's root (the script runs on its instance's root, or
on an LDtk entity's, named like it), or in a scene -1 (a path from the top level).

Inputs:
- scene: The scene or component
- script: The script's name
- selected: The selected node (-1 for none)

Returns:
- The node's index, or -1
*/
NodeField_From :: proc(scene: ^SceneDef, script: string, selected: int) -> int {
	if selected >= 0 && selected < len(scene.nodes) && NodeDef_Runs(&scene.nodes[selected], script) do return selected
	for &n, i in scene.nodes do if NodeDef_Runs(&n, script) do return i
	if Scene_IsComponent(scene) && len(scene.nodes) > 0 do return 0
	return -1
}

/*
Adds a node field for a node of the open scene to the script shown in the code tab: a pointer
of the node's type, defaulting to the node's path from the script's node (the selected node if
it uses this script, else the scene's first that does; none: a component's root, or in a scene a
path from the top level). The
engine sets it before `ready`. The edit is the code editor's (undoable, unsaved until saved).

Returns:
- What happened, for the Console, and false when nothing was added
*/
NodeField_Insert :: proc(state: ^State, node: int) -> (message: string, ok: bool) {
	if state.codeTab < 1 || state.codeTab > len(state.codeTabs) do return "No script is shown", false
	scene := &state.project.scenes[state.currentScene]
	if node < 0 || node >= len(scene.nodes) do return "No node", false
	path := state.codeTabs[state.codeTab - 1]
	st, found := NodeField_FindStruct(CodeEditor_Text(path))
	if !found do return fmt.tprintf("%s has no script struct (a struct with `using script: e.Script`)", path), false
	from := NodeField_From(scene, st.name, state.selectedNode)
	line, name := NodeField_Line(st, &state.project, scene, node, from)
	// The field above needs a comma now that another follows it
	if at, col, needed := Struct_MissingComma(CodeEditor_Text(path), st.closeLine); needed do CodeEditor_InsertAt(path, at, col, ",")
	if !CodeEditor_InsertAtLine(path, st.closeLine, line) do return "The code editor couldn't take the field", false
	CodeEditor_GotoLine(path, st.closeLine + 1)
	return fmt.tprintf("Added %s to %s: %s (save, and it's set before ready)", name, st.name, strings.trim_space(line)), true
}

/*
Where the last field above a struct's closing brace lacks its comma: Odin allows that only for
the last field, so a field added after it needs one. Comments after the field are kept after it.

Inputs:
- text: The file's text
- closeLine: The line of the struct's closing brace (0-based)

Returns:
- The line and column (bytes) to put the comma at, and whether one is needed
*/
Struct_MissingComma :: proc(text: string, closeLine: int) -> (line, column: int, needed: bool) {
	lines := strings.split_lines(text, context.temp_allocator)
	for i := min(closeLine, len(lines)) - 1; i >= 0; i -= 1 {
		code := lines[i]
		// The part before a line comment (not inside a tag: tags hold no "//" here)
		if at := strings.index(code, "//"); at >= 0 && strings.count(code[:at], "`") % 2 == 0 do code = code[:at]
		code = strings.trim_right_space(code)
		trimmed := strings.trim_space(code)
		if trimmed == "" do continue // blank, or only a comment
		if strings.has_suffix(trimmed, ",") || strings.has_suffix(trimmed, "{") do return 0, 0, false
		return i, len(code), true
	}
	return 0, 0, false
}
