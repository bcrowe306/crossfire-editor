package crossfire_editor

import "core:dynlib"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:time"
import "gui:skald"
import e "engine:."
import api "plugin_api"

/*
Editor plugins (the plugin API: plugin_api/plugin_api.odin): Odin packages in a project's
`plugins/<name>/` folders, built into shared libraries and loaded into the editor.

- **Finding and building:** `Plugins_Tick` (every PLUGINS_TICK_SECONDS while the project has a
  `plugins/` folder: the view starts it) builds a plugin whose `.odin` files are newer than its
  last build, one at a time, as a child process (`odin build <folder> -build-mode:shared` with
  the `plugin_api` collection), into `build/plugins/<project>-<hash>/<name>-<n>.<so|dll|dylib>`:
  a new file each time, since a loaded library can't be replaced (and Linux's `dlopen` would hand
  back the loaded one for the same path). Build output goes to the Output tab.
- **Loading:** `dynlib.load_library`, then its exported `crossfire_plugin` (api.PLUGIN_ENTRY) is
  called with the `Host`; what it returns is copied (names, extensions, targets) so a reload can
  drop the old library. A plugin built against another API version isn't kept.
- **Calling in:** plugin procedures run with the editor's `context` (its allocators). The `Host`'s
  procedures reach the editor state through `pluginState`, set just before each call (update's
  `out`, or the view's state for inspector rows, which must only read).
- **Commands** (the Plugins tab's buttons: `Plugin_Command_Run`) and inspector changes
  (`Plugin_Row_Changed`) are `.Project` undo steps: whatever they change in the scenes is one step.
  **Importers** take the files of their extensions in `importAsset` first.
- **New Plugin** (the Plugins tab) writes `plugins/<name>/<name>.odin` from `PLUGIN_TEMPLATE`.
*/

PLUGINS_FOLDER :: "plugins"
PLUGINS_TICK_SECONDS :: 0.5

// Where the plugin API package is: this checkout's (development), else beside the editor
PLUGIN_API_SOURCE :: #directory + "/plugin_api"

// A plugin's state
PluginStatus :: enum {
	// Not built yet (or its build is waiting its turn)
	Waiting,
	Building,
	Loaded,
	// Its build or load failed (`problem`)
	Failed,
}

// One plugin folder of the project
PluginRecord :: struct {
	// Its folder's name ("grid_tools"), and what it says it is (owned)
	folder: string,
	name, description: string,
	status: PluginStatus,
	problem: string,
	// The newest source when it was last built (built again when one is newer)
	built: time.Time,
	// Its loaded library and what it gave (strings owned; procedures into the library)
	library: dynlib.Library,
	loads: int,
	commands: [dynamic]PluginCommandRecord,
	importers: [dynamic]PluginImporterRecord,
	inspectors: [dynamic]PluginInspectorRecord,
}

PluginCommandRecord :: struct {
	name, description: string,
	run: proc(host: ^api.Host),
}

PluginImporterRecord :: struct {
	extensions: [dynamic]string,
	description: string,
	run: proc(host: ^api.Host, source: string) -> (string, string),
}

PluginInspectorRecord :: struct {
	targets: [dynamic]string,
	rows: proc(host: ^api.Host, node: int) -> []api.InspectorRow,
	changed: proc(host: ^api.Host, node: int, id, value: string),
}

// The project's plugins (package state: loaded libraries and a build process aren't State)
PluginsState :: struct {
	list: [dynamic]PluginRecord,
	// The project they belong to (absolute; owned)
	root: string,
	// A build running: its plugin, process, output
	building: int,
	process: os.Process,
	pipe: ^os.File,
	output: [dynamic]u8,
	host: api.Host,
}

@(private="file")
plugins: PluginsState = {building = -1}

// The state host procedures act on (set around every call into a plugin)
@(private="file")
pluginState: ^State

// The Plugins tab and the view's ticks (State.pluginsTicking)
Plugins_Tick :: struct {}
// Runs a plugin's command (indices into the Plugins tab's list)
Plugin_Command_Run :: struct {
	plugin, command: int,
}
// An inspector row a plugin gave changed (strings for the frame)
Plugin_Row_Changed :: struct {
	plugin, inspector, node: int,
	id, value: string,
}
// The Plugins tab's New Plugin / Rebuild All
Plugin_New_Requested :: struct {}
Plugins_Rebuild_Requested :: struct {}

