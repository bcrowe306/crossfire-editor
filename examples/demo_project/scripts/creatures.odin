package scripts

import "core:math"
import "core:math/linalg"
import e "engine:."
import sdl "vendor:sdl3"

/*
The forest's creatures, each an LDtk entity mapped to a component (an Area with an
AnimatedSprite playing an animation asset and a CollisionShape hurtbox) and running the script
named like it. Their LDtk fields set the script fields of the same names (`patrol` a Point,
`speed`, `health`, a bee's `chase`). Shared behavior is in enemy.odin.

- **Snail** (`animations/snail.anim.xml`, PNG sheets cut by size): crawls back and forth, turning
  at its patrol's end, a wall or a ledge. A hit sends it into its shell for a moment.
- **Boar** (`animations/boar.anim.xml`, one Aseprite file per animation): walks its patrol; when
  the hero is ahead on its level it snorts, then charges at three times its speed, never off a
  ledge.
- **Bee** (`animations/bee.anim.xml`): flies its path, bobbing, and dives at the hero. A bee with
  `chase` (the Hollow's caves) hunts her instead: its NavAgent finds a way around the rock through
  the scene's NavRegion (`e.NavAgent_SetTarget`), and it flies along the agent's velocity.
*/

Snail :: struct {
	using script: e.Script,
	// The far end of its walk, in the level (an LDtk Point: the middle of the chosen cell); unset: ledge to ledge
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
			Enemy_Start(&self.enemy, self.node, self.health, 10, false, ANIM_SNAIL_DEAD, 0.7)
			self.enemy.hurtSound, self.enemy.defeatSound = SOUND_SNAIL_HURT, SOUND_SNAIL_DEFEAT
			self.home = self.node.position
			self.heading = self.patrol != {} && self.patrol.x >= self.home.x ? 1 : -1
		},
		destroy = proc(self: ^Snail) {
			Enemy_Stop(&self.enemy)
		},
		update = proc(self: ^Snail, _: []sdl.Event, deltaTime: f64) {
			busy := Enemy_Update(&self.enemy, deltaTime)
			// Just hit and still alive: into the shell
			if self.enemy.flash > 0.8 && Enemy_Alive(&self.enemy) do self.hiding = 0.7
			sprite := self.enemy.sprite
			if self.hiding > 0 && Enemy_Alive(&self.enemy) {
				self.hiding -= f32(deltaTime)
				if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, ANIM_SNAIL_HIDE)
				return
			}
			if busy do return
			if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, ANIM_SNAIL_WALK)
			x := self.node.position.x
			turn := !Level_CanWalk(self.scene, e.Node_GetWorldPosition(self.node), self.heading, 12)
			if self.patrol != {} {
				left, right := min(self.home.x, self.patrol.x), max(self.home.x, self.patrol.x)
				turn ||= (self.heading > 0 && x >= right) || (self.heading < 0 && x <= left)
			}
			if turn do self.heading = -self.heading
			self.node.position.x += self.heading * self.speed * f32(deltaTime)
			Sprite_FaceLeftSheet(sprite, self.heading)
		},
	})
}

Boar :: struct {
	using script: e.Script,
	patrol: [2]f32 `export:""`,
	speed: f32 `export:"default=40 min=0 max=300"`,
	health: int `export:"default=3 min=1 max=20"`,
	// How far ahead (px) it notices the hero, and how much faster it charges
	sight: f32 `export:"default=170 min=0 max=600"`,
	charge: f32 `export:"default=3 min=1 max=8"`,
	enemy: Enemy,
	home: [2]f32,
	heading: f32,
	// Seconds it stands still (at the end of its walk, after a charge); of its snort before one
	resting, snorting: f32,
	charging: bool,
}

@(init)
register_Boar :: proc "contextless" () {
	e.Script_Register(Boar, {
		ready = proc(self: ^Boar) {
			Enemy_Start(&self.enemy, self.node, self.health, 30, false, ANIM_BOAR_HIT, 0.5)
			self.enemy.hurtSound, self.enemy.defeatSound = SOUND_BOAR_HURT, SOUND_BOAR_DEFEAT
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

			// The hero ahead, on about its level, in sight: a snort, then a charge
			sees := false
			if hero := currentHero; hero != nil && !hero.dead {
				to := Hero_Feet(hero) - feet
				if abs(to.x) < self.sight && abs(to.y) < 40 && math.sign(to.x) == self.heading do sees = true
				if abs(to.x) < self.sight * 0.5 && abs(to.y) < 40 {
					sees = true
					self.heading = math.sign(to.x)
				}
			}
			if sees && !self.charging && self.snorting <= 0 {
				self.snorting = 0.45
				Sfx(self.game, SOUND_BOSS_CHARGE, 0.45, 1.5)
			}
			if self.snorting > 0 {
				self.snorting -= dt
				if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, ANIM_BOAR_IDLE)
				Sprite_FaceLeftSheet(sprite, self.heading)
				// A shiver before it goes
				if sprite != nil do sprite.position.x = math.sin(self.snorting * 80) * 1
				if self.snorting <= 0 do self.charging = true
				return
			}
			if sprite != nil do sprite.position.x = 0
			if self.charging && !sees do self.charging = false
			if self.resting > 0 && !self.charging {
				self.resting -= dt
				if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, ANIM_BOAR_IDLE)
				return
			}

			speed := self.speed
			if self.charging {
				speed *= self.charge
			} else {
				// Patrol: turn at its ends (resting a moment)
				left, right := min(self.home.x, self.patrol.x), max(self.home.x, self.patrol.x)
				x := self.node.position.x
				if right - left > 1 && ((self.heading > 0 && x >= right) || (self.heading < 0 && x <= left)) {
					self.heading = -self.heading
					self.resting = 0.8
					return
				}
			}
			if !Level_CanWalk(self.scene, feet, self.heading, 16) {
				if !self.charging do self.heading = -self.heading
				self.charging = false
				self.resting = 0.6
				return
			}
			self.node.position.x += self.heading * speed * dt
			if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, self.charging ? ANIM_BOAR_RUN : ANIM_BOAR_WALK)
			Sprite_FaceLeftSheet(sprite, self.heading)
		},
	})
}

