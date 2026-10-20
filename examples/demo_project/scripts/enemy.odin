package scripts

import "core:math"
import e "engine:."
import sdl "vendor:sdl3"

/*
What the forest's enemies (Snail, Boar, Bee) share: an `Enemy` value in each script, with health,
knockback, a red flash when hurt, and a death animation before the node goes.

- The hero's sword finds them through `liveEnemies` (every enemy registers in its ready and
  leaves in its destroy) and their hurtbox: the rectangle or circle of the CollisionShape under
  their Area, as edited in the component.
- Touching the hero is physics: the hero's CharacterMover inside the enemy's Area
  (e.PhysicsBody_IsInArea). Landing on it from above is a stomp (it takes a hit, the hero
  bounces); otherwise the hero is hurt.
- Knockback slides a walker along the ground but never off a ledge or into a wall (the LDtk
  level's Collisions layer: Level_CanWalk); flyers are pushed freely.
*/
Enemy :: struct {
	node: ^e.Node,
	sprite: ^e.AnimatedSprite,
	health: int,
	// Score for defeating it
	points: int,
	flies: bool,
	// The death animation and how long it shows
	deathAnimation: string,
	deathTime: f32,
	// Pushed by a hit, px/s (it slows down by itself)
	knockback: [2]f32,
	// Seconds left: of the red flash, of dying, of ignoring the hero after a stomp
	flash, dying, contactCooldown: f32,
}

// Every enemy alive in the scene (registered in ready, removed in destroy)
liveEnemies: [dynamic]^Enemy

// Sets an enemy up (from its script's ready) and registers it
Enemy_Start :: proc(enemy: ^Enemy, node: ^e.Node, health, points: int, flies: bool, deathAnimation: string, deathTime: f32) {
	enemy.node = node
	enemy.health = max(health, 1)
	enemy.points = points
	enemy.flies = flies
	enemy.deathAnimation = deathAnimation
	enemy.deathTime = deathTime
	if sprite := e.Node_FindChild(node, "Sprite"); e.Node_Is(sprite, e.AnimatedSprite) do enemy.sprite = cast(^e.AnimatedSprite)sprite
	append(&liveEnemies, enemy)
}

// Unregisters an enemy (from its script's destroy)
Enemy_Stop :: proc(enemy: ^Enemy) {
	for other, i in liveEnemies do if other == enemy {
		unordered_remove(&liveEnemies, i)
		return
	}
}

// Whether it's still in the fight (not dying)
Enemy_Alive :: proc(enemy: ^Enemy) -> bool {
	return enemy.health > 0
}

// Its hurtbox in the world: its CollisionShape's rectangle (a circle's square)
Enemy_Box :: proc(enemy: ^Enemy) -> sdl.FRect {
	center := e.Node_GetWorldPosition(enemy.node)
	size := [2]f32{24, 16}
	for child in enemy.node.children {
		if !e.Node_Is(child, e.CollisionShape) do continue
		shape := cast(^e.CollisionShape)child
		center += shape.position
		size = shape.shape == .Rectangle ? shape.size : {shape.radius * 2, shape.radius * 2}
		break
	}
	return {center.x - size.x * 0.5, center.y - size.y * 0.5, size.x, size.y}
}

// Its hurtbox's middle (where blood comes from)
Enemy_Center :: proc(enemy: ^Enemy) -> [2]f32 {
	box := Enemy_Box(enemy)
	return {box.x + box.w * 0.5, box.y + box.h * 0.5}
}

/*
Hits an enemy: it loses health, flashes, is knocked away from `fromX` (world), bleeds; the game
stops for a moment and the camera shakes. At no health it's defeated: its points go to the
score and it plays its death animation.

Returns:
- true if that defeated it
*/
Enemy_Hurt :: proc(enemy: ^Enemy, damage: int, fromX: f32) -> bool {
	if !Enemy_Alive(enemy) do return false
	scene := enemy.node.scene
	away: f32 = Enemy_Center(enemy).x >= fromX ? 1 : -1
	enemy.health -= damage
	enemy.flash = 0.15
	enemy.knockback = {away * 170, enemy.flies ? -60 : 0}
	defeated := enemy.health <= 0
	Effects_Hit(scene, Enemy_Center(enemy), away, defeated ? .Heavy : .Light)
	if defeated {
		enemy.dying = enemy.deathTime
		if state := e.Global(GameState); state != nil do state.score += enemy.points
		e.Game_PlaySound(scene.game, SOUND_DEFEAT)
		if enemy.sprite != nil do e.AnimationPlayer_Play(&enemy.sprite.animation, enemy.deathAnimation, true)
	} else {
		e.Game_PlaySound(scene.game, SOUND_HIT)
	}
	return defeated
}

/*
An enemy's frame: knockback, the flash, dying (it fades, then goes), and touching the hero.
Its script calls it first in its update.

Returns:
- true while the script should leave it alone (dying, or being knocked back)
*/
Enemy_Update :: proc(enemy: ^Enemy, deltaTime: f64) -> (busy: bool) {
	dt := f32(deltaTime)
	node := enemy.node
	enemy.flash = max(enemy.flash - dt, 0)
	enemy.contactCooldown = max(enemy.contactCooldown - dt, 0)
	node.tint = enemy.flash > 0 ? {255, 90, 90, 255} : {255, 255, 255, 255}

	if enemy.dying > 0 {
		enemy.dying -= dt
		node.tint.a = u8(255 * clamp(enemy.dying / enemy.deathTime * 2, 0, 1))
		if enemy.flies do node.position.y += 60 * dt
		if enemy.dying <= 0 do e.Scene_RemoveNode(node.scene, node.id)
		knock(enemy, dt)
		return true
	}

	knocked := knock(enemy, dt)
	touchHero(enemy)
	return knocked
}

// Moves it by its knockback, which fades out; walkers stay on their ground
@(private="file")
knock :: proc(enemy: ^Enemy, dt: f32) -> bool {
	if abs(enemy.knockback.x) < 5 && abs(enemy.knockback.y) < 5 {
		enemy.knockback = {}
		return false
	}
	node := enemy.node
	step := enemy.knockback * dt
	if enemy.flies || Level_CanWalk(node.scene, e.Node_GetWorldPosition(node), math.sign(step.x), 12) {
		node.position.x += step.x
	}
	if enemy.flies do node.position.y += step.y
	enemy.knockback *= math.exp(-8 * dt)
	return true
}

// The hero inside its Area: a stomp from above, else the hero is hurt
@(private="file")
touchHero :: proc(enemy: ^Enemy) {
	hero := currentHero
	if hero == nil || enemy.contactCooldown > 0 || !e.Node_Is(enemy.node, e.Area) do return
	mover := cast(^e.CharacterMover)hero.node
	if !e.PhysicsBody_IsInArea(mover, cast(^e.Area)enemy.node) do return
	feet := e.Node_GetWorldPosition(mover)
	box := Enemy_Box(enemy)
	if mover.velocity.y > 0 && feet.y < box.y + box.h * 0.5 {
		enemy.contactCooldown = 0.3
		Hero_Bounce(hero)
		e.Game_PlaySound(enemy.node.scene.game, SOUND_STOMP)
		Enemy_Hurt(enemy, 1, feet.x)
		return
	}
	Hero_Hurt(hero, Enemy_Center(enemy).x)
}

// Turns a sprite drawn facing left to face `direction` (-1 left, 1 right)
Sprite_FaceLeftSheet :: proc(sprite: ^e.AnimatedSprite, direction: f32) {
	if sprite != nil && direction != 0 do sprite.scale.x = direction > 0 ? -1 : 1
}
