package editor

import "core:fmt"
import "gui:skald"

/*
Bottom panel: Console, Output and Animation tabs. The chevron collapses it to just its header;
clicking a tab while collapsed opens it again.
*/
bottomPanelView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	open := s.layout.bottomOpen

	labels := make([]string, len(BottomTab), context.temp_allocator)
	for tab in BottomTab do labels[tab] = fmt.tprintf("%v", tab)

	header := skald.row(
		skald.tabs(ctx, labels, int(s.bottomTab),
			proc(index: int) -> Msg { return Bottom_Tab_Changed(index) },
			id = skald.hash_id("bottom-tabs")),
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
	case .Animation: content = animationView(s, ctx)
	case .Keys:      content = keysView(s, ctx)
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

// Every keyboard shortcut, from the keymap
@(private="file")
keysView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.text("Change these in Edit > Settings > Keyboard.", th.color.fg_muted, th.font.size_sm))
	for chords, action in s.settings.keymap {
		if chords == {} do continue
		label := ACTION_LABELS[action]
		append(&rows, skald.row(
			skald.col(skald.text(Keymap_FormatChords(chords), th.color.fg, th.font.size_sm), width = 160),
			skald.text(ACTION_KEY_RULES[action].viewportOnly ? fmt.tprintf("%s (mouse over viewport)", label) : label,
				th.color.fg_muted, th.font.size_sm),
			spacing = th.spacing.sm,
		))
	}
	append(&rows, skald.text("Viewport mouse: wheel zooms, middle/right drag or Space+drag pans, Shift constrains drags.",
		th.color.fg_muted, th.font.size_sm))
	return skald.scroll(ctx, {0, 0},
		skald.col(..rows[:], spacing = 2, padding = th.spacing.sm),
		id = skald.hash_id("keys-scroll"))
}

@(private="file")
animationView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) && scene.nodes[s.selectedNode].kind == .AnimatedSprite {
		return placeholder(ctx, fmt.tprintf("Animation editor for '%s' is not implemented yet.", scene.nodes[s.selectedNode].name))
	}
	return placeholder(ctx, "Select an AnimatedSprite node to edit its animations.")
}

@(private="file")
placeholder :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
	th := ctx.theme
	return skald.col(
		skald.text(text, th.color.fg_muted, th.font.size_sm),
		padding = th.spacing.md,
	)
}
