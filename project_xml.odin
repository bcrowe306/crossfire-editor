package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import e "engine:."

/*
Saving projects as XML, in the format the engine loads (see the engine's project_format.odin).

Output is deterministic: attributes are written in a fixed order, and a node only writes the
attributes that apply to its kind and differ from the defaults. Saving an unchanged project
produces identical files, so projects diff cleanly in version control.
*/

/*
Writes a project to its `rootPath`: project.xml and one file per scene in `scenes/`.
Asset files are not touched.

Inputs:
- project: The project to save

Returns:
- "" on success, otherwise an error message (temp allocated)
*/
Project_Save :: proc(project: ^Project) -> string {
	scenesDir, _ := filepath.join({project.rootPath, "scenes"}, context.temp_allocator)
	if err := os.make_directory_all(scenesDir); err != nil && !os.exists(scenesDir) {
		return fmt.tprintf("Couldn't create %s: %v", scenesDir, err)
	}

	projectFile, _ := filepath.join({project.rootPath, "project.xml"}, context.temp_allocator)
	if err := os.write_entire_file(projectFile, ProjectToXML(project, context.temp_allocator)); err != nil {
		return fmt.tprintf("Couldn't write %s: %v", projectFile, err)
	}

	for &scene in project.scenes {
		path, _ := filepath.join({project.rootPath, SceneFilePath(&scene, context.temp_allocator)}, context.temp_allocator)
		if err := os.write_entire_file(path, SceneToXML(&scene, context.temp_allocator)); err != nil {
			return fmt.tprintf("Couldn't write %s: %v", path, err)
		}
	}
	// Scenes renamed or removed since the last save: delete their old files
	Project_CleanSceneFiles(project)

	// Export settings: only once they differ from the defaults (or the file exists)
	exportsFile, _ := filepath.join({project.rootPath, EXPORT_SETTINGS_FILE}, context.temp_allocator)
	exports := ExportSettings_ToINI(&project.exports, context.temp_allocator)
	if exports != "" || os.exists(exportsFile) {
		if err := os.write_entire_file(exportsFile, exports); err != nil {
			return fmt.tprintf("Couldn't write %s: %v", exportsFile, err)
		}
	}
	return ""
}

/*
The text of a project's project.xml.

Inputs:
- project: The project
- allocator: Allocator for the text

Returns:
- The XML
*/
ProjectToXML :: proc(project: ^Project, allocator := context.allocator) -> string {
	w := xmlWriter(allocator)
	open(&w, "project")
	attr(&w, "formatVersion", e.PROJECT_FORMAT_VERSION)
	attr(&w, "name", project.name)
	attr(&w, "width", project.gameSize.x)
	attr(&w, "height", project.gameSize.y)
	attr(&w, "scaleMode", project.scaleMode)
	attr(&w, "background", e.FormatColor(project.background, context.temp_allocator))
	attr(&w, "startScene", project.startScene)
	endOpen(&w)
	for &scene in project.scenes {
		open(&w, "scene")
		attr(&w, "name", scene.name)
		attr(&w, "path", SceneFilePath(&scene, context.temp_allocator))
		closeEmpty(&w)
	}
	for asset in project.assets {
		open(&w, "asset")
		attr(&w, "path", asset.path)
		attr(&w, "kind", asset.kind)
		closeEmpty(&w)
	}
	close(&w, "project")
	return strings.to_string(w.builder)
}

/*
The text of a scene file. Node nesting follows the scene's parent links.

Inputs:
- scene: The scene
- allocator: Allocator for the text

Returns:
- The XML
*/
SceneToXML :: proc(scene: ^SceneDef, allocator := context.allocator) -> string {
	w := xmlWriter(allocator)
	open(&w, "scene")
	attr(&w, "formatVersion", e.PROJECT_FORMAT_VERSION)
	attr(&w, "name", scene.name)
	endOpen(&w)

	// Nodes are depth-first, so a node's subtree ends where the next node isn't deeper
	open_nodes := make([dynamic]int, context.temp_allocator)
	for &node, i in scene.nodes {
		for len(open_nodes) > 0 && open_nodes[len(open_nodes) - 1] != node.parent {
			pop(&open_nodes)
			close(&w, "node")
		}
		writeNode(&w, &node)
		hasChildren := Scene_HasChildren(scene, i)
		if len(node.items) == 0 && node.script == "" && !hasChildren {
			closeEmpty(&w)
			continue
		}
		endOpen(&w)
		for item in node.items {
			open(&w, "item")
			attr(&w, "label", item.label)
			attr(&w, "action", item.action)
			closeEmpty(&w)
		}
		if node.script != "" {
			open(&w, "script")
			attr(&w, "name", node.script)
			if len(node.props) == 0 {
				closeEmpty(&w)
			} else {
				endOpen(&w)
				for prop in node.props {
					open(&w, "prop")
					attr(&w, "name", prop.name)
					attr(&w, "value", prop.value)
					closeEmpty(&w)
				}
				close(&w, "script")
			}
		}
		if hasChildren {
			append(&open_nodes, i)
		} else {
			close(&w, "node")
		}
	}
	for _ in open_nodes do close(&w, "node")

	close(&w, "scene")
	return strings.to_string(w.builder)
}

