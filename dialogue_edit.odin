package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Dialogues in the editor (the engine's dialogue.odin, yarn.odin, dialogue_box.odin).

- **Assets:** `Project.dialogues` (`DialogueDef`: a `.dialogue.xml` file and its `e.DialogueData`),
  assets of kind Dialogue in `dialogues/`, loaded with the project and written by `Project_Save`
  (only changed files). The browser's **New Dialogue** makes one; importing a `.yarn` file
  converts it into one (`Yarn_Import`: Yarn Spinner's options and ifs flattened into nodes and
  conditions; what wasn't converted goes to the Console).
- **The Dialogue tab** (the bottom panel's, view_dialogue.odin) edits the dialogue the browser
  selected, or the selected DialogueBox's (`DialogueEditor.path`): its nodes as a graph, the
  selected node's steps. Every edit is one `Dialogue_Changed` message, a `.Project` undo step
  (the snapshot holds every dialogue; typing merges per field, a node's drag per gesture).
  Renaming a node renames the jumps, options and start naming it.
- **DialogueBox nodes:** `NodeDef.dialogue` / `dialogueStart` / `dialogueBox` (the engine's
  `e.DialogueBoxSettings`; its font owned), the inspector's rows (`dialogueBoxRows`); the
  viewport plays the first line (the preview game gets the dialogues in memory, unsaved edits
  too: `Dialogue_ProvideToGame`).
*/

DIALOGUE_FOLDER :: "dialogues"

// A dialogue asset: its file (owned) and contents (owned)
DialogueDef :: struct {
	path: string,
	data: e.DialogueData,
}

// What the Dialogue tab shows and has selected (view state; State.dialogue)
DialogueEditor :: struct {
	// The dialogue (an asset path, owned; "" none)
	path: string,
	// The selected node and step (-1 none)
	node, step: int,
	// A node being dragged, and where it was grabbed
	dragging: bool,
	grab: [2]f32,
}

// One edit of the shown dialogue
DialogueOp :: enum {
	Node_Added,
	Node_Removed,
	Node_Renamed,
	Node_Moved,
	Start_Set,
	Step_Added,
	Step_Removed,
	Step_Moved,
	Step_Field,
	Option_Added,
	Option_Removed,
	Option_Field,
}

// A field of a step or option
DialogueField :: enum {
	Speaker,
	Text,
	Condition,
	Target,
	Variable,
	Expression,
	Command,
}

// Edits the shown dialogue's selected node (its fields by op)
Dialogue_Changed :: struct {
	op: DialogueOp,
	// The step, and the option in it
	step, option: int,
	field: DialogueField,
	kind: e.DialogueStepKind,
	text: string,
	position: [2]f32,
	// Step_Moved: -1 up, 1 down
	delta: int,
}

// The Dialogue tab's selection and dragging (not undoable)
DialogueViewOp :: enum {
	Show,
	Select_Node,
	Select_Step,
	Drag_Begin,
	Drag_End,
}

Dialogue_View :: struct {
	op: DialogueViewOp,
	index: int,
	// Show: the dialogue's path (for the frame)
	path: string,
	grab: [2]f32,
}

// The browser's New Dialogue
Dialogue_Created :: struct {}

// Reads a `.dialogue.xml` file (owned), or an empty dialogue and why
Project_LoadDialogue :: proc(rootPath, path: string) -> (DialogueDef, string) {
	def := DialogueDef{path = strings.clone(path)}
	text, err := os.read_entire_file(joinPath(rootPath, path, allocator = context.temp_allocator), context.temp_allocator)
	if err != nil do return def, fmt.tprintf("Couldn't read %s", path)
	parsed, parseErr := e.ParseDialogue(string(text))
	if parseErr != .None do return def, fmt.tprintf("%s isn't a dialogue (%v)", path, parseErr)
	def.data = parsed
	return def, ""
}

DialogueDef_Clone :: proc(d: DialogueDef) -> DialogueDef {
	return {strings.clone(d.path), e.DialogueData_Clone(d.data)}
}

DialogueDef_Destroy :: proc(d: ^DialogueDef) {
	delete(d.path)
	e.DialogueData_Destroy(&d.data)
	d^ = {}
}

// The project's dialogue for a file (-1 if none)
Project_FindDialogue :: proc(project: ^Project, path: string) -> int {
	for d, i in project.dialogues do if d.path == path do return i
	return -1
}

// Writes every dialogue's file (Project_Save); only changed files are touched
Project_SaveDialogues :: proc(project: ^Project) -> string {
	for &d in project.dialogues {
		text := e.FormatDialogue(d.data, context.temp_allocator)
		full := joinPath(project.rootPath, d.path, allocator = context.temp_allocator)
		existing, readErr := os.read_entire_file(full, context.temp_allocator)
		if readErr == nil && string(existing) == text do continue
		_ = os.make_directory_all(filepath.dir(full))
		if err := os.write_entire_file(full, text); err != nil do return fmt.tprintf("Couldn't write %s: %v", d.path, err)
	}
	return ""
}

// A free path for a dialogue named `name` (dialogues/<name>.dialogue.xml, numbered when taken)
@(private="file")
dialoguePathFor :: proc(project: ^Project, name: string) -> string {
	base := strings.to_lower(sanitize(strings.trim_space(name)), context.temp_allocator)
	if base == "" do base = "dialogue"
	taken :: proc(project: ^Project, path: string) -> bool {
		for asset in project.assets do if strings.equal_fold(asset.path, path) do return true
		return os.exists(joinPath(project.rootPath, path, allocator = context.temp_allocator))
	}
	path := fmt.tprintf("%s/%s%s", DIALOGUE_FOLDER, base, e.DIALOGUE_EXTENSION)
	for n := 2; taken(project, path); n += 1 do path = fmt.tprintf("%s/%s_%d%s", DIALOGUE_FOLDER, base, n, e.DIALOGUE_EXTENSION)
	return path
}

// Adds a dialogue (owned) as a new asset and writes its file
@(private="file")
dialogueAdd :: proc(project: ^Project, path: string, data: e.DialogueData) -> (int, string) {
	def := DialogueDef{path = strings.clone(path), data = data}
	full := joinPath(project.rootPath, path, allocator = context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(full))
	if err := os.write_entire_file(full, e.FormatDialogue(def.data, context.temp_allocator)); err != nil {
		DialogueDef_Destroy(&def)
		return -1, fmt.tprintf("Couldn't write %s: %v", path, err)
	}
	append(&project.assets, AssetDef{path = strings.clone(path), kind = .Dialogue})
	append(&project.dialogues, def)
	return len(project.dialogues) - 1, ""
}

/*
Makes a new dialogue with a first node and line.

Returns:
- Its index in `project.dialogues`, or -1 and why
*/
Project_CreateDialogue :: proc(project: ^Project, name: string) -> (int, string) {
	data := e.DialogueData{start = strings.clone("Start"), nodes = make([dynamic]e.DialogueNode)}
	node := e.DialogueNode{name = strings.clone("Start"), position = {20, 20}, steps = make([dynamic]e.DialogueStep)}
	append(&node.steps, e.DialogueStep{kind = .Line, speaker = strings.clone("Guide"), text = strings.clone("Hello!")})
	append(&data.nodes, node)
	return dialogueAdd(project, dialoguePathFor(project, name), data)
}

/*
Imports a Yarn Spinner file: converted into a dialogue asset named after it.

Returns:
- The dialogue's asset index, what wasn't converted (temp allocated), or why it failed
*/
Yarn_Import :: proc(project: ^Project, source: string) -> (index: int, warnings: []string, problem: string) {
	text, err := os.read_entire_file(source, context.temp_allocator)
	if err != nil do return -1, nil, fmt.tprintf("Couldn't read %s", source)
	data, notes, ok := e.Yarn_Convert(string(text))
	if !ok {
		e.DialogueData_Destroy(&data)
		return -1, nil, fmt.tprintf("%s has no Yarn nodes (title: ... --- ... ===)", filepath.base(source))
	}
	name := strings.trim_suffix(filepath.base(source), filepath.ext(source))
	_, problem = dialogueAdd(project, dialoguePathFor(project, name), data)
	if problem != "" do return -1, nil, problem
	return len(project.assets) - 1, notes, ""
}

// Whether a file is a Yarn Spinner script
Yarn_IsFile :: proc(path: string) -> bool {
	return strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".yarn")
}

// The dialogue the Dialogue tab shows (nil when none)
Dialogue_Shown :: proc(s: ^State) -> ^DialogueDef {
	if i := Project_FindDialogue(&s.project, s.dialogue.path); i >= 0 do return &s.project.dialogues[i]
	return nil
}

// Whether a message edits a dialogue (History_Classify: a .Project step)
Dialogue_IsEdit :: proc(m: Msg) -> bool {
	_, ok := m.(Dialogue_Changed)
	return ok
}

/*
Handles the dialogue messages.

Returns:
- Whether the message was this file's
*/
DialogueEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	ed := &s.dialogue
	#partial switch v in m {
	case Dialogue_Created:
		index, problem := Project_CreateDialogue(&s.project, "dialogue")
		if problem != "" {
			logLine(s, .Error, strings.clone(problem))
			break
		}
		s.session.assetsChanged = true
		path := s.project.dialogues[index].path
		dialogueShow(s, path)
		for asset, i in s.project.assets do if asset.path == path do s.browserSelection = {kind = .Asset, folder = .Dialogues, index = i}
		s.browserOpen[.Dialogues] = true
		s.bottomTab = .Dialogue
		s.layout.bottomOpen = true
		logLine(s, .Info, fmt.aprintf("Made %s: edit it in the Dialogue tab", path))
		if message := Scripts_WriteAssetsFile(&s.project); message != "" do logLine(s, .Warning, strings.clone(message))
	case Dialogue_View:
		switch v.op {
		case .Show:
			dialogueShow(s, v.path)
		case .Select_Node:
			ed.node, ed.step = v.index, -1
		case .Select_Step:
			ed.step = v.index
		case .Drag_Begin:
			ed.dragging, ed.grab = true, v.grab
			s.history.gesture += 1
		case .Drag_End:
			ed.dragging = false
		}
	case Dialogue_Changed:
		def := Dialogue_Shown(s)
		if def == nil do break
		dialogueApply(s, def, v)
	case:
		return false
	}
	return true
}

@(private="file")
dialogueShow :: proc(s: ^State, path: string) {
	if s.dialogue.path == path do return
	delete(s.dialogue.path)
	s.dialogue = {path = strings.clone(path), node = 0, step = -1}
}

@(private="file")
dialogueApply :: proc(s: ^State, def: ^DialogueDef, v: Dialogue_Changed) {
	ed := &s.dialogue
	data := &def.data
	nodeOk := ed.node >= 0 && ed.node < len(data.nodes)
	set :: proc(field: ^string, text: string) {
		delete(field^)
		field^ = strings.clone(text)
	}
	switch v.op {
	case .Node_Added:
		name := "Node"
		for n := 2; e.Dialogue_FindNode(data, name) >= 0; n += 1 do name = fmt.tprintf("Node%d", n)
		append(&data.nodes, e.DialogueNode{name = strings.clone(name), position = v.position, steps = make([dynamic]e.DialogueStep)})
		ed.node, ed.step = len(data.nodes) - 1, -1
		if data.start == "" do set(&data.start, name)
	case .Node_Removed:
		if !nodeOk do break
		n := &data.nodes[ed.node]
		delete(n.name)
		for &st in n.steps do e.DialogueStep_Destroy(&st)
		delete(n.steps)
		ordered_remove(&data.nodes, ed.node)
		ed.node, ed.step = min(ed.node, len(data.nodes) - 1), -1
	case .Node_Renamed:
		if !nodeOk do break
		name := strings.trim_space(v.text)
		old := data.nodes[ed.node].name
		if name == "" || name == old || e.Dialogue_FindNode(data, name) >= 0 do break
		// What names it follows
		for &n in data.nodes do for &st in n.steps {
			if st.target == old do set(&st.target, name)
			for &o in st.options do if o.target == old do set(&o.target, name)
		}
		if data.start == old do set(&data.start, name)
		set(&data.nodes[ed.node].name, name)
	case .Node_Moved:
		if nodeOk do data.nodes[ed.node].position = {max(v.position.x, 0), max(v.position.y, 0)}
	case .Start_Set:
		set(&data.start, v.text)
	case .Step_Added:
		if !nodeOk do break
		st := e.DialogueStep{kind = v.kind}
		#partial switch v.kind {
		case .Line: st.text = strings.clone("...")
		case .Options:
			st.options = make([dynamic]e.DialogueOption)
			append(&st.options, e.DialogueOption{text = strings.clone("Yes")}, e.DialogueOption{text = strings.clone("No")})
		case .Set: st.variable, st.expression = strings.clone("$flag"), strings.clone("true")
		case .Command: st.command = strings.clone("wait 1")
		}
		steps := &data.nodes[ed.node].steps
		at := ed.step >= 0 && ed.step < len(steps) ? ed.step + 1 : len(steps)
		inject_at(steps, at, st)
		ed.step = at
	case .Step_Removed:
		if !nodeOk || v.step < 0 || v.step >= len(data.nodes[ed.node].steps) do break
		e.DialogueStep_Destroy(&data.nodes[ed.node].steps[v.step])
		ordered_remove(&data.nodes[ed.node].steps, v.step)
		ed.step = -1
	case .Step_Moved:
		if !nodeOk do break
		steps := data.nodes[ed.node].steps[:]
		to := v.step + v.delta
		if v.step < 0 || v.step >= len(steps) || to < 0 || to >= len(steps) do break
		steps[v.step], steps[to] = steps[to], steps[v.step]
		ed.step = to
	case .Step_Field:
		if !nodeOk || v.step < 0 || v.step >= len(data.nodes[ed.node].steps) do break
		st := &data.nodes[ed.node].steps[v.step]
		text := v.text == TEXTURE_NONE ? "" : v.text
		switch v.field {
		case .Speaker:    set(&st.speaker, text)
		case .Text:       set(&st.text, text)
		case .Condition:  set(&st.condition, text)
		case .Target:     set(&st.target, text)
		case .Variable:   set(&st.variable, text)
		case .Expression: set(&st.expression, text)
		case .Command:    set(&st.command, text)
		}
	case .Option_Added:
		if !nodeOk || v.step < 0 || v.step >= len(data.nodes[ed.node].steps) do break
		append(&data.nodes[ed.node].steps[v.step].options, e.DialogueOption{text = strings.clone("Option")})
	case .Option_Removed:
		if !nodeOk || v.step < 0 || v.step >= len(data.nodes[ed.node].steps) do break
		options := &data.nodes[ed.node].steps[v.step].options
		if v.option < 0 || v.option >= len(options) do break
		o := options[v.option]
		delete(o.text); delete(o.target); delete(o.condition)
		ordered_remove(options, v.option)
	case .Option_Field:
		if !nodeOk || v.step < 0 || v.step >= len(data.nodes[ed.node].steps) do break
		options := &data.nodes[ed.node].steps[v.step].options
		if v.option < 0 || v.option >= len(options) do break
		o := &options[v.option]
		text := v.text == TEXTURE_NONE ? "" : v.text
		#partial switch v.field {
		case .Text:      set(&o.text, text)
		case .Target:    set(&o.target, text)
		case .Condition: set(&o.condition, text)
		}
	}
}

