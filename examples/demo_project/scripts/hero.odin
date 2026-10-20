package scripts

import e "engine:."
import sdl "vendor:sdl3"

/*
Hero: the forest level's player, an LDtk entity. ForestScene's LDtkLevel node maps the LDtk
entity "Hero" to components/hero.component.xml (a CharacterMover with its sprite and capsule),
and this script is attached because it's named like the entity. The entity's "speed" field in
LDtk sets `speed` (LDtk fields set the exported fields with the same name).

The project has no gravity (it's a space game), so the hero falls by itself: scripted gravity
on the mover's velocity, then e.CharacterMover_Move, which stops it on the level's IntGrid
collision. Jumps forgive a late press and a step off a ledge (jump buffer, coyote time), and
letting go early makes a short hop. The camera follows inside the level's bounds.

Attacking (the "attack" action) plays the two-slash animation; each slash (frames 1-2 and 5-6)
hits every enemy whose hurtbox meets the sword's reach in front of her, once per slash
(Enemy_Hurt: knockback, blood, a hitstop and a camera shake). On the ground she nearly stops
while swinging.

Health is the game state's (GameState_Damage): touching an enemy hurts (Hero_Hurt: knocked back,
a moment of safety); a pit costs health too and puts her back on the last firm ground she stood
on. At no health she falls, and the run ends. Escape goes back to the menu.
*/
Hero :: struct {
	using script: e.Script,
	// Run speed in pixels per second (the LDtk entity's "speed" field sets it)
	speed: f32 `export:"default=160 min=20 max=400"`,
	jumpSpeed: f32 `export:"default=400 min=50 max=800"`,
	gravity: f32 `export:"default=900 min=0 max=3000"`,
	// The sword: how far it reaches in front, and its damage
	reach: f32 `export:"default=40 min=8 max=120"`,
	damage: int `export:"default=1 min=1 max=10"`,

	sprite: ^e.AnimatedSprite,
	// Where she respawns after a pit: the last firm ground she stood on
	safe: [2]f32,
	// The level's size, for the camera and pits
	levelSize: [2]f32,
	// Which way she faces (1 right, -1 left)
	facing: f32,
	// Seconds left to still jump after leaving the floor, and of a jump pressed early
	coyote, jumpBuffer: f32,
	// Seconds left of being pushed back by a hit, and which way
	knockback, knockDirection: f32,
	// Seconds into the attack (< 0: not attacking), and the enemies each slash already hit
	attackTime: f32,
	struck: [2][dynamic]^Enemy,
	// Seconds left before the run ends (she's down)
	dying: f32,
}

// The hero of the scene that's playing (enemies look for her), or nil
currentHero: ^Hero

// The sword's two slashes, in seconds into the attack (the animation's frames 1-2 and 5-6 at 16 fps)
@(private="file")
SLASHES :: [2][2]f32{{1.0 / 16, 3.0 / 16}, {5.0 / 16, 7.0 / 16}}
@(private="file")
ATTACK_TIME :: f32(8.0 / 16)

// Whether she's down (the run is ending)
Hero_Dead :: proc(hero: ^Hero) -> bool {
	return hero.dying > 0
}

// A bounce off a stomped enemy
Hero_Bounce :: proc(hero: ^Hero) {
	(cast(^e.CharacterMover)hero.node).velocity.y = -260
}

/*
Hurts the hero, hit by something at `fromX` (world): health (GameState_Damage), knocked back up
and away, blood, a hitstop and a bigger shake. Nothing while she's safe after the last hit.
*/
Hero_Hurt :: proc(hero: ^Hero, fromX: f32) {
	state := e.Global(GameState)
	if state == nil || Hero_Dead(hero) || state.invulnerable > 0 do return
	mover := cast(^e.CharacterMover)hero.node
	at := e.Node_GetWorldPosition(mover)
	hero.knockDirection = at.x < fromX ? -1 : 1
	hero.knockback = 0.25
	mover.velocity.y = -220
	hero.attackTime = -1
	e.Game_PlaySound(hero.game, SOUND_HURT)
	Effects_Hit(hero.scene, at - {0, 20}, hero.knockDirection, .Hurt)
	if GameState_Damage(state, 1) do heroDown(hero)
}

@(private="file")
heroDown :: proc(hero: ^Hero) {
	hero.dying = 1.2
	if hero.sprite != nil do e.AnimationPlayer_Play(&hero.sprite.animation, "fall")
}

// The sword's reach in the world: in front of her, from her knees to above her head
@(private="file")
swordBox :: proc(hero: ^Hero) -> sdl.FRect {
	feet := e.Node_GetWorldPosition(hero.node)
	x := hero.facing > 0 ? feet.x - 4 : feet.x + 4 - hero.reach
	return {x, feet.y - 54, hero.reach, 50}
}

