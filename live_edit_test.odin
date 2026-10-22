package crossfire_editor

import "core:testing"

// The live view: the game's replies read into State.live (the tree's depths, stats and their
// history, a chosen node's properties), typed values kept, nothing sent without a game

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
the_live_view_reads_the_game :: proc(t: ^testing.T) {
	state := State{project = Project_CreateDemo("build/test_live"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
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
