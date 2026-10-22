package crossfire_editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "core:time"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
The Timeline: editing an Animator node's keyframe clips (the engine's animator.odin) in the
bottom panel's **Timeline** tab (view_timeline.odin).

- **Which Animator:** the selected one; selecting another node keeps the last Animator selected
  in the scene (`TimelineEditor.node`), so its targets can be selected and moved while its
  timeline stays.
- **Data:** `NodeDef.animator` is the engine's `e.AnimatorSettings` (owned: `e.AnimatorSettings_Clone`,
  `_Destroy`, `_Equal`). Every edit is one message, `Timeline_Changed{op, ...}`, a node step on the
  Animator (dragging a key is one sticky step); `Timeline_View` changes only the panel (the
  clip shown, the playhead, the selection, the new track's choices).
- **Tracks** name their node by a path from the Animator's parent (`Scene_NodePath`, read back by
  `Timeline_ResolvePath` as the engine does), so keep the Animator inside what it animates.
- **Keys** record a node's value as it is in the scene (`Timeline_NodeValue`): move a node, then
  Key. The viewport shows the clip at the playhead while scrubbing or playing
  (`TimelineEditor.previewing`), until the next edit of a node.
*/

// The Timeline's own state (not undone): what it shows and what's selected
TimelineEditor :: struct {
	// The Animator edited: its scene and node index (-1: none)
	scene, node: int,
	// The clip shown
	clip: int,
	// The playhead, in seconds
	playhead: f32,
	// Playing the clip in the viewport
	playing: bool,
	tickPending: bool,
	lastTick: time.Tick,
	// The viewport shows the clip at the playhead (scrubbing, playing); a node edit ends it
	previewing: bool,
	// The selected track and key (-1: none)
	track, key: int,
	// The new track's node (a path from the Animator's parent) and property (heap)
	newNode, newProperty: string,
	// A clip name typed that isn't valid yet (heap; "" when none)
	nameEdit: string,
	// A key is being dragged along the timeline
	dragging: bool,
	// The ruler is being dragged (scrubbing)
	scrubbing: bool,
}

// What a `Timeline_Changed` edits
TimelineOp :: enum {
	Clip_Added,
	Clip_Removed,
	Clip_Renamed,
	Clip_Length,
	Clip_Loop,
	// The clip shown becomes (flag) or stops being the one it starts with
	Clip_Autoplay,
	// The clip it starts with, by name (text; "": none)
	Autoplay_Named,
	Speed,
	// A track for the node at `path` and the property `text` ("event": an event track)
	Track_Added,
	Track_Removed,
	Track_Step,
	// A key on the selected track at the playhead, from its node's value (or "event")
	Key_Added,
	// A key on every track at the playhead
	Keys_Recorded,
	Key_Removed,
	Key_Time,
	// Dragging the selected key (number: its new time); sticky, one step per drag
	Key_Moved,
	Key_Value,
	Key_Ease,
}

// An edit of the Animator's clips (an undo step)
Timeline_Changed :: struct {
	op: TimelineOp,
	text: string,
	// Track_Added: the node's path
	path: string,
	number: f32,
	flag: bool,
}

// What a `Timeline_View` changes
TimelineViewOp :: enum {
	// index: the clip
	Clip_Chosen,
	// number: the playhead's time
	Scrubbed,
	Play_Toggled,
	Rewound,
	// index: the track
	Track_Selected,
	// index: the track, other: the key
	Key_Selected,
	// text: the new track's node path
	New_Node_Chosen,
	// text: the new track's property
	New_Property_Chosen,
	// A key drag starts (bumps the gesture, so the drag is one step) and ends
	Drag_Begin,
	Drag_End,
	Scrub_Begin,
	Scrub_End,
	// text: a clip name being typed
	Name_Typed,
}

// A change to the Timeline panel only (not undone)
Timeline_View :: struct {
	op: TimelineViewOp,
	text: string,
	number: f32,
	index, other: int,
}

// The Timeline's playback clock
Timeline_Tick :: struct {}

