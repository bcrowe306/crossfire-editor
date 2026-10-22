package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The Animation panel (the bottom panel's Animation tab): the animation editor for the selected
AnimatedSprite. A toolbar on top, the frames below, using the panel's whole width:

	+---------------------------------------------------------------------------------+
	| [walk v] + dup - up dn   Name [walk]   * Starts with this   Frames [0] to [3]     |
	| FPS [10]  [x] Loop  [Forward v]   Sheet [hero.png v]   Grid 4 x 2   Margin  Gap  |
	+------------+--------------------------------------------------------------------+
	|  preview   | [0][1][2][3][4][5][6][7]  a thumbnail of every cell of the sheet,  |
	|  > 2 / 4   |  the selected animation's cells lit                                |
	+------------+--------------------------------------------------------------------+

- The animation dropdown picks the animation; the buttons add, duplicate, remove and move it.
  The star marks the one the sprite starts with (or the inspector's Starts with).
- The selected animation's name, first and last frame, speed, looping and play mode, then the
  sprite sheet's image and grid (the same as the inspector's). The toolbar's groups wrap onto as
  many lines as the panel's width needs; the whole panel scrolls when it's short.
- The frames: click a thumbnail to start the animation there, Shift+click to end it there.
- The preview plays the animation as the game will (`AnimationDef_FrameAt`); the viewport plays
  it on the sprite too.

Logic and messages: animation_edit.odin. Widget keys: `animation-select` (the dropdown),
`animation-add`, `animation-duplicate`, `animation-remove`, `animation-up`, `animation-down`,
`animation-name-<node>`, `animation-start-<node>`, `animation-end-<node>`, `animation-fps-<node>`,
`animation-loop-<node>`, `animation-mode-<node>`, `animation-autoplay`, `animation-sheet-<node>`,
`animation-frames` (the thumbnails), `animation-preview`, `animation-play`.
*/

// Thumbnail size and gap in the frame strip
@(private="file")
THUMB_SIZE :: 56
@(private="file")
THUMB_GAP :: 6
@(private="file")
PREVIEW_SIZE :: 120
@(private="file")
NUMBER_WIDTH :: 76

AnimationPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	src, animation, index := AnimEdit_Selection(s)
	if src.kind == .None {
		if src.path != "" do return placeholder(ctx, fmt.tprintf("%s couldn't be read.", src.path))
		return placeholder(ctx, "Select an AnimatedSprite node (or an animation asset in the browser) to edit its animations.")
	}
	if animation == nil do return placeholder(ctx, fmt.tprintf("%s has no animations.", AnimSource_Name(src)))
	sheet := sheetImage(ctx, s, src.texture^)
	cells := max(src.columns^ * src.rows^, 1)
	// Widget keys: the node's index for its own animations (the UI tests use it), else apart
	key := src.kind == .Node ? s.selectedNode : -2 - max(src.setIndex, 0)

	// Keep the preview's frames coming while it plays
	if s.animEditor.playing && !s.animEditor.tickPending && EditorFocused() do skald.send(ctx, Msg(Anim_Tick_Requested{}))

	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.sm * 2 - INSPECTOR_SCROLLBAR_WIDTH
	gap := th.spacing.sm

	// The toolbar's groups wrap onto more lines when the panel is narrow; everything scrolls
	// together when the panel is short
	toolbar := make([dynamic]skald.View, context.temp_allocator)
	append(&toolbar, ..sourceLabel(ctx, s, src))
	append(&toolbar, ..animationPicker(ctx, s, src, animation^, index, key))
	append(&toolbar, ..animationDetails(ctx, s, src, animation^, key, cells))
	append(&toolbar, ..sheetSettings(ctx, s, src, key, cells))
	stripWidth := max(width - PREVIEW_SIZE - gap * 3, THUMB_SIZE)
	return skald.scroll(ctx, {0, 0}, skald.col(
		skald.wrap_row(..toolbar[:], spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = gap, width = width, bg = th.color.surface),
		skald.divider(ctx),
		skald.row(
			animationPreview(ctx, s, src, animation^, sheet, cells),
			frameStrip(ctx, s, src, animation^, sheet, cells, stripWidth),
			spacing = gap,
			padding = gap,
		),
		width = width,
	), id = skald.hash_id("animation-scroll"))
}