// The project's plugins as the Plugins tab lists them
Plugins_List :: proc() -> []PluginRecord {
	return plugins.list[:]
}

// Whether the project has a plugins folder (the view keeps the tick going then)
Plugins_Present :: proc(state: ^State) -> bool {
	return os.exists(joinPath(state.project.rootPath, PLUGINS_FOLDER, allocator = context.temp_allocator))
}

/*
Handles the plugin messages.

Returns:
- A command to run, and whether `m` was one of them
*/
Plugins_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Plugins_Tick:
		return pluginsTick(state), true
	case Plugin_Command_Run:
		if v.plugin < 0 || v.plugin >= len(plugins.list) do break
		p := &plugins.list[v.plugin]
		if p.status != .Loaded || v.command < 0 || v.command >= len(p.commands) do break
		logLine(state, .Info, fmt.aprintf("Plugin %s: %s", p.name, p.commands[v.command].name))
		pluginCall(state)
		p.commands[v.command].run(&plugins.host)
	case Plugin_Row_Changed:
		if v.plugin < 0 || v.plugin >= len(plugins.list) do break
		p := &plugins.list[v.plugin]
		if p.status != .Loaded || v.inspector < 0 || v.inspector >= len(p.inspectors) do break
		if changed := p.inspectors[v.inspector].changed; changed != nil {
			pluginCall(state)
			changed(&plugins.host, v.node, v.id, v.value)
		}
	case Plugin_New_Requested:
		path, problem := Plugin_Create(&state.project, "my_plugin")
		if problem != "" {
			logLine(state, .Error, strings.clone(problem))
			break
		}
		logLine(state, .Info, fmt.aprintf("Made %s: the editor builds and loads it now", path))
		absolute := absolutePath(joinPath(state.project.rootPath, path, allocator = context.temp_allocator))
		return Script_Open(state, absolute, 1), true
	case Plugins_Rebuild_Requested:
		for &p in plugins.list do p.built = {}
	case:
		return {}, false
	}
	return {}, true
}

/*
Writes a new plugin's folder and source (`plugins/<name>/<name>.odin`, numbered when taken) from
the template: a command, an importer and inspector rows to start from.

Returns:
- The file's path (relative to the project; temp allocated), or why it failed
*/
Plugin_Create :: proc(project: ^Project, name: string) -> (string, string) {
	base := strings.to_lower(sanitize(name), context.temp_allocator)
	folder := base
	for n := 2; os.exists(joinPath(project.rootPath, PLUGINS_FOLDER, folder, allocator = context.temp_allocator)); n += 1 do folder = fmt.tprintf("%s_%d", base, n)
	dir := joinPath(project.rootPath, PLUGINS_FOLDER, folder, allocator = context.temp_allocator)
	if err := os.make_directory_all(dir); err != nil do return "", fmt.tprintf("Couldn't make %s: %v", dir, err)
	source, _ := strings.replace_all(PLUGIN_TEMPLATE, "PACKAGE", folder, context.temp_allocator)
	path := fmt.tprintf("%s/%s/%s.odin", PLUGINS_FOLDER, folder, folder)
	if err := os.write_entire_file(joinPath(project.rootPath, path, allocator = context.temp_allocator), transmute([]byte)source); err != nil {
		return "", fmt.tprintf("Couldn't write %s: %v", path, err)
	}
	return path, ""
}

/*
Runs an importer for a file, when a loaded plugin takes its extension.

Returns:
- Whether one did (then `asset` is what it made, or `problem` why it couldn't)
*/
Plugins_Import :: proc(state: ^State, source: string) -> (handled: bool, asset: string, problem: string) {
	ext := strings.to_lower(strings.trim_prefix(filepath.ext(source), "."), context.temp_allocator)
	if ext == "" do return
	for &p in plugins.list do if p.status == .Loaded {
		for &importer in p.importers do for x in importer.extensions do if x == ext {
			pluginCall(state)
			asset, problem = importer.run(&plugins.host, source)
			return true, asset, problem
		}
	}
	return
}

