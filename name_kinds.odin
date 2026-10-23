package crossfire_editor

import "base:runtime"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import vmem "core:mem/virtual"
import "gui:skald"

/*
Which engine procedures take which kind of name, read from the engine's own source: its name
types (the engine's names.odin: `NodePath :: string`, `SceneName :: string`...) are aliases of
`string` that its procedures' parameters use (`Game_ChangeScene :: proc(game: ^Game, name:
SceneName, ...)`). The code editor's name providers (code_names.odin) complete and check string
literals passed there.

- **Read once** from the engine the editor builds with (`Toolchain_EngineDir`) with
  `core:odin/parser`, on a worker (`NameTable_Start`, from the script index's tick); only files
  naming a name type are parsed (other files' procedure groups are read from their text). Until
  it's there, the providers answer nothing.
- **Procedure groups** (`AnimationPlayer_Play :: proc{PlayByName, PlayByIndex}`) take their
  members' name parameters, by position and by name (the first member with one wins).
- **Declaring procedures** (the engine's rule: `_Add` or `_Create` in the name, as
  `Node_AddToGroup`, `Audio_AddBus`, `Game_CreateScene`) name something new: completed, never
  reported, and what they're given counts as known.
- The table is never freed (one per run, on the heap: tests on several threads share it).
*/

// What kind of name a parameter takes (the engine's name types)
NameKind :: enum {
	None,
	Node_Path,
	Child_Path,
	Scene_Path,
	Animation,
	Action,
	Group,
	Bus,
	Scene,
	State,
	State_Param,
	Clip,
	Dialogue_Node,
	Achievement,
	Sound_Path,
}

// The engine's type for each kind (names.odin)
NAME_KIND_TYPES := [NameKind]string{
	.None          = "",
	.Node_Path     = "NodePath",
	.Child_Path    = "ChildPath",
	.Scene_Path    = "ScenePath",
	.Animation     = "AnimationName",
	.Action        = "ActionName",
	.Group         = "GroupName",
	.Bus           = "BusName",
	.Scene         = "SceneName",
	.State         = "StateName",
	.State_Param   = "StateParamName",
	.Clip          = "ClipName",
	.Dialogue_Node = "DialogueNodeName",
	.Achievement   = "AchievementName",
	.Sound_Path    = "SoundPath",
}

// What a kind of name is, in a sentence's words ("scene", "input action")
NAME_KIND_WORDS := [NameKind]string{
	.None          = "name",
	.Node_Path     = "node",
	.Child_Path    = "child node",
	.Scene_Path    = "node",
	.Animation     = "animation",
	.Action        = "input action",
	.Group         = "group",
	.Bus           = "bus",
	.Scene         = "scene",
	.State         = "state",
	.State_Param   = "state machine parameter",
	.Clip          = "clip",
	.Dialogue_Node = "dialogue node",
	.Achievement   = "achievement",
	.Sound_Path    = "sound file",
}

// One name parameter of a procedure
NameParam :: struct {
	// Its position among the parameters (0-based) and its name
	index: int,
	name:  string,
	kind:  NameKind,
}

// An engine procedure (or group) with name parameters
NameProc :: struct {
	name:     string,
	params:   []NameParam,
	// It declares the names it's given (`_Add` / `_Create` in its name)
	declares: bool,
}

// Every engine procedure with a name parameter (NameTable_Get)
NameTable :: struct {
	procs: map[string]NameProc,
	// The engine folder it was read from, how many files were parsed and how long it took
	engineDir: string,
	files:     int,
	took:      time.Duration,
}

@(private="file")
nameTables: struct {
	lock:    sync.Mutex,
	table:   ^NameTable,
	loading: bool,
}

// The table, or nil while it isn't read yet
NameTable_Get :: proc() -> ^NameTable {
	sync.guard(&nameTables.lock)
	return nameTables.table
}

/*
Reads the table from an engine folder now, unless it's already read (tests; the worker's job).

Returns:
- The table (nil when the folder has no name types)
*/
NameTable_Load :: proc(engineDir: string) -> ^NameTable {
	if t := NameTable_Get(); t != nil do return t
	table := NameTable_Read(engineDir, runtime.heap_allocator())
	sync.guard(&nameTables.lock)
	nameTables.loading = false
	if nameTables.table == nil do nameTables.table = table
	return nameTables.table
}

// The worker's answer: the table was read (the providers ask again)
NameTable_Loaded :: struct {}

/*
Starts reading the table on a worker, once (the script index's tick).

Returns:
- The worker's command, or nothing when it's read or being read
*/
NameTable_Start :: proc() -> skald.Command(Msg) {
	{
		sync.guard(&nameTables.lock)
		if nameTables.table != nil || nameTables.loading do return {}
		nameTables.loading = true
	}
	dir, _ := Toolchain_EngineDir()
	Job :: struct { dir: string }
	return skald.cmd_thread(Msg, Job{strings.clone(dir)}, proc(job: Job) -> Msg {
		NameTable_Load(job.dir)
		delete(job.dir)
		return NameTable_Loaded{}
	})
}

