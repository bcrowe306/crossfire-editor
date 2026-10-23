/*
The demo's own player: the engine's player with the demo's scripts linked in, as the editor's Play
builds it for a project with scripts (play.odin's playerMainSource). `task play:demo` builds and
runs it, without the editor:

	odin build tools/demo/player -collection:engine=../odin_sdl_engine \
		-collection:project=examples/demo_project -out:build/demo_player
	build/demo_player examples/demo_project
*/
package demo_player

import e "engine:."
import scripts "project:scripts"
_ :: scripts

main :: proc() {
	e.Player_Main()
}
