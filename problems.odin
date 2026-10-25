package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The Problems tab (TODO.md's "UI and UX" round "Feedback", 2026-10-25): what's wrong with the
project, each row a click away from its cause.

- **What's gathered** (`Problems_Gather`): every scene's and component's nodes' **missing assets**
  (an image, animation sheet, animation asset, component, sound, material, shader, dialogue or
  LDtk file that isn't on disk), **broken node paths** (`NodePaths_Broken`: a camera's target, a
  track's node, a listener's target... that leads to no node), **unresolved references** (a
  script or node type the last scripts build doesn't have), and the scripts' **errors**: the
  Output tab's error lines with a location (the last build's) and the script index's problems
  (script_index.odin).
- **When:** on demand (the tab's Refresh), after a project save, after a scripts build, and when
  the tab is shown. The list is kept until the next gathering (`ProblemsState.items`, owned).
- **Going to one** (`Problems_Go`, a row's click): a node's problem opens its scene (a component in
  its tab) and selects the node, its parents expanded; a file's opens it at its line in the code
  editor; an asset's selects it in the browser when the project has it.
- Keys: the list `problems-list`, its rows `problem-<i>`, Refresh `problems-refresh`; driver check
  `problems <n>` / `problem <i> <text>` (contains), `send Problems_Refresh`. Tests:
  `problems_test.odin`; tests/ui/feedback.script.
*/

ProblemKind :: enum {
	Missing_Asset,
	Broken_Node_Path,
	// A script or node type the scripts build doesn't have
	Unresolved_Reference,
	Script_Error,
	Script_Warning,
}

// One problem (strings owned)
Problem :: struct {
	kind: ProblemKind,
	// What's wrong ("Missing image images/ship.png")
	text: string,
	// Where: "PlayScene > World > Ship", or the file and line
	place: string,
	// A node's problem: its scene and node (-1 none)
	scene, node: int,
	// A file's problem: the file (absolute; "" none), 1-based line, 0-based column
	file: string,
	line, column: int,
	// A missing asset's path as the node holds it ("" none)
	asset: string,
}

// The Problems tab's list (part of State)
ProblemsState :: struct {
	items: [dynamic]Problem,
	// Gathered at least once since the project opened
	gathered: bool,
	// The row last clicked (-1 none)
	selected: int,
}

// Gather the problems again (the tab's Refresh)
Problems_Refresh :: struct {}
// A row clicked: go to its cause
Problem_Picked :: distinct int

// Whether a problem is an error (else a warning: the row's color)
Problem_IsError :: proc(p: Problem) -> bool {
	return p.kind == .Script_Error || p.kind == .Missing_Asset
}

/*
Gathers the project's problems again, replacing the list.

Inputs:
- state: The editor state
*/
Problems_Gather :: proc(state: ^State) {
	list := &state.problems
	Problems_Clear(list)
	list.gathered = true
	list.selected = -1
	root := state.project.rootPath
	catalogReady := state.scripts.status == .Ready
	for &scene, si in state.project.scenes {
		sceneName := scene.component != "" ? filepath.base(scene.component) : scene.name
		for &node, ni in scene.nodes {
			place := problemPlace(&scene, sceneName, ni)
			missing :: proc(list: ^ProblemsState, root, what, path, place: string, scene, node: int) {
				if path == "" || strings.has_prefix(path, "builtin:") do return
				full := filepath.is_abs(path) ? path : joinPath(root, path, allocator = context.temp_allocator)
				if os.is_file(full) || os.is_dir(full) do return
				append(&list.items, Problem{kind = .Missing_Asset, text = fmt.aprintf("Missing %s %s", what, path),
					place = strings.clone(place), scene = scene, node = node, asset = strings.clone(path), line = 0})
			}
			missing(list, root, "image", node.texture, place, si, ni)
			if node.animationSet == "" {
				seen := make(map[string]bool, allocator = context.temp_allocator)
				for a in node.animations {
					sheet := strings.trim_suffix(a.sheet, e.ASEPRITE_SHEET_SUFFIX)
					if sheet == "" || seen[sheet] do continue
					seen[sheet] = true
					missing(list, root, "sprite sheet", sheet, place, si, ni)
				}
			}
			missing(list, root, "animation asset", node.animationSet, place, si, ni)
			missing(list, root, "component", node.component, place, si, ni)
			missing(list, root, "sound", node.sound, place, si, ni)
			missing(list, root, "physics material", node.material, place, si, ni)
			missing(list, root, "shader", node.shader, place, si, ni)
			missing(list, root, "dialogue", node.dialogue, place, si, ni)
			if node.kind == .LDtkLevel do missing(list, root, "LDtk project", node.ldtk.file, place, si, ni)
			if catalogReady {
				unresolved :: proc(list: ^ProblemsState, what, name, place: string, scene, node: int) {
					append(&list.items, Problem{kind = .Unresolved_Reference, text = fmt.aprintf("No %s named %s (the scripts build has none)", what, name),
						place = strings.clone(place), scene = scene, node = node})
				}
				if node.script != "" && ScriptCatalog_Find(&state.scripts, node.script) == nil do unresolved(list, "script", node.script, place, si, ni)
				for more in node.moreScripts do if more.name != "" && ScriptCatalog_Find(&state.scripts, more.name) == nil do unresolved(list, "script", more.name, place, si, ni)
				if node.customKind != "" && ScriptCatalog_FindNodeType(&state.scripts, node.customKind) == nil do unresolved(list, "node type", node.customKind, place, si, ni)
			}
		}
		for ref in NodePaths_Broken(&scene, catalogReady ? &state.scripts : nil) {
			what := strings.to_lower(strings.join(strings.split(fmt.tprintf("%v", ref.kind), "_", context.temp_allocator), " ", context.temp_allocator), context.temp_allocator)
			if ref.kind == .Script_Field do what = fmt.tprintf("field %s", ref.field)
			append(&list.items, Problem{kind = .Broken_Node_Path, text = fmt.aprintf("The %s path %q leads to no node", what, ref.path),
				place = strings.clone(problemPlace(&scene, sceneName, ref.owner)), scene = si, node = ref.owner})
		}
	}
	// The last build's errors (the Output tab), then the script index's problems
	for line in LogList_Lines(&state.output) {
		if line.level != .Error do continue
		location, ok := ErrorLocation_Parse(line.text)
		if !ok do continue
		file := ErrorLocation_Resolve(state, location, true)
		_, _, message := strings.partition(line.text, ") ")
		if message == "" do message = line.text
		append(&list.items, Problem{kind = .Script_Error, text = strings.clone(strings.trim_space(message)),
			place = fmt.aprintf("%s:%d", filepath.base(location.path), location.line), scene = -1, node = -1,
			file = strings.clone(file), line = location.line, column = max(location.column - 1, 0)})
	}
	for p in state.scriptIndex.problems {
		append(&list.items, Problem{kind = p.warning ? .Script_Warning : .Script_Error, text = strings.clone(p.message),
			place = fmt.aprintf("%s:%d", filepath.base(p.path), p.line), scene = -1, node = -1,
			file = strings.clone(p.path), line = p.line, column = p.column})
	}
}

// "PlayScene > World > Ship" (temp allocated)
@(private="file")
problemPlace :: proc(scene: ^SceneDef, sceneName: string, node: int) -> string {
	if node < 0 || node >= len(scene.nodes) do return sceneName
	names := make([dynamic]string, context.temp_allocator)
	for n := node; n >= 0 && n < len(scene.nodes); n = scene.nodes[n].parent do inject_at(&names, 0, scene.nodes[n].name)
	return fmt.tprintf("%s > %s", sceneName, strings.join(names[:], " > ", context.temp_allocator))
}

// Empties the list
Problems_Clear :: proc(list: ^ProblemsState) {
	for &p in list.items {
		delete(p.text)
		delete(p.place)
		delete(p.file)
		delete(p.asset)
	}
	clear(&list.items)
}

// Frees the list
Problems_Destroy :: proc(list: ^ProblemsState) {
	Problems_Clear(list)
	delete(list.items)
	list.items = nil
}

/*
Goes to a problem's cause: selects its node (its scene open, its parents expanded), opens its file
at its line, or selects its asset in the browser.

Inputs:
- state: The editor state
- index: The problem's place in the list

Returns:
- The command opening a file gives
*/
Problems_Go :: proc(state: ^State, index: int) -> skald.Command(Msg) {
	if index < 0 || index >= len(state.problems.items) do return {}
	state.problems.selected = index
	p := state.problems.items[index]
	if p.file != "" do return Script_Open(state, p.file, max(p.line, 1), p.column, readOnly = !Path_InProject(state, p.file))
	if p.scene >= 0 && p.scene < len(state.project.scenes) {
		Mode_Set(state, .Scene)
		state.codeTab, state.slicer.shown = 0, 0
		scene := &state.project.scenes[p.scene]
		if scene.component != "" do scene.opened = true
		scene.tabClosed = false
		openScene(state, p.scene)
		if p.node >= 0 && p.node < len(scene.nodes) {
			for parent := scene.nodes[p.node].parent; parent >= 0 && parent < len(scene.nodes); parent = scene.nodes[parent].parent do scene.nodes[parent].expanded = true
			clear(&state.selection)
			state.selectedNode = p.node
		}
	}
	if p.asset != "" do Browser_RevealFile(state, p.asset)
	return {}
}

/*
The Problems tab's messages.

Returns:
- The command, and whether the message was one of these
*/
Problems_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Problems_Refresh:
		Problems_Gather(state)
		return {}, true
	case Problem_Picked:
		return Problems_Go(state, int(v)), true
	}
	return {}, false
}

/*
The Problems tab: a header (the count, Refresh), then a row per problem (its level's icon, what's
wrong, where), or an empty state.
*/
ProblemsPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	tk := uiTokens(ctx)
	list := &s.problems
	errors := 0
	for p in list.items do if Problem_IsError(p) do errors += 1
	count := list.gathered ? fmt.tprintf("%d error%s, %d warning%s", errors, errors == 1 ? "" : "s",
		len(list.items) - errors, len(list.items) - errors == 1 ? "" : "s") : "Not checked yet"
	header := skald.row(
		uiText(th, .Muted, count),
		skald.flex(1, skald.spacer(0)),
		panelToolButton(ctx, "problems-refresh", ACTION_ICONS[.Refresh], "Check the project again", Msg(Problems_Refresh{}), label = "Refresh"),
		spacing = tk.buttonGap,
		padding = tk.panelPadding,
		cross_align = .Center,
	)
	if len(list.items) == 0 {
		text := list.gathered ? "No problems found: every asset, node path and script the scenes use is there." : "The project hasn't been checked yet."
		return skald.col(header, emptyState(ctx, text, {label = "Check Now", msg = Msg(Problems_Refresh{}), key = "problems-check"}), cross_align = .Stretch)
	}
	rows := make([]ListRow, len(list.items), context.temp_allocator)
	for p, i in list.items {
		isError := Problem_IsError(p)
		rows[i] = {
			row = {label = fmt.tprintf("%s  (%s)", p.text, p.place), icon = ACTION_ICONS[.Warning],
				iconColor = isError ? th.color.danger : th.color.warning, selected = i == list.selected},
			key = fmt.tprintf("problem-%d", i),
			pick = Msg(Problem_Picked(i)),
		}
	}
	listView, _ := rowList(ctx, "problems-list", rows, tk.rowHeight)
	return skald.col(
		header,
		skald.flex(1, skald.scroll(ctx, {0, 0}, listView, id = skald.hash_id("problems-scroll"), reveal_focus = false)),
		cross_align = .Stretch,
	)
}
