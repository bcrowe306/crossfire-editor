package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "gui:skald"

/*
The Level mode's world tools (phase 5 of TODO.md's "LDtk level editor"), LDtk's WorldTool,
LevelSpotPicker and Rulers on the canvas:

- **New level** (`Level_Spot_Started`: the Levels sidebar's and World tab's New Level, LDtk's
  "Pick a spot for a new level"): the canvas shows the world, the pointer where the new level would
  go (`LDtk_LevelSpot`: blue, red where there's no room; a linear world's insertion), a click makes
  it (`Level_Added`), Esc or the right button cancels. The canvas's right-click menu's New Level
  Here makes one at the point (or starts picking when there's no room, as LDtk asks).
- **The canvas's menu** (a right click that doesn't move: a right drag still pans): New Level Here;
  on a level Duplicate, Delete, Focus, Move to another world; with several worlds, the others.
- **Moving levels** (WorldTool): Free worlds snap to the project's grid while it's shown and to
  other levels' edges within a few screen pixels (Shift or Ctrl: free); GridVania worlds by
  their grid; a linear world's drag puts the level at the place nearest the pointer
  (`Level_Sorted`), its line shown; Ctrl + Alt + drag duplicates the level there (the original
  stays).
- **Resizing** (Rulers): the focused level's eight handles just outside its edges; a drag
  previews the new bounds on the selected layer's grid (the world's in GridVania), at least a cell,
  then `Level_Resized` (its cells and entities stay where they are in the world, cropped).
- **World depth** (`LevelMode.depth`, PgUp / PgDn; Ctrl + PgUp / PgDn move the selected level):
  levels of other depths are faded and can't be picked, as in LDtk's world view.

Keys: the canvas's `ldtk-map-Level`; handles have no widgets (the driver's `level_resize`).
*/

// A level's resize handle (LDtk's RectHandlePos)
LevelResizeHandle :: enum u8 {
	None,
	Top,
	Bottom,
	Left,
	Right,
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
}

// Start picking a spot for a new level on the canvas (World tab, Levels sidebar); `cancel` stops
Level_Spot_Started :: struct {
	cancel: bool,
}

// Show another world depth (`number`: +1 further, -1 closer), or move the selected level there
Level_Depth_Shown :: struct {
	step: int,
	moveLevel: bool,
}

// Rulers' handle distance outside the level and their size (level pixels: PADDING, HANDLE_SIZE)
@(private="file")
RESIZE_PADDING :: 4
@(private="file")
RESIZE_HANDLE :: 10

// Where a handle is, in level pixels (Rulers.getX / getY)
LevelResize_HandlePos :: proc(h: LevelResizeHandle, size: [2]f64) -> [2]f64 {
	x, y: f64
	#partial switch h {
	case .Top, .Bottom: x = f64(int(size.x * 0.5))
	case .Left, .Top_Left, .Bottom_Left: x = -RESIZE_PADDING
	case .Right, .Top_Right, .Bottom_Right: x = size.x + RESIZE_PADDING
	}
	#partial switch h {
	case .Top, .Top_Left, .Top_Right: y = -RESIZE_PADDING
	case .Bottom, .Bottom_Left, .Bottom_Right: y = size.y + RESIZE_PADDING
	case .Left, .Right: y = f64(int(size.y * 0.5))
	}
	return {x, y}
}

/*
The focused level's handle under a world point (Rulers.isOver: within 1.5 handles of it, outside
the level), `.None` when there's none or the level isn't focused.
*/
LevelResize_HandleAt :: proc(state: ^State, doc: ^LDtkDoc, world: [2]f32) -> LevelResizeHandle {
	if state.level.focus == "" || doc == nil do return .None
	level := LDtkDoc_FindLevel(doc, state.level.focus)
	if level < 0 do return .None
	r := LDtkDoc_LevelRect(doc, level)
	p := [2]f64{f64(world.x) - r[0], f64(world.y) - r[1]}
	if p.x >= 0 && p.y >= 0 && p.x < r[2] && p.y < r[3] do return .None
	// Generous enough to grab when zoomed out (8 screen pixels at least)
	reach := max(f64(RESIZE_HANDLE) * 1.5, 8 / f64(max(state.level.view.zoom, 0.01)))
	for h in LevelResizeHandle {
		if h == .None do continue
		at := LevelResize_HandlePos(h, {r[2], r[3]})
		d := p - at
		if math.sqrt(d.x * d.x + d.y * d.y) <= reach do return h
	}
	return .None
}