// A label and its controls, kept together on one toolbar line
@(private="file")
group :: proc(ctx: ^skald.Ctx(Msg), label: string, controls: ..skald.View) -> skald.View {
	views := make([dynamic]skald.View, context.temp_allocator)
	if label != "" do append(&views, toolLabel(ctx, label))
	append(&views, ..controls)
	return skald.row(..views[:], spacing = ctx.theme.spacing.xs, cross_align = .Center)
}

// What the panel edits: the sprite's own animations, an asset (and how many sprites use it), or an
// Aseprite file's tags (read only, with Open in Aseprite)
@(private="file")
sourceLabel :: proc(ctx: ^skald.Ctx(Msg), s: ^State, src: AnimSource) -> []skald.View {
	th := ctx.theme
	text: string
	switch src.kind {
	case .None:
	case .Node: text = fmt.tprintf("%s's own animations", src.node.name)
	case .Set:
		users := AnimationSet_UserCount(&s.project, src.path)
		text = fmt.tprintf("%s  (used by %d sprite%s)", filepath.base(src.path), users, users == 1 ? "" : "s")
	case .Aseprite: text = fmt.tprintf("%s: its tags (edit them in Aseprite)", filepath.base(src.path))
	}
	// Separate toolbar items: they wrap onto their own lines in a narrow panel
	views := make([dynamic]skald.View, context.temp_allocator)
	append(&views, skald.text(fmt.tprintf("%s  %s", ICON_FILM, text), th.color.fg, th.font.size_sm))
	if src.kind == .Aseprite {
		index := -1
		for a, i in s.project.assets do if a.path == src.path do index = i
		append(&views, skald.button(ctx, "Open in Aseprite", Msg(Aseprite_Asset_Open_Requested(index)), id = skald.hash_id("animation-aseprite-open"),
			bg = th.color.bg, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm))
	}
	if s.animEditor.asset != "" {
		append(&views, skald.button(ctx, "Back to the sprite", Msg(Anim_Asset_Shown("")), id = skald.hash_id("animation-asset-close"),
			bg = th.color.bg, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm))
	}
	return views[:]
}

