package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:strings"
import "gui:skald"

/*
Multi-node editing (TODO.md's "UI and UX" round "Workflow", 2026-10-25): with several nodes
selected, the inspector shows the properties they share; setting one sets it on every selected
node in one undo step, and a property whose values differ shows "—".

- **What's shared** (`inspectorMultiView`, view_inspector.odin): the rows every node has (position,
  rotation, scale, layer, visible, Z index, Y sort, blend, process, groups). The node's name, its
  kind's own rows, its script and events stay one node's: select one node to edit them.
- **The generic path** (`MultiEdit_Applies`, `MultiEdit_Apply`): a node property message
  (`Node_Field_Changed`, `Node_Text_Changed`, `Node_Flag_Changed`, `Node_Visibility_Changed`,
  `Node_Layer_Toggled`, typing in a node number field: `Number_Text_Changed` with a `NodeField`)
  is applied to each selected node in turn as if it were the only one selected (`applyMsg` with
  `selectedNode` set to it), so every rule of the one-node edit (clamps, linked X / Y pairs)
  holds per node. `History_Classify` makes it one `.Scene` step (`MultiEdit_Classify`; typing and
  steppers merge like the one-node edit's) and the selection is kept.
- **Mixed values** (`MultiEdit_Mixed`): a number field shows "—" (its − / + set every node to the
  primary's value ± a step), a checkbox's label "—", a text field "" with "—" as its placeholder.
- Not covered: renaming several nodes, the kinds' own rows (a Sprite's texture across sprites),
  scripts and their fields, events.
*/

/*
Whether a message is a node property edit that applies to every selected node.

Returns:
- true with several nodes selected and `m` one of the generic node edits
*/
MultiEdit_Applies :: proc(state: ^State, m: Msg) -> bool {
	if len(state.selection) < 2 || state.mode != .Scene do return false
	#partial switch v in m {
	case Node_Field_Changed, Node_Text_Changed, Node_Flag_Changed, Node_Visibility_Changed, Node_Layer_Toggled:
		return true
	case Number_Text_Changed:
		_, isNode := v.target.(NodeField)
		return isNode
	}
	return false
}

/*
Applies a node property edit to every selected node (`MultiEdit_Applies`), the primary one last
so it stays selected. Typing in a number field keeps its text once and applies the value to each.
*/
MultiEdit_Apply :: proc(state: ^State, m: Msg) {
	msg := m
	if typed, isTyping := m.(Number_Text_Changed); isTyping {
		msg = NumberEdit_Update(state, typed)
		if msg == nil do return
	}
	primary := state.selectedNode
	nodes := make([]int, len(state.selection), context.temp_allocator)
	copy(nodes, state.selection[:])
	scene := &state.project.scenes[state.currentScene]
	for n in nodes {
		if n == primary || n < 0 || n >= len(scene.nodes) do continue
		state.selectedNode = n
		applyMsg(state, msg)
	}
	state.selectedNode = primary
	applyMsg(state, msg)
	// The applyMsg calls above may have trimmed the selection to the node they edited
	Selection_Set(state, nodes, primary)
}

/*
The undo step of a multi-node edit: the whole scene, one step, merged while the same field is
typed or stepped.
*/
MultiEdit_Classify :: proc(state: ^State, m: Msg) -> EditInfo {
	key :: proc(parts: ..any) -> u64 {
		return hash.fnv64a(transmute([]byte)fmt.tprint(..parts))
	}
	count := len(state.selection)
	what := "a property"
	merge: u64
	#partial switch v in m {
	case Node_Field_Changed:
		what = fieldLabel(v.field)
		merge = key("multi-field", v.field, state.currentScene)
	case Number_Text_Changed:
		if field, ok := v.target.(NodeField); ok {
			what = fieldLabel(field)
			merge = key("multi-field", field, state.currentScene)
		}
	case Node_Text_Changed:
		what = fmt.tprint(v.field)
		merge = key("multi-text", v.field, state.currentScene)
	case Node_Flag_Changed:
		what = fmt.tprint(v.flag)
	case Node_Visibility_Changed:
		return {scope = .Scene, label = fmt.tprintf("%s %d nodes", bool(v) ? "Show" : "Hide", count)}
	case Node_Layer_Toggled:
		what = v.mask ? "the collision mask" : "the collision layer"
	}
	return {scope = .Scene, label = fmt.tprintf("Change %s of %d nodes", what, count), mergeKey = merge}
}

// The base properties the multi-node inspector shows, for `MultiEdit_Mixed`
MultiProp :: enum {
	Position_X,
	Position_Y,
	Rotation,
	Scale_X,
	Scale_Y,
	Layer,
	Visible,
	Z_Index,
	Y_Sort,
	Blend,
	Process,
	Groups,
}

/*
Which of the shared properties differ between the selected nodes.

Returns:
- The properties whose values aren't all the primary node's
*/
MultiEdit_Mixed :: proc(state: ^State) -> bit_set[MultiProp] {
	mixed: bit_set[MultiProp]
	scene := &state.project.scenes[state.currentScene]
	if state.selectedNode < 0 || state.selectedNode >= len(scene.nodes) do return mixed
	p := &scene.nodes[state.selectedNode]
	for n in state.selection {
		if n < 0 || n >= len(scene.nodes) || n == state.selectedNode do continue
		o := &scene.nodes[n]
		if o.position.x != p.position.x do mixed += {.Position_X}
		if o.position.y != p.position.y do mixed += {.Position_Y}
		if o.rotation != p.rotation do mixed += {.Rotation}
		if o.scale.x != p.scale.x do mixed += {.Scale_X}
		if o.scale.y != p.scale.y do mixed += {.Scale_Y}
		if o.layer != p.layer do mixed += {.Layer}
		if o.visible != p.visible do mixed += {.Visible}
		if o.zIndex != p.zIndex do mixed += {.Z_Index}
		if o.ySort != p.ySort do mixed += {.Y_Sort}
		if o.blendMode != p.blendMode do mixed += {.Blend}
		if o.processMode != p.processMode do mixed += {.Process}
		if strings.trim_space(o.groups) != strings.trim_space(p.groups) do mixed += {.Groups}
	}
	return mixed
}

