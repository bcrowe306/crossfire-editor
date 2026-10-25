package crossfire_editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
The sprite sheet slicer's tab (its logic and widget keys: slicer_edit.odin): the sheet on a canvas
to pan and zoom, its cells outlined and the picked ones numbered in their order, beside (or, in a
narrow center panel, under) a column of controls:

	+--------------------------------------+------------------------+
	| [tabs ...]                  Fit 100% |  hero.png 256 x 64     |
	|  +----+----+----+----+               |  Slice by  [Grid v]    |
	|  | 1  | 2  | 3  |    |   the sheet   |  Columns [4] Rows [2]  |
	|  +----+----+----+----+   (pan, zoom) |  Frames: 3 picked      |
	|  |    |    |    |    |               |  Animations: idle, run |
	|  +----+----+----+----+               |  name, FPS, loop, ...  |
	|                                      |  preview, frame strip  |
	|                                      |  Create / Apply / Add  |
	+--------------------------------------+------------------------+

The canvas: a click picks a cell, Ctrl+click adds or takes one away, Shift+click the run from the
last one clicked; the wheel zooms (Settings' wheel rule, as the viewport's), a middle or right
drag (or Space + drag) pans.
*/

// From this center panel width the controls are beside the canvas; narrower, under it
SLICER_SIDE_WIDTH :: f32(620)
// The controls' column beside the canvas
SLICER_PANEL_WIDTH :: f32(300)
// The preview and the frame strip's thumbnails
@(private="file")
SLICER_PREVIEW_SIZE :: 96
@(private="file")
SLICER_THUMB :: 40
@(private="file")
SLICER_THUMB_GAP :: 4

// A pan dragged on the canvas (view state: from the press to the release)
@(private="file")
slicerPanning: bool

