package editor

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
}

SettingsDialog :: struct {
	open: bool,
	tab: SettingsTab,
	draft: Settings,
	// Keyboard tab filter (owned)
	search: string,
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
	Grid_Size,
}

// Opens the dialog on a fresh copy of the active settings
SettingsDialog_Open :: proc(state: ^State) {
	dialog := &state.settingsDialog
	delete(dialog.search)
	dialog^ = {open = true, tab = dialog.tab, draft = state.settings}
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
	case Settings_Theme_Changed:
		draft.theme = string(v) == "Light" ? .Light : .Dark
	case Settings_Value_Changed:
		switch v.field {
		case .Font_Size:         draft.fontSize = clamp(f32(v.value), SETTINGS_FONT_SIZE_RANGE[0], SETTINGS_FONT_SIZE_RANGE[1])
		case .Spacing:           draft.spacing = clamp(f32(v.value), SETTINGS_SPACING_RANGE[0], SETTINGS_SPACING_RANGE[1])
		case .Row_Height:        draft.rowHeight = clamp(f32(v.value), SETTINGS_ROW_HEIGHT_RANGE[0], SETTINGS_ROW_HEIGHT_RANGE[1])
		case .Undo_Merge_Ms:     draft.undoMergeMs = clamp(int(v.value), SETTINGS_UNDO_MS_RANGE[0], SETTINGS_UNDO_MS_RANGE[1])
		case .Undo_Group_Max_Ms: draft.undoGroupMaxMs = clamp(int(v.value), SETTINGS_UNDO_MS_RANGE[0], SETTINGS_UNDO_MS_RANGE[1])
		case .Undo_Limit:        draft.undoLimit = clamp(int(v.value), SETTINGS_UNDO_LIMIT_RANGE[0], SETTINGS_UNDO_LIMIT_RANGE[1])
		case .Grid_Size:         draft.gridSize = clamp(int(v.value), SETTINGS_GRID_SIZE_RANGE[0], SETTINGS_GRID_SIZE_RANGE[1])
		}
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
	case Settings_Builtin_Editor_Changed:
		draft.builtInCodeEditor = bool(v)
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
		case .Editor:
			draft.undoMergeMs, draft.undoGroupMaxMs, draft.undoLimit = defaults.undoMergeMs, defaults.undoGroupMaxMs, defaults.undoLimit
			draft.gridSize = defaults.gridSize
			draft.codeEditorPath, draft.codeEditorArgs, draft.optimizedPlay = defaults.codeEditorPath, defaults.codeEditorArgs, defaults.optimizedPlay
		case .Keyboard:
			draft.keymap = defaults.keymap
		case .Toolchain:
			draft.odinPath = defaults.odinPath
		}
		dialog.capture = {}
	case Settings_Applied:
		state.settings = draft^
		dialog.capture = {}
		if v.close do dialog.open = false
		if message := Settings_Save(&state.settings, state.settingsPath); message != "" {
			logLine(state, .Warning, fmt.aprintf("Settings applied but not saved: %s", message))
		} else {
			logLine(state, .Info, fmt.aprintf("Saved settings to %s", state.settingsPath))
		}
		return skald.cmd_set_theme(Msg, Settings_Theme(&state.settings)), true
	case Settings_Cancelled:
		dialog.open = false
		dialog.capture = {}
	case:
		return {}, false
	}
	return {}, true
}