/*
The bounds a resize drag gives (Rulers.getResizedBounds: the dragged edges moved by whole cells of
the selected layer's grid, or the project's; snapped to a GridVania world's grid), relative to the
level: left, top, right, bottom.
*/
LevelResize_Bounds :: proc(state: ^State, doc: ^LDtkDoc) -> (b: [4]int, valid: bool) {
	drag := state.level.drag
	level := LDtkDoc_FindLevel(doc, drag.target)
	if level < 0 do return {}, false
	r := LDtkDoc_LevelRect(doc, level)
	grid := LDtkDoc_DefaultGrid(doc)
	if def := LevelMode_LayerDef(state, doc); def >= 0 {
		main := LDtkDoc_Main(doc)
		grid = max(Json_Int(main, Json_Get(main, def, "gridSize"), grid), 1)
	}
	d := drag.offset
	step :: proc(v: f32, g: int) -> int { return int(math.floor(f64(v) / f64(g))) * g }
	b = {0, 0, int(r[2]), int(r[3])}
	#partial switch drag.handle {
	case .Left, .Top_Left, .Bottom_Left: b[0] = step(d.x, grid)
	}
	#partial switch drag.handle {
	case .Top, .Top_Left, .Top_Right: b[1] = step(d.y, grid)
	}
	#partial switch drag.handle {
	case .Right, .Top_Right, .Bottom_Right: b[2] = int(r[2]) + step(d.x, grid)
	}
	#partial switch drag.handle {
	case .Bottom, .Bottom_Left, .Bottom_Right: b[3] = int(r[3]) + step(d.y, grid)
	}
	world := doc.levels[level].world
	if LDtkDoc_WorldLayout(doc, world) == "GridVania" {
		g := LDtkDoc_WorldGrid(doc, world)
		round :: proc(v, g: int) -> int { return int(ldtkRound(f64(v) / f64(g))) * g }
		b = {round(b[0], g.x), round(b[1], g.y), round(b[2], g.x), round(b[3], g.y)}
	}
	return b, b[2] >= b[0] + grid && b[3] >= b[1] + grid
}

// The world depth shown, kept within the world's depths
LevelMode_Depth :: proc(state: ^State, doc: ^LDtkDoc) -> int {
	if doc == nil || doc.problem != "" do return 0
	lo, hi := 0, 0
	for l in LevelMode_WorldLevels(state, doc) {
		d := LDtkDoc_LevelDepth(doc, l)
		lo, hi = min(lo, d), max(hi, d)
	}
	return clamp(state.level.depth, lo, hi)
}

// The world's depths (lowest, highest)
LevelMode_Depths :: proc(state: ^State, doc: ^LDtkDoc) -> (lo, hi: int) {
	for l in LevelMode_WorldLevels(state, doc) {
		d := LDtkDoc_LevelDepth(doc, l)
		lo, hi = min(lo, d), max(hi, d)
	}
	return
}

