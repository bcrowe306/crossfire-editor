package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "gui:skald"

/*
Play mode: runs the open project in a player program, as a separate process.

Which player: a project without scripts uses the engine's own (`<engine>/player`). A project with
scripts gets its own, generated in `build/players/<project>/`: a two-line main that imports the
engine and the project's `scripts` package (`-collection:project=<project folder>`) and calls
`e.Player_Run` (see `playerMainSource`).

Play saves the project, builds the player if any engine or script source is newer than it, asks a
project player to describe its scripts (`--describe-scripts`, which fills the inspector's script
catalog: scripts.odin), then runs `player <project folder>`. Build Scripts (Ctrl+B) does the same
without running the game. Output from the build goes to the Output tab and from the game to the
Console. Stop kills whichever is running.

Builds are unoptimized unless `settings.optimizedPlay` is on: a project player builds in about 4 s
that way, against about 50 s with -o:speed (exports have their own Optimize setting).

Nothing here blocks: the build, the description and the game are child processes, and a
`Play_Tick` message every PLAY_POLL_SECONDS drains their output and checks whether they exited.
*/

// Engine checkout the player is built from. The Taskfile passes the same folder it uses for
// the engine collection
ENGINE_DIR :: #config(ENGINE_DIR, "../odin_sdl_engine")
// Where the engine's player binary is built, relative to the editor's working directory
PLAYER_BINARY :: "build/player/player"
// Where projects with scripts get their own players: build/players/<project>/player
PROJECT_PLAYERS_DIR :: "build/players"

PLAY_POLL_SECONDS :: 0.1

// The child process Play is waiting on
PlayStage :: enum {
	None,
	Building,
	// The player printing its scripts (--describe-scripts)
	Describing,
	Running,
}

// What a session is for: only build and describe the scripts, or play the game. Describe is the
// zero value, so a session that lost track of it never starts the game by accident
PlayPurpose :: enum {
	Describe,
	Play,
}

PlaySession :: struct {
	stage: PlayStage,
	purpose: PlayPurpose,
	// What --describe-scripts printed
	described: [dynamic]u8,
	process: os.Process,
	// Read end of the pipe receiving the child's stdout and stderr
	pipe: ^os.File,
	// Write end of the game's stdin: the live view's commands (live_edit.odin; nil for builds)
	stdin: ^os.File,
	// Output received since the last newline
	partial: [dynamic]u8,
	// Hot reload: the build running beside the game (play_reload.odin)
	reload: PlayReload,
}

// Sent every PLAY_POLL_SECONDS while a build or game is running
Play_Tick :: struct {}

// Play: start (save, build if needed, run), or resume when paused
@(private="package")
playStart :: proc(state: ^State, scene := "") -> skald.Command(Msg) {
	switch state.playState {
	case .Paused:
		if pauseGame(state, false) {
			state.playState = .Playing
			logLine(state, .Info, fmt.aprintf("Resumed"))
		}
		return {}
	case .Building, .Playing:
		return {}
	case .Stopped:
	}

	if !CodeTabs_SaveAll(state) do return {}
	_ = Shaders_Compile(state)
	if message := Project_Save(&state.project); message != "" {
		logLine(state, .Error, fmt.aprintf("Play: couldn't save the project: %s", message))
		return {}
	}
	Session_MarkSaved(state)

	clearOutput(state)
	// Which scene to start in: "" for the project's start scene. Kept until the game runs
	delete(playScene)
	playScene = strings.clone(scene)
	return buildPlayer(state, .Play)
}

// The scene Play Scene asked for, "" for the start scene. Package state: endSession clears the
// session between the build and the run
@(private="file")
playScene: string

/*
Build Scripts: builds the project's player if needed and reads its scripts, without playing.
*/
@(private="package")
scriptsBuild :: proc(state: ^State) -> skald.Command(Msg) {
	if state.play.stage != .None {
		logLine(state, .Warning, fmt.aprintf("Stop the game first: it's using the player"))
		return {}
	}
	// Any build counts as the one the editor would start by itself for this project
	state.scriptsAutoBuilt = true
	if !Project_HasScripts(&state.project) {
		logLine(state, .Info, fmt.aprintf("This project has no scripts yet (no .odin files in %s/)", SCRIPTS_FOLDER))
		state.scripts.status = .Unknown
		return {}
	}
	clearOutput(state)
	return buildPlayer(state, .Describe)
}

