package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "core:time"
import "gui:skald"

/*
The Level mode's world canvas (level_mode.odin): an LDtk project's levels where its world puts
them, each drawn with its layers as LDtk draws them (level_layers_render.odin: the focused level a
picture per layer, in pieces, so painting redraws only what changed; the others one picture,
drawn again only when what they show changes, not when they move), with its entities (their
shapes, colors and tiles: `LevelEntity_Draw`) and the links between them (entity reference
fields, as arrows) and to neighbouring levels; over the focused level the painting overlay
(level_canvas_paint.odin: grid lines, the brush, handles, points).

- **The view** (`LevelView`): the world point at the center and a zoom, fitted to the world when a
  file first shows (`LevelCanvas_FitOnce`) and by Fit. Screen = size / 2 + (world - center) *
  zoom.
- **Input** (from the canvas's last rect, as the viewport's): the wheel zooms around the pointer
  or pans (`wheelAction`, Settings > Editor > Wheel pans); a press sends `Level_Canvas_Pressed`
  with what's under the pointer (an entity first, then a level); while a drag is on, every move
  sends `Level_Canvas_Moved` and the release `Level_Canvas_Released`, wherever the pointer is.
  Middle drag and Space + drag pan; on the focused level the left and right buttons go to the
  painting tools first (level_paint.odin), elsewhere a right drag pans.
- **A drag shows where it'll land** (`LevelDrag_Target`: a GridVania world's grid, an entity's
  layer grid) before the release writes it.

The pictures' content keys (`levelContentKeys`) are a hash of each level's layers and the
project's definitions, worked out once per document version.
*/

// The content keys of a document's levels, worked out once per document version
@(private="file", thread_local)
levelKeys: struct {
	file: string,
	version: int,
	keys: map[string]u64,
}

// Pictures drawn bigger than this (on their longer side) are scaled down
LEVEL_IMAGE_MAX :: 2048

// Frees the canvas's caches (tests, quitting); the images go with Skald's renderer
LevelCanvas_Destroy :: proc() {
	LevelPictures_Destroy()
	LevelPaint_DestroyModel()
	LevelPalette_Destroy()
	LDtkDefs_Destroy()
	LDtkRules_Destroy()
	for iid in levelKeys.keys do delete(iid)
	delete(levelKeys.keys)
	delete(levelKeys.file)
	levelKeys = {}
}

// The shown world (or the focused level) fitted to the canvas (once its size is known)
LevelCanvas_Fit :: proc(state: ^State) {
	view := &state.level.view
	file := LevelMode_File(state)
	doc := LDtkDoc_Get(state.project.rootPath, file)
	if doc == nil || doc.problem != "" || view.size.x <= 0 || view.size.y <= 0 do return
	center, zoom := levelFit(state, doc, view.size)
	view.center, view.zoom = center, zoom
	delete(view.fitted)
	view.fitted = strings.clone(levelFitKey(state))
}

// Fits the view when the canvas shows a file, world or focused level it hasn't fitted yet
LevelCanvas_FitOnce :: proc(state: ^State) {
	if state.level.view.fitted != levelFitKey(state) || state.level.view.zoom <= 0 do LevelCanvas_Fit(state)
}

// What the view was fitted to: the file, the world, the focused level (temp)
@(private="file")
levelFitKey :: proc(state: ^State) -> string {
	return fmt.tprintf("%s|%s|%s", LevelMode_File(state), state.level.world, state.level.focus)
}

/*
The view showing the shown world's levels in a canvas of `size`; while a level is focused, that
level (with a margin: the neighbours' edges show around it).
*/
@(private="file")
levelFit :: proc(state: ^State, doc: ^LDtkDoc, size: [2]f32) -> (center: [2]f32, zoom: f32) {
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	levels := LevelMode_WorldLevels(state, doc)
	focus := state.level.focus != "" ? LDtkDoc_FindLevel(doc, state.level.focus) : -1
	any := false
	for i in levels {
		if focus >= 0 && i != focus do continue
		r := LDtkDoc_LevelRect(doc, i)
		lo = {min(lo.x, f32(r[0])), min(lo.y, f32(r[1]))}
		hi = {max(hi.x, f32(r[0] + r[2])), max(hi.y, f32(r[1] + r[3]))}
		any = true
	}
	if !any do return {0, 0}, 1
	extent := [2]f32{max(hi.x - lo.x, 1), max(hi.y - lo.y, 1)}
	zoom = clamp(min(size.x / extent.x, size.y / extent.y) * (focus >= 0 ? 0.85 : 0.9), LEVEL_MIN_ZOOM, LEVEL_MAX_ZOOM)
	return (lo + hi) * 0.5, zoom
}

// A level as the canvas draws it
LevelCanvasLevel :: struct {
	identifier, iid: string,
	// Its world rectangle (where a drag puts it: moved)
	world: [4]f32,
	image: string,
	imageSize: [2]f32,
	background: skald.Color,
	// Not the focused level (while one is), or of another world depth: drawn dimmed (and another
	// depth's isn't picked)
	dim, otherDepth: bool,
	// A copy being dragged (Ctrl + Alt): drawn where it'll go, not hit
	ghost: bool,
	// Its fields' values (level_fields_render.odin: over it in the world view, above it focused)
	fields: LevelFields,
}

// How an entity is drawn (its definition's `renderMode`)
LevelEntityShape :: enum u8 {
	Rectangle,
	Ellipse,
	Cross,
	Tile,
}

