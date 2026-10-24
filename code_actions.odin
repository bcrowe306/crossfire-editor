package crossfire_editor

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:reflect"
import "core:strconv"
import "core:strings"
import vmem "core:mem/virtual"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import "gui:skald"
import e "engine:."

/*
Engine-aware code actions (round 7 of TODO.md's "Code editor integration"): what Ctrl+. offers in
a script's code tab besides the quick fixes, each only where it applies, read from the tab's text
(parsed again when asked, `CodeActions_Read`) and the script index (other files, the catalog it
keeps up to date): no build needed. Each one's edits are one undo step in the tab, written with
tabs, previewed beside the menu.

- **Handle an event** (`Handle door's onOpened`): on a node field (its declaration, or
  `self.door` in the script's procedures) of a node type with events (an engine one's, a node
  type of the game's: its base kind's and its own tagged `EventSubject` fields), or on the script
  struct's line or its registration for the events of the node it runs on (when every node
  running it is of one kind; a node type's own). It writes a handler before the registration and
  subscribes it in the `ready` hook (adding the hook when there's none):
  `if self.door != nil do e.Event_Subscribe(&self.door.onOpened, Hero_onDoorOpened, self)`.
  **Decided:** the subscription is code, as the demo's scripts subscribe, not a scene listener
  as Listen... adds: it holds for every node running the script, in every scene, without a
  scene edit beside the code's (so it's one undo step), and reads in the script. Listen... stays
  the way to wire one node's event to another node's script. Events already subscribed that way
  aren't offered again.
- **Export a field** (`Export speed`, and for numbers `Export speed with a range...`: the Range
  dialog, min / max / default): on a field of a registered struct whose type the inspector edits
  (the index's rules), not tagged yet. The default comes from the field's first assignment in
  the struct's procedures (`self.speed = 250`), else the type's zero (a node field: the first
  node that fits, from the first node running the script). On an exported field: `Remove export`
  and, for numbers, `Set speed's range...`.
- **A switch over a state machine's states** (decided, since round 1's typed constants already
  are the "state machine constants"): in a procedure of the script, on a `^e.StateMachine`
  field (or a blank line, for each such field), a `switch e.StateMachine_Current(self.brain)`
  with a case per `STATE_` constant of the machine the field points to (from the nodes running
  the script), inside a nil check.
- **Register the struct** as a script (it embeds `using script: e.Script`) or a node type (it
  embeds an engine node type) when no file registers it: New Script's `@(init)` registration
  (`ScriptTemplate_Registration`) after the struct, the `vendor:sdl3` import added when missing.
- **Add a hook** (`Add the update hook`) on a registration: the hooks the literal lacks (ready,
  update, draw, destroy; the physics ones for bodies and areas; sceneChanged and loaded for
  globals), with the engine's signatures.
- **Show a field in the inspector** on an exported field: selects a node running the script (the
  selected one when it does, else one in the open scene, else the first) and scrolls the
  inspector to the field (`Code_Field_Reveal_Requested`, `Inspector_RevealWidget`). The other
  way, a script field's label in the inspector has **Go to Declaration** (its right-click menu,
  or Ctrl+click): `Script_Field_Declaration_Requested`.

Actions that change State (the dialog, the inspector) can't do it inside the code editor's call:
the provider leaves a message (`codeActions.pending`) for the code view to send
(`CodeActions_Take`).
*/

// --- the tab's code, as the actions read it -------------------------------------------------

// A struct field as written (0-based line, byte columns)
CodeActionField :: struct {
	name, type: string,
	// The tag's text inside its backquotes ("" none)
	tag: string,
	line, column: int,
	// The column after the type, on the name's line (-1: the type goes on to another line)
	typeEnd: int,
	// The backquoted tag's columns, backquotes included (-1: none)
	tagStart, tagEnd: int,
	isUsing: bool,
}

// A struct declared in the file
CodeActionStruct :: struct {
	name: string,
	// `Name :: struct {` and its closing brace
	line, closeLine: int,
	// The first field's type when it's `using` (`e.Script`)
	embeds: string,
	fields: [dynamic]CodeActionField,
}

// A hook of a registration's literal: `ready = proc(self: ^Hero) {`
CodeActionHook :: struct {
	name: string,
	// Its first parameter's name
	param: string,
	line: int,
	// Its body's closing brace
	closeLine, closeColumn: int,
}

// A `Script_Register` / `NodeType_Register` / `Data_Register` call
CodeActionRegistration :: struct {
	kind: IndexRegistrationKind,
	name, base: string,
	line: int,
	// The first line of the declaration holding it (its attributes)
	declLine: int,
	// The hooks are a literal (`{...}`): its braces
	hasHooks: bool,
	openLine, openColumn, closeLine, closeColumn: int,
	hooks: [dynamic]CodeActionHook,
}

// A procedure (declared or a literal): its lines and its first parameter when that's a pointer
// to a named type (`self: ^Hero`)
CodeActionProc :: struct {
	startLine, endLine: int,
	selfName, selfType: string,
}

// What the actions know of a file (temp allocated; names are slices of its text)
CodeActionCode :: struct {
	lines: []string,
	// The engine's and SDL's import names ("" not imported), the last import's line (-1 none)
	engineAlias, sdlAlias: string,
	lastImportLine: int,
	structs: [dynamic]CodeActionStruct,
	registrations: [dynamic]CodeActionRegistration,
	procs: [dynamic]CodeActionProc,
	// The file's top-level declarations' names
	decls: [dynamic]string,
	errors: int,
}

