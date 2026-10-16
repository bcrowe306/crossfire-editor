package editor

import "core:fmt"
import "core:strings"
import "gui:skald"

/*
The Settings dialog (Edit > Settings, Ctrl+,): three tabs over a draft of the settings.

	Appearance   theme, text size, spacing, tree row height
	Editor       undo merging (debounce and throttle) and history length
	Keyboard     every action's two shortcuts: click one, then press the new keys

Footer: reset the open tab to its defaults, Cancel, Apply (keep the dialog open), Save.

Widget keys for UI tests: `settings-dialog`, tabs `settings-tab-<Tab>`, `settings-search`,
shortcut buttons `settings-key-<Action>-<slot>` (slot 0 or 1), `settings-reset-<Action>`,
`settings-reset-tab`, `settings-cancel`, `settings-apply`, `settings-save`.
*/
settingsDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	dialog := &s.settingsDialog
	if dialog.open && dialog.capture.active do captureKey(ctx)

	content: skald.View
	if dialog.open {
		switch dialog.tab {
		case .Appearance: content = appearanceTab(s, ctx)
		case .Editor:     content = editorTab(s, ctx)
		case .Keyboard:   content = keyboardTab(s, ctx)
		}
	}

	tabs := make([dynamic]skald.View, context.temp_allocator)
	for tab in SettingsTab {
		active := tab == dialog.tab
		append(&tabs, skald.button(ctx, fmt.tprintf("%v", tab), Msg(Settings_Tab_Changed(int(tab))),
			id = skald.hash_id(fmt.tprintf("settings-tab-%v", tab)),
			bg = active ? th.color.primary : th.color.surface,
			fg = active ? th.color.on_primary : th.color.fg,
			font_size = th.font.size_sm))
	}

	return skald.dialog(ctx,
		open = dialog.open,
		on_dismiss = proc() -> Msg { return Settings_Cancelled{} },
		content = skald.col(
			skald.text("Settings", th.color.fg, th.font.size_lg),
			skald.row(..tabs[:], spacing = th.spacing.xs),
			skald.divider(ctx),
			// flex: the Keyboard tab's list flexes inside the content, which would otherwise be
			// content-sized and give it no height
			skald.col(skald.flex(1, content), height = 380, cross_align = .Stretch),
			skald.divider(ctx),
			skald.row(
				skald.button(ctx, "Reset to Defaults", Msg(Settings_Tab_Reset{}), id = skald.hash_id("settings-reset-tab"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(Settings_Cancelled{}), id = skald.hash_id("settings-cancel"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, "Apply", Msg(Settings_Applied{close = false}), id = skald.hash_id("settings-apply"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, "Save", Msg(Settings_Applied{close = true}), id = skald.hash_id("settings-save"),
					font_size = th.font.size_sm),
				spacing = th.spacing.sm,
				cross_align = .Center,
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("settings-dialog"),
		width = 640,
		max_width = 640,
	)
}

// While a shortcut button waits for keys: the first key pressed (with the held modifiers) binds
// it, Escape cancels. The keys are taken out of this frame's input so nothing else reacts to
// them, including the dialog (Escape) and the focused button (Enter, Space)
@(private="file")
captureKey :: proc(ctx: ^skald.Ctx(Msg)) {
	pressed := ctx.input.keys_pressed
	if pressed == {} do return
	ctx.input.keys_pressed = {}
	ctx.input.text = ""
	if .Escape in pressed && ctx.input.modifiers == {} {
		skald.send(ctx, Msg(Settings_Capture_Cancelled{}))
		return
	}
	for key in skald.Key {
		if key not_in pressed do continue
		chord := skald.Shortcut{key, ctx.input.modifiers}
		// Plain Backspace is Skald's "no shortcut"
		if chord == {} do continue
		skald.send(ctx, Msg(Settings_Key_Captured(chord)))
		return
	}
}

@(private="file")
appearanceTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	draft := &s.settingsDialog.draft
	return skald.col(
		settingRow(ctx, "Theme", skald.select(ctx, draft.theme == .Light ? "Light" : "Dark", []string{"Dark", "Light"},
			proc(v: string) -> Msg { return Settings_Theme_Changed(v) },
			id = skald.hash_id("settings-theme"), width = 140)),
		settingRow(ctx, "Text size", numberSetting(ctx, s, .Font_Size, f64(draft.fontSize), 1, SETTINGS_FONT_SIZE_RANGE, "px")),
		hint(ctx, "Body text, in pixels. Headings and small text scale with it."),
		settingRow(ctx, "Spacing", numberSetting(ctx, s, .Spacing, f64(draft.spacing), 5, SETTINGS_SPACING_RANGE, "%")),
		hint(ctx, "Padding and gaps between controls, as a percentage of Skald's default."),
		settingRow(ctx, "Row height", numberSetting(ctx, s, .Row_Height, f64(draft.rowHeight), 1, SETTINGS_ROW_HEIGHT_RANGE, "px")),
		hint(ctx, "Rows in the project browser and scene tree."),
		skald.spacer(th.spacing.sm),
		hint(ctx, "Changes show when you press Apply or Save."),
		spacing = th.spacing.sm,
		padding = th.spacing.sm,
		cross_align = .Stretch,
	)
}

@(private="file")
editorTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	draft := &s.settingsDialog.draft
	msRange :: [2]f32{f32(SETTINGS_UNDO_MS_RANGE[0]), f32(SETTINGS_UNDO_MS_RANGE[1])}
	limitRange :: [2]f32{f32(SETTINGS_UNDO_LIMIT_RANGE[0]), f32(SETTINGS_UNDO_LIMIT_RANGE[1])}
	gridRange :: [2]f32{f32(SETTINGS_GRID_SIZE_RANGE[0]), f32(SETTINGS_GRID_SIZE_RANGE[1])}
	// Scrolls: the Scripts settings at the bottom don't fit the dialog's height
	content := skald.col(
		skald.text("Undo", th.color.fg, th.font.size_md),
		settingRow(ctx, "Merge edits within", numberSetting(ctx, s, .Undo_Merge_Ms, f64(draft.undoMergeMs), 50, msRange, "ms")),
		hint(ctx, "Edits to the same thing closer together than this undo as one step: typing a name, dragging a number, nudging with the arrow keys."),
		settingRow(ctx, "Longest merged edit", numberSetting(ctx, s, .Undo_Group_Max_Ms, f64(draft.undoGroupMaxMs), 250, msRange, "ms")),
		hint(ctx, "A long run of merged edits is still cut into steps this long. 0 never cuts. Dragging in the viewport is always one step."),
		settingRow(ctx, "Undo steps kept", numberSetting(ctx, s, .Undo_Limit, f64(draft.undoLimit), 10, limitRange, "")),
		skald.spacer(th.spacing.sm),
		skald.text("Viewport", th.color.fg, th.font.size_md),
		settingRow(ctx, "Grid size", numberSetting(ctx, s, .Grid_Size, f64(draft.gridSize), 8, gridRange, "px")),
		hint(ctx, "Spacing of the viewport grid, in world units. G shows it; Shift+G snaps moves to it (and rotation to 15°, scale to 0.1)."),
		skald.spacer(th.spacing.sm),
		skald.text("Scripts", th.color.fg, th.font.size_md),
		// Copies: the draft is inside this frame's copy of the state, which is gone by the time
		// Skald draws the fields (they showed garbage, and editing saved garbage)
		settingRow(ctx, "Editor program", skald.row(
			skald.text_input(ctx, strings.clone(FixedText_String(&draft.codeEditorPath), context.temp_allocator),
				proc(v: string) -> Msg { return Settings_Code_Editor_Path_Changed(v) },
				id = skald.hash_id("settings-code-editor-path"), width = 230, placeholder = "zed"),
			skald.button(ctx, "Browse...", Msg(Settings_Code_Editor_Browse{}), id = skald.hash_id("settings-code-editor-browse"),
				bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm, padding = {th.spacing.sm, 2}),
			spacing = th.spacing.xs,
			cross_align = .Center,
		)),
		editorProgramStatus(ctx, FixedText_String(&draft.codeEditorPath)),
		settingRow(ctx, "Arguments", skald.text_input(ctx, strings.clone(FixedText_String(&draft.codeEditorArgs), context.temp_allocator),
			proc(v: string) -> Msg { return Settings_Code_Editor_Args_Changed(v) },
			id = skald.hash_id("settings-code-editor-args"), width = 300, placeholder = "{file}:{line}")),
		hint(ctx, "{file} and {line} are replaced; without {file}, the file is added at the end. Zed: {file}:{line}. VS Code: --goto {file}:{line}. It runs in the project's scripts folder, with the editor's environment."),
		settingRow(ctx, "Optimized Play", skald.checkbox(ctx, draft.optimizedPlay, "Build with -o:speed",
			proc(v: bool) -> Msg { return Settings_Optimized_Play_Changed(v) },
			id = skald.hash_id("settings-optimized-play"))),
		hint(ctx, "Faster games, but each build takes about 50 s instead of 4. Exports are always optimized."),
		spacing = th.spacing.sm,
		padding = th.spacing.sm,
		cross_align = .Stretch,
	)
	return skald.scroll(ctx, {0, 0}, content, id = skald.hash_id("settings-editor-scroll"))
}

@(private="file")
keyboardTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	dialog := &s.settingsDialog
	draft := &dialog.draft

	rows := make([dynamic]skald.View, context.temp_allocator)
	for action in Action {
		chords := draft.keymap[action]
		label := ACTION_LABELS[action]
		if !matchesSearch(label, dialog.search) && !matchesSearch(Keymap_FormatChords(chords), dialog.search) do continue

		buttons := make([dynamic]skald.View, context.temp_allocator)
		append(&buttons, skald.col(skald.text(label, th.color.fg, th.font.size_sm), width = 210))
		for slot in 0..<KEYMAP_SLOTS {
			capturing := dialog.capture.active && dialog.capture.action == action && dialog.capture.slot == slot
			text := capturing ? "Press keys..." : chords[slot] == {} ? "-" : skald.shortcut_format(chords[slot])
			append(&buttons, skald.button(ctx, text, Msg(Settings_Capture_Started{action, slot}),
				id = skald.hash_id(fmt.tprintf("settings-key-%v-%d", action, slot)),
				width = 120, font_size = th.font.size_sm,
				bg = capturing ? th.color.primary : th.color.surface,
				fg = capturing ? th.color.on_primary : chords[slot] == {} ? th.color.fg_muted : th.color.fg))
		}
		append(&buttons, skald.button(ctx, ICON_UNDO, Msg(Settings_Key_Reset(action)),
			id = skald.hash_id(fmt.tprintf("settings-reset-%v", action)),
			width = 28, font_size = th.font.size_sm, bg = th.color.surface, fg = th.color.fg_muted))
		append(&rows, skald.row(..buttons[:], spacing = th.spacing.xs, cross_align = .Center))

		// The same chord on another action: the first in the list wins
		for chord in chords {
			if other, used := Keymap_FindChord(&draft.keymap, chord, action); used {
				append(&rows, skald.text(fmt.tprintf("    %s is also %s", skald.shortcut_format(chord), ACTION_LABELS[other]),
					th.color.warning, th.font.size_xs))
			}
		}
	}
	if len(rows) == 0 {
		append(&rows, skald.text(fmt.tprintf("No shortcuts match '%s'", dialog.search), th.color.fg_muted, th.font.size_sm))
	}

	help := dialog.capture.active ? "Press the new shortcut, or Escape to cancel." :
		"Click a shortcut, then press the new keys. The arrow resets a row; a shortcut can be cleared while it waits for keys."
	footer: skald.View = skald.text(help, th.color.fg_muted, th.font.size_xs)
	if dialog.capture.active {
		footer = skald.row(
			skald.flex(1, skald.text(help, th.color.fg_muted, th.font.size_xs)),
			skald.button(ctx, "Clear", Msg(Settings_Key_Cleared{dialog.capture.action, dialog.capture.slot}),
				id = skald.hash_id("settings-key-clear"), font_size = th.font.size_sm, bg = th.color.surface, fg = th.color.fg),
			spacing = th.spacing.sm,
			cross_align = .Center,
		)
	}

	return skald.col(
		skald.row(skald.flex(1, skald.text_input(ctx, dialog.search,
			proc(v: string) -> Msg { return Settings_Search_Changed(v) },
			id = skald.hash_id("settings-search"),
			placeholder = "Search actions and shortcuts",
			clear_button = true))),
		skald.flex(1, skald.scroll(ctx, {0, 0},
			skald.col(..rows[:], spacing = 2, cross_align = .Stretch),
			id = skald.hash_id("settings-keys-scroll"))),
		footer,
		spacing = th.spacing.sm,
		padding = th.spacing.sm,
		cross_align = .Stretch,
	)
}

// "Label     [control]"
@(private="file")
settingRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	th := ctx.theme
	return skald.row(
		skald.col(skald.text(label, th.color.fg, th.font.size_sm), width = 170),
		control,
		spacing = th.spacing.sm,
		cross_align = .Center,
	)
}

