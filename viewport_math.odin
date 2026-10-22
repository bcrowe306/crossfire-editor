package crossfire_editor

import "core:math"
import "core:time"
import e "engine:."

/*
Viewport navigation and editing math, shared by `update` and the viewport view.

The view maps world coordinates to viewport pixels (logical, relative to the area right of and
below the rulers):

	viewport = (world - center) * zoom + size / 2
*/

VIEWPORT_MIN_ZOOM :: 0.05
VIEWPORT_MAX_ZOOM :: 32
// Zoom step for zoom in/out commands and one mouse wheel notch
VIEWPORT_ZOOM_STEP :: 1.25
// Margin around the game area when fitting it into the view, as a fraction of the view
VIEWPORT_FIT_MARGIN :: 0.9
// Rotation snap with Shift held, degrees
ROTATE_SNAP :: 15
// Scale steps while snapping
SCALE_SNAP :: 0.1
// Arrow-key nudge distances in world units
NUDGE_SMALL :: 1
NUDGE_LARGE :: 10

// What a viewport drag does
DragMode :: enum {
	None,
	Move,
	// Move along one world axis (the move tool's arrows)
	Move_X,
	Move_Y,
	Rotate,
	// Scale both axes by the same factor
	Scale,
	// Scale each local axis separately (the scale tool's corner handles)
	Scale_Axes,
	Pan,
	// Drag a rectangle on empty space to select the nodes in it
	Box,
}

// A drag in progress: what it does and the values when it started
ViewportDrag :: struct {
	mode: DragMode,
	node: int,
	startMouse: [2]f32,     // World position where the drag started
	startPosition: [2]f32,  // The node's local values at the start
	startRotation: f32,
	startScale: [2]f32,
	startWorld: e.Transform2D,
	parentWorld: e.Transform2D,
	// Box selection: where the mouse is now (world), and whether it adds to the selection
	current: [2]f32,
	additive: bool,
}

/*
Viewport navigation state, part of `State`.
*/
ViewportState :: struct {
	// World point at the center of the view
	center: [2]f32,
	// Viewport pixels per world unit. 0 until the first fit
	zoom: f32,
	// Size of the view area (inside the rulers) in logical pixels, measured last frame
	size: [2]f32,
	// Play AnimatedSprite animations in the viewport
	animate: bool,
	drag: ViewportDrag,
	// Draw the grid, and snap drags to it (see Viewport_ApplyDrag)
	gridVisible: bool,
	// Outline collision shapes, rays and joints (Toggle_Collision_Shapes)
	showShapes: bool,
	// Draw lit scenes unlit (Toggle_Lighting): lights and their darkness off in the viewport
	unlit: bool,
	snap: bool,
	// Animation frames shown so far; each one is a 1 / VIEWPORT_ANIMATION_FPS timer tick
	animationFrame: int,
	// A tick timer is running (`Viewport_Tick_Requested` started it; each tick starts the next)
	tickPending: bool,
	// When the next tick is due, so ticks keep a steady rate however late each one lands
	nextTick: time.Tick,
	// Fit the view to what the scene draws once its preview is built (a component opening:
	// `Viewport_FitRect`), instead of to the game area
	fitContent: bool,
}

// Viewport animations are drawn at this rate, not the display's: each frame re-renders the scene
// in software and uploads it, and the rest of the editor redraws with it
VIEWPORT_ANIMATION_FPS :: 30

Viewport_WorldToView :: proc(v: ^ViewportState, world: [2]f32) -> [2]f32 {
	return (world - v.center) * v.zoom + v.size * 0.5
}

Viewport_ViewToWorld :: proc(v: ^ViewportState, point: [2]f32) -> [2]f32 {
	return (point - v.size * 0.5) / max(v.zoom, VIEWPORT_MIN_ZOOM) + v.center
}

/*
The world-to-view transform, scaled by `pixelScale` for rendering at physical resolution.
*/
Viewport_Transform :: proc(v: ^ViewportState, pixelScale: f32 = 1) -> e.Transform2D {
	zoom := v.zoom * pixelScale
	return {x = {zoom, 0}, y = {0, zoom}, origin = v.size * 0.5 * pixelScale - v.center * zoom}
}

