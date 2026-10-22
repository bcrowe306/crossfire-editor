package crossfire_editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

/*
The live view: the game run with Play, seen and changed while it plays (the engine's live.odin).

- **The link:** Play starts the player with `--live` and a pipe on its stdin (`PlaySession.stdin`);
  `Live_Send` writes a command line to it. The game's replies come with its output: lines starting
  `@@live ` are taken out of the Console and read by `Live_Ingest` into `State.live`.
- **What's asked:** `watch` when the game starts (stats four times a second, the scene's tree twice
  a second); `select <id>` when a node is chosen (its properties come with each tree); `set <id>
  <property> <value>` as a property is typed in; `pause`, `resume`, `step`.
- **The view** (view_live.odin, the bottom panel's Live tab): the stats with a graph of frame
  times, the running scene's nodes, the chosen node's properties to edit, and the pause and step
  buttons. Nothing here is saved or undoable: the running game changes, not the project.
*/

// The running game as the live view knows it (`State.live`; strings heap, owned)
LiveView :: struct {
	// The game answered (since it started)
	connected: bool,
	// The playing scene's name
	scene: string,
	// Its nodes, parents before children
	nodes: [dynamic]LiveNode,
	// The chosen node's id ("": none) and its properties
	selected: string,
	properties: [dynamic]LiveProperty,
	// Values typed in, by property name, kept until another node is chosen (the game's value
	// comes back every half second and would overwrite what's being typed)
	edits: map[string]string,
	// The last stats
	stats: LiveStats,
	// Frame times (milliseconds), oldest first, for the graph
	history: [dynamic]f32,
	// The game is paused (as it said)
	paused: bool,
	// A pause or resume was sent: stats saying otherwise were sent before the game read it, and
	// are ignored until one agrees (or a couple of seconds pass)
	pausePending: bool,
	pauseSent: time.Tick,
}

LiveNode :: struct {
	id, name, type, parent: string,
	visible: bool,
	// Its depth in the tree (0: top level)
	depth: int,
}

LiveProperty :: struct {
	name, value: string,
}

LiveStats :: struct {
	fps, frame, update, physics, draw: f32,
	nodes, drawn: int,
}

// Frame times the graph keeps
LIVE_HISTORY :: 120

// A command for the game (the Live tab's buttons): pause, resume, step
Live_Command :: distinct string
// A node chosen in the Live tab (its id)
Live_Selected :: distinct string
// A property typed in the Live tab
Live_Property_Edited :: struct {
	name, text: string,
}

/*
Writes a command to the running game (nothing when no game runs with the link).

Returns:
- Whether it was written
*/
Live_Send :: proc(s: ^State, line: string) -> bool {
	if s.play.stdin == nil do return false
	n, err := os.write(s.play.stdin, transmute([]u8)fmt.tprintf("%s\n", line))
	return err == nil && n > 0
}

/*
Reads a reply the game printed (the text after `@@live `).
*/
Live_Ingest :: proc(s: ^State, text: string) {
	value, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil do return
	object, isObject := value.(json.Object)
	if !isObject do return
	live := &s.live
	live.connected = true
	str :: proc(o: json.Object, key: string) -> string {
		v, _ := o[key].(json.String)
		return v
	}
	num :: proc(o: json.Object, key: string) -> f32 {
		v, _ := o[key].(json.Float)
		return f32(v)
	}
	switch str(object, "type") {
	case "stats":
		live.stats = {
			fps = num(object, "fps"), frame = num(object, "frame"), update = num(object, "update"),
			physics = num(object, "physics"), draw = num(object, "draw"),
			nodes = int(num(object, "nodes")), drawn = int(num(object, "drawn")),
		}
		paused, _ := object["paused"].(json.Boolean)
		if live.pausePending && paused != live.paused && time.duration_seconds(time.tick_since(live.pauseSent)) < 2 {
			// Sent before the game read our pause or resume
		} else {
			live.paused = paused
			live.pausePending = false
		}
		append(&live.history, live.stats.frame)
		if len(live.history) > LIVE_HISTORY do ordered_remove(&live.history, 0)
	case "tree":
		liveClearNodes(live)
		delete(live.scene)
		live.scene = strings.clone(str(object, "scene"))
		nodes, _ := object["nodes"].(json.Array)
		depths := make(map[string]int, context.temp_allocator)
		for n in nodes {
			o := n.(json.Object) or_continue
			id, parent := str(o, "id"), str(o, "parent")
			depth := parent == "" ? 0 : depths[parent] + 1
			depths[id] = depth
			visible, _ := o["visible"].(json.Boolean)
			append(&live.nodes, LiveNode{strings.clone(id), strings.clone(str(o, "name")), strings.clone(str(o, "type")), strings.clone(parent), visible, depth})
		}
	case "node":
		if str(object, "id") != live.selected do break
		liveClearProperties(live)
		props, _ := object["properties"].(json.Array)
		for p in props {
			o := p.(json.Object) or_continue
			append(&live.properties, LiveProperty{strings.clone(str(o, "name")), strings.clone(str(o, "value"))})
		}
	case "set":
		ok, _ := object["ok"].(json.Boolean)
		if !ok do logLine(s, .Warning, fmt.aprintf("Live: %s isn't a value of %s", live.edits[str(object, "property")], str(object, "property")))
	}
}

/*
Handles the Live tab's messages.

Returns:
- Whether the message was this file's
*/
Live_Update :: proc(s: ^State, m: Msg) -> bool {
	live := &s.live
	#partial switch v in m {
	case Live_Command:
		Live_Send(s, string(v))
		logLine(s, .Info, fmt.aprintf("Live: %s", v))
		// Shown at once (the game says so with its next stats); the toolbar's Play button too
		if v == "pause" || v == "resume" {
			live.pausePending = true
			live.pauseSent = time.tick_now()
		}
		if v == "pause" {
			live.paused = true
			if s.playState == .Playing do s.playState = .Paused
		}
		if v == "resume" {
			live.paused = false
			if s.playState == .Paused do s.playState = .Playing
		}
	case Live_Selected:
		delete(live.selected)
		live.selected = strings.clone(string(v))
		liveClearProperties(live)
		liveClearEdits(live)
		Live_Send(s, fmt.tprintf("select %s", v))
	case Live_Property_Edited:
		if live.selected == "" do break
		if old, found := live.edits[v.name]; found {
			delete(old)
			live.edits[v.name] = strings.clone(v.text)
		} else {
			live.edits[strings.clone(v.name)] = strings.clone(v.text)
		}
		Live_Send(s, fmt.tprintf("set %s %s %s", live.selected, v.name, v.text))
	case:
		return false
	}
	return true
}

/*
Forgets the running game (it stopped, or a new one starts).
*/
Live_Reset :: proc(live: ^LiveView) {
	liveClearNodes(live)
	liveClearProperties(live)
	liveClearEdits(live)
	delete(live.scene)
	delete(live.selected)
	delete(live.nodes)
	delete(live.properties)
	delete(live.edits)
	delete(live.history)
	live^ = {}
}

@(private="file")
liveClearNodes :: proc(live: ^LiveView) {
	for n in live.nodes {
		delete(n.id)
		delete(n.name)
		delete(n.type)
		delete(n.parent)
	}
	clear(&live.nodes)
}

@(private="file")
liveClearProperties :: proc(live: ^LiveView) {
	for p in live.properties {
		delete(p.name)
		delete(p.value)
	}
	clear(&live.properties)
}

@(private="file")
liveClearEdits :: proc(live: ^LiveView) {
	for k, v in live.edits {
		delete(k)
		delete(v)
	}
	clear(&live.edits)
}