// Builds the player the project needs (if it's out of date), then describes or runs it
@(private="file")
buildPlayer :: proc(state: ^State, purpose: PlayPurpose) -> skald.Command(Msg) {
	state.play.purpose = purpose
	// The scripts compile against the current asset constants
	if message := Scripts_WriteAssetsFile(&state.project); message != "" do logLine(state, .Warning, strings.clone(message))
	target := playerTarget(state)
	if Project_HasScripts(&state.project) do state.scripts.status = .Building
	if target.prebuilt || playerIsCurrent(target) {
		return afterBuild(state)
	}

	odin := Toolchain_Odin(FixedText_String(&state.settings.odinPath))
	if odin == "" {
		logLine(state, .Error, fmt.aprintf("No Odin compiler to build the game with: install one in Settings > Toolchain"))
		state.scripts.status = .Failed
		return {}
	}
	command := playerBuildCommand(state, odin, target, target.binary)
	outputLine(state, .Info, fmt.aprintf("$ %s", strings.join(command, " ", context.temp_allocator)))

	if !startProcess(state, command, "") {
		state.scripts.status = .Failed
		return {}
	}
	state.play.stage = .Building
	state.playState = .Building
	state.bottomTab = .Output
	state.layout.bottomOpen = true
	return skald.cmd_delay(PLAY_POLL_SECONDS, Msg(Play_Tick{}))
}

// The command building a player target into `binary` (temp allocated)
@(private="package")
playerBuildCommand :: proc(state: ^State, odin: string, target: PlayerTarget, binary: string) -> []string {
	engineDir, _ := Toolchain_EngineDir()
	command := make([dynamic]string, context.temp_allocator)
	append(&command, odin, "build", target.source, fmt.tprintf("-collection:engine=%s", engineDir))
	if target.project != "" do append(&command, fmt.tprintf("-collection:project=%s", target.project))
	if state.settings.optimizedPlay do append(&command, "-o:speed")
	append(&command, fmt.tprintf("-out:%s", binary))
	return command[:]
}

// After a build: describe a project player's scripts, then play (if that's the purpose)
@(private="file")
afterBuild :: proc(state: ^State) -> skald.Command(Msg) {
	if Project_HasScripts(&state.project) {
		target := playerTarget(state)
		if !startProcess(state, []string{target.binary, "--describe-scripts"}, "") {
			state.scripts.status = .Failed
			return {}
		}
		state.play.stage = .Describing
		state.playState = .Building
		return skald.cmd_delay(PLAY_POLL_SECONDS, Msg(Play_Tick{}))
	}
	if state.play.purpose == .Play do return startGame(state)
	return {}
}

// Pause: freezes the game process (Linux and macOS)
@(private="package")
playPause :: proc(state: ^State) {
	if state.playState != .Playing do return
	if pauseGame(state, true) {
		state.playState = .Paused
		logLine(state, .Info, fmt.aprintf("Paused"))
	}
}

// Stop: kills the build or game
@(private="package")
playStop :: proc(state: ^State) {
	if state.play.stage == .None do return
	stage := state.play.stage
	if state.playState == .Paused && !state.live.connected do signalGame(state, .Resume)
	_ = os.process_kill(state.play.process)
	_, _ = os.process_wait(state.play.process) // Reap it
	drainOutput(state, flush = true)
	endSession(state)
	if stage != .Running && state.scripts.status == .Building do state.scripts.status = .Unknown
	logLine(state, .Info, fmt.aprintf(stage == .Running ? "Stopped" : "Build cancelled"))
}

// Play_Tick: forward output, notice when the child exits
@(private="package")
playTick :: proc(state: ^State) -> skald.Command(Msg) {
	if state.play.stage == .None do return {}
	drainOutput(state)
	// Hot reload: its build beside the game, and the restart (play_reload.odin)
	if state.play.stage == .Running {
		if command, restarted := playReloadTick(state); restarted do return command
	}

	status, err := os.process_wait(state.play.process, 0)
	if err == os.General_Error.Timeout || (err == nil && !status.exited) {
		return skald.cmd_delay(PLAY_POLL_SECONDS, Msg(Play_Tick{}))
	}

	drainOutput(state, flush = true)
	stage := state.play.stage
	purpose := state.play.purpose
	// endSession frees the session; keep what the player described
	described := state.play.described
	state.play.described = {}
	endSession(state)

	if err != nil {
		logLine(state, .Error, fmt.aprintf("Play: lost track of the process: %v", err))
		return {}
	}
	switch stage {
	case .Building:
		if status.exit_code != 0 {
			state.scripts.status = .Failed
			logLine(state, .Error, fmt.aprintf("Building the player failed (exit code %d). See the Output tab", status.exit_code))
			return {}
		}
		outputLine(state, .Info, fmt.aprintf("Player built"))
		// endSession cleared the session; the next step needs to know what it's for
		state.play.purpose = purpose
		return afterBuild(state)
	case .Describing:
		ok := takeDescription(state, string(described[:]), status.exit_code)
		delete(described)
		if !ok do return {}
		if purpose == .Play do return startGame(state)
	case .Running:
		level := status.exit_code == 0 ? LogLevel.Info : LogLevel.Error
		logLine(state, level, fmt.aprintf("Game exited (exit code %d)", status.exit_code))
	case .None:
	}
	return {}
}

