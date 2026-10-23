package crossfire_editor

import "core:fmt"
import "core:reflect"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
A Camera node's follow target and settings in the editor (the engine's camera.odin).

- **Data:** `NodeDef.camera` (the engine's `e.CameraSettings`, plain: follow mode and strengths,
  dead zone, offset, look-ahead, limits, shake) and `NodeDef.cameraTarget` (the node it follows
  by itself, a path from it; owned). Its zoom is `NodeDef.zoom` (`NodeField.Zoom`).
- **Messages:** `Camera_Changed{field, value, flag, text}`, a node step (numbers merge while
  typed or stepped).
- **Paths kept:** renaming or moving nodes rewrites cameras' target paths so they still lead to
  the same node (`CameraTargets_Resolve` before the change, `CameraTargets_Repath` after).
- **Viewport:** a selected camera shows its limits, its dead zone around its view's middle and a
  line to its target (view_viewport.odin's `drawCameraGuides`).
*/

// A camera setting (`Camera_Changed`)
CameraField :: enum {
	Target,
	Follow_Mode,
	Smoothing,
	Smooth_Time,
	Follow_Speed,
	Max_Speed,
	Deadzone_X,
	Deadzone_Y,
	Offset_X,
	Offset_Y,
	Look_Ahead_X,
	Look_Ahead_Y,
	Look_Ahead_Smoothing,
	// A side's limit; `flag` on the `_On` fields turns it on or off
	Limit_Left,
	Limit_Top,
	Limit_Right,
	Limit_Bottom,
	Limit_Left_On,
	Limit_Top_On,
	Limit_Right_On,
	Limit_Bottom_On,
	Shake_Strength,
	Shake_Duration,
	Shake_Frequency,
}

// A change to the selected camera's settings (`value` for numbers, `flag` for switches, `text`
// for the target and the follow mode)
Camera_Changed :: struct {
	field: CameraField,
	value: f32,
	flag: bool,
	text: string,
}

// The camera's number fields' target (number_field.odin)
CameraNumber :: distinct CameraField

// The target choice for none
CAMERA_TARGET_NONE :: "(none)"

/*
Applies a camera setting to the selected node.

Returns:
- Whether the message was this file's
*/
CameraEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	v, ok := m.(Camera_Changed)
	if !ok do return false
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) do return true
	node := &scene.nodes[s.selectedNode]
	c := &node.camera
	value := v.value
	switch v.field {
	case .Target:
		delete(node.cameraTarget)
		node.cameraTarget = strings.clone(v.text == CAMERA_TARGET_NONE ? "" : v.text)
	case .Follow_Mode:
		if mode, found := reflect.enum_from_name(e.CameraFollowMode, v.text); found do c.follow.mode = mode
	case .Smoothing:    c.follow.smoothing = max(value, 0)
	case .Smooth_Time:  c.follow.smoothTime = max(value, 0.01)
	case .Follow_Speed: c.follow.speed = max(value, 0)
	case .Max_Speed:    c.follow.maxSpeed = max(value, 0)
	case .Deadzone_X:   c.follow.deadzone.x = max(value, 0)
	case .Deadzone_Y:   c.follow.deadzone.y = max(value, 0)
	case .Offset_X:     c.follow.offset.x = value
	case .Offset_Y:     c.follow.offset.y = value
	case .Look_Ahead_X: c.follow.lookAhead.x = max(value, 0)
	case .Look_Ahead_Y: c.follow.lookAhead.y = max(value, 0)
	case .Look_Ahead_Smoothing: c.follow.lookAheadSmoothing = max(value, 0)
	case .Limit_Left:   c.limitMin.x = value
	case .Limit_Top:    c.limitMin.y = value
	case .Limit_Right:  c.limitMax.x = value
	case .Limit_Bottom: c.limitMax.y = value
	case .Limit_Left_On, .Limit_Top_On, .Limit_Right_On, .Limit_Bottom_On:
		side := CAMERA_LIMIT_SIDES[v.field]
		if !v.flag {
			c.limits -= {side}
			break
		}
		c.limits += {side}
		// A right or bottom limit at 0 starts at the game's edge instead (0 would hide everything)
		if side == .Right && c.limitMax.x == 0 do c.limitMax.x = s.project.gameSize.x
		if side == .Bottom && c.limitMax.y == 0 do c.limitMax.y = s.project.gameSize.y
	case .Shake_Strength:  c.shake.strength = max(value, 0)
	case .Shake_Duration:  c.shake.duration = max(value, 0)
	case .Shake_Frequency: c.shake.frequency = max(value, 0)
	}
	return true
}

// The side each limit switch turns on
@(private="file")
CAMERA_LIMIT_SIDES := #partial [CameraField]e.CameraSide{
	.Limit_Left_On = .Left, .Limit_Top_On = .Top, .Limit_Right_On = .Right, .Limit_Bottom_On = .Bottom,
	.Limit_Left = .Left, .Limit_Top = .Top, .Limit_Right = .Right, .Limit_Bottom = .Bottom,
}

