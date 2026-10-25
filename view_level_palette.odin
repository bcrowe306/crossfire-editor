package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "gui:skald"

/*
The Level mode's palette (LDtk's tool palettes: ui/palette/IntGridPalette, TilePalette,
EntityPalette): under the Layers sidebar's rows, what the selected layer paints with.

- **IntGrid:** a row per value (its color, name and number); the picked one is what Pencil,
  Rectangle and Fill paint (`Level_Value_Picked`). Keys `level-value-<value>`.
- **Tiles:** the layer's tileset, fitted to the sidebar's width (Ctrl + wheel zooms, the wheel
  scrolls), its picked tiles outlined. A click picks a tile, a drag a rectangle of them (a
  stamp); Shift or Ctrl + drag adds to the selection, the right button removes from it, Ctrl +
  click on a picked tile removes it (LDtk's Tileset.modifySelection). Above it: Stamp / Random
  (R), flip X (X) and Y (Y), tile stacking (Shift+T). Keys `level-palette-tiles` (the canvas),
  `level-palette-random`, `level-palette-flip-x`, `level-palette-flip-y`, `level-palette-stacking`.
- **Entities:** a row per entity type the layer takes (its color, name, size); the picked one is
  what Place puts (`Level_Entity_Type_Picked`). Keys `level-entity-type-<uid>`.
- **AutoLayer:** its tiles come from its rules (the Auto-layer Rules tab).
*/

// The tile palette's view per tileset: its zoom (0: fitted to the width) and the drag selecting
@(private="file")
TilePaletteView :: struct {
	zoom: f32,
	// A selection drag: its first tile cell, the button (right removes), the modifiers at the press
	dragging: bool,
	start: [2]int,
	right, add, ctrl: bool,
}

@(private="file", thread_local)
tilePalettes: map[int]TilePaletteView

// Frees the palette's view state (tests, quitting)
LevelPalette_Destroy :: proc() {
	delete(tilePalettes)
	tilePalettes = nil
}

