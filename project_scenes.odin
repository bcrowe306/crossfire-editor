package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

/*
Managing a project's scenes: adding, duplicating, pasting, renaming and removing them, and which
one the game starts in. The browser's Scenes folder and its context menu use these
(scene_actions in update.odin); they're undoable as `.Project` edits (history.odin).

Scene files: a scene is saved to `scenes/<name>.scene.xml`. Renaming or removing a scene doesn't
touch the disk right away; `Project_Save` deletes the files of scenes that are gone, but only files
the editor itself loaded or saved (`Project.sceneFiles`), never other files in the folder.

References: renaming a scene updates what names it, the start scene, Menu buttons
(`scene:<Name>` actions) and script fields that name a scene (`kind=scene`); removing one leaves
references dangling and reports how many there are.
*/

/*
Why a name can't be a scene's: empty, not usable as a file name, or taken by another scene.

Inputs:
- project: The project
- name: The wanted name
- except: A scene allowed to have it already (the one being renamed), or -1

Returns:
- "" if it can be used, otherwise why not (temp allocated)
*/
SceneNameProblem :: proc(project: ^Project, name: string, except := -1) -> string {
	if strings.trim_space(name) == "" do return "give the scene a name"
	if name != strings.trim_space(name) do return "the name can't start or end with spaces"
	if strings.contains_any(name, "/\\:*?\"<>|") do return "the name can't contain / \\ : * ? \" < > |"
	if name == "." || name == ".." do return "that name is reserved"
	for scene, i in project.scenes {
		if i != except && strings.equal_fold(scene.name, name) do return fmt.tprintf("there's already a scene named %s", scene.name)
	}
	return ""
}

/*
A scene name no scene has: `name`, or its base (trailing digits removed) numbered from 2.

Returns:
- The name (temp allocated)
*/
Project_UniqueSceneName :: proc(project: ^Project, name: string) -> string {
	if SceneNameProblem(project, name) == "" do return name
	base := strings.trim_right(name, "0123456789")
	if base == "" do base = name
	for i := 2; ; i += 1 {
		candidate := fmt.tprintf("%s%d", base, i)
		if SceneNameProblem(project, candidate) == "" do return candidate
	}
}

// A deep copy of a scene: its name and nodes
SceneDef_Clone :: proc(scene: SceneDef) -> SceneDef {
	copy := SceneDef{name = strings.clone(scene.name)}
	for node in scene.nodes do append(&copy.nodes, NodeDef_Clone(node))
	return copy
}

// Frees a scene's name and nodes
SceneDef_Destroy :: proc(scene: ^SceneDef) {
	for &node in scene.nodes do NodeDef_Destroy(&node)
	delete(scene.nodes)
	delete(scene.name)
	scene^ = {}
}

/*
Adds a new scene with a top-level Node2D, "World".

Inputs:
- project: The project
- name: A name (made unique if taken)
- at: Where in the scene list, or -1 for the end

Returns:
- The new scene's index
*/
Project_AddScene :: proc(project: ^Project, name: string, at := -1) -> int {
	scene := SceneDef{name = strings.clone(Project_UniqueSceneName(project, name))}
	Scene_InsertNode(&scene, "World", .Node2D, -1)
	return insertScene(project, scene, at)
}

/*
Adds a copy of a scene (duplicating, or pasting a copied one), named after it: "Level" becomes
"Level2" when "Level" is taken.

Inputs:
- project: The project
- source: The scene to copy (not changed)
- at: Where in the scene list, or -1 for the end

Returns:
- The copy's index
*/
Project_AddSceneCopy :: proc(project: ^Project, source: SceneDef, at := -1) -> int {
	copy := SceneDef_Clone(source)
	name := Project_UniqueSceneName(project, source.name)
	delete(copy.name)
	copy.name = strings.clone(name)
	return insertScene(project, copy, at)
}

@(private="file")
insertScene :: proc(project: ^Project, scene: SceneDef, at: int) -> int {
	index := at < 0 || at > len(project.scenes) ? len(project.scenes) : at
	inject_at(&project.scenes, index, scene)
	return index
}

