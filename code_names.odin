package crossfire_editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import e "engine:."

/*
Project-aware strings: completion and problems for the names engine calls take
(name_kinds.odin says which parameter takes which kind), from what the editor knows of the
project. Two providers of code_editor's, registered with the others (code_providers.odin):

- **Completion** (`nameCompletions`; '"' and '/' open it): inside a string argument, the names
  that fit there; in the argument but outside a string, the typed constants of that kind first
  (scripts/assets.odin's `SCENE_`, `ANIM_`, `PATH_`...).
- **Diagnostics** (`nameDiagnostics`): a string literal the project has no such name for gets a
  warning, "did you mean" the closest, with quick fixes: that name, or its constant.

**What fits where:**
- **Node paths** (`Node_FindPath`, `Node_FindChild`, `Scene_FindNode`, `Camera2D_SetFollowTargetPath`)
  are resolved in the scene trees, from the call's first argument: `self.node` (or `x.node`) is
  the node running the script, `self.field` a node field of the script (its value on that node,
  else its default, as a path from it), a scene its whole tree. The script is the one whose
  procedure it is (its first parameter's type, else the file's only script); it runs on every
  node the scenes and components attach it to (`scriptUsers`), and a component's nodes are
  followed into every instance of it, so ".." leaves the component. **Each attachment is checked
  apart**, and a path that fails from some of them says from which. Children made while the game
  runs (an LDtkLevel's, a TileMap's) aren't known: paths into them aren't reported.
- **Animations, states and parameters, clips, dialogue nodes:** the receiver's (a node field's
  sprite, state machine, Animator, DialogueBox); otherwise every one in the project, those of
  nodes under the script's node first. A receiver that isn't known is checked against the
  project's whole list.
- **Actions, groups, buses, scenes, achievements, sound files:** the project's, plus what code
  declares (`Node_AddToGroup(node, "x")`, `Audio_AddBus("x")`, `Input_AddAction`,
  `Game_CreateScene`). Sound files are checked on disk.
- **Only literal strings** are checked (the script index records them: name_kinds.odin, the
  index's `IndexCall`); a name built at run time (a variable, `fmt.tprintf`, an escape) isn't.

Everything is worked out when asked from data the editor has (temp allocated): the trees are
walked lazily (`NameTree`), the constants come from the providers' cache.
*/

// The node kinds whose children are made while the game runs (paths below them aren't known)
@(private="file")
OPEN_KINDS :: bit_set[NodeKind]{.LDtkLevel, .TileMap}

// The most attachments of a script followed (instances of instances count)
@(private="file")
MAX_ATTACHMENTS :: 32

// --- the scenes' trees, components followed into their instances -----------------------

// A place in the project's trees: a node of a scene or component, or a scene's top level
// (`node` -1), and, inside a component instance, the place of that instance
@(private="file")
PathLoc :: struct {
	scene, node: int,
	// The instance this component node is reached through (an index into the tree's locs);
	// LOC_OUTSIDE: a scene's own node; LOC_UNKNOWN: a component not instanced anywhere
	up: int,
}

@(private="file") LOC_OUTSIDE :: -1
@(private="file") LOC_UNKNOWN :: -2

// The places looked at so far (temp allocated)
@(private="file")
NameTree :: struct {
	project: ^Project,
	locs: [dynamic]PathLoc,
}

@(private="file")
treeMake :: proc(project: ^Project) -> NameTree {
	return {project, make([dynamic]PathLoc, context.temp_allocator)}
}

@(private="file")
treeAdd :: proc(tree: ^NameTree, loc: PathLoc) -> int {
	for l, i in tree.locs do if l == loc do return i
	append(&tree.locs, loc)
	return len(tree.locs) - 1
}

// The node at a place (nil: a scene's top level)
@(private="file")
treeNode :: proc(tree: ^NameTree, at: int) -> ^NodeDef {
	loc := tree.locs[at]
	if loc.node < 0 do return nil
	return &tree.project.scenes[loc.scene].nodes[loc.node]
}

// How deep a place is in instances (to stop components holding themselves)
@(private="file")
treeDepth :: proc(tree: ^NameTree, at: int) -> int {
	depth := 0
	for up := tree.locs[at].up; up >= 0 && depth < 8; up = tree.locs[up].up do depth += 1
	return depth
}

// A component's root (its first top-level node; -1 none)
@(private="file")
componentRoot :: proc(scene: ^SceneDef) -> int {
	for n, i in scene.nodes do if n.parent < 0 do return i
	return -1
}

// The children of a place: the scene's, and an instance's component's root's children
@(private="file")
treeChildren :: proc(tree: ^NameTree, at: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	loc := tree.locs[at]
	scene := &tree.project.scenes[loc.scene]
	for &n, i in scene.nodes do if n.parent == loc.node do append(&out, treeAdd(tree, {loc.scene, i, loc.up}))
	if node := treeNode(tree, at); node != nil && node.kind == .Component && node.component != "" && treeDepth(tree, at) < 6 {
		if c := Project_FindComponent(tree.project, node.component); c >= 0 && c != loc.scene {
			comp := &tree.project.scenes[c]
			root := componentRoot(comp)
			if root >= 0 do for &n, i in comp.nodes do if n.parent == root do append(&out, treeAdd(tree, {c, i, at}))
		}
	}
	return out[:]
}

// The child of a place with a name (-1 none)
@(private="file")
treeChild :: proc(tree: ^NameTree, at: int, name: string) -> int {
	for c in treeChildren(tree, at) do if treeNode(tree, c).name == name do return c
	return -1
}

// Where a lookup could go: a place, nowhere (the engine finds nothing), or not known here
@(private="file")
PathStatus :: enum {
	Found,
	Missing,
	Unknown,
}

