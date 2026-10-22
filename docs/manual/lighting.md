# 2D lighting

Lighting makes a scene dark and lights it with **lights**: a torch flickering in a cave, a street
lamp's circle of light, a flashlight's cone, a window's glow. **Occluders** block the light and
cast shadows behind them: walls, pillars, crates.

- [Turning it on](#turning-it-on)
- [Lights](#lights)
- [Shadows](#shadows)
- [Editing in the dark](#editing-in-the-dark)
- [HUDs and menus stay lit](#huds-and-menus-stay-lit)
- [Lighting in scripts](#lighting-in-scripts)
- [Animating lights](#animating-lights)
- [How it works, and its limits](#how-it-works-and-its-limits)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Turning it on

Lighting is a setting of each scene:

1. Select the scene in the browser (the **Scenes** folder). Its preview, under the browser, shows
   its **Scene settings**.
2. Tick **Lit (dark outside its lights)**. The scene goes dark.
3. **Ambient** is the light everywhere, before any lights: black is pitch dark, a dark blue a
   moonlit night, a gray a dim room, white no darkness at all.
4. Add lights.

## Lights

**Add Node** (Ctrl+Shift+A) > **Light2D**, and place it where the light comes from.

| Setting | What it does |
|---|---|
| **Light kind** | **Point**: shines all around (a torch, a lamp). **Spot**: a cone (a flashlight, a stage light) |
| **Light color** | Its color at the center |
| **Energy** | How bright: 1 is its color, 2 twice as bright (up to white), 0.5 half |
| **Reach** | How far it goes, in pixels. It fades evenly from the center to nothing there |
| **Cone** | A spot light's width, in degrees. The cone points the way the node is turned (rotation 0: right, 90: down) |
| **Shadows** | It stops at occluders |

Lights add up where they overlap: a red and a green light make yellow. A light inside a moving node
(a player, a lantern carried by an enemy) moves with it.

The viewport shows a light's marker; selected, a ring shows its reach.

## Shadows

**Add Node** > **LightOccluder**: a shape that blocks light. Its **Shape** is a Rectangle (Width,
Height), a Circle (Radius), a Polygon (Points: `x,y` pairs) or a Segment (two points: a thin wall).
Lights with **Shadows** ticked stop at its edges, and the area behind it stays dark. The viewport
outlines occluders in gray.

**Walls you already have:** in the scene settings, **Static bodies cast shadows** makes every
StaticBody's collision shapes block light too: a TileMap's or an LDtk level's solid walls cast
shadows without any occluders. (One-way platforms don't.)

Occluders are dark themselves: a lit wall's face isn't lit. Put the occluder slightly inside the
wall's picture if you want the face to show.

## Editing in the dark

A dark scene is hard to edit. The viewport's light-bulb button (in its header, **Shift+L**) shows
lit scenes unlit while you work; press it again to see the lighting. The game is always lit.

## HUDs and menus stay lit

Only the layers the camera draws are lit. Layers in the scene's **Screen layers** (its settings:
HUDs, menus) are drawn after the lighting, at full brightness. Put your UI on a screen layer.

## Lighting in scripts

```odin
Torch :: struct {
	using script: e.Script,
	light: ^e.Light2D `export:"default=Light"`,
	time: f32,
}

Torch_update :: proc(self: ^Torch, events: []sdl.Event, dt: f64) {
	// A flicker
	self.time += f32(dt)
	self.light.settings.energy = 1 + 0.1 * math.sin(self.time * 20)
}
```

| Code | What it does |
|---|---|
| `light.settings.energy`, `.radius`, `.color`, `.angle`, `.shadows`, `.kind` | Change a light any time |
| `light.visible = false` | Turns it off |
| `e.Scene_SetLighting(scene, true, ambient)` | Lights a scene (or not), with an ambient color; `bodyShadows = true` makes static bodies cast shadows |
| `e.CreateLight2D(scene, settings)` | A light from code |
| `e.CreateLightOccluder(scene, {w, h})` | An occluder from code (`shape`, `radius`, `points` for other shapes) |
| `e.Light_Visibility(light)` | The area a light reaches, as a polygon (for gameplay: is the player in the light?) |

## Animating lights

An **Animator** can animate a light's **Light energy**, **Light radius** and **Light color**
(and its position, to move it): a torch that flickers, a lighthouse beam that sweeps (animate its
rotation), a sunrise (animate the color).

## How it works, and its limits

The engine draws a **light map** the size of the screen: the ambient color everywhere, plus each
light's area (the polygon its light reaches, fading toward its edges). Then it multiplies the
light map over what was drawn: where the map is black the scene is black, where it's white the
scene shows as drawn. This needs no shaders, so it works with every renderer, in the browser too.

Limits:

- Shadows are sharp (hard edges). Soft shadows need shaders (planned).
- Normal-mapped sprites (lighting that shows a sprite's bumps) need shaders too.
- Light can't be brighter than the scene's drawn colors: energy above 1 only helps colored lights
  reach white.
- Many lights with shadows over many occluders cost time each frame (every light checks every
  occluder near it). Dozens are fine.

## How it's stored

The scene's settings are on its root element, lights and occluders are nodes:

```xml
<scene name="Cave" lighting="true" ambient="#202436ff" bodyShadows="true">
	<node kind="Light2D" name="Torch" x="200" y="120" lightColor="#ffb060ff" energy="1.2" lightRadius="260"/>
	<node kind="Light2D" name="Flashlight" x="40" y="40" rotation="30" lightKind="Spot" spotAngle="40"/>
	<node kind="LightOccluder" name="Pillar" x="300" y="160" shape="Rectangle" width="40" height="120"/>
</scene>
```

## Questions

**Everything is black.** Add a Light2D, and check its Reach and Energy. Or raise the Ambient.

**My light goes through walls.** Tick its **Shadows**, and add LightOccluders (or tick **Static
bodies cast shadows** in the scene's settings, for walls that have collision).

**My HUD is dark.** Put it on a screen layer ([HUDs and menus stay lit](#huds-and-menus-stay-lit)).
