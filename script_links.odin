package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import "gui:skald"
import e "engine:."

/*
Code and scene links: what the project does with the scripts' types, fields and events, shown
in the code and reached from it, and renames that carry into the project (round 3 of TODO.md's
"Code editor integration"; the providers are registered in code_providers.odin).

- **Gutter markers** on each `Script_Register` / `NodeType_Register` / `Data_Register` line list
  everything using the type: nodes of scenes and components (as a script, one of their more
  scripts, or their node type), instances of components whose root runs it, globals, data
  resources. On an exported field's line, a marker when nodes override its value ("speed: 3
  nodes override it", each with its value); on an event's, when something listens. A click opens
  the one there is, or a menu of them (code_editor's marker menu); choosing one opens its scene
  or component tab and selects the node (a global: Project Settings > Globals; a data resource:
  selected in the browser). The lines also get an inlay hint with the count.
- **Find Usages** (Alt+Shift+F12, the code editor's context menu and palette) on a registered
  type's name, an exported field or an event, wherever the code names it (its declaration, `x.speed`
  through a receiver of known type, `Hero{speed = ...}`): the uses in the code editor's
  references panel, each opening the node. A field's lists every node running the script with
  its value (overrides first) and the Timeline tracks animating it; an event's, the listeners.
- **Rename** (F2, the code editor's rename box) of the same symbols renames in code and project:
  the code from the scripts' text (script_rename.odin says how, and why not through OLS), the
  shown file's edits as one undo step of its tab, other files' as one undo step of theirs (opened
  in tabs, left unsaved, like any edit); the project in one undo step (`Code_Rename_Requested`,
  a `.Project` edit): scripts attached to nodes and their more scripts, node types (`customKind`),
  globals, data resources' types, stored values (`<prop name>` of nodes, node types, globals,
  data), listeners (a script's events, globals'), Timeline `script.x` tracks, LDtk entity rules
  (and a rule keeping an entity named like a renamed script running it).
*/

// Where a use of a script is
UsageTargetKind :: enum {
	Node,
	Global,
	Data,
}

// What a usage opens: a node of a scene or component, a global, a data resource
UsageTarget :: struct {
	kind: UsageTargetKind,
	scene, node: int,
	// A global's or data resource's index
	index: int,
}

// One use of a type, field or event in the project (strings temp allocated)
ProjectUsage :: struct {
	target: UsageTarget,
	// "PlayScene: Spaceship", "hero (component): Hero", "Globals: GameState"
	label: string,
	// What it does with it: "runs Mover", "speed = 250", "speed = 175 (default)"
	preview: string,
	// It sets a field's value (an override) or listens to the event
	sets: bool,
}

// A usage chosen in the code (a marker, its menu, Find Usages): open it, or say why there's none
Code_Usage_Opened :: struct {
	target: UsageTarget,
	// "Nothing uses Hero yet" instead (for the frame)
	notice: string,
}

// A rename the code editor made (Rename Symbol): the project's side and other files' edits
Code_Rename_Requested :: struct {
	// What and to what (owned by the providers until the frame ends: cloned on use)
	symbol: ScriptSymbol,
	newName: string,
	// Other files' edits (the shown file's are done)
	edits: []CodeEdit,
}

// --- what the project does with a type ----------------------------------------------------

// The stored values a node holds for a type: its first or more scripts' (`.Script`), its node
// type's (`.NodeType`)
@(private)
nodeValuesFor :: proc(node: ^NodeDef, name: string, kind: IndexRegistrationKind) -> (^[dynamic]ScriptPropDef, bool) {
	#partial switch kind {
	case .Script:
		if node.script == name do return &node.props, true
		for &extra in node.moreScripts do if extra.name == name do return &extra.props, true
	case .NodeType:
		if node.customKind == name do return &node.customProps, true
	}
	return nil, false
}

// How a node runs a type ("runs Hero", "its 2nd script", "a Player node"), "" when it doesn't
@(private)
nodeRunsHow :: proc(project: ^Project, node: ^NodeDef, name: string, kind: IndexRegistrationKind) -> string {
	#partial switch kind {
	case .Script:
		if node.script == name do return fmt.tprintf("runs %s", name)
		for extra, i in node.moreScripts do if extra.name == name do return fmt.tprintf("runs %s (its script %d)", name, i + 2)
		if node.kind == .Component {
			if c := Project_FindComponent(project, node.component); c >= 0 && len(project.scenes[c].nodes) > 0 {
				root := &project.scenes[c].nodes[0]
				if root.script == name do return fmt.tprintf("an instance of %s (runs %s)", ComponentName(node.component), name)
				for extra in root.moreScripts do if extra.name == name do return fmt.tprintf("an instance of %s (runs %s)", ComponentName(node.component), name)
			}
		}
	case .NodeType:
		if node.customKind == name do return fmt.tprintf("a %s node", name)
		if node.kind == .Component {
			if c := Project_FindComponent(project, node.component); c >= 0 && len(project.scenes[c].nodes) > 0 && project.scenes[c].nodes[0].customKind == name {
				return fmt.tprintf("an instance of %s (a %s)", ComponentName(node.component), name)
			}
		}
	}
	return ""
}