/*
A press the world tools take first: a new level's spot, a resize handle. Returns whether it took it.
*/
LevelWorld_Press :: proc(state: ^State, v: Level_Canvas_Pressed) -> bool {
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	if doc == nil || doc.problem != "" || v.pan do return false
	if state.level.spot {
		if v.right {
			state.level.spot = false
			return true
		}
		iid := LDtk_NewIid()
		levelApplyEdit(state, {op = .Level_Added, file = file, world = LevelMode_World(state, doc), number = f64(v.world.x), number2 = f64(v.world.y),
			index = LevelMode_Depth(state, doc), flag = !state.level.paint.noGrid, text = iid})
		if state.level.problem != "" do return true
		state.level.spot = false
		if doc = LDtkDoc_Get(state.project.rootPath, file); doc != nil do if at := LDtkDoc_FindLevel(doc, iid); at >= 0 {
			id, _ := LDtkDoc_LevelNames(doc, at)
			levelSelect(state, file, strings.clone(id, context.temp_allocator))
		}
		return true
	}
	if v.right || v.alt || v.ctrl do return false
	if h := LevelResize_HandleAt(state, doc, v.world); h != .None {
		drag := &state.level.drag
		delete(drag.target)
		level := LDtkDoc_FindLevel(doc, state.level.focus)
		_, iid := LDtkDoc_LevelNames(doc, level)
		drag^ = {mode = .Resize, target = strings.clone(iid), start = v.world, handle = h}
		return true
	}
	return false
}

/*
Where a level drag puts the level (WorldTool.onMouseMove): Free worlds on the project's grid when
it's shown (truncated, as LDtk's Std.int), then against other levels' edges within the snap
distance (Shift or Ctrl: free); GridVania worlds by whole world cells the pointer moved; linear
worlds where they are (the release reorders them).
*/
LevelDrag_LevelTarget :: proc(state: ^State, doc: ^LDtkDoc) -> [2]int {
	drag := state.level.drag
	level := LDtkDoc_FindLevel(doc, drag.target)
	origin := [2]int{int(drag.origin.x), int(drag.origin.y)}
	delta := [2]int{int(math.round(f64(drag.offset.x))), int(math.round(f64(drag.offset.y)))}
	if level < 0 do return origin + delta
	world := doc.levels[level].world
	switch LDtkDoc_WorldLayout(doc, world) {
	case "GridVania":
		g := LDtkDoc_WorldGrid(doc, world)
		floorTo :: proc(v: f64, g: int) -> int { return int(math.floor(v / f64(g))) * g }
		start := drag.start
		now := drag.start + drag.offset
		x := origin.x + floorTo(f64(now.x), g.x) - floorTo(f64(start.x), g.x)
		y := origin.y + floorTo(f64(now.y), g.y) - floorTo(f64(start.y), g.y)
		return {floorTo(f64(x), g.x), floorTo(f64(y), g.y)}
	case "LinearHorizontal", "LinearVertical":
		return origin
	}
	p := origin + delta
	if !state.level.paint.noGrid {
		g := levelSmartGrid(doc)
		p = {(p.x / g) * g, (p.y / g) * g}
	}
	if drag.free do return p
	// Other levels' edges within the snap distance (WorldTool.snapLevelX / Y), where it doesn't overlap
	r := LDtkDoc_LevelRect(doc, level)
	size := [2]int{int(r[2]), int(r[3])}
	dist := f64(levelSmartGrid(doc)) / (f64(max(state.level.view.zoom, 0.01)) * 0.4)
	overlaps :: proc(doc: ^LDtkDoc, level: int, at, size: [2]int) -> bool {
		for o in worldLevels(doc, doc.levels[level].world) {
			if o == level do continue
			r := LDtkDoc_LevelRect(doc, o)
			if f64(at.x) < r[0] + r[2] && f64(at.x + size.x) > r[0] && f64(at.y) < r[1] + r[3] && f64(at.y + size.y) > r[1] do return true
		}
		return false
	}
	snap :: proc(doc: ^LDtkDoc, level: int, p: ^[2]int, size: [2]int, axis, offset, at: int, dist: f64) {
		if abs(f64(p[axis] + offset - at)) > dist do return
		next := p^
		next[axis] = at - offset
		if !overlaps(doc, level, next, size) do p^ = next
	}
	for o in worldLevels(doc, world) {
		if o == level do continue
		or := LDtkDoc_LevelRect(doc, o)
		gap := max(max(0, f64(p.x) - (or[0] + or[2])) + max(0, or[0] - f64(p.x + size.x)), max(0, f64(p.y) - (or[1] + or[3])) + max(0, or[1] - f64(p.y + size.y)))
		if gap > dist do continue
		ox, oy, ow, oh := int(or[0]), int(or[1]), int(or[2]), int(or[3])
		for pass in 0 ..< 2 {
			snap(doc, level, &p, size, 0, 0, ox, dist)
			snap(doc, level, &p, size, 0, 0, ox + ow, dist)
			snap(doc, level, &p, size, 0, size.x, ox, dist)
			snap(doc, level, &p, size, 0, size.x, ox + ow, dist)
			if pass == 1 do break
			snap(doc, level, &p, size, 1, 0, oy, dist)
			snap(doc, level, &p, size, 1, 0, oy + oh, dist)
			snap(doc, level, &p, size, 1, size.y, oy, dist)
			snap(doc, level, &p, size, 1, size.y, oy + oh, dist)
		}
	}
	return p
}

