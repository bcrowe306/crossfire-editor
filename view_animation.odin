package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
The Animation panel (the bottom panel's Animation tab): the animation editor for the selected
AnimatedSprite. A toolbar on top, the frames below, using the panel's whole width:

	+---------------------------------------------------------------------------------+
	| [walk v] + dup - up dn   Name [walk]   * Starts with this                         |
	| Sheet [walk.png v]  Grid [Cells v]  [4] x [2]  Margin [0]  Gap [0]  8 frames      |
	| Frames [0] to [3]  Count [4]  FPS [10]  [x] Loop  [Forward v]                     |
	+------------+--------------------------------------------------------------------+
	|  preview   | [0][1][2][3][4][5][6][7]  a thumbnail of every cell of its sheet,  |
	|  > 2 / 4   |  the selected animation's cells lit                                |
	+------------+--------------------------------------------------------------------+

- The animation dropdown picks the animation; the buttons add (every frame of the selected one's
  sheet), duplicate, remove and move it. The star marks the one the sprite starts with (or the
  inspector's Starts with).
- The selected animation's name; its own sheet (an image, or one dragged from the browser onto
  the panel) and grid: columns x rows, or (Grid: Size) a cell's width x height in pixels, the
  other worked out from the image; margin and gap; its first and last frame (or how many),
  speed, looping and play mode. The toolbar's groups wrap onto as many lines as the panel's
  width needs (they're kept small: the tiled window is narrow); the whole panel scrolls when
  it's short.
- The frames: the selected animation's sheet; click a thumbnail to start the animation there,
  Shift+click to end it there.
- The preview plays the animation as the game will (`AnimationDef_FrameAt`); the viewport plays
  it on the sprite too.

Logic and messages: animation_edit.odin. Widget keys: `animation-select` (the dropdown),
`animation-add`, `animation-duplicate`, `animation-remove`, `animation-up`, `animation-down`,
`animation-name-<node>`, `animation-sheet-<node>`, `animation-grid-<node>` (Cells or Size),
`animation-Columns-<node>`, `animation-Rows-<node>`, `animation-Cell_Width-<node>`,
`animation-Cell_Height-<node>`, `animation-Margin-<node>`, `animation-Spacing-<node>`,
`animation-start-<node>`, `animation-end-<node>`, `animation-count-<node>`, `animation-fps-<node>`,
`animation-loop-<node>`, `animation-mode-<node>`, `animation-autoplay`, `animation-frames` (the
thumbnails), `animation-preview`, `animation-play`, `animation-scroll` (the panel: images dropped
on it).
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
	// The selected animation's own sheet
	sheet := sheetImage(ctx, s, animation.sheet)
	cells := AnimEdit_Cells(s.project.rootPath, animation^)
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
	append(&toolbar, ..sheetSettings(ctx, s, src, animation^, key, cells))
	append(&toolbar, ..animationDetails(ctx, s, src, animation^, key, cells))
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
	tk := uiTokens(ctx)
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
	append(&views, uiText(th, .Value, fmt.tprintf("%s  %s", ICON_FILM, text)))
	if src.kind == .Aseprite {
		index := -1
		for a, i in s.project.assets do if a.path == src.path do index = i
		append(&views, skald.button(ctx, "Open in Aseprite", Msg(Aseprite_Asset_Open_Requested(index)), id = skald.hash_id("animation-aseprite-open"),
			bg = th.color.bg, fg = th.color.fg, padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm))
	}
	if s.animEditor.asset != "" {
		append(&views, skald.button(ctx, "Back to the sprite", Msg(Anim_Asset_Shown("")), id = skald.hash_id("animation-asset-close"),
			bg = th.color.bg, fg = th.color.fg, padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm))
	}
	return views[:]
}

// Toolbar, first row: which animation (a dropdown), the list's buttons, its name, "starts with"
@(private="file")
animationPicker :: proc(ctx: ^skald.Ctx(Msg), s: ^State, src: AnimSource, animation: AnimationDef, index, key: int) -> []skald.View {
	tk := uiTokens(ctx)
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
	}, id = skald.hash_id("animation-select"), width = tk.fieldM)
	// The selected animation drags into code by its grip (code_drag.odin)
	owner := src.node != nil ? s.selectedNode : -1
	grip := CodeDrag_Handle(ctx, s, "animation-drag", DropSource{kind = .Animation, name = animation.name, node = owner, index = -1, detail = src.path})
	tool :: proc(ctx: ^skald.Ctx(Msg), key, icon, tip: string, msg: Msg, disabled := false) -> skald.View {
		tk := uiTokens(ctx)
		th := ctx.theme
		button := skald.button(ctx, icon, msg, id = skald.hash_id(key), bg = th.color.bg, fg = th.color.fg_muted,
			width = tk.panelButtonWidth, padding = {0, tk.xxs}, font_size = th.font.size_sm, radius = th.radius.sm, disabled = disabled)
		return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("%s-tip", key)))
	}

	// The name keeps what's typed until it's valid (not empty, not another animation's)
	nameId := skald.hash_id(fmt.tprintf("animation-name-%d", key))
	typing := skald.widget_has_focus(ctx, nameId) && s.animEditor.nameId == nameId && s.animEditor.nameText != animation.name
	name := strings.clone(typing ? s.animEditor.nameText : animation.name, context.temp_allocator)
	problem := typing ? AnimEdit_NameProblem(src.animations[:], index, s.animEditor.nameText) : ""
	nameField := skald.text_input(ctx, name, nameId, proc(id: skald.Widget_ID, v: string) -> Msg { return Anim_Name_Typed{id, v} },
		id = nameId, width = tk.fieldM, padding = InspectorFieldPadding(ctx), invalid = problem != "")
	isFirst := autoplay == animation.name || (autoplay == "" && index == 0)
	first := skald.button(ctx, fmt.tprintf("%s  Starts with this", ICON_STAR), Msg(Anim_Autoplay_Set{}), id = skald.hash_id("animation-autoplay"),
		bg = isFirst ? th.color.primary : th.color.bg, fg = isFirst ? th.color.on_primary : th.color.fg,
		padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm, disabled = autoplay == animation.name || src.readOnly)
	if src.readOnly {
		// Aseprite's tags: which one, and that's all
		groups := make([dynamic]skald.View, context.temp_allocator)
		append(&groups, group(ctx, "", uiText(th, .Label, ICON_FILM), picker, grip))
		return groups[:]
	}
	groups := make([dynamic]skald.View, context.temp_allocator)
	append(&groups,
		group(ctx, "", uiText(th, .Label, ICON_FILM), picker, grip),
		group(ctx, "",
			tool(ctx, "animation-add", ICON_PLUS, "New animation (every frame of this one's sheet)", Msg(Anim_Added{})),
			tool(ctx, "animation-duplicate", ICON_COPY, "Duplicate this animation", Msg(Anim_Duplicated{})),
			tool(ctx, "animation-remove", ICON_TRASH, "Remove this animation (a sprite keeps one)", Msg(Anim_Removed{}), disabled = count <= 1),
			tool(ctx, "animation-up", ICON_ARROW_UP, "Move it up the list", Msg(Anim_Moved(-1)), disabled = index <= 0),
			tool(ctx, "animation-down", ICON_ARROW_DOWN, "Move it down the list", Msg(Anim_Moved(1)), disabled = index >= count - 1)),
		group(ctx, "Name", nameField),
		skald.tooltip(ctx, first, "The sprite plays this animation when the game starts", id = skald.hash_id("animation-autoplay-tip")),
	)
	if problem != "" do append(&groups, uiText(th, .Muted, problem, color = th.color.danger))
	return groups[:]
}