// The parent of a place: the node above, the instance a component's root stands for, or the
// scene's top level (Missing above the top; Unknown above a component not instanced)
@(private="file")
treeParent :: proc(tree: ^NameTree, at: int) -> (int, PathStatus) {
	loc := tree.locs[at]
	if loc.node < 0 do return -1, .Missing
	scene := &tree.project.scenes[loc.scene]
	p := scene.nodes[loc.node].parent
	component := Scene_IsComponent(scene)
	if p < 0 {
		if !component do return treeAdd(tree, {loc.scene, -1, LOC_OUTSIDE}), .Found
		if loc.up >= 0 do return treeParent(tree, loc.up)
		return -1, .Unknown
	}
	if component && scene.nodes[p].parent < 0 {
		if loc.up >= 0 do return loc.up, .Found
	}
	return treeAdd(tree, {loc.scene, p, loc.up}), .Found
}

// The top level of the scene a place is in (through instances); Unknown in a component not
// instanced
@(private="file")
treeTop :: proc(tree: ^NameTree, at: int) -> (int, PathStatus) {
	loc := tree.locs[at]
	for Scene_IsComponent(&tree.project.scenes[loc.scene]) {
		if loc.up < 0 do return -1, .Unknown
		loc = tree.locs[loc.up]
	}
	return treeAdd(tree, {loc.scene, -1, LOC_OUTSIDE}), .Found
}

// "ForestScene/World/Hero": a place's scene and names down to it
@(private="file")
treeLabel :: proc(tree: ^NameTree, at: int) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	cur := at
	for guard := 0; cur >= 0 && guard < 64; guard += 1 {
		loc := tree.locs[cur]
		if loc.node < 0 {
			inject_at(&parts, 0, tree.project.scenes[loc.scene].name)
			break
		}
		inject_at(&parts, 0, treeNode(tree, cur).name)
		p, status := treeParent(tree, cur)
		if status != .Found {
			// A component not instanced: its name
			scene := &tree.project.scenes[loc.scene]
			if Scene_IsComponent(scene) && scene.nodes[loc.node].parent >= 0 do inject_at(&parts, 0, ComponentName(scene.component))
			break
		}
		cur = p
	}
	return strings.join(parts[:], "/", context.temp_allocator)
}

// The result of following a path
@(private="file")
PathResult :: struct {
	status: PathStatus,
	// Found: where it leads
	loc: int,
	// Missing: the segment that wasn't there (its index in `segments`) and the place it was
	// looked for under
	failed, under: int,
	segments: []string,
}

/*
Follows a path as the engine's lookup for its kind does: `Node_FindPath` (".." and "." and a
leading "/"), `Node_FindChild` (names only), `Scene_FindNode` (from `start`, a scene's top level:
a bare name anywhere, "A/B" from a top-level A, "/A/B"). `allowTop`: ending at a scene's top
level counts as found (completion's folders).
*/
@(private="file")
treeResolve :: proc(tree: ^NameTree, start: int, path: string, kind: NameKind, allowTop := false) -> PathResult {
	segments := strings.split(path, "/", context.temp_allocator)
	out := PathResult{status = .Found, loc = start, segments = segments}
	cur := start
	first := 0
	switch kind {
	case .Scene_Path:
		if strings.has_prefix(path, "/") {
			first = 1
		} else if strings.index_byte(path, '/') < 0 {
			// A bare name: any node of the scene
			if found := treeFind(tree, start, path); found >= 0 do return {status = .Found, loc = found, segments = segments}
			return {status = treeHasOpen(tree, start) ? .Unknown : .Missing, failed = 0, under = start, segments = segments}
		}
	case .Node_Path:
		if strings.has_prefix(path, "/") {
			top, status := treeTop(tree, start)
			if status != .Found do return {status = status, segments = segments}
			cur = top
			first = 1
		}
	case .Child_Path:
	case .None, .Animation, .Action, .Group, .Bus, .Scene, .State, .State_Param, .Clip, .Dialogue_Node, .Achievement, .Sound_Path:
	}
	for i in first ..< len(segments) {
		seg := segments[i]
		if kind == .Node_Path && (seg == "" || seg == ".") do continue
		if kind == .Node_Path && seg == ".." {
			p, status := treeParent(tree, cur)
			if status != .Found do return {status = status, failed = i, under = cur, segments = segments}
			cur = p
			continue
		}
		next := treeChild(tree, cur, seg)
		if next < 0 {
			node := treeNode(tree, cur)
			if node != nil && node.kind in OPEN_KINDS do return {status = .Unknown, segments = segments}
			return {status = .Missing, failed = i, under = cur, segments = segments}
		}
		cur = next
	}
	// The engine finds no node at a scene's top level itself
	if tree.locs[cur].node < 0 && !allowTop do return {status = .Missing, failed = len(segments) - 1, under = cur, segments = segments}
	out.loc = cur
	return out
}

// The first node named so under a place, depth first (-1 none)
@(private="file")
treeFind :: proc(tree: ^NameTree, at: int, name: string, depth := 0) -> int {
	if depth > 12 do return -1
	for c in treeChildren(tree, at) {
		if treeNode(tree, c).name == name do return c
		if found := treeFind(tree, c, name, depth + 1); found >= 0 do return found
	}
	return -1
}

// Whether a node under a place makes children while the game runs
@(private="file")
treeHasOpen :: proc(tree: ^NameTree, at: int, depth := 0) -> bool {
	if depth > 12 do return false
	for c in treeChildren(tree, at) {
		if treeNode(tree, c).kind in OPEN_KINDS do return true
		if treeHasOpen(tree, c, depth + 1) do return true
	}
	return false
}

