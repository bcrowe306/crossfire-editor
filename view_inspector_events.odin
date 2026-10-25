package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The inspector's Events section and the Listen... dialog (node_listeners.odin): the node's events
(the engine's, for the kind it's built as), each with the scripts listening to it (× removes
one) and Listen..., which asks which script of the scene listens. Collapsed until opened, unless
the node has listeners.

Widget keys: `inspector-events-toggle`, `inspector-event-listen-<event>` (a script's:
`inspector-event-listen-script.<name>`), `inspector-global-listen-<Global>-<event>`,
`inspector-new-event`, `inspector-global-new-event-<Global>`, `inspector-listener-remove-<i>`;
the New Event dialog's `new-event-name`, `new-event-description`, `new-event-kind`,
`new-event-create`, `new-event-cancel`; the dialog's `listener-dialog`, `listener-target-<i>` (the
scene's scripted nodes in order), `listener-cancel`.
*/
@(private="package")
eventsSection :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, controlWidth: f32) -> []skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	own := e.SceneNodeKind_Events(NodeDef_BuiltKind(&s.project, node))
	script := NodeDef_Script(&s.project, node)
	scriptEvents := Script_Events(s, script)
	// Its more scripts and its node type publish events too (node_scripts_edit.odin)
	others := make([dynamic]string, context.temp_allocator)
	if node.customKind != "" do append(&others, node.customKind)
	for extra in node.moreScripts do append(&others, extra.name)
	otherCount := 0
	for name in others do otherCount += len(Script_Events(s, name))
	open := s.inspectorEventsOpen || len(node.listeners) > 0
	small :: proc(ctx: ^skald.Ctx(Msg), label, key: string, msg: Msg) -> skald.View {
		tk := uiTokens(ctx)
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg,
			padding = {tk.s, tk.hair}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	muted :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32) -> skald.View {
		return uiText(ctx.theme, .Muted, text, max_width = width)
	}
	// The toggle beside the title, not at the row's right end: when the inspector's content is
	// wider than a narrow (tiled) inspector, the right end is under the scrollbar strip or past
	// the window's edge, and a click there scrolled instead (lost clicks on Show / Hide)
	append(&rows, skald.row(
		uiText(th, .Value, fmt.tprintf("%s  Events (%d)", ICON_LINK, len(own) + len(scriptEvents) + otherCount)),
		len(node.listeners) > 0 ? skald.View(skald.View_Spacer{size = 0}) : small(ctx, open ? "Hide" : "Show", "inspector-events-toggle", Msg(Inspector_Events_Toggled{})),
		skald.flex(1, skald.spacer(0)),
		spacing = th.spacing.sm,
		cross_align = .Center,
	))
	if !open do return rows[:]
	width := inspectorRowWidth(controlWidth)
	shown := make([dynamic]int, context.temp_allocator)
	// One event: its name (the description on hover), Listen..., its listeners
	// The name drags into code (a subscription, its subject: code_drops.odin): key
	// inspector-event-drag-<...> beside Listen...'s inspector-event-listen-<...>
	event :: proc(ctx: ^skald.Ctx(Msg), s: ^State, rows: ^[dynamic]skald.View, shown: ^[dynamic]int, node: ^NodeDef, ev: e.NodeEventInfo, global, label, key: string, listen: Msg, width: f32, script := "") {
		tk := uiTokens(ctx)
		th := ctx.theme
		name := tipLabel(ctx, Event_ShortName(ev.name), uiText(th, .Label, label, max_width = width - tk.fieldXS), ev.description)
		if global == "" && s.codeTab > 0 {
			dragKey, _ := strings.replace(key, "inspector-event-listen-", "inspector-event-drag-", 1, context.temp_allocator)
			name = CodeDrag_Zone(ctx, s, name, dragKey, DropSource{kind = .Event, name = ev.name, node = s.selectedNode, index = -1, script = script, detail = ev.dataHint})
		}
		append(rows, skald.row(
			name,
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "Listen...", listen, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg,
				padding = {tk.s, tk.hair}, font_size = th.font.size_xs, radius = th.radius.sm, disabled = listen == nil),
			cross_align = .Center,
		))
		for l, i in node.listeners do if l.event == ev.name && l.global == global {
			append(shown, i)
			append(rows, listenerRow(ctx, s, l, i, width))
		}
	}
	for ev in own {
		event(ctx, s, &rows, &shown, node, ev, "", ev.name, fmt.tprintf("inspector-event-listen-%s", ev.name), Msg(Listener_Dialog_Opened{s.selectedNode, ev.name}), width)
	}
	// Its script's own events (once built), and a new one
	if script != "" {
		append(&rows, skald.row(
			skald.text(fmt.tprintf("%s  %s", ICON_CODE, script), th.color.fg, th.font.size_xs),
			skald.flex(1, skald.spacer(0)),
			small(ctx, "New Event...", "inspector-new-event", Msg(New_Event_Opened(script))),
			cross_align = .Center,
		))
		if ScriptCatalog_Find(&s.scripts, script) == nil do append(&rows, muted(ctx, fmt.tprintf("Build the scripts%s to see %s's events.", keyParen(s, .Build_Scripts), script), width))
		for ev in scriptEvents {
			event(ctx, s, &rows, &shown, node, ev, "", Event_ShortName(ev.name), fmt.tprintf("inspector-event-listen-%s", ev.name), Msg(Listener_Dialog_Opened{s.selectedNode, ev.name}), width, script)
		}
	}
	// Its node type's and more scripts' events ("script.x" too: the game looks in each)
	for name in others {
		append(&rows, skald.row(
			skald.text(fmt.tprintf("%s  %s", ICON_CODE, name), th.color.fg, th.font.size_xs),
			skald.flex(1, skald.spacer(0)),
			small(ctx, "New Event...", fmt.tprintf("inspector-new-event-%s", name), Msg(New_Event_Opened(name))),
			cross_align = .Center,
		))
		for ev in Script_Events(s, name) {
			event(ctx, s, &rows, &shown, node, ev, "", Event_ShortName(ev.name), fmt.tprintf("inspector-event-listen-%s-%s", name, ev.name), Msg(Listener_Dialog_Opened{s.selectedNode, ev.name}), width, name)
		}
	}
	// The globals' events: this node's script listens (stored on this node)
	if len(s.project.globals) > 0 {
		append(&rows, uiSection(th, uiTokens(ctx), "Globals"))
		if node.script == "" do append(&rows, muted(ctx, "Give this node a script to listen to the globals' events.", width))
		for g in s.project.globals {
			append(&rows, skald.row(
				uiText(th, .Muted, fmt.tprintf("%s  %s", ICON_GLOBE, g.script)),
				skald.flex(1, skald.spacer(0)),
				small(ctx, "+ Event", fmt.tprintf("inspector-global-new-event-%s", g.script), Msg(New_Event_Opened(g.script))),
				cross_align = .Center,
			))
			for ev in Script_Events(s, g.script) {
				listen := node.script != "" ? Msg(Global_Listen_Requested{s.selectedNode, g.script, ev.name}) : nil
				event(ctx, s, &rows, &shown, node, ev, g.script, fmt.tprintf("  %s", Event_ShortName(ev.name)), fmt.tprintf("inspector-global-listen-%s-%s", g.script, ev.name), listen, width)
			}
		}
	}
	// Listeners whose event isn't there: for a script's or a global's, only known after a build
	for l, i in node.listeners {
		listed := false
		for j in shown do if j == i do listed = true
		if listed do continue
		scriptOnes := l.global != "" || strings.has_prefix(l.event, e.SCRIPT_EVENT_PREFIX)
		if scriptOnes && s.scripts.status != .Ready do continue
		append(&rows, skald.row(
			skald.flex(1, uiText(th, .Muted, fmt.tprintf("%s%s (no such event) → %s  %s", l.global != "" ? fmt.tprintf("%s.", l.global) : "", l.event, l.target, l.handler), max_width = width - tk.panelButtonWidth, color = th.color.warning)),
			small(ctx, "×", fmt.tprintf("inspector-listener-remove-%d", i), Msg(Listener_Removed{s.selectedNode, i})),
			cross_align = .Center,
		))
	}
	return rows[:]
}

