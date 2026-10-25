package crossfire_editor

import "gui:skald"

/*
The tree widget used by the project browser and the scene tree. It behaves like `skald.tree`
(same mouse and keyboard handling, same messages, rows reported by index, the widget's rect stored
under its id so test scripts can click rows), but each row also has its own icon and label color,
so node kinds and asset types are told apart at a glance. Skald's tree draws every row in the
theme's colors and has no per-row option.

Mouse: press on a row's chevron toggles it; press on the row selects it; a double-click on an
expandable row also toggles it. Keyboard (when focused): Up/Down/Home/End move the selection,
Right expands, Left collapses or jumps to the parent, Enter/Space toggles.
*/

ColoredTreeRow :: struct {
	depth: int,
	label: string,
	icon: string,
	expandable: bool,
	expanded: bool,
	selected: bool,
	// {} for the theme's default (muted icon, normal label)
	iconColor: skald.Color,
	labelColor: skald.Color,
	// A small icon after the label ("" for none: the scene tree marks nodes with a script)
	badge: string,
	badgeColor: skald.Color,
}

/*
Scrolls a tree's scroll so its selected row is wholly in view, when the selection has moved to
another row since the last call (a click on a half-hidden row, a node picked in the viewport, the
arrow keys), so wheeling away from a selection isn't undone. Call it before building the scroll,
which must have `reveal_focus = false`: that would show the focused tree, taller than the view,
from its top, and scroll the clicked row away.
*/
Tree_RevealSelected :: proc(ctx: ^skald.Ctx(Msg), rows: []ColoredTreeRow, treeKey, scrollKey: string, rowHeight: f32) {
	treeId := skald.hash_id(treeKey)
	selected := -1
	for r, i in rows do if r.selected {
		selected = i
		break
	}
	last, known := treeRevealed[treeId]
	treeRevealed[treeId] = selected
	if selected < 0 || (known && last == selected) do return
	tree, drawn := ctx.widgets.states[treeId]
	scroll, scrollDrawn := &ctx.widgets.states[skald.hash_id(scrollKey)]
	if !drawn || !scrollDrawn || scroll.last_rect.h <= 0 do return
	area := scroll.last_rect
	top := tree.last_rect.y + f32(selected) * rowHeight
	MARGIN :: f32(4)
	if top + rowHeight + MARGIN > area.y + area.h {
		scroll.scroll_y += top + rowHeight + MARGIN - (area.y + area.h)
	} else if top - MARGIN < area.y {
		scroll.scroll_y = max(scroll.scroll_y - (area.y - top + MARGIN), 0)
	} else {
		return
	}
	skald.send(ctx, Msg(Frame_Requested{}))
}

/*
When a click inside a scroll ends on a control that's partly out of its view, scrolls just enough
to show all of it (Skald's scroll only reveals controls that take keyboard focus). On release, so
the control doesn't move away between the press and the release of its own click. Call it before
building the scroll.
*/
Scroll_RevealClicked :: proc(ctx: ^skald.Ctx(Msg), scrollKey: string) {
	if !ctx.input.mouse_released[.Left] do return
	scroll, drawn := &ctx.widgets.states[skald.hash_id(scrollKey)]
	if !drawn || scroll.last_rect.h <= 0 do return
	area := scroll.last_rect
	mouse := ctx.input.mouse_pos
	inside :: proc(r: skald.Rect, p: [2]f32) -> bool { return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h }
	if !inside(area, mouse) || skald.mouse_over_overlay(ctx) do return
	// The smallest control drawn last frame inside this scroll, under the pointer
	best: skald.Rect
	found := false
	for id, st in ctx.widgets.states {
		if !skald.widget_drawn_last_frame(ctx.widgets, st) || id == skald.hash_id(scrollKey) do continue
		c := st.clip_rect
		if c.w <= 0 || c.x < area.x - 0.5 || c.y < area.y - 0.5 || c.x + c.w > area.x + area.w + 0.5 || c.y + c.h > area.y + area.h + 0.5 do continue
		r := st.last_rect
		if !inside(r, mouse) || r.h >= area.h do continue
		if !found || r.w * r.h < best.w * best.h {
			best = r
			found = true
		}
	}
	if !found do return
	MARGIN :: f32(6)
	if best.y + best.h + MARGIN > area.y + area.h {
		scroll.scroll_y += best.y + best.h + MARGIN - (area.y + area.h)
	} else if best.y - MARGIN < area.y {
		scroll.scroll_y = max(scroll.scroll_y - (area.y - best.y + MARGIN), 0)
	} else {
		return
	}
	skald.send(ctx, Msg(Frame_Requested{}))
}