// Project.getSmartLevelGridSize: the smallest grid of the layers that aren't entities'
@(private="file")
levelSmartGrid :: proc(doc: ^LDtkDoc) -> int {
	main := LDtkDoc_Main(doc)
	g := max(int)
	for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) {
		if Json_String(main, Json_Get(main, d, "type")) == "Entities" do continue
		g = min(g, max(Json_Int(main, Json_Get(main, d, "gridSize"), 16), 1))
	}
	return g == max(int) ? LDtkDoc_DefaultGrid(doc) : g
}

/*
A level drag's or a resize's release: the move (or, for a linear world, the new place in its
order; Ctrl + Alt: a copy there), the resize, or (a right click that didn't move) the canvas's menu.
Returns whether it was one of these.
*/
LevelWorld_Released :: proc(state: ^State) -> bool {
	drag := state.level.drag
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	if doc == nil || doc.problem != "" do return false
	#partial switch drag.mode {
	case .Resize:
		defer levelDragEnd(state)
		if !drag.moved do return true
		b, valid := LevelResize_Bounds(state, doc)
		level := LDtkDoc_FindLevel(doc, drag.target)
		if !valid || level < 0 do return true
		r := LDtkDoc_LevelRect(doc, level)
		if b == {0, 0, int(r[2]), int(r[3])} do return true
		levelApplyEdit(state, {op = .Level_Resized, file = file, level = strings.clone(drag.target, context.temp_allocator), number = f64(b[0]), number2 = f64(b[1]), number3 = f64(b[2] - b[0]), number4 = f64(b[3] - b[1])})
		return true
	case .Pan:
		if drag.menu && !drag.moved {
			// LDtk's world menu (WorldTool's right click)
			level := -1
			if drag.target != "" do level = LDtkDoc_FindLevel(doc, drag.target)
			state.contextMenu = {open = true, at = drag.at, target = Ctx_Level{level = level, world = drag.start, canvas = true}}
			levelDragEnd(state)
			return true
		}
	case .Level:
		if !drag.moved do return false
		defer levelDragEnd(state)
		level := LDtkDoc_FindLevel(doc, drag.target)
		if level < 0 do return true
		world := doc.levels[level].world
		layout := LDtkDoc_WorldLayout(doc, world)
		target := strings.clone(drag.target, context.temp_allocator)
		if layout == "LinearHorizontal" || layout == "LinearVertical" {
			levels := worldLevels(doc, world)
			cur := 0
			for l, i in levels do if l == level do cur = i
			r := LDtkDoc_LevelRect(doc, level)
			pointer := drag.start + drag.offset
			at, _ := linearInsertPoint(doc, world, {f64(pointer.x), f64(pointer.y)}, level, layout == "LinearHorizontal" ? r[0] : r[1])
			if at < 0 do return true
			to := at > cur ? at - 1 : at
			if drag.copy {
				levelApplyEdit(state, {op = .Level_Duplicated, file = file, level = target, text = LDtk_NewIid()})
			} else if to != cur {
				levelApplyEdit(state, {op = .Level_Sorted, file = file, level = target, number = f64(to)})
			}
			return true
		}
		to := LevelDrag_Target(state, doc)
		if drag.copy {
			copyIid := LDtk_NewIid()
			levelApplyEdit(state, {op = .Level_Duplicated, file = file, level = target, text = copyIid, number = f64(to.x), number2 = f64(to.y)})
			if state.level.problem == "" do if d := LDtkDoc_Get(state.project.rootPath, file); d != nil do if at := LDtkDoc_FindLevel(d, copyIid); at >= 0 {
				id, _ := LDtkDoc_LevelNames(d, at)
				levelSelect(state, file, strings.clone(id, context.temp_allocator))
			}
		} else {
			levelApplyEdit(state, {op = .Level_Moved, file = file, level = target, number = f64(to.x), number2 = f64(to.y)})
		}
		if state.level.problem != "" do logLine(state, .Warning, fmt.aprintf("Not moved: %s", state.level.problem))
		return true
	}
	return false
}