// An entity as the canvas draws it
LevelCanvasEntity :: struct {
	iid, identifier: string,
	// Its level's identifier, its layer definition's uid
	level: string,
	layer: int,
	// Its world rectangle and center
	world: [4]f32,
	center: [2]f32,
	color: skald.Color,
	// LDtk's look (EntityRender): its shape, fill and line opacity, hollow, its tile (the
	// tileset image's full path and the rectangle in it), the tile's opacity and render mode,
	// its name shown
	shape: LevelEntityShape,
	fillAlpha, lineAlpha, tileAlpha: f32,
	hollow, showName: bool,
	tileImage: string,
	tileSrc: [4]f32,
	tileMode: string,
	// Its definition's pivot and 9-slice borders (top, right, bottom, left: tile pixels)
	pivot: [2]f32,
	slices: [4]f32,
	// A copy being dragged (Ctrl + Alt): drawn where it'll go, not hit
	ghost: bool,
	// Its fields' values and shapes as LDtk draws them (level_fields_render.odin); its name hidden
	// with them (a layer hiding its fields while inactive)
	fields: LevelFields,
	nameHidden: bool,
}

// A link between level centers (a neighbour; `level`: the level it's of, by identifier). Entity
// references are drawn by their fields (level_fields_render.odin); `entity` marks such a link.
LevelCanvasLink :: struct {
	from, to: [2]f32,
	entity: bool,
	level: string,
}

