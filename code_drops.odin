package crossfire_editor

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import e "engine:."

/*
Drops into code: every editor thing dragged onto a code tab becomes code (round 4 of TODO.md's
"Code editor integration"; the manual's code editor page has the table users read).

- **Sources describe themselves** (`DropSource`): what kind of thing it is, its name, the node of
  the open scene it belongs to (a property's or an animation's), an asset or scene, and a detail
  (a parameter's kind, an event's data hint). Panels make one when a drag starts (code_drag.odin)
  and know nothing about code.
- **One table says what each kind is** (`CODE_DROP_KINDS`): its name type (the engine's names.odin,
  so its typed constants and the parameters it fits), and its shape in a struct. **What code does
  with it is the engine's** (`e.CODE_USES`, code_uses.odin: the uses of a name type, a handle
  type, a node type or a node type's field); `codeUseKeys` says which apply to a source.
- **Where it lands decides the shape** (`ce.Syntax_Context`):
  - in a struct (or anywhere outside a procedure): a field, before the struct's closing brace
  - in a procedure's body: a statement on its own line (a condition becomes an `if` block, a value
    a `x :=` line), after the line it was dropped on, indented like it
  - on a call's argument: the constant (its typed constant, or a string literal when there's none),
    or the expression (`self.hero`, `self.hero.position`) when the parameter doesn't take that
    kind of name; inside a string, the name itself
  - in a comment: the constant
- **A plain drop does the first choice; Shift opens the menu** of at most `CODE_DROP_MAX_CHOICES`,
  each with a preview (code_editor's drop menu).
- **Code uses what the script has**: the procedure's script parameter (`self`, from the
  procedure's parameter list), a node field whose default path leads to the node (or, for a thing
  without a node, the only field of the type), else it **adds the field** in the same undo step
  (as a node dropped in the struct would). A thing needing a node of a type the script can't
  reach (no field, no such node in the scene) leaves that choice out.
*/

// What kind of thing is dropped on a code tab
DropSourceKind :: enum {
	// A scene tree node
	Node,
	// An inspector property of a node (Position, Visible...): `name` is its label
	Property,
	// An exported field of a node's script: `name` the field, `script` the script
	Script_Field,
	// An event of a node (`name`: "onExit", "animation.onAnimationEnded", "script.onHit"; `detail` its data hint)
	Event,
	Animation,
	State,
	// A state machine parameter (`detail`: its kind, Float / Bool / Trigger)
	State_Param,
	Action,
	Group,
	Bus,
	// An Animator's clip
	Clip,
	// A scene (`index` into project.scenes)
	Scene,
	// A browser asset (`index` into project.assets): images, sounds, music, components, dialogues...
	Asset,
}

/*
Something dragged onto a code tab, as its panel describes it. Strings are the owner's (a drag
keeps clones: `DropSource_Clone`).
*/
DropSource :: struct {
	kind:   DropSourceKind,
	// Its name: the node's, the animation's, the action's...; a property's label
	name:   string,
	// The node of the open scene it is or belongs to (an animation's sprite, a state's machine, a
	// clip's Animator, a property's node; -1: none)
	node:   int,
	// A scene or an asset (index; -1: none)
	index:  int,
	// The script a field or event belongs to ("" none)
	script: string,
	// A parameter's kind, an event's data hint ("" none)
	detail: string,
}

// A copy of a source with its own strings
DropSource_Clone :: proc(src: DropSource, allocator := context.allocator) -> DropSource {
	out := src
	out.name = strings.clone(src.name, allocator)
	out.script = strings.clone(src.script, allocator)
	out.detail = strings.clone(src.detail, allocator)
	return out
}

// Frees a source's strings
DropSource_Destroy :: proc(src: ^DropSource) {
	delete(src.name)
	delete(src.script)
	delete(src.detail)
	src^ = {}
}

// How a kind of thing goes into a struct
CodeStructShape :: enum {
	// A node field of the node's type, defaulting to its path (node_fields.odin)
	Node_Field,
	// A field of the asset's handle type (asset_fields.odin); assets without one: a name field
	Asset_Field,
	// A field of the name type, exported, defaulting to the name (`jumpAction: e.ActionName`)
	Name_Field,
	// A node field for the node it belongs to
	Owner_Field,
}

// What a kind of thing is, for drops (CODE_DROP_KINDS)
CodeDropKind :: struct {
	// In a sentence ("input action")
	noun:        string,
	// Its name type (its constants, the parameters it fits, the engine's uses); .None: not a name
	nameKind:    NameKind,
	inStruct:    CodeStructShape,
	// A name field's name after the name ("Action": jumpAction)
	fieldSuffix: string,
}

/*
The one table of drops: what each kind of thing is. What code does with it comes from the engine
(`e.CODE_USES`, by `codeUseKeys`); a new kind needs a row here, its panel's source, and uses in
the engine.
*/
CODE_DROP_KINDS := [DropSourceKind]CodeDropKind{
	.Node         = {"node", .Node_Path, .Node_Field, ""},
	.Property     = {"property", .None, .Owner_Field, ""},
	.Script_Field = {"script field", .None, .Owner_Field, ""},
	.Event        = {"event", .None, .Owner_Field, ""},
	.Animation    = {"animation", .Animation, .Name_Field, "Animation"},
	.State        = {"state", .State, .Name_Field, "State"},
	.State_Param  = {"state machine parameter", .State_Param, .Name_Field, "Param"},
	.Action       = {"input action", .Action, .Name_Field, "Action"},
	.Group        = {"group", .Group, .Name_Field, "Group"},
	.Bus          = {"bus", .Bus, .Name_Field, "Bus"},
	.Clip         = {"clip", .Clip, .Name_Field, "Clip"},
	.Scene        = {"scene", .Scene, .Name_Field, "Scene"},
	.Asset        = {"asset", .None, .Asset_Field, ""},
}

// The most choices a drop's menu lists
CODE_DROP_MAX_CHOICES :: 4

// What the code editor is given when something is dropped on it (`ce.Drop_Request.kind`; `data`
// points at the DropSource)
CODE_DROP_SOURCE :: "source"