// "PlayScene", "hero (component)"
@(private)
sceneLabel :: proc(scene: ^SceneDef) -> string {
	return Scene_IsComponent(scene) ? fmt.tprintf("%s (component)", ComponentName(scene.component)) : scene.name
}

// The type's description (the catalog's: built, or from the source)
@(private)
descOf :: proc(state: ^State, name: string, kind: IndexRegistrationKind) -> ^ScriptDesc {
	switch kind {
	case .Script: return ScriptCatalog_Find(&state.scripts, name)
	case .NodeType: return ScriptCatalog_FindNodeType(&state.scripts, name)
	case .Data: for &d in state.scripts.dataTypes do if d.name == name do return &d
	}
	return nil
}

// Every use of a registered type: nodes (and component instances), globals, data resources
ScriptLinks_TypeUsages :: proc(state: ^State, name: string, kind: IndexRegistrationKind) -> []ProjectUsage {
	out := make([dynamic]ProjectUsage, context.temp_allocator)
	p := &state.project
	if kind != .Data {
		for &scene, si in p.scenes do for &node, ni in scene.nodes {
			how := nodeRunsHow(p, &node, name, kind)
			if how == "" do continue
			append(&out, ProjectUsage{target = {kind = .Node, scene = si, node = ni}, label = fmt.tprintf("%s: %s", sceneLabel(&scene), node.name), preview = how, sets = true})
		}
	}
	if kind == .Script {
		for g, i in p.globals do if g.script == name {
			append(&out, ProjectUsage{target = {kind = .Global, index = i}, label = fmt.tprintf("Globals: %s", name), preview = "runs as a global (Project Settings > Globals)", sets = true})
		}
	}
	if kind == .Data {
		for d, i in p.data do if d.type == name {
			append(&out, ProjectUsage{target = {kind = .Data, index = i}, label = fmt.tprintf("Data: %s", filepath.base(d.path)), preview = fmt.tprintf("a %s data resource", name), sets = true})
		}
	}
	return out[:]
}

/*
Every use of a type's exported field: each node running it with its value (those that set it
first), each global and data resource of it, and the Timeline tracks animating it.
*/
ScriptLinks_FieldUsages :: proc(state: ^State, owner: string, kind: IndexRegistrationKind, field: string) -> []ProjectUsage {
	sets := make([dynamic]ProjectUsage, context.temp_allocator)
	defaults := make([dynamic]ProjectUsage, context.temp_allocator)
	p := &state.project
	defaultValue := ""
	if desc := descOf(state, owner, kind); desc != nil {
		for f in desc.fields do if f.name == field do defaultValue = f.defaultValue
	}
	valueOf :: proc(props: []ScriptPropDef, field: string) -> (string, bool) {
		for prop in props do if prop.name == field do return prop.value, true
		return "", false
	}
	add :: proc(sets, defaults: ^[dynamic]ProjectUsage, target: UsageTarget, label, field, defaultValue: string, props: []ScriptPropDef) {
		if value, set := valueOf(props, field); set {
			append(sets, ProjectUsage{target = target, label = label, preview = fmt.tprintf("%s = %s", field, value), sets = true})
		} else {
			append(defaults, ProjectUsage{target = target, label = label, preview = fmt.tprintf("%s = %s (default)", field, defaultValue)})
		}
	}
	tracks := make([dynamic]ProjectUsage, context.temp_allocator)
	for &scene, si in p.scenes do for &node, ni in scene.nodes {
		label := fmt.tprintf("%s: %s", sceneLabel(&scene), node.name)
		if props, ok := nodeValuesFor(&node, owner, kind); ok {
			add(&sets, &defaults, {kind = .Node, scene = si, node = ni}, label, field, defaultValue, props[:])
		} else if how := nodeRunsHow(p, &node, owner, kind); how != "" {
			// An instance: the component's root holds the values
			append(&defaults, ProjectUsage{target = {kind = .Node, scene = si, node = ni}, label = label, preview = fmt.tprintf("%s: %s", how, field)})
		}
		if node.kind == .Animator do for clip in node.animator.clips do for track in clip.tracks {
			if track.property != fmt.tprintf("%s%s", e.ANIMATOR_SCRIPT_PREFIX, field) do continue
			target := Timeline_ResolvePath(&scene, ni, track.node)
			if target < 0 || nodeRunsHow(p, &scene.nodes[target], owner, kind) == "" do continue
			append(&tracks, ProjectUsage{target = {kind = .Node, scene = si, node = ni}, label = label,
				preview = fmt.tprintf("Timeline clip %s animates %s's %s", clip.name, scene.nodes[target].name, field), sets = true})
		}
	}
	if kind == .Script {
		for &g, i in p.globals do if g.script == owner {
			add(&sets, &defaults, {kind = .Global, index = i}, fmt.tprintf("Globals: %s", owner), field, defaultValue, g.props[:])
		}
	}
	if kind == .Data {
		for &d, i in p.data do if d.type == owner {
			add(&sets, &defaults, {kind = .Data, index = i}, fmt.tprintf("Data: %s", filepath.base(d.path)), field, defaultValue, d.values[:])
		}
	}
	append(&sets, ..tracks[:])
	append(&sets, ..defaults[:])
	return sets[:]
}

