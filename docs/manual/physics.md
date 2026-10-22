---
title: Physics
description: Make things fall, collide, bounce and be pushed with physics bodies, collision shapes, layers, ray casts and joints, and move platformer characters that slide along walls and floors.
order: 9
---

# Physics

**Physics** makes the things in your game behave like solid objects: a crate falls and lands on
the ground, a ball bounces off a wall, a player can't walk through a door, a coin notices the
player touching it. The engine does this with Box2D, a well-known physics library: you say what
each thing is and what shape it has, and the physics works out how they move and touch.

Two kinds of node work together:

- A **body** says what a thing is: a wall that never moves, a crate that falls, a character your
  code moves, or an invisible trigger region.
- A **CollisionShape** under it says what shape it has: a rectangle, a circle, a capsule, a
  polygon or a line.

- [A first example: a falling crate](#a-first-example-a-falling-crate)
- [The body kinds](#the-body-kinds)
- [Collision shapes](#collision-shapes)
- [Body settings](#body-settings)
- [Layers: who collides with whom](#layers-who-collides-with-whom)
- [Gravity and pixels per meter](#gravity-and-pixels-per-meter)
- [Seeing the shapes](#seeing-the-shapes)
- [One-way platforms](#one-way-platforms)
- [Collision events](#collision-events)
- [A platformer character](#a-platformer-character)
- [RayCast nodes](#raycast-nodes)
- [Asking the physics from code](#asking-the-physics-from-code)
- [Joints](#joints)
- [In scripts](#in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## A first example: a falling crate

1. **Add Node** (Ctrl+Shift+A) > **StaticBody**, and name it Ground. Place it near the bottom of
   the game area.
2. With Ground selected, **Add Node > CollisionShape**. It becomes Ground's child. In the
   inspector, keep **Shape** on Rectangle and set **Width** to 600 and **Height** to 40.
3. Select the top of the scene again (nothing selected, or the World node), **Add Node >
   DynamicBody**, and name it Crate. Place it above the ground.
4. Under Crate, add a **Sprite** (its picture) and a **CollisionShape** (a 48 x 48 Rectangle).
5. Press **Play** (F5). The crate falls and lands on the ground.

Nothing falls in the editor's viewport: physics only runs in the game.

A body without a shape collides with nothing; the inspector warns you ("Add a CollisionShape
under it..."). A shape that isn't under a body does nothing; the inspector warns about that too.
A shape belongs to its nearest body above it, so you can keep shapes inside a helper Node2D
under the body.

## The body kinds

They're in Add Node under **Physics**.

| Node | What it is | Use it for |
|---|---|---|
| **StaticBody** | Doesn't move by itself; other bodies collide with it. Moving its node in code moves it (it jumps there) | Walls, floors, platforms, rocks |
| **DynamicBody** | Moved by gravity, collisions, forces and pushes; its node follows it | Crates, balls, debris, ragdoll parts |
| **CharacterMover** | Moved by your code, sliding along whatever it hits instead of going through. It pushes dynamic bodies out of its way | Players and enemies in platformers and top-down games |
| **Area** | A region that notices bodies coming in and going out, and stops nothing | Coins, pickups, checkpoints, water, damage zones, doors that open when you're near |

## Collision shapes

Select a CollisionShape to set its **Shape**:

| Shape | Settings | Notes |
|---|---|---|
| **Rectangle** | **Width**, **Height** | Centered on the node |
| **Circle** | **Radius** | |
| **Capsule** | **Radius**, **Height** | Upright; the height includes the round ends. What a CharacterMover moves as |
| **Polygon** | **Points** | `x,y` pairs separated by spaces, 3 to 8 points. A concave outline is made convex: use several polygons for an L shape |
| **Segment** | **Points** | Two `x,y` points: a thin line, for ground outlines and thin walls |

A shape moves, turns and scales with its node: rotate a rectangle to make a slope. Two more
settings:

- **Disabled** leaves the shape out of its body.
- **One way** makes it a one-way platform ([below](#one-way-platforms)).

To give a body shapes that follow its sprite's outline, use **Collision from sprite** at the
bottom of a body's inspector: see
[Collision from sprites and physics materials](collision_and_materials.md).

The viewport outlines shapes in their body's color, and each shape can be clicked and moved like
any node. The polygon button in the viewport's header (**Shift+C**) hides or shows the outlines.

## Body settings

Every body has **Layers** and **Collides** ([Layers](#layers-who-collides-with-whom)). Then, by
kind:

| Setting | Bodies | What it does |
|---|---|---|
| **Friction** | Static, Dynamic, Mover | How much the surface grips: 0 is ice, 0.6 (the default) is typical, 1 is rubber |
| **Bounce** | Static, Dynamic, Mover | 0 doesn't bounce, 1 bounces back as high as it fell |
| **Material** | Static, Dynamic, Mover | A shared physics material that replaces Friction, Bounce and Density ([Physics materials](collision_and_materials.md#physics-materials)) |
| **Density** | Dynamic | How heavy it is for its size (kg for each 100 x 100 pixels); heavier bodies push lighter ones |
| **Gravity** | Dynamic | Multiplies the world's gravity: 1 normal, 0 floats, 0.5 drifts down slowly, -1 falls up |
| **Damping** | Dynamic | Slows its movement down over time, like air or water (0: none) |
| **Spin damp** | Dynamic | Slows its spinning down over time |
| **No rotation** | Dynamic | It never turns over (characters, crates that should stay upright) |
| **Bullet** | Dynamic | Extra-careful collision for small, fast things, so they don't pass through other moving bodies |
| **Floor angle** | Mover | The steepest slope, in degrees, that counts as floor (45 by default); steeper is a wall |

## Layers: who collides with whom

Not everything should collide with everything: the player's bullets shouldn't hit the player,
enemies may walk through each other, a coin should only notice the player. **Layers** sort
bodies into groups, numbered 1 to 16 in the inspector:

- **Layers**: the layers this body is on. Every body starts on layer 1.
- **Collides**: the layers it collides with. Every body starts colliding with all of them.

Click a number to turn it on or off. Two bodies collide only when each one's **Collides**
includes a layer the other is on. An **Area** notices the bodies on the layers in its
**Collides**.

An example plan:

| Layer | Who's on it | Collides with |
|---|---|---|
| 1 | The level (walls, floors) | 2, 3, 4 |
| 2 | The player | 1, 3, 5 |
| 3 | Enemies | 1, 2 |
| 4 | The player's bullets | 1, 3 |
| 5 | Pickups (Areas) | 2 |

Write your plan down somewhere (a comment in a script, the project's README): the numbers mean
whatever you decide. Code can use layers up to 64.

## Gravity and pixels per meter

**File > Project Settings... > General** has the physics settings for the whole game:

| Setting | What it does |
|---|---|
| **Pixels per meter** | How many pixels make one meter in the physics (100 by default). Box2D works best with things from 0.1 to 10 meters, so at 100 a 50 px crate is half a meter. Change it if your game's things are much bigger or smaller than that |
| **Gravity** | Pixels per second², x and y; y points down. 980 is Earth's gravity at 100 pixels per meter. A space game sets it to 0, 0 |
| **Show shapes** | Draws collision shapes over the game while you develop ([Seeing the shapes](#seeing-the-shapes)) |
| **Smooth motion** | Physics steps 60 times a second whatever the frame rate; this draws moving bodies between steps, so they glide on fast screens (they're drawn up to one step behind) |

A scene can have its own gravity (an underwater level, the moon): select the scene in the
browser and tick **Own gravity** in its settings under the browser, then set x and y.

## Seeing the shapes

In the editor, the viewport always outlines shapes (Shift+C hides them).

In the game, collision shapes are invisible. While you develop, it helps to see them:

- Tick **Show shapes** in Project Settings, or **Scene > Show Collision Shapes in Game**.
- Or, while a game started with Play runs, press **F9** to show and hide them. (**F10** shows
  the engine's debug overlay: frame rate and counts.)

Each body's shapes are drawn in a color for its kind: static green, dynamic blue (grey-blue while
asleep), movers orange, Areas purple, with joints and rays. Exported games never draw them and F9
does nothing there.

## One-way platforms

A **one-way platform** stops what lands on it from above, and lets things pass through from
below and from the sides: the floating ledges of a platformer that you jump up through.

1. Select the platform's CollisionShape.
2. Tick **One way**.

It works for DynamicBodies and CharacterMovers. To let a character drop down through one, set its
`dropThrough` while the player holds down ([A platformer character](#a-platformer-character)).

## Collision events

When bodies touch, the physics tells their nodes. There are two ways to react.

**From the inspector:** select the body, open the **Events** section of the inspector (Show),
and press **Listen...** beside an event. Pick the node whose script should react; the editor
writes the handler into that script.

**In the body's own script**, with the collision procedures:

```odin
Coin :: struct {
	using script: e.Script,
	pickup: e.SoundAsset `export:""`,
}

@(init)
register_Coin :: proc "contextless" () {
	e.Script_Register(Coin, {
		// On an Area: a body came inside it
		collisionEnter = proc(self: ^Coin, hit: ^e.Collision) {
			if !e.Node_Is(hit.other, e.CharacterMover) do return
			e.Game_PlaySound(self.game, self.pickup)
			e.Scene_RemoveNode(self.scene, self.node.id)
		},
	})
}
```

| Event | Script procedure | When |
|---|---|---|
| **onCollisionEnter** | `collisionEnter` | Another body started touching this one (for an Area: a body came in) |
| **onCollisionExit** | `collisionExit` | They stopped touching (for an Area: the body went out) |
| **onAreaEnter** | `areaEnter` | This body went into an Area (`hit.other` is the Area) |
| **onAreaExit** | `areaExit` | This body left an Area |
| **onLanded**, **onLeftFloor**, **onWallHit**, **onCeilingHit** | | A CharacterMover landed, left the floor (jumped, fell or walked off an edge), ran into a wall, hit a ceiling |
| **onHitEnter**, **onHitExit** | | A RayCast started or stopped hitting a body |

Events come once per pair of bodies: a body with three shapes touching the ground with two of
them still sends one enter, and one exit when the last one lets go.

What a collision tells you (`hit` above, a `^e.Collision`):

| Field | What it is |
|---|---|
| `hit.body` | The body the event is for |
| `hit.other` | What it touched (for an Area: the body that came in or went out) |
| `hit.shape`, `hit.otherShape` | Which of their CollisionShapes touched |
| `hit.point` | Where they touch, in world pixels (zero for exits, Areas and movers' contacts) |
| `hit.normal` | The direction from `body` toward `other` there |

The collision is only valid during the call: copy what you need.

## A platformer character

A **CharacterMover** is a body your code moves. You set its `velocity` and call
`e.CharacterMover_Move` every frame; it moves that far, slides along walls and floors instead of
going into them, and removes the part of the velocity that ran into something (landing stops the
fall, a wall stops the run).

1. **Add Node > CharacterMover**, named Hero.
2. Under it, a **Sprite** (or AnimatedSprite), and a **CollisionShape** with Shape **Capsule**
   (or Circle): that's what a mover moves as.
3. Give Hero a script (the inspector's **New...** under Script), like this one:

```odin
Hero :: struct {
	using script: e.Script,
	speed: f32 `export:"default=200 min=0"`,
	jumpSpeed: f32 `export:"default=450 min=0"`,
	gravity: f32 `export:"default=980 min=0"`,
}

@(init)
register_Hero :: proc "contextless" () {
	e.Script_Register(Hero, {
		update = proc(self: ^Hero, events: []sdl.Event, dt: f64) {
			mover := cast(^e.CharacterMover)self.node
			// Left and right
			mover.velocity.x = e.Input_GetAxis("ui_left", "ui_right") * self.speed
			// Jump, only from the floor
			if mover.onFloor && e.Input_IsActionJustPressed("ui_accept") {
				mover.velocity.y = -self.jumpSpeed
			}
			// Gravity is yours to add
			mover.velocity.y += self.gravity * f32(dt)
			// Hold down to fall through one-way platforms
			mover.dropThrough = e.Input_IsActionPressed("ui_down")
			e.CharacterMover_Move(mover, dt)
		},
	})
}
```

A mover doesn't fall by itself: the project's gravity moves DynamicBodies only, so your code
adds gravity to the velocity (and a top-down game simply doesn't).

After each move, the mover tells you where it ended up:

| Field | What it says |
|---|---|
| `onFloor` | It stands on a floor (a surface no steeper than its **Floor angle**) |
| `onWall` | It touches a wall |
| `onCeiling` | It touches a ceiling |
| `floorNormal` | The floor's direction, pointing up away from it, while `onFloor` (for walking on slopes) |
| `velocity` | What's left of its velocity after the move |
| `dropThrough` | Set it to fall through one-way platforms |

The demo project's forest level has a complete hero (`scripts/hero.odin`): running, jumping with
a little forgiveness for late presses, short hops, attacks.

## RayCast nodes

A **RayCast** is an invisible line from its node to a **Target** that reports the first body in
its way, after every physics step. Put one under an enemy to see whether the player is in front
of it, or under a character's feet to check for ground ahead.

| Setting | What it does |
|---|---|
| **Target X**, **Target Y** | Where the ray ends, relative to the node (0, 50: 50 px down) |
| **Hits** | The layers it hits |
| **Enabled** | It casts after every physics step |
| **Skip own body** | It ignores the body it's under (a character's own body) |

The viewport draws the ray. In a script, read `colliding`, `point`, `normal` and `collider` (the
body hit), or listen to its **onHitEnter** and **onHitExit** events. `e.RayCast_ForceUpdate(ray)`
casts it at once (after moving it, to see the result before the next step).

## Asking the physics from code

Scripts can ask questions at any moment, without nodes:

```odin
ex_queries :: proc(self: ^Hero, ENEMY_LAYER: u64, hurt: proc(body: ^e.PhysicsBody)) {
	mover := cast(^e.CharacterMover)self.node
	feet := e.Node_GetWorldPosition(mover)

	// Is there ground within 40 px below?
	ground := e.Physics_RayCast(self.scene, feet, feet + {0, 40}, exclude = mover)
	if ground.hit do log.infof("ground at %v, under %s", ground.point, ground.body.name)

	// Everything on the enemy layer within 48 px: a sword swing
	for body in e.Physics_QueryCircle(self.scene, feet, 48, ENEMY_LAYER) do hurt(body)

	// What did the player click on?
	click := e.Scene_ScreenToWorld(self.scene, e.Input_GetMousePosition(self.game))
	for body in e.Physics_QueryPoint(self.scene, click) do log.infof("clicked %s", body.name)

	// How far right can a 12 px wide dash go?
	hit := e.Physics_ShapeCast(self.scene, 12, feet, feet + {200, 0}, exclude = mover)
	dashTo := feet + [2]f32{200, 0} * (hit.hit ? hit.fraction : 1)
	_ = dashTo
}
```

| Procedure | What it returns |
|---|---|
| `e.Physics_RayCast(scene, from, to, mask, exclude)` | The first body a line hits (`hit`, `point`, `normal`, `body`, `shape`, `fraction`); Areas are ignored |
| `e.Physics_ShapeCast(scene, radius, from, to, mask, exclude)` | The same for a circle moving along the line: a thick ray |
| `e.Physics_QueryPoint(scene, point, mask)` | The bodies with a shape under a point |
| `e.Physics_QueryRect(scene, rect, mask)` | The bodies overlapping a rectangle (`{x, y, width, height}`, x and y its top-left corner) |
| `e.Physics_QueryCircle(scene, center, radius, mask)` | The bodies overlapping a circle |

Positions are world pixels. `mask` is the layers to find (`e.PhysicsLayers(3)`, every layer if
left out). The queries leave Areas out unless you pass `includeAreas = true`.

## Joints

A **Joint** connects two bodies at its position (its anchor): a door on a hinge, a rope, a
spring, a car's wheels.

1. **Add Node > Joint**. Put it under body A, or anywhere and choose **Body A**. With neither,
   body A is the world itself: the joint pins body B to that spot.
2. Choose **Body B**: the body it connects. The list holds the scene's bodies, by name (renaming
   a body updates the joints that name it).
3. Choose its **Kind**, and place it where the bodies meet.

| Kind | What it does |
|---|---|
| **Revolute** | A hinge or pin at the joint: body B turns around it (doors, pendulums, wheels on an axle) |
| **Distance** | Keeps the joint and the **Offset** point (on body B) apart: a rod; with **Limit**, a rope; with **Spring**, a spring |
| **Prismatic** | Body B slides along the joint's X axis without turning (rotate the joint to aim it): elevators, pistons |
| **Weld** | Glues the bodies together; a spring makes it bend |
| **Wheel** | Body B slides along the joint's X axis on a spring and spins freely: a car wheel's suspension |

| Setting | What it does |
|---|---|
| **Offset X**, **Offset Y** | Distance joints: the far end, relative to the joint |
| **Limit**, **Lower**, **Upper** | Keeps it between two values: degrees for Revolute, pixels for the others |
| **Motor**, **Speed**, **Strength** | Drives it: degrees per second for Revolute and Wheel, pixels per second for the others, up to that strength |
| **Spring**, **Stiffness Hz**, **Damping** | A spring: stiffness in bounces per second, damping 0 (bounces forever) to 1 (no bounce) |
| **Bodies collide** | Whether the two bodies still collide with each other |

The joint is made when the game starts, from where the bodies are then. The viewport draws its
anchor, red while it has no body B, with lines to its bodies. Removing either body removes the
joint.

## In scripts

| Code | What it does |
|---|---|
| `e.CharacterMover_Move(mover, dt)` | Moves a mover by its `velocity` ([A platformer character](#a-platformer-character)) |
| `e.DynamicBody_SetVelocity(body, v)`, `e.DynamicBody_GetVelocity(body)` | A dynamic body's speed, pixels per second |
| `e.DynamicBody_ApplyImpulse(body, impulse)` | An instant push: `e.DynamicBody_GetMass(body) * [2]f32{0, -400}` changes its speed by 400 px/s upward whatever it weighs |
| `e.DynamicBody_ApplyForce(body, force)` | A push during the next step (call it every frame for a steady force) |
| `e.DynamicBody_SetAngularVelocity(body, degreesPerSecond)` | Its spin |
| `e.PhysicsBody_SetLayers(body, e.PhysicsLayers(2), e.PhysicsLayers(1, 3))` | Changes its layers and what it collides with |
| `e.PhysicsBody_IsTouching(body, other)`, `e.PhysicsBody_GetContacts(body)` | What it touches right now |
| `e.PhysicsBody_IsInArea(body, area)`, `e.PhysicsBody_GetAreas(body)`, `e.Area_GetOverlaps(area)` | Which Areas a body is in; which bodies an Area holds |
| `e.PhysicsBody_RebuildShapes(body)` | After changing a shape's size, points or **One way** in code |
| `e.Joint_SetMotorSpeed(joint, speed)` | Drives a joint's motor (turning it on) |
| `e.Joint_GetAngle(joint)`, `e.Joint_GetTranslation(joint)`, `e.Joint_GetForce(joint)` | How far it turned or slid, how hard it pulls |
| `e.Physics_SetGravity(scene, {0, 490})` | Changes a scene's gravity while it runs |
| `e.Physics_SetDebugDraw(game, true)` | Shows the collision shapes in a running game |

A rope that snaps when pulled too hard:

```odin
if linalg.length(e.Joint_GetForce(rope)) > 50000 do e.Scene_RemoveNode(scene, rope.id)
```

Move a static body by setting its node's `position`; dynamic bodies are moved by the physics,
so push them with velocities and impulses instead (setting a dynamic body's position makes it
jump there).

## How it's stored

Bodies, shapes and joints are nodes in the scene file, with only the settings that aren't the
defaults:

```xml
<node kind="StaticBody" name="Ground" x="400" y="560">
	<node kind="CollisionShape" name="CollisionShape" shape="Rectangle" width="600" height="40"/>
	<node kind="CollisionShape" name="Ledge" y="-120" shape="Segment" points="-60,0 60,0" oneWay="true"/>
</node>
<node kind="DynamicBody" name="Crate" x="400" y="100" collisionLayer="3" collisionMask="1 3" restitution="0.3">
	<node kind="CollisionShape" name="CollisionShape" shape="Rectangle" width="48" height="48"/>
</node>
```

The project's settings are on project.xml's root (`pixelsPerMeter`, `gravityX`, `gravityY`,
`physicsDebug`, `physicsSmoothing`), written only when changed.

## Questions

**My body falls through the floor.** Check that both have a CollisionShape under them, that the
shapes aren't Disabled, and their layers: each one's **Collides** must include a layer the other
is on. A very fast small body may need **Bullet**.

**My character doesn't fall.** CharacterMovers don't use the project's gravity: add it to the
velocity in the script, and call `e.CharacterMover_Move` every frame.

**My character doesn't move at all.** Its shape must be a Capsule or Circle (the inspector warns
otherwise), and the script must call `e.CharacterMover_Move`.

**My coin doesn't notice the player.** The coin's an Area: its **Collides** must include the
player's layer, and the coin needs a CollisionShape. Use `collisionEnter` (an Area's "a body came
in"), not `areaEnter` (that's for the body going into an Area).

**Things are floaty or too heavy.** Look at **Pixels per meter**: with very big sprites at 100 px
per meter, your crates are many meters tall and fall slowly to the eye. Raise it, or raise
**Gravity**.

**Do bodies move in the editor?** No: the viewport keeps physics paused, so nothing falls while
you build the level. Press Play to see it.
