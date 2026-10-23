package crossfire_editor

import "core:fmt"
import "core:reflect"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
2D lighting in the editor (the engine's lighting.odin): a scene's lighting (its settings in the
browser's scene preview: Lit, ambient color, static bodies' shadows), Light2D nodes and
LightOccluder nodes.

- **Data:** `NodeDef.light` is the engine's `e.LightSettings` (a plain value). An occluder's
  shape is the CollisionShape fields (`shape`, `shapeSize`, `radius`, `points`), edited with the
  same rows (`shapeRows`) and written the same way. A scene's lighting is in its
  `e.SceneSettings` (`lighting`, `ambient`, `bodyShadows`).
- **Messages:** `Light_Setting_Changed{field, value, text, flag}` (a node step; the energy and
  radius sliders merge while dragged), `Scene_Lighting_Changed` (a `.Project` step, like the
  other scene settings).
- **Viewport:** the engine lights the preview as the game will. The header's light-bulb button
  (`viewport.unlit`) shows the scene unlit for editing in the dark. Occluders are outlined, and a
  selected light shows its reach.
*/

// A light setting (`Light_Setting_Changed`)
LightField :: enum {
	Kind,
	Color,
	Energy,
	Radius,
	Angle,
	Shadows,
}

// A change to the selected Light2D: a number (`value`), a choice or color (`text`), a checkbox
// (`flag`)
Light_Setting_Changed :: struct {
	field: LightField,
	value: f32,
	text: string,
	flag: bool,
}

// A change to a scene's lighting (the browser's scene preview)
Scene_Lighting_Changed :: struct {
	scene: int,
	lighting: bool,
	ambient: sdl.Color,
	bodyShadows: bool,
}

/*
Applies a lighting message.

Returns:
- Whether the message was this file's
*/
LightEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case Light_Setting_Changed:
		scene := &s.project.scenes[s.currentScene]
		if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) || scene.nodes[s.selectedNode].kind != .Light2D do return true
		l := &scene.nodes[s.selectedNode].light
		switch v.field {
		case .Kind: if k, ok := reflect.enum_from_name(e.LightKind, v.text); ok do l.kind = k
		case .Color: if c, ok := e.ParseColor(v.text); ok do l.color = c
		case .Energy: l.energy = max(v.value, 0)
		case .Radius: l.radius = max(v.value, 0)
		case .Angle: l.angle = clamp(v.value, 1, 359)
		case .Shadows: l.shadows = v.flag
		}
	case Scene_Lighting_Changed:
		if v.scene < 0 || v.scene >= len(s.project.scenes) || Scene_IsComponent(&s.project.scenes[v.scene]) do return true
		settings := &s.project.scenes[v.scene].settings
		settings.lighting = v.lighting
		settings.ambient = v.ambient
		settings.bodyShadows = v.bodyShadows
	case:
		return false
	}
	return true
}