// A key on the selected track at a time (seconds; the playhead moves there): a track's context menu
Timeline_Key_Here :: distinct f32
Timeline_Tick_Requested :: struct {}

// The Timeline's number fields
TimelineNumber :: enum {
	Length,
	Speed,
	Key_Time,
}

/*
Whether a message edits the Timeline's Animator (its clips, through the panel).

Inputs:
- m: The message

Returns:
- true for the Timeline's edits
*/
Timeline_IsEdit :: proc(m: Msg) -> bool {
	#partial switch v in m {
	case Timeline_Changed, Timeline_Key_Here: return true
	case Timeline_View: return v.op == .Name_Typed
	case Number_Text_Changed:
		_, isTimeline := v.target.(TimelineNumber)
		return isTimeline
	}
	return false
}

// Frames a second the Timeline plays at in the viewport
TIMELINE_FPS :: 30

// Key times snap to this (seconds) while dragging; Shift drags freely
TIMELINE_SNAP :: 0.05

/*
The Animator the Timeline edits: the stored one when it's still an Animator of the open scene.

Inputs:
- s: The state

Returns:
- The node and its index, or nil and -1
*/
Timeline_Animator :: proc(s: ^State) -> (^NodeDef, int) {
	t := &s.timeline
	if t.scene != s.currentScene || s.currentScene < 0 || s.currentScene >= len(s.project.scenes) do return nil, -1
	scene := &s.project.scenes[s.currentScene]
	if t.node < 0 || t.node >= len(scene.nodes) || scene.nodes[t.node].kind != .Animator do return nil, -1
	return &scene.nodes[t.node], t.node
}

/*
The clip the Timeline shows.

Inputs:
- s: The state

Returns:
- The clip, or nil when the Animator has none (or there's no Animator)
*/
Timeline_Clip :: proc(s: ^State) -> ^e.AnimatorClipData {
	node, _ := Timeline_Animator(s)
	if node == nil || len(node.animator.clips) == 0 do return nil
	return &node.animator.clips[clamp(s.timeline.clip, 0, len(node.animator.clips) - 1)]
}

/*
Keeps the Timeline on the selected Animator, and its choices in range: after every message.

Inputs:
- s: The state
*/
Timeline_Follow :: proc(s: ^State) {
	t := &s.timeline
	if s.currentScene >= 0 && s.currentScene < len(s.project.scenes) {
		scene := &s.project.scenes[s.currentScene]
		if s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) && scene.nodes[s.selectedNode].kind == .Animator {
			if t.node != s.selectedNode || t.scene != s.currentScene {
				t.node, t.scene = s.selectedNode, s.currentScene
				t.clip, t.playhead, t.track, t.key, t.playing = 0, 0, -1, -1, false
			}
		}
	}
	node, _ := Timeline_Animator(s)
	if node == nil {
		t.playing, t.previewing = false, false
		return
	}
	t.clip = clamp(t.clip, 0, max(len(node.animator.clips) - 1, 0))
	clip := Timeline_Clip(s)
	if clip == nil {
		t.track, t.key = -1, -1
		return
	}
	if t.track >= len(clip.tracks) do t.track = len(clip.tracks) - 1
	if t.track < 0 || t.key >= len(clip.tracks[t.track].keys) do t.key = -1
	t.playhead = clamp(t.playhead, 0, clip.length)
}

/*
The node a track's path leads to, read as the engine reads it: from the Animator's parent ("" or
"." the parent itself, a leading "/" from the top level).

Inputs:
- scene: The scene
- animator: The Animator's index
- path: The track's path

Returns:
- The node's index, or -1
*/
Timeline_ResolvePath :: proc(scene: ^SceneDef, animator: int, path: string) -> int {
	path := strings.trim_space(path)
	at := scene.nodes[animator].parent
	atRoot := at < 0
	if strings.has_prefix(path, "/") {
		at, atRoot = -1, true
		path = path[1:]
	}
	if path == "" || path == "." do return atRoot ? -1 : at
	rest := path
	for part in strings.split_iterator(&rest, "/") {
		switch part {
		case "", ".":
			continue
		case "..":
			if atRoot do return -1
			at = scene.nodes[at].parent
			atRoot = at < 0
		case:
			next := -1
			for node, i in scene.nodes do if node.parent == at && node.name == part {
				next = i
				break
			}
			if next < 0 do return -1
			at, atRoot = next, false
		}
	}
	return atRoot ? -1 : at
}

