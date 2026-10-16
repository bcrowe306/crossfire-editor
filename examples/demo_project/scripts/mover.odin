package scripts

import e "engine:."
import sdl "vendor:sdl3"

/*
Mover: attach it to a node in the editor's inspector (Script).

Fields tagged `export:""` show in the inspector and are saved in the scene. Options inside the
quotes: default=<value> min=<n> max=<n> kind=scene. Untagged fields are the script's own state.
self.node is the node it's attached to; self.scene and self.game are there too.
*/
Mover :: struct {
	using script: e.Script,
	speed: f32 `export:"default=100 min=0"`,
}

@(init)
register_Mover :: proc "contextless" () {
	e.Script_Register(Mover, {
		// Once, when the scene starts: every node exists (e.Scene_FindNode(self.scene, "World/Ship"))
		ready = proc(self: ^Mover) {
		},
		// Every frame, after the node's own update
		update = proc(self: ^Mover, events: []sdl.Event, dt: f64) {
			self.node.position.x += self.speed * f32(dt)
		},
	})
}
