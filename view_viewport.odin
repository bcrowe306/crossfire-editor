package crossfire_editor

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"
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

// A panel button that shows whether its setting is on
@(private="file")
toggleButton :: proc(s: ^State, ctx: ^skald.Ctx(Msg), key, icon, tip: string, action: Action, on: bool) -> skald.View {
	th := ctx.theme
	button := skald.button(ctx, icon, Msg(action),
		id = skald.hash_id(fmt.tprintf("panel-%s", key)),
		bg = on ? th.color.primary : th.color.surface, fg = on ? th.color.on_primary : th.color.fg_muted,
		width = math.round(th.font.size_md * 1.9), padding = {0, 3}, font_size = th.font.size_sm)
	return skald.tooltip(ctx, button, actionTip(s, tip, action), id = skald.hash_id(fmt.tprintf("panel-tip-%s", key)))
}

// The viewport's last render, kept only while a test script runs (save_viewport_render); with
// the shared GPU renderer it's read back when asked for (`Viewport_LastRender`)
lastViewportRender: [dynamic]u8
lastViewportSize: [2]int

// The viewport's last render (RGBA8) and its size, for test scripts
Viewport_LastRender :: proc() -> ([]u8, [2]int) {
	if Preview_Shared() do return Preview_LastPixels(), Preview_DrawnSize()
	return lastViewportRender[:], lastViewportSize
}

