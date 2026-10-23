package scripts

import "core:math"
import e "engine:."
import sdl "vendor:sdl3"

/*
Coin: the forest level's coins, LDtk entities mapped to components/coin.component.xml (an Area
with a sprite). Each coin's "value" field in LDtk sets `value`: the one on the highest platform
is worth 5, and drawn bigger. Taking one adds its value to the coins collected (the HUD shows
them) and removes the coin.
*/
Coin :: struct {
	using script: e.Script,
	value: int `export:"default=1 min=1"`,
	sprite: ^e.Node,
	time: f32,
	taken: bool,
	// e.Scene_AddComponent(self.scene, self.coinparticles, position = {0, 0})
	coinparticles: e.ComponentAsset `export:"default=components/coinparticles.component.xml"`,
	// texture := e.Asset_Texture(self.game, self.coin)
}

@(init)
register_Coin :: proc "contextless" () {
	e.Script_Register(Coin, {
		ready = proc(self: ^Coin) {
			self.sprite = e.Node_FindChild(self.node, "Sprite")
			if self.sprite != nil && self.value > 1 do self.sprite.scale = {1.5, 1.5}
			// Not all in step
			self.time = self.node.position.x * 0.05
		},
		update = proc(self: ^Coin, _: []sdl.Event, deltaTime: f64) {
			self.time += f32(deltaTime)
			if self.sprite != nil do self.sprite.position.y = math.sin(self.time * 4) * 1.5
		},
		collisionEnter = proc(self: ^Coin, hit: ^e.Collision) {
			if self.taken || !e.Node_Is(hit.other, e.CharacterMover) do return
			self.taken = true
			if state := e.Global(GameState); state != nil do state.coins += self.value
			instance := e.Scene_AddComponent(self.scene, self.coinparticles)
			instance.position = self.node.position
			e.Game_PlaySound(self.game, SOUND_COIN)
			e.Scene_RemoveNode(self.scene, self.node.id)
		},
	})
}
