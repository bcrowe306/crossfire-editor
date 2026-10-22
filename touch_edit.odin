package crossfire_editor

import "core:fmt"
import "core:math"
import "core:reflect"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Touch controls in the editor (the engine's touch.odin): VirtualJoystick nodes (an on-screen stick
pushing four input actions) and TouchButton nodes (a round button pressing one).

- **Data:** `NodeDef.touch` is the engine's `e.TouchControlSettings` (a plain value);
  `NodeDef.touchActions` the actions, comma-separated as scene files keep them (owned); a
  button's label is `text`.
- **Messages:** `Touch_Setting_Changed{field, value, text, flag, index}`, a node step (sliders
  merge while dragged).
- **Viewport:** the preview always draws them (`showTouchControls`), at their position; the
  inspector warns when the node is on a layer the camera moves.
*/

// A touch control setting (`Touch_Setting_Changed`)
TouchField :: enum {
	Action,
	Radius,
	Deadzone,
	Zone_Width,
	Zone_Height,
	Floating,
	Visibility,
	Mouse,
	Color,
	Opacity,
}

// A change to the selected VirtualJoystick or TouchButton: a number (`value`), a choice or color
// (`text`; an action: `index` 0..3), a checkbox (`flag`)
Touch_Setting_Changed :: struct {
	field: TouchField,
	value: f32,
	text: string,
	flag: bool,
	index: int,
}

// The choice for "no action"
TOUCH_ACTION_NONE :: "(none)"

// Whether a kind is a touch control
NodeKind_IsTouchControl :: proc(kind: NodeKind) -> bool {
	return kind == .VirtualJoystick || kind == .TouchButton
}

/*
Applies a touch control setting to the selected node.

Returns:
- Whether the message was this file's
*/
TouchEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	v, ok := m.(Touch_Setting_Changed)
	if !ok do return false
	node := selectedNode(s)
	if node == nil || !NodeKind_IsTouchControl(node.kind) do return true
	t := &node.touch
	// Short numbers in scene files
	round :: proc(x: f32, places: f32) -> f32 { return math.round(x * places) / places }
	switch v.field {
	case .Action:
		actions := e.TouchControl_ParseActions(node.touchActions)
		if v.index < 0 || v.index > 3 do break
		actions[v.index] = v.text == TOUCH_ACTION_NONE ? "" : v.text
		// The names are slices of the old text: formatted before it's freed
		formatted := strings.clone(e.TouchControl_FormatActions(actions))
		delete(node.touchActions)
		node.touchActions = formatted
	case .Radius:      t.radius = clamp(math.round(v.value), 4, 1000)
	case .Deadzone:    t.deadzone = clamp(round(v.value, 100), 0, 0.95)
	case .Zone_Width:  t.zone.x = clamp(math.round(v.value), 0, 4000)
	case .Zone_Height: t.zone.y = clamp(math.round(v.value), 0, 4000)
	case .Floating:    t.floating = v.flag
	case .Visibility:  if vis, found := reflect.enum_from_name(e.TouchVisibility, v.text); found do t.visibility = vis
	case .Mouse:       t.mouse = v.flag
	case .Color:       if c, parsed := e.ParseColor(v.text); parsed do t.color = c
	case .Opacity:     t.opacity = clamp(round(v.value, 100), 0, 1)
	}
	return true
}

