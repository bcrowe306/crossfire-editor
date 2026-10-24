package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:strconv"
import "core:strings"
import ce "code_editor/editor"
import e "engine:."
import cebuf "code_editor/buffer"
import "gui:skald"

/*
The running game in the code (round 6 of the code editor integration): live values beside a
script's field declarations, and number literals scrubbed into the running game.

**Live values.** While a game plays with the live link (live_edit.odin), each script struct of the
shown code tab (registered as a script or a node type) gets a hint on its declaration line saying
which running node its values come from (`live: Hero`; with several nodes running it, a click
opens a menu of them), and each field line the value the game has (`= 312`, any field: the engine
reads them by reflection). Which node: one picked from that menu (until the Live tab's choice or
the scene's selection changes), else the node chosen in the Live tab when it runs the script,
else the scene's selected node when it does (matched by its path in the running scene), else the
first running node that runs it (`codeLiveTarget`).

**Asking for what's shown.** Every frame `CodeLive_Frame` works out the fields on the shown tab's
visible lines and their nodes (`CodeLive_Watches`); `Live_Watch` sends only the watches that
changed (`fields <Script> <id> <field>...`), and the game sends their values with its stats, four
times a second. No code tab, no game: the watches stop. The hints go when the game stops (the
providers check the link; `CodeProviders_Begin` asks them again when the tree, the values or the
link change).

**Scrubbing.** Alt+drag on a number in an exported field's `default=` (code_editor's `.Scrub`
providers: the buffer isn't edited while dragging, the value is drawn over the literal) sends each
value to the running game (`set <id> script.<field> <value>`, through `Code_Scrub_Changed`),
starting from the game's value, kept in the tag's `min` / `max`. At the release a menu asks where
the value goes, so there's always one source of truth:
- **the code's default** (`default=312` written in the tab: one undo step there; saved, hot
  reload restarts the game with it), for every node without its own value;
- **the node's own value** (the inspector's, an undo step), when the node is in the open
  project's scene; offered first when the node has its own value already, since the default
  wouldn't change it (the menu says so);
- **the game only**: nothing is written (Escape does the same).
Plain number literals in procedure bodies aren't scrubbed: changing one needs a rebuild, and hot
reload restarts the game, so it couldn't follow a drag (decided in round 6).
*/

// Lines past the visible ones whose fields are asked for too (scrolling shows them at once)
CODE_LIVE_MARGIN :: 5

// A field's value was scrubbed: send it to the running game (the code view sends it; strings temp)
Code_Scrub_Changed :: struct {
	id, property, value: string,
}

// Where a scrubbed value goes when the drag ends (the menu's choice)
CodeScrubWriteKind :: enum {
	Game_Only,
	Code_Default,
	Node_Value,
}

// A scrub's value written back (the menu's pick; strings temp)
Code_Scrub_Write :: struct {
	kind: CodeScrubWriteKind,
	// The literal in the code tab (0-based line, bytes) and its text then, and the new text
	path: string,
	line, start, end: int,
	literal, text: string,
	// The node's own value: its scene and index, which of its scripts, the field, the value and
	// the field's default
	scene, node: int,
	script, field, value, defaultValue: string,
}

// A code tab's hint picked a running node for a script (strings temp)
Code_Live_Picked :: struct {
	script, id: string,
}

// The watches a code tab wants (`Live_Watch`; strings temp)
Code_Live_Watch :: struct {
	lines: []string,
}

// What the providers left for the view to send, and the scrub in progress (package state, like
// the other providers')
@(private="file")
codeLive: struct {
	// The last scrub change, a pick, a write-back (owned strings)
	change: Maybe(Code_Scrub_Changed),
	pick: Maybe(Code_Live_Picked),
	write: Maybe(Code_Scrub_Write),
	// The scrub being dragged: its field (set by the scrub target; owned)
	scrub: CodeScrub,
	// What the release's menu offered, in its order
	choices: [dynamic]CodeScrubWriteKind,
}

