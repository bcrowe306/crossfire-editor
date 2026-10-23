package crossfire_editor

import "core:strings"

/*
Node paths that follow renames and moves.

Nodes name other nodes of their scene by paths (`Scene_NodePath`, read as the engine's
`Node_FindPath` does): a Camera's follow target, a CameraView's camera, an IKChain's tip and
target, a StateMachine's sprite, a SkinnedMesh's bones, an Animator's tracks (from the Animator's
parent), listeners' targets, and script node fields (`^e.Node`-type exported fields: the
catalog says which, so they're followed once the scripts are built). Renaming or moving a node
would break them, so every rename and move goes through two steps:

	before := NodePaths_Resolve(scene, &state.scripts)   // where every path leads now
	// ... rename or move nodes ...
	NodePaths_Repath(scene, before, newIndex)             // point them at the same nodes again

A path that still leads to its node is left as written; one that doesn't is rewritten from its
owner (or from the top level, "/World/Ship", when it was written that way). A script node field
using its default gets a value of its own when the default no longer leads there. Paths that
lead nowhere before the change are left alone.

A rename that changes any path is a `.Scene` undo step (`Scene_HasNodePaths` in
`History_Classify`); moves already are.
*/

// What kind of stored path a `NodePathRef` is
NodePathKind :: enum {
	// A Camera's follow target (`NodeDef.cameraTarget`)
	Camera_Target,
	// A CameraView's camera (`NodeDef.viewCamera`)
	View_Camera,
	// An IKChain's tip bone (`NodeDef.ikTip`)
	IK_Tip,
	// An IKChain's target (`NodeDef.ikTarget`)
	IK_Target,
	// A StateMachine's AnimatedSprite (`stateMachine.target`; "" is its parent and isn't stored)
	State_Machine_Target,
	// One of a SkinnedMesh's bones (`mesh.bones[slot]`)
	Mesh_Bone,
	// An Animator track's node (`animator.clips[slot].tracks[track].node`, from the Animator's parent)
	Track,
	// A listener's target (`listeners[slot].target`)
	Listener,
	// A script node field: `field` of the first script (slot -1), the node type (slot -2) or
	// `moreScripts[slot]`
	Script_Field,
}

// A path one node stores to another, and the node it led to when it was resolved
NodePathRef :: struct {
	kind: NodePathKind,
	// The node holding the path
	owner: int,
	// Which of the owner's paths (see `NodePathKind`)
	slot: int,
	// The track, for `.Track`
	track: int,
	// The field's name and default, for `.Script_Field` (temp allocated)
	field: string,
	defaultValue: string,
	// The node it leads to
	target: int,
}

// The first script's slot and the node type's, for `.Script_Field`
NODE_PATH_FIRST_SCRIPT :: -1
NODE_PATH_NODE_TYPE :: -2

/*
Every stored node path of a scene that leads to a node now, with that node.

Inputs:
- scene: The scene
- catalog: The script catalog, for script node fields (nil, or not built: they're skipped)

Returns:
- The paths (temp allocated)
*/
NodePaths_Resolve :: proc(scene: ^SceneDef, catalog: ^ScriptCatalog = nil) -> []NodePathRef {
	refs := make([dynamic]NodePathRef, context.temp_allocator)
	add :: proc(refs: ^[dynamic]NodePathRef, scene: ^SceneDef, ref: NodePathRef, path: string) {
		if path == "" do return
		ref := ref
		ref.target = nodePathResolve(scene, ref, path)
		if ref.target >= 0 do append(refs, ref)
	}
	for &node, i in scene.nodes {
		#partial switch node.kind {
		case .Camera:
			add(&refs, scene, {kind = .Camera_Target, owner = i}, node.cameraTarget)
		case .CameraView:
			add(&refs, scene, {kind = .View_Camera, owner = i}, node.viewCamera)
		case .IKChain:
			add(&refs, scene, {kind = .IK_Tip, owner = i}, node.ikTip)
			add(&refs, scene, {kind = .IK_Target, owner = i}, node.ikTarget)
		case .StateMachine:
			add(&refs, scene, {kind = .State_Machine_Target, owner = i}, node.stateMachine.target)
		case .SkinnedMesh:
			for bone, b in node.mesh.bones do add(&refs, scene, {kind = .Mesh_Bone, owner = i, slot = b}, bone)
		case .Animator:
			for clip, c in node.animator.clips do for track, t in clip.tracks {
				if track.property == "event" do continue
				add(&refs, scene, {kind = .Track, owner = i, slot = c, track = t}, track.node == "" ? "." : track.node)
			}
		}
		for l, li in node.listeners do if l.global == "" do add(&refs, scene, {kind = .Listener, owner = i, slot = li}, l.target)
		if catalog == nil do continue
		fields :: proc(refs: ^[dynamic]NodePathRef, scene: ^SceneDef, owner, slot: int, desc: ^ScriptDesc, props: []ScriptPropDef) {
			if desc == nil do return
			for &f in desc.fields do if f.type == .Node {
				ref := NodePathRef{kind = .Script_Field, owner = owner, slot = slot, field = f.name, defaultValue = f.defaultValue}
				add(refs, scene, ref, Props_Value(props, f.name, f.defaultValue))
			}
		}
		if node.script != "" do fields(&refs, scene, i, NODE_PATH_FIRST_SCRIPT, ScriptCatalog_Find(catalog, node.script), node.props[:])
		if node.customKind != "" do fields(&refs, scene, i, NODE_PATH_NODE_TYPE, ScriptCatalog_FindNodeType(catalog, node.customKind), node.customProps[:])
		for &more, m in node.moreScripts do fields(&refs, scene, i, m, ScriptCatalog_Find(catalog, more.name), more.props[:])
	}
	return refs[:]
}

