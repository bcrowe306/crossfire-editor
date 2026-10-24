package crossfire_editor

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import vmem "core:mem/virtual"
import e "engine:."

/*
What the scripts' code says about their names, for renames and the symbol under the caret
(script_links.odin): every file of the scripts package parsed with `core:odin/parser`, then each
identifier classified as naming one of the package's types or a field of one, as far as the code
shows without a compiler.

**Why the index and not the language server (OLS's rename):** the project side of a rename has
to agree exactly with the code side, and the editor already reads the code (the script index:
the same parser, the same files, unsaved code tabs included). OLS's rename reads other files from
disk, so it misses what's typed in other tabs and isn't saved yet, it isn't always there (none
installed, still starting, crashed), and it answers later, while the scene files are rewritten
now. So renames of what the project stores (script types, node types, data types, their exported
fields and events) are computed here, synchronously, from the code tabs' text; anything else F2
renames goes to OLS (code_editor's rename.odin).

**How a field's uses are found:** `x.speed` renames when `x`'s type is known to be the struct:
a procedure's parameter (`self: ^Hero`), a local or global declared with a type or from a
composite literal, `&`, a cast, a call of the package's procedures (their result type),
`e.Node_GetScript(node, Hero)`, `e.Global(Hero)`, `e.Data(Hero, ...)`, `new(Hero)`, a field of a
known struct, an element of a known slice, `for x in` one; through `using` fields and parameters.
`Hero{speed = 1}` and the declaration itself too. A `.speed` whose receiver's type isn't known
is left alone and counted (`CodeRename.unsure`): the build says if one was missed, and nothing
that only shares the name is ever renamed.
*/

// What a name in the scripts is, for renames and usages
ScriptSymbolKind :: enum {
	None,
	// A registered script, node type or data type (its struct)
	Type,
	// One of its exported fields
	Field,
	// One of its events (an `EventSubject` field tagged `event:"..."`: `script.<field>`)
	Event,
}

// A name of the project's code the editor can rename and find: a registered type, or its field
ScriptSymbol :: struct {
	kind: ScriptSymbolKind,
	// The registered type, the one renamed or whose field it is (temp allocated)
	owner: string,
	ownerKind: IndexRegistrationKind,
	// The field or event's field name (temp allocated)
	field: string,
	// Where the name is in the document asked about: 0-based line, byte columns
	line, start, end: int,
}

// The symbol's current name: the type's, or the field's
ScriptSymbol_Name :: proc(s: ScriptSymbol) -> string {
	return s.kind == .Type ? s.owner : s.field
}

// A script file's text for the code model (its path absolute)
CodeSource :: struct {
	path: string,
	text: string,
}

// An edit to a script file: 0-based line, byte columns (`end` exclusive) of the text it was
// computed from, and what replaces it (temp allocated)
CodeEdit :: struct {
	path: string,
	line, column, endColumn: int,
	text: string,
}

// The code side of a rename: every file's edits, in order (temp allocated)
CodeRename :: struct {
	edits: [dynamic]CodeEdit,
	// `.field` uses whose receiver's type isn't known: left alone (paths and lines, 1-based)
	unsure: [dynamic]string,
	// Why it can't be done ("Player is already declared in hero.odin"); "" when it can
	problem: string,
}

// What an identifier means, as far as the code shows
@(private="file")
Meaning :: enum {
	// The package's type of that name
	Type,
	// A field of a struct (`owner`; "" when the receiver's type isn't known)
	Field,
	// A `kind=<type>` in a struct tag (a data type's name)
	Tag_Kind,
	// A string literal passed to an engine procedure (an event's name: "script.onHit")
	Engine_String,
}

@(private="file")
Occurrence :: struct {
	file: int,
	// 0-based line, byte columns of the name (for strings: inside the quotes)
	line, column, endColumn: int,
	meaning: Meaning,
	owner, name: string,
}

@(private="file")
CodeFile :: struct {
	path, text: string,
	file: ^ast.File,
	// The engine's import name ("e"; "" when it isn't imported), and every import's
	alias: string,
	imports: map[string]bool,
}

// The parsed package: its files, structs, procedures' result types and globals (all in `arena`)
@(private="file")
CodeModel :: struct {
	arena: vmem.Arena,
	allocator: runtime.Allocator,
	files: [dynamic]CodeFile,
	structs: map[string]^ast.Struct_Type,
	structFile: map[string]int,
	procs: map[string]^ast.Proc_Type,
	globals: map[string]Decl,
	occurrences: [dynamic]Occurrence,
	// What typeOf answers for a value known to be of another package's type (the engine's: its
	// fields are that package's), as opposed to nil, not known
	otherPackage: ^ast.Expr,
}