/*
Reads which procedures of an engine folder take which kind of name (pure: tests call it).

Inputs:
- engineDir: The engine's folder (its top-level .odin files, tests left out)
- allocator: For the table and everything in it

Returns:
- The table (nil when the folder can't be read or declares no name types)
*/
NameTable_Read :: proc(engineDir: string, allocator := context.allocator) -> ^NameTable {
	start := time.tick_now()
	entries, err := os.read_all_directory_by_path(engineDir, context.temp_allocator)
	if err != nil do return nil
	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil do return nil
	defer vmem.arena_destroy(&arena)
	scratch := vmem.arena_allocator(&arena)

	kindOf :: proc(type: ^ast.Expr) -> NameKind {
		if type == nil do return .None
		ident, ok := type.derived.(^ast.Ident)
		if !ok do return .None
		for name, kind in NAME_KIND_TYPES do if kind != .None && name == ident.name do return kind
		return .None
	}
	Found :: struct { params: [dynamic]NameParam }
	procs := make(map[string]Found, allocator = scratch)
	groups := make(map[string][dynamic]string, allocator = scratch)
	aliases := 0
	files := 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") do continue
		data, readErr := os.read_entire_file(entry.fullpath, scratch)
		if readErr != nil do continue
		text := string(data)
		named := false
		for name in NAME_KIND_TYPES do if name != "" && strings.contains(text, name) { named = true; break }
		if !named {
			// Only procedure groups to look at: read from the text (`Name :: proc{A, B}`, one line)
			rest := text
			for line in strings.split_lines_iterator(&rest) {
				name, sep, value := strings.partition(line, " :: proc")
				if sep == "" || strings.contains(name, " ") || strings.contains(name, "\t") do continue
				value = strings.trim_left_space(value)
				if !strings.has_prefix(value, "{") || !strings.has_suffix(strings.trim_space(value), "}") do continue
				members := make([dynamic]string, scratch)
				inner := strings.trim_space(value)
				inner = inner[1:len(inner) - 1]
				for m in strings.split_iterator(&inner, ",") do if m := strings.trim_space(m); m != "" do append(&members, m)
				groups[name] = members
			}
			continue
		}
		files += 1
		context.allocator = scratch
		file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
		file.src = text
		file.fullpath = entry.fullpath
		p := parser.default_parser()
		p.err = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
		p.warn = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
		parser.parse_file(&p, file)
		for decl in file.decls {
			vd, isValue := decl.derived.(^ast.Value_Decl)
			if !isValue || vd.is_mutable || len(vd.names) != 1 || len(vd.values) != 1 do continue
			ident, isIdent := vd.names[0].derived.(^ast.Ident)
			if !isIdent do continue
			#partial switch v in vd.values[0].derived {
			case ^ast.Ident:
				if v.name == "string" do for name in NAME_KIND_TYPES do if name == ident.name do aliases += 1
			case ^ast.Proc_Lit:
				type, ok := v.type.derived.(^ast.Proc_Type)
				if !ok || type.params == nil do continue
				found := Found{params = make([dynamic]NameParam, scratch)}
				index := 0
				for field in type.params.list {
					kind := kindOf(field.type)
					for name in field.names {
						defer index += 1
						if kind == .None do continue
						n, isName := name.derived.(^ast.Ident)
						if isName do append(&found.params, NameParam{index, n.name, kind})
					}
				}
				if len(found.params) > 0 do procs[ident.name] = found
			case ^ast.Proc_Group:
				members := make([dynamic]string, scratch)
				for arg in v.args do if m, isName := arg.derived.(^ast.Ident); isName do append(&members, m.name)
				groups[ident.name] = members
			}
		}
	}
	if aliases == 0 do return nil
	context.allocator = allocator
	table := new(NameTable)
	table.procs = make(map[string]NameProc)
	table.engineDir = strings.clone(engineDir)
	table.files = files
	add :: proc(table: ^NameTable, name: string, params: []NameParam) {
		out := make([]NameParam, len(params))
		for p, i in params do out[i] = {p.index, strings.clone(p.name), p.kind}
		declares := strings.contains(name, "_Add") || strings.contains(name, "_Create")
		table.procs[strings.clone(name)] = NameProc{name = strings.clone(name), params = out, declares = declares}
	}
	for name, found in procs do add(table, name, found.params[:])
	for name, members in groups {
		merged := make([dynamic]NameParam, context.temp_allocator)
		for m in members {
			found, ok := procs[m]
			if !ok do continue
			for p in found.params {
				taken := false
				for q in merged do if q.index == p.index || q.name == p.name do taken = true
				if !taken do append(&merged, p)
			}
		}
		if len(merged) > 0 do add(table, name, merged[:])
	}
	table.took = time.tick_since(start)
	return table
}

/*
What a procedure's argument takes.

Inputs:
- procName: The engine procedure as called, without its package (`Game_ChangeScene`)
- index: The argument's position (positional arguments)
- argName: A named argument's name (`bus = "SFX"`), "" for a positional one

Returns:
- The kind (`.None`: not a name), and whether the procedure declares it
*/
NameTable_ParamKind :: proc(table: ^NameTable, procName: string, index: int, argName := "") -> (kind: NameKind, declares: bool) {
	if table == nil do return .None, false
	p, ok := table.procs[procName]
	if !ok do return .None, false
	for param in p.params {
		if argName != "" ? param.name == argName : param.index == index do return param.kind, p.declares && param.kind != .Sound_Path
	}
	return .None, false
}
