package crossfire_editor

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."
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
	skald.prof_scope("rightSidebarView")
	// A narrow inspector stacks its rows' labels over their controls, while it's built
	_, right := FittedSidebarWidths(&s.layout)
	_, inspectorStacked = Inspector_Layout(ctx.theme, right)
	defer inspectorStacked = false
	return skald.split(ctx,
		first = sceneTreeView(s, ctx),
		second = inspectorView(s, ctx),
		first_size = FittedSceneTreeHeight(&s.layout),
		on_resize = proc(v: f32) -> Msg { return Scene_Tree_Resized(v) },
		id = skald.hash_id("split-scene-inspector"),
		direction = .Column,
		min_first = MIN_SCENE_TREE_HEIGHT,
		min_second = MIN_INSPECTOR_HEIGHT,
	)
}

/*
A node's scene tree row: its kind's icon and color (the same as its viewport marker), dimmed when
hidden, and a script icon after the name when it has a script.
*/
SceneTree_Row :: proc(th: ^skald.Theme, scene: ^SceneDef, nodeIndex: int, selected: bool) -> ColoredTreeRow {
	node := &scene.nodes[nodeIndex]
	color := kindColor(node.kind)
	label := TintLabel(th, color)
	if !node.visible do label = th.color.fg_muted
	return {
		depth = Scene_NodeDepth(scene, nodeIndex),
		label = node.visible ? node.name : fmt.tprintf("%s (hidden)", node.name),
		expandable = Scene_HasChildren(scene, nodeIndex),
		expanded = node.expanded,
		selected = selected,
		icon = NodeKindIcon(node.kind),
		iconColor = color,
		labelColor = label,
		badge = node.script != "" ? ICON_FILE_CODE : "",
		badgeColor = SCRIPT_COLOR,
	}
}

