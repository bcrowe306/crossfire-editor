package scripts

import e "engine:."
import sdl "vendor:sdl3"

/*
CoinCollect: attach it to a node in the editor's inspector (Script).

Fields tagged `export:""` show in the inspector and are saved in the scene. Options inside the
quotes: default=<value> min=<n> max=<n> kind=scene. Untagged fields are the script's own state.
self.node is the node it's attached to; self.scene and self.game are there too.
*/
CoinCollect :: struct {
	using script: e.Script,
	speed: f32 `export:"default=100 min=0"`,
	particleEmitter: ^e.ParticleEmitter `export:"default=."`
}

@(init)
register_CoinCollect :: proc "contextless" () {
	e.Script_Register(CoinCollect, {
		// Once, when the scene starts: every node exists (e.Scene_FindNode(self.scene, "World/Ship"))
		ready = proc(self: ^CoinCollect) {
		e.Event_Subscribe(&self.particleEmitter.onFinished, proc(subject: ^e.EventSubject, source: rawptr, data: e.EventData, userData: rawptr){
			self := cast(^CoinCollect)userData
			e.Scene_RemoveNode(self.scene, self.node.id)
		}, self)
		},
		// Every frame, after the node's own update
		update = proc(self: ^CoinCollect, events: []sdl.Event, dt: f64) {
		},
	})
}
