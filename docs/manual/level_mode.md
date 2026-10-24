---
title: Level mode
description: "The editor's LDtk level editor: your LDtk project's levels in a Levels sidebar and on a canvas you pan, zoom and rearrange, a tool row, a Layers sidebar, and LDtk's panels as tabs (World, Level, Layers, Entities, Enums, Tilesets, Auto-layer Rules, Project), saved into the .ldtk file when you save."
order: 18
---

# Level mode

The editor has **modes**, picked with the tabs beside the menu bar
([Editor modes](getting_started.md#editor-modes)). The **Scene** mode is where you build scenes
from nodes. The **Level** mode is the editor's **LDtk level editor**: the levels of an
[LDtk](https://ldtk.io) project, laid out as they are in its world, which you look into, move
around and edit, laid out like LDtk itself. Your edits are saved into the `.ldtk` file when you
save the project, so LDtk, the viewport and a running game all read the same file
([LDtk levels](levels.md)).

It's being built in phases. **Today** (phase 1) it edits what's there: where levels and entities
are, the layers' settings and order, which layers each level shows, entity types and their
fields, every field's value, IntGrid values, enums and the world's layout. Painting tiles and
IntGrid cells and placing entities come in phase 2 (until then, do them in LDtk); then the
definitions editors, auto-layer rules, and the rest of what LDtk does.

- [Opening it](#opening-it)
- [The window in the Level mode](#the-window-in-the-level-mode)
- [The tool row](#the-tool-row)
- [The Levels sidebar](#the-levels-sidebar)
- [The canvas](#the-canvas)
- [The Layers sidebar](#the-layers-sidebar)
- [The bottom tabs](#the-bottom-tabs)
- [Saving, undo and LDtk](#saving-undo-and-ldtk)
- [A narrow window](#a-narrow-window)
- [What's shared with the Scene mode](#whats-shared-with-the-scene-mode)
- [Questions](#questions)

## Opening it

- Click **Level** in the mode bar, at the top of the window beside the menus.
- Or **View > Level Mode**, or **Ctrl+Alt+2** (Cmd+Alt+2 on a Mac). **Ctrl+Alt+1** goes back to
  the Scene mode.

The editor remembers the mode for each project: open the project again and it shows the mode
you left it in, on the same LDtk file and world.

## The window in the Level mode

```
+--------------------------------------------------------------------+
| File Edit Scripts View Scene Help      [Scene | Level]             |
|        [select] [pencil] [rect] [fill] [eraser] [picker]   > || [] |
+-----------+--------------------------------------+-----------------+
| Levels    | World > Start      Fit  Open in LDtk | Layers          |
| Start     |                                      | = Entities  (o) |
| Cave      |   the canvas: the world, or the      | = Tiles     (o) |
| Tower     |   focused level larger               | = Walls     (o) |
|           +--------------------------------------+                 |
|           | World Level Layers Entities Enums ...|                 |
|           | the tab's settings                   |                 |
+-----------+--------------------------------------+-----------------+
```

| Part | What it's for |
|---|---|
| **Tool row** (top) | LDtk's tools for the selected layer, and the play controls at its end ([The tool row](#the-tool-row)) |
| **Levels** (left) | The world's levels: select one, double-click to focus it, right-click for its menu ([The Levels sidebar](#the-levels-sidebar)) |
| **Canvas** (middle) | The world's levels drawn as the game draws them, or one level larger ([The canvas](#the-canvas)) |
| **Layers** (right) | The selected level's layers: select one, show or hide it, drag it up or down ([The Layers sidebar](#the-layers-sidebar)) |
| **Bottom tabs** | LDtk's panels, then the **Console** and **Output** ([The bottom tabs](#the-bottom-tabs)) |

The menus and the mode bar stay at the top. The panels resize like the Scene mode's (drag the
dividers) and keep their own sizes.

## The tool row

The tool row replaces the toolbar in the Level mode. In the middle, the tools of the **selected
layer** (the Layers sidebar's), as LDtk has them for that kind of layer:

| Layer | Tools |
|---|---|
| **IntGrid** | Select, Pencil, Rectangle, Fill, Eraser, Picker |
| **Tiles** | Select, Stamp, Random, Rectangle, Fill, Eraser, Picker |
| **Entities** | Select, Place, Eraser, Picker |
| **Auto-layer** | Select (its tiles come from its rules) |

**Select** is the canvas as it works today: click to select a level or an entity, drag to move
it. The painting tools show greyed out: painting arrives in phase 2 (their tooltips say so). Until
then, paint in LDtk (**Open in LDtk**).

At its end are the **play controls**: Play, Play the scene open in the Scene mode, Pause, Stop and
Restart, as on the Scene mode's toolbar. The file and undo buttons are in the menus (**Ctrl+S**,
**Ctrl+Z**).

## The Levels sidebar

The left sidebar lists the levels of the world, in the world's order:

- **Click** a level: it's selected (on the canvas too, and the Layers sidebar shows its layers).
- **Double-click** it: the canvas **focuses** on it ([The canvas](#the-canvas)).
- **Right-click** it: its menu: **Focus** (or **Back to the World**), **Open in the Scene Mode**
  (the scene showing it), **New Scene with This Level**, **Open in LDtk at This Level**. Rename,
  Duplicate, Delete and New Level are listed greyed out: they're LDtk's until a later phase.

With several LDtk files in the project, a choice at the top picks the one shown. With several
**worlds** in the file (LDtk's Multi-worlds), a second choice picks the world: the sidebar and the
canvas show its levels (the World tab has the same choice). Without an LDtk file, the sidebar has
**Import...**.

## The canvas

The canvas shows every level of the world where the world puts it, with its layers, its
background and its entities as the game shows them. On top of them:

- each level's **name**, in its top-left corner, and an outline (the selected level's in the
  accent color);
- each **entity**'s outline in its color (when you're zoomed in far enough to see them; the
  selected entity's always);
- **links**: an arrow from each entity to the entities its reference fields point at (an
  EntityRef field: a door to the door it leads to), and, for the selected level, dashed lines to
  its **neighbouring** levels.

The header above it says where you are (**World**, or **World → Start** while a level is
focused), whether the file has unsaved edits, the zoom, and its buttons: **Focus** the selected
level, **World** (back to the world view), **Fit**, **Open in LDtk**.

**Focusing a level** (double-click it here or in the Levels sidebar, or the header's Focus) shows
that level larger, the others faded around it, as LDtk's level view does. While it's focused,
clicking another level focuses that one, its entities are the ones you can pick, and the level
doesn't move when you drag it (the drag pans). **Double-click outside it**, or the header's
**World** button, to go back to the world view.

To move around:

| Do | What happens |
|---|---|
| **Wheel** | Zoom in and out around the pointer |
| **Shift + wheel**, **Ctrl + wheel**, sideways scrolling | Pan (like the viewport; **Settings > Editor > Wheel pans** swaps zooming and panning, for touchpads) |
| **Middle** or **right drag**, **Space + drag**, a drag on empty space | Pan |
| **Fit** (the header's button) | The whole world (or the focused level) in view |

To work on the world (the **Select** tool):

| Do | What happens |
|---|---|
| **Click** a level | Selects it |
| **Double-click** a level | Focuses it |
| **Drag** a level (the world view) | Moves it in the world |
| **Click** an entity | Selects it (and its level): the **Entities** tab shows it, ready to edit |
| **Drag** an entity | Moves it in its level, on its layer's grid; hold **Shift** to move it by the pixel |
| Click **empty space** | Selects nothing (in the world view) |

Where a dragged level lands depends on the world's layout: anywhere (in whole pixels) in a
**Free** world, on the world grid in a **GridVania** one. Levels of a **linear** world are placed
by their order, so they don't move: change the layout in the **World** tab first. Each move is one
undo step; the levels' neighbours (which LDtk works out from where levels touch) follow.

## The Layers sidebar

The right sidebar lists the selected level's layers, the top one first (as LDtk lists them). Each
row has a grip, the layer's name and type, and an eye:

- **Click** a layer to select it: the tool row shows its tools, and the **Layers** tab its
  settings.
- **The eye** shows or hides the layer in that level, as LDtk's eye does: it's saved in the file
  (the layer's `visible` in the level), so a game hides the layer too. Each click is an undo step.
- **Drag the grip** up or down to move the layer: it moves in every level (LDtk keeps one order
  for all of them). One undo step.

With no level selected, the sidebar lists the project's layers (select one; the eyes need a
level).

## The bottom tabs

The bottom panel's tabs are LDtk's panels, then the same **Console** and **Output** as the Scene
mode's. A tab strip wider than the panel scrolls sideways. Every control sends an edit, made at
once in the LDtk file the editor has open (saved with the project: [Saving, undo and
LDtk](#saving-undo-and-ldtk)); what isn't editable here yet says so.

Fields' values are typed as text: a number, `true` or `false` (a checkbox), a color as
`#RRGGBB`, a point as `x, y` (cells), an enum's or a reference's value from a list. An empty
field is the field's default. Names are cleaned up as LDtk does (spaces and other characters
become `_`, the project's identifier style applies: `my door` becomes `My_door`) and must not be
taken; a name that can't be used isn't kept, and the tab says why above its rows.

### The World tab

The world: with several worlds, which one shows; its **layout** (Free, GridVania, linear side by
side or one above the other: changing it moves the levels as LDtk would), its **grid**
(GridVania's; the levels move with it), and each level's **X** and **Y**.

### The Level tab

The selected level: its size and place in the world, how many layers, entities, fields and
neighbours it has; the **scenes showing it** (click one to open it in the Scene mode, its
LDtkLevel node selected) or **New Scene with This Level**; its custom **fields**; its
**neighbours**. With no level selected, how many levels the world has and the level fields'
names.

A level shows in a scene through an **LDtkLevel** node naming it
([Putting a level in a scene](levels.md#putting-a-level-in-a-scene)). **New Scene with This Level**
makes a scene named after the level, with a World node and an LDtkLevel node showing that level,
and opens it in the Scene mode. It's one undo step: **Ctrl+Z** takes the scene away again and
goes back to the Level mode. Scenes whose LDtkLevel node shows **All levels** are listed for every
level, after the ones naming it.

### The Layers tab

The selected layer (the Layers sidebar's, or the choice at the top): its **name**, its type,
whether the selected level shows it, its **opacity**, **parallax** (X, Y, scaling), its **grid
size** (only while nothing is painted in it: LDtk moves painted cells when it changes) and its
**order** (Up / Down, or the sidebar's grip). An **IntGrid** layer's values follow: each value's
**name** and **color**, and, for every scene whose LDtkLevel node uses that layer for collision,
what each value becomes there (**Solid**, **One-way platform**, **Area**, **Nothing**: the node's
settings, not the file's).

### The Entities tab

Pick an entity type: its **name**, **width**, **height**, **color**, **pivot**; its **fields**'
names and defaults; the type's entities in the selected level (all of them with none selected).
Click one to select it (and center the canvas on it): its position and every field's value are
edited below it. Then the level's **references**: the entity reference fields of its entities,
each pointing at an entity the field allows.

### The Enums tab

Pick an enum: its **name**, each value's **name** and **color**; **add a value**, **add an
enum**. External enums (from a file) are listed; they're edited in their file.

### The Tilesets tab

What each tileset is: its image, size and grid. Tilesets are edited in LDtk for now.

### The Auto-layer Rules tab

A summary of each layer's auto-layer rule groups (how many rules, how many active). The rules are
edited in LDtk for now: phase 4 edits them here.

### The Project tab

The LDtk file's own settings, read only for now (its version, worlds, identifier style, default
grid and level size, background, whether levels are saved in separate files), and whether it has
unsaved edits, with **Save**.

What LDtk keeps in step is kept too: renaming an entity type renames it on every entity and in
the project's table of contents, renaming an enum value changes every field set to it, a layer's
opacity is every level's, a moved level's entities get their new world positions. A renamed
layer or entity type is renamed in your scenes' LDtkLevel nodes too (their collision layer and
entity rules), in the same undo step. Scripts named like an entity type aren't renamed.

Not editable here yet (LDtk edits them, and the tabs say so): array fields, tile fields,
symmetrical references, external enums, tilesets, levels' sizes and names, new or deleted levels,
the order of a linear world's levels, a field's or a layer's type, auto-layer rules, the project's
settings.

## Saving, undo and LDtk

- **Edits stay in the editor until you save**, as in LDtk: each edit changes the LDtk file the
  editor has open, the canvas, the viewport and the inspector show it at once, and the project
  shows **Modified** (the canvas's header says "unsaved"). **Save** (Ctrl+S) writes it, the files
  its levels are saved in apart (LDtk's "Save levels to separate files": `.ldtkl` files) included.
  **Play** and **Export** save it first, so the game reads your edits, and so does **Open in
  LDtk**.
- **Nothing else in the file changes:** the editor only rewrites the values it edits, in LDtk's
  style, so LDtk opens it as before and your version control shows small changes. Each file is
  replaced whole when it's written, never left half written.
- **Undo** (Ctrl+Z) takes an edit back, one step per edit (typing a name or a value is one step).
  Undo back to what was saved and there's nothing left to save.
- **LDtk saved the file** while the editor had it open: the editor reads it again (the status bar
  and the canvas's header say when). If you had unsaved edits, LDtk's change is **merged** with
  them when the two are in different places in the file. When they're in the same place, a bar
  over the canvas asks: **Reload It** (the file as LDtk saved it; your unsaved edits go) or **Keep
  My Edits** (saving then writes them over LDtk's change); saving waits for the answer. An undo
  after LDtk's change works the same way: merged when it can be, else the editor asks whether to
  **overwrite** LDtk's change or **keep the file** as it is.
- **LDtk doesn't notice the editor's changes** while it has the file open, and its next save
  writes over them. Edit in one at a time: close the project in LDtk (or open it again there)
  after saving here.
- **Open in LDtk** opens the file at the selected level (or the selected entity's level: LDtk
  can't be told which entity to select). LDtk's command line only takes the file, so the editor
  sets the level LDtk remembers in its own settings ("last project") before starting it.

## A narrow window

The Level mode fits smaller windows:

- **Under about 1100 px wide**, the tool row and rows are smaller (the toolbar's size), and the
  sidebars are at most 220 px wide.
- **Under about 760 px wide** (a tiled window), there's one sidebar: the levels over the layers.
- **The tools** go into a **...** menu when they don't fit beside the play controls.
- The bottom tabs scroll sideways; the tabs' rows put their labels over their controls when the
  panel is narrow.

## What's shared with the Scene mode

The menus, the play controls, the **Console** and **Output** tabs, **Settings** and **Project
Settings**, and the docs window are the same in both modes. The Scene mode's toolbar tools
(Select, Move, Rotate...) and its project browser don't show here, and the commands for nodes and
the viewport (Add Node, Delete, Copy, the grid, the zoom...) are greyed out in the menus.

**Undo** is one history for both modes: Ctrl+Z undoes the last edit wherever it was made, and
shows the mode (and the scene) it was made in. Playing, building and exporting show the Console
and Output tabs in whichever mode is showing.

Things that belong to the Scene mode bring it forward: opening a scene, selecting a node, opening
a script (the code tabs are beside the scene tabs), a Console line's error location, the status
bar's Git branch (the Git tab is the Scene mode's).

## Questions

**The world is empty.** The project has no LDtk file yet: import one (**Ctrl+I**, or the Levels
sidebar's **Import...**). See [LDtk levels](levels.md).

**I can't paint.** Painting comes in phase 2: the tools are there, greyed out. Paint in LDtk until
then (**Open in LDtk**, then save there).

**I changed the level in LDtk and the world didn't change.** It's read again when the file
changes: save in LDtk, then come back to the editor.

**My edit isn't in the game / in LDtk.** It's in the editor until you save: **Ctrl+S** (Play and
Export save first).

**My edit here disappeared after I saved in LDtk.** LDtk had the file open and saved its own copy
over it. Open the file again in LDtk after saving here (or undo LDtk's save there).

**A name I typed isn't kept.** It isn't a usable identifier, or another one has it: the tab says
why above its rows. Finish typing a name that works.

**I can't drag levels.** The world is linear (its levels are placed by their order): pick
**Free** or **GridVania** in the **World** tab. Or a level is focused: go back to the world view
(the header's **World** button).

**My entity jumps when I drag it.** It's placed on its layer's grid, as LDtk places it; hold
**Shift** to move it by the pixel.

**Where are the Scene mode's tools and the browser?** They're the Scene mode's (Ctrl+Alt+1).
