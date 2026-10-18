package editor

import "core:fmt"
import "core:hash"
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
	ProjectChange,
}

// The project's scene list and settings: adding, removing, renaming scenes, Project Settings
ProjectChange :: struct {
	before: ProjectSnapshot,
	after: ProjectSnapshot,
}

// Everything a `.Project` edit can change (owned)
ProjectSnapshot :: struct {
	name: string,
	startScene: string,
	gameSize: [2]f32,
	scaleMode: e.ScaleMode,
	background: sdl.Color,
	scenes: [dynamic]SceneDef,
	exports: ExportSettings,
	physics: e.PhysicsSettings,
	globals: [dynamic]GlobalDef,
	data: [dynamic]DataDef,
	actions: [dynamic]ActionDef,
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
	project: ProjectSnapshot,
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
	case Scene_Action:
		if SceneOp_EditsProject(v.op) do return {scope = .Project, label = sceneOpLabel(s, v)}
		return {}
	case Project_Settings_Applied:
		return {scope = .Project, label = "Change project settings"}
	case Export_Target_Run:
		// Exporting applies the dialog first
		return {scope = .Project, label = "Change project settings"}
	case Rename_Committed:
		if s.rename.active && s.rename.target == .Scene {
			index := s.rename.node
			label := index >= 0 && index < len(s.project.scenes) ? fmt.tprintf("Rename scene %s", s.project.scenes[index].name) : "Rename scene"
			return {scope = .Project, label = label}
		}
		index := s.rename.node
		if s.rename.active && index >= 0 && index < len(scene.nodes) {
			// Renaming a body joints name changes them too: the whole scene is the step
			if isBodyKind(scene.nodes[index].kind) && Scene_JointsReferTo(scene, scene.nodes[index].name) {
				return {scope = .Scene, label = fmt.tprintf("Rename %s", scene.nodes[index].name)}
			}
			return node(index, fmt.tprintf("Rename %s", scene.nodes[index].name))
		}
	case Node_Renamed:
		if hasSelection && isBodyKind(scene.nodes[selected].kind) && Scene_JointsReferTo(scene, name) {
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
		if prop, isProp := v.target.(ScriptPropTarget); isProp && hasSelection {
			return node(selected, fmt.tprintf("Change %s of %s", prop.name, name), key("prop", prop.name, s.currentScene, selected))
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
		if hasSelection do return node(selected, fmt.tprintf("Rename an animation of %s", name), key("anim-name", s.currentScene, selected, s.animEditor.selected))
	case Anim_Field_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change an animation of %s", name), key("anim", v.field, s.currentScene, selected, s.animEditor.selected))
	case Anim_Loop_Changed, Anim_Mode_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change an animation of %s", name))
	case Anim_Frame_Clicked:
		if hasSelection do return node(selected, fmt.tprintf("Change the frames of an animation of %s", name))
	case Anim_Autoplay_Set:
		if hasSelection do return node(selected, fmt.tprintf("Change the first animation of %s", name))
	case Particle_Field_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %s of %s", particleLabel(v.name), name), key("particle", v.name, s.currentScene, selected))
	case Particle_Axis_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change %s of %s", particleLabel(v.name), name), key("particle", v.name, s.currentScene, selected))
	case Ramp_Edited:
		if hasSelection do return node(selected, fmt.tprintf("Change the color ramp of %s", name), key("particle", "colorRamp", s.currentScene, selected))
	case Particles_Reset:
		if hasSelection do return node(selected, fmt.tprintf("Reset the particles of %s", name))
	case Node_Layer_Toggled:
		if hasSelection do return node(selected, fmt.tprintf("Change collision %s of %s", v.mask ? "mask" : "layers", name))
	case Node_Points_Changed:
		if hasSelection do return node(selected, fmt.tprintf("Change points of %s", name), key("points", s.currentScene, selected))
	case Viewport_Drag_Move:
		drag := s.viewport.drag
		if drag.mode == .None || drag.mode == .Pan || drag.mode == .Box || drag.node < 0 || drag.node >= len(scene.nodes) do break
		info := node(drag.node, fmt.tprintf("%v %s", drag.mode, scene.nodes[drag.node].name), key("drag", s.history.gesture))
		info.sticky = true
		// Several nodes move together: record the whole scene
		if len(s.selection) > 1 && slice.contains(s.selection[:], drag.node) {
			info.scope = .Scene
			info.label = fmt.tprintf("%v %d nodes", drag.mode, len(s.selection))
		}
		return info
	case Component_Instance_Added:
		return {scope = .Scene, label = "Add an instance"}
	case Add_Node_Confirmed, Add_Node_Kind_Chosen:
		return {scope = .Scene, label = "Add node"}
	case Asset_Dropped:
		return {scope = .Scene, label = "Add sprite"}
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
			return {scope = .Project, label = s.project.physics.debugDraw ? "Hide collision shapes" : "Show collision shapes"}
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
	case .Font_Size:  return "font size"
	case .Zoom:       return "zoom"
	case .Columns:    return "columns"
	case .Rows:       return "rows"
	case .Margin:     return "sheet margin"
	case .Spacing:    return "sheet spacing"
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
	case .Project:
		snap.project = takeProjectSnapshot(s)
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
	// A node or scene edit can't switch scenes, but be safe: compare against the scene it started
	// in (a project edit may have removed it, so it doesn't need it)
	if snap.info.scope != .Project && snap.scene >= len(s.project.scenes) {
		discardSnapshot(&snap)
		return
	}
	scene := &s.project.scenes[min(snap.scene, len(s.project.scenes) - 1)]
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
	case .Project:
		after := takeProjectSnapshot(s)
		if projectSnapshotsEqual(&snap.project, &after) {
			destroyProjectSnapshot(&after)
			discardSnapshot(&snap)
			return
		}
		command.change = ProjectChange{snap.project, after}
	}
	History_Push(&s.history, command, &s.settings, now)
}

/*
Adds a command to the history, or merges it into the newest command (see the merging rules at the
top of this file). Clears the redo stack. Takes ownership of `command`.
*/
History_Push :: proc(h: ^History, command: UndoCommand, settings: ^Settings, now: time.Tick) {
	command := command
	h.version += 1
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
		case ProjectChange:
			destroyProjectSnapshot(&change.after)
			new := command.change.(ProjectChange)
			change.after = new.after
			destroyProjectSnapshot(&new.before)
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
	s.history.version += 1
	// The scene list itself: restore it whole, then show the scene that was open
	if change, isProject := command.change.(ProjectChange); isProject {
		snapshot := undo ? &change.before : &change.after
		restoreProjectSnapshot(s, snapshot)
		s.currentScene = clamp(snapshot.currentScene, 0, len(s.project.scenes) - 1)
		s.selectedNode = -1
		clear(&s.selection)
		s.viewport.drag = {}
		s.treeDrag = {}
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
	case ProjectChange:
		// Handled above
	}
	s.selectedNode = undo ? command.selectionBefore : command.selectionAfter
	if s.selectedNode >= len(scene.nodes) do s.selectedNode = -1
	// Only the primary node is remembered; the step selects just it
	clear(&s.selection)
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
	   a.margin != b.margin || a.spacing != b.spacing || a.autoplay != b.autoplay || !animationsEqual(a.animations[:], b.animations[:]) ||
	   len(a.items) != len(b.items) ||
	   a.script != b.script || len(a.props) != len(b.props) ||
	   a.collisionLayer != b.collisionLayer || a.collisionMask != b.collisionMask || a.friction != b.friction ||
	   a.restitution != b.restitution || a.density != b.density || a.gravityScale != b.gravityScale ||
	   a.linearDamping != b.linearDamping || a.angularDamping != b.angularDamping || a.fixedRotation != b.fixedRotation ||
	   a.bullet != b.bullet || a.floorMaxAngle != b.floorMaxAngle || a.shape != b.shape || a.shapeSize != b.shapeSize ||
	   a.radius != b.radius || len(a.points) != len(b.points) || a.disabled != b.disabled || a.target != b.target ||
	   a.enabled != b.enabled || a.excludeParent != b.excludeParent ||
	   a.jointKind != b.jointKind || a.bodyA != b.bodyA || a.bodyB != b.bodyB || a.jointOffset != b.jointOffset ||
	   a.enableLimit != b.enableLimit || a.lower != b.lower || a.upper != b.upper || a.enableMotor != b.enableMotor ||
	   a.motorSpeed != b.motorSpeed || a.maxMotor != b.maxMotor || a.enableSpring != b.enableSpring ||
	   a.hertz != b.hertz || a.dampingRatio != b.dampingRatio || a.collideConnected != b.collideConnected ||
	   a.particles != b.particles || a.component != b.component {
		return false
	}
	for p, i in a.points do if p != b.points[i] do return false
	for item, i in a.items do if item != b.items[i] do return false
	for prop, i in a.props do if prop != b.props[i] do return false
	return true
}

// Whether two animation lists are the same
animationsEqual :: proc(a, b: []AnimationDef) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
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
		destroyProjectSnapshot(&change.before)
		destroyProjectSnapshot(&change.after)
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
	if snap.info.scope == .Project do destroyProjectSnapshot(&snap.project)
}

