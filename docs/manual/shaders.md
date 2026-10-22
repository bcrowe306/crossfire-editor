---
title: Shaders and screen effects
description: Change how nodes are drawn with built-in effects (hit flash, outline, dissolve, palette swap) or your own GLSL shaders, and put CRT, bloom or color grading over the whole screen.
order: 16
---

# Shaders and screen effects

A **shader** is a small program the graphics card runs for every pixel a node draws. It can
change the color of each pixel: flash a hit enemy white, outline a selected unit, dissolve a dead
monster, recolor a team's units, or make the whole screen look like an old TV.

The engine ships seven **built-in effects**, and you can write **your own** shaders in GLSL.

- [Where shaders run](#where-shaders-run)
- [A shader on a node](#a-shader-on-a-node)
- [The built-in effects](#the-built-in-effects)
- [Screen effects](#screen-effects)
- [Writing your own shader](#writing-your-own-shader)
- [In scripts and animations](#in-scripts-and-animations)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Where shaders run

Shaders run on **SDL's GPU renderer**. A project that uses any shader picks it by itself when its
**Renderer** (Project Settings > General) is **Auto** (the default), or when it's set to **GPU**.
With another renderer, nodes draw as if they had no shader; the inspector warns about it.

- **Linux and Windows** run shaders through Vulkan, **macOS** through Metal.
- **Web exports** don't run shaders: nodes draw without them.
- Without the GPU renderer, the **hit flash** still brightens the picture, as an approximation.
  The other effects do nothing.

The viewport shows shaders as the game will. When the open scene uses one, the editor draws it
with the same GPU renderer.

## A shader on a node

1. Select a node that draws something: a Sprite, AnimatedSprite, Label, TileMap, LDtkLevel,
   ParticleEmitter (with a texture), a UI control, or a parent of such nodes (a character's body,
   a Node2D grouping sprites).
2. In the inspector's **Shader** section, choose one: **Built-in: Hit flash**, **Outline**,
   **Dissolve**, **Palette swap**, the screen effects, or one of your project's shaders.
3. Its **parameters** appear under it: sliders for numbers, color pickers for colors, text
   (`1, 2`) for vectors. Every slider's reset button puts it back to the shader's default.

A shader colors **the node and its children**, unless a child has a shader of its own. Put a hit
flash on a character's body, and the sprite under it flashes too.

It colors what's drawn **from images and text**: sprites, animation frames, tiles, letters,
textured particles. Shapes drawn with lines and fills (debug shapes, particles without a
texture, a progress bar's fill) aren't affected.

Every change is an undo step; a slider's drag is one step.

## The built-in effects

**For nodes:**

| Effect | Parameters | Use it for |
|---|---|---|
| **Hit flash** | **Flash color** (white), **Amount** 0 to 1 | A hit, a pickup: set Amount to 1, then fade it to 0 |
| **Outline** | **Outline color**, **Width** in pixels | Selection, highlights, an item you can pick up |
| **Dissolve** | **Amount** 0 (whole) to 1 (gone), **Edge color**, **Edge width**, **Noise scale** | Deaths, teleports, things burning away |
| **Palette swap** | **Color 1-4** and what each **Becomes**, **Tolerance** | Team colors, skins, damaged versions |

The outline is drawn on the transparent pixels next to the picture, so the picture needs
transparent room around it. In a sprite sheet, leave a gap between frames.

**For the screen** (on a ScreenEffect node, below; they work on nodes too):

| Effect | Parameters | Use it for |
|---|---|---|
| **CRT** | **Scanlines**, **Curve**, **Dark border**, **Grille**, **Brightness** | A retro TV look |
| **Bloom** | **Threshold** (how bright glows), **Intensity**, **Radius** in pixels | Glowing lights, magic, neon |
| **Color grading** | **Brightness**, **Contrast**, **Saturation** (0: gray), **Tint**, **Vignette** | Mood: a gray flashback, a red alarm, a dark cave |

## Screen effects

A **ScreenEffect** node runs its effect over the whole scene as it's drawn.

1. **Add Node > ScreenEffect** (under Graphics). Where it is in the tree doesn't matter.
2. Choose its **Effect** and set its parameters.
3. **Covers screen layers** (on by default) applies the effect to the scene's screen layers too
   (the HUD). Off, the HUD draws on top, untouched.

Several ScreenEffects run one after the other, in the order they were added: color grading,
then CRT. Hide one (untick its **Visible** in the inspector, or `visible = false` from a script) to turn
it off.

## Writing your own shader

1. In a node's Shader section, press **New Shader** (once the project has one, a shader's
   right-click menu in the browser's Shaders folder has New Shader too). A file is made in `assets/shaders/` (`shader.frag`) and opens in a code tab.
2. Edit it and **save** (Ctrl+S). The editor compiles it, and any mistake shows in the Console
   with the line: `assets/shaders/shader.frag:21: 'colr' : undeclared identifier`.
3. Give it to nodes like the built-in ones; its parameters show in the inspector.

The template, explained:

```glsl
#version 450
layout(location = 0) in vec4 v_color;   // the node's tint and opacity
layout(location = 1) in vec2 v_uv;      // where in the picture, 0 to 1
layout(location = 0) out vec4 o_color;  // the pixel's color
layout(set = 2, binding = 0) uniform sampler2D u_texture;   // the picture
layout(set = 3, binding = 0) uniform Params {
	vec4 tint;        // color default=#4fc3f7 label=Tint
	float strength;   // default=0.5 min=0 max=1 label=Strength
	float speed;      // default=2 min=0 max=10 label=Pulse speed
	float time;       // filled by the engine: seconds the game has run
};
void main() {
	vec4 c = texture(u_texture, v_uv) * v_color;
	float pulse = 0.5 + 0.5 * sin(time * speed);
	o_color = vec4(mix(c.rgb, tint.rgb, strength * pulse), c.a);
}
```

The rules:
- It's a **GLSL 450 fragment shader**. Keep the first lines as they are: the inputs, the output
  and the picture are what the engine gives every shader.
- **Parameters** are the members of the `Params` block, one per line: `float`, `vec2`, `vec3`
  or `vec4`. The comment after each tells the inspector about it:
  - `default=0.5`: its starting value (vectors: `default=1, 2`; colors: `default=#ff8000`)
  - `min=0 max=1`: a slider's range (numbers)
  - `label=Glow strength`: what the inspector calls it (the rest of the comment)
  - `color`: a `vec4` shown as a color picker
- Three names are **filled by the engine**, not shown in the inspector: `time` (seconds the game
  has run), `texelSize` (1 divided by the picture's size: one pixel, in `v_uv` units) and
  `textureSize` (the picture's size in pixels).
- `main` must use `Params`: a block nothing reads is dropped by the compiler, and its values
  don't arrive.

The compilers (glslang and SDL_shadercross) come with releases; Settings > Toolchain shows
**Shader compiler**. From a source checkout, build them once with the engine's
`tools/build_shader_tools.sh` (`task shadertools` in the editor's folder). The editor compiles
changed shaders on save, before Play and before exports, into a `.frag.shader` file beside each
`.frag`; games load that file.

## In scripts and animations

```odin
Enemy :: struct {
	using script: e.Script,
	flash: f32,
}

// Hit: flash red, fading over a quarter second in update
Enemy_hit :: proc(self: ^Enemy) {
	e.Node_SetShader(self.node, "builtin:hit_flash")
	e.Node_SetShaderParam(self.node, "flashColor", sdl.Color{255, 60, 60, 255})
	self.flash = 1
}

Enemy_update :: proc(self: ^Enemy, events: []sdl.Event, deltaTime: f64) {
	if self.flash > 0 {
		self.flash = max(self.flash - f32(deltaTime) * 4, 0)
		e.Node_SetShaderParam(self.node, "amount", self.flash)
	}
}
```

| Procedure | What it does |
|---|---|
| `e.Node_SetShader(node, path)` | Gives a node a shader (`"builtin:outline"`, `SHADER_WAVE`, or `""` for none), with its defaults |
| `e.Node_SetShaderParam(node, name, value)` | Sets a parameter: a number, `[2]f32`, `[4]f32` or `sdl.Color` |
| `e.Node_GetShaderParam(node, name)` | A parameter's value |
| `e.Node_ResetShaderParams(node)` | Every parameter back to the shader's default |
| `e.CreateScreenEffect(scene, path)` | A ScreenEffect from code |

Your project's shaders get constants in `scripts/assets.odin`: `SHADER_WAVE :: "assets/shaders/wave.frag"`.

**Animator tracks:** a shader's numbers, vectors and colors can be keyframed in the Timeline as
`shader.<name>` properties (`shader.amount`). A hit flash is a clip of two keys: 1 at 0 s, 0 at
0.2 s.

## How it's stored

A node's shader is its `shader` attribute, and the parameters you changed are `<shaderParam>`
children (the others keep the shader's defaults):

```xml
<node name="Hero" kind="Sprite" texture="assets/hero.png" shader="builtin:hit_flash">
	<shaderParam name="flashColor" value="#ff3c3c"/>
</node>
<node name="TV" kind="ScreenEffect" shader="builtin:crt" effectScreenLayers="false">
	<shaderParam name="scanlines" value="0.8"/>
</node>
```

`project.xml` says `shaders="true"` when a scene uses any: that's how Auto knows to pick the GPU
renderer. Exports carry each shader's compiled `.frag.shader` file.

## Questions

**My shader shows nothing different.** Check the Console for compile errors, that the project's
Renderer is Auto or GPU, and that `main` reads the parameters you're changing.

**The outline is cut off at the picture's edge.** It's drawn in the picture's transparent
border: add a few transparent pixels around the image.

**Can I use HLSL?** Not yet: shaders are GLSL. The engine compiles them to SPIR-V (Vulkan) and
MSL (Metal).

**Do shaders work on Windows without Vulkan?** The GPU renderer is asked for Vulkan there.
Without a Vulkan driver it falls back to Direct3D 12, which can't run these shaders, and nodes draw
without them.
