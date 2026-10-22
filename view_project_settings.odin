package crossfire_editor

import "core:fmt"
import "core:reflect"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The Project Settings dialog (File > Project Settings), in these tabs:
- General: the game's name, resolution, how it scales to the window, its background color, and
  the scene it starts in.
- Input: the game's input actions and what triggers them (input_actions.odin).
- Globals: the scripts that run for the whole game.
- Export: every export target, each with a checkbox (File > Export exports the checked ones) and
  its own settings, plus an Export button for the shown target.
- Grid: the viewport grid (cell size, major lines, opacities; View > Grid Settings opens it).
Apply makes the changes one undoable step (scene_actions.odin); Export applies them first.

Widget keys for UI tests: `project-settings-tab-<Tab>`, `project-settings-name`,
`project-settings-start`, `project-settings-apply`, `project-settings-cancel`; Grid tab:
`project-settings-grid-<Width | Height | Major_Every | Opacity | Major_Opacity>`; Export tab:
`export-target-<Target>` (shows it), `export-enable-<Target>`, `export-field-<Field>`,
`export-run`, `export-cancel`, the settings scroll `export-settings-scroll-<Target>`; Input tab:
`input-action-<i>` (shows it), `input-up-<i>`, `input-down-<i>`, `input-remove-<i>`,
`input-new-name`, `input-add`, `input-defaults`, `input-name`, `input-deadzone` (a valueSlider),
`input-binding-remove-<i>`, `input-capture`, `input-add-key`, `input-add-mouse`,
`input-add-gamepad`, `input-add-axis`, `input-device`.
*/
projectSettingsDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	// Closed: no content (its buttons would stay clickable where they were drawn: closedDialog)
	// Embedded: the Settings dialog's Project tab shows it (ProjectSettings_TabsView)
	if !s.projectSettings.open || s.projectSettings.embedded do return closedDialog(ctx, "project-settings-dialog")
	th := ctx.theme
	d := &s.projectSettings
	content: skald.View = skald.View_Spacer{size = 0}
	if d.open {
		tabs, body := ProjectSettings_TabsView(s, ctx)
		// The Export tab scrolls inside a fixed height: 400 px, less in a short window, so the
		// buttons below stay on screen (the title, tabs and footer take about 220 px)
		exportHeight: f32 = 400
		generalHeight: f32 = 560
		if ctx.renderer != nil {
			exportHeight = clamp(f32(ctx.renderer.fb_size.y) - 220, 160, 400)
			generalHeight = clamp(f32(ctx.renderer.fb_size.y) - 220, 160, 560)
		}
		content = skald.col(
			skald.text("Project Settings", th.color.fg, th.font.size_lg),
			tabs,
			skald.divider(ctx),
			skald.col(skald.flex(1, body), height = d.tab == .General ? generalHeight : exportHeight, cross_align = .Stretch),
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
	width: f32 = d.tab == .General ? 460 : 760
	return skald.dialog(ctx,
		open = d.open,
		on_dismiss = proc() -> Msg { return Project_Settings_Cancelled{} },
		content = content,
		id = skald.hash_id("project-settings-dialog"),
		width = width,
		max_width = width,
	)
}

/*
The Project Settings tabs: the row of tab buttons and the shown tab, for the Project Settings
dialog and the Settings dialog's Project tab.

Returns:
- The tab buttons (a row), and the shown tab's content
*/
ProjectSettings_TabsView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> (tabs, body: skald.View) {
	th := ctx.theme
	d := &s.projectSettings
	buttons := make([dynamic]skald.View, context.temp_allocator)
	for tab in ProjectSettingsTab {
		active := tab == d.tab
		append(&buttons, skald.button(ctx, fmt.tprintf("%v", tab), Msg(Project_Settings_Tab_Changed(tab)),
			id = skald.hash_id(fmt.tprintf("project-settings-tab-%v", tab)),
			bg = active ? th.color.primary : th.color.surface,
			fg = active ? th.color.on_primary : th.color.fg,
			font_size = th.font.size_sm))
	}
	// General and Grid scroll once they're taller than the dialog leaves them (a short, tiled
	// window; Settings' Project tab, which has less room): the dialog's buttons must stay drawn,
	// or they can't be clicked. The other tabs scroll their own lists
	switch d.tab {
	case .General: body = skald.scroll(ctx, {0, 0}, generalTab(s, ctx), id = skald.hash_id("project-settings-general-scroll"))
	case .Input:   body = inputTab(s, ctx)
	case .Globals: body = globalsTab(s, ctx)
	case .Export:  body = exportTab(s, ctx)
	case .Grid:    body = skald.scroll(ctx, {0, 0}, gridTab(s, ctx), id = skald.hash_id("project-settings-grid-scroll"))
	}
	return skald.row(..buttons[:], spacing = th.spacing.xs), body
}

// The viewport grid for this project (keys project-settings-grid-<field>)
@(private="file")
gridTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	g := &s.projectSettings.grid
	field :: proc(ctx: ^skald.Ctx(Msg), s: ^State, target: GridTarget, value: int, limits: [2]int, unit: string) -> skald.View {
		return skald.row(
			numberField(ctx, s, fmt.tprintf("project-settings-grid-%v", target), target, f64(value), 1, 0, 120, f64(limits[0]), f64(limits[1])),
			skald.text(unit, ctx.theme.color.fg_muted, ctx.theme.font.size_sm),
			spacing = ctx.theme.spacing.xs,
			cross_align = .Center,
		)
	}
	note :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
		return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = 440)
	}
	return skald.col(
		settingRow(ctx, "Grid width", field(ctx, s, .Width, g.size.x, e.GRID_SIZE_RANGE, "px")),
		settingRow(ctx, "Grid height", field(ctx, s, .Height, g.size.y, e.GRID_SIZE_RANGE, "px")),
		note(ctx, "The viewport grid's cell, in world units. G shows the grid; Shift+G snaps moves to it (and rotation to 15°, scale to 0.1)."),
		settingRow(ctx, "Major lines every", field(ctx, s, .Major_Every, g.majorEvery, e.GRID_MAJOR_RANGE, "cells")),
		settingRow(ctx, "Line opacity", field(ctx, s, .Opacity, g.opacity, {0, 100}, "%")),
		settingRow(ctx, "Major line opacity", field(ctx, s, .Major_Opacity, g.majorOpacity, {0, 100}, "%")),
		note(ctx, "Major lines divide the grid into blocks of cells (0: none). The grid is saved with the project (project.xml), so everyone working on it sees the same one; the game doesn't use it."),
		spacing = th.spacing.sm,
		padding = th.spacing.xs,
		cross_align = .Start,
	)
}

