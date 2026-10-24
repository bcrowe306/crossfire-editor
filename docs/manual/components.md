---
title: Components
description: Save a group of nodes (an enemy, a coin, a door) as a component, edit it in its own tab, place instances of it in any scene, and add or remove them from scripts.
order: 16
---

# Components

A coin in a platformer is a few nodes: a spinning AnimatedSprite, an Area that notices the player,
its CollisionShape, a sound. A level has fifty coins. Building each one by hand is slow, and
changing them all later is worse. A **component** is that group of nodes saved once, in a file of
its own. Each coin in the level is then an **instance** of it: one node in the scene tree that
stands for the whole group. Change the component, and every coin in every scene changes.

(Other engines call these prefabs, or packed scenes.)

- [Making a component](#making-a-component)
- [Editing a component](#editing-a-component)
- [Placing instances](#placing-instances)
- [What an instance can change](#what-an-instance-can-change)
- [Make Unique: one instance on its own](#make-unique-one-instance-on-its-own)
- [Renaming and removing](#renaming-and-removing)
- [Components in scripts](#components-in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Making a component

**From nodes you already have:**

1. Build the thing in a scene: a parent node with everything it needs under it (for a coin, an
   Area with its sprite, shape and sound as children).
2. Right-click the parent in the scene tree > **Save as component**.

The parent and everything under it are saved as a component named after the parent (`Coin` makes
`components/coin.component.xml`), and appear in the browser's **Components** folder by name (`coin`:
the browser and every component choice leave out the `.component.xml`). In the scene,
the parent becomes an instance of the new component, where it was. Undo turns it back into plain
nodes (the component file stays).

**From scratch:**

1. Right-click the browser's **Components** folder > **New Component**.
2. The list of node kinds opens: pick what the component's **root** is (its top node): a Node2D to
   group things, an Area for a pickup, a CharacterMover for an enemy...

The component is made with that root, named after its kind, and opens in its own tab, ready to
build on.

## Editing a component

Open a component to change it:

- double-click it in the browser's **Components** folder;
- or select it and press **Edit** in the preview under the browser (also in its right-click menu);
- or select an instance in a scene and press the inspector's **Edit** button (it says Edit and the component's name).

It opens in a tab above the viewport like a scene, and the view fits what it draws. Add nodes,
move them, attach scripts, set their settings: everything works as in a scene (see [Scenes and
nodes](scenes_and_nodes.md)), and every edit can be undone.

A component has **one root**. With nothing selected, new nodes, pasted nodes and dropped pictures
go under the root, and nodes can't be dragged beside it.

**Unsaved changes:** a dot on the component's tab means it has changes not yet written to its file.
**File > Save** (Ctrl+S) saves it with the rest of the project. Closing its tab with unsaved
changes asks first:

| Choice | What happens |
|---|---|
| **Save** | Writes the component's file |
| **Don't Save** | Puts the component back the way its file has it (instances everywhere follow), and drops its undo steps |
| **Cancel** | Keeps the tab open |

Instances in other scenes show your changes in the viewport as you make them.

## Placing instances

Any of these adds an instance to the open scene:

- **Drag the component** from the browser's Components folder into the viewport. It lands where you
  let go, inside the selected node (or at the top of the scene).
- **Add to Scene**, in the preview under the browser or the component's right-click menu: it goes
  at the selected node's position, inside it (with nothing selected: the middle of the view).
- **Add Node** (Ctrl+Shift+A) > **Component**, then choose which one in the inspector's
  **Component** row.

An instance is one node in the scene tree, shown with the component's whole picture in the
viewport. Click anywhere on it to select it, and move, turn and scale it like any node.

A component can't contain an instance of itself (directly, or through other components): the
editor refuses.

The browser's preview of a component shows its picture, how many nodes it has, its root's kind
and how many instances use it.

## What an instance can change

Each instance has its own:

- **Name**
- **Position**, **Rotation**, **Scale**
- **Layer**
- **Visible**

Everything else (the nodes inside, their pictures, shapes, sounds, scripts and script fields) is
the component's, the same for every instance. To change those, edit the component: every instance
follows.

## Make Unique: one instance on its own

Sometimes one coin should be different: a big golden coin worth more. Select its instance and
press **Make Unique** in the inspector. The editor copies the component into a new one (`coin_2`)
and points this instance at the copy. Edit the copy (**Edit coin_2**) without touching the other
coins.

Undo points the instance back at the original component (the copy stays in the project).

## Renaming and removing

**Rename:** right-click the component in the browser > **Rename**, type the new name, press Enter.
The file is renamed, and every instance follows. A component's name is its file's name: it can't
be empty or used by another component (ignoring upper and lower case). Renaming can't be undone
(it renames a file): rename it back instead.

**Remove:** right-click > **Remove from Project...** (or the trash button at the top of the
browser). The dialog says how many nodes use it, and offers to keep the file or delete it.

## Components in scripts

Scripts add instances while the game runs: a bullet each time the player fires, a coin dropped by
a defeated enemy, waves of enemies.

The editor writes a constant for each component in `scripts/assets.odin` (`COMPONENT_COIN` for
`coin.component.xml`). Or give your script a field of type `e.ComponentAsset`: the inspector then
offers a list of the project's components for it (dragging a component from the browser onto a
script's code tab adds such a field for you).

```odin
Chest :: struct {
	using script: e.Script,
	// The inspector shows a picker of the project's components
	reward: e.ComponentAsset `export:"default=components/coin.component.xml"`,
	opened: bool,
}

@(init)
register_Chest :: proc "contextless" () {
	e.Script_Register(Chest, {
		update = proc(self: ^Chest, events: []sdl.Event, dt: f64) {
			if self.opened || !e.Input_IsActionJustPressed("ui_accept", self.game) do return
			self.opened = true
			// A coin where the chest is
			e.Scene_AddComponent(self.scene, self.reward, position = e.Node_GetWorldPosition(self.node))
		},
	})
}
```

Without a parent, the position is in the world: `{0, 0}` is the level's corner, which may well be
off screen. That's why the example uses the chest's own world position.

```odin
// Three coins in a row, under this node (positions relative to it)
for i in 0 ..< 3 {
	e.Scene_AddComponent(self.scene, COMPONENT_COIN, parent = self.node, position = {f32(i) * 40, 0})
}

// Keep the instance's root to remove it later
coin := e.Scene_AddComponent(self.scene, COMPONENT_COIN, position = {100, 200})
if coin != nil {
	e.Scene_RemoveComponent(self.scene, coin.id)
}
```

| Code | What it does |
|---|---|
| `e.Scene_AddComponent(scene, component, parent = nil, position = {})` | Adds an instance, with its scripts, at the start of the next frame. Returns its root node (nil, with a message in the Console, if the file can't be read) |
| `e.Scene_RemoveComponent(scene, root.id)` | Removes an instance, its whole tree. Only an instance's root is accepted |

Add as many instances as you like: the component's file is read once per game. See
[Scripts](scripts.md) for writing and attaching scripts.

## How it's stored

A component is a file in `components/`, holding its root node and everything under it:

```xml
<component name="coin">
	<node kind="Area" name="Coin">
		<node kind="AnimatedSprite" name="Sprite">
			<animation name="spin" sheet="assets/coin.png" columns="8" rows="1" start="0" end="7" fps="12" loop="true"/>
		</node>
		<node kind="CollisionShape" name="Shape" shape="Circle" radius="12"/>
	</node>
</component>
```

An instance in a scene is a Component node naming the file, with its own transform:

```xml
<node kind="Component" name="Coin3" x="420" y="180" component="components/coin.component.xml"/>
```

## Questions

**I changed one instance's sprite and they all changed.** That's what components do. Press **Make
Unique** on the instance first to give it its own copy.

**Save as component isn't doing anything.** The node is already an instance of a component (the
Console says so). Open its component instead.

**My script's coin appears in the wrong place.** Without a `parent`, the `position` is in the world,
not relative to the script's node: use `e.Node_GetWorldPosition(self.node)`, or pass `parent`.

**I can't add a node next to the root.** A component has one root: put new nodes inside it.
