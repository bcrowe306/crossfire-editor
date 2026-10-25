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
	skald.prof_scope("viewportView")
	th := ctx.theme
	canvasId := skald.hash_id("viewport-canvas")
	scene := &s.project.scenes[s.currentScene]
	// A slicer tab shows the sprite sheet slicer (view_slicer.odin), a code tab the built-in code
	// editor (code_tabs.odin)
	if tab := Slicer_Shown(s); tab != nil do return slicerCenterView(s, ctx, tab)
	if codePath := CodeTabs_Active(s); codePath != "" do return codeCenterView(s, ctx, codePath)
	CodeEditor_DrainEvents()

	// The view area is the canvas minus the rulers, from last frame's layout
	canvasRect := lastRect(ctx, canvasId)
	viewRect := skald.Rect{canvasRect.x + RULER_SIZE, canvasRect.y + RULER_SIZE, canvasRect.w - RULER_SIZE, canvasRect.h - RULER_SIZE}
	viewSize := [2]f32{viewRect.w, viewRect.h}
	if viewRect.w > 0 && viewRect.h > 0 && viewSize != s.viewport.size {
		skald.send(ctx, Viewport_Measured(viewSize))
	}

	shapes := Viewport_NodeShapes(s, scene)
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
		toggleButton(s, ctx, "viewport-shapes", ICON_POLYGON, "Show collision shapes, rays and joints, and the collision LDtk levels and TileMaps make", .Toggle_Collision_Shapes, s.viewport.showShapes),
		toggleButton(s, ctx, "viewport-lighting", ICON_LIGHTBULB, "Show lit scenes lit", .Toggle_Lighting, !s.viewport.unlit),
		toggleButton(s, ctx, "viewport-local-axes", ICON_COMPASS, "Move along the selected node's own axes (turned with it)", .Toggle_Local_Axes, s.viewport.localAxes),
		alignButton(s, ctx),
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
always has one), then the code tabs, then the slicer's. The scene tab is lit only while the scene
shows.
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
		shown := index == s.currentScene && CodeTabs_Active(s) == "" && s.slicer.shown == 0
		if shown do active = i
		tip := Scene_IsComponent(scene) ? scene.component : fmt.tprintf("Scene %s", scene.name)
		if dirty do tip = fmt.tprintf("%s (unsaved changes: Save%s)", tip, keyParen(s, .Save_Project))
		append(&views, editorTab(ctx, label, tip, shown,
			Msg(Scene_Tab_Changed(i)), Msg(Scene_Tab_Closed(i)), fmt.tprintf("scene-tab-%d", i), closable, menu = Ctx_Scene_Tab(index)))
	}
	append(&views, ..CodeTabs_View(s, ctx))
	append(&views, ..SlicerTabs_View(s, ctx))
	strip := skald.row(..views[:], spacing = ctx.theme.spacing.xs, cross_align = .End)
	// More tabs than fit scroll sideways (the wheel, or the bar under them); the tab that shows
	// is scrolled into view when it changes (its close button, its right end)
	shownKey := s.codeTab > 0 ? fmt.tprintf("code-tab-%d", s.codeTab - 1) : fmt.tprintf("scene-tab-%d", max(active, 0))
	if s.slicer.shown > 0 do shownKey = fmt.tprintf("slicer-tab-%d", s.slicer.shown - 1)
	shown := skald.hash_id(closable || s.codeTab > 0 || s.slicer.shown > 0 ? tabCloseKey(shownKey) : shownKey)
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
	for shape, i in Viewport_NodeShapes(s, scene) {
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
	// The slicer's tab hides the viewport (its last rect stays in Skald's store)
	inside := rect.w > 0 && s.viewport.zoom > 0 && s.slicer.shown == 0 && view.x >= 0 && view.y >= 0 && view.x < rect.w - RULER_SIZE && view.y < rect.h - RULER_SIZE
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
	shape := Viewport_NodeShapes(s, scene)[index]
	if !shape.visible do return {}, false
	return viewToWindow(rect, Viewport_WorldToView(&s.viewport, shapeCenter(shape))), true
}


// INPUT

// How far (px) a right click may move and still open the context menu rather than pan
RIGHT_CLICK_SLOP :: 4

// Where the right button went down in the viewport, to tell a right click from a right drag
@(private="file")
rightPress: struct {
	active: bool,
	at: [2]f32,
}