/*
The path a track uses for a node: from the Animator's parent ("." for the parent itself).

Inputs:
- scene: The scene
- animator: The Animator's index
- target: The node
- allocator: For the text

Returns:
- The path
*/
Timeline_PathTo :: proc(scene: ^SceneDef, animator, target: int, allocator := context.allocator) -> string {
	return Scene_NodePath(scene, scene.nodes[animator].parent, target, allocator)
}

/*
The properties a node's tracks can animate: the engine's built-in ones its kind has, then its
script's fields (once built).

Inputs:
- s: The state
- node: The node
- allocator: For the list

Returns:
- Property names ("position", "script.speed")
*/
Timeline_Properties :: proc(s: ^State, node: ^NodeDef, allocator := context.allocator) -> []string {
	list := make([dynamic]string, allocator)
	type := e.SCENE_NODE_TYPES[NodeDef_BuiltKind(&s.project, node)]
	for p in e.ANIMATOR_PROPERTIES do if e.Animator_TypeHasProperty(type, p) do append(&list, p.name)
	// Every script's fields (its node type's, its scripts'), once each
	for code in NodeDef_Codes(s, node) do if code.desc != nil {
		for f in code.desc.fields do if _, ok := e.Animator_ScriptFieldKind(f.type); ok {
			name := fmt.aprintf("%s%s", e.ANIMATOR_SCRIPT_PREFIX, f.name, allocator = allocator)
			if slice.contains(list[:], name) {
				delete(name, allocator)
				continue
			}
			append(&list, name)
		}
	}
	return list[:]
}

/*
A property's name as the Timeline shows it ("Position X", "speed (script)").

Inputs:
- property: The property

Returns:
- Its label (temp allocated when made)
*/
Timeline_PropertyLabel :: proc(property: string) -> string {
	if property == e.ANIMATOR_EVENT_PROPERTY do return "Events"
	for p in e.ANIMATOR_PROPERTIES do if p.name == property do return p.label
	if strings.has_prefix(property, e.ANIMATOR_SCRIPT_PREFIX) do return fmt.tprintf("%s (script)", property[len(e.ANIMATOR_SCRIPT_PREFIX):])
	return property
}

/*
A node's value of a property as it is in the scene, as key text: what Key records.

Inputs:
- s: The state
- node: The node
- property: The property
- allocator: For the text

Returns:
- The text, and false when the node has no such property
*/
Timeline_NodeValue :: proc(s: ^State, node: ^NodeDef, property: string, allocator := context.allocator) -> (string, bool) {
	value: e.AnimatorValue
	switch property {
	case "position": value = node.position
	case "position.x": value = node.position.x
	case "position.y": value = node.position.y
	case "rotation": value = node.rotation
	case "scale": value = node.scale
	case "scale.x": value = node.scale.x
	case "scale.y": value = node.scale.y
	// Nodes in scene files have no tint: white, opaque
	case "tint": value = sdl.Color{255, 255, 255, 255}
	case "opacity": value = f32(1)
	case "visible": value = node.visible
	case "zIndex": value = f32(node.zIndex)
	case "animation":
		name := node.autoplay
		if name == "" && len(node.animations) > 0 do name = node.animations[0].name
		value = name
	case "text": value = node.text
	case "color": value = node.color
	case:
		if !strings.has_prefix(property, e.ANIMATOR_SCRIPT_PREFIX) do return "", false
		field := property[len(e.ANIMATOR_SCRIPT_PREFIX):]
		// The first code with the field (the engine's order), its value or its default
		for code in NodeDef_Codes(s, node) {
			for p in code.props do if p.name == field do return strings.clone(p.value, allocator), true
			if code.desc != nil {
				for f in code.desc.fields do if f.name == field do return strings.clone(f.defaultValue, allocator), true
			}
		}
		return "", false
	}
	return e.Animator_FormatValue(value, allocator), true
}

