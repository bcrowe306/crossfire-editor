---
title: LDtk levels
description: Draw your levels in the LDtk level editor and use them in scenes, with tile layers, IntGrid collision, entities that become components with scripts, and levels that update while the game plays.
order: 16
---

# LDtk levels

[LDtk](https://ldtk.io) is a free level editor made for 2D games. In it you paint a level's
**tiles** (ground, walls, decorations) on layers, mark which cells are solid on an **IntGrid**
layer (a grid of numbers: 1 for ground, 2 for platforms...), and place **entities**: the player's
start, coins, enemies, doors, with **fields** of their own (a coin's value, an enemy's speed).
Many levels make a **world**.

The Crossfire Editor reads LDtk's files as they are. An **LDtkLevel** node shows a level in a
scene exactly as the game draws it, turns its IntGrid into collision, and turns its entities into
nodes with your components and scripts. You keep drawing in LDtk; the editor and the running game
follow your saves.

The demo project's three levels (ForestScene, HollowScene and LairScene, all in
`assets/levels/legacy.ldtk`) use everything on this page.

- [Importing an LDtk project](#importing-an-ldtk-project)
- [Putting a level in a scene](#putting-a-level-in-a-scene)
- [Picking levels on the world map](#picking-levels-on-the-world-map)
- [The LDtkLevel node's settings](#the-ldtklevel-nodes-settings)
- [Collision from an IntGrid layer](#collision-from-an-intgrid-layer)
- [Entities](#entities)
- [Fields: settings from LDtk](#fields-settings-from-ldtk)
- [What the inspector tells you](#what-the-inspector-tells-you)
- [Editing in LDtk while you work](#editing-in-ldtk-while-you-work)
- [Levels in scripts](#levels-in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Importing an LDtk project

1. File > **Import Asset...** (Ctrl+I) and pick the `.ldtk` file.
2. The editor copies it into the project, in `assets/<its name>/`, with every file it needs, at the
   same places relative to it: tileset images, separate level files (`.ldtkl`, when the LDtk
   project saves levels apart) and level background images. LDtk can open the copy just like the
   original.
3. Files the project reached outside its own folder (`../art/tiles.png`) go to
   `assets/<its name>/external/`, and the copy's paths are changed to point there.

If `assets/<its name>/` is taken, the copy goes to `<its name>_2`, and so on. A `.ldtk` file that's
already inside the project folder isn't copied: it's used where it is.

**From now on, edit the copy** in the project: it's the one the game uses. Its browser preview, the
inspector and the right-click menu have **Open in LDtk**, which opens it in LDtk (a double-click in
the browser does too). If LDtk isn't found, set where it is in **Edit > Settings... > Editor >
LDtk program**.

The browser lists LDtk projects in its **Levels** folder. Select one to see its preview: a picture
of the whole world, the LDtk version, and each level with its size, layers and entities.

When you export the game, the files the LDtk project needs go with it.

## Putting a level in a scene

- **Drag** the LDtk project from the browser into the viewport. A **Level** node is added with its
  first level's top-left corner where you let go.
- Or **Add Node** (Ctrl+Shift+A) > **LDtkLevel** (under Scene), then choose its **LDtk file** in the
  inspector.

The level shows in the viewport as the game draws it. Move the node to move the whole level; like
any node, it can be undone, duplicated, and put under another node.

## Picking levels on the world map

The browser's preview of an LDtk project shows its world, every level in its place. Hover a level
to outline it, and click it: the selected LDtkLevel node shows that level (or, when none is
selected, the scene's first LDtkLevel node using that file). It's an undo step like any other edit.

The inspector's **Level** choice does the same from a list.

## The LDtkLevel node's settings

| Setting | What it does |
|---|---|
| **LDtk file** | Which LDtk project |
| **Open in LDtk** | Opens it in LDtk |
| **Level** | Which level; **(first level)** is the first of the file |
| **Whole world** | Builds every level of the level's world, each in its place, for a game that scrolls from level to level without loading (LDtk's Free and GridVania layouts place levels where they are in the world; linear layouts one after the other) |
| **Collision** | The IntGrid layer that becomes collision, or **(none)** ([below](#collision-from-an-intgrid-layer)) |
| **Entities** | Makes nodes for the level's entities. Untick it to see the level without them |
| **Background** | Draws the level's background color and image from LDtk |
| **Smooth tiles** | Smooths the tiles when they're drawn bigger or smaller. Off (the default) keeps pixel art sharp |

Under **Level**, a picture of what it builds and what LDtk says about the level: its size in pixels
and cells, its place in the world, its background, its neighbours and its own LDtk fields.

How layers are drawn:

- LDtk's top layer draws on top, as in LDtk. Every layer is on the LDtkLevel node's render layer.
- Layers hidden in LDtk (its eye button) are hidden.
- IntGrid layers without tiles draw their values' colors, as LDtk shows them.
- **Parallax** layers (a parallax factor set in LDtk) move with the camera in the game the way LDtk
  does it. In the editor's viewport they stay where they were drawn.

## Collision from an IntGrid layer

Choose the IntGrid layer in **Collision** (the demo's is called Ground). Each of its values
gets a row, named after the value in LDtk ("1 Ground", "2 Platform"), where you choose what it
becomes:

| Choice | What its cells become |
|---|---|
| **Solid** | Walls and floors: solid rectangles of a StaticBody named **Collision** |
| **One-way platform** | Platforms you jump up through from below and land on from above (in the same StaticBody: see [One-way platforms](physics.md#one-way-platforms)) |
| **Area (a trigger)** | An **Area** named after the value ("Spikes", or Area2 when the value has no name): it reports bodies coming in and going out, for spikes, water, ladders, exits |
| **Nothing** | No collision |

Every value starts **Solid**. Neighbouring cells are joined into bigger rectangles, so a wall is one
shape, not one per cell.

Under the values, the collision's **Layers**, **Collides**, **Friction** and **Bounce**, as for any
body ([Physics](physics.md#layers-who-collides-with-whom)): they apply to the StaticBody and the
Areas the level makes.

The inspector's **How it's built** counts the solid, one-way and area cells. The viewport draws
the shapes themselves over the level, the same rectangles the game gets: solid ones green, one-way
platforms amber, areas purple. The polygon button in the viewport's header (**Shift+C**, or **View
> Show Collision Shapes**) hides and shows them. In the running game, the toolbar's collision
shapes button beside Play, or **F9**, shows them ([Seeing the shapes](physics.md#seeing-the-shapes)).

## Entities

Each entity type of the LDtk project (Player, Coin, Enemy...) has a line in the inspector, with
how many of them the level has, and two choices.

**Becomes**: what node each entity of the type is.

| Choice | What it makes |
|---|---|
| **Auto** | The component chosen for it if any, else what code registered for it (`e.LDtk_RegisterEntity`), else its rectangle |
| A component (`components/coin.component.xml`) | An instance of that component: your own node tree, with its sprite, body, shapes, sounds |
| **Its rectangle** | A plain node the size of the entity, drawing the entity's tile from LDtk if it has one |
| **Code (LDtk_RegisterEntity)** | What your code makes for it ([Levels in scripts](#levels-in-scripts)); its rectangle when nothing registered it |
| **Nothing (skipped)** | No node: the entity is only data for your code |

The node is placed at the entity's position in LDtk (its pivot) and named after it.

**Runs**: the script attached to each entity's node.

| Choice | What runs |
|---|---|
| **Auto (named like it)** | The script with the entity's name: a Coin entity runs a script called `Coin`, when the node made has no script of its own |
| **No script** | None, not even one named like it |
| A script | That script |

**The usual way:** for each kind of thing in your level, make a component and a script with the
entity's name.

1. Make the coin as a component: an **Area** with a **Sprite** and a **CollisionShape** (see
   [Physics](physics.md)), saved with **Save as Component** (the scene tree's right-click menu).
2. Write a script named `Coin` (Scripts > **New Script...**): what a coin does when touched.
3. In the LDtkLevel's inspector, set the Coin entity's **Becomes** to the component. **Runs** stays
   **Auto**: the `Coin` script runs on every coin.

Now every coin you place in LDtk is a working coin in the game. The demo's hero, coins, gems,
creatures, rune stones, platforms and boss are made this way.

## Fields: settings from LDtk

An entity's **fields** in LDtk set the script's exported fields with the same name (capitals and
underscores don't matter: LDtk's `move_speed` sets `moveSpeed`). So one Enemy script can have a slow
snail and a fast boar, set in LDtk:

```odin
// An LDtk entity "Enemy" with Int field "health" and Float field "speed"
Enemy :: struct {
	using script: e.Script,
	health: int `export:"default=3 min=1"`,
	speed: f32 `export:"default=60"`,
}

@(init)
register_Enemy :: proc "contextless" () {
	e.Script_Register(Enemy, {
		ready = proc(self: ^Enemy) {
			log.infof("%s: health %d, speed %v", self.node.name, self.health, self.speed)
		},
	})
}
```

Fields that set script fields: integers, floats, booleans, strings, enums (by the value's name),
colors and points (the pixel position of the middle of the cell). Arrays, tiles and entity
references are read by code ([Levels in scripts](#levels-in-scripts)). Script fields with no LDtk
field of their name keep their default.

## What the inspector tells you

The LDtkLevel's inspector explains how the level is built, so there are no surprises in the game:

- **How it's built**: every layer, bottom first, and what it makes: drawn tiles, auto-layer tiles,
  IntGrid colors, the collision layer (how many cells are solid, one-way or in areas), entities
  made or not; its parallax, opacity and whether it's hidden.
- **Entities**: per type, what it becomes and why, the script it runs (or one that would run if you
  wrote it), and which LDtk field sets which script field. An entity that would be a bare rectangle
  with no script is shown as a warning: it would do nothing in the game.
- **In the level**: every entity, with its position and fields. Click one to center the viewport on
  it.

## Editing in LDtk while you work

Keep LDtk open beside the editor:

- **In the editor:** save in LDtk, and the viewport shows the new level as soon as the editor next
  draws. The inspector reads the file again too.
- **While the game plays** (started with Play): saving in LDtk updates the running game. Tiles,
  collision and backgrounds change in place; layers added or removed in LDtk appear or go; entities
  you place spawn (with their scripts), and entities you delete go. The others keep running where
  they are, so a hero halfway through the level stays there. The LDtkLevel node's **onReloaded**
  event fires after each reload.

Exported games don't watch their files.

## Levels in scripts

Find the level node by name, then ask it about its entities and cells:

```odin
// The scene's LDtkLevel node, named "Level"
Level :: proc(scene: ^e.Scene) -> ^e.LDtkLevelNode {
	node := e.Scene_FindNode(scene, "Level")
	if node == nil || !e.Node_Is(node, e.LDtkLevelNode) do return nil
	return cast(^e.LDtkLevelNode)node
}

ex_level :: proc(self: ^e.Script) {
	level := Level(self.scene)
	// Every Coin entity's node
	for coin in e.LDtk_FindEntityNodes(level, "Coin") do log.infof("a coin at %v", coin.position)
	// The IntGrid value under this node (0: empty)
	if e.LDtk_IntGridAtPosition(level, "Collisions", e.Node_GetWorldPosition(self.node)) == 3 {
		log.info("on a ladder")
	}
}
```

An entity's script can read its own LDtk data, including what doesn't set script fields:

```odin
ex_fields :: proc(self: ^e.Script) {
	entity := e.LDtk_EntityOf(self.node)
	if entity == nil do return
	speed := e.LDtk_FieldValue(entity.fields, "speed", f64(100))
	name := e.LDtk_FieldValue(entity.fields, "name", "nobody")
	log.infof("%s runs at %v", name, speed)
	// A lever whose "door" field (an EntityRef) points at a door
	door := e.LDtk_EntityRefNode(self.node, "door")
	if door != nil do door.visible = false
}
```

**Entity references** (LDtk's EntityRef fields, drawn as arrows between entities) let the level
decide which lever opens which door, not the code: the demo's boss trigger closes the gate its
"gate" field points at (`scripts/level.odin`).

**Entities made by code:** register what an entity type becomes, and set its **Becomes** to Auto or
Code:

```odin
@(init)
registerSpawners :: proc "contextless" () {
	e.LDtk_RegisterEntity("Torch", proc(scene: ^e.Scene, entity: ^e.LDtkEntity) -> ^e.Node {
		return e.CreateParticleEmitter(scene)
	})
}
```

| Code | What it does |
|---|---|
| `e.LDtk_FindEntityNodes(level, "Coin")` | The nodes made for an entity type |
| `e.LDtk_IntGridAtPosition(level, "Collisions", position)` | The IntGrid value at a world position (0: empty or outside the level) |
| `e.LDtk_EntityOf(node)` | The LDtk data of an entity's node (or of a node under it): `identifier`, `iid`, `size`, `fields`... |
| `e.LDtk_FieldValue(fields, "name", default)` | A field's value, or the default when it's missing or of another type (the default's type says which: `f64(1)`, `int(0)`, `""`, `true`) |
| `e.LDtk_EntityRefNode(node, "door")`, `e.LDtk_EntityRefNodes(node, "lamps")` | The node an EntityRef field points at; the nodes of an array of them |
| `e.LDtk_FindEntityByIid(level, iid)` | An entity's node by its LDtk iid |
| `e.LDtk_RegisterEntity("Torch", spawn)` | Makes an entity type's nodes in code |
| `e.Asset_LDtk(game, LDTK_LEGACY)` | The whole LDtk project's data (worlds, levels, layers, definitions), from its constant in `scripts/assets.odin` |

The LDtkLevel node's events (inspector > **Events** > **Listen...**): **onEntitySpawned** (an
entity's node was made, when the level is built or a reload added one; its data is the node) and
**onReloaded**.

A collected coin removed with `e.Scene_RemoveNode` leaves the level's lists, so the lookups never
hand back a removed node.

## How it's stored

The LDtkLevel node in the scene file names the file and level, the collision layer and its values,
and the entity rules that aren't Auto:

```xml
<node kind="LDtkLevel" name="Level" x="0" y="0" ldtk="assets/levels/legacy.ldtk" level="Forest" intGridCollision="Ground" oneWayValues="2" areaValues="4">
	<entity name="Hero" component="components/hero.component.xml"/>
	<entity name="Coin" component="components/coin.component.xml"/>
	<entity name="Marker" make="Skip"/>
</node>
```

`collisionValues` lists the solid values when not every value is solid (`"0"` alone: none);
`allLevels`, `spawnEntities`, `background` and `smoothTiles` appear when changed. The level itself
stays in the `.ldtk` file: the nodes it makes aren't in the scene file.

## Questions

**The level is empty in the viewport.** Check its **LDtk file** and **Level**, and that the file
opens (the inspector says when it can't be read). Tilesets must be where the LDtk project expects
them: import the `.ldtk` with the editor, which brings them along.

**The player falls through the ground.** Choose the IntGrid layer in **Collision**, and check its
values are **Solid**: the viewport then outlines the ground in green (with the viewport's
collision shapes on, **Shift+C**). The player's body must collide with the level's layers
(**Collides**).

**My entities are just rectangles.** Choose a component in their **Becomes**, or write a script
named like them: the inspector says what each type becomes and why.

**My script's field isn't set from LDtk.** The names must match (capitals and underscores aside),
and the field must be one of the kinds that set script fields; arrays and references are read with
`e.LDtk_EntityOf`.

**Parallax doesn't move in the editor.** It only moves in the game, with the camera. Press Play.

**Can I change the level while the game runs?** Yes: save in LDtk ([Editing in LDtk while you
work](#editing-in-ldtk-while-you-work)).
