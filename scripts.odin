package editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode"
import "gui:skald"
import "core:time"
import e "engine:."

/*
Project scripts in the editor: Odin game code attached to nodes (the engine's script.odin explains
scripts themselves).

	<project>/scripts/<name>.odin    the project's `scripts` package: one file per script by convention

What the editor knows about the scripts comes from building them: after a build it runs the
project's player with `--describe-scripts` and reads the JSON it prints (`ScriptCatalog_Parse`),
so names, exported fields, their types, defaults and ranges are exactly what the compiler saw.
Until the first build after opening a project the catalog is empty; nodes keep their script and
values anyway, and the inspector shows the values it has.

Scripts are edited outside the editor, in the program set in the settings (`code_editor_path`,
`zed` by default, and `code_editor_args`, `{file}:{line}`). A built-in editor using the Odin language server is planned
much later.
*/

SCRIPTS_FOLDER :: "scripts"

// What the last build said about the project's scripts
ScriptCatalog :: struct {
	status: ScriptCatalogStatus,
	scripts: [dynamic]ScriptDesc,
}

ScriptCatalogStatus :: enum {
	// Not built since the project was opened (or it has no scripts folder)
	Unknown,
	Building,
	Ready,
	// The build failed: see the Output tab
	Failed,
}

// A script, as `--describe-scripts` reports it (strings owned)
ScriptDesc :: struct {
	name: string,
	file: string,
	line: int,
	fields: [dynamic]ScriptFieldDesc,
}

ScriptFieldDesc :: struct {
	name: string,
	type: e.ScriptFieldType,
	defaultValue: string,
	min: Maybe(f64),
	max: Maybe(f64),
	// "scene": a string naming a scene
	hint: string,
	enumNames: [dynamic]string,
}

/*
Reads the JSON `player --describe-scripts` prints.

Returns:
- The scripts (owned; free with `ScriptCatalog_Clear`), and whether the text was valid
*/
ScriptCatalog_Parse :: proc(text: string) -> ([dynamic]ScriptDesc, bool) {
	scripts := make([dynamic]ScriptDesc)
	// The JSON is the last line that starts with '{' (the player may log before it)
	start := strings.last_index(text, "{\"scripts\"")
	if start < 0 do return scripts, false
	value, err := json.parse_string(text[start:], allocator = context.temp_allocator)
	if err != .None do return scripts, false
	root, isObject := value.(json.Object)
	if !isObject do return scripts, false
	list, _ := root["scripts"].(json.Array)
	for item in list {
		obj, ok := item.(json.Object)
		if !ok do continue
		desc := ScriptDesc{
			name = strings.clone(jsonString(obj, "name")),
			file = strings.clone(jsonString(obj, "file")),
			line = int(jsonNumber(obj, "line").? or_else 0),
		}
		fields, _ := obj["fields"].(json.Array)
		for f in fields {
			fo, isField := f.(json.Object)
			if !isField do continue
			field := ScriptFieldDesc{
				name = strings.clone(jsonString(fo, "name")),
				defaultValue = strings.clone(jsonString(fo, "default")),
				hint = strings.clone(jsonString(fo, "hint")),
				min = jsonNumber(fo, "min"),
				max = jsonNumber(fo, "max"),
			}
			for t in e.ScriptFieldType do if fmt.tprint(t) == jsonString(fo, "type") do field.type = t
			names, _ := fo["enum"].(json.Array)
			for n in names do if s, isString := n.(json.String); isString do append(&field.enumNames, strings.clone(s))
			append(&desc.fields, field)
		}
		append(&scripts, desc)
	}
	return scripts, true
}

// Frees the catalog's scripts
ScriptCatalog_Clear :: proc(catalog: ^ScriptCatalog) {
	for &script in catalog.scripts {
		delete(script.name)
		delete(script.file)
		for &field in script.fields {
			delete(field.name)
			delete(field.defaultValue)
			delete(field.hint)
			for n in field.enumNames do delete(n)
			delete(field.enumNames)
		}
		delete(script.fields)
	}
	delete(catalog.scripts)
	catalog.scripts = {}
}

// The described script with that name, or nil
ScriptCatalog_Find :: proc(catalog: ^ScriptCatalog, name: string) -> ^ScriptDesc {
	for &script in catalog.scripts do if script.name == name do return &script
	return nil
}

