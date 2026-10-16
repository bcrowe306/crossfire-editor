package editor

import "core:encoding/ini"
import "core:fmt"
import "core:path/filepath"
import "core:reflect"
import "core:strings"

/*
Exporting: the targets a project can be exported to, their settings, and the plan of steps that
builds one. The steps are run by export_run.odin; everything here is pure (no files touched), so
it's unit-tested.

Every target is listed (`ExportTarget`), each with its own settings (`EXPORT_TARGETS[t].fields`).
Projects keep them in `export.ini` next to project.xml (`ExportSettings_ToINI`), edited in
Project Settings > Export. Implemented so far (`Export_Implemented`):
- Linux x86_64, when the editor runs on it (the host): an optimized player, the project's files in
  `data/`, the SDL3 libraries in `lib/` (rpath `$ORIGIN/lib`), optionally a .tar.gz.
- Web: the player built for js_wasm32 and linked by Emscripten (the `third_party/emsdk`
  submodule, `task emsdk`) into index.html/.js/.wasm/.data; optionally a .zip (for itch.io).
  Sound comes from SDL3_mixer built for the web from `third_party/SDL_mixer`
  (`tools/build_web_mixer.sh`; the export builds it the first time).
The others report "not implemented yet" when exported.
*/

// Everything a project can be exported to. Consoles are generic for now (generations later)
ExportTarget :: enum {
	Linux_x64,
	Linux_ARM64,
	Windows_x64,
	Windows_ARM64,
	macOS_x64,
	macOS_ARM64,
	Web,
	Steam,
	PlayStation_5,
	Xbox_Series,
	Nintendo_Switch,
}

// How the Export tab groups the targets
ExportGroup :: enum {
	Desktop,
	Web,
	Store,
	Console,
}

// A setting a target can have; which ones it has is `ExportTargetInfo.fields`
ExportField :: enum {
	// Where the export goes: relative to the project folder, or absolute
	Output_Folder,
	// The game's executable (desktop)
	Executable_Name,
	// The browser tab's title (web)
	Page_Title,
	// Build with -o:speed
	Optimize,
	// Ship the SDL3 libraries next to the game
	Bundle_Libraries,
	// Windows: no console window (-subsystem:windows)
	Hide_Console,
	// macOS: the .app's bundle identifier
	Bundle_Identifier,
	// Also pack the output into one archive next to it
	Archive,
	// Steam: the app and depot to upload to
	Steam_App_ID,
	Steam_Depot_ID,
}

ExportFieldKind :: enum {
	Text,
	Bool,
}

ExportFieldInfo :: struct {
	// Key in export.ini
	key: string,
	label: string,
	kind: ExportFieldKind,
	// Shown under the field
	help: string,
}

EXPORT_FIELDS := [ExportField]ExportFieldInfo{
	.Output_Folder     = {"output_folder", "Output folder", .Text, "Relative to the project folder, or absolute. Empty: export/<target>."},
	.Executable_Name   = {"executable_name", "Executable", .Text, "Empty: the project's name."},
	.Page_Title        = {"page_title", "Page title", .Text, "Empty: the project's name."},
	.Optimize          = {"optimize", "Optimize", .Bool, "Build with -o:speed: a faster game, a slower build."},
	.Bundle_Libraries  = {"bundle_libraries", "Bundle libraries", .Bool, "Copy the SDL3 libraries into lib/ next to the game, so players don't need them installed."},
	.Hide_Console      = {"hide_console", "Hide console", .Bool, "No console window next to the game."},
	.Bundle_Identifier = {"bundle_identifier", "Bundle ID", .Text, "Like com.example.mygame."},
	.Archive           = {"archive", "Archive", .Bool, "Also pack the export into one file next to the output folder."},
	.Steam_App_ID      = {"steam_app_id", "App ID", .Text, "From the Steamworks partner site."},
	.Steam_Depot_ID    = {"steam_depot_id", "Depot ID", .Text, ""},
}

ExportTargetInfo :: struct {
	label: string,
	group: ExportGroup,
	fields: bit_set[ExportField],
	// Shown under the target's title in the Export tab
	note: string,
}

@(private="file")
DESKTOP_FIELDS :: bit_set[ExportField]{.Output_Folder, .Executable_Name, .Optimize, .Bundle_Libraries, .Archive}