// Every node name under a place (temp allocated)
@(private="file")
treeNames :: proc(tree: ^NameTree, at: int, out: ^[dynamic]string, depth := 0) {
	if depth > 12 || len(out) > 2000 do return
	for c in treeChildren(tree, at) {
		append(out, treeNode(tree, c).name)
		treeNames(tree, c, out, depth + 1)
	}
}

// --- which script, and where it runs ----------------------------------------------------

// A node running the script: its place, and its values for the script's fields
@(private="file")
Attachment :: struct {
	loc: int,
	props: []ScriptPropDef,
}

/*
The script whose code a procedure is: its first parameter's type when that's a registered
script, else the file's only script ("" when it can't be told).
*/
@(private)
nameScriptOf :: proc(state: ^State, file: ^IndexFile, selfType: string) -> string {
	if selfType != "" {
		if ScriptCatalog_Find(&state.scripts, selfType) != nil || ScriptCatalog_FindNodeType(&state.scripts, selfType) != nil do return selfType
	}
	if file == nil do return ""
	only := ""
	for r in file.registrations {
		if r.kind == .Data do continue
		if only != "" do return ""
		only = r.name
	}
	return only
}

// The places a component's node is in: one per instance (instances of instances followed)
@(private="file")
placesOf :: proc(tree: ^NameTree, scene, node: int, depth := 0) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	def := &tree.project.scenes[scene]
	if !Scene_IsComponent(def) {
		append(&out, treeAdd(tree, {scene, node, LOC_OUTSIDE}))
		return out[:]
	}
	isRoot := def.nodes[node].parent < 0
	if depth < 4 {
		for &other, si in tree.project.scenes {
			if si == scene do continue
			for &n, ni in other.nodes {
				if n.kind != .Component || n.component != def.component do continue
				for outer in placesOf(tree, si, ni, depth + 1) {
					if len(out) >= MAX_ATTACHMENTS do break
					// The instance is the root; the root's descendants are reached through it
					append(&out, isRoot ? outer : treeAdd(tree, {scene, node, outer}))
				}
			}
		}
	}
	if len(out) == 0 do append(&out, treeAdd(tree, {scene, node, LOC_UNKNOWN}))
	return out[:]
}

// The nodes running a script, as places (components into their instances), with its values
@(private="file")
attachmentsOf :: proc(state: ^State, tree: ^NameTree, script: string) -> []Attachment {
	out := make([dynamic]Attachment, context.temp_allocator)
	if script == "" do return nil
	for u in scriptUsers(state, script) {
		if u.node < 0 do continue
		node := &state.project.scenes[u.scene].nodes[u.node]
		props := node.props[:]
		if node.customKind == script do props = node.customProps[:]
		for &more in node.moreScripts do if more.name == script do props = more.props[:]
		for place in placesOf(tree, u.scene, u.node) {
			if len(out) >= MAX_ATTACHMENTS do break
			append(&out, Attachment{place, props})
		}
	}
	return out[:]
}

// What a call names things from: its first argument resolved from an attachment (a place, or
// unknown)
@(private="file")
receiverAt :: proc(state: ^State, tree: ^NameTree, script, receiver: string, kind: NameKind, att: Attachment) -> (int, bool) {
	if kind == .Scene_Path {
		top, status := treeTop(tree, att.loc)
		return top, status == .Found
	}
	text := strings.trim_prefix(receiver, "&")
	text = strings.trim_suffix(text, ".animation")
	parts := strings.split(text, ".", context.temp_allocator)
	if len(parts) != 2 do return -1, false
	if parts[1] == "node" do return att.loc, true
	desc := ScriptCatalog_Find(&state.scripts, script)
	if desc == nil do desc = ScriptCatalog_FindNodeType(&state.scripts, script)
	if desc == nil do return -1, false
	for &f in desc.fields do if f.type == .Node && f.name == parts[1] {
		value := Props_Value(att.props, f.name, f.defaultValue)
		if value == "" do return -1, false
		r := treeResolve(tree, att.loc, value, .Node_Path)
		return r.loc, r.status == .Found
	}
	return -1, false
}

// --- the names of each kind ----------------------------------------------------------------

// The node kind a receiver of names is
@(private="file")
receiverKind :: proc(kind: NameKind) -> (NodeKind, bool) {
	#partial switch kind {
	case .Animation:     return .AnimatedSprite, true
	case .State, .State_Param: return .StateMachine, true
	case .Clip:          return .Animator, true
	case .Dialogue_Node: return .DialogueBox, true
	}
	return .Node2D, false
}

// The names a node has of a kind (a sprite's animations, a machine's states...; temp allocated)
@(private="file")
nodeNames :: proc(project: ^Project, node: ^NodeDef, kind: NameKind) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	#partial switch kind {
	case .Animation:
		if node.kind != .AnimatedSprite do break
		if node.animationSet == "" {
			for a in node.animations do append(&out, a.name)
			break
		}
		for &set in project.animationSets do if set.path == node.animationSet do for a in set.animations do append(&out, a.name)
		if len(out) == 0 && e.Aseprite_IsFile(node.animationSet) {
			names, _ := asepriteTagNames(project.rootPath, node.animationSet)
			for n in names do append(&out, n)
		}
	case .State:
		if node.kind == .StateMachine do for s in node.stateMachine.states do append(&out, s.name)
	case .State_Param:
		if node.kind == .StateMachine do for p in node.stateMachine.params do append(&out, p.name)
	case .Clip:
		if node.kind == .Animator do for c in node.animator.clips do append(&out, c.name)
	case .Dialogue_Node:
		if node.kind != .DialogueBox do break
		for &d in project.dialogues do if d.path == node.dialogue do for n in d.data.nodes do append(&out, n.name)
	}
	return out[:]
}

