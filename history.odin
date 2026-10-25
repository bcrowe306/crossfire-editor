package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import e "engine:."

/*
Undo and redo, as a history of commands.

Each `UndoCommand` is one undoable step: what changed (one node, or a whole scene's node list),
its state before and after, the selection before and after, and the scene it happened in. Undo
puts the "before" state back; redo puts the "after" state back. Both stacks own their commands'
data.

Recording is automatic. `update` asks `History_Classify` whether a message edits the project.
If it does, `update` snapshots the part it edits, applies the message, and compares; a change
becomes a command (`History_Commit`). Editing code doesn't need to know about undo: a new kind of
edit only needs a line in `History_Classify`, saying what it touches and how it merges.

Merging (debounce and throttle): an edit with the same merge key as the newest command (the same
field of the same node, say) is folded into it instead of becoming a new step, if
- it came within `undoMergeMs` of the previous edit (debounce: typing a name or dragging a number
  is one step, a pause starts a new one), and
- the run started less than `undoGroupMaxMs` ago (throttle: a long run is still cut into steps;
  0 turns this off).
Gestures (a viewport drag, from press to release) always merge, however long they take.

What isn't undoable: selection, panel layout and other view state, and asset imports and removals,
which copy and delete files on disk.
*/

History :: struct {
	undo: [dynamic]UndoCommand,
	redo: [dynamic]UndoCommand,
	// Bumped when a viewport drag starts, so two drags never merge
	gesture: int,
	// Bumped by every change to the project through the history (a step pushed, merged, undone
	// or redone), so unsaved changes can be detected (project_session.odin)
	version: int,
	// The part of `version` that changed only LDtk documents (`FileChange` steps): whether they're
	// unsaved is the documents' own (ldtk_doc.odin's `LDtkDoc_Unsaved`: an undo back to the saved
	// text leaves nothing to save), so they don't count here
	fileVersion: int,
}

UndoCommand :: struct {
	// "Rename Spaceship" (owned)
	label: string,
	scene: int,
	selectionBefore: int,
	selectionAfter: int,
	// The editor mode it was made in, and the one it left (editor_modes.odin): undo shows the
	// first, redo the second, so edits in every mode undo in order from one history
	modeBefore, modeAfter: EditorMode,
	// 0 = never merges
	mergeKey: u64,
	// Merges with the same key regardless of time (a drag)
	sticky: bool,
	started: time.Tick,
	last: time.Tick,
	change: UndoChange,
}

UndoChange :: union {
	NodeChange,
	SceneChange,
	ProjectChange,
	FileChange,
}

/*
An LDtk project's document (the Level mode's edits, ldtk_ops.odin): each file's text before and
after, in memory (ldtk_doc.odin: saving writes them). Undo puts "before" back, redo "after"; a
document changed since (LDtk saved the file and it was read again or merged) is merged when the
two changes don't touch (`History_MergeText`), else the step waits for the user's answer
(`LevelMode.conflict`). A rename the scenes followed also holds the
project's snapshot (`project`, `hasProject`), and the components whose LDtkLevel nodes followed it
(`components`: the project's snapshot holds scenes only).
*/
FileChange :: struct {
	// The LDtk project (relative to the project folder; owned)
	ldtkFile: string,
	files: [dynamic]FileText,
	hasProject: bool,
	project: ProjectChange,
	components: [dynamic]ComponentNodes,
}

// A component's nodes before and after a step (a rename its LDtkLevel nodes followed; owned)
ComponentNodes :: struct {
	// The component's file (its `SceneDef.component`)
	file: string,
	before, after: [dynamic]NodeDef,
}

/*
A file's text before and after a step (all owned). A big file keeps only what changed, as hunks
(`FileHunk`: the bytes before and after, where each is in its text), found by a diff over the
texts' values (`textHunks`): a stroke on a 256 x 256 level changes some cells and the auto-layer
tiles around them in a 6.5 MB file, and two whole texts a step were 13 MB (200 steps: 2.6 GB).
Files under `FILE_STEP_WHOLE_MAX` keep their whole texts (`whole`: `before`, `after`), and so does a
file the step made or dropped (a level saved apart, added, removed or named again: "" on that side).
`fileStepMake` makes one, `fileStepTarget` the text a document gets back from one.
*/
FileText :: struct {
	path: string,
	// Whole texts (a small file)
	before, after: string,
	whole: bool,
	// A big file's hunks, in order, and its texts' lengths
	hunks: [dynamic]FileHunk,
	beforeLen, afterLen: int,
}

// What changed in one place of a big file: its bytes before and after (owned), where they are in
// the text before and in the text after
FileHunk :: struct {
	beforeAt, afterAt: int,
	before, after: string,
}

// Files bigger than this keep only their steps' hunks (FileText)
FILE_STEP_WHOLE_MAX :: 256 * 1024

// Frees a file step
@(private="file")
fileStepDestroy :: proc(f: ^FileText) {
	delete(f.path)
	delete(f.before)
	delete(f.after)
	for h in f.hunks {
		delete(h.before)
		delete(h.after)
	}
	delete(f.hunks)
	f^ = {}
}

// The bytes a file step keeps
FileText_Size :: proc(f: FileText) -> int {
	n := len(f.before) + len(f.after)
	for h in f.hunks do n += len(h.before) + len(h.after)
	return n
}

// A file step from whole texts (cloned, or their hunks)
@(private="file")
fileStepMake :: proc(path, before, after: string) -> FileText {
	// A file made or dropped ("" one side) keeps its text: undo puts it back without a document to apply hunks to
	if before == "" || after == "" || max(len(before), len(after)) < FILE_STEP_WHOLE_MAX do return {path = strings.clone(path), before = strings.clone(before), after = strings.clone(after), whole = true}
	return {path = strings.clone(path), hunks = textHunks(before, after), beforeLen = len(before), afterLen = len(after)}
}

// A piece of text a diff compares: a value up to its comma or line break
@(private="file")
Segment :: struct {
	start, end: int,
	hash: u64,
}

// A text's segments (temp allocated): split after each ',' and '\n'
@(private="file")
segmentsOf :: proc(text: string) -> []Segment {
	out := make([dynamic]Segment, 0, len(text) / 8 + 1, context.temp_allocator)
	start := 0
	for i in 0 ..< len(text) {
		c := text[i]
		if c == ',' || c == '\n' || i == len(text) - 1 {
			append(&out, Segment{start, i + 1, hash.fnv64a(transmute([]u8)text[start:i + 1])})
			start = i + 1
		}
	}
	return out[:]
}

/*
The hunks turning one text into another (owned): their common start and end left out, then the
segments between compared (`segmentsOf`); where they differ, the next place they agree again is
looked for within `DIFF_WINDOW` segments of both (`DIFF_ANCHOR` segments in a row equal, the
fewest skipped),
and what's between is a hunk. Any place two equal segments meet is a right answer: the hunks
always make the new text, only not always the fewest bytes.
*/
@(private="file")
textHunks :: proc(before, after: string) -> [dynamic]FileHunk {
	DIFF_WINDOW :: 4096
	DIFF_ANCHOR :: 6
	hunks := make([dynamic]FileHunk)
	n := min(len(before), len(after))
	p := 0
	for p < n && before[p] == after[p] do p += 1
	q := 0
	for q < n - p && before[len(before) - 1 - q] == after[len(after) - 1 - q] do q += 1
	// Whole segments: the start backs up to one's beginning, the end to one's end
	for p > 0 && before[p - 1] != ',' && before[p - 1] != '\n' do p -= 1
	for q > 0 && before[len(before) - q - 1] != ',' && before[len(before) - q - 1] != '\n' do q -= 1
	a, b := before[p:len(before) - q], after[p:len(after) - q]
	if len(a) == 0 && len(b) == 0 do return hunks
	sa, sb := segmentsOf(a), segmentsOf(b)
	same :: #force_inline proc(a, b: string, x, y: Segment) -> bool {
		return x.hash == y.hash && x.end - x.start == y.end - y.start && a[x.start:x.end] == b[y.start:y.end]
	}
	add :: proc(hunks: ^[dynamic]FileHunk, a, b: string, sa, sb: []Segment, i0, i1, j0, j1, p: int) {
		as := i0 < len(sa) ? sa[i0].start : len(a)
		ae := i1 > i0 ? sa[i1 - 1].end : as
		bs := j0 < len(sb) ? sb[j0].start : len(b)
		be := j1 > j0 ? sb[j1 - 1].end : bs
		// Next to the last hunk: one hunk
		if n := len(hunks); n > 0 && hunks[n - 1].beforeAt + len(hunks[n - 1].before) == p + as && hunks[n - 1].afterAt + len(hunks[n - 1].after) == p + bs {
			last := &hunks[n - 1]
			grownBefore := strings.concatenate({last.before, a[as:ae]})
			grownAfter := strings.concatenate({last.after, b[bs:be]})
			delete(last.before)
			delete(last.after)
			last.before, last.after = grownBefore, grownAfter
			return
		}
		append(hunks, FileHunk{beforeAt = p + as, afterAt = p + bs, before = strings.clone(a[as:ae]), after = strings.clone(b[bs:be])})
	}
	// A run of DIFF_ANCHOR segments from each one, as one hash: where two runs agree, they agree
	// again (one equal segment in a run of "2," cells is no place to start agreeing)
	grams :: proc(segs: []Segment) -> []u64 {
		out := make([]u64, len(segs), context.temp_allocator)
		for l in 0 ..< len(segs) {
			h := u64(14695981039346656037)
			for m in l ..< min(l + DIFF_ANCHOR, len(segs)) do h = (h ~ segs[m].hash) * 1099511628211
			out[l] = h
		}
		return out
	}
	runSame :: proc(a, b: string, sa, sb: []Segment, i, j: int) -> bool {
		if len(sa) - i < DIFF_ANCHOR || len(sb) - j < DIFF_ANCHOR {
			if len(sa) - i != len(sb) - j do return false
		}
		for m in 0 ..< min(DIFF_ANCHOR, len(sa) - i, len(sb) - j) {
			x, y := sa[i + m], sb[j + m]
			if x.hash != y.hash || x.end - x.start != y.end - y.start || a[x.start:x.end] != b[y.start:y.end] do return false
		}
		return true
	}
	ga, gb := grams(sa), grams(sb)
	window := make(map[u64]int, DIFF_WINDOW, context.temp_allocator)
	i, j := 0, 0
	for i < len(sa) || j < len(sb) {
		if i < len(sa) && j < len(sb) && same(a, b, sa[i], sb[j]) {
			i += 1
			j += 1
			continue
		}
		// Where they agree again: a run of old segments found among the next new ones, the
		// nearest (fewest segments skipped on both sides); most are near, so a small window first
		di, dj := len(sa) - i, len(sb) - j
		for size in ([]int{64, DIFF_WINDOW}) {
			clear(&window)
			for l := min(j + size, len(sb)) - 1; l >= j; l -= 1 do window[gb[l]] = l
			best := max(int)
			for k in 0 ..< min(size, len(sa) - i) {
				if k >= best do break
				l, found := window[ga[i + k]]
				if !found || k + l - j >= best || !runSame(a, b, sa, sb, i + k, l) do continue
				di, dj = k, l - j
				best = k + l - j
			}
			if best < max(int) do break
		}
		add(&hunks, a, b, sa, sb, i, i + di, j, j + dj, p)
		i += di
		j += dj
	}
	return hunks
}

/*
A big file step applied to a text that's one of its sides (undo: from "after" to "before"; redo
the other way), false when the text isn't that side.
*/
@(private="file")
fileStepApply :: proc(f: FileText, current: string, undo: bool) -> (string, bool) {
	if len(current) != (undo ? f.afterLen : f.beforeLen) do return "", false
	b := strings.builder_make(0, undo ? f.beforeLen : f.afterLen, context.temp_allocator)
	at := 0
	for h in f.hunks {
		from, have := undo ? h.afterAt : h.beforeAt, undo ? h.after : h.before
		put := undo ? h.before : h.after
		if from < at || from + len(have) > len(current) || current[from:][:len(have)] != have do return "", false
		strings.write_string(&b, current[at:from])
		strings.write_string(&b, put)
		at = from + len(have)
	}
	strings.write_string(&b, current[at:])
	return strings.to_string(b), true
}

