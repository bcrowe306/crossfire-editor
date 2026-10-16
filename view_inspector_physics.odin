package editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The inspector's physics properties (the engine's physics_nodes.odin says what they do):
- Bodies: collision layers and mask (`layerGrid`), friction and bounce; DynamicBody mass,
  gravity, damping, fixed rotation, bullet; CharacterMover floor angle.
- CollisionShape: the shape and its size, points for polygons and segments, disabled. Notes when
  it isn't under a body.
- RayCast: target, what it hits, enabled, ignore its own body.
Widget keys follow the inspector's: `inspector-<Field>-<node>`, layer buttons
`inspector-layer-<n>-<node>` / `inspector-mask-<n>-<node>`, `inspector-points-<node>`.
*/

// Layers the inspector's grids show (layers above it are kept, and settable in the scene file)
INSPECTOR_LAYER_COUNT :: 16

// Joint body choices: body A's default (the body above the joint, or the world), and no body B
JOINT_BODY_DEFAULT :: "(body above, or the world)"
JOINT_BODY_NONE :: "(none)"

@(private="package")
physicsInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	rows := make([dynamic]skald.View, context.temp_allocator)
	number :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: NodeField, value: f32, step: f64, decimals: int, width: f32, minValue := min(f64), maxValue := max(f64)) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("inspector-%v-%d", field, key), field, f64(value), step, decimals, width, minValue, maxValue)
	}
	flag :: proc(ctx: ^skald.Ctx(Msg), key: int, flag: NodeFlag, value: bool) -> skald.View {
		return skald.checkbox(ctx, value, "", flag, proc(flag: NodeFlag, value: bool) -> Msg { return Node_Flag_Changed{flag, value} },
			id = skald.hash_id(fmt.tprintf("inspector-%v-%d", flag, key)))
	}
	hint :: proc(ctx: ^skald.Ctx(Msg), text: string, warning := false) -> skald.View {
		return skald.text(text, warning ? ctx.theme.color.warning : ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = 260)
	}
	scene := &s.project.scenes[s.currentScene]
	index := s.selectedNode

	#partial switch node.kind {
	case .StaticBody, .DynamicBody, .CharacterMover, .Area:
		append(&rows,
			inspectorRow(ctx, "Layers", layerGrid(ctx, key, false, node.collisionLayer, controlWidth)),
			inspectorRow(ctx, "Collides", layerGrid(ctx, key, true, node.collisionMask, controlWidth)),
		)
		if node.kind == .Area {
			append(&rows, hint(ctx, "Reports bodies entering and leaving it (on the layers in Collides); stops nothing."))
		} else {
			append(&rows,
				inspectorRow(ctx, "Friction", number(ctx, s, key, .Friction, node.friction, 0.1, 2, numberWidth, 0, 10)),
				inspectorRow(ctx, "Bounce", number(ctx, s, key, .Restitution, node.restitution, 0.1, 2, numberWidth, 0, 1)),
			)
		}
		#partial switch node.kind {
		case .DynamicBody:
			append(&rows,
				inspectorRow(ctx, "Density", number(ctx, s, key, .Density, node.density, 0.1, 2, numberWidth, 0, 1000)),
				inspectorRow(ctx, "Gravity", number(ctx, s, key, .Gravity_Scale, node.gravityScale, 0.1, 2, numberWidth, -100, 100)),
				inspectorRow(ctx, "Damping", number(ctx, s, key, .Linear_Damping, node.linearDamping, 0.1, 2, numberWidth, 0, 100)),
				inspectorRow(ctx, "Spin damp", number(ctx, s, key, .Angular_Damping, node.angularDamping, 0.1, 2, numberWidth, 0, 100)),
				inspectorRow(ctx, "No rotation", flag(ctx, key, .Fixed_Rotation, node.fixedRotation)),
				inspectorRow(ctx, "Bullet", flag(ctx, key, .Bullet, node.bullet)),
			)
		case .CharacterMover:
			append(&rows, inspectorRow(ctx, "Floor angle", number(ctx, s, key, .Floor_Max_Angle, node.floorMaxAngle, 5, 0, numberWidth, 0, 89)))
			if !moverHasCapsule(scene, index) {
				append(&rows, hint(ctx, "Needs a Capsule or Circle CollisionShape under it: that's what it moves as.", warning = true))
			}
		}
		if !bodyHasShape(scene, index) {
			append(&rows, hint(ctx, "Add a CollisionShape under it to give it a shape.", warning = true))
		}

	case .CollisionShape:
		shapes := make([]string, len(e.CollisionShapeKind), context.temp_allocator)
		for kind in e.CollisionShapeKind do shapes[kind] = fmt.tprintf("%v", kind)
		append(&rows, inspectorRow(ctx, "Shape", skald.select(ctx, fmt.tprintf("%v", node.shape), shapes, NodeTextField.Shape,
			proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} },
			id = skald.hash_id(fmt.tprintf("inspector-shape-%d", key)), width = controlWidth)))
		switch node.shape {
		case .Rectangle:
			append(&rows,
				inspectorRow(ctx, "Width", number(ctx, s, key, .Shape_Width, node.shapeSize.x, 1, 0, numberWidth, 1, 100000)),
				inspectorRow(ctx, "Height", number(ctx, s, key, .Shape_Height, node.shapeSize.y, 1, 0, numberWidth, 1, 100000)),
			)
		case .Circle:
			append(&rows, inspectorRow(ctx, "Radius", number(ctx, s, key, .Radius, node.radius, 1, 0, numberWidth, 0.5, 100000)))
		case .Capsule:
			append(&rows,
				inspectorRow(ctx, "Radius", number(ctx, s, key, .Radius, node.radius, 1, 0, numberWidth, 0.5, 100000)),
				inspectorRow(ctx, "Height", number(ctx, s, key, .Shape_Height, node.shapeSize.y, 1, 0, numberWidth, 1, 100000)),
				hint(ctx, "Upright; the height includes the round ends."),
			)
		case .Polygon, .Segment:
			append(&rows,
				inspectorRow(ctx, "Points", pointsField(ctx, s, key, node.points[:], controlWidth)),
				hint(ctx, node.shape == .Polygon ? "x,y pairs separated by spaces; 3 to 8 points, made convex." : "Two x,y points separated by a space."),
			)
		}
		append(&rows, inspectorRow(ctx, "Disabled", flag(ctx, key, .Disabled, node.disabled)))
		if shapeBody(scene, index) < 0 {
			append(&rows, hint(ctx, "Not under a body: this shape does nothing. Move it under a StaticBody, DynamicBody, CharacterMover or Area.", warning = true))
		}

	case .RayCast:
		append(&rows,
			inspectorRow(ctx, "Target X", number(ctx, s, key, .Target_X, node.target.x, 1, 0, numberWidth)),
			inspectorRow(ctx, "Target Y", number(ctx, s, key, .Target_Y, node.target.y, 1, 0, numberWidth)),
			inspectorRow(ctx, "Hits", layerGrid(ctx, key, true, node.collisionMask, controlWidth)),
			inspectorRow(ctx, "Enabled", flag(ctx, key, .Enabled, node.enabled)),
			inspectorRow(ctx, "Skip own body", flag(ctx, key, .Exclude_Parent, node.excludeParent)),
			hint(ctx, "Casts from the node to the target (relative to it) after every physics step."),
		)

	case .Joint:
		kinds := make([]string, len(e.JointKind), context.temp_allocator)
		for kind in e.JointKind do kinds[kind] = fmt.tprintf("%v", kind)
		onText :: proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} }
		// Every body in the scene, by name
		bodies := make([dynamic]string, context.temp_allocator)
		for other in scene.nodes do if isBodyKind(other.kind) do append(&bodies, other.name)
		choicesA := make([dynamic]string, context.temp_allocator)
		append(&choicesA, JOINT_BODY_DEFAULT)
		append(&choicesA, ..bodies[:])
		choicesB := make([dynamic]string, context.temp_allocator)
		append(&choicesB, JOINT_BODY_NONE)
		append(&choicesB, ..bodies[:])
		append(&rows,
			inspectorRow(ctx, "Kind", skald.select(ctx, fmt.tprintf("%v", node.jointKind), kinds, NodeTextField.Joint_Kind, onText,
				id = skald.hash_id(fmt.tprintf("inspector-joint-kind-%d", key)), width = controlWidth)),
			inspectorRow(ctx, "Body A", skald.select(ctx, node.bodyA == "" ? JOINT_BODY_DEFAULT : node.bodyA, choicesA[:], NodeTextField.Body_A, onText,
				id = skald.hash_id(fmt.tprintf("inspector-body-a-%d", key)), width = controlWidth)),
			inspectorRow(ctx, "Body B", skald.select(ctx, node.bodyB == "" ? JOINT_BODY_NONE : node.bodyB, choicesB[:], NodeTextField.Body_B, onText,
				id = skald.hash_id(fmt.tprintf("inspector-body-b-%d", key)), width = controlWidth)),
		)
		switch node.jointKind {
		case .Revolute:  append(&rows, hint(ctx, "A hinge at the joint: body B turns around it."))
		case .Distance:  append(&rows, hint(ctx, "Keeps the joint and the offset point (on body B) apart: a rod, a rope (limits) or a spring."))
		case .Prismatic: append(&rows, hint(ctx, "Body B slides along the joint's X axis (rotate the joint to aim it) without turning."))
		case .Weld:      append(&rows, hint(ctx, "Glues the bodies together; a spring makes it bend."))
		case .Wheel:     append(&rows, hint(ctx, "Body B slides along the joint's X axis on a spring and spins freely: a wheel's suspension."))
		}
		if node.jointKind == .Distance {
			append(&rows,
				inspectorRow(ctx, "Offset X", number(ctx, s, key, .Offset_X, node.jointOffset.x, 1, 0, numberWidth)),
				inspectorRow(ctx, "Offset Y", number(ctx, s, key, .Offset_Y, node.jointOffset.y, 1, 0, numberWidth)),
			)
		}
		if node.jointKind != .Weld {
			unit := node.jointKind == .Revolute ? "°" : "px"
			append(&rows,
				inspectorRow(ctx, "Limit", flag(ctx, key, .Limit, node.enableLimit)),
				inspectorRow(ctx, fmt.tprintf("Lower %s", unit), number(ctx, s, key, .Lower, node.lower, 1, 0, numberWidth)),
				inspectorRow(ctx, fmt.tprintf("Upper %s", unit), number(ctx, s, key, .Upper, node.upper, 1, 0, numberWidth)),
				inspectorRow(ctx, "Motor", flag(ctx, key, .Motor, node.enableMotor)),
				inspectorRow(ctx, node.jointKind == .Revolute || node.jointKind == .Wheel ? "Speed °/s" : "Speed px/s",
					number(ctx, s, key, .Motor_Speed, node.motorSpeed, 10, 0, numberWidth)),
				inspectorRow(ctx, "Strength", number(ctx, s, key, .Max_Motor, node.maxMotor, 1000, 0, numberWidth, 0)),
			)
		}
		append(&rows,
			inspectorRow(ctx, "Spring", flag(ctx, key, .Spring, node.enableSpring)),
			inspectorRow(ctx, "Stiffness Hz", number(ctx, s, key, .Hertz, node.hertz, 0.5, 1, numberWidth, 0, 120)),
			inspectorRow(ctx, "Damping", number(ctx, s, key, .Damping, node.dampingRatio, 0.1, 2, numberWidth, 0, 10)),
			inspectorRow(ctx, "Bodies collide", flag(ctx, key, .Collide_Connected, node.collideConnected)),
		)
		if node.bodyB == "" {
			append(&rows, hint(ctx, "Choose body B: the body it connects.", warning = true))
		} else if count := nodesNamed(scene, node.bodyB); count != 1 {
			append(&rows, hint(ctx, count == 0 ? fmt.tprintf("No node named %s in this scene.", node.bodyB) : fmt.tprintf("%d nodes are named %s: the first is used.", count, node.bodyB), warning = true))
		}
	}
	return rows[:]
}