Bee :: struct {
	using script: e.Script,
	patrol: [2]f32 `export:""`,
	speed: f32 `export:"default=50 min=0 max=300"`,
	health: int `export:"default=1 min=1 max=20"`,
	// Hunts the hero through the level's NavRegion instead of flying a path
	chase: bool `export:""`,
	// How close (px) the hero must be for a dive, or to be hunted
	sight: f32 `export:"default=120 min=0 max=500"`,
	agent: ^e.NavAgent `export:"default=Agent"`,
	enemy: Enemy,
	home: [2]f32,
	// 0..1 along its path, and which way
	along, direction: f32,
	time: f32,
	// While diving: where to, for how much longer; then a pause before the next
	target: [2]f32,
	diving, cooldown: f32,
	// Seconds before the hunt's path is worked out again; no path was found the last time
	repath: f32,
	lost: bool,
	buzz: f32,
}

@(init)
register_Bee :: proc "contextless" () {
	e.Script_Register(Bee, {
		ready = proc(self: ^Bee) {
			Enemy_Start(&self.enemy, self.node, self.health, 20, true, ANIM_BEE_HIT, 0.6)
			self.enemy.hurtSound, self.enemy.defeatSound = SOUND_BEE_HURT, SOUND_BEE_DEFEAT
			self.enemy.stompable = true
			self.home = self.node.position
			if self.patrol == {} do self.patrol = self.home + {40, 0}
			self.direction = 1
			self.time = self.home.x * 0.1
			if self.agent != nil do self.agent.settings.speed = self.speed * 1.6
		},
		destroy = proc(self: ^Bee) {
			Enemy_Stop(&self.enemy)
		},
		update = proc(self: ^Bee, _: []sdl.Event, deltaTime: f64) {
			if Enemy_Update(&self.enemy, deltaTime) {
				if self.agent != nil do e.NavAgent_Stop(self.agent)
				return
			}
			dt := f32(deltaTime)
			self.time += dt
			self.cooldown = max(self.cooldown - dt, 0)
			sprite := self.enemy.sprite
			position := self.node.position
			hero := currentHero
			bob := [2]f32{0, math.sin(self.time * 3) * 5}

			// Lost: it tries again in a moment
			if self.lost {
				self.repath -= dt
				if self.repath <= 0 do self.lost = false
			}
			// Hunting through the caves: the NavAgent's path, its velocity
			if self.chase && self.agent != nil {
				here := e.Node_GetWorldPosition(self.node)
				if hero != nil && !hero.dead && Hero_Near(here, self.sight * 2) && !self.lost {
					self.repath -= dt
					if self.repath <= 0 {
						self.repath = 0.35
						// No way to her (or no NavRegion here): it flies its path and dives instead
						self.lost = !e.NavAgent_SetTarget(self.agent, Hero_Center(hero))
						if self.lost do self.repath = 1.5
					}
					self.buzz -= dt
					if self.buzz <= 0 {
						self.buzz = 1.6
						Sfx(self.game, SOUND_BEE_BUZZ, 0.35)
					}
					self.node.position += self.agent.velocity * dt + bob * dt
					Sprite_FaceLeftSheet(sprite, self.agent.velocity.x)
					if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, Hero_Near(here, 50) ? ANIM_BEE_ATTACK : ANIM_BEE_FLY)
					return
				}
				e.NavAgent_Stop(self.agent)
			}

			// Diving at where the hero was
			if self.diving > 0 {
				self.diving -= dt
				to := self.target - position
				if linalg.length(to) < 4 do self.diving = 0
				else do self.node.position += linalg.normalize(to) * min(self.speed * 2.6 * dt, linalg.length(to))
				Sprite_FaceLeftSheet(sprite, to.x)
				if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, ANIM_BEE_ATTACK)
				if self.diving <= 0 do self.cooldown = 1.6
				return
			}
			if hero != nil && !hero.dead && self.cooldown <= 0 {
				// The hero's middle, in the level (the bee's parent's space: the same as the hero's)
				heroAt := hero.node.position - {0, 18}
				if linalg.length(heroAt - position) < self.sight {
					self.target = heroAt
					self.diving = 1.1
					Sfx(self.game, SOUND_BEE_BUZZ, 0.5, 1.2)
					return
				}
			}

			// Back and forth along its path, bobbing; back to the path after a dive
			length := max(linalg.length(self.patrol - self.home), 1)
			self.along += self.direction * self.speed * dt / length
			if self.along >= 1 do self.direction = -1
			if self.along <= 0 do self.direction = 1
			self.along = clamp(self.along, 0, 1)
			goal := linalg.lerp(self.home, self.patrol, self.along) + bob
			to := goal - position
			step := min(self.speed * 1.5 * dt, linalg.length(to))
			if step > 0 do self.node.position += linalg.normalize(to) * step
			Sprite_FaceLeftSheet(sprite, abs(to.x) > 0.5 ? to.x : self.direction * (self.patrol.x - self.home.x))
			if sprite != nil do e.AnimationPlayer_Play(&sprite.animation, ANIM_BEE_FLY)
		},
	})
}
