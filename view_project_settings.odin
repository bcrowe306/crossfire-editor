package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The Project Settings dialog (File > Project Settings), in two tabs:
- General: the game's name, resolution, how it scales to the window, its background color, and
  the scene it starts in.
- Export: every export target, each with a checkbox (File > Export exports the checked ones) and
  its own settings, plus an Export button for the shown target.
Apply makes the changes one undoable step (scene_actions.odin); Export applies them first.

Widget keys for UI tests: `project-settings-tab-<Tab>`, `project-settings-name`,
`project-settings-start`, `project-settings-apply`, `project-settings-cancel`; Export tab:
`export-target-<Target>` (shows it), `export-enable-<Target>`, `export-field-<Field>`,
`export-run`, `export-cancel`, the settings scroll `export-settings-scroll-<Target>`.
*/
projectSettingsDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	d := &s.projectSettings
	content: skald.View = skald.View_Spacer{size = 0}
	if d.open {
		tabs := make([dynamic]skald.View, context.temp_allocator)
		for tab in ProjectSettingsTab {
			active := tab == d.tab
			append(&tabs, skald.button(ctx, fmt.tprintf("%v", tab), Msg(Project_Settings_Tab_Changed(tab)),
				id = skald.hash_id(fmt.tprintf("project-settings-tab-%v", tab)),
				bg = active ? th.color.primary : th.color.surface,
				fg = active ? th.color.on_primary : th.color.fg,
				font_size = th.font.size_sm))
		}
		body := d.tab == .General ? generalTab(s, ctx) : exportTab(s, ctx)
		// The Export tab scrolls inside a fixed height: 400 px, less in a short window, so the
		// buttons below stay on screen (the title, tabs and footer take about 220 px)
		exportHeight: f32 = 400
		if ctx.renderer != nil do exportHeight = clamp(f32(ctx.renderer.fb_size.y) - 220, 160, 400)
		content = skald.col(
			skald.text("Project Settings", th.color.fg, th.font.size_lg),
			skald.row(..tabs[:], spacing = th.spacing.xs),
			skald.divider(ctx),
			skald.col(skald.flex(1, body), height = d.tab == .General ? 0 : exportHeight, cross_align = .Stretch),
			skald.divider(ctx),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(Project_Settings_Cancelled{}), id = skald.hash_id("project-settings-cancel"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, "Apply", Msg(Project_Settings_Applied{}), id = skald.hash_id("project-settings-apply"),
					font_size = th.font.size_sm),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		)
	}
	width: f32 = d.tab == .Export ? 760 : 460
	return skald.dialog(ctx,
		open = d.open,
		on_dismiss = proc() -> Msg { return Project_Settings_Cancelled{} },
		content = content,
		id = skald.hash_id("project-settings-dialog"),
		width = width,
		max_width = width,
	)
}

@(private="file")
settingRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	return skald.row(
		skald.col(skald.text(label, ctx.theme.color.fg, ctx.theme.font.size_sm), width = 120),
		control,
		spacing = ctx.theme.spacing.sm,
		cross_align = .Center,
	)
}

