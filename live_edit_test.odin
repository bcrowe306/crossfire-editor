package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"

// The live view: the game's replies read into State.live (the tree's depths, stats and their
// history, a chosen node's properties), typed values kept, nothing sent without a game

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
the_live_view_reads_the_game :: proc(t: ^testing.T) {
	state := State{project = Project_CreateTestProject("build/test_live"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, themeSelection = -1, dataSelection = -1}
	defer State_Destroy(&state)
	live := &state.live

	Live_Ingest(&state, `{"type":"tree","scene":"Level","nodes":[{"id":"a","name":"World","type":"Node","parent":"","visible":true},{"id":"b","name":"Hero","type":"Sprite","parent":"a","visible":true},{"id":"c","name":"Hat","type":"Sprite","parent":"b","visible":false}]}`)
	testing.expect(t, live.connected && live.scene == "Level" && len(live.nodes) == 3, "the tree")
	testing.expect(t, live.nodes[0].depth == 0 && live.nodes[1].depth == 1 && live.nodes[2].depth == 2 && !live.nodes[2].visible, "depths")
	for _ in 0..<LIVE_HISTORY + 5 do Live_Ingest(&state, `{"type":"stats","fps":60,"frame":16.7,"update":0.5,"physics":0.2,"draw":1.1,"nodes":3,"drawn":2,"paused":true}`)
	testing.expect(t, live.stats.nodes == 3 && live.stats.drawn == 2 && live.paused, "stats")
	testing.expect_value(t, len(live.history), LIVE_HISTORY)
	// Another tree replaces the nodes
	Live_Ingest(&state, `{"type":"tree","scene":"Level","nodes":[{"id":"a","name":"World","type":"Node","parent":"","visible":true}]}`)
	testing.expect_value(t, len(live.nodes), 1)

	// A node chosen: its properties come (another node's are ignored); a typed value is kept over
	// the game's until another node is chosen. Without a game nothing is sent (and nothing breaks)
	sendTo(&state, Live_Selected("a"))
	testing.expect_value(t, live.selected, "a")
	Live_Ingest(&state, `{"type":"node","id":"z","properties":[{"name":"position","value":"1, 1"}]}`)
	testing.expect_value(t, len(live.properties), 0)
	Live_Ingest(&state, `{"type":"node","id":"a","properties":[{"name":"position","value":"10, 20"},{"name":"visible","value":"true"}]}`)
	testing.expect(t, len(live.properties) == 2 && live.properties[0].value == "10, 20", "its properties")
	sendTo(&state, Live_Property_Edited{"position", "5, 5"})
	testing.expect_value(t, live.edits["position"], "5, 5")
	sendTo(&state, Live_Selected("b"))
	testing.expect(t, len(live.edits) == 0 && len(live.properties) == 0, "cleared for another node")
	testing.expect(t, !Live_Send(&state, "watch"), "no game")
	// Garbage is ignored
	Live_Ingest(&state, `not json`)
	Live_Ingest(&state, `{"type":"nonsense"}`)
}

// What the editor wrote to the game's stdin since the last call
@(private="file")
sentLines :: proc(reader: ^os.File) -> string {
	buffer: [256]u8
	hasData, _ := os.pipe_has_data(reader)
	if !hasData do return ""
	n, _ := os.read(reader, buffer[:])
	return strings.clone(string(buffer[:n]), context.temp_allocator)
}

@(test)
the_toolbar_shows_and_hides_the_games_collision_shapes :: proc(t: ^testing.T) {
	state := State{project = Project_CreateTestProject("build/test_live_shapes"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, themeSelection = -1, dataSelection = -1}
	defer State_Destroy(&state)

	// Not playing: the project's setting, a project undo step
	testing.expect(t, !PhysicsDebug_Shown(&state), "off at first")
	sendTo(&state, Action.Toggle_Physics_Debug)
	testing.expect(t, state.project.physics.debugDraw && PhysicsDebug_Shown(&state), "on")
	testing.expect_value(t, len(state.history.undo), 1)
	testing.expect_value(t, state.history.undo[0].label, "Show collision shapes")
	sendTo(&state, Action.Undo)
	testing.expect(t, !state.project.physics.debugDraw, "undone")

	// Playing with the link: the game is told at once, and the button shows what it says
	reader, writer, err := os.pipe()
	testing.expect_value(t, err, nil)
	if err != nil do return
	defer os.close(reader)
	state.play.stdin = writer
	defer { os.close(writer); state.play.stdin = nil }
	state.playState = .Playing
	Live_Ingest(&state, `{"type":"stats","fps":60,"frame":16.7,"update":0.5,"physics":0.2,"draw":1.1,"nodes":3,"drawn":2,"paused":false,"shapes":false}`)
	testing.expect(t, state.live.connected && !PhysicsDebug_Shown(&state), "the game hides them")
	sendTo(&state, Action.Toggle_Physics_Debug)
	testing.expect(t, state.project.physics.debugDraw && state.live.shapes && PhysicsDebug_Shown(&state), "shown, in the project and the game")
	testing.expect_value(t, sentLines(reader), "shapes on\n")
	// Stats the game sent before it read that are ignored; then it agrees
	Live_Ingest(&state, `{"type":"stats","paused":false,"shapes":false}`)
	testing.expect(t, PhysicsDebug_Shown(&state), "still shown (a stale line)")
	Live_Ingest(&state, `{"type":"stats","paused":false,"shapes":true}`)
	testing.expect(t, state.live.shapes && !state.live.shapesPending, "the game agrees")

	// F9 in the game hid them: the button follows; a click shows them again, which the project
	// already says (no undo step)
	Live_Ingest(&state, `{"type":"stats","paused":false,"shapes":false}`)
	testing.expect(t, !PhysicsDebug_Shown(&state) && state.project.physics.debugDraw, "hidden in the game only")
	steps := len(state.history.undo)
	sendTo(&state, Action.Toggle_Physics_Debug)
	testing.expect(t, PhysicsDebug_Shown(&state) && state.project.physics.debugDraw, "shown again")
	testing.expect_value(t, len(state.history.undo), steps)
	testing.expect_value(t, sentLines(reader), "shapes on\n")

	// Undoing the toggle hides them in the game too
	sendTo(&state, Action.Undo)
	testing.expect(t, !state.project.physics.debugDraw && !state.live.shapes, "undone, in the game too")
	testing.expect_value(t, sentLines(reader), "shapes off\n")
	sendTo(&state, Action.Redo)
	testing.expect_value(t, sentLines(reader), "shapes on\n")

	// Stopped: the project's setting again
	state.playState = .Stopped
	Live_Reset(&state.live)
	testing.expect(t, PhysicsDebug_Shown(&state), "the project's")
	free_all(context.temp_allocator)
}
