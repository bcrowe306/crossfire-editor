package crossfire_editor

import "core:fmt"
import "core:slice"
import "gui:skald"

/*
Breadcrumbs (TODO.md's "UI and UX" round 1, 2026-10-25): a slim bar above the Scene mode's
viewport with the selected node's path, the scene first (`Scene > Level > Player`); a click on a
crumb selects that ancestor (the scene's crumb clears the selection), the last crumb is the node.
The Level mode's canvas header shows its place the same way (`World > Level > Layer`: the world
crumb goes back to the world view, the level's focuses it).

When the crumbs don't fit, they're dropped from the left (the node's end of the path stays) behind
an ellipsis (`Breadcrumbs_Fit`). The bar is always there in the Scene mode, a selection or none,
so the viewport keeps its size when the selection changes.

Widget keys for UI tests: `crumb-<i>` (0: the scene; the Level mode's `level-crumb-<i>`).
*/

// One crumb: its label, what a click sends (nil: the last crumb, not clickable)
Crumb :: struct {
	label: string,
	msg: Msg,
}

/*
A node and its ancestors, the scene's top first.

Returns:
- The node indices (temp allocated; empty for -1 or an index out of range)
*/
Breadcrumbs_Chain :: proc(scene: ^SceneDef, index: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	// The tree is acyclic, but a broken file must not hang the editor
	for n := index; n >= 0 && n < len(scene.nodes) && len(out) <= len(scene.nodes); n = scene.nodes[n].parent do append(&out, n)
	slice.reverse(out[:])
	return out[:]
}

/*
The Scene mode's crumbs: the scene, then the selected node's ancestors and the node.

Returns:
- The crumbs (temp allocated)
*/
Breadcrumbs_Scene :: proc(s: ^State) -> []Crumb {
	out := make([dynamic]Crumb, context.temp_allocator)
	if s.currentScene < 0 || s.currentScene >= len(s.project.scenes) do return out[:]
	scene := &s.project.scenes[s.currentScene]
	chain := Breadcrumbs_Chain(scene, s.selectedNode)
	append(&out, Crumb{label = scene.name, msg = len(chain) > 0 ? Msg(Action.Deselect) : nil})
	for n, i in chain {
		append(&out, Crumb{label = scene.nodes[n].name, msg = i < len(chain) - 1 ? Msg(Node_Picked(n)) : nil})
	}
	return out[:]
}

/*
How many crumbs to leave out at the left so the rest fit a width.

Inputs:
- widths: Each crumb's width
- separator: A separator's width (between two crumbs, and after the ellipsis)
- ellipsis: The ellipsis' width
- width: The room

Returns:
- The crumbs dropped (0: all fit; never the last one)
*/
Breadcrumbs_Fit :: proc(widths: []f32, separator, ellipsis, width: f32) -> int {
	total: f32 = 0
	for w, i in widths do total += w + (i > 0 ? separator : 0)
	dropped := 0
	for total > width && dropped < len(widths) - 1 {
		// The first one dropped leaves an ellipsis in its place
		total -= widths[dropped] + separator
		if dropped == 0 do total += ellipsis + separator
		dropped += 1
	}
	return dropped
}

/*
A row of crumbs within `width`: the left ones dropped behind an ellipsis when they don't fit.
Each crumb is a small flat button keyed `<key>-<i>`; the last is the current one, not clickable.
*/
breadcrumbsRow :: proc(ctx: ^skald.Ctx(Msg), crumbs: []Crumb, key: string, width: f32) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	crumb :: proc(ctx: ^skald.Ctx(Msg), c: Crumb, id: skald.Widget_ID, last: bool) -> skald.View {
		th := ctx.theme
		tk := uiTokens(ctx)
		// The last crumb is where the path ends: a click does nothing
		msg := c.msg
		if msg == nil do msg = Msg(Frame_Requested{})
		return skald.button(ctx, c.label, msg, id = id,
			bg = th.color.surface, fg = last ? th.color.fg : th.color.fg_muted,
			padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	separator := uiText(th, .Muted, ICON_CHEVRON_RIGHT)
	views := make([dynamic]skald.View, context.temp_allocator)
	for c, i in crumbs do append(&views, crumb(ctx, c, skald.hash_id(fmt.tprintf("%s-%d", key, i)), i == len(crumbs) - 1))
	dropped := 0
	if ctx.renderer != nil && width > 0 {
		widths := make([]f32, len(views), context.temp_allocator)
		for v, i in views do widths[i] = skald.view_size(ctx.renderer, v).x
		ellipsis := skald.view_size(ctx.renderer, uiText(th, .Muted, "...")).x
		dropped = Breadcrumbs_Fit(widths, skald.view_size(ctx.renderer, separator).x + tk.xs * 2, ellipsis, width)
	}
	items := make([dynamic]skald.View, context.temp_allocator)
	if dropped > 0 do append(&items, uiText(th, .Muted, "..."))
	for i in dropped ..< len(views) {
		if len(items) > 0 do append(&items, uiText(th, .Muted, ICON_CHEVRON_RIGHT))
		append(&items, views[i])
	}
	return skald.row(..items[:], spacing = tk.xs, cross_align = .Center)
}

/*
The Scene mode's breadcrumb bar, above the viewport, as wide as the center panel.
*/
breadcrumbsBar :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2 - tk.xs * 2
	return skald.row(
		breadcrumbsRow(ctx, Breadcrumbs_Scene(s), "crumb", width),
		padding = tk.xxs,
		cross_align = .Center,
		bg = th.color.surface,
	)
}