/*
Reads a script's text for the code actions with core:odin/parser (the script index's parser), the
AST in an arena freed at once. Pure, so tests call it.

Returns:
- What the file declares, with the positions the actions write at (temp allocated)
*/
CodeActions_Read :: proc(path, text: string) -> (code: CodeActionCode) {
	temp := context.temp_allocator
	code.lines = strings.split_lines(text, temp)
	code.lastImportLine = -1
	code.structs = make([dynamic]CodeActionStruct, temp)
	code.registrations = make([dynamic]CodeActionRegistration, temp)
	code.procs = make([dynamic]CodeActionProc, temp)
	code.decls = make([dynamic]string, temp)

	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil do return
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)
	file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
	file.src = text
	file.fullpath = path
	p := parser.default_parser()
	p.err = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
	parser.parse_file(&p, file)
	code.errors = p.error_count

	for imp in file.imports {
		rel := strings.trim(imp.relpath.text, "\"`")
		switch rel {
		case "engine:.", "engine:", "engine": code.engineAlias = imp.name.text != "" ? imp.name.text : "crossfire"
		case "vendor:sdl3":                  code.sdlAlias = imp.name.text != "" ? imp.name.text : "sdl3"
		}
		code.lastImportLine = max(code.lastImportLine, imp.relpath.pos.line - 1)
	}
	columnOf :: proc(src: string, offset: int) -> int {
		start := clamp(offset, 0, len(src))
		for start > 0 && src[start - 1] != '\n' do start -= 1
		return offset - start
	}
	sourceOf :: proc(src: string, node: ^ast.Node) -> string {
		return src[clamp(node.pos.offset, 0, len(src)):clamp(node.end.offset, 0, len(src))]
	}

	for decl in file.decls {
		vd, isValue := decl.derived.(^ast.Value_Decl)
		if !isValue do continue
		for name in vd.names do if ident, ok := name.derived.(^ast.Ident); ok do append(&code.decls, ident.name)
		if vd.is_mutable || len(vd.names) != 1 || len(vd.values) != 1 do continue
		ident, isIdent := vd.names[0].derived.(^ast.Ident)
		st, isStruct := vd.values[0].derived.(^ast.Struct_Type)
		if !isIdent || !isStruct || st.fields == nil do continue
		// Only a struct that's closed (a half-typed one runs on into what follows)
		if st.end.offset < 1 || st.end.offset > len(text) || text[st.end.offset - 1] != '}' do continue
		out := CodeActionStruct{name = ident.name, line = ident.pos.line - 1, closeLine = st.end.line - 1}
		out.fields = make([dynamic]CodeActionField, temp)
		for f, fi in st.fields.list {
			if f.type == nil do continue
			b := strings.builder_make(temp)
			for c in sourceOf(text, f.type) do if c != ' ' && c != '\t' && c != '\n' && c != '\r' do strings.write_rune(&b, c)
			type := strings.to_string(b)
			isUsing := .Using in f.flags
			if fi == 0 && isUsing do out.embeds = type
			for name in f.names {
				nameIdent, ok := name.derived.(^ast.Ident)
				if !ok do continue
				field := CodeActionField{
					name = nameIdent.name, type = type, line = nameIdent.pos.line - 1, column = nameIdent.pos.column - 1,
					typeEnd = f.type.end.line == nameIdent.pos.line ? columnOf(text, f.type.end.offset) : -1,
					tagStart = -1, tagEnd = -1, isUsing = isUsing,
				}
				if f.tag.text != "" && f.tag.pos.line == nameIdent.pos.line {
					field.tag = strings.trim(f.tag.text, "`")
					field.tagStart = columnOf(text, f.tag.pos.offset)
					field.tagEnd = field.tagStart + len(f.tag.text)
				}
				append(&out.fields, field)
			}
		}
		append(&code.structs, out)
	}

	// Registrations (with their hooks) and procedures, through every declaration
	Walk :: struct {
		code: ^CodeActionCode,
		src: string,
		declLine: int,
	}
	w := Walk{code = &code, src = text}
	visitor := ast.Visitor{data = &w, visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil do return nil
		w := (^Walk)(v.data)
		temp := context.temp_allocator
		columnOf :: proc(src: string, offset: int) -> int {
			start := clamp(offset, 0, len(src))
			for start > 0 && src[start - 1] != '\n' do start -= 1
			return offset - start
		}
		selfOf :: proc(type: ^ast.Proc_Type) -> (name, typeName: string) {
			if type == nil || type.params == nil || len(type.params.list) == 0 do return
			first := type.params.list[0]
			if len(first.names) > 0 do if ident, ok := first.names[0].derived.(^ast.Ident); ok do name = ident.name
			if ptr, isPtr := first.type.derived.(^ast.Pointer_Type); isPtr && ptr.elem != nil {
				#partial switch elem in ptr.elem.derived {
				case ^ast.Ident: typeName = elem.name
				case ^ast.Selector_Expr: if elem.field != nil do typeName = elem.field.name
				}
			}
			return
		}
		#partial switch n in node.derived {
		case ^ast.Proc_Lit:
			self, selfType := selfOf(n.type)
			append(&w.code.procs, CodeActionProc{n.pos.line - 1, n.end.line - 1, self, selfType})
		case ^ast.Call_Expr:
			callee := ""
			#partial switch c in n.expr.derived {
			case ^ast.Selector_Expr: if c.field != nil do callee = c.field.name
			case ^ast.Ident: callee = c.name
			}
			kind: IndexRegistrationKind
			hooksAt := 1
			switch callee {
			case "Script_Register": kind = .Script
			case "Data_Register": kind = .Data
			case "NodeType_Register": kind, hooksAt = .NodeType, 2
			case: return v
			}
			if len(n.args) == 0 do return v
			name := ""
			#partial switch a in n.args[0].derived {
			case ^ast.Ident: name = a.name
			case ^ast.Selector_Expr: if a.field != nil do name = a.field.name
			}
			if name == "" do return v
			reg := CodeActionRegistration{kind = kind, name = name, line = n.pos.line - 1, declLine = w.declLine}
			reg.hooks = make([dynamic]CodeActionHook, temp)
			if kind == .NodeType && len(n.args) > 1 {
				if sel, ok := n.args[1].derived.(^ast.Implicit_Selector_Expr); ok && sel.field != nil do reg.base = sel.field.name
			}
			if kind != .Data && len(n.args) > hooksAt {
				if lit, ok := n.args[hooksAt].derived.(^ast.Comp_Lit); ok {
					reg.hasHooks = true
					reg.openLine, reg.openColumn = lit.open.line - 1, columnOf(w.src, lit.open.offset)
					reg.closeLine, reg.closeColumn = lit.close.line - 1, columnOf(w.src, lit.close.offset)
					for elem in lit.elems {
						fv, isField := elem.derived.(^ast.Field_Value)
						if !isField do continue
						hookName, named := fv.field.derived.(^ast.Ident)
						procLit, isProc := fv.value.derived.(^ast.Proc_Lit)
						if !named || !isProc do continue
						hook := CodeActionHook{name = hookName.name, line = fv.pos.line - 1, closeLine = -1}
						hook.param, _ = selfOf(procLit.type)
						if body, ok := procLit.body.derived.(^ast.Block_Stmt); ok && procLit.body != nil {
							hook.closeLine, hook.closeColumn = body.close.line - 1, columnOf(w.src, body.close.offset)
						}
						append(&reg.hooks, hook)
					}
				}
			}
			append(&w.code.registrations, reg)
		}
		return v
	}}
	for decl in file.decls {
		w.declLine = decl.pos.line - 1
		if vd, ok := decl.derived.(^ast.Value_Decl); ok do for attr in vd.attributes do w.declLine = min(w.declLine, attr.pos.line - 1)
		ast.walk(&visitor, decl)
	}
	return
}

// --- what the actions look things up in -----------------------------------------------------

// The struct whose lines hold `line` (nil none)
@(private="file")
structAt :: proc(code: ^CodeActionCode, line: int) -> ^CodeActionStruct {
	for &s in code.structs do if s.line <= line && line <= s.closeLine do return &s
	return nil
}

@(private="file")
structNamed :: proc(code: ^CodeActionCode, name: string) -> ^CodeActionStruct {
	for &s in code.structs do if s.name == name do return &s
	return nil
}

@(private="file")
fieldOn :: proc(s: ^CodeActionStruct, line: int) -> ^CodeActionField {
	if s == nil do return nil
	for &f in s.fields do if f.line == line do return &f
	return nil
}

@(private="file")
fieldNamed :: proc(s: ^CodeActionStruct, name: string) -> ^CodeActionField {
	if s == nil do return nil
	for &f in s.fields do if f.name == name do return &f
	return nil
}

// This file's registration of a struct (nil none)
@(private="file")
registrationOf :: proc(code: ^CodeActionCode, name: string) -> ^CodeActionRegistration {
	for &r in code.registrations do if r.name == name do return &r
	return nil
}

// Whether a struct is registered: in this file's text, or another file the index read
@(private="file")
registeredAnywhere :: proc(state: ^State, code: ^CodeActionCode, path, name: string) -> bool {
	if registrationOf(code, name) != nil do return true
	for file, &f in state.scriptIndex.files {
		if file == path do continue
		for r in f.registrations do if r.name == name do return true
	}
	return false
}

// The innermost procedure holding a line (nil none)
@(private="file")
procAt :: proc(code: ^CodeActionCode, line: int) -> ^CodeActionProc {
	best: ^CodeActionProc
	for &p in code.procs {
		if p.startLine > line || line > p.endLine do continue
		if best == nil || p.endLine - p.startLine < best.endLine - best.startLine do best = &p
	}
	return best
}

// The hook whose header or body holds a line (nil none)
@(private="file")
hookAt :: proc(reg: ^CodeActionRegistration, line: int) -> ^CodeActionHook {
	for &h in reg.hooks do if h.line <= line && line <= h.closeLine do return &h
	return nil
}

@(private="file")
hookNamed :: proc(reg: ^CodeActionRegistration, name: string) -> ^CodeActionHook {
	for &h in reg.hooks do if h.name == name do return &h
	return nil
}

