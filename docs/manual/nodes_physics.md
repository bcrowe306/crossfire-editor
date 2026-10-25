---
title: "Node guides: physics"
description: How to use the physics nodes, StaticBody, DynamicBody, CharacterMover, Area, CollisionShape, RayCast and Joint, in the editor and from scripts.
order: 48
---

# Node guides: physics

The physics nodes make things in your game solid: walls and floors, crates that fall, characters
that slide along the ground, triggers that notice the player, rays that look for walls, and
joints that hinge or tie bodies together. Each section below is one node kind's guide: what it
does, its properties, how to set it up in the editor, how scripts use it, an example and its API.
The [Node guides](nodes.md) page lists every kind; [Physics](physics.md) and
[Collision from sprites and physics materials](collision_and_materials.md) explain the feature in
depth.

- [StaticBody](#staticbody)
- [DynamicBody](#dynamicbody)
- [CharacterMover](#charactermover)
- [Area](#area)
- [CollisionShape](#collisionshape)
- [RayCast](#raycast)
- [Joint](#joint)
- [Questions](#questions)

## StaticBody

A StaticBody is a physics body that doesn't move by itself: walls, floors, platforms, rocks.
Other bodies collide with it and stop. When your code moves its node, the body jumps to the new
place, so a lift or a moving platform can be a StaticBody whose script changes its position. In
code it's an `e.StaticBody`.

**Properties**

| Property | What it does |
|---|---|
| **Layers** | The collision layers (1 to 16) the body is on; it starts on layer 1 |
| **Collides** | The layers it collides with; it starts with all of them |
| **Friction** | How much the surface grips: 0 is ice, 0.6 the default, 1 rubber |
| **Bounce** | 0 doesn't bounce, 1 sends things back as high as they fell |
| **Material** | A shared physics material that replaces Friction and Bounce (**New Material** makes one) |
| **Collision from sprite** | **Sprite**, **Alpha threshold**, **Detail** and **Make Shapes**: traces a sprite under the body into polygon shapes |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **StaticBody**, and name it (Ground, Wall, Lift).
2. Under it, add a **CollisionShape** (its shape) and, if it should be seen, a **Sprite**. The
   inspector warns while the body has no shape.
3. Set its **Layers** and **Collides** if your game uses a layer plan.
4. Press **Play** (F5): dynamic bodies and characters stop on it. Press F9 in the game to see its
   shapes, outlined in green.

**From code**

Give a script on the body a node field, or cast `self.node` when the script is on the body
itself. Move it by setting its node's `position`. `e.PhysicsBody_SetLayers` changes its layers,
`e.PhysicsBody_IsTouching` and `e.PhysicsBody_GetContacts` say what touches it, and its
`collisionEnter` / `collisionExit` hooks (or the **onCollisionEnter** and **onCollisionExit**
events) report bodies touching it. `e.CreateStaticBody` makes one in code.

**Example**

A lift: put this script on a StaticBody with a CollisionShape, and it rides up and down.

```odin
Lift :: struct {
	using script: e.Script,
	// How far up it rides, in pixels
	travel: f32 `export:"default=120 min=0"`,
	// Seconds for a trip up and down
	period: f32 `export:"default=4 min=0.5"`,
	start: [2]f32,
	time: f32,
}

Lift_ready :: proc(self: ^Lift) {
	self.start = self.node.position
}

Lift_update :: proc(self: ^Lift, events: []sdl.Event, dt: f64) {
	self.time += f32(dt)
	// 0 at the bottom, 1 at the top, smoothly
	up := (1 - math.cos(self.time / self.period * 2 * math.PI)) / 2
	self.node.position = self.start - {0, self.travel * up}
}

@(init)
register_Lift :: proc "contextless" () {
	e.Script_Register(Lift, {ready = Lift_ready, update = Lift_update})
}
```

**API**: [e.StaticBody](https://crossfireengine.io/api/physics/#staticbody),
[e.PhysicsBody](https://crossfireengine.io/api/physics/#physicsbody),
[e.CreateStaticBody](https://crossfireengine.io/api/physics/#createstaticbody),
[e.PhysicsBody_SetLayers](https://crossfireengine.io/api/physics/#physicsbody_setlayers),
[e.PhysicsBody_GetContacts](https://crossfireengine.io/api/physics/#physicsbody_getcontacts)

More: [Physics](physics.md#the-body-kinds)

## DynamicBody

A DynamicBody is moved by the physics: gravity pulls it, collisions stop it and turn it, forces
and impulses push it, and its node follows it. Use it for crates, balls, debris, barrels and
ragdoll parts. In code it's an `e.DynamicBody`.

**Properties**

| Property | What it does |
|---|---|
| **Layers**, **Collides** | Its collision layers and the layers it collides with |
| **Friction**, **Bounce** | Its surface, as on a StaticBody |
| **Material** | A shared physics material that replaces Friction, Bounce and Density |
| **Density** | How heavy it is for its size (kg for each 100 x 100 pixels); heavier bodies push lighter ones |
| **Gravity** | Multiplies the world's gravity: 1 normal, 0 floats, -1 falls up |
| **Damping**, **Spin damp** | Slow its movement and its spinning down over time, like air or water |
| **No rotation** | It never turns over |
| **Bullet** | Extra-careful collision for small, fast things so they don't pass through other moving bodies |
| **Collision from sprite** | Makes polygon shapes from a sprite under the body |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **DynamicBody**, named Crate or Ball, above something solid
   (a StaticBody).
2. Under it, add a **Sprite** and a **CollisionShape** the size of the picture (or use
   **Collision from sprite** > **Make Shapes**).
3. Set **Density**, **Bounce** and **Gravity** to taste; tick **No rotation** for things that
   should stay upright.
4. Press **Play** (F5): it falls. Nothing falls in the editor's viewport, which keeps physics
   paused.

**From code**

Cast the node (`cast(^e.DynamicBody)self.node`) or use a node field like
`body: ^e.DynamicBody`. Don't set its position to move it: push it.
`e.DynamicBody_SetVelocity` and `e.DynamicBody_GetVelocity` are its speed in pixels per second,
`e.DynamicBody_ApplyImpulse` an instant push (multiply by `e.DynamicBody_GetMass` for a change of
speed whatever it weighs), `e.DynamicBody_ApplyForce` a push for the next step, and
`e.DynamicBody_SetAngularVelocity` its spin in degrees per second. Its `collisionEnter` hook
tells you what it hit.

**Example**

A ball that hops when the player presses the jump key while it rests on something, and plays a
sound when it hits hard.

```odin
Ball :: struct {
	using script: e.Script,
	hopSpeed: f32 `export:"default=500 min=0"`,
	bonk: e.SoundAsset `export:""`,
}

Ball_update :: proc(self: ^Ball, events: []sdl.Event, dt: f64) {
	body := cast(^e.DynamicBody)self.node
	if e.Input_IsActionJustPressed("ui_accept") && len(e.PhysicsBody_GetContacts(body)) > 0 {
		// The same change of speed however heavy the ball is
		e.DynamicBody_ApplyImpulse(body, e.DynamicBody_GetMass(body) * [2]f32{0, -self.hopSpeed})
	}
}

Ball_collisionEnter :: proc(self: ^Ball, hit: ^e.Collision) {
	body := cast(^e.DynamicBody)self.node
	if linalg.length(e.DynamicBody_GetVelocity(body)) > 300 do e.Game_PlaySound(self.game, self.bonk)
}

@(init)
register_Ball :: proc "contextless" () {
	e.Script_Register(Ball, {update = Ball_update, collisionEnter = Ball_collisionEnter})
}
```

**API**: [e.DynamicBody](https://crossfireengine.io/api/physics/#dynamicbody),
[e.DynamicBody_SetVelocity](https://crossfireengine.io/api/physics/#dynamicbody_setvelocity),
[e.DynamicBody_ApplyImpulse](https://crossfireengine.io/api/physics/#dynamicbody_applyimpulse),
[e.DynamicBody_ApplyForce](https://crossfireengine.io/api/physics/#dynamicbody_applyforce),
[e.DynamicBody_GetMass](https://crossfireengine.io/api/physics/#dynamicbody_getmass),
[e.CreateDynamicBody](https://crossfireengine.io/api/physics/#createdynamicbody)

More: [Physics](physics.md#body-settings)

## CharacterMover

A CharacterMover is a body your code moves: players and enemies in platformers and top-down
games. You set its `velocity` and call `e.CharacterMover_Move` every frame; it slides along walls
and floors instead of going through them, and pushes dynamic bodies out of its way. Gravity
doesn't move it: a platformer's script adds gravity to the velocity. In code it's an
`e.CharacterMover`.

**Properties**

| Property | What it does |
|---|---|
| **Layers**, **Collides** | Its collision layers and the layers it collides with |
| **Friction**, **Bounce**, **Material** | Its surface, as on the other bodies |
| **Floor angle** | The steepest slope, in degrees, that counts as floor (45 by default); steeper is a wall |
| **Collision from sprite** | Makes shapes from a sprite (a mover only moves as a Capsule or Circle, though) |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **CharacterMover**, named Hero.
2. Under it, add a **Sprite** or **AnimatedSprite**, and a **CollisionShape** with **Shape**
   Capsule or Circle: that's what the mover moves as. The inspector warns without one.
3. Give it a script (**New...** under Script) that sets the velocity and moves it.
4. Press **Play** (F5) and walk into walls and up slopes. Its shapes show in orange with F9.

**From code**

A script on the mover casts `self.node` to `^e.CharacterMover`. Set `velocity` (pixels per
second) and call `e.CharacterMover_Move(mover, dt)`; afterwards `onFloor`, `onWall`, `onCeiling`
and `floorNormal` say where it ended up, and `velocity` keeps what wasn't stopped. Set
`dropThrough` to fall through one-way platforms. Its events **onLanded**, **onLeftFloor**,
**onWallHit** and **onCeilingHit** fire when those change.

**Example**

A top-down walker (no gravity) that moves with the arrow keys or a gamepad stick.

```odin
Walker :: struct {
	using script: e.Script,
	speed: f32 `export:"default=160 min=0"`,
}

Walker_update :: proc(self: ^Walker, events: []sdl.Event, dt: f64) {
	mover := cast(^e.CharacterMover)self.node
	mover.velocity = e.Input_GetVector("ui_left", "ui_right", "ui_up", "ui_down") * self.speed
	e.CharacterMover_Move(mover, dt)
	if mover.onWall do log.debugf("%s is against a wall", self.node.name)
}

@(init)
register_Walker :: proc "contextless" () {
	e.Script_Register(Walker, {update = Walker_update})
}
```

**API**: [e.CharacterMover](https://crossfireengine.io/api/physics/#charactermover),
[e.CharacterMover_Move](https://crossfireengine.io/api/physics/#charactermover_move),
[e.CreateCharacterMover](https://crossfireengine.io/api/physics/#createcharactermover)

More: [Physics](physics.md#a-platformer-character)

## Area

An Area is a region that notices bodies coming in and going out, and stops nothing: coins,
pickups, checkpoints, water, damage zones, a door that opens when you're near. It notices the
bodies on the layers in its **Collides**. In code it's an `e.Area`.

**Properties**

| Property | What it does |
|---|---|
| **Layers** | The layers the Area is on (what other bodies' Collides must include for them to see it in `areaEnter`) |
| **Collides** | The layers of the bodies it notices |
| **Collision from sprite** | Makes the region's shapes from a sprite under it |

An Area has no Friction, Bounce or Material: nothing touches it.

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **Area**, named Coin or Water.
2. Under it, add a **CollisionShape** for the region, and a **Sprite** if it should be seen.
3. Set **Collides** to the player's layer (or whatever it should notice).
4. React to it: in the inspector's **Events** section (Show), **Listen...** beside
   **onCollisionEnter**, or give the Area a script with a `collisionEnter` hook.
5. Press **Play** (F5) and walk in. With F9 its shapes show in purple.

**From code**

On the Area itself, `collisionEnter` and `collisionExit` mean "a body came in" and "went out",
with the body in `hit.other`. On the body that walks in, `areaEnter` and `areaExit` fire instead,
with the Area in `hit.other`. `e.Area_GetOverlaps(area)` lists the bodies inside right now, and
`e.PhysicsBody_IsInArea` and `e.PhysicsBody_GetAreas` ask from the body's side.

**Example**

Water that pushes floating things up while they're inside it.

```odin
Water :: struct {
	using script: e.Script,
	// Upward push, in pixels per second squared
	lift: f32 `export:"default=1400 min=0"`,
}

Water_update :: proc(self: ^Water, events: []sdl.Event, dt: f64) {
	area := cast(^e.Area)self.node
	for body in e.Area_GetOverlaps(area) {
		if !e.Node_Is(body, e.DynamicBody) do continue
		crate := cast(^e.DynamicBody)body
		e.DynamicBody_ApplyForce(crate, e.DynamicBody_GetMass(crate) * [2]f32{0, -self.lift})
	}
}

Water_collisionEnter :: proc(self: ^Water, hit: ^e.Collision) {
	log.infof("%s splashed into %s", hit.other.name, self.node.name)
}

@(init)
register_Water :: proc "contextless" () {
	e.Script_Register(Water, {update = Water_update, collisionEnter = Water_collisionEnter})
}
```

**API**: [e.Area](https://crossfireengine.io/api/physics/#area),
[e.Area_GetOverlaps](https://crossfireengine.io/api/physics/#area_getoverlaps),
[e.PhysicsBody_IsInArea](https://crossfireengine.io/api/physics/#physicsbody_isinarea),
[e.PhysicsBody_GetAreas](https://crossfireengine.io/api/physics/#physicsbody_getareas),
[e.Collision](https://crossfireengine.io/api/physics/#collision),
[e.CreateArea](https://crossfireengine.io/api/physics/#createarea)

More: [Physics](physics.md#collision-events)

## CollisionShape

A CollisionShape gives the body above it its shape: a rectangle, circle, capsule, polygon or
line. It belongs to its nearest body ancestor, so it can sit inside a helper Node2D under the
body, and it moves, turns and scales with its node (rotate a rectangle to make a slope). A body
can have several. In code it's an `e.CollisionShape`.

**Properties**

| Property | What it does |
|---|---|
| **Shape** | Rectangle, Circle, Capsule, Polygon or Segment |
| **Width**, **Height** | A Rectangle's size, centered on the node; a Capsule's **Height** includes its round ends |
| **Radius** | A Circle's or Capsule's radius |
| **Points** | A Polygon's `x,y` pairs separated by spaces (3 to 8, made convex), or a Segment's two points |
| **Disabled** | Leaves the shape out of its body |
| **One way** | A one-way platform: only its top stops what lands on it |
| **Slice** | With a Sprite showing an Aseprite file nearby: takes that slice's rectangle frame by frame (a hitbox) |

**In the editor**

1. Select a body and **Add Node** (Ctrl+Shift+A) > **CollisionShape**: it becomes the body's
   child. The inspector warns about a shape with no body above it.
2. Pick its **Shape** and set its size; move and rotate it in the viewport like any node.
3. The viewport outlines it in its body's color; **Shift+C** hides and shows the outlines.
4. Press **Play** (F5), and F9 in the game to see the shapes the physics uses.

**From code**

Reach it with a node field (`shape: ^e.CollisionShape \`export:"default=CollisionShape"\``).
Its fields are `shape`, `size`, `radius`, `height`, `points`, `disabled` and `oneWay`. After
changing any of them, call `e.PhysicsBody_RebuildShapes` on its body
(`e.CollisionShape_GetBody(shape)` finds it), or the physics keeps the old shape.

**Example**

A balloon that grows while the player holds the jump key: put it on a DynamicBody with a Circle
CollisionShape and a Sprite.

```odin
Balloon :: struct {
	using script: e.Script,
	shape: ^e.CollisionShape `export:"default=CollisionShape"`,
	picture: ^e.Sprite `export:"default=Sprite"`,
	// Pixels of radius per second
	growth: f32 `export:"default=8 min=0"`,
	maxRadius: f32 `export:"default=64 min=1"`,
}

Balloon_update :: proc(self: ^Balloon, events: []sdl.Event, dt: f64) {
	if self.shape == nil || !e.Input_IsActionPressed("ui_accept") do return
	if self.shape.radius >= self.maxRadius do return
	grown := min(self.shape.radius + self.growth * f32(dt), self.maxRadius)
	// The picture grows by the same factor as the shape
	if self.picture != nil do self.picture.scale *= grown / self.shape.radius
	self.shape.radius = grown
	if body := e.CollisionShape_GetBody(self.shape); body != nil do e.PhysicsBody_RebuildShapes(body)
}

@(init)
register_Balloon :: proc "contextless" () {
	e.Script_Register(Balloon, {update = Balloon_update})
}
```

**API**: [e.CollisionShape](https://crossfireengine.io/api/physics/#collisionshape),
[e.CollisionShapeKind](https://crossfireengine.io/api/physics/#collisionshapekind),
[e.CollisionShape_GetBody](https://crossfireengine.io/api/physics/#collisionshape_getbody),
[e.PhysicsBody_RebuildShapes](https://crossfireengine.io/api/physics/#physicsbody_rebuildshapes),
[e.CreateCollisionShape](https://crossfireengine.io/api/physics/#createcollisionshape)

More: [Physics](physics.md#collision-shapes)

## RayCast

A RayCast is an invisible line from its node to a target that reports the first body in its way,
after every physics step: is the player in front of the enemy, is there ground ahead, is there a
wall to the right. In code it's an `e.RayCast`.

**Properties**

| Property | What it does |
|---|---|
| **Target X**, **Target Y** | Where the ray ends, relative to the node (0, 50 is 50 pixels down) |
| **Hits** | The layers it hits |
| **Enabled** | It casts after every physics step |
| **Skip own body** | It ignores the body it's under (a character's own body) |

**In the editor**

1. Select the character (or any node) and **Add Node** (Ctrl+Shift+A) > **RayCast**: it casts
   from that spot.
2. Set **Target X** and **Target Y**; the viewport draws the ray.
3. Set **Hits** to the layers it should see, and keep **Skip own body** on under a body.
4. Press **Play** (F5); with F9 the game draws the ray too.

**From code**

Use a node field (`ray: ^e.RayCast \`export:"default=RayCast"\``) and read `colliding`, `point`,
`normal` and `collider` (the body it hit, `nil` when nothing). Change `target` to aim it, and
call `e.RayCast_ForceUpdate(ray)` to cast at once instead of waiting for the next step. The
**onHitEnter** and **onHitExit** events fire when it starts and stops hitting a body. For a
one-off question without a node, `e.Physics_RayCast` casts a line from code.

**Example**

An enemy that walks back and forth on a ledge and turns around at the edge. It's a
CharacterMover with a Capsule shape and a RayCast named LedgeRay at (0, 0), its target ahead of
and below its feet (20, 50).

```odin
Patroller :: struct {
	using script: e.Script,
	ledgeRay: ^e.RayCast `export:"default=LedgeRay"`,
	speed: f32 `export:"default=60 min=0"`,
	gravity: f32 `export:"default=980 min=0"`,
	direction: f32,
}

Patroller_ready :: proc(self: ^Patroller) {
	self.direction = 1
}

Patroller_update :: proc(self: ^Patroller, events: []sdl.Event, dt: f64) {
	mover := cast(^e.CharacterMover)self.node
	// No ground ahead, or a wall: turn around and aim the ray the other way
	if self.ledgeRay != nil && mover.onFloor && (!self.ledgeRay.colliding || mover.onWall) {
		self.direction = -self.direction
		self.ledgeRay.target.x = abs(self.ledgeRay.target.x) * self.direction
		e.RayCast_ForceUpdate(self.ledgeRay)
	}
	mover.velocity.x = self.speed * self.direction
	mover.velocity.y += self.gravity * f32(dt)
	e.CharacterMover_Move(mover, dt)
}

@(init)
register_Patroller :: proc "contextless" () {
	e.Script_Register(Patroller, {ready = Patroller_ready, update = Patroller_update})
}
```

**API**: [e.RayCast](https://crossfireengine.io/api/physics/#raycast),
[e.RayCast_ForceUpdate](https://crossfireengine.io/api/physics/#raycast_forceupdate),
[e.CreateRayCast](https://crossfireengine.io/api/physics/#createraycast),
[e.Physics_RayCast](https://crossfireengine.io/api/physics/#physics_raycast)

More: [Physics](physics.md#raycast-nodes)

## Joint

A Joint connects two bodies at its position (its anchor): a door on a hinge, a rope, a spring, a
sliding elevator, two bodies welded together, a car's wheels. Body A is the body it's under (or
the one you choose), or the world itself; body B is the body it connects. In code it's an
`e.Joint`.

**Properties**

| Property | What it does |
|---|---|
| **Kind** | Revolute (a hinge), Distance (a rod, rope or spring), Prismatic (a slider), Weld (glue) or Wheel (a suspension) |
| **Body A** | The first body: "(body above, or the world)" by default, or a body of the scene |
| **Body B** | The body it connects (required: the anchor is drawn red without one) |
| **Offset X**, **Offset Y** | Distance joints: the far end, on body B, relative to the joint |
| **Limit**, **Lower**, **Upper** | Keeps it between two values: degrees for Revolute (the labels say °), pixels for the others (px) |
| **Motor**, **Speed**, **Strength** | Drives it at that speed (°/s or px/s), up to that torque or force; Weld joints have none |
| **Spring**, **Stiffness Hz**, **Damping** | A spring: bounces per second, and 0 (bounces forever) to 1 (no bounce) |
| **Bodies collide** | Whether the two bodies still collide with each other |

**In the editor**

1. Put the joint under body A: select it and **Add Node** (Ctrl+Shift+A) > **Joint**. Or add it
   anywhere and choose **Body A**; with neither, it pins body B to that spot in the world.
2. Choose **Body B** from the list of the scene's bodies, and its **Kind**.
3. Place it where the bodies meet (the hinge's pin, the rope's top); rotate it to aim a
   Prismatic or Wheel joint's slide.
4. Press **Play** (F5). The joint is made when the game starts, from where the bodies are then.

**From code**

Use a node field (`hinge: ^e.Joint \`export:"default=Hinge"\``). Most settings are read only
when the joint is made; after that, `e.Joint_SetMotorSpeed` drives its motor (turning it on).
`e.Joint_GetAngle` (Revolute), `e.Joint_GetTranslation` (Prismatic, Distance) and
`e.Joint_GetForce` say how far it turned or slid and how hard it pulls; `e.Joint_IsActive` says
whether it exists. Removing the joint's node (`e.Scene_RemoveNode`) breaks it.

**Example**

A drawbridge on a Revolute joint with **Motor** on: the player raises and lowers it, and the
chains snap if something too heavy pulls on it.

```odin
Drawbridge :: struct {
	using script: e.Script,
	hinge: ^e.Joint `export:"default=Hinge"`,
	// Degrees per second
	speed: f32 `export:"default=45 min=0"`,
	breakForce: f32 `export:"default=200000 min=0"`,
}

Drawbridge_update :: proc(self: ^Drawbridge, events: []sdl.Event, dt: f64) {
	if self.hinge == nil || !e.Joint_IsActive(self.hinge) do return
	e.Joint_SetMotorSpeed(self.hinge, e.Input_GetAxis("ui_up", "ui_down") * self.speed)
	if linalg.length(e.Joint_GetForce(self.hinge)) > self.breakForce {
		log.infof("the bridge broke at %.0f degrees", e.Joint_GetAngle(self.hinge))
		e.Scene_RemoveNode(self.scene, self.hinge.id)
		self.hinge = nil
	}
}

@(init)
register_Drawbridge :: proc "contextless" () {
	e.Script_Register(Drawbridge, {update = Drawbridge_update})
}
```

**API**: [e.Joint](https://crossfireengine.io/api/physics/#joint),
[e.JointKind](https://crossfireengine.io/api/physics/#jointkind),
[e.Joint_SetMotorSpeed](https://crossfireengine.io/api/physics/#joint_setmotorspeed),
[e.Joint_GetAngle](https://crossfireengine.io/api/physics/#joint_getangle),
[e.Joint_GetTranslation](https://crossfireengine.io/api/physics/#joint_gettranslation),
[e.Joint_GetForce](https://crossfireengine.io/api/physics/#joint_getforce),
[e.Joint_IsActive](https://crossfireengine.io/api/physics/#joint_isactive),
[e.CreateJoint](https://crossfireengine.io/api/physics/#createjoint)

More: [Physics](physics.md#joints)

## Questions

**My body has no effect on anything.** A body without a CollisionShape collides with nothing,
and a shape that isn't under a body does nothing; the inspector warns about both. Check also
that each body's **Collides** includes a layer the other is on.

**I changed a shape's size in my script and nothing happened.** The physics keeps the shapes it
built. Call `e.PhysicsBody_RebuildShapes` on the body after changing a shape's size, points,
**Disabled** or **One way**, or the body's friction, bounce or density.

**My Area's script hears nothing.** On the Area, use `collisionEnter` ("a body came in");
`areaEnter` is for the body that goes into an Area. The Area needs a shape, and its **Collides**
must include the body's layer.

**Setting a DynamicBody's position makes it jump.** Dynamic bodies are moved by the physics:
push them with `e.DynamicBody_SetVelocity` or `e.DynamicBody_ApplyImpulse`. Moving a StaticBody's
node is fine, that's how lifts work.

**Changing a joint's limits in a script does nothing.** A joint's settings are read when it's
made, at the start of the game; only `e.Joint_SetMotorSpeed` changes it afterwards. To change
the rest, remove the joint and make a new one with `e.CreateJoint`.

**My CharacterMover doesn't move or fall.** It needs a Capsule or Circle shape, a script that
calls `e.CharacterMover_Move` every frame, and, in a platformer, gravity added to its `velocity`
by that script.
