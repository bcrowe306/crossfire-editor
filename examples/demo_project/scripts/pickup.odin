package scripts

import "core:math/rand"
import e "engine:."

/*
Pickup: on an Area (a star). When the player flies into it: points into the global game state,
a sound (an asset handle set in the inspector), a burst of sparks (the scene's "Sparks"
ParticleEmitter, started from code), and the star moves somewhere else.
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
			// A one-shot emitter (emitting and continuous off, burst 1): move it here and fire it
			if sparks := e.Scene_FindNode(self.scene, "Sparks"); sparks != nil && e.Node_Is(sparks, e.ParticleEmitter) {
				sparks.position = e.Node_GetWorldPosition(self.node)
				e.ParticleEmitter_Start(cast(^e.ParticleEmitter)sparks)
			}
			self.node.position = {rand.float32_range(120, 1160), rand.float32_range(120, 600)}
		},
	})
}
