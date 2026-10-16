package editor

import "core:fmt"
import e "engine:."
import "gui:skald"

INSPECTOR_LABEL_WIDTH :: 82
INSPECTOR_MAX_NUMBER_WIDTH :: 160
// Room kept free on the right of inspector rows for the scrollbar
INSPECTOR_SCROLLBAR_WIDTH :: 14

/*
Right sidebar: the current scene's node tree above an inspector for the selected node.
The divider between them can be dragged.
*/
rightSidebarView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	return skald.split(ctx,
		first = sceneTreeView(s, ctx),
		second = inspectorView(s, ctx),
		first_size = s.layout.sceneTreeHeight,
		on_resize = proc(v: f32) -> Msg { return Scene_Tree_Resized(v) },
		id = skald.hash_id("split-scene-inspector"),
		direction = .Column,
		min_first = MIN_SCENE_TREE_HEIGHT,
		min_second = MIN_INSPECTOR_HEIGHT,
	)
}

@(private="file")
sceneTreeView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	scene := &s.project.scenes[s.currentScene]
	visible := SceneTreeRows(scene)
	rows := make([]skald.Tree_Row, len(visible), context.temp_allocator)
	for nodeIndex, i in visible {
		node := &scene.nodes[nodeIndex]
		rows[i] = {
			depth = Scene_NodeDepth(scene, nodeIndex),
			label = node.visible ? node.name : fmt.tprintf("%s (hidden)", node.name),
			expandable = Scene_HasChildren(scene, nodeIndex),
			expanded = node.expanded,
			selected = nodeIndex == s.selectedNode,
			icon = NodeKindIcon(node.kind),
		}
	}

	return skald.col(
		panelHeader(ctx, ICON_SITEMAP, scene.name,
			panelButton(ctx, "add-node", ICON_PLUS, "Add child node (Ctrl+Shift+A)", Action.Add_Node),
			panelButton(ctx, "delete-node", ICON_TRASH, "Delete node (Delete)", Action.Delete_Node, disabled = s.selectedNode < 0),
		),
		skald.divider(ctx),
		skald.flex(1, skald.scroll(ctx, {0, 0},
			skald.tree(ctx, rows,
				on_toggle = proc(row: int) -> Msg { return Node_Toggled(row) },
				on_select = proc(row: int) -> Msg { return Node_Selected(row) },
				id = skald.hash_id("scene-tree"),
				row_height = TREE_ROW_HEIGHT,
			),
			id = skald.hash_id("scene-tree-scroll"),
		)),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

@(private="file")
inspectorView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	scene := &s.project.scenes[s.currentScene]
	header := panelHeader(ctx, ICON_CIRCLE_INFO, "Inspector")

	if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) {
		return skald.col(
			header,
			skald.divider(ctx),
			skald.col(
				skald.text("Select a node in the scene tree or the viewport.", th.color.fg_muted, th.font.size_sm),
				padding = th.spacing.md,
			),
			cross_align = .Stretch,
			bg = th.color.bg,
		)
	}

	node := &scene.nodes[s.selectedNode]
	// Ids include the node index so a half-typed value doesn't carry over to another node
	key := s.selectedNode

	// Content inside a scroll view isn't width-limited, so size controls from the sidebar width
	_, sidebarWidth := FittedSidebarWidths(&s.layout)
	controlWidth := max(sidebarWidth - th.spacing.md * 2 - INSPECTOR_LABEL_WIDTH - th.spacing.sm - INSPECTOR_SCROLLBAR_WIDTH, 80)
	numberWidth := min(controlWidth, INSPECTOR_MAX_NUMBER_WIDTH)

	onField :: proc(field: NodeField, value: f64) -> Msg { return Node_Field_Changed{field, value} }
	number :: proc(ctx: ^skald.Ctx(Msg), key: int, field: NodeField, value: f32, step: f64, decimals: int, width: f32, minValue := min(f64), maxValue := max(f64)) -> skald.View {
		return skald.number_input(ctx, f64(value), field, onField,
			id = skald.hash_id(fmt.tprintf("inspector-%v-%d", field, key)),
			step = step, decimals = decimals, min_value = minValue, max_value = maxValue,
			width = width)
	}

	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows,
		inspectorRow(ctx, "Name", skald.text_input(ctx, node.name,
			proc(v: string) -> Msg { return Node_Renamed(v) },
			id = skald.hash_id(fmt.tprintf("inspector-name-%d", key)),
			width = controlWidth)),
		inspectorRow(ctx, "Type", skald.text(fmt.tprintf("%s  %v", NodeKindIcon(node.kind), node.kind), th.color.fg_muted, th.font.size_sm)),
		inspectorRow(ctx, "Position X", number(ctx, key, .Position_X, node.position.x, 1, 0, numberWidth)),
		inspectorRow(ctx, "Position Y", number(ctx, key, .Position_Y, node.position.y, 1, 0, numberWidth)),
		inspectorRow(ctx, "Rotation", number(ctx, key, .Rotation, node.rotation, 5, 1, numberWidth)),
		inspectorRow(ctx, "Scale X", number(ctx, key, .Scale_X, node.scale.x, 0.1, 2, numberWidth)),
		inspectorRow(ctx, "Scale Y", number(ctx, key, .Scale_Y, node.scale.y, 0.1, 2, numberWidth)),
		inspectorRow(ctx, "Layer", number(ctx, key, .Layer, f32(node.layer), 1, 0, numberWidth, 0, 7)),
		inspectorRow(ctx, "Visible", skald.checkbox(ctx, node.visible, "",
			proc(v: bool) -> Msg { return Node_Visibility_Changed(v) },
			id = skald.hash_id(fmt.tprintf("inspector-visible-%d", key)))),
	)

	// Properties of this node's kind
	onText :: proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} }
	onFlag :: proc(flag: NodeFlag, value: bool) -> Msg { return Node_Flag_Changed{flag, value} }
	textField :: proc(ctx: ^skald.Ctx(Msg), key: int, field: NodeTextField, value: string, width: f32) -> skald.View {
		return skald.text_input(ctx, value, field, onText,
			id = skald.hash_id(fmt.tprintf("inspector-%v-%d", field, key)), width = width)
	}
	flag :: proc(ctx: ^skald.Ctx(Msg), key: int, flag: NodeFlag, value: bool) -> skald.View {
		return skald.checkbox(ctx, value, "", flag, onFlag, id = skald.hash_id(fmt.tprintf("inspector-%v-%d", flag, key)))
	}
	textureSelect :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, value: string, width: f32) -> skald.View {
		images := make([dynamic]string, context.temp_allocator)
		for asset in s.project.assets do if asset.kind == .Image do append(&images, asset.path)
		return skald.select(ctx, value, images[:], NodeTextField.Texture, onText,
			id = skald.hash_id(fmt.tprintf("inspector-texture-%d", key)), width = width, placeholder = "Choose an image")
	}

	if node.kind != .Node2D {
		append(&rows, skald.divider(ctx), skald.text(fmt.tprintf("%v", node.kind), th.color.fg, th.font.size_sm))
	}
	switch node.kind {
	case .Node2D:
	case .Sprite:
		append(&rows, inspectorRow(ctx, "Texture", textureSelect(ctx, s, key, node.texture, controlWidth)))
	case .AnimatedSprite:
		modes := make([]string, len(e.AnimationPlayMode), context.temp_allocator)
		for mode in e.AnimationPlayMode do modes[mode] = fmt.tprintf("%v", mode)
		append(&rows,
			inspectorRow(ctx, "Sheet", textureSelect(ctx, s, key, node.texture, controlWidth)),
			inspectorRow(ctx, "Columns", number(ctx, key, .Columns, f32(node.columns), 1, 0, numberWidth, 1, 64)),
			inspectorRow(ctx, "Rows", number(ctx, key, .Rows, f32(node.rows), 1, 0, numberWidth, 1, 64)),
			inspectorRow(ctx, "FPS", number(ctx, key, .FPS, node.fps, 1, 0, numberWidth, 0, 120)),
			inspectorRow(ctx, "Loop", flag(ctx, key, .Loop, node.loop)),
			inspectorRow(ctx, "Play mode", skald.select(ctx, fmt.tprintf("%v", node.playMode), modes, NodeTextField.Play_Mode, onText,
				id = skald.hash_id(fmt.tprintf("inspector-mode-%d", key)), width = controlWidth)),
		)
	case .Label:
		append(&rows,
			inspectorRow(ctx, "Text", textField(ctx, key, .Text, node.text, controlWidth)),
			inspectorRow(ctx, "Font size", number(ctx, key, .Font_Size, node.fontSize, 2, 0, numberWidth, 1, 400)),
			inspectorRow(ctx, "Color", textField(ctx, key, .Color, e.FormatColor(node.color, context.temp_allocator), controlWidth)),
			inspectorRow(ctx, "Centered", flag(ctx, key, .Centered, node.centered)),
		)
	case .Camera:
		append(&rows, inspectorRow(ctx, "Zoom", number(ctx, key, .Zoom, node.zoom, 0.1, 2, numberWidth, 0.05, 20)))
	case .Menu:
		// Editing buttons comes later; show what the menu does
		for item in node.items {
			append(&rows, inspectorRow(ctx, item.label, skald.text(item.action, th.color.fg_muted, th.font.size_sm)))
		}
		if len(node.items) == 0 {
			append(&rows, skald.text("No buttons", th.color.fg_muted, th.font.size_sm))
		}
	}

	fields := skald.col(..rows[:],
		spacing = th.spacing.sm,
		padding = th.spacing.md,
		cross_align = .Stretch,
	)

	return skald.col(
		header,
		skald.divider(ctx),
		skald.flex(1, skald.scroll(ctx, {0, 0}, fields, id = skald.hash_id("inspector-scroll"))),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

// A label column and its control
@(private="file")
inspectorRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	th := ctx.theme
	return skald.row(
		skald.col(skald.text(label, th.color.fg_muted, th.font.size_sm), width = INSPECTOR_LABEL_WIDTH),
		control,
		spacing = th.spacing.sm,
		cross_align = .Center,
	)
}