// The identifier at a column of a line, and whether `<receiver>.` comes right before it
@(private="file")
memberAt :: proc(line: string, col: int) -> (word, receiver: string) {
	isWord :: proc(c: u8) -> bool { return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' }
	start, end := min(col, len(line)), min(col, len(line))
	for start > 0 && isWord(line[start - 1]) do start -= 1
	for end < len(line) && isWord(line[end]) do end += 1
	word = line[start:end]
	if start > 0 && line[start - 1] == '.' {
		r := start - 1
		for r > 0 && isWord(line[r - 1]) do r -= 1
		receiver = line[r:start - 1]
	}
	return
}

// A name nothing in the scripts package declares yet: `base`, else `base2`, `base3`...
@(private="file")
uniqueDecl :: proc(state: ^State, code: ^CodeActionCode, path, base: string) -> string {
	taken :: proc(state: ^State, code: ^CodeActionCode, path, name: string) -> bool {
		for d in code.decls do if d == name do return true
		decl := fmt.tprintf("%s ::", name)
		for src in scriptSources(state) {
			if absolutePath(src.path) == path do continue
			for line in strings.split_lines(src.text, context.temp_allocator) do if strings.has_prefix(line, decl) do return true
		}
		return false
	}
	name := base
	for n := 2; taken(state, code, path, name); n += 1 do name = fmt.tprintf("%s%d", base, n)
	return name
}

// The leading tabs (and spaces) of a line
@(private="file")
tabsOf :: proc(line: string) -> string {
	return indentOf(line)
}

// `e.` and `sdl.` written as the file imports them (temp allocated)
@(private="file")
aliased :: proc(code: ^CodeActionCode, text: string) -> string {
	out := engineAliased(code.engineAlias != "" ? code.engineAlias : "e", text)
	sdl := code.sdlAlias != "" ? code.sdlAlias : "sdl"
	if sdl == "sdl" do return out
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(out); i += 1 {
		wordStart := i == 0 || !(out[i - 1] == '_' || out[i - 1] == '.' || out[i - 1] >= 'a' && out[i - 1] <= 'z' || out[i - 1] >= 'A' && out[i - 1] <= 'Z' || out[i - 1] >= '0' && out[i - 1] <= '9')
		if wordStart && strings.has_prefix(out[i:], "sdl.") {
			strings.write_string(&b, sdl)
			strings.write_byte(&b, '.')
			i += 3
			continue
		}
		strings.write_byte(&b, out[i])
	}
	return strings.to_string(b)
}

// The import of vendor:sdl3 a file needs for code using `sdl.` (none when it has one)
@(private="file")
sdlImportEdit :: proc(code: ^CodeActionCode) -> (ce.Text_Edit, bool) {
	if code.sdlAlias != "" do return {}, false
	at := code.lastImportLine >= 0 ? code.lastImportLine + 1 : 1
	return ce.Text_Edit{start = {at, 0}, end = {at, 0}, text = "import sdl \"vendor:sdl3\"\n"}, true
}

// --- the provider ----------------------------------------------------------------------------

// What an action does besides its edits, for the code view to send (`codeActions.pending`)
CodeActionCommand :: union {
	Code_Range_Requested,
	Code_Field_Reveal_Requested,
}

@(private="file")
codeActions: struct {
	// The last menu's commands (an action's id is its index + 1; owned)
	commands: [dynamic]CodeActionCommand,
	// The command of the action picked, for the view to send (owned)
	pending: Maybe(CodeActionCommand),
}

@(private="file")
commandFree :: proc(c: CodeActionCommand) {
	switch v in c {
	case Code_Range_Requested: delete(v.path); delete(v.lineText); delete(v.field); delete(v.min); delete(v.max); delete(v.defaultValue)
	case Code_Field_Reveal_Requested: delete(v.script); delete(v.field)
	}
}

@(private="file")
commandClone :: proc(c: CodeActionCommand, allocator := context.allocator) -> CodeActionCommand {
	switch v in c {
	case Code_Range_Requested:
		out := v
		out.path = strings.clone(v.path, allocator)
		out.lineText = strings.clone(v.lineText, allocator)
		out.field = strings.clone(v.field, allocator)
		out.min = strings.clone(v.min, allocator)
		out.max = strings.clone(v.max, allocator)
		out.defaultValue = strings.clone(v.defaultValue, allocator)
		return out
	case Code_Field_Reveal_Requested:
		return Code_Field_Reveal_Requested{strings.clone(v.script, allocator), strings.clone(v.field, allocator)}
	}
	return nil
}

// Keeps a command for an action of this menu; returns its id
@(private="file")
commandAdd :: proc(c: CodeActionCommand) -> int {
	append(&codeActions.commands, commandClone(c))
	return len(codeActions.commands)
}

// Frees the package state (tests, quitting)
CodeActions_Shutdown :: proc() {
	for c in codeActions.commands do commandFree(c)
	delete(codeActions.commands)
	if c, ok := codeActions.pending.?; ok do commandFree(c)
	codeActions = {}
}

// Sends what an action picked left (the view, after the code editor ran)
CodeActions_Take :: proc(ctx: ^skald.Ctx(Msg)) {
	c, ok := codeActions.pending.?
	if !ok do return
	codeActions.pending = nil
	defer commandFree(c)
	switch v in commandClone(c, context.temp_allocator) {
	case Code_Range_Requested:        skald.send(ctx, Msg(v))
	case Code_Field_Reveal_Requested: skald.send(ctx, Msg(v))
	}
}

// The command an action left, once (temp allocated; tests)
CodeActions_TakePending :: proc() -> (CodeActionCommand, bool) {
	c, ok := codeActions.pending.?
	if !ok do return nil, false
	codeActions.pending = nil
	defer commandFree(c)
	return commandClone(c, context.temp_allocator), true
}

// Everything an action builder needs
@(private="file")
ActionCtx :: struct {
	state: ^State,
	doc: ce.Provider_Document,
	pos: cebuf.Position,
	syntax: ce.Syntax_Context,
	code: ^CodeActionCode,
	// The document's absolute path
	path: string,
	out: ^[dynamic]ce.Provider_Action,
}

// Ctrl+. in a script: the actions that apply at the caret (see the file's comment)
@(private)
projectActions :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, out: ^[dynamic]ce.Provider_Action) {
	state := codeProvidersState()
	if !isProjectScript(state, doc.path) || ctx.syntax.kind == .Comment || ctx.syntax.in_string do return
	for c in codeActions.commands do commandFree(c)
	clear(&codeActions.commands)
	code := CodeActions_Read(doc.path, docText(doc))
	if code.engineAlias == "" do return
	a := ActionCtx{state = state, doc = doc, pos = pos, syntax = ctx.syntax, code = &code, path = absolutePath(doc.path), out = out}
	handlerActions(&a)
	exportActions(&a)
	stateSwitchActions(&a)
	registerActions(&a)
	hookActions(&a)
}

// An action picked: its command (if any) waits for the view
@(private)
projectActionRun :: proc(doc: ce.Provider_Document, action: ce.Provider_Action, userData: rawptr) {
	if action.id <= 0 || action.id > len(codeActions.commands) do return
	if c, ok := codeActions.pending.?; ok do commandFree(c)
	codeActions.pending = commandClone(codeActions.commands[action.id - 1])
}

// --- handlers for events ---------------------------------------------------------------------

// The events of a field's node type (`^e.Door`, `^Door`: a node type of the game's); nil none
@(private="file")
fieldEvents :: proc(state: ^State, code: ^CodeActionCode, type: string) -> []e.NodeEventInfo {
	if !strings.has_prefix(type, "^") || strings.contains(type, "[") do return nil
	name := type[1:]
	if dot := strings.index_byte(name, '.'); dot >= 0 {
		if name[:dot] != code.engineAlias do return nil
		return engineTypeEvents(name[dot + 1:])
	}
	// A node type of the game's: its base kind's events and its own
	desc := ScriptCatalog_FindNodeType(&state.scripts, name)
	if desc == nil do return nil
	out := make([dynamic]e.NodeEventInfo, context.temp_allocator)
	for _, &f in state.scriptIndex.files do for &s in f.structs do if s.name == name {
		for field in s.fields do if strings.has_suffix(field.type, "EventSubject") {
			if description, tagged := reflect.struct_tag_lookup(reflect.Struct_Tag(field.tag), "event"); tagged {
				append(&out, e.NodeEventInfo{name = field.name, description = string(description), dataHint = string(reflect.struct_tag_get(reflect.Struct_Tag(field.tag), "data"))})
			}
		}
	}
	append(&out, ..e.SceneNodeKind_Events(desc.base))
	return out[:]
}