/*
What the canvas shows of a document (temp allocated): the shown world's levels (moved ones where
the drag puts them; while a level is focused, the others dimmed), their entities and the links.
The UI test driver reads it (`drag_level`, `click_entity`).
*/
LevelCanvas_Content :: proc(state: ^State, doc: ^LDtkDoc) -> (levels: []LevelCanvasLevel, entities: []LevelCanvasEntity, links: []LevelCanvasLink) {
	main := LDtkDoc_Main(doc)
	world := LevelMode_World(state, doc)
	ls := make([dynamic]LevelCanvasLevel, context.temp_allocator)
	drag := state.level.drag
	moved := drag.moved ? LevelDrag_Target(state, doc) : {}
	depth := LevelMode_Depth(state, doc)
	ghosts := make([dynamic]LevelCanvasLevel, context.temp_allocator)
	for _, i in doc.levels {
		identifier, iid := LDtkDoc_LevelNames(doc, i)
		r := LDtkDoc_LevelRect(doc, i)
		at := [4]f32{f32(r[0]), f32(r[1]), f32(r[2]), f32(r[3])}
		dragged := drag.moved && drag.mode == .Level && drag.target == iid
		if dragged && !drag.copy do at.xy = {f32(moved.x), f32(moved.y)}
		bg := skald.rgb(0x202838)
		if c, ok := LDtk_ParseColor(Json_String(main, Json_Get(main, doc.levels[i].entry, "__bgColor"))); ok do bg = skald.rgb(u32(c))
		otherDepth := state.level.focus == "" && LDtkDoc_LevelDepth(doc, i) != depth
		l := LevelCanvasLevel{identifier = identifier, iid = iid, world = at, image = levelImageName(LevelMode_File(state), iid), background = bg,
			dim = (state.level.focus != "" && identifier != state.level.focus) || otherDepth, otherDepth = otherDepth}
		append(&ls, l)
		// A copy dragged with Ctrl + Alt: where it'll go
		if dragged && drag.copy && doc.levels[i].world == world {
			ghost := l
			ghost.ghost = true
			ghost.world.xy = {f32(moved.x), f32(moved.y)}
			append(&ghosts, ghost)
		}
	}
	es := make([dynamic]LevelCanvasEntity, context.temp_allocator)
	// Entities shown per document entity (a removed one in a stroke, a hidden layer's: none)
	shownIndex := make([dynamic]int, context.temp_allocator)
	stroke := &state.level.paint.stroke
	folder := LDtkDoc_Folder(doc)
	// For the fields: where each entity is (references' targets), and each one's places
	targets := make(map[string]LevelFieldTarget, context.temp_allocator)
	places := make([dynamic]LevelFieldEntity, context.temp_allocator)
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		def := LDtkDoc_DefByUid(doc, "entities", Json_Int(json, Json_Get(json, e.node, "defUid"), -1))
		px := Json_Get(json, e.node, "px")
		p := [2]f32{f32(Json_Int(json, Json_At(json, px, 0))), f32(Json_Int(json, Json_At(json, px, 1)))}
		iid := Json_String(json, Json_Get(json, e.node, "iid"))
		w := f32(Json_Int(json, Json_Get(json, e.node, "width"), 16))
		h := f32(Json_Int(json, Json_Get(json, e.node, "height"), 16))
		// A stroke's removals and resize show before they're made
		removed := false
		if stroke.kind == .Erase_Entities do for r in stroke.removed do if r == iid do removed = true
		if stroke.kind == .Resize && stroke.entity == iid {
			p = {f32(stroke.at.x), f32(stroke.at.y)}
			w, h = f32(stroke.size.x), f32(stroke.size.y)
		}
		layerOffset := [2]f32{f32(Json_Int(json, Json_Get(json, e.layer, "__pxTotalOffsetX"))), f32(Json_Int(json, Json_Get(json, e.layer, "__pxTotalOffsetY")))}
		hidden := !Json_Bool(json, Json_Get(json, e.layer, "visible"), true)
		pivot := [2]f32{f32(Json_Float(main, Json_Get(main, def, "pivotX"), 0.5)), f32(Json_Float(main, Json_Get(main, def, "pivotY"), 0.5))}
		origin := ls[e.level].world.xy + layerOffset
		color := skald.rgb(0xFFCC00)
		if c, ok := LDtk_ParseColor(Json_String(json, Json_Get(json, e.node, "__smartColor"))); ok do color = skald.rgb(u32(c))
		look := LevelCanvasEntity{
			iid = iid, identifier = Json_String(json, Json_Get(json, e.node, "__identifier")), level = ls[e.level].identifier,
			layer = Json_Int(json, Json_Get(json, e.layer, "layerDefUid"), -1), color = color,
			fillAlpha = f32(Json_Float(main, Json_Get(main, def, "fillOpacity"), 1)), lineAlpha = f32(Json_Float(main, Json_Get(main, def, "lineOpacity"), 1)),
			tileAlpha = f32(Json_Float(main, Json_Get(main, def, "tileOpacity"), 1)),
			hollow = Json_Bool(main, Json_Get(main, def, "hollow")), showName = Json_Bool(main, Json_Get(main, def, "showName"), true),
			tileMode = Json_String(main, Json_Get(main, def, "tileRenderMode")),
			pivot = pivot,
		}
		for v, k in Json_Items(main, Json_Get(main, def, "nineSliceBorders")) do if k < 4 do look.slices[k] = f32(Json_Int(main, v))
		switch Json_String(main, Json_Get(main, def, "renderMode")) {
		case "Ellipse": look.shape = .Ellipse
		case "Cross":   look.shape = .Cross
		case "Tile":    look.shape = .Tile
		}
		// Its tile (the instance's `__tile`: a field's or the type's)
		tile := Json_Get(json, e.node, "__tile")
		if Json_Kind(json, tile) == .Object {
			td := LDtkDoc_DefByUid(doc, "tilesets", Json_Int(json, Json_Get(json, tile, "tilesetUid"), -1))
			if rel := Json_String(main, Json_Get(main, td, "relPath")); rel != "" {
				look.tileImage = joinPath(folder, rel, allocator = context.temp_allocator)
				look.tileSrc = {f32(Json_Int(json, Json_Get(json, tile, "x"))), f32(Json_Int(json, Json_Get(json, tile, "y"))), f32(Json_Int(json, Json_Get(json, tile, "w"))), f32(Json_Int(json, Json_Get(json, tile, "h")))}
			}
		}
		if look.shape == .Tile && look.tileImage == "" do look.shape = .Rectangle
		place := proc(look: ^LevelCanvasEntity, origin, p, pivot: [2]f32, w, h: f32) {
			x0 := origin + p - pivot * [2]f32{w, h}
			look.world = {x0.x, x0.y, w, h}
			look.center = x0 + {w, h} * 0.5
		}
		at := p
		if drag.moved && drag.mode == .Entity && drag.target == iid && !drag.copy do at = {f32(moved.x), f32(moved.y)}
		place(&look, origin, at, pivot, w, h)
		if removed || hidden {
			append(&shownIndex, -1)
		} else {
			append(&shownIndex, len(es))
			append(&es, look)
		}
		{
			grid := Json_Int(json, Json_Get(json, e.layer, "__gridSize"), 16)
			cell := Json_Get(json, e.node, "__grid")
			pivotAt := origin + at
			pointOrigin := origin + {(f32(Json_Int(json, Json_At(json, cell, 0))) + 0.5) * f32(grid), (f32(Json_Int(json, Json_At(json, cell, 1))) + 0.5) * f32(grid)}
			if Json_Bool(main, Json_Get(main, def, "resizableX")) do pointOrigin.x = look.center.x
			if Json_Bool(main, Json_Get(main, def, "resizableY")) do pointOrigin.y = look.center.y
			targets[iid] = {center = look.center, pivot = pivotAt, identifier = look.identifier, level = look.level, world = doc.levels[e.level].world, depth = LDtkDoc_LevelDepth(doc, e.level)}
			append(&places, LevelFieldEntity{pivot = pivotAt, center = look.center, pointOrigin = pointOrigin, layerOrigin = origin, grid = grid,
				world = doc.levels[e.level].world, depth = LDtkDoc_LevelDepth(doc, e.level)})
		}
		// A copy dragged with Ctrl + Alt: where it'll go
		if drag.moved && drag.mode == .Entity && drag.target == iid && drag.copy {
			ghost := look
			ghost.ghost = true
			place(&ghost, origin, {f32(moved.x), f32(moved.y)}, pivot, w, h)
			append(&es, ghost)
		}
	}
	lk := make([dynamic]LevelCanvasLink, context.temp_allocator)
	// Fields (their values, radii, points and reference links: level_fields_render.odin): in the
	// world view only those shown in the world; a layer hiding its fields while another is selected
	worldMode := state.level.focus == ""
	selectedLayer := -1
	if layerDef := LevelMode_LayerDef(state, doc); layerDef >= 0 do selectedLayer = Json_Int(main, Json_Get(main, layerDef, "uid"), -1)
	for e, i in LDtkDoc_Entities(doc) {
		if shownIndex[i] < 0 do continue
		json := LDtkDoc_Json(doc, e.file)
		look := &es[shownIndex[i]]
		def := LDtkDoc_DefByUid(doc, "entities", Json_Int(json, Json_Get(json, e.node, "defUid"), -1))
		ld := LDtkDoc_DefByUid(doc, "layers", look.layer)
		alpha := f32(1)
		if !worldMode && look.layer != selectedLayer {
			if Json_Bool(main, Json_Get(main, ld, "hideFieldsWhenInactive")) {
				look.nameHidden = true
				continue
			}
			alpha = f32(Json_Float(main, Json_Get(main, ld, "inactiveOpacity"), 1))
		}
		look.fields = LevelFields_Make(doc, json, Json_Items(main, Json_Get(main, def, "fieldDefs")), Json_Get(json, e.node, "fieldInstances"), look.color, worldMode, &places[i], targets, look.level)
		look.fields.alpha = alpha
	}
	for &l, i in ls {
		smart := skald.rgb(0x40465B)
		if c, ok := LDtk_ParseColor(Json_String(main, Json_Get(main, doc.levels[i].entry, "__smartColor"))); ok do smart = skald.rgb(u32(c))
		l.fields = LevelFields_Make(doc, main, Json_Items(main, LDtkDoc_Defs(doc, "levelFields")), Json_Get(main, doc.levels[i].entry, "fieldInstances"), smart, worldMode, nil, targets, l.identifier)
		// A level's fields go over it whatever their position (WorldRender.updateFieldsPos)
		for &row in l.fields.rows do row.pos = .Above
	}
	// Neighbours: from each level's center to its neighbours'
	for _, i in doc.levels {
		if doc.levels[i].world != world do continue
		for n in LDtkDoc_Neighbours(doc, i) {
			for other in ls do if other.iid == n.iid {
				a, b := ls[i].world, other.world
				append(&lk, LevelCanvasLink{from = a.xy + a.zw * 0.5, to = b.xy + b.zw * 0.5, level = ls[i].identifier})
			}
		}
	}
	// Only the shown world (the lists above are by the document's levels: filtered last)
	shownLevels := make([dynamic]LevelCanvasLevel, context.temp_allocator)
	for l, i in ls do if doc.levels[i].world == world do append(&shownLevels, l)
	append(&shownLevels, ..ghosts[:])
	shownEntities := make([dynamic]LevelCanvasEntity, context.temp_allocator)
	for en in es do for l, i in ls do if l.identifier == en.level && doc.levels[i].world == world do append(&shownEntities, en)
	if len(doc.worlds) <= 1 {
		append(&ls, ..ghosts[:])
		return ls[:], es[:], lk[:]
	}
	shownLinks := make([dynamic]LevelCanvasLink, context.temp_allocator)
	for link in lk {
		if !link.entity {
			append(&shownLinks, link)
			continue
		}
		// References within the world (one to another world has no place here)
		inWorld :: proc(p: [2]f32, entities: []LevelCanvasEntity) -> bool {
			for en in entities do if en.center == p do return true
			return false
		}
		if inWorld(link.from, shownEntities[:]) && inWorld(link.to, shownEntities[:]) do append(&shownLinks, link)
	}
	return shownLevels[:], shownEntities[:], shownLinks[:]
}

