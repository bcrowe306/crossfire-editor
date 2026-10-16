package editor

import "core:slice"

/*
Multi-selection. `State.selection` holds every selected node of the open scene; `selectedNode` is
the primary one (the inspector edits it, the tool handles sit on it), and is always part of the
selection when it's set.

Most code only sets `selectedNode` (a click selects one node). `Selection_Normalize`, which
`update` runs after every message, turns that into a one-node selection. Code that selects
several nodes sets `selection` itself and calls `Selection_Set` (which marks it as set, so a
structural edit's result isn't replaced).

Operations on "the selection" work on its roots: selected nodes with no selected ancestor, so a
selected child isn't deleted or copied twice along with its parent.
*/

/*
Selects nodes, replacing the selection.

Inputs:
- state: The editor state
- nodes: The nodes; copied
- primary: The primary node (must be one of them), or -1 for the last one
*/
Selection_Set :: proc(state: ^State, nodes: []int, primary := -1) {
	clear(&state.selection)
	append(&state.selection, ..nodes)
	state.selectedNode = primary >= 0 ? primary : (len(nodes) > 0 ? nodes[len(nodes) - 1] : -1)
	state.selectionSet = true
	Selection_Normalize(state)
}

// Whether a node is selected
Selection_Contains :: proc(state: ^State, node: int) -> bool {
	return slice.contains(state.selection[:], node)
}

/*
Adds a node to the selection, or removes it if it's already selected (Ctrl+click). The node
becomes the primary one when added; when removed, the last remaining one does.
*/
Selection_Toggle :: proc(state: ^State, node: int) {
	if index, found := slice.linear_search(state.selection[:], node); found {
		ordered_remove(&state.selection, index)
		state.selectedNode = len(state.selection) > 0 ? state.selection[len(state.selection) - 1] : -1
	} else {
		append(&state.selection, node)
		state.selectedNode = node
	}
	state.selectionSet = true
	Selection_Normalize(state)
}

/*
Makes the selection consistent with `selectedNode` and the scene: drops nodes that no longer
exist and duplicates, empties it when nothing is selected, and makes it just `selectedNode` when
that isn't part of it (something selected one node). Sorted by node index.
*/
Selection_Normalize :: proc(state: ^State) {
	count := len(state.project.scenes[state.currentScene].nodes)
	if state.selectedNode < 0 || state.selectedNode >= count {
		state.selectedNode = -1
		clear(&state.selection)
		return
	}
	for i := len(state.selection) - 1; i >= 0; i -= 1 {
		if state.selection[i] < 0 || state.selection[i] >= count do ordered_remove(&state.selection, i)
	}
	if !slice.contains(state.selection[:], state.selectedNode) {
		clear(&state.selection)
		append(&state.selection, state.selectedNode)
	}
	slice.sort(state.selection[:])
	unique := slice.unique(state.selection[:])
	resize(&state.selection, len(unique))
}

/*
The selected nodes that have no selected ancestor, in node order: what Delete, Copy, Duplicate
and dragging act on.

Returns:
- The node indices (temp allocated)
*/
Selection_Roots :: proc(state: ^State) -> []int {
	scene := &state.project.scenes[state.currentScene]
	roots := make([dynamic]int, context.temp_allocator)
	for node in state.selection {
		ancestorSelected := false
		for p := scene.nodes[node].parent; p >= 0; p = scene.nodes[p].parent {
			if slice.contains(state.selection[:], p) {
				ancestorSelected = true
				break
			}
		}
		if !ancestorSelected do append(&roots, node)
	}
	return roots[:]
}