// Names declared by code anywhere in the scripts (`Node_AddToGroup(node, "x")`...)
@(private="file")
declaredNames :: proc(state: ^State, table: ^NameTable, kind: NameKind, out: ^[dynamic]string) {
	for _, &f in state.scriptIndex.files do for c in f.calls {
		k, declares := NameTable_ParamKind(table, c.procName, c.argument, c.argName)
		if k == kind && declares && c.value != "" do append(out, c.value)
	}
}

/*
Every name of a kind the project has (sorted, once each; temp allocated): its actions, groups,
buses, scenes..., or for the receiver kinds every node's and file's.
*/
@(private="file")
projectNames :: proc(state: ^State, table: ^NameTable, kind: NameKind) -> []string {
	project := &state.project
	out := make([dynamic]string, context.temp_allocator)
	#partial switch kind {
	case .Action:
		for a in project.actions do append(&out, a.name)
		declaredNames(state, table, kind, &out)
	case .Group:
		for &scene in project.scenes do for &node in scene.nodes {
			rest := node.groups
			for part in strings.split_iterator(&rest, ",") do if g := strings.trim_space(part); g != "" do append(&out, g)
		}
		declaredNames(state, table, kind, &out)
	case .Bus:
		for b in project.buses do append(&out, b.name)
		declaredNames(state, table, kind, &out)
	case .Scene:
		for &scene in project.scenes do if !Scene_IsComponent(&scene) do append(&out, scene.name)
		declaredNames(state, table, kind, &out)
	case .Achievement:
		for a in project.achievements do append(&out, a.name)
	case .Sound_Path:
		for a in project.assets do if a.kind == .Audio || a.kind == .Music do append(&out, a.path)
	case .Animation:
		for &set in project.animationSets do for a in set.animations do append(&out, a.name)
		for a in project.assets do if a.kind == .Image && e.Aseprite_IsFile(a.path) {
			names, _ := asepriteTagNames(project.rootPath, a.path)
			for n in names do append(&out, n)
		}
		for &scene in project.scenes do for &node in scene.nodes do if node.kind == .AnimatedSprite && node.animationSet == "" do for a in node.animations do append(&out, a.name)
	case .State, .State_Param, .Clip:
		for &scene in project.scenes do for &node in scene.nodes do for n in nodeNames(project, &node, kind) do append(&out, n)
	case .Dialogue_Node:
		for &d in project.dialogues do for n in d.data.nodes do append(&out, n.name)
	}
	return uniqueSorted(out[:])
}

@(private="file")
uniqueSorted :: proc(names: []string) -> []string {
	slice.sort(names)
	out := make([dynamic]string, context.temp_allocator)
	for n, i in names do if n != "" && (i == 0 || n != names[i - 1]) do append(&out, n)
	return out[:]
}

// The names of the nodes of a kind under the attachments (theirs first in completion)
@(private="file")
nearNames :: proc(state: ^State, tree: ^NameTree, attachments: []Attachment, kind: NameKind) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	want, ok := receiverKind(kind)
	if !ok do return nil
	visit :: proc(state: ^State, tree: ^NameTree, at: int, want: NodeKind, kind: NameKind, out: ^[dynamic]string, depth: int) {
		if depth > 4 do return
		if node := treeNode(tree, at); node != nil && node.kind == want do for n in nodeNames(&state.project, node, kind) do append(out, n)
		for c in treeChildren(tree, at) do visit(state, tree, c, want, kind, out, depth + 1)
	}
	for att in attachments do visit(state, tree, att.loc, want, kind, &out, 0)
	return uniqueSorted(out[:])
}

// --- matching -------------------------------------------------------------------------------

// The edit distance of two names, ignoring case
@(private="file")
nameDistance :: proc(a, b: string) -> int {
	lower :: proc(c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + 32 : c }
	if len(a) > 64 || len(b) > 64 do return max(len(a), len(b))
	prev, cur: [65]int
	for j in 0 ..= len(b) do prev[j] = j
	for i in 1 ..= len(a) {
		cur[0] = i
		for j in 1 ..= len(b) {
			cost := lower(a[i - 1]) == lower(b[j - 1]) ? 0 : 1
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		}
		prev = cur
	}
	return prev[len(b)]
}

/*
The name closest to a misspelled one ("" when none is close: at most a third of its letters
apart, at least one; a difference of case alone always is).
*/
@(private)
Names_Closest :: proc(name: string, candidates: []string) -> string {
	best, bestDistance := "", max(int)
	limit := max(1, len(name) / 3)
	for c in candidates {
		if c == name do continue
		d := nameDistance(name, c)
		if strings.equal_fold(c, name) do d = 0
		if d < bestDistance || d == bestDistance && len(c) < len(best) do best, bestDistance = c, d
	}
	return bestDistance <= limit ? best : ""
}

// Whether a name starts with a prefix, ignoring case
@(private="file")
hasPrefixFold :: proc(name, prefix: string) -> bool {
	return len(name) >= len(prefix) && strings.equal_fold(name[:len(prefix)], prefix)
}

// --- the call around a position (completion) -------------------------------------------------

// A name argument: what kind it takes, of which call, in which script
@(private="file")
NameUse :: struct {
	kind: NameKind,
	declares: bool,
	procName: string,
	receiver: string,
	script: string,
}