/*
Escapes text for an XML attribute value.

Inputs:
- text: Raw text
- allocator: Allocator for the result

Returns:
- The text with `& < > " '` replaced by entities
*/
EscapeXML :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in text {
		switch r {
		case '&':  strings.write_string(&b, "&amp;")
		case '<':  strings.write_string(&b, "&lt;")
		case '>':  strings.write_string(&b, "&gt;")
		case '"':  strings.write_string(&b, "&quot;")
		case '\'': strings.write_string(&b, "&apos;")
		case:      strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}


// WRITER

@(private="file")
XMLWriter :: struct {
	builder: strings.Builder,
	depth: int,
}

@(private="file")
xmlWriter :: proc(allocator := context.allocator) -> XMLWriter {
	w := XMLWriter{builder = strings.builder_make(allocator)}
	strings.write_string(&w.builder, `<?xml version="1.0" encoding="UTF-8"?>` + "\n")
	return w
}

// Starts `<tag`; follow with attr calls, then endOpen or closeEmpty
@(private="file")
open :: proc(w: ^XMLWriter, tag: string) {
	for _ in 0..<w.depth do strings.write_byte(&w.builder, '\t')
	strings.write_byte(&w.builder, '<')
	strings.write_string(&w.builder, tag)
}

@(private="file")
endOpen :: proc(w: ^XMLWriter) {
	strings.write_string(&w.builder, ">\n")
	w.depth += 1
}

@(private="file")
closeEmpty :: proc(w: ^XMLWriter) {
	strings.write_string(&w.builder, "/>\n")
}

@(private="file")
close :: proc(w: ^XMLWriter, tag: string) {
	w.depth -= 1
	for _ in 0..<w.depth do strings.write_byte(&w.builder, '\t')
	fmt.sbprintf(&w.builder, "</%s>\n", tag)
}

@(private="file")
attr :: proc(w: ^XMLWriter, key: string, value: any) {
	text := fmt.tprint(value)
	fmt.sbprintf(&w.builder, ` %s="%s"`, key, EscapeXML(text, context.temp_allocator))
}

// A node's attributes: common ones, then those for its kind. Defaults are left out
@(private="file")
writeNode :: proc(w: ^XMLWriter, node: ^NodeDef) {
	defaults := e.DEFAULT_SCENE_NODE
	open(w, "node")
	attr(w, "kind", node.kind)
	attr(w, "name", node.name)
	attr(w, "x", node.position.x)
	attr(w, "y", node.position.y)
	if node.rotation != 0 do attr(w, "rotation", node.rotation)
	if node.scale.x != 1 do attr(w, "scaleX", node.scale.x)
	if node.scale.y != 1 do attr(w, "scaleY", node.scale.y)
	if node.layer != 0 do attr(w, "layer", node.layer)
	if !node.visible do attr(w, "visible", false)

	switch node.kind {
	case .Sprite:
		attr(w, "texture", node.texture)
	case .AnimatedSprite:
		attr(w, "texture", node.texture)
		attr(w, "columns", node.columns)
		attr(w, "rows", node.rows)
		attr(w, "fps", node.fps)
		attr(w, "loop", node.loop)
		if node.playMode != defaults.playMode do attr(w, "playMode", node.playMode)
	case .Label:
		attr(w, "text", node.text)
		attr(w, "fontSize", node.fontSize)
		attr(w, "color", e.FormatColor(node.color, context.temp_allocator))
		if node.centered != defaults.centered do attr(w, "centered", node.centered)
	case .Camera:
		if node.zoom != defaults.zoom do attr(w, "zoom", node.zoom)
	case .Node2D, .Menu:
	}
}
