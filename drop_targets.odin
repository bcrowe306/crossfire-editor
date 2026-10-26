package crossfire_editor

import "gui:skald"

/*
Drop targets that light up during a drag (TODO.md's "UI and UX" round "Workflow", 2026-10-25):
while something is dragged, every place that would take it gets an accent outline, and the one
under the pointer a faint fill too. No motion: they show and go with the drag.

- **What's dragged and where it goes** (`DropTargets_Keys`, the same cases as the drops'
  releases, view_browser.odin's `browserDrag`, `sceneTreeMouse`, code_drag.odin): an asset from
  the browser into the viewport (images, components, LDtk files, animation assets), a code tab
  (any asset), the Animation panel (an image: the animation's sheet), the center's tab strip and
  the slicer's sheet (an image: the slicer); a node of the scene tree within the tree, or into a
  code tab; anything else dragged into code (code_drag.odin) into the code tab.
- **Drawn** by `dropTargetsView` (built last in `view`, over everything but popups): each target's
  rect from last frame (only targets drawn then), clipped to its scroll's visible part.
- Not targets: the inspector's fields (assets aren't dropped on them yet).
*/

/*
The widget keys of the places that would take the drag in progress (none without one).

Returns:
- The keys (temp allocated)
*/
DropTargets_Keys :: proc(s: ^State) -> []string {
	keys := make([dynamic]string, context.temp_allocator)
	code := s.codeTab > 0 && s.mode == .Scene
	switch {
	case s.assetDrag.active && s.assetDrag.asset >= 0 && s.assetDrag.asset < len(s.project.assets):
		kind := s.project.assets[s.assetDrag.asset].kind
		if s.mode == .Scene && CodeTabs_Active(s) == "" && s.slicer.shown == 0 && (kind == .Image || kind == .Component || kind == .LDtk || kind == .Animation) {
			append(&keys, "viewport-canvas")
		}
		if code do append(&keys, "code-editor")
		if kind == .Image && s.mode == .Scene {
			append(&keys, "center-tabs")
			if s.bottomTab == .Animation && s.layout.bottomOpen do append(&keys, "animation-scroll")
			if s.slicer.shown > 0 do append(&keys, "slicer-canvas")
		}
	case s.treeDrag.active:
		append(&keys, "scene-tree-scroll")
		if code do append(&keys, "code-editor")
	case s.codeDrag.active:
		if code do append(&keys, "code-editor")
	}
	return keys[:]
}

/*
The outlines of the drag's drop targets (an overlay per target; nothing without a drag).
*/
dropTargetsView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	keys := DropTargets_Keys(s)
	if len(keys) == 0 do return skald.spacer(0)
	th := ctx.theme
	views := make([dynamic]skald.View, context.temp_allocator)
	Outline :: struct { color: skald.Color, hot: bool }
	for key in keys {
		st, ok := ctx.widgets.states[skald.hash_id(key)]
		if !ok || st.last_rect.w <= 0 || st.last_drawn_frame + 1 < ctx.widgets.frame do continue
		r := st.last_rect
		if st.clip_rect.w > 0 do r = rectIntersect(r, st.clip_rect)
		if r.w <= 0 || r.h <= 0 do continue
		outline := new_clone(Outline{th.color.primary, pointIn(r, ctx.input.mouse_pos)}, context.temp_allocator)
		append(&views, skald.overlay({r.x, r.y, r.w, 0},
			skald.canvas(ctx, outline, proc(o: ^Outline, p: skald.Canvas_Painter) {
				b := p.bounds
				if o.hot {
					fill := o.color
					fill[3] *= 0.12
					skald.draw_rect(p.r, b, fill)
				}
				for edge in ([4]skald.Rect{{b.x, b.y, b.w, 2}, {b.x, b.y + b.h - 2, b.w, 2}, {b.x, b.y, 2, b.h}, {b.x + b.w - 2, b.y, 2, b.h}}) {
					skald.draw_rect(p.r, edge, o.color)
				}
			}, width = r.w, height = r.h),
			no_shadow = true, pin = true))
	}
	return skald.col(..views[:])
}

// The part two rects share (zero size when they don't overlap)
rectIntersect :: proc(a, b: skald.Rect) -> skald.Rect {
	x0, y0 := max(a.x, b.x), max(a.y, b.y)
	x1, y1 := min(a.x + a.w, b.x + b.w), min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}
