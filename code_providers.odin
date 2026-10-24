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
- **Hover:** a constant: what it names, and a preview of it (an image's thumbnail, a sound's
  length and a play button, an animation's frames, a dialogue node's lines, a component's or
  scene's picture, a font's sample: code_previews.odin); a string literal or a tag's default
  naming an asset or a scene: the same preview; an engine procedure, type or constant: its doc
  comment rendered, instead of OLS's answer (engine_docs.odin); a registered script, data or node
  type: what uses it, its fields and events, and whether that comes from a build or the source
  (the index)
- **Inlay swatches:** color literals (`sdl.Color{...}`, hex in a color field's tag or
  `e.ParseColor`) get a swatch after their line; a click opens the Color dialog, which rewrites
  the literal (code_colors.odin)
- **Diagnostics:** the index's problems in the file (a field that can't be exported, a tag option
  that isn't one, a min / max / default that isn't a number), and names the project doesn't have
  in engine calls' string literals, with quick fixes (code_names.odin)
- **Gutter markers and inlay hints:** on each `Script_Register` / `NodeType_Register` /
  `Data_Register` line, what uses it; on exported fields nodes override and events something
  listens to, those; a click opens the one, or a menu of them (script_links.odin)
- **Find Usages and Rename** of registered types, their exported fields and events
  (script_links.odin, script_rename.odin)
- **Drops:** anything the editor drags onto a code tab (a node, a property, an animation, an
  action, an asset...: a `DropSource`) becomes a field in a struct, a statement in a procedure,
  the constant or expression on a call's argument, with a menu of alternatives on Shift
  (code_drops.odin)

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
	// A usage to open (a marker's click, its menu, Find Usages' panel) or a notice instead, for
	// the view to send (owned)
	open: Maybe(UsageTarget),
	notice: string,
	// The targets of the references panel's last usages (their ids index it)
	usageTargets: [dynamic]UsageTarget,
	// What the rename box offered (prepare_rename's; strings owned), and a rename done in the
	// code for the view to send (its project side and other files' edits; owned)
	renameSymbol: ScriptSymbol,
	renameKnown: bool,
	rename: Maybe(Code_Rename_Requested),
	// Why the last drop inserted nothing (owned)
	dropProblem: string,
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
		ce.provider_register(&p.registry, ce.Provider{kind = .Gutter, name = "script users", gutter = linkMarkers, on_click = linkMarkerClicked})
		ce.provider_register(&p.registry, ce.Provider{kind = .Inlay, name = "script users", inlay = linkInlays})
		ce.provider_register(&p.registry, ce.Provider{kind = .Inlay, name = "color swatches", inlay = colorInlays, on_inlay_click = colorSwatchClicked})
		ce.provider_register(&p.registry, ce.Provider{kind = .Usages, name = "project usages", usages = linkUsages, on_open = linkUsageOpened})
		ce.provider_register(&p.registry, ce.Provider{kind = .Rename, name = "project renames", prepare_rename = linkPrepareRename, rename = linkRename})
		ce.provider_register(&p.registry, ce.Provider{kind = .Drop, name = "editor things", drop = projectDrop})
		// The running game (code_live.odin) and log points (log_points.odin)
		ce.provider_register(&p.registry, ce.Provider{kind = .Inlay, name = "live values", inlay = liveInlays, on_inlay_click = liveInlayClicked})
		ce.provider_register(&p.registry, ce.Provider{kind = .Scrub, name = "live values", scrub_target = liveScrubTarget, on_scrub = liveScrubbed, on_scrub_choice = liveScrubChosen})
		ce.provider_register(&p.registry, ce.Provider{kind = .Gutter, name = "log points", gutter = logPointMarkers, on_click = logPointMarkerClicked, on_gutter_line = logPointGutterLine})
		ce.provider_register(&p.registry, ce.Provider{kind = .Inlay, name = "log points", inlay = logPointInlays})
		ce.provider_register(&p.registry, ce.Provider{kind = .Menu, name = "log points", menu_items = logPointMenuItems, on_menu_item = logPointMenuPicked})
		// "Open Docs" on a name: the docs window (docs_window.odin)
		ce.provider_register(&p.registry, ce.Provider{kind = .Menu, name = "docs", menu_items = docsMenuItems, on_menu_item = docsMenuPicked})
		// Engine-aware code actions in Ctrl+.'s menu (code_actions.odin)
		ce.provider_register(&p.registry, ce.Provider{kind = .Action, name = "project actions", actions = projectActions, on_action = projectActionRun})
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
	Key :: struct {
		history, index, catalog, scenes, assets: int,
		// The running game's tree, watched values and link; what's chosen; the log points
		liveTree, liveFields: int,
		connected: bool,
		liveSelected: u64,
		selected, logPoints: int,
	}
	k := Key{state.history.version, state.scriptIndex.generation, state.scripts.generation, len(state.project.scenes), len(state.project.assets),
		state.live.treeGeneration, state.live.fieldsGeneration, CodeLive_Active(state), hash.fnv64a(transmute([]byte)state.live.selected),
		state.selectedNode, state.logPoints.generation}
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
	delete(p.notice)
	delete(p.dropProblem)
	delete(p.usageTargets)
	symbolFree(&p.renameSymbol)
	renameFree()
	p^ = {}
}