// Puts the project's dialogues (as they are in memory) into a preview game, before it builds
Dialogue_ProvideToGame :: proc(s: ^State, game: ^e.Game) {
	game.dialogues = make(map[string]^e.DialogueData, context.temp_allocator)
	for &d in s.project.dialogues do game.dialogues[d.path] = new_clone(d.data, context.temp_allocator)
}

/*
The inspector's rows for a DialogueBox: its dialogue and start node, size, typing speed, text,
colors, autostart and hiding, and Edit in the Dialogue tab.
*/
dialogueBoxRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	b := node.dialogueBox
	d := e.DEFAULT_DIALOGUE_BOX_SETTINGS
	Payload :: struct { field: DialogueBoxField }
	id :: proc(field: DialogueBoxField, key: int) -> string { return fmt.tprintf("inspector-dialogue-%v-%d", field, key) }
	slider :: proc(ctx: ^skald.Ctx(Msg), field: DialogueBoxField, key: int, value, lo, hi, step, def: f32, width: f32) -> skald.View {
		return valueSlider(ctx, id(field, key), value, Payload{field}, proc(p: Payload, v: f32) -> Msg { return DialogueBox_Setting_Changed{field = p.field, value = v} },
			lo, hi, step = step, decimals = 0, defaultValue = def, width = width)
	}
	check :: proc(ctx: ^skald.Ctx(Msg), field: DialogueBoxField, key: int, value: bool) -> skald.View {
		return skald.checkbox(ctx, value, "", Payload{field}, proc(p: Payload, v: bool) -> Msg { return DialogueBox_Setting_Changed{field = p.field, flag = v} },
			id = skald.hash_id(id(field, key)))
	}
	color :: proc(ctx: ^skald.Ctx(Msg), field: DialogueBoxField, key: int, c: [4]u8) -> skald.View {
		linear := skald.rgb(u32(c[0]) << 16 | u32(c[1]) << 8 | u32(c[2]))
		Color :: struct { field: DialogueBoxField, alpha: u8 }
		return skald.color_picker(ctx, linear, Color{field, c[3]}, proc(p: Color, v: skald.Color) -> Msg {
			return DialogueBox_Setting_Changed{field = p.field, text = fmt.tprintf("#%s%02x", skald.color_to_hex(v), p.alpha)}
		}, id = skald.hash_id(id(field, key)))
	}
	choice :: proc(ctx: ^skald.Ctx(Msg), field: DialogueBoxField, key: int, value: string, names: []string, width: f32) -> skald.View {
		return skald.select(ctx, value, names, Payload{field}, proc(p: Payload, v: string) -> Msg { return DialogueBox_Setting_Changed{field = p.field, text = v} },
			id = skald.hash_id(id(field, key)), width = width)
	}
	dialogues := make([dynamic]string, context.temp_allocator)
	append(&dialogues, TEXTURE_NONE)
	for asset in s.project.assets do if asset.kind == .Dialogue do append(&dialogues, asset.path)
	append(&rows, inspectorRow(ctx, "Dialogue", choice(ctx, .Dialogue, key, node.dialogue == "" ? TEXTURE_NONE : node.dialogue, dialogues[:], controlWidth)))
	nodes := make([dynamic]string, context.temp_allocator)
	append(&nodes, DIALOGUE_START_DEFAULT)
	if i := Project_FindDialogue(&s.project, node.dialogue); i >= 0 do for n in s.project.dialogues[i].data.nodes do append(&nodes, n.name)
	append(&rows, inspectorRow(ctx, "Start node", choice(ctx, .Start, key, node.dialogueStart == "" ? DIALOGUE_START_DEFAULT : node.dialogueStart, nodes[:], controlWidth)))
	append(&rows,
		inspectorRow(ctx, "Box width", slider(ctx, .Width, key, b.size.x, 16, 1920, 1, d.size.x, controlWidth)),
		inspectorRow(ctx, "Box height", slider(ctx, .Height, key, b.size.y, 16, 1080, 1, d.size.y, controlWidth)),
		inspectorRow(ctx, "Type speed", slider(ctx, .Type_Speed, key, b.typeSpeed, 0, 200, 1, d.typeSpeed, controlWidth)),
		inspectorRow(ctx, "Letter size", slider(ctx, .Font_Size, key, b.fontSize, 6, 96, 1, d.fontSize, controlWidth)),
		inspectorRow(ctx, "Box padding", slider(ctx, .Padding, key, b.padding, 0, 64, 1, d.padding, controlWidth)),
		inspectorRow(ctx, "Box color", color(ctx, .Background, key, transmute([4]u8)b.background)),
		inspectorRow(ctx, "Text color", color(ctx, .Text_Color, key, transmute([4]u8)b.textColor)),
		inspectorRow(ctx, "Name color", color(ctx, .Name_Color, key, transmute([4]u8)b.nameColor)),
		inspectorRow(ctx, "Chosen color", color(ctx, .Pick_Color, key, transmute([4]u8)b.pickColor)),
		inspectorRow(ctx, "Starts playing", check(ctx, .Autostart, key, b.autostart)),
		inspectorRow(ctx, "Hide when done", check(ctx, .Hide_When_Done, key, b.hideWhenDone)),
	)
	fonts := make([dynamic]string, context.temp_allocator)
	append(&fonts, TEXTURE_NONE)
	for asset in s.project.assets do if asset.kind == .Font do append(&fonts, asset.path)
	append(&rows, inspectorRow(ctx, "Box font", choice(ctx, .Font, key, b.font == "" ? TEXTURE_NONE : b.font, fonts[:], controlWidth)))
	append(&rows, inspectorRow(ctx, "", skald.button(ctx, fmt.tprintf("%s  Edit in the Dialogue tab", ICON_COMMENTS), Msg(Dialogue_View{op = .Show, path = node.dialogue}), id = skald.hash_id(fmt.tprintf("inspector-dialogue-edit-%d", key)),
		bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)))
	append(&rows, skald.text("The player continues with ui_accept (Space, Enter, a click) and picks options with ui_up / ui_down. Scripts: e.DialogueBox_Start(box, \"Node\"); its onCommand runs your commands.", th.color.fg_muted, th.font.size_xs, max_width = inspectorRowWidth(controlWidth)))
	return rows[:]
}