// Every listener of a script's event: on nodes running it, and on nodes listening to a global's
ScriptLinks_EventUsages :: proc(state: ^State, owner: string, kind: IndexRegistrationKind, field: string) -> []ProjectUsage {
	out := make([dynamic]ProjectUsage, context.temp_allocator)
	p := &state.project
	event := fmt.tprintf("%s%s", e.SCRIPT_EVENT_PREFIX, field)
	for &scene, si in p.scenes do for &node, ni in scene.nodes {
		runs := nodeRunsHow(p, &node, owner, kind) != ""
		for l in node.listeners {
			if l.event != event do continue
			if l.global != "" ? l.global != owner : !runs do continue
			who := l.global != "" ? fmt.tprintf("listens to the global %s's %s", owner, field) : fmt.tprintf("%s: %s listens (%s)", field, l.target == "" || l.target == "." ? "its script" : l.target, l.handler)
			append(&out, ProjectUsage{target = {kind = .Node, scene = si, node = ni}, label = fmt.tprintf("%s: %s", sceneLabel(&scene), node.name), preview = who, sets = true})
		}
	}
	return out[:]
}

// A symbol's usages (ScriptLinks_TypeUsages, _FieldUsages or _EventUsages)
ScriptLinks_Usages :: proc(state: ^State, symbol: ScriptSymbol) -> []ProjectUsage {
	switch symbol.kind {
	case .None: return nil
	case .Type: return ScriptLinks_TypeUsages(state, symbol.owner, symbol.ownerKind)
	case .Field: return ScriptLinks_FieldUsages(state, symbol.owner, symbol.ownerKind, symbol.field)
	case .Event: return ScriptLinks_EventUsages(state, symbol.owner, symbol.ownerKind, symbol.field)
	}
	return nil
}

// --- renames in the project -----------------------------------------------------------------

// What a rename changed (or would) in the project
ProjectRenameCounts :: struct {
	// Nodes, globals and data resources changed, the scenes and components they're in
	nodes, globals, data, scenes: int,
	// Stored values renamed, listeners, Timeline tracks, LDtk rules
	values, listeners, tracks, rules: int,
	// Things it can't change (LDtk entity fields by name; temp allocated)
	notes: [dynamic]string,
}

// The count as a phrase ("3 nodes in 2 scenes, 4 values, 1 listener"; "" for nothing)
ProjectRenameCounts_Text :: proc(c: ProjectRenameCounts) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	plural :: proc(n: int, one, many: string) -> string { return fmt.tprintf("%d %s", n, n == 1 ? one : many) }
	if c.nodes > 0 do append(&parts, fmt.tprintf("%s in %s", plural(c.nodes, "node", "nodes"), plural(c.scenes, "scene", "scenes")))
	if c.globals > 0 do append(&parts, plural(c.globals, "global", "globals"))
	if c.data > 0 do append(&parts, plural(c.data, "data resource", "data resources"))
	if c.values > 0 do append(&parts, plural(c.values, "stored value", "stored values"))
	if c.listeners > 0 do append(&parts, plural(c.listeners, "listener", "listeners"))
	if c.tracks > 0 do append(&parts, plural(c.tracks, "Timeline track", "Timeline tracks"))
	if c.rules > 0 do append(&parts, plural(c.rules, "LDtk rule", "LDtk rules"))
	return strings.join(parts[:], ", ", context.temp_allocator)
}

