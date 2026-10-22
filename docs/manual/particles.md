---
title: Particles
description: Make sparks, smoke, fire, rain, explosions and magic with ParticleEmitter nodes, set up in the inspector and played live in the viewport.
order: 11
---

# Particles

A **particle** is a small dot, shape or picture that's born, moves for a moment and disappears.
Hundreds of them together make effects that would be hard to draw by hand: the sparks of a hit,
smoke from a chimney, a ship's engine flame, rain, fireworks, a coin's sparkle when it's taken.

A **ParticleEmitter** node makes them: it **emits** particles from where it is, sends them off
in a direction, pulls them with gravity and wind, and changes their size and color as they age.
Every setting is in the inspector, and the viewport plays the effect while you change it.

- [Making an emitter](#making-an-emitter)
- [How emission works](#how-emission-works)
- [Spread and variance: a little randomness](#spread-and-variance-a-little-randomness)
- [The settings](#the-settings)
- [The color ramp](#the-color-ramp)
- [Shapes and pictures](#shapes-and-pictures)
- [One-shot and continuous](#one-shot-and-continuous)
- [World space and local space](#world-space-and-local-space)
- [Collisions](#collisions)
- [Particles in scripts](#particles-in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Making an emitter

1. **Add Node** (Ctrl+Shift+A) > **ParticleEmitter** (under Graphics). To make it follow
   something (a ship's flame, a torch carried by an enemy), select that node first, so the
   emitter becomes its child.
2. Place it where the particles should come from.
3. Make sure the viewport's animations are playing (the play button in the viewport's header,
   or **P**): the emitter starts at once, with the default settings, a fiery fountain of dots.
4. Change the settings in the inspector. The viewport shows each change as you make it.

Every change is an undo step (Ctrl+Z); dragging a slider is one step. **Reset to defaults**, at
the top of the emitter's settings, puts every setting back as a new emitter has them, and clears
its picture (it can be undone too).

The inspector's controls:

- **Sliders**: drag, or click the value box beside the slider and type one. Hold Shift while
  dragging for fine steps. The button beside it resets that one setting.
- **Pairs** (Spread, Size, Scale, Gravity dir., Wind) have an X and a Y slider. The link button
  under the name ties them: changing one changes the other in proportion.
- **Colors** have a color picker and an **Alpha** slider beside it (0 transparent, 255 solid).
- Hover a setting's name to see what it does, its range and its default.

## How emission works

An emitter works in **cycles**. A cycle lasts **Lifetime** seconds and emits **Amount**
particles; each particle lives **Lifetime** seconds too. **Burst** says how they're spread over
the cycle: at 0 they come out evenly, one after another (a steady fountain); at 1 they all come
out at once (an explosion).

When a cycle ends, a **Continuous** emitter starts the next one; one that isn't continuous stops
after one cycle (a one-shot: [below](#one-shot-and-continuous)).

## Spread and variance: a little randomness

Particles that all do the same thing look like a machine. Many settings come in threes to make
each particle a little different:

- the base value (**Angle**: the direction, say 270, straight up),
- a **spread** (**Angle spread** 30: up to 30 degrees either way),
- a **variance** (**Angle var.**), from 0 to 1: how much of the spread is used. 0 is none (every
  particle goes straight up), 1 all of it (anywhere from 240 to 300).

So a new emitter's **Angle spread** does nothing until you raise **Angle var.** too.

## The settings

They're in groups, in this order.

**Emission**

| Setting | What it does |
|---|---|
| **Emitting** | Emits from the start. Untick it for an emitter a script starts |
| **Continuous** | Starts a new cycle when one ends; unticked, it stops after one |
| **Amount** | Particles per cycle |
| **Lifetime** | Seconds a cycle lasts, and a particle lives |
| **Burst** | 0: particles spread evenly over the cycle; 1: all at once |
| **Spread** | Half the width and height of the area particles start in, around the emitter (0: all from one point; 300, 0: along a 600 px line, for rain) |
| **Local space** | Particles move with the emitter instead of staying in the world ([below](#world-space-and-local-space)) |
| **On the GPU**, **GPU amount** | Runs the particles on the graphics card, tens of thousands at once: see [Lines, trails and GPU particles](lines_and_trails.md) |

**Shape**

| Setting | What it does |
|---|---|
| **Shape** | What a particle is drawn as ([Shapes and pictures](#shapes-and-pictures)) |
| **Size** | Its size in pixels (what X and Y mean depends on the shape) |
| **Size var.**, **Size spread** | Each particle's size changed at random, up to the spread in pixels either way |
| **Scale start**, **Scale end** | Its scale when born and when it dies, blended in between: 1 to 0 makes particles shrink away, 0 to 1 grow |

**Rotation**

| Setting | What it does |
|---|---|
| **Rotation** | Each particle's starting angle, in degrees (for shapes that can turn: ellipses, rectangles, lines, pictures) |
| **Rotation var.**, **Rot. spread** | Starting angles at random, up to the spread either way |
| **Torque** | Spin, degrees per second (negative: the other way) |
| **Torque var.**, **Torque spread** | Each particle spinning at its own speed |
| **Torque accel.** | How fast the spin changes, degrees per second² |

**Color**

| Setting | What it does |
|---|---|
| **Color ramp** | Ticked: colors come from the ramp ([below](#the-color-ramp)). Unticked: they go from **Start color** to **End color** |
| **Start color**, **End color** | The color when born and when it dies (with alpha: an end alpha of 0 fades particles out) |
| **Color var.** | Each particle's red, green and blue changed a little at random, for less even fire and smoke |

**Motion**

| Setting | What it does |
|---|---|
| **Angle** | The direction particles go, in degrees clockwise from right: 0 right, 90 down, 180 left, 270 up. It turns with the emitter's rotation |
| **Angle var.**, **Angle spread** | Directions at random, up to the spread either way: 360 and a variance of 1 goes every way |
| **Velocity** | Starting speed, pixels per second |
| **Velocity var.**, **Vel. spread** | Speeds at random |
| **Speed scale** | Multiplies how far particles move each frame: 0.5 slow motion, 2 twice as fast |
| **Acceleration** | Speeds particles up (or, negative, slows them down) along their direction, pixels per second² |

**Forces**

| Setting | What it does |
|---|---|
| **Gravity dir.** | Which way gravity pulls (0, 1 is down; 0, 0 turns it off) |
| **Gravity** | How strongly, pixels per second² (negative pulls the other way: smoke rising) |
| **Wind** | A steady push on every particle, pixels per second², x and y |

**Collision**

| Setting | What it does |
|---|---|
| **Collide** | Particles bounce off each other and the edges of the view ([Collisions](#collisions)) |
| **Elasticity** | How much speed they keep after a bounce: 0 none, 1 all |

## The color ramp

With **Color ramp** ticked, particles take their colors from a **ramp**: a strip of colors from
birth (left) to death (right), like a graphics program's gradient. The new emitter's ramp goes
from warm yellow, to red at mid-life, to a dark gray that fades out: fire.

The ramp editor shows the strip over a checkerboard (so you see where it's transparent) with a
marker under it for each **stop** (a color at a point of the particle's life).

- **Click the strip** to add a stop there, in the color the ramp has at that point.
- **Press a marker** to select that stop; **drag** it to move it.
- The selected stop's row (**Stop 2 / 3**) has **Add** (a stop next to it) and **Remove** (a ramp
  keeps at least two).
- Below: the selected stop's **Position** (0 born, 1 dies), **Color** and **Alpha**.

A ramp holds up to 8 stops. Some ideas:

- **Smoke**: dark gray, solid, to light gray with alpha 0.
- **Magic**: white to cyan to purple, fading out.
- **A spark**: white for the first tenth, then orange, then dark red fading out.

## Shapes and pictures

| Shape | What it draws | Size means |
|---|---|---|
| **Circle** | A round dot | X: the radius |
| **Ellipse** | An oval, turned by the particle's rotation | X and Y: the radii |
| **Rectangle** | A rectangle, turned by its rotation (confetti) | Width and height |
| **Pixel** | One screen pixel (stars, dust) | Nothing |
| **Line** | A line along its rotation (rain, speed lines) | X: the length. Its thickness in pixels is the Y of **Scale start** / **Scale end** (at least a pixel) |
| **Texture** | A picture, tinted by the particle's color | Width and height |
| **Custom** | Drawn by your code (the emitter's `customDraw`); a circle without it | Up to your code |

With **Texture**, a **Texture** choice appears under the shape: pick one of the project's images
(import one first with Ctrl+I). A white picture takes the ramp's colors fully; a colored one is
tinted by them, so set the ramp to white if the picture should keep its own colors.

## One-shot and continuous

A **continuous** emitter goes on forever: a torch, a waterfall, an engine. A **one-shot**
emitter (**Continuous** off) emits one cycle and stops: an explosion, a puff of dust when landing,
the sparkle of a coin taken.

For a one-shot, set **Burst** near 1 (all at once), and usually untick **Emitting**, so it doesn't
go off when the scene starts: your script starts it at the right moment
([Particles in scripts](#particles-in-scripts)). The viewport replays a one-shot emitter each
time its particles are gone, so you can watch it while you adjust it (with Emitting ticked).

An emitter that's done (it stopped emitting and its last particle died) sends its
**onFinished** event, once. A common use: an explosion saved as a component, added where
something blows up and removed again on onFinished.

## World space and local space

By default particles live in the **world**: once emitted, they don't care where the emitter goes.
A moving ship leaves its engine flame behind it as a trail. That's usually what you want.

With **Local space** ticked, particles move, turn and scale **with** the emitter, as if painted on
it: a glow around a magic orb that's carried around, a shield's sparkles.

Either way, the direction they're emitted in turns with the emitter's rotation: a flame emitter
under a ship that turns points backward from wherever the ship faces.

## Collisions

With **Collide** ticked, particles bounce off each other and, in world space, off the edges of
what the camera shows (or of the game area without a camera), keeping **Elasticity** of their
speed. It's for effects like balls in a box or bubbles crowding: particles don't collide with
physics bodies.

It compares every pair of particles, so it gets slow quickly: keep **Amount** low (a few hundred
at most) on emitters that collide. GPU particles don't collide.

## Particles in scripts

Give the script a field for the emitter (drop the emitter from the scene tree onto the code tab
to add one), then start and stop it:

```odin
Ship :: struct {
	using script: e.Script,
	explosion: ^e.ParticleEmitter `export:"default=Explosion"`,
	thruster: ^e.ParticleEmitter `export:"default=Thruster"`,
}

@(init)
register_Ship :: proc "contextless" () {
	e.Script_Register(Ship, {
		update = proc(self: ^Ship, events: []sdl.Event, dt: f64) {
			// The flame only while thrusting
			thrusting := e.Input_IsActionPressed("ui_up")
			if thrusting && !self.thruster.emitting do e.ParticleEmitter_Start(self.thruster)
			if !thrusting && self.thruster.emitting do e.ParticleEmitter_Stop(self.thruster)
		},
	})
}

// Blows up where the ship is (Explosion: a one-shot emitter, Emitting off)
Ship_explode :: proc(self: ^Ship) {
	self.explosion.position = self.node.position
	e.ParticleEmitter_Start(self.explosion)
}
```

| Code | What it does |
|---|---|
| `e.ParticleEmitter_Start(emitter)` | Starts emitting: a new cycle begins (fires a one-shot again) |
| `e.ParticleEmitter_Stop(emitter)` | Stops emitting; live particles finish their lives, then onFinished |
| `e.ParticleEmitter_Clear(emitter)` | Removes every live particle at once |
| `e.ParticleEmitter_AliveCount(emitter)` | How many particles are alive |
| `emitter.emitting` | Whether it's emitting now (`emitter.settings.emitting` is only how it starts) |
| `emitter.settings.amount = 120` | Any setting, any time: new particles use it, live ones its forces and colors |
| `e.CreateParticleEmitter(scene)` | A new emitter from code (with the default settings, or pass your own) |

In code, the settings' names are the scene file's: **Amount** is `amount`, **Start color**
`particleColor`, **Color ramp** `useColorRamp`, **Gravity** `gravityVelocity`, **Gravity dir.**
`gravityDirection`, **Collide** `collisionEnabled`. Hover a setting in the inspector, or look at
`ParticleSettings` in the engine's `particles.odin`, for the rest.

**When it's finished:** select the emitter, open the inspector's **Events** (Show), and
**Listen...** to **onFinished** to have the editor write a handler into a script. Or from code:

```odin
// Remove the emitter once its particles are gone
e.Event_Subscribe(&boom.onFinished, proc(_: ^e.EventSubject, source: rawptr, _: e.EventData, _: rawptr) {
	emitter := cast(^e.ParticleEmitter)source
	e.Scene_RemoveNode(emitter.scene, emitter.id)
}, nil)
```

The demo project's forest level does both: `scripts/coin_collect.odin` (a coin's sparkle) and
the blood burst in `scripts/effects.odin`.

## How it's stored

An emitter's settings are a `<particles>` element in the scene file, with only the settings that
differ from the defaults; a Texture shape's picture is the node's `texture`:

```xml
<node kind="ParticleEmitter" name="Sparkle" x="0" y="0" texture="assets/star.png">
	<particles continuous="false" amount="10" lifetime="0.5" burst="0.9" shape="Texture" size="13,13" colorRamp="0:#ffe664 0.5:#ffffff 1:#28282800" angleVariance="1" angleSpread="360" gravityVelocity="0"/>
</node>
```

A ramp is `position:#color` pairs, the color as `#rrggbb` or `#rrggbbaa`.

## Questions

**Nothing moves in the viewport.** The viewport's animations are paused: press **P** (or the
play button in the viewport's header). Check **Emitting** too.

**My one-shot plays when the scene starts.** Untick **Emitting**, and start it from a script.

**My explosion trails behind the ship.** That's world space doing its job. Tick **Local space** if
the particles should move with the ship.

**The spread does nothing.** Raise the variance beside it (**Angle var.**, **Size var.**...): at 0
the spread isn't used.

**My particles stop at 1000.** A CPU emitter keeps up to 1000 particles alive; past that the
oldest ones are reused. For more, tick **On the GPU** ([GPU particles](lines_and_trails.md)).

**Can particles hit walls?** Not physics bodies: **Collide** only bounces them off each other and
the edges of the view.