/*
The text a document gets back from a file step (undo: its "before", redo: its "after"), given the
text it has now. When the document is as the step left it, that's the step's text; when it changed
elsewhere (LDtk saved the file meanwhile), a small file's step is applied to it where the two don't
touch (`History_MergeText`) and `force` overwrites it (the conflict dialog's Overwrite). A big
file's step needs the document as the step left it (its hunks are all it kept).

Returns:
- The text (temp allocated or the step's), false when it can't be made
*/
@(private="file")
fileStepTarget :: proc(f: FileText, current: string, undo, force: bool) -> (string, bool) {
	if f.whole {
		want := undo ? f.before : f.after
		expected := undo ? f.after : f.before
		switch {
		case current == expected || current == want || force: return want, true
		}
		return History_MergeText(expected, want, current)
	}
	if text, ok := fileStepApply(f, current, undo); ok do return text, true
	// Already there (the step's other side)
	if _, other := fileStepApply(f, current, !undo); other do return current, true
	return "", false
}

// A file step's text before, from its text after (the document's now: the step was just made)
@(private="file")
fileStepWhole :: proc(f: FileText, after: string) -> (before: string, ok: bool) {
	if f.whole do return f.before, f.after == after
	return fileStepApply(f, after, true)
}

// The project's scene list and settings: adding, removing, renaming scenes, Project Settings.
// The snapshots are on the heap (owned, from `takeProjectSnapshot`): a ProjectSnapshot is about
// 12 KB, and two of them by value made every UndoCommand 25 KB (copies of which in debug builds
// took a Windows test thread's 1 MB stack)
ProjectChange :: struct {
	before: ^ProjectSnapshot,
	after: ^ProjectSnapshot,
}

// Everything a `.Project` edit can change (owned)
ProjectSnapshot :: struct {
	name: string,
	startScene: string,
	locale: string,
	icon: string,
	gameSize: [2]f32,
	scaleMode: e.ScaleMode,
	renderer: e.RenderBackend,
	textureFilter: e.TextureFilter,
	background: sdl.Color,
	scenes: [dynamic]SceneDef,
	exports: ExportSettings,
	physics: e.PhysicsSettings,
	window: e.WindowSettings,
	grid: e.GridSettings,
	audioOutput: e.AudioOutputSettings,
	globals: [dynamic]GlobalDef,
	data: [dynamic]DataDef,
	// Animation assets' sheets and animations, by file
	animationSets: [dynamic]AnimationSetDef,
	// UI themes by file, and the project's
	themes: [dynamic]ThemeDef,
	// Dialogues by file
	dialogues: [dynamic]DialogueDef,
	// Physics materials by file
	materials: [dynamic]MaterialDef,
	uiTheme: string,
	transition: e.Transition,
	loadingScene: string,
	actions: [dynamic]ActionDef,
	buses: [dynamic]BusDef,
	steam: e.SteamSettings,
	achievements: [dynamic]AchievementDef,
	players: e.PlayerSettings,
	// The scene open at the time, shown again on undo/redo
	currentScene: int,
}

// One node's properties
NodeChange :: struct {
	index: int,
	before: NodeDef,
	after: NodeDef,
}

// A scene's whole node list: adding, removing, pasting and moving nodes
SceneChange :: struct {
	before: [dynamic]NodeDef,
	after: [dynamic]NodeDef,
}

EditScope :: enum {
	// Not an edit
	None,
	// Changes the properties of one node
	Node,
	// Changes the scene's node list
	Scene,
	// Changes the scene list or the project's settings
	Project,
	// Changes an LDtk project's document in memory (`EditInfo.ldtkFile`; ldtk_doc.odin)
	Files,
}

// What a message edits, from `History_Classify`
EditInfo :: struct {
	scope: EditScope,
	// The node a `.Node` edit changes
	node: int,
	label: string,
	mergeKey: u64,
	sticky: bool,
	// A `.Files` edit's LDtk project (relative to the project folder), and whether the project's
	// scenes may change too (renames they follow)
	ldtkFile: string,
	withProject: bool,
}

// The state an edit started from, taken before the message is applied
EditSnapshot :: struct {
	info: EditInfo,
	scene: int,
	selection: int,
	// The mode the edit was made in
	mode: EditorMode,
	node: NodeDef,
	nodes: [dynamic]NodeDef,
	// A `.Project` edit's (or a `.Files` edit's with `withProject`), owned; nil otherwise
	project: ^ProjectSnapshot,
	// A `.Files` edit's files and their texts (owned)
	files: [dynamic]FileText,
	// A rename's components (with LDtkLevel nodes of that file): their nodes before (owned)
	components: [dynamic]ComponentNodes,
}

