package crossfire_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
The sprite sheet slicer (its view is view_slicer.odin): a center tab per image, beside the scene
and code tabs, where a sheet is cut into frames and the frames named into animations, which then
go into an animation asset, onto the selected AnimatedSprite or into a new one.

- **Cutting the sheet:** by a grid (`SliceMode.Grid`: the engine's `e.SheetGrid`, columns x rows
  or cells of a size, margin, gap and where it starts: `offset`), or by its sprites
  (`SliceMode.Auto`: `e.Sheet_FindSprites`, islands of opaque pixels merged within a distance,
  specks dropped; on a worker for big sheets, `SLICER_DETECT_SYNC_PIXELS`). The cells are
  numbered in reading order either way (`Slicer_CellCount`, `Slicer_CellRect`).
- **Picking frames:** the canvas's clicks (`SlicerOp.Cell_Clicked`: a click picks one, Ctrl adds
  or takes one away, Shift picks the run from the last one clicked), a row, all, none, reversed.
  The order picked is the frames' order.
- **Animations** (`SliceAnimation`): named from the picked frames (several per sheet: a row
  each), with FPS, loop, play mode and frame times, played in the tab's preview; their frames can
  be reordered and taken out.
- **What it makes** (`Slicer_AnimationDefs`): an animation whose frames are a run of a grid's
  cells in order is the grid and a range (the Animation panel edits it as any other); any other
  (frames out of order, or found sprites) has its frames as rectangles (`AnimationDef.rects`,
  the engine's `rects`), evened out to one size per animation when asked (`Slicer_EvenOut`:
  anchored at the bottom middle, so feet stay put). **Create animation asset**
  (`Slicer_Asset_Created`: a `.Project` step; the set is written by Save like any edited set,
  and undo takes it out again: `AnimationSetDef.stepMade`), **Apply to sprite**
  (`Slicer_Applied`: a `.Node` step on the selected AnimatedSprite: its own animations, or the
  asset), **Add to scene** (`Slicer_Added_To_Scene`: a `.Scene` step, a new AnimatedSprite).
- **The tab's settings** (`SlicerSettings`: how it cuts, the sprites found, the animations, the
  asset made) are remembered per image in `.editor/slicer.ini` (`Slicer_Save`, `Slicer_Load`),
  written when they change; they aren't undo steps (like the Animation panel's selection), what
  the tab makes is.
- **Tabs:** `SlicerState.tabs` (one per image), `shown` (1-based; 0: a scene or code tab shows).
  Showing one hides the code tab (`codeTab` 0); a scene or code tab picked, or another scene
  opened, hides it (`update`).

Widget keys: the tabs `slicer-tab-<i>`, `slicer-tab-close-<i>`; `slicer-canvas`, `slicer-scroll`
(the controls), `slicer-mode`, `slicer-grid-mode`, `slicer-<SlicerNumber>` (numbers:
`slicer-Columns`, `slicer-Cell_Width`, `slicer-Margin`, `slicer-Spacing`, `slicer-Offset_X`,
`slicer-Threshold`, `slicer-Merge`, `slicer-Min_Size`, `slicer-FPS`), `slicer-detect`,
`slicer-even`, `slicer-select-row`, `slicer-select-all`, `slicer-select-none`,
`slicer-reverse`, `slicer-add`, `slicer-rows`, `slicer-set-frames`, `slicer-anim-<i>`,
`slicer-anim-remove`, `slicer-anim-up`, `slicer-anim-down`, `slicer-name`, `slicer-loop`,
`slicer-play-mode`, `slicer-durations`, `slicer-duration-<frame>`, `slicer-frame-<i>`,
`slicer-frame-earlier`, `slicer-frame-later`, `slicer-frame-remove`, `slicer-play`,
`slicer-preview`, `slicer-asset-name`, `slicer-create`, `slicer-use-asset`, `slicer-apply`,
`slicer-add-to-scene`, `slicer-fit`, `slicer-manual`.
*/

// Where the slicer remembers each image's settings (in the project folder)
SLICER_FILE :: ".editor/slicer.ini"
// Sheets with more pixels than this find their sprites on a worker
SLICER_DETECT_SYNC_PIXELS :: 1024 * 1024
// At most this many grid cells (a 4096 px sheet of 8 px cells)
SLICER_MAX_CELLS :: 512 * 512

// How the slicer cuts a sheet
SliceMode :: enum {
	// By a grid (`SlicerSettings.grid`)
	Grid,
	// By its sprites: islands of opaque pixels (`SlicerSettings.found`)
	Auto,
}

// An animation named in the slicer: cells of the sheet in the order it plays them
SliceAnimation :: struct {
	// Owned
	name: string,
	// Cells, in order (owned)
	frames: [dynamic]int,
	fps: f32,
	loop: bool,
	playMode: e.AnimationPlayMode,
	// Seconds per frame (owned; empty: 1 / fps each)
	durations: [dynamic]f32,
}

// What the slicer remembers about an image (`.editor/slicer.ini`)
SlicerSettings :: struct {
	mode: SliceMode,
	grid: e.SheetGrid,
	// Auto-detect: the least alpha that counts, islands this close merged, boxes smaller dropped
	threshold: int,
	merge: int,
	minSize: int,
	// Found sprites become frames of one size per animation (`Slicer_EvenOut`)
	evenOut: bool,
	// The sprites auto-detect found (owned)
	found: [dynamic]sdl.FRect,
	// The animations named (owned)
	animations: [dynamic]SliceAnimation,
	// The animation asset made from them ("": none yet; owned)
	asset: string,
}

// One slicer tab: an image and what's being done with it
SlicerTab :: struct {
	// The image, relative to the project (owned)
	image: string,
	settings: SlicerSettings,
	// The cells picked, in the order picked (owned)
	selection: [dynamic]int,
	// The last cell clicked (Shift picks from it; -1 none)
	anchor: int,
	// The animation shown under the list (-1 none)
	animation: int,
	// Its frame picked in the frame strip (-1 none)
	frame: int,
	// The canvas: the image point at its middle, screen pixels per image pixel (0: fit it), its size
	center: [2]f32,
	zoom: f32,
	canvas: [2]f32,
	// Zoomed or panned by hand: the view stays as it is when the canvas changes size (else it's
	// fitted again)
	viewMoved: bool,
	// Finding sprites on a worker
	detecting: bool,
	// What the last detection said ("" fine; owned)
	note: string,
	// The preview's clock (seconds)
	clock: f64,
	// The settings as last written (owned): only a change is written
	saved: string,
}