/*
What a source is called in the editor's words ("animation run", "node Hero"; temp allocated).
*/
DropSource_Describe :: proc(state: ^State, src: DropSource) -> string {
	k := CODE_DROP_KINDS[src.kind]
	#partial switch src.kind {
	case .Asset:
		if src.index >= 0 && src.index < len(state.project.assets) do return fmt.tprintf("%s", filepath.base(state.project.assets[src.index].path))
	case .Scene:
		if src.index >= 0 && src.index < len(state.project.scenes) do return fmt.tprintf("scene %s", state.project.scenes[src.index].name)
	case .Property:
		return fmt.tprintf("%s's %s", codeSourceNodeName(state, src.node), strings.to_lower(src.name, context.temp_allocator))
	case .Script_Field:
		return fmt.tprintf("%s.%s", src.script, src.name)
	case .Event:
		return fmt.tprintf("%s's %s", codeSourceNodeName(state, src.node), src.name)
	}
	return fmt.tprintf("%s %s", k.noun, src.name)
}

@(private="file")
codeSourceNodeName :: proc(state: ^State, node: int) -> string {
	scene := &state.project.scenes[state.currentScene]
	return node >= 0 && node < len(scene.nodes) ? scene.nodes[node].name : "a node"
}

// The engine types a node kind is, its own first, then those it embeds ("AudioPlayer2D",
// "AudioPlayer", "Node"; temp allocated)
CodeDrops_TypeChain :: proc(kind: NodeKind) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	id := e.SCENE_NODE_TYPES[kind]
	for id != nil {
		if named, ok := type_info_of(id).variant.(runtime.Type_Info_Named); ok do append(&out, named.name)
		if !reflect.is_struct(type_info_of(id)) || len(reflect.struct_field_names(id)) == 0 do break
		first := reflect.struct_field_at(id, 0)
		if !first.is_using do break
		id = first.type.id
	}
	return out[:]
}

// A struct's field by name, also through its `using` fields (reflect's own looks at its fields only)
@(private="file")
fieldByName :: proc(id: typeid, name: string, depth := 0) -> reflect.Struct_Field {
	if depth > 6 || !reflect.is_struct(type_info_of(id)) do return {}
	for f in reflect.struct_fields_zipped(id) {
		if f.name == name do return f
	}
	for f in reflect.struct_fields_zipped(id) do if f.is_using {
		if found := fieldByName(f.type.id, name, depth + 1); found.name != "" do return found
	}
	return {}
}

// The most basic of a node kind's types that has a field ("position": "Node"; "size" on a
// Label: "Label"): the type code reaching it needs ("Node" when none has it)
@(private="file")
fieldOwnerType :: proc(kind: NodeKind, field: string) -> string {
	owner := "Node"
	id := e.SCENE_NODE_TYPES[kind]
	for id != nil {
		named, isNamed := type_info_of(id).variant.(runtime.Type_Info_Named)
		if !reflect.is_struct(type_info_of(id)) do break
		// Its own field (not one through `using`)
		if isNamed do for name in reflect.struct_field_names(id) do if name == field do owner = named.name
		if len(reflect.struct_field_names(id)) == 0 do break
		first := reflect.struct_field_at(id, 0)
		if !first.is_using do break
		id = first.type.id
	}
	return owner
}

// What an inspector label is called in code where the words differ (a type, the label, the
// field): "Font size" on a Label is `size`
@(private="file")
PROPERTY_ALIASES := [?][3]string{
	{"Label", "Font size", "size"},
	{"Node", "Blend", "blendMode"},
	{"Node", "Process", "processMode"},
}

/*
The engine field an inspector property label stands for on a node kind: the label in
lowerCamelCase ("Z index": zIndex) or an alias, a field of the kind's type or of a type it
embeds (`using`); "Position X" is `position.x`. Only plain values (numbers, booleans, text,
vectors, enums, colors) count.

Returns:
- The field as code writes it after the node ("position.x"), its type, and false when the node's
  type has no such field (the label can't be dragged)
*/
CodeDrops_PropertyField :: proc(kind: NodeKind, label: string) -> (field: string, type: ^reflect.Type_Info, ok: bool) {
	label := label
	component := ""
	if strings.has_suffix(label, " X") || strings.has_suffix(label, " Y") {
		component = strings.to_lower(label[len(label) - 1:], context.temp_allocator)
		label = label[:len(label) - 2]
	}
	name := ""
	for alias in PROPERTY_ALIASES do for t in CodeDrops_TypeChain(kind) do if t == alias[0] && label == alias[1] do name = alias[2]
	if name == "" {
		b := strings.builder_make(context.temp_allocator)
		upper := false
		for r in label {
			if r == ' ' || r == '-' {
				upper = strings.builder_len(b) > 0
				continue
			}
			if strings.builder_len(b) == 0 do strings.write_rune(&b, r >= 'A' && r <= 'Z' ? r + 32 : r)
			else do strings.write_rune(&b, upper && r >= 'a' && r <= 'z' ? r - 32 : r)
			upper = false
		}
		name = strings.to_string(b)
	}
	if name == "" do return "", nil, false
	f := fieldByName(e.SCENE_NODE_TYPES[kind], name)
	if f.name == "" || f.type == nil do return "", nil, false
	type = f.type
	base := reflect.type_info_base(type)
	#partial switch v in base.variant {
	case reflect.Type_Info_Boolean, reflect.Type_Info_Integer, reflect.Type_Info_Float, reflect.Type_Info_String, reflect.Type_Info_Enum:
	case reflect.Type_Info_Array:
		if component != "" {
			if v.count < 2 do return "", nil, false
			return fmt.tprintf("%s.%s", f.name, component), v.elem, true
		}
	case reflect.Type_Info_Struct:
		// sdl.Color and such: a struct of numbers
		for t in v.types[:v.field_count] {
			#partial switch _ in reflect.type_info_base(t).variant {
			case reflect.Type_Info_Integer, reflect.Type_Info_Float:
			case: return "", nil, false
			}
		}
	case:
		return "", nil, false
	}
	if component != "" do return "", nil, false
	return f.name, type, true
}