// A level picture's image name (by file and level iid; temp)
@(private="file")
levelImageName :: proc(file, iid: string) -> string {
	return fmt.tprintf("level-map-%x", hash.fnv64a(transmute([]u8)fmt.tprintf("%s|%s", file, iid)))
}

// What a level's picture shows: its layers, size and background, and the definitions (by level
// iid; worked out again when the document changes)
@(private="file")
levelContentKeys :: proc(doc: ^LDtkDoc, file: string) -> ^map[string]u64 {
	if levelKeys.file == file && levelKeys.version == doc.version && levelKeys.keys != nil do return &levelKeys.keys
	for iid in levelKeys.keys do delete(iid)
	clear(&levelKeys.keys)
	delete(levelKeys.file)
	levelKeys.file = strings.clone(file)
	levelKeys.version = doc.version
	main := LDtkDoc_Main(doc)
	defs := hash.fnv64a(transmute([]u8)Json_Text(main, Json_Get(main, Json_Root(main), "defs")))
	for l, i in doc.levels {
		_, iid := LDtkDoc_LevelNames(doc, i)
		json := LDtkDoc_Json(doc, l.file)
		key := defs ~ hash.fnv64a(transmute([]u8)Json_Text(json, Json_Get(json, l.node, "layerInstances")))
		for k in ([]string{"pxWid", "pxHei", "__bgColor", "bgRelPath", "bgPos"}) do key = key * 31 ~ hash.fnv64a(transmute([]u8)Json_Text(main, Json_Get(main, l.entry, k)))
		levelKeys.keys[strings.clone(iid)] = key
	}
	return &levelKeys.keys
}

// The canvas's widget key (the UI tests' and the driver's)
LEVEL_CANVAS_KEY :: "ldtk-map-Level"

/*
The world canvas: the levels, entities and links of the Level mode's file, its input (see the
file's doc block).
*/
levelCanvasView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, file: string) -> skald.View {
	Data :: struct {
		s: ^State,
		file: string,
	}
	data := new_clone(Data{s, strings.clone(file, context.temp_allocator)}, context.temp_allocator)
	return skald.sized(ctx, data, proc(ctx: ^skald.Ctx(Msg), d: ^Data, size: [2]f32) -> skald.View {
		return LevelCanvas_Build(ctx, d.s, d.file, size)
	})
}

