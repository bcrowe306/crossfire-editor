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
		return labeledSelect(ctx, value == "" ? TEXTURE_NONE : value, Asset_DisplayNames(list[:]), list[:], payload, onChoice, id = skald.hash_id(key), width = width)
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
			return uiText(th, .Label, fmt.tprintf("%s (node fields work on node scripts)", value == "" ? "none" : value), max_width = controlWidth)
		}
		return choices(ctx, value, NodeField_Choices(&s.project, scene, s.selectedNode, field.hint), payload, id(field, key), controlWidth)
	}
	return uiText(th, .Label, value)
}

/*
A dropdown showing `labels` that chooses `values` (the same length, in order): assets listed by
name (`Asset_DisplayName`) while their paths are what's stored. A value without a label shows as
itself.
*/
labeledSelect :: proc(ctx: ^skald.Ctx(Msg), value: string, labels, values: []string, payload: $P, onChange: proc(P, string) -> Msg,
	id: skald.Widget_ID = 0, width: f32 = 0, placeholder := "") -> skald.View {
	Labeled :: struct { inner: P, labels, values: []string, onChange: proc(P, string) -> Msg }
	shown := value
	for v, i in values do if v == value { shown = labels[i]; break }
	return skald.select(ctx, shown, labels, Labeled{payload, labels, values, onChange}, proc(p: Labeled, label: string) -> Msg {
		for l, i in p.labels do if l == label do return p.onChange(p.inner, p.values[i])
		return p.onChange(p.inner, label)
	}, id = id, width = width, placeholder = placeholder)
}

/*
The labels for a list of asset paths (`Asset_DisplayName`), `TEXTURE_NONE` kept as it is.
*/
Asset_DisplayNames :: proc(paths: []string) -> []string {
	labels := make([]string, len(paths), context.temp_allocator)
	for p, i in paths do labels[i] = p == TEXTURE_NONE ? p : Asset_DisplayName(p)
	return labels
}

/*
Whether a stored value fits a field's type as the engine reads it (script.odin's
`Script_SetField`): a number, an integer, true / false, two numbers, a color, one of the enum's
names. Text, asset and node fields take anything. A value that doesn't fit (the field's type
changed in the code) makes the game use the default, with a warning.
*/
ScriptProp_Fits :: proc(field: ^ScriptFieldDesc, value: string) -> bool {
	text := strings.trim_space(value)
	if text == "" do return true
	switch field.type {
	case .Float:
		_, ok := strconv.parse_f64(text)
		return ok
	case .Int:
		_, ok := strconv.parse_int(text)
		return ok
	case .Bool:
		return text == "true" || text == "false" || text == "1" || text == "0"
	case .Vector2:
		x, _, y := strings.partition(text, ",")
		_, okX := strconv.parse_f32(strings.trim_space(x))
		_, okY := strconv.parse_f32(strings.trim_space(y))
		return okX && okY
	case .Color:
		_, ok := e.ParseColor(text)
		return ok
	case .Enum:
		for name in field.enumNames do if name == text do return true
		return false
	case .String, .Texture, .Sound, .Font, .Data, .Component, .Music, .Animation, .Node:
		return true
	}
	return true
}

/*
The rows under a field whose stored value doesn't fit its type any more (the code changed it: a
number field became a bool): the value is kept, and the inspector says the game uses the default
instead, with a Reset that removes it (undoable). None when it fits or nothing is stored.

Widget keys: `inspector-mismatch-<field>-<key>`, its Reset `inspector-mismatch-reset-<field>-<key>`.
*/
FieldMismatchRows :: proc(ctx: ^skald.Ctx(Msg), values: []ScriptPropDef, field: ^ScriptFieldDesc, key: string, target: PropTarget, width: f32) -> []skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	stored, set := "", false
	for p in values do if p.name == field.name { stored, set = p.value, true }
	if !set || ScriptProp_Fits(field, stored) do return nil
	rows := make([dynamic]skald.View, context.temp_allocator)
	note := uiText(th, .Muted, fmt.tprintf("Stored %q isn't a %v: the game uses the default (%s).", stored, field.type, field.defaultValue == "" ? "\"\"" : field.defaultValue), max_width = width, color = th.color.warning)
	reset := skald.button(ctx, "Reset", Msg(Script_Prop_Changed{field.name, field.defaultValue, field.defaultValue, target}),
		id = skald.hash_id(fmt.tprintf("inspector-mismatch-reset-%s-%s", field.name, key)),
		bg = th.color.surface, fg = th.color.fg, padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm)
	append(&rows, skald.row(skald.tooltip(ctx, note, "The code changed the field's type: Reset removes the stored value", id = skald.hash_id(fmt.tprintf("inspector-mismatch-%s-%s", field.name, key))), reset, spacing = th.spacing.xs, cross_align = .Center))
	return rows[:]
}

/*
Rows for the stored values of fields the code doesn't have (renamed or removed in it, before or
after a build): kept, not silently deleted, listed read only under the fields with a × each that
removes one (an undoable edit). None when every value has its field.

Widget keys: `inspector-orphan-<name>-<key>`, its × `inspector-orphan-remove-<name>-<key>`.
*/
OrphanedValueRows :: proc(ctx: ^skald.Ctx(Msg), values: []ScriptPropDef, desc: ^ScriptDesc, key: string, target: PropTarget, width: f32) -> []skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	if desc == nil do return nil
	rows := make([dynamic]skald.View, context.temp_allocator)
	for p in values {
		known := false
		for f in desc.fields do if f.name == p.name do known = true
		if known do continue
		if len(rows) == 0 {
			append(&rows, uiText(th, .Muted, fmt.tprintf("Stored values %s has no field for (kept until removed; renamed or removed in the code?):", desc.name), max_width = width, color = th.color.warning))
		}
		remove := skald.button(ctx, ICON_XMARK, Msg(Script_Prop_Changed{p.name, "", "", target}),
			id = skald.hash_id(fmt.tprintf("inspector-orphan-remove-%s-%s", p.name, key)),
			bg = th.color.surface, fg = th.color.fg_muted, padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm)
		value := uiText(th, .Label, p.value, max_width = max(width - tk.fieldS, tk.fieldXS))
		append(&rows, inspectorRow(ctx, p.name, skald.row(skald.tooltip(ctx, value, fmt.tprintf("%s = %s, kept", p.name, p.value), id = skald.hash_id(fmt.tprintf("inspector-orphan-%s-%s", p.name, key))), remove, spacing = th.spacing.xs, cross_align = .Center),
			"Kept from a field the script no longer has: the game ignores it. × removes it"))
	}
	return rows[:]
}
