package scripts

import "core:math"
import e "engine:."
import sdl "vendor:sdl3"

/*
Boar: a ground enemy, an LDtk entity mapped to components/boar.component.xml. It walks its
patrol (the LDtk "patrol" Point and "speed" fields) and, when the hero comes near on its level,
charges at three times its speed: running, never off a ledge or into a wall (the level's
Collisions layer). It takes three hits (the "health" field); defeated, it flashes white and
vanishes. Shared enemy behavior: enemy.odin.
*/
Boar :: struct {
	using script: e.Script,
	patrol: [2]f32 `export:""`,
	speed: f32 `export:"default=40 min=0 max=300"`,
	health: int `export:"default=3 min=1 max=20"`,
	// How far ahead (px) it notices the hero, and how much faster it charges
	sight: f32 `export:"default=150 min=0 max=600"`,
	charge: f32 `export:"default=3 min=1 max=8"`,
	enemy: Enemy,
	home: [2]f32,
	heading: f32,
	// Seconds it stands still (at the end of its walk, after a charge)
	resting: f32,
	charging: bool,
}

@(init)
register_Boar :: proc "contextless" () {
	e.Script_Register(Boar, {
		ready = proc(self: ^Boar) {
			Enemy_Start(&self.enemy, self.node, self.health, 30, false, "vanish", 0.5)
			self.home = self.node.position
			if self.patrol == {} do self.patrol = self.home
			self.heading = self.patrol.x >= self.home.x ? 1 : -1
		},
		destroy = proc(self: ^Boar) {
			Enemy_Stop(&self.enemy)
		},
		update = proc(self: ^Boar, _: []sdl.Event, deltaTime: f64) {
			if Enemy_Update(&self.enemy, deltaTime) do return
			dt := f32(deltaTime)
			sprite := self.enemy.sprite
			feet := e.Node_GetWorldPosition(self.node)

			// The hero ahead, on about its level, in sight: charge
			self.charging = false
			if hero := currentHero; hero != nil && !Hero_Dead(hero) {
				to := e.Node_GetWorldPosition(hero.node) - feet
				if abs(to.x) < self.sight && abs(to.y) < 40 {
					self.charging = true
					self.heading = math.sign(to.x)
				}
			}
			if self.resting > 0 && !self.charging {
				self.resting -= dt
				if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, "idle")
				return
			}

			speed := self.speed
			if self.charging {
				speed *= self.charge
			} else {
				// Patrol: turn at its ends (resting a moment)
				left, right := min(self.home.x, self.patrol.x), max(self.home.x, self.patrol.x)
				x := self.node.position.x
				if (self.heading > 0 && x >= right) || (self.heading < 0 && x <= left) {
					self.heading = -self.heading
					self.resting = 0.8
					return
				}
			}
			if !Level_CanWalk(self.scene, feet, self.heading, 16) {
				if !self.charging do self.heading = -self.heading
				self.resting = 0.5
				return
			}
			self.node.position.x += self.heading * speed * dt
			if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, self.charging ? "run" : "walk")
			Sprite_FaceLeftSheet(sprite, self.heading)
		},
	})
}
