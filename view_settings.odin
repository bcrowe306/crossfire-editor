package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strings"
import "gui:skald"

/*
The Settings dialog (Edit > Settings, Ctrl+,): tabs over a draft of the settings.

	Appearance   theme, text size, spacing, tree row height
	Editor       undo merging (debounce and throttle) and history length, code editor, Play
	Keyboard     every action's two shortcuts: click one, then press the new keys
	Toolchain    what building games needs, found or not, and installing Odin
	Project      the Project Settings dialog's tabs (General, Input, Globals, Export), on its draft

Footer: reset the open tab to its defaults (not on Project), Cancel, Apply (keep the dialog open),
Save. Apply and Save also apply the Project tab's changes once it was opened (one undoable step);
Cancel drops them.

Widget keys for UI tests: `settings-dialog`, tabs `settings-tab-<Tab>`, `settings-search`,
shortcut buttons `settings-key-<Action>-<slot>` (slot 0 or 1), `settings-reset-<Action>`,
`settings-reset-tab`, `settings-cancel`, `settings-apply`, `settings-save`.
*/
settingsDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	// Closed: no content (its buttons would stay clickable where they were drawn: closedDialog)
	if !s.settingsDialog.open do return closedDialog(ctx, "settings-dialog")
	// An input action (its Project tab) dragged into code: hidden meanwhile (code_drag.odin)
	if CodeDrag_HidesDialogs(s) do return closedDialog(ctx, "settings-dialog")
	th := ctx.theme
	dialog := &s.settingsDialog
	if dialog.open && dialog.capture.active do captureKey(ctx)
	// The row the command palette asked for: lit (settingRow), and scrolled into view once laid out
	settingsHighlight = dialog.highlight
	if settingsRevealWanted do settingsReveal(ctx, dialog.tab)

	content: skald.View
	if dialog.open {
		switch dialog.tab {
		case .Appearance: content = appearanceTab(s, ctx)
		case .Editor:     content = editorTab(s, ctx)
		case .Keyboard:   content = keyboardTab(s, ctx)
		case .Toolchain:  content = toolchainTab(s, ctx)
		case .Project:    content = projectTab(s, ctx)
		}
	}
	// The project's Input and Export tabs are laid out for the Project Settings dialog's width
	width: f32 = dialog.tab == .Project && s.projectSettings.tab != .General ? tk.dialogWide : tk.dialogSettings

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
			uiText(th, .Title, "Settings"),
			skald.row(..tabs[:], spacing = th.spacing.xs),
			skald.divider(ctx),
			// flex: the Keyboard tab's list flexes inside the content, which would otherwise be
			// content-sized and give it no height
			// 380 px, less in a short window so the buttons below stay on screen (the title, tabs
			// and footer take about 220 px: Save was off a 500 px window)
			skald.col(skald.flex(1, content), height = ctx.renderer != nil ? clamp(f32(ctx.renderer.fb_size.y) - 220, 160, 380) : 380, cross_align = .Stretch),
			skald.divider(ctx),
			skald.row(
				dialog.tab == .Project ? skald.spacer(0) : skald.button(ctx, "Reset to Defaults", Msg(Settings_Tab_Reset{}), id = skald.hash_id("settings-reset-tab"),
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
		width = width,
		max_width = width,
	)
}

// The Project tab: the Project Settings dialog's own tabs, on its draft
@(private="file")
projectTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	if !s.projectSettings.open do return skald.spacer(0)
	tabs, body := ProjectSettings_TabsView(s, ctx)
	return skald.col(
		tabs,
		skald.flex(1, body),
		spacing = th.spacing.sm,
		cross_align = .Stretch,
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
		// Stored the keymap's way: Cmd+S pressed on a Mac is "Ctrl+S"
		chord := Chord_FromPlatform(skald.Shortcut{key, ctx.input.modifiers})
		// Plain Backspace is Skald's "no shortcut"
		if chord == {} do continue
		skald.send(ctx, Msg(Settings_Key_Captured(chord)))
		return
	}
}

