package scripts

import "core:fmt"
import e "engine:."
import sdl "vendor:sdl3"

/*
Hud: a GLOBAL SCRIPT that DRAWS. A global's draw hook draws over the scene, in screen space (the
camera doesn't move it), for as long as the game runs. Drawing is up to the global: this one
hides itself (self.hidden) outside the levels, and shows the forest's controls there.
*/
Hud :: struct {
	using script: e.Script,
	color: sdl.Color `export:"default=#ebf0ff"`,
	size: f32 `export:"default=26 min=8 max=72"`,
	// In the forest level: show its controls
	forest: bool,
}

@(init)
register_Hud :: proc "contextless" () {
	e.Script_Register(Hud, {
		sceneChanged = proc(self: ^Hud, scene: ^e.Scene) {
			self.hidden = !IsLevelScene(scene.name)
			self.forest = scene.name == "ForestScene"
		},
		draw = proc(self: ^Hud, renderer: ^sdl.Renderer) {
			state := e.Global(GameState)
			if state == nil do return
			rm := &self.game.resourceManager
			e.DrawText(rm, {24, 18}, fmt.tprintf("Score %d", state.score), e.DEFAULT_FONT, self.size, self.color)
			e.DrawText(rm, {24, 18 + self.size * 1.3}, fmt.tprintf("Lives %d", state.lives), e.DEFAULT_FONT, self.size * 0.8, self.color)
			e.DrawText(rm, {24, 18 + self.size * 2.4}, fmt.tprintf("Best %d", state.highScore), e.DEFAULT_FONT, self.size * 0.8, {150, 160, 185, 255})
			// Blink while safe after a hit
			if state.invulnerable > 0 && int(state.invulnerable * 8) % 2 == 0 {
				e.DrawText(rm, {24, 18 + self.size * 3.5}, "Shields!", e.DEFAULT_FONT, self.size * 0.8, {255, 200, 90, 255})
			}
			if self.forest {
				e.DrawText(rm, {24, 720 - self.size * 1.5}, "Arrows / WASD: move    Space: jump    Esc: menu", e.DEFAULT_FONT, self.size * 0.7, {235, 240, 255, 200})
			}
		},
	})
}
