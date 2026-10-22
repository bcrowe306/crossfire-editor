package crossfire_editor

import "core:fmt"
import "gui:skald"

/*
Bottom panel: Console, Output, Animation (view_animation.odin), Mixer (view_mixer.odin), Git
(view_git.odin), Tiles (view_tiles.odin) Timeline (view_timeline.odin) and Live (view_live.odin) tabs.
Keyboard shortcuts are listed in Settings > Keyboard (Help > Keyboard Shortcuts opens it). The chevron collapses it to just its header;
clicking a tab while collapsed opens it again.
*/
bottomPanelView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	open := s.layout.bottomOpen

	labels := make([]string, len(BottomTab), context.temp_allocator)
	for tab in BottomTab do labels[tab] = fmt.tprintf("%v", tab)

	tabs := skald.tooltip(ctx, skald.tabs(ctx, labels, int(s.bottomTab),
		proc(index: int) -> Msg { return Bottom_Tab_Changed(index) },
		id = skald.hash_id("bottom-tabs")), BOTTOM_TABS_TIP, id = skald.hash_id("bottom-tabs-tip"))
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
	left, right := FittedSidebarWidths(&s.layout)
	panelWidth := s.layout.workspace.x - left - right - DIVIDER * 2
	tabsWidth, tabsHeight := f32(200), f32(30)
	if ctx.renderer != nil {
		tabsWidth = max(panelWidth - skald.view_size(ctx.renderer, buttons).x - th.spacing.xs * 3, 60)
		tabsHeight = skald.view_size(ctx.renderer, tabs).y
	}
	hScroll_Reveal(ctx, "bottom-tabs-scroll", skald.widget_make_sub_id(skald.hash_id("bottom-tabs"), u64(int(s.bottomTab) + 1)))
	header := skald.row(
		hScroll(ctx, "bottom-tabs-scroll", tabs, tabsWidth, tabsHeight, thin = true),
		skald.flex(1, skald.spacer(0)),
		buttons,
		spacing = th.spacing.xs,
		padding = th.spacing.xs,
		cross_align = .Center,
		bg = th.color.surface,
	)
	if !open do return header

	content: skald.View
	switch s.bottomTab {
	case .Console:   content = logView(ctx, s.console[:], "Console is empty.", "console-scroll", output = false)
	case .Output:    content = logView(ctx, s.output[:], "Build output appears here when you press Play.", "output-scroll", output = true)
	case .Animation: content = AnimationPanel(s, ctx)
	case .Mixer:     content = MixerPanel(s, ctx)
	case .Git:       content = GitPanel(s, ctx)
	case .Tiles:     content = TilesPanel(s, ctx)
	case .Timeline:  content = TimelinePanel(s, ctx)
	case .Live:      content = LivePanel(s, ctx)
	case .States:    content = StatesPanel(s, ctx)
	case .Dialogue:  content = DialoguePanel(s, ctx)
	case .Plugins:   content = PluginsPanel(s, ctx)
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
	#partial switch s.bottomTab {
	case .Console: return len(s.console) > 0
	case .Output:  return len(s.output) > 0
	}
	return false
}

// A scrolling list of log lines, colored by level; a right-click opens a line's menu (copy it,
// copy all, clear: context_menus.odin). Line widgets: `<scrollKey>-line-<i>`
@(private="file")
logView :: proc(ctx: ^skald.Ctx(Msg), log: []LogLine, emptyText, scrollKey: string, output: bool) -> skald.View {
	th := ctx.theme
	scrollId := skald.hash_id(scrollKey)
	// The line under a right-click, from last frame's layout (below the lines: -1)
	if area := lastRect(ctx, scrollId); ctx.input.mouse_pressed[.Right] && area.w > 0 {
		line := -1
		p := ctx.input.mouse_pos
		for i in 0..<len(log) {
			r := lastRect(ctx, skald.hash_id(fmt.tprintf("%s-line-%d", scrollKey, i)))
			if r.w > 0 && p.y >= r.y && p.y < r.y + r.h && p.y >= area.y && p.y < area.y + area.h {
				line = i
				break
			}
		}
		rightPressOpens(ctx, area, Ctx_Log{output = output, line = line})
	}
	if len(log) == 0 do return placeholder(ctx, emptyText)

	lines := make([]skald.View, len(log), context.temp_allocator)
	for line, i in log {
		color := th.color.fg
		tag := "INFO "
		switch line.level {
		case .Info:
		case .Warning: color, tag = th.color.warning, "WARN "
		case .Error:   color, tag = th.color.danger, "ERROR"
		}
		text := new(skald.View, context.temp_allocator)
		text^ = skald.text(fmt.tprintf("%s  %s", tag, line.text), color, th.font.size_sm)
		lines[i] = skald.View_Zone{id = skald.hash_id(fmt.tprintf("%s-line-%d", scrollKey, i)), child = text}
	}
	return skald.scroll(ctx, {0, 0},
		skald.col(..lines, spacing = 2, padding = th.spacing.sm),
		id = scrollId)
}

@(private="package")
placeholder :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text(text, th.color.fg_muted, th.font.size_sm),
		padding = th.spacing.md,
	)
}
