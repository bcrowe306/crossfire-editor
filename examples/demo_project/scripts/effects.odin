package scripts

import "core:fmt"
import e "engine:."
import sdl "vendor:sdl3"

/*
Shared helpers: what a hit looks and feels like, floating text, and questions about the level's
ground.

A hit (`Effects_Hit`) is several things at once, each an engine feature:
- particles: an instance of a one-shot ParticleEmitter component (`components/blood.component.xml`
  or `sparks.component.xml`, their look edited in the editor), added from code with
  `e.Scene_AddComponent` and removed by its `Burst` script once its particles are gone;
- a hitstop: the game freezes for a few frames (`e.Game_HitStop`);
- a camera shake (`e.Camera2D_Shake`) and a gamepad rumble (`e.Input_Rumble`).
*/

// How hard a hit feels
HitWeight :: enum {
	// The hero's sword on an enemy
	Light,
	// An enemy defeated
	Heavy,
	// The hero hurt
	Hurt,
	// The boss's slam, its defeat
	Huge,
}

// Particles, a hitstop, a shake and a rumble at `at` (world), the particles flying toward
// `direction` (-1 left, 1 right)
Effects_Hit :: proc(scene: ^e.Scene, at: [2]f32, direction: f32, weight: HitWeight) {
	component := weight == .Hurt ? COMPONENT_BLOOD : COMPONENT_SPARKS
	if burst := e.Scene_AddComponent(scene, component, nil, at); burst != nil && e.Node_Is(burst, e.ParticleEmitter) {
		emitter := cast(^e.ParticleEmitter)burst
		// Up and away: 300° is up-right, 240° up-left
		emitter.settings.angle = direction >= 0 ? 300 : 240
		if weight == .Heavy || weight == .Huge do emitter.settings.amount *= 2
	}
	camera := scene.camera
	switch weight {
	case .Light:
		e.Game_HitStop(scene.game, 0.05)
		e.Camera2D_Shake(camera, 2, 0.12)
		e.Input_Rumble(0.2, 0.3, 0.08)
	case .Heavy:
		e.Game_HitStop(scene.game, 0.08)
		e.Camera2D_Shake(camera, 3.5, 0.22)
		e.Input_Rumble(0.4, 0.5, 0.15)
	case .Hurt:
		e.Game_HitStop(scene.game, 0.12)
		e.Camera2D_Shake(camera, 5, 0.3)
		e.Input_Rumble(0.8, 0.6, 0.25)
	case .Huge:
		e.Game_HitStop(scene.game, 0.1)
		e.Camera2D_Shake(camera, 7, 0.5)
		e.Input_Rumble(1, 1, 0.4)
	}
}

// A puff of dust at `at` (world): a landing, a step, an enemy gone
Effects_Dust :: proc(scene: ^e.Scene, at: [2]f32, amount := 8) {
	if dust := e.Scene_AddComponent(scene, COMPONENT_DUST, nil, at); dust != nil && e.Node_Is(dust, e.ParticleEmitter) {
		(cast(^e.ParticleEmitter)dust).settings.amount = amount
	}
}

/*
Text that floats up from `at` (world) and fades: "+10", "Saved". A Label (it draws at its
screen position at its own size, so the camera's zoom doesn't blow it up), moved and faded by a
tween (`e.Tween_To`), removed when the tween's last step calls back.
*/
Effects_Popup :: proc(scene: ^e.Scene, at: [2]f32, text: string, color: sdl.Color = {255, 230, 140, 255}, size: f32 = 26) {
	label := e.CreateLabel(scene, text, at, size, color, true, e.JoinPath(scene.game.projectDir, FONT_PIXELIFYSANS.path))
	if label == nil do return
	label.layer = .Layer6
	tween := e.Tween_Create(label)
	e.Tween_To(tween, &label.position, at - {0, 22}, 0.9, .OutCubic)
	e.Tween_Parallel(tween)
	e.Tween_To(tween, &label.tint, sdl.Color{255, 255, 255, 0}, 0.9, .InQuad)
	e.Tween_Call(tween, proc(user: rawptr) {
		node := cast(^e.Node)user
		e.Scene_RemoveNode(node.scene, node.id)
	}, label)
}

// "+n" over something picked up or defeated
Effects_Score :: proc(scene: ^e.Scene, at: [2]f32, points: int) {
	Effects_Popup(scene, at, fmt.tprintf("+%d", points))
}

// The scene's LDtk level (the LDtkLevel node named "Level"), or nil
LevelNode :: proc(scene: ^e.Scene) -> ^e.LDtkLevelNode {
	level := e.Scene_FindNode(scene, "Level")
	if level == nil || !e.Node_Is(level, e.LDtkLevelNode) do return nil
	return cast(^e.LDtkLevelNode)level
}

// The level's size in pixels ({} without one)
LevelSize :: proc(scene: ^e.Scene) -> [2]f32 {
	if level := LevelNode(scene); level != nil && len(level.views) > 0 do return level.views[0].level.size
	return {}
}

// Whether the level's solid ground (the Ground IntGrid layer's grass or stone) is at a world position
Level_Solid :: proc(scene: ^e.Scene, at: [2]f32) -> bool {
	value := e.LDtk_IntGridAtPosition(LevelNode(scene), "Ground", at)
	return value == GROUND_GRASS || value == GROUND_STONE
}

// Whether there's anything to stand on (ground or a plank) at a world position
Level_Floor :: proc(scene: ^e.Scene, at: [2]f32) -> bool {
	value := e.LDtk_IntGridAtPosition(LevelNode(scene), "Ground", at)
	return value == GROUND_GRASS || value == GROUND_STONE || value == GROUND_PLANK
}

// The Ground layer's values (tools/demo/make_demo.py)
GROUND_GRASS :: 1
GROUND_PLANK :: 2
GROUND_STONE :: 3
GROUND_WATER :: 4

/*
Whether something walking on the ground at `feet` (world) can go on toward `direction`: there's
floor ahead under its front edge (`reach` px ahead), and no wall there.
*/
Level_CanWalk :: proc(scene: ^e.Scene, feet: [2]f32, direction, reach: f32) -> bool {
	front := feet + {direction * reach, 0}
	return Level_Floor(scene, front + {0, 4}) && !Level_Solid(scene, front - {0, 8})
}

// The LDtk iid of the entity a node was made for ("" if it wasn't)
EntityKey :: proc(node: ^e.Node) -> string {
	if entity := e.LDtk_EntityOf(node); entity != nil do return entity.iid
	return ""
}

/*
Burst: on a one-shot ParticleEmitter (the root of components/blood.component.xml, sparks,
dust...). Starts it, then removes the instance when the emitter finishes (its onFinished event:
the cycle ended and its particles are gone), so effects made from code clean up after
themselves.
*/
Burst :: struct {
	using script: e.Script,
}

@(init)
register_Burst :: proc "contextless" () {
	e.Script_Register(Burst, {
		ready = proc(self: ^Burst) {
			if !e.Node_Is(self.node, e.ParticleEmitter) do return
			emitter := cast(^e.ParticleEmitter)self.node
			e.Event_Subscribe(&emitter.onFinished, proc(_: ^e.EventSubject, source: rawptr, _: e.EventData, _: rawptr) {
				emitter := cast(^e.ParticleEmitter)source
				e.Scene_RemoveComponent(emitter.scene, emitter.id)
			}, nil)
			e.ParticleEmitter_Start(emitter)
		},
	})
}