// An engine node type's events, by its name (`AnimatedSprite`; nil when it isn't one)
@(private="file")
engineTypeEvents :: proc(typeName: string) -> []e.NodeEventInfo {
	if typeName == "Node" do return e.SceneNodeKind_Events(.Node2D)
	for kind in NodeKind do if kind != .Component && NodeField_TypeName(kind) == typeName do return e.SceneNodeKind_Events(kind)
	return nil
}

/*
The handler procedure an event action writes (before the registration) and its subscription (in
ready).

Inputs:
- script: The struct
- name: The handler's name (`Hero_onDoorOpened`)
- whose: For the comment ("door", "its node")
- info: The event
*/
@(private="file")
handlerSource :: proc(code: ^CodeActionCode, script, name, whose: string, info: e.NodeEventInfo) -> (text: string, bodyLines: int) {
	b := strings.builder_make(context.temp_allocator)
	description := info.description != "" ? fmt.tprintf(": %s", info.description) : ""
	fmt.sbprintf(&b, "// %s's %s%s\n", whose, info.name, description)
	fmt.sbprintf(&b, "%s :: proc(_: ^e.EventSubject, source: rawptr, data: e.EventData, user: rawptr) {{\n", name)
	fmt.sbprintf(&b, "\tself := cast(^%s)user\n", script)
	bodyLines = 1
	if info.dataHint != "" {
		fmt.sbprintf(&b, "\t// %s\n", info.dataHint)
		bodyLines += 1
	}
	strings.write_string(&b, "}\n\n")
	return aliased(code, strings.to_string(b)), bodyLines
}

/*
The edits subscribing `call` in a registration's ready hook: before its closing brace, or a new
ready hook holding it.
*/
@(private="file")
readyEdit :: proc(code: ^CodeActionCode, reg: ^CodeActionRegistration, statement: string) -> (ce.Text_Edit, bool) {
	if !reg.hasHooks do return {}, false
	if ready := hookNamed(reg, "ready"); ready != nil {
		if ready.closeLine < 0 do return {}, false
		closing := code.lines[ready.closeLine]
		indent := tabsOf(closing)
		if strings.trim_space(closing[:ready.closeColumn]) != "" {
			// `ready = proc(self: ^Hero) {}`: the body opens on its own lines
			return ce.Text_Edit{start = {ready.closeLine, ready.closeColumn}, end = {ready.closeLine, ready.closeColumn},
				text = fmt.tprintf("\n%s\t%s\n%s", indent, statement, indent)}, true
		}
		return ce.Text_Edit{start = {ready.closeLine, 0}, end = {ready.closeLine, 0}, text = fmt.tprintf("%s\t%s\n", indent, statement)}, true
	}
	indent := tabsOf(code.lines[reg.line])
	hook := fmt.tprintf("%s\tready = proc(self: ^%s) {{\n%s\t\t%s\n%s\t},\n", indent, reg.name, indent, statement, indent)
	if reg.openLine == reg.closeLine {
		// `e.Script_Register(Hero, {})`
		return ce.Text_Edit{start = {reg.openLine, reg.openColumn + 1}, end = {reg.closeLine, reg.closeColumn}, text = fmt.tprintf("\n%s%s", hook, indent)}, true
	}
	return ce.Text_Edit{start = {reg.openLine + 1, 0}, end = {reg.openLine + 1, 0}, text = hook}, true
}

// The ready hook's parameter ("self" when there's no hook yet)
@(private="file")
readyParam :: proc(reg: ^CodeActionRegistration) -> string {
	if ready := hookNamed(reg, "ready"); ready != nil && ready.param != "" do return ready.param
	return "self"
}

// One "Handle <whose>'s <event>" action
@(private="file")
handlerAction :: proc(a: ^ActionCtx, s: ^CodeActionStruct, reg: ^CodeActionRegistration, whose, nameBase, subject, guard: string, info: e.NodeEventInfo) {
	code := a.code
	text := strings.join(code.lines, "\n", context.temp_allocator)
	// Already subscribed in code: not again
	if strings.contains(text, fmt.tprintf("&%s,", subject)) || strings.contains(text, fmt.tprintf("&%s)", subject)) do return
	name := uniqueDecl(a.state, code, a.path, fmt.tprintf("%s_%s", s.name, nameBase))
	param := readyParam(reg)
	call := fmt.tprintf("e.Event_Subscribe(&%s, %s, %s)", subject, name, param)
	statement := aliased(code, guard != "" ? fmt.tprintf("if %s do %s", guard, call) : call)
	sub, ok := readyEdit(code, reg, statement)
	if !ok do return
	handler, bodyLines := handlerSource(code, s.name, name, whose, info)
	edits := make([]ce.Text_Edit, 2, context.temp_allocator)
	edits[0] = {start = {reg.declLine, 0}, end = {reg.declLine, 0}, text = handler}
	edits[1] = sub
	// The caret: the end of the handler's last body line
	last := strings.split_lines(handler, context.temp_allocator)[1 + bodyLines]
	append(a.out, ce.Provider_Action{
		title = fmt.tprintf("Handle %s's %s", whose, info.name),
		edits = edits,
		caret = cebuf.Position{reg.declLine + 1 + bodyLines, len(last)},
		preview = fmt.tprintf("%s\n// in ready:\n%s", strings.trim_right(handler, "\n"), statement),
	})
}

// Handle an event: of a node field's node, or of the node the script runs on (its struct's line,
// its registration)
@(private="file")
handlerActions :: proc(a: ^ActionCtx) {
	code := a.code
	line := code.lines[a.pos.line]
	s := structAt(code, a.pos.line)
	field: ^CodeActionField
	if s != nil {
		field = fieldOn(s, a.pos.line)
	} else if p := procAt(code, a.pos.line); p != nil && p.selfType != "" {
		// `self.door` in one of the script's procedures
		word, receiver := memberAt(line, a.pos.col)
		if receiver == p.selfName {
			s = structNamed(code, p.selfType)
			field = fieldNamed(s, word)
		}
	}
	ownLine := false
	if s == nil {
		// On a registration: its struct
		for &r in code.registrations do if r.line == a.pos.line {
			s = structNamed(code, r.name)
			ownLine = true
		}
	}
	if s == nil do return
	reg := registrationOf(code, s.name)
	if reg == nil || reg.kind == .Data do return
	p := readyParam(reg)
	if field != nil && !field.isUsing {
		for info in fieldEvents(a.state, code, field.type) {
			short := strings.trim_prefix(Event_ShortName(info.name), "on")
			base := fmt.tprintf("on%s%s", upperFirst(NodeField_Name(field.name, nil)), upperFirst(short))
			handlerAction(a, s, reg, field.name, base, fmt.tprintf("%s.%s.%s", p, field.name, info.name), fmt.tprintf("%s.%s != nil", p, field.name), info)
		}
		return
	}
	if !ownLine && a.pos.line != s.line && (field == nil || !field.isUsing) do return
	// The node it runs on: a node type's own, or the one kind every node running the script is
	if reg.kind == .NodeType {
		desc := ScriptCatalog_FindNodeType(&a.state.scripts, s.name)
		if desc == nil do return
		for info in fieldEvents(a.state, code, fmt.tprintf("^%s", s.name)) {
			handlerAction(a, s, reg, "its node", Event_ShortName(info.name), fmt.tprintf("%s.%s", p, info.name), "", info)
		}
		return
	}
	kind: Maybe(NodeKind)
	for u in scriptUsers(a.state, s.name) {
		if u.node < 0 do continue
		k := NodeDef_BuiltKind(&a.state.project, &a.state.project.scenes[u.scene].nodes[u.node])
		if had, ok := kind.?; ok && had != k do return
		kind = k
	}
	k, known := kind.?
	if !known do return
	typeName := k == .Node2D ? "Node" : NodeField_TypeName(k)
	for info in e.SceneNodeKind_Events(k) {
		subject := fmt.tprintf("(cast(^e.%s)%s.node).%s", typeName, p, info.name)
		guard := fmt.tprintf("e.Node_Is(%s.node, e.%s)", p, typeName)
		if typeName == "Node" do subject, guard = fmt.tprintf("%s.node.%s", p, info.name), ""
		handlerAction(a, s, reg, fmt.tprintf("its %s", typeName), Event_ShortName(info.name), subject, guard, info)
	}
}

