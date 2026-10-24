package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "gui:skald"

/*
Hot reload: scripts saved while the game plays restart it where it was (`settings.hotReload`).

While a project player runs, `playReloadTick` (every Play_Tick) looks at the scripts folder
every PLAY_RELOAD_LOOK ticks. When a script is newer than what the game was built from, or the
log points changed (log_points.odin: `LogPoints_Signature` against `builtLogPoints`):

1. **Build** the player again beside the running one (`player-reload` in the same folder: the
   running binary can't be overwritten on Windows, and Linux refuses to write a running file).
   The game goes on; the build's output goes to the Output tab. A failed build is logged and the
   game keeps running the old code.
2. **Describe** the new player's scripts (`--describe-scripts`), so the inspector's catalog
   matches the code the game will run.
3. **Snapshot**: the live link's `snapshot <file>` makes the game write its state (the engine's
   hot_reload.odin: its scene, its globals, every node's properties) and reply. A game that
   doesn't answer within PLAY_RELOAD_WAIT seconds (frozen by Pause without the live link) is
   restarted without its state.
4. **Restart**: the old game is stopped, `player-reload` replaces `player`, and the new one starts
   with `--restore <file>`.

Saves made during a build are noticed after the restart (the build's sources are dated when it
starts), so the game always ends up running the newest code.
*/

// Ticks of PLAY_POLL_SECONDS between looks at the scripts folder
PLAY_RELOAD_LOOK :: 5
// Seconds the game has to write its snapshot
PLAY_RELOAD_WAIT :: 3.0

// Where a hot reload is
PlayReloadStage :: enum {
	None,
	Building,
	Describing,
	// Waiting for the game's snapshot
	Snapshot,
}

// A hot reload's build beside the running game (PlaySession.reload)
PlayReload :: struct {
	stage: PlayReloadStage,
	// The build or the description
	process: os.Process,
	// Its stdout and stderr
	pipe: ^os.File,
	// Output since the last newline
	partial: [dynamic]u8,
	// What --describe-scripts printed
	described: [dynamic]u8,
	// The newest script the running game was built from
	built: time.Time,
	// The newest script when this build started: the restarted game's `built`
	building: time.Time,
	// The log points the running game was built with (`LogPoints_Signature`), and this build's
	builtLogPoints, buildingLogPoints: u64,
	// Ticks until the next look at the scripts folder
	look: int,
	// When the snapshot was asked for
	asked: time.Tick,
	// The game's reply: whether it wrote the snapshot
	snapshotDone, snapshotOk: bool,
}

/*
Called while the game runs (playTick): looks for changed scripts, moves a reload along and
restarts the game when it's ready.

Returns:
- The restarted game's tick, and true when it restarted (the session is the new game's)
*/
@(private="package")
playReloadTick :: proc(state: ^State) -> (skald.Command(Msg), bool) {
	reload := &state.play.reload
	switch reload.stage {
	case .None:
		if !state.settings.hotReload || !Project_HasScripts(&state.project) do return {}, false
		reload.look -= 1
		if reload.look > 0 do return {}, false
		reload.look = PLAY_RELOAD_LOOK
		// A change to assets.odin's constants no script uses isn't one (script_constants.odin)
		newest := Scripts_NewestFor(playReloadScripts(state), playerTarget(state).binary)
		// Log points added, changed or removed build it again too (log_points.odin)
		scriptsChanged := time.diff(reload.built, newest) > 0
		if !scriptsChanged && LogPoints_Signature(&state.logPoints) == reload.builtLogPoints do return {}, false
		playReloadBuild(state, newest, scriptsChanged ? "scripts changed" : "log points changed")
	case .Building, .Describing:
		playReloadDrain(state)
		status, err := os.process_wait(reload.process, 0)
		if err == os.General_Error.Timeout || (err == nil && !status.exited) do return {}, false
		playReloadDrain(state, flush = true)
		stage := reload.stage
		playReloadEndProcess(state)
		if err != nil || status.exit_code != 0 {
			if stage == .Building {
				logLine(state, .Error, fmt.aprintf("Hot reload: the scripts don't build (see the Output tab); the game goes on with the old code"))
			} else {
				logLine(state, .Error, fmt.aprintf("Hot reload: the new player couldn't describe its scripts (exit code %d); the game goes on", status.exit_code))
			}
			playReloadDone(state)
			return {}, false
		}
		if stage == .Building {
			outputLine(state, .Info, fmt.aprintf("Hot reload: built"))
			if !playReloadStart(state, {playReloadBinary(state), "--describe-scripts"}) {
				playReloadDone(state)
				return {}, false
			}
			reload.stage = .Describing
			return {}, false
		}
		described := string(reload.described[:])
		if !takeDescription(state, described, status.exit_code) {
			playReloadDone(state)
			return {}, false
		}
		delete(reload.described)
		reload.described = {}
		// The game writes its state and replies (Live_Ingest sets snapshotDone)
		reload.snapshotDone, reload.snapshotOk = false, false
		reload.asked = time.tick_now()
		if !Live_Send(state, fmt.tprintf("snapshot %s", playReloadSnapshotPath(state))) do reload.snapshotDone = true
		reload.stage = .Snapshot
	case .Snapshot:
		waited := time.duration_seconds(time.tick_since(reload.asked))
		if !reload.snapshotDone && waited < PLAY_RELOAD_WAIT do return {}, false
		return playReloadRestart(state), true
	}
	return {}, false
}

