package scripts

import "core:fmt"
import "core:math/rand"
import e "engine:."
import sdl "vendor:sdl3"

/*
Things to pick up, each an LDtk entity mapped to a component (an Area, its sprite, a bob made in
the Timeline: the component's Animator) and running the script named like it:

- **Coin**: score and a coin; its LDtk `value` field says how many.
- **Gem**: the levels' secrets (three each): counted, shown on the victory screen.
- **Potion**: a heart back.
- **Pot**: breaks under the sword and spills coins (instances of the Coin component, added from
  code with `e.Scene_AddComponent` and sent flying with tweens).

A pickup collected is remembered by its LDtk entity iid in the run (GameState_Take), so after a
Continue it stays gone; the Area's `collisionEnter` hook says when the hero walks in.
*/

// Shared by the pickups: the hero walked into it
@(private="file")
isHero :: proc(collision: ^e.Collision) -> bool {
	hero := currentHero
	return hero != nil && !hero.dead && collision.other != nil && cast(^e.Node)collision.other == hero.node
}

// Gone if this run already took it (a Continue)
@(private="file")
alreadyTaken :: proc(node: ^e.Node) -> bool {
	state := State()
	if state != nil && GameState_Taken(state, EntityKey(node)) {
		e.Scene_RemoveNode(node.scene, node.id)
		return true
	}
	return false
}

// Collected: remembered, a sparkle, removed
@(private="file")
collect :: proc(node: ^e.Node, component := COMPONENT_SPARKLE) {
	if state := State(); state != nil do GameState_Take(state, EntityKey(node))
	e.Scene_AddComponent(node.scene, component, nil, e.Node_GetWorldPosition(node))
	e.Scene_RemoveNode(node.scene, node.id)
}

// Starts a pickup's bob at a random point, so a row of them doesn't move in step
@(private="file")
offsetBob :: proc(node: ^e.Node) {
	if bob := e.Node_FindChild(node, "Bob"); bob != nil && e.Node_Is(bob, e.Animator) {
		animator := cast(^e.Animator)bob
		e.Animator_Seek(animator, rand.float32() * 1.2)
	}
}

Coin :: struct {
	using script: e.Script,
	// Coins it's worth (the LDtk entity's "value" field)
	value: int `export:"default=1 min=1 max=100"`,
	taken: bool,
}

@(init)
register_Coin :: proc "contextless" () {
	e.Script_Register(Coin, {
		ready = proc(self: ^Coin) {
			if alreadyTaken(self.node) do return
			offsetBob(self.node)
		},
		update = proc(self: ^Coin, _: []sdl.Event, dt: f64) {
			// A coin spilled from a pot can appear around her: taken as soon as she touches it
			if !self.taken && currentHero != nil && e.Node_Is(self.node, e.Area) {
				if e.PhysicsBody_IsInArea(Hero_Mover(currentHero), cast(^e.Area)self.node) do takeCoin(self)
			}
		},
		collisionEnter = proc(self: ^Coin, collision: ^e.Collision) {
			if !self.taken && isHero(collision) do takeCoin(self)
		},
	})
}

@(private="file")
takeCoin :: proc(self: ^Coin) {
	self.taken = true
	if state := State(); state != nil {
		state.run.coins += self.value
		state.run.score += 5 * self.value
	}
	Sfx(self.game, SOUND_COIN, 0.7, rand.float32_range(0.95, 1.1))
	if self.value > 1 do Effects_Score(self.scene, e.Node_GetWorldPosition(self.node), 5 * self.value)
	collect(self.node)
}

Gem :: struct {
	using script: e.Script,
}

