package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "gui:skald"
import e "engine:."

/*
LDtk in the editor (the engine side: the engine's ldtk.odin and ldtk_nodes.odin).

- **Assets:** a `.ldtk` file is an asset of kind LDtk. Importing one from outside the project
  copies it into `assets/<name>/` with the files it needs (tileset images, separate level files,
  level backgrounds) at the same relative paths, so LDtk still opens the copy; files it reached
  with `../` go to `assets/<name>/external/` and the copy's JSON points there
  (`LDtkEdit_Import`). Keep editing the copy in LDtk: the viewport follows its saves.
- **Nodes:** an LDtkLevel node (Add Node, or drag the asset into the viewport) shows the level as
  the game draws it. The inspector picks the file, the level (or the whole world), the IntGrid
  layer that becomes collision and which of its values, whether entities are made, the
  background, smooth tiles, and per entity identifier the component its entities become. Open in
  LDtk starts LDtk on the file (Settings > Editor > LDtk program).
- **Reloading:** the editor's copy of a parsed file (`LDtkEdit_Project`, for the inspector) and
  the viewport's (the preview game's, `Game_LoadLDtk`) are read again when the file's
  modification time changes: save in LDtk, come back, and the level is current.
- **Exports** ship the files an LDtk asset needs along with it (`LDtkEdit_ExportFiles`).

Widget keys: `inspector-ldtk-file-<node>`, `inspector-ldtk-level-<node>`, `inspector-ldtk-all-<node>`,
`inspector-ldtk-collision-<node>`, `inspector-ldtk-values-<node>`, `inspector-ldtk-entities-<node>`,
`inspector-ldtk-background-<node>`, `inspector-ldtk-smooth-<node>`, `inspector-ldtk-component-<entity>-<node>`,
`inspector-ldtk-open-<node>`.
*/

// What an LDtk_Setting_Changed message changes
LDtkSettingField :: enum {
	File,
	Level,
	All_Levels,
	Collision_Layer,
	Collision_Values,
	Spawn_Entities,
	Background,
	Smooth_Tiles,
	// The component entities named `name` become (text; "" for none)
	Entity_Component,
}

// An LDtkLevel node's setting, from the inspector (strings only live for the frame)
LDtk_Setting_Changed :: struct {
	field: LDtkSettingField,
	text: string,
	flag: bool,
	// Entity_Component: the entity identifier
	name: string,
}

// Open the selected LDtkLevel node's file in LDtk
LDtk_Open_Requested :: struct {}

// A level clicked in the browser's world map (strings only live for the frame)
LDtk_Level_Picked :: struct {
	file, level: string,
}

// The choice for no level ("the first one") and no collision layer
LDTK_FIRST_LEVEL :: "(first level)"
LDTK_NO_LAYER :: "(none)"

// The folder imported LDtk projects go in, under assets/
@(private="file")
LDTK_EXTERNAL_FOLDER :: "external"

/*
A project file as parsed for the inspector, read again when the file changes (kept between
frames; nil when it can't be read).

Inputs:
- root: The project folder
- path: The .ldtk file, relative to it
*/
LDtkEdit_Project :: proc(root, path: string) -> ^e.LDtkProject {
	if path == "" do return nil
	full := joinPath(root, path, allocator = context.temp_allocator)
	modified := ldtkModified(full)
	if entry, found := &ldtkCache[full]; found {
		if entry.modified == modified do return entry.project
		e.LDtk_Destroy(entry.project)
		entry.project, _ = e.LDtk_Load(full)
		entry.modified = modified
		return entry.project
	}
	project, _ := e.LDtk_Load(full)
	ldtkCache[strings.clone(full)] = {project, modified}
	return project
}

// A file's modification time (zero when it's missing)
ldtkModified :: proc(path: string) -> time.Time {
	info, err := os.stat(path, context.temp_allocator)
	return err == nil ? info.modification_time : {}
}

// Frees the parsed projects (tests, quitting)
LDtkEdit_Destroy :: proc() {
	for path, entry in ldtkCache {
		e.LDtk_Destroy(entry.project)
		delete(path)
	}
	delete(ldtkCache)
	ldtkCache = nil
}