// Shows the whole game area, centered
Viewport_Fit :: proc(v: ^ViewportState, gameSize: [2]f32) {
	v.center = gameSize * 0.5
	if v.size.x > 0 && v.size.y > 0 {
		v.zoom = clamp(min(v.size.x / gameSize.x, v.size.y / gameSize.y) * VIEWPORT_FIT_MARGIN, VIEWPORT_MIN_ZOOM, VIEWPORT_MAX_ZOOM)
	} else {
		v.zoom = 1
	}
}

/*
Shows a world rectangle, centered, as large as fits (with the fit margin). A rectangle smaller
than `VIEWPORT_FIT_MIN_SIZE` is shown at that size, so a tiny or empty component isn't magnified
without end.
*/
Viewport_FitRect :: proc(v: ^ViewportState, rect: [4]f32) {
	size := [2]f32{max(rect[2], VIEWPORT_FIT_MIN_SIZE), max(rect[3], VIEWPORT_FIT_MIN_SIZE)}
	v.center = {rect[0] + rect[2] * 0.5, rect[1] + rect[3] * 0.5}
	if v.size.x > 0 && v.size.y > 0 {
		v.zoom = clamp(min(v.size.x / size.x, v.size.y / size.y) * VIEWPORT_FIT_MARGIN, VIEWPORT_MIN_ZOOM, VIEWPORT_MAX_ZOOM)
	} else {
		v.zoom = 1
	}
}

// The smallest world size `Viewport_FitRect` fits (an empty component shows 128 units around it)
VIEWPORT_FIT_MIN_SIZE :: 128

/*
Zooms by a factor, keeping a world point under the same pixel (the mouse, for wheel zoom).
*/
Viewport_ZoomAt :: proc(v: ^ViewportState, factor: f32, anchor: [2]f32) {
	old := max(v.zoom, VIEWPORT_MIN_ZOOM)
	zoom := clamp(old * factor, VIEWPORT_MIN_ZOOM, VIEWPORT_MAX_ZOOM)
	v.center = anchor - (anchor - v.center) * (old / zoom)
	v.zoom = zoom
}

// Pans by a distance in view pixels (the content follows the mouse)
Viewport_Pan :: proc(v: ^ViewportState, pixels: [2]f32) {
	v.center -= pixels / max(v.zoom, VIEWPORT_MIN_ZOOM)
}

/*
A "nice" spacing for ruler ticks: 1, 2 or 5 times a power of ten, with at least `minPixels`
between ticks at this zoom.
*/
Viewport_RulerStep :: proc(zoom: f32, minPixels: f32 = 60) -> f32 {
	raw := minPixels / max(zoom, VIEWPORT_MIN_ZOOM)
	magnitude := math.pow(10, math.floor(math.log10(raw)))
	for m in ([3]f32{1, 2, 5}) {
		if m * magnitude >= raw do return m * magnitude
	}
	return 10 * magnitude
}