// The field a scrub drags (owned strings)
@(private="file")
CodeScrub :: struct {
	path: string,
	script, field, id: string,
	// The literal (0-based line, bytes) and its text
	line, start, end: int,
	literal: string,
	// The default's whole value and where the literal is in it (a vector's other number stays)
	defaultText: string,
	numberStart, numberEnd: int,
	// The other component of a vector field as the game has it ("" for numbers)
	other: string,
	component: int,
	// The node in the open project (-1 none) and whether it has its own value
	scene, node: int,
	ownValue: string,
	hasOwn: bool,
	defaultValue: string,
	nodeName: string,
}

// A registered script struct in a file and its fields (lines 0-based, as the index read them)
CodeLiveStruct :: struct {
	script: string,
	line: int,
	fields: []IndexField,
}

/*
The script structs a file declares that run on nodes (registered as scripts or node types).

Inputs:
- state: Editor state
- path: The file (absolute)

Returns:
- The structs (temp allocated; strings the index's)
*/
CodeLive_Structs :: proc(state: ^State, path: string) -> []CodeLiveStruct {
	out := make([dynamic]CodeLiveStruct, context.temp_allocator)
	file := ScriptIndex_File(&state.scriptIndex, path)
	if file == nil do return nil
	registered := make(map[string]bool, context.temp_allocator)
	for _, f in state.scriptIndex.files do for r in f.registrations do if r.kind == .Script || r.kind == .NodeType do registered[r.name] = true
	for s in file.structs {
		if !registered[s.name] do continue
		append(&out, CodeLiveStruct{script = s.name, line = s.line - 1, fields = s.fields[:]})
	}
	return out[:]
}

// The struct's declaration line in a buffer edited since the index read it: the nearest line
// declaring it (-1 none)
@(private="file")
structLine :: proc(doc: ce.Provider_Document, s: CodeLiveStruct) -> int {
	count := cebuf.buffer_line_count(doc.buffer)
	declares :: proc(text, name: string) -> bool {
		at := strings.index(text, name)
		return at >= 0 && strings.has_prefix(strings.trim_left_space(text[at + len(name):]), "::") && strings.contains(text, "struct")
	}
	for d in 0 ..< 200 {
		for at in ([2]int{s.line - d, s.line + d}) {
			if at >= 0 && at < count && declares(cebuf.buffer_line_str(doc.buffer, at), s.script) do return at
		}
	}
	return -1
}

/*
Whether the code tabs show live values: a game plays and answers on the live link.
*/
CodeLive_Active :: proc(state: ^State) -> bool {
	return state != nil && state.live.connected && state.playState != .Stopped && state.play.stage == .Running
}

/*
The running node a script's values come from, and every running node that runs it.

Returns:
- The node (an index of `state.live.nodes`, -1 none) and the candidates (temp allocated)
*/
CodeLive_Target :: proc(state: ^State, script: string) -> (node: int, candidates: []int) {
	live := &state.live
	list := make([dynamic]int, context.temp_allocator)
	for n, i in live.nodes do for s in n.scripts do if s == script {
		append(&list, i)
		break
	}
	candidates = list[:]
	if len(candidates) == 0 do return -1, candidates
	isCandidate :: proc(candidates: []int, i: int) -> bool {
		for c in candidates do if c == i do return true
		return false
	}
	indexOf :: proc(live: ^LiveView, id: string) -> int {
		for n, i in live.nodes do if n.id == id do return i
		return -1
	}
	// Picked in the code, while the Live tab and the scene's choices stay as they were
	if pick, ok := live.codePicks[script]; ok && pick.liveSelected == hash.fnv64a(transmute([]byte)live.selected) && pick.editorSelected == state.selectedNode {
		if i := indexOf(live, pick.id); i >= 0 && isCandidate(candidates, i) do return i, candidates
	}
	if i := indexOf(live, live.selected); i >= 0 && isCandidate(candidates, i) do return i, candidates
	if i := codeLiveSelectedNode(state); i >= 0 && isCandidate(candidates, i) do return i, candidates
	return candidates[0], candidates
}

