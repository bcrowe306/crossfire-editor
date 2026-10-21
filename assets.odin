package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

/*
Project asset operations: importing files into `assets/`, removing them, and finding where
they're used. Imported files are copied into the project; asset paths are stored relative to
the project root with `/`.

The asset list is saved in project.xml with the rest of the project (Save, or Play).
*/

ASSETS_FOLDER :: "assets"

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
	case ".ttf", ".otf":
		return .Font, true
	case ".json":
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), DATA_EXTENSION) do return .Data, true
	case ".xml":
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), COMPONENT_EXTENSION) do return .Component, true
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ANIMATION_EXTENSION) do return .Animation, true
	case ".ldtk":
		return .LDtk, true
	case ".csv":
		return .Translation, true
	}
	return .Image, false
}

// Extensions for the import dialog's filters (semicolon-separated, no dots)
IMPORT_IMAGE_PATTERN :: "png;jpg;jpeg;bmp;gif;tga;webp;qoi;aseprite;ase"
IMPORT_AUDIO_PATTERN :: "wav;ogg;mp3;flac"
IMPORT_FONT_PATTERN  :: "ttf;otf"
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
	append(&project.assets, AssetDef{strings.clone(relative), kind})
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
How many nodes, across all scenes, use an asset path.
*/
AssetUsage :: proc(project: ^Project, path: string) -> int {
	count := 0
	for &scene in project.scenes {
		for node in scene.nodes do if node.texture == path do count += 1
	}
	return count
}

// Full path of an asset on disk (temp allocated)
AssetFilePath :: proc(project: ^Project, asset: AssetDef) -> string {
	path, _ := filepath.join({project.rootPath, asset.path}, context.temp_allocator)
	return path
}

// "name.png", or "name_1.png", "name_2.png"... if the folder already has it
@(private="file")
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

@(private="file")
toSlashes :: proc(path: string) -> string {
	s, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	return s
}
