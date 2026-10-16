package editor

import "core:fmt"
import "core:math"
import "core:strings"
import e "engine:."

/*
Editing whole subtrees of a scene: copying, pasting, duplicating, and moving a node to another
place in the tree.

A copied subtree is a list of nodes in depth-first order whose `parent` indices are relative to
the list: the first node (the subtree's root) has parent -1, and every other node points at an
earlier entry. That's the same shape as a scene's `nodes`, so it can be inserted anywhere.
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
	copy.texture = strings.clone(node.texture)
	copy.text = strings.clone(node.text)
	copy.items = make([dynamic]MenuItemDef, 0, len(node.items))
	for item in node.items {
		append(&copy.items, MenuItemDef{strings.clone(item.label), strings.clone(item.action)})
	}
	return copy
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
Inserts a copied subtree as the last child of `parent`. The copy is cloned, so `nodes` can be
inserted again (pasting twice). The root is renamed if the scene already uses its name.

Inputs:
- scene: The scene
- nodes: A subtree from `Scene_CopySubtree`
- parent: Parent node index, or -1 for a top-level node

Returns:
- The index of the inserted root, or -1 if `nodes` is empty
*/
Scene_PasteSubtree :: proc(scene: ^SceneDef, nodes: []NodeDef, parent: int) -> int {
	if len(nodes) == 0 do return -1
	at := len(scene.nodes)
	if parent >= 0 {
		at = parent + 1 + Scene_DescendantCount(scene, parent)
		scene.nodes[parent].expanded = true
	}
	return insertSubtree(scene, nodes, parent, at)
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
	return insertSubtree(scene, nodes[:], scene.nodes[index].parent, index + len(nodes))
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
dropping it next to or into itself does nothing.

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
	return newIndex[node], true
}

// Inserts clones of `nodes` at array position `at` under `parent`. `at` must be where a child of
// `parent` can go: the end of one of its children's subtrees (or of its own, for the last child)
@(private="file")
insertSubtree :: proc(scene: ^SceneDef, nodes: []NodeDef, parent, at: int) -> int {
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
	name := Scene_UniqueNodeName(scene, clones[0].name)
	if name != clones[0].name {
		delete(clones[0].name)
		clones[0].name = strings.clone(name)
	}
	inject_at(&scene.nodes, at, ..clones)
	return at
}

@(private="file")
flatten :: proc(children: [][dynamic]int, slot: int, order: ^[dynamic]int) {
	for c in children[slot] {
		append(order, c)
		flatten(children, c, order)
	}
}

// Rounds away float noise from recomputed transforms (639.99994 -> 640)
@(private="file")
tidy :: proc(v: f32) -> f32 {
	return math.round(v * 1000) / 1000
}