/*
The editor's look: a preset to start from, the base theme, text size, spacing, row height, corners,
and every theme color (editor_theme.odin). Changes show at once; Cancel puts the old look back.

Widget keys: `settings-preset`, `settings-theme`, `settings-color-<key>` (a color's picker: bg,
surface... as editor.ini names them, the Viewport section's viewport_bg, viewport_grid... too)
and `settings-color-reset-<key>`, `settings-<field>`.
*/
@(private="file")
appearanceTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	draft := &s.settingsDialog.draft
	current := Settings_Theme(draft)
	presets := make([dynamic]string, context.temp_allocator)
	for p in THEME_PRESETS do append(&presets, p.name)
	preset := EditorTheme_PresetName(draft)
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows,
		settingRow(ctx, "Preset", skald.select(ctx, preset == "" ? "Custom" : preset, presets[:],
			proc(v: string) -> Msg { return Settings_Theme_Preset_Chosen(v) },
			id = skald.hash_id("settings-preset"), width = tk.fieldM)),
		hint(ctx, "A look to start from. Choosing one replaces the colors below; change any of them after."),
		settingRow(ctx, "Theme", skald.select(ctx, draft.theme == .Light ? "Light" : "Dark", []string{"Dark", "Light"},
			proc(v: string) -> Msg { return Settings_Theme_Changed(v) },
			id = skald.hash_id("settings-theme"), width = tk.fieldM)),
		hint(ctx, "The base: the colors you haven't set are its."),
		settingRow(ctx, "Text size", numberSetting(ctx, s, .Font_Size, f64(draft.fontSize), 1, SETTINGS_FONT_SIZE_RANGE, "px")),
		hint(ctx, "Body text, in pixels. Headings and small text scale with it."),
		settingRow(ctx, "Spacing", numberSetting(ctx, s, .Spacing, f64(draft.spacing), 5, SETTINGS_SPACING_RANGE, "%")),
		hint(ctx, "Padding and gaps between controls, as a percentage of Skald's default."),
		settingRow(ctx, "Row height", numberSetting(ctx, s, .Row_Height, f64(draft.rowHeight), 1, SETTINGS_ROW_HEIGHT_RANGE, "px")),
		hint(ctx, "Rows in the project browser and scene tree (shows when you press Apply or Save)."),
		settingRow(ctx, "Corners", numberSetting(ctx, s, .Corner_Radius, f64(draft.cornerRadius), 25, SETTINGS_CORNER_RADIUS_RANGE, "%")),
		hint(ctx, "How round the corners of buttons, fields and panels are: 0 is square, 100 Skald's own."),
		skald.divider(ctx),
		uiSection(th, tk, "Colors"),
		hint(ctx, "Click a color to change it; the editor shows it at once. The ↶ beside a color you've set puts the theme's back."),
	)
	// Text that would be hard to read (editor_theme.odin's contrast check): the ratio, and a fix
	for p in EditorTheme_ContrastProblems(&current) {
		textKey, backKey := THEME_COLOR_KEYS[p.pair.text], THEME_COLOR_KEYS[p.pair.back]
		warning := fmt.tprintf("%s  %s on %s is hard to read: %.1f:1 (text needs %.1f:1). Try %s.", ICON_WARNING,
			THEME_COLOR_LABELS[p.pair.text], strings.to_lower(THEME_COLOR_LABELS[p.pair.back], context.temp_allocator), p.ratio, CONTRAST_TEXT_MIN, ThemeColor_Format(p.suggestion))
		fix := skald.button(ctx, "Use it", Msg(Settings_Theme_Color_Changed{p.pair.text, p.suggestion}),
			id = skald.hash_id(fmt.tprintf("settings-contrast-fix-%s-%s", textKey, backKey)), padding = tk.buttonPadding, font_size = th.font.size_xs)
		append(&rows, skald.row(uiText(th, .Muted, warning, max_width = tk.textMeasure, color = th.color.warning), fix, spacing = tk.buttonGap, cross_align = .Center))
	}
	for which in ThemeColor {
		key := THEME_COLOR_KEYS[which]
		color := ThemeColor_Field(&current.color, which)^
		picker := skald.color_picker(ctx, color, which, proc(w: ThemeColor, c: skald.Color) -> Msg { return Settings_Theme_Color_Changed{w, c} },
			id = skald.hash_id(fmt.tprintf("settings-color-%s", key)), width = tk.fieldM)
		reset: skald.View = skald.spacer(0)
		if which in draft.themeColorsSet {
			reset = skald.tooltip(ctx, skald.button(ctx, ICON_UNDO, Msg(Settings_Theme_Color_Reset(which)), id = skald.hash_id(fmt.tprintf("settings-color-reset-%s", key)),
				width = tk.panelButtonWidth, font_size = th.font.size_sm, bg = th.color.surface, fg = th.color.fg_muted),
				"Back to the theme's color", id = skald.hash_id(fmt.tprintf("settings-color-reset-tip-%s", key)))
		}
		append(&rows, settingRow(ctx, THEME_COLOR_LABELS[which], skald.row(picker, reset, spacing = th.spacing.xs, cross_align = .Center)))
	}
	append(&rows,
		settingRow(ctx, "Selection opacity", numberSetting(ctx, s, .Selection_Opacity, f64(math.round(current.color.selection[3] * 100)), 5, {0, 100}, "%")),
		skald.divider(ctx),
		uiSection(th, tk, "Viewport"),
		hint(ctx, "The viewport's and the Level canvas's colors: around the game area, the grid (the project's opacities apply to it), the game frame, the selection, the gizmo and the guides. The ↶ puts the default back."),
	)
	viewportColors := ViewportColors_Of(draft, &current)
	for which in ViewportColor {
		key := VIEWPORT_COLOR_KEYS[which]
		picker := skald.color_picker(ctx, viewportColors[which], which, proc(w: ViewportColor, c: skald.Color) -> Msg { return Settings_Viewport_Color_Changed{w, c} },
			id = skald.hash_id(fmt.tprintf("settings-color-%s", key)), width = tk.fieldM)
		reset: skald.View = skald.spacer(0)
		if which in draft.viewportColorsSet {
			reset = skald.tooltip(ctx, skald.button(ctx, ICON_UNDO, Msg(Settings_Viewport_Color_Reset(which)), id = skald.hash_id(fmt.tprintf("settings-color-reset-%s", key)),
				width = tk.panelButtonWidth, font_size = th.font.size_sm, bg = th.color.surface, fg = th.color.fg_muted),
				"Back to the default color", id = skald.hash_id(fmt.tprintf("settings-color-reset-tip-%s", key)))
		}
		append(&rows, settingRow(ctx, VIEWPORT_COLOR_LABELS[which], skald.row(picker, reset, spacing = th.spacing.xs, cross_align = .Center)))
	}
	append(&rows,
		skald.spacer(th.spacing.sm),
		hint(ctx, "Changes show at once. Apply or Save keeps them (in editor.ini); Cancel puts the old look back."),
	)
	content := skald.col(..rows[:], spacing = th.spacing.sm, padding = th.spacing.sm, cross_align = .Stretch)
	return skald.scroll(ctx, {0, 0}, content, id = skald.hash_id("settings-appearance-scroll"))
}

