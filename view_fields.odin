package crossfire_editor

import "core:fmt"
import "core:strconv"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The control for one exported field (a script's on a node, a global's, a data resource's), by
its type: number fields, checkbox, text or a scene dropdown, two numbers for vectors, a color
picker, an enum dropdown, and for asset handles a dropdown of the project's assets of that kind
(Data fields: of that data type, from the field's `kind=`), and for node fields a dropdown of
the scene's nodes of that type, as paths from the script's node (node_fields.odin). It edits the value text in `values`
through `Script_Prop_Changed{target = ...}`.

Widget keys: `inspector-prop-<field>-<key>` (`-x` / `-y` for a vector's parts).
*/
FieldControl :: proc(ctx: ^skald.Ctx(Msg), s: ^State, values: []ScriptPropDef, field: ^ScriptFieldDesc, key: string, target: PropTarget, controlWidth, numberWidth: f32) -> skald.View {
	th := ctx.theme
	value := Props_Value(values, field.name, field.defaultValue)
	id :: proc(field: ^ScriptFieldDesc, key: string, part := "") -> string {
		return fmt.tprintf("inspector-prop-%s%s-%s", field.name, part, key)
	}
	Payload :: struct {
		name, defaultValue: string,
		target: PropTarget,
	}
	payload := Payload{field.name, field.defaultValue, target}
	onText :: proc(p: Payload, v: string) -> Msg { return Script_Prop_Changed{p.name, v, p.defaultValue, p.target} }
	// Dropdowns with a "None" choice
	onChoice :: proc(p: Payload, v: string) -> Msg { return Script_Prop_Changed{p.name, v == TEXTURE_NONE ? "" : v, p.defaultValue, p.target} }
	choices :: proc(ctx: ^skald.Ctx(Msg), value: string, options: []string, payload: Payload, key: string, width: f32) -> skald.View {
		list := make([dynamic]string, context.temp_allocator)
		append(&list, TEXTURE_NONE)
		append(&list, ..options)
		return skald.select(ctx, value == "" ? TEXTURE_NONE : value, list[:], payload, onChoice, id = skald.hash_id(key), width = width)
	}
	assetsOf :: proc(s: ^State, kind: AssetKind) -> []string {
		paths := make([dynamic]string, context.temp_allocator)
		for asset in s.project.assets do if asset.kind == kind do append(&paths, asset.path)
		return paths[:]
	}
	lo := field.min.? or_else min(f64)
	hi := field.max.? or_else max(f64)

	switch field.type {
	case .Float, .Int:
		number, _ := strconv.parse_f64(strings.trim_space(value))
		numberTarget := ScriptPropTarget{name = field.name, defaultValue = field.defaultValue, integer = field.type == .Int, component = -1, target = target}
		return numberField(ctx, s, id(field, key), numberTarget, number, 1, field.type == .Int ? 0 : 2, numberWidth, lo, hi)
	case .Bool:
		return skald.checkbox(ctx, value == "true", "", payload,
			proc(p: Payload, v: bool) -> Msg { return Script_Prop_Changed{p.name, v ? "true" : "false", p.defaultValue, p.target} },
			id = skald.hash_id(id(field, key)))
	case .String:
		if field.hint == "scene" {
			scenes := make([dynamic]string, context.temp_allocator)
			append(&scenes, ..Project_SceneNames(&s.project))
			return choices(ctx, value, scenes[:], payload, id(field, key), controlWidth)
		}
		return skald.text_input(ctx, strings.clone(value, context.temp_allocator), payload, onText, id = skald.hash_id(id(field, key)), width = controlWidth, padding = InspectorFieldPadding(ctx))
	case .Vector2:
		xText, _, yText := strings.partition(value, ",")
		x, _ := strconv.parse_f64(strings.trim_space(xText))
		y, _ := strconv.parse_f64(strings.trim_space(yText))
		half := max((controlWidth - th.spacing.xs) * 0.5, 60)
		return skald.row(
			numberField(ctx, s, id(field, key, "-x"), ScriptPropTarget{field.name, field.defaultValue, false, 0, y, target}, x, 1, 1, half, lo, hi),
			numberField(ctx, s, id(field, key, "-y"), ScriptPropTarget{field.name, field.defaultValue, false, 1, x, target}, y, 1, 1, half, lo, hi),
			spacing = th.spacing.xs,
		)
	case .Color:
		color, ok := e.ParseColor(value)
		if !ok do color = {255, 255, 255, 255}
		linear := skald.rgb(u32(color.r) << 16 | u32(color.g) << 8 | u32(color.b))
		return skald.color_picker(ctx, linear, payload,
			proc(p: Payload, c: skald.Color) -> Msg { return Script_Prop_Changed{p.name, fmt.tprintf("#%s", strings.to_lower(skald.color_to_hex(c), context.temp_allocator)), p.defaultValue, p.target} },
			id = skald.hash_id(id(field, key)), width = controlWidth)
	case .Enum:
		return skald.select(ctx, value, field.enumNames[:], payload, onText, id = skald.hash_id(id(field, key)), width = controlWidth)
	case .Texture: return choices(ctx, value, assetsOf(s, .Image), payload, id(field, key), controlWidth)
	case .Sound:   return choices(ctx, value, assetsOf(s, .Audio), payload, id(field, key), controlWidth)
	case .Music:   return choices(ctx, value, assetsOf(s, .Music), payload, id(field, key), controlWidth)
	case .Font:    return choices(ctx, value, assetsOf(s, .Font), payload, id(field, key), controlWidth)
	case .Data:    return choices(ctx, value, Project_DataOfType(&s.project, field.hint), payload, id(field, key), controlWidth)
	case .Component: return choices(ctx, value, assetsOf(s, .Component), payload, id(field, key), controlWidth)
	case .Animation:
		// Animation files and Aseprite files (their tags)
		paths := make([dynamic]string, context.temp_allocator)
		for asset in s.project.assets do if Asset_IsAnimations(asset) do append(&paths, asset.path)
		return choices(ctx, value, paths[:], payload, id(field, key), controlWidth)
	case .Node:
		// The scene's nodes that fit, as paths from the script's node (node_fields.odin)
		scene := &s.project.scenes[s.currentScene]
		onNode := false
		switch _ in target {
		case SelectedNodeTarget, NodeScriptTarget, NodeCustomTarget: onNode = true
		case DraftGlobalTarget, DataTarget:
		}
		if !onNode || s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) {
			return skald.text(fmt.tprintf("%s (node fields work on node scripts)", value == "" ? "none" : value), th.color.fg_muted, th.font.size_sm, max_width = controlWidth)
		}
		return choices(ctx, value, NodeField_Choices(&s.project, scene, s.selectedNode, field.hint), payload, id(field, key), controlWidth)
	}
	return skald.text(value, th.color.fg_muted, th.font.size_sm)
}