// Toolbar: the animation's frames (first and last, or how many), speed, looping and play mode
@(private="file")
animationDetails :: proc(ctx: ^skald.Ctx(Msg), s: ^State, src: AnimSource, animation: AnimationDef, key, cells: int) -> []skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	start, end := AnimationDef_Range(animation, cells)
	timing := ""
	if len(animation.durations) > 0 && src.readOnly {
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
		append(&groups, uiText(th, .Muted, fmt.tprintf("Frames %d to %d · %v · %s", start, end, animation.playMode, repeat)))
		if timing != "" do append(&groups, uiText(th, .Muted, timing))
		if eventText != "" do append(&groups, uiText(th, .Muted, eventText))
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
		group(ctx, "Count", numberField(ctx, s, fmt.tprintf("animation-count-%d", key), AnimField.Frames, f64(end - start + 1), 1, 0, NUMBER_WIDTH, 1, f64(cells - start))),
		group(ctx, "FPS", numberField(ctx, s, fmt.tprintf("animation-fps-%d", key), AnimField.FPS, f64(animation.fps), 1, 0, NUMBER_WIDTH, 0, 120)),
		skald.checkbox(ctx, animation.loop, "Loop", proc(v: bool) -> Msg { return Anim_Loop_Changed(v) }, id = skald.hash_id(fmt.tprintf("animation-loop-%d", key))),
		skald.select(ctx, fmt.tprintf("%v", animation.playMode), modes, proc(v: string) -> Msg { return Anim_Mode_Changed(v) },
			id = skald.hash_id(fmt.tprintf("animation-mode-%d", key)), width = tk.fieldS),
	)
	// Not looping: how many times it plays
	// (a ping-pong's: passes, one way each; 0 is two, there and back)
	if !animation.loop {
		pingPong := animation.playMode == .PingPong || animation.playMode == .PingPongReverse
		times := pingPong ? (animation.repeat > 0 ? animation.repeat : 2) : max(animation.repeat, 1)
		append(&groups, group(ctx, "Plays", numberField(ctx, s, fmt.tprintf("animation-repeat-%d", key), AnimField.Repeat, f64(times), 1, 0, NUMBER_WIDTH, 1, 1000), toolLabel(ctx, pingPong ? "passes" : "times")))
	}
	// Each frame's own time (in ms), instead of FPS for all
	own := len(animation.durations) > 0
	append(&groups, skald.checkbox(ctx, own, "Frame times", proc(v: bool) -> Msg { return Anim_Durations_Toggled(v) }, id = skald.hash_id(fmt.tprintf("animation-durations-%d", key))))
	if own {
		for frame in 0 ..= end - start {
			ms := frame < len(animation.durations) && animation.durations[frame] > 0 ? animation.durations[frame] * 1000 : AnimEdit_FpsDuration(animation) * 1000
			// Times belong to cells (from the first), whichever way it plays
			cell := start + frame
			append(&groups, group(ctx, fmt.tprintf("%d:", cell),
				numberField(ctx, s, fmt.tprintf("animation-duration-%d-%d", frame, key), AnimDurationTarget(frame), f64(ms), 10, 0, NUMBER_WIDTH, 1, 60000), toolLabel(ctx, "ms")))
		}
		append(&groups, uiText(th, .Muted, "Frame times are in ms; FPS is for frames without one."))
	}
	if eventText != "" do append(&groups, uiText(th, .Muted, eventText))
	return groups[:]
}

