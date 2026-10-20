package scripts

import "core:math"
import "core:math/linalg"
import e "engine:."
import sdl "vendor:sdl3"

/*
Bee: a flying enemy, an LDtk entity mapped to components/bee.component.xml. It flies back and
forth between where it was placed and its "patrol" Point (any direction: it ignores the ground),
bobbing; when the hero comes close it dives at where the hero was, then flies back to its path.
One hit (the "health" field) and it tumbles down and fades. Shared enemy behavior: enemy.odin.
*/
Bee :: struct {
	using script: e.Script,
	patrol: [2]f32 `export:""`,
	speed: f32 `export:"default=50 min=0 max=300"`,
	health: int `export:"default=1 min=1 max=20"`,
	// How close (px) the hero must be for a dive
	sight: f32 `export:"default=110 min=0 max=400"`,
	enemy: Enemy,
	home: [2]f32,
	// 0..1 along its path, and which way
	along, direction: f32,
	time: f32,
	// While diving: where to, for how much longer; then a pause before the next
	target: [2]f32,
	diving, cooldown: f32,
}

@(init)
register_Bee :: proc "contextless" () {
	e.Script_Register(Bee, {
		ready = proc(self: ^Bee) {
			Enemy_Start(&self.enemy, self.node, self.health, 20, true, "hit", 0.6)
			self.home = self.node.position
			if self.patrol == {} do self.patrol = self.home + {32, 0}
			self.direction = 1
			self.time = self.home.x * 0.1
		},
		destroy = proc(self: ^Bee) {
			Enemy_Stop(&self.enemy)
		},
		update = proc(self: ^Bee, _: []sdl.Event, deltaTime: f64) {
			if Enemy_Update(&self.enemy, deltaTime) do return
			dt := f32(deltaTime)
			self.time += dt
			self.cooldown = max(self.cooldown - dt, 0)
			sprite := self.enemy.sprite
			position := self.node.position
			hero := currentHero

			// Diving at where the hero was
			if self.diving > 0 {
				self.diving -= dt
				to := self.target - position
				if linalg.length(to) < 4 do self.diving = 0
				else do self.node.position += linalg.normalize(to) * min(self.speed * 2.4 * dt, linalg.length(to))
				Sprite_FaceLeftSheet(sprite, to.x)
				if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, "attack")
				if self.diving <= 0 do self.cooldown = 1.5
				return
			}
			if hero != nil && !Hero_Dead(hero) && self.cooldown <= 0 {
				// The hero's middle, in the level (the bee's parent's space: the same as the hero's)
				heroAt := hero.node.position - {0, 20}
				if linalg.length(heroAt - position) < self.sight {
					self.target = heroAt
					self.diving = 1.2
					return
				}
			}

			// Back and forth along its path, bobbing; back to the path after a dive
			length := max(linalg.length(self.patrol - self.home), 1)
			self.along += self.direction * self.speed * dt / length
			if self.along >= 1 do self.direction = -1
			if self.along <= 0 do self.direction = 1
			self.along = clamp(self.along, 0, 1)
			goal := linalg.lerp(self.home, self.patrol, self.along) + {0, math.sin(self.time * 3) * 6}
			to := goal - position
			step := min(self.speed * 1.5 * dt, linalg.length(to))
			if step > 0 do self.node.position += linalg.normalize(to) * step
			Sprite_FaceLeftSheet(sprite, abs(to.x) > 0.5 ? to.x : self.direction * (self.patrol.x - self.home.x))
			if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, "fly")
		},
	})
}
