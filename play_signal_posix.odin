#+build linux, darwin, freebsd, openbsd, netbsd
package editor

import "core:sys/posix"

// Pause freezes the game process (SIGSTOP), Resume continues it (SIGCONT)
@(private="package")
signalGame :: proc(state: ^State, signal: GameSignal) -> bool {
	if state.play.stage != .Running do return false
	posixSignal := signal == .Pause ? posix.Signal.SIGSTOP : posix.Signal.SIGCONT
	return posix.kill(posix.pid_t(state.play.process.pid), posixSignal) == .OK
}