/*
Whether a message edits the project, and how its undo step merges.

Inputs:
- s: The state before the message
- m: The message

Returns:
- What it edits (`scope = .None` if nothing)
*/
History_Classify :: proc(s: ^State, m: Msg) -> EditInfo {
	scene := &s.project.scenes[s.currentScene]
	selected := s.selectedNode
	hasSelection := selected >= 0 && selected < len(scene.nodes)
	name := hasSelection ? scene.nodes[selected].name : ""
	key :: proc(parts: ..any) -> u64 {
		return hash.fnv64a(transmute([]byte)fmt.tprint(..parts))
	}
	node :: proc(index: int, label: string, mergeKey: u64 = 0) -> EditInfo {
		return {scope = .Node, node = index, label = label, mergeKey = mergeKey}
	}

	if index, field, ok := SceneSettings_Classify(s, m); ok && index >= 0 && index < len(s.project.scenes) {
		sceneName := s.project.scenes[index].name
		return {scope = .Project, label = fmt.tprintf("Change the %s of %s", field, sceneName), mergeKey = key("scene-settings", field, index)}
	}
	// The Animation panel on an animation asset: a project step (the snapshot holds every set);
	// an Aseprite file's animations are read only
	if AnimEdit_IsEdit(m) {
		src := AnimEdit_Source(s)
		#partial switch src.kind {
		case .Set:
			field := ""
			if f, isField := m.(Anim_Field_Changed); isField do field = fmt.tprint(f.field)
			if n, isNumber := m.(Number_Text_Changed); isNumber do field = fmt.tprint(n.target)
			if d, isDuration := m.(Anim_Duration_Changed); isDuration do field = fmt.tprint(AnimDurationTarget(d.frame))
			_, typing := m.(Anim_Name_Typed)
			merge := field != "" || typing ? key("anim-set", src.path, field, typing, s.animEditor.selected) : 0
			return {scope = .Project, label = fmt.tprintf("Change the animations in %s", filepath.base(src.path)), mergeKey = merge}
		case .Aseprite, .None:
			return {}
		}
	}
	// The Level mode's painting: a stroke's release, a placement, Delete and Duplicate (level_paint.odin)
	if s.mode == .Level {
		if info, world := LevelWorld_Classify(s, m); world do return info
		if info, painted := LevelPaint_Classify(s, m); painted do return info
	}
	#partial switch v in m {
	case Anim_Set_From_Node:
		if hasSelection do return node(selected, fmt.tprintf("Save the animations of %s as an asset", name))
	// The sprite sheet slicer's outputs (slicer_edit.odin); its own settings aren't undo steps
	case Slicer_Asset_Created:
		if tab := Slicer_Shown(s); tab != nil {
			if Slicer_AssetIndex(s, tab) >= 0 do return {scope = .Project, label = fmt.tprintf("Update %s from %s", filepath.base(tab.settings.asset), filepath.base(tab.image))}
			return {scope = .Project, label = fmt.tprintf("Make an animation asset from %s", filepath.base(tab.image))}
		}
	case Slicer_Applied:
		if tab := Slicer_Shown(s); tab != nil && Slicer_TargetSprite(s) != nil do return node(selected, fmt.tprintf("Give %s the animations of %s", name, filepath.base(tab.image)))
	case Slicer_Added_To_Scene:
		if tab := Slicer_Shown(s); tab != nil do return {scope = .Scene, label = fmt.tprintf("Add an AnimatedSprite of %s", filepath.base(tab.image))}
	case Code_Scrub_Write:
		// A scrubbed value written to a node's own value (the code's default is the code tab's undo)
		if v.kind == .Node_Value && v.scene >= 0 && v.scene < len(s.project.scenes) && v.node >= 0 && v.node < len(s.project.scenes[v.scene].nodes) {
			return {scope = .Project, label = fmt.tprintf("Change %s of %s (from the running game)", v.field, s.project.scenes[v.scene].nodes[v.node].name)}
		}
	case Listener_Target_Chosen:
		if d := s.listenerDialog; d.node >= 0 && d.node < len(scene.nodes) do return node(d.node, fmt.tprintf("Listen to %s's %s", scene.nodes[d.node].name, d.event))
	case Global_Listen_Requested:
		if v.node >= 0 && v.node < len(scene.nodes) do return node(v.node, fmt.tprintf("Listen to %s's %s", v.global, v.event))
	case Listener_Removed:
		if v.node >= 0 && v.node < len(scene.nodes) do return node(v.node, fmt.tprintf("Remove a listener of %s", scene.nodes[v.node].name))
	case Scene_Action:
		if SceneOp_EditsProject(v.op) do return {scope = .Project, label = sceneOpLabel(s, v)}
		return {}
	case Project_Settings_Applied:
		return {scope = .Project, label = "Change project settings"}
	case Code_Rename_Requested:
		// Every scene, component, global and data resource naming it: one step (the code's edits
		// are the code tabs' own undo)
		return {scope = .Project, label = fmt.tprintf("Rename %s to %s", symbolTitle(v.symbol), v.newName)}
	case Export_Target_Run:
		// Exporting applies the dialog first
		return {scope = .Project, label = "Change project settings"}
	case Rename_Committed:
		// Renaming a component moves its file: not undoable, like removing an asset
		if s.rename.active && s.rename.target == .Component do return {}
		if s.rename.active && s.rename.target == .Scene {
			index := s.rename.node
			label := index >= 0 && index < len(s.project.scenes) ? fmt.tprintf("Rename scene %s", s.project.scenes[index].name) : "Rename scene"
			return {scope = .Project, label = label}
		}
		index := s.rename.node
		if s.rename.active && index >= 0 && index < len(scene.nodes) {
			// Renaming a body joints name changes them too, and stored node paths may change
			// (node_paths_edit.odin): the whole scene is the step
			if isBodyKind(scene.nodes[index].kind) && Scene_JointsReferTo(scene, scene.nodes[index].name) || Scene_HasNodePaths(scene, &s.scripts) {
				return {scope = .Scene, label = fmt.tprintf("Rename %s", scene.nodes[index].name)}
			}
			return node(index, fmt.tprintf("Rename %s", scene.nodes[index].name))
		}
	case Node_Renamed:
		// Joints naming a body, stored node paths follow: the whole scene is the step
		if hasSelection && (isBodyKind(scene.nodes[selected].kind) && Scene_JointsReferTo(scene, name) || Scene_HasNodePaths(scene, &s.scripts)) {
			return {scope = .Scene, label = fmt.tprintf("Rename %s", name), mergeKey = key("rename", s.currentScene, selected)}
		}
		if hasSelection do return node(selected, fmt.tprintf("Rename %s", name), key("rename", s.currentScene, selected))
	case Node_Script_Changed:
		if hasSelection do return node(selected, string(v) == "" || string(v) == TEXTURE_NONE ? fmt.tprintf("Remove script from %s", name) : fmt.tprintf("Attach %s to %s", string(v), name))
	case Script_Prop_Changed:
		switch t in v.target {
		case SelectedNodeTarget:
			if hasSelection do return node(selected, fmt.tprintf("Change %s of %s", v.name, name), key("prop", v.name, s.currentScene, selected))
		case DataTarget:
			if int(t) < len(s.project.data) {
				return {scope = .Project, label = fmt.tprintf("Change %s of %s", v.name, DataName(s.project.data[t].path)), mergeKey = key("data", v.name, int(t))}
			}
		case DraftGlobalTarget:
			// The dialog's draft: Apply is the undo step
		case NodeScriptTarget:
			if hasSelection do return node(selected, fmt.tprintf("Change %s of %s", v.name, name), key("prop-more", int(t), v.name, s.currentScene, selected))
		case NodeCustomTarget:
			if hasSelection do return node(selected, fmt.tprintf("Change %s of %s", v.name, name), key("prop-custom", v.name, s.currentScene, selected))
		}
	case New_Script_Created:
		if hasSelection do return node(selected, fmt.tprintf("Attach a new script to %s", name))
	case Node_Visibility_Changed:
		if hasSelection do return node(selected, fmt.tprintf("%s %s", bool(v) ? "Show" : "Hide", name))
	case Node_Field_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %s of %s", fieldLabel(v.field), name), key("field", v.field, s.currentScene, selected))
	case Number_Text_Changed:
		// Typing a number: the same step as changing that field
		if field, isNode := v.target.(NodeField); isNode && hasSelection {
			return node(selected, fmt.tprintf("Change %s of %s", fieldLabel(field), name), key("field", field, s.currentScene, selected))
		}
		if field, isAnim := v.target.(AnimField); isAnim && hasSelection {
			return node(selected, fmt.tprintf("Change an animation of %s", name), key("anim", field, s.currentScene, selected, s.animEditor.selected))
		}
		if frame, isDuration := v.target.(AnimDurationTarget); isDuration && hasSelection {
			return node(selected, fmt.tprintf("Change a frame time of an animation of %s", name), key("anim-duration", int(frame), s.currentScene, selected, s.animEditor.selected))
		}
		if field, isTimeline := v.target.(TimelineNumber); isTimeline {
			if _, i := Timeline_Animator(s); i >= 0 do return node(i, fmt.tprintf("Change the %v in the clips of %s", field, scene.nodes[i].name), key("timeline-number", field, i, s.timeline.clip, s.timeline.track, s.timeline.key))
		}
		if field, isCam := v.target.(CameraToolNumber); isCam && hasSelection {
			return node(selected, fmt.tprintf("Change %v of %s", CameraToolField(field), name), key("camtool", CameraToolField(field), s.currentScene, selected))
		}
		if field, isCamera := v.target.(CameraNumber); isCamera && hasSelection {
			return node(selected, fmt.tprintf("Change %v of %s", CameraField(field), name), key("camera", CameraField(field), s.currentScene, selected))
		}
		if field, isSM := v.target.(SMNumberTarget); isSM {
			if _, i := States_Machine(s); i >= 0 do return node(i, fmt.tprintf("Change a state machine's %v", field), key("states-number", field, i, s.states.state, s.states.transition))
		}
		if field, isNav := v.target.(NavNumberTarget); isNav && hasSelection {
			return node(selected, fmt.tprintf("Change %v of %s", NavField(field), name), key("nav", NavField(field), s.currentScene, selected))
		}
		if field, isUI := v.target.(UINumberTarget); isUI && hasSelection {
			return node(selected, fmt.tprintf("Change %v of %s", UIField(field), name), key("ui", UIField(field), s.currentScene, selected))
		}
		if t, isLDtk := v.target.(LDtkNumberTarget); isLDtk do return LDtkEdit_Info(t.edit)
		if prop, isProp := v.target.(ScriptPropTarget); isProp && hasSelection {
			return node(selected, fmt.tprintf("Change %s of %s", prop.name, name), key("prop", prop.name, fmt.tprint(prop.target), s.currentScene, selected))
		}
	case Node_Text_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %v of %s", v.field, name), key("text", v.field, s.currentScene, selected))
	case Node_Flag_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %v of %s", v.flag, name))
	// The Animation panel: the selected node's animations
	case Anim_Added:
		if hasSelection do return node(selected, fmt.tprintf("Add an animation to %s", name))
	case Anim_Duplicated:
		if hasSelection do return node(selected, fmt.tprintf("Duplicate an animation of %s", name))
	case Anim_Removed:
		if hasSelection do return node(selected, fmt.tprintf("Remove an animation of %s", name))
	case Anim_Moved:
		if hasSelection do return node(selected, fmt.tprintf("Reorder the animations of %s", name))
	case Anim_Name_Typed:
		// State machines and Timeline keys playing it by name follow: then the scene is the step
		if hasSelection && Scene_PlaysAnimationsByName(scene) do return {scope = .Scene, label = fmt.tprintf("Rename an animation of %s", name), mergeKey = key("anim-name", s.currentScene, selected, s.animEditor.selected)}
		if hasSelection do return node(selected, fmt.tprintf("Rename an animation of %s", name), key("anim-name", s.currentScene, selected, s.animEditor.selected))
	case Anim_Field_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change an animation of %s", name), key("anim", v.field, s.currentScene, selected, s.animEditor.selected))
	case Anim_Loop_Changed, Anim_Mode_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change an animation of %s", name))
	case Anim_Frame_Clicked:
		if hasSelection do return node(selected, fmt.tprintf("Change the frames of an animation of %s", name))
	case Anim_Durations_Toggled:
		if hasSelection do return node(selected, fmt.tprintf("Change the frame times of an animation of %s", name))
	case Anim_Duration_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change a frame time of an animation of %s", name), key("anim-duration", v.frame, s.currentScene, selected, s.animEditor.selected))
	case Anim_Sheet_Texture_Changed, Anim_Sheet_Dropped, Anim_Grid_Mode_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change the sheet of an animation of %s", name))
	case Anim_Autoplay_Set:
		if hasSelection do return node(selected, fmt.tprintf("Change the first animation of %s", name))
	// The States tab: its StateMachine's step (not necessarily the selected node); a drag is one
	// step, typing merges
	case SM_Changed:
		if _, i := States_Machine(s); i >= 0 {
			label := fmt.tprintf("Change %v in %s", v.op, scene.nodes[i].name)
			#partial switch v.op {
			case .State_Moved:
				info := node(i, label, key("states-drag", s.history.gesture))
				info.sticky = true
				return info
			case .State_Renamed, .Transition_Condition, .Transition_Guard, .State_Can_Exit, .State_Enter_Event, .State_Exit_Event, .Param_Renamed, .Param_Value:
				return node(i, label, key("states-text", v.op, i, s.states.state, s.states.transition, v.index))
			case .Clause_Changed:
				// Typing a value merges; a choice is a step of its own
				if v.part == .Value do return node(i, label, key("states-clause", v.condition, i, s.states.state, s.states.transition, v.index))
			}
			return node(i, label)
		}
	// Camera tools: sliders merge while dragged
	case Camera_Tool_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %v of %s", v.field, name), v.field == .Factor_X || v.field == .Factor_Y ? key("camtool", v.field, s.currentScene, selected) : 0)
	// A Camera's settings: numbers merge while stepped (typing is Number_Text_Changed above)
	case Camera_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %v of %s", v.field, name), v.field != .Target && v.field != .Follow_Mode && v.text == "" && !v.flag ? key("camera", v.field, s.currentScene, selected) : 0)
	// Navigation: typing a number merges
	case Nav_Setting_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %v of %s", v.field, name))
	// Lights: a slider's drag merges
	// Shaders (shader_edit.odin): a parameter's slider drag merges; New Shader gives the node one
	case Node_Shader_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change the shader of %s", name))
	case Node_Shader_Param_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %s of %s's shader", v.name, name), key("shader-param", v.name, s.currentScene, selected))
	case Shader_New_Requested:
		if v.forSelected && hasSelection do return node(selected, fmt.tprintf("Give %s a new shader", name))
	// The Dialogue tab: a project step (the snapshot holds every dialogue); typing merges per
	// field, a node's drag per gesture (dialogue_edit.odin)
	// A plugin's command or inspector row: whatever it changes in the project is one step
	case Plugin_Command_Run:
		return {scope = .Project, label = "Run a plugin's command"}
	case Plugin_Row_Changed:
		return {scope = .Project, label = "Change a plugin's inspector row", mergeKey = key("plugin-row", v.plugin, v.inspector, v.node, v.id)}
	case Dialogue_Changed:
		if Dialogue_Shown(s) == nil do break
		merge: u64 = 0
		#partial switch v.op {
		case .Node_Moved: merge = key("dialogue-move", s.dialogue.path, s.dialogue.node, s.history.gesture)
		case .Step_Field, .Option_Field, .Node_Renamed: merge = key("dialogue-field", s.dialogue.path, s.dialogue.node, v.op, v.step, v.option, v.field)
		}
		return {scope = .Project, label = fmt.tprintf("Edit the dialogue %s (%v)", filepath.base(s.dialogue.path), v.op), mergeKey = merge}
	case DialogueBox_Setting_Changed:
		number := v.field == .Width || v.field == .Height || v.field == .Type_Speed || v.field == .Font_Size || v.field == .Padding
		if hasSelection do return node(selected, fmt.tprintf("Change the %v of %s", v.field, name), number ? key("dialogue-box", v.field, s.currentScene, selected) : 0)
	case Skeleton_Setting_Changed:
		// The mesh grid is the editor's, not the node's (skeleton_edit.odin)
		if v.field == .Mesh_Columns || v.field == .Mesh_Rows do break
		number := v.field == .Bone_Length || v.field == .IK_Length
		if hasSelection do return node(selected, fmt.tprintf("Change the %v of %s", v.field, name), number ? key("skeleton", v.field, s.currentScene, selected) : 0)
	case Skeleton_Bone_Added:
		if hasSelection do return {scope = .Scene, label = fmt.tprintf("Add a bone to %s", name)}
	case Mesh_Made:
		if hasSelection do return node(selected, fmt.tprintf("Make the mesh of %s", name))
	case Mesh_Bound:
		if hasSelection do return node(selected, fmt.tprintf("Bind %s to its bones", name))
	case Line_Setting_Changed:
		// Sliders merge while dragged (line_edit.odin)
		number := v.field == .Width || v.field == .End_Width || v.field == .End_Opacity || v.field == .Lifetime || v.field == .Min_Distance
		if hasSelection do return node(selected, fmt.tprintf("Change the %v of %s", v.field, name), number ? key("line", v.field, s.currentScene, selected) : 0)
	case Touch_Setting_Changed:
		// Sliders merge while dragged (touch_edit.odin)
		number := v.field == .Radius || v.field == .Deadzone || v.field == .Zone_Width || v.field == .Zone_Height || v.field == .Opacity
		if hasSelection do return node(selected, fmt.tprintf("Change the %v of %s", v.field, name), number ? key("touch", v.field, s.currentScene, selected) : 0)
	case Light_Setting_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change the %v of %s", v.field, name), v.field == .Energy || v.field == .Radius || v.field == .Angle ? key("light", v.field, s.currentScene, selected) : 0)
	// UI controls: typing and number fields merge per setting
	case UI_Setting_Changed:
		if hasSelection {
			merge: u64 = 0
			#partial switch v.field {
			case .Placeholder, .Width, .Height, .Margin, .Columns, .Padding, .Spacing, .Value, .Min, .Max, .Step, .Max_Length, .Patch_Left, .Patch_Top, .Patch_Right, .Patch_Bottom, .Text_Size:
				merge = key("ui", v.field, s.currentScene, selected)
			}
			return node(selected, fmt.tprintf("Change %v of %s", v.field, name), merge)
		}
	// Themes: project steps (their files are assets); a slider's drag merges
	case Theme_Field_Changed:
		return {scope = .Project, label = fmt.tprintf("Change a theme's %s", v.field), mergeKey = key("theme", v.field, s.themeSelection)}
	case Theme_Font_Changed:
		return {scope = .Project, label = "Change a theme's font"}
	case Theme_Project_Set:
		return {scope = .Project, label = "Change the project's theme"}
	// The file stays (an asset); undo takes the control's choice back
	case Theme_Created:
		if v.forSelected && hasSelection do return node(selected, fmt.tprintf("Give %s a new theme", name))
	// Physics materials: project steps too; a slider's drag merges
	case Material_Field_Changed:
		return {scope = .Project, label = fmt.tprintf("Change a material's %v", v.field), mergeKey = key("material", v.field, s.materialSelection)}
	case Material_Created:
		if v.forSelected && hasSelection do return node(selected, fmt.tprintf("Give %s a new material", name))
	// On the selected emitter, else the Particles tab's (`Particles_Target`)
	case Particle_Field_Changed:
		if emitter, at := Particles_Target(s); emitter != nil do return node(at, fmt.tprintf("Change %s of %s", particleLabel(v.name), emitter.name), key("particle", v.name, s.currentScene, at))
	case Particle_Axis_Changed:
		if emitter, at := Particles_Target(s); emitter != nil do return node(at, fmt.tprintf("Change %s of %s", particleLabel(v.name), emitter.name), key("particle", v.name, s.currentScene, at))
	case Ramp_Edited:
		if emitter, at := Particles_Target(s); emitter != nil do return node(at, fmt.tprintf("Change the color ramp of %s", emitter.name), key("particle", "colorRamp", s.currentScene, at))
	case Particles_Reset:
		if emitter, at := Particles_Target(s); emitter != nil do return node(at, fmt.tprintf("Reset the particles of %s", emitter.name))
	case Particles_Preset_Applied:
		if emitter, at := Particles_Target(s); emitter != nil do return node(at, fmt.tprintf("Apply the %s preset to %s", v, emitter.name))
	case Node_Layer_Toggled:
		if hasSelection do return node(selected, fmt.tprintf("Change collision %s of %s", v.mask ? "mask" : "layers", name))
	case Node_Points_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change points of %s", name), key("points", s.currentScene, selected))
	case Viewport_Drag_Begin:
		// Alt+drag: the duplicates and their move are one step (the drag's: the gesture this begins)
		if v.duplicate && v.node >= 0 && v.node < len(scene.nodes) {
			return {scope = .Scene, label = fmt.tprintf("Duplicate and move %s", many(s, scene.nodes[v.node].name)), mergeKey = key("drag", s.history.gesture + 1), sticky = true}
		}
	case Viewport_Drag_Move:
		drag := s.viewport.drag
		if drag.mode == .None || drag.mode == .Pan || drag.mode == .Box || drag.mode == .Zoom_Box || drag.node < 0 || drag.node >= len(scene.nodes) do break
		info := node(drag.node, fmt.tprintf("%v %s", drag.mode, scene.nodes[drag.node].name), key("drag", s.history.gesture))
		info.sticky = true
		// Duplicates being moved: the same scene step as their duplication
		if drag.duplicated {
			info.scope = .Scene
			info.label = fmt.tprintf("Duplicate and move %s", many(s, scene.nodes[drag.node].name))
		}
		// Several nodes move together: record the whole scene
		if len(s.selection) > 1 && slice.contains(s.selection[:], drag.node) {
			info.scope = .Scene
			info.label = fmt.tprintf("%v %d nodes", drag.mode, len(s.selection))
		}
		return info
	case Level_Scene_Created:
		// The Level mode's New Scene with This Level (level_mode.odin)
		return {scope = .Project, label = fmt.tprintf("New scene for level %s", s.level.level)}
	case LDtk_Level_Picked:
		// While the Level mode shows, a level picked on the browser's map selects it there
		if s.mode == .Level do break
		return {scope = .Scene, label = fmt.tprintf("Show level %s", v.level)}
	// The Level mode's LDtk tab and canvas: the LDtk project's files (ldtk_ops.odin)
	case LDtk_Edit:
		return LDtkEdit_Info(v)
	case LDtk_Text_Typed:
		return LDtkEdit_Info(v.edit)
	case Level_Canvas_Released:
		drag := s.level.drag
		if drag.moved && (drag.mode == .Level || drag.mode == .Entity) {
			return {scope = .Files, ldtkFile = LevelMode_File(s), label = drag.mode == .Level ? "Move a level in the world" : "Move an entity", withProject = drag.mode == .Level}
		}
	case Level_Collision_Kind_Changed:
		if v.scene >= 0 && v.scene < len(s.project.scenes) do return {scope = .Project, label = fmt.tprintf("Change what IntGrid value %d becomes in %s", v.value, s.project.scenes[v.scene].name)}
	case LDtk_Setting_Changed:
		if !hasSelection do break
		// Typing collision values merges into one step
		if v.field == .Collision_Values do return node(selected, fmt.tprintf("Change the collision values of %s", name), key("ldtk-values", s.currentScene, selected))
		return node(selected, fmt.tprintf("Change %v of %s", v.field, name))
	// The Timeline: its Animator's clips (not necessarily the selected node); a key drag is one
	// step, typing a number or a clip name merges
	case Timeline_Changed:
		if _, i := Timeline_Animator(s); i >= 0 {
			label := fmt.tprintf("%s in the clips of %s", timelineOpLabel(v.op), scene.nodes[i].name)
			if v.op == .Key_Moved {
				info := node(i, label, key("timeline-drag", s.history.gesture))
				info.sticky = true
				return info
			}
			return node(i, label, v.op == .Key_Value ? key("timeline-value", i, s.timeline.track, s.timeline.key) : 0)
		}
	case Timeline_Key_Here:
		if _, i := Timeline_Animator(s); i >= 0 do return node(i, fmt.tprintf("%s in the clips of %s", timelineOpLabel(.Key_Added), scene.nodes[i].name))
	case Timeline_View:
		if _, i := Timeline_Animator(s); i >= 0 && v.op == .Name_Typed {
			return node(i, fmt.tprintf("Rename a clip of %s", scene.nodes[i].name), key("timeline-name", i, s.timeline.clip))
		}
	// Painting tiles: a stroke (press to release) is one step
	case Tile_Brush:
		if hasSelection && v.phase != .Hover {
			info := node(selected, fmt.tprintf("Paint the tiles of %s", name), key("tiles", s.history.gesture + (v.phase == .Begin ? 1 : 0)))
			info.sticky = true
			return info
		}
	case Tile_Layer_Added:
		if hasSelection do return node(selected, fmt.tprintf("Add a tile layer to %s", name))
	case Tile_Layer_Reverted:
		if hasSelection do return node(selected, fmt.tprintf("Use the file's tiles in %s", name))
	case Aseprite_Layer_Toggled:
		if hasSelection do return node(selected, fmt.tprintf("Change the layers %s draws", name))
	case TileMap_Setting_Changed:
		if !hasSelection do break
		// Typing a frame merges into one step
		if v.field == .Frame do return node(selected, fmt.tprintf("Change the frame of %s", name), key("tilemap-frame", s.currentScene, selected))
		return node(selected, fmt.tprintf("Change %v of %s", v.field, name))
	case Audio_Field_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %v of %s", v.field, name), key("audio", v.field, s.currentScene, selected))
	case Audio_Flag_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %v of %s", v.flag, name))
	// A MusicPlayer's layers (music_layers_edit.odin): typing a name or dragging a volume merges
	case Music_Layer_Added:
		if hasSelection do return node(selected, fmt.tprintf("Add a layer to %s", name))
	case Music_Layer_Removed:
		if hasSelection do return node(selected, fmt.tprintf("Remove a layer of %s", name))
	case Music_Layer_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change a layer's %v of %s", v.field, name), key("music-layer", v.index, v.field, s.currentScene, selected))
	case Bus_Added:
		return {scope = .Project, label = "Add a bus"}
	case Bus_Removed:
		return {scope = .Project, label = "Remove a bus"}
	case Bus_Renamed:
		return {scope = .Project, label = "Rename a bus", mergeKey = key("bus-name", v.index)}
	case Bus_Volume_Changed:
		return {scope = .Project, label = "Change a bus's volume", mergeKey = key("bus-volume", v.index)}
	// Bus effects (bus_effects_edit.odin): a slider's drag merges
	case Bus_Effect_Added:
		return {scope = .Project, label = fmt.tprintf("Add a %v to a bus", v.kind)}
	case Bus_Effect_Removed:
		return {scope = .Project, label = "Remove a bus effect"}
	case Bus_Effect_Moved:
		return {scope = .Project, label = "Move a bus effect"}
	case Bus_Effect_Changed:
		return {scope = .Project, label = fmt.tprintf("Change a bus effect's %v", v.field), mergeKey = key("bus-effect", v.bus, v.index, v.field)}
	case Bus_Pan_Changed:
		return {scope = .Project, label = "Change a bus's pan", mergeKey = key("bus-pan", v.index)}
	case Bus_Mute_Toggled:
		return {scope = .Project, label = "Mute or unmute a bus"}
	case Component_Made_Unique:
		if hasSelection do return node(selected, fmt.tprintf("Make %s unique", name))
	case Component_Instance_Added:
		return {scope = .Scene, label = "Add an instance"}
	// Collision from sprite: traced shapes replace the body's earlier ones (collision_trace_edit.odin)
	case Collision_Traced:
		if hasSelection do return {scope = .Scene, label = fmt.tprintf("Make collision for %s from its sprite", name)}
	case Add_Node_Confirmed, Add_Node_Kind_Chosen, Add_Node_Type_Chosen:
		return {scope = .Scene, label = "Add node"}
	// More scripts on a node (node_scripts_edit.odin)
	case Node_Script_Added:
		if hasSelection && string(v) != "" do return node(selected, fmt.tprintf("Attach %s to %s", string(v), name))
	case Node_Script_Removed:
		if hasSelection do return node(selected, fmt.tprintf("Remove a script from %s", name))
	case Asset_Dropped:
		asset := s.assetDrag.asset
		if asset >= 0 && asset < len(s.project.assets) && s.project.assets[asset].kind == .LDtk do return {scope = .Scene, label = "Add level"}
		return {scope = .Scene, label = "Add sprite"}
	case Node_Command:
		if !hasSelection do break
		switch v.op {
		case .Toggle_Visible:  return {scope = .Scene, label = fmt.tprintf("Show or hide %s", many(s, name))}
		case .Reset_Position:  return {scope = .Scene, label = fmt.tprintf("Reset the position of %s", many(s, name))}
		case .Reset_Rotation:  return {scope = .Scene, label = fmt.tprintf("Reset the rotation of %s", many(s, name))}
		case .Reset_Scale:     return {scope = .Scene, label = fmt.tprintf("Reset the scale of %s", many(s, name))}
		case .Reset_Transform: return {scope = .Scene, label = fmt.tprintf("Reset the transform of %s", many(s, name))}
		case .Bring_Forward:   return {scope = .Scene, label = fmt.tprintf("Bring %s forward", many(s, name))}
		case .Send_Backward:   return {scope = .Scene, label = fmt.tprintf("Send %s backward", many(s, name))}
		case .Move_Up:         return {scope = .Scene, label = fmt.tprintf("Move %s up", name)}
		case .Move_Down:       return {scope = .Scene, label = fmt.tprintf("Move %s down", name)}
		case .Select_Children, .Select_Parent, .Copy_Path, .Expand_All, .Collapse_All:
		}
	case Paste_Here:
		return {scope = .Scene, label = "Paste"}
	case Align_Nodes:
		if hasSelection do return {scope = .Scene, label = fmt.tprintf("%s %s", AlignOp_Label(v.op), many(s, name))}
	case Tree_Drag_Dropped:
		if s.treeDrag.node >= 0 && s.treeDrag.node < len(scene.nodes) {
			return {scope = .Scene, label = fmt.tprintf("Move %s", scene.nodes[s.treeDrag.node].name)}
		}
	case Action:
		// Node shortcuts that the browser takes for its selected scene
		if routed, ok := Browser_RouteAction(s, v); ok {
			if SceneOp_EditsProject(routed.op) do return {scope = .Project, label = sceneOpLabel(s, routed)}
			return {}
		}
		#partial switch v {
		case .Toggle_Physics_Debug:
			return {scope = .Project, label = PhysicsDebug_Shown(s) ? "Hide collision shapes" : "Show collision shapes"}
		case .Nudge_Left, .Nudge_Right, .Nudge_Up, .Nudge_Down,
		     .Nudge_Left_Large, .Nudge_Right_Large, .Nudge_Up_Large, .Nudge_Down_Large:
			if !hasSelection do break
			if len(s.selection) > 1 {
				return {scope = .Scene, label = fmt.tprintf("Nudge %d nodes", len(s.selection)), mergeKey = key("nudge-many", s.currentScene)}
			}
			return node(selected, fmt.tprintf("Nudge %s", name), key("nudge", s.currentScene, selected))
		case .Delete_Node: if hasSelection do return {scope = .Scene, label = fmt.tprintf("Delete %s", many(s, name))}
		case .Cut_Node: if hasSelection do return {scope = .Scene, label = fmt.tprintf("Cut %s", many(s, name))}
		case .Duplicate_Node: if hasSelection do return {scope = .Scene, label = fmt.tprintf("Duplicate %s", many(s, name))}
		case .Paste_Node: return {scope = .Scene, label = "Paste"}
		case .Save_As_Component: if hasSelection do return {scope = .Scene, label = fmt.tprintf("Save %s as a component", name)}
		}
	}
	return {}
}

