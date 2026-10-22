/*
The Crossfire Editor's plugin API: what a plugin package imports to add tools to the editor.

A **plugin** is an Odin package in a project's `plugins/<name>/` folder. The editor builds it into
a shared library (`odin build -build-mode:shared`, with this package as the `plugin_api`
collection), loads it, and calls its exported `crossfire_plugin` procedure, which says what it
adds:

- **Commands**: tools in the editor's Plugins menu and the Plugins tab ("Arrange in a Grid",
  "Snap Children to Pixels"). Each runs once when chosen; whatever it changes in the project is
  one undo step.
- **Importers**: what to do with files of some extensions when they're imported (turn a `.csv`
  into a dialogue, a level format into a scene).
- **Inspector rows**: extra rows in the inspector for nodes of some kinds, or with some script:
  notes, numbers, text, checkboxes, choices and buttons, described as data the editor draws;
  changes come back to the plugin.

The plugin reads and changes the project through the `Host` the editor passes: the open scene's
nodes and their properties (as text, like the Timeline's), the selection, the assets. It can use
Odin's core library (files: `core:os`); it doesn't link the engine.

A plugin is rebuilt and reloaded when its files change (save a `.odin` file in its folder);
build errors show in the editor's Output tab.

	package grid_tools

	import api "plugin_api:."

	// Package-level lists: a slice literal returned from a procedure would be on its stack
	commands := []api.Command{{name = "Arrange Children in a Grid", run = arrange}}

	@(export)
	crossfire_plugin :: proc(host: ^api.Host) -> api.Plugin {
		return {name = "Grid Tools", version = api.PLUGIN_API_VERSION, commands = commands}
	}

	arrange :: proc(host: ^api.Host) {
		parent := host.selected()
		...
	}

**Rules:** everything the editor gets from a plugin (names, labels, rows) is copied before the
plugin can be reloaded, so string literals are fine. Memory a plugin allocates comes from the
editor's allocators (the `context` the editor calls with); temporary data should use
`context.temp_allocator`.
*/
package crossfire_plugin

// The API version the editor speaks (a plugin built against another isn't loaded)
PLUGIN_API_VERSION :: 1

// The name of the procedure a plugin exports
PLUGIN_ENTRY :: "crossfire_plugin"

// What a plugin's exported `crossfire_plugin` procedure returns
Plugin :: struct {
	// Shown in the Plugins tab
	name, description: string,
	// The API version it was built against: PLUGIN_API_VERSION (one built against another isn't
	// loaded)
	version: int,
	commands: []Command,
	importers: []Importer,
	inspectors: []Inspector,
}

// The type of a plugin's entry procedure
PluginEntry :: #type proc(host: ^Host) -> Plugin

// A tool the user runs from the Plugins menu or tab
Command :: struct {
	name: string,
	// What it does, in the Plugins tab
	description: string,
	run: proc(host: ^Host),
}

/*
Handles imports of files with some extensions. The editor calls `run` with the file the user
picked; it makes whatever the project should get (files inside the project folder), registers
them (`Host.addAsset`) and returns the asset to select.
*/
Importer :: struct {
	// Without the dot, lower case: {"csv", "tsv"}
	extensions: []string,
	description: string,
	run: proc(host: ^Host, source: string) -> (asset: string, problem: string),
}

// Extra inspector rows for some nodes
Inspector :: struct {
	// Node kinds ("Sprite", "Label") and scripts ("script:Player") it's for
	targets: []string,
	// The rows for a node (temp allocated: `context.temp_allocator`)
	rows: proc(host: ^Host, node: int) -> []InspectorRow,
	// A row's value changed (a Button row: pressed, value "")
	changed: proc(host: ^Host, node: int, id: string, value: string),
}

// What a row shows and edits
RowKind :: enum {
	// Text to read
	Note,
	// A text field
	Text,
	// A number field
	Number,
	// A checkbox ("true" / "false")
	Bool,
	// A dropdown of `choices`
	Choice,
	// A button (the label is the row's; `value` is the button's text)
	Button,
}

// An inspector row
InspectorRow :: struct {
	// Passed back to `changed`
	id: string,
	label: string,
	kind: RowKind,
	value: string,
	choices: []string,
}

/*
What the editor lets a plugin do. Node indices are into the open scene (or component); -1 means
none (the top level as a parent). Properties are text: "name", "kind", "position" ("x, y"),
"rotation", "scale" ("x, y"), "visible", "layer", "z_index", "texture", "text", "color",
"region", "script" (its first script's name), "script.<field>" (a script field's value).
*/
Host :: struct {
	// PLUGIN_API_VERSION of the editor
	version: int,
	// A line in the editor's Console (warning: in its color)
	log: proc(text: string, warning := false),
	// The project's folder (absolute)
	projectRoot: proc() -> string,
	// The open scene (or component): its name, its nodes
	sceneName: proc() -> string,
	nodeCount: proc() -> int,
	// A node's parent (-1: top level) and its children
	nodeParent: proc(node: int) -> int,
	nodeChildren: proc(node: int) -> []int,
	// Read and write a node's property (false: no such node or property, or a bad value)
	getProperty: proc(node: int, property: string) -> (string, bool),
	setProperty: proc(node: int, property, value: string) -> bool,
	// Adds a node of a kind ("Sprite") under a parent (-1: top level); its index
	addNode: proc(kind, name: string, parent: int) -> int,
	// Removes a node and its children
	removeNode: proc(node: int),
	// The selected node (-1 none) and all selected ones
	selected: proc() -> int,
	selection: proc() -> []int,
	select: proc(node: int),
	// The project's assets: their paths (relative to the project) and kinds ("Image", "Audio"...)
	assets: proc() -> []string,
	assetKind: proc(path: string) -> string,
	// Lists a file inside the project folder as an asset (its kind from its extension)
	addAsset: proc(path: string) -> bool,
}
