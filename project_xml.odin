package crossfire_editor

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
		// A component goes to its own file
		file := Scene_IsComponent(&scene) ? scene.component : SceneFilePath(&scene, context.temp_allocator)
		path, _ := filepath.join({project.rootPath, file}, context.temp_allocator)
		_ = os.make_directory_all(filepath.dir(path))
		if err := os.write_entire_file(path, SceneToXML(&scene, context.temp_allocator)); err != nil {
			return fmt.tprintf("Couldn't write %s: %v", path, err)
		}
		Scene_MarkSaved(&scene)
	}
	// Scenes renamed or removed since the last save: delete their old files
	Project_CleanSceneFiles(project)
	if message := Project_SaveData(project); message != "" do return message
	if message := Project_SaveAnimationSets(project); message != "" do return message
	if message := Project_SaveThemes(project); message != "" do return message
	if message := Project_SaveDialogues(project); message != "" do return message
	if message := Project_SaveMaterials(project); message != "" do return message
	if message := Guides_Save(project); message != "" do return message
	// The typed asset constants for scripts follow the asset list
	if message := Scripts_WriteAssetsFile(project); message != "" do return message

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
	if project.renderer != .Auto do attr(&w, "renderer", project.renderer)
	if project.textureFilter != .Default do attr(&w, "textureFilter", project.textureFilter)
	// A scene uses shaders: Auto means the GPU renderer then (shader_edit.odin)
	if Project_UsesShaders(project) do attr(&w, "shaders", true)
	attr(&w, "background", e.FormatColor(project.background, context.temp_allocator))
	attr(&w, "startScene", project.startScene)
	// Physics settings only when they aren't the defaults
	physics := project.physics
	if physics.pixelsPerMeter != e.DEFAULT_PHYSICS.pixelsPerMeter do attr(&w, "pixelsPerMeter", physics.pixelsPerMeter)
	if physics.gravity.x != e.DEFAULT_PHYSICS.gravity.x do attr(&w, "gravityX", physics.gravity.x)
	if physics.gravity.y != e.DEFAULT_PHYSICS.gravity.y do attr(&w, "gravityY", physics.gravity.y)
	if physics.debugDraw do attr(&w, "physicsDebug", true)
	if !physics.smoothing do attr(&w, "physicsSmoothing", false)
	// The window, only what isn't the default
	window := project.window
	if window.fullscreen != e.DEFAULT_WINDOW_SETTINGS.fullscreen do attr(&w, "fullscreen", window.fullscreen)
	if window.vsync != e.DEFAULT_WINDOW_SETTINGS.vsync do attr(&w, "vsync", window.vsync)
	if window.highDPI != e.DEFAULT_WINDOW_SETTINGS.highDPI do attr(&w, "highDPI", window.highDPI)
	// The sound output's format, when not stereo at 48 kHz (0: the device's own)
	if project.audioOutput.frequency != e.DEFAULT_AUDIO_OUTPUT.frequency do attr(&w, "audioFrequency", project.audioOutput.frequency)
	if project.audioOutput.channels != e.DEFAULT_AUDIO_OUTPUT.channels do attr(&w, "audioChannels", project.audioOutput.channels)
	if project.locale != "" do attr(&w, "locale", project.locale)
	if project.uiTheme != "" do attr(&w, "uiTheme", project.uiTheme)
	if t, d := project.transition, e.DEFAULT_TRANSITION; t != d {
		attr(&w, "transition", t.kind)
		if t.duration != d.duration do attr(&w, "transitionTime", t.duration)
		if t.color != d.color do attr(&w, "transitionColor", e.FormatColor(t.color, context.temp_allocator))
	}
	if project.loadingScene != "" do attr(&w, "loadingScene", project.loadingScene)
	if project.icon != "" do attr(&w, "icon", project.icon)
	// Steam (steam_edit.odin)
	if project.steam.appId != 0 do attr(&w, "steamAppId", project.steam.appId)
	if project.steam.cloudSaves do attr(&w, "steamCloud", true)
	endOpen(&w)
	for &scene in project.scenes {
		// Components are assets, not scenes
		if Scene_IsComponent(&scene) do continue
		open(&w, "scene")
		attr(&w, "name", scene.name)
		attr(&w, "path", SceneFilePath(&scene, context.temp_allocator))
		closeEmpty(&w)
	}
	for asset in project.assets {
		open(&w, "asset")
		attr(&w, "path", asset.path)
		attr(&w, "kind", asset.kind)
		// Import settings (asset_import_edit.odin)
		if asset.filter != .Default do attr(&w, "filter", asset.filter)
		if asset.msdf do attr(&w, "msdf", true)
		closeEmpty(&w)
	}
	for global in project.globals {
		open(&w, "global")
		attr(&w, "script", global.script)
		if len(global.props) == 0 {
			closeEmpty(&w)
			continue
		}
		endOpen(&w)
		for prop in global.props {
			open(&w, "prop")
			attr(&w, "name", prop.name)
			attr(&w, "value", prop.value)
			closeEmpty(&w)
		}
		close(&w, "global")
	}
	// The editor's grid, when not the default
	if grid := project.grid; grid != e.DEFAULT_GRID_SETTINGS {
		d := e.DEFAULT_GRID_SETTINGS
		open(&w, "grid")
		if grid.size.x != d.size.x do attr(&w, "width", grid.size.x)
		if grid.size.y != d.size.y do attr(&w, "height", grid.size.y)
		if grid.majorEvery != d.majorEvery do attr(&w, "majorEvery", grid.majorEvery)
		if grid.opacity != d.opacity do attr(&w, "opacity", grid.opacity)
		if grid.majorOpacity != d.majorOpacity do attr(&w, "majorOpacity", grid.majorOpacity)
		closeEmpty(&w)
	}
	// Buses: Master only when it's not the default
	for &bus, i in project.buses {
		if i == 0 && bus.volume == 1 && bus.pan == 0 && !bus.mute && bus.effectCount == 0 do continue
		open(&w, "bus")
		attr(&w, "name", bus.name)
		if bus.volume != 1 do attr(&w, "volume", bus.volume)
		if bus.pan != 0 do attr(&w, "pan", bus.pan)
		if bus.mute do attr(&w, "mute", true)
		if bus.effectCount == 0 {
			closeEmpty(&w)
			continue
		}
		// Its effects (bus_effects_edit.odin): what applies to each kind, when not the default
		endOpen(&w)
		d := e.DEFAULT_AUDIO_EFFECT
		for fx in BusDef_Effects(&bus) {
			open(&w, "effect")
			attr(&w, "kind", fmt.tprint(fx.kind))
			if fx.bypass do attr(&w, "bypass", true)
			switch fx.kind {
			case .LowPass, .HighPass:
				if fx.cutoff != d.cutoff do attr(&w, "cutoff", fx.cutoff)
				if fx.resonance != d.resonance do attr(&w, "resonance", fx.resonance)
			case .Echo:
				if fx.delay != d.delay do attr(&w, "delay", fx.delay)
				if fx.feedback != d.feedback do attr(&w, "feedback", fx.feedback)
				if fx.mix != d.mix do attr(&w, "mix", fx.mix)
			case .Reverb:
				if fx.roomSize != d.roomSize do attr(&w, "roomSize", fx.roomSize)
				if fx.damping != d.damping do attr(&w, "damping", fx.damping)
				if fx.mix != d.mix do attr(&w, "mix", fx.mix)
			}
			closeEmpty(&w)
		}
		close(&w, "bus")
	}
	// Local players, when not the defaults (players_edit.odin)
	if pl, d := project.players, e.DEFAULT_PLAYER_SETTINGS; pl.maxPlayers != d.maxPlayers || pl.keyboard != d.keyboard || pl.joinAction != "" {
		open(&w, "players")
		if pl.maxPlayers != d.maxPlayers do attr(&w, "max", pl.maxPlayers)
		if pl.keyboard != d.keyboard do attr(&w, "keyboard", pl.keyboard)
		if pl.joinAction != "" do attr(&w, "joinAction", pl.joinAction)
		closeEmpty(&w)
	}
	for a in project.achievements {
		open(&w, "achievement")
		attr(&w, "name", a.name)
		if a.title != "" do attr(&w, "title", a.title)
		if a.description != "" do attr(&w, "description", a.description)
		if a.hidden do attr(&w, "hidden", true)
		closeEmpty(&w)
	}
	for action in project.actions {
		open(&w, "action")
		attr(&w, "name", action.name)
		if action.deadzone != e.DEFAULT_ACTION_DEADZONE do attr(&w, "deadzone", action.deadzone)
		if len(action.bindings) == 0 {
			closeEmpty(&w)
			continue
		}
		endOpen(&w)
		for binding in action.bindings {
			element, attributes := e.FormatInputBinding(binding)
			open(&w, element)
			for a in attributes do attr(&w, a.name, a.value)
			closeEmpty(&w)
		}
		close(&w, "action")
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
	// A component's file has the same nodes under a <component> root
	root := Scene_IsComponent(scene) ? "component" : "scene"
	open(&w, root)
	attr(&w, "formatVersion", e.PROJECT_FORMAT_VERSION)
	attr(&w, "name", scene.name)
	// The scene's own settings, only those it has
	if settings := scene.settings; !Scene_IsComponent(scene) {
		if settings.screenLayers != {} do attr(&w, "screenLayers", e.FormatScreenLayers(settings.screenLayers, context.temp_allocator))
		if settings.hasBackground do attr(&w, "background", e.FormatColor(settings.background, context.temp_allocator))
		if settings.lighting do attr(&w, "lighting", true)
		if settings.lighting && settings.ambient.a > 0 do attr(&w, "ambient", e.FormatColor(settings.ambient, context.temp_allocator))
		if settings.bodyShadows do attr(&w, "bodyShadows", true)
		if settings.hasGravity {
			attr(&w, "gravityX", settings.gravity.x)
			attr(&w, "gravityY", settings.gravity.y)
		}
	}
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
		// A ParticleEmitter's settings that aren't the defaults
		particles := node.kind == .ParticleEmitter ? e.FormatParticleSettings(node.particles) : nil
		animations := node.kind == .AnimatedSprite ? node.animations[:] : nil
		entities := node.kind == .LDtkLevel ? node.ldtk.entityComponents[:] : nil
		painted := node.kind == .TileMap ? node.tilemap.painted[:] : nil
		clips := node.kind == .Animator ? node.animator.clips[:] : nil
		machine := node.kind == .StateMachine ? &node.stateMachine : nil
		layers := node.kind == .MusicPlayer ? node.musicLayers[:] : nil
		if len(node.items) == 0 && len(node.shaderParams) == 0 && !(node.kind == .SkinnedMesh && len(node.mesh.vertices) > 0) && node.script == "" && len(node.moreScripts) == 0 && len(node.customProps) == 0 && len(node.listeners) == 0 && len(particles) == 0 && len(animations) == 0 && len(layers) == 0 && len(entities) == 0 && len(painted) == 0 && len(clips) == 0 && (machine == nil || len(machine.states) + len(machine.params) + len(machine.transitions) == 0) && !hasChildren {
			closeEmpty(&w)
			continue
		}
		endOpen(&w)
		// An AnimatedSprite's animations
		for a in animations do writeAnimation(&w, a)
		// A MusicPlayer's layers (music_layers_edit.odin)
		for l in layers {
			open(&w, "layer")
			attr(&w, "name", l.name)
			if l.sound != "" do attr(&w, "sound", l.sound)
			if l.volume != 1 do attr(&w, "volume", l.volume)
			closeEmpty(&w)
		}
		if len(particles) > 0 {
			open(&w, "particles")
			for pair in particles do attr(&w, pair.name, pair.value)
			closeEmpty(&w)
		}
		// An LDtkLevel's entity rules: only what isn't Auto
		// A TileMap's painted layers: their tiles in base64 (the engine's TileLayer_Encode)
		for layer in painted {
			open(&w, "tiles")
			attr(&w, "layer", layer.layer)
			if layer.tileset != 0 do attr(&w, "tileset", layer.tileset)
			if layer.x != 0 do attr(&w, "x", layer.x)
			if layer.y != 0 do attr(&w, "y", layer.y)
			attr(&w, "columns", layer.columns)
			attr(&w, "rows", layer.rows)
			attr(&w, "data", e.TileLayer_Encode(layer.tiles[:], context.temp_allocator))
			closeEmpty(&w)
		}
		// A StateMachine's parameters, states and transitions (the engine's state_machine.odin)
		if machine != nil {
			for p in machine.params {
				open(&w, "param")
				attr(&w, "name", p.name)
				attr(&w, "type", p.kind)
				if p.value != "" do attr(&w, "value", p.value)
				closeEmpty(&w)
			}
			for st in machine.states {
				open(&w, "state")
				attr(&w, "name", st.name)
				if st.animation != "" do attr(&w, "animation", st.animation)
				attr(&w, "x", st.position.x)
				attr(&w, "y", st.position.y)
				if st.canExit != "" do attr(&w, "canExit", st.canExit)
				if st.speed != 1 && st.speed != 0 do attr(&w, "speed", st.speed)
				if st.loop != .As_Made do attr(&w, "loop", st.loop)
				if st.enterEvent != "" do attr(&w, "onEnter", st.enterEvent)
				if st.exitEvent != "" do attr(&w, "onExit", st.exitEvent)
				closeEmpty(&w)
			}
			for t in machine.transitions {
				open(&w, "transition")
				attr(&w, "from", t.from)
				attr(&w, "to", t.to)
				if t.condition != "" do attr(&w, "when", t.condition)
				if t.after != 0 do attr(&w, "after", t.after)
				if t.onFinished do attr(&w, "onFinished", true)
				if t.guard != "" do attr(&w, "guard", t.guard)
				if t.priority != 0 do attr(&w, "priority", t.priority)
				if t.interrupts do attr(&w, "interrupts", true)
				closeEmpty(&w)
			}
		}
		// An Animator's clips: tracks of keys (the engine's animator.odin)
		for clip in clips {
			open(&w, "clip")
			attr(&w, "name", clip.name)
			attr(&w, "length", clip.length)
			if clip.loop do attr(&w, "loop", true)
			if len(clip.tracks) == 0 {
				closeEmpty(&w)
				continue
			}
			endOpen(&w)
			for track in clip.tracks {
				open(&w, "track")
				if track.node != "" do attr(&w, "node", track.node)
				attr(&w, "property", track.property)
				if track.step do attr(&w, "step", true)
				if len(track.keys) == 0 {
					closeEmpty(&w)
					continue
				}
				endOpen(&w)
				for key in track.keys {
					open(&w, "key")
					attr(&w, "time", key.time)
					attr(&w, "value", key.value)
					if key.ease != .Linear do attr(&w, "ease", key.ease)
					closeEmpty(&w)
				}
				close(&w, "track")
			}
			close(&w, "clip")
		}
		for m in entities {
			open(&w, "entity")
			attr(&w, "name", m.entity)
			if m.component != "" do attr(&w, "component", m.component)
			if m.make != .Auto do attr(&w, "make", m.make)
			if m.script != "" do attr(&w, "script", m.script)
			if m.noScript do attr(&w, "noScript", true)
			closeEmpty(&w)
		}
		// Scripts listening to its events
		for l in node.listeners {
			open(&w, "listener")
			if l.global != "" do attr(&w, "global", l.global)
			attr(&w, "event", l.event)
			attr(&w, "target", l.target)
			attr(&w, "handler", l.handler)
			closeEmpty(&w)
		}
		for p in node.shaderParams {
			open(&w, "shaderParam")
			attr(&w, "name", p.name)
			attr(&w, "value", p.value)
			closeEmpty(&w)
		}
		for item in node.items {
			open(&w, "item")
			attr(&w, "label", item.label)
			attr(&w, "action", item.action)
			closeEmpty(&w)
		}
		// A SkinnedMesh's mesh (skeleton_edit.odin; the engine's skeleton.odin)
		if node.kind == .SkinnedMesh && len(node.mesh.vertices) > 0 {
			m := &node.mesh
			open(&w, "mesh")
			attr(&w, "vertices", e.FormatPoints(m.vertices[:], context.temp_allocator))
			if len(m.uvs) > 0 do attr(&w, "uvs", e.FormatPoints(m.uvs[:], context.temp_allocator))
			if len(m.triangles) > 0 do attr(&w, "triangles", e.FormatTriangles(m.triangles[:]))
			if len(m.bones) > 0 do attr(&w, "bones", strings.join(m.bones[:], ",", context.temp_allocator))
			if len(m.weights) > 0 do attr(&w, "weights", e.FormatWeights(m.weights[:]))
			closeEmpty(&w)
		}
		// A custom node type's own field values (`<prop>` children of the node)
		for prop in node.customProps {
			open(&w, "prop")
			attr(&w, "name", prop.name)
			attr(&w, "value", prop.value)
			closeEmpty(&w)
		}
		// Its scripts, in order: the first, then the more scripts
		writeScript :: proc(w: ^XMLWriter, name: string, props: []ScriptPropDef) {
			open(w, "script")
			attr(w, "name", name)
			if len(props) == 0 {
				closeEmpty(w)
				return
			}
			endOpen(w)
			for prop in props {
				open(w, "prop")
				attr(w, "name", prop.name)
				attr(w, "value", prop.value)
				closeEmpty(w)
			}
			close(w, "script")
		}
		if node.script != "" do writeScript(&w, node.script, node.props[:])
		for extra in node.moreScripts do writeScript(&w, extra.name, extra.props[:])
		if hasChildren {
			append(&open_nodes, i)
		} else {
			close(&w, "node")
		}
	}
	for _ in open_nodes do close(&w, "node")

	close(&w, root)
	return strings.to_string(w.builder)
}

