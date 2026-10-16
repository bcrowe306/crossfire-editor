package editor

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:time"
import "gui:skald"
import sdl "vendor:sdl3"

/*
UI test driver: runs a script that drives the editor through real input.

	odin_sdl_editor [project folder] --script tests/ui/smoke.script

The script pushes SDL mouse and keyboard events, which reach Skald exactly like a user's input,
and checks the editor's state. Everything happens inside the editor process: the driver never
reads the screen, so it's safe to run while using the machine (the editor window does open). Widgets are found by the key their id was made from
(`skald.hash_id(key)` in the view code), so scripts don't depend on window size or layout.
The editor exits when the script ends: code 0 if every check passed, 1 otherwise.

Script format: one command per line; blank lines and `#` comments are ignored.

	wait <frames>                    Let frames pass
	wait_until <check> [timeout=<s>] Wait (default 10 s) until a check passes; fails on timeout
	expect <check>                   Fail unless the check passes now
	click_widget <key>               Click the center of a widget's visible part, e.g. toolbar-play
	click_row <tree key> <row>       Click a row of a tree: browser-tree, scene-tree
	right_click_row <tree key> <row> Right-click a row (opens the scene tree's context menu)
	click_menu_item <menu key> <i>   Click item i of an open context menu, e.g. scene-tree-menu
	drag_row <tree key> <from> <to> <before | inside | after>
	                                 Drag a row onto another row (top quarter, middle, bottom
	                                 quarter); a `to` past the last row drops below the rows
	click_node <name>                Click a node in the viewport (current scene)
	drag_node <name> <dx> <dy>       Press on a node, move by (dx, dy) window pixels, release
	scroll <notches>                 Mouse wheel over the viewport center (positive zooms in)
	click <x> <y>                    Click a window position (logical pixels)
	move <x> <y>                     Move the mouse
	key <combo>                      Press a key: F5, DELETE, ctrl+s, shift+F5 (SDL scancode names)
	type <text>                      Type text into the focused field
	import <path>                    Import a file as an asset, as if picked in the Import dialog
	                                 (native file dialogs can't be scripted)
	quit                             End the script

Checks:

	scene <name>                 Scene open in the viewport
	selected <name | none>       Selected node
	parent <name | none>         The selected node's parent
	nodes <count>                Nodes in the open scene
	play <Stopped | Building | Playing | Paused>
	tab <Console | Output | Animation>
	bottom <open | closed>       Bottom panel
	field <x | y | rotation | scale_x | scale_y | visible | name> <value>
	                             Property of the selected node (numbers are rounded to whole units)
	tool <Select | Move | Rotate | Scale>
	zoom <percent>               Viewport zoom, rounded to a whole percent
	typing <true | false>        Whether a text or number field has keyboard focus
	assets <count>               Assets in the project
	browser_rows <count>         Rows the project browser shows (after search filtering)
	preview <image | audio | font | none>   What the browser's preview panel shows
	preview_visible <true | false>   The image preview got usable space (at least 32 x 32)
	audio <playing | stopped>    Sound preview playback
	dialog <open | closed>       The remove-asset dialog
	add_dialog <open | closed>   The Add Node dialog
	menu <key> <open | closed>   A context menu, e.g. scene-tree-menu
	row <n> <name>               Node shown in row n of the scene tree
	clipboard <count>            Nodes copied (a subtree)
	console_contains <text>      A console line contains the text
	output_contains <text>       An Output line contains the text

Every input command waits INPUT_SETTLE_FRAMES afterwards, so its effects are visible to the
next check.
*/

INPUT_SETTLE_FRAMES :: 3
DEFAULT_WAIT_TIMEOUT :: 10 * time.Second
// A script that hasn't finished after this long fails
SCRIPT_TIMEOUT :: 300 * time.Second

// Sent every frame while a script runs, so the editor keeps drawing frames
Script_Tick :: struct {}