// A running node's path from the top of its scene ("/World/Hero")
CodeLive_NodePath :: proc(live: ^LiveView, i: int) -> string {
	chain := make([dynamic]string, context.temp_allocator)
	at := i
	for guard := 0; at >= 0 && guard < 256; guard += 1 {
		inject_at(&chain, 0, live.nodes[at].name)
		parent := live.nodes[at].parent
		at = -1
		if parent == "" do break
		for n, j in live.nodes do if n.id == parent do at = j
	}
	b := strings.builder_make(context.temp_allocator)
	for name in chain {
		strings.write_byte(&b, '/')
		strings.write_string(&b, name)
	}
	return strings.to_string(b)
}

/*
The open project's node a running node is (by its path in the scene of the same name).

Returns:
- The scene and node indexes, or -1, -1
*/
CodeLive_ProjectNode :: proc(state: ^State, liveNode: int) -> (scene, node: int) {
	if liveNode < 0 || liveNode >= len(state.live.nodes) do return -1, -1
	si := Project_FindScene(&state.project, state.live.scene)
	if si < 0 do return -1, -1
	path := CodeLive_NodePath(&state.live, liveNode)
	sc := &state.project.scenes[si]
	for _, ni in sc.nodes do if Scene_NodePath(sc, -1, ni, context.temp_allocator) == path do return si, ni
	return -1, -1
}

// The running node the scene's selected node is (-1 none: another scene, or not running)
@(private="file")
codeLiveSelectedNode :: proc(state: ^State) -> int {
	if state.selectedNode < 0 || state.currentScene < 0 || state.currentScene >= len(state.project.scenes) do return -1
	sc := &state.project.scenes[state.currentScene]
	if sc.name != state.live.scene || state.selectedNode >= len(sc.nodes) do return -1
	path := Scene_NodePath(sc, -1, state.selectedNode, context.temp_allocator)
	for _, i in state.live.nodes do if CodeLive_NodePath(&state.live, i) == path do return i
	return -1
}

/*
The `fields` watches for a code tab's visible lines: per script struct with a running node, the
fields declared between `first` and `last` (0-based lines, CODE_LIVE_MARGIN more each way).

Returns:
- "<Script> <id> <field>..." lines (temp allocated)
*/
CodeLive_Watches :: proc(state: ^State, path: string, first, last: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if !CodeLive_Active(state) do return nil
	for s in CodeLive_Structs(state, path) {
		node, _ := CodeLive_Target(state, s.script)
		if node < 0 do continue
		b := strings.builder_make(context.temp_allocator)
		count := 0
		for f in s.fields {
			if f.isUsing do continue
			line := f.line - 1
			if line < first - CODE_LIVE_MARGIN || line > last + CODE_LIVE_MARGIN do continue
			if count == 0 do fmt.sbprintf(&b, "%s %s", s.script, state.live.nodes[node].id)
			fmt.sbprintf(&b, " %s", f.name)
			count += 1
		}
		if count > 0 do append(&out, strings.to_string(b))
	}
	return out[:]
}

/*
Keeps the running game's watches on what the shown code tab shows (called by `view` every
frame): sends `Code_Live_Watch` when they differ from what was sent.
*/
CodeLive_Frame :: proc(state: ^State, ctx: ^skald.Ctx(Msg)) {
	wanted: []string
	if CodeLive_Active(state) && state.codeTab > 0 && state.codeTab <= len(state.codeTabs) {
		path := state.codeTabs[state.codeTab - 1]
		if first, count, ok := CodeEditor_VisibleLines(path); ok do wanted = CodeLive_Watches(state, absolutePath(path), first, first + count)
	}
	same := len(wanted) == len(state.live.watches)
	for w, i in wanted {
		if !same do break
		same = state.live.watches[i] == w
	}
	if !same do skald.send(ctx, Msg(Code_Live_Watch{wanted}))
}