@(init)
register_Gem :: proc "contextless" () {
	e.Script_Register(Gem, {
		ready = proc(self: ^Gem) {
			if alreadyTaken(self.node) do return
			offsetBob(self.node)
		},
		collisionEnter = proc(self: ^Gem, collision: ^e.Collision) {
			if !isHero(collision) do return
			state := State()
			if state != nil {
				state.run.gems += 1
				state.run.score += 100
			}
			Sfx(self.game, SOUND_SHARD)
			Effects_Popup(self.scene, e.Node_GetWorldPosition(self.node) - {0, 8}, state != nil ? fmt.tprintf("Gem %d", gemsInLevel(state, self.scene)) : "Gem", {140, 210, 255, 255})
			e.Camera2D_Shake(self.scene.camera, 1.5, 0.2)
			collect(self.node, COMPONENT_SPARKLE)
		},
	})
}

// How many of this level's gems the run has (counting the one just taken)
@(private="file")
gemsInLevel :: proc(state: ^GameState, scene: ^e.Scene) -> int {
	level := LevelNode(scene)
	if level == nil do return state.run.gems
	count := 1
	for gem in e.LDtk_FindEntityNodes(level, "Gem") do if GameState_Taken(state, EntityKey(gem)) do count += 1
	return count
}

Potion :: struct {
	using script: e.Script,
	hearts: int `export:"default=1 min=1 max=10"`,
}

@(init)
register_Potion :: proc "contextless" () {
	e.Script_Register(Potion, {
		ready = proc(self: ^Potion) {
			if alreadyTaken(self.node) do return
			offsetBob(self.node)
		},
		collisionEnter = proc(self: ^Potion, collision: ^e.Collision) {
			if !isHero(collision) do return
			state := State()
			if state == nil || state.health >= state.maxHealth do return
			GameState_Heal(state, self.hearts)
			Sfx(self.game, SOUND_HEART)
			Effects_Popup(self.scene, e.Node_GetWorldPosition(self.node) - {0, 8}, "+1 heart", {255, 140, 140, 255})
			collect(self.node)
		},
	})
}

Pot :: struct {
	using script: e.Script,
	// Coins inside (the LDtk entity's "coins" field)
	coins: int `export:"default=2 min=0 max=20"`,
	broken: bool,
}

// Every pot in the scene the sword can break
livePots: [dynamic]^Pot

// A pot's box in the world (its CollisionShape)
Pot_Box :: proc(pot: ^Pot) -> sdl.FRect {
	at := e.Node_GetWorldPosition(pot.node)
	return {at.x - 7, at.y - 20, 14, 20}
}

// Breaks a pot (the hero's sword): shards, a crash, its coins flying out
Pot_Break :: proc(pot: ^Pot) {
	if pot.broken do return
	pot.broken = true
	if state := State(); state != nil do GameState_Take(state, EntityKey(pot.node))
	at := e.Node_GetWorldPosition(pot.node)
	Sfx(pot.game, SOUND_POT_BREAK, 0.9, rand.float32_range(0.9, 1.1))
	if shards := e.Scene_AddComponent(pot.scene, COMPONENT_SHARDS, nil, at - {0, 10}); shards == nil do Effects_Dust(pot.scene, at, 10)
	for i in 0 ..< pot.coins {
		coin := e.Scene_AddComponent(pot.scene, COMPONENT_COIN, pot.node.parent, pot.node.position - {0, 12})
		if coin == nil do continue
		// Out in an arc, then down to the floor: a tween on its position (it's taken once it lands)
		spread := (f32(i) - f32(pot.coins - 1) * 0.5) * 14
		landing := pot.node.position + {spread + rand.float32_range(-3, 3), -8}
		tween := e.Tween_Create(coin)
		e.Tween_To(tween, &coin.position, pot.node.position + {spread * 0.6, -40 - rand.float32() * 12}, 0.25, .OutQuad)
		e.Tween_To(tween, &coin.position, landing, 0.3, .OutBounce)
	}
	e.Scene_RemoveNode(pot.scene, pot.node.id)
}

@(init)
register_Pot :: proc "contextless" () {
	e.Script_Register(Pot, {
		ready = proc(self: ^Pot) {
			if alreadyTaken(self.node) do return
			append(&livePots, self)
		},
		destroy = proc(self: ^Pot) {
			for other, i in livePots do if other == self {
				unordered_remove(&livePots, i)
				break
			}
		},
	})
}
