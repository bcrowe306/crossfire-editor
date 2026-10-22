---
title: Keyframe animation
description: "Animate any node's properties over time with Animator nodes and the Timeline: clips, tracks, keys, curves and events."
order: 22
---

# Keyframe animation (Animator and the Timeline)

An **Animator** node changes other nodes' properties over time: it moves, turns and scales them,
fades them, shows and hides them, changes a label's text or a script's values, and it can tell
your scripts when a moment comes. You set the values at a few moments, the **keys**, and the
Animator fills in the moments between them.

Use it for things that always happen the same way:

- a door that slides open, a platform that goes back and forth, a coin that bobs and spins
- a title that drops in and a menu that slides up
- a hit flash, a pulse, a shake
- a short cutscene: the camera moves, a character walks in, a line of text appears

(For a sprite's frame-by-frame drawing, use an AnimatedSprite and the Animation tab instead. An
Animator can tell an AnimatedSprite which of its animations to play.)

- [The words](#the-words)
- [Your first animation](#your-first-animation)
- [The Timeline tab](#the-timeline-tab)
- [What can be animated](#what-can-be-animated)
- [Curves: how a value moves between keys](#curves-how-a-value-moves-between-keys)
- [Events: calling your code at a moment](#events-calling-your-code-at-a-moment)
- [Playing clips](#playing-clips)
- [Animators in scripts](#animators-in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## The words

- **Animator**: the node that plays the animations. Put it **inside** the node it animates (as
  its child), or beside the nodes it animates (as their sibling).
- **Clip**: one animation, with a name ("open", "intro", "bob") and a length in seconds. An
  Animator can hold many clips and plays one at a time.
- **Track**: inside a clip, the changes of **one property of one node**: "the Door's position",
  "the Title's opacity". A clip can have many tracks, so many things can change at once.
- **Key**: a moment on a track and the value the property has then: "at 0.5 s, the position is
  100, 40".
- **Playhead**: the red line in the Timeline: the moment you're looking at.

## Your first animation

A box that slides to the right and back, forever:

1. **Add the Animator.** Select the node to animate (say a Sprite named Box), then **Add Node**
   (Ctrl+Shift+A) > **Animator**. It's added inside Box.
2. **Open the Timeline.** With the Animator selected, press **Edit in the Timeline** in the
   inspector (or open the bottom panel's **Timeline** tab).
3. **Make a clip.** Press **+ Clip**. It's called "clip" and lasts 1 second. Type a better name in
   **Name** ("slide"), set **Length** to 2, tick **Loop**.
4. **Add a track.** The **Track** choices show which node and which property: the node is "."
   (the Animator's parent: Box), the property **Position**. Press **+ Track**. The track gets its
   first key at the playhead (0 s), with Box's position now.
5. **Key the middle.** Click the ruler at 1 s (the playhead moves there). Now move Box in the
   viewport to where it should be at 1 s: select it and drag it right. The Timeline stays on the
   Animator. Press **Key**: a second key, at 1 s, with the new position.
6. **Key the end.** Click the ruler at 2 s. Move Box back where it started (or select the first
   key and copy its value), and press **Key**.
7. **Watch it.** Press **Play**. The viewport plays the clip; drag the playhead on the ruler to
   look at any moment. Moving any node afterwards shows the scene as it is again.
8. **Start it with the scene.** Press **Starts with this** (or set **First clip** in the
   inspector). Press **Play** (F5) to see it in the game.

Every change in the Timeline is a step for **Undo** (Ctrl+Z).

## The Timeline tab

**The clip row:**

| Control | What it does |
|---|---|
| **Clip** | The clip shown (★: the one the Animator starts with) |
| **+ Clip** | A new, empty clip of 1 second |
| **Name** | The clip's name; a name that's empty or another clip's isn't taken (it says why) |
| **Length** | The clip's length in seconds |
| **Loop** | At its end the clip starts again (else it stops there) |
| **Starts with this** | The Animator plays this clip when the scene starts |
| **Remove Clip** | Deletes the clip |
| **Manual** | Opens this page |

**The playing row:**

| Control | What it does |
|---|---|
| **Play / Pause** | Plays the clip in the viewport from the playhead |
| **To the Start** | The playhead back to 0 |
| **Track** (node, property) | What a new track animates: any node of the scene, and its properties |
| **+ Track** | Adds that track, with a key at the playhead holding the node's value now |
| **+ Event Track** | Adds a track of events ([Events](#events-calling-your-code-at-a-moment)) |

**The tracks:** one row per track: its name on the left, its keys (diamonds) on the right, under
the ruler.

| Mouse | Does |
|---|---|
| Click the ruler, or an empty spot | Moves the playhead there (drag to scrub) |
| Click a key | Selects it, and moves the playhead to it |
| Drag a key | Moves it in time, in steps of 0.05 s (hold Shift for any time) |
| Double-click a track | Adds a key there, from its node's value now |
| Click a track's name | Selects the track |

A track whose node can't be found (renamed, deleted, moved elsewhere) shows its name in orange.

**The selected track:**

| Control | What it does |
|---|---|
| **Key** | A key at the playhead with the node's value now (replaces a key already there) |
| **Steps** | The value jumps from key to key instead of moving between them |
| **Key All Tracks** | A key on every track of the clip, at the playhead |
| **Remove Track** | Deletes the track and its keys |

**The selected key:** **Key at** (its time), **Value** (type it; see the formats below),
**Curve to the next** (the easing to the next key) and **Remove Key**.

## What can be animated

| Property | Value | Notes |
|---|---|---|
| Position | `x, y` | Relative to the node's parent, like the inspector's |
| Position X, Position Y | a number | One axis only, so another track (or code) can move the other |
| Rotation | degrees | Clockwise; 360 is a full turn (more turns: 720...) |
| Scale | `x, y` | 1 is the normal size; negative mirrors |
| Scale X, Scale Y | a number | |
| Tint | `#rrggbb` or `#rrggbbaa` | Multiplies the node's colors (and its children's) |
| Opacity | 0 to 1 | 0 is invisible, 1 opaque (the tint's alpha) |
| Visible | `true` / `false` | Steps |
| Z index | a whole number | Draw order in its layer |
| Animation (AnimatedSprite) | an animation's name | Steps: plays that animation of the sprite |
| Text (Label) | text | Steps |
| Text color (Label) | `#rrggbb` | |
| A script's field (`speed (script)`) | the field's value | Numbers, `x, y` pairs and colors move; true/false, text and choices step. Shown once the scripts are built (Play or Build Scripts) |

Values are written as in the inspector: `12`, `-3.5`, `10, 40`, `#ff8000`, `true`.

## Curves: how a value moves between keys

Each key has a **curve** to the next key (**Curve to the next**). Linear moves at an even speed.
The others start or end slowly, which looks more natural:

| Curve | Moves |
|---|---|
| Linear | Evenly |
| InQuad, InCubic, InSine, InExpo | Starts slow, ends fast ("In") |
| OutQuad, OutCubic, OutSine, OutExpo | Starts fast, ends slow ("Out"): good for things arriving |
| InOutQuad, InOutCubic, InOutSine, InOutExpo | Slow at both ends: good for back and forth |
| InBack, OutBack, InOutBack | Goes a little past the end, then back |
| OutElastic | Springs past the end and settles |
| OutBounce | Bounces at the end, like a dropped ball |

A track with **Steps** ticked ignores curves: the value jumps at each key. True/false and text
values always step.

## Events: calling your code at a moment

An **event track** fires the Animator's **onEvent** event as each of its keys passes, with the
key's value (its name) as the data. Use it to play a footstep sound at the right frame, shake the
camera when the boss lands, or spawn the enemies when the cutscene ends.

1. **+ Event Track**, then **+ Event** at each moment (or double-click the track). Name each key
   in **Event** ("footstep", "land").
2. Select the Animator, open the inspector's **Events** section and **Listen...** to `onEvent`
   with the node whose script should react. The editor writes the handler into that script
   (here a Hero script with a `step: e.SoundAsset` field):

```odin
Hero_onAnimEvent :: proc(self: ^Hero, source: ^e.Node, data: e.EventData) {
	name := data.(string)
	switch name {
	case "footstep": e.Game_PlaySound(self.game, self.step)
	case "land":     e.Camera2D_Shake(self.scene.camera, 6, 0.3)
	}
}
```

The Animator also fires **onFinished** (data: the clip's name) when a clip that doesn't loop
reaches its end.

## Playing clips

- **First clip** (the inspector) or **Starts with this** (the Timeline): the Animator plays it
  when the scene starts. With none, it waits for a script.
- **Clip speed** (the inspector): 2 plays twice as fast, 0.5 half as fast, 0 holds.
- A clip that doesn't loop stops on its last values.
- The Animator follows its **Process** mode like any node: a paused scene pauses it (unless it's
  set to run while paused, for a pause menu's animation).
- In the editor, Animators don't play by themselves: the Timeline shows them.

## Animators in scripts

Give the script a field for the Animator (drag the Animator from the scene tree onto the code,
or write it), then:

```odin
Door :: struct {
	using script: e.Script,
	anim: ^e.Animator `export:"default=Anim"`,
}

Door_open :: proc(self: ^Door) {
	e.Animator_Play(self.anim, "open")
}
```

| Procedure | What it does |
|---|---|
| `e.Animator_Play(anim, "open")` | Plays a clip from its start (`restart = true` starts the playing one again; a paused one resumes) |
| `e.Animator_Stop(anim)` | Stops; `reset = true` puts the clip's first values back |
| `e.Animator_Pause(anim, true)` | Pauses (false resumes) |
| `e.Animator_Seek(anim, 0.5)` | Jumps to a time |
| `e.Animator_IsPlaying(anim)` | Whether a clip is playing |
| `e.Animator_CurrentClip(anim)` | The clip's name |
| `anim.speed = 2` | How fast it plays |
| `e.Animator_SetClips(anim, settings)` | Replaces its clips with clips made in code |

## How it's stored

The clips are part of the scene file, inside the Animator's node:

```xml
<node kind="Animator" name="Anim" autoplay="slide">
	<clip name="slide" length="2" loop="true">
		<track node="." property="position">
			<key time="0" value="0, 0" ease="InOutSine"/>
			<key time="1" value="100, 0" ease="InOutSine"/>
			<key time="2" value="0, 0"/>
		</track>
		<track property="event">
			<key time="1" value="turn"/>
		</track>
	</clip>
</node>
```

A track's `node` is a path from the Animator's parent: `.` is the parent itself, `Box` a node
beside the Animator, `Box/Lid` a child of Box, `/World/Box` from the top of the scene.

## Questions

**I moved the node but the viewport shows it elsewhere.** The viewport was showing the clip at the
playhead. Any edit of a node goes back to showing the scene as it is; scrubbing or playing shows
the clip again.

**My track's name is orange.** Its node isn't where its path says: it was renamed, deleted or
moved. Remove the track and add it again for the node.

**The node doesn't move in the game, but does in the Timeline.** Check the Animator plays: give it
a **First clip**, or play a clip from a script. A script that sets the same property every frame
wins over the Animator if it runs after it.

**Can several Animators animate the same node?** Yes, but if two tracks set the same property, the
last one to run wins. Animate different properties (Position X in one, Position Y in another).