EXPORT_TARGETS := [ExportTarget]ExportTargetInfo{
	.Linux_x64       = {"Linux x86_64", .Desktop, DESKTOP_FIELDS, "An executable with data/ and lib/ beside it. The archive is a .tar.gz."},
	.Linux_ARM64     = {"Linux ARM64", .Desktop, DESKTOP_FIELDS, "Needs an ARM64 machine or CI to build."},
	.Windows_x64     = {"Windows x86_64", .Desktop, DESKTOP_FIELDS + {.Hide_Console}, "Needs Windows (or CI) to build."},
	.Windows_ARM64   = {"Windows ARM64", .Desktop, DESKTOP_FIELDS + {.Hide_Console}, "Needs Windows (or CI) to build."},
	.macOS_x64       = {"macOS x86_64", .Desktop, DESKTOP_FIELDS + {.Bundle_Identifier}, "Needs a Mac (or CI) to build; distributing needs signing and notarization."},
	.macOS_ARM64     = {"macOS ARM64", .Desktop, DESKTOP_FIELDS + {.Bundle_Identifier}, "Needs a Mac (or CI) to build; distributing needs signing and notarization."},
	.Web             = {"Web (WebAssembly)", .Web, {.Output_Folder, .Page_Title, .Optimize, .Archive}, "index.html and its files: serve the folder over HTTP. The archive is a .zip (for itch.io). Sound starts after the player first clicks or presses a key (a browser rule); images must be PNG or BMP."},
	.Steam           = {"Steam", .Store, {.Output_Folder, .Steam_App_ID, .Steam_Depot_ID}, "Uploads desktop builds with the Steamworks SDK."},
	.PlayStation_5   = {"PlayStation 5", .Console, {.Output_Folder}, "Needs Sony's SDK (licensed developers only)."},
	.Xbox_Series     = {"Xbox Series X|S", .Console, {.Output_Folder}, "Needs Microsoft's GDK (licensed developers only)."},
	.Nintendo_Switch = {"Nintendo Switch", .Console, {.Output_Folder}, "Needs Nintendo's SDK (licensed developers only)."},
}

// One target's settings: a plain value (inline text), so the dialog and undo can copy it
ExportTargetSettings :: struct {
	enabled: bool,
	outputFolder: FixedText,
	// Executable name or page title ("" = the project's name)
	name: FixedText,
	optimize: bool,
	bundleLibraries: bool,
	hideConsole: bool,
	archive: bool,
	// Bundle ID (macOS) or Steam app ID
	identifier: FixedText,
	steamDepot: FixedText,
}

// A project's export settings, kept in its export.ini
ExportSettings :: struct {
	targets: [ExportTarget]ExportTargetSettings,
}

// The project file the settings are saved in
EXPORT_SETTINGS_FILE :: "export.ini"

// Where exports go when the output folder is empty: export/<target>, in the project folder
EXPORT_DEFAULT_FOLDER :: "export"

// Settings for every target before a project changes them
ExportSettings_Default :: proc() -> ExportSettings {
	settings: ExportSettings
	for &t in settings.targets {
		t.optimize = true
		t.bundleLibraries = true
	}
	return settings
}

// The text a text field edits, or nil for a bool field
ExportField_Text :: proc(t: ^ExportTargetSettings, field: ExportField) -> ^FixedText {
	#partial switch field {
	case .Output_Folder:                 return &t.outputFolder
	case .Executable_Name, .Page_Title:  return &t.name
	case .Bundle_Identifier, .Steam_App_ID: return &t.identifier
	case .Steam_Depot_ID:                return &t.steamDepot
	}
	return nil
}

// The flag a bool field edits, or nil for a text field
ExportField_Bool :: proc(t: ^ExportTargetSettings, field: ExportField) -> ^bool {
	#partial switch field {
	case .Optimize:         return &t.optimize
	case .Bundle_Libraries: return &t.bundleLibraries
	case .Hide_Console:     return &t.hideConsole
	case .Archive:          return &t.archive
	}
	return nil
}

/*
Whether a target can be exported from this machine. Desktop targets build only for the OS and CPU
the editor runs on; Linux x86_64 is the only one done.
*/
Export_Implemented :: proc(target: ExportTarget) -> bool {
	#partial switch target {
	case .Web:       return true
	case .Linux_x64: return ODIN_OS == .Linux && ODIN_ARCH == .amd64
	}
	return false
}

