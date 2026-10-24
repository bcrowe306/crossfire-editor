package crossfire_editor

import "core:encoding/json"
import "core:hash"
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
  <property> <value>` as a property is typed in; `pause`, `resume`, `step`; `shapes on` / `off`
  from the toolbar's collision shapes button (`Live_SetShapes`; the stats say whether they're
  shown, so the button follows F9 pressed in the game).
- **The view** (view_live.odin, the bottom panel's Live tab): the stats with a graph of frame
  times, the running scene's nodes, the chosen node's properties to edit, and the pause and step
  buttons. Nothing here is saved or undoable: the running game changes, not the project.
- **Live values in the code** (code_live.odin): the tree says which scripts each node runs
  (`LiveNode.scripts`); `fields <Script> <id> <field>...` asks for the fields a code tab shows
  (`Live_Watch`: only what changed is sent), whose values come back with the stats
  (`LiveView.fields`).
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
	// The game shows its physics debug shapes (as it said; F9 in the game toggles them)
	shapes: bool,
	// `shapes` was sent: stats saying otherwise are ignored until one agrees (as for pausing)
	shapesPending: bool,
	shapesSent: time.Tick,
	// Script fields a code tab shows, as the game last sent them (`fields` replies; code_live.odin)
	fields: [dynamic]LiveFields,
	// The `fields` watches sent ("<Script> <id> <field>..." each, owned), so only changes are sent
	watches: [dynamic]string,
	// Bumped when the tree's nodes or scripts change, and when a watched value changes (the code
	// tab's hints are asked again)
	treeGeneration, fieldsGeneration: int,
	treeHash: u64,
	// A node picked in a code tab for a script (its hint's menu): script name to node id (owned)
	codePicks: map[string]LiveCodePick,
}

// A live node a code tab's hint was pointed at (`LiveView.codePicks`)
LiveCodePick :: struct {
	// The live node's id (owned)
	id: string,
	// What the Live tab and the scene had chosen then: when either changes, the pick gives way
	liveSelected: u64,
	editorSelected: int,
}

// A script's fields on a node, as the game sent them (`fields` reply; strings owned)
LiveFields :: struct {
	script, id: string,
	values: [dynamic]LiveProperty,
}

LiveNode :: struct {
	id, name, type, parent: string,
	visible: bool,
	// Its depth in the tree (0: top level)
	depth: int,
	// The scripts it runs, its node type's first (owned)
	scripts: []string,
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
		shapes, _ := object["shapes"].(json.Boolean)
		if live.shapesPending && shapes != live.shapes && time.duration_seconds(time.tick_since(live.shapesSent)) < 2 {
			// Sent before the game read our shapes command
		} else {
			live.shapes = shapes
			live.shapesPending = false
		}
		append(&live.history, live.stats.frame)
		if len(live.history) > LIVE_HISTORY do ordered_remove(&live.history, 0)
	case "tree":
		liveClearNodes(live)
		delete(live.scene)
		live.scene = strings.clone(str(object, "scene"))
		nodes, _ := object["nodes"].(json.Array)
		depths := make(map[string]int, context.temp_allocator)
		// What the code tab's hints depend on: the nodes and their scripts
		h := hash.fnv64a(transmute([]byte)live.scene)
		for n in nodes {
			o := n.(json.Object) or_continue
			id, parent := str(o, "id"), str(o, "parent")
			depth := parent == "" ? 0 : depths[parent] + 1
			depths[id] = depth
			visible, _ := o["visible"].(json.Boolean)
			list, _ := o["scripts"].(json.Array)
			scripts := make([]string, len(list))
			for s, i in list {
				name, _ := s.(json.String)
				scripts[i] = strings.clone(name)
				h = hash.fnv64a(transmute([]byte)name, h)
			}
			h = hash.fnv64a(transmute([]byte)id, h)
			h = hash.fnv64a(transmute([]byte)str(o, "name"), h)
			append(&live.nodes, LiveNode{strings.clone(id), strings.clone(str(o, "name")), strings.clone(str(o, "type")), strings.clone(parent), visible, depth, scripts})
		}
		if h != live.treeHash {
			live.treeHash = h
			live.treeGeneration += 1
		}
	case "node":
		if str(object, "id") != live.selected do break
		liveClearProperties(live)
		props, _ := object["properties"].(json.Array)
		for p in props {
			o := p.(json.Object) or_continue
			append(&live.properties, LiveProperty{strings.clone(str(o, "name")), strings.clone(str(o, "value"))})
		}
	case "fields":
		// A watched script's fields (a code tab's live values)
		script, id := str(object, "script"), str(object, "id")
		entry: ^LiveFields
		for &f in live.fields do if f.script == script && f.id == id do entry = &f
		if entry == nil {
			append(&live.fields, LiveFields{script = strings.clone(script), id = strings.clone(id)})
			entry = &live.fields[len(live.fields) - 1]
		}
		values, _ := object["values"].(json.Array)
		changed := len(values) != len(entry.values)
		for v, i in values {
			o := v.(json.Object) or_continue
			if !changed && (entry.values[i].name != str(o, "name") || entry.values[i].value != str(o, "value")) do changed = true
		}
		if !changed do break
		liveFieldsClear(entry)
		for v in values {
			o := v.(json.Object) or_continue
			append(&entry.values, LiveProperty{strings.clone(str(o, "name")), strings.clone(str(o, "value"))})
		}
		live.fieldsGeneration += 1
	case "snapshot":
		// Hot reload: the game wrote its state (play_reload.odin)
		ok, _ := object["ok"].(json.Boolean)
		playReloadSnapshotTaken(s, bool(ok))
	case "set":
		ok, _ := object["ok"].(json.Boolean)
		if !ok do logLine(s, .Warning, fmt.aprintf("Live: %s isn't a value of %s", live.edits[str(object, "property")], str(object, "property")))
	}
}

/*
Shows or hides the running game's physics debug shapes over the link (the toolbar's button:
`Toggle_Physics_Debug`). Shown at once; the game's next stats agree.

Inputs:
- s: Editor state
- on: Show them

Returns:
- Whether it was sent (a game runs with the link)
*/
Live_SetShapes :: proc(s: ^State, on: bool) -> bool {
	if !s.live.connected || !Live_Send(s, on ? "shapes on" : "shapes off") do return false
	s.live.shapes = on
	s.live.shapesPending = true
	s.live.shapesSent = time.tick_now()
	return true
}

/*
Whether the game's collision shapes are on, as the toolbar shows them: the running game's (it
may have toggled them with F9), else the project's development setting
(`project.physics.debugDraw`).
*/
PhysicsDebug_Shown :: proc(s: ^State) -> bool {
	if s.live.connected && s.playState != .Stopped do return s.live.shapes
	return s.project.physics.debugDraw
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
	for &f in live.fields {
		liveFieldsClear(&f)
		delete(f.script)
		delete(f.id)
		delete(f.values)
	}
	delete(live.fields)
	for w in live.watches do delete(w)
	delete(live.watches)
	for k, v in live.codePicks {
		delete(k)
		delete(v.id)
	}
	delete(live.codePicks)
	// The code tab's hints go with the game: they're asked again
	generation := live.treeGeneration + live.fieldsGeneration + 1
	live^ = {}
	live.treeGeneration = generation
}

/*
Sends the `fields` watches a code tab wants (code_live.odin's `CodeLive_Watches`), only those
that changed: a script no longer wanted is stopped (`fields <Script>`), a new or changed one sent
whole.

Inputs:
- s: Editor state
- wanted: "<Script> <id> <field>..." lines, one per script
*/
Live_Watch :: proc(s: ^State, wanted: []string) {
	live := &s.live
	scriptOf :: proc(line: string) -> string {
		name, _, _ := strings.partition(line, " ")
		return name
	}
	// Stopped: scripts sent before and not wanted now
	for i := len(live.watches) - 1; i >= 0; i -= 1 {
		old := live.watches[i]
		kept := false
		for w in wanted do if scriptOf(w) == scriptOf(old) do kept = true
		if kept do continue
		Live_Send(s, fmt.tprintf("fields %s", scriptOf(old)))
		liveFieldsForget(live, scriptOf(old))
		delete(old)
		ordered_remove(&live.watches, i)
	}
	for w in wanted {
		at := -1
		for old, i in live.watches do if scriptOf(old) == scriptOf(w) do at = i
		if at >= 0 && live.watches[at] == w do continue
		Live_Send(s, fmt.tprintf("fields %s", w))
		if at >= 0 {
			delete(live.watches[at])
			live.watches[at] = strings.clone(w)
		} else {
			append(&live.watches, strings.clone(w))
		}
	}
}

/*
A script's field on a live node, as the game last sent it.

Returns:
- The value's text (the live view's), and whether it was sent
*/
Live_FieldValue :: proc(live: ^LiveView, script, id, field: string) -> (string, bool) {
	for f in live.fields do if f.script == script && f.id == id {
		for v in f.values do if v.name == field do return v.value, true
	}
	return "", false
}

// A script no longer watched: its values go
@(private="file")
liveFieldsForget :: proc(live: ^LiveView, script: string) {
	for i := len(live.fields) - 1; i >= 0; i -= 1 {
		f := &live.fields[i]
		if f.script != script do continue
		liveFieldsClear(f)
		delete(f.script)
		delete(f.id)
		delete(f.values)
		ordered_remove(&live.fields, i)
		live.fieldsGeneration += 1
	}
}

@(private="file")
liveFieldsClear :: proc(f: ^LiveFields) {
	for v in f.values {
		delete(v.name)
		delete(v.value)
	}
	clear(&f.values)
}

@(private="file")
liveClearNodes :: proc(live: ^LiveView) {
	for n in live.nodes {
		delete(n.id)
		delete(n.name)
		delete(n.type)
		delete(n.parent)
		for s in n.scripts do delete(s)
		delete(n.scripts)
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
