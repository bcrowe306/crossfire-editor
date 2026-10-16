package editor

import "core:fmt"
import e "engine:."

/*
The Add Node dialog's logic: which node kinds match the search, and adding the chosen one.

The kinds and their descriptions come from the engine (`e.SCENE_NODE_KINDS`), so the dialog lists
exactly what scene files and the player support. `view` (to draw the list) and `update` (to know
what Enter or a click picked) both filter with `AddNode_Kinds`.
*/

// The Add Node dialog, part of `State`
AddNodeDialog :: struct {
	open: bool,
	// Filter text (owned)
	search: string,
	// Highlighted entry in the filtered list
	highlight: int,
}

/*
Node kinds matching a search: a case-insensitive substring of the kind's name or description.
An empty search lists every kind.

Inputs:
- search: The search text

Returns:
- The matching kinds, in engine order (temp allocated)
*/
AddNode_Kinds :: proc(search: string) -> []NodeKind {
	kinds := make([dynamic]NodeKind, context.temp_allocator)
	for kind in NodeKind {
		name := fmt.tprintf("%v", kind)
		if matchesSearch(name, search) || matchesSearch(e.SCENE_NODE_KINDS[kind].description, search) {
			append(&kinds, kind)
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

Returns:
- The new node's index
*/
AddNode_Create :: proc(state: ^State, kind: NodeKind) -> int {
	scene := &state.project.scenes[state.currentScene]
	parent := state.selectedNode
	if parent < 0 || parent >= len(scene.nodes) do parent = -1

	index := Scene_InsertNode(scene, uniqueNodeName(scene, fmt.tprintf("%v", kind)), kind, parent)
	state.selectedNode = index
	return index
}

// "Sprite", or "Sprite2", "Sprite3"... if the scene already has one
@(private="file")
uniqueNodeName :: proc(scene: ^SceneDef, base: string) -> string {
	taken :: proc(scene: ^SceneDef, name: string) -> bool {
		for node in scene.nodes do if node.name == name do return true
		return false
	}
	if !taken(scene, base) do return base
	for i := 2; ; i += 1 {
		name := fmt.tprintf("%s%d", base, i)
		if !taken(scene, name) do return name
	}
}
