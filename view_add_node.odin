package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:math"
import "gui:skald"
import e "engine:."

/*
The Add Node dialog: a search box over the list of node kinds the engine supports.

	search    filters by kind name, description or category; focused when the dialog opens
	list      the matching kinds under their category's header (icon, name, description), in a
	          scroll as tall as the window allows; click to add
	footer    where the node goes (child of the selection, or top-level)

Keys: Up / Down move the highlight (the list scrolls to keep it in view), Enter adds the
highlighted kind, Escape closes.
Widget keys for UI tests: `add-node-dialog`, `add-node-search`, `add-node-scroll`,
`add-node-<Kind>`.
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

	// Fixed heights, so where each row is in the list is known without laying it out (rows
	// scrolled far out of view keep stale rects): the highlight is scrolled into view with them
	rowHeight := math.ceil(th.font.size_md * 1.35 + th.font.size_xs * 1.35 + 2 + th.spacing.sm * 2)
	headerHeight := math.ceil(th.font.size_sm * 1.35 + th.spacing.sm * 2)
	ROW_SPACING :: f32(2)
	rows := make([dynamic]skald.View, context.temp_allocator)
	kinds := AddNode_Kinds(s.addNode.search)
	y: f32 = 0
	highlightTop: f32 = -1
	category := e.SceneNodeCategory(-1)
	for kind, i in kinds {
		info := e.SCENE_NODE_KINDS[kind]
		if info.category != category {
			category = info.category
			append(&rows, skald.col(
				skald.text(e.SCENE_NODE_CATEGORY_NAMES[category], th.color.fg_muted, th.font.size_sm),
				height = headerHeight,
				padding = th.spacing.sm,
				main_align = .End,
			))
			y += headerHeight + ROW_SPACING
		}
		if i == s.addNode.highlight do highlightTop = y
		y += rowHeight + ROW_SPACING
		id := skald.hash_id(fmt.tprintf("add-node-%v", kind))
		highlighted := i == s.addNode.highlight
		bg := th.color.bg
		if highlighted do bg = th.color.primary
		else if skald.widget_hovered(ctx, id) do bg = th.color.surface
		fg := highlighted ? th.color.on_primary : th.color.fg
		muted := highlighted ? th.color.on_primary : th.color.fg_muted
		row := skald.col(
			skald.text(fmt.tprintf("%s  %v", NodeKindIcon(kind), kind), fg, th.font.size_md),
			skald.text(info.description, muted, th.font.size_xs),
			height = rowHeight,
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

	// As tall as the list, less in a short window (the title, search, hint and Cancel take
	// about 230 px), so the dialog stays on screen
	listHeight := max(y - ROW_SPACING, rowHeight)
	if ctx.renderer != nil do listHeight = min(listHeight, max(f32(ctx.renderer.fb_size.y) - 230, rowHeight * 3), 520)
	addNodeRevealHighlight(ctx, s, highlightTop, rowHeight, listHeight)
	list := skald.scroll(ctx, {0, listHeight}, skald.col(..rows[:], spacing = ROW_SPACING, cross_align = .Stretch),
		id = skald.hash_id("add-node-scroll"))

	return skald.dialog(ctx,
		open = s.addNode.open,
		on_dismiss = proc() -> Msg { return Add_Node_Cancelled{} },
		content = skald.col(
			skald.text(s.addNode.forComponent ? "New Component" : "Add Node", th.color.fg, th.font.size_lg),
			search,
			list,
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

// The highlight and search the list was last scrolled for: it scrolls when either changes
@(private="file")
addNodeRevealed: struct {
	highlight: int,
	search:    u32,
	known:     bool,
}

// Scrolls the list so the highlighted row is in view, when the highlight or the search changed
@(private="file")
addNodeRevealHighlight :: proc(ctx: ^skald.Ctx(Msg), s: ^State, top, rowHeight, listHeight: f32) {
	search := hash.fnv32a(transmute([]u8)s.addNode.search)
	if addNodeRevealed.known && addNodeRevealed.highlight == s.addNode.highlight && addNodeRevealed.search == search do return
	scroll, drawn := &ctx.widgets.states[skald.hash_id("add-node-scroll")]
	if !drawn do return
	addNodeRevealed = {s.addNode.highlight, search, true}
	if top < 0 do return
	MARGIN :: f32(4)
	if top + rowHeight + MARGIN > scroll.scroll_y + listHeight {
		scroll.scroll_y = top + rowHeight + MARGIN - listHeight
	} else if top - MARGIN < scroll.scroll_y {
		// The first row: up to the top, its category's header with it
		scroll.scroll_y = s.addNode.highlight == 0 ? 0 : max(top - MARGIN, 0)
	} else {
		return
	}
	skald.send(ctx, Msg(Frame_Requested{}))
}

// Where the new node will go
@(private="file")
addNodeParentHint :: proc(s: ^State) -> string {
	if s.addNode.forComponent do return "The component's root: what it is (a Sprite, an Area, a CharacterMover...). Its name is the component's."
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) {
		return fmt.tprintf("Adds a child of %s.", scene.nodes[s.selectedNode].name)
	}
	return fmt.tprintf("Adds a top-level node to %s.", scene.name)
}