// The drag is over
@(private)
levelDragEnd :: proc(state: ^State) {
	delete(state.level.drag.target)
	state.level.drag = {}
}

/*
The world tools' undo steps (History_Classify): a new level's spot clicked, a resize's release, a
level drag's (moved, sorted, copied). Level steps hold the project too: renames reach the scenes.
*/
LevelWorld_Classify :: proc(s: ^State, m: Msg) -> (EditInfo, bool) {
	file := LevelMode_File(s)
	#partial switch v in m {
	case Level_Canvas_Pressed:
		if s.level.spot && !v.right && !v.pan do return {scope = .Files, ldtkFile = file, label = "Add a level", withProject = true}, true
	case Level_Canvas_Released:
		drag := s.level.drag
		#partial switch drag.mode {
		case .Resize:
			if drag.moved do return {scope = .Files, ldtkFile = file, label = "Resize a level", withProject = true}, true
		case .Level:
			if !drag.moved do break
			label := drag.copy ? "Copy a level in the world" : "Move a level in the world"
			return {scope = .Files, ldtkFile = file, label = label, withProject = true}, true
		}
	case Level_Depth_Shown:
		if v.moveLevel do return {scope = .Files, ldtkFile = file, label = "Change a level's depth", withProject = true}, true
	case Action:
		if v == .Level_Move_Further || v == .Level_Move_Closer do return {scope = .Files, ldtkFile = file, label = "Change a level's depth", withProject = true}, true
	}
	return {}, false
}

/*
The world tools' messages: picking a new level's spot, the world depth shown or a level moved to
another depth. Returns whether `m` was one.
*/
LevelWorld_Update :: proc(state: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case Level_Spot_Started:
		state.level.spot = !v.cancel
		if state.level.spot do levelFocus(state, "")
	case Action:
		#partial switch v {
		case .Level_Depth_Further: return LevelWorld_Update(state, Level_Depth_Shown{step = 1})
		case .Level_Depth_Closer:  return LevelWorld_Update(state, Level_Depth_Shown{step = -1})
		case .Level_Move_Further:  return LevelWorld_Update(state, Level_Depth_Shown{step = 1, moveLevel = true})
		case .Level_Move_Closer:   return LevelWorld_Update(state, Level_Depth_Shown{step = -1, moveLevel = true})
		}
		return false
	case Level_Depth_Shown:
		doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
		if doc == nil || doc.problem != "" do return true
		if v.moveLevel {
			if state.level.level == "" do return true
			level := LDtkDoc_FindLevel(doc, state.level.level)
			if level < 0 do return true
			_, iid := LDtkDoc_LevelNames(doc, level)
			levelApplyEdit(state, {op = .Level_Depth, file = LevelMode_File(state), level = strings.clone(iid, context.temp_allocator), number = f64(v.step)})
			if doc = LDtkDoc_Get(state.project.rootPath, LevelMode_File(state)); doc != nil {
				if at := LDtkDoc_FindLevel(doc, iid); at >= 0 do state.level.depth = LDtkDoc_LevelDepth(doc, at)
			}
			return true
		}
		lo, hi := LevelMode_Depths(state, doc)
		state.level.depth = clamp(LevelMode_Depth(state, doc) + v.step, lo, hi)
		// LDtk shows the world to change depth
		levelFocus(state, "")
	case:
		return false
	}
	return true
}

