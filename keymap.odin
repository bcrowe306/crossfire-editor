package crossfire_editor

import "core:fmt"
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
	// Only in these editor modes (empty: every mode); the menu bar disables it in the others
	onlyIn: bit_set[EditorMode],
}

ACTION_KEY_RULES := #partial [Action]ActionKeyRule{
	.Undo = {textChord = true},
	.Redo = {textChord = true},
	// The scene's nodes, its viewport and the code tabs are the Scene mode's (editor_modes.odin)
	.Add_Node = {onlyIn = {.Scene}},
	.Delete_Node = {onlyIn = {.Scene}},
	.Duplicate_Node = {textChord = true, onlyIn = {.Scene}},
	.Copy_Node = {textChord = true, onlyIn = {.Scene}},
	.Cut_Node = {textChord = true, onlyIn = {.Scene}},
	.Paste_Node = {textChord = true, onlyIn = {.Scene}},
	.Rename_Node = {onlyIn = {.Scene}},
	.Save_As_Component = {onlyIn = {.Scene}},
	.Add_Script = {onlyIn = {.Scene}},
	.Select_All = {textChord = true, onlyIn = {.Scene}},
	.Toggle_Grid = {onlyIn = {.Scene}},
	.Toggle_Snap = {onlyIn = {.Scene}},
	.Toggle_Collision_Shapes = {onlyIn = {.Scene}},
	.Toggle_Lighting = {onlyIn = {.Scene}},
	.Tool_Select = {onlyIn = {.Scene}},
	.Tool_Move = {onlyIn = {.Scene}},
	.Tool_Rotate = {onlyIn = {.Scene}},
	.Tool_Scale = {onlyIn = {.Scene}},
	.Tool_Pan = {onlyIn = {.Scene}},
	.Tool_Transform = {onlyIn = {.Scene}},
	.Tool_Zoom = {onlyIn = {.Scene}},
	.Toggle_Local_Axes = {onlyIn = {.Scene}},
	.Toggle_Guides = {onlyIn = {.Scene}},
	.Frame_Selected = {onlyIn = {.Scene}},
	.View_Fit = {onlyIn = {.Scene}},
	.Zoom_In = {onlyIn = {.Scene}},
	.Zoom_Out = {onlyIn = {.Scene}},
	.Zoom_100 = {onlyIn = {.Scene}},
	.Toggle_Animation = {onlyIn = {.Scene}},
	.Deselect = {onlyIn = {.Scene}},
	.Nudge_Left = {viewportOnly = true, onlyIn = {.Scene}},
	.Nudge_Right = {viewportOnly = true, onlyIn = {.Scene}},
	.Nudge_Up = {viewportOnly = true, onlyIn = {.Scene}},
	.Nudge_Down = {viewportOnly = true, onlyIn = {.Scene}},
	.Nudge_Left_Large = {viewportOnly = true, onlyIn = {.Scene}},
	.Nudge_Right_Large = {viewportOnly = true, onlyIn = {.Scene}},
	.Nudge_Up_Large = {viewportOnly = true, onlyIn = {.Scene}},
	.Nudge_Down_Large = {viewportOnly = true, onlyIn = {.Scene}},
	.Open_Script = {onlyIn = {.Scene}},
	.Close_Code_Tab = {onlyIn = {.Scene}},
	// The Level mode's (level_paint.odin)
	.Level_Flip_X = {onlyIn = {.Level}},
	.Level_Flip_Y = {onlyIn = {.Level}},
	.Level_Random_Mode = {onlyIn = {.Level}},
	.Level_Toggle_Grid = {onlyIn = {.Level}},
	.Level_Single_Layer = {onlyIn = {.Level}},
	.Level_Tile_Stacking = {onlyIn = {.Level}},
	.Level_Auto_Layers = {onlyIn = {.Level}},
	.Level_Delete = {onlyIn = {.Level}},
	.Level_Duplicate = {textChord = true, onlyIn = {.Level}},
	.Level_Cancel = {onlyIn = {.Level}},
	.Level_World_Mode = {onlyIn = {.Level}},
}

