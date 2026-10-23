package crossfire_editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import e "engine:."

/*
Editing whole subtrees of a scene: copying, pasting, duplicating, and moving a node to another
place in the tree.

A copied subtree is a list of nodes in depth-first order whose `parent` indices are relative to
the list: the first node (the subtree's root) has parent -1, and every other node points at an
earlier entry. That's the same shape as a scene's `nodes`, so it can be inserted anywhere. A list
can hold several subtrees one after another (copying a multi-selection): each root has parent -1.
*/

// Where a dragged node goes relative to the node it's dropped on
DropPosition :: enum {
	// The target's previous sibling
	Before,
	// The target's next sibling
	After,
	// The target's last child
	Inside,
}

/*
A copy of a node: its strings and lists are cloned.

Inputs:
- node: The node to copy

Returns:
- The copy. Free with `NodeDef_Destroy`
*/
NodeDef_Clone :: proc(node: NodeDef) -> NodeDef {
	copy := node
	copy.name = strings.clone(node.name)
	copy.groups = strings.clone(node.groups)
	copy.texture = strings.clone(node.texture)
	copy.text = strings.clone(node.text)
	copy.items = make([dynamic]MenuItemDef, 0, len(node.items))
	for item in node.items {
		append(&copy.items, MenuItemDef{strings.clone(item.label), strings.clone(item.action)})
	}
	copy.script = strings.clone(node.script)
	copy.props = make([dynamic]ScriptPropDef, 0, len(node.props))
	for prop in node.props do append(&copy.props, ScriptPropDef{strings.clone(prop.name), strings.clone(prop.value)})
	copy.moreScripts = NodeScripts_Clone(node.moreScripts[:])
	copy.customKind = strings.clone(node.customKind)
	copy.customProps = Props_Clone(node.customProps[:])
	copy.listeners = make([dynamic]e.NodeListenerData, 0, len(node.listeners))
	for l in node.listeners do append(&copy.listeners, Listener_Clone(l))
	copy.bodyA = strings.clone(node.bodyA)
	copy.bodyB = strings.clone(node.bodyB)
	copy.points = make([dynamic][2]f32, 0, len(node.points))
	append(&copy.points, ..node.points[:])
	copy.mesh = e.MeshData_Clone(node.mesh)
	copy.ikTip = strings.clone(node.ikTip)
	copy.ikTarget = strings.clone(node.ikTarget)
	copy.dialogue = strings.clone(node.dialogue)
	copy.dialogueStart = strings.clone(node.dialogueStart)
	copy.dialogueBox.font = strings.clone(node.dialogueBox.font)
	copy.animations = make([dynamic]AnimationDef, 0, len(node.animations))
	for a in node.animations do append(&copy.animations, AnimationDef_Clone(a))
	copy.animationSet = strings.clone(node.animationSet)
	copy.musicLayers = MusicLayers_Clone(node.musicLayers)
	copy.asepriteLayers = strings.clone(node.asepriteLayers)
	copy.pivotSlice = strings.clone(node.pivotSlice)
	copy.nineSlice = strings.clone(node.nineSlice)
	copy.region = strings.clone(node.region)
	copy.slice = strings.clone(node.slice)
	copy.autoplay = strings.clone(node.autoplay)
	copy.component = strings.clone(node.component)
	copy.ldtk = LDtkSettings_Clone(node.ldtk)
	copy.tilemap = TileMapSettings_Clone(node.tilemap)
	copy.animator = e.AnimatorSettings_Clone(node.animator)
	copy.ui = e.UISettings_Clone(node.ui)
	copy.stateMachine = e.StateMachineSettings_Clone(node.stateMachine)
	copy.viewCamera = strings.clone(node.viewCamera)
	copy.cameraTarget = strings.clone(node.cameraTarget)
	copy.touchActions = strings.clone(node.touchActions)
	copy.shader = strings.clone(node.shader)
	copy.shaderParams = make([dynamic]ScriptPropDef, 0, len(node.shaderParams))
	for p in node.shaderParams do append(&copy.shaderParams, ScriptPropDef{strings.clone(p.name), strings.clone(p.value)})
	copy.sound = strings.clone(node.sound)
	copy.bus = strings.clone(node.bus)
	copy.material = strings.clone(node.material)
	return copy
}