/*
What building games needs (toolchain.odin's Toolchain_Check): each tool found or not, where, and
what to do about a missing one; the odin path; Install Odin (the pinned release, into the editor's
data folder). Widget keys: `settings-odin-path`, `settings-install-odin`.
*/
@(private="file")
toolchainTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	draft := &s.settingsDialog.draft
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, uiSection(th, tk, "Building games"),
		hint(ctx, "Play and Export compile your game with Odin. A project without scripts needs no compiler when the editor has a prebuilt player for it."))
	for tool in Toolchain_Check(draft) {
		mark := tool.found ? ICON_CHECK : ICON_XMARK
		color := tool.found ? th.color.success : th.color.danger
		lines := make([dynamic]skald.View, context.temp_allocator)
		append(&lines, uiText(th, .Value, tool.name))
		if tool.path != "" do append(&lines, uiText(th, .Muted, tool.path, max_width = tk.textMeasure))
		append(&lines, uiText(th, .Muted, tool.note, max_width = tk.textMeasure))
		append(&rows, skald.row(
			skald.col(skald.text(mark, color, th.font.size_md), width = tk.iconColumn),
			skald.col(..lines[:], spacing = tk.hair),
			spacing = th.spacing.sm,
		))
	}
	append(&rows, uiSection(th, tk, "Odin"),
		settingRow(ctx, "Odin program", skald.text_input(ctx, strings.clone(FixedText_String(&draft.odinPath), context.temp_allocator),
			proc(v: string) -> Msg { return Settings_Odin_Path_Changed(v) },
			id = skald.hash_id("settings-odin-path"), width = tk.fieldXL, placeholder = "odin in PATH, else the installed one")))
	installed := Toolchain_InstalledOdin() != ""
	label := s.toolchainInstalling ? "Installing..." : installed ? fmt.tprintf("Odin %s is installed", ODIN_VERSION) : fmt.tprintf("%s  Install Odin %s", ICON_DOWNLOAD, ODIN_VERSION)
	append(&rows, settingRow(ctx, "", skald.button(ctx, label, Msg(Toolchain_Install_Requested{}), id = skald.hash_id("settings-install-odin"),
		disabled = s.toolchainInstalling || installed, bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm, padding = tk.fieldPadding)))
	append(&rows, hint(ctx, fmt.tprintf("Downloads the Odin release the engine uses (about 70 MB, from GitHub) into %s. It still needs the linker above.", Toolchain_DataDir())))
	_, hasEmsdk := Toolchain_EmsdkDir()
	_, hasMixer := Toolchain_SDLMixerDir()
	emscripten := hasEmsdk && hasMixer
	webLabel := s.emscriptenInstalling ? "Installing..." : emscripten ? fmt.tprintf("Emscripten %s is installed", EMSDK_VERSION) : fmt.tprintf("%s  Install Emscripten %s", ICON_DOWNLOAD, EMSDK_VERSION)
	append(&rows, uiSection(th, tk, "Web exports"),
		settingRow(ctx, "", skald.button(ctx, webLabel, Msg(Toolchain_Emscripten_Requested{}), id = skald.hash_id("settings-install-emscripten"),
			disabled = s.emscriptenInstalling || emscripten, bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm, padding = tk.fieldPadding)),
		hint(ctx, fmt.tprintf("Downloads Emscripten (about 1 GB; it needs Python) and SDL_mixer's sources into %s. The first web export does it too.", Toolchain_DataDir())))
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.sm, padding = th.spacing.sm, cross_align = .Stretch),
		id = skald.hash_id("settings-toolchain-scroll"))
}