// The palette of the selected layer (nil when there's nothing to show)
LevelPalette_View :: proc(s: ^State, ctx: ^skald.Ctx(Msg), doc: ^LDtkDoc, textWidth: f32) -> (skald.View, bool) {
	tk := uiTokens(ctx)
	th := ctx.theme
	main := LDtkDoc_Main(doc)
	def := LevelMode_LayerDef(s, doc)
	if def < 0 do return {}, false
	uid := Json_Int(main, Json_Get(main, def, "uid"), -1)
	layerType := Json_String(main, Json_Get(main, def, "__type"))
	rows := make([dynamic]skald.View, context.temp_allocator)
	// The editor's panel header (`panelHeader`), what it paints with in its title
	header := skald.col(panelHeader(ctx, ICON_PALETTE, s.level.focus == "" ? "Palette (double-click a level to paint)" : fmt.tprintf("Palette: %s", Json_String(main, Json_Get(main, def, "identifier")))),
		skald.divider(ctx), cross_align = .Stretch)
	switch layerType {
	case "IntGrid":
		picked := -1
		if v, found := s.level.paint.values[uid]; found do picked = v
		values := Json_Items(main, Json_Get(main, def, "intGridValues"))
		if picked < 0 && len(values) > 0 do picked = Json_Int(main, Json_Get(main, values[0], "value"))
		for v in values {
			value := Json_Int(main, Json_Get(main, v, "value"))
			name := Json_String(main, Json_Get(main, v, "identifier"))
			c, _ := LDtk_ParseColor(Json_String(main, Json_Get(main, v, "color")))
			label := name != "" ? fmt.tprintf("%s (%d)", name, value) : fmt.tprintf("%d", value)
			// A tree row (the scene tree's look), the value's color as its icon
			row := ColoredTreeRow{label = label, icon = ICON_SQUARE_FULL, iconColor = skald.rgb(u32(c)), selected = value == picked}
			append(&rows, paletteRow(ctx, s, fmt.tprintf("level-value-%d", value), row, Msg(Level_Value_Picked{uid, value})))
		}
		if len(values) == 0 do append(&rows, skald.col(uiText(th, .Muted, "No values: add them in the Layers tab.", max_width = textWidth + tk.fieldXS), padding = th.spacing.sm))
		list := skald.scroll(ctx, {0, 0}, skald.col(..rows[:], cross_align = .Stretch), id = skald.hash_id("level-palette-scroll"))
		return skald.col(header, skald.flex(1, list), cross_align = .Stretch), true
	case "Tiles":
		tileset := jsonUidOr(main, Json_Get(main, def, "tilesetDefUid"))
		// The level's instance may use another tileset
		if level := LDtkDoc_FindLevel(doc, s.level.focus != "" ? s.level.focus : s.level.level); level >= 0 {
			file, array := LDtkDoc_LayerInstances(doc, level)
			json := LDtkDoc_Json(doc, file)
			for li in Json_Items(json, array) do if Json_Int(json, Json_Get(json, li, "layerDefUid"), -1) == uid {
				if o := jsonUidOr(json, Json_Get(json, li, "overrideTilesetUid")); o >= 0 do tileset = o
			}
		}
		td := LDtkDoc_DefByUid(doc, "tilesets", tileset)
		if td < 0 {
			return skald.col(header, skald.col(uiText(th, .Muted, "This layer has no tileset: pick one in LDtk's Layers panel.", max_width = textWidth + tk.fieldXS), padding = th.spacing.sm), cross_align = .Stretch), true
		}
		paint := &s.level.paint
		toggle :: proc(ctx: ^skald.Ctx(Msg), key, label, tip: string, on: bool, msg: Msg) -> skald.View {
			// The editor's panel buttons (`panelToolButton`), pressed while on
			return panelToolButton(ctx, key, "", tip, msg, label = label, on = on)
		}
		options := skald.wrap_row(
			toggle(ctx, "level-palette-random", paint.random ? "Random" : "Stamp", actionTip(s, "Stamp (the picked tiles as they are) or random (one of them per cell)", .Level_Random_Mode), paint.random, Msg(Action.Level_Random_Mode)),
			toggle(ctx, "level-palette-flip-x", "Flip X", actionTip(s, "Flip the tiles on X", .Level_Flip_X), paint.flipX, Msg(Action.Level_Flip_X)),
			toggle(ctx, "level-palette-flip-y", "Flip Y", actionTip(s, "Flip the tiles on Y", .Level_Flip_Y), paint.flipY, Msg(Action.Level_Flip_Y)),
			toggle(ctx, "level-palette-stacking", "Stack", actionTip(s, "Tile stacking: a tile with transparent pixels goes over the cell's", .Level_Tile_Stacking), !paint.noStacking, Msg(Action.Level_Tile_Stacking)),
			toggle(ctx, "level-palette-save", "Save", actionTip(s, "Memorize the picked tiles: a click on one of them picks them all again (Ctrl + click: just that tile)", .Level_Save_Tile_Selection), false, Msg(Action.Level_Save_Tile_Selection)),
			spacing = th.spacing.xs, line_spacing = th.spacing.xs,
		)
		Data :: struct {
			s: ^State,
			doc: ^LDtkDoc,
			td: int,
		}
		data := new_clone(Data{s, doc, td}, context.temp_allocator)
		tiles := skald.sized(ctx, data, proc(ctx: ^skald.Ctx(Msg), d: ^Data, size: [2]f32) -> skald.View {
			return tilePaletteView(ctx, d.s, d.doc, d.td, size)
		})
		return skald.col(header, skald.col(options, padding = th.spacing.xs), skald.flex(1, tiles), cross_align = .Stretch), true
	case "Entities":
		picked := s.level.paint.entityDef
		if picked < 0 || LDtkDoc_DefByUid(doc, "entities", picked) < 0 do picked = LevelPaint_FirstAllowed(doc, def, main)
		for ed in Json_Items(main, LDtkDoc_Defs(doc, "entities")) {
			if !LevelPaint_LayerTakes(main, def, ed) do continue
			edUid := Json_Int(main, Json_Get(main, ed, "uid"), -1)
			c, _ := LDtk_ParseColor(Json_String(main, Json_Get(main, ed, "color")))
			row := ColoredTreeRow{label = fmt.tprintf("%s  %dx%d", Json_String(main, Json_Get(main, ed, "identifier")), Json_Int(main, Json_Get(main, ed, "width")), Json_Int(main, Json_Get(main, ed, "height"))),
				icon = ICON_SQUARE_FULL, iconColor = skald.rgb(u32(c)), selected = edUid == picked}
			append(&rows, paletteRow(ctx, s, fmt.tprintf("level-entity-type-%d", edUid), row, Msg(Level_Entity_Type_Picked(edUid))))
		}
		if len(rows) == 0 do append(&rows, skald.col(uiText(th, .Muted, "No entity type this layer takes: add one in the Entities tab.", max_width = textWidth + tk.fieldXS), padding = th.spacing.sm))
		list := skald.scroll(ctx, {0, 0}, skald.col(..rows[:], cross_align = .Stretch), id = skald.hash_id("level-palette-scroll"))
		return skald.col(header, skald.flex(1, list), cross_align = .Stretch), true
	case "AutoLayer":
		return skald.col(header, skald.col(uiText(th, .Muted, "An auto-layer's tiles come from its rules (the Auto-layer Rules tab): paint its IntGrid source layer.", max_width = textWidth + tk.fieldXS), padding = th.spacing.sm), cross_align = .Stretch), true
	}
	return {}, false
}

