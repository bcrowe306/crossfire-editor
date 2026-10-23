package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import e "engine:."

/*
Project asset operations: importing files into `assets/`, removing them, and finding where
they're used. Imported files are copied into the project; asset paths are stored relative to
the project root with `/`.

The asset list is saved in project.xml with the rest of the project (Save, or Play).
*/

ASSETS_FOLDER :: "assets"

// The editor's own file formats: the browser and pickers list these assets by name alone
EDITOR_FORMAT_EXTENSIONS :: [?]string{COMPONENT_EXTENSION, DATA_EXTENSION, ANIMATION_EXTENSION, THEME_EXTENSION, MATERIAL_EXTENSION, e.ATLAS_EXTENSION, e.DIALOGUE_EXTENSION}

/*
How an asset is shown in lists: its file's name, without the extension of the editor's own
formats (`components/coin.component.xml` is "coin"; `assets/hero.png` stays "hero.png").

Example:
	name := Asset_DisplayName("components/coin.component.xml") // "coin"
*/
Asset_DisplayName :: proc(path: string) -> string {
	base := filepath.base(path)
	lower := strings.to_lower(base, context.temp_allocator)
	for ext in EDITOR_FORMAT_EXTENSIONS do if strings.has_suffix(lower, ext) do return base[:len(base) - len(ext)]
	return base
}

/*
The asset kind for a file, from its extension.

Returns:
- The kind, and false for file types the engine can't use
*/
AssetKindForPath :: proc(path: string) -> (AssetKind, bool) {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	switch ext {
	case ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".webp", ".qoi", ".aseprite", ".ase":
		return .Image, true
	case ".wav", ".ogg", ".mp3", ".flac":
		return .Audio, true
	// Converted to Ogg Vorbis when imported (asset_import_edit.odin)
	case ".m4a", ".aac", ".opus", ".wma", ".webm", ".mp4", ".m4b", ".amr", ".ac3":
		return .Audio, true
	// TrueType, OpenType, and BMFont bitmap fonts (the engine's fonts.odin)
	case ".ttf", ".otf", ".fnt":
		return .Font, true
	case ".json":
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), DATA_EXTENSION) do return .Data, true
		// A DragonBones skeleton: imported as a component (skeleton_edit.odin)
		if DragonBones_IsSkeleton(path) do return .Component, true
	case ".xml":
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), COMPONENT_EXTENSION) do return .Component, true
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ANIMATION_EXTENSION) do return .Animation, true
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), THEME_EXTENSION) do return .Theme, true
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), MATERIAL_EXTENSION) do return .PhysicsMaterial, true
		if e.Atlas_IsFile(path) do return .Atlas, true
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), e.DIALOGUE_EXTENSION) do return .Dialogue, true
	// Yarn Spinner: converted into a dialogue on import (dialogue_edit.odin)
	case ".yarn":
		return .Dialogue, true
	case ".ldtk":
		return .LDtk, true
	case ".csv":
		return .Translation, true
	case ".frag":
		return .Shader, true
	}
	return .Image, false
}

// Extensions for the import dialog's filters (semicolon-separated, no dots)
IMPORT_IMAGE_PATTERN :: "png;jpg;jpeg;bmp;gif;tga;webp;qoi;aseprite;ase"
IMPORT_AUDIO_PATTERN :: "wav;ogg;mp3;flac;" + IMPORT_CONVERT_PATTERN
IMPORT_FONT_PATTERN  :: "ttf;otf;fnt"
IMPORT_LDTK_PATTERN  :: "ldtk"
IMPORT_TRANSLATION_PATTERN :: "csv"

/*
Imports a file into the project: copies it into `assets/` (adding `_1`, `_2`... if the name is
taken) and adds it to the asset list. A file that is already inside the project folder is added
without copying.

Inputs:
- project: The project
- source: Path of the file to import

Returns:
- The new asset's index (or the existing one, if the file is already an asset), and an error
  message ("" on success; temp allocated)
*/
Project_ImportAsset :: proc(project: ^Project, source: string) -> (index: int, message: string) {
	kind, supported := AssetKindForPath(source)
	if !supported {
		return -1, fmt.tprintf("%s isn't a supported image, audio or font file", filepath.base(source))
	}
	if !os.exists(source) {
		return -1, fmt.tprintf("%s doesn't exist", source)
	}

	root, _ := os.get_absolute_path(project.rootPath, context.temp_allocator)
	absSource, _ := os.get_absolute_path(source, context.temp_allocator)

	// Already inside the project: reference it where it is
	relative := ""
	if Yarn_IsFile(source) {
		index, _, problem := Yarn_Import(project, source)
		return index, problem
	}
	if DragonBones_IsSkeleton(source) {
		index, _, problem := DragonBones_Import(project, source)
		return index, problem
	}
	if rel, err := filepath.rel(root, absSource, context.temp_allocator); err == nil && !strings.has_prefix(rel, "..") {
		relative = toSlashes(rel)
	} else if kind == .LDtk {
		// With the tilesets and level files it needs (ldtk_edit.odin)
		copied, problem := LDtkEdit_Import(project, source)
		if problem != "" do return -1, problem
		relative = copied
	} else {
		assetsDir, _ := filepath.join({project.rootPath, ASSETS_FOLDER}, context.temp_allocator)
		_ = os.make_directory_all(assetsDir)
		name := uniqueFileName(assetsDir, filepath.base(source))
		destination, _ := filepath.join({assetsDir, name}, context.temp_allocator)
		if err := os.copy_file(destination, source); err != nil {
			return -1, fmt.tprintf("Couldn't copy %s into the project: %v", filepath.base(source), err)
		}
		relative = fmt.tprintf("%s/%s", ASSETS_FOLDER, name)
	}

	for asset, i in project.assets {
		if asset.path == relative do return i, ""
	}
	if kind == .Data {
		def, problem := Project_LoadData(project.rootPath, relative)
		if problem != "" do return -1, problem
		append(&project.data, def)
	}
	if kind == .Animation {
		set, problem := Project_LoadAnimationSet(project.rootPath, relative)
		if problem != "" {
			AnimationSetDef_Destroy(&set)
			return -1, problem
		}
		append(&project.animationSets, set)
	}
	if kind == .Dialogue {
		dialogue, problem := Project_LoadDialogue(project.rootPath, relative)
		if problem != "" {
			DialogueDef_Destroy(&dialogue)
			return -1, problem
		}
		append(&project.dialogues, dialogue)
	}
	if kind == .Atlas {
		atlas, problem := Project_LoadAtlas(project.rootPath, relative)
		if problem != "" {
			AtlasDef_Destroy(&atlas)
			return -1, problem
		}
		append(&project.atlases, atlas)
	}
	if kind == .PhysicsMaterial {
		material, problem := Project_LoadMaterial(project.rootPath, relative)
		if problem != "" {
			MaterialDef_Destroy(&material)
			return -1, problem
		}
		append(&project.materials, material)
	}
	if kind == .Theme {
		theme, problem := Project_LoadTheme(project.rootPath, relative)
		if problem != "" {
			ThemeDef_Destroy(&theme)
			return -1, problem
		}
		append(&project.themes, theme)
	}
	append(&project.assets, AssetDef{path = strings.clone(relative), kind = kind})
	return len(project.assets) - 1, ""
}