viewportView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	canvasId := skald.hash_id("viewport-canvas")
	scene := &s.project.scenes[s.currentScene]
	// A code tab shows the built-in code editor instead (code_tabs.odin)
	if codePath := CodeTabs_Active(s); codePath != "" do return codeCenterView(s, ctx, codePath)
	CodeEditor_DrainEvents()

	// The view area is the canvas minus the rulers, from last frame's layout
	canvasRect := lastRect(ctx, canvasId)
	viewRect := skald.Rect{canvasRect.x + RULER_SIZE, canvasRect.y + RULER_SIZE, canvasRect.w - RULER_SIZE, canvasRect.h - RULER_SIZE}
	viewSize := [2]f32{viewRect.w, viewRect.h}
	if viewRect.w > 0 && viewRect.h > 0 && viewSize != s.viewport.size {
		skald.send(ctx, Viewport_Measured(viewSize))
	}

	shapes := nodeShapes(s, scene)
	if viewRect.w > 0 do handleViewportInput(s, ctx, canvasId, viewRect, shapes)

	// Render the scene with the engine: straight into Skald's image (the shared GPU renderer), or
	// read back and uploaded
	imageReady := false
	if ctx.renderer != nil && s.viewport.zoom > 0 && viewRect.w > 0 && viewRect.h > 0 {
		pixelScale := max(ctx.renderer.scale, 1)
		size := [2]int{int(math.ceil(viewRect.w * pixelScale)), int(math.ceil(viewRect.h * pixelScale))}
		// Re-render and upload only when what the viewport shows changed. Other redraws (hovering,
		// typing, the console) reuse the uploaded image
		key := Preview_FrameKey(s, size, pixelScale)
		renderStart := time.tick_now()
		renderMs: f64
		if key == uploadedKey && size == uploadedSize {
			imageReady = true
		} else if pixels, ok := Preview_Render(s, size, pixelScale); ok && Preview_Shared() {
			// Drawn into the image the canvas shows: nothing to upload
			frameStats.viewportMs = time.duration_milliseconds(time.tick_since(renderStart))
			imageReady = true
			uploadedSize = size
			uploadedKey = key
		} else if ok {
			renderMs = time.duration_milliseconds(time.tick_since(renderStart))
			// Test scripts can save it (the driver's save_viewport_render)
			if ScriptDriver_Active() {
				resize(&lastViewportRender, len(pixels))
				copy(lastViewportRender[:], pixels)
				lastViewportSize = size
			}
			started := time.tick_now()
			defer frameStats.viewportMs = renderMs + time.duration_milliseconds(time.tick_since(started))
			if size == uploadedSize {
				imageReady = skald.image_update_pixels(ctx.renderer, VIEWPORT_IMAGE, u32(size.x), u32(size.y), pixels)
			}
			if !imageReady {
				imageReady = skald.image_load_pixels(ctx.renderer, VIEWPORT_IMAGE, u32(size.x), u32(size.y), pixels, mipmaps = false)
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
	// A component just opened: fit the view to what it draws, now that it's built
	if s.viewport.fitContent && Preview_IsCurrent(s) do skald.send(ctx, Viewport_Content_Measured(contentRect(s, scene)))

	buttons := skald.row(
		panelButton(ctx, "viewport-animate", s.viewport.animate ? ICON_PAUSE : ICON_PLAY,
			s.viewport.animate ? "Pause viewport animations (P)" : "Play viewport animations (P)", Action.Toggle_Animation),
		toggleButton(s, ctx, "viewport-grid", ICON_GRID, "Show grid", .Toggle_Grid, s.viewport.gridVisible),
		toggleButton(s, ctx, "viewport-snap", ICON_MAGNET, "Snap to grid", .Toggle_Snap, s.viewport.snap),
		toggleButton(s, ctx, "viewport-shapes", ICON_POLYGON, "Show collision shapes", .Toggle_Collision_Shapes, s.viewport.showShapes),
		toggleButton(s, ctx, "viewport-lighting", ICON_LIGHTBULB, "Show lit scenes lit", .Toggle_Lighting, !s.viewport.unlit),
		panelButton(ctx, "viewport-fit", ICON_SCALE, actionTip(s, "Fit game area", .View_Fit), Action.View_Fit),
		skald.button(ctx, fmt.tprintf("%.0f%%", s.viewport.zoom * 100), Msg(Action.Zoom_100),
			id = skald.hash_id("viewport-zoom"), bg = th.color.surface, fg = th.color.fg_muted,
			font_size = th.font.size_sm, width = 64, padding = {0, 3}),
		spacing = th.spacing.xs,
		cross_align = .Center,
	)
	// The tabs get what the buttons leave, scrolling sideways when there are more: many scenes,
	// scripts or a narrow window must not push the buttons out of view
	header := centerHeader(s, ctx, buttons)

	// The canvas draws after view returns, so its data must outlive this call
	data := new(ViewportData, context.temp_allocator)
	data^ = {
		state = s^,
		shapes = shapes,
		imageReady = imageReady,
		shared = Preview_Shared(),
		imageSize = uploadedSize,
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

/*
The center panel's tab strip: a tab per scene, then per open component (the one being edited
always has one), then the code tabs. The scene tab is lit only while the scene shows.
*/
@(private="file")
centerTabs :: proc(s: ^State, ctx: ^skald.Ctx(Msg), width: f32) -> skald.View {
	tabScenes := ViewportTabScenes(s)
	views := make([dynamic]skald.View, context.temp_allocator)
	active := -1
	// The last tab can't close: the viewport always shows a scene
	closable := len(tabScenes) > 1
	for index, i in tabScenes {
		scene := &s.project.scenes[index]
		// A filled circle beside the icon: unsaved changes (Ctrl+S saves them)
		dirty := Scene_IsDirty(s, index)
		mark := dirty ? fmt.tprintf("%s ", ICON_CIRCLE) : ""
		label := Scene_IsComponent(scene) ? fmt.tprintf("%s %s%s", ICON_CUBES, mark, scene.name) : fmt.tprintf("%s%s", mark, scene.name)
		shown := index == s.currentScene && CodeTabs_Active(s) == ""
		if shown do active = i
		tip := Scene_IsComponent(scene) ? scene.component : fmt.tprintf("Scene %s", scene.name)
		if dirty do tip = fmt.tprintf("%s (unsaved changes: Ctrl+S saves)", tip)
		append(&views, editorTab(ctx, label, tip, shown,
			Msg(Scene_Tab_Changed(i)), Msg(Scene_Tab_Closed(i)), fmt.tprintf("scene-tab-%d", i), closable))
	}
	append(&views, ..CodeTabs_View(s, ctx))
	strip := skald.row(..views[:], spacing = ctx.theme.spacing.xs, cross_align = .End)
	// More tabs than fit scroll sideways (the wheel, or the bar under them); the tab that shows
	// is scrolled into view when it changes (its close button, its right end)
	shownKey := s.codeTab > 0 ? fmt.tprintf("code-tab-%d", s.codeTab - 1) : fmt.tprintf("scene-tab-%d", max(active, 0))
	shown := skald.hash_id(closable || s.codeTab > 0 ? tabCloseKey(shownKey) : shownKey)
	hScroll_Reveal(ctx, "center-tabs", shown)
	// The bar is a thin line over the tabs' bottom: the header keeps its height either way
	height := ctx.renderer != nil ? skald.view_size(ctx.renderer, strip).y : 30
	return hScroll(ctx, "center-tabs", strip, max(width, 40), height, thin = true)
}

/*
The center panel's header: the tabs and, at the right, the view's buttons. When the buttons would
leave the tabs less than `CENTER_TABS_MIN_WIDTH` (a narrow window), the tabs get a row of their
own above the buttons.
*/
@(private="file")
centerHeader :: proc(s: ^State, ctx: ^skald.Ctx(Msg), buttons: skald.View) -> skald.View {
	th := ctx.theme
	room := tabsRoom(s, ctx, buttons)
	if room >= CENTER_TABS_MIN_WIDTH {
		return skald.row(
			centerTabs(s, ctx, room),
			skald.flex(1, skald.spacer(0)),
			buttons,
			spacing = th.spacing.xs,
			padding = th.spacing.xs,
			cross_align = .Center,
			bg = th.color.surface,
		)
	}
	left, right := FittedSidebarWidths(&s.layout)
	full := s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.xs * 2
	return skald.col(
		centerTabs(s, ctx, full),
		skald.row(skald.flex(1, skald.spacer(0)), buttons, spacing = th.spacing.xs, cross_align = .Center),
		spacing = th.spacing.xs,
		padding = th.spacing.xs,
		bg = th.color.surface,
	)
}

// Below this the tabs get their own row in the header
CENTER_TABS_MIN_WIDTH :: f32(200)

// What the tab strip has room for: the center panel's width less the header's buttons
@(private="file")
tabsRoom :: proc(s: ^State, ctx: ^skald.Ctx(Msg), buttons: skald.View) -> f32 {
	left, right := FittedSidebarWidths(&s.layout)
	center := s.layout.workspace.x - left - right - DIVIDER * 2
	buttonsWidth := ctx.renderer != nil ? skald.view_size(ctx.renderer, buttons).x : 0
	return center - buttonsWidth - ctx.theme.spacing.xs * 4
}

// The center panel while a code tab shows: the tabs, the file's header, the code editor
@(private="file")
codeCenterView :: proc(s: ^State, ctx: ^skald.Ctx(Msg), path: string) -> skald.View {
	th := ctx.theme
	buttons := CodeTabs_HeaderButtons(s, ctx, path)
	// A tab just opened or picked takes the keyboard
	if s.codeFocusPending {
		skald.widget_focus(ctx, skald.hash_id(CODE_EDITOR_KEY))
		skald.send(ctx, Msg(Code_Focused{}))
	}
	header := centerHeader(s, ctx, buttons)
	return skald.col(
		header,
		CodeTabs_DiskBar(s, ctx, path),
		skald.flex(1, CodeEditor_View(s, ctx, path)),
		CodeTabs_StatusLine(s, ctx, path),
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
The nodes a box selection catches: visible nodes whose bounds overlap the rectangle, or whose
marker (nodes that draw nothing) is inside it. Uses the engine preview's bounds.

Inputs:
- lo, hi: The rectangle's corners in world coordinates

Returns:
- The node indices, in node order (temp allocated)
*/
ViewportNodesInRect :: proc(s: ^State, lo, hi: [2]f32) -> []int {
	scene := &s.project.scenes[s.currentScene]
	hits := make([dynamic]int, context.temp_allocator)
	for shape, i in nodeShapes(s, scene) {
		if !shape.visible || scene.nodes[i].kind == .Animator do continue
		inside := false
		if shape.hasBounds {
			// Axis-aligned overlap of the bounds' extent with the box
			a, b := shape.corners[0], shape.corners[0]
			for c in shape.corners do a, b = {min(a.x, c.x), min(a.y, c.y)}, {max(b.x, c.x), max(b.y, c.y)}
			inside = a.x <= hi.x && b.x >= lo.x && a.y <= hi.y && b.y >= lo.y
		} else {
			p := shape.world.origin
			inside = p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y
		}
		if inside do append(&hits, i)
	}
	return hits[:]
}

/*
The world point under a window position, if it's inside the viewport's view area (last frame's
layout).
*/
ViewportWorldAt :: proc(s: ^State, ctx: ^skald.Ctx(Msg), window: [2]f32) -> ([2]f32, bool) {
	rect := lastRect(ctx, skald.hash_id("viewport-canvas"))
	view := window - {rect.x + RULER_SIZE, rect.y + RULER_SIZE}
	inside := rect.w > 0 && s.viewport.zoom > 0 && view.x >= 0 && view.y >= 0 && view.x < rect.w - RULER_SIZE && view.y < rect.h - RULER_SIZE
	return Viewport_ViewToWorld(&s.viewport, view), inside
}

/*
Where a world point is drawn, in window coordinates (last frame's layout). Test scripts paint
tiles with it (`drag_world`).

Returns:
- The position, and false when the viewport hasn't been laid out yet
*/
ViewportWorldToWindow :: proc(s: ^State, ctx: ^skald.Ctx(Msg), world: [2]f32) -> ([2]f32, bool) {
	rect := lastRect(ctx, skald.hash_id("viewport-canvas"))
	if rect.w <= 0 || s.viewport.zoom <= 0 do return {}, false
	return viewToWindow(rect, Viewport_WorldToView(&s.viewport, world)), true
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

	// Painting tiles (the Tiles tab shows, a TileMap selected: tile_paint.odin): a stroke follows the
	// mouse anywhere until its button is released
	painting, _ := TilePaint_Node(s)
	if painting != nil && s.tilePainter.stroking {
		if input.mouse_delta != {} do skald.send(ctx, Msg(Tile_Brush{world = mouseWorld, phase = .Move}))
		if input.mouse_released[.Left] || input.mouse_released[.Right] do skald.send(ctx, Msg(Tile_Brush{world = mouseWorld, phase = .End}))
		return
	}

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

	if input.scroll != {} {
		zoom, pan := wheelAction(input.scroll, input.modifiers, s.settings.wheelPans)
		if zoom != 0 do skald.send(ctx, Viewport_Zoomed{math.pow(WHEEL_ZOOM_STEP, zoom), mouseWorld})
		if pan != {} do skald.send(ctx, Viewport_Panned(pan))
	}

	spaceHeld := .Space in input.keys_down && !IsTyping(ctx)
	if painting != nil && !spaceHeld {
		// Left paints with the tool, right erases; middle still pans (below)
		if input.mouse_pressed[.Left] || input.mouse_pressed[.Right] {
			skald.send(ctx, Msg(Tile_Brush{world = mouseWorld, phase = .Begin, erase = input.mouse_pressed[.Right]}))
			return
		}
		if input.mouse_delta != {} do skald.send(ctx, Msg(Tile_Brush{world = mouseWorld, phase = .Hover}))
	}
	panTool := s.tool == .Pan && input.mouse_pressed[.Left]
	if input.mouse_pressed[.Middle] || input.mouse_pressed[.Right] || (input.mouse_pressed[.Left] && spaceHeld) || panTool {
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
	toggle := .Ctrl in input.modifiers
	add := .Shift in input.modifiers
	switch {
	case hit < 0:
		// Empty space: drag a box to select (Ctrl or Shift adds to the selection)
		if !toggle && !add do skald.send(ctx, Node_Picked(-1))
		skald.send(ctx, Viewport_Drag_Begin{mode = .Box, node = -1, mouse = mouseWorld, additive = toggle || add})
	case toggle:
		skald.send(ctx, Node_Pick_Toggled(hit))
	case add:
		skald.send(ctx, Node_Pick_Added(hit))
	case len(s.selection) > 1 && slice.contains(s.selection[:], hit):
		// Part of a multi-selection: keep it, so the drag moves them all
		skald.send(ctx, Node_Primary_Picked(hit))
		skald.send(ctx, Viewport_Drag_Begin{mode = toolDragMode(s.tool), node = hit, mouse = mouseWorld})
	case:
		skald.send(ctx, Node_Picked(hit))
		skald.send(ctx, Viewport_Drag_Begin{mode = toolDragMode(s.tool), node = hit, mouse = mouseWorld})
	}
}

/*
What a wheel turn does to the viewport: wheel notches to zoom by (positive zooms in), and view
pixels to pan by (as `Viewport_Panned`: the content moves with it). Sideways scrolling always pans.
Without `wheelPans` the wheel zooms, Shift + wheel pans sideways, Ctrl + wheel up and down; with
it (touchpads) the wheel pans and Ctrl + wheel zooms.
*/
wheelAction :: proc(scroll: [2]f32, modifiers: skald.Modifiers, wheelPans: bool) -> (zoom: f32, pan: [2]f32) {
	pan.x = scroll.x * WHEEL_PAN_PIXELS
	switch {
	case wheelPans && .Ctrl in modifiers, !wheelPans && .Ctrl not_in modifiers && .Shift not_in modifiers:
		zoom = scroll.y
	case !wheelPans && .Shift in modifiers:
		pan.x += scroll.y * WHEEL_PAN_PIXELS
	case:
		pan.y = scroll.y * WHEEL_PAN_PIXELS
	}
	return
}

// View pixels a wheel notch pans
WHEEL_PAN_PIXELS :: 40

@(private="file")
toolDragMode :: proc(tool: Tool) -> DragMode {
	switch tool {
	case .Select, .Move: return .Move
	case .Rotate:        return .Rotate
	case .Scale:         return .Scale
	case .Pan:           return .Pan
	}
	return .Move
}

// Which drag the selected node's tool handles start at this point, or .None
@(private="file")
gizmoHit :: proc(s: ^State, shapes: []NodeShape, mouseView, mouseWorld: [2]f32) -> DragMode {
	if s.selectedNode < 0 || s.selectedNode >= len(shapes) do return .None
	shape := shapes[s.selectedNode]
	if !shape.visible || s.project.scenes[s.currentScene].nodes[s.selectedNode].kind == .Animator do return .None
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
	case .Select, .Pan:
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
		// Animators aren't in the world: picked in the scene tree
		if !shape.visible || scene.nodes[i].layer < bestLayer || scene.nodes[i].kind == .Animator do continue
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

// The world rectangle {x, y, w, h} around what the scene draws, and the nodes that draw nothing
// (their positions); zero size at the origin for an empty scene
@(private="file")
contentRect :: proc(s: ^State, scene: ^SceneDef) -> [4]f32 {
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	grow :: proc(lo, hi: ^[2]f32, p: [2]f32) {
		lo^, hi^ = {min(lo.x, p.x), min(lo.y, p.y)}, {max(hi.x, p.x), max(hi.y, p.y)}
	}
	for shape in nodeShapes(s, scene) {
		if !shape.visible do continue
		if shape.hasBounds do for corner in shape.corners do grow(&lo, &hi, corner)
		else do grow(&lo, &hi, shape.world.origin)
	}
	if lo.x > hi.x do return {}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

// The rectangle a node and everything under it draw, in the node's space
@(private="file")
subtreeBounds :: proc(root: ^e.Node) -> (sdl.FRect, bool) {
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	visit :: proc(node: ^e.Node, toRoot: e.Transform2D, lo, hi: ^[2]f32) {
		if bounds, ok := e.Node_GetLocalBounds(node); ok {
			for corner in ([4][2]f32{{bounds.x, bounds.y}, {bounds.x + bounds.w, bounds.y}, {bounds.x, bounds.y + bounds.h}, {bounds.x + bounds.w, bounds.y + bounds.h}}) {
				p := e.Transform2D_Apply(toRoot, corner)
				lo^, hi^ = {min(lo.x, p.x), min(lo.y, p.y)}, {max(hi.x, p.x), max(hi.y, p.y)}
			}
		}
		for child in node.children do visit(child, e.Transform2D_Multiply(toRoot, e.Node_GetLocalTransform(child)), lo, hi)
	}
	visit(root, e.TRANSFORM2D_IDENTITY, &lo, &hi)
	if lo.x > hi.x do return {}, false
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, true
}

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
		// An instance is everything its component draws
		if node.kind == .Component do bounds, ok = subtreeBounds(engineNode)
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
	// The image is the shared GPU target (draw its used corner, `imageSize` pixels)
	shared: bool,
	imageSize: [2]int,
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
	if data.imageReady && data.shared {
		GPUTarget_Draw(r, VIEWPORT_IMAGE, viewRect, data.imageSize)
	} else if data.imageReady {
		skald.draw_image(r, VIEWPORT_IMAGE, viewRect, .Fill)
	} else {
		skald.draw_rect(r, viewRect, skald.rgb(0x101218))
	}
	if v.zoom > 0 && v.gridVisible do drawGrid(r, viewRect, v, s.project.grid, th)
	if v.zoom > 0 {
		// Game frame
		a := toWindow(p.bounds, v, {0, 0})
		b := toWindow(p.bounds, v, s.project.gameSize)
		skald.draw_rect_outline(r, {a.x, a.y, b.x - a.x, b.y - a.y}, 1, GAME_FRAME_COLOR)
		drawTextTop(r, fmt.tprintf("%.0f x %.0f", s.project.gameSize.x, s.project.gameSize.y), a.x, a.y - 16, GAME_FRAME_COLOR, th.font.size_xs)

		for &node, i in scene.nodes {
			shape := data.shapes[i]
			if !shape.visible do continue
			origin := toWindow(p.bounds, v, shape.world.origin)
			switch {
			case !v.showShapes && (node.kind == .CollisionShape || node.kind == .RayCast || node.kind == .Joint):
				// Hidden (Toggle_Collision_Shapes); still pickable by their bounds
			case node.kind == .Joint:
				drawJoint(r, p.bounds, v, scene, i, data.shapes[:], th)
			case node.kind == .CameraZone || node.kind == .CameraView:
				// Their rectangle (a view's is drawn by the engine too)
				color := kindColor(node.kind)
				corners := [4][2]f32{{0, 0}, {node.shapeSize.x, 0}, node.shapeSize, {0, node.shapeSize.y}}
				for c, k in corners {
					a := toWindow(p.bounds, v, e.Transform2D_Apply(shape.world, c))
					b := toWindow(p.bounds, v, e.Transform2D_Apply(shape.world, corners[(k + 1) % 4]))
					skald.draw_polyline(r, {a, b}, i == s.selectedNode ? 2 : 1, color, aa = true)
				}
				drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(node.kind), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
			case node.kind == .NavRegion:
				// Its area, and (selected) its blocked cells
				color := kindColor(.NavRegion)
				corners := [4][2]f32{{0, 0}, {node.shapeSize.x, 0}, node.shapeSize, {0, node.shapeSize.y}}
				for c, k in corners {
					a := toWindow(p.bounds, v, e.Transform2D_Apply(shape.world, c))
					b := toWindow(p.bounds, v, e.Transform2D_Apply(shape.world, corners[(k + 1) % 4]))
					skald.draw_polyline(r, {a, b}, 1, color, aa = true)
				}
				if i == s.selectedNode {
					if built := Preview_Node(i); built != nil && e.Node_Is(built, e.NavRegion) {
						grid := &(cast(^e.NavRegion)built).grid
						shade := skald.Color{1, 0.3, 0.3, 0.3}
						for blocked, cell in grid.blocked {
							if !blocked do continue
							w := grid.origin + [2]f32{f32(cell % grid.columns), f32(cell / grid.columns)} * grid.cellSize
							a := toWindow(p.bounds, v, w)
							b := toWindow(p.bounds, v, w + grid.cellSize)
							skald.draw_rect(r, {a.x, a.y, b.x - a.x, b.y - a.y}, shade)
						}
					}
				}
				drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(node.kind), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
			case node.kind == .LightOccluder:
				drawCollisionShape(r, p.bounds, v, &node, shape.world, kindColor(.LightOccluder))
				drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(node.kind), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
			case node.kind == .Light2D:
				// Its marker, and its reach while selected
				color := kindColor(.Light2D)
				if i == s.selectedNode {
					faint := color
					faint[3] = 0.5
					skald.draw_ring(r, origin, node.light.radius * v.zoom, 1, faint, aa = true)
				}
				skald.draw_circle(r, origin, MARKER_RADIUS, color, aa = true)
				drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(node.kind), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
			case node.kind == .CollisionShape:
				// Shapes draw nothing in the game: outline them in their body's color
				body := shapeBody(scene, i)
				color := body >= 0 && !node.disabled ? kindColor(scene.nodes[body].kind) : th.color.fg_muted
				drawCollisionShape(r, p.bounds, v, &node, shape.world, color)
			case node.kind == .RayCast:
				end := toWindow(p.bounds, v, e.Transform2D_Apply(shape.world, node.target))
				color := kindColor(.RayCast)
				if !node.enabled do color = th.color.fg_muted
				skald.draw_polyline(r, {origin, end}, 1.5, color, aa = true)
				skald.draw_circle(r, end, 3, color, aa = true)
				skald.draw_circle(r, origin, MARKER_RADIUS, color, aa = true)
				drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(node.kind), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
			case node.kind == .Camera:
				drawCameraFrame(r, p.bounds, v, shape, node.zoom, s.project.gameSize, kindColor(.Camera))
				skald.draw_circle(r, origin, MARKER_RADIUS, kindColor(.Camera), aa = true)
				drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(node.kind), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
			case node.kind == .AudioPlayer2D && i == s.selectedNode && node.audio.maxDistance > 0:
				// Where it can be heard (the range is in world units)
				color := kindColor(.AudioPlayer2D)
				faint := color
				faint[3] = 0.5
				skald.draw_ring(r, origin, node.audio.maxDistance * v.zoom, 1, faint, aa = true)
				skald.draw_circle(r, origin, MARKER_RADIUS, color, aa = true)
				drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(node.kind), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
			case node.kind == .Animator:
				// Not in the world: no marker (it would cover what it animates)
			case !shape.hasBounds:
				// Nodes that draw nothing get a marker so they can be seen and picked
				skald.draw_circle(r, origin, MARKER_RADIUS, kindColor(node.kind), aa = true)
				drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(node.kind), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
			}
		}

		// The rest of a multi-selection gets an outline; the primary node also gets the tool handles
		for node in s.selection {
			if node == s.selectedNode || node >= len(data.shapes) || !data.shapes[node].visible do continue
			drawOutline(r, p.bounds, v, data.shapes[node], th.color.primary)
		}
		// An Animator isn't in the world: no handles (they'd cover what it animates)
		if s.selectedNode >= 0 && s.selectedNode < len(data.shapes) && data.shapes[s.selectedNode].visible && scene.nodes[s.selectedNode].kind != .Animator {
			drawSelection(r, p.bounds, s, data.shapes[s.selectedNode], th)
		}
		// Painting tiles: the cell under the mouse, a rectangle being dragged
		if node, ase := TilePaint_Node(s); node != nil && s.tilePainter.hovering {
			layer := TilePaint_Layer(s, node, ase)
			tp := s.tilePainter
			from, to := tp.hover, tp.hover
			if tp.stroking && tp.tool == .Rectangle do from = tp.start
			if a, b, ok := TilePaint_CellsRect(s, node, ase, layer, from, to); ok {
				wa, wb := toWindow(p.bounds, v, a), toWindow(p.bounds, v, b)
				box := skald.Rect{min(wa.x, wb.x), min(wa.y, wb.y), abs(wb.x - wa.x), abs(wb.y - wa.y)}
				color := tp.erasing || tp.tool == .Erase ? th.color.danger : th.color.primary
				fill := color
				fill[3] = 0.18
				skald.draw_rect(r, box, fill)
				skald.draw_rect_outline(r, box, 1, color)
			}
		}
		if v.drag.mode == .Box {
			a := toWindow(p.bounds, v, v.drag.startMouse)
			b := toWindow(p.bounds, v, v.drag.current)
			box := skald.Rect{min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y)}
			fill := th.color.primary
			fill[3] = 0.15
			skald.draw_rect(r, box, fill)
			skald.draw_rect_outline(r, box, 1, th.color.primary)
		}
	}
	skald.pop_clip(r)

	drawRulers(r, p.bounds, viewRect, v, data.mouse, th)

	// Zoom indicator and mouse position
	zoomText := fmt.tprintf("%.0f%%", v.zoom * 100)
	skald.draw_rect(r, {viewRect.x + viewRect.w - 70, viewRect.y + viewRect.h - 26, 62, 20}, {0, 0, 0, 0.55}, 4)
	drawTextTop(r, zoomText, viewRect.x + viewRect.w - 62, viewRect.y + viewRect.h - 23, th.color.fg, th.font.size_xs)
	if inRect(viewRect, data.mouse) && v.zoom > 0 {
		world := Viewport_ViewToWorld(v, data.mouse - {viewRect.x, viewRect.y})
		drawTextTop(r, fmt.tprintf("%.0f, %.0f", world.x, world.y), viewRect.x + 8, viewRect.y + viewRect.h - 23, th.color.fg_muted, th.font.size_xs)
	}
}

// A selected node's outline: its bounds, or a ring around its marker
@(private="file")
drawOutline :: proc(r: ^skald.Renderer, canvas: skald.Rect, v: ^ViewportState, shape: NodeShape, color: skald.Color) {
	origin := viewToWindow(canvas, Viewport_WorldToView(v, shape.world.origin))
	if shape.hasBounds {
		points := make([][2]f32, 5, context.temp_allocator)
		for corner, i in shape.corners do points[i] = viewToWindow(canvas, Viewport_WorldToView(v, corner))
		points[4] = points[0]
		skald.draw_polyline(r, points, 1.5, color, aa = true)
	} else {
		skald.draw_ring(r, origin, PICK_RADIUS, 1.5, color, aa = true)
	}
}

// The game area's outline: a subtle red, apart from the grid and the camera frames
GAME_FRAME_COLOR :: skald.Color{0.93, 0.36, 0.36, 0.6}

/*
Grid lines at the project's cell size, a major (more opaque) line every `majorEvery` cells,
the axes brighter still. Zoomed out, cells double until they're at least 8 px apart on screen,
and the major lines with them, so blocks keep the same number of cells.
*/
@(private="file")
drawGrid :: proc(r: ^skald.Renderer, view: skald.Rect, v: ^ViewportState, grid: e.GridSettings, th: ^skald.Theme) {
	cell := [2]f32{f32(grid.size.x), f32(grid.size.y)}
	if cell.x <= 0 || cell.y <= 0 do return
	for cell.x * v.zoom < 8 || cell.y * v.zoom < 8 do cell *= 2
	every := grid.majorEvery
	lo := Viewport_ViewToWorld(v, {0, 0})
	hi := Viewport_ViewToWorld(v, {view.w, view.h})
	color := th.color.fg
	color[3] = f32(grid.opacity) / 100
	major := th.color.fg
	major[3] = f32(grid.majorOpacity) / 100
	axis := th.color.fg
	axis[3] = min(max(major[3], color[3]) + 0.15, 1)
	// The line's color by its index: line i sits at i cells from the origin
	lineColor :: proc(i: int, every: int, color, major, axis: skald.Color) -> skald.Color {
		if i == 0 do return axis
		if every > 0 && i %% every == 0 do return major
		return color
	}
	for i := int(math.floor(lo.x / cell.x)); f32(i) * cell.x <= hi.x; i += 1 {
		sx := view.x + Viewport_WorldToView(v, {f32(i) * cell.x, 0}).x
		skald.draw_rect(r, {sx, view.y, 1, view.h}, lineColor(i, every, color, major, axis))
	}
	for i := int(math.floor(lo.y / cell.y)); f32(i) * cell.y <= hi.y; i += 1 {
		sy := view.y + Viewport_WorldToView(v, {0, f32(i) * cell.y}).y
		skald.draw_rect(r, {view.x, sy, view.w, 1}, lineColor(i, every, color, major, axis))
	}
}

// Selection box and the active tool's handles
@(private="file")
drawSelection :: proc(r: ^skald.Renderer, canvas: skald.Rect, s: ^State, shape: NodeShape, th: ^skald.Theme) {
	v := &s.viewport
	color := th.color.primary
	origin := viewToWindow(canvas, Viewport_WorldToView(v, shape.world.origin))
	drawOutline(r, canvas, v, shape, color)
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
	case .Select, .Pan:
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

// A joint: a ring at its anchor, a line to body B, Distance's other anchor, a slider's axis
@(private="file")
drawJoint :: proc(r: ^skald.Renderer, canvas: skald.Rect, v: ^ViewportState, scene: ^SceneDef, index: int, shapes: []NodeShape, th: ^skald.Theme) {
	node := &scene.nodes[index]
	world := shapes[index].world
	toWindow :: proc(canvas: skald.Rect, v: ^ViewportState, p: [2]f32) -> [2]f32 {
		return viewToWindow(canvas, Viewport_WorldToView(v, p))
	}
	color := kindColor(.Joint)
	anchor := toWindow(canvas, v, world.origin)
	a, b := jointBodies(scene, index)
	faint := color
	faint[3] = 0.5
	if a >= 0 do skald.draw_polyline(r, {toWindow(canvas, v, shapes[a].world.origin), anchor}, 1, faint, aa = true)
	switch node.jointKind {
	case .Distance:
		other := toWindow(canvas, v, e.Transform2D_Apply(world, node.jointOffset))
		skald.draw_polyline(r, {anchor, other}, 1.5, color, aa = true)
		skald.draw_circle(r, other, 3, color, aa = true)
		if b >= 0 do skald.draw_polyline(r, {toWindow(canvas, v, shapes[b].world.origin), other}, 1, faint, aa = true)
	case .Prismatic, .Wheel:
		// The axis it slides along: the joint's X direction
		axis := linalg.normalize0(world.x) * 60
		skald.draw_polyline(r, {toWindow(canvas, v, world.origin - axis), toWindow(canvas, v, world.origin + axis)}, 1, color, aa = true)
		if b >= 0 do skald.draw_polyline(r, {anchor, toWindow(canvas, v, shapes[b].world.origin)}, 1, faint, aa = true)
	case .Revolute, .Weld:
		if b >= 0 do skald.draw_polyline(r, {anchor, toWindow(canvas, v, shapes[b].world.origin)}, 1, faint, aa = true)
	}
	// The anchor; red when body B is missing
	ring := b >= 0 ? color : skald.rgb(0xff5050)
	skald.draw_circle(r, anchor, MARKER_RADIUS + 2, ring, aa = true)
	skald.draw_circle(r, anchor, MARKER_RADIUS - 1, skald.rgb(0x101218), aa = true)
	drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(.Joint), node.name), anchor.x + 8, anchor.y - 8, th.color.fg_muted, th.font.size_xs)
}

// A CollisionShape's outline, in the node's space mapped through its world transform
@(private="file")
drawCollisionShape :: proc(r: ^skald.Renderer, canvas: skald.Rect, v: ^ViewportState, node: ^NodeDef, world: e.Transform2D, color: skald.Color) {
	local := make([dynamic][2]f32, context.temp_allocator)
	closed := true
	arc :: proc(points: ^[dynamic][2]f32, center: [2]f32, radius, from, to: f32) {
		SEGMENTS :: 16
		for i in 0 ..= SEGMENTS {
			angle := from + (to - from) * f32(i) / SEGMENTS
			append(points, center + [2]f32{math.cos(angle), math.sin(angle)} * radius)
		}
	}
	switch node.shape {
	case .Rectangle:
		h := node.shapeSize * 0.5
		append(&local, [2]f32{-h.x, -h.y}, [2]f32{h.x, -h.y}, [2]f32{h.x, h.y}, [2]f32{-h.x, h.y})
	case .Circle:
		arc(&local, {0, 0}, node.radius, 0, 2 * math.PI)
		// A spoke, so rotation shows
		append(&local, [2]f32{0, 0})
	case .Capsule:
		half := max(node.shapeSize.y * 0.5 - node.radius, 0)
		arc(&local, {0, -half}, node.radius, math.PI, 2 * math.PI)
		arc(&local, {0, half}, node.radius, 0, math.PI)
	case .Polygon:
		append(&local, ..node.points[:])
	case .Segment:
		append(&local, ..node.points[:])
		closed = false
	}
	if len(local) < 2 do return
	points := make([dynamic][2]f32, 0, len(local) + 1, context.temp_allocator)
	for p in local do append(&points, viewToWindow(canvas, Viewport_WorldToView(v, e.Transform2D_Apply(world, p))))
	if closed do append(&points, points[0])
	fill := color
	fill[3] = 0.08
	if closed && len(points) >= 4 do skald.draw_polygon(r, points[:len(points) - 1], fill)
	skald.draw_polyline(r, points[:], 1.5, color, aa = true)
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
		if major do drawTextTop(r, fmt.tprintf("%.0f", x), px + 3, canvas.y + 1, tick, th.font.size_xs)
	}
	if inRect(viewRect, mouse) do skald.draw_rect(r, {mouse.x, canvas.y, 1, RULER_SIZE}, th.color.primary)
	skald.pop_clip(r)

	skald.push_clip(r, {canvas.x, viewRect.y, RULER_SIZE, viewRect.h})
	for y := math.floor(topLeft.y / minor) * minor; y <= bottomRight.y; y += minor {
		py := viewRect.y + Viewport_WorldToView(v, {0, y}).y
		major := isMultiple(y, step)
		width: f32 = major ? RULER_SIZE * 0.6 : RULER_SIZE * 0.25
		skald.draw_rect(r, {canvas.x + RULER_SIZE - width, py, width, 1}, tick)
		if major do drawTextTop(r, fmt.tprintf("%.0f", y), canvas.x + 2, py + 2, tick, th.font.size_xs)
	}
	if inRect(viewRect, mouse) do skald.draw_rect(r, {canvas.x, mouse.y, RULER_SIZE, 1}, th.color.primary)
	skald.pop_clip(r)
}

/*
Draws text with its top at `y`. Skald's draw_text takes the baseline: given a top, the text sat
above where it was meant to (the top ruler's numbers were cut off but for their bottoms).
*/
drawTextTop :: proc(r: ^skald.Renderer, text: string, x, y: f32, color: skald.Color, size: f32) {
	skald.draw_text(r, text, x, y + skald.text_ascent(r, size), color, size)
}

// The scenes the viewport's tabs show, in order: every scene, then the open components (indices into project.scenes; temp allocated)
ViewportTabScenes :: proc(s: ^State) -> []int {
	list := make([dynamic]int, context.temp_allocator)
	for &scene, i in s.project.scenes do if !Scene_IsComponent(&scene) && (!scene.tabClosed || i == s.currentScene) do append(&list, i)
	for &scene, i in s.project.scenes do if Scene_IsComponent(&scene) && (scene.opened || i == s.currentScene) do append(&list, i)
	return list[:]
}

// Each node kind's color: its marker in the viewport and its row in the scene tree
kindColor :: proc(kind: NodeKind) -> skald.Color {
	switch kind {
	case .Node2D:         return skald.rgb(0x8b93a8)
	case .Sprite:         return skald.rgb(0x6cc3ff)
	case .AnimatedSprite: return skald.rgb(0xb48cff)
	case .Camera:         return skald.rgb(0xffbe46)
	case .Label:          return skald.rgb(0x7ee0a1)
	case .Menu:           return skald.rgb(0xff8a7a)
	// Physics: the colors the engine's debug drawing uses for bodies
	case .StaticBody:     return skald.rgb(0x78c878)
	case .DynamicBody:    return skald.rgb(0x6eaaff)
	case .CharacterMover: return skald.rgb(0xffaa46)
	case .Area:           return skald.rgb(0xc878ff)
	case .CollisionShape: return skald.rgb(0x4fd1c5)
	case .RayCast:        return skald.rgb(0xff6b6b)
	case .Joint:          return skald.rgb(0xffdc78)
	case .ParticleEmitter: return skald.rgb(0xff9d5c)
	case .Component:      return COMPONENT_COLOR
	// Sound: the browser's audio pink
	case .AudioPlayer, .AudioPlayer2D, .MusicPlayer: return skald.rgb(0xf08fd8)
	// The browser's Levels orange
	case .LDtkLevel:      return skald.rgb(0xff8a5b)
	// Aseprite's images, toward green
	case .TileMap:        return skald.rgb(0x6cd9a8)
	// Animation's purple, lighter
	case .Animator:       return skald.rgb(0xd2a8ff)
	// Lights: warm yellow; occluders: their shadow's gray
	case .Light2D:        return skald.rgb(0xffd36b)
	// Navigation: a path's green
	case .NavRegion, .NavAgent: return skald.rgb(0x8be07a)
	case .VirtualJoystick, .TouchButton: return skald.rgb(0x7ad3ff)
	case .ScreenEffect: return skald.rgb(0xe08bff)
	// State machines: the Animator's purple, bluer
	case .StateMachine:   return skald.rgb(0xa8b4ff)
	// Camera tools: the Camera's amber
	case .ParallaxLayer, .CameraZone, .CameraView: return skald.rgb(0xffbe46)
	case .LightOccluder:  return skald.rgb(0x9aa0b4)
	// UI: the Label's green, bluer
	case .Panel, .Button, .ProgressBar, .TextField, .ScrollBox, .RichText: return skald.rgb(0x7ed6d0)
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