// A declared name: its type as written, or the value it's declared from (and which of the
// value's results, for `a, b := f()`), or an element of a ranged value (`for x in list`)
@(private="file")
Decl :: struct {
	type: ^ast.Expr,
	value: ^ast.Expr,
	result: int,
	ranged: bool,
	// A `using` parameter or local: its fields are names in the procedure
	isUsing: bool,
	// Declared twice with different meanings: unknown
	ambiguous: bool,
}

// One procedure's names (a literal's own: Odin procedures don't capture locals)
@(private="file")
Scope :: struct {
	names: map[string]Decl,
	usings: [dynamic]^ast.Expr,
	// Being resolved (a recursion guard)
	resolving: map[string]bool,
}

@(private="file")
codeModelBuild :: proc(sources: []CodeSource) -> ^CodeModel {
	m := new(CodeModel)
	if vmem.arena_init_growing(&m.arena) != nil {
		free(m)
		return nil
	}
	m.allocator = vmem.arena_allocator(&m.arena)
	context.allocator = m.allocator
	m.files = make([dynamic]CodeFile)
	m.structs = make(map[string]^ast.Struct_Type)
	m.structFile = make(map[string]int)
	m.procs = make(map[string]^ast.Proc_Type)
	m.globals = make(map[string]Decl)
	m.occurrences = make([dynamic]Occurrence)
	m.otherPackage = ast.new(ast.Bad_Expr, tokenizer.Pos{}, tokenizer.Pos{})
	sorted := slice.clone(sources, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: CodeSource) -> bool { return a.path < b.path })
	for s in sorted {
		file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
		file.src = strings.clone(s.text)
		file.fullpath = strings.clone(s.path)
		p := parser.default_parser()
		p.err = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
		p.warn = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
		parser.parse_file(&p, file)
		cf := CodeFile{path = file.fullpath, text = file.src, file = file, imports = make(map[string]bool)}
		for imp in file.imports {
			path := strings.trim(imp.relpath.text, "\"`")
			name := imp.name.text
			if name == "" {
				name = path
				if colon := strings.last_index_byte(name, ':'); colon >= 0 do name = name[colon + 1:]
				if slash := strings.last_index_byte(name, '/'); slash >= 0 do name = name[slash + 1:]
			}
			if path == "engine:." || path == "engine:" || path == "engine" {
				if imp.name.text == "" do name = "crossfire"
				cf.alias = name
			}
			cf.imports[name] = true
		}
		append(&m.files, cf)
		fi := len(m.files) - 1
		for decl in file.decls {
			vd, ok := decl.derived.(^ast.Value_Decl)
			if !ok || len(vd.names) == 0 do continue
			for nameExpr, i in vd.names {
				ident, isIdent := nameExpr.derived.(^ast.Ident)
				if !isIdent do continue
				if !vd.is_mutable && i < len(vd.values) {
					#partial switch v in vd.values[i].derived {
					case ^ast.Struct_Type:
						if ident.name not_in m.structs {
							m.structs[ident.name] = v
							m.structFile[ident.name] = fi
						}
					case ^ast.Proc_Lit:
						if v.type != nil do m.procs[ident.name] = v.type
					}
					continue
				}
				if vd.is_mutable {
					d := Decl{type = vd.type}
					if vd.type == nil && len(vd.values) == len(vd.names) do d.value = vd.values[i]
					else if vd.type == nil && len(vd.values) == 1 { d.value = vd.values[0]; d.result = i }
					m.globals[ident.name] = d
				}
			}
		}
	}
	for &f, fi in m.files do codeModelWalkFile(m, fi, &f)
	return m
}

@(private="file")
codeModelDestroy :: proc(m: ^CodeModel) {
	if m == nil do return
	vmem.arena_destroy(&m.arena)
	free(m)
}

// --- types -----------------------------------------------------------------------------

// The package's struct a type names, through pointers (`^Hero` -> Hero); "" for anything else
@(private="file")
structName :: proc(m: ^CodeModel, type: ^ast.Expr) -> string {
	t := type
	for depth in 0 ..< 8 {
		if t == nil do return ""
		#partial switch v in t.derived {
		case ^ast.Pointer_Type: t = v.elem
		case ^ast.Paren_Expr: t = v.expr
		case ^ast.Distinct_Type: t = v.type
		case ^ast.Ident:
			if v.name in m.structs do return v.name
			return ""
		case:
			return ""
		}
		_ = depth
	}
	return ""
}