// Why a target can't be exported (for the error and the Export tab)
Export_NotImplementedReason :: proc(target: ExportTarget) -> string {
	if target == .Linux_x64 do return "Linux x86_64 exports must be made on Linux x86_64 (other machines: later, on CI)"
	return fmt.tprintf("%s export isn't implemented yet", EXPORT_TARGETS[target].label)
}

/*
Reads export.ini. Unknown sections and keys, and bad values, are skipped and reported.

Returns:
- Problems found, one line each (temp allocated)
*/
ExportSettings_Parse :: proc(settings: ^ExportSettings, text: string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	it := ini.iterator_from_string(text)
	for key, value in ini.iterate(&it) {
		target, ok := reflect.enum_from_name(ExportTarget, it.section)
		if !ok {
			append(&problems, fmt.tprintf("[%s]: unknown export target", it.section))
			continue
		}
		t := &settings.targets[target]
		if key == "enabled" {
			if b, valid := parseBool(value); valid do t.enabled = b
			else do append(&problems, fmt.tprintf("[%s] %s = %s: expected true or false", it.section, key, value))
			continue
		}
		field, known := exportFieldByKey(key)
		if !known || field not_in EXPORT_TARGETS[target].fields {
			append(&problems, fmt.tprintf("[%s] %s: unknown setting", it.section, key))
			continue
		}
		if text := ExportField_Text(t, field); text != nil {
			text^ = FixedText_Make(value)
		} else if flag := ExportField_Bool(t, field); flag != nil {
			if b, valid := parseBool(value); valid do flag^ = b
			else do append(&problems, fmt.tprintf("[%s] %s = %s: expected true or false", it.section, key, value))
		}
	}
	return problems[:]
}

/*
The text of export.ini: a section for each target whose settings aren't the defaults, in
`ExportTarget` order, with every setting of that target. Deterministic.

Returns:
- The text ("" when everything is a default)
*/
ExportSettings_ToINI :: proc(settings: ^ExportSettings, allocator := context.allocator) -> string {
	defaults := ExportSettings_Default()
	b := strings.builder_make(allocator)
	for target in ExportTarget {
		t := &settings.targets[target]
		if t^ == defaults.targets[target] do continue
		if strings.builder_len(b) == 0 {
			strings.write_string(&b, "; Export settings (Project Settings > Export in the editor)\n")
		}
		fmt.sbprintf(&b, "\n[%v]\nenabled = %v\n", target, t.enabled)
		for field in EXPORT_TARGETS[target].fields {
			if text := ExportField_Text(t, field); text != nil {
				fmt.sbprintf(&b, "%s = %s\n", EXPORT_FIELDS[field].key, FixedText_String(text))
			} else if flag := ExportField_Bool(t, field); flag != nil {
				fmt.sbprintf(&b, "%s = %v\n", EXPORT_FIELDS[field].key, flag^)
			}
		}
	}
	return strings.to_string(b)
}

@(private="file")
exportFieldByKey :: proc(key: string) -> (ExportField, bool) {
	for info, field in EXPORT_FIELDS do if info.key == key do return field, true
	return {}, false
}

@(private="file")
parseBool :: proc(value: string) -> (bool, bool) {
	switch strings.to_lower(value, context.temp_allocator) {
	case "true":  return true, true
	case "false": return false, true
	}
	return false, false
}

/*
What a step of an export does. Commands run as child processes (their output goes to the Output
tab); the others are quick file operations done by the editor itself.
*/
ExportStepKind :: enum {
	// Run `command` in `workingDir` (and keep its output if `capture`)
	Command,
	// Write `content` to `path`, creating folders
	Write_File,
	// Copy `files` (relative paths) from `source` into `path`, keeping their folders
	Copy_Files,
	// Copy the SDL3 libraries `ldd` printed (the previous step's captured output) into `path`
	Bundle_Libraries,
	// Delete the folder `path` (only folders the export owns, under the editor's build folder)
	Remove_Folder,
	// Create the folder `path` (and its parents); compilers don't create their output folders
	Make_Folder,
}

ExportStep :: struct {
	kind: ExportStepKind,
	// What the Output tab shows for it
	label: string,
	command: []string,
	workingDir: string,
	capture: bool,
	path: string,
	content: string,
	source: string,
	files: []string,
}

