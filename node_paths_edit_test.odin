package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"
import e "engine:."

// Every stored node path follows renames and moves (node_paths_edit.odin), and a rename that
// changes them is one undo step

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
node_paths_follow_renames_and_moves :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_node_paths"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)

	// A built script with two node fields: one stored, one left at its default
	fields := make([dynamic]ScriptFieldDesc)
	append(&fields, ScriptFieldDesc{name = strings.clone("sword"), type = .Node, defaultValue = strings.clone(""), hint = strings.clone("Node")})
	append(&fields, ScriptFieldDesc{name = strings.clone("camera"), type = .Node, defaultValue = strings.clone("../Cam"), hint = strings.clone("Camera2D")})
	append(&fields, ScriptFieldDesc{name = strings.clone("label"), type = .String, defaultValue = strings.clone("Hero"), hint = strings.clone("")})
	append(&state.scripts.scripts, ScriptDesc{name = strings.clone("Hero"), fields = fields})
	state.scripts.status = .Ready

	scene := &state.project.scenes[0]
	level := Scene_InsertNode(scene, "Level", .Node2D, -1)
	hero := Scene_InsertNode(scene, "Hero", .Sprite, level)
	sword := Scene_InsertNode(scene, "Sword", .Sprite, hero)
	cam := Scene_InsertNode(scene, "Cam", .Camera, level)
	view := Scene_InsertNode(scene, "View", .CameraView, level)
	ik := Scene_InsertNode(scene, "Arm", .IKChain, level)
	machine := Scene_InsertNode(scene, "Brain", .StateMachine, level)
	mesh := Scene_InsertNode(scene, "Skin", .SkinnedMesh, level)
	animator := Scene_InsertNode(scene, "Anim", .Animator, level)
	nodeAt :: proc(state: ^State, i: int) -> ^NodeDef { return &state.project.scenes[0].nodes[i] }
	set :: proc(text: ^string, value: string) { delete(text^); text^ = strings.clone(value) }

	h := nodeAt(&state, hero)
	set(&h.script, "Hero")
	append(&h.props, ScriptPropDef{strings.clone("sword"), strings.clone("Sword")})
	append(&h.props, ScriptPropDef{strings.clone("label"), strings.clone("Level")}) // not a node field: never touched
	append(&h.listeners, e.NodeListenerData{strings.clone("onEnter"), strings.clone("../Cam"), strings.clone("onCamEnter"), strings.clone("")})
	set(&nodeAt(&state, cam).cameraTarget, "../Hero")
	set(&nodeAt(&state, view).viewCamera, "../Cam")
	set(&nodeAt(&state, ik).ikTip, "../Hero/Sword")
	set(&nodeAt(&state, ik).ikTarget, "/Level/Hero") // from the top level: stays that way
	set(&nodeAt(&state, machine).stateMachine.target, "../Hero")
	append(&nodeAt(&state, mesh).mesh.bones, strings.clone("../Hero/Sword"))
	tracks := make([dynamic]e.AnimatorTrackData)
	append(&tracks, e.AnimatorTrackData{node = strings.clone("Hero"), property = strings.clone("position")})
	append(&tracks, e.AnimatorTrackData{node = strings.clone(""), property = strings.clone("event")})
	append(&nodeAt(&state, animator).animator.clips, e.AnimatorClipData{name = strings.clone("walk"), length = 1, tracks = tracks})

	refs := NodePaths_Resolve(scene, &state.scripts)
	// camera, view, tip, target, machine, bone, track, listener, sword, camera field (not the event track, not label)
	testing.expect_value(t, len(refs), 10)
	testing.expect(t, Scene_HasNodePaths(scene, &state.scripts), "has paths")
	testing.expect(t, !Scene_HasNodePaths(&SceneDef{}), "an empty scene has none")

	expectAll :: proc(t: ^testing.T, state: ^State, heroPath, swordPath, camPath, levelName: string, loc := #caller_location) {
		scene := &state.project.scenes[0]
		find :: proc(scene: ^SceneDef, kind: NodeKind) -> ^NodeDef {
			for &n in scene.nodes do if n.kind == kind do return &n
			return nil
		}
		hero: ^NodeDef
		for &n in scene.nodes do if n.script == "Hero" do hero = &n
		testing.expect_value(t, find(scene, .Camera).cameraTarget, heroPath, loc = loc)
		testing.expect_value(t, find(scene, .CameraView).viewCamera, camPath, loc = loc)
		testing.expect_value(t, find(scene, .IKChain).ikTip, swordPath, loc = loc)
		testing.expect_value(t, find(scene, .StateMachine).stateMachine.target, heroPath, loc = loc)
		testing.expect_value(t, find(scene, .SkinnedMesh).mesh.bones[0], swordPath, loc = loc)
		testing.expect_value(t, Props_Value(hero.props[:], "label", ""), "Level", loc = loc)
		testing.expect_value(t, find(scene, .Animator).animator.clips[0].tracks[1].node, "", loc = loc)
		_ = levelName
	}

	// Renaming the hero: every path to it (and through it) follows; one .Scene undo step
	state.selectedNode = hero
	sendTo(&state, Node_Renamed("Player"))
	expectAll(t, &state, "../Player", "../Player/Sword", "../Cam", "Level")
	testing.expect_value(t, nodeAt(&state, ik).ikTarget, "/Level/Player")
	testing.expect_value(t, nodeAt(&state, animator).animator.clips[0].tracks[0].node, "Player")
	testing.expect_value(t, Props_Value(nodeAt(&state, hero).props[:], "sword", ""), "Sword")
	sendTo(&state, Action.Undo)
	expectAll(t, &state, "../Hero", "../Hero/Sword", "../Cam", "Level")
	testing.expect_value(t, nodeAt(&state, ik).ikTarget, "/Level/Hero")
	testing.expect_value(t, nodeAt(&state, hero).name, "Hero")
	sendTo(&state, Action.Redo)
	testing.expect_value(t, nodeAt(&state, hero).name, "Player")

	// Renaming the camera: the view, the listener and the script's default-valued field follow (the
	// field gets a value of its own)
	state.selectedNode = cam
	sendTo(&state, Node_Renamed("MainCam"))
	expectAll(t, &state, "../Player", "../Player/Sword", "../MainCam", "Level")
	testing.expect_value(t, nodeAt(&state, hero).listeners[0].target, "../MainCam")
	testing.expect_value(t, Props_Value(nodeAt(&state, hero).props[:], "camera", "../Cam"), "../MainCam")

	// Renaming the sword: the script's stored field follows
	state.selectedNode = sword
	sendTo(&state, Node_Renamed("Blade"))
	testing.expect_value(t, Props_Value(nodeAt(&state, hero).props[:], "sword", ""), "Blade")
	testing.expect_value(t, nodeAt(&state, ik).ikTip, "../Player/Blade")

	// Moving the hero to the top level: paths from its old siblings now go up and over
	scene = &state.project.scenes[0]
	_, ok := Scene_MoveNode(scene, hero, -1, .After, &state.scripts)
	testing.expect(t, ok, "moved")
	expectAll(t, &state, "../../Player", "../../Player/Blade", "../MainCam", "Level")
	testing.expect_value(t, scene.nodes[nodeIndex(scene, "Arm")].ikTarget, "/Player")
	testing.expect_value(t, scene.nodes[nodeIndex(scene, "Anim")].animator.clips[0].tracks[0].node, "../Player")
	player := nodeIndex(scene, "Player")
	testing.expect_value(t, Props_Value(scene.nodes[player].props[:], "camera", ""), "../Level/MainCam")
	testing.expect_value(t, scene.nodes[player].listeners[0].target, "../Level/MainCam")
	testing.expect_value(t, Props_Value(scene.nodes[player].props[:], "sword", ""), "Blade")

	// Without the catalog script fields are left alone; the rest still follow
	refs = NodePaths_Resolve(scene, nil)
	testing.expect_value(t, len(refs), 8)

	// A path that leads nowhere is left as written
	set(&scene.nodes[nodeIndex(scene, "View")].viewCamera, "../Nobody")
	state.selectedNode = nodeIndex(scene, "Level")
	sendTo(&state, Node_Renamed("Stage"))
	scene = &state.project.scenes[0]
	testing.expect_value(t, scene.nodes[nodeIndex(scene, "View")].viewCamera, "../Nobody")
	testing.expect_value(t, scene.nodes[nodeIndex(scene, "Arm")].ikTarget, "/Player")
	testing.expect_value(t, Props_Value(scene.nodes[nodeIndex(scene, "Player")].props[:], "camera", ""), "../Stage/MainCam")
	free_all(context.temp_allocator)
}

// The index of the scene's node with a name, or -1
@(private="file")
nodeIndex :: proc(scene: ^SceneDef, name: string) -> int {
	for n, i in scene.nodes do if n.name == name do return i
	return -1
}