/*
The live link's reply to `snapshot` (Live_Ingest).

Inputs:
- ok: Whether the game wrote its snapshot
*/
@(private="package")
playReloadSnapshotTaken :: proc(state: ^State, ok: bool) {
	if state.play.reload.stage != .Snapshot do return
	state.play.reload.snapshotDone = true
	state.play.reload.snapshotOk = ok
}

// A game just started (startGame): its scripts are the folder's as they are now
@(private="package")
playReloadStarted :: proc(state: ^State) {
	state.play.reload.look = PLAY_RELOAD_LOOK
	if Project_HasScripts(&state.project) do state.play.reload.built = newestSource(playReloadScripts(state))
	state.play.reload.builtLogPoints = LogPoints_Signature(&state.logPoints)
}

// Stops a reload's process (the session ends: endSession)
@(private="package")
playReloadAbort :: proc(state: ^State) {
	reload := &state.play.reload
	if reload.stage == .Building || reload.stage == .Describing {
		_ = os.process_kill(reload.process)
		_, _ = os.process_wait(reload.process)
		playReloadEndProcess(state)
	}
	delete(reload.partial)
	delete(reload.described)
	reload^ = {}
}

// INTERNAL

// Starts the build of the new player
@(private="file")
playReloadBuild :: proc(state: ^State, newest: time.Time, why: string) {
	reload := &state.play.reload
	target := playerTarget(state)
	odin := Toolchain_Odin(FixedText_String(&state.settings.odinPath))
	if odin == "" {
		logLine(state, .Error, fmt.aprintf("Hot reload: no Odin compiler (Settings > Toolchain)"))
		reload.built = newest
		return
	}
	if message := Scripts_WriteAssetsFile(&state.project); message != "" do logLine(state, .Warning, strings.clone(message))
	// Log points: the build's copy of the scripts with them in
	reload.buildingLogPoints = LogPoints_Signature(&state.logPoints)
	reload.builtLogPoints = reload.buildingLogPoints
	if target.logPoints != "" do logPointsWriteBuild(state, target.logPoints)
	command := playerBuildCommand(state, odin, target, playReloadBinary(state))
	outputLine(state, .Info, fmt.aprintf("Hot reload: $ %s", strings.join(command, " ", context.temp_allocator)))
	logLine(state, .Info, fmt.aprintf("Hot reload: %s, building the game again...", why))
	reload.building = newest
	// The constants it's built with (beside the binary it replaces when it's through)
	Constants_Snapshot(&state.project, playerTarget(state).binary)
	// What this build sees (the script index describes files changed after it)
	state.scriptsBuildSource = Scripts_NewestSource(&state.project)
	// Not again until this one is through
	reload.built = newest
	if playReloadStart(state, command) do reload.stage = .Building
}

