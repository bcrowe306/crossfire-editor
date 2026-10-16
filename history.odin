package editor

import "core:fmt"
import "core:hash"
import "core:strings"
import "core:time"

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
}

UndoCommand :: struct {
	// "Rename Spaceship" (owned)
	label: string,
	scene: int,
	selectionBefore: int,
	selectionAfter: int,
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
}

// What a message edits, from `History_Classify`
EditInfo :: struct {
	scope: EditScope,
	// The node a `.Node` edit changes
	node: int,
	label: string,
	mergeKey: u64,
	sticky: bool,
}

// The state an edit started from, taken before the message is applied
EditSnapshot :: struct {
	info: EditInfo,
	scene: int,
	selection: int,
	node: NodeDef,
	nodes: [dynamic]NodeDef,
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

	#partial switch v in m {
	case Node_Renamed:
		if hasSelection do return node(selected, fmt.tprintf("Rename %s", name), key("rename", s.currentScene, selected))
	case Node_Visibility_Changed:
		if hasSelection do return node(selected, fmt.tprintf("%s %s", bool(v) ? "Show" : "Hide", name))
	case Node_Field_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %s of %s", fieldLabel(v.field), name), key("field", v.field, s.currentScene, selected))
	case Node_Text_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %v of %s", v.field, name), key("text", v.field, s.currentScene, selected))
	case Node_Flag_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %v of %s", v.flag, name))
	case Viewport_Drag_Move:
		drag := s.viewport.drag
		if drag.mode == .None || drag.mode == .Pan || drag.node < 0 || drag.node >= len(scene.nodes) do break
		info := node(drag.node, fmt.tprintf("%v %s", drag.mode, scene.nodes[drag.node].name), key("drag", s.history.gesture))
		info.sticky = true
		return info
	case Add_Node_Confirmed, Add_Node_Kind_Chosen:
		return {scope = .Scene, label = "Add node"}
	case Tree_Drag_Dropped:
		if s.treeDrag.node >= 0 && s.treeDrag.node < len(scene.nodes) {
			return {scope = .Scene, label = fmt.tprintf("Move %s", scene.nodes[s.treeDrag.node].name)}
		}
	case Action:
		#partial switch v {
		case .Nudge_Left, .Nudge_Right, .Nudge_Up, .Nudge_Down,
		     .Nudge_Left_Large, .Nudge_Right_Large, .Nudge_Up_Large, .Nudge_Down_Large:
			if hasSelection do return node(selected, fmt.tprintf("Nudge %s", name), key("nudge", s.currentScene, selected))
		case .Delete_Node: if hasSelection do return {scope = .Scene, label = fmt.tprintf("Delete %s", name)}
		case .Cut_Node: if hasSelection do return {scope = .Scene, label = fmt.tprintf("Cut %s", name)}
		case .Duplicate_Node: if hasSelection do return {scope = .Scene, label = fmt.tprintf("Duplicate %s", name)}
		case .Paste_Node: return {scope = .Scene, label = "Paste"}
		}
	}
	return {}
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
	case .Font_Size:  return "font size"
	case .Zoom:       return "zoom"
	case .Columns:    return "columns"
	case .Rows:       return "rows"
	case .FPS:        return "FPS"
	}
	return "property"
}

/*
Copies what an edit is about to change. Pass the result to `History_Commit` after applying the
message.
*/
History_Snapshot :: proc(s: ^State, info: EditInfo) -> EditSnapshot {
	scene := &s.project.scenes[s.currentScene]
	snap := EditSnapshot{info = info, scene = s.currentScene, selection = s.selectedNode}
	snap.info.label = strings.clone(info.label)
	switch info.scope {
	case .None:
	case .Node:
		if info.node >= 0 && info.node < len(scene.nodes) do snap.node = NodeDef_Clone(scene.nodes[info.node])
	case .Scene:
		snap.nodes = cloneNodes(scene.nodes[:])
	}
	return snap
}

/*
Records an edit, if it changed anything: compares the snapshot with the state after the message,
and pushes a command or merges it into the newest one. Takes ownership of the snapshot.

Inputs:
- s: The state after the message
- snap: From `History_Snapshot`, before the message
- now: The time of the edit (for merging)
*/
History_Commit :: proc(s: ^State, snap: EditSnapshot, now: time.Tick) {
	snap := snap
	command := UndoCommand{
		label = snap.info.label,
		scene = snap.scene,
		selectionBefore = snap.selection,
		selectionAfter = s.selectedNode,
		mergeKey = snap.info.mergeKey,
		sticky = snap.info.sticky,
		started = now,
		last = now,
	}
	// An edit can't switch scenes, but be safe: compare against the scene it started in
	if snap.scene >= len(s.project.scenes) {
		discardSnapshot(&snap)
		return
	}
	scene := &s.project.scenes[snap.scene]
	switch snap.info.scope {
	case .None:
		discardSnapshot(&snap)
		return
	case .Node:
		index := snap.info.node
		if index < 0 || index >= len(scene.nodes) || NodeDef_Equal(snap.node, scene.nodes[index]) {
			discardSnapshot(&snap)
			return
		}
		command.change = NodeChange{index, snap.node, NodeDef_Clone(scene.nodes[index])}
	case .Scene:
		if nodesEqual(snap.nodes[:], scene.nodes[:]) {
			discardSnapshot(&snap)
			return
		}
		command.change = SceneChange{snap.nodes, cloneNodes(scene.nodes[:])}
	}
	History_Push(&s.history, command, &s.settings, now)
}

/*
Adds a command to the history, or merges it into the newest command (see the merging rules at the
top of this file). Clears the redo stack. Takes ownership of `command`.
*/
History_Push :: proc(h: ^History, command: UndoCommand, settings: ^Settings, now: time.Tick) {
	command := command
	if top, ok := mergeTarget(h, &command, settings, now); ok {
		// Keep the top's "before"; take the new "after"
		switch &change in top.change {
		case NodeChange:
			NodeDef_Destroy(&change.after)
			new := command.change.(NodeChange)
			change.after = new.after
			NodeDef_Destroy(&new.before)
		case SceneChange:
			destroyNodes(&change.after)
			new := command.change.(SceneChange)
			change.after = new.after
			destroyNodes(&new.before)
		}
		top.last = now
		top.selectionAfter = command.selectionAfter
		delete(command.label)
		return
	}
	clearCommands(&h.redo)
	append(&h.undo, command)
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
Undoes the newest command: switches to its scene and puts back its "before" state and
selection.

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
	if command.scene >= len(s.project.scenes) {
		destroyCommand(&command)
		return "", false
	}
	if s.currentScene != command.scene do openScene(s, command.scene)
	scene := &s.project.scenes[command.scene]
	switch change in command.change {
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
	}
	s.selectedNode = undo ? command.selectionBefore : command.selectionAfter
	if s.selectedNode >= len(scene.nodes) do s.selectedNode = -1
	s.viewport.drag = {}
	s.treeDrag = {}
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
	   a.texture != b.texture || a.text != b.text || a.fontSize != b.fontSize || a.color != b.color ||
	   a.centered != b.centered || a.zoom != b.zoom || a.columns != b.columns || a.rows != b.rows ||
	   a.fps != b.fps || a.loop != b.loop || a.playMode != b.playMode || len(a.items) != len(b.items) {
		return false
	}
	for item, i in a.items do if item != b.items[i] do return false
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
}