/*
The inspector rows plugins give a node (by its kind, or "script:<Name>" for its scripts).

Returns:
- Each plugin inspector's index and rows (temp allocated)
*/
Plugins_InspectorRows :: proc(state: ^State, node: int) -> []PluginRows {
	out := make([dynamic]PluginRows, context.temp_allocator)
	scene := &state.project.scenes[state.currentScene]
	if node < 0 || node >= len(scene.nodes) do return out[:]
	def := &scene.nodes[node]
	kind := fmt.tprint(def.kind)
	for &p, pi in plugins.list do if p.status == .Loaded {
		for &inspector, ii in p.inspectors {
			match := false
			for t in inspector.targets {
				if t == kind || (def.customKind != "" && t == def.customKind) do match = true
				if strings.has_prefix(t, "script:") && NodeDef_Runs(def, t[len("script:"):]) do match = true
			}
			if !match || inspector.rows == nil do continue
			pluginCall(state)
			append(&out, PluginRows{pi, ii, p.name, inspector.rows(&plugins.host, node)})
		}
	}
	return out[:]
}

// One plugin inspector's rows for a node
PluginRows :: struct {
	plugin, inspector: int,
	name: string,
	rows: []api.InspectorRow,
}

// Unloads every plugin (the project changed, or the editor quits)
Plugins_Unload :: proc() {
	pluginsStopBuild()
	for &p in plugins.list do pluginRecordDestroy(&p)
	delete(plugins.list)
	plugins.list = nil
	delete(plugins.root)
	plugins.root = ""
	delete(plugins.output)
	plugins.output = nil
}

// INTERNAL

// Finds, builds and loads the project's plugins; ticks again while there are any
@(private="file")
pluginsTick :: proc(state: ^State) -> skald.Command(Msg) {
	root := absolutePath(state.project.rootPath)
	if plugins.root != root {
		Plugins_Unload()
		plugins.root = strings.clone(root)
		plugins.building = -1
	}
	folder := joinPath(root, PLUGINS_FOLDER, allocator = context.temp_allocator)
	if !os.exists(folder) {
		if len(plugins.list) > 0 do Plugins_Unload()
		state.pluginsTicking = false
		return {}
	}
	// The folders there now: new ones added, gone ones dropped
	entries, _ := os.read_all_directory_by_path(folder, context.temp_allocator)
	present := make(map[string]bool, context.temp_allocator)
	for entry in entries do if entry.type == .Directory {
		present[entry.name] = true
		known := false
		for p in plugins.list do if p.folder == entry.name do known = true
		if !known do append(&plugins.list, PluginRecord{folder = strings.clone(entry.name), name = strings.clone(entry.name)})
	}
	for i := len(plugins.list) - 1; i >= 0; i -= 1 do if !present[plugins.list[i].folder] && plugins.building != i {
		pluginRecordDestroy(&plugins.list[i])
		ordered_remove(&plugins.list, i)
	}
	// A build running: its output, its end
	if plugins.building >= 0 {
		pluginsBuildPoll(state)
	} else {
		// The next plugin whose sources are newer than its build
		for &p, i in plugins.list {
			newest := newestSource(joinPath(folder, p.folder, allocator = context.temp_allocator))
			if newest == {} || time.diff(p.built, newest) <= 0 do continue
			pluginsBuildStart(state, i, newest)
			break
		}
	}
	state.pluginsTicking = true
	return skald.cmd_delay(PLUGINS_TICK_SECONDS, Msg(Plugins_Tick{}))
}