// A uid that may be null (-1)
@(private="file")
jsonUidOr :: proc(json: ^JsonDoc, node: int) -> int {
	return Json_Kind(json, node) == .Number ? Json_Int(json, node) : -1
}

// A palette row, a tree row (`Tree_RowView`: the editor's lists' look): a click picks it
@(private="file")
paletteRow :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: string, row: ColoredTreeRow, msg: Msg) -> skald.View {
	id := skald.hash_id(key)
	if skald.widget_hovered(ctx, id) && !skald.mouse_over_overlay(ctx) {
		skald.cursor_request(ctx, .Pointer)
		if ctx.input.mouse_pressed[.Left] do skald.send(ctx, msg)
	}
	child := new(skald.View, context.temp_allocator)
	child^ = Tree_RowView(ctx.theme, row, s.settings.rowHeight, true, false)
	return skald.View_Zone{id = id, child = child}
}

// The saved selections' tiles (temp)
@(private="file")
savedIds :: proc(saved: []$T) -> [][]int {
	out := make([][]int, len(saved), context.temp_allocator)
	for sel, i in saved do out[i] = sel.ids
	return out
}

// The tile palette: the tileset at its zoom, the picked tiles, the drag selecting
@(private="file")
tilePaletteView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, doc: ^LDtkDoc, td: int, size: [2]f32) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	main := LDtkDoc_Main(doc)
	uid := Json_Int(main, Json_Get(main, td, "uid"), -1)
	path := joinPath(LDtkDoc_Folder(doc), Json_String(main, Json_Get(main, td, "relPath")), allocator = context.temp_allocator)
	pxW, pxH := f32(Json_Int(main, Json_Get(main, td, "pxWid"))), f32(Json_Int(main, Json_Get(main, td, "pxHei")))
	gridSize := f32(max(Json_Int(main, Json_Get(main, td, "tileGridSize"), 16), 1))
	spacing := f32(Json_Int(main, Json_Get(main, td, "spacing")))
	padding := f32(Json_Int(main, Json_Get(main, td, "padding")))
	cWid := max(Json_Int(main, Json_Get(main, td, "__cWid"), int((pxW - padding * 2 + spacing) / (gridSize + spacing))), 1)
	cHei := max(Json_Int(main, Json_Get(main, td, "__cHei"), int((pxH - padding * 2 + spacing) / (gridSize + spacing))), 1)
	view, has := &tilePalettes[uid]
	if !has {
		tilePalettes[uid] = {}
		view = &tilePalettes[uid]
	}
	fit := max(size.x - 14, 32) / max(pxW, 1)
	zoom := view.zoom > 0 ? view.zoom : fit
	id := skald.hash_id("level-palette-tiles")
	scrollId := skald.hash_id("level-palette-tiles-scroll")
	// The tile cell under the pointer (from the canvas's last rect, inside the scroll's clip)
	cellAt :: proc(ctx: ^skald.Ctx(Msg), id: skald.Widget_ID, zoom, gridSize, spacing, padding: f32, cWid, cHei: int) -> ([2]int, bool) {
		st, ok := ctx.widgets.states[id]
		if !ok do return {}, false
		r := st.last_rect
		local := (ctx.input.mouse_pos - {r.x, r.y}) / zoom
		cx := int(math.floor((local.x - padding) / (gridSize + spacing)))
		cy := int(math.floor((local.y - padding) / (gridSize + spacing)))
		return {clamp(cx, 0, cWid - 1), clamp(cy, 0, cHei - 1)}, true
	}
	hovered := skald.widget_hovered(ctx, id) && !skald.mouse_over_overlay(ctx) && !Overlay_PopupOpen(ctx)
	if st, ok := ctx.widgets.states[id]; ok && st.clip_rect.w > 0 {
		m := ctx.input.mouse_pos
		c := st.clip_rect
		if m.x < c.x || m.y < c.y || m.x >= c.x + c.w || m.y >= c.y + c.h do hovered = false
	}
	picked := s.level.paint.tiles[uid]
	// The tileset's saved selections (TilesetDef.savedSelections): their tiles and modes
	Saved :: struct {
		ids: []int,
		random: bool,
	}
	saved := make([dynamic]Saved, context.temp_allocator)
	for sel in Json_Items(main, Json_Get(main, td, "savedSelections")) {
		ids := make([dynamic]int, context.temp_allocator)
		for v in Json_Items(main, Json_Get(main, sel, "ids")) do append(&ids, Json_Int(main, v))
		append(&saved, Saved{ids[:], Json_String(main, Json_Get(main, sel, "mode")) == "Random"})
	}
	ctrl := skald.PRIMARY_MODIFIER in ctx.input.modifiers
	shift := .Shift in ctx.input.modifiers
	if hovered && ctx.input.scroll.y != 0 && ctrl {
		// Ctrl + wheel zooms (the wheel alone scrolls)
		view.zoom = clamp(zoom * (ctx.input.scroll.y > 0 ? 1.25 : 0.8), 0.25, 8)
		ctx.input.scroll = {}
	}
	if hovered && (ctx.input.mouse_pressed[.Left] || ctx.input.mouse_pressed[.Right]) && !view.dragging {
		if c, ok := cellAt(ctx, id, zoom, gridSize, spacing, padding, cWid, cHei); ok {
			view^ = {zoom = view.zoom, dragging = true, start = c, right = !ctx.input.mouse_pressed[.Left], add = shift || ctrl, ctrl = ctrl}
		}
	}
	selection: [4]int
	if view.dragging {
		c, _ := cellAt(ctx, id, zoom, gridSize, spacing, padding, cWid, cHei)
		selection = {min(view.start.x, c.x), min(view.start.y, c.y), max(view.start.x, c.x), max(view.start.y, c.y)}
		if !ctx.input.mouse_buttons[.Left] && !ctx.input.mouse_buttons[.Right] {
			// LDtk's Tileset.modifySelection: replace, add (Shift / Ctrl), remove (the right button,
			// or Ctrl + click on a picked tile; at least one stays)
			ids := make([dynamic]int, context.temp_allocator)
			for cy in selection[1] ..= selection[3] do for cx in selection[0] ..= selection[2] do append(&ids, cx + cy * cWid)
			single := selection[0] == selection[2] && selection[1] == selection[3]
			isPicked := false
			for id in picked do if single && id == ids[0] do isPicked = true
			remove := view.right || (view.ctrl && isPicked)
			out := make([dynamic]int, context.temp_allocator)
			switch {
			case remove:
				for id in picked {
					gone := false
					for r in ids do if r == id do gone = true
					if !gone do append(&out, id)
				}
				if len(out) == 0 && len(picked) > 0 do append(&out, picked[0])
			case view.add:
				append(&out, ..picked[:])
				for id in ids {
					has := false
					for p in out do if p == id do has = true
					if !has do append(&out, id)
				}
			case:
				append(&out, ..ids[:])
			}
			// TileToolPicker.modifySelection: one tile of a saved selection picks it all (not with Ctrl)
			mode := 0
			if len(out) == 1 && !view.ctrl && !remove {
				for sel in saved do for id in sel.ids do if id == out[0] && mode == 0 {
					clear(&out)
					append(&out, ..sel.ids)
					mode = sel.random ? 2 : 1
				}
			}
			skald.send(ctx, Msg(Level_Tiles_Picked{uid, out[:], mode}))
			view.dragging = false
		} else {
			skald.send(ctx, Msg(Frame_Requested{}))
		}
	}
	Paint :: struct {
		image: string,
		size: [2]f32,
		zoom, grid, spacing, padding: f32,
		cWid: int,
		picked: []int,
		saved: [][]int,
		dragging: bool,
		selection: [4]int,
		accent, line: skald.Color,
	}
	p := new_clone(Paint{image = strings.clone(path, context.temp_allocator), size = {pxW, pxH}, zoom = zoom, grid = gridSize, spacing = spacing, padding = padding,
		cWid = cWid, picked = picked != nil ? picked[:] : nil, saved = savedIds(saved[:]), dragging = view.dragging, selection = selection, accent = th.color.primary, line = th.color.border}, context.temp_allocator)
	canvas := skald.canvas(ctx, p, proc(p: ^Paint, painter: skald.Canvas_Painter) {
		r := painter.r
		b := painter.bounds
		skald.draw_rect(r, b, {0.1, 0.1, 0.12, 1})
		skald.draw_image_region(r, p.image, {b.x, b.y, p.size.x * p.zoom, p.size.y * p.zoom}, {0, 0, p.size.x, p.size.y}, inset = false)
		cell :: proc(p: ^Paint, b: skald.Rect, cx, cy: int) -> skald.Rect {
			step := (p.grid + p.spacing) * p.zoom
			return {b.x + p.padding * p.zoom + f32(cx) * step, b.y + p.padding * p.zoom + f32(cy) * step, p.grid * p.zoom, p.grid * p.zoom}
		}
		// Saved selections: their tiles outlined faintly (a click on one picks them all)
		for sel in p.saved do for id in sel {
			c := cell(p, b, id % max(p.cWid, 1), id / max(p.cWid, 1))
			skald.draw_rect_outline(r, c, 1, {1, 1, 1, 0.35})
		}
		// The picked tiles: an outline that shows on any color (dark, then the accent inside)
		for id in p.picked {
			c := cell(p, b, id % max(p.cWid, 1), id / max(p.cWid, 1))
			skald.draw_rect(r, c, {p.accent.r, p.accent.g, p.accent.b, 0.3})
			skald.draw_rect_outline(r, {c.x - 1, c.y - 1, c.w + 2, c.h + 2}, 1, {0, 0, 0, 0.8})
			skald.draw_rect_outline(r, c, 2, p.accent)
		}
		if p.dragging {
			a := cell(p, b, p.selection[0], p.selection[1])
			z := cell(p, b, p.selection[2], p.selection[3])
			skald.draw_rect_outline(r, {a.x, a.y, z.x + z.w - a.x, z.y + z.h - a.y}, 2, {1, 1, 1, 0.9})
		}
	}, id = id, width = pxW * zoom, height = pxH * zoom, cursor = .Crosshair)
	return skald.scroll(ctx, {0, 0}, skald.col(canvas, padding = tk.xxs), id = scrollId)
}