// --- the providers ----------------------------------------------------------------

// The live values' inlay hints (a code tab's providers: code_providers.odin)
@(private)
liveInlays :: proc(doc: ce.Provider_Document, ctx: ce.Provider_Context, out: ^[dynamic]ce.Inlay_Hint) {
	state := codeProvidersState()
	if !CodeLive_Active(state) || !isProjectScript(state, doc.path) do return
	live := &state.live
	count := cebuf.buffer_line_count(doc.buffer)
	for s, si in CodeLive_Structs(state, absolutePath(doc.path)) {
		node, candidates := CodeLive_Target(state, s.script)
		if node < 0 do continue
		line := structLine(doc, s)
		if line < 0 || line >= count do continue
		label := fmt.tprintf("live: %s", live.nodes[node].name)
		choices: []string
		if len(candidates) > 1 {
			at := 0
			for c, i in candidates do if c == node do at = i
			label = fmt.tprintf("live: %s (%d of %d) ▾", live.nodes[node].name, at + 1, len(candidates))
			choices = make([]string, len(candidates), ctx.allocator)
			for c, i in candidates do choices[i] = fmt.aprintf("%s  %s", live.nodes[c].name, CodeLive_NodePath(live, c), allocator = ctx.allocator)
		}
		text := cebuf.buffer_line_str(doc.buffer, line)
		append(out, ce.Inlay_Hint{pos = {line, len(text)}, label = label, kind = .Note, clickable = len(choices) > 1, choices = choices, id = si})
		projectScene, projectNode := CodeLive_ProjectNode(state, node)
		for f in s.fields {
			if f.isUsing do continue
			value, ok := Live_FieldValue(live, s.script, live.nodes[node].id, f.name)
			if !ok do continue
			at := relocate(doc, f.line - 1, f.lineText)
			if at < 0 do continue
			hint := fmt.tprintf("= %s", value)
			// The node's own value (the inspector's) when it has one: the game started from it
			if own, has := codeLiveOwnValue(state, projectScene, projectNode, s.script, f.name); has do hint = fmt.tprintf("= %s  (%s's own: %s)", value, live.nodes[node].name, own)
			append(out, ce.Inlay_Hint{pos = {at, len(cebuf.buffer_line_str(doc.buffer, at))}, label = hint, kind = .Value})
		}
	}
}

// A live hint's menu: a running node picked for the struct's script
@(private)
liveInlayClicked :: proc(doc: ce.Provider_Document, hint: ce.Inlay_Hint, userData: rawptr) {
	state := codeProvidersState()
	if !CodeLive_Active(state) do return
	structs := CodeLive_Structs(state, absolutePath(doc.path))
	if hint.id < 0 || hint.id >= len(structs) do return
	_, candidates := CodeLive_Target(state, structs[hint.id].script)
	if hint.choice < 0 || hint.choice >= len(candidates) do return
	codeLivePickFree()
	codeLive.pick = Code_Live_Picked{strings.clone(structs[hint.id].script), strings.clone(state.live.nodes[candidates[hint.choice]].id)}
}

// The node's own value of a script's field (its stored prop: the inspector's), if it has one
@(private="file")
codeLiveOwnValue :: proc(state: ^State, scene, node: int, script, field: string) -> (string, bool) {
	if scene < 0 || node < 0 do return "", false
	n := &state.project.scenes[scene].nodes[node]
	props := codeLiveProps(n, script)
	if props == nil do return "", false
	for p in props^ do if p.name == field do return p.value, true
	return "", false
}

// A node's stored values of one of its scripts (its first, more or node type's; nil: it doesn't run it)
@(private="file")
codeLiveProps :: proc(n: ^NodeDef, script: string) -> ^[dynamic]ScriptPropDef {
	if n.customKind == script do return &n.customProps
	if n.script == script do return &n.props
	for &extra in n.moreScripts do if extra.name == script do return &extra.props
	return nil
}