@(private="file")
pluginsBuildStart :: proc(state: ^State, index: int, newest: time.Time) {
	p := &plugins.list[index]
	p.built = newest
	odin := Toolchain_Odin(FixedText_String(&state.settings.odinPath))
	if odin == "" {
		pluginFail(state, p, "No Odin compiler (Settings > Toolchain) to build plugins with")
		return
	}
	apiDir, found := Toolchain_PluginAPI()
	if !found {
		pluginFail(state, p, "The plugin API's sources (plugin_api) aren't beside the editor")
		return
	}
	p.loads += 1
	out := pluginLibraryPath(state, p.folder, p.loads)
	_ = os.make_directory_all(filepath.dir(out))
	source := joinPath(plugins.root, PLUGINS_FOLDER, p.folder, allocator = context.temp_allocator)
	command := []string{odin, "build", source, "-build-mode:shared", fmt.tprintf("-out:%s", out), fmt.tprintf("-collection:plugin_api=%s", apiDir)}
	outputLine(state, .Info, fmt.aprintf("Plugin %s: $ %s", p.folder, strings.join(command, " ", context.temp_allocator)))
	reader, writer, pipeErr := os.pipe()
	if pipeErr != nil {
		pluginFail(state, p, fmt.tprintf("couldn't create a pipe: %v", pipeErr))
		return
	}
	process, err := os.process_start({command = command, stdout = writer, stderr = writer})
	os.close(writer)
	if err != nil {
		os.close(reader)
		pluginFail(state, p, fmt.tprintf("couldn't run %s: %v", odin, err))
		return
	}
	plugins.building, plugins.process, plugins.pipe = index, process, reader
	p.status = .Building
}

@(private="file")
pluginsBuildPoll :: proc(state: ^State) {
	buffer: [4096]u8
	for {
		hasData, err := os.pipe_has_data(plugins.pipe)
		if !hasData || err != nil do break
		n, _ := os.read(plugins.pipe, buffer[:])
		if n <= 0 do break
		append(&plugins.output, ..buffer[:n])
	}
	status, err := os.process_wait(plugins.process, 0)
	if err == os.General_Error.Timeout || (err == nil && !status.exited) do return
	for {
		n, _ := os.read(plugins.pipe, buffer[:])
		if n <= 0 do break
		append(&plugins.output, ..buffer[:n])
	}
	os.close(plugins.pipe)
	index := plugins.building
	plugins.building, plugins.pipe = -1, nil
	text := strings.trim_space(string(plugins.output[:]))
	for line in strings.split_lines(text, context.temp_allocator) do if strings.trim_space(line) != "" do outputLine(state, .Error, strings.clone(line))
	clear(&plugins.output)
	if index < 0 || index >= len(plugins.list) do return
	p := &plugins.list[index]
	if err != nil || status.exit_code != 0 {
		pluginFail(state, p, "its build failed: see the Output tab")
		return
	}
	pluginLoad(state, p, pluginLibraryPath(state, p.folder, p.loads))
}

// Loads a built library in place of the plugin's old one
@(private="file")
pluginLoad :: proc(state: ^State, p: ^PluginRecord, path: string) {
	library, ok := dynlib.load_library(path)
	if !ok {
		pluginFail(state, p, fmt.tprintf("couldn't load %s: %s", filepath.base(path), dynlib.last_error()))
		return
	}
	address, found := dynlib.symbol_address(library, api.PLUGIN_ENTRY)
	if !found {
		dynlib.unload_library(library)
		pluginFail(state, p, fmt.tprintf("it exports no %s procedure (@(export) %s :: proc(host: ^api.Host) -> api.Plugin)", api.PLUGIN_ENTRY, api.PLUGIN_ENTRY))
		return
	}
	pluginHostSetup()
	pluginCall(state)
	given := (cast(api.PluginEntry)address)(&plugins.host)
	if given.version != api.PLUGIN_API_VERSION {
		dynlib.unload_library(library)
		pluginFail(state, p, fmt.tprintf("it was made for plugin API version %d; this editor speaks %d (set version = api.PLUGIN_API_VERSION)", given.version, api.PLUGIN_API_VERSION))
		return
	}
	// The old library goes once nothing points into it
	pluginRecordClear(p)
	p.library = library
	delete(p.name)
	delete(p.description)
	p.name = strings.clone(given.name != "" ? given.name : p.folder)
	p.description = strings.clone(given.description)
	for c in given.commands do append(&p.commands, PluginCommandRecord{strings.clone(c.name), strings.clone(c.description), c.run})
	for i in given.importers {
		r := PluginImporterRecord{description = strings.clone(i.description), run = i.run}
		for x in i.extensions do append(&r.extensions, strings.clone(strings.to_lower(strings.trim_prefix(x, "."), context.temp_allocator)))
		append(&p.importers, r)
	}
	for i in given.inspectors {
		r := PluginInspectorRecord{rows = i.rows, changed = i.changed}
		for t in i.targets do append(&r.targets, strings.clone(t))
		append(&p.inspectors, r)
	}
	p.status = .Loaded
	delete(p.problem)
	p.problem = ""
	logLine(state, .Info, fmt.aprintf("Plugin %s loaded: %d command%s, %d importer%s, %d inspector%s", p.name,
		len(p.commands), len(p.commands) == 1 ? "" : "s", len(p.importers), len(p.importers) == 1 ? "" : "s", len(p.inspectors), len(p.inspectors) == 1 ? "" : "s"))
}