// The center panel while a slicer tab shows: the tabs, the canvas and the controls
slicerCenterView :: proc(s: ^State, ctx: ^skald.Ctx(Msg), tab: ^SlicerTab) -> skald.View {
	th := ctx.theme
	// Code tabs aren't drawn: their queued input goes (as the scene view does)
	CodeEditor_DrainEvents()
	small :: proc(ctx: ^skald.Ctx(Msg), key, label, tip: string, msg: Msg) -> skald.View {
		th := ctx.theme
		button := skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg_muted,
			padding = {th.spacing.sm, 3}, font_size = th.font.size_sm, radius = th.radius.sm)
		return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("%s-tip", key)))
	}
	buttons := skald.row(
		small(ctx, "slicer-fit", ICON_SCALE, "Fit the sheet to the view", Msg(Slicer_Changed{op = .Fit, point = tab.canvas})),
		small(ctx, "slicer-zoom", fmt.tprintf("%.0f%%", tab.zoom * 100), "The zoom: click for 100%", Msg(Slicer_Changed{op = .Zoom, number = f64(1 / max(tab.zoom, 0.01)), point = tab.center})),
		small(ctx, "slicer-manual", fmt.tprintf("%s  Manual", ICON_CIRCLE_INFO), "The sprite sheet slicer's page of the manual", Msg(Manual_Opened("sprite_slicer"))),
		spacing = th.spacing.xs,
		cross_align = .Center,
	)
	header := centerHeader(s, ctx, buttons)
	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2
	Data :: struct {
		s: ^State,
		tab: ^SlicerTab,
		width: f32,
	}
	data := new_clone(Data{s, tab, width}, context.temp_allocator)
	body := skald.sized(ctx, data, proc(ctx: ^skald.Ctx(Msg), d: ^Data, size: [2]f32) -> skald.View {
		th := ctx.theme
		if d.width >= SLICER_SIDE_WIDTH {
			canvasSize := [2]f32{max(size.x - SLICER_PANEL_WIDTH - 1, 40), max(size.y, 40)}
			return skald.row(
				slicerCanvas(ctx, d.s, d.tab, canvasSize),
				skald.rect({1, size.y}, th.color.border),
				slicerControls(ctx, d.s, d.tab, SLICER_PANEL_WIDTH, size.y),
				spacing = 0,
			)
		}
		// Narrow: the canvas over the controls, which get the rest
		canvasHeight := clamp(size.y * 0.42, 100, max(size.y - 120, 100))
		return skald.col(
			slicerCanvas(ctx, d.s, d.tab, {max(size.x, 40), canvasHeight}),
			skald.rect({size.x, 1}, th.color.border),
			slicerControls(ctx, d.s, d.tab, size.x, max(size.y - canvasHeight - 1, 60)),
			spacing = 0,
		)
	})
	return skald.col(
		header,
		skald.flex(1, body),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

// The slicer's tabs for the center strip: the image's name, a × (a middle click closes too)
SlicerTabs_View :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> []skald.View {
	views := make([dynamic]skald.View, context.temp_allocator)
	for tab, i in s.slicer.tabs {
		label := fmt.tprintf("%s  %s", ICON_SCISSORS, filepath.base(tab.image))
		append(&views, editorTab(ctx, label, fmt.tprintf("Slicing %s", tab.image), s.slicer.shown == i + 1,
			Msg(Slicer_Tab_Selected(i)), Msg(Slicer_Tab_Closed(i)), fmt.tprintf("slicer-tab-%d", i), menu = Ctx_Slicer_Tab(i)))
	}
	return views[:]
}

// The sheet on a canvas: its input from the last rect, then the image, the cells, the picks
@(private="file")
slicerCanvas :: proc(ctx: ^skald.Ctx(Msg), s: ^State, tab: ^SlicerTab, size: [2]f32) -> skald.View {
	th := ctx.theme
	id := skald.hash_id("slicer-canvas")
	image := sheetImage(ctx, s, tab.image)
	sheet := image.size
	if sheet.x <= 0 do sheet = Slicer_SheetSize(s, tab)
	if size != tab.canvas do skald.send(ctx, Msg(Slicer_Changed{op = .Measured, point = size}))
	// Not fitted yet: fitted, and drawn fitted meanwhile
	center, zoom := tab.center, tab.zoom
	if zoom <= 0 && sheet.x > 0 {
		skald.send(ctx, Msg(Slicer_Changed{op = .Fit, point = size}))
		center = sheet / 2
		zoom = clamp(min(size.x / sheet.x, size.y / sheet.y) * 0.95, 0.02, 32)
	}
	if zoom <= 0 do zoom = 1
	toScreen :: proc(p, center: [2]f32, zoom: f32, size: [2]f32) -> [2]f32 { return size * 0.5 + (p - center) * zoom }
	settings := &tab.settings
	count := Slicer_CellCount(settings, sheet)

	// Input, from last frame's rect
	hovered := -1
	cursor := skald.Cursor_Shape.Crosshair
	if state, drawn := ctx.widgets.states[id]; drawn && state.last_rect.w > 0 {
		input := ctx.input
		local := input.mouse_pos - {state.last_rect.x, state.last_rect.y}
		point := center + (local - size * 0.5) / zoom
		inside := local.x >= 0 && local.y >= 0 && local.x < size.x && local.y < size.y
		free := len(ctx.widgets.overlay_rects_prev) == 0 && ctx.widgets.modal_rect_prev.w == 0 && !skald.mouse_over_overlay(ctx)
		if slicerPanning {
			if input.mouse_delta != {} do skald.send(ctx, Msg(Slicer_Changed{op = .Pan, point = input.mouse_delta}))
			if input.mouse_released[.Left] || input.mouse_released[.Middle] || input.mouse_released[.Right] do slicerPanning = false
			cursor = .Grabbing
		} else if inside && free {
			hovered = Slicer_CellAt(settings, sheet, point)
			if input.scroll != {} {
				wheelZoom, pan := wheelAction(input.scroll, input.modifiers, s.settings.wheelPans)
				if wheelZoom != 0 do skald.send(ctx, Msg(Slicer_Changed{op = .Zoom, number = f64(math.pow(f32(WHEEL_ZOOM_STEP), wheelZoom)), point = point}))
				if pan != {} do skald.send(ctx, Msg(Slicer_Changed{op = .Pan, point = pan}))
			}
			spaceHeld := .Space in input.keys_down && !IsTyping(ctx)
			if input.mouse_pressed[.Middle] || input.mouse_pressed[.Right] || (input.mouse_pressed[.Left] && spaceHeld) {
				slicerPanning = true
			} else if input.mouse_pressed[.Left] && hovered >= 0 {
				ctrl := skald.PRIMARY_MODIFIER in input.modifiers
				skald.send(ctx, Msg(Slicer_Changed{op = .Cell_Clicked, index = hovered, flag = .Shift in input.modifiers, number = ctrl ? 1 : 0}))
			}
			if hovered >= 0 do cursor = .Pointer
			if spaceHeld do cursor = .Grab
		}
	}

	// What it draws, in screen pixels (temp: the canvas draws after the view returns)
	Cell :: struct {
		rect: [4]f32,
		order: int,
	}
	Paint :: struct {
		image: string,
		sheet: [4]f32,
		cells: []Cell,
		picked: []Cell,
		frames: []Cell,
		hover: [4]f32,
		hasHover: bool,
		bg, check, line, accent, frame, fg, shade: skald.Color,
		font: f32,
		note: string,
	}
	paint := new(Paint, context.temp_allocator)
	topLeft := toScreen({0, 0}, center, zoom, size)
	paint.image = image.name
	paint.sheet = {topLeft.x, topLeft.y, sheet.x * zoom, sheet.y * zoom}
	visible :: proc(r: [4]f32, size: [2]f32) -> bool { return r[0] + r[2] >= 0 && r[1] + r[3] >= 0 && r[0] <= size.x && r[1] <= size.y }
	screenRect :: proc(r: sdl.FRect, center: [2]f32, zoom: f32, size: [2]f32) -> [4]f32 {
		p := size * 0.5 + ([2]f32{r.x, r.y} - center) * zoom
		return {p.x, p.y, r.w * zoom, r.h * zoom}
	}
	// The cells' outlines (only those in view, and only while they're big enough to see)
	cells := make([dynamic]Cell, context.temp_allocator)
	if settings.mode == .Grid && count > 0 {
		columns, rows, cell := e.SheetGrid_Layout(settings.grid, sheet)
		if cell.x * zoom >= 3 && cell.y * zoom >= 3 {
			step := cell + settings.grid.spacing
			origin := settings.grid.offset + settings.grid.margin
			// The columns and rows in view
			lo := ([2]f32{0, 0} - size * 0.5) / zoom + center - origin
			hi := (size - size * 0.5) / zoom + center - origin
			c0, c1 := max(int(math.floor(lo.x / step.x)), 0), min(int(hi.x / step.x) + 1, columns)
			r0, r1 := max(int(math.floor(lo.y / step.y)), 0), min(int(hi.y / step.y) + 1, rows)
			for row in r0 ..< r1 do for column in c0 ..< c1 {
				index := row * columns + column
				if index >= count do continue
				append(&cells, Cell{screenRect(Slicer_CellRect(settings, sheet, index), center, zoom, size), -1})
			}
		}
	} else {
		for r in settings.found {
			rect := screenRect(r, center, zoom, size)
			if visible(rect, size) do append(&cells, Cell{rect, -1})
		}
	}
	paint.cells = cells[:]
	// The picked cells, numbered in their order
	picked := make([dynamic]Cell, context.temp_allocator)
	for c, i in tab.selection {
		if c < 0 || c >= count do continue
		rect := screenRect(Slicer_CellRect(settings, sheet, c), center, zoom, size)
		if visible(rect, size) do append(&picked, Cell{rect, i + 1})
	}
	paint.picked = picked[:]
	// The shown animation's frames (outlined), its picked frame thicker
	frames := make([dynamic]Cell, context.temp_allocator)
	if a := Slicer_Animation(tab); a != nil {
		for c, i in a.frames {
			if c < 0 || c >= count do continue
			rect := screenRect(Slicer_CellRect(settings, sheet, c), center, zoom, size)
			if visible(rect, size) do append(&frames, Cell{rect, i == tab.frame ? 1 : 0})
		}
	}
	paint.frames = frames[:]
	if hovered >= 0 {
		paint.hover = screenRect(Slicer_CellRect(settings, sheet, hovered), center, zoom, size)
		paint.hasHover = true
	}
	paint.bg = th.color.bg
	paint.check = skald.color_mix(th.color.bg, th.color.fg, 0.08)
	paint.line = skald.color_mix(th.color.fg, th.color.primary, 0.4)
	paint.line.a = 0.55
	paint.accent = th.color.primary
	paint.frame = th.color.warning
	paint.fg = th.color.fg
	paint.shade = {0, 0, 0, 0.55}
	paint.font = th.font.size_xs
	switch {
	case tab.image == "" || sheet.x <= 0: paint.note = fmt.tprintf("%s can't be read", tab.image)
	case tab.detecting: paint.note = "Finding sprites…"
	case settings.mode == .Auto && len(settings.found) == 0: paint.note = "No sprites found yet: Find Sprites"
	}
	return skald.canvas(ctx, paint, proc(p: ^Paint, painter: skald.Canvas_Painter) {
		r := painter.r
		b := painter.bounds
		skald.push_clip(r, b)
		defer skald.pop_clip(r)
		skald.draw_rect(r, b, p.bg)
		at :: proc(b: skald.Rect, q: [4]f32) -> skald.Rect { return {b.x + q[0], b.y + q[1], q[2], q[3]} }
		sheet := at(b, p.sheet)
		// A checkerboard under the sheet (its transparent pixels), 8 screen pixels a square
		{
			x0, y0 := max(sheet.x, b.x), max(sheet.y, b.y)
			x1, y1 := min(sheet.x + sheet.w, b.x + b.w), min(sheet.y + sheet.h, b.y + b.h)
			for y := y0; y < y1; y += 8 do for x := x0; x < x1; x += 8 {
				if (int((x - sheet.x) / 8) + int((y - sheet.y) / 8)) % 2 == 0 do continue
				skald.draw_rect(r, {x, y, min(8, x1 - x), min(8, y1 - y)}, p.check)
			}
		}
		if p.image != "" do skald.draw_image_region(r, p.image, sheet, {0, 0, p.sheet[2], p.sheet[3]}, inset = false)
		ring :: proc(r: ^skald.Renderer, q: skald.Rect, color: skald.Color, w: f32) {
			skald.draw_rect(r, {q.x, q.y, q.w, w}, color)
			skald.draw_rect(r, {q.x, q.y + q.h - w, q.w, w}, color)
			skald.draw_rect(r, {q.x, q.y, w, q.h}, color)
			skald.draw_rect(r, {q.x + q.w - w, q.y, w, q.h}, color)
		}
		for c in p.cells do ring(r, at(b, c.rect), p.line, 1)
		fill := p.accent
		fill.a = 0.28
		for c in p.picked {
			q := at(b, c.rect)
			skald.draw_rect(r, q, fill)
			ring(r, q, p.accent, 2)
			if q.w >= 14 && q.h >= 12 {
				label := fmt.tprintf("%d", c.order)
				tw, _ := skald.measure_text(r, label, p.font)
				skald.draw_rect(r, {q.x + 2, q.y + 2, tw + 6, p.font + 4}, p.shade, 2)
				drawTextTop(r, label, q.x + 5, q.y + 4, p.fg, p.font)
			}
		}
		for c in p.frames do ring(r, at(b, c.rect), p.frame, c.order == 1 ? 3 : 1)
		if p.hasHover do ring(r, at(b, p.hover), p.fg, 1)
		if p.note != "" {
			tw, _ := skald.measure_text(r, p.note, p.font)
			skald.draw_rect(r, {b.x + 8, b.y + 8, tw + 12, p.font + 10}, p.shade, 3)
			drawTextTop(r, p.note, b.x + 14, b.y + 13, p.fg, p.font)
		}
	}, id = id, width = size.x, height = size.y, cursor = cursor)
}

// The controls' buttons: a little lighter than the panel (the theme's surface is its color)
@(private="file")
slicerButtonColor :: proc(th: ^skald.Theme) -> skald.Color {
	return skald.color_mix(th.color.surface, th.color.fg, 0.12)
}

// The controls' column: slicing, frames, animations, what it makes; one scroll
@(private="file")
slicerControls :: proc(ctx: ^skald.Ctx(Msg), s: ^State, tab: ^SlicerTab, width, height: f32) -> skald.View {
	th := ctx.theme
	inner := width - th.spacing.md * 2 - INSPECTOR_SCROLLBAR_WIDTH
	// Rows stack their labels in a narrow column (as the inspector's)
	controlWidth, stacked := Inspector_Layout(th, width)
	wasStacked := inspectorStacked
	inspectorStacked = stacked
	defer inspectorStacked = wasStacked
	numberWidth := min(controlWidth, INSPECTOR_MAX_NUMBER_WIDTH)
	selectWidth := min(controlWidth, 170)
	settings := &tab.settings
	sheet := Slicer_SheetSize(s, tab)
	count := Slicer_CellCount(settings, sheet)
	rows := make([dynamic]skald.View, context.temp_allocator)
	heading :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
		return skald.col(skald.spacer(ctx.theme.spacing.sm), skald.text(text, ctx.theme.color.fg, ctx.theme.font.size_sm))
	}
	note :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32, color := skald.Color{}) -> skald.View {
		c := color.a > 0 ? color : ctx.theme.color.fg_muted
		return skald.text(text, c, ctx.theme.font.size_xs, max_width = width)
	}
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg, disabled := false, primary := false) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = primary ? th.color.primary : slicerButtonColor(th),
			fg = primary ? th.color.on_primary : th.color.fg, padding = {th.spacing.sm, 3}, font_size = th.font.size_xs,
			radius = th.radius.sm, disabled = disabled)
	}
	number :: proc(ctx: ^skald.Ctx(Msg), s: ^State, field: SlicerNumber, value: f64, lo, hi: f64, width: f32) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("slicer-%v", field), field, value, 1, 0, width, lo, hi)
	}

	// The sheet
	append(&rows, skald.text(fmt.tprintf("%s  %s", ICON_SCISSORS, filepath.base(tab.image)), th.color.fg, th.font.size_sm, max_width = inner))
	append(&rows, note(ctx, fmt.tprintf("%.0f × %.0f px · %d cell%s", sheet.x, sheet.y, count, count == 1 ? "" : "s"), inner))

	// How it's cut
	append(&rows, heading(ctx, "Slice"))
	modeLabels := []string{"A grid", "Its sprites (auto-detect)"}
	append(&rows, inspectorRow(ctx, "Slice by", skald.select(ctx, modeLabels[settings.mode], modeLabels, proc(v: string) -> Msg {
		return Slicer_Changed{op = .Mode, text = v == "A grid" ? "Grid" : "Auto"}
	}, id = skald.hash_id("slicer-mode"), width = selectWidth)))
	switch settings.mode {
	case .Grid:
		g := settings.grid
		gridLabels := []string{"Cell count", "Cell size"}
		append(&rows, inspectorRow(ctx, "Grid by", skald.select(ctx, gridLabels[g.mode], gridLabels, proc(v: string) -> Msg {
			return Slicer_Changed{op = .Grid_Mode, text = v == "Cell count" ? "Cells" : "Size"}
		}, id = skald.hash_id("slicer-grid-mode"), width = selectWidth)))
		columns, gridRows, cell := e.SheetGrid_Layout(g, sheet)
		switch g.mode {
		case .Cells:
			append(&rows, inspectorRow(ctx, "Columns", number(ctx, s, .Columns, f64(max(g.columns, 1)), 1, 512, numberWidth)))
			append(&rows, inspectorRow(ctx, "Rows", number(ctx, s, .Rows, f64(max(g.rows, 1)), 1, 512, numberWidth)))
		case .Size:
			append(&rows, inspectorRow(ctx, "Cell width", number(ctx, s, .Cell_Width, f64(g.cellSize.x), 1, 4096, numberWidth)))
			append(&rows, inspectorRow(ctx, "Cell height", number(ctx, s, .Cell_Height, f64(g.cellSize.y), 1, 4096, numberWidth)))
		}
		append(&rows, inspectorRow(ctx, "Margin", number(ctx, s, .Margin, f64(g.margin), 0, 1000, numberWidth)))
		append(&rows, inspectorRow(ctx, "Cell gap", number(ctx, s, .Spacing, f64(g.spacing), 0, 1000, numberWidth)))
		append(&rows, inspectorRow(ctx, "Start X", number(ctx, s, .Offset_X, f64(g.offset.x), 0, 4096, numberWidth)))
		append(&rows, inspectorRow(ctx, "Start Y", number(ctx, s, .Offset_Y, f64(g.offset.y), 0, 4096, numberWidth)))
		derived := g.mode == .Cells ? fmt.tprintf("Cells of %.1f × %.1f px", cell.x, cell.y) : fmt.tprintf("%d × %d cells", columns, gridRows)
		append(&rows, note(ctx, derived, inner))
		if left := e.SheetGrid_Leftover(g, sheet); left.x >= 1 || left.y >= 1 {
			append(&rows, note(ctx, fmt.tprintf("Left over: %.0f px right, %.0f px below (not in any cell)", left.x, left.y), inner, th.color.warning))
		}
	case .Auto:
		append(&rows, inspectorRow(ctx, "Alpha at least", number(ctx, s, .Threshold, f64(settings.threshold), 1, 255, numberWidth)))
		append(&rows, inspectorRow(ctx, "Merge within", number(ctx, s, .Merge, f64(settings.merge), 0, 256, numberWidth)))
		append(&rows, inspectorRow(ctx, "Smallest", number(ctx, s, .Min_Size, f64(settings.minSize), 0, 4096, numberWidth)))
		append(&rows, inspectorRow(ctx, "Same size frames", skald.checkbox(ctx, settings.evenOut, "", proc(v: bool) -> Msg { return Slicer_Changed{op = .Even_Out, flag = v} },
			id = skald.hash_id("slicer-even"))))
		append(&rows, button(ctx, "slicer-detect", fmt.tprintf("%s  Find Sprites", ICON_WAND), Msg(Slicer_Changed{op = .Detect}), disabled = tab.detecting))
		if tab.detecting do append(&rows, note(ctx, "Finding sprites…", inner))
		else if tab.note != "" do append(&rows, note(ctx, tab.note, inner))
	}

	// Picking frames
	append(&rows, heading(ctx, "Frames"))
	append(&rows, note(ctx, fmt.tprintf("%d picked. Click a cell; Ctrl+click adds or takes away; Shift+click picks a run.", len(tab.selection)), inner))
	append(&rows, skald.wrap_row(
		button(ctx, "slicer-select-row", "Row", Msg(Slicer_Changed{op = .Select_Row}), disabled = count == 0),
		button(ctx, "slicer-select-all", "All", Msg(Slicer_Changed{op = .Select_All}), disabled = count == 0),
		button(ctx, "slicer-select-none", "None", Msg(Slicer_Changed{op = .Select_None}), disabled = len(tab.selection) == 0),
		button(ctx, "slicer-reverse", "Reverse", Msg(Slicer_Changed{op = .Reverse_Selection}), disabled = len(tab.selection) < 2),
		spacing = th.spacing.xs, line_spacing = th.spacing.xs, width = inner))

	// The animations
	append(&rows, heading(ctx, "Animations"))
	append(&rows, skald.wrap_row(
		button(ctx, "slicer-add", fmt.tprintf("%s  New from Picked", ICON_PLUS), Msg(Slicer_Changed{op = .Animation_Added}), disabled = len(tab.selection) == 0, primary = true),
		button(ctx, "slicer-rows", "One per Row", Msg(Slicer_Changed{op = .Rows_To_Animations}), disabled = count == 0),
		button(ctx, "slicer-set-frames", "Set Frames to Picked", Msg(Slicer_Changed{op = .Frames_Set}), disabled = len(tab.selection) == 0 || tab.animation < 0),
		spacing = th.spacing.xs, line_spacing = th.spacing.xs, width = inner))
	if len(settings.animations) == 0 {
		append(&rows, note(ctx, "None yet: pick frames on the sheet (a row: click its first, Shift+click its last), then New from Picked.", inner))
	}
	for a, i in settings.animations {
		shown := i == tab.animation
		label := fmt.tprintf("%s  ·  %d frame%s", a.name, len(a.frames), len(a.frames) == 1 ? "" : "s")
		append(&rows, skald.button(ctx, label, Msg(Slicer_Changed{op = .Animation_Selected, index = i}), id = skald.hash_id(fmt.tprintf("slicer-anim-%d", i)),
			bg = shown ? skald.color_mix(th.color.primary, th.color.surface, 0.55) : slicerButtonColor(th), fg = th.color.fg,
			padding = {th.spacing.sm, 3}, font_size = th.font.size_xs, radius = th.radius.sm, width = inner))
	}
	if a := Slicer_Animation(tab); a != nil {
		append(&rows, skald.wrap_row(
			button(ctx, "slicer-anim-up", ICON_ARROW_UP, Msg(Slicer_Changed{op = .Animation_Moved, number = -1}), disabled = tab.animation <= 0),
			button(ctx, "slicer-anim-down", ICON_ARROW_DOWN, Msg(Slicer_Changed{op = .Animation_Moved, number = 1}), disabled = tab.animation >= len(settings.animations) - 1),
			button(ctx, "slicer-anim-remove", fmt.tprintf("%s  Remove", ICON_TRASH), Msg(Slicer_Changed{op = .Animation_Removed})),
			spacing = th.spacing.xs, line_spacing = th.spacing.xs, width = inner))
		append(&rows, ..slicerAnimationRows(ctx, s, tab, a, controlWidth, numberWidth, selectWidth, inner))
	}

	// What it makes
	append(&rows, heading(ctx, "Make"))
	assetAt := Slicer_AssetIndex(s, tab)
	nameText := strings.clone(s.slicer.assetName, context.temp_allocator)
	append(&rows, inspectorRow(ctx, "Asset name", skald.text_input(ctx, nameText, proc(v: string) -> Msg { return Slicer_Changed{op = .Asset_Name, text = v} },
		id = skald.hash_id("slicer-asset-name"), width = min(controlWidth, INSPECTOR_MAX_TEXT_WIDTH), padding = InspectorFieldPadding(ctx),
		placeholder = strings.clone(Slicer_AssetName(s, tab), context.temp_allocator))))
	defs := 0
	for a in settings.animations do if len(a.frames) > 0 do defs += 1
	create := assetAt >= 0 ? fmt.tprintf("%s  Update %s", ICON_FILM, filepath.base(tab.settings.asset)) : fmt.tprintf("%s  Create Animation Asset", ICON_FILM)
	append(&rows, button(ctx, "slicer-create", create, Msg(Slicer_Asset_Created{}), disabled = defs == 0, primary = true))
	if assetAt >= 0 {
		use := skald.checkbox(ctx, s.slicer.useAsset, "Use the asset", proc(v: bool) -> Msg { return Slicer_Changed{op = .Use_Asset, flag = v} },
			id = skald.hash_id("slicer-use-asset"))
		append(&rows, skald.tooltip(ctx, use, fmt.tprintf("Apply to Sprite and Add to Scene give the sprite %s (else the animations themselves, as its own)", tab.settings.asset),
			id = skald.hash_id("slicer-use-asset-tip")))
	}
	target := Slicer_TargetSprite(s)
	applyLabel := target != nil ? fmt.tprintf("Apply to %s", target.name) : "Apply to Sprite"
	canGive := defs > 0 || (assetAt >= 0 && s.slicer.useAsset)
	append(&rows, skald.wrap_row(
		skald.tooltip(ctx, button(ctx, "slicer-apply", applyLabel, Msg(Slicer_Applied{}), disabled = target == nil || !canGive),
			target != nil ? "The selected AnimatedSprite plays these animations (its own, replaced; or the asset)" : "Select an AnimatedSprite in the scene tree to give it these animations", id = skald.hash_id("slicer-apply-tip")),
		skald.tooltip(ctx, button(ctx, "slicer-add-to-scene", "Add to Scene", Msg(Slicer_Added_To_Scene{}), disabled = !canGive),
			"A new AnimatedSprite playing these animations, in the middle of the view", id = skald.hash_id("slicer-add-to-scene-tip")),
		spacing = th.spacing.xs, line_spacing = th.spacing.xs, width = inner))
	append(&rows, note(ctx, "In scripts: e.AnimationPlayer_Play(&sprite.animation, ANIM_...): the animations' constants are in scripts/assets.odin once saved.", inner))

	return skald.scroll(ctx, {width, height}, skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.md, width = width - INSPECTOR_SCROLLBAR_WIDTH),
		id = skald.hash_id("slicer-scroll"))
}