// A number in an exported field's default: Alt+drag scrubs it into the running game
@(private)
liveScrubTarget :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, out: ^ce.Scrub_Target) -> bool {
	state := codeProvidersState()
	if !CodeLive_Active(state) || !isProjectScript(state, doc.path) do return false
	if pos.line < 0 || pos.line >= cebuf.buffer_line_count(doc.buffer) do return false
	text := cebuf.buffer_line_str(doc.buffer, pos.line)
	for s in CodeLive_Structs(state, absolutePath(doc.path)) {
		for f in s.fields {
			if f.isUsing || relocate(doc, f.line - 1, f.lineText) != pos.line do continue
			integer := f.type == "int" || f.type == "i32"
			vector := f.type == "[2]f32"
			if !integer && !vector && f.type != "f32" && f.type != "f64" do return false
			literal, ok := CodeScrub_Literal(text, pos.col)
			if !ok do return false
			node, _ := CodeLive_Target(state, s.script)
			if node < 0 do return false
			id := state.live.nodes[node].id
			// From the game's value (a vector's component: the literal's place in the default)
			start, _ := strconv.parse_f64(text[literal.start:literal.end])
			other := ""
			if game, has := Live_FieldValue(&state.live, s.script, id, f.name); has {
				numbers := CodeScrub_Numbers(game)
				if vector && len(numbers) == 2 {
					start = numbers[literal.component]
					other = fmt.tprintf("%v", numbers[1 - literal.component])
				} else if !vector && len(numbers) == 1 {
					start = numbers[0]
				}
			}
			if vector && other == "" {
				// Not sent yet: the default's other number
				defaults := CodeScrub_Numbers(literal.defaultText)
				if len(defaults) == 2 do other = fmt.tprintf("%v", defaults[1 - literal.component])
			}
			lo, hi := CodeScrub_Range(text)
			sc, ni := CodeLive_ProjectNode(state, node)
			own, hasOwn := codeLiveOwnValue(state, sc, ni, s.script, f.name)
			codeScrubFree()
			codeLive.scrub = CodeScrub{
				path = strings.clone(doc.path), script = strings.clone(s.script), field = strings.clone(f.name), id = strings.clone(id),
				line = pos.line, start = literal.start, end = literal.end, literal = strings.clone(text[literal.start:literal.end]),
				defaultText = strings.clone(literal.defaultText), numberStart = literal.numberStart, numberEnd = literal.numberEnd,
				other = strings.clone(other), component = vector ? literal.component : -1,
				scene = sc, node = ni, ownValue = strings.clone(own), hasOwn = hasOwn,
				defaultValue = strings.clone(literal.defaultText), nodeName = strings.clone(state.live.nodes[node].name),
			}
			out^ = {start = {pos.line, literal.start}, end = {pos.line, literal.end}, value = start, decimals = -1, min = lo, max = hi, integer = integer}
			return true
		}
	}
	return false
}

// A scrub's new value (sent to the game through the view) or its end (the write-back choices)
@(private)
liveScrubbed :: proc(doc: ce.Provider_Document, target: ce.Scrub_Target, value: f64, text: string, phase: ce.Scrub_Phase, userData: rawptr, choices: ^[dynamic]string) {
	sc := &codeLive.scrub
	if sc.field == "" do return
	switch phase {
	case .Change:
		codeChangeFree()
		codeLive.change = Code_Scrub_Changed{strings.clone(sc.id), strings.concatenate({e.ANIMATOR_SCRIPT_PREFIX, sc.field}), strings.clone(codeScrubValue(sc, text))}
	case .End:
		clear(&codeLive.choices)
		code := sc.hasOwn ? fmt.tprintf("Write %s as the default in the code (%s keeps its own %s)", text, sc.nodeName, sc.ownValue) : fmt.tprintf("Write %s as the default in the code", text)
		node := fmt.tprintf("Write %s to %s's own value (the inspector)", codeScrubValue(sc, text), sc.nodeName)
		canNode := sc.scene >= 0 && sc.node >= 0
		if sc.hasOwn && canNode {
			append(choices, node, code)
			append(&codeLive.choices, CodeScrubWriteKind.Node_Value, CodeScrubWriteKind.Code_Default)
		} else {
			append(choices, code)
			append(&codeLive.choices, CodeScrubWriteKind.Code_Default)
			if canNode {
				append(choices, node)
				append(&codeLive.choices, CodeScrubWriteKind.Node_Value)
			}
		}
		append(choices, fmt.tprintf("Keep %s in the running game only", text))
		append(&codeLive.choices, CodeScrubWriteKind.Game_Only)
	}
}

