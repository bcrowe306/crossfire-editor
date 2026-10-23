package crossfire_editor

import "core:fmt"
import "core:reflect"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
UI controls in the editor (the engine's ui_controls.odin): Panel, Button, ProgressBar,
TextField, ScrollBox and RichText nodes.

- **Data:** `NodeDef.ui` is the engine's `e.UISettings` (its strings owned:
  `e.UISettings_Clone` / `_Destroy`; `UISettings_Equal`). Text is the node's `text`, an image its
  `texture` (the usual `Node_Text_Changed` fields). Every other setting is one message,
  `UI_Setting_Changed{field, value, text, flag}`, a node step (numbers and typing merge).
- **Inspector** (`uiInspectorRows`): the rows a kind uses; a control its parent lays out says so
  (its position is the layout's then).
- **Viewport:** the engine lays controls out and draws them, so the viewport shows them as the
  game will (anchors against the game area). Dragging a control moves its offset from its anchor
  (`NodeDef.position`; `syncTransforms` hands it to the engine's `Control.offset`).
*/

// A control setting (`UI_Setting_Changed`)
UIField :: enum {
	Width,
	Height,
	Anchor,
	Margin,
	Layout,
	Align,
	Justify,
	Columns,
	Padding,
	Spacing,
	Expand,
	Disabled,
	Value,
	Min,
	Max,
	Direction,
	Show_Value,
	Show_Loading,
	Max_Length,
	Patch_Left,
	Patch_Top,
	Patch_Right,
	Patch_Bottom,
	Text_Size,
	Text_Align,
	Theme,
	Placeholder,
	Action,
}

// A change to the selected control's settings: a number (`value`), a choice or text (`text`),
// a checkbox (`flag`)
UI_Setting_Changed :: struct {
	field: UIField,
	value: f64,
	text: string,
	flag: bool,
}

// The control number fields' target (number_field.odin)
UINumberTarget :: distinct UIField

// The theme choice that means "its parent's"
UI_THEME_INHERITED :: "(its parent's)"
// The action choice for none
UI_ACTION_NONE :: "(none: scripts listen to onPressed)"

/*
Whether a node kind is a UI control.
*/
NodeKind_IsControl :: proc(kind: NodeKind) -> bool {
	#partial switch kind {
	case .Panel, .Button, .ProgressBar, .TextField, .ScrollBox, .RichText: return true
	}
	return false
}

/*
Whether two control settings are the same.
*/
UISettings_Equal :: proc(a, b: e.UISettings) -> bool {
	x, y := a, b
	x.theme, x.placeholder, x.action = "", "", ""
	y.theme, y.placeholder, y.action = "", "", ""
	return x == y && a.theme == b.theme && a.placeholder == b.placeholder && a.action == b.action
}

/*
Applies a control setting to the selected node.

Returns:
- Whether the message was this file's
*/
UIEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	v, ok := m.(UI_Setting_Changed)
	if !ok do return false
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) || !NodeKind_IsControl(scene.nodes[s.selectedNode].kind) do return true
	u := &scene.nodes[s.selectedNode].ui
	n := f32(v.value)
	enumFrom :: proc(text: string, $E: typeid) -> (E, bool) { return reflect.enum_from_name(E, text) }
	setText :: proc(to: ^string, text: string) {
		delete(to^)
		to^ = strings.clone(text)
	}
	switch v.field {
	case .Width: u.size.x = max(n, 0)
	case .Height: u.size.y = max(n, 0)
	case .Margin: u.margin = n
	case .Columns: u.columns = max(int(n), 1)
	case .Padding: u.padding = max(n, -1)
	case .Spacing: u.spacing = max(n, -1)
	case .Value: u.value = n
	case .Min: u.minValue = n
	case .Max: u.maxValue = n
	case .Max_Length: u.maxLength = max(int(n), 0)
	case .Patch_Left: u.patchMargins[0] = max(n, 0)
	case .Patch_Top: u.patchMargins[1] = max(n, 0)
	case .Patch_Right: u.patchMargins[2] = max(n, 0)
	case .Patch_Bottom: u.patchMargins[3] = max(n, 0)
	case .Text_Size: u.textSize = max(n, 0)
	case .Expand: u.expand = v.flag
	case .Disabled: u.disabled = v.flag
	case .Show_Value: u.showValue = v.flag
	case .Show_Loading: u.showLoading = v.flag
	case .Anchor: if x, found := enumFrom(v.text, e.UIAnchor); found do u.anchor = x
	case .Layout: if x, found := enumFrom(v.text, e.UILayout); found do u.layout = x
	case .Align: if x, found := enumFrom(v.text, e.UIAlign); found do u.align = x
	case .Justify: if x, found := enumFrom(v.text, e.UIAlign); found do u.justify = x
	case .Direction: if x, found := enumFrom(v.text, e.ProgressDirection); found do u.direction = x
	case .Text_Align: if x, found := enumFrom(v.text, e.UITextAlign); found do u.textAlign = x
	case .Theme: setText(&u.theme, v.text == UI_THEME_INHERITED ? "" : v.text)
	case .Placeholder: setText(&u.placeholder, v.text)
	case .Action: setText(&u.action, uiActionFromChoice(v.text))
	}
	return true
}