/*
Takes what `--describe-scripts` printed into the script catalog.

Returns:
- false (logged, the catalog failed) when the player failed or printed something else
*/
@(private="package")
takeDescription :: proc(state: ^State, described: string, exitCode: int) -> bool {
	scripts, dataTypes, nodeTypes, ok := ScriptCatalog_ParseAll(described)
	if exitCode != 0 || !ok {
		ScriptCatalog_Clear(&ScriptCatalog{scripts = scripts, dataTypes = dataTypes, nodeTypes = nodeTypes})
		state.scripts.status = .Failed
		logLine(state, .Error, fmt.aprintf("Couldn't read the project's scripts (exit code %d)", exitCode))
		return false
	}
	ScriptCatalog_Clear(&state.scripts)
	state.scripts.scripts = scripts
	state.scripts.dataTypes = dataTypes
	state.scripts.nodeTypes = nodeTypes
	state.scripts.status = .Ready
	outputLine(state, .Info, fmt.aprintf("%d script%s: %s", len(scripts), len(scripts) == 1 ? "" : "s", scriptNames(scripts[:])))
	if len(dataTypes) > 0 do outputLine(state, .Info, fmt.aprintf("%d data type%s: %s", len(dataTypes), len(dataTypes) == 1 ? "" : "s", scriptNames(dataTypes[:])))
	if len(nodeTypes) > 0 do outputLine(state, .Info, fmt.aprintf("%d node type%s: %s", len(nodeTypes), len(nodeTypes) == 1 ? "" : "s", scriptNames(nodeTypes[:])))
	return true
}

/*
Runs the built player on the saved project. restore: a snapshot file to start from (hot reload:
its scene, globals and nodes), else the start scene or Play Scene's
*/
@(private="package")
startGame :: proc(state: ^State, restore := "") -> skald.Command(Msg) {
	projectDir := absolutePath(state.project.rootPath)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, playerTarget(state).binary, projectDir)
	// Developer keys (F9: collision shapes, F10: the debug overlay); exported games never get them
	append(&command, "--dev")
	// The live view (the Live tab): commands on its stdin, replies in its output
	append(&command, "--live")
	// The machine's sound device (Settings > Editor); exported games use the system's default
	if device := FixedText_String(&state.settings.audioDevice); device != "" do append(&command, "--audio-device", strings.clone(device, context.temp_allocator))
	if restore != "" {
		append(&command, "--restore", restore)
	} else if playScene != "" {
		append(&command, "--scene", playScene)
		logLine(state, .Info, fmt.aprintf("Playing %s from scene %s", projectDir, playScene))
	} else {
		logLine(state, .Info, fmt.aprintf("Playing %s", projectDir))
	}
	Live_Reset(&state.live)
	if !startProcess(state, command[:], projectDir, live = true) {
		return {}
	}
	Live_Send(state, "watch")
	playReloadStarted(state)
	state.play.stage = .Running
	state.playState = .Playing
	state.bottomTab = .Console
	return skald.cmd_delay(PLAY_POLL_SECONDS, Msg(Play_Tick{}))
}

// Starts a child process with stdout and stderr going into one pipe
@(private="file")
startProcess :: proc(state: ^State, command: []string, workingDir: string, live := false) -> bool {
	reader, writer, pipeErr := os.pipe()
	if pipeErr != nil {
		logLine(state, .Error, fmt.aprintf("Play: couldn't create a pipe: %v", pipeErr))
		return false
	}
	// The game's stdin: the live view writes commands to it
	inRead, inWrite: ^os.File
	if live {
		inRead, inWrite, pipeErr = os.pipe()
		if pipeErr != nil do inRead, inWrite = nil, nil
	}
	process, err := os.process_start({command = command, working_dir = workingDir, stdout = writer, stderr = writer, stdin = inRead})
	// The child has its own copies; closing ours lets reads end when the child exits
	os.close(writer)
	if inRead != nil do os.close(inRead)
	if err != nil {
		if inWrite != nil do os.close(inWrite)
		os.close(reader)
		logLine(state, .Error, fmt.aprintf("Play: couldn't start %s: %v", command[0], err))
		return false
	}
	state.play.process = process
	state.play.pipe = reader
	state.play.stdin = inWrite
	return true
}