/*
Whether an action's keys work in a mode (`ActionKeyRule.onlyIn`). The browser's routed keys
(Delete, Ctrl+D/C/X/V, F2 on its selected scene: `Browser_RouteAction`) work wherever the browser
shows, so they count while it has the keyboard.
*/
Action_InMode :: proc(action: Action, mode: EditorMode, browserFocused := false) -> bool {
	only := ACTION_KEY_RULES[action].onlyIn
	if only == {} || mode in only do return true
	#partial switch action {
	case .Delete_Node, .Duplicate_Node, .Copy_Node, .Cut_Node, .Paste_Node, .Rename_Node: return browserFocused
	}
	return false
}

// Readable names for the Keys tab and menus
ACTION_LABELS := [Action]string{
	.New_Project = "New project", .Open_Project = "Open project", .Save_Project = "Save", .Save_Project_As = "Save project as",
	.Export = "Export", .Export_Project_Archive = "Export project archive", .Export_Project_Archive_With_History = "Export project archive with its history", .Open_Project_Archive = "Open project archive", .Quit = "Quit", .Undo = "Undo", .Redo = "Redo",
	.Add_Node = "Add node", .Delete_Node = "Delete node", .Duplicate_Node = "Duplicate node",
	.Copy_Node = "Copy node", .Cut_Node = "Cut node", .Paste_Node = "Paste node", .Rename_Node = "Rename node", .Save_As_Component = "Save as component", .Add_Script = "Add or open the node's script",
	.Select_All = "Select all nodes", .Toggle_Grid = "Show/hide grid", .Toggle_Snap = "Snap to grid", .Toggle_Collision_Shapes = "Show/hide collision shapes", .Toggle_Lighting = "Show the viewport lit or unlit", .Toggle_Physics_Debug = "Show collision shapes in the game (development)", .Play = "Play", .Pause = "Pause",
	.Stop = "Stop", .Restart = "Restart the game", .Toggle_Bottom_Panel = "Toggle bottom panel", .Clear_Console = "Clear console",
	.About = "About",
	.User_Manual = "User Manual",
	.Tool_Select = "Select tool", .Tool_Move = "Move tool", .Tool_Rotate = "Rotate tool",
	.Tool_Scale = "Scale tool", .Tool_Pan = "Pan tool", .Tool_Transform = "Transform tool", .Tool_Zoom = "Zoom tool", .Toggle_Local_Axes = "Move along the node's own axes", .Toggle_Guides = "Show guides", .Frame_Selected = "Frame selected node", .View_Fit = "Fit game area",
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
	.Mode_Scene = "Scene mode", .Mode_Level = "Level mode",
	.Level_Flip_X = "Level: flip the tiles on X", .Level_Flip_Y = "Level: flip the tiles on Y",
	.Level_Random_Mode = "Level: random tiles or a stamp", .Level_Toggle_Grid = "Level: show the grid and snap to it",
	.Level_Single_Layer = "Level: fade the other layers", .Level_Tile_Stacking = "Level: stack tiles",
	.Level_Auto_Layers = "Level: show auto-layer tiles", .Level_Delete = "Level: delete the selected entity",
	.Level_Duplicate = "Level: duplicate the selected entity", .Level_Cancel = "Level: cancel a pick, deselect",
	.Level_World_Mode = "Level: the world or the level",
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
Keymap chords are written once for every platform: their **Ctrl is the platform's command key**
(Cmd on macOS, Ctrl elsewhere), and their Super the other one (Ctrl on macOS, the Windows or
Super key elsewhere). So "Ctrl+S" in settings.default.ini and editor.ini saves with Cmd+S on a
Mac and Ctrl+S on Windows and Linux, and one editor.ini works on all of them.

This turns a keymap chord into the keys pressed on this platform (on macOS, Ctrl and Super swap),
and back: the swap is its own inverse (`Chord_FromPlatform`).

Example:
	chord, _ := Shortcut_Parse("Ctrl+S")
	pressed := Chord_OnPlatform(chord) // {.S, {.Super}} on macOS, {.S, {.Ctrl}} elsewhere
*/
Chord_OnPlatform :: proc(chord: skald.Shortcut, mac := ODIN_OS == .Darwin) -> skald.Shortcut {
	if !mac do return chord
	out := chord
	out.mods -= {.Ctrl, .Super}
	if .Ctrl in chord.mods do out.mods += {.Super}
	if .Super in chord.mods do out.mods += {.Ctrl}
	return out
}

// The keymap chord for keys pressed on this platform (Cmd+S on a Mac is the keymap's "Ctrl+S")
Chord_FromPlatform :: proc(pressed: skald.Shortcut, mac := ODIN_OS == .Darwin) -> skald.Shortcut {
	return Chord_OnPlatform(pressed, mac)
}

/*
A keymap chord as this platform names it: "Ctrl+Shift+Z" on Windows and Linux, "Shift+Cmd+Z" on a
Mac; "" when unbound. What users see (menus, tooltips, Settings); files keep `Keymap_FormatChords`.
*/
Chord_Format :: proc(chord: skald.Shortcut, mac := ODIN_OS == .Darwin) -> string {
	return skald.shortcut_format_for(Chord_OnPlatform(chord, mac), mac)
}

// " (Ctrl+B)" (" (Cmd+B)" on a Mac) for text naming an action's keys; "" when it has none
keyParen :: proc(s: ^State, action: Action) -> string {
	chord := Keymap_Shortcut(&s.settings.keymap, action)
	return chord == {} ? "" : fmt.tprintf(" (%s)", Chord_Format(chord))
}

/*
The action using a chord, other than `except`. The Settings dialog warns about such conflicts;
at runtime the first action in `Action` order wins. Actions of modes that never show together
(`ActionKeyRule.onlyIn`) don't conflict: the Scene mode's G and the Level mode's are both G.

Returns:
- The action, and whether there is one
*/
Keymap_FindChord :: proc(keymap: ^Keymap, chord: skald.Shortcut, except: Action) -> (Action, bool) {
	if chord == {} do return {}, false
	mine := ACTION_KEY_RULES[except].onlyIn
	for chords, action in keymap {
		if action == except do continue
		// Actions of different modes may share a key (G is the Scene mode's grid and the Level mode's)
		theirs := ACTION_KEY_RULES[action].onlyIn
		if mine != {} && theirs != {} && mine & theirs == {} do continue
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
- mode: The editor mode that shows: actions only for others don't fire (`Action_InMode`)
- browserFocused: The project browser has the keyboard (its routed keys work in every mode)
*/
KeymapDispatch :: proc(ctx: ^skald.Ctx(Msg), keymap: ^Keymap, overViewport: bool, dialogOpen := false, mode := EditorMode.Scene, browserFocused := false) {
	// A modal dialog handles its own keys (Escape closes it)
	if dialogOpen do return
	typing := IsTyping(ctx)
	// The code editor gets every key but a few of the editor's (save, play, build, ...)
	coding := CodeEditor_Focused(ctx)
	for chords, action in keymap {
		if coding && action not_in CODE_EDITOR_PASSTHROUGH do continue
		rule := ACTION_KEY_RULES[action]
		if rule.viewportOnly && !overViewport do continue
		if !Action_InMode(action, mode, browserFocused) do continue
		for chord in chords {
			if chord == {} do continue
			if typing && !coding && (isPlainKey(chord) || rule.textChord) do continue
			skald.shortcut(ctx, Chord_OnPlatform(chord), Msg(action))
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
