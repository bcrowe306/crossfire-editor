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
`inspector-ldtk-collision-<node>`, `inspector-ldtk-value-<value>-<node>` (what an IntGrid value becomes),
`inspector-ldtk-entities-<node>`, `inspector-ldtk-background-<node>`, `inspector-ldtk-smooth-<node>`,
`inspector-ldtk-component-<entity>-<node>` (what it becomes), `inspector-ldtk-script-<entity>-<node>`
(the script it runs), `inspector-ldtk-open-<node>`.
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
	// What entities named `name` become (text: a LDTK_MAKE_LABELS label, or a component's path)
	Entity_Make,
	// The script they run (text: LDTK_SCRIPT_AUTO, LDTK_SCRIPT_NONE or a script's name)
	Entity_Script,
	// What the collision layer's value `name` becomes (text: a LDTK_KIND_LABELS label)
	Collision_Value_Kind,
}

// The inspector's choices of what an entity type becomes (with the project's components after)
LDTK_MAKE_LABELS := [e.LDtkEntityMake]string{
	.Auto      = "Auto",
	.Component = "",
	.Code      = "Code (LDtk_RegisterEntity)",
	.Rectangle = "Its rectangle",
	.Skip      = "Nothing (skipped)",
}
LDTK_SCRIPT_AUTO :: "Auto (named like it)"
LDTK_SCRIPT_NONE :: "No script"
// The inspector's choices of what a collision value becomes
LDTK_KIND_LABELS := [e.LDtkCollisionKind]string{
	.None    = "Nothing",
	.Solid   = "Solid",
	.One_Way = "One-way platform",
	.Area    = "Area (a trigger)",
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
	// The file, or the Level mode's unsaved edits of it (ldtk_doc.odin)
	stamp := LDtkDoc_Stamp(root, path)
	load :: proc(root, path, full: string) -> ^e.LDtkProject {
		if LDtkDoc_IsUnsaved(root, path) {
			if doc := LDtkDoc_Get(root, path); doc != nil && doc.problem == "" {
				project, _ := e.LDtk_Parse(LDtkDoc_GameText(doc), full)
				return project
			}
		}
		project, _ := e.LDtk_Load(full)
		return project
	}
	if entry, found := &ldtkCache[full]; found {
		if entry.stamp == stamp do return entry.project
		e.LDtk_Destroy(entry.project)
		entry.project = load(root, path, full)
		entry.stamp = stamp
		return entry.project
	}
	project := load(root, path, full)
	ldtkCache[strings.clone(full)] = {project, stamp}
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
	// `LDtkDoc_Stamp`: the file's time, or the unsaved document's version
	stamp: u64,
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
	result.oneWayValues = make([dynamic]int)
	append(&result.oneWayValues, ..settings.oneWayValues[:])
	result.areaValues = make([dynamic]int)
	append(&result.areaValues, ..settings.areaValues[:])
	result.entityComponents = make([dynamic]e.LDtkEntityComponent)
	for m in settings.entityComponents do append(&result.entityComponents, e.LDtkEntityComponent{strings.clone(m.entity), strings.clone(m.component), m.make, strings.clone(m.script), m.noScript})
	return result
}

// Whether two LDtkLevel nodes' settings are the same
LDtkSettings_Equal :: proc(a, b: e.LDtkLevelSettings) -> bool {
	if a.file != b.file || a.level != b.level || a.allLevels != b.allLevels || a.collisionLayer != b.collisionLayer ||
	   a.spawnEntities != b.spawnEntities || a.background != b.background || a.smoothTiles != b.smoothTiles ||
	   !slice.equal(a.collisionValues[:], b.collisionValues[:]) || !slice.equal(a.oneWayValues[:], b.oneWayValues[:]) ||
	   !slice.equal(a.areaValues[:], b.areaValues[:]) || len(a.entityComponents) != len(b.entityComponents) {
		return false
	}
	for m, i in a.entityComponents do if m != b.entityComponents[i] do return false
	return true
}

