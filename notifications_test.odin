package crossfire_editor

// Feedback (TODO.md's "UI and UX" round): the toasts' queue and expiry (notifications.odin), the
// Problems tab's gathering (problems.odin) and the undo history's jumps (undo_history.odin).
// Run with: task test

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The demo project in memory (its root `root`), PlayScene open, nothing selected
@(private="file")
feedbackState :: proc(root := "unused") -> State {
	state := State{
		project = Project_CreateTestProject(root),
		browserSelection = {kind = .None},
		currentScene = 1,
		selectedNode = -1,
		busSelection = -1,
		settings = Settings_Default(),
	}
	state.settings.builtInCodeEditor = false
	return state
}

@(private="file")
feedbackSend :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(private="file")
feedbackNode :: proc(scene: ^SceneDef, name: string) -> int {
	for node, i in scene.nodes do if node.name == name do return i
	return -1
}

@(test)
toasts_expire_by_level_and_errors_stay :: proc(t: ^testing.T) {
	n: Notifications
	defer Notifications_Destroy(&n)
	start := time.tick_now()
	info := Notifications_Push(&n, .Info, "Saved", now = start)
	warning := Notifications_Push(&n, .Warning, "No targets", now = start)
	error := Notifications_Push(&n, .Error, "Build failed", .Show_Output, now = start)
	testing.expect_value(t, len(n.toasts), 3)
	testing.expect(t, info != warning && warning != error, "ids are unique")
	// The next deadline is the info toast's
	left, ok := Notifications_NextDeadline(&n, start)
	testing.expect(t, ok)
	testing.expect_value(t, left, TOAST_SECONDS * time.Second)
	// Not yet
	testing.expect(t, !Notifications_Expire(&n, time.tick_add(start, time.Second)))
	// The info toast goes first, then the warning; the error stays
	testing.expect(t, Notifications_Expire(&n, time.tick_add(start, TOAST_SECONDS * time.Second)))
	testing.expect_value(t, len(n.toasts), 2)
	testing.expect_value(t, n.toasts[0].text, "No targets")
	Notifications_Expire(&n, time.tick_add(start, time.Hour))
	testing.expect_value(t, len(n.toasts), 1)
	testing.expect_value(t, n.toasts[0].action, ToastAction.Show_Output)
	_, ok = Notifications_NextDeadline(&n, start)
	testing.expect(t, !ok, "an error has no deadline")
	// Dismissed by its id
	testing.expect(t, Notifications_Dismiss(&n, error))
	testing.expect(t, !Notifications_Dismiss(&n, error))
	testing.expect_value(t, len(n.toasts), 0)
}

@(test)
toasts_keep_the_errors_when_too_many :: proc(t: ^testing.T) {
	n: Notifications
	defer Notifications_Destroy(&n)
	Notifications_Push(&n, .Error, "first error")
	for _ in 0 ..< TOAST_MAX do Notifications_Push(&n, .Info, "info")
	testing.expect_value(t, len(n.toasts), TOAST_MAX)
	testing.expect_value(t, n.toasts[0].text, "first error")
	// All errors: the oldest goes
	for i in 0 ..< TOAST_MAX do Notifications_Push(&n, .Error, i == TOAST_MAX - 1 ? "last" : "error")
	testing.expect_value(t, len(n.toasts), TOAST_MAX)
	testing.expect_value(t, n.toasts[TOAST_MAX - 1].text, "last")
}

@(test)
toast_messages_dismiss_and_run_actions :: proc(t: ^testing.T) {
	state := feedbackState()
	defer State_Destroy(&state)
	feedbackSend(&state, Notify_Requested{.Error, .Show_Problems, "Building the scripts failed"})
	testing.expect_value(t, len(state.notifications.toasts), 1)
	id := state.notifications.toasts[0].id
	feedbackSend(&state, Toast_Action_Clicked(id))
	testing.expect_value(t, len(state.notifications.toasts), 0)
	testing.expect_value(t, Mode_BottomTab(&state), BottomTab.Problems)
	testing.expect(t, state.problems.gathered, "Show Problems checks the project")
	feedbackSend(&state, Notify_Requested{.Info, .None, "hello"})
	feedbackSend(&state, Toast_Dismissed(state.notifications.toasts[0].id))
	testing.expect_value(t, len(state.notifications.toasts), 0)
}

