package crossfire_editor

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import vmem "core:mem/virtual"
import "gui:skald"
import e "engine:."

/*
The script index: what the project's scripts declare, read from their source with
`core:odin/parser`, without building them. The build's catalog (`--describe-scripts`,
scripts.odin) says exactly what the compiler saw, but only after a build; the index knows as
soon as a file is saved or typed in a code tab:

- each script registered with `Script_Register(Name, ...)`, its struct, and its exported fields
  (type, `default=` / `min=` / `max=` / `kind=`, the comment above it) and events (`EventSubject`
  fields tagged `event:"..."`, as the engine's `NodeType_Events` reads them)
- data types (`Data_Register`), node types (`NodeType_Register`, with their base kind) and which
  scripts the project runs as globals
- problems the build only finds at run time: a field that can't be exported, a tag option that
  isn't one, a min / max that isn't a number
- every engine call's string literal arguments (`e.Game_ChangeScene(game, "Forest")`: the
  procedure, the argument's position or name, its first argument as written) and every
  procedure's lines and first parameter's type, for the name providers (code_names.odin)

**When it runs:** `ScriptIndex_Tick` (every SCRIPT_INDEX_TICK seconds while a project is open)
looks at the scripts folder's files and the code tabs' buffers; a file whose modification time
changed, or a buffer whose text changed and has then been still for a tick, is parsed again
(only those: about 1 ms a file) on a worker (`skald.cmd_thread`), so the UI never waits. The
result (`ScriptIndex_Parsed`) replaces those files' entries. A file that doesn't parse keeps its
last good declarations (half-typed code doesn't make fields disappear), with its error count.

**The catalog stays authoritative** (`ScriptIndex_Apply`): `State.scripts` is the build's
catalog (kept as `ScriptIndex.built`) with the index's description of every script whose file
changed since that build (saved after it, or unsaved in a code tab), and of those the build
doesn't know; those carry `ScriptDesc.fromIndex` (the inspector says so). Before any build, the
index describes them all (the catalog's status stays Unknown).
*/

// How often the index looks for changed script files and buffers (seconds)
SCRIPT_INDEX_TICK :: 0.5

// What the index knows about the project's scripts (State.scriptIndex)
ScriptIndex :: struct {
	// Each .odin file of scripts/, by absolute path
	files: map[string]IndexFile,
	// What the files describe, as the catalog does (fromIndex set; owned)
	scripts, dataTypes, nodeTypes: [dynamic]ScriptDesc,
	// Exported fields' and tags' problems, by file
	problems: [dynamic]IndexProblem,
	// The scripts folder it indexes (absolute, owned)
	folder: string,
	// A parse is running on the worker / files changed meanwhile
	running, again: bool,
	// Bumped whenever what it describes changes (providers and the inspector follow)
	generation: int,
	// The tick is scheduled
	ticking: bool,
	// Code tab buffers: the version last seen and when, and the version last parsed (by path)
	buffers: map[string]IndexBufferState,
	// The build's own catalog (a copy: `State.scripts` is it merged with the index), and the
	// newest script source when that build started
	built: ScriptCatalog,
	hasBuilt: bool,
	builtFrom: time.Time,
	// Timing: the last run's files and time (the worker's), and the first full index's
	lastFiles: int,
	lastTime: time.Duration,
	fullTime: time.Duration,
}

// A code tab's buffer as the index follows it
IndexBufferState :: struct {
	seenVersion: int,
	seenAt: time.Tick,
	parsedVersion: int,
}

// One file's declarations (owned)
IndexFile :: struct {
	path: string,
	// Its modification time when read from disk; from a code tab: the buffer's version (else -1)
	modTime: time.Time,
	bufferVersion: int,
	hash: u64,
	// Parse errors in this version (its declarations may be the last good version's)
	errors: int,
	structs: [dynamic]IndexStruct,
	enums: [dynamic]IndexEnum,
	registrations: [dynamic]IndexRegistration,
	// The name the engine is imported as ("e"; "" when it isn't imported)
	engineAlias: string,
	// The engine calls' string literal arguments, and the procedures (their lines)
	calls: [dynamic]IndexCall,
	procs: [dynamic]IndexProc,
}

// A string literal passed to an engine procedure: `e.Scene_GetGroup(self.scene, "enemies")`
IndexCall :: struct {
	// The procedure, without the package (`Scene_GetGroup`)
	procName: string,
	// The argument's position among the positional ones, or its name (`bus = "SFX"`; else "")
	argument: int,
	argName: string,
	// The literal's text without its quotes
	value: string,
	// 1-based line, 0-based byte columns of the literal, quotes included; its line's text
	line, column, endColumn: int,
	lineText: string,
	// The call's first argument as written, spaces removed (`self.scene`, `&sprite.animation`)
	receiver: string,
	// The type of the first parameter of the procedure it's in, a pointer's (`Hero` for
	// `self: ^Hero`; "" none)
	selfType: string,
}

// A procedure (declared or a literal): its lines (1-based, inclusive) and its first parameter's
// type when that's a pointer to a named type (`Hero` for `proc(self: ^Hero)`)
IndexProc :: struct {
	startLine, endLine: int,
	selfType: string,
}