/*
Renames a type, an exported field or an event in the project: everything that names it (see the
file's doc). With `dryRun` nothing changes and the counts say what would.

Inputs:
- state: The editor state (its project changes; LDtk files are read for entity types)
- symbol: What's renamed (its current name in it)
- newName: The new name

Returns:
- What changed
*/
ScriptRename_Project :: proc(state: ^State, symbol: ScriptSymbol, newName: string, dryRun := false) -> ProjectRenameCounts {
	counts := ProjectRenameCounts{notes = make([dynamic]string, context.temp_allocator)}
	p := &state.project
	set :: proc(text: ^string, value: string, dryRun: bool) {
		if dryRun do return
		delete(text^)
		text^ = strings.clone(value)
	}
	renameProp :: proc(props: ^[dynamic]ScriptPropDef, from, to: string, dryRun: bool) -> bool {
		at := -1
		for prop, i in props do if prop.name == from do at = i
		if at < 0 do return false
		if dryRun do return true
		// A value already stored under the new name (left from an older field) gives way
		for prop, i in props do if prop.name == to {
			delete(prop.name)
			delete(prop.value)
			ordered_remove(props, i)
			if i < at do at -= 1
			break
		}
		delete(props[at].name)
		props[at].name = strings.clone(to)
		return true
	}
	old := ScriptSymbol_Name(symbol)
	oldEvent := fmt.tprintf("%s%s", e.SCRIPT_EVENT_PREFIX, symbol.field)
	newEvent := fmt.tprintf("%s%s", e.SCRIPT_EVENT_PREFIX, newName)
	oldTrack := fmt.tprintf("%s%s", e.ANIMATOR_SCRIPT_PREFIX, symbol.field)
	newTrack := fmt.tprintf("%s%s", e.ANIMATOR_SCRIPT_PREFIX, newName)
	ldtkNoted := false
	for &scene in p.scenes {
		touched := false
		for &node, ni in scene.nodes {
			changed := false
			// What the node runs, before anything here renames it
			runs := symbol.kind != .Type && nodeRunsHow(p, &node, symbol.owner, symbol.ownerKind) != ""
			switch symbol.kind {
			case .None:
			case .Type:
				#partial switch symbol.ownerKind {
				case .Script:
					if node.script == old { set(&node.script, newName, dryRun); changed = true }
					for &extra in node.moreScripts do if extra.name == old { set(&extra.name, newName, dryRun); changed = true }
					for &l in node.listeners do if l.global == old {
						set(&l.global, newName, dryRun)
						counts.listeners += 1
						changed = true
					}
					// LDtk: rules naming it, and entities named like it (Auto: the script of their name)
					if node.kind == .LDtkLevel {
						for &rule in node.ldtk.entityComponents do if rule.script == old {
							set(&rule.script, newName, dryRun)
							counts.rules += 1
							changed = true
						}
						if project := LDtkEdit_Project(p.rootPath, node.ldtk.file); project != nil {
							for def in project.entities {
								if def.identifier != old do continue
								rule := e.LDtk_EntityRule(&node.ldtk, def.identifier)
								if rule.script != "" || rule.noScript do continue
								if !dryRun {
									found := false
									for &m in node.ldtk.entityComponents do if m.entity == old {
										set(&m.script, newName, false)
										found = true
									}
									if !found do append(&node.ldtk.entityComponents, e.LDtkEntityComponent{entity = strings.clone(old), component = strings.clone(""), script = strings.clone(newName)})
								}
								counts.rules += 1
								changed = true
							}
						}
					}
				case .NodeType:
					if node.customKind == old { set(&node.customKind, newName, dryRun); changed = true }
				}
			case .Field:
				if props, ok := nodeValuesFor(&node, symbol.owner, symbol.ownerKind); ok && renameProp(props, symbol.field, newName, dryRun) {
					counts.values += 1
					changed = true
				}
			case .Event:
				for &l in node.listeners {
					if l.event != oldEvent do continue
					if l.global != "" ? l.global != symbol.owner : !runs do continue
					set(&l.event, newEvent, dryRun)
					counts.listeners += 1
					changed = true
				}
			}
			// Timeline tracks animating the field on a node running the type
			if symbol.kind == .Field && node.kind == .Animator {
				for &clip in node.animator.clips do for &track in clip.tracks {
					if track.property != oldTrack do continue
					target := Timeline_ResolvePath(&scene, ni, track.node)
					if target < 0 || nodeRunsHow(p, &scene.nodes[target], symbol.owner, symbol.ownerKind) == "" do continue
					set(&track.property, newTrack, dryRun)
					counts.tracks += 1
					changed = true
				}
			}
			// LDtk entities set script fields by their own fields' names: those can't be renamed here
			if symbol.kind == .Field && node.kind == .LDtkLevel && !ldtkNoted {
				if project := LDtkEdit_Project(p.rootPath, node.ldtk.file); project != nil {
					for def in project.entities {
						rule := e.LDtk_EntityRule(&node.ldtk, def.identifier)
						if rule.script == symbol.owner || (rule.script == "" && !rule.noScript && def.identifier == symbol.owner) {
							append(&counts.notes, fmt.tprintf("LDtk entities (%s) set fields by name: rename %s in LDtk too if they set it", def.identifier, symbol.field))
							ldtkNoted = true
							break
						}
					}
				}
			}
			if changed {
				counts.nodes += 1
				touched = true
			}
		}
		if touched do counts.scenes += 1
	}
	for &g in p.globals {
		switch symbol.kind {
		case .None, .Event:
		case .Type:
			if symbol.ownerKind == .Script && g.script == old {
				set(&g.script, newName, dryRun)
				counts.globals += 1
			}
		case .Field:
			if symbol.ownerKind == .Script && g.script == symbol.owner && renameProp(&g.props, symbol.field, newName, dryRun) {
				counts.globals += 1
				counts.values += 1
			}
		}
	}
	for &d in p.data {
		if symbol.ownerKind != .Data do break
		switch symbol.kind {
		case .None, .Event:
		case .Type:
			if d.type == old {
				set(&d.type, newName, dryRun)
				counts.data += 1
			}
		case .Field:
			if d.type == symbol.owner && renameProp(&d.values, symbol.field, newName, dryRun) {
				counts.data += 1
				counts.values += 1
			}
		}
	}
	return counts
}

