# Crossfire Editor user manual

This manual explains the Crossfire Editor and the Crossfire Engine for people making a game with
them for the first time. Each page covers one feature: what it's for, how to use it in the editor
step by step, the settings it has, and how to reach it from a script.

Open it from the editor with **Help > User Manual** (F1). Panels that have a page here have a
**Manual** button that opens it.

## Pages

| Page | What it covers |
|---|---|
| [Tilemaps](tilemaps.md) | TileMap nodes: drawing levels from tiles, painting them in the editor, terrains (autotiling), collision from tiles, animated tiles, changing tiles from scripts |

More pages arrive with each feature (keyframe animation, the UI system, lighting, pathfinding,
the live game view, scene transitions, state machines, parallax and cameras), and pages for the
older features follow.

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
- **Bottom panel**: the tabs under the viewport (Console, Output, Animation, Mixer, Git, Tiles).
  Ctrl+J shows or hides it.
- **Play** (F5): runs the game in its own window, the way players will see it.
- **Undo** (Ctrl+Z) and **Redo** (Ctrl+Shift+Z): every edit in a scene can be taken back.
