package scripts

import e "engine:."
import sdl "vendor:sdl3"

/*
PlayerShip: on the play scene's CharacterMover. Arrow keys or WASD fly it; walls stop it, and it
pushes the rocks. Its look and speed come from the chosen ship's data resource (ShipStats), so
picking another ship in Options changes it with no code change.
*/
PlayerShip :: struct {
	using script: e.Script,
	// Used when the game state has no ship (an asset picker of ShipStats resources)
	fallback: e.DataAsset `export:"kind=ShipStats"`,
	stats: ^ShipStats,
}

@(init)
register_PlayerShip :: proc "contextless" () {
	e.Script_Register(PlayerShip, {
		ready = proc(self: ^PlayerShip) {
			ship := self.fallback
			if state := e.Global(GameState); state != nil && state.ship.path != "" do ship = state.ship
			self.stats = e.Data(ShipStats, ship)
			if self.stats == nil do return
			// The look from the data: its sprite, size and tint on the "Sprite" child
			if sprite := e.Node_FindChild(self.node, "Sprite"); e.Node_Is(sprite, e.Sprite) {
				(cast(^e.Sprite)sprite).texture = e.Asset_Texture(self.game, self.stats.sprite)
				sprite.scale = {self.stats.scale, self.stats.scale}
				sprite.tint = self.stats.tint
			}
		},
		update = proc(self: ^PlayerShip, _: []sdl.Event, dt: f64) {
			mover := cast(^e.CharacterMover)self.node
			keys := sdl.GetKeyboardState(nil)
			direction: [2]f32
			if keys[sdl.Scancode.LEFT] || keys[sdl.Scancode.A] do direction.x -= 1
			if keys[sdl.Scancode.RIGHT] || keys[sdl.Scancode.D] do direction.x += 1
			if keys[sdl.Scancode.UP] || keys[sdl.Scancode.W] do direction.y -= 1
			if keys[sdl.Scancode.DOWN] || keys[sdl.Scancode.S] do direction.y += 1
			speed := self.stats != nil ? self.stats.speed : 300
			mover.velocity = direction * speed
			e.CharacterMover_Move(mover, dt)
		},
	})
}