// The slicer's tabs and what they share (part of State)
SlicerState :: struct {
	tabs: [dynamic]SlicerTab,
	// The tab that shows, 1-based (0: none)
	shown: int,
	// The preview plays
	playing: bool,
	tickPending: bool,
	lastTick: time.Tick,
	// An animation name being typed that isn't valid yet (owned), in the field `nameId`
	nameId: skald.Widget_ID,
	nameText: string,
	// The asset's name as typed ("": the image's; owned)
	assetName: string,
	// Apply and Add to scene use the asset made (else the animations themselves)
	useAsset: bool,
}

// What a `Slicer_Changed` does
SlicerOp :: enum {
	// How it cuts: `text` a SliceMode / SheetGridMode name
	Mode,
	Grid_Mode,
	// Found sprites evened out to one size (`flag`)
	Even_Out,
	// Find the sprites again
	Detect,
	// A cell clicked (`index`; `flag` Shift: the run from the last; `number` 1: Ctrl, add or take away)
	Cell_Clicked,
	Select_Row,
	Select_All,
	Select_None,
	Reverse_Selection,
	// A new animation from the picked frames
	Animation_Added,
	// An animation per row of cells (of the picked frames' rows, else every row)
	Rows_To_Animations,
	// The shown animation's frames become the picked ones
	Frames_Set,
	Animation_Selected,
	Animation_Removed,
	// `number` -1 or 1
	Animation_Moved,
	// The shown animation's name typed (`text`, `id`)
	Name_Typed,
	Loop,
	// `text` an AnimationPlayMode name
	Play_Mode,
	// Frame times on or off (`flag`)
	Durations,
	// A frame of the shown animation picked (`index`), moved (`number` -1 or 1), taken out
	Frame_Picked,
	Frame_Moved,
	Frame_Removed,
	// The canvas: fit (`point` its size), zoom by `number` around the image point `point`, pan by
	// `point` screen pixels, its size (`point`)
	Fit,
	Zoom,
	Pan,
	Measured,
	Playback,
	// The asset's name typed (`text`), Apply and Add use the asset (`flag`)
	Asset_Name,
	Use_Asset,
}

// An edit in the shown slicer tab
Slicer_Changed :: struct {
	op: SlicerOp,
	index: int,
	number: f64,
	text: string,
	flag: bool,
	point: [2]f32,
	id: skald.Widget_ID,
}

// The slicer's numbers (number fields)
SlicerNumber :: enum {
	Columns,
	Rows,
	Cell_Width,
	Cell_Height,
	Margin,
	Spacing,
	Offset_X,
	Offset_Y,
	Threshold,
	Merge,
	Min_Size,
	FPS,
}

// A frame's time in the shown animation (its index; milliseconds)
SlicerDurationTarget :: distinct int

// A slicer number set
Slicer_Number_Changed :: struct {
	field: SlicerNumber,
	value: f64,
}

// A frame's time set (milliseconds)
Slicer_Duration_Changed :: struct {
	frame: int,
	ms: f64,
}

// Opens the slicer on an image (its path in the project; shows its tab when open)
Slicer_Opened :: distinct string
// A slicer tab picked or closed (its index)
Slicer_Tab_Selected :: distinct int
Slicer_Tab_Closed :: distinct int
// Auto-detect's answer (from a worker: `rects` and `note` owned)
Slicer_Detected :: struct {
	image: string,
	rects: []sdl.FRect,
	note: string,
}
// The preview's frame timer
Slicer_Tick :: struct {}
Slicer_Tick_Requested :: struct {}
// Create animation asset (or update the one made): a project step
Slicer_Asset_Created :: struct {}
// Apply to sprite: the selected AnimatedSprite gets the animations (or the asset): a node step
Slicer_Applied :: struct {}
// Add to scene: a new AnimatedSprite with them: a scene step
Slicer_Added_To_Scene :: struct {}

// The shown slicer tab (nil when a scene or code tab shows)
Slicer_Shown :: proc(s: ^State) -> ^SlicerTab {
	i := s.slicer.shown - 1
	return i >= 0 && i < len(s.slicer.tabs) ? &s.slicer.tabs[i] : nil
}

// The defaults for an image the slicer hasn't seen: a strip of square cells when it's one, else
// one cell
SlicerSettings_Default :: proc(size: [2]f32) -> SlicerSettings {
	grid := e.DEFAULT_SHEET_GRID
	w, h := int(size.x), int(size.y)
	if h > 0 && w > h && w % h == 0 do grid.columns = w / h
	if w > 0 && h > w && h % w == 0 do grid.rows = h / w
	return {mode = .Grid, grid = grid, threshold = 128, merge = 2, minSize = 4, evenOut = true}
}

// Frees an animation's lists and name
SliceAnimation_Destroy :: proc(a: ^SliceAnimation) {
	delete(a.name)
	delete(a.frames)
	delete(a.durations)
}

// Frees settings' lists
SlicerSettings_Destroy :: proc(settings: ^SlicerSettings) {
	delete(settings.found)
	for &a in settings.animations do SliceAnimation_Destroy(&a)
	delete(settings.animations)
	delete(settings.asset)
	settings^ = {}
}

// Frees a tab
SlicerTab_Destroy :: proc(tab: ^SlicerTab) {
	delete(tab.image)
	SlicerSettings_Destroy(&tab.settings)
	delete(tab.selection)
	delete(tab.note)
	delete(tab.saved)
}

// Frees the slicer's tabs and text (State_Destroy, a project switch)
SlicerState_Destroy :: proc(slicer: ^SlicerState) {
	for &tab in slicer.tabs do SlicerTab_Destroy(&tab)
	delete(slicer.tabs)
	delete(slicer.nameText)
	delete(slicer.assetName)
	slicer^ = {}
}

// A sheet's size in pixels (0 when it can't be read)
Slicer_SheetSize :: proc(s: ^State, tab: ^SlicerTab) -> [2]f32 {
	return AnimEdit_SheetSize(s.project.rootPath, tab.image)
}

/*
How many cells the slicer cuts a sheet into: its grid's (at most SLICER_MAX_CELLS), or the
sprites found.
*/
Slicer_CellCount :: proc(settings: ^SlicerSettings, size: [2]f32) -> int {
	if settings.mode == .Auto do return len(settings.found)
	if size.x <= 0 || size.y <= 0 do return 0
	return min(e.SheetGrid_CellCount(settings.grid, size), SLICER_MAX_CELLS)
}

// A cell's rectangle in the sheet (the grid's, or a found sprite's)
Slicer_CellRect :: proc(settings: ^SlicerSettings, size: [2]f32, cell: int) -> sdl.FRect {
	if settings.mode == .Auto {
		if cell < 0 || cell >= len(settings.found) do return {}
		return settings.found[cell]
	}
	return e.SheetGrid_CellRect(settings.grid, size, cell)
}