@(private="file")
pluginFail :: proc(state: ^State, p: ^PluginRecord, problem: string) {
	p.status = .Failed
	delete(p.problem)
	p.problem = strings.clone(problem)
	logLine(state, .Error, fmt.aprintf("Plugin %s: %s", p.folder, problem))
}

// Drops what a plugin gave and its library
@(private="file")
pluginRecordClear :: proc(p: ^PluginRecord) {
	for c in p.commands { delete(c.name); delete(c.description) }
	clear(&p.commands)
	for &i in p.importers {
		for x in i.extensions do delete(x)
		delete(i.extensions)
		delete(i.description)
	}
	clear(&p.importers)
	for &i in p.inspectors {
		for t in i.targets do delete(t)
		delete(i.targets)
	}
	clear(&p.inspectors)
	if p.library != nil do dynlib.unload_library(p.library)
	p.library = nil
}

@(private="file")
pluginRecordDestroy :: proc(p: ^PluginRecord) {
	pluginRecordClear(p)
	delete(p.commands)
	delete(p.importers)
	delete(p.inspectors)
	delete(p.folder)
	delete(p.name)
	delete(p.description)
	delete(p.problem)
	p^ = {}
}

@(private="file")
pluginsStopBuild :: proc() {
	if plugins.building < 0 do return
	_ = os.process_kill(plugins.process)
	_, _ = os.process_wait(plugins.process)
	if plugins.pipe != nil do os.close(plugins.pipe)
	plugins.pipe = nil
	plugins.building = -1
	delete(plugins.output)
	plugins.output = nil
}

// A plugin's library file for its n-th build (absolute; temp allocated)
@(private="file")
pluginLibraryPath :: proc(state: ^State, folder: string, n: int) -> string {
	ext := ODIN_OS == .Windows ? "dll" : ODIN_OS == .Darwin ? "dylib" : "so"
	project := fmt.tprintf("%s-%x", sanitize(filepath.base(plugins.root)), hash.fnv32a(transmute([]byte)plugins.root))
	return absolutePath(joinPath("build", "plugins", project, fmt.tprintf("%s-%d.%s", folder, n, ext), allocator = context.temp_allocator))
}

// The plugin API's folder: this checkout's, else beside the editor (releases)
Toolchain_PluginAPI :: proc() -> (string, bool) {
	if os.exists(PLUGIN_API_SOURCE) do return PLUGIN_API_SOURCE, true
	if exeDir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		for dir in ([]string{joinPath(exeDir, "plugin_api", allocator = context.temp_allocator), joinPath(exeDir, "..", "Resources", "plugin_api", allocator = context.temp_allocator)}) {
			if os.exists(dir) do return dir, true
		}
	}
	return "", false
}

// Sets the state host procedures use (before every call into a plugin)
@(private="file")
pluginCall :: proc(state: ^State) {
	pluginState = state
	pluginHostSetup()
}

