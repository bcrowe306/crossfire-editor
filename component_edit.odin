package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import e "engine:."

/*
Components: node trees saved in the assets (`components/<name>.component.xml`, assets of kind
Component) and reused in any scene through Component nodes (instances), like Godot's packed
scenes. The engine builds an instance's tree in its place (project_loader.odin); scripts add more
with `e.Scene_Instantiate(scene, COMPONENT_SHIP)`.

- **Editing:** a component is a `SceneDef` with `component` set (its file), kept in
  `Project.scenes` after the scenes, so the viewport, scene tree, inspector and undo work on it as
  on a scene. Everything that means "the project's scenes" (the browser's Scenes folder, the start
  scene, menu and scene fields, project.xml's scene list, Play Scene) leaves components out
  (`Scene_IsComponent`). Opening one (`opened`) gives it a viewport tab.
- **Saving:** `Project_Save` writes each component to its file (`<component>` root).
- **Making one:** Save as Component (the scene tree's menu) turns the selected node and its
  subtree into a component, and the node into an instance of it: its root keeps no transform,
  the instance takes the node's. Or the browser's New Component (a Node2D to build on).
- **Using one:** drag it from the browser into the viewport, its Add to Scene, or a Component node
  (Add Node) with the inspector's Component choice. An instance's own name, transform, layer
  and visibility apply to the component's root; the rest is the component's, and changes to
  the component show in every instance.
*/

COMPONENT_FOLDER :: "components"
COMPONENT_EXTENSION :: ".component.xml"

// Whether a SceneDef is a component (not one of the project's scenes)
Scene_IsComponent :: proc(scene: ^SceneDef) -> bool {
	return scene.component != ""
}

// "components/space_ship.component.xml" -> "space_ship"
ComponentName :: proc(path: string) -> string {
	base := filepath.base(path)
	return strings.has_suffix(base, COMPONENT_EXTENSION) ? base[:len(base) - len(COMPONENT_EXTENSION)] : filepath.stem(base)
}

// The component a file is, among the project's scenes (-1 if none)
Project_FindComponent :: proc(project: ^Project, path: string) -> int {
	for &scene, i in project.scenes do if scene.component == path do return i
	return -1
}

// Reads a component file into a SceneDef (owned). A file that can't be read gives an empty one and why
Project_LoadComponent :: proc(rootPath, path: string) -> (SceneDef, string) {
	scene := SceneDef{name = strings.clone(ComponentName(path)), component = strings.clone(path)}
	full := joinPath(rootPath, path, allocator = context.temp_allocator)
	text, err := os.read_entire_file(full, context.temp_allocator)
	if err != nil do return scene, fmt.tprintf("Couldn't read component %s", path)
	data, parseErr := e.ParseComponent(string(text), context.temp_allocator)
	if parseErr != .None do return scene, fmt.tprintf("%s isn't a component (%v)", path, parseErr)
	for node in data.nodes do append(&scene.nodes, NodeDef_FromData(node))
	return scene, ""
}

// Writes a component's file now (Save writes them too); "" or what went wrong
Project_WriteComponent :: proc(project: ^Project, scene: ^SceneDef) -> string {
	full := joinPath(project.rootPath, scene.component, allocator = context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(full))
	if err := os.write_entire_file(full, SceneToXML(scene, context.temp_allocator)); err != nil {
		return fmt.tprintf("Couldn't write %s: %v", scene.component, err)
	}
	return ""
}

// A path for a new component named `name` that no asset uses: components/ship.component.xml, ship_2...
ComponentPathFor :: proc(project: ^Project, name: string) -> string {
	base := strings.to_lower(sanitize(strings.trim_space(name)), context.temp_allocator)
	if base == "" do base = "component"
	taken :: proc(project: ^Project, path: string) -> bool {
		// Case-insensitively: on Windows and macOS, Ship and ship are one file
		for asset in project.assets do if strings.equal_fold(asset.path, path) do return true
		return os.exists(joinPath(project.rootPath, path, allocator = context.temp_allocator))
	}
	path := fmt.tprintf("%s/%s%s", COMPONENT_FOLDER, base, COMPONENT_EXTENSION)
	for n := 2; taken(project, path); n += 1 do path = fmt.tprintf("%s/%s_%d%s", COMPONENT_FOLDER, base, n, COMPONENT_EXTENSION)
	return path
}