/*
The cell under a point of the sheet (in its pixels), or -1: the grid's by arithmetic, a found
sprite by looking (the smallest holding it).
*/
Slicer_CellAt :: proc(settings: ^SlicerSettings, size: [2]f32, p: [2]f32) -> int {
	count := Slicer_CellCount(settings, size)
	if count == 0 do return -1
	if settings.mode == .Auto {
		best, bestArea := -1, f32(max(f32))
		for r, i in settings.found {
			if p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h && r.w * r.h < bestArea do best, bestArea = i, r.w * r.h
		}
		return best
	}
	g := settings.grid
	columns, rows, cell := e.SheetGrid_Layout(g, size)
	local := p - g.offset - g.margin
	if local.x < 0 || local.y < 0 || cell.x <= 0 || cell.y <= 0 do return -1
	step := cell + g.spacing
	column, row := int(local.x / step.x), int(local.y / step.y)
	if column >= columns || row >= rows do return -1
	// In a gap between cells: none
	if local.x - f32(column) * step.x >= cell.x || local.y - f32(row) * step.y >= cell.y do return -1
	index := row * columns + column
	return index < count ? index : -1
}

// The cells in the same row as a cell (a grid's row; found sprites overlapping it vertically), in order
Slicer_RowOf :: proc(settings: ^SlicerSettings, size: [2]f32, cell: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	count := Slicer_CellCount(settings, size)
	if cell < 0 || cell >= count do return out[:]
	if settings.mode == .Grid {
		columns, _, _ := e.SheetGrid_Layout(settings.grid, size)
		row := cell / columns
		for c in row * columns ..< min((row + 1) * columns, count) do append(&out, c)
		return out[:]
	}
	r := settings.found[cell]
	for f, i in settings.found do if f.y < r.y + r.h && f.y + f.h > r.y do append(&out, i)
	return out[:]
}

// The rows of cells, each in order (a grid's rows; found sprites grouped as they read)
Slicer_Rows :: proc(settings: ^SlicerSettings, size: [2]f32) -> [][]int {
	rows := make([dynamic][]int, context.temp_allocator)
	count := Slicer_CellCount(settings, size)
	taken := make([]bool, count, context.temp_allocator)
	for cell in 0 ..< count {
		if taken[cell] do continue
		row := Slicer_RowOf(settings, size, cell)
		for c in row do taken[c] = true
		append(&rows, row)
	}
	return rows[:]
}

/*
Found sprites' frames evened out: each animation's frames grown to its largest frame's size,
anchored at their bottom middle (feet stay on the ground as it plays), moved back inside the sheet
where they'd stick out.

Inputs:
- rects: One animation's frames (changed in place)
- size: The sheet's size (0: not kept inside)
*/
Slicer_EvenOut :: proc(rects: []sdl.FRect, size: [2]f32) {
	big: [2]f32
	for r in rects do big = {max(big.x, r.w), max(big.y, r.h)}
	for &r in rects {
		bottom := r.y + r.h
		middle := r.x + r.w / 2
		r = {math.floor(middle - big.x / 2), bottom - big.y, big.x, big.y}
		if size.x > 0 && size.y > 0 {
			r.x = clamp(r.x, 0, max(size.x - r.w, 0))
			r.y = clamp(r.y, 0, max(size.y - r.h, 0))
		}
	}
}

/*
The slicer's animations as the editor's (`AnimationDef`, owned): a run of a grid's cells in order
is the grid and a range; anything else (frames out of order, found sprites) has its frames as
rectangles (evened out per animation when `evenOut`). Animations without frames are left out.

Inputs:
- settings: The tab's settings
- image: The sheet (the animations' `sheet`)
- size: The sheet's size

Returns:
- The animations (free each with AnimationDef_Destroy, then the list)
*/
Slicer_AnimationDefs :: proc(settings: ^SlicerSettings, image: string, size: [2]f32) -> [dynamic]AnimationDef {
	out := make([dynamic]AnimationDef)
	count := Slicer_CellCount(settings, size)
	for a in settings.animations {
		frames := make([dynamic]int, context.temp_allocator)
		for f in a.frames do if f >= 0 && f < count do append(&frames, f)
		if len(frames) == 0 do continue
		def := AnimationDef{name = strings.clone(a.name), sheet = strings.clone(image), grid = e.DEFAULT_SHEET_GRID, fps = a.fps, loop = a.loop, playMode = a.playMode}
		run := settings.mode == .Grid
		for f, i in frames do if i > 0 && f != frames[i - 1] + 1 do run = false
		if run {
			def.grid = settings.grid
			def.start, def.end = frames[0], frames[len(frames) - 1]
		} else {
			rects := make([]sdl.FRect, len(frames), context.temp_allocator)
			for f, i in frames do rects[i] = Slicer_CellRect(settings, size, f)
			if settings.mode == .Auto && settings.evenOut do Slicer_EvenOut(rects, size)
			def.rects = make([dynamic]sdl.FRect, 0, len(rects))
			append(&def.rects, ..rects)
			def.start, def.end = 0, len(rects) - 1
		}
		def.durations = make([dynamic]f32, 0, len(a.durations))
		for d, i in a.durations do if i < len(frames) do append(&def.durations, d)
		def.events = make([dynamic]string)
		append(&out, def)
	}
	return out
}