// "Delete scene Level2"
@(private="file")
sceneOpLabel :: proc(s: ^State, action: Scene_Action) -> string {
	name := action.scene >= 0 && action.scene < len(s.project.scenes) ? s.project.scenes[action.scene].name : ""
	switch action.op {
	case .New:       return "Add scene"
	case .Duplicate: return fmt.tprintf("Duplicate scene %s", name)
	case .Cut:       return fmt.tprintf("Cut scene %s", name)
	case .Paste:     return "Paste scene"
	case .Delete:    return fmt.tprintf("Delete scene %s", name)
	case .Set_Start: return fmt.tprintf("Make %s the start scene", name)
	case .Open, .Play, .Rename, .Copy:
	}
	return "Scene change"
}

// The node's name, or "3 nodes" for a multi-selection
@(private="file")
many :: proc(s: ^State, name: string) -> string {
	return len(s.selection) > 1 ? fmt.tprintf("%d nodes", len(s.selection)) : name
}

// A particle setting's label, lowercase, for undo step names
@(private="file")
particleLabel :: proc(name: string) -> string {
	for field in e.ParticleSettings_Fields() do if field.name == name do return strings.to_lower(field.label, context.temp_allocator)
	return name
}

@(private="file")
fieldLabel :: proc(field: NodeField) -> string {
	switch field {
	case .Position_X: return "position"
	case .Position_Y: return "position"
	case .Rotation:   return "rotation"
	case .Scale_X:    return "scale"
	case .Scale_Y:    return "scale"
	case .Layer:      return "layer"
	case .Z_Index:    return "z index"
	case .Font_Size:  return "font size"
	case .Zoom:       return "zoom"
	case .Friction:        return "friction"
	case .Restitution:     return "bounce"
	case .Density:         return "density"
	case .Gravity_Scale:   return "gravity scale"
	case .Linear_Damping:  return "damping"
	case .Angular_Damping: return "angular damping"
	case .Floor_Max_Angle: return "floor angle"
	case .Shape_Width:     return "width"
	case .Shape_Height:    return "height"
	case .Radius:          return "radius"
	case .Target_X, .Target_Y: return "ray target"
	case .Offset_X, .Offset_Y: return "joint offset"
	case .Lower:       return "lower limit"
	case .Upper:       return "upper limit"
	case .Motor_Speed: return "motor speed"
	case .Max_Motor:   return "motor strength"
	case .Hertz:       return "spring stiffness"
	case .Damping:     return "spring damping"
	case .Nine_Width, .Nine_Height: return "9-patch size"
	}
	return "property"
}