// The shown animation's rows: name, speed, loop, play mode, frame times, the preview, its frames
@(private="file")
slicerAnimationRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, tab: ^SlicerTab, a: ^SliceAnimation, controlWidth, numberWidth, selectWidth, inner: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	settings := &tab.settings
	// The name keeps what's typed until it's valid (not empty, not another's)
	nameId := skald.hash_id("slicer-name")
	typing := skald.widget_has_focus(ctx, nameId) && s.slicer.nameId == nameId && s.slicer.nameText != a.name
	name := strings.clone(typing ? s.slicer.nameText : a.name, context.temp_allocator)
	problem := typing ? Slicer_NameProblem(settings.animations[:], tab.animation, s.slicer.nameText) : ""
	append(&rows, inspectorRow(ctx, "Animation name", skald.text_input(ctx, name, nameId, proc(id: skald.Widget_ID, v: string) -> Msg { return Slicer_Changed{op = .Name_Typed, text = v, id = id} },
		id = nameId, width = min(controlWidth, INSPECTOR_MAX_TEXT_WIDTH), padding = InspectorFieldPadding(ctx), invalid = problem != "")))
	if problem != "" do append(&rows, skald.text(problem, th.color.danger, th.font.size_xs, max_width = inner))
	append(&rows, inspectorRow(ctx, "FPS", numberField(ctx, s, "slicer-FPS", SlicerNumber.FPS, f64(a.fps), 1, 0, numberWidth, 0, 120)))
	append(&rows, inspectorRow(ctx, "Loop", skald.checkbox(ctx, a.loop, "", proc(v: bool) -> Msg { return Slicer_Changed{op = .Loop, flag = v} }, id = skald.hash_id("slicer-loop"))))
	modes := make([]string, len(e.AnimationPlayMode), context.temp_allocator)
	for mode in e.AnimationPlayMode do modes[mode] = fmt.tprintf("%v", mode)
	append(&rows, inspectorRow(ctx, "Play mode", skald.select(ctx, fmt.tprintf("%v", a.playMode), modes, proc(v: string) -> Msg { return Slicer_Changed{op = .Play_Mode, text = v} },
		id = skald.hash_id("slicer-play-mode"), width = selectWidth)))
	own := len(a.durations) > 0
	append(&rows, inspectorRow(ctx, "Frame times", skald.checkbox(ctx, own, "", proc(v: bool) -> Msg { return Slicer_Changed{op = .Durations, flag = v} }, id = skald.hash_id("slicer-durations"))))
	if own {
		times := make([dynamic]skald.View, context.temp_allocator)
		for frame in 0 ..< len(a.frames) {
			ms := frame < len(a.durations) ? a.durations[frame] * 1000 : 100
			append(&times, skald.row(
				skald.text(fmt.tprintf("%d:", frame + 1), th.color.fg_muted, th.font.size_xs),
				numberField(ctx, s, fmt.tprintf("slicer-duration-%d", frame), SlicerDurationTarget(frame), f64(ms), 10, 0, 96, 1, 60000),
				skald.text("ms", th.color.fg_muted, th.font.size_xs),
				spacing = th.spacing.xs, cross_align = .Center))
		}
		append(&rows, skald.wrap_row(..times[:], spacing = th.spacing.sm, line_spacing = th.spacing.xs, width = inner))
	}

	// The preview, playing as the game will (`AnimationDef_FrameAt`)
	sheet := sheetImage(ctx, s, tab.image)
	size := sheet.size
	if size.x <= 0 do size = Slicer_SheetSize(s, tab)
	rects := make([]sdl.FRect, len(a.frames), context.temp_allocator)
	for c, i in a.frames do rects[i] = Slicer_CellRect(settings, size, c)
	if settings.mode == .Auto && settings.evenOut do Slicer_EvenOut(rects, size)
	frame := 0
	if len(rects) > 0 {
		def := AnimationDef{start = 0, end = len(rects) - 1, fps = a.fps, loop = a.loop, playMode = a.playMode, durations = a.durations}
		backwards := a.playMode == .Reverse || a.playMode == .PingPongReverse
		frame = s.slicer.playing ? AnimationDef_FrameAt(def, len(rects), tab.clock) : (backwards ? len(rects) - 1 : 0)
	}
	if s.slicer.playing && !s.slicer.tickPending && EditorFocused() do skald.send(ctx, Msg(Slicer_Tick_Requested{}))
	Preview :: struct {
		image: string,
		cell: sdl.FRect,
		bg, edge: skald.Color,
	}
	preview := new_clone(Preview{sheet.name, len(rects) > 0 ? rects[frame] : {}, th.color.surface, th.color.border}, context.temp_allocator)
	canvas := skald.canvas(ctx, preview, proc(pv: ^Preview, p: skald.Canvas_Painter) {
		skald.draw_rect(p.r, p.bounds, pv.bg, 4)
		c := pv.cell
		if pv.image != "" && c.w > 0 && c.h > 0 {
			box := skald.Rect{p.bounds.x + 4, p.bounds.y + 4, p.bounds.w - 8, p.bounds.h - 8}
			scale := min(box.w / c.w, box.h / c.h)
			// Whole pixels when it fits that way (pixel art stays crisp)
			if scale >= 1 do scale = math.floor(scale)
			shown := skald.Rect{box.x + (box.w - c.w * scale) * 0.5, box.y + (box.h - c.h * scale) * 0.5, c.w * scale, c.h * scale}
			skald.draw_image_region(p.r, pv.image, shown, {c.x, c.y, c.w, c.h})
		}
		skald.draw_rect(p.r, {p.bounds.x, p.bounds.y + p.bounds.h - 1, p.bounds.w, 1}, pv.edge)
	}, id = skald.hash_id("slicer-preview"), width = SLICER_PREVIEW_SIZE, height = SLICER_PREVIEW_SIZE)
	playing := s.slicer.playing
	play := skald.button(ctx, playing ? ICON_PAUSE : ICON_PLAY, Msg(Slicer_Changed{op = .Playback}), id = skald.hash_id("slicer-play"),
		bg = th.color.surface, fg = th.color.fg, width = 28, padding = {0, 2}, font_size = th.font.size_sm, radius = th.radius.sm)
	append(&rows, skald.row(
		canvas,
		skald.col(
			skald.tooltip(ctx, play, playing ? "Pause the preview" : "Play the preview", id = skald.hash_id("slicer-play-tip")),
			skald.text(len(rects) > 0 ? fmt.tprintf("frame %d of %d", frame + 1, len(rects)) : "no frames", th.color.fg_muted, th.font.size_xs),
			spacing = th.spacing.xs),
		spacing = th.spacing.sm))

	// Its frames, in order: click one to move it or take it out
	perRow := max(int((inner + SLICER_THUMB_GAP) / (SLICER_THUMB + SLICER_THUMB_GAP)), 1)
	stripRows := max((len(rects) + perRow - 1) / perRow, 1)
	stripId := skald.hash_id("slicer-frames")
	if state, drawn := ctx.widgets.states[stripId]; drawn && state.last_rect.w > 0 && ctx.input.mouse_pressed[.Left] {
		rect := state.last_rect
		visible := state.clip_rect.w > 0 ? state.clip_rect : rect
		mouse := ctx.input.mouse_pos
		if pointIn(rect, mouse) && pointIn(visible, mouse) && len(ctx.widgets.overlay_rects_prev) == 0 && ctx.widgets.modal_rect_prev.w == 0 {
			column := int((mouse.x - rect.x) / (SLICER_THUMB + SLICER_THUMB_GAP))
			row := int((mouse.y - rect.y) / (SLICER_THUMB + SLICER_THUMB_GAP))
			if picked := row * perRow + column; column < perRow && picked < len(rects) do skald.send(ctx, Msg(Slicer_Changed{op = .Frame_Picked, index = picked}))
		}
	}
	Strip :: struct {
		image: string,
		rects: []sdl.FRect,
		perRow, picked, current: int,
		dim, lit, edge, text: skald.Color,
		font: f32,
	}
	strip := new_clone(Strip{sheet.name, rects, perRow, tab.frame, s.slicer.playing ? frame : -1,
		th.color.surface, th.color.warning, th.color.border, th.color.fg_muted, th.font.size_xs}, context.temp_allocator)
	append(&rows, skald.canvas(ctx, strip, proc(st: ^Strip, p: skald.Canvas_Painter) {
		for c, i in st.rects {
			x := p.bounds.x + f32(i % st.perRow) * (SLICER_THUMB + SLICER_THUMB_GAP)
			y := p.bounds.y + f32(i / st.perRow) * (SLICER_THUMB + SLICER_THUMB_GAP)
			box := skald.Rect{x, y, SLICER_THUMB, SLICER_THUMB}
			skald.draw_rect(p.r, box, st.dim, 3)
			if st.image != "" && c.w > 0 && c.h > 0 {
				scale := min((box.w - 4) / c.w, (box.h - 4) / c.h)
				shown := skald.Rect{box.x + (box.w - c.w * scale) * 0.5, box.y + (box.h - c.h * scale) * 0.5, c.w * scale, c.h * scale}
				skald.draw_image_region(p.r, st.image, shown, {c.x, c.y, c.w, c.h})
			}
			edge := i == st.picked ? st.lit : i == st.current ? st.text : st.edge
			w := f32(i == st.picked || i == st.current ? 2 : 1)
			skald.draw_rect(p.r, {box.x, box.y, box.w, w}, edge)
			skald.draw_rect(p.r, {box.x, box.y + box.h - w, box.w, w}, edge)
			skald.draw_rect(p.r, {box.x, box.y, w, box.h}, edge)
			skald.draw_rect(p.r, {box.x + box.w - w, box.y, w, box.h}, edge)
			drawTextTop(p.r, fmt.tprintf("%d", i + 1), box.x + 2, box.y + 1, st.text, st.font)
		}
	}, id = stripId, width = inner, height = f32(stripRows) * (SLICER_THUMB + SLICER_THUMB_GAP), cursor = .Pointer))
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg, disabled := false) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = slicerButtonColor(th), fg = th.color.fg,
			padding = {th.spacing.sm, 3}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = disabled)
	}
	picked := tab.frame >= 0 && tab.frame < len(a.frames)
	append(&rows, skald.wrap_row(
		button(ctx, "slicer-frame-earlier", fmt.tprintf("%s  Earlier", ICON_ARROW_LEFT), Msg(Slicer_Changed{op = .Frame_Moved, number = -1}), disabled = !picked || tab.frame == 0),
		button(ctx, "slicer-frame-later", fmt.tprintf("Later  %s", ICON_ARROW_RIGHT), Msg(Slicer_Changed{op = .Frame_Moved, number = 1}), disabled = !picked || tab.frame >= len(a.frames) - 1),
		button(ctx, "slicer-frame-remove", fmt.tprintf("%s  Take Out", ICON_XMARK), Msg(Slicer_Changed{op = .Frame_Removed}), disabled = !picked),
		spacing = th.spacing.xs, line_spacing = th.spacing.xs, width = inner))
	if picked do append(&rows, skald.text(fmt.tprintf("Frame %d: cell %d", tab.frame + 1, a.frames[tab.frame]), th.color.fg_muted, th.font.size_xs))
	return rows[:]
}