/*
The project's script files (the .odin files in `scripts/`), sorted.

Returns:
- Paths relative to the project folder, with `/` (temp allocated)
*/
Project_ScriptFiles :: proc(project: ^Project) -> []string {
	files := make([dynamic]string, context.temp_allocator)
	dir, _ := filepath.join({project.rootPath, SCRIPTS_FOLDER}, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return nil
	for entry in entries {
		if entry.type == .Regular && strings.has_suffix(entry.name, ".odin") {
			append(&files, fmt.tprintf("%s/%s", SCRIPTS_FOLDER, entry.name))
		}
	}
	slice.sort(files[:])
	return files[:]
}

// Whether the project has any scripts (so Play needs a player of its own)
Project_HasScripts :: proc(project: ^Project) -> bool {
	return len(Project_ScriptFiles(project)) > 0
}

/*
Whether a name can be a script: an Odin identifier starting with a capital letter.

Returns:
- "" if it can, otherwise why not (temp allocated)
*/
ScriptNameProblem :: proc(name: string) -> string {
	if name == "" do return "give the script a name"
	for r, i in name {
		ok := r == '_' || unicode.is_letter(r) || (i > 0 && unicode.is_digit(r))
		if !ok do return fmt.tprintf("'%s' isn't a valid Odin name (letters, digits and _, not starting with a digit)", name)
	}
	if !unicode.is_upper(rune(name[0])) do return "start it with a capital letter, like PlayerController"
	return ""
}

/*
The file a new script goes in: PlayerController -> scripts/player_controller.odin.
*/
ScriptFileFor :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r, i in name {
		if unicode.is_upper(r) {
			if i > 0 do strings.write_byte(&b, '_')
			strings.write_rune(&b, unicode.to_lower(r))
		} else {
			strings.write_rune(&b, r)
		}
	}
	return fmt.tprintf("%s/%s.odin", SCRIPTS_FOLDER, strings.to_string(b))
}

/*
Writes a new script from the template: a struct with an exported field, and ready and update.

Inputs:
- project: The project (its scripts folder is created if needed)
- name: The script's name (see `ScriptNameProblem`)

Returns:
- The file, relative to the project folder (temp allocated), and an error message ("" on success)
*/
Project_CreateScript :: proc(project: ^Project, name: string) -> (file: string, message: string) {
	if problem := ScriptNameProblem(name); problem != "" do return "", problem
	file = ScriptFileFor(name)
	path, _ := filepath.join({project.rootPath, file}, context.temp_allocator)
	if os.exists(path) do return "", fmt.tprintf("%s already exists", file)
	dir, _ := filepath.join({project.rootPath, SCRIPTS_FOLDER}, context.temp_allocator)
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		return "", fmt.tprintf("couldn't create %s: %v", dir, err)
	}
	if err := os.write_entire_file(path, transmute([]byte)ScriptTemplate(name)); err != nil {
		return "", fmt.tprintf("couldn't write %s: %v", path, err)
	}
	return file, ""
}

// The source of a new script (temp allocated)
ScriptTemplate :: proc(name: string) -> string {
	return strings.concatenate({`package scripts

import e "engine:."
import sdl "vendor:sdl3"

/*
`, name, `: attach it to a node in the editor's inspector (Script).

Fields tagged ` + "`export:\"\"`" + ` show in the inspector and are saved in the scene. Options inside the
quotes: default=<value> min=<n> max=<n> kind=scene. Untagged fields are the script's own state.
self.node is the node it's attached to; self.scene and self.game are there too.
*/
`, name, ` :: struct {
	using script: e.Script,
	speed: f32 ` + "`export:\"default=100 min=0\"`" + `,
}

@(init)
register_`, name, ` :: proc "contextless" () {
	e.Script_Register(`, name, `, {
		// Once, when the scene starts: every node exists (e.Scene_FindNode(self.scene, "World/Ship"))
		ready = proc(self: ^`, name, `) {
		},
		// Every frame, after the node's own update
		update = proc(self: ^`, name, `, events: []sdl.Event, dt: f64) {
		},
	})
}
`}, context.temp_allocator)
}

