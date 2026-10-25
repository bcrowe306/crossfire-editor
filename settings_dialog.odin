package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"

/*
The Settings dialog's state and message handling. Its view is in view_settings.odin.

The dialog edits `draft`, a copy of the settings. Apply (or Save, which also closes) makes the
draft the active settings, writes editor.ini and switches Skald's theme; Cancel or Escape drops it.
*/

SettingsTab :: enum {
	Appearance,
	Editor,
	Keyboard,
	// What building games needs, found or not (toolchain.odin)
	Toolchain,
	// The Project Settings dialog's tabs, inside this one (ProjectSettingsDialog.embedded)
	Project,
}

SettingsDialog :: struct {
	open: bool,
	tab: SettingsTab,
	draft: Settings,
	// Keyboard tab filter (owned)
	search: string,
	// The row the command palette opened it at, lit (its label; not owned: the palette's tables'
	// strings live as long as the editor). The view scrolls to it once (`settingsRevealWanted`)
	highlight: string,
	// Waiting for a key press to bind
	capture: struct {
		active: bool,
		action: Action,
		slot: int,
	},
}

// Number settings the dialog edits
SettingsField :: enum {
	Font_Size,
	Spacing,
	Row_Height,
	Undo_Merge_Ms,
	Undo_Group_Max_Ms,
	Undo_Limit,
	Console_Limit,
	Rotate_Snap,
	Scale_Snap,
	Corner_Radius,
	Selection_Opacity,
}

// Opens the dialog on a fresh copy of the active settings
SettingsDialog_Open :: proc(state: ^State) {
	dialog := &state.settingsDialog
	delete(dialog.search)
	dialog^ = {open = true, tab = dialog.tab, draft = state.settings}
	if dialog.tab == .Project do openEmbeddedProjectSettings(state)
}

// The Project tab edits the Project Settings dialog's draft, opened on the project's values once
@(private="file")
openEmbeddedProjectSettings :: proc(state: ^State) {
	if state.projectSettings.open && state.projectSettings.embedded do return
	ProjectSettings_Open(state, state.projectSettings.tab)
	state.projectSettings.embedded = true
}

// Closes the Project tab's draft, dropping its changes
@(private="file")
closeEmbeddedProjectSettings :: proc(state: ^State) {
	if !state.projectSettings.embedded do return
	state.projectSettings.open = false
	state.projectSettings.embedded = false
}

// The draft's look, shown at once (Settings > Appearance is live; Cancel puts the old one back)
@(private="file")
liveTheme :: proc(draft: ^Settings) -> skald.Command(Msg) {
	return skald.cmd_set_theme(Msg, Settings_Theme(draft))
}

