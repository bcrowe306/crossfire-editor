package crossfire_editor

/*
Contextual hints (TODO.md's "UI and UX" round "Workflow", 2026-10-25): the status bar shows the
current tool's keys and modifiers, so what Shift, Alt or Space do with it needn't be remembered.
One line per tool of the Scene mode's viewport (`Tool`) and of the Level mode (`LevelTool`); the
texts follow what the canvases do (view_viewport.odin's drags, level_canvas.odin's modifiers).
*/

// Under this window width the status bar has no room for the hint
STATUS_HINT_MIN_WIDTH :: 900

// The Scene mode's tools' hints
TOOL_HINTS := [Tool]string{
	.Select    = "Click: select · Ctrl+click: toggle · Shift+click: add · Drag empty space: box select · Alt+drag: duplicate · Space: pan",
	.Move      = "Shift: one axis · Alt+drag: duplicate · Arrows: nudge · Space: pan",
	.Rotate    = "Shift: snap the angle · Space: pan",
	.Scale     = "Shift: axes separately · Side handles: one axis · Space: pan",
	.Transform = "Arrows, square, corners, ring · Shift: one axis, snap · Alt+drag: duplicate · Space: pan",
	.Zoom      = "Click: zoom in · Alt+click: zoom out · Drag: zoom to a box",
	.Pan       = "Drag: pan · Wheel: zoom",
}

// The Level mode's tools' hints
LEVEL_TOOL_HINTS := [LevelTool]string{
	.Select    = "Click: select · Drag: move · Shift+Alt+drag: select a rectangle · Ctrl+Alt+drag: copy the selection · Space: pan",
	.Pencil    = "Right button: erase · Shift+drag: rectangle · Shift+click: fill · Alt+click: pick · Space: pan",
	.Random    = "A random picked tile per cell · Right button: erase · Alt+click: pick · Space: pan",
	.Rectangle = "Drag: a rectangle · Right button: erase · Alt+click: pick · Space: pan",
	.Fill      = "Click: fill the area · Right button: erase · Alt+click: pick · Space: pan",
	.Eraser    = "Drag: erase · Shift+drag: a rectangle · Space: pan",
	.Picker    = "Click: pick the value, tile or entity type under the pointer · Space: pan",
}

/*
The status bar's hint for the tool in use: the Scene mode's viewport tool, or the Level mode's.

Returns:
- The hint text (a constant; "" when the mode has none)
*/
Tool_Hint :: proc(s: ^State) -> string {
	switch s.mode {
	case .Scene: return TOOL_HINTS[s.tool]
	case .Level: return LEVEL_TOOL_HINTS[s.level.tool]
	}
	return ""
}
