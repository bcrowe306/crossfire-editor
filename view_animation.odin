package editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import e "engine:."
import stbi "vendor:stb/image"

/*
The Animation panel (the bottom panel's Animation tab): the animation editor for the selected
AnimatedSprite.

	+--------------+------------------------------------------------+-------------+
	| Animations   | Name [walk]  Start [0]  End [3]  FPS [10]  ...  |   preview   |
	|  * walk 0-3  | Sheet [hero.png]  Columns [4]  Rows [2]  ...    |   (plays)   |
	|    jump 4-7  | [0][1][2][3]  frame thumbnails: the selected    |  > 2 / 4    |
	| + dup - up dn|  [4][5][6][7] animation's frames lit           |             |
	+--------------+------------------------------------------------+-------------+

- The list: select an animation; add, duplicate, remove, move up and down. The star marks the
  one the sprite starts with (set it with the star button, or the inspector's Starts with).
- The selected animation's name, first and last frame, speed, looping and play mode.
- The sprite sheet: image and grid (the same as the inspector's), and a thumbnail of every cell.
  Click a thumbnail to start the animation there, Shift+click to end it there.
- The preview plays the animation as the game will (`AnimationDef_FrameAt`); the viewport plays
  it on the sprite too.

Logic and messages: animation_edit.odin. Widget keys: `animation-list-<i>`, `animation-add`,
`animation-duplicate`, `animation-remove`, `animation-up`, `animation-down`, `animation-name-<node>`,
`animation-start-<node>`, `animation-end-<node>`, `animation-fps-<node>`, `animation-loop-<node>`,
`animation-mode-<node>`, `animation-autoplay`, `animation-frames` (the thumbnails),
`animation-preview`, `animation-play`.
*/

// Thumbnail size and gap in the frame strip
@(private="file")
THUMB_SIZE :: 56
@(private="file")
THUMB_GAP :: 6
@(private="file")
LIST_WIDTH :: 170
@(private="file")
PREVIEW_WIDTH :: 150

AnimationPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	node, animation, index := AnimEdit_Selection(s)
	if node == nil do return placeholder(ctx, "Select an AnimatedSprite node to edit its animations.")
	if animation == nil do return placeholder(ctx, fmt.tprintf("%s has no animations.", node.name))
	sheet := sheetImage(ctx, s, node.texture)
	cells := max(node.columns * node.rows, 1)
	key := s.selectedNode

	// Keep the preview's frames coming while it plays
	if s.animEditor.playing && !s.animEditor.tickPending && EditorFocused() do skald.send(ctx, Msg(Anim_Tick_Requested{}))

	// Side by side when the center column has room; stacked in one scroll when it hasn't
	left, right := FittedSidebarWidths(&s.layout)
	centerWidth := s.layout.workspace.x - left - right - DIVIDER * 2
	gap := th.spacing.sm
	wide := centerWidth >= LIST_WIDTH + FORM_WIDTH + PREVIEW_WIDTH + THUMB_SIZE * 3 + gap * 8
	if wide {
		stripWidth := centerWidth - LIST_WIDTH - FORM_WIDTH - PREVIEW_WIDTH - gap * 8
		return skald.row(
			animationList(ctx, s, node, index, true),
			skald.scroll(ctx, {FORM_WIDTH, 0}, animationForm(ctx, s, node, animation^, index, key, cells), id = skald.hash_id("animation-form-scroll")),
			skald.flex(1, skald.scroll(ctx, {0, 0}, frameStrip(ctx, s, node, animation^, sheet, cells, stripWidth), id = skald.hash_id("animation-frames-scroll"))),
			animationPreview(ctx, s, node, animation^, sheet, cells),
			spacing = gap,
			padding = gap,
			cross_align = .Stretch,
		)
	}
	return skald.scroll(ctx, {0, 0}, skald.col(
		animationList(ctx, s, node, index, false),
		skald.divider(ctx),
		animationForm(ctx, s, node, animation^, index, key, cells),
		skald.divider(ctx),
		frameStrip(ctx, s, node, animation^, sheet, cells, max(centerWidth - gap * 4 - INSPECTOR_SCROLLBAR_WIDTH, THUMB_SIZE)),
		animationPreview(ctx, s, node, animation^, sheet, cells),
		spacing = gap,
		padding = gap,
	), id = skald.hash_id("animation-scroll"))
}