@(private="file")
LDtkCacheEntry :: struct {
	project: ^e.LDtkProject,
	modified: time.Time,
}

// Parsed projects by full path. Package state: the view reads them, and they're only a cache.
// Thread-local: the editor has one thread, but unit tests run on several, each with its own
// allocator
@(private="file", thread_local)
ldtkCache: map[string]LDtkCacheEntry

// A copy of an LDtkLevel node's settings (heap allocated)
LDtkSettings_Clone :: proc(settings: e.LDtkLevelSettings) -> e.LDtkLevelSettings {
	result := settings
	result.file = strings.clone(settings.file)
	result.level = strings.clone(settings.level)
	result.collisionLayer = strings.clone(settings.collisionLayer)
	result.collisionValues = make([dynamic]int)
	append(&result.collisionValues, ..settings.collisionValues[:])
	result.entityComponents = make([dynamic]e.LDtkEntityComponent)
	for m in settings.entityComponents do append(&result.entityComponents, e.LDtkEntityComponent{strings.clone(m.entity), strings.clone(m.component)})
	return result
}

// Whether two LDtkLevel nodes' settings are the same
LDtkSettings_Equal :: proc(a, b: e.LDtkLevelSettings) -> bool {
	if a.file != b.file || a.level != b.level || a.allLevels != b.allLevels || a.collisionLayer != b.collisionLayer ||
	   a.spawnEntities != b.spawnEntities || a.background != b.background || a.smoothTiles != b.smoothTiles ||
	   !slice.equal(a.collisionValues[:], b.collisionValues[:]) || len(a.entityComponents) != len(b.entityComponents) {
		return false
	}
	for m, i in a.entityComponents do if m != b.entityComponents[i] do return false
	return true
}

// The settings as text, for the viewport's rebuild signature (the file's modification time too:
// saving in LDtk rebuilds the level)
LDtkSettings_Signature :: proc(b: ^strings.Builder, root: string, settings: ^e.LDtkLevelSettings) {
	fmt.sbprintf(b, "%s|%s|%v|%s|%v|%v|%v|%v", settings.file, settings.level, settings.allLevels, settings.collisionLayer,
		settings.collisionValues[:], settings.spawnEntities, settings.background, settings.smoothTiles)
	for m in settings.entityComponents do fmt.sbprintf(b, "|%s=%s", m.entity, m.component)
	if settings.file != "" do fmt.sbprintf(b, "|%v", ldtkModified(joinPath(root, settings.file, allocator = context.temp_allocator)))
}

/*
Handles the LDtk messages.

Returns:
- A command to run, and whether `m` was one
*/
LDtkEdit_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case LDtk_Level_Picked:
		// The selected LDtkLevel node if it shows this file, else the scene's first that does
		scene := &state.project.scenes[state.currentScene]
		target := -1
		if node := selectedNode(state); node != nil && node.kind == .LDtkLevel && node.ldtk.file == v.file do target = state.selectedNode
		for &n, i in scene.nodes do if target < 0 && n.kind == .LDtkLevel && n.ldtk.file == v.file do target = i
		if target < 0 {
			logLine(state, .Info, fmt.aprintf("No LDtkLevel node shows %s in %s: drag it into the viewport to add one", filepath.base(v.file), scene.name))
			return {}, true
		}
		settings := &scene.nodes[target].ldtk
		delete(settings.level)
		settings.level = strings.clone(v.level)
		settings.allLevels = false
		state.selectedNode = target
	case LDtk_Setting_Changed:
		node := selectedNode(state)
		if node == nil || node.kind != .LDtkLevel do return {}, true
		settings := &node.ldtk
		switch v.field {
		case .File:
			delete(settings.file)
			settings.file = strings.clone(v.text == TEXTURE_NONE ? "" : v.text)
			// Another file's levels and layers have other names
			delete(settings.level)
			settings.level = strings.clone("")
		case .Level:
			delete(settings.level)
			settings.level = strings.clone(v.text == LDTK_FIRST_LEVEL ? "" : v.text)
		case .All_Levels:
			settings.allLevels = v.flag
		case .Collision_Layer:
			delete(settings.collisionLayer)
			settings.collisionLayer = strings.clone(v.text == LDTK_NO_LAYER ? "" : v.text)
		case .Collision_Values:
			clear(&settings.collisionValues)
			for part in strings.fields(v.text, context.temp_allocator) {
				if value, ok := strconv.parse_int(strings.trim(part, ",")); ok && value > 0 do append(&settings.collisionValues, value)
			}
		case .Spawn_Entities:
			settings.spawnEntities = v.flag
		case .Background:
			settings.background = v.flag
		case .Smooth_Tiles:
			settings.smoothTiles = v.flag
		case .Entity_Component:
			component := v.text == TEXTURE_NONE ? "" : v.text
			for &m, i in settings.entityComponents {
				if m.entity != v.name do continue
				delete(m.component)
				if component == "" {
					delete(m.entity)
					ordered_remove(&settings.entityComponents, i)
				} else {
					m.component = strings.clone(component)
				}
				return {}, true
			}
			if component != "" do append(&settings.entityComponents, e.LDtkEntityComponent{strings.clone(v.name), strings.clone(component)})
		}
	case LDtk_Asset_Open_Requested:
		if int(v) < 0 || int(v) >= len(state.project.assets) do return {}, true
		return LDtkEdit_OpenInLDtk(state, state.project.assets[v].path), true
	case LDtk_Open_Requested:
		node := selectedNode(state)
		if node == nil || node.kind != .LDtkLevel || node.ldtk.file == "" do return {}, true
		return LDtkEdit_OpenInLDtk(state, node.ldtk.file), true
	case:
		return {}, false
	}
	return {}, true
}