// Stops the game and starts the new player where it was
@(private="file")
playReloadRestart :: proc(state: ^State) -> skald.Command(Msg) {
	reload := state.play.reload
	snapshot := reload.snapshotOk ? playReloadSnapshotPath(state) : ""
	if !reload.snapshotOk do logLine(state, .Warning, fmt.aprintf("Hot reload: the game didn't save its state; it starts over"))
	// The game first: then its binary can be replaced
	if state.playState == .Paused && !state.live.connected do signalGame(state, .Resume)
	_ = os.process_kill(state.play.process)
	_, _ = os.process_wait(state.play.process)
	drainOutput(state, flush = true)
	endSession(state)
	target := playerTarget(state)
	if err := os.rename(playReloadBinary(state), target.binary); err != nil {
		logLine(state, .Error, fmt.aprintf("Hot reload: couldn't replace the player: %v", err))
		return {}
	}
	logLine(state, .Info, fmt.aprintf(snapshot != "" ? "Hot reload: restarting the game where it was" : "Hot reload: restarting the game"))
	command := startGame(state, snapshot)
	// What the new game was built from (saves during the build start another reload)
	if state.play.stage == .Running {
		state.play.reload.built = reload.building
		state.play.reload.builtLogPoints = reload.buildingLogPoints
	}
	return command
}

// A reload that went nowhere: the game goes on, waiting for the next save
@(private="file")
playReloadDone :: proc(state: ^State) {
	reload := &state.play.reload
	delete(reload.described)
	reload.described = {}
	reload.stage = .None
	reload.look = PLAY_RELOAD_LOOK
}

@(private="file")
playReloadStart :: proc(state: ^State, command: []string) -> bool {
	reader, writer, pipeErr := os.pipe()
	if pipeErr != nil {
		logLine(state, .Error, fmt.aprintf("Hot reload: couldn't create a pipe: %v", pipeErr))
		return false
	}
	process, err := os.process_start({command = command, stdout = writer, stderr = writer})
	os.close(writer)
	if err != nil {
		os.close(reader)
		logLine(state, .Error, fmt.aprintf("Hot reload: couldn't start %s: %v", command[0], err))
		return false
	}
	state.play.reload.process = process
	state.play.reload.pipe = reader
	return true
}

@(private="file")
playReloadEndProcess :: proc(state: ^State) {
	reload := &state.play.reload
	if reload.pipe != nil do os.close(reload.pipe)
	reload.pipe = nil
	reload.process = {}
	clear(&reload.partial)
}

// The build's lines go to the Output tab; the description's are kept
@(private="file")
playReloadDrain :: proc(state: ^State, flush := false) {
	reload := &state.play.reload
	if reload.pipe == nil do return
	buffer: [4096]u8
	for {
		hasData, err := os.pipe_has_data(reload.pipe)
		if !hasData || err != nil do break
		n, _ := os.read(reload.pipe, buffer[:])
		if n <= 0 do break
		append(&reload.partial, ..buffer[:n])
	}
	start := 0
	for b, i in reload.partial {
		if b != '\n' do continue
		playReloadLine(state, string(reload.partial[start:i]))
		start = i + 1
	}
	remove_range(&reload.partial, 0, start)
	if flush && len(reload.partial) > 0 {
		playReloadLine(state, string(reload.partial[:]))
		clear(&reload.partial)
	}
}

@(private="file")
playReloadLine :: proc(state: ^State, line: string) {
	reload := &state.play.reload
	if reload.stage == .Describing {
		append(&reload.described, ..transmute([]u8)line)
		append(&reload.described, '\n')
		return
	}
	text, level, _ := parseLogLine(strings.trim_right(line, "\r"))
	outputLine(state, level, strings.clone(LogPoints_ProjectPaths(state, text)))
}

// The project's scripts folder (temp allocated)
@(private="file")
playReloadScripts :: proc(state: ^State) -> string {
	return joinPath(absolutePath(state.project.rootPath), SCRIPTS_FOLDER, allocator = context.temp_allocator)
}

// The new player, beside the running one (temp allocated)
@(private="file")
playReloadBinary :: proc(state: ^State) -> string {
	return fmt.tprintf("%s-reload", playerTarget(state).binary)
}

// Where the game writes its state for the new player (temp allocated)
@(private="file")
playReloadSnapshotPath :: proc(state: ^State) -> string {
	path, _ := filepath.join({filepath.dir(playerTarget(state).binary), "snapshot.json"}, context.temp_allocator)
	return path
}
