package crossfire_editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

/*
The Level mode's edits of levels and worlds (phase 5 of TODO.md's "LDtk level editor"), as LDtk
makes them (its data/World.hx, data/Level.hx, data/Project.hx, ui/vp/LevelSpotPicker.hx,
WorldTool.hx, display/Rulers.hx, ui/LevelInstanceForm.hx, ui/modal/panel/WorldPanel.hx):

- **New level** (`Level_Added`, World.createLevel and LevelSpotPicker.tryToCreateLevelAt): at a
  world point, the world's default size, placed as LDtk places it (Free and GridVania: centered on
  the point, pushed off the levels it overlaps, snapped to the world grid or, with the grid shown,
  to the project's; refused where it can't go: "no room"), or inserted in a linear world's order
  where the point is. The new level has LDtk's defaults (an automatic name from the project's
  pattern, its layers and fields, the current depth).
- **Duplicate** (World.duplicateLevel): a copy after it with new iids (its layers' and entities'),
  references between its own entities pointing at the copies, references out of it dropped; moved
  by 4 default grid cells in Free and GridVania worlds (the menu's), or put where a Ctrl + Alt
  drag left it.
- **Delete** (World.removeLevel): never the world's last level; references to its entities go.
- **Resize** (Level.applyNewBounds, LayerInstance.applyNewBounds): every layer's cells moved by
  the cells the left and top edges moved and cropped to the new size, entities moved with them
  (removed when they leave the level, unless their type allows it), points moved, auto-layers
  worked out again; its world position follows its left and top edges.
- **The level's settings** (`Level_Set`): its name (LDtk's input is off while the name is
  automatic), automatic naming, depth, background color (none: the project's default),
  background image, its position and pivot. Depth further / closer (`Level_Depth`:
  World.moveLevelToDepthFurther / Closer), its place in its world's order (`Level_Sorted`:
  World.sortLevel, a linear world's drag), moved to another world (`Level_World_Moved`).
- **Worlds** (`World_Added`, `World_Removed`, `World_Set`): Project.createWorld (LDtk's
  Multi-worlds option turned on with it, the project's one world becoming the first of
  `worlds`), removeWorld (never the last), a world's name and new levels' size.

Each edit ends as every definition edit does (ldtk_defs.odin): LDtk's tidy (ldtk_tidy.odin, with
the levels' part here: automatic names, background colors and positions, the default level size on
a GridVania grid, the level files' names), then neighbours, entities' world positions and the table
of contents; one undo step.
*/

// LDtk's defaults (Project.DEFAULT_*)
LDTK_DEFAULT_LEVEL_SIZE :: 256
LDTK_DEFAULT_GRID_SIZE :: 16
LDTK_DEFAULT_LEVEL_NAME_PATTERN :: "Level_%idx"
LDTK_DEFAULT_LEVEL_BG :: 0x696A79
// A level's background image positions (ldtk.Json.BgImagePos)
LDTK_BG_POSITIONS :: []string{"Unscaled", "Contain", "Cover", "CoverDirty", "Repeat"}
// LDtk's project flags (ldtk.Json.ProjectFlag), in its order: the order LDtk writes them in
LDTK_PROJECT_FLAGS :: []string{"DiscardPreCsvIntGrid", "ExportOldTableOfContentData", "ExportPreCsvIntGridFormat", "IgnoreBackupSuggest", "PrependIndexToLevelFileNames", "MultiWorlds", "UseMultilinesType"}

/*
Makes a level or world edit (`Level_Added`, `Level_Removed`, `Level_Duplicated`, `Level_Set`,
`Level_Depth`, `Level_Resized`, `Level_Sorted`, `Level_World_Moved`, `World_Added`,
`World_Removed`, `World_Set`; and the moves of ldtk_ops.odin's `Level_X`, `Level_Y`,
`Level_Moved`, `World_Layout`, `World_Grid_Width`, `World_Grid_Height` once their patches are
made: `LDtkOps_LevelsFinish`) in the document in memory.

Returns:
- "" or why nothing changed
*/
LDtkOps_LevelEdit :: proc(root: string, doc: ^LDtkDoc, edit: LDtk_Edit) -> (problem: string) {
	s := stagesMake(doc)
	defer if problem != "" do for d in s.made do LDtkDoc_Free(d)
	#partial switch edit.op {
	case .Level_Added:       problem = levelAdded(&s, edit)
	case .Level_Removed:     problem = levelRemoved(&s, edit)
	case .Level_Duplicated:  problem = levelDuplicated(&s, edit)
	case .Level_Set:         problem = levelSet(&s, edit)
	case .Level_Depth:       problem = levelDepth(&s, edit)
	case .Level_Resized:     problem = levelResized(&s, edit)
	case .Level_Sorted:      problem = levelSorted(&s, edit)
	case .Level_World_Moved: problem = levelToWorld(&s, edit)
	case .World_Added:       problem = worldAdded(&s, edit)
	case .World_Removed:     problem = worldRemoved(&s, edit)
	case .World_Set:         problem = worldSet(&s, edit)
	case:                    problem = "not a level edit"
	}
	if problem != "" do return
	if len(s.made) == 0 do return ""
	return LDtkOps_LevelsFinish(&s)
}

/*
The end of a level or world edit, after its own stages: LDtk's tidy (the levels' part included),
neighbours and entities' world positions, the table of contents; then the document gets the texts.
*/
@(private)
LDtkOps_LevelsFinish :: proc(s: ^Stages) -> string {
	if problem := LDtkTidy_Run(s); problem != "" do return problem
	p := LDtkPatches{}
	refreshNeighbours(&p, s.cur)
	refreshWorldPositions(&p, s.cur)
	if problem := stagesApply(s, &p); problem != "" do return problem
	p = {}
	ldtkTocPatches(&p, s.cur)
	if problem := stagesApply(s, &p); problem != "" do return problem
	result := stagesFinish(s, "")
	s.made = nil
	return result
}

// --- What a world is ----------------------------------------------------------------------------

// Whether a project has LDtk's Multi-worlds option (levels in `worlds`)
LDtkDoc_MultiWorlds :: proc(doc: ^LDtkDoc) -> bool {
	return LDtkDoc_HasFlag(doc, "MultiWorlds")
}

// Whether a project has one of LDtk's flags (`flags`)
LDtkDoc_HasFlag :: proc(doc: ^LDtkDoc, flag: string) -> bool {
	main := LDtkDoc_Main(doc)
	for f in Json_Items(main, Json_Get(main, Json_Root(main), "flags")) do if Json_String(main, f) == flag do return true
	return false
}

// A world's size for new levels (World.defaultLevelWidth / Height)
LDtkDoc_WorldLevelSize :: proc(doc: ^LDtkDoc, world: int) -> [2]int {
	main := LDtkDoc_Main(doc)
	o := doc.worlds[world].object
	return {max(Json_Int(main, Json_Get(main, o, "defaultLevelWidth"), LDTK_DEFAULT_LEVEL_SIZE), 1), max(Json_Int(main, Json_Get(main, o, "defaultLevelHeight"), LDTK_DEFAULT_LEVEL_SIZE), 1)}
}

// New levels' background color (Project.defaultLevelBgColor: else the workspace's `bgColor`, else LDtk's)
LDtkDoc_DefaultLevelBg :: proc(doc: ^LDtkDoc) -> int {
	main := LDtkDoc_Main(doc)
	root := Json_Root(main)
	if c, ok := LDtk_ParseColor(Json_String(main, Json_Get(main, root, "defaultLevelBgColor"))); ok do return c
	if c, ok := LDtk_ParseColor(Json_String(main, Json_Get(main, root, "bgColor"))); ok do return c
	return 0x40465B
}

// The project's default grid size (`defaultGridSize`)
LDtkDoc_DefaultGrid :: proc(doc: ^LDtkDoc) -> int {
	main := LDtkDoc_Main(doc)
	return max(Json_Int(main, Json_Get(main, Json_Root(main), "defaultGridSize"), LDTK_DEFAULT_GRID_SIZE), 1)
}

// A level's depth in its world (`worldDepth`)
LDtkDoc_LevelDepth :: proc(doc: ^LDtkDoc, level: int) -> int {
	main := LDtkDoc_Main(doc)
	return Json_Int(main, Json_Get(main, doc.levels[level].entry, "worldDepth"))
}

// The levels of a world, in its order (indexes into `doc.levels`; temp)
@(private)
worldLevels :: proc(doc: ^LDtkDoc, world: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for l, i in doc.levels do if l.world == world do append(&out, i)
	return out[:]
}

// Every level's identifier (temp; `except` left out)
@(private="file")
levelIdentifiers :: proc(doc: ^LDtkDoc, except := -1) -> map[string]bool {
	out := make(map[string]bool, len(doc.levels), context.temp_allocator)
	for _, i in doc.levels {
		if i == except do continue
		id, _ := LDtkDoc_LevelNames(doc, i)
		out[strings.clone(id, context.temp_allocator)] = true
	}
	return out
}