/*
The inspector's rows for a Camera: its zoom, then Follow (target, mode and its strength, speed
cap, dead zone, offset, look-ahead), Limits (a switch and a value per side) and Shake.
*/
cameraInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	c := node.camera
	scene := &s.project.scenes[s.currentScene]
	number :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: CameraField, value: f32, step: f64, decimals: int, width: f32, lo: f64 = 0, hi: f64 = 100000) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("inspector-camera-%v-%d", field, key), CameraNumber(field), f64(value), step, decimals, width, lo, hi)
	}
	header :: proc(ctx: ^skald.Ctx(Msg), rows: ^[dynamic]skald.View, text: string) {
		append(rows, skald.spacer(ctx.theme.spacing.xs), skald.text(text, ctx.theme.color.fg, ctx.theme.font.size_xs))
	}
	select :: proc(ctx: ^skald.Ctx(Msg), key: int, field: CameraField, value: string, choices: []string, width: f32) -> skald.View {
		Payload :: struct { field: CameraField }
		return skald.select(ctx, value, choices, Payload{field}, proc(p: Payload, v: string) -> Msg { return Camera_Changed{field = p.field, text = v} },
			id = skald.hash_id(fmt.tprintf("inspector-camera-%v-%d", field, key)), width = width)
	}

	append(&rows, inspectorRow(ctx, "Zoom", numberField(ctx, s, fmt.tprintf("inspector-%v-%d", NodeField.Zoom, key), NodeField.Zoom, f64(node.zoom), 0.1, 2, numberWidth, 0.05, 20)))

	// Follow: the node it follows by itself, and how
	header(ctx, &rows, "Follow")
	targets := make([dynamic]string, context.temp_allocator)
	append(&targets, CAMERA_TARGET_NONE)
	for _, i in scene.nodes do if i != key do append(&targets, Scene_NodePath(scene, key, i, context.temp_allocator))
	append(&rows, inspectorRow(ctx, "Target", select(ctx, key, .Target, node.cameraTarget == "" ? CAMERA_TARGET_NONE : node.cameraTarget, targets[:], controlWidth)))
	if node.cameraTarget != "" && Scene_ResolvePath(scene, key, node.cameraTarget) < 0 {
		append(&rows, skald.text(fmt.tprintf("No node at %s yet: one the game makes is found once it's there.", node.cameraTarget), th.color.warning, th.font.size_xs, max_width = inspectorRowWidth(controlWidth)))
	}
	modes := make([]string, len(e.CameraFollowMode), context.temp_allocator)
	for m, i in e.CameraFollowMode do modes[i] = fmt.tprintf("%v", m)
	append(&rows, inspectorRow(ctx, "Follow mode", select(ctx, key, .Follow_Mode, fmt.tprintf("%v", c.follow.mode), modes, controlWidth)))
	switch c.follow.mode {
	case .Snap:
	case .Exponential: append(&rows, inspectorRow(ctx, "Smoothing", number(ctx, s, key, .Smoothing, c.follow.smoothing, 0.5, 1, numberWidth, 0, 100)))
	case .SmoothDamp:  append(&rows, inspectorRow(ctx, "Smooth time", number(ctx, s, key, .Smooth_Time, c.follow.smoothTime, 0.05, 2, numberWidth, 0.01, 10)))
	case .Linear:      append(&rows, inspectorRow(ctx, "Follow speed", number(ctx, s, key, .Follow_Speed, c.follow.speed, 50, 0, numberWidth)))
	}
	if c.follow.mode != .Snap do append(&rows, inspectorRow(ctx, "Max speed", number(ctx, s, key, .Max_Speed, c.follow.maxSpeed, 50, 0, numberWidth)))
	append(&rows,
		inspectorRow(ctx, "Dead zone X", number(ctx, s, key, .Deadzone_X, c.follow.deadzone.x, 8, 0, numberWidth)),
		inspectorRow(ctx, "Dead zone Y", number(ctx, s, key, .Deadzone_Y, c.follow.deadzone.y, 8, 0, numberWidth)),
		inspectorRow(ctx, "Aim offset X", number(ctx, s, key, .Offset_X, c.follow.offset.x, 8, 0, numberWidth, -100000)),
		inspectorRow(ctx, "Aim offset Y", number(ctx, s, key, .Offset_Y, c.follow.offset.y, 8, 0, numberWidth, -100000)),
		inspectorRow(ctx, "Look ahead X", number(ctx, s, key, .Look_Ahead_X, c.follow.lookAhead.x, 8, 0, numberWidth)),
		inspectorRow(ctx, "Look ahead Y", number(ctx, s, key, .Look_Ahead_Y, c.follow.lookAhead.y, 8, 0, numberWidth)),
	)
	if c.follow.lookAhead != {} do append(&rows, inspectorRow(ctx, "Look ease", number(ctx, s, key, .Look_Ahead_Smoothing, c.follow.lookAheadSmoothing, 0.5, 1, numberWidth, 0, 100)))

	// Limits: a switch and (when on) a value per side, in one row when both fit controlWidth (a
	// number field is never drawn narrower than NumberField_MinWidth), else the value under its
	// switch (a narrow inspector)
	header(ctx, &rows, "Limits")
	checkWidth := th.font.size_md + 4
	limitWidth := min(numberWidth, controlWidth - checkWidth - th.spacing.xs)
	stacked := limitWidth < NumberField_MinWidth(th)
	if stacked do limitWidth = numberWidth
	limit :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, c: e.CameraSettings, side: e.CameraSide, on, field: CameraField, value: f32, width: f32, stacked: bool) -> skald.View {
		Payload :: struct { field: CameraField }
		check := skald.checkbox(ctx, side in c.limits, "", Payload{on}, proc(p: Payload, v: bool) -> Msg { return Camera_Changed{field = p.field, flag = v} },
			id = skald.hash_id(fmt.tprintf("inspector-camera-%v-%d", on, key)))
		if side not_in c.limits do return check
		number := numberField(ctx, s, fmt.tprintf("inspector-camera-%v-%d", field, key), CameraNumber(field), f64(value), 16, 0, width, -1000000, 1000000)
		if stacked do return skald.col(check, number, spacing = 2)
		return skald.row(check, number, spacing = ctx.theme.spacing.xs, cross_align = .Center)
	}
	append(&rows,
		inspectorRow(ctx, "Limit left", limit(ctx, s, key, c, .Left, .Limit_Left_On, .Limit_Left, c.limitMin.x, limitWidth, stacked)),
		inspectorRow(ctx, "Limit top", limit(ctx, s, key, c, .Top, .Limit_Top_On, .Limit_Top, c.limitMin.y, limitWidth, stacked)),
		inspectorRow(ctx, "Limit right", limit(ctx, s, key, c, .Right, .Limit_Right_On, .Limit_Right, c.limitMax.x, limitWidth, stacked)),
		inspectorRow(ctx, "Limit bottom", limit(ctx, s, key, c, .Bottom, .Limit_Bottom_On, .Limit_Bottom, c.limitMax.y, limitWidth, stacked)),
	)

	// Shake: what e.Camera2D_Shake(camera) does without a strength or duration
	header(ctx, &rows, "Shake")
	append(&rows,
		inspectorRow(ctx, "Shake size", number(ctx, s, key, .Shake_Strength, c.shake.strength, 1, 1, numberWidth, 0, 1000)),
		inspectorRow(ctx, "Shake time", number(ctx, s, key, .Shake_Duration, c.shake.duration, 0.05, 2, numberWidth, 0, 30)),
		inspectorRow(ctx, "Shake rate", number(ctx, s, key, .Shake_Frequency, c.shake.frequency, 5, 0, numberWidth, 0, 240)),
	)
	return rows[:]
}