@(private="file")
settingRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	return skald.row(
		skald.col(tipLabel(ctx, label, skald.text(label, ctx.theme.color.fg, ctx.theme.font.size_sm)), width = 120),
		control,
		spacing = ctx.theme.spacing.sm,
		cross_align = .Center,
	)
}

// The renderer choices: every backend, marked when this computer's SDL doesn't have it
@(private="file")
rendererSelect :: proc(ctx: ^skald.Ctx(Msg), backend: e.RenderBackend) -> skald.View {
	labels := make([dynamic]string, context.temp_allocator)
	for b in e.RenderBackend do append(&labels, rendererLabel(b))
	return skald.select(ctx, rendererLabel(backend), labels[:],
		proc(label: string) -> Msg {
			for b in e.RenderBackend do if rendererLabel(b) == label do return Project_Settings_Renderer_Changed(b)
			return nil
		},
		id = skald.hash_id("project-settings-renderer"), width = 260)
}

@(private="file")
rendererLabel :: proc(backend: e.RenderBackend) -> string {
	info := e.RENDER_BACKENDS[backend]
	if !e.RenderBackend_Available(backend) do return fmt.tprintf("%s (not on this computer)", info.label)
	return info.label
}

// Where the chosen renderer works, and what happens elsewhere
@(private="file")
rendererNote :: proc(backend: e.RenderBackend) -> string {
	if backend == .Auto do return "SDL picks the best renderer on each platform: OpenGL on Linux, Direct3D 11 on Windows, Metal on macOS. Web exports always use WebGL."
	return fmt.tprintf("%s: %s. Where it isn't available (or fails to start), the game falls back to SDL's choice; web exports always use WebGL.",
		e.RENDER_BACKENDS[backend].label, e.RENDER_BACKENDS[backend].platforms)
}