// A level's index by identifier or iid in the stage's document, or why not
@(private="file")
findLevel :: proc(s: ^Stages, name: string) -> (int, string) {
	level := LDtkDoc_FindLevel(s.cur, name)
	if level < 0 do return -1, "no such level"
	return level, ""
}

// A level's whole value as LDtk writes it alone (its entry, with its layers from its .ldtkl file)
@(private="file")
levelWholeJV :: proc(doc: ^LDtkDoc, level: int) -> LDtkJV {
	l := doc.levels[level]
	main := LDtkDoc_Main(doc)
	v := ldtkJV(main, l.entry)
	if l.file == 0 do return v
	json := LDtkDoc_Json(doc, l.file)
	layers := ldtkJV(json, Json_Get(json, l.node, "layerInstances"))
	obj := v.(LDtkJObject)
	for &pair in obj do if pair.key == "layerInstances" do pair.value = layers
	return obj
}

// An object's member set (or added at the end; temp)
@(private)
jvWith :: proc(v: LDtkJV, key: string, value: LDtkJV) -> LDtkJV {
	obj, ok := v.(LDtkJObject)
	if !ok do return v
	out := make([dynamic]LDtkJPair, 0, len(obj) + 1, context.temp_allocator)
	found := false
	for pair in obj {
		if pair.key == key {
			append(&out, LDtkJPair{key, value})
			found = true
		} else {
			append(&out, pair)
		}
	}
	if !found do append(&out, LDtkJPair{key, value})
	return LDtkJObject(out[:])
}

// An object's member, or `default` when it has none or it's null
@(private)
jvOr :: proc(v: LDtkJV, key: string, default: LDtkJV) -> LDtkJV {
	x := jvGet(v, key)
	if x == nil do return default
	if _, isNull := x.(LDtkJNull); isNull do return default
	return x
}

// An object's member (nil when it has none)
@(private)
jvGet :: proc(v: LDtkJV, key: string) -> LDtkJV {
	obj, ok := v.(LDtkJObject)
	if !ok do return nil
	for pair in obj do if pair.key == key do return pair.value
	return nil
}

/*
A level's own file path for a project saving levels apart, as LDtk names it on save
(Level.makeExternalRelPath): `<project name>/<identifier>.ldtkl`, with its index across every
world first (`0000-`) under the PrependIndexToLevelFileNames flag.
*/
LDtk_LevelFileName :: proc(projectFile, identifier: string, index: int, prependIndex: bool) -> string {
	base := filepath.base(projectFile)
	stem := strings.trim_suffix(base, filepath.ext(base))
	if prependIndex do return fmt.tprintf("%s/%04d-%s.ldtkl", stem, index, identifier)
	return fmt.tprintf("%s/%s.ldtkl", stem, identifier)
}

// Whether the project saves its levels apart (`externalLevels`)
LDtkDoc_ExternalLevels :: proc(doc: ^LDtkDoc) -> bool {
	main := LDtkDoc_Main(doc)
	return Json_Bool(main, Json_Get(main, Json_Root(main), "externalLevels"))
}

// The file's `__header__` (LDtk's Const.JSON_HEADER), or LDtk 1.5.3's
@(private)
ldtkHeaderJV :: proc(doc: ^LDtkDoc) -> LDtkJV {
	main := LDtkDoc_Main(doc)
	if h := Json_Get(main, Json_Root(main), "__header__"); h >= 0 do return ldtkJV(main, h)
	return jobject(jpair("fileType", "LDtk Project JSON"), jpair("app", "LDtk"), jpair("doc", "https://ldtk.io/json"),
		jpair("schema", "https://ldtk.io/files/JSON_SCHEMA.json"), jpair("appAuthor", "Sebastien 'deepnight' Benard"),
		jpair("appVersion", "1.5.3"), jpair("url", "https://ldtk.io"))
}

/*
Writes a world's levels array again from level values (kept ones as their text, new ones as LDtk
writes them); a level saved apart is given its .ldtkl file (`levelFile`) and its entry is the
project file's (no layers, its file named).
*/
@(private="file")
worldLevelsWrite :: proc(s: ^Stages, p: ^LDtkPatches, world: int, items: []string) {
	ldtkRebuildRows(p, s.cur, 0, s.cur.worlds[world].levels, items)
}

// A new level's file for a project saving levels apart: its whole value with LDtk's header,
// `externalRelPath` null (LDtk's own files say so)
@(private="file")
levelFileText :: proc(doc: ^LDtkDoc, whole: LDtkJV) -> string {
	v := jvWith(whole, "externalRelPath", LDtkJNull{})
	obj := v.(LDtkJObject)
	out := make([dynamic]LDtkJPair, 0, len(obj) + 1, context.temp_allocator)
	append(&out, LDtkJPair{"__header__", ldtkHeaderJV(doc)})
	for pair in obj do if pair.key != "__header__" do append(&out, pair)
	return LDtk_PrettyJson(LDtkJObject(out[:]), Json_Minified(LDtkDoc_Main(doc)), 0)
}

/*
A level's entry text for its world's levels array (`whole`: the level with its layers): saved
apart, its layers go to its file (`s.added`) and the entry names it.
*/
@(private="file")
levelEntryText :: proc(s: ^Stages, world: int, whole: LDtkJV, index: int) -> string {
	doc := s.cur
	array := doc.worlds[world].levels
	if !LDtkDoc_ExternalLevels(doc) do return ldtkItemText(doc, 0, array, jvWith(whole, "externalRelPath", LDtkJNull{}))
	id, _ := jvGet(whole, "identifier").(string)
	rel := LDtk_LevelFileName(doc.files[0].path, id, index, LDtkDoc_HasFlag(doc, "PrependIndexToLevelFileNames"))
	s.added[joinPath(LDtkDoc_Folder(doc), rel, allocator = context.temp_allocator)] = levelFileText(doc, whole)
	entry := jvWith(jvWith(whole, "externalRelPath", rel), "layerInstances", LDtkJNull{})
	return ldtkItemText(doc, 0, array, entry)
}

// A level's index across every world (LDtk's level file index)
@(private="file")
levelGlobalIndex :: proc(doc: ^LDtkDoc, world, inWorld: int) -> int {
	n := 0
	for _, w in doc.worlds {
		if w == world do return n + inWorld
		n += len(worldLevels(doc, w))
	}
	return n
}

// The texts of a world's level entries, in order (temp)
@(private="file")
worldEntryTexts :: proc(doc: ^LDtkDoc, world: int) -> [dynamic]string {
	main := LDtkDoc_Main(doc)
	out := make([dynamic]string, context.temp_allocator)
	for entry in Json_Items(main, doc.worlds[world].levels) do append(&out, strings.clone(Json_Text(main, entry), context.temp_allocator))
	return out
}

// --- New levels ---------------------------------------------------------------------------------

/*
A new level's value as LDtk writes one (Level.toJson of `new Level`): LDtk's defaults, no layers
or fields yet (the tidy adds them: Level.tidy), its world position stored only in Free and
GridVania worlds.
*/
@(private="file")
newLevelJV :: proc(doc: ^LDtkDoc, world: int, identifier, iid: string, uid, x, y, w, h, depth: int) -> LDtkJV {
	bg := LDtkDoc_DefaultLevelBg(doc)
	layout := LDtkDoc_WorldLayout(doc, world)
	linear := layout == "LinearHorizontal" || layout == "LinearVertical"
	return jobject(
		jpair("identifier", identifier),
		jpair("iid", iid),
		jpair("uid", i64(uid)),
		jpair("worldX", i64(linear ? -1 : x)),
		jpair("worldY", i64(linear ? -1 : y)),
		jpair("worldDepth", i64(depth)),
		jpair("pxWid", i64(w)),
		jpair("pxHei", i64(h)),
		jpair("__bgColor", LDtk_FormatColor(bg)),
		jpair("bgColor", LDtkJNull{}),
		jpair("useAutoIdentifier", true),
		jpair("bgRelPath", LDtkJNull{}),
		jpair("bgPos", LDtkJNull{}),
		jpair("bgPivotX", 0.5),
		jpair("bgPivotY", 0.5),
		jpair("__smartColor", LDtk_FormatColor(ldtkToWhite(bg, 0.45))),
		jpair("__bgPos", LDtkJNull{}),
		jpair("externalRelPath", LDtkJNull{}),
		jpair("fieldInstances", LDtkJArray{}),
		jpair("layerInstances", LDtkJArray{}),
		jpair("__neighbours", LDtkJArray{}),
	)
}

// Where LDtk would put a new level for a world point (LevelSpotPicker.getLevelInsertBounds)
LDtkLevelSpot :: struct {
	x, y, w, h: f64,
	// It would overlap a level (nothing is made there)
	overlaps: bool,
	// A linear world: the place in its order
	index: int,
	ok: bool,
}

