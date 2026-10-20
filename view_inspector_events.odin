package crossfire_editor

import "core:fmt"
import "gui:skald"
import e "engine:."

/*
The inspector's Events section and the Listen... dialog (node_listeners.odin): the node's events
(the engine's, for the kind it's built as), each with the scripts listening to it (× removes
one) and Listen..., which asks which script of the scene listens. Collapsed until opened, unless
the node has listeners.

Widget keys: `inspector-events-toggle`, `inspector-event-listen-<event>`,
`inspector-listener-remove-<i>`; the dialog's `listener-dialog`, `listener-target-<i>` (the
scene's scripted nodes in order), `listener-cancel`.
*/
@(private="package")
eventsSection :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, controlWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	events := e.SceneNodeKind_Events(NodeDef_BuiltKind(&s.project, node))
	open := s.inspectorEventsOpen || len(node.listeners) > 0
	small :: proc(ctx: ^skald.Ctx(Msg), label, key: string, msg: Msg) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 1}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	append(&rows, skald.row(
		skald.text(fmt.tprintf("%s  Events (%d)", ICON_LINK, len(events)), th.color.fg, th.font.size_sm),
		skald.flex(1, skald.spacer(0)),
		len(node.listeners) > 0 ? skald.View(skald.View_Spacer{size = 0}) : small(ctx, open ? "Hide" : "Show", "inspector-events-toggle", Msg(Inspector_Events_Toggled{})),
		cross_align = .Center,
	))
	if !open do return rows[:]
	width := controlWidth + INSPECTOR_LABEL_WIDTH
	for ev in events {
		short := Event_ShortName(ev.name)
		append(&rows, skald.row(
			tipLabel(ctx, short, skald.text(ev.name, th.color.fg_muted, th.font.size_sm), ev.description),
			skald.flex(1, skald.spacer(0)),
			small(ctx, "Listen...", fmt.tprintf("inspector-event-listen-%s", ev.name), Msg(Listener_Dialog_Opened{s.selectedNode, ev.name})),
			cross_align = .Center,
		))
		for l, i in node.listeners do if l.event == ev.name {
			append(&rows, skald.row(
				skald.flex(1, skald.text(fmt.tprintf("    → %s  %s", l.target, l.handler), th.color.fg, th.font.size_xs, max_width = width - 30)),
				small(ctx, "×", fmt.tprintf("inspector-listener-remove-%d", i), Msg(Listener_Removed{s.selectedNode, i})),
				cross_align = .Center,
			))
		}
	}
	// Listeners for events the node's kind doesn't have (it changed kind, or an older engine's)
	for l, i in node.listeners {
		known := false
		for ev in events do if ev.name == l.event do known = true
		if known do continue
		append(&rows, skald.row(
			skald.flex(1, skald.text(fmt.tprintf("%s (no such event) → %s  %s", l.event, l.target, l.handler), th.color.warning, th.font.size_xs, max_width = width - 30)),
			small(ctx, "×", fmt.tprintf("inspector-listener-remove-%d", i), Msg(Listener_Removed{s.selectedNode, i})),
			cross_align = .Center,
		))
	}
	return rows[:]
}

// The Listen... dialog: which of the scene's scripts listens to the node's event
listenerDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
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
		append(&rows, skald.text("No node in this scene has a script yet: add one first (right-click a node > Add Script...).", th.color.fg_muted, th.font.size_xs, max_width = 380))
	}
	return skald.dialog(ctx,
		open = true,
		on_dismiss = proc() -> Msg { return Listener_Dialog_Cancelled{} },
		content = skald.col(
			skald.text(fmt.tprintf("Listen to %s's %s", source.name, d.event), th.color.fg, th.font.size_lg, max_width = 380),
			skald.text(description, th.color.fg_muted, th.font.size_xs, max_width = 380),
			skald.text("Which script listens? It gets a handler, opened in the code editor, called whenever the event happens (connected before ready).", th.color.fg_muted, th.font.size_xs, max_width = 380),
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
		width = 420,
	)
}