// A struct declared in a file
IndexStruct :: struct {
	name: string,
	line: int,
	// The first field's type when it's `using` (`e.Script`, `e.Sprite`; "" otherwise)
	embeds: string,
	fields: [dynamic]IndexField,
}

// A struct field as written
IndexField :: struct {
	name: string,
	// Its type as written, without spaces (`f32`, `^e.Camera2D`, `[2]f32`)
	type: string,
	// The tag's text inside the backquotes ("" for none)
	tag: string,
	// The comment above it (or after it)
	comment: string,
	isUsing: bool,
	// 1-based line, 0-based byte column of its name; its line's text (relocating problems)
	line, column: int,
	lineText: string,
}

IndexEnum :: struct {
	name: string,
	values: [dynamic]string,
}

IndexRegistrationKind :: enum {
	Script,
	Data,
	NodeType,
}

// A `Script_Register(T, ...)`, `Data_Register(T)` or `NodeType_Register(T, .Base, ...)` call
IndexRegistration :: struct {
	kind: IndexRegistrationKind,
	name: string,
	// A node type's base kind (`Sprite`)
	base: string,
	// 1-based line and 0-based byte column of the call; its line's text
	line, column: int,
	lineText: string,
}

// A problem in a script file the index found
IndexProblem :: struct {
	path: string,
	// 1-based line, 0-based byte columns
	line, column, endColumn: int,
	lineText: string,
	message: string,
	warning: bool,
}

// A file to index: its text (owned by the job), where it came from
IndexSource :: struct {
	path: string,
	text: string,
	modTime: time.Time,
	bufferVersion: int,
}

// The index's tick (State.scriptIndex.ticking)
ScriptIndex_Tick :: struct {}

// The worker's answer: the files it parsed (owned) and how long it took
ScriptIndex_Parsed :: struct {
	folder: string,
	files: []IndexFile,
	took: time.Duration,
}

/*
Reads one script file's declarations with core:odin/parser. Pure (no editor state), so it runs
on the worker and in tests.

Inputs:
- path: The file (its absolute path)
- text: Its source
- allocator: For the result

Returns:
- What it declares (owned by `allocator`); `errors` > 0 when it doesn't parse cleanly (what the
  parser recovered is still there)
*/
ScriptIndex_ParseSource :: proc(path, text: string, allocator := context.allocator) -> IndexFile {
	out := IndexFile{path = strings.clone(path, allocator), bufferVersion = -1, hash = hash.fnv64a(transmute([]u8)text)}
	out.structs = make([dynamic]IndexStruct, allocator)
	out.enums = make([dynamic]IndexEnum, allocator)
	out.registrations = make([dynamic]IndexRegistration, allocator)
	out.calls = make([dynamic]IndexCall, allocator)
	out.procs = make([dynamic]IndexProc, allocator)

	// The AST lives in an arena, freed after
	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil do return out
	defer vmem.arena_destroy(&arena)
	result := allocator
	context.allocator = vmem.arena_allocator(&arena)

	file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
	file.src = text
	file.fullpath = path
	p := parser.default_parser()
	p.err = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
	parser.parse_file(&p, file)
	out.errors = p.error_count

	lineText :: proc(src: string, offset: int) -> string {
		start := offset
		for start > 0 && src[start - 1] != '\n' do start -= 1
		end := offset
		for end < len(src) && src[end] != '\n' && src[end] != '\r' do end += 1
		return src[start:end]
	}
	sourceOf :: proc(src: string, node: ^ast.Node) -> string {
		return src[clamp(node.pos.offset, 0, len(src)):clamp(node.end.offset, 0, len(src))]
	}
	compact :: proc(text: string, allocator: runtime.Allocator) -> string {
		b := strings.builder_make(allocator)
		for r in text do if r != ' ' && r != '\t' && r != '\n' && r != '\r' do strings.write_rune(&b, r)
		return strings.to_string(b)
	}

	for decl in file.decls {
		vd, isValue := decl.derived.(^ast.Value_Decl)
		if !isValue || vd.is_mutable || len(vd.names) != 1 || len(vd.values) != 1 do continue
		ident, isIdent := vd.names[0].derived.(^ast.Ident)
		if !isIdent do continue
		#partial switch v in vd.values[0].derived {
		case ^ast.Struct_Type:
			st := IndexStruct{name = strings.clone(ident.name, result), line = ident.pos.line}
			st.fields = make([dynamic]IndexField, result)
			if v.fields != nil {
				for f, fi in v.fields.list {
					type := f.type != nil ? compact(sourceOf(text, f.type), result) : ""
					tag := ""
					if f.tag.text != "" do tag = strings.trim(f.tag.text, "`")
					comment := ""
					if f.docs != nil do comment = indexCommentText(f.docs, result)
					else if f.comment != nil do comment = indexCommentText(f.comment, result)
					isUsing := .Using in f.flags
					if fi == 0 && isUsing do st.embeds = strings.clone(type, result)
					for name in f.names {
						nameIdent, ok := name.derived.(^ast.Ident)
						if !ok do continue
						append(&st.fields, IndexField{
							name = strings.clone(nameIdent.name, result),
							type = strings.clone(type, result),
							tag = strings.clone(tag, result),
							comment = strings.clone(comment, result),
							isUsing = isUsing,
							line = nameIdent.pos.line,
							column = nameIdent.pos.column - 1,
							lineText = strings.clone(lineText(text, nameIdent.pos.offset), result),
						})
					}
					delete(type, result)
					delete(comment, result)
				}
			}
			append(&out.structs, st)
		case ^ast.Enum_Type:
			en := IndexEnum{name = strings.clone(ident.name, result)}
			en.values = make([dynamic]string, result)
			for f in v.fields {
				#partial switch fv in f.derived {
				case ^ast.Ident: append(&en.values, strings.clone(fv.name, result))
				case ^ast.Field_Value:
					if fi, ok := fv.field.derived.(^ast.Ident); ok do append(&en.values, strings.clone(fi.name, result))
				}
			}
			append(&out.enums, en)
		}
	}

	// Registrations: calls anywhere (the @(init) procedures' bodies)
	Walk :: struct {
		out: ^IndexFile,
		src: string,
		result: runtime.Allocator,
	}
	w := Walk{&out, text, result}
	visitor := ast.Visitor{data = &w, visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil do return nil
		call, isCall := node.derived.(^ast.Call_Expr)
		if !isCall || len(call.args) == 0 do return v
		w := (^Walk)(v.data)
		callee := ""
		#partial switch c in call.expr.derived {
		case ^ast.Selector_Expr: if c.field != nil do callee = c.field.name
		case ^ast.Ident: callee = c.name
		}
		kind: IndexRegistrationKind
		switch callee {
		case "Script_Register": kind = .Script
		case "Data_Register": kind = .Data
		case "NodeType_Register": kind = .NodeType
		case: return v
		}
		name := ""
		#partial switch a in call.args[0].derived {
		case ^ast.Ident: name = a.name
		case ^ast.Selector_Expr: if a.field != nil do name = a.field.name
		}
		if name == "" do return v
		base := ""
		if kind == .NodeType && len(call.args) > 1 {
			if sel, ok := call.args[1].derived.(^ast.Implicit_Selector_Expr); ok && sel.field != nil do base = sel.field.name
		}
		append(&w.out.registrations, IndexRegistration{
			kind = kind,
			name = strings.clone(name, w.result),
			base = strings.clone(base, w.result),
			line = call.pos.line,
			column = call.pos.column - 1,
			lineText = strings.clone(lineText(w.src, call.pos.offset), w.result),
		})
		return v
	}}
	for decl in file.decls do ast.walk(&visitor, decl)
	indexCalls(&out, file, text, result)
	return out
}