/*
The canvas at a size (levelCanvasView gives it the size layout gives it): its input this frame,
then what it draws.
*/
LevelCanvas_Build :: proc(ctx: ^skald.Ctx(Msg), s: ^State, file: string, size: [2]f32) -> skald.View {
	skald.prof_scope("LevelCanvas_Build")
	Data :: struct {
		s: ^State,
		file: string,
	}
	d := &Data{s, file}
	{
		th := ctx.theme
		size := [2]f32{max(size.x, 1), max(size.y, 1)}
		// Its size, and a world it hasn't fitted yet (another file chosen): fitted then
		if size != s.level.view.size || s.level.view.fitted != levelFitKey(s) do skald.send(ctx, Msg(Level_Canvas_Measured(size)))
		doc := LDtkDoc_Get(s.project.rootPath, d.file)
		id := skald.hash_id(LEVEL_CANVAS_KEY)
		if doc == nil || doc.problem != "" do return skald.spacer(0)
		levels, entities, links := LevelCanvas_Content(s, doc)
		// The levels' pictures (level_layers_render.odin), drawn within the frame's budget
		keys := levelContentKeys(doc, d.file)
		deadline := time.tick_add(time.tick_now(), LEVEL_RENDER_BUDGET_MS * time.Millisecond)
		waiting := false
		for l in levels do if LevelPictures_Update(ctx, s, doc, l.image, l.iid, l.identifier, l.world, keys[l.iid], deadline) do waiting = true
		if waiting do skald.send(ctx, Msg(Frame_Requested{}))
		// Before the first fit, a fitted view of its own
		center, zoom := s.level.view.center, s.level.view.zoom
		if zoom <= 0 || s.level.view.fitted != levelFitKey(s) do center, zoom = levelFit(s, doc, size)
		toScreen :: proc(p, center: [2]f32, zoom: f32, size: [2]f32) -> [2]f32 { return size * 0.5 + (p - center) * zoom }

		// Input, from the canvas's last rect
		hoveredLevel, hoveredEntity := -1, -1
		cursor := skald.Cursor_Shape.Default
		if state, drawn := ctx.widgets.states[id]; drawn {
			input := ctx.input
			local := input.mouse_pos - {state.last_rect.x, state.last_rect.y}
			world := center + (local - size * 0.5) / zoom
			inside := local.x >= 0 && local.y >= 0 && local.x < size.x && local.y < size.y
			hovered := inside && skald.widget_hovered(ctx, id) && !skald.mouse_over_overlay(ctx) && len(ctx.widgets.overlay_rects_prev) == 0
			#reverse for e, i in entities {
				// While a level is focused, only its entities
				if e.ghost || (s.level.focus != "" && e.level != s.level.focus) do continue
				r := e.world
				// Tiny entities count a few screen pixels around them
				pad := max(0, 3 / zoom - min(r[2], r[3]) * 0.5)
				if world.x >= r[0] - pad && world.y >= r[1] - pad && world.x < r[0] + r[2] + pad && world.y < r[1] + r[3] + pad {
					hoveredEntity = i
					break
				}
			}
			#reverse for l, i in levels {
				if l.ghost || l.otherDepth do continue
				r := l.world
				if world.x >= r[0] && world.y >= r[1] && world.x < r[0] + r[2] && world.y < r[1] + r[3] {
					hoveredLevel = i
					break
				}
			}
			if !hovered do hoveredLevel, hoveredEntity = -1, -1
			shift := .Shift in input.modifiers
			alt := .Alt in input.modifiers
			ctrl := skald.PRIMARY_MODIFIER in input.modifiers
			stroking := s.level.paint.stroke.kind != .None
			if s.level.drag.mode != .None || stroking {
				// A drag (or a tool's stroke) follows the mouse anywhere until its button is released
				if input.mouse_delta != {} do skald.send(ctx, Msg(Level_Canvas_Moved{world = world, delta = input.mouse_delta, free = shift}))
				if input.mouse_released[.Left] || input.mouse_released[.Middle] || input.mouse_released[.Right] do skald.send(ctx, Msg(Level_Canvas_Released{}))
				cursor = stroking ? LevelPaint_Cursor(s) : .Move
				if s.level.drag.mode == .Pan do cursor = .Grabbing
				if s.level.drag.mode == .Resize do cursor = LevelResize_Cursor(s.level.drag.handle)
				if stroking && s.level.paint.stroke.kind == .Resize do cursor = LevelHandle_Cursor(s.level.paint.stroke.handle)
			} else if hovered {
				if input.scroll != {} {
					wheelZoom, pan := wheelAction(input.scroll, input.modifiers, s.settings.wheelPans)
					if wheelZoom != 0 do skald.send(ctx, Msg(Level_Canvas_Zoomed{math.pow(f32(WHEEL_ZOOM_STEP), wheelZoom), world}))
					if pan != {} do skald.send(ctx, Msg(Level_Canvas_Panned(pan)))
				}
				spaceHeld := .Space in input.keys_down && !IsTyping(ctx)
				panning := input.mouse_pressed[.Middle] || (input.mouse_pressed[.Left] && spaceHeld)
				if panning {
					skald.send(ctx, Msg(Level_Canvas_Pressed{world = world, pan = true}))
				} else if input.mouse_pressed[.Left] || input.mouse_pressed[.Right] {
					// The right button: LDtk's eraser on the focused level, else a pan (levelCanvasPressed)
					right := !input.mouse_pressed[.Left]
					press := Level_Canvas_Pressed{world = world, double = !right && input.mouse_click_count[.Left] >= 2, free = shift, right = right, alt = alt, ctrl = ctrl, at = input.mouse_pos}
					if hoveredEntity >= 0 && !press.double do press.entity = strings.clone(entities[hoveredEntity].iid, context.temp_allocator)
					if hoveredLevel >= 0 do press.level = strings.clone(levels[hoveredLevel].identifier, context.temp_allocator)
					skald.send(ctx, Msg(press))
				}
				// The pointer says what a press does: levels move in the world view, another level
				// is focused by a click, the focused level pans, entities move; then the world
				// tools, the selected entity's handles and the painting tools over all of that
				onFocused := s.level.focus != "" && hoveredLevel >= 0 && levels[hoveredLevel].identifier == s.level.focus
				if hoveredLevel >= 0 do cursor = s.level.focus == "" ? .Move : onFocused ? .Grab : .Pointer
				if hoveredEntity >= 0 do cursor = .Move
				if spaceHeld do cursor = .Grab
				if s.level.spot do cursor = .Crosshair
				if h := LevelResize_HandleAt(s, doc, world); h != .None do cursor = LevelResize_Cursor(h)
				if onFocused && LevelPaint_Cursor(s) != .Default && !spaceHeld do cursor = LevelPaint_Cursor(s)
				if h, found := LevelPaint_HandleHovered(s, doc, world); found && !spaceHeld do cursor = LevelHandle_Cursor(h)
			}
		}

		// What it draws, in screen pixels (temp: the canvas draws after the view returns)
		PaintPiece :: struct {
			rect: [4]f32,
			image: string,
			src: [2]f32,
			alpha: f32,
		}
		PaintLevel :: struct {
			rect: [4]f32,
			pieces: []PaintPiece,
			background: skald.Color,
			label: string,
			selected, hovered, dim, ghost: bool,
			// Its fields' rows (over its bottom in the world view, above it focused) at an opacity
			fields: []LevelFieldRow,
			fieldsAlpha: f32,
			fieldsAbove: bool,
		}
		PaintEntity :: struct {
			rect: [4]f32,
			look: LevelCanvasEntity,
			// dim: in a level that isn't the focused one (not outlined)
			selected, hovered, dim: bool,
		}
		// A field's shape in screen pixels (level_fields_render.odin)
		PaintMark :: struct {
			mark: LevelFieldMark,
			from, to: [2]f32,
			alpha: f32,
		}
		Paint :: struct {
			levels: []PaintLevel,
			entities: []PaintEntity,
			marks: []PaintMark,
			links: []LevelCanvasLink,
			// GridVania's grid (screen pixels between lines, the first lines' offsets; 0: none)
			grid, gridOrigin: [2]f32,
			bg, line, accent, fg, muted, link, neighbour: skald.Color,
			fontSize, zoom: f32,
			// Entities are outlined only when they're big enough to see
			showEntities: bool,
			// The focused level's tool overlay (level_canvas_paint.odin)
			overlay: ^LevelOverlay,
			// A reference being picked: other levels' entities shown
			picking: bool,
			// The world tools' (level_world_tools.odin): handles, a resize, a new level's spot, a
			// linear world's insertion
			world: ^LevelWorldOverlay,
			// LDtk's selection (level_select.odin)
			selection: ^LevelSelectOverlay,
		}
		paint := new(Paint, context.temp_allocator)
		pl := make([]PaintLevel, len(levels), context.temp_allocator)
		model := LevelPaint_Current()
		selectedLayer := -1
		if model != nil && s.level.focus != "" {
			_, selectedLayer = LevelPaint_Layer(s, model)
		}
		for l, i in levels {
			p := toScreen(l.world.xy, center, zoom, size)
			list, _ := LevelPictures_Pieces(l.image)
			pieces := make([dynamic]PaintPiece, 0, len(list), context.temp_allocator)
			focusedLevel := s.level.focus != "" && l.identifier == s.level.focus && model != nil && model.identifier == l.identifier
			for piece in list {
				alpha := f32(1)
				if piece.layer >= 0 {
					if !focusedLevel || piece.layer >= len(model.layers) do continue
					layer := &model.layers[piece.layer]
					if !layer.visible do continue
					// LDtk's LevelRender.applyLayerVisibility: its opacity; not the selected one at
					// its inactive opacity, fainter still in single layer mode
					d := &model.defs[layer.def]
					alpha = f32(d.displayOpacity)
					if piece.layer != selectedLayer {
						alpha *= f32(d.inactiveOpacity)
						if s.level.paint.singleLayer do alpha *= 0.8 - 0.75 * 0.75
					}
				}
				r := piece.rect
				sp := toScreen(l.world.xy + r.xy, center, zoom, size)
				append(&pieces, PaintPiece{rect = {sp.x, sp.y, r[2] * zoom, r[3] * zoom}, image = piece.image, src = piece.size, alpha = alpha})
			}
			pl[i] = {rect = {p.x, p.y, l.world[2] * zoom, l.world[3] * zoom}, pieces = pieces[:],
				background = l.background, label = l.identifier, selected = l.identifier == s.level.level && !l.ghost, hovered = i == hoveredLevel, dim = l.dim, ghost = l.ghost}
			// WorldRender.updateFieldsPos: every level's in the world view, fading out zoomed far out;
			// focused, only the focused level's
			if !l.ghost && !l.otherDepth {
				if s.level.focus == "" {
					pl[i].fields, pl[i].fieldsAlpha = l.fields.rows, min((zoom - 0.1) / 0.1, 1)
				} else if l.identifier == s.level.focus {
					pl[i].fields, pl[i].fieldsAlpha, pl[i].fieldsAbove = l.fields.rows, 1, true
				}
			}
		}
		pe := make([]PaintEntity, len(entities), context.temp_allocator)
		pm := make([dynamic]PaintMark, context.temp_allocator)
		for en, i in entities {
			p := toScreen(en.world.xy, center, zoom, size)
			pe[i] = {rect = {p.x, p.y, en.world[2] * zoom, en.world[3] * zoom}, look = en, selected = en.iid == s.level.entity && !en.ghost, hovered = i == hoveredEntity,
				dim = s.level.focus != "" && en.level != s.level.focus}
			if pe[i].dim || en.ghost do continue
			for m in en.fields.marks do append(&pm, PaintMark{m, toScreen(m.from, center, zoom, size), toScreen(m.to, center, zoom, size), en.fields.alpha})
		}
		// The selected level's neighbours (all of them would cross every level)
		pk := make([dynamic]LevelCanvasLink, context.temp_allocator)
		for link in links {
			if !link.entity && link.level != s.level.level do continue
			append(&pk, LevelCanvasLink{toScreen(link.from, center, zoom, size), toScreen(link.to, center, zoom, size), link.entity, link.level})
		}
		colors := ViewportColors(s, th)
		paint^ = {levels = pl, entities = pe, marks = pm[:], links = pk[:], bg = colors[.Level_Bg], line = colors[.Level_Grid], accent = th.color.primary, fg = th.color.fg,
			muted = th.color.fg_muted, link = skald.rgb(0x7FD1FF), neighbour = th.color.fg_muted, fontSize = th.font.size_xs, zoom = zoom, showEntities = zoom >= 0.15,
			picking = s.level.paint.pick.kind == .Ref}
		shownWorld := LevelMode_World(s, doc)
		if len(doc.worlds) > 0 && LDtkDoc_WorldLayout(doc, shownWorld) == "GridVania" {
			grid := LDtkDoc_WorldGrid(doc, shownWorld)
			step := [2]f32{f32(grid.x), f32(grid.y)} * zoom
			if step.x >= 8 && step.y >= 8 {
				origin := toScreen({0, 0}, center, zoom, size)
				paint.grid = step
				paint.gridOrigin = {math.mod(origin.x, step.x), math.mod(origin.y, step.y)}
			}
		}
		// The focused level's tool overlay: its layer's grid, the brush, handles, points
		if s.level.focus != "" {
			for l in levels do if l.identifier == s.level.focus {
				hover: Maybe([2]f32)
				if state, drawn := ctx.widgets.states[id]; drawn && skald.widget_hovered(ctx, id) {
					local := ctx.input.mouse_pos - {state.last_rect.x, state.last_rect.y}
					hover = center + (local - size * 0.5) / zoom
				}
				paint.overlay = LevelOverlay_Build(ctx, s, doc, l.world, hover, center, zoom, size)
			}
		}
		{
			hover: Maybe([2]f32)
			if state, drawn := ctx.widgets.states[id]; drawn && skald.widget_hovered(ctx, id) {
				local := ctx.input.mouse_pos - {state.last_rect.x, state.last_rect.y}
				hover = center + (local - size * 0.5) / zoom
			}
			paint.world = LevelWorldOverlay_Build(s, doc, hover, center, zoom, size)
			if s.level.focus != "" do for l in levels do if l.identifier == s.level.focus && !l.ghost do paint.selection = LevelSelectOverlay_Build(s, doc, l.world.xy, center, zoom, size)
			if s.level.spot do cursor = .Crosshair
		}
		return skald.canvas(ctx, paint, proc(p: ^Paint, painter: skald.Canvas_Painter) {
			r := painter.r
			b := painter.bounds
			skald.push_clip(r, b)
			defer skald.pop_clip(r)
			skald.draw_rect(r, b, p.bg)
			if p.grid.x > 0 {
				line := p.line
				line.a *= 0.35
				for x := p.gridOrigin.x; x < b.w; x += p.grid.x do skald.draw_rect(r, {b.x + x, b.y, 1, b.h}, line)
				for y := p.gridOrigin.y; y < b.h; y += p.grid.y do skald.draw_rect(r, {b.x, b.y + y, b.w, 1}, line)
			}
			for l in p.levels {
				rect := skald.Rect{b.x + l.rect[0], b.y + l.rect[1], l.rect[2], l.rect[3]}
				skald.draw_rect(r, rect, l.background)
				skald.push_clip(r, rect)
				for piece in l.pieces {
					skald.draw_image_region(r, piece.image, {b.x + piece.rect[0], b.y + piece.rect[1], piece.rect[2], piece.rect[3]}, {0, 0, piece.src.x, piece.src.y}, tint = {1, 1, 1, piece.alpha}, inset = false)
				}
				skald.pop_clip(r)
				// Not the focused level: faded into the background, as LDtk's level view shows its neighbours
				if l.dim do skald.draw_rect(r, rect, {p.bg.r, p.bg.g, p.bg.b, 0.7})
				// A copy being dragged: translucent over what's there
				if l.ghost do skald.draw_rect(r, rect, {p.accent.r, p.accent.g, p.accent.b, 0.25})
			}
			// The selected layer's grid under the entities
			if p.overlay != nil do LevelOverlay_DrawGrid(r, b, p.overlay)
			// Links under the outlines: neighbours faint, references as arrows
			for link in p.links {
				a, c := [2]f32{b.x, b.y} + link.from, [2]f32{b.x, b.y} + link.to
				if !link.entity {
					// Dashed, ending in a ring at the neighbour's center
					d := c - a
					length := math.sqrt(d.x * d.x + d.y * d.y)
					if length < 1 do continue
					dir := d / length
					for t: f32 = 0; t < length; t += 10 do skald.draw_line(r, a + dir * t, a + dir * min(t + 5, length), 1.5, p.neighbour, aa = true)
					skald.draw_ring(r, c, 5, 1.5, p.neighbour)
					continue
				}
				skald.draw_line(r, a, c, 2, p.link, aa = true)
				d := c - a
				length := math.sqrt(d.x * d.x + d.y * d.y)
				if length < 1 do continue
				dir := d / length
				side := [2]f32{-dir.y, dir.x}
				head := c - dir * 4
				skald.draw_polygon(r, {c, head - dir * 6 + side * 5, head - dir * 6 - side * 5}, p.link, aa = true)
				skald.draw_circle(r, a, 3, p.link, aa = true)
			}
			// Fields' shapes (radii, points, reference links) under the entities
			if p.showEntities do for m in p.marks do LevelFields_DrawMark(r, m.mark, [2]f32{b.x, b.y} + m.from, [2]f32{b.x, b.y} + m.to, p.zoom, m.alpha)
			for e in p.entities {
				// Another level's entities show while a reference is picked (they can be picked)
				if e.dim && !e.selected && !p.picking do continue
				rect := skald.Rect{b.x + e.rect[0], b.y + e.rect[1], max(e.rect[2], 2), max(e.rect[3], 2)}
				// LDtk's look (EntityRender), big enough to see
				if p.showEntities || e.selected do LevelEntity_Draw(r, rect, e.look, p.fontSize, p.zoom)
				switch {
				case e.selected: skald.draw_rect_outline(r, {rect.x - 2, rect.y - 2, rect.w + 4, rect.h + 4}, 2, p.accent)
				case e.hovered:  skald.draw_rect_outline(r, {rect.x - 1, rect.y - 1, rect.w + 2, rect.h + 2}, 2, p.fg)
				}
			}
			// Fields' values around their entities, over every entity
			if p.showEntities do for e in p.entities {
				if e.dim || len(e.look.fields.rows) == 0 do continue
				rect := skald.Rect{b.x + e.rect[0], b.y + e.rect[1], max(e.rect[2], 2), max(e.rect[3], 2)}
				LevelFields_DrawRows(r, rect, e.look.fields.rows, p.fontSize, e.look.fields.alpha, LevelEntity_NameShown(e.look, rect, p.zoom))
			}
			if p.overlay != nil do LevelOverlay_Draw(r, b, p.overlay)
			for l in p.levels {
				rect := skald.Rect{b.x + l.rect[0], b.y + l.rect[1], l.rect[2], l.rect[3]}
				switch {
				case l.selected: skald.draw_rect_outline(r, {rect.x - 2, rect.y - 2, rect.w + 4, rect.h + 4}, 3, p.accent)
				case l.hovered:  skald.draw_rect_outline(r, rect, 2, p.fg)
				case:            skald.draw_rect_outline(r, rect, 1, p.line)
				}
				// Its name in its top-left corner, on a backdrop
				labelWidth := f32(len(l.label)) * p.fontSize * 0.6 + 8
				if rect.w > labelWidth * 0.5 && rect.h > p.fontSize + 6 {
					skald.draw_rect(r, {rect.x + 1, rect.y + 1, min(labelWidth, rect.w - 2), p.fontSize + 6}, {p.bg.r, p.bg.g, p.bg.b, 0.75})
					skald.push_clip(r, {rect.x, rect.y, rect.w, rect.h})
					drawTextTop(r, l.label, rect.x + 4, rect.y + 3, l.selected ? p.accent : p.fg, p.fontSize)
					skald.pop_clip(r)
				}
			}
			// Levels' fields
			for l in p.levels {
				if len(l.fields) == 0 || l.fieldsAlpha <= 0 do continue
				rect := skald.Rect{b.x + l.rect[0], b.y + l.rect[1], l.rect[2], l.rect[3]}
				line := l.fieldsAbove ? skald.Rect{rect.x, rect.y - 4, rect.w, 0} : skald.Rect{rect.x, rect.y + rect.h - 4, rect.w, 0}
				LevelFields_DrawRows(r, line, l.fields, p.fontSize, l.fieldsAlpha, false)
			}
			if p.overlay != nil do LevelOverlay_DrawHint(r, b, p.overlay)
			if p.selection != nil do LevelSelectOverlay_Draw(r, b, p.selection)
			if p.world != nil do LevelWorldOverlay_Draw(r, b, p.world, p.fg, p.accent, p.bg, p.fontSize)
		}, id = id, width = size.x, height = size.y, cursor = cursor)
	}
}

/*
Where a world point of the Level mode's canvas is in the window, as last drawn (the UI test
driver's drags and clicks).

Returns:
- The window point, and false when the canvas hasn't been drawn
*/
LevelCanvas_WorldToWindow :: proc(s: ^State, ctx: ^skald.Ctx(Msg), world: [2]f32) -> ([2]f32, bool) {
	state, drawn := ctx.widgets.states[skald.hash_id(LEVEL_CANVAS_KEY)]
	if !drawn || s.level.view.zoom <= 0 do return {}, false
	r := state.last_rect
	return [2]f32{r.x, r.y} + [2]f32{r.w, r.h} * 0.5 + (world - s.level.view.center) * s.level.view.zoom, true
}
