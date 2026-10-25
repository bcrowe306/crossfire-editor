---
title: "Node guides: graphics"
description: "Guides to the nodes that draw: sprites, tilemaps, parallax, camera views, lights, screen effects, lines, trails and particles."
order: 48
---

# Node guides: graphics

These are the nodes that put things on the screen: pictures, animations, tile levels, scrolling
backgrounds, extra camera views, lights and shadows, effects over the whole screen, lines, trails
and particles. Each section is one node kind's guide: what it does, its properties, how to set
it up in the editor, how a script reaches it, an example and its API. The overview of every kind
is [Node guides](nodes.md); the feature pages linked from each section go into depth.

- [Sprite](#sprite)
- [AnimatedSprite](#animatedsprite)
- [TileMap](#tilemap)
- [ParallaxLayer](#parallaxlayer)
- [CameraView](#cameraview)
- [Light2D](#light2d)
- [LightOccluder](#lightoccluder)
- [ScreenEffect](#screeneffect)
- [Line2D](#line2d)
- [Trail2D](#trail2d)
- [ParticleEmitter](#particleemitter)
- [Questions](#questions)

## Sprite

A Sprite draws one picture, centered on the node's position: a tree, a coin, a crate, a ship. Use
it for anything that shows a still image; turn, grow or mirror it with the node's Rotation and
Scale (Scale X -1 faces it the other way). In code it's an `e.Sprite`.

**Properties**

| Property | What it does |
|---|---|
| **Texture** | The picture it draws: any image of the project, or a texture atlas |
| **Region** | With an atlas as its Texture: which of the atlas's pictures |
| Aseprite layers (checkboxes) | With an Aseprite file: which of its layers are drawn (none ticked: every visible one) |
| **Pivot slice** | With an Aseprite file that has slices with pivots: the pivot drawn at the node's position (none: the middle) |
| **9-patch**, **9-patch size** | With an Aseprite 9-patch slice: the picture is drawn stretched to that size, corners kept (0: the slice's own size) |

**In the editor**

1. Drag a picture from the browser into the viewport (a Sprite named after it appears there), or
   **Add Node** (Ctrl+Shift+A) > **Sprite** and pick its **Texture**.
2. It needs no parent or children. Put it inside a moving node (a body, a character) to move with
   it.
3. Place it with the viewport's handles, or Position X / Y in the inspector.
4. Press **Play** (F5): it draws where it is in the viewport. A picture saved again in another
   program updates in the viewport and in the running game.

**From code**

A script gets it through a node field, `sprite: ^e.Sprite`. Set `sprite.texture` to another
picture (`e.Asset_Texture(self.game, asset)`, with an `e.TextureAsset` field or a `TEXTURE_...`
constant of `scripts/assets.odin`), `sprite.visible` to hide it, `sprite.scale.x = -1` to mirror
it, and `e.Sprite_SetRegion(sprite, atlas, name)` to show another picture of an atlas.

**Example**

A door that shows its open picture when the player presses the accept action:

```odin
Door :: struct {
	using script: e.Script,
	sprite: ^e.Sprite `export:"default=Sprite"`,
	// The picture of the open door (a dropdown of the project's images)
	openImage: e.TextureAsset `export:""`,
	open: bool,
}

Door_update :: proc(self: ^Door, events: []sdl.Event, dt: f64) {
	if self.sprite == nil || self.open do return
	if e.Input_IsActionJustPressed("ui_accept", self.game) {
		self.open = true
		self.sprite.texture = e.Asset_Texture(self.game, self.openImage)
	}
}

@(init)
register_Door :: proc "contextless" () {
	e.Script_Register(Door, {update = Door_update})
}
```

**API**: [e.Sprite](https://crossfireengine.io/api/project-format-and-loading/#sprite),
[e.Sprite_SetRegion](https://crossfireengine.io/api/rendering/#sprite_setregion),
[e.Asset_Texture](https://crossfireengine.io/api/assets-and-import/#asset_texture)

More: [Sprites and images](sprites_and_images.md#sprites)

## AnimatedSprite

An AnimatedSprite plays sprite sheet animations ("idle", "run", "jump"), each from its own sheet,
drawn centered on the node's position. Use it for characters, enemies, coins that spin: anything
drawn frame by frame. Its animations are its own, or an animation asset's (an `.anim.xml` file,
or an Aseprite file's tags). In code it's an `e.AnimatedSprite`.

**Properties**

| Property | What it does |
|---|---|
| **Animations** | Its own animations, or an animation asset's that other sprites share |
| **Sheets** | The sheets its animations use (shown, not edited here) |
| **Starts with** | The animation it plays when the scene starts (the first one unless you pick one) |
| **N animations** / **Edit Animations** | Opens the bottom panel's Animation tab on this sprite |
| Aseprite layers, **Pivot slice** | With an Aseprite sheet: the layers drawn, and the pivot drawn at the node's position |
| **Save as Animation Asset** | Makes its own animations a file other sprites can use |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **AnimatedSprite**. Put it inside the character node it draws.
2. Press **Edit Animations**: in the **Animation** tab, set each animation's **Sheet** and
   **Grid** (cells across and down, or a frame's size), its frames, speed and looping. Or cut
   the sheet in the [sprite sheet slicer](sprite_slicer.md) (**Slice a sheet…**): pick frames on
   the picture, name the animations, and **Apply to** the sprite (its animation player plays
   them).
3. Pick **Starts with**.
4. Press **P** (or the play button above the viewport) to see it play in the viewport, then
   **Play** (F5) to check it in the game.

**From code**

A node field `sprite: ^e.AnimatedSprite` gets it. Its `animation` is an animation player:
`e.AnimationPlayer_Play(&sprite.animation, "run")` switches (playing the one that's playing does
nothing; `restart = true` starts it again), `e.AnimationPlayer_IsPlaying` and
`e.AnimationPlayer_CurrentName` say what plays, `sprite.animation.speed` speeds it up (0 freezes
it), and `e.AnimatedSprite_UseAnimations(sprite, asset, "idle")` swaps to another animation asset.
The player's events (`onAnimationEnded`, `onFrameChanged`, `onFrameEvent`...) tell a script when
things happen.

**Example**

A runner that plays "run" while a direction is held and "idle" otherwise, mirrored to face the way
it goes:

```odin
Runner :: struct {
	using script: e.Script,
	sprite: ^e.AnimatedSprite `export:"default=Sprite"`,
}

Runner_update :: proc(self: ^Runner, events: []sdl.Event, dt: f64) {
	if self.sprite == nil do return
	left := e.Input_IsActionPressed("ui_left", self.game)
	right := e.Input_IsActionPressed("ui_right", self.game)
	if left || right {
		e.AnimationPlayer_Play(&self.sprite.animation, "run")
		self.sprite.scale.x = left ? -1 : 1
	} else {
		e.AnimationPlayer_Play(&self.sprite.animation, "idle")
	}
}

@(init)
register_Runner :: proc "contextless" () {
	e.Script_Register(Runner, {update = Runner_update})
}
```

**API**: [e.AnimatedSprite](https://crossfireengine.io/api/project-format-and-loading/#animatedsprite),
[e.AnimationPlayer_Play](https://crossfireengine.io/api/animation/#animationplayer_play),
[e.AnimationPlayer_IsPlaying](https://crossfireengine.io/api/animation/#animationplayer_isplaying),
[e.AnimatedSprite_UseAnimations](https://crossfireengine.io/api/animation/#animatedsprite_useanimations)

More: [Sprites and images](sprites_and_images.md#animated-sprites)

## TileMap

A TileMap draws the tilemap layers of an Aseprite file, and turns tiles with a collision
property into physics bodies (solid, one-way and area tiles). Use it for a level made of tiles:
ground, walls, platforms, water. Tiles can also be painted in the editor, kept in the scene. In
code it's an `e.TileMapNode`.

**Properties**

| Property | What it does |
|---|---|
| **Tilemap file** | The Aseprite file (files with tilemap layers are listed first) |
| **Paint Tiles** | Opens the bottom panel's Tiles tab to paint on it |
| **Frame** | The file's frame shown, and collision's (only with more than one frame) |
| Layers (checkboxes) | Which tilemap layers it draws (none ticked: every one visible in Aseprite) |
| **Animate**, **Tag** | Plays the file's frames, or a tag's (water, torches); collision stays on **Frame** |
| **Tile collision** | Tiles' collision properties become a StaticBody and Areas |
| Layers, Mask, Friction, Bounce | The generated bodies' physics settings (with Tile collision) |

**In the editor**

1. Import the `.aseprite` file (File > Import Asset, Ctrl+I) and drag it from the browser into
   the viewport: its top-left corner goes where you drop it. Or **Add Node** (Ctrl+Shift+A) >
   **TileMap** and pick its **Tilemap file**.
2. It makes its own children (one per layer, plus the bodies) when the scene runs: don't add
   any.
3. Press **Paint Tiles** to paint in the viewport with the **Tiles** tab's tools.
4. Press **Play** (F5): walk a character on it to check the collision. A file saved again in
   Aseprite updates in the running game.

**From code**

A node field `level: ^e.TileMapNode` gets it. `e.TileMap_TileAt(level, layer, position)` gives the
tile under a point of the world (and its layer), `e.TileMap_TileProperty(layer, tile, name)` one
of its properties, `e.TileMap_CellAt` the column and row under a point, `e.TileMap_SetTile` changes
a cell (0 empties it) and `e.TileMap_SetTerrain` paints a terrain there. Changed collision is
rebuilt on the node's next update.

**Example**

A digger that breaks the block under its feet when the accept action is pressed:

```odin
Digger :: struct {
	using script: e.Script,
	level: ^e.TileMapNode `export:"default=../Level"`,
}

Digger_update :: proc(self: ^Digger, events: []sdl.Event, dt: f64) {
	if self.level == nil || !e.Input_IsActionJustPressed("ui_accept", self.game) do return
	// A little below the node: the tile it stands on
	below := e.Node_GetWorldPosition(self.node) + {0, 20}
	if column, row, ok := e.TileMap_CellAt(self.level, "Ground", below); ok {
		e.TileMap_SetTile(self.level, "Ground", column, row, 0)
	}
}

@(init)
register_Digger :: proc "contextless" () {
	e.Script_Register(Digger, {update = Digger_update})
}
```

**API**: [e.TileMapNode](https://crossfireengine.io/api/tilemaps-and-aseprite/#tilemapnode),
[e.TileMap_TileAt](https://crossfireengine.io/api/tilemaps-and-aseprite/#tilemap_tileat),
[e.TileMap_TileProperty](https://crossfireengine.io/api/tilemaps-and-aseprite/#tilemap_tileproperty),
[e.TileMap_CellAt](https://crossfireengine.io/api/tilemaps-and-aseprite/#tilemap_cellat),
[e.TileMap_SetTile](https://crossfireengine.io/api/tilemaps-and-aseprite/#tilemap_settile),
[e.TileMap_SetTerrain](https://crossfireengine.io/api/tilemaps-and-aseprite/#tilemap_setterrain)

More: [Tilemaps](tilemaps.md#adding-a-tilemap-to-a-scene)

## ParallaxLayer

A ParallaxLayer is a background that moves slower than the world as the camera moves, so it
looks far away: skies, mountains, hills. Its image can repeat so it never ends, and its children
(a cloud, a bird) move with it. In code it's an `e.ParallaxLayer`.

**Properties**

| Property | What it does |
|---|---|
| **Image** | The background picture (none: just its children) |
| **Follows camera X**, **Follows camera Y** | How much it moves with the camera: 1 like the world, 0.5 half as fast, 0 not at all (a sky) |
| **Repeat across**, **Repeat down** | Tiles the image across (or down) the screen |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **ParallaxLayer**, at the top of the scene tree so it's drawn
   first (behind everything), or on a low **Layer**.
2. Pick its **Image** and set **Follows camera X / Y**. Use several layers for depth: sky at 0,
   mountains at 0.1, hills at 0.3, trees at 0.6.
3. Tick **Repeat across** for a background that scrolls sideways.
4. The viewport shows it where it is when the camera is where the scene starts it: press **Play**
   (F5) and move the camera (a camera following the player) to see it scroll.

**From code**

A node field `layer: ^e.ParallaxLayer` gets it. Its position is set from the camera every frame,
so move it with `layer.base` (where it is when the camera is at its start). `layer.settings.factor`
changes how much it follows, `layer.settings.repeatX` / `repeatY` the tiling, and `layer.texture`
the image. `e.CreateParallaxLayer(scene, texture, factor)` makes one from code.

**Example**

Clouds that drift on their own, on top of the parallax:

```odin
Clouds :: struct {
	using script: e.Script,
	layer: ^e.ParallaxLayer `export:"default=Clouds"`,
	// Pixels a second (negative: to the left)
	wind: f32 `export:"default=-12"`,
}

Clouds_update :: proc(self: ^Clouds, events: []sdl.Event, dt: f64) {
	if self.layer == nil do return
	// base, not position: the camera sets the position every frame
	self.layer.base.x += self.wind * f32(dt)
}

@(init)
register_Clouds :: proc "contextless" () {
	e.Script_Register(Clouds, {update = Clouds_update})
}
```

**API**: [e.ParallaxLayer](https://crossfireengine.io/api/camera/#parallaxlayer),
[e.CreateParallaxLayer](https://crossfireengine.io/api/camera/#createparallaxlayer),
[e.CameraToolSettings](https://crossfireengine.io/api/camera/#cameratoolsettings)

More: [Camera tools](camera_tools.md#parallax-backgrounds)

## CameraView

A CameraView draws what another Camera sees into a rectangle on the screen: split screen (one
view per player), a minimap (a zoomed-out camera), picture in picture. The view takes only the
node's position (its top-left corner), not its rotation or scale. In code it's an `e.CameraView`.

**Properties**

| Property | What it does |
|---|---|
| **View width**, **View height** | The rectangle's size, from the node's position |
| **Shows camera** | The Camera node it shows (kept by a path, which follows renames and moves) |
| **View zoom** | Zoom, times its camera's (0.2 shows five times as much) |
| **Border** | The frame's width in pixels (0: none) |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **Camera** for what the view shows (a MapCamera in the middle of
   the level, or a camera inside each player). The scene's main camera is its first Camera.
2. **Add Node** > **CameraView**; pick **Shows camera**, set **View width / height**, **View zoom**
   and **Border**, and place it (a corner of the screen for a minimap).
3. Put it on a **screen layer** (the scene's settings: Screen layers, then the node's **Layer**) so
   the main camera doesn't move it.
4. Press **Play** (F5): the rectangle shows the other camera's picture.

**From code**

A node field `view: ^e.CameraView` gets it. `view.settings.zoom` and `view.settings.border` change
the look, `view.size` its rectangle, `view.cameraPath` the camera it shows (a path from the view),
and `view.visible` shows or hides it. `e.CreateCameraView(scene, size, cameraPath)` makes one from
code.

**Example**

A minimap that the player toggles and zooms out a little more each time it opens:

```odin
Minimap :: struct {
	using script: e.Script,
	view: ^e.CameraView `export:"default=Minimap"`,
}

Minimap_update :: proc(self: ^Minimap, events: []sdl.Event, dt: f64) {
	if self.view == nil do return
	if e.Input_IsKeyJustPressed(.M, self.game) {
		self.view.visible = !self.view.visible
		if self.view.visible do self.view.settings.zoom = max(self.view.settings.zoom * 0.8, 0.05)
	}
}

@(init)
register_Minimap :: proc "contextless" () {
	e.Script_Register(Minimap, {update = Minimap_update})
}
```

**API**: [e.CameraView](https://crossfireengine.io/api/camera/#cameraview),
[e.CreateCameraView](https://crossfireengine.io/api/camera/#createcameraview),
[e.Camera2D](https://crossfireengine.io/api/camera/#camera2d)

More: [Camera tools](camera_tools.md#camera-views-split-screen-and-minimaps)

## Light2D

A Light2D lights a dark scene: a point light shines all around (a torch, a lamp), a spot light
in a cone the way the node faces (a flashlight). Its color fades from its center to nothing at its
reach; lights add up, and with Shadows they stop at occluders. It only shows in a scene with
lighting turned on. In code it's an `e.Light2D`.

**Properties**

| Property | What it does |
|---|---|
| **Light kind** | **Point** (all around) or **Spot** (a cone) |
| **Light color** | Its color at the center |
| **Energy** | How bright: 1 its color, 2 twice as bright (up to white) |
| **Reach** | How far it goes, in pixels |
| **Cone** | A spot light's width in degrees; it points the node's rotation (0: right) |
| **Shadows** | It stops at LightOccluders (and, with the scene's setting, static bodies) |

**In the editor**

1. Select the scene in the browser and tick **Lit (dark outside its lights)** in its Scene
   settings; set its **Ambient** (the light everywhere: black is pitch dark).
2. **Add Node** (Ctrl+Shift+A) > **Light2D**, where the light comes from: inside a player or a
   lantern to move with it.
3. Set its kind, color, **Energy** and **Reach**; selected, a ring shows its reach in the viewport.
4. The viewport's light-bulb button (Shift+L) shows the scene unlit while you edit. Press **Play**
   (F5): the game is always lit.

**From code**

A node field `light: ^e.Light2D` gets it. Change `light.settings.energy`, `.radius`, `.color`,
`.angle`, `.shadows` or `.kind` any time; `light.visible = false` turns it off.
`e.Scene_SetLighting(scene, true, ambient)` lights a scene from code, `e.CreateLight2D` makes a
light, and `e.Light_Visibility(light)` gives the area it reaches as a polygon.

**Example**

A flashlight that the player switches on and off, with a battery that dims it:

```odin
Flashlight :: struct {
	using script: e.Script,
	light: ^e.Light2D `export:"default=Light"`,
	// Seconds of light in a full battery
	battery: f32 `export:"default=60 min=1"`,
	used: f32,
}

Flashlight_update :: proc(self: ^Flashlight, events: []sdl.Event, dt: f64) {
	if self.light == nil do return
	if e.Input_IsActionJustPressed("ui_accept", self.game) do self.light.visible = !self.light.visible
	if !self.light.visible do return
	self.used = min(self.used + f32(dt), self.battery)
	// Full brightness until the last quarter, then fading out
	left := 1 - self.used / self.battery
	self.light.settings.energy = min(left * 4, 1)
}

@(init)
register_Flashlight :: proc "contextless" () {
	e.Script_Register(Flashlight, {update = Flashlight_update})
}
```

**API**: [e.Light2D](https://crossfireengine.io/api/lighting/#light2d),
[e.LightSettings](https://crossfireengine.io/api/lighting/#lightsettings),
[e.CreateLight2D](https://crossfireengine.io/api/lighting/#createlight2d),
[e.Scene_SetLighting](https://crossfireengine.io/api/lighting/#scene_setlighting),
[e.Light_Visibility](https://crossfireengine.io/api/lighting/#light_visibility)

More: [2D lighting](lighting.md#lights)

## LightOccluder

A LightOccluder is a shape that blocks light: lights with Shadows stop at its edges and the area
behind it stays dark. Use it for walls, pillars, trees and crates in a lit scene. Walls that have
collision can cast shadows without one (the scene's **Static bodies cast shadows**). In code it's an
`e.LightOccluder`.

**Properties**

| Property | What it does |
|---|---|
| **Shape** | Rectangle, Circle, Polygon or Segment (a thin wall), like a CollisionShape's |
| **Width**, **Height** | A rectangle's size, centered on the node |
| **Radius** | A circle's radius |
| **Points** | A polygon's or segment's points, `x,y` pairs in the node's space |

**In the editor**

1. In a lit scene, **Add Node** (Ctrl+Shift+A) > **LightOccluder**, over the wall's picture (or
   inside the node it belongs to, to move with it).
2. Pick its **Shape** and size it; the viewport outlines it in gray.
3. Tick **Shadows** on the lights it should block.
4. Press **Play** (F5): the light stops at it. The occluder itself is dark: put it slightly inside
   the wall's picture if the wall's face should show lit.

**From code**

A node field `occluder: ^e.LightOccluder` gets it. `occluder.shape`, `.size`, `.radius` and
`.points` change it; a hidden occluder (`visible = false`) doesn't block light.
`e.CreateLightOccluder(scene, {w, h})` makes a rectangle from code.

**Example**

A window shutter that lets light in while it's open:

```odin
Shutter :: struct {
	using script: e.Script,
	blind: ^e.LightOccluder `export:"default=Blind"`,
}

Shutter_update :: proc(self: ^Shutter, events: []sdl.Event, dt: f64) {
	if self.blind == nil do return
	// Hidden occluders don't cast shadows
	if e.Input_IsActionJustPressed("ui_accept", self.game) do self.blind.visible = !self.blind.visible
}

@(init)
register_Shutter :: proc "contextless" () {
	e.Script_Register(Shutter, {update = Shutter_update})
}
```

**API**: [e.LightOccluder](https://crossfireengine.io/api/lighting/#lightoccluder),
[e.CreateLightOccluder](https://crossfireengine.io/api/lighting/#createlightoccluder)

More: [2D lighting](lighting.md#shadows)

## ScreenEffect

A ScreenEffect runs a shader over the whole scene as drawn: an old TV (CRT), bloom, color
grading, or your own effect. Several run one after the other, in the order they were added. It
needs the GPU renderer: elsewhere it's skipped and the scene draws as it is. In code it's an
`e.ScreenEffect`.

**Properties**

| Property | What it does |
|---|---|
| **Effect** | The shader: a built-in screen effect (crt, bloom, color_grade) or one of the project's |
| **New Shader**, **Edit** | Makes a shader file for it, or opens its file in a code tab |
| **Covers screen layers** | The effect covers the HUD too (on by default); off, screen layers draw over it untouched |
| The shader's parameters | One row each (sliders, colors, vectors), named by the shader |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **ScreenEffect** (under Graphics). Where it is in the tree
   doesn't matter.
2. Choose its **Effect** and set its parameters.
3. Untick **Visible** to turn it off without removing it.
4. Press **Play** (F5) with the project's Renderer on Auto or GPU. A shader with a mistake shows
   its error in the Console.

**From code**

A node field `fx: ^e.ScreenEffect` gets it. `e.Node_SetShaderParam(fx, name, value)` sets a
parameter (a number, `[2]f32`, `[4]f32` or `sdl.Color`), `e.Node_SetShader(fx, path)` changes the
effect, `fx.includeScreenLayers` is **Covers screen layers**, and `fx.visible` turns it on and off.
`e.CreateScreenEffect(scene, "builtin:crt")` adds one from code.

**Example**

Color drains from the screen as the player's health drops (a ScreenEffect with the
`builtin:color_grade` effect):

```odin
Woozy :: struct {
	using script: e.Script,
	grade: ^e.ScreenEffect `export:"default=Grade"`,
	health: f32 `export:"default=100 min=0 max=100"`,
}

Woozy_update :: proc(self: ^Woozy, events: []sdl.Event, dt: f64) {
	if self.grade == nil do return
	// Full color at full health, gray at none, with a darker edge
	left := self.health / 100
	e.Node_SetShaderParam(self.grade, "saturation", left)
	e.Node_SetShaderParam(self.grade, "vignette", 1 - left)
}

@(init)
register_Woozy :: proc "contextless" () {
	e.Script_Register(Woozy, {update = Woozy_update})
}
```

**API**: [e.ScreenEffect](https://crossfireengine.io/api/shaders-and-screen-effects/#screeneffect),
[e.CreateScreenEffect](https://crossfireengine.io/api/shaders-and-screen-effects/#createscreeneffect),
[e.Node_SetShaderParam](https://crossfireengine.io/api/shaders-and-screen-effects/#node_setshaderparam),
[e.Node_SetShader](https://crossfireengine.io/api/shaders-and-screen-effects/#node_setshader)

More: [Shaders and screen effects](shaders.md#screen-effects)

## Line2D

A Line2D draws a thick line through points in its own space: ropes, lasers, paths, outlines. Its
color can fade along it, its corners be sharp or round, its ends rounded, and a texture can run
along it (a chain, a dashed line). Moving, turning and scaling the node moves, turns and scales
the line. In code it's an `e.Line2D`.

**Properties**

| Property | What it does |
|---|---|
| **Points** | The points, `x,y` pairs separated by spaces, in the node's space |
| **Line width** | Thickness in pixels |
| **Line color**, **End color** | The colors at the start and the end, blended along the line |
| **Opacity at end** | The end color's opacity (0 fades it out) |
| **Joints**, **Round caps**, **Closed** | Sharp or Round corners; rounded ends; join the last point to the first |
| **Texture**, **Texture mode** | An image along it: Stretch (once) or Tile (every line-width of length) |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **Line2D** (under Graphics).
2. Type its **Points**: `0,0 200,0 200,100` is an L shape starting at the node's position. The
   viewport draws it as you type.
3. Set its width, colors and joints; give it a **Texture** for a rope or a chain. A line with a
   texture also takes a shader (the inspector's Shader section).
4. Press **Play** (F5) to see what scripts do to it.

**From code**

A node field `line: ^e.Line2D` gets it. `e.Line2D_SetPoints(line, points)` replaces its points
(copied), `e.Line2D_AddPoint` adds one at the end, `e.Line2D_Clear` removes them all, and
`line.settings` holds every setting (`width`, `color`, `endColor`, `joint`, `closed`...).
`e.CreateLine2D(scene, points)` makes one from code.

**Example**

A laser that reaches out from its node when fired, and pulses while it's on:

```odin
Laser :: struct {
	using script: e.Script,
	beam: ^e.Line2D `export:"default=Beam"`,
	reach: f32 `export:"default=400 min=10"`,
	length, time: f32,
}

Laser_update :: proc(self: ^Laser, events: []sdl.Event, dt: f64) {
	if self.beam == nil do return
	firing := e.Input_IsActionPressed("ui_accept", self.game)
	// Grows at 2000 pixels a second while fired, gone at once when not
	self.length = firing ? min(self.length + 2000 * f32(dt), self.reach) : 0
	self.time += f32(dt)
	self.beam.settings.width = 4 + 2 * math.sin(self.time * 30)
	e.Line2D_SetPoints(self.beam, {{0, 0}, {self.length, 0}})
}

@(init)
register_Laser :: proc "contextless" () {
	e.Script_Register(Laser, {update = Laser_update})
}
```

**API**: [e.Line2D](https://crossfireengine.io/api/particles-and-lines/#line2d),
[e.LineSettings](https://crossfireengine.io/api/particles-and-lines/#linesettings),
[e.Line2D_SetPoints](https://crossfireengine.io/api/particles-and-lines/#line2d_setpoints),
[e.Line2D_AddPoint](https://crossfireengine.io/api/particles-and-lines/#line2d_addpoint),
[e.Line2D_Clear](https://crossfireengine.io/api/particles-and-lines/#line2d_clear),
[e.CreateLine2D](https://crossfireengine.io/api/particles-and-lines/#createline2d)

More: [Lines, trails and GPU particles](lines_and_trails.md#lines)

## Trail2D

A Trail2D leaves a ribbon behind its parent as the parent moves: sword swings, dashes, comets,
tire tracks. It records where the parent goes and forgets points older than its length, tapering
from its start width and color to its end ones. It draws in the world, so when the parent turns
the trail stays where it was. In code it's an `e.Trail2D`.

**Properties**

| Property | What it does |
|---|---|
| **Start width**, **End width** | Thickness at the newest point (by the parent) and at the tail (0 tapers to a point) |
| **Start color**, **End color**, **Opacity at end** | Colors along it; 0 opacity fades the tail out |
| **Joints**, **Round caps** | Sharp or Round corners; rounded ends |
| **Texture**, **Texture mode** | An image along it: Stretch or Tile |
| **Trail length (s)** | Seconds each point lasts: how long the trail is |
| **Point spacing** | How far the parent moves before a point is added (smaller: smoother curves) |
| **Emitting** | Adding points; off, the trail fades away |

**In the editor**

1. Select what leaves the trail (the player, a sword, a projectile).
2. **Add Node** (Ctrl+Shift+A) > **Trail2D**: it becomes a child of the selected node and follows
   it.
3. Set its widths, colors, **Trail length (s)** and **Point spacing**.
4. The viewport doesn't show trails (nothing moves there): press **Play** (F5) and move the
   parent.

**From code**

A node field `trail: ^e.Trail2D` gets it. `e.Trail2D_SetEmitting(trail, on)` starts or stops
adding points, `e.Trail2D_Clear(trail)` forgets them (after a teleport, so no streak crosses the
screen), and `trail.settings` holds every setting (`width`, `endWidth`, `lifetime`,
`minDistance`...). `e.CreateTrail2D(scene)` makes one from code: make it a child of what leaves
it.

**Example**

A dash: the trail shows only while dashing, and is cleared when the player respawns:

```odin
Dasher :: struct {
	using script: e.Script,
	trail: ^e.Trail2D `export:"default=Trail"`,
	dashLeft: f32,
}

Dasher_ready :: proc(self: ^Dasher) {
	if self.trail != nil do e.Trail2D_SetEmitting(self.trail, false)
}

Dasher_update :: proc(self: ^Dasher, events: []sdl.Event, dt: f64) {
	if self.trail == nil do return
	if e.Input_IsActionJustPressed("ui_accept", self.game) do self.dashLeft = 0.25
	if self.dashLeft > 0 {
		self.dashLeft -= f32(dt)
		self.node.position.x += 900 * f32(dt)
	}
	e.Trail2D_SetEmitting(self.trail, self.dashLeft > 0)
}

// Back to the start: no streak across the level
Dasher_respawn :: proc(self: ^Dasher, at: [2]f32) {
	self.node.position = at
	if self.trail != nil do e.Trail2D_Clear(self.trail)
}

@(init)
register_Dasher :: proc "contextless" () {
	e.Script_Register(Dasher, {ready = Dasher_ready, update = Dasher_update})
}
```

**API**: [e.Trail2D](https://crossfireengine.io/api/particles-and-lines/#trail2d),
[e.Trail2D_SetEmitting](https://crossfireengine.io/api/particles-and-lines/#trail2d_setemitting),
[e.Trail2D_Clear](https://crossfireengine.io/api/particles-and-lines/#trail2d_clear),
[e.CreateTrail2D](https://crossfireengine.io/api/particles-and-lines/#createtrail2d)

More: [Lines, trails and GPU particles](lines_and_trails.md#trails)

## ParticleEmitter

A ParticleEmitter sends out particles that move, spin, grow and change color: sparks, smoke,
fire, rain, explosions. It emits in cycles of **Lifetime** seconds, **Amount** particles a cycle,
evenly or all at once (**Burst**); a continuous emitter runs forever, a one-shot stops after one
cycle. It can run on the graphics card for many more particles. In code it's an
`e.ParticleEmitter`.

**Properties**

The settings come in groups (the Particles tab's categories); hover a name for its range and
default. The inspector shows a summary (one-shot or continuous, the amount and rate, the
lifetime, the shape, CPU or GPU, the particles alive), **Emitting** and a **Preset** menu, then
**Edit in the Particles tab** and a link per group. The settings are edited in the bottom panel's
**Particles** tab, one group at a time, with presets (Fire, Smoke, Sparks, Dust, Rain), Restart
and Reset.

| Property | What it does |
|---|---|
| **Emitting**, **Continuous** | Emits from the start; starts a new cycle when one ends (off: a one-shot) |
| **Amount**, **Lifetime**, **Burst** | Particles a cycle; seconds a cycle and a particle last; 0 steady, 1 all at once |
| **Spread**, **Local space** | The area particles start in; particles move with the emitter instead of staying in the world |
| **On the GPU**, **GPU amount** (GPU) | Simulates on the graphics card, with that many particles a cycle |
| **Shape**, **Texture**, **Size**, **Scale start**, **Scale end** | What a particle is drawn as (Circle, Rectangle, Texture...), its size, and its scale over its life |
| **Rotation**, **Torque**, **Torque accel.** | Starting turn and spin |
| **Color ramp** (**Ramp**), or **Start color** and **End color** | Its colors over its life |
| **Angle**, **Velocity**, **Speed scale**, **Acceleration** | Direction (270 is up) and speed |
| **Gravity dir.**, **Gravity**, **Wind** | Forces on every particle |
| **Collide**, **Elasticity** | Particles bounce off each other and the view's edges (not physics bodies) |
| The **var.** and **spread** rows | How much randomness each value gets (a spread does nothing with its variance at 0) |
| **Reset** (the Particles tab's) | Every setting back to a new emitter's |

**In the editor**

1. Select what the particles come from (a ship's engine, a torch), then **Add Node**
   (Ctrl+Shift+A) > **ParticleEmitter**: it becomes a child and follows it.
2. Place it where the particles start. Press **P** (or the viewport's play button) to see it run in
   the viewport.
3. Pick a preset in the inspector, then change the settings in the **Particles** tab (**Edit in
   the Particles tab**, or a group's link):
   the viewport shows each change at once, and the tab's **Restart** plays it again. For a
   one-shot (an explosion), untick **Emitting** and **Continuous** and start it from a script.
4. Press **Play** (F5) to check it in the game.

**From code**

A node field `emitter: ^e.ParticleEmitter` gets it. `e.ParticleEmitter_Start` begins a cycle (fires
a one-shot again), `e.ParticleEmitter_Stop` stops emitting (live particles finish),
`e.ParticleEmitter_Clear` removes every live particle, and `e.ParticleEmitter_AliveCount` counts
them. `emitter.emitting` is whether it's emitting now (`emitter.settings.emitting` is only how it
starts); `emitter.settings` holds every setting, named as in the scene file (`amount`,
`particleColor`, `gravityVelocity`...). Its `onFinished` event comes when a run has ended and its
last particle died.

**Example**

A chest that bursts into sparkles when opened (Sparkles: a one-shot emitter, Emitting off):

```odin
Chest :: struct {
	using script: e.Script,
	sparkles: ^e.ParticleEmitter `export:"default=Sparkles"`,
	opened: bool,
}

Chest_update :: proc(self: ^Chest, events: []sdl.Event, dt: f64) {
	if self.sparkles == nil || self.opened do return
	if e.Input_IsActionJustPressed("ui_accept", self.game) {
		self.opened = true
		self.sparkles.settings.amount = 80
		e.ParticleEmitter_Start(self.sparkles)
	}
}

@(init)
register_Chest :: proc "contextless" () {
	e.Script_Register(Chest, {update = Chest_update})
}
```

**API**: [e.ParticleEmitter](https://crossfireengine.io/api/particles-and-lines/#particleemitter),
[e.ParticleSettings](https://crossfireengine.io/api/particles-and-lines/#particlesettings),
[e.ParticleEmitter_Start](https://crossfireengine.io/api/particles-and-lines/#particleemitter_start),
[e.ParticleEmitter_Stop](https://crossfireengine.io/api/particles-and-lines/#particleemitter_stop),
[e.ParticleEmitter_Clear](https://crossfireengine.io/api/particles-and-lines/#particleemitter_clear),
[e.CreateParticleEmitter](https://crossfireengine.io/api/particles-and-lines/#createparticleemitter)

More: [Particles](particles.md#making-an-emitter)

## Questions

**My ParallaxLayer doesn't move when my script sets its position.** The camera sets a
ParallaxLayer's position every frame. Move its `base` instead.

**My CameraView slides away when the camera moves.** Put it on a screen layer (the scene's
settings: Screen layers, then the node's **Layer**), so the main camera doesn't move it.

**My ScreenEffect does nothing.** It needs the GPU renderer: check the project's Renderer is Auto
or GPU, and the Console for shader errors. Elsewhere (the software renderer, the web) effects are
skipped.

**My trail doesn't show in the viewport.** Trails only draw while their parent moves, so only in
Play. Check **Emitting** is on and **Trail length (s)** isn't tiny.

**My script kept one of the TileMap's bodies, and it's gone.** After `e.TileMap_SetTile` the
TileMap's collision is rebuilt on its next update with new bodies: find them again.

**I hid an occluder and the light shines through.** That's how it works: hidden occluders (and
ones inside a hidden node) don't block light, which makes `visible` a handy on and off switch.