/*
The canvas's world menu (LDtk's WorldTool right click): New Level Here; on a level Focus,
Duplicate, Delete, Move to another world; with several worlds, Go to another world.
*/
LevelWorld_MenuItems :: proc(s: ^State, items: ^[dynamic]skald.Menu_Item(Msg), t: Ctx_Level) {
	file := LevelMode_File(s)
	doc := LDtkDoc_Get(s.project.rootPath, file)
	if doc == nil || doc.problem != "" do return
	f := strings.clone(file, context.temp_allocator)
	world := LevelMode_World(s, doc)
	append(items, skald.Menu_Item(Msg){label = "New Level Here", msg = Msg(LDtk_Edit{op = .Level_Added, file = f, world = world, number = f64(t.world.x), number2 = f64(t.world.y),
		index = LevelMode_Depth(s, doc), flag = !s.level.paint.noGrid, text = LDtk_NewIid()})})
	append(items, skald.Menu_Item(Msg){label = "Pick a Spot for a New Level", msg = Msg(Level_Spot_Started{})})
	if t.level >= 0 && t.level < len(doc.levels) {
		append(items, MENU_SEPARATOR)
		levelMenuEdits(s, items, doc, t.level)
	}
	if len(doc.worlds) > 1 && (t.level < 0 || t.level >= len(doc.levels)) {
		goTo := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
		for _, w in doc.worlds {
			name, iid := LDtkDoc_WorldNames(doc, w)
			append(&goTo, skald.Menu_Item(Msg){label = fmt.tprintf("%s (%d levels)", name, len(worldLevels(doc, w))), msg = Msg(Level_World_Chosen(strings.clone(iid, context.temp_allocator))), disabled = w == world})
		}
		append(items, MENU_SEPARATOR, skald.Menu_Item(Msg){label = "Go to World", submenu = goTo[:]})
	}
}

/*
A level's edits in its menus (the Levels sidebar's, the canvas's): Rename (the Level tab's name),
Duplicate, Delete, a depth further or closer, Move to another world.
*/
@(private)
levelMenuEdits :: proc(s: ^State, items: ^[dynamic]skald.Menu_Item(Msg), doc: ^LDtkDoc, level: int) {
	file := strings.clone(LevelMode_File(s), context.temp_allocator)
	_, iid := LDtkDoc_LevelNames(doc, level)
	l := strings.clone(iid, context.temp_allocator)
	world := doc.levels[level].world
	last := len(worldLevels(doc, world)) <= 1
	further, closer := LDtkDoc_LevelDepthMoves(doc, level)
	append(items,
		skald.Menu_Item(Msg){label = "Rename (the Level tab)", msg = Msg(Level_Rename_Started(l))},
		skald.Menu_Item(Msg){label = "Duplicate", msg = Msg(LDtk_Edit{op = .Level_Duplicated, file = file, level = l, flag = true, text = LDtk_NewIid()})},
		skald.Menu_Item(Msg){label = last ? "Delete (a world keeps one level)" : "Delete", msg = Msg(LDtk_Edit{op = .Level_Removed, file = file, level = l}), disabled = last},
		skald.Menu_Item(Msg){label = "Move a Depth Further", msg = Msg(LDtk_Edit{op = .Level_Depth, file = file, level = l, number = 1}), disabled = !further},
		skald.Menu_Item(Msg){label = "Move a Depth Closer", msg = Msg(LDtk_Edit{op = .Level_Depth, file = file, level = l, number = -1}), disabled = !closer},
	)
	if len(doc.worlds) > 1 {
		to := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
		for _, w in doc.worlds {
			name, _ := LDtkDoc_WorldNames(doc, w)
			append(&to, skald.Menu_Item(Msg){label = fmt.tprintf("%s %s (%d levels)", ICON_ARROW_RIGHT, name, len(worldLevels(doc, w))), msg = Msg(LDtk_Edit{op = .Level_World_Moved, file = file, level = l, world = w}), disabled = w == world})
		}
		append(items, skald.Menu_Item(Msg){label = "Move to World", submenu = to[:]})
	}
}