/*
Points a scene's joints at a body's new name (joints name their bodies).

Returns:
- How many references changed
*/
Scene_RenameJointReferences :: proc(scene: ^SceneDef, old, new: string) -> int {
	if old == "" || old == new do return 0
	changed := 0
	for &node in scene.nodes {
		if node.kind != .Joint do continue
		if node.bodyA == old {
			delete(node.bodyA)
			node.bodyA = strings.clone(new)
			changed += 1
		}
		if node.bodyB == old {
			delete(node.bodyB)
			node.bodyB = strings.clone(new)
			changed += 1
		}
	}
	return changed
}

// Whether any joint in the scene names this body
Scene_JointsReferTo :: proc(scene: ^SceneDef, name: string) -> bool {
	for node in scene.nodes do if node.kind == .Joint && name != "" && (node.bodyA == name || node.bodyB == name) do return true
	return false
}

/*
Copies a node and its descendants.

Inputs:
- scene: The scene
- index: The subtree's root node
- allocator: Allocator for the returned list (the nodes' strings use the context allocator)

Returns:
- The nodes, with parents relative to the list (the root's is -1). Free with `Subtree_Destroy`
*/
Scene_CopySubtree :: proc(scene: ^SceneDef, index: int, allocator := context.allocator) -> [dynamic]NodeDef {
	count := 1 + Scene_DescendantCount(scene, index)
	nodes := make([dynamic]NodeDef, 0, count, allocator)
	for i in index..<index + count {
		node := NodeDef_Clone(scene.nodes[i])
		node.parent = i == index ? -1 : scene.nodes[i].parent - index
		append(&nodes, node)
	}
	return nodes
}

// Frees a list of nodes made by `Scene_CopySubtree`
Subtree_Destroy :: proc(nodes: ^[dynamic]NodeDef) {
	for &node in nodes do NodeDef_Destroy(&node)
	delete(nodes^)
	nodes^ = {}
}

/*
Copies several nodes and their descendants into one list, one subtree after another.

Inputs:
- scene: The scene
- roots: The subtrees' roots (none inside another's subtree; see `Selection_Roots`)

Returns:
- The nodes, parents relative to the list. Free with `Subtree_Destroy`
*/
Scene_CopyNodes :: proc(scene: ^SceneDef, roots: []int, allocator := context.allocator) -> [dynamic]NodeDef {
	nodes := make([dynamic]NodeDef, allocator)
	for root in roots {
		base := len(nodes)
		subtree := Scene_CopySubtree(scene, root, context.temp_allocator)
		for node in subtree {
			node := node
			if node.parent >= 0 do node.parent += base
			append(&nodes, node)
		}
	}
	return nodes
}

/*
Inserts copied subtrees as the last children of `parent`. The copies are cloned, so `nodes` can be
inserted again (pasting twice). Roots are renamed if the scene already uses their names.

Inputs:
- scene: The scene
- nodes: Subtrees from `Scene_CopySubtree` or `Scene_CopyNodes`
- parent: Parent node index, or -1 for top-level nodes

Returns:
- The index of the first inserted root, or -1 if `nodes` is empty
*/
Scene_PasteSubtree :: proc(scene: ^SceneDef, nodes: []NodeDef, parent: int) -> int {
	roots := Scene_PasteNodes(scene, nodes, parent)
	return len(roots) > 0 ? roots[0] : -1
}

/*
Like `Scene_PasteSubtree`, returning every inserted root (temp allocated).
*/
Scene_PasteNodes :: proc(scene: ^SceneDef, nodes: []NodeDef, parent: int) -> []int {
	if len(nodes) == 0 do return nil
	parent := Scene_ParentFor(scene, parent)
	at := len(scene.nodes)
	if parent >= 0 {
		at = parent + 1 + Scene_DescendantCount(scene, parent)
		scene.nodes[parent].expanded = true
	}
	return insertSubtree(scene, nodes, parent, at)
}

/*
Duplicates several nodes: each copy goes right after its original, as described in
`Scene_DuplicateNode`.

Inputs:
- scene: The scene
- roots: The nodes, in node order, none inside another's subtree

Returns:
- The copies' indices (temp allocated)
*/
Scene_DuplicateNodes :: proc(scene: ^SceneDef, roots: []int) -> []int {
	copies := make([dynamic]int, context.temp_allocator)
	// Each copy shifts the nodes after it, including the later roots
	offset := 0
	for root in roots {
		before := len(scene.nodes)
		append(&copies, Scene_DuplicateNode(scene, root + offset))
		offset += len(scene.nodes) - before
	}
	return copies[:]
}

