package crossfire_editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:time"
import e "engine:."
import "gui:skald"

/*
The Animation panel's logic (its view is view_animation.odin): animations, which are named ranges
of the cells of their own sprite sheets (`AnimationDef`: a sheet cut into columns x rows, or into
cells of a size, with a margin and gaps), each with a speed (or each frame's duration), looping
and a play mode, and which one plays first. They're the panel's source (`AnimSource`,
animation_sets_edit.odin): the selected AnimatedSprite's own, the animation asset it uses, or the
one the browser shows in the panel (`AnimEditor.asset`); an Aseprite file's are read only.

Edits are `.Node` undo steps on a node's own animations, `.Project` steps on an asset's
(History_Classify). The panel's own state (`AnimEditor`: which animation is selected, the
preview's clock, a half-typed name) isn't undoable.
*/

// The autoplay choice meaning "the first animation" (stored as "")
ANIMATION_FIRST :: "(first)"
// The Animations choice meaning "its own animations" (no animation asset; stored as "")
ANIMATION_OWN :: "(its own)"
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
	// The animation asset the panel shows, chosen in the browser (its path, owned; "": the
	// selected AnimatedSprite's)
	asset: string,
}

/*
The Animation panel's source (`AnimEdit_Source`) and its selected animation (the selection clamped
to the list).

Returns:
- The source (kind .None: nothing to show), the animation (nil if there's none), its index
*/
AnimEdit_Selection :: proc(s: ^State) -> (src: AnimSource, animation: ^AnimationDef, index: int) {
	src = AnimEdit_Source(s)
	if src.kind == .None || len(src.animations^) == 0 do return src, nil, -1
	index = clamp(s.animEditor.selected, 0, len(src.animations^) - 1)
	return src, &src.animations[index], index
}

/*
How many cells an animation's sheet has: its grid on the image (`e.SheetGrid_CellCount`; a grid of
cell sizes needs the image's size, `Image_Size`, read once per file time).

Inputs:
- root: The project folder
- animation: The animation

Returns:
- The cells (at least 1)
*/
AnimEdit_Cells :: proc(root: string, animation: AnimationDef) -> int {
	return e.SheetGrid_CellCount(animation.grid, AnimEdit_SheetSize(root, animation.sheet))
}

// An animation's sheet's size in pixels (0 when it has none or it can't be read)
AnimEdit_SheetSize :: proc(root, sheet: string) -> [2]f32 {
	if sheet == "" do return {}
	size, _ := Image_Size(joinPath(root, sheet, allocator = context.temp_allocator))
	return {f32(size.x), f32(size.y)}
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
	backwards := animation.playMode == .Reverse || animation.playMode == .PingPongReverse
	if (animation.fps <= 0 && len(animation.durations) == 0) || count <= 1 do return backwards ? end : start
	step := AnimationDef_StepAt(animation, count, t)
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
	case .PingPongReverse:
		cycle := 2 * (count - 1)
		at := animation.loop ? step % cycle : min(step, cycle)
		return end - (at < count ? at : cycle - at)
	}
	return start
}

/*
How many frame steps an animation has taken `t` seconds after it starts: at its fps, or by its
frames' durations (each step the duration of the frame it leaves, as the engine's player does).
*/
AnimationDef_StepAt :: proc(animation: AnimationDef, count: int, t: f64) -> int {
	if len(animation.durations) == 0 do return int(math.floor(max(t, 0) * f64(animation.fps)))
	// The frames a forward pass visits, in order: their durations repeat for the steps after
	durationOf :: proc(animation: AnimationDef, frame: int) -> f64 {
		if frame >= 0 && frame < len(animation.durations) && animation.durations[frame] > 0 do return f64(animation.durations[frame])
		return animation.fps > 0 ? 1 / f64(animation.fps) : 0.1
	}
	step := 0
	left := max(t, 0)
	// Long enough for any preview: it stops after 100000 steps
	for step < 100000 {
		frame := step % count
		#partial switch animation.playMode {
		case .Reverse: frame = count - 1 - step % count
		case .PingPong, .PingPongReverse:
			cycle := max(2 * (count - 1), 1)
			at := step % cycle
			frame = at < count ? at : cycle - at
			if animation.playMode == .PingPongReverse do frame = count - 1 - frame
		}
		d := durationOf(animation, frame)
		if left < d do break
		left -= d
		step += 1
	}
	return step
}