// The write-back picked from the scrub's menu, for the view to send
@(private)
liveScrubChosen :: proc(doc: ce.Provider_Document, target: ce.Scrub_Target, value: f64, text: string, choice: int, userData: rawptr) {
	sc := &codeLive.scrub
	if sc.field == "" || choice < 0 || choice >= len(codeLive.choices) do return
	codeWriteFree()
	codeLive.write = Code_Scrub_Write{
		kind = codeLive.choices[choice], path = strings.clone(sc.path), line = sc.line, start = sc.start, end = sc.end,
		literal = strings.clone(sc.literal), text = strings.clone(text),
		scene = sc.scene, node = sc.node, script = strings.clone(sc.script), field = strings.clone(sc.field),
		value = strings.clone(codeScrubValue(sc, text)), defaultValue = strings.clone(sc.defaultValue),
	}
}

// The property's whole value for a scrubbed number: a vector's other component kept (temp allocated)
@(private="file")
codeScrubValue :: proc(sc: ^CodeScrub, text: string) -> string {
	if sc.component < 0 do return text
	return sc.component == 0 ? fmt.tprintf("%s, %s", text, sc.other) : fmt.tprintf("%s, %s", sc.other, text)
}

// What the live providers left for the view to send (a scrub's value, a pick, a write-back), once
CodeLive_Take :: proc(ctx: ^skald.Ctx(Msg)) {
	for m in CodeLive_Messages() do skald.send(ctx, m)
}

/*
What the live providers left (a scrub's value, a pick, a write-back) as messages, once: the code
view sends them; tests take them.

Returns:
- The messages (strings temp allocated)
*/
CodeLive_Messages :: proc() -> []Msg {
	out := make([dynamic]Msg, context.temp_allocator)
	if c, ok := codeLive.change.?; ok {
		append(&out, Msg(Code_Scrub_Changed{strings.clone(c.id, context.temp_allocator), strings.clone(c.property, context.temp_allocator), strings.clone(c.value, context.temp_allocator)}))
		codeChangeFree()
	}
	if p, ok := codeLive.pick.?; ok {
		append(&out, Msg(Code_Live_Picked{strings.clone(p.script, context.temp_allocator), strings.clone(p.id, context.temp_allocator)}))
		codeLivePickFree()
	}
	if w, ok := codeLive.write.?; ok {
		m := w
		m.path = strings.clone(w.path, context.temp_allocator)
		m.literal = strings.clone(w.literal, context.temp_allocator)
		m.text = strings.clone(w.text, context.temp_allocator)
		m.script = strings.clone(w.script, context.temp_allocator)
		m.field = strings.clone(w.field, context.temp_allocator)
		m.value = strings.clone(w.value, context.temp_allocator)
		m.defaultValue = strings.clone(w.defaultValue, context.temp_allocator)
		append(&out, Msg(m))
		codeWriteFree()
	}
	return out[:]
}

// Frees the package state (tests, quitting)
CodeLive_Shutdown :: proc() {
	codeChangeFree()
	codeLivePickFree()
	codeWriteFree()
	codeScrubFree()
	delete(codeLive.choices)
	codeLive = {}
}

