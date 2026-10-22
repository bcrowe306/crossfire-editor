package crossfire_editor

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import e "engine:."
import "gui:skald"

/*
Viewport tools beyond picking and the gizmos: aligning and distributing the selection, the Zoom
tool's clicks and boxes, and guides.

**Align and distribute** (`Align_Nodes`, a `.Scene` undo step): the selection's roots line up by
their bounds as the viewport draws them (`Viewport_NodeShapes`: what they draw, turned and scaled;
a node that draws nothing is its origin). Left / Center / Right / Top / Middle / Bottom move each
to the selection's edge or middle; Distribute leaves the outermost two where they are and spaces
the others so the gaps between them are equal. Moves are in the world, turned into each node's
parent space. The node menus (context_menus.odin) and the viewport header's buttons (shown with
two or more nodes selected) send it.

**Guides** (`SceneDef.guides`): lines across the viewport at a world x (vertical) or y
(horizontal), dragged out of the rulers (view_viewport.odin's guide drag), moved by dragging,
removed by dragging them back onto a ruler or from their menu. With snapping on, a dragged node's
origin snaps to a guide within `GUIDE_SNAP_PIXELS`. Editor-only: kept per scene in the project's
`.editor/guides.ini` (`Guides_Save`, `Guides_Load`), not undo steps.
*/

// How `Align_Nodes` lines up the selection
AlignOp :: enum {
	Left,
	Center,
	Right,
	Top,
	Middle,
	Bottom,
	Distribute_Horizontally,
	Distribute_Vertically,
}

// Aligns or distributes the selection's roots
Align_Nodes :: struct {
	op: AlignOp,
}

// What an align does, for menus and undo ("Align left")
AlignOp_Label :: proc(op: AlignOp) -> string {
	switch op {
	case .Left:                    return "Align left"
	case .Center:                  return "Align centers"
	case .Right:                   return "Align right"
	case .Top:                     return "Align tops"
	case .Middle:                  return "Align middles"
	case .Bottom:                  return "Align bottoms"
	case .Distribute_Horizontally: return "Distribute across"
	case .Distribute_Vertically:   return "Distribute down"
	}
	return ""
}

/*
The Align and Distribute submenu's items for the selection: none with fewer than two nodes;
distributing needs three.
*/
ViewportTools_AlignItems :: proc(s: ^State) -> []skald.Menu_Item(Msg) {
	roots := Selection_Roots(s)
	if len(roots) < 2 do return nil
	items := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
	append(&items,
		msgItem("Left Edges", Msg(Align_Nodes{.Left})),
		msgItem("Centers", Msg(Align_Nodes{.Center})),
		msgItem("Right Edges", Msg(Align_Nodes{.Right})),
		MENU_SEPARATOR,
		msgItem("Top Edges", Msg(Align_Nodes{.Top})),
		msgItem("Middles", Msg(Align_Nodes{.Middle})),
		msgItem("Bottom Edges", Msg(Align_Nodes{.Bottom})),
		MENU_SEPARATOR,
		msgItem("Distribute Across", Msg(Align_Nodes{.Distribute_Horizontally}), disabled = len(roots) < 3),
		msgItem("Distribute Down", Msg(Align_Nodes{.Distribute_Vertically}), disabled = len(roots) < 3))
	return items[:]
}

// More items for the viewport's empty-space menu
ViewportTools_ViewportItems :: proc(s: ^State, items: ^MenuItems) {
	if align := ViewportTools_AlignItems(s); len(align) > 0 {
		append(items, MENU_SEPARATOR, submenuItem("Align and Distribute", align))
	}
}