/*
The inspector's rows for a VirtualJoystick or TouchButton: its actions, size, zone, look and
when it shows. Keys `inspector-touch-<Field>-<node>` (an action: `-Action<i>-`).
*/
touchInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth: f32) -> []skald.View {
	rows := make([dynamic]skald.View, context.temp_allocator)
	t := node.touch
	d := e.TouchControl_Defaults(node.kind)
	width := controlWidth + INSPECTOR_LABEL_WIDTH
	joystick := node.kind == .VirtualJoystick
	note :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32, warning := false) -> skald.View {
		return skald.text(text, warning ? ctx.theme.color.warning : ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = width)
	}
	Payload :: struct { field: TouchField, index: int }
	onNumber :: proc(p: Payload, v: f32) -> Msg { return Touch_Setting_Changed{field = p.field, value = v} }
	onFlag :: proc(p: Payload, v: bool) -> Msg { return Touch_Setting_Changed{field = p.field, flag = v} }
	onText :: proc(p: Payload, v: string) -> Msg { return Touch_Setting_Changed{field = p.field, text = v, index = p.index} }
	id :: proc(field: TouchField, key: int, index := -1) -> string {
		return index < 0 ? fmt.tprintf("inspector-touch-%v-%d", field, key) : fmt.tprintf("inspector-touch-%v%d-%d", field, index, key)
	}
	slider :: proc(ctx: ^skald.Ctx(Msg), field: TouchField, key: int, value, lo, hi, step, def: f32, decimals: int, width: f32) -> skald.View {
		return valueSlider(ctx, id(field, key), value, Payload{field, -1}, onNumber, lo, hi, step = step, decimals = decimals, defaultValue = def, width = width)
	}
	check :: proc(ctx: ^skald.Ctx(Msg), field: TouchField, key: int, value: bool) -> skald.View {
		return skald.checkbox(ctx, value, "", Payload{field, -1}, onFlag, id = skald.hash_id(id(field, key)))
	}

	// The actions: the project's (Project Settings > Input)
	choices := make([dynamic]string, context.temp_allocator)
	append(&choices, TOUCH_ACTION_NONE)
	for a in s.project.actions do append(&choices, a.name)
	actions := e.TouchControl_ParseActions(node.touchActions)
	labels := joystick ? []string{"Left action", "Right action", "Up action", "Down action"} : []string{"Input action"}
	for label, i in labels {
		current := actions[i] == "" ? TOUCH_ACTION_NONE : actions[i]
		append(&rows, inspectorRow(ctx, label, skald.select(ctx, current, choices[:], Payload{.Action, i}, onText,
			id = skald.hash_id(id(.Action, key, i)), width = controlWidth)))
		known := actions[i] == ""
		for a in s.project.actions do if a.name == actions[i] do known = true
		if !known do append(&rows, note(ctx, fmt.tprintf("No input action is called %s (Project Settings > Input).", actions[i]), width, warning = true))
	}
	if len(s.project.actions) == 0 do append(&rows, note(ctx, "No input actions yet: add them in Project Settings > Input.", width))
	if !joystick {
		append(&rows, inspectorRow(ctx, "Label", skald.text_input(ctx, node.text, NodeTextField.Text, proc(field: NodeTextField, v: string) -> Msg { return Node_Text_Changed{field, v} },
			id = skald.hash_id(fmt.tprintf("inspector-touch-Label-%d", key)), width = controlWidth, padding = InspectorFieldPadding(ctx), placeholder = "A")))
	}

	append(&rows,
		inspectorRow(ctx, "Size radius", slider(ctx, .Radius, key, t.radius, 4, 300, 1, d.radius, 0, controlWidth)),
	)
	if joystick do append(&rows, inspectorRow(ctx, "Deadzone", slider(ctx, .Deadzone, key, t.deadzone, 0, 0.95, 0.01, d.deadzone, 2, controlWidth)))
	append(&rows,
		inspectorRow(ctx, "Touch zone width", slider(ctx, .Zone_Width, key, t.zone.x, 0, 2000, 1, 0, 0, controlWidth)),
		inspectorRow(ctx, "Touch zone height", slider(ctx, .Zone_Height, key, t.zone.y, 0, 2000, 1, 0, 0, controlWidth)),
	)
	if joystick do append(&rows, inspectorRow(ctx, "Floating", check(ctx, .Floating, key, t.floating)))
	visibilities := reflect.enum_field_names(e.TouchVisibility)
	append(&rows,
		inspectorRow(ctx, "Shows", skald.select(ctx, fmt.tprint(t.visibility), visibilities, Payload{.Visibility, -1}, onText,
			id = skald.hash_id(id(.Visibility, key)), width = controlWidth)),
		inspectorRow(ctx, "Mouse works it", check(ctx, .Mouse, key, t.mouse)),
	)
	linear := skald.rgb(u32(t.color.r) << 16 | u32(t.color.g) << 8 | u32(t.color.b))
	append(&rows,
		inspectorRow(ctx, "Control color", skald.color_picker(ctx, linear, Payload{.Color, -1}, proc(p: Payload, c: skald.Color) -> Msg {
			return Touch_Setting_Changed{field = .Color, text = fmt.tprintf("#%s", skald.color_to_hex(c))}
		}, id = skald.hash_id(id(.Color, key)))),
		inspectorRow(ctx, "Opacity", slider(ctx, .Opacity, key, t.opacity, 0, 1, 0.01, d.opacity, 2, controlWidth)),
	)

	// Where it is: on a layer the camera moves, it scrolls away with the world
	scene := &s.project.scenes[s.currentScene]
	if !(e.RenderLayer(clamp(node.layer, 0, len(e.RenderLayer) - 1)) in scene.settings.screenLayers) && Scene_HasCamera(scene) {
		append(&rows, note(ctx, fmt.tprintf("%v moves with the camera: put it on a screen layer (select the scene in the browser > Screen layers) so it stays put.", node.layer), width, warning = true))
	}
	zone := t.zone.x > 0 && t.zone.y > 0 ? fmt.tprintf("a %.0f x %.0f zone around it", t.zone.x, t.zone.y) : "its circle"
	if joystick {
		append(&rows, note(ctx, fmt.tprintf("A finger landing on %s moves the stick%s; it pushes the actions above as far as it's pushed (scripts: e.Input_GetVector, or e.VirtualJoystick_GetVector).", zone, t.floating ? ", which starts where the finger lands" : ""), width))
	} else {
		append(&rows, note(ctx, fmt.tprintf("A finger on %s presses the action while it's held (events: onPressed, onReleased).", zone), width))
	}
	append(&rows, note(ctx, "Touch_Screens: shown once the screen is touched, and in Play from the editor; desktop players don't see it.", width))
	return rows[:]
}

// Whether a scene has a Camera node (touch controls on its world layers scroll with it)
@(private="file")
Scene_HasCamera :: proc(scene: ^SceneDef) -> bool {
	for &n in scene.nodes do if n.kind == .Camera do return true
	return false
}
