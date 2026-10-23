---
title: Tilemaps
description: "Levels drawn from tiles: TileMap nodes from Aseprite tilesets, painting tiles in the editor, terrains, tile collision."
order: 17
---

# Tilemaps

A **tilemap** draws a level from small square pictures, **tiles**, laid out on a grid: grass,
walls, platforms, water. Instead of drawing a whole level as one big picture, you draw a set of
tiles once and place them many times. Tiles can also say what they are in the game: solid ground,
a platform you can jump up through, spikes that hurt.

In Crossfire, tiles come from [Aseprite](https://www.aseprite.org), the pixel art editor. You draw
the tiles (the **tileset**) in Aseprite, and you place them either in Aseprite or in the editor.
A **TileMap** node shows them in your scene.

- [What you need](#what-you-need)
- [Adding a TileMap to a scene](#adding-a-tilemap-to-a-scene)
- [Painting tiles in the editor](#painting-tiles-in-the-editor)
- [Terrains: tiles that fit their neighbours](#terrains-tiles-that-fit-their-neighbours)
- [Collision: solid, one-way and area tiles](#collision-solid-one-way-and-area-tiles)
- [Animated tiles](#animated-tiles)
- [The TileMap's settings](#the-tilemaps-settings)
- [Tilemaps in scripts](#tilemaps-in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## What you need

An Aseprite file (`.aseprite` or `.ase`) with at least one **tilemap layer**. In Aseprite:

1. **File > New**, any size (say 320 x 180).
2. **Layer > New > New Tilemap Layer**. Aseprite asks for the tile size: 16 x 16 is common for
   pixel art.
3. Draw on the layer. Each cell you draw in becomes a tile of the layer's **tileset**, and drawing
   the same picture again reuses it. The **Tileset** panel (above the layers, when the tilemap
   layer is selected) lists the tiles; tile 0 is always the empty one.
4. Save the file inside your project's folder, or import it (below).

You can paint the whole level in Aseprite, or only draw the tiles there and paint the level in
the editor. Both work, and you can mix them.

## Adding a TileMap to a scene

1. **Import the file**: File > Import Asset (Ctrl+I), pick the `.aseprite` file. It appears in the
   browser under **Images**. Its preview says "It has tilemap layers".
2. **Drag it from the browser into the viewport.** A file with tilemap layers becomes a TileMap
   node (a file without them becomes a Sprite). Its top-left corner goes where you drop it.

   Or add a node with **Add Node** (Ctrl+Shift+A) > **TileMap**, then pick the file in the
   inspector's **Tilemap file**.
3. The viewport shows the file's tilemap layers, bottom layer first, as they look in Aseprite.

Save the file again in Aseprite and the viewport updates as soon as you come back to the editor.
A game running from Play updates too.

## Painting tiles in the editor

Select the TileMap and press **Paint Tiles** in the inspector (or open the bottom panel's
**Tiles** tab). While the Tiles tab shows and a TileMap is selected, the viewport paints tiles
instead of selecting and moving nodes.

### The Tiles panel

- **Layer**: the layer you paint. The list has the file's tilemap layers, then layers of the
  scene's own (below).
- **+ Layer**: adds a layer of the scene's own, drawn above the file's layers. With more than one
  tileset in the file, **New layers on** picks which tileset it uses.
- **Use the File's Tiles**: shown once you've painted a layer that comes from the file. It throws
  your painting of that layer away and shows the file's tiles again.
- **Tools** (below).
- **Terrain**: the terrain the Terrain tool paints (only when the tileset has terrains).
- **Flip X, Flip Y, Rotate**: turn the brush. Flip X mirrors it left to right, Flip Y top to
  bottom, and Rotate turns it a quarter clockwise each press. The brush line says what's set.
- **The palette**: every tile of the layer's tileset. Click one to paint with it (the outlined one
  is the brush). Its flips stay.

### The mouse in the viewport

| Mouse | Does |
|---|---|
| Left button, or drag | The tool |
| Right button, or drag | Erases (every tool; with Terrain it removes the terrain) |
| Middle drag, or Space + drag | Pans the view |
| Wheel | Zooms |

The cell under the mouse is outlined (red while erasing). Press **F** to frame the selected
TileMap when its tiles are small on screen.

### The tools

| Tool | What a stroke does |
|---|---|
| **Paint** | Puts the brush tile in every cell you drag over |
| **Erase** | Empties every cell you drag over |
| **Rectangle** | Fills the rectangle from where you press to where you release (outlined while you drag) |
| **Fill** | Fills the cell you click and every touching cell that had the same tile (like a paint bucket) |
| **Pick** | Takes the tile of the cell you click as the brush, with its flips |
| **Terrain** | Paints a terrain: each cell takes the tile that fits its neighbours ([Terrains](#terrains-tiles-that-fit-their-neighbours)) |

Each stroke (from pressing the button to releasing it) is one step for **Undo** (Ctrl+Z).

Painting outside a layer's grid makes the grid bigger: left, right, up or down.

### What happens to the file

The editor never changes your Aseprite file. The first time you paint a layer that comes from
the file, the editor copies that layer's tiles into the scene, and from then on the scene's copy
is what the game shows for that layer. Changes you make to that layer later in Aseprite don't
show any more, until you press **Use the File's Tiles**. Layers of the scene's own exist only in
the scene. The tiles themselves (their pictures) always come from the file: redraw a tile in
Aseprite and it changes everywhere.

The inspector lists the layers painted in the scene ("Painted here: Ground").

## Terrains: tiles that fit their neighbours

Drawing the edge of a grass area by hand means picking the right edge tile for every cell: top
edge, corner, the end of a strip. A **terrain** does it for you: you paint "grass", and each cell
takes the grass tile whose edges match the grass around it. This is often called autotiling.

### Setting up a terrain in Aseprite

Give each tile of the terrain two **properties**: in Aseprite's Tileset panel, select the tile,
open its **Properties** (the tile's User Data), and add:

- `terrain`: the terrain's name, the same for all its tiles: `grass`.
- `mask`: which of its eight neighbours are the same terrain, for that tile to be drawn. Add up
  the numbers of the sides that are grass:

  |   |   |   |
  |---|---|---|
  | NW 128 | N 1 | NE 2 |
  | W 64 | (the tile) | E 4 |
  | SW 32 | S 16 | SE 8 |

  A tile with grass above and to the right (N + E) has mask 5. The middle tile, with grass all
  around, has mask 255. Instead of a number, `mask` can be names: `N,E,S,W`.

Two common kinds of tile sets:

- **16 tiles, edges only.** Use only N, E, S, W (1, 4, 16, 64): one tile for each of the 16 ways
  the four sides can be grass or not. Corners are ignored.
- **47 tiles ("blob"), edges and corners.** Add the corners too. A corner only counts when both
  sides next to it are grass, so 47 tiles cover every case.

If no tile matches a cell exactly, the closest one is used, so a set missing some tiles still
works.

### Painting a terrain

1. In the Tiles panel, pick the **Terrain** tool (it shows when the layer's tileset has terrains)
   and the terrain in **Terrain**.
2. Paint. Each painted cell, and its neighbours, take the tile that fits.
3. The right button removes the terrain, and the neighbours fix their edges.

Cells beyond the layer's edges count as the same terrain, so grass reaching the edge of the map
doesn't get a border there. Tiles that aren't part of a terrain are left as they are.

## Collision: solid, one-way and area tiles

Tiles say what they are in the physics world through properties set in Aseprite, the same way as
terrains (a tile's Properties, or the tileset's Properties for every tile of it):

| Property | Value | The tile becomes |
|---|---|---|
| `collision` | `solid` | A wall or floor: bodies can't pass |
| `collision` | `one-way` | A platform: bodies pass up through it and land on top |
| `collision` | `area` | An area: bodies pass through, and it reports them entering and leaving |
| `area` | a name, like `spikes` | An area of that name |
| `solid` | `true` (a checkbox) | Solid, like `collision = solid` |

When the TileMap is built (in the viewport and in the game), its solid and one-way tiles become
one **StaticBody** named `Collision`, with neighbouring tiles merged into a few large rectangles.
The area tiles become an **Area** per name (`spikes`, or `Area` without a name). Scripts listen to
those Areas' events (Area enter and exit) like any Area's.

In the inspector:

- Each layer's line counts its tiles: "4 solid, 1 one-way, 2 in spikes".
- **Tile collision** turns all of it off (for a background layer, say).
- **Layers**, **Mask**, **Friction** and **Bounce** are the bodies' physics settings, as on any
  body.

Collision comes from the TileMap's **Frame** (below), and painted tiles count like the file's.

## Animated tiles

A tilemap in Aseprite can be different in each frame: water moving, torches flickering. Tick the
TileMap's **Animate** in the inspector to play the file's frames at their durations (set in
Aseprite's timeline). **Tag** plays only the frames of one of the file's tags.

Collision stays the tiles of the TileMap's **Frame** while it plays, so the bodies don't change.
A painted layer is the same in every frame.

The viewport plays it when animations are on (P).

## The TileMap's settings

| Setting | What it does |
|---|---|
| **Tilemap file** | The Aseprite file (files with tilemap layers are listed first) |
| **Frame** | The frame of the file shown (and collision's); only with more than one frame |
| **Layers** (checkboxes) | Which tilemap layers it draws. With none ticked, every layer visible in Aseprite. Ticking a layer hidden in Aseprite draws it anyway. The last one can't be unticked |
| **Animate** | Plays the file's frames |
| **Tag** | The tag whose frames it plays (Every frame: all of them) |
| **Tile collision** | Tiles' collision properties become bodies |
| **Layers, Mask, Friction, Bounce** | The generated bodies' physics settings |

## Tilemaps in scripts

A script can find the TileMap node (an exported field of type `^e.TileMapNode`, or
`e.Scene_FindNode`) and read or change its tiles. Positions are in the world, the same as nodes'.

```odin
// Given: hitPoint: [2]f32, seedPoint: [2]f32
// (hitPoint: where the hero's head hit a block; seedPoint: where a seed landed)
level := cast(^e.TileMapNode)e.Scene_FindNode(self.scene, "Level")

// The tile under the hero's feet, and one of its properties
tile, layer, found := e.TileMap_TileAt(level, "Ground", e.Node_GetWorldPosition(self.node))
if found {
	if damage, has := e.TileMap_TileProperty(layer, tile, "damage"); has {
		// ...
	}
}

// Break the block the hero hit: empty its cell
if column, row, ok := e.TileMap_CellAt(level, "Ground", hitPoint); ok {
	e.TileMap_SetTile(level, "Ground", column, row, 0)
}

// Grow grass where a seed lands: the terrain picks the right tiles
if column, row, ok := e.TileMap_CellAt(level, "Ground", seedPoint); ok {
	e.TileMap_SetTerrain(level, "Ground", column, row, "grass")
}
```

| Procedure | What it does |
|---|---|
| `e.TileMap_TileAt(node, layer, position)` | The tile under a point ("" layer: the top-most with a tile there) |
| `e.TileMap_CellAt(node, layer, position)` | The column and row of the cell under a point |
| `e.TileMap_SetTile(node, layer, column, row, tile)` | Changes a cell's tile (0 empties it) |
| `e.TileMap_SetTerrain(node, layer, column, row, terrain)` | Paints a terrain ("" removes it) |
| `e.TileMap_TileProperty(layer, tile, name)` | A tile's property (its own, else its tileset's) |
| `e.TileMap_TileCollision(tileset, tile)` | What a tile becomes in the physics world |

Changed tiles show at once. Their collision is rebuilt on the node's next update, and the
TileMap's bodies are new ones then: a script that kept one of them must find it again.

A tile value is the tile's number in its tileset, plus flip bits: `tile | e.ASEPRITE_TILE_FLIP_X`
mirrors it, `e.ASEPRITE_TILE_FLIP_Y` flips it, `e.ASEPRITE_TILE_FLIP_D` swaps its axes (with one of
the others, a quarter turn). `tile & e.ASEPRITE_TILE_ID` is the number alone.

## How it's stored

A TileMap is a node in the scene file:

```xml
<node kind="TileMap" name="Level" tilemap="assets/forest.aseprite" animate="true" tag="water">
	<tiles layer="Ground" columns="40" rows="12" data="AQAAAAEAAAACAAAA..."/>
</node>
```

Each `<tiles>` element is a layer painted in the editor: its name (a file layer it replaces, or a
layer of the scene's own), its tileset (`tileset`, for a layer of its own), its corner (`x`, `y`,
in pixels), its size in tiles, and its tiles. The tiles are the same 32-bit values Aseprite uses
(the tile's number and its flips), row by row, written as base64. The file itself is never
written.

## Questions

**Why don't my changes in Aseprite show on a layer I painted?** Painting a file layer copies it
into the scene. Press **Use the File's Tiles** in the Tiles panel to go back to the file's tiles
(your painting of that layer is lost).

**Can I paint on a rotated or scaled TileMap?** Yes: the cell under the mouse follows the node's
rotation and scale.

**My terrain draws the wrong edges.** Check each tile's `mask`: it lists the sides that are the
same terrain, not the sides with an edge drawn. A tile with grass on every side is 255 (or
`N,E,S,W` for an edge set).

**The Terrain tool isn't there.** The layer's tileset has no tile with a `terrain` property.