/*
Opens a file in the configured code editor, without waiting for it.

The process is described in full (`os.Process_Desc`):
- command: the program (`settings.codeEditorPath`: a path, or a name found in PATH), then its
  arguments (`settings.codeEditorArgs` with {file} and {line} replaced: `Script_EditorCommand`)
- env: this process's environment (`os.environ`), so the editor sees the same DISPLAY,
  WAYLAND_DISPLAY, PATH, HOME... as the editor that launched it
- working_dir: the project's scripts folder (the project folder if it doesn't exist yet)
- stdout, stderr: the editor's own, so messages from the program show where the editor's do
  (passing none would close them, and some programs fail without them)

A program that exits with an error is reported in the Console by `Editor_Process_Check`.

Inputs:
- state: The editor state (settings, project, and to log)
- file: Absolute path
- line: Line to open at (1 if unknown)

Returns:
- The command that checks on the process afterwards
*/
Script_OpenInEditor :: proc(state: ^State, file: string, line: int) -> skald.Command(Msg) {
	program, found := Script_FindEditorProgram(FixedText_String(&state.settings.codeEditorPath))
	if !found {
		logLine(state, .Error, fmt.aprintf("Couldn't find the code editor '%s'. Set its path in Settings > Editor", program))
		return {}
	}
	command := Script_EditorCommand(program, FixedText_String(&state.settings.codeEditorArgs), file, line)
	env, envErr := os.environ(context.temp_allocator)
	if envErr != nil do env = nil // nil also means "this process's environment"
	process, err := os.process_start({
		command = command,
		env = env,
		working_dir = scriptsWorkingDir(&state.project),
		stdout = os.stdout,
		stderr = os.stderr,
	})
	if err != nil {
		logLine(state, .Error, fmt.aprintf("Couldn't start %s: %v. Check Settings > Editor", program, err))
		return {}
	}
	append(&editorProcesses, EditorProcess{process = process, program = strings.clone(filepath.base(program)), started = time.tick_now()})
	logLine(state, .Info, fmt.aprintf("Opened %s:%d in %s", filepath.base(file), max(line, 1), filepath.base(program)))
	return skald.cmd_delay(EDITOR_CHECK_SECONDS, Msg(Editor_Process_Check{}))
}

DEFAULT_CODE_EDITOR_PATH :: "zed"
DEFAULT_CODE_EDITOR_ARGS :: "{file}:{line}"

/*
The command line that opens a file: the program, then the arguments template split on spaces with
`{file}` and `{line}` replaced. Arguments without `{file}` get the file added at the end.

Inputs:
- program: The executable (as found by `Script_FindEditorProgram`)
- args: The arguments template ("" for the default)
- file, line: What to open

Returns:
- The program and its arguments (temp allocated)
*/
Script_EditorCommand :: proc(program, args, file: string, line: int) -> []string {
	template := strings.trim_space(args)
	if template == "" do template = DEFAULT_CODE_EDITOR_ARGS
	command := make([dynamic]string, context.temp_allocator)
	append(&command, program)
	for part in strings.fields(template, context.temp_allocator) {
		part, _ := strings.replace_all(part, "{file}", file, context.temp_allocator)
		part, _ = strings.replace_all(part, "{line}", fmt.tprint(max(line, 1)), context.temp_allocator)
		append(&command, part)
	}
	if !strings.contains(template, "{file}") do append(&command, file)
	return command[:]
}

/*
Where the code editor program is: the setting itself if it's a path (absolute, or relative to
the editor's folder), or the first match in PATH for a bare name. Empty means the default.

Returns:
- The path (temp allocated), and whether it exists
*/
Script_FindEditorProgram :: proc(setting: string) -> (string, bool) {
	program := strings.trim_space(setting)
	if program == "" do program = DEFAULT_CODE_EDITOR_PATH
	// "~/..." is a shell shorthand; expand it, since nothing else will
	if strings.has_prefix(program, "~/") {
		if home := os.get_env("HOME", context.temp_allocator); home != "" {
			program, _ = filepath.join({home, program[2:]}, context.temp_allocator)
		}
	}
	if strings.contains_rune(program, '/') do return program, os.exists(program)
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ":", context.temp_allocator) {
		if dir == "" do continue
		candidate, _ := filepath.join({dir, program}, context.temp_allocator)
		if os.exists(candidate) && !os.is_dir(candidate) do return candidate, true
	}
	return program, false
}

