package crossfire_editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:time"
import e "engine:."
import "gui:skald"
import sdl "vendor:sdl3"

/*
The Level mode (editor_modes.odin): the editor of LDtk projects, LDtk's own layout (the user's
design, `LDtk_interface.html`: phase 1 of TODO.md's "LDtk level editor"). Its window:

	+--------------------------------------------------------------------+
	| menu bar  [Scene | Level]                                         |
	|          [select] [pencil] [rect] [fill] [eraser] [picker]   play  | the tool row
	+-----------+--------------------------------------+-----------------+
	| Levels    | World > Level_0   Fit  Open in LDtk  | Layers          |
	| (worlds)  |                                      | = Entities  (o) |
	| Level_0   |   the canvas: the world, or the      | = Tiles     (o) |
	| Level_1   |   focused level larger               | = Walls     (o) |
	|           +--------------------------------------+                 |
	|           | World Level Layers Entities Enums ...|                 |
	|           | the tab's settings                   |                 |
	+-----------+--------------------------------------+-----------------+

- **The tool row** (view_level_tools.odin) replaces the toolbar: LDtk's tools for the selected
  layer's type, the play controls at its end.
- **The Levels sidebar** (view_level_sidebars.odin) replaces the project browser: the LDtk file and
  world choices, a row per level of the world (click selects, double-click focuses, right-click:
  `Ctx_Level`).
- **The canvas** (level_canvas.odin): the world's levels where it puts them, each drawn with its
  layers by the engine, its entities outlined, entity references and level neighbours drawn as
  links. Pan (middle or right drag, Space + drag, a drag on empty space, the wheel with Shift /
  Ctrl as the viewport's: `wheelAction`), zoom (the wheel, around the pointer), Fit. A click
  selects a level or an entity, a double-click focuses a level (`focus`: the view fits it, the
  others dimmed, as LDtk's level view; the header's World button, a double-click outside it, or
  the menu go back to the world view). Dragging a level moves it in the world (Free: whole
  pixels; GridVania: on the world grid; linear layouts place levels by their order: read only;
  not while a level is focused), dragging an entity moves it in its level (on its layer's grid;
  Shift: by the pixel). Each move is one undo step.
- **The Layers sidebar** (view_level_sidebars.odin): the selected level's layers, top first; the
  selected one (`layerDef`) is what the tools and the Layers tab work on; the eye shows or hides
  the layer in that level (its layer instance's `visible`, saved in the file as LDtk's eye does);
  the grip drags a layer to another place (`Layer_Move`, in every level).
- **The bottom tabs** (view_ldtk_tab.odin): LDtk's panels (World, Level, Layers, Entities, Enums,
  Tilesets, Auto-layer Rules, Project), then the Console and Output.
- **Saving:** edits change the LDtk document in memory (ldtk_doc.odin); Save (Ctrl+S), Play,
  exports and Open in LDtk write it. A file LDtk saved meanwhile is merged with the unsaved edits
  when the two don't touch, else the canvas's bar asks: reload it, or keep the edits
  (`LDtk_Disk_Chosen`). An undo over a document LDtk changed since is merged the same way, else
  asked (`LevelMode.conflict`, the conflict dialog).

State (`State.level`): its panel sizes (`layout`, `Mode_Layout`), its bottom tab, the world shown
(`file`, an LDtk asset: "" the project's first; `world`, a world's iid: "" its first; remembered
in `.editor/modes.ini`), the selected level, entity and layer, the focused level, the tool, the
canvas's view and drag, the tabs' choices. Its widgets: `level-split-left`,
`level-split-center-right`, `level-split-map-bottom`, `level-file`, `level-world`,
`level-row-<i>`, `level-list-scroll`, `level-layer-row-<i>`, `level-layer-grip-<i>`,
`level-layer-eye-<i>`, `level-layers-scroll`, `level-tool-<Tool>`, `level-tool-more`,
the canvas header's `panel-level-fit`, `panel-level-world-view`, `panel-level-focus`,
`panel-level-open-ldtk` (panelButton's keys), `ldtk-map-Level` (the canvas), `ldtk-disk-reload` / `ldtk-disk-keep`, `level-import`, `level-bottom-tabs`, the tabs'
(view_ldtk_tab.odin), the conflict dialog's `ldtk-conflict-overwrite` / `-keep` / `-cancel`.
*/

// The Level mode's state
LevelMode :: struct {
	// Its panels: the Levels sidebar's width, the Layers sidebar's, the bottom panel's height
	layout: Layout,
	// The bottom tab it shows (World, Level, ... Console, Output)
	bottomTab: BottomTab,
	// The LDtk project shown (an asset's path; "" the project's first; owned)
	file: string,
	// The world shown (its iid; "" the project's first; owned)
	world: string,
	// The selected level's identifier ("" none; owned)
	level: string,
	// The selected entity's iid ("" none; owned)
	entity: string,
	// The level the canvas is focused on (its identifier; "" the world view; owned)
	focus: string,
	// The world canvas's view and the drag on it (level_canvas.odin)
	view: LevelView,
	drag: LevelDrag,
	// The selected layer, entity type and enum (definitions' uids; -1: the first): the Layers,
	// Entities and Enums tabs show them, the tool row's tools follow the layer's type
	layerDef, entityDef, enumDef: int,
	// The tool the canvas uses (view_level_tools.odin)
	tool: LevelTool,
	// Painting: the palette's picks, the brush's options, the stroke (level_paint.odin)
	paint: LevelPaint,
	// Why the last LDtk edit wasn't made ("" when it was; owned)
	problem: string,
	// Names typed for a new enum value and a new enum (owned)
	newValue, newEnum: string,
	// An undo or redo whose document changed outside the editor, waiting for the user's answer
	conflict: struct {
		open, undo: bool,
	},
}

