package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:path/filepath"
import "core:strings"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import "gui:skald"

/*
The code editor's providers (code_editor's providers.odin): what the editor adds to OLS in the
code tabs, from the project and the script index (script_index.odin). Registered once, shared by
every tab (`CodeProviders_Registry`):

- **Completion:** the names an engine call's argument takes (code_names.odin: inside its string,
  the project's names of that kind; outside it, their constants first), then the constants of
  the generated scripts/assets.odin (`Scripts_Constants`), each saying what it names; the same
  items from OLS (which reads assets.odin) fold into them. Not after a `.` (a member), in
  comments or in strings
- **Hover:** a constant: what it names; a registered script, data or node type: what uses it,
  its fields and events, and whether that comes from a build or the source (the index)
- **Diagnostics:** the index's problems in the file (a field that can't be exported, a tag option
  that isn't one, a min / max / default that isn't a number), and names the project doesn't have
  in engine calls' string literals, with quick fixes (code_names.odin)
- **Gutter markers and inlay hints:** on each `Script_Register` / `NodeType_Register` line, the
  nodes using it; a click on the marker selects the first (`Code_Marker_Clicked`)
- **Drops:** a scene tree node or a browser asset dropped on a call's argument inserts its constant
  (`PATH_...`, `TEXTURE_...`; a node without one: its path in quotes); anywhere else it adds a
  field to the script struct, as before (`NodeField_Insert`, `AssetField_Insert`)

The providers read the editor's State through `providerState`, set around every call into the
code editor (`CodeProviders_Begin` / `_End`: the code view, a drop); outside those it's nil and
they answer nothing. Package state, like the code editor's host.
*/

@(private="file")
codeProviders: struct {
	registry: ce.Provider_Registry,
	registered: bool,
	// The state the providers read while the code editor runs (nil otherwise)
	state: ^State,
	// The constants, kept until the project changes (`constantsKey`; owned)
	constants: [dynamic]GeneratedConstant,
	constantsKey: u64,
	// What the providers last answered from: a change invalidates them
	seenKey: u64,
	// A gutter marker clicked: the script it's on (owned; "" none), for the view to send
	clicked: string,
}

// The registry every code tab uses (registered on first use)
CodeProviders_Registry :: proc() -> ^ce.Provider_Registry {
	p := &codeProviders
	if !p.registered {
		p.registered = true
		// The names in engine calls first: their constants outrank the others (code_names.odin)
		ce.provider_register(&p.registry, ce.Provider{kind = .Completion, name = "project names", completion = nameCompletions, trigger_chars = "\"/"})
		ce.provider_register(&p.registry, ce.Provider{kind = .Completion, name = "project constants", completion = projectCompletions})
		ce.provider_register(&p.registry, ce.Provider{kind = .Hover, name = "project", hover = projectHover})
		ce.provider_register(&p.registry, ce.Provider{kind = .Diagnostics, name = "script index", diagnostic = indexDiagnostics})
		ce.provider_register(&p.registry, ce.Provider{kind = .Diagnostics, name = "project names", diagnostic = nameDiagnostics})
		ce.provider_register(&p.registry, ce.Provider{kind = .Gutter, name = "script users", gutter = scriptMarkers, on_click = scriptMarkerClicked})
		ce.provider_register(&p.registry, ce.Provider{kind = .Inlay, name = "script users", inlay = scriptInlays})
		ce.provider_register(&p.registry, ce.Provider{kind = .Drop, name = "scene nodes and assets", drop = projectDrop})
	}
	return &p.registry
}

/*
Lets the providers read `state` until CodeProviders_End, and invalidates their cached answers
when the project, the script index or the catalog changed since they last ran.
*/
CodeProviders_Begin :: proc(state: ^State) {
	p := &codeProviders
	p.state = state
	Key :: struct { history, index, catalog, scenes, assets: int }
	k := Key{state.history.version, state.scriptIndex.generation, state.scripts.generation, len(state.project.scenes), len(state.project.assets)}
	key := hash.fnv64a(([^]u8)(&k)[:size_of(k)])
	if key != p.seenKey {
		p.seenKey = key
		if p.registered do ce.provider_registry_invalidate(&p.registry)
	}
}