// The settings as text, for the viewport's rebuild signature (the file's stamp too: saving in LDtk
// rebuilds the level, and so does an unsaved edit in the Level mode)
LDtkSettings_Signature :: proc(b: ^strings.Builder, root: string, settings: ^e.LDtkLevelSettings) {
	// Every setting the build reads: the kinds' lists (one-way to an area changes no other) and
	// each entity rule whole
	fmt.sbprintf(b, "%s|%s|%v|%s|%v|%v|%v|%v|%v|%v", settings.file, settings.level, settings.allLevels, settings.collisionLayer,
		settings.collisionValues[:], settings.oneWayValues[:], settings.areaValues[:], settings.spawnEntities, settings.background, settings.smoothTiles)
	for m in settings.entityComponents do fmt.sbprintf(b, "|%s=%s,%v,%s,%v", m.entity, m.component, m.make, m.script, m.noScript)
	if settings.file != "" do fmt.sbprintf(b, "|%v", LDtkDoc_Stamp(root, settings.file))
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
			rule := ldtkRule(settings, v.name)
			delete(rule.component)
			rule.component = strings.clone(v.text == TEXTURE_NONE ? "" : v.text)
			if rule.component != "" && rule.make != .Auto do rule.make = .Component
			ldtkDropDefaultRules(settings)
		case .Entity_Make:
			rule := ldtkRule(settings, v.name)
			found := false
			for label, make in LDTK_MAKE_LABELS do if label != "" && label == v.text {
				rule.make = make
				found = true
				// Auto keeps no component: the mapped one would make it a component again
				if make != .Component {
					delete(rule.component)
					rule.component = ""
				}
			}
			// A component's path
			if !found {
				rule.make = .Component
				delete(rule.component)
				rule.component = strings.clone(v.text)
			}
			ldtkDropDefaultRules(settings)
		case .Entity_Script:
			rule := ldtkRule(settings, v.name)
			delete(rule.script)
			rule.script, rule.noScript = "", false
			switch v.text {
			case LDTK_SCRIPT_AUTO:
			case LDTK_SCRIPT_NONE: rule.noScript = true
			case: rule.script = strings.clone(v.text)
			}
			ldtkDropDefaultRules(settings)
		case .Collision_Value_Kind:
			value, ok := strconv.parse_int(v.name)
			if !ok do break
			kind := e.LDtkCollisionKind.None
			for label, k in LDTK_KIND_LABELS do if label == v.text do kind = k
			LDtkEdit_SetCollisionKind(state, settings, value, kind)
		}
	case LDtk_Asset_Open_Requested:
		if int(v) < 0 || int(v) >= len(state.project.assets) do return {}, true
		path := state.project.assets[v].path
		// The Level mode's selected level (an entity's: its level)
		level := state.mode == .Level && path == LevelMode_File(state) ? state.level.level : ""
		return LDtkEdit_OpenInLDtk(state, path, level), true
	case LDtk_Open_Requested:
		node := selectedNode(state)
		if node == nil || node.kind != .LDtkLevel || node.ldtk.file == "" do return {}, true
		return LDtkEdit_OpenInLDtk(state, node.ldtk.file, node.ldtk.allLevels ? "" : node.ldtk.level), true
	case:
		return {}, false
	}
	return {}, true
}

/*
Starts LDtk on a project file (Settings > Editor > LDtk program, else `ldtk` in PATH; the Level
mode's unsaved edits of it are saved first), at a level
when one is given: LDtk's command line takes only the file, but when it opens a project it selects
the level its settings remember (`lastProject.levelUid`), so that's set first
(`LDtk_RememberLevel`). An entity can't be selected that way: LDtk opens at its level.

Inputs:
- path: The .ldtk file, relative to the project
- level: A level's identifier or iid ("" LDtk's own choice)
*/
LDtkEdit_OpenInLDtk :: proc(state: ^State, path: string, level := "") -> skald.Command(Msg) {
	setting := FixedText_String(&state.settings.ldtkPath)
	program, found := Script_FindEditorProgram(setting == "" ? "ldtk" : setting)
	if !found {
		logLine(state, .Error, fmt.aprintf("Couldn't find LDtk ('%s'). Get it from ldtk.io, then set its path in Settings > Editor", program))
		return {}
	}
	// LDtk reads the file: the Level mode's unsaved edits are written first (ldtk_doc.odin)
	if LDtkDoc_IsUnsaved(state.project.rootPath, path) {
		if problem := LDtkDoc_Save(state.project.rootPath, path); problem != "" {
			logLine(state, .Error, fmt.aprintf("Not opened in LDtk: couldn't save %s first: %s", filepath.base(path), problem))
			return {}
		}
		logLine(state, .Info, fmt.aprintf("Saved %s for LDtk", filepath.base(path)))
	}
	file := absolutePath(joinPath(state.project.rootPath, path, allocator = context.temp_allocator))
	if level != "" {
		if doc := LDtkDoc_Get(state.project.rootPath, path); doc != nil && doc.problem == "" {
			if index := LDtkDoc_FindLevel(doc, level); index >= 0 {
				main := LDtkDoc_Main(doc)
				uid := Json_Int(main, Json_Get(main, doc.levels[index].entry, "uid"), -1)
				if problem := LDtk_RememberLevel(LDtk_SettingsPath(), file, uid); problem != "" do logLine(state, .Warning, fmt.aprintf("LDtk will open at its own choice of level: %s", problem))
			}
		}
	}
	process, err := os.process_start({command = {program, file}, working_dir = filepath.dir(file)})
	if err != nil {
		logLine(state, .Error, fmt.aprintf("Couldn't start LDtk (%s): %v", program, err))
		return {}
	}
	logLine(state, .Info, level != "" ? fmt.aprintf("Opened %s in LDtk at %s", filepath.base(path), level) : fmt.aprintf("Opened %s in LDtk", filepath.base(path)))
	return Editor_WatchProcess(process, program)
}