// A name no other animation of the list has: "walk", "walk2", "walk3", ...
AnimEdit_UniqueName :: proc(animations: []AnimationDef, base: string) -> string {
	taken :: proc(animations: []AnimationDef, name: string) -> bool {
		for a in animations do if a.name == name do return true
		return false
	}
	if !taken(animations, base) do return strings.clone(base)
	root := strings.trim_right(base, "0123456789")
	for n := 2; ; n += 1 {
		name := fmt.tprintf("%s%d", root, n)
		if !taken(animations, name) do return strings.clone(name)
	}
}

// Why a name can't be the selected animation's ("" if it can)
AnimEdit_NameProblem :: proc(animations: []AnimationDef, index: int, name: string) -> string {
	if strings.trim_space(name) == "" do return "Give it a name"
	if strings.trim_space(name) != name do return "No spaces at the ends"
	for a, i in animations do if i != index && a.name == name do return "Another animation has that name"
	return ""
}

// Whether a message edits what the Animation panel shows (for History_Classify)
AnimEdit_IsEdit :: proc(m: Msg) -> bool {
	#partial switch v in m {
	case Anim_Added, Anim_Duplicated, Anim_Removed, Anim_Moved, Anim_Name_Typed, Anim_Field_Changed, Anim_Loop_Changed, Anim_Mode_Changed,
	     Anim_Autoplay_Set, Anim_Frame_Clicked, Anim_Sheet_Texture_Changed, Anim_Sheet_Dropped, Anim_Grid_Mode_Changed:
		return true
	case Number_Text_Changed:
		_, isAnim := v.target.(AnimField)
		return isAnim
	}
	return false
}