// The text between two buffer positions (temp allocated)
@(private="file")
bufferText :: proc(b: ^cebuf.Buffer, from, to: cebuf.Position) -> string {
	if cebuf.position_less(to, from) do return ""
	sb := strings.builder_make(context.temp_allocator)
	for line in from.line ..= to.line {
		if line >= cebuf.buffer_line_count(b) do break
		text := cebuf.buffer_line_str(b, line)
		start := line == from.line ? min(from.col, len(text)) : 0
		end := line == to.line ? min(to.col, len(text)) : len(text)
		if start < end do strings.write_string(&sb, text[start:end])
		if line != to.line do strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}

// A call's first argument as written, spaces removed (from its '(' to the first ',' outside
// brackets and strings, or `limit`)
@(private="file")
firstArgument :: proc(b: ^cebuf.Buffer, open, limit: cebuf.Position) -> string {
	text := bufferText(b, {open.line, open.col + 1}, limit)
	depth := 0
	quote: u8 = 0
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(text) {
		c := text[i]
		if quote != 0 {
			if c == quote && (i == 0 || text[i - 1] != '\\') do quote = 0
			strings.write_byte(&sb, c)
			continue
		}
		switch c {
		case '"', '`', '\'': quote = c
		case '(', '[', '{': depth += 1
		case ')', ']', '}': depth -= 1
		case ',': if depth == 0 do return strings.to_string(sb)
		}
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' do strings.write_byte(&sb, c)
	}
	return strings.to_string(sb)
}

// The name argument at a position of a project script, if it is one
@(private="file")
nameUseAt :: proc(state: ^State, table: ^NameTable, doc: ce.Provider_Document, pos: cebuf.Position, syntax: ce.Syntax_Context) -> (use: NameUse, ok: bool) {
	if syntax.kind != .Call_Argument do return
	dot := strings.last_index_byte(syntax.call_name, '.')
	if dot < 0 do return
	file := ScriptIndex_File(&state.scriptIndex, absolutePath(doc.path))
	alias := file != nil && file.engineAlias != "" ? file.engineAlias : "e"
	if syntax.call_name[:dot] != alias do return
	use.procName = syntax.call_name[dot + 1:]
	// A named argument: `bus = "SFX"`
	argName := ""
	before := strings.trim_left_space(bufferText(doc.buffer, syntax.arg_start, pos))
	n := 0
	for n < len(before) && (before[n] == '_' || before[n] >= 'a' && before[n] <= 'z' || before[n] >= 'A' && before[n] <= 'Z' || n > 0 && before[n] >= '0' && before[n] <= '9') do n += 1
	if n > 0 {
		rest := strings.trim_left_space(before[n:])
		if strings.has_prefix(rest, "=") && !strings.has_prefix(rest, "==") do argName = before[:n]
	}
	use.kind, use.declares = NameTable_ParamKind(table, use.procName, syntax.argument, argName)
	if use.kind == .None do return
	use.receiver = syntax.argument == 0 && argName == "" ? "" : firstArgument(doc.buffer, syntax.open, pos)
	// The procedure it's in: the innermost of the index's around the line
	selfType := ""
	if file != nil {
		best := -1
		for p, i in file.procs {
			if p.startLine > pos.line + 1 || p.endLine < pos.line + 1 do continue
			if best < 0 || p.endLine - p.startLine < file.procs[best].endLine - file.procs[best].startLine do best = i
		}
		if best >= 0 do selfType = file.procs[best].selfType
	}
	use.script = nameScriptOf(state, file, selfType)
	return use, true
}

// --- what fits: candidates ------------------------------------------------------------------

// A name that fits an argument
@(private="file")
NameCandidate :: struct {
	name, detail, about: string,
	priority: int,
}

// The constants' section for a kind (none: there are no constants of it)
@(private="file")
kindSection :: proc(kind: NameKind) -> (ConstantSection, string, bool) {
	#partial switch kind {
	case .Node_Path, .Child_Path, .Scene_Path: return .Node_Paths, "PATH_", true
	case .Animation:     return .Animations, "ANIM_", true
	case .Action:        return .Actions, "ACTION_", true
	case .Group:         return .Groups, "GROUP_", true
	case .Bus:           return .Buses, "BUS_", true
	case .Scene:         return .Scenes, "SCENE_", true
	case .State:         return .States, "STATE_", true
	case .State_Param:   return .States, "PARAM_", true
	case .Dialogue_Node: return .Dialogue_Nodes, "DIALOGUE_NODE_", true
	case .Achievement:   return .Achievements, "ACHIEVEMENT_", true
	}
	return .Assets, "", false
}

// A constant's value as a name (its text without the quotes; "" when it isn't a string)
@(private="file")
constantText :: proc(c: GeneratedConstant) -> string {
	if len(c.value) < 2 || c.value[0] != '"' do return ""
	return c.value[1:len(c.value) - 1]
}

// The names a receiver kind fits at a use: per attachment (known: all resolved), the near ones
@(private="file")
receiverNames :: proc(state: ^State, tree: ^NameTree, use: NameUse, attachments: []Attachment) -> (names: [][]string, known: bool) {
	want, _ := receiverKind(use.kind)
	out := make([][]string, len(attachments), context.temp_allocator)
	if len(attachments) == 0 do return out, false
	for att, i in attachments {
		at, ok := receiverAt(state, tree, use.script, use.receiver, use.kind, att)
		if !ok do return out, false
		node := treeNode(tree, at)
		if node == nil || node.kind != want do return out, false
		out[i] = nodeNames(&state.project, node, use.kind)
	}
	return out, true
}