@(private="file")
Driver :: struct {
	active: bool,
	path: string,
	lines: []string,
	line: int,
	// Frames to let pass before the next command
	waitFrames: int,
	// Events to push on later frames, one batch per frame (a release after a press, drag steps)
	pending: [dynamic][dynamic]sdl.Event,
	// Active wait_until: the check and its deadline
	waitCheck: string,
	waitDeadline: time.Tick,
	waitTimeout: time.Duration,
	started: time.Tick,
	failures: int,
	finished: bool,
}

@(private="file")
driver: Driver

/*
Loads a script. Call before the app starts.

Inputs:
- path: Script file

Returns:
- false if the file can't be read
*/
ScriptDriver_Load :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("[script] can't read %s: %v", path, err)
		return false
	}
	driver = {
		active = true,
		path = path,
		lines = strings.split_lines(string(data)),
		started = time.tick_now(),
	}
	return true
}

// Whether a script is driving the editor
ScriptDriver_Active :: proc() -> bool {
	return driver.active
}

// Exit code for a finished script: 0 when every check passed
ScriptDriver_ExitCode :: proc() -> int {
	return driver.failures == 0 && driver.finished ? 0 : 1
}

/*
Runs script commands for this frame. Called from `view`, which has what the driver needs: the
widget rectangles from the last frame and the current state.
*/
ScriptDriver_Frame :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) {
	if !driver.active do return
	// Keep frames coming while the script runs
	skald.send(ctx, Msg(Script_Tick{}))

	if time.tick_since(driver.started) > SCRIPT_TIMEOUT {
		fail("script timed out")
		finish(ctx)
		return
	}

	// Events queued by the previous command go out one batch per frame
	if len(driver.pending) > 0 {
		batch := driver.pending[0]
		for &event in batch do _ = sdl.PushEvent(&event)
		delete(batch)
		ordered_remove(&driver.pending, 0)
		return
	}
	if driver.waitFrames > 0 {
		driver.waitFrames -= 1
		return
	}
	if driver.waitCheck != "" {
		ok, message := runCheck(s, ctx, driver.waitCheck)
		if ok {
			report(true, fmt.tprintf("wait_until %s", driver.waitCheck))
			driver.waitCheck = ""
		} else if time.tick_since(driver.waitDeadline) > 0 {
			fail(fmt.tprintf("wait_until %s: timed out after %v (%s)", driver.waitCheck, driver.waitTimeout, message))
			driver.waitCheck = ""
		} else {
			return
		}
	}

	// Run commands until one needs to wait for later frames
	for driver.line < len(driver.lines) {
		line := strings.trim_space(driver.lines[driver.line])
		driver.line += 1
		if line == "" || strings.has_prefix(line, "#") do continue
		if !runCommand(s, ctx, line) do return
	}
	finish(ctx)
}

