package scripts

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import e "engine:."
import sdl "vendor:sdl3"

/*
The levels' furniture, each an LDtk entity mapped to a component and running the script named
like it:

- **Runestone**: a checkpoint. Touched, its rune lights (a Light2D brightened by a tween,
  particles) and the run is saved there (GameState_Checkpoint): Continue and Retry come back to it.
- **Lorestone**: a stone with something to say. Near it a prompt shows the interact action's key
  (from the input bindings, so it follows the player's own); pressed, the HUD's DialogueBox plays
  the node of `dialogues/story.dialogue.xml` its LDtk `dialogue` field names.
- **Platform**: a moving platform. Its component's Animator (made in the Timeline) moves the
  script's `t` from 0 to 1 and back, eased; the script puts the platform between where it was
  placed and its LDtk `path` Point, and carries the hero standing on it.
- **Candle**: a flickering light.
- **Exit**: the level's end (the mine in the forest, a rune portal in the hollow): the next
  scene (its `next` field) through the loading screen, saved at its start.
- **Gate**: a log that drops behind the hero in the boss's arena (an Animator clip), and its
  collision with it.
- **BossTrigger**: an LDtk rectangle (the LDtkLevel node's entity rule, `make="Rectangle"`, makes
  it a plain node; its size is the entity's, `e.LDtk_EntityOf`) that starts the boss fight once
  the hero's feet are inside it, and closes the gate its "gate" field points at (an LDtk entity
  reference: `e.LDtk_EntityRefNode`).
*/

Runestone :: struct {
	using script: e.Script,
	rune: ^e.Sprite `export:"default=Rune"`,
	runeLit: ^e.Sprite `export:"default=RuneLit"`,
	glow: ^e.Light2D `export:"default=Glow"`,
	motes: ^e.ParticleEmitter `export:"default=Motes"`,
	burst: ^e.ParticleEmitter `export:"default=Burst"`,
	lit: bool,
	time: f32,
}

@(private="file")
lightStone :: proc(self: ^Runestone, quietly: bool) {
	self.lit = true
	if self.rune != nil do self.rune.visible = false
	if self.runeLit != nil {
		self.runeLit.visible = true
		if !quietly do e.Tween_FromTo(e.Tween_Create(self.runeLit), &self.runeLit.scale, [2]f32{2.2, 2.2}, [2]f32{1, 1}, 0.5, .OutBack)
	}
	if self.motes != nil do e.ParticleEmitter_Start(self.motes)
	if self.glow != nil {
		if quietly do self.glow.settings.energy = 1
		else do e.Tween_FromTo(e.Tween_Create(self.glow), &self.glow.settings.energy, 3, 1, 1.2, .OutCubic)
	}
}

@(init)
register_Runestone :: proc "contextless" () {
	e.Script_Register(Runestone, {
		ready = proc(self: ^Runestone) {
			if self.glow != nil do self.glow.settings.energy = 0
			// The save's rune stone is already lit
			if state := State(); state != nil && state.run.checkpoint != "" && state.run.checkpoint == EntityKey(self.node) do lightStone(self, true)
		},
		update = proc(self: ^Runestone, _: []sdl.Event, dt: f64) {
			self.time += f32(dt)
			if self.lit && self.runeLit != nil do self.runeLit.tint.a = u8(200 + 55 * math.sin(self.time * 3))
		},
		collisionEnter = proc(self: ^Runestone, collision: ^e.Collision) {
			hero := currentHero
			if self.lit || hero == nil || collision.other == nil || cast(^e.Node)collision.other != hero.node do return
			lightStone(self, false)
			if self.burst != nil do e.ParticleEmitter_Start(self.burst)
			Sfx(self.game, SOUND_CHECKPOINT)
			if state := State(); state != nil do GameState_Checkpoint(state, EntityKey(self.node))
			Effects_Popup(self.scene, e.Node_GetWorldPosition(self.node) - {0, 70}, "Progress saved", {150, 215, 255, 255})
			Hud_Toast(self.scene, "The rune remembers you. Progress saved.")
		},
	})
}

Lorestone :: struct {
	using script: e.Script,
	// The dialogue node it plays (the LDtk entity's "dialogue" field)
	dialogue: string `export:""`,
	prompt: ^e.RichText `export:"default=Prompt"`,
	near: bool,
	time: f32,
}