// The state the providers read (nil outside the code editor's calls: they answer nothing)
@(private)
codeProvidersState :: proc() -> ^State {
	return codeProviders.state
}

CodeProviders_End :: proc() {
	codeProviders.state = nil
}

// Frees the providers' package state (tests, quitting)
CodeProviders_Shutdown :: proc() {
	p := &codeProviders
	ce.provider_registry_destroy(&p.registry)
	constantsFree()
	delete(p.constants)
	delete(p.clicked)
	p^ = {}
}

// A gutter marker click waiting to be sent (the script's name, temp allocated; "" none)
CodeProviders_TakeClick :: proc() -> string {
	p := &codeProviders
	if p.clicked == "" do return ""
	name := strings.clone(p.clicked, context.temp_allocator)
	delete(p.clicked)
	p.clicked = ""
	return name
}

// A gutter marker was clicked: select the first node running the script
Code_Marker_Clicked :: struct {
	// The script (for the frame)
	script: string,
}

/*
The providers' messages (a marker's click).

Returns:
- A command, and whether `m` was one of them
*/
CodeProviders_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case NameTable_Loaded:
		// The engine's name parameters are known: the name providers have something to say
		if codeProviders.registered do ce.provider_registry_invalidate(&codeProviders.registry)
		return {}, true
	case Code_Marker_Clicked:
		users := scriptUsers(state, v.script)
		if len(users) == 0 {
			logLine(state, .Info, fmt.aprintf("No node runs %s yet", v.script))
			return {}, true
		}
		u := users[0]
		// The current scene's first, else the first anywhere
		for x in users do if x.scene == state.currentScene { u = x; break }
		if u.node < 0 {
			logLine(state, .Info, fmt.aprintf("%s runs as a global (Project Settings > Globals)", v.script))
			return {}, true
		}
		// Another scene shows that scene (update shows the scene when currentScene changes)
		state.currentScene = u.scene
		Selection_Set(state, {u.node})
		logLine(state, .Info, fmt.aprintf("Selected %s (it runs %s)", state.project.scenes[u.scene].nodes[u.node].name, v.script))
		return {}, true
	}
	return {}, false
}

// The project's constants (cached until the project changes; the slice is the cache's)
CodeProviders_Constants :: proc(state: ^State) -> []GeneratedConstant {
	p := &codeProviders
	Key :: struct { history, assets, scenes, sets, dialogues, actions, buses: int }
	k := Key{state.history.version, len(state.project.assets), len(state.project.scenes), len(state.project.animationSets), len(state.project.dialogues), len(state.project.actions), len(state.project.buses)}
	key := hash.fnv64a(([^]u8)(&k)[:size_of(k)]) ~ hash.fnv64a(transmute([]u8)state.project.rootPath)
	if key == p.constantsKey && p.constants != nil do return p.constants[:]
	p.constantsKey = key
	constantsFree()
	for c in Scripts_Constants(&state.project) {
		append(&p.constants, GeneratedConstant{
			name = strings.clone(c.name), value = strings.clone(c.value), section = c.section,
			about = strings.clone(c.about), comment = strings.clone(c.comment), target = strings.clone(c.target),
		})
	}
	return p.constants[:]
}

@(private="file")
constantsFree :: proc() {
	for c in codeProviders.constants {
		delete(c.name); delete(c.value); delete(c.about); delete(c.comment); delete(c.target)
	}
	clear(&codeProviders.constants)
}

// A node or global running a script: its scene and node (-1: a global)
ScriptUser :: struct {
	scene, node: int,
}

// What runs a script: nodes of every scene and component (as a script or node type), then the
// globals (temp allocated)
scriptUsers :: proc(state: ^State, script: string) -> []ScriptUser {
	out := make([dynamic]ScriptUser, context.temp_allocator)
	for &scene, si in state.project.scenes do for &node, ni in scene.nodes {
		if NodeDef_Runs(&node, script) do append(&out, ScriptUser{si, ni})
	}
	for g in state.project.globals do if g.script == script do append(&out, ScriptUser{-1, -1})
	return out[:]
}

