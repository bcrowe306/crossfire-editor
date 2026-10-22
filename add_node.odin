package crossfire_editor

import "core:fmt"
import "core:strings"
import e "engine:."

/*
The Add Node dialog's logic: which node kinds match the search, and adding the chosen one.

The kinds, their descriptions and categories come from the engine (`e.SCENE_NODE_KINDS`), so the
dialog lists exactly what scene files and the player support, grouped as the engine groups them. `view` (to draw the list) and `update` (to know
what Enter or a click picked) both filter with `AddNode_Kinds`.
*/

// The Add Node dialog, part of `State`
AddNodeDialog :: struct {
	open: bool,
	// Filter text (owned)
	search: string,
	// Highlighted entry in the filtered list
	highlight: int,
	// Picking the root of a new component (New Component), not a node for the open scene
	forComponent: bool,
}

/*
Node kinds matching a search: a case-insensitive substring of the kind's name, description or
category. An empty search lists every kind.

Inputs:
- search: The search text

Returns:
- The matching kinds, by category (`e.SceneNodeCategory` order), then in engine order (temp
  allocated). The dialog lists them in this order, and its highlight indexes this list
*/
AddNode_Kinds :: proc(search: string) -> []NodeKind {
	kinds := make([dynamic]NodeKind, context.temp_allocator)
	for category in e.SceneNodeCategory {
		categoryMatches := matchesSearch(e.SCENE_NODE_CATEGORY_NAMES[category], search)
		for kind in NodeKind {
			info := e.SCENE_NODE_KINDS[kind]
			if info.category != category do continue
			name := fmt.tprintf("%v", kind)
			if categoryMatches || matchesSearch(name, search) || matchesSearch(info.description, search) {
				append(&kinds, kind)
			}
		}
	}
	return kinds[:]
}

/*
Adds a node of a kind to the open scene: a child of the selected node, or a top-level node when
nothing is selected. It gets the kind's name, numbered if the scene already uses it, and becomes
the selection.

Inputs:
- state: The editor state
- kind: The node kind to add
- custom: A node type of the project's code built on `kind` ("" for none): the node is one, and
  named after it

Returns:
- The new node's index
*/
AddNode_Create :: proc(state: ^State, kind: NodeKind, custom := "") -> int {
	scene := &state.project.scenes[state.currentScene]
	parent := state.selectedNode
	if parent < 0 || parent >= len(scene.nodes) do parent = -1

	index := Scene_InsertNode(scene, Scene_UniqueNodeName(scene, custom != "" ? custom : fmt.tprintf("%v", kind)), kind, parent)
	if custom != "" do scene.nodes[index].customKind = strings.clone(custom)
	state.selectedNode = index
	return index
}

