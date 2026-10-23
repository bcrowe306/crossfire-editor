---
title: Collision from sprites and physics materials
description: Give a body collision shapes that fit its sprite, and share friction, bounce and density between bodies with physics materials.
order: 10
---

# Collision from sprites and physics materials

Physics bodies collide through the **CollisionShape** nodes under them: rectangles, circles,
capsules, polygons. Two tools save time:

- **Collision from sprite** traces the opaque pixels of a sprite into polygon shapes, so a rock,
  a ship or a piece of ground collides where it's drawn instead of as a box.
- **Physics materials** keep a surface (friction, bounce) and density in one shared file, so
  every ice block in the game slides the same way and you change them all in one place.

- [Collision from a sprite](#collision-from-a-sprite)
- [Physics materials](#physics-materials)
- [In scripts](#in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Collision from a sprite

1. Make the body: **Add Node > StaticBody** (walls, ground, rocks), **DynamicBody** (things that
   fall and get pushed) or **CharacterMover**.
2. Put the picture under it: select the body, **Add Node > Sprite** (or AnimatedSprite), and
   choose its **Image**.
3. Select the body again. At the bottom of its inspector, under **Collision from sprite**:
   - **Sprite**: which sprite to trace (the first one under the body unless you pick another).
   - **Alpha threshold**: how opaque a pixel must be to count as solid, from 1 to 255 (128:
     half see-through and more). Raise it to leave out soft glows and shadows.
   - **Detail**: how far, in pixels, the shapes may stray from the outline. **0** follows every
     pixel step (many small shapes); **1.5** (the default) smooths staircases; larger values
     make fewer, simpler shapes, which are faster for the physics.
4. Press **Make Shapes**.

The body gets CollisionShape nodes named **Traced**, **Traced2**, ...: each a convex polygon of
at most 8 points (what the physics engine takes), together covering the sprite's opaque pixels.
They follow the sprite's position, rotation and scale under the body. An AnimatedSprite is traced
from its first animation's first frame (on that animation's sheet).

They're ordinary shapes: select one to see its points, delete the ones you don't need, or add
your own beside them. **Make Shapes** again (after changing the image or the settings) replaces
the Traced shapes and leaves your own alone. Ctrl+Z takes a trace back.

Holes inside a sprite (a ring's middle) are filled: the shapes follow each region's outside
edge. Pixels that only touch at a corner count as apart.

## Physics materials

A material is a file with three values:

| Setting | What it does |
|---|---|
| **Friction** | How much a surface grips: 0 is ice, 0.6 is typical, 1 is rubber |
| **Bounce** | 0 doesn't bounce, 1 bounces back as high as it fell |
| **Density** | Weight for its size (kg per 100 x 100 pixels): only falling bodies (DynamicBody) use it |

**Making one:**

- From a body: its inspector's **New Material** makes `materials/material.material.xml` and gives
  it to the body.
- From the browser: right-click the **Materials** folder (or empty space) > **New Material**.

**Editing one:** select it in the browser's **Materials** folder. The inspector shows its sliders
and how many bodies use it. Every body using it changes at once.

**Using one:** a body's **Material** choice. With a material, the body's own Friction, Bounce and
Density give way to the material's (the inspector shows them). Choose **(the body's own)** to go
back to the body's values. Areas don't have materials (they stop nothing).

## In scripts

| Code | What it does |
|---|---|
| `e.CollisionShapes_FromTexture(body, "assets/rock.png")` | Traces an image into Traced shapes under a body at run time (also `threshold`, `tolerance`) |
| `e.Image_CollisionPolygons(pixels, w, h)` | The convex pieces for RGBA pixels, for your own use |
| `e.PhysicsBody_SetMaterial(body, {friction = 0.02, restitution = 0.9, density = 0.5})` | Changes a body's surface and density while it runs |
| `material, ok := e.Game_LoadPhysicsMaterial(game, "materials/ice.material.xml")` | Reads a material file (once per game) |

```odin
// A crate's script (on a DynamicBody)
Crate :: struct {
	using script: e.Script,
}

// A body that turns to ice when frozen
freeze :: proc(self: ^Crate) {
	ice, ok := e.Game_LoadPhysicsMaterial(self.game, "materials/ice.material.xml")
	if ok do e.PhysicsBody_SetMaterial(cast(^e.PhysicsBody)self.node, ice)
}
```

## How it's stored

A material file:

```xml
<material formatVersion="13" friction="0.05" restitution="0" density="0.9"/>
```

A body naming it, and its traced shapes (polygons like any other):

```xml
<node kind="StaticBody" name="Rock" material="materials/stone.material.xml">
	<node kind="Sprite" name="Art" texture="assets/rock.png"/>
	<node kind="CollisionShape" name="Traced" shape="Polygon" points="-20,-8 4,-15 20,0 2,14 -18,9"/>
</node>
```

## Questions

**Make Shapes says there are no pixels.** The image is fully transparent at that threshold: lower
**Alpha threshold**.

**Too many shapes.** Raise **Detail** (2 to 4 is plenty for most sprites), or delete the small
ones.

**The shapes are in the wrong place.** They're placed where the sprite draws when you press
Make Shapes: move the sprite, then make them again.

**My body ignores its Friction.** It has a Material: the material's values win. Edit the
material, or set Material to **(the body's own)**.