/*
The keys of the engine's uses (`e.CODE_USES`) that apply to a source, the most specific first:
a name's type ("StateParamName:Trigger", then "StateParamName"), an asset's handle type, a
node's types, a property's field on each of them.
*/
codeUseKeys :: proc(state: ^State, src: DropSource) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	k := CODE_DROP_KINDS[src.kind]
	scene := &state.project.scenes[state.currentScene]
	#partial switch src.kind {
	case .Node:
		if src.node >= 0 && src.node < len(scene.nodes) do append(&out, ..CodeDrops_TypeChain(NodeDef_BuiltKind(&state.project, &scene.nodes[src.node])))
	case .Property:
		if src.node < 0 || src.node >= len(scene.nodes) do break
		kind := NodeDef_BuiltKind(&state.project, &scene.nodes[src.node])
		field, _, ok := CodeDrops_PropertyField(kind, src.name)
		base, _, _ := strings.partition(field, ".")
		if ok do for t in CodeDrops_TypeChain(kind) do append(&out, fmt.tprintf("%s.%s", t, base))
	case .Asset:
		if src.index < 0 || src.index >= len(state.project.assets) do break
		asset := state.project.assets[src.index]
		if type, ok := AssetField_Type(asset.kind); ok do append(&out, type)
		if asset.kind == .Dialogue do append(&out, "Dialogue")
	case:
		if k.nameKind != .None {
			type := NAME_KIND_TYPES[k.nameKind]
			if src.detail != "" do append(&out, fmt.tprintf("%s:%s", type, src.detail))
			append(&out, type)
		}
	}
	return out[:]
}

// --- the drop: its context ----------------------------------------------------------------

// What a drop knows about where it landed (temp allocated)
@(private="file")
DropCtx :: struct {
	state:     ^State,
	doc:       ce.Provider_Document,
	pos:       cebuf.Position,
	syntax:    ce.Syntax_Context,
	src:       DropSource,
	scene:     ^SceneDef,
	// The engine's import name in the file
	alias:     string,
	// The script struct (none: fields can't be added)
	st:        NodeField_Struct,
	hasStruct: bool,
	// The node the script runs on (its paths start there; -1: from the top level)
	from:      int,
	// The script in the procedure ("self": its first parameter of the script's pointer type, else "self")
	recv:      string,
}

/*
Builds a drop's choices (code_providers.odin's drop provider): the plain drop first. See the
file's doc for what goes where.

Returns:
- false when the source can't go there (nothing is inserted; `out.message` may say why)
*/
CodeDrops_Build :: proc(state: ^State, doc: ce.Provider_Document, pos: cebuf.Position, syntax: ce.Syntax_Context, src: DropSource, out: ^ce.Drop_Result, allocator: runtime.Allocator) -> bool {
	c := DropCtx{state = state, doc = doc, pos = pos, syntax = syntax, src = src, alias = "e", from = -1, recv = "self"}
	c.scene = &state.project.scenes[state.currentScene]
	text := docText(doc)
	c.st, c.hasStruct = NodeField_FindStruct(text)
	if c.hasStruct {
		c.alias = c.st.engineAlias
		c.from = NodeField_From(c.scene, c.st.name, state.selectedNode)
	} else if file := ScriptIndex_File(&state.scriptIndex, absolutePath(doc.path)); file != nil && file.engineAlias != "" {
		c.alias = file.engineAlias
	}
	if c.hasStruct do c.recv = receiverOf(syntax.proc_params, c.st.name)

	choices := make([dynamic]ce.Drop_Choice, context.temp_allocator)
	switch {
	case syntax.kind == .Comment:
		if text, ok := constantOf(&c); ok do append(&choices, argumentChoice(&c, "Its constant", text))
	case syntax.kind == .Call_Argument && syntax.in_string:
		append(&choices, argumentChoice(&c, "Its name", nameInString(&c)))
	case syntax.kind == .Call_Argument:
		argumentChoices(&c, &choices)
	case syntax.kind == .Proc_Body:
		bodyChoices(&c, &choices)
	case:
		structChoices(&c, &choices)
	}
	if len(choices) == 0 {
		why := fmt.tprintf("Nothing to write for %s there", DropSource_Describe(state, src))
		if !c.hasStruct && syntax.kind != .Call_Argument && syntax.kind != .Proc_Body {
			why = fmt.tprintf("%s has no script struct (a struct with `using script: e.Script`)", filepath.base(doc.path))
		}
		out.message = strings.clone(why, allocator)
		return false
	}
	for choice, i in choices {
		if i == CODE_DROP_MAX_CHOICES do break
		append(&out.choices, choice)
	}
	return true
}

// The document's text (temp allocated)
@(private)
docText :: proc(doc: ce.Provider_Document) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< cebuf.buffer_line_count(doc.buffer) {
		if i > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, cebuf.buffer_line_str(doc.buffer, i))
	}
	return strings.to_string(b)
}

/*
The script variable of a procedure: the name of its parameter whose type is a pointer to the
script struct (`self: ^Hero`), else "self".
*/
@(private="file")
receiverOf :: proc(params, structName: string) -> string {
	rest := params
	for part in strings.split_iterator(&rest, ",") {
		name, _, type := strings.partition(part, ":")
		if strings.trim_space(type) == fmt.tprintf("^%s", structName) do return strings.trim_space(name)
	}
	return "self"
}

// Writes `e.` as the file's import name of the engine
@(private="file")
withAlias :: proc(c: ^DropCtx, code: string) -> string {
	return engineAliased(c.alias, code)
}

// Code written with `e.` for the engine, with the file's import name of it instead (temp allocated)
@(private)
engineAliased :: proc(alias, code: string) -> string {
	if alias == "e" do return code
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(code); i += 1 {
		wordStart := i == 0 || !(code[i - 1] == '_' || code[i - 1] == '.' || code[i - 1] >= 'a' && code[i - 1] <= 'z' || code[i - 1] >= 'A' && code[i - 1] <= 'Z' || code[i - 1] >= '0' && code[i - 1] <= '9')
		if wordStart && strings.has_prefix(code[i:], "e.") {
			strings.write_string(&b, alias)
			strings.write_byte(&b, '.')
			i += 1
			continue
		}
		strings.write_byte(&b, code[i])
	}
	return strings.to_string(b)
}

// --- names and constants -------------------------------------------------------------------

// The group a sprite's own animations or a machine's states are listed under in assets.odin
@(private="file")
ownerGroup :: proc(c: ^DropCtx, node: int, format: string) -> string {
	if node < 0 || node >= len(c.scene.nodes) do return ""
	label := Scene_IsComponent(c.scene) ? fmt.tprintf("component %s", ComponentName(c.scene.component)) : fmt.tprintf("scene %s", c.scene.name)
	return fmt.tprintf(format, c.scene.nodes[node].name, label)
}