@(private="file")
upperFirst :: proc(s: string) -> string {
	if s == "" || s[0] < 'a' || s[0] > 'z' do return s
	return fmt.tprintf("%c%s", s[0] - 32, s[1:])
}

// --- exporting fields ------------------------------------------------------------------------

// How the inspector edits a field's type (the index's rules), and whether it's a number
@(private="file")
FieldExport :: enum {
	None,
	Float,
	Int,
	Bool,
	String,
	Vector2,
	Color,
	Enum,
	Asset,
	Node,
}

@(private="file")
exportKindOf :: proc(state: ^State, code: ^CodeActionCode, type: string) -> (FieldExport, string) {
	short := type
	if dot := strings.last_index_byte(type, '.'); dot >= 0 do short = type[dot + 1:]
	switch {
	case type == "f32" || type == "f64": return .Float, ""
	case type == "int" || type == "i32": return .Int, ""
	case type == "bool": return .Bool, ""
	case type == "string": return .String, ""
	case type == "[2]f32": return .Vector2, ""
	case strings.has_prefix(type, "^"):
		if strings.contains(type, "[") do return .None, ""
		if fieldEvents(state, code, type) != nil || engineNodeTypeName(short) do return .Node, short
		return .None, ""
	case strings.contains(type, ".") && short == "Color": return .Color, ""
	case strings.contains(type, ".") && (short == "TextureAsset" || short == "SoundAsset" || short == "FontAsset" || short == "DataAsset" || short == "ComponentAsset" || short == "MusicAsset"): return .Asset, ""
	}
	for _, &f in state.scriptIndex.files do for en in f.enums do if en.name == type {
		return .Enum, len(en.values) > 0 ? en.values[0] : ""
	}
	return .None, ""
}

// A tag without one key (`json:"x" export:"..."` without export; trimmed)
@(private="file")
tagWithout :: proc(tag, key: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := tag
	for len(rest) > 0 {
		rest = strings.trim_left_space(rest)
		colon := strings.index_byte(rest, ':')
		if colon < 0 || colon + 1 >= len(rest) || rest[colon + 1] != '"' {
			strings.write_string(&b, rest)
			break
		}
		end := strings.index_byte(rest[colon + 2:], '"')
		if end < 0 {
			strings.write_string(&b, rest)
			break
		}
		part := rest[:colon + 3 + end]
		if rest[:colon] != key {
			if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
			strings.write_string(&b, part)
		}
		rest = rest[len(part):]
	}
	return strings.trim_space(strings.to_string(b))
}

/*
The edit giving a field's tag an `export` key with these options (replacing its export key, the
tag's other keys kept), or, with `options` nil, removing the export key (and the tag, when it had
nothing else).
*/
@(private="file")
exportEdit :: proc(f: ^CodeActionField, options: Maybe(string)) -> (ce.Text_Edit, bool) {
	opts, set := options.?
	if f.tagStart < 0 {
		if !set || f.typeEnd < 0 do return {}, false
		return ce.Text_Edit{start = {f.line, f.typeEnd}, end = {f.line, f.typeEnd}, text = fmt.tprintf(" `export:\"%s\"`", opts)}, true
	}
	kept := tagWithout(f.tag, "export")
	if !set {
		if kept == "" {
			from := f.typeEnd >= 0 && f.typeEnd <= f.tagStart ? f.typeEnd : f.tagStart
			return ce.Text_Edit{start = {f.line, from}, end = {f.line, f.tagEnd}, text = ""}, true
		}
		return ce.Text_Edit{start = {f.line, f.tagStart}, end = {f.line, f.tagEnd}, text = fmt.tprintf("`%s`", kept)}, true
	}
	tag := kept == "" ? fmt.tprintf("export:\"%s\"", opts) : fmt.tprintf("%s export:\"%s\"", kept, opts)
	return ce.Text_Edit{start = {f.line, f.tagStart}, end = {f.line, f.tagEnd}, text = fmt.tprintf("`%s`", tag)}, true
}

/*
A field's value as its struct's procedures first set it (`self.speed = 250`), as a `default=`
would write it ("" none: not a literal, or never set).
*/
@(private="file")
initialValue :: proc(code: ^CodeActionCode, structName, field: string, kind: FieldExport) -> string {
	for p in code.procs {
		if p.selfType != structName || p.selfName == "" do continue
		prefix := fmt.tprintf("%s.%s", p.selfName, field)
		for i in p.startLine ..= min(p.endLine, len(code.lines) - 1) {
			trimmed := strings.trim_space(code.lines[i])
			if !strings.has_prefix(trimmed, prefix) do continue
			rest := strings.trim_space(trimmed[len(prefix):])
			if !strings.has_prefix(rest, "=") || strings.has_prefix(rest, "==") do continue
			value := strings.trim_space(rest[1:])
			if comment := strings.index(value, "//"); comment >= 0 do value = strings.trim_space(value[:comment])
			#partial switch kind {
			case .Float, .Int:
				if _, ok := strconv.parse_f64(value); ok do return value
			case .Bool:
				if value == "true" || value == "false" do return value
			case .String:
				if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' {
					inner := value[1:len(value) - 1]
					if strings.index_any(inner, "\"`\\") < 0 do return inner
				}
			case .Vector2:
				if strings.has_prefix(value, "{") && strings.has_suffix(value, "}") {
					parts := strings.split(value[1:len(value) - 1], ",", context.temp_allocator)
					if len(parts) == 2 {
						x, okX := strconv.parse_f64(strings.trim_space(parts[0]))
						y, okY := strconv.parse_f64(strings.trim_space(parts[1]))
						if okX && okY do return fmt.tprintf("%v, %v", x, y)
					}
				}
			case .Enum:
				if strings.has_prefix(value, ".") do return value[1:]
			}
			return ""
		}
	}
	return ""
}

// A node field's default: the first node that fits, as a path from the first node running the script
@(private="file")
nodeDefault :: proc(state: ^State, script, typeName: string) -> string {
	for u in scriptUsers(state, script) {
		if u.node < 0 do continue
		choices := NodeField_Choices(&state.project, &state.project.scenes[u.scene], u.node, typeName)
		for c in choices do if c != "" && c != "." do return c
	}
	return ""
}

// The options of an exported number field's tag: its default, min and max ("" unset)
@(private="file")
exportOptions :: proc(tag: string) -> (defaultValue, lo, hi, others: string) {
	options := string(reflect.struct_tag_get(reflect.Struct_Tag(tag), "export"))
	b := strings.builder_make(context.temp_allocator)
	words := strings.fields(options, context.temp_allocator)
	for i := 0; i < len(words); i += 1 {
		key, _, value := strings.partition(words[i], "=")
		switch key {
		case "default":
			// A vector's "default=10, 20" goes on past its space
			for i + 1 < len(words) && !strings.contains(words[i + 1], "=") {
				i += 1
				value = fmt.tprintf("%s %s", value, words[i])
			}
			defaultValue = value
		case "min": lo = value
		case "max": hi = value
		case:
			if strings.builder_len(b) > 0 do strings.write_byte(&b, ' ')
			strings.write_string(&b, words[i])
		}
	}
	return defaultValue, lo, hi, strings.to_string(b)
}

