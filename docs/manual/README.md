---
title: Crossfire Editor user manual
description: How to make games with the Crossfire Editor and Engine, a page per feature for people new to them.
order: 0
---

# Crossfire Editor user manual

This manual explains the Crossfire Editor and the Crossfire Engine for people making a game with
them for the first time. Each page covers one feature: what it's for, how to use it in the editor
step by step, the settings it has, and how to reach it from a script.

Open it from the editor with **Help > User Manual** (F1): it opens in the editor's own docs window,
with the engine's API reference beside it, search, back and forward, and a link to the same page
on [crossfireengine.io](https://crossfireengine.io). Panels that have a page here have a
**Manual** button that opens it there, every node, scene and asset has **Open Docs** in its
right-click menu, and F1 in a code tab opens the entry of the engine name under the caret. See
[The docs window](docs_window.md).

## Pages

| Page | What it covers |
|---|---|
| [Getting started](getting_started.md) | Install and run the Crossfire Editor, learn the parts of its window, and make a first tiny game with a picture and some text |
| [Projects](projects.md) | Making, opening and saving a project; recent projects in the File menu; Save Project As (a copy somewhere else); project archives; unsaved changes |
| [Scenes and nodes](scenes_and_nodes.md) | Make and organize scenes, build them from nodes in the scene tree, set each node's position, layer and drawing order, and work in the viewport with its tools (move, rotate, scale, transform, zoom), right-click menus, align and distribute, guides, grid and undo |
| [Sprites and images](sprites_and_images.md) | Show pictures with Sprite nodes, play sprite-sheet animations with AnimatedSprite and the Animation panel, share animations as assets, use Aseprite files with their tags, layers and slices, and write text with Labels |
| [The sprite sheet slicer](sprite_slicer.md) | Cut a sprite sheet into frames by a grid or by finding its sprites, pick frames on the picture, name animations from them, and make an animation asset, give them to an AnimatedSprite or add a new one |
| [Scripts](scripts.md) | Write your game's code in Odin, attach it to nodes, set its fields in the inspector, and use events, assets and the engine from it |
| [Several scripts, node types and hot reload](scripts_node_types_hot_reload.md) | More than one script on a node, node types of your own made in code (a Player that is a Sprite), changing scripts while the game plays |
| [Globals, data resources and saves](globals_data_saves.md) | Keep game-wide state in global scripts, put game data such as enemy stats in data resources edited in the inspector, and save and load the player's progress |
| [Input](input.md) | Name your game's controls as input actions bound to keys, mouse buttons and gamepads, read them in scripts, and let players rebind them |
| [Physics](physics.md) | Make things fall, collide, bounce and be pushed with physics bodies, collision shapes, layers, ray casts and joints, and move platformer characters that slide along walls and floors |
| [Collision from sprites and physics materials](collision_and_materials.md) | Collision shapes traced from a sprite's pixels; shared friction, bounce and density for bodies |
| [Particles](particles.md) | Make sparks, smoke, fire, rain, explosions and magic with ParticleEmitter nodes, set up in the inspector and played live in the viewport |
| [Lines, trails and GPU particles](lines_and_trails.md) | Line2D (ropes, lasers, paths), Trail2D (ribbons behind moving things), ParticleEmitters running tens of thousands of particles on the GPU |
| [Sound and music](sound.md) | Play sound effects and music with AudioPlayer, AudioPlayer2D and MusicPlayer nodes, mix them on buses in the Mixer tab, and play sounds from scripts |
| [Bus effects, crossfades and music layers](audio_effects_and_music.md) | Filters, echo and reverb on mix buses (the Mixer's FX), fading between songs, music built from layers that scripts fade in and out |
| [Components](components.md) | Save a group of nodes (an enemy, a coin, a door) as a component, edit it in its own tab, place instances of it in any scene, and add or remove them from scripts |
| [LDtk levels](levels.md) | Draw your levels in the LDtk level editor and use them in scenes, with tile layers, IntGrid collision, entities that become components with scripts, and levels that update while the game plays |
| [Level mode](level_mode.md) | The editor's LDtk level editor, laid out like LDtk: a tool row, the Levels and Layers sidebars, a canvas where you move levels and entities and focus a level, LDtk's panels as tabs editing layers, entities, fields, enums and the world (saved into the `.ldtk` file with the project), the scenes showing each level |
| [Level definitions](level_definitions.md) | Editing an LDtk project's layers, entity types and their fields, enums (and external enum files), tilesets and level fields in the Level mode's tabs, as LDtk's panels do, every level kept in step |
| [Tilemaps](tilemaps.md) | TileMap nodes: drawing levels from tiles, painting them in the editor, terrains (autotiling), collision from tiles, animated tiles, changing tiles from scripts |
| [Camera tools](camera_tools.md) | A camera following a node by itself (limits, dead zone, look-ahead, shake), parallax backgrounds, rooms the camera stays in (camera zones), smooth zoom, camera views for split screen, minimaps and picture in picture |
| [2D lighting](lighting.md) | Lit scenes: an ambient light, point and spot lights, shadows from occluders and static bodies, editing in the dark, lights in scripts and animations |
| [Shaders and screen effects](shaders.md) | Built-in effects (hit flash, outline, dissolve, palette swap), your own GLSL shaders, ScreenEffect nodes (CRT, bloom, color grading), shaders in scripts and the Timeline |
| [The UI system](ui.md) | Panels, buttons, progress bars, text fields, scroll boxes and rich text for menus and HUDs: anchors, row / column / grid layouts, themes, 9-patch images, keyboard and gamepad focus, scripts |
| [Keyframe animation](animation.md) | Animator nodes and the Timeline: clips, tracks and keys that move, turn, scale, fade and change any node over time; curves; events that call your code |
| [State machines](state_machines.md) | StateMachine nodes and the States tab: states playing animations, transitions on conditions over parameters scripts set, events, any-state transitions |
| [Skeletal animation](skeletal_animation.md) | Bones and skeletons keyed in the Timeline, pictures bent over bones (skinned meshes), IK chains reaching targets, DragonBones characters imported |
| [Dialogue](dialogue.md) | Conversations written in the Dialogue tab (lines, choices, conditions, variables, commands), Yarn Spinner files imported, the typewriter DialogueBox, scripts |
| [Pathfinding and navigation](navigation.md) | NavRegion grids blocked by walls, NavAgents finding paths (A*) and walking characters along them around each other; doors, chasing, events |
| [Scene changes](scene_changes.md) | Transitions between scenes (fades, wipes, a circle), scenes opened over others (pause menus, HUDs), loading screens, scene changes in scripts |
| [Localization](localization.md) | Translate your game's text into other languages with CSV translation tables, "@key" texts in labels, buttons and menus, and Tr(key) in scripts |
| [Local multiplayer](local_multiplayer.md) | Players joining with gamepads or the keyboard, each reading the input actions from their own device; lobbies, unplugged pads, split screen |
| [Touch controls and Steam](touch_and_steam.md) | On-screen joysticks and buttons pressing input actions, fingers in scripts; Steam achievements, stats and cloud saves (the stub backend) |
| [Asset import settings, atlases and fonts](asset_import.md) | Smooth or pixel-art filtering per image, texture atlases Sprites draw from, bitmap fonts, fonts sharp at any size (MSDF), converting sounds to Ogg Vorbis |
| [The Live tab](live.md) | The game running from Play, seen from the editor: pause and step a frame, frame times (update, physics, draw), the running scene's nodes and their values, changed while it plays |
| [The code editor](code_editor.md) | Write your game's Odin scripts in tabs beside your scenes, with completion, error checking, go to definition, find and replace, and a command palette, or use an external editor such as Zed or VS Code instead |
| [Version control with Git](version_control.md) | Keep every version of your project with Git from the bottom panel's Git tab, with commits, branches, pushing to and pulling from a remote, diffs, merges and Git LFS for big assets |
| [Exporting your game](exporting.md) | Turn your project into a game other people can run, on Linux, Windows, macOS or in a web browser, from Project Settings > Export, File > Export, or the command line |
| [Settings and the toolchain](settings_and_toolchain.md) | Change how the editor looks (a live theme editor with presets and every color) and behaves, rebind its shortcuts, check and install the tools that build your games, and find your way around Project Settings |
| [Editor plugins](plugins.md) | Your own Odin code in the editor: commands, importers for other formats, inspector rows; built and reloaded as you save |
| [The docs window](docs_window.md) | This manual and the engine's API reference inside the editor, offline: opening it from anywhere (F1, Open Docs, Manual buttons), links, search, back and forward, the same page on crossfireengine.io |
| [Node guides](nodes.md) | Every node kind in one table, with a link to its guide |
| [Node guides: scene structure](nodes_scene.md) | Node2D, Camera, Component, LDtkLevel, CameraZone, NavRegion, NavAgent: what each does, its properties, the inspector, code, an example |
| [Node guides: graphics](nodes_graphics.md) | Sprite, AnimatedSprite, TileMap, ParallaxLayer, CameraView, Light2D, LightOccluder, ScreenEffect, Line2D, Trail2D, ParticleEmitter |
| [Node guides: animation](nodes_animation.md) | Animator, StateMachine, Skeleton2D, Bone2D, SkinnedMesh, IKChain |
| [Node guides: user interface](nodes_ui.md) | Label, Menu, Panel, Button, ProgressBar, TextField, ScrollBox, RichText, Slider, CheckBox, DialogueBox, VirtualJoystick, TouchButton |
| [Node guides: physics](nodes_physics.md) | StaticBody, DynamicBody, CharacterMover, Area, CollisionShape, RayCast, Joint |
| [Node guides: sound](nodes_audio.md) | AudioPlayer, AudioPlayer2D, MusicPlayer |

The pages are in reading order: the first five get you making a game, the rest can be read as
you need them; the node guides at the end are a reference, a section per node kind.

## Words used in this manual

- **Project**: your game's folder. It holds `project.xml` (the game's settings), `scenes/` (the
  levels and menus), `assets/` (images, sounds, fonts) and `scripts/` (your Odin code).
- **Scene**: one screen of the game: a level, a menu. It's a tree of nodes.
- **Node**: one thing in a scene: a sprite, a camera, a physics body, a tilemap. Nodes have
  children; a child moves, turns and scales with its parent.
- **Inspector**: the panel on the right, under the scene tree. It shows the selected node's
  settings.
- **Browser**: the panel on the left listing the project's scenes and assets.
- **Viewport**: the picture of the scene in the middle, where nodes are placed.
- **Bottom panel**: the tabs under the viewport (Console, Output, Animation, Mixer, Git, Tiles,
  Timeline, Live, States, Particles, Dialogue, Plugins).
  Ctrl+J shows or hides it.
- **Play** (F5): runs the game in its own window, the way players will see it.
- **Undo** (Ctrl+Z) and **Redo** (Ctrl+Shift+Z): every edit in a scene can be taken back.
- **Ctrl on a Mac:** where this manual says Ctrl, a Mac uses **Cmd** (Ctrl+S is Cmd+S), and
  Alt is **Option**. The editor shows each shortcut the way your computer names it.
