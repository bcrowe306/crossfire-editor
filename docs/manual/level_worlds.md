---
title: Levels, worlds and the project
description: "Making, renaming, copying, resizing and deleting levels in the Level mode, their backgrounds and depths; worlds (several, their layouts); LDtk's selection; field values on the canvas; saved tile selections; the Project tab's every option and what saving writes (backups, PNG images, the simple export)."
order: 21
---

# Levels, worlds and the project

The [Level mode](level_mode.md) edits an LDtk project's **levels** and **worlds** as LDtk's world
view, World panel and level form do, and the **project's settings** as LDtk's project panel does:
everything is written into the `.ldtk` file as LDtk writes it, one undo step per edit, saved with
the project. This page is the guide to them, and to what came with them: LDtk's **selection**
(rectangles of cells and entities moved, copied, deleted), **field values drawn on the canvas**,
**saved tile selections** and LDtk's **panel keys**. [LDtk parity](level_parity.md) lists every
LDtk feature and where it is.

- [Levels](#levels)
- [Worlds](#worlds)
- [Selecting, moving and copying](#selecting-moving-and-copying)
- [Fields on the canvas](#fields-on-the-canvas)
- [Saved tile selections](#saved-tile-selections)
- [The Project tab](#the-project-tab)
- [What saving writes](#what-saving-writes)
- [Keys](#keys)
- [Questions](#questions)

## Levels

**A new level:** **+** (New Level) in the Levels sidebar's header (or **+ Level** on the World
tab's toolbar row, **+** on the Level tab's), then click the canvas where it goes: the pointer shows the level (the world's
**New level width / height**, the World tab), blue where it fits, red where it would overlap
another; in a linear world, a line shows where in the order it goes. **Esc** or a right click
cancels. A right click on empty space in the world has **New Level Here**. The new level is
named by the project's **level name pattern** (the Project tab; `Level_0`, `Level_1`...), at the
depth shown, selected.

**Its settings** are in the **Level** tab (its list is the world's levels; its toolbar row: **+**,
**Duplicate**, **Delete**, **Up** and **Down** in the world's order, **Focus**):

| Setting | What it does |
|---|---|
| **Name** | The level's identifier, unique (cleaned up as LDtk does). Scenes whose LDtkLevel node names the level follow a rename. With **Automatic name** on, the project's pattern names it (and names it again when it moves): untick it to type a name |
| **IID** | Its unique id (references name it); the button copies it |
| **Depth** | Its world depth (LDtk's world layers): **Further** and **Closer** move it, where no level of that depth is in the way |
| **World X / Y** | Where it is (GridVania: on the world grid) |
| **Width / Height**, **Resize** | Type the new size, then **Resize**: the right and bottom edges move; what's past them is removed (entities too, unless their type may leave the level) |
| **Background color** | Its own color, or **Default** (the project's) |
| **Image**, **Position**, **Pivot** | A picture under its layers (one of the project's images), scaled not at all, to fit, to cover (or stretched), or repeated, the pivot saying which part shows |
| **Duplicate**, **Delete** (the toolbar row) | A copy beside it (selected), or the level removed (references to its entities go; not the last level of a world) |

Its **fields** are below them, then the level fields' definitions
([Level definitions](level_definitions.md#fields)).

**On the canvas:**

| Do | What happens |
|---|---|
| **Drag** a level (the world view) | Moves it: in a Free world snapped to the grid and to other levels' edges (**Shift** or **Ctrl**: free), in a GridVania world on its grid, in a linear world to another place in the order |
| **Ctrl + Alt + drag** a level | A copy goes there, the original stays |
| **Drag a handle** around the focused level | Resizes it from that side (on the selected layer's grid; the world's in GridVania), its new size shown |
| **Right click** a level | Its menu: **Focus**, **Duplicate**, **Delete**, **Move to** another world, **New Level Here** |
| **PgUp / PgDn** | Shows the next world depth up or down (the others are faded and can't be picked) |
| **Ctrl + PgUp / PgDn** | Moves the selected level to the depth above or below |

The Levels sidebar's menu has the same: **Rename** (the Level tab's name, ready to type),
**Duplicate**, **Delete**, **New Level...**.

## Worlds

The **World** tab: its list is the worlds (pick one to show it), its toolbar row:

- **+ World**: a project with one world gets LDtk's **Multi-worlds** turned on (its levels
  become its first world's), then a new world (`World2`...). **Delete** removes the shown world
  and its levels (not the last world). **+ Level** makes a level in it (above).

Its settings:

- **Name** (with several worlds), **IID**.
- **Layout**: **Free** (anywhere), **GridVania** (on a world grid: **Grid width / height**),
  **Horizontal** or **Vertical** (one after the other, in their order). Changing it moves the
  levels as LDtk does.
- **New level width / height**: new levels' size (on the grid in GridVania).
- **Depth shown**, and each level's order (the arrows) and place.

With several worlds, the Levels sidebar's choice and the World tab's list pick the one shown; a
level's menu **Move to** moves it to another world.

## Selecting, moving and copying

LDtk's selection works on the focused level:

| Do | What happens |
|---|---|
| **Shift + Alt + drag** (any tool), or a drag on empty cells with the **Select** tool | Selects what's in the rectangle: cells (IntGrid values, tiles), entities, entities' points, in every visible layer that allows it (only the selected layer in single layer mode) |
| **Shift+E** | Selects the empty cells too: moved, they clear where they land |
| **Ctrl+A** | Selects everything |
| **Drag** the selection | Moves it, on the grid (each layer by its own cells); the canvas shows where it goes |
| **Ctrl + Alt + drag** the selection | Copies it there |
| **Delete** | Removes it |
| **Esc**, or another tool's press | Lets it go |

The canvas header says what's selected. Each move, copy or removal is one undo step; auto-layers
are worked out again where cells moved.

## Fields on the canvas

Entities' and levels' **field values** are drawn as LDtk draws them, by each field's display
settings ([Level definitions](level_definitions.md#fields)):

- **Value only** and **Name and value**: the values above, at the center of or beneath the entity
  (its **position**), in the field's color and scale, with its prefix and suffix; colors as a
  disc, tiles and enum values with an icon as the icon, references as `@(Type)` (`@(Type in
  Level)` for another level's).
- **Array count**: how many values.
- **Radius** (pixels or cells): a circle around the entity.
- **Points**, **Point star**, **Point path**, **Point path loop**: each point, and the lines between
  them.
- **Reference link** (between centers or pivots): a link to each referenced entity, in the
  field's **link style** (zig-zag, arrows, curved...), cut short when the target is in another
  world or depth.

A field on its default isn't shown unless it's **always shown**; in the world view only the
fields **shown in the world** are. An Entities layer that **hides its fields when inactive**
hides them (and the names) while another layer is selected. Levels' fields show under each level
in the world view, above the focused level.

## Saved tile selections

Pick tiles in a Tiles layer's palette, then **Shift+S** (or the palette's **Save**): the
selection is saved in the tileset (LDtk's saved selections, in the file). A click on any tile of
a saved selection then picks all of it, in its mode (stamp or random); **Ctrl + click** picks just
that tile. Saving a single tile forgets the saved selections it's in.

## The Project tab

The LDtk file's own settings, as LDtk's project panel has them (the tab has no list: its toolbar
row has **Save**):

| Section | Settings |
|---|---|
| **Saving** | **Separate level files** (each level in an `.ldtkl` file in a folder named after the project: smaller diffs), **Minify JSON**, **Backups on save** (how many are kept, 3 to 50, and where), **Image export** (none, a PNG per layer, per level, or both; **With backgrounds**; the file names' pattern), **Super simple export**, **Tiled export** (kept for LDtk, which writes Tiled files when it saves; the editor doesn't) |
| **Names** | **Identifier style** (Capitalize, Uppercase, Lowercase, Free: every name in the project changes), **Level names** (the pattern: `%world`, `%idx`, `%idx1`, `%x`, `%y`, `%gx`, `%gy`, `%depth`) |
| **Defaults** | Grid size, entity size and pivot, the workspace and levels' background colors |
| **Advanced** | **Multi-worlds**, **Index in file names** (`0000-Level.ldtkl`), **Old IntGrid data** (LDtk's legacy `intGrid` arrays), **Multilines type**, **Old table of contents** |
| **Custom commands** | The commands LDtk runs (by hand, after loading, before or after saving): added, edited, reordered, removed. The editor keeps them for LDtk and **never runs them**: a project file could make it run any program |
| **Description** | The project's tutorial text |

Each is one undo step. Turning separate level files, minified JSON or Multi-worlds on or off
rewrites the files as LDtk would.

## What saving writes

Saving (**Ctrl+S**, Play, Export, Open in LDtk) writes the project's LDtk files, then what LDtk's
own save writes:

- **Backups** (with Backups on save): the project's files copied into
  `<project name>/backups/<iid>_<date>_<time>/` (or the backup folder), the oldest ones beyond the
  limit removed.
- **Images** (Image export): `<project name>/png/`, named by the pattern.
- **The simple export**: `<project name>/simplified/<level>/`: `data.json`, a CSV per IntGrid
  layer, the layers' and the level's pictures.
- **Level files** of levels deleted or renamed are removed (separate level files).

The pictures are drawn by the editor, as the canvas draws the levels: a pixel can differ from
LDtk's where tiles blend.

## Keys

| Key | What it does |
|---|---|
| **P**, **L**, **E**, **U**, **T**, **C** | The Project, Layers, Entities, Enums, Tilesets, Level tab (again: the panel closes) |
| **1** to **9**, **0** | Selects the first to tenth layer |
| **PgUp / PgDn**, **Ctrl + PgUp / PgDn** | The depth shown, the selected level's depth |
| **Ctrl+A**, **Shift+E**, **Delete** | Select all, select empty cells too, delete the selection |
| **Shift+S** | Saves the picked tiles as a selection |
| **Esc** | Cancels a new level's spot, the selection, a pick |

They're in **Settings > Keyboard** with the Level mode's other keys.

## Questions

**My new level got a name like `Level_3`, and I can't type another.** It's named by the project's
pattern: untick **Automatic name** in the Level tab first.

**I can't add a level where I click.** It would overlap a level (the spot shows red): click
elsewhere, or make room.

**A resize removed my entities.** They were past the new edges and their type can't leave the
level: Ctrl+Z.

**Why didn't my custom command run?** The editor never runs them (see [The Project
tab](#the-project-tab)): LDtk does, when it opens or saves the file.

**Where are the backups?** In `<project name>/backups/` beside the `.ldtk` file, unless the
Project tab names another folder.

**What can't be done here yet?** [LDtk parity](level_parity.md) lists it.