// The path candidates for what's typed so far (`dir`: up to its last '/'), from each attachment
@(private="file")
pathCandidates :: proc(state: ^State, tree: ^NameTree, use: NameUse, attachments: []Attachment, dir: string, out: ^[dynamic]NameCandidate) {
	Seen :: struct { count: int, kind: NodeKind, top: bool }
	seen := make(map[string]Seen, allocator = context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	add :: proc(seen: ^map[string]Seen, order: ^[dynamic]string, name: string, kind: NodeKind, top: bool) {
		s, had := seen[name]
		if !had do append(order, name)
		s.count += 1
		if top do s.kind = kind
		s.top ||= top
		seen[name] = s
	}
	bases := 0
	parentName := ""
	for att in attachments {
		base, ok := receiverAt(state, tree, use.script, use.receiver, use.kind, att)
		if !ok do continue
		at := base
		if dir != "" {
			// The folder typed so far (a scene's top level counts: "/", "../" from a top-level node)
			folder := strings.trim_suffix(dir, "/")
			if use.kind == .Scene_Path && !strings.has_prefix(folder, "/") do folder = fmt.tprintf("/%s", folder)
			if folder == "" do folder = "/"
			r := treeResolve(tree, base, folder, use.kind, allowTop = true)
			if r.status != .Found do continue
			at = r.loc
		}
		bases += 1
		for c in treeChildren(tree, at) do add(&seen, &order, treeNode(tree, c).name, treeNode(tree, c).kind, true)
		if use.kind == .Scene_Path && dir == "" {
			// A bare name finds a node anywhere in the scene
			names := make([dynamic]string, context.temp_allocator)
			treeNames(tree, at, &names)
			for n in names do add(&seen, &order, n, .Node2D, false)
		}
		if use.kind == .Node_Path && parentName == "" && (dir == "" || strings.has_suffix(dir, "../")) {
			if p, status := treeParent(tree, at); status == .Found {
				parentName = treeNode(tree, p) != nil ? treeNode(tree, p).name : "the scene's top level"
			}
		}
	}
	if bases == 0 do return
	for name in order {
		s := seen[name]
		detail := s.top ? fmt.tprint(s.kind) : "anywhere in the scene"
		if s.count < bases && bases > 1 do detail = fmt.tprintf("%s (from %d of %d nodes)", detail, min(s.count, bases), bases)
		append(out, NameCandidate{name = name, detail = detail, about = fmt.tprintf("Node %s%s", dir, name), priority = s.top ? 25 : 15})
	}
	if use.kind == .Node_Path && parentName != "" {
		append(out, NameCandidate{name = "..", detail = "the parent", about = fmt.tprintf("Up to %s", parentName), priority = 20})
	}
}

// The candidates of a kind that isn't a path
@(private="file")
nameCandidates :: proc(state: ^State, table: ^NameTable, tree: ^NameTree, use: NameUse, attachments: []Attachment, out: ^[dynamic]NameCandidate) {
	word := NAME_KIND_WORDS[use.kind]
	if _, receiver := receiverKind(use.kind); receiver {
		names, known := receiverNames(state, tree, use, attachments)
		if known {
			seen := make(map[string]bool, allocator = context.temp_allocator)
			for list in names do for n in list {
				if n == "" || n in seen do continue
				seen[n] = true
				append(out, NameCandidate{name = n, detail = word, about = fmt.tprintf("The %s %q of the node %s names", word, n, use.receiver), priority = 25})
			}
			return
		}
		near := nearNames(state, tree, attachments, use.kind)
		nearSet := make(map[string]bool, allocator = context.temp_allocator)
		for n in near do nearSet[n] = true
		for n in projectNames(state, table, use.kind) {
			isNear := n in nearSet
			append(out, NameCandidate{name = n, detail = isNear ? fmt.tprintf("%s, under this script's node", word) : word, about = fmt.tprintf("A %s of the project", word), priority = isNear ? 25 : 15})
		}
		return
	}
	for n in projectNames(state, table, use.kind) do append(out, NameCandidate{name = n, detail = word, about = fmt.tprintf("The project's %s %q", word, n), priority = 25})
}

// --- the providers ----------------------------------------------------------------------------

// Where the string the position is in starts (the column after its opening quote; -1 none)
@(private="file")
stringStart :: proc(line: string, col: int) -> int {
	for i := min(col, len(line)) - 1; i >= 0; i -= 1 {
		if line[i] != '"' && line[i] != '`' do continue
		slashes := 0
		for j := i - 1; j >= 0 && line[j] == '\\'; j -= 1 do slashes += 1
		if slashes % 2 == 0 do return i + 1
	}
	return -1
}

// Whether a name kind is a node path
@(private="file")
isPathKind :: proc(kind: NameKind) -> bool {
	return kind == .Node_Path || kind == .Child_Path || kind == .Scene_Path
}

@(private)
nameCompletions :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, out: ^[dynamic]ce.Provider_Completion) {
	state := codeProvidersState()
	table := NameTable_Get()
	if table == nil || !isProjectScript(state, doc.path) do return
	use, ok := nameUseAt(state, table, doc, pos, ctx.syntax)
	if !ok do return
	tree := treeMake(&state.project)
	attachments := attachmentsOf(state, &tree, use.script)

	if !ctx.syntax.in_string {
		// Outside a string: the typed constants of the kind, first
		section, prefix, has := kindSection(use.kind)
		if !has do return
		allowed := make(map[string]bool, allocator = context.temp_allocator)
		if !isPathKind(use.kind) {
			cands := make([dynamic]NameCandidate, context.temp_allocator)
			nameCandidates(state, table, &tree, use, attachments, &cands)
			for c in cands do allowed[c.name] = true
		}
		for c in CodeProviders_Constants(state) {
			if c.section != section || !strings.has_prefix(c.name, prefix) do continue
			text := constantText(c)
			if isPathKind(use.kind) {
				if !constantResolves(state, &tree, use, attachments, text) do continue
			} else if text not_in allowed {
				continue
			}
			append(out, ce.Provider_Completion{label = c.name, detail = "string", documentation = fmt.tprintf("%s\n\nscripts/assets.odin (generated by the editor)", c.about), kind = 21, priority = 30})
		}
		return
	}

	line := cebuf.buffer_line_str(doc.buffer, pos.line)
	open := stringStart(line, pos.col)
	if open < 0 do return
	typed := line[open:min(pos.col, len(line))]
	replaceFrom := open
	segment := typed
	cands := make([dynamic]NameCandidate, context.temp_allocator)
	if isPathKind(use.kind) {
		slash := strings.last_index_byte(typed, '/')
		dir := typed[:slash + 1]
		segment = typed[slash + 1:]
		replaceFrom = open + slash + 1
		pathCandidates(state, &tree, use, attachments, dir, &cands)
	} else {
		nameCandidates(state, table, &tree, use, attachments, &cands)
	}
	// What was typed before the word the list filters by ("Boss " of "Boss R")
	before := strings.has_suffix(segment, ctx.prefix) ? segment[:len(segment) - len(ctx.prefix)] : segment
	for c in cands {
		if !hasPrefixFold(c.name, before) do continue
		append(out, ce.Provider_Completion{
			label = c.name, detail = c.detail, documentation = c.about,
			insert_text = c.name, filter_text = c.name[len(before):],
			kind = isPathKind(use.kind) ? 9 : 12, priority = c.priority,
			replace_start = replaceFrom,
		})
	}
}