@(private="file")
symbolFree :: proc(s: ^ScriptSymbol) {
	delete(s.owner)
	delete(s.field)
	s^ = {}
}

@(private="file")
renameFree :: proc() {
	r, ok := codeProviders.rename.?
	if !ok do return
	symbolFree(&r.symbol)
	delete(r.newName)
	for edit in r.edits { delete(edit.path); delete(edit.text) }
	delete(r.edits)
	codeProviders.rename = nil
}

// Leaves a usage to open (or a notice when there's none) for the view to send
@(private)
CodeProviders_SetOpen :: proc(target: UsageTarget, notice := "") {
	p := &codeProviders
	delete(p.notice)
	p.notice = strings.clone(notice)
	p.open = notice == "" ? target : nil
}

// The usage (or notice) waiting to be opened, once (the notice temp allocated)
CodeProviders_TakeOpen :: proc() -> (target: UsageTarget, notice: string, ok: bool) {
	p := &codeProviders
	if t, has := p.open.?; has {
		p.open = nil
		return t, "", true
	}
	if p.notice != "" {
		notice = strings.clone(p.notice, context.temp_allocator)
		delete(p.notice)
		p.notice = ""
		return {}, notice, true
	}
	return {}, "", false
}

// Keeps the references panel's usages' targets (their ids index them)
@(private)
CodeProviders_SetUsageTargets :: proc(targets: []UsageTarget) {
	clear(&codeProviders.usageTargets)
	append(&codeProviders.usageTargets, ..targets)
}

// The target of a usage the references panel listed
@(private)
CodeProviders_UsageTarget :: proc(id: int) -> (UsageTarget, bool) {
	t := codeProviders.usageTargets[:]
	if id < 0 || id >= len(t) do return {}, false
	return t[id], true
}

// Keeps what the rename box offered (cloned)
@(private)
CodeProviders_SetRenameSymbol :: proc(symbol: ScriptSymbol) {
	p := &codeProviders
	symbolFree(&p.renameSymbol)
	p.renameSymbol = symbol
	p.renameSymbol.owner = strings.clone(symbol.owner)
	p.renameSymbol.field = strings.clone(symbol.field)
	p.renameKnown = true
}

// What the rename box offered (temp allocated)
@(private)
CodeProviders_RenameSymbol :: proc() -> (ScriptSymbol, bool) {
	p := &codeProviders
	s := p.renameSymbol
	s.owner = strings.clone(s.owner, context.temp_allocator)
	s.field = strings.clone(s.field, context.temp_allocator)
	return s, p.renameKnown
}

// Leaves a rename's project side and other files' edits for the view to send (cloned)
@(private)
CodeProviders_SetRename :: proc(symbol: ScriptSymbol, newName: string, edits: []CodeEdit) {
	renameFree()
	s := symbol
	s.owner = strings.clone(symbol.owner)
	s.field = strings.clone(symbol.field)
	owned := make([]CodeEdit, len(edits))
	for edit, i in edits {
		owned[i] = edit
		owned[i].path = strings.clone(edit.path)
		owned[i].text = strings.clone(edit.text)
	}
	codeProviders.rename = Code_Rename_Requested{symbol = s, newName = strings.clone(newName), edits = owned}
}