@(init)
register_Lorestone :: proc "contextless" () {
	e.Script_Register(Lorestone, {
		ready = proc(self: ^Lorestone) {
			if self.prompt != nil do self.prompt.visible = false
		},
		update = proc(self: ^Lorestone, _: []sdl.Event, dt: f64) {
			self.time += f32(dt)
			hero := currentHero
			near := hero != nil && !hero.dead && e.Node_Is(self.node, e.Area) && e.PhysicsBody_IsInArea(Hero_Mover(hero), cast(^e.Area)self.node)
			talking := Dialogue_Playing(self.scene)
			if self.prompt != nil {
				self.prompt.visible = near && !talking
				if near && !self.near do e.Control_SetText(self.prompt, fmt.tprintf("[color=#ffe08a]%s[/color] Read", BindingName(ACTION_INTERACT)))
				self.prompt.offset.y = -50 + math.sin(self.time * 4) * 2
			}
			self.near = near
			if near && !talking && Hero_HasControl(hero) && e.Input_IsActionJustPressed(ACTION_INTERACT) {
				Dialogue_Play(self.scene, self.dialogue)
			}
		},
	})
}

// The first keyboard (else any) binding of an action, as players read it ("W", "Space")
BindingName :: proc(action: string) -> string {
	bindings := e.Input_GetBindings(action)
	for b in bindings do if _, key := b.(e.KeyBinding); key do return e.InputBinding_Describe(b)
	if len(bindings) > 0 do return e.InputBinding_Describe(bindings[0])
	return "?"
}

Platform :: struct {
	using script: e.Script,
	// The far end of its trip (the LDtk entity's "path" Point, in the level)
	path: [2]f32 `export:""`,
	// Its speed, px/s: sets how fast its Animator plays
	speed: f32 `export:"default=40 min=1 max=400"`,
	// Where it is between its two ends, 0 to 1: the Animator's track moves it
	t: f32 `export:"min=0 max=1"`,
	animator: ^e.Animator `export:"default=Move"`,
	home: [2]f32,
	last: [2]f32,
	// Which way it went last frame (along its path: +1 out, -1 back)
	heading: f32,
}

@(init)
register_Platform :: proc "contextless" () {
	e.Script_Register(Platform, {
		ready = proc(self: ^Platform) {
			self.home = self.node.position
			// LDtk's point is a cell's middle; the platform stands on the cell's bottom like its entity
			if self.path == {} do self.path = self.home
			else do self.path.y += 8
			self.last = self.home
			// The clip is 2 s there and back: its speed makes the trip take distance / speed
			if self.animator != nil {
				trip := max(linalg.length(self.path - self.home) / max(self.speed, 1), 0.5)
				self.animator.speed = 1 / trip
			}
		},
		update = proc(self: ^Platform, _: []sdl.Event, dt: f64) {
			target := linalg.lerp(self.home, self.path, clamp(self.t, 0, 1))
			delta := target - self.node.position
			self.node.position = target
			// A creak where it turns back, when the hero is near enough to hear it
			if delta != {} {
				heading := linalg.dot(delta, self.path - self.home) > 0 ? f32(1) : -1
				if self.heading != 0 && heading != self.heading && Hero_Near(e.Node_GetWorldPosition(self.node), 260) do Sfx(self.game, SOUND_PLATFORM, 0.4)
				self.heading = heading
			}
			// The hero standing on it rides along
			if hero := currentHero; hero != nil && delta != {} {
				mover := Hero_Mover(hero)
				feet := Hero_Feet(hero)
				at := e.Node_GetWorldPosition(self.node)
				if mover.onFloor && abs(feet.x - at.x) < 30 && abs(feet.y - (at.y - 16)) < 6 do mover.position += delta
			}
		},
	})
}

Candle :: struct {
	using script: e.Script,
	light: ^e.Light2D `export:"default=Light"`,
	energy: f32,
	time: f32,
}

@(init)
register_Candle :: proc "contextless" () {
	e.Script_Register(Candle, {
		ready = proc(self: ^Candle) {
			if self.light != nil do self.energy = self.light.settings.energy
			self.time = rand.float32() * 10
		},
		update = proc(self: ^Candle, _: []sdl.Event, dt: f64) {
			self.time += f32(dt)
			if self.light != nil do self.light.settings.energy = self.energy * (0.88 + 0.08 * math.sin(self.time * 9) + 0.05 * math.sin(self.time * 23 + 1))
		},
	})
}

