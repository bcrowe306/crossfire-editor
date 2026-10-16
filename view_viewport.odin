package editor

import "core:fmt"
import "core:math"
import e "engine:."
import "gui:skald"
import sdl "vendor:sdl3"

/*
Center area: scene tabs and view controls above the viewport.

The viewport shows the open scene rendered by the engine (viewport_preview.odin), with editor
overlays drawn on top: the game frame, camera frames, markers for nodes that draw nothing, the
selection box and the active tool's handles, rulers, and the zoom indicator.

Mouse:
- Left: select a node (topmost under the cursor) and drag it with the active tool. The move
  tool's arrows constrain to an axis, the scale tool's corner handles scale each axis separately.
  Shift snaps rotation to 15° steps / keeps moves on one axis / scales axes separately.
- Middle or right drag, or Space + left drag: pan. Wheel: zoom around the cursor.
Keys are in keymap.odin.
*/

RULER_SIZE :: 22
VIEWPORT_IMAGE :: "viewport-render"
MARKER_RADIUS :: 5
// Screen pixels around a marker or gizmo handle that count as hitting it
PICK_RADIUS :: 10
GIZMO_ARROW_LENGTH :: 70
GIZMO_ROTATE_RADIUS :: 70
GIZMO_HANDLE_SIZE :: 9
WHEEL_ZOOM_STEP :: 1.15

// Size of the last image uploaded to Skald (it must be re-registered when the size changes)
@(private="file")
uploadedSize: [2]int
// `Preview_FrameKey` of the uploaded image
@(private="file")
uploadedKey: u64

// Whether the editor window has keyboard focus (the user is working in it)
EditorFocused :: proc() -> bool {
	return sdl.GetKeyboardFocus() != nil
}

// Where a node is and what it covers, in world coordinates
@(private="file")
NodeShape :: struct {
	visible: bool,
	world: e.Transform2D,
	hasBounds: bool,
	// Bounds corners in world coordinates: top-left, top-right, bottom-right, bottom-left
	corners: [4][2]f32,
}