@(private="file")
editorTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	draft := &s.settingsDialog.draft
	msRange :: [2]f32{f32(SETTINGS_UNDO_MS_RANGE[0]), f32(SETTINGS_UNDO_MS_RANGE[1])}
	limitRange :: [2]f32{f32(SETTINGS_UNDO_LIMIT_RANGE[0]), f32(SETTINGS_UNDO_LIMIT_RANGE[1])}
	consoleRange :: [2]f32{f32(SETTINGS_CONSOLE_LIMIT_RANGE[0]), f32(SETTINGS_CONSOLE_LIMIT_RANGE[1])}
	// Scrolls: the Scripts settings at the bottom don't fit the dialog's height
	content := skald.col(
		uiSection(th, tk, "Undo"),
		settingRow(ctx, "Merge edits within", numberSetting(ctx, s, .Undo_Merge_Ms, f64(draft.undoMergeMs), 50, msRange, "ms")),
		hint(ctx, "Edits to the same thing closer together than this undo as one step: typing a name, dragging a number, nudging with the arrow keys."),
		settingRow(ctx, "Longest merged edit", numberSetting(ctx, s, .Undo_Group_Max_Ms, f64(draft.undoGroupMaxMs), 250, msRange, "ms")),
		hint(ctx, "A long run of merged edits is still cut into steps this long. 0 never cuts. Dragging in the viewport is always one step."),
		settingRow(ctx, "Undo steps kept", numberSetting(ctx, s, .Undo_Limit, f64(draft.undoLimit), 10, limitRange, "")),
		skald.spacer(th.spacing.sm),
		uiSection(th, tk, "Console"),
		settingRow(ctx, "Console lines kept", numberSetting(ctx, s, .Console_Limit, f64(draft.consoleLimit), 500, consoleRange, "lines")),
		hint(ctx, "The Console and the Output tab each keep this many lines; the oldest are dropped."),
		skald.spacer(th.spacing.sm),
		uiSection(th, tk, "Viewport"),
		hint(ctx, "The grid is the project's: Project Settings > Grid (View > Grid Settings)."),
		skald.spacer(th.spacing.sm),
		uiSection(th, tk, "Scripts"),
		settingRow(ctx, "Code editor", skald.checkbox(ctx, draft.builtInCodeEditor, "Use the built-in code editor",
			proc(v: bool) -> Msg { return Settings_Builtin_Editor_Changed(v) },
			id = skald.hash_id("settings-builtin-editor"))),
		hint(ctx, "Scripts open in a tab next to the scenes, with Odin highlighting and, with the Odin language server, completion and diagnostics. Off: they open in the program below."),
		settingRow(ctx, "Auto-close", skald.checkbox(ctx, draft.autoClosePairs, "Close brackets and quotes as you type",
			proc(v: bool) -> Msg { return Settings_Auto_Close_Changed(v) },
			id = skald.hash_id("settings-auto-close"))),
		hint(ctx, "( [ { \" ' ` get their closer after the caret; typing the closer steps over it; Backspace removes an empty pair; Enter between brackets opens an indented line. < closes after a name (Map<), as it's \"less than\" elsewhere."),
		settingRow(ctx, "Language server", skald.text_input(ctx, strings.clone(FixedText_String(&draft.olsPath), context.temp_allocator),
			proc(v: string) -> Msg { return Settings_OLS_Path_Changed(v) },
			id = skald.hash_id("settings-ols-path"), width = tk.fieldXL, placeholder = "found automatically")),
		hint(ctx, olsStatus(FixedText_String(&draft.olsPath))),
		settingRow(ctx, "LDtk program", skald.text_input(ctx, strings.clone(FixedText_String(&draft.ldtkPath), context.temp_allocator),
			proc(v: string) -> Msg { return Settings_LDtk_Path_Changed(v) },
			id = skald.hash_id("settings-ldtk-path"), width = tk.fieldXL, placeholder = "ldtk in PATH")),
		hint(ctx, "The level editor (ldtk.io) that an LDtkLevel node's Open in LDtk starts."),
		settingRow(ctx, "Aseprite program", skald.text_input(ctx, strings.clone(FixedText_String(&draft.asepritePath), context.temp_allocator),
			proc(v: string) -> Msg { return Settings_Aseprite_Path_Changed(v) },
			id = skald.hash_id("settings-aseprite-path"), width = tk.fieldXL, placeholder = "aseprite in PATH")),
		hint(ctx, "The pixel art editor (aseprite.org) that Open in Aseprite starts on .aseprite files. Steam's copy works: point this at its aseprite program."),
		// Copies: the draft is inside this frame's copy of the state, which is gone by the time
		// Skald draws the fields (they showed garbage, and editing saved garbage)
		settingRow(ctx, "External program", skald.row(
			skald.text_input(ctx, strings.clone(FixedText_String(&draft.codeEditorPath), context.temp_allocator),
				proc(v: string) -> Msg { return Settings_Code_Editor_Path_Changed(v) },
				id = skald.hash_id("settings-code-editor-path"), width = tk.fieldL, placeholder = "zed"),
			skald.button(ctx, "Browse...", Msg(Settings_Code_Editor_Browse{}), id = skald.hash_id("settings-code-editor-browse"),
				bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm, padding = tk.fieldPadding),
			spacing = th.spacing.xs,
			cross_align = .Center,
		)),
		editorProgramStatus(ctx, FixedText_String(&draft.codeEditorPath)),
		settingRow(ctx, "Arguments", skald.text_input(ctx, strings.clone(FixedText_String(&draft.codeEditorArgs), context.temp_allocator),
			proc(v: string) -> Msg { return Settings_Code_Editor_Args_Changed(v) },
			id = skald.hash_id("settings-code-editor-args"), width = tk.fieldXL, placeholder = "{file}:{line}")),
		hint(ctx, "{file}, {line} and {folder} (the scripts folder) are replaced; without {file}, the file is added at the end. Opening {folder} as the workspace lets the Odin language server use scripts/ols.json for code completion. Zed: {folder} {file}:{line}. VS Code: {folder} --goto {file}:{line}."),
		settingRow(ctx, "Optimized Play", skald.checkbox(ctx, draft.optimizedPlay, "Build with -o:speed",
			proc(v: bool) -> Msg { return Settings_Optimized_Play_Changed(v) },
			id = skald.hash_id("settings-optimized-play"))),
		hint(ctx, "Faster games, but each build takes about 50 s instead of 4. Exports have their own Optimize setting (Project Settings > Export)."),
		settingRow(ctx, "Hot reload", skald.checkbox(ctx, draft.hotReload, "Restart the game where it was when scripts change",
			proc(v: bool) -> Msg { return Settings_Hot_Reload_Changed(v) },
			id = skald.hash_id("settings-hot-reload"))),
		hint(ctx, "Saving a script while the game plays builds it again in the background (the game goes on; build errors go to the Output tab), then restarts it in the same scene with its globals and every node's properties carried over. Things made while playing (bullets, spawned enemies) start over."),
		settingRow(ctx, "Wheel pans", skald.checkbox(ctx, draft.wheelPans, "The wheel pans the viewport; Ctrl + wheel zooms",
			proc(v: bool) -> Msg { return Settings_Wheel_Pans_Changed(v) },
			id = skald.hash_id("settings-wheel-pans"))),
		settingRow(ctx, "Rotation snap", numberSetting(ctx, s, .Rotate_Snap, f64(draft.rotateSnap), 1, SETTINGS_ROTATE_SNAP_RANGE, "°")),
		settingRow(ctx, "Scale snap", numberSetting(ctx, s, .Scale_Snap, f64(draft.scaleSnap), 0.05, SETTINGS_SCALE_SNAP_RANGE, "", decimals = 2)),
		hint(ctx, "The steps the viewport's Rotate and Scale drags snap to while snapping is on (the magnet, Shift+G) or Shift is held."),
		settingRow(ctx, "Audio device", audioDeviceSelect(ctx, FixedText_String(&draft.audioDevice))),
		hint(ctx, "Where Play's game and the editor's sound previews play: a device of this computer (exported games use the system's default; players can pick one with --audio-device). If it's missing, the default is used."),
		hint(ctx, "For touchpads (two-finger scrolling pans). Off: the wheel zooms, Shift + wheel pans sideways, Ctrl + wheel up and down. Sideways scrolling always pans; so do the Pan tool (H), a middle or right drag, and Space + drag."),
		spacing = th.spacing.sm,
		padding = th.spacing.sm,
		cross_align = .Stretch,
	)
	return skald.scroll(ctx, {0, 0}, content, id = skald.hash_id("settings-editor-scroll"))
}