@(private="file")
numberSetting :: proc(ctx: ^skald.Ctx(Msg), s: ^State, field: SettingsField, value, step: f64, limits: [2]f32, unit: string) -> skald.View {
	th := ctx.theme
	return skald.row(
		numberField(ctx, s, fmt.tprintf("settings-%v", field), field, value, step, 0, 130, f64(limits[0]), f64(limits[1])),
		skald.text(unit, th.color.fg_muted, th.font.size_sm),
		spacing = th.spacing.xs,
		cross_align = .Center,
	)
}

@(private="file")
hint :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
	th := ctx.theme
	return skald.text(text, th.color.fg_muted, th.font.size_xs, max_width = 560)
}

// Under the program field: where it resolves to, or that it can't be found
@(private="file")
editorProgramStatus :: proc(ctx: ^skald.Ctx(Msg), program: string) -> skald.View {
	th := ctx.theme
	resolved, found := Script_FindEditorProgram(program)
	if !found {
		return skald.text(fmt.tprintf("Not found: %s", program == "" ? DEFAULT_CODE_EDITOR_PATH : program), th.color.warning, th.font.size_xs, max_width = 560)
	}
	return skald.text(fmt.tprintf("Runs %s", resolved), th.color.fg_muted, th.font.size_xs, max_width = 560)
}
