package scripts

import "core:math"
import "core:math/rand"
import e "engine:."
import sdl "vendor:sdl3"

/*
Boss: Grimtusk, the great boar the blight turned, in the Lair's arena. An LDtk entity mapped to
components/boss.component.xml: the boar's animations three times the size, an aura (a Light2D
and a ParticleEmitter of miasma), a hurtbox. It sleeps until the arena's BossTrigger wakes it
(`Boss_Wake`), then fights in three phases, each faster and meaner:

1. **Charges** (above two thirds of its health): it paws the ground (a shiver and a snort: the
   tell), then charges across the arena. Into a wall it's **stunned**: dazed, and hits hurt it
   twice as much. That's the opening.
2. **Slams** (from two thirds): it also leaps at the hero and lands with a shockwave that runs
   along the floor both ways (jump it), and calls bees.
3. **Rage** (from a third): faster, redder, more bees, shockwaves after every charge too.

Each phase change is a roar (the camera shakes, the music's drums layer comes up). Its health
shows in the HUD's BossBar (a ProgressBar). Defeated, time slows, it fades, and the level's
director (`Level`) plays the ending.
*/
Boss :: struct {
	using script: e.Script,
	health: int `export:"default=36 min=1 max=200"`,
	// Walking and charging speeds, px/s
	walkSpeed: f32 `export:"default=50 min=0 max=400"`,
	chargeSpeed: f32 `export:"default=330 min=0 max=900"`,
	aura: ^e.Light2D `export:"default=Aura"`,
	miasma: ^e.ParticleEmitter `export:"default=Miasma"`,
	enemy: Enemy,
	mode: BossMode,
	// Seconds in the current mode, and how long it lasts
	time, length: f32,
	phase: int,
	heading: f32,
	// A leap: from where, to where
	leapFrom, leapTo: [2]f32,
	waves: [dynamic]Shockwave,
	bar: ^e.ProgressBar,
	barPanel: ^e.Control,
	defeated: bool,
	shiver: f32,
}

// What the boss is doing
BossMode :: enum {
	Asleep,
	Waking,
	Idle,
	Paw,
	Charge,
	Stunned,
	Leap,
	Roar,
	Dying,
}

// A slam's shockwave running along the floor
Shockwave :: struct {
	x, y, direction: f32,
	life, puff: f32,
}

// The boss of the scene (the Lair's), or nil
currentBoss: ^Boss

// Starts the fight (the arena's BossTrigger, after the cutscene)
Boss_Wake :: proc(boss: ^Boss) {
	if boss.mode != .Asleep do return
	boss.mode, boss.time, boss.length = .Waking, 0, 1.4
	if boss.barPanel != nil do boss.barPanel.visible = true
	Sfx(boss.game, SOUND_BOSS_ROAR)
	e.Camera2D_Shake(boss.scene.camera, 4, 1)
}

// Whether the fight is over
Boss_Defeated :: proc(boss: ^Boss) -> bool {
	return boss == nil || boss.defeated
}

@(private="file")
feet :: proc(boss: ^Boss) -> [2]f32 {
	return e.Node_GetWorldPosition(boss.node)
}

@(private="file")
enter :: proc(boss: ^Boss, mode: BossMode, length: f32) {
	boss.mode, boss.time, boss.length = mode, 0, length
}

@(private="file")
play :: proc(boss: ^Boss, animation: string) {
	if boss.enemy.sprite != nil do e.AnimationPlayer_Play(&boss.enemy.sprite.animation, animation)
}

// Its speed in this phase
@(private="file")
pace :: proc(boss: ^Boss) -> f32 {
	return boss.phase >= 3 ? 1.45 : boss.phase == 2 ? 1.2 : 1
}