// The engine calls' string literal arguments and the procedures of a parsed file (ParseSource's)
@(private="file")
indexCalls :: proc(out: ^IndexFile, file: ^ast.File, text: string, result: runtime.Allocator) {
	alias := ""
	for imp in file.imports {
		path := strings.trim(imp.relpath.text, "\"`")
		if path != "engine:." && path != "engine:" && path != "engine" do continue
		alias = imp.name.text != "" ? imp.name.text : "crossfire"
	}
	out.engineAlias = strings.clone(alias, result)
	lineText :: proc(src: string, offset: int) -> string {
		start := offset
		for start > 0 && src[start - 1] != '\n' do start -= 1
		end := offset
		for end < len(src) && src[end] != '\n' && src[end] != '\r' do end += 1
		return src[start:end]
	}
	Walk :: struct {
		out: ^IndexFile,
		src, alias: string,
		result: runtime.Allocator,
		// The procedures' byte ranges, for each call's (innermost first: the smallest)
		ranges: [dynamic][2]int,
		offsets: [dynamic]int,
	}
	w := Walk{out = out, src = text, alias = alias, result = result}
	w.ranges = make([dynamic][2]int, context.allocator)
	w.offsets = make([dynamic]int, context.allocator)
	visitor := ast.Visitor{data = &w, visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil do return nil
		w := (^Walk)(v.data)
		#partial switch n in node.derived {
		case ^ast.Proc_Lit:
			self := ""
			if type, ok := n.type.derived.(^ast.Proc_Type); ok && type.params != nil && len(type.params.list) > 0 {
				if ptr, isPtr := type.params.list[0].type.derived.(^ast.Pointer_Type); isPtr && ptr.elem != nil {
					#partial switch elem in ptr.elem.derived {
					case ^ast.Ident: self = elem.name
					case ^ast.Selector_Expr: if elem.field != nil do self = elem.field.name
					}
				}
			}
			append(&w.out.procs, IndexProc{n.pos.line, n.end.line, strings.clone(self, w.result)})
			append(&w.ranges, [2]int{n.pos.offset, n.end.offset})
		case ^ast.Call_Expr:
			if w.alias == "" do return v
			sel, isSel := n.expr.derived.(^ast.Selector_Expr)
			if !isSel || sel.field == nil do return v
			pkg, isIdent := sel.expr.derived.(^ast.Ident)
			if !isIdent || pkg.name != w.alias do return v
			receiver := ""
			if len(n.args) > 0 {
				if _, named := n.args[0].derived.(^ast.Field_Value); !named {
					// The AST's arena (the worker's temp allocator isn't reset there)
					b := strings.builder_make(context.allocator)
					for c in w.src[clamp(n.args[0].pos.offset, 0, len(w.src)):clamp(n.args[0].end.offset, 0, len(w.src))] do if c != ' ' && c != '\t' && c != '\n' && c != '\r' do strings.write_rune(&b, c)
					receiver = strings.to_string(b)
				}
			}
			position := 0
			for arg in n.args {
				value := arg
				argName := ""
				if fv, named := arg.derived.(^ast.Field_Value); named {
					if name, ok := fv.field.derived.(^ast.Ident); ok do argName = name.name
					value = fv.value
				}
				defer if argName == "" do position += 1
				lit, isLit := value.derived.(^ast.Basic_Lit)
				if !isLit || lit.tok.kind != .String || len(lit.tok.text) < 2 do continue
				raw := lit.tok.text
				content := raw[1:len(raw) - 1]
				// Escapes are kept as written: names never need them, so one is a name the code builds
				if raw[0] != '"' && raw[0] != '`' || strings.index_byte(content, '\\') >= 0 do continue
				at := lit.pos.offset
				lineStart := at
				for lineStart > 0 && w.src[lineStart - 1] != '\n' do lineStart -= 1
				append(&w.out.calls, IndexCall{
					procName = strings.clone(sel.field.name, w.result),
					argument = argName == "" ? position : -1,
					argName = strings.clone(argName, w.result),
					value = strings.clone(content, w.result),
					line = lit.pos.line,
					column = at - lineStart,
					endColumn = at - lineStart + len(raw),
					lineText = strings.clone(lineText(w.src, at), w.result),
					receiver = strings.clone(receiver, w.result),
				})
				append(&w.offsets, at)
			}
		}
		return v
	}}
	for decl in file.decls do ast.walk(&visitor, decl)
	// Each call's procedure: the smallest range holding it
	for &call, i in out.calls {
		at := w.offsets[i]
		best := -1
		for r, j in w.ranges {
			if r[0] > at || at >= r[1] do continue
			if best < 0 || r[1] - r[0] < w.ranges[best][1] - w.ranges[best][0] do best = j
		}
		if best >= 0 do call.selfType = strings.clone(out.procs[best].selfType, result)
	}
}