/*
Where every camera's target path leads now, so a change to names or the tree can point them at
the same nodes afterwards (`CameraTargets_Repath`).

Inputs:
- scene: The scene

Returns:
- Per node: its target's index, or -1 (no target, not a camera, or not found); temp allocated
*/
CameraTargets_Resolve :: proc(scene: ^SceneDef) -> []int {
	targets := make([]int, len(scene.nodes), context.temp_allocator)
	for &node, i in scene.nodes {
		targets[i] = -1
		if node.kind == .Camera && node.cameraTarget != "" do targets[i] = Scene_ResolvePath(scene, i, node.cameraTarget)
	}
	return targets
}

/*
Points cameras' target paths at the nodes they led to before a rename or a move.

Inputs:
- scene: The scene, after the change
- before: `CameraTargets_Resolve` from before it
- newIndex: Each old index's new one, when the nodes moved (nil: they didn't)

Returns:
- How many paths changed
*/
CameraTargets_Repath :: proc(scene: ^SceneDef, before: []int, newIndex: []int = nil) -> int {
	changed := 0
	for target, old in before {
		if target < 0 do continue
		camera, to := old, target
		if newIndex != nil do camera, to = newIndex[old], newIndex[target]
		node := &scene.nodes[camera]
		path := Scene_NodePath(scene, camera, to, context.temp_allocator)
		if path == node.cameraTarget do continue
		delete(node.cameraTarget)
		node.cameraTarget = strings.clone(path)
		changed += 1
	}
	return changed
}

// Whether any camera of the scene follows a node by its path (a rename may change those paths)
Scene_HasCameraTargets :: proc(scene: ^SceneDef) -> bool {
	for node in scene.nodes do if node.kind == .Camera && node.cameraTarget != "" do return true
	return false
}
