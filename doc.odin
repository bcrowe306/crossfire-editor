/*
The odin_sdl_engine editor.

Built with Skald's Elm architecture:

- `State` (editor.odin) holds everything: the open `Project`, selection, panel sizes and the console.
- `Msg` (msg.odin) lists everything that can happen.
- `update` (update.odin) is the only place `State` changes.
- `view` (view.odin and view_*.odin) draws the whole window from `State` every frame.

Window layout:

	+-----------------------------------------------------------+
	| menu bar                                                  |
	| toolbar: file, undo, tools, play controls, export        |
	+-----------+-----------------------------------+-----------+
	| browser   | scene tabs                        | scene     |
	| (project  | viewport                          | tree      |
	|  files)   |                                   |-----------|
	|           +-----------------------------------+ inspector |
	|           | bottom panel: Console / Output /  |           |
	|           | Animation tabs, collapsible       |           |
	+-----------+-----------------------------------+-----------+
	| status bar                                                |
	+-----------------------------------------------------------+

The project model (project.odin) is plain data, independent of Skald and the engine.
*/
package crossfire_editor