// Whether a path constant's value leads to a node from every attachment (some, at least)
@(private="file")
constantResolves :: proc(state: ^State, tree: ^NameTree, use: NameUse, attachments: []Attachment, path: string) -> bool {
	if path == "" do return false
	found := 0
	for att in attachments {
		base, ok := receiverAt(state, tree, use.script, use.receiver, use.kind, att)
		if !ok do continue
		r := treeResolve(tree, base, path, use.kind)
		if r.status == .Missing do return false
		if r.status == .Found do found += 1
	}
	return found > 0
}

// A problem with a name: its message, the name to put instead ("" none) and its constant
@(private="file")
NameProblem :: struct {
	message: string,
	suggestion: string,
	constant: string,
}

@(private)
nameDiagnostics :: proc(doc: ce.Provider_Document, ctx: ce.Provider_Context, out: ^[dynamic]ce.Provider_Diagnostic) {
	state := codeProvidersState()
	table := NameTable_Get()
	if table == nil || !isProjectScript(state, doc.path) do return
	file := ScriptIndex_File(&state.scriptIndex, absolutePath(doc.path))
	if file == nil do return
	tree := treeMake(&state.project)
	for call in file.calls {
		kind, declares := NameTable_ParamKind(table, call.procName, call.argument, call.argName)
		if kind == .None || declares || call.value == "" do continue
		at := relocate(doc, call.line - 1, call.lineText)
		if at < 0 do continue
		use := NameUse{kind = kind, procName = call.procName, receiver = call.receiver, script = nameScriptOf(state, file, call.selfType)}
		problem, bad := Names_Check(state, table, &tree, use, call.value)
		if !bad do continue
		fixes := make([dynamic]ce.Provider_Fix, ctx.allocator)
		edit :: proc(at, column, endColumn: int, text: string, allocator := context.allocator) -> []ce.Text_Edit {
			edits := make([]ce.Text_Edit, 1, allocator)
			edits[0] = {start = {at, column}, end = {at, endColumn}, text = text}
			return edits
		}
		if problem.suggestion != "" {
			append(&fixes, ce.Provider_Fix{title = fmt.aprintf("Replace with %q", problem.suggestion, allocator = ctx.allocator), edits = edit(at, call.column, call.endColumn, fmt.aprintf("%q", problem.suggestion, allocator = ctx.allocator), ctx.allocator), preferred = true})
		}
		if problem.constant != "" {
			append(&fixes, ce.Provider_Fix{title = fmt.aprintf("Use %s", problem.constant, allocator = ctx.allocator), edits = edit(at, call.column, call.endColumn, problem.constant, ctx.allocator)})
		}
		append(out, ce.Provider_Diagnostic{
			start = {at, call.column}, end = {at, call.endColumn},
			severity = .Warning, message = problem.message, source = "crossfire", fixes = fixes[:],
		})
	}
}

/*
Checks a name given to an engine procedure (the diagnostics' work; tests call it).

Returns:
- What's wrong, and whether something is
*/
@(private)
Names_Check :: proc(state: ^State, table: ^NameTable, tree: ^NameTree, use: NameUse, value: string) -> (problem: NameProblem, bad: bool) {
	word := NAME_KIND_WORDS[use.kind]
	if isPathKind(use.kind) do return checkPath(state, tree, use, value)
	if _, receiver := receiverKind(use.kind); receiver {
		attachments := attachmentsOf(state, tree, use.script)
		names, known := receiverNames(state, tree, use, attachments)
		if known {
			failing := make([dynamic]int, context.temp_allocator)
			for list, i in names do if !slice.contains(list, value) do append(&failing, i)
			if len(failing) == 0 do return {}, false
			first := attachments[failing[0]]
			at, _ := receiverAt(state, tree, use.script, use.receiver, use.kind, first)
			where_ := treeLabel(tree, at)
			problem.suggestion = Names_Closest(value, names[failing[0]])
			if len(failing) < len(attachments) {
				problem.message = fmt.tprintf("%s has no %s %q (from %s; the others have it)", where_, word, value, treeLabel(tree, first.loc))
				problem.suggestion = ""
			} else if problem.suggestion != "" {
				problem.message = fmt.tprintf("%s has no %s %q: did you mean %q?", where_, word, value, problem.suggestion)
			} else {
				problem.message = fmt.tprintf("%s has no %s %q", where_, word, value)
			}
			problem.constant = constantFor(state, use.kind, problem.suggestion)
			return problem, true
		}
	}
	all := projectNames(state, table, use.kind)
	if use.kind == .Sound_Path {
		if slice.contains(all, value) || os.exists(joinPath(state.project.rootPath, value, allocator = context.temp_allocator)) do return {}, false
	} else if slice.contains(all, value) {
		return {}, false
	}
	hint := ""
	#partial switch use.kind {
	case .Action: hint = " (Project Settings > Input)"
	case .Bus: hint = " (the Mixer)"
	case .Achievement: hint = " (Project Settings > Steam)"
	}
	problem.suggestion = Names_Closest(value, all)
	if problem.suggestion != "" {
		problem.message = fmt.tprintf("No %s %q%s: did you mean %q?", word, value, hint, problem.suggestion)
	} else {
		problem.message = fmt.tprintf("No %s %q in the project%s", word, value, hint)
	}
	problem.constant = constantFor(state, use.kind, problem.suggestion)
	return problem, true
}

