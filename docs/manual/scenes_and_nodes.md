---
title: Scenes and nodes
description: Make and organize scenes, build them from nodes in the scene tree, set each node's position, layer and drawing order, and work in the viewport with its tools, right-click menus, align and distribute, guides, grid and undo.
order: 3
---

# Scenes and nodes

A game is made of **scenes**: the title menu, each level, the options screen, the game-over
screen. A scene is a tree of **nodes**: each node is one thing (a picture, some text, a camera, a
wall, a sound), and a node can have children that move, turn and grow with it. A spaceship node
with a flame and a gun under it: move the ship, and the flame and the gun come along.

- [Scenes](#scenes)
- [The scene tree](#the-scene-tree)
- [Adding nodes](#adding-nodes)
- [Arranging nodes](#arranging-nodes)
- [Every node's settings](#every-nodes-settings)
- [The viewport](#the-viewport)
- [Right-click menus](#right-click-menus)
- [Align and distribute](#align-and-distribute)
- [Guides](#guides)
- [Grid and snapping](#grid-and-snapping)
- [Undo and redo](#undo-and-redo)
- [A scene's own settings](#a-scenes-own-settings)
- [Nodes in scripts](#nodes-in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Scenes

The browser's **Scenes** folder lists them. The **start scene** (the one the game opens with) says
**(start)**. Click a scene to open it: it gets a tab above the viewport, and its nodes show in the
scene tree.

Right-click a scene for:

| Command | What it does |
|---|---|
| **Open** | Opens it (a click does the same) |
| **Play Scene** | Runs the game starting from this scene instead of the start scene |
| **Rename** (F2) | Renames it in place. Menu buttons and script fields that lead to it follow the new name |
| **Duplicate** (Ctrl+D) | A copy of it, with all its nodes |
| **Copy** / **Cut** / **Paste** (Ctrl+C / X / V) | Copies scenes, within the project |
| **Delete** (Del) | Removes it. The last scene can't be deleted |
| **Set as Start Scene** | The game opens with it |
| **New Scene** | A new scene with a **World** node in it, ready to be named: type its name and press Enter |

Right-click the Scenes folder (or empty space in the browser) for **New Scene** too. The
shortcuts in the table work on scenes while the browser has the keyboard (after you click in it);
otherwise they work on nodes.

**Playing:** **Play** (F5) runs the game from its start scene. **Play This Scene** (Ctrl+F5, the
Scene menu, or the toolbar's second play button) runs it from the open scene, handy to test a
level without going through the menu. **Pause** (F6) and **Stop** (Shift+F5) control the running
game.

**The start scene** is also in **File > Project Settings... > General > Start scene**.

**The preview:** selecting a scene shows, under the browser, its file, how many nodes of each kind
it has, its camera, the scripts and components it uses, buttons (**Open**, **Play Scene**, **Set
as Start**) and the scene's own settings ([below](#a-scenes-own-settings)).

**Tabs:** each open scene has a tab above the viewport. The × on a tab closes it (the scene stays
in the project); clicking the scene in the browser opens it again.

## The scene tree

The panel at the top right shows the open scene's nodes, children indented under their parents.
Its header has the scene's name, **+** (Add Node) and the trash (Delete). The ▸ beside a parent
folds its children away.

- **Click** a node to select it. The inspector under the tree shows its settings.
- **Double-click** it, or press **F2**, to rename it. Enter keeps the name, Escape cancels.
- **Right-click** it for its menu (the same as a right-click on it in the viewport: see
  [Right-click menus](#right-click-menus)): Add Child Node, Cut, Copy, Paste, Duplicate, Delete,
  Rename, its script, Save as Component, Hide / Show, Transform, Order, Select, Frame Selected,
  Copy Node Path, Expand All, Collapse All. A right-click below the rows offers Add Node, Paste,
  Select All and Expand / Collapse All.

The editing commands are in the **Edit** menu too. A copied node takes its children with it. **Paste**
puts the copies inside the selected node (or at the top of the scene when nothing is selected),
in this scene or another one. A duplicate goes right after the original, named with the next
number (`Ship2` after `Ship`). [Save as component](components.md) turns the node into a reusable
piece.

**Selecting several nodes:**

| Do | To |
|---|---|
| Ctrl+click | Add a node to the selection, or take it out |
| Shift+click (in the tree) | Select every row between the selected one and this one |
| Shift+click (in the viewport) | Add a node to the selection |
| Drag over empty space in the viewport | Select every node in the box (Ctrl or Shift: add them) |
| Ctrl+A | Select every node of the scene |
| Escape | Select nothing |

Delete, Copy, Cut, Duplicate, the arrow keys and dragging in the viewport then work on all of them
at once. The inspector shows the one you clicked last.

## Adding nodes

**Add Node** (Ctrl+Shift+A, the **+** above the scene tree, or **Edit > Add Node...**) opens a
list of every kind of node, each with a line saying what it's for, under these headings:

| Heading | Has |
|---|---|
| **Scene** | Node2D (groups others), Camera, Component, LDtkLevel, CameraZone, StateMachine, NavRegion, NavAgent |
| **Graphics** | Sprite, AnimatedSprite, ParticleEmitter, TileMap, Light2D, LightOccluder, ParallaxLayer, CameraView, Animator, ScreenEffect, Line2D, Trail2D, the skeleton nodes |
| **User interface** | Label, Menu, Panel, Button, ProgressBar, TextField, ScrollBox, RichText, DialogueBox, VirtualJoystick, TouchButton |
| **Physics** | StaticBody, DynamicBody, CharacterMover, Area, CollisionShape, RayCast, Joint |
| **Sound** | AudioPlayer, AudioPlayer2D, MusicPlayer |
| **Your node types** | Node types your scripts define (see [Several scripts, node types and hot reload](scripts_node_types_hot_reload.md)) |

Type to search (by name, description or heading), move with Up and Down, and press Enter or click
to add. Escape closes the list.

The new node goes **inside the selected node** (at the top of the scene when nothing is
selected), at its parent's position, named after its kind (`Sprite`, then `Sprite2`...). It's
selected, so the inspector shows it straight away.

Dragging an image from the browser into the viewport is quicker for pictures: it makes a Sprite
where you let go (see [Sprites and images](sprites_and_images.md)).

## Arranging nodes

**Drag a node in the scene tree** to move it:

- onto the top or bottom edge of another row: it goes before or after that node, beside it;
- onto the middle of a row: it becomes that node's last child;
- below all the rows: it goes to the end of the scene, at the top level.

A line or a box shows where it will land. Dragging near the tree's top or bottom edge scrolls it.
The node stays where it is on the screen: its position is changed to match its new parent. A node
can't go inside its own children.

**Order matters:** nodes draw in the tree's order, top first, so a node lower in the tree draws over
the ones above it (unless their **Layer** or **Z index** say otherwise, below).

## Every node's settings

Select a node and the inspector shows these first, whatever its kind:

| Setting | What it does |
|---|---|
| **Name** | What the scene tree shows. Scripts find nodes by name |
| **Type** | Its kind (Sprite, Label...). It can't be changed |
| **Position X**, **Position Y** | Where it is, in pixels, **relative to its parent**: a child at 0, 0 sits on its parent's position. X grows to the right, Y downward |
| **Rotation** | How far it's turned, in degrees, clockwise, relative to its parent |
| **Scale X**, **Scale Y** | Its size: 1 is normal, 2 twice as big, 0.5 half. A negative X mirrors it |
| **Layer** | Which of the 8 drawing layers it's on (0 to 7). Lower layers draw first, behind the higher ones. Children don't inherit it |
| **Visible** | Unticked, the node and everything under it aren't drawn (they still run) |
| **Z index** | Order within its layer: a higher number draws on top. Nodes with the same number keep the tree's order |
| **Y sort** | Draws this node's children by how low they are on the screen, lower ones in front: characters walking behind and in front of each other in a top-down game |
| **Blend** | How its pixels mix with what's behind: **Blend** (normal), **Add** (glows, fire, light), **Multiply** (shadows, tinting), **Modulate**, **None** (replaces what's under it) |
| **Process** | When it updates: **Inherit** (like its parent), **Pausable** (stops while the game is paused), **WhenPaused** (only while paused: a pause menu), **Always**, **Disabled** (never; it still draws) |
| **Groups** | Names separated by commas (`enemies, flying`). Scripts get every node of a group at once |

The chain-link button beside Position and Scale links X and Y: change one and the other follows
in proportion. Hover any setting's name for an explanation.

Below these come the node's script (see [Scripts](scripts.md)), its events, and the settings of
its kind: an image for a Sprite, a text for a Label, a shape for a CollisionShape. Each kind's page
in this manual explains them.

Labels and Menus follow their parent's position, but not its rotation or scale.

## The viewport

The viewport in the middle shows the open scene as the game draws it. The red outline is the
**game area**, what the player's screen shows (without a camera: exactly; with one, what the
camera sees). Cameras show their own frame.

**Tools** (toolbar, View menu or keys):

| Tool | Key | Dragging a node |
|---|---|---|
| **Select** | Q | Moves it |
| **Move** | W | Moves it; drag an arrow to move along one direction only |
| **Rotate** | E | Turns it (drag the ring) |
| **Scale** | R | Resizes it: a corner scales both directions, a side's middle handle one |
| **Transform** | T | All three at once: the arrows and middle square move, the corner and side handles scale, the ring turns |
| **Zoom** | Z | Doesn't move nodes: a click zooms in two times there (Alt+click: out), dragging a box zooms to fit it |
| **Pan** | H | Moves the view instead |

Click a node to select it (the topmost one under the pointer). Hold **Shift** while dragging to
constrain the move. **The arrow keys** nudge the selection by a pixel (Shift + arrow: 10), while
the pointer is over the viewport.

- **Alt + drag** moves a copy: the selection is duplicated and the copies follow the pointer,
  leaving the originals where they were. One Undo takes back both.
- **The node's own axes** (**L**, or the compass button above the viewport): the move arrows turn
  with the selected node, so a turned platform slides along its own length.

**Moving around:**

| Do | To |
|---|---|
| Mouse wheel | Zoom in and out around the pointer |
| Shift + wheel | Pan sideways |
| Ctrl + wheel | Pan up and down |
| Middle or right drag, Space + drag, or the Pan tool | Pan |
| Ctrl+= / Ctrl+- | Zoom in / out |
| Ctrl+1, or click the zoom percentage | 100% |
| Ctrl+0, or the fit button | Fit the game area in the view |
| F | Center the view on the selected node (Frame Selected) |

With a touchpad, **Settings > Editor > Wheel pans** makes scrolling pan and Ctrl + scroll zoom.

**The rulers** along the top and left edge are in world pixels, and follow the pointer. The
corner shows the zoom and the pointer's position in the world.

**The buttons above the viewport** (beside the scene tabs):

| Button | Key | What it does |
|---|---|---|
| Play / pause | P | Plays animations and particles in the viewport, or freezes them |
| Grid | G | Shows the grid |
| Magnet | Shift+G | Snaps to the grid |
| Polygon | Shift+C | Shows collision shapes (see [Physics](physics.md)) |
| Light bulb | Shift+L | Shows lit scenes lit or unlit (see [2D lighting](lighting.md)) |
| Compass | L | The move arrows follow the selected node's own axes |
| Align | | With two or more nodes selected: Align and Distribute (below) |
| Fit | Ctrl+0 | Fits the game area in the view |
| Percentage | Ctrl+1 | Shows the zoom; click for 100% |

Scripts don't run in the viewport: nothing falls or walks there. Press Play to see the game run.

## Right-click menus

Everywhere in the editor, a right-click opens a menu of what you can do with what's under the
pointer. Each item shows its shortcut, items that can't be used now are grayed, and settings that
are on have a check. Items with ▸ open a submenu. Escape or a click elsewhere closes the menu.

**On a node in the viewport** (a right click that doesn't drag: a right drag pans). The node is
selected first; if it's part of a selection, the menu acts on all of it:

| Item | Does |
|---|---|
| Add Child Node..., Add Node Here... | Add Node, as a child of this one, or at the point you clicked |
| Cut, Copy, Paste, Duplicate, Delete, Rename | As their shortcuts |
| Add Script... / Open Script (Name) | Its script ([Scripts](scripts.md)) |
| Save as Component... / Edit Component, Make Unique | [Components](components.md) |
| Hide / Show | Hides it in the viewport and the game, or shows it |
| Transform ▸ | Reset its position, rotation, scale, or all three |
| Align and Distribute ▸ | With several nodes selected ([below](#align-and-distribute)) |
| Order ▸ | Move Up / Move Down among its siblings in the tree; Bring Forward / Send Backward (its z index) |
| Select ▸ | Its children, its parent, all, none |
| Frame Selected | Centers the view on it |
| Copy Node Path | Its path from the scene's top (`World/Ship`), for scripts |

**On empty space in the viewport:** Add Node Here..., Paste Here (the copy's origin lands where
you clicked), Select All, Deselect, Frame Selected, Fit the View, the zoom, the **Tool** submenu,
the **Show** submenu (grid, snapping, collision shapes, lighting, animations, guides), Grid
Settings....

**Elsewhere:** the [browser](projects.md)'s scenes, assets of every kind (open, add to the scene,
play a sound, show in the file manager, copy its path, remove...) and folders (new files of each
kind, Import); the scene and code tabs (play, save, show in the browser, close, close the others,
close the ones to the right); the Console and Output lines (copy one, copy all, clear); and the
bottom panel's lists: [states](state_machines.md), [dialogue](dialogue.md) nodes and steps,
[Timeline](animation.md) tracks and keys, [Mixer](sound.md) strips, [Git](version_control.md)
changes, [Live](live.md) nodes, the Animation panel's frames, [plugins](plugins.md).

## Align and distribute

With two or more nodes selected, **Align and Distribute** (the Align button above the viewport, or
a node's menu) lines them up by what they draw (a node that draws nothing by its origin):

| Item | Moves each node to |
|---|---|
| Left Edges, Centers, Right Edges | The selection's left edge, middle or right edge |
| Top Edges, Middles, Bottom Edges | The selection's top, middle or bottom |
| Distribute Across, Distribute Down | Equal gaps between them, the outermost two staying put (three or more nodes) |

Each is one undo step.

## Guides

Guides are lines across the viewport to line things up against. **Drag one out of a ruler:** from
the top ruler for a horizontal guide, from the left one for a vertical guide, and let go where you
want it. **Drag a guide** to move it; drag it back onto its ruler to remove it. A right-click on a
guide offers Remove Guide, Remove All Guides and Hide Guides.

With **snapping** on (Shift+G), a node you drag snaps its origin onto a guide within a few pixels.
**View > Show Guides** (Shift+;) hides or shows them all. Guides belong to the scene and are kept
with the project for you, in `.editor/guides.ini` (yours: not an undo step, not part of the game, and left out of Git).

## Grid and snapping

**G** shows the grid (it's on to start with). **Shift+G** turns snapping on: while you drag, the
node's position lands on the grid (and on [guides](#guides)), rotations go in 15° steps and scales
in steps of 0.1. **Settings > Editor > Rotation snap** and **Scale snap** change those steps. When
several nodes are dragged, only the one under the pointer snaps; the rest keep their places
relative to it.

**View > Grid Settings...** opens **Project Settings > Grid**: **Grid width** and **Grid height**
(the cell size in pixels), **Major lines every** (a lighter line every so many cells; 0 for none),
**Line opacity** and **Major line opacity** (60% and 90% to start). The grid is drawn in dark grays
of its own, so it stands apart from the editor's panels; the axes (x = 0, y = 0) are the lightest.
The grid is saved with the project, so everyone working on it shares it.

## Undo and redo

Every edit to a scene can be undone: **Edit > Undo** (Ctrl+Z) and **Redo** (Ctrl+Shift+Z or
Ctrl+Y). The Edit menu says what it will undo ("Undo Rename Spaceship"). Undoing an edit in
another scene switches to that scene first. A whole drag in the viewport is one step; typing
into a field becomes one step once you pause.

Not undone: selecting, opening and closing panels, and importing or removing files (they copy and
delete files). While you're typing in a field, Ctrl+Z undoes your typing instead.

**Settings > Editor** sets how many steps are kept and how quickly edits merge.

## A scene's own settings

Select a scene in the browser: the preview under it ends with **Scene settings**, which apply to
that scene only.

| Setting | What it does |
|---|---|
| **Screen layers** (buttons 1 to 8) | The layers drawn without the camera, fixed on the screen: put HUDs and menus there. Button 1 is the inspector's Layer 0, button 8 its Layer 7 |
| **Own background** | Clears the screen with this scene's color instead of the project's (Project Settings > General) |
| **Lit (dark outside its lights)**, **Ambient**, **Static bodies cast shadows** | 2D lighting: see [2D lighting](lighting.md) |
| **Own gravity** | Gravity for this scene instead of the project's, in pixels per second² (Y down): a low-gravity moon level |

Each change can be undone like any other edit.

## Nodes in scripts

Scripts reach a scene's nodes and change the same settings the inspector shows:

```odin
// A node by its path from the top of the scene
door := e.Scene_FindNode(self.scene, "World/Door")
if door != nil {
	door.visible = false
	door.position = {320, 180}
	door.rotation = 90
	door.zIndex = 5
}

// Every node in the group "enemies"
for enemy in e.Scene_GetGroup(self.scene, "enemies") {
	enemy.scale = {2, 2}
}

// Into a group from code
e.Node_AddToGroup(self.node, "enemies")

// Where a node really is, after its parents' transforms
if e.Node_GetWorldPosition(self.node).y > 2000 {
	// It fell off the level
}
```

`self` is your script (see [Scripts](scripts.md)). A bare name (`"Door"`) finds the first node
with that name anywhere in the scene.

## How it's stored

Each scene is a file, `scenes/<Name>.scene.xml`. Its nodes are nested the way the tree shows them,
and only the settings that differ from the defaults are written:

```xml
<scene name="Level1" screenLayers="8" gravityX="0" gravityY="400">
	<node kind="Node2D" name="World">
		<node kind="Sprite" name="Ship" x="640" y="360" rotation="15" texture="assets/ship.png">
			<node kind="Sprite" name="Flame" y="40" zIndex="-1" texture="assets/flame.png"/>
		</node>
		<node kind="Label" name="Title" x="640" y="80" text="Level 1" fontSize="48" layer="7"/>
	</node>
</scene>
```

## Questions

**My node is behind another one.** Move it lower in the scene tree, or give it a higher **Z
index**, or a higher **Layer**.

**I moved a parent and its children moved too.** That's what parents are for. To move only the
parent, drag the children out of it in the scene tree first.

**My HUD scrolls away with the camera.** Put it on a layer, and tick that layer in the scene's
**Screen layers**.

**Delete removed a scene instead of a node.** The browser had the keyboard. Undo (Ctrl+Z), click in
the viewport or the scene tree, and try again.

**The Add Node list doesn't have my kind of node.** Clear the search box. Node types from your
scripts only show once the scripts are built (**Scripts > Build Scripts**, Ctrl+B).