// What `Export_Plan` needs to know; paths absolute
ExportInput :: struct {
	target: ExportTarget,
	settings: ExportTargetSettings,
	// The saved project
	projectDir: string,
	projectName: string,
	hasScripts: bool,
	// project.xml, the scene files and the assets, relative to projectDir
	files: []string,
	engineDir: string,
	emsdkDir: string,
	// Web: the SDL_mixer sources, the script that builds them, and the folder the library goes in
	mixerDir: string,
	mixerBuildScript: string,
	webLibDir: string,
	// Whether webLibDir already has libSDL3_mixer.a (else the export builds it first)
	webMixerBuilt: bool,
	// A folder the export may use for intermediate files (the editor's build/exports/<project>)
	workDir: string,
}

// A planned export
ExportPlan :: struct {
	target: ExportTarget,
	// Where the result goes
	outputDir: string,
	// The archive made after it, or ""
	archive: string,
	steps: []ExportStep,
}

/*
The steps that export a project to one target. Nothing is touched; `Export_Run` runs them.

Inputs:
- input: The project and the target's settings
- allocator: For the plan and everything in it (an arena: the plan is freed as a whole)

Returns:
- The plan, and "" or why the target can't be exported
*/
Export_Plan :: proc(input: ExportInput, allocator := context.allocator) -> (plan: ExportPlan, problem: string) {
	context.allocator = allocator
	if !Export_Implemented(input.target) do return {}, Export_NotImplementedReason(input.target)
	settings := input.settings
	plan.target = input.target
	plan.outputDir = Export_OutputDir(input.projectDir, input.target, &settings, allocator)
	if message := checkOutputDir(input.projectDir, plan.outputDir); message != "" do return {}, message

	steps := make([dynamic]ExportStep)
	append(&steps, ExportStep{kind = .Make_Folder, label = "Create the output folder", path = plan.outputDir})
	// The player: the engine's, or a generated main that also links the project's scripts
	source := joinPath(input.engineDir, "player")
	if input.hasScripts {
		source = joinPath(input.workDir, "main")
		append(&steps, ExportStep{kind = .Write_File, label = "Write the game's main package",
			path = joinPath(source, "main.odin"), content = playerMainSource()})
	}
	collections := make([dynamic]string)
	append(&collections, fmt.aprintf("-collection:engine=%s", input.engineDir))
	if input.hasScripts do append(&collections, fmt.aprintf("-collection:project=%s", input.projectDir))

	#partial switch input.target {
	case .Linux_x64:
		name := Export_Name(&settings, .Executable_Name, input.projectName)
		if strings.contains_any(name, "/\\") do return {}, fmt.tprintf("The executable name '%s' can't contain a slash", name)
		binary := joinPath(plan.outputDir, name)
		command := make([dynamic]string)
		append(&command, "odin", "build", source)
		append(&command, ..collections[:])
		if settings.optimize do append(&command, "-o:speed")
		append(&command, fmt.aprintf("-out:%s", binary))
		// The libraries are found in lib/ next to the executable first
		if settings.bundleLibraries do append(&command, "-extra-linker-flags:-Wl,-rpath,$ORIGIN/lib")
		append(&steps, ExportStep{kind = .Command, label = "Build the game", command = command[:]})
		append(&steps, copyProjectStep(input, joinPath(plan.outputDir, "data")))
		if settings.bundleLibraries {
			ldd := make([]string, 2)
			ldd[0], ldd[1] = "ldd", binary
			append(&steps, ExportStep{kind = .Command, label = "Find the libraries it uses", command = ldd, capture = true})
			append(&steps, ExportStep{kind = .Bundle_Libraries, label = "Copy the SDL3 libraries", path = joinPath(plan.outputDir, "lib")})
		}
		if settings.archive {
			plan.archive = fmt.aprintf("%s.tar.gz", plan.outputDir)
			tar := make([]string, 6)
			tar[0], tar[1], tar[2], tar[3], tar[4], tar[5] = "tar", "-czf", plan.archive, "-C", filepath.dir(plan.outputDir), filepath.base(plan.outputDir)
			append(&steps, ExportStep{kind = .Command, label = "Pack the archive", command = tar})
		}
	case .Web:
		emcc := Export_EmccPath(input.emsdkDir, allocator)
		webDir := joinPath(input.workDir, "web")
		object := joinPath(webDir, "game.wasm.o")
		dataDir := joinPath(webDir, "data")
		shell := joinPath(webDir, "shell.html")
		webFiles := joinPath(input.engineDir, "web")

		command := make([dynamic]string)
		append(&steps, ExportStep{kind = .Make_Folder, label = "Create the build folder", path = webDir})
		mixerLib := joinPath(input.webLibDir, "libSDL3_mixer.a")
		if !input.webMixerBuilt {
			build := make([]string, 5)
			build[0], build[1], build[2], build[3], build[4] = "bash", input.mixerBuildScript, input.emsdkDir, input.mixerDir, input.webLibDir
			append(&steps, ExportStep{kind = .Command, label = "Build SDL3_mixer for the web (once)", command = build})
		}
		append(&command, "odin", "build", source, "-target:js_wasm32", "-build-mode:obj")
		append(&command, ..collections[:])
		if settings.optimize do append(&command, "-o:speed")
		append(&command, fmt.aprintf("-out:%s", object))
		append(&steps, ExportStep{kind = .Command, label = "Build the game for WebAssembly", command = command[:]})
		// A fresh copy of the project's files, packaged into the page's virtual file system
		append(&steps, ExportStep{kind = .Remove_Folder, label = "Clear the staged files", path = dataDir})
		append(&steps, copyProjectStep(input, dataDir))
		title := Export_Name(&settings, .Page_Title, input.projectName)
		append(&steps, ExportStep{kind = .Write_File, label = "Write the page template", path = shell, content = Export_WebShell(title)})

		link := make([dynamic]string)
		append(&link, emcc, joinPath(webFiles, "main.c"), object, mixerLib,
			"-o", joinPath(plan.outputDir, "index.html"),
			"-sUSE_SDL=3", "-sUSE_SDL_TTF=3", "-sALLOW_MEMORY_GROWTH",
			"--js-library", joinPath(webFiles, "odin_env.js"),
			"--pre-js", joinPath(webFiles, "odin_env_pre.js"),
			"--shell-file", shell,
			fmt.aprintf("--preload-file=%s@/data", dataDir))
		if settings.optimize do append(&link, "-O2")
		append(&steps, ExportStep{kind = .Command, label = "Link with Emscripten", command = link[:]})
		if settings.archive {
			plan.archive = fmt.aprintf("%s.zip", plan.outputDir)
			// Python is there: Emscripten needs it
			zip := make([dynamic]string)
			append(&zip, "python3", "-m", "zipfile", "-c", plan.archive, "index.html", "index.js", "index.wasm", "index.data")
			append(&steps, ExportStep{kind = .Command, label = "Pack the archive", command = zip[:], workingDir = plan.outputDir})
		}
	}
	plan.steps = steps[:]
	return plan, ""
}