// The world canvas's view: the world point at its center and the zoom (screen pixels per world
// pixel); fitted to the world (or the focused level) when it first shows one (`fitted`, owned)
LevelView :: struct {
	center: [2]f32,
	zoom: f32,
	// The canvas's size, as last laid out
	size: [2]f32,
	fitted: string,
}

// What a press on the canvas started
LevelDragMode :: enum {
	None,
	Pan,
	// Moving the level `target` (its iid)
	Level,
	// Moving the entity `target` (its iid)
	Entity,
}

// A drag on the world canvas, press to release
LevelDrag :: struct {
	mode: LevelDragMode,
	// The level's or entity's iid (owned)
	target: string,
	// Where it started (world pixels), the level's or entity's position then, how far it's gone
	start, origin, offset: [2]f32,
	// It moved past the click's slop: the release moves what was dragged
	moved: bool,
	// Shift: entities by the pixel, not their grid
	free: bool,
	// Ctrl + Alt: the release copies the entity there (LDtk's SelectionTool isCopy)
	copy: bool,
}

// The Level mode's panels the first time it shows (the design's 300 px sidebars)
LEVEL_LAYOUT_DEFAULT :: Layout{leftWidth = 300, rightWidth = 300, bottomHeight = 374, bottomOpen = true}

// Under this workspace width the Level mode is compact: the tool row the toolbar's size, shorter
// rows, sidebars at most LEVEL_COMPACT_SIDEBAR wide
LEVEL_COMPACT_WIDTH :: 1100
LEVEL_COMPACT_SIDEBAR :: 220
// Under this workspace width there's one sidebar: the levels over the layers
LEVEL_ONE_SIDEBAR_WIDTH :: 760
// The sidebars' smallest width, and the canvas's
LEVEL_MIN_SIDEBAR :: 160
LEVEL_MIN_CANVAS :: 240

/*
The Level mode's sidebars at its layout's workspace: the Levels sidebar's and the Layers sidebar's
widths, or (narrower than LEVEL_ONE_SIDEBAR_WIDTH) one sidebar with the levels over the layers.
`view` and `update` both use it, so a divider maps back to the same widths.

Returns:
- The widths, and whether there's one sidebar (`right` 0 then)
*/
LevelMode_Sidebars :: proc(layout: ^Layout) -> (left, right: f32, one: bool) {
	w := layout.workspace.x
	left, right = layout.leftWidth, layout.rightWidth
	if w > 0 && w < LEVEL_COMPACT_WIDTH {
		left = min(left, LEVEL_COMPACT_SIDEBAR)
		right = min(right, LEVEL_COMPACT_SIDEBAR)
	}
	if w > 0 && w < LEVEL_ONE_SIDEBAR_WIDTH {
		return clamp(left, LEVEL_MIN_SIDEBAR, max(w - DIVIDER - LEVEL_MIN_CANVAS, LEVEL_MIN_SIDEBAR)), 0, true
	}
	available := w - DIVIDER * 2 - LEVEL_MIN_CANVAS
	if w > 0 && left + right > available {
		factor := max(available, 0) / (left + right)
		left = max(left * factor, LEVEL_MIN_SIDEBAR)
		right = max(right * factor, LEVEL_MIN_SIDEBAR)
	}
	return
}

// The Level mode's sizes: the design's at full size, smaller in a narrow window
LevelSizes :: struct {
	// The tool row's height (0: its natural height) and its buttons' size and corner radius
	toolRow, toolButton, toolRadius: f32,
	// The sidebars' headers, their rows, the bottom panel's tab row (0: natural)
	header, row, tabRow: f32,
	compact: bool,
}

/*
The Level mode's sizes for the shown window: the design's (a 75 px tool row of 45 px buttons, 32 px
headers, 60 px rows, a 40 px tab row) from LEVEL_COMPACT_WIDTH up, else the toolbar's sizes and
shorter rows.
*/
LevelMode_Sizes :: proc(s: ^State, th: ^skald.Theme) -> LevelSizes {
	w := Mode_LayoutOf(s, .Level).workspace.x
	if w > 0 && w < LEVEL_COMPACT_WIDTH {
		return {toolButton = math.round(th.font.size_md * 2.4), toolRadius = th.radius.md, header = 28, row = max(f32(s.settings.rowHeight) + 8, 34), compact = true}
	}
	return {toolRow = 75, toolButton = 45, toolRadius = 10, header = 32, row = 60, tabRow = 40}
}

// A world picked in the Levels sidebar (an LDtk asset's path; the frame's string)
Level_File_Chosen :: distinct string

// A world of the LDtk project picked (its iid; the frame's string)
Level_World_Chosen :: distinct string

// A level clicked (on the browser's world map while the Level mode shows: `level`, else ""), maybe a double-click
Level_Map_Clicked :: struct {
	file, level: string,
	double: bool,
}

// A level's row in the Levels sidebar pressed (a double-click focuses it; the frame's string)
Level_Row_Clicked :: struct {
	level: string,
	double: bool,
}

// The canvas focused on a level (its identifier), or back to the world view ("")
Level_Focus_Changed :: distinct string

// Open the first scene showing a level (its identifier) in the Scene mode
Level_Open_Showing :: distinct string

// A layer selected in the Layers sidebar (its definition's uid)
Level_Layer_Picked :: distinct int

// The answer to LDtk's change on disk clashing with unsaved edits: reload the file, or keep the edits
LDtk_Disk_Chosen :: struct {
	reload: bool,
}

// Open a scene showing the selected level in the Scene mode, its LDtkLevel node selected
Level_Scene_Opened :: struct {
	scene, node: int,
}

// A new scene with an LDtkLevel node showing the selected level, opened in the Scene mode
Level_Scene_Created :: struct {}

