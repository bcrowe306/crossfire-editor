package scripts

import "core:math"
import "core:math/rand"
import e "engine:."
import sdl "vendor:sdl3"

/*
Hero: Lyra, the player. Every level's LDtkLevel node maps the LDtk entity "Hero" to
components/hero.component.xml (a CharacterMover with her sprite, capsule, lantern and dust),
and this script is attached because it's named like the entity.

- **Movement** feels like a platformer's: she speeds up and slows down (`acceleration`,
  `friction`, less control in the air), falls faster than she rises, a released jump is cut
  short, and jumps forgive a late press and a step off a ledge (jump buffer, coyote time).
  Gravity is scripted on the mover's velocity, then `e.CharacterMover_Move` stops her on the
  level's IntGrid collision (planks are one-way: hold down and jump to drop through them).
- **Animation** isn't picked here: her StateMachine ("Brain") follows parameters set every frame
  (speed, onFloor, vy, and the attack / hurt triggers) and plays the states' animations, the
  tags of `assets/characters/hero.aseprite`.
- **Frame events** in the Aseprite file time the rest: "slash" on the attack's two swings hits
  what the sword reaches (`swing`), "step" plays a footstep and kicks up dust.
- **Hits** take a heart (GameState), knock her back, flash her through the sprite's shader
  (`builtin:hit_flash`, its `amount` parameter; a tint where shaders don't run) and leave her
  safe for a moment. Pits and water cost a heart too and put her back on the last firm ground.
  At none she falls, and the game over screen comes.
- **The camera** follows her by itself (the Camera node's target, look-ahead and limits are in
  the scene file; `ready` points it at her and sets the limits to the level's size).
- **Moving platforms** carry her (`Platform` moves her with it while she stands on it).
*/
Hero :: struct {
	using script: e.Script,
	// Top run speed, px/s (the LDtk entity's "speed" field sets it)
	speed: f32 `export:"default=175 min=40 max=400"`,
	// How fast she gets up to speed on the ground and in the air, px/s²
	acceleration: f32 `export:"default=1800 min=100 max=10000"`,
	airAcceleration: f32 `export:"default=1150 min=100 max=10000"`,
	// How fast she stops on the ground with no input, px/s²
	friction: f32 `export:"default=2400 min=100 max=10000"`,
	jumpSpeed: f32 `export:"default=430 min=100 max=900"`,
	// Gravity while rising, and while falling (or after letting go of jump)
	gravity: f32 `export:"default=1250 min=100 max=5000"`,
	fallGravity: f32 `export:"default=1800 min=100 max=5000"`,
	maxFall: f32 `export:"default=540 min=100 max=1500"`,
	// What's left of the rise when jump is let go early
	jumpCut: f32 `export:"default=0.45 min=0 max=1"`,
	coyoteTime: f32 `export:"default=0.1 min=0 max=0.5"`,
	jumpBuffer: f32 `export:"default=0.12 min=0 max=0.5"`,
	// The sword: how far it reaches in front, and its damage per slash
	reach: f32 `export:"default=44 min=8 max=120"`,
	damage: int `export:"default=1 min=1 max=10"`,
	sprite: ^e.AnimatedSprite `export:"default=Sprite"`,
	brain: ^e.StateMachine `export:"default=Brain"`,
	lantern: ^e.Light2D `export:"default=Lantern"`,

	// Which way she faces (1 right, -1 left)
	facing: f32,
	// Seconds left to still jump after leaving the floor, and of a jump pressed early
	coyote, buffered: f32,
	// Seconds left of being pushed by a hit, and which way
	knockback, knockDirection: f32,
	// Seconds before another attack; a press during one plays the next
	attackCooldown, attackQueued: f32,
	// The hit flash (1 to 0)
	flash: f32,
	// Down: seconds before the game over screen
	dying: f32,
	dead: bool,
	// Where a pit puts her back: the last firm ground she stood on
	safe: [2]f32,
	levelSize: [2]f32,
	// Last frame's floor, for landings, and the speed she fell at
	wasOnFloor: bool,
	fallSpeed: f32,
	// What each slash already hit (an enemy is hit once per slash)
	struck: [dynamic]rawptr,
	// Seconds left of dropping through a plank
	dropping: f32,
	// The flash's fallback when shaders don't run
	shaders: bool,
	// Seconds since she appeared (the lantern's flicker)
	time: f32,
}

// The hero of the scene that's playing (enemies and pickups look for her), or nil
currentHero: ^Hero

// Whether she's down
Hero_Dead :: proc(hero: ^Hero) -> bool {
	return hero == nil || hero.dead
}

