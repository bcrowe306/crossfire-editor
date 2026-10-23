---
title: Sprites and images
description: Show pictures with Sprite nodes, play sprite-sheet animations with AnimatedSprite and the Animation panel, share animations as assets, use Aseprite files with their tags, layers and slices, and write text with Labels.
order: 4
---

# Sprites and images

Most of what a 2D game shows is pictures: the hero, the enemies, the coins, the background. A
**Sprite** node draws a picture. An **AnimatedSprite** plays a **sprite sheet**, a picture made of
many frames side by side (a walk cycle, a spinning coin), like a flip book. A **Label** writes a
line of text. This page covers all three, and pictures drawn in Aseprite.

- [Bringing in pictures](#bringing-in-pictures)
- [Sprites](#sprites)
- [Animated sprites](#animated-sprites)
- [The Animation panel](#the-animation-panel)
- [Animation assets: animations sprites share](#animation-assets-animations-sprites-share)
- [Aseprite files](#aseprite-files)
- [Labels: text on the screen](#labels-text-on-the-screen)
- [In scripts](#in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Bringing in pictures

**Import** a picture with the **+** at the top of the browser, or Ctrl+I. The editor copies it into
your project's `assets/` folder (a file already inside the project is used where it is), and it
shows in the browser's **Images** folder. Click it: the preview under the browser shows the
picture, its size and its file size.

The editor takes PNG, JPEG, BMP, GIF, TGA, WebP, QOI and Aseprite (`.aseprite`, `.ase`) files.
Games exported for the web can only show PNG and BMP so far.

Pixel art looking blurry? See [Asset import settings](asset_import.md) for pixel-sharp filtering,
and for packing many small pictures into one atlas.

## Sprites

The quickest way: **drag the picture from the browser into the viewport.** A Sprite named after the
file appears where you let go, inside the selected node (or at the top of the scene). Or **Add
Node** (Ctrl+Shift+A) > **Sprite** and choose its picture in the inspector.

| Setting | What it does |
|---|---|
| **Texture** | The picture it draws: any image of the project, or a texture atlas |
| **Region** | With an atlas: which of its pictures (see [Asset import settings](asset_import.md)) |

The picture is drawn **centered on the node's position**. Turn it, grow it or mirror it with the
node's Rotation and Scale (a Scale X of -1 faces it the other way), like any node (see [Scenes and
nodes](scenes_and_nodes.md)).

A picture you change in another program and save again updates in the viewport on its own, and in
a game started with Play too.

## Animated sprites

1. **Add Node** > **AnimatedSprite**.
2. In the inspector, **Edit Animations**: the bottom panel's **Animation** tab opens on it.
3. **Sheet**: the sprite sheet's picture (or drag the picture from the browser onto the panel).
4. **Grid**: how the sheet is cut into frames, either
   - **Cells**: how many frames across and down. A strip of 8 frames in one row is 8 × 1; or
   - **Size**: one frame's width and height in pixels (32 × 32): the panel works out how many fit.
5. If your sheet has a border or gaps between frames: **Margin** (pixels around the edge before
   the first frame) and **Gap** (pixels between frames).

The sprite starts with one animation, **default**: every frame, looping, at 8 frames a second.
Press **P** (or the play button above the viewport) to see it play in the viewport.

**Every animation has its own sheet.** An "idle" can come from `hero_idle.png` and a "run" from
`hero_run.png`, each with its own grid; or they can share one sheet, using different frames of
it. A new animation starts on the sheet of the one you were editing.

Its other inspector rows:

| Setting | What it does |
|---|---|
| **Animations** | **its own** animations, or an animation asset's ([below](#animation-assets-animations-sprites-share)) |
| **Sheets** | The sheets its animations use (each animation's is set in the Animation panel) |
| **Starts with** | The animation it plays when the scene starts (the first one, unless you pick another) |
| **N animations** / **Edit Animations** | Opens the Animation panel on this sprite |
| **Save as Animation Asset** | Makes its animations (and their sheets) a file other sprites can use |

Like Sprites, AnimatedSprites are drawn centered on their position.

## The Animation panel

A sprite usually has several animations: "idle", "run", "jump". Each plays some frames of its
own sheet: frames 0 to 3 of one sheet, or 4 to 9 of the same one, or every frame of another. The
bottom panel's **Animation** tab (the inspector's **Edit Animations** opens it) names them and
sets each one's sheet, frames and speed.

**Its toolbar:**

| Control | What it does |
|---|---|
| The dropdown | Which animation you're editing. ★ marks the one the sprite starts with |
| **+** | A new animation: every frame of the sheet the selected one uses |
| Copy, trash, ↑, ↓ | Duplicate it, remove it (a sprite keeps at least one), move it up or down the list |
| **Name** | Its name: what scripts play it by. Two animations can't share a name |
| **★ Starts with this** | The sprite plays it when the scene starts |
| **Sheet** | Its sprite sheet's picture. Dragging a picture from the browser onto the panel sets it too |
| **Grid** | How its sheet is cut into frames: **Cells** (so many across × down) or **Size** (a frame's width × height in pixels). Beside it, the other one, worked out from the picture: the frames' size, or how many fit. With **Size**, pixels the frames don't fill at the right or bottom are left out of every frame, and the panel says how many ("Left over: 12 px on the right"); with **Cells**, it warns when frames aren't whole pixels |
| **Margin**, **Gap** | Pixels around the sheet's edge before the first frame, and between frames |
| **Frames** ... **to** ... | Its first and last frame |
| **Count** | How many frames it plays from its first (sets the last). Change either the last frame or the count: the other follows |
| **FPS** | Frames per second: how fast it plays |
| **Loop** | Plays again from the start when it ends; unticked, it stops on its last frame |
| **Plays** ... **times** | Without Loop: how many times it plays before stopping. A ping-pong counts **passes**, one way each, as Aseprite does: 2 is there and back, 3 ends on the far frame |
| **Frame times** | Ticked, each frame gets its own time in milliseconds (a field per frame, starting at the FPS's time): hold a pose longer, snap through a swing. Unticked, FPS times them all |
| The mode | **Forward**, **Reverse** (last frame to first), **PingPong** (there and back), **PingPongReverse** (back and there) |

The toolbar's controls wrap onto more lines when the panel is narrow.

**Under the toolbar**, the preview plays the animation (its play button pauses it) and shows which
frame it's on. Beside it, every frame of the animation's sheet as a thumbnail, numbered, the
animation's frames lit:

- **click** a frame: the animation starts there;
- **Shift+click** a frame: it ends there.

The viewport plays the animation you're editing on the sprite, so you see it in place. Every edit
can be undone. Renaming an animation renames it in the [state machines](state_machines.md) and
[Timeline](animation.md) keys that play it.

## Animation assets: animations sprites share

Ten enemies of the same kind should share one set of animations: change the "walk" once and all
ten change. An **animation asset** is such a set in a file of its own (`animations/<name>.anim.xml`):
its animations, each with its own sheet and grid.

**Making one:**

- select an AnimatedSprite whose animations are done, and press the inspector's **Save as
  Animation Asset**. The file is made from them (named after the sprite), and the sprite now plays
  it. Or
- once the browser has an **Animations** folder, right-click it > **New Animations**: an empty one
  opens in the Animation panel; pick its animation's sheet there.

**Using one:**

- drag it from the browser's **Animations** folder into the viewport: an AnimatedSprite playing it;
- or set an AnimatedSprite's **Animations** to it in the inspector.

**Editing one:** select it in the browser and right-click > **Edit Animations** (or select a
sprite using it and open the Animation panel). The panel's header says which file it is and how
many sprites use it. Changes show in every sprite using it. **Back to the sprite** goes back to the
selected sprite's animations.

An Aseprite file is an animation asset too, as it is: [below](#aseprite-files).

## Aseprite files

[Aseprite](https://www.aseprite.org) is a popular pixel-art editor. Its `.aseprite` files can go in
your project as they are, no exporting needed.

**As a picture:** import it and use it like any image (drag it in, a Sprite's Texture...). It
shows its **first frame**, with every visible layer. Save it in Aseprite and the viewport (and a
game running from Play) updates.

**The browser's preview** shows its size, frames, tags and layers, with:

- **Open in Aseprite**: opens the file in Aseprite (also in the right-click menu). If Aseprite
  isn't found, set **Edit > Settings... > Editor > Aseprite program** to where it's installed;
- **Animations**: shows its tags in the Animation panel (right-click > **Show Its Animations**
  does the same).

A file with **tilemap layers** makes a TileMap when dragged into the viewport instead: see
[Tilemaps](tilemaps.md).

### Tags as animations

In Aseprite, **tags** name ranges of frames ("idle", "run"). Set an AnimatedSprite's **Animations**
to the file, and each tag becomes an animation with that name:

- each frame keeps its own duration from Aseprite (the FPS doesn't apply);
- the tag's direction is the play mode (Forward, Reverse, Ping-pong, Ping-pong Reverse);
- a tag with a repeat count plays that many times; one without loops;
- a file without tags gives one animation, **default**, of every frame.

The Animation panel shows them, but they're edited in Aseprite: change them there, save, and the
editor follows. **Starts with** in the inspector picks the tag the sprite starts with.

**Frame events:** text you put in a cel's **User Data** in Aseprite (or an `event` property), on
any layer (a hidden "events" layer works well), is an **event** of that frame. When the frame
shows in the game, the sprite's `animation.onFrameEvent` event fires with that text: a footstep
sound, the moment a sword hits. The inspector lists them; listen to them from the node's
**Events** section (see [Scripts](scripts.md)).

### Layers

A Sprite or AnimatedSprite showing an Aseprite file lists the file's **layers** as checkboxes in
the inspector. Untick the ones it shouldn't draw. Two nodes can show two parts of the same file:
the body in one, the sword in another (one layer always stays ticked).

### Slices

Aseprite's **slices** are named rectangles drawn over the picture. The editor uses them three
ways:

| Slice | Where | What it does |
|---|---|---|
| A slice with a **pivot** | Sprite or AnimatedSprite: **Pivot slice** | That point of the picture is on the node's position, frame by frame, instead of the picture's middle: the feet stay put when the frames are different sizes |
| A **9-patch** slice (one with a center) | Sprite: **9-patch**, **9-patch size** | Draws that part stretched to the size you give (0: the slice's own); the corners keep their size, the edges and middle stretch. Panels, buttons, speech bubbles |
| Any slice | CollisionShape: **Slice** | The shape takes the slice's rectangle, frame by frame: a **hitbox** that follows the animation (a sword's reach on the attack frames). It's off where the slice is hidden |

A CollisionShape's Slice follows the nearest Sprite or AnimatedSprite showing an Aseprite file
(one of its parents, or a child of one). See [Physics](physics.md) for bodies and shapes.

## Labels: text on the screen

**Add Node** > **Label** (under User interface).

| Setting | What it does |
|---|---|
| **Text** | The words shown. Text starting with `@` is a translation key (`@menu.play`), shown in the player's language |
| **Font size** | The text's size in pixels |
| **Color** | Its color |
| **Centered** | Ticked, the text is centered on the node's position; unticked, its top-left corner is there |

Labels draw in the built-in font. For your own fonts, wrapped text, several colors or sizes, use
the UI controls (a **RichText**, a **Button**) with a theme: see [The UI system](ui.md).

A Label follows its parent's position, but isn't rotated or scaled with it. To keep text fixed on
the screen while the camera moves (a score, a HUD), put it on one of the scene's **screen
layers** (see [Scenes and nodes](scenes_and_nodes.md)).

## In scripts

Switch animations from a script on the AnimatedSprite: a hero that runs while a key is held and
stands still otherwise.

```odin
Hero :: struct {
	using script: e.Script,
}

@(init)
register_Hero :: proc "contextless" () {
	e.Script_Register(Hero, {
		update = proc(self: ^Hero, events: []sdl.Event, dt: f64) {
			if !e.Node_Is(self.node, e.AnimatedSprite) do return
			sprite := cast(^e.AnimatedSprite)self.node
			if e.Input_IsActionPressed("ui_right", self.game) || e.Input_IsActionPressed("ui_left", self.game) {
				e.AnimationPlayer_Play(&sprite.animation, "run")
			} else {
				e.AnimationPlayer_Play(&sprite.animation, "idle")
			}
		},
	})
}
```

Playing the animation that's already playing does nothing, so calling it every frame is fine.

| Code | What it does |
|---|---|
| `e.AnimationPlayer_Play(&sprite.animation, "jump")` | Plays an animation by its name |
| `e.AnimationPlayer_Play(&sprite.animation, "jump", restart = true)` | Starts it again from its first frame, even if it's playing |
| `e.AnimationPlayer_IsPlaying(&sprite.animation, "jump")` | Whether that one is playing |
| `e.AnimationPlayer_CurrentName(&sprite.animation)` | The name of the one playing |
| `e.AnimationPlayer_Pause`, `_Resume`, `_Stop` | Pause, carry on, stop |
| `sprite.animation.speed = 2` | Plays twice as fast (0 freezes it) |
| `e.AnimatedSprite_UseAnimations(sprite, ANIMATION_HERO_ARMORED, "idle")` | Switches to another animation asset (`ANIMATION_...` constants are in `scripts/assets.odin`) |

The sprite's `animation` also has events to listen to: `onAnimationEnded` (an animation that
doesn't loop finished), `onAnimationLooped`, `onFrameChanged`, `onFrameEvent`.

A Label's text and color from a script, every frame:

```odin
ScoreLabel :: struct {
	using script: e.Script,
	score: int,
}

@(init)
register_ScoreLabel :: proc "contextless" () {
	e.Script_Register(ScoreLabel, {
		update = proc(self: ^ScoreLabel, events: []sdl.Event, dt: f64) {
			if !e.Node_Is(self.node, e.Label) do return
			label := cast(^e.Label)self.node
			label.text = fmt.tprintf("Score: %d", self.score)
			label.color = self.score >= 100 ? {255, 215, 0, 255} : {255, 255, 255, 255}
		},
	})
}
```

Text made with `fmt.tprintf` only lasts until the end of the frame, so set it every frame (as
here) or keep the string yourself. These examples use `import e "engine:."`, `import sdl
"vendor:sdl3"` and `import "core:fmt"`; [Scripts](scripts.md) explains how a script is made and
attached.

## How it's stored

```xml
<node kind="Sprite" name="Tree" x="200" y="300" texture="assets/tree.png"/>
<node kind="AnimatedSprite" name="Coin" x="400" y="300" autoplay="spin">
	<animation name="spin" sheet="assets/coin.png" columns="8" rows="1" start="0" end="7" fps="12" loop="true"/>
	<animation name="sparkle" sheet="assets/sparkle.png" grid="Size" cellWidth="16" cellHeight="16" spacing="1" fps="20"/>
</node>
<node kind="AnimatedSprite" name="Hero" x="100" y="500" animations="assets/hero.aseprite" autoplay="idle"/>
<node kind="Label" name="Title" x="640" y="80" text="My Game" fontSize="48" color="#ffd700"/>
```

Each `<animation>` names its own `sheet` and grid: `columns` × `rows`, or `grid="Size"` with
`cellWidth` × `cellHeight`, plus `margin` and `spacing`. Files saved by older versions had one
sheet on the node (`texture`, `columns`, `rows`): they open as before, every animation on that
sheet.

## Questions

**My sprite sheet shows all its frames at once, tiny.** Set the animation's **Grid**: its
columns and rows, or with **Size** a frame's width and height.

**The animation shows bits of the next frame.** The grid is off: check the Grid, Margin and Gap
against the sheet.

**My animations need different sheets.** Give each its own: pick the animation in the Animation
panel's dropdown and set its **Sheet**.

**My animation doesn't play in the viewport.** Press **P**, or the play button above the viewport.

**I can't edit an Aseprite file's animations in the panel.** They come from its tags: change them
in Aseprite (**Open in Aseprite**) and save.

**The character jitters when its frames are different sizes.** Give the file a slice with a pivot
(at the feet) in Aseprite, and pick it as the sprite's **Pivot slice**.

**My score scrolls off the screen when the camera moves.** Labels are in the world like any node.
Put it on a layer, and tick that layer in the scene's **Screen layers**, to keep it in place.