// The rename waiting to be sent, once (temp allocated)
CodeProviders_TakeRename :: proc() -> (Code_Rename_Requested, bool) {
	r, ok := codeProviders.rename.?
	if !ok do return {}, false
	out := r
	out.symbol.owner = strings.clone(r.symbol.owner, context.temp_allocator)
	out.symbol.field = strings.clone(r.symbol.field, context.temp_allocator)
	out.newName = strings.clone(r.newName, context.temp_allocator)
	out.edits = make([]CodeEdit, len(r.edits), context.temp_allocator)
	for edit, i in r.edits {
		out.edits[i] = edit
		out.edits[i].path = strings.clone(edit.path, context.temp_allocator)
		out.edits[i].text = strings.clone(edit.text, context.temp_allocator)
	}
	renameFree()
	return out, true
}

/*
The providers' messages: a usage to open (a marker's click or menu, Find Usages), a rename's
project side and other files' edits.

Returns:
- A command, and whether `m` was one of them
*/
CodeProviders_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case NameTable_Loaded:
		// The engine's name parameters are known: the name providers have something to say
		if codeProviders.registered do ce.provider_registry_invalidate(&codeProviders.registry)
		return {}, true
	case EngineDocs_Loaded:
		// Hovers ask the table when they're asked: nothing to redo
		return {}, true
	case Code_Hover_Audio:
		if message := CodePreviews_PlayAudio(state, v.path, v.play); message != "" do logLine(state, .Warning, fmt.aprintf("Preview: %s", message))
		return {}, true
	case Code_Help_Requested:
		Docs_Navigate(&state.docs, string(v))
		return {}, true
	case Code_Usage_Opened:
		if v.notice != "" {
			logLine(state, .Info, strings.clone(v.notice))
			return {}, true
		}
		ScriptLinks_Open(state, v.target)
		return {}, true
	case Code_Rename_Requested:
		logLine(state, .Info, strings.clone(ScriptRename_Apply(state, v)))
		// The index reads the renamed code at its next tick (the tabs' text)
		if codeProviders.registered do ce.provider_registry_invalidate(&codeProviders.registry)
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
			group = strings.clone(c.group),
		})
	}
	return p.constants[:]
}