/*
Copies what an edit is about to change. Pass the result to `History_Commit` after applying the
message.

Returns:
- The snapshot, on the heap (`History_Commit` takes it and frees it): `update` keeps only a
  pointer in its frame
*/
History_Snapshot :: proc(s: ^State, info: EditInfo) -> ^EditSnapshot {
	scene := &s.project.scenes[s.currentScene]
	snap := new(EditSnapshot)
	snap.info = info
	snap.scene, snap.selection, snap.mode = s.currentScene, s.selectedNode, s.mode
	snap.info.label = strings.clone(info.label)
	switch info.scope {
	case .None:
	case .Node:
		if info.node >= 0 && info.node < len(scene.nodes) do snap.node = NodeDef_Clone(scene.nodes[info.node])
	case .Scene:
		snap.nodes = cloneNodes(scene.nodes[:])
	case .Project:
		snap.project = takeProjectSnapshot(s)
	case .Files:
		snap.info.ldtkFile = strings.clone(info.ldtkFile)
		// The document's texts as the editor has them (unsaved edits included)
		if doc := LDtkDoc_Get(s.project.rootPath, info.ldtkFile); doc != nil {
			for text, i in LDtkDoc_Texts(doc) do append(&snap.files, FileText{path = strings.clone(doc.files[i].path), before = strings.clone(text)})
		}
		if info.withProject {
			snap.project = takeProjectSnapshot(s)
			for &scene in s.project.scenes {
				if !Scene_IsComponent(&scene) || !Scene_ShowsLDtk(&scene, info.ldtkFile) do continue
				append(&snap.components, ComponentNodes{file = strings.clone(scene.component), before = cloneNodes(scene.nodes[:])})
			}
		}
	}
	return snap
}

/*
Records an edit, if it changed anything: compares the snapshot with the state after the message,
and pushes a command or merges it into the newest one. Takes ownership of the snapshot.

Inputs:
- s: The state after the message
- snap: From `History_Snapshot`, before the message (freed here)
- now: The time of the edit (for merging)

Everything big is on the heap or behind a pointer (the snapshot, the command, the project
snapshots): this frame was about 250 KB in debug builds, under `update` in every unit test, and a
Windows test thread has 1 MB of stack.
*/
History_Commit :: proc(s: ^State, snap: ^EditSnapshot, now: time.Tick) {
	defer free(snap)
	command := new(UndoCommand)
	defer free(command)
	command.label = snap.info.label
	command.scene = snap.scene
	command.selectionBefore, command.selectionAfter = snap.selection, s.selectedNode
	command.modeBefore, command.modeAfter = snap.mode, s.mode
	command.mergeKey, command.sticky = snap.info.mergeKey, snap.info.sticky
	command.started, command.last = now, now
	// A node or scene edit can't switch scenes, but be safe: compare against the scene it started
	// in (a project edit may have removed it, so it doesn't need it)
	if snap.info.scope != .Project && snap.scene >= len(s.project.scenes) {
		discardSnapshot(snap)
		return
	}
	scene := &s.project.scenes[min(snap.scene, len(s.project.scenes) - 1)]
	switch snap.info.scope {
	case .None:
		discardSnapshot(snap)
		return
	case .Node:
		index := snap.info.node
		if index < 0 || index >= len(scene.nodes) || NodeDef_Equal(snap.node, scene.nodes[index]) {
			discardSnapshot(snap)
			return
		}
		command.change = NodeChange{index, snap.node, NodeDef_Clone(scene.nodes[index])}
	case .Scene:
		if nodesEqual(snap.nodes[:], scene.nodes[:]) {
			discardSnapshot(snap)
			return
		}
		command.change = SceneChange{snap.nodes, cloneNodes(scene.nodes[:])}
	// The big changes are built in place (`command.change`), not copied in: see History_Push
	case .Project:
		after := takeProjectSnapshot(s)
		if projectSnapshotsEqual(snap.project, after) {
			destroyProjectSnapshot(after)
			discardSnapshot(snap)
			return
		}
		command.change = ProjectChange{before = snap.project, after = after}
		snap.project = nil
	case .Files:
		command.change = FileChange{ldtkFile = snap.info.ldtkFile}
		change := &command.change.(FileChange)
		snap.info.ldtkFile = ""
		doc := LDtkDoc_Get(s.project.rootPath, change.ldtkFile)
		// Files the edit made (a level saved apart, added or named again): from nothing ("")
		if doc != nil do for df in doc.files {
			had := false
			for f in snap.files do if f.path == df.path do had = true
			if !had do append(&change.files, fileStepMake(df.path, "", df.json.text))
		}
		for &f in snap.files {
			now := f.before
			// A file the edit dropped (its level removed, or saved in the project file again): to nothing
			if doc != nil {
				text, found := LDtkDoc_TextOf(doc, f.path)
				now = found ? text : ""
			}
			if now == f.before {
				delete(f.path)
				delete(f.before)
				continue
			}
			append(&change.files, fileStepMake(f.path, f.before, now))
			delete(f.path)
			delete(f.before)
		}
		delete(snap.files)
		snap.files = nil
		if snap.info.withProject {
			change.project.before = snap.project
			snap.project = nil
			change.project.after = takeProjectSnapshot(s)
			if projectSnapshotsEqual(change.project.before, change.project.after) {
				destroyProjectSnapshot(change.project.after)
				destroyProjectSnapshot(change.project.before)
				change.project = {}
			} else {
				change.hasProject = true
			}
		}
		// Components that followed the rename
		for &c in snap.components {
			scene := Project_FindComponentScene(&s.project, c.file)
			if scene == nil || nodesEqual(c.before[:], scene.nodes[:]) {
				delete(c.file)
				destroyNodes(&c.before)
				continue
			}
			c.after = cloneNodes(scene.nodes[:])
			append(&change.components, c)
		}
		delete(snap.components)
		snap.components = nil
		if len(change.files) == 0 && !FileChange_TouchesProject(change) {
			delete(change.files)
			delete(change.ldtkFile)
			delete(snap.info.label)
			return
		}
	}
	History_Push(&s.history, command, &s.settings, now)
}

/*
Adds a command to the history, or merges it into the newest command (see the merging rules at the
top of this file). Clears the redo stack. Takes ownership of `command`.
*/
History_Push :: proc(h: ^History, command: ^UndoCommand, settings: ^Settings, now: time.Tick) {
	// Pointers, not copies: an UndoCommand was about 25 KB, and copies of it in debug builds took
	// most of a Windows test thread's 1 MB stack (ldtk_edits_undo_and_redo overflowed it)
	h.version += 1
	if change, isFiles := &command.change.(FileChange); isFiles && !FileChange_TouchesProject(change) do h.fileVersion += 1
	if top, ok := mergeTarget(h, command, settings, now); ok {
		// Keep the top's "before"; take the new "after"
		switch &change in top.change {
		case NodeChange:
			NodeDef_Destroy(&change.after)
			new := &command.change.(NodeChange)
			change.after = new.after
			NodeDef_Destroy(&new.before)
		case SceneChange:
			destroyNodes(&change.after)
			new := &command.change.(SceneChange)
			change.after = new.after
			destroyNodes(&new.before)
		case ProjectChange:
			destroyProjectSnapshot(change.after)
			new := &command.change.(ProjectChange)
			change.after = new.after
			destroyProjectSnapshot(new.before)
		case FileChange:
			// Each file keeps the first "before", takes the newest "after"
			new := &command.change.(FileChange)
			for &f in new.files {
				merged := false
				for &old in change.files do if old.path == f.path {
					merged = true
					if old.whole && f.whole {
						delete(old.after)
						old.after = f.after
						delete(f.path)
						delete(f.before)
						continue
					}
					// Middles: the whole texts from the document's text now (the new step's "after"),
					// then the step again from the first "before" to it
					now, found := LDtkDoc_CachedText(f.path)
					newBefore, okNew := fileStepWhole(f, now)
					firstBefore, okOld := fileStepWhole(old, newBefore)
					if !found || !okNew || !okOld {
						// Not as the steps left it: kept apart
						merged = false
						continue
					}
					step := fileStepMake(f.path, firstBefore, now)
					fileStepDestroy(&old)
					old = step
					fileStepDestroy(&f)
				}
				if !merged do append(&change.files, f)
			}
			delete(new.files)
			delete(new.ldtkFile)
			// Each component keeps its first "before", takes the newest "after"
			for &c in new.components {
				merged := false
				for &old in change.components do if old.file == c.file {
					destroyNodes(&old.after)
					old.after = c.after
					destroyNodes(&c.before)
					delete(c.file)
					merged = true
				}
				if !merged do append(&change.components, c)
			}
			delete(new.components)
			if new.hasProject {
				if change.hasProject {
					destroyProjectSnapshot(change.project.after)
					change.project.after = new.project.after
					destroyProjectSnapshot(new.project.before)
				} else {
					change.hasProject = true
					change.project = new.project
				}
			}
		}
		top.last = now
		top.selectionAfter = command.selectionAfter
		top.modeAfter = command.modeAfter
		delete(command.label)
		return
	}
	clearCommands(&h.redo)
	append(&h.undo, command^)
	limit := max(settings.undoLimit, 1)
	for len(h.undo) > limit {
		destroyCommand(&h.undo[0])
		ordered_remove(&h.undo, 0)
	}
}

// The newest command, if `command` should merge into it
@(private="file")
mergeTarget :: proc(h: ^History, command: ^UndoCommand, settings: ^Settings, now: time.Tick) -> (^UndoCommand, bool) {
	if command.mergeKey == 0 || len(h.undo) == 0 || len(h.redo) > 0 do return nil, false
	top := &h.undo[len(h.undo) - 1]
	if top.mergeKey != command.mergeKey || top.scene != command.scene || top.sticky != command.sticky do return nil, false
	topNode, topIsNode := top.change.(NodeChange)
	newNode, newIsNode := command.change.(NodeChange)
	if topIsNode != newIsNode || (topIsNode && topNode.index != newNode.index) do return nil, false
	if command.sticky do return top, true
	ms :: proc(d: time.Duration) -> int { return int(time.duration_milliseconds(d)) }
	if ms(time.tick_diff(top.last, now)) >= settings.undoMergeMs do return nil, false
	if settings.undoGroupMaxMs > 0 && ms(time.tick_diff(top.started, now)) >= settings.undoGroupMaxMs do return nil, false
	return top, true
}

/*
Undoes the newest command: switches to the mode it was made in and its scene, and puts back its
"before" state and selection.

Returns:
- The command's label, and whether there was one to undo
*/
History_Undo :: proc(s: ^State) -> (string, bool) {
	return step(s, &s.history.undo, &s.history.redo, true)
}

/*
Redoes the most recently undone command.

Returns:
- The command's label, and whether there was one to redo
*/
History_Redo :: proc(s: ^State) -> (string, bool) {
	return step(s, &s.history.redo, &s.history.undo, false)
}

