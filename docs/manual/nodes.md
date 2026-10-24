---
title: Node guides
description: "Every node kind in one place: what it does and where its guide is (properties, the inspector, code, an example, the API)."
order: 41
---

# Node guides

A scene is built from nodes, and each kind of node does one job. This page lists every kind the
engine has, grouped as the **Add Node** dialog groups them, with a link to its guide. Each guide
says what the node does, its properties (as the inspector names them), how to set it up in the
editor, how to use it from a script, an example that compiles, and links to its entries in the
[API reference](https://crossfireengine.io/api/).

The guides are on six pages:

- [Scene structure](nodes_scene.md)
- [Graphics](nodes_graphics.md)
- [Animation](nodes_animation.md)
- [User interface](nodes_ui.md)
- [Physics](nodes_physics.md)
- [Sound](nodes_audio.md)

In the editor, right-click a node in the scene tree or the viewport and choose **Open Docs** to
open its guide in the docs window; **F1** over the inspector does the same for the selected node.

## Scene structure

| Node | What it does |
|---|---|
| [Node2D](nodes_scene.md#node2d) | Groups nodes; moving, rotating or scaling it moves its children |
| [Camera](nodes_scene.md#camera) | Chooses the part of the scene the game shows; can follow a parent node |
| [Component](nodes_scene.md#component) | An instance of a component: a node tree saved in the assets, reused in any scene |
| [LDtkLevel](nodes_scene.md#ldtklevel) | A level made in the LDtk level editor: its tile layers, entities and IntGrid collision |
| [CameraZone](nodes_scene.md#camerazone) | A room the camera stays inside while it's in it; moving to another slides the view over |
| [StateMachine](nodes_animation.md#statemachine) | Keeps one of a set of states (idle, run, jump) and moves between them on conditions; plays each state's animation |
| [NavRegion](nodes_scene.md#navregion) | Where characters can walk: a grid over an area, blocked by static bodies, for finding paths |
| [NavAgent](nodes_scene.md#navagent) | Finds paths through a NavRegion and moves its parent along them, around other agents |

## Graphics

| Node | What it does |
|---|---|
| [Sprite](nodes_graphics.md#sprite) | Draws an image |
| [AnimatedSprite](nodes_graphics.md#animatedsprite) | Plays a sprite sheet animation |
| [ParticleEmitter](nodes_graphics.md#particleemitter) | Emits particles that move, spin, grow and change color: sparks, smoke, fire, rain |
| [TileMap](nodes_graphics.md#tilemap) | Tilemap layers drawn in Aseprite: their tiles, and collision from the tiles' properties |
| [Light2D](nodes_graphics.md#light2d) | A light in a lit scene: a point or a spot cone, colored, with shadows from occluders |
| [ParallaxLayer](nodes_graphics.md#parallaxlayer) | A background that moves slower than the world as the camera moves (depth), tiled if asked: skies, hills |
| [CameraView](nodes_graphics.md#cameraview) | What another camera sees, in a rectangle on the screen: split screen, minimaps, picture in picture |
| [LightOccluder](nodes_graphics.md#lightoccluder) | A shape that blocks light and casts shadows: walls, pillars, trees |
| [Animator](nodes_animation.md#animator) | Animates other nodes' properties over time with keyframes: cutscenes, moving platforms, UI, effects |
| [ScreenEffect](nodes_graphics.md#screeneffect) | A shader over the whole scene as drawn: CRT, bloom, color grading (GPU renderer) |
| [Line2D](nodes_graphics.md#line2d) | A thick line through points: ropes, lasers, paths, with a color gradient, round joints, a texture |
| [Trail2D](nodes_graphics.md#trail2d) | A ribbon left behind its parent as it moves: sword swings, dashes, comets, tire tracks |
| [Skeleton2D](nodes_animation.md#skeleton2d) | The root of a character's bones: animate the bones, and the pictures on them follow |
| [Bone2D](nodes_animation.md#bone2d) | A bone of a skeleton: its children (pictures, more bones) move with it; key it in the Timeline |
| [SkinnedMesh](nodes_animation.md#skinnedmesh) | A picture bent over bones: a mesh whose points follow weighted bones (soft bodies, sleeves, tails) |
| [IKChain](nodes_animation.md#ikchain) | Turns a chain of bones so its tip reaches a target: arms reaching, feet planted on the ground |

## User interface

| Node | What it does |
|---|---|
| [Label](nodes_ui.md#label) | Draws a line of text |
| [Menu](nodes_ui.md#menu) | A list of buttons that switch scenes or quit the game |
| [Panel](nodes_ui.md#panel) | A box that lays out the controls in it (rows, columns, grids) on a themed or 9-patch background |
| [Button](nodes_ui.md#button) | A button with text or a picture: switches scenes, quits, or tells scripts it was pressed |
| [ProgressBar](nodes_ui.md#progressbar) | A bar showing a value in its range: health, stamina, loading |
| [TextField](nodes_ui.md#textfield) | A box the player types a line of text in: names, chat, codes |
| [ScrollBox](nodes_ui.md#scrollbox) | A column of controls that scrolls: long lists, inventories, credits |
| [RichText](nodes_ui.md#richtext) | Text with colors and sizes that wraps: dialogue, descriptions, tooltips |
| [Slider](nodes_ui.md#slider) | A value picked by dragging a knob along a track, or with the keys: volume, brightness, difficulty |
| [CheckBox](nodes_ui.md#checkbox) | A box to tick, with its text beside it: on / off settings like fullscreen or subtitles |
| [VirtualJoystick](nodes_ui.md#virtualjoystick) | An on-screen stick for touch screens, pushing input actions (moving left, right, up, down) |
| [TouchButton](nodes_ui.md#touchbutton) | An on-screen round button for touch screens, pressing an input action (jump, fire) |
| [DialogueBox](nodes_ui.md#dialoguebox) | Shows a conversation: the speaker, each line typed out, options to choose (a dialogue asset, or Yarn) |

## Physics

| Node | What it does |
|---|---|
| [StaticBody](nodes_physics.md#staticbody) | A physics body that doesn't move by itself: walls, floors, platforms |
| [DynamicBody](nodes_physics.md#dynamicbody) | A physics body moved by gravity, collisions and forces |
| [CharacterMover](nodes_physics.md#charactermover) | A body moved by code that slides along walls and floors: players, enemies |
| [Area](nodes_physics.md#area) | A region that reports bodies entering and leaving it: pickups, triggers |
| [CollisionShape](nodes_physics.md#collisionshape) | The shape of the physics body above it: rectangle, circle, capsule, polygon, segment |
| [RayCast](nodes_physics.md#raycast) | A ray that reports the first physics body in its way: line of sight, ground checks |
| [Joint](nodes_physics.md#joint) | Connects two physics bodies: a hinge, rope, spring, slider, weld or wheel |

## Sound

| Node | What it does |
|---|---|
| [AudioPlayer](nodes_audio.md#audioplayer) | Plays a sound: volume, pitch, pan, looping, through a mix bus |
| [AudioPlayer2D](nodes_audio.md#audioplayer2d) | Plays a sound in the world: panned and quieter with distance from the camera |
| [MusicPlayer](nodes_audio.md#musicplayer) | Streams music: fades, looping, seeking, through a mix bus |

## Questions

**Which node do I start a scene with?** Usually a **Node2D** to group the others, a **Camera** if
the view should move, then what the scene shows. [Scenes and nodes](scenes_and_nodes.md) walks
through it.

**What's the difference between a node kind and a node type?** A node kind is one of the
engine's (this page). A node type is your own, made in code from a kind (a Player that is a
Sprite): see [Several scripts, node types and hot reload](scripts_node_types_hot_reload.md).

**Where are a node's settings that every node has?** Position, rotation, scale, layer, z index,
visibility and groups are in [Every node's settings](scenes_and_nodes.md#every-nodes-settings).

**How do I reach a node from a script?** Give the script a node field, such as
``door: ^e.Sprite `export:"default=Door"` ``, and pick the node in the inspector: see
[Scripts](scripts.md#exported-fields).