@(private="file")
takeProjectSnapshot :: proc(s: ^State) -> ProjectSnapshot {
	p := &s.project
	snapshot := ProjectSnapshot{
		name = strings.clone(p.name),
		startScene = strings.clone(p.startScene),
		gameSize = p.gameSize,
		scaleMode = p.scaleMode,
		background = p.background,
		exports = p.exports,
		physics = p.physics,
		currentScene = s.currentScene,
	}
	// Scenes only: components are assets (made and removed with their files, like data resources)
	for &scene in p.scenes do if !Scene_IsComponent(&scene) do append(&snapshot.scenes, SceneDef_Clone(scene))
	for g in p.globals do append(&snapshot.globals, GlobalDef_Clone(g))
	for d in p.data do append(&snapshot.data, DataDef_Clone(d))
	for a in p.actions do append(&snapshot.actions, ActionDef_Clone(a))
	return snapshot
}

@(private="file")
restoreProjectSnapshot :: proc(s: ^State, snapshot: ^ProjectSnapshot) {
	p := &s.project
	delete(p.name)
	delete(p.startScene)
	// The scenes come back; the components stay as they are, after them
	components := make([dynamic]SceneDef, context.temp_allocator)
	for &scene in p.scenes {
		if Scene_IsComponent(&scene) do append(&components, scene)
		else do SceneDef_Destroy(&scene)
	}
	clear(&p.scenes)
	p.name = strings.clone(snapshot.name)
	p.startScene = strings.clone(snapshot.startScene)
	p.gameSize, p.scaleMode, p.background = snapshot.gameSize, snapshot.scaleMode, snapshot.background
	p.exports = snapshot.exports
	p.physics = snapshot.physics
	for &g in p.globals do GlobalDef_Destroy(&g)
	clear(&p.globals)
	for g in snapshot.globals do append(&p.globals, GlobalDef_Clone(g))
	for &a in p.actions do ActionDef_Destroy(&a)
	clear(&p.actions)
	for a in snapshot.actions do append(&p.actions, ActionDef_Clone(a))
	// Data values by file: resources made or removed since (files, not undoable) stay as they are
	for d in snapshot.data {
		i := Project_FindData(p, d.path)
		if i < 0 do continue
		DataDef_Destroy(&p.data[i])
		p.data[i] = DataDef_Clone(d)
	}
	for scene in snapshot.scenes do append(&p.scenes, SceneDef_Clone(scene))
	append(&p.scenes, ..components[:])
}

