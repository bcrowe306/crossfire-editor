package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The Tiles panel (the bottom panel's Tiles tab): painting the selected TileMap (tile_paint.odin).
A toolbar on top, the tileset's tiles below:

	+---------------------------------------------------------------------------------+
	| Layer [Ground v] + Layer  Use the File's Tiles   [Paint][Erase][Rect][Fill][Pick] |
	| [Terrain] [grass v]   Flip X  Flip Y  Rotate     brush: tile 3, flipped across    |
	+---------------------------------------------------------------------------------+
	| [1][2][3][4][5][6] ... every tile of the layer's tileset; a click picks the brush  |
	+---------------------------------------------------------------------------------+

While it shows, the viewport paints the selected TileMap: left button with the tool, right
button erases, middle (or Space) pans.

Widget keys: `tiles-layer`, `tiles-add-layer`, `tiles-tileset`, `tiles-revert`,
`tiles-tool-<Tool>` (Paint, Erase, Rectangle, Fill, Pick, Terrain), `tiles-terrain`,
`tiles-flip-x`, `tiles-flip-y`, `tiles-rotate`, `tiles-palette` (the tiles).
*/

@(private="file")
TILE_THUMB :: 36
@(private="file")
TILE_GAP :: 4

TilesPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	node, ase := TilePaint_Node(s)
	if node == nil {
		text := "Select a TileMap node to paint its tiles: its Aseprite file's tilesets are the palette."
		return skald.col(uiText(th, .Label, text, max_width = tk.textWide), padding = th.spacing.md)
	}
	p := &s.tilePainter
	layer := TilePaint_Layer(s, node, ase)
	tileset, tilesetIndex := TilePaint_Tileset(node, ase, layer)
	small :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View { return uiText(ctx.theme, .Muted, text) }
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg, on := false) -> skald.View {
		tk := uiTokens(ctx)
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = on ? th.color.primary : th.color.bg, fg = on ? th.color.on_primary : th.color.fg,
			padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	toolbar := make([dynamic]skald.View, context.temp_allocator)
	// The layer painted, a new one, and back to the file's tiles
	layers := TilePaint_Layers(node, ase)
	append(&toolbar, skald.row(small(ctx, "Layer"), skald.select(ctx, layer, layers, proc(v: string) -> Msg { return Tile_Layer_Chosen(v) },
		id = skald.hash_id("tiles-layer"), width = tk.fieldM), spacing = th.spacing.xs, cross_align = .Center))
	if len(ase.tilesets) > 1 {
		names := make([]string, len(ase.tilesets), context.temp_allocator)
		for t, i in ase.tilesets do names[i] = t.name != "" ? fmt.tprintf("%d %s", i, t.name) : fmt.tprintf("Tileset %d", i)
		Choices :: struct { names: []string }
		append(&toolbar, skald.row(small(ctx, "New layers on"), skald.select(ctx, names[clamp(p.tileset, 0, len(names) - 1)], names, Choices{names},
			proc(c: Choices, v: string) -> Msg {
				for n, i in c.names do if n == v do return Tile_Tileset_Chosen(i)
				return {}
			}, id = skald.hash_id("tiles-tileset"), width = tk.fieldS), spacing = th.spacing.xs, cross_align = .Center))
	}
	append(&toolbar, button(ctx, "tiles-add-layer", fmt.tprintf("%s  Layer", ACTION_ICONS[.Add]), Msg(Tile_Layer_Added{})))
	isFileLayer := false
	if i := e.Aseprite_FindLayer(ase, layer); i >= 0 && ase.layers[i].type == .Tilemap do isFileLayer = true
	painted := false
	for q in node.tilemap.painted do if q.layer == layer do painted = true
	if isFileLayer && painted do append(&toolbar, button(ctx, "tiles-revert", "Use the File's Tiles", Msg(Tile_Layer_Reverted{})))
	// The tools: each its own toolbar item, so they wrap in a narrow panel (a row of them ran
	// under the scrollbar)
	labels := [TilePaintTool]string{.Paint = "Paint", .Erase = "Erase", .Rectangle = "Rectangle", .Fill = "Fill", .Pick = "Pick", .Terrain = "Terrain"}
	terrains := tileset != nil ? e.Tileset_Terrains(tileset, context.temp_allocator) : nil
	for tool in TilePaintTool {
		if tool == .Terrain && len(terrains) == 0 do continue
		append(&toolbar, button(ctx, fmt.tprintf("tiles-tool-%v", tool), labels[tool], Msg(Tile_Tool_Chosen(tool)), p.tool == tool))
	}
	if len(terrains) > 0 {
		current := p.terrain
		known := false
		for t in terrains do if t == current do known = true
		if !known do current = terrains[0]
		append(&toolbar, skald.row(small(ctx, "Terrain"), skald.select(ctx, current, terrains, proc(v: string) -> Msg { return Tile_Terrain_Chosen(v) },
			id = skald.hash_id("tiles-terrain"), width = tk.fieldS), spacing = th.spacing.xs, cross_align = .Center))
	}
	// The brush's flips
	flips := p.tile & ~e.ASEPRITE_TILE_ID
	append(&toolbar,
		button(ctx, "tiles-flip-x", "Flip X", Msg(Tile_Brush_Turned(0)), flips & e.ASEPRITE_TILE_FLIP_X != 0),
		button(ctx, "tiles-flip-y", "Flip Y", Msg(Tile_Brush_Turned(1)), flips & e.ASEPRITE_TILE_FLIP_Y != 0),
		button(ctx, "tiles-rotate", "Rotate", Msg(Tile_Brush_Turned(2)), flips & e.ASEPRITE_TILE_FLIP_D != 0))
	append(&toolbar, small(ctx, brushText(p.tile)))
	append(&toolbar, button(ctx, "tiles-manual", fmt.tprintf("%s  Manual", ACTION_ICONS[.Manual]), Msg(Manual_Opened("tilemaps"))))

	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.sm * 2 - INSPECTOR_SCROLLBAR_WIDTH
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.wrap_row(..toolbar[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width, bg = th.color.surface))
	append(&rows, skald.divider(ctx))
	if tileset == nil {
		append(&rows, uiText(th, .Value, fmt.tprintf("%s has no tileset.", layer), color = th.color.warning))
	} else {
		append(&rows, palette(ctx, s, node, tileset, tilesetIndex, max(width - th.spacing.sm * 2, TILE_THUMB)))
		append(&rows, small(ctx, "In the viewport: left button paints with the tool, right erases, middle (or Space) pans. Tiles with terrain and mask properties in Aseprite paint as terrains."))
	}
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, width = width, padding = th.spacing.sm), id = skald.hash_id("tiles-scroll"))
}