// A name no other animation of the slicer tab has: "walk", "walk2", ...
Slicer_UniqueName :: proc(animations: []SliceAnimation, base: string) -> string {
	taken :: proc(animations: []SliceAnimation, name: string) -> bool {
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

// Why a name can't be an animation's ("" if it can)
Slicer_NameProblem :: proc(animations: []SliceAnimation, index: int, name: string) -> string {
	if strings.trim_space(name) == "" do return "Give it a name"
	if strings.trim_space(name) != name do return "No spaces at the ends"
	if strings.contains_any(name, "|\n") do return "No | in names"
	for a, i in animations do if i != index && a.name == name do return "Another animation has that name"
	return ""
}

// A frame's time at an fps, in whole milliseconds (100 ms without an fps)
@(private="file")
fpsDuration :: proc(fps: f32) -> f32 {
	if fps <= 0 do return 0.1
	return f32(math.round(1000 / f64(fps))) / 1000
}

// The shown tab's shown animation (nil: none)
Slicer_Animation :: proc(tab: ^SlicerTab) -> ^SliceAnimation {
	if tab == nil || tab.animation < 0 || tab.animation >= len(tab.settings.animations) do return nil
	return &tab.settings.animations[tab.animation]
}

// The animation asset the tab made, when the project still has it (-1: none)
Slicer_AssetIndex :: proc(s: ^State, tab: ^SlicerTab) -> int {
	if tab == nil || tab.settings.asset == "" do return -1
	return Project_FindAnimationSet(&s.project, tab.settings.asset)
}

// The selected node when it's an AnimatedSprite (nil otherwise)
Slicer_TargetSprite :: proc(s: ^State) -> ^NodeDef {
	if s.currentScene < 0 || s.currentScene >= len(s.project.scenes) do return nil
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) || scene.nodes[s.selectedNode].kind != .AnimatedSprite do return nil
	return &scene.nodes[s.selectedNode]
}

// Opens (or shows) an image's tab: its settings from `.editor/slicer.ini`, else the defaults
Slicer_Open :: proc(s: ^State, image: string) {
	if image == "" do return
	for tab, i in s.slicer.tabs do if tab.image == image {
		Slicer_Show(s, i)
		return
	}
	tab := SlicerTab{image = strings.clone(image), anchor = -1, animation = -1, frame = -1}
	size := Slicer_SheetSize(s, &tab)
	settings, found := Slicer_Load(s.project.rootPath, image)
	tab.settings = found ? settings : SlicerSettings_Default(size)
	if len(tab.settings.animations) > 0 do tab.animation = 0
	tab.saved = strings.clone(Slicer_Format(image, &tab.settings))
	append(&s.slicer.tabs, tab)
	Slicer_Show(s, len(s.slicer.tabs) - 1)
}

// Shows a slicer tab (the code tab steps back; the Scene mode shows)
Slicer_Show :: proc(s: ^State, index: int) {
	if index < 0 || index >= len(s.slicer.tabs) do return
	s.slicer.shown = index + 1
	s.codeTab = 0
	Mode_Set(s, .Scene)
}

// Closes a slicer tab (its settings are saved already); a neighbour or the scene shows
Slicer_Close :: proc(s: ^State, index: int) {
	if index < 0 || index >= len(s.slicer.tabs) do return
	wasShown := s.slicer.shown == index + 1
	SlicerTab_Destroy(&s.slicer.tabs[index])
	ordered_remove(&s.slicer.tabs, index)
	if wasShown {
		s.slicer.shown = 0
	} else if s.slicer.shown > index + 1 {
		s.slicer.shown -= 1
	}
}

/*
Handles the slicer's messages: its tabs, edits, the canvas, the preview and what it makes.

Returns:
- A command (auto-detect on a worker, the preview's next frame), and whether `m` was the slicer's
*/
Slicer_Update :: proc(s: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	command: skald.Command(Msg)
	tab := Slicer_Shown(s)
	#partial switch v in m {
	case Slicer_Opened:
		Slicer_Open(s, string(v))
		return {}, true
	case Slicer_Tab_Selected:
		Slicer_Show(s, int(v))
		return {}, true
	case Slicer_Tab_Closed:
		Slicer_Close(s, int(v))
		return {}, true
	case Slicer_Detected:
		defer delete(v.image)
		for &t in s.slicer.tabs do if t.image == v.image {
			t.detecting = false
			slicerTakeFound(&t, v.rects, v.note)
			Slicer_Save(s, &t)
			return {}, true
		}
		delete(v.rects)
		delete(v.note)
		return {}, true
	case Slicer_Tick_Requested:
		if s.slicer.tickPending || !s.slicer.playing do return {}, true
		s.slicer.tickPending = true
		s.slicer.lastTick = time.tick_now()
		return skald.cmd_delay(1.0 / ANIMATION_PREVIEW_FPS, Msg(Slicer_Tick{})), true
	case Slicer_Tick:
		now := time.tick_now()
		if tab != nil do tab.clock += min(time.duration_seconds(time.tick_diff(s.slicer.lastTick, now)), 0.25)
		s.slicer.lastTick = now
		if !s.slicer.playing || tab == nil || s.mode != .Scene || !EditorFocused() {
			s.slicer.tickPending = false
			return {}, true
		}
		return skald.cmd_delay(1.0 / ANIMATION_PREVIEW_FPS, Msg(Slicer_Tick{})), true
	case Slicer_Number_Changed:
		if tab == nil do return {}, true
		slicerNumber(s, tab, v.field, v.value)
	case Slicer_Duration_Changed:
		a := Slicer_Animation(tab)
		if a == nil || v.frame < 0 || v.frame >= len(a.frames) do return {}, true
		for len(a.durations) <= v.frame do append(&a.durations, fpsDuration(a.fps))
		a.durations[v.frame] = f32(clamp(math.round(v.ms), 1, 60000)) / 1000
	case Slicer_Changed:
		if tab == nil do return {}, true
		command = slicerEdit(s, tab, v)
	case Slicer_Asset_Created:
		Slicer_CreateAsset(s, tab)
		return {}, true
	case Slicer_Applied:
		Slicer_Apply(s, tab)
		return {}, true
	case Slicer_Added_To_Scene:
		Slicer_AddToScene(s, tab)
		return {}, true
	case:
		return {}, false
	}
	if tab != nil do Slicer_Save(s, tab)
	return command, true
}

// A number field's value
@(private="file")
slicerNumber :: proc(s: ^State, tab: ^SlicerTab, field: SlicerNumber, value: f64) {
	g := &tab.settings.grid
	switch field {
	case .Columns:     g.columns = clamp(int(value), 1, 512)
	case .Rows:        g.rows = clamp(int(value), 1, 512)
	case .Cell_Width:  g.cellSize.x = clamp(f32(int(value)), 1, 4096)
	case .Cell_Height: g.cellSize.y = clamp(f32(int(value)), 1, 4096)
	case .Margin:      g.margin = clamp(f32(int(value)), 0, 1000)
	case .Spacing:     g.spacing = clamp(f32(int(value)), 0, 1000)
	case .Offset_X:    g.offset.x = clamp(f32(int(value)), 0, 4096)
	case .Offset_Y:    g.offset.y = clamp(f32(int(value)), 0, 4096)
	case .Threshold:   tab.settings.threshold = clamp(int(value), 1, 255)
	case .Merge:       tab.settings.merge = clamp(int(value), 0, 256)
	case .Min_Size:    tab.settings.minSize = clamp(int(value), 0, 4096)
	case .FPS:
		if a := Slicer_Animation(tab); a != nil do a.fps = clamp(f32(value), 0, 120)
	}
	// A grid that changed: picks past its cells go
	if field <= .Offset_Y do slicerClampPicks(s, tab)
}