// Toolbar, first row: which animation (a dropdown), the list's buttons, its name, "starts with"
@(private="file")
animationPicker :: proc(ctx: ^skald.Ctx(Msg), s: ^State, src: AnimSource, animation: AnimationDef, index, key: int) -> []skald.View {
	th := ctx.theme
	count := len(src.animations^)
	autoplay := src.autoplay^
	// The dropdown lists the names; the starting one gets a star
	labels := make([]string, count, context.temp_allocator)
	for a, i in src.animations^ {
		first := autoplay == a.name || (autoplay == "" && i == 0)
		labels[i] = first ? fmt.tprintf("%s %s", a.name, ICON_STAR) : a.name
	}
	Choices :: struct { labels: []string }
	picker := skald.select(ctx, labels[index], labels, Choices{labels}, proc(c: Choices, v: string) -> Msg {
		for label, i in c.labels do if label == v do return Anim_Selected(i)
		return {}
	}, id = skald.hash_id("animation-select"), width = 150)
	tool :: proc(ctx: ^skald.Ctx(Msg), key, icon, tip: string, msg: Msg, disabled := false) -> skald.View {
		th := ctx.theme
		button := skald.button(ctx, icon, msg, id = skald.hash_id(key), bg = th.color.bg, fg = th.color.fg_muted,
			width = 26, padding = {0, 2}, font_size = th.font.size_sm, radius = th.radius.sm, disabled = disabled)
		return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("%s-tip", key)))
	}

	// The name keeps what's typed until it's valid (not empty, not another animation's)
	nameId := skald.hash_id(fmt.tprintf("animation-name-%d", key))
	typing := skald.widget_has_focus(ctx, nameId) && s.animEditor.nameId == nameId && s.animEditor.nameText != animation.name
	name := strings.clone(typing ? s.animEditor.nameText : animation.name, context.temp_allocator)
	problem := typing ? AnimEdit_NameProblem(src.animations[:], index, s.animEditor.nameText) : ""
	nameField := skald.text_input(ctx, name, nameId, proc(id: skald.Widget_ID, v: string) -> Msg { return Anim_Name_Typed{id, v} },
		id = nameId, width = 140, padding = InspectorFieldPadding(ctx), invalid = problem != "")
	isFirst := autoplay == animation.name || (autoplay == "" && index == 0)
	first := skald.button(ctx, fmt.tprintf("%s  Starts with this", ICON_STAR), Msg(Anim_Autoplay_Set{}), id = skald.hash_id("animation-autoplay"),
		bg = isFirst ? th.color.primary : th.color.bg, fg = isFirst ? th.color.on_primary : th.color.fg,
		padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = autoplay == animation.name || src.readOnly)
	if src.readOnly {
		// Aseprite's tags: which one, and that's all
		groups := make([dynamic]skald.View, context.temp_allocator)
		append(&groups, group(ctx, "", skald.text(ICON_FILM, th.color.fg_muted, th.font.size_sm), picker))
		return groups[:]
	}
	groups := make([dynamic]skald.View, context.temp_allocator)
	append(&groups,
		group(ctx, "", skald.text(ICON_FILM, th.color.fg_muted, th.font.size_sm), picker),
		group(ctx, "",
			tool(ctx, "animation-add", ICON_PLUS, "New animation (every frame)", Msg(Anim_Added{})),
			tool(ctx, "animation-duplicate", ICON_COPY, "Duplicate this animation", Msg(Anim_Duplicated{})),
			tool(ctx, "animation-remove", ICON_TRASH, "Remove this animation (a sprite keeps one)", Msg(Anim_Removed{}), disabled = count <= 1),
			tool(ctx, "animation-up", ICON_ARROW_UP, "Move it up the list", Msg(Anim_Moved(-1)), disabled = index <= 0),
			tool(ctx, "animation-down", ICON_ARROW_DOWN, "Move it down the list", Msg(Anim_Moved(1)), disabled = index >= count - 1)),
		group(ctx, "Name", nameField),
		skald.tooltip(ctx, first, "The sprite plays this animation when the game starts", id = skald.hash_id("animation-autoplay-tip")),
	)
	if problem != "" do append(&groups, skald.text(problem, th.color.danger, th.font.size_xs))
	return groups[:]
}

