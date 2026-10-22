# Camera tools: parallax, rooms, zoom, split screen

The camera decides what part of the world the player sees (a **Camera** node: put it inside the
player so it follows). These tools shape what it shows:

- **ParallaxLayer**: backgrounds that move slower than the world, so far hills drift by gently
  while the ground rushes past. It gives a flat game depth.
- **CameraZone**: rooms. The camera stays inside the room the player is in (it doesn't show the
  next room early), and slides over when the player walks into another.
- **Smooth zoom**: zoom in for a close-up, out for a boss arena, over a moment.
- **CameraView**: what another camera sees, drawn in a rectangle on the screen: each player's half
  in split screen, a minimap, a picture-in-picture of a door opening elsewhere.

- [Parallax backgrounds](#parallax-backgrounds)
- [Rooms: camera zones](#rooms-camera-zones)
- [Smooth zoom](#smooth-zoom)
- [Camera views: split screen and minimaps](#camera-views-split-screen-and-minimaps)
- [In scripts](#in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

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

**Split screen** for two players: a camera inside each player, and two CameraViews, each half the
screen, each showing one player's camera. (Leave the scene's main camera somewhere out of the way,
or make the views cover the whole screen.)

**Border** draws a frame around the view (0: none).

## In scripts

| Code | What it does |
|---|---|
| `e.Camera2D_ZoomTo(camera, zoom, seconds)` | Zooms smoothly (0 seconds: at once) |
| `layer.base = {x, y}` | Moves a ParallaxLayer (its `position` is set from the camera each frame) |
| `layer.settings.factor = {0.5, 0}` | Changes how much it follows |
| `zone.size`, `zone.settings.transition` | A zone's size and slide time |
| `view.settings.zoom`, `view.cameraPath` | A view's zoom, and the camera it shows (a path from it) |
| `e.CreateParallaxLayer`, `e.CreateCameraZone`, `e.CreateCameraView` | Make them from code |

## How it's stored

```xml
<node kind="ParallaxLayer" name="Hills" texture="assets/hills.png" factorX="0.3" factorY="0" repeatX="true"/>
<node kind="CameraZone" name="Room2" x="640" y="0" width="640" height="360" zoneTransition="0.5"/>
<node kind="CameraView" name="Minimap" x="1060" y="20" width="200" height="120" viewCamera="../MapCamera" viewZoom="0.2" layer="7"/>
```

## Questions

**My parallax layer covers everything.** It's drawn in scene-tree order: move it to the top of the
tree (or put it on a lower Layer than the rest).

**The camera doesn't stop at the room's edge.** The camera's position must be inside the zone:
check the zone's outline covers the room, and that the camera follows the player (it's inside
the player node, or a script moves it).

**My minimap moves around.** Put the CameraView on a screen layer.

**UI looks big in a camera view.** UI controls and labels keep their size whatever the zoom
(they're for the screen); sprites and tiles zoom.
