package editor

import "core:fmt"
import "core:math"
import e "engine:."
import "gui:skald"
import sdl "vendor:sdl3"

INSPECTOR_LABEL_WIDTH :: 82
// The texture dropdown's first choice: no image
TEXTURE_NONE :: "(None)"
// Widest a number field gets (its − and + buttons included), and a text box, dropdown or color
INSPECTOR_MAX_NUMBER_WIDTH :: 120
INSPECTOR_MAX_TEXT_WIDTH :: 200
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
	rows := make([]ColoredTreeRow, len(visible), context.temp_allocator)
	for nodeIndex, i in visible {
		node := &scene.nodes[nodeIndex]
		// Each node kind in its own color, the same as its marker in the viewport; hidden nodes dimmed
		color := kindColor(node.kind)
		label := TintLabel(th, color)
		if !node.visible do label = th.color.fg_muted
		rows[i] = {
			depth = Scene_NodeDepth(scene, nodeIndex),
			label = node.visible ? node.name : fmt.tprintf("%s (hidden)", node.name),
			expandable = Scene_HasChildren(scene, nodeIndex),
			expanded = node.expanded,
			selected = Selection_Contains(s, nodeIndex),
			icon = NodeKindIcon(node.kind),
			iconColor = color,
			labelColor = label,
		}
	}

	if s.refocus == .Scene_Tree {
		skald.widget_focus(ctx, skald.hash_id("scene-tree"))
		skald.send(ctx, Msg(Refocus_Done{}))
	}
	// Before the tree and menu are built: they act on this frame's presses too
	indicator := sceneTreeMouse(s, ctx, visible)
	renameField := sceneTreeRename(s, ctx, visible)

	// The tree is built before the menu that wraps it, so it would see a click on a menu item
	// (over the tree) before the menu consumes it, and select the row underneath
	menuState, _ := ctx.widgets.states[skald.hash_id("scene-tree-menu")]
	shield := menuState.open && skald.mouse_over_overlay(ctx) && ctx.input.mouse_pressed[.Left]
	if shield do ctx.input.mouse_pressed[.Left] = false
	tree := skald.scroll(ctx, {0, 0},
		coloredTree(ctx, rows,
			on_toggle = proc(row: int) -> Msg { return Node_Toggled(row) },
			on_select = proc(row: int) -> Msg { return Node_Selected(row) },
			id = skald.hash_id("scene-tree"),
			row_height = s.settings.rowHeight,
		),
		id = skald.hash_id("scene-tree-scroll"),
	)
	if shield do ctx.input.mouse_pressed[.Left] = true
	labels := make([]string, len(SCENE_TREE_MENU), context.temp_allocator)
	for action, i in SCENE_TREE_MENU {
		label := action == .Add_Node ? "Add Node..." : ACTION_LABELS[action]
		shortcut := skald.shortcut_format(Keymap_Shortcut(&s.settings.keymap, action))
		labels[i] = shortcut == "" ? label : fmt.tprintf("%s   (%s)", label, shortcut)
	}
	menu := skald.context_menu(ctx, tree, labels,
		proc(i: int) -> Msg { return Msg(SCENE_TREE_MENU[i]) },
		id = skald.hash_id("scene-tree-menu"),
		width = 250,
	)

	return skald.col(
		panelHeader(ctx, ICON_SITEMAP, scene.name,
			panelButton(ctx, "add-node", ICON_PLUS, actionTip(s, "Add node", .Add_Node), Action.Add_Node),
			panelButton(ctx, "delete-node", ICON_TRASH, actionTip(s, "Delete node", .Delete_Node), Action.Delete_Node, disabled = s.selectedNode < 0),
		),
		skald.divider(ctx),
		skald.flex(1, menu),
		indicator,
		renameField,
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

// The scene tree's right-click menu, in order
SCENE_TREE_MENU := [?]Action{.Add_Node, .Rename_Node, .Duplicate_Node, .Copy_Node, .Cut_Node, .Paste_Node, .Delete_Node}

// How far the mouse moves with the button down before a press on a row becomes a drag
TREE_DRAG_THRESHOLD :: 5

/*
Scene tree mouse handling the tree widget doesn't do itself:
- right-click selects the row under the cursor (or deselects below the rows), so the context
  menu acts on it
- dragging a row moves the node: onto the top or bottom quarter of a row puts it before or after
  that node, onto the middle makes it a child, below the rows makes it the last top-level node

Returns the drop indicator to draw while dragging (an overlay; empty otherwise).
*/
@(private="file")
sceneTreeMouse :: proc(s: ^State, ctx: ^skald.Ctx(Msg), visible: []int) -> skald.View {
	th := ctx.theme
	none := skald.View(skald.View_Spacer{size = 0})
	treeState, drawn := ctx.widgets.states[skald.hash_id("scene-tree")]
	areaState, _ := ctx.widgets.states[skald.hash_id("scene-tree-scroll")]
	if !drawn || areaState.last_rect.w <= 0 do return none
	area := areaState.last_rect
	tree := treeState.last_rect
	mouse := ctx.input.mouse_pos
	overArea := pointIn(area, mouse) && !skald.mouse_over_overlay(ctx) && ctx.widgets.modal_rect_prev.w == 0
	rowHeight := s.settings.rowHeight
	row := int(math.floor((mouse.y - tree.y) / rowHeight))
	onRow := row >= 0 && row < len(visible)

	if ctx.input.mouse_pressed[.Right] && overArea {
		skald.send(ctx, Msg(Node_Right_Clicked(onRow ? row : -1)))
	}
	// Ctrl+click toggles a row in the selection, Shift+click selects a range. The tree would
	// select just the clicked row, so it doesn't see this press
	mods := ctx.input.modifiers
	if ctx.input.mouse_pressed[.Left] && overArea && onRow && (.Ctrl in mods || .Shift in mods) {
		skald.send(ctx, Msg(Tree_Selection_Clicked{row = row, range = .Shift in mods}))
		ctx.input.mouse_pressed[.Left] = false
		return none
	}
	if ctx.input.mouse_pressed[.Left] && overArea && onRow {
		// Double-click renames. The tree itself would expand or collapse the row on a double
		// click, so it doesn't see the click count
		if ctx.input.mouse_click_count[.Left] >= 2 {
			skald.send(ctx, Msg(Rename_Started(visible[row])))
			ctx.input.mouse_click_count[.Left] = 1
		}
		skald.send(ctx, Msg(Tree_Drag_Pressed{node = visible[row], start = mouse}))
		return none
	}
	if !s.treeDrag.pressed do return none

	scene := &s.project.scenes[s.currentScene]
	target, position, valid := sceneTreeDropTarget(scene, visible, s.treeDrag.node, tree, mouse, rowHeight)
	valid = valid && overArea
	if !ctx.input.mouse_buttons[.Left] {
		if s.treeDrag.active && valid {
			skald.send(ctx, Msg(Tree_Drag_Dropped{target = target, position = position}))
		} else {
			skald.send(ctx, Msg(Tree_Drag_Cancelled{}))
		}
		return none
	}
	if !s.treeDrag.active {
		d := mouse - s.treeDrag.start
		if d.x * d.x + d.y * d.y >= TREE_DRAG_THRESHOLD * TREE_DRAG_THRESHOLD {
			skald.send(ctx, Msg(Tree_Drag_Started{}))
		}
		return none
	}
	// Near the top or bottom edge, scroll so rows out of view can be reached. Frames keep coming
	// while the mouse is held there
	edge := rowHeight
	scroll := &ctx.widgets.states[skald.hash_id("scene-tree-scroll")]
	if mouse.y < area.y + edge && scroll.scroll_y > 0 {
		scroll.scroll_y = max(scroll.scroll_y - rowHeight * 0.3, 0)
		skald.send(ctx, Msg(Frame_Requested{}))
	} else if mouse.y > area.y + area.h - edge && tree.y + tree.h > area.y + area.h {
		scroll.scroll_y += rowHeight * 0.3
		skald.send(ctx, Msg(Frame_Requested{}))
	}
	if !valid do return none

	// Where it would land: a line between rows, or a box around the new parent
	Indicator :: struct { color: skald.Color, box: bool }
	marker := new_clone(Indicator{th.color.primary, false}, context.temp_allocator)
	rect: skald.Rect
	switch {
	case target < 0:
		rect = {tree.x, tree.y + f32(len(visible)) * rowHeight - 1, tree.w, 2}
	case position == .Inside:
		at := rowOf(visible, target)
		rect = {tree.x, tree.y + f32(at) * rowHeight, tree.w, rowHeight}
		marker.box = true
	case:
		at := rowOf(visible, target)
		if position == .After do at += 1 + visibleDescendants(scene, visible, at)
		indent := th.spacing.sm + f32(Scene_NodeDepth(scene, target)) * th.spacing.lg
		rect = {tree.x + indent, tree.y + f32(at) * rowHeight - 1, tree.w - indent, 2}
	}
	// The tree may be scrolled: don't draw outside its visible area
	if rect.y + rect.h < area.y || rect.y > area.y + area.h do return none

	return skald.overlay({rect.x, rect.y, rect.w, 0},
		skald.canvas(ctx, marker, proc(m: ^Indicator, p: skald.Canvas_Painter) {
			if m.box {
				fill := m.color
				fill[3] *= 0.25
				skald.draw_rect(p.r, p.bounds, fill, 3)
				b := p.bounds
				for edge in ([4]skald.Rect{{b.x, b.y, b.w, 1}, {b.x, b.y + b.h - 1, b.w, 1}, {b.x, b.y, 1, b.h}, {b.x + b.w - 1, b.y, 1, b.h}}) {
					skald.draw_rect(p.r, edge, m.color)
				}
			} else {
				skald.draw_rect(p.r, p.bounds, m.color, 1)
			}
		}, width = rect.w, height = rect.h),
		no_shadow = true, pin = true)
}

/*
Where a dragged node would go if released at `mouse`.

Returns:
- target: The node dropped on, or -1 for the end of the top level
- position: Before, After or Inside the target
- valid: Whether the node can go there (not into its own subtree)
*/
@(private="file")
sceneTreeDropTarget :: proc(scene: ^SceneDef, visible: []int, dragged: int, tree: skald.Rect, mouse: [2]f32, rowHeight: f32) -> (target: int, position: DropPosition, valid: bool) {
	rel := (mouse.y - tree.y) / rowHeight
	if rel >= f32(len(visible)) {
		return -1, .Inside, Scene_CanMoveNode(scene, dragged, -1, .Inside)
	}
	row := max(int(math.floor(rel)), 0)
	fraction := rel - f32(row)
	target = visible[row]
	position = fraction < 0.25 ? .Before : fraction > 0.75 ? .After : .Inside
	// The bottom edge of an open parent is the top of its first child
	if position == .After && row + 1 < len(visible) && scene.nodes[visible[row + 1]].parent == target {
		target, position = visible[row + 1], .Before
	}
	return target, position, Scene_CanMoveNode(scene, dragged, target, position)
}

@(private="file")
rowOf :: proc(visible: []int, node: int) -> int {
	for n, i in visible do if n == node do return i
	return 0
}

// Rows after `row` that belong to its node's subtree
@(private="file")
visibleDescendants :: proc(scene: ^SceneDef, visible: []int, row: int) -> int {
	depth := Scene_NodeDepth(scene, visible[row])
	count := 0
	for i := row + 1; i < len(visible) && Scene_NodeDepth(scene, visible[i]) > depth; i += 1 do count += 1
	return count
}

@(private="file")
pointIn :: proc(r: skald.Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

@(private="file")
inspectorView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	scene := &s.project.scenes[s.currentScene]
	header := panelHeader(ctx, ICON_CIRCLE_INFO, "Inspector")

	if s.dataSelection >= 0 && s.dataSelection < len(s.project.data) {
		return skald.col(
			header,
			skald.divider(ctx),
			skald.flex(1, skald.scroll(ctx, {0, 0}, dataInspector(s, ctx), id = skald.hash_id("inspector-scroll"))),
			cross_align = .Stretch,
			bg = th.color.bg,
		)
	}
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
	// Several selected: the inspector edits the primary one
	multiNote: skald.View = skald.View_Spacer{size = 0}
	if len(s.selection) > 1 {
		multiNote = skald.text(fmt.tprintf("%d nodes selected. Editing %s; moving, nudging, copying and deleting act on all.", len(s.selection), node.name),
			th.color.fg_muted, th.font.size_xs, max_width = 260)
	}

	// Content inside a scroll view isn't width-limited, so size controls from the sidebar width
	_, sidebarWidth := FittedSidebarWidths(&s.layout)
	controlWidth := max(sidebarWidth - th.spacing.md * 2 - INSPECTOR_LABEL_WIDTH - th.spacing.sm - INSPECTOR_SCROLLBAR_WIDTH, 80)
	// Room for the link button next to X/Y fields, so it never ends up under the scrollbar
	numberWidth := min(controlWidth - LINK_BUTTON_WIDTH - th.spacing.xs, INSPECTOR_MAX_NUMBER_WIDTH)
	controlWidth = min(controlWidth, INSPECTOR_MAX_TEXT_WIDTH)

	number :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: NodeField, value: f32, step: f64, decimals: int, width: f32, minValue := min(f64), maxValue := max(f64)) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("inspector-%v-%d", field, key), field, f64(value), step, decimals, width, minValue, maxValue)
	}

	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows,
		multiNote,
		inspectorRow(ctx, "Name", skald.text_input(ctx, node.name,
			proc(v: string) -> Msg { return Node_Renamed(v) },
			id = skald.hash_id(fmt.tprintf("inspector-name-%d", key)),
			width = controlWidth, padding = InspectorFieldPadding(ctx))),
		inspectorRow(ctx, "Type", skald.text(fmt.tprintf("%s  %v", NodeKindIcon(node.kind), node.kind), th.color.fg_muted, th.font.size_sm)),
		// X/Y pairs: the chain button links them, so changing one changes the other in proportion
		inspectorRow(ctx, "Position X", linked(ctx, s, .Position, number(ctx, s, key, .Position_X, node.position.x, 1, 0, numberWidth))),
		inspectorRow(ctx, "Position Y", linkSpace(ctx, number(ctx, s, key, .Position_Y, node.position.y, 1, 0, numberWidth))),
		inspectorRow(ctx, "Rotation", number(ctx, s, key, .Rotation, node.rotation, 5, 1, numberWidth)),
		inspectorRow(ctx, "Scale X", linked(ctx, s, .Scale, number(ctx, s, key, .Scale_X, node.scale.x, 0.1, 2, numberWidth))),
		inspectorRow(ctx, "Scale Y", linkSpace(ctx, number(ctx, s, key, .Scale_Y, node.scale.y, 0.1, 2, numberWidth))),
		inspectorRow(ctx, "Layer", number(ctx, s, key, .Layer, f32(node.layer), 1, 0, numberWidth, 0, 7)),
		inspectorRow(ctx, "Visible", skald.checkbox(ctx, node.visible, "",
			proc(v: bool) -> Msg { return Node_Visibility_Changed(v) },
			id = skald.hash_id(fmt.tprintf("inspector-visible-%d", key)))),
	)

	// Properties of this node's kind
	onText :: proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} }
	onFlag :: proc(flag: NodeFlag, value: bool) -> Msg { return Node_Flag_Changed{flag, value} }
	textField :: proc(ctx: ^skald.Ctx(Msg), key: int, field: NodeTextField, value: string, width: f32) -> skald.View {
		return skald.text_input(ctx, value, field, onText,
			id = skald.hash_id(fmt.tprintf("inspector-%v-%d", field, key)), width = width, padding = InspectorFieldPadding(ctx))
	}
	flag :: proc(ctx: ^skald.Ctx(Msg), key: int, flag: NodeFlag, value: bool) -> skald.View {
		return skald.checkbox(ctx, value, "", flag, onFlag, id = skald.hash_id(fmt.tprintf("inspector-%v-%d", flag, key)))
	}
	textureSelect :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, value: string, width: f32) -> skald.View {
		// The project's images, and "None" to clear it
		images := make([dynamic]string, context.temp_allocator)
		append(&images, TEXTURE_NONE)
		for asset in s.project.assets do if asset.kind == .Image do append(&images, asset.path)
		return skald.select(ctx, value == "" ? TEXTURE_NONE : value, images[:], NodeTextField.Texture, onText,
			id = skald.hash_id(fmt.tprintf("inspector-texture-%d", key)), width = width, placeholder = "Choose an image")
	}
	colorPicker :: proc(ctx: ^skald.Ctx(Msg), key: int, value: sdl.Color, width: f32) -> skald.View {
		// The node stores sRGB bytes; Skald's picker works in linear color. The message carries hex
		linear := skald.rgb(u32(value.r) << 16 | u32(value.g) << 8 | u32(value.b))
		return skald.color_picker(ctx, linear,
			proc(c: skald.Color) -> Msg { return Node_Text_Changed{.Color, fmt.tprintf("#%s", skald.color_to_hex(c))} },
			id = skald.hash_id(fmt.tprintf("inspector-color-%d", key)), width = width)
	}

	append(&rows, skald.divider(ctx))
	append(&rows, ..scriptSection(ctx, s, node, key, controlWidth, numberWidth))

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
			inspectorRow(ctx, "Columns", number(ctx, s, key, .Columns, f32(node.columns), 1, 0, numberWidth, 1, 64)),
			inspectorRow(ctx, "Rows", number(ctx, s, key, .Rows, f32(node.rows), 1, 0, numberWidth, 1, 64)),
			inspectorRow(ctx, "FPS", number(ctx, s, key, .FPS, node.fps, 1, 0, numberWidth, 0, 120)),
			inspectorRow(ctx, "Loop", flag(ctx, key, .Loop, node.loop)),
			inspectorRow(ctx, "Play mode", skald.select(ctx, fmt.tprintf("%v", node.playMode), modes, NodeTextField.Play_Mode, onText,
				id = skald.hash_id(fmt.tprintf("inspector-mode-%d", key)), width = controlWidth)),
		)
	case .Label:
		append(&rows,
			inspectorRow(ctx, "Text", textField(ctx, key, .Text, node.text, controlWidth)),
			inspectorRow(ctx, "Font size", number(ctx, s, key, .Font_Size, node.fontSize, 2, 0, numberWidth, 1, 400)),
			inspectorRow(ctx, "Color", colorPicker(ctx, key, node.color, controlWidth)),
			inspectorRow(ctx, "Centered", flag(ctx, key, .Centered, node.centered)),
		)
	case .Camera:
		append(&rows, inspectorRow(ctx, "Zoom", number(ctx, s, key, .Zoom, node.zoom, 0.1, 2, numberWidth, 0.05, 20)))
	case .StaticBody, .DynamicBody, .CharacterMover, .Area, .CollisionShape, .RayCast, .Joint:
		append(&rows, ..physicsInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
	case .ParticleEmitter:
		append(&rows, ..particleInspectorRows(ctx, s, node, key, controlWidth))
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
@(private="package")
inspectorRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	th := ctx.theme
	return skald.row(
		skald.col(skald.text(label, th.color.fg_muted, th.font.size_sm), width = INSPECTOR_LABEL_WIDTH),
		control,
		spacing = th.spacing.sm,
		cross_align = .Center,
	)
}

