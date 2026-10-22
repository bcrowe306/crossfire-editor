package crossfire_editor

import "core:fmt"
import "core:math"
import "core:reflect"
import "gui:skald"
import e "engine:."

/*
Lines and trails in the editor (the engine's lines.odin): Line2D nodes (a thick line through
points: ropes, lasers, paths) and Trail2D nodes (a ribbon left behind their parent).

- **Data:** `NodeDef.line` is the engine's `e.LineSettings` (a plain value); a line's points are
  `NodeDef.points` (the CollisionShape field, its Points text row), its image `texture`.
- **Messages:** `Line_Setting_Changed{field, value, text, flag}`, a node step (sliders merge
  while dragged).
- **Viewport:** the engine draws lines (their points and settings follow edits every frame:
  `syncTransforms`); a trail draws only while its parent moves, so the editor shows nothing for
  it until Play.
*/

// A line or trail setting (`Line_Setting_Changed`)
LineField :: enum {
	Width,
	End_Width,
	Color,
	End_Color,
	End_Opacity,
	Joint,
	Round_Caps,
	Closed,
	Texture_Mode,
	Lifetime,
	Min_Distance,
	Emitting,
}

// A change to the selected Line2D or Trail2D: a number (`value`), a choice or color (`text`), a
// checkbox (`flag`)
Line_Setting_Changed :: struct {
	field: LineField,
	value: f32,
	text: string,
	flag: bool,
}

// Whether a kind is a line or trail
NodeKind_IsLine :: proc(kind: NodeKind) -> bool {
	return kind == .Line2D || kind == .Trail2D
}

/*
Applies a line setting to the selected node.

Returns:
- Whether the message was this file's
*/
LineEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	v, ok := m.(Line_Setting_Changed)
	if !ok do return false
	node := selectedNode(s)
	if node == nil || !NodeKind_IsLine(node.kind) do return true
	l := &node.line
	round :: proc(x: f32, places: f32) -> f32 { return math.round(x * places) / places }
	switch v.field {
	case .Width:        l.width = clamp(round(v.value, 10), 0, 500)
	case .End_Width:    l.endWidth = clamp(round(v.value, 10), 0, 500)
	case .Color:        if c, parsed := e.ParseColor(v.text); parsed do l.color = c
	case .End_Color:    if c, parsed := e.ParseColor(v.text); parsed do l.endColor = c
	case .End_Opacity:  l.endColor.a = u8(clamp(math.round(v.value * 255), 0, 255))
	case .Joint:        if j, found := reflect.enum_from_name(e.LineJoint, v.text); found do l.joint = j
	case .Round_Caps:   l.roundCaps = v.flag
	case .Closed:       l.closed = v.flag
	case .Texture_Mode: if t, found := reflect.enum_from_name(e.LineTextureMode, v.text); found do l.textureMode = t
	case .Lifetime:     l.lifetime = clamp(round(v.value, 100), 0.01, 30)
	case .Min_Distance: l.minDistance = clamp(round(v.value, 10), 0.1, 500)
	case .Emitting:     l.emitting = v.flag
	}
	return true
}