@(private="file")
generalTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	d := &s.projectSettings
	scenes := make([dynamic]string, context.temp_allocator)
	append(&scenes, ..Project_SceneNames(&s.project))
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
		settingRow(ctx, "Renderer", rendererSelect(ctx, d.renderer)),
		skald.text(rendererNote(d.renderer), th.color.fg_muted, th.font.size_xs, max_width = 420),
		settingRow(ctx, "Window", skald.row(
			windowFlag(ctx, "Fullscreen", .Fullscreen, d.window.fullscreen),
			windowFlag(ctx, "VSync", .VSync, d.window.vsync),
			windowFlag(ctx, "High DPI", .High_DPI, d.window.highDPI),
			spacing = th.spacing.md,
		)),
		skald.text("How the game's window starts: fullscreen at the desktop's resolution, frames in step with the display (vsync), at the display's full pixel density (sharper on high-DPI screens). Games can change fullscreen and vsync while running.",
			th.color.fg_muted, th.font.size_xs, max_width = 420),
		settingRow(ctx, "Sound output", audioOutputSelects(ctx, d.audioOutput)),
		skald.text("The format the game asks its sound device for; the device converts it to what it really is. Stereo at 48 kHz works on every device. \"The device's own\" asks for the device's native format, which fails on outputs SDL can't open that way (some multichannel, Bluetooth or HDMI outputs). If a format won't open, the game tries the others, then other devices, and logs what it got.",
			th.color.fg_muted, th.font.size_xs, max_width = 420),
		settingRow(ctx, "Background", skald.color_picker(ctx, d.background,
			proc(c: skald.Color) -> Msg { return Project_Settings_Background_Changed(c) },
			id = skald.hash_id("project-settings-background"), width = 160)),
		settingRow(ctx, "Start scene", skald.select(ctx, strings.clone(d.startScene, context.temp_allocator), scenes[:],
			proc(v: string) -> Msg { return Project_Settings_Start_Changed(v) },
			id = skald.hash_id("project-settings-start"), width = 200)),
		skald.text("The scene the game starts in (Play, and exports). Play Scene (Ctrl+F5) starts in the open scene instead.",
			th.color.fg_muted, th.font.size_xs, max_width = 420),
		settingRow(ctx, "Icon", iconSelect(ctx, s, d.icon)),
		skald.col(..sceneFlowSettingRows(ctx, s), spacing = th.spacing.sm, cross_align = .Stretch),
		settingRow(ctx, "Language", skald.text_input(ctx, strings.clone(d.locale, context.temp_allocator),
			proc(v: string) -> Msg { return Project_Settings_Locale_Changed(v) },
			id = skald.hash_id("project-settings-locale"), width = 120)),
		skald.text(localeNote(s), th.color.fg_muted, th.font.size_xs, max_width = 420),
		skald.divider(ctx),
		settingRow(ctx, "Pixels per meter", numberField(ctx, s, "project-settings-ppm", PhysicsTarget.Pixels_Per_Meter, f64(d.physics.pixelsPerMeter), 10, 0, 120, 1, 10000)),
		settingRow(ctx, "Gravity", skald.row(
			numberField(ctx, s, "project-settings-gravity-x", PhysicsTarget.Gravity_X, f64(d.physics.gravity.x), 10, 0, 120),
			numberField(ctx, s, "project-settings-gravity-y", PhysicsTarget.Gravity_Y, f64(d.physics.gravity.y), 10, 0, 120),
			spacing = th.spacing.xs,
		)),
		settingRow(ctx, "Show shapes", skald.checkbox(ctx, d.physics.debugDraw, "Draw collision shapes in the game while developing",
			proc(v: bool) -> Msg { return Project_Settings_Physics_Debug_Changed(v) },
			id = skald.hash_id("project-settings-physics-debug"))),
		skald.text("For Play only: exports never draw them. While playing, F9 shows and hides them. Also in the Scene menu.",
			th.color.fg_muted, th.font.size_xs, max_width = 420),
		settingRow(ctx, "Smooth motion", skald.checkbox(ctx, d.physics.smoothing, "Draw bodies between physics steps",
			proc(v: bool) -> Msg { return Project_Settings_Physics_Smoothing_Changed(v) },
			id = skald.hash_id("project-settings-physics-smoothing"))),
		skald.text("Physics steps 60 times a second whatever the frame rate; smoothing draws moving bodies in between, so they glide on fast screens (they're drawn up to one step behind).",
			th.color.fg_muted, th.font.size_xs, max_width = 420),
		skald.text("Physics works in meters: a body of 1 m is this many pixels (Box2D does best with things 0.1 to 10 m). Gravity is in pixels per second², y down: 980 is Earth's at 100 px per meter.",
			th.color.fg_muted, th.font.size_xs, max_width = 420),
		spacing = th.spacing.sm,
		cross_align = .Stretch,
	)
}