// Moves complete lines from the pipe to the Output (building) or Console (running) tab.
// flush also sends a final line without a newline
@(private="package")
drainOutput :: proc(state: ^State, flush := false) {
	session := &state.play
	if session.pipe == nil do return
	buffer: [4096]u8
	for {
		hasData, err := os.pipe_has_data(session.pipe)
		if !hasData || err != nil do break
		n, _ := os.read(session.pipe, buffer[:])
		if n <= 0 do break
		append(&session.partial, ..buffer[:n])
	}

	start := 0
	for b, i in session.partial {
		if b == '\n' {
			emitLine(state, string(session.partial[start:i]))
			start = i + 1
		}
	}
	remove_range(&session.partial, 0, start)
	if flush && len(session.partial) > 0 {
		emitLine(state, string(session.partial[:]))
		clear(&session.partial)
	}
}

@(private="file")
emitLine :: proc(state: ^State, line: string) {
	// --describe-scripts output is data, not log lines
	if state.play.stage == .Describing {
		append(&state.play.described, ..transmute([]u8)line)
		append(&state.play.described, '\n')
		return
	}
	// The live view's replies aren't log lines
	if state.play.stage == .Running && strings.has_prefix(line, "@@live ") {
		Live_Ingest(state, strings.trim_right(line[len("@@live "):], "\r"))
		return
	}
	line, level := parseLogLine(strings.trim_right(line, "\r"))
	if state.play.stage == .Building {
		outputLine(state, level, strings.clone(line))
	} else {
		logLine(state, level, strings.clone(line), echo = false)
	}
}

@(private="package")
endSession :: proc(state: ^State) {
	playReloadAbort(state)
	if state.play.pipe != nil do os.close(state.play.pipe)
	if state.play.stdin != nil do os.close(state.play.stdin)
	state.live.connected = false
	delete(state.play.partial)
	delete(state.play.described)
	state.play = {}
	state.playState = .Stopped
}

// Pause / Resume for the running game: signalGame is per platform (play_signal_*.odin)
@(private="package")
GameSignal :: enum {
	Pause,
	Resume,
}

// What to build for the open project, and where (paths absolute, temp allocated)
@(private="package")
PlayerTarget :: struct {
	// Package folder to build
	source: string,
	binary: string,
	// The project folder, for -collection:project (projects with scripts), else ""
	project: string,
	// Folders whose .odin files the binary depends on
	inputs: []string,
	// A prebuilt player (next to the editor): nothing to build
	prebuilt: bool,
}