/*
Where a target's export goes (absolute).

Inputs:
- projectDir: The project folder (absolute)
- settings: The target's settings; an empty output folder means export/<target>
*/
Export_OutputDir :: proc(projectDir: string, target: ExportTarget, settings: ^ExportTargetSettings, allocator := context.allocator) -> string {
	folder := strings.trim_space(FixedText_String(&settings.outputFolder))
	if folder == "" do folder = fmt.tprintf("%s/%s", EXPORT_DEFAULT_FOLDER, strings.to_lower(fmt.tprint(target), context.temp_allocator))
	if filepath.is_abs(folder) do return cleanPath(folder, allocator)
	return joinPath(projectDir, folder, allocator = allocator)
}

// The executable name or page title: the setting, or else the project's name (made file-safe for executables)
Export_Name :: proc(settings: ^ExportTargetSettings, field: ExportField, projectName: string) -> string {
	name := strings.trim_space(FixedText_String(ExportField_Text(settings, field)))
	if name != "" do return strings.clone(name)
	if field == .Executable_Name do return strings.clone(sanitize(projectName))
	return strings.clone(projectName)
}

// Emscripten's compiler in an emsdk checkout
Export_EmccPath :: proc(emsdkDir: string, allocator := context.allocator) -> string {
	return joinPath(emsdkDir, "upstream", "emscripten", "emcc", allocator = allocator)
}

