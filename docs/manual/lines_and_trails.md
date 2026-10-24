---
title: Lines, trails and GPU particles
description: Draw thick lines through points (ropes, lasers, paths), leave trails behind moving things (sword swings, dashes, comets), and run tens of thousands of particles on the graphics card.
order: 12
---

# Lines, trails and GPU particles

- **Line2D** draws a thick line through points: a rope, a laser beam, a path on a map, an
  outline. It can fade from one color to another, have round or sharp corners and round ends,
  close into a loop, and carry an image along it.
- **Trail2D** leaves a ribbon behind whatever it's attached to as it moves: a sword's swing, a
  dash, a comet's tail, tire tracks. The ribbon narrows and fades with age.
- **GPU particles**: a ParticleEmitter can run on the graphics card, with tens of thousands of
  particles where the CPU manages a few hundred.

- [Lines](#lines)
- [Trails](#trails)
- [Line and trail settings](#line-and-trail-settings)
- [GPU particles](#gpu-particles)
- [In scripts](#in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Lines

1. **Add Node > Line2D** (under Graphics).
2. Type its **Points** in the inspector: `x,y` pairs separated by spaces, in the node's own
   space. `0,0 200,0 200,100` is an L shape starting at the node's position. The viewport draws
   it as you type.
3. Set its **Line width**, **Line color** and **End color** (the color blends from one to the
   other along the line), and **Opacity at end** to fade it out.
4. **Joints**: Sharp corners (pointed, cut flat when very sharp) or Round. **Round caps**
   rounds both ends. **Closed** joins the last point back to the first: an outline.
5. Give it a **Texture** to draw an image along it: **Stretch** puts the image once along the
   whole line, **Tile** repeats it every line-width of length (a chain, a dashed line).

Moving, turning and scaling the node moves, turns and scales the line; its width scales with it.

## Trails

1. Select what should leave the trail (the player, a sword, a projectile).
2. **Add Node > Trail2D**: it becomes a child of the selected node, and follows it.
3. Set its **Start width** (by the parent) and **End width** (at the trail's tail; 0 tapers it
   to a point), **Start color** and **End color**, and **Opacity at end** (0 fades it out).
4. **Trail length (s)**: how long each point lasts, so how long the trail is behind a moving
   parent. **Point spacing**: how far the parent moves before a new point is added (smaller is
   smoother on curves).

The trail draws in the world, not on its parent: when the parent turns, the trail stays where
it was. **The viewport doesn't show trails**, since nothing moves there. Play to see it.

**Emitting** off stops adding points: the trail fades away behind the parent. Use it for a
sword trail only during a swing (see [In scripts](#in-scripts)).

## Line and trail settings

| Setting | Line2D | Trail2D | What it does |
|---|---|---|---|
| **Points** | yes | | The line's points, in the node's space |
| **Line width** / **Start width** | yes | yes | Thickness in pixels (a trail's at its newest point) |
| **End width** | | yes | Thickness at the oldest point |
| **Line color** / **Start color**, **End color** | yes | yes | Blended along the length |
| **Opacity at end** | yes | yes | The end color's opacity |
| **Joints** | yes | yes | Sharp or Round corners |
| **Round caps** | yes | yes | Rounded ends |
| **Closed** | yes | | A loop |
| **Texture**, **Texture mode** | yes | yes | An image along it: Stretch or Tile |
| **Trail length (s)** | | yes | Seconds a point lasts |
| **Point spacing** | | yes | Pixels moved between points |
| **Emitting** | | yes | Adding points |

A line or trail with a texture also takes a shader (the inspector's Shader section; see the
shaders page).

## GPU particles

Any ParticleEmitter can simulate on the graphics card:

1. Select the emitter and tick **On the GPU** (its GPU settings: the Particles tab's GPU
   category).
2. Set **GPU amount**: how many particles a cycle, up to 200 000. **Amount** is still used where
   the GPU path can't run (below).

Every other setting works the same: lifetime, burst, spread, shapes, sizes and scales, rotation
and spin, colors and the color ramp (its first 8 stops), angle and velocity, acceleration,
gravity and wind, local space, and the node's **Blend** (Add for glowing sparks). Differences:
- **No collisions** with the view's edges.
- The **Ellipse**, **Line**, **Pixel** and **Custom** shapes draw as circles; **Circle**,
  **Rectangle** and **Texture** are as on the CPU.

**Where it runs:** the GPU renderer, like shaders. A project with GPU particles picks it when its
Renderer is Auto, and the viewport shows them with it. Elsewhere (other renderers, the web) the
emitter simulates on the CPU with **Amount** particles, so the game still works.

How it compares, measured on a laptop's integrated graphics (Intel UHD 620), the time a frame
takes to move and draw the particles:

| Particles | Time a frame |
|---|---|
| 500 on the CPU | 1.6 ms |
| 500 on the GPU | 0.8 ms |
| 20 000 on the GPU | 2.1 ms |
| 100 000 on the GPU | 5.2 ms |

## In scripts

```odin
Sword :: struct {
	using script: e.Script,
	trail: ^e.Trail2D `export:"default=Trail"`,
	beam: ^e.Line2D `export:"default=../Beam"`,
}

// A swing: the trail draws only while it lasts
Sword_swing :: proc(self: ^Sword, swinging: bool) {
	e.Trail2D_SetEmitting(self.trail, swinging)
}

// After a teleport: no streak across the screen
Sword_teleported :: proc(self: ^Sword) {
	e.Trail2D_Clear(self.trail)
}

// A laser from the sword to a target, in the beam's space
Sword_aim :: proc(self: ^Sword, target: [2]f32) {
	e.Line2D_SetPoints(self.beam, {{0, 0}, target})
}
```

| Procedure | What it does |
|---|---|
| `e.CreateLine2D(scene, points)`, `e.CreateTrail2D(scene)` | Make one from code |
| `e.Line2D_SetPoints(line, points)`, `e.Line2D_AddPoint(line, point)`, `e.Line2D_Clear(line)` | A line's points |
| `e.Trail2D_SetEmitting(trail, on)`, `e.Trail2D_Clear(trail)` | Start, stop, empty a trail |
| `line.settings`, `trail.settings` | Every setting (`width`, `color`, `joint`, `lifetime`...) |
| `e.ParticleEmitter_OnGPU(emitter)` | Whether an emitter is drawing on the GPU now |

## How it's stored

```xml
<node name="Beam" kind="Line2D" points="0,0 300,0" lineWidth="6" lineColor="#ff4040" endColor="#ff404000" roundCaps="true"/>
<node name="Trail" kind="Trail2D" lineWidth="12" endWidth="0" lifetime="0.3" minDistance="3"/>
<node name="Sparks" kind="ParticleEmitter"><particles gpu="true" gpuAmount="20000"/></node>
```

Only the settings that differ from the defaults are written. A project with GPU particles has
`shaders="true"` in project.xml, so Auto picks the GPU renderer.

## Questions

**My trail doesn't show.** It draws only while its parent moves, and only in Play. Check
**Emitting** is on and the **Trail length** isn't tiny.

**The line's corners look cut off.** Sharp corners sharper than about 60° are cut flat, or the
point would reach far out. Use **Round** joints.

**GPU particles look the same as before.** The project draws with another renderer, or this
computer's GPU renderer can't run them; the Console says so. Then the CPU draws **Amount**
particles.