@(private="file")
constantsFree :: proc() {
	for c in codeProviders.constants {
		delete(c.name); delete(c.value); delete(c.about); delete(c.comment); delete(c.target); delete(c.group)
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
	// A string (or a tag's default) naming an asset or a scene: its preview
	if CodePreviews_Literal(state, doc, pos, out) do return
	word := wordAt(doc, pos)
	if word == "" do return
	if c := Scripts_FindConstant(CodeProviders_Constants(state), word); c != nil {
		// The preview first (a play button stays in view in a short tab), then what the constant is
		CodePreviews_Constant(state, c, out)
		append(&out.blocks, ce.Hover_Block(ce.Hover_Text{text = fmt.tprintf("**%s** :: %s\n\n%s", c.name, c.value, c.about), markdown = true}))
		return
	}
	// An engine declaration: its documentation, instead of the language server's
	if d, ok := engineDocAt(state, doc, pos); ok {
		append(&out.blocks, ce.Hover_Block(ce.Hover_Text{text = EngineDoc_Markdown(d), markdown = true}))
		out.replace_server = true
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
			_, _, users := strings.partition(long, ": ")
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

// Something dropped on the code: what it becomes there (code_drops.odin)
@(private="file")
projectDrop :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, drop: ce.Drop_Request, out: ^ce.Drop_Result) -> bool {
	state := codeProviders.state
	if state == nil || drop.kind != CODE_DROP_SOURCE || drop.data == nil do return false
	src := (^DropSource)(drop.data)^
	if !CodeDrops_Build(state, doc, pos, ctx.syntax, src, out, ctx.allocator) {
		// Nothing to insert: the reason is still the host's to log
		delete(codeProviders.dropProblem)
		codeProviders.dropProblem = strings.clone(out.message)
		return false
	}
	return true
}

// Why the last drop inserted nothing, once ("" none; temp allocated)
CodeProviders_TakeDropProblem :: proc() -> string {
	p := &codeProviders
	text := strings.clone(p.dropProblem, context.temp_allocator)
	delete(p.dropProblem)
	p.dropProblem = ""
	return text
}

// A node's path as its PATH_ constant has it: from a component's root, or "/..." from a scene's top
@(private)
constantPathOf :: proc(scene: ^SceneDef, node: int) -> string {
	if Scene_IsComponent(scene) {
		parts := make([dynamic]string, context.temp_allocator)
		for at := node; at >= 0 && scene.nodes[at].parent >= 0; at = scene.nodes[at].parent do inject_at(&parts, 0, scene.nodes[at].name)
		return len(parts) == 0 ? "." : strings.join(parts[:], "/", context.temp_allocator)
	}
	return Scene_NodePath(scene, -1, node, context.temp_allocator)
}

// F1 in a code tab: a page to open (the engine declaration's API page, or the manual)
Code_Help_Requested :: distinct string

// The engine declaration named at a position (`e.Camera2D_Follow`), through the file's import name
@(private)
engineDocAt :: proc(state: ^State, doc: ce.Provider_Document, pos: cebuf.Position) -> (EngineDoc, bool) {
	table := EngineDocs_Get()
	if table == nil || pos.line < 0 || pos.line >= cebuf.buffer_line_count(doc.buffer) do return {}, false
	alias := "e"
	if file := ScriptIndex_File(&state.scriptIndex, absolutePath(doc.path)); file != nil && file.engineAlias != "" do alias = file.engineAlias
	return EngineDocs_At(table, cebuf.buffer_line_str(doc.buffer, pos.line), pos.col, alias)
}

/*
Where F1 goes in a code tab: the API entry of the engine declaration at the caret, else the page
of the type the code shows for the name there (`CodeProviders_DocsAt`), else "" (the manual's
code editor page).

Returns:
- The docs window's address ("" none; temp allocated)
*/
CodeProviders_HelpAt :: proc(state: ^State, doc: ce.Provider_Document, pos: cebuf.Position) -> string {
	if state == nil do return ""
	if d, ok := engineDocAt(state, doc, pos); ok do return Docs_EngineAddress(d)
	return CodeProviders_DocsAt(state, doc, pos)
}

/*
Where a code tab's "Open Docs" goes for the name at a position: an engine name (`e.Sprite`,
`e.Camera2D_Follow`) is a node type's guide or its API entry; a field, variable or parameter
goes through the type the code shows for it (`self.door` declared `door: ^e.Door`: the Door's
guide; script_rename.odin's `ScriptCode_TypeAt`).

Returns:
- The docs window's address ("" when the name isn't one the docs have; temp allocated)
*/
CodeProviders_DocsAt :: proc(state: ^State, doc: ce.Provider_Document, pos: cebuf.Position) -> string {
	if state == nil do return ""
	table := EngineDocs_Get()
	if d, ok := engineDocAt(state, doc, pos); ok do return Docs_EngineNameAddress(d.name, table)
	typeText, alias := ScriptCode_TypeAt(scriptSources(state), absolutePath(doc.path), pos.line, pos.col)
	return Docs_TypeAddress(typeText, alias, table)
}

// The address "Open Docs" in a code tab's menu left for the view to open (heap; "" none)
@(private="file")
docsLeft: string

@(private)
docsMenuItems :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, out: ^[dynamic]string) {
	if CodeProviders_DocsAt(codeProvidersState(), doc, pos) != "" do append(out, "Open Docs")
}

@(private)
docsMenuPicked :: proc(doc: ce.Provider_Document, pos: cebuf.Position, index: int, userData: rawptr) {
	address := CodeProviders_DocsAt(codeProvidersState(), doc, pos)
	if address == "" do return
	delete(docsLeft)
	docsLeft = strings.clone(address)
}

// Sends what a code tab's "Open Docs" left (the code view, after the code editor ran)
CodeProviders_TakeDocs :: proc(ctx: ^skald.Ctx(Msg)) {
	if docsLeft == "" do return
	skald.send(ctx, Msg(Docs_Opened(strings.clone(docsLeft, context.temp_allocator))))
	delete(docsLeft)
	docsLeft = ""
}