/*
Handles a Settings dialog message.

Returns:
- A command to run (the theme switch on Apply), and whether `m` was a dialog message
*/
SettingsDialog_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	dialog := &state.settingsDialog
	draft := &dialog.draft
	#partial switch v in m {
	case Settings_Tab_Changed:
		dialog.tab = SettingsTab(v)
		dialog.capture = {}
		if dialog.tab == .Project do openEmbeddedProjectSettings(state)
	case Settings_Theme_Changed:
		draft.theme = string(v) == "Light" ? .Light : .Dark
		return liveTheme(draft), true
	case Settings_Theme_Color_Changed:
		// The picker has no alpha: a color keeps the opacity it had
		old := Settings_Theme(draft).color
		c := v.value
		c[3] = ThemeColor_Field(&old, v.color)[3]
		draft.themeColors[v.color] = c
		draft.themeColorsSet += {v.color}
		return liveTheme(draft), true
	case Settings_Theme_Color_Reset:
		draft.themeColorsSet -= {ThemeColor(v)}
		return liveTheme(draft), true
	case Settings_Theme_Preset_Chosen:
		EditorTheme_ApplyPreset(draft, string(v))
		return liveTheme(draft), true
	case Settings_Viewport_Color_Changed:
		// The views read the draft while the dialog is open: shown at once. The picker has no
		// alpha: a color keeps the opacity it had (the game frame's, the guides')
		c := v.value
		c[3] = viewportAlpha(draft, v.color)
		draft.viewportColors[v.color] = c
		draft.viewportColorsSet += {v.color}
	case Settings_Viewport_Color_Reset:
		draft.viewportColorsSet -= {ViewportColor(v)}
	case Settings_Value_Changed:
		switch v.field {
		case .Font_Size:         draft.fontSize = clamp(f32(v.value), SETTINGS_FONT_SIZE_RANGE[0], SETTINGS_FONT_SIZE_RANGE[1])
		case .Spacing:           draft.spacing = clamp(f32(v.value), SETTINGS_SPACING_RANGE[0], SETTINGS_SPACING_RANGE[1])
		case .Row_Height:        draft.rowHeight = clamp(f32(v.value), SETTINGS_ROW_HEIGHT_RANGE[0], SETTINGS_ROW_HEIGHT_RANGE[1])
		case .Undo_Merge_Ms:     draft.undoMergeMs = clamp(int(v.value), SETTINGS_UNDO_MS_RANGE[0], SETTINGS_UNDO_MS_RANGE[1])
		case .Undo_Group_Max_Ms: draft.undoGroupMaxMs = clamp(int(v.value), SETTINGS_UNDO_MS_RANGE[0], SETTINGS_UNDO_MS_RANGE[1])
		case .Undo_Limit:        draft.undoLimit = clamp(int(v.value), SETTINGS_UNDO_LIMIT_RANGE[0], SETTINGS_UNDO_LIMIT_RANGE[1])
		case .Console_Limit:     draft.consoleLimit = clamp(int(v.value), SETTINGS_CONSOLE_LIMIT_RANGE[0], SETTINGS_CONSOLE_LIMIT_RANGE[1])
		case .Rotate_Snap:       draft.rotateSnap = clamp(f32(v.value), SETTINGS_ROTATE_SNAP_RANGE[0], SETTINGS_ROTATE_SNAP_RANGE[1])
		case .Scale_Snap:        draft.scaleSnap = clamp(f32(v.value), SETTINGS_SCALE_SNAP_RANGE[0], SETTINGS_SCALE_SNAP_RANGE[1])
		case .Corner_Radius:     draft.cornerRadius = clamp(f32(v.value), SETTINGS_CORNER_RADIUS_RANGE[0], SETTINGS_CORNER_RADIUS_RANGE[1])
		case .Selection_Opacity:
			// The selection's color as it shows now, with this opacity (it's set from then on)
			c := Settings_Theme(draft).color.selection
			c[3] = clamp(f32(v.value), 0, 100) / 100
			draft.themeColors[.Selection] = c
			draft.themeColorsSet += {.Selection}
		}
		if v.field == .Font_Size || v.field == .Spacing || v.field == .Corner_Radius || v.field == .Selection_Opacity do return liveTheme(draft), true
	case Settings_Code_Editor_Path_Changed:
		draft.codeEditorPath = FixedText_Make(string(v))
	case Settings_Code_Editor_Args_Changed:
		draft.codeEditorArgs = FixedText_Make(string(v))
	case Settings_Code_Editor_Browse:
		return skald.cmd_open_file_dialog(nil, proc(r: skald.File_Dialog_Result) -> Msg { return Settings_Code_Editor_Picked(r) }), true
	case Settings_Code_Editor_Picked:
		if !v.cancelled && v.path != "" do draft.codeEditorPath = FixedText_Make(v.path)
	case Settings_Optimized_Play_Changed:
		draft.optimizedPlay = bool(v)
	case Settings_Hot_Reload_Changed:
		draft.hotReload = bool(v)
	case Settings_Wheel_Pans_Changed:
		draft.wheelPans = bool(v)
	case Settings_Builtin_Editor_Changed:
		draft.builtInCodeEditor = bool(v)
	case Settings_Auto_Close_Changed:
		draft.autoClosePairs = bool(v)
	case Settings_LDtk_Path_Changed:
		draft.ldtkPath = FixedText_Make(string(v))
	case Settings_Aseprite_Path_Changed:
		draft.asepritePath = FixedText_Make(string(v))
	case Settings_Audio_Device_Changed:
		draft.audioDevice = FixedText_Make(string(v) == AUDIO_DEFAULT_DEVICE ? "" : string(v))
	case Settings_OLS_Path_Changed:
		draft.olsPath = FixedText_Make(string(v))
	case Settings_Odin_Path_Changed:
		draft.odinPath = FixedText_Make(string(v))
	case Settings_Search_Changed:
		delete(dialog.search)
		dialog.search = strings.clone(string(v))
	case Settings_Capture_Started:
		dialog.capture = {active = true, action = v.action, slot = v.slot}
	case Settings_Capture_Cancelled:
		dialog.capture = {}
	case Settings_Key_Captured:
		if dialog.capture.active {
			draft.keymap[dialog.capture.action][dialog.capture.slot] = skald.Shortcut(v)
		}
		dialog.capture = {}
	case Settings_Key_Cleared:
		draft.keymap[v.action][v.slot] = {}
		dialog.capture = {}
	case Settings_Key_Reset:
		draft.keymap[Action(v)] = Settings_Default().keymap[Action(v)]
		dialog.capture = {}
	case Settings_Tab_Reset:
		// Back to the defaults, for the open tab only
		defaults := Settings_Default()
		switch dialog.tab {
		case .Appearance:
			draft.theme, draft.fontSize, draft.spacing, draft.rowHeight = defaults.theme, defaults.fontSize, defaults.spacing, defaults.rowHeight
			draft.themeColors, draft.themeColorsSet, draft.cornerRadius = defaults.themeColors, defaults.themeColorsSet, defaults.cornerRadius
			draft.viewportColors, draft.viewportColorsSet = defaults.viewportColors, defaults.viewportColorsSet
			dialog.capture = {}
			return liveTheme(draft), true
		case .Editor:
			draft.undoMergeMs, draft.undoGroupMaxMs, draft.undoLimit = defaults.undoMergeMs, defaults.undoGroupMaxMs, defaults.undoLimit
			draft.consoleLimit = defaults.consoleLimit
			draft.codeEditorPath, draft.codeEditorArgs, draft.optimizedPlay = defaults.codeEditorPath, defaults.codeEditorArgs, defaults.optimizedPlay
			draft.hotReload = defaults.hotReload
			draft.wheelPans = defaults.wheelPans
			draft.autoClosePairs = defaults.autoClosePairs
			draft.audioDevice = defaults.audioDevice
			draft.ldtkPath = defaults.ldtkPath
			draft.asepritePath = defaults.asepritePath
		case .Keyboard:
			draft.keymap = defaults.keymap
		case .Toolchain:
			draft.odinPath = defaults.odinPath
		case .Project:
			// The project has no defaults to go back to (the button is hidden)
		}
		dialog.capture = {}
	case Settings_Applied:
		state.settings = draft^
		// A lower limit applies at once
		LogList_Trim(&state.console, state.settings.consoleLimit)
		LogList_Trim(&state.output, state.settings.consoleLimit)
		AudioPreview_SetDevice(FixedText_String(&state.settings.audioDevice))
		dialog.capture = {}
		if v.close do dialog.open = false
		if message := Settings_Save(&state.settings, state.settingsPath); message != "" {
			logLine(state, .Warning, fmt.aprintf("Settings applied but not saved: %s", message))
		} else {
			logLine(state, .Info, fmt.aprintf("Saved settings to %s", state.settingsPath))
		}
		theme := skald.cmd_set_theme(Msg, Settings_Theme(&state.settings))
		// The Project tab was opened: its changes are applied too, as their own undoable step
		if state.projectSettings.open && state.projectSettings.embedded {
			return skald.cmd_batch(theme, skald.cmd_now(Msg(Project_Settings_Applied{}))), true
		}
		return theme, true
	case Settings_Cancelled:
		dialog.open = false
		dialog.capture = {}
		closeEmbeddedProjectSettings(state)
		// The look previewed while editing goes back to the applied settings'
		return skald.cmd_set_theme(Msg, Settings_Theme(&state.settings)), true
	case:
		return {}, false
	}
	return {}, true
}

// A canvas color's opacity as the draft shows it (its theme's, for the colors following it)
@(private="file")
viewportAlpha :: proc(draft: ^Settings, which: ViewportColor) -> f32 {
	theme := Settings_Theme(draft)
	return ViewportColors_Of(draft, &theme)[which][3]
}