// Runs one command. Returns false when the script must wait before the next one
@(private="file")
runCommand :: proc(s: ^State, ctx: ^skald.Ctx(Msg), line: string) -> bool {
	command, _, rest := strings.partition(line, " ")
	rest = strings.trim_space(rest)
	args := strings.fields(rest, context.temp_allocator)

	switch command {
	case "wait":
		driver.waitFrames = max(atoi(args, 0, 1), 1)
		return false

	case "wait_until":
		check := rest
		driver.waitTimeout = DEFAULT_WAIT_TIMEOUT
		if index := strings.index(rest, "timeout="); index >= 0 {
			if seconds, ok := strconv.parse_f64(rest[index + len("timeout="):]); ok {
				driver.waitTimeout = time.Duration(seconds * f64(time.Second))
			}
			check = strings.trim_space(rest[:index])
		}
		driver.waitCheck = strings.clone(check)
		driver.waitDeadline = time.tick_add(time.tick_now(), driver.waitTimeout)
		return false

	case "expect":
		ok, message := runCheck(s, ctx, rest)
		if ok do report(true, line)
		else do fail(fmt.tprintf("%s (%s)", line, message))
		return true

	case "click_widget":
		rect, ok := widgetRect(ctx, rest)
		if !ok {
			fail(fmt.tprintf("%s: no widget with key '%s' was drawn last frame", line, rest))
			return true
		}
		click({rect.x + rect.w * 0.5, rect.y + rect.h * 0.5})
		report(true, line)
		return false

	case "click_row":
		if len(args) < 2 {
			fail(fmt.tprintf("%s: expected a tree key and a row", line))
			return true
		}
		rect, ok := widgetRect(ctx, args[0])
		if !ok {
			fail(fmt.tprintf("%s: no tree with key '%s' was drawn last frame", line, args[0]))
			return true
		}
		// Rows are laid out from the tree's real top edge, which may be scrolled out of view
		top := ctx.widgets.states[skald.hash_id(args[0])].last_rect.y
		row := atoi(args, 1, 0)
		y := top + (f32(row) + 0.5) * TREE_ROW_HEIGHT
		if !rowVisible(ctx, args[0], y) {
			fail(fmt.tprintf("%s: row %d is scrolled out of view", line, row))
			return true
		}
		click({rect.x + rect.w * 0.5, y})
		report(true, line)
		return false

	case "right_click_row", "drag_row":
		if len(args) < (command == "drag_row" ? 4 : 2) {
			fail(fmt.tprintf("%s: expected a tree key and rows", line))
			return true
		}
		rect, ok := widgetRect(ctx, args[0])
		if !ok {
			fail(fmt.tprintf("%s: no tree with key '%s' was drawn last frame", line, args[0]))
			return true
		}
		top := ctx.widgets.states[skald.hash_id(args[0])].last_rect.y
		x := rect.x + rect.w * 0.5
		from := [2]f32{x, top + (f32(atoi(args, 1, 0)) + 0.5) * TREE_ROW_HEIGHT}
		if !rowVisible(ctx, args[0], from.y) {
			fail(fmt.tprintf("%s: row %s is scrolled out of view", line, args[1]))
			return true
		}
		if command == "right_click_row" {
			pushMouse(.MOUSE_MOTION, from)
			queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, from, sdl.BUTTON_RIGHT))
			queueBatch(mouseEvent(.MOUSE_BUTTON_UP, from, sdl.BUTTON_RIGHT))
			driver.waitFrames = INPUT_SETTLE_FRAMES
			report(true, line)
			return false
		}
		fraction: f32
		switch args[3] {
		case "before": fraction = 0.1
		case "inside": fraction = 0.5
		case "after":  fraction = 0.9
		case:
			fail(fmt.tprintf("%s: expected before, inside or after", line))
			return true
		}
		to := [2]f32{x, top + (f32(atoi(args, 2, 0)) + fraction) * TREE_ROW_HEIGHT}
		if !rowVisible(ctx, args[0], to.y) {
			fail(fmt.tprintf("%s: row %s is scrolled out of view", line, args[2]))
			return true
		}
		pushMouse(.MOUSE_MOTION, from)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, from))
		STEPS :: 4
		for i in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, from + (to - from) * f32(i) / STEPS))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, to))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "click_menu_item":
		state, drawn := ctx.widgets.states[skald.hash_id(args[0] if len(args) > 0 else "")]
		if !drawn || !state.open {
			fail(fmt.tprintf("%s: no open context menu with that key", line))
			return true
		}
		click(contextMenuItemCenter(ctx, state.anchor_pos, atoi(args, 1, 0), atoi(args, 2, 6)))
		report(true, line)
		return false

	case "click_node":
		scene := &s.project.scenes[s.currentScene]
		index := -1
		for node, i in scene.nodes do if node.name == rest do index = i
		position, ok := ViewportNodePosition(s, ctx, index)
		if !ok {
			fail(fmt.tprintf("%s: no visible node '%s' in the viewport", line, rest))
			return true
		}
		click(position)
		report(true, line)
		return false

	case "drag_node":
		if len(args) < 3 {
			fail(fmt.tprintf("%s: expected a node name and dx dy", line))
			return true
		}
		scene := &s.project.scenes[s.currentScene]
		index := -1
		for node, i in scene.nodes do if node.name == args[0] do index = i
		start, ok := ViewportNodePosition(s, ctx, index)
		if !ok {
			fail(fmt.tprintf("%s: no visible node '%s' in the viewport", line, args[0]))
			return true
		}
		delta := [2]f32{f32(atoi(args, 1, 0)), f32(atoi(args, 2, 0))}
		pushMouse(.MOUSE_MOTION, start)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, start))
		// Move in steps over several frames, like a real drag, then release
		STEPS :: 4
		for i in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, start + delta * f32(i) / STEPS))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, start + delta))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "scroll":
		center, ok := viewportCenter(ctx)
		if !ok {
			fail(fmt.tprintf("%s: the viewport hasn't been drawn", line))
			return true
		}
		pushMouse(.MOUSE_MOTION, center)
		event: sdl.Event
		event.type = .MOUSE_WHEEL
		event.wheel.y = f32(atoi(args, 0, 1))
		event.wheel.mouse_x, event.wheel.mouse_y = center.x, center.y
		queueBatch(event)
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "click":
		click({f32(atoi(args, 0, 0)), f32(atoi(args, 1, 0))})
		report(true, line)
		return false

	case "move":
		pushMouse(.MOUSE_MOTION, {f32(atoi(args, 0, 0)), f32(atoi(args, 1, 0))})
		driver.waitFrames = INPUT_SETTLE_FRAMES
		return false

	case "key":
		if !pressKey(rest) {
			fail(fmt.tprintf("%s: unknown key", line))
			return true
		}
		report(true, line)
		return false

	case "type":
		event: sdl.Event
		event.type = .TEXT_INPUT
		event.text.text = strings.clone_to_cstring(rest) // Read by Skald next frame; tiny, kept
		_ = sdl.PushEvent(&event)
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "import":
		skald.send(ctx, Msg(Asset_Import_Result{path = strings.clone(rest)}))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "quit":
		driver.line = len(driver.lines)
		return true
	}

	fail(fmt.tprintf("unknown command: %s", line))
	return true
}

