package scripts

import "core:math/rand"
import e "engine:."

/*
Pickup: on an Area (a star). When the player flies into it: points into the global game state,
a sound (an asset handle set in the inspector), and the star moves somewhere else.
*/
Pickup :: struct {
	using script: e.Script,
	points: int `export:"default=10 min=1"`,
	// A SoundAsset field: the inspector lists the project's sounds
	sound: e.SoundAsset `export:""`,
}

@(init)
register_Pickup :: proc "contextless" () {
	e.Script_Register(Pickup, {
		// For an Area, collisionEnter means a body came inside it
		collisionEnter = proc(self: ^Pickup, hit: ^e.Collision) {
			if !e.Node_Is(hit.other, e.CharacterMover) do return
			if state := e.Global(GameState); state != nil do state.score += self.points
			e.Game_PlaySound(self.game, self.sound)
			self.node.position = {rand.float32_range(120, 1160), rand.float32_range(120, 600)}
		},
	})
}