// A comment group's text, markers and the space after them removed (allocator)
@(private="file")
indexCommentText :: proc(group: ^ast.Comment_Group, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	for tok, i in group.list {
		text := tok.text
		if strings.has_prefix(text, "/*") {
			text = strings.trim_suffix(strings.trim_prefix(text, "/*"), "*/")
		} else {
			text = strings.trim_prefix(text, "//")
		}
		if i > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, strings.trim_space(text))
	}
	return strings.to_string(b)
}

// Frees one file's entry
IndexFile_Destroy :: proc(f: ^IndexFile) {
	delete(f.path)
	for &s in f.structs {
		delete(s.name)
		delete(s.embeds)
		for fl in s.fields {
			delete(fl.name); delete(fl.type); delete(fl.tag); delete(fl.comment); delete(fl.lineText)
		}
		delete(s.fields)
	}
	delete(f.structs)
	for &en in f.enums {
		delete(en.name)
		for v in en.values do delete(v)
		delete(en.values)
	}
	delete(f.enums)
	for r in f.registrations { delete(r.name); delete(r.base); delete(r.lineText) }
	delete(f.registrations)
	delete(f.engineAlias)
	for c in f.calls {
		delete(c.procName); delete(c.argName); delete(c.value); delete(c.lineText); delete(c.receiver); delete(c.selfType)
	}
	delete(f.calls)
	for p in f.procs do delete(p.selfType)
	delete(f.procs)
	f^ = {}
}

// Frees everything the index holds (and its copy of the build's catalog)
ScriptIndex_Destroy :: proc(index: ^ScriptIndex) {
	for _, &f in index.files do IndexFile_Destroy(&f)
	delete(index.files)
	scriptIndexClearDerived(index)
	delete(index.scripts)
	delete(index.dataTypes)
	delete(index.nodeTypes)
	delete(index.problems)
	delete(index.folder)
	for path in index.buffers do delete(path)
	delete(index.buffers)
	ScriptCatalog_Clear(&index.built)
	index^ = {}
}

@(private="file")
scriptIndexClearDerived :: proc(index: ^ScriptIndex) {
	ScriptDescs_Destroy(&index.scripts)
	ScriptDescs_Destroy(&index.dataTypes)
	ScriptDescs_Destroy(&index.nodeTypes)
	for p in index.problems { delete(p.path); delete(p.message); delete(p.lineText) }
	clear(&index.problems)
	index.scripts = {}
	index.dataTypes = {}
	index.nodeTypes = {}
}

/*
Takes parsed files into the index (owning them), then works out what they describe again. A
file that didn't parse keeps its last good declarations (the new version's errors noted).

Inputs:
- files: Parsed files (the index takes them; their slice is the caller's)
*/
ScriptIndex_Take :: proc(index: ^ScriptIndex, files: []IndexFile) {
	for &f in files {
		if old, had := &index.files[f.path]; had {
			if f.errors > 0 && old.errors == 0 && (len(old.structs) > 0 || len(old.registrations) > 0) {
				// Keep what last parsed; note the new version and its errors
				old.errors = f.errors
				old.modTime = f.modTime
				old.bufferVersion = f.bufferVersion
				old.hash = f.hash
				IndexFile_Destroy(&f)
				continue
			}
			// The key is the old entry's path: out first, then the new one in
			ScriptIndex_Forget(index, f.path)
		}
		index.files[f.path] = f
	}
	ScriptIndex_Derive(index)
}