// The host's procedures (once)
@(private="file")
pluginHostSetup :: proc() {
	if plugins.host.version != 0 do return
	plugins.host = {
		version = api.PLUGIN_API_VERSION,
		log = proc(text: string, warning := false) {
			if pluginState != nil do logLine(pluginState, warning ? .Warning : .Info, strings.clone(text))
		},
		projectRoot = proc() -> string { return absolutePath(pluginState.project.rootPath) },
		sceneName = proc() -> string { return hostScene().name },
		nodeCount = proc() -> int { return len(hostScene().nodes) },
		nodeParent = proc(node: int) -> int {
			scene := hostScene()
			return node >= 0 && node < len(scene.nodes) ? scene.nodes[node].parent : -1
		},
		nodeChildren = proc(node: int) -> []int {
			scene := hostScene()
			out := make([dynamic]int, context.temp_allocator)
			for n, i in scene.nodes do if n.parent == node do append(&out, i)
			return out[:]
		},
		getProperty = hostGetProperty,
		setProperty = hostSetProperty,
		addNode = proc(kind, name: string, parent: int) -> int {
			k, ok := reflect.enum_from_name(NodeKind, kind)
			if !ok do return -1
			scene := hostScene()
			p := parent >= 0 && parent < len(scene.nodes) ? parent : -1
			return Scene_InsertNode(scene, Scene_UniqueNodeName(scene, name != "" ? name : kind), k, p)
		},
		removeNode = proc(node: int) {
			scene := hostScene()
			if node < 0 || node >= len(scene.nodes) do return
			Scene_RemoveNode(scene, node)
			pluginState.selectedNode = -1
		},
		selected = proc() -> int { return pluginState.selectedNode },
		selection = proc() -> []int {
			out := make([]int, len(pluginState.selection), context.temp_allocator)
			copy(out, pluginState.selection[:])
			return out
		},
		select = proc(node: int) { pluginState.selectedNode = node },
		assets = proc() -> []string {
			out := make([]string, len(pluginState.project.assets), context.temp_allocator)
			for a, i in pluginState.project.assets do out[i] = a.path
			return out
		},
		assetKind = proc(path: string) -> string {
			for a in pluginState.project.assets do if a.path == path do return fmt.tprint(a.kind)
			return ""
		},
		addAsset = proc(path: string) -> bool {
			full := joinPath(pluginState.project.rootPath, path, allocator = context.temp_allocator)
			_, message := Project_ImportAsset(&pluginState.project, full)
			if message != "" do return false
			pluginState.session.assetsChanged = true
			return true
		},
	}
}

@(private="file")
hostScene :: proc() -> ^SceneDef {
	return &pluginState.project.scenes[pluginState.currentScene]
}

@(private="file")
hostGetProperty :: proc(node: int, property: string) -> (string, bool) {
	scene := hostScene()
	if node < 0 || node >= len(scene.nodes) do return "", false
	n := &scene.nodes[node]
	switch property {
	case "name":     return n.name, true
	case "kind":     return fmt.tprint(n.kind), true
	case "position": return fmt.tprintf("%v, %v", n.position.x, n.position.y), true
	case "rotation": return fmt.tprintf("%v", n.rotation), true
	case "scale":    return fmt.tprintf("%v, %v", n.scale.x, n.scale.y), true
	case "visible":  return n.visible ? "true" : "false", true
	case "layer":    return fmt.tprintf("%d", n.layer), true
	case "z_index":  return fmt.tprintf("%d", n.zIndex), true
	case "texture":  return n.texture, true
	case "text":     return n.text, true
	case "color":    return e.FormatColor(n.color, context.temp_allocator), true
	case "region":   return n.region, true
	case "script":   return n.script, true
	}
	if strings.has_prefix(property, "script.") {
		field := property[len("script."):]
		for code in NodeDef_Codes(pluginState, n) {
			for p in code.props do if p.name == field do return p.value, true
			if code.desc != nil do for f in code.desc.fields do if f.name == field do return f.defaultValue, true
		}
	}
	return "", false
}