Exit :: struct {
	using script: e.Script,
	// The scene it leads to (the LDtk entity's "next" field)
	next: string `export:"kind=scene"`,
	// "Mine" or "Portal"
	kind: string `export:"default=Mine"`,
	mine: ^e.Sprite `export:"default=Mine"`,
	portal: ^e.Node `export:"default=Portal"`,
	leaving: f32,
}

@(init)
register_Exit :: proc "contextless" () {
	e.Script_Register(Exit, {
		ready = proc(self: ^Exit) {
			if self.mine != nil do self.mine.visible = self.kind != "Portal"
			if self.portal != nil do self.portal.visible = self.kind == "Portal"
		},
		update = proc(self: ^Exit, _: []sdl.Event, dt: f64) {
			if self.leaving <= 0 do return
			self.leaving -= f32(dt)
			if self.leaving <= 0 {
				if state := State(); state != nil do GameState_LevelComplete(state, self.next)
			}
		},
		collisionEnter = proc(self: ^Exit, collision: ^e.Collision) {
			hero := currentHero
			if self.leaving > 0 || hero == nil || hero.dead || collision.other == nil || cast(^e.Node)collision.other != hero.node do return
			self.leaving = 1.6
			if state := State(); state != nil {
				state.cutscene += 1
				state.run.score += 250
			}
			Sfx(self.game, SOUND_LEVEL_COMPLETE)
			Hud_Toast(self.scene, self.kind == "Portal" ? "Into the heart of the forest..." : "Deeper into the woods...")
			Level_FadeMusic(self.scene, 1.4)
		},
	})
}

Gate :: struct {
	using script: e.Script,
	sprite: ^e.Sprite `export:"default=Sprite"`,
	shape: ^e.CollisionShape `export:"default=Shape"`,
	animator: ^e.Animator `export:"default=Drop"`,
	closed: bool,
}

// Drops the gate (it blocks the way back)
Gate_Close :: proc(gate: ^Gate) {
	if gate.closed do return
	gate.closed = true
	if gate.sprite != nil do gate.sprite.visible = true
	if gate.animator != nil do e.Animator_Play(gate.animator, "close", true)
	if gate.shape != nil {
		gate.shape.disabled = false
		if e.Node_Is(gate.node, e.StaticBody) do e.PhysicsBody_RebuildShapes(cast(^e.PhysicsBody)gate.node)
	}
	Sfx(gate.game, SOUND_GATE_OPEN, 0.9, 0.8)
}

@(init)
register_Gate :: proc "contextless" () {
	e.Script_Register(Gate, {
		ready = proc(self: ^Gate) {
			if self.sprite != nil do self.sprite.visible = false
		},
	})
}

// The gate dropped (its Animator's event track, "landed": a listener in the component)
Gate_onDropEvent :: proc(self: ^Gate, source: ^e.Node, data: e.EventData) {
	Sfx(self.game, SOUND_BOSS_SLAM, 0.6, 1.3)
	e.Camera2D_Shake(self.scene.camera, 3, 0.25)
	Effects_Dust(self.scene, e.Node_GetWorldPosition(self.node), 14)
}

@(init)
register_Gate_onDropEvent :: proc "contextless" () {
	e.Script_Listener(Gate, "onDropEvent", Gate_onDropEvent)
}

BossTrigger :: struct {
	using script: e.Script,
	fired: bool,
}

@(init)
register_BossTrigger :: proc "contextless" () {
	e.Script_Register(BossTrigger, {
		update = proc(self: ^BossTrigger, _: []sdl.Event, _: f64) {
			hero := currentHero
			entity := e.LDtk_EntityOf(self.node)
			if self.fired || hero == nil || hero.dead || entity == nil do return
			// The node is the rectangle's top-left corner (the entity's pivot is 0, 0)
			at := e.Node_GetWorldPosition(self.node)
			feet := Hero_Feet(hero)
			if feet.x >= at.x && feet.x <= at.x + entity.size.x && feet.y >= at.y && feet.y <= at.y + entity.size.y + 4 {
				self.fired = true
				Level_StartBoss(self.scene, self.node)
			}
		},
	})
}