// "3 nodes: ForestScene/Hero, ..." (temp allocated)
@(private="file")
usersText :: proc(state: ^State, users: []ScriptUser, script: string, limit := 6) -> (short, long: string) {
	nodes, globals := 0, 0
	for u in users {
		if u.node >= 0 do nodes += 1
		else do globals += 1
	}
	switch {
	case nodes == 0 && globals == 0: short = "no node uses it"
	case nodes == 0:                 short = "a global"
	case globals > 0:                short = fmt.tprintf("%d node%s, a global", nodes, nodes == 1 ? "" : "s")
	case:                            short = fmt.tprintf("%d node%s", nodes, nodes == 1 ? "" : "s")
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s: %s", script, short)
	shown := 0
	for u in users {
		if u.node < 0 do continue
		if shown == limit {
			fmt.sbprintf(&b, "\n...and %d more", nodes - limit)
			break
		}
		scene := &state.project.scenes[u.scene]
		owner := Scene_IsComponent(scene) ? fmt.tprintf("%s (component)", ComponentName(scene.component)) : scene.name
		fmt.sbprintf(&b, "\n- %s: %s", owner, scene.nodes[u.node].name)
		shown += 1
	}
	if nodes > 0 do strings.write_string(&b, "\nClick the marker to select it.")
	return short, strings.to_string(b)
}

// Whether a document is one of the project's scripts
@(private)
isProjectScript :: proc(state: ^State, path: string) -> bool {
	if state == nil || path == "" || !strings.has_suffix(path, ".odin") do return false
	folder := absolutePath(joinPath(state.project.rootPath, SCRIPTS_FOLDER, allocator = context.temp_allocator))
	return filepath.dir(absolutePath(path)) == folder
}

// The identifier at a position of a document (a slice of its line; "" none)
@(private="file")
wordAt :: proc(doc: ce.Provider_Document, pos: cebuf.Position) -> string {
	if pos.line < 0 || pos.line >= cebuf.buffer_line_count(doc.buffer) do return ""
	line := cebuf.buffer_line_str(doc.buffer, pos.line)
	isWord :: proc(c: u8) -> bool { return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' }
	start, end := min(pos.col, len(line)), min(pos.col, len(line))
	for start > 0 && isWord(line[start - 1]) do start -= 1
	for end < len(line) && isWord(line[end]) do end += 1
	return line[start:end]
}

// --- the providers ----------------------------------------------------------

@(private="file")
projectCompletions :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, out: ^[dynamic]ce.Provider_Completion) {
	state := codeProviders.state
	if !isProjectScript(state, doc.path) || ctx.syntax.kind == .Comment || ctx.syntax.in_string do return
	// Not a member (`e.`, `self.`): the constants are the package's own
	line := cebuf.buffer_line_str(doc.buffer, pos.line)
	before := pos.col - len(ctx.prefix) - 1
	if before >= 0 && before < len(line) && line[before] == '.' do return
	// Only what can match while the list is open: its words start like the typed one
	lower :: proc(c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + 32 : c }
	for c in CodeProviders_Constants(state) {
		if len(ctx.prefix) > 0 && lower(c.name[0]) != lower(ctx.prefix[0]) do continue
		append(out, ce.Provider_Completion{
			label = c.name,
			detail = constantType(c),
			documentation = fmt.tprintf("%s\n\nscripts/assets.odin (generated by the editor)", c.about),
			kind = 21,
			priority = 1,
		})
	}
}

// What a constant's type reads as ("string", "e.TextureAsset")
@(private="file")
constantType :: proc(c: GeneratedConstant) -> string {
	if strings.has_prefix(c.value, "e.") do return c.value[:strings.index_byte(c.value, '{')]
	return "string"
}

@(private="file")
projectHover :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, out: ^ce.Hover_Content) {
	state := codeProviders.state
	if !isProjectScript(state, doc.path) || ctx.syntax.kind == .Comment do return
	word := wordAt(doc, pos)
	if word == "" do return
	if c := Scripts_FindConstant(CodeProviders_Constants(state), word); c != nil {
		append(&out.blocks, ce.Hover_Block(ce.Hover_Text{text = fmt.tprintf("**%s** :: %s\n\n%s", c.name, c.value, c.about), markdown = true}))
		return
	}
	// A script, data type or node type
	kinds := [3]string{"Script", "Data type", "Node type"}
	lists := [3][]ScriptDesc{state.scripts.scripts[:], state.scripts.dataTypes[:], state.scripts.nodeTypes[:]}
	for list, k in lists do for &d in list {
		if d.name != word do continue
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "**%s %s**", kinds[k], d.name)
		if k == 2 do fmt.sbprintf(&b, " (a %v)", d.base)
		if k != 1 {
			// "Hero: 3 nodes\n- ForestScene: Hero..." without the marker's hint
			_, long := usersText(state, scriptUsers(state, d.name), d.name)
			_, _, users := strings.partition(strings.trim_suffix(long, "\nClick the marker to select it."), ": ")
			fmt.sbprintf(&b, ": %s", users)
		}
		if len(d.fields) > 0 {
			strings.write_string(&b, "\n\nExported fields:")
			for f in d.fields {
				fmt.sbprintf(&b, "\n- %s: %v = %s", f.name, f.type, f.defaultValue == "" ? "\"\"" : f.defaultValue)
			}
		}
		if len(d.events) > 0 {
			strings.write_string(&b, "\n\nEvents:")
			for ev in d.events do fmt.sbprintf(&b, "\n- %s: %s", ev.name, ev.description)
		}
		strings.write_string(&b, d.fromIndex ? "\n\n*From the source (the script index): build to run it.*" : "\n\n*From the last build.*")
		append(&out.blocks, ce.Hover_Block(ce.Hover_Text{text = strings.to_string(b), markdown = true}))
		return
	}
}