// What a mixed value shows
MIXED_VALUE :: "—"

/*
The inspector with several nodes selected: how many and of which kinds, then the properties they
share, mixed values as "—". Keys are the one-node inspector's with the primary node's index
(`inspector-Position_X-<node>`), so a value being typed stays with the field.
*/
inspectorMultiView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	scene := &s.project.scenes[s.currentScene]
	node := &scene.nodes[s.selectedNode]
	key := s.selectedNode
	mixed := MultiEdit_Mixed(s)
	_, sidebarWidth := FittedSidebarWidths(&s.layout)
	controlWidth := inspectorControlWidth(th, sidebarWidth)
	numberWidth := min(controlWidth - LINK_BUTTON_WIDTH - th.spacing.xs, INSPECTOR_MAX_NUMBER_WIDTH)
	controlWidth = min(controlWidth, INSPECTOR_MAX_TEXT_WIDTH)

	// The kinds selected: "3 Sprites, 1 Label"
	counts: [NodeKind]int
	for n in s.selection do if n >= 0 && n < len(scene.nodes) do counts[scene.nodes[n].kind] += 1
	kinds := make([dynamic]string, context.temp_allocator)
	for count, kind in counts do if count > 0 do append(&kinds, fmt.tprintf("%d %v", count, kind))

	number :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: int, field: NodeField, value: f32, step: f64, decimals: int, width: f32, mixed: bool, minValue := min(f64), maxValue := max(f64)) -> skald.View {
		return numberField(ctx, s, fmt.tprintf("inspector-%v-%d", field, key), field, f64(value), step, decimals, width, minValue, maxValue, mixed = mixed)
	}
	check :: proc(ctx: ^skald.Ctx(Msg), id: string, value, mixed: bool, msg: proc(v: bool) -> Msg) -> skald.View {
		return skald.checkbox(ctx, value && !mixed, mixed ? MIXED_VALUE : "", msg, id = skald.hash_id(id))
	}
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows,
		uiText(th, .Value, fmt.tprintf("%d nodes selected", len(s.selection))),
		uiText(th, .Muted, strings.join(kinds[:], ", ", context.temp_allocator), max_width = tk.textNarrow),
		inspectorRow(ctx, "Position X", linked(ctx, s, .Position, number(ctx, s, key, .Position_X, node.position.x, 1, 0, numberWidth, .Position_X in mixed))),
		inspectorRow(ctx, "Position Y", linkSpace(ctx, number(ctx, s, key, .Position_Y, node.position.y, 1, 0, numberWidth, .Position_Y in mixed))),
		inspectorRow(ctx, "Rotation", number(ctx, s, key, .Rotation, node.rotation, 5, 1, numberWidth, .Rotation in mixed)),
		inspectorRow(ctx, "Scale X", linked(ctx, s, .Scale, number(ctx, s, key, .Scale_X, node.scale.x, 0.1, 2, numberWidth, .Scale_X in mixed))),
		inspectorRow(ctx, "Scale Y", linkSpace(ctx, number(ctx, s, key, .Scale_Y, node.scale.y, 0.1, 2, numberWidth, .Scale_Y in mixed))),
		inspectorRow(ctx, "Layer", number(ctx, s, key, .Layer, f32(node.layer), 1, 0, numberWidth, .Layer in mixed, 0, 7)),
		inspectorRow(ctx, "Visible", check(ctx, fmt.tprintf("inspector-visible-%d", key), node.visible, .Visible in mixed,
			proc(v: bool) -> Msg { return Node_Visibility_Changed(v) })),
		inspectorRow(ctx, "Z index", number(ctx, s, key, .Z_Index, f32(node.zIndex), 1, 0, numberWidth, .Z_Index in mixed)),
		inspectorRow(ctx, "Y sort", check(ctx, fmt.tprintf("inspector-%v-%d", NodeFlag.Y_Sort, key), node.ySort, .Y_Sort in mixed,
			proc(v: bool) -> Msg { return Node_Flag_Changed{.Y_Sort, v} })),
		inspectorRow(ctx, "Blend", enumSelect(ctx, node.blendMode, .Blend_Mode, key, controlWidth, mixed = .Blend in mixed)),
		inspectorRow(ctx, "Process", enumSelect(ctx, node.processMode, .Process_Mode, key, controlWidth, mixed = .Process in mixed)),
		inspectorRow(ctx, "Groups", skald.text_input(ctx, .Groups in mixed ? "" : node.groups, NodeTextField.Groups,
			proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} },
			id = skald.hash_id(fmt.tprintf("inspector-%v-%d", NodeTextField.Groups, key)),
			width = controlWidth, padding = InspectorFieldPadding(ctx), placeholder = .Groups in mixed ? MIXED_VALUE : "")),
		uiText(th, .Muted, "A value set here is set on every selected node (one undo step); — marks values that differ. Select one node for its name, its kind's settings, script and events.", max_width = tk.textNarrow),
	)
	return skald.col(..rows[:], spacing = th.spacing.sm, padding = th.spacing.md, cross_align = .Stretch)
}
