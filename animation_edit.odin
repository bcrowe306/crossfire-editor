package editor

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strings"
import "core:time"
import e "engine:."
import "gui:skald"

/*
The Animation panel's logic (its view is view_animation.odin): the selected AnimatedSprite's
animations, which are named ranges of its sprite sheet's cells (`AnimationDef`), each with a
speed, looping and a play mode, and which one it starts with (`NodeDef.autoplay`).

Edits are `.Node` undo steps (History_Classify). The panel's own state (`AnimEditor`: which
animation is selected, the preview's clock, a half-typed name) isn't undoable.
*/

// The autoplay choice meaning "the first animation" (stored as "")
ANIMATION_FIRST :: "(first)"
// The panel preview's frame rate
ANIMATION_PREVIEW_FPS :: 30

// The Animation panel's state (part of State)
AnimEditor :: struct {
	// The selected animation of the selected node
	selected: int,
	// The preview plays; `clock` is how long it has played the selected animation (seconds)
	playing: bool,
	clock: f64,
	lastTick: time.Tick,
	tickPending: bool,
	// A name being typed that isn't valid yet (owned), in the field `nameId`
	nameId: skald.Widget_ID,
	nameText: string,
}

/*
The selected node, if it's an AnimatedSprite, and its selected animation (the selection clamped
to the list).

Returns:
- The node and animation (nil if there's none), and the animation's index
*/
AnimEdit_Selection :: proc(s: ^State) -> (node: ^NodeDef, animation: ^AnimationDef, index: int) {
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) do return nil, nil, -1
	node = &scene.nodes[s.selectedNode]
	if node.kind != .AnimatedSprite do return nil, nil, -1
	if len(node.animations) == 0 do return node, nil, -1
	index = clamp(s.animEditor.selected, 0, len(node.animations) - 1)
	return node, &node.animations[index], index
}

/*
The cells an animation plays in a sheet of `cells` cells: its start and end, resolved (end -1 is
the last cell) and kept inside the sheet.
*/
AnimationDef_Range :: proc(animation: AnimationDef, cells: int) -> (start, end: int) {
	last := max(cells - 1, 0)
	start = clamp(animation.start, 0, last)
	end = animation.end < 0 ? last : clamp(animation.end, start, last)
	return
}

/*
The cell an animation shows `t` seconds after it starts, as the engine's player steps it: at
`fps`, forward, backward or there and back (PingPong), looping or stopping on its last frame.

Returns:
- The sheet cell
*/
AnimationDef_FrameAt :: proc(animation: AnimationDef, cells: int, t: f64) -> int {
	start, end := AnimationDef_Range(animation, cells)
	count := end - start + 1
	if animation.fps <= 0 || count <= 1 do return animation.playMode == .Reverse ? end : start
	step := int(math.floor(max(t, 0) * f64(animation.fps)))
	switch animation.playMode {
	case .Forward:
		return start + (animation.loop ? step % count : min(step, count - 1))
	case .Reverse:
		return end - (animation.loop ? step % count : min(step, count - 1))
	case .PingPong:
		// start .. end .. start+1: one cycle is 2 * (count - 1) steps
		cycle := 2 * (count - 1)
		at := animation.loop ? step % cycle : min(step, cycle)
		return start + (at < count ? at : cycle - at)
	}
	return start
}

// A name no other animation of the node has: "walk", "walk2", "walk3", ...
AnimEdit_UniqueName :: proc(node: ^NodeDef, base: string) -> string {
	taken :: proc(node: ^NodeDef, name: string) -> bool {
		for a in node.animations do if a.name == name do return true
		return false
	}
	if !taken(node, base) do return strings.clone(base)
	root := strings.trim_right(base, "0123456789")
	for n := 2; ; n += 1 {
		name := fmt.tprintf("%s%d", root, n)
		if !taken(node, name) do return strings.clone(name)
	}
}

// Why a name can't be the selected animation's ("" if it can)
AnimEdit_NameProblem :: proc(node: ^NodeDef, index: int, name: string) -> string {
	if strings.trim_space(name) == "" do return "Give it a name"
	if strings.trim_space(name) != name do return "No spaces at the ends"
	for a, i in node.animations do if i != index && a.name == name do return "Another animation has that name"
	return ""
}