/*
Removes several nodes and their descendants.

Inputs:
- scene: The scene
- roots: The nodes, none inside another's subtree
*/
Scene_RemoveNodes :: proc(scene: ^SceneDef, roots: []int) {
	// Last first, so the earlier indices stay valid
	sorted := make([]int, len(roots), context.temp_allocator)
	copy(sorted, roots)
	slice.sort(sorted)
	#reverse for root in sorted do Scene_RemoveNode(scene, root)
}

/*
Duplicates a node and its descendants. The copy is placed right after the original, as its next
sibling, with a numbered name ("Ship" -> "Ship2").

Inputs:
- scene: The scene
- index: The node to duplicate

Returns:
- The copy's index
*/
Scene_DuplicateNode :: proc(scene: ^SceneDef, index: int) -> int {
	nodes := Scene_CopySubtree(scene, index, context.temp_allocator)
	defer Subtree_Destroy(&nodes)
	// A component's root: the copy goes under it (a component has one root), as its last child
	if index == 0 && Scene_IsComponent(scene) do return insertSubtree(scene, nodes[:], 0, len(nodes))[0]
	return insertSubtree(scene, nodes[:], scene.nodes[index].parent, index + len(nodes))[0]
}

/*
A name no node in the scene has: `name` itself if it's free, otherwise its base (trailing
digits removed) numbered from 2: "Sprite" -> "Sprite2", "Sprite2" -> "Sprite3".

Inputs:
- scene: The scene
- name: The wanted name

Returns:
- The name (temp allocated when it had to be numbered)
*/
Scene_UniqueNodeName :: proc(scene: ^SceneDef, name: string) -> string {
	taken :: proc(scene: ^SceneDef, name: string) -> bool {
		for node in scene.nodes do if node.name == name do return true
		return false
	}
	if !taken(scene, name) do return name
	base := strings.trim_right(name, "0123456789")
	if base == "" do base = name
	for i := 2; ; i += 1 {
		candidate := fmt.tprintf("%s%d", base, i)
		if !taken(scene, candidate) do return candidate
	}
}

/*
Whether a node can be moved to a place in the tree. A node can't go inside its own subtree, and
dropping it next to or into itself does nothing. In a component nothing goes beside the root (the
top level holds only it).

Inputs:
- scene: The scene
- node: The node being moved
- target: The node it's dropped on, or -1 for the end of the top level
- position: Where relative to `target`

Returns:
- true if `Scene_MoveNode` would move it
*/
Scene_CanMoveNode :: proc(scene: ^SceneDef, node, target: int, position: DropPosition) -> bool {
	if node < 0 || node >= len(scene.nodes) do return false
	if Scene_IsComponent(scene) && (target < 0 || (position != .Inside && scene.nodes[target].parent < 0)) do return false
	if target < 0 do return true
	if target >= len(scene.nodes) do return false
	// The target is the node or one of its descendants
	return !(target >= node && target <= node + Scene_DescendantCount(scene, node))
}

/*
Moves a node, with its descendants, to another place in the tree. It keeps its place in the
world: its local position, rotation and scale are recomputed for the new parent.

Inputs:
- scene: The scene
- node: The node to move
- target: The node to drop it on, or -1 to make it the last top-level node
- position: Before or after `target` as a sibling, or inside it as its last child

Returns:
- The node's new index, and whether it moved (false if `Scene_CanMoveNode` says no)
*/
Scene_MoveNode :: proc(scene: ^SceneDef, node, target: int, position: DropPosition) -> (int, bool) {
	if !Scene_CanMoveNode(scene, node, target, position) do return node, false
	world := Scene_WorldTransforms(scene)
	// Cameras keep following the same nodes (their paths are fixed after the move)
	cameraTargets := CameraTargets_Resolve(scene)
	count := len(scene.nodes)

	// Each node's children in order; slot `count` holds the top-level nodes
	children := make([][dynamic]int, count + 1, context.temp_allocator)
	for &list in children do list = make([dynamic]int, context.temp_allocator)
	for n, i in scene.nodes do append(&children[n.parent < 0 ? count : n.parent], i)

	// Detach the node from its parent
	oldSlot := &children[scene.nodes[node].parent < 0 ? count : scene.nodes[node].parent]
	for c, i in oldSlot do if c == node { ordered_remove(oldSlot, i); break }

	// Attach it at the new place
	newParent := -1
	switch {
	case target < 0:
		append(&children[count], node)
	case position == .Inside:
		newParent = target
		append(&children[target], node)
		scene.nodes[target].expanded = true
	case:
		newParent = scene.nodes[target].parent
		slot := &children[newParent < 0 ? count : newParent]
		at := 0
		for c, i in slot do if c == target do at = i
		inject_at(slot, position == .After ? at + 1 : at, node)
	}

	// Flatten back to depth-first order, then rebuild the array
	order := make([dynamic]int, 0, count, context.temp_allocator)
	flatten(children, count, &order)
	newIndex := make([]int, count, context.temp_allocator)
	for old, i in order do newIndex[old] = i

	old := make([]NodeDef, count, context.temp_allocator)
	copy(old, scene.nodes[:])
	for oldIndex, i in order {
		n := old[oldIndex]
		parent := oldIndex == node ? newParent : n.parent
		n.parent = parent >= 0 ? newIndex[parent] : -1
		scene.nodes[i] = n
	}

	// Same world transform under the new parent
	moved := &scene.nodes[newIndex[node]]
	parentWorld := newParent >= 0 ? world[newParent] : e.TRANSFORM2D_IDENTITY
	local := e.Transform2D_Multiply(e.Transform2D_Inverse(parentWorld), world[node])
	moved.position = {tidy(local.origin.x), tidy(local.origin.y)}
	moved.rotation = tidy(e.Transform2D_Rotation(local))
	scale := e.Transform2D_Scale(local)
	// A mirrored transform: keep the X axis and flip Y
	if local.x.x * local.y.y - local.y.x * local.x.y < 0 do scale.y = -scale.y
	moved.scale = {tidy(scale.x), tidy(scale.y)}
	CameraTargets_Repath(scene, cameraTargets, newIndex)
	return newIndex[node], true
}