/*
The inspector's rows for a Light2D or a LightOccluder.
*/
lightInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	width := inspectorRowWidth(controlWidth)
	note :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32, warning := false) -> skald.View {
		return skald.text(text, warning ? ctx.theme.color.warning : ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = width)
	}
	scene := &s.project.scenes[s.currentScene]
	if node.kind == .LightOccluder {
		append(&rows, ..shapeRows(ctx, s, node, key, controlWidth, numberWidth))
		append(&rows, note(ctx, "Blocks light: lights with Shadows stop at its edges.", width))
	} else {
		l := node.light
		Payload :: struct { field: LightField, color: sdl.Color }
		kinds := reflect.enum_field_names(e.LightKind)
		append(&rows, inspectorRow(ctx, "Light kind", skald.select(ctx, fmt.tprint(l.kind), kinds, Payload{.Kind, {}}, proc(p: Payload, v: string) -> Msg { return Light_Setting_Changed{field = p.field, text = v} },
			id = skald.hash_id(fmt.tprintf("inspector-light-Kind-%d", key)), width = controlWidth)))
		linear := skald.rgb(u32(l.color.r) << 16 | u32(l.color.g) << 8 | u32(l.color.b))
		append(&rows, inspectorRow(ctx, "Light color", skald.color_picker(ctx, linear, Payload{.Color, {}}, proc(p: Payload, c: skald.Color) -> Msg {
			return Light_Setting_Changed{field = .Color, text = fmt.tprintf("#%s", skald.color_to_hex(c))}
		}, id = skald.hash_id(fmt.tprintf("inspector-light-Color-%d", key)), width = controlWidth)))
		slide :: proc(p: Payload, v: f32) -> Msg { return Light_Setting_Changed{field = p.field, value = v} }
		d := e.DEFAULT_LIGHT_SETTINGS
		append(&rows, inspectorRow(ctx, "Energy", valueSlider(ctx, fmt.tprintf("inspector-light-Energy-%d", key), l.energy, Payload{.Energy, {}}, slide, 0, 4, step = 0.01, decimals = 2, defaultValue = d.energy, width = controlWidth)))
		append(&rows, inspectorRow(ctx, "Reach", valueSlider(ctx, fmt.tprintf("inspector-light-Radius-%d", key), l.radius, Payload{.Radius, {}}, slide, 0, 2000, step = 1, decimals = 0, defaultValue = d.radius, width = controlWidth)))
		if l.kind == .Spot {
			append(&rows, inspectorRow(ctx, "Cone", valueSlider(ctx, fmt.tprintf("inspector-light-Angle-%d", key), l.angle, Payload{.Angle, {}}, slide, 1, 359, step = 1, decimals = 0, defaultValue = d.angle, width = controlWidth)))
			append(&rows, note(ctx, "The cone faces the node's rotation (0: right).", width))
		}
		append(&rows, inspectorRow(ctx, "Shadows", skald.checkbox(ctx, l.shadows, "", Payload{.Shadows, {}}, proc(p: Payload, v: bool) -> Msg { return Light_Setting_Changed{field = p.field, flag = v} },
			id = skald.hash_id(fmt.tprintf("inspector-light-Shadows-%d", key)))))
		if !scene.settings.lighting {
			append(&rows, note(ctx, fmt.tprintf("%s isn't lit yet: turn on Lit in its settings (select the scene in the browser).", scene.name), width, warning = true))
		}
	}
	_ = th
	return rows[:]
}

/*
The scene preview's lighting rows (view_browser_info.odin): Lit, the ambient color, static bodies'
shadows.
*/
sceneLightingRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, index: int, width: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	settings := s.project.scenes[index].settings
	ambient := settings.ambient.a > 0 ? settings.ambient : e.DEFAULT_AMBIENT
	Payload :: struct { msg: Scene_Lighting_Changed }
	payload := Payload{{index, settings.lighting, ambient, settings.bodyShadows}}
	append(&rows, skald.checkbox(ctx, settings.lighting, "Lit (dark outside its lights)", payload,
		proc(p: Payload, on: bool) -> Msg { m := p.msg; m.lighting = on; return m },
		id = skald.hash_id("scene-settings-lighting")))
	if settings.lighting {
		linear := skald.rgb(u32(ambient.r) << 16 | u32(ambient.g) << 8 | u32(ambient.b))
		append(&rows, skald.row(
			skald.text("Ambient", th.color.fg_muted, th.font.size_xs),
			skald.color_picker(ctx, linear, payload, proc(p: Payload, c: skald.Color) -> Msg {
				m := p.msg
				m.ambient, _ = e.ParseColor(fmt.tprintf("#%s", skald.color_to_hex(c)))
				return m
			}, id = skald.hash_id("scene-settings-ambient"), width = 90),
			spacing = th.spacing.xs, cross_align = .Center,
		))
		append(&rows, skald.checkbox(ctx, settings.bodyShadows, "Static bodies cast shadows", payload,
			proc(p: Payload, on: bool) -> Msg { m := p.msg; m.bodyShadows = on; return m },
			id = skald.hash_id("scene-settings-body-shadows")))
		append(&rows, skald.text("Add Light2D nodes to light it, LightOccluder nodes for shadows.", th.color.fg_muted, th.font.size_xs, max_width = width))
	}
	return rows[:]
}
