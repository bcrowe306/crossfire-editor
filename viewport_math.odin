package editor

import "core:math"
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
}

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
*/
Viewport_ApplyDrag :: proc(node: ^NodeDef, drag: ^ViewportDrag, mouse: [2]f32, constrain: bool) {
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
		node.position = e.Transform2D_Apply(e.Transform2D_Inverse(drag.parentWorld), world)

	case .Rotate:
		a := drag.startMouse - origin
		b := mouse - origin
		delta := math.to_degrees(math.atan2(b.y, b.x) - math.atan2(a.y, a.x))
		rotation := drag.startRotation + delta
		if constrain do rotation = math.round(rotation / ROTATE_SNAP) * ROTATE_SNAP
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

	case .None, .Pan:
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
