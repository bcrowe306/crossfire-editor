package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"

/*
The bottom tabs' shared layout for a tab that manages a list (the user's of 2026-10-25: the Level
mode's World, Level, Layers, Entities, Enums, Tilesets and Auto-layer Rules tabs, and the Project
tab without a list):

	+----------------------------------------------------------------+
	| World | Level | Layers | Entities | ...      (the tab strip)    |
	+----------------------------------------------------------------+
	| [+] [copy] [trash] [up] [down]   2 of 5 layers  (toolbar row)  |
	+----------------+-----------------------------------------------+
	| item           | the selected item's settings: the inspector's |
	| item           | rows (`inspectorLabelled`, stacked when the   |
	| item           | column is narrow)                             |
	+----------------+-----------------------------------------------+

- **The toolbar row:** the panel buttons (`panelToolButton`) of the list's actions and the tab's
  own, then a text (counts, a hint, the selected item's name); a `wrap_row`, so a narrow panel wraps
  it.
- **The sidebar:** the list's rows, the scene tree's rows (`rowList`, `Tree_RowView`: the same
  height, font, icons, indent and selection colors as the Level mode's sidebars and the Scene
  mode's trees); a click picks an item (its `pick` message), Up / Down the next one. A divider
  resizes it, and the width is kept per tab (`List_Tab_Resized`, `LevelMode.listWidths`).
- **The content:** the rows the tab built, in a scroll, padded as the inspector's.
- **Narrow panels** (under `LIST_TAB_COMPACT_WIDTH`: a tiled window's bottom panel is about 200 px):
  no sidebar; the list is a dropdown over the content (`choiceKey`), as the Particles tab's
  categories are.

`ListTab_Layout` works out the widths first (the content's rows need their control width before
they're built: `LDtkTabCtx`), `listTabView` builds it. Keys: the list `<key>`, its rows
`<key>-<i>`, its scroll `<key>-scroll`, the divider `<key>-split`, the dropdown `choiceKey`, the
content's scroll `contentKey`.
*/

// The sidebar's width the first time a tab shows, its smallest, and the content's smallest
LIST_TAB_WIDTH :: 180
LIST_TAB_MIN_WIDTH :: 120
LIST_TAB_MIN_CONTENT :: 240
// Under this panel width the sidebar is a dropdown over the content
LIST_TAB_COMPACT_WIDTH :: 480
// The widest a content row's control gets
LIST_TAB_MAX_CONTROL :: 260

// How a list tab lays out at a panel width (`ListTab_Layout`)
ListTabLayout :: struct {
	// No sidebar: the list is a dropdown over the content
	compact: bool,
	// The sidebar's width (0: none), the content column's (the panel's rest)
	sidebar, content: f32,
	// Inside the content's padding and scrollbar: what text and rows of buttons may take
	rowWidth: f32,
	// A row's control's width, and whether rows put their labels over their controls
	controlWidth: f32,
	stacked: bool,
}

/*
How a list tab lays out in a panel: the sidebar (its stored width, kept between its minimum and
what leaves the content its minimum) or, narrower than LIST_TAB_COMPACT_WIDTH, none; the content's
rows as the inspector lays them out at that width (`Inspector_Layout`: labels beside their
controls, or over them when a number field wouldn't fit).

Inputs:
- th: The theme
- panel: The bottom panel's width
- hasList: The tab has a list (the Project tab hasn't)
- stored: The sidebar's width the user left (0: LIST_TAB_WIDTH)

Returns:
- The layout
*/
ListTab_Layout :: proc(th: ^skald.Theme, panel: f32, hasList: bool, stored: f32) -> ListTabLayout {
	l: ListTabLayout
	l.compact = !hasList || panel < LIST_TAB_COMPACT_WIDTH
	if !l.compact {
		width := stored > 0 ? stored : LIST_TAB_WIDTH
		l.sidebar = clamp(width, LIST_TAB_MIN_WIDTH, max(panel - DIVIDER - LIST_TAB_MIN_CONTENT, LIST_TAB_MIN_WIDTH))
	}
	l.content = max(panel - (l.sidebar > 0 ? l.sidebar + DIVIDER : 0), 120)
	l.rowWidth = max(l.content - th.spacing.md * 2 - INSPECTOR_SCROLLBAR_WIDTH, 80)
	l.controlWidth, l.stacked = Inspector_Layout(th, l.content)
	l.controlWidth = min(l.controlWidth, LIST_TAB_MAX_CONTROL)
	return l
}

// An item of a list tab's sidebar: its row (the scene tree's look) and what a click sends
ListTabItem :: struct {
	row: ColoredTreeRow,
	pick: Msg,
}

// What a list tab shows besides its rows (filled while the tab is built; temp)
ListTab :: struct {
	// The list's widget key (its rows `<key>-<i>`)
	key: string,
	// Whether the tab has a list (the sidebar or the dropdown)
	hasList: bool,
	items: [dynamic]ListTabItem,
	// The toolbar row's buttons, and its text
	tools: [dynamic]skald.View,
	text: string,
	// Shown in the sidebar when the list is empty
	empty: string,
	// The narrow panel's dropdown's widget key, and the content's scroll's
	choiceKey, contentKey: string,
}

// A new list tab's parts (temp)
ListTab_Make :: proc(key, choiceKey, contentKey: string, hasList: bool) -> ListTab {
	t := ListTab{key = key, hasList = hasList, choiceKey = choiceKey, contentKey = contentKey}
	t.items.allocator = context.temp_allocator
	t.tools.allocator = context.temp_allocator
	return t
}