@(private="file")
step :: proc(s: ^State, from, to: ^[dynamic]UndoCommand, undo: bool) -> (string, bool) {
	if len(from) == 0 do return "", false
	command := pop(from)
	s.history.version += 1
	// The mode the step was made in (undo) or left (redo), as the step's scene shows
	Mode_Set(s, undo ? command.modeBefore : command.modeAfter)
	// Files written back: as they were (merged with outside changes when they don't touch), or the
	// step waits for the user's answer
	if change, isFiles := &command.change.(FileChange); isFiles {
		if !FileChange_TouchesProject(change) do s.history.fileVersion += 1
		if !History_RestoreFiles(s, change, undo, force = false) {
			append(from, command)
			s.level.conflict = {open = true, undo = undo}
			return fmt.tprintf("%s (waiting: %s changed outside the editor)", command.label, filepath.base(change.ldtkFile)), true
		}
		command.mergeKey = 0
		append(to, command)
		return command.label, true
	}
	// The scene list itself: restore it whole, then show the scene that was open
	if change, isProject := &command.change.(ProjectChange); isProject {
		snapshot := undo ? change.before : change.after
		// The selection stays when the step didn't change the open scene's tree (an animation
		// asset's edit: the Animation panel keeps showing it; a rename of a script: its nodes
		// changed, not which they are)
		openBefore := s.currentScene
		nodesBefore := s.currentScene < len(s.project.scenes) ? cloneNodes(s.project.scenes[s.currentScene].nodes[:]) : nil
		defer destroyNodes(&nodesBefore)
		restoreProjectSnapshot(s, snapshot)
		s.currentScene = clamp(snapshot.currentScene, 0, len(s.project.scenes) - 1)
		kept := undo ? command.selectionBefore : command.selectionAfter
		same := s.currentScene == openBefore && nodesSameTree(nodesBefore[:], s.project.scenes[s.currentScene].nodes[:])
		s.selectedNode = same && kept >= 0 && kept < len(s.project.scenes[s.currentScene].nodes) ? kept : -1
		clear(&s.selection)
		s.viewport.drag = {}
		s.treeDrag = {}
		CodeDrag_Clear(s)
		command.mergeKey = 0
		append(to, command)
		return command.label, true
	}
	if command.scene >= len(s.project.scenes) {
		destroyCommand(&command)
		return "", false
	}
	if s.currentScene != command.scene do openScene(s, command.scene)
	scene := &s.project.scenes[command.scene]
	switch &change in command.change {
	case NodeChange:
		if change.index < len(scene.nodes) {
			node := &scene.nodes[change.index]
			// The tree's open/closed state isn't part of the edit
			expanded := node.expanded
			NodeDef_Destroy(node)
			node^ = NodeDef_Clone(undo ? change.before : change.after)
			node.expanded = expanded
		}
	case SceneChange:
		destroyNodes(&scene.nodes)
		scene.nodes = cloneNodes((undo ? change.before : change.after)[:])
	case ProjectChange, FileChange:
		// Handled above
	}
	s.selectedNode = undo ? command.selectionBefore : command.selectionAfter
	if s.selectedNode >= len(scene.nodes) do s.selectedNode = -1
	// Only the primary node is remembered; the step selects just it
	clear(&s.selection)
	s.viewport.drag = {}
	s.treeDrag = {}
	CodeDrag_Clear(s)
	// A merge must not extend a command that was undone and redone
	command.mergeKey = 0
	append(to, command)
	return command.label, true
}

// The label of the next undo or redo, "" if there's none (for menus and tooltips)
History_NextLabel :: proc(h: ^History, redo: bool) -> string {
	stack := redo ? &h.redo : &h.undo
	return len(stack) > 0 ? stack[len(stack) - 1].label : ""
}

// Frees both stacks
History_Destroy :: proc(h: ^History) {
	clearCommands(&h.undo)
	clearCommands(&h.redo)
	delete(h.undo)
	delete(h.redo)
	h^ = {}
}

/*
Whether two nodes are the same, ignoring the editor-only `expanded` flag.
*/
NodeDef_Equal :: proc(a, b: NodeDef) -> bool {
	if a.name != b.name || a.kind != b.kind || a.parent != b.parent || a.position != b.position ||
	   a.rotation != b.rotation || a.scale != b.scale || a.layer != b.layer || a.visible != b.visible ||
	   a.processMode != b.processMode || a.blendMode != b.blendMode || a.zIndex != b.zIndex || a.ySort != b.ySort ||
	   a.groups != b.groups ||
	   a.texture != b.texture || a.text != b.text || a.fontSize != b.fontSize || a.color != b.color ||
	   a.centered != b.centered || a.zoom != b.zoom || a.autoplay != b.autoplay || !animationsEqual(a.animations[:], b.animations[:]) || a.animationSet != b.animationSet ||
	   a.asepriteLayers != b.asepriteLayers || a.pivotSlice != b.pivotSlice || a.nineSlice != b.nineSlice || a.nineSize != b.nineSize || a.region != b.region || a.slice != b.slice ||
	   len(a.items) != len(b.items) ||
	   a.script != b.script || len(a.props) != len(b.props) ||
	   !NodeScripts_Equal(a.moreScripts[:], b.moreScripts[:]) || a.customKind != b.customKind || !propsEqual(a.customProps[:], b.customProps[:]) ||
	   a.collisionLayer != b.collisionLayer || a.collisionMask != b.collisionMask || a.friction != b.friction ||
	   a.restitution != b.restitution || a.density != b.density || a.gravityScale != b.gravityScale ||
	   a.linearDamping != b.linearDamping || a.angularDamping != b.angularDamping || a.fixedRotation != b.fixedRotation ||
	   a.bullet != b.bullet || a.floorMaxAngle != b.floorMaxAngle || a.shape != b.shape || a.shapeSize != b.shapeSize ||
	   a.radius != b.radius || len(a.points) != len(b.points) || a.disabled != b.disabled || a.oneWay != b.oneWay || a.target != b.target ||
	   a.enabled != b.enabled || a.excludeParent != b.excludeParent ||
	   a.jointKind != b.jointKind || a.bodyA != b.bodyA || a.bodyB != b.bodyB || a.jointOffset != b.jointOffset ||
	   a.enableLimit != b.enableLimit || a.lower != b.lower || a.upper != b.upper || a.enableMotor != b.enableMotor ||
	   a.motorSpeed != b.motorSpeed || a.maxMotor != b.maxMotor || a.enableSpring != b.enableSpring ||
	   a.hertz != b.hertz || a.dampingRatio != b.dampingRatio || a.collideConnected != b.collideConnected ||
	   a.particles != b.particles || a.component != b.component ||
	   a.sound != b.sound || a.bus != b.bus || a.material != b.material || a.audio != b.audio || !MusicLayers_Equal(a.musicLayers, b.musicLayers) || !LDtkSettings_Equal(a.ldtk, b.ldtk) || !TileMapSettings_Equal(a.tilemap, b.tilemap) || !e.AnimatorSettings_Equal(a.animator, b.animator) || !UISettings_Equal(a.ui, b.ui) || a.light != b.light || a.nav != b.nav || !e.StateMachineSettings_Equal(a.stateMachine, b.stateMachine) || a.cameraTools != b.cameraTools || a.viewCamera != b.viewCamera || a.camera != b.camera || a.cameraTarget != b.cameraTarget || a.touch != b.touch || a.touchActions != b.touchActions ||
	   a.shader != b.shader || !propsEqual(a.shaderParams[:], b.shaderParams[:]) || a.effectScreenLayers != b.effectScreenLayers || a.line != b.line ||
	   a.boneLength != b.boneLength || !e.MeshData_Equal(a.mesh, b.mesh) || a.ik != b.ik || a.ikTip != b.ikTip || a.ikTarget != b.ikTarget ||
	   a.dialogue != b.dialogue || a.dialogueStart != b.dialogueStart || a.dialogueBox != b.dialogueBox {
		return false
	}
	for p, i in a.points do if p != b.points[i] do return false
	for item, i in a.items do if item != b.items[i] do return false
	for prop, i in a.props do if prop != b.props[i] do return false
	if len(a.listeners) != len(b.listeners) do return false
	for l, i in a.listeners do if l != b.listeners[i] do return false
	return true
}

// Whether two animation lists are the same
animationsEqual :: proc(a, b: []AnimationDef) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if !AnimationDef_Equal(x, b[i]) do return false
	return true
}

@(private="file")
nodesEqual :: proc(a, b: []NodeDef) -> bool {
	if len(a) != len(b) do return false
	for node, i in a do if !NodeDef_Equal(node, b[i]) do return false
	return true
}

@(private="file")
cloneNodes :: proc(nodes: []NodeDef) -> [dynamic]NodeDef {
	list := make([dynamic]NodeDef, 0, len(nodes))
	for node in nodes do append(&list, NodeDef_Clone(node))
	return list
}

@(private="file")
destroyNodes :: proc(nodes: ^[dynamic]NodeDef) {
	for &node in nodes do NodeDef_Destroy(&node)
	delete(nodes^)
	nodes^ = {}
}

@(private="file")
destroyCommand :: proc(command: ^UndoCommand) {
	delete(command.label)
	switch &change in command.change {
	case NodeChange:
		NodeDef_Destroy(&change.before)
		NodeDef_Destroy(&change.after)
	case SceneChange:
		destroyNodes(&change.before)
		destroyNodes(&change.after)
	case ProjectChange:
		destroyProjectSnapshot(change.before)
		destroyProjectSnapshot(change.after)
	case FileChange:
		for &f in change.files do fileStepDestroy(&f)
		delete(change.files)
		delete(change.ldtkFile)
		if change.hasProject {
			destroyProjectSnapshot(change.project.before)
			destroyProjectSnapshot(change.project.after)
		}
		for &c in change.components {
			delete(c.file)
			destroyNodes(&c.before)
			destroyNodes(&c.after)
		}
		delete(change.components)
	}
}

@(private="file")
clearCommands :: proc(stack: ^[dynamic]UndoCommand) {
	for &command in stack do destroyCommand(&command)
	clear(stack)
}

@(private="file")
discardSnapshot :: proc(snap: ^EditSnapshot) {
	delete(snap.info.label)
	if snap.info.scope == .Node do NodeDef_Destroy(&snap.node)
	if snap.info.scope == .Scene do destroyNodes(&snap.nodes)
	destroyProjectSnapshot(snap.project)
	snap.project = nil
	delete(snap.info.ldtkFile)
	for f in snap.files {
		delete(f.path)
		delete(f.before)
		delete(f.after)
	}
	delete(snap.files)
	for &c in snap.components {
		delete(c.file)
		destroyNodes(&c.before)
	}
	delete(snap.components)
}

// The project's scenes and settings, copied (owned, on the heap: `destroyProjectSnapshot`)
@(private="file")
takeProjectSnapshot :: proc(s: ^State) -> ^ProjectSnapshot {
	p := &s.project
	snapshot := new(ProjectSnapshot)
	snapshot^ = {
		name = strings.clone(p.name),
		startScene = strings.clone(p.startScene),
		locale = strings.clone(p.locale),
		uiTheme = strings.clone(p.uiTheme),
		transition = p.transition,
		loadingScene = strings.clone(p.loadingScene),
		icon = strings.clone(p.icon),
		gameSize = p.gameSize,
		scaleMode = p.scaleMode,
		renderer = p.renderer,
		textureFilter = p.textureFilter,
		background = p.background,
		exports = p.exports,
		physics = p.physics,
		window = p.window,
		grid = p.grid,
		audioOutput = p.audioOutput,
		currentScene = s.currentScene,
	}
	// Scenes only: components are assets (made and removed with their files, like data resources)
	for &scene in p.scenes do if !Scene_IsComponent(&scene) do append(&snapshot.scenes, SceneDef_Clone(scene))
	for g in p.globals do append(&snapshot.globals, GlobalDef_Clone(g))
	for d in p.data do append(&snapshot.data, DataDef_Clone(d))
	for set in p.animationSets do append(&snapshot.animationSets, AnimationSetDef_Clone(set))
	for t in p.themes do append(&snapshot.themes, ThemeDef_Clone(t))
	for d in p.dialogues do append(&snapshot.dialogues, DialogueDef_Clone(d))
	for m in p.materials do append(&snapshot.materials, MaterialDef_Clone(m))
	for a in p.actions do append(&snapshot.actions, ActionDef_Clone(a))
	for b in p.buses do append(&snapshot.buses, BusDef_Clone(b))
	snapshot.steam = p.steam
	snapshot.achievements = Achievements_Clone(p.achievements[:])
	snapshot.players = PlayerSettings_Clone(p.players)
	return snapshot
}