/*
Escapes text for an XML attribute value.

Inputs:
- text: Raw text
- allocator: Allocator for the result

Returns:
- The text with `& < > " '` replaced by entities, and line breaks and tabs by character
  references (`&#10;`, `&#13;`, `&#9;`): an XML parser reads a raw line break in an attribute as a
  space, so a RichText's lines ran together after a save and a load
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
		case '\n': strings.write_string(&b, "&#10;")
		case '\r': strings.write_string(&b, "&#13;")
		case '\t': strings.write_string(&b, "&#9;")
		case:      strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}


// WRITER

/*
An `.anim.xml` file's text (an animation asset): the sheet on the root element, an `<animation>`
per animation. Deterministic, like scene files.
*/
AnimationSetToXML :: proc(set: ^AnimationSetDef, allocator := context.allocator) -> string {
	w := xmlWriter(allocator)
	open(&w, "animations")
	attr(&w, "formatVersion", e.PROJECT_FORMAT_VERSION)
	if set.autoplay != "" do attr(&w, "autoplay", set.autoplay)
	if len(set.animations) == 0 {
		closeEmpty(&w)
	} else {
		endOpen(&w)
		for a in set.animations do writeAnimation(&w, a)
		close(&w, "animations")
	}
	return strings.to_string(w.builder)
}

