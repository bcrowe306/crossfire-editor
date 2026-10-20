package scripts

import e "engine:."

/*
The forest level's shared helpers: what a hit looks and feels like, and questions about the
level's ground.

A hit (Effects_Hit) is three things at once:
- blood: an instance of components/blood.component.xml (a one-shot ParticleEmitter, its look
  edited in the editor), sprayed away from whoever struck, removed by its Burst script once its
  particles are gone (e.Scene_AddComponent from code, e.Scene_RemoveComponent);
- a hitstop: the game freezes for a few frames (e.Game_HitStop);
- a camera shake (e.Camera2D_Shake).
*/

// How hard a hit feels
HitWeight :: enum {
	// The hero's sword on an enemy
	Light,
	// An enemy defeated
	Heavy,
	// The hero hurt
	Hurt,
}

// Blood, a hitstop and a shake at `at` (world), the blood flying toward `direction` (-1 left, 1 right)
Effects_Hit :: proc(scene: ^e.Scene, at: [2]f32, direction: f32, weight: HitWeight) {
	if blood := e.Scene_AddComponent(scene, COMPONENT_BLOOD, nil, at); blood != nil && e.Node_Is(blood, e.ParticleEmitter) {
		// Up and away: 300° is up-right, 240° up-left
		(cast(^e.ParticleEmitter)blood).settings.angle = direction >= 0 ? 300 : 240
		if weight == .Heavy do (cast(^e.ParticleEmitter)blood).settings.amount = 48
	}
	switch weight {
	case .Light:
		e.Game_HitStop(scene.game, 0.06)
		e.Camera2D_Shake(scene.camera, 2.5, 0.15)
	case .Heavy:
		e.Game_HitStop(scene.game, 0.09)
		e.Camera2D_Shake(scene.camera, 4, 0.25)
	case .Hurt:
		e.Game_HitStop(scene.game, 0.12)
		e.Camera2D_Shake(scene.camera, 6, 0.3)
	}
}

// The scene's LDtk level (the LDtkLevel node named "Level"), or nil
ForestLevel :: proc(scene: ^e.Scene) -> ^e.LDtkLevelNode {
	level := e.Scene_FindNode(scene, "Level")
	if level == nil || !e.Node_Is(level, e.LDtkLevelNode) do return nil
	return cast(^e.LDtkLevelNode)level
}

// Whether the level's ground (the Collisions IntGrid layer) is at a world position
Level_Solid :: proc(scene: ^e.Scene, at: [2]f32) -> bool {
	return e.LDtk_IntGridAtPosition(ForestLevel(scene), "Collisions", at) != 0
}

/*
Whether something walking on the ground at `feet` (world) can go on toward `direction`: there's
ground ahead under its front edge (`reach` px ahead), and no wall there.
*/
Level_CanWalk :: proc(scene: ^e.Scene, feet: [2]f32, direction, reach: f32) -> bool {
	front := feet + {direction * reach, 0}
	return Level_Solid(scene, front + {0, 4}) && !Level_Solid(scene, front - {0, 8})
}

/*
Burst: on a one-shot ParticleEmitter, the root of components/blood.component.xml. Starts it, then
removes the instance when the emitter finishes (its onFinished event: the cycle ended and its
particles are gone), so effects made from code clean up after themselves.
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