// A line of a document that has `text` (the line it had when indexed): `line` (0-based) if it
// still does, else the nearest within 200 lines; -1 when it's gone (edited since)
@(private)
relocate :: proc(doc: ce.Provider_Document, line: int, text: string) -> int {
	count := cebuf.buffer_line_count(doc.buffer)
	for d in 0 ..< 200 {
		for at in ([2]int{line - d, line + d}) {
			if at >= 0 && at < count && cebuf.buffer_line_str(doc.buffer, at) == text do return at
		}
	}
	return -1
}

@(private="file")
indexDiagnostics :: proc(doc: ce.Provider_Document, ctx: ce.Provider_Context, out: ^[dynamic]ce.Provider_Diagnostic) {
	state := codeProviders.state
	if !isProjectScript(state, doc.path) do return
	path := absolutePath(doc.path)
	for p in ScriptIndex_ProblemsIn(&state.scriptIndex, path) {
		at := relocate(doc, p.line - 1, p.lineText)
		if at < 0 do continue
		append(out, ce.Provider_Diagnostic{
			start = {at, p.column}, end = {at, p.endColumn},
			severity = p.warning ? .Warning : .Error,
			message = p.message,
			source = "crossfire",
		})
	}
}

// A script or node type registered on a line of a document
@(private="file")
RegistrationLine :: struct {
	line: int,
	name: string,
}

// The registrations of scripts and node types in a document, on their lines now
@(private="file")
registrationsIn :: proc(state: ^State, doc: ce.Provider_Document) -> []RegistrationLine {
	out := make([dynamic]RegistrationLine, context.temp_allocator)
	f := ScriptIndex_File(&state.scriptIndex, absolutePath(doc.path))
	if f == nil do return nil
	for r in f.registrations {
		if r.kind == .Data do continue
		at := relocate(doc, r.line - 1, r.lineText)
		if at >= 0 do append(&out, RegistrationLine{at, r.name})
	}
	return out[:]
}

@(private="file")
scriptMarkers :: proc(doc: ce.Provider_Document, ctx: ce.Provider_Context, out: ^[dynamic]ce.Gutter_Marker) {
	state := codeProviders.state
	if !isProjectScript(state, doc.path) do return
	for r in registrationsIn(state, doc) {
		users := scriptUsers(state, r.name)
		_, long := usersText(state, users, r.name)
		append(out, ce.Gutter_Marker{line = r.line, icon = len(users) > 0 ? .Diamond : .Ring, tooltip = long})
	}
}

