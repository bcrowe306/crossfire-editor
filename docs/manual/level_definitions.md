---
title: Level definitions
description: "Editing an LDtk project's definitions in the Level mode, as LDtk's panels do: layers (types, grids, opacities, parallax, IntGrid values and groups, tilesets, auto-layer sources), entity types and their fields (every field type, defaults, ranges, display, conversions), enums (with external enum files), tilesets (images, grids, tile tags and custom data) and level fields; every level kept in step."
order: 19
---

# Level definitions

An LDtk project's **definitions** are what its levels are made of: the layers every level has,
the entity types you place, their fields, the enums fields pick from, the tilesets tiles come
from, and the fields every level has. In the [Level mode](level_mode.md) they're edited in the
bottom tabs, the way LDtk's panels edit them (**Layers**, **Entities**, **Enums**, **Tilesets**,
and the **Level** tab's level fields).

Every change is kept in step across the levels as LDtk keeps it: a new layer appears in every
level, a deleted entity type's entities go (and references to them), a new field is added to every
entity of the type at its default, a changed default shows on every entity using it. Each change
is one undo step (**Ctrl+Z**), and it stays in the editor until you save (**Ctrl+S**), as every
Level mode edit does ([Saving, undo and LDtk](level_mode.md#saving-undo-and-ldtk)).

## The lists

Each tab starts with its list: pick the definition in the choice, and under it:

- **Add**: a layer by its type (**IntGrid**, **Entities**, **Tiles**, **AutoLayer**; new layers go
  on top), an **Entity** (or a **Rectangle region** or **Circle region**: hollow, resizable,
  tagged `region`), a field of any type, an **Enum**, a tileset from one of the project's images.
- **Duplicate**: a copy after it, named like it with a number (`Walls2`).
- **Delete**: and what used it goes with it (a layer's content in every level, an entity type's
  entities, an enum's fields).
- **Up** and **Down**: its place in the list (a layer's place is its drawing order: higher draws
  over lower).

New definitions get LDtk's names and defaults (`IntGrid`, `Entity`, `Integer`...) and a nice
color of LDtk's palette; rename them in their **Name** field.

## Layers

Every layer has:

| Setting | What it does |
|---|---|
| **Name**, **Documentation**, **List color** | Its identifier, a note, its color in LDtk's lists |
| **Opacity**, **Inactive opacity** | How opaque it draws, and while another layer is selected |
| **Grid size** | Its cells' size: every level's cells keep their place (cells past the new size go), entities move with it |
| **Guide grid** | A second grid LDtk draws over it |
| **Offset X / Y** | Where it's drawn in every level |
| **Parallax X / Y**, **Parallax scaling** | How it scrolls; Y follows X while they're the same, and is X's with scaling on |
| **Hidden in list**, **Hide fields**, **Pick inactive**, **In the world view**, **Async render**, **Filter tags** | How LDtk shows it |

By its type:

- **IntGrid**: its **values** (each a name, a color, a group, an icon tile; **+ Value** adds the
  next number), its **groups** (a name and a color: rules can match any value of a group). A
  removed value's cells become empty in every level. With a **Rules' tileset** it's also an
  auto-layer.
- **AutoLayer**: its **Source layer** (the IntGrid layer its rules read; it takes that layer's
  grid) and **Tileset**.
- Auto-layers both: **Tiles removed by** (a Tiles layer whose tiles hide the rules' tiles) and a
  **Biome field** (a level field of an enum). When what their tiles depend on changes, the rules
  run again in every level. Their rules are edited in the Auto-layer Rules tab
  ([Auto-layer rules](level_rules.md)).
- **Tiles**: its **Tileset** (the layer takes the tileset's grid) and **Tile pivot**.
- **Entities**: **Required tags** and **Excluded tags**: which entity types it takes.

The **In the scenes** rows say what your scenes' LDtkLevel nodes make of an IntGrid layer's
values (solid, one-way, an area).

## Entity types

| Setting | What it does |
|---|---|
| **Name**, **Documentation**, **Tags** | Its identifier, a note, tags layers and references filter by |
| **Width**, **Height** | Its size; entities of that size follow it |
| **Resizable across / down**, **Keep aspect**, **Min / Max** | Whether its entities can be resized, and how far |
| **Pivot X / Y** | Where an entity's position is in its box |
| **Color**, **Drawn as** | Its color, and its shape (rectangle, ellipse, cross) or a tile of a tileset, picked on the tileset's picture (drag over tiles for a bigger one) |
| **Tile fits**, **Borders** | How the tile fills the box (cover, fit, repeat, stretch, full size, 9-slice and its borders) |
| **Tile / Fill / Line opacity**, **Hollow**, **Show name**, **Editor tile** | How it looks |
| **Max count**, **Counted**, **At the limit** | How many may be placed, where they're counted, what one more does |
| **Out of bounds**, **Table of contents** | Whether entities may leave their level, whether the project lists them all |

**LDtk's internal icons** in **Drawn as** makes the icons' tileset. The icons are LDtk's own image
(FinalBossBlues' icons, for the editor only): put a copy of `finalbossblues-icons_full_16.png`
beside the `.ldtk` file to see them here and in your game.

## Fields

An entity type's fields (under its settings) and the levels' fields (the **Level** tab) are edited
the same way. **New field** adds one of any type: Integer, Float, Boolean, String, Multilines,
Color, an enum, File path, Tile, and for entities Entity ref and Point; each single or an array.

| Setting | For |
|---|---|
| **Default** | The value of one without its own (a number, a text, a color, a checkbox, an enum's value, `x, y` for a point, a tile picked on its tileset) |
| **Can be null** | Whether a value may be empty |
| **Min**, **Max** | Numbers' range (swapped when reversed; values read clamped) |
| **Min items**, **Max items** | Arrays' sizes |
| **Regular expression**, **Ignore case** | What a String keeps |
| **Language** | How LDtk colors a Multilines value |
| **File types** | The extensions a File path takes |
| **Tileset** | A Tile field's tiles |
| **Points at**, **Symmetrical**, **Other levels**, **Chain** | Which entities a reference may point at, and how |
| **Shown as**, **Where**, **Text scale**, **Line**, **Display color**, **Always shown**, **In the world view**, **Cut long values**, **Prefix**, **Suffix** | How LDtk shows it in levels (only the ways that fit its type) |
| **Gives the color**, **In the table of contents**, **Searchable** | Its value colors its entity, is listed, is searched |

**Convert...** changes a field's type where LDtk can: to an array, String and Multilines both ways,
File path to and from String, Integer to Float, Boolean to Integer, Float to Integer (truncated or
rounded). Values are converted with it; the ones marked "values may change" can lose something.

## Enums

An enum's **Name**, **Tags** and **Icons' tileset**, and its **values**: each a name (fields set to
it follow a rename), a color, an icon picked on the icons' tileset, its place, **Remove** (fields
set to it lose their value). **New value** adds one.

**External enums** come from a file in your project's assets: a text file (`MyEnum: a, b, c`, an
enum a line), JSON (`{ "MyEnum": "a, b, c" }` or a list), Haxe source (its simple enums) or a
CastleDB file (its sheets with an identifier column, their colors). **Import** reads the file;
their values are the file's. When the file changes, the tab says so: **Sync** reads it again,
adding and removing values (it says how many, and how many of the removed are used), and
**Remove its enums** takes them out of the project.

## Tilesets

A tileset's **Name**, its **Image** (another image keeps placed tiles at their column and row),
its **Grid**, **Spacing** and **Padding** (a new grid keeps tiles at their column and row too), its
**Tags**, and its **Tag enum**: an enum whose values tag tiles.

Under them, the tileset's picture shows its **Tile data**:

- **Custom data**: click a tile, then type its data (any text your game reads: JSON, numbers);
  tiles with data are outlined; empty removes it.
- **Tag** *value*: drag over tiles to tag them with the value, with the right button to untag.

## Questions

**My new layer isn't in a level.** It is in every level, empty: select the level and the layer in
the Layers sidebar.

**I deleted something by mistake.** **Ctrl+Z**: every change is one undo step, and nothing is
written until you save.

**My grid change moved my entities.** LDtk moves them by the grids' ratio too, so they stay over
the same cells.

**A field's default doesn't show on an entity.** That entity has its own value: clear its value
(the Entities tab, the entity selected) and it shows the default.

**I can't edit an external enum's values.** They're its file's: change the file and **Sync**.

**The internal icons don't show.** They're LDtk's own image: see [Entity types](#entity-types).