// The start node choice for the dialogue's own start
DIALOGUE_START_DEFAULT :: "(the dialogue's start)"

// A DialogueBox's setting
DialogueBoxField :: enum {
	Dialogue,
	Start,
	Width,
	Height,
	Type_Speed,
	Font_Size,
	Padding,
	Background,
	Text_Color,
	Name_Color,
	Pick_Color,
	Autostart,
	Hide_When_Done,
	Font,
}

// A setting of the selected DialogueBox changed
DialogueBox_Setting_Changed :: struct {
	field: DialogueBoxField,
	value: f32,
	text: string,
	flag: bool,
}

/*
Handles DialogueBox_Setting_Changed on the selected node.

Returns:
- Whether the message was one
*/
DialogueBoxEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	v, ok := m.(DialogueBox_Setting_Changed)
	if !ok do return false
	node := selectedNode(s)
	if node == nil || node.kind != .DialogueBox do return true
	b := &node.dialogueBox
	text := v.text == TEXTURE_NONE ? "" : v.text
	switch v.field {
	case .Dialogue:
		delete(node.dialogue)
		node.dialogue = strings.clone(text)
		// Show it in the Dialogue tab too
		if text != "" do dialogueShow(s, text)
	case .Start:
		delete(node.dialogueStart)
		node.dialogueStart = strings.clone(text == DIALOGUE_START_DEFAULT ? "" : text)
	case .Width:          b.size.x = clamp(v.value, 16, 4096)
	case .Height:         b.size.y = clamp(v.value, 16, 4096)
	case .Type_Speed:     b.typeSpeed = clamp(v.value, 0, 1000)
	case .Font_Size:      b.fontSize = clamp(v.value, 4, 200)
	case .Padding:        b.padding = clamp(v.value, 0, 200)
	case .Background:     if c, parsed := e.ParseColor(text); parsed do b.background = c
	case .Text_Color:     if c, parsed := e.ParseColor(text); parsed do b.textColor = c
	case .Name_Color:     if c, parsed := e.ParseColor(text); parsed do b.nameColor = c
	case .Pick_Color:     if c, parsed := e.ParseColor(text); parsed do b.pickColor = c
	case .Autostart:      b.autostart = v.flag
	case .Hide_When_Done: b.hideWhenDone = v.flag
	case .Font:
		delete(b.font)
		b.font = strings.clone(text)
	}
	return true
}