// Drops picked cells the sheet no longer has (the grid shrank)
@(private="file")
slicerClampPicks :: proc(s: ^State, tab: ^SlicerTab) {
	count := Slicer_CellCount(&tab.settings, Slicer_SheetSize(s, tab))
	#reverse for c, i in tab.selection do if c >= count do ordered_remove(&tab.selection, i)
	if tab.anchor >= count do tab.anchor = -1
}

// Takes auto-detect's sprites (owned) into a tab
@(private="file")
slicerTakeFound :: proc(tab: ^SlicerTab, rects: []sdl.FRect, note: string) {
	clear(&tab.settings.found)
	append(&tab.settings.found, ..rects)
	delete(rects)
	delete(tab.note)
	tab.note = note
	if tab.settings.mode == .Auto {
		count := len(tab.settings.found)
		#reverse for c, i in tab.selection do if c >= count do ordered_remove(&tab.selection, i)
		if tab.anchor >= count do tab.anchor = -1
	}
}

/*
Finds a tab's sprites: here for a small sheet, else on a worker (`Slicer_Detected` comes back).

Returns:
- The worker's command, or none
*/
Slicer_Detect :: proc(s: ^State, tab: ^SlicerTab) -> skald.Command(Msg) {
	full := joinPath(s.project.rootPath, tab.image, allocator = context.temp_allocator)
	search := e.SpriteSearch{threshold = u8(clamp(tab.settings.threshold, 1, 255)), mergeDistance = tab.settings.merge, minSize = tab.settings.minSize}
	size := Slicer_SheetSize(s, tab)
	if size.x * size.y <= SLICER_DETECT_SYNC_PIXELS {
		rects, note := Slicer_FindSprites(full, search)
		slicerTakeFound(tab, rects, note)
		return {}
	}
	tab.detecting = true
	Job :: struct { path, image: string, search: e.SpriteSearch }
	return skald.cmd_thread(Msg, Job{strings.clone(full), strings.clone(tab.image), search}, proc(job: Job) -> Msg {
		defer delete(job.path)
		rects, note := Slicer_FindSprites(job.path, job.search)
		free_all(context.temp_allocator)
		return Slicer_Detected{image = job.image, rects = rects, note = note}
	})
}

/*
Reads an image and finds its sprites (`e.Sheet_FindSprites`; a sheet without transparency: its
corner's color is the background). Blocks: `Slicer_Detect` runs big sheets on a worker.

Returns:
- The boxes and a note saying how many and how long it took, or why there are none (both owned)
*/
Slicer_FindSprites :: proc(path: string, search: e.SpriteSearch) -> ([]sdl.FRect, string) {
	start := time.tick_now()
	pixels, w, h, ok := Image_LoadRGBA(path)
	if !ok do return nil, fmt.aprintf("Couldn't read %s", filepath.base(path))
	search := search
	search.key, search.useKey = e.Sheet_BackgroundKey(pixels, w, h, search.threshold)
	rects := e.Sheet_FindSprites(pixels, w, h, search)
	ms := time.duration_milliseconds(time.tick_since(start))
	background := search.useKey ? fmt.tprintf(", the background #%02x%02x%02x", search.key[0], search.key[1], search.key[2]) : ""
	if len(rects) == 0 do return rects, fmt.aprintf("No sprites found (alpha at least %d%s): lower the alpha", search.threshold, background)
	return rects, fmt.aprintf("%d sprite%s found in %.0f ms%s", len(rects), len(rects) == 1 ? "" : "s", ms, background)
}

