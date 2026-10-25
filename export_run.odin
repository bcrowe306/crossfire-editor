package crossfire_editor

import "base:runtime"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Running exports: File > Export (every enabled target) and the Export tab's Export button (one
target). The project is saved first, as for Play. Each target becomes a job: its `Export_Plan`,
whose steps run in order. Commands are child processes polled by `Export_Tick` (like Play's), and
their output goes to the Output tab; the file steps are quick and done in `update`. A failed step
ends that target's job, and the next target runs. Exports run beside Play: they build into their
own folders.
*/

// Where exports keep intermediate files: build/exports/<project>-<hash>/ under the editor's folder
EXPORT_WORK_DIR :: "build/exports"

// Emscripten for web exports: the emsdk submodule (`task emsdk` installs it)
EMSDK_DIR :: #config(EMSDK_DIR, "third_party/emsdk")
// SDL3_mixer's sources (a submodule), built for the web into WEB_LIB_DIR by WEB_MIXER_SCRIPT
SDL_MIXER_DIR :: #config(SDL_MIXER_DIR, "third_party/SDL_mixer")
WEB_MIXER_SCRIPT :: "tools/build_web_mixer.sh"
WEB_LIB_DIR :: "build/web"

// One target being exported
ExportJob :: struct {
	// Owns the plan and its strings
	arena: vmem.Arena,
	plan: ExportPlan,
	step: int,
}

// The exports in progress (part of State)
ExportSession :: struct {
	// Waiting and running jobs; jobs[0] runs
	jobs: [dynamic]^ExportJob,
	// The running command, if any
	running: bool,
	process: os.Process,
	pipe: ^os.File,
	partial: [dynamic]u8,
	// Output of a command with `capture` (ldd's, for Bundle_Libraries)
	captured: [dynamic]u8,
	succeeded, failed: int,
}

// Sent every PLAY_POLL_SECONDS while an export command runs
Export_Tick :: struct {}

// Whether exports are running
Export_Busy :: proc(state: ^State) -> bool {
	return len(state.exporting.jobs) > 0
}

/*
Exports the project to some targets: saves it, plans each target and starts the first.
Targets that can't be exported are reported in the Console and skipped.

Inputs:
- targets: The targets; File > Export passes the enabled ones
*/
Export_Start :: proc(state: ^State, targets: bit_set[ExportTarget]) -> skald.Command(Msg) {
	if Export_Busy(state) {
		logLine(state, .Warning, fmt.aprintf("An export is already running"))
		return {}
	}
	if targets == {} {
		logLine(state, .Warning, fmt.aprintf("No export targets are enabled: choose some in Project Settings > Export"))
		ProjectSettings_Open(state, .Export)
		return {}
	}
	if !CodeTabs_SaveAll(state) do return {}
	// The Level mode's unsaved LDtk edits: exports take the files (ldtk_doc.odin)
	if !LDtkDocs_SaveProject(state) do return {}
	_ = Shaders_Compile(state)
	_ = Fonts_MakeMSDF(state)
	if message := Project_Save(&state.project); message != "" {
		logLine(state, .Error, fmt.aprintf("Export: couldn't save the project: %s", message))
		return {}
	}
	Session_MarkSaved(state)
	clearOutput(state)
	state.exporting.succeeded, state.exporting.failed = 0, 0

	needsEmscripten := false
	for target in targets {
		job := new(ExportJob)
		if err := vmem.arena_init_growing(&job.arena); err != nil {
			free(job)
			logLine(state, .Error, fmt.aprintf("Export: out of memory"))
			break
		}
		problem: string
		input := exportInput(state, target, vmem.arena_allocator(&job.arena))
		job.plan, problem = Export_Plan(input, vmem.arena_allocator(&job.arena))
		// A build needs an Odin compiler (a project without scripts can do without, on a target
		// with a prebuilt player)
		if problem == "" && input.odin == "" && (input.hasScripts || input.prebuiltPlayer == "") {
			problem = "No Odin compiler to build the game with: install one in Settings > Toolchain"
		}
		// Emscripten (and SDL_mixer's sources) missing: installed first, then this export runs
		_, hasEmsdk := Toolchain_EmsdkDir()
		_, hasMixer := Toolchain_SDLMixerDir()
		if problem == "" && target == .Web && (!hasEmsdk || !hasMixer) {
			vmem.arena_destroy(&job.arena)
			free(job)
			state.exportAfterEmscripten += {target}
			needsEmscripten = true
			continue
		}
		if problem == "" && target == .Web && Toolchain_WebMixerScript() == "" {
			problem = fmt.tprintf("The web export needs %s, which this editor doesn't have (releases ship it next to the editor)", WEB_MIXER_SCRIPT)
		}
		if problem != "" {
			logLine(state, .Error, fmt.aprintf("Export %s: %s", EXPORT_TARGETS[target].label, problem))
			state.exporting.failed += 1
			vmem.arena_destroy(&job.arena)
			free(job)
			continue
		}
		append(&state.exporting.jobs, job)
	}
	if needsEmscripten {
		logLine(state, .Info, strings.clone("The web export needs Emscripten: installing it first (the export runs after)"))
		install := skald.cmd_now(Msg(Toolchain_Emscripten_Requested{}))
		if !Export_Busy(state) do return install
		return skald.cmd_batch(install, advance(state))
	}
	if !Export_Busy(state) do return {}
	Mode_ShowLogTab(state, .Output)
	state.layout.bottomOpen = true
	return advance(state)
}

// Export_Tick: forward output; when the command ends, go on with the next step
@(private="package")
exportTick :: proc(state: ^State) -> skald.Command(Msg) {
	session := &state.exporting
	if !session.running do return {}
	drainExportOutput(state)
	status, err := os.process_wait(session.process, 0)
	if err == os.General_Error.Timeout || (err == nil && !status.exited) {
		return skald.cmd_delay(PLAY_POLL_SECONDS, Msg(Export_Tick{}))
	}
	drainExportOutput(state, flush = true)
	endCommand(state)
	job := session.jobs[0]
	step := job.plan.steps[job.step]
	switch {
	case err != nil:
		failJob(state, fmt.tprintf("lost track of %s: %v", step.command[0], err))
	case status.exit_code != 0:
		failJob(state, fmt.tprintf("%s failed (exit code %d). See the Output tab", step.label, status.exit_code))
	case:
		job.step += 1
	}
	return advance(state)
}

// Stops the exports: kills the running command and drops the queue
Export_Cancel :: proc(state: ^State) {
	if !Export_Busy(state) do return
	session := &state.exporting
	if session.running {
		_ = os.process_kill(session.process)
		_, _ = os.process_wait(session.process)
		drainExportOutput(state, flush = true)
		endCommand(state)
	}
	for job in session.jobs do destroyJob(job)
	clear(&session.jobs)
	logLine(state, .Info, fmt.aprintf("Export cancelled"))
}

// Frees the session (quitting)
ExportSession_Destroy :: proc(state: ^State) {
	if Export_Busy(state) do Export_Cancel(state)
	delete(state.exporting.jobs)
	delete(state.exporting.partial)
	delete(state.exporting.captured)
}

// What Export_Plan needs, from the open (saved) project
@(private="file")
exportInput :: proc(state: ^State, target: ExportTarget, allocator := context.allocator) -> ExportInput {
	projectDir := absolutePath(state.project.rootPath)
	workDir := absolutePath(joinPath(EXPORT_WORK_DIR, projectBuildFolder(projectDir), allocator = context.temp_allocator))
	_ = os.make_directory_all(workDir)
	// The folder exists now, so this is absolute
	workDir = absolutePath(workDir)
	_ = os.make_directory_all(WEB_LIB_DIR)
	webLibDir := absolutePath(WEB_LIB_DIR)
	engineDir, _ := Toolchain_EngineDir()
	emsdkDir, _ := Toolchain_EmsdkDir()
	mixerDir, _ := Toolchain_SDLMixerDir()
	host, _ := Toolchain_HostTarget()
	return {
		target = target,
		settings = state.project.exports.targets[target],
		projectDir = strings.clone(projectDir, allocator),
		projectName = strings.clone(state.project.name, allocator),
		hasScripts = Project_HasScripts(&state.project),
		files = Export_ProjectFiles(&state.project, allocator),
		projectXML = Export_ProjectXML(&state.project, allocator),
		engineDir = strings.clone(engineDir, allocator),
		odin = strings.clone(Toolchain_Odin(FixedText_String(&state.settings.odinPath)), allocator),
		prebuiltPlayer = strings.clone(Toolchain_PrebuiltPlayer(target), allocator),
		host = host,
		sdlDLLs = host == .Windows_x64 || host == .Windows_ARM64 ? odinSDLDLLs(Toolchain_Odin(FixedText_String(&state.settings.odinPath)), allocator) : nil,
		emsdkDir = strings.clone(emsdkDir, allocator),
		mixerDir = strings.clone(mixerDir, allocator),
		mixerBuildScript = strings.clone(Toolchain_WebMixerScript(), allocator),
		webLibDir = strings.clone(webLibDir, allocator),
		webMixerBuilt = os.exists(joinPath(webLibDir, "libSDL3_mixer.a", allocator = context.temp_allocator)),
		webBox2DBuilt = os.exists(joinPath(engineDir, "box2d", "lib", "box2d_web.o", allocator = context.temp_allocator)),
		staticSDL = Export_StaticSDLBuilt(engineDir, target),
		workDir = strings.clone(workDir, allocator),
	}
}

/*
Runs steps until one has to wait for a child process, finishing jobs as their steps run out.

Returns:
- The tick that polls the running command, or nothing once every job is done
*/
@(private="file")
advance :: proc(state: ^State) -> skald.Command(Msg) {
	session := &state.exporting
	for len(session.jobs) > 0 {
		job := session.jobs[0]
		if job.step >= len(job.plan.steps) {
			finishJob(state)
			continue
		}
		step := job.plan.steps[job.step]
		outputLine(state, .Info, fmt.aprintf("[%s] %s", EXPORT_TARGETS[job.plan.target].label, step.label), category = LOG_EXPORT_CATEGORY)
		if step.kind == .Command {
			if startCommand(state, step) do return skald.cmd_delay(PLAY_POLL_SECONDS, Msg(Export_Tick{}))
			failJob(state, fmt.tprintf("couldn't start %s", step.command[0]))
			continue
		}
		if message := runFileStep(state, step); message != "" {
			failJob(state, message)
			continue
		}
		job.step += 1
	}
	summary := fmt.tprintf("Export finished: %d succeeded, %d failed", session.succeeded, session.failed)
	outputLine(state, session.failed > 0 ? .Warning : .Info, strings.clone(summary), category = LOG_EXPORT_CATEGORY)
	return {}
}

// The steps the editor does itself. Returns "" or what went wrong
@(private="file")
runFileStep :: proc(state: ^State, step: ExportStep) -> string {
	switch step.kind {
	case .Command:
	case .Write_File:
		_ = os.make_directory_all(filepath.dir(step.path))
		existing, readErr := os.read_entire_file(step.path, context.temp_allocator)
		// Unchanged files keep their time, so the build can tell nothing changed
		if readErr == nil && string(existing) == step.content do return ""
		if err := os.write_entire_file(step.path, step.content); err != nil do return fmt.tprintf("couldn't write %s: %v", step.path, err)
	case .Copy_Files:
		for file in step.files {
			from := joinPath(step.source, file, allocator = context.temp_allocator)
			to := joinPath(step.path, file, allocator = context.temp_allocator)
			if err := os.make_directory_all(filepath.dir(to)); err != nil && !os.exists(filepath.dir(to)) {
				return fmt.tprintf("couldn't create %s: %v", filepath.dir(to), err)
			}
			if err := os.copy_file(to, from); err != nil do return fmt.tprintf("couldn't copy %s: %v", from, err)
		}
	case .Copy_File:
		if err := os.copy_file(step.path, step.source); err != nil do return fmt.tprintf("couldn't copy %s: %v", step.source, err)
		when ODIN_OS != .Windows do _ = os.chmod(step.path, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
	case .Append_Pack:
		extra := make(map[string]string, context.temp_allocator)
		extra["project.xml"] = step.content
		if problem := e.Pack_Append(step.path, step.source, step.files, extra); problem != "" do return fmt.tprintf("the data pack: %s", problem)
	case .Bundle_Libraries:
		libraries := Export_ParseLdd(string(state.exporting.captured[:]), context.temp_allocator)
		if len(libraries) == 0 do return "ldd found no SDL3 libraries in the game"
		_ = os.make_directory_all(step.path)
		for library in libraries {
			// Saved under the name the game asks for (the soname ldd printed), resolving symlinks
			to := joinPath(step.path, filepath.base(library), allocator = context.temp_allocator)
			if err := os.copy_file(to, library); err != nil do return fmt.tprintf("couldn't copy %s: %v", library, err)
			outputLine(state, .Info, fmt.aprintf("  %s", filepath.base(library)), category = LOG_EXPORT_CATEGORY)
		}
	case .Make_Folder:
		if err := os.make_directory_all(step.path); err != nil && !os.is_dir(step.path) do return fmt.tprintf("couldn't create %s: %v", step.path, err)
	case .Patch_Subsystem:
		if problem := Export_SetWindowsSubsystem(step.path, gui = true); problem != "" do return problem
	case .Copy_Libraries:
		for library in step.files {
			to := joinPath(step.path, filepath.base(library), allocator = context.temp_allocator)
			if err := os.copy_file(to, library); err != nil do return fmt.tprintf("couldn't copy %s: %v", library, err)
		}
	case .Zip_Folder:
		files := make([dynamic]ZipSource, context.temp_allocator)
		top := filepath.base(step.source)
		walk :: proc(dir, prefix: string, files: ^[dynamic]ZipSource) {
			handle, err := os.open(dir)
			if err != nil do return
			defer os.close(handle)
			entries, _ := os.read_dir(handle, -1, context.temp_allocator)
			for entry in entries {
				name := fmt.tprintf("%s/%s", prefix, entry.name)
				if entry.type == .Directory do walk(entry.fullpath, name, files)
				else do append(files, ZipSource{name = name, path = strings.clone(entry.fullpath, context.temp_allocator)})
			}
		}
		walk(step.source, top, &files)
		if problem := Zip_Write(step.path, files[:]); problem != "" do return fmt.tprintf("the archive: %s", problem)
	case .Remove_Folder:
		// Only the editor's own build folder, whatever the plan says
		if !strings.contains(step.path, "/build/exports/") do return fmt.tprintf("refusing to delete %s", step.path)
		if os.exists(step.path) {
			if err := removeAll(step.path); err != nil do return fmt.tprintf("couldn't delete %s: %v", step.path, err)
		}
	}
	return ""
}

@(private="file")
finishJob :: proc(state: ^State) {
	session := &state.exporting
	job := session.jobs[0]
	label := EXPORT_TARGETS[job.plan.target].label
	destination := job.plan.archive != "" ? fmt.tprintf("%s (and %s)", job.plan.outputDir, job.plan.archive) : job.plan.outputDir
	logLine(state, .Info, fmt.aprintf("Exported %s to %s", label, destination))
	session.succeeded += 1
	ordered_remove(&session.jobs, 0)
	destroyJob(job)
}

@(private="file")
failJob :: proc(state: ^State, message: string) {
	session := &state.exporting
	job := session.jobs[0]
	logLine(state, .Error, fmt.aprintf("Export %s: %s", EXPORT_TARGETS[job.plan.target].label, message))
	session.failed += 1
	ordered_remove(&session.jobs, 0)
	destroyJob(job)
}

@(private="file")
destroyJob :: proc(job: ^ExportJob) {
	vmem.arena_destroy(&job.arena)
	free(job)
}

// Starts a command with stdout and stderr going into one pipe
@(private="file")
startCommand :: proc(state: ^State, step: ExportStep) -> bool {
	session := &state.exporting
	reader, writer, pipeErr := os.pipe()
	if pipeErr != nil do return false
	outputLine(state, .Info, fmt.aprintf("$ %s", strings.join(step.command, " ", context.temp_allocator)), category = LOG_EXPORT_CATEGORY)
	process, err := os.process_start({command = step.command, working_dir = step.workingDir, stdout = writer, stderr = writer})
	os.close(writer)
	if err != nil {
		os.close(reader)
		outputLine(state, .Error, fmt.aprintf("%v", err), category = LOG_EXPORT_CATEGORY)
		return false
	}
	session.running = true
	session.process = process
	session.pipe = reader
	clear(&session.captured)
	return true
}

@(private="file")
endCommand :: proc(state: ^State) {
	session := &state.exporting
	if session.pipe != nil do os.close(session.pipe)
	session.pipe = nil
	session.running = false
	clear(&session.partial)
}

// Moves complete lines from the pipe to the Output tab (or the capture buffer)
@(private="file")
drainExportOutput :: proc(state: ^State, flush := false) {
	session := &state.exporting
	if session.pipe == nil do return
	buffer: [4096]u8
	for {
		hasData, err := os.pipe_has_data(session.pipe)
		if !hasData || err != nil do break
		n, _ := os.read(session.pipe, buffer[:])
		if n <= 0 do break
		append(&session.partial, ..buffer[:n])
	}
	capture := len(session.jobs) > 0 && session.jobs[0].plan.steps[session.jobs[0].step].capture
	start := 0
	for b, i in session.partial {
		if b != '\n' do continue
		exportLine(state, string(session.partial[start:i]), capture)
		start = i + 1
	}
	remove_range(&session.partial, 0, start)
	if flush && len(session.partial) > 0 {
		exportLine(state, string(session.partial[:]), capture)
		clear(&session.partial)
	}
}

@(private="file")
exportLine :: proc(state: ^State, line: string, capture: bool) {
	if capture {
		append(&state.exporting.captured, ..transmute([]u8)line)
		append(&state.exporting.captured, '\n')
		return
	}
	text, level, category := parseLogLine(strings.trim_right(line, "\r"))
	outputLine(state, level, strings.clone(text), category = category != "" ? category : LOG_EXPORT_CATEGORY)
}

/*
Deletes a file or a folder with everything in it (nothing to do if it doesn't exist). Use it
instead of `os.remove_all`, which on Windows goes through the shell (SHFileOperationW): that
loads shell extensions' copy hooks over COM and crashed when called from several threads (the
tests). Symlinks are removed, not followed.
*/
removeAll :: proc(path: string) -> os.Error {
	if path == "" do return nil
	info, err := os.lstat(path, context.temp_allocator)
	if err == .Not_Exist do return nil
	if err != nil do return err
	if info.type == .Directory {
		entries := os.read_all_directory_by_path(path, context.temp_allocator) or_return
		for entry in entries do removeAll(entry.fullpath) or_return
	}
	return os.remove(path)
}

/*
Whether the engine's static SDL (tools/build_sdl_static.sh) is built for a desktop target, so
its games link SDL in and need no libraries next to them.
*/
Export_StaticSDLBuilt :: proc(engineDir: string, target: ExportTarget) -> bool {
	folder: string
	#partial switch target {
	case .Linux_x64:   folder = "linux_amd64"
	case .Linux_ARM64: folder = "linux_arm64"
	case .macOS_x64:   folder = "darwin_amd64"
	case .macOS_ARM64: folder = "darwin_arm64"
	case .Windows_x64: folder = "windows_amd64"
	case .Windows_ARM64: folder = "windows_arm64"
	case:              return false
	}
	library := target == .Windows_x64 || target == .Windows_ARM64 ? "sdl3_static.lib" : "libSDL3.a"
	return os.exists(joinPath(engineDir, "sdl", "lib", folder, library, allocator = context.temp_allocator))
}

/*
Marks a Windows executable a GUI program (no console window opens with it) or a console one:
the Subsystem field of its PE optional header (2 GUI, 3 console). A prebuilt player is a console
program; Hide console patches its copy.

Returns:
- "" or what went wrong
*/
Export_SetWindowsSubsystem :: proc(path: string, gui: bool) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return fmt.tprintf("couldn't read %s: %v", path, err)
	if len(data) < 0x40 || data[0] != 'M' || data[1] != 'Z' do return fmt.tprintf("%s isn't a Windows program", path)
	pe := int(data[0x3C]) | int(data[0x3D]) << 8 | int(data[0x3E]) << 16 | int(data[0x3F]) << 24
	// "PE\0\0", the 20-byte file header, then the optional header: Subsystem is at its byte 68
	field := pe + 4 + 20 + 68
	if pe <= 0 || field + 2 > len(data) || string(data[pe:pe + 4]) != "PE\x00\x00" do return fmt.tprintf("%s has no PE header", path)
	data[field], data[field + 1] = gui ? 2 : 3, 0
	if err := os.write_entire_file(path, data); err != nil do return fmt.tprintf("couldn't write %s: %v", path, err)
	return ""
}

