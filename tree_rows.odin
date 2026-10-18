package editor

import "core:path/filepath"
import "core:strings"

/*
Flattening of the project into the rows the browser and scene tree show.

Skald's tree widget reports clicks by row index, so `view` (to draw rows) and `update` (to
know what a clicked row was) must flatten the state the same way. Both call these procs.
Results are allocated with the temp allocator and are only valid for the current frame.
*/

BrowserItemKind :: enum {
	None,
	Folder,
	Scene,
	Asset,
	// A script file: index into state.scriptFiles
	Script,
}

// What a project browser row refers to
BrowserItem :: struct {
	kind: BrowserItemKind,
	folder: BrowserFolder,
	// Scene or asset index, for those kinds
	index: int,
}

/*
The rows the project browser shows, in order: each folder, followed by its contents if open.

Inputs:
- state: The editor state

Returns:
- One item per visible row (temp allocated)
*/
BrowserRows :: proc(state: ^State) -> []BrowserItem {
	rows := make([dynamic]BrowserItem, context.temp_allocator)
	search := state.browserSearch
	for folder in BrowserFolder {
		contents := make([dynamic]BrowserItem, context.temp_allocator)
		if folder == .Scenes {
			for &scene, i in state.project.scenes {
				// Components are listed in their own folder, as assets
				if !Scene_IsComponent(&scene) && matchesSearch(scene.name, search) do append(&contents, BrowserItem{kind = .Scene, folder = folder, index = i})
			}
		} else if folder == .Scripts {
			// Shown only when the project has scripts
			if len(state.scriptFiles) == 0 do continue
			for file, i in state.scriptFiles {
				if matchesSearch(filepath.base(file), search) do append(&contents, BrowserItem{kind = .Script, folder = folder, index = i})
			}
		} else {
			for asset, i in state.project.assets {
				if AssetFolder(asset.kind) == folder && matchesSearch(filepath.base(asset.path), search) {
					append(&contents, BrowserItem{kind = .Asset, folder = folder, index = i})
				}
			}
		}

		// While searching, only folders with matches are shown, and they're shown open
		if search != "" && len(contents) == 0 do continue
		append(&rows, BrowserItem{kind = .Folder, folder = folder})
		if search != "" || state.browserOpen[folder] do append(&rows, ..contents[:])
	}
	return rows[:]
}

/*
Whether a name matches the browser search: a case-insensitive substring. An empty search
matches everything.
*/
matchesSearch :: proc(name, search: string) -> bool {
	if search == "" do return true
	return strings.contains(strings.to_lower(name, context.temp_allocator), strings.to_lower(search, context.temp_allocator))
}

/*
The browser folder an asset kind is listed under.
*/
AssetFolder :: proc(kind: AssetKind) -> BrowserFolder {
	switch kind {
	case .Image: return .Images
	case .Audio: return .Audio
	case .Font:  return .Fonts
	case .Data:  return .Data
	case .Component: return .Components
	}
	return .Images
}

/*
The nodes the scene tree shows, in order: every node whose ancestors are all expanded.

Inputs:
- scene: The scene

Returns:
- Node indices, one per visible row (temp allocated)
*/
SceneTreeRows :: proc(scene: ^SceneDef) -> []int {
	rows := make([dynamic]int, context.temp_allocator)
	// While inside a collapsed node's subtree, nodes deeper than it are skipped
	collapsedDepth := -1
	for i in 0..<len(scene.nodes) {
		depth := Scene_NodeDepth(scene, i)
		if collapsedDepth >= 0 {
			if depth > collapsedDepth do continue
			collapsedDepth = -1
		}
		append(&rows, i)
		if !scene.nodes[i].expanded && Scene_HasChildren(scene, i) {
			collapsedDepth = depth
		}
	}
	return rows[:]
}