// "tile 3, flipped across, turned a quarter"
@(private="file")
brushText :: proc(tile: u32) -> string {
	id := tile & e.ASEPRITE_TILE_ID
	if id == 0 do return "Brush: pick a tile below"
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, fmt.tprintf("Brush: tile %d", id))
	if tile & e.ASEPRITE_TILE_FLIP_X != 0 do append(&parts, "flip X")
	if tile & e.ASEPRITE_TILE_FLIP_Y != 0 do append(&parts, "flip Y")
	if tile & e.ASEPRITE_TILE_FLIP_D != 0 do append(&parts, "diagonal")
	return strings.join(parts[:], ", ", context.temp_allocator)
}

// The tileset's tiles as thumbnails (the selected one outlined); a click picks it for the brush
@(private="file")
palette :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, tileset: ^e.AsepriteTileset, index: int, width: f32) -> skald.View {
	th := ctx.theme
	id := skald.hash_id("tiles-palette")
	perRow := max(int((width + TILE_GAP) / (TILE_THUMB + TILE_GAP)), 1)
	count := max(tileset.count - 1, 0)
	height := f32((count + perRow - 1) / perRow) * (TILE_THUMB + TILE_GAP)
	tilePaletteColumns = perRow
	// The mouse, from last frame's rect (like the Animation panel's frames)
	if state, drawn := ctx.widgets.states[id]; drawn && state.last_rect.w > 0 && ctx.input.mouse_pressed[.Left] {
		rect := state.last_rect
		mouse := ctx.input.mouse_pos
		visible := state.clip_rect.w > 0 ? state.clip_rect : rect
		inside :: proc(r: skald.Rect, p: [2]f32) -> bool { return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h }
		if inside(rect, mouse) && inside(visible, mouse) && len(ctx.widgets.overlay_rects_prev) == 0 {
			column := int((mouse.x - rect.x) / (TILE_THUMB + TILE_GAP))
			row := int((mouse.y - rect.y) / (TILE_THUMB + TILE_GAP))
			tile := row * perRow + column + 1
			if column < perRow && tile < tileset.count do skald.send(ctx, Msg(Tile_Brush_Chosen(u32(tile))))
		}
	}
	image := tilesetImage(ctx, s, node.tilemap.file, tileset, index)
	Palette :: struct {
		image: string,
		tileSize: [2]f32,
		count, perRow, selected: int,
		edge, lit, bg: skald.Color,
	}
	data := new_clone(Palette{image, {f32(tileset.tileWidth), f32(tileset.tileHeight)}, count, perRow, int(s.tilePainter.tile & e.ASEPRITE_TILE_ID),
		th.color.border, th.color.primary, th.color.surface}, context.temp_allocator)
	return skald.canvas(ctx, data, proc(d: ^Palette, p: skald.Canvas_Painter) {
		for i in 0..<d.count {
			tile := i + 1
			x := p.bounds.x + f32(i % d.perRow) * (TILE_THUMB + TILE_GAP)
			y := p.bounds.y + f32(i / d.perRow) * (TILE_THUMB + TILE_GAP)
			box := skald.Rect{x, y, TILE_THUMB, TILE_THUMB}
			skald.draw_rect(p.r, box, d.bg, 3)
			if d.image != "" {
				scale := min((TILE_THUMB - 4) / d.tileSize.x, (TILE_THUMB - 4) / d.tileSize.y)
				size := d.tileSize * scale
				shown := skald.Rect{x + (TILE_THUMB - size.x) * 0.5, y + (TILE_THUMB - size.y) * 0.5, size.x, size.y}
				skald.draw_image_region(p.r, d.image, shown, {0.5, f32(tile) * d.tileSize.y + 0.5, d.tileSize.x - 1, d.tileSize.y - 1}, {1, 1, 1, 1})
			}
			color, width := tile == d.selected ? d.lit : d.edge, tile == d.selected ? f32(2) : f32(1)
			skald.draw_rect(p.r, {box.x, box.y, box.w, width}, color)
			skald.draw_rect(p.r, {box.x, box.y + box.h - width, box.w, width}, color)
			skald.draw_rect(p.r, {box.x, box.y, width, box.h}, color)
			skald.draw_rect(p.r, {box.x + box.w - width, box.y, width, box.h}, color)
		}
	}, id = id, width = width, height = max(height, TILE_THUMB), cursor = .Pointer)
}