// --- the scripts' text ------------------------------------------------------------------------

// The scripts package's files (absolute paths), their text from a code tab when open (temp allocated)
@(private)
scriptSources :: proc(state: ^State) -> []CodeSource {
	out := make([dynamic]CodeSource, context.temp_allocator)
	folder := absolutePath(joinPath(state.project.rootPath, SCRIPTS_FOLDER, allocator = context.temp_allocator))
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil do return nil
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") do continue
		path := absolutePath(joinPath(folder, entry.name, allocator = context.temp_allocator))
		text, version, _ := CodeEditor_Buffer(path, true)
		if version < 0 {
			data, readErr := os.read_entire_file(path, context.temp_allocator)
			if readErr != nil do continue
			text = string(data)
		}
		append(&out, CodeSource{path = path, text = text})
	}
	return out[:]
}

// What a registered type is called in messages ("script Hero", "node type Player")
@(private)
ownerKindName :: proc(kind: IndexRegistrationKind) -> string {
	switch kind {
	case .Script: return "script"
	case .NodeType: return "node type"
	case .Data: return "data type"
	}
	return "type"
}

// "script Hero", "Hero's field speed", "Hero's event onHit"
@(private)
symbolTitle :: proc(symbol: ScriptSymbol) -> string {
	switch symbol.kind {
	case .None: return ""
	case .Type: return fmt.tprintf("%s %s", ownerKindName(symbol.ownerKind), symbol.owner)
	case .Field: return fmt.tprintf("%s's field %s", symbol.owner, symbol.field)
	case .Event: return fmt.tprintf("%s's event %s", symbol.owner, symbol.field)
	}
	return ""
}

/*
Applies a rename's project side and other files' edits (`Code_Rename_Requested`): the project in
place (one `.Project` undo step: History_Classify), each other script file's edits in its code
tab (opened, not shown: one undo step there, left unsaved), or written to the file when it can't
be opened in a tab.

Returns:
- A sentence for the Console (temp allocated)
*/
ScriptRename_Apply :: proc(state: ^State, v: Code_Rename_Requested) -> string {
	counts := ScriptRename_Project(state, v.symbol, v.newName)
	// Other files: grouped by path, in a tab each
	files := 0
	paths := make([dynamic]string, context.temp_allocator)
	for edit in v.edits do if !slice.contains(paths[:], edit.path) do append(&paths, edit.path)
	for path in paths {
		edits := make([dynamic]ce.Text_Edit, context.temp_allocator)
		for edit in v.edits do if edit.path == path do append(&edits, ce.Text_Edit{start = {edit.line, edit.column}, end = {edit.line, edit.endColumn}, text = edit.text})
		if state.settings.builtInCodeEditor {
			CodeTabs_Open(state, path, 0, show = false)
		}
		if CodeEditor_ApplyEdits(path, edits[:]) {
			files += 1
			continue
		}
		// Not in a tab (the external editor): the file itself
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil do continue
		text := applyCodeEdits(string(data), v.edits, path)
		if writeErr := os.write_entire_file(path, transmute([]u8)text); writeErr == nil do files += 1
	}
	project := ProjectRenameCounts_Text(counts)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "Renamed %s to %s", symbolTitle(v.symbol), v.newName)
	if files > 0 do fmt.sbprintf(&b, "; %d other file%s changed (unsaved, Ctrl+Z in each undoes it)", files, files == 1 ? "" : "s")
	if project != "" do fmt.sbprintf(&b, "; in the project: %s (one undo step)", project)
	for note in counts.notes do fmt.sbprintf(&b, ". %s", note)
	return strings.to_string(b)
}

