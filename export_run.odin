package editor

import "core:fmt"
import "core:hash"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"

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
	if message := Project_Save(&state.project); message != "" {
		logLine(state, .Error, fmt.aprintf("Export: couldn't save the project: %s", message))
		return {}
	}
	Session_MarkSaved(state)
	clearOutput(state)
	state.exporting.succeeded, state.exporting.failed = 0, 0

	for target in targets {
		job := new(ExportJob)
		if err := vmem.arena_init_growing(&job.arena); err != nil {
			free(job)
			logLine(state, .Error, fmt.aprintf("Export: out of memory"))
			break
		}
		problem: string
		job.plan, problem = Export_Plan(exportInput(state, target, vmem.arena_allocator(&job.arena)), vmem.arena_allocator(&job.arena))
		if problem == "" && target == .Web && !os.exists(Export_EmccPath(absolutePath(EMSDK_DIR), context.temp_allocator)) {
			problem = "The web export needs Emscripten. In the editor's folder, run: task emsdk (about 1 GB, once per machine)"
		}
		if problem == "" && target == .Web && !os.exists(joinPath(SDL_MIXER_DIR, "src", "SDL_mixer.c", allocator = context.temp_allocator)) {
			problem = "The web export needs the SDL_mixer sources. In the editor's folder, run: task submodules"
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
	if !Export_Busy(state) do return {}
	state.bottomTab = .Output
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
	folder := fmt.tprintf("%s-%x", sanitize(filepath.base(projectDir)), hash.fnv32a(transmute([]byte)projectDir))
	workDir := absolutePath(joinPath(EXPORT_WORK_DIR, folder, allocator = context.temp_allocator))
	_ = os.make_directory_all(workDir)
	// The folder exists now, so this is absolute
	workDir = absolutePath(workDir)
	_ = os.make_directory_all(WEB_LIB_DIR)
	webLibDir := absolutePath(WEB_LIB_DIR)
	return {
		target = target,
		settings = state.project.exports.targets[target],
		projectDir = strings.clone(projectDir, allocator),
		projectName = strings.clone(state.project.name, allocator),
		hasScripts = Project_HasScripts(&state.project),
		files = Export_ProjectFiles(&state.project, allocator),
		projectXML = Export_ProjectXML(&state.project, allocator),
		engineDir = strings.clone(absolutePath(ENGINE_DIR), allocator),
		emsdkDir = strings.clone(absolutePath(EMSDK_DIR), allocator),
		mixerDir = strings.clone(absolutePath(SDL_MIXER_DIR), allocator),
		mixerBuildScript = strings.clone(absolutePath(WEB_MIXER_SCRIPT), allocator),
		webLibDir = strings.clone(webLibDir, allocator),
		webMixerBuilt = os.exists(joinPath(webLibDir, "libSDL3_mixer.a", allocator = context.temp_allocator)),
		webBox2DBuilt = os.exists(joinPath(absolutePath(ENGINE_DIR), "box2d", "lib", "box2d_web.o", allocator = context.temp_allocator)),
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
		outputLine(state, .Info, fmt.aprintf("[%s] %s", EXPORT_TARGETS[job.plan.target].label, step.label))
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
	outputLine(state, session.failed > 0 ? .Warning : .Info, strings.clone(summary))
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
	case .Bundle_Libraries:
		libraries := Export_ParseLdd(string(state.exporting.captured[:]), context.temp_allocator)
		if len(libraries) == 0 do return "ldd found no SDL3 libraries in the game"
		_ = os.make_directory_all(step.path)
		for library in libraries {
			// Saved under the name the game asks for (the soname ldd printed), resolving symlinks
			to := joinPath(step.path, filepath.base(library), allocator = context.temp_allocator)
			if err := os.copy_file(to, library); err != nil do return fmt.tprintf("couldn't copy %s: %v", library, err)
			outputLine(state, .Info, fmt.aprintf("  %s", filepath.base(library)))
		}
	case .Make_Folder:
		if err := os.make_directory_all(step.path); err != nil && !os.is_dir(step.path) do return fmt.tprintf("couldn't create %s: %v", step.path, err)
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
	outputLine(state, .Info, fmt.aprintf("$ %s", strings.join(step.command, " ", context.temp_allocator)))
	process, err := os.process_start({command = step.command, working_dir = step.workingDir, stdout = writer, stderr = writer})
	os.close(writer)
	if err != nil {
		os.close(reader)
		outputLine(state, .Error, fmt.aprintf("%v", err))
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
	text, level := parseLogLine(strings.trim_right(line, "\r"))
	outputLine(state, level, strings.clone(text))
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
