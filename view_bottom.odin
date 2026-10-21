package crossfire_editor

import "core:fmt"
import "gui:skald"

/*
Bottom panel: Console, Output, Animation (view_animation.odin), Mixer (view_mixer.odin) and Git
(view_git.odin) tabs.
Keyboard shortcuts are listed in Settings > Keyboard (Help > Keyboard Shortcuts opens it). The chevron collapses it to just its header;
clicking a tab while collapsed opens it again.
*/
bottomPanelView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	open := s.layout.bottomOpen

	labels := make([]string, len(BottomTab), context.temp_allocator)
	for tab in BottomTab do labels[tab] = fmt.tprintf("%v", tab)

	header := skald.row(
		skald.tooltip(ctx, skald.tabs(ctx, labels, int(s.bottomTab),
			proc(index: int) -> Msg { return Bottom_Tab_Changed(index) },
			id = skald.hash_id("bottom-tabs")), BOTTOM_TABS_TIP, id = skald.hash_id("bottom-tabs-tip")),
		skald.flex(1, skald.spacer(0)),
		panelButton(ctx, "clear-log", ICON_TRASH, "Clear", Action.Clear_Console,
			disabled = !clearable(s)),
		panelButton(ctx, "toggle-bottom", open ? ICON_CHEVRON_DOWN : ICON_CHEVRON_UP,
			open ? "Collapse panel (Ctrl+J)" : "Expand panel (Ctrl+J)", Action.Toggle_Bottom_Panel),
		spacing = th.spacing.xs,
		padding = th.spacing.xs,
		cross_align = .Center,
		bg = th.color.surface,
	)
	if !open do return header

	content: skald.View
	switch s.bottomTab {
	case .Console:   content = logView(ctx, s.console[:], "Console is empty.", "console-scroll")
	case .Output:    content = logView(ctx, s.output[:], "Build output appears here when you press Play.", "output-scroll")
	case .Animation: content = AnimationPanel(s, ctx)
	case .Mixer:     content = MixerPanel(s, ctx)
	case .Git:       content = GitPanel(s, ctx)
	case .Tiles:     content = TilesPanel(s, ctx)
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

// A scrolling list of log lines, colored by level
@(private="file")
logView :: proc(ctx: ^skald.Ctx(Msg), log: []LogLine, emptyText, scrollKey: string) -> skald.View {
	th := ctx.theme
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
		lines[i] = skald.text(fmt.tprintf("%s  %s", tag, line.text), color, th.font.size_sm)
	}
	return skald.scroll(ctx, {0, 0},
		skald.col(..lines, spacing = 2, padding = th.spacing.sm),
		id = skald.hash_id(scrollKey))
}

@(private="package")
placeholder :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text(text, th.color.fg_muted, th.font.size_sm),
		padding = th.spacing.md,
	)
}
