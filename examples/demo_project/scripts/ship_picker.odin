package scripts

import "core:fmt"
import e "engine:."
import sdl "vendor:sdl3"

/*
ShipPicker: on a Label in Options. Left / Right choose the ship (a data resource), shown by name;
the choice goes into the global game state and is saved right away.
*/
ShipPicker :: struct {
	using script: e.Script,
}

@(private="file")
SHIPS := [?]e.DataAsset{DATA_SCOUT, DATA_HAULER}

@(init)
register_ShipPicker :: proc "contextless" () {
	e.Script_Register(ShipPicker, {
		update = proc(self: ^ShipPicker, events: []sdl.Event, _: f64) {
			state := e.Global(GameState)
			if state == nil do return
			current := 0
			for ship, i in SHIPS do if ship == state.ship do current = i
			for event in events {
				if event.type != .KEY_DOWN || event.key.repeat do continue
				#partial switch event.key.scancode {
				case .LEFT:  current = (current + len(SHIPS) - 1) % len(SHIPS)
				case .RIGHT: current = (current + 1) % len(SHIPS)
				case: continue
				}
				state.ship = SHIPS[current]
				e.Save_Game()
			}
			stats := e.Data(ShipStats, SHIPS[current])
			if label := cast(^e.Label)self.node; e.Node_Is(self.node, e.Label) && stats != nil {
				label.text = fmt.tprintf("<  Ship: %s  (speed %.0f)  >", stats.name, stats.speed)
			}
		},
	})
}
