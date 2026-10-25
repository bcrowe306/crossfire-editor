---
title: LDtk parity
description: "Every feature of LDtk 1.5.3, checked against the Level mode: done, done differently (and why), not done (and why), or not applicable (LDtk's app itself: its window, updates, home page). Read from LDtk's source, section by section."
order: 22
---

# LDtk parity

The Level mode is meant to make LDtk unnecessary for editing levels: everything you do in LDtk to
an LDtk project, you can do here, and the file it writes is the file LDtk would write. This page
checks that, feature by feature, against LDtk 1.5.3's source (the workspace's `ldtk/`): its
keys, its tools, its panels, what it writes when it saves, the file format. Each feature is:

- **Done**: here, as LDtk does it (its rules ported; LDtk's own sample files are the tests).
- **Differently**: here, in another way, for the reason given.
- **Not done**: not here yet, with why (the open ones are in the project's TODO.md).
- **N/A**: LDtk the app rather than the editing (its window, updates, home page, crash reports):
  the editor has its own, or doesn't need one.

**The count** (2026-10-25): 429 features: **305 done**, **60 done differently**, **41 not done**,
**23 not applicable**. Everything you need to edit levels, worlds, definitions, rules and the
project is done; what isn't is mostly convenience (a command palette, keyboard navigation in the
palettes, a few view toggles), app features LDtk has around the editing, and two rarely used
operations (baking an auto-layer, moving entities between layers).

The guides: [Level mode](level_mode.md), [Levels, worlds and the project](level_worlds.md),
[Level definitions](level_definitions.md), [Auto-layer rules](level_rules.md).

- [Keyboard](#keyboard)
- [Mouse and modifiers](#mouse-and-modifiers)
- [View options](#view-options)
- [The world view](#the-world-view)
- [The World panel](#the-world-panel)
- [A level's properties](#a-levels-properties)
- [Project settings](#project-settings)
- [The Layers panel](#the-layers-panel)
- [Auto-layer rules](#auto-layer-rules)
- [The Entities panel](#the-entities-panel)
- [Fields' definitions](#fields-definitions)
- [Fields' values and the entity editor](#fields-values-and-the-entity-editor)
- [Painting](#painting)
- [Selecting, moving, resizing](#selecting-moving-resizing)
- [The Enums panel](#the-enums-panel)
- [The Tilesets panel](#the-tilesets-panel)
- [Other parts of LDtk's interface](#other-parts-of-ldtks-interface)
- [Saving and exports](#saving-and-exports)
- [The file format](#the-file-format)
- [LDtk the app](#ldtk-the-app)
- [Questions](#questions)

## Keyboard

Every key below is in **Settings > Keyboard** (the Level mode's actions), where you can change it.

| LDtk | Here |
|---|---|
| Save (Ctrl+S) | **Done**: the project's Save writes the LDtk files (Play, Export and Open in LDtk save first) |
| Save as (Ctrl+Shift+S) | **Differently**: the project's Save Project As copies the whole project, its LDtk files included |
| Close project (Ctrl+W) | **N/A**: the editor's File menu; the Levels sidebar picks the LDtk file |
| Rename project | **Not done**: rename the `.ldtk` file (and its levels' folder) outside the editor, then import it again |
| Esc's chain (cancel a pick, a chain, the tool, the selection) | **Done**: Esc cancels a pick, a new level's spot, the selection, the stroke |
| App settings (F12) | **N/A**: the editor's Settings (Ctrl+,) |
| Undo, redo (Ctrl+Z, Ctrl+Y) | **Done**: one history for the whole editor, an undo step per edit |
| Select all (Ctrl+A; the layer only in single layer mode) | **Done** |
| Zen mode (Tab) | **Differently**: the sidebars and the bottom panel resize and collapse; Tab moves the keyboard between controls, as everywhere in the editor |
| Help panel (H) | **Differently**: F1 opens this manual in the docs window; tooltips name each key |
| World / level view (Shift+W) | **Done** |
| Run a custom command (Ctrl+R) | **Not done**: on purpose: commands are kept and edited (the Project tab) but never run; a project file could make the editor run any program |
| Quit (Ctrl+Q) | **N/A**: the editor's Quit |
| Minimize, hide, fullscreen | **N/A**: the window's own |
| Previous / next world depth (PgDn / PgUp) | **Done** |
| Move the level to another depth (Ctrl + PgDn / PgUp) | **Done** |
| Panels: Project P, Layers L, Entities E, Enums U, Tilesets T, Level C (again: close) | **Done**: they show the bottom tab; again closes the panel |
| Palette navigation (WASD, ZQSD or arrows) | **Not done**: pick in the palette with the mouse |
| Auto-layer tiles shown (Shift+R) | **Done** |
| Select empty spaces (Shift+E) | **Done** |
| Tile stacking (Shift+T) | **Done** |
| Single layer mode (Shift+A) | **Done** |
| Show details (Ctrl+H) | **Not done**: fields and names always show (a layer's "hide fields when inactive" hides its own) |
| Grid (G) | **Done** |
| Command palette (Ctrl+F, Ctrl+K...) | **Not done**: the Levels sidebar, the tabs' lists and the Entities tab's list find things |
| Flip X / Y (X, Y, Shift+H, Shift+V) | **Done** |
| Random or stamp (R) | **Done** |
| Save a tile selection (Shift+S) | **Done** |
| Load the saved selection of a tile (Shift+L) | **Differently**: a click on a tile of a saved selection picks it all (Ctrl + click: just that tile), as LDtk's palette does |
| Layers by number (1 to 9, 0) | **Done** |
| Layers by F1 to F10 | **Differently**: F1 is the editor's help; the number keys pick layers |
| A quick tap on Space fits the view | **Differently**: the canvas header's Fit |
| Zoom with + and - held | **Not done**: the wheel zooms |
| Delete the selection (Delete) | **Done** |
| Debug menu (Ctrl+Shift+D) | **N/A** |
| Home page keys, help page lists and links | **N/A**: the editor's own menus; Settings > Keyboard lists every key |

## Mouse and modifiers

| LDtk | Here |
|---|---|
| Left button paints, right erases | **Done** |
| macOS: Ctrl + click erases | **Differently**: Ctrl + click is a right click on a Mac for the whole editor, which erases |
| Middle drag, Space + drag pan | **Done** (a right drag on empty space too) |
| Space + right drag zooms | **Not done**: the wheel zooms |
| The wheel zooms around the pointer (its speed a setting) | **Done**: Settings > Editor > Wheel pans swaps zooming and panning |
| Shift + drag: a rectangle | **Done** |
| Shift + a quick click: a fill | **Done** |
| Alt + click picks what's under the pointer | **Done** |
| Shift + Alt + drag: a rectangle selection | **Done** |
| Ctrl + Alt + drag on a selection copies it | **Done** |
| A drag on the selection moves it | **Done** |
| A click on an entity of the active layer selects and drags it | **Done** |
| A second click on a selected entity selects its points too | **Not done**: drag its points directly (they show while it's selected) |
| The pointer's coordinates in a footer (world, level, cell) | **Not done**: the brush's preview shows the cell; the status bar shows the world and level |
| A guide bar of the modifiers per layer type | **Differently**: the tools' tooltips list them, and the canvas says why a press did nothing |
| Cursors: cell, rectangle, stamp, entity ghost, eraser, forbidden, pan, resize | **Differently**: the brush, stamp and entity are drawn under the pointer; resize, move and crosshair cursors |

## View options

| LDtk | Here |
|---|---|
| Zen mode | **Differently**: see [Keyboard](#keyboard) |
| Grid on / off (off: free placement) | **Done** |
| Show details off ("tiles only") | **Not done** |
| Single layer mode (and its intensity setting) | **Done**: LDtk's default intensity |
| Auto-layer tiles shown | **Done** |
| Tiles' enum tags drawn on Tiles layers | **Not done**: the Tilesets tab shows a tile's tags on its picture |
| Select empty spaces | **Done** |
| Tile stacking | **Done** |
| Options greyed out for layer types that don't use them | **Differently**: the tool row shows the selected layer type's tools |
| Zoom limits | **Done** |
| Fit the view, scroll to the level | **Done**: the header's Fit; selecting a level or entity in the tabs centers it |
| World view when zooming far out, a level when zooming into it | **Not done**: double-click a level, the header's World button, Shift+W |
| The layer eye (saved in the file) | **Done** |
| A drag across eyes | **Not done**: click each |
| Shift + click on an eye: only this layer | **Not done** |
| The layer list's tag filter | **Not done**: the layers' filter tags are kept and edited |
| A layer's color in the list | **Done** |
| A layer hidden from the list | **Done** |
| A layer's documentation as a tooltip | **Not done**: it's edited in the Layers tab |
| A "Rules" button on auto-layers' rows | **Differently**: the Auto-layer Rules tab |
| Rulers: the level's size while resizing | **Done** |
| A layer's guide grid | **Done** |
| Nearby levels' tiles around the level | **Done**: the world's other levels, dimmed |
| The window title (file, unsaved, level) | **Differently**: the window title marks unsaved edits, the canvas header shows the level |
| Banners: a backup opened, the project's tutorial description | **Not done**: the description is edited in the Project tab; backups aren't opened from the editor |
| A "Rebuild all auto-layers" pending button | **Differently**: rules are applied again at every edit, so nothing waits |
| The window faded when unfocused | **N/A** |
| A flash on picked or removed elements | **Not done** |

## The world view

| LDtk | Here |
|---|---|
| A hovered level highlighted | **Done** |
| A click selects a level, another focuses it | **Done** (a double-click focuses) |
| In a level, a click on another level selects it | **Done** (focuses it) |
| Levels dragged in the world view | **Done** |
| Free worlds: snapping to the grid and other levels' edges, Shift or Ctrl: none | **Done** |
| GridVania worlds: on the world grid | **Done** |
| Linear worlds: a drag reorders, with the insertion line | **Done** |
| Ctrl + Alt + drag copies a level | **Done** |
| Right-click menu: New level here (a picker when there's no room) | **Done** |
| Right-click menu: Duplicate, Delete a level | **Done** (undo instead of LDtk's confirmation) |
| Right-click menu: go to another world, move the level to it | **Done** |
| The menu on empty space in the level view | **Done** |
| Only the active depth's levels respond | **Done** |
| The world depths' list | **Done**: the World tab's depth and PgUp / PgDn |
| The worlds' list | **Done**: the Levels sidebar's and World tab's choice |
| A level's eight resize handles | **Done** |
| Resizing on the layer's grid (the world's in GridVania), its size shown | **Done** |
| Left and top edges move the level; at least a cell | **Done** |
| The new level picker (a preview, no overlaps, the grid) | **Done** |
| New levels at the shown depth, the world's default size | **Done** |
| Neighbours worked out in eight directions and across depths | **Done** |
| Automatic names applied again after moves | **Done** |
| The world render: layers shown in the world view, names, fields shown in the world | **Done** |
| A level's LevelTile field drawn instead of its picture | **Not done**: the level's picture shows |

## The World panel

| LDtk | Here |
|---|---|
| The world choice (Multi-worlds) | **Done** |
| Create a world | **Done** (Multi-worlds turned on as LDtk does) |
| Delete a world (not the last) | **Done** (undo instead of confirmation) |
| Create a level | **Done** |
| Duplicate, delete the level | **Done** (undo instead of confirmation) |
| The world's IID, copied | **Done** |
| The world's name (Multi-worlds only) | **Done** |
| The layout (Free, GridVania, linear), levels moved | **Done** |
| GridVania's grid | **Done** |
| New levels' size (on the world grid) | **Done** |
| The level's form in the panel | **Differently**: the Level tab |
| Closing the panel leaves the world view | **N/A**: the tabs aren't modal |

## A level's properties

| LDtk | Here |
|---|---|
| IID, copied | **Done** |
| Name, unique | **Done** (scenes naming it follow) |
| Automatic name by the project's pattern | **Done** |
| World depth, Further / Closer | **Done** |
| World X / Y on the world grid | **Done** |
| Width and height (on the grid, up to 4096) | **Done**: kept or cropped from the chosen side, as LDtk |
| Background color, "Use default" | **Done** |
| Background image: pick, reload, recent, remove, locate | **Differently**: picked from the project's images, removed; no recent list or locate |
| Background position (Unscaled, Contain, Cover, Cover dirty, Repeat) | **Done** |
| Background pivot | **Done** |
| Custom fields, "Edit custom fields" | **Done** (the Level tab) |
| The form disabled for levels of another depth | **Differently**: every level's form can be edited |
| A background image reloaded when it changes on disk | **Not done**: it's read again when the level changes |

## Project settings

| LDtk | Here |
|---|---|
| Save | **Done**: the Project tab's Save |
| Save as, rename, locate | **Not done**: Save Project As copies the project; rename and locate in the file manager |
| A backup opened: "Restore this backup" | **Not done**: backups are written; restore one by copying it over the project |
| Super simple export | **Done**: `simplified/` as LDtk writes it |
| Save levels to separate files | **Done**: `.ldtkl` files, written whole as LDtk writes them |
| Image export: none, per layer, per level, both | **Done**: drawn by the editor's renderer (a pixel can differ from LDtk's where tiles blend) |
| Also export level backgrounds | **Done** |
| PNG file name pattern (%world, %level_name, %level_idx, %layer_name, %layer_idx) | **Done** |
| Tiled export | **Not done**: on purpose: LDtk's exports only the first world (its own note); the setting is kept for LDtk |
| `.ldtk` or `.json` file extension | **Not done**: the editor reads `.ldtk` files |
| Backups on save | **Done** |
| The backup folder | **Done** |
| How many backups are kept (3 to 50) | **Done** |
| "Backups recommended" for big projects | **N/A** |
| Minify JSON | **Done** |
| Identifier style, everything renamed | **Done** |
| Custom commands (text, when it runs; add, remove, reorder) | **Differently**: kept and edited, never run (see Ctrl+R above) |
| Commands' trust status | **N/A**: nothing runs |
| Default grid size | **Done** |
| Default entity size | **Done** |
| Level name pattern (%world, %idx1, %idx, %x, %y, %gx, %gy, %depth) | **Done**: a text field; its variables listed in its tooltip |
| Workspace background color | **Done** |
| Default level background color | **Done** |
| Default entity pivot | **Done** |
| The Advanced section | **Differently**: always open |
| Flag: Multi-worlds (locked with several worlds) | **Done** |
| Flag: index in level file names | **Done** |
| Flag: the old IntGrid format | **Done**: the legacy `intGrid` arrays written, kept in step by painting |
| Flag: the Multilines type | **Done** |
| Flag: the old table of contents | **Done** |
| Hidden flags (IgnoreBackupSuggest, DiscardPreCsvIntGrid) | **Done**: kept as they are |
| The tutorial description | **Done** (edited; not shown as a banner) |
| "Enable backups?" on opening a big project | **N/A** |

## The Layers panel

| LDtk | Here |
|---|---|
| Create a layer by type | **Done** |
| The list: reorder, search, type icons, colors | **Done** (a choice list) |
| Copy, cut, paste, duplicate, delete a layer | **Differently**: Duplicate and Delete; no clipboard between projects |
| Paste into the list | **Not done**: no definitions' clipboard |
| Delete: a warning when it's an auto-layer's source | **Differently**: undo instead |
| Tutorial buttons | **N/A** |
| Name, documentation | **Done** |
| Default tileset, "Create a new tileset" | **Done** |
| Grid size, cells remapped in every level | **Done** |
| Offsets, opacity, inactive opacity | **Done** |
| Parallax and its scaling | **Done** |
| Color in the list | **Done** |
| Hidden from the list | **Done** |
| Shown in the world view | **Done** |
| Selectable while inactive | **Done** |
| Asynchronous render | **Differently**: kept; the editor always draws levels in pieces |
| Guide grid | **Done** |
| Filter tags | **Done** (edited; the list's filter isn't) |
| Entities: hide fields when inactive | **Done** |
| Entities: required and excluded tags | **Done** |
| Move existing entities to another layer | **Not done**: move them with the selection (Ctrl + Alt copies, Delete removes) |
| IntGrid: the values' icon tileset | **Done** |
| IntGrid: add a value or a group | **Done** |
| IntGrid value: color, icon, name, remove, drag between groups | **Done** (a group choice instead of a drag) |
| IntGrid group: rename, add to it, delete, color | **Done** |
| Tiles: tile pivot | **Done** |
| Auto-layer: source layer | **Done** |
| Auto-layer: tileset, "Edit rules" | **Done** |
| Tiles removed under a Tiles layer | **Done** |
| Biome enum | **Done** |
| Bake an auto-layer into a Tiles layer | **Not done**: open in TODO.md |

## Auto-layer rules

| LDtk | Here |
|---|---|
| "+ Group" (Assistant, empty), Randomize, Render, the level's own tileset | **Done** |
| A group on and off; optional groups per level | **Done** |
| Groups opened and closed | **Done** |
| Renamed | **Done** |
| Icon | **Done** |
| Biomes (values, Any, AND / OR) | **Done** |
| EDIT (the Assistant) and + rule | **Done** |
| Group menu: copy, cut, paste, duplicate, delete, rename, remap, color, icon | **Done** (a color wheel too) |
| Group menu: the out-of-bounds policy of every rule | **Done** |
| Group menu: edit with the Assistant, advanced mode | **Done** |
| Group menu: biome enum, optional on and off | **Done** |
| Duplicate and remap | **Done** |
| Groups and rules dragged, rules into other groups | **Done** |
| A rule on and off | **Done** |
| Its preview, a click opens its editor | **Done** |
| Chance and opacity | **Done** |
| Break on match | **Done** |
| Flips (refused on symmetric patterns) | **Done** |
| Random offsets (linked) | **Done** |
| Modulos and the checker | **Done** |
| Perlin noise and its settings | **Done** |
| Insert a rule before or after | **Done** |
| Rule menu: copy, cut, paste, duplicate, delete | **Done** |
| A hovered rule's cells shown on the level | **Done** |
| The rules of the cell under the pointer highlighted | **Done** |
| The last edited rule highlighted | **Done** |
| Tiles: single (random) or stamps | **Done** |
| Several tile rectangles | **Done** |
| The stamp's pivot | **Done** |
| The pattern up to 9 x 9, LDtk's three buttons | **Done** |
| The value palette: list or columns, groups, Any / None | **Done** (a list: no columns view) |
| "Enable help" in the rule editor | **Differently**: the tab's notes and this manual |
| The out-of-bounds policy | **Done** |
| The Assistant: values, its 47 parts, stacking | **Done** |
| Rules applied again in every level | **Done**: at once, with each edit (LDtk waits and shows a progress bar) |

## The Entities panel

| LDtk | Here |
|---|---|
| Create an entity type | **Done** |
| Presets (rectangle and circle regions) | **Done** |
| The list grouped by tags, sorted, searched | **Differently**: one choice list (reorder with Up / Down) |
| Copy, cut, paste, duplicate, delete | **Differently**: Duplicate and Delete (undo instead of LDtk's warning) |
| Live preview | **Differently**: the canvas shows the type's entities |
| Name, show the name | **Done** |
| Table of contents | **Done** |
| Out of level bounds | **Done** |
| Documentation | **Done** |
| Tags | **Done** |
| Size, minimum and maximum | **Done** |
| Resizable width, height, keep the aspect ratio | **Done** |
| Color, render mode (rectangle, ellipse, tile, cross) | **Done** |
| Its tile | **Done** |
| Tile render modes (cover, fit, repeat, stretch, full size, 9-slice) | **Done**: drawn as LDtk draws them |
| 9-slice borders | **Done** |
| Tile, fill, line opacity, hollow | **Done** |
| An icon for the interface | **Done** |
| Pivot | **Done** |
| Max count, its scope and behaviour | **Done** |
| Custom fields | **Done** |

## Fields' definitions

| LDtk | Here |
|---|---|
| "+ single value" / "+ array" by type | **Done** |
| Every type (Int, Float, Bool, String, Text, Color, Enum, Path, Tile, EntityRef, Point) | **Done** |
| The enum picker (by tag, by external file) | **Done** |
| The list: reorder, copy, cut, paste, duplicate, delete | **Differently**: reorder, duplicate, delete |
| Type conversions (and LDtk's warnings) | **Done** (undo instead of LDtk's warning) |
| Name, documentation | **Done** |
| Table of contents | **Done** |
| Searchable | **Done** (kept; no command palette searches it) |
| Default values | **Done** |
| Minimum, maximum | **Done** |
| Accepted file types | **Done** |
| Regular expression and its i flag | **Done** |
| The regular expression's "Test" website | **N/A** |
| Text language | **Done** |
| Can be null | **Done** |
| A tile field's tileset | **Done** |
| References: symmetrical, in any level, chained | **Done** |
| Allowed references (any, same, tags, one type) | **Done** |
| Array length limits | **Done** |
| Display mode (every one) | **Done**: drawn on the canvas as LDtk draws them |
| Display position (above, center, beneath) | **Done** |
| Link style | **Done** |
| Shown in the world view | **Done** |
| Display scale and color | **Done** |
| Prefix and suffix | **Done** |
| Always shown | **Done** |
| Long values cut | **Done** |
| The value as the smart color | **Done** |
| Level fields use the same form | **Done** |

## Fields' values and the entity editor

| LDtk | Here |
|---|---|
| A floating window for the selected entity | **Differently**: the Entities tab shows it, the canvas stays in view |
| Its type's name, a link to edit the type | **Differently**: the same tab edits the type above it |
| IID, copied | **Done** |
| X, Y, width, height (pixels or cells) | **Done** (pixels) |
| "References to this entity", followed with a click | **Done** |
| The type's documentation shown | **Not done**: shown where the type is edited |
| Fields' "Default" / "Required!" tags, reset to default | **Differently**: an empty field is its default |
| A field's menu: edit its definition | **Not done**: the field's definition is just above, in the same tab |
| Numbers with prefix, suffix, clamping | **Done** |
| Colors, reset | **Done** |
| Strings, the regular expression applied | **Done** |
| Multiline text in a text editor (with its language) | **Differently**: a text field |
| Enums: a list with icons and colors | **Differently**: a list of names |
| Bools | **Done** |
| Paths: pick, edit the file, locate, clear | **Differently**: typed, cleared |
| Points: picked on the canvas, a path keeps adding, removed | **Done** |
| References: picked on the canvas (any level), followed, cleared | **Done** |
| Tiles: picked, cleared | **Done** |
| Arrays: add, remove, reorder | **Done** |
| The field instances' JSON (`__value`, `realEditorValues`...) | **Done**: as LDtk writes it |

## Painting

| LDtk | Here |
|---|---|
| IntGrid: lines, erase, rectangle, fill | **Done**: LDtk's line and fill orders |
| IntGrid palette: groups, collapsible, search, columns | **Differently**: a list of the values |
| IntGrid palette: navigation keys; "Edit layer" | **Not done**: the Layers tab edits it |
| Tiles: stamps | **Done** |
| Tiles: random | **Done** |
| Tiles: a rectangle repeats the stamp; a fill | **Done** |
| Tiles: flips | **Done** |
| Tiles: stacking; erasing the top tile | **Done** |
| Tiles: a tileset grid bigger than the layer's | **Done** |
| Tiles: a level's own tileset ("incompatible size" refused) | **Done** |
| The tile palette's buttons (random, save the selection, fit) | **Done** (the wheel and Ctrl + wheel instead of Fit) |
| The tileset picker: drag, Shift / Ctrl add, Ctrl + click and the right button remove | **Done** |
| The tileset picker: scroll, zoom, remembered per tileset | **Done** |
| Saved tile selections recalled by a click (not with Ctrl) | **Done** |
| Navigation keys in the tileset | **Not done** |
| The palette over the canvas when it's not fitted | **Differently**: the palette stays in its sidebar |
| Alt + click picks a tile (flips, its saved selection) | **Done** |
| Alt + click picks an IntGrid value | **Done** |
| Each layer remembers its picked value | **Done** |
| A stroke started outside the level paints once it enters | **Done** |
| Drawing paused while painting | **Differently**: only the changed pieces are drawn again |
| Entities: on the grid by their pivot, or free without the grid | **Done** |
| Entities: a resizable type sized by the placing drag | **Done** |
| Entities: count limits on placing | **Done** |
| Entities: chained references | **Done** |
| Entities: the right button removes entities or points | **Done** |
| Entities: refused while details are hidden | **N/A**: details always show |
| Entity palette: tags, search, columns; "Edit" | **Differently**: a list of the types the layer takes |
| AutoLayer layers have no brush | **Done** |

## Selecting, moving, resizing

| LDtk | Here |
|---|---|
| Cells, entities and points, across layers (one in single layer mode) | **Done** |
| Visible layers, "selectable while inactive" | **Done** |
| A picked element's layer becomes the selected one | **Done** |
| Rectangles, with empty spaces | **Done** |
| Select all | **Done** |
| Moved with a preview and an arrow, on the grid | **Done** |
| Empty spaces clear where they land | **Done** |
| Ctrl + Alt copies; count limits | **Done** |
| Mixed grid sizes refused | **Differently**: each layer's cells move by whole cells of its own grid |
| Entities out of the level removed unless allowed | **Done** |
| Delete removes the selection | **Done** |
| A single cell picked isn't kept as a selection | **Done** |
| Entity resize handles (grid, aspect ratio, limits) | **Done** |

## The Enums panel

| LDtk | Here |
|---|---|
| Create an enum | **Done** |
| Import from text, JSON, Haxe, CastleDB | **Done** |
| The list by tag and source file, search, reorder | **Done** |
| Copy, cut, paste, duplicate, delete | **Differently**: duplicate and delete (undo instead of the warning) |
| External sources: sync, locate, remove | **Done** (locate: not) |
| External enums are read only | **Done** |
| Name, icon tileset, tags | **Done** |
| Its source file and checksum | **Done** |
| Values: add, name, color, icon, delete, reorder | **Done** |
| Sync with LDtk's diff | **Done**: what a sync would remove is shown first |
| Files watched and synced automatically | **Differently**: the tab says when a file changed; Sync applies it |
| Checksum checked on opening | **Done** |
| A lost file relocated | **Not done**: fix the path in LDtk, or put the file back |
| CastleDB colors and icons | **Done** |

## The Tilesets panel

| LDtk | Here |
|---|---|
| Create a tileset (pick its image) | **Done** |
| The list by tag, reorder, search; LDtk's icons marked | **Done** |
| Copy, cut, paste, duplicate, delete | **Differently**: duplicate and delete |
| Its image: PNG, GIF, JPG, Aseprite; reload, recent, remove, locate | **Differently**: picked from the project's images (Aseprite files too); no recent list or locate |
| The last image folder remembered | **N/A**: images come from the project |
| The name from the image | **Done** |
| Name, tile size, spacing, padding | **Done** |
| A new grid remaps tile ids | **Done** |
| Tags | **Done** |
| The enum tagging tiles | **Done** |
| Tags painted on tiles | **Done** |
| Custom data per tile | **Done** |
| A tile's tags and data in a tooltip | **Differently**: shown beside the picture for the picked tile |
| LDtk's internal icons | **Done** (the tileset; LDtk's picture needs a copy beside the file) |
| Opaque tiles and average colors | **Done**: byte for byte LDtk's |
| Images reloaded when they change | **Not done**: a tileset's picture is read once a session (open the project again) |

## Other parts of LDtk's interface

| LDtk | Here |
|---|---|
| Command palette | **Not done** |
| Quick search boxes in lists | **Differently**: choice lists and the Levels sidebar |
| The tag editor (rename everywhere) | **Differently**: tags typed; renamed per definition |
| The name pattern editor | **Differently**: a text field |
| The pivot editor (nine presets, exact values) | **Done** |
| The color picker (hex, recent colors, color-blind palette) | **Differently**: a color field and a color wheel; LDtk's palette for rule groups |
| "Copy URL" menus | **N/A** |
| Collapsible sections remembered | **Differently**: sections stay open |
| LastChance (undo a destructive change for 20 s) | **Differently**: every change is undoable with Ctrl+Z, any time |
| Notifications | **Differently**: the tab's note and the Console |
| The level's undo timeline (30 states per level) | **Differently**: one history for the editor, each edit a step |
| Log dialogs, confirm and choice dialogs | **Differently**: refusals say why in the tab; undo instead of confirmations |

## Saving and exports

| LDtk | Here |
|---|---|
| The save's order (checks, backup, files, images, exports) | **Done**: backup, the files, then LDtk's extra files |
| Checks (network drives, permissions) | **Differently**: a file that can't be written is reported, nothing is half written |
| Saving a sample inside LDtk's folder | **N/A** |
| The project file with its header, pretty or minified | **Done**: byte for byte LDtk's JsonPretty |
| Separate level files in `<project>/`, stale ones removed | **Done** |
| Per-level JSON caching | **Differently**: only changed files are written |
| The table of contents | **Done** |
| PNG export | **Done** |
| Tiled export | **Not done**: see [Project settings](#project-settings) |
| Super simple export (data.json, CSVs, PNGs) | **Done** |
| Backups (timestamped, pruned) | **Done** |
| Backups and crash files listed on the home page, restored | **Not done**: see [Project settings](#project-settings) |
| Rename the project (its folder too) | **Not done**: see [Keyboard](#keyboard) |
| A save asked for files of an older LDtk | **Differently**: files older than LDtk 1.0 aren't edited (the tab says so); open them in LDtk once |

## The file format

| LDtk | Here |
|---|---|
| The project's members (every one of JSON_SCHEMA.json) | **Done**: every member kept or written as LDtk writes it |
| Worlds | **Done** |
| Levels (backgrounds' `__bgPos`, `__smartColor`, `__neighbours`, external paths) | **Done** |
| Layer instances (CSV, tiles, entities, seeds, optional rules, overrides) | **Done** |
| Tiles (`px`, `src`, flips, ids, alpha) | **Done** |
| Entity instances (`__grid`, `__pivot`, `__worldX`, `__smartColor`, `__tags`, `__tile`) | **Done** |
| Field instances | **Done** |
| References, grid points, tile rectangles | **Done** |
| The table of contents (and its old form) | **Done** |
| Definitions | **Done** |
| Rule groups and rules | **Done** |
| IntGrid values, groups, instances | **Done** |
| Enums, tilesets, custom data | **Done** |
| Custom commands | **Done** |
| Flags | **Done** |
| `.ldtk`, `.ldtkl`, the index prefix | **Done** |

## LDtk the app

| LDtk | Here |
|---|---|
| Home page (new, load, Ogmo import, samples, settings) | **N/A**: the editor imports `.ldtk` files; Ogmo projects aren't imported |
| Home page links | **N/A** |
| Recent projects and folders | **N/A**: the editor's recent projects |
| Backups on the home page | **Not done**: see [Project settings](#project-settings) |
| New project | **Differently**: a new LDtk project is made in LDtk once; the editor edits everything after |
| Ogmo 3 import | **Not done**: open it in LDtk once |
| Support, changelog, updates | **N/A** |
| Crash reports | **N/A**: the editor's own |
| A `.ldtkl` on the command line opens its level | **Differently**: Open in LDtk opens LDtk at the level the editor shows |
| Opening the last project and level | **Done**: the Level mode remembers its file and world |
| "Unsaved changes" on closing | **Done**: the editor's save prompt |
| Files watched (tilesets, backgrounds, external enums) | **Differently**: external enums say they changed; images are read once a session |
| Lost files relocated | **Not done** |
| Custom commands run, after loading too | **Not done**: on purpose (see Ctrl+R) |
| The system clipboard for definitions | **Differently**: LDtk's clipboard within the editor (rules and groups); definitions are duplicated |
| Settings: UI scale, level UI scale, fields' look (outline or table), nearby levels, single layer intensity, color-blind colors, wheel speed, world view on the wheel, navigation keys | **Differently**: the editor's Settings (text size, theme, wheel pans); LDtk's outline look |
| Settings: start fullscreen, fade when unfocused, best GPU, auto update, log file | **N/A** |

## Questions

**Is something here written differently from LDtk?** No: what the editor writes is what LDtk
writes. The tests check it against LDtk's own sample files: written back, edited and undone, they
come back byte for byte, and every edited file is checked against LDtk's JSON schema and read by
the engine.

**A "not done" feature matters to me.** Tell us (the project's issues): the open ones are listed
in TODO.md, and LDtk itself still opens the same file meanwhile.

**Why aren't custom commands run?** A project file can name any program. Running what a file
says on open or save would let a downloaded project run anything on your computer, so the editor
keeps the commands for LDtk and never runs them.