// The canvas's size, as laid out
Level_Canvas_Measured :: distinct [2]f32

// A press on the canvas: on an entity, a level, or nothing (strings only live for the frame)
Level_Canvas_Pressed :: struct {
	// The world point pressed
	world: [2]f32,
	// The level's identifier and the entity's iid under it ("" none)
	level, entity: string,
	// A double-click, a pan (middle, Space), Shift (free)
	double, pan, free: bool,
	// The right button (LDtk's erase), Alt (LDtk's pick and select), Ctrl (with Alt: copy)
	right, alt, ctrl: bool,
}

// The pointer moved during a canvas drag: the world point under it, how far it moved on screen
Level_Canvas_Moved :: struct {
	world, delta: [2]f32,
	free: bool,
}

// The canvas drag ended
Level_Canvas_Released :: struct {}

// The wheel zoomed the canvas by `factor` around a world point
Level_Canvas_Zoomed :: struct {
	factor: f32,
	world: [2]f32,
}

// The wheel or a drag panned the canvas (screen pixels: the content moves with it)
Level_Canvas_Panned :: distinct [2]f32

// The header's Fit: the whole world (or the focused level) in view
Level_Canvas_Fit :: struct {}

// An entity picked in the Entities tab: selected and centered on the canvas (its iid; the frame's string)
Level_Entity_Picked :: distinct string

// The item a tab shows (a definition's uid)
LDtk_Item_Picked :: struct {
	tab: BottomTab,
	uid: int,
}

// Typing in one of the tabs' text fields: the text is kept while it has focus (State.numberEdit),
// applied whenever it's a valid value (`edit.text`)
LDtk_Text_Typed :: struct {
	id: skald.Widget_ID,
	edit: LDtk_Edit,
}

// The name typed for a new enum value or enum (the frame's string)
LDtk_New_Name_Typed :: struct {
	enumValue: bool,
	text: string,
}

// What an LDtkLevel node makes of an IntGrid value, from the Layers tab (a `.Project` step: the
// node may be in another scene than the open one)
Level_Collision_Kind_Changed :: struct {
	scene, node, value: int,
	kind: e.LDtkCollisionKind,
}

// The answer to an undo or redo whose LDtk document changed outside the editor
LDtkConflictChoice :: enum {
	// Put the step's text back over the outside change
	Overwrite,
	// Keep the document as it is (the step and the ones before it are dropped)
	Keep_File,
	// Leave it for now (the step waits)
	Cancel,
}
LDtk_Conflict_Chosen :: distinct LDtkConflictChoice

// Frees the Level mode's state
LevelMode_Destroy :: proc(level: ^LevelMode) {
	delete(level.file)
	delete(level.world)
	delete(level.level)
	delete(level.entity)
	delete(level.focus)
	delete(level.view.fitted)
	delete(level.drag.target)
	delete(level.problem)
	delete(level.newValue)
	delete(level.newEnum)
	LevelPaint_Destroy(&level.paint)
	layout, tab := level.layout, level.bottomTab
	level^ = {layout = layout, bottomTab = tab, layerDef = -1, entityDef = -1, enumDef = -1, paint = {entityDef = -1}}
}

/*
The LDtk project the Level mode shows: its chosen one while the project has it, else the
project's first LDtk asset ("" when there's none).
*/
LevelMode_File :: proc(state: ^State) -> string {
	first := ""
	for asset in state.project.assets {
		if asset.kind != .LDtk do continue
		if asset.path == state.level.file do return asset.path
		if first == "" do first = asset.path
	}
	return first
}

// The world the Level mode shows (an index into `doc.worlds`: the chosen one, else the first)
LevelMode_World :: proc(state: ^State, doc: ^LDtkDoc) -> int {
	if doc == nil do return 0
	if state.level.world != "" do for _, w in doc.worlds {
		if _, iid := LDtkDoc_WorldNames(doc, w); iid == state.level.world do return w
	}
	return 0
}

// The levels of the shown world, in its order (indexes into `doc.levels`; temp allocated)
LevelMode_WorldLevels :: proc(state: ^State, doc: ^LDtkDoc) -> []int {
	world := LevelMode_World(state, doc)
	out := make([dynamic]int, context.temp_allocator)
	for l, i in doc.levels do if l.world == world do append(&out, i)
	return out[:]
}

// A scene's LDtkLevel node showing a level
LevelShownIn :: struct {
	scene, node: int,
	// It shows every level of the world, not just this one
	allLevels: bool,
}

/*
The scenes (not components) whose LDtkLevel nodes show a level of an LDtk file: the node naming
it (by identifier or iid, or "" for the file's first level), then those showing the whole world.

Returns:
- The scenes and nodes (temp allocated), the ones naming the level first
*/
LevelMode_ScenesShowing :: proc(state: ^State, file, level: string) -> []LevelShownIn {
	project := LDtkEdit_Project(state.project.rootPath, file)
	first, iid := "", ""
	if project != nil {
		for world in project.worlds do for l in world.levels {
			if first == "" do first = l.identifier
			if l.identifier == level do iid = l.iid
		}
	}
	named := make([dynamic]LevelShownIn, context.temp_allocator)
	whole := make([dynamic]LevelShownIn, context.temp_allocator)
	for &scene, si in state.project.scenes {
		if Scene_IsComponent(&scene) do continue
		for node, ni in scene.nodes {
			if node.kind != .LDtkLevel || node.ldtk.file != file do continue
			if node.ldtk.allLevels {
				append(&whole, LevelShownIn{si, ni, true})
			} else if node.ldtk.level == level || (iid != "" && node.ldtk.level == iid) || (node.ldtk.level == "" && level == first) {
				append(&named, LevelShownIn{si, ni, false})
			}
		}
	}
	append(&named, ..whole[:])
	return named[:]
}

