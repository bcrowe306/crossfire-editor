package editor

import "gui:skald"

/*
Keyboard shortcuts: which keys trigger which `Action`.

The chords live in the settings (`Settings.keymap`), so users can change them in the Settings
dialog; the defaults are the `[keymap]` section of `settings.default.ini`. What stays in code is
how each action behaves (`ACTION_KEY_RULES`): whether it only works over the viewport, and
whether text fields keep its chord while typing.

`KeymapDispatch` turns key presses into `Action` messages each frame, before the menu bar is
built, so a binding fires once even when a menu item shows the same shortcut (Skald's
`shortcut` consumes the key). The menu bar and the Keys tab read their hints from the keymap.

Defaults follow common editor conventions (Unity/Godot): Q W E R for tools, F to frame the
selection, arrows to nudge, Ctrl+0 to fit the view.

Rules:
- Bindings without Ctrl/Alt/Super ("plain" keys, including Delete, arrows and Escape) are
  ignored while a text or number field has keyboard focus, so typing never triggers them.
- Nothing fires while a modal dialog is open; the dialog handles its own keys.
- `textChord` actions (Ctrl+Z, Ctrl+C/X/V/D) also stand down while typing, so text fields keep
  those chords (a text field's Ctrl+Z undoes typing).
- `viewportOnly` actions need the mouse over the viewport (arrow-key nudges, so arrows still
  work in lists and fields elsewhere).
- Backspace on its own can't be bound: Skald uses it as the "no shortcut" value.
*/

// Chords per action: a main one (shown in menus) and an alternative (Redo: Ctrl+Shift+Z or Ctrl+Y)
KEYMAP_SLOTS :: 2

// Every action's chords. An empty `skald.Shortcut{}` means unbound
Keymap :: [Action][KEYMAP_SLOTS]skald.Shortcut

// How an action's shortcut behaves
ActionKeyRule :: struct {
	// Only while the mouse is over the viewport
	viewportOnly: bool,
	// Not while typing: text fields use the same chord
	textChord: bool,
}

ACTION_KEY_RULES := #partial [Action]ActionKeyRule{
	.Undo = {textChord = true},
	.Redo = {textChord = true},
	.Duplicate_Node = {textChord = true},
	.Copy_Node = {textChord = true},
	.Cut_Node = {textChord = true},
	.Paste_Node = {textChord = true},
	.Select_All = {textChord = true},
	.Nudge_Left = {viewportOnly = true},
	.Nudge_Right = {viewportOnly = true},
	.Nudge_Up = {viewportOnly = true},
	.Nudge_Down = {viewportOnly = true},
	.Nudge_Left_Large = {viewportOnly = true},
	.Nudge_Right_Large = {viewportOnly = true},
	.Nudge_Up_Large = {viewportOnly = true},
	.Nudge_Down_Large = {viewportOnly = true},
}

// Readable names for the Keys tab and menus
ACTION_LABELS := [Action]string{
	.New_Project = "New project", .Open_Project = "Open project", .Save_Project = "Save",
	.Export = "Export", .Export_Project_Archive = "Export project archive", .Open_Project_Archive = "Open project archive", .Quit = "Quit", .Undo = "Undo", .Redo = "Redo",
	.Add_Node = "Add node", .Delete_Node = "Delete node", .Duplicate_Node = "Duplicate node",
	.Copy_Node = "Copy node", .Cut_Node = "Cut node", .Paste_Node = "Paste node", .Rename_Node = "Rename node", .Save_As_Component = "Save as component",
	.Select_All = "Select all nodes", .Toggle_Grid = "Show/hide grid", .Toggle_Snap = "Snap to grid", .Toggle_Collision_Shapes = "Show/hide collision shapes", .Toggle_Physics_Debug = "Show collision shapes in the game (development)", .Play = "Play", .Pause = "Pause",
	.Stop = "Stop", .Toggle_Bottom_Panel = "Toggle bottom panel", .Clear_Console = "Clear console",
	.About = "About",
	.Tool_Select = "Select tool", .Tool_Move = "Move tool", .Tool_Rotate = "Rotate tool",
	.Tool_Scale = "Scale tool", .Tool_Pan = "Pan tool", .Frame_Selected = "Frame selected node", .View_Fit = "Fit game area",
	.Zoom_In = "Zoom in", .Zoom_Out = "Zoom out", .Zoom_100 = "Zoom to 100%",
	.Toggle_Animation = "Play/pause viewport animations", .Deselect = "Deselect",
	.Nudge_Left = "Nudge left", .Nudge_Right = "Nudge right", .Nudge_Up = "Nudge up",
	.Nudge_Down = "Nudge down", .Nudge_Left_Large = "Nudge left x10",
	.Nudge_Right_Large = "Nudge right x10", .Nudge_Up_Large = "Nudge up x10",
	.Nudge_Down_Large = "Nudge down x10",
	.Import_Asset = "Import asset", .Remove_Asset = "Remove asset",
	.Toggle_Preview_Panel = "Toggle preview panel", .Play_Audio_Preview = "Play sound preview",
	.Stop_Audio_Preview = "Stop sound preview",
	.Open_Settings = "Settings", .Play_Scene = "Play the open scene", .Open_Project_Settings = "Project settings", .Build_Scripts = "Build scripts", .Open_Script = "Open script in code editor",
	.Close_Code_Tab = "Close code tab",
}