// The folder the code editor runs in: the project's scripts folder, absolute
@(private="file")
scriptsWorkingDir :: proc(project: ^Project) -> string {
	dir, _ := filepath.join({project.rootPath, SCRIPTS_FOLDER}, context.temp_allocator)
	if !os.is_dir(dir) do dir = project.rootPath
	absolute, err := os.get_absolute_path(dir, context.temp_allocator)
	return err == nil ? absolute : dir
}

/*
Checks the code editor processes Open started: ones that exited are freed, and ones that exited
with an error are reported. Rechecks while some are still running, for up to EDITOR_WATCH_SECONDS
each (an editor that stays open, rather than handing the file to a running one, isn't watched
for its whole life).

Returns:
- The next check, or nothing when no process needs watching
*/
Editor_CheckProcesses :: proc(state: ^State) -> skald.Command(Msg) {
	for i := len(editorProcesses) - 1; i >= 0; i -= 1 {
		p := editorProcesses[i]
		status, err := os.process_wait(p.process, 0)
		exited := err == nil && status.exited
		if exited && status.exit_code != 0 {
			logLine(state, .Error, fmt.aprintf("%s exited with code %d without opening the script. Check Settings > Editor (its messages are in the terminal the editor runs from)", p.program, status.exit_code))
		}
		watched := time.duration_seconds(time.tick_since(p.started)) >= EDITOR_WATCH_SECONDS
		if exited || watched {
			delete(p.program)
			unordered_remove(&editorProcesses, i)
		}
	}
	if len(editorProcesses) == 0 do return {}
	return skald.cmd_delay(EDITOR_CHECK_SECONDS, Msg(Editor_Process_Check{}))
}

EDITOR_CHECK_SECONDS :: 0.5
EDITOR_WATCH_SECONDS :: 10

// A code editor process started by Open. Package state: it's about OS processes, which the
// editor's state can't copy
@(private="file")
EditorProcess :: struct {
	process: os.Process,
	// Owned
	program: string,
	started: time.Tick,
}

@(private="file")
editorProcesses: [dynamic]EditorProcess

/*
A node's value for a script field: what's stored on the node, or the field's default.
*/
NodeDef_ScriptValue :: proc(node: ^NodeDef, field: ^ScriptFieldDesc) -> string {
	for prop in node.props do if prop.name == field.name do return prop.value
	return field.defaultValue
}

/*
Sets a node's value for a script field (copied). Setting it back to the default removes it, so
scene files only hold values that differ.
*/
NodeDef_SetScriptValue :: proc(node: ^NodeDef, name, value, defaultValue: string) {
	for prop, i in node.props {
		if prop.name != name do continue
		delete(prop.value)
		if value == defaultValue {
			delete(prop.name)
			ordered_remove(&node.props, i)
		} else {
			node.props[i].value = strings.clone(value)
		}
		return
	}
	if value != defaultValue do append(&node.props, ScriptPropDef{strings.clone(name), strings.clone(value)})
}

@(private="file")
jsonString :: proc(obj: json.Object, key: string) -> string {
	s, _ := obj[key].(json.String)
	return s
}

@(private="file")
jsonNumber :: proc(obj: json.Object, key: string) -> Maybe(f64) {
	#partial switch v in obj[key] {
	case json.Float: return f64(v)
	case json.Integer: return f64(v)
	}
	return nil
}

/*
Re-reads the project's script files from disk (after opening a project, creating a script, or
building).
*/
Scripts_Refresh :: proc(state: ^State) {
	for f in state.scriptFiles do delete(f)
	clear(&state.scriptFiles)
	for f in Project_ScriptFiles(&state.project) do append(&state.scriptFiles, strings.clone(f))
}

/*
Where a script's source is: the file the last build reported, or the file a new script of that
name would get.

Returns:
- An absolute path (temp allocated), and the line
*/
Script_Location :: proc(state: ^State, name: string) -> (string, int) {
	if desc := ScriptCatalog_Find(&state.scripts, name); desc != nil && desc.file != "" do return desc.file, desc.line
	path, _ := filepath.join({state.project.rootPath, ScriptFileFor(name)}, context.temp_allocator)
	absolute, err := os.get_absolute_path(path, context.temp_allocator)
	return err == nil ? absolute : path, 1
}