/*
An exported number's options as written: `default=250 min=0 max=400` then the others it had.
*/
CodeActions_ExportOptions :: proc(defaultValue, lo, hi, others: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if defaultValue != "" do append(&parts, fmt.tprintf("default=%s", defaultValue))
	if lo != "" do append(&parts, fmt.tprintf("min=%s", lo))
	if hi != "" do append(&parts, fmt.tprintf("max=%s", hi))
	if others != "" do append(&parts, others)
	return strings.join(parts[:], " ", context.temp_allocator)
}

// Export a field, export it with a range, remove its export, set its range; show it in the inspector
@(private="file")
exportActions :: proc(a: ^ActionCtx) {
	code := a.code
	s := structAt(code, a.pos.line)
	f := fieldOn(s, a.pos.line)
	if f == nil || f.isUsing || strings.has_suffix(f.type, "EventSubject") do return
	if !registeredAnywhere(a.state, code, a.path, s.name) do return
	kind, hint := exportKindOf(a.state, code, f.type)
	_, exported := reflect.struct_tag_lookup(reflect.Struct_Tag(f.tag), "export")
	number := kind == .Float || kind == .Int
	lineText := code.lines[f.line]
	rangeRequest :: proc(a: ^ActionCtx, f: ^CodeActionField, lineText, defaultValue, lo, hi: string, whole: bool) -> int {
		return commandAdd(Code_Range_Requested{path = a.path, line = f.line, lineText = lineText, field = f.name, whole = whole, defaultValue = defaultValue, min = lo, max = hi})
	}
	if exported {
		if edit, ok := exportEdit(f, nil); ok {
			edits := make([]ce.Text_Edit, 1, context.temp_allocator)
			edits[0] = edit
			append(a.out, ce.Provider_Action{title = fmt.tprintf("Remove export from %s", f.name), edits = edits,
				preview = fmt.tprintf("%s (stored values stay, listed in the inspector)", f.name)})
		}
		if number {
			defaultValue, lo, hi, _ := exportOptions(f.tag)
			append(a.out, ce.Provider_Action{title = fmt.tprintf("Set %s's range...", f.name), id = rangeRequest(a, f, lineText, defaultValue, lo, hi, kind == .Int)})
		}
		// To the inspector: a node running the script, scrolled to the field
		if desc := ScriptCatalog_Find(&a.state.scripts, s.name); desc != nil {
			for field in desc.fields do if field.name == f.name {
				append(a.out, ce.Provider_Action{title = fmt.tprintf("Show %s in the inspector", f.name), id = commandAdd(Code_Field_Reveal_Requested{script = s.name, field = f.name})})
				break
			}
		}
		return
	}
	if kind == .None do return
	defaultValue := initialValue(code, s.name, f.name, kind)
	if defaultValue == "" {
		#partial switch kind {
		case .Float, .Int: defaultValue = "0"
		case .Bool:        defaultValue = "false"
		case .Vector2:     defaultValue = "0, 0"
		case .Color:       defaultValue = "#ffffff"
		case .Enum:        defaultValue = hint
		case .Node:        defaultValue = nodeDefault(a.state, s.name, hint)
		}
	}
	options := defaultValue != "" ? fmt.tprintf("default=%s", defaultValue) : ""
	if edit, ok := exportEdit(f, options); ok {
		edits := make([]ce.Text_Edit, 1, context.temp_allocator)
		edits[0] = edit
		after := fmt.tprintf("%s%s%s", lineText[:edit.start.col], edit.text, lineText[edit.end.col:])
		append(a.out, ce.Provider_Action{title = fmt.tprintf("Export %s", f.name), edits = edits, preview = strings.trim_space(after), preferred = true})
	}
	if number && f.typeEnd >= 0 {
		append(a.out, ce.Provider_Action{title = fmt.tprintf("Export %s with a range...", f.name), id = rangeRequest(a, f, lineText, defaultValue, "", "", kind == .Int)})
	}
}

// --- a switch over a state machine's states ------------------------------------------------

@(private="file")
stateSwitchActions :: proc(a: ^ActionCtx) {
	code := a.code
	p := procAt(code, a.pos.line)
	if p == nil || p.selfType == "" || p.selfName == "" || a.syntax.kind != .Proc_Body do return
	s := structNamed(code, p.selfType)
	if s == nil do return
	line := code.lines[a.pos.line]
	word, receiver := memberAt(line, a.pos.col)
	blank := strings.trim_space(line) == ""
	machineType := fmt.tprintf("^%s.StateMachine", code.engineAlias)
	for &f in s.fields {
		if f.type != machineType do continue
		if !(blank || word == f.name && receiver == p.selfName) do continue
		states := machineStates(a.state, s.name, f.name)
		if len(states) == 0 do continue
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "if %s.%s != nil {{\n\tswitch e.StateMachine_Current(%s.%s) {{\n", p.selfName, f.name, p.selfName, f.name)
		for st, i in states do fmt.sbprintf(&b, "\tcase %s:%s\n", st, i == 0 ? "{caret}" : "")
		strings.write_string(&b, "\t}\n}")
		statement := aliased(code, strings.to_string(b))
		edit, caret := CodeStatement_Edit(a.doc, a.pos, statement)
		edits := make([]ce.Text_Edit, 1, context.temp_allocator)
		edits[0] = edit
		preview, _ := strings.replace_all(statement, "{caret}", "", context.temp_allocator)
		append(a.out, ce.Provider_Action{title = fmt.tprintf("Insert a switch over %s's states (%d)", f.name, len(states)), edits = edits, caret = caret, preview = preview})
	}
}

/*
The states of the machine a script's field points to (the first node running the script whose
field leads to one): their STATE_ constants, else their names quoted (temp allocated).
*/
@(private="file")
machineStates :: proc(state: ^State, script, field: string) -> []string {
	constants := CodeProviders_Constants(state)
	for ref in CodeNames_FieldNodes(state, script, field) {
		scene := &state.project.scenes[ref.scene]
		node := &scene.nodes[ref.node]
		if node.kind != .StateMachine || len(node.stateMachine.states) == 0 do continue
		label := Scene_IsComponent(scene) ? fmt.tprintf("component %s", ComponentName(scene.component)) : fmt.tprintf("scene %s", scene.name)
		group := fmt.tprintf("%s in %s", node.name, label)
		out := make([dynamic]string, context.temp_allocator)
		for st in node.stateMachine.states {
			name := fmt.tprintf("%q", st.name)
			for c in constants do if c.section == .States && strings.has_prefix(c.name, "STATE_") && c.group == group && c.value == name {
				name = c.name
				break
			}
			append(&out, name)
		}
		return out[:]
	}
	return nil
}

// --- registering a struct ------------------------------------------------------------------