// Toolbar: the animation's frames, speed, looping and play mode
@(private="file")
animationDetails :: proc(ctx: ^skald.Ctx(Msg), s: ^State, src: AnimSource, animation: AnimationDef, key, cells: int) -> []skald.View {
	th := ctx.theme
	start, end := AnimationDef_Range(animation, cells)
	timing := ""
	if len(animation.durations) > 0 {
		ms := make([dynamic]string, context.temp_allocator)
		for d in animation.durations do append(&ms, fmt.tprintf("%.0f", d * 1000))
		timing = fmt.tprintf("Durations (ms): %s", strings.join(ms[:], " ", context.temp_allocator))
	}
	// Its frames' events (animation.onFrameEvent): an Aseprite file's from its cels
	events := make([dynamic]string, context.temp_allocator)
	for event, i in animation.events do if event != "" do append(&events, fmt.tprintf("frame %d: %s", start + i, event))
	eventText := len(events) > 0 ? fmt.tprintf("Events (animation.onFrameEvent): %s", strings.join(events[:], "; ", context.temp_allocator)) : ""
	if src.readOnly {
		groups := make([dynamic]skald.View, context.temp_allocator)
		repeat := animation.loop ? "loops" : animation.repeat > 1 ? fmt.tprintf("plays %d times", animation.repeat) : "plays once"
		append(&groups, skald.text(fmt.tprintf("Frames %d to %d · %v · %s", start, end, animation.playMode, repeat), th.color.fg_muted, th.font.size_xs))
		if timing != "" do append(&groups, skald.text(timing, th.color.fg_muted, th.font.size_xs))
		if eventText != "" do append(&groups, skald.text(eventText, th.color.fg_muted, th.font.size_xs))
		return groups[:]
	}
	modes := make([]string, len(e.AnimationPlayMode), context.temp_allocator)
	for mode in e.AnimationPlayMode do modes[mode] = fmt.tprintf("%v", mode)
	groups := make([dynamic]skald.View, context.temp_allocator)
	append(&groups,
		group(ctx, "Frames",
			numberField(ctx, s, fmt.tprintf("animation-start-%d", key), AnimField.Start, f64(start), 1, 0, NUMBER_WIDTH, 0, f64(cells - 1)),
			toolLabel(ctx, "to"),
			numberField(ctx, s, fmt.tprintf("animation-end-%d", key), AnimField.End, f64(end), 1, 0, NUMBER_WIDTH, 0, f64(cells - 1))),
		group(ctx, "FPS", numberField(ctx, s, fmt.tprintf("animation-fps-%d", key), AnimField.FPS, f64(animation.fps), 1, 0, NUMBER_WIDTH, 0, 120)),
		skald.checkbox(ctx, animation.loop, "Loop", proc(v: bool) -> Msg { return Anim_Loop_Changed(v) }, id = skald.hash_id(fmt.tprintf("animation-loop-%d", key))),
		skald.select(ctx, fmt.tprintf("%v", animation.playMode), modes, proc(v: string) -> Msg { return Anim_Mode_Changed(v) },
			id = skald.hash_id(fmt.tprintf("animation-mode-%d", key)), width = 110),
	)
	if timing != "" do append(&groups, skald.text(fmt.tprintf("%s (they set the speed, not FPS)", timing), th.color.fg_muted, th.font.size_xs))
	if eventText != "" do append(&groups, skald.text(eventText, th.color.fg_muted, th.font.size_xs))
	return groups[:]
}

// Toolbar: the sprite sheet's image and grid (a node's: the inspector edits the same fields)
@(private="file")
sheetSettings :: proc(ctx: ^skald.Ctx(Msg), s: ^State, src: AnimSource, key, cells: int) -> []skald.View {
	th := ctx.theme
	groups := make([dynamic]skald.View, context.temp_allocator)
	if src.readOnly {
		append(&groups, skald.text(fmt.tprintf("Sheet: every frame, %d x %d", src.columns^, src.rows^), th.color.fg_muted, th.font.size_xs))
		return groups[:]
	}
	images := make([dynamic]string, context.temp_allocator)
	append(&images, TEXTURE_NONE)
	for asset in s.project.assets do if asset.kind == .Image do append(&images, asset.path)
	texture := src.texture^
	sheet: skald.View
	if src.kind == .Node {
		sheet = skald.select(ctx, texture == "" ? TEXTURE_NONE : texture, images[:], NodeTextField.Texture,
			proc(field: NodeTextField, v: string) -> Msg { return Node_Text_Changed{field, v} },
			id = skald.hash_id(fmt.tprintf("animation-sheet-%d", key)), width = 150, placeholder = "Choose an image")
	} else {
		sheet = skald.select(ctx, texture == "" ? TEXTURE_NONE : texture, images[:], proc(v: string) -> Msg { return Anim_Sheet_Texture_Changed(v) },
			id = skald.hash_id(fmt.tprintf("animation-sheet-%d", key)), width = 150, placeholder = "Choose an image")
	}
	// A node's grid is its node fields; an asset's, the panel's own
	number :: proc(ctx: ^skald.Ctx(Msg), s: ^State, src: AnimSource, key: int, field: NodeField, value: f32, lo, hi: f64) -> skald.View {
		id := fmt.tprintf("animation-%v-%d", field, key)
		if src.kind == .Node do return numberField(ctx, s, id, field, f64(value), 1, 0, NUMBER_WIDTH, lo, hi)
		anim: AnimField
		#partial switch field {
		case .Columns: anim = .Columns
		case .Rows:    anim = .Rows
		case .Margin:  anim = .Margin
		case .Spacing: anim = .Spacing
		}
		return numberField(ctx, s, id, anim, f64(value), 1, 0, NUMBER_WIDTH, lo, hi)
	}
	append(&groups,
		group(ctx, "Sheet", sheet),
		group(ctx, "Grid", number(ctx, s, src, key, .Columns, f32(src.columns^), 1, 64), toolLabel(ctx, "×"), number(ctx, s, src, key, .Rows, f32(src.rows^), 1, 64)),
		group(ctx, "Margin", number(ctx, s, src, key, .Margin, src.margin^, 0, 1000)),
		group(ctx, "Gap", number(ctx, s, src, key, .Spacing, src.spacing^, 0, 1000)),
		skald.text(fmt.tprintf("%d frames", cells), th.color.fg_muted, th.font.size_xs),
	)
	return groups[:]
}