// Forgets a file (deleted on disk)
ScriptIndex_Forget :: proc(index: ^ScriptIndex, path: string) {
	if path not_in index.files do return
	_, f := delete_key(&index.files, path)
	IndexFile_Destroy(&f)
}

// The engine's node types by name (`Camera2D`...), for node fields
@(private="file")
engineNodeTypeName :: proc(name: string) -> bool {
	if name == "Node" do return true
	for kind in NodeKind do if NodeField_TypeName(kind) == name do return true
	return false
}

// An asset handle type's field type, by its name
@(private="file")
assetFieldType :: proc(name: string) -> (e.ScriptFieldType, bool) {
	switch name {
	case "TextureAsset":   return .Texture, true
	case "SoundAsset":     return .Sound, true
	case "FontAsset":      return .Font, true
	case "DataAsset":      return .Data, true
	case "ComponentAsset": return .Component, true
	case "MusicAsset":     return .Music, true
	case "AnimationAsset": return .Animation, true
	}
	return .Float, false
}

/*
Works out what the indexed files describe: the scripts, data types and node types registered,
their exported fields and events (as the engine's `exportedFields` reads them), and the
problems. Called by ScriptIndex_Take.
*/
ScriptIndex_Derive :: proc(index: ^ScriptIndex) {
	scriptIndexClearDerived(index)
	index.generation += 1
	// Every file's structs and enums, by name (one package), in path order for determinism
	paths := make([dynamic]string, context.temp_allocator)
	for path in index.files do append(&paths, path)
	slice.sort(paths[:])
	structs := make(map[string]^IndexStruct, allocator = context.temp_allocator)
	structFile := make(map[string]string, allocator = context.temp_allocator)
	enums := make(map[string]^IndexEnum, allocator = context.temp_allocator)
	for path in paths {
		f := &index.files[path]
		for &s in f.structs do if s.name not_in structs { structs[s.name] = &s; structFile[s.name] = f.path }
		for &en in f.enums do if en.name not_in enums do enums[en.name] = &en
	}
	// A struct that embeds a node type (through its first field), for node fields
	embedsNode :: proc(structs: map[string]^IndexStruct, name: string, depth := 0) -> bool {
		if depth > 6 do return false
		s, ok := structs[name]
		if !ok || s.embeds == "" do return false
		base := s.embeds
		if dot := strings.last_index_byte(base, '.'); dot >= 0 do return engineNodeTypeName(base[dot + 1:])
		return embedsNode(structs, base, depth + 1)
	}

	problem :: proc(index: ^ScriptIndex, path: string, field: IndexField, message: string, warning := true) {
		append(&index.problems, IndexProblem{
			path = strings.clone(path), line = field.line, column = field.column, endColumn = field.column + len(field.name),
			lineText = strings.clone(field.lineText), message = strings.clone(message), warning = warning,
		})
	}

	isAsset :: proc(name: string) -> bool { _, ok := assetFieldType(name); return ok }
	describe :: proc(index: ^ScriptIndex, structs: map[string]^IndexStruct, enums: map[string]^IndexEnum, path: string, s: ^IndexStruct, events: bool) -> (desc: ScriptDesc) {
		for f in s.fields {
			if events && strings.has_suffix(f.type, "EventSubject") {
				description, tagged := reflect.struct_tag_lookup(reflect.Struct_Tag(f.tag), "event")
				if tagged {
					append(&desc.events, e.NodeEventInfo{
						name = strings.concatenate({e.SCRIPT_EVENT_PREFIX, f.name}),
						description = strings.clone(string(description)),
						dataHint = strings.clone(string(reflect.struct_tag_get(reflect.Struct_Tag(f.tag), "data"))),
					})
				}
			}
			options, exported := reflect.struct_tag_lookup(reflect.Struct_Tag(f.tag), "export")
			if !exported do continue
			field := ScriptFieldDesc{line = f.line}
			type := f.type
			short := type
			if dot := strings.last_index_byte(type, '.'); dot >= 0 do short = type[dot + 1:]
			switch {
			case type == "f32" || type == "f64": field.type = .Float
			case type == "int" || type == "i32": field.type = .Int
			case type == "bool": field.type = .Bool
			case type == "string": field.type = .String
			case type == "[2]f32": field.type = .Vector2
			case strings.contains(type, ".") && short == "Color" && !strings.has_prefix(type, "^"): field.type = .Color
			case strings.contains(type, ".") && isAsset(short) && !strings.has_prefix(type, "^"): field.type, _ = assetFieldType(short)
			case type in enums:
				field.type = .Enum
				for v in enums[type].values do append(&field.enumNames, strings.clone(v))
			// A pointer to another package's type: a node type (the engine's: Control, MusicPlayer...;
			// the build says if it isn't), or to one of the package's that embeds one
			case strings.has_prefix(type, "^") && !strings.contains(type, "[") && (strings.contains(type, ".") || embedsNode(structs, type[1:]) || engineNodeTypeName(type[1:])):
				field.type = .Node
				field.hint = strings.clone(short[strings.has_prefix(short, "^") ? 1 : 0:])
			case strings.contains(type, ".") && !strings.has_prefix(type, "^") && !strings.contains(type, "["):
				// Another package's type (an engine enum?): the build will say
				continue
			case:
				problem(index, path, f, fmt.tprintf("%s can't be exported: use f32, f64, int, i32, bool, string, [2]f32, an enum, sdl.Color, an asset handle or a node pointer", f.type))
				continue
			}
			field.name = strings.clone(f.name)
			if f.comment != "" do field.comment = strings.clone(f.comment)
			for option in indexTagOptions(string(options)) {
				switch option.key {
				case "default":
					delete(field.defaultValue)
					field.defaultValue = strings.clone(option.value)
				case "min", "max":
					v, ok := strconv.parse_f64(option.value)
					if !ok {
						problem(index, path, f, fmt.tprintf("%s=%s isn't a number", option.key, option.value))
						continue
					}
					if option.key == "min" do field.min = v
					else do field.max = v
				case "kind":
					if field.type != .Node {
						delete(field.hint)
						field.hint = strings.clone(option.value)
					}
				case:
					problem(index, path, f, fmt.tprintf("export:\"%s\" isn't an option (default=, min=, max=, kind=)", option.key))
				}
			}
			if field.type == .Float || field.type == .Int {
				if _, isNumber := strconv.parse_f64(field.defaultValue); field.defaultValue != "" && !isNumber {
					problem(index, path, f, fmt.tprintf("default=%s isn't a number", field.defaultValue))
				}
			}
			if field.defaultValue == "" {
				#partial switch field.type {
				case .Float, .Int: field.defaultValue = strings.clone("0")
				case .Bool: field.defaultValue = strings.clone("false")
				case .Vector2: field.defaultValue = strings.clone("0, 0")
				case .Color: field.defaultValue = strings.clone("#ffffff")
				case .Enum: if len(field.enumNames) > 0 do field.defaultValue = strings.clone(field.enumNames[0])
				}
			}
			append(&desc.fields, field)
		}
		return
	}

	for path in paths {
		f := &index.files[path]
		for r in f.registrations {
			s, ok := structs[r.name]
			if !ok do continue
			desc := describe(index, structs, enums, structFile[r.name], s, r.kind == .Script)
			desc.name = strings.clone(r.name)
			desc.file = strings.clone(f.path)
			desc.line = r.line
			desc.fromIndex = true
			switch r.kind {
			case .Script: append(&index.scripts, desc)
			case .Data: append(&index.dataTypes, desc)
			case .NodeType:
				for kind in NodeKind do if fmt.tprint(kind) == r.base do desc.base = kind
				append(&index.nodeTypes, desc)
			}
		}
	}
}