@(private="file")
scriptInlays :: proc(doc: ce.Provider_Document, ctx: ce.Provider_Context, out: ^[dynamic]ce.Inlay_Hint) {
	state := codeProviders.state
	if !isProjectScript(state, doc.path) do return
	for r in registrationsIn(state, doc) {
		short, _ := usersText(state, scriptUsers(state, r.name), r.name)
		append(out, ce.Inlay_Hint{pos = {r.line, len(cebuf.buffer_line_str(doc.buffer, r.line))}, label = short, kind = .Note})
	}
}

// A marker's click: the script registered on its line, for the view to send
@(private="file")
scriptMarkerClicked :: proc(doc: ce.Provider_Document, marker: ce.Gutter_Marker, userData: rawptr) {
	if marker.line < 0 || marker.line >= cebuf.buffer_line_count(doc.buffer) do return
	line := cebuf.buffer_line_str(doc.buffer, marker.line)
	for call in ([]string{"Script_Register(", "NodeType_Register("}) {
		at := strings.index(line, call)
		if at < 0 do continue
		rest := line[at + len(call):]
		end := 0
		for end < len(rest) && (rest[end] == '_' || rest[end] >= 'a' && rest[end] <= 'z' || rest[end] >= 'A' && rest[end] <= 'Z' || rest[end] >= '0' && rest[end] <= '9') do end += 1
		if end == 0 do return
		delete(codeProviders.clicked)
		codeProviders.clicked = strings.clone(rest[:end])
		return
	}
}

// What the code editor is given when something is dropped on it (DropRequest.kind)
CODE_DROP_NODE :: "node"
CODE_DROP_ASSET :: "asset"

@(private="file")
projectDrop :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, drop: ce.Drop_Request, out: ^ce.Drop_Result) -> bool {
	state := codeProviders.state
	if state == nil do return false
	index := int(uintptr(drop.data))
	onArgument := ctx.syntax.kind == .Call_Argument && !ctx.syntax.in_string
	switch drop.kind {
	case CODE_DROP_NODE:
		scene := &state.project.scenes[state.currentScene]
		if index < 0 || index >= len(scene.nodes) do return false
		if onArgument {
			path := constantPathOf(state, scene, index)
			name := path
			for c in CodeProviders_Constants(state) do if c.section == .Node_Paths && c.value == fmt.tprintf("%q", path) && c.target == (Scene_IsComponent(scene) ? ComponentName(scene.component) : scene.name) {
				name = c.name
				break
			}
			text := name == path ? fmt.tprintf("%q", path) : name
			append(&out.edits, ce.Text_Edit{start = pos, end = pos, text = text})
			out.message = fmt.aprintf("Inserted %s (%s)", text, path, allocator = ctx.allocator)
			return true
		}
		message, _ := NodeField_Insert(state, index)
		out.message = strings.clone(message, ctx.allocator)
		return true
	case CODE_DROP_ASSET:
		if index < 0 || index >= len(state.project.assets) do return false
		if onArgument {
			asset := state.project.assets[index]
			for c in CodeProviders_Constants(state) do if c.section == .Assets && c.target == asset.path {
				append(&out.edits, ce.Text_Edit{start = pos, end = pos, text = c.name})
				out.message = fmt.aprintf("Inserted %s (%s)", c.name, asset.path, allocator = ctx.allocator)
				return true
			}
		}
		message, _ := AssetField_Insert(state, index)
		out.message = strings.clone(message, ctx.allocator)
		return true
	}
	return false
}

// A node's path as its PATH_ constant has it: from a component's root, or "/..." from a scene's top
@(private="file")
constantPathOf :: proc(state: ^State, scene: ^SceneDef, node: int) -> string {
	if Scene_IsComponent(scene) {
		parts := make([dynamic]string, context.temp_allocator)
		for at := node; at >= 0 && scene.nodes[at].parent >= 0; at = scene.nodes[at].parent do inject_at(&parts, 0, scene.nodes[at].name)
		return len(parts) == 0 ? "." : strings.join(parts[:], "/", context.temp_allocator)
	}
	return Scene_NodePath(scene, -1, node, context.temp_allocator)
}
