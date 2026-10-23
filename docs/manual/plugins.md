---
title: Editor plugins
description: Extend the editor with your own Odin code — tool commands that change the project, importers for other file formats, and extra inspector rows — reloaded every time you save.
order: 37
---

# Editor plugins

A **plugin** is Odin code that adds to the editor itself, for your project: a command that lays out
a level, an importer that turns your spreadsheet into dialogue, inspector buttons for the nodes
your game uses most. Plugins live in the project (`plugins/`), so everyone working on it gets them;
the editor builds and loads them, and builds them again whenever you save.

A plugin can add:

| What | Where it shows | Example |
|---|---|---|
| **Commands** | buttons in the bottom panel's **Plugins** tab | "Arrange Children in a Grid", "Snap Everything to Pixels" |
| **Importers** | importing files of its extensions (Ctrl+I) | `.csv` lines into a dialogue, a level format into a scene |
| **Inspector rows** | the inspector, for nodes of some kinds or scripts | a note, a number, a checkbox, a button on every Sprite |

Plugins need Odin installed, like scripts do (Settings > Toolchain).

- [Your first plugin](#your-first-plugin)
- [What a plugin looks like](#what-a-plugin-looks-like)
- [The Host: reading and changing the project](#the-host-reading-and-changing-the-project)
- [Commands](#commands)
- [Importers](#importers)
- [Inspector rows](#inspector-rows)
- [How plugins are built and loaded](#how-plugins-are-built-and-loaded)

## Your first plugin

1. Open the bottom panel's **Plugins** tab and press **New Plugin**. The editor writes
   `plugins/my_plugin/my_plugin.odin` (a command and inspector rows to start from) and opens it in
   a code tab.
2. A moment later the tab shows it **Loaded**, with its **Count Nodes** button. Press it: the
   Console says how many nodes the scene has.
3. Select a Sprite: the inspector has a **my_plugin** section with its picture and a **Flip** button.
4. Change the code and save (Ctrl+S): the editor builds it again and swaps the new one in. Build
   errors go to the **Output** tab, and the Plugins tab says it failed.

Rename the folder and the `package` line to name your plugin; every folder in `plugins/` is a
plugin.

## What a plugin looks like

```odin
package grid_tools

import "core:fmt"
import api "plugin_api:."

// What it adds: package-level lists (a list written inside the procedure below would be gone
// when it returns)
commands := []api.Command{
	{name = "Arrange Children in a Grid", description = "Lays the selected node's children out in rows of four", run = arrange},
}

// The editor calls this when it loads the plugin
@(export)
crossfire_plugin :: proc(host: ^api.Host) -> api.Plugin {
	return {
		name = "Grid Tools",
		description = "Arranges nodes on a grid",
		version = api.PLUGIN_API_VERSION,
		commands = commands,
	}
}

arrange :: proc(host: ^api.Host) {
	parent := host.selected()
	if parent < 0 {
		host.log("Select a node whose children to arrange", warning = true)
		return
	}
	for child, i in host.nodeChildren(parent) {
		host.setProperty(child, "position", fmt.tprintf("%d, %d", (i % 4) * 48, (i / 4) * 48))
	}
}
```

- The package imports `plugin_api:.` (the editor passes that collection when it builds). Its types
  are `Plugin`, `Command`, `Importer`, `Inspector`, `InspectorRow` and `Host`.
- `crossfire_plugin` must be `@(export)`ed and return the plugin with `version =
  api.PLUGIN_API_VERSION` (a plugin built for another version isn't loaded).
- It can use Odin's core library (`core:os` for files, `core:strings`, `core:encoding/json`...). It
  doesn't use the engine: it changes the project through the Host.
- Its package variables keep their values while it's loaded (a setting it remembers), and start
  over when it's rebuilt.
- Use `context.temp_allocator` for anything temporary: the editor's frame memory.

## The Host: reading and changing the project

Every procedure a plugin gives gets the `host`. Nodes are numbered in the open scene (or
component), in scene tree order; `-1` means none (as a parent: the top level).

| Host procedure | Does |
|---|---|
| `log(text, warning = false)` | a line in the Console |
| `projectRoot()` | the project's folder |
| `sceneName()`, `nodeCount()` | the open scene |
| `nodeParent(node)`, `nodeChildren(node)` | its tree |
| `getProperty(node, property)`, `setProperty(node, property, value)` | a node's properties, as text |
| `addNode(kind, name, parent)`, `removeNode(node)` | adding and removing nodes |
| `selected()`, `selection()`, `select(node)` | the selection |
| `assets()`, `assetKind(path)` | the project's assets |
| `addAsset(path)` | lists a file inside the project folder as an asset |

Properties are written the way the inspector shows them: `"name"`, `"kind"` (read only),
`"position"` and `"scale"` (`"x, y"`), `"rotation"`, `"visible"` (`"true"`), `"layer"`,
`"z_index"`, `"texture"`, `"text"`, `"color"` (`"#ff8000"`), `"region"`, `"script"` (read only), and a
script's fields as `"script.speed"`.

An **AnimatedSprite's animations** (its own, or those of the animation asset it plays; an
Aseprite file's can be read, not changed):

| Property | Is |
|---|---|
| `"animations"` | the names, comma-separated (read only) |
| `"animation_set"` | the animation asset's path (`""`: its own animations) |
| `"autoplay"` | the one it starts with (`""`: the first) |
| `"animation.walk.sheet"` | the image the animation `walk` plays from |
| `"animation.walk.grid"` | `"Cells"` (columns x rows) or `"Size"` (cells of a size) |
| `"animation.walk.columns"`, `"rows"`, `"cell_size"` (`"w, h"`) | the grid; the values the mode doesn't set are worked out from the image |
| `"animation.walk.margin"`, `"spacing"` | pixels around the cells and between them |
| `"animation.walk.start"`, `"end"` | its first and last cell (`-1`: the sheet's last) |
| `"animation.walk.frames"` | `"first, last"`: the cells it plays (read only) |
| `"animation.walk.fps"`, `"loop"`, `"play_mode"`, `"repeat"` | how it plays (`"Forward"`, `"Reverse"`, `"PingPong"`, `"PingPongReverse"`) |
| `"animation.walk.durations"` | each frame's time in milliseconds, space separated (`""`: FPS for all) |
| `"animation.walk.sheet_size"`, `"cells"` | the image's size in pixels and its cell count (read only) |

```odin
// Given: host: ^api.Host, node: int
sheet, _ := host.getProperty(node, "animation.walk.sheet")
host.setProperty(node, "animation.walk.durations", "100 100 250")
```

## Commands

```odin
countNodes :: proc(host: ^api.Host) {
	host.log(fmt.tprintf("The scene has %d nodes", host.nodeCount()))
}

commands := []api.Command{
	{name = "Count Nodes", description = "Logs how many nodes the scene has", run = countNodes},
}
```

Each command is a button in the Plugins tab (its description is the button's tooltip). Whatever a
command changes in the project is **one undo step**: Ctrl+Z puts it all back.

## Importers

```odin
importCSV :: proc(host: ^api.Host, source: string) -> (asset: string, problem: string) {
	// Read `source` (the file the user picked), write what the project needs inside its folder,
	// list it with host.addAsset, and return the asset to select
	// ...
	return "dialogues/talk.dialogue.xml", ""
}

importers := []api.Importer{
	{extensions = {"csv"}, description = "speaker,text lines into a dialogue", run = importCSV},
}
```

When the user imports a file whose extension a loaded plugin takes, the plugin's importer runs
instead of the editor's own. Return `problem` (and no asset) when the file can't be imported: the
Console shows it.

## Inspector rows

```odin
inspectors := []api.Inspector{
	{targets = {"Sprite", "script:Enemy"}, rows = spriteRows, changed = spriteChanged},
}

spriteRows :: proc(host: ^api.Host, node: int) -> []api.InspectorRow {
	rows := make([]api.InspectorRow, 2, context.temp_allocator)
	rows[0] = {label = "Picture", kind = .Note, value = "..."}
	rows[1] = {id = "snap", label = "Snap", kind = .Button, value = "Snap to the Grid"}
	return rows
}

spriteChanged :: proc(host: ^api.Host, node: int, id, value: string) {
	if id == "snap" {
		// Pressed: change the node through the host
	}
}
```

- **targets**: node kinds (`"Sprite"`, `"Label"`, a node type of your code) and scripts
  (`"script:Enemy"`: nodes running that script).
- **rows** is asked every time the inspector draws: only read here. Row kinds: `.Note` (text to
  read), `.Text`, `.Number` (fields), `.Bool` (a checkbox: `"true"` / `"false"`), `.Choice` (a
  dropdown of `choices`), `.Button` (`value` is its text).
- **changed** is called with the row's `id` and new value (a button: `""`); its changes are an
  undo step.

## How plugins are built and loaded

- While the project has a `plugins/` folder, the editor looks at it twice a second. A plugin whose
  `.odin` files are newer than its last build is built (`odin build plugins/<name>
  -build-mode:shared`) into the editor's `build/plugins/` folder, a new file each time, and
  loaded in place of the old one. One builds at a time; the others wait.
- The **Plugins** tab lists each one: Waiting, Building, Loaded or Failed (and why). **Rebuild
  All** builds them all again.
- Plugins run inside the editor, with its rights: only use plugins you trust, like any code in the
  project.
- Exported games don't contain plugins: they're for the editor only.

## Questions

**My plugin says Failed.** The Output tab has the compiler's errors. "exports no crossfire_plugin
procedure": add `@(export)`. "made for plugin API version 0": set `version = api.PLUGIN_API_VERSION`.

**It says "It is unsafe to return a compound literal of a slice".** Declare the lists at package
level (`commands := []api.Command{...}`), not inside `crossfire_plugin`.

**My inspector rows don't show.** Check the target spells the kind as the scene tree does
(`"Sprite"`, `"AnimatedSprite"`) and the plugin is Loaded.