/*
Renames a scene and everything that refers to it: the start scene, Menu buttons that switch to it
(`scene:<Name>`), and script fields of scene kind (`catalog` says which fields those are).

Inputs:
- project: The project
- index: The scene
- name: The new name (see `SceneNameProblem`)
- catalog: The script catalog, to find scene-kind script fields

Returns:
- How many references were updated, and an error message ("" on success)
*/
Project_RenameScene :: proc(project: ^Project, index: int, name: string, catalog: ^ScriptCatalog) -> (references: int, message: string) {
	if index < 0 || index >= len(project.scenes) do return 0, "no such scene"
	if problem := SceneNameProblem(project, name, index); problem != "" do return 0, problem
	old := strings.clone(project.scenes[index].name, context.temp_allocator)
	if old == name do return 0, ""

	delete(project.scenes[index].name)
	project.scenes[index].name = strings.clone(name)
	if project.startScene == old {
		delete(project.startScene)
		project.startScene = strings.clone(name)
		references += 1
	}
	oldAction := fmt.tprintf("scene:%s", old)
	for &scene in project.scenes {
		for &node in scene.nodes {
			for &item in node.items {
				if item.action != oldAction do continue
				delete(item.action)
				item.action = fmt.aprintf("scene:%s", name)
				references += 1
			}
			desc := ScriptCatalog_Find(catalog, node.script)
			if desc == nil do continue
			for &prop in node.props {
				if prop.value != old do continue
				for field in desc.fields {
					if field.name == prop.name && field.hint == "scene" {
						delete(prop.value)
						prop.value = strings.clone(name)
						references += 1
					}
				}
			}
		}
	}
	return references, ""
}

/*
Removes a scene. If it was the start scene, the first remaining scene becomes the start scene.

Inputs:
- project: The project
- index: The scene; the last scene can't be removed

Returns:
- How many Menu buttons still switch to it (they'll do nothing), and an error message
*/
Project_RemoveScene :: proc(project: ^Project, index: int) -> (danglingReferences: int, message: string) {
	if index < 0 || index >= len(project.scenes) do return 0, "no such scene"
	if len(project.scenes) == 1 do return 0, "a project needs at least one scene"
	name := strings.clone(project.scenes[index].name, context.temp_allocator)
	SceneDef_Destroy(&project.scenes[index])
	ordered_remove(&project.scenes, index)
	if project.startScene == name {
		delete(project.startScene)
		project.startScene = strings.clone(project.scenes[0].name)
	}
	action := fmt.tprintf("scene:%s", name)
	for &scene in project.scenes do for &node in scene.nodes do for item in node.items do if item.action == action do danglingReferences += 1
	return danglingReferences, ""
}

// Makes a scene the one the game starts in
Project_SetStartScene :: proc(project: ^Project, index: int) {
	if index < 0 || index >= len(project.scenes) do return
	delete(project.startScene)
	project.startScene = strings.clone(project.scenes[index].name)
}

// The index of the scene with a name, or -1
Project_FindScene :: proc(project: ^Project, name: string) -> int {
	for scene, i in project.scenes do if scene.name == name do return i
	return -1
}

/*
Deletes the files of scenes that are no longer in the project, after a rename or a removal: files
in `project.sceneFiles` (the ones the editor loaded or saved) that no current scene uses. Then
`sceneFiles` becomes the current list. Called by `Project_Save` after writing the scenes.
*/
Project_CleanSceneFiles :: proc(project: ^Project) {
	current := make([dynamic]string, context.temp_allocator)
	for &scene in project.scenes do append(&current, SceneFilePath(&scene, context.temp_allocator))
	for file in project.sceneFiles {
		if slice.contains(current[:], file) do continue
		path, _ := filepath.join({project.rootPath, file}, context.temp_allocator)
		_ = os.remove(path)
	}
	Project_SetSceneFiles(project, current[:])
}

// Replaces `project.sceneFiles` (copies the paths)
Project_SetSceneFiles :: proc(project: ^Project, files: []string) {
	for f in project.sceneFiles do delete(f)
	clear(&project.sceneFiles)
	for f in files do append(&project.sceneFiles, strings.clone(f))
}