// Adds a component's SceneDef and asset, and writes its file. Returns its scene index, or -1 and why
@(private="file")
addComponent :: proc(project: ^Project, scene: SceneDef) -> (int, string) {
	scene := scene
	if message := Project_WriteComponent(project, &scene); message != "" {
		SceneDef_Destroy(&scene)
		return -1, message
	}
	append(&project.assets, AssetDef{strings.clone(scene.component), .Component})
	append(&project.scenes, scene)
	return len(project.scenes) - 1, ""
}

/*
Makes a new component: a root node of `kind` named `name`, to build on.

Inputs:
- project: The project
- name: The component's name (and its root's); "" for "Component"
- kind: The root node's kind (New Component lets the user pick it, as Add Node does)

Returns:
- Its index in `project.scenes`, or -1 and why not
*/
Project_NewComponent :: proc(project: ^Project, name: string, kind := NodeKind.Node2D) -> (int, string) {
	name := strings.trim_space(name)
	if name == "" do name = "Component"
	scene := SceneDef{name = strings.clone(ComponentName(ComponentPathFor(project, name))), component = strings.clone(ComponentPathFor(project, name))}
	Scene_InsertNode(&scene, name, kind, -1)
	return addComponent(project, scene)
}

/*
Save as Component: the node at `index` and its subtree become a new component (the root's own
transform left out: an instance gives it one), and the node becomes an instance of it, with the
node's name, transform, layer and visibility. Its children leave the scene with it.

Returns:
- The component's index in `project.scenes`, or -1 and why not
*/
Scene_SaveBranchAsComponent :: proc(project: ^Project, sceneIndex, index: int) -> (int, string) {
	if sceneIndex < 0 || sceneIndex >= len(project.scenes) do return -1, "no such scene"
	scene := &project.scenes[sceneIndex]
	if index < 0 || index >= len(scene.nodes) do return -1, "select a node first"
	original := scene.nodes[index]
	if original.kind == .Component do return -1, fmt.tprintf("%s is a component instance already", original.name)

	path := ComponentPathFor(project, original.name)
	component := SceneDef{name = strings.clone(ComponentName(path)), component = strings.clone(path)}
	component.nodes = Scene_CopySubtree(scene, index)
	root := &component.nodes[0]
	root.parent = -1
	root.position, root.rotation, root.scale = {}, 0, {1, 1}
	componentIndex, message := addComponent(project, component)
	if message != "" do return -1, message
	scene = &project.scenes[sceneIndex]

	// The node becomes an instance; its descendants go (they're in the component now)
	descendants := Scene_DescendantCount(scene, index)
	for i in index + 1 ..< index + 1 + descendants do NodeDef_Destroy(&scene.nodes[i])
	remove_range(&scene.nodes, index + 1, index + 1 + descendants)
	for &node in scene.nodes[index + 1:] do if node.parent > index do node.parent -= descendants
	instance := NodeDef_Make(original.name, .Component, original.parent)
	instance.position, instance.rotation, instance.scale = original.position, original.rotation, original.scale
	instance.layer, instance.visible = original.layer, original.visible
	delete(instance.component)
	instance.component = strings.clone(path)
	NodeDef_Destroy(&scene.nodes[index])
	scene.nodes[index] = instance
	return componentIndex, ""
}

/*
Adds an instance of a component under `parent` (-1: the top level), named after the component,
at a world point.

Returns:
- The new node's index, or -1 and why not (the component holding this scene: an instance would
  hold itself)
*/
Scene_AddInstanceAt :: proc(project: ^Project, sceneIndex: int, path: string, parent: int, world: [2]f32) -> (int, string) {
	scene := &project.scenes[sceneIndex]
	if Component_Contains(project, path, scene.component) do return -1, fmt.tprintf("%s holds %s: it can't go inside it", ComponentName(path), scene.name)
	parent := parent
	if parent >= len(scene.nodes) do parent = -1
	index := Scene_InsertNode(scene, Scene_UniqueNodeName(scene, ComponentName(path)), .Component, parent)
	node := &scene.nodes[index]
	delete(node.component)
	node.component = strings.clone(path)
	parentWorld := parent >= 0 ? Scene_WorldTransforms(scene)[parent] : e.TRANSFORM2D_IDENTITY
	local := e.Transform2D_Apply(e.Transform2D_Inverse(parentWorld), world)
	node.position = {tidy(local.x), tidy(local.y)}
	return index, ""
}