/*
Applies a drag to a node, from the values captured when it started.

Inputs:
- node: The node being dragged
- drag: The drag, as started by `Viewport_Drag_Begin`
- mouse: Current mouse position in world coordinates
- constrain: Shift held: snap rotation, keep moves on one axis, scale axes separately
- grid: Snapping on: the grid's cell (width, height). Moves put the node's origin on the grid,
  rotation snaps to ROTATE_SNAP degrees, scale to SCALE_SNAP steps. Zero for no snapping
*/
Viewport_ApplyDrag :: proc(node: ^NodeDef, drag: ^ViewportDrag, mouse: [2]f32, constrain: bool, grid: [2]f32 = {}) {
	snap := grid.x > 0 && grid.y > 0
	origin := drag.startWorld.origin
	switch drag.mode {
	case .Move, .Move_X, .Move_Y:
		delta := mouse - drag.startMouse
		mode := drag.mode
		if mode == .Move && constrain do mode = abs(delta.x) >= abs(delta.y) ? .Move_X : .Move_Y
		if mode == .Move_X do delta.y = 0
		if mode == .Move_Y do delta.x = 0
		// The new world origin, expressed in the parent's space
		world := origin + delta
		if snap {
			if mode != .Move_Y do world.x = math.round(world.x / grid.x) * grid.x
			if mode != .Move_X do world.y = math.round(world.y / grid.y) * grid.y
		}
		node.position = e.Transform2D_Apply(e.Transform2D_Inverse(drag.parentWorld), world)

	case .Rotate:
		a := drag.startMouse - origin
		b := mouse - origin
		delta := math.to_degrees(math.atan2(b.y, b.x) - math.atan2(a.y, a.x))
		rotation := drag.startRotation + delta
		if constrain || snap do rotation = math.round(rotation / ROTATE_SNAP) * ROTATE_SNAP
		node.rotation = normalizeDegrees(rotation)

	case .Scale, .Scale_Axes:
		// Compare the mouse to the start in the node's rotated frame
		angle := -e.Transform2D_Rotation(drag.startWorld)
		a := rotate(drag.startMouse - origin, angle)
		b := rotate(mouse - origin, angle)
		if drag.mode == .Scale_Axes || constrain {
			ratio := [2]f32{1, 1}
			if abs(a.x) > 1e-3 do ratio.x = b.x / a.x
			if abs(a.y) > 1e-3 do ratio.y = b.y / a.y
			node.scale = drag.startScale * ratio
		} else {
			la := math.sqrt(a.x * a.x + a.y * a.y)
			lb := math.sqrt(b.x * b.x + b.y * b.y)
			if la > 1e-3 do node.scale = drag.startScale * (lb / la)
		}
		if snap do node.scale = {math.round(node.scale.x / SCALE_SNAP) * SCALE_SNAP, math.round(node.scale.y / SCALE_SNAP) * SCALE_SNAP}

	case .None, .Pan, .Box:
	}
}

// -180..180
@(private="file")
normalizeDegrees :: proc(degrees: f32) -> f32 {
	d := math.mod(degrees + 180, 360)
	if d < 0 do d += 360
	return d - 180
}

@(private="file")
rotate :: proc(v: [2]f32, degrees: f32) -> [2]f32 {
	r := math.to_radians(degrees)
	c, s := math.cos(r), math.sin(r)
	return {v.x * c - v.y * s, v.x * s + v.y * c}
}

/*
Applies the change a drag made to its node to the other selected nodes, so a multi-selection
moves, rotates and scales together: the same world movement, the same rotation added, the same
scale factor, each about its own origin.

Inputs:
- scene: The scene
- dragged: The dragged node, already updated by `Viewport_ApplyDrag`
- before: The dragged node as it was before this step
- others: The other selected roots
*/
Viewport_FollowDrag :: proc(scene: ^SceneDef, dragged: int, before: NodeDef, others: []int) {
	if len(others) == 0 do return
	world := Scene_WorldTransforms(scene)
	node := scene.nodes[dragged]
	// World movement of the dragged node's origin (its parent didn't move)
	parentWorld := node.parent >= 0 ? world[node.parent] : e.TRANSFORM2D_IDENTITY
	moved := e.Transform2D_ApplyVector(parentWorld, node.position - before.position)
	turned := node.rotation - before.rotation
	ratio := [2]f32{1, 1}
	if abs(before.scale.x) > 1e-6 do ratio.x = node.scale.x / before.scale.x
	if abs(before.scale.y) > 1e-6 do ratio.y = node.scale.y / before.scale.y
	for other in others {
		if other == dragged do continue
		o := &scene.nodes[other]
		otherParent := o.parent >= 0 ? world[o.parent] : e.TRANSFORM2D_IDENTITY
		o.position += e.Transform2D_ApplyVector(e.Transform2D_Inverse(otherParent), moved)
		o.rotation = normalizeDegrees(o.rotation + turned)
		o.scale *= ratio
	}
}