// Whether a type is known and isn't one of the package's structs (another package's, a
// builtin, an array): a field reached through it is never a package struct's
@(private="file")
isForeign :: proc(m: ^CodeModel, type: ^ast.Expr) -> bool {
	if type == nil do return false
	if type == m.otherPackage do return true
	t := type
	for _ in 0 ..< 8 {
		#partial switch v in t.derived {
		case ^ast.Pointer_Type: t = v.elem
		case ^ast.Paren_Expr: t = v.expr
		case ^ast.Selector_Expr: return true
		case ^ast.Ident: return v.name not_in m.structs && (v.name not_in m.globals)
		case ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Map_Type, ^ast.Multi_Pointer_Type: return true
		case: return false
		}
		if t == nil do return false
	}
	return false
}

// The element of a pointer, slice, array, dynamic array or map's value type
@(private="file")
elemType :: proc(type: ^ast.Expr) -> ^ast.Expr {
	if type == nil do return nil
	#partial switch v in type.derived {
	case ^ast.Pointer_Type: return v.elem
	case ^ast.Multi_Pointer_Type: return v.elem
	case ^ast.Array_Type: return v.elem
	case ^ast.Dynamic_Array_Type: return v.elem
	case ^ast.Map_Type: return v.value
	case ^ast.Paren_Expr: return elemType(v.expr)
	}
	return nil
}

// What a ranged value's elements are: through one pointer (`for x in self.list`)
@(private="file")
rangeElem :: proc(type: ^ast.Expr) -> ^ast.Expr {
	if type == nil do return nil
	if p, ok := type.derived.(^ast.Pointer_Type); ok do return elemType(p.elem)
	return elemType(type)
}

// A pointer to a type (made in the model's arena)
@(private="file")
pointerTo :: proc(m: ^CodeModel, type: ^ast.Expr) -> ^ast.Expr {
	if type == nil do return nil
	context.allocator = m.allocator
	p := ast.new(ast.Pointer_Type, type.pos, type.end)
	p.elem = type
	return p
}

/*
The struct that has a field of the name, looking through `using` fields (`using script: e.Script`
of another package's: "" then), and the field's type.
*/
@(private="file")
fieldOf :: proc(m: ^CodeModel, structName: string, field: string, depth := 0) -> (owner: string, type: ^ast.Expr, found: bool) {
	st, ok := m.structs[structName]
	if !ok || st.fields == nil || depth > 6 do return "", nil, false
	for f in st.fields.list {
		for name in f.names {
			if ident, isIdent := name.derived.(^ast.Ident); isIdent && ident.name == field do return structName, f.type, true
		}
	}
	for f in st.fields.list {
		if .Using not_in f.flags do continue
		if inner := structNameOf(m, f.type); inner != "" {
			if o, t, has := fieldOf(m, inner, field, depth + 1); has do return o, t, true
		}
	}
	return "", nil, false
}

@(private="file")
structNameOf :: proc(m: ^CodeModel, type: ^ast.Expr) -> string {
	return structName(m, type)
}

// The type of a procedure's result (`i`th), when declared
@(private="file")
resultType :: proc(type: ^ast.Proc_Type, i: int) -> ^ast.Expr {
	if type == nil || type.results == nil do return nil
	n := 0
	for f in type.results.list {
		count := max(len(f.names), 1)
		if i < n + count do return f.type
		n += count
	}
	return nil
}

@(private="file")
Env :: struct {
	m: ^CodeModel,
	file: ^CodeFile,
	scope: ^Scope,
}

// The type of an expression, as far as the code shows (nil when it doesn't)
@(private="file")
typeOf :: proc(env: Env, expr: ^ast.Expr, depth := 0) -> ^ast.Expr {
	if expr == nil || depth > 24 do return nil
	m := env.m
	#partial switch v in expr.derived {
	case ^ast.Ident:
		return nameType(env, v.name, depth)
	case ^ast.Paren_Expr:
		return typeOf(env, v.expr, depth + 1)
	case ^ast.Selector_Expr:
		if v.field == nil do return nil
		if pkg, ok := v.expr.derived.(^ast.Ident); ok && pkg.name in env.file.imports && !nameDeclared(env, pkg.name) do return nil
		base := typeOf(env, v.expr, depth + 1)
		if isForeign(m, base) do return m.otherPackage
		owner := structName(m, base)
		if owner == "" do return nil
		_, type, found := fieldOf(m, owner, v.field.name)
		if !found do return nil
		return type
	case ^ast.Call_Expr:
		return callType(env, v, depth)
	case ^ast.Unary_Expr:
		if v.op.kind == .And do return pointerTo(m, typeOf(env, v.expr, depth + 1))
		return typeOf(env, v.expr, depth + 1)
	case ^ast.Deref_Expr:
		return elemType(typeOf(env, v.expr, depth + 1))
	case ^ast.Index_Expr:
		return elemType(typeOf(env, v.expr, depth + 1))
	case ^ast.Comp_Lit:
		return v.type
	case ^ast.Type_Assertion:
		return v.type
	case ^ast.Type_Cast:
		return v.type
	case ^ast.Ternary_If_Expr:
		return typeOf(env, v.x, depth + 1)
	case ^ast.Or_Else_Expr:
		return typeOf(env, v.x, depth + 1)
	case ^ast.Or_Return_Expr:
		return typeOf(env, v.expr, depth + 1)
	}
	return nil
}