// The edits of `Slicer_Changed`
@(private="file")
slicerEdit :: proc(s: ^State, tab: ^SlicerTab, v: Slicer_Changed) -> skald.Command(Msg) {
	settings := &tab.settings
	size := Slicer_SheetSize(s, tab)
	count := Slicer_CellCount(settings, size)
	a := Slicer_Animation(tab)
	switch v.op {
	case .Mode:
		mode, ok := reflect.enum_from_name(SliceMode, v.text)
		if !ok || mode == settings.mode do break
		settings.mode = mode
		clear(&tab.selection)
		tab.anchor = -1
		// Found nothing yet: find them now
		if mode == .Auto && len(settings.found) == 0 do return Slicer_Detect(s, tab)
	case .Grid_Mode:
		// The other mode's values from the image, so the cells stay where they are
		mode, ok := reflect.enum_from_name(e.SheetGridMode, v.text)
		if !ok || mode == settings.grid.mode do break
		columns, rows, cell := e.SheetGrid_Layout(settings.grid, size)
		settings.grid.mode = mode
		switch mode {
		case .Cells:
			settings.grid.columns, settings.grid.rows = columns, rows
			settings.grid.cellSize = {}
		case .Size:
			settings.grid.cellSize = cell.x >= 1 && cell.y >= 1 ? {math.floor(cell.x), math.floor(cell.y)} : {32, 32}
			settings.grid.columns, settings.grid.rows = 1, 1
		}
		slicerClampPicks(s, tab)
	case .Even_Out:
		settings.evenOut = v.flag
	case .Detect:
		return Slicer_Detect(s, tab)
	case .Cell_Clicked:
		if v.index < 0 || v.index >= count do break
		ctrl := v.number != 0
		switch {
		case v.flag && tab.anchor >= 0:
			// The run from the last one clicked, either way
			clear(&tab.selection)
			step := v.index >= tab.anchor ? 1 : -1
			for c := tab.anchor; ; c += step {
				append(&tab.selection, c)
				if c == v.index do break
			}
		case ctrl:
			if at, found := slice.linear_search(tab.selection[:], v.index); found {
				ordered_remove(&tab.selection, at)
			} else {
				append(&tab.selection, v.index)
			}
			tab.anchor = v.index
		case:
			clear(&tab.selection)
			append(&tab.selection, v.index)
			tab.anchor = v.index
		}
	case .Select_Row:
		from := tab.anchor >= 0 ? tab.anchor : (len(tab.selection) > 0 ? tab.selection[0] : 0)
		row := Slicer_RowOf(settings, size, from)
		if len(row) == 0 do break
		clear(&tab.selection)
		append(&tab.selection, ..row)
	case .Select_All:
		clear(&tab.selection)
		for c in 0 ..< count do append(&tab.selection, c)
	case .Select_None:
		clear(&tab.selection)
		tab.anchor = -1
	case .Reverse_Selection:
		slice.reverse(tab.selection[:])
	case .Animation_Added:
		if len(tab.selection) == 0 do break
		base := v.text != "" ? v.text : "animation"
		added := SliceAnimation{name = Slicer_UniqueName(settings.animations[:], base), fps = e.DEFAULT_ANIMATION_FPS, loop = true}
		append(&added.frames, ..tab.selection[:])
		append(&settings.animations, added)
		tab.animation = len(settings.animations) - 1
		tab.frame = -1
		tab.clock = 0
	case .Rows_To_Animations:
		// The picked frames' rows, else every row: an animation each, named row1, row2...
		rows := Slicer_Rows(settings, size)
		wanted := make([dynamic]bool, len(rows), context.temp_allocator)
		any := false
		for row, r in rows do for c in row do if slice.contains(tab.selection[:], c) {
			wanted[r] = true
			any = true
		}
		for row, r in rows {
			if any && !wanted[r] do continue
			added := SliceAnimation{name = Slicer_UniqueName(settings.animations[:], fmt.tprintf("row%d", r + 1)), fps = e.DEFAULT_ANIMATION_FPS, loop = true}
			append(&added.frames, ..row)
			append(&settings.animations, added)
		}
		if len(settings.animations) > 0 && tab.animation < 0 do tab.animation = 0
	case .Frames_Set:
		if a == nil || len(tab.selection) == 0 do break
		clear(&a.frames)
		append(&a.frames, ..tab.selection[:])
		resize(&a.durations, min(len(a.durations), len(a.frames)))
		if len(a.durations) > 0 do for len(a.durations) < len(a.frames) do append(&a.durations, fpsDuration(a.fps))
		tab.frame = -1
		tab.clock = 0
	case .Animation_Selected:
		if v.index < 0 || v.index >= len(settings.animations) do break
		tab.animation = v.index
		tab.frame = -1
		tab.clock = 0
		// Its frames are the picks (to change them, or to see them on the sheet)
		clear(&tab.selection)
		append(&tab.selection, ..settings.animations[v.index].frames[:])
	case .Animation_Removed:
		if a == nil do break
		SliceAnimation_Destroy(a)
		ordered_remove(&settings.animations, tab.animation)
		tab.animation = min(tab.animation, len(settings.animations) - 1)
		tab.frame = -1
	case .Animation_Moved:
		to := tab.animation + int(v.number)
		if a == nil || to < 0 || to >= len(settings.animations) do break
		settings.animations[tab.animation], settings.animations[to] = settings.animations[to], settings.animations[tab.animation]
		tab.animation = to
	case .Name_Typed:
		delete(s.slicer.nameText)
		s.slicer.nameId, s.slicer.nameText = v.id, strings.clone(v.text)
		if a == nil || Slicer_NameProblem(settings.animations[:], tab.animation, v.text) != "" do break
		delete(a.name)
		a.name = strings.clone(v.text)
	case .Loop:
		if a != nil do a.loop = v.flag
	case .Play_Mode:
		if a == nil do break
		if mode, ok := reflect.enum_from_name(e.AnimationPlayMode, v.text); ok do a.playMode = mode
		tab.clock = 0
	case .Durations:
		if a == nil do break
		clear(&a.durations)
		if v.flag do for _ in a.frames do append(&a.durations, fpsDuration(a.fps))
		tab.clock = 0
	case .Frame_Picked:
		if a != nil && v.index >= 0 && v.index < len(a.frames) do tab.frame = v.index
	case .Frame_Moved:
		to := tab.frame + int(v.number)
		if a == nil || tab.frame < 0 || tab.frame >= len(a.frames) || to < 0 || to >= len(a.frames) do break
		a.frames[tab.frame], a.frames[to] = a.frames[to], a.frames[tab.frame]
		if tab.frame < len(a.durations) && to < len(a.durations) do a.durations[tab.frame], a.durations[to] = a.durations[to], a.durations[tab.frame]
		tab.frame = to
	case .Frame_Removed:
		if a == nil || tab.frame < 0 || tab.frame >= len(a.frames) do break
		ordered_remove(&a.frames, tab.frame)
		if tab.frame < len(a.durations) do ordered_remove(&a.durations, tab.frame)
		tab.frame = min(tab.frame, len(a.frames) - 1)
	case .Fit:
		if size.x <= 0 || size.y <= 0 || v.point.x <= 0 || v.point.y <= 0 do break
		tab.center = size / 2
		tab.zoom = clamp(min(v.point.x / size.x, v.point.y / size.y) * 0.95, 0.02, 32)
		tab.viewMoved = false
	case .Zoom:
		if tab.zoom <= 0 || v.number <= 0 do break
		// Around the image point under the pointer: it stays where it is on screen
		zoom := clamp(tab.zoom * f32(v.number), 0.02, 64)
		tab.center = v.point + (tab.center - v.point) * (tab.zoom / zoom)
		tab.zoom = zoom
		tab.viewMoved = true
	case .Pan:
		if tab.zoom > 0 do tab.center -= v.point / tab.zoom
		tab.viewMoved = true
	case .Measured:
		tab.canvas = v.point
		// Not moved by hand: it stays fitted
		if !tab.viewMoved && size.x > 0 && size.y > 0 && v.point.x > 0 && v.point.y > 0 {
			tab.center = size / 2
			tab.zoom = clamp(min(v.point.x / size.x, v.point.y / size.y) * 0.95, 0.02, 32)
		}
	case .Playback:
		s.slicer.playing = !s.slicer.playing
		if s.slicer.playing && !s.slicer.tickPending {
			s.slicer.tickPending = true
			s.slicer.lastTick = time.tick_now()
			return skald.cmd_delay(1.0 / ANIMATION_PREVIEW_FPS, Msg(Slicer_Tick{}))
		}
	case .Asset_Name:
		delete(s.slicer.assetName)
		s.slicer.assetName = strings.clone(v.text)
	case .Use_Asset:
		s.slicer.useAsset = v.flag
	}
	// Frame times cover every frame
	if a := Slicer_Animation(tab); a != nil && len(a.durations) > 0 {
		for len(a.durations) < len(a.frames) do append(&a.durations, fpsDuration(a.fps))
	}
	return {}
}

// The name the asset gets: what's typed, else the image's name
Slicer_AssetName :: proc(s: ^State, tab: ^SlicerTab) -> string {
	if name := strings.trim_space(s.slicer.assetName); name != "" do return name
	base := filepath.base(tab.image)
	return strings.trim_suffix(base, filepath.ext(base))
}