@(private="file")
restoreProjectSnapshot :: proc(s: ^State, snapshot: ^ProjectSnapshot) {
	p := &s.project
	delete(p.name)
	delete(p.startScene)
	delete(p.locale)
	delete(p.icon)
	// The scenes come back; the components stay as they are, after them
	components := make([dynamic]SceneDef, context.temp_allocator)
	for &scene in p.scenes {
		if Scene_IsComponent(&scene) do append(&components, scene)
		else do SceneDef_Destroy(&scene)
	}
	clear(&p.scenes)
	p.name = strings.clone(snapshot.name)
	p.startScene = strings.clone(snapshot.startScene)
	p.locale = strings.clone(snapshot.locale)
	delete(p.uiTheme)
	p.uiTheme = strings.clone(snapshot.uiTheme)
	p.transition = snapshot.transition
	delete(p.loadingScene)
	p.loadingScene = strings.clone(snapshot.loadingScene)
	p.icon = strings.clone(snapshot.icon)
	p.gameSize, p.scaleMode, p.background = snapshot.gameSize, snapshot.scaleMode, snapshot.background
	p.renderer = snapshot.renderer
	p.textureFilter = snapshot.textureFilter
	p.exports = snapshot.exports
	p.physics = snapshot.physics
	p.window = snapshot.window
	p.grid = snapshot.grid
	p.audioOutput = snapshot.audioOutput
	for &g in p.globals do GlobalDef_Destroy(&g)
	clear(&p.globals)
	for g in snapshot.globals do append(&p.globals, GlobalDef_Clone(g))
	for &a in p.actions do ActionDef_Destroy(&a)
	clear(&p.actions)
	for a in snapshot.actions do append(&p.actions, ActionDef_Clone(a))
	for b in p.buses do delete(b.name)
	clear(&p.buses)
	for b in snapshot.buses do append(&p.buses, BusDef_Clone(b))
	p.steam = snapshot.steam
	Achievements_Destroy(&p.achievements)
	p.achievements = Achievements_Clone(snapshot.achievements[:])
	delete(p.players.joinAction)
	p.players = PlayerSettings_Clone(snapshot.players)
	// Data values by file: resources made or removed since (files, not undoable) stay as they are
	for d in snapshot.data {
		i := Project_FindData(p, d.path)
		if i < 0 do continue
		DataDef_Destroy(&p.data[i])
		p.data[i] = DataDef_Clone(d)
	}
	// Animation assets by file, the same way; the ones an undoable step made (the sprite sheet
	// slicer's: `stepMade`) come and go with it, their asset entries too
	#reverse for &set, i in p.animationSets {
		if !set.stepMade do continue
		kept := false
		for had in snapshot.animationSets do if had.path == set.path do kept = true
		if kept do continue
		for asset, a in p.assets do if asset.path == set.path {
			delete(asset.path)
			ordered_remove(&p.assets, a)
			break
		}
		AnimationSetDef_Destroy(&set)
		ordered_remove(&p.animationSets, i)
	}
	for set in snapshot.animationSets {
		i := Project_FindAnimationSet(p, set.path)
		if i < 0 {
			if set.stepMade {
				append(&p.animationSets, AnimationSetDef_Clone(set))
				append(&p.assets, AssetDef{path = strings.clone(set.path), kind = .Animation})
			}
			continue
		}
		AnimationSetDef_Destroy(&p.animationSets[i])
		p.animationSets[i] = AnimationSetDef_Clone(set)
	}
	// Dialogues by file, the same way
	for d in snapshot.dialogues {
		i := Project_FindDialogue(p, d.path)
		if i < 0 do continue
		DialogueDef_Destroy(&p.dialogues[i])
		p.dialogues[i] = DialogueDef_Clone(d)
	}
	// Themes by file, the same way
	for t in snapshot.themes {
		i := Project_FindTheme(p, t.path)
		if i < 0 do continue
		ThemeDef_Destroy(&p.themes[i])
		p.themes[i] = ThemeDef_Clone(t)
	}
	// And materials
	for m in snapshot.materials {
		i := Project_FindMaterial(p, m.path)
		if i < 0 do continue
		MaterialDef_Destroy(&p.materials[i])
		p.materials[i] = MaterialDef_Clone(m)
	}
	for scene in snapshot.scenes do append(&p.scenes, SceneDef_Clone(scene))
	append(&p.scenes, ..components[:])
}

/*
A component's SceneDef was removed from the project's list (its asset removed): steps that edit
it go, and steps for the documents after it follow their new index.
*/
// Drops the undo and redo steps of one scene (its contents were replaced: a component reloaded
// from its file), keeping the others' indices
History_DropScene :: proc(h: ^History, index: int) {
	drop :: proc(list: ^[dynamic]UndoCommand, index: int) {
		#reverse for &command, i in list {
			if _, isProject := command.change.(ProjectChange); isProject do continue
			if command.scene == index {
				destroyCommand(&command)
				ordered_remove(list, i)
			}
		}
	}
	drop(&h.undo, index)
	drop(&h.redo, index)
	h.version += 1
}

History_SceneRemoved :: proc(h: ^History, index: int) {
	fix :: proc(list: ^[dynamic]UndoCommand, index: int) {
		#reverse for &command, i in list {
			if _, isProject := command.change.(ProjectChange); isProject do continue
			if command.scene == index {
				destroyCommand(&command)
				ordered_remove(list, i)
			} else if command.scene > index {
				command.scene -= 1
			}
		}
	}
	fix(&h.undo, index)
	fix(&h.redo, index)
}

// Frees a snapshot from `takeProjectSnapshot` and what it holds (nil: nothing)
@(private="file")
destroyProjectSnapshot :: proc(snapshot: ^ProjectSnapshot) {
	if snapshot == nil do return
	delete(snapshot.name)
	delete(snapshot.startScene)
	delete(snapshot.locale)
	delete(snapshot.icon)
	for &scene in snapshot.scenes do SceneDef_Destroy(&scene)
	delete(snapshot.scenes)
	for &g in snapshot.globals do GlobalDef_Destroy(&g)
	delete(snapshot.globals)
	for &d in snapshot.data do DataDef_Destroy(&d)
	delete(snapshot.data)
	for &set in snapshot.animationSets do AnimationSetDef_Destroy(&set)
	delete(snapshot.animationSets)
	for &t in snapshot.themes do ThemeDef_Destroy(&t)
	delete(snapshot.themes)
	for &d in snapshot.dialogues do DialogueDef_Destroy(&d)
	delete(snapshot.dialogues)
	for &m in snapshot.materials do MaterialDef_Destroy(&m)
	delete(snapshot.materials)
	delete(snapshot.uiTheme)
	delete(snapshot.loadingScene)
	for &a in snapshot.actions do ActionDef_Destroy(&a)
	delete(snapshot.actions)
	for b in snapshot.buses do delete(b.name)
	delete(snapshot.buses)
	Achievements_Destroy(&snapshot.achievements)
	delete(snapshot.players.joinAction)
	free(snapshot)
}

@(private="file")
projectSnapshotsEqual :: proc(a, b: ^ProjectSnapshot) -> bool {
	if a.name != b.name || a.startScene != b.startScene || a.locale != b.locale || a.icon != b.icon || a.gameSize != b.gameSize || a.scaleMode != b.scaleMode ||
	   a.renderer != b.renderer || a.textureFilter != b.textureFilter || a.background != b.background || a.exports != b.exports || a.physics != b.physics || a.window != b.window || a.grid != b.grid || a.audioOutput != b.audioOutput || len(a.scenes) != len(b.scenes) {
		return false
	}
	for scene, i in a.scenes {
		if scene.name != b.scenes[i].name || scene.settings != b.scenes[i].settings || !nodesEqual(scene.nodes[:], b.scenes[i].nodes[:]) do return false
	}
	if len(a.globals) != len(b.globals) || len(a.data) != len(b.data) || !actionsEqual(a.actions[:], b.actions[:]) || !busesEqual(a.buses[:], b.buses[:]) do return false
	for g, i in a.globals do if g.script != b.globals[i].script || !propsEqual(g.props[:], b.globals[i].props[:]) do return false
	for d, i in a.data do if d.path != b.data[i].path || d.type != b.data[i].type || !propsEqual(d.values[:], b.data[i].values[:]) do return false
	if len(a.animationSets) != len(b.animationSets) do return false
	for set, i in a.animationSets do if !AnimationSetDef_Equal(set, b.animationSets[i]) do return false
	if a.uiTheme != b.uiTheme || len(a.themes) != len(b.themes) || a.transition != b.transition || a.loadingScene != b.loadingScene do return false
	if a.steam != b.steam || !Achievements_Equal(a.achievements[:], b.achievements[:]) || a.players != b.players do return false
	for t, i in a.themes do if !ThemeDef_Equal(t, b.themes[i]) do return false
	if len(a.dialogues) != len(b.dialogues) do return false
	for d, i in a.dialogues do if d.path != b.dialogues[i].path || !e.DialogueData_Equal(d.data, b.dialogues[i].data) do return false
	if len(a.materials) != len(b.materials) do return false
	for m, i in a.materials do if !MaterialDef_Equal(m, b.materials[i]) do return false
	return true
}

// What a Timeline edit does, for undo's label ("Add a key")
@(private="file")
timelineOpLabel :: proc(op: TimelineOp) -> string {
	switch op {
	case .Clip_Added: return "Add a clip"
	case .Clip_Removed: return "Remove a clip"
	case .Clip_Renamed: return "Rename a clip"
	case .Clip_Length: return "Change a clip's length"
	case .Clip_Loop: return "Change a clip's looping"
	case .Clip_Autoplay, .Autoplay_Named: return "Change the clip it starts with"
	case .Speed: return "Change the speed"
	case .Track_Added: return "Add a track"
	case .Track_Removed: return "Remove a track"
	case .Track_Step: return "Change a track's stepping"
	case .Key_Added: return "Add a key"
	case .Keys_Recorded: return "Key every track"
	case .Key_Removed: return "Remove a key"
	case .Key_Time, .Key_Moved: return "Move a key"
	case .Key_Value: return "Change a key's value"
	case .Key_Ease: return "Change a key's curve"
	}
	return "Change"
}

// Whether two node lists are the same tree: the same nodes (names) under the same parents
@(private="file")
nodesSameTree :: proc(a, b: []NodeDef) -> bool {
	if len(a) != len(b) do return false
	for n, i in a do if n.name != b[i].name || n.parent != b[i].parent do return false
	return true
}

/*
Puts a file step's texts back in the LDtk document (in memory: saving writes them): "before" for
an undo, "after" for a redo. A document changed since the step (LDtk saved the file, read again or
merged) is merged when that change and the step's don't touch (`History_MergeText`); otherwise
nothing changes unless `force` (the user chose to overwrite). The project's snapshot is restored
with them.

Returns:
- Whether it was put back (false: a conflict, nothing changed)
*/
History_RestoreFiles :: proc(s: ^State, change: ^FileChange, undo, force: bool) -> bool {
	targets := make([]string, len(change.files), context.temp_allocator)
	doc := LDtkDoc_Get(s.project.rootPath, change.ldtkFile)
	for f, i in change.files {
		current := ""
		found := false
		if doc != nil do current, found = LDtkDoc_TextOf(doc, f.path)
		if !found {
			// The document isn't there (only whole steps can be put back without it)
			if !f.whole do return false
			targets[i] = undo ? f.before : f.after
			continue
		}
		target, ok := fileStepTarget(f, current, undo, force)
		if !ok do return false
		targets[i] = target
	}
	if doc != nil {
		// By path: a step may bring a level file back or drop one ("": not in the document then)
		texts := make(map[string]string, len(doc.files) + len(change.files), context.temp_allocator)
		for df in doc.files do texts[df.path] = df.json.text
		for f, i in change.files {
			if targets[i] == "" do delete_key(&texts, f.path)
			else do texts[f.path] = targets[i]
		}
		if problem := LDtkDoc_SetTextsByPath(doc, texts); problem != "" do logLine(s, .Error, strings.clone(problem))
	}
	if change.hasProject do restoreProjectSnapshot(s, undo ? change.project.before : change.project.after)
	for &c in change.components {
		scene := Project_FindComponentScene(&s.project, c.file)
		if scene == nil do continue
		destroyNodes(&scene.nodes)
		scene.nodes = cloneNodes((undo ? c.before : c.after)[:])
	}
	return true
}

/*
Whether a file step changed the project too (a rename the scenes or components followed): it then
makes the project modified, as other steps do.
*/
FileChange_TouchesProject :: proc(change: ^FileChange) -> bool {
	return change.hasProject || len(change.components) > 0
}

// A component's SceneDef by its file (nil: none)
Project_FindComponentScene :: proc(p: ^Project, file: string) -> ^SceneDef {
	for &scene in p.scenes do if Scene_IsComponent(&scene) && scene.component == file do return &scene
	return nil
}

// Whether a scene (or component) has an LDtkLevel node showing an LDtk file
Scene_ShowsLDtk :: proc(scene: ^SceneDef, file: string) -> bool {
	for &node in scene.nodes do if node.kind == .LDtkLevel && node.ldtk.file == file do return true
	return false
}