// Whether a name is declared in the procedure or the package (so it isn't an import's)
@(private="file")
nameDeclared :: proc(env: Env, name: string) -> bool {
	if env.scope != nil && name in env.scope.names do return true
	return name in env.m.globals
}

@(private="file")
nameType :: proc(env: Env, name: string, depth: int) -> ^ast.Expr {
	if env.scope != nil {
		if d, ok := env.scope.names[name]; ok do return declType(env, name, d, depth)
		// A field of a `using` parameter's struct
		for u in env.scope.usings {
			if owner := structName(env.m, u); owner != "" {
				if _, type, found := fieldOf(env.m, owner, name); found do return type
			}
		}
	}
	if d, ok := env.m.globals[name]; ok {
		global := env
		global.scope = nil
		return declType(global, name, d, depth)
	}
	return nil
}

@(private="file")
declType :: proc(env: Env, name: string, d: Decl, depth: int) -> ^ast.Expr {
	if d.ambiguous do return nil
	if d.type != nil do return d.ranged ? rangeElem(d.type) : d.type
	if d.value == nil do return nil
	if env.scope != nil {
		if env.scope.resolving[name] do return nil
		env.scope.resolving[name] = true
		defer delete_key(&env.scope.resolving, name)
	}
	t: ^ast.Expr
	if d.result > 0 {
		if call, ok := d.value.derived.(^ast.Call_Expr); ok do t = callResult(env, call, d.result, depth + 1)
	} else {
		t = typeOf(env, d.value, depth + 1)
	}
	return d.ranged ? rangeElem(t) : t
}

@(private="file")
callType :: proc(env: Env, call: ^ast.Call_Expr, depth: int) -> ^ast.Expr {
	return callResult(env, call, 0, depth)
}

// A call's `i`th result's type: the package's procedures, `new(T)`, conversions `T(x)` /
// `(^T)(x)`, and the engine's procedures that return a pointer to the type they're given
@(private="file")
callResult :: proc(env: Env, call: ^ast.Call_Expr, i: int, depth: int) -> ^ast.Expr {
	m := env.m
	#partial switch c in call.expr.derived {
	case ^ast.Ident:
		if c.name == "new" && len(call.args) > 0 && i == 0 do return pointerTo(m, call.args[0])
		if c.name in m.structs && i == 0 do return call.expr
		if proc_type, ok := m.procs[c.name]; ok do return resultType(proc_type, i)
	case ^ast.Paren_Expr:
		// A conversion: (^Hero)(ptr)
		if i == 0 do return c.expr
	case ^ast.Pointer_Type:
		if i == 0 do return call.expr
	case ^ast.Selector_Expr:
		pkg, isIdent := c.expr.derived.(^ast.Ident)
		if !isIdent || c.field == nil || pkg.name != env.file.alias || env.file.alias == "" || i != 0 do return nil
		switch c.field.name {
		case "Node_GetScript", "Global", "Data", "CreateNode":
			for arg in call.args {
				if id, ok := arg.derived.(^ast.Ident); ok && id.name in m.structs do return pointerTo(m, arg)
			}
		}
		// Any other engine procedure returns the engine's types
		return m.otherPackage
	}
	_ = depth
	return nil
}

// --- the walk ----------------------------------------------------------------------------

@(private="file")
Walker :: struct {
	m: ^CodeModel,
	file: int,
	scope: ^Scope,
	// Identifiers classified by their parent (fields, keys, names): the walk skips them
	skip: ^map[^ast.Ident]bool,
}