// The SDL3 DLLs Odin ships for Windows (vendor/sdl3 and its image, ttf, mixer folders, next to
// the odin program), for games built without the static SDL
@(private="file")
odinSDLDLLs :: proc(odin: string, allocator: runtime.Allocator) -> []string {
	if odin == "" do return nil
	root := filepath.dir(odin)
	dlls := make([dynamic]string, allocator)
	for folder in ([]string{"sdl3", "sdl3/image", "sdl3/ttf", "sdl3/mixer"}) {
		dir := joinPath(root, "vendor", folder, allocator = context.temp_allocator)
		handle, err := os.open(dir)
		if err != nil do continue
		entries, _ := os.read_dir(handle, -1, context.temp_allocator)
		os.close(handle)
		for entry in entries do if strings.has_suffix(strings.to_lower(entry.name, context.temp_allocator), ".dll") {
			append(&dlls, strings.clone(entry.fullpath, allocator))
		}
	}
	return dlls[:]
}

/*
Exports a project without a window (`crossfire-editor <project> --export <target>`): plans it as the
Export tab would, runs each step (printing what it runs and what the commands print), and returns
the exit code. A web export installs Emscripten first when it's missing. For CI and scripts.

Inputs:
- projectDir: The project folder
- targetName: The target, as the ExportTarget's name (Linux_x64, Windows_x64, macOS_ARM64, Web...)
- settingsPath: The editor settings to use (the Odin compiler's path)

Returns:
- 0 when it exported, 1 otherwise (the reason printed)
*/
Export_Headless :: proc(projectDir, targetName, settingsPath: string) -> int {
	target, known := reflect.enum_from_name(ExportTarget, targetName)
	if !known {
		names := make([dynamic]string, context.temp_allocator)
		for t in ExportTarget do append(&names, fmt.tprint(t))
		fmt.eprintfln("Unknown export target '%s': %s", targetName, strings.join(names[:], ", ", context.temp_allocator))
		return 1
	}
	state: State
	state.settings, _ = Settings_Load(settingsPath)
	project, message, _ := Project_Load(projectDir)
	if message != "" {
		fmt.eprintfln("Couldn't open %s: %s", projectDir, message)
		return 1
	}
	state.project = project
	defer Project_Destroy(&state.project)
	if target == .Web {
		_, hasEmsdk := Toolchain_EmsdkDir()
		_, hasMixer := Toolchain_SDLMixerDir()
		if !hasEmsdk || !hasMixer {
			fmt.println("Installing Emscripten for the web export (about 1 GB, once)...")
			if problem := Toolchain_InstallEmscriptenNow(); problem != "" {
				fmt.eprintfln("Installing Emscripten failed: %s", problem)
				return 1
			}
		}
	}
	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil do return 1
	defer vmem.arena_destroy(&arena)
	allocator := vmem.arena_allocator(&arena)
	input := exportInput(&state, target, allocator)
	plan, problem := Export_Plan(input, allocator)
	if problem == "" && input.odin == "" && (input.hasScripts || input.prebuiltPlayer == "") do problem = "no Odin compiler to build the game with"
	if problem != "" {
		fmt.eprintfln("Export %s: %s", EXPORT_TARGETS[target].label, problem)
		return 1
	}
	defer delete(state.exporting.captured)
	for step in plan.steps {
		fmt.println("--", step.label)
		if step.kind != .Command {
			if message := runFileStep(&state, step); message != "" {
				fmt.eprintfln("Export %s: %s", EXPORT_TARGETS[target].label, message)
				return 1
			}
			continue
		}
		fmt.println(strings.join(step.command, " ", context.temp_allocator))
		result, stdout, stderr, err := Process_Exec({command = step.command, working_dir = step.workingDir}, context.temp_allocator)
		if len(stdout) > 0 do fmt.print(string(stdout))
		if len(stderr) > 0 do fmt.eprint(string(stderr))
		if step.capture {
			clear(&state.exporting.captured)
			append(&state.exporting.captured, ..stdout)
		}
		if err != nil || result.exit_code != 0 {
			fmt.eprintfln("Export %s: %s failed", EXPORT_TARGETS[target].label, step.label)
			return 1
		}
	}
	fmt.printfln("Exported %s to %s%s", EXPORT_TARGETS[target].label, plan.outputDir, plan.archive != "" ? fmt.tprintf(" (and %s)", plan.archive) : "")
	return 0
}