/*
The project's files an export ships: project.xml, each scene's file and each asset (relative
paths). Scripts are compiled in, not shipped.
*/
Export_ProjectFiles :: proc(project: ^Project, allocator := context.allocator) -> []string {
	files := make([dynamic]string, allocator)
	append(&files, strings.clone("project.xml", allocator))
	for &scene in project.scenes do append(&files, SceneFilePath(&scene, allocator))
	for asset in project.assets do append(&files, strings.clone(asset.path, allocator))
	return files[:]
}

/*
The SDL3 libraries in `ldd` output: lines like
`libSDL3.so.0 => /usr/lib/libSDL3.so.0 (0x7f...)`. Other libraries (libc, the GPU drivers) must
come from the player's system.

Returns:
- The libraries' paths (pointing into `text`)
*/
Export_ParseLdd :: proc(text: string, allocator := context.allocator) -> []string {
	libraries := make([dynamic]string, allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		name, _, rest := strings.partition(strings.trim_space(line), " => ")
		if !strings.has_prefix(name, "libSDL3") || rest == "" do continue
		path, _, _ := strings.partition(rest, " (")
		path = strings.trim_space(path)
		if path != "" && path != "not found" do append(&libraries, path)
	}
	return libraries[:]
}

/*
The page around a web export: Emscripten's --shell-file. The canvas keeps the game's aspect
ratio and fills the window.
*/
Export_WebShell :: proc(title: string, allocator := context.allocator) -> string {
	// Not a format string: fmt reads braces as formatting, and the page is full of them
	head :: `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>`
	tail :: `</title>
<style>
html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
canvas { display: block; position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); outline: none; }
</style>
</head>
<body>
<canvas id="canvas" tabindex="-1" oncontextmenu="event.preventDefault()"></canvas>
<script>
var canvas = document.getElementById("canvas");
// Scale the canvas to the window, keeping the game's shape
function fitCanvas() {
	if (!canvas.width || !canvas.height) return;
	var scale = Math.min(window.innerWidth / canvas.width, window.innerHeight / canvas.height);
	var width = Math.floor(canvas.width * scale) + "px", height = Math.floor(canvas.height * scale) + "px";
	// SDL sets the size too; only change it when it differs, or the observer would loop
	if (canvas.style.width != width) canvas.style.width = width;
	if (canvas.style.height != height) canvas.style.height = height;
}
window.addEventListener("resize", fitCanvas);
new MutationObserver(fitCanvas).observe(canvas, { attributes: true, attributeFilter: ["width", "height", "style"] });
var Module = { canvas: canvas };
</script>
{{{ SCRIPT }}}
</body>
</html>
`
	return strings.concatenate({head, EscapeXML(title, context.temp_allocator), tail}, allocator)
}

@(private="file")
copyProjectStep :: proc(input: ExportInput, destination: string) -> ExportStep {
	files := make([]string, len(input.files))
	for file, i in input.files do files[i] = strings.clone(file)
	return {kind = .Copy_Files, label = "Copy the project's files", source = input.projectDir, path = destination, files = files}
}

// An output folder must not hold the project (exports copy into it, and the archive packs it)
@(private="file")
checkOutputDir :: proc(projectDir, outputDir: string) -> string {
	project := cleanPath(projectDir, context.temp_allocator)
	output := cleanPath(outputDir, context.temp_allocator)
	if output == project || isInside(project, output) {
		return fmt.tprintf("The output folder %s contains the project; choose a folder inside it (like export/) or elsewhere", outputDir)
	}
	for folder in ([]string{"scenes", "assets", SCRIPTS_FOLDER}) {
		inside := joinPath(project, folder, allocator = context.temp_allocator)
		if output == inside || isInside(output, inside) {
			return fmt.tprintf("The output folder %s is inside the project's %s/ folder", outputDir, folder)
		}
	}
	return ""
}

// Whether `path` is inside `folder` (both clean)
@(private="file")
isInside :: proc(path, folder: string) -> bool {
	return strings.has_prefix(path, folder) && len(path) > len(folder) && (path[len(folder)] == '/' || folder == "/")
}

// filepath.join, for paths that can't fail to allocate
joinPath :: proc(parts: ..string, allocator := context.allocator) -> string {
	path, _ := filepath.join(parts, allocator)
	return path
}

@(private="file")
cleanPath :: proc(path: string, allocator := context.allocator) -> string {
	result, _ := filepath.clean(path, allocator)
	return result
}