// Toolbar: the selected animation's sheet: its image (a dropdown, or an image dropped on the
// panel), its grid (columns x rows, or a cell's size), margin and gap
@(private="file")
sheetSettings :: proc(ctx: ^skald.Ctx(Msg), s: ^State, src: AnimSource, animation: AnimationDef, key, cells: int) -> []skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	groups := make([dynamic]skald.View, context.temp_allocator)
	columns, rows, cell := e.SheetGrid_Layout(animation.grid, AnimEdit_SheetSize(s.project.rootPath, animation.sheet))
	if src.readOnly {
		append(&groups, uiText(th, .Muted, fmt.tprintf("Sheet: %s, every frame, %d x %d", filepath.base(strings.trim_suffix(animation.sheet, e.ASEPRITE_SHEET_SUFFIX)), columns, rows)))
		return groups[:]
	}
	images := make([dynamic]string, context.temp_allocator)
	append(&images, TEXTURE_NONE)
	for asset in s.project.assets do if asset.kind == .Image do append(&images, asset.path)
	sheet := skald.select(ctx, animation.sheet == "" ? TEXTURE_NONE : animation.sheet, images[:], proc(v: string) -> Msg { return Anim_Sheet_Texture_Changed(v) },
		id = skald.hash_id(fmt.tprintf("animation-sheet-%d", key)), width = tk.fieldM, placeholder = "Choose an image")
	// The sprite sheet slicer, on this sheet (slicer_edit.odin)
	slice := skald.tooltip(ctx, skald.button(ctx, fmt.tprintf("%s  Slice a sheet…", ICON_SCISSORS), Msg(Slicer_Opened(strings.clone(animation.sheet, context.temp_allocator))),
		id = skald.hash_id("animation-slice"), bg = th.color.bg, fg = th.color.fg, padding = tk.fieldPadding, font_size = th.font.size_xs,
		radius = th.radius.sm, disabled = animation.sheet == ""),
		"Open the sheet in the sprite sheet slicer: cut it by a grid or find its sprites, pick frames, name animations", id = skald.hash_id("animation-slice-tip"))
	if len(animation.rects) > 0 {
		// A sliced sheet: its cells are rectangles (no grid to edit here)
		append(&groups,
			group(ctx, "Sheet", sheet),
			uiText(th, .Muted, fmt.tprintf("%d frames sliced from the sheet (each its own rectangle)", len(animation.rects))),
			slice,
			skald.button(ctx, "Use a grid instead", Msg(Anim_Rects_Cleared{}), id = skald.hash_id("animation-rects-clear"),
				bg = th.color.bg, fg = th.color.fg, padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm),
		)
		return groups[:]
	}
	modes := make([]string, len(e.SheetGridMode), context.temp_allocator)
	for mode in e.SheetGridMode do modes[mode] = fmt.tprintf("%v", mode)
	gridMode := skald.select(ctx, fmt.tprintf("%v", animation.grid.mode), modes, proc(v: string) -> Msg { return Anim_Grid_Mode_Changed(v) },
		id = skald.hash_id(fmt.tprintf("animation-grid-%d", key)), width = tk.fieldXS)
	number :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: AnimField, value: f32, lo, hi: f64) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("animation-%v-%d", field, key), field, f64(value), 1, 0, NUMBER_WIDTH, lo, hi)
	}
	// The grid's values: columns x rows, or a cell's size; the other is shown, worked out from the image
	values, derived: skald.View
	switch animation.grid.mode {
	case .Cells:
		values = group(ctx, "", number(ctx, s, key, .Columns, f32(max(animation.grid.columns, 1)), 1, 256), toolLabel(ctx, "×"), number(ctx, s, key, .Rows, f32(max(animation.grid.rows, 1)), 1, 256))
		derived = uiText(th, .Muted, cell.x > 0 && cell.y > 0 ? fmt.tprintf("cells %.0f × %.0f px", cell.x, cell.y) : "")
	case .Size:
		values = group(ctx, "", number(ctx, s, key, .Cell_Width, animation.grid.cellSize.x, 1, 4096), toolLabel(ctx, "×"), number(ctx, s, key, .Cell_Height, animation.grid.cellSize.y, 1, 4096), toolLabel(ctx, "px"))
		derived = uiText(th, .Muted, fmt.tprintf("%d × %d cells", columns, rows))
	}
	note := AnimEdit_SheetNote(s.project.rootPath, animation)
	append(&groups,
		group(ctx, "Sheet", sheet),
		group(ctx, "Grid", gridMode),
		values,
		group(ctx, "Margin", number(ctx, s, key, .Margin, animation.grid.margin, 0, 1000)),
		group(ctx, "Gap", number(ctx, s, key, .Spacing, animation.grid.spacing, 0, 1000)),
		group(ctx, "Offset", number(ctx, s, key, .Offset_X, animation.grid.offset.x, 0, 4096), toolLabel(ctx, ","), number(ctx, s, key, .Offset_Y, animation.grid.offset.y, 0, 4096)),
		uiText(th, .Muted, fmt.tprintf("%d frames", cells)),
		derived,
		slice,
	)
	if note != "" do append(&groups, uiText(th, .Muted, note, color = th.color.warning))
	if animation.sheet == "" do append(&groups, uiText(th, .Muted, "Pick a sheet, or drag an image from the browser onto this panel.", color = th.color.warning))
	return groups[:]
}