/*
The text field for renaming a node in place: an overlay over its row. Enter or clicking elsewhere
keeps the new name, Escape cancels.
*/
@(private="file")
sceneTreeRename :: proc(s: ^State, ctx: ^skald.Ctx(Msg), visible: []int) -> skald.View {
	th := ctx.theme
	none := skald.View(skald.View_Spacer{size = 0})
	// Scenes are renamed in the browser
	if !s.rename.active || s.rename.target != .Node do return none
	scene := &s.project.scenes[s.currentScene]
	row := -1
	for node, i in visible do if node == s.rename.node do row = i
	treeState, drawn := ctx.widgets.states[skald.hash_id("scene-tree")]
	if row < 0 || !drawn || s.rename.node >= len(scene.nodes) {
		skald.send(ctx, Msg(Rename_Cancelled{}))
		return none
	}

	id := skald.hash_id("scene-tree-rename")
	// Before the field is built, so it doesn't see these keys
	skald.shortcut(ctx, {.Enter, {}}, Msg(Rename_Committed{byKey = true}))
	skald.shortcut(ctx, {.Escape, {}}, Msg(Rename_Cancelled{}))
	if !s.rename.focused {
		skald.widget_focus(ctx, id)
		skald.send(ctx, Msg(Rename_Focused{}))
	} else if !skald.widget_has_focus(ctx, id) {
		skald.send(ctx, Msg(Rename_Committed{}))
	}

	// Over the label: after the row's indent, chevron and icon (Skald's tree layout)
	tree := treeState.last_rect
	rowHeight := s.settings.rowHeight
	x := tree.x + th.spacing.sm + f32(Scene_NodeDepth(scene, s.rename.node)) * th.spacing.lg + 16 + th.font.size_md + th.spacing.xs
	area := treeState.clip_rect.w > 0 ? treeState.clip_rect : tree
	y := tree.y + f32(row) * rowHeight
	if y < area.y || y + rowHeight > area.y + area.h do return none
	width := max(tree.x + tree.w - x - th.spacing.xs, 60)
	return skald.overlay({x, y, 0, 0},
		skald.text_input(ctx, s.rename.text,
			proc(v: string) -> Msg { return Rename_Text_Changed(v) },
			id = id, width = width, height = rowHeight, font_size = th.font.size_sm),
		no_shadow = true, pin = true)
}