@(private="file")
keyboardTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	dialog := &s.settingsDialog
	draft := &dialog.draft

	rows := make([dynamic]skald.View, context.temp_allocator)
	for action in Action {
		chords := draft.keymap[action]
		label := ACTION_LABELS[action]
		// By name, or by the keys as shown (Cmd+S on a Mac)
		shown := make([dynamic]string, context.temp_allocator)
		for chord in chords do if chord != {} do append(&shown, Chord_Format(chord))
		if !matchesSearch(label, dialog.search) && !matchesSearch(strings.join(shown[:], " | ", context.temp_allocator), dialog.search) do continue

		buttons := make([dynamic]skald.View, context.temp_allocator)
		append(&buttons, skald.col(uiText(th, .Value, label), width = tk.fieldL))
		for slot in 0..<KEYMAP_SLOTS {
			capturing := dialog.capture.active && dialog.capture.action == action && dialog.capture.slot == slot
			text := capturing ? "Press keys..." : chords[slot] == {} ? "-" : Chord_Format(chords[slot])
			append(&buttons, skald.button(ctx, text, Msg(Settings_Capture_Started{action, slot}),
				id = skald.hash_id(fmt.tprintf("settings-key-%v-%d", action, slot)),
				width = tk.fieldS, font_size = th.font.size_sm,
				bg = capturing ? th.color.primary : th.color.surface,
				fg = capturing ? th.color.on_primary : chords[slot] == {} ? th.color.fg_muted : th.color.fg))
		}
		append(&buttons, skald.button(ctx, ICON_UNDO, Msg(Settings_Key_Reset(action)),
			id = skald.hash_id(fmt.tprintf("settings-reset-%v", action)),
			width = tk.panelButtonWidth, font_size = th.font.size_sm, bg = th.color.surface, fg = th.color.fg_muted))
		append(&rows, skald.row(..buttons[:], spacing = th.spacing.xs, cross_align = .Center))

		// The same chord on another action: the first in the list wins
		for chord in chords {
			if other, used := Keymap_FindChord(&draft.keymap, chord, action); used {
				append(&rows, uiText(th, .Muted, fmt.tprintf("    %s is also %s", Chord_Format(chord), ACTION_LABELS[other]), color = th.color.warning))
			}
		}
	}
	if len(rows) == 0 {
		append(&rows, uiText(th, .Label, fmt.tprintf("No shortcuts match '%s'", dialog.search)))
	}

	help := dialog.capture.active ? "Press the new shortcut, or Escape to cancel." :
		"Click a shortcut, then press the new keys. The arrow resets a row; a shortcut can be cleared while it waits for keys."
	footer: skald.View = uiText(th, .Muted, help)
	if dialog.capture.active {
		footer = skald.row(
			skald.flex(1, uiText(th, .Muted, help)),
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
			skald.col(..rows[:], spacing = tk.xxs, cross_align = .Stretch),
			id = skald.hash_id("settings-keys-scroll"))),
		footer,
		spacing = th.spacing.sm,
		padding = th.spacing.sm,
		cross_align = .Stretch,
	)
}