/*
Where a new level goes for a world point, as LDtk's level spot picker finds it: Free and
GridVania: the world's default size centered on the point, moved off each level it overlaps (to
the side the point is on), refused when it still overlaps one or the point is on a level; snapped
to the world grid (GridVania) or the project's grid (`snap`: LDtk's grid shown). Linear worlds:
the nearest place between levels.

Inputs:
- world: The world (an index into `doc.worlds`)
- point: The world point
- depth: The world depth shown (levels of other depths don't count)
- snap: The grid is shown (Free worlds snap to the project's grid then)
*/
LDtk_LevelSpot :: proc(doc: ^LDtkDoc, world: int, point: [2]f64, depth: int, snap: bool) -> LDtkLevelSpot {
	size := LDtkDoc_WorldLevelSize(doc, world)
	b := LDtkLevelSpot{x = point.x - f64(size.x) * 0.5, y = point.y - f64(size.y) * 0.5, w = f64(size.x), h = f64(size.y), ok = true}
	layout := LDtkDoc_WorldLayout(doc, world)
	levels := worldLevels(doc, world)
	overlaps :: proc(r: [4]f64, x, y, w, h: f64) -> bool {
		return x < r[0] + r[2] && x + w > r[0] && y < r[1] + r[3] && y + h > r[1]
	}
	switch layout {
	case "LinearHorizontal", "LinearVertical":
		at, coord := linearInsertPoint(doc, world, point, -1)
		if at < 0 do return {}
		b.index = at
		if layout == "LinearHorizontal" {
			b.x = coord - b.w * 0.5
			b.y = -b.h * 0.1
			b.h += f64(int(b.h * 0.2))
		} else {
			b.x = -b.w * 0.1
			b.y = coord - b.h * 0.5
			b.w += f64(int(b.w * 0.2))
		}
		return b
	}
	onLevel := false
	for l in levels {
		r := LDtkDoc_LevelRect(doc, l)
		if point.x >= r[0] && point.x < r[0] + r[2] && point.y >= r[1] && point.y < r[1] + r[3] do onLevel = true
	}
	if onLevel {
		b.overlaps = true
	} else {
		// Pushed off each level it overlaps (the side of the line from that level's center)
		for l in levels {
			r := LDtkDoc_LevelRect(doc, l)
			if !overlaps(r, b.x, b.y, b.w, b.h) do continue
			cx, cy := math.round(r[0] + r[2] * 0.5), math.round(r[1] + r[3] * 0.5)
			slope := ((b.y + b.h * 0.5) - cy) / ((b.x + b.w * 0.5) - cx)
			if slope * r[2] * 0.5 >= -r[3] * 0.5 && slope * r[2] * 0.5 <= r[3] * 0.5 {
				b.x = b.x < cx ? r[0] - b.w : r[0] + r[2]
			} else {
				b.y = b.y < cy ? r[1] - b.h : r[1] + r[3]
			}
		}
		for l in levels do if overlaps(LDtkDoc_LevelRect(doc, l), b.x, b.y, b.w, b.h) {
			b.overlaps = true
			break
		}
	}
	if layout == "GridVania" {
		grid := LDtkDoc_WorldGrid(doc, world)
		b.x = ldtkRound(b.x / f64(grid.x)) * f64(grid.x)
		b.y = ldtkRound(b.y / f64(grid.y)) * f64(grid.y)
	} else if snap {
		g := f64(LDtkDoc_DefaultGrid(doc))
		b.x = ldtkRound(b.x / g) * g
		b.y = ldtkRound(b.y / g) * g
	}
	_ = depth
	return b
}

/*
A linear world's place for a world point (LevelSpotPicker.getLinearInsertPoint): before each level
(its start) or after the last, the nearest to the point. `moved`: a level being dragged (its place
counts at its start then, and the end isn't offered when it's the last).

Returns:
- The index to insert at and its coordinate, -1 when there's none
*/
@(private)
linearInsertPoint :: proc(doc: ^LDtkDoc, world: int, point: [2]f64, moved: int, movedOrigin: f64 = 0) -> (index: int, coord: f64) {
	levels := worldLevels(doc, world)
	if len(levels) <= 1 && moved >= 0 do return -1, 0
	horizontal := LDtkDoc_WorldLayout(doc, world) == "LinearHorizontal"
	best := math.INF_F64
	index = -1
	consider :: proc(at: int, c, p: f64, best: ^f64, index: ^int, coord: ^f64) {
		d := abs(p - c)
		if d < best^ {
			best^ = d
			index^ = at
			coord^ = c
		}
	}
	p := horizontal ? point.x : point.y
	for l, i in levels {
		r := LDtkDoc_LevelRect(doc, l)
		c := horizontal ? r[0] : r[1]
		if l == moved do c = movedOrigin
		consider(i, c, p, &best, &index, &coord)
	}
	if len(levels) > 0 {
		last := levels[len(levels) - 1]
		if last != moved {
			r := LDtkDoc_LevelRect(doc, last)
			consider(len(levels), horizontal ? r[0] + r[2] : r[1] + r[3], p, &best, &index, &coord)
		}
	}
	return
}

@(private="file")
levelAdded :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	doc := s.cur
	world := edit.world
	if world < 0 || world >= len(doc.worlds) do return "no such world"
	depth := edit.index
	spot := LDtk_LevelSpot(doc, world, {edit.number, edit.number2}, depth, edit.flag)
	if !spot.ok || spot.overlaps do return "No room for a level here! Pick another spot."
	layout := LDtkDoc_WorldLayout(doc, world)
	linear := layout == "LinearHorizontal" || layout == "LinearVertical"
	size := LDtkDoc_WorldLevelSize(doc, world)
	uids := uidsMake(doc)
	uid := uidTake(&uids)
	identifier := ldtkUniqueId("Level1", defStyle(doc), levelIdentifiers(doc))
	iid := edit.text != "" ? edit.text : LDtk_NewIid()
	x, y := int(math.round(spot.x)), int(math.round(spot.y))
	whole := newLevelJV(doc, world, identifier, iid, uid, x, y, size.x, size.y, linear ? 0 : depth)
	texts := worldEntryTexts(doc, world)
	at := linear ? clamp(spot.index, 0, len(texts)) : len(texts)
	inject_at(&texts, at, levelEntryText(s, world, whole, levelGlobalIndex(doc, world, at)))
	p := LDtkPatches{}
	worldLevelsWrite(s, &p, world, texts[:])
	uidsDone(&p, doc, uids)
	return stagesApply(s, &p)
}

// --- Removing, copying, ordering ----------------------------------------------------------------

/*
The patches removing every entity reference to any of some iids (Project.removeAnyFieldRefsTo for
each): a single reference becomes the default, an array loses the items.
*/
@(private)
removeRefsToAny :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, iids: map[string]bool, minified: bool) {
	if len(iids) == 0 do return
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		for fi in Json_Items(json, Json_Get(json, e.node, "fieldInstances")) {
			t := Json_String(json, Json_Get(json, fi, "__type"))
			if t != "EntityRef" && t != "Array<EntityRef>" do continue
			value := Json_Get(json, fi, "__value")
			raw := Json_Get(json, fi, "realEditorValues")
			if t == "EntityRef" {
				if Json_String(json, Json_Get(json, value, "entityIid")) in iids {
					LDtkPatches_Set(p, doc, e.file, value, "null")
					LDtkPatches_Set(p, doc, e.file, raw, "[]")
				}
				continue
			}
			values := Json_Items(json, value)
			raws := Json_Items(json, raw)
			keptValues := make([dynamic]LDtkJV, context.temp_allocator)
			keptRaws := make([dynamic]LDtkJV, context.temp_allocator)
			removed := false
			for v, i in values {
				if Json_String(json, Json_Get(json, v, "entityIid")) in iids {
					removed = true
					continue
				}
				append(&keptValues, ldtkJV(json, v))
				if i < len(raws) do append(&keptRaws, ldtkJV(json, raws[i]))
			}
			if !removed do continue
			LDtkPatches_Set(p, doc, e.file, value, writeAt(json, fi, LDtkJArray(keptValues[:]), minified))
			LDtkPatches_Set(p, doc, e.file, raw, writeAt(json, fi, LDtkJArray(keptRaws[:]), minified))
		}
	}
}

// The iids of a level's entities (temp)
@(private="file")
levelEntityIids :: proc(doc: ^LDtkDoc, level: int) -> map[string]bool {
	out := make(map[string]bool, context.temp_allocator)
	for e in LDtkDoc_Entities(doc) {
		if e.level != level do continue
		json := LDtkDoc_Json(doc, e.file)
		out[strings.clone(Json_String(json, Json_Get(json, e.node, "iid")), context.temp_allocator)] = true
	}
	return out
}