// The constant naming a name of a kind ("" none)
@(private="file")
constantFor :: proc(state: ^State, kind: NameKind, name: string) -> string {
	if name == "" do return ""
	section, prefix, has := kindSection(kind)
	if !has || isPathKind(kind) do return ""
	for c in CodeProviders_Constants(state) do if c.section == section && strings.has_prefix(c.name, prefix) && constantText(c) == name do return c.name
	return ""
}

// A node path checked from every node the script runs on
@(private="file")
checkPath :: proc(state: ^State, tree: ^NameTree, use: NameUse, path: string) -> (problem: NameProblem, bad: bool) {
	attachments := attachmentsOf(state, tree, use.script)
	found := make([dynamic]int, context.temp_allocator)
	missing := make([dynamic]int, context.temp_allocator)
	results := make([]PathResult, len(attachments), context.temp_allocator)
	bases := make([]int, len(attachments), context.temp_allocator)
	for att, i in attachments {
		base, ok := receiverAt(state, tree, use.script, use.receiver, use.kind, att)
		if !ok do continue
		bases[i] = base
		results[i] = treeResolve(tree, base, path, use.kind)
		#partial switch results[i].status {
		case .Found: append(&found, i)
		case .Missing: append(&missing, i)
		}
	}
	if len(missing) == 0 do return {}, false
	from :: proc(tree: ^NameTree, attachments: []Attachment, list: []int) -> string {
		labels := make([dynamic]string, context.temp_allocator)
		for i in list[:min(len(list), 2)] do append(&labels, treeLabel(tree, attachments[i].loc))
		text := strings.join(labels[:], ", ", context.temp_allocator)
		if len(list) > 2 do text = fmt.tprintf("%s and %d more", text, len(list) - 2)
		return text
	}
	if len(found) > 0 {
		problem.message = fmt.tprintf("No node %q from %s (it's there from %s)", path, from(tree, attachments, missing[:]), from(tree, attachments, found[:]))
		return problem, true
	}
	// Did you mean: the failing name replaced by the closest one there, if that path leads
	// somewhere from every node
	first := results[missing[0]]
	if first.failed >= 0 && first.failed < len(first.segments) && first.under >= 0 {
		names := make([dynamic]string, context.temp_allocator)
		if use.kind == .Scene_Path && first.failed == 0 && strings.index_byte(path, '/') < 0 {
			treeNames(tree, first.under, &names)
		} else {
			for c in treeChildren(tree, first.under) do append(&names, treeNode(tree, c).name)
		}
		if best := Names_Closest(first.segments[first.failed], names[:]); best != "" {
			segments := slice.clone(first.segments, context.temp_allocator)
			segments[first.failed] = best
			fixed := strings.join(segments, "/", context.temp_allocator)
			everywhere := true
			for i in missing do if treeResolve(tree, bases[i], fixed, use.kind).status != .Found do everywhere = false
			if everywhere {
				problem.suggestion = fixed
				problem.constant = pathConstantFor(state, tree, use, attachments, bases, missing[:], fixed)
			}
		}
	}
	if problem.suggestion != "" {
		problem.message = fmt.tprintf("No node %q from %s: did you mean %q?", path, from(tree, attachments, missing[:]), problem.suggestion)
	} else {
		problem.message = fmt.tprintf("No node %q from %s", path, from(tree, attachments, missing[:]))
	}
	return problem, true
}

// A PATH_ constant that leads where a path does from every node in `which` ("" none)
@(private="file")
pathConstantFor :: proc(state: ^State, tree: ^NameTree, use: NameUse, attachments: []Attachment, bases: []int, which: []int, path: string) -> string {
	for c in CodeProviders_Constants(state) {
		if c.section != .Node_Paths do continue
		text := constantText(c)
		same := true
		for i in which {
			want := treeResolve(tree, bases[i], path, use.kind)
			got := treeResolve(tree, bases[i], text, use.kind)
			if got.status != .Found || got.loc != want.loc do same = false
		}
		if same do return c.name
	}
	return ""
}

// A node of a scene or component (CodeNames_FieldNodes)
NodeRef :: struct {
	scene, node: int,
}

/*
The nodes a script's node field points to (`self.brain`), from every node running the script:
its value on that node, else the field's default, as a path from it (code actions: a state
machine's states). Each node once.

Returns:
- The nodes (temp allocated); none when nothing runs the script or no path leads anywhere
*/
CodeNames_FieldNodes :: proc(state: ^State, script, field: string) -> []NodeRef {
	tree := treeMake(&state.project)
	out := make([dynamic]NodeRef, context.temp_allocator)
	for att in attachmentsOf(state, &tree, script) {
		at, ok := receiverAt(state, &tree, script, fmt.tprintf("self.%s", field), .Node_Path, att)
		if !ok || at < 0 do continue
		loc := tree.locs[at]
		if loc.node < 0 do continue
		ref := NodeRef{loc.scene, loc.node}
		seen := false
		for r in out do seen ||= r == ref
		if !seen do append(&out, ref)
	}
	return out[:]
}