@(test)
jobs_remember_how_long_they_took :: proc(t: ^testing.T) {
	n: Notifications
	start := time.tick_now()
	testing.expect_value(t, Notifications_Follow(&n, {.Play_Build}, start), bit_set[ToastJob]{})
	ended := Notifications_Follow(&n, {}, time.tick_add(start, 10 * time.Second))
	testing.expect_value(t, ended, bit_set[ToastJob]{.Play_Build})
	testing.expect_value(t, n.lastTook[.Play_Build], 10 * time.Second)
}

@(test)
problems_gather_missing_assets_broken_paths_and_errors :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_problems"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	os.make_directory(joinPath(dir, "assets", allocator = context.temp_allocator))
	testing.expect(t, os.write_entire_file(joinPath(dir, "assets/ship.png", allocator = context.temp_allocator), transmute([]byte)string("png")) == nil)
	state := feedbackState(dir)
	defer State_Destroy(&state)
	scene := &state.project.scenes[1]
	camera := feedbackNode(scene, "Camera")
	delete(scene.nodes[camera].cameraTarget)
	scene.nodes[camera].cameraTarget = strings.clone("Nowhere")
	outputLine(&state, .Error, strings.clone("/game/scripts/hero.odin(12:5) Error: Undeclared name: speed"))

	Problems_Gather(&state)
	testing.expect(t, state.problems.gathered)
	missingShip, missingLight, brokenCamera, scriptError := -1, -1, -1, -1
	for p, i in state.problems.items {
		if p.kind == .Missing_Asset && p.asset == "assets/ship.png" do missingShip = i
		if p.kind == .Missing_Asset && p.asset == "assets/light.png" && strings.has_suffix(p.place, "ShipLight") do missingLight = i
		if p.kind == .Broken_Node_Path && p.node == camera do brokenCamera = i
		if p.kind == .Script_Error do scriptError = i
	}
	testing.expect_value(t, missingShip, -1)
	testing.expect(t, missingLight >= 0, "a sheet that isn't on disk is missing")
	testing.expect(t, brokenCamera >= 0, "the camera's target leads nowhere")
	testing.expect(t, scriptError >= 0, "the build's error is a problem")
	if missingLight >= 0 {
		testing.expect_value(t, state.problems.items[missingLight].place, "PlayScene > World > Spaceship > ShipLight")
	}
	if scriptError >= 0 {
		p := state.problems.items[scriptError]
		testing.expect_value(t, p.text, "Error: Undeclared name: speed")
		testing.expect_value(t, p.line, 12)
		testing.expect_value(t, p.column, 4)
	}
	if brokenCamera >= 0 {
		testing.expect(t, strings.contains(state.problems.items[brokenCamera].text, "\"Nowhere\""))
		// A click selects the camera
		feedbackSend(&state, Problem_Picked(brokenCamera))
		testing.expect_value(t, state.selectedNode, camera)
		testing.expect_value(t, state.problems.selected, brokenCamera)
	}
	// Fixed, then checked again: gone
	delete(scene.nodes[camera].cameraTarget)
	scene.nodes[camera].cameraTarget = strings.clone("/World/Spaceship")
	feedbackSend(&state, Problems_Refresh{})
	for p in state.problems.items do testing.expect(t, p.kind != .Broken_Node_Path, "the path leads to the ship now")
}

@(test)
undo_history_jumps_to_a_step :: proc(t: ^testing.T) {
	state := feedbackState()
	defer State_Destroy(&state)
	scene := &state.project.scenes[1]
	ship := feedbackNode(scene, "Spaceship")
	feedbackSend(&state, Node_Picked(ship))
	for name in ([]string{"A", "B", "C"}) {
		feedbackSend(&state, Node_Renamed(name))
		// Each rename its own step (they'd merge within undoMergeMs)
		if len(state.history.undo) > 0 do state.history.undo[len(state.history.undo) - 1].mergeKey = 0
	}
	testing.expect_value(t, len(state.history.undo), 3)
	testing.expect_value(t, scene.nodes[ship].name, "C")
	// Back to the first step
	feedbackSend(&state, History_Jump(1))
	testing.expect_value(t, len(state.history.undo), 1)
	testing.expect_value(t, len(state.history.redo), 2)
	testing.expect_value(t, scene.nodes[ship].name, "A")
	// Forward to the last
	feedbackSend(&state, History_Jump(3))
	testing.expect_value(t, scene.nodes[ship].name, "C")
	// To the opened project, and past the end (clamped)
	testing.expect_value(t, History_JumpTo(&state, 0), -3)
	testing.expect_value(t, scene.nodes[ship].name, "Spaceship")
	testing.expect_value(t, History_JumpTo(&state, 99), 3)
	testing.expect_value(t, scene.nodes[ship].name, "C")
}