// The node's animations, with the list's buttons (`scrolls`: in its own scroll, side by side)
@(private="file")
animationList :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, selected: int, scrolls: bool) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	for a, i in node.animations {
		cells := max(node.columns * node.rows, 1)
		start, end := AnimationDef_Range(a, cells)
		first := node.autoplay == a.name || (node.autoplay == "" && i == 0)
		label := fmt.tprintf("%s %s   %d–%d", first ? ICON_STAR : "  ", a.name, start, end)
		on := i == selected
		append(&rows, skald.button(ctx, label, Msg(Anim_Selected(i)), id = skald.hash_id(fmt.tprintf("animation-list-%d", i)),
			bg = on ? th.color.primary : th.color.surface, fg = on ? th.color.on_primary : th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_sm, radius = th.radius.sm, width = LIST_WIDTH - 12, text_align = .Start))
	}
	tool :: proc(ctx: ^skald.Ctx(Msg), key, icon, tip: string, msg: Msg, disabled := false) -> skald.View {
		th := ctx.theme
		button := skald.button(ctx, icon, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg_muted,
			width = 26, padding = {0, 2}, font_size = th.font.size_sm, radius = th.radius.sm, disabled = disabled)
		return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("%s-tip", key)))
	}
	count := len(node.animations)
	list := skald.col(..rows[:], spacing = 2)
	return skald.col(
		skald.text(fmt.tprintf("%s  Animations", ICON_FILM), th.color.fg, th.font.size_sm),
		scrolls ? skald.flex(1, skald.scroll(ctx, {0, 0}, list, id = skald.hash_id("animation-list-scroll"))) : list,
		skald.row(
			tool(ctx, "animation-add", ICON_PLUS, "New animation (every frame)", Msg(Anim_Added{})),
			tool(ctx, "animation-duplicate", ICON_COPY, "Duplicate the selected animation", Msg(Anim_Duplicated{})),
			tool(ctx, "animation-remove", ICON_TRASH, "Remove the selected animation (a sprite keeps one)", Msg(Anim_Removed{}), disabled = count <= 1),
			tool(ctx, "animation-up", ICON_ARROW_UP, "Move up", Msg(Anim_Moved(-1)), disabled = selected <= 0),
			tool(ctx, "animation-down", ICON_ARROW_DOWN, "Move down", Msg(Anim_Moved(1)), disabled = selected >= count - 1),
			spacing = 2,
		),
		spacing = th.spacing.xs,
		width = LIST_WIDTH,
	)
}