/*
A source's typed constant (`ANIM_HERO_RUN`, `SOUND_JUMP`), else its name as a string literal.

Returns:
- The text, and false when the source has neither (a property, an event)
*/
@(private="file")
constantOf :: proc(c: ^DropCtx, pathKind := NameKind.Node_Path) -> (string, bool) {
	state := c.state
	src := c.src
	constants := CodeProviders_Constants(state)
	find :: proc(constants: []GeneratedConstant, section: ConstantSection, value: string, prefix := "", group := "", target := "") -> string {
		quoted := fmt.tprintf("%q", value)
		any := ""
		count := 0
		for k in constants {
			if k.section != section || k.value != quoted || !strings.has_prefix(k.name, prefix) do continue
			if group != "" && k.group == group || target != "" && k.target == target do return k.name
			any = k.name
			count += 1
		}
		return count == 1 || group == "" && target == "" ? any : ""
	}
	name := ""
	switch src.kind {
	case .Node:
		if src.node < 0 || src.node >= len(c.scene.nodes) do return "", false
		// A child path (`Node_FindChild`) is from the script's node; constants are from the top
		if pathKind == .Child_Path && c.from >= 0 && isBelow(c.scene, src.node, c.from) {
			return fmt.tprintf("%q", Scene_NodePath(c.scene, c.from, src.node, context.temp_allocator)), true
		}
		path := constantPathOf(c.scene, src.node)
		owner := Scene_IsComponent(c.scene) ? ComponentName(c.scene.component) : c.scene.name
		for k in constants do if k.section == .Node_Paths && k.value == fmt.tprintf("%q", path) && k.target == owner do return k.name, true
		return fmt.tprintf("%q", path), true
	case .Animation:
		name = find(constants, .Animations, src.name, "ANIM_", ownerGroup(c, src.node, "%s's own, in %s"), src.detail)
	case .State:
		name = find(constants, .States, src.name, "STATE_", ownerGroup(c, src.node, "%s in %s"))
	case .State_Param:
		name = find(constants, .States, src.name, "PARAM_", ownerGroup(c, src.node, "%s in %s"))
	case .Action: name = find(constants, .Actions, src.name)
	case .Group:  name = find(constants, .Groups, src.name)
	case .Bus:    name = find(constants, .Buses, src.name)
	case .Clip:
	case .Scene:
		if src.index < 0 || src.index >= len(state.project.scenes) do return "", false
		name = find(constants, .Scenes, state.project.scenes[src.index].name)
		if name == "" do return fmt.tprintf("%q", state.project.scenes[src.index].name), true
	case .Asset:
		if src.index < 0 || src.index >= len(state.project.assets) do return "", false
		asset := state.project.assets[src.index]
		handle, _ := AssetField_Type(asset.kind)
		for k in constants do if k.section == .Assets && k.target == asset.path {
			// An Aseprite file has a texture and an animations constant: the handle's
			if handle == "" || strings.contains(k.value, handle) do return k.name, true
		}
		if handle != "" do return fmt.tprintf("%s.%s{{%q}", c.alias, handle, asset.path), true
		return fmt.tprintf("%q", asset.path), true
	case .Property, .Script_Field, .Event:
		return "", false
	}
	if name != "" do return name, true
	return fmt.tprintf("%q", src.name), true
}

// Whether `node` is below `ancestor` in the scene's tree
@(private="file")
isBelow :: proc(scene: ^SceneDef, node, ancestor: int) -> bool {
	for at := scene.nodes[node].parent; at >= 0; at = scene.nodes[at].parent do if at == ancestor do return true
	return false
}

// A source's name as it goes inside a string literal (a node: its path for the parameter)
@(private="file")
nameInString :: proc(c: ^DropCtx) -> string {
	src := c.src
	#partial switch src.kind {
	case .Node:
		if src.node < 0 || src.node >= len(c.scene.nodes) do return src.name
		if paramKind(c) == .Scene_Path || c.from < 0 do return constantPathOf(c.scene, src.node)
		return Scene_NodePath(c.scene, c.from, src.node, context.temp_allocator)
	case .Scene:
		if src.index >= 0 && src.index < len(c.state.project.scenes) do return c.state.project.scenes[src.index].name
	case .Asset:
		if src.index >= 0 && src.index < len(c.state.project.assets) do return c.state.project.assets[src.index].path
	}
	return src.name
}

// The kind of name the argument under the drop takes (the engine's name types; .None: not a name)
@(private="file")
paramKind :: proc(c: ^DropCtx) -> NameKind {
	call := c.syntax.call_name
	dot := strings.last_index_byte(call, '.')
	if dot < 0 || call[:dot] != c.alias do return .None
	// A named argument (`bus = `)
	argName := ""
	line := cebuf.buffer_line_str(c.doc.buffer, c.pos.line)
	if c.syntax.arg_start.line == c.pos.line && c.syntax.arg_start.col <= c.pos.col && c.pos.col <= len(line) {
		before := strings.trim_space(line[c.syntax.arg_start.col:c.pos.col])
		if strings.has_suffix(before, "=") && !strings.has_suffix(before, "==") do argName = strings.trim_space(before[:len(before) - 1])
	}
	kind, _ := NameTable_ParamKind(NameTable_Get(), call[dot + 1:], c.syntax.argument, argName)
	return kind
}

// --- nodes in code ----------------------------------------------------------------------------

// The default path in a field's tag (`export:"default=../Camera"`), "" none
@(private="file")
fieldDefault :: proc(line: string) -> string {
	at := strings.index(line, "default=")
	if at < 0 do return ""
	rest := line[at + len("default="):]
	end := 0
	for end < len(rest) && rest[end] != ' ' && rest[end] != '"' do end += 1
	return rest[:end]
}

// A field's pointer type's name (`hero: ^e.CharacterMover` → "CharacterMover"; "" for anything else)
@(private="file")
fieldNodeType :: proc(c: ^DropCtx, line: string) -> string {
	_, _, rest := strings.partition(line, ":")
	rest = strings.trim_space(rest)
	prefix := fmt.tprintf("^%s.", c.alias)
	if !strings.has_prefix(rest, prefix) do return ""
	rest = rest[len(prefix):]
	end := 0
	for end < len(rest) && (rest[end] == '_' || rest[end] >= 'a' && rest[end] <= 'z' || rest[end] >= 'A' && rest[end] <= 'Z' || rest[end] >= '0' && rest[end] <= '9') do end += 1
	return rest[:end]
}

