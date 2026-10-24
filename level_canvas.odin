package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "gui:skald"

/*
The Level mode's world canvas (level_mode.odin): an LDtk project's levels where its world puts
them, each drawn by the engine with its layers (`Preview_RenderLDtkLevel`, one picture per level,
uploaded once per change of what it draws: not when it only moves), with its entities outlined
and the links between them (entity reference fields, as arrows) and to neighbouring levels.

- **The view** (`LevelView`): the world point at the center and a zoom, fitted to the world when a
  file first shows (`LevelCanvas_FitOnce`) and by Fit. Screen = size / 2 + (world - center) *
  zoom.
- **Input** (from the canvas's last rect, as the viewport's): the wheel zooms around the pointer
  or pans (`wheelAction`, Settings > Editor > Wheel pans); a press sends `Level_Canvas_Pressed`
  with what's under the pointer (an entity first, then a level); while a drag is on, every move
  sends `Level_Canvas_Moved` and the release `Level_Canvas_Released`, wherever the pointer is.
  Middle or right drag and Space + drag pan.
- **A drag shows where it'll land** (`LevelDrag_Target`: a GridVania world's grid, an entity's
  layer grid) before the release writes it.

The pictures are Skald images named `level-map-<hash>` (by file and level iid), kept in
`levelImages` (thread-local package state, like the preview's) with the content key they show:
a hash of the level's layers and the project's definitions, so moving a level doesn't draw it
again.
*/

// A level's picture on the canvas
@(private="file")
LevelImage :: struct {
	// What it shows (the level's layers and the definitions), its pixels' size, their scale
	key: u64,
	size: [2]int,
	scale: f32,
}

@(private="file", thread_local)
levelImages: map[string]LevelImage

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
	for name in levelImages do delete(name)
	delete(levelImages)
	levelImages = nil
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
	// Not the focused level (while one is): drawn dimmed
	dim: bool,
}

// An entity as the canvas draws it
LevelCanvasEntity :: struct {
	iid, identifier: string,
	// Its level's identifier
	level: string,
	// Its world rectangle and center
	world: [4]f32,
	center: [2]f32,
	color: skald.Color,
}