@(private="file")
levelRemoved :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	level, why := findLevel(s, edit.level)
	if why != "" do return why
	doc := s.cur
	world := doc.levels[level].world
	levels := worldLevels(doc, world)
	if len(levels) <= 1 do return "You can't delete the last level."
	iids := levelEntityIids(doc, level)
	texts := make([dynamic]string, context.temp_allocator)
	main := LDtkDoc_Main(doc)
	for l in levels do if l != level do append(&texts, strings.clone(Json_Text(main, doc.levels[l].entry), context.temp_allocator))
	p := LDtkPatches{}
	worldLevelsWrite(s, &p, world, texts[:])
	if problem := stagesApply(s, &p); problem != "" do return problem
	refs := LDtkPatches{}
	removeRefsToAny(&refs, s.cur, iids, Json_Minified(LDtkDoc_Main(s.cur)))
	return stagesApply(s, &refs)
}

/*
A level's copy (World.duplicateLevel): its JSON with new iids and uid, its layers' `levelId`,
references between its entities pointing at the copies, others dropped.
*/
@(private="file")
levelCopyJV :: proc(doc: ^LDtkDoc, level: int, identifier, iid: string, uid: int) -> LDtkJV {
	whole := levelWholeJV(doc, level)
	remap := make(map[string]string, context.temp_allocator)
	for old in levelEntityIids(doc, level) do remap[old] = LDtk_NewIid()
	fixEntity :: proc(e: LDtkJV, remap: map[string]string) -> LDtkJV {
		out := e
		if old, ok := jvGet(e, "iid").(string); ok do out = jvWith(out, "iid", remap[old] or_else old)
		fields, _ := jvGet(e, "fieldInstances").(LDtkJArray)
		newFields := make([]LDtkJV, len(fields), context.temp_allocator)
		for f, i in fields {
			t, _ := jvGet(f, "__type").(string)
			newFields[i] = f
			if t != "EntityRef" && t != "Array<EntityRef>" do continue
			raws, _ := jvGet(f, "realEditorValues").(LDtkJArray)
			kept := make([dynamic]LDtkJV, context.temp_allocator)
			for r in raws {
				params, _ := jvGet(r, "params").(LDtkJArray)
				target := ""
				if len(params) > 0 do target, _ = params[0].(string)
				to, inside := remap[target]
				if !inside do continue
				append(&kept, jvWith(r, "params", jarray(to)))
			}
			newFields[i] = jvWith(f, "realEditorValues", LDtkJArray(kept[:]))
		}
		return jvWith(out, "fieldInstances", LDtkJArray(newFields))
	}
	layers, _ := jvGet(whole, "layerInstances").(LDtkJArray)
	newLayers := make([]LDtkJV, len(layers), context.temp_allocator)
	for li, i in layers {
		x := jvWith(jvWith(li, "iid", LDtk_NewIid()), "levelId", i64(uid))
		entities, _ := jvGet(li, "entityInstances").(LDtkJArray)
		newEntities := make([]LDtkJV, len(entities), context.temp_allocator)
		for e, j in entities do newEntities[j] = fixEntity(e, remap)
		newLayers[i] = jvWith(x, "entityInstances", LDtkJArray(newEntities))
	}
	out := jvWith(jvWith(jvWith(whole, "iid", iid), "uid", i64(uid)), "identifier", identifier)
	out = jvWith(out, "layerInstances", LDtkJArray(newLayers))
	return jvWith(out, "__neighbours", LDtkJArray{})
}

@(private="file")
levelDuplicated :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	level, why := findLevel(s, edit.level)
	if why != "" do return why
	doc := s.cur
	world := doc.levels[level].world
	layout := LDtkDoc_WorldLayout(doc, world)
	identifier, _ := LDtkDoc_LevelNames(doc, level)
	uids := uidsMake(doc)
	uid := uidTake(&uids)
	iid := edit.text != "" ? edit.text : LDtk_NewIid()
	copy := levelCopyJV(doc, level, ldtkUniqueId(identifier, defStyle(doc), levelIdentifiers(doc)), iid, uid)
	if layout == "Free" || layout == "GridVania" {
		rect := LDtkDoc_LevelRect(doc, level)
		x, y := int(rect[0]), int(rect[1])
		if edit.flag {
			// The menu's copy: 4 default grid cells down and right (WorldPanel, WorldTool)
			g := LDtkDoc_DefaultGrid(doc) * 4
			x, y = x + g, y + g
		} else {
			x, y = int(math.round(edit.number)), int(math.round(edit.number2))
		}
		copy = jvWith(jvWith(copy, "worldX", i64(x)), "worldY", i64(y))
	}
	levels := worldLevels(doc, world)
	at, _ := slice.linear_search(levels, level)
	texts := worldEntryTexts(doc, world)
	inject_at(&texts, at + 1, levelEntryText(s, world, copy, levelGlobalIndex(doc, world, at + 1)))
	p := LDtkPatches{}
	worldLevelsWrite(s, &p, world, texts[:])
	uidsDone(&p, doc, uids)
	return stagesApply(s, &p)
}

@(private="file")
levelSorted :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	level, why := findLevel(s, edit.level)
	if why != "" do return why
	doc := s.cur
	world := doc.levels[level].world
	levels := worldLevels(doc, world)
	from, _ := slice.linear_search(levels, level)
	to := clamp(int(math.round(edit.number)), 0, len(levels) - 1)
	if to == from do return ""
	texts := worldEntryTexts(doc, world)
	moved := texts[from]
	ordered_remove(&texts, from)
	inject_at(&texts, to, moved)
	p := LDtkPatches{}
	worldLevelsWrite(s, &p, world, texts[:])
	return stagesApply(s, &p)
}

// Level.moveToWorld: the level goes last in another world
@(private="file")
levelToWorld :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	level, why := findLevel(s, edit.level)
	if why != "" do return why
	doc := s.cur
	from := doc.levels[level].world
	to := edit.world
	if to < 0 || to >= len(doc.worlds) do return "no such world"
	if to == from do return ""
	main := LDtkDoc_Main(doc)
	moved := strings.clone(Json_Text(main, doc.levels[level].entry), context.temp_allocator)
	rest := make([dynamic]string, context.temp_allocator)
	for l in worldLevels(doc, from) do if l != level do append(&rest, strings.clone(Json_Text(main, doc.levels[l].entry), context.temp_allocator))
	target := worldEntryTexts(doc, to)
	// At the target array's indentation (the worlds' arrays are at the same depth)
	append(&target, ldtkItemText(doc, 0, doc.worlds[to].levels, ldtkJV(main, doc.levels[level].entry)))
	_ = moved
	p := LDtkPatches{}
	worldLevelsWrite(s, &p, from, rest[:])
	worldLevelsWrite(s, &p, to, target[:])
	if problem := stagesApply(s, &p); problem != "" do return problem
	// Placed by the new world's layout (World.reorganizeWorld)
	return levelsReorganize(s)
}

/*
Linear worlds' stored positions (-1, as LDtk's Level.toJson writes them), after a level moved
between worlds.
*/
@(private="file")
levelsReorganize :: proc(s: ^Stages) -> string {
	doc := s.cur
	p := LDtkPatches{}
	for _, level in doc.levels {
		layout := LDtkDoc_WorldLayout(doc, doc.levels[level].world)
		if layout != "LinearHorizontal" && layout != "LinearVertical" do continue
		for place in LDtkDoc_LevelObjects(doc, level) {
			json := LDtkDoc_Json(doc, place.file)
			LDtkPatches_Set(&p, doc, place.file, Json_Get(json, place.node, "worldX"), "-1")
			LDtkPatches_Set(&p, doc, place.file, Json_Get(json, place.node, "worldY"), "-1")
		}
	}
	return stagesApply(s, &p)
}

// --- A level's settings -------------------------------------------------------------------------

// Writes a member in every copy of a level's settings (its entry, its .ldtkl object)
@(private)
levelWrite :: proc(p: ^LDtkPatches, doc: ^LDtkDoc, level: int, key: string, v: LDtkJV) {
	for place in LDtkDoc_LevelObjects(doc, level) {
		json := LDtkDoc_Json(doc, place.file)
		member := Json_Get(json, place.node, key)
		if member < 0 || jvSame(json, member, v) do continue
		LDtkPatches_Add(p, place.file, Json_SetPatch(json, member, writeAt(json, member, v, Json_Minified(json))))
	}
}

