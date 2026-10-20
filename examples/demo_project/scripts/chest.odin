package scripts

import e "engine:."
import sdl "vendor:sdl3"

/*
Chest: the forest level's goal, an LDtk entity mapped to components/chest.component.xml. Reaching
it opens it (another texture, from code), adds `bonus` to the score, cheers, says so above
itself (text drawn by the script, in the level, through the camera), and ends the run after
`delay` seconds (GameState_EndRun: the high score is kept and saved).
*/
Chest :: struct {
	using script: e.Script,
	bonus: int `export:"default=50 min=0"`,
	delay: f32 `export:"default=3 min=0 max=10"`,
	opened: bool,
	time: f32,
}

@(init)
register_Chest :: proc "contextless" () {
	e.Script_Register(Chest, {
		update = proc(self: ^Chest, _: []sdl.Event, deltaTime: f64) {
			if !self.opened do return
			self.time += f32(deltaTime)
			if self.time >= self.delay {
				if state := e.Global(GameState); state != nil do GameState_EndRun(state)
				self.game->switchScene("MenuScene")
			}
		},
		draw = proc(self: ^Chest, renderer: ^sdl.Renderer) {
			if !self.opened do return
			// In the chest's own space: 54 px above it, scaled by the camera's zoom like the level
			e.DrawTextCentered(&self.game.resourceManager, {0, -54 - self.time * 4}, "Well done!", e.DEFAULT_FONT, 10, {255, 236, 160, 255})
		},
		collisionEnter = proc(self: ^Chest, hit: ^e.Collision) {
			if self.opened || !e.Node_Is(hit.other, e.CharacterMover) do return
			self.opened = true
			if sprite := e.Node_FindChild(self.node, "Sprite"); e.Node_Is(sprite, e.Sprite) {
				(cast(^e.Sprite)sprite).texture = e.Asset_Texture(self.game, TEXTURE_CHEST_OPEN)
			}
			if state := e.Global(GameState); state != nil do state.score += self.bonus
			e.Game_PlaySound(self.game, SOUND_WIN)
		},
	})
}
