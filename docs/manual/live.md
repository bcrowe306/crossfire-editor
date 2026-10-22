---
title: The Live tab
description: "Watch and change the game running from Play: its nodes and values, frame times, pause and step a frame."
order: 32
---

# The Live tab: the running game, as it plays

When you press **Play** (F5), your game runs in its own window. The bottom panel's **Live** tab
shows that running game from inside the editor: what's in the scene that's playing, any node's
values (and you can change them while it runs), how long each frame takes, and buttons to
**pause** the game and **step** it one frame at a time.

Use it to find out why something misbehaves without adding log lines: is the enemy's speed what
you think? Is the door's collision shape where it should be? Which part of the frame is slow?

- [Opening it](#opening-it)
- [Pause and step](#pause-and-step)
- [Frame times: is the game fast enough?](#frame-times-is-the-game-fast-enough)
- [The running scene's nodes](#the-running-scenes-nodes)
- [Changing values while it runs](#changing-values-while-it-runs)
- [How it works](#how-it-works)
- [Questions](#questions)

## Opening it

1. Press **Play** (F5).
2. Open the bottom panel's **Live** tab (if the panel is narrow, scroll its tab strip sideways
   with the mouse wheel to reach it).

It shows "Press Play" while no game runs. Games started from the editor answer it; exported
games never do.

## Pause and step

- **Pause** (or F6, or the toolbar's pause button): the game stops updating. It keeps drawing, so
  you can look at the frozen moment: where everything is, every value.
- **Step a Frame** (while paused): the game runs exactly one frame (1/60 of a second) and stops
  again. Step through a jump, a collision, an animation, frame by frame.
- **Resume** (or F5): it carries on.

The editor's pause used to stop the game's program (on Linux and macOS only); with the Live tab
the game pauses itself, so it works on every computer.

## Frame times: is the game fast enough?

The line at the top says, averaged over the last half second:

| Number | What it is |
|---|---|
| **fps** | Frames per second (60 is smooth on most screens) |
| **frame** | Milliseconds from one frame to the next (16.7 ms at 60 fps) |
| **update** | How long your game's logic took: scripts, globals, the scene's nodes, physics |
| **physics** | The physics simulation alone (part of update) |
| **draw** | How long drawing took |
| **nodes**, **drawn** | Nodes in the scene, and how many drew something |

Under it, a **graph** of frame times: one bar per quarter second, the orange line at 16.7 ms. Bars
above the line are frames slower than 60 fps: something took too long then.

What to do when it's slow:

- **update** high: a script does too much each frame (searching all nodes, finding paths every
  frame, building strings), or there are very many nodes or bodies.
- **physics** high: many moving bodies, or many complicated shapes.
- **draw** high: many things drawn (see **drawn**), big images scaled, many particles, many lights
  with shadows.
- **frame** high but update and draw low: the computer is waiting for the screen (vsync) or busy
  with something else; nothing to fix in the game.

## The running scene's nodes

The left side lists every node of the scene that's playing, as the scene tree shows them
(children indented under their parents), including nodes your scripts made while it runs
(bullets, enemies, particles). Hidden nodes are dimmed. The list updates twice a second.

Click a node to see its values on the right: its position, rotation, scale, tint, opacity,
visibility, z index, what its kind has (a label's text, a light's energy...), and its script's
fields (`speed (script)`).

## Changing values while it runs

Type in any value's field: the game changes at once. Move a platform, make the player faster,
hide something, change a script's value. Values are written as in the inspector: `120, 300` for a
position, `#ff8000` for a color, `true` or `false`.

These changes only affect the running game: the project isn't changed, and they're gone when the
game stops. When you've found the right value, set it in the inspector.

A value the game can't use ("abc" for a speed) is refused: the Console says so.

## How it works

Play starts the game with `--live`. The editor writes commands to the game's input (watch, select
a node, set a value, pause, resume, step) and the game answers in its output, in lines starting
with `@@live` that the editor takes out of the Console. See the engine's `live.odin` for the
details, if you build your own tools.

## Questions

**The tab says "Waiting for the game".** The game is still starting (loading its first scene), or
it crashed: look in the Console.

**A node I changed jumps back.** Something in the game sets it every frame (a script, an
Animator, physics): your change lasts one frame. Pause first, or change what sets it.

**The list is long and slow.** Scenes with thousands of nodes send long lists; it doesn't slow the
game much, but finding a node takes scrolling.
