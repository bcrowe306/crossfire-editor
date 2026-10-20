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
letting go early makes a short hop. The camera follows inside the level's bounds; falling into
a pit costs a life and starts over at the spawn point. Escape goes back to the menu.
*/
Hero :: struct {
	using script: e.Script,
	// Run speed in pixels per second (the LDtk entity's "speed" field sets it)
	speed: f32 `export:"default=110 min=20 max=400"`,
	jumpSpeed: f32 `export:"default=380 min=50 max=800"`,
	gravity: f32 `export:"default=900 min=0 max=3000"`,

	sprite: ^e.AnimatedSprite,
	spawn: [2]f32,
	// The level's size, for the camera and pits
	levelSize: [2]f32,
	// Seconds left to still jump after leaving the floor, and of a jump pressed early
	coyote, jumpBuffer: f32,
	// Seconds left of being pushed back by a hit, and which way
	knockback, knockDirection: f32,
}

// Pushes the hero away from a hit at `from` (a world x), up and back
Hero_Knock :: proc(hero: ^Hero, from: f32) {
	mover := cast(^e.CharacterMover)hero.node
	hero.knockDirection = e.Node_GetWorldPosition(hero.node).x < from ? -1 : 1
	hero.knockback = 0.25
	mover.velocity.y = -220
}

// A bounce off a stomped enemy
Hero_Bounce :: proc(hero: ^Hero) {
	(cast(^e.CharacterMover)hero.node).velocity.y = -260
}

@(init)
register_Hero :: proc "contextless" () {
	e.Script_Register(Hero, {
		ready = proc(self: ^Hero) {
			self.spawn = self.node.position
			if sprite := e.Node_FindChild(self.node, "Sprite"); e.Node_Is(sprite, e.AnimatedSprite) {
				self.sprite = cast(^e.AnimatedSprite)sprite
			}
			// The level the hero is in: the LDtkLevel node named "Level"
			if level := e.Scene_FindNode(self.scene, "Level"); level != nil && e.Node_Is(level, e.LDtkLevelNode) {
				root := cast(^e.LDtkLevelNode)level
				if len(root.views) > 0 do self.levelSize = root.views[0].level.size
			}
			if camera := self.scene.camera; camera != nil {
				if self.levelSize != {} do e.Camera2D_SetBounds(camera, {0, 0}, self.levelSize)
				e.Camera2D_SnapTo(camera, e.Node_GetWorldPosition(self.node))
			}
		},
		update = proc(self: ^Hero, _: []sdl.Event, deltaTime: f64) {
			if e.Input_IsActionJustPressed(ACTION_UI_CANCEL) {
				self.game->switchScene("MenuScene")
				return
			}
			mover := cast(^e.CharacterMover)self.node
			dt := f32(deltaTime)
			direction := e.Input_GetAxis(ACTION_UI_LEFT, ACTION_UI_RIGHT)

			mover.velocity.x = direction * self.speed
			if self.knockback > 0 {
				self.knockback -= dt
				mover.velocity.x = self.knockDirection * 140
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

			// Into a pit: a life, and back to the start
			if self.levelSize != {} && mover.position.y > self.levelSize.y + 48 {
				if state := e.Global(GameState); state != nil {
					state.invulnerable = 0
					GameState_Hit(state)
				}
				mover.position = self.spawn
				mover.velocity = {}
				if self.scene.camera != nil do e.Camera2D_SnapTo(self.scene.camera, self.spawn)
			}

			if self.sprite != nil {
				animation := "idle"
				if !mover.onFloor {
					animation = mover.velocity.y < 0 ? "jump" : "fall"
				} else if direction != 0 {
					animation = "run"
				}
				e.AnimationPlayer_Play(&self.sprite.animation, animation)
				// The sheet faces right; a negative scale mirrors it
				if direction != 0 do self.sprite.scale.x = direction < 0 ? -1 : 1
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