/*
Whether a component is, or holds (instances of instances...), the component `other` ("": none).
An instance of `path` can't go into `other` when this is true: it would hold itself.
*/
Component_Contains :: proc(project: ^Project, path, other: string) -> bool {
	if other == "" do return false
	visit :: proc(project: ^Project, path, other: string, depth: int) -> bool {
		if path == other do return true
		if depth > 16 do return true
		i := Project_FindComponent(project, path)
		if i < 0 do return false
		for node in project.scenes[i].nodes {
			if node.kind == .Component && node.component != "" && visit(project, node.component, other, depth + 1) do return true
		}
		return false
	}
	return visit(project, path, other, 0)
}

// Nodes in the project's scenes and components that are instances of a component
Component_InstanceCount :: proc(project: ^Project, path: string) -> int {
	count := 0
	for &scene in project.scenes do for node in scene.nodes do if node.kind == .Component && node.component == path do count += 1
	return count
}

// Why a component can't be renamed to `name` ("" if it can): it becomes the file's name
ComponentNameProblem :: proc(project: ^Project, assetIndex: int, name: string) -> string {
	name := strings.trim_space(name)
	if name == "" do return "Give it a name"
	if sanitize(name) != name do return "Letters, digits and _ only"
	path := fmt.tprintf("%s/%s%s", COMPONENT_FOLDER, name, COMPONENT_EXTENSION)
	for asset, i in project.assets do if i != assetIndex && strings.equal_fold(asset.path, path) do return "There's already a component with that name"
	return ""
}

/*
Renames a component: its file (moved now, components/<name>.component.xml), its asset, and every
instance's reference to it, in every scene and component. Not undoable (it moves a file, like
removing an asset).

Returns:
- How many instances now point at the new name, and "" or what went wrong (nothing changes then)
*/
Project_RenameComponent :: proc(project: ^Project, assetIndex: int, name: string) -> (int, string) {
	if assetIndex < 0 || assetIndex >= len(project.assets) || project.assets[assetIndex].kind != .Component do return 0, "no such component"
	name := strings.trim_space(name)
	if problem := ComponentNameProblem(project, assetIndex, name); problem != "" do return 0, problem
	old := strings.clone(project.assets[assetIndex].path, context.temp_allocator)
	path := fmt.tprintf("%s/%s%s", COMPONENT_FOLDER, name, COMPONENT_EXTENSION)
	if path == old do return 0, ""
	from := joinPath(project.rootPath, old, allocator = context.temp_allocator)
	to := joinPath(project.rootPath, path, allocator = context.temp_allocator)
	if os.exists(from) {
		if err := os.rename(from, to); err != nil do return 0, fmt.tprintf("couldn't rename %s: %v", old, err)
	}
	delete(project.assets[assetIndex].path)
	project.assets[assetIndex].path = strings.clone(path)
	if i := Project_FindComponent(project, old); i >= 0 {
		scene := &project.scenes[i]
		delete(scene.component)
		scene.component = strings.clone(path)
		delete(scene.name)
		scene.name = strings.clone(name)
		// Without a file (it couldn't be moved), write one under the new name
		if !os.exists(to) do Project_WriteComponent(project, scene)
	}
	references := 0
	for &scene in project.scenes {
		for &node in scene.nodes {
			if node.kind != .Component || node.component != old do continue
			delete(node.component)
			node.component = strings.clone(path)
			references += 1
		}
	}
	return references, ""
}

/*
Make Unique: a copy of an instance's component, as a new component (`<name>_2`...), for this
instance alone; the instance points at it, so changing it leaves the other instances alone.

Returns:
- The new component's path (temp allocated), or "" and why not
*/
Scene_MakeInstanceUnique :: proc(project: ^Project, sceneIndex, index: int) -> (string, string) {
	if sceneIndex < 0 || sceneIndex >= len(project.scenes) do return "", "no such scene"
	scene := &project.scenes[sceneIndex]
	if index < 0 || index >= len(scene.nodes) || scene.nodes[index].kind != .Component do return "", "select a component instance"
	source := Project_FindComponent(project, scene.nodes[index].component)
	if source < 0 do return "", fmt.tprintf("%s isn't in the project", scene.nodes[index].component)
	copy := SceneDef_Clone(project.scenes[source])
	path := ComponentPathFor(project, ComponentName(copy.component))
	delete(copy.component)
	copy.component = strings.clone(path)
	delete(copy.name)
	copy.name = strings.clone(ComponentName(path))
	copy.opened = false
	if _, message := addComponent(project, copy); message != "" do return "", message
	node := &project.scenes[sceneIndex].nodes[index]
	delete(node.component)
	node.component = strings.clone(path)
	return path, ""
}