/*
The Level mode's messages: its world and level, the sidebars, the canvas, the tabs and their edits
(made in the LDtk document: ldtk_ops.odin), the conflict dialog and bar. While the Level mode
shows, a level picked on the browser's world map selects it here instead of changing the hidden
scene.

Returns:
- A command, and whether `m` was one
*/
LevelMode_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	// Painting's own messages and keys (level_paint.odin)
	if LevelPaint_Update(state, m) do return {}, true
	#partial switch v in m {
	case Level_File_Chosen:
		if string(v) == state.level.file do return {}, true
		setOwned(&state.level.file, string(v))
		setOwned(&state.level.world, "")
		levelSelect(state, "", "")
		Mode_Save(state)
	case Level_World_Chosen:
		if string(v) == state.level.world do return {}, true
		setOwned(&state.level.world, string(v))
		levelSelect(state, "", "")
		Mode_Save(state)
	case Level_Map_Clicked:
		levelSelect(state, v.file, v.level)
		if !v.double || v.level == "" do return {}, true
		levelOpenShowing(state, v.file, v.level)
	case Level_Row_Clicked:
		levelSelect(state, LevelMode_File(state), v.level)
		setOwned(&state.level.entity, "")
		// A double-click focuses the level; a level picked while one is focused is focused instead
		if v.double || state.level.focus != "" do levelFocus(state, v.level)
	case Level_Focus_Changed:
		if string(v) != "" do levelSelect(state, LevelMode_File(state), string(v))
		levelFocus(state, string(v))
	case Level_Open_Showing:
		levelOpenShowing(state, LevelMode_File(state), string(v))
	case Level_Layer_Picked:
		state.level.layerDef = int(v)
		// A tool the layer's type doesn't have goes back to Select
		if !LevelTool_Available(state, state.level.tool) do state.level.tool = .Select
	case Level_Tool_Picked:
		tool := LevelTool(v)
		if LevelTool_Available(state, tool) && LEVEL_TOOLS[tool].works do state.level.tool = tool
	case LDtk_Disk_Chosen:
		if said := LDtkDoc_ResolveDisk(state.project.rootPath, LevelMode_File(state), v.reload); said != "" do logLine(state, .Info, strings.clone(said))
	case LDtk_Level_Picked:
		if state.mode != .Level do return {}, false
		levelSelect(state, v.file, v.level)
	case Level_Scene_Opened:
		levelOpen(state, v.scene, v.node)
	case Level_Scene_Created:
		file := LevelMode_File(state)
		if file == "" || state.level.level == "" do return {}, true
		// After the scenes, before the components
		at := Project_SceneCount(&state.project)
		index := Project_AddScene(&state.project, state.level.level, at)
		if at <= state.currentScene do state.currentScene += 1
		scene := &state.project.scenes[index]
		node := Scene_AddLDtkAt(scene, file, 0, {0, 0})
		delete(scene.nodes[node].ldtk.level)
		scene.nodes[node].ldtk.level = strings.clone(state.level.level)
		logLine(state, .Info, fmt.aprintf("Added scene %s showing level %s of %s", scene.name, state.level.level, filepath.base(file)))
		levelOpen(state, index, node)

	// The canvas
	case Level_Canvas_Measured:
		state.level.view.size = ([2]f32)(v)
		LevelCanvas_FitOnce(state)
	case Level_Canvas_Fit:
		LevelCanvas_Fit(state)
	case Level_Canvas_Zoomed:
		view := &state.level.view
		zoom := clamp(view.zoom * v.factor, LEVEL_MIN_ZOOM, LEVEL_MAX_ZOOM)
		// The world point under the pointer stays there
		view.center = v.world - (v.world - view.center) * (view.zoom / zoom)
		view.zoom = zoom
	case Level_Canvas_Panned:
		if state.level.view.zoom > 0 do state.level.view.center -= ([2]f32)(v) / state.level.view.zoom
	case Level_Canvas_Pressed:
		// The tools on the focused level first (level_paint.odin), else select, move, pan
		if !LevelPaint_Press(state, v) do levelCanvasPressed(state, v)
	case Level_Canvas_Moved:
		if LevelPaint_Moved(state, v) do return {}, true
		drag := &state.level.drag
		drag.free = v.free
		switch drag.mode {
		case .None:
		case .Pan:
			if state.level.view.zoom > 0 do state.level.view.center -= v.delta / state.level.view.zoom
		case .Level, .Entity:
			drag.offset = v.world - drag.start
			if !drag.moved && linalg_length(drag.offset * state.level.view.zoom) >= LEVEL_DRAG_SLOP do drag.moved = true
		}
	case Level_Canvas_Released:
		if !LevelPaint_Released(state) do levelCanvasReleased(state)
	case Level_Entity_Picked:
		levelSelectEntity(state, string(v), center = true)

	// The tabs
	case LDtk_Item_Picked:
		setOwned(&state.level.problem, "")
		#partial switch v.tab {
		case .Layers: state.level.layerDef = v.uid
		case .Entities: state.level.entityDef = v.uid
		case .Enums: state.level.enumDef = v.uid
		}
		if !LevelTool_Available(state, state.level.tool) do state.level.tool = .Select
	case LDtk_Edit:
		levelApplyEdit(state, v)
	case LDtk_Text_Typed:
		delete(state.numberEdit.text)
		state.numberEdit = {id = v.id, text = strings.clone(v.edit.text)}
		levelApplyEdit(state, v.edit)
	case LDtk_New_Name_Typed:
		setOwned(v.enumValue ? &state.level.newValue : &state.level.newEnum, v.text)
	case Level_Collision_Kind_Changed:
		if v.scene < 0 || v.scene >= len(state.project.scenes) do return {}, true
		scene := &state.project.scenes[v.scene]
		if v.node < 0 || v.node >= len(scene.nodes) || scene.nodes[v.node].kind != .LDtkLevel do return {}, true
		LDtkEdit_SetCollisionKind(state, &scene.nodes[v.node].ldtk, v.value, v.kind)
	case LDtk_Conflict_Chosen:
		switch LDtkConflictChoice(v) {
		case .Overwrite, .Keep_File:
			if text := History_ResolveConflict(state, LDtkConflictChoice(v) == .Overwrite); text != "" do logLine(state, .Info, strings.clone(text))
		case .Cancel:
			state.level.conflict = {}
		}
	case:
		return {}, false
	}
	return {}, true
}

