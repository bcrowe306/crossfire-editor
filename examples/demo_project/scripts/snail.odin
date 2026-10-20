package scripts

import e "engine:."
import sdl "vendor:sdl3"

/*
Snail: the forest level's enemies, LDtk entities mapped to components/snail.component.xml (an
Area with a walking sprite). Each snail's "patrol" Point field in LDtk (drawn as a path in LDtk)
is the far end of its walk: it crawls between where it was placed and there. Its "speed" field
sets `speed`.

Landing on it from above squashes it (points, and the hero bounces); walking into it costs a
life (GameState_Hit) and knocks the hero back.
*/
Snail :: struct {
	using script: e.Script,
	// The far end of its walk, in the level (an LDtk Point: the middle of the chosen cell)
	patrol: [2]f32 `export:""`,
	speed: f32 `export:"default=24 min=0 max=200"`,
	home: [2]f32,
	heading: f32,
	sprite: ^e.Node,
	squashed: bool,
}

@(init)
register_Snail :: proc "contextless" () {
	e.Script_Register(Snail, {
		ready = proc(self: ^Snail) {
			self.home = self.node.position
			if self.patrol == {} do self.patrol = self.home
			self.heading = self.patrol.x >= self.home.x ? 1 : -1
			self.sprite = e.Node_FindChild(self.node, "Sprite")
		},
		update = proc(self: ^Snail, _: []sdl.Event, deltaTime: f64) {
			left, right := min(self.home.x, self.patrol.x), max(self.home.x, self.patrol.x)
			x := self.node.position.x + self.heading * self.speed * f32(deltaTime)
			if x >= right do self.heading = -1
			if x <= left do self.heading = 1
			self.node.position.x = clamp(x, left, right)
			// The sheet faces left
			if self.sprite != nil do self.sprite.scale.x = -self.heading
		},
		collisionEnter = proc(self: ^Snail, hit: ^e.Collision) {
			hero := e.Node_GetScript(hit.other, Hero)
			if hero == nil || self.squashed do return
			mover := cast(^e.CharacterMover)hit.other
			heroY := e.Node_GetWorldPosition(hit.other).y
			snail := e.Node_GetWorldPosition(self.node)
			// Falling, feet above its middle: a stomp
			if mover.velocity.y > 0 && heroY < snail.y - 6 {
				self.squashed = true
				Hero_Bounce(hero)
				if state := e.Global(GameState); state != nil do state.score += 3
				e.Game_PlaySound(self.game, SOUND_STOMP)
				e.Scene_RemoveNode(self.scene, self.node.id)
				return
			}
			state := e.Global(GameState)
			if state != nil && state.invulnerable > 0 do return
			Hero_Knock(hero, snail.x)
			if state != nil do GameState_Hit(state)
		},
	})
}
