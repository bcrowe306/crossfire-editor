package editor

import "gui:skald"

/*
Keyboard shortcuts: every command's default key, in one table.

`KeymapDispatch` turns key presses into `Action` messages each frame, before the menu bar is
built, so a binding fires once even when a menu item shows the same shortcut (Skald's
`shortcut` consumes the key). The menu bar and the Keys tab read their hints from this table.

Defaults follow common editor conventions (Unity/Godot): Q W E R for tools, F to frame the
selection, arrows to nudge, Ctrl+0 to fit the view.

Rules:
- Bindings without Ctrl/Alt/Super ("plain" keys, including Delete, arrows and Escape) are
  ignored while a text or number field has keyboard focus, so typing never triggers them.
- Nothing fires while a modal dialog is open; the dialog handles its own keys.
- `viewportOnly` bindings need the mouse over the viewport (arrow-key nudges, so arrows still
  work in lists and fields elsewhere).

Making the keymap user-editable (loading it from a file) is planned; keep every shortcut in this
table so that stays possible.
*/

KeyBinding :: struct {
	action: Action,
	chord: skald.Shortcut,
	viewportOnly: bool,
}

DEFAULT_KEYMAP := [?]KeyBinding{
	// File
	{action = .New_Project,  chord = {.N, {.Ctrl}}},
	{action = .Open_Project, chord = {.O, {.Ctrl}}},
	{action = .Save_Project, chord = {.S, {.Ctrl}}},
	{action = .Export,       chord = {.E, {.Ctrl, .Shift}}},
	{action = .Import_Asset, chord = {.I, {.Ctrl}}},
	{action = .Quit,         chord = {.Q, {.Ctrl}}},
	// Edit
	{action = .Undo,         chord = {.Z, {.Ctrl}}},
	{action = .Redo,         chord = {.Z, {.Ctrl, .Shift}}},
	{action = .Add_Node,     chord = {.A, {.Ctrl, .Shift}}},
	{action = .Delete_Node,  chord = {.Delete, {}}},
	{action = .Deselect,     chord = {.Escape, {}}},
	// Tools
	{action = .Tool_Select,  chord = {.Q, {}}},
	{action = .Tool_Move,    chord = {.W, {}}},
	{action = .Tool_Rotate,  chord = {.E, {}}},
	{action = .Tool_Scale,   chord = {.R, {}}},
	// View
	{action = .Frame_Selected,   chord = {.F, {}}},
	{action = .View_Fit,         chord = {.N0, {.Ctrl}}},
	{action = .Zoom_100,         chord = {.N1, {.Ctrl}}},
	{action = .Zoom_In,          chord = {.Equals, {.Ctrl}}},
	{action = .Zoom_Out,         chord = {.Minus, {.Ctrl}}},
	{action = .Toggle_Animation, chord = {.P, {}}},
	{action = .Toggle_Bottom_Panel, chord = {.J, {.Ctrl}}},
	// Scene
	{action = .Play,  chord = {.F5, {}}},
	{action = .Pause, chord = {.F6, {}}},
	{action = .Stop,  chord = {.F5, {.Shift}}},
	// Nudge the selected node
	{action = .Nudge_Left,        chord = {.Left,  {}},        viewportOnly = true},
	{action = .Nudge_Right,       chord = {.Right, {}},        viewportOnly = true},
	{action = .Nudge_Up,          chord = {.Up,    {}},        viewportOnly = true},
	{action = .Nudge_Down,        chord = {.Down,  {}},        viewportOnly = true},
	{action = .Nudge_Left_Large,  chord = {.Left,  {.Shift}},  viewportOnly = true},
	{action = .Nudge_Right_Large, chord = {.Right, {.Shift}},  viewportOnly = true},
	{action = .Nudge_Up_Large,    chord = {.Up,    {.Shift}},  viewportOnly = true},
	{action = .Nudge_Down_Large,  chord = {.Down,  {.Shift}},  viewportOnly = true},
}

// Readable names for the Keys tab and menus
ACTION_LABELS := [Action]string{
	.New_Project = "New project", .Open_Project = "Open project", .Save_Project = "Save",
	.Export = "Export", .Quit = "Quit", .Undo = "Undo", .Redo = "Redo",
	.Add_Node = "Add node", .Delete_Node = "Delete node", .Play = "Play", .Pause = "Pause",
	.Stop = "Stop", .Toggle_Bottom_Panel = "Toggle bottom panel", .Clear_Console = "Clear console",
	.About = "About",
	.Tool_Select = "Select tool", .Tool_Move = "Move tool", .Tool_Rotate = "Rotate tool",
	.Tool_Scale = "Scale tool", .Frame_Selected = "Frame selected node", .View_Fit = "Fit game area",
	.Zoom_In = "Zoom in", .Zoom_Out = "Zoom out", .Zoom_100 = "Zoom to 100%",
	.Toggle_Animation = "Play/pause viewport animations", .Deselect = "Deselect",
	.Nudge_Left = "Nudge left", .Nudge_Right = "Nudge right", .Nudge_Up = "Nudge up",
	.Nudge_Down = "Nudge down", .Nudge_Left_Large = "Nudge left x10",
	.Nudge_Right_Large = "Nudge right x10", .Nudge_Up_Large = "Nudge up x10",
	.Nudge_Down_Large = "Nudge down x10",
	.Import_Asset = "Import asset", .Remove_Asset = "Remove asset",
	.Toggle_Preview_Panel = "Toggle preview panel", .Play_Audio_Preview = "Play sound preview",
	.Stop_Audio_Preview = "Stop sound preview",
}

/*
The shortcut bound to an action, or an empty one. Used by the menu bar for its hints.

Inputs:
- action: The action
- typing: Whether a text field has focus. Plain-key shortcuts are left out then, because the
  menu bar would otherwise fire them while typing

Returns:
- The chord (empty if unbound or suppressed)
*/
Keymap_Shortcut :: proc(action: Action, typing := false) -> skald.Shortcut {
	for binding in DEFAULT_KEYMAP {
		if binding.action == action {
			if typing && isPlainKey(binding.chord) do return {}
			return binding.chord
		}
	}
	return {}
}

/*
Sends the action of every binding whose chord was pressed this frame. Call from `view` before
anything else registers shortcuts.

Inputs:
- ctx: The frame context
- overViewport: Whether the mouse is over the viewport
*/
KeymapDispatch :: proc(ctx: ^skald.Ctx(Msg), overViewport: bool, dialogOpen := false) {
	// A modal dialog handles its own keys (Escape closes it)
	if dialogOpen do return
	typing := IsTyping(ctx)
	for binding in DEFAULT_KEYMAP {
		if typing && isPlainKey(binding.chord) do continue
		if binding.viewportOnly && !overViewport do continue
		skald.shortcut(ctx, binding.chord, Msg(binding.action))
	}
}

/*
Whether a text or number field has keyboard focus.
*/
IsTyping :: proc(ctx: ^skald.Ctx(Msg)) -> bool {
	if skald.is_typing(ctx) do return true
	focused := ctx.widgets.focused_id
	return focused != 0 && ctx.widgets.states[focused].kind == .Number_Input
}

// A chord without Ctrl, Alt or Super: it would clash with typing
@(private="file")
isPlainKey :: proc(chord: skald.Shortcut) -> bool {
	return chord.mods & {.Ctrl, .Alt, .Super} == {}
}