@(private="file")
toolLabel :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
	return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_sm)
}

/*
A thumbnail of every cell of the sheet, wrapped to `width`: the selected animation's cells lit,
its first and last marked, the preview's current frame outlined. Click sets the start,
Shift+click the end.
*/
@(private="file")
frameStrip :: proc(ctx: ^skald.Ctx(Msg), s: ^State, src: AnimSource, animation: AnimationDef, sheet: SheetImage, cells: int, width: f32) -> skald.View {
	th := ctx.theme
	id := skald.hash_id("animation-frames")
	perRow := max(int((width + THUMB_GAP) / (THUMB_SIZE + THUMB_GAP)), 1)
	stripColumns = perRow
	rowCount := (cells + perRow - 1) / perRow
	height := f32(rowCount) * (THUMB_SIZE + THUMB_GAP + 12)

	// A right-click on a frame: its menu (start or end the animation there: context_menus_panels.odin)
	if state, drawn := ctx.widgets.states[id]; drawn && state.last_rect.w > 0 && ctx.input.mouse_pressed[.Right] {
		rect := state.last_rect
		mouse := ctx.input.mouse_pos
		column := int((mouse.x - rect.x) / (THUMB_SIZE + THUMB_GAP))
		row := int((mouse.y - rect.y) / (THUMB_SIZE + THUMB_GAP + 12))
		if frame := row * perRow + column; mouse.x >= rect.x && mouse.y >= rect.y && column < perRow && frame < cells {
			rightPressOpens(ctx, rect, Ctx_Graph{graph = .Animation, item = frame, sub = -1})
		}
	}
	// The mouse, from last frame's rect (like the scene tree's)
	if state, drawn := ctx.widgets.states[id]; drawn && state.last_rect.w > 0 && ctx.input.mouse_pressed[.Left] {
		rect := state.last_rect
		mouse := ctx.input.mouse_pos
		visible := state.clip_rect.w > 0 ? state.clip_rect : rect
		inside :: proc(r: skald.Rect, p: [2]f32) -> bool { return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h }
		if inside(rect, mouse) && inside(visible, mouse) && len(ctx.widgets.overlay_rects_prev) == 0 && ctx.widgets.modal_rect_prev.w == 0 {
			column := int((mouse.x - rect.x) / (THUMB_SIZE + THUMB_GAP))
			row := int((mouse.y - rect.y) / (THUMB_SIZE + THUMB_GAP + 12))
			frame := row * perRow + column
			if column < perRow && frame < cells {
				skald.send(ctx, Msg(Anim_Frame_Clicked{frame, .Shift in ctx.input.modifiers}))
			}
		}
	}

	start, end := AnimationDef_Range(animation, cells)
	Strip :: struct {
		sheet: SheetImage,
		grid: SheetGrid,
		cells, perRow, start, end, current: int,
		lit, dim, edge, current_color, text, muted: skald.Color,
		font: f32,
	}
	strip := new_clone(Strip{
		sheet = sheet, grid = gridOf(src), cells = cells, perRow = perRow, start = start, end = end,
		current = s.animEditor.playing ? AnimationDef_FrameAt(animation, cells, s.animEditor.clock) : -1,
		lit = th.color.primary, dim = th.color.surface, edge = th.color.border, current_color = th.color.fg,
		text = th.color.fg, muted = th.color.fg_muted, font = th.font.size_xs,
	}, context.temp_allocator)
	return skald.canvas(ctx, strip, proc(st: ^Strip, p: skald.Canvas_Painter) {
		for frame in 0 ..< st.cells {
			x := p.bounds.x + f32(frame % st.perRow) * (THUMB_SIZE + THUMB_GAP)
			y := p.bounds.y + f32(frame / st.perRow) * (THUMB_SIZE + THUMB_GAP + 12)
			box := skald.Rect{x, y, THUMB_SIZE, THUMB_SIZE}
			inRange := frame >= st.start && frame <= st.end
			skald.draw_rect(p.r, box, st.dim, 3)
			drawCell(p.r, st.sheet, st.grid, frame, box, inRange ? {1, 1, 1, 1} : {1, 1, 1, 0.35})
			ring(p.r, box, frame == st.current ? st.current_color : inRange ? st.lit : st.edge, frame == st.current || inRange ? 2 : 1)
			caption := fmt.tprintf("%d", frame)
			if frame == st.start && frame == st.end do caption = fmt.tprintf("%d  start·end", frame)
			else if frame == st.start do caption = fmt.tprintf("%d  start", frame)
			else if frame == st.end do caption = fmt.tprintf("%d  end", frame)
			drawTextTop(p.r, caption, x, y + THUMB_SIZE + 1, inRange ? st.text : st.muted, st.font)
		}
	}, id = id, width = width, height = height, cursor = .Pointer)
}