// A file's text with a rename's edits to it applied (temp allocated)
@(private)
applyCodeEdits :: proc(text: string, edits: []CodeEdit, path: string) -> string {
	lines := strings.split(text, "\n", context.temp_allocator)
	mine := make([dynamic]CodeEdit, context.temp_allocator)
	for edit in edits do if edit.path == path do append(&mine, edit)
	// Last first, so earlier columns stay right
	slice.sort_by(mine[:], proc(a, b: CodeEdit) -> bool { return a.line != b.line ? a.line > b.line : a.column > b.column })
	for edit in mine {
		if edit.line < 0 || edit.line >= len(lines) do continue
		line := lines[edit.line]
		if edit.endColumn > len(line) || edit.column > edit.endColumn do continue
		lines[edit.line] = strings.concatenate({line[:edit.column], edit.text, line[edit.endColumn:]}, context.temp_allocator)
	}
	return strings.join(lines, "\n", context.temp_allocator)
}

// --- the providers -------------------------------------------------------------------------

// A registration or exported field on a line of a document, and what uses it
@(private="file")
MarkedLine :: struct {
	line: int,
	symbol: ScriptSymbol,
	usages: []ProjectUsage,
}

/*
The lines of a document that get a marker: each registration (its type's usages), and each
exported field or event of a registered type declared there that nodes set or listen to.
*/
@(private="file")
markedLines :: proc(state: ^State, doc: ce.Provider_Document) -> []MarkedLine {
	out := make([dynamic]MarkedLine, context.temp_allocator)
	f := ScriptIndex_File(&state.scriptIndex, absolutePath(doc.path))
	if f == nil do return nil
	for r in f.registrations {
		at := relocate(doc, r.line - 1, r.lineText)
		if at < 0 do continue
		symbol := ScriptSymbol{kind = .Type, owner = r.name, ownerKind = r.kind}
		append(&out, MarkedLine{at, symbol, ScriptLinks_TypeUsages(state, r.name, r.kind)})
	}
	// Fields: the struct of a registered type declared in this file
	for &st in f.structs {
		kind, registered := registeredKind(&state.scriptIndex, &state.scripts, st.name)
		if !registered do continue
		desc := descOf(state, st.name, kind)
		if desc == nil do continue
		for field in st.fields {
			symbol := ScriptSymbol{owner = st.name, ownerKind = kind, field = field.name}
			for df in desc.fields do if df.name == field.name do symbol.kind = .Field
			for ev in desc.events do if Event_ShortName(ev.name) == field.name do symbol.kind = .Event
			if symbol.kind == .None do continue
			usages := ScriptLinks_Usages(state, symbol)
			set := make([dynamic]ProjectUsage, context.temp_allocator)
			for u in usages do if u.sets do append(&set, u)
			if len(set) == 0 do continue
			at := relocate(doc, field.line - 1, field.lineText)
			if at < 0 do continue
			append(&out, MarkedLine{at, symbol, set[:]})
		}
	}
	return out[:]
}

// The marker's tooltip and inlay text for a marked line (temp allocated)
@(private="file")
markedText :: proc(m: MarkedLine) -> (short, long: string) {
	b := strings.builder_make(context.temp_allocator)
	n := len(m.usages)
	switch m.symbol.kind {
	case .None:
	case .Type:
		nodes, globals, data := 0, 0, 0
		for u in m.usages {
			switch u.target.kind {
			case .Node: nodes += 1
			case .Global: globals += 1
			case .Data: data += 1
			}
		}
		parts := make([dynamic]string, context.temp_allocator)
		if nodes > 0 do append(&parts, fmt.tprintf("%d node%s", nodes, nodes == 1 ? "" : "s"))
		if globals > 0 do append(&parts, "a global")
		if data > 0 do append(&parts, fmt.tprintf("%d data resource%s", data, data == 1 ? "" : "s"))
		short = len(parts) == 0 ? (m.symbol.ownerKind == .Data ? "no data resource uses it" : "no node uses it") : strings.join(parts[:], ", ", context.temp_allocator)
		fmt.sbprintf(&b, "%s: %s", m.symbol.owner, short)
	case .Field:
		nodes, globals, data, tracks := 0, 0, 0, 0
		for u in m.usages {
			switch {
			case strings.has_prefix(u.preview, "Timeline"): tracks += 1
			case u.target.kind == .Global: globals += 1
			case u.target.kind == .Data: data += 1
			case: nodes += 1
			}
		}
		parts := make([dynamic]string, context.temp_allocator)
		if nodes > 0 do append(&parts, fmt.tprintf("%d node%s override%s it", nodes, nodes == 1 ? "" : "s", nodes == 1 ? "s" : ""))
		if globals > 0 do append(&parts, "a global sets it")
		if data > 0 do append(&parts, fmt.tprintf("%d data resource%s set%s it", data, data == 1 ? "" : "s", data == 1 ? "s" : ""))
		if tracks > 0 do append(&parts, fmt.tprintf("%d Timeline track%s", tracks, tracks == 1 ? "" : "s"))
		short = strings.join(parts[:], ", ", context.temp_allocator)
		fmt.sbprintf(&b, "%s: %s", m.symbol.field, short)
	case .Event:
		short = fmt.tprintf("%d listener%s", n, n == 1 ? "" : "s")
		fmt.sbprintf(&b, "%s: %s", m.symbol.field, short)
	}
	limit := 8
	for u, i in m.usages {
		if i == limit {
			fmt.sbprintf(&b, "\n...and %d more", n - limit)
			break
		}
		fmt.sbprintf(&b, "\n- %s: %s", u.label, u.preview)
	}
	if n == 1 do strings.write_string(&b, "\nClick the marker to open it.")
	else if n > 1 do strings.write_string(&b, "\nClick the marker to choose one.")
	return short, strings.to_string(b)
}

