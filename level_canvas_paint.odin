package crossfire_editor

import "core:math"
import "gui:skald"

/*
What the Level mode's canvas draws over the focused level for the tools (level_paint.odin), as
LDtk draws it (its LevelRender.renderGrid, the tools' cursors, ResizeTool, EntityRender):

- **The grid** of the selected layer (LDtk's 7% white lines, black on a light project
  background; its guide grid at 33%), unless G turned it off, and not when cells are under 6
  screen pixels.
- **The brush** at the pointer: an IntGrid value's cell in its color, the tile stamp (flipped as
  it'll paint), the entity type Place puts where it'll go, the eraser's cell, a rectangle while
  Shift is held.
- **The selected entity's** resize handles (yellow, as LDtk's) and its point fields' points and
  path.
- **A hint** while the Entities tab waits for a pick, and why a press was refused.

Entities themselves are drawn by `LevelEntity_Draw` (their shape, tile, opacities, name).
*/

// A rectangle the overlay draws (screen pixels relative to the canvas)
LevelOverlayRect :: struct {
	rect: [4]f32,
	fill, outline: skald.Color,
	width: f32,
}

// An image the overlay draws (the stamp's preview)
LevelOverlayImage :: struct {
	name: string,
	rect: [4]f32,
	src: [2]f32,
	alpha: f32,
}

// A circle (a handle, a point)
LevelOverlayCircle :: struct {
	center: [2]f32,
	radius: f32,
	color: skald.Color,
	ring: bool,
}

// A line (a point path)
LevelOverlayLine :: struct {
	a, b: [2]f32,
	color: skald.Color,
	width: f32,
}

// The focused level's tool overlay, built in the view (temp allocated)
LevelOverlay :: struct {
	// The grid's lines (1 px rectangles) and color; the guide grid's
	grid, guide: [dynamic][4]f32,
	gridColor, guideColor: skald.Color,
	rects: [dynamic]LevelOverlayRect,
	images: [dynamic]LevelOverlayImage,
	circles: [dynamic]LevelOverlayCircle,
	lines: [dynamic]LevelOverlayLine,
	hint: string,
	hintColor, hintBg: skald.Color,
	fontSize: f32,
}