// "Go to Level1" -> "scene:Level1", "Quit the game" -> "quit"
@(private="file")
uiActionFromChoice :: proc(choice: string) -> string {
	switch {
	case choice == UI_ACTION_NONE: return ""
	case choice == "Quit the game": return "quit"
	case choice == "Close this (back to the scene under it)": return "pop"
	case strings.has_prefix(choice, "Go to "): return fmt.tprintf("scene:%s", choice[len("Go to "):])
	case strings.has_prefix(choice, "Open ") && strings.has_suffix(choice, " over this"): return fmt.tprintf("push:%s", choice[len("Open "):len(choice) - len(" over this")])
	}
	return choice
}

@(private="file")
uiActionChoice :: proc(action: string) -> string {
	switch {
	case action == "": return UI_ACTION_NONE
	case action == "quit": return "Quit the game"
	case action == "pop": return "Close this (back to the scene under it)"
	case strings.has_prefix(action, "scene:"): return fmt.tprintf("Go to %s", action[len("scene:"):])
	case strings.has_prefix(action, "push:"): return fmt.tprintf("Open %s over this", action[len("push:"):])
	}
	return action
}

/*
The inspector's rows for a UI control: its size and place, then its kind's settings.
*/
uiInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	u := &node.ui
	scene := &s.project.scenes[s.currentScene]
	number :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: UIField, value: f32, step: f32, decimals: int, width: f32, lo: f64 = -100000, hi: f64 = 100000) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("inspector-ui-%v-%d", field, key), UINumberTarget(field), f64(value), f64(step), decimals, width, lo, hi)
	}
	choice :: proc(ctx: ^skald.Ctx(Msg), key: int, field: UIField, value: string, choices: []string, width: f32) -> skald.View {
		Payload :: struct { field: UIField }
		return skald.select(ctx, value, choices, Payload{field}, proc(p: Payload, v: string) -> Msg { return UI_Setting_Changed{field = p.field, text = v} },
			id = skald.hash_id(fmt.tprintf("inspector-ui-%v-%d", field, key)), width = width)
	}
	enumChoice :: proc(ctx: ^skald.Ctx(Msg), key: int, field: UIField, value: $E, width: f32) -> skald.View {
		names := reflect.enum_field_names(E)
		return choice(ctx, key, field, fmt.tprint(value), names, width)
	}
	check :: proc(ctx: ^skald.Ctx(Msg), key: int, field: UIField, value: bool) -> skald.View {
		Payload :: struct { field: UIField }
		return skald.checkbox(ctx, value, "", Payload{field}, proc(p: Payload, v: bool) -> Msg { return UI_Setting_Changed{field = p.field, flag = v} },
			id = skald.hash_id(fmt.tprintf("inspector-ui-%v-%d", field, key)))
	}
	note :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32) -> skald.View {
		return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = width)
	}
	onText :: proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} }
	width := inspectorRowWidth(controlWidth)

	// Where it goes: by its parent's layout, or its anchor
	parent := node.parent >= 0 ? &scene.nodes[node.parent] : nil
	laidOut := parent != nil && NodeKind_IsControl(parent.kind) && (parent.ui.layout != .None || parent.kind == .ScrollBox)
	append(&rows, inspectorRow(ctx, "Width", number(ctx, s, key, .Width, u.size.x, 1, 0, numberWidth, 0)))
	append(&rows, inspectorRow(ctx, "Height", number(ctx, s, key, .Height, u.size.y, 1, 0, numberWidth, 0)))
	append(&rows, note(ctx, "0: as big as what's in it.", width))
	if laidOut {
		layout := parent.kind == .ScrollBox ? "column" : strings.to_lower(fmt.tprint(parent.ui.layout), context.temp_allocator)
		append(&rows, note(ctx, fmt.tprintf("Placed by %s's %s layout: its position is ignored.", parent.name, layout), width))
		if parent.ui.layout == .Row || parent.ui.layout == .Column || parent.kind == .ScrollBox {
			append(&rows, inspectorRow(ctx, "Expand", check(ctx, key, .Expand, u.expand)))
		}
	} else {
		append(&rows, inspectorRow(ctx, "Anchor", enumChoice(ctx, key, .Anchor, u.anchor, controlWidth)))
		#partial switch u.anchor {
		case .Full, .Top_Wide, .Bottom_Wide, .Left_Tall, .Right_Tall:
			append(&rows, inspectorRow(ctx, "Edge margin", number(ctx, s, key, .Margin, u.margin, 1, 0, numberWidth)))
		}
		anchoredTo := parent == nil ? "the screen (the game area)" : NodeKind_IsControl(parent.kind) ? parent.name : fmt.tprintf("%s's position", parent.name)
		append(&rows, note(ctx, fmt.tprintf("Anchored to %s; its position moves it from there.", anchoredTo), width))
	}

	switch node.kind {
	case .Panel, .ScrollBox:
		if node.kind == .Panel do append(&rows, inspectorRow(ctx, "Layout", enumChoice(ctx, key, .Layout, u.layout, controlWidth)))
		if u.layout == .Grid && node.kind == .Panel do append(&rows, inspectorRow(ctx, "Grid columns", number(ctx, s, key, .Columns, f32(u.columns), 1, 0, numberWidth, 1, 64)))
		append(&rows, inspectorRow(ctx, "Align", enumChoice(ctx, key, .Align, u.align, controlWidth)))
		if node.kind == .Panel && (u.layout == .Row || u.layout == .Column) do append(&rows, inspectorRow(ctx, "Justify", enumChoice(ctx, key, .Justify, u.justify, controlWidth)))
		append(&rows, inspectorRow(ctx, "Padding", number(ctx, s, key, .Padding, u.padding, 1, 0, numberWidth, -1)))
		append(&rows, inspectorRow(ctx, "Gap", number(ctx, s, key, .Spacing, u.spacing, 1, 0, numberWidth, -1)))
		append(&rows, note(ctx, "-1: the theme's.", width))
	case .Button:
		append(&rows, inspectorRow(ctx, "Text", skald.text_input(ctx, node.text, NodeTextField.Text, onText,
			id = skald.hash_id(fmt.tprintf("inspector-Text-%d", key)), width = controlWidth, padding = InspectorFieldPadding(ctx))))
		actions := make([dynamic]string, context.temp_allocator)
		append(&actions, UI_ACTION_NONE, "Quit the game", "Close this (back to the scene under it)")
		for name in Project_SceneNames(&s.project) do append(&actions, fmt.tprintf("Go to %s", name))
		for name in Project_SceneNames(&s.project) do append(&actions, fmt.tprintf("Open %s over this", name))
		append(&rows, inspectorRow(ctx, "Action", choice(ctx, key, .Action, uiActionChoice(u.action), actions[:], controlWidth)))
		append(&rows, inspectorRow(ctx, "Can't be used", check(ctx, key, .Disabled, u.disabled)))
		append(&rows, inspectorRow(ctx, "Text align", enumChoice(ctx, key, .Text_Align, u.textAlign, controlWidth)))
	case .ProgressBar:
		append(&rows, inspectorRow(ctx, "Value", number(ctx, s, key, .Value, u.value, 0.1, 2, numberWidth)))
		append(&rows, inspectorRow(ctx, "Min", number(ctx, s, key, .Min, u.minValue, 1, 2, numberWidth)))
		append(&rows, inspectorRow(ctx, "Max", number(ctx, s, key, .Max, u.maxValue, 1, 2, numberWidth)))
		append(&rows, inspectorRow(ctx, "Fills toward", enumChoice(ctx, key, .Direction, u.direction, controlWidth)))
		append(&rows, inspectorRow(ctx, "Show percent", check(ctx, key, .Show_Value, u.showValue)))
		append(&rows, inspectorRow(ctx, "Shows loading", check(ctx, key, .Show_Loading, u.showLoading)))
	case .TextField:
		append(&rows, inspectorRow(ctx, "Text", skald.text_input(ctx, node.text, NodeTextField.Text, onText,
			id = skald.hash_id(fmt.tprintf("inspector-Text-%d", key)), width = controlWidth, padding = InspectorFieldPadding(ctx))))
		Payload :: struct {}
		append(&rows, inspectorRow(ctx, "Placeholder", skald.text_input(ctx, u.placeholder, Payload{}, proc(_: Payload, v: string) -> Msg { return UI_Setting_Changed{field = .Placeholder, text = v} },
			id = skald.hash_id(fmt.tprintf("inspector-ui-Placeholder-%d", key)), width = controlWidth, padding = InspectorFieldPadding(ctx))))
		append(&rows, inspectorRow(ctx, "Max length", number(ctx, s, key, .Max_Length, f32(u.maxLength), 1, 0, numberWidth, 0, 10000)))
		append(&rows, inspectorRow(ctx, "Can't be used", check(ctx, key, .Disabled, u.disabled)))
	case .RichText:
		append(&rows, inspectorRow(ctx, "Text", skald.text_input(ctx, node.text, NodeTextField.Text, onText,
			id = skald.hash_id(fmt.tprintf("inspector-Text-%d", key)), width = controlWidth, padding = InspectorFieldPadding(ctx))))
		append(&rows, note(ctx, "Tags: [color=#ff8000]gold[/color], [size=28]big[/size]. It wraps at its width (0: only at line breaks, \\n).", width))
	case .Node2D, .Sprite, .AnimatedSprite, .Camera, .Label, .Menu, .StaticBody, .DynamicBody, .CharacterMover, .Area,
	     .CollisionShape, .RayCast, .Joint, .ParticleEmitter, .Component, .AudioPlayer, .AudioPlayer2D, .MusicPlayer,
	     .LDtkLevel, .TileMap, .Animator, .Light2D, .LightOccluder, .NavRegion, .NavAgent, .StateMachine, .ParallaxLayer, .CameraZone, .CameraView,
	     .VirtualJoystick, .TouchButton, .ScreenEffect, .Line2D, .Trail2D, .Skeleton2D, .Bone2D, .SkinnedMesh, .IKChain, .DialogueBox:
	}
	if node.kind != .ProgressBar && node.kind != .Panel && node.kind != .ScrollBox {
		append(&rows, inspectorRow(ctx, "Font size", number(ctx, s, key, .Text_Size, u.textSize, 1, 0, numberWidth, 0, 400)))
	}
	// An image instead of the fill (a progress bar's fill), stretched as a 9-patch
	if node.kind != .TextField && node.kind != .RichText {
		images := make([dynamic]string, context.temp_allocator)
		append(&images, TEXTURE_NONE)
		for asset in s.project.assets do if asset.kind == .Image do append(&images, asset.path)
		append(&rows, inspectorRow(ctx, "Image", skald.select(ctx, node.texture == "" ? TEXTURE_NONE : node.texture, images[:], NodeTextField.Texture, onText,
			id = skald.hash_id(fmt.tprintf("inspector-texture-%d", key)), width = controlWidth, placeholder = "The theme's fill")))
		if node.texture != "" {
			m := u.patchMargins
			append(&rows, inspectorRow(ctx, "Edges L / T", skald.row(number(ctx, s, key, .Patch_Left, m[0], 1, 0, numberWidth * 0.5, 0), number(ctx, s, key, .Patch_Top, m[1], 1, 0, numberWidth * 0.5, 0), spacing = 4)))
			append(&rows, inspectorRow(ctx, "Edges R / B", skald.row(number(ctx, s, key, .Patch_Right, m[2], 1, 0, numberWidth * 0.5, 0), number(ctx, s, key, .Patch_Bottom, m[3], 1, 0, numberWidth * 0.5, 0), spacing = 4)))
			append(&rows, note(ctx, "Edges: pixels of the image that don't stretch (a 9-patch); all 0 stretches it whole.", width))
		}
	}
	// Its theme (its parent's when none)
	themes := make([dynamic]string, context.temp_allocator)
	append(&themes, UI_THEME_INHERITED)
	for asset in s.project.assets do if asset.kind == .Theme do append(&themes, asset.path)
	append(&rows, inspectorRow(ctx, "UI theme", choice(ctx, key, .Theme, u.theme == "" ? UI_THEME_INHERITED : u.theme, themes[:], controlWidth)))
	// A theme of its own, made and chosen at once (select it in the browser's Themes to edit it)
	append(&rows, skald.button(ctx, fmt.tprintf("%s  New Theme for %s", ICON_PALETTE, node.name), Msg(Theme_Created{forSelected = true}),
		id = skald.hash_id(fmt.tprintf("inspector-ui-new-theme-%d", key)), bg = th.color.surface, fg = th.color.fg,
		padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm))
	return rows[:]
}