// Inspector text boxes are a little tighter than Skald's default (spacing.md x spacing.sm)
InspectorFieldPadding :: proc(ctx: ^skald.Ctx(Msg)) -> [2]f32 {
	return {ctx.theme.spacing.sm, 2}
}

// A field followed by its pair's link toggle
@(private="file")
linked :: proc(ctx: ^skald.Ctx(Msg), s: ^State, pair: LinkedPair, field: skald.View) -> skald.View {
	th := ctx.theme
	on := s.inspectorLinks[pair]
	button := skald.button(ctx, on ? ICON_LINK : ICON_LINK_SLASH, Msg(Inspector_Link_Toggled(pair)),
		id = skald.hash_id(fmt.tprintf("inspector-link-%v", pair)),
		bg = on ? th.color.primary : th.color.surface, fg = on ? th.color.on_primary : th.color.fg_muted,
		width = LINK_BUTTON_WIDTH, padding = {0, 1}, font_size = th.font.size_xs, radius = th.radius.sm)
	tip := on ? "Unlink: change X and Y separately" : "Link X and Y: changing one changes the other in proportion"
	return skald.row(field, skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("inspector-link-tip-%v", pair))),
		spacing = th.spacing.xs, cross_align = .Center)
}

// The second field of a pair, lined up with the first (which has the link button)
@(private="file")
linkSpace :: proc(ctx: ^skald.Ctx(Msg), field: skald.View) -> skald.View {
	return skald.row(field, skald.spacer(LINK_BUTTON_WIDTH), spacing = ctx.theme.spacing.xs)
}