@(private="file")
toolLabel :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
	return uiText(ctx.theme, .Label, text)
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
		grid: e.SheetGrid,
		rects: []sdl.FRect,
		cells, perRow, start, end, current: int,
		lit, dim, edge, current_color, text, muted: skald.Color,
		font: f32,
	}
	strip := new_clone(Strip{
		sheet = sheet, grid = animation.grid, rects = slice.clone(animation.rects[:], context.temp_allocator), cells = cells, perRow = perRow, start = start, end = end,
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
			drawCell(p.r, st.sheet, st.grid, st.rects, frame, box, inRange ? {1, 1, 1, 1} : {1, 1, 1, 0.35})
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
	tk := uiTokens(ctx)
	th := ctx.theme
	start, end := AnimationDef_Range(animation, cells)
	backwards := animation.playMode == .Reverse || animation.playMode == .PingPongReverse
	frame := s.animEditor.playing ? AnimationDef_FrameAt(animation, cells, s.animEditor.clock) : (backwards ? end : start)
	Preview :: struct { sheet: SheetImage, grid: e.SheetGrid, rects: []sdl.FRect, frame: int, bg, edge: skald.Color }
	preview := new_clone(Preview{sheet, animation.grid, slice.clone(animation.rects[:], context.temp_allocator), frame, th.color.surface, th.color.border}, context.temp_allocator)
	canvas := skald.canvas(ctx, preview, proc(pv: ^Preview, p: skald.Canvas_Painter) {
		skald.draw_rect(p.r, p.bounds, pv.bg, 4)
		drawCell(p.r, pv.sheet, pv.grid, pv.rects, pv.frame, {p.bounds.x + 4, p.bounds.y + 4, p.bounds.w - 8, p.bounds.h - 8}, {1, 1, 1, 1})
		ring(p.r, p.bounds, pv.edge, 1)
	}, id = skald.hash_id("animation-preview"), width = PREVIEW_SIZE, height = PREVIEW_SIZE)
	playing := s.animEditor.playing
	play := skald.button(ctx, playing ? ICON_PAUSE : ICON_PLAY, Msg(Anim_Playback_Toggled{}), id = skald.hash_id("animation-play"),
		bg = th.color.surface, fg = th.color.fg, width = tk.panelButtonWidth, padding = {0, tk.xxs}, font_size = th.font.size_sm, radius = th.radius.sm)
	return skald.col(
		canvas,
		skald.row(
			skald.tooltip(ctx, play, playing ? "Pause the preview" : "Play the preview", id = skald.hash_id("animation-play-tip")),
			uiText(th, .Muted, fmt.tprintf("frame %d · %d of %d", frame, frame - start + 1, end - start + 1)),
			spacing = th.spacing.xs, cross_align = .Center,
		),
		uiText(th, .Muted, "Click a frame: start there. Shift+click: end there.", max_width = PREVIEW_SIZE),
		spacing = th.spacing.xs,
		width = PREVIEW_SIZE,
	)
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
An animation's sprite sheet as a Skald image, loaded (`Image_LoadRGBA`: stb_image, or the engine for
Aseprite files) and uploaded the first time (the sprite sheet slicer's sheet too).
*/
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

/*
Whether the mouse is over the Animation panel showing an animation it can edit (a sheet dragged
from the browser drops there).
*/
AnimationPanel_TakesDrop :: proc(s: ^State, ctx: ^skald.Ctx(Msg), mouse: [2]f32) -> bool {
	if s.bottomTab != .Animation || !s.layout.bottomOpen do return false
	src, animation, _ := AnimEdit_Selection(s)
	if animation == nil || src.readOnly do return false
	state, drawn := ctx.widgets.states[skald.hash_id("animation-scroll")]
	if !drawn do return false
	area := state.clip_rect.w > 0 ? state.clip_rect : state.last_rect
	return pointIn(area, mouse)
}

// Whether the panel has uploaded a sheet (for the UI tests: thumbnails can be drawn)
AnimationPanel_SheetLoaded :: proc(s: ^State, texture: string) -> bool {
	path := joinPath(s.project.rootPath, texture, allocator = context.temp_allocator)
	for key, image in sheets do if strings.has_prefix(key, fmt.tprintf("%s@", path)) && image.name != "" do return true
	return false
}

// Draws one cell of a sheet (its grid's, or its rectangle) into `box`, keeping its shape (centered)
@(private="file")
drawCell :: proc(r: ^skald.Renderer, sheet: SheetImage, grid: e.SheetGrid, rects: []sdl.FRect, frame: int, box: skald.Rect, tint: skald.Color) {
	if sheet.name == "" do return
	cell := e.Sheet_CellRect(grid, rects, sheet.size, frame)
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