// A listener of the selected node, with × to remove it
@(private="file")
listenerRow :: proc(ctx: ^skald.Ctx(Msg), s: ^State, l: e.NodeListenerData, index: int, width: f32) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	return skald.row(
		skald.flex(1, skald.text(fmt.tprintf("    → %s  %s", l.target, l.handler), th.color.fg, th.font.size_xs, max_width = width - tk.panelButtonWidth)),
		skald.button(ctx, "×", Msg(Listener_Removed{s.selectedNode, index}), id = skald.hash_id(fmt.tprintf("inspector-listener-remove-%d", index)),
			bg = th.color.surface, fg = th.color.fg, padding = {tk.s, tk.hair}, font_size = th.font.size_xs, radius = th.radius.sm),
		cross_align = .Center,
	)
}

// The New Event dialog: a name, what it means and its data, written into the script's struct
newEventDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	if !s.newEvent.open do return closedDialog(ctx, "new-event-dialog")
	th := ctx.theme
	d := &s.newEvent
	problem := NewEvent_Problem(s)
	kinds := make([]string, len(EventDataKind), context.temp_allocator)
	for k, i in EventDataKind do kinds[i] = EVENT_DATA_LABELS[k]
	field :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
		tk := uiTokens(ctx)
		return skald.row(skald.col(uiText(ctx.theme, .Value, label), width = tk.fieldXS), skald.flex(1, control), spacing = ctx.theme.spacing.sm, cross_align = .Center)
	}
	return skald.dialog(ctx,
		open = true,
		on_dismiss = proc() -> Msg { return New_Event_Cancelled{} },
		on_confirm = dialogConfirm(problem == "", proc() -> Msg { return New_Event_Created{} }),
		content = skald.col(
			uiText(th, .Title, fmt.tprintf("New Event on %s", d.script)),
			field(ctx, "Name", skald.text_input(ctx, d.name, proc(v: string) -> Msg { return New_Event_Name_Changed(v) },
				id = skald.hash_id("new-event-name"), placeholder = "onCoinCollected")),
			field(ctx, "What it means", skald.text_input(ctx, d.description, proc(v: string) -> Msg { return New_Event_Description_Changed(v) },
				id = skald.hash_id("new-event-description"), placeholder = "The hero picked up a coin")),
			field(ctx, "Data", skald.select(ctx, EVENT_DATA_LABELS[d.kind], kinds,
				proc(v: string) -> Msg {
					for label, k in EVENT_DATA_LABELS do if label == v do return New_Event_Kind_Changed(k)
					return New_Event_Kind_Changed(.None)
				}, id = skald.hash_id("new-event-kind"), width = tk.fieldL)),
			skald.text(problem != "" ? problem : fmt.tprintf("Adds %s to %s's struct, with how to fire it. Saved and built, it's listed here to listen to.", d.name, d.script),
				problem != "" && d.name != "" ? th.color.warning : th.color.fg_muted, th.font.size_xs, max_width = tk.textDialog),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(New_Event_Cancelled{}), id = skald.hash_id("new-event-cancel"), bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, "Create", Msg(New_Event_Created{}), id = skald.hash_id("new-event-create"), font_size = th.font.size_sm, disabled = problem != ""),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("new-event-dialog"),
		initial_focus = skald.hash_id("new-event-name"),
		width = tk.dialogM,
	)
}