@(private="file")
levelSet :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	level, why := findLevel(s, edit.level)
	if why != "" do return why
	doc := s.cur
	main := LDtkDoc_Main(doc)
	entry := doc.levels[level].entry
	p := LDtkPatches{}
	t := strings.trim_space(edit.text)
	switch edit.key {
	case "identifier":
		if Json_Bool(main, Json_Get(main, entry, "useAutoIdentifier")) do return "this level is named by the project's pattern: turn Automatic name off first"
		if _, ok := LDtk_CleanIdentifier(t, defStyle(doc)); !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text)
		old, _ := LDtkDoc_LevelNames(doc, level)
		// Project.fixUniqueIdStr: cleaned up, then made unique among every level
		id := ldtkUniqueId(t, defStyle(doc), levelIdentifiers(doc, except = level))
		if id == old do return ""
		levelWrite(&p, doc, level, "identifier", id)
	case "useAutoIdentifier":
		levelWrite(&p, doc, level, "useAutoIdentifier", edit.flag)
	case "worldDepth":
		v, ok := editNumber(edit)
		if !ok do return fmt.tprintf("%q isn't a whole number", edit.text)
		levelWrite(&p, doc, level, "worldDepth", i64(math.round(v)))
	case "bgColor":
		if t == "" {
			levelWrite(&p, doc, level, "bgColor", LDtkJNull{})
			break
		}
		c, ok := LDtk_ParseColor(t)
		if !ok do return fmt.tprintf("%q isn't a color (#RRGGBB)", edit.text)
		// The project's default is no color of its own (LevelInstanceForm)
		def := LDtkDoc_DefaultLevelBg(doc)
		levelWrite(&p, doc, level, "bgColor", c == def ? LDtkJV(LDtkJNull{}) : LDtkJV(LDtk_FormatColor(c)))
	case "bgRelPath":
		if t == "" {
			levelWrite(&p, doc, level, "bgRelPath", LDtkJNull{})
			levelWrite(&p, doc, level, "bgPos", LDtkJNull{})
			break
		}
		if _, ok := Image_Size(joinPath(LDtkDoc_Folder(doc), t, allocator = context.temp_allocator)); !ok do return fmt.tprintf("%s can't be read as an image", t)
		hadImage := Json_Kind(main, Json_Get(main, entry, "bgRelPath")) == .String
		levelWrite(&p, doc, level, "bgRelPath", strings.clone(t, context.temp_allocator))
		// A first image covers the level
		if !hadImage do levelWrite(&p, doc, level, "bgPos", "Cover")
	case "bgPos":
		if !slice.contains(LDTK_BG_POSITIONS, t) do return fmt.tprintf("%q isn't one of %v", edit.text, LDTK_BG_POSITIONS)
		if Json_Kind(main, Json_Get(main, entry, "bgRelPath")) != .String do return "the level has no background image"
		levelWrite(&p, doc, level, "bgPos", strings.clone(t, context.temp_allocator))
	case "bgPivot":
		levelWrite(&p, doc, level, "bgPivotX", jvNumber(ldtkWriteFloat(clamp(edit.number, 0, 1))))
		levelWrite(&p, doc, level, "bgPivotY", jvNumber(ldtkWriteFloat(clamp(edit.number2, 0, 1))))
	case:
		return fmt.tprintf("a level has no setting %q", edit.key)
	}
	return stagesApply(s, &p)
}

// World.moveLevelToDepthFurther / Closer (`number`: 1 further, -1 closer)
@(private="file")
levelDepth :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	level, why := findLevel(s, edit.level)
	if why != "" do return why
	doc := s.cur
	world := doc.levels[level].world
	levels := worldLevels(doc, world)
	depth := LDtkDoc_LevelDepth(doc, level)
	lo, hi := 0, 0
	others := false
	for l in levels {
		d := LDtkDoc_LevelDepth(doc, l)
		lo, hi = min(lo, d), max(hi, d)
		if l != level && d == depth do others = true
	}
	p := LDtkPatches{}
	if edit.number > 0 {
		if depth >= hi && !others do return "it's the furthest level already"
		levelWrite(&p, doc, level, "worldDepth", i64(depth + 1))
		if problem := stagesApply(s, &p); problem != "" do return problem
		// No level left at depth 0: every level comes one closer
		doc = s.cur
		any0 := false
		for l in worldLevels(doc, world) do if LDtkDoc_LevelDepth(doc, l) == 0 do any0 = true
		if any0 do return ""
		q := LDtkPatches{}
		for l in worldLevels(doc, world) do levelWrite(&q, doc, l, "worldDepth", i64(LDtkDoc_LevelDepth(doc, l) - 1))
		return stagesApply(s, &q)
	}
	if depth <= lo && !others do return "it's the closest level already"
	levelWrite(&p, doc, level, "worldDepth", i64(depth - 1))
	return stagesApply(s, &p)
}

/*
Whether a level can go a depth further or closer (World.canMoveLevelToDepthFurther / Closer).
*/
LDtkDoc_LevelDepthMoves :: proc(doc: ^LDtkDoc, level: int) -> (further, closer: bool) {
	world := doc.levels[level].world
	depth := LDtkDoc_LevelDepth(doc, level)
	lo, hi := 0, 0
	others := false
	for l in worldLevels(doc, world) {
		d := LDtkDoc_LevelDepth(doc, l)
		lo, hi = min(lo, d), max(hi, d)
		if l != level && d == depth do others = true
	}
	return depth < hi || others, depth > lo || others
}

// --- Resizing -----------------------------------------------------------------------------------