// An `<animation>`: its sheet and grid (columns x rows, or a cell's size; margin and gap when
// set), `fps` always, the rest when not the default (durations in milliseconds)
@(private="file")
writeAnimation :: proc(w: ^XMLWriter, a: AnimationDef) {
	open(w, "animation")
	attr(w, "name", a.name)
	if a.sheet != "" do attr(w, "sheet", a.sheet)
	switch a.grid.mode {
	case .Cells:
		attr(w, "columns", max(a.grid.columns, 1))
		attr(w, "rows", max(a.grid.rows, 1))
	case .Size:
		attr(w, "grid", a.grid.mode)
		attr(w, "cellWidth", a.grid.cellSize.x)
		attr(w, "cellHeight", a.grid.cellSize.y)
	}
	if a.grid.margin != 0 do attr(w, "margin", a.grid.margin)
	if a.grid.spacing != 0 do attr(w, "spacing", a.grid.spacing)
	attr(w, "start", a.start)
	attr(w, "end", a.end)
	attr(w, "fps", a.fps)
	if a.loop do attr(w, "loop", true)
	if a.playMode != .Forward do attr(w, "playMode", a.playMode)
	if a.repeat > 0 do attr(w, "repeat", a.repeat)
	if len(a.durations) > 0 {
		b := strings.builder_make(context.temp_allocator)
		for d, i in a.durations do fmt.sbprintf(&b, "%s%v", i > 0 ? " " : "", f32(int(d * 1000 * 1000 + 0.5)) / 1000)
		attr(w, "durations", strings.to_string(b))
	}
	if len(a.events) > 0 {
		any := false
		for event in a.events do if event != "" do any = true
		if any do attr(w, "events", strings.join(a.events[:], ";", context.temp_allocator))
	}
	closeEmpty(w)
}

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
	// A custom node type: its name, and the built-in kind it's built on
	if node.customKind != "" {
		attr(w, "kind", node.customKind)
		attr(w, "baseKind", node.kind)
	} else {
		attr(w, "kind", node.kind)
	}
	attr(w, "name", node.name)
	attr(w, "x", node.position.x)
	attr(w, "y", node.position.y)
	if node.rotation != 0 do attr(w, "rotation", node.rotation)
	if node.scale.x != 1 do attr(w, "scaleX", node.scale.x)
	if node.scale.y != 1 do attr(w, "scaleY", node.scale.y)
	if node.layer != 0 do attr(w, "layer", node.layer)
	if !node.visible do attr(w, "visible", false)
	if node.processMode != .Inherit do attr(w, "processMode", node.processMode)
	if node.blendMode != .Blend do attr(w, "blendMode", node.blendMode)
	if node.zIndex != 0 do attr(w, "zIndex", int(node.zIndex))
	if node.ySort do attr(w, "ySort", true)
	if node.groups != "" do attr(w, "groups", node.groups)
	// Its shader (shader_edit.odin; the values are <shaderParam> children)
	if node.shader != "" do attr(w, "shader", node.shader)
	if node.kind == .ScreenEffect && !node.effectScreenLayers do attr(w, "effectScreenLayers", false)

	switch node.kind {
	case .Sprite:
		attr(w, "texture", node.texture)
		if node.region != "" do attr(w, "region", node.region)
		if node.asepriteLayers != "" do attr(w, "layers", node.asepriteLayers)
		if node.pivotSlice != "" do attr(w, "pivotSlice", node.pivotSlice)
		if node.nineSlice != "" {
			attr(w, "nineSlice", node.nineSlice)
			if node.nineSize.x > 0 do attr(w, "nineWidth", node.nineSize.x)
			if node.nineSize.y > 0 do attr(w, "nineHeight", node.nineSize.y)
		}
	case .AnimatedSprite:
		// Its sheets are its animations' (format 14)
		if node.autoplay != "" do attr(w, "autoplay", node.autoplay)
		if node.animationSet != "" do attr(w, "animations", node.animationSet)
		if node.asepriteLayers != "" do attr(w, "layers", node.asepriteLayers)
		if node.pivotSlice != "" do attr(w, "pivotSlice", node.pivotSlice)
	case .Label:
		attr(w, "text", node.text)
		attr(w, "fontSize", node.fontSize)
		attr(w, "color", e.FormatColor(node.color, context.temp_allocator))
		if node.centered != defaults.centered do attr(w, "centered", node.centered)
	case .Camera:
		if node.zoom != defaults.zoom do attr(w, "zoom", node.zoom)
		writeCamera(w, node)
	case .StaticBody, .DynamicBody, .CharacterMover, .Area:
		if node.collisionLayer != defaults.collisionLayer do attr(w, "collisionLayer", e.FormatPhysicsLayers(node.collisionLayer, context.temp_allocator))
		if node.collisionMask != defaults.collisionMask do attr(w, "collisionMask", e.FormatPhysicsLayers(node.collisionMask, context.temp_allocator))
		if node.kind != .Area {
			if node.friction != defaults.friction do attr(w, "friction", node.friction)
			if node.restitution != defaults.restitution do attr(w, "restitution", node.restitution)
			if node.material != "" do attr(w, "material", node.material)
		}
		#partial switch node.kind {
		case .DynamicBody:
			if node.density != defaults.density do attr(w, "density", node.density)
			if node.gravityScale != defaults.gravityScale do attr(w, "gravityScale", node.gravityScale)
			if node.linearDamping != defaults.linearDamping do attr(w, "linearDamping", node.linearDamping)
			if node.angularDamping != defaults.angularDamping do attr(w, "angularDamping", node.angularDamping)
			if node.fixedRotation do attr(w, "fixedRotation", true)
			if node.bullet do attr(w, "bullet", true)
		case .CharacterMover:
			if node.floorMaxAngle != defaults.floorMaxAngle do attr(w, "floorMaxAngle", node.floorMaxAngle)
		}
	case .CollisionShape:
		writeShape(w, node)
		if node.disabled do attr(w, "disabled", true)
		if node.oneWay do attr(w, "oneWay", true)
		if node.slice != "" do attr(w, "slice", node.slice)
	case .LightOccluder:
		writeShape(w, node)
	case .ParallaxLayer, .CameraZone, .CameraView:
		c, d := node.cameraTools, e.DEFAULT_CAMERA_TOOL_SETTINGS
		#partial switch node.kind {
		case .ParallaxLayer:
			if node.texture != "" do attr(w, "texture", node.texture)
			if c.factor.x != d.factor.x do attr(w, "factorX", c.factor.x)
			if c.factor.y != d.factor.y do attr(w, "factorY", c.factor.y)
			if c.repeatX do attr(w, "repeatX", true)
			if c.repeatY do attr(w, "repeatY", true)
		case .CameraZone:
			attr(w, "width", node.shapeSize.x)
			attr(w, "height", node.shapeSize.y)
			if c.transition != d.transition do attr(w, "zoneTransition", c.transition)
		case .CameraView:
			attr(w, "width", node.shapeSize.x)
			attr(w, "height", node.shapeSize.y)
			if node.viewCamera != "" do attr(w, "viewCamera", node.viewCamera)
			if c.zoom != d.zoom do attr(w, "viewZoom", c.zoom)
			if c.border != d.border do attr(w, "border", c.border)
		}
	case .StateMachine:
		if node.stateMachine.start != "" do attr(w, "start", node.stateMachine.start)
		if node.stateMachine.target != "" do attr(w, "animates", node.stateMachine.target)
	case .NavRegion, .NavAgent:
		n, d := node.nav, e.DEFAULT_NAV_SETTINGS
		if node.kind == .NavRegion {
			attr(w, "width", node.shapeSize.x)
			attr(w, "height", node.shapeSize.y)
			if n.cellSize != d.cellSize do attr(w, "cellSize", n.cellSize)
			if n.agentRadius != d.agentRadius do attr(w, "agentRadius", n.agentRadius)
			if n.diagonal != d.diagonal do attr(w, "diagonal", n.diagonal)
		} else {
			if n.speed != d.speed do attr(w, "speed", n.speed)
			if n.arriveDistance != d.arriveDistance do attr(w, "arriveDistance", n.arriveDistance)
			if n.avoidRadius != d.avoidRadius do attr(w, "avoidRadius", n.avoidRadius)
			if n.autoMove != d.autoMove do attr(w, "autoMove", n.autoMove)
		}
	case .DialogueBox:
		// dialogue_edit.odin: its dialogue, start node, and the settings that aren't the defaults
		b, d := node.dialogueBox, defaults.dialogueBox
		if node.dialogue != "" do attr(w, "dialogue", node.dialogue)
		if node.dialogueStart != "" do attr(w, "startNode", node.dialogueStart)
		if b.size.x != d.size.x do attr(w, "boxWidth", b.size.x)
		if b.size.y != d.size.y do attr(w, "boxHeight", b.size.y)
		if b.typeSpeed != d.typeSpeed do attr(w, "typeSpeed", b.typeSpeed)
		if b.fontSize != d.fontSize do attr(w, "textSize", b.fontSize)
		if b.font != "" do attr(w, "boxFont", b.font)
		if b.padding != d.padding do attr(w, "boxPadding", b.padding)
		if b.background != d.background do attr(w, "boxColor", e.FormatColor(b.background, context.temp_allocator))
		if b.textColor != d.textColor do attr(w, "textColor", e.FormatColor(b.textColor, context.temp_allocator))
		if b.nameColor != d.nameColor do attr(w, "nameColor", e.FormatColor(b.nameColor, context.temp_allocator))
		if b.pickColor != d.pickColor do attr(w, "pickColor", e.FormatColor(b.pickColor, context.temp_allocator))
		if b.autostart != d.autostart do attr(w, "boxAutostart", b.autostart)
		if b.hideWhenDone != d.hideWhenDone do attr(w, "hideWhenDone", b.hideWhenDone)
	case .Skeleton2D:
	case .Bone2D:
		if node.boneLength != defaults.boneLength do attr(w, "boneLength", node.boneLength)
	case .SkinnedMesh:
		if node.texture != "" do attr(w, "texture", node.texture)
		if node.region != "" do attr(w, "region", node.region)
	case .IKChain:
		if node.ikTip != "" do attr(w, "ikTip", node.ikTip)
		if node.ikTarget != "" do attr(w, "ikTarget", node.ikTarget)
		if node.ik.length != defaults.ik.length do attr(w, "ikLength", node.ik.length)
		if node.ik.bendPositive != defaults.ik.bendPositive do attr(w, "ikBend", node.ik.bendPositive ? "positive" : "negative")
		if node.ik.enabled != defaults.ik.enabled do attr(w, "ikEnabled", node.ik.enabled)
	case .Line2D, .Trail2D:
		// line_edit.odin: a line's points, the image, the settings that aren't the defaults
		l, d := node.line, e.DEFAULT_LINE_SETTINGS
		if node.kind == .Line2D && len(node.points) > 0 do attr(w, "points", e.FormatPoints(node.points[:], context.temp_allocator))
		if node.texture != "" do attr(w, "texture", node.texture)
		if l.width != d.width do attr(w, "lineWidth", l.width)
		if l.endWidth != d.endWidth do attr(w, "endWidth", l.endWidth)
		if l.color != d.color do attr(w, "lineColor", e.FormatColor(l.color, context.temp_allocator))
		if l.endColor != d.endColor do attr(w, "endColor", e.FormatColor(l.endColor, context.temp_allocator))
		if l.joint != d.joint do attr(w, "joint", l.joint)
		if l.roundCaps != d.roundCaps do attr(w, "roundCaps", l.roundCaps)
		if l.closed != d.closed do attr(w, "closed", l.closed)
		if l.textureMode != d.textureMode do attr(w, "textureMode", l.textureMode)
		if l.lifetime != d.lifetime do attr(w, "lifetime", l.lifetime)
		if l.minDistance != d.minDistance do attr(w, "minDistance", l.minDistance)
		if l.emitting != d.emitting do attr(w, "emitting", l.emitting)
	case .VirtualJoystick, .TouchButton:
		// touch_edit.odin; a button's label is `text`
		t, d := node.touch, e.TouchControl_Defaults(node.kind)
		if node.kind == .TouchButton && node.text != "" do attr(w, "text", node.text)
		if node.touchActions != "" do attr(w, "touchActions", node.touchActions)
		if t.radius != d.radius do attr(w, "touchRadius", t.radius)
		if t.deadzone != d.deadzone do attr(w, "deadzone", t.deadzone)
		if t.zone.x != d.zone.x do attr(w, "zoneWidth", t.zone.x)
		if t.zone.y != d.zone.y do attr(w, "zoneHeight", t.zone.y)
		if t.floating != d.floating do attr(w, "floating", t.floating)
		if t.visibility != d.visibility do attr(w, "touchVisibility", t.visibility)
		if t.mouse != d.mouse do attr(w, "touchMouse", t.mouse)
		if t.color != d.color do attr(w, "touchColor", e.FormatColor(t.color, context.temp_allocator))
		if t.opacity != d.opacity do attr(w, "touchOpacity", t.opacity)
	case .Light2D:
		l, d := node.light, e.DEFAULT_LIGHT_SETTINGS
		if l.kind != d.kind do attr(w, "lightKind", l.kind)
		if l.color != d.color do attr(w, "lightColor", e.FormatColor(l.color, context.temp_allocator))
		if l.energy != d.energy do attr(w, "energy", l.energy)
		if l.radius != d.radius do attr(w, "lightRadius", l.radius)
		if l.angle != d.angle do attr(w, "spotAngle", l.angle)
		if l.shadows != d.shadows do attr(w, "shadows", l.shadows)
	case .RayCast:
		attr(w, "targetX", node.target.x)
		attr(w, "targetY", node.target.y)
		if node.collisionMask != defaults.collisionMask do attr(w, "collisionMask", e.FormatPhysicsLayers(node.collisionMask, context.temp_allocator))
		if !node.enabled do attr(w, "enabled", false)
		if !node.excludeParent do attr(w, "excludeParent", false)
	case .Joint:
		attr(w, "joint", node.jointKind)
		if node.bodyA != "" do attr(w, "bodyA", node.bodyA)
		attr(w, "bodyB", node.bodyB)
		if node.jointKind == .Distance {
			attr(w, "offsetX", node.jointOffset.x)
			attr(w, "offsetY", node.jointOffset.y)
		}
		if node.enableLimit do attr(w, "limit", true)
		if node.lower != 0 do attr(w, "lower", node.lower)
		if node.upper != 0 do attr(w, "upper", node.upper)
		if node.enableMotor do attr(w, "motor", true)
		if node.motorSpeed != 0 do attr(w, "motorSpeed", node.motorSpeed)
		if node.maxMotor != 0 do attr(w, "maxMotor", node.maxMotor)
		if node.enableSpring do attr(w, "spring", true)
		if node.hertz != 0 do attr(w, "hertz", node.hertz)
		if node.dampingRatio != defaults.dampingRatio do attr(w, "damping", node.dampingRatio)
		if node.collideConnected do attr(w, "collideConnected", true)
	case .ParticleEmitter:
		if node.texture != "" do attr(w, "texture", node.texture)
	case .Component:
		attr(w, "component", node.component)
	case .Panel, .Button, .ProgressBar, .TextField, .ScrollBox, .RichText, .Slider, .CheckBox:
		u, d := node.ui, e.DEFAULT_UI_SETTINGS
		if node.kind != .Panel && node.kind != .ScrollBox && node.kind != .Slider && node.text != "" do attr(w, "text", node.text)
		if node.texture != "" && UIKind_TakesImage(node.kind) do attr(w, "texture", node.texture)
		if u.size.x != 0 do attr(w, "width", u.size.x)
		if u.size.y != 0 do attr(w, "height", u.size.y)
		if u.anchor != d.anchor do attr(w, "anchor", u.anchor)
		if u.margin != d.margin do attr(w, "margin", u.margin)
		if u.layout != d.layout do attr(w, "layout", u.layout)
		if u.align != d.align do attr(w, "align", u.align)
		if u.justify != d.justify do attr(w, "justify", u.justify)
		if u.columns != d.columns do attr(w, "columns", u.columns)
		if u.padding != d.padding do attr(w, "padding", u.padding)
		if u.spacing != d.spacing do attr(w, "spacing", u.spacing)
		if u.expand do attr(w, "expand", true)
		if u.disabled do attr(w, "disabled", true)
		if u.value != d.value do attr(w, "value", u.value)
		if u.minValue != d.minValue do attr(w, "min", u.minValue)
		if u.maxValue != d.maxValue do attr(w, "max", u.maxValue)
		if u.direction != d.direction do attr(w, "direction", u.direction)
		if u.showValue do attr(w, "showValue", true)
		if u.showLoading do attr(w, "showLoading", true)
		// A Slider's and a CheckBox's own (the parser reads them only for those kinds)
		if node.kind == .Slider && u.step != d.step do attr(w, "step", u.step)
		if node.kind == .CheckBox && u.checked do attr(w, "checked", true)
		if u.maxLength != 0 do attr(w, "maxLength", u.maxLength)
		if u.patchMargins != {} do attr(w, "patchMargins", fmt.tprintf("%v %v %v %v", u.patchMargins[0], u.patchMargins[1], u.patchMargins[2], u.patchMargins[3]))
		if u.textSize != 0 do attr(w, "textSize", u.textSize)
		if u.textAlign != d.textAlign do attr(w, "textAlign", u.textAlign)
		if u.theme != "" do attr(w, "theme", u.theme)
		if u.placeholder != "" do attr(w, "placeholder", u.placeholder)
		if u.action != "" do attr(w, "action", u.action)
	case .Animator:
		if node.animator.autoplay != "" do attr(w, "autoplay", node.animator.autoplay)
		if node.animator.speed != e.DEFAULT_ANIMATOR_SETTINGS.speed do attr(w, "speed", node.animator.speed)
	case .TileMap:
		t := node.tilemap
		attr(w, "tilemap", t.file)
		if t.frame != 0 do attr(w, "frame", t.frame)
		if t.layers != "" do attr(w, "layers", t.layers)
		if !t.collision do attr(w, "tileCollision", false)
		if t.animate do attr(w, "animate", true)
		if t.tag != "" do attr(w, "tag", t.tag)
		// The generated bodies'
		if t.collision {
			if node.collisionLayer != e.DEFAULT_SCENE_NODE.collisionLayer do attr(w, "collisionLayer", e.FormatPhysicsLayers(node.collisionLayer, context.temp_allocator))
			if node.collisionMask != e.DEFAULT_SCENE_NODE.collisionMask do attr(w, "collisionMask", e.FormatPhysicsLayers(node.collisionMask, context.temp_allocator))
			if node.friction != e.DEFAULT_SCENE_NODE.friction do attr(w, "friction", node.friction)
			if node.restitution != e.DEFAULT_SCENE_NODE.restitution do attr(w, "restitution", node.restitution)
		}
	case .LDtkLevel:
		l, d := node.ldtk, e.DEFAULT_LDTK_LEVEL_SETTINGS
		attr(w, "ldtk", l.file)
		if l.level != "" do attr(w, "level", l.level)
		if l.allLevels do attr(w, "allLevels", true)
		if l.collisionLayer != "" {
			attr(w, "intGridCollision", l.collisionLayer)
			// Solid, one-way and area values, each list only when it has some
			list :: proc(w: ^XMLWriter, key: string, values: []int) {
				if len(values) == 0 do return
				b := strings.builder_make(context.temp_allocator)
				for v, i in values do fmt.sbprintf(&b, "%s%d", i > 0 ? " " : "", v)
				attr(w, key, strings.to_string(b))
			}
			list(w, "collisionValues", l.collisionValues[:])
			list(w, "oneWayValues", l.oneWayValues[:])
			list(w, "areaValues", l.areaValues[:])
			// The generated StaticBody's
			if node.collisionLayer != e.DEFAULT_SCENE_NODE.collisionLayer do attr(w, "collisionLayer", e.FormatPhysicsLayers(node.collisionLayer, context.temp_allocator))
			if node.collisionMask != e.DEFAULT_SCENE_NODE.collisionMask do attr(w, "collisionMask", e.FormatPhysicsLayers(node.collisionMask, context.temp_allocator))
			if node.friction != e.DEFAULT_SCENE_NODE.friction do attr(w, "friction", node.friction)
			if node.restitution != e.DEFAULT_SCENE_NODE.restitution do attr(w, "restitution", node.restitution)
		}
		if l.spawnEntities != d.spawnEntities do attr(w, "spawnEntities", l.spawnEntities)
		if l.background != d.background do attr(w, "background", l.background)
		if l.smoothTiles != d.smoothTiles do attr(w, "smoothTiles", l.smoothTiles)
	case .AudioPlayer, .AudioPlayer2D, .MusicPlayer:
		a, d := node.audio, e.DEFAULT_AUDIO_SETTINGS
		if node.sound != "" do attr(w, "sound", node.sound)
		if node.bus != "" do attr(w, "bus", node.bus)
		if a.volume != d.volume do attr(w, "volume", a.volume)
		if a.pitch != d.pitch do attr(w, "pitch", a.pitch)
		if a.pan != d.pan do attr(w, "pan", a.pan)
		if a.loop do attr(w, "loop", true)
		if a.autostart do attr(w, "autostart", true)
		if node.kind == .AudioPlayer2D {
			if a.maxDistance != d.maxDistance do attr(w, "maxDistance", a.maxDistance)
			if a.attenuation != d.attenuation do attr(w, "attenuation", a.attenuation)
		}
		if node.kind == .MusicPlayer {
			if a.fadeIn != 0 do attr(w, "fadeIn", a.fadeIn)
			if a.fadeOut != 0 do attr(w, "fadeOut", a.fadeOut)
		}
	case .Node2D, .Menu, .ScreenEffect:
	}
}