/*
The viewport tools' messages; true when `m` was one.
*/
ViewportTools_Update :: proc(state: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case Guide_Added:
		append(&state.project.scenes[state.currentScene].guides, Guide{vertical = v.vertical, at = math_tidy(v.at)})
		state.viewport.guidesHidden = false
		return true
	case Guide_Moved:
		guides := &state.project.scenes[state.currentScene].guides
		if v.index >= 0 && v.index < len(guides) do guides[v.index].at = math_tidy(v.at)
		return true
	case Guide_Removed:
		guides := &state.project.scenes[state.currentScene].guides
		if int(v) >= 0 && int(v) < len(guides) do ordered_remove(guides, int(v))
		return true
	case Guides_Cleared:
		clear(&state.project.scenes[state.currentScene].guides)
		return true
	case Align_Nodes:
		scene := &state.project.scenes[state.currentScene]
		roots := Selection_Roots(state)
		boxes := make([]AlignBox, len(roots), context.temp_allocator)
		shapes := Viewport_NodeShapes(state, scene)
		for r, i in roots do boxes[i] = alignBox(shapes[r])
		moves := Align_Moves(boxes, v.op)
		transforms := Scene_WorldTransforms(scene)
		for r, i in roots {
			if moves[i] == {} do continue
			node := &scene.nodes[r]
			parentWorld := node.parent >= 0 ? transforms[node.parent] : e.TRANSFORM2D_IDENTITY
			local := e.Transform2D_ApplyVector(e.Transform2D_Inverse(parentWorld), moves[i])
			node.position = {math_tidy(node.position.x + local.x), math_tidy(node.position.y + local.y)}
		}
		return true
	}
	return false
}

// A node's box in the world: its drawn bounds, or its origin when it draws nothing
AlignBox :: struct {
	min, max: [2]f32,
}

@(private="file")
alignBox :: proc(shape: NodeShape) -> AlignBox {
	if !shape.hasBounds {
		origin := e.Transform2D_Apply(shape.world, {0, 0})
		return {origin, origin}
	}
	box := AlignBox{shape.corners[0], shape.corners[0]}
	corners := shape.corners
	for c in corners[1:] {
		box.min = {min(box.min.x, c.x), min(box.min.y, c.y)}
		box.max = {max(box.max.x, c.x), max(box.max.y, c.y)}
	}
	return box
}

/*
How far each box moves (world) to align or distribute them, in their order.

Example:
	moves := Align_Moves({{{0, 0}, {10, 10}}, {{30, 5}, {50, 15}}}, .Left)
	// moves[1] == {-30, 0}
*/
Align_Moves :: proc(boxes: []AlignBox, op: AlignOp) -> [][2]f32 {
	moves := make([][2]f32, len(boxes), context.temp_allocator)
	if len(boxes) < 2 do return moves
	lo, hi := boxes[0].min, boxes[0].max
	for b in boxes {
		lo = {min(lo.x, b.min.x), min(lo.y, b.min.y)}
		hi = {max(hi.x, b.max.x), max(hi.y, b.max.y)}
	}
	middle := (lo + hi) * 0.5
	for b, i in boxes {
		center := (b.min + b.max) * 0.5
		#partial switch op {
		case .Left:   moves[i].x = lo.x - b.min.x
		case .Right:  moves[i].x = hi.x - b.max.x
		case .Center: moves[i].x = middle.x - center.x
		case .Top:    moves[i].y = lo.y - b.min.y
		case .Bottom: moves[i].y = hi.y - b.max.y
		case .Middle: moves[i].y = middle.y - center.y
		}
	}
	if (op != .Distribute_Horizontally && op != .Distribute_Vertically) || len(boxes) < 3 do return moves
	axis := op == .Distribute_Horizontally ? 0 : 1
	// In order along the axis (by their starts); the first and last stay
	order := make([]int, len(boxes), context.temp_allocator)
	for &o, i in order do o = i
	Sorter :: struct { boxes: []AlignBox, axis: int }
	context.user_ptr = &Sorter{boxes, axis}
	slice.sort_by(order, proc(a, b: int) -> bool {
		sorter := (^Sorter)(context.user_ptr)
		return sorter.boxes[a].min[sorter.axis] < sorter.boxes[b].min[sorter.axis]
	})
	first, last := boxes[order[0]], boxes[order[len(order) - 1]]
	sizes := f32(0)
	for b in boxes do sizes += b.max[axis] - b.min[axis]
	gap := ((last.max[axis] - first.min[axis]) - sizes) / f32(len(boxes) - 1)
	at := first.min[axis]
	for i in order {
		b := boxes[i]
		moves[i][axis] = at - b.min[axis]
		at += (b.max[axis] - b.min[axis]) + gap
	}
	return moves
}

