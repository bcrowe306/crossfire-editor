---
title: Level mode
description: "The editor's world editor: your LDtk project's levels on a canvas you pan, zoom and rearrange, entities you pick and move, and the LDtk tab, which edits layers, entities, fields, enums and the world and saves them into the .ldtk file."
order: 18
---

# Level mode

The editor has **modes**, picked with the tabs beside the menu bar
([Editor modes](getting_started.md#editor-modes)). The **Scene** mode is where you build scenes
from nodes. The **Level** mode is where you work on your game's **world**: the levels of an
[LDtk](https://ldtk.io) project, laid out as they are in it, which you can move around, look
into and edit. Every edit is saved into the `.ldtk` file at once, so LDtk, the viewport and a
running game all read the same file ([LDtk levels](levels.md)).

You still paint tiles and place new entities in LDtk; the Level mode edits what's there: where
levels and entities are, the layers' settings, entity types and their fields, every field's
value, IntGrid values, enums and the world's layout.

- [Opening it](#opening-it)
- [The window in the Level mode](#the-window-in-the-level-mode)
- [The world canvas](#the-world-canvas)
- [Levels and their scenes](#levels-and-their-scenes)
- [The LDtk tab](#the-ldtk-tab)
- [Saving, undo and LDtk](#saving-undo-and-ldtk)
- [What's shared with the Scene mode](#whats-shared-with-the-scene-mode)
- [Questions](#questions)

## Opening it

- Click **Level** in the mode bar, at the top of the window beside the menus.
- Or **View > Level Mode**, or **Ctrl+Alt+2** (Cmd+Alt+2 on a Mac). **Ctrl+Alt+1** goes back to
  the Scene mode.

The editor remembers the mode for each project: open the project again and it shows the mode
you left it in, on the same world.

## The window in the Level mode

```
+-----------+-----------------------------------------+--------------+
| browser   | World: legacy.ldtk   Fit  Open in LDtk  | Level        |
|           |                                         |              |
|           |   the world: every level in place, its  | the selected |
|           |   entities and links                    | level and    |
|           +-----------------------------------------+ entity, the  |
| preview   | bottom panel: LDtk, Console, Output     | scenes that  |
|           |                                         | show it      |
+-----------+-----------------------------------------+--------------+
```

| Part | What it's for |
|---|---|
| **Browser** (left) | The same project browser as in the Scene mode. Selecting an LDtk project there shows its world |
| **World** (middle) | The canvas: the LDtk project's levels, drawn as the game draws them. With several LDtk projects, the choice in its header picks one; **Fit** shows the whole world; **Open in LDtk** opens the file in LDtk at the selected level |
| **Level** (right) | The selected level: its size, where it is in the world, its layers, entities, fields and neighbours, the selected entity, and the scenes showing the level |
| **Bottom panel** | **LDtk** (the editor of the project's settings: below), and the same **Console** and **Output** as the Scene mode's |

The panels resize like the Scene mode's, and keep their own sizes: making the browser wider
here doesn't change it in the Scene mode.

## The world canvas

Every level of the world is drawn where the world puts it, with its layers, its background and
its entities as the game shows them. On top of them:

- each level's **name**, in its top-left corner, and an outline (the selected level's in the
  accent color);
- each **entity**'s outline in its color (when you're zoomed in far enough to see them; the
  selected entity's always);
- **links**: an arrow from each entity to the entities its reference fields point at (an
  EntityRef field: a door to the door it leads to), and, for the selected level, dashed lines to
  its **neighbouring** levels.

To move around:

| Do | What happens |
|---|---|
| **Wheel** | Zoom in and out around the pointer |
| **Shift + wheel**, **Ctrl + wheel**, sideways scrolling | Pan (like the viewport; **Settings > Editor > Wheel pans** swaps zooming and panning, for touchpads) |
| **Middle** or **right drag**, **Space + drag**, a drag on empty space | Pan |
| **Fit** (the header's button) | The whole world in view |

To work on the world:

| Do | What happens |
|---|---|
| **Click** a level | Selects it: the Level panel and the LDtk tab show it |
| **Double-click** a level | Opens the scene showing it in the Scene mode |
| **Drag** a level | Moves it in the world |
| **Click** an entity | Selects it (and its level): the LDtk tab's **Entities** shows it, ready to edit |
| **Drag** an entity | Moves it in its level, on its layer's grid; hold **Shift** to move it by the pixel |
| Click **empty space** | Selects nothing |

Where a dragged level lands depends on the world's layout: anywhere (in whole pixels) in a
**Free** world, on the world grid in a **GridVania** one. Levels of a **linear** world are placed
by their order, so they don't move: change the layout in the LDtk tab's **World** first. Each move
is one undo step, saved into the `.ldtk` file when you let go; the levels' neighbours (which LDtk
works out from where levels touch) follow.

## Levels and their scenes

A level shows in a scene through an **LDtkLevel** node naming it
([Putting a level in a scene](levels.md#putting-a-level-in-a-scene)). Select a level and the
Level panel lists the scenes showing it, each with its LDtkLevel node: click one to open it in
the Scene mode, the node selected. **Double-click** the level on the canvas to open the first
of them.

A level no scene shows yet has **New Scene with This Level** in the Level panel: it makes a scene
named after the level, with a World node and an LDtkLevel node showing that level, and opens it
in the Scene mode. It's one undo step: **Ctrl+Z** takes the scene away again and goes back to the
Level mode.

Scenes whose LDtkLevel node shows **All levels** are listed for every level of the world, after
the ones naming it.

## The LDtk tab

The bottom panel's **LDtk** tab is where the project's settings are edited. Its sections are the
vertical tabs on its left (in a narrow panel, a choice above the section):

| Section | What you can do |
|---|---|
| **Layers** | Pick a layer: its **name**, whether the selected level shows it, its **opacity**, **parallax** (X, Y, scaling), its **grid size** (only while nothing is painted in it: LDtk moves painted cells when it changes) and its **order** (Up / Down, in every level) |
| **Entities** | Pick an entity type: its **name**, **width**, **height**, **color**, **pivot**; its **fields**' names and defaults; the type's entities in the selected level (all of them with none selected). Click one to select it (and center the canvas on it): its position and every field's value are edited below it |
| **Collisions** | Pick an IntGrid layer: each value's **name** and **color**; and, for every scene whose LDtkLevel node uses that layer for collision, what each value becomes there (**Solid**, **One-way platform**, **Area**, **Nothing**: the node's settings, not the file's) |
| **Links** | The entity reference fields of the selected level's entities: pick what each points at (only the entities the field allows). The selected level's **neighbours**, which LDtk works out from where levels are: move levels to change them |
| **Level fields** | The selected level's custom fields (and, with no level selected, the fields' names) |
| **Enums** | Pick an enum: its **name**, each value's **name** and **color**; **add a value**, **add an enum** |
| **World** | The world's **layout** (Free, GridVania, linear side by side or one above the other: changing it moves the levels as LDtk would), its **grid** (GridVania's; the levels move with it), and each level's **X** and **Y** |
| **Tilesets** | What each tileset is (its image, size and grid) |

Fields' values are typed as text: a number, `true` or `false` (a checkbox), a color as
`#RRGGBB`, a point as `x, y` (cells), an enum's or a reference's value from a list. An empty
field is the field's default. Names are cleaned up as LDtk does (spaces and other characters
become `_`, the project's identifier style applies: `my door` becomes `My_door`) and must not be
taken; a name that can't be used isn't saved, and the tab says why above the section.

What LDtk keeps in step is kept too: renaming an entity type renames it on every entity and in
the project's table of contents, renaming an enum value changes every field set to it, a layer's
opacity is every level's, a moved level's entities get their new world positions. A renamed
layer or entity type is renamed in your scenes' LDtkLevel nodes too (their collision layer and
entity rules), in the same undo step. Scripts named like an entity type aren't renamed.

Not editable here yet (LDtk edits them, and the tab says so): array fields, tile fields,
symmetrical references, external enums, tilesets, levels' sizes and names, the order of a linear
world's levels, a field's or a layer's type. Painting tiles and IntGrid cells, and placing new
entities, are LDtk's.

## Saving, undo and LDtk

- **Every edit is saved into the file at once**, the files a level is saved in apart (LDtk's
  "Save levels to separate files": `.ldtkl` files) included. Nothing else in the file changes:
  the editor only rewrites the values it edits, in LDtk's style, so LDtk opens it as before and
  your version control shows small changes. They don't make the project "Modified": Ctrl+S has
  nothing more to write.
- **Undo** (Ctrl+Z) puts the file back as it was before the edit, one step per edit (typing a
  name or a value is one step).
- **LDtk saved the file** while the editor was open: the editor reads it again (the status bar and
  the World header say when). An undo after that still works when your edit and LDtk's change are
  in different places in the file; when they overlap, the editor asks whether to **overwrite**
  LDtk's change or **keep the file** as LDtk saved it.
- **LDtk doesn't notice the editor's changes** while it has the file open, and its next save
  writes over them. Edit in one at a time: close the project in LDtk (or open it again there)
  after editing here.
- **Open in LDtk** opens the file at the selected level (or the selected entity's level: LDtk
  can't be told which entity to select). LDtk's command line only takes the file, so the editor
  sets the level LDtk remembers in its own settings ("last project") before starting it.

## What's shared with the Scene mode

The menus, the toolbar's file, undo and play buttons and **Export**, the browser, the **Console**
and **Output** tabs, **Settings** and **Project Settings**, and the docs window are the same in
both modes. The toolbar's tools (Select, Move, Rotate...) are the Scene mode's, so they don't
show here, and the commands for nodes and the viewport (Add Node, Delete, Copy, the grid, the
zoom...) are greyed out in the menus.

**Undo** is one history for both modes: Ctrl+Z undoes the last edit wherever it was made, and
shows the mode (and the scene) it was made in. Playing, building and exporting show the Console
and Output tabs in whichever mode is showing.

Things that belong to the Scene mode bring it forward: opening a scene in the browser, opening a
script (the code tabs are beside the scene tabs), a Console line's error location, the status
bar's Git branch (the Git tab is the Scene mode's).

## Questions

**The world is empty.** The project has no LDtk file yet: import one (**Ctrl+I**, or the
**Import...** button the Level mode shows then). See [LDtk levels](levels.md).

**I changed the level in LDtk and the world didn't change.** It's read again when the file
changes: save in LDtk, then come back to the editor.

**My edit here disappeared after I saved in LDtk.** LDtk had the file open and saved its own copy
over it. Open the file again in LDtk after editing here (or undo LDtk's save there).

**A name I typed isn't saved.** It isn't a usable identifier, or another one has it: the LDtk
tab says why above the section. Finish typing a name that works.

**I can't drag levels.** The world is linear (its levels are placed by their order): pick
**Free** or **GridVania** in the LDtk tab's **World**.

**My entity jumps when I drag it.** It's placed on its layer's grid, as LDtk places it; hold
**Shift** to move it by the pixel.

**Where are the tools?** They're the Scene mode's (Ctrl+Alt+1).
