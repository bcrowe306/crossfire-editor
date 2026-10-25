package crossfire_editor

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "gui:skald"

/*
Bottom panel: the shown mode's tabs (editor_modes.odin's `bottomTabs`): the Scene mode's Console,
Output, Animation (view_animation.odin), Mixer (view_mixer.odin), Git (view_git.odin), Tiles
(view_tiles.odin), Timeline (view_timeline.odin), Live (view_live.odin), States, Particles
(view_particles.odin), Dialogue and Plugins; the Level mode's LDtk (level_mode.odin), Console and Output. The Console and Output are
the same lists in every mode. Keyboard shortcuts are listed in Settings > Keyboard (Help >
Keyboard Shortcuts opens it). The chevron collapses it to just its header; clicking a tab while
collapsed opens it again. Keys: the Scene mode's strip `bottom-tabs` (a tab's index is its
BottomTab), another mode's `<mode>-bottom-tabs` (`level-bottom-tabs`), scrolled by
`bottom-tabs-scroll` / `<mode>-bottom-tabs-scroll`.
*/
bottomPanelView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	layout := Mode_Layout(s)
	open := layout.bottomOpen
	tabList := EDITOR_MODES[s.mode].bottomTabs
	shown := Mode_BottomTab(s)
	active := 0
	labels := make([]string, len(tabList), context.temp_allocator)
	for tab, i in tabList {
		labels[i] = BottomTab_Label(tab)
		if tab == shown do active = i
	}
	prefix := s.mode == .Scene ? "" : fmt.tprintf("%s-", strings.to_lower(EDITOR_MODES[s.mode].name, context.temp_allocator))
	tabsKey := fmt.tprintf("%sbottom-tabs", prefix)
	scrollKey := fmt.tprintf("%sbottom-tabs-scroll", prefix)

	tabs := skald.tooltip(ctx, skald.tabs(ctx, labels, active,
		proc(index: int) -> Msg { return Bottom_Tab_Picked(index) },
		id = skald.hash_id(tabsKey)), s.mode == .Scene ? BOTTOM_TABS_TIP : LEVEL_BOTTOM_TABS_TIP, id = skald.hash_id(fmt.tprintf("%s-tip", tabsKey)))
	buttons := skald.row(
		panelButton(ctx, "clear-log", ICON_TRASH, "Clear", Action.Clear_Console,
			disabled = !clearable(s)),
		panelButton(ctx, "toggle-bottom", open ? ICON_CHEVRON_DOWN : ICON_CHEVRON_UP,
			actionTip(s, open ? "Collapse panel" : "Expand panel", .Toggle_Bottom_Panel), Action.Toggle_Bottom_Panel),
		spacing = th.spacing.xs,
		cross_align = .Center,
	)
	// More tabs than the panel is wide scroll sideways, like the center's: unclipped, the ones
	// past its edge took clicks meant for the inspector beside it (a dropdown's choice there
	// switched the tab)
	left, right := FittedSidebarWidths(layout)
	panelWidth := layout.workspace.x - left - right - DIVIDER * 2
	tabsWidth, tabsHeight := f32(200), f32(30)
	if ctx.renderer != nil {
		tabsWidth = max(panelWidth - skald.view_size(ctx.renderer, buttons).x - th.spacing.xs * 3, 60)
		tabsHeight = skald.view_size(ctx.renderer, tabs).y
	}
	hScroll_Reveal(ctx, scrollKey, skald.widget_make_sub_id(skald.hash_id(tabsKey), u64(active + 1)))
	header := skald.row(
		hScroll(ctx, scrollKey, tabs, tabsWidth, tabsHeight, thin = true),
		skald.flex(1, skald.spacer(0)),
		buttons,
		spacing = th.spacing.xs,
		padding = th.spacing.xs,
		cross_align = .Center,
		bg = th.color.surface,
	)
	if !open do return header

	content: skald.View
	switch shown {
	case .Console:   content = logView(ctx, s, false, "Console is empty.", "console-scroll")
	case .Output:    content = logView(ctx, s, true, "Build output appears here when you press Play.", "output-scroll")
	case .Animation: content = AnimationPanel(s, ctx)
	case .Mixer:     content = MixerPanel(s, ctx)
	case .Git:       content = GitPanel(s, ctx)
	case .Tiles:     content = TilesPanel(s, ctx)
	case .Timeline:  content = TimelinePanel(s, ctx)
	case .Live:      content = LivePanel(s, ctx)
	case .States:    content = StatesPanel(s, ctx)
	case .Particles: content = ParticlesPanel(s, ctx)
	case .Dialogue:  content = DialoguePanel(s, ctx)
	case .Plugins:   content = PluginsPanel(s, ctx)
	case .World, .Level, .Layers, .Entities, .Enums, .Tilesets, .Auto_Layer_Rules, .LDtk_Project:
		content = LevelMode_LDtkTab(s, ctx, shown)
	}

	return skald.col(
		header,
		skald.divider(ctx),
		skald.flex(1, content),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

@(private="file")
clearable :: proc(s: ^State) -> bool {
	#partial switch Mode_BottomTab(s) {
	case .Console: return len(LogList_Lines(&s.console)) > 0
	case .Output:  return len(LogList_Lines(&s.output)) > 0
	}
	return false
}

