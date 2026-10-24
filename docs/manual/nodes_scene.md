---
title: "Node guides: scene structure"
description: "Guides for the nodes that shape a scene: Node2D, Camera, Component, LDtkLevel, CameraZone, NavRegion and NavAgent."
order: 40
---

# Node guides: scene structure

These nodes give a scene its shape: they group other nodes, choose what the player sees, reuse
saved groups of nodes, bring in whole levels, split the world into rooms and let characters find
their way. Each section below is one node kind's guide: what it does, its properties, how to set
it up in the editor, how scripts reach it, an example and its API. The overview of every kind is
[Node guides](nodes.md); the feature pages linked from each section go into depth.

- [Node2D](#node2d)
- [Camera](#camera)
- [Component](#component)
- [LDtkLevel](#ldtklevel)
- [CameraZone](#camerazone)
- [NavRegion](#navregion)
- [NavAgent](#navagent)
- [Questions](#questions)

## Node2D

A Node2D groups other nodes. It draws nothing itself, but moving, turning, scaling or hiding it
does the same to everything inside it: a "World" holding the level, an "Enemies" folder, a
moving platform made of several sprites. In code it's a plain `e.Node`, the part every other node
type starts with.

**Properties**

| Property | What it does |
|---|---|
| **Name** | What the scene tree shows; scripts find nodes by name or path |
| **Position X**, **Position Y** | Where it is, relative to its parent. Its children's positions are relative to it |
| **Rotation**, **Scale X**, **Scale Y** | Turn and size it, and everything inside with it |
| **Layer**, **Visible**, **Z index** | The drawing layer (0 to 7, not inherited by children), whether it and its children draw, the order within the layer |
| **Y sort** | Draws its children by how low they are on the screen (top-down games) |
| **Blend**, **Process**, **Groups** | How its pixels mix, when it updates (**Disabled** or **Pausable** pass down to children set to **Inherit**), its group names |

These are the settings every node has; a Node2D has nothing more.

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **Node2D**, at the top of the scene or inside another node.
2. Name it for what it holds (`World`, `Enemies`), then drag nodes onto it in the scene tree to
   put them inside.
3. Move it in the viewport: its children move with it.
4. Press **Play** (F5): the children appear where the group puts them.

**From code**

A script gets a group with a node field of type `^e.Node`, or `e.Scene_FindNode(self.scene,
"World/Enemies")`. Change `position`, `rotation`, `scale` and `visible` on it; `e.Node_AddChild`
puts a node inside it and `e.Node_GetWorldPosition` tells where a child really is.

**Example**

A platform made of several sprites under a Node2D, bobbing up and down:

```odin
Bobber :: struct {
	using script: e.Script,
	// The group to move (a child named Platform)
	platform: ^e.Node `export:"default=Platform"`,
	// How far it bobs, in pixels, and how fast
	height: f32 `export:"default=24"`,
	speed: f32 `export:"default=2"`,
	time: f32,
}

Bobber_update :: proc(self: ^Bobber, events: []sdl.Event, dt: f64) {
	if self.platform == nil do return
	self.time += f32(dt)
	// Every sprite inside moves with the group
	self.platform.position.y = math.sin(self.time * self.speed) * self.height
}

@(init)
register_Bobber :: proc "contextless" () {
	e.Script_Register(Bobber, {
		update = Bobber_update,
	})
}
```

**API**: [e.Node](https://crossfireengine.io/api/core/#node),
[e.Scene_FindNode](https://crossfireengine.io/api/core/#scene_findnode),
[e.Node_AddChild](https://crossfireengine.io/api/core/#node_addchild),
[e.Node_GetWorldPosition](https://crossfireengine.io/api/core/#node_getworldposition),
[e.Scene_GetGroup](https://crossfireengine.io/api/core/#scene_getgroup)

More: [Scenes and nodes](scenes_and_nodes.md#every-nodes-settings)

## Camera

A Camera chooses the part of the scene the game shows: its position is the middle of the screen.
Give it a **Target** and it follows that node by itself, smoothly, without showing past the
level's edges; it can also shake and zoom. The first Camera in a scene is the one the game draws
through (`self.scene.camera`); others serve CameraViews. In code it's an `e.Camera2D`.

**Properties**

| Property | What it does |
|---|---|
| **Zoom** | 1 is normal, 2 shows everything twice as big |
| **Target** | The node it follows while the game runs, as a path from the camera (`../Hero`) |
| **Follow mode** | **Snap**, **Exponential** (**Smoothing**), **SmoothDamp** (**Smooth time**) or **Linear** (**Follow speed**); **Max speed** caps how fast it moves |
| **Dead zone X**, **Dead zone Y** | A box in the middle the target moves inside without moving the camera |
| **Aim offset X**, **Aim offset Y** | Where it aims beside the target (`-40` in Y shows more above the player) |
| **Look ahead X**, **Look ahead Y**, **Look ease** | How far it looks ahead where the target moves, and how fast it swings round |
| **Limit left**, **Limit top**, **Limit right**, **Limit bottom** | Ticked sides it never shows past, in world pixels |
| **Shake size**, **Shake time**, **Shake rate** | How `e.Camera2D_Shake` shakes when a script gives no strength or time |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **Camera**, at the top of the scene (or inside the player, to
   follow it rigidly with no settings).
2. In the **Follow** group, pick the **Target** (the player) and a **Follow mode**: SmoothDamp
   feels best for players.
3. Under **Limits**, tick the sides the level has and type where its edges are.
4. Selected, the camera draws its limits, dead zone and a line to its target in the viewport.
5. Press **Play** (F5): the view starts on the target and eases after it.

**From code**

A node field `camera: ^e.Camera2D `export:"default=../Camera"`` reaches a camera; the scene's
main one is also `self.scene.camera`. `e.Camera2D_SetFollowTarget` and
`e.Camera2D_SetFollowTargetPath` choose what it follows, `e.Camera2D_SetLimit` and
`e.Camera2D_SetBounds` keep it in the level, `e.Camera2D_Shake` shakes it,
`e.Camera2D_ZoomTo` zooms smoothly, and `e.Camera2D_MoveTo` pans somewhere (following pauses
until the pan ends). `camera.follow` holds the follow settings.

**Example**

The player's script makes the camera follow it and shakes the view when it lands a hit:

```odin
Brawler :: struct {
	using script: e.Script,
	camera: ^e.Camera2D `export:"default=../Camera"`,
}

Brawler_ready :: proc(self: ^Brawler) {
	if self.camera == nil do return
	self.camera.follow.mode = .SmoothDamp
	self.camera.follow.lookAhead = {80, 0}
	// Never show below the ground
	e.Camera2D_SetLimit(self.camera, .Bottom, 720)
	e.Camera2D_SetFollowTarget(self.camera, self.node)
}

Brawler_update :: proc(self: ^Brawler, events: []sdl.Event, dt: f64) {
	if self.camera != nil && e.Input_IsActionJustPressed("ui_accept", self.game) {
		// 6 pixels for 0.25 seconds
		e.Camera2D_Shake(self.camera, 6, 0.25)
	}
}

@(init)
register_Brawler :: proc "contextless" () {
	e.Script_Register(Brawler, {
		ready = Brawler_ready,
		update = Brawler_update,
	})
}
```

**API**: [e.Camera2D](https://crossfireengine.io/api/camera/#camera2d),
[e.Camera2D_SetFollowTarget](https://crossfireengine.io/api/camera/#camera2d_setfollowtarget),
[e.Camera2D_SetLimit](https://crossfireengine.io/api/camera/#camera2d_setlimit),
[e.Camera2D_SetBounds](https://crossfireengine.io/api/camera/#camera2d_setbounds),
[e.Camera2D_Shake](https://crossfireengine.io/api/camera/#camera2d_shake),
[e.Camera2D_ZoomTo](https://crossfireengine.io/api/camera/#camera2d_zoomto),
[e.Camera2D_MoveTo](https://crossfireengine.io/api/camera/#camera2d_moveto),
[e.Scene_SetCamera](https://crossfireengine.io/api/camera/#scene_setcamera)

More: [Camera tools](camera_tools.md#following-a-target)

## Component

A Component node is an instance of a component: a group of nodes (a coin, an enemy, a door)
saved once in its own file and placed in any scene. Change the component and every instance
changes. While the game runs, the instance is the component's own root node (an Area for a coin,
a CharacterMover for an enemy), with this node's name, position and other settings; it's a plain
`e.Node` only when the component can't be read.

**Properties**

| Property | What it does |
|---|---|
| **Component** | Which component this is an instance of |
| **Edit** *name* | Opens the component in its own tab, to change every instance |
| **Make Unique** | Copies the component into a new one just for this instance |
| **Name**, **Position X** / **Y**, **Rotation**, **Scale X** / **Y**, **Layer**, **Visible** | The instance's own; everything else (the nodes inside, their scripts and settings) is the component's |

**In the editor**

1. Make the component first: build the nodes, then save them as a component (see
   [Components](components.md#making-a-component)).
2. Drag it from the browser's Components folder into the viewport, or **Add Node**
   (Ctrl+Shift+A) > **Component** and choose it in the **Component** row.
3. Move, turn and scale the instance like any node; it shows the component's whole picture.
4. Press **Play** (F5): each instance runs the component's nodes and scripts.

**From code**

Give a script a field of type `e.ComponentAsset` (the inspector offers the project's components)
or use the `COMPONENT_...` constants of `scripts/assets.odin`. `e.Scene_AddComponent` adds an
instance at the start of the next frame and returns its root (without a `parent`, the position
is in the world). `e.Scene_RemoveComponent` removes one by its root's `id`,
`e.Scene_GetComponentInstances` lists a component's instances, and `e.Node_GetComponent` tells
which component a node is an instance of. A node field such as `^e.Area` can point at a placed
instance: its type is the component root's.

**Example**

A spawner that drops a coin every two seconds, never more than five at once:

```odin
CoinSpawner :: struct {
	using script: e.Script,
	// The inspector shows a picker of the project's components
	coin: e.ComponentAsset `export:"default=components/coin.component.xml"`,
	every: f32 `export:"default=2"`,
	wait: f32,
}

CoinSpawner_update :: proc(self: ^CoinSpawner, events: []sdl.Event, dt: f64) {
	self.wait -= f32(dt)
	if self.wait > 0 do return
	self.wait = self.every
	if len(e.Scene_GetComponentInstances(self.scene, self.coin)) >= 5 do return
	// Under this node, a little to the right each time
	offset := f32(len(e.Scene_GetComponentInstances(self.scene, self.coin))) * 32
	e.Scene_AddComponent(self.scene, self.coin, parent = self.node, position = {offset, 0})
}

@(init)
register_CoinSpawner :: proc "contextless" () {
	e.Script_Register(CoinSpawner, {
		update = CoinSpawner_update,
	})
}
```

**API**: [e.ComponentAsset](https://crossfireengine.io/api/assets-and-import/#componentasset),
[e.Scene_AddComponent](https://crossfireengine.io/api/project-format-and-loading/#scene_addcomponent),
[e.Scene_RemoveComponent](https://crossfireengine.io/api/project-format-and-loading/#scene_removecomponent),
[e.Scene_GetComponentInstances](https://crossfireengine.io/api/project-format-and-loading/#scene_getcomponentinstances),
[e.Node_GetComponent](https://crossfireengine.io/api/project-format-and-loading/#node_getcomponent)

More: [Components](components.md#placing-instances)

## LDtkLevel

An LDtkLevel shows a level made in the LDtk level editor: its tile layers, its IntGrid layer
turned into collision, and its entities turned into nodes with your components and scripts. Use
it when you draw levels in LDtk; save there and the editor (and a game started with Play)
follows. In code it's an `e.LDtkLevelNode`.

**Properties**

| Property | What it does |
|---|---|
| **LDtk file** | Which LDtk project (`.ldtk`); **Open in LDtk** opens it there |
| **Level** | Which of its levels, **(first level)** by default |
| **Whole world** | Builds every level of the world, each in its place |
| **Collision** | The IntGrid layer that becomes collision; each value is **Solid**, **One-way platform** or **Area (a trigger)** |
| **Entities** | Makes nodes for the level's entities; per entity type, **Becomes** (a component, code...) and **Runs** (its script) |
| **Background**, **Smooth tiles** | Draws LDtk's background color and image; smooths scaled tiles (off keeps pixel art sharp) |

**In the editor**

1. Import the `.ldtk` file into the project, so its tilesets come along.
2. Drag it from the browser into the viewport, or **Add Node** (Ctrl+Shift+A) > **LDtkLevel**
   and choose its **LDtk file**.
3. Pick the **Level** (or click one on the world map in the browser's preview) and the
   **Collision** layer; check that the ground's values are **Solid**.
4. The inspector lists how each layer is built and what each entity type becomes.
5. Press **Play** (F5): the player stands on the IntGrid's ground and the entities run their
   scripts. Shift+C in the viewport shows the collision shapes.

**From code**

A node field `level: ^e.LDtkLevelNode `export:"default=../Level"`` reaches it.
`e.LDtk_FindEntityNodes` lists the nodes made for an entity type, `e.LDtk_IntGridAtPosition`
reads the IntGrid value at a world position, and an entity's own script reads its LDtk data with
`e.LDtk_EntityOf` and `e.LDtk_FieldValue`. Its events are `onEntitySpawned` and `onReloaded`.

**Example**

A level exit that opens once every Coin entity of the level is collected:

```odin
LevelExit :: struct {
	using script: e.Script,
	level: ^e.LDtkLevelNode `export:"default=../Level"`,
	open: bool,
}

LevelExit_ready :: proc(self: ^LevelExit) {
	// Closed (hidden) until the coins are gone
	self.node.visible = false
}

LevelExit_update :: proc(self: ^LevelExit, events: []sdl.Event, dt: f64) {
	if self.open || self.level == nil do return
	// Collected coins removed with e.Scene_RemoveNode leave this list
	if len(e.LDtk_FindEntityNodes(self.level, "Coin")) == 0 {
		self.open = true
		self.node.visible = true
		log.info("every coin collected: the exit is open")
	}
}

@(init)
register_LevelExit :: proc "contextless" () {
	e.Script_Register(LevelExit, {
		ready = LevelExit_ready,
		update = LevelExit_update,
	})
}
```

**API**: [e.LDtkLevelNode](https://crossfireengine.io/api/ldtk/#ldtklevelnode),
[e.LDtk_FindEntityNodes](https://crossfireengine.io/api/ldtk/#ldtk_findentitynodes),
[e.LDtk_IntGridAtPosition](https://crossfireengine.io/api/ldtk/#ldtk_intgridatposition),
[e.LDtk_EntityOf](https://crossfireengine.io/api/ldtk/#ldtk_entityof),
[e.LDtk_EntityRefNode](https://crossfireengine.io/api/ldtk/#ldtk_entityrefnode),
[e.LDtk_RegisterEntity](https://crossfireengine.io/api/ldtk/#ldtk_registerentity)

More: [LDtk levels](levels.md#the-ldtklevel-nodes-settings)

## CameraZone

A CameraZone is a room the camera stays inside. While the scene's camera is in a zone, it can't
show anything outside it; when the camera moves into another zone, the view slides over to it,
like the rooms of a Zelda or Metroid game. In code it's an `e.CameraZone`.

**Properties**

| Property | What it does |
|---|---|
| **Room width**, **Room height** | The room's size in pixels, from the node's position (its top-left corner) |
| **Slide time** | Seconds the view takes to slide into this room from another (0: at once) |
| **Visible** | A hidden zone is ignored, so hiding one turns that room off |

**In the editor**

1. Set up a **Camera** that follows the player (its **Target**, or the camera inside the player).
2. **Add Node** (Ctrl+Shift+A) > **CameraZone** for each room, at the room's top-left corner.
3. Set **Room width** and **Room height**: the viewport outlines the room. Make each room at least
   the size of the screen; a smaller one keeps the camera centered on it.
4. Press **Play** (F5) and walk from room to room: the view stops at each room's edges and slides
   across.

**From code**

A node field `zone: ^e.CameraZone` reaches one. `zone.size` is its size and
`zone.settings.transition` its slide time; `e.CreateCameraZone` makes one from code. The zone is
picked by the scene camera's world position, so a script can test the same thing to know which
room the player is in.

**Example**

A boss arena that zooms the camera out while the camera is inside it:

```odin
BossArena :: struct {
	using script: e.Script,
	zone: ^e.CameraZone `export:"default=../BossRoom"`,
	inside: bool,
}

BossArena_update :: proc(self: ^BossArena, events: []sdl.Event, dt: f64) {
	camera := self.scene.camera
	if self.zone == nil || camera == nil do return
	at := e.Node_GetWorldPosition(camera)
	corner := e.Node_GetWorldPosition(self.zone)
	inside := at.x >= corner.x && at.y >= corner.y &&
		at.x < corner.x + self.zone.size.x && at.y < corner.y + self.zone.size.y
	if inside != self.inside {
		self.inside = inside
		// Show more of the arena, over the zone's slide time
		e.Camera2D_ZoomTo(camera, inside ? 0.8 : 1, self.zone.settings.transition)
	}
}

@(init)
register_BossArena :: proc "contextless" () {
	e.Script_Register(BossArena, {
		update = BossArena_update,
	})
}
```

**API**: [e.CameraZone](https://crossfireengine.io/api/camera/#camerazone),
[e.CameraToolSettings](https://crossfireengine.io/api/camera/#cameratoolsettings),
[e.CreateCameraZone](https://crossfireengine.io/api/camera/#createcamerazone),
[e.Camera2D_ZoomTo](https://crossfireengine.io/api/camera/#camera2d_zoomto)

More: [Camera tools](camera_tools.md#rooms-camera-zones)

## NavRegion

A NavRegion marks where characters can walk: a grid of cells over an area, where any cell a
StaticBody's collision shape covers is blocked (a TileMap's or an LDtk level's walls count).
NavAgents find their paths through it. Use it in top-down games, or for things that fly. In code
it's an `e.NavRegion`.

**Properties**

| Property | What it does |
|---|---|
| **Area width**, **Area height** | The area's size in pixels, from the node's position (its top-left corner) |
| **Cell size** | The grid's cell size: smaller finds narrower gaps but searches take longer (16 or 32; match your tiles) |
| **Agent radius** | Half your characters' width: walls grow by it so paths keep bodies clear of them |
| **Diagonal moves** | Paths may go diagonally (never squeezing between two blocked corners) |

The inspector shows how many cells the grid has.

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **NavRegion**, at the top-left of the walking area.
2. Set **Area width** and **Area height** to cover it (a whole level, or one room), and the
   **Cell size** and **Agent radius** to suit your tiles and characters.
3. Select it: the viewport shades its blocked cells red. Only static bodies block cells.
4. Add a **NavAgent** to a character (below) and press **Play** (F5).

**From code**

A node field `region: ^e.NavRegion` reaches one, or `e.Scene_FindNavRegion` finds the region at
a position. `e.NavRegion_FindPath` gives a path's points without an agent,
`e.NavGrid_LineClear(&region.grid, a, b)` tells whether nothing blocks a straight line,
`e.NavGrid_SetBlocked` blocks or opens one cell (a door), and `e.NavRegion_Rebuild` builds the
grid again from the static bodies.

**Example**

A guard that notices the player only when no wall is between them:

```odin
Lookout :: struct {
	using script: e.Script,
	// The node to watch, chosen in the inspector
	player: ^e.Node `export:""`,
	sight: f32 `export:"default=300"`,
	spotted: bool,
}

Lookout_update :: proc(self: ^Lookout, events: []sdl.Event, dt: f64) {
	if self.player == nil do return
	eye := e.Node_GetWorldPosition(self.node)
	target := e.Node_GetWorldPosition(self.player)
	region := e.Scene_FindNavRegion(self.scene, eye)
	sees := region != nil && linalg.distance(eye, target) <= self.sight &&
		e.NavGrid_LineClear(&region.grid, eye, target)
	if sees && !self.spotted do log.info("the lookout spotted the player")
	self.spotted = sees
}

@(init)
register_Lookout :: proc "contextless" () {
	e.Script_Register(Lookout, {
		update = Lookout_update,
	})
}
```

**API**: [e.NavRegion](https://crossfireengine.io/api/navigation/#navregion),
[e.NavSettings](https://crossfireengine.io/api/navigation/#navsettings),
[e.Scene_FindNavRegion](https://crossfireengine.io/api/navigation/#scene_findnavregion),
[e.NavRegion_FindPath](https://crossfireengine.io/api/navigation/#navregion_findpath),
[e.NavGrid_LineClear](https://crossfireengine.io/api/navigation/#navgrid_lineclear),
[e.NavGrid_SetBlocked](https://crossfireengine.io/api/navigation/#navgrid_setblocked),
[e.NavRegion_Rebuild](https://crossfireengine.io/api/navigation/#navregion_rebuild)

More: [Pathfinding and navigation](navigation.md#navregion-where-characters-can-walk)

## NavAgent

A NavAgent finds paths through the NavRegion it stands in and moves its parent along them,
slowing down at the end and keeping apart from other agents. It moves a CharacterMover or a
DynamicBody by its velocity and any other node by its position. Put one inside each character
that walks by itself (guards, villagers, followers). In code it's an `e.NavAgent`.

**Properties**

| Property | What it does |
|---|---|
| **Walk speed** | Pixels per second |
| **Arrive within** | How close to the target counts as there |
| **Keep apart** | Agents closer than this push each other aside (0: no avoiding) |
| **Move parent** | The agent moves its parent itself; off, it only works out `velocity` and your script moves the character |

Its events (inspector > **Events**): **onArrived** and **onPathFailed**.

**In the editor**

1. Have a **NavRegion** covering where the character starts.
2. Select the character (a CharacterMover with a CollisionShape, for example) and **Add Node**
   (Ctrl+Shift+A) > **NavAgent**: it goes inside it.
3. Set **Walk speed** and **Keep apart**; leave **Move parent** on unless your script moves the
   character.
4. Send it somewhere from the character's script and press **Play** (F5). Listen to
   **onPathFailed** to hear when no path leads to the target.

**From code**

A node field `nav: ^e.NavAgent `export:"default=NavAgent"`` reaches the agent from the
character's script. `e.NavAgent_SetTarget` finds a path and starts walking (false when there's
none), `e.NavAgent_Stop` stops it, `nav.moving` says whether it's walking, `nav.velocity` where
it's heading (flip a sprite by its x) and `nav.settings.speed` changes its speed any time.

**Example**

A villager walking back and forth between where it starts and a point beside it:

```odin
Villager :: struct {
	using script: e.Script,
	nav: ^e.NavAgent `export:"default=NavAgent"`,
	// The other end of the walk, from where it starts
	walk: [2]f32 `export:"default=200, 0"`,
	home: [2]f32,
	away: bool,
}

Villager_ready :: proc(self: ^Villager) {
	self.home = e.Node_GetWorldPosition(self.node)
}

Villager_update :: proc(self: ^Villager, events: []sdl.Event, dt: f64) {
	if self.nav == nil || self.nav.moving do return
	// Arrived (or just started): head for the other end
	self.away = !self.away
	if !e.NavAgent_SetTarget(self.nav, self.away ? self.home + self.walk : self.home) {
		log.warn("the villager has no way there")
	}
}

@(init)
register_Villager :: proc "contextless" () {
	e.Script_Register(Villager, {
		ready = Villager_ready,
		update = Villager_update,
	})
}
```

**API**: [e.NavAgent](https://crossfireengine.io/api/navigation/#navagent),
[e.NavAgent_SetTarget](https://crossfireengine.io/api/navigation/#navagent_settarget),
[e.NavAgent_Stop](https://crossfireengine.io/api/navigation/#navagent_stop),
[e.CreateNavAgent](https://crossfireengine.io/api/navigation/#createnavagent)

More: [Pathfinding and navigation](navigation.md#navagent-finding-and-following-paths)

## Questions

**I added two Cameras and the game shows the wrong one.** The first Camera the scene builds is
the one it draws through; any other only serves a CameraView. Put the main camera first in the
scene tree, or call `e.Scene_SetCamera(self.scene, camera)`.

**My script's field pointing at a component instance is nil.** At run time the instance is the
component's root node, so the field's type must match that root (`^e.Area` for a coin whose root
is an Area), or be `^e.Node`.

**A CameraZone doesn't hold the camera.** The zone is chosen by the camera's own position, not
the player's: the camera must follow the player (its **Target**, or as the player's child), and
the zone must be visible. After the camera leaves every zone, it keeps the last zone's limits.

**My NavAgent stands still.** It needs a NavRegion where it starts, **Move parent** on (or your
script moving the character by `velocity`), and a target it can reach: listen to
**onPathFailed**.

**The LDtk level's entities are only rectangles.** Choose a component in the entity type's
**Becomes**, or write a script named like the entity: the inspector says what each type becomes
and why.

**Moving a Node2D didn't move a node I expected.** Only nodes inside it in the scene tree follow
it; a node beside it keeps its own position. Drag the node onto the Node2D to put it inside.