@(private="file")
generalTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	d := &s.projectSettings
	scenes := make([dynamic]string, context.temp_allocator)
	for scene in s.project.scenes do append(&scenes, scene.name)
	modes := make([dynamic]string, context.temp_allocator)
	for mode in e.ScaleMode do append(&modes, fmt.tprint(mode))
	return skald.col(
		// Copies: d lives in this frame's copy of the state (see the rule in CLAUDE.md)
		settingRow(ctx, "Name", skald.text_input(ctx, strings.clone(d.name, context.temp_allocator),
			proc(v: string) -> Msg { return Project_Settings_Name_Changed(v) },
			id = skald.hash_id("project-settings-name"), width = 260)),
		settingRow(ctx, "Resolution", skald.row(
			numberField(ctx, s, "project-settings-width", GameSizeTarget(0), f64(d.gameSize.x), 16, 0, 120, 16, 16384),
			skald.text("x", th.color.fg_muted, th.font.size_sm),
			numberField(ctx, s, "project-settings-height", GameSizeTarget(1), f64(d.gameSize.y), 16, 0, 120, 16, 16384),
			spacing = th.spacing.xs,
			cross_align = .Center,
		)),
		settingRow(ctx, "Scaling", skald.select(ctx, fmt.tprint(d.scaleMode), modes[:],
			proc(v: string) -> Msg { return Project_Settings_Scale_Changed(v) },
			id = skald.hash_id("project-settings-scale"), width = 160)),
		settingRow(ctx, "Background", skald.color_picker(ctx, d.background,
			proc(c: skald.Color) -> Msg { return Project_Settings_Background_Changed(c) },
			id = skald.hash_id("project-settings-background"), width = 160)),
		settingRow(ctx, "Start scene", skald.select(ctx, strings.clone(d.startScene, context.temp_allocator), scenes[:],
			proc(v: string) -> Msg { return Project_Settings_Start_Changed(v) },
			id = skald.hash_id("project-settings-start"), width = 200)),
		skald.text("The scene the game starts in (Play, and exports). Play Scene (Ctrl+F5) starts in the open scene instead.",
			th.color.fg_muted, th.font.size_xs, max_width = 420),
		skald.divider(ctx),
		settingRow(ctx, "Pixels per meter", numberField(ctx, s, "project-settings-ppm", PhysicsTarget.Pixels_Per_Meter, f64(d.physics.pixelsPerMeter), 10, 0, 120, 1, 10000)),
		settingRow(ctx, "Gravity", skald.row(
			numberField(ctx, s, "project-settings-gravity-x", PhysicsTarget.Gravity_X, f64(d.physics.gravity.x), 10, 0, 120),
			numberField(ctx, s, "project-settings-gravity-y", PhysicsTarget.Gravity_Y, f64(d.physics.gravity.y), 10, 0, 120),
			spacing = th.spacing.xs,
		)),
		settingRow(ctx, "Show shapes", skald.checkbox(ctx, d.physics.debugDraw, "Draw collision shapes in the game",
			proc(v: bool) -> Msg { return Project_Settings_Physics_Debug_Changed(v) },
			id = skald.hash_id("project-settings-physics-debug"))),
		skald.text("Physics works in meters: a body of 1 m is this many pixels (Box2D does best with things 0.1 to 10 m). Gravity is in pixels per second², y down: 980 is Earth's at 100 px per meter.",
			th.color.fg_muted, th.font.size_xs, max_width = 420),
		spacing = th.spacing.sm,
		cross_align = .Stretch,
	)
}

// The target list on the left, the shown target's settings on the right
@(private="file")
exportTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	d := &s.projectSettings

	list := make([dynamic]skald.View, context.temp_allocator)
	for group in ExportGroup {
		append(&list, skald.text(fmt.tprintf("%v", group), th.color.fg_muted, th.font.size_xs))
		for info, target in EXPORT_TARGETS {
			if info.group != group do continue
			shown := target == d.exportTarget
			label := Export_Implemented(target) ? info.label : fmt.tprintf("%s (not implemented)", info.label)
			append(&list, skald.row(
				skald.checkbox(ctx, d.exports.targets[target].enabled, "", target,
					proc(t: ExportTarget, v: bool) -> Msg { return Export_Target_Enabled{t, v} },
					id = skald.hash_id(fmt.tprintf("export-enable-%v", target))),
				skald.button(ctx, label, Msg(Export_Target_Selected(target)),
					id = skald.hash_id(fmt.tprintf("export-target-%v", target)),
					bg = shown ? th.color.primary : th.color.bg,
					fg = shown ? th.color.on_primary : (Export_Implemented(target) ? th.color.fg : th.color.fg_muted),
					font_size = th.font.size_sm, padding = {th.spacing.sm, 2}, width = 210),
				spacing = th.spacing.xs,
				cross_align = .Center,
			))
		}
		append(&list, skald.spacer(th.spacing.xs))
	}
	targets := skald.scroll(ctx, {0, 0}, skald.col(..list[:], spacing = 2, cross_align = .Start),
		id = skald.hash_id("export-targets-scroll"))

	return skald.row(
		// flex: a scroll needs a height to scroll in
		skald.col(skald.flex(1, targets), width = 250, cross_align = .Stretch),
		// A scroll position per target: each opens at the top, with its Export button in view
		skald.flex(1, skald.scroll(ctx, {0, 0}, exportTargetSettings(s, ctx),
			id = skald.hash_id(fmt.tprintf("export-settings-scroll-%v", d.exportTarget)))),
		spacing = th.spacing.md,
		cross_align = .Stretch,
	)
}

