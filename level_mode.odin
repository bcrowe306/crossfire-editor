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
The Level mode (editor_modes.odin): the world editor, and the groundwork for an editor of LDtk's
format of our own. Its workspace:

	+-----------+--------------------------------------+--------------+
	| browser   | World: <file>  [file] Fit  Open in LDtk | the level    |
	|           |                                      | selected,    |
	|           |   the world canvas: every level with  | the scenes   |
	|           |   its layers, entities and links      | showing it,  |
	|           +--------------------------------------+ the entity   |
	| preview   | bottom panel: LDtk, Console, Output  | selected     |
	+-----------+--------------------------------------+--------------+

- **The world canvas** (level_canvas.odin): the LDtk project's levels where its world puts them,
  each drawn with its layers by the engine, its entities outlined, entity references and level
  neighbours drawn as links. Pan (middle or right drag, Space + drag, a drag on empty space, the
  wheel with Shift / Ctrl as the viewport's: `wheelAction`), zoom (the wheel, around the
  pointer), Fit. A click selects a level or an entity (the LDtk tab shows it), a double-click
  opens the level in the Scene mode (the scene whose LDtkLevel node shows it:
  `LevelMode_ScenesShowing`). Dragging a level moves it in the world (Free: anywhere, whole
  pixels; GridVania: on the world grid; linear layouts place levels by their order: read only),
  dragging an entity moves it in its level (on its layer's grid; Shift: by the pixel). Each move is
  one undo step written into the file.
- **The level panel** (right): what the selected level is, the scenes showing it (open them:
  `Level_Scene_Opened`), New Scene with This Level (`Level_Scene_Created`, a `.Project` step), the
  selected entity, Open in LDtk at this level.
- **The LDtk tab** (view_ldtk_tab.odin): Layers, Entities, Collisions, Links, Level fields, Enums,
  World, Tilesets, each item's settings edited and written back into the .ldtk file
  (ldtk_ops.odin: `LDtk_Edit`, a `.Files` undo step each).
- **LDtk itself:** Open in LDtk opens the file at the selected level (`LDtkEdit_OpenInLDtk`:
  LDtk's own "last level" setting, its command line has no level); LDtk's saves are read again
  when the editor next draws (the files' modification times), and the status bar says when the
  file changed outside the editor (`LDtkDoc_Outside`). An undo over a file LDtk changed since is
  merged when the two changes don't touch, else asked (`LevelMode.conflict`, the conflict dialog).

State (`State.level`): its panel sizes (`layout`, `Mode_Layout`), its bottom tab, the world shown
(`file`, an LDtk asset: "" the project's first; remembered in `.editor/modes.ini`), the selected
level and entity, the canvas's view and drag, the LDtk tab's choices. Its widgets:
`level-split-left`, `level-split-center-right`, `level-split-map-bottom`, `level-file`,
`level-fit`, `level-open-ldtk`, `ldtk-map-Level` (the canvas), `level-info-scroll`,
`level-open-scene-<i>`, `level-new-scene`, `level-manual`, `level-bottom-tabs`, the LDtk tab's
(view_ldtk_tab.odin), the conflict dialog's `ldtk-conflict-overwrite` / `-keep` / `-cancel`.
*/

// The Level mode's state
LevelMode :: struct {
	// Its panels: the browser's width, the level panel's, the bottom panel's height
	layout: Layout,
	// The bottom tab it shows (LDtk, Console or Output)
	bottomTab: BottomTab,
	// The LDtk project shown (an asset's path; "" the project's first; owned)
	file: string,
	// The selected level's identifier ("" none; owned)
	level: string,
	// The selected entity's iid ("" none; owned)
	entity: string,
	// The world canvas's view and the drag on it (level_canvas.odin)
	view: LevelView,
	drag: LevelDrag,
	// The LDtk tab's shown section and the item each section shows (definitions' uids; -1: the first)
	tab: LDtkTab,
	layerDef, entityDef, enumDef, intGridDef: int,
	// Why the last LDtk edit wasn't written ("" when it was; owned)
	problem: string,
	// Names typed for a new enum value and a new enum (owned)
	newValue, newEnum: string,
	// An undo or redo whose files changed outside the editor, waiting for the user's answer
	conflict: struct {
		open, undo: bool,
	},
}

// The world canvas's view: the world point at its center and the zoom (screen pixels per world
// pixel); fitted to the world when it first shows a file (`fitted`, owned)
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
}

// The LDtk tab's sections (its vertical tabs)
LDtkTab :: enum {
	Layers,
	Entities,
	Collisions,
	Links,
	Level_Fields,
	Enums,
	World,
	Tilesets,
}

// The Level mode's panels the first time it shows
LEVEL_LAYOUT_DEFAULT :: Layout{leftWidth = 240, rightWidth = 260, bottomHeight = 200, bottomOpen = true}

// A world picked in the Level mode's header (an LDtk asset's path; the frame's string)
Level_File_Chosen :: distinct string

// A level clicked (on the browser's world map while the Level mode shows: `level`, else ""), maybe a double-click
Level_Map_Clicked :: struct {
	file, level: string,
	double: bool,
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
	double, pan, free: bool,
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

// The header's Fit: the whole world in view
Level_Canvas_Fit :: struct {}

// An entity picked in the LDtk tab: selected and centered on the canvas (its iid; the frame's string)
Level_Entity_Picked :: distinct string

// The LDtk tab's section picked
LDtk_Tab_Picked :: distinct LDtkTab

// The item an LDtk tab section shows (a definition's uid)
LDtk_Item_Picked :: struct {
	tab: LDtkTab,
	uid: int,
}

// Typing in one of the LDtk tab's text fields: the text is kept while it has focus (State.numberEdit),
// written whenever it's a valid value (`edit.text`)
LDtk_Text_Typed :: struct {
	id: skald.Widget_ID,
	edit: LDtk_Edit,
}

// The name typed for a new enum value or enum (the frame's string)
LDtk_New_Name_Typed :: struct {
	enumValue: bool,
	text: string,
}

// What an LDtkLevel node makes of an IntGrid value, from the Collisions tab (a `.Project` step:
// the node may be in another scene than the open one)
Level_Collision_Kind_Changed :: struct {
	scene, node, value: int,
	kind: e.LDtkCollisionKind,
}

// The answer to an undo or redo whose LDtk files changed outside the editor
LDtkConflictChoice :: enum {
	// Write the step's text over the outside change
	Overwrite,
	// Keep the file as it is (the step and the ones before it are dropped)
	Keep_File,
	// Leave it for now (the step waits)
	Cancel,
}
LDtk_Conflict_Chosen :: distinct LDtkConflictChoice

// Frees the Level mode's state
LevelMode_Destroy :: proc(level: ^LevelMode) {
	delete(level.file)
	delete(level.level)
	delete(level.entity)
	delete(level.view.fitted)
	delete(level.drag.target)
	delete(level.problem)
	delete(level.newValue)
	delete(level.newEnum)
	layout, tab := level.layout, level.bottomTab
	level^ = {layout = layout, bottomTab = tab}
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
The Level mode's messages: its world and level, the canvas, the LDtk tab and its edits (written
into the LDtk project: ldtk_ops.odin), the conflict dialog. While the Level mode shows, a level
picked on the browser's world map selects it here instead of changing the hidden scene.

Returns:
- A command, and whether `m` was one
*/
LevelMode_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Level_File_Chosen:
		if string(v) == state.level.file do return {}, true
		setOwned(&state.level.file, string(v))
		levelSelect(state, "", "")
		Mode_Save(state)
	case Level_Map_Clicked:
		levelSelect(state, v.file, v.level)
		if !v.double || v.level == "" do return {}, true
		levelOpenShowing(state, v.file, v.level)
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
		levelCanvasPressed(state, v)
	case Level_Canvas_Moved:
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
		levelCanvasReleased(state)
	case Level_Entity_Picked:
		levelSelectEntity(state, string(v), center = true)

	// The LDtk tab
	case LDtk_Tab_Picked:
		state.level.tab = LDtkTab(v)
		setOwned(&state.level.problem, "")
	case LDtk_Item_Picked:
		setOwned(&state.level.problem, "")
		#partial switch v.tab {
		case .Layers: state.level.layerDef = v.uid
		case .Entities: state.level.entityDef = v.uid
		case .Enums: state.level.enumDef = v.uid
		case .Collisions: state.level.intGridDef = v.uid
		}
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
@(private="file")
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
Applies an LDtk tab edit: written into the file (ldtk_ops.odin), or why not kept for the tab to
show. A rename of a layer or an entity type is followed by the scenes' LDtkLevel nodes naming it
(their collision layer, their entity rules), in the same undo step.
*/
@(private="file")
levelApplyEdit :: proc(state: ^State, edit: LDtk_Edit) {
	problem, rename := LDtkOps_Apply(state.project.rootPath, edit)
	setOwned(&state.level.problem, problem)
	// A name added: its field is ready for the next
	if problem == "" && edit.op == .Enum_Value_Added do setOwned(&state.level.newValue, "")
	if problem == "" && edit.op == .Enum_Added do setOwned(&state.level.newEnum, "")
	if problem != "" || rename.kind == .None do return
	for &scene in state.project.scenes {
		if Scene_IsComponent(&scene) do continue
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

// A press on the canvas: selects what's under it, starts a pan or a move
@(private="file")
levelCanvasPressed :: proc(state: ^State, v: Level_Canvas_Pressed) {
	drag := &state.level.drag
	delete(drag.target)
	drag^ = {}
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	if v.pan || doc == nil || doc.problem != "" {
		drag.mode = .Pan
		return
	}
	switch {
	case v.entity != "":
		levelSelectEntity(state, v.entity, center = false)
		e, found := LDtkDoc_FindEntity(doc, v.entity)
		if !found do return
		json := LDtkDoc_Json(doc, e.file)
		px := Json_Get(json, e.node, "px")
		drag^ = {mode = .Entity, target = strings.clone(v.entity), start = v.world, origin = {f32(Json_Int(json, Json_At(json, px, 0))), f32(Json_Int(json, Json_At(json, px, 1)))}, free = v.free}
	case v.level != "":
		levelSelect(state, file, v.level)
		setOwned(&state.level.entity, "")
		if v.double {
			levelOpenShowing(state, file, v.level)
			return
		}
		level := LDtkDoc_FindLevel(doc, v.level)
		if level < 0 do return
		_, iid := LDtkDoc_LevelNames(doc, level)
		rect := LDtkDoc_LevelRect(doc, level)
		drag^ = {mode = .Level, target = strings.clone(iid), start = v.world, origin = {f32(rect[0]), f32(rect[1])}}
	case:
		// Empty space: nothing selected, the drag pans
		levelSelect(state, file, "")
		setOwned(&state.level.entity, "")
		drag.mode = .Pan
	}
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
	} else {
		levelApplyEdit(state, {op = .Entity_Moved, file = file, entity = drag.target, number = f64(to.x), number2 = f64(to.y)})
	}
	if state.level.problem != "" do logLine(state, .Warning, fmt.aprintf("Not moved: %s", state.level.problem))
}

// Selects an entity (and its level), shows it in the LDtk tab's Entities, maybe centered on the canvas
@(private="file")
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
	state.level.tab = .Entities
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

// Selects a level (and its file: the browser's map may show another one)
@(private="file")
levelSelect :: proc(state: ^State, file, level: string) {
	if file != state.level.file && file != "" {
		setOwned(&state.level.file, file)
		Mode_Save(state)
	}
	setOwned(&state.level.level, level)
	if level == "" do setOwned(&state.level.entity, "")
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
The Level mode's workspace: the browser, the world canvas over the bottom panel, the level panel.
Its panels' sizes are its own (`State.level.layout`); the dividers send the messages the Scene
mode's do, which change the shown mode's layout.
*/
levelModeView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	layout := Mode_LayoutOf(s, .Level)^
	layout.workspace = size
	left, right := FittedSidebarWidths(&layout)
	centerWidth := max(size.x - left - right - DIVIDER * 2, MIN_CENTER_WIDTH)
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
	centerAndRight := skald.split(ctx,
		first = center,
		second = levelInfoView(s, ctx),
		first_size = centerWidth,
		on_resize = proc(v: f32) -> Msg { return Center_Resized(v) },
		id = skald.hash_id("level-split-center-right"),
		min_first = MIN_CENTER_WIDTH,
		min_second = MIN_SIDEBAR_WIDTH,
	)
	return skald.split(ctx,
		first = browserView(s, ctx),
		second = centerAndRight,
		first_size = left,
		on_resize = proc(v: f32) -> Msg { return Left_Resized(v) },
		id = skald.hash_id("level-split-left"),
		min_first = MIN_SIDEBAR_WIDTH,
		min_second = MIN_CENTER_WIDTH + MIN_SIDEBAR_WIDTH + DIVIDER,
	)
}

// The center: a header (the world, a choice of LDtk files, Fit, Open in LDtk) over the world canvas
@(private="file")
levelMapView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	file := LevelMode_File(s)
	if file == "" {
		return skald.col(
			panelHeader(ctx, ICON_MAP, "World"),
			skald.col(
				skald.text("This project has no LDtk levels yet.", th.color.fg, th.font.size_sm),
				skald.text("Draw levels in LDtk (ldtk.io) and import the .ldtk file: its levels show here, laid out as in its world, to edit and to open in scenes.", th.color.fg_muted, th.font.size_xs, max_width = 420),
				skald.button(ctx, fmt.tprintf("%s  Import...", ICON_PLUS), Msg(Action.Import_Asset), id = skald.hash_id("level-import"),
					bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm),
				spacing = th.spacing.sm,
				padding = th.spacing.md,
			),
			cross_align = .Stretch,
			bg = th.color.bg,
		)
	}
	actions := make([dynamic]skald.View, context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	index := -1
	for asset, i in s.project.assets {
		if asset.kind != .LDtk do continue
		append(&files, asset.path)
		if asset.path == file do index = i
	}
	if len(files) > 1 {
		append(&actions, labeledSelect(ctx, file, Asset_DisplayNames(files[:]), files[:], 0, proc(_: int, path: string) -> Msg {
			return Level_File_Chosen(path)
		}, id = skald.hash_id("level-file"), width = 160))
	}
	if s.level.view.zoom > 0 do append(&actions, skald.text(fmt.tprintf("%.0f%%", s.level.view.zoom * 100), th.color.fg_muted, th.font.size_xs))
	append(&actions, panelButton(ctx, "level-fit", ICON_ZOOM, "Fit the world in view", Msg(Level_Canvas_Fit{})))
	append(&actions, panelButton(ctx, "level-open-ldtk", ICON_EXTERNAL, s.level.level != "" ? fmt.tprintf("Open in LDtk at %s", s.level.level) : "Open in LDtk", Msg(LDtk_Asset_Open_Requested(index))))
	doc := LDtkDoc_Get(s.project.rootPath, file)
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
	append(&rows, panelHeader(ctx, ICON_MAP, fmt.tprintf("World: %s", filepath.base(file)), ..actions[:]))
	if change, outside := LDtkDoc_Outside(s.project.rootPath, file); outside {
		append(&rows, skald.text(fmt.tprintf("%s  %s changed outside the editor at %s (saved in LDtk?): read again", ICON_REFRESH, change.file, levelClock(change.at)),
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

// The right panel: what the mode is, the selected level and entity, the scenes showing the level
@(private="file")
levelInfoView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	_, right := FittedSidebarWidths(Mode_LayoutOf(s, .Level))
	width := max(right - th.spacing.sm * 2 - 14, 120)
	rows := make([dynamic]skald.View, context.temp_allocator)
	small :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32, color: skald.Color = {}) -> skald.View {
		return skald.text(text, color == {} ? ctx.theme.color.fg_muted : color, ctx.theme.font.size_xs, max_width = width)
	}
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	file := LevelMode_File(s)
	doc := file != "" ? LDtkDoc_Get(s.project.rootPath, file) : nil
	if doc != nil && doc.problem != "" do doc = nil
	level := doc != nil && s.level.level != "" ? LDtkDoc_FindLevel(doc, s.level.level) : -1
	switch {
	case doc == nil:
		append(&rows, small(ctx, "Levels show here once the project has an LDtk file.", width))
	case level < 0:
		append(&rows, skald.text(fmt.tprintf("%d level%s", len(doc.levels), len(doc.levels) == 1 ? "" : "s"), th.color.fg, th.font.size_sm))
		append(&rows, small(ctx, "Click a level on the canvas to select it, double-click to open it in the Scene mode, drag it to move it in the world.", width))
	case:
		main := LDtkDoc_Main(doc)
		identifier, _ := LDtkDoc_LevelNames(doc, level)
		rect := LDtkDoc_LevelRect(doc, level)
		entities := 0
		for e in LDtkDoc_Entities(doc) do if e.level == level do entities += 1
		_, layers := LDtkDoc_LayerInstances(doc, level)
		layerCount := Json_Count(LDtkDoc_Json(doc, doc.levels[level].file), layers)
		fields := Json_Count(main, Json_Get(main, doc.levels[level].entry, "fieldInstances"))
		neighbours := len(LDtkDoc_Neighbours(doc, level))
		append(&rows, skald.text(fmt.tprintf("%s  %s", ICON_MAP, identifier), th.color.fg, th.font.size_sm, max_width = width))
		append(&rows, small(ctx, fmt.tprintf("%.0f x %.0f px, at %.0f, %.0f in the world", rect[2], rect[3], rect[0], rect[1]), width))
		append(&rows, small(ctx, fmt.tprintf("%d layer%s, %d entit%s, %d field%s, %d neighbour%s", layerCount, layerCount == 1 ? "" : "s",
			entities, entities == 1 ? "y" : "ies", fields, fields == 1 ? "" : "s", neighbours, neighbours == 1 ? "" : "s"), width))
		if e, found := LDtkDoc_FindEntity(doc, s.level.entity); found && s.level.entity != "" {
			json := LDtkDoc_Json(doc, e.file)
			px := Json_Get(json, e.node, "px")
			append(&rows, small(ctx, fmt.tprintf("Selected: %s at %d, %d (the LDtk tab's Entities edits it)", Json_String(json, Json_Get(json, e.node, "__identifier")),
				Json_Int(json, Json_At(json, px, 0)), Json_Int(json, Json_At(json, px, 1))), width, th.color.fg))
		}
		append(&rows, skald.spacer(th.spacing.xs))
		shown := LevelMode_ScenesShowing(s, file, identifier)
		if len(shown) == 0 {
			append(&rows, small(ctx, "No scene shows this level.", width))
			append(&rows, button(ctx, "level-new-scene", fmt.tprintf("%s  New Scene with This Level", ICON_PLUS), Msg(Level_Scene_Created{})))
		} else {
			append(&rows, small(ctx, "Shown in:", width))
			for at, i in shown {
				scene := &s.project.scenes[at.scene]
				label := fmt.tprintf("%s  %s (%s%s)", ICON_ARROW_RIGHT, scene.name, scene.nodes[at.node].name, at.allLevels ? ", the whole world" : "")
				append(&rows, button(ctx, fmt.tprintf("level-open-scene-%d", i), label, Msg(Level_Scene_Opened{at.scene, at.node})))
			}
		}
	}
	// What this mode is
	append(&rows, skald.spacer(th.spacing.sm), skald.divider(ctx), skald.spacer(th.spacing.xs),
		skald.text("Level mode", th.color.fg, th.font.size_sm),
		small(ctx, "Your game's world: the levels of an LDtk project, laid out as they are in it. Move levels and entities here, edit layers, entities, fields, enums and the world in the LDtk tab: it's all saved into the .ldtk file at once (undo with Ctrl+Z). Open a level in the Scene mode to place nodes, scripts and components around it.", width),
		button(ctx, "level-manual", fmt.tprintf("%s  Manual", ICON_CIRCLE_INFO), Msg(Manual_Opened("level_mode"))))
	return skald.col(
		panelHeader(ctx, ICON_CIRCLE_INFO, "Level"),
		skald.flex(1, skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.sm), id = skald.hash_id("level-info-scroll"))),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

/*
The status bar's middle in the Level mode: the world, the selected level, and (when it happened)
when the LDtk file last changed outside the editor.
*/
LevelMode_Status :: proc(s: ^State) -> (world, level, outside: string) {
	file := LevelMode_File(s)
	world = file == "" ? "World: none" : fmt.tprintf("World: %s", filepath.base(file))
	level = s.level.level == "" ? "Level: none selected" : fmt.tprintf("Level: %s", s.level.level)
	if change, found := LDtkDoc_Outside(s.project.rootPath, file); found && file != "" do outside = fmt.tprintf("%s changed outside at %s", change.file, levelClock(change.at))
	return
}

/*
Asks what to do when an undo or redo would write over an LDtk file changed outside the editor
since (LDtk saved it) and the two changes touch: overwrite the outside change, keep the file (the
step goes), or wait.
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
			skald.text(fmt.tprintf("%s \"%s\" would write over what changed in %s since (saved in LDtk?).", what, label, file), th.color.fg_muted, th.font.size_sm, max_width = 460),
			skald.text("Overwrite puts the editor's version back; Keep the File leaves it as it is and drops this step (and the older ones of the history).", th.color.fg_muted, th.font.size_sm, max_width = 460),
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
