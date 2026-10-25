package crossfire_editor

import "core:fmt"
import "core:hash"
import "gui:skald"

/*
The command palette's popup (command_palette.odin), styled like the Add Node dialog:

	search      the query (its prefix keeps a category); focused when it opens
	categories  All and a button per category, each typing its prefix (`palette-category-<Kind>`)
	list        the matches, best first: the category, the label, its detail (a shortcut, a path)
	            at the right; the highlighted row lit; at most `PALETTE_SHOWN`, then a count

Keys: Up / Down, Page Up / Page Down move the highlight (the list scrolls to keep it in view),
Enter runs it, Escape closes. Widget keys for UI tests: `command-palette`, `palette-search`,
`palette-scroll`, `palette-row-<i>` (in the matches' order), `palette-category-All` /
`-Action` / `-Setting` / `-Node` / `-Asset` / `-Doc`.
*/
commandPaletteView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	if !s.palette.open do return closedDialog(ctx, "command-palette")
	tk := uiTokens(ctx)
	th := ctx.theme
	rowHeight := tk.rowHeight
	// The rows a page moves
	page := 8
	// Before the search box, so it doesn't see these keys
	skald.shortcut(ctx, {.Up, {}}, Msg(Palette_Highlight_Moved(-1)))
	skald.shortcut(ctx, {.Down, {}}, Msg(Palette_Highlight_Moved(1)))
	skald.shortcut(ctx, {.Page_Up, {}}, Msg(Palette_Highlight_Moved(-page)))
	skald.shortcut(ctx, {.Page_Down, {}}, Msg(Palette_Highlight_Moved(page)))
	skald.shortcut(ctx, {.Enter, {}}, Msg(Palette_Confirmed{}))

	search := skald.text_input(ctx, s.palette.query,
		proc(v: string) -> Msg { return Palette_Query_Changed(v) },
		id = skald.hash_id("palette-search"),
		placeholder = "Search actions, settings, nodes, assets, docs",
		clear_button = true)

	// The category buttons: All, then one per prefix (Code shares the actions' >)
	kinds, _ := Palette_ParseQuery(s.palette.query)
	all := kinds == ~bit_set[PaletteKind]{}
	categories := make([dynamic]skald.View, context.temp_allocator)
	category :: proc(ctx: ^skald.Ctx(Msg), key, label: string, on: bool, kind: int) -> skald.View {
		th := ctx.theme
		tk := uiTokens(ctx)
		return skald.button(ctx, label, Msg(Palette_Category_Picked(kind)),
			id = skald.hash_id(fmt.tprintf("palette-category-%s", key)),
			bg = on ? th.color.primary : th.color.surface, fg = on ? th.color.on_primary : th.color.fg_muted,
			padding = tk.buttonPadding, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	append(&categories, category(ctx, "All", "All", all, -1))
	for kind in PaletteKind {
		if kind == .Code do continue
		name := kind == .Action ? "Actions" : kind == .Doc ? "Docs" : fmt.tprintf("%ss", PALETTE_KIND_NAMES[kind])
		append(&categories, category(ctx, fmt.tprintf("%v", kind), fmt.tprintf("%c %s", PALETTE_PREFIXES[kind], name), !all && kind in kinds, int(kind)))
	}

	codePath := Palette_CodePath(s)
	entries := Palette_Entries(s, codePath)
	matches := Palette_Matches(entries, s.palette.query)
	shown := min(len(matches), PALETTE_SHOWN)
	highlight := clamp(s.palette.highlight, 0, max(shown - 1, 0))
	rows := make([dynamic]skald.View, context.temp_allocator)
	for m, i in matches[:shown] {
		entry := entries[m.entry]
		id := skald.hash_id(fmt.tprintf("palette-row-%d", i))
		lit := i == highlight
		bg := th.color.surface
		if lit do bg = th.color.primary
		else if skald.widget_hovered(ctx, id) do bg = th.color.bg
		fg := lit ? th.color.on_primary : th.color.fg
		muted := lit ? th.color.on_primary : th.color.fg_muted
		row := skald.row(
			skald.col(uiText(th, .Muted, PALETTE_KIND_NAMES[entry.kind], color = muted), width = tk.fieldXS),
			skald.flex(1, uiText(th, .Value, entry.label, overflow = .Ellipsis, color = fg)),
			uiText(th, .Muted, entry.detail, max_width = tk.fieldL, overflow = .Ellipsis, color = muted),
			height = rowHeight,
			spacing = tk.s,
			padding = tk.s,
			cross_align = .Center,
			bg = bg,
			radius = th.radius.sm,
		)
		append(&rows, skald.clickable(ctx, row, Msg(Palette_Chosen(i)), id = id, focusable = false))
	}
	_, text := Palette_ParseQuery(s.palette.query)
	count := ""
	switch {
	case len(matches) == 0: count = fmt.tprintf("Nothing matches '%s'", text)
	case len(matches) > shown: count = fmt.tprintf("%d of %d shown: type more to narrow them", shown, len(matches))
	case: count = fmt.tprintf("%d %s", len(matches), len(matches) == 1 ? "match" : "matches")
	}

	// As tall as the rows, less in a short window (the search, categories and hints take about
	// eight rows), so the popup stays on screen
	listHeight := max(f32(shown) * rowHeight, rowHeight)
	if ctx.renderer != nil do listHeight = min(listHeight, max(f32(ctx.renderer.fb_size.y) - rowHeight * 8, rowHeight * 3), rowHeight * 14)
	paletteRevealHighlight(ctx, s, highlight, f32(highlight) * rowHeight, rowHeight, listHeight)
	list := skald.scroll(ctx, {0, listHeight}, skald.col(..rows[:], cross_align = .Stretch),
		id = skald.hash_id("palette-scroll"))

	return skald.dialog(ctx,
		open = true,
		on_dismiss = proc() -> Msg { return Palette_Closed{} },
		content = skald.col(
			search,
			skald.wrap_row(..categories[:], spacing = tk.buttonGap, line_spacing = tk.buttonGap),
			list,
			skald.row(
				uiText(th, .Muted, count),
				skald.flex(1, skald.spacer(0)),
				uiText(th, .Muted, "Enter runs, Esc closes"),
				spacing = tk.s,
			),
			spacing = th.spacing.sm,
			padding = tk.panelPadding,
			cross_align = .Stretch,
		),
		id = skald.hash_id("command-palette"),
		initial_focus = skald.hash_id("palette-search"),
		width = tk.dialogL,
	)
}

// The highlight and query the list was last scrolled for: it scrolls when either changes
@(private="file")
paletteRevealed: struct {
	highlight: int,
	query: u32,
	known: bool,
}

// Scrolls the list so the highlighted row is in view, when the highlight or the query changed
@(private="file")
paletteRevealHighlight :: proc(ctx: ^skald.Ctx(Msg), s: ^State, highlight: int, top, rowHeight, listHeight: f32) {
	query := hash.fnv32a(transmute([]u8)s.palette.query)
	if paletteRevealed.known && paletteRevealed.highlight == highlight && paletteRevealed.query == query do return
	scroll, drawn := &ctx.widgets.states[skald.hash_id("palette-scroll")]
	if !drawn do return
	paletteRevealed = {highlight, query, true}
	if top + rowHeight > scroll.scroll_y + listHeight {
		scroll.scroll_y = top + rowHeight - listHeight
	} else if top < scroll.scroll_y {
		scroll.scroll_y = top
	} else {
		return
	}
	skald.send(ctx, Msg(Frame_Requested{}))
}
