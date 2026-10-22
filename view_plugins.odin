package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import api "plugin_api"

/*
The Plugins tab (the bottom panel's) and plugins' inspector rows (plugin_host.odin).

	+--------------------------------------------------------------------------------------+
	| + New Plugin   Rebuild All                                                    Manual  |
	| grid_tools  Loaded   Arranges nodes on a grid                                         |
	|   [Arrange Children in a Grid]  [Snap to Pixels]   imports .csv   rows for Sprite      |
	| broken  Failed: its build failed: see the Output tab                                  |
	+--------------------------------------------------------------------------------------+

Widget keys: `plugins-new`, `plugins-rebuild`, `plugins-manual`, `plugin-<i>-command-<k>`; inspector
rows `plugin-row-<plugin>-<inspector>-<id>`.
*/

PluginsPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	left, right := FittedSidebarWidths(&s.layout)
	width := s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.sm * 2 - INSPECTOR_SCROLLBAR_WIDTH
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.bg, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	small :: proc(ctx: ^skald.Ctx(Msg), text: string, width: f32) -> skald.View { return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = width) }
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.wrap_row(
		button(ctx, "plugins-new", fmt.tprintf("%s  New Plugin", ICON_PLUS), Msg(Plugin_New_Requested{})),
		button(ctx, "plugins-rebuild", "Rebuild All", Msg(Plugins_Rebuild_Requested{})),
		button(ctx, "plugins-manual", fmt.tprintf("%s  Manual", ICON_CIRCLE_INFO), Msg(Manual_Opened("plugins"))),
		spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.sm, width = width, bg = th.color.surface))
	list := Plugins_List()
	if len(list) == 0 {
		append(&rows, small(ctx, "Plugins add tools to the editor: commands that change the project, importers for other file formats, extra inspector rows. A plugin is an Odin package in the project's plugins/ folder; New Plugin writes one to start from, and the editor builds and loads it (again whenever you save it).", width))
	}
	for p, i in list {
		color := th.color.fg_muted
		status := fmt.tprint(p.status)
		switch p.status {
		case .Loaded: color = th.color.success
		case .Failed:
			color = th.color.danger
			status = fmt.tprintf("Failed: %s", p.problem)
		case .Building: status = "Building..."
		case .Waiting:
		}
		// A right-click on the name: the plugin's menu (context_menus_panels.odin); widget `plugin-<i>`
		nameId := skald.hash_id(fmt.tprintf("plugin-%d", i))
		rightPressOpens(ctx, lastRect(ctx, nameId), Ctx_Graph{graph = .Plugin, item = i, sub = -1})
		name := new(skald.View, context.temp_allocator)
		name^ = skald.text(fmt.tprintf("%s  %s", ICON_PLUG, p.name), th.color.fg, th.font.size_sm)
		append(&rows, skald.wrap_row(
			skald.View_Zone{id = nameId, child = name},
			skald.text(status, color, th.font.size_xs, max_width = width - 200),
			small(ctx, fmt.tprintf("plugins/%s", p.folder), 200),
			spacing = th.spacing.md, line_spacing = th.spacing.xs, padding = th.spacing.xs, width = width))
		if p.description != "" do append(&rows, skald.row(skald.spacer(th.spacing.lg), small(ctx, p.description, width - th.spacing.lg)))
		if p.status != .Loaded do continue
		parts := make([dynamic]skald.View, context.temp_allocator)
		append(&parts, skald.spacer(th.spacing.lg))
		for c, k in p.commands {
			b := button(ctx, fmt.tprintf("plugin-%d-command-%d", i, k), strings.clone(c.name, context.temp_allocator), Msg(Plugin_Command_Run{i, k}))
			append(&parts, c.description != "" ? skald.tooltip(ctx, b, strings.clone(c.description, context.temp_allocator), id = skald.hash_id(fmt.tprintf("plugin-%d-command-%d-tip", i, k))) : b)
		}
		for importer in p.importers {
			exts := make([dynamic]string, context.temp_allocator)
			for x in importer.extensions do append(&exts, fmt.tprintf(".%s", x))
			append(&parts, small(ctx, fmt.tprintf("imports %s", strings.join(exts[:], ", ", context.temp_allocator)), 200))
		}
		for inspector in p.inspectors {
			append(&parts, small(ctx, fmt.tprintf("rows for %s", strings.join(inspector.targets[:], ", ", context.temp_allocator)), 240))
		}
		if len(parts) == 1 do append(&parts, small(ctx, "It adds nothing yet.", 200))
		append(&rows, skald.wrap_row(..parts[:], spacing = th.spacing.sm, line_spacing = th.spacing.xs, padding = th.spacing.xs, width = width))
	}
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, width = width, padding = th.spacing.sm), id = skald.hash_id("plugins-scroll"))
}

/*
The inspector rows plugins add for the selected node (after its kind's rows): each plugin's
under its name.
*/
pluginInspectorRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, controlWidth: f32) -> []skald.View {
	th := ctx.theme
	out := make([dynamic]skald.View, context.temp_allocator)
	node := s.selectedNode
	for group in Plugins_InspectorRows(s, node) {
		if len(group.rows) == 0 do continue
		append(&out, skald.divider(ctx), skald.text(fmt.tprintf("%s  %s", ICON_PLUG, group.name), th.color.fg, th.font.size_sm))
		for row in group.rows {
			Payload :: struct { plugin, inspector, node: int, id: string }
			p := Payload{group.plugin, group.inspector, node, strings.clone(row.id, context.temp_allocator)}
			key := skald.hash_id(fmt.tprintf("plugin-row-%d-%d-%s", group.plugin, group.inspector, row.id))
			changed :: proc(p: Payload, v: string) -> Msg { return Plugin_Row_Changed{p.plugin, p.inspector, p.node, p.id, v} }
			value := strings.clone(row.value, context.temp_allocator)
			control: skald.View
			switch row.kind {
			case .Note:
				control = skald.text(value, th.color.fg_muted, th.font.size_xs, max_width = controlWidth)
			case .Text, .Number:
				control = skald.text_input(ctx, value, p, changed, id = key, width = controlWidth, padding = InspectorFieldPadding(ctx))
			case .Bool:
				control = skald.checkbox(ctx, value == "true", "", p, proc(p: Payload, v: bool) -> Msg { return Plugin_Row_Changed{p.plugin, p.inspector, p.node, p.id, v ? "true" : "false"} }, id = key)
			case .Choice:
				choices := make([]string, len(row.choices), context.temp_allocator)
				for c, i in row.choices do choices[i] = strings.clone(c, context.temp_allocator)
				control = skald.select(ctx, value, choices, p, changed, id = key, width = controlWidth)
			case .Button:
				control = skald.button(ctx, value != "" ? value : row.label, Msg(Plugin_Row_Changed{p.plugin, p.inspector, p.node, p.id, ""}), id = key,
					bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
			}
			append(&out, inspectorRow(ctx, strings.clone(row.label, context.temp_allocator), control, "Added by a plugin"))
		}
	}
	return out[:]
}

_ :: api.RowKind