// Collects a procedure's names: its parameters, then every declaration in its body (not in
// nested procedure literals: they have their own)
@(private="file")
scopeOf :: proc(m: ^CodeModel, lit: ^ast.Proc_Lit) -> ^Scope {
	context.allocator = m.allocator
	s := new(Scope)
	s.names = make(map[string]Decl)
	s.resolving = make(map[string]bool)
	s.usings = make([dynamic]^ast.Expr)
	add :: proc(s: ^Scope, name: string, d: Decl) {
		if name == "_" || name == "" do return
		if old, had := s.names[name]; had {
			if old.type != d.type || old.value != d.value || old.result != d.result || old.ranged != d.ranged {
				o := old
				o.ambiguous = true
				s.names[name] = o
			}
			return
		}
		s.names[name] = d
	}
	if lit.type != nil && lit.type.params != nil {
		for f in lit.type.params.list {
			for name in f.names {
				if id, ok := name.derived.(^ast.Ident); ok do add(s, id.name, Decl{type = f.type})
			}
			if .Using in f.flags do append(&s.usings, f.type)
		}
	}
	if lit.type != nil && lit.type.results != nil {
		for f in lit.type.results.list do for name in f.names {
			if id, ok := name.derived.(^ast.Ident); ok do add(s, id.name, Decl{type = f.type})
		}
	}
	Collect :: struct { s: ^Scope, root: ^ast.Proc_Lit }
	c := Collect{s, lit}
	v := ast.Visitor{data = &c, visit = proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil do return nil
		c := (^Collect)(v.data)
		#partial switch n in node.derived {
		case ^ast.Proc_Lit:
			if n != c.root do return nil
		case ^ast.Value_Decl:
			if !n.is_mutable do return v
			for name, i in n.names {
				id, ok := name.derived.(^ast.Ident)
				if !ok do continue
				d := Decl{type = n.type, isUsing = n.is_using}
				if n.type == nil {
					if len(n.values) == len(n.names) do d.value = n.values[i]
					else if len(n.values) == 1 { d.value = n.values[0]; d.result = i }
				}
				add(c.s, id.name, d)
				if n.is_using do append(&c.s.usings, n.type != nil ? n.type : d.value)
			}
		case ^ast.Range_Stmt:
			if len(n.vals) > 0 {
				if id, ok := n.vals[0].derived.(^ast.Ident); ok do add(c.s, id.name, Decl{value = n.expr, ranged = true})
			}
		}
		return v
	}}
	if lit.body != nil do ast.walk(&v, lit.body)
	return s
}

@(private="file")
codeModelWalkFile :: proc(m: ^CodeModel, fi: int, f: ^CodeFile) {
	context.allocator = m.allocator
	skip := make(map[^ast.Ident]bool)
	w := new(Walker)
	w^ = Walker{m = m, file = fi, skip = &skip}
	v := new(ast.Visitor)
	v^ = ast.Visitor{data = w, visit = walkVisit}
	for decl in f.file.decls do ast.walk(v, decl)
}

@(private="file")
emit :: proc(w: ^Walker, ident: ^ast.Ident, meaning: Meaning, owner: string) {
	if ident == nil || ident.name == "" || ident.name == "_" do return
	append(&w.m.occurrences, Occurrence{
		file = w.file, line = ident.pos.line - 1, column = ident.pos.column - 1, endColumn = ident.pos.column - 1 + len(ident.name),
		meaning = meaning, owner = owner, name = ident.name,
	})
}