// Replaces an owned string with a copy of another
@(private)
setOwned :: proc(field: ^string, value: string) {
	if field^ == value do return
	delete(field^)
	field^ = strings.clone(value)
}

@(private="file")
linalg_length :: proc(v: [2]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

// Screen pixels a press moves before it's a drag
LEVEL_DRAG_SLOP :: 3
// The canvas's zoom range
LEVEL_MIN_ZOOM :: 0.02
LEVEL_MAX_ZOOM :: 16

/*
Applies an edit (to the document in memory: ldtk_ops.odin), or keeps why not for the tabs to
show. A rename of a layer or an entity type is followed by the scenes' and components' LDtkLevel
nodes naming it (their collision layer, their entity rules), in the same undo step (components
through `FileChange.components`: the project's snapshot holds scenes only).
*/
@(private)
levelApplyEdit :: proc(state: ^State, edit: LDtk_Edit) {
	problem, rename := LDtkOps_Apply(state.project.rootPath, edit)
	setOwned(&state.level.problem, problem)
	// A name added: its field is ready for the next
	if problem == "" && edit.op == .Enum_Value_Added do setOwned(&state.level.newValue, "")
	if problem == "" && edit.op == .Enum_Added do setOwned(&state.level.newEnum, "")
	if problem != "" || rename.kind == .None do return
	for &scene in state.project.scenes {
		for &node in scene.nodes {
			if node.kind != .LDtkLevel || node.ldtk.file != edit.file do continue
			switch rename.kind {
			case .None:
			case .Layer:
				if node.ldtk.collisionLayer == rename.from do setOwned(&node.ldtk.collisionLayer, rename.to)
			case .Entity:
				for &rule in node.ldtk.entityComponents do if rule.entity == rename.from do setOwned(&rule.entity, rename.to)
			}
		}
	}
}

/*
A press on the canvas: selects what's under it, starts a pan or a move. While a level is focused,
a press on another level focuses that one, and the focused level itself doesn't move (a press on
it pans); a double-click outside it goes back to the world view.
*/
@(private="file")
levelCanvasPressed :: proc(state: ^State, v: Level_Canvas_Pressed) {
	drag := &state.level.drag
	delete(drag.target)
	drag^ = {}
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	// The right button pans where it doesn't erase (level_paint.odin took it otherwise)
	if v.pan || v.right || doc == nil || doc.problem != "" {
		drag.mode = .Pan
		return
	}
	focused := state.level.focus
	switch {
	case v.entity != "":
		levelSelectEntity(state, v.entity, center = false)
		e, found := LDtkDoc_FindEntity(doc, v.entity)
		if !found do return
		json := LDtkDoc_Json(doc, e.file)
		px := Json_Get(json, e.node, "px")
		drag^ = {mode = .Entity, target = strings.clone(v.entity), start = v.world, origin = {f32(Json_Int(json, Json_At(json, px, 0))), f32(Json_Int(json, Json_At(json, px, 1)))}, free = v.free}
	case v.level != "" && focused != "":
		// The focused level's view: another level is focused, the focused one pans
		setOwned(&state.level.entity, "")
		if v.level != focused {
			levelSelect(state, file, v.level)
			levelFocus(state, v.level)
			return
		}
		levelSelect(state, file, v.level)
		drag.mode = .Pan
	case v.level != "":
		levelSelect(state, file, v.level)
		setOwned(&state.level.entity, "")
		if v.double {
			levelFocus(state, v.level)
			return
		}
		level := LDtkDoc_FindLevel(doc, v.level)
		if level < 0 do return
		_, iid := LDtkDoc_LevelNames(doc, level)
		rect := LDtkDoc_LevelRect(doc, level)
		drag^ = {mode = .Level, target = strings.clone(iid), start = v.world, origin = {f32(rect[0]), f32(rect[1])}}
	case:
		// Empty space: nothing selected (a double-click there goes back to the world), the drag pans
		if v.double && focused != "" {
			levelFocus(state, "")
		} else if focused == "" {
			levelSelect(state, file, "")
		}
		setOwned(&state.level.entity, "")
		drag.mode = .Pan
	}
}

// Focuses the canvas on a level (its identifier: the view fits it) or the world ("")
@(private)
levelFocus :: proc(state: ^State, level: string) {
	setOwned(&state.level.focus, level)
	LevelCanvas_Fit(state)
}

/*
Where a drag puts what it moves: a level's world position (GridVania: on the world grid), an
entity's position in its level (on its layer's grid, its pivot on a cell's; free: by the pixel).
*/
LevelDrag_Target :: proc(state: ^State, doc: ^LDtkDoc) -> [2]int {
	drag := state.level.drag
	p := drag.origin + drag.offset
	switch drag.mode {
	case .None, .Pan:
	case .Level:
		level := LDtkDoc_FindLevel(doc, drag.target)
		if level >= 0 && LDtkDoc_WorldLayout(doc, doc.levels[level].world) == "GridVania" {
			grid := LDtkDoc_WorldGrid(doc, doc.levels[level].world)
			return {LDtk_SnapToGrid(int(math.round(p.x)), grid.x), LDtk_SnapToGrid(int(math.round(p.y)), grid.y)}
		}
	case .Entity:
		e, found := LDtkDoc_FindEntity(doc, drag.target)
		if !found || drag.free do break
		main := LDtkDoc_Main(doc)
		json := LDtkDoc_Json(doc, e.file)
		grid := f32(max(Json_Int(json, Json_Get(json, e.layer, "__gridSize"), 16), 1))
		def := LDtkDoc_DefByUid(doc, "entities", Json_Int(json, Json_Get(json, e.node, "defUid"), -1))
		pivot := [2]f32{f32(Json_Float(main, Json_Get(main, def, "pivotX"))), f32(Json_Float(main, Json_Get(main, def, "pivotY")))}
		cell := [2]f32{math.round((p.x - pivot.x * grid) / grid), math.round((p.y - pivot.y * grid) / grid)}
		snapped := cell * grid + pivot * grid
		return {int(math.round(snapped.x)), int(math.round(snapped.y))}
	}
	return {int(math.round(p.x)), int(math.round(p.y))}
}

// The drag's end: a level or an entity dragged is moved (an LDtk edit, one undo step)
@(private="file")
levelCanvasReleased :: proc(state: ^State) {
	drag := state.level.drag
	defer {
		delete(state.level.drag.target)
		state.level.drag = {}
	}
	if !drag.moved || (drag.mode != .Level && drag.mode != .Entity) do return
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	if doc == nil do return
	to := LevelDrag_Target(state, doc)
	if drag.mode == .Level {
		levelApplyEdit(state, {op = .Level_Moved, file = file, level = drag.target, number = f64(to.x), number2 = f64(to.y)})
	} else if drag.copy {
		// Ctrl + Alt: a copy goes there, selected (LDtk's SelectionTool isCopy)
		copyIid := LDtk_NewIid()
		levelApplyEdit(state, {op = .Entity_Duplicated, file = file, entity = drag.target, text = copyIid, number = f64(to.x), number2 = f64(to.y)})
		if state.level.problem == "" do levelSelectEntity(state, copyIid, center = false)
	} else {
		levelApplyEdit(state, {op = .Entity_Moved, file = file, entity = drag.target, number = f64(to.x), number2 = f64(to.y)})
	}
	if state.level.problem != "" do logLine(state, .Warning, fmt.aprintf("Not moved: %s", state.level.problem))
}

/*
Selects an entity (and its level), and the Entities tab shows its type and it (unless the
bottom panel shows the Console or Output); maybe centered on the canvas.
*/
@(private)
levelSelectEntity :: proc(state: ^State, iid: string, center: bool) {
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	if doc == nil do return
	e, found := LDtkDoc_FindEntity(doc, iid)
	if !found do return
	identifier, _ := LDtkDoc_LevelNames(doc, e.level)
	levelSelect(state, file, identifier)
	setOwned(&state.level.entity, iid)
	json := LDtkDoc_Json(doc, e.file)
	state.level.entityDef = Json_Int(json, Json_Get(json, e.node, "defUid"), -1)
	// Its layer is the selected one (the tools follow it)
	state.level.layerDef = Json_Int(json, Json_Get(json, e.layer, "layerDefUid"), state.level.layerDef)
	if !LevelTool_Available(state, state.level.tool) do state.level.tool = .Select
	if state.level.bottomTab != .Console && state.level.bottomTab != .Output do state.level.bottomTab = .Entities
	if center {
		rect := LDtkDoc_LevelRect(doc, e.level)
		px := Json_Get(json, e.node, "px")
		state.level.view.center = {f32(rect[0]) + f32(Json_Int(json, Json_At(json, px, 0))), f32(rect[1]) + f32(Json_Int(json, Json_At(json, px, 1)))}
	}
}

// Opens the first scene showing a level (or says there's none)
@(private="file")
levelOpenShowing :: proc(state: ^State, file, level: string) {
	shown := LevelMode_ScenesShowing(state, file, level)
	if len(shown) == 0 {
		logLine(state, .Info, fmt.aprintf("No scene shows %s yet: New Scene with This Level makes one", level))
		return
	}
	levelOpen(state, shown[0].scene, shown[0].node)
}

/*
Selects a level (and its file: the browser's map may show another one; and its world). Nothing
selected leaves the world view.
*/
@(private)
levelSelect :: proc(state: ^State, file, level: string) {
	if file != state.level.file && file != "" {
		setOwned(&state.level.file, file)
		setOwned(&state.level.world, "")
		Mode_Save(state)
	}
	setOwned(&state.level.level, level)
	if level == "" {
		setOwned(&state.level.entity, "")
		setOwned(&state.level.focus, "")
		return
	}
	// A level of another world shows that world
	if doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state)); doc != nil && doc.problem == "" {
		if index := LDtkDoc_FindLevel(doc, level); index >= 0 && doc.levels[index].world != LevelMode_World(state, doc) {
			_, iid := LDtkDoc_WorldNames(doc, doc.levels[index].world)
			setOwned(&state.level.world, iid)
			setOwned(&state.level.focus, "")
			Mode_Save(state)
		}
	}
}