@(private="file")
sceneTreeView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	skald.prof_scope("sceneTreeView")
	th := ctx.theme
	scene := &s.project.scenes[s.currentScene]
	visible := SceneTreeRows(scene)
	rows := make([]ColoredTreeRow, len(visible), context.temp_allocator)
	for nodeIndex, i in visible do rows[i] = SceneTree_Row(th, scene, nodeIndex, Selection_Contains(s, nodeIndex))

	if s.refocus == .Scene_Tree {
		skald.widget_focus(ctx, skald.hash_id("scene-tree"))
		skald.send(ctx, Msg(Refocus_Done{}))
	}
	// Before the tree and menu are built: they act on this frame's presses too
	indicator := sceneTreeMouse(s, ctx, visible)
	renameField := sceneTreeRename(s, ctx, visible)

	Tree_RevealSelected(ctx, rows, "scene-tree", "scene-tree-scroll", s.settings.rowHeight)
	tree := skald.scroll(ctx, {0, 0},
		coloredTree(ctx, rows,
			on_toggle = proc(row: int) -> Msg { return Node_Toggled(row) },
			on_select = proc(row: int) -> Msg { return Node_Selected(row) },
			id = skald.hash_id("scene-tree"),
			row_height = s.settings.rowHeight,
		),
		id = skald.hash_id("scene-tree-scroll"),
		reveal_focus = false,
	)
	// Its right-click menu is the editor's (context_menus.odin), opened by sceneTreeMouse
	menu := tree

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

	// A right-click opens the node's menu (selecting it), or below the rows the tree's
	if ctx.input.mouse_pressed[.Right] && overArea {
		if onRow {
			skald.send(ctx, Msg(Context_Menu_Opened{at = mouse, target = Ctx_Node{node = visible[row]}}))
		} else {
			skald.send(ctx, Msg(Node_Right_Clicked(-1)))
			skald.send(ctx, Msg(Context_Menu_Opened{at = mouse, target = Ctx_Tree{}}))
		}
		ctx.input.mouse_pressed[.Right] = false
	}
	// Ctrl+click (Cmd+click on a Mac) toggles a row in the selection, Shift+click selects a range. The tree would
	// select just the clicked row, so it doesn't see this press
	mods := ctx.input.modifiers
	if ctx.input.mouse_pressed[.Left] && overArea && onRow && (skald.PRIMARY_MODIFIER in mods || .Shift in mods) {
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
	// Over the code tab: a field for the node in its script
	codeArea := ctx.widgets.states[skald.hash_id("code-editor")].last_rect
	overCode := s.codeTab > 0 && s.treeDrag.active && pointIn(codeArea, mouse)
	if !ctx.input.mouse_buttons[.Left] {
		if s.treeDrag.active && valid {
			skald.send(ctx, Msg(Tree_Drag_Dropped{target = target, position = position}))
		} else if overCode {
			skald.send(ctx, Msg(Tree_Drag_Dropped_On_Code{mouse, .Shift in ctx.input.modifiers}))
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
	if overCode {
		// What the drop will do, by the pointer
		label := fmt.tprintf("%s  %s into the code (Shift: choices)", ICON_FILE_CODE, scene.nodes[s.treeDrag.node].name)
		return skald.overlay({mouse.x + 14, mouse.y + 10, 0, 0},
			skald.col(skald.text(label, th.color.on_primary, th.font.size_sm), padding = th.spacing.xs, bg = th.color.primary, radius = th.radius.sm),
			no_shadow = true, pin = true)
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

@(private)
pointIn :: proc(r: skald.Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

@(private="file")
inspectorView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	skald.prof_scope("inspectorView")
	th := ctx.theme
	scene := &s.project.scenes[s.currentScene]
	header := panelHeader(ctx, ICON_CIRCLE_INFO, "Inspector")
	Scroll_RevealClicked(ctx, "inspector-scroll")
	inspectorRevealStep(ctx)

	if s.themeSelection >= 0 && s.themeSelection < len(s.project.themes) {
		return skald.col(
			header,
			skald.divider(ctx),
			skald.flex(1, skald.scroll(ctx, {0, 0}, themeInspector(s, ctx), id = skald.hash_id("inspector-scroll"))),
			cross_align = .Stretch,
			bg = th.color.bg,
		)
	}
	if s.busSelection >= 0 && s.busSelection < len(s.project.buses) {
		return skald.col(
			header,
			skald.divider(ctx),
			skald.flex(1, skald.scroll(ctx, {0, 0}, busEffectsInspector(s, ctx), id = skald.hash_id("inspector-scroll"))),
			cross_align = .Stretch,
			bg = th.color.bg,
		)
	}
	if s.atlasSelection >= 0 && s.atlasSelection < len(s.project.atlases) {
		return skald.col(
			header,
			skald.divider(ctx),
			skald.flex(1, skald.scroll(ctx, {0, 0}, atlasInspector(s, ctx), id = skald.hash_id("inspector-scroll"))),
			cross_align = .Stretch,
			bg = th.color.bg,
		)
	}
	if s.materialSelection >= 0 && s.materialSelection < len(s.project.materials) {
		return skald.col(
			header,
			skald.divider(ctx),
			skald.flex(1, skald.scroll(ctx, {0, 0}, materialInspector(s, ctx), id = skald.hash_id("inspector-scroll"))),
			cross_align = .Stretch,
			bg = th.color.bg,
		)
	}
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
	// The rows' labels drag into code (inspectorRow)
	inspectorDrag = {state = s, node = s.selectedNode, kind = NodeDef_BuiltKind(&s.project, node)}
	defer inspectorDrag = {}
	// Several selected: the inspector edits the primary one
	multiNote: skald.View = skald.View_Spacer{size = 0}
	if len(s.selection) > 1 {
		multiNote = skald.text(fmt.tprintf("%d nodes selected. Editing %s; moving, nudging, copying and deleting act on all.", len(s.selection), node.name),
			th.color.fg_muted, th.font.size_xs, max_width = 260)
	}

	// Content inside a scroll view isn't width-limited, so size controls from the sidebar width
	_, sidebarWidth := FittedSidebarWidths(&s.layout)
	controlWidth := inspectorControlWidth(th, sidebarWidth)
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
		inspectorRow(ctx, "Z index", number(ctx, s, key, .Z_Index, f32(node.zIndex), 1, 0, numberWidth)),
		inspectorRow(ctx, "Y sort", skald.checkbox(ctx, node.ySort, "", NodeFlag.Y_Sort,
			proc(flag: NodeFlag, value: bool) -> Msg { return Node_Flag_Changed{flag, value} },
			id = skald.hash_id(fmt.tprintf("inspector-%v-%d", NodeFlag.Y_Sort, key)))),
		inspectorRow(ctx, "Blend", enumSelect(ctx, node.blendMode, .Blend_Mode, key, controlWidth)),
		inspectorRow(ctx, "Process", enumSelect(ctx, node.processMode, .Process_Mode, key, controlWidth)),
		inspectorRow(ctx, "Groups", skald.text_input(ctx, node.groups, NodeTextField.Groups,
			proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} },
			id = skald.hash_id(fmt.tprintf("inspector-%v-%d", NodeTextField.Groups, key)),
			width = controlWidth, padding = InspectorFieldPadding(ctx))),
	)
	// While a code tab shows, each group drags into code by its chip (code_drag.odin): key
	// inspector-group-<name>-<node>
	if s.codeTab > 0 && strings.trim_space(node.groups) != "" {
		chips := make([dynamic]skald.View, context.temp_allocator)
		rest := node.groups
		for part in strings.split_iterator(&rest, ",") {
			g := strings.trim_space(part)
			if g == "" do continue
			chip := skald.col(skald.text(fmt.tprintf("%s %s", ICON_GRIP, g), th.color.fg_muted, th.font.size_xs), padding = 2, bg = th.color.surface, radius = th.radius.sm)
			append(&chips, CodeDrag_Zone(ctx, s, chip, fmt.tprintf("inspector-group-%s-%d", g, key), DropSource{kind = .Group, name = g, node = key, index = -1}))
		}
		append(&rows, inspectorLabelled(ctx, skald.spacer(0), skald.wrap_row(..chips[:], spacing = th.spacing.xs, line_spacing = 2, width = controlWidth)))
	}

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
	textureSelect :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, value: string, width: f32, atlases := false) -> skald.View {
		// The project's images (and atlases, for a Sprite), and "None" to clear it
		images := make([dynamic]string, context.temp_allocator)
		append(&images, TEXTURE_NONE)
		for asset in s.project.assets do if asset.kind == .Image || (atlases && asset.kind == .Atlas) do append(&images, asset.path)
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
	// A node type of the project's code: its own fields (node_scripts_edit.odin)
	if node.customKind != "" {
		append(&rows, ..nodeTypeRows(ctx, s, node, key, controlWidth, numberWidth))
		append(&rows, skald.divider(ctx))
	}
	append(&rows, ..scriptSection(ctx, s, node, key, controlWidth, numberWidth))
	append(&rows, ..moreScriptsRows(ctx, s, node, key, controlWidth, numberWidth))
	append(&rows, skald.divider(ctx))
	append(&rows, ..eventsSection(ctx, s, node, controlWidth))

	if node.kind != .Node2D {
		append(&rows, skald.divider(ctx), skald.text(fmt.tprintf("%v", node.kind), th.color.fg, th.font.size_sm))
	}
	switch node.kind {
	case .Node2D:
	case .Sprite:
		append(&rows, inspectorRow(ctx, "Texture", textureSelect(ctx, s, key, node.texture, controlWidth, atlases = true)))
		// An atlas: which of its images (atlas_edit.odin)
		if Asset_IsAtlas(node.texture) {
			regions := make([dynamic]string, context.temp_allocator)
			append(&regions, REGION_NONE)
			append(&regions, ..Atlas_RegionNames(&s.project, node.texture))
			append(&rows, inspectorRow(ctx, "Region", skald.select(ctx, node.region == "" ? REGION_NONE : node.region, regions[:], NodeTextField.Region, onText,
				id = skald.hash_id(fmt.tprintf("inspector-region-%d", key)), width = controlWidth)))
		}
		append(&rows, ..asepriteSpriteRows(ctx, s, node, key, controlWidth, numberWidth))
	case .AnimatedSprite:
		// The animations themselves are edited in the bottom panel's Animation tab; they're the
		// sprite's own, or an animation asset's (an .anim.xml file, or an Aseprite file's tags)
		sets := make([dynamic]string, context.temp_allocator)
		append(&sets, ANIMATION_OWN)
		for asset in s.project.assets do if Asset_IsAnimations(asset) do append(&sets, asset.path)
		append(&rows, inspectorRow(ctx, "Animations", skald.select(ctx, node.animationSet == "" ? ANIMATION_OWN : node.animationSet, sets[:], NodeTextField.Animation_Set, onText,
			id = skald.hash_id(fmt.tprintf("inspector-animation-set-%d", key)), width = controlWidth)))
		// The animations it plays: its own, or the asset's
		animations := node.animations[:]
		if node.animationSet != "" {
			animations = nil
			if i := Project_FindAnimationSet(&s.project, node.animationSet); i >= 0 {
				animations = s.project.animationSets[i].animations[:]
			} else if set := AsepriteEdit_AnimationSet(s.project.rootPath, node.animationSet); set != nil {
				animations = set.animations[:]
			} else {
				append(&rows, skald.text(fmt.tprintf("%s can't be read.", node.animationSet), th.color.warning, th.font.size_xs, max_width = inspectorRowWidth(controlWidth)))
			}
		}
		choices := make([dynamic]string, context.temp_allocator)
		append(&choices, ANIMATION_FIRST)
		for a in animations do append(&choices, a.name)
		editButton := skald.button(ctx, fmt.tprintf("%s  Edit Animations", ICON_FILM), Msg(Bottom_Tab_Changed(int(BottomTab.Animation))),
			id = skald.hash_id(fmt.tprintf("inspector-edit-animations-%d", key)),
			bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
		// Each animation has its own sheet (edited in the Animation panel): the ones they use
		sheets := make([dynamic]string, context.temp_allocator)
		for a in animations {
			name := a.sheet == "" ? "(none)" : filepath.base(strings.trim_suffix(a.sheet, e.ASEPRITE_SHEET_SUFFIX))
			known := false
			for other in sheets do if other == name do known = true
			if !known do append(&sheets, name)
		}
		sheetText := len(sheets) == 0 ? "none yet" : strings.join(sheets[:], ", ", context.temp_allocator)
		append(&rows, inspectorRow(ctx, "Sheets", skald.text(sheetText, th.color.fg_muted, th.font.size_xs, max_width = controlWidth)))
		append(&rows,
			inspectorRow(ctx, "Starts with", skald.select(ctx, node.autoplay == "" ? ANIMATION_FIRST : node.autoplay, choices[:], NodeTextField.Autoplay, onText,
				id = skald.hash_id(fmt.tprintf("inspector-autoplay-%d", key)), width = controlWidth)),
			inspectorRow(ctx, fmt.tprintf("%d animation%s", len(animations), len(animations) == 1 ? "" : "s"), editButton),
		)
		append(&rows, ..asepriteSpriteRows(ctx, s, node, key, controlWidth, numberWidth))
		// Its own animations, shared: an asset other sprites can use (the button on its own row:
		// it doesn't fit beside a label in a narrow inspector)
		if node.animationSet == "" {
			append(&rows, skald.button(ctx, fmt.tprintf("%s  Save as Animation Asset", ICON_FILM), Msg(Anim_Set_From_Node{}),
				id = skald.hash_id(fmt.tprintf("inspector-save-animations-%d", key)),
				bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm))
		}
	case .Label:
		append(&rows,
			inspectorRow(ctx, "Text", textField(ctx, key, .Text, node.text, controlWidth)),
			inspectorRow(ctx, "Font size", number(ctx, s, key, .Font_Size, node.fontSize, 2, 0, numberWidth, 1, 400)),
			inspectorRow(ctx, "Color", colorPicker(ctx, key, node.color, controlWidth)),
			inspectorRow(ctx, "Centered", flag(ctx, key, .Centered, node.centered)),
		)
	case .Camera:
		append(&rows, ..cameraInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
	case .StaticBody, .DynamicBody, .CharacterMover, .Area, .CollisionShape, .RayCast, .Joint:
		append(&rows, ..physicsInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
		if node.kind == .CollisionShape do append(&rows, ..sliceShapeRows(ctx, s, node, key, controlWidth))
	case .ParticleEmitter:
		append(&rows, ..particleInspectorRows(ctx, s, node, key, controlWidth))
	case .AudioPlayer, .AudioPlayer2D, .MusicPlayer:
		append(&rows, ..audioInspectorRows(ctx, s, node, key, controlWidth))
	case .LDtkLevel:
		append(&rows, ..ldtkInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
	case .TileMap:
		append(&rows, ..tileMapInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
	case .Animator:
		append(&rows, ..animatorInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
	case .ParallaxLayer, .CameraZone, .CameraView:
		append(&rows, ..cameraToolInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
	case .StateMachine:
		append(&rows, ..stateMachineInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
	case .NavRegion, .NavAgent:
		append(&rows, ..navInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
	case .VirtualJoystick, .TouchButton:
		append(&rows, ..touchInspectorRows(ctx, s, node, key, controlWidth))
	case .ScreenEffect:
		append(&rows, ..shaderInspectorRows(ctx, s, node, key, controlWidth))
	case .Line2D, .Trail2D:
		append(&rows, inspectorRow(ctx, "Texture", textureSelect(ctx, s, key, node.texture, controlWidth)))
		append(&rows, ..lineInspectorRows(ctx, s, node, key, controlWidth))
	case .DialogueBox:
		append(&rows, ..dialogueBoxRows(ctx, s, node, key, controlWidth))
	case .Skeleton2D, .Bone2D, .SkinnedMesh, .IKChain:
		append(&rows, ..skeletonInspectorRows(ctx, s, node, key, controlWidth, numberWidth, inspectorRow(ctx, "Texture", textureSelect(ctx, s, key, node.texture, controlWidth, atlases = true))))
	case .Light2D, .LightOccluder:
		append(&rows, ..lightInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
	case .Panel, .Button, .ProgressBar, .TextField, .ScrollBox, .RichText, .Slider, .CheckBox:
		append(&rows, ..uiInspectorRows(ctx, s, node, key, controlWidth, numberWidth))
	case .Component:
		// The component it's an instance of; its own fields are the component's (Open edits them)
		choices := make([dynamic]string, context.temp_allocator)
		append(&choices, TEXTURE_NONE)
		for asset in s.project.assets do if asset.kind == .Component do append(&choices, asset.path)
		append(&rows, inspectorRow(ctx, "Component", labeledSelect(ctx, node.component == "" ? TEXTURE_NONE : node.component, Asset_DisplayNames(choices[:]), choices[:], NodeTextField.Component, onText,
			id = skald.hash_id(fmt.tprintf("inspector-component-%d", key)), width = controlWidth, placeholder = "Choose a component")))
		if i := Project_FindComponent(&s.project, node.component); i >= 0 {
			open := skald.button(ctx, fmt.tprintf("%s  Edit %s", ICON_CUBES, s.project.scenes[i].name), Msg(Component_Opened(i)),
				id = skald.hash_id(fmt.tprintf("inspector-open-component-%d", key)),
				bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
			unique := skald.button(ctx, fmt.tprintf("%s  Make Unique", ICON_COPY), Msg(Component_Made_Unique{}),
				id = skald.hash_id(fmt.tprintf("inspector-make-unique-%d", key)),
				bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
			append(&rows, inspectorRow(ctx, "", open),
				inspectorRow(ctx, "", skald.tooltip(ctx, unique, "Give this instance its own copy of the component, to change it without changing the others",
					id = skald.hash_id(fmt.tprintf("inspector-make-unique-tip-%d", key)))),
				skald.text("Its name, position, rotation, scale, layer and visibility are this instance's; the rest is the component's: open it to change every instance.",
					th.color.fg_muted, th.font.size_xs, max_width = 260))
		} else if node.component != "" {
			append(&rows, skald.text(fmt.tprintf("%s isn't in the project.", node.component), th.color.warning, th.font.size_xs, max_width = 260))
		}
	case .Menu:
		// Editing buttons comes later; show what the menu does
		for item in node.items {
			append(&rows, inspectorRow(ctx, item.label, skald.text(item.action, th.color.fg_muted, th.font.size_sm)))
		}
		if len(node.items) == 0 {
			append(&rows, skald.text("No buttons", th.color.fg_muted, th.font.size_sm))
		}
	}
	// Its shader (shader_edit.odin; a ScreenEffect's are its own rows above)
	if node.kind != .ScreenEffect && NodeKind_TakesShader(node.kind) do append(&rows, ..shaderInspectorRows(ctx, s, node, key, controlWidth))
	// Rows plugins add (plugin_host.odin)
	append(&rows, ..pluginInspectorRows(ctx, s, controlWidth))

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
inspectorRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View, tip := "") -> skald.View {
	// Hovering the label explains the setting (tooltips.odin; `tip` adds to it)
	view := tipLabel(ctx, label, skald.text(label, ctx.theme.color.fg_muted, ctx.theme.font.size_sm), tip)
	// A node's property or script field drags into code (code_drag.odin): key
	// inspector-label-<label>-<node>, spaces as underscores (inspector-label-Position_X-2)
	// A script field's label also goes to its declaration: Ctrl+click, or its right-click menu
	// (code_actions.odin), and the code's "Show in the inspector" scrolls to it (always a zone)
	if d := inspectorDrag; d.state != nil && d.script != "" && label != "" {
		key := Inspector_ScriptFieldKey(label, d.node)
		id := skald.hash_id(key)
		if desc := ScriptCatalog_Find(&d.state.scripts, d.script); desc != nil {
			for f, i in desc.fields do if f.name == label {
				rect := lastRect(ctx, id)
				rightPressOpens(ctx, rect, Ctx_Script_Field{node = d.node, field = i})
				free := !skald.mouse_over_overlay(ctx) && ctx.widgets.modal_rect_prev.w == 0
				if ctx.input.mouse_pressed[.Left] && skald.PRIMARY_MODIFIER in ctx.input.modifiers && free && pointIn(rect, ctx.input.mouse_pos) {
					skald.send(ctx, Msg(Script_Field_Declaration_Requested{d.script, label}))
					ctx.input.mouse_pressed[.Left] = false
				}
				break
			}
		}
		if d.state.codeTab > 0 {
			view = CodeDrag_Zone(ctx, d.state, view, key, DropSource{kind = .Script_Field, name = label, node = d.node, index = -1, script = d.script})
		} else {
			view = skald.zone(ctx, view, id)
		}
	} else if d := inspectorDrag; d.state != nil && d.state.codeTab > 0 && label != "" {
		spaced, _ := strings.replace_all(label, " ", "_", context.temp_allocator)
		key := fmt.tprintf("inspector-label-%s-%d", spaced, d.node)
		if _, _, ok := CodeDrops_PropertyField(d.kind, label); ok {
			view = CodeDrag_Zone(ctx, d.state, view, key, DropSource{kind = .Property, name = label, node = d.node, index = -1})
		}
	}
	return inspectorLabelled(ctx, view, control)
}

// The node whose rows the inspector is building, and the script whose fields they are (set by
// inspectorView; per thread: unit tests build views in parallel)
@(thread_local, private="file")
inspectorDrag: struct {
	state:  ^State,
	node:   int,
	kind:   NodeKind,
	script: string,
}

/*
A label (any view: a text, or a text with a button under it) and its control: side by side, the
label in its column of INSPECTOR_LABEL_WIDTH, or in a narrow inspector (`inspectorStacked`) the
label over the control, which then has the row's whole width.
*/
inspectorLabelled :: proc(ctx: ^skald.Ctx(Msg), label, control: skald.View) -> skald.View {
	th := ctx.theme
	if inspectorStacked do return skald.col(label, control, spacing = 2)
	return skald.row(
		skald.col(label, width = INSPECTOR_LABEL_WIDTH),
		control,
		spacing = th.spacing.sm,
		cross_align = .Center,
	)
}

// The inspector's rows stack their labels over their controls (set while the right sidebar is
// built: `Inspector_Layout`)
@(private="package")
inspectorStacked: bool

/*
How the inspector lays out its rows at a sidebar width: a label column beside the controls, or,
when that leaves a control less than a number field with a link button needs
(`NumberField_MinWidth`: it's never drawn narrower, and anything past the width runs under the
scrollbar), labels over the controls.

Inputs:
- th: The theme (the number field's buttons and the spacing follow it)
- sidebarWidth: The right sidebar's width

Returns:
- controlWidth: The width a row's control has (before the rows' caps, INSPECTOR_MAX_TEXT_WIDTH)
- stacked: Labels go over their controls
*/
Inspector_Layout :: proc(th: ^skald.Theme, sidebarWidth: f32) -> (controlWidth: f32, stacked: bool) {
	inner := sidebarWidth - th.spacing.md * 2 - INSPECTOR_SCROLLBAR_WIDTH
	beside := inner - INSPECTOR_LABEL_WIDTH - th.spacing.sm
	needed := NumberField_MinWidth(th) + LINK_BUTTON_WIDTH + th.spacing.xs
	if beside >= needed do return beside, false
	return max(inner, needed), true
}

// The width a row's control has at a sidebar width (`Inspector_Layout`)
inspectorControlWidth :: proc(th: ^skald.Theme, sidebarWidth: f32) -> f32 {
	width, _ := Inspector_Layout(th, sidebarWidth)
	return width
}

// A whole row's width (text spanning it, a row of buttons), from its control's width
inspectorRowWidth :: proc(controlWidth: f32) -> f32 {
	return inspectorStacked ? controlWidth : controlWidth + INSPECTOR_LABEL_WIDTH
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

// The X/Y link button's width (beside Position X and Scale X)
@(private="package")
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
	case .Unknown:  status = len(s.scriptFiles) > 0 ? fmt.tprintf("not built yet%s", keyParen(s, .Build_Scripts)) : ""
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
		message := s.scripts.status == .Building ? "Building..." : fmt.tprintf("Build the scripts%s to edit %s's fields.", keyParen(s, .Build_Scripts), node.script)
		append(&rows, skald.text(message, th.color.fg_muted, th.font.size_xs, max_width = inspectorRowWidth(controlWidth)))
		for prop in node.props do append(&rows, inspectorRowView(ctx, prop.name, skald.text(prop.value, th.color.fg_muted, th.font.size_sm)))
		return rows[:]
	}
	// Where the fields come from: read from the source by the script index (the file changed
	// since the last build, or there's been none: the game runs the old fields until it's built),
	// or the build. Always one short line: a row that came and went with the build moved the rows
	// below when the build ended (a click on the Events toggle was lost when they moved between
	// the pointer's move and the press)
	source := desc.fromIndex ? fmt.tprintf("From the source: not built yet%s", keyParen(s, .Build_Scripts)) : "From the last build"
	// As wide as the rows (a wider text widened the inspector's content in a narrow window, and
	// pushed the Events' Listen... buttons under its scrollbar)
	append(&rows, skald.text(source, th.color.fg_muted, th.font.size_xs, max_width = inspectorRowWidth(controlWidth)))
	if len(desc.fields) == 0 {
		append(&rows, skald.text("No exported fields (tag a field with export:\"\" to edit it here).", th.color.fg_muted, th.font.size_xs, max_width = inspectorRowWidth(controlWidth)))
	}
	// Their labels drag into code as the script's fields
	inspectorDrag.script = node.script
	for &field in desc.fields {
		append(&rows, inspectorRow(ctx, field.name, FieldControl(ctx, s, node.props[:], &field, fmt.tprintf("%d", key), SelectedNodeTarget{}, controlWidth, numberWidth), scriptFieldTip(&field)))
		append(&rows, ..FieldMismatchRows(ctx, node.props[:], &field, fmt.tprintf("%d", key), SelectedNodeTarget{}, controlWidth + 100))
	}
	inspectorDrag.script = ""
	// Values of fields the code no longer has: kept and shown, not dropped
	append(&rows, ..OrphanedValueRows(ctx, node.props[:], desc, fmt.tprintf("%d", key), SelectedNodeTarget{}, controlWidth + 100))
	return rows[:]
}

// inspectorRow, for code outside the main inspector proc
@(private="file")
inspectorRowView :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	return inspectorRow(ctx, label, control)
}

// A dropdown of an enum's values for a node setting, sent as Node_Text_Changed{field, name}
@(private="file")
enumSelect :: proc(ctx: ^skald.Ctx(Msg), value: $E, field: NodeTextField, key: int, width: f32) -> skald.View {
	names := make([]string, len(E), context.temp_allocator)
	for v, i in E do names[i] = fmt.tprintf("%v", v)
	return skald.select(ctx, fmt.tprintf("%v", value), names, field,
		proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} },
		id = skald.hash_id(fmt.tprintf("inspector-%v-%d", field, key)), width = width)
}

/*
Scrolls the inspector to a widget over the next frames (a script field's row the code's "Show in
the inspector" asked for): rows far outside the scroll aren't laid out, so it pages down until the
widget is drawn, then brings it into view. Set from update (`Inspector_RevealWidget`).
*/
Inspector_RevealWidget :: proc(key: string) {
	inspectorReveal.id = skald.hash_id(key)
	inspectorReveal.frames = 0
	inspectorReveal.active = true
}

// The widget the inspector scrolls to, and for how many frames it has looked (per thread: tests)
@(thread_local, private="file")
inspectorReveal: struct {
	id: skald.Widget_ID,
	frames: int,
	active: bool,
}

// The most frames the inspector pages looking for a widget
@(private="file")
INSPECTOR_REVEAL_FRAMES :: 60

@(private="file")
inspectorRevealStep :: proc(ctx: ^skald.Ctx(Msg)) {
	r := &inspectorReveal
	if !r.active do return
	r.frames += 1
	scroll, drawn := &ctx.widgets.states[skald.hash_id("inspector-scroll")]
	if r.frames > INSPECTOR_REVEAL_FRAMES {
		r.active = false
		return
	}
	// Keep frames coming while it looks
	skald.send(ctx, Msg(Frame_Requested{}))
	// The first frames: the selection's rows aren't built yet
	if !drawn || scroll.last_rect.h <= 0 || r.frames < 3 do return
	area := scroll.last_rect
	target, seen := ctx.widgets.states[r.id]
	if !seen || !skald.widget_drawn_last_frame(ctx.widgets, target) {
		// Not laid out: page down (from the top first)
		scroll.scroll_y = r.frames == 3 ? 0 : scroll.scroll_y + area.h * 0.8
		return
	}
	t := target.last_rect
	MARGIN :: f32(24)
	switch {
	case t.y < area.y:              scroll.scroll_y = max(scroll.scroll_y - (area.y - t.y) - MARGIN, 0)
	case t.y + t.h > area.y + area.h: scroll.scroll_y += t.y + t.h - (area.y + area.h) + MARGIN
	case: r.active = false
	}
}