@(private="file")
registerActions :: proc(a: ^ActionCtx) {
	code := a.code
	s := structAt(code, a.pos.line)
	if s == nil || s.embeds == "" || registeredAnywhere(a.state, code, a.path, s.name) do return
	alias, _, typeName := strings.partition(s.embeds, ".")
	if alias != code.engineAlias || typeName == "" do return
	base := ""
	if typeName != "Script" {
		for kind in NodeKind do if kind != .Component && kind != .Node2D && NodeField_TypeName(kind) == typeName do base = fmt.tprint(kind)
		if base == "" do return
	}
	procName := uniqueDecl(a.state, code, a.path, fmt.tprintf("register_%s", s.name))
	source := aliased(code, ScriptTemplate_Registration(s.name, base, procName))
	edits := make([dynamic]ce.Text_Edit, context.temp_allocator)
	added := 0
	if edit, needed := sdlImportEdit(code); needed {
		append(&edits, edit)
		added = 1
	}
	at := s.closeLine + 1
	if at < len(code.lines) {
		append(&edits, ce.Text_Edit{start = {at, 0}, end = {at, 0}, text = fmt.tprintf("\n%s", source)})
	} else {
		// The struct ends the file (no line break after its brace): after the brace
		end := len(code.lines[s.closeLine])
		append(&edits, ce.Text_Edit{start = {s.closeLine, end}, end = {s.closeLine, end}, text = fmt.tprintf("\n\n%s", strings.trim_right(source, "\n"))})
	}
	// The caret: the end of the ready hook's line
	lines := strings.split_lines(source, context.temp_allocator)
	readyAt := 0
	for l, i in lines do if strings.contains(l, "ready = proc") do readyAt = i
	title := base == "" ? fmt.tprintf("Register %s as a script", s.name) : fmt.tprintf("Register %s as a node type (%s)", s.name, base)
	append(a.out, ce.Provider_Action{title = title, edits = edits[:], caret = cebuf.Position{at + 1 + readyAt + added, len(lines[readyAt])}, preview = strings.trim_right(source, "\n")})
}

// --- hooks -----------------------------------------------------------------------------------

// A hook's parameters after self (`events: []sdl.Event, dt: f64`), as ScriptHooks declares them
@(private="file")
HOOK_PARAMS := [?][2]string{
	{"ready", ""},
	{"update", ", events: []sdl.Event, dt: f64"},
	{"draw", ", renderer: ^sdl.Renderer"},
	{"destroy", ""},
	{"collisionEnter", ", collision: ^e.Collision"},
	{"collisionExit", ", collision: ^e.Collision"},
	{"areaEnter", ", collision: ^e.Collision"},
	{"areaExit", ", collision: ^e.Collision"},
	{"sceneChanged", ", scene: ^e.Scene"},
	{"loaded", ""},
}

// What each hook is for (the comment above it)
@(private="file")
HOOK_COMMENTS := [?]string{
	"Once, when the scene starts: every node exists",
	"Every frame, after the node's own update",
	"After the node draws, in its local space",
	"When the node is freed",
	"Another body started touching this one (or entered this Area)",
	"Another body stopped touching this one (or left this Area)",
	"This body entered an Area (collision.other)",
	"This body left an Area (collision.other)",
	"The game switched scenes (a global's)",
	"Load_Game restored the fields (a global's)",
}

@(private="file")
hookActions :: proc(a: ^ActionCtx) {
	code := a.code
	reg: ^CodeActionRegistration
	for &r in code.registrations do if r.hasHooks && r.kind != .Data && r.line <= a.pos.line && a.pos.line <= r.closeLine do reg = &r
	if reg == nil do return
	if h := hookAt(reg, a.pos.line); h != nil && a.pos.line != h.line do return
	// Which hooks apply: physics ones for bodies, a global's for globals
	body, global := false, false
	bodies := bit_set[NodeKind]{.StaticBody, .DynamicBody, .CharacterMover, .Area}
	if reg.kind == .NodeType {
		for kind in NodeKind do if fmt.tprint(kind) == reg.base && kind in bodies do body = true
	} else {
		for u in scriptUsers(a.state, reg.name) {
			if u.node < 0 do global = true
			else if NodeDef_BuiltKind(&a.state.project, &a.state.project.scenes[u.scene].nodes[u.node]) in bodies do body = true
		}
	}
	indent := tabsOf(code.lines[reg.line])
	sdlEdit, needsSdl := sdlImportEdit(code)
	for hp, i in HOOK_PARAMS {
		name := hp[0]
		if hookNamed(reg, name) != nil do continue
		if i >= 4 && i <= 7 && !body do continue
		if i >= 8 && !global do continue
		hook := aliased(code, fmt.tprintf("%s\t// %s\n%s\t%s = proc(self: ^%s%s) {{\n%s\t}},\n", indent, HOOK_COMMENTS[i], indent, name, reg.name, hp[1], indent))
		edits := make([dynamic]ce.Text_Edit, context.temp_allocator)
		usesSdl := strings.contains(hp[1], "sdl.")
		if usesSdl && needsSdl do append(&edits, sdlEdit)
		shift := usesSdl && needsSdl ? 1 : 0
		at: cebuf.Position
		if reg.openLine == reg.closeLine {
			append(&edits, ce.Text_Edit{start = {reg.openLine, reg.openColumn + 1}, end = {reg.closeLine, reg.closeColumn}, text = fmt.tprintf("\n%s%s", hook, indent)})
			at = {reg.openLine + 2 + shift, 0}
		} else if strings.trim_space(code.lines[reg.closeLine][:reg.closeColumn]) == "" {
			append(&edits, ce.Text_Edit{start = {reg.closeLine, 0}, end = {reg.closeLine, 0}, text = hook})
			at = {reg.closeLine + 1 + shift, 0}
		} else {
			// `}` after the last hook on its line: a line of its own first
			append(&edits, ce.Text_Edit{start = {reg.closeLine, reg.closeColumn}, end = {reg.closeLine, reg.closeColumn}, text = fmt.tprintf("\n%s%s", hook, indent)})
			at = {reg.closeLine + 2 + shift, 0}
		}
		hookLines := strings.split_lines(hook, context.temp_allocator)
		append(a.out, ce.Provider_Action{title = fmt.tprintf("Add the %s hook", name), edits = edits[:], caret = cebuf.Position{at.line, len(hookLines[1])}, preview = strings.trim_right(hook, "\n")})
	}
}

// --- the Range dialog ------------------------------------------------------------------------

// Open the Range dialog for an exported (or to be exported) number field (strings cloned in update)
Code_Range_Requested :: struct {
	// The code tab, the field's line (0-based) and its text then (checked again on OK)
	path: string,
	line: int,
	lineText: string,
	field: string,
	// An int: whole numbers only
	whole: bool,
	min, max, defaultValue: string,
}

// One of the dialog's fields typed (0 min, 1 max, 2 default)
Code_Range_Field_Changed :: struct {
	which: int,
	text: string,
}
Code_Range_Applied :: struct {}
Code_Range_Cancelled :: struct {}

// Show a script's field in the inspector: a node running it selected, the inspector scrolled to it
Code_Field_Reveal_Requested :: struct {
	script, field: string,
}

// A script field's label in the inspector: its declaration in a code tab
Script_Field_Declaration_Requested :: struct {
	script, field: string,
}

// The Range dialog (State.codeRange; strings owned)
CodeRangeDialog :: struct {
	open: bool,
	request: Code_Range_Requested,
	// Why OK can't write it ("" it can)
	problem: string,
}

// Frees the dialog's strings
CodeRangeDialog_Destroy :: proc(d: ^CodeRangeDialog) {
	commandFree(d.request)
	delete(d.problem)
	d^ = {}
}

/*
Why the dialog's values can't be written ("" when they can): numbers (whole ones for an int),
min not over max, the default inside them.
*/
CodeRange_Problem :: proc(r: Code_Range_Requested) -> string {
	values: [3]Maybe(f64)
	texts := [3]string{r.min, r.max, r.defaultValue}
	names := [3]string{"Min", "Max", "Default"}
	for text, i in texts {
		t := strings.trim_space(text)
		if t == "" do continue
		v, ok := strconv.parse_f64(t)
		if !ok do return fmt.tprintf("%s isn't a number", names[i])
		if r.whole && v != f64(int(v)) do return fmt.tprintf("%s must be a whole number (%s is an int)", names[i], r.field)
		values[i] = v
	}
	lo, hasLo := values[0].?
	hi, hasHi := values[1].?
	d, hasD := values[2].?
	if hasLo && hasHi && lo > hi do return "Min is over Max"
	if hasD && (hasLo && d < lo || hasHi && d > hi) do return "The default is outside the range"
	return ""
}