// Opens a scene's LDtkLevel node in the Scene mode
@(private="file")
levelOpen :: proc(state: ^State, scene, node: int) {
	if scene < 0 || scene >= len(state.project.scenes) do return
	Mode_Set(state, .Scene)
	openScene(state, scene)
	state.codeTab = 0
	state.project.scenes[scene].tabClosed = false
	state.selectedNode = node >= 0 && node < len(state.project.scenes[scene].nodes) ? node : -1
}

/*
The Level mode's workspace: the Levels sidebar, the canvas over the bottom panel, the Layers
sidebar; narrower than LEVEL_ONE_SIDEBAR_WIDTH, one sidebar (the levels over the layers) beside
the canvas. Its panels' sizes are its own (`State.level.layout`); the dividers send the messages
the Scene mode's do, which change the shown mode's layout.
*/
levelModeView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	layout := Mode_LayoutOf(s, .Level)^
	layout.workspace = size
	left, right, one := LevelMode_Sidebars(&layout)
	center: skald.View
	if !layout.bottomOpen {
		center = skald.col(skald.flex(1, levelMapView(s, ctx)), bottomPanelView(s, ctx), cross_align = .Stretch)
	} else {
		center = skald.split(ctx,
			first = levelMapView(s, ctx),
			second = bottomPanelView(s, ctx),
			first_size = max(size.y - FittedBottomHeight(&layout) - DIVIDER, MIN_VIEWPORT_HEIGHT),
			on_resize = proc(v: f32) -> Msg { return Viewport_Resized(v) },
			id = skald.hash_id("level-split-map-bottom"),
			direction = .Column,
			min_first = MIN_VIEWPORT_HEIGHT,
			min_second = MIN_BOTTOM_HEIGHT,
		)
	}
	if one {
		// The levels over the layers, in one sidebar
		return skald.split(ctx,
			first = levelSidebarsStackedView(s, ctx),
			second = center,
			first_size = left,
			on_resize = proc(v: f32) -> Msg { return Left_Resized(v) },
			id = skald.hash_id("level-split-left"),
			min_first = LEVEL_MIN_SIDEBAR,
			min_second = LEVEL_MIN_CANVAS,
		)
	}
	centerWidth := max(size.x - left - right - DIVIDER * 2, LEVEL_MIN_CANVAS)
	centerAndRight := skald.split(ctx,
		first = center,
		second = levelLayersSidebarView(s, ctx),
		first_size = centerWidth,
		on_resize = proc(v: f32) -> Msg { return Center_Resized(v) },
		id = skald.hash_id("level-split-center-right"),
		min_first = LEVEL_MIN_CANVAS,
		min_second = LEVEL_MIN_SIDEBAR,
	)
	return skald.split(ctx,
		first = levelLevelsSidebarView(s, ctx),
		second = centerAndRight,
		first_size = left,
		on_resize = proc(v: f32) -> Msg { return Left_Resized(v) },
		id = skald.hash_id("level-split-left"),
		min_first = LEVEL_MIN_SIDEBAR,
		min_second = LEVEL_MIN_CANVAS + LEVEL_MIN_SIDEBAR + DIVIDER,
	)
}

