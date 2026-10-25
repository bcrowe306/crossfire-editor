---
title: Pathfinding and navigation
description: "Navigation regions and agents: characters finding their way around walls with A* paths."
order: 32
---

# Pathfinding and navigation

Navigation lets characters find their way: a guard walking to the player around the furniture, a
villager going home, a unit sent across the map. You mark **where characters can walk** with a
**NavRegion**, and give each character a **NavAgent**, which finds a path and walks its character
along it, around walls and around other characters.

- [How it works](#how-it-works)
- [Your first walking character](#your-first-walking-character)
- [NavRegion: where characters can walk](#navregion-where-characters-can-walk)
- [NavAgent: finding and following paths](#navagent-finding-and-following-paths)
- [Navigation in scripts](#navigation-in-scripts)
- [Doors, bridges and changing walls](#doors-bridges-and-changing-walls)
- [Limits](#limits)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## How it works

A NavRegion divides an area into a **grid of cells**. A cell is **blocked** when a wall covers
it: any **StaticBody**'s collision shape, including the walls a TileMap or an LDtk level makes from
its tiles. So a level that already has collision needs no extra work.

When a character needs to go somewhere, its NavAgent searches the grid for the shortest way
through open cells (the **A\*** algorithm), then straightens it: wherever the way between two
points is clear, it goes straight instead of cell by cell. Then each frame it steers its character
toward the next point.

## Your first walking character

1. **The area.** **Add Node** (Ctrl+Shift+A) > **NavRegion**. Place it at the top-left of the area
   characters walk in and set **Area width** and **Area height** to cover it (a whole level, or
   one room).
2. **Look at the grid.** Select the region: the viewport shades its blocked cells red. Walls
   (static bodies) block cells; nothing else does.
3. **A character.** Your character node (a CharacterMover with a CollisionShape, for example).
   With it selected, **Add Node** > **NavAgent**: the agent goes inside it.
4. **Send it somewhere** from the character's script (registered as every script is: [Scripts](scripts.md)):

```odin
Guard :: struct {
	using script: e.Script,
	nav: ^e.NavAgent `export:"default=NavAgent"`,
}

Guard_ready :: proc(self: ^Guard) {
	e.NavAgent_SetTarget(self.nav, {600, 300})
}

// Registers the script, with its ready hook (see Scripts)
@(init)
register_Guard :: proc "contextless" () {
	e.Script_Register(Guard, {ready = Guard_ready})
}
```

5. **Play** (F5): the guard walks to (600, 300), around anything in the way, and stops there.

## NavRegion: where characters can walk

| Setting | What it does |
|---|---|
| **Area width**, **Area height** | The area's size in pixels, from the node's position (its top-left corner) |
| **Cell size** | The grid's cell size. Smaller cells find narrower gaps and follow walls closer, but each search takes longer. 16 or 32 suits most games; match your tiles |
| **Agent radius** | Half your characters' width. Walls are grown by it, so paths keep characters' bodies clear of walls and they don't snag on corners. A gap narrower than twice this is closed |
| **Diagonal moves** | Paths may go diagonally (never squeezing between two blocked corners) |

The inspector shows how many cells the grid has. The grid is built when the scene starts.

Several regions can share a scene (rooms, floors); an agent uses the region it's standing in.

## NavAgent: finding and following paths

Put a NavAgent inside the node it moves.

| Setting | What it does |
|---|---|
| **Walk speed** | Pixels per second |
| **Arrive within** | How close to the target counts as there |
| **Keep apart** | Agents closer than this push each other aside, so a crowd doesn't stack up (0: no avoiding) |
| **Move parent** | The agent moves its parent itself. Off: it only works out where to go (`velocity`) and your script moves the character (to play walk animations, add knockback...) |

How it moves its parent:

- a **CharacterMover**: by setting its velocity and moving it (it slides along walls like when
  your code moves it)
- a **DynamicBody**: by setting its velocity
- any other node: by changing its position

It slows down over the last stretch and stops at the target. Its events (listen in the inspector's
**Events**):

| Event | When |
|---|---|
| **onArrived** | It reached its target |
| **onPathFailed** | No path leads to the target (walled off, or the agent isn't in any NavRegion) |

## Navigation in scripts

| Code | What it does |
|---|---|
| `e.NavAgent_SetTarget(agent, position)` | Finds a path and starts walking (false when there's none) |
| `e.NavAgent_Stop(agent)` | Stops where it is |
| `agent.moving` | Whether it's walking |
| `agent.velocity` | Where it's heading this frame, in pixels per second (flip the sprite by its x, pick walk or idle) |
| `agent.settings.speed` | Change its speed any time (running, slowed) |
| `e.Scene_FindNavRegion(scene, position)` | The region at a position |
| `e.NavRegion_FindPath(region, from, to)` | A path's points without an agent (to draw a route, check a distance) |
| `e.NavGrid_LineClear(&region.grid, a, b)` | Whether nothing blocks the straight line (line of sight on the grid) |

A guard chasing the player (its script has two more fields: the node to chase, and a countdown):

```odin
Guard :: struct {
	using script: e.Script,
	nav: ^e.NavAgent `export:"default=NavAgent"`,
	// The node to chase, chosen in the inspector
	player: ^e.Node `export:""`,
	// Seconds until the next path
	repath: f32,
}

Guard_update :: proc(self: ^Guard, events: []sdl.Event, dt: f64) {
	self.repath -= f32(dt)
	if self.repath <= 0 {
		// Every quarter second: the player moves
		e.NavAgent_SetTarget(self.nav, e.Node_GetWorldPosition(self.player))
		self.repath = 0.25
	}
}

@(init)
register_Guard :: proc "contextless" () {
	e.Script_Register(Guard, {update = Guard_update})
}
```

(Finding a path is quick, but not free: send agents again a few times a second, not every frame.)

## Doors, bridges and changing walls

- **A door that opens or closes:** block or open its cells: `e.NavGrid_SetBlocked(&region.grid,
  doorPosition, true)` (or `false`). One call per cell it covers.
- **Walls that moved or were added:** `e.NavRegion_Rebuild(region)` builds the grid again from the
  static bodies (cells blocked by hand open again).

Agents already walking keep their path; send them again to use the new grid.

## Limits

- Navigation is in the plane: top-down games, or things that fly. A platformer's walking needs
  jumps and gravity the grid doesn't know about.
- Only static bodies block the grid. Moving things (other characters, crates) are avoided by
  **Keep apart** between agents, not by the paths.
- A grid of very many cells (a huge level with tiny cells) makes searches slower: use bigger cells
  or several regions.

## How it's stored

```xml
<node kind="NavRegion" name="Floor" width="1280" height="720" cellSize="16" agentRadius="10"/>
<node kind="CharacterMover" name="Guard" x="100" y="100">
	<node kind="CollisionShape" shape="Circle" radius="10"/>
	<node kind="NavAgent" name="NavAgent" speed="120" avoidRadius="16"/>
</node>
```

## Questions

**My character doesn't move.** Check that it starts inside a NavRegion (the region's outline in
the viewport), that **Move parent** is on, and listen to **onPathFailed**.

**It walks through walls.** The walls need to be static bodies with collision shapes (a TileMap's
or LDtk level's collision counts). Select the region to see which cells are blocked.

**It gets stuck on corners.** Raise the region's **Agent radius** to about half the character's
width.

**It won't go through a gap.** The gap is narrower than twice the agent radius, or narrower than
a cell: lower the cell size.