/*
Handles the Timeline's messages.

Inputs:
- s: The state
- m: The message

Returns:
- A command, and whether the message was the Timeline's
*/
Timeline_Update :: proc(s: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	t := &s.timeline
	#partial switch v in m {
	case Timeline_Changed:
		timelineEdit(s, v)
		t.previewing = true
		if clip := Timeline_Clip(s); clip != nil do previewAt(s)
	case Timeline_Key_Here:
		t.playhead = max(f32(v), 0)
		timelineEdit(s, Timeline_Changed{op = .Key_Added})
		t.previewing = true
		if clip := Timeline_Clip(s); clip != nil do previewAt(s)
	case Timeline_View:
		return timelineView(s, v), true
	case Timeline_Tick_Requested:
		if t.tickPending || !t.playing do break
		t.tickPending = true
		t.lastTick = time.tick_now()
		return skald.cmd_delay(1.0 / TIMELINE_FPS, Msg(Timeline_Tick{})), true
	case Timeline_Tick:
		now := time.tick_now()
		step := f32(min(time.duration_seconds(time.tick_diff(t.lastTick, now)), 0.25))
		t.lastTick = now
		clip := Timeline_Clip(s)
		node, _ := Timeline_Animator(s)
		if !t.playing || clip == nil || s.bottomTab != .Timeline || !s.layout.bottomOpen || !EditorFocused() {
			t.tickPending = false
			break
		}
		speed := node.animator.speed
		t.playhead += step * max(speed, 0)
		if t.playhead >= clip.length {
			if clip.loop && clip.length > 0 {
				t.playhead = f32(math.mod(f64(t.playhead), f64(clip.length)))
			} else {
				t.playhead = clip.length
				t.playing = false
				t.tickPending = false
				break
			}
		}
		return skald.cmd_delay(1.0 / TIMELINE_FPS, Msg(Timeline_Tick{})), true
	case:
		return {}, false
	}
	return {}, true
}

// The viewport shows the clip at the playhead (Preview_Render applies it)
@(private="file")
previewAt :: proc(s: ^State) {
	s.timeline.previewing = true
}

@(private="file")
timelineView :: proc(s: ^State, v: Timeline_View) -> skald.Command(Msg) {
	t := &s.timeline
	node, _ := Timeline_Animator(s)
	switch v.op {
	case .Clip_Chosen:
		t.clip, t.playhead, t.track, t.key, t.playing = v.index, 0, -1, -1, false
		t.previewing = true
		delete(t.nameEdit)
		t.nameEdit = ""
	case .Scrubbed:
		if clip := Timeline_Clip(s); clip != nil do t.playhead = clamp(v.number, 0, clip.length)
		t.previewing = true
	case .Play_Toggled:
		t.playing = !t.playing
		t.previewing = true
		if clip := Timeline_Clip(s); t.playing && clip != nil && t.playhead >= clip.length do t.playhead = 0
		if t.playing && !t.tickPending {
			t.tickPending = true
			t.lastTick = time.tick_now()
			return skald.cmd_delay(1.0 / TIMELINE_FPS, Msg(Timeline_Tick{}))
		}
	case .Rewound:
		t.playhead, t.playing = 0, false
		t.previewing = true
	case .Track_Selected:
		t.track, t.key = v.index, -1
	case .Key_Selected:
		t.track, t.key = v.index, v.other
		if clip := Timeline_Clip(s); clip != nil && v.index >= 0 && v.index < len(clip.tracks) && v.other >= 0 && v.other < len(clip.tracks[v.index].keys) {
			t.playhead = clip.tracks[v.index].keys[v.other].time
			t.previewing = true
		}
	case .New_Node_Chosen:
		delete(t.newNode)
		t.newNode = strings.clone(v.text)
		delete(t.newProperty)
		t.newProperty = ""
	case .New_Property_Chosen:
		delete(t.newProperty)
		t.newProperty = strings.clone(v.text)
	case .Drag_Begin:
		t.dragging = true
		s.history.gesture += 1
	case .Drag_End:
		t.dragging = false
	case .Scrub_Begin:
		t.scrubbing = true
	case .Scrub_End:
		t.scrubbing = false
	case .Name_Typed:
		delete(t.nameEdit)
		t.nameEdit = strings.clone(v.text)
		// A valid name applies at once (an undo step); the text stays until then
		if node != nil && Timeline_ClipNameProblem(node, t.clip, v.text) == "" {
			delete(t.nameEdit)
			t.nameEdit = ""
			timelineEdit(s, {op = .Clip_Renamed, text = v.text})
		}
	}
	return {}
}