// The selected animation playing (or its first frame while paused), with play / pause; the
// hint about clicking frames sits under it
@(private="file")
animationPreview :: proc(ctx: ^skald.Ctx(Msg), s: ^State, src: AnimSource, animation: AnimationDef, sheet: SheetImage, cells: int) -> skald.View {
	th := ctx.theme
	start, end := AnimationDef_Range(animation, cells)
	backwards := animation.playMode == .Reverse || animation.playMode == .PingPongReverse
	frame := s.animEditor.playing ? AnimationDef_FrameAt(animation, cells, s.animEditor.clock) : (backwards ? end : start)
	Preview :: struct { sheet: SheetImage, grid: SheetGrid, frame: int, bg, edge: skald.Color }
	preview := new_clone(Preview{sheet, gridOf(src), frame, th.color.surface, th.color.border}, context.temp_allocator)
	canvas := skald.canvas(ctx, preview, proc(pv: ^Preview, p: skald.Canvas_Painter) {
		skald.draw_rect(p.r, p.bounds, pv.bg, 4)
		drawCell(p.r, pv.sheet, pv.grid, pv.frame, {p.bounds.x + 4, p.bounds.y + 4, p.bounds.w - 8, p.bounds.h - 8}, {1, 1, 1, 1})
		ring(p.r, p.bounds, pv.edge, 1)
	}, id = skald.hash_id("animation-preview"), width = PREVIEW_SIZE, height = PREVIEW_SIZE)
	playing := s.animEditor.playing
	play := skald.button(ctx, playing ? ICON_PAUSE : ICON_PLAY, Msg(Anim_Playback_Toggled{}), id = skald.hash_id("animation-play"),
		bg = th.color.surface, fg = th.color.fg, width = 28, padding = {0, 2}, font_size = th.font.size_sm, radius = th.radius.sm)
	return skald.col(
		canvas,
		skald.row(
			skald.tooltip(ctx, play, playing ? "Pause the preview" : "Play the preview", id = skald.hash_id("animation-play-tip")),
			skald.text(fmt.tprintf("frame %d · %d of %d", frame, frame - start + 1, end - start + 1), th.color.fg_muted, th.font.size_xs),
			spacing = th.spacing.xs, cross_align = .Center,
		),
		skald.text("Click a frame: start there. Shift+click: end there.", th.color.fg_muted, th.font.size_xs, max_width = PREVIEW_SIZE),
		spacing = th.spacing.xs,
		width = PREVIEW_SIZE,
	)
}