/*
The inspector's rows for a Line2D or Trail2D (after its texture): width, colors, joints, caps, a
line's points and closing, a trail's lifetime, spacing and emitting. Keys
`inspector-line-<Field>-<node>`, a line's points `inspector-points-<node>`.
*/
lineInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth: f32) -> []skald.View {
	rows := make([dynamic]skald.View, context.temp_allocator)
	l := node.line
	d := e.DEFAULT_LINE_SETTINGS
	trail := node.kind == .Trail2D
	width := controlWidth + INSPECTOR_LABEL_WIDTH
	Payload :: struct { field: LineField }
	id :: proc(field: LineField, key: int) -> string { return fmt.tprintf("inspector-line-%v-%d", field, key) }
	slider :: proc(ctx: ^skald.Ctx(Msg), field: LineField, key: int, value, lo, hi, step, def: f32, decimals: int, width: f32) -> skald.View {
		return valueSlider(ctx, id(field, key), value, Payload{field}, proc(p: Payload, v: f32) -> Msg { return Line_Setting_Changed{field = p.field, value = v} },
			lo, hi, step = step, decimals = decimals, defaultValue = def, width = width)
	}
	check :: proc(ctx: ^skald.Ctx(Msg), field: LineField, key: int, value: bool) -> skald.View {
		return skald.checkbox(ctx, value, "", Payload{field}, proc(p: Payload, v: bool) -> Msg { return Line_Setting_Changed{field = p.field, flag = v} },
			id = skald.hash_id(id(field, key)))
	}
	choice :: proc(ctx: ^skald.Ctx(Msg), field: LineField, key: int, value: string, names: []string, width: f32) -> skald.View {
		return skald.select(ctx, value, names, Payload{field}, proc(p: Payload, v: string) -> Msg { return Line_Setting_Changed{field = p.field, text = v} },
			id = skald.hash_id(id(field, key)), width = width)
	}
	colorPicker :: proc(ctx: ^skald.Ctx(Msg), field: LineField, key: int, c: [4]u8) -> skald.View {
		linear := skald.rgb(u32(c[0]) << 16 | u32(c[1]) << 8 | u32(c[2]))
		Color :: struct { field: LineField, alpha: u8 }
		return skald.color_picker(ctx, linear, Color{field, c[3]}, proc(p: Color, v: skald.Color) -> Msg {
			// The picker has no alpha: the color's own is kept
			return Line_Setting_Changed{field = p.field, text = fmt.tprintf("#%s%02x", skald.color_to_hex(v), p.alpha)}
		}, id = skald.hash_id(id(field, key)))
	}
	note :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32) -> skald.View {
		return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = width)
	}

	if !trail {
		append(&rows, inspectorRow(ctx, "Points", pointsField(ctx, s, key, node.points[:], controlWidth)))
		append(&rows, note(ctx, "In the node's space: \"x,y x,y ...\". Scripts change them with e.Line2D_SetPoints and e.Line2D_AddPoint.", width))
	}
	append(&rows, inspectorRow(ctx, trail ? "Start width" : "Line width", slider(ctx, .Width, key, l.width, 0, 100, 0.5, d.width, 1, controlWidth)))
	if trail do append(&rows, inspectorRow(ctx, "End width", slider(ctx, .End_Width, key, l.endWidth, 0, 100, 0.5, d.endWidth, 1, controlWidth)))
	append(&rows,
		inspectorRow(ctx, trail ? "Start color" : "Line color", colorPicker(ctx, .Color, key, transmute([4]u8)l.color)),
		inspectorRow(ctx, "End color", colorPicker(ctx, .End_Color, key, transmute([4]u8)l.endColor)),
		inspectorRow(ctx, "Opacity at end", slider(ctx, .End_Opacity, key, f32(l.endColor.a) / 255, 0, 1, 0.01, 1, 2, controlWidth)),
		inspectorRow(ctx, "Joints", choice(ctx, .Joint, key, fmt.tprint(l.joint), reflect.enum_field_names(e.LineJoint), controlWidth)),
		inspectorRow(ctx, "Round caps", check(ctx, .Round_Caps, key, l.roundCaps)),
	)
	if !trail do append(&rows, inspectorRow(ctx, "Closed", check(ctx, .Closed, key, l.closed)))
	if node.texture != "" do append(&rows, inspectorRow(ctx, "Texture mode", choice(ctx, .Texture_Mode, key, fmt.tprint(l.textureMode), reflect.enum_field_names(e.LineTextureMode), controlWidth)))
	if trail {
		append(&rows,
			inspectorRow(ctx, "Trail length (s)", slider(ctx, .Lifetime, key, l.lifetime, 0.01, 5, 0.01, d.lifetime, 2, controlWidth)),
			inspectorRow(ctx, "Point spacing", slider(ctx, .Min_Distance, key, l.minDistance, 0.1, 100, 0.5, d.minDistance, 1, controlWidth)),
			inspectorRow(ctx, "Emitting", check(ctx, .Emitting, key, l.emitting)),
		)
		scene := &s.project.scenes[s.currentScene]
		parent := node.parent >= 0 ? scene.nodes[node.parent].name : "nothing"
		append(&rows, note(ctx, fmt.tprintf("Follows %s through the world as it moves (it shows in Play, not here). Scripts: e.Trail2D_SetEmitting, e.Trail2D_Clear after a teleport.", parent), width))
	}
	return rows[:]
}
