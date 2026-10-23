package crossfire_editor

import "core:testing"
import "gui:skald"

// Restart (play.odin) and the toolbar that holds it (view.odin's overflow)

@(test)
restart_needs_a_game_to_restart :: proc(t: ^testing.T) {
	state := State{settings = Settings_Default()}
	testing.expect(t, !Play_CanRestart(&state), "nothing runs")
	state.playState = .Playing
	state.play.stage = .Running
	state.play.purpose = .Play
	testing.expect(t, Play_CanRestart(&state), "a game")
	state.playState = .Paused
	testing.expect(t, Play_CanRestart(&state), "a paused game")
	// Play's build of it: building again restarts it; Build Scripts' build has no game
	state.playState = .Building
	state.play.stage = .Building
	testing.expect(t, Play_CanRestart(&state), "Play's build")
	state.play.purpose = .Describe
	testing.expect(t, !Play_CanRestart(&state), "Build Scripts' build")
	state.play.stage = .Describing
	testing.expect(t, !Play_CanRestart(&state), "Build Scripts describing")
	// Nothing to restart: the message does nothing
	state = State{settings = Settings_Default()}
	command := playRestart(&state)
	testing.expect(t, command.kind == {} && len(command.children) == 0, "no command")
	testing.expect_value(t, state.playState, PlayState.Stopped)
	// Its key is the keymap's (settings.default.ini)
	testing.expect(t, Keymap_Shortcut(&state.settings.keymap, .Restart) == skald.Shortcut{key = .F5, mods = {.Ctrl, .Shift}}, "Restart is Ctrl+Shift+F5")
}

@(test)
toolbar_overflows_in_a_narrow_window :: proc(t: ^testing.T) {
	// The default look: 31 px buttons, 3 px apart, 6 px at the ends
	button, spacing, padding := f32(31), f32(3), f32(6)
	// Everything: 19 buttons, 2 separators of 7 px, 22 items' gaps
	full := padding * 2 + 19 * button + 2 * (1 + spacing * 2) + 22 * spacing
	testing.expect_value(t, Toolbar_Overflow(0, button, spacing, padding), ToolbarOverflow.None)
	testing.expect_value(t, Toolbar_Overflow(1280, button, spacing, padding), ToolbarOverflow.None)
	testing.expect_value(t, Toolbar_Overflow(full, button, spacing, padding), ToolbarOverflow.None)
	// A tiled window (about 650 px): the tools go into the overflow menu
	testing.expect_value(t, Toolbar_Overflow(full - 1, button, spacing, padding), ToolbarOverflow.Tools)
	testing.expect_value(t, Toolbar_Overflow(650, button, spacing, padding), ToolbarOverflow.Tools)
	// Narrower still: the file and undo buttons too
	testing.expect_value(t, Toolbar_Overflow(400, button, spacing, padding), ToolbarOverflow.Files)
}
