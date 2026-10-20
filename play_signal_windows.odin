#+build windows
package crossfire_editor

import "core:fmt"

// Pausing a process needs POSIX signals: not on Windows yet
@(private="package")
signalGame :: proc(state: ^State, signal: GameSignal) -> bool {
	logLine(state, .Warning, fmt.aprintf("Pausing the game isn't supported on this platform yet"))
	return false
}