/*
Writes the dialog's range into the field's tag in its code tab: one edit (one undo step there),
only when the field's line is still as it was.

Returns:
- "" or why it wasn't written (temp allocated)
*/
CodeRange_Write :: proc(r: Code_Range_Requested) -> string {
	text, version, _ := CodeEditor_Buffer(r.path, true)
	if version < 0 do return "The code tab with the field isn't open"
	code := CodeActions_Read(r.path, text)
	if r.line >= len(code.lines) || code.lines[r.line] != r.lineText do return fmt.tprintf("%s's line changed in the code meanwhile: nothing was written", r.field)
	f := fieldOn(structAt(&code, r.line), r.line)
	if f == nil || f.name != r.field do return fmt.tprintf("%s isn't on its line any more: nothing was written", r.field)
	_, _, _, others := exportOptions(f.tag)
	edit, ok := exportEdit(f, CodeActions_ExportOptions(strings.trim_space(r.defaultValue), strings.trim_space(r.min), strings.trim_space(r.max), others))
	if !ok do return fmt.tprintf("%s's tag can't be written here", r.field)
	if !CodeEditor_ApplyEdits(r.path, {edit}) do return "The code tab with the field isn't open"
	return ""
}

/*
The code actions' messages: the Range dialog (opened by an action, edited, OK writing the tag),
showing a field in the inspector, a field's declaration from the inspector.

Returns:
- A command, and whether `m` was one of them
*/
CodeActions_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	d := &state.codeRange
	#partial switch v in m {
	case Code_Range_Requested:
		CodeRangeDialog_Destroy(d)
		d.open = true
		d.request = commandClone(v).(Code_Range_Requested)
		return {}, true
	case Code_Range_Field_Changed:
		target := [3]^string{&d.request.min, &d.request.max, &d.request.defaultValue}
		if v.which < 0 || v.which > 2 do return {}, true
		delete(target[v.which]^)
		target[v.which]^ = strings.clone(v.text)
		delete(d.problem)
		d.problem = ""
		return {}, true
	case Code_Range_Cancelled:
		CodeRangeDialog_Destroy(d)
		return {}, true
	case Code_Range_Applied:
		if problem := CodeRange_Problem(d.request); problem != "" {
			delete(d.problem)
			d.problem = strings.clone(problem)
			return {}, true
		}
		message := CodeRange_Write(d.request)
		logLine(state, message == "" ? .Info : .Warning, strings.clone(message == "" ? fmt.tprintf("%s's range written", d.request.field) : message))
		CodeRangeDialog_Destroy(d)
		return {}, true
	case Code_Field_Reveal_Requested:
		logLine(state, .Info, strings.clone(CodeActions_Reveal(state, v.script, v.field)))
		return {}, true
	case Script_Field_Declaration_Requested:
		path, line, column, found := ScriptField_Declaration(state, v.script, v.field)
		if !found {
			logLine(state, .Warning, fmt.aprintf("No declaration of %s.%s in the scripts", v.script, v.field))
			return {}, true
		}
		return Script_Open(state, path, line, column), true
	}
	return {}, false
}

/*
Shows a script's field in the inspector: selects a node running the script (the selected node
when it does, else the open scene's first, else the first of any scene: its tab opens) and
scrolls the inspector to the field's row (`Inspector_RevealWidget`).

Returns:
- What happened, for the Console (temp allocated)
*/
CodeActions_Reveal :: proc(state: ^State, script, field: string) -> string {
	best := ScriptUser{-1, -1}
	runs :: proc(node: ^NodeDef, script: string) -> bool { return node.script == script }
	if state.selectedNode >= 0 && state.currentScene < len(state.project.scenes) {
		scene := &state.project.scenes[state.currentScene]
		if state.selectedNode < len(scene.nodes) && runs(&scene.nodes[state.selectedNode], script) do best = {state.currentScene, state.selectedNode}
	}
	if best.node < 0 {
		for u in scriptUsers(state, script) {
			if u.node < 0 || !runs(&state.project.scenes[u.scene].nodes[u.node], script) do continue
			if best.node < 0 || u.scene == state.currentScene && best.scene != state.currentScene do best = u
		}
	}
	if best.node < 0 {
		for g in state.project.globals do if g.script == script {
			ProjectSettings_Open(state, .Globals)
			return fmt.tprintf("%s is a global: its fields are in Project Settings > Globals", script)
		}
		return fmt.tprintf("No node runs %s as its script yet: attach it in a node's inspector", script)
	}
	ScriptLinks_Open(state, {kind = .Node, scene = best.scene, node = best.node})
	Inspector_RevealWidget(Inspector_ScriptFieldKey(field, best.node))
	return fmt.tprintf("%s's %s in the inspector (%s)", script, field, state.project.scenes[best.scene].nodes[best.node].name)
}

// The key of a script field's label in the inspector (`inspector-label-<field>-<node>`)
Inspector_ScriptFieldKey :: proc(field: string, node: int) -> string {
	spaced, _ := strings.replace_all(field, " ", "_", context.temp_allocator)
	return fmt.tprintf("inspector-label-%s-%d", spaced, node)
}

/*
Where a script's field is declared: the file the index read its struct from, the field's line and
column (1-based).
*/
ScriptField_Declaration :: proc(state: ^State, script, field: string) -> (path: string, line, column: int, found: bool) {
	for file, &f in state.scriptIndex.files do for &s in f.structs do if s.name == script {
		for fl in s.fields do if fl.name == field do return file, fl.line, fl.column + 1, true
	}
	return "", 0, 0, false
}

/*
The Range dialog: Min (`code-range-min`), Max (`code-range-max`), Default (`code-range-default`),
the tag it writes, OK (`code-range-ok`) and Cancel (`code-range-cancel`).
*/
CodeRangeDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	if !s.codeRange.open do return closedDialog(ctx, "code-range-dialog")
	th := ctx.theme
	r := &s.codeRange.request
	row :: proc(ctx: ^skald.Ctx(Msg), label, value, key: string, which: int) -> skald.View {
		th := ctx.theme
		on: proc(which: int, text: string) -> Msg = proc(which: int, text: string) -> Msg { return Code_Range_Field_Changed{which, text} }
		return skald.row(
			skald.col(skald.text(label, th.color.fg, th.font.size_sm), width = 70),
			skald.text_input(ctx, value, which, on, id = skald.hash_id(key), width = 160),
			spacing = th.spacing.sm, cross_align = .Center)
	}
	problem := s.codeRange.problem != "" ? s.codeRange.problem : CodeRange_Problem(r^)
	_, _, _, others := exportOptions(r.lineText[strings.index_byte(r.lineText, '`') + 1:] if strings.index_byte(r.lineText, '`') >= 0 else "")
	writes := fmt.tprintf("export:\"%s\"", CodeActions_ExportOptions(strings.trim_space(r.defaultValue), strings.trim_space(r.min), strings.trim_space(r.max), others))
	return skald.dialog(ctx,
		open = true,
		on_dismiss = proc() -> Msg { return Code_Range_Cancelled{} },
		content = skald.col(
			skald.text(fmt.tprintf("Range of %s", r.field), th.color.fg, th.font.size_lg),
			skald.text(fmt.tprintf("The inspector keeps it between Min and Max (empty: no limit)%s.", r.whole ? "; whole numbers" : ""), th.color.fg_muted, th.font.size_xs, max_width = 340),
			row(ctx, "Min", r.min, "code-range-min", 0),
			row(ctx, "Max", r.max, "code-range-max", 1),
			row(ctx, "Default", r.defaultValue, "code-range-default", 2),
			skald.text(problem != "" ? problem : fmt.tprintf("Writes %s", writes), problem != "" ? th.color.danger : th.color.fg_muted, th.font.size_xs, max_width = 340),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(Code_Range_Cancelled{}), id = skald.hash_id("code-range-cancel"), bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, "OK", Msg(Code_Range_Applied{}), id = skald.hash_id("code-range-ok"), font_size = th.font.size_sm),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("code-range-dialog"),
		width = 380,
	)
}