/*
A log tab (the Console, or the Output tab with `output`): a header of filters over its lines
(console.odin's `LogList`). Only the visible lines are built (`virtual_list`), so a full history
costs what a screenful does. The lines follow the newest one unless the list is paused
(`logFollow`). A right-click opens a line's menu (copy it, copy all shown, its category, clear:
context_menus.odin). Widgets: `<scrollKey>` (the list), `<scrollKey>-area` (the list or its
placeholder), `<scrollKey>-line-<i>` (a line by its index
in the kept lines), and the header's `<scrollKey>-search`, `-level-<Level>`, `-categories`,
`-follow`.
*/
@(private="file")
logView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, output: bool, emptyText, scrollKey: string) -> skald.View {
	th := ctx.theme
	list := logListOf(s, output)
	lines := LogList_Lines(list)
	shown := LogList_Shown(list)
	listId := skald.hash_id(scrollKey)
	rowHeight := logRowHeight(ctx)
	header := logHeader(ctx, list, output, scrollKey, len(shown))
	// The line under a right-click, from last frame's layout and scroll (below the lines, or none
	// shown: -1). The area is the whole tab under the header, the list or its placeholder
	areaId := skald.hash_id(fmt.tprintf("%s-area", scrollKey))
	if area := lastRect(ctx, areaId); ctx.input.mouse_pressed[.Right] && area.w > 0 {
		line := -1
		p := ctx.input.mouse_pos
		if st, ok := ctx.widgets.states[listId]; ok && len(shown) > 0 && st.last_rect.h > 0 && p.y >= st.last_rect.y && p.y < st.last_rect.y + st.last_rect.h {
			row := int((p.y - st.last_rect.y + st.scroll_y) / rowHeight)
			if row >= 0 && row < len(shown) do line = list.serial + shown[row]
		}
		rightPressOpens(ctx, area, Ctx_Log{output = output, line = line})
	}
	content: skald.View
	switch {
	case len(lines) == 0: content = placeholder(ctx, emptyText)
	case len(shown) == 0: content = placeholder(ctx, "No lines match the filters.")
	case:
		logFollow(ctx, list, output, listId, shown, rowHeight)
		rows := new(LogRows, context.temp_allocator)
		rows^ = {lines = lines, shown = shown, list = list, key = scrollKey, height = rowHeight, output = output, clip = lastRect(ctx, listId)}
		// Following: the last row revealed, for the first frame after the list was hidden (logFollow
		// keeps it there afterwards)
		content = skald.virtual_list(ctx, rows, len(shown), rowHeight, {0, 0}, logRow, logRowKey, id = listId,
			reveal_row = list.paused ? -1 : len(shown) - 1)
	}
	area := new(skald.View, context.temp_allocator)
	area^ = content
	return skald.col(
		header,
		skald.flex(1, skald.View_Zone{id = areaId, child = area}),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

// What a log tab's rows are built from (temp allocated; the lines are the state's)
@(private="file")
LogRows :: struct {
	lines: []LogLine,
	// Indexes into `lines` of the rows, in order
	shown: []int,
	list: ^LogList,
	key: string,
	height: f32,
	// The Output tab's (for a location's Go to Error)
	output: bool,
	// The list's rect last frame: a line is under the pointer only inside it
	clip: skald.Rect,
}

// A log row's height: one line of small text and a little room
@(private="file")
logRowHeight :: proc(ctx: ^skald.Ctx(Msg)) -> f32 {
	th := ctx.theme
	if ctx.renderer != nil do return math.ceil(skald.view_size(ctx.renderer, skald.text("Ag", th.color.fg, th.font.size_sm)).y) + 3
	return math.ceil(th.font.size_sm * 1.4) + 3
}

// A row's key for its widgets' state: the line's serial number, which stays with it
@(private="file")
logRowKey :: proc(rows: ^LogRows, i: int) -> u64 {
	return u64(rows.list.serial + rows.shown[i])
}

// One line: its level and category, muted, then its text in the level's color
@(private="file")
logRow :: proc(ctx: ^skald.Ctx(Msg), rows: ^LogRows, i: int) -> skald.View {
	th := ctx.theme
	index := rows.shown[i]
	line := rows.lines[index]
	color := th.color.fg
	tag := "INFO "
	switch line.level {
	case .Debug:   color, tag = th.color.fg_muted, "DEBUG"
	case .Info:
	case .Warning: color, tag = th.color.warning, "WARN "
	case .Error:   color, tag = th.color.danger, "ERROR"
	}
	// A line naming a source location is a link (error_locations.odin): the accent color and a
	// hand under the pointer, a click opens it
	body := skald.text(line.text, color, th.font.size_sm)
	if _, located := ErrorLocation_Parse(line.text); located {
		linkId := skald.hash_id(fmt.tprintf("%s-link-%d", rows.key, index))
		r := lastRect(ctx, linkId)
		p := ctx.input.mouse_pos
		c := rows.clip
		over := r.w > 0 && p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h &&
			p.x >= c.x && p.y >= c.y && p.x < c.x + c.w && p.y < c.y + c.h &&
			!skald.mouse_over_overlay(ctx) && ctx.widgets.modal_rect_prev.w <= 0
		if over {
			skald.cursor_request(ctx, .Pointer)
			if ctx.input.mouse_pressed[.Left] do skald.send(ctx, Msg(Log_Command{.Go_To_Error, rows.output, rows.list.serial + index}))
		}
		link := new(skald.View, context.temp_allocator)
		link^ = skald.col(
			skald.text(line.text, over ? th.color.primary : color, th.font.size_sm),
			// The underline: the text's width, under it
			skald.rect({0, 1}, over ? th.color.primary : skald.Color{}),
			cross_align = .Stretch,
		)
		body = skald.View_Zone{id = linkId, child = link}
	}
	text := new(skald.View, context.temp_allocator)
	text^ = skald.row(
		skald.text(fmt.tprintf("%s  %s", tag, LogList_CategoryName(rows.list, line)), th.color.fg_muted, th.font.size_sm),
		body,
		spacing = th.spacing.sm,
		padding = th.spacing.xs,
		height = rows.height,
		cross_align = .Center,
	)
	return skald.View_Zone{id = skald.hash_id(fmt.tprintf("%s-line-%d", rows.key, index)), child = text}
}

/*
The header over a log tab's lines: a search box, a toggle per level (with how many lines it has),
the category menu's button and the Follow toggle. A `wrap_row`, so it wraps in a narrow panel.
*/
@(private="file")
logHeader :: proc(ctx: ^skald.Ctx(Msg), list: ^LogList, output: bool, key: string, shownCount: int) -> skald.View {
	th := ctx.theme
	items := make([dynamic]skald.View, context.temp_allocator)
	append(&items, skald.text_input(ctx, list.search, output,
		proc(output: bool, text: string) -> Msg { return Log_Search_Changed{output, text} },
		id = skald.hash_id(fmt.tprintf("%s-search", key)),
		placeholder = "Search", width = 150, font_size = th.font.size_sm,
		clear_button = true, escape_clears = true))
	LABELS := [LogLevel]string{.Debug = "Debug", .Info = "Info", .Warning = "Warnings", .Error = "Errors"}
	for level in ([]LogLevel{.Error, .Warning, .Info, .Debug}) {
		hidden := level in list.hiddenLevels
		color := th.color.fg
		#partial switch level {
		case .Warning: color = th.color.warning
		case .Error:   color = th.color.danger
		case .Debug:   color = th.color.fg_muted
		}
		buttonKey := fmt.tprintf("%s-level-%v", key, level)
		button := skald.button(ctx, fmt.tprintf("%s %d", LABELS[level], list.counts[level]), Msg(Log_Level_Toggled{output, level}),
			id = skald.hash_id(buttonKey),
			bg = hidden ? th.color.surface : th.color.elevated, fg = hidden ? th.color.fg_muted : color,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_sm)
		append(&items, skald.tooltip(ctx, button, fmt.tprintf("%s %s lines", hidden ? "Show" : "Hide", strings.to_lower(LABELS[level], context.temp_allocator)),
			id = skald.hash_id(fmt.tprintf("%s-tip", buttonKey))))
	}
	hiddenCategories := 0
	for c in list.categories do if c.hidden do hiddenCategories += 1
	categoriesKey := fmt.tprintf("%s-categories", key)
	categoriesId := skald.hash_id(categoriesKey)
	r := lastRect(ctx, categoriesId)
	label := hiddenCategories == 0 ? "All categories" : fmt.tprintf("%d of %d categories", len(list.categories) - hiddenCategories, len(list.categories))
	categories := skald.button(ctx, fmt.tprintf("%s %s", label, ICON_CHEVRON_DOWN),
		Msg(Context_Menu_Opened{at = {r.x, r.y + r.h}, target = Ctx_Log_Categories{output}}),
		id = categoriesId, bg = th.color.surface, fg = hiddenCategories == 0 ? th.color.fg : th.color.primary,
		padding = {th.spacing.sm, 2}, font_size = th.font.size_sm)
	append(&items, skald.tooltip(ctx, categories, "Choose the categories shown: engine, SDL, the game's own, build, editor...",
		id = skald.hash_id(fmt.tprintf("%s-tip", categoriesKey))))
	following := !list.paused
	followKey := fmt.tprintf("%s-follow", key)
	follow := skald.button(ctx, ICON_ARROW_DOWN, Msg(Log_Follow_Toggled{output}),
		id = skald.hash_id(followKey),
		bg = following ? th.color.primary : th.color.surface, fg = following ? th.color.on_primary : th.color.fg_muted,
		width = math.round(th.font.size_md * 1.9), padding = {0, 3}, font_size = th.font.size_sm)
	append(&items, skald.tooltip(ctx, follow, following ? "Following the newest line: scroll up to stop" : "Follow the newest line (scrolling to the end does too)",
		id = skald.hash_id(fmt.tprintf("%s-tip", followKey))))
	total := len(LogList_Lines(list))
	if shownCount != total do append(&items, skald.text(fmt.tprintf("%d of %d lines", shownCount, total), th.color.fg_muted, th.font.size_sm))
	return skald.wrap_row(..items[:], spacing = th.spacing.xs, line_spacing = th.spacing.xs, padding = th.spacing.xs)
}

// Per log list (by its widget id), what `logFollow` saw last frame: the scroll offset, and the
// top row's line (serial number) and how far into it the view was
@(private="file")
LogScrollSeen :: struct {
	scroll: f32,
	topSerial: int,
	topOffset: f32,
}
@(private="file")
logScrollSeen: map[skald.Widget_ID]LogScrollSeen

/*
Keeps a log list on its newest line while it follows, and notices the user's scrolling: up while
following pauses it, back to the end resumes it (`Log_Follow_Set`). While paused, the line at the
top stays there as older lines are dropped or the filters change. Works on the list's scroll
state before `virtual_list` builds from it (Skald clamps the offset there).
*/
@(private="file")
logFollow :: proc(ctx: ^skald.Ctx(Msg), list: ^LogList, output: bool, id: skald.Widget_ID, shown: []int, rowHeight: f32) {
	st, ok := &ctx.widgets.states[id]
	// Not drawn last frame (the tab or the list was hidden): Skald starts its state afresh, so
	// there's nothing to compare with (the list's reveal_row takes it to the end when following)
	if !ok || st.last_rect.h <= 0 || st.last_frame + 1 < ctx.widgets.frame {
		delete_key(&logScrollSeen, id)
		return
	}
	viewHeight := st.last_rect.h
	lastEnd := max(st.content_h - viewHeight, 0)
	seen, known := logScrollSeen[id]
	moved := known && abs(st.scroll_y - seen.scroll) > 0.5
	atEnd := st.scroll_y >= lastEnd - 1
	following := !list.paused
	if following && moved && !atEnd {
		skald.send(ctx, Msg(Log_Follow_Set{output, false}))
		following = false
	} else if !following && moved && atEnd {
		skald.send(ctx, Msg(Log_Follow_Set{output, true}))
		following = true
	}
	if following {
		st.scroll_y = max(f32(len(shown)) * rowHeight - viewHeight, 0)
	} else if known && !moved {
		// The top line where it was: find its row now (rows are in serial order)
		index := seen.topSerial - list.serial
		row, found := slice.binary_search(shown, index)
		if !found && row >= len(shown) do row = len(shown) - 1
		st.scroll_y = max(f32(max(row, 0)) * rowHeight + (found ? seen.topOffset : 0), 0)
	}
	top := clamp(int(st.scroll_y / rowHeight), 0, max(len(shown) - 1, 0))
	logScrollSeen[id] = {
		scroll = st.scroll_y,
		topSerial = len(shown) > 0 ? list.serial + shown[top] : list.serial,
		topOffset = st.scroll_y - f32(top) * rowHeight,
	}
}

@(private="package")
placeholder :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text(text, th.color.fg_muted, th.font.size_sm),
		padding = th.spacing.md,
	)
}