// Rename a level: the Level tab shows it, its name field focused (a level's iid; the frame's string)
Level_Rename_Started :: distinct string

// The pointer over a resize handle
LevelResize_Cursor :: proc(h: LevelResizeHandle) -> skald.Cursor_Shape {
	#partial switch h {
	case .Top, .Bottom: return .NS_Resize
	case .Left, .Right: return .EW_Resize
	case .Top_Left, .Bottom_Right: return .NWSE_Resize
	case .Top_Right, .Bottom_Left: return .NESW_Resize
	}
	return .Default
}

// What the world tools draw over the canvas (screen pixels; temp)
LevelWorldOverlay :: struct {
	// The focused level's handles (Rulers), its size label
	handles: [8][2]f32,
	handleCount: int,
	sizeLabel: string,
	sizeAt: [2]f32,
	// A resize's new bounds and whether they're valid
	resize: [4]f32,
	resizing, resizeValid: bool,
	// A new level's spot (LevelSpotPicker), whether it overlaps
	spot: [4]f32,
	spotShown, spotOverlaps: bool,
	// A linear world's insertion line (WorldTool's drag)
	line: [2][2]f32,
	lineShown: bool,
}

/*
The world tools' overlay for the canvas's view (`hover`: the world point under the pointer).
*/
LevelWorldOverlay_Build :: proc(state: ^State, doc: ^LDtkDoc, hover: Maybe([2]f32), center: [2]f32, zoom: f32, size: [2]f32) -> ^LevelWorldOverlay {
	o := new(LevelWorldOverlay, context.temp_allocator)
	toScreen :: proc(p, center: [2]f32, zoom: f32, size: [2]f32) -> [2]f32 { return size * 0.5 + (p - center) * zoom }
	any := false
	// The focused level's handles and size (Rulers)
	if state.level.focus != "" && !state.level.spot {
		if level := LDtkDoc_FindLevel(doc, state.level.focus); level >= 0 {
			r := LDtkDoc_LevelRect(doc, level)
			for h in LevelResizeHandle {
				if h == .None do continue
				at := LevelResize_HandlePos(h, {r[2], r[3]})
				o.handles[o.handleCount] = toScreen({f32(r[0] + at.x), f32(r[1] + at.y)}, center, zoom, size)
				o.handleCount += 1
			}
			cells := ""
			if def := LevelMode_LayerDef(state, doc); def >= 0 {
				main := LDtkDoc_Main(doc)
				g := max(Json_Int(main, Json_Get(main, def, "gridSize"), 16), 1)
				cells = fmt.tprintf("%d x %d cells, ", int(math.ceil(r[2] / f64(g))), int(math.ceil(r[3] / f64(g))))
			}
			o.sizeLabel = fmt.tprintf("%s%.0f x %.0f px", cells, r[2], r[3])
			o.sizeAt = toScreen({f32(r[0] + r[2] * 0.5), f32(r[1] + r[3] + 12)}, center, zoom, size)
			any = true
			if state.level.drag.mode == .Resize && state.level.drag.moved {
				b, valid := LevelResize_Bounds(state, doc)
				p := toScreen({f32(r[0]) + f32(b[0]), f32(r[1]) + f32(b[1])}, center, zoom, size)
				o.resize = {p.x, p.y, f32(b[2] - b[0]) * zoom, f32(b[3] - b[1]) * zoom}
				o.resizing, o.resizeValid = true, valid
				o.sizeLabel = fmt.tprintf("%d x %d px", b[2] - b[0], b[3] - b[1])
			}
		}
	}
	// A new level's spot under the pointer
	if state.level.spot {
		if p, ok := hover.?; ok {
			spot := LDtk_LevelSpot(doc, LevelMode_World(state, doc), {f64(p.x), f64(p.y)}, LevelMode_Depth(state, doc), !state.level.paint.noGrid)
			if spot.ok {
				a := toScreen({f32(spot.x), f32(spot.y)}, center, zoom, size)
				o.spot = {a.x, a.y, f32(spot.w) * zoom, f32(spot.h) * zoom}
				o.spotShown, o.spotOverlaps = true, spot.overlaps
				any = true
			}
		}
	}
	// A linear world's drag: where the level would go
	drag := state.level.drag
	if drag.mode == .Level && drag.moved {
		if level := LDtkDoc_FindLevel(doc, drag.target); level >= 0 {
			world := doc.levels[level].world
			layout := LDtkDoc_WorldLayout(doc, world)
			if layout == "LinearHorizontal" || layout == "LinearVertical" {
				r := LDtkDoc_LevelRect(doc, level)
				pointer := drag.start + drag.offset
				at, coord := linearInsertPoint(doc, world, {f64(pointer.x), f64(pointer.y)}, level, layout == "LinearHorizontal" ? r[0] : r[1])
				if at >= 0 {
					extent: f64 = 0
					for l in worldLevels(doc, world) {
						lr := LDtkDoc_LevelRect(doc, l)
						extent = max(extent, layout == "LinearHorizontal" ? lr[1] + lr[3] : lr[0] + lr[2])
					}
					if layout == "LinearHorizontal" {
						o.line = {toScreen({f32(coord), -100}, center, zoom, size), toScreen({f32(coord), f32(extent + 100)}, center, zoom, size)}
					} else {
						o.line = {toScreen({-100, f32(coord)}, center, zoom, size), toScreen({f32(extent + 100), f32(coord)}, center, zoom, size)}
					}
					o.lineShown = true
					any = true
				}
			}
		}
	}
	return any ? o : nil
}

