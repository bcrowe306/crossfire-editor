---
title: Input
description: Name your game's controls as input actions bound to keys, mouse buttons and gamepads, read them in scripts, and let players rebind them.
order: 9
---

# Input

Your game asks "is the player jumping?", not "is the space bar down?". That question is an
**input action**: a name (`jump`) that any of several keys, mouse buttons, gamepad buttons or
stick directions trigger. One script then works on a keyboard and on a gamepad, and players can
change the controls without you touching the code.

- [Input actions](#input-actions)
- [Project Settings > Input](#project-settings--input)
- [The default ui_ actions](#the-default-ui_-actions)
- [Reading actions in scripts](#reading-actions-in-scripts)
- [Raw keys, mouse and gamepads](#raw-keys-mouse-and-gamepads)
- [Rebinding while the game runs](#rebinding-while-the-game-runs)
- [Rumble](#rumble)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Input actions

An action has:

| Part | What it is |
|---|---|
| **Name** | What scripts ask for: `jump`, `shoot`, `move_left` |
| **Bindings** | What triggers it. Any one of them does: Space, *or* the left mouse button, *or* a gamepad's South button (A on Xbox, Cross on PlayStation) |
| **Deadzone** | How far a stick or trigger must move before it counts (0.5 by default: half way). Keys and buttons ignore it |

## Project Settings > Input

**File > Project Settings...**, tab **Input**.

On the left, the project's actions, with how many bindings each has:

- Click one to show it on the right.
- The arrows reorder them, the trash button removes one.
- **New action:** type a name (`jump`) and press **Add**. Names can't have spaces at the ends or
  repeat another action's.
- **Add the default ui_ actions** puts back any of the six `ui_` actions you removed.
- Under them, the **Local players** settings ([Local multiplayer](local_multiplayer.md)).

On the right, the shown action:

| Setting | What it does |
|---|---|
| **Name** | Rename it (the new name applies once it's valid) |
| **Deadzone** | How far a stick or trigger must move to count, 0 to 0.99 |
| **Triggered by** | Its bindings; the trash button removes one |
| **Press a key or button** | Press it, then press the key, modifier key (Shift, Ctrl...), mouse button or wheel direction to bind. Escape cancels |
| **Key** | Add a key from a list (every key the engine knows) |
| **Mouse** | Add a mouse button: Left, Middle, Right, Back, Forward, or a wheel direction (WheelUp, WheelDown, WheelLeft, WheelRight) |
| **Gamepad** | Add a gamepad button: South, East, West, North, the shoulders, the d-pad, Start, Back... |
| **Stick, trigger** | Add a stick direction or a trigger: `LeftX −` is the left stick pushed left, `LeftY +` pushed down, `RightTrigger +` the right trigger |
| **For** | Which gamepad new gamepad bindings are for: **Any gamepad** (most games), or Gamepad 1 to 4 (for local multiplayer) |

Gamepad bindings come from the dropdowns: the editor can't see your gamepad while you're in a
dialog. Buttons are named by **position** (South is the bottom face button on every brand).

**Apply** makes all your changes one undoable step. Each action also gets a constant in
`scripts/assets.odin` (`ACTION_JUMP :: "jump"`), so a typo in a name is a compile error.

## The default ui_ actions

New projects start with six actions, named like Godot's:

| Action | Bound to |
|---|---|
| `ui_left` | Left arrow, A, d-pad left, left stick left |
| `ui_right` | Right arrow, D, d-pad right, left stick right |
| `ui_up` | Up arrow, W, d-pad up, left stick up |
| `ui_down` | Down arrow, S, d-pad down, left stick down |
| `ui_accept` | Enter, Space, South button |
| `ui_cancel` | Escape, East button |

The engine uses them itself: menus, UI controls and dialogue boxes move their focus, press and
go back with them, on the keyboard and gamepads alike. Your scripts can use them too. The demo's
hero has its own actions (left, right, jump, attack...), so players can rebind them in its Options
without changing the menus' keys. Change their bindings freely; keep the names.

## Reading actions in scripts

| Code | Answers |
|---|---|
| `e.Input_IsActionPressed("jump")` | Is it held down now? (true every frame while held) |
| `e.Input_IsActionJustPressed("jump")` | Did it go down **this frame**? (once per press: jumps, shots, menu choices) |
| `e.Input_IsActionJustReleased("jump")` | Was it let go this frame? |
| `e.Input_GetActionStrength("accelerate")` | How hard, 0 to 1: 1 for keys and buttons, how far a stick or trigger is pushed (past the deadzone) |
| `e.Input_GetAxis("turn_left", "turn_right")` | One axis from two actions, -1 to 1 |
| `e.Input_GetVector("ui_left", "ui_right", "ui_up", "ui_down")` | A direction from four actions (x right, y down), at most 1 long |

Moving in eight directions:

```odin
Ship :: struct {
	using script: e.Script,
	speed: f32 `export:"default=200 min=0"`,
}

@(init)
register_Ship :: proc "contextless" () {
	e.Script_Register(Ship, {
		update = proc(self: ^Ship, events: []sdl.Event, dt: f64) {
			// Arrows, WASD, the d-pad or the left stick: at most 1 long, so diagonals aren't faster
			direction := e.Input_GetVector("ui_left", "ui_right", "ui_up", "ui_down")
			self.node.position += direction * self.speed * f32(dt)
		},
	})
}
```

Presses, holds and releases:

```odin
Jumper :: struct {
	using script: e.Script,
	charging: f64,
}

@(init)
register_Jumper :: proc "contextless" () {
	e.Script_Register(Jumper, {
		update = proc(self: ^Jumper, events: []sdl.Event, dt: f64) {
			// The frame it's pressed: once per press
			if e.Input_IsActionJustPressed(ACTION_JUMP) do log.info("jump!")
			// Held down: every frame
			if e.Input_IsActionPressed("charge") do self.charging += dt
			// The frame it's let go
			if e.Input_IsActionJustReleased("charge") {
				log.infof("charged for %.1f s", self.charging)
				self.charging = 0
			}
		},
	})
}
```

Analog control, where a light push does a little:

```odin
Car :: struct {
	using script: e.Script,
	turnSpeed: f32 `export:"default=180"`,
	topSpeed: f32 `export:"default=300"`,
}

@(init)
register_Car :: proc "contextless" () {
	e.Script_Register(Car, {
		update = proc(self: ^Car, events: []sdl.Event, dt: f64) {
			// -1 (turn_left fully) to 1 (turn_right fully)
			steer := e.Input_GetAxis("turn_left", "turn_right")
			self.node.rotation += steer * self.turnSpeed * f32(dt)
			// 0 to 1: a trigger pushed halfway is 0.5, a key is 1
			throttle := e.Input_GetActionStrength("accelerate")
			_ = throttle * self.topSpeed
		},
	})
}
```

- A key's auto-repeat doesn't count as new presses.
- An action name the game doesn't have counts as not pressed, and the Console warns once.
- Input is read once at the start of each frame, so every script sees the same state.
- When the game window loses focus, every key and button counts as released.

Actions can also be added from code, for a game that makes its own:

```odin
AddActions :: proc() {
	if !e.Input_HasAction("dash") {
		e.Input_AddAction("dash", e.KeyBinding{.LeftShift}, e.GamepadButtonBinding{.East, -1})
	}
}
```

## Raw keys, mouse and gamepads

Sometimes you want a particular key (a debug key, typing) or the mouse's position. The engine
has its own names for them, so you don't need SDL:

```odin
Raw :: proc(self: ^e.Script) {
	// Keys, by position on a US keyboard
	if e.Input_IsKeyPressed(.LeftShift) do log.info("running")
	if e.Input_IsKeyJustPressed(.F3) do log.info("debug view")
	// The mouse, in game coordinates (not moved by the camera)
	if e.Input_IsMouseButtonJustPressed(.Left) {
		screen := e.Input_GetMousePosition()
		world := e.Scene_ScreenToWorld(self.scene, screen)
		log.infof("clicked at %v (world %v)", screen, world)
	}
	zoom := e.Input_GetMouseWheel().y
	_ = zoom
	// Gamepads: device 0 is the first connected, -1 any
	if e.Input_GamepadCount() > 0 {
		if e.Input_IsGamepadButtonJustPressed(.Start, -1) do log.info("pause")
		aim := [2]f32{e.Input_GetGamepadAxis(.RightX), e.Input_GetGamepadAxis(.RightY)}
		_ = aim
	}
}
```

| Code | What it gives |
|---|---|
| `e.Input_IsKeyPressed(.Space)`, `IsKeyJustPressed`, `IsKeyJustReleased` | A key (`.A` to `.Z`, `.Num0` to `.Num9`, `.F1`..., `.Left`, `.Escape`, `.LeftShift`...) |
| `e.Input_IsMouseButtonPressed(.Left)`, `JustPressed`, `JustReleased` | A mouse button |
| `e.Input_GetMousePosition()` | Where the mouse is, in game coordinates; `e.Scene_ScreenToWorld(scene, p)` gives the point in the scene under it |
| `e.Input_GetMouseMotion()`, `e.Input_GetMouseWheel()` | How far the mouse moved and the wheel turned this frame |
| `e.Input_GamepadCount()` | How many gamepads are connected |
| `e.Input_IsGamepadButtonPressed(.South, device)`, `JustPressed`, `JustReleased` | A gamepad button; `device` -1 (the default) is any gamepad |
| `e.Input_GetGamepadAxis(.LeftX, device)` | A stick (-1 to 1, right and down positive) or trigger (0 to 1), raw with no deadzone; `device` 0 (the default) is the first gamepad, -1 the one pushed furthest |

Gamepads are numbered from 0 in the order they were connected. Prefer actions where you can:
raw keys can't be rebound by players.

The SDL events of the frame are still passed to `update` (`events: []sdl.Event`) for code that
wants them.

## Rebinding while the game runs

Players expect to change the controls in an options menu. The engine does the hard part:

1. `e.Input_StartCapture()` starts waiting for the next input.
2. Each frame, `e.Input_GetCapturedBinding()` returns it once it comes: a key, a mouse button, a
   gamepad button, or a stick or trigger pushed past halfway. While waiting (and on that frame)
   actions don't press, so the button being bound doesn't also act.
3. `e.Input_SetBindings("jump", {binding})` gives the action its new bindings.
4. `e.Input_SaveBindings()` keeps them with the game's saves.

```odin
// An options menu's "Change jump" button
RebindJump :: struct {
	using script: e.Script,
	waiting: bool,
}

RebindJump_Start :: proc(self: ^RebindJump) {
	e.Input_StartCapture()
	self.waiting = true
}

@(init)
register_RebindJump :: proc "contextless" () {
	e.Script_Register(RebindJump, {
		update = proc(self: ^RebindJump, events: []sdl.Event, dt: f64) {
			if !self.waiting do return
			binding, ok := e.Input_GetCapturedBinding()
			if !ok do return
			self.waiting = false
			// Escape cancels
			if binding == e.InputBinding(e.KeyBinding{.Escape}) do return
			// Already used by another action?
			for other in e.Input_ActionsUsing(binding) do log.infof("also on %s", other)
			e.Input_SetBindings("jump", {binding})
			e.Input_SaveBindings()
			log.infof("Jump: %s", e.InputBinding_Describe(binding))
		},
	})
}
```

**Saved bindings aren't loaded by themselves.** Load them once when the game starts, in a
[global script](globals_data_saves.md)'s `ready`:

```odin
Settings :: struct {
	using script: e.Script,
}

@(init)
register_Settings :: proc "contextless" () {
	e.Script_Register(Settings, {
		ready = proc(self: ^Settings) {
			// The player's own bindings, if they changed any
			e.Input_LoadBindings()
		},
	})
}
```

Actions the save doesn't mention keep the project's bindings, so actions you add in a later
version still work for players with saved controls.

| Code | What it does |
|---|---|
| `e.Input_StartCapture()`, `e.Input_CancelCapture()`, `e.Input_IsCapturing()` | Start, stop or check a capture. `Input_StartCapture(anyDevice = false)` binds a gamepad press to that gamepad only |
| `e.Input_GetCapturedBinding()` | The captured input, once |
| `e.Input_GetBindings(name)`, `e.Input_SetBindings(name, bindings)` | Read or replace an action's bindings |
| `e.Input_ActionsUsing(binding)` | The actions a binding is already on (to warn, or take it off them) |
| `e.Input_ResetBindings()` | Every action back to the project's bindings (then `Input_SaveBindings` to keep that) |
| `e.Input_SaveBindings()`, `e.Input_LoadBindings()` | Keep and bring back the bindings (a "bindings" slot beside the saves) |
| `e.InputBinding_Describe(binding)` | A binding as text for the menu: `Space`, `Mouse Left`, `Gamepad South`, `Gamepad LeftX −` |

Showing an action's current bindings, and a "Reset controls" button:

```odin
ShowBindings :: proc() {
	for binding in e.Input_GetBindings("jump") do log.info(e.InputBinding_Describe(binding))
}

ResetControls :: proc() {
	e.Input_ResetBindings()
	e.Input_SaveBindings()
}
```

## Rumble

`e.Input_Rumble(low, high, seconds)` shakes the gamepads that can: `low` and `high` are the
strengths of the two motors (0 to 1; the low one is a deep rumble, the high one a buzz). A new
rumble replaces one still going. Pass a device number to rumble one gamepad (with
[local multiplayer](local_multiplayer.md), each player's own).

```odin
Hit :: proc() {
	// Low motor, high motor (0 to 1), seconds; every gamepad, or device 0, 1...
	e.Input_Rumble(0.4, 0.8, 0.25)
}
```

## More on input

- [Local multiplayer](local_multiplayer.md): several players, each reading the same actions from
  their own gamepad or the keyboard.
- [Touch controls and Steam](touch_and_steam.md): on-screen joysticks and buttons that press
  actions, and fingers in scripts.

## How it's stored

Actions are in `project.xml`:

```xml
<action name="jump" deadzone="0.5">
	<key key="Space"/>
	<mouse button="Left"/>
	<gamepad button="South"/>
	<axis axis="LeftY" direction="-1"/>
</action>
```

Saved bindings are a small text file in the save folder, one line per action:

```
jump = key key=Space | gamepad button=South
move_left = key key=A | axis axis=LeftX direction=-1
```

## Questions

**My action never fires.** Check its name in Project Settings > Input against the script
(the Console warns about a name the game doesn't have). Use the `ACTION_` constants to rule out
typos.

**My character jumps many times per press.** Use `Input_IsActionJustPressed` (once per press),
not `Input_IsActionPressed` (every frame while held).

**The stick drifts, or needs pushing too far.** Change the action's Deadzone: higher ignores more
drift, lower reacts to smaller pushes.

**The gamepad does nothing.** Check its bindings are for **Any gamepad** (or the right one), and
that `e.Input_GamepadCount()` sees it. Gamepads are found when they're connected, while the
game runs too.

**Pressing a key in Project Settings doesn't add a gamepad button.** Gamepad buttons and sticks
are added from the Gamepad and Stick, trigger dropdowns.

**Escape quits my game.** A game quits on Escape unless one of its actions uses the key. The
default `ui_cancel` binds it, so most games keep Escape for themselves; a project that removed
it from every action quits on it. Bind it to an action (a pause key) to handle it yourself.

**The player's controls reset every time.** Call `e.Input_LoadBindings()` when the game starts.