/*
Points paths at the nodes they led to before a rename or a move: those that no longer lead
there are rewritten.

Inputs:
- scene: The scene, after the change
- before: `NodePaths_Resolve` from before it
- newIndex: Each old index's new one, when the nodes moved (nil: they didn't)

Returns:
- How many paths changed
*/
NodePaths_Repath :: proc(scene: ^SceneDef, before: []NodePathRef, newIndex: []int = nil) -> int {
	changed := 0
	for ref in before {
		ref := ref
		if newIndex != nil do ref.owner, ref.target = newIndex[ref.owner], newIndex[ref.target]
		node := &scene.nodes[ref.owner]
		current := nodePathText(node, ref)
		if nodePathResolve(scene, ref, current == "" && ref.kind == .Track ? "." : current) == ref.target do continue
		path: string
		switch {
		case strings.has_prefix(strings.trim_space(current), "/"):
			path = Scene_NodePath(scene, -1, ref.target, context.temp_allocator)
		case ref.kind == .Track:
			path = Timeline_PathTo(scene, ref.owner, ref.target, context.temp_allocator)
		case:
			path = Scene_NodePath(scene, ref.owner, ref.target, context.temp_allocator)
		}
		nodePathSet(node, ref, path)
		changed += 1
	}
	return changed
}

/*
Whether any node of the scene stores a path to another (a rename may change those paths, so
it's a `.Scene` undo step then).
*/
Scene_HasNodePaths :: proc(scene: ^SceneDef, catalog: ^ScriptCatalog = nil) -> bool {
	return len(NodePaths_Resolve(scene, catalog)) > 0
}

// Where a path leads from its owner (a track's from the Animator's parent), or -1
@(private="file")
nodePathResolve :: proc(scene: ^SceneDef, ref: NodePathRef, path: string) -> int {
	if ref.kind == .Track do return Timeline_ResolvePath(scene, ref.owner, path)
	return Scene_ResolvePath(scene, ref.owner, path)
}

// The path a ref stands for, as the node holds it now
@(private="file")
nodePathText :: proc(node: ^NodeDef, ref: NodePathRef) -> string {
	switch ref.kind {
	case .Camera_Target: return node.cameraTarget
	case .View_Camera: return node.viewCamera
	case .IK_Tip: return node.ikTip
	case .IK_Target: return node.ikTarget
	case .State_Machine_Target: return node.stateMachine.target
	case .Mesh_Bone: return node.mesh.bones[ref.slot]
	case .Track: return node.animator.clips[ref.slot].tracks[ref.track].node
	case .Listener: return node.listeners[ref.slot].target
	case .Script_Field: return Props_Value(nodePathProps(node, ref.slot)[:], ref.field, ref.defaultValue)
	}
	return ""
}

// Stores a ref's new path in its node (owned)
@(private="file")
nodePathSet :: proc(node: ^NodeDef, ref: NodePathRef, path: string) {
	replace :: proc(text: ^string, path: string) {
		delete(text^)
		text^ = strings.clone(path)
	}
	switch ref.kind {
	case .Camera_Target: replace(&node.cameraTarget, path)
	case .View_Camera: replace(&node.viewCamera, path)
	case .IK_Tip: replace(&node.ikTip, path)
	case .IK_Target: replace(&node.ikTarget, path)
	case .State_Machine_Target: replace(&node.stateMachine.target, path)
	case .Mesh_Bone: replace(&node.mesh.bones[ref.slot], path)
	case .Track: replace(&node.animator.clips[ref.slot].tracks[ref.track].node, path)
	case .Listener: replace(&node.listeners[ref.slot].target, path)
	case .Script_Field: Props_Set(nodePathProps(node, ref.slot), ref.field, path, ref.defaultValue)
	}
}

// A script slot's field values: the first script's, the node type's or one of the more scripts'
@(private="file")
nodePathProps :: proc(node: ^NodeDef, slot: int) -> ^[dynamic]ScriptPropDef {
	switch slot {
	case NODE_PATH_FIRST_SCRIPT: return &node.props
	case NODE_PATH_NODE_TYPE: return &node.customProps
	}
	return &node.moreScripts[slot].props
}