// The row each tree last revealed (Tree_RevealSelected), by widget id
@(private="file")
treeRevealed: map[skald.Widget_ID]int

coloredTree :: proc(
	ctx: ^skald.Ctx(Msg),
	rows: []ColoredTreeRow,
	on_toggle: proc(row: int) -> Msg,
	on_select: proc(row: int) -> Msg,
	id: skald.Widget_ID,
	row_height: f32,
) -> skald.View {
	th := ctx.theme
	skald.widget_make_focusable(ctx, id)
	st := skald.widget_get(ctx, id, .Tree)
	focused := skald.widget_has_focus(ctx, id)

	fs := th.font.size_md
	rh := row_height
	indent := th.spacing.lg
	CHEVRON_WIDTH :: f32(16)
	padX := th.spacing.sm
	iconGap := th.spacing.xs
	rect := st.last_rect

	selectedRow := -1
	for r, i in rows do if r.selected && selectedRow < 0 do selectedRow = i
	cursor := selectedRow
	if cursor < 0 && st.cursor_pos > 0 && st.cursor_pos - 1 < len(rows) do cursor = st.cursor_pos - 1

	// Mouse: from last frame's rect, rows stacked from its top
	mouse := ctx.input.mouse_pos
	// Not through a dialog or a popup (a dialog's button over the tree would also select a row)
	blocked := ctx.widgets.modal_rect_prev.w > 0 || skald.mouse_over_overlay(ctx)
	// The rows' rect runs past the scroll view around the tree when it's scrolled or taller than
	// it: only the visible part takes clicks (otherwise a click on the inspector under the scene
	// tree selected the hidden row "behind" it)
	visible := st.clip_rect.w > 0 ? st.clip_rect : rect
	inside :: proc(r: skald.Rect, p: [2]f32) -> bool { return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h }
	if ctx.input.mouse_pressed[.Left] && !blocked && rect.w > 0 && inside(rect, mouse) && inside(visible, mouse) {
		i := int((mouse.y - rect.y) / rh)
		if i >= 0 && i < len(rows) {
			r := rows[i]
			chevronX := rect.x + padX + f32(r.depth) * indent
			onChevron := mouse.x >= chevronX && mouse.x < chevronX + CHEVRON_WIDTH
			if r.expandable && onChevron {
				skald.send(ctx, on_toggle(i))
			} else {
				skald.send(ctx, on_select(i))
				cursor = i
				skald.widget_focus(ctx, id)
				focused = true
				if r.expandable && ctx.input.mouse_click_count[.Left] >= 2 do skald.send(ctx, on_toggle(i))
			}
		}
	}

	if focused && len(rows) > 0 {
		keys := ctx.input.keys_pressed
		if cursor < 0 do cursor = 0
		move :: proc(ctx: ^skald.Ctx(Msg), on_select: proc(row: int) -> Msg, to: int, cursor: ^int) {
			cursor^ = to
			skald.send(ctx, on_select(to))
		}
		switch {
		case .Down in keys && cursor < len(rows) - 1: move(ctx, on_select, cursor + 1, &cursor)
		case .Up in keys && cursor > 0:                move(ctx, on_select, cursor - 1, &cursor)
		case .Home in keys:                            move(ctx, on_select, 0, &cursor)
		case .End in keys:                             move(ctx, on_select, len(rows) - 1, &cursor)
		}
		r := rows[cursor]
		if .Right in keys && r.expandable && !r.expanded do skald.send(ctx, on_toggle(cursor))
		if .Left in keys {
			if r.expandable && r.expanded {
				skald.send(ctx, on_toggle(cursor))
			} else if r.depth > 0 {
				for j := cursor - 1; j >= 0; j -= 1 {
					if rows[j].depth < r.depth {
						move(ctx, on_select, j, &cursor)
						break
					}
				}
			}
		}
		if (.Enter in keys || .Space in keys) && r.expandable do skald.send(ctx, on_toggle(cursor))
	}
	st.cursor_pos = cursor + 1
	skald.widget_set(ctx, id, st)

	views := make([]skald.View, len(rows), context.temp_allocator)
	for r, i in rows {
		bg := skald.Color{}
		iconColor := r.iconColor[3] > 0 ? r.iconColor : th.color.fg_muted
		labelColor := r.labelColor[3] > 0 ? r.labelColor : th.color.fg
		chevronColor := th.color.fg_muted
		switch {
		case r.selected && focused:
			bg = th.color.primary
			iconColor, labelColor, chevronColor = th.color.on_primary, th.color.on_primary, th.color.on_primary
		case r.selected:
			bg = skald.selected_inactive_bg_for(th^)
		case focused && i == cursor:
			bg = th.color.selection
		}
		chevron := r.expandable ? (r.expanded ? "▼" : "▶") : "  "
		children := make([dynamic]skald.View, context.temp_allocator)
		append(&children,
			skald.spacer(padX + f32(r.depth) * indent),
			skald.col(skald.text(chevron, chevronColor, fs), width = CHEVRON_WIDTH, height = rh, main_align = .Center, cross_align = .Center),
		)
		if r.icon != "" do append(&children, skald.spacer(iconGap), skald.text(r.icon, iconColor, fs))
		append(&children, skald.spacer(iconGap), skald.text(r.label, labelColor, fs))
		if r.badge != "" {
			badgeColor := r.selected ? th.color.on_primary : (r.badgeColor[3] > 0 ? r.badgeColor : th.color.fg_muted)
			append(&children, skald.spacer(iconGap * 2), skald.text(r.badge, badgeColor, th.font.size_xs))
		}
		append(&children, skald.flex(1, skald.spacer(0)))
		views[i] = skald.row(..children[:], height = rh, cross_align = .Center, bg = bg, radius = th.radius.sm)
	}
	// A bare zone, as skald.tree does: it records the rect under `id` without `skald.zone`'s click
	// state, which would claim the slot with another widget kind and reset this tree's state
	content := new(skald.View, context.temp_allocator)
	content^ = skald.col(..views, cross_align = .Stretch)
	return skald.View_Zone{id = id, child = content}
}

