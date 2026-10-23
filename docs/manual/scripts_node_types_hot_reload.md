---
title: Several scripts, node types and hot reload
description: Give one node several scripts, make node types of your own from game code (a Player that is a Sprite with its own code), and change scripts while the game plays without starting over.
order: 6
---

# Several scripts, node types and hot reload

A **script** is Odin code attached to a node: a struct with your fields and procedures the game
calls (`ready` once, `update` every frame, `draw`, `destroy`). The scripts of a project are the
`.odin` files in its `scripts/` folder; the editor builds them into the game when you press
Play or Build Scripts (Ctrl+B).

This page covers three things built on scripts:

- [Several scripts on one node](#several-scripts-on-one-node): a node can run a `Health` script
  and a `Blinker` script at once, each with its own fields.
- [Node types of your own](#node-types-of-your-own): code that makes a new kind of node, a
  `Player` that is a Sprite with its own fields and code, listed in Add Node like the built-in
  kinds.
- [Hot reload](#hot-reload-changing-scripts-while-the-game-plays): save a script while the game
  plays and it restarts where it was, with your change in it.

## Several scripts on one node

Small scripts that each do one thing are easier to write and to reuse than one big script per
node. A `Health` script can go on the player, the enemies and the crates; a `Blinker` script on
anything that should flash.

### Adding them

1. Select the node. The inspector's **Script** section shows its first script (or None).
2. Choose its first script from the **Script** dropdown, or make one with **New...**.
3. Once it has one, **Add script** lists the project's other scripts. Choose one: it's added
   under the first, with its own fields. Add as many as you like; a node has each script once.

Each added script has a title row with **Open** (the script's code in the code editor) and **×**
(remove it from the node). Removing the first script makes the next one the first.

Every change is undoable (Ctrl+Z), like any other edit.

### What the game does with them

- The node's scripts run **in order**: the first script's `ready`, then the next one's, and so
  on; the same for `update`, `draw` and `destroy`.
- Each script has its own fields, set from the inspector.
- Events a script publishes, collision events and listeners work for every script of the node.
- A script finds its node's other scripts with `e.Node_GetScript`:

```odin
Health :: struct {
	using script: e.Script,
	hp: int `export:"default=10"`,
}

Blinker :: struct {
	using script: e.Script,
	// Blinks a second
	rate: f32 `export:"default=4"`,
	time: f64,
}

blinkerUpdate :: proc(self: ^Blinker, events: []sdl.Event, dt: f64) {
	self.time += dt
	// The same node's Health script, if it has one: blink while it's low
	if health := e.Node_GetScript(self.node, Health); health != nil && health.hp < 3 {
		self.node.visible = int(self.time * f64(self.rate)) % 2 == 0
	}
}
```

- The Timeline can key any script's fields (`hp (script)`). When two scripts of a node have a
  field of the same name, the first one's is used.

### In the scene file

Each script is a `<script>` element inside the node, in order:

```xml
<node kind="Sprite" name="Hero" texture="assets/hero.png">
	<script name="Health"><prop name="hp" value="25"/></script>
	<script name="Blinker"/>
</node>
```

## Node types of your own

Sometimes a thing in your game is really a new kind of node: a `Player` is a Sprite that also has
lives, a speed and code. A **node type** is that: a struct of your code that **starts with a
built-in node type**, registered so the editor and the game know it.

```odin
package scripts

import e "engine:."
import sdl "vendor:sdl3"

// A Sprite with its own fields: its first field is the Sprite it is
Player :: struct {
	using sprite: e.Sprite,
	speed: f32 `export:"default=200"`,
	lives: int `export:"default=3"`,
}

@(init)
registerPlayer :: proc "contextless" () {
	e.NodeType_Register(Player, .Sprite, {
		ready = proc(self: ^Player) {
			self.lives = 3
		},
		update = proc(self: ^Player, events: []sdl.Event, dt: f64) {
			self.position.x += self.speed * f32(dt)
		},
	})
}
```

- The first field must be the built-in type the second argument names: `using sprite: e.Sprite`
  for `.Sprite`, `using body: e.CharacterMover` for `.CharacterMover`, and so on. The game refuses
  (with a message) a struct that doesn't start with it.
- Fields tagged `export:""` are edited in the inspector, as script fields are.
- `ready`, `update`, `draw` and `destroy` are the same hooks scripts have. They run **before**
  the node's scripts, so a script on a Player sees the Player's update done.
- Since the node **is** a Player, code reaches its fields straight away:
  `player := cast(^Player)node`, after checking with `e.Node_Is(node, Player)`.

### Using it in the editor

1. Build the scripts (Ctrl+B). The Output tab says `1 node type: Player`.
2. Open **Add Node** (Ctrl+Shift+A). Your node types are listed last, under **Your node types**
   (search finds them by name, or by the kind they're built on: "sprite").
3. Choose **Player**. The node is a Sprite in the editor: it has a Sprite's settings (image,
   centering...), draws as one in the viewport, and is named Player.
4. The inspector has a **Player** section above the Script section: Open (its code) and its
   fields. The node can also have scripts, like any other.

A node type can be a component's root too: New Component lists them.

In the scene file the node keeps both names, so a game built without your code (or before it's
built) still has a Sprite:

```xml
<node kind="Player" baseKind="Sprite" name="Player" texture="assets/hero.png">
	<prop name="lives" value="5"/>
</node>
```

If the code no longer registers `Player`, the game builds a plain Sprite and logs a warning.

## Hot reload: changing scripts while the game plays

Normally a script change needs the game stopped, built and started again, and then played back
to where you were. With hot reload, **save the script while the game plays**:

1. The editor notices the change (from its own code editor or any other editor) and builds the
   game again **in the background**. The game keeps running meanwhile; the build's messages go
   to the Output tab.
2. When the build is done, the game saves its state, the editor stops it and starts the new
   build **in the same scene**, then puts the state back:
   - the globals (what a save game holds: score, inventory...);
   - every node's position, rotation, scale, color, visibility, animation, state machine state;
   - every script field and node type field of every node.
3. The Console says `Hot reload: restored 42 nodes`, and you play on with the new code.

**What starts over:** things made while playing (bullets, spawned enemies, particles), physics
speeds, timers and tweens in flight, and sounds playing. Fields of a script that aren't exported
(no `export:""` tag) start from their initial values, unless they're in a global.

**A script that doesn't build:** the game goes on with the old code. The Console says
`Hot reload: the scripts don't build`; the errors are in the Output tab. Fix them and save
again.

**Turning it off:** Edit > Settings > Editor > **Hot reload**. Off, saving a script while the game
plays does nothing to the game (Play builds the new code next time).

Hot reload works for games started with Play from the editor; exported games never reload.

### From the command line

The editor uses two things the player program has, which also work by hand:

- With `--live`, the game reads commands on its standard input; `snapshot <file>` writes its
  state to a file as JSON.
- `player <project> --restore <file>` starts the game where a snapshot left off.

## Questions

**The Add script dropdown isn't there.** It shows once the node has a first script and the
project has other scripts to add, after the scripts were built (Ctrl+B).

**My node type isn't in Add Node.** Build the scripts first (Ctrl+B); if the build fails, the
Output tab says why. Check the struct's first field is the built-in type its registration names.

**Can a node have the same script twice?** No: each script once. Make two small scripts, or one
with a list.

**Which runs first, the node type or the scripts?** The node type's hook, then the scripts' in
their order.

**The game restarted but forgot something.** Only exported fields, globals and the node values
listed above carry over. Put what must survive in an exported field or a global.