// Whether the player can move her: not during a dialogue, a cutscene, or once she's down
Hero_HasControl :: proc(hero: ^Hero) -> bool {
	state := State()
	return !hero.dead && (state == nil || state.cutscene == 0)
}

// The hero's mover
Hero_Mover :: proc(hero: ^Hero) -> ^e.CharacterMover {
	return cast(^e.CharacterMover)hero.node
}

// Her feet in the world
Hero_Feet :: proc(hero: ^Hero) -> [2]f32 {
	return e.Node_GetWorldPosition(hero.node)
}

// Her middle in the world (what enemies aim at)
Hero_Center :: proc(hero: ^Hero) -> [2]f32 {
	return Hero_Feet(hero) - {0, 18}
}

// A bounce off a stomped enemy
Hero_Bounce :: proc(hero: ^Hero) {
	mover := Hero_Mover(hero)
	mover.velocity.y = e.Input_IsActionPressed(ACTION_JUMP) ? -hero.jumpSpeed * 0.95 : -hero.jumpSpeed * 0.6
	hero.coyote = 0
}

/*
Hurts the hero, hit by something at `fromX` (world): a heart, knocked back up and away, blood, a
hitstop, a bigger shake, a flash. Nothing while she's safe after the last hit.

Returns:
- Whether it hurt her
*/
Hero_Hurt :: proc(hero: ^Hero, fromX: f32, amount := 1) -> bool {
	state := State()
	if state == nil || hero.dead || state.invulnerable > 0 do return false
	mover := Hero_Mover(hero)
	at := Hero_Feet(hero)
	hero.knockDirection = at.x < fromX ? -1 : 1
	hero.knockback = 0.22
	mover.velocity = {hero.knockDirection * 190, -230}
	hero.flash = 1
	Sfx(hero.game, SOUND_HERO_HURT)
	Effects_Hit(hero.scene, at - {0, 20}, hero.knockDirection, .Hurt)
	if GameState_Damage(state, amount) {
		heroDown(hero)
	} else if hero.brain != nil {
		e.StateMachine_SetTrigger(hero.brain, PARAM_HERO_BRAIN_HURT)
	}
	return true
}

// A pit or water: a heart, and back on firm ground
Hero_Fell :: proc(hero: ^Hero) {
	state := State()
	if state == nil || hero.dead do return
	mover := Hero_Mover(hero)
	state.invulnerable = 0
	Sfx(hero.game, SOUND_HERO_HURT)
	if GameState_Damage(state, 1) {
		heroDown(hero)
		return
	}
	mover.position = hero.safe
	mover.velocity = {}
	hero.flash = 1
	if camera := hero.scene.camera; camera != nil do e.Camera2D_SnapTo(camera, Hero_Feet(hero))
	Effects_Dust(hero.scene, Hero_Feet(hero), 12)
}

@(private="file")
heroDown :: proc(hero: ^Hero) {
	hero.dead = true
	hero.dying = 2
	if hero.brain != nil do e.StateMachine_SetBool(hero.brain, PARAM_HERO_BRAIN_DEAD, true)
	Sfx(hero.game, SOUND_HERO_DEATH)
	e.Game_SetTimeScale(hero.game, 0.5)
}

// The sword's reach in the world: in front of her, from her knees to above her head
@(private="file")
swordBox :: proc(hero: ^Hero) -> sdl.FRect {
	feet := Hero_Feet(hero)
	x := hero.facing > 0 ? feet.x - 6 : feet.x + 6 - hero.reach
	return {x, feet.y - 46, hero.reach, 46}
}

Rect_Overlaps :: proc(a, b: sdl.FRect) -> bool {
	return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// One slash (the animation's "slash" event): hits what the sword reaches, each thing once
@(private="file")
swing :: proc(hero: ^Hero) {
	clear(&hero.struck)
	Sfx(hero.game, SOUND_SWING, 0.8, rand.float32_range(0.92, 1.08))
	box := swordBox(hero)
	feet := Hero_Feet(hero)
	// Hurting can remove enemies from the list: look at a copy
	enemies := make([]^Enemy, len(liveEnemies), context.temp_allocator)
	copy(enemies, liveEnemies[:])
	for enemy in enemies {
		if !Enemy_Alive(enemy) || !Rect_Overlaps(box, Enemy_Box(enemy)) do continue
		damage := hero.damage
		if boss := currentBoss; boss != nil && enemy == &boss.enemy do damage = Boss_Damage(boss, damage)
		Enemy_Hurt(enemy, damage, feet.x)
	}
	breakables := make([]^Pot, len(livePots), context.temp_allocator)
	copy(breakables, livePots[:])
	for pot in breakables do if Rect_Overlaps(box, Pot_Box(pot)) do Pot_Break(pot)
}

// The sprite's frame events (Aseprite cels' user data in hero.aseprite)
@(private="file")
onFrameEvent :: proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, user: rawptr) {
	hero := cast(^Hero)user
	name, _ := data.(string)
	switch name {
	case "slash":
		swing(hero)
	case "step":
		if Hero_Mover(hero).onFloor {
			Sfx(hero.game, SOUND_STEP, 0.45, rand.float32_range(0.9, 1.1))
			Effects_Dust(hero.scene, Hero_Feet(hero) - {hero.facing * 4, 0}, 3)
		}
	}
}

