package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "gui:skald"

/*
Play mode: runs the open project in the engine's player as a separate process.

Play saves the project, builds the player (`<engine>/player`) if any engine source is newer
than the last build, then runs `player <project folder>`. Output from the build goes to the
Output tab and output from the game to the Console. Stop kills the game.

Nothing here blocks: the build and the game are child processes, and a `Play_Tick` message
every PLAY_POLL_SECONDS drains their output and checks whether they exited.
*/

// Engine checkout the player is built from. The Taskfile passes the same folder it uses for
// the engine collection
ENGINE_DIR :: #config(ENGINE_DIR, "../odin_sdl_engine")
// Where the player binary is built, relative to the editor's working directory
PLAYER_BINARY :: "build/player/player"

PLAY_POLL_SECONDS :: 0.1

// The child process Play is waiting on
PlayStage :: enum {
	None,
	Building,
	Running,
}

PlaySession :: struct {
	stage: PlayStage,
	process: os.Process,
	// Read end of the pipe receiving the child's stdout and stderr
	pipe: ^os.File,
	// Output received since the last newline
	partial: [dynamic]u8,
}

// Sent every PLAY_POLL_SECONDS while a build or game is running
Play_Tick :: struct {}

// Play: start (save, build if needed, run), or resume when paused
@(private="package")
playStart :: proc(state: ^State) -> skald.Command(Msg) {
	switch state.playState {
	case .Paused:
		if signalGame(state, .Resume) {
			state.playState = .Playing
			logLine(state, .Info, fmt.aprintf("Resumed"))
		}
		return {}
	case .Building, .Playing:
		return {}
	case .Stopped:
	}

	if message := Project_Save(&state.project); message != "" {
		logLine(state, .Error, fmt.aprintf("Play: couldn't save the project: %s", message))
		return {}
	}

	clearOutput(state)
	if playerIsCurrent() {
		return startGame(state)
	}

	engineDir := absolutePath(ENGINE_DIR)
	playerSource, _ := filepath.join({engineDir, "player"}, context.temp_allocator)
	// Optimized, like an exported game. Rebuilt only when the engine changes
	command := []string{"odin", "build", playerSource, "-o:speed", fmt.tprintf("-out:%s", playerPath())}
	outputLine(state, .Info, fmt.aprintf("$ %s", strings.join(command, " ", context.temp_allocator)))

	if !startProcess(state, command, "") {
		return {}
	}
	state.play.stage = .Building
	state.playState = .Building
	state.bottomTab = .Output
	state.layout.bottomOpen = true
	return skald.cmd_delay(PLAY_POLL_SECONDS, Msg(Play_Tick{}))
}

// Pause: freezes the game process (Linux and macOS)
@(private="package")
playPause :: proc(state: ^State) {
	if state.playState != .Playing do return
	if signalGame(state, .Pause) {
		state.playState = .Paused
		logLine(state, .Info, fmt.aprintf("Paused"))
	}
}

// Stop: kills the build or game
@(private="package")
playStop :: proc(state: ^State) {
	if state.play.stage == .None do return
	stage := state.play.stage
	if state.playState == .Paused do signalGame(state, .Resume)
	_ = os.process_kill(state.play.process)
	_, _ = os.process_wait(state.play.process) // Reap it
	drainOutput(state, flush = true)
	endSession(state)
	logLine(state, .Info, fmt.aprintf(stage == .Building ? "Build cancelled" : "Stopped"))
}

