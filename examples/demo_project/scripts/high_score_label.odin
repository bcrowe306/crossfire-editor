package scripts

import "core:fmt"
import e "engine:."
import sdl "vendor:sdl3"

/*
HighScoreLabel: on a Label in the menu. Reads the global game state every frame.
*/
HighScoreLabel :: struct {
	using script: e.Script,
}

@(init)
register_HighScoreLabel :: proc "contextless" () {
	e.Script_Register(HighScoreLabel, {
		update = proc(self: ^HighScoreLabel, _: []sdl.Event, _: f64) {
			state := e.Global(GameState)
			if state == nil || !e.Node_Is(self.node, e.Label) do return
			ship := GameState_Ship(state)
			(cast(^e.Label)self.node).text = fmt.tprintf("Best score: %d     Ship: %s", state.highScore, ship != nil ? ship.name : "?")
		},
	})
}