/*
A text changed two ways from `base`: `ours` (the step being undone or redone) and `theirs` (the
file as it is now, changed outside). When the two changes are in separate places, `theirs` with
ours applied too; when they touch, nothing (the user decides).

Returns:
- The merged text (temp allocated), and whether it merged
*/
History_MergeText :: proc(base, ours, theirs: string) -> (string, bool) {
	prefix :: proc(a, b: string) -> int {
		n := min(len(a), len(b))
		for i in 0 ..< n do if a[i] != b[i] do return i
		return n
	}
	suffix :: proc(a, b: string, from: int) -> int {
		n := min(len(a), len(b)) - from
		for i in 0 ..< n do if a[len(a) - 1 - i] != b[len(b) - 1 - i] do return i
		return max(n, 0)
	}
	p1 := prefix(base, ours)
	s1 := suffix(base, ours, p1)
	p2 := prefix(base, theirs)
	s2 := suffix(base, theirs, p2)
	ourStart, ourEnd := p1, len(base) - s1
	theirStart, theirEnd := p2, len(base) - s2
	replacement := ours[p1:len(ours) - s1]
	merged: string
	switch {
	case ourEnd <= theirStart:
		merged = strings.concatenate({theirs[:ourStart], replacement, theirs[ourEnd:]}, context.temp_allocator)
	case theirEnd <= ourStart:
		d := len(theirs) - len(base)
		merged = strings.concatenate({theirs[:ourStart + d], replacement, theirs[ourEnd + d:]}, context.temp_allocator)
	case:
		return "", false
	}
	// Still JSON (LDtk's files): a merge that isn't is a conflict
	if check, problem := Json_Parse(merged, context.temp_allocator); problem != "" {
		return "", false
	} else do Json_Destroy(&check)
	return merged, true
}

/*
Answers a file step that waited (its files changed outside the editor): overwrite them with the
step's texts, or keep the files as they are (the step is dropped, and the history before it: it
can't be undone over the outside change). A big file's step can't overwrite a file changed where
its hunks are (`FileText`): the file is kept then.
*/
History_ResolveConflict :: proc(s: ^State, overwrite: bool) -> string {
	undo := s.level.conflict.undo
	s.level.conflict = {}
	from, to := undo ? &s.history.undo : &s.history.redo, undo ? &s.history.redo : &s.history.undo
	if len(from) == 0 do return ""
	command := pop(from)
	change, isFiles := &command.change.(FileChange)
	if !isFiles {
		append(from, command)
		return ""
	}
	s.history.version += 1
	if !FileChange_TouchesProject(change) do s.history.fileVersion += 1
	// A big file's step keeps only its hunks: over a file changed where they are, it can't
	// overwrite, and the file is kept as it is
	if overwrite && History_RestoreFiles(s, change, undo, force = true) {
		command.mergeKey = 0
		append(to, command)
		return fmt.tprintf("%s: %s", undo ? "Undo" : "Redo", command.label)
	}
	label := fmt.tprintf("Kept %s as it is: \"%s\" and the steps before it can't be undone over its change", filepath.base(change.ldtkFile), command.label)
	if overwrite do label = fmt.tprintf("Couldn't overwrite %s (a big file's step keeps only what it changed, and the file changed there): kept it as it is, and \"%s\" and the steps before it can't be undone", filepath.base(change.ldtkFile), command.label)
	destroyCommand(&command)
	// The older steps of that file would undo over it too
	if undo do clearCommands(from)
	return label
}

// What each LDtk edit is called in the history
LDTK_EDIT_LABELS := [LDtkEditOp]string{
	.Layer_Name = "Rename a layer", .Layer_Opacity = "Change a layer's opacity", .Layer_Parallax_X = "Change a layer's parallax",
	.Layer_Parallax_Y = "Change a layer's parallax", .Layer_Parallax_Scaling = "Change a layer's parallax scaling",
	.Layer_Grid_Size = "Change a layer's grid size", .Layer_Move = "Move a layer", .Layer_Visible = "Show or hide a layer",
	.Entity_Name = "Rename an entity type", .Entity_Width = "Change an entity type's size", .Entity_Height = "Change an entity type's size",
	.Entity_Color = "Change an entity type's color", .Entity_Pivot_X = "Change an entity type's pivot", .Entity_Pivot_Y = "Change an entity type's pivot",
	.Field_Name = "Rename a field", .Field_Default = "Change a field's default",
	.Entity_X = "Move an entity", .Entity_Y = "Move an entity", .Entity_Moved = "Move an entity", .Entity_Field = "Change an entity's field",
	.Entity_Ref = "Change an entity reference", .Level_Field = "Change a level's field",
	.Entity_Added = "Place an entity", .Entity_Removed = "Remove an entity", .Entity_Resized = "Resize an entity",
	.Entity_Duplicated = "Duplicate an entity", .Entity_Point = "Change an entity's point",
	.Level_X = "Move a level in the world", .Level_Y = "Move a level in the world", .Level_Moved = "Move a level in the world",
	.IntGrid_Name = "Rename an IntGrid value", .IntGrid_Color = "Change an IntGrid value's color",
	.Enum_Name = "Rename an enum", .Enum_Value_Name = "Rename an enum value", .Enum_Value_Color = "Change an enum value's color",
	.Enum_Value_Added = "Add an enum value", .Enum_Added = "Add an enum",
	.World_Layout = "Change the world's layout", .World_Grid_Width = "Change the world's grid", .World_Grid_Height = "Change the world's grid",
	.Def_Set = "Change a definition", .Def_Added = "Add a definition", .Def_Removed = "Remove a definition",
	.Def_Duplicated = "Duplicate a definition", .Def_Moved = "Move a definition", .Field_Converted = "Convert a field's type",
	.IntGrid_Value_Added = "Add an IntGrid value", .IntGrid_Value_Removed = "Remove an IntGrid value", .IntGrid_Value_Moved = "Move an IntGrid value",
	.IntGrid_Value_Tile = "Change an IntGrid value's tile", .IntGrid_Group_Added = "Add an IntGrid group", .IntGrid_Group_Removed = "Remove an IntGrid group",
	.IntGrid_Group_Set = "Change an IntGrid group", .IntGrid_Group_Moved = "Move an IntGrid group",
	.Enum_Value_Removed = "Remove an enum value", .Enum_Value_Moved = "Move an enum value", .Enum_Value_Tile = "Change an enum value's icon",
	.Enum_Import = "Import external enums", .Enum_Sync = "Sync external enums", .Enum_External_Removed = "Remove external enums",
	.Tileset_Tag = "Tag tiles", .Tileset_Custom_Data = "Change tiles' custom data",
	.Rule_Group_Added = "Add a rule group", .Rule_Group_Removed = "Remove a rule group", .Rule_Group_Duplicated = "Duplicate a rule group",
	.Rule_Group_Moved = "Move a rule group", .Rule_Group_Set = "Change a rule group", .Rule_Group_Here = "Turn an optional rule group on or off in a level",
	.Rule_Group_Remapped = "Duplicate and remap a rule group", .Rule_Group_Assistant = "Make rules with the Assistant",
	.Rule_Added = "Add a rule", .Rule_Removed = "Remove a rule", .Rule_Duplicated = "Duplicate a rule", .Rule_Moved = "Move a rule",
	.Rule_Set = "Change a rule", .Rule_Pattern = "Change a rule's pattern", .Rule_Tiles = "Change a rule's tiles", .Rule_Pasted = "Paste rules",
	.Rule_Seed = "Randomize a layer's rules", .Rule_Tileset_Here = "Change a layer's tileset in a level",
	.Level_Added = "Add a level", .Level_Removed = "Delete a level", .Level_Duplicated = "Duplicate a level",
	.Level_Set = "Change a level", .Level_Depth = "Change a level's depth", .Level_Resized = "Resize a level",
	.Level_Sorted = "Move a level in its world's order", .Level_World_Moved = "Move a level to another world",
	.World_Added = "Add a world", .World_Removed = "Delete a world", .World_Set = "Change a world",
	.Project_Set = "Change the LDtk project's settings", .Project_Flag = "Change an LDtk project option",
	.Project_Command = "Change the LDtk project's commands",
	.Field_Value = "Change a field's value",
}

/*
An LDtk edit's undo step: its files (`.Files`), a label, and a merge key for edits typed or
stepped (one step per field while typing); renames of layers and entity types also hold the
project (the scenes' LDtkLevel nodes follow them).
*/
LDtkEdit_Info :: proc(edit: LDtk_Edit) -> EditInfo {
	info := EditInfo{scope = .Files, ldtkFile = edit.file, label = fmt.tprintf("%s in %s", LDTK_EDIT_LABELS[edit.op], filepath.base(edit.file))}
	#partial switch edit.op {
	case .Layer_Move, .Layer_Visible, .Layer_Parallax_Scaling, .Entity_Moved, .Level_Moved, .Entity_Ref, .Enum_Value_Added, .Enum_Added, .World_Layout,
	     .Entity_Added, .Entity_Removed, .Entity_Resized, .Entity_Duplicated, .Entity_Point,
	     .Def_Added, .Def_Removed, .Def_Duplicated, .Def_Moved, .Field_Converted, .IntGrid_Value_Added, .IntGrid_Value_Removed, .IntGrid_Value_Moved,
	     .IntGrid_Group_Added, .IntGrid_Group_Removed, .IntGrid_Group_Moved, .Enum_Value_Removed, .Enum_Value_Moved, .Enum_Import, .Enum_Sync,
	     .Enum_External_Removed, .Tileset_Tag,
	     .Rule_Group_Added, .Rule_Group_Removed, .Rule_Group_Duplicated, .Rule_Group_Moved, .Rule_Group_Here, .Rule_Group_Remapped,
	     .Rule_Group_Assistant, .Rule_Added, .Rule_Removed, .Rule_Duplicated, .Rule_Moved, .Rule_Pattern, .Rule_Tiles, .Rule_Pasted,
	     .Rule_Seed, .Rule_Tileset_Here,
	     .Level_Added, .Level_Removed, .Level_Duplicated, .Level_Depth, .Level_Resized, .Level_Sorted, .Level_World_Moved,
	     .World_Added, .World_Removed, .Project_Flag:
	case .Field_Value:
		// Typing a value merges (per item); adding, removing, moving don't
		if edit.key == "" || edit.key == "set" do info.mergeKey = hash.fnv64a(transmute([]byte)fmt.tprint("ldtk", edit.op, edit.file, edit.entity, edit.level, edit.field, edit.index))
	case .Level_Set, .World_Set, .Project_Set, .Project_Command:
		// Typed text merges (a name, a number); toggles and choices don't
		switch edit.key {
		case "identifier", "worldDepth", "bgColor", "defaultLevelWidth", "defaultLevelHeight", "levelNamePattern", "pngFilePattern",
		     "defaultGridSize", "defaultEntityWidth", "defaultEntityHeight", "bgColor_project", "defaultLevelBgColor", "backupLimit",
		     "backupRelPath", "tutorialDesc", "command", "defaultPivot":
			info.mergeKey = hash.fnv64a(transmute([]byte)fmt.tprint("ldtk", edit.op, edit.file, edit.world, edit.level, edit.index, edit.key))
		}
	case .Rule_Set, .Rule_Group_Set:
		// Typed and stepped values merge (one step a field while typing); toggles and choices don't
		merges := false
		if edit.op == .Rule_Group_Set do merges = edit.key == "name" || edit.key == "color"
		else if m := LDtkRules_Member(edit.key); m != nil do merges = m.type == .Int || m.type == .Float
		if merges do info.mergeKey = hash.fnv64a(transmute([]byte)fmt.tprint("ldtk", edit.op, edit.file, edit.def, edit.field, edit.index, edit.key))
	case:
		info.mergeKey = hash.fnv64a(transmute([]byte)fmt.tprint("ldtk", edit.op, edit.file, edit.world, edit.def, edit.field, edit.index, edit.level, edit.entity, edit.kind, edit.key))
	}
	if edit.op == .Def_Set do info.label = fmt.tprintf("%s in %s", LDtkDefs_SetLabel(edit), filepath.base(edit.file))
	if edit.op == .Rule_Set do info.label = fmt.tprintf("%s in %s", LDtkRules_SetLabel(edit), filepath.base(edit.file))
	// Renames scenes follow (their LDtkLevel nodes name layers and entity types)
	// Level renames (asked, automatic names, a project's identifier style) are followed by scenes too
	#partial switch edit.op {
	case .Layer_Name, .Entity_Name, .Level_Added, .Level_Removed, .Level_Duplicated, .Level_Set, .Level_Sorted, .Level_World_Moved,
	     .Level_X, .Level_Y, .Level_Moved, .World_Layout, .World_Grid_Width, .World_Grid_Height, .World_Added, .World_Removed,
	     .World_Set, .Project_Set, .Project_Flag:
		info.withProject = true
	}
	return info
}