/*
Starts LDtk on a project file (Settings > Editor > LDtk program, else `ldtk` in PATH).
*/
LDtkEdit_OpenInLDtk :: proc(state: ^State, path: string) -> skald.Command(Msg) {
	setting := FixedText_String(&state.settings.ldtkPath)
	program, found := Script_FindEditorProgram(setting == "" ? "ldtk" : setting)
	if !found {
		logLine(state, .Error, fmt.aprintf("Couldn't find LDtk ('%s'). Get it from ldtk.io, then set its path in Settings > Editor", program))
		return {}
	}
	file := absolutePath(joinPath(state.project.rootPath, path, allocator = context.temp_allocator))
	process, err := os.process_start({command = {program, file}, working_dir = filepath.dir(file)})
	if err != nil {
		logLine(state, .Error, fmt.aprintf("Couldn't start LDtk (%s): %v", program, err))
		return {}
	}
	logLine(state, .Info, fmt.aprintf("Opened %s in LDtk", filepath.base(path)))
	return Editor_WatchProcess(process, program)
}

// The inspector's LDtkLevel rows
ldtkInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	settings := &node.ldtk
	onText :: proc(field: LDtkSettingField, value: string) -> Msg { return LDtk_Setting_Changed{field = field, text = value} }
	onFlag :: proc(field: LDtkSettingField, value: bool) -> Msg { return LDtk_Setting_Changed{field = field, flag = value} }
	flag :: proc(ctx: ^skald.Ctx(Msg), key: int, name: string, field: LDtkSettingField, value: bool) -> skald.View {
		return skald.checkbox(ctx, value, "", field, onFlag, id = skald.hash_id(fmt.tprintf("inspector-ldtk-%s-%d", name, key)))
	}
	small :: proc(ctx: ^skald.Ctx(Msg), text: string, color: skald.Color) -> skald.View {
		return skald.text(text, color, ctx.theme.font.size_xs, max_width = 260)
	}

	files := make([dynamic]string, context.temp_allocator)
	append(&files, TEXTURE_NONE)
	for asset in s.project.assets do if asset.kind == .LDtk do append(&files, asset.path)
	append(&rows, inspectorRow(ctx, "LDtk file", skald.select(ctx, settings.file == "" ? TEXTURE_NONE : settings.file, files[:],
		LDtkSettingField.File, onText, id = skald.hash_id(fmt.tprintf("inspector-ldtk-file-%d", key)), width = controlWidth)))
	if len(files) == 1 do append(&rows, small(ctx, "No LDtk projects yet: import a .ldtk file (File > Import Asset)", th.color.fg_muted))
	if settings.file == "" do return rows[:]

	project := LDtkEdit_Project(s.project.rootPath, settings.file)
	open := skald.button(ctx, fmt.tprintf("%s  Open in LDtk", ICON_MAP), Msg(LDtk_Open_Requested{}),
		id = skald.hash_id(fmt.tprintf("inspector-ldtk-open-%d", key)),
		bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	append(&rows, inspectorRow(ctx, "", open))
	if project == nil {
		append(&rows, small(ctx, fmt.tprintf("%s can't be read as an LDtk project.", settings.file), th.color.warning))
		return rows[:]
	}

	levels := make([dynamic]string, context.temp_allocator)
	append(&levels, LDTK_FIRST_LEVEL)
	for world in project.worlds do for level in world.levels do append(&levels, level.identifier)
	append(&rows,
		inspectorRow(ctx, "Level", skald.select(ctx, settings.level == "" ? LDTK_FIRST_LEVEL : settings.level, levels[:],
			LDtkSettingField.Level, onText, id = skald.hash_id(fmt.tprintf("inspector-ldtk-level-%d", key)), width = controlWidth)),
		inspectorRow(ctx, "Whole world", flag(ctx, key, "all", .All_Levels, settings.allLevels)),
	)
	level := settings.level == "" ? (len(project.worlds[0].levels) > 0 ? &project.worlds[0].levels[0] : nil) : e.LDtk_FindLevel(project, settings.level)
	if level == nil {
		if settings.level != "" do append(&rows, small(ctx, fmt.tprintf("%s has no level '%s'.", settings.file, settings.level), th.color.warning))
	} else {
		entities := 0
		for l in level.layers do entities += len(l.entities)
		append(&rows, small(ctx, fmt.tprintf("%s: %.0f x %.0f px, %d layers, %d entities", level.identifier, level.size.x, level.size.y, len(level.layers), entities), th.color.fg_muted))
		// What it builds: the level (or the world), as the viewport shows it
		append(&rows, ldtkThumbnailView(ctx, s, .Inspector, settings.file, settings.level, settings.allLevels, 260, 120))
	}

	// Collision from an IntGrid layer
	layers := make([dynamic]string, context.temp_allocator)
	append(&layers, LDTK_NO_LAYER)
	for def in project.layers do if def.type == .IntGrid do append(&layers, def.identifier)
	append(&rows, inspectorRow(ctx, "Collision", skald.select(ctx, settings.collisionLayer == "" ? LDTK_NO_LAYER : settings.collisionLayer, layers[:],
		LDtkSettingField.Collision_Layer, onText, id = skald.hash_id(fmt.tprintf("inspector-ldtk-collision-%d", key)), width = controlWidth)))
	if def := e.LDtk_FindLayerDef(project, settings.collisionLayer); def != nil {
		values := strings.builder_make(context.temp_allocator)
		for v, i in settings.collisionValues do fmt.sbprintf(&values, "%s%d", i > 0 ? " " : "", v)
		append(&rows, inspectorRow(ctx, "Values", skald.text_input(ctx, strings.to_string(values), LDtkSettingField.Collision_Values, onText,
			id = skald.hash_id(fmt.tprintf("inspector-ldtk-values-%d", key)), width = controlWidth, placeholder = "every value")))
		names := strings.builder_make(context.temp_allocator)
		for v, i in def.intGridValues do fmt.sbprintf(&names, "%s%d = %s", i > 0 ? ", " : "", v.value, v.identifier == "" ? "(unnamed)" : v.identifier)
		append(&rows, small(ctx, fmt.tprintf("Cells with these values become a StaticBody (%s)", strings.to_string(names)), th.color.fg_muted))
		// The StaticBody's layers, what it collides with, its surface
		append(&rows, ..bodySurfaceRows(ctx, s, node, key, controlWidth, numberWidth))
	}
	append(&rows,
		inspectorRow(ctx, "Entities", flag(ctx, key, "entities", .Spawn_Entities, settings.spawnEntities)),
		inspectorRow(ctx, "Background", flag(ctx, key, "background", .Background, settings.background)),
		inspectorRow(ctx, "Smooth tiles", flag(ctx, key, "smooth", .Smooth_Tiles, settings.smoothTiles)),
	)

	// What each entity becomes: a component, else a script named like it, else a rectangle
	if settings.spawnEntities && len(project.entities) > 0 {
		components := make([dynamic]string, context.temp_allocator)
		append(&components, TEXTURE_NONE)
		for asset in s.project.assets do if asset.kind == .Component do append(&components, asset.path)
		append(&rows, skald.text("Entity components", th.color.fg, th.font.size_sm))
		for def in project.entities {
			current := TEXTURE_NONE
			for m in settings.entityComponents do if m.entity == def.identifier do current = m.component
			append(&rows, inspectorRow(ctx, def.identifier, skald.select(ctx, current, components[:], strings.clone(def.identifier, context.temp_allocator),
				proc(entity: string, value: string) -> Msg { return LDtk_Setting_Changed{field = .Entity_Component, text = value, name = entity} },
				id = skald.hash_id(fmt.tprintf("inspector-ldtk-component-%s-%d", def.identifier, key)), width = controlWidth)))
		}
		append(&rows, small(ctx, "Without a component, an entity gets the script with its name, if there's one; its LDtk fields set the script's fields of the same name.", th.color.fg_muted))
	}
	return rows[:]
}

