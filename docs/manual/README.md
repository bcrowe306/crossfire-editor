# Crossfire Editor user manual

This manual explains the Crossfire Editor and the Crossfire Engine for people making a game with
them for the first time. Each page covers one feature: what it's for, how to use it in the editor
step by step, the settings it has, and how to reach it from a script.

Open it from the editor with **Help > User Manual** (F1). Panels that have a page here have a
**Manual** button that opens it.

## Pages

| Page | What it covers |
|---|---|
| [Dialogue](dialogue.md) | Conversations written in the Dialogue tab (lines, choices, conditions, variables, commands), Yarn Spinner files imported, the typewriter DialogueBox, scripts |
| [Skeletal animation](skeletal_animation.md) | Bones and skeletons keyed in the Timeline, pictures bent over bones (skinned meshes), IK chains reaching targets, DragonBones characters imported |
| [Asset import settings, atlases and fonts](asset_import.md) | Smooth or pixel-art filtering per image, texture atlases Sprites draw from, bitmap fonts, fonts sharp at any size (MSDF), converting sounds to Ogg Vorbis |
| [Several scripts, node types and hot reload](scripts_node_types_hot_reload.md) | More than one script on a node, node types of your own made in code (a Player that is a Sprite), changing scripts while the game plays |
| [Projects](projects.md) | Making, opening and saving a project; recent projects in the File menu; Save Project As (a copy somewhere else); project archives; unsaved changes |
| [Keyframe animation](animation.md) | Animator nodes and the Timeline: clips, tracks and keys that move, turn, scale, fade and change any node over time; curves; events that call your code |
| [Lines, trails and GPU particles](lines_and_trails.md) | Line2D (ropes, lasers, paths), Trail2D (ribbons behind moving things), ParticleEmitters running tens of thousands of particles on the GPU |
| [Shaders and screen effects](shaders.md) | Built-in effects (hit flash, outline, dissolve, palette swap), your own GLSL shaders, ScreenEffect nodes (CRT, bloom, color grading), shaders in scripts and the Timeline |
| [Local multiplayer](local_multiplayer.md) | Players joining with gamepads or the keyboard, each reading the input actions from their own device; lobbies, unplugged pads, split screen |
| [Touch controls and Steam](touch_and_steam.md) | On-screen joysticks and buttons pressing input actions, fingers in scripts; Steam achievements, stats and cloud saves (the stub backend) |
| [Bus effects, crossfades and music layers](audio_effects_and_music.md) | Filters, echo and reverb on mix buses (the Mixer's FX), fading between songs, music built from layers that scripts fade in and out |
| [Collision from sprites and physics materials](collision_and_materials.md) | Collision shapes traced from a sprite's pixels; shared friction, bounce and density for bodies |
| [Camera tools](camera_tools.md) | Parallax backgrounds, rooms the camera stays in (camera zones), smooth zoom, camera views for split screen, minimaps and picture in picture |
| [State machines](state_machines.md) | StateMachine nodes and the States tab: states playing animations, transitions on conditions over parameters scripts set, events, any-state transitions |
| [Scene changes](scene_changes.md) | Transitions between scenes (fades, wipes, a circle), scenes opened over others (pause menus, HUDs), loading screens, scene changes in scripts |
| [The Live tab](live.md) | The game running from Play, seen from the editor: pause and step a frame, frame times (update, physics, draw), the running scene's nodes and their values, changed while it plays |
| [Pathfinding and navigation](navigation.md) | NavRegion grids blocked by walls, NavAgents finding paths (A*) and walking characters along them around each other; doors, chasing, events |
| [2D lighting](lighting.md) | Lit scenes: an ambient light, point and spot lights, shadows from occluders and static bodies, editing in the dark, lights in scripts and animations |
| [The UI system](ui.md) | Panels, buttons, progress bars, text fields, scroll boxes and rich text for menus and HUDs: anchors, row / column / grid layouts, themes, 9-patch images, keyboard and gamepad focus, scripts |
| [Tilemaps](tilemaps.md) | TileMap nodes: drawing levels from tiles, painting them in the editor, terrains (autotiling), collision from tiles, animated tiles, changing tiles from scripts |

Pages for the older features (scenes and nodes, scripts, physics, particles, sound, LDtk,
Aseprite, components, exporting) follow.

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
  Timeline, Live, States).
  Ctrl+J shows or hides it.
- **Play** (F5): runs the game in its own window, the way players will see it.
- **Undo** (Ctrl+Z) and **Redo** (Ctrl+Shift+Z): every edit in a scene can be taken back.