/*
Create animation asset: the tab's animations as a new animation asset (`animations/<name>.anim.xml`,
written by Save like an edited set), or into the one the tab made, when the project still has
it. A `.Project` step: undo takes a new one out again (`AnimationSetDef.stepMade`).
*/
Slicer_CreateAsset :: proc(s: ^State, tab: ^SlicerTab) {
	if tab == nil do return
	defs := Slicer_AnimationDefs(&tab.settings, tab.image, Slicer_SheetSize(s, tab))
	defer {
		for &d in defs do AnimationDef_Destroy(&d)
		delete(defs)
	}
	if len(defs) == 0 {
		logLine(s, .Warning, strings.clone("Name an animation first: pick frames on the sheet, then New Animation"))
		return
	}
	if at := Slicer_AssetIndex(s, tab); at >= 0 {
		set := &s.project.animationSets[at]
		for &a in set.animations do AnimationDef_Destroy(&a)
		clear(&set.animations)
		for d in defs do append(&set.animations, AnimationDef_Clone(d))
		if Project_FindAnimationName(set, set.autoplay) < 0 {
			delete(set.autoplay)
			set.autoplay = strings.clone("")
		}
		logLine(s, .Info, fmt.aprintf("Updated %s: %d animation%s from %s", set.path, len(defs), len(defs) == 1 ? "" : "s", filepath.base(tab.image)))
		return
	}
	at, problem := Project_CreateAnimationSet(&s.project, Slicer_AssetName(s, tab), AnimationSetDef{animations = defs}, write = false)
	if at < 0 {
		logLine(s, .Error, fmt.aprintf("Couldn't make the animation asset: %s", problem))
		return
	}
	set := &s.project.animationSets[at]
	set.stepMade = true
	delete(tab.settings.asset)
	tab.settings.asset = strings.clone(set.path)
	s.slicer.useAsset = true
	logLine(s, .Info, fmt.aprintf("Made %s: %d animation%s from %s (written when you save)", set.path, len(defs), len(defs) == 1 ? "" : "s", filepath.base(tab.image)))
}

// The index of an animation in a set by name (-1: none)
Project_FindAnimationName :: proc(set: ^AnimationSetDef, name: string) -> int {
	for a, i in set.animations do if a.name == name do return i
	return -1
}

// Gives a sprite the tab's animations (its own: replacing them) or the asset made
@(private="file")
slicerGive :: proc(s: ^State, tab: ^SlicerTab, node: ^NodeDef) -> bool {
	if at := Slicer_AssetIndex(s, tab); at >= 0 && s.slicer.useAsset {
		for &a in node.animations do AnimationDef_Destroy(&a)
		clear(&node.animations)
		delete(node.animationSet)
		node.animationSet = strings.clone(tab.settings.asset)
		delete(node.autoplay)
		node.autoplay = strings.clone("")
		return true
	}
	defs := Slicer_AnimationDefs(&tab.settings, tab.image, Slicer_SheetSize(s, tab))
	if len(defs) == 0 {
		delete(defs)
		logLine(s, .Warning, strings.clone("Name an animation first: pick frames on the sheet, then New Animation"))
		return false
	}
	for &a in node.animations do AnimationDef_Destroy(&a)
	delete(node.animations)
	node.animations = defs
	delete(node.animationSet)
	node.animationSet = strings.clone("")
	delete(node.autoplay)
	node.autoplay = strings.clone("")
	return true
}

// Apply to sprite: the selected AnimatedSprite gets the tab's animations, or the asset (a node step)
Slicer_Apply :: proc(s: ^State, tab: ^SlicerTab) {
	node := Slicer_TargetSprite(s)
	if tab == nil || node == nil {
		logLine(s, .Warning, strings.clone("Select an AnimatedSprite (in the scene tree) to apply the animations to"))
		return
	}
	if slicerGive(s, tab, node) {
		what := node.animationSet != "" ? node.animationSet : fmt.tprintf("%d animation%s", len(node.animations), len(node.animations) == 1 ? "" : "s")
		logLine(s, .Info, fmt.aprintf("%s plays %s now", node.name, what))
	}
}

// Add to scene: a new AnimatedSprite named after the image, with the animations or the asset, in
// the middle of the view (a scene step; it's selected)
Slicer_AddToScene :: proc(s: ^State, tab: ^SlicerTab) {
	if tab == nil || s.currentScene < 0 || s.currentScene >= len(s.project.scenes) do return
	scene := &s.project.scenes[s.currentScene]
	base := filepath.base(tab.image)
	name := Slicer_NodeName(strings.trim_suffix(base, filepath.ext(base)))
	parent := Scene_ParentFor(scene, s.selectedNode < len(scene.nodes) ? s.selectedNode : -1)
	index := Scene_InsertNode(scene, Scene_UniqueNodeName(scene, name), .AnimatedSprite, parent)
	if !slicerGive(s, tab, &scene.nodes[index]) {
		Scene_RemoveNode(scene, index)
		return
	}
	parentWorld := parent >= 0 ? Scene_WorldTransforms(scene)[parent] : e.TRANSFORM2D_IDENTITY
	world := s.viewport.zoom > 0 ? s.viewport.center : s.project.gameSize / 2
	local := e.Transform2D_Apply(e.Transform2D_Inverse(parentWorld), world)
	scene.nodes[index].position = {math.round(local.x), math.round(local.y)}
	s.selectedNode = index
	logLine(s, .Info, fmt.aprintf("Added %s to %s", scene.nodes[index].name, scene.name))
}

// A node name from a file name: "hero_run" -> "HeroRun"
Slicer_NodeName :: proc(stem: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	upper := true
	for ch in stem {
		if ch == '_' || ch == '-' || ch == ' ' || ch == '.' {
			upper = true
			continue
		}
		if upper && ch >= 'a' && ch <= 'z' do strings.write_rune(&b, ch - 32)
		else do strings.write_rune(&b, ch)
		upper = false
	}
	name := strings.to_string(b)
	return name != "" ? name : "AnimatedSprite"
}

// PERSISTENCE (.editor/slicer.ini)

/*
An image's settings as its section of `.editor/slicer.ini` (temp allocated):

	[assets/hero.png]
	mode = Grid
	grid = Cells 4 2 0 0 0 0 0 0
	detect = 128 2 4 1
	found = 0,4,20,12 24,0,18,16
	asset = animations/hero.anim.xml
	anim = 8 1 Forward | 0 1 2 3 | 100 100 100 300 | idle

`grid` is the mode, columns, rows, cell width and height, margin, gap and offset; `detect` the
alpha, merge distance, smallest size and evening out; each `anim` its fps, loop and play mode,
its frames, its frame times in ms (empty for none) and its name (last: it may hold anything but
a line break or `|`).
*/
Slicer_Format :: proc(image: string, settings: ^SlicerSettings) -> string {
	b := strings.builder_make(context.temp_allocator)
	g := settings.grid
	fmt.sbprintf(&b, "[%s]\n", image)
	fmt.sbprintf(&b, "mode = %v\n", settings.mode)
	fmt.sbprintf(&b, "grid = %v %d %d %v %v %v %v %v %v\n", g.mode, max(g.columns, 1), max(g.rows, 1), g.cellSize.x, g.cellSize.y, g.margin, g.spacing, g.offset.x, g.offset.y)
	fmt.sbprintf(&b, "detect = %d %d %d %d\n", settings.threshold, settings.merge, settings.minSize, settings.evenOut ? 1 : 0)
	if len(settings.found) > 0 do fmt.sbprintf(&b, "found = %s\n", e.FormatSheetRects(settings.found[:], context.temp_allocator))
	if settings.asset != "" do fmt.sbprintf(&b, "asset = %s\n", settings.asset)
	for a in settings.animations {
		fmt.sbprintf(&b, "anim = %v %d %v |", a.fps, a.loop ? 1 : 0, a.playMode)
		for f in a.frames do fmt.sbprintf(&b, " %d", f)
		strings.write_string(&b, " |")
		for d in a.durations do fmt.sbprintf(&b, " %v", f32(int(d * 1000 * 1000 + 0.5)) / 1000)
		fmt.sbprintf(&b, " | %s\n", a.name)
	}
	return strings.to_string(b)
}