// The edits that add a node field for `node` to the script struct (the comma the field above
// needs, the field), and its name
@(private="file")
addNodeField :: proc(c: ^DropCtx, node: int, edits: ^[dynamic]ce.Text_Edit) -> string {
	line, name := NodeField_Line(c.st, &c.state.project, c.scene, node, c.from)
	if at, col, needed := Struct_MissingComma(docText(c.doc), c.st.closeLine); needed {
		append(edits, ce.Text_Edit{start = {at, col}, end = {at, col}, text = ","})
	}
	append(edits, ce.Text_Edit{start = {c.st.closeLine, 0}, end = {c.st.closeLine, 0}, text = line})
	return name
}

/*
Code reaching a node of type `want` ("Node": any): the script's node (`self.node`), a field whose
default path leads to it, else a new field (its edits added). For a thing without a node (-1), the
script's only field of that type, else the scene's first node of it.

Returns:
- The expression, and false when no node can be reached (no script struct, no such node)
*/
@(private="file")
nodeExpr :: proc(c: ^DropCtx, node: int, want: string, edits: ^[dynamic]ce.Text_Edit) -> (string, bool) {
	if !c.hasStruct do return "", false
	want := want == "" ? "Node" : want
	node := node
	if node < 0 {
		for line, i in c.st.lines {
			t := fieldNodeType(c, line)
			if t == "" do continue
			fits := t == want
			for kind in NodeKind do if !fits && NodeField_TypeName(kind) == t do fits = e.SceneNodeKind_IsType(kind, want)
			if fits do return fmt.tprintf("%s.%s", c.recv, c.st.fields[i]), true
		}
		for &n, i in c.scene.nodes do if e.SceneNodeKind_IsType(NodeDef_BuiltKind(&c.state.project, &n), want) {
			node = i
			break
		}
		if node < 0 do return "", false
	}
	if node >= len(c.scene.nodes) do return "", false
	kind := NodeDef_BuiltKind(&c.state.project, &c.scene.nodes[node])
	if !e.SceneNodeKind_IsType(kind, want) do return "", false
	if node == c.from && want == "Node" do return fmt.tprintf("%s.node", c.recv), true
	path := Scene_NodePath(c.scene, c.from, node, context.temp_allocator)
	own := NodeField_TypeName(kind)
	for line, i in c.st.lines {
		t := fieldNodeType(c, line)
		if t == "" || fieldDefault(line) != path do continue
		if t == want || t == own || want == "Node" do return fmt.tprintf("%s.%s", c.recv, c.st.fields[i]), true
	}
	return fmt.tprintf("%s.%s", c.recv, addNodeField(c, node, edits)), true
}

// The node type a source's uses act on when the source belongs to a node (its own type)
@(private="file")
ownType :: proc(c: ^DropCtx, node: int) -> string {
	if node < 0 || node >= len(c.scene.nodes) do return "Node"
	return NodeField_TypeName(NodeDef_BuiltKind(&c.state.project, &c.scene.nodes[node]))
}

// A value of a type as code writes one (a property set to something to change)
@(private="file")
valueOf :: proc(type: ^reflect.Type_Info) -> string {
	if type == nil do return "0"
	base := reflect.type_info_base(type)
	#partial switch v in base.variant {
	case reflect.Type_Info_Boolean: return "true"
	case reflect.Type_Info_String: return "\"\""
	case reflect.Type_Info_Array:
		parts := make([]string, v.count, context.temp_allocator)
		for &p in parts do p = "0"
		return fmt.tprintf("{{%s}", strings.join(parts, ", ", context.temp_allocator))
	case reflect.Type_Info_Enum:
		if len(v.names) > 0 do return fmt.tprintf(".%s", v.names[0])
	case reflect.Type_Info_Struct: return v.field_count == 4 ? "{255, 255, 255, 255}" : "{}"
	}
	return "0"
}

// A script field's value as code writes one
@(private="file")
scriptValueOf :: proc(field: ^ScriptFieldDesc) -> (string, bool) {
	#partial switch field.type {
	case .Float, .Int:  return field.defaultValue != "" ? field.defaultValue : "0", true
	case .Bool:         return "true", true
	case .String:       return "\"\"", true
	case .Vector2:      return "{0, 0}", true
	case .Color:        return "{255, 255, 255, 255}", true
	case .Enum:         return len(field.enumNames) > 0 ? fmt.tprintf(".%s", field.enumNames[0]) : "{}", true
	}
	return "", false
}

// --- filling in the engine's uses ------------------------------------------------------------

/*
A use's code with its placeholders filled in (`{caret}` kept): the source's constant, its node (a
field added when needed), the script, its game and scene.

Returns:
- The code, and false when a placeholder can't be filled (no node of the type to reach)
*/
@(private="file")
fillUse :: proc(c: ^DropCtx, use: e.CodeUse, edits: ^[dynamic]ce.Text_Edit, value := "") -> (string, bool) {
	code := use.code
	if strings.contains(code, "{node}") {
		owner := c.src.node
		// A thing without a node, or one on a node that isn't of the type (a music file, a group)
		if c.src.kind == .Asset || c.src.kind == .Scene || c.src.kind == .Action || c.src.kind == .Bus || c.src.kind == .Group do owner = -1
		expr, ok := nodeExpr(c, owner, use.node, edits)
		if !ok do return "", false
		code, _ = strings.replace_all(code, "{node}", expr, context.temp_allocator)
	}
	if strings.contains(code, "{name}") {
		name, ok := constantOf(c)
		if !ok do return "", false
		code, _ = strings.replace_all(code, "{name}", name, context.temp_allocator)
	}
	if strings.contains(code, "{type}") {
		type := "T"
		if c.src.kind == .Asset && c.src.index >= 0 && c.src.index < len(c.state.project.assets) {
			if i := Project_FindData(&c.state.project, c.state.project.assets[c.src.index].path); i >= 0 && c.state.project.data[i].type != "" do type = c.state.project.data[i].type
		}
		if type == "T" do return "", false
		code, _ = strings.replace_all(code, "{type}", type, context.temp_allocator)
	}
	code, _ = strings.replace_all(code, "{self}", c.recv, context.temp_allocator)
	code, _ = strings.replace_all(code, "{game}", fmt.tprintf("%s.game", c.recv), context.temp_allocator)
	code, _ = strings.replace_all(code, "{scene}", fmt.tprintf("%s.scene", c.recv), context.temp_allocator)
	code, _ = strings.replace_all(code, "{value}", value != "" ? value : "0", context.temp_allocator)
	return withAlias(c, code), true
}