@(private="file")
approach :: proc(value, target, step: f32) -> f32 {
	return value < target ? min(value + step, target) : max(value - step, target)
}

@(init)
register_Hero :: proc "contextless" () {
	e.Script_Register(Hero, {
		ready = proc(self: ^Hero) {
			currentHero = self
			self.facing = 1
			self.struck = make([dynamic]rawptr, e.Node_GetAllocator(self.node))
			self.shaders = e.Renderer_SupportsShaders(self.game.renderer)
			if self.sprite != nil do e.Event_Subscribe(&self.sprite.animation.onFrameEvent, onFrameEvent, self)
			self.levelSize = LevelSize(self.scene)

			// Continuing or retrying: she starts at the save's rune stone
			if state := State(); state != nil && state.run.level == self.scene.name && state.run.checkpoint != "" {
				if level := LevelNode(self.scene); level != nil {
					if stone := e.LDtk_FindEntityByIid(level, state.run.checkpoint); stone != nil {
						self.node.position = stone.position + {20, 0}
					}
				}
			}
			self.safe = self.node.position
			self.wasOnFloor = true
			if camera := self.scene.camera; camera != nil {
				e.Camera2D_SetFollowTarget(camera, self.node)
				if self.levelSize != {} {
					e.Camera2D_SetLimit(camera, .Left, 0)
					e.Camera2D_SetLimit(camera, .Top, 0)
					e.Camera2D_SetLimit(camera, .Right, self.levelSize.x)
					e.Camera2D_SetLimit(camera, .Bottom, self.levelSize.y)
				}
			}
			// The lantern only matters where it's dark
			if self.lantern != nil do self.lantern.visible = self.scene.lighting.enabled
		},
		destroy = proc(self: ^Hero) {
			if currentHero == self do currentHero = nil
			if self.game != nil do e.Game_SetTimeScale(self.game, 1)
		},
		update = proc(self: ^Hero, _: []sdl.Event, deltaTime: f64) {
			mover := Hero_Mover(self)
			dt := f32(deltaTime)
			state := State()
			control := Hero_HasControl(self)

			// Down: she falls where she is, then the game over screen
			if self.dead {
				self.dying -= f32(deltaTime) / max(self.game.timeScale, 0.01)
				mover.velocity.x = approach(mover.velocity.x, 0, self.friction * dt)
				mover.velocity.y = min(mover.velocity.y + self.fallGravity * dt, self.maxFall)
				e.CharacterMover_Move(mover, deltaTime)
				if self.dying <= 0 {
					self.dying = 1000
					e.Game_SetTimeScale(self.game, 1)
					if state != nil do GameState_Defeated(state)
				}
				return
			}

			direction := control ? e.Input_GetAxis(ACTION_LEFT, ACTION_RIGHT) : 0
			attacking := self.brain != nil && e.StateMachine_Is(self.brain, "attack")
			hurt := self.brain != nil && e.StateMachine_Is(self.brain, "hurt")
			if !attacking && direction != 0 do self.facing = direction < 0 ? -1 : 1

			// The attack: pressed (or queued during the last one), when the cooldown allows
			self.attackCooldown = max(self.attackCooldown - dt, 0)
			self.attackQueued = max(self.attackQueued - dt, 0)
			if control && e.Input_IsActionJustPressed(ACTION_ATTACK) do self.attackQueued = 0.25
			if self.attackQueued > 0 && !attacking && !hurt && self.attackCooldown <= 0 && self.brain != nil {
				e.StateMachine_SetTrigger(self.brain, PARAM_HERO_BRAIN_ATTACK)
				self.attackQueued = 0
				self.attackCooldown = 0.12
			}

			// Running: toward the input's speed, slower in the air; barely moving while swinging on the ground
			target := direction * self.speed
			if attacking && mover.onFloor do target *= 0.15
			rate := mover.onFloor ? (direction != 0 ? self.acceleration : self.friction) : self.airAcceleration
			mover.velocity.x = approach(mover.velocity.x, target, rate * dt)
			if self.knockback > 0 {
				self.knockback -= dt
				mover.velocity.x = self.knockDirection * 190
			}

			// Jumping: buffered presses, coyote time, a cut when let go, dropping through planks
			self.coyote = mover.onFloor ? self.coyoteTime : max(self.coyote - dt, 0)
			jumpPressed := control && e.Input_IsActionJustPressed(ACTION_JUMP)
			self.buffered = jumpPressed ? self.jumpBuffer : max(self.buffered - dt, 0)
			self.dropping = max(self.dropping - dt, 0)
			if self.buffered > 0 && self.coyote > 0 {
				if control && e.Input_IsActionPressed(ACTION_DOWN) && mover.onFloor && Level_PlankUnder(self) {
					self.dropping = 0.25
				} else {
					mover.velocity.y = -self.jumpSpeed
					Sfx(self.game, SOUND_JUMP, 0.7, rand.float32_range(0.95, 1.05))
					Effects_Dust(self.scene, Hero_Feet(self), 5)
				}
				self.buffered, self.coyote = 0, 0
			}
			mover.dropThrough = self.dropping > 0
			rising := mover.velocity.y < 0
			if rising && control && e.Input_IsActionJustReleased(ACTION_JUMP) do mover.velocity.y *= self.jumpCut
			holding := control && e.Input_IsActionPressed(ACTION_JUMP)
			g := rising && holding ? self.gravity : self.fallGravity
			// A little hang at the top of a held jump
			if holding && abs(mover.velocity.y) < 40 do g *= 0.6
			mover.velocity.y = min(mover.velocity.y + g * dt, self.maxFall)
			if !mover.onFloor do self.fallSpeed = max(self.fallSpeed, mover.velocity.y)
			e.CharacterMover_Move(mover, deltaTime)

			// Landing: dust and a thump, harder from higher
			if mover.onFloor && !self.wasOnFloor {
				if self.fallSpeed > 260 {
					Sfx(self.game, SOUND_LAND, clamp(self.fallSpeed / 600, 0.3, 0.9))
					Effects_Dust(self.scene, Hero_Feet(self), int(clamp(self.fallSpeed / 50, 4, 12)))
				}
				self.fallSpeed = 0
			}
			self.wasOnFloor = mover.onFloor

			// Firm ground under both edges of her feet: where a pit puts her back
			feet := Hero_Feet(self)
			if mover.onFloor && Level_Solid(self.scene, feet + {-7, 4}) && Level_Solid(self.scene, feet + {7, 4}) {
				self.safe = mover.position
			}
			if self.levelSize != {} && feet.y > self.levelSize.y + 40 do Hero_Fell(self)

			// The state machine's parameters: it picks the animation
			if self.brain != nil {
				e.StateMachine_SetFloat(self.brain, PARAM_HERO_BRAIN_SPEED, abs(mover.velocity.x))
				e.StateMachine_SetFloat(self.brain, PARAM_HERO_BRAIN_VY, mover.velocity.y)
				e.StateMachine_SetBool(self.brain, PARAM_HERO_BRAIN_ON_FLOOR, mover.onFloor)
			}
			if self.sprite != nil {
				// The sheet faces right; a negative scale mirrors it
				self.sprite.scale.x = self.facing
				// The hit flash, then a blink while she's safe
				self.flash = max(self.flash - dt * 4, 0)
				if self.shaders {
					e.Node_SetShaderParam(self.sprite, "amount", self.flash)
				} else {
					v := u8(255 - 120 * self.flash)
					self.sprite.tint = {255, v, v, 255}
				}
				self.sprite.visible = state == nil || state.invulnerable <= 0.05 || int(state.invulnerable * 12) % 2 == 0
			}
			if self.lantern != nil {
				// A lantern's flame: it breathes
				self.time += dt
				self.lantern.settings.energy = 1.1 + 0.06 * math.sin(self.time * 7) + 0.04 * math.sin(self.time * 13)
			}
		},
		// Water (the Ground layer's Water value becomes an Area named after it)
		areaEnter = proc(self: ^Hero, collision: ^e.Collision) {
			if collision.other != nil && collision.other.name == "Water" {
				Sfx(self.game, SOUND_SPLASH, 0.8)
				Effects_Dust(self.scene, Hero_Feet(self), 10)
				Hero_Fell(self)
			}
		},
	})
}

// Whether she stands on a plank (one-way: she can drop through)
Level_PlankUnder :: proc(hero: ^Hero) -> bool {
	return e.LDtk_IntGridAtPosition(LevelNode(hero.scene), "Ground", Hero_Feet(hero) + {0, 4}) == GROUND_PLANK
}
