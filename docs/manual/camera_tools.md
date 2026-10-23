---
title: Camera tools
description: A camera that follows a node by itself (limits, dead zone, look-ahead, shake), parallax backgrounds, rooms the camera stays in, smooth zoom, and camera views for split screen and minimaps.
order: 18
---

# Camera tools: following, parallax, rooms, zoom, split screen

The camera decides what part of the world the player sees (a **Camera** node). Give it a
**Target** and it follows that node by itself, smoothly, without leaving the level. These tools
shape what it shows:

- **Following a target**: the camera eases after the player, with a dead zone, an offset, a
  look-ahead in the direction they run, limits it never shows past, and its own shake.
- **ParallaxLayer**: backgrounds that move slower than the world, so far hills drift by gently
  while the ground rushes past. It gives a flat game depth.
- **CameraZone**: rooms. The camera stays inside the room the player is in (it doesn't show the
  next room early), and slides over when the player walks into another.
- **Smooth zoom**: zoom in for a close-up, out for a boss arena, over a moment.
- **CameraView**: what another camera sees, drawn in a rectangle on the screen: each player's half
  in split screen, a minimap, a picture-in-picture of a door opening elsewhere.

- [Following a target](#following-a-target)
- [Parallax backgrounds](#parallax-backgrounds)
- [Rooms: camera zones](#rooms-camera-zones)
- [Smooth zoom](#smooth-zoom)
- [Camera views: split screen and minimaps](#camera-views-split-screen-and-minimaps)
- [In scripts](#in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Following a target

Select the **Camera** and, in the inspector's **Follow** group, pick its **Target**: the player
(any node of the scene; the list shows paths from the camera, like `../Hero`). When the game
runs, the camera starts on the target and follows it every frame. Renaming or moving nodes in
the scene tree keeps the path pointing at the same node.

How it follows:

- **Follow mode**: **Snap** (exactly on it every frame), **Exponential** (fast, then slowing as
  it arrives: **Smoothing**, higher is tighter), **SmoothDamp** (a spring that never overshoots:
  **Smooth time**, about how many seconds it takes to catch up; feels best for players),
  **Linear** (a steady **Follow speed**).
- **Max speed**: the fastest it may move, in pixels a second (0: no limit).
- **Dead zone X / Y**: a box around the middle of the view the target can move inside without
  moving the camera. Small steps don't shake the view; the camera moves once the target pushes
  past the box's edge.
- **Aim offset X / Y**: where the camera aims beside the target: `-40` in Y keeps the player a
  little below the middle, so more of what's above shows.
- **Look ahead X / Y**: how far the camera looks ahead in the direction the target moves (a
  runner sees more of what's coming); back to the middle when it stands still. **Look ease**:
  how quickly it swings when the target turns around (0: at once).

**Limits** keep the view inside the level: tick **Limit left**, **top**, **right** or **bottom**
and type where that edge is (in world pixels). The camera never shows past a ticked side,
whatever its zoom; untick a side to leave it open (a side-scroller that only stops at the ground
and the start of the level ticks Bottom and Left). With both sides of an axis ticked closer
together than the screen, the view is centered between them. A [camera zone](#rooms-camera-zones)
replaces the limits while the camera is in it.

**Zoom**: 2 shows everything twice as big.

**Shake** is how `e.Camera2D_Shake(camera)` shakes the view when a script gives no strength or
duration: **Shake size** (pixels), **Shake time** (seconds), **Shake rate** (new positions a
second, eased between: 10 to 30 rumbles, 0 jitters every frame).

Selected, the camera shows its guides in the viewport: its limits as lines, its dead zone as a
box around its middle, and a line to its target with a ring where it aims.

A camera placed inside the player (as its child) follows it too, rigidly, with no Target: use a
Target for smoothing, limits and the rest.

## Parallax backgrounds

1. **Add Node** > **ParallaxLayer**, at the top of the scene tree so it's drawn first (behind
   everything), or on a low **Layer**.
2. **Image**: the background picture (hills, clouds, a sky).
3. **Follows camera X / Y**: how much it moves with the camera:
   - **1**: it moves exactly like the world (no parallax)
   - **0.5**: half as fast: it looks far away
   - **0.1**: barely moves: very far (mountains)
   - **0**: it doesn't move at all with the camera (a sky)
4. **Repeat across** (and **Repeat down**): the image is tiled so it never ends as the camera
   travels.

Use several layers for more depth: sky at 0, mountains at 0.1, hills at 0.3, trees at 0.6. A
layer's children (a cloud sprite, a bird) move with it.

The editor's viewport shows layers where they are when the camera is where the scene starts
it; press **Play** to see them move.

## Rooms: camera zones

1. **Add Node** > **CameraZone** for each room. Put it at the room's top-left corner and set
   **Room width** and **Room height** to the room's size (the viewport outlines it).
2. **Slide time**: how long the view takes to slide into this room from another (0: at once).

While the scene's camera (its position: the player, when the camera follows the player) is in a
zone, the camera can't show anything outside it. Walking into the next zone slides the view
across, like the rooms of a Zelda or Metroid game. Outside every zone the camera keeps the limits
it had.

Make each zone at least the size of the screen (the game's width and height); a smaller room
keeps the camera centered on it.

## Smooth zoom

From a script:

```odin
e.Camera2D_ZoomTo(self.scene.camera, 1.5, 0.6)   // zoom in to 1.5 over 0.6 seconds
e.Camera2D_ZoomTo(self.scene.camera, 1, 0.6)     // and back
```

(Or animate it with a Tween in a script: `e.Tween_To(tween, &camera.zoom, 2, 0.5)`.)

## Camera views: split screen and minimaps

A **CameraView** draws what a **Camera** sees into a rectangle.

**A minimap:**

1. **Add Node** > **Camera** named **MapCamera**, in the middle of the level (it isn't the
   scene's main camera: the first Camera is).
2. **Add Node** > **CameraView**: **Shows camera**: MapCamera, **View zoom** 0.2 (five times as
   much of the level), **View width / height** 200 x 120, placed in a corner.
3. Put the CameraView on a **screen layer** (the scene's settings: Screen layers, and the node's
   Layer), so the main camera doesn't move it.

The view keeps its camera by a path, which follows when you rename or move nodes in the scene
tree.

**Split screen** for two players: a camera inside each player, and two CameraViews, each half the
screen, each showing one player's camera. (Leave the scene's main camera somewhere out of the way,
or make the views cover the whole screen.)

**Border** draws a frame around the view (0: none).

## In scripts

| Code | What it does |
|---|---|
| `e.Camera2D_SetFollowTarget(camera, node)` | Follows that node by itself (nil: stops) |
| `e.Camera2D_SetFollowTargetPath(camera, "../Hero")` | Follows the node at a path from the camera |
| `e.Camera2D_GetFollowTarget(camera)` | The node it follows (nil: none, or it's gone) |
| `camera.follow.mode = .SmoothDamp`, `camera.follow.deadzone`, `.offset`, `.lookAhead` | The follow settings |
| `e.Camera2D_SetLimit(camera, .Left, 0)`, `e.Camera2D_ClearLimit(camera, .Left)` | Limits one side, or frees it |
| `e.Camera2D_SetBounds(camera, {0, 0}, {3840, 720})`, `e.Camera2D_ClearBounds(camera)` | Limits all four sides, or none |
| `e.Camera2D_Shake(camera)`, `e.Camera2D_Shake(camera, 6, 0.3)` | Shakes with its Shake settings, or a strength and seconds |
| `e.Camera2D_ZoomTo(camera, zoom, seconds)` | Zooms smoothly (0 seconds: at once) |
| `layer.base = {x, y}` | Moves a ParallaxLayer (its `position` is set from the camera each frame) |
| `layer.settings.factor = {0.5, 0}` | Changes how much it follows |
| `zone.size`, `zone.settings.transition` | A zone's size and slide time |
| `view.settings.zoom`, `view.cameraPath` | A view's zoom, and the camera it shows (a path from it) |
| `e.CreateParallaxLayer`, `e.CreateCameraZone`, `e.CreateCameraView` | Make them from code |

From a script, a camera that follows the hero and stops at the ground:

```odin
// Given: hero: ^e.Node
camera := self.scene.camera
camera.follow.mode = .SmoothDamp
camera.follow.lookAhead = {80, 0}
e.Camera2D_SetLimit(camera, .Bottom, 720)
e.Camera2D_SetFollowTarget(camera, hero)
```

## How it's stored

```xml
<node kind="Camera" name="Camera" target="../Hero" followMode="SmoothDamp" smoothTime="0.3" deadzoneX="96" targetOffsetY="-40" lookAheadX="80" limitLeft="0" limitBottom="720" shakeStrength="6"/>
<node kind="ParallaxLayer" name="Hills" texture="assets/hills.png" factorX="0.3" factorY="0" repeatX="true"/>
<node kind="CameraZone" name="Room2" x="640" y="0" width="640" height="360" zoneTransition="0.5"/>
<node kind="CameraView" name="Minimap" x="1060" y="20" width="200" height="120" viewCamera="../MapCamera" viewZoom="0.2" layer="7"/>
```

## Questions

**The camera doesn't follow its target.** Check the Target's path still leads to the node (the
inspector warns when no node is there; a node the game makes later is found once it appears),
that the camera isn't panning (`e.Camera2D_MoveTo` pauses following until it ends), and that it's
the camera the scene draws through (the first Camera; another camera follows too, for a
CameraView).

**The camera jitters while following.** Use SmoothDamp or Exponential instead of Snap, or give it
a dead zone.

**The view stops before the level's edge.** A limit is at the wrong place: select the camera and
look at the lines it draws in the viewport.

**My parallax layer covers everything.** It's drawn in scene-tree order: move it to the top of the
tree (or put it on a lower Layer than the rest).

**The camera doesn't stop at the room's edge.** The camera's position must be inside the zone:
check the zone's outline covers the room, and that the camera follows the player (it's inside
the player node, follows it as its Target, or a script moves it).

**My minimap moves around.** Put the CameraView on a screen layer.

**UI looks big in a camera view.** UI controls and labels keep their size whatever the zoom
(they're for the screen); sprites and tiles zoom.