// `default=10, 20 min=0`: the engine's tag options (script.odin's tagOptions), and any other
// `key=` at a word start, so a misspelled one is reported (temp allocated)
@(private="file")
indexTagOptions :: proc(text: string) -> []struct { key, value: string } {
	Option :: struct { key, value: string }
	KEYS :: [?]string{"default=", "min=", "max=", "kind="}
	starts := make([dynamic]int, context.temp_allocator)
	for i in 0..<len(text) {
		if i > 0 && text[i - 1] != ' ' do continue
		known := false
		for key in KEYS do if strings.has_prefix(text[i:], key) do known = true
		// Another `word=` starts an option too, so a misspelled one is reported; not inside
		// default='s value, which may hold spaces
		if !known {
			j := i
			for j < len(text) && (text[j] >= 'a' && text[j] <= 'z' || text[j] >= 'A' && text[j] <= 'Z') do j += 1
			word := j > i && j < len(text) && text[j] == '='
			inDefault := len(starts) > 0 && strings.has_prefix(text[starts[len(starts) - 1]:], "default=")
			known = word && !inDefault
		}
		if known do append(&starts, i)
	}
	options := make([]Option, len(starts), context.temp_allocator)
	for start, n in starts {
		end := n + 1 < len(starts) ? starts[n + 1] : len(text)
		key, _, value := strings.partition(text[start:end], "=")
		options[n] = {key, strings.trim_space(value)}
	}
	return transmute([]struct { key, value: string })options
}

// --- running it --------------------------------------------------------------------

