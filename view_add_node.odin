package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:math"
import "gui:skald"
import e "engine:."

/*
The Add Node dialog: a search box over the list of node kinds the engine supports.

	search    filters by kind name, description or category; focused when the dialog opens
	list      the matching kinds under their category's header (icon, name, description), then the
	          node types of the project's code (node_scripts_edit.odin), in a scroll as tall as the
	          window allows; click to add
	footer    where the node goes (child of the selection, or top-level)

Keys: Up / Down move the highlight (the list scrolls to keep it in view), Enter adds the
highlighted kind, Escape closes.
Widget keys for UI tests: `add-node-dialog`, `add-node-search`, `add-node-scroll`,
`add-node-<Kind>` (a node type of the project's code: `add-node-<Type>`).
*/
addNodeDialog :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
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
	entries := AddNode_Entries(s.addNode.search, &s.scripts)
	y: f32 = 0
	highlightTop: f32 = -1
	// The header over each run of entries: a category's name, or the project's node types'
	header := ""
	for entry, i in entries {
		entryHeader := entry.custom != "" ? ADD_NODE_TYPES_HEADER : e.SCENE_NODE_CATEGORY_NAMES[e.SCENE_NODE_KINDS[entry.kind].category]
		if entryHeader != header {
			header = entryHeader
			append(&rows, skald.col(
				uiText(th, .Label, header),
				height = headerHeight,
				padding = th.spacing.sm,
				main_align = .End,
			))
			y += headerHeight + ROW_SPACING
		}
		if i == s.addNode.highlight do highlightTop = y
		y += rowHeight + ROW_SPACING
		label := entry.custom != "" ? entry.custom : fmt.tprintf("%v", entry.kind)
		id := skald.hash_id(fmt.tprintf("add-node-%s", label))
		highlighted := i == s.addNode.highlight
		bg := th.color.bg
		if highlighted do bg = th.color.primary
		else if skald.widget_hovered(ctx, id) do bg = th.color.surface
		fg := highlighted ? th.color.on_primary : th.color.fg
		muted := highlighted ? th.color.on_primary : th.color.fg_muted
		row := skald.col(
			skald.text(fmt.tprintf("%s  %s", NodeKindIcon(entry.kind), label), fg, th.font.size_md),
			skald.text(entry.description, muted, th.font.size_xs),
			height = rowHeight,
			spacing = tk.xxs,
			padding = th.spacing.sm,
			cross_align = .Stretch,
			bg = bg,
			radius = th.radius.sm,
		)
		msg := entry.custom != "" ? Msg(Add_Node_Type_Chosen(entry.custom)) : Msg(Add_Node_Kind_Chosen(entry.kind))
		append(&rows, skald.clickable(ctx, row, msg, id = id, focusable = false))
	}
	if len(entries) == 0 {
		append(&rows, uiText(th, .Label, fmt.tprintf("No node types match '%s'", s.addNode.search)))
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
			uiText(th, .Title, s.addNode.forComponent ? "New Component" : "Add Node"),
			search,
			list,
			uiText(th, .Muted, addNodeParentHint(s)),
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
		width = tk.dialogM,
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