// "PlayScene: Spaceship (speed = 250)": a usage in a marker's menu
@(private="file")
choiceLabel :: proc(u: ProjectUsage) -> string {
	return fmt.tprintf("%s (%s)", u.label, u.preview)
}

@(private)
linkMarkers :: proc(doc: ce.Provider_Document, ctx: ce.Provider_Context, out: ^[dynamic]ce.Gutter_Marker) {
	state := codeProvidersState()
	if !isProjectScript(state, doc.path) do return
	for m in markedLines(state, doc) {
		_, long := markedText(m)
		choices: []string
		if len(m.usages) > 1 {
			choices = make([]string, len(m.usages), context.temp_allocator)
			for u, i in m.usages do choices[i] = choiceLabel(u)
		}
		icon: ce.Gutter_Icon = m.symbol.kind == .Type ? (len(m.usages) > 0 ? .Diamond : .Ring) : .Dot
		append(out, ce.Gutter_Marker{line = m.line, icon = icon, tooltip = long, choices = choices})
	}
}

@(private)
linkInlays :: proc(doc: ce.Provider_Document, ctx: ce.Provider_Context, out: ^[dynamic]ce.Inlay_Hint) {
	state := codeProvidersState()
	if !isProjectScript(state, doc.path) do return
	for m in markedLines(state, doc) {
		short, _ := markedText(m)
		if short == "" do continue
		append(out, ce.Inlay_Hint{pos = {m.line, len(cebuf.buffer_line_str(doc.buffer, m.line))}, label = short, kind = .Note})
	}
}

// A marker's click (or its menu's choice): the usage it stands for, for the view to open
@(private)
linkMarkerClicked :: proc(doc: ce.Provider_Document, marker: ce.Gutter_Marker, userData: rawptr) {
	state := codeProvidersState()
	if state == nil do return
	for m in markedLines(state, doc) {
		if m.line != marker.line do continue
		if len(m.usages) == 0 {
			CodeProviders_SetOpen({}, fmt.tprintf("Nothing uses %s yet", ScriptSymbol_Name(m.symbol)))
			return
		}
		choice := clamp(marker.choice, 0, len(m.usages) - 1)
		CodeProviders_SetOpen(m.usages[choice].target)
		return
	}
}

// Find Usages: the symbol at the position, and every use of it
@(private)
linkUsages :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, out: ^ce.Usages_Result) -> bool {
	state := codeProvidersState()
	if !isProjectScript(state, doc.path) do return false
	symbol := ScriptRename_SymbolAt(scriptSources(state), absolutePath(doc.path), pos.line, pos.col, &state.scriptIndex, &state.scripts)
	if symbol.kind == .None do return false
	usages := ScriptLinks_Usages(state, symbol)
	out.symbol = strings.clone(ScriptSymbol_Name(symbol), ctx.allocator)
	if len(usages) == 0 {
		out.empty_message = fmt.aprintf("Nothing in the project uses %s yet", symbolTitle(symbol), allocator = ctx.allocator)
		return true
	}
	targets := make([]UsageTarget, len(usages), context.temp_allocator)
	for u, i in usages {
		targets[i] = u.target
		append(&out.items, ce.Provider_Usage{label = strings.clone(u.label, ctx.allocator), preview = strings.clone(u.preview, ctx.allocator), id = i})
	}
	CodeProviders_SetUsageTargets(targets)
	return true
}

@(private)
linkUsageOpened :: proc(doc: ce.Provider_Document, usage: ce.Provider_Usage, userData: rawptr) {
	if target, ok := CodeProviders_UsageTarget(usage.id); ok do CodeProviders_SetOpen(target)
}

// Rename: what's at the position, with what else it changes
@(private)
linkPrepareRename :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, out: ^ce.Rename_Target) -> bool {
	state := codeProvidersState()
	if !isProjectScript(state, doc.path) do return false
	symbol := ScriptRename_SymbolAt(scriptSources(state), absolutePath(doc.path), pos.line, pos.col, &state.scriptIndex, &state.scripts)
	if symbol.kind == .None do return false
	counts := ScriptRename_Project(state, symbol, ScriptSymbol_Name(symbol), dryRun = true)
	project := ProjectRenameCounts_Text(counts)
	out^ = {
		start = {symbol.line, symbol.start}, end = {symbol.line, symbol.end},
		name = strings.clone(ScriptSymbol_Name(symbol), ctx.allocator),
		title = fmt.aprintf("Rename %s", symbolTitle(symbol), allocator = ctx.allocator),
		note = strings.clone(project != "" ? fmt.tprintf("Also: %s", project) : "In the code only: nothing in the project names it", ctx.allocator),
	}
	CodeProviders_SetRenameSymbol(symbol)
	return true
}