/*
The main shortcut bound to an action, or an empty one. Used by the menu bar and context menus
for their hints.

Inputs:
- keymap: The keymap (`state.settings.keymap`)
- action: The action
- typing: Whether a text field has focus. Shortcuts that typing keeps are left out then,
  because the menu bar would otherwise fire them while typing

Returns:
- The chord (empty if unbound or suppressed)
*/
Keymap_Shortcut :: proc(keymap: ^Keymap, action: Action, typing := false) -> skald.Shortcut {
	for chord in keymap[action] {
		if chord == {} do continue
		if typing && (isPlainKey(chord) || ACTION_KEY_RULES[action].textChord) do return {}
		return chord
	}
	return {}
}

/*
The action using a chord, other than `except`. The Settings dialog warns about such conflicts;
at runtime the first action in `Action` order wins.

Returns:
- The action, and whether there is one
*/
Keymap_FindChord :: proc(keymap: ^Keymap, chord: skald.Shortcut, except: Action) -> (Action, bool) {
	if chord == {} do return {}, false
	for chords, action in keymap {
		if action == except do continue
		for c in chords do if c == chord do return action, true
	}
	return {}, false
}

/*
Sends the action of every binding whose chord was pressed this frame. Call from `view` before
anything else registers shortcuts.

Inputs:
- ctx: The frame context
- keymap: The keymap
- overViewport: Whether the mouse is over the viewport
- dialogOpen: A modal dialog or popup menu is open; nothing is dispatched
*/
KeymapDispatch :: proc(ctx: ^skald.Ctx(Msg), keymap: ^Keymap, overViewport: bool, dialogOpen := false) {
	// A modal dialog handles its own keys (Escape closes it)
	if dialogOpen do return
	typing := IsTyping(ctx)
	// The code editor gets every key but a few of the editor's (save, play, build, ...)
	coding := CodeEditor_Focused(ctx)
	for chords, action in keymap {
		if coding && action not_in CODE_EDITOR_PASSTHROUGH do continue
		rule := ACTION_KEY_RULES[action]
		if rule.viewportOnly && !overViewport do continue
		for chord in chords {
			if chord == {} do continue
			if typing && !coding && (isPlainKey(chord) || rule.textChord) do continue
			skald.shortcut(ctx, chord, Msg(action))
		}
	}
}

/*
Whether a text or number field has keyboard focus.
*/
IsTyping :: proc(ctx: ^skald.Ctx(Msg)) -> bool {
	if skald.is_typing(ctx) || CodeEditor_Focused(ctx) do return true
	focused := ctx.widgets.focused_id
	return focused != 0 && ctx.widgets.states[focused].kind == .Number_Input
}

// A chord without Ctrl, Alt or Super: it would clash with typing
@(private="file")
isPlainKey :: proc(chord: skald.Shortcut) -> bool {
	return chord.mods & {.Ctrl, .Alt, .Super} == {}
}
