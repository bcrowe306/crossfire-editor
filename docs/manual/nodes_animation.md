---
title: "Node guides: animation"
description: "How to use the animation nodes: Animator, StateMachine, Skeleton2D, Bone2D, SkinnedMesh and IKChain."
order: 48
---

# Node guides: animation

These nodes make things move over time: keyframed clips, a character's states choosing its
animations, and skeletons of bones that bend pictures and reach for targets. Each section is one
node kind's guide: what it does, its properties, the inspector, code, an example and the API. The
[Node guides](nodes.md) page lists every kind; [Keyframe animation](animation.md),
[State machines](state_machines.md) and [Skeletal animation](skeletal_animation.md) go deeper.

- [Animator](#animator)
- [StateMachine](#statemachine)
- [Skeleton2D](#skeleton2d)
- [Bone2D](#bone2d)
- [SkinnedMesh](#skinnedmesh)
- [IKChain](#ikchain)
- [Questions](#questions)

## Animator

An Animator plays **clips** of keyframes that change other nodes' properties over time: a door
opening, a platform moving back and forth, a menu sliding in, a coin bobbing, a cutscene. A clip
has a length and **tracks**; each track animates one property of one node (position, rotation,
scale, tint, opacity, visible, Z index, an AnimatedSprite's animation, a Label's text, a script's
exported field) through **keys**. A track's node is a path from the Animator's *parent*, so put
the Animator inside what it animates. In code it's an `e.Animator`.

**Properties**

| Property | What it does |
|---|---|
| **First clip** | The clip it plays when the scene starts (None: it waits for a script) |
| **Clip speed** | How fast its clips play: 2 is twice as fast, 0 holds them |
| **Edit in the Timeline** | Opens the bottom panel's Timeline tab, where clips, tracks and keys are made |

**In the editor**

1. Select the node to animate (or its parent), then **Add Node** (Ctrl+Shift+A) > **Animator**.
2. Press **Edit in the Timeline**. Make a clip, select a node, change a property and press
   **Key** on it; move the playhead, change it again, Key again.
3. Pick the clip under **First clip** if it should start by itself; set **Clip speed** if needed.
4. For a moment that should run code (a footstep), add an event track and listen to the
   Animator's **onEvent** in the inspector's Events section.
5. Play (F5): in the editor Animators don't play by themselves, only the Timeline shows them.

**From code**

Give the script a node field `^e.Animator`. `e.Animator_Play(anim, "open")` plays a clip
(`restart = true` starts the playing one again), `e.Animator_Stop` stops it (`reset = true` puts
its first values back), `e.Animator_Pause` and `e.Animator_Seek` pause and jump,
`e.Animator_IsPlaying` and `e.Animator_CurrentClip` tell what it's doing, and `anim.speed` is the
Clip speed. Its events are `onFinished` (a clip that doesn't loop ended; data: its name) and
`onEvent` (an event key passed; data: the key's value). `e.Animator_SetClips` replaces its clips
with ones made in code.

**Example**

A chest that plays its "open" clip when the player presses the interact action, and says when the
clip has ended:

```odin
Chest :: struct {
	using script: e.Script,
	anim: ^e.Animator `export:"default=Anim"`,
	opened: bool,
}

Chest_onAnimFinished :: proc(_: ^e.EventSubject, source: rawptr, data: e.EventData, userData: rawptr) {
	self := cast(^Chest)userData
	if data.(string) == "open" do log.infof("%s is open", self.node.name)
}

Chest_ready :: proc(self: ^Chest) {
	if self.anim != nil do e.Event_Subscribe(&self.anim.onFinished, Chest_onAnimFinished, self)
}

Chest_update :: proc(self: ^Chest, events: []sdl.Event, dt: f64) {
	if self.anim == nil || self.opened do return
	if e.Input_IsActionJustPressed("interact", self.game) {
		e.Animator_Play(self.anim, "open")
		self.opened = true
	}
}

@(init)
register_Chest :: proc "contextless" () {
	e.Script_Register(Chest, {ready = Chest_ready, update = Chest_update})
}
```

**API**

[e.Animator](https://crossfireengine.io/api/animation/#animator),
[e.Animator_Play](https://crossfireengine.io/api/animation/#animator_play),
[e.Animator_Stop](https://crossfireengine.io/api/animation/#animator_stop),
[e.Animator_Pause](https://crossfireengine.io/api/animation/#animator_pause),
[e.Animator_Seek](https://crossfireengine.io/api/animation/#animator_seek),
[e.Animator_IsPlaying](https://crossfireengine.io/api/animation/#animator_isplaying),
[e.Animator_CurrentClip](https://crossfireengine.io/api/animation/#animator_currentclip),
[e.Animator_SetClips](https://crossfireengine.io/api/animation/#animator_setclips),
[e.CreateAnimator](https://crossfireengine.io/api/animation/#createanimator)

More: [Keyframe animation](animation.md#the-timeline-tab)

## StateMachine

A StateMachine keeps one of a set of **states** (idle, run, jump, attack) and moves between them
by **transitions** whose conditions read **parameters** your script sets (a speed, whether the
character is on the ground, a "jump" trigger) and **code guards** your scripts provide. Transitions
have priorities, exit times and guards; a state can refuse to be left (its exit guard) unless a
transition interrupts it. Each state can play an animation of an
AnimatedSprite, so the character's animation follows what it's doing without code choosing
animations. Use it for characters and enemies with a few clear modes. In code it's an
`e.StateMachine`.

**Properties**

| Property | What it does |
|---|---|
| **Starts in** | The state it starts in when the scene starts (shown once it has states) |
| **Animates** | The AnimatedSprite whose animations its states play ((its parent) by default) |
| **Edit in the States tab** | Opens the bottom panel's States tab: the graph of states, transitions and parameters, and a sidebar with the selected state's or transition's properties |

**In the editor**

1. Select the character's AnimatedSprite, then **Add Node** (Ctrl+Shift+A) > **StateMachine**: it
   goes inside the sprite, and its states play the sprite's animations.
2. Press **Edit in the States tab**. Add parameters (**+ Parameter**: Float, Bool or Trigger),
   states (**+ State**, each with the animation it **Plays**, its speed and loop, maybe a **Can
   exit when**) and transitions (**+ Transition to:**, with a **When** condition such as
   `speed > 10`, maybe a **Guard**, a **Priority** and an **Exit after**), in the sidebar.
3. Set **Starts in**. If the inspector says it animates no AnimatedSprite, choose one under
   **Animates**.
4. Feed the parameters from the character's script (below).
5. Play (F5): the States tab shows the machine's state as it changes, which clauses hold and what
   keeps a transition from being taken.

**From code**

Give the script a node field `^e.StateMachine`. Set parameters with `e.StateMachine_SetFloat`,
`e.StateMachine_SetBool` and `e.StateMachine_SetTrigger` (a trigger is cleared by the transition
that uses it). Read the state with `e.StateMachine_Current`, `e.StateMachine_Is` and
`e.StateMachine_TimeInState`; `e.StateMachine_Travel` goes to a state at once, whatever the
transitions say, and `e.StateMachine_TryTravel` only when `e.StateMachine_CanExit` says the state
can be left. Code guards are `e.StateMachine_RegisterGuard` (from an `@(init)`) and
`e.StateMachine_SetGuard` (one machine, with the script as `self`). Its events are
`onStateEntered` and `onStateExited` (data: the state's name), `onTransition` and `onStateEvent`
(a state's enter or exit event); `e.StateMachine_OnEnter` / `OnExit` listen to one state.

**Example**

A knight that walks with the move actions and attacks with "attack"; the machine picks walk,
idle and attack animations, and the knight stands still while attacking:

```odin
Knight :: struct {
	using script: e.Script,
	brain: ^e.StateMachine `export:"default=Sprite/Brain"`,
	speed: f32 `export:"default=120 min=0"`,
}

Knight_update :: proc(self: ^Knight, events: []sdl.Event, dt: f64) {
	if self.brain == nil do return
	move := e.Input_GetAxis("move_left", "move_right", self.game)
	if e.StateMachine_Is(self.brain, "attack") do move = 0
	self.node.position.x += move * self.speed * f32(dt)
	e.StateMachine_SetFloat(self.brain, "speed", abs(move) * self.speed)
	if e.Input_IsActionJustPressed("attack", self.game) do e.StateMachine_SetTrigger(self.brain, "attack")
}

@(init)
register_Knight :: proc "contextless" () {
	e.Script_Register(Knight, {update = Knight_update})
}
```

**API**

[e.StateMachine](https://crossfireengine.io/api/animation/#statemachine),
[e.StateMachine_SetFloat](https://crossfireengine.io/api/animation/#statemachine_setfloat),
[e.StateMachine_SetBool](https://crossfireengine.io/api/animation/#statemachine_setbool),
[e.StateMachine_SetTrigger](https://crossfireengine.io/api/animation/#statemachine_settrigger),
[e.StateMachine_Current](https://crossfireengine.io/api/animation/#statemachine_current),
[e.StateMachine_Is](https://crossfireengine.io/api/animation/#statemachine_is),
[e.StateMachine_TimeInState](https://crossfireengine.io/api/animation/#statemachine_timeinstate),
[e.StateMachine_Travel](https://crossfireengine.io/api/animation/#statemachine_travel),
[e.StateMachine_TryTravel](https://crossfireengine.io/api/animation/#statemachine_trytravel),
[e.StateMachine_CanExit](https://crossfireengine.io/api/animation/#statemachine_canexit),
[e.StateMachine_RegisterGuard](https://crossfireengine.io/api/animation/#statemachine_registerguard),
[e.StateMachine_SetGuard](https://crossfireengine.io/api/animation/#statemachine_setguard),
[e.StateMachine_OnEnter](https://crossfireengine.io/api/animation/#statemachine_onenter),
[e.CreateStateMachine](https://crossfireengine.io/api/animation/#createstatemachine)

More: [State machines](state_machines.md#your-first-state-machine),
[Guards](state_machines.md#guards)

## Skeleton2D

A Skeleton2D is the root of a character's bones. Its Bone2D children (and their children) are the
skeleton; Sprites on the bones move with them rigidly (a cut-out character), and SkinnedMeshes bend
over them. It has no settings of its own: move, turn or flip it to move the whole character. Use
it for characters animated by bones instead of a drawing per frame. In code it's an
`e.Skeleton2D`.

**Properties**

| Property | What it does |
|---|---|
| **Add Bone** | Adds a Bone2D under the skeleton (the start of a chain) |
| Position, Rotation, Scale | Like any node's: they move the whole skeleton and what it carries |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **Skeleton2D**, placed where the character stands (its hips).
2. **Add Bone** in the inspector, then build the chains from each bone (see [Bone2D](#bone2d)).
3. Put pictures on the bones: drag an image into the viewport with a bone selected, or drag a
   Sprite's row onto a bone in the scene tree.
4. Add an **Animator** under the Skeleton2D and key the bones in the Timeline.
5. Play (F5) to see the clips, and the IK chains if it has any.

**From code**

Give the script (often on the Skeleton2D itself) node fields for the parts it needs: its
Animator, bones, IK targets. Scale the skeleton with a negative `scale.x` to face the other way.
Bones are reached with node fields too (`^e.Bone2D`), or `e.Node_FindPath`.

**Example**

A puppet script on the Skeleton2D: it faces the mouse and plays "walk" or "idle":

```odin
Puppet :: struct {
	using script: e.Script,
	anim: ^e.Animator `export:"default=Anim"`,
	speed: f32 `export:"default=80 min=0"`,
}

Puppet_update :: proc(self: ^Puppet, events: []sdl.Event, dt: f64) {
	mouse := e.Scene_ScreenToWorld(self.scene, e.Input_GetMousePosition(self.game))
	here := e.Node_GetWorldPosition(self.node)
	self.node.scale.x = mouse.x < here.x ? -1 : 1
	move := e.Input_GetAxis("move_left", "move_right", self.game)
	self.node.position.x += move * self.speed * f32(dt)
	if self.anim != nil do e.Animator_Play(self.anim, move != 0 ? "walk" : "idle")
}

@(init)
register_Puppet :: proc "contextless" () {
	e.Script_Register(Puppet, {update = Puppet_update})
}
```

(`e.Animator_Play` with the clip already playing does nothing, so calling it every frame is fine.)

**API**

[e.Skeleton2D](https://crossfireengine.io/api/animation/#skeleton2d),
[e.CreateSkeleton2D](https://crossfireengine.io/api/animation/#createskeleton2d)

More: [Skeletal animation](skeletal_animation.md#building-a-skeleton)

## Bone2D

A Bone2D is one bone of a skeleton: a node pointing along its x axis for its **Length**. Its
children (pictures, more bones) move with it, so turning an upper arm turns the forearm and hand
too. Bones are posed by their Rotation (and Position, Scale) and keyed in the Timeline like any
node. In code it's an `e.Bone2D`.

**Properties**

| Property | What it does |
|---|---|
| **Length** | How long the bone is along its x axis: where its tip is (IK reaches with it) |
| **Add Bone** | Adds a bone at this one's tip, as its child |
| Rotation | Turns the bone (degrees, clockwise): how it is posed |

**In the editor**

1. Select a Skeleton2D (or a bone) and press **Add Bone**; **Add Node** (Ctrl+Shift+A) >
   **Bone2D** works too. A bone goes under a Skeleton2D or another bone.
2. Turn it (Rotation) to point where the bone goes, and set its **Length**.
3. With it selected, **Add Bone** again to continue the chain from its tip.
4. The viewport draws every bone as a wedge from its origin to its tip; select bones by their
   rows in the scene tree. The pose the scene has is the **rest pose** meshes bind to.
5. Key its Rotation in the Timeline, then Play (F5).

**From code**

A node field `^e.Bone2D` gets the bone. Its `rotation`, `position` and `scale` are those of any
node (relative to its parent bone); `length` is its Length. `e.Bone2D_Tip` gives where its tip is
in the world: where a gun's muzzle or a hand is.

**Example**

A turret whose barrel bone aims at the mouse and fires a bullet component from its tip:

```odin
Turret :: struct {
	using script: e.Script,
	barrel: ^e.Bone2D `export:"default=Base/Barrel"`,
	bullet: e.ComponentAsset `export:""`,
}

Turret_update :: proc(self: ^Turret, events: []sdl.Event, dt: f64) {
	if self.barrel == nil do return
	mouse := e.Scene_ScreenToWorld(self.scene, e.Input_GetMousePosition(self.game))
	toMouse := mouse - e.Node_GetWorldPosition(self.barrel)
	self.barrel.rotation = math.to_degrees(math.atan2(toMouse.y, toMouse.x))
	if e.Input_IsActionJustPressed("shoot", self.game) {
		e.Scene_AddComponent(self.scene, self.bullet, position = e.Bone2D_Tip(self.barrel))
	}
}

@(init)
register_Turret :: proc "contextless" () {
	e.Script_Register(Turret, {update = Turret_update})
}
```

(The rotation is relative to the bone's parent; this assumes the parent isn't turned.)

**API**

[e.Bone2D](https://crossfireengine.io/api/animation/#bone2d),
[e.Bone2D_Tip](https://crossfireengine.io/api/animation/#bone2d_tip),
[e.CreateBone2D](https://crossfireengine.io/api/animation/#createbone2d)

More: [Skeletal animation](skeletal_animation.md#animating-it)

## SkinnedMesh

A SkinnedMesh bends one picture over several bones: a mesh of triangles covers the picture, and
each point of it follows up to four bones, blended by weights. Where two bones meet, the picture
bends smoothly instead of showing a seam, which suits bodies, sleeves, tails and soft things. It
binds to its bones' **rest pose** (where they are when the scene starts) and moves with their
moves since. In code it's an `e.SkinnedMesh`.

**Properties**

| Property | What it does |
|---|---|
| **Texture** | The picture it bends (an image, or an atlas) |
| **Region** | Which image of the atlas it draws (shown for an atlas) |
| **Mesh columns**, **Mesh rows** | Make Mesh's grid: cells across and down the picture (more: smoother bends, more triangles) |
| **Make Mesh** | Covers the picture with that grid of triangles, leaving out empty cells (its bones and weights go) |
| **Bind to Bones** | Weights every point to the skeleton's nearest bones |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **SkinnedMesh** under the Skeleton2D, and choose its
   **Texture** (and **Region** for an atlas).
2. Set **Mesh columns** and **Mesh rows**, press **Make Mesh**, and place the mesh over the bones
   it should follow.
3. Press **Bind to Bones**. The inspector shows how many points, triangles and bones it has, and
   warns "Not bound" until it's bound.
4. Moving bones in the editor changes the rest pose, so the mesh doesn't bend then: press **Bind
   to Bones** again after moving bones or the mesh.
5. Play (F5), or play the Timeline: the mesh bends with the animated bones.

**From code**

A node field `^e.SkinnedMesh` gets it. Its `mesh` (an `e.MeshData`: vertices, uvs, triangles,
bones as paths from the mesh, weights) and `texture` are fields. It binds on its first update;
`e.SkinnedMesh_Bind` binds it again to the bones' pose now (after changing the rest pose in code)
and returns how many of its bones it found. `e.SkinnedMesh_Deform` gives where its points are now.

**Example**

A jelly that sways one of its bones, and warns when its mesh lost a bone (renamed or deleted):

```odin
Jelly :: struct {
	using script: e.Script,
	body: ^e.SkinnedMesh `export:"default=Body"`,
	top: ^e.Bone2D `export:"default=Root/Top"`,
	sway: f32 `export:"default=15 min=0 max=90"`,
	time: f32,
}

Jelly_ready :: proc(self: ^Jelly) {
	if self.body == nil do return
	found := e.SkinnedMesh_Bind(self.body)
	if found < len(self.body.mesh.bones) do log.warnf("%s: %d of its bones are missing", self.node.name, len(self.body.mesh.bones) - found)
}

Jelly_update :: proc(self: ^Jelly, events: []sdl.Event, dt: f64) {
	if self.top == nil do return
	self.time += f32(dt)
	self.top.rotation = -90 + self.sway * math.sin(self.time * 3)
}

@(init)
register_Jelly :: proc "contextless" () {
	e.Script_Register(Jelly, {ready = Jelly_ready, update = Jelly_update})
}
```

(The bind in `ready` happens before the sway turns the bone, so the scene's pose stays the rest
pose.)

**API**

[e.SkinnedMesh](https://crossfireengine.io/api/animation/#skinnedmesh),
[e.MeshData](https://crossfireengine.io/api/animation/#meshdata),
[e.SkinnedMesh_Bind](https://crossfireengine.io/api/animation/#skinnedmesh_bind),
[e.SkinnedMesh_Deform](https://crossfireengine.io/api/animation/#skinnedmesh_deform),
[e.CreateSkinnedMesh](https://crossfireengine.io/api/animation/#createskinnedmesh)

More: [Skeletal animation](skeletal_animation.md#pictures-that-bend-skinned-meshes)

## IKChain

An IKChain turns a chain of bones so the tip of its last bone reaches a target node (inverse
kinematics): move the hand, and the elbow and shoulder follow. Use it for feet staying on the
ground, hands holding things, a head looking at something. Two bones are solved exactly, bending
the chosen way; longer chains (a tail) turn each bone in turn. IK runs after the Animator each
frame, so you can animate the target and let IK place the limb. In code it's an `e.IKChain`.

**Properties**

| Property | What it does |
|---|---|
| **Tip bone** | The last bone of the chain: its tip reaches for the target |
| **IK target** | The node the chain's tip reaches for (move it, or animate it) |
| **Bones** | How many bones up from the tip turn (2: an arm or a leg; 1: only the tip turns) |
| **Bend** | Which way the middle joint bends for two bones: Positive (clockwise) or Negative |
| **Solve** | Turn the bones toward the target every frame (off: they keep their animation) |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **IKChain** (anywhere; under the Skeleton2D is tidy), and add a
   node to be its target (a Node2D "HandTarget").
2. Choose the **Tip bone** (the forearm) and the **IK target**; the inspector warns when either
   path leads nowhere.
3. Set **Bones** and **Bend** (an elbow and a knee bend opposite ways).
4. Drag the target in the viewport: the chain follows at once.
5. Play (F5) with a script or an Animator moving the target.

**From code**

A node field `^e.IKChain` gets it. Its `settings` (an `e.IKSettings`) holds `length` (Bones),
`bendPositive` (Bend) and `enabled` (Solve); `tip` and `target` are its paths. Usually you just
move the target node (`e.Node_SetWorldPosition`) and the chain follows on the next frame.
`e.IKChain_Solve` solves one chain now.

**Example**

An arm that reaches for the mouse while "grab" is held, and goes back to its animation otherwise:

```odin
Reacher :: struct {
	using script: e.Script,
	ik: ^e.IKChain `export:"default=ArmIK"`,
	hand: ^e.Node `export:"default=HandTarget"`,
}

Reacher_update :: proc(self: ^Reacher, events: []sdl.Event, dt: f64) {
	if self.ik == nil || self.hand == nil do return
	reaching := e.Input_IsActionPressed("grab", self.game)
	self.ik.settings.enabled = reaching
	if reaching {
		mouse := e.Scene_ScreenToWorld(self.scene, e.Input_GetMousePosition(self.game))
		e.Node_SetWorldPosition(self.hand, mouse)
	}
}

@(init)
register_Reacher :: proc "contextless" () {
	e.Script_Register(Reacher, {update = Reacher_update})
}
```

**API**

[e.IKChain](https://crossfireengine.io/api/animation/#ikchain),
[e.IKSettings](https://crossfireengine.io/api/animation/#iksettings),
[e.IKChain_Solve](https://crossfireengine.io/api/animation/#ikchain_solve),
[e.CreateIKChain](https://crossfireengine.io/api/animation/#createikchain)

More: [Skeletal animation](skeletal_animation.md#reaching-for-targets-ik-chains)

## Questions

**My Animator's track moves the wrong node, or none.** A track's node is a path from the
Animator's *parent*, not from the Animator: "Coin" is the Animator's sibling, "" the parent
itself. Put the Animator inside what it animates; an orange track name means its node isn't found.

**My script sets a property but the Animator undoes it.** The Animator sets its tracks' values in
its own update. A script that runs after it wins that frame; animate a different property (Position
X in the clip, Position Y from code) to avoid a tug of war.

**My StateMachine's trigger fires much later than I pressed the key.** A trigger stays set until
a transition that reads it is taken. If no transition from the current state uses it, it waits;
set it only when it can be used, or check the transitions' **From**.

**The StateMachine changes state but the animation doesn't.** **Animates** must be the
AnimatedSprite (the inspector warns when it animates none), and each state's **Plays** must name
one of that sprite's animations.

**My SkinnedMesh stopped bending after I moved a bone in the editor.** Moving bones in the editor
changes the rest pose the mesh binds to. Press **Bind to Bones** again.

**My IKChain does nothing.** **Tip bone** must be a Bone2D, the target must exist (the inspector
warns about both), and **Solve** must be on. With **Bones** at 1, only the tip turns.