/*
Builds the overlay of the focused level (temp allocated).

Inputs:
- world: The level's world rectangle
- hover: The pointer's world point when it's over the canvas
- center, zoom, size: The canvas's view
*/
LevelOverlay_Build :: proc(ctx: ^skald.Ctx(Msg), s: ^State, doc: ^LDtkDoc, world: [4]f32, hover: Maybe([2]f32), center: [2]f32, zoom: f32, size: [2]f32) -> ^LevelOverlay {
	o := new(LevelOverlay, context.temp_allocator)
	o.grid = make([dynamic][4]f32, context.temp_allocator)
	o.guide = make([dynamic][4]f32, context.temp_allocator)
	o.rects = make([dynamic]LevelOverlayRect, context.temp_allocator)
	o.images = make([dynamic]LevelOverlayImage, context.temp_allocator)
	o.circles = make([dynamic]LevelOverlayCircle, context.temp_allocator)
	o.lines = make([dynamic]LevelOverlayLine, context.temp_allocator)
	o.fontSize = ctx.theme.font.size_xs
	o.hintColor = ctx.theme.color.fg
	o.hintBg = ctx.theme.color.bg
	toScreen :: proc(p, center: [2]f32, zoom: f32, size: [2]f32) -> [2]f32 { return size * 0.5 + (p - center) * zoom }
	m := LevelPaint_Current()
	if m == nil || m.identifier != s.level.focus do return o
	l, _ := LevelPaint_Layer(s, m)
	paint := &s.level.paint
	main := LDtkDoc_Main(doc)
	// Level pixels to screen
	at :: proc(world: [4]f32, p, center: [2]f32, zoom: f32, size: [2]f32) -> [2]f32 {
		return size * 0.5 + (world.xy + p - center) * zoom
	}

	// The grid (LevelRender.renderGrid)
	if l != nil && !paint.noGrid {
		d := &m.defs[l.def]
		bg, _ := LDtk_ParseColor(Json_String(main, Json_Get(main, Json_Root(main), "bgColor")))
		lum := (0.299 * f32((bg >> 16) & 255) + 0.587 * f32((bg >> 8) & 255) + 0.114 * f32(bg & 255)) / 255
		base := lum >= 0.8 ? skald.Color{0, 0, 0, 1} : skald.Color{1, 1, 1, 1}
		o.gridColor = {base.r, base.g, base.b, 0.07}
		o.guideColor = {base.r, base.g, base.b, 0.33}
		grid := f32(d.gridSize)
		off := LDtkLayer_Offset(m, l)
		if grid * zoom >= 6 {
			top := at(world, {0, max(f32(off.y), 0)}, center, zoom, size)
			bottom := at(world, {0, min(f32(l.cHei) * grid, world[3])}, center, zoom, size)
			for cx in 0 ..= l.cWid {
				x := f32(cx) * grid + f32(off.x)
				if x < 0 || x > world[2] do continue
				p := at(world, {x, 0}, center, zoom, size)
				if p.x < -1 || p.x > size.x + 1 do continue
				append(&o.grid, [4]f32{p.x, top.y, 1, bottom.y - top.y})
			}
			left := at(world, {max(f32(off.x), 0), 0}, center, zoom, size)
			right := at(world, {min(f32(l.cWid) * grid, world[2]), 0}, center, zoom, size)
			for cy in 0 ..= l.cHei {
				y := f32(cy) * grid + f32(off.y)
				if y < 0 || y > world[3] do continue
				p := at(world, {0, y}, center, zoom, size)
				if p.y < -1 || p.y > size.y + 1 do continue
				append(&o.grid, [4]f32{left.x, p.y, right.x - left.x, 1})
			}
		}
		// The guide grid (the layer's guideGridWid / Hei)
		ld := LDtkDoc_DefByUid(doc, "layers", d.uid)
		gw, gh := f32(Json_Int(main, Json_Get(main, ld, "guideGridWid"))), f32(Json_Int(main, Json_Get(main, ld, "guideGridHei")))
		if gw > 1 && gw * zoom >= 6 {
			for x := f32(off.x); x <= world[2]; x += gw {
				p := at(world, {x, 0}, center, zoom, size)
				q := at(world, {x, world[3]}, center, zoom, size)
				append(&o.guide, [4]f32{p.x, p.y, 1, q.y - p.y})
			}
		}
		if gh > 1 && gh * zoom >= 6 {
			for y := f32(off.y); y <= world[3]; y += gh {
				p := at(world, {0, y}, center, zoom, size)
				q := at(world, {world[2], y}, center, zoom, size)
				append(&o.guide, [4]f32{p.x, p.y, q.x - p.x, 1})
			}
		}
	}

	// The Auto-layer Rules tab's: its rule's or group's cells, the Perlin noise, the cell under
	// the pointer (the tab highlights its rules)
	if s.level.bottomTab == .Auto_Layer_Rules do levelRulesOverlay(o, s, doc, m, world, hover, center, zoom, size)

	// The selected entity's handles and points
	level := LDtkDoc_FindLevel(doc, s.level.focus)
	if s.level.entity != "" && level >= 0 {
		for b in LevelPaint_Entities(doc, level) {
			if b.iid != s.level.entity do continue
			box := b
			if paint.stroke.kind == .Resize && paint.stroke.entity == b.iid do box.at, box.size = paint.stroke.at, paint.stroke.size
			yellow := skald.rgb(0xFFCC00)
			yellow.a = 0.75
			for h in LevelHandle do if LevelPaint_HandleActive(box, h) {
				c := LevelPaint_HandleAt(box, h)
				append(&o.circles, LevelOverlayCircle{at(world, c, center, zoom, size), max(5 * 0.6 * zoom, 3), yellow, false})
			}
			// Point fields: a path from the entity through its points (LDtk's PointPath)
			points := LevelPaint_Points(doc, b.iid)
			tl := LevelEntityBox_TopLeft(box)
			from := at(world, {f32(tl.x + box.offset.x) + f32(box.size.x) * 0.5, f32(tl.y + box.offset.y) + f32(box.size.y) * 0.5}, center, zoom, size)
			color := skald.rgb(0xFFFFFF)
			if e, found := LDtkDoc_FindEntity(doc, b.iid); found {
				json := LDtkDoc_Json(doc, e.file)
				if c, ok := LDtk_ParseColor(Json_String(json, Json_Get(json, e.node, "__smartColor"))); ok do color = skald.rgb(u32(c))
			}
			entityCenter := from
			lastField := -1
			for pt in points {
				c := pt.center
				if paint.stroke.kind == .Point && paint.stroke.field == pt.field && paint.stroke.index == pt.index {
					// Where the drag puts it
					if lay := LevelPaint_LayerByDef(m, b.layer); lay != nil {
						g := f32(m.defs[lay.def].gridSize)
						off := LDtkLayer_Offset(m, lay)
						c = {(f32(paint.stroke.at.x) + 0.5) * g + f32(off.x), (f32(paint.stroke.at.y) + 0.5) * g + f32(off.y)}
					}
				}
				sp := at(world, c, center, zoom, size)
				// Each field's path starts at the entity
				if pt.field != lastField do from = entityCenter
				append(&o.lines, LevelOverlayLine{from, sp, {color.r, color.g, color.b, 0.6}, 1.5})
				append(&o.circles, LevelOverlayCircle{sp, max(3, 4 * zoom * 0.25), color, true})
				from = sp
				lastField = pt.field
			}
		}
	}

	// The brush at the pointer
	pointer, hovering := hover.?
	if hovering && l != nil && s.level.drag.mode == .None {
		lp := pointer - world.xy
		inside := lp.x >= 0 && lp.y >= 0 && lp.x < world[2] && lp.y < world[3]
		d := &m.defs[l.def]
		grid := f32(d.gridSize)
		off := LDtkLayer_Offset(m, l)
		cellRect :: proc(world: [4]f32, c: [2]int, grid: f32, off: [2]int, center: [2]f32, zoom: f32, size: [2]f32) -> [4]f32 {
			p := size * 0.5 + (world.xy + [2]f32{f32(c.x) * grid + f32(off.x), f32(c.y) * grid + f32(off.y)} - center) * zoom
			return {p.x, p.y, grid * zoom, grid * zoom}
		}
		st := &paint.stroke
		tool := s.level.tool
		if paint.pick.kind == .None && (inside || st.kind == .Grid) && painting_(tool) {
			cell := LDtkLayer_CellAt(m, l, lp)
			erase := tool == .Eraser || (st.kind == .Grid && st.mode == .Remove)
			red := skald.rgb(0xFF4040)
			switch d.kind {
			case .IntGrid, .Tiles:
				color := skald.Color{1, 1, 1, 1}
				if d.kind == .IntGrid {
					if v := LDtkLayerInfo_Value(d, LevelPaint_Value(s, m, l)); v != nil do color = skald.rgb(v.color)
				}
				if erase do color = red
				if st.kind == .Grid && st.rectangle {
					a, c := st.origin, st.last
					r0 := cellRect(world, {min(a.x, c.x), min(a.y, c.y)}, grid, off, center, zoom, size)
					r1 := cellRect(world, {max(a.x, c.x), max(a.y, c.y)}, grid, off, center, zoom, size)
					rect := [4]f32{r0[0], r0[1], r1[0] + r1[2] - r0[0], r1[1] + r1[3] - r0[1]}
					append(&o.rects, LevelOverlayRect{rect, {color.r, color.g, color.b, 0.25}, color, 2})
				} else if d.kind == .Tiles && !erase && tool != .Picker {
					brush := LevelPaint_Brush(s, m, l)
					if paint.random && len(brush.ids) > 0 do brush.ids = brush.ids[:1]
					name, extent := LevelPictures_BrushImage(ctx, doc, m, l, brush)
					if name != "" {
						p := at(world, {f32(cell.x) * grid + f32(off.x), f32(cell.y) * grid + f32(off.y)}, center, zoom, size)
						append(&o.images, LevelOverlayImage{name, {p.x, p.y, extent.x * zoom, extent.y * zoom}, extent, 0.75})
						append(&o.rects, LevelOverlayRect{{p.x, p.y, extent.x * zoom, extent.y * zoom}, {}, {1, 1, 1, 0.6}, 1})
					}
				} else {
					rect := cellRect(world, cell, grid, off, center, zoom, size)
					fill := color
					fill.a = tool == .Picker ? 0 : 0.45
					append(&o.rects, LevelOverlayRect{rect, fill, color, tool == .Picker ? 2 : 1})
				}
			case .Entities:
				if tool == .Pencil && !erase {
					// The type Place puts, where it'll go
					defUid := paint.entityDef
					if defUid < 0 || LDtkDoc_DefByUid(doc, "entities", defUid) < 0 do defUid = LevelPaint_FirstAllowed(doc, LDtkDoc_DefByUid(doc, "layers", d.uid), main)
					def := LDtkDoc_DefByUid(doc, "entities", defUid)
					if def >= 0 {
						pivot := [2]f32{f32(Json_Float(main, Json_Get(main, def, "pivotX"), 0.5)), f32(Json_Float(main, Json_Get(main, def, "pivotY"), 0.5))}
						w, h := f32(Json_Int(main, Json_Get(main, def, "width"), 16)), f32(Json_Int(main, Json_Get(main, def, "height"), 16))
						placed := lp
						if !paint.noGrid do placed = {math.round((f32(cell.x) + pivot.x) * grid), math.round((f32(cell.y) + pivot.y) * grid)} + {f32(off.x), f32(off.y)}
						c, _ := LDtk_ParseColor(Json_String(main, Json_Get(main, def, "color")))
						color := skald.rgb(u32(c))
						p := at(world, placed - pivot * {w, h}, center, zoom, size)
						append(&o.rects, LevelOverlayRect{{p.x, p.y, w * zoom, h * zoom}, {color.r, color.g, color.b, 0.3}, color, 1})
					}
				} else if erase {
					append(&o.circles, LevelOverlayCircle{toScreen(pointer, center, zoom, size), 6, red, true})
				}
			case .AutoLayer:
			}
		}
	}
	switch paint.pick.kind {
	case .None:
	case .Ref:   o.hint = "Click an entity to point the reference at it (the right button or Esc: cancel)"
	case .Point: o.hint = paint.pick.index < 0 ? "Click cells to add points (the right button or Esc: done)" : "Click a cell for the point (the right button or Esc: cancel)"
	}
	if o.hint == "" && s.level.problem != "" && s.mode == .Level do o.hint = s.level.problem
	return o
}