/*
A label color tinted toward a type's color: readable as text, but still clearly that type's.
*/
TintLabel :: proc(th: ^skald.Theme, color: skald.Color, amount: f32 = 0.45) -> skald.Color {
	fg := th.color.fg
	return {fg[0] + (color[0] - fg[0]) * amount, fg[1] + (color[1] - fg[1]) * amount, fg[2] + (color[2] - fg[2]) * amount, 1}
}

// Browser colors: folders, scenes, and each asset kind
BrowserItemColor :: proc(state: ^State, item: BrowserItem) -> skald.Color {
	switch item.kind {
	case .Folder:
		switch item.folder {
		case .Scenes: return SCENE_COLOR
		case .Scripts: return SCRIPT_COLOR
		case .Images: return assetKindColor(.Image)
		case .Audio:  return assetKindColor(.Audio)
		case .Music:  return assetKindColor(.Music)
		case .Fonts:  return assetKindColor(.Font)
		case .Data:   return assetKindColor(.Data)
		case .Components: return assetKindColor(.Component)
		case .Levels: return assetKindColor(.LDtk)
		case .Translations: return assetKindColor(.Translation)
		case .Animations: return assetKindColor(.Animation)
		case .Themes: return assetKindColor(.Theme)
		case .Materials: return assetKindColor(.PhysicsMaterial)
		case .Atlases: return assetKindColor(.Atlas)
		case .Dialogues: return assetKindColor(.Dialogue)
		case .Shaders: return assetKindColor(.Shader)
		}
	case .Scene: return SCENE_COLOR
	case .Script: return SCRIPT_COLOR
	case .Asset: return assetKindColor(state.project.assets[item.index].kind)
	case .None:
	}
	return {}
}

SCENE_COLOR :: skald.Color{0.36, 0.62, 1.0, 1}
// Components (browser rows, instance nodes): a scene's blue toward violet
COMPONENT_COLOR :: skald.Color{0.55, 0.5, 1.0, 1}
SCRIPT_COLOR :: skald.Color{0.55, 0.85, 0.35, 1}

@(private="file")
assetKindColor :: proc(kind: AssetKind) -> skald.Color {
	switch kind {
	case .Image: return skald.rgb(0x6cc3ff)
	case .Audio: return skald.rgb(0xf08fd8)
	case .Music: return skald.rgb(0xd88ff0)
	case .Font:  return skald.rgb(0xffbe46)
	case .Data:  return skald.rgb(0x9ad1a8)
	case .Component: return COMPONENT_COLOR
	case .LDtk:  return skald.rgb(0xff8a5b)
	case .Translation: return skald.rgb(0xc8d36a)
	case .Animation: return skald.rgb(0x7fe0d0)
	// The UI controls' color
	case .Theme: return skald.rgb(0x7ed6d0)
	case .PhysicsMaterial: return skald.rgb(0xc9a27a)
	case .Atlas: return skald.rgb(0x7fc4a8)
	case .Dialogue: return skald.rgb(0xf2a6c8)
	case .Shader: return skald.rgb(0xe08bff)
	}
	return {}
}
