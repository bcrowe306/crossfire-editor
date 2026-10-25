---
title: Auto-layer rules
description: "Editing an LDtk project's auto-layer rules in the Level mode's Auto-layer Rules tab, as LDtk's rule panel does: groups (optional, biomes, colors, icons), rules and their editor (tiles, the pattern, chance, mirrors, modulos, offsets, Perlin), the Rule Assistant, duplicate and remap; the level showing every change."
order: 20
---

# Auto-layer rules

An **auto-layer** draws its tiles by itself from an IntGrid layer's values: you paint "wall",
"grass" or "water" cells, and its **rules** decide which tile goes in each cell (a wall's corner,
grass on top of a block, a random rock). An IntGrid layer with a tileset has rules of its own; an
**AutoLayer** layer draws from another IntGrid layer. In the [Level mode](level_mode.md) the
**Auto-layer Rules** tab edits them as LDtk's rule panel does, and the canvas shows every change at
once: the rules are applied again in every level, exactly as LDtk applies them (the files you save
are the files LDtk would save).

Rules are in **groups**, applied in the list's order: the first group's rules first, each group's
rules top to bottom. A rule that **breaks on match** stops the rules below it in the cells where it
applies; a rule that doesn't lets the next ones add their tiles over its own.

Each change is one undo step (**Ctrl+Z**), and stays in the editor until you save (**Ctrl+S**), as
every Level mode edit does ([Saving, undo and LDtk](level_mode.md#saving-undo-and-ldtk)).

## The tab

At the top:

- **Layer**: whose rules it shows, an IntGrid layer or an AutoLayer. It follows the layer selected
  in the Layers sidebar; picking one here selects it.
- **+ Group**: a new group, made by the **Rule Assistant** (recommended: below) or empty. An empty
  group goes first in the list, its name ready to type.
- **Paste group**: a group you copied, at the end.
- **Randomize**: a new random seed for the layer in the selected level: rules with a chance or a
  Perlin filter change where they apply.
- **Render**: the auto-layers' tiles shown, or their IntGrid values instead (**Shift+R**).
- **Tileset here**: the tileset the rules draw with in the selected level. Any tileset of the same
  size (tiles across and down, grid) works: a "winter" tileset for one level, say.

A layer whose settings stop its rules working (an IntGrid layer without a tileset, an AutoLayer
without a source layer) says so, with a button to its settings in the Layers tab.

## Groups

Each group's header has:

- its **grip**: drag it up or down to change the order;
- its **toggle**: the group on or off. An **optional** group has an eye instead: it's off
  everywhere, and turned on per level (the selected level's eye);
- its icon, then its **name**: click it to open or close the group, double-click to rename it.
  Hovering the name outlines, on the focused level, the cells where its rules put tiles;
- its biomes, when the layer has a biome field;
- **+** (a new rule, first in the group) or **EDIT** (a group the Assistant made);
- **⋯**, its menu (a right click on the header opens it too).

The menu: **Copy**, **Cut**, **Paste** (after it), **Duplicate**, **Delete**; **Rename**;
**Duplicate and remap** (below); **Assign group color**; **Assign group icon** (picked on the
tileset) and **Remove group icon**; **Edit "out-of-bounds" policy for all rules**; **Edit rules
using the Assistant** (its groups); **Assign biome enum** (below); **Turn into an OPTIONAL group**
or **Disable OPTIONAL state** (the levels then lose their on / off state for it).

**Biomes**: with a **Biome field** set on the layer (a level field of an enum: the Layers tab), a
group can need some of the enum's values in the level: **Any biome**, or one or more values; with
several, **OR** (at least one of them) or **AND** (all of them). The group then applies only in the
levels whose biome field has them (the header says when it isn't in the selected level's).

## Rules

Each rule's row has its grip (drag it to another place, or into another group), its toggle, its
**pattern** (click it to edit the rule; hovering it outlines its cells on the focused level), its
**chance** (%), its **opacity**, then buttons: **break on match** (■), the **X** and **Y** mirrors,
the offsets, the modulos (`1-1`), **P** (Perlin; a right click opens its settings), and a new rule
before or after it. A right click on the row: **Edit**, **Copy**, **Cut**, **Paste** (after it),
**Duplicate**, **Delete**.

Pointing at a cell of the focused level highlights the rules that put tiles there.

### The rule editor

A rule's editor replaces the list (**Back to the rules** returns), so the level stays in view:

- **Tiles**: **Individual tiles** (one of them, at random, in each matching cell) or **Rectangles
  of tiles** (stamps: one of them at random, placed by the stamp's **pivot**). Pick them on the
  tileset: a drag picks a rectangle of tiles, **Shift** adds to them, the right button removes. For
  stamps, click one to replace it, right-click to remove it, **+ Stamp** to add another.
- **Pattern**: what the cells around the matching cell must hold (its center is the cell drawn).
  Pick a value in the palette (an IntGrid value, a whole group of values, or **"Any value" / "No
  value"**), then on the 9 x 9 grid:
  - the **left** button: this value is required here;
  - the **right** button: this value must **not** be here (with "Any value": no value at all);
  - the **middle** button: clear (anything goes).
  Drag to paint several cells. Hovering a cell says what it asks for. Empty borders are trimmed
  when it's saved, as LDtk does.
- **Out of bounds**: the value the rule reads past the layer's edges: by default it doesn't apply
  where its pattern reaches past them; **Empty cells**, or a value.
- **Placement**: **Chance**, **Opacity**, **Break on match**, **X mirror** and **Y mirror** (the
  rule also matches its pattern reversed; refused on a symmetric pattern, where they'd change
  nothing).
- **Modulos**: the rule applies every *X* columns and every *Y* rows, from an **offset**;
  **Checkerboard** shifts every other row (or column) by half the modulo. The little grid shows
  where it applies.
- **Offsets**: the tiles moved by a number of pixels, and at random within a range (linked: from
  minus to plus the same number; the link button sets the two ends apart).
- **Perlin filter**: the rule applies only where a Perlin noise is positive (random patches):
  its seed, scale and octaves; **Show the noise on the level** draws it (red: off, green: on).

### The Rule Assistant

The Assistant makes a whole group of rules for walls, platforms and edges from one IntGrid value:

1. **Main value**: the value the rules draw tiles for; **Outer value**: what's around it (none: any
   other value, or nothing).
2. The group's **name**.
3. The **parts**: a block, its walls, outer and inner corners, turns, crosses... Click a part, then
   pick its tiles on the tileset (several: one at random). You don't have to fill them all: a part
   without tiles uses a mirrored part's (shown faded).
4. **Allow rules to stack**: several rules may then draw in one cell (for transparent tiles).

**Create rules** makes the group (first in the list). Its rules are then the Assistant's: **EDIT**
opens it again; **Switch to advanced mode** lets you edit them by hand (the Assistant can't edit
that group any more).

### Duplicate and remap

From a group's menu: a copy of the group after it, with its IntGrid values changed (grass's rules
made into snow's, say) and its tiles moved on the tileset: click where its first tile goes (the
tiles that would go past the tileset's edge show red). Name the copy and **Confirm**.

## Questions

**My rule draws nothing.** It needs tiles, and its pattern must match: hover its pattern to see
its cells. A rule above it that breaks on match may take those cells first; a group may be off,
optional (off here), or not in this level's biomes.

**My rule doesn't apply at the level's edges.** Its pattern reaches past them: set its **Out of
bounds** to the value the outside should count as.

**The tiles changed when I clicked Randomize.** That's what it's for: rules with a chance or a
Perlin filter pick again with the new seed. **Ctrl+Z** brings the old seed back.

**Can I copy rules to another layer or LDtk file?** Yes: **Copy**, then **Paste** in that layer's
list (the clipboard lasts while the editor runs, like LDtk's).

**Will LDtk read the rules I made here?** Yes: they're written as LDtk writes them, and their
tiles are the ones LDtk makes.