// Evaluates a check against the state. Returns whether it passed and what was found
@(private="file")
runCheck :: proc(s: ^State, ctx: ^skald.Ctx(Msg), check: string) -> (ok: bool, found: string) {
	name, _, value := strings.partition(check, " ")
	value = strings.trim_space(value)
	scene := &s.project.scenes[s.currentScene]
	selected := s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) ? &scene.nodes[s.selectedNode] : nil

	switch name {
	case "scene":
		found = scene.name
	case "selected":
		found = selected != nil ? selected.name : "none"
	case "parent":
		if selected == nil do return false, "nothing selected"
		found = selected.parent >= 0 ? scene.nodes[selected.parent].name : "none"
	case "nodes":
		found = fmt.tprint(len(scene.nodes))
	case "play":
		found = fmt.tprint(s.playState)
	case "tab":
		found = fmt.tprint(s.bottomTab)
	case "bottom":
		found = s.layout.bottomOpen ? "open" : "closed"
	case "tool":
		found = fmt.tprint(s.tool)
	case "zoom":
		found = fmt.tprint(int(math.round(s.viewport.zoom * 100)))
	case "typing":
		found = fmt.tprint(IsTyping(ctx))
	case "assets":
		found = fmt.tprint(len(s.project.assets))
	case "browser_rows":
		found = fmt.tprint(len(BrowserRows(s)))
	case "preview":
		found = "none"
		if s.browserSelection.kind == .Asset && s.browserSelection.index < len(s.project.assets) {
			found = strings.to_lower(fmt.tprint(s.project.assets[s.browserSelection.index].kind), context.temp_allocator)
		}
	case "preview_visible":
		found = fmt.tprint(previewImageArea.x >= 32 && previewImageArea.y >= 32)
	case "audio":
		found = AudioPreview_IsPlaying() ? "playing" : "stopped"
	case "dialog":
		found = s.removeConfirm.open ? "open" : "closed"
	case "add_dialog":
		found = s.addNode.open ? "open" : "closed"
	case "menu":
		key, _, expected := strings.partition(value, " ")
		state, drawn := ctx.widgets.states[skald.hash_id(key)]
		found = drawn && state.open ? "open" : "closed"
		return found == strings.trim_space(expected), found
	case "row":
		index, _, expected := strings.partition(value, " ")
		rows := SceneTreeRows(scene)
		row, _ := strconv.parse_int(index)
		found = row >= 0 && row < len(rows) ? scene.nodes[rows[row]].name : "none"
		return found == strings.trim_space(expected), found
	case "clipboard":
		found = fmt.tprint(len(s.clipboard))
	case "field":
		field, _, expected := strings.partition(value, " ")
		if selected == nil do return false, "nothing selected"
		switch field {
		case "x":        found = fmt.tprint(math.round(selected.position.x))
		case "y":        found = fmt.tprint(math.round(selected.position.y))
		case "rotation": found = fmt.tprint(math.round(selected.rotation))
		case "scale_x":  found = fmt.tprintf("%.2f", selected.scale.x)
		case "scale_y":  found = fmt.tprintf("%.2f", selected.scale.y)
		case "visible":  found = fmt.tprint(selected.visible)
		case "name":     found = selected.name
		case:            return false, fmt.tprintf("unknown field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "console_contains", "output_contains":
		lines := name == "console_contains" ? s.console[:] : s.output[:]
		for line in lines do if strings.contains(line.text, value) do return true, "found"
		return false, fmt.tprintf("%d lines, none match", len(lines))
	case:
		return false, fmt.tprintf("unknown check '%s'", name)
	}
	return found == value, found
}

// The visible part of a widget's rectangle from the last frame (clipped by its scroll container
// and the window), looked up without touching its state
@(private="file")
widgetRect :: proc(ctx: ^skald.Ctx(Msg), key: string) -> (skald.Rect, bool) {
	state, ok := ctx.widgets.states[skald.hash_id(key)]
	if !ok do return {}, false
	rect := state.last_rect
	if state.clip_rect.w > 0 do rect = intersect(rect, state.clip_rect)
	if ctx.renderer != nil {
		rect = intersect(rect, {0, 0, f32(ctx.renderer.fb_size.x), f32(ctx.renderer.fb_size.y)})
	}
	if rect.w <= 0 || rect.h <= 0 do return {}, false
	return rect, true
}

@(private="file")
intersect :: proc(a, b: skald.Rect) -> skald.Rect {
	x0, y0 := max(a.x, b.x), max(a.y, b.y)
	x1, y1 := min(a.x + a.w, b.x + b.w), min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

// Move there now, press next frame, release the frame after. Like a real mouse, the pointer
// arrives before the button goes down: widgets that act on press (text fields take focus) check
// hover from the previous frame
@(private="file")
click :: proc(position: [2]f32) {
	pushMouse(.MOUSE_MOTION, position)
	queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, position))
	queueBatch(mouseEvent(.MOUSE_BUTTON_UP, position))
	driver.waitFrames = INPUT_SETTLE_FRAMES
}