// Inserts clones of `nodes` (one or more subtrees) at array position `at` under `parent`, and
// returns the roots' indices (temp allocated). `at` must be where a child of `parent` can go: the
// end of one of its children's subtrees (or of its own, for the last child)
@(private="file")
insertSubtree :: proc(scene: ^SceneDef, nodes: []NodeDef, parent, at: int) -> []int {
	n := len(nodes)
	// Nodes from `at` on move down by n
	for i in at..<len(scene.nodes) {
		if scene.nodes[i].parent >= at do scene.nodes[i].parent += n
	}
	clones := make([]NodeDef, n, context.temp_allocator)
	for node, i in nodes {
		clones[i] = NodeDef_Clone(node)
		clones[i].parent = node.parent < 0 ? parent : at + node.parent
	}
	inject_at(&scene.nodes, at, ..clones)
	// Free names for the roots, one at a time so two pasted roots don't get the same one
	roots := make([dynamic]int, context.temp_allocator)
	for node, i in nodes {
		if node.parent >= 0 do continue
		index := at + i
		append(&roots, index)
		root := &scene.nodes[index]
		original := root.name
		root.name = ""
		name := Scene_UniqueNodeName(scene, original)
		root.name = name == original ? original : strings.clone(name)
		if name != original do delete(original)
	}
	return roots[:]
}

@(private="file")
flatten :: proc(children: [][dynamic]int, slot: int, order: ^[dynamic]int) {
	for c in children[slot] {
		append(order, c)
		flatten(children, c, order)
	}
}

// Rounds away float noise from recomputed transforms (639.99994 -> 640)
@(private="package")
tidy :: proc(v: f32) -> f32 {
	return math.round(v * 1000) / 1000
}

/*
Adds a Sprite showing an image, placed at a world position: what dropping an image from the
project browser into the viewport does. It's named after the file ("ship.png" -> "ship").

Inputs:
- scene: The scene
- texture: Image path relative to the project folder
- parent: Parent node index (the selection), or -1 for a top-level node
- world: Where it goes, in world coordinates

Returns:
- The new node's index
*/
Scene_AddSpriteAt :: proc(scene: ^SceneDef, texture: string, parent: int, world: [2]f32) -> int {
	parent := parent
	if parent >= len(scene.nodes) do parent = -1
	parent = Scene_ParentFor(scene, parent)
	base := filepath.stem(filepath.base(texture))
	index := Scene_InsertNode(scene, Scene_UniqueNodeName(scene, base == "" ? "Sprite" : base), .Sprite, parent)
	node := &scene.nodes[index]
	delete(node.texture)
	node.texture = strings.clone(texture)
	// The position is relative to the parent
	parentWorld := parent >= 0 ? Scene_WorldTransforms(scene)[parent] : e.TRANSFORM2D_IDENTITY
	local := e.Transform2D_Apply(e.Transform2D_Inverse(parentWorld), world)
	node.position = {tidy(local.x), tidy(local.y)}
	return index
}