// A list tab's divider dragged: the sidebar's new width, kept for the tab shown
List_Tab_Resized :: distinct f32

/*
A list tab: the toolbar row, then the sidebar beside the content (or, compact, the dropdown over
it). `rows` are the content's rows, built for `l`'s widths.

Inputs:
- s: The state (the rows' height)
- t: The tab's list, tools and text
- l: Its layout (`ListTab_Layout`)
- rows: The content's rows
- panel: The bottom panel's width (the toolbar row wraps to it)
*/
listTabView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, t: ^ListTab, l: ListTabLayout, rows: []skald.View, panel: f32) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	// The toolbar row: the tab's buttons, then its text
	tools := make([dynamic]skald.View, context.temp_allocator)
	append(&tools, ..t.tools[:])
	if t.text != "" {
		// Beside the buttons while there's room (a wrapped text takes its whole width: a line of its own)
		text := uiText(th, .Muted, t.text)
		if ctx.renderer != nil && skald.view_size(ctx.renderer, text).x > panel - th.spacing.sm * 2 {
			text = uiText(th, .Muted, t.text, max_width = max(panel - th.spacing.sm * 2, tk.fieldXS))
		}
		append(&tools, text)
	}
	// One line, centered, while it fits; else wrapped (a narrow panel)
	line := skald.row(..tools[:], spacing = th.spacing.xs, cross_align = .Center)
	if ctx.renderer != nil && skald.view_size(ctx.renderer, line).x > panel - th.spacing.xs * 2 {
		line = skald.wrap_row(..tools[:], spacing = th.spacing.xs, line_spacing = th.spacing.xs, width = max(panel - th.spacing.xs * 2, tk.fieldXS))
	}
	toolbar := skald.col(line, padding = th.spacing.xs, bg = th.color.surface, cross_align = .Stretch)

	// The content: the dropdown of a narrow panel, then the rows, padded as the inspector's
	content := make([dynamic]skald.View, context.temp_allocator)
	if t.hasList && l.compact && len(t.items) > 0 do append(&content, listTabChoice(ctx, t, l))
	append(&content, ..rows)
	Scroll_RevealClicked(ctx, t.contentKey)
	body := skald.scroll(ctx, {0, 0}, skald.col(..content[:], spacing = th.spacing.sm, padding = th.spacing.md), id = skald.hash_id(t.contentKey))
	if t.hasList && !l.compact {
		body = skald.split(ctx,
			first = listTabSidebar(ctx, s, t),
			second = body,
			first_size = l.sidebar,
			on_resize = proc(v: f32) -> Msg { return List_Tab_Resized(v) },
			id = skald.hash_id(fmt.tprintf("%s-split", t.key)),
			min_first = LIST_TAB_MIN_WIDTH,
			min_second = LIST_TAB_MIN_CONTENT,
		)
	}
	return skald.col(toolbar, skald.divider(ctx), skald.flex(1, body), cross_align = .Stretch)
}

// The sidebar: the items as the scene tree's rows
@(private="file")
listTabSidebar :: proc(ctx: ^skald.Ctx(Msg), s: ^State, t: ^ListTab) -> skald.View {
	th := ctx.theme
	if len(t.items) == 0 {
		return skald.col(uiText(th, .Muted, t.empty, max_width = LIST_TAB_WIDTH - th.spacing.sm * 2), padding = th.spacing.sm, bg = th.color.bg)
	}
	rows := make([]ListRow, len(t.items), context.temp_allocator)
	tree := make([]ColoredTreeRow, len(t.items), context.temp_allocator)
	for item, i in t.items {
		rows[i] = {row = item.row, key = fmt.tprintf("%s-%d", t.key, i), pick = item.pick}
		tree[i] = item.row
	}
	scrollKey := fmt.tprintf("%s-scroll", t.key)
	Tree_RevealSelected(ctx, tree, t.key, scrollKey, s.settings.rowHeight)
	list, _ := rowList(ctx, t.key, rows, s.settings.rowHeight)
	return skald.col(skald.flex(1, skald.scroll(ctx, {0, 0}, list, id = skald.hash_id(scrollKey), reveal_focus = false)), cross_align = .Stretch, bg = th.color.bg)
}

// A narrow panel's dropdown of the items (their picks: the frame's, as the rows' are)
@(private="file")
listTabChoice :: proc(ctx: ^skald.Ctx(Msg), t: ^ListTab, l: ListTabLayout) -> skald.View {
	labels := make([]string, len(t.items), context.temp_allocator)
	values := make([]string, len(t.items), context.temp_allocator)
	picks := make([]Msg, len(t.items), context.temp_allocator)
	shown := ""
	for item, i in t.items {
		labels[i] = strings.repeat("  ", item.row.depth, context.temp_allocator)
		labels[i] = fmt.tprintf("%s%s", labels[i], item.row.label)
		values[i] = fmt.tprint(i)
		picks[i] = item.pick
		if item.row.selected && shown == "" do shown = values[i]
	}
	Picks :: struct { picks: []Msg }
	return labeledSelect(ctx, shown, labels, values, Picks{picks}, proc(p: Picks, v: string) -> Msg {
		i, _ := tabParseInt(v)
		if i < 0 || i >= len(p.picks) || p.picks[i] == nil do return Msg(Frame_Requested{})
		return p.picks[i]
	}, id = skald.hash_id(t.choiceKey), width = min(l.rowWidth, LIST_TAB_MAX_CONTROL))
}