// The row the command palette opened Settings at (`SettingsDialog.highlight`), set by the view
@(private="file")
settingsHighlight: string

// Set by the palette when it opens Settings at a row: the view scrolls the tab to it once
settingsRevealWanted: bool

// The highlighted row's label's widget key (the reveal finds its rect)
SETTINGS_HIGHLIGHT_KEY :: "settings-highlight"

// Scrolls the tab so the highlighted row shows, once both were laid out (last frame's rects)
@(private="file")
settingsReveal :: proc(ctx: ^skald.Ctx(Msg), tab: SettingsTab) {
	tk := uiTokens(ctx)
	key: string
	#partial switch tab {
	case .Appearance: key = "settings-appearance-scroll"
	case .Editor:     key = "settings-editor-scroll"
	case .Toolchain:  key = "settings-toolchain-scroll"
	case:
		settingsRevealWanted = false
		return
	}
	scroll, scrolled := &ctx.widgets.states[skald.hash_id(key)]
	row, found := ctx.widgets.states[skald.hash_id(SETTINGS_HIGHLIGHT_KEY)]
	if !scrolled || !found || scroll.last_rect.h <= 0 || row.last_rect.h <= 0 {
		skald.send(ctx, Msg(Frame_Requested{}))
		return
	}
	settingsRevealWanted = false
	view, at := scroll.last_rect, row.last_rect
	if at.y + at.h + tk.m > view.y + view.h {
		scroll.scroll_y += at.y + at.h + tk.m - (view.y + view.h)
	} else if at.y - tk.m < view.y {
		scroll.scroll_y = max(scroll.scroll_y - (view.y - at.y + tk.m), 0)
	} else {
		return
	}
	skald.send(ctx, Msg(Frame_Requested{}))
}