// Thumbnails per row in the last palette drawn (the UI tests click a tile by its place)
@(private="file")
tilePaletteColumns := 1

// The center of tile `tile`'s thumbnail, from the palette's top left (the UI tests click it)
TilesPanel_TileCenter :: proc(tile: int) -> [2]f32 {
	i := max(tile - 1, 0)
	return {f32(i % tilePaletteColumns) * (TILE_THUMB + TILE_GAP) + TILE_THUMB * 0.5, f32(i / tilePaletteColumns) * (TILE_THUMB + TILE_GAP) + TILE_THUMB * 0.5}
}

// Uploaded tileset images, by file, tileset and the file's time (saved again: uploaded again)
@(private="file")
tilesetImages: map[string]bool

// A tileset's tiles as a Skald image (uploaded the first time), or "" when it can't be
@(private="file")
tilesetImage :: proc(ctx: ^skald.Ctx(Msg), s: ^State, file: string, tileset: ^e.AsepriteTileset, index: int) -> string {
	if ctx.renderer == nil || tileset.pixels == nil do return ""
	full := joinPath(s.project.rootPath, file, allocator = context.temp_allocator)
	name := fmt.tprintf("tileset:%s#%d@%v", full, index, ldtkModified(full))
	if name in tilesetImages do return name
	if !skald.image_load_pixels(ctx.renderer, name, u32(tileset.tileWidth), u32(tileset.tileHeight * tileset.count), tileset.pixels) do return ""
	tilesetImages[strings.clone(name)] = true
	return name
}