@(private="file")
hostSetProperty :: proc(node: int, property, value: string) -> bool {
	scene := hostScene()
	if node < 0 || node >= len(scene.nodes) do return false
	n := &scene.nodes[node]
	pair :: proc(text: string) -> ([2]f32, bool) {
		a, _, b := strings.partition(text, ",")
		x, ok1 := strconv.parse_f32(strings.trim_space(a))
		y, ok2 := strconv.parse_f32(strings.trim_space(b))
		return {x, y}, ok1 && ok2
	}
	text :: proc(field: ^string, value: string) -> bool {
		delete(field^)
		field^ = strings.clone(value)
		return true
	}
	switch property {
	case "name":     return value != "" && text(&n.name, value)
	case "position": v, ok := pair(value); if ok do n.position = v; return ok
	case "scale":    v, ok := pair(value); if ok do n.scale = v; return ok
	case "rotation": v, ok := strconv.parse_f32(value); if ok do n.rotation = v; return ok
	case "visible":  n.visible = value == "true"; return value == "true" || value == "false"
	case "layer":    v, ok := strconv.parse_int(value); if ok do n.layer = clamp(v, 0, 7); return ok
	case "z_index":  v, ok := strconv.parse_int(value); if ok do n.zIndex = i32(v); return ok
	case "texture":  return text(&n.texture, value)
	case "text":     return text(&n.text, value)
	case "color":    c, ok := e.ParseColor(value); if ok do n.color = c; return ok
	case "region":   return text(&n.region, value)
	}
	if strings.has_prefix(property, "script.") {
		// The first code with that field, in the engine's order: its node type, its first
		// script, its more scripts (before a build: its first script)
		field := property[len("script."):]
		find :: proc(desc: ^ScriptDesc, field: string) -> (string, bool) {
			if desc != nil do for f in desc.fields do if f.name == field do return f.defaultValue, true
			return "", false
		}
		if n.customKind != "" {
			if d, ok := find(ScriptCatalog_FindNodeType(&pluginState.scripts, n.customKind), field); ok {
				Props_Set(&n.customProps, field, value, d)
				return true
			}
		}
		first := ScriptCatalog_Find(&pluginState.scripts, n.script)
		if d, ok := find(first, field); ok || (first == nil && n.script != "") {
			NodeDef_SetScriptValue(n, field, value, d)
			return true
		}
		for &extra in n.moreScripts {
			if d, ok := find(ScriptCatalog_Find(&pluginState.scripts, extra.name), field); ok {
				Props_Set(&extra.props, field, value, d)
				return true
			}
		}
	}
	return false
}

// A new plugin's source: one of each thing a plugin can add
PLUGIN_TEMPLATE :: `// A Crossfire Editor plugin. The editor builds it when it changes; see the manual's Plugins
// page for the API (plugin_api: Host, Command, Importer, Inspector).
package PACKAGE

import "core:fmt"
import "core:strings"
import api "plugin_api:."

// What it adds (package-level lists: they must outlive the call)
commands := []api.Command{
	{name = "Count Nodes", description = "Logs how many nodes the open scene has", run = countNodes},
}

inspectors := []api.Inspector{
	{targets = {"Sprite"}, rows = spriteRows, changed = spriteChanged},
}

@(export)
crossfire_plugin :: proc(host: ^api.Host) -> api.Plugin {
	return {
		name = "PACKAGE",
		description = "What this plugin does",
		version = api.PLUGIN_API_VERSION,
		commands = commands,
		inspectors = inspectors,
	}
}

countNodes :: proc(host: ^api.Host) {
	host.log(fmt.tprintf("%s has %d nodes", host.sceneName(), host.nodeCount()))
}

// A row for every Sprite: its picture, and a button turning it to face the other way
spriteRows :: proc(host: ^api.Host, node: int) -> []api.InspectorRow {
	texture, _ := host.getProperty(node, "texture")
	rows := make([]api.InspectorRow, 2, context.temp_allocator)
	rows[0] = {label = "Picture", kind = .Note, value = texture == "" ? "none" : texture}
	rows[1] = {id = "flip", label = "Facing", kind = .Button, value = "Flip"}
	return rows
}

spriteChanged :: proc(host: ^api.Host, node: int, id, value: string) {
	if id != "flip" do return
	scale, _ := host.getProperty(node, "scale")
	x, _, y := strings.partition(scale, ",")
	host.setProperty(node, "scale", fmt.tprintf("%s%s,%s", strings.has_prefix(strings.trim_space(x), "-") ? "" : "-", strings.trim_prefix(strings.trim_space(x), "-"), y))
}
`