/*
Globals: the scripts that run for the whole game, in start order, and the shown one's fields.
Widget keys: `global-<i>` (shows it), `global-up-<i>`, `global-down-<i>`, `global-remove-<i>`,
`global-add`; fields `inspector-prop-<field>-global<i>`.
*/
@(private="file")
globalsTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	d := &s.projectSettings
	list := make([dynamic]skald.View, context.temp_allocator)
	small :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg, disabled := false) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg_muted,
			font_size = th.font.size_xs, padding = {th.spacing.xs, 1}, radius = th.radius.sm, disabled = disabled)
	}
	for g, i in d.globals {
		shown := i == d.selectedGlobal
		append(&list, skald.row(
			skald.button(ctx, fmt.tprintf("%s  %s", ICON_GLOBE, g.script), Msg(Global_Selected(i)), id = skald.hash_id(fmt.tprintf("global-%d", i)),
				bg = shown ? th.color.primary : th.color.bg, fg = shown ? th.color.on_primary : th.color.fg,
				font_size = th.font.size_sm, padding = {th.spacing.sm, 2}, width = 150),
			small(ctx, fmt.tprintf("global-up-%d", i), ICON_CHEVRON_UP, Msg(Global_Moved{i, -1}), i == 0),
			small(ctx, fmt.tprintf("global-down-%d", i), ICON_CHEVRON_DOWN, Msg(Global_Moved{i, 1}), i == len(d.globals) - 1),
			small(ctx, fmt.tprintf("global-remove-%d", i), ICON_TRASH, Msg(Global_Removed(i))),
			spacing = th.spacing.xs,
			cross_align = .Center,
		))
	}
	if len(d.globals) == 0 do append(&list, skald.text("No globals yet.", th.color.fg_muted, th.font.size_sm))
	// Scripts that could be added
	choices := make([dynamic]string, context.temp_allocator)
	append(&choices, TEXTURE_NONE)
	for script in s.scripts.scripts {
		taken := false
		for g in d.globals do if g.script == script.name do taken = true
		if !taken do append(&choices, script.name)
	}
	append(&list, skald.spacer(th.spacing.sm), skald.text("Add a script as a global:", th.color.fg_muted, th.font.size_xs),
		skald.select(ctx, TEXTURE_NONE, choices[:], proc(v: string) -> Msg { return Global_Added(v) },
			id = skald.hash_id("global-add"), width = 220, placeholder = "Choose a script"))
	if s.scripts.status != .Ready {
		append(&list, skald.text("Build the scripts (Ctrl+B) to list them here.", th.color.fg_muted, th.font.size_xs, max_width = 230))
	}

	fields := make([dynamic]skald.View, context.temp_allocator)
	append(&fields,
		skald.text("Globals run for the whole game, across scenes, in this order: game state, settings, a HUD. Every Play starts them from these values. Scripts reach one with e.Global(Type), and e.Save_Game / e.Load_Game save and restore their fields as JSON.",
			th.color.fg_muted, th.font.size_xs, max_width = 440),
		skald.spacer(th.spacing.xs))
	if d.selectedGlobal >= 0 && d.selectedGlobal < len(d.globals) {
		g := &d.globals[d.selectedGlobal]
		append(&fields, skald.text(g.script, th.color.fg, th.font.size_md))
		desc := ScriptCatalog_Find(&s.scripts, g.script)
		if desc == nil {
			append(&fields, skald.text(fmt.tprintf("Build the scripts (Ctrl+B) to edit %s's fields.", g.script), th.color.fg_muted, th.font.size_xs))
			for p in g.props do append(&fields, settingRow(ctx, p.name, skald.text(p.value, th.color.fg_muted, th.font.size_sm)))
		} else if len(desc.fields) == 0 {
			append(&fields, skald.text("No exported fields (tag a field with export:\"\" to set it here).", th.color.fg_muted, th.font.size_xs))
		} else {
			for &field in desc.fields {
				append(&fields, settingRow(ctx, field.name, FieldControl(ctx, s, g.props[:], &field, fmt.tprintf("global%d", d.selectedGlobal),
					DraftGlobalTarget(d.selectedGlobal), 260, 120)))
			}
		}
	}
	return skald.row(
		skald.col(skald.flex(1, skald.scroll(ctx, {0, 0}, skald.col(..list[:], spacing = th.spacing.xs, cross_align = .Start), id = skald.hash_id("globals-list-scroll"))),
			width = 270, cross_align = .Stretch),
		skald.flex(1, skald.scroll(ctx, {0, 0}, skald.col(..fields[:], spacing = th.spacing.sm, padding = th.spacing.xs, cross_align = .Start),
			id = skald.hash_id("globals-fields-scroll"))),
		spacing = th.spacing.md,
		cross_align = .Stretch,
	)
}