// A Camera's follow target, follow settings, limits and shake (only what isn't the default)
@(private="file")
writeCamera :: proc(w: ^XMLWriter, node: ^NodeDef) {
	c, d := node.camera, e.DEFAULT_CAMERA_SETTINGS
	if node.cameraTarget != "" do attr(w, "target", node.cameraTarget)
	if c.follow.mode != d.follow.mode do attr(w, "followMode", c.follow.mode)
	if c.follow.smoothing != d.follow.smoothing do attr(w, "smoothing", c.follow.smoothing)
	if c.follow.smoothTime != d.follow.smoothTime do attr(w, "smoothTime", c.follow.smoothTime)
	if c.follow.speed != d.follow.speed do attr(w, "followSpeed", c.follow.speed)
	if c.follow.maxSpeed != d.follow.maxSpeed do attr(w, "maxSpeed", c.follow.maxSpeed)
	if c.follow.deadzone.x != d.follow.deadzone.x do attr(w, "deadzoneX", c.follow.deadzone.x)
	if c.follow.deadzone.y != d.follow.deadzone.y do attr(w, "deadzoneY", c.follow.deadzone.y)
	if c.follow.offset.x != d.follow.offset.x do attr(w, "targetOffsetX", c.follow.offset.x)
	if c.follow.offset.y != d.follow.offset.y do attr(w, "targetOffsetY", c.follow.offset.y)
	if c.follow.lookAhead.x != d.follow.lookAhead.x do attr(w, "lookAheadX", c.follow.lookAhead.x)
	if c.follow.lookAhead.y != d.follow.lookAhead.y do attr(w, "lookAheadY", c.follow.lookAhead.y)
	if c.follow.lookAheadSmoothing != d.follow.lookAheadSmoothing do attr(w, "lookAheadSmoothing", c.follow.lookAheadSmoothing)
	// A side's value is there when that side is limited, or when it's off with a value to keep
	// for when it's turned on again (listed in `limitsOff`)
	values := [e.CameraSide]f32{.Left = c.limitMin.x, .Top = c.limitMin.y, .Right = c.limitMax.x, .Bottom = c.limitMax.y}
	keys := [e.CameraSide]string{.Left = "limitLeft", .Top = "limitTop", .Right = "limitRight", .Bottom = "limitBottom"}
	off := strings.builder_make(context.temp_allocator)
	for side in e.CameraSide {
		if side not_in c.limits && values[side] == 0 do continue
		attr(w, keys[side], values[side])
		if side in c.limits do continue
		if strings.builder_len(off) > 0 do strings.write_byte(&off, ',')
		fmt.sbprint(&off, side)
	}
	if strings.builder_len(off) > 0 do attr(w, "limitsOff", strings.to_string(off))
	if c.shake.strength != d.shake.strength do attr(w, "shakeStrength", c.shake.strength)
	if c.shake.duration != d.shake.duration do attr(w, "shakeDuration", c.shake.duration)
	if c.shake.frequency != d.shake.frequency do attr(w, "shakeFrequency", c.shake.frequency)
}

// A shape's kind and size (a CollisionShape's, a LightOccluder's)
@(private="file")
writeShape :: proc(w: ^XMLWriter, node: ^NodeDef) {
	attr(w, "shape", node.shape)
	switch node.shape {
	case .Rectangle:
		attr(w, "width", node.shapeSize.x)
		attr(w, "height", node.shapeSize.y)
	case .Circle:
		attr(w, "radius", node.radius)
	case .Capsule:
		attr(w, "radius", node.radius)
		attr(w, "height", node.shapeSize.y)
	case .Polygon, .Segment:
		attr(w, "points", e.FormatPoints(node.points[:], context.temp_allocator))
	}
}