@(private="file")
pushMouse :: proc(type: sdl.EventType, position: [2]f32) {
	event := mouseEvent(type, position)
	_ = sdl.PushEvent(&event)
}

@(private="file")
mouseEvent :: proc(type: sdl.EventType, position: [2]f32, button := sdl.BUTTON_LEFT) -> sdl.Event {
	event: sdl.Event
	event.type = type
	if type == .MOUSE_MOTION {
		event.motion.x, event.motion.y = position.x, position.y
	} else {
		event.button.button = u8(button)
		event.button.down = type == .MOUSE_BUTTON_DOWN
		event.button.clicks = 1
		event.button.x, event.button.y = position.x, position.y
	}
	return event
}

// "ctrl+shift+s" -> key down now, key up next frame
@(private="file")
pressKey :: proc(combo: string) -> bool {
	parts := strings.split(combo, "+", context.temp_allocator)
	mods: sdl.Keymod
	for part in parts[:len(parts) - 1] {
		switch strings.to_lower(part, context.temp_allocator) {
		case "ctrl":  mods += {.LCTRL}
		case "shift": mods += {.LSHIFT}
		case "alt":   mods += {.LALT}
		case "super": mods += {.LGUI}
		case:         return false
		}
	}
	name := strings.to_upper(parts[len(parts) - 1], context.temp_allocator)
	// SDL's digit scancodes are named _0.._9 in Odin
	if len(name) == 1 && name[0] >= '0' && name[0] <= '9' do name = strings.concatenate({"_", name}, context.temp_allocator)
	scancode, ok := reflect.enum_from_name(sdl.Scancode, name)
	if !ok do return false

	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = scancode
	event.key.mod = mods
	event.key.down = true
	_ = sdl.PushEvent(&event)
	event.type = .KEY_UP
	event.key.down = false
	// Skald takes the modifiers from each key event, so release them too, as letting go of the
	// keys would. Otherwise Ctrl stays held and text inputs ignore later typing.
	event.key.mod = {}
	queueBatch(event)
	driver.waitFrames = INPUT_SETTLE_FRAMES
	return true
}