// The Listen... dialog: which of the scene's scripts listens to the node's event
listenerDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	if !s.listenerDialog.open do return closedDialog(ctx, "listener-dialog")
	th := ctx.theme
	d := &s.listenerDialog
	scene := &s.project.scenes[s.currentScene]
	if d.node < 0 || d.node >= len(scene.nodes) do return closedDialog(ctx, "listener-dialog")
	source := &scene.nodes[d.node]
	description := ""
	for ev in e.SceneNodeKind_Events(NodeDef_BuiltKind(&s.project, source)) do if ev.name == d.event do description = ev.description
	rows := make([dynamic]skald.View, context.temp_allocator)
	targets := Listener_Targets(scene)
	for target, i in targets {
		node := &scene.nodes[target]
		label := fmt.tprintf("%s  %s   (%s)", ICON_CODE, node.script, Scene_NodePath(scene, -1, target, context.temp_allocator)[1:])
		append(&rows, skald.button(ctx, label, Msg(Listener_Target_Chosen(target)), id = skald.hash_id(fmt.tprintf("listener-target-%d", i)),
			bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm))
	}
	if len(targets) == 0 {
		append(&rows, uiText(th, .Muted, "No node in this scene has a script yet: add one first (right-click a node > Add Script...).", max_width = tk.textDialog))
	}
	return skald.dialog(ctx,
		open = true,
		on_dismiss = proc() -> Msg { return Listener_Dialog_Cancelled{} },
		content = skald.col(
			uiText(th, .Title, fmt.tprintf("Listen to %s's %s", source.name, d.event), max_width = tk.textDialog),
			uiText(th, .Muted, description, max_width = tk.textDialog),
			uiText(th, .Muted, "Which script listens? It gets a handler, opened in the code editor, called whenever the event happens (connected before ready).", max_width = tk.textDialog),
			skald.col(..rows[:], spacing = th.spacing.xs, cross_align = .Stretch),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(Listener_Dialog_Cancelled{}), id = skald.hash_id("listener-cancel"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("listener-dialog"),
		width = tk.dialogM,
	)
}
