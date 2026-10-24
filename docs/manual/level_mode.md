---
title: Level mode
description: "The editor's world editor: your LDtk project's levels laid out as in its world, the scenes showing each level, a scene made for a level in one click, and the LDtk tab."
order: 17
---

# Level mode

The editor has **modes**, picked with the tabs beside the menu bar
([Editor modes](getting_started.md#editor-modes)). The **Scene** mode is where you build scenes
from nodes. The **Level** mode is where you see your game's **world**: the levels of an
[LDtk](https://ldtk.io) project, laid out as they are in it, each one leading to the scene that
shows it.

Today the Level mode shows the world and the scenes around it; the levels themselves are drawn
in LDtk ([LDtk levels](levels.md)). Editing levels here, saved back into the `.ldtk` file, is
what comes next.

## Opening it

- Click **Level** in the mode bar, at the top of the window beside the menus.
- Or **View > Level Mode**, or **Ctrl+Alt+2** (Cmd+Alt+2 on a Mac). **Ctrl+Alt+1** goes back to
  the Scene mode.

The editor remembers the mode for each project: open the project again and it shows the mode
you left it in, on the same world.

## The window in the Level mode

```
+-----------+--------------------------------------+--------------+
| browser   | World: legacy.ldtk     Open in LDtk  | Level        |
|           |                                      |              |
|           |   the world: every level in place    | the selected |
|           |                                      | level, the   |
|           +--------------------------------------+ scenes that  |
| preview   | bottom panel: LDtk, Console, Output  | show it      |
+-----------+--------------------------------------+--------------+
```

| Part | What it's for |
|---|---|
| **Browser** (left) | The same project browser as in the Scene mode. Selecting an LDtk project there shows its world |
| **World** (middle) | The LDtk project's levels, as the game draws them. With several LDtk projects, the choice in its header picks one; **Open in LDtk** opens the file in LDtk |
| **Level** (right) | The selected level: its size, where it is in the world, its layers, entities, fields and neighbours, and the scenes showing it |
| **Bottom panel** | **LDtk** (what the project defines), and the same **Console** and **Output** as the Scene mode's |

The panels resize like the Scene mode's, and keep their own sizes: making the browser wider
here doesn't change it in the Scene mode.

## Levels and their scenes

A level shows in a scene through an **LDtkLevel** node naming it
([Putting a level in a scene](levels.md#putting-a-level-in-a-scene)). On the world:

- **Hover** a level to outline it.
- **Click** it to select it. The Level panel says what it is and lists the scenes showing it,
  each with its LDtkLevel node: click one to open it in the Scene mode, the node selected.
- **Double-click** it to open the first scene showing it in the Scene mode.

A level no scene shows yet has **New Scene with This Level** in the Level panel: it makes a scene
named after the level, with a World node and an LDtkLevel node showing that level, and opens it
in the Scene mode. It's one undo step: **Ctrl+Z** takes the scene away again and goes back to the
Level mode.

Scenes whose LDtkLevel node shows **All levels** are listed for every level of the world, after
the ones naming it.

## The LDtk tab

The bottom panel's **LDtk** tab lists what the world's LDtk project defines: its layers (and
their kinds), entity types, enums and tilesets, and how many worlds and levels it has. For now it
only reads them; change them in LDtk, and the tab (and the world) follows when you save there.

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

**Where are the tools?** They're the Scene mode's (Ctrl+Alt+1).

**Can I edit levels here?** Not yet: draw them in LDtk. Editing layers, entities, collisions,
links, level fields, enums and the world from the LDtk tab, saved into the `.ldtk` file, is
being built next.