// Play_Tick: forward output, notice when the child exits
@(private="package")
playTick :: proc(state: ^State) -> skald.Command(Msg) {
	if state.play.stage == .None do return {}
	drainOutput(state)

	status, err := os.process_wait(state.play.process, 0)
	if err == os.General_Error.Timeout || (err == nil && !status.exited) {
		return skald.cmd_delay(PLAY_POLL_SECONDS, Msg(Play_Tick{}))
	}

	drainOutput(state, flush = true)
	stage := state.play.stage
	endSession(state)

	if err != nil {
		logLine(state, .Error, fmt.aprintf("Play: lost track of the process: %v", err))
		return {}
	}
	switch stage {
	case .Building:
		if status.exit_code != 0 {
			logLine(state, .Error, fmt.aprintf("Play: building the player failed (exit code %d). See the Output tab", status.exit_code))
			return {}
		}
		outputLine(state, .Info, fmt.aprintf("Player built"))
		return startGame(state)
	case .Running:
		level := status.exit_code == 0 ? LogLevel.Info : LogLevel.Error
		logLine(state, level, fmt.aprintf("Game exited (exit code %d)", status.exit_code))
	case .None:
	}
	return {}
}

// Runs the built player on the saved project
@(private="file")
startGame :: proc(state: ^State) -> skald.Command(Msg) {
	projectDir := absolutePath(state.project.rootPath)
	command := []string{playerPath(), projectDir}
	logLine(state, .Info, fmt.aprintf("Playing %s", projectDir))
	if !startProcess(state, command, projectDir) {
		return {}
	}
	state.play.stage = .Running
	state.playState = .Playing
	state.bottomTab = .Console
	return skald.cmd_delay(PLAY_POLL_SECONDS, Msg(Play_Tick{}))
}

// Starts a child process with stdout and stderr going into one pipe
@(private="file")
startProcess :: proc(state: ^State, command: []string, workingDir: string) -> bool {
	reader, writer, pipeErr := os.pipe()
	if pipeErr != nil {
		logLine(state, .Error, fmt.aprintf("Play: couldn't create a pipe: %v", pipeErr))
		return false
	}
	process, err := os.process_start({command = command, working_dir = workingDir, stdout = writer, stderr = writer})
	// The child has its own copy; closing ours lets reads end when the child exits
	os.close(writer)
	if err != nil {
		os.close(reader)
		logLine(state, .Error, fmt.aprintf("Play: couldn't start %s: %v", command[0], err))
		return false
	}
	state.play.process = process
	state.play.pipe = reader
	return true
}

// Moves complete lines from the pipe to the Output (building) or Console (running) tab.
// flush also sends a final line without a newline
@(private="file")
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
	line, level := parseLogLine(strings.trim_right(line, "\r"))
	if state.play.stage == .Building {
		outputLine(state, level, strings.clone(line))
	} else {
		logLine(state, level, strings.clone(line), echo = false)
	}
}

@(private="file")
endSession :: proc(state: ^State) {
	if state.play.pipe != nil do os.close(state.play.pipe)
	delete(state.play.partial)
	state.play = {}
	state.playState = .Stopped
}

@(private="file")
GameSignal :: enum {
	Pause,
	Resume,
}

@(private="file")
signalGame :: proc(state: ^State, signal: GameSignal) -> bool {
	when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD {
		if state.play.stage != .Running do return false
		posixSignal := signal == .Pause ? posix.Signal.SIGSTOP : posix.Signal.SIGCONT
		return posix.kill(posix.pid_t(state.play.process.pid), posixSignal) == .OK
	} else {
		logLine(state, .Warning, fmt.aprintf("Pausing the game isn't supported on this platform yet"))
		return false
	}
}

// Whether the player binary exists and is newer than every engine source file
@(private="file")
playerIsCurrent :: proc() -> bool {
	built, err := os.modification_time_by_path(PLAYER_BINARY)
	if err != nil do return false
	engineDir := absolutePath(ENGINE_DIR)
	playerDir, _ := filepath.join({engineDir, "player"}, context.temp_allocator)
	return time.diff(newestSource(engineDir), built) > 0 && time.diff(newestSource(playerDir), built) > 0
}

@(private="file")
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

@(private="file")
absolutePath :: proc(path: string) -> string {
	result, err := os.get_absolute_path(path, context.temp_allocator)
	return err == nil ? result : path
}

@(private="file")
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