// The engine's uses that apply to the source, the most specific key's first
@(private="file")
usesOf :: proc(c: ^DropCtx) -> []e.CodeUse {
	out := make([dynamic]e.CodeUse, context.temp_allocator)
	for key in codeUseKeys(c.state, c.src) do append(&out, ..e.CodeUses_For(key))
	return out[:]
}

// --- shapes: in a procedure ------------------------------------------------------------------

// The leading tabs and spaces of a line
@(private)
indentOf :: proc(line: string) -> string {
	n := 0
	for n < len(line) && (line[n] == '\t' || line[n] == ' ') do n += 1
	return line[:n]
}

/*
Inserts a statement in a procedure: on the line dropped on when it's blank, else on a new line
after it (before it when it closes a block), indented like the code there, every line of a
several-line statement too. `{caret}` marks the caret (else the statement's end).

Returns:
- The edit and the caret, in the text after the edit
*/
@(private="file")
statementEdit :: proc(c: ^DropCtx, code: string) -> (ce.Text_Edit, cebuf.Position) {
	return CodeStatement_Edit(c.doc, c.pos, code)
}

/*
Where a statement goes in a procedure for a position (a drop's, a code action's caret): on its
line when it's blank, else on a new line after it (before it when it closes a block), indented
like the code there, every line of a several-line statement too. `{caret}` marks the caret
(else the statement's end).

Returns:
- The edit and the caret, in the text after the edit
*/
CodeStatement_Edit :: proc(doc: ce.Provider_Document, pos: cebuf.Position, code: string) -> (ce.Text_Edit, cebuf.Position) {
	c := struct { doc: ce.Provider_Document, pos: cebuf.Position }{doc, pos}
	line := cebuf.buffer_line_str(c.doc.buffer, c.pos.line)
	trimmed := strings.trim_space(line)
	indent := indentOf(line)
	at := cebuf.Position{c.pos.line + 1, 0}
	end := at
	switch {
	case trimmed == "":
		// The blank line itself, indented like the line above (one more after a `{`)
		at, end = {c.pos.line, 0}, {c.pos.line, len(line)}
		for i := c.pos.line - 1; i >= 0; i -= 1 {
			above := cebuf.buffer_line_str(c.doc.buffer, i)
			if strings.trim_space(above) == "" do continue
			indent = indentOf(above)
			if strings.has_suffix(strings.trim_right_space(above), "{") do indent = fmt.tprintf("%s\t", indent)
			break
		}
	case strings.has_prefix(trimmed, "}"):
		at, end = {c.pos.line, 0}, {c.pos.line, 0}
		indent = fmt.tprintf("%s\t", indent)
	case strings.has_suffix(strings.trim_right_space(line), "{"):
		indent = fmt.tprintf("%s\t", indent)
	}
	if at.line >= cebuf.buffer_line_count(c.doc.buffer) {
		// After the last line: a line break first
		at = {c.pos.line, len(line)}
		end = at
	}
	b := strings.builder_make(context.temp_allocator)
	if at.col > 0 do strings.write_byte(&b, '\n')
	caret := cebuf.Position{-1, 0}
	lines := strings.split_lines(code, context.temp_allocator)
	for l, i in lines {
		strings.write_string(&b, indent)
		row := at.line + i + (at.col > 0 ? 1 : 0)
		if mark := strings.index(l, "{caret}"); mark >= 0 {
			caret = {row, len(indent) + mark}
			strings.write_string(&b, l[:mark])
			strings.write_string(&b, l[mark + len("{caret}"):])
		} else {
			strings.write_string(&b, l)
		}
		if caret.line < 0 && i == len(lines) - 1 do caret = {row, len(indent) + len(l)}
		if i < len(lines) - 1 || end == at && at.col == 0 do strings.write_byte(&b, '\n')
	}
	return ce.Text_Edit{start = at, end = end, text = strings.to_string(b)}, caret
}

// A statement as its use's kind writes it: an `if` block for a condition, `x := ` for a value
@(private="file")
statementOf :: proc(kind: e.CodeUseKind, code, var: string) -> string {
	switch kind {
	case .Condition: return fmt.tprintf("if %s {{\n\t{{caret}\n}", code)
	case .Value:     return fmt.tprintf("%s := %s", var, code)
	case .Statement:
	}
	return code
}

// The caret after other edits (fields added above the statement) moved it
@(private="file")
caretAfter :: proc(caret: cebuf.Position, statementAt: cebuf.Position, others: []ce.Text_Edit) -> cebuf.Position {
	out := caret
	for edit in others do if edit.start.line < statementAt.line {
		out.line += strings.count(edit.text, "\n")
	}
	return out
}

// A choice of a statement (and the fields it needs)
@(private="file")
statementChoice :: proc(c: ^DropCtx, title, code: string, fieldEdits: []ce.Text_Edit) -> ce.Drop_Choice {
	edit, caret := statementEdit(c, code)
	edits := make([]ce.Text_Edit, len(fieldEdits) + 1, context.temp_allocator)
	copy(edits, fieldEdits)
	edits[len(fieldEdits)] = edit
	preview, _ := strings.replace_all(code, "{caret}", "", context.temp_allocator)
	return {title = title, preview = withField(c, preview, fieldEdits), edits = edits, caret = caretAfter(caret, edit.start, fieldEdits), message = fmt.tprintf("Inserted %s", firstLine(preview))}
}

// A preview with the field a choice adds after it
@(private="file")
withField :: proc(c: ^DropCtx, preview: string, fieldEdits: []ce.Text_Edit) -> string {
	for edit in fieldEdits do if strings.contains(edit.text, "\n") {
		return fmt.tprintf("%s\n// and in %s:\n%s", preview, c.st.name, strings.trim_space(edit.text))
	}
	return preview
}

@(private="file")
firstLine :: proc(text: string) -> string {
	line, _, _ := strings.partition(text, "\n")
	return strings.trim_space(line)
}