/*
A level resized as LDtk's Rulers and level form do (Level.applyNewBounds): `number`, `number2` the
new left and top edges (level pixels; negative grows the level up or left), `number3`, `number4`
its new size. Cells and entities keep their place in the world; what falls outside is cropped.
*/
@(private="file")
levelResized :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	level, why := findLevel(s, edit.level)
	if why != "" do return why
	doc := s.cur
	main := LDtkDoc_Main(doc)
	left, top := int(math.round(edit.number)), int(math.round(edit.number2))
	w, h := int(math.round(edit.number3)), int(math.round(edit.number4))
	minSize := LDtkDoc_DefaultGrid(doc)
	if w < minSize || h < minSize do return fmt.tprintf("a level is at least %d px (the project's grid) on each side", minSize)
	if w > 4096 * 4 || h > 4096 * 4 do return "a level is at most 16384 px on a side"
	rect := LDtkDoc_LevelRect(doc, level)
	if left == 0 && top == 0 && w == int(rect[2]) && h == int(rect[3]) do return ""
	m, ok := LDtkLevel_Read(doc, "", level)
	if !ok do return "the level's layers can't be read"
	defer LDtkLevel_Destroy(&m)
	p := LDtkPatches{}
	file, array := LDtkDoc_LayerInstances(doc, level)
	json := LDtkDoc_Json(doc, file)
	minified := Json_Minified(json)
	instances := Json_Items(json, array)
	entityAllowsOut := make(map[int]bool, context.temp_allocator)
	for ed in Json_Items(main, LDtkDoc_Defs(doc, "entities")) do entityAllowsOut[Json_Int(main, Json_Get(main, ed, "uid"))] = Json_Bool(main, Json_Get(main, ed, "allowOutOfBounds"))
	for li in instances {
		iid := Json_String(json, Json_Get(json, li, "iid"))
		l: ^LDtkLayerData
		for &x in m.layers do if x.iid == iid do l = &x
		ld := LDtkDoc_DefByUid(doc, "layers", Json_Int(json, Json_Get(json, li, "layerDefUid"), -1))
		grid := max(Json_Int(main, Json_Get(main, ld, "gridSize"), 16), 1)
		offX, offY := Json_Int(json, Json_Get(json, li, "pxOffsetX")), Json_Int(json, Json_Get(json, li, "pxOffsetY"))
		totalX, totalY := offX - left, offY - top
		// Haxe's % and Std.int truncate toward zero, as Odin's do
		newOffX, newOffY := totalX % grid, totalY % grid
		cdx, cdy := totalX / grid, totalY / grid
		newCWid := int(math.ceil(f64(w - newOffX) / f64(grid)))
		newCHei := int(math.ceil(f64(h - newOffY) / f64(grid)))
		LDtkPatches_Set(&p, doc, file, Json_Get(json, li, "pxOffsetX"), fmt.tprint(newOffX))
		LDtkPatches_Set(&p, doc, file, Json_Get(json, li, "pxOffsetY"), fmt.tprint(newOffY))
		type := Json_String(json, Json_Get(json, li, "__type"))
		if l != nil do switch type {
		case "IntGrid":
			cells := make([]i32, max(newCWid * newCHei, 0), context.temp_allocator)
			for cy in 0 ..< l.cHei do for cx in 0 ..< l.cWid {
				v := l.intGrid[cx + cy * l.cWid]
				nx, ny := cx + cdx, cy + cdy
				if v != 0 && nx >= 0 && nx < newCWid && ny >= 0 && ny < newCHei do cells[nx + ny * newCWid] = v
			}
			copyLayer := l^
			copyLayer.intGrid = cells
			copyLayer.cWid, copyLayer.cHei = newCWid, newCHei
			node := Json_Get(json, li, "intGridCsv")
			LDtkPatches_Set(&p, doc, file, node, LDtkLayer_IntGridText(&copyLayer, minified, LDtk_IndentAt(json.text, int(json.nodes[node].start))))
			// Its auto tiles are worked out again (LevelRender's LevelResized)
			if at := Json_Get(json, li, "autoLayerTiles"); Json_Count(json, at) > 0 do LDtkPatches_Set(&p, doc, file, at, "[]")
		case "Tiles":
			stacks := make([][dynamic]LDtkGridTile, max(newCWid * newCHei, 0), context.temp_allocator)
			for cy in 0 ..< l.cHei do for cx in 0 ..< l.cWid {
				stack := l.tiles[cx + cy * l.cWid]
				nx, ny := cx + cdx, cy + cdy
				if len(stack) > 0 && nx >= 0 && nx < newCWid && ny >= 0 && ny < newCHei do stacks[nx + ny * newCWid] = stack
			}
			copyLayer := l^
			copyLayer.tiles = stacks
			copyLayer.cWid, copyLayer.cHei = newCWid, newCHei
			node := Json_Get(json, li, "gridTiles")
			LDtkPatches_Set(&p, doc, file, node, LDtkLayer_GridTilesText(&m, &copyLayer, minified, LDtk_IndentAt(json.text, int(json.nodes[node].start))))
		case "AutoLayer":
			if at := Json_Get(json, li, "autoLayerTiles"); Json_Count(json, at) > 0 do LDtkPatches_Set(&p, doc, file, at, "[]")
		}
		if type != "Entities" do continue
		// Entities move with the cells; those outside the level go (unless their type allows it)
		entities := Json_Get(json, li, "entityInstances")
		kept := make([dynamic]string, context.temp_allocator)
		removed := false
		for e in Json_Items(json, entities) {
			px := Json_Get(json, e, "px")
			x := Json_Int(json, Json_At(json, px, 0)) + cdx * grid
			y := Json_Int(json, Json_At(json, px, 1)) + cdy * grid
			if !(entityAllowsOut[Json_Int(json, Json_Get(json, e, "defUid"))] or_else false) && !(x >= 0 && x < w && y >= 0 && y < h) {
				removed = true
				continue
			}
			v := jvWith(ldtkJV(json, e), "px", jarray(i64(x), i64(y)))
			// Points move with the cells (FieldInstance.parseValue of "cx,cy")
			fields, _ := jvGet(v, "fieldInstances").(LDtkJArray)
			newFields := make([]LDtkJV, len(fields), context.temp_allocator)
			for f, i in fields {
				newFields[i] = f
				t, _ := jvGet(f, "__type").(string)
				if t != "Point" && t != "Array<Point>" do continue
				raws, _ := jvGet(f, "realEditorValues").(LDtkJArray)
				moved := make([]LDtkJV, len(raws), context.temp_allocator)
				for r, k in raws {
					moved[k] = r
					params, _ := jvGet(r, "params").(LDtkJArray)
					if len(params) == 0 do continue
					text, isText := params[0].(string)
					if !isText do continue
					xs, _, ys := strings.partition(text, ",")
					cx, _ := strconv.parse_int(strings.trim_space(xs))
					cy, _ := strconv.parse_int(strings.trim_space(ys))
					moved[k] = jvWith(r, "params", jarray(fmt.tprintf("%d,%d", cx + cdx, cy + cdy)))
				}
				newFields[i] = jvWith(f, "realEditorValues", LDtkJArray(moved))
			}
			v = jvWith(v, "fieldInstances", LDtkJArray(newFields))
			append(&kept, ldtkItemText(doc, file, entities, v))
		}
		_ = removed
		if Json_Count(json, entities) > 0 do ldtkRebuildRows(&p, doc, file, entities, kept[:])
	}
	levelWrite(&p, doc, level, "pxWid", i64(w))
	levelWrite(&p, doc, level, "pxHei", i64(h))
	layout := LDtkDoc_WorldLayout(doc, doc.levels[level].world)
	if layout == "Free" || layout == "GridVania" {
		levelWrite(&p, doc, level, "worldX", i64(int(rect[0]) + left))
		levelWrite(&p, doc, level, "worldY", i64(int(rect[1]) + top))
	}
	if problem := stagesApply(s, &p); problem != "" do return problem
	// The level's derived values, then its auto-layers worked out again
	if problem := LDtkTidy_Run(s); problem != "" do return problem
	layers := make(map[int]bool, context.temp_allocator)
	for d in Json_Items(LDtkDoc_Main(s.cur), LDtkDoc_Defs(s.cur, "layers")) do layers[Json_Int(LDtkDoc_Main(s.cur), Json_Get(LDtkDoc_Main(s.cur), d, "uid"))] = true
	return rerunRules(s, layers, only = LDtkDoc_FindLevel(s.cur, edit.level))
}

// --- Worlds -------------------------------------------------------------------------------------

/*
Turns LDtk's Multi-worlds option on or off (Project.toJson's two forms): on, the root's world
becomes `worlds`' first (its iid the root's `dummyWorldIid`, its settings and levels moved, the
root's world settings null); off (one world only), the other way.
*/
@(private)
multiWorldsSet :: proc(s: ^Stages, on: bool) -> string {
	doc := s.cur
	main := LDtkDoc_Main(doc)
	root := Json_Root(main)
	if on == LDtkDoc_MultiWorlds(doc) do return ""
	v := ldtkJV(main, root)
	keys := []string{"defaultLevelWidth", "defaultLevelHeight", "worldGridWidth", "worldGridHeight", "worldLayout"}
	if on {
		world := jobject(
			jpair("iid", jvOr(v, "dummyWorldIid", LDtk_NewIid())),
			jpair("identifier", "World"),
			jpair("defaultLevelWidth", jvOr(v, "defaultLevelWidth", i64(LDTK_DEFAULT_LEVEL_SIZE))),
			jpair("defaultLevelHeight", jvOr(v, "defaultLevelHeight", i64(LDTK_DEFAULT_LEVEL_SIZE))),
			jpair("worldGridWidth", jvOr(v, "worldGridWidth", i64(LDTK_DEFAULT_LEVEL_SIZE))),
			jpair("worldGridHeight", jvOr(v, "worldGridHeight", i64(LDTK_DEFAULT_LEVEL_SIZE))),
			jpair("worldLayout", jvOr(v, "worldLayout", "Free")),
			jpair("levels", jvOr(v, "levels", LDtkJArray{})),
		)
		for k in keys do v = jvWith(v, k, LDtkJNull{})
		v = jvWith(v, "levels", LDtkJArray{})
		v = jvWith(v, "worlds", jarray(world))
	} else {
		worlds, _ := jvGet(v, "worlds").(LDtkJArray)
		if len(worlds) > 1 do return "the project has several worlds: remove all but one first"
		if len(worlds) == 1 {
			w := worlds[0]
			for k in keys do v = jvWith(v, k, jvOr(w, k, LDtkJNull{}))
			v = jvWith(v, "levels", jvOr(w, "levels", LDtkJArray{}))
		}
		v = jvWith(v, "worlds", LDtkJArray{})
	}
	v = jvWith(v, "flags", flagsWith(doc, "MultiWorlds", on))
	p := LDtkPatches{}
	LDtkPatches_Set(&p, doc, 0, root, LDtk_PrettyJson(v, Json_Minified(main), 0))
	return stagesApply(s, &p)
}

/*
The project's flags with one turned on or off, as LDtk writes them (in ProjectFlag's order; the
legacy DiscardPreCsvIntGrid dropped and ExportOldTableOfContentData added for files before 1.5,
as LDtk's Project.fromJson reads them).
*/
@(private)
flagsWith :: proc(doc: ^LDtkDoc, flag: string, on: bool) -> LDtkJV {
	main := LDtkDoc_Main(doc)
	have := make(map[string]bool, context.temp_allocator)
	for f in Json_Items(main, Json_Get(main, Json_Root(main), "flags")) do have[strings.clone(Json_String(main, f), context.temp_allocator)] = true
	delete_key(&have, "DiscardPreCsvIntGrid")
	version := Json_String(main, Json_Get(main, Json_Root(main), "jsonVersion"))
	if ldtkVersionBelow(version, 1, 5) do have["ExportOldTableOfContentData"] = true
	if on do have[flag] = true
	else do delete_key(&have, flag)
	out := make([dynamic]LDtkJV, context.temp_allocator)
	for f in LDTK_PROJECT_FLAGS do if f in have do append(&out, f)
	return LDtkJArray(out[:])
}

// Whether an LDtk version ("1.5.3") is below major.minor
@(private)
ldtkVersionBelow :: proc(version: string, major, minor: int) -> bool {
	parts := strings.split(version, ".", context.temp_allocator)
	a, _ := strconv.parse_int(len(parts) > 0 ? parts[0] : "0")
	b, _ := strconv.parse_int(len(parts) > 1 ? parts[1] : "0")
	return a < major || (a == major && b < minor)
}

