package scripts

import "core:math"
import "core:math/rand"
import e "engine:."

/*
Rock: on a DynamicBody. It drifts and bounces off the walls (restitution 1, no gravity in this
project); touching the player costs a life (GameState_Hit, which plays SOUND_HIT: a generated
asset constant).
*/
Rock :: struct {
	using script: e.Script,
	speed: f32 `export:"default=160 min=0"`,
}

@(init)
register_Rock :: proc "contextless" () {
	e.Script_Register(Rock, {
		ready = proc(self: ^Rock) {
			angle := rand.float32_range(0, 2 * math.PI)
			e.DynamicBody_SetVelocity(cast(^e.DynamicBody)self.node, [2]f32{math.cos(angle), math.sin(angle)} * self.speed)
			e.DynamicBody_SetAngularVelocity(cast(^e.DynamicBody)self.node, rand.float32_range(-60, 60))
		},
		collisionEnter = proc(self: ^Rock, hit: ^e.Collision) {
			if !e.Node_Is(hit.other, e.CharacterMover) do return
			if state := e.Global(GameState); state != nil do GameState_Hit(state)
		},
	})
}