// A link: an entity reference (`entity`) or a neighbour (between level centers; `level`: the
// level it's of, by identifier)
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
	for _, i in doc.levels {
		identifier, iid := LDtkDoc_LevelNames(doc, i)
		r := LDtkDoc_LevelRect(doc, i)
		at := [4]f32{f32(r[0]), f32(r[1]), f32(r[2]), f32(r[3])}
		if drag.moved && drag.mode == .Level && drag.target == iid do at.xy = {f32(moved.x), f32(moved.y)}
		bg := skald.rgb(0x202838)
		if c, ok := LDtk_ParseColor(Json_String(main, Json_Get(main, doc.levels[i].entry, "__bgColor"))); ok do bg = skald.rgb(u32(c))
		append(&ls, LevelCanvasLevel{identifier = identifier, iid = iid, world = at, image = levelImageName(LevelMode_File(state), iid), background = bg,
			dim = state.level.focus != "" && identifier != state.level.focus})
	}
	es := make([dynamic]LevelCanvasEntity, context.temp_allocator)
	centers := make(map[string][2]f32, context.temp_allocator)
	for e in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		def := LDtkDoc_DefByUid(doc, "entities", Json_Int(json, Json_Get(json, e.node, "defUid"), -1))
		px := Json_Get(json, e.node, "px")
		p := [2]f32{f32(Json_Int(json, Json_At(json, px, 0))), f32(Json_Int(json, Json_At(json, px, 1)))}
		iid := Json_String(json, Json_Get(json, e.node, "iid"))
		if drag.moved && drag.mode == .Entity && drag.target == iid do p = {f32(moved.x), f32(moved.y)}
		w := f32(Json_Int(json, Json_Get(json, e.node, "width"), 16))
		h := f32(Json_Int(json, Json_Get(json, e.node, "height"), 16))
		pivot := [2]f32{f32(Json_Float(main, Json_Get(main, def, "pivotX"), 0.5)), f32(Json_Float(main, Json_Get(main, def, "pivotY"), 0.5))}
		origin := ls[e.level].world.xy
		x0 := origin + p - pivot * [2]f32{w, h}
		color := skald.rgb(0xFFCC00)
		if c, ok := LDtk_ParseColor(Json_String(json, Json_Get(json, e.node, "__smartColor"))); ok do color = skald.rgb(u32(c))
		entity := LevelCanvasEntity{iid = iid, identifier = Json_String(json, Json_Get(json, e.node, "__identifier")), level = ls[e.level].identifier, world = {x0.x, x0.y, w, h}, center = x0 + {w, h} * 0.5, color = color}
		append(&es, entity)
		centers[iid] = entity.center
	}
	lk := make([dynamic]LevelCanvasLink, context.temp_allocator)
	// Entity references: from the entity to each target (arrays too)
	for e, i in LDtkDoc_Entities(doc) {
		json := LDtkDoc_Json(doc, e.file)
		for fi in Json_Items(json, Json_Get(json, e.node, "fieldInstances")) {
			t := Json_String(json, Json_Get(json, fi, "__type"))
			if t != "EntityRef" && t != "Array<EntityRef>" do continue
			value := Json_Get(json, fi, "__value")
			targets := Json_Kind(json, value) == .Array ? Json_Items(json, value) : []int{value}
			for target in targets {
				to, found := centers[Json_String(json, Json_Get(json, target, "entityIid"))]
				if found do append(&lk, LevelCanvasLink{from = es[i].center, to = to, entity = true})
			}
		}
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
	shownEntities := make([dynamic]LevelCanvasEntity, context.temp_allocator)
	for en, i in LDtkDoc_Entities(doc) do if doc.levels[en.level].world == world do append(&shownEntities, es[i])
	if len(doc.worlds) <= 1 do return ls[:], es[:], lk[:]
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

// Pictures drawn per frame at most: a big world's first frame doesn't wait for every level (the
// others show their background meanwhile, and frames keep coming until they're drawn)
LEVEL_IMAGES_PER_FRAME :: 3

// Draws (and uploads) the levels' pictures that changed since they were last uploaded
@(private="file")
levelUploadImages :: proc(ctx: ^skald.Ctx(Msg), s: ^State, doc: ^LDtkDoc, file: string, levels: []LevelCanvasLevel) {
	if ctx.renderer == nil do return
	keys := levelContentKeys(doc, file)
	drawn := 0
	for l in levels {
		key := keys[l.iid]
		if image, found := levelImages[l.image]; found && image.key == key do continue
		if drawn >= LEVEL_IMAGES_PER_FRAME {
			skald.send(ctx, Msg(Frame_Requested{}))
			return
		}
		drawn += 1
		scale := min(1, f32(LEVEL_IMAGE_MAX) / max(l.world[2], l.world[3], 1))
		pixels, size, ok := Preview_RenderLDtkLevel(s, file, l.identifier, l.world.zw, scale)
		if !ok do continue
		previous, had := levelImages[l.image]
		if had && previous.size == size do skald.image_update_pixels(ctx.renderer, l.image, u32(size.x), u32(size.y), pixels)
		else do skald.image_load_pixels(ctx.renderer, l.image, u32(size.x), u32(size.y), pixels, mipmaps = false)
		if !had do levelImages[strings.clone(l.image)] = {}
		levelImages[l.image] = {key, size, scale}
	}
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
		levelUploadImages(ctx, s, doc, d.file, levels)
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
				if s.level.focus != "" && e.level != s.level.focus do continue
				r := e.world
				// Tiny entities count a few screen pixels around them
				pad := max(0, 3 / zoom - min(r[2], r[3]) * 0.5)
				if world.x >= r[0] - pad && world.y >= r[1] - pad && world.x < r[0] + r[2] + pad && world.y < r[1] + r[3] + pad {
					hoveredEntity = i
					break
				}
			}
			#reverse for l, i in levels {
				r := l.world
				if world.x >= r[0] && world.y >= r[1] && world.x < r[0] + r[2] && world.y < r[1] + r[3] {
					hoveredLevel = i
					break
				}
			}
			if !hovered do hoveredLevel, hoveredEntity = -1, -1
			shift := .Shift in input.modifiers
			if s.level.drag.mode != .None {
				// A drag follows the mouse anywhere until its button is released
				if input.mouse_delta != {} do skald.send(ctx, Msg(Level_Canvas_Moved{world = world, delta = input.mouse_delta, free = shift}))
				if input.mouse_released[.Left] || input.mouse_released[.Middle] || input.mouse_released[.Right] do skald.send(ctx, Msg(Level_Canvas_Released{}))
				cursor = .Move
			} else if hovered {
				if input.scroll != {} {
					wheelZoom, pan := wheelAction(input.scroll, input.modifiers, s.settings.wheelPans)
					if wheelZoom != 0 do skald.send(ctx, Msg(Level_Canvas_Zoomed{math.pow(f32(WHEEL_ZOOM_STEP), wheelZoom), world}))
					if pan != {} do skald.send(ctx, Msg(Level_Canvas_Panned(pan)))
				}
				spaceHeld := .Space in input.keys_down && !IsTyping(ctx)
				panning := input.mouse_pressed[.Middle] || input.mouse_pressed[.Right] || (input.mouse_pressed[.Left] && spaceHeld)
				if panning {
					skald.send(ctx, Msg(Level_Canvas_Pressed{world = world, pan = true}))
				} else if input.mouse_pressed[.Left] {
					press := Level_Canvas_Pressed{world = world, double = input.mouse_click_count[.Left] >= 2, free = shift}
					if hoveredEntity >= 0 && !press.double do press.entity = strings.clone(entities[hoveredEntity].iid, context.temp_allocator)
					if hoveredLevel >= 0 do press.level = strings.clone(levels[hoveredLevel].identifier, context.temp_allocator)
					skald.send(ctx, Msg(press))
				}
				if hoveredEntity >= 0 || hoveredLevel >= 0 do cursor = .Pointer
			}
		}

		// What it draws, in screen pixels (temp: the canvas draws after the view returns)
		PaintLevel :: struct {
			rect: [4]f32,
			image: string,
			src: [2]f32,
			background: skald.Color,
			label: string,
			selected, hovered, dim: bool,
		}
		PaintEntity :: struct {
			rect: [4]f32,
			color: skald.Color,
			// dim: in a level that isn't the focused one (not outlined)
			selected, hovered, dim: bool,
		}
		Paint :: struct {
			levels: []PaintLevel,
			entities: []PaintEntity,
			links: []LevelCanvasLink,
			// GridVania's grid (screen pixels between lines, the first lines' offsets; 0: none)
			grid, gridOrigin: [2]f32,
			bg, line, accent, fg, muted, link, neighbour: skald.Color,
			fontSize: f32,
			// Entities are outlined only when they're big enough to see
			showEntities: bool,
		}
		paint := new(Paint, context.temp_allocator)
		pl := make([]PaintLevel, len(levels), context.temp_allocator)
		for l, i in levels {
			p := toScreen(l.world.xy, center, zoom, size)
			image := levelImages[l.image]
			pl[i] = {rect = {p.x, p.y, l.world[2] * zoom, l.world[3] * zoom}, image = l.image, src = {f32(image.size.x), f32(image.size.y)},
				background = l.background, label = l.identifier, selected = l.identifier == s.level.level, hovered = i == hoveredLevel, dim = l.dim}
		}
		pe := make([]PaintEntity, len(entities), context.temp_allocator)
		for en, i in entities {
			p := toScreen(en.world.xy, center, zoom, size)
			pe[i] = {rect = {p.x, p.y, en.world[2] * zoom, en.world[3] * zoom}, color = en.color, selected = en.iid == s.level.entity, hovered = i == hoveredEntity,
				dim = s.level.focus != "" && en.level != s.level.focus}
		}
		// The selected level's neighbours (all of them would cross every level)
		pk := make([dynamic]LevelCanvasLink, context.temp_allocator)
		for link in links {
			if !link.entity && link.level != s.level.level do continue
			append(&pk, LevelCanvasLink{toScreen(link.from, center, zoom, size), toScreen(link.to, center, zoom, size), link.entity, link.level})
		}
		paint^ = {levels = pl, entities = pe, links = pk[:], bg = th.color.bg, line = th.color.border, accent = th.color.primary, fg = th.color.fg,
			muted = th.color.fg_muted, link = skald.rgb(0x7FD1FF), neighbour = th.color.fg_muted, fontSize = th.font.size_xs, showEntities = zoom >= 0.15}
		if len(doc.worlds) > 0 && LDtkDoc_WorldLayout(doc, 0) == "GridVania" {
			grid := LDtkDoc_WorldGrid(doc, 0)
			step := [2]f32{f32(grid.x), f32(grid.y)} * zoom
			if step.x >= 8 && step.y >= 8 {
				origin := toScreen({0, 0}, center, zoom, size)
				paint.grid = step
				paint.gridOrigin = {math.mod(origin.x, step.x), math.mod(origin.y, step.y)}
			}
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
				if l.src.x > 0 do skald.draw_image_region(r, l.image, rect, {0, 0, l.src.x, l.src.y}, inset = false)
				// Not the focused level: faded into the background, as LDtk's level view shows its neighbours
				if l.dim do skald.draw_rect(r, rect, {p.bg.r, p.bg.g, p.bg.b, 0.7})
			}
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
			for e in p.entities {
				if (!p.showEntities || e.dim) && !e.selected do continue
				rect := skald.Rect{b.x + e.rect[0], b.y + e.rect[1], max(e.rect[2], 2), max(e.rect[3], 2)}
				switch {
				case e.selected: skald.draw_rect_outline(r, {rect.x - 2, rect.y - 2, rect.w + 4, rect.h + 4}, 2, p.accent)
				case e.hovered:  skald.draw_rect_outline(r, {rect.x - 1, rect.y - 1, rect.w + 2, rect.h + 2}, 2, p.fg)
				case:            skald.draw_rect_outline(r, rect, 1, {e.color.r, e.color.g, e.color.b, 0.8})
				}
			}
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