// Whether a tool draws a brush (anything but Select)
@(private="file")
painting_ :: proc(tool: LevelTool) -> bool {
	return tool != .Select
}

// Draws the overlay's grid (under the entities)
LevelOverlay_DrawGrid :: proc(r: ^skald.Renderer, b: skald.Rect, o: ^LevelOverlay) {
	for g in o.grid do skald.draw_rect(r, {b.x + g[0], b.y + g[1], g[2], g[3]}, o.gridColor)
	for g in o.guide do skald.draw_rect(r, {b.x + g[0], b.y + g[1], g[2], g[3]}, o.guideColor)
}

// Draws the overlay's brush, handles and points (over the entities)
LevelOverlay_Draw :: proc(r: ^skald.Renderer, b: skald.Rect, o: ^LevelOverlay) {
	for img in o.images do skald.draw_image_region(r, img.name, {b.x + img.rect[0], b.y + img.rect[1], img.rect[2], img.rect[3]}, {0, 0, img.src.x, img.src.y}, tint = {1, 1, 1, img.alpha}, inset = false)
	for rc in o.rects {
		rect := skald.Rect{b.x + rc.rect[0], b.y + rc.rect[1], rc.rect[2], rc.rect[3]}
		if rc.fill.a > 0 do skald.draw_rect(r, rect, rc.fill)
		if rc.width > 0 do skald.draw_rect_outline(r, rect, rc.width, rc.outline)
	}
	for ln in o.lines do skald.draw_line(r, [2]f32{b.x, b.y} + ln.a, [2]f32{b.x, b.y} + ln.b, ln.width, ln.color, aa = true)
	for c in o.circles {
		p := [2]f32{b.x, b.y} + c.center
		if c.ring do skald.draw_ring(r, p, c.radius, 1.5, c.color)
		else do skald.draw_circle(r, p, c.radius, c.color, aa = true)
	}
}