// A guide being dragged out of a ruler (index -1) or moved; `at` is where it is now (world)
@(private="file")
guideDrag: struct {
	active, vertical: bool,
	index: int,
	at: f32,
}

// The open scene's guide under a view point (within a few pixels), or -1; none while hidden
@(private="file")
guideAt :: proc(s: ^State, mouseView: [2]f32) -> int {
	if s.viewport.guidesHidden do return -1
	for g, i in s.project.scenes[s.currentScene].guides {
		p := Viewport_WorldToView(&s.viewport, g.vertical ? {g.at, 0} : {0, g.at})
		if g.vertical ? abs(p.x - mouseView.x) < 4 : abs(p.y - mouseView.y) < 4 do return i
	}
	return -1
}

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

	// A guide follows the mouse; dropped in the view it stays, on a ruler (or outside) it goes
	if guideDrag.active {
		guideDrag.at = guideDrag.vertical ? mouseWorld.x : mouseWorld.y
		if input.mouse_released[.Left] {
			guideDrag.active = false
			switch {
			case inView && guideDrag.index < 0:  skald.send(ctx, Msg(Guide_Added{guideDrag.vertical, guideDrag.at}))
			case inView:                         skald.send(ctx, Msg(Guide_Moved{guideDrag.index, guideDrag.at}))
			case guideDrag.index >= 0:           skald.send(ctx, Msg(Guide_Removed(guideDrag.index)))
			}
		}
		return
	}
	// A press on a ruler pulls a guide out of it (the top one's is horizontal, the left one's vertical)
	if input.mouse_pressed[.Left] && skald.widget_hovered(ctx, canvasId) && !skald.mouse_over_overlay(ctx) && drag.mode == .None {
		p := input.mouse_pos
		inTop := p.y >= viewRect.y - RULER_SIZE && p.y < viewRect.y && p.x >= viewRect.x && p.x < viewRect.x + viewRect.w
		inLeft := p.x >= viewRect.x - RULER_SIZE && p.x < viewRect.x && p.y >= viewRect.y && p.y < viewRect.y + viewRect.h
		if inTop || inLeft {
			guideDrag = {active = true, vertical = inLeft, index = -1, at = inLeft ? mouseWorld.x : mouseWorld.y}
			return
		}
	}

	// An active drag follows the mouse anywhere, even outside the view
	if drag.mode != .None {
		released := input.mouse_released[.Left] || input.mouse_released[.Middle] || input.mouse_released[.Right]
		// A right click that didn't drag (a right drag pans): the context menu for the node under
		// the pointer, or for empty space (context_menus.odin)
		if input.mouse_released[.Right] && rightPress.active {
			rightPress.active = false
			d := input.mouse_pos - rightPress.at
			if d.x * d.x + d.y * d.y < RIGHT_CLICK_SLOP * RIGHT_CLICK_SLOP {
				skald.send(ctx, Msg(Viewport_Drag_End{}))
				hit := pickNode(s, shapes, mouseView, mouseWorld)
				target: ContextTarget = Ctx_Viewport{world = mouseWorld}
				if hit >= 0 do target = Ctx_Node{node = hit, world = mouseWorld, viewport = true}
				if g := guideAt(s, mouseView); g >= 0 do target = Ctx_Guide(g)
				skald.send(ctx, Msg(Context_Menu_Opened{at = input.mouse_pos, target = target}))
				return
			}
		}
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
	if input.mouse_pressed[.Right] do rightPress = {active = true, at = input.mouse_pos}
	if input.mouse_pressed[.Middle] || input.mouse_pressed[.Right] || (input.mouse_pressed[.Left] && spaceHeld) || panTool {
		skald.send(ctx, Viewport_Drag_Begin{mode = .Pan, node = -1, mouse = mouseWorld})
		return
	}
	if !input.mouse_pressed[.Left] do return

	// The Zoom tool: a click zooms in there (Alt: out), a drag zooms to the box (viewport_tools.odin)
	if s.tool == .Zoom {
		skald.send(ctx, Viewport_Drag_Begin{mode = .Zoom_Box, node = -1, mouse = mouseWorld, additive = .Alt in input.modifiers})
		return
	}
	// Alt+drag moves a copy: the selection is duplicated first
	duplicate :: proc(mode: DragMode, mods: skald.Modifiers) -> bool {
		return .Alt in mods && (mode == .Move || mode == .Move_X || mode == .Move_Y)
	}

	// The selected node's gizmo takes priority, then a guide, then whatever is under the cursor
	if mode := gizmoHit(s, shapes, mouseView, mouseWorld); mode != .None {
		skald.send(ctx, Viewport_Drag_Begin{mode = mode, node = s.selectedNode, mouse = mouseWorld, duplicate = duplicate(mode, input.modifiers)})
		return
	}
	if g := guideAt(s, mouseView); g >= 0 {
		guide := s.project.scenes[s.currentScene].guides[g]
		guideDrag = {active = true, vertical = guide.vertical, index = g, at = guide.at}
		return
	}
	hit := pickNode(s, shapes, mouseView, mouseWorld)
	// Ctrl+click toggles (Cmd+click on a Mac, where Ctrl+click is a right click)
	toggle := skald.PRIMARY_MODIFIER in input.modifiers
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
		mode := toolDragMode(s.tool)
		skald.send(ctx, Viewport_Drag_Begin{mode = mode, node = hit, mouse = mouseWorld, duplicate = duplicate(mode, input.modifiers)})
	case:
		skald.send(ctx, Node_Picked(hit))
		mode := toolDragMode(s.tool)
		skald.send(ctx, Viewport_Drag_Begin{mode = mode, node = hit, mouse = mouseWorld, duplicate = duplicate(mode, input.modifiers)})
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
	// Ctrl, or Cmd on a Mac (a touchpad's pinch arrives as Ctrl + wheel there too)
	ctrl := .Ctrl in modifiers || skald.PRIMARY_MODIFIER in modifiers
	switch {
	case wheelPans && ctrl, !wheelPans && !ctrl && .Shift not_in modifiers:
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
	case .Select, .Move, .Transform: return .Move
	case .Rotate:                    return .Rotate
	case .Scale:                     return .Scale
	case .Pan:                       return .Pan
	case .Zoom:                      return .Zoom_Box
	}
	return .Move
}