@(private="file")
LINK_BUTTON_WIDTH :: 20

/*
The inspector's Script section: which script the node has (or none), buttons to make a new one
and open it, and its exported fields from the last build (scripts.odin).
*/
@(private="file")
scriptSection :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)

	status := ""
	switch s.scripts.status {
	case .Unknown:  status = len(s.scriptFiles) > 0 ? "not built yet (Ctrl+B)" : ""
	case .Building: status = "building..."
	case .Failed:   status = "build failed: see Output"
	case .Ready:
	}
	append(&rows, skald.row(
		skald.text(fmt.tprintf("%s  Script", ICON_CODE), th.color.fg, th.font.size_sm),
		skald.flex(1, skald.spacer(0)),
		skald.text(status, s.scripts.status == .Failed ? th.color.danger : th.color.fg_muted, th.font.size_xs),
		cross_align = .Center,
	))

	// The choices: none, every built script, and the node's own if the catalog doesn't know it
	names := make([dynamic]string, context.temp_allocator)
	append(&names, TEXTURE_NONE)
	for desc in s.scripts.scripts do append(&names, desc.name)
	if node.script != "" && ScriptCatalog_Find(&s.scripts, node.script) == nil do append(&names, node.script)
	append(&rows, inspectorRowView(ctx, "Script", skald.select(ctx, node.script == "" ? TEXTURE_NONE : node.script, names[:],
		proc(v: string) -> Msg { return Node_Script_Changed(v) },
		id = skald.hash_id(fmt.tprintf("inspector-script-%d", key)), width = controlWidth)))
	// The buttons get their own row, under the dropdown: next to it they ran into the scrollbar
	// strip in a narrow inspector, which covered them (clicks did nothing)
	textButton :: proc(ctx: ^skald.Ctx(Msg), key, icon, label, tip: string, msg: Msg) -> skald.View {
		th := ctx.theme
		button := skald.button(ctx, fmt.tprintf("%s  %s", icon, label), msg, id = skald.hash_id(key),
			bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
		return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("%s-tip", key)))
	}
	buttons := make([dynamic]skald.View, context.temp_allocator)
	append(&buttons, textButton(ctx, "inspector-new-script", ICON_PLUS, "New...", "Write a new script and attach it to this node", Msg(New_Script_Opened{})))
	if node.script != "" {
		append(&buttons, textButton(ctx, "inspector-open-script", ICON_FILE_CODE, "Open in Editor", actionTip(s, "Open the script in your code editor", .Open_Script), Msg(Action.Open_Script)))
	}
	append(&rows, inspectorRowView(ctx, "", skald.row(..buttons[:], spacing = th.spacing.xs, cross_align = .Center)))
	if node.script == "" do return rows[:]

	desc := ScriptCatalog_Find(&s.scripts, node.script)
	if desc == nil {
		message := s.scripts.status == .Building ? "Building..." : fmt.tprintf("Build the scripts (Ctrl+B) to edit %s's fields.", node.script)
		append(&rows, skald.text(message, th.color.fg_muted, th.font.size_xs, max_width = 260))
		for prop in node.props do append(&rows, inspectorRowView(ctx, prop.name, skald.text(prop.value, th.color.fg_muted, th.font.size_sm)))
		return rows[:]
	}
	if len(desc.fields) == 0 {
		append(&rows, skald.text("No exported fields (tag a field with export:\"\" to edit it here).", th.color.fg_muted, th.font.size_xs, max_width = 260))
	}
	for &field in desc.fields {
		append(&rows, inspectorRowView(ctx, field.name, FieldControl(ctx, s, node.props[:], &field, fmt.tprintf("%d", key), SelectedNodeTarget{}, controlWidth, numberWidth)))
	}
	return rows[:]
}

// inspectorRow, for code outside the main inspector proc
@(private="file")
inspectorRowView :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	return inspectorRow(ctx, label, control)
}