/*
Handles the Animation panel's messages.

Returns:
- A command (the preview's next frame), and whether `m` was one of the panel's messages
*/
AnimEdit_Update :: proc(s: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	ed := &s.animEditor
	node, animation, index := AnimEdit_Selection(s)
	restart :: proc(ed: ^AnimEditor) { ed.clock = 0 }

	#partial switch v in m {
	case Anim_Selected:
		ed.selected = int(v)
		restart(ed)
	case Anim_Added:
		if node == nil do break
		append(&node.animations, AnimationDef{AnimEdit_UniqueName(node, "animation"), 0, -1, e.DEFAULT_SCENE_NODE.fps, true, .Forward})
		ed.selected = len(node.animations) - 1
		restart(ed)
	case Anim_Duplicated:
		if animation == nil do break
		twin := animation^
		twin.name = AnimEdit_UniqueName(node, animation.name)
		inject_at(&node.animations, index + 1, twin)
		ed.selected = index + 1
		restart(ed)
	case Anim_Removed:
		// A sprite keeps one animation
		if animation == nil || len(node.animations) <= 1 do break
		if node.autoplay == animation.name {
			delete(node.autoplay)
			node.autoplay = strings.clone("")
		}
		delete(animation.name)
		ordered_remove(&node.animations, index)
		ed.selected = min(index, len(node.animations) - 1)
		restart(ed)
	case Anim_Moved:
		if animation == nil do break
		to := index + int(v)
		if to < 0 || to >= len(node.animations) do break
		node.animations[index], node.animations[to] = node.animations[to], node.animations[index]
		ed.selected = to
	case Anim_Name_Typed:
		delete(ed.nameText)
		ed.nameId, ed.nameText = v.id, strings.clone(v.text)
		if animation == nil || AnimEdit_NameProblem(node, index, v.text) != "" do break
		// The autoplay setting follows the rename
		if node.autoplay == animation.name {
			delete(node.autoplay)
			node.autoplay = strings.clone(v.text)
		}
		delete(animation.name)
		animation.name = strings.clone(v.text)
	case Anim_Field_Changed:
		if animation == nil do break
		cells := max(node.columns * node.rows, 1)
		start, end := AnimationDef_Range(animation^, cells)
		switch v.field {
		case .Start:
			animation.start = clamp(int(v.value), 0, cells - 1)
			// The end moves along rather than ending up before the start
			animation.end = max(end, animation.start)
		case .End:
			animation.end = clamp(int(v.value), 0, cells - 1)
			animation.start = min(start, animation.end)
		case .FPS:
			animation.fps = clamp(f32(v.value), 0, 120)
		}
	case Anim_Loop_Changed:
		if animation != nil do animation.loop = bool(v)
	case Anim_Mode_Changed:
		if animation == nil do break
		if mode, ok := reflect.enum_from_name(e.AnimationPlayMode, string(v)); ok do animation.playMode = mode
		restart(ed)
	case Anim_Autoplay_Set:
		if animation == nil do break
		delete(node.autoplay)
		node.autoplay = strings.clone(animation.name)
	case Anim_Frame_Clicked:
		if animation == nil do break
		cells := max(node.columns * node.rows, 1)
		frame := clamp(v.frame, 0, cells - 1)
		start, end := AnimationDef_Range(animation^, cells)
		if v.end {
			animation.end = frame
			animation.start = min(start, frame)
		} else {
			animation.start = frame
			animation.end = max(end, frame)
		}
		restart(ed)
	case Anim_Playback_Toggled:
		ed.playing = !ed.playing
		if ed.playing && !ed.tickPending {
			ed.tickPending = true
			ed.lastTick = time.tick_now()
			return skald.cmd_delay(1.0 / ANIMATION_PREVIEW_FPS, Msg(Anim_Tick{})), true
		}
	case Anim_Tick_Requested:
		if ed.tickPending || !ed.playing do break
		ed.tickPending = true
		ed.lastTick = time.tick_now()
		return skald.cmd_delay(1.0 / ANIMATION_PREVIEW_FPS, Msg(Anim_Tick{})), true
	case Anim_Tick:
		now := time.tick_now()
		ed.clock += min(time.duration_seconds(time.tick_diff(ed.lastTick, now)), 0.25)
		ed.lastTick = now
		// Only while it plays and the panel shows an animation; the view asks again when it does
		if !ed.playing || animation == nil || s.bottomTab != .Animation || !s.layout.bottomOpen || !EditorFocused() {
			ed.tickPending = false
			break
		}
		return skald.cmd_delay(1.0 / ANIMATION_PREVIEW_FPS, Msg(Anim_Tick{})), true
	case:
		return {}, false
	}
	return {}, true
}