// "Label     [control]"; the command palette's row has its label lit
@(private="file")
settingRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	if label != "" && label == settingsHighlight {
		tip := fieldTip(label)
		lit := skald.tooltip(ctx, uiText(th, .Section, label, color = th.color.primary), tip == "" ? "Found with the command palette" : tip,
			id = skald.hash_id(SETTINGS_HIGHLIGHT_KEY))
		return skald.row(skald.col(lit, width = tk.labelWidthWide), control, spacing = th.spacing.sm, cross_align = .Center)
	}
	return skald.row(
		skald.col(tipLabel(ctx, label, uiText(th, .Label, label)), width = tk.labelWidthWide),
		control,
		spacing = th.spacing.sm,
		cross_align = .Center,
	)
}

@(private="file")
numberSetting :: proc(ctx: ^skald.Ctx(Msg), s: ^State, field: SettingsField, value, step: f64, limits: [2]f32, unit: string, decimals := 0) -> skald.View {
	th := ctx.theme
	return skald.row(
		numberField(ctx, s, fmt.tprintf("settings-%v", field), field, value, step, decimals, 130, f64(limits[0]), f64(limits[1])),
		uiText(th, .Label, unit),
		spacing = th.spacing.xs,
		cross_align = .Center,
	)
}

// The playback devices SDL sees, the default first (key settings-audio-device)
@(private="file")
audioDeviceSelect :: proc(ctx: ^skald.Ctx(Msg), device: string) -> skald.View {
	tk := uiTokens(ctx)
	names := make([dynamic]string, context.temp_allocator)
	append(&names, AUDIO_DEFAULT_DEVICE)
	append(&names, ..AudioPreview_Devices())
	current := device == "" ? AUDIO_DEFAULT_DEVICE : strings.clone(device, context.temp_allocator)
	return skald.select(ctx, current, names[:], proc(v: string) -> Msg { return Settings_Audio_Device_Changed(v) },
		id = skald.hash_id("settings-audio-device"), width = tk.fieldXL)
}