/*
The selected animation's name, frames, speed, looping, play mode and "starts with", then the
sprite sheet: image and grid (the inspector edits the same fields).
*/
@(private="file")
animationForm :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, animation: AnimationDef, index, key, cells: int) -> skald.View {
	th := ctx.theme
	start, end := AnimationDef_Range(animation, cells)
	field :: proc(ctx: ^skald.Ctx(Msg), label: string, controls: ..skald.View) -> skald.View {
		th := ctx.theme
		views := make([dynamic]skald.View, context.temp_allocator)
		append(&views, skald.col(skald.text(label, th.color.fg_muted, th.font.size_sm), width = 58))
		append(&views, ..controls)
		return skald.row(..views[:], spacing = th.spacing.xs, cross_align = .Center)
	}
	small :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
		return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs)
	}
	NUMBER :: 76
	// The name keeps what's typed until it's valid (not empty, not another animation's)
	nameId := skald.hash_id(fmt.tprintf("animation-name-%d", key))
	focused := skald.widget_has_focus(ctx, nameId)
	typing := focused && s.animEditor.nameId == nameId && s.animEditor.nameText != animation.name
	name := typing ? strings.clone(s.animEditor.nameText, context.temp_allocator) : strings.clone(animation.name, context.temp_allocator)
	problem := typing ? AnimEdit_NameProblem(node, index, s.animEditor.nameText) : ""
	nameField := skald.text_input(ctx, name, nameId, proc(id: skald.Widget_ID, v: string) -> Msg { return Anim_Name_Typed{id, v} },
		id = nameId, width = FORM_WIDTH - 70, padding = InspectorFieldPadding(ctx), invalid = problem != "")
	modes := make([]string, len(e.AnimationPlayMode), context.temp_allocator)
	for mode in e.AnimationPlayMode do modes[mode] = fmt.tprintf("%v", mode)
	isFirst := node.autoplay == animation.name || (node.autoplay == "" && index == 0)
	first := skald.button(ctx, fmt.tprintf("%s  Starts with this", ICON_STAR), Msg(Anim_Autoplay_Set{}), id = skald.hash_id("animation-autoplay"),
		bg = isFirst ? th.color.primary : th.color.surface, fg = isFirst ? th.color.on_primary : th.color.fg,
		padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = node.autoplay == animation.name)
	images := make([dynamic]string, context.temp_allocator)
	append(&images, TEXTURE_NONE)
	for asset in s.project.assets do if asset.kind == .Image do append(&images, asset.path)
	sheetNumber :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: NodeField, value: f32, lo, hi: f64) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("animation-%v-%d", field, key), field, f64(value), 1, 0, NUMBER, lo, hi)
	}
	return skald.col(
		field(ctx, "Name", nameField),
		problem != "" ? skald.text(problem, th.color.danger, th.font.size_xs) : skald.View(skald.View_Spacer{size = 0}),
		field(ctx, "Frames",
			numberField(ctx, s, fmt.tprintf("animation-start-%d", key), AnimField.Start, f64(start), 1, 0, NUMBER, 0, f64(cells - 1)),
			small(ctx, "to"),
			numberField(ctx, s, fmt.tprintf("animation-end-%d", key), AnimField.End, f64(end), 1, 0, NUMBER, 0, f64(cells - 1))),
		field(ctx, "FPS", numberField(ctx, s, fmt.tprintf("animation-fps-%d", key), AnimField.FPS, f64(animation.fps), 1, 0, NUMBER, 0, 120),
			skald.checkbox(ctx, animation.loop, "Loop", proc(v: bool) -> Msg { return Anim_Loop_Changed(v) }, id = skald.hash_id(fmt.tprintf("animation-loop-%d", key)))),
		field(ctx, "Mode", skald.select(ctx, fmt.tprintf("%v", animation.playMode), modes, proc(v: string) -> Msg { return Anim_Mode_Changed(v) },
			id = skald.hash_id(fmt.tprintf("animation-mode-%d", key)), width = 120)),
		field(ctx, "", skald.tooltip(ctx, first, "The sprite plays this animation when the game starts", id = skald.hash_id("animation-autoplay-tip"))),
		skald.text("Sprite sheet", th.color.fg, th.font.size_xs),
		field(ctx, "Image", skald.select(ctx, node.texture == "" ? TEXTURE_NONE : node.texture, images[:], NodeTextField.Texture,
			proc(field: NodeTextField, v: string) -> Msg { return Node_Text_Changed{field, v} },
			id = skald.hash_id(fmt.tprintf("animation-sheet-%d", key)), width = FORM_WIDTH - 70, placeholder = "Choose an image")),
		field(ctx, "Grid", sheetNumber(ctx, s, key, .Columns, f32(node.columns), 1, 64), small(ctx, "×"), sheetNumber(ctx, s, key, .Rows, f32(node.rows), 1, 64)),
		field(ctx, "Margin", sheetNumber(ctx, s, key, .Margin, node.margin, 0, 1000), small(ctx, "gap"), sheetNumber(ctx, s, key, .Spacing, node.spacing, 0, 1000)),
		small(ctx, fmt.tprintf("%d frames. Click a frame to start there, Shift+click to end there.", cells)),
		spacing = th.spacing.xs,
		width = FORM_WIDTH,
	)
}

@(private="file")
FORM_WIDTH :: 250

/*
A thumbnail of every cell of the sheet, wrapped to `width`: the selected animation's cells lit,
its first and last marked, the preview's current frame outlined. Click sets the start,
Shift+click the end.
*/
@(private="file")
frameStrip :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, animation: AnimationDef, sheet: SheetImage, cells: int, width: f32) -> skald.View {
	th := ctx.theme
	id := skald.hash_id("animation-frames")
	perRow := max(int((width + THUMB_GAP) / (THUMB_SIZE + THUMB_GAP)), 1)
	stripColumns = perRow
	rowCount := (cells + perRow - 1) / perRow
	height := f32(rowCount) * (THUMB_SIZE + THUMB_GAP + 12)

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
		sheet = sheet, grid = gridOf(node), cells = cells, perRow = perRow, start = start, end = end,
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
			skald.draw_text(p.r, caption, x, y + THUMB_SIZE + 1, inRange ? st.text : st.muted, st.font)
		}
	}, id = id, width = width, height = height, cursor = .Pointer)
}