/*
Why a clip can't have a name ("" when it can): empty, or another clip's.

Inputs:
- node: The Animator
- clip: The clip renamed
- name: The name

Returns:
- The problem, or ""
*/
Timeline_ClipNameProblem :: proc(node: ^NodeDef, clip: int, name: string) -> string {
	name := strings.trim_space(name)
	if name == "" do return "A clip needs a name"
	for c, i in node.animator.clips do if i != clip && c.name == name do return "Another clip has that name"
	return ""
}

@(private="file")
uniqueClipName :: proc(node: ^NodeDef, base: string) -> string {
	for n := 1; ; n += 1 {
		name := n == 1 ? base : fmt.tprintf("%s%d", base, n)
		if Timeline_ClipNameProblem(node, -1, name) == "" do return name
	}
}

@(private="file")
timelineEdit :: proc(s: ^State, v: Timeline_Changed) {
	t := &s.timeline
	node, index := Timeline_Animator(s)
	if node == nil do return
	settings := &node.animator
	clip := Timeline_Clip(s)
	scene := &s.project.scenes[s.currentScene]
	track: ^e.AnimatorTrackData
	if clip != nil && t.track >= 0 && t.track < len(clip.tracks) do track = &clip.tracks[t.track]
	key: ^e.AnimatorKeyData
	if track != nil && t.key >= 0 && t.key < len(track.keys) do key = &track.keys[t.key]
	switch v.op {
	case .Clip_Added:
		name := strings.clone(v.text != "" ? v.text : uniqueClipName(node, "clip"))
		append(&settings.clips, e.AnimatorClipData{name = name, length = 1, tracks = make([dynamic]e.AnimatorTrackData)})
		t.clip, t.playhead, t.track, t.key = len(settings.clips) - 1, 0, -1, -1
	case .Clip_Removed:
		if clip == nil do break
		removed := e.AnimatorSettings{clips = make([dynamic]e.AnimatorClipData, context.temp_allocator)}
		append(&removed.clips, clip^)
		if settings.autoplay == clip.name {
			delete(settings.autoplay)
			settings.autoplay = strings.clone("")
		}
		ordered_remove(&settings.clips, t.clip)
		destroyClips(&removed)
		t.clip, t.playhead, t.track, t.key = max(t.clip - 1, 0), 0, -1, -1
	case .Clip_Renamed:
		if clip == nil || Timeline_ClipNameProblem(node, t.clip, v.text) != "" do break
		name := strings.trim_space(v.text)
		if settings.autoplay == clip.name {
			delete(settings.autoplay)
			settings.autoplay = strings.clone(name)
		}
		delete(clip.name)
		clip.name = strings.clone(name)
	case .Clip_Length:
		if clip != nil do clip.length = max(v.number, 0.01)
	case .Clip_Loop:
		if clip != nil do clip.loop = v.flag
	case .Clip_Autoplay:
		if clip == nil do break
		delete(settings.autoplay)
		settings.autoplay = strings.clone(v.flag ? clip.name : "")
	case .Autoplay_Named:
		delete(settings.autoplay)
		settings.autoplay = strings.clone(v.text)
	case .Speed:
		settings.speed = max(v.number, 0)
	case .Track_Added:
		if clip == nil do break
		if v.text == e.ANIMATOR_EVENT_PROPERTY {
			append(&clip.tracks, e.AnimatorTrackData{node = strings.clone(""), property = strings.clone(e.ANIMATOR_EVENT_PROPERTY), keys = make([dynamic]e.AnimatorKeyData)})
		} else {
			if v.text == "" || Timeline_ResolvePath(scene, index, v.path) < 0 do break
			append(&clip.tracks, e.AnimatorTrackData{node = strings.clone(v.path), property = strings.clone(v.text), keys = make([dynamic]e.AnimatorKeyData)})
			// The next track's choices stay
			if v.path != t.newNode {
				delete(t.newNode)
				t.newNode = strings.clone(v.path)
			}
		}
		t.track, t.key = len(clip.tracks) - 1, -1
		// Its first key: the node's value now, at the playhead
		addKey(s, scene, index, &clip.tracks[t.track], t.playhead)
		t.key = 0
	case .Track_Removed:
		if track == nil do break
		for k in track.keys do delete(k.value)
		delete(track.keys)
		delete(track.node)
		delete(track.property)
		ordered_remove(&clip.tracks, t.track)
		t.track, t.key = -1, -1
	case .Track_Step:
		if track != nil do track.step = v.flag
	case .Key_Added:
		if track == nil do break
		t.key = addKey(s, scene, index, track, t.playhead)
	case .Keys_Recorded:
		if clip == nil do break
		for &tr in clip.tracks do if tr.property != e.ANIMATOR_EVENT_PROPERTY do addKey(s, scene, index, &tr, t.playhead)
	case .Key_Removed:
		if key == nil do break
		delete(key.value)
		ordered_remove(&track.keys, t.key)
		t.key = -1
	case .Key_Time, .Key_Moved:
		if key == nil do break
		key.time = clamp(v.number, 0, clip.length)
		t.playhead = key.time
		// Keep the keys in order, and the moved one selected
		moved := key.time
		value := key.value
		slice.stable_sort_by(track.keys[:], proc(a, b: e.AnimatorKeyData) -> bool { return a.time < b.time })
		for k, i in track.keys do if k.time == moved && raw_data(k.value) == raw_data(value) do t.key = i
	case .Key_Value:
		if key == nil do break
		delete(key.value)
		key.value = strings.clone(strings.trim_space(v.text))
	case .Key_Ease:
		if key == nil do break
		for ease in e.EaseType do if fmt.tprint(ease) == v.text do key.ease = ease
	}
}