/*
Copies an LDtk project from outside the project into `assets/<name>/` with the files it needs.

Inputs:
- project: The project
- source: The .ldtk file

Returns:
- The copy's path relative to the project folder (temp allocated), or "" and what went wrong
*/
LDtkEdit_Import :: proc(project: ^Project, source: string) -> (string, string) {
	text, err := os.read_entire_file(source, context.temp_allocator)
	if err != nil do return "", fmt.tprintf("Couldn't read %s: %v", filepath.base(source), err)
	sourceDir := filepath.dir(source)
	stem := filepath.stem(filepath.base(source))
	folderName := stem
	assetsDir := joinPath(project.rootPath, ASSETS_FOLDER, allocator = context.temp_allocator)
	for i := 2; os.exists(joinPath(assetsDir, folderName, allocator = context.temp_allocator)); i += 1 do folderName = fmt.tprintf("%s_%d", stem, i)
	destDir := joinPath(assetsDir, folderName, allocator = context.temp_allocator)
	if mkErr := os.make_directory_all(destDir); mkErr != nil do return "", fmt.tprintf("Couldn't create %s: %v", destDir, mkErr)

	json := string(text)
	for dep in e.LDtk_Dependencies(json) {
		from := joinPath(sourceDir, dep, allocator = context.temp_allocator)
		if !os.exists(from) do continue
		target := dep
		// Outside the LDtk project's folder: into external/, and the copy points there
		if filepath.is_abs(dep) || strings.has_prefix(dep, "../") || strings.has_prefix(dep, "..\\") {
			target = fmt.tprintf("%s/%s", LDTK_EXTERNAL_FOLDER, filepath.base(dep))
			escaped, _ := strings.replace_all(dep, "/", "\\/", context.temp_allocator)
			for form in ([]string{dep, escaped}) {
				json, _ = strings.replace_all(json, fmt.tprintf("\"%s\"", form), fmt.tprintf("\"%s\"", target), context.temp_allocator)
			}
		}
		to := joinPath(destDir, target, allocator = context.temp_allocator)
		_ = os.make_directory_all(filepath.dir(to))
		if copyErr := os.copy_file(to, from); copyErr != nil do return "", fmt.tprintf("Couldn't copy %s: %v", dep, copyErr)
	}
	if writeErr := os.write_entire_file(joinPath(destDir, filepath.base(source), allocator = context.temp_allocator), transmute([]byte)json); writeErr != nil {
		return "", fmt.tprintf("Couldn't write the copy of %s: %v", filepath.base(source), writeErr)
	}
	return fmt.tprintf("%s/%s/%s", ASSETS_FOLDER, folderName, filepath.base(source)), ""
}