@(private="file")
codeChangeFree :: proc() {
	if c, ok := codeLive.change.?; ok {
		delete(c.id)
		delete(c.property)
		delete(c.value)
	}
	codeLive.change = nil
}

@(private="file")
codeLivePickFree :: proc() {
	if p, ok := codeLive.pick.?; ok {
		delete(p.script)
		delete(p.id)
	}
	codeLive.pick = nil
}

@(private="file")
codeWriteFree :: proc() {
	if w, ok := codeLive.write.?; ok {
		delete(w.path)
		delete(w.literal)
		delete(w.text)
		delete(w.script)
		delete(w.field)
		delete(w.value)
		delete(w.defaultValue)
	}
	codeLive.write = nil
}

@(private="file")
codeScrubFree :: proc() {
	sc := &codeLive.scrub
	delete(sc.path)
	delete(sc.script)
	delete(sc.field)
	delete(sc.id)
	delete(sc.literal)
	delete(sc.defaultText)
	delete(sc.other)
	delete(sc.ownValue)
	delete(sc.defaultValue)
	delete(sc.nodeName)
	sc^ = {}
}

// --- the literals ---------------------------------------------------------------

// A number in a tag's `default=` (bytes of its line)
CodeScrubLiteral :: struct {
	start, end: int,
	// The default's whole value (`10, 20`), the number's place in it, and which number it is
	defaultText: string,
	numberStart, numberEnd: int,
	component: int,
}

/*
The number at a column of a line inside an `export:"default=..."` tag's value: what a scrub
changes. Not in a procedure body, not elsewhere in the tag (`min=`, `max=`).

Inputs:
- line: The line's text
- column: A byte column (on the number or just after it)

Returns:
- The literal, and false when there's none there
*/
CodeScrub_Literal :: proc(line: string, column: int) -> (CodeScrubLiteral, bool) {
	tag := strings.index(line, "export:\"")
	if tag < 0 do return {}, false
	body := tag + len("export:\"")
	close := strings.index_byte(line[body:], '"')
	if close < 0 do return {}, false
	options := line[body:body + close]
	d := strings.index(options, "default=")
	if d < 0 || (d > 0 && options[d - 1] != ' ') do return {}, false
	valueStart := d + len("default=")
	valueEnd := len(options)
	for key in ([]string{" min=", " max=", " kind="}) {
		if k := strings.index(options[valueStart:], key); k >= 0 do valueEnd = min(valueEnd, valueStart + k)
	}
	value := options[valueStart:valueEnd]
	base := body + valueStart
	// The numbers in it, in order
	component := 0
	i := 0
	for i < len(value) {
		c := value[i]
		isStart := c >= '0' && c <= '9' || (c == '-' || c == '.') && i + 1 < len(value) && (value[i + 1] >= '0' && value[i + 1] <= '9' || value[i + 1] == '.')
		if !isStart {
			i += 1
			continue
		}
		j := i + 1
		for j < len(value) && (value[j] >= '0' && value[j] <= '9' || value[j] == '.') do j += 1
		if column >= base + i && column <= base + j {
			return {start = base + i, end = base + j, defaultText = strings.trim_space(value), numberStart = i, numberEnd = j, component = component}, true
		}
		component += 1
		i = j
	}
	return {}, false
}

/*
The numbers in a value's text ("[10, 20]", "10, 20", "312.5"), in order (temp allocated).
*/
CodeScrub_Numbers :: proc(text: string) -> []f64 {
	out := make([dynamic]f64, context.temp_allocator)
	i := 0
	for i < len(text) {
		c := text[i]
		if !(c >= '0' && c <= '9' || c == '-' || c == '.') {
			i += 1
			continue
		}
		j := i + 1
		for j < len(text) && (text[j] >= '0' && text[j] <= '9' || text[j] == '.' || text[j] == 'e' || (text[j] == '-' && text[j - 1] == 'e')) do j += 1
		if v, ok := strconv.parse_f64(text[i:j]); ok do append(&out, v)
		i = j
	}
	return out[:]
}