// A key at `at` on a track: its node's value now (or an event's name); replaces a key already
// there. Returns its index
@(private="file")
addKey :: proc(s: ^State, scene: ^SceneDef, animator: int, track: ^e.AnimatorTrackData, at: f32) -> int {
	value: string
	if track.property == e.ANIMATOR_EVENT_PROPERTY {
		value = strings.clone(fmt.tprintf("event%d", len(track.keys) + 1))
	} else {
		target := Timeline_ResolvePath(scene, animator, track.node)
		if target < 0 do return -1
		text, ok := Timeline_NodeValue(s, &scene.nodes[target], track.property)
		if !ok do return -1
		value = text
	}
	for &k, i in track.keys do if abs(k.time - at) < 0.0005 {
		delete(k.value)
		k.value = value
		return i
	}
	append(&track.keys, e.AnimatorKeyData{time = at, value = value})
	slice.stable_sort_by(track.keys[:], proc(a, b: e.AnimatorKeyData) -> bool { return a.time < b.time })
	for k, i in track.keys do if raw_data(k.value) == raw_data(value) do return i
	return -1
}

@(private="file")
destroyClips :: proc(settings: ^e.AnimatorSettings) {
	for &clip in settings.clips {
		for &track in clip.tracks {
			for k in track.keys do delete(k.value)
			delete(track.keys)
			delete(track.node)
			delete(track.property)
		}
		delete(clip.tracks)
		delete(clip.name)
	}
}

/*
Frees the Timeline's own strings.

Inputs:
- t: The Timeline
*/
TimelineEditor_Destroy :: proc(t: ^TimelineEditor) {
	delete(t.newNode)
	delete(t.newProperty)
	delete(t.nameEdit)
	t^ = {node = -1, track = -1, key = -1}
}