// What comes after a pause: a charge, a leap, or calling bees
@(private="file")
decide :: proc(boss: ^Boss) {
	hero := currentHero
	if hero == nil do return
	boss.heading = Hero_Feet(hero).x >= feet(boss).x ? 1 : -1
	roll := rand.float32()
	if boss.phase >= 2 && roll < 0.25 && len(liveEnemies) < 4 {
		enter(boss, .Roar, 1)
		Sfx(boss.game, SOUND_BOSS_ROAR, 0.7, 1.2)
		for i in 0 ..< boss.phase - 1 {
			at := feet(boss) + {f32(i * 2 - 1) * 60, -120}
			e.Scene_AddComponent(boss.scene, COMPONENT_BEE, boss.node.parent, boss.node.position + (at - feet(boss)))
		}
		return
	}
	if boss.phase >= 2 && roll < 0.6 {
		enter(boss, .Leap, 0.9 / pace(boss))
		boss.leapFrom = boss.node.position
		boss.leapTo = {boss.node.position.x + (Hero_Feet(hero).x - feet(boss).x), boss.node.position.y}
		Sfx(boss.game, SOUND_BOSS_CHARGE, 0.8, 0.8)
		return
	}
	enter(boss, .Paw, 0.7 / pace(boss))
	Sfx(boss.game, SOUND_BOSS_CHARGE, 0.9)
}

// A slam's landing: shockwaves both ways, a big shake
@(private="file")
slam :: proc(boss: ^Boss) {
	at := feet(boss)
	Sfx(boss.game, SOUND_BOSS_SLAM)
	Effects_Hit(boss.scene, at, 0, .Huge)
	Effects_Dust(boss.scene, at, 24)
	for direction in ([2]f32{-1, 1}) do append(&boss.waves, Shockwave{x = at.x, y = at.y, direction = direction, life = 1.4})
}

@(private="file")
updateWaves :: proc(boss: ^Boss, dt: f32) {
	hero := currentHero
	for i := len(boss.waves) - 1; i >= 0; i -= 1 {
		w := &boss.waves[i]
		w.life -= dt
		w.x += w.direction * 260 * dt
		w.puff -= dt
		if w.puff <= 0 {
			w.puff = 0.05
			Effects_Dust(boss.scene, {w.x, w.y}, 4)
		}
		blocked := Level_Solid(boss.scene, {w.x + w.direction * 8, w.y - 8})
		if hero != nil && !hero.dead && Hero_Mover(hero).onFloor {
			f := Hero_Feet(hero)
			if abs(f.x - w.x) < 12 && abs(f.y - w.y) < 20 do Hero_Hurt(hero, w.x - w.direction * 10)
		}
		if w.life <= 0 || blocked do unordered_remove(&boss.waves, i)
	}
}