@(private="file")
overlaps :: proc(a, b: sdl.FRect) -> bool {
	return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// Hits what the sword reaches during a slash (each enemy once per slash)
@(private="file")
swing :: proc(hero: ^Hero) {
	for window, i in SLASHES {
		if hero.attackTime < window[0] || hero.attackTime >= window[1] do continue
		box := swordBox(hero)
		// Hurting can remove enemies from the list: look at a copy
		enemies := make([]^Enemy, len(liveEnemies), context.temp_allocator)
		copy(enemies, liveEnemies[:])
		for enemy in enemies {
			if !Enemy_Alive(enemy) || !overlaps(box, Enemy_Box(enemy)) do continue
			already := false
			for other in hero.struck[i] do if other == enemy do already = true
			if already do continue
			append(&hero.struck[i], enemy)
			Enemy_Hurt(enemy, hero.damage, e.Node_GetWorldPosition(hero.node).x)
		}
	}
}

@(init)
register_Hero :: proc "contextless" () {
	e.Script_Register(Hero, {
		ready = proc(self: ^Hero) {
			currentHero = self
			self.safe = self.node.position
			self.facing = 1
			self.attackTime = -1
			for &list in self.struck do list = make([dynamic]^Enemy, e.Node_GetAllocator(self.node))
			if sprite := e.Node_FindChild(self.node, "Sprite"); e.Node_Is(sprite, e.AnimatedSprite) {
				self.sprite = cast(^e.AnimatedSprite)sprite
			}
			if level := ForestLevel(self.scene); level != nil && len(level.views) > 0 {
				self.levelSize = level.views[0].level.size
			}
			if camera := self.scene.camera; camera != nil {
				if self.levelSize != {} do e.Camera2D_SetBounds(camera, {0, 0}, self.levelSize)
				e.Camera2D_SnapTo(camera, e.Node_GetWorldPosition(self.node))
			}
		},
		destroy = proc(self: ^Hero) {
			if currentHero == self do currentHero = nil
		},
		update = proc(self: ^Hero, _: []sdl.Event, deltaTime: f64) {
			if e.Input_IsActionJustPressed(ACTION_UI_CANCEL) {
				self.game->switchScene("MenuScene")
				return
			}
			mover := cast(^e.CharacterMover)self.node
			dt := f32(deltaTime)

			// Down: she falls where she is, then the run ends
			if self.dying > 0 {
				self.dying -= dt
				mover.velocity.x = 0
				mover.velocity.y = min(mover.velocity.y + self.gravity * dt, 600)
				e.CharacterMover_Move(mover, deltaTime)
				if self.sprite != nil do self.sprite.tint.a = u8(255 * clamp(self.dying, 0, 1))
				if self.dying <= 0 {
					if state := e.Global(GameState); state != nil do GameState_EndRun(state)
					self.game->switchScene("MenuScene")
				}
				return
			}

			direction := e.Input_GetAxis(ACTION_UI_LEFT, ACTION_UI_RIGHT)
			attacking := self.attackTime >= 0
			if !attacking && direction != 0 do self.facing = direction < 0 ? -1 : 1

			// The attack: two slashes, then she's free again
			if !attacking && e.Input_IsActionJustPressed(ACTION_ATTACK) {
				self.attackTime = 0
				attacking = true
				for &list in self.struck do clear(&list)
				e.Game_PlaySound(self.game, SOUND_SWING)
				if self.sprite != nil do e.AnimationPlayer_Play(&self.sprite.animation, "attack", true)
			}
			if attacking {
				self.attackTime += dt
				swing(self)
				if self.attackTime >= ATTACK_TIME do self.attackTime = -1
			}

			mover.velocity.x = direction * self.speed
			if attacking && mover.onFloor do mover.velocity.x *= 0.2
			if self.knockback > 0 {
				self.knockback -= dt
				mover.velocity.x = self.knockDirection * 150
			}
			self.coyote = mover.onFloor ? 0.1 : max(self.coyote - dt, 0)
			self.jumpBuffer = e.Input_IsActionJustPressed(ACTION_JUMP) ? 0.12 : max(self.jumpBuffer - dt, 0)
			if self.jumpBuffer > 0 && self.coyote > 0 {
				mover.velocity.y = -self.jumpSpeed
				self.jumpBuffer, self.coyote = 0, 0
				e.Game_PlaySound(self.game, SOUND_JUMP)
			}
			// A short hop: letting go while rising cuts the rise
			if e.Input_IsActionJustReleased(ACTION_JUMP) && mover.velocity.y < 0 do mover.velocity.y *= 0.45
			mover.velocity.y = min(mover.velocity.y + self.gravity * dt, 600)
			e.CharacterMover_Move(mover, deltaTime)

			// Firm ground under both edges of her feet: where a pit puts her back
			feet := e.Node_GetWorldPosition(mover)
			if mover.onFloor && Level_Solid(self.scene, feet + {-7, 4}) && Level_Solid(self.scene, feet + {7, 4}) {
				self.safe = mover.position
			}
			// Into a pit: health, and back on firm ground
			if self.levelSize != {} && mover.position.y > self.levelSize.y + 48 {
				mover.position = self.safe
				mover.velocity = {}
				if self.scene.camera != nil do e.Camera2D_SnapTo(self.scene.camera, self.safe)
				if state := e.Global(GameState); state != nil {
					e.Game_PlaySound(self.game, SOUND_HURT)
					state.invulnerable = 0
					if GameState_Damage(state, 1) do heroDown(self)
				}
			}

			if self.sprite != nil {
				if !attacking {
					animation := "idle"
					if !mover.onFloor {
						animation = mover.velocity.y < 0 ? "jump" : "fall"
					} else if direction != 0 {
						animation = "run"
					}
					e.AnimationPlayer_Play(&self.sprite.animation, animation)
				}
				// The sheet faces right; a negative scale mirrors it
				self.sprite.scale.x = self.facing
				// Blink while safe after a hit
				state := e.Global(GameState)
				self.sprite.visible = state == nil || state.invulnerable <= 0 || int(state.invulnerable * 10) % 2 == 0
			}
			if camera := self.scene.camera; camera != nil {
				e.Camera2D_Follow(camera, e.Node_GetWorldPosition(self.node) - {0, 24}, deltaTime)
			}
		},
	})
}
