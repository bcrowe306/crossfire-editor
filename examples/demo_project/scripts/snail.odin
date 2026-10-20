package scripts

import e "engine:."
import sdl "vendor:sdl3"

/*
Snail: a slow enemy, an LDtk entity mapped to components/snail.component.xml (an Area with a
walking sprite). Its LDtk fields set `patrol` (a Point, drawn as a path in LDtk: the far end of
its walk), `speed` and `health`. It crawls between where it was placed and there, turning at
walls and ledges. A hit sends it into its shell for a moment (the "hide" animation); defeated,
it plays "dead". Shared enemy behavior: enemy.odin.
*/
Snail :: struct {
	using script: e.Script,
	// The far end of its walk, in the level (an LDtk Point: the middle of the chosen cell)
	patrol: [2]f32 `export:""`,
	speed: f32 `export:"default=24 min=0 max=200"`,
	health: int `export:"default=2 min=1 max=20"`,
	enemy: Enemy,
	home: [2]f32,
	heading: f32,
	// Seconds left in its shell after a hit
	hiding: f32,
}

@(init)
register_Snail :: proc "contextless" () {
	e.Script_Register(Snail, {
		ready = proc(self: ^Snail) {
			Enemy_Start(&self.enemy, self.node, self.health, 10, false, "dead", 0.7)
			self.home = self.node.position
			if self.patrol == {} do self.patrol = self.home
			self.heading = self.patrol.x >= self.home.x ? 1 : -1
		},
		destroy = proc(self: ^Snail) {
			Enemy_Stop(&self.enemy)
		},
		update = proc(self: ^Snail, _: []sdl.Event, deltaTime: f64) {
			busy := Enemy_Update(&self.enemy, deltaTime)
			// Just hit (it's flashing) and still alive: into the shell
			if self.enemy.flash > 0 && Enemy_Alive(&self.enemy) do self.hiding = 0.6
			sprite := self.enemy.sprite
			if self.hiding > 0 && Enemy_Alive(&self.enemy) {
				self.hiding -= f32(deltaTime)
				if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, "hide")
				return
			}
			if busy do return
			if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, "walk")
			left, right := min(self.home.x, self.patrol.x), max(self.home.x, self.patrol.x)
			x := self.node.position.x
			if (self.heading > 0 && x >= right) || (self.heading < 0 && x <= left) || !Level_CanWalk(self.scene, e.Node_GetWorldPosition(self.node), self.heading, 12) {
				self.heading = -self.heading
			}
			self.node.position.x += self.heading * self.speed * f32(deltaTime)
			Sprite_FaceLeftSheet(sprite, self.heading)
		},
	})
}
