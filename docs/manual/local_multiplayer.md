---
title: Local multiplayer
description: Let several people play on one computer, each joining with a gamepad or the keyboard and reading the input actions from their own device, with split-screen views.
order: 35
---

# Local multiplayer

Local multiplayer is several people playing on one computer: couch co-op, versus, party
games. Each **player** joins with a **device** (a gamepad, or the keyboard and mouse), and from
then on reads the project's **input actions** from that device only. Player 1's `jump` is their
pad's A button; player 2's is theirs.

Online multiplayer isn't part of the engine.

- [How it works](#how-it-works)
- [Project settings](#project-settings)
- [A lobby: joining](#a-lobby-joining)
- [Each player's input](#each-players-input)
- [Unplugged gamepads, leaving](#unplugged-gamepads-leaving)
- [Split screen](#split-screen)
- [In scripts: the whole list](#in-scripts-the-whole-list)
- [Questions](#questions)

## How it works

1. You set up **input actions** as for a single-player game (**Project Settings > Input**):
   `jump` on Space and a gamepad's South button, `left` / `right` on A / D and the left stick.
2. While the game is **joining** (a lobby screen), anyone who presses the join button on a device
   no player has becomes the next player: player 0, then 1, 2...
3. Scripts ask about **a player's** action: `e.Player_IsActionPressed(1, "jump")`. Only that
   player's device counts.

The plain `e.Input_IsActionPressed("jump")` still reads every device, which is what menus want.

## Project settings

**Project Settings > Input**, under the list of actions, has **Local players**:

| Setting | What it does |
|---|---|
| **Most players** | How many can join at once (1 to 8; 4 by default) |
| **Keyboard player** | The keyboard and mouse can be one player's device (on by default). Touch controls go with the keyboard player |
| **Join with** | The input that joins. By default a gamepad's **South** (Xbox A, PlayStation Cross) or **Start**, and the keyboard's **Enter** or **Space**. Choose an action instead (for example `ui_accept`) and its buttons and keys join |

Apply them like any other project setting (one undo step).

## A lobby: joining

Joining is off until a script turns it on, so stray presses in other scenes don't add players.
A lobby scene's script:

```odin
Lobby :: struct {
	using script: e.Script,
	label: ^e.Label `export:"default=../Players"`,
}

Lobby_ready :: proc(self: ^Lobby) {
	e.Players_Clear()
	e.Players_StartJoining()
}

Lobby_update :: proc(self: ^Lobby, events: []sdl.Event, deltaTime: f64) {
	// Show who's in
	text := fmt.tprintf("%d players: press A or Enter to join", e.Players_Count())
	for i in 0 ..< e.Players_Count() {
		text = fmt.tprintf("%s\nPlayer %d: %s", text, i + 1, e.Player_DeviceName(i))
	}
	self.label.text = text
	// Anyone presses ui_cancel (a gamepad's East button, or Escape) when everyone's in: play
	if e.Players_Count() > 0 && e.Input_IsActionJustPressed("ui_cancel") {
		e.Players_StopJoining()
		e.Game_ChangeScene(self.scene.game, "Arena")
	}
}
```

To add players from code instead (a one-player game, or "press any key"), use
`e.Players_Join(.Keyboard)` or `e.Players_Join(.Gamepad, 0)` (the first connected gamepad).

**Events** let a lobby react: `game.input.players.onJoined` (data: the new player's number),
`onLeft`, `onDisconnected`, `onReconnected`.

## Each player's input

Give the player character's script a `player` field, exported so each character node picks its
number in the inspector:

```odin
Hero :: struct {
	using script: e.Script,
	player: int `export:"min=0 max=7"`,
	speed: f32 `export:"default=200"`,
}

Hero_update :: proc(self: ^Hero, events: []sdl.Event, deltaTime: f64) {
	move := e.Player_GetVector(self.player, "left", "right", "up", "down")
	self.node.position += move * self.speed * f32(deltaTime)
	if e.Player_IsActionJustPressed(self.player, "jump") {
		e.Player_Rumble(self.player, 0.3, 0.3, 0.1)
	}
}
```

| Procedure | What it does |
|---|---|
| `e.Player_IsActionPressed(player, name)` | The action is held on the player's device |
| `e.Player_IsActionJustPressed`, `e.Player_IsActionJustReleased` | It went down / up this frame |
| `e.Player_GetActionStrength(player, name)` | 0 to 1 (sticks and triggers in between) |
| `e.Player_GetAxis(player, negative, positive)` | -1 to 1 from two actions |
| `e.Player_GetVector(player, left, right, up, down)` | A direction at most 1 long |
| `e.Player_Rumble(player, low, high, seconds)` | Rumbles the player's gamepad |
| `e.Player_DeviceName(player)` | "Keyboard", the gamepad's name, or "(unplugged)" |

Which bindings count for a player:
- **A gamepad player**: the action's gamepad buttons and sticks, on their own pad. A binding made
  "For" one gamepad in Project Settings (Gamepad 2) counts on whichever pad the player has: with
  players, the player decides the pad.
- **The keyboard player**: the action's keys and mouse buttons, and touch controls.

## Unplugged gamepads, leaving

If a player's gamepad is unplugged (or its battery dies), the player **stays**: their actions read
nothing, `Player_DeviceName` says "(unplugged)", and `onDisconnected` is sent, a good moment to
pause the game. The next gamepad plugged in goes back to the first player waiting for one
(`onReconnected`).

`e.Players_Leave(player)` removes a player; the players after them move down a number (player 2
becomes player 1), so keep a script's `player` field in step if players can leave mid-game.
`e.Players_Clear()` removes everyone (a lobby starting over).

## Split screen

Each player gets a **CameraView** node (see the camera tools page): what a Camera following that
player sees, drawn into a rectangle of the screen. `e.SplitScreen_Rect(player, count, size)` gives
each player's rectangle: one fills the screen, two side by side, three with one on top, four in
the corners, more in a grid.

```odin
Arena :: struct {
	using script: e.Script,
}

Arena_ready :: proc(self: ^Arena) {
	count := e.Players_Count()
	for i in 0 ..< count {
		view := cast(^e.CameraView)e.Scene_FindNode(self.scene, fmt.tprintf("View%d", i + 1))
		if view == nil do continue
		r := e.SplitScreen_Rect(i, count, self.scene.game.size, gap = 4)
		view.position = {r.x, r.y}
		view.size = {r.w, r.h}
	}
}
```

Put the views on a screen layer, and give each its own Camera (a child of that player's
character) as its **View camera**.

## In scripts: the whole list

| Procedure | What it does |
|---|---|
| `e.Players_StartJoining()`, `e.Players_StopJoining()`, `e.Players_IsJoining()` | The lobby |
| `e.Players_Join(device, gamepad)` | Adds a player from code (returns its number, -1 if it can't) |
| `e.Players_Leave(player)`, `e.Players_Clear()` | Removes players |
| `e.Players_Count()`, `e.Players_Get(player)` | Who's in (`device`, `connected`) |
| `e.SplitScreen_Rect(player, count, size, gap)` | A player's split-screen rectangle |

## Questions

**Two players on one keyboard?** Not built in: the keyboard is one device. Make separate actions
(`p1_left` on A, `p2_left` on the left arrow) and read them with `e.Input_IsActionPressed`.

**Do players carry over between scenes?** Yes: players belong to the game, not a scene. They're
cleared only when you call `e.Players_Clear` or `e.Players_Leave`.

**Can I test without gamepads?** The keyboard can be a player. With one gamepad and the keyboard,
two players can try it.