@(private="file")
bodyChoices :: proc(c: ^DropCtx, out: ^[dynamic]ce.Drop_Choice) {
	src := c.src
	scene := c.scene
	#partial switch src.kind {
	case .Property:
		if src.node < 0 || src.node >= len(scene.nodes) do return
		kind := NodeDef_BuiltKind(&c.state.project, &scene.nodes[src.node])
		field, type, ok := CodeDrops_PropertyField(kind, src.name)
		if !ok do return
		edits := make([dynamic]ce.Text_Edit, context.temp_allocator)
		owner, _, _ := strings.partition(field, ".")
		node, reached := nodeExpr(c, src.node, fieldOwnerType(kind, owner), &edits)
		if !reached do return
		value := valueOf(type)
		append(out, statementChoice(c, "Set it", fmt.tprintf("%s.%s = {{caret}%s", node, field, value), edits[:]))
		// A local named after it ("position.x": positionX)
		base, _, part := strings.partition(field, ".")
		local := part != "" ? fmt.tprintf("%s%s", base, strings.to_upper(part, context.temp_allocator)) : field
		append(out, statementChoice(c, "Read it", fmt.tprintf("%s := %s.%s", local, node, field), edits[:]))
		for use in usesOf(c) do usesChoice(c, use, out, value)
	case .Script_Field:
		expr, value, edits, ok := scriptFieldExpr(c)
		if !ok do return
		if value != "" do append(out, statementChoice(c, "Set it", fmt.tprintf("%s = {{caret}%s", expr, value), edits))
		append(out, statementChoice(c, "Read it", fmt.tprintf("%s := %s", src.name, expr), edits))
	case .Event:
		subject, edits, ok := eventSubject(c)
		if !ok do return
		hint := src.detail != "" ? fmt.tprintf("{{caret}// %s", src.detail) : "{caret}"
		castLine := c.hasStruct ? fmt.tprintf("\t%s := (^%s)(user)\n", c.recv, c.st.name) : ""
		user := c.hasStruct ? c.recv : "nil"
		subscribe := fmt.tprintf("%s.Event_Subscribe(%s, proc(_: ^%s.EventSubject, source: rawptr, data: %s.EventData, user: rawptr) {{\n%s\t%s\n}, %s)",
			c.alias, subject, c.alias, c.alias, castLine, hint, user)
		append(out, statementChoice(c, "Listen to it", subscribe, edits))
		if strings.has_prefix(src.name, "script.") && c.hasStruct {
			append(out, statementChoice(c, "Fire it", fmt.tprintf("%s.Event_Notify(%s, %s.node, {{caret}nil)", c.alias, subject, c.recv), edits))
		}
	case:
		for use in usesOf(c) do usesChoice(c, use, out)
	}
}

// A use as a statement choice (left out when it can't be filled in)
@(private="file")
usesChoice :: proc(c: ^DropCtx, use: e.CodeUse, out: ^[dynamic]ce.Drop_Choice, value := "") {
	edits := make([dynamic]ce.Text_Edit, context.temp_allocator)
	code, ok := fillUse(c, use, &edits, value)
	if !ok do return
	append(out, statementChoice(c, use.title, statementOf(use.kind, code, use.var), edits[:]))
}

// A script field's expression, a value for it, and the fields reaching its node needs
@(private="file")
scriptFieldExpr :: proc(c: ^DropCtx) -> (expr, value: string, edits: []ce.Text_Edit, ok: bool) {
	src := c.src
	fieldEdits := make([dynamic]ce.Text_Edit, context.temp_allocator)
	if desc := ScriptCatalog_Find(&c.state.scripts, src.script); desc != nil {
		for &f in desc.fields do if f.name == src.name do value, _ = scriptValueOf(&f)
	}
	if c.hasStruct && src.script == c.st.name && (src.node == c.from || src.node < 0) {
		return fmt.tprintf("%s.%s", c.recv, src.name), value, nil, true
	}
	node, reached := nodeExpr(c, src.node, "Node", &fieldEdits)
	if !reached do return "", "", nil, false
	return fmt.tprintf("%s.Node_GetScript(%s, %s).%s", c.alias, node, src.script, src.name), value, fieldEdits[:], true
}

// An event's subject (`&self.sprite.animation.onAnimationEnded`) and the fields reaching it needs
@(private="file")
eventSubject :: proc(c: ^DropCtx) -> (string, []ce.Text_Edit, bool) {
	src := c.src
	edits := make([dynamic]ce.Text_Edit, context.temp_allocator)
	if strings.has_prefix(src.name, "script.") {
		field := src.name[len("script."):]
		if c.hasStruct && src.script == c.st.name && src.node == c.from do return fmt.tprintf("&%s.%s", c.recv, field), nil, true
		if src.script == "" do return "", nil, false
		node, ok := nodeExpr(c, src.node, "Node", &edits)
		if !ok do return "", nil, false
		return fmt.tprintf("&%s.Node_GetScript(%s, %s).%s", c.alias, node, src.script, field), edits[:], true
	}
	if src.node < 0 || src.node >= len(c.scene.nodes) do return "", nil, false
	first, _, _ := strings.partition(src.name, ".")
	node, ok := nodeExpr(c, src.node, fieldOwnerType(NodeDef_BuiltKind(&c.state.project, &c.scene.nodes[src.node]), first), &edits)
	if !ok do return "", nil, false
	return fmt.tprintf("&%s.%s", node, src.name), edits[:], true
}

// --- shapes: on an argument --------------------------------------------------------------------

// A choice inserting an expression at the drop
@(private="file")
argumentChoice :: proc(c: ^DropCtx, title, text: string, fieldEdits: []ce.Text_Edit = nil) -> ce.Drop_Choice {
	clean, _ := strings.replace_all(text, "{caret}", "", context.temp_allocator)
	edits := make([]ce.Text_Edit, len(fieldEdits) + 1, context.temp_allocator)
	copy(edits, fieldEdits)
	edits[len(fieldEdits)] = {start = c.pos, end = c.pos, text = clean}
	caret := c.pos
	if mark := strings.index(text, "{caret}"); mark >= 0 && !strings.contains(text[:mark], "\n") {
		caret.col += mark
	} else if !strings.contains(clean, "\n") {
		caret.col += len(clean)
	}
	return {title = title, preview = withField(c, clean, fieldEdits), edits = edits, caret = caretAfter(caret, c.pos, fieldEdits), message = fmt.tprintf("Inserted %s", firstLine(clean))}
}