/*
Toggle buttons for collision layers 1-16, in two rows: lit when the layer is set. `mask` picks
which set they edit.
*/
@(private="file")
layerGrid :: proc(ctx: ^skald.Ctx(Msg), key: int, mask: bool, bits: u64, width: f32) -> skald.View {
	th := ctx.theme
	PER_ROW :: INSPECTOR_LAYER_COUNT / 2
	gap: f32 = 2
	size := max((width - gap * (PER_ROW - 1)) / PER_ROW, 14)
	rows: [2]skald.View
	for r in 0 ..< 2 {
		buttons := make([dynamic]skald.View, context.temp_allocator)
		for c in 0 ..< PER_ROW {
			layer := r * PER_ROW + c + 1
			on := bits & (1 << u64(layer - 1)) != 0
			append(&buttons, skald.button(ctx, fmt.tprintf("%d", layer), Msg(Node_Layer_Toggled{mask, layer}),
				id = skald.hash_id(fmt.tprintf("inspector-%s-%d-%d", mask ? "mask" : "layer", layer, key)),
				bg = on ? th.color.primary : th.color.surface,
				fg = on ? th.color.on_primary : th.color.fg_muted,
				width = size, padding = {0, 1}, font_size = th.font.size_xs, radius = th.radius.sm))
		}
		rows[r] = skald.row(..buttons[:], spacing = gap)
	}
	return skald.col(rows[0], rows[1], spacing = gap)
}

