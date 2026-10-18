package editor

import "core:fmt"
import "gui:skald"
import e "engine:."

/*
The Add Node dialog: a search box over the list of node kinds the engine supports.

	search    filters by kind name or description; focused when the dialog opens
	list      one row per matching kind (icon, name, description); click to add
	footer    where the node goes (child of the selection, or top-level)

Keys: Up / Down move the highlight, Enter adds the highlighted kind, Escape closes.
Widget keys for UI tests: `add-node-dialog`, `add-node-search`, `add-node-<Kind>`.
*/
addNodeDialog :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	// Closed: no content (its buttons would stay clickable where they were drawn: closedDialog)
	if !s.addNode.open do return closedDialog(ctx, "add-node-dialog")
	th := ctx.theme
	if s.addNode.open {
		// Before the search box, so it doesn't see these keys
		skald.shortcut(ctx, {.Up, {}}, Msg(Add_Node_Highlight_Moved(-1)))
		skald.shortcut(ctx, {.Down, {}}, Msg(Add_Node_Highlight_Moved(1)))
		skald.shortcut(ctx, {.Enter, {}}, Msg(Add_Node_Confirmed{}))
	}

	search := skald.row(
		skald.flex(1, skald.text_input(ctx, s.addNode.search,
			proc(v: string) -> Msg { return Add_Node_Search_Changed(v) },
			id = skald.hash_id("add-node-search"),
			placeholder = "Search node types",
			clear_button = true)),
		cross_align = .Center,
	)

	rows := make([dynamic]skald.View, context.temp_allocator)
	kinds := AddNode_Kinds(s.addNode.search)
	for kind, i in kinds {
		id := skald.hash_id(fmt.tprintf("add-node-%v", kind))
		highlighted := i == s.addNode.highlight
		bg := th.color.bg
		if highlighted do bg = th.color.primary
		else if skald.widget_hovered(ctx, id) do bg = th.color.surface
		fg := highlighted ? th.color.on_primary : th.color.fg
		muted := highlighted ? th.color.on_primary : th.color.fg_muted
		row := skald.col(
			skald.text(fmt.tprintf("%s  %v", NodeKindIcon(kind), kind), fg, th.font.size_md),
			skald.text(e.SCENE_NODE_KINDS[kind].description, muted, th.font.size_xs),
			spacing = 2,
			padding = th.spacing.sm,
			cross_align = .Stretch,
			bg = bg,
			radius = th.radius.sm,
		)
		append(&rows, skald.clickable(ctx, row, Msg(Add_Node_Kind_Chosen(kind)), id = id, focusable = false))
	}
	if len(kinds) == 0 {
		append(&rows, skald.text(fmt.tprintf("No node types match '%s'", s.addNode.search), th.color.fg_muted, th.font.size_sm))
	}

	return skald.dialog(ctx,
		open = s.addNode.open,
		on_dismiss = proc() -> Msg { return Add_Node_Cancelled{} },
		content = skald.col(
			skald.text("Add Node", th.color.fg, th.font.size_lg),
			search,
			skald.col(..rows[:], spacing = 2, cross_align = .Stretch),
			skald.text(addNodeParentHint(s), th.color.fg_muted, th.font.size_xs),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(Add_Node_Cancelled{}), id = skald.hash_id("add-node-cancel")),
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("add-node-dialog"),
		initial_focus = skald.hash_id("add-node-search"),
		width = 420,
	)
}

// Where the new node will go
@(private="file")
addNodeParentHint :: proc(s: ^State) -> string {
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) {
		return fmt.tprintf("Adds a child of %s.", scene.nodes[s.selectedNode].name)
	}
	return fmt.tprintf("Adds a top-level node to %s.", scene.name)
}