/*
LDtk's settings file: Electron's user data folder for LDtk (Linux `$XDG_CONFIG_HOME` or
`~/.config`, macOS `~/Library/Application Support`, Windows `%APPDATA%`) + `/LDtk/settings/settings.cfg`.
`CROSSFIRE_LDTK_SETTINGS` names another file (the tests').

Returns:
- The path (temp allocated; "" when there's no home folder to look in)
*/
LDtk_SettingsPath :: proc() -> string {
	if override := os.get_env("CROSSFIRE_LDTK_SETTINGS", context.temp_allocator); override != "" do return override
	base := ""
	when ODIN_OS == .Windows {
		base = os.get_env("APPDATA", context.temp_allocator)
	} else when ODIN_OS == .Darwin {
		if home := os.get_env("HOME", context.temp_allocator); home != "" do base = joinPath(home, "Library/Application Support", allocator = context.temp_allocator)
	} else {
		base = os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
		if base == "" do if home := os.get_env("HOME", context.temp_allocator); home != "" do base = joinPath(home, ".config", allocator = context.temp_allocator)
	}
	if base == "" do return ""
	return joinPath(base, "LDtk/settings/settings.cfg", allocator = context.temp_allocator)
}

/*
Sets the level LDtk opens a project at: its settings' `lastProject` (`{filePath, levelUid}`, which
LDtk's editor reads when it opens any project: page/Editor.hx), written atomically, nothing else
touched. LDtk must not be running with the file open (it keeps its own copy of the settings and
writes it back).

Inputs:
- settings: LDtk's settings file (`LDtk_SettingsPath`)
- file: The project's full path
- levelUid: The level's uid

Returns:
- "" or what went wrong (no settings file: LDtk was never started; nothing is written)
*/
LDtk_RememberLevel :: proc(settings, file: string, levelUid: int) -> string {
	if settings == "" || levelUid < 0 do return "no LDtk settings folder"
	text, err := os.read_entire_file(settings, context.temp_allocator)
	if err != nil do return "LDtk's settings file isn't there yet (start LDtk once)"
	doc, problem := Json_Parse(string(text), context.temp_allocator)
	if problem != "" do return fmt.tprintf("LDtk's settings aren't JSON: %s", problem)
	slashed, _ := strings.replace_all(file, "\\", "/", context.temp_allocator)
	value := Json_Object(Json_Minified(&doc), {"filePath", Json_Quote(slashed)}, {"levelUid", fmt.tprint(levelUid)})
	root := Json_Root(&doc)
	if Json_Kind(&doc, root) != .Object do return "LDtk's settings aren't an object"
	patch: JsonPatch
	if last := Json_Get(&doc, root, "lastProject"); last >= 0 {
		patch = Json_SetPatch(&doc, last, value)
	} else {
		patch = Json_AddMemberPatch(&doc, root, "lastProject", value)
	}
	updated, ok := Json_Apply(doc.text, {patch}, context.temp_allocator)
	if !ok do return "couldn't change LDtk's settings"
	return LDtk_WriteFile(settings, updated, ldtkModified(settings))
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
		// What it builds: the level (or the world), as the viewport shows it, and what it is
		append(&rows, ldtkThumbnailView(ctx, s, .Inspector, settings.file, settings.level, settings.allLevels, 260, 120))
		append(&rows, ..ldtkLevelRows(ctx, s, project, settings, inspectorRowWidth(controlWidth)))
	}

	// Collision from an IntGrid layer
	layers := make([dynamic]string, context.temp_allocator)
	append(&layers, LDTK_NO_LAYER)
	for def in project.layers do if def.type == .IntGrid do append(&layers, def.identifier)
	append(&rows, inspectorRow(ctx, "Collision", skald.select(ctx, settings.collisionLayer == "" ? LDTK_NO_LAYER : settings.collisionLayer, layers[:],
		LDtkSettingField.Collision_Layer, onText, id = skald.hash_id(fmt.tprintf("inspector-ldtk-collision-%d", key)), width = controlWidth)))
	if def := e.LDtk_FindLayerDef(project, settings.collisionLayer); def != nil {
		// What each value becomes
		kinds := make([dynamic]string, context.temp_allocator)
		for label in LDTK_KIND_LABELS do append(&kinds, label)
		for v in def.intGridValues {
			label := v.identifier != "" ? fmt.tprintf("%d %s", v.value, v.identifier) : fmt.tprintf("Value %d", v.value)
			append(&rows, inspectorRow(ctx, label, skald.select(ctx, LDTK_KIND_LABELS[e.LDtk_CollisionKind(settings, v.value)], kinds[:], fmt.tprint(v.value),
				proc(value: string, kind: string) -> Msg { return LDtk_Setting_Changed{field = .Collision_Value_Kind, text = kind, name = value} },
				id = skald.hash_id(fmt.tprintf("inspector-ldtk-value-%d-%d", v.value, key)), width = controlWidth)))
		}
		append(&rows, small(ctx, "Solid and one-way cells become one StaticBody; each area value an Area named after it.", th.color.fg_muted))
		// The StaticBody's layers, what it collides with, its surface
		append(&rows, ..bodySurfaceRows(ctx, s, node, key, controlWidth, numberWidth))
	}
	append(&rows,
		inspectorRow(ctx, "Entities", flag(ctx, key, "entities", .Spawn_Entities, settings.spawnEntities)),
		inspectorRow(ctx, "Background", flag(ctx, key, "background", .Background, settings.background)),
		inspectorRow(ctx, "Smooth tiles", flag(ctx, key, "smooth", .Smooth_Tiles, settings.smoothTiles)),
	)
	width := inspectorRowWidth(controlWidth)
	// How the engine builds it: each layer and what it becomes
	append(&rows, ..ldtkBuildRows(ctx, s, project, settings, width))

	// What each entity type becomes and why, with its component choice
	if settings.spawnEntities && len(project.entities) > 0 {
		// What it becomes: the choices, then the project's components
		makes := make([dynamic]string, context.temp_allocator)
		for m in ([]e.LDtkEntityMake{.Auto, .Rectangle, .Code, .Skip}) do append(&makes, LDTK_MAKE_LABELS[m])
		for asset in s.project.assets do if asset.kind == .Component do append(&makes, asset.path)
		// The script it runs
		scripts := make([dynamic]string, context.temp_allocator)
		append(&scripts, LDTK_SCRIPT_AUTO, LDTK_SCRIPT_NONE)
		for desc in s.scripts.scripts do append(&scripts, desc.name)
		// How many of each, in the levels built, and one to read its fields from
		placed, _ := e.LDtk_PlacedLevels(project, settings^, context.temp_allocator)
		counts := make(map[string]int, context.temp_allocator)
		samples := make(map[string]^e.LDtkEntity, context.temp_allocator)
		for p in placed do for l in p.level.layers do for &entity in l.entities {
			counts[entity.identifier] += 1
			if entity.identifier not_in samples do samples[entity.identifier] = &entity
		}
		append(&rows, skald.text(fmt.tprintf("%s  Entities", ICON_CUBES), th.color.fg, th.font.size_sm))
		for def in project.entities {
			rule := e.LDtk_EntityRule(settings, def.identifier)
			becomes := rule.component != "" && (rule.make == .Auto || rule.make == .Component) ? rule.component : LDTK_MAKE_LABELS[rule.make == .Component ? .Auto : rule.make]
			runs := rule.noScript ? LDTK_SCRIPT_NONE : (rule.script != "" ? rule.script : LDTK_SCRIPT_AUTO)
			// A script the catalog doesn't know (not built yet) stays choosable
			choices := scripts[:]
			if !slice.contains(choices, runs) {
				more := make([dynamic]string, context.temp_allocator)
				append(&more, ..choices)
				append(&more, runs)
				choices = more[:]
			}
			entity := strings.clone(def.identifier, context.temp_allocator)
			append(&rows, skald.text(fmt.tprintf("%s ×%d", def.identifier, counts[def.identifier]), th.color.fg, th.font.size_sm))
			append(&rows, inspectorRow(ctx, "Becomes", labeledSelect(ctx, becomes, Asset_DisplayNames(makes[:]), makes[:], entity,
				proc(entity: string, value: string) -> Msg { return LDtk_Setting_Changed{field = .Entity_Make, text = value, name = entity} },
				id = skald.hash_id(fmt.tprintf("inspector-ldtk-component-%s-%d", def.identifier, key)), width = controlWidth)))
			append(&rows, inspectorRow(ctx, "Runs", skald.select(ctx, runs, choices, entity,
				proc(entity: string, value: string) -> Msg { return LDtk_Setting_Changed{field = .Entity_Script, text = value, name = entity} },
				id = skald.hash_id(fmt.tprintf("inspector-ldtk-script-%s-%d", def.identifier, key)), width = controlWidth)))
			lines, bare := LDtkEdit_EntityPlan(s, settings, def.identifier, samples[def.identifier])
			for line in lines do append(&rows, skald.text(line, bare ? th.color.warning : th.color.fg_muted, th.font.size_xs, max_width = width))
		}
	}
	append(&rows, ..ldtkInstanceRows(ctx, s, s.selectedNode, project, settings, width))
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
	parent = Scene_ParentFor(scene, parent)
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
re-uploaded only when the picture changes). On the browser's world map (`.Browser`) hovering a
level outlines it and a click picks it (`LDtk_Level_Picked`: the selected LDtkLevel node's, or the
Level mode's while it shows). The Level mode's own canvas is level_canvas.odin.

Inputs:
- height: 0 to flex (fill what the parent gives)
- selected: The level outlined in the accent color ("" none)
*/
ldtkThumbnailView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, slot: LDtkThumbnailSlot, file, level: string, allLevels: bool, width, height: f32, selected := "") -> skald.View {
	Data :: struct {
		s: ^State,
		slot: LDtkThumbnailSlot,
		file, level, selected: string,
		allLevels: bool,
	}
	data := new_clone(Data{s, slot, strings.clone(file, context.temp_allocator), strings.clone(level, context.temp_allocator), strings.clone(selected, context.temp_allocator), allLevels}, context.temp_allocator)
	picture := skald.sized(ctx, data, proc(ctx: ^skald.Ctx(Msg), d: ^Data, size: [2]f32) -> skald.View {
		pixelSize := [2]int{max(int(size.x), 1), max(int(size.y), 1)}
		pixels, key, ok := Preview_RenderLDtk(d.s, d.slot, d.file, d.level, d.allLevels, pixelSize)
		if ok && ctx.renderer != nil && (key != ldtkImageKeys[d.slot] || pixelSize != ldtkImageSizes[d.slot]) {
			if pixelSize == ldtkImageSizes[d.slot] do skald.image_update_pixels(ctx.renderer, LDTK_IMAGES[d.slot], u32(pixelSize.x), u32(pixelSize.y), pixels)
			else do skald.image_load_pixels(ctx.renderer, LDTK_IMAGES[d.slot], u32(pixelSize.x), u32(pixelSize.y), pixels)
			ldtkImageKeys[d.slot], ldtkImageSizes[d.slot] = key, pixelSize
		}
		// The browser's world map: hovering a level outlines it, a click picks it (LDtk_Level_Picked)
		id := skald.hash_id(fmt.tprintf("ldtk-map-%v", d.slot))
		hovered: [4]f32
		hovering := false
		if d.slot == .Browser {
			if state, drawn := ctx.widgets.states[id]; drawn && skald.widget_hovered(ctx, id) && len(ctx.widgets.overlay_rects_prev) == 0 {
				local := ctx.input.mouse_pos - {state.last_rect.x, state.last_rect.y}
				identifier, rect, onLevel := Preview_LDtkLevelAt(d.slot, local)
				if onLevel do hovered, hovering = rect, true
				if ctx.input.mouse_pressed[.Left] && onLevel {
					skald.send(ctx, Msg(LDtk_Level_Picked{file = strings.clone(d.file, context.temp_allocator), level = strings.clone(identifier, context.temp_allocator)}))
				}
			}
		}
		chosen, hasChosen := Preview_LDtkLevelRect(d.slot, d.selected)
		Paint :: struct { slot: LDtkThumbnailSlot, hovered, chosen: [4]f32, hovering, hasChosen: bool, color: skald.Color }
		paint := new_clone(Paint{d.slot, hovered, chosen, hovering, hasChosen && d.selected != "", ctx.theme.color.primary}, context.temp_allocator)
		return skald.canvas(ctx, paint, proc(p: ^Paint, painter: skald.Canvas_Painter) {
			skald.draw_image(painter.r, LDTK_IMAGES[p.slot], painter.bounds, .Fill)
			b := painter.bounds
			if p.hasChosen do skald.draw_rect_outline(painter.r, {b.x + p.chosen[0] - 1, b.y + p.chosen[1] - 1, p.chosen[2] + 2, p.chosen[3] + 2}, 3, p.color)
			if p.hovering do skald.draw_rect_outline(painter.r, {b.x + p.hovered[0], b.y + p.hovered[1], p.hovered[2], p.hovered[3]}, 2, p.color)
		}, id = id, width = max(size.x, 1), height = max(size.y, 1), cursor = d.slot == .Browser && hovering ? .Pointer : .Default)
	})
	if height <= 0 do return skald.flex(1, picture)
	return skald.col(picture, width = width, height = height)
}