/*
What changed since the index last looked: the scripts folder's .odin files whose modification
time differs (or that are new), and code tabs' buffers whose text changed and then stayed the same
for a tick (texts read or copied: owned by the returned sources). Files that went are forgotten.

Inputs:
- folder: The project's scripts folder (absolute)
- buffer: A code tab's version for a path (-1 when it isn't open), whether it has unsaved
  changes, and its text when `wantText` (a copy); nil in tests
*/
ScriptIndex_Plan :: proc(index: ^ScriptIndex, folder: string, buffer: proc(path: string, wantText: bool) -> (text: string, version: int, dirty: bool) = nil) -> [dynamic]IndexSource {
	sources := make([dynamic]IndexSource)
	if index.folder != folder {
		// Another project: start over
		for _, &f in index.files do IndexFile_Destroy(&f)
		clear(&index.files)
		for path in index.buffers do delete(path)
		clear(&index.buffers)
		delete(index.folder)
		index.folder = strings.clone(folder)
		ScriptIndex_Derive(index)
	}
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	if err == nil {
		for entry in entries {
			if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") do continue
			path := filepath.join({folder, entry.name}, context.temp_allocator) or_continue
			seen[path] = true
			known, had := index.files[path]
			// A code tab with unsaved changes: its text, once it stopped changing
			if buffer != nil {
				_, version, dirty := buffer(path, false)
				if version >= 0 && dirty {
					st, hadState := index.buffers[path]
					if !hadState {
						index.buffers[strings.clone(path)] = {seenVersion = version, seenAt = time.tick_now(), parsedVersion = -1}
						continue
					}
					if st.seenVersion != version {
						st.seenVersion, st.seenAt = version, time.tick_now()
						index.buffers[path] = st
						continue
					}
					if st.parsedVersion == version || had && known.bufferVersion == version do continue
					st.parsedVersion = version
					index.buffers[path] = st
					text, _, _ := buffer(path, true)
					append(&sources, IndexSource{path = strings.clone(path), text = strings.clone(text), bufferVersion = version})
					continue
				}
			}
			if had && known.bufferVersion < 0 && known.modTime == entry.modification_time do continue
			text, readErr := os.read_entire_file(path, context.allocator)
			if readErr != nil do continue
			// Unchanged text (a save of what the buffer had parsed): only the time moves on
			if had && known.hash == hash.fnv64a(text) {
				f := &index.files[path]
				f.modTime = entry.modification_time
				f.bufferVersion = -1
				delete(text)
				continue
			}
			append(&sources, IndexSource{path = strings.clone(path), text = string(text), modTime = entry.modification_time, bufferVersion = -1})
		}
	}
	gone := make([dynamic]string, context.temp_allocator)
	for path in index.files do if path not_in seen do append(&gone, path)
	if len(gone) > 0 {
		for path in gone do ScriptIndex_Forget(index, path)
		ScriptIndex_Derive(index)
	}
	return sources
}

/*
Parses sources (the worker's job; tests call it directly).

Returns:
- The parsed files (owned) and the time taken
*/
ScriptIndex_ParseAll :: proc(sources: []IndexSource) -> ([]IndexFile, time.Duration) {
	start := time.tick_now()
	files := make([]IndexFile, len(sources))
	for s, i in sources {
		files[i] = ScriptIndex_ParseSource(s.path, s.text)
		files[i].modTime = s.modTime
		files[i].bufferVersion = s.bufferVersion
	}
	return files, time.tick_since(start)
}

@(private="file")
indexSourcesDestroy :: proc(sources: []IndexSource) {
	for s in sources { delete(s.path); delete(s.text) }
}

/*
The index's messages: the tick (look for changes, start a parse on the worker) and the worker's
answer (take it, apply it to the catalog).

Returns:
- A command, and whether `m` was one of them
*/
ScriptIndex_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	index := &state.scriptIndex
	#partial switch v in m {
	case ScriptIndex_Tick:
		index.ticking = false
		if state.project.rootPath == "" do return {}, true
		folder := absolutePath(joinPath(state.project.rootPath, SCRIPTS_FOLDER, allocator = context.temp_allocator))
		tick := skald.cmd_delay(SCRIPT_INDEX_TICK, Msg(ScriptIndex_Tick{}))
		// The engine's name parameters, once (name_kinds.odin)
		if names := NameTable_Start(); names.kind != .None do tick = skald.cmd_batch(tick, names)
		// And its documentation, for hovers and F1 (engine_docs.odin)
		if docs := EngineDocs_Start(); docs.kind != .None do tick = skald.cmd_batch(tick, docs)
		index.ticking = true
		if index.running {
			index.again = true
			return tick, true
		}
		before := index.generation
		sources := ScriptIndex_Plan(index, folder, codeBufferOf)
		if index.generation != before do ScriptIndex_Apply(state)
		if len(sources) == 0 {
			delete(sources)
			return tick, true
		}
		index.running = true
		Job :: struct { folder: string, sources: [dynamic]IndexSource }
		work := skald.cmd_thread(Msg, Job{strings.clone(folder), sources}, proc(job: Job) -> Msg {
			files, took := ScriptIndex_ParseAll(job.sources[:])
			indexSourcesDestroy(job.sources[:])
			delete(job.sources)
			return ScriptIndex_Parsed{job.folder, files, took}
		})
		return skald.cmd_batch(tick, work), true
	case ScriptIndex_Parsed:
		index.running = false
		defer delete(v.folder)
		defer delete(v.files)
		if v.folder != index.folder {
			for &f in v.files do IndexFile_Destroy(&f)
			return {}, true
		}
		first := len(index.files) == 0
		index.lastFiles = len(v.files)
		index.lastTime = v.took
		if first do index.fullTime = v.took
		ScriptIndex_Take(index, v.files)
		ScriptIndex_Apply(state)
		if index.again {
			index.again = false
			if !index.ticking {
				index.ticking = true
				return skald.cmd_delay(0.05, Msg(ScriptIndex_Tick{})), true
			}
		}
		return {}, true
	}
	return {}, false
}