@(private="file")
exportTargetSettings :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	d := &s.projectSettings
	target := d.exportTarget
	info := EXPORT_TARGETS[target]
	t := &d.exports.targets[target]
	rows := make([dynamic]skald.View, context.temp_allocator)
	// The buttons sit beside the title, so they're in view whatever the target's settings
	busy := Export_Busy(s)
	header := make([dynamic]skald.View, context.temp_allocator)
	append(&header, skald.text(info.label, th.color.fg, th.font.size_md))
	append(&header, skald.button(ctx, "Export", Msg(Export_Target_Run(target)),
		id = skald.hash_id("export-run"), font_size = th.font.size_sm, disabled = busy))
	if busy {
		append(&header, skald.button(ctx, "Cancel Export", Msg(Export_Cancel_Requested{}), id = skald.hash_id("export-cancel"),
			bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm))
	}
	append(&rows, skald.row(..header[:], spacing = th.spacing.md, cross_align = .Center))

	status, statusColor := "Ready to export from this machine.", th.color.success
	if !Export_Implemented(target) {
		status, statusColor = Export_NotImplementedReason(target), th.color.warning
	} else if target == .Web && !os.exists(Export_EmccPath(absolutePath(EMSDK_DIR), context.temp_allocator)) {
		status, statusColor = "Needs Emscripten: run `task emsdk` in the editor's folder (about 1 GB, once).", th.color.warning
	}
	append(&rows, skald.text(status, statusColor, th.font.size_sm, max_width = 440))
	append(&rows, skald.text(info.note, th.color.fg_muted, th.font.size_xs, max_width = 440))
	append(&rows, skald.spacer(th.spacing.xs))

	for field in info.fields {
		fieldInfo := EXPORT_FIELDS[field]
		key := skald.hash_id(fmt.tprintf("export-field-%v", field))
		Payload :: struct {
			target: ExportTarget,
			field: ExportField,
		}
		payload := Payload{target, field}
		control: skald.View
		switch fieldInfo.kind {
		case .Text:
			placeholder := ""
			#partial switch field {
			case .Output_Folder: placeholder = fmt.tprintf("%s/%s", EXPORT_DEFAULT_FOLDER, strings.to_lower(fmt.tprint(target), context.temp_allocator))
			case .Executable_Name: placeholder = sanitize(s.project.name)
			case .Page_Title: placeholder = strings.clone(s.project.name, context.temp_allocator)
			}
			// A copy: the text is inline in this frame's copy of the state
			control = skald.text_input(ctx, strings.clone(FixedText_String(ExportField_Text(t, field)), context.temp_allocator), payload,
				proc(p: Payload, v: string) -> Msg { return Export_Text_Changed{p.target, p.field, v} },
				id = key, width = 300, placeholder = placeholder)
		case .Bool:
			control = skald.checkbox(ctx, ExportField_Bool(t, field)^, "", payload,
				proc(p: Payload, v: bool) -> Msg { return Export_Flag_Changed{p.target, p.field, v} },
				id = key)
		}
		append(&rows, settingRow(ctx, fieldInfo.label, control))
		if fieldInfo.help != "" do append(&rows, skald.text(fieldInfo.help, th.color.fg_muted, th.font.size_xs, max_width = 440))
	}

	append(&rows, skald.spacer(th.spacing.sm))
	append(&rows, skald.text("Export (above) exports this target. File > Export exports every checked target. Exporting saves the project and applies these settings.",
		th.color.fg_muted, th.font.size_xs, max_width = 440))
	return skald.col(..rows[:], spacing = th.spacing.sm, padding = th.spacing.xs, cross_align = .Start)
}
