---
title: The sprite sheet slicer
description: Cut a sprite sheet into frames by a grid or by finding its sprites, pick frames, name animations from them with their speed and frame times, and make an animation asset, give them to an AnimatedSprite or add a new one.
order: 5
---

# The sprite sheet slicer

A sprite sheet is one picture holding many frames: a walk cycle in a row, an idle in the next, a
jump below. The **sprite sheet slicer** cuts such a picture into frames and turns them into named
animations ("idle", "run", "jump") in a few clicks: it opens the sheet in a tab of its own beside
your scenes, you cut it by a grid or let it find the sprites, pick the frames of each animation on
the picture, and then make them an **animation asset**, give them to an **AnimatedSprite**, or add
a new AnimatedSprite playing them.

The animations it makes are ordinary ones: the [Animation panel](sprites_and_images.md#the-animation-panel)
edits them afterwards, [state machines](state_machines.md) play them by name, and scripts play
them with the AnimatedSprite's animation player (`e.AnimationPlayer_Play`).

- [Opening it](#opening-it)
- [The tab](#the-tab)
- [Cutting the sheet by a grid](#cutting-the-sheet-by-a-grid)
- [Finding the sprites](#finding-the-sprites)
- [Picking frames](#picking-frames)
- [Naming animations](#naming-animations)
- [Making something of them](#making-something-of-them)
- [In scripts](#in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Opening it

- Select a picture in the browser: its preview has **Slice Sprite Sheet…**. Or right-click the
  picture > **Slice Sprite Sheet…**.
- Drag a picture from the browser onto the tabs above the viewport.
- In the [Animation panel](sprites_and_images.md#the-animation-panel), **Slice a sheet…** opens the
  selected animation's sheet.

Each picture gets one tab (its name with a pair of scissors), after the scene and code tabs. Click
a scene tab to go back to the scene; the slicer's tab stays open. Its **×**, a middle click or
Ctrl+W closes it. The tab remembers everything about its picture (the grid, the sprites found,
the animations named): close it, open it again tomorrow, and it's as you left it.

## The tab

The picture fills the tab's left side, on a checkerboard where it's transparent, with every frame
outlined. The column on the right (under the picture when the window is narrow) has the controls,
from top to bottom: how the sheet is cut, the frames picked, the animations, and what to make.

| On the picture | Does |
|---|---|
| Wheel | Zooms around the pointer (with Settings > Editor > Wheel pans: pans; Ctrl + wheel zooms) |
| Middle or right drag, Space + drag | Pans |
| **Fit** (above the picture) | Fits the whole sheet in view |
| The zoom (above the picture) | Back to 100% |
| **Manual** | Opens this page |

Picked frames are tinted and numbered in their order; the frames of the animation you're editing
are outlined in orange, the frame picked in its strip more thickly.

## Cutting the sheet by a grid

**Slice by: A grid** cuts the sheet into cells of one size, numbered left to right, then top to
bottom, from 0.

| Setting | What it does |
|---|---|
| **Grid by** | **Cell count** (so many columns and rows share the sheet) or **Cell size** (a cell's width and height in pixels: as many as fit) |
| **Columns**, **Rows** | Cells across and down (Cell count) |
| **Cell width**, **Cell height** | A cell's size in pixels (Cell size) |
| **Margin** | Pixels around the grid, left out of every cell |
| **Cell gap** | Pixels between neighbouring cells |
| **Start X**, **Start Y** | Where the grid starts: pixels from the sheet's left edge and top. For a sheet with a title, or a row of something else, above or beside the frames |

Under them, the other way of saying it (the cells' size, or how many fit) and, with Cell size,
the pixels left over at the right and bottom (in no frame). A new sheet starts as one cell, or
as a row of square cells when it's a strip exactly so many heights wide.

## Finding the sprites

Sheets of **uneven sprites** (packed by hand, a frame wider than the next, a sword sticking out of
one) have no grid. **Slice by: Its sprites (auto-detect)** finds them: every island of opaque
pixels is a sprite, boxed, in reading order (rows top to bottom, each left to right).

| Setting | What it does |
|---|---|
| **Alpha at least** | How opaque a pixel must be to count (1-255). A sheet without transparency (sprites on a flat color) uses its top-left pixel's color as the background |
| **Merge within** | Pieces this many pixels apart or closer are one sprite: a sword a pixel away from its hand, a puff of dust beside a jump. 0: only touching pixels |
| **Smallest** | Sprites smaller than this many pixels both ways are left out (stray pixels) |
| **Same size frames** | Each animation's frames are made as big as its biggest, lined up at their bottom middle, so a character's feet stay put as it plays (unticked: each frame its own size, drawn centered) |
| **Find Sprites** | Looks again (after changing the settings above); the line under it says how many it found and how long it took |

It's quick: a 4096 × 4096 sheet takes a fraction of a second, and a sheet that big is looked at in
the background while you go on.

## Picking frames

Click frames on the picture:

- **click**: just that frame;
- **Ctrl+click**: adds a frame, or takes it away (on a Mac, Cmd+click);
- **Shift+click**: every frame from the last one clicked to this one, in that direction (click a
  row's first frame, Shift+click its last: the row);
- **Row**, **All**, **None**: the last clicked frame's row, every frame, nothing;
- **Reverse**: the picked frames the other way round.

**The order you pick them in is the order they play.** Ctrl+click frames 5, 2, 3 and the
animation plays 5, 2, 3.

## Naming animations

| Button | Does |
|---|---|
| **New from Picked** | A new animation of the picked frames, in their order (looping, 8 frames a second) |
| **One per Row** | An animation per row of frames (`row1`, `row2`...): the picked frames' rows, else every row. A sheet with an idle row, a run row and a jump row becomes three animations at once: rename them |
| **Set Frames to Picked** | The animation you're editing gets the picked frames instead |

The animations are listed under them; click one to edit it (its frames become the picked ones,
outlined on the picture). ↑ and ↓ move it in the list, **Remove** deletes it.

| Setting | What it does |
|---|---|
| **Animation name** | What scripts and state machines play it by. Two can't share a name; a name being typed that can't be one turns red and waits |
| **FPS** | Frames per second |
| **Loop** | Plays again from the start when it ends |
| **Play mode** | **Forward**, **Reverse**, **PingPong** (there and back), **PingPongReverse** |
| **Frame times** | Each frame its own time in milliseconds instead of one speed for all: hold a pose, snap through a swing |

Under them the **preview** plays the animation as the game will (its button plays and pauses it),
and the **frame strip** shows its frames in order: click one, then **Earlier** or **Later** moves
it (with its time), **Take Out** removes it.

## Making something of them

| Button | Does |
|---|---|
| **Create Animation Asset** | Makes `animations/<name>.anim.xml` from the animations (the **Asset name**, else the picture's name): an [animation asset](sprites_and_images.md#animation-assets-animations-sprites-share) any number of sprites can play. It's written when you save the project. Pressed again, it's **Update <asset>**: the same file gets the animations as they are now |
| **Apply to <sprite>** | The AnimatedSprite selected in the scene tree plays them: the asset (with **Use the asset** ticked, once there is one), or the animations themselves as its own (replacing the ones it had) |
| **Add to Scene** | A new AnimatedSprite, named after the picture, playing them (the asset, or its own), in the middle of the view |

Each is one step **Ctrl+Z** undoes: the asset goes from the project again (Save writes nothing
for it), the sprite plays what it played before, the new sprite goes. The slicer's own settings
(the grid, the picks, the animations named) aren't undo steps: they're the tab's, remembered as
they are.

**Run of frames or rectangles?** An animation whose frames are a run of a grid's cells in order
(3, 4, 5, 6) is saved as the grid and its first and last frame, so the Animation panel edits it
like any other. Any other (frames out of order, or found sprites) is saved with each frame's
rectangle on the sheet: the Animation panel then says "N frames sliced from the sheet" instead
of the grid, and **Use a grid instead** turns it back into a grid animation. **Slice a sheet…**
opens the slicer again.

**In the node guides:** the [AnimatedSprite](nodes_graphics.md#animatedsprite) is the node that
plays them (its animation player is the "animation player" of other engines); for animations of
any property over time (positions, colors, a script's fields) use an
[Animator and the Timeline](animation.md) instead.

## In scripts

Every animation gets a constant in `scripts/assets.odin` once the project is saved: an asset's
`ANIM_<ASSET>_<NAME>` (`ANIM_HERO_RUN` for "run" in `animations/hero.anim.xml`) and the asset's
own `ANIMATION_<ASSET>`; a sprite's own animations `ANIM_<SCENE>_<SPRITE>_<NAME>`. Drag the
animation (the Animation panel's grip) into a code tab to write them for you.

```odin
// Given: sprite: ^e.AnimatedSprite, ANIM_HERO_RUN: e.AnimationName, ANIMATION_HERO: e.AnimationAsset
// The sprite plays the asset the slicer made, starting with "run"
e.AnimatedSprite_UseAnimations(sprite, ANIMATION_HERO, ANIM_HERO_RUN)
// Later: switch animations by name
e.AnimationPlayer_Play(&sprite.animation, ANIM_HERO_RUN)
```

A game can find sprites on a sheet too: `e.Sheet_FindSprites` returns their boxes, and
`e.CreateRectSheetAnimation` makes an animation of rectangles of a texture.

## How it's stored

The animations it makes are ordinary `<animation>` elements (in an `.anim.xml` file, or a scene
file for a sprite's own):

```xml
<animation name="idle" sheet="assets/hero.png" columns="8" rows="3" offsetY="16" start="0" end="7" fps="8" loop="true"/>
<animation name="slash" sheet="assets/hero.png" rects="0,64,40,32 44,60,52,36 100,62,48,34" fps="12"/>
```

`offsetX` / `offsetY` say where a grid starts; `rects` lists each frame's rectangle (`x,y,w,h`
in pixels), used instead of the grid. Editors and engines from before these were added read the
grid only: a `rects` animation then plays the sheet's cells instead.

The tab's own settings are in the project's `.editor/slicer.ini`, a section per picture (the
`.editor` folder is your own editor state: version control can leave it out).

## Questions

**The grid's frames show bits of their neighbours.** The grid is off: check Columns and Rows (or
the cell size), Margin, Cell gap and Start against the sheet. Zoom in on the picture: the
outlines should sit between the frames.

**Auto-detect makes one sprite of two frames.** They're closer than **Merge within**: lower it.
It splits a sprite in two (a sword, a shadow): raise it.

**Auto-detect finds nothing on my sheet.** The sheet may be opaque everywhere with a background
that isn't one flat color: use a grid, or make the background transparent in your paint program.
With faint sprites, lower **Alpha at least**.

**My character bobs up and down as it plays.** Its frames are different sizes: tick **Same size
frames** and make the animation again.

**Apply to Sprite is greyed out.** Select an AnimatedSprite in the scene tree (the slicer's tab
stays open), and name an animation first.

**I made the asset but the file isn't there.** It's written when you save (Ctrl+S), like other
changes to animation assets.

**Can I slice an Aseprite file?** Its first frame, yes; but an Aseprite file's tags are already
animations (see [Aseprite files](sprites_and_images.md#aseprite-files)), so you rarely need to.
