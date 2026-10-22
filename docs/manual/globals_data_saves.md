---
title: Globals, data resources and saves
description: Keep game-wide state in global scripts, put game data such as enemy stats in data resources edited in the inspector, and save and load the player's progress.
order: 7
---

# Globals, data resources and saves

Node scripts live and die with their scene: when the player goes from level 1 to level 2, the
level 1 nodes and their scripts are gone. Some things must outlast scenes, and some things
aren't code at all. This page covers three tools for that:

- [Global scripts](#global-scripts): code and state for the whole game: the score, the lives,
  settings, a music manager, a HUD drawn over every scene.
- [Data resources](#data-resources): game data in files you edit in the inspector: each enemy's
  health and speed, each ship's sprite, each item's price.
- [Saving games](#saving-games): `e.Save_Game()` and `e.Load_Game()` keep the globals' state
  between runs.

Read [Scripts](scripts.md) first: globals and data types are written the same way.

## Global scripts

A global is a script that isn't attached to a node. The game makes **one** of it when it starts
and keeps it until it quits, across every scene.

### Making one

1. **Scripts > New Script...** (or New... in a node's Script section).
2. Name it (`GameState`) and set **Kind** to **Global script (runs all game)**.
3. **Create** writes `scripts/game_state.odin`, adds it to the project's globals and opens it.

The new file:

```odin
package scripts

import "core:log"
import e "engine:."
import sdl "vendor:sdl3"

/*
GameState: a global script. It runs for the whole game, across scenes, from when the game
starts (Project Settings > Globals lists the globals and sets their exported fields; every Play
starts from those values).

Any script reaches it with e.Global(GameState). e.Save_Game() saves its state as JSON and
e.Load_Game() brings it back: fields that aren't exported (except save:"-" ones), and exported
ones tagged save:"" (exported fields are editor settings otherwise).
*/
GameState :: struct {
	using script: e.Script,
	// Set in Project Settings > Globals
	lives: int `export:"default=3 min=0"`,
	// The game's own state (saved, not shown in the editor)
	score: int,
}

@(init)
register_GameState :: proc "contextless" () {
	e.Script_Register(GameState, {
		// Once, when the game starts (after the scenes are built)
		ready = proc(self: ^GameState) {
			log.infof("Starting with %d lives", self.lives)
		},
		// Every frame, before the scene updates
		update = proc(self: ^GameState, events: []sdl.Event, dt: f64) {
		},
		// The game switched scenes
		sceneChanged = proc(self: ^GameState, scene: ^e.Scene) {
		},
		// Optional: draws over the scene, unmoved by the camera (a HUD). Set self.hidden to skip it
		// draw = proc(self: ^GameState, renderer: ^sdl.Renderer) {},
	})
}
```

It's an ordinary script registered with `e.Script_Register`. What makes it global is being in
the project's list of globals. A global has `self.game`, but `self.node` and `self.scene` are
`nil`: it isn't in a scene.

| Hook | When it runs |
|---|---|
| `ready` | Once, when the game starts, after the first scene is built |
| `update` | Every frame, **before** the scene's nodes |
| `sceneChanged(self, scene)` | The game switched to another scene (`scene.name` tells which) |
| `draw(self, renderer)` | Every frame after the scene, in screen space (not moved by the camera): a HUD. Leave it out if the global draws nothing; set `self.hidden = true` to skip it for a while |
| `loaded(self)` | `e.Load_Game()` just put a save's values back (see [Saving games](#saving-games)) |
| `destroy` | When the game ends |

### Project Settings > Globals

**File > Project Settings...**, tab **Globals**, lists the globals in the order they start:

- **Add a script as a global:** a dropdown of the built scripts. Any script can be a global.
- The arrows reorder them (a global that uses another in its `ready` goes after it), the trash
  button removes one (its file stays).
- Click a global to set its exported fields on the right, like the inspector does for nodes.
- **Apply** makes it one undoable step.

**Every Play starts the globals from these values**, so testing always starts fresh (unless the
game loads a save).

### Using a global from any script

`e.Global(T)` returns the game's global of that type, or `nil` when the project has none:

```odin
Coin :: struct {
	using script: e.Script,
	value: int `export:"default=10 min=1"`,
}

@(init)
register_Coin :: proc "contextless" () {
	e.Script_Register(Coin, {})
}

Coin_Collected :: proc(self: ^Coin) {
	if state := e.Global(GameState); state != nil {
		state.score += self.value
	}
	e.Game_PlaySound(self.game, SOUND_COIN)
	e.Scene_RemoveNode(self.scene, self.node.id)
}
```

### A global's events

Globals can publish [events](scripts.md#events-and-listeners) too. Select any node with a
script; the inspector's **Events** section has a **Globals** part listing each global, with
**+ Event** to add an event to it. A global fires its events with `nil` as the source (it has no
node):

```odin
Score :: struct {
	using script: e.Script,
	// The score changed. Fire it: e.Event_Notify(&self.onScoreChanged, nil, 42)
	onScoreChanged: e.EventSubject `event:"The score changed" data:"value := data.(int)"`,
	score: int,
}

Score_Add :: proc(self: ^Score, points: int) {
	self.score += points
	e.Event_Notify(&self.onScoreChanged, nil, self.score)
}
```

After a build, **Listen...** beside the event makes the selected node's script listen (a HUD
label updating its text, say). The listener only hears the event while its scene is the one
playing.

## Data resources

A **data resource** is a file holding values of a **data type** you define in code. Use them for
data you want to tune without touching code: a goblin and a bat are two resources of one
`EnemyStats` type, each with its own health, speed and sprite.

### 1. Define a data type

New Script with **Kind** set to **Data type (for data resources)**, or write it yourself:

```odin
EnemyStats :: struct {
	health: int `export:"default=10 min=1"`,
	speed: f32 `export:"default=100 min=0"`,
	sprite: e.TextureAsset `export:""`,
}

@(init)
register_EnemyStats :: proc "contextless" () {
	e.Data_Register(EnemyStats)
}
```

- A data type is a plain struct: **no** `using script: e.Script` line, no hooks.
- Its exported fields are the resource's values; they take the same types as script fields
  (numbers, text, colors, enums, asset handles...).
- `e.Data_Register` (not `Script_Register`) makes it a data type.
- Build the scripts (Ctrl+B). The Output tab lists it: `1 data type: EnemyStats`.

### 2. Make resources

1. In the browser, right-click the **Data** folder > **New Data Resource...**.
2. Give it a **Name** (`Goblin`; letters, digits, spaces, `-` and `_`) and choose its **Type**.
3. **Create** writes `data/goblin.data.json` with every field at its default and selects it.

Selected in the browser, a resource shows in the **inspector**: its fields, edited like a
script's, and the line of code that loads it (`In code: e.Data(EnemyStats, DATA_GOBLIN)`).
Each resource gets a `DATA_` constant in `scripts/assets.odin` (`Fast Ship` becomes
`DATA_FAST_SHIP`).

### 3. Use them

`e.Data(T, asset)` loads a resource (the first time) and returns it:

```odin
Enemy :: struct {
	using script: e.Script,
	// Which enemy this is: a dropdown of the EnemyStats resources
	kind: e.DataAsset `export:"kind=EnemyStats"`,
	health: int,
	stats: ^EnemyStats,
}

@(init)
register_Enemy :: proc "contextless" () {
	e.Script_Register(Enemy, {
		ready = proc(self: ^Enemy) {
			self.stats = e.Data(EnemyStats, self.kind)
			if self.stats == nil do self.stats = e.Data(EnemyStats, DATA_GOBLIN)
			if self.stats != nil do self.health = self.stats.health
		},
		update = proc(self: ^Enemy, events: []sdl.Event, dt: f64) {
			if self.stats == nil do return
			self.node.position.x -= self.stats.speed * f32(dt)
		},
	})
}
```

- A field of type `e.DataAsset` with `kind=EnemyStats` shows in the inspector as a dropdown of
  the `EnemyStats` resources, so each enemy node picks its stats.
- **Everyone shares one copy** of a resource: treat it as read only. Here the enemy copies the
  health into its own field before losing any.
- `e.Data` returns `nil` for an empty asset or a resource of another type (with a message in the
  Console).

Undo (Ctrl+Z) takes back changes to a resource's values. Making and removing resources creates
and deletes files, so like imports they can't be undone.

## Saving games

Saves keep **the globals' state**. Nothing else is saved: nodes and scenes start the way the
editor made them, and your scripts set them up from the globals.

```odin
SaveAndLoad :: proc() {
	e.Save_Game()          // into the "save" slot
	e.Load_Game()          // false if there's no save yet
	e.Save_Game("slot2")
}
```

### What's saved

Each global's fields, by name, as JSON:

| Field | Saved? |
|---|---|
| Not exported (`score: int`): the game's state | **Yes** |
| Not exported, tagged `save:"-"`: caches, timers, pointers to nodes | No |
| Exported (`export:"..."`): settings from the editor | No, so changing one in the editor reaches players who already have a save |
| Exported and tagged `save:""`: a setting the player changes too (a chosen ship, a volume) | **Yes**: the save's value wins |
| Events (`e.EventSubject`) | No |

Numbers, booleans, strings, enums (by name), arrays, slices, dynamic arrays, maps, nested
structs and asset handles all save. A field that can't be written as JSON is skipped, with a
warning.

```odin
Progress :: struct {
	using script: e.Script,
	// A setting from the editor: not saved
	startingLives: int `export:"default=3 min=1"`,
	// A setting the player changes too: saved
	musicVolume: f32 `export:"default=0.8 min=0 max=1" save:""`,
	// The game's state: saved
	level: int,
	highScore: int,
	unlocked: [dynamic]string,
	// Not saved
	timer: f32 `save:"-"`,
}

@(init)
register_Progress :: proc "contextless" () {
	e.Script_Register(Progress, {
		ready = proc(self: ^Progress) {
			if e.Load_Game() do log.infof("Welcome back: level %d", self.level)
		},
		loaded = proc(self: ^Progress) {
			log.infof("Best score so far: %d", self.highScore)
		},
	})
}

Progress_LevelDone :: proc(self: ^Progress, score: int) {
	self.level += 1
	self.highScore = max(self.highScore, score)
	if !e.Save_Game() do log.warn("Couldn't save")
}
```

**Loading** sets the fields the save has and leaves the others: a field you add to a global
after players have saves keeps its starting value for them. Then each global's `loaded` hook
runs. Load from a global's `ready` (as above) to continue where the player left off.

### Slots

The slot is the save's name. Use several for several save files:

| Code | What it does |
|---|---|
| `e.Save_Game("slot2")` | Saves (true when written) |
| `e.Load_Game("slot2")` | Loads (false when there's no such save, or it can't be read) |
| `e.Save_Exists("slot2")` | Whether that save exists ("Continue" buttons) |
| `e.Save_Delete("slot2")` | Deletes it ("New game") |

```odin
Slots :: proc() {
	e.Save_Game("slot2")
	if e.Save_Exists("slot2") do e.Load_Game("slot2")
	e.Save_Delete("slot2")
}
```

Use letters, digits, `-` and `_` in slot names: each slot is a file.

### Where saves go

- **Desktop:** the player's data folder (SDL's "pref path"): `<user data>/<game name>/saves/<slot>.json`.
- **Web:** the browser's local storage.
- **Games started from the editor** (Play) save under `<game name> (dev)`, so testing never
  touches the saves of an exported copy you're playing.
- With Steam cloud saves on (Project Settings > Steam), saves go through Steam's cloud files
  ([Touch controls and Steam](touch_and_steam.md)).

[Hot reload](scripts_node_types_hot_reload.md) uses the same rules: the globals' saved fields
survive a script change.

## How it's stored

Globals are in `project.xml`, with the field values you set:

```xml
<global script="GameState">
	<prop name="lives" value="3"/>
</global>
```

A data resource is its own file, listed in `project.xml` as an asset of kind Data:

```json
{"formatVersion": 1, "type": "EnemyStats", "values": {"health": "30", "speed": "80"}}
```

A save:

```json
{
	"formatVersion": 1,
	"globals": {
		"GameState": {"score": 120, "lives": 2, "highScore": 900}
	}
}
```

## Questions

**My script isn't in the "Add a script as a global" list.** Build the scripts (Ctrl+B) first. A
script already in the list isn't offered twice.

**`e.Global(GameState)` returns nil.** The script isn't in Project Settings > Globals (or the
project's build failed). New Script with Kind Global adds it for you; scripts made as node
scripts must be added by hand.

**My changes to a global's fields in Project Settings don't show in the game.** The game loaded
a save, and that field is saved. Exported fields aren't saved unless tagged `save:""`; delete the
save (`e.Save_Delete()`) to start fresh.

**New Data Resource says there are no data types.** Register one with `e.Data_Register` and build
(Ctrl+B).

**I changed a data resource from code and every enemy changed.** They share one copy. Copy the
values into the script's own fields first.

**Is the score saved automatically?** No: call `e.Save_Game()` when it makes sense (a level
finished, a checkpoint, the options closed).