// Draws the world tools' overlay (in the canvas's painter)
LevelWorldOverlay_Draw :: proc(r: ^skald.Renderer, b: skald.Rect, o: ^LevelWorldOverlay, fg, accent, bg: skald.Color, fontSize: f32) {
	origin := [2]f32{b.x, b.y}
	for i in 0 ..< o.handleCount {
		skald.draw_circle(r, origin + o.handles[i], 5, fg, aa = true)
		skald.draw_ring(r, origin + o.handles[i], 5, 1, bg)
	}
	if o.resizing {
		// LDtk's preview: yellow, red when too small
		color := o.resizeValid ? skald.rgb(0xFFCC00) : skald.rgb(0xFF0000)
		skald.draw_rect_outline(r, {b.x + o.resize[0], b.y + o.resize[1], o.resize[2], o.resize[3]}, 3, color)
	}
	if o.sizeLabel != "" && o.handleCount > 0 {
		w := f32(len(o.sizeLabel)) * fontSize * 0.6 + 8
		at := origin + o.sizeAt - {w * 0.5, 0}
		skald.draw_rect(r, {at.x, at.y, w, fontSize + 6}, {bg.r, bg.g, bg.b, 0.8})
		drawTextTop(r, o.sizeLabel, at.x + 4, at.y + 3, fg, fontSize)
	}
	if o.spotShown {
		// LDtk's colors: blue where it fits, orange-red where it doesn't
		c := o.spotOverlaps ? skald.rgb(0xFF4400) : skald.rgb(0x8DCBFB)
		rect := skald.Rect{b.x + o.spot[0], b.y + o.spot[1], o.spot[2], o.spot[3]}
		skald.draw_rect(r, rect, {c.r, c.g, c.b, 0.3})
		skald.draw_rect_outline(r, rect, 2, {c.r, c.g, c.b, 0.7})
		mid := [2]f32{rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
		arm := min(rect.w, rect.h) * 0.2
		skald.draw_line(r, mid - {0, arm}, mid + {0, arm}, 4, c, aa = true)
		skald.draw_line(r, mid - {arm, 0}, mid + {arm, 0}, 4, c, aa = true)
	}
	if o.lineShown {
		skald.draw_line(r, origin + o.line[0], origin + o.line[1], 4, skald.Color{0.45, 1, 1, 0.6}, aa = true)
	}
}