// The node's rule for an entity type, added (Auto) when it has none
@(private="file")
ldtkRule :: proc(settings: ^e.LDtkLevelSettings, entity: string) -> ^e.LDtkEntityRule {
	for &m in settings.entityComponents do if m.entity == entity do return &m
	append(&settings.entityComponents, e.LDtkEntityRule{entity = strings.clone(entity)})
	return &settings.entityComponents[len(settings.entityComponents) - 1]
}

// Drops the rules that say nothing (Auto, no component, no script): the scene file stays short
@(private="file")
ldtkDropDefaultRules :: proc(settings: ^e.LDtkLevelSettings) {
	#reverse for m, i in settings.entityComponents {
		if m.make != .Auto || m.component != "" || m.script != "" || m.noScript do continue
		delete(m.entity)
		delete(m.component)
		delete(m.script)
		ordered_remove(&settings.entityComponents, i)
	}
}

/*
Sets what a value of the collision layer becomes, keeping the others as they are now: the lists
(`collisionValues` solid, `oneWayValues`, `areaValues`) are written out from every value's kind.
When every value is solid, no list is kept (the engine's default: every value solid).

Inputs:
- state: The editor state (the project's LDtk file, for the layer's values)
- settings: The LDtkLevel node's settings
- value: The IntGrid value
- kind: What it becomes
*/
LDtkEdit_SetCollisionKind :: proc(state: ^State, settings: ^e.LDtkLevelSettings, value: int, kind: e.LDtkCollisionKind) {
	project := LDtkEdit_Project(state.project.rootPath, settings.file)
	def := project != nil ? e.LDtk_FindLayerDef(project, settings.collisionLayer) : nil
	values := make([dynamic]int, context.temp_allocator)
	if def != nil do for v in def.intGridValues do append(&values, v.value)
	if !slice.contains(values[:], value) do append(&values, value)
	kinds := make([]e.LDtkCollisionKind, len(values), context.temp_allocator)
	for v, i in values do kinds[i] = v == value ? kind : e.LDtk_CollisionKind(settings, v)
	clear(&settings.collisionValues)
	clear(&settings.oneWayValues)
	clear(&settings.areaValues)
	allSolid := true
	for v, i in values {
		switch kinds[i] {
		case .Solid:   append(&settings.collisionValues, v)
		case .One_Way: append(&settings.oneWayValues, v)
		case .Area:    append(&settings.areaValues, v)
		case .None:
		}
		if kinds[i] != .Solid do allSolid = false
	}
	if allSolid do clear(&settings.collisionValues)
	// None solid: an empty list would make every other value solid, so "0" (the empty cell) alone
	if len(settings.collisionValues) == 0 && !allSolid do append(&settings.collisionValues, 0)
}
