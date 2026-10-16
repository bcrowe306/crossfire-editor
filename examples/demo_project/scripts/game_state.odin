package scripts

import "core:log"
import e "engine:."
import sdl "vendor:sdl3"

/*
GameState: a GLOBAL SCRIPT. It isn't attached to a node: Project Settings > Globals lists it, so
the game makes one when it starts and keeps it across every scene. Every Play starts from the
values set there (startingLives, ship).

Any script reaches it with e.Global(GameState). e.Save_Game() writes its state as JSON and
e.Load_Game() reads it back, so the high score and the chosen ship survive restarts. What's
saved: fields that aren't exported (the game's state), except save:"-" ones; exported fields
are editor settings and aren't saved, unless tagged save:"" (the ship: the player changes it).
*/
GameState :: struct {
	using script: e.Script,
	// Set in Project Settings > Globals
	startingLives: int `export:"default=3 min=1 max=9"`,
	// The ship flown (a data resource; Options changes it). kind=ShipStats: the picker only lists those
	ship: e.DataAsset `export:"kind=ShipStats" save:""`,

	// The game's own state (saved)
	score: int,
	lives: int,
	highScore: int,
	// Not saved: seconds left of the safety after a hit
	invulnerable: f32 `save:"-"`,
}

// The ship's stats, or nil
GameState_Ship :: proc(state: ^GameState) -> ^ShipStats {
	return e.Data(ShipStats, state.ship)
}

// Takes a life (unless just hit). Ends the run at zero: keeps the high score, saves, back to the menu
GameState_Hit :: proc(state: ^GameState) {
	if state.invulnerable > 0 do return
	state.lives -= 1
	state.invulnerable = 1.5
	e.Game_PlaySound(state.game, SOUND_HIT)
	if state.lives > 0 do return
	if state.score > state.highScore {
		state.highScore = state.score
		log.infof("New high score: %d", state.highScore)
	}
	e.Save_Game()
	state.game->switchScene("MenuScene")
}

@(init)
register_GameState :: proc "contextless" () {
	e.Script_Register(GameState, {
		// Once, when the game starts: bring back the last save (high score, ship)
		ready = proc(self: ^GameState) {
			if e.Load_Game() {
				log.infof("Welcome back: best score %d", self.highScore)
			}
			if GameState_Ship(self) == nil do self.ship = DATA_SCOUT
		},
		update = proc(self: ^GameState, _: []sdl.Event, dt: f64) {
			self.invulnerable = max(self.invulnerable - f32(dt), 0)
		},
		// A new run every time the play scene starts
		sceneChanged = proc(self: ^GameState, scene: ^e.Scene) {
			if scene.name == "PlayScene" {
				self.score = 0
				self.lives = self.startingLives
				self.invulnerable = 0
			}
		},
	})
}