/*
Removes an asset from the project's asset list, and optionally deletes its file.

Nodes that use it keep their reference (and draw nothing until it's fixed); `AssetUsage` tells
how many there are.

Inputs:
- project: The project
- index: The asset
- deleteFile: Also delete the file from the project folder. Can't be undone

Returns:
- An error message, "" on success (temp allocated)
*/
Project_RemoveAsset :: proc(project: ^Project, index: int, deleteFile: bool) -> string {
	if index < 0 || index >= len(project.assets) do return "No such asset"
	asset := project.assets[index]
	message := ""
	if deleteFile {
		path, _ := filepath.join({project.rootPath, asset.path}, context.temp_allocator)
		if err := os.remove(path); err != nil && os.exists(path) {
			message = fmt.tprintf("Removed from the project, but couldn't delete %s: %v", asset.path, err)
		}
	}
	if d := Project_FindData(project, asset.path); d >= 0 {
		DataDef_Destroy(&project.data[d])
		ordered_remove(&project.data, d)
	}
	if a := Project_FindAnimationSet(project, asset.path); a >= 0 {
		AnimationSetDef_Destroy(&project.animationSets[a])
		ordered_remove(&project.animationSets, a)
	}
	if d := Project_FindDialogue(project, asset.path); d >= 0 {
		DialogueDef_Destroy(&project.dialogues[d])
		ordered_remove(&project.dialogues, d)
	}
	if a := Project_FindAtlas(project, asset.path); a >= 0 {
		AtlasDef_Destroy(&project.atlases[a])
		ordered_remove(&project.atlases, a)
	}
	if m := Project_FindMaterial(project, asset.path); m >= 0 {
		MaterialDef_Destroy(&project.materials[m])
		ordered_remove(&project.materials, m)
	}
	if t := Project_FindTheme(project, asset.path); t >= 0 {
		ThemeDef_Destroy(&project.themes[t])
		ordered_remove(&project.themes, t)
	}
	// A component's SceneDef (the caller moves the viewport off it first)
	if c := Project_FindComponent(project, asset.path); c >= 0 {
		SceneDef_Destroy(&project.scenes[c])
		ordered_remove(&project.scenes, c)
	}
	delete(asset.path)
	ordered_remove(&project.assets, index)
	return message
}

/*
How many nodes, across all scenes, use an asset path (as their texture, or an animation's sheet),
and animation assets' animations.
*/
AssetUsage :: proc(project: ^Project, path: string) -> int {
	count := 0
	uses :: proc(animations: []AnimationDef, path: string) -> bool {
		for a in animations do if a.sheet == path || strings.trim_suffix(a.sheet, e.ASEPRITE_SHEET_SUFFIX) == path do return true
		return false
	}
	for &scene in project.scenes {
		for node in scene.nodes do if node.texture == path || uses(node.animations[:], path) do count += 1
	}
	for set in project.animationSets do if uses(set.animations[:], path) do count += 1
	return count
}

// Full path of an asset on disk (temp allocated)
AssetFilePath :: proc(project: ^Project, asset: AssetDef) -> string {
	path, _ := filepath.join({project.rootPath, asset.path}, context.temp_allocator)
	return path
}

// "name.png", or "name_1.png", "name_2.png"... if the folder already has it
@(private="package")
uniqueFileName :: proc(folder, name: string) -> string {
	stem := filepath.stem(name)
	ext := filepath.ext(name)
	candidate := name
	for i := 1; ; i += 1 {
		path, _ := filepath.join({folder, candidate}, context.temp_allocator)
		if !os.exists(path) do return candidate
		candidate = fmt.tprintf("%s_%d%s", stem, i, ext)
	}
}

@(private="package")
toSlashes :: proc(path: string) -> string {
	s, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	return s
}