// The selected animation playing (or its first frame while paused), with play / pause
@(private="file")
animationPreview :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, animation: AnimationDef, sheet: SheetImage, cells: int) -> skald.View {
	th := ctx.theme
	start, end := AnimationDef_Range(animation, cells)
	frame := s.animEditor.playing ? AnimationDef_FrameAt(animation, cells, s.animEditor.clock) : (animation.playMode == .Reverse ? end : start)
	Preview :: struct { sheet: SheetImage, grid: SheetGrid, frame: int, bg, edge: skald.Color }
	preview := new_clone(Preview{sheet, gridOf(node), frame, th.color.surface, th.color.border}, context.temp_allocator)
	size := f32(PREVIEW_WIDTH - 10)
	canvas := skald.canvas(ctx, preview, proc(pv: ^Preview, p: skald.Canvas_Painter) {
		skald.draw_rect(p.r, p.bounds, pv.bg, 4)
		drawCell(p.r, pv.sheet, pv.grid, pv.frame, {p.bounds.x + 4, p.bounds.y + 4, p.bounds.w - 8, p.bounds.h - 8}, {1, 1, 1, 1})
		ring(p.r, p.bounds, pv.edge, 1)
	}, id = skald.hash_id("animation-preview"), width = size, height = size)
	playing := s.animEditor.playing
	play := skald.button(ctx, playing ? ICON_PAUSE : ICON_PLAY, Msg(Anim_Playback_Toggled{}), id = skald.hash_id("animation-play"),
		bg = th.color.surface, fg = th.color.fg, width = 30, padding = {0, 2}, font_size = th.font.size_sm, radius = th.radius.sm)
	return skald.col(
		canvas,
		skald.row(
			skald.tooltip(ctx, play, playing ? "Pause the preview" : "Play the preview", id = skald.hash_id("animation-play-tip")),
			skald.text(fmt.tprintf("frame %d (%d of %d)", frame, frame - start + 1, end - start + 1), th.color.fg_muted, th.font.size_xs),
			spacing = th.spacing.xs, cross_align = .Center,
		),
		spacing = th.spacing.xs,
		width = PREVIEW_WIDTH,
	)
}

// A sheet's grid (what drawing a cell needs from the node)
@(private="file")
SheetGrid :: struct {
	columns, rows: int,
	margin, spacing: f32,
}

@(private="file")
gridOf :: proc(node: ^NodeDef) -> SheetGrid {
	return {node.columns, node.rows, node.margin, node.spacing}
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
The node's sprite sheet as a Skald image, loaded (with stb_image) and uploaded the first time.
*/
@(private="file")
sheetImage :: proc(ctx: ^skald.Ctx(Msg), s: ^State, texture: string) -> SheetImage {
	if texture == "" || ctx.renderer == nil do return {}
	path := joinPath(s.project.rootPath, texture, allocator = context.temp_allocator)
	if image, known := sheets[path]; known do return image
	image: SheetImage
	w, h, channels: i32
	pixels := stbi.load(strings.clone_to_cstring(path, context.temp_allocator), &w, &h, &channels, 4)
	if pixels != nil {
		defer stbi.image_free(pixels)
		name := fmt.aprintf("animation-sheet:%s", path)
		if skald.image_load_pixels(ctx.renderer, name, u32(w), u32(h), pixels[:w * h * 4]) {
			image = {name, {f32(w), f32(h)}}
		} else {
			delete(name)
		}
	}
	sheets[strings.clone(path)] = image
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
	image, known := sheets[joinPath(s.project.rootPath, texture, allocator = context.temp_allocator)]
	return known && image.name != ""
}

/*
Draws one cell of a sheet into `box`, keeping its shape: the whole sheet is drawn scaled and
offset so the cell lands in the box, clipped to it.
*/
@(private="file")
drawCell :: proc(r: ^skald.Renderer, sheet: SheetImage, grid: SheetGrid, frame: int, box: skald.Rect, tint: skald.Color) {
	if sheet.name == "" do return
	cell := e.SpriteSheet_CellRect(sheet.size, grid.columns, grid.rows, grid.margin, grid.spacing, frame)
	if cell.w <= 0 || cell.h <= 0 do return
	scale := min(box.w / cell.w, box.h / cell.h)
	shown := skald.Rect{box.x + (box.w - cell.w * scale) * 0.5, box.y + (box.h - cell.h * scale) * 0.5, cell.w * scale, cell.h * scale}
	skald.push_clip(r, shown)
	skald.draw_image(r, sheet.name, {shown.x - cell.x * scale, shown.y - cell.y * scale, sheet.size.x * scale, sheet.size.y * scale}, .Fill, tint)
	skald.pop_clip(r)
}

@(private="file")
ring :: proc(r: ^skald.Renderer, b: skald.Rect, color: skald.Color, width: f32) {
	skald.draw_rect(r, {b.x, b.y, b.w, width}, color)
	skald.draw_rect(r, {b.x, b.y + b.h - width, b.w, width}, color)
	skald.draw_rect(r, {b.x, b.y, width, b.h}, color)
	skald.draw_rect(r, {b.x + b.w - width, b.y, width, b.h}, color)
}