/*
Input: the actions on the left (select, reorder, remove, add by name, add the default ui_*
ones), the shown action on the right: its name, deadzone and bindings. A binding is added by
pressing it ("Press a key or button": a key, a modifier, a mouse button or the wheel) or from
the dropdowns (every key; mouse buttons; gamepad buttons and stick directions, for any gamepad or
one).
*/
@(private="file")
inputTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	d := &s.projectSettings
	if d.capturing {
		if binding, captured, cancelled := Input_CaptureBinding(ctx, d.captureModifiers); captured {
			skald.send(ctx, Msg(Input_Binding_Added{binding}))
		} else if cancelled {
			skald.send(ctx, Msg(Input_Capture_Cancelled{}))
		}
	}
	small :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg, disabled := false) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg_muted,
			font_size = th.font.size_xs, padding = {th.spacing.xs, 1}, radius = th.radius.sm, disabled = disabled)
	}

	list := make([dynamic]skald.View, context.temp_allocator)
	for a, i in d.actions {
		shown := i == d.selectedAction
		append(&list, skald.row(
			skald.button(ctx, fmt.tprintf("%s  (%d)", a.name, len(a.bindings)), Msg(Input_Action_Selected(i)), id = skald.hash_id(fmt.tprintf("input-action-%d", i)),
				bg = shown ? th.color.primary : th.color.bg, fg = shown ? th.color.on_primary : th.color.fg,
				font_size = th.font.size_sm, padding = {th.spacing.sm, 2}, width = 140, text_align = .Start),
			small(ctx, fmt.tprintf("input-up-%d", i), ICON_CHEVRON_UP, Msg(Input_Action_Moved{i, -1}), i == 0),
			small(ctx, fmt.tprintf("input-down-%d", i), ICON_CHEVRON_DOWN, Msg(Input_Action_Moved{i, 1}), i == len(d.actions) - 1),
			small(ctx, fmt.tprintf("input-remove-%d", i), ICON_TRASH, Msg(Input_Action_Removed(i))),
			spacing = th.spacing.xs,
			cross_align = .Center,
		))
	}
	if len(d.actions) == 0 do append(&list, skald.text("No actions yet.", th.color.fg_muted, th.font.size_sm))
	newProblem := d.newActionName == "" ? "" : ActionNameProblem(d.actions[:], -1, d.newActionName)
	append(&list,
		skald.spacer(th.spacing.sm),
		skald.text("New action:", th.color.fg_muted, th.font.size_xs),
		skald.row(
			skald.text_input(ctx, strings.clone(d.newActionName, context.temp_allocator), proc(v: string) -> Msg { return Input_New_Name_Changed(v) },
				id = skald.hash_id("input-new-name"), width = 140, placeholder = "jump", invalid = newProblem != ""),
			skald.button(ctx, fmt.tprintf("%s Add", ICON_PLUS), Msg(Input_Action_Added{}), id = skald.hash_id("input-add"),
				font_size = th.font.size_sm, padding = {th.spacing.sm, 2}, disabled = d.newActionName == "" || newProblem != ""),
			spacing = th.spacing.xs, cross_align = .Center,
		),
		skald.text(newProblem, th.color.danger, th.font.size_xs),
		small(ctx, "input-defaults", "Add the default ui_ actions", Msg(Input_Defaults_Added{})),
	)

	fields := make([dynamic]skald.View, context.temp_allocator)
	append(&fields, skald.text("Actions are named inputs that keys, mouse buttons and gamepads trigger. Scripts ask about them: e.Input_IsActionPressed(\"jump\"), e.Input_IsActionJustPressed, e.Input_GetVector(\"ui_left\", \"ui_right\", \"ui_up\", \"ui_down\").",
		th.color.fg_muted, th.font.size_xs, max_width = 320))
	if d.selectedAction >= 0 && d.selectedAction < len(d.actions) {
		a := &d.actions[d.selectedAction]
		nameId := skald.hash_id("input-name")
		typing := skald.widget_has_focus(ctx, nameId) && d.renameText != "" && d.renameText != a.name
		problem := typing ? ActionNameProblem(d.actions[:], d.selectedAction, d.renameText) : ""
		append(&fields,
			settingRow(ctx, "Name", skald.text_input(ctx, strings.clone(typing ? d.renameText : a.name, context.temp_allocator),
				proc(v: string) -> Msg { return Input_Action_Renamed(v) }, id = nameId, width = 170, invalid = problem != "")),
			skald.text(problem, th.color.danger, th.font.size_xs),
			settingRow(ctx, "Deadzone", valueSlider(ctx, "input-deadzone", a.deadzone, struct {}{},
				proc(_: struct {}, v: f32) -> Msg { return Input_Deadzone_Changed(v) }, 0, 0.99, step = 0.01, decimals = 2,
				defaultValue = e.DEFAULT_ACTION_DEADZONE, width = 200)),
			skald.text("How far a stick or trigger must move to count.", th.color.fg_muted, th.font.size_xs),
			skald.spacer(th.spacing.xs),
			skald.text("Triggered by", th.color.fg, th.font.size_sm),
		)
		for binding, i in a.bindings {
			append(&fields, skald.row(
				skald.col(skald.text(e.InputBinding_Describe(binding), th.color.fg, th.font.size_sm), width = 200),
				small(ctx, fmt.tprintf("input-binding-remove-%d", i), ICON_TRASH, Msg(Input_Binding_Removed(i))),
				spacing = th.spacing.sm, cross_align = .Center,
			))
		}
		if len(a.bindings) == 0 do append(&fields, skald.text("Nothing yet: add a key or button below.", th.color.fg_muted, th.font.size_xs))

		capture := d.capturing ? "Press a key, mouse button or wheel... (Escape cancels)" : fmt.tprintf("%s  Press a key or button", ICON_PLUS)
		modifiers := ctx.input.modifiers
		append(&fields,
			skald.spacer(th.spacing.xs),
			skald.button(ctx, capture, d.capturing ? Msg(Input_Capture_Cancelled{}) : Msg(Input_Capture_Started(modifiers)), id = skald.hash_id("input-capture"),
				bg = d.capturing ? th.color.primary : th.color.surface, fg = d.capturing ? th.color.on_primary : th.color.fg,
				font_size = th.font.size_sm, padding = {th.spacing.sm, 3}),
		)
		names :: proc($E: typeid) -> []string {
			list := make([dynamic]string, context.temp_allocator)
			for name in reflect.enum_field_names(E) do if name != "Unknown" do append(&list, name)
			return list[:]
		}
		axes := make([dynamic]string, context.temp_allocator)
		for name in reflect.enum_field_names(e.GamepadAxis) {
			append(&axes, fmt.tprintf("%s −", name), fmt.tprintf("%s +", name))
		}
		devices := []string{"Any gamepad", "Gamepad 1", "Gamepad 2", "Gamepad 3", "Gamepad 4"}
		append(&fields,
			settingRow(ctx, "Key", skald.select(ctx, "", names(e.Key), proc(v: string) -> Msg {
				k, _ := reflect.enum_from_name(e.Key, v)
				return Input_Binding_Added{e.KeyBinding{k}}
			}, id = skald.hash_id("input-add-key"), width = 170, placeholder = "Add a key")),
			settingRow(ctx, "Mouse", skald.select(ctx, "", names(e.MouseButton), proc(v: string) -> Msg {
				b, _ := reflect.enum_from_name(e.MouseButton, v)
				return Input_Binding_Added{e.MouseBinding{b}}
			}, id = skald.hash_id("input-add-mouse"), width = 170, placeholder = "Add a mouse button")),
			settingRow(ctx, "Gamepad", skald.select(ctx, "", names(e.GamepadButton), d.bindingDevice, proc(device: int, v: string) -> Msg {
				b, _ := reflect.enum_from_name(e.GamepadButton, v)
				return Input_Binding_Added{e.GamepadButtonBinding{b, device}}
			}, id = skald.hash_id("input-add-gamepad"), width = 170, placeholder = "Add a gamepad button")),
			settingRow(ctx, "Stick, trigger", skald.select(ctx, "", axes[:], d.bindingDevice, proc(device: int, v: string) -> Msg {
				name, _, sign := strings.partition(v, " ")
				axis, _ := reflect.enum_from_name(e.GamepadAxis, name)
				return Input_Binding_Added{e.GamepadAxisBinding{axis, sign == "−" ? -1 : 1, device}}
			}, id = skald.hash_id("input-add-axis"), width = 170, placeholder = "Add a stick direction")),
			settingRow(ctx, "For", skald.select(ctx, devices[clamp(d.bindingDevice + 1, 0, len(devices) - 1)], devices, proc(v: string) -> Msg {
				for name, i in ([]string{"Any gamepad", "Gamepad 1", "Gamepad 2", "Gamepad 3", "Gamepad 4"}) do if name == v do return Input_Device_Changed(i - 1)
				return {}
			}, id = skald.hash_id("input-device"), width = 170)),
			skald.text("The gamepad new gamepad bindings are for: Any (most games), or one, for local multiplayer. Sticks: − is left or up, + right or down.",
				th.color.fg_muted, th.font.size_xs, max_width = 320),
		)
	}
	return skald.row(
		skald.col(skald.flex(1, skald.scroll(ctx, {0, 0}, skald.col(..list[:], spacing = th.spacing.xs, cross_align = .Start), id = skald.hash_id("input-list-scroll"))),
			width = 230, cross_align = .Stretch),
		skald.flex(1, skald.scroll(ctx, {0, 0}, skald.col(..fields[:], spacing = th.spacing.sm, padding = th.spacing.xs, cross_align = .Start),
			id = skald.hash_id("input-fields-scroll"))),
		spacing = th.spacing.md,
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
	} else if _, hasEmsdk := Toolchain_EmsdkDir(); target == .Web && !hasEmsdk {
		status, statusColor = "Needs Emscripten: the first web export installs it (about 1 GB, once), or Settings > Toolchain > Install Emscripten.", th.color.warning
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

// The sound output's sample rate and channels (keys project-settings-audio-rate, -channels)
@(private="file")
audioOutputSelects :: proc(ctx: ^skald.Ctx(Msg), output: e.AudioOutputSettings) -> skald.View {
	rate := output.frequency == 0 ? AUDIO_OWN : fmt.tprintf("%d Hz", output.frequency)
	channels := output.channels == 0 ? AUDIO_OWN : output.channels == 1 ? "Mono" : output.channels == 2 ? "Stereo" : fmt.tprintf("%d channels", output.channels)
	return skald.row(
		skald.select(ctx, rate, []string{"48000 Hz", "44100 Hz", AUDIO_OWN},
			proc(v: string) -> Msg { return Project_Settings_Audio_Changed{false, v == AUDIO_OWN ? 0 : v == "44100 Hz" ? 44100 : 48000} },
			id = skald.hash_id("project-settings-audio-rate"), width = 140),
		skald.select(ctx, channels, []string{"Stereo", "Mono", AUDIO_OWN},
			proc(v: string) -> Msg { return Project_Settings_Audio_Changed{true, v == AUDIO_OWN ? 0 : v == "Mono" ? 1 : 2} },
			id = skald.hash_id("project-settings-audio-channels"), width = 140),
		spacing = ctx.theme.spacing.sm,
	)
}

// The choice for the device's native format
AUDIO_OWN :: "The device's own"

// One of the window's settings as a checkbox (key project-settings-window-<field>)
@(private="file")
windowFlag :: proc(ctx: ^skald.Ctx(Msg), label: string, field: WindowField, value: bool) -> skald.View {
	return skald.checkbox(ctx, value, label, field,
		proc(field: WindowField, value: bool) -> Msg { return Project_Settings_Window_Changed{field, value} },
		id = skald.hash_id(fmt.tprintf("project-settings-window-%v", field)))
}

// What the Language setting does, and the languages the project's translation tables have
@(private="file")
localeNote :: proc(s: ^State) -> string {
	tables := 0
	for asset in s.project.assets do if asset.kind == .Translation do tables += 1
	if tables == 0 do return "The language the game starts in, from its translation tables (CSV assets: import one). Empty: the player's system language."
	return fmt.tprintf("The language the game starts in, as the translation tables name it (%d table%s in the project). Empty: the player's system language when a table has it, else the tables' first.", tables, tables == 1 ? "" : "s")
}

// The window icon: one of the project's images, or None (the engine's Crossfire logo)
@(private="file")
iconSelect :: proc(ctx: ^skald.Ctx(Msg), s: ^State, icon: string) -> skald.View {
	images := make([dynamic]string, context.temp_allocator)
	append(&images, TEXTURE_NONE)
	for asset in s.project.assets do if asset.kind == .Image do append(&images, asset.path)
	return skald.select(ctx, icon == "" ? TEXTURE_NONE : strings.clone(icon, context.temp_allocator), images[:],
		proc(v: string) -> Msg { return Project_Settings_Icon_Changed(v) },
		id = skald.hash_id("project-settings-icon"), width = 260)
}