@(private="file")
walkVisit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil
	w := (^Walker)(v.data)
	m := w.m
	file := &m.files[w.file]
	env := Env{m, file, w.scope}
	#partial switch n in node.derived {
	case ^ast.Proc_Lit:
		// Its own names (a literal doesn't see its parent's locals)
		inner := new(Walker, m.allocator)
		inner^ = w^
		inner.scope = scopeOf(m, n)
		nv := new(ast.Visitor, m.allocator)
		nv^ = ast.Visitor{data = inner, visit = walkVisit}
		return nv
	case ^ast.Value_Decl:
		// `Hero :: struct {...}`: its fields are Hero's
		if !n.is_mutable && len(n.names) == 1 && len(n.values) == 1 {
			if st, ok := n.values[0].derived.(^ast.Struct_Type); ok {
				if id, isIdent := n.names[0].derived.(^ast.Ident); isIdent {
					emit(w, id, .Type, id.name)
					w.skip[id] = true
					if st.fields != nil do for f in st.fields.list {
						for name in f.names {
							if fid, isField := name.derived.(^ast.Ident); isField {
								emit(w, fid, .Field, id.name)
								w.skip[fid] = true
							}
						}
						tagKinds(w, f)
					}
				}
			}
		}
	case ^ast.Struct_Type:
		// Another struct (a literal's type, nested): its field names aren't anything renamed
		if n.fields != nil do for f in n.fields.list do for name in f.names {
			if fid, ok := name.derived.(^ast.Ident); ok && fid not_in w.skip do w.skip[fid] = true
		}
	case ^ast.Field_List:
		// Parameters' names
		for f in n.list do for name in f.names {
			if fid, ok := name.derived.(^ast.Ident); ok && fid not_in w.skip do w.skip[fid] = true
		}
	case ^ast.Selector_Expr:
		if n.field == nil do break
		w.skip[n.field] = true
		if pkg, ok := n.expr.derived.(^ast.Ident); ok && pkg.name in file.imports && !nameDeclared(env, pkg.name) {
			// Another package's name (`e.Sprite`): neither
			w.skip[pkg] = true
			break
		}
		base := typeOf(env, n.expr)
		owner := structName(m, base)
		if owner != "" {
			if o, _, found := fieldOf(m, owner, n.field.name); found do owner = o
		} else if isForeign(m, base) {
			// Known to be another package's (the engine's): not the package's field
			owner = "-"
		}
		emit(w, n.field, .Field, owner)
	case ^ast.Implicit_Selector_Expr:
		if n.field != nil do w.skip[n.field] = true
	case ^ast.Comp_Lit:
		owner := n.type != nil ? structName(m, n.type) : ""
		for elem in n.elems {
			fv, ok := elem.derived.(^ast.Field_Value)
			if !ok do continue
			if key, isIdent := fv.field.derived.(^ast.Ident); isIdent {
				w.skip[key] = true
				if owner != "" do emit(w, key, .Field, owner)
			}
		}
	case ^ast.Call_Expr:
		// Named arguments are parameters' names
		for arg in n.args {
			if fv, ok := arg.derived.(^ast.Field_Value); ok {
				if key, isIdent := fv.field.derived.(^ast.Ident); isIdent do w.skip[key] = true
			}
		}
		// An engine call's string literals (event names: "script.onHit")
		if sel, ok := n.expr.derived.(^ast.Selector_Expr); ok && file.alias != "" {
			if pkg, isIdent := sel.expr.derived.(^ast.Ident); isIdent && pkg.name == file.alias {
				for arg in n.args {
					value := arg
					if fv, named := arg.derived.(^ast.Field_Value); named do value = fv.value
					lit, isLit := value.derived.(^ast.Basic_Lit)
					if !isLit || lit.tok.kind != .String || len(lit.tok.text) < 2 || lit.tok.text[0] != '"' do continue
					content := lit.tok.text[1:len(lit.tok.text) - 1]
					if strings.index_byte(content, '\\') >= 0 do continue
					append(&m.occurrences, Occurrence{
						file = w.file, line = lit.pos.line - 1, column = lit.pos.column, endColumn = lit.pos.column + len(content),
						meaning = .Engine_String, name = content,
					})
				}
			}
		}
	case ^ast.Ident:
		if n in w.skip do break
		// A local of the same name hides the package's type
		if w.scope != nil && n.name in w.scope.names do break
		if n.name in m.structs {
			emit(w, n, .Type, n.name)
		} else if w.scope != nil && n.name not_in m.globals {
			// A field of a `using` parameter's struct
			for u in w.scope.usings {
				if owner := structName(m, u); owner != "" {
					if o, _, found := fieldOf(m, owner, n.name); found {
						emit(w, n, .Field, o)
						break
					}
				}
			}
		}
	}
	return v
}

// A struct field's tag's `kind=<Type>` (a data asset field naming its data type)
@(private="file")
tagKinds :: proc(w: ^Walker, f: ^ast.Field) {
	text := f.tag.text
	if len(text) < 2 do return
	at := 0
	for {
		i := strings.index(text[at:], "kind=")
		if i < 0 do return
		start := at + i + len("kind=")
		end := start
		for end < len(text) && (text[end] == '_' || text[end] >= 'a' && text[end] <= 'z' || text[end] >= 'A' && text[end] <= 'Z' || text[end] >= '0' && text[end] <= '9') do end += 1
		if end > start && (at + i == 0 || text[at + i - 1] == ' ' || text[at + i - 1] == '"') {
			append(&w.m.occurrences, Occurrence{
				file = w.file, line = f.tag.pos.line - 1, column = f.tag.pos.column - 1 + start, endColumn = f.tag.pos.column - 1 + end,
				meaning = .Tag_Kind, name = text[start:end],
			})
		}
		at = end
		if at >= len(text) do return
	}
}

// --- what's at a position, and renames ------------------------------------------------------

// The registered type of that name: its kind (scripts first, then node types, then data types)
@(private)
registeredKind :: proc(index: ^ScriptIndex, catalog: ^ScriptCatalog, name: string) -> (IndexRegistrationKind, bool) {
	for _, &f in index.files do for r in f.registrations do if r.name == name do return r.kind, true
	if catalog != nil {
		if ScriptCatalog_Find(catalog, name) != nil do return .Script, true
		if ScriptCatalog_FindNodeType(catalog, name) != nil do return .NodeType, true
		for d in catalog.dataTypes do if d.name == name do return .Data, true
	}
	return .Script, false
}