@(private="file")
argumentChoices :: proc(c: ^DropCtx, out: ^[dynamic]ce.Drop_Choice) {
	src := c.src
	wants := paramKind(c)
	constant, hasConstant := constantOf(c, wants)
	literal := fmt.tprintf("%q", nameInString(c))
	#partial switch src.kind {
	case .Node:
		edits := make([dynamic]ce.Text_Edit, context.temp_allocator)
		node, reached := nodeExpr(c, src.node, "Node", &edits)
		// Without the engine's table (not read yet) the parameter's kind is unknown: the path
		pathFirst := wants == .Node_Path || wants == .Scene_Path || wants == .Child_Path || wants == .None && NameTable_Get() == nil || !reached
		if pathFirst && hasConstant do append(out, argumentChoice(c, "Its path", constant))
		if reached do append(out, argumentChoice(c, "The node", node, edits[:]))
		if !pathFirst && hasConstant do append(out, argumentChoice(c, "Its path", constant))
		if constant != literal do append(out, argumentChoice(c, "Its path as text", literal))
		return
	case .Property:
		if src.node < 0 || src.node >= len(c.scene.nodes) do return
		kind := NodeDef_BuiltKind(&c.state.project, &c.scene.nodes[src.node])
		field, _, ok := CodeDrops_PropertyField(kind, src.name)
		if !ok do return
		edits := make([dynamic]ce.Text_Edit, context.temp_allocator)
		owner, _, _ := strings.partition(field, ".")
		node, reached := nodeExpr(c, src.node, fieldOwnerType(kind, owner), &edits)
		if reached do append(out, argumentChoice(c, "Its value", fmt.tprintf("%s.%s", node, field), edits[:]))
	case .Script_Field:
		expr, _, edits, ok := scriptFieldExpr(c)
		if ok do append(out, argumentChoice(c, "Its value", expr, edits))
		return
	case .Event:
		subject, edits, ok := eventSubject(c)
		if ok do append(out, argumentChoice(c, "Its subject", subject, edits))
		return
	case:
		if hasConstant do append(out, argumentChoice(c, CODE_DROP_KINDS[src.kind].nameKind != .None || src.kind == .Asset ? "Its constant" : "Its name", constant))
		if hasConstant && constant != literal && src.kind != .Asset do append(out, argumentChoice(c, "Its name as text", literal))
		// A name field of the struct with it
		if c.hasStruct do for line, i in c.st.lines {
			if fieldDefault(line) == src.name && CODE_DROP_KINDS[src.kind].nameKind != .None && strings.contains(line, NAME_KIND_TYPES[CODE_DROP_KINDS[src.kind].nameKind]) {
				append(out, argumentChoice(c, "Its field", fmt.tprintf("%s.%s", c.recv, c.st.fields[i])))
				break
			}
		}
	}
	// What the engine's uses compute (a condition, a value)
	for use in usesOf(c) {
		if use.kind == .Statement do continue
		edits := make([dynamic]ce.Text_Edit, context.temp_allocator)
		code, ok := fillUse(c, use, &edits)
		if ok do append(out, argumentChoice(c, use.title, code, edits[:]))
	}
}

// --- shapes: in a struct -----------------------------------------------------------------------

// A choice adding a field (its lines, before the struct's closing brace)
@(private="file")
fieldChoice :: proc(c: ^DropCtx, title, lines, name: string) -> ce.Drop_Choice {
	edits := make([dynamic]ce.Text_Edit, context.temp_allocator)
	if at, col, needed := Struct_MissingComma(docText(c.doc), c.st.closeLine); needed {
		append(&edits, ce.Text_Edit{start = {at, col}, end = {at, col}, text = ","})
	}
	append(&edits, ce.Text_Edit{start = {c.st.closeLine, 0}, end = {c.st.closeLine, 0}, text = lines})
	// The caret at the end of the field's line (the last of the lines added)
	added := strings.count(lines, "\n")
	last := strings.trim_right(lines, "\n")
	if nl := strings.last_index_byte(last, '\n'); nl >= 0 do last = last[nl + 1:]
	return {
		title = title, preview = strings.trim_right(lines, "\n"), edits = edits[:],
		caret = cebuf.Position{c.st.closeLine + added - 1, len(last)},
		message = fmt.tprintf("Added %s to %s: %s (save, and it's set from the scene)", name, c.st.name, strings.trim_space(last)),
	}
}

@(private="file")
structChoices :: proc(c: ^DropCtx, out: ^[dynamic]ce.Drop_Choice) {
	if !c.hasStruct do return
	src := c.src
	k := CODE_DROP_KINDS[src.kind]
	ownerField :: proc(c: ^DropCtx, out: ^[dynamic]ce.Drop_Choice, node: int, title: string) {
		if node < 0 || node >= len(c.scene.nodes) do return
		line, name := NodeField_Line(c.st, &c.state.project, c.scene, node, c.from)
		append(out, fieldChoice(c, title, line, name))
	}
	nameField :: proc(c: ^DropCtx, out: ^[dynamic]ce.Drop_Choice, name, type, suffix: string, options := "") {
		field := NodeField_Name(fmt.tprintf("%s%s", name, suffix), c.st.fields)
		extra := options != "" ? fmt.tprintf("%s ", options) : ""
		append(out, fieldChoice(c, "A field with its name", fmt.tprintf("\t%s: %s.%s `export:\"%sdefault=%s\"`,\n", field, c.alias, type, extra, name), field))
	}
	switch k.inStruct {
	case .Node_Field:
		ownerField(c, out, src.node, "A field for the node")
	case .Owner_Field:
		ownerField(c, out, src.node, fmt.tprintf("A field for %s", codeSourceNodeName(c.state, src.node)))
	case .Asset_Field:
		if src.index < 0 || src.index >= len(c.state.project.assets) do return
		asset := c.state.project.assets[src.index]
		if line, name, ok := AssetField_Line(c.st, &c.state.project, asset); ok {
			append(out, fieldChoice(c, "A field with the asset", line, name))
		} else {
			field := NodeField_Name(AssetField_BaseName(asset.path), c.st.fields)
			append(out, fieldChoice(c, "A field with its path", fmt.tprintf("\t%s: string `export:\"default=%s\"`,\n", field, asset.path), field))
		}
	case .Name_Field:
		name := src.name
		options := ""
		if src.kind == .Scene {
			if src.index < 0 || src.index >= len(c.state.project.scenes) do return
			name = c.state.project.scenes[src.index].name
			options = "kind=scene"
		}
		if strings.contains(name, " ") do return
		nameField(c, out, name, NAME_KIND_TYPES[k.nameKind], k.fieldSuffix, options)
		if src.kind != .Group do ownerField(c, out, src.node, fmt.tprintf("A field for %s", codeSourceNodeName(c.state, src.node)))
	}
}