/*
Reads an image's settings from `.editor/slicer.ini` (`Slicer_Format`'s section).

Returns:
- The settings (owned), and false when the file has none for it
*/
Slicer_Load :: proc(root, image: string) -> (settings: SlicerSettings, found: bool) {
	data, err := os.read_entire_file(joinPath(root, SLICER_FILE, allocator = context.temp_allocator), context.temp_allocator)
	if err != nil do return
	return Slicer_Parse(string(data), image)
}

// Reads an image's section of the file's text (Slicer_Load); owned settings, and whether it was there
Slicer_Parse :: proc(text, image: string) -> (settings: SlicerSettings, found: bool) {
	settings = SlicerSettings_Default({})
	inSection := false
	text := text
	for line in strings.split_lines_iterator(&text) {
		line := strings.trim_right(line, "\r")
		if strings.has_prefix(line, "[") && strings.has_suffix(line, "]") {
			inSection = line[1:len(line) - 1] == image
			if inSection do found = true
			continue
		}
		if !inSection do continue
		key, _, value := strings.partition(line, " = ")
		fields := strings.fields(value, context.temp_allocator)
		number :: proc(fields: []string, i: int, fallback: f32) -> f32 {
			if i >= len(fields) do return fallback
			v, ok := strconv.parse_f32(fields[i])
			return ok ? v : fallback
		}
		switch key {
		case "mode":
			if mode, ok := reflect.enum_from_name(SliceMode, strings.trim_space(value)); ok do settings.mode = mode
		case "grid":
			if len(fields) > 0 do if mode, ok := reflect.enum_from_name(e.SheetGridMode, fields[0]); ok do settings.grid.mode = mode
			settings.grid.columns = max(int(number(fields, 1, 1)), 1)
			settings.grid.rows = max(int(number(fields, 2, 1)), 1)
			settings.grid.cellSize = {max(number(fields, 3, 0), 0), max(number(fields, 4, 0), 0)}
			settings.grid.margin = max(number(fields, 5, 0), 0)
			settings.grid.spacing = max(number(fields, 6, 0), 0)
			settings.grid.offset = {max(number(fields, 7, 0), 0), max(number(fields, 8, 0), 0)}
		case "detect":
			settings.threshold = clamp(int(number(fields, 0, 128)), 1, 255)
			settings.merge = max(int(number(fields, 1, 2)), 0)
			settings.minSize = max(int(number(fields, 2, 4)), 0)
			settings.evenOut = number(fields, 3, 1) != 0
		case "found":
			delete(settings.found)
			settings.found = e.ParseSheetRects(value)
		case "asset":
			delete(settings.asset)
			settings.asset = strings.clone(strings.trim_space(value))
		case "anim":
			parts := strings.split_n(value, "|", 4, context.temp_allocator)
			if len(parts) < 4 do continue
			head := strings.fields(parts[0], context.temp_allocator)
			a := SliceAnimation{fps = number(head, 0, e.DEFAULT_ANIMATION_FPS), loop = number(head, 1, 1) != 0}
			if len(head) > 2 do if mode, ok := reflect.enum_from_name(e.AnimationPlayMode, head[2]); ok do a.playMode = mode
			for f in strings.fields(parts[1], context.temp_allocator) do if n, ok := strconv.parse_int(f); ok && n >= 0 do append(&a.frames, n)
			for d in strings.fields(parts[2], context.temp_allocator) do if ms, ok := strconv.parse_f32(d); ok && ms > 0 do append(&a.durations, ms / 1000)
			a.name = strings.clone(strings.trim_space(parts[3]))
			if a.name == "" || len(a.frames) == 0 {
				SliceAnimation_Destroy(&a)
				continue
			}
			append(&settings.animations, a)
		}
	}
	return
}

/*
Writes a tab's settings into `.editor/slicer.ini` when they changed since last written (the other
images' sections kept as they are; written whole into a temporary file first, then moved over
it). Only for a project folder on disk.
*/
Slicer_Save :: proc(s: ^State, tab: ^SlicerTab) {
	text := Slicer_Format(tab.image, &tab.settings)
	if text == tab.saved || s.project.rootPath == "" || !os.exists(s.project.rootPath) do return
	path := joinPath(s.project.rootPath, SLICER_FILE, allocator = context.temp_allocator)
	old, _ := os.read_entire_file(path, context.temp_allocator)
	merged := Slicer_ReplaceSection(string(old), tab.image, text)
	_ = os.make_directory_all(filepath.dir(path))
	temporary := fmt.tprintf("%s.tmp", path)
	if err := os.write_entire_file(temporary, transmute([]u8)merged); err != nil {
		logLine(s, .Warning, fmt.aprintf("Couldn't write %s: %v", SLICER_FILE, err))
		return
	}
	if err := os.rename(temporary, path); err != nil {
		logLine(s, .Warning, fmt.aprintf("Couldn't write %s: %v", SLICER_FILE, err))
		return
	}
	delete(tab.saved)
	tab.saved = strings.clone(text)
}

// The file's text with an image's section replaced by `section` (or added at its end); temp allocated
Slicer_ReplaceSection :: proc(file, image, section: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	skipping, replaced := false, false
	text := file
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "[") && strings.has_suffix(strings.trim_right(line, "\r"), "]") {
			trimmed := strings.trim_right(line, "\r")
			skipping = trimmed[1:len(trimmed) - 1] == image
			if skipping && !replaced {
				strings.write_string(&b, section)
				replaced = true
			}
		}
		if skipping || strings.trim_space(line) == "" do continue
		fmt.sbprintf(&b, "%s\n", line)
	}
	if !replaced do strings.write_string(&b, section)
	return strings.to_string(b)
}