@(private="file")
atoi :: proc(args: []string, index: int, default: int) -> int {
	if index >= len(args) do return default
	value, ok := strconv.parse_int(args[index])
	return ok ? value : default
}

@(private="file")
report :: proc(passed: bool, text: string) {
	fmt.printfln("[script] %s:%d %s %s", driver.path, driver.line, passed ? "ok  " : "FAIL", text)
}

@(private="file")
fail :: proc(text: string) {
	driver.failures += 1
	report(false, text)
	log.errorf("[script] %s", text)
}

@(private="file")
finish :: proc(ctx: ^skald.Ctx(Msg)) {
	if driver.finished do return
	driver.finished = true
	driver.active = false
	fmt.printfln("[script] %s: %s (%d failed)", driver.path, driver.failures == 0 ? "PASSED" : "FAILED", driver.failures)
	skald.send(ctx, Msg(Action.Quit))
}

// Queues events to push together on a later frame (one frame per queued batch)
@(private="file")
queueBatch :: proc(events: ..sdl.Event) {
	batch := make([dynamic]sdl.Event)
	append(&batch, ..events)
	append(&driver.pending, batch)
}

// Center of the viewport's view area, from last frame's layout
@(private="file")
viewportCenter :: proc(ctx: ^skald.Ctx(Msg)) -> ([2]f32, bool) {
	rect, ok := widgetRect(ctx, "viewport-canvas")
	if !ok do return {}, false
	return {rect.x + RULER_SIZE + (rect.w - RULER_SIZE) * 0.5, rect.y + RULER_SIZE + (rect.h - RULER_SIZE) * 0.5}, true
}

/*
Center of a context menu item. Mirrors `skald.context_menu`'s layout (fixed-height rows below the
click point, flipped above it near the window's bottom); update this if Skald's menu changes.

Inputs:
- anchor: Where the menu was opened (its widget state's `anchor_pos`)
- index: The item
- count: How many items the menu has (it decides whether the menu flips)
*/
@(private="file")
contextMenuItemCenter :: proc(ctx: ^skald.Ctx(Msg), anchor: [2]f32, index, count: int) -> [2]f32 {
	th := ctx.theme
	BORDER :: f32(1)
	PAD :: f32(4)
	GAP :: f32(2)
	rowHeight := th.font.size_md + 2 * th.spacing.sm + 6
	height := 2 * (BORDER + PAD) + f32(count) * rowHeight + f32(max(0, count - 1)) * GAP
	rect := skald.overlay_placement_rect(ctx, skald.Rect{anchor.x, anchor.y, 0, 0}, {250, height}, .Below)
	return {rect.x + 125, rect.y + BORDER + PAD + f32(index) * (rowHeight + GAP) + rowHeight * 0.5}
}

// Whether a height in a tree is inside the part of the tree's scroll area that's on screen. Rows
// past the end of the tree count, as long as they're inside that area (dropping below the rows)
@(private="file")
rowVisible :: proc(ctx: ^skald.Ctx(Msg), treeKey: string, y: f32) -> bool {
	state := ctx.widgets.states[skald.hash_id(treeKey)]
	area := state.clip_rect.w > 0 ? state.clip_rect : state.last_rect
	return y >= area.y && y < area.y + area.h
}