/*
Handles the Animation panel's messages.

Returns:
- A command (the preview's next frame), and whether `m` was one of the panel's messages
*/
AnimEdit_Update :: proc(s: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	ed := &s.animEditor
	src, animation, index := AnimEdit_Selection(s)
	restart :: proc(ed: ^AnimEditor) { ed.clock = 0 }
	// An image dropped on the panel: the drag ends either way
	dropped := ""
	if _, isDrop := m.(Anim_Sheet_Dropped); isDrop {
		asset := s.assetDrag.asset
		s.assetDrag = {}
		if asset >= 0 && asset < len(s.project.assets) && s.project.assets[asset].kind == .Image do dropped = s.project.assets[asset].path
	}
	// An Aseprite file's animations are read only (edited in Aseprite)
	if src.readOnly && AnimEdit_IsEdit(m) do return {}, true
	list := src.animations
	autoplay := src.autoplay

	#partial switch v in m {
	case Anim_Selected:
		ed.selected = int(v)
		restart(ed)
	case Anim_Set_From_Node:
		// The sprite's own animations (and their sheets) become an asset it uses (the file isn't undone)
		if src.kind != .Node do break
		node := src.node
		at, problem := Project_CreateAnimationSet(&s.project, node.name, AnimationSet_OfNode(node))
		if at < 0 {
			logLine(s, .Error, fmt.aprintf("Couldn't save the animations of %s: %s", node.name, problem))
			break
		}
		path := s.project.animationSets[at].path
		delete(node.animationSet)
		node.animationSet = strings.clone(path)
		for &a in node.animations do AnimationDef_Destroy(&a)
		clear(&node.animations)
		delete(node.autoplay)
		node.autoplay = strings.clone("")
		logLine(s, .Info, fmt.aprintf("Saved the animations of %s as %s, which it plays now", node.name, path))
	case Anim_Set_New:
		at, problem := Project_CreateAnimationSet(&s.project, "animations", AnimationSetDef{})
		if at < 0 {
			logLine(s, .Error, fmt.aprintf("Couldn't make the animations: %s", problem))
			break
		}
		path := s.project.animationSets[at].path
		logLine(s, .Info, fmt.aprintf("Made %s: pick its animation's sheet in the Animation panel", path))
		delete(ed.asset)
		ed.asset = strings.clone(path)
		ed.selected = 0
		s.bottomTab = .Animation
		s.layout.bottomOpen = true
	case Anim_Asset_Shown:
		// The browser's animation asset in the panel ("": back to the selected sprite's)
		delete(ed.asset)
		ed.asset = strings.clone(string(v))
		ed.selected = 0
		restart(ed)
		if ed.asset != "" {
			s.bottomTab = .Animation
			s.layout.bottomOpen = true
		}
	case Anim_Added:
		if src.kind == .None do break
		// Every frame of the sheet the selected animation uses (its grid too)
		added := animation != nil ? AnimationDef_Default(sheet = animation.sheet, grid = animation.grid) : AnimationDef_Default()
		delete(added.name)
		added.name = AnimEdit_UniqueName(list[:], "animation")
		append(list, added)
		ed.selected = len(list) - 1
		restart(ed)
	case Anim_Duplicated:
		if animation == nil do break
		twin := AnimationDef_Clone(animation^)
		delete(twin.name)
		twin.name = AnimEdit_UniqueName(list[:], animation.name)
		inject_at(list, index + 1, twin)
		ed.selected = index + 1
		restart(ed)
	case Anim_Removed:
		// A sprite keeps one animation
		if animation == nil || len(list) <= 1 do break
		if autoplay^ == animation.name {
			delete(autoplay^)
			autoplay^ = strings.clone("")
		}
		AnimationDef_Destroy(animation)
		ordered_remove(list, index)
		ed.selected = min(index, len(list) - 1)
		restart(ed)
	case Anim_Moved:
		if animation == nil do break
		to := index + int(v)
		if to < 0 || to >= len(list) do break
		list[index], list[to] = list[to], list[index]
		ed.selected = to
	case Anim_Name_Typed:
		delete(ed.nameText)
		ed.nameId, ed.nameText = v.id, strings.clone(v.text)
		if animation == nil || AnimEdit_NameProblem(list[:], index, v.text) != "" do break
		// The autoplay setting follows the rename
		if autoplay^ == animation.name {
			delete(autoplay^)
			autoplay^ = strings.clone(v.text)
		}
		delete(animation.name)
		animation.name = strings.clone(v.text)
	case Anim_Sheet_Texture_Changed:
		// The selected animation's sheet
		if animation == nil do break
		delete(animation.sheet)
		animation.sheet = strings.clone(string(v) == TEXTURE_NONE ? "" : string(v))
		restart(ed)
	case Anim_Sheet_Dropped:
		if animation == nil || dropped == "" do break
		delete(animation.sheet)
		animation.sheet = strings.clone(dropped)
		logLine(s, .Info, fmt.aprintf("%s plays on %s now", animation.name, filepath.base(dropped)))
		restart(ed)
	case Anim_Grid_Mode_Changed:
		// The other mode's values from the image, so the cells stay where they are
		if animation == nil do break
		mode, ok := reflect.enum_from_name(e.SheetGridMode, string(v))
		if !ok || mode == animation.grid.mode do break
		columns, rows, cell := e.SheetGrid_Layout(animation.grid, AnimEdit_SheetSize(s.project.rootPath, animation.sheet))
		// Only the mode's own values are kept (as a file keeps them)
		animation.grid.mode = mode
		switch mode {
		case .Cells:
			animation.grid.columns, animation.grid.rows = columns, rows
			animation.grid.cellSize = {}
		case .Size:
			animation.grid.cellSize = cell.x >= 1 && cell.y >= 1 ? {math.floor(cell.x), math.floor(cell.y)} : {32, 32}
			animation.grid.columns, animation.grid.rows = 1, 1
		}
	case Anim_Field_Changed:
		if animation == nil do break
		// Its sheet's grid
		grid := &animation.grid
		#partial switch v.field {
		case .Columns:     grid.columns = clamp(int(v.value), 1, 256); return {}, true
		case .Rows:        grid.rows = clamp(int(v.value), 1, 256); return {}, true
		case .Cell_Width:  grid.cellSize.x = clamp(f32(int(v.value)), 1, 4096); return {}, true
		case .Cell_Height: grid.cellSize.y = clamp(f32(int(v.value)), 1, 4096); return {}, true
		case .Margin:      grid.margin = clamp(f32(v.value), 0, 1000); return {}, true
		case .Spacing:     grid.spacing = clamp(f32(v.value), 0, 1000); return {}, true
		}
		cells := AnimEdit_Cells(s.project.rootPath, animation^)
		start, end := AnimationDef_Range(animation^, cells)
		#partial switch v.field {
		case .Start:
			animation.start = clamp(int(v.value), 0, cells - 1)
			// The end moves along rather than ending up before the start
			animation.end = max(end, animation.start)
		case .End:
			animation.end = clamp(int(v.value), 0, cells - 1)
			animation.start = min(start, animation.end)
		case .Frames:
			// From the start, as many as the sheet has left
			animation.start = start
			animation.end = start + clamp(int(v.value), 1, cells - start) - 1
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
		delete(autoplay^)
		autoplay^ = strings.clone(animation.name)
	case Anim_Frame_Clicked:
		if animation == nil do break
		cells := AnimEdit_Cells(s.project.rootPath, animation^)
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