@(init)
register_Boss :: proc "contextless" () {
	e.Script_Register(Boss, {
		ready = proc(self: ^Boss) {
			currentBoss = self
			Enemy_Start(&self.enemy, self.node, self.health, 500, false, "hit", 2.4)
			self.enemy.stompable = false
			self.enemy.weight = 0.15
			self.phase = 1
			self.heading = -1
			self.waves = make([dynamic]Shockwave, e.Node_GetAllocator(self.node))
			if panel := e.Scene_FindNode(self.scene, "HUD/BossBar"); panel != nil && e.Node_IsControl(panel) {
				self.barPanel = cast(^e.Control)panel
				self.barPanel.visible = false
			}
			if bar := e.Scene_FindNode(self.scene, "HUD/BossBar/BossHealth"); bar != nil && e.Node_Is(bar, e.ProgressBar) do self.bar = cast(^e.ProgressBar)bar
			if self.enemy.sprite != nil do self.enemy.sprite.tint = {200, 150, 190, 255}
			play(self, "idle")
		},
		destroy = proc(self: ^Boss) {
			Enemy_Stop(&self.enemy)
			if currentBoss == self do currentBoss = nil
		},
		update = proc(self: ^Boss, _: []sdl.Event, deltaTime: f64) {
			dt := f32(deltaTime)
			self.time += dt
			updateWaves(self, dt)
			if self.bar != nil do e.ProgressBar_SetValue(self.bar, f32(max(self.enemy.health, 0)) / f32(self.enemy.maxHealth))
			// The aura breathes, brighter as it weakens
			if self.aura != nil do self.aura.settings.energy = (0.6 + 0.25 * f32(self.phase)) * (1 + 0.15 * math.sin(self.time * 5))

			if self.mode == .Asleep {
				play(self, "idle")
				return
			}
			if !Enemy_Alive(&self.enemy) {
				if self.mode != .Dying {
					enter(self, .Dying, 3)
					self.defeated = true
					clear(&self.waves)
					Sfx(self.game, SOUND_BOSS_DEFEAT)
					Effects_Hit(self.scene, Enemy_Center(&self.enemy), 0, .Huge)
					e.Game_SetTimeScale(self.game, 0.35)
					if self.miasma != nil do e.ParticleEmitter_Stop(self.miasma)
					if self.barPanel != nil do self.barPanel.visible = false
				}
				if self.time > 0.8 do e.Game_SetTimeScale(self.game, 1)
				Enemy_Update(&self.enemy, deltaTime)
				return
			}
			Enemy_Update(&self.enemy, deltaTime)

			// Phases by health: a roar between them
			fraction := f32(self.enemy.health) / f32(self.enemy.maxHealth)
			phase := fraction <= 0.34 ? 3 : fraction <= 0.67 ? 2 : 1
			if phase > self.phase {
				self.phase = phase
				enter(self, .Roar, 1.2)
				Sfx(self.game, SOUND_BOSS_ROAR)
				e.Camera2D_Shake(self.scene.camera, 5, 0.9)
				if self.enemy.sprite != nil do self.enemy.sprite.tint = phase == 3 ? {255, 110, 110, 255} : {230, 130, 160, 255}
				if self.miasma != nil do self.miasma.settings.amount = 40 * phase
			}

			sprite := self.enemy.sprite
			here := feet(self)
			if sprite != nil do sprite.position.x = 0
			switch self.mode {
			case .Asleep, .Dying:
			case .Waking, .Roar:
				play(self, "idle")
				if sprite != nil do sprite.position.x = math.sin(self.time * 70) * 1.5
				if self.time >= self.length do enter(self, .Idle, 0.8 / pace(self))
			case .Idle:
				play(self, "walk")
				hero := currentHero
				if hero != nil {
					self.heading = Hero_Feet(hero).x >= here.x ? 1 : -1
					if abs(Hero_Feet(hero).x - here.x) > 60 && Level_CanWalk(self.scene, here, self.heading, 50) {
						self.node.position.x += self.heading * self.walkSpeed * pace(self) * dt
					}
				}
				if self.time >= self.length do decide(self)
			case .Paw:
				play(self, "idle")
				if sprite != nil do sprite.position.x = math.sin(self.time * 90) * 2
				if self.time >= self.length do enter(self, .Charge, 4)
			case .Charge:
				play(self, "run")
				step := self.heading * self.chargeSpeed * pace(self) * dt
				if Level_Solid(self.scene, here + {self.heading * 70, -16}) {
					// Into the wall: stunned (and, raging, a shockwave)
					enter(self, .Stunned, 2.2 - 0.3 * f32(self.phase))
					Sfx(self.game, SOUND_BOSS_STUN)
					Effects_Hit(self.scene, here + {self.heading * 60, -30}, -self.heading, .Huge)
					if self.phase >= 3 do slam(self)
				} else {
					self.node.position.x += step
					if int(self.time * 10) % 2 == 0 do Effects_Dust(self.scene, here, 2)
				}
				if self.time >= self.length do enter(self, .Idle, 0.6)
			case .Stunned:
				play(self, "idle")
				if sprite != nil do sprite.position.x = math.sin(self.time * 8) * 3
				if self.time >= self.length do enter(self, .Idle, 0.5)
			case .Leap:
				t := clamp(self.time / self.length, 0, 1)
				play(self, "run")
				self.node.position.x = self.leapFrom.x + (self.leapTo.x - self.leapFrom.x) * t
				self.node.position.y = self.leapFrom.y - math.sin(t * math.PI) * 110
				// Never into a wall
				if Level_Solid(self.scene, feet(self) + {self.heading * 60, -20}) do self.leapTo.x = self.node.position.x
				if t >= 1 {
					self.node.position.y = self.leapFrom.y
					slam(self)
					enter(self, .Idle, 0.9 / pace(self))
				}
			}
			Sprite_FaceLeftSheet(sprite, self.heading)
			// Stunned: hits count double
			self.enemy.weight = self.mode == .Stunned ? 0.3 : 0.1
		},
	})
}

// Called by Enemy_Hurt's caller for the boss: stunned, hits count twice
Boss_Damage :: proc(boss: ^Boss, damage: int) -> int {
	return boss.mode == .Stunned ? damage * 2 : damage
}