/*
A component's SceneDef was removed from the project's list (its asset removed): steps that edit
it go, and steps for the documents after it follow their new index.
*/
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

@(private="file")
destroyProjectSnapshot :: proc(snapshot: ^ProjectSnapshot) {
	delete(snapshot.name)
	delete(snapshot.startScene)
	for &scene in snapshot.scenes do SceneDef_Destroy(&scene)
	delete(snapshot.scenes)
	for &g in snapshot.globals do GlobalDef_Destroy(&g)
	delete(snapshot.globals)
	for &d in snapshot.data do DataDef_Destroy(&d)
	delete(snapshot.data)
	for &a in snapshot.actions do ActionDef_Destroy(&a)
	delete(snapshot.actions)
	snapshot^ = {}
}

@(private="file")
projectSnapshotsEqual :: proc(a, b: ^ProjectSnapshot) -> bool {
	if a.name != b.name || a.startScene != b.startScene || a.gameSize != b.gameSize || a.scaleMode != b.scaleMode ||
	   a.background != b.background || a.exports != b.exports || a.physics != b.physics || len(a.scenes) != len(b.scenes) {
		return false
	}
	for scene, i in a.scenes {
		if scene.name != b.scenes[i].name || !nodesEqual(scene.nodes[:], b.scenes[i].nodes[:]) do return false
	}
	if len(a.globals) != len(b.globals) || len(a.data) != len(b.data) || !actionsEqual(a.actions[:], b.actions[:]) do return false
	for g, i in a.globals do if g.script != b.globals[i].script || !propsEqual(g.props[:], b.globals[i].props[:]) do return false
	for d, i in a.data do if d.path != b.data[i].path || d.type != b.data[i].type || !propsEqual(d.values[:], b.data[i].values[:]) do return false
	return true
}