/*
Reads one script file into the index now, on the caller's thread, and applies it to the catalog:
New Script's file, so the inspector's Script section shows the script's fields at once instead
of changing under the pointer half a second later (a click on a button below it was lost when
the rows moved between the pointer's move and the press). A small file parses in a millisecond.
Does nothing before the index has read the project's folder (its first tick reads them all).

Inputs:
- path: The file (absolute, in the project's scripts folder)
*/
ScriptIndex_ReadNow :: proc(state: ^State, path: string) {
	index := &state.scriptIndex
	folder := absolutePath(joinPath(state.project.rootPath, SCRIPTS_FOLDER, allocator = context.temp_allocator))
	if index.folder != folder || index.running do return
	key := filepath.join({folder, filepath.base(path)}, context.temp_allocator) or_else ""
	info, statErr := os.stat(key, context.temp_allocator)
	if key == "" || statErr != nil do return
	text, err := os.read_entire_file(key, context.temp_allocator)
	if err != nil do return
	f := ScriptIndex_ParseSource(key, string(text))
	f.modTime = info.modification_time
	files := []IndexFile{f}
	ScriptIndex_Take(index, files)
	ScriptIndex_Apply(state)
}

// A code tab's buffer for the index: its version, whether it has unsaved changes, its text (asked for)
@(private="file")
codeBufferOf :: proc(path: string, wantText: bool) -> (text: string, version: int, dirty: bool) {
	return CodeEditor_Buffer(path, wantText)
}

/*
Merges the index into the catalog: `State.scripts` becomes the build's catalog
(`index.built`) with the index's description of each script, data type and node type whose
file changed since that build (or that it doesn't have), marked `fromIndex`; a described one
whose changed file no longer registers it is dropped. Before any build: the index's alone.
*/
ScriptIndex_Apply :: proc(state: ^State) {
	index := &state.scriptIndex
	status := state.scripts.status
	changedSinceBuild :: proc(index: ^ScriptIndex, file: string) -> bool {
		if !index.hasBuilt do return true
		base := filepath.base(file)
		for path, &f in index.files {
			if filepath.base(path) != base do continue
			if f.bufferVersion >= 0 do return true
			return time.diff(index.builtFrom, f.modTime) > 0
		}
		return false
	}
	merge :: proc(index: ^ScriptIndex, built: []ScriptDesc, indexed: []ScriptDesc, into: ^[dynamic]ScriptDesc) {
		ScriptDescs_Destroy(into)
		into^ = make([dynamic]ScriptDesc)
		for &d in built {
			// The index has a newer description, or the file changed and doesn't register it now
			replaced := false
			for &n in indexed do if n.name == d.name && changedSinceBuild(index, n.file) do replaced = true
			if replaced do continue
			if changedSinceBuild(index, d.file) && index.hasBuilt {
				still := false
				for &n in indexed do if n.name == d.name do still = true
				if !still do continue
			}
			append(into, ScriptDesc_Clone(d))
		}
		for &n in indexed {
			known := false
			for &d in built do if d.name == n.name do known = true
			if known && !changedSinceBuild(index, n.file) do continue
			append(into, ScriptDesc_Clone(n))
		}
	}
	merge(index, index.built.scripts[:], index.scripts[:], &state.scripts.scripts)
	merge(index, index.built.dataTypes[:], index.dataTypes[:], &state.scripts.dataTypes)
	merge(index, index.built.nodeTypes[:], index.nodeTypes[:], &state.scripts.nodeTypes)
	state.scripts.status = status
	state.scripts.generation += 1
}

/*
Keeps the build's catalog for ScriptIndex_Apply (a copy), with the newest script source when the
build started. Called when a build's description arrives (play.odin's takeDescription).
*/
ScriptIndex_TakeBuild :: proc(state: ^State) {
	index := &state.scriptIndex
	ScriptCatalog_Clear(&index.built)
	for &d in state.scripts.scripts do append(&index.built.scripts, ScriptDesc_Clone(d))
	for &d in state.scripts.dataTypes do append(&index.built.dataTypes, ScriptDesc_Clone(d))
	for &d in state.scripts.nodeTypes do append(&index.built.nodeTypes, ScriptDesc_Clone(d))
	index.built.status = .Ready
	index.hasBuilt = true
	index.builtFrom = state.scriptsBuildSource
	ScriptIndex_Apply(state)
}

// The newest modification time of the scripts folder's .odin files (zero when there are none)
Scripts_NewestSource :: proc(project: ^Project) -> time.Time {
	newest: time.Time
	dir := joinPath(project.rootPath, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return newest
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") do continue
		if time.diff(newest, entry.modification_time) > 0 do newest = entry.modification_time
	}
	return newest
}

// The index's problems in a file (absolute path)
ScriptIndex_ProblemsIn :: proc(index: ^ScriptIndex, path: string) -> []IndexProblem {
	out := make([dynamic]IndexProblem, context.temp_allocator)
	for p in index.problems do if p.path == path do append(&out, p)
	return out[:]
}

// The file entry for a path, or nil
ScriptIndex_File :: proc(index: ^ScriptIndex, path: string) -> ^IndexFile {
	return &index.files[path] if path in index.files else nil
}