/*
Where a cell of the shown sheet is on the slicer's canvas (its middle, from the canvas's top left;
the UI tests click it), and whether that's in view.
*/
Slicer_CellCenter :: proc(s: ^State, tab: ^SlicerTab, cell: int) -> ([2]f32, bool) {
	size := Slicer_SheetSize(s, tab)
	if cell < 0 || cell >= Slicer_CellCount(&tab.settings, size) || tab.zoom <= 0 do return {}, false
	r := Slicer_CellRect(&tab.settings, size, cell)
	local := tab.canvas * 0.5 + ([2]f32{r.x + r.w / 2, r.y + r.h / 2} - tab.center) * tab.zoom
	return local, local.x >= 0 && local.y >= 0 && local.x < tab.canvas.x && local.y < tab.canvas.y
}

// The middle of frame n in the slicer's frame strip, from its top left, at the strip's width
Slicer_FrameStripCenter :: proc(frame: int, width: f32) -> [2]f32 {
	perRow := max(int((width + SLICER_THUMB_GAP) / (SLICER_THUMB + SLICER_THUMB_GAP)), 1)
	return {f32(frame % perRow) * (SLICER_THUMB + SLICER_THUMB_GAP) + SLICER_THUMB / 2, f32(frame / perRow) * (SLICER_THUMB + SLICER_THUMB_GAP) + SLICER_THUMB / 2}
}