// Project.createWorld(true): Multi-worlds on, a world named "World" (made unique) with a level
@(private="file")
worldAdded :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	if problem := multiWorldsSet(s, true); problem != "" do return problem
	doc := s.cur
	main := LDtkDoc_Main(doc)
	taken := make(map[string]bool, context.temp_allocator)
	for _, w in doc.worlds {
		name, _ := LDtkDoc_WorldNames(doc, w)
		taken[strings.clone(name, context.temp_allocator)] = true
	}
	identifier := ldtkUniqueId(edit.text != "" ? edit.text : "World", defStyle(doc), taken)
	uids := uidsMake(doc)
	uid := uidTake(&uids)
	levelName := ldtkUniqueId("Level1", defStyle(doc), levelIdentifiers(doc))
	worldIid := LDtk_NewIid()
	levelIid := edit.entity != "" ? edit.entity : LDtk_NewIid()
	world := jobject(
		jpair("iid", worldIid),
		jpair("identifier", identifier),
		jpair("defaultLevelWidth", i64(LDTK_DEFAULT_LEVEL_SIZE)),
		jpair("defaultLevelHeight", i64(LDTK_DEFAULT_LEVEL_SIZE)),
		jpair("worldGridWidth", i64(LDTK_DEFAULT_LEVEL_SIZE)),
		jpair("worldGridHeight", i64(LDTK_DEFAULT_LEVEL_SIZE)),
		jpair("worldLayout", "Free"),
		jpair("levels", LDtkJArray{}),
	)
	worlds := Json_Get(main, Json_Root(main), "worlds")
	texts := make([dynamic]string, context.temp_allocator)
	for w in Json_Items(main, worlds) do append(&texts, strings.clone(Json_Text(main, w), context.temp_allocator))
	append(&texts, ldtkItemText(doc, 0, worlds, world))
	p := LDtkPatches{}
	ldtkRebuildRows(&p, doc, 0, worlds, texts[:])
	uidsDone(&p, doc, uids)
	if problem := stagesApply(s, &p); problem != "" do return problem
	// Its first level (World.createLevel)
	doc = s.cur
	w := len(doc.worlds) - 1
	whole := newLevelJV(doc, w, levelName, levelIid, uid, 0, 0, LDTK_DEFAULT_LEVEL_SIZE, LDTK_DEFAULT_LEVEL_SIZE, 0)
	q := LDtkPatches{}
	worldLevelsWrite(s, &q, w, []string{levelEntryText(s, w, whole, len(doc.levels))})
	return stagesApply(s, &q)
}

// Project.removeWorld: never the last; its levels go, and references to their entities
@(private="file")
worldRemoved :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	doc := s.cur
	if edit.world < 0 || edit.world >= len(doc.worlds) do return "no such world"
	if len(doc.worlds) <= 1 do return "You can't delete the last world."
	iids := make(map[string]bool, context.temp_allocator)
	for l in worldLevels(doc, edit.world) do for iid in levelEntityIids(doc, l) do iids[iid] = true
	main := LDtkDoc_Main(doc)
	worlds := Json_Get(main, Json_Root(main), "worlds")
	texts := make([dynamic]string, context.temp_allocator)
	for w in Json_Items(main, worlds) do if w != doc.worlds[edit.world].object do append(&texts, strings.clone(Json_Text(main, w), context.temp_allocator))
	p := LDtkPatches{}
	ldtkRebuildRows(&p, doc, 0, worlds, texts[:])
	if problem := stagesApply(s, &p); problem != "" do return problem
	refs := LDtkPatches{}
	removeRefsToAny(&refs, s.cur, iids, Json_Minified(LDtkDoc_Main(s.cur)))
	return stagesApply(s, &refs)
}

// A world's name (Multi-worlds only: WorldPanel's input is off otherwise) or new levels' size
@(private="file")
worldSet :: proc(s: ^Stages, edit: LDtk_Edit) -> string {
	doc := s.cur
	if edit.world < 0 || edit.world >= len(doc.worlds) do return "no such world"
	main := LDtkDoc_Main(doc)
	object := doc.worlds[edit.world].object
	p := LDtkPatches{}
	switch edit.key {
	case "identifier":
		if !LDtkDoc_MultiWorlds(doc) do return "a project with one world names it World (turn Multi-worlds on in the Project tab to name worlds)"
		t := strings.trim_space(edit.text)
		if _, ok := LDtk_CleanIdentifier(t, defStyle(doc)); !ok do return fmt.tprintf("%q isn't an identifier (letters, digits and _, not starting with a digit)", edit.text)
		taken := make(map[string]bool, context.temp_allocator)
		for _, w in doc.worlds {
			if w == edit.world do continue
			name, _ := LDtkDoc_WorldNames(doc, w)
			taken[strings.clone(name, context.temp_allocator)] = true
		}
		defWrite(&p, doc, object, "identifier", ldtkUniqueId(t, defStyle(doc), taken))
	case "defaultLevelWidth", "defaultLevelHeight":
		v, ok := editNumber(edit)
		if !ok do return fmt.tprintf("%q isn't a whole number", edit.text)
		n := clamp(int(math.round(v)), LDtkDoc_DefaultGrid(doc), 9999)
		// World.snapWorldGridX / Y (forced above zero) in GridVania worlds
		if LDtkDoc_WorldLayout(doc, edit.world) == "GridVania" {
			grid := LDtkDoc_WorldGrid(doc, edit.world)
			g := edit.key == "defaultLevelWidth" ? grid.x : grid.y
			n = max(int(ldtkRound(f64(n) / f64(g))), 1) * g
		}
		defWrite(&p, doc, object, edit.key, i64(n))
	case:
		return fmt.tprintf("a world has no setting %q", edit.key)
	}
	_ = main
	return stagesApply(s, &p)
}

// --- The levels' part of LDtk's tidy ------------------------------------------------------------

/*
The levels' part of LDtk's tidy (World.tidy, Level.toJson), run before the instances' passes
(ldtk_tidy.odin's `LDtkTidy_Run`):
- a GridVania world's size for new levels on its grid (World.tidy);
- the automatic names (World.applyAutoLevelIdentifiers: the project's `levelNamePattern` with
  %world, %idx1, %idx, %gx, %gy, %x, %y, %depth / %d; made unique among every level);
- each level's `__bgColor` (its own, else the project's default) and `__bgPos` (where its
  background image is drawn: Level.getBgTileInfos; left as written when the image can't be read).
*/
@(private)
tidyLevels :: proc(p: ^LDtkPatches, doc: ^LDtkDoc) {
	main := LDtkDoc_Main(doc)
	root := Json_Root(main)
	style := Json_String(main, Json_Get(main, root, "identifierStyle"))
	// World.tidy: GridVania's default level size on its grid
	for _, w in doc.worlds {
		if LDtkDoc_WorldLayout(doc, w) != "GridVania" do continue
		o := doc.worlds[w].object
		grid := LDtkDoc_WorldGrid(doc, w)
		for key, i in ([]string{"defaultLevelWidth", "defaultLevelHeight"}) {
			node := Json_Get(main, o, key)
			if Json_Kind(main, node) != .Number do continue
			g := i == 0 ? grid.x : grid.y
			want := max(int(ldtkRound(f64(Json_Int(main, node)) / f64(g))), 1) * g
			if Json_Int(main, node) != want do LDtkPatches_Set(p, doc, 0, node, fmt.tprint(want))
		}
	}
	// The automatic names
	pattern := LDTK_DEFAULT_LEVEL_NAME_PATTERN
	if node := Json_Get(main, root, "levelNamePattern"); Json_Kind(main, node) == .String do pattern = Json_String(main, node)
	names := make([]string, len(doc.levels), context.temp_allocator)
	auto := make([]bool, len(doc.levels), context.temp_allocator)
	for _, i in doc.levels {
		id, _ := LDtkDoc_LevelNames(doc, i)
		names[i] = strings.clone(id, context.temp_allocator)
		auto[i] = Json_Bool(main, Json_Get(main, doc.levels[i].entry, "useAutoIdentifier"))
	}
	for _, w in doc.worlds {
		levels := worldLevels(doc, w)
		uniq := 0
		for l in levels do if auto[l] {
			names[l] = fmt.tprintf("#%d", uniq)
			uniq += 1
		}
		layout := LDtkDoc_WorldLayout(doc, w)
		grid := LDtkDoc_WorldGrid(doc, w)
		worldName, _ := LDtkDoc_WorldNames(doc, w)
		left, top := max(int), max(int)
		for l in levels {
			r := LDtkDoc_LevelRect(doc, l)
			left, top = min(left, int(r[0])), min(top, int(r[1]))
		}
		for l, idx in levels {
			if !auto[l] do continue
			r := LDtkDoc_LevelRect(doc, l)
			depth := LDtkDoc_LevelDepth(doc, l)
			placed := layout == "Free" || layout == "GridVania"
			id := pattern
			id, _ = strings.replace_all(id, "%depth", fmt.tprint(depth), context.temp_allocator)
			id, _ = strings.replace_all(id, "%world", worldName, context.temp_allocator)
			id, _ = strings.replace_all(id, "%idx1", fmt.tprint(idx + 1), context.temp_allocator)
			id, _ = strings.replace_all(id, "%idx", fmt.tprint(idx), context.temp_allocator)
			id, _ = strings.replace_all(id, "%gx", layout == "GridVania" ? fmt.tprint((int(r[0]) - left) / grid.x) : "", context.temp_allocator)
			id, _ = strings.replace_all(id, "%gy", layout == "GridVania" ? fmt.tprint((int(r[1]) - top) / grid.y) : "", context.temp_allocator)
			id, _ = strings.replace_all(id, "%x", placed ? fmt.tprint(int(r[0])) : "", context.temp_allocator)
			id, _ = strings.replace_all(id, "%y", placed ? fmt.tprint(int(r[1])) : "", context.temp_allocator)
			id, _ = strings.replace_all(id, "%d", fmt.tprint(depth), context.temp_allocator)
			taken := make(map[string]bool, len(names), context.temp_allocator)
			for n in names do taken[n] = true
			names[l] = ldtkUniqueId(id, style, taken)
		}
	}
	for _, i in doc.levels {
		old, _ := LDtkDoc_LevelNames(doc, i)
		if names[i] != old do levelWrite(p, doc, i, "identifier", names[i])
	}
	// Backgrounds
	defaultBg := LDtkDoc_DefaultLevelBg(doc)
	folder := LDtkDoc_Folder(doc)
	for _, i in doc.levels {
		entry := doc.levels[i].entry
		bg := defaultBg
		if c, ok := LDtk_ParseColor(Json_String(main, Json_Get(main, entry, "bgColor"))); ok do bg = c
		levelWrite(p, doc, i, "__bgColor", LDtk_FormatColor(bg))
		if pos, ok := levelBgPos(doc, folder, i); ok do levelWrite(p, doc, i, "__bgPos", pos)
	}
}

