---
title: Scripts
description: Write your game's code in Odin, attach it to nodes, set its fields in the inspector, and use events, assets and the engine from it.
order: 6
---

# Scripts

A scene on its own just sits there. **Scripts** make things happen: a ship that flies when you
press the arrow keys, a coin that disappears when the hero touches it, a door that opens when
every enemy is gone.

A script is **Odin code** attached to a node. The scripts of a project are the `.odin` files in
its `scripts/` folder. When you press Play (or Build Scripts), the editor compiles them into
your game together with the engine.

- [Making a script](#making-a-script)
- [What's in the new file](#whats-in-the-new-file)
- [The hooks: ready, update, draw, destroy](#the-hooks-ready-update-draw-destroy)
- [Exported fields](#exported-fields)
- [Editing fields in the inspector](#editing-fields-in-the-inspector)
- [Building: Ctrl+B and the Output tab](#building-ctrlb-and-the-output-tab)
- [The code editor](#the-code-editor)
- [Events and listeners](#events-and-listeners)
- [Assets in code: scripts/assets.odin](#assets-in-code-scriptsassetsodin)
- [Common engine calls](#common-engine-calls)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Making a script

1. Select the node the script is for (a Sprite, a CharacterMover...).
2. In the inspector's **Script** section, press **New...**.
3. The **New Script** dialog asks for a **Name**. Use a capital letter first and only letters,
   digits and `_`: `PlayerController`, `Coin`, `EnemyAI`.
4. Leave **Kind** on **Node script (attached to a node)**. (The other kinds, global scripts and
   data types, are on [their own page](globals_data_saves.md).)
5. Press **Create**.

The editor writes `scripts/player_controller.odin` (the name in snake case), attaches the script
to the selected node, opens the file in a code tab and builds the scripts so the inspector can
show its fields.

Other ways in:

| Where | What it does |
|---|---|
| **Scripts > New Script...** | The same dialog (attaches the script to the selected node, if any) |
| Right-click a node in the scene tree > **Add Script...** | New Script for that node. On a node that has a script, the item reads **Open Script (Name)** |
| The inspector's **Script** dropdown | Attach a script you already wrote, or **None** to take it off |
| The inspector's **Open in Editor** | Opens the node's script in the code editor |
| The browser's **Scripts** folder | Every script file. Its preview lists the scripts the file registers and the nodes using each (click one to go there) |

One script can go on many nodes: every coin can run the same `Coin` script, each with its own
field values. A node can also run [several scripts](scripts_node_types_hot_reload.md).

## What's in the new file

Here is what New Script writes for a script named `Mover`:

```odin
package scripts

import e "engine:."
import sdl "vendor:sdl3"

/*
Mover: attach it to a node in the editor's inspector (Script).

Fields tagged `export:""` show in the inspector and are saved in the scene. Options inside the
quotes: default=<value> min=<n> max=<n> kind=scene. Untagged fields are the script's own state.
self.node is the node it's attached to; self.scene and self.game are there too.
*/
Mover :: struct {
	using script: e.Script,
	speed: f32 `export:"default=100 min=0"`,
}

@(init)
register_Mover :: proc "contextless" () {
	e.Script_Register(Mover, {
		// Once, when the scene starts: every node exists (e.Scene_FindNode(self.scene, "World/Ship"))
		ready = proc(self: ^Mover) {
		},
		// Every frame, after the node's own update
		update = proc(self: ^Mover, events: []sdl.Event, dt: f64) {
		},
	})
}
```

Part by part:

| Part | What it is |
|---|---|
| `package scripts` | Every file in `scripts/` belongs to one Odin package, so your scripts can use each other's types and procedures |
| `import e "engine:."` | The Crossfire Engine. Everything it has is `e.Something` |
| `import sdl "vendor:sdl3"` | SDL, the library under the engine. `update` receives SDL events and colors are `sdl.Color` |
| `Mover :: struct { ... }` | The script's data. Each node running the script gets its own copy |
| `using script: e.Script` | **Must be the first field.** It gives the script `self.node` (the node it's on), `self.scene` (that node's scene) and `self.game` (the running game). `using` lets you write `self.node` rather than `self.script.node` |
| `speed: f32 ...` | An **exported field**: the backquoted tag makes it show in the inspector (see below) |
| `@(init)` | Runs the procedure when the game program starts, before anything else. That's how the engine learns about your script without a list somewhere |
| `proc "contextless" ()` | Odin requires `@(init)` procedures to be "contextless". `Script_Register` sets up what it needs, so just keep this line as it is |
| `e.Script_Register(Mover, {...})` | Tells the engine "there's a script called Mover, and here is its code". Scene files attach it by that name |
| `ready = proc(self: ^Mover) {...}` | The hooks: procedures the engine calls at certain moments. `self` is this node's copy of the struct |

## The hooks: ready, update, draw, destroy

Every hook is optional: leave out the ones you don't need.

| Hook | When it runs | Typical use |
|---|---|---|
| `ready = proc(self: ^T)` | Once, on the first frame the node is in the scene. Every node of the scene exists by then | Find other nodes, set the starting state |
| `update = proc(self: ^T, events: []sdl.Event, dt: f64)` | Every frame, after the node's own update. `dt` is the time since the last frame, in seconds | Movement, input, timers |
| `draw = proc(self: ^T, renderer: ^sdl.Renderer)` | After the node draws, in the node's own space | Extra drawing (a health bar over an enemy) |
| `destroy = proc(self: ^T)` | When the node is removed | Tidy up (stop a sound, tell a manager). The struct itself is freed for you |

Bodies (DynamicBody, CharacterMover, Area...) can also have `collisionEnter`, `collisionExit`,
`areaEnter` and `areaExit` hooks; [events](#events-and-listeners) are another way to hear about
collisions.

**Multiply by `dt`** for anything that moves over time: `speed * f32(dt)` moves `speed` pixels a
second however fast the computer is.

A complete script that spins its node and counts the turns:

```odin
Spinner :: struct {
	using script: e.Script,
	// Degrees a second (shown in the inspector)
	speed: f32 `export:"default=90 min=0 max=720"`,
	// The script's own state (not shown, not saved in the scene)
	turns: int,
}

@(init)
register_Spinner :: proc "contextless" () {
	e.Script_Register(Spinner, {
		ready = proc(self: ^Spinner) {
			log.infof("%s starts spinning", self.node.name)
		},
		update = proc(self: ^Spinner, events: []sdl.Event, dt: f64) {
			self.node.rotation += self.speed * f32(dt)
			if self.node.rotation >= 360 {
				self.node.rotation -= 360
				self.turns += 1
			}
		},
		destroy = proc(self: ^Spinner) {
			log.infof("%s spun %d times", self.node.name, self.turns)
		},
	})
}
```

(`log` is `import "core:log"`; its messages show in the editor's **Console** tab while the game
plays. The engine's own logging adds a level and a category to each line: see
[Logging](#logging).)

## Logging

Write to the Console with `e.Log_Debug`, `e.Log_Info`, `e.Log_Warning` and `e.Log_Error`. The
text is formatted like `fmt.printf` (`%d` for numbers, `%v` for anything, `%.2f` for two
decimals), and `category` says what the line is about:

```odin
e.Log_Info("Level %d started", 3)
e.Log_Warning("Low health: %d", 12, category = "player")
e.Log_Debug("Path from %v to %v", [2]f32{0, 0}, [2]f32{100, 40}, category = "ai")
e.Log(.Error, "save", "Couldn't write slot %d", 2)
```

| Level | For | Shown |
|---|---|---|
| `.Debug` | Details for finding a problem | In games played from the editor; exported games leave them out unless they call `e.Log_SetLevel(.Debug)` |
| `.Info` | What happens as the game runs | Always |
| `.Warning` | Something unexpected the game carries on from | Always, in yellow |
| `.Error` | Something that failed | Always, in red |

A line without a category is in **game**. Pick short names, one per part of your game ("player",
"ai", "save"): the Console's category menu lists every one it has seen, so you can show only the
part you're working on. The other categories you'll see:

| Category | What |
|---|---|
| **engine** | The engine's own messages (the scene it plays, the renderer, warnings about your scenes) |
| **SDL** | SDL's messages (the windowing, graphics and sound library under the engine) |
| **editor** | The editor's messages (opened, saved, imported...) |
| **plugin** | [Editor plugins](plugins.md)' messages |
| **build**, **export** | Building and exporting, in the Output tab |

`log.info` and the rest of `core:log` still work: their lines are in **game** (or **engine** for
the engine's). Plain `fmt.println` lines show too, as **game** Info lines.

**In an exported game** the lines go to the game's standard output (a terminal, when you start it
from one) and to the computer's log: the debugger's output on Windows, the Console app on macOS,
the browser's console on the web. Each line reads the same everywhere:

```text
[INFO ] [engine] Playing 'Legacy of the Wardens' (10 scenes, start: TitleScene, 27 scripts registered)
[WARN ] [player] Low health: 12
```

## Exported fields

A field with an `export:""` tag is **exported**: it shows in the inspector, and the value you
set there is saved in the scene. That's how one `Enemy` script makes a slow goblin and a fast
bat: same code, different values.

Inside the quotes go options, separated by spaces:

| Option | Meaning | Example |
|---|---|---|
| `default=<value>` | The value a new node starts with (else zero, white for colors, the first value for enums) | `default=100`, `default=#ff8080`, `default=64, 0` |
| `min=<n>`, `max=<n>` | The smallest and largest number the inspector allows | `min=0 max=500` |
| `kind=scene` | A string that names a scene: the inspector offers the project's scenes | |
| `kind=<DataType>` | A data resource field that only lists resources of that type | `kind=EnemyStats` |

Fields without the tag are the script's own state: not shown, not saved, starting at zero each
time the scene starts.

The field types the inspector knows:

```odin
Mood :: enum {
	Calm,
	Angry,
	Scared,
}

Enemy :: struct {
	using script: e.Script,
	speed: f32 `export:"default=120 min=0 max=500"`,
	health: int `export:"default=3 min=1"`,
	flying: bool `export:""`,
	title: string `export:"default=Goblin"`,
	nextLevel: string `export:"kind=scene"`,
	patrol: [2]f32 `export:"default=64, 0"`,
	tint: sdl.Color `export:"default=#ff8080"`,
	mood: Mood `export:"default=Calm"`,
	hurtSound: e.SoundAsset `export:""`,
	stats: e.DataAsset `export:"kind=EnemyStats"`,
	loot: e.ComponentAsset `export:""`,
	body: ^e.Sprite `export:"default=Sprite"`,
	camera: ^e.Camera2D `export:"default=../Camera"`,
	// Not exported: the script's own
	time: f64,
}
```

| Type | In the inspector |
|---|---|
| `f32`, `f64`, `int`, `i32` | A number field, kept between `min` and `max` |
| `bool` | A checkbox |
| `string` | A text box (with `kind=scene`, a dropdown of scenes) |
| `[2]f32` | Two numbers, x and y |
| `sdl.Color` | A color picker |
| An enum | A dropdown of its values |
| `e.TextureAsset`, `e.SoundAsset`, `e.MusicAsset`, `e.FontAsset`, `e.ComponentAsset`, `e.AnimationAsset`, `e.DataAsset` | A dropdown of the project's assets of that kind |
| A pointer to a node: `^e.Sprite`, `^e.Camera2D`, `^e.Node`... | A dropdown of the scene's nodes of that kind |

### Node fields

A node field holds a **path** from the script's node to another node, like a file path:
`Sprite` is a child named Sprite, `../Camera` a sibling named Camera, `/World/Door` a path from
the top of the scene. Just before `ready`, the engine sets the field to that node. If the node
isn't there, or isn't of the field's kind, the field stays `nil` and the Console shows a
warning, so check for `nil` before using one you might not have set.

**Renaming or moving nodes keeps node fields pointing at the same nodes** (once the scripts are
built, so the editor knows which fields hold nodes): a path that no longer leads to its node is
rewritten, and a field still on its default gets a value of its own. A path written from the top
(`/World/Door`) stays one.

A quick way to make one: **drag a node from the scene tree onto the script's struct in a code
tab**. The editor adds a field of the node's kind, named after the node, with its path as the
default. (Dropped in a procedure instead, it writes code using the node, adding the field too:
[Dragging things into the code](code_editor.md#dragging-things-into-the-code).)

### Asset fields

An asset field (`hurtSound: e.SoundAsset`) lets each node pick its own asset in the inspector.
**Dragging an asset from the browser onto a code tab** adds one for you, defaulting to that
asset, with a comment showing how to use it.

## Editing fields in the inspector

Once the scripts are built, the inspector's **Script** section shows a row per exported field,
under the Script dropdown. Hover a field's name to see its type, range and default. Every change
is undoable (Ctrl+Z), and only values that differ from the default are written to the scene.

The editor also reads the scripts' **source** as you type or save them (the script index): a field
you add shows in the inspector a moment later, before any build, with "From the source: not
built yet" over the fields ("From the last build" once it's built). Once the scripts are built, the build's description is used
for every file that hasn't changed since. When the editor can't tell (a script it can't read yet),
the inspector says "Build the scripts (Ctrl+B) to edit Mover's fields." and lists the stored
values, read only. Nothing is lost meanwhile.

Values are never dropped silently: a value stored for a field the script no longer has (renamed or
removed in the code) is listed under the fields as kept, with a **×** to remove it, and a value that
no longer fits its field's type (a number field that became a `bool`) is flagged with a **Reset**.
To rename a field and keep its values, rename it with **F2** in the code tab: the values, listeners
and Timeline tracks follow ([Code and scenes, linked](code_editor.md#code-and-scenes-linked)).

## Building: Ctrl+B and the Output tab

**Scripts > Build Scripts** (Ctrl+B) compiles the scripts without starting the game. The editor
also builds once in the background when a project with scripts opens, after New Script, and
whenever you press Play with changed scripts.

- The compiler's messages go to the bottom panel's **Output** tab (Ctrl+J shows the bottom
  panel). An error names the file, line and column: **click the error** (or right-click it and
  choose **Go to Error**) to open the script at that spot, fix it and build again. A crash or a
  failed `assert` while the game runs names its place the same way in the Console, and clicks
  the same way. See [Going to an error](code_editor.md#going-to-an-error-from-the-output-tab-or-the-console).
- After a good build the Output tab lists what it found: `3 scripts: Coin, Hero, Mover` (and data
  types and node types, if any). The inspector's dropdowns use that list.
- The Script section's header shows "building..." during a build and "build failed: see Output"
  after a failed one.

Building needs Odin and a linker; **Edit > Settings... > Toolchain** checks them, and can install
Odin for you.

## The code editor

Scripts open in **code tabs** beside the scene tabs, in the editor's built-in code editor:

- **Completion** from the Odin language server (OLS): type `e.` to list the engine's procedures,
  or `self.` for your struct's fields.
- Errors and warnings marked as you type, go to definition, find references, quick fixes.
- **Ctrl+W** closes the code tab; saving a script (and Play) saves the open tabs.
- Drops: almost anything dragged onto a code tab becomes code: a field in the struct, a statement
  in a procedure, its constant on a call's argument (Shift: the other choices). See the code
  editor's [Dragging things into the code](code_editor.md#dragging-things-into-the-code).
- Your project in the code: its constants complete, hovers say what they name and which nodes run
  a script, `export` tags the inspector can't use are flagged, and `Script_Register` lines and
  exported fields show who uses and sets them (click to open the node).
- **Find Usages** (Alt+Shift+F12) lists the nodes using a script, a field or an event, and
  **Rename** (F2) renames a script, a field or an event in the code and in every scene and
  component ([Code and scenes, linked](code_editor.md#code-and-scenes-linked)).
- Names in strings: inside `e.Game_ChangeScene(self.game, "...")`, `e.Node_FindPath(self.node,
  "...")`, `e.AnimationPlayer_Play(&self.sprite.animation, "...")` and the other engine calls
  that take a name, the project's names of that kind complete, and one it doesn't have is
  underlined with a quick fix ([Names in strings](code_editor.md#names-in-strings-scenes-nodes-animations)).
- **Ctrl+.** offers code actions where they apply: handle a node field's event (the handler and
  its subscription in `ready`), export a field (with a range), a switch over a state machine's
  states, register a struct, add a hook, show a field in the inspector. In the inspector,
  Ctrl+click a script field's label (or right-click > **Go to Declaration**) to open it in the
  code ([Code actions](code_editor.md#code-actions-ctrl)).

You can use another program instead: untick **Edit > Settings... > Editor > Code editor** and
set its path and arguments there (Zed by default). The editor writes `scripts/ols.json` so that
program's Odin language server finds the engine too.

The [code editor page](code_editor.md) covers its keys, search, and settings.

## Events and listeners

Nodes **announce things** through events: a body was hit, a sound finished, a menu button was
pressed, a CharacterMover landed. A script can **listen** to another node's event without any
code to find that node.

The examples below use a Hero script that counts the coins it picks up:

```odin
Hero :: struct {
	using script: e.Script,
	// Coins picked up so far
	coins: int,
}
```

### Listening to an event

1. Select the node whose event you want (say, a coin's Area).
2. In the inspector's **Events** section press **Show**. Each event is listed with what it means
   (hover its name).
3. Press **Listen...** beside the event. A dialog lists the scene's nodes that have a script:
   choose the one that should react (the Hero).
4. The editor stores the listener on the node and adds a **handler** to the listener's script
   file, then puts the cursor inside it:

```odin
// Coin's onCollisionEnter (Events in Coin's inspector): A body started touching it (an Area: a body came in)
Hero_onCoinCollisionEnter :: proc(self: ^Hero, source: ^e.Node, data: e.EventData) {
	// collision := e.Collision_FromEvent(data)
	self.coins += 1
}

@(init)
register_Hero_onCoinCollisionEnter :: proc "contextless" () {
	e.Script_Listener(Hero, "onCoinCollisionEnter", Hero_onCoinCollisionEnter)
}
```

- `self` is the listening script (the Hero's), `source` the node whose event it is (the coin),
  `data` what the event carries. The comment line shows how to read it for this event.
- The listener is shown under its event in the Events section; **×** removes it.

### Events of your own

A script can publish its own events: a coin saying "I was collected", a boss saying "phase two".

1. Select a node with the script. In the Events section, beside the script's name, press
   **New Event...**.
2. Give it a **Name** (`onCollected`), **What it means** (shown to whoever listens), and its
   **Data**: Nothing, a whole number, a number, true or false, text, or a node.
3. **Create** adds the event to the script's struct, with a comment on how to fire it:

```odin
Coin :: struct {
	using script: e.Script,
	// The hero picked up a coin. Fire it: e.Event_Notify(&self.onCollected, self.node, 42)
	onCollected: e.EventSubject `event:"The hero picked up a coin" data:"value := data.(int)"`,
}
```

Fire it from your code when it happens:

```odin
Coin_Collect :: proc(self: ^Coin) {
	e.Event_Notify(&self.onCollected, self.node, 1)
	e.Game_PlaySound(self.game, SOUND_COIN)
	e.Scene_RemoveNode(self.scene, self.node.id)
}
```

After a build (Ctrl+B) the event appears in the Events section of every node with that script,
with its own **Listen...** button. The handler reads the data the way the tag says:

```odin
Hero_onCoinCollected :: proc(self: ^Hero, source: ^e.Node, data: e.EventData) {
	value := data.(int)
	self.coins += value
}
```

Global scripts have events too (the **Globals** part of the Events section, with **+ Event**):
see [Globals, data and saves](globals_data_saves.md).

## Assets in code: scripts/assets.odin

The editor keeps a file `scripts/assets.odin` with a **constant for every asset** of the project,
rewritten whenever you import, remove or add one, and before every build:

```odin
package scripts

import e "engine:."

TEXTURE_SHIP :: e.TextureAsset{"assets/ship.png"}
SOUND_COIN :: e.SoundAsset{"assets/coin.wav"}
SOUND_LASER :: e.SoundAsset{"assets/laser.wav"}
MUSIC_THEME :: e.MusicAsset{"assets/theme.ogg"}
FONT_PIXEL :: e.FontAsset{"assets/pixel.ttf"}
COMPONENT_BULLET :: e.ComponentAsset{"components/Bullet.component.xml"}
COMPONENT_COIN :: e.ComponentAsset{"components/Coin.component.xml"}
ATLAS_ITEMS :: "atlases/items.atlas.xml"
DATA_GOBLIN :: e.DataAsset{"data/goblin.data.json"}  // EnemyStats

ACTION_JUMP :: "jump"

// Animations, per animation set and per AnimatedSprite with its own: e.AnimationPlayer_Play(&sprite.animation, ANIM_HERO_RUN)
// - assets/characters/hero.aseprite
ANIM_HERO_IDLE :: "idle"
ANIM_HERO_RUN :: "run"

// State machines' states and parameters: e.StateMachine_SetFloat(brain, PARAM_HERO_BRAIN_SPEED, speed)
// - Brain in component hero
STATE_HERO_BRAIN_IDLE :: "idle"
PARAM_HERO_BRAIN_SPEED :: "speed"

// Node groups: e.Scene_GetGroup(scene, GROUP_ENEMIES)
GROUP_ENEMIES :: "enemies"

// Mix buses: e.Audio_SetBusVolume(BUS_MUSIC, 0.5)
BUS_MASTER :: "Master"
BUS_MUSIC :: "Music"

// Scenes: e.Game_ChangeScene(game, SCENE_FOREST_SCENE)
SCENE_FOREST_SCENE :: "ForestScene"
SCENE_GAME_OVER :: "GameOver"

// Dialogue nodes: e.Dialogue_Start(runner, data, DIALOGUE_NODE_STORY_START)
DIALOGUE_NODE_STORY_START :: "Start"

// Node paths: in a component from its root, in a scene from its top level ("/"). e.Node_FindPath(self.node, PATH_HERO_SPRITE)
// - scene ForestScene
PATH_FOREST_SCENE_HUD :: "/HUD"
PATH_FOREST_SCENE_HUD_BOSS_BAR :: "/HUD/BossBar"
// - component hero
PATH_HERO_SPRITE :: "Sprite"
```

An **asset's** constant is its file's name in capitals, anything but letters and digits turned into
one underscore: `hero-run.png` is `TEXTURE_HERO_RUN`, `boss fight.ogg` is `SOUND_BOSS_FIGHT`.

| Prefix | Assets |
|---|---|
| `TEXTURE_` | Images (and Aseprite files) |
| `SOUND_`, `MUSIC_` | Sounds, and sounds used as streamed music |
| `FONT_` | Fonts |
| `COMPONENT_` | Components (saved node trees) |
| `DATA_` | Data resources |
| `ANIMATION_` | Animation assets (and Aseprite files' tags) |
| `SHADER_`, `ATLAS_`, `DIALOGUE_`, `LDTK_` | Shaders, atlases, dialogues, LDtk projects |
| `ACTION_`, `ACHIEVEMENT_` | Input action names, Steam achievement names |

### Names of everything else

The file also has a constant for the names your code passes to the engine as strings, so a typo
or a renamed animation is a compile error instead of something that quietly doesn't happen:

| Constant | Its value | Use it with |
|---|---|---|
| `ANIM_<SET>_<NAME>` | An animation's name, per animation asset (`animations/boar.anim.xml`: `ANIM_BOAR_RUN`) and per Aseprite file with tags (`hero.aseprite`: `ANIM_HERO_RUN`) | `e.AnimationPlayer_Play(&sprite.animation, ANIM_BOAR_RUN)` |
| `ANIM_<OWNER>_<SPRITE>_<NAME>` | An animation of an AnimatedSprite that has its own (not an asset's): OWNER is its scene or component | the same |
| `STATE_<OWNER>_<MACHINE>_<STATE>`, `PARAM_<OWNER>_<MACHINE>_<PARAM>` | A StateMachine node's states and parameters | `e.StateMachine_SetBool(brain, PARAM_HERO_BRAIN_ON_FLOOR, true)` |
| `GROUP_<NAME>` | A group any node is in | `e.Scene_GetGroup(self.scene, GROUP_ENEMIES)` |
| `BUS_<NAME>` | A mix bus (Master too) | `e.Audio_SetBusVolume(BUS_MUSIC, 0.5)` |
| `SCENE_<NAME>` | A scene's name | `e.Game_ChangeScene(self.game, SCENE_GAME_OVER)` |
| `DIALOGUE_NODE_<DIALOGUE>_<NODE>` | A node of a dialogue | `e.Dialogue_Start(runner, data, DIALOGUE_NODE_STORY_START)` |
| `PATH_<COMPONENT>_<NODE>...` | A node's path in a component, from its root (the node the component is, where its root's scripts run) | `e.Node_FindPath(self.node, PATH_HERO_SPRITE)` |
| `PATH_<SCENE>_<NODE>...` | A node's path in a scene, from the scene's top level: it starts with `/`, so it works from any node; a Component instance's own nodes are listed under it | `e.Node_FindPath(self.node, PATH_FOREST_SCENE_HUD_BOSS_BAR)`, `e.Scene_FindNode(self.scene, PATH_FOREST_SCENE_HUD)` |

How these names are made:

- **Words are split as you wrote them:** `bossBar`, `BossBar`, `boss bar` and `boss_bar` are all
  `BOSS_BAR`; `HUDBar` is `HUD_BAR`; `ForestScene` is `FOREST_SCENE`. (Asset, action and
  achievement constants keep the names they've always had, without the split, so code using them
  keeps building: `ACTION_MOVELEFT` for `moveLeft`.)
- **A path joins its nodes' names:** the HUD's BossBar in ForestScene is
  `PATH_FOREST_SCENE_HUD_BOSS_BAR`.
- **The file stays in the same order when you save:** each kind has its section, under a comment,
  and inside it a `// - ...` line for each animation set, state machine, scene or component.
  Scenes, components, groups and paths are sorted by name (moving a node among its siblings
  changes nothing); a set's animations and a machine's states and parameters keep their order.
- **Two things that would get the same name** (nodes `Boss Bar` and `BossBar` side by side): the
  first in that order keeps it, the next gets `_2`, then `_3`. Asset constants come first, so
  theirs never change.
- An Aseprite file without tags gets no `ANIM_` constants (it plays its frames as `default`).
- Nodes with the same name side by side share a path: it's listed once (`Node_FindPath` finds the
  first).

The file is written when you save the project and before every build, so a node or animation you
just added gets its constant once you save. Constants nothing uses yet don't make the next Play
build the game again: only a change to one your scripts use does.

Use these rather than typing paths: a typo is a compile error instead of a missing sound, the
code editor completes them (first, in an engine call that takes that kind of name), and removing an asset turns every place that used it into a build
error you can find. **Don't edit this file**: the editor rewrites it. (If you remove its first comment line, the
editor treats the file as yours and stops updating it.)

## Common engine calls

All of these take what a script already has: `self.node`, `self.scene`, `self.game`.

| Code | What it does |
|---|---|
| `self.node.position`, `.rotation`, `.scale`, `.visible`, `.name` | The node the script is on |
| `e.Scene_FindNode(self.scene, "World/Door")` | Another node, by name or by a path from a top-level node (`nil` if none) |
| `e.Node_FindPath(self.node, "../Camera")` | A node by a path from this one |
| `e.Node_GetScript(node, Health)` | A node's script of a type (`nil` if it has none) |
| `e.Node_Is(node, e.Sprite)` | Whether a node is of a kind, before `cast(^e.Sprite)node` |
| `e.Input_IsActionPressed("jump")`, `e.Input_IsActionJustPressed("jump")` | Input actions (see [Input](input.md)) |
| `e.Game_PlaySound(self.game, SOUND_COIN)` | Plays a sound once |
| `e.Scene_AddComponent(self.scene, COMPONENT_BULLET, position = ...)` | Adds a copy of a component (a bullet, an explosion) |
| `e.Scene_RemoveNode(self.scene, node.id)` | Removes a node and its children (next frame) |
| `e.Asset_Texture(self.game, TEXTURE_SHIP)` | An image, for a Sprite's `texture` |
| `e.Game_ChangeScene(self.game, SCENE_LEVEL_2)` | Goes to another scene (its constant, or its name: `"Level2"`) |
| `e.Global(GameState)` | A global script (see [Globals, data and saves](globals_data_saves.md)) |

A gun that shoots on the "shoot" action:

```odin
Gun :: struct {
	using script: e.Script,
}

@(init)
register_Gun :: proc "contextless" () {
	e.Script_Register(Gun, {
		update = proc(self: ^Gun, events: []sdl.Event, dt: f64) {
			if e.Input_IsActionJustPressed("shoot") {
				e.Game_PlaySound(self.game, SOUND_LASER)
				e.Scene_AddComponent(self.scene, COMPONENT_BULLET, position = e.Node_GetWorldPosition(self.node))
			}
		},
	})
}
```

(`e.Node_GetWorldPosition` is where the node is in the scene, whatever its parents. A component
added without a parent goes at the top level, so it needs the world position.)

More ways to look around from a script:

```odin
Calls :: proc(self: ^Enemy) {
	// Another node of the scene, by name or by a path from a top-level node
	if door := e.Scene_FindNode(self.scene, "World/Door"); door != nil do door.visible = false
	// A node from this one: a child, or ../ for a sibling
	sword := e.Node_FindPath(self.node, "Sword")
	_ = sword
	// Another script on this node
	if spinner := e.Node_GetScript(self.node, Spinner); spinner != nil do spinner.speed = 0
	// A node of a kind
	player := e.Scene_FindNode(self.scene, "Player")
	if e.Node_Is(player, e.Sprite) {
		sprite := cast(^e.Sprite)player
		sprite.texture = e.Asset_Texture(self.game, TEXTURE_SHIP)
	}
	// Another scene
	if self.health <= 0 do e.Game_ChangeScene(self.game, SCENE_GAME_OVER)
	// The scene's name
	log.infof("in %s", self.scene.name)
}
```

Scripts **don't run in the viewport**: the editor shows the scene as it starts. Press Play (F5)
to see them work.

## How it's stored

A node's script and the field values you changed are in the scene file:

```xml
<node kind="Sprite" name="Goblin" texture="assets/goblin.png">
	<script name="Enemy">
		<prop name="speed" value="80"/>
		<prop name="camera" value="../Camera"/>
	</script>
	<listener event="onCollisionEnter" target="../Hero" handler="onCoinCollisionEnter"/>
</node>
```

## Questions

**My script isn't in the Script dropdown.** Build the scripts (Ctrl+B). If the Output tab shows
errors, fix them first. Check the file calls `e.Script_Register` from an `@(init)` procedure.

**The build says `@(init)` procedures must be contextless.** Write
`proc "contextless" ()`, as the template does.

**My field doesn't show in the inspector.** It needs the `export:""` tag (with backquotes around
it), a type from the table above, and a build.

**My node field is nil.** The path doesn't lead to a node of that kind. Pick the node again in
the inspector's dropdown, and check the Console for the warning.

**Things move faster on a faster computer.** Multiply by `dt`.

**My `e.Log_Debug` lines don't show in the exported game.** Exported games leave debug lines
out. Call `e.Log_SetLevel(.Debug)` (in a global script's `ready`, say) to keep them.

**The Console doesn't show my line.** Check its filters: the level buttons, the category menu
and the search box (the header says "12 of 340 lines" when some are hidden). Right-click a line
and choose **Show Everything** to turn them all off.

**Can I see a script run without playing?** No: the viewport doesn't run scripts. Play, and use
the [Live tab](live.md) to look inside the running game.

**Can I change a script while the game plays?** Yes: save it and the game restarts where it was
([hot reload](scripts_node_types_hot_reload.md)).