/*
What's at a position of a script file: a registered type's name, or one of its exported fields or
events (declared, used through a receiver whose type the code shows, in a composite literal).

Inputs:
- sources: Every file of the scripts package (the code tabs' text for open ones)
- path: The file asked about (one of `sources`), and the 0-based line and byte column
- index, catalog: Which types are registered, and their fields and events (the catalog: built or
  from the source)

Returns:
- The symbol (temp allocated), `kind = .None` when it's nothing the project stores
*/
ScriptRename_SymbolAt :: proc(sources: []CodeSource, path: string, line, column: int, index: ^ScriptIndex, catalog: ^ScriptCatalog) -> ScriptSymbol {
	m := codeModelBuild(sources)
	if m == nil do return {}
	defer codeModelDestroy(m)
	fi := -1
	for f, i in m.files do if f.path == path do fi = i
	if fi < 0 do return {}
	for o in m.occurrences {
		if o.file != fi || o.line != line || column < o.column || column > o.endColumn do continue
		#partial switch o.meaning {
		case .Type:
			kind, registered := registeredKind(index, catalog, o.name)
			if !registered do continue
			return {kind = .Type, owner = strings.clone(o.name, context.temp_allocator), ownerKind = kind, line = o.line, start = o.column, end = o.endColumn}
		case .Field:
			if o.owner == "" do continue
			kind, registered := registeredKind(index, catalog, o.owner)
			if !registered do continue
			symbol := symbolKindOf(catalog, o.owner, o.name)
			if symbol == .None do continue
			return {kind = symbol, owner = strings.clone(o.owner, context.temp_allocator), ownerKind = kind, field = strings.clone(o.name, context.temp_allocator), line = o.line, start = o.column, end = o.endColumn}
		}
	}
	return {}
}

// Whether a type's field is exported or an event (the catalog's description), or neither
@(private="file")
symbolKindOf :: proc(catalog: ^ScriptCatalog, owner, field: string) -> ScriptSymbolKind {
	if catalog == nil do return .None
	descs := [3][]ScriptDesc{catalog.scripts[:], catalog.nodeTypes[:], catalog.dataTypes[:]}
	for list in descs do for &d in list {
		if d.name != owner do continue
		for f in d.fields do if f.name == field do return .Field
		for ev in d.events do if Event_ShortName(ev.name) == field do return .Event
	}
	return .None
}

/*
The code side of renaming a symbol: every edit to the package's files (a type: every identifier
naming it, and `kind=` in tags; a field: its declaration and its uses through a known receiver;
an event: those and the engine calls' "script.<name>" strings), or why it can't be renamed.

Inputs:
- sources: Every file of the scripts package (the code tabs' text for open ones)
- symbol: What's renamed (ScriptRename_SymbolAt's)
- newName: The new name (an identifier)

Returns:
- The edits (temp allocated), the uses left alone, and a problem when the name is taken
*/
ScriptRename_Code :: proc(sources: []CodeSource, symbol: ScriptSymbol, newName: string) -> CodeRename {
	out := CodeRename{edits = make([dynamic]CodeEdit, context.temp_allocator), unsure = make([dynamic]string, context.temp_allocator)}
	m := codeModelBuild(sources)
	if m == nil {
		out.problem = "The scripts couldn't be read"
		return out
	}
	defer codeModelDestroy(m)
	// The new name mustn't be taken
	switch symbol.kind {
	case .None:
		out.problem = "Nothing to rename"
		return out
	case .Type:
		for f in m.files {
			for decl in f.file.decls {
				vd, ok := decl.derived.(^ast.Value_Decl)
				if !ok do continue
				for name in vd.names {
					if id, isIdent := name.derived.(^ast.Ident); isIdent && id.name == newName {
						out.problem = fmt.tprintf("%s is already declared in %s (line %d)", newName, filepath.base(f.path), id.pos.line)
						return out
					}
				}
			}
		}
	case .Field, .Event:
		if _, _, taken := fieldOf(m, symbol.owner, newName); taken {
			out.problem = fmt.tprintf("%s already has a field %s", symbol.owner, newName)
			return out
		}
	}
	oldEvent := strings.concatenate({e.SCRIPT_EVENT_PREFIX, symbol.field}, context.temp_allocator)
	newEvent := strings.concatenate({e.SCRIPT_EVENT_PREFIX, newName}, context.temp_allocator)
	for o in m.occurrences {
		path := m.files[o.file].path
		edit := CodeEdit{path = strings.clone(path, context.temp_allocator), line = o.line, column = o.column, endColumn = o.endColumn, text = strings.clone(newName, context.temp_allocator)}
		switch symbol.kind {
		case .None:
		case .Type:
			if (o.meaning == .Type || o.meaning == .Tag_Kind) && o.name == symbol.owner do append(&out.edits, edit)
		case .Field, .Event:
			#partial switch o.meaning {
			case .Field:
				if o.name != symbol.field do continue
				if o.owner == symbol.owner do append(&out.edits, edit)
				else if o.owner == "" do append(&out.unsure, fmt.tprintf("%s:%d", filepath.base(path), o.line + 1))
			case .Engine_String:
				if symbol.kind == .Event && o.name == oldEvent {
					edit.text = strings.clone(newEvent, context.temp_allocator)
					append(&out.edits, edit)
				}
			}
		}
	}
	slice.sort_by(out.edits[:], proc(a, b: CodeEdit) -> bool {
		if a.path != b.path do return a.path < b.path
		if a.line != b.line do return a.line < b.line
		return a.column < b.column
	})
	// The same name reached twice (a parent and a child both saw it)
	unique := make([dynamic]CodeEdit, context.temp_allocator)
	for e in out.edits {
		if n := len(unique); n > 0 && unique[n - 1].path == e.path && unique[n - 1].line == e.line && unique[n - 1].column == e.column do continue
		append(&unique, e)
	}
	out.edits = unique
	return out
}