/*
Where a level's background image is drawn (Level.getBgTileInfos, `__bgPos`): its scale by its
position mode, the part of the image shown (`cropRect`) and where (`topLeftPx`) by its pivot.

Returns:
- The value (null without an image), false when the image can't be read (left as written)
*/
@(private)
levelBgPos :: proc(doc: ^LDtkDoc, folder: string, level: int) -> (LDtkJV, bool) {
	main := LDtkDoc_Main(doc)
	entry := doc.levels[level].entry
	rel := Json_Get(main, entry, "bgRelPath")
	if Json_Kind(main, rel) != .String do return LDtkJNull{}, true
	mode := Json_String(main, Json_Get(main, entry, "bgPos"))
	if mode == "" do return LDtkJNull{}, true
	size, ok := Image_Size(joinPath(folder, Json_String(main, rel), allocator = context.temp_allocator))
	if !ok do return nil, false
	info := LDtk_BgTileInfos(size, {Json_Int(main, Json_Get(main, entry, "pxWid")), Json_Int(main, Json_Get(main, entry, "pxHei"))}, mode,
		{Json_Float(main, Json_Get(main, entry, "bgPivotX"), 0.5), Json_Float(main, Json_Get(main, entry, "bgPivotY"), 0.5)})
	return jobject(
		jpair("topLeftPx", jarray(i64(info.disp.x), i64(info.disp.y))),
		jpair("scale", jarray(jvNumber(info.scale.x), jvNumber(info.scale.y))),
		jpair("cropRect", jarray(jvNumber(info.crop[0]), jvNumber(info.crop[1]), jvNumber(info.crop[2]), jvNumber(info.crop[3]))),
	), true
}

// Where a level's background image is drawn (Level.getBgTileInfos)
LDtkBgInfos :: struct {
	// The part of the image (x, y, w, h), its scale, where its top left is in the level
	crop: [4]f64,
	scale: [2]f64,
	disp: [2]int,
	repeat: bool,
}

/*
Level.getBgTileInfos: a background image's scale for its position mode (Unscaled, Contain,
Cover, CoverDirty, Repeat), the part of it shown and where, by the pivot.

Inputs:
- image: The image's size
- level: The level's size
- mode: The position mode (`bgPos`)
- pivot: `bgPivotX`, `bgPivotY`
*/
LDtk_BgTileInfos :: proc(image, level: [2]int, mode: string, pivot: [2]f64) -> LDtkBgInfos {
	bw, bh := f64(image.x), f64(image.y)
	lw, lh := f64(level.x), f64(level.y)
	sx, sy := 1.0, 1.0
	switch mode {
	case "Contain": sx = min(lw / bw, lh / bh); sy = sx
	case "Cover": sx = max(lw / bw, lh / bh); sy = sx
	case "CoverDirty": sx, sy = lw / bw, lh / bh
	}
	subW := min(bw, lw / sx)
	subH := min(bh, lh / sy)
	return {
		crop = {pivot.x * (bw - subW), pivot.y * (bh - subH), subW, subH},
		scale = {sx, sy},
		disp = {int(pivot.x * (lw - subW * sx)), int(pivot.y * (lh - subH * sy))},
		repeat = mode == "Repeat",
	}
}

/*
The level files' part of the tidy (ProjectSaver.prepareProjectSavingData): with levels saved
apart, each level's file named as LDtk names it on save (`LDtk_LevelFileName`: by its name, and
its index across every world under PrependIndexToLevelFileNames); a level named again keeps its
file's text under the new name.
*/
@(private)
tidyLevelFiles :: proc(s: ^Stages) -> string {
	doc := s.cur
	if !LDtkDoc_ExternalLevels(doc) do return ""
	main := LDtkDoc_Main(doc)
	prepend := LDtkDoc_HasFlag(doc, "PrependIndexToLevelFileNames")
	folder := LDtkDoc_Folder(doc)
	p := LDtkPatches{}
	index := 0
	for _, w in doc.worlds do for l in worldLevels(doc, w) {
		defer index += 1
		entry := doc.levels[l].entry
		rel := Json_Get(main, entry, "externalRelPath")
		if Json_Kind(main, rel) != .String || doc.levels[l].file == 0 do continue
		id, _ := LDtkDoc_LevelNames(doc, l)
		want := LDtk_LevelFileName(doc.files[0].path, id, index, prepend)
		if Json_String(main, rel) == want do continue
		LDtkPatches_Set(&p, doc, 0, rel, Json_Quote(want))
		s.added[joinPath(folder, want, allocator = context.temp_allocator)] = strings.clone(LDtkDoc_Json(doc, doc.levels[l].file).text, context.temp_allocator)
	}
	return stagesApply(s, &p)
}

/*
Saves the levels in their own files or back in the project file (LDtk's "Save levels to separate
files", ProjectSaver.prepareProjectSavingData): on, each level's layers go to its `.ldtkl` file
(LDtk's header, the level's JSON), its entry keeps the rest and names the file; off, its layers come
back into its entry (the files are removed on Save).
*/
@(private)
externalLevelsSet :: proc(s: ^Stages, on: bool) -> string {
	doc := s.cur
	main := LDtkDoc_Main(doc)
	root := Json_Root(main)
	p := LDtkPatches{}
	defWrite(&p, doc, root, "externalLevels", on)
	prepend := LDtkDoc_HasFlag(doc, "PrependIndexToLevelFileNames")
	folder := LDtkDoc_Folder(doc)
	index := 0
	for _, w in doc.worlds do for l in worldLevels(doc, w) {
		defer index += 1
		level := doc.levels[l]
		entry := level.entry
		if on && level.file == 0 {
			id, _ := LDtkDoc_LevelNames(doc, l)
			rel := LDtk_LevelFileName(doc.files[0].path, id, index, prepend)
			s.added[joinPath(folder, rel, allocator = context.temp_allocator)] = levelFileText(doc, levelWholeJV(doc, l))
			LDtkPatches_Set(&p, doc, 0, Json_Get(main, entry, "externalRelPath"), Json_Quote(rel))
			if li := Json_Get(main, entry, "layerInstances"); li >= 0 do LDtkPatches_Set(&p, doc, 0, li, "null")
		} else if !on && level.file != 0 {
			json := LDtkDoc_Json(doc, level.file)
			layers := ldtkJV(json, Json_Get(json, level.node, "layerInstances"))
			LDtkPatches_Set(&p, doc, 0, Json_Get(main, entry, "externalRelPath"), "null")
			if li := Json_Get(main, entry, "layerInstances"); li >= 0 do LDtkPatches_Set(&p, doc, 0, li, writeAt(main, li, layers, Json_Minified(main)))
		}
	}
	return stagesApply(s, &p)
}