// A sheet's grid (what drawing a cell needs from the node)
@(private="file")
SheetGrid :: struct {
	columns, rows: int,
	margin, spacing: f32,
}

@(private="file")
gridOf :: proc(src: AnimSource) -> SheetGrid {
	return {src.columns^, src.rows^, src.margin^, src.spacing^}
}

// A sprite sheet uploaded to Skald, to draw its cells
SheetImage :: struct {
	// The Skald image name ("" if it isn't loaded)
	name: string,
	size: [2]f32,
}

// Loaded sheets by file path; a failed load is remembered too (name "")
@(private="file")
sheets: map[string]SheetImage

/*
The node's sprite sheet as a Skald image, loaded (`Image_LoadRGBA`: stb_image, or the engine for
Aseprite files) and uploaded the first time.
*/
@(private="file")
sheetImage :: proc(ctx: ^skald.Ctx(Msg), s: ^State, texture: string) -> SheetImage {
	if texture == "" || ctx.renderer == nil do return {}
	path := joinPath(s.project.rootPath, texture, allocator = context.temp_allocator)
	// By the file's time too: saved again (in Aseprite), it's uploaded again
	file := strings.trim_suffix(path, e.ASEPRITE_SHEET_SUFFIX)
	cacheKey := fmt.tprintf("%s@%v", path, ldtkModified(file))
	if image, known := sheets[cacheKey]; known do return image
	image: SheetImage
	if pixels, w, h, ok := Image_LoadRGBA(path); ok {
		name := fmt.aprintf("animation-sheet:%s", cacheKey)
		if skald.image_load_pixels(ctx.renderer, name, u32(w), u32(h), pixels) {
			image = {name, {f32(w), f32(h)}}
		} else {
			delete(name)
		}
	}
	sheets[strings.clone(cacheKey)] = image
	return image
}

// Thumbnails per row in the last frame strip drawn
@(private="file")
stripColumns := 1

// The center of thumbnail n, from the strip's top left (the UI tests click it)
AnimationPanel_FrameCenter :: proc(frame: int) -> [2]f32 {
	return {f32(frame % stripColumns) * (THUMB_SIZE + THUMB_GAP) + THUMB_SIZE * 0.5, f32(frame / stripColumns) * (THUMB_SIZE + THUMB_GAP + 12) + THUMB_SIZE * 0.5}
}

// Whether the panel has uploaded a sheet (for the UI tests: thumbnails can be drawn)
AnimationPanel_SheetLoaded :: proc(s: ^State, texture: string) -> bool {
	path := joinPath(s.project.rootPath, texture, allocator = context.temp_allocator)
	for key, image in sheets do if strings.has_prefix(key, fmt.tprintf("%s@", path)) && image.name != "" do return true
	return false
}

// Draws one cell of a sheet into `box`, keeping its shape (centered)
@(private="file")
drawCell :: proc(r: ^skald.Renderer, sheet: SheetImage, grid: SheetGrid, frame: int, box: skald.Rect, tint: skald.Color) {
	if sheet.name == "" do return
	cell := e.SpriteSheet_CellRect(sheet.size, grid.columns, grid.rows, grid.margin, grid.spacing, frame)
	if cell.w <= 0 || cell.h <= 0 do return
	scale := min(box.w / cell.w, box.h / cell.h)
	shown := skald.Rect{box.x + (box.w - cell.w * scale) * 0.5, box.y + (box.h - cell.h * scale) * 0.5, cell.w * scale, cell.h * scale}
	skald.draw_image_region(r, sheet.name, shown, {cell.x, cell.y, cell.w, cell.h}, tint)
}

@(private="file")
ring :: proc(r: ^skald.Renderer, b: skald.Rect, color: skald.Color, width: f32) {
	skald.draw_rect(r, {b.x, b.y, b.w, width}, color)
	skald.draw_rect(r, {b.x, b.y + b.h - width, b.w, width}, color)
	skald.draw_rect(r, {b.x, b.y, width, b.h}, color)
	skald.draw_rect(r, {b.x + b.w - width, b.y, width, b.h}, color)
}