viewportView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	canvasId := skald.hash_id("viewport-canvas")
	scene := &s.project.scenes[s.currentScene]

	// The view area is the canvas minus the rulers, from last frame's layout
	canvasRect := lastRect(ctx, canvasId)
	viewRect := skald.Rect{canvasRect.x + RULER_SIZE, canvasRect.y + RULER_SIZE, canvasRect.w - RULER_SIZE, canvasRect.h - RULER_SIZE}
	viewSize := [2]f32{viewRect.w, viewRect.h}
	if viewRect.w > 0 && viewRect.h > 0 && viewSize != s.viewport.size {
		skald.send(ctx, Viewport_Measured(viewSize))
	}

	shapes := nodeShapes(s, scene)
	if viewRect.w > 0 do handleViewportInput(s, ctx, canvasId, viewRect, shapes)

	// Render the scene with the engine and hand the pixels to Skald
	imageReady := false
	if ctx.renderer != nil && s.viewport.zoom > 0 && viewRect.w > 0 && viewRect.h > 0 {
		pixelScale := max(ctx.renderer.scale, 1)
		size := [2]int{int(math.ceil(viewRect.w * pixelScale)), int(math.ceil(viewRect.h * pixelScale))}
		// Re-render and upload only when what the viewport shows changed. Other redraws (hovering,
		// typing, the console) reuse the uploaded image
		key := Preview_FrameKey(s, size, pixelScale)
		if key == uploadedKey && size == uploadedSize {
			imageReady = true
		} else if pixels, ok := Preview_Render(s, size, pixelScale); ok {
			if size == uploadedSize {
				imageReady = skald.image_update_pixels(ctx.renderer, VIEWPORT_IMAGE, u32(size.x), u32(size.y), pixels)
			}
			if !imageReady {
				imageReady = skald.image_load_pixels(ctx.renderer, VIEWPORT_IMAGE, u32(size.x), u32(size.y), pixels)
				uploadedSize = size
			}
			uploadedKey = imageReady ? key : 0
		}
		// Animations ask for frames at VIEWPORT_ANIMATION_FPS, and stop while the editor window
		// isn't focused (focusing it again redraws, which asks again)
		if s.viewport.animate && Preview_IsAnimated() && !s.viewport.tickPending && EditorFocused() {
			skald.send(ctx, Msg(Viewport_Tick_Requested{}))
		}
	}

	labels := make([]string, len(s.project.scenes), context.temp_allocator)
	for sc, i in s.project.scenes do labels[i] = sc.name
	header := skald.row(
		skald.tabs(ctx, labels, s.currentScene,
			proc(index: int) -> Msg { return Scene_Tab_Changed(index) },
			id = skald.hash_id("scene-tabs")),
		skald.flex(1, skald.spacer(0)),
		panelButton(ctx, "viewport-animate", s.viewport.animate ? ICON_PAUSE : ICON_PLAY,
			s.viewport.animate ? "Pause viewport animations (P)" : "Play viewport animations (P)", Action.Toggle_Animation),
		panelButton(ctx, "viewport-fit", ICON_SCALE, actionTip(s, "Fit game area", .View_Fit), Action.View_Fit),
		skald.button(ctx, fmt.tprintf("%.0f%%", s.viewport.zoom * 100), Msg(Action.Zoom_100),
			id = skald.hash_id("viewport-zoom"), bg = th.color.surface, fg = th.color.fg_muted,
			font_size = th.font.size_sm, width = 64, padding = {0, 3}),
		spacing = th.spacing.xs,
		padding = th.spacing.xs,
		cross_align = .Center,
		bg = th.color.surface,
	)

	// The canvas draws after view returns, so its data must outlive this call
	data := new(ViewportData, context.temp_allocator)
	data^ = {
		state = s^,
		shapes = shapes,
		imageReady = imageReady,
		mouse = ctx.input.mouse_pos,
		theme = th^,
	}
	return skald.col(
		header,
		skald.flex(1, skald.canvas(ctx, data, drawViewport, id = canvasId, cursor = .Crosshair)),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

// Whether the mouse is over the viewport's view area (for viewport-only shortcuts)
ViewportHovered :: proc(ctx: ^skald.Ctx(Msg)) -> bool {
	rect := lastRect(ctx, skald.hash_id("viewport-canvas"))
	p := ctx.input.mouse_pos
	return rect.w > 0 && p.x >= rect.x + RULER_SIZE && p.y >= rect.y + RULER_SIZE && p.x < rect.x + rect.w && p.y < rect.y + rect.h
}

/*
Where a node's center is drawn, in window coordinates, using last frame's layout. Test scripts
use it to click nodes (`click_node`).

Returns:
- The position, and false if the viewport hasn't been laid out yet or the node is hidden
*/
ViewportNodePosition :: proc(s: ^State, ctx: ^skald.Ctx(Msg), index: int) -> ([2]f32, bool) {
	rect := lastRect(ctx, skald.hash_id("viewport-canvas"))
	scene := &s.project.scenes[s.currentScene]
	if rect.w <= 0 || index < 0 || index >= len(scene.nodes) || s.viewport.zoom <= 0 do return {}, false
	shape := nodeShapes(s, scene)[index]
	if !shape.visible do return {}, false
	return viewToWindow(rect, Viewport_WorldToView(&s.viewport, shapeCenter(shape))), true
}


// INPUT

@(private="file")
handleViewportInput :: proc(s: ^State, ctx: ^skald.Ctx(Msg), canvasId: skald.Widget_ID, viewRect: skald.Rect, shapes: []NodeShape) {
	input := ctx.input
	v := &s.viewport
	mouseView := input.mouse_pos - {viewRect.x, viewRect.y}
	mouseWorld := Viewport_ViewToWorld(v, mouseView)
	inView := mouseView.x >= 0 && mouseView.y >= 0 && mouseView.x < viewRect.w && mouseView.y < viewRect.h
	hovered := inView && skald.widget_hovered(ctx, canvasId) && !skald.mouse_over_overlay(ctx)
	drag := &v.drag

	// An active drag follows the mouse anywhere, even outside the view
	if drag.mode != .None {
		released := input.mouse_released[.Left] || input.mouse_released[.Middle] || input.mouse_released[.Right]
		if drag.mode == .Pan {
			if input.mouse_delta != {} do skald.send(ctx, Viewport_Panned(input.mouse_delta))
		} else if input.mouse_delta != {} {
			skald.send(ctx, Viewport_Drag_Move{mouseWorld, .Shift in input.modifiers})
		}
		if released do skald.send(ctx, Msg(Viewport_Drag_End{}))
		return
	}
	if !hovered do return

	if input.scroll.y != 0 {
		skald.send(ctx, Viewport_Zoomed{math.pow(WHEEL_ZOOM_STEP, input.scroll.y), mouseWorld})
	}

	spaceHeld := .Space in input.keys_down && !IsTyping(ctx)
	if input.mouse_pressed[.Middle] || input.mouse_pressed[.Right] || (input.mouse_pressed[.Left] && spaceHeld) {
		skald.send(ctx, Viewport_Drag_Begin{mode = .Pan, node = -1, mouse = mouseWorld})
		return
	}
	if !input.mouse_pressed[.Left] do return

	// The selected node's gizmo takes priority, then whatever is under the cursor
	if mode := gizmoHit(s, shapes, mouseView, mouseWorld); mode != .None {
		skald.send(ctx, Viewport_Drag_Begin{mode = mode, node = s.selectedNode, mouse = mouseWorld})
		return
	}
	hit := pickNode(s, shapes, mouseView, mouseWorld)
	skald.send(ctx, Node_Picked(hit))
	if hit >= 0 {
		skald.send(ctx, Viewport_Drag_Begin{mode = toolDragMode(s.tool), node = hit, mouse = mouseWorld})
	}
}

@(private="file")
toolDragMode :: proc(tool: Tool) -> DragMode {
	switch tool {
	case .Select, .Move: return .Move
	case .Rotate:        return .Rotate
	case .Scale:         return .Scale
	}
	return .Move
}

// Which drag the selected node's tool handles start at this point, or .None
@(private="file")
gizmoHit :: proc(s: ^State, shapes: []NodeShape, mouseView, mouseWorld: [2]f32) -> DragMode {
	if s.selectedNode < 0 || s.selectedNode >= len(shapes) do return .None
	shape := shapes[s.selectedNode]
	if !shape.visible do return .None
	v := &s.viewport
	origin := Viewport_WorldToView(v, shape.world.origin)

	switch s.tool {
	case .Move:
		if distanceToSegment(mouseView, origin, origin + {GIZMO_ARROW_LENGTH, 0}) < PICK_RADIUS * 0.6 do return .Move_X
		if distanceToSegment(mouseView, origin, origin + {0, GIZMO_ARROW_LENGTH}) < PICK_RADIUS * 0.6 do return .Move_Y
		if length(mouseView - origin) < PICK_RADIUS do return .Move
	case .Rotate:
		if abs(length(mouseView - origin) - GIZMO_ROTATE_RADIUS) < PICK_RADIUS do return .Rotate
	case .Scale:
		if shape.hasBounds {
			for corner in shape.corners {
				if length(mouseView - Viewport_WorldToView(v, corner)) < PICK_RADIUS do return .Scale_Axes
			}
		}
		if length(mouseView - origin) < PICK_RADIUS do return .Scale
	case .Select:
	}
	// Grabbing the selected node itself uses the tool's normal drag
	if hitsShape(v, shape, mouseView, mouseWorld) do return toolDragMode(s.tool)
	return .None
}

// The topmost visible node under the point (higher layers first, then later in the tree), or -1
@(private="file")
pickNode :: proc(s: ^State, shapes: []NodeShape, mouseView, mouseWorld: [2]f32) -> int {
	scene := &s.project.scenes[s.currentScene]
	best, bestLayer := -1, -1
	for shape, i in shapes {
		if !shape.visible || scene.nodes[i].layer < bestLayer do continue
		if hitsShape(&s.viewport, shape, mouseView, mouseWorld) {
			// Later nodes draw on top within a layer
			best, bestLayer = i, scene.nodes[i].layer
		}
	}
	return best
}

@(private="file")
hitsShape :: proc(v: ^ViewportState, shape: NodeShape, mouseView, mouseWorld: [2]f32) -> bool {
	if shape.hasBounds do return insideQuad(mouseWorld, shape.corners)
	return length(mouseView - Viewport_WorldToView(v, shape.world.origin)) < PICK_RADIUS
}


// SHAPES

// World transform, visibility and bounds of every node in the open scene (temp allocated)
@(private="file")
nodeShapes :: proc(s: ^State, scene: ^SceneDef) -> []NodeShape {
	world := Scene_WorldTransforms(scene)
	shapes := make([]NodeShape, len(scene.nodes), context.temp_allocator)
	for &node, i in scene.nodes {
		shape := &shapes[i]
		shape.world = world[i]
		shape.visible = node.visible && (node.parent < 0 || shapes[node.parent].visible)
		// Cameras draw nothing; their view frame is drawn as an overlay instead
		if node.kind == .Camera do continue
		engineNode := Preview_Node(i)
		if engineNode == nil do continue
		bounds, ok := e.Node_GetLocalBounds(engineNode)
		if !ok do continue
		// Labels and menus follow position only: no rotation or scale
		transform := world[i]
		if node.kind == .Label || node.kind == .Menu {
			transform = {x = {1, 0}, y = {0, 1}, origin = world[i].origin}
		}
		shape.hasBounds = true
		shape.corners = {
			e.Transform2D_Apply(transform, {bounds.x, bounds.y}),
			e.Transform2D_Apply(transform, {bounds.x + bounds.w, bounds.y}),
			e.Transform2D_Apply(transform, {bounds.x + bounds.w, bounds.y + bounds.h}),
			e.Transform2D_Apply(transform, {bounds.x, bounds.y + bounds.h}),
		}
	}
	return shapes
}

@(private="file")
shapeCenter :: proc(shape: NodeShape) -> [2]f32 {
	if !shape.hasBounds do return shape.world.origin
	c := shape.corners
	return (c[0] + c[1] + c[2] + c[3]) * 0.25
}


// DRAWING

@(private="file")
ViewportData :: struct {
	state: State,
	shapes: []NodeShape,
	imageReady: bool,
	mouse: [2]f32,
	theme: skald.Theme,
}

@(private="file")
drawViewport :: proc(data: ^ViewportData, p: skald.Canvas_Painter) {
	r := p.r
	s := &data.state
	v := &s.viewport
	th := &data.theme
	scene := &s.project.scenes[s.currentScene]
	viewRect := skald.Rect{p.bounds.x + RULER_SIZE, p.bounds.y + RULER_SIZE, p.bounds.w - RULER_SIZE, p.bounds.h - RULER_SIZE}
	toWindow :: proc(canvas: skald.Rect, v: ^ViewportState, world: [2]f32) -> [2]f32 {
		return viewToWindow(canvas, Viewport_WorldToView(v, world))
	}

	skald.push_clip(r, viewRect)
	if data.imageReady {
		skald.draw_image(r, VIEWPORT_IMAGE, viewRect, .Fill)
	} else {
		skald.draw_rect(r, viewRect, skald.rgb(0x101218))
	}
	if v.zoom > 0 {
		// Game frame
		a := toWindow(p.bounds, v, {0, 0})
		b := toWindow(p.bounds, v, s.project.gameSize)
		skald.draw_rect_outline(r, {a.x, a.y, b.x - a.x, b.y - a.y}, 1, th.color.border)
		skald.draw_text(r, fmt.tprintf("%.0f x %.0f", s.project.gameSize.x, s.project.gameSize.y), a.x, a.y - 16, th.color.fg_muted, th.font.size_xs)

		for &node, i in scene.nodes {
			shape := data.shapes[i]
			if !shape.visible do continue
			origin := toWindow(p.bounds, v, shape.world.origin)
			switch {
			case node.kind == .Camera:
				drawCameraFrame(r, p.bounds, v, shape, node.zoom, s.project.gameSize, kindColor(.Camera))
				skald.draw_circle(r, origin, MARKER_RADIUS, kindColor(.Camera), aa = true)
				skald.draw_text(r, fmt.tprintf("%s %s", NodeKindIcon(node.kind), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
			case !shape.hasBounds:
				// Nodes that draw nothing get a marker so they can be seen and picked
				skald.draw_circle(r, origin, MARKER_RADIUS, kindColor(node.kind), aa = true)
				skald.draw_text(r, fmt.tprintf("%s %s", NodeKindIcon(node.kind), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
			}
		}

		if s.selectedNode >= 0 && s.selectedNode < len(data.shapes) && data.shapes[s.selectedNode].visible {
			drawSelection(r, p.bounds, s, data.shapes[s.selectedNode], th)
		}
	}
	skald.pop_clip(r)

	drawRulers(r, p.bounds, viewRect, v, data.mouse, th)

	// Zoom indicator and mouse position
	zoomText := fmt.tprintf("%.0f%%", v.zoom * 100)
	skald.draw_rect(r, {viewRect.x + viewRect.w - 70, viewRect.y + viewRect.h - 26, 62, 20}, {0, 0, 0, 0.55}, 4)
	skald.draw_text(r, zoomText, viewRect.x + viewRect.w - 62, viewRect.y + viewRect.h - 23, th.color.fg, th.font.size_xs)
	if inRect(viewRect, data.mouse) && v.zoom > 0 {
		world := Viewport_ViewToWorld(v, data.mouse - {viewRect.x, viewRect.y})
		skald.draw_text(r, fmt.tprintf("%.0f, %.0f", world.x, world.y), viewRect.x + 8, viewRect.y + viewRect.h - 23, th.color.fg_muted, th.font.size_xs)
	}
}

// Selection box and the active tool's handles
@(private="file")
drawSelection :: proc(r: ^skald.Renderer, canvas: skald.Rect, s: ^State, shape: NodeShape, th: ^skald.Theme) {
	v := &s.viewport
	color := th.color.primary
	origin := viewToWindow(canvas, Viewport_WorldToView(v, shape.world.origin))

	if shape.hasBounds {
		points := make([][2]f32, 5, context.temp_allocator)
		for corner, i in shape.corners do points[i] = viewToWindow(canvas, Viewport_WorldToView(v, corner))
		points[4] = points[0]
		skald.draw_polyline(r, points, 1.5, color, aa = true)
	} else {
		skald.draw_ring(r, origin, PICK_RADIUS, 1.5, color, aa = true)
	}
	skald.draw_circle(r, origin, 3, color, aa = true)

	X_COLOR :: skald.Color{0.95, 0.35, 0.35, 1}
	Y_COLOR :: skald.Color{0.4, 0.85, 0.45, 1}
	drag := v.drag.mode
	switch s.tool {
	case .Move:
		drawArrow(r, origin, {1, 0}, drag == .Move_X ? th.color.fg : X_COLOR)
		drawArrow(r, origin, {0, 1}, drag == .Move_Y ? th.color.fg : Y_COLOR)
		skald.draw_rect(r, {origin.x - 4, origin.y - 4, 8, 8}, th.color.fg)
	case .Rotate:
		skald.draw_ring(r, origin, GIZMO_ROTATE_RADIUS, drag == .Rotate ? 3 : 2, color, aa = true)
		angle := math.to_radians(e.Transform2D_Rotation(shape.world))
		handle := origin + [2]f32{math.cos(angle), math.sin(angle)} * GIZMO_ROTATE_RADIUS
		skald.draw_line(r, origin, handle, 1, color, aa = true)
		skald.draw_circle(r, handle, 5, th.color.fg, aa = true)
	case .Scale:
		if shape.hasBounds {
			for corner in shape.corners {
				c := viewToWindow(canvas, Viewport_WorldToView(v, corner))
				h :: GIZMO_HANDLE_SIZE
				skald.draw_rect(r, {c.x - h * 0.5, c.y - h * 0.5, h, h}, th.color.fg)
				skald.draw_rect_outline(r, {c.x - h * 0.5, c.y - h * 0.5, h, h}, 1, color)
			}
		}
		skald.draw_rect(r, {origin.x - 4, origin.y - 4, 8, 8}, color)
	case .Select:
	}
}

@(private="file")
drawArrow :: proc(r: ^skald.Renderer, origin, direction: [2]f32, color: skald.Color) {
	tip := origin + direction * GIZMO_ARROW_LENGTH
	side := [2]f32{-direction.y, direction.x}
	skald.draw_line(r, origin, tip, 2, color, aa = true)
	head := [][2]f32{tip + direction * 8, tip + side * 5, tip - side * 5}
	skald.draw_polygon(r, head, color, aa = true)
}

// The area a Camera node shows: the game resolution at its zoom, centered on it
@(private="file")
drawCameraFrame :: proc(r: ^skald.Renderer, canvas: skald.Rect, v: ^ViewportState, shape: NodeShape, zoom: f32, gameSize: [2]f32, color: skald.Color) {
	half := gameSize * 0.5 / max(zoom, 0.01)
	frame := e.Transform2D_Make(shape.world.origin, e.Transform2D_Rotation(shape.world), {1, 1})
	corners := [4][2]f32{-half, {half.x, -half.y}, half, {-half.x, half.y}}
	points := make([][2]f32, 5, context.temp_allocator)
	for corner, i in corners do points[i] = viewToWindow(canvas, Viewport_WorldToView(v, e.Transform2D_Apply(frame, corner)))
	points[4] = points[0]
	skald.draw_polyline(r, points, 1, {color.r, color.g, color.b, 0.7}, aa = true)
}

// Rulers along the top and left, in world units, with the mouse position marked
@(private="file")
drawRulers :: proc(r: ^skald.Renderer, canvas, viewRect: skald.Rect, v: ^ViewportState, mouse: [2]f32, th: ^skald.Theme) {
	bg := th.color.surface
	tick := th.color.fg_muted
	skald.draw_rect(r, {canvas.x, canvas.y, canvas.w, RULER_SIZE}, bg)
	skald.draw_rect(r, {canvas.x, canvas.y, RULER_SIZE, canvas.h}, bg)
	skald.draw_rect(r, {canvas.x, canvas.y + RULER_SIZE - 1, canvas.w, 1}, th.color.border)
	skald.draw_rect(r, {canvas.x + RULER_SIZE - 1, canvas.y, 1, canvas.h}, th.color.border)
	if v.zoom <= 0 do return

	step := Viewport_RulerStep(v.zoom)
	minor := step / 5
	topLeft := Viewport_ViewToWorld(v, {0, 0})
	bottomRight := Viewport_ViewToWorld(v, {viewRect.w, viewRect.h})

	skald.push_clip(r, {viewRect.x, canvas.y, viewRect.w, RULER_SIZE})
	for x := math.floor(topLeft.x / minor) * minor; x <= bottomRight.x; x += minor {
		px := viewRect.x + Viewport_WorldToView(v, {x, 0}).x
		major := isMultiple(x, step)
		height: f32 = major ? RULER_SIZE * 0.6 : RULER_SIZE * 0.25
		skald.draw_rect(r, {px, canvas.y + RULER_SIZE - height, 1, height}, tick)
		if major do skald.draw_text(r, fmt.tprintf("%.0f", x), px + 3, canvas.y + 1, tick, th.font.size_xs)
	}
	if inRect(viewRect, mouse) do skald.draw_rect(r, {mouse.x, canvas.y, 1, RULER_SIZE}, th.color.primary)
	skald.pop_clip(r)

	skald.push_clip(r, {canvas.x, viewRect.y, RULER_SIZE, viewRect.h})
	for y := math.floor(topLeft.y / minor) * minor; y <= bottomRight.y; y += minor {
		py := viewRect.y + Viewport_WorldToView(v, {0, y}).y
		major := isMultiple(y, step)
		width: f32 = major ? RULER_SIZE * 0.6 : RULER_SIZE * 0.25
		skald.draw_rect(r, {canvas.x + RULER_SIZE - width, py, width, 1}, tick)
		if major do skald.draw_text(r, fmt.tprintf("%.0f", y), canvas.x + 2, py + 2, tick, th.font.size_xs)
	}
	if inRect(viewRect, mouse) do skald.draw_rect(r, {canvas.x, mouse.y, RULER_SIZE, 1}, th.color.primary)
	skald.pop_clip(r)
}

@(private="file")
kindColor :: proc(kind: NodeKind) -> skald.Color {
	switch kind {
	case .Node2D:         return skald.rgb(0x8b93a8)
	case .Sprite:         return skald.rgb(0x6cc3ff)
	case .AnimatedSprite: return skald.rgb(0xb48cff)
	case .Camera:         return skald.rgb(0xffbe46)
	case .Label:          return skald.rgb(0x7ee0a1)
	case .Menu:           return skald.rgb(0xff8a7a)
	}
	return skald.rgb(0xffffff)
}


// HELPERS

@(private="file")
lastRect :: proc(ctx: ^skald.Ctx(Msg), id: skald.Widget_ID) -> skald.Rect {
	state, ok := ctx.widgets.states[id]
	return ok ? state.last_rect : {}
}

// A view-area point to window coordinates, given the canvas rect (the view starts after the rulers)
@(private="file")
viewToWindow :: proc(canvas: skald.Rect, point: [2]f32) -> [2]f32 {
	return point + {canvas.x + RULER_SIZE, canvas.y + RULER_SIZE}
}

@(private="file")
inRect :: proc(rect: skald.Rect, p: [2]f32) -> bool {
	return p.x >= rect.x && p.y >= rect.y && p.x < rect.x + rect.w && p.y < rect.y + rect.h
}

@(private="file")
isMultiple :: proc(value, step: f32) -> bool {
	q := value / step
	return abs(q - math.round(q)) < 1e-3
}

@(private="file")
length :: proc(v: [2]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

@(private="file")
distanceToSegment :: proc(p, a, b: [2]f32) -> f32 {
	ab := b - a
	t := clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / max(ab.x * ab.x + ab.y * ab.y, 1e-6), 0, 1)
	return length(p - (a + ab * t))
}

// Whether a point is inside a convex quad (any winding)
@(private="file")
insideQuad :: proc(p: [2]f32, quad: [4][2]f32) -> bool {
	sign: f32 = 0
	for i in 0..<4 {
		a, b := quad[i], quad[(i + 1) % 4]
		cross := (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
		if cross == 0 do continue
		if sign == 0 do sign = cross
		else if (cross > 0) != (sign > 0) do return false
	}
	return true
}
