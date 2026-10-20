package scripts

import "core:math"
import e "engine:."
import sdl "vendor:sdl3"

/*
Key and Gate: an LDtk entity reference. In LDtk the key's "opens" field is an EntityRef to the
gate (drawn as an arrow between them); e.LDtk_EntityRefNode finds the gate's node from it, so
the level decides which key opens which gate, not the code.

The gate is a StaticBody (components/gate.component.xml) that blocks the way to the chest.
Taking the key opens it: it fades away and is removed.
*/
Key :: struct {
	using script: e.Script,
	sprite: ^e.Node,
	time: f32,
	taken: bool,
}

Gate :: struct {
	using script: e.Script,
	// Seconds it takes to fade away
	fadeTime: f32 `export:"default=0.8 min=0.05 max=5"`,
	opening: bool,
	faded: f32,
}

// Opens a gate: it fades away, then goes
Gate_Open :: proc(gate: ^Gate) {
	if gate.opening do return
	gate.opening = true
	e.Game_PlaySound(gate.game, SOUND_GATE)
}

@(init)
register_Key :: proc "contextless" () {
	e.Script_Register(Key, {
		ready = proc(self: ^Key) {
			self.sprite = e.Node_FindChild(self.node, "Sprite")
		},
		update = proc(self: ^Key, _: []sdl.Event, deltaTime: f64) {
			self.time += f32(deltaTime)
			if self.sprite != nil do self.sprite.position.y = math.sin(self.time * 3) * 2
		},
		collisionEnter = proc(self: ^Key, hit: ^e.Collision) {
			if self.taken || !e.Node_Is(hit.other, e.CharacterMover) do return
			self.taken = true
			e.Game_PlaySound(self.game, SOUND_KEY)
			// The entity the key's "opens" field points at, in LDtk
			if gate := e.Node_GetScript(e.LDtk_EntityRefNode(self.node, "opens"), Gate); gate != nil do Gate_Open(gate)
			e.Scene_RemoveNode(self.scene, self.node.id)
		},
	})
	e.Script_Register(Gate, {
		update = proc(self: ^Gate, _: []sdl.Event, deltaTime: f64) {
			if !self.opening do return
			self.faded += f32(deltaTime) / self.fadeTime
			self.node.tint.a = u8(255 * clamp(1 - self.faded, 0, 1))
			if self.faded >= 1 do e.Scene_RemoveNode(self.scene, self.node.id)
		},
	})
}