/*
A field's `min=` and `max=` from its line's tag (nil: none).
*/
CodeScrub_Range :: proc(line: string) -> (lo, hi: Maybe(f64)) {
	read :: proc(line, key: string) -> Maybe(f64) {
		at := strings.index(line, key)
		if at < 0 do return nil
		rest := line[at + len(key):]
		end := 0
		for end < len(rest) && (rest[end] >= '0' && rest[end] <= '9' || rest[end] == '.' || rest[end] == '-') do end += 1
		v, ok := strconv.parse_f64(rest[:end])
		return ok ? v : nil
	}
	return read(line, " min="), read(line, " max=")
}

// --- the messages ---------------------------------------------------------------

/*
The live values' and scrubs' messages: the watches, a value sent to the game, a node picked, a
scrubbed value written back.

Returns:
- Whether `m` was one of them
*/
CodeLive_Update :: proc(state: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case Code_Live_Watch:
		Live_Watch(state, v.lines)
	case Code_Scrub_Changed:
		Live_Send(state, fmt.tprintf("set %s %s %s", v.id, v.property, v.value))
	case Code_Live_Picked:
		live := &state.live
		if old, ok := live.codePicks[v.script]; ok {
			delete(old.id)
			live.codePicks[v.script] = {strings.clone(v.id), hash.fnv64a(transmute([]byte)live.selected), state.selectedNode}
		} else {
			live.codePicks[strings.clone(v.script)] = {strings.clone(v.id), hash.fnv64a(transmute([]byte)live.selected), state.selectedNode}
		}
		live.treeGeneration += 1
	case Code_Scrub_Write:
		logLine(state, .Info, strings.clone(CodeLive_Write(state, v)))
	case:
		return false
	}
	return true
}

/*
Writes a scrubbed value back where the scrub's menu said: the code's default (an edit in the code
tab, one undo step there), the node's own value (the caller's undo step: History_Classify), or
nowhere (the game keeps it).

Returns:
- What happened, for the Console (temp allocated)
*/
CodeLive_Write :: proc(state: ^State, w: Code_Scrub_Write) -> string {
	switch w.kind {
	case .Game_Only:
		return fmt.tprintf("%s = %s in the running game only (the project isn't changed)", w.field, w.value)
	case .Code_Default:
		text, _, _ := CodeEditor_Buffer(w.path, true)
		lines := strings.split_lines(text, context.temp_allocator)
		if w.line >= len(lines) || w.end > len(lines[w.line]) || lines[w.line][w.start:w.end] != w.literal {
			return "The default changed in the code meanwhile: nothing was written"
		}
		edit := ce.Text_Edit{start = {w.line, w.start}, end = {w.line, w.end}, text = w.text}
		if !CodeEditor_ApplyEdits(w.path, {edit}) do return "The code tab with the default isn't open"
		return fmt.tprintf("%s's default is %s in the code (save it: hot reload restarts the game with it)", w.field, w.text)
	case .Node_Value:
		if w.scene < 0 || w.scene >= len(state.project.scenes) || w.node < 0 || w.node >= len(state.project.scenes[w.scene].nodes) do return "The node isn't in the project's scene"
		n := &state.project.scenes[w.scene].nodes[w.node]
		props := codeLiveProps(n, w.script)
		if props == nil do return fmt.tprintf("%s doesn't run %s in the project", n.name, w.script)
		defaultValue := w.defaultValue
		if desc := ScriptCatalog_Find(&state.scripts, w.script); desc != nil {
			for f in desc.fields do if f.name == w.field do defaultValue = f.defaultValue
		}
		Props_Set(props, w.field, w.value, defaultValue)
		return fmt.tprintf("%s of %s is %s (its own value, in the inspector)", w.field, n.name, w.value)
	}
	return ""
}