// A text box for "x,y x,y" points that keeps what's typed until it parses (like a number field)
@(private="file")
pointsField :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, points: [][2]f32, width: f32) -> skald.View {
	id := skald.hash_id(fmt.tprintf("inspector-points-%d", key))
	focused := skald.widget_has_focus(ctx, id)
	editing := s.numberEdit.id == id
	if editing && !focused do skald.send(ctx, Msg(Number_Edit_Ended(id)))
	text := editing && focused ? strings.clone(s.numberEdit.text, context.temp_allocator) : e.FormatPoints(points, context.temp_allocator)
	return skald.text_input(ctx, text, id, proc(id: skald.Widget_ID, v: string) -> Msg { return Node_Points_Changed{id, v} },
		id = id, width = width, padding = InspectorFieldPadding(ctx), placeholder = "x,y x,y x,y")
}

@(private="file")
nodesNamed :: proc(scene: ^SceneDef, name: string) -> int {
	count := 0
	for node in scene.nodes do if node.name == name do count += 1
	return count
}

/*
A joint's bodies in the scene: body A (its own name, else the body above the joint; -1 = the
world) and body B (-1 if not found), as the engine finds them (the first node with the name).
*/
jointBodies :: proc(scene: ^SceneDef, index: int) -> (a, b: int) {
	joint := &scene.nodes[index]
	find :: proc(scene: ^SceneDef, name: string) -> int {
		for node, i in scene.nodes do if node.name == name && isBodyKind(node.kind) do return i
		return -1
	}
	a = joint.bodyA != "" ? find(scene, joint.bodyA) : shapeBody(scene, index)
	b = joint.bodyB != "" ? find(scene, joint.bodyB) : -1
	return a, b
}

// The body a CollisionShape belongs to (its nearest body ancestor), or -1
shapeBody :: proc(scene: ^SceneDef, index: int) -> int {
	if index < 0 || index >= len(scene.nodes) do return -1
	for p := scene.nodes[index].parent; p >= 0; p = scene.nodes[p].parent {
		if isBodyKind(scene.nodes[p].kind) do return p
	}
	return -1
}

isBodyKind :: proc(kind: NodeKind) -> bool {
	return kind == .StaticBody || kind == .DynamicBody || kind == .CharacterMover || kind == .Area
}

// Whether a body has a CollisionShape of its own (one whose nearest body is this one)
@(private="file")
bodyHasShape :: proc(scene: ^SceneDef, body: int) -> bool {
	for node, i in scene.nodes do if node.kind == .CollisionShape && !node.disabled && shapeBody(scene, i) == body do return true
	return false
}

@(private="file")
moverHasCapsule :: proc(scene: ^SceneDef, body: int) -> bool {
	for node, i in scene.nodes {
		if node.kind == .CollisionShape && !node.disabled && (node.shape == .Capsule || node.shape == .Circle) && shapeBody(scene, i) == body do return true
	}
	return false
}
