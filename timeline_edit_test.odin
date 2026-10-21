package crossfire_editor

import "core:os"
import "core:sync"
import "core:testing"
import e "engine:."

// The Timeline: an Animator's clips made, keyed from the scene, undone, saved, read back and
// shown in the viewport at the playhead

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
animators_are_edited_in_the_timeline :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer Preview_Destroy()
	os.make_directory("build")
	dir := "build/test_timeline"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(), timeline = {node = -1, track = -1, key = -1}}
	state.settings.builtInCodeEditor = false
	defer State_Destroy(&state)
	scene := &state.project.scenes[0]
	box := Scene_InsertNode(scene, "Box", .Label, 0)
	anim := Scene_InsertNode(scene, "Anim", .Animator, 0)
	testing.expect(t, scene.nodes[box].parent == 0 && scene.nodes[anim].parent == 0, "siblings under World")
	animator :: proc(state: ^State, at: int) -> ^e.AnimatorSettings { return &state.project.scenes[0].nodes[at].animator }

	// Paths are from the Animator's parent, as the engine reads them
	testing.expect_value(t, Timeline_PathTo(scene, anim, box, context.temp_allocator), "Box")
	testing.expect_value(t, Timeline_PathTo(scene, anim, 0, context.temp_allocator), ".")
	testing.expect_value(t, Timeline_ResolvePath(scene, anim, "Box"), box)
	testing.expect_value(t, Timeline_ResolvePath(scene, anim, ""), 0)
	testing.expect_value(t, Timeline_ResolvePath(scene, anim, "/World/Box"), box)
	testing.expect_value(t, Timeline_ResolvePath(scene, anim, "Nothing"), -1)
	properties := Timeline_Properties(&state, &scene.nodes[box], context.temp_allocator)
	hasText := false
	for p in properties do if p == "text" do hasText = true
	testing.expect(t, hasText, "a Label's text can be animated")

	// Selecting the Animator puts it in the Timeline; selecting another node keeps it there
	state.selectedNode = anim
	sendTo(&state, Bottom_Tab_Changed(int(BottomTab.Timeline)))
	node, index := Timeline_Animator(&state)
	testing.expect(t, node != nil && index == anim, "the Timeline shows the Animator")
	sendTo(&state, Timeline_Changed{op = .Clip_Added})
	testing.expect(t, len(animator(&state, anim).clips) == 1 && animator(&state, anim).clips[0].name == "clip", "a clip")
	state.selectedNode = box
	sendTo(&state, Frame_Requested{})
	_, index = Timeline_Animator(&state)
	testing.expect_value(t, index, anim)

	// A track: its first key is the node's value now, at the playhead
	scene = &state.project.scenes[0]
	scene.nodes[box].position = {10, 20}
	sendTo(&state, Timeline_Changed{op = .Track_Added, path = "Box", text = "position"})
	clip := &animator(&state, anim).clips[0]
	testing.expect(t, len(clip.tracks) == 1 && clip.tracks[0].node == "Box" && len(clip.tracks[0].keys) == 1, "a track with a key")
	testing.expect_value(t, clip.tracks[0].keys[0].value, "10, 20")
	// Move the node, move the playhead, Key
	sendTo(&state, Timeline_View{op = .Scrubbed, number = 1})
	state.project.scenes[0].nodes[box].position = {110, 20}
	sendTo(&state, Timeline_Changed{op = .Key_Added})
	clip = &animator(&state, anim).clips[0]
	testing.expect(t, len(clip.tracks[0].keys) == 2 && clip.tracks[0].keys[1].time == 1 && clip.tracks[0].keys[1].value == "110, 20", "keyed at 1 s")
	// Undo takes the key back (the Animator's step, though the Box is selected)
	sendTo(&state, Action.Undo)
	testing.expect_value(t, len(animator(&state, anim).clips[0].tracks[0].keys), 1)
	sendTo(&state, Action.Redo)
	testing.expect_value(t, len(animator(&state, anim).clips[0].tracks[0].keys), 2)

	// Dragging a key is one step; keys stay in order
	sendTo(&state, Timeline_View{op = .Key_Selected, index = 0, other = 1})
	sendTo(&state, Timeline_View{op = .Drag_Begin})
	sendTo(&state, Timeline_Changed{op = .Key_Moved, number = 0.8})
	sendTo(&state, Timeline_Changed{op = .Key_Moved, number = 0.5})
	sendTo(&state, Timeline_View{op = .Drag_End})
	clip = &animator(&state, anim).clips[0]
	testing.expect_value(t, clip.tracks[0].keys[1].time, f32(0.5))
	sendTo(&state, Action.Undo)
	testing.expect_value(t, animator(&state, anim).clips[0].tracks[0].keys[1].time, f32(1))
	sendTo(&state, Action.Redo)
	sendTo(&state, Timeline_View{op = .Key_Selected, index = 0, other = 0})
	sendTo(&state, Timeline_Changed{op = .Key_Ease, text = "InOutQuad"})
	testing.expect_value(t, animator(&state, anim).clips[0].tracks[0].keys[0].ease, e.EaseType.InOutQuad)
	sendTo(&state, Timeline_Changed{op = .Key_Ease, text = "Linear"})

	// An event track: its keys are names
	sendTo(&state, Timeline_View{op = .Scrubbed, number = 0.25})
	sendTo(&state, Timeline_Changed{op = .Track_Added, text = e.ANIMATOR_EVENT_PROPERTY})
	clip = &animator(&state, anim).clips[0]
	testing.expect(t, len(clip.tracks) == 2 && clip.tracks[1].keys[0].value == "event1" && clip.tracks[1].keys[0].time == 0.25, "an event key")
	sendTo(&state, Timeline_Changed{op = .Key_Value, text = "  footstep "})
	testing.expect_value(t, animator(&state, anim).clips[0].tracks[1].keys[0].value, "footstep")

	// Names: typed until valid; the clip it starts with follows a rename
	sendTo(&state, Timeline_Changed{op = .Clip_Autoplay, flag = true})
	testing.expect_value(t, animator(&state, anim).autoplay, "clip")
	sendTo(&state, Timeline_View{op = .Name_Typed, text = ""})
	testing.expect_value(t, state.timeline.nameEdit, "")
	testing.expect_value(t, animator(&state, anim).clips[0].name, "clip")
	sendTo(&state, Timeline_View{op = .Name_Typed, text = "slide"})
	testing.expect(t, animator(&state, anim).clips[0].name == "slide" && animator(&state, anim).autoplay == "slide", "renamed")
	sendTo(&state, Timeline_Changed{op = .Clip_Length, number = 2})
	sendTo(&state, Timeline_Changed{op = .Clip_Loop, flag = true})

	// The viewport shows the clip at the playhead (halfway between the keys at 0 and 0.5)
	sendTo(&state, Timeline_View{op = .Scrubbed, number = 0.25})
	testing.expect(t, state.timeline.previewing, "previewing")
	_, ok := Preview_Render(&state, {64, 64}, 1)
	testing.expect(t, ok, "rendered")
	built := Preview_Node(box)
	testing.expect(t, built != nil, "the Box is built")
	if built != nil do testing.expect_value(t, built.position, [2]f32{60, 20})
	// An edit of a node shows the scene as it is again
	sendTo(&state, Node_Field_Changed{.Position_X, 5})
	testing.expect(t, !state.timeline.previewing, "not previewing after an edit")
	Preview_Render(&state, {64, 64}, 1)
	built = Preview_Node(box)
	if built != nil do testing.expect_value(t, built.position, [2]f32{5, 20})

	// Saved and read back the same
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	at := -1
	for n, i in loaded.scenes[0].nodes do if n.kind == .Animator do at = i
	testing.expect(t, at >= 0, "an Animator")
	if at >= 0 do testing.expect(t, e.AnimatorSettings_Equal(loaded.scenes[0].nodes[at].animator, animator(&state, anim)^), "the same clips")

	// Removing: tracks, keys, the clip (and the clip it starts with goes too)
	sendTo(&state, Timeline_View{op = .Key_Selected, index = 1, other = 0})
	sendTo(&state, Timeline_Changed{op = .Key_Removed})
	testing.expect_value(t, len(animator(&state, anim).clips[0].tracks[1].keys), 0)
	sendTo(&state, Timeline_Changed{op = .Track_Removed})
	testing.expect_value(t, len(animator(&state, anim).clips[0].tracks), 1)
	sendTo(&state, Timeline_Changed{op = .Clip_Removed})
	testing.expect(t, len(animator(&state, anim).clips) == 0 && animator(&state, anim).autoplay == "", "no clips")
	free_all(context.temp_allocator)
}