// The move arrows' directions in the view: the world's axes, or the node's own (turned with it)
@(private="file")
moveAxes :: proc(s: ^State, shape: NodeShape) -> (x, y: [2]f32) {
	if !s.viewport.localAxes do return {1, 0}, {0, 1}
	a := math.to_radians(e.Transform2D_Rotation(shape.world))
	return {math.cos(a), math.sin(a)}, {-math.sin(a), math.cos(a)}
}

// The middles of a node's bounds' sides (view coordinates) and the axis each scales: top and
// bottom its y, left and right its x
@(private="file")
sideHandles :: proc(v: ^ViewportState, shape: NodeShape) -> (points: [4][2]f32, modes: [4]DragMode) {
	c := shape.corners
	for i in 0..<4 do points[i] = Viewport_WorldToView(v, (c[i] + c[(i + 1) % 4]) * 0.5)
	return points, {.Scale_Y, .Scale_X, .Scale_Y, .Scale_X}
}

// Which drag the selected node's tool handles start at this point, or .None
@(private="file")
gizmoHit :: proc(s: ^State, shapes: []NodeShape, mouseView, mouseWorld: [2]f32) -> DragMode {
	if s.selectedNode < 0 || s.selectedNode >= len(shapes) do return .None
	shape := shapes[s.selectedNode]
	if !shape.visible || s.project.scenes[s.currentScene].nodes[s.selectedNode].kind == .Animator do return .None
	v := &s.viewport
	origin := Viewport_WorldToView(v, shape.world.origin)

	axisX, axisY := moveAxes(s, shape)
	arrows :: proc(mouse, origin, axisX, axisY: [2]f32) -> DragMode {
		if distanceToSegment(mouse, origin, origin + axisX * GIZMO_ARROW_LENGTH) < PICK_RADIUS * 0.6 do return .Move_X
		if distanceToSegment(mouse, origin, origin + axisY * GIZMO_ARROW_LENGTH) < PICK_RADIUS * 0.6 do return .Move_Y
		if length(mouse - origin) < PICK_RADIUS do return .Move
		return .None
	}
	handles :: proc(v: ^ViewportState, shape: NodeShape, mouse: [2]f32) -> DragMode {
		if !shape.hasBounds do return .None
		for corner in shape.corners {
			if length(mouse - Viewport_WorldToView(v, corner)) < PICK_RADIUS do return .Scale_Axes
		}
		points, modes := sideHandles(v, shape)
		for p, i in points do if length(mouse - p) < PICK_RADIUS * 0.8 do return modes[i]
		return .None
	}
	switch s.tool {
	case .Move:
		if mode := arrows(mouseView, origin, axisX, axisY); mode != .None do return mode
	case .Rotate:
		if abs(length(mouseView - origin) - GIZMO_ROTATE_RADIUS) < PICK_RADIUS do return .Rotate
	case .Scale:
		if mode := handles(v, shape, mouseView); mode != .None do return mode
		if length(mouseView - origin) < PICK_RADIUS do return .Scale
	case .Transform:
		// The arrows and the middle square, then the bounds' handles, then the ring
		if mode := arrows(mouseView, origin, axisX, axisY); mode != .None do return mode
		if mode := handles(v, shape, mouseView); mode != .None do return mode
		if abs(length(mouseView - origin) - GIZMO_ROTATE_RADIUS) < PICK_RADIUS * 0.6 do return .Rotate
	case .Select, .Pan, .Zoom:
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
	for shape in Viewport_NodeShapes(s, scene) {
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
Viewport_NodeShapes :: proc(s: ^State, scene: ^SceneDef) -> []NodeShape {
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
	if v.zoom > 0 do drawGuides(r, viewRect, s)
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
			case node.kind == .Bone2D || node.kind == .IKChain || node.kind == .SkinnedMesh || node.kind == .Skeleton2D:
				// Bones as wedges, an IK chain's reach, a selected mesh's triangles (skeleton_edit.odin)
				drawSkeletonNode(r, p.bounds, v, scene, i, shape.world, i == s.selectedNode, th)
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
				// Selected: its limits, dead zone and a line to its target (camera_edit.odin)
				if i == s.selectedNode do drawCameraGuides(r, p.bounds, v, scene, i, data.shapes[:])
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

// The Align and Distribute button (two or more nodes selected): its menu opens under it
@(private="file")
alignButton :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	if len(Selection_Roots(s)) < 2 do return skald.spacer(0)
	th := ctx.theme
	id := skald.hash_id("panel-viewport-align")
	r := lastRect(ctx, id)
	at := [2]f32{r.x, r.y + r.h}
	button := skald.button(ctx, ICON_ALIGN, Msg(Context_Menu_Opened{at = at, target = Ctx_Align{}}), id = id,
		bg = th.color.surface, fg = th.color.fg_muted, width = math.round(th.font.size_md * 1.9), padding = {0, 3}, font_size = th.font.size_sm)
	return skald.tooltip(ctx, button, "Align or distribute the selected nodes", id = skald.hash_id("panel-tip-viewport-align"))
}

// The guides' color: a cyan apart from the grid's grays and the selection's
GUIDE_COLOR :: skald.Color{0.25, 0.8, 0.95, 0.85}

// The open scene's guides, and one being dragged (dropped on a ruler it goes: drawn faint)
@(private="file")
drawGuides :: proc(r: ^skald.Renderer, view: skald.Rect, s: ^State) {
	line :: proc(r: ^skald.Renderer, view: skald.Rect, v: ^ViewportState, vertical: bool, at: f32, color: skald.Color) {
		p := Viewport_WorldToView(v, vertical ? {at, 0} : {0, at})
		if vertical do skald.draw_rect(r, {view.x + p.x, view.y, 1, view.h}, color)
		else do skald.draw_rect(r, {view.x, view.y + p.y, view.w, 1}, color)
	}
	v := &s.viewport
	if !v.guidesHidden {
		for g, i in s.project.scenes[s.currentScene].guides {
			if guideDrag.active && guideDrag.index == i do continue
			line(r, view, v, g.vertical, g.at, GUIDE_COLOR)
		}
	}
	if guideDrag.active do line(r, view, v, guideDrag.vertical, guideDrag.at, {GUIDE_COLOR.r, GUIDE_COLOR.g, GUIDE_COLOR.b, 1})
}

// The move arrows' colors: x red, y green
X_COLOR :: skald.Color{0.95, 0.35, 0.35, 1}
Y_COLOR :: skald.Color{0.4, 0.85, 0.45, 1}

// The game area's outline: a subtle red, apart from the grid and the camera frames
GAME_FRAME_COLOR :: skald.Color{0.93, 0.36, 0.36, 0.6}

// The grid's dark grays (lines, majors, axes), apart from the editor's own colors; the project's
// opacities apply to them
GRID_LINE_COLOR :: skald.Color{0.22, 0.22, 0.23, 1}
GRID_MAJOR_COLOR :: skald.Color{0.31, 0.31, 0.32, 1}
GRID_AXIS_COLOR :: skald.Color{0.42, 0.42, 0.44, 1}

/*
Grid lines at the project's cell size, in dark gray: a major (lighter) line every `majorEvery`
cells, the axes lighter still. Zoomed out, cells double until they're at least 8 px apart on
screen, and the major lines with them, so blocks keep the same number of cells.
*/
@(private="file")
drawGrid :: proc(r: ^skald.Renderer, view: skald.Rect, v: ^ViewportState, grid: e.GridSettings, th: ^skald.Theme) {
	cell := [2]f32{f32(grid.size.x), f32(grid.size.y)}
	if cell.x <= 0 || cell.y <= 0 do return
	for cell.x * v.zoom < 8 || cell.y * v.zoom < 8 do cell *= 2
	every := grid.majorEvery
	lo := Viewport_ViewToWorld(v, {0, 0})
	hi := Viewport_ViewToWorld(v, {view.w, view.h})
	color := GRID_LINE_COLOR
	color[3] = f32(grid.opacity) / 100
	major := GRID_MAJOR_COLOR
	major[3] = f32(grid.majorOpacity) / 100
	axis := GRID_AXIS_COLOR
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

	drag := v.drag.mode
	axisX, axisY := moveAxes(s, shape)
	arrows :: proc(r: ^skald.Renderer, origin, axisX, axisY: [2]f32, drag: DragMode, th: ^skald.Theme) {
		drawArrow(r, origin, axisX, drag == .Move_X ? th.color.fg : X_COLOR)
		drawArrow(r, origin, axisY, drag == .Move_Y ? th.color.fg : Y_COLOR)
		skald.draw_rect(r, {origin.x - 4, origin.y - 4, 8, 8}, th.color.fg)
	}
	ring :: proc(r: ^skald.Renderer, origin: [2]f32, shape: NodeShape, drag: DragMode, color: skald.Color, th: ^skald.Theme) {
		skald.draw_ring(r, origin, GIZMO_ROTATE_RADIUS, drag == .Rotate ? 3 : 2, color, aa = true)
		angle := math.to_radians(e.Transform2D_Rotation(shape.world))
		handle := origin + [2]f32{math.cos(angle), math.sin(angle)} * GIZMO_ROTATE_RADIUS
		skald.draw_line(r, origin, handle, 1, color, aa = true)
		skald.draw_circle(r, handle, 5, th.color.fg, aa = true)
	}
	// Corner handles (both axes) and side handles (one axis)
	handles :: proc(r: ^skald.Renderer, canvas: skald.Rect, v: ^ViewportState, shape: NodeShape, drag: DragMode, color: skald.Color, th: ^skald.Theme) {
		if !shape.hasBounds do return
		square :: proc(r: ^skald.Renderer, c: [2]f32, h: f32, fill, edge: skald.Color) {
			skald.draw_rect(r, {c.x - h * 0.5, c.y - h * 0.5, h, h}, fill)
			skald.draw_rect_outline(r, {c.x - h * 0.5, c.y - h * 0.5, h, h}, 1, edge)
		}
		for corner in shape.corners do square(r, viewToWindow(canvas, Viewport_WorldToView(v, corner)), GIZMO_HANDLE_SIZE, drag == .Scale_Axes ? color : th.color.fg, color)
		points, modes := sideHandles(v, shape)
		for p, i in points do square(r, viewToWindow(canvas, p), GIZMO_HANDLE_SIZE - 2, drag == modes[i] ? color : th.color.fg, color)
	}
	switch s.tool {
	case .Move:
		arrows(r, origin, axisX, axisY, drag, th)
	case .Rotate:
		ring(r, origin, shape, drag, color, th)
	case .Scale:
		handles(r, canvas, v, shape, drag, color, th)
		skald.draw_rect(r, {origin.x - 4, origin.y - 4, 8, 8}, color)
	case .Transform:
		ring(r, origin, shape, drag, color, th)
		handles(r, canvas, v, shape, drag, color, th)
		arrows(r, origin, axisX, axisY, drag, th)
	case .Select, .Pan, .Zoom:
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

// A selected camera's guides: the sides it can't show past (lines across the view), its dead zone
// around its view's middle, and a line to its follow target with a ring where it aims
@(private="file")
drawCameraGuides :: proc(r: ^skald.Renderer, canvas: skald.Rect, v: ^ViewportState, scene: ^SceneDef, index: int, shapes: []NodeShape) {
	toWindow :: proc(canvas: skald.Rect, v: ^ViewportState, p: [2]f32) -> [2]f32 {
		return viewToWindow(canvas, Viewport_WorldToView(v, p))
	}
	node := &scene.nodes[index]
	c := node.camera
	color := kindColor(.Camera)
	faint := color
	faint[3] = 0.55
	origin := shapes[index].world.origin
	// Limits: each side on is a line, as long as the other axis's limits (or the view) allow
	if c.limits != {} {
		lo := Viewport_ViewToWorld(v, {0, 0})
		hi := Viewport_ViewToWorld(v, v.size)
		top := .Top in c.limits ? c.limitMin.y : lo.y
		bottom := .Bottom in c.limits ? c.limitMax.y : hi.y
		left := .Left in c.limits ? c.limitMin.x : lo.x
		right := .Right in c.limits ? c.limitMax.x : hi.x
		lines: [4][2][2]f32
		count := 0
		if .Left in c.limits { lines[count] = {{c.limitMin.x, top}, {c.limitMin.x, bottom}}; count += 1 }
		if .Right in c.limits { lines[count] = {{c.limitMax.x, top}, {c.limitMax.x, bottom}}; count += 1 }
		if .Top in c.limits { lines[count] = {{left, c.limitMin.y}, {right, c.limitMin.y}}; count += 1 }
		if .Bottom in c.limits { lines[count] = {{left, c.limitMax.y}, {right, c.limitMax.y}}; count += 1 }
		for line in lines[:count] do skald.draw_polyline(r, {toWindow(canvas, v, line[0]), toWindow(canvas, v, line[1])}, 2, color, aa = true)
	}
	// The dead zone, around the view's middle (the camera's position)
	if c.follow.deadzone != {} {
		a := toWindow(canvas, v, origin - c.follow.deadzone * 0.5)
		b := toWindow(canvas, v, origin + c.follow.deadzone * 0.5)
		skald.draw_rect_outline(r, {a.x, a.y, b.x - a.x, b.y - a.y}, 1, faint)
	}
	// Its target: a line to it, and a ring where the camera aims (the target plus the offset)
	if node.cameraTarget != "" {
		if target := Scene_ResolvePath(scene, index, node.cameraTarget); target >= 0 && target < len(shapes) && target != index {
			at := shapes[target].world.origin
			skald.draw_polyline(r, {toWindow(canvas, v, origin), toWindow(canvas, v, at)}, 1, faint, aa = true)
			skald.draw_ring(r, toWindow(canvas, v, at + c.follow.offset), MARKER_RADIUS + 3, 1.5, color, aa = true)
		}
	}
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
	case .Line2D, .Trail2D: return skald.rgb(0xff9d5c)
	case .Skeleton2D, .Bone2D, .SkinnedMesh, .IKChain: return skald.rgb(0xe8c39e)
	case .DialogueBox: return skald.rgb(0xf2a6c8)
	// State machines: the Animator's purple, bluer
	case .StateMachine:   return skald.rgb(0xa8b4ff)
	// Camera tools: the Camera's amber
	case .ParallaxLayer, .CameraZone, .CameraView: return skald.rgb(0xffbe46)
	case .LightOccluder:  return skald.rgb(0x9aa0b4)
	// UI: the Label's green, bluer
	case .Panel, .Button, .ProgressBar, .TextField, .ScrollBox, .RichText, .Slider, .CheckBox: return skald.rgb(0x7ed6d0)
	}
	return skald.rgb(0xffffff)
}


// HELPERS

// A widget's rect from last frame (zero when it wasn't drawn)
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

// A skeleton node's overlay: a bone's wedge (origin to tip), an IK chain's line to its target, a
// selected SkinnedMesh's triangles as they bend now, a skeleton's marker
@(private="file")
drawSkeletonNode :: proc(r: ^skald.Renderer, canvas: skald.Rect, v: ^ViewportState, scene: ^SceneDef, index: int, world: e.Transform2D, selected: bool, th: ^skald.Theme) {
	node := &scene.nodes[index]
	toWindow :: proc(canvas: skald.Rect, v: ^ViewportState, p: [2]f32) -> [2]f32 {
		return viewToWindow(canvas, Viewport_WorldToView(v, p))
	}
	color := kindColor(node.kind)
	if !selected do color[3] = 0.7
	origin := toWindow(canvas, v, world.origin)
	switch node.kind {
	case .Bone2D:
		length := max(node.boneLength, 4)
		tip := toWindow(canvas, v, e.Transform2D_Apply(world, {length, 0}))
		side := toWindow(canvas, v, e.Transform2D_Apply(world, {length * 0.2, length * 0.12})) - origin
		other := toWindow(canvas, v, e.Transform2D_Apply(world, {length * 0.2, -length * 0.12})) - origin
		a, b := origin + side, origin + other
		fill := color
		fill[3] = selected ? 0.45 : 0.25
		skald.draw_triangles(r, {origin, a, tip, origin, tip, b}, fill)
		skald.draw_polyline(r, {origin, a, tip, b, origin}, selected ? 2 : 1, color, aa = true)
		skald.draw_circle(r, origin, 3, color, aa = true)
		if selected do drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(.Bone2D), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
	case .IKChain:
		tip := Scene_ResolvePath(scene, index, node.ikTip)
		target := Scene_ResolvePath(scene, index, node.ikTarget)
		if target >= 0 {
			worlds := Scene_WorldTransforms(scene)
			at := toWindow(canvas, v, worlds[target].origin)
			if tip >= 0 {
				// The tip as the preview solved it
				end := worlds[tip].origin
				if built := Preview_Node(tip); built != nil && e.Node_Is(built, e.Bone2D) do end = e.Bone2D_Tip(cast(^e.Bone2D)built)
				faint := color
				faint[3] = 0.5
				skald.draw_polyline(r, {toWindow(canvas, v, end), at}, 1, faint, aa = true)
			}
			skald.draw_ring(r, at, 7, selected ? 2 : 1, color, aa = true)
			skald.draw_polyline(r, {at - {10, 0}, at + {10, 0}}, 1, color, aa = true)
			skald.draw_polyline(r, {at - {0, 10}, at + {0, 10}}, 1, color, aa = true)
		}
		if selected do drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(.IKChain), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
	case .SkinnedMesh:
		if !selected do break
		built := Preview_Node(index)
		if built == nil || !e.Node_Is(built, e.SkinnedMesh) do break
		mesh := cast(^e.SkinnedMesh)built
		points := e.SkinnedMesh_Deform(mesh)
		meshWorld := e.Node_GetWorldTransform(mesh)
		for t := 0; t + 2 < len(mesh.mesh.triangles); t += 3 {
			ok := true
			for k in 0 ..< 3 do if int(mesh.mesh.triangles[t + k]) >= len(points) do ok = false
			if !ok do continue
			a := toWindow(canvas, v, e.Transform2D_Apply(meshWorld, points[mesh.mesh.triangles[t]]))
			b := toWindow(canvas, v, e.Transform2D_Apply(meshWorld, points[mesh.mesh.triangles[t + 1]]))
			c := toWindow(canvas, v, e.Transform2D_Apply(meshWorld, points[mesh.mesh.triangles[t + 2]]))
			skald.draw_polyline(r, {a, b, c, a}, 1, color, aa = true)
		}
		for p in points do skald.draw_circle(r, toWindow(canvas, v, e.Transform2D_Apply(meshWorld, p)), 2, color, aa = true)
	case .Skeleton2D:
		skald.draw_circle(r, origin, MARKER_RADIUS, color, aa = true)
		drawTextTop(r, fmt.tprintf("%s %s", NodeKindIcon(.Skeleton2D), node.name), origin.x + 8, origin.y - 8, th.color.fg_muted, th.font.size_xs)
	case .Node2D, .Sprite, .AnimatedSprite, .Camera, .Label, .Menu, .StaticBody, .DynamicBody, .CharacterMover, .Area,
	     .CollisionShape, .RayCast, .Joint, .ParticleEmitter, .Component, .AudioPlayer, .AudioPlayer2D, .MusicPlayer,
	     .LDtkLevel, .TileMap, .Animator, .Light2D, .LightOccluder, .NavRegion, .NavAgent, .StateMachine, .ParallaxLayer, .CameraZone, .CameraView,
	     .Panel, .Button, .ProgressBar, .TextField, .ScrollBox, .RichText, .Slider, .CheckBox, .VirtualJoystick, .TouchButton, .ScreenEffect, .Line2D, .Trail2D, .DialogueBox:
	}
}