@(private="package")
playerTarget :: proc(state: ^State) -> PlayerTarget {
	engineDir, _ := Toolchain_EngineDir()
	if !Project_HasScripts(&state.project) {
		// A release's prebuilt player: no compiler needed
		if host, ok := Toolchain_HostTarget(); ok {
			if prebuilt := Toolchain_PrebuiltPlayer(host); prebuilt != "" do return {binary = prebuilt, prebuilt = true}
		}
		source, _ := filepath.join({engineDir, "player"}, context.temp_allocator)
		inputs := make([]string, 2, context.temp_allocator)
		inputs[0], inputs[1] = engineDir, source
		return {source = source, binary = playerPath(), inputs = inputs}
	}
	projectDir := absolutePath(state.project.rootPath)
	// One player per project folder; the main is rewritten if it changed
	folder := fmt.tprintf("%s-%x", sanitize(filepath.base(projectDir)), hash.fnv32a(transmute([]byte)projectDir))
	dir, _ := filepath.join({PROJECT_PLAYERS_DIR, folder}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	dir = absolutePath(dir)
	mainFile, _ := filepath.join({dir, "main.odin"}, context.temp_allocator)
	source := playerMainSource()
	existing, readErr := os.read_entire_file(mainFile, context.temp_allocator)
	if readErr != nil || string(existing) != source do _ = os.write_entire_file(mainFile, transmute([]byte)source)
	binary, _ := filepath.join({dir, "player"}, context.temp_allocator)
	scripts, _ := filepath.join({projectDir, SCRIPTS_FOLDER}, context.temp_allocator)
	inputs := make([]string, 3, context.temp_allocator)
	inputs[0], inputs[1], inputs[2] = engineDir, scripts, dir
	return {source = dir, binary = binary, project = projectDir, inputs = inputs}
}

/*
The generated main of a project's own player: the engine's player, with the project's scripts
package linked in (its @(init) procedures register the scripts). Play and exports use it; it
builds for the desktop and the browser alike (`e.Player_Main`).
*/
playerMainSource :: proc() -> string {
	return `// Generated by the editor: the player for a project with scripts. Don't edit; it's rewritten.
package main

import e "engine:."
import scripts "project:scripts"
_ :: scripts

main :: proc() {
	e.Player_Main()
}
`
}

// Whether the player binary exists and is newer than every source it's built from
@(private="file")
playerIsCurrent :: proc(target: PlayerTarget) -> bool {
	built, err := os.modification_time_by_path(target.binary)
	if err != nil do return false
	for dir in target.inputs do if time.diff(newestSource(dir), built) <= 0 do return false
	return true
}

// "My Game!" -> "My_Game_"
@(private="package")
sanitize :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in name do strings.write_rune(&b, (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' ? r : '_')
	return strings.to_string(b)
}

@(private="file")
scriptNames :: proc(scripts: []ScriptDesc) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for s in scripts do append(&names, s.name)
	return len(names) == 0 ? "none" : strings.join(names[:], ", ", context.temp_allocator)
}

@(private="package")
newestSource :: proc(dir: string) -> time.Time {
	newest: time.Time
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return newest
	for entry in entries {
		if entry.type == .Regular && strings.has_suffix(entry.name, ".odin") && time.diff(newest, entry.modification_time) > 0 {
			newest = entry.modification_time
		}
	}
	return newest
}

// Absolute path of the player binary. The game runs from the project folder, so a relative
// path wouldn't resolve. Made from the folder, which exists, because get_absolute_path fails
// for files that don't exist yet
@(private="file")
playerPath :: proc() -> string {
	dir := filepath.dir(PLAYER_BINARY)
	_ = os.make_directory_all(dir)
	path, _ := filepath.join({absolutePath(dir), filepath.base(PLAYER_BINARY)}, context.temp_allocator)
	return path
}

@(private="package")
absolutePath :: proc(path: string) -> string {
	result, err := os.get_absolute_path(path, context.temp_allocator)
	return err == nil ? result : path
}

@(private="package")
clearOutput :: proc(state: ^State) {
	for line in state.output do delete(line.text)
	clear(&state.output)
}

// Appends a line to the Output tab. text must be heap-allocated; the list owns it
@(private="package")
outputLine :: proc(state: ^State, level: LogLevel, text: string) {
	append(&state.output, LogLine{level, text})
}

/*
Splits a line from a child process into its text and level. Lines from Odin's console logger,
like `[WARN ] --- [2026-10-15 18:17:10] [main.odin:45:run()] message`, lose the level tag and
timestamp (the console shows the level itself); other lines are kept as they are, and count as
errors if they look like one (compiler errors contain "Error" or "ERROR").

Inputs:
- line: One line of output

Returns:
- The text to show and its level
*/
parseLogLine :: proc(line: string) -> (text: string, level: LogLevel) {
	LEVELS :: [?]struct{tag: string, level: LogLevel}{
		{"[DEBUG", .Info}, {"[INFO", .Info}, {"[WARN", .Warning}, {"[ERROR", .Error}, {"[FATAL", .Error},
	}
	for entry in LEVELS {
		if !strings.has_prefix(line, entry.tag) do continue
		// Skip "[LEVEL] --- [timestamp] "
		if separator := strings.index(line, "] --- ["); separator >= 0 {
			rest := line[separator + len("] --- ["):]
			if end := strings.index(rest, "] "); end >= 0 {
				return rest[end + 2:], entry.level
			}
		}
		return line, entry.level
	}
	if strings.contains(line, "Error") || strings.contains(line, "ERROR") do return line, .Error
	return line, .Info
}

// Pauses or resumes the game: through its live link (it keeps drawing and answering, and it works
// everywhere), else with a signal (POSIX only)
@(private="file")
pauseGame :: proc(state: ^State, pause: bool) -> bool {
	if state.live.connected && Live_Send(state, pause ? "pause" : "resume") {
		state.live.paused = pause
		state.live.pausePending = true
		state.live.pauseSent = time.tick_now()
		return true
	}
	return signalGame(state, pause ? .Pause : .Resume)
}