/*
The center: a slim header (where the canvas is: the world or "World > Level"; the zoom, World
view, Focus, Fit, Open in LDtk), LDtk's change on disk (a bar asking about a clash with unsaved
edits, or a note), over the canvas.
*/
@(private="file")
levelMapView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	file := LevelMode_File(s)
	if file == "" {
		return skald.col(
			skald.col(
				skald.text("This project has no LDtk levels yet.", th.color.fg, th.font.size_sm),
				skald.text("Draw levels in LDtk (ldtk.io) and import the .ldtk file (the Levels sidebar's Import...): its levels show here, laid out as in its world, to edit and to open in scenes.", th.color.fg_muted, th.font.size_xs, max_width = 420),
				spacing = th.spacing.sm,
				padding = th.spacing.md,
			),
			cross_align = .Stretch,
			bg = th.color.bg,
		)
	}
	index := -1
	for asset, i in s.project.assets do if asset.kind == .LDtk && asset.path == file do index = i
	doc := LDtkDoc_Get(s.project.rootPath, file)
	readable := doc != nil && doc.problem == ""
	// Where the canvas is: the world (with several, its name), the focused level
	place := "World"
	if readable && len(doc.worlds) > 1 do place, _ = LDtkDoc_WorldNames(doc, LevelMode_World(s, doc))
	if s.level.focus != "" do place = fmt.tprintf("%s  %s  %s", place, ICON_ARROW_RIGHT, s.level.focus)
	actions := make([dynamic]skald.View, context.temp_allocator)
	if s.level.view.zoom > 0 do append(&actions, skald.text(fmt.tprintf("%.0f%%", s.level.view.zoom * 100), th.color.fg_muted, th.font.size_xs))
	if s.level.focus != "" {
		append(&actions, panelButton(ctx, "level-world-view", ICON_GLOBE, "Back to the world view (or double-click outside the level)", Msg(Level_Focus_Changed(""))))
	} else if s.level.level != "" {
		append(&actions, panelButton(ctx, "level-focus", ICON_CROSSHAIRS, fmt.tprintf("Focus on %s (or double-click it)", s.level.level), Msg(Level_Focus_Changed(strings.clone(s.level.level, context.temp_allocator)))))
	}
	append(&actions, panelButton(ctx, "level-fit", ICON_ZOOM, s.level.focus != "" ? "Fit the level in view" : "Fit the world in view", Msg(Level_Canvas_Fit{})))
	append(&actions, panelButton(ctx, "level-open-ldtk", ICON_EXTERNAL, s.level.level != "" ? fmt.tprintf("Open in LDtk at %s (unsaved edits are saved first)", s.level.level) : "Open in LDtk (unsaved edits are saved first)", Msg(LDtk_Asset_Open_Requested(index))))
	body: skald.View
	switch {
	case doc == nil:
		body = placeholder(ctx, fmt.tprintf("%s can't be read.", filepath.base(file)))
	case doc.problem != "":
		body = placeholder(ctx, fmt.tprintf("%s can't be read as an LDtk project: %s", filepath.base(file), doc.problem))
	case:
		body = levelCanvasView(ctx, s, file)
	}
	rows := make([dynamic]skald.View, context.temp_allocator)
	items := make([dynamic]skald.View, context.temp_allocator)
	append(&items, skald.text(place, th.color.fg, th.font.size_sm))
	if LDtkDoc_IsUnsaved(s.project.rootPath, file) do append(&items, skald.text("(unsaved: Ctrl+S saves)", th.color.warning, th.font.size_xs))
	append(&items, skald.flex(1, skald.spacer(0)))
	append(&items, ..actions[:])
	header := skald.row(..items[:],
		spacing = th.spacing.xs,
		padding = th.spacing.xs,
		cross_align = .Center,
		bg = th.color.surface,
	)
	append(&rows, header)
	// LDtk saved the file over unsaved edits: reload it, or keep the edits
	if names, clash := LDtkDoc_DiskConflict(s.project.rootPath, file); clash {
		append(&rows, skald.wrap_row(
			skald.text(fmt.tprintf("%s  %s changed outside the editor (saved in LDtk?) where you have unsaved edits.", ICON_REFRESH, strings.join(names, ", ", context.temp_allocator)), th.color.warning, th.font.size_xs, max_width = 2000),
			skald.button(ctx, "Reload It", Msg(LDtk_Disk_Chosen{reload = true}), id = skald.hash_id("ldtk-disk-reload"), bg = th.color.surface, fg = th.color.fg,
				padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm),
			skald.button(ctx, "Keep My Edits", Msg(LDtk_Disk_Chosen{reload = false}), id = skald.hash_id("ldtk-disk-keep"), bg = th.color.surface, fg = th.color.fg,
				padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm),
			spacing = th.spacing.xs, line_spacing = 2, padding = th.spacing.xs,
		))
	} else if change, outside := LDtkDoc_Outside(s.project.rootPath, file); outside {
		what := change.merged ? "merged with your unsaved edits" : "read again"
		append(&rows, skald.text(fmt.tprintf("%s  %s changed outside the editor at %s (saved in LDtk?): %s", ICON_REFRESH, change.file, levelClock(change.at), what),
			th.color.warning, th.font.size_xs, max_width = 2000))
	}
	append(&rows, skald.flex(1, body))
	return skald.col(..rows[:], cross_align = .Stretch, bg = th.color.bg)
}

