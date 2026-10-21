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
	if project.icon != "" do attr(&w, "icon", project.icon)
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
	for bus, i in project.buses {
		if i == 0 && bus.volume == 1 && bus.pan == 0 && !bus.mute do continue
		open(&w, "bus")
		attr(&w, "name", bus.name)
		if bus.volume != 1 do attr(&w, "volume", bus.volume)
		if bus.pan != 0 do attr(&w, "pan", bus.pan)
		if bus.mute do attr(&w, "mute", true)
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
		if len(node.items) == 0 && node.script == "" && len(node.listeners) == 0 && len(particles) == 0 && len(animations) == 0 && len(entities) == 0 && !hasChildren {
			closeEmpty(&w)
			continue
		}
		endOpen(&w)
		// An AnimatedSprite's animations
		for a in animations do writeAnimation(&w, a)
		if len(particles) > 0 {
			open(&w, "particles")
			for pair in particles do attr(&w, pair.name, pair.value)
			closeEmpty(&w)
		}
		// An LDtkLevel's entity rules: only what isn't Auto
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

	close(&w, root)
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

/*
An `.anim.xml` file's text (an animation asset): the sheet on the root element, an `<animation>`
per animation. Deterministic, like scene files.
*/
AnimationSetToXML :: proc(set: ^AnimationSetDef, allocator := context.allocator) -> string {
	w := xmlWriter(allocator)
	open(&w, "animations")
	attr(&w, "formatVersion", e.PROJECT_FORMAT_VERSION)
	if set.texture != "" do attr(&w, "texture", set.texture)
	attr(&w, "columns", set.columns)
	attr(&w, "rows", set.rows)
	if set.margin != 0 do attr(&w, "margin", set.margin)
	if set.spacing != 0 do attr(&w, "spacing", set.spacing)
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

// An `<animation>`: `fps` always, the rest when not the default (durations in milliseconds)
@(private="file")
writeAnimation :: proc(w: ^XMLWriter, a: AnimationDef) {
	open(w, "animation")
	attr(w, "name", a.name)
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
	attr(w, "kind", node.kind)
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

	switch node.kind {
	case .Sprite:
		attr(w, "texture", node.texture)
	case .AnimatedSprite:
		attr(w, "texture", node.texture)
		attr(w, "columns", node.columns)
		attr(w, "rows", node.rows)
		if node.margin != 0 do attr(w, "margin", node.margin)
		if node.spacing != 0 do attr(w, "spacing", node.spacing)
		if node.autoplay != "" do attr(w, "autoplay", node.autoplay)
		if node.animationSet != "" do attr(w, "animations", node.animationSet)
	case .Label:
		attr(w, "text", node.text)
		attr(w, "fontSize", node.fontSize)
		attr(w, "color", e.FormatColor(node.color, context.temp_allocator))
		if node.centered != defaults.centered do attr(w, "centered", node.centered)
	case .Camera:
		if node.zoom != defaults.zoom do attr(w, "zoom", node.zoom)
	case .StaticBody, .DynamicBody, .CharacterMover, .Area:
		if node.collisionLayer != defaults.collisionLayer do attr(w, "collisionLayer", e.FormatPhysicsLayers(node.collisionLayer, context.temp_allocator))
		if node.collisionMask != defaults.collisionMask do attr(w, "collisionMask", e.FormatPhysicsLayers(node.collisionMask, context.temp_allocator))
		if node.kind != .Area {
			if node.friction != defaults.friction do attr(w, "friction", node.friction)
			if node.restitution != defaults.restitution do attr(w, "restitution", node.restitution)
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
		if node.disabled do attr(w, "disabled", true)
		if node.oneWay do attr(w, "oneWay", true)
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
	case .TileMap:
		t := node.tilemap
		attr(w, "tilemap", t.file)
		if t.frame != 0 do attr(w, "frame", t.frame)
		if t.layers != "" do attr(w, "layers", t.layers)
		if !t.collision do attr(w, "tileCollision", false)
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
	case .Node2D, .Menu:
	}
}