/*
The type the code shows for the name at a position (a struct's field, a parameter, a local, a
`self.door` selector), as written: `^e.Door` for `door: ^e.Door`, `e.Sprite` for a local
declared from a field of that type. The docs window's "Open Docs" in a code tab follows it to the
type's page (docs.odin's `Docs_TypeAddress`).

Inputs:
- sources: The scripts package's files
- path: The file asked about (absolute)
- line, column: The position (0-based line, byte column inside the name or right after it)

Returns:
- The type's text ("" when the code doesn't show it; temp allocated) and the file's import name
  of the engine
*/
ScriptCode_TypeAt :: proc(sources: []CodeSource, path: string, line, column: int) -> (typeText, alias: string) {
	m := codeModelBuild(sources)
	if m == nil do return
	defer codeModelDestroy(m)
	fi := -1
	for f, i in m.files do if f.path == path do fi = i
	if fi < 0 do return
	alias = strings.clone(m.files[fi].alias, context.temp_allocator)
	Finder :: struct {
		m: ^CodeModel,
		file: ^CodeFile,
		scope: ^Scope,
		line, column: int,
		found: ^^ast.Expr,
		done: ^bool,
	}
	found: ^ast.Expr
	done := false
	finder := new(Finder, m.allocator)
	finder^ = Finder{m = m, file = &m.files[fi], line = line, column = column, found = &found, done = &done}
	spans :: proc(f: ^Finder, ident: ^ast.Ident) -> bool {
		if ident == nil do return false
		start := ident.pos.column - 1
		return ident.pos.line - 1 == f.line && f.column >= start && f.column <= start + len(ident.name)
	}
	visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		f := (^Finder)(v.data)
		if node == nil || f.done^ do return nil
		env := Env{f.m, f.file, f.scope}
		take :: proc(f: ^Finder, t: ^ast.Expr) {
			f.found^ = t
			f.done^ = true
		}
		#partial switch n in node.derived {
		case ^ast.Proc_Lit:
			inner := new(Finder, f.m.allocator)
			inner^ = f^
			inner.scope = scopeOf(f.m, n)
			nv := new(ast.Visitor, f.m.allocator)
			nv^ = ast.Visitor{data = inner, visit = v.visit}
			return nv
		case ^ast.Field_List:
			// Struct fields and parameters: their declared type
			for field in n.list do for name in field.names {
				if id, ok := name.derived.(^ast.Ident); ok && spans(f, id) {
					take(f, field.type)
					return nil
				}
			}
		case ^ast.Value_Decl:
			for name, i in n.names {
				id, ok := name.derived.(^ast.Ident)
				if !ok || !spans(f, id) do continue
				if n.type != nil do take(f, n.type)
				else if i < len(n.values) do take(f, typeOf(env, n.values[i]))
				else do f.done^ = true
				return nil
			}
		case ^ast.Selector_Expr:
			if n.field != nil && spans(f, n.field) {
				take(f, typeOf(env, n))
				return nil
			}
		case ^ast.Ident:
			if spans(f, n) {
				take(f, nameType(env, n.name, 0))
				return nil
			}
		}
		return v
	}
	v := new(ast.Visitor, m.allocator)
	v^ = ast.Visitor{data = finder, visit = visit}
	for decl in m.files[fi].file.decls {
		ast.walk(v, decl)
		if done do break
	}
	if found == nil || found == m.otherPackage do return "", alias
	// The type's text, from the file it's written in (a field of a struct in another file)
	for cf in m.files {
		if cf.path != found.pos.file do continue
		if found.pos.offset >= 0 && found.end.offset <= len(cf.text) && found.pos.offset < found.end.offset {
			return strings.clone(cf.text[found.pos.offset:found.end.offset], context.temp_allocator), alias
		}
	}
	return "", alias
}