// A time of day, "14:05:09" (local time, SDL's)
levelClock :: proc(t: time.Time) -> string {
	dt: sdl.DateTime
	if !sdl.TimeToDateTime(sdl.Time(time.to_unix_nanoseconds(t)), &dt, true) do return "?"
	return fmt.tprintf("%02d:%02d:%02d", dt.hour, dt.minute, dt.second)
}

/*
The status bar's middle in the Level mode: the world, the selected level, and (when it happened)
when the LDtk file last changed outside the editor, or that its edits aren't saved.
*/
LevelMode_Status :: proc(s: ^State) -> (world, level, outside: string) {
	file := LevelMode_File(s)
	world = file == "" ? "World: none" : fmt.tprintf("World: %s", filepath.base(file))
	if doc := LDtkDoc_Get(s.project.rootPath, file); doc != nil && doc.problem == "" && len(doc.worlds) > 1 {
		name, _ := LDtkDoc_WorldNames(doc, LevelMode_World(s, doc))
		world = fmt.tprintf("World: %s (%s)", filepath.base(file), name)
	}
	level = s.level.level == "" ? "Level: none selected" : fmt.tprintf("Level: %s", s.level.level)
	if names, clash := LDtkDoc_DiskConflict(s.project.rootPath, file); clash {
		outside = fmt.tprintf("%s changed outside: reload it or keep your edits", strings.join(names, ", ", context.temp_allocator))
	} else if change, found := LDtkDoc_Outside(s.project.rootPath, file); found && file != "" {
		outside = fmt.tprintf("%s changed outside at %s", change.file, levelClock(change.at))
	}
	return
}

/*
Asks what to do when an undo or redo would change an LDtk document that changed outside the
editor since (LDtk saved the file) where the step changes it: put the step's text back over the
outside change, keep the document (the step goes), or wait.
*/
ldtkConflictDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	if !s.level.conflict.open do return closedDialog(ctx, "ldtk-conflict-dialog")
	th := ctx.theme
	stack := s.level.conflict.undo ? s.history.undo : s.history.redo
	label := len(stack) > 0 ? stack[len(stack) - 1].label : ""
	file := ""
	if len(stack) > 0 do if change, ok := stack[len(stack) - 1].change.(FileChange); ok do file = filepath.base(change.ldtkFile)
	what := s.level.conflict.undo ? "Undo" : "Redo"
	return skald.dialog(ctx,
		open = true,
		on_dismiss = proc() -> Msg { return LDtk_Conflict_Chosen(.Cancel) },
		content = skald.col(
			skald.text(fmt.tprintf("%s changed outside the editor", file), th.color.fg, th.font.size_lg),
			skald.text(fmt.tprintf("%s \"%s\" would change what changed in %s since (saved in LDtk?).", what, label, file), th.color.fg_muted, th.font.size_sm, max_width = 460),
			skald.text("Overwrite puts the editor's version back (save to write it); Keep the File leaves it as it is and drops this step (and the older ones of the history).", th.color.fg_muted, th.font.size_sm, max_width = 460),
			skald.spacer(th.spacing.sm),
			skald.row(
				skald.button(ctx, "Cancel", Msg(LDtk_Conflict_Chosen(.Cancel)), id = skald.hash_id("ldtk-conflict-cancel"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Keep the File", Msg(LDtk_Conflict_Chosen(.Keep_File)), id = skald.hash_id("ldtk-conflict-keep"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, fmt.tprintf("Overwrite (%s)", what), Msg(LDtk_Conflict_Chosen(.Overwrite)), id = skald.hash_id("ldtk-conflict-overwrite"),
					bg = th.color.danger, fg = th.color.on_primary, font_size = th.font.size_sm),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.xs,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("ldtk-conflict-dialog"),
		initial_focus = skald.hash_id("ldtk-conflict-keep"),
	)
}