// Draws the overlay's hint (on top, at the canvas's bottom)
LevelOverlay_DrawHint :: proc(r: ^skald.Renderer, b: skald.Rect, o: ^LevelOverlay) {
	if o.hint == "" do return
	w := f32(len(o.hint)) * o.fontSize * 0.55 + 16
	h := o.fontSize + 10
	x := b.x + max((b.w - w) * 0.5, 4)
	y := b.y + b.h - h - 8
	skald.draw_rect(r, {x, y, min(w, b.w - 8), h}, {o.hintBg.r, o.hintBg.g, o.hintBg.b, 0.85}, 4)
	skald.push_clip(r, {x, y, min(w, b.w - 8), h})
	drawTextTop(r, o.hint, x + 8, y + 5, o.hintColor, o.fontSize)
	skald.pop_clip(r)
}

/*
Draws an entity as LDtk's editor does (EntityRender): its tile (fit inside, stretched, covering,
at full size or repeated, at its tile opacity), else its shape (a rectangle, an ellipse, a cross)
filled and outlined at its definition's opacities (hollow: outlined only); its name above it when
the type shows it and it's big enough.
*/
LevelEntity_Draw :: proc(r: ^skald.Renderer, rect: skald.Rect, e: LevelCanvasEntity, fontSize, zoom: f32) {
	alpha := e.ghost ? f32(0.5) : 1
	c := e.color
	switch e.shape {
	case .Tile:
		tw, th := e.tileSrc[2] * zoom, e.tileSrc[3] * zoom
		dst := rect
		switch e.tileMode {
		case "Stretch", "NineSlice":
		case "Cover":
			s := max(rect.w / max(tw, 1), rect.h / max(th, 1))
			dst = {rect.x + (rect.w - tw * s) * 0.5, rect.y + (rect.h - th * s) * 0.5, tw * s, th * s}
		case "FullSizeCropped", "FullSizeUncropped":
			dst = {rect.x + (rect.w - tw) * 0.5, rect.y + (rect.h - th) * 0.5, tw, th}
		case:
			// FitInside (LDtk's default), Repeat drawn once
			s := min(rect.w / max(tw, 1), rect.h / max(th, 1))
			dst = {rect.x + (rect.w - tw * s) * 0.5, rect.y + (rect.h - th * s) * 0.5, tw * s, th * s}
		}
		skald.push_clip(r, e.tileMode == "Cover" || e.tileMode == "FullSizeCropped" ? rect : skald.Rect{rect.x - 1e5, rect.y - 1e5, 2e5, 2e5})
		if !skald.draw_image_region(r, e.tileImage, dst, {e.tileSrc[0], e.tileSrc[1], e.tileSrc[2], e.tileSrc[3]}, tint = {1, 1, 1, e.tileAlpha * alpha}) {
			skald.draw_rect_outline(r, rect, 1, {c.r, c.g, c.b, 0.8 * alpha})
		}
		skald.pop_clip(r)
	case .Rectangle:
		if !e.hollow do skald.draw_rect(r, rect, {c.r, c.g, c.b, e.fillAlpha * alpha})
		skald.draw_rect_outline(r, rect, 1, {c.r, c.g, c.b, e.lineAlpha * alpha})
	case .Ellipse:
		points := make([][2]f32, 32, context.temp_allocator)
		center := [2]f32{rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
		for &p, i in points {
			a := f32(i) / f32(len(points)) * math.TAU
			p = center + {math.cos(a) * rect.w * 0.5, math.sin(a) * rect.h * 0.5}
		}
		if !e.hollow do skald.draw_polygon(r, points, {c.r, c.g, c.b, e.fillAlpha * alpha}, aa = true)
		closed := make([][2]f32, len(points) + 1, context.temp_allocator)
		copy(closed, points)
		closed[len(points)] = points[0]
		skald.draw_polyline(r, closed, 1, {c.r, c.g, c.b, e.lineAlpha * alpha}, aa = true)
	case .Cross:
		line := skald.Color{c.r, c.g, c.b, e.lineAlpha * alpha}
		skald.draw_line(r, {rect.x, rect.y}, {rect.x + rect.w, rect.y + rect.h}, 2, line, aa = true)
		skald.draw_line(r, {rect.x + rect.w, rect.y}, {rect.x, rect.y + rect.h}, 2, line, aa = true)
	}
	if LevelEntity_NameShown(e, rect, zoom) {
		// Centered over it, its first 16 characters (EntityRender: `ed.identifier.substr(0,16)`)
		name := e.identifier[:min(len(e.identifier), 16)]
		w, _ := skald.measure_text(r, name, fontSize)
		drawTextTop(r, name, rect.x + rect.w * 0.5 - w * 0.5, rect.y - fontSize - 2, {1, 1, 1, 0.85 * alpha}, fontSize)
	}
}

// Whether an entity's name shows over it: its type shows it, its layer doesn't hide it, and it's big enough
LevelEntity_NameShown :: proc(e: LevelCanvasEntity, rect: skald.Rect, zoom: f32) -> bool {
	return e.showName && !e.nameHidden && rect.h >= 6 && zoom >= 0.5
}

/*
The Auto-layer Rules tab's marks on the focused level (EditAllAutoLayerRules.showAffectedCells: a
cell outlined in magenta over purple where the hovered rule, or each rule of the hovered group, put
a tile; RulePerlinSettings' preview: red where the Perlin noise stops the rule, green where it
lets it), and the cell under the pointer reported to the tab (onEditorMouseMove).
*/
@(private="file")
levelRulesOverlay :: proc(o: ^LevelOverlay, s: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel, world: [4]f32, hover: Maybe([2]f32), center: [2]f32, zoom: f32, size: [2]f32) {
	layerUid, layer := LevelRules_Layer(s, doc)
	l := LevelPaint_LayerByDef(m, layerUid)
	if l == nil || layer < 0 {
		LevelRules_SetCanvasCell(-1, {}, false)
		return
	}
	d := &m.defs[l.def]
	grid := f32(d.gridSize)
	off := LDtkLayer_Offset(m, l)
	at :: proc(world: [4]f32, p, center: [2]f32, zoom: f32, size: [2]f32) -> [2]f32 {
		return size * 0.5 + (world.xy + p - center) * zoom
	}
	// The cell under the pointer
	cellOk := false
	cell: [2]int
	if p, ok := hover.?; ok {
		lp := p - world.xy
		if lp.x >= 0 && lp.y >= 0 && lp.x < world[2] && lp.y < world[3] {
			cell = LDtkLayer_CellAt(m, l, lp)
			cellOk = cell.x >= 0 && cell.y >= 0 && cell.x < l.cWid && cell.y < l.cHei
		}
	}
	LevelRules_SetCanvasCell(layerUid, cell, cellOk)
	// The hovered rule's or group's cells (not while auto-layers are hidden: LDtk's)
	_, rule, group := LevelRules_Hovered()
	if !s.level.paint.hideAutoLayers && (rule >= 0 || group >= 0) && len(l.auto) > 0 {
		wanted := make(map[i32]bool, context.temp_allocator)
		if rule >= 0 do wanted[i32(rule)] = true
		if group >= 0 do for g in LDtkRules_ReadGroups(LDtkDoc_Main(doc), layer) do if g.uid == group do for r in g.rules do wanted[i32(r.uid)] = true
		fill := skald.rgb(0x5A36A7)
		fill.a = 0.6
		line := skald.rgb(0xFF00FF)
		for tiles in l.auto do for t in tiles {
			if t.rule not_in wanted do continue
			p := at(world, {f32(t.x) + f32(off.x), f32(t.y) + f32(off.y)}, center, zoom, size)
			if p.x > size.x || p.y > size.y || p.x + grid * zoom < 0 || p.y + grid * zoom < 0 do continue
			append(&o.rects, LevelOverlayRect{{p.x, p.y, grid * zoom, grid * zoom}, fill, line, 1})
		}
	}
	// The edited rule's Perlin noise over the layer
	if s.level.rules.page == .Editor && s.level.rules.perlinPreview {
		r, _, ok := LevelRules_Rule(doc, layer, s.level.rules.rule)
		if ok && r.perlinActive {
			red, green := skald.Color{1, 0, 0, 0.5}, skald.rgb(0xB3F700)
			green.a = 0.3
			for cy in 0 ..< l.cHei do for cx in 0 ..< l.cWid {
				p := at(world, {f32(cx) * grid + f32(off.x), f32(cy) * grid + f32(off.y)}, center, zoom, size)
				if p.x > size.x || p.y > size.y || p.x + grid * zoom < 0 || p.y + grid * zoom < 0 do continue
				v := ldtkPerlin(l.seed + r.perlinSeed, f64(cx) * r.perlinScale, f64(cy) * r.perlinScale, r.perlinOctaves)
				append(&o.rects, LevelOverlayRect{{p.x, p.y, grid * zoom, grid * zoom}, v < 0 ? red : green, {}, 0})
			}
		}
	}
	levelRulesMarks = 0
	for rc in o.rects do if rc.width == 1 do levelRulesMarks += 1
}

// How many cells the rules tab's hover outlined last (the UI test driver's `rules marks`)
@(thread_local)
levelRulesMarks: int

// The cells outlined for the rules tab's hover, as last drawn
LevelRules_Marks :: proc() -> int {
	return levelRulesMarks
}