/*
The files the project's LDtk assets need besides themselves (relative to the project folder,
allocated with `allocator`): exports ship them.
*/
LDtkEdit_ExportFiles :: proc(project: ^Project, allocator := context.allocator) -> []string {
	files := make([dynamic]string, allocator)
	for asset in project.assets {
		if asset.kind != .LDtk do continue
		text, err := os.read_entire_file(joinPath(project.rootPath, asset.path, allocator = context.temp_allocator), context.temp_allocator)
		if err != nil do continue
		folder := filepath.dir(asset.path)
		for dep in e.LDtk_Dependencies(string(text)) {
			path := folder == "." ? dep : fmt.tprintf("%s/%s", folder, dep)
			cleaned, _ := filepath.clean(path, context.temp_allocator)
			cleaned = toSlashesPackage(cleaned)
			// Only what's inside the project (an export can't reach outside it)
			if strings.has_prefix(cleaned, "../") || filepath.is_abs(cleaned) do continue
			if !os.exists(joinPath(project.rootPath, cleaned, allocator = context.temp_allocator)) do continue
			known := false
			for f in files do if f == cleaned do known = true
			for a in project.assets do if a.path == cleaned do known = true
			if !known do append(&files, strings.clone(cleaned, allocator))
		}
	}
	return files[:]
}

