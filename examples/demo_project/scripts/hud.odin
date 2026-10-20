package scripts

import "core:fmt"
import e "engine:."
import sdl "vendor:sdl3"

/*
Hud: a GLOBAL SCRIPT that DRAWS. A global's draw hook draws over the scene, in screen space (the
camera doesn't move it), for as long as the game runs. Drawing is up to the global: this one
hides itself (self.hidden) outside the levels.

- The space game: score, lives, best score.
- The forest: a health bar along the top (a pale part trails behind a loss, then drains), the
  coins collected beside a coin, the score (enemies defeated, the chest) on the right, and the
  controls at the bottom.
*/
Hud :: struct {
	using script: e.Script,
	color: sdl.Color `export:"default=#ebf0ff"`,
	size: f32 `export:"default=26 min=8 max=72"`,
	// In the forest level
	forest: bool,
	// The health the bar shows: trails behind the real one after a hit
	shownHealth: f32,
}

@(init)
register_Hud :: proc "contextless" () {
	e.Script_Register(Hud, {
		sceneChanged = proc(self: ^Hud, scene: ^e.Scene) {
			self.hidden = !IsLevelScene(scene.name)
			self.forest = scene.name == "ForestScene"
			if state := e.Global(GameState); state != nil do self.shownHealth = f32(state.maxHealth)
		},
		update = proc(self: ^Hud, _: []sdl.Event, deltaTime: f64) {
			state := e.Global(GameState)
			if state == nil do return
			// Drain toward the real health (at once when it goes up)
			target := f32(state.health)
			self.shownHealth = self.shownHealth > target ? max(self.shownHealth - f32(deltaTime) * 2, target) : target
		},
		draw = proc(self: ^Hud, renderer: ^sdl.Renderer) {
			state := e.Global(GameState)
			if state == nil do return
			if self.forest {
				drawForest(self, state, renderer)
				return
			}
			rm := &self.game.resourceManager
			e.DrawText(rm, {24, 18}, fmt.tprintf("Score %d", state.score), e.DEFAULT_FONT, self.size, self.color)
			e.DrawText(rm, {24, 18 + self.size * 1.3}, fmt.tprintf("Lives %d", state.lives), e.DEFAULT_FONT, self.size * 0.8, self.color)
			e.DrawText(rm, {24, 18 + self.size * 2.4}, fmt.tprintf("Best %d", state.highScore), e.DEFAULT_FONT, self.size * 0.8, {150, 160, 185, 255})
			// Blink while safe after a hit
			if state.invulnerable > 0 && int(state.invulnerable * 8) % 2 == 0 {
				e.DrawText(rm, {24, 18 + self.size * 3.5}, "Shields!", e.DEFAULT_FONT, self.size * 0.8, {255, 200, 90, 255})
			}
		},
	})
}

// The forest's HUD: health bar, coins, score, controls
@(private="file")
drawForest :: proc(self: ^Hud, state: ^GameState, renderer: ^sdl.Renderer) {
	rm := &self.game.resourceManager
	SHADOW :: sdl.Color{10, 14, 24, 170}

	// A panel behind health and coins, so the level's coins don't mix with the count
	panel := sdl.FRect{12, 10, 400, 98}
	e.DrawRoundedRectangle(renderer, &panel, 10, SHADOW)

	// Health: a bar of maxHealth segments
	bar := sdl.FRect{24, 22, 300, 22}
	e.DrawRectangle(renderer, &bar, {60, 20, 28, 255})
	maxHealth := f32(max(state.maxHealth, 1))
	trail := sdl.FRect{bar.x, bar.y, bar.w * clamp(self.shownHealth / maxHealth, 0, 1), bar.h}
	e.DrawRectangle(renderer, &trail, {255, 214, 160, 255})
	fill := sdl.FRect{bar.x, bar.y, bar.w * clamp(f32(state.health) / maxHealth, 0, 1), bar.h}
	low := state.health * 3 <= state.maxHealth
	e.DrawRectangle(renderer, &fill, low ? sdl.Color{235, 60, 50, 255} : sdl.Color{214, 40, 64, 255})
	shine := sdl.FRect{fill.x, fill.y + 2, fill.w, 5}
	e.DrawRectangle(renderer, &shine, {255, 255, 255, 60})
	for i in 1 ..< state.maxHealth {
		x := bar.x + bar.w * f32(i) / maxHealth
		e.DrawLine(renderer, {x, bar.y}, {x, bar.y + bar.h - 1}, {20, 10, 16, 200})
	}
	e.DrawRectangleOutline(renderer, &bar, {235, 240, 255, 220})
	e.DrawText(rm, {bar.x + bar.w + 14, bar.y - 4}, fmt.tprintf("%d / %d", state.health, state.maxHealth), e.DEFAULT_FONT, self.size * 0.8, self.color)

	// Coins: the coin's image (its 16 px tile, the coin small in it), its count
	coin := e.Asset_Texture(self.game, TEXTURE_COIN)
	e.DrawTexture(renderer, coin, {14, 48, 64, 64})
	e.DrawText(rm, {74, 60}, fmt.tprintf("x %d", state.coins), e.DEFAULT_FONT, self.size, {255, 222, 120, 255})

	// Score, right-aligned
	text := fmt.tprintf("Score %d", state.score)
	size := e.MeasureText(rm, text, e.DEFAULT_FONT, self.size)
	e.DrawText(rm, {self.game.size.x - 24 - size.x, 16}, text, e.DEFAULT_FONT, self.size, self.color)
	best := fmt.tprintf("Best %d", state.highScore)
	bestSize := e.MeasureText(rm, best, e.DEFAULT_FONT, self.size * 0.7)
	e.DrawText(rm, {self.game.size.x - 24 - bestSize.x, 16 + self.size * 1.25}, best, e.DEFAULT_FONT, self.size * 0.7, {150, 160, 185, 255})

	e.DrawText(rm, {24, self.game.size.y - self.size * 1.5}, "Arrows / WASD: move    Space: jump    J / X: attack    Esc: menu", e.DEFAULT_FONT, self.size * 0.7, {235, 240, 255, 200})
}