@(private)
linkRename :: proc(doc: ce.Provider_Document, target: ce.Rename_Target, newName: string, ctx: ce.Provider_Context, out: ^ce.Rename_Result) -> bool {
	state := codeProvidersState()
	if state == nil do return false
	symbol, known := CodeProviders_RenameSymbol()
	if !known || ScriptSymbol_Name(symbol) != target.name {
		symbol = ScriptRename_SymbolAt(scriptSources(state), absolutePath(doc.path), target.start.line, target.start.col, &state.scriptIndex, &state.scripts)
	}
	if symbol.kind == .None {
		out.error = strings.clone("This isn't something the project names any more", ctx.allocator)
		return false
	}
	if symbol.kind == .Type {
		taken := ScriptCatalog_Find(&state.scripts, newName) != nil || ScriptCatalog_FindNodeType(&state.scripts, newName) != nil
		for d in state.scripts.dataTypes do taken ||= d.name == newName
		if taken {
			out.error = fmt.aprintf("A script or type named %s already exists", newName, allocator = ctx.allocator)
			return false
		}
	}
	code := ScriptRename_Code(scriptSources(state), symbol, newName)
	if code.problem != "" {
		out.error = strings.clone(code.problem, ctx.allocator)
		return false
	}
	path := absolutePath(doc.path)
	others := make([dynamic]CodeEdit, context.temp_allocator)
	files := make(map[string]bool, allocator = context.temp_allocator)
	for edit in code.edits {
		files[edit.path] = true
		if edit.path == path {
			append(&out.edits, ce.Text_Edit{start = {edit.line, edit.column}, end = {edit.line, edit.endColumn}, text = strings.clone(edit.text, ctx.allocator)})
		} else {
			append(&others, edit)
		}
	}
	counts := ScriptRename_Project(state, symbol, newName, dryRun = true)
	CodeProviders_SetRename(symbol, newName, others[:])
	b := strings.builder_make(ctx.allocator)
	fmt.sbprintf(&b, "Renamed %s to %s: %d place%s in %d file%s", ScriptSymbol_Name(symbol), newName, len(code.edits), len(code.edits) == 1 ? "" : "s", len(files), len(files) == 1 ? "" : "s")
	if project := ProjectRenameCounts_Text(counts); project != "" do fmt.sbprintf(&b, ", %s", project)
	if len(code.unsure) > 0 do fmt.sbprintf(&b, "; left %d .%s of unknown type (%s)", len(code.unsure), symbol.field, strings.join(code.unsure[:], ", ", context.temp_allocator))
	out.message = strings.to_string(b)
	return true
}

/*
Opens a usage (`Code_Usage_Opened`): a node's scene or component tab with the node selected, a
global's Project Settings tab, a data resource selected in the browser.
*/
ScriptLinks_Open :: proc(state: ^State, target: UsageTarget) {
	p := &state.project
	switch target.kind {
	case .Node:
		if target.scene < 0 || target.scene >= len(p.scenes) || target.node < 0 || target.node >= len(p.scenes[target.scene].nodes) do return
		scene := &p.scenes[target.scene]
		if Scene_IsComponent(scene) do scene.opened = true
		scene.tabClosed = false
		// Another scene: update shows it (and leaves the code tab) when currentScene changes
		state.currentScene = target.scene
		Selection_Set(state, {target.node})
		logLine(state, .Info, fmt.aprintf("Selected %s in %s", scene.nodes[target.node].name, sceneLabel(scene)))
	case .Global:
		ProjectSettings_Open(state, .Globals)
	case .Data:
		if target.index < 0 || target.index >= len(p.data) do return
		for asset, i in p.assets do if asset.path == p.data[target.index].path {
			state.browserSelection = {kind = .Asset, index = i}
			logLine(state, .Info, fmt.aprintf("Selected %s in the browser", filepath.base(asset.path)))
			break
		}
	}
}

// Sent by the code view for what the providers left (a usage to open, a rename's project side)
@(private)
linksSend :: proc(ctx: ^skald.Ctx(Msg)) {
	if target, notice, ok := CodeProviders_TakeOpen(); ok do skald.send(ctx, Msg(Code_Usage_Opened{target, notice}))
	if rename, ok := CodeProviders_TakeRename(); ok do skald.send(ctx, Msg(rename))
}