/*
The Zoom tool's drag, ended: a click (a box under 4 px across on screen) zooms in two times
where it was (`drag.additive`, Alt held: out); a box fits the view to it.
*/
ViewportTools_ZoomBox :: proc(v: ^ViewportState, drag: ViewportDrag) {
	lo := [2]f32{min(drag.startMouse.x, drag.current.x), min(drag.startMouse.y, drag.current.y)}
	hi := [2]f32{max(drag.startMouse.x, drag.current.x), max(drag.startMouse.y, drag.current.y)}
	size := (hi - lo) * v.zoom
	if size.x < 4 && size.y < 4 {
		Viewport_ZoomAt(v, drag.additive ? 0.5 : 2, drag.startMouse)
		return
	}
	Viewport_FitRect(v, {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y})
}

// A guide line: vertical at x = `at`, or horizontal at y = `at` (world units)
Guide :: struct {
	vertical: bool,
	at: f32,
}

// A guide dragged out of a ruler and dropped in the view
Guide_Added :: struct {
	vertical: bool,
	at: f32,
}
// A guide dragged to `at`
Guide_Moved :: struct {
	index: int,
	at: f32,
}
// A guide dragged back onto a ruler, or removed from its menu
Guide_Removed :: distinct int
// Every guide of the open scene removed
Guides_Cleared :: struct {}

// How near (screen pixels) a dragged node's origin snaps to a guide
GUIDE_SNAP_PIXELS :: 8
// Where guides are kept, relative to the project
GUIDES_FILE :: ".editor/guides.ini"

/*
Snaps a dragged node's world origin to the scene's nearest guides within `reach` (world units):
a vertical guide its x, a horizontal one its y (an axis-constrained move keeps the other).
*/
Guides_SnapNode :: proc(scene: ^SceneDef, node: int, reach: f32, mode: DragMode) {
	world := Scene_WorldTransforms(scene)
	at := world[node].origin
	snapped := Guides_Snap(scene.guides[:], at, reach)
	if mode == .Move_X do snapped.y = at.y
	if mode == .Move_Y do snapped.x = at.x
	if snapped == at do return
	n := &scene.nodes[node]
	parentWorld := n.parent >= 0 ? world[n.parent] : e.TRANSFORM2D_IDENTITY
	n.position = e.Transform2D_Apply(e.Transform2D_Inverse(parentWorld), snapped)
}

/*
A world point moved onto the nearest guides within `reach`: x onto a vertical guide, y onto a
horizontal one.

Example:
	p := Guides_Snap({{vertical = true, at = 100}}, {97, 40}, 5) // {100, 40}
*/
Guides_Snap :: proc(guides: []Guide, point: [2]f32, reach: f32) -> [2]f32 {
	out := point
	best := [2]f32{reach, reach}
	for g in guides {
		axis := g.vertical ? 0 : 1
		if d := abs(point[axis] - g.at); d <= best[axis] {
			best[axis] = d
			out[axis] = g.at
		}
	}
	return out
}

/*
Writes every scene's guides to `.editor/guides.ini` (when there are any, or the file is there).
Returns "" or what went wrong.
*/
Guides_Save :: proc(project: ^Project) -> string {
	path, _ := filepath.join({project.rootPath, GUIDES_FILE}, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	any := false
	for &scene in project.scenes {
		if len(scene.guides) == 0 do continue
		any = true
		fmt.sbprintf(&b, "[%s]\n", Scene_IsComponent(&scene) ? scene.component : scene.name)
		for g in scene.guides do fmt.sbprintf(&b, "%s = %v\n", g.vertical ? "x" : "y", g.at)
	}
	if !any && !os.exists(path) do return ""
	_ = os.make_directory_all(filepath.dir(path))
	text := strings.to_string(b)
	if old, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(old) == text do return ""
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil do return fmt.tprintf("Couldn't write %s: %v", path, err)
	return ""
}

// Reads `.editor/guides.ini` into the project's scenes (missing or unreadable: none)
Guides_Load :: proc(project: ^Project) {
	path, _ := filepath.join({project.rootPath, GUIDES_FILE}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	it := ini.iterator_from_string(string(data))
	for key, value in ini.iterate(&it) {
		scene: ^SceneDef
		for &s in project.scenes do if s.name == it.section || (s.component != "" && s.component == it.section) do scene = &s
		at, ok := strconv.parse_f32(strings.trim_space(value))
		if scene == nil || !ok || (key != "x" && key != "y") do continue
		append(&scene.guides, Guide{vertical = key == "x", at = at})
	}
}

_ :: fmt