@(private="file")
toSlashesPackage :: proc(path: string) -> string {
	s, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	return s
}

// Open an LDtk asset in LDtk (the browser's menu), by asset index
LDtk_Asset_Open_Requested :: distinct int

/*
The browser's preview of an LDtk asset: its worlds' levels (size, layers, entities), and Open in
LDtk.
*/
ldtkPreview :: proc(s: ^State, ctx: ^skald.Ctx(Msg), asset: AssetDef, path: string) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	project := LDtkEdit_Project(s.project.rootPath, asset.path)
	// The whole world, as the game draws it
	picture: skald.View = skald.spacer(0)
	if project != nil do picture = ldtkThumbnailView(ctx, s, .Browser, asset.path, "", true, 0, 0)
	append(&rows, skald.text(fmt.tprintf("%s  %s", ICON_MAP, filepath.base(asset.path)), th.color.fg, th.font.size_sm, max_width = previewTextWidth))
	if project == nil {
		append(&rows, skald.text("This file can't be read as an LDtk project.", th.color.danger, th.font.size_xs, max_width = previewTextWidth))
	} else {
		levels := 0
		for world in project.worlds do levels += len(world.levels)
		append(&rows, skald.text(fmt.tprintf("LDtk %s · %d level%s · %d tileset%s", project.jsonVersion, levels, levels == 1 ? "" : "s",
			len(project.tilesets), len(project.tilesets) == 1 ? "" : "s"), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
		for world in project.worlds {
			if len(project.worlds) > 1 do append(&rows, skald.text(fmt.tprintf("%s (%v)", world.identifier, world.layout), th.color.fg, th.font.size_xs, max_width = previewTextWidth))
			for level in world.levels {
				entities := 0
				for l in level.layers do entities += len(l.entities)
				append(&rows, skald.text(fmt.tprintf("%s  %.0f x %.0f · %d layers · %d entities", level.identifier, level.size.x, level.size.y,
					len(level.layers), entities), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
			}
		}
		append(&rows, skald.text("Drag it into the viewport to add a level, or add an LDtkLevel node.", th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
	}
	index := -1
	for a, i in s.project.assets do if a.path == asset.path do index = i
	append(&rows, skald.button(ctx, fmt.tprintf("%s  Open in LDtk", ICON_MAP), Msg(LDtk_Asset_Open_Requested(index)),
		id = skald.hash_id("browser-ldtk-open"), bg = th.color.surface, fg = th.color.fg,
		padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm))
	return skald.col(
		skald.flex(3, picture),
		skald.flex(2, skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.sm), id = skald.hash_id("browser-ldtk-preview"))),
		cross_align = .Stretch,
	)
}

/*
Adds an LDtkLevel node for an LDtk asset where it was dropped in the viewport: the level's
top-left corner there (the first level; the inspector picks another).

Returns:
- The new node's index
*/
Scene_AddLDtkAt :: proc(scene: ^SceneDef, path: string, parent: int, world: [2]f32) -> int {
	parent := parent
	if parent >= len(scene.nodes) do parent = -1
	index := Scene_InsertNode(scene, Scene_UniqueNodeName(scene, "Level"), .LDtkLevel, parent)
	node := &scene.nodes[index]
	delete(node.ldtk.file)
	node.ldtk.file = strings.clone(path)
	parentWorld := parent >= 0 ? Scene_WorldTransforms(scene)[parent] : e.TRANSFORM2D_IDENTITY
	local := e.Transform2D_Apply(e.Transform2D_Inverse(parentWorld), world)
	node.position = {f32(int(local.x)), f32(int(local.y))}
	return index
}

// The Skald images LDtk pictures are uploaded to, and what each holds
@(private="file")
LDTK_IMAGES := [LDtkThumbnailSlot]string{.Browser = "ldtk-thumbnail-browser", .Inspector = "ldtk-thumbnail-inspector"}
@(private="file")
ldtkImageKeys: [LDtkThumbnailSlot]u64
@(private="file")
ldtkImageSizes: [LDtkThumbnailSlot][2]int

/*
A picture of an LDtk level (or the whole world) filling the space it gets (Preview_RenderLDtk;
re-uploaded only when the picture changes).

Inputs:
- height: 0 to flex (fill what the parent gives)
*/
ldtkThumbnailView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, slot: LDtkThumbnailSlot, file, level: string, allLevels: bool, width, height: f32) -> skald.View {
	Data :: struct {
		s: ^State,
		slot: LDtkThumbnailSlot,
		file, level: string,
		allLevels: bool,
	}
	data := new_clone(Data{s, slot, strings.clone(file, context.temp_allocator), strings.clone(level, context.temp_allocator), allLevels}, context.temp_allocator)
	picture := skald.sized(ctx, data, proc(ctx: ^skald.Ctx(Msg), d: ^Data, size: [2]f32) -> skald.View {
		pixelSize := [2]int{max(int(size.x), 1), max(int(size.y), 1)}
		pixels, key, ok := Preview_RenderLDtk(d.s, d.slot, d.file, d.level, d.allLevels, pixelSize)
		if ok && ctx.renderer != nil && (key != ldtkImageKeys[d.slot] || pixelSize != ldtkImageSizes[d.slot]) {
			if pixelSize == ldtkImageSizes[d.slot] do skald.image_update_pixels(ctx.renderer, LDTK_IMAGES[d.slot], u32(pixelSize.x), u32(pixelSize.y), pixels)
			else do skald.image_load_pixels(ctx.renderer, LDTK_IMAGES[d.slot], u32(pixelSize.x), u32(pixelSize.y), pixels)
			ldtkImageKeys[d.slot], ldtkImageSizes[d.slot] = key, pixelSize
		}
		// The browser's world map: hovering a level outlines it, a click picks it for the selected
		// LDtkLevel node (LDtk_Level_Picked)
		id := skald.hash_id(fmt.tprintf("ldtk-map-%v", d.slot))
		hovered: [4]f32
		hovering := false
		if d.slot == .Browser {
			if state, drawn := ctx.widgets.states[id]; drawn && skald.widget_hovered(ctx, id) && len(ctx.widgets.overlay_rects_prev) == 0 {
				local := ctx.input.mouse_pos - {state.last_rect.x, state.last_rect.y}
				if identifier, rect, ok := Preview_LDtkLevelAt(d.slot, local); ok {
					hovered, hovering = rect, true
					if ctx.input.mouse_pressed[.Left] do skald.send(ctx, Msg(LDtk_Level_Picked{file = strings.clone(d.file, context.temp_allocator), level = strings.clone(identifier, context.temp_allocator)}))
				}
			}
		}
		Paint :: struct { slot: LDtkThumbnailSlot, hovered: [4]f32, hovering: bool, color: skald.Color }
		paint := new_clone(Paint{d.slot, hovered, hovering, ctx.theme.color.primary}, context.temp_allocator)
		return skald.canvas(ctx, paint, proc(p: ^Paint, painter: skald.Canvas_Painter) {
			skald.draw_image(painter.r, LDTK_IMAGES[p.slot], painter.bounds, .Fill)
			if p.hovering {
				b := painter.bounds
				skald.draw_rect_outline(painter.r, {b.x + p.hovered[0], b.y + p.hovered[1], p.hovered[2], p.hovered[3]}, 2, p.color)
			}
		}, id = id, width = max(size.x, 1), height = max(size.y, 1), cursor = d.slot == .Browser && hovering ? .Pointer : .Default)
	})
	if height <= 0 do return skald.flex(1, picture)
	return skald.col(picture, width = width, height = height)
}