// The audio device choice for the system's default
AUDIO_DEFAULT_DEVICE :: "System default"

@(private="file")
hint :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	return uiText(th, .Muted, text, max_width = tk.textWide)
}

// Under the program field: where it resolves to, or that it can't be found
@(private="file")
editorProgramStatus :: proc(ctx: ^skald.Ctx(Msg), program: string) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	resolved, found := Script_FindEditorProgram(program)
	if !found {
		return uiText(th, .Muted, fmt.tprintf("Not found: %s", program == "" ? DEFAULT_CODE_EDITOR_PATH : program), max_width = tk.textWide, color = th.color.warning)
	}
	if cli, isApp := Script_ZedCLIFor(resolved); isApp {
		message := cli != "" ? fmt.tprintf("%s is Zed's app, which can't open files in a running Zed: Open uses %s (Zed's command-line tool) instead. Set that here to make it explicit.", resolved, cli) :
			fmt.tprintf("%s is Zed's app, which can't open files in a running Zed. Use Zed's command-line tool (zed, or zeditor on Arch).", resolved)
		return uiText(th, .Muted, message, max_width = tk.textWide, color = th.color.warning)
	}
	return uiText(th, .Muted, fmt.tprintf("Runs %s", resolved), max_width = tk.textWide)
}

// Which language server the built-in code editor will use
@(private="file")
olsStatus :: proc(setting: string) -> string {
	found := Code_FindOLS(setting)
	if found == "" do return setting == "" ? "No ols found (in PATH, code_editor/third_party/ols or Zed's Odin extension): the editor works without completion and diagnostics." : fmt.tprintf("%s wasn't found.", setting)
	return fmt.tprintf("Uses %s", found)
}
