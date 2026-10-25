---
title: Touch controls and Steam
description: Play with fingers through on-screen joysticks and buttons that press your input actions, read touches in scripts, and unlock Steam achievements, keep stats and save to Steam Cloud.
order: 34
---

# Touch controls and Steam

This page covers two things a game needs before it ships on more devices and stores:

- **Touch input**: on-screen **joysticks** and **buttons** for phones, tablets, the Steam Deck and
  touch-screen laptops. They press the same **input actions** as the keyboard and gamepads, so
  the game's code doesn't change. Scripts can also read every finger on the screen.
- **Steam**: **achievements**, **stats** and **cloud saves**, through one engine API.

- [Input actions first](#input-actions-first)
- [A virtual joystick](#a-virtual-joystick)
- [A touch button](#a-touch-button)
- [Touch control settings](#touch-control-settings)
- [Touches in scripts](#touches-in-scripts)
- [Steam](#steam)
- [Steam in scripts](#steam-in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Input actions first

Touch controls press **input actions**: named inputs like `jump` or `move_left`, set up in
**Project Settings > Input**. An action can have several bindings (Space, a gamepad's A
button), and a touch control is one more way to press it. Code that reads the action
(`e.Input_IsActionPressed("jump")`, `e.Input_GetVector(...)`) then works with all of them.

If the project has no actions yet, open **Project Settings > Input** and press **Add the default
ui_ actions** (left, right, up, down, accept, cancel), or add your own.

## A virtual joystick

1. Select the scene and choose its **Screen layers** in the browser's scene preview, for
   example Layer8. Things on a screen layer stay put on the screen when the camera moves. Without
   one, the joystick would scroll away with the level, and the inspector warns about it.
2. **Add Node > VirtualJoystick** (it's under User interface). Set its **Layer** to the screen
   layer.
3. Place it where a thumb rests, for example the bottom-left corner: its position is the middle
   of the stick.
4. In the inspector, choose its four actions: **Left action**, **Right action**, **Up action**,
   **Down action** (for example `ui_left`, `ui_right`, `ui_up`, `ui_down`). Leave any of them at
   (none).

Pushing the stick presses its actions as far as it's pushed: halfway right gives the right
action a strength of about 0.5. A script moving with

```odin
direction := e.Input_GetVector("ui_left", "ui_right", "ui_up", "ui_down")
```

moves the same with the arrow keys, a gamepad's stick or the on-screen stick.

**Floating** joysticks start where the thumb lands. Give it a **Touch zone** (say 600 x 500 over
the left of the screen) and tick **Floating**: a thumb landing anywhere in the zone puts the
stick under it, and it goes back when the thumb lifts.

## A touch button

1. **Add Node > TouchButton**, on the screen layer, where the other thumb rests.
2. Choose its **Input action** (`jump`, `ui_accept`).
3. Give it a **Label** if you like (`A`, `Jump`).

The action is pressed while a finger holds the button. Scripts can also listen to the button's
**onPressed** and **onReleased** events (the inspector's Events section).

## Touch control settings

| Setting | What it does |
|---|---|
| **Size radius** | The stick's or button's radius, in game pixels (64 for a stick, 40 for a button) |
| **Deadzone** | (Joystick) A stick moved less than this fraction of its radius counts as centered (0.2) |
| **Touch zone width / height** | The area that takes a finger, centered on the node. 0 x 0 means the circle itself |
| **Floating** | (Joystick) It starts where the finger lands in its zone |
| **Shows** | **Touch_Screens** (the default): shown once the screen has been touched, and always in Play from the editor, so desktop players never see it. **Always**. **Never**: an invisible touch zone that still works |
| **Mouse works it** | The mouse drives it too, to try it on a desktop. On by default |
| **Control color**, **Opacity** | Its look |

Each control takes **one finger**: the first that lands in its zone. It keeps that finger until
it lifts, wherever it moves, so a thumb can slide off the stick and still steer. A finger taken by
one control isn't taken by another, so two thumbs work a stick and a button at once.

SDL also turns the first finger into mouse clicks, so **menus and UI buttons work with touches**
already, with nothing to set up.

## Touches in scripts

`e.Input_GetTouches()` lists every finger on the screen this frame, in game coordinates:

| Field | What it is |
|---|---|
| `position` | Where it is now |
| `start` | Where it went down |
| `motion` | How far it moved this frame |
| `pressure` | 0 to 1 (1 on screens that can't tell) |
| `pressed` | It went down this frame |
| `released` | It lifted this frame (it's gone next frame) |
| `claimed` | A joystick or button took it |

```odin
Swipe :: struct {
	using script: e.Script,
}

Swipe_update :: proc(self: ^Swipe, events: []sdl.Event, deltaTime: f64) {
	for touch in e.Input_GetTouches() {
		// A quick flick upward, not on a control: jump
		if touch.released && !touch.claimed && touch.start.y - touch.position.y > 80 {
			e.Debug_Text(self.scene, touch.position, "swipe!", seconds = 0.5)
		}
	}
}
```

Also: `e.Input_GetTouchCount()` (fingers down), `e.Input_IsTouchScreen()` (has the screen been
touched?), `e.VirtualJoystick_GetVector(stick)` (a stick's position, -1 to 1 each way),
`e.TouchButton_IsPressed(button)`. Joysticks and buttons can be made from code with
`e.CreateVirtualJoystick(scene, {"left", "right", "up", "down"})` and
`e.CreateTouchButton(scene, "jump", "A")`.

## Steam

**Project Settings > Steam** holds:

- **Steam app ID**: the game's ID on Steamworks (480 is Valve's test app).
- **Cloud saves**: `e.Save_Game` and `e.Load_Game` read and write Steam Cloud files, so saves
  follow the player between computers.
- **Achievements**: each with its **API name** (as set up on Steamworks: letters, digits and `_`,
  like `FIRST_BLOOD`), a **title**, a **description** and **Hidden**. **Add Achievement** adds one;
  the bin removes one. The tab warns about names Steam won't take or that are used twice.

Press **Apply**: it's one undo step (Ctrl+Z takes all of it back). Every achievement gets a
constant in `scripts/assets.odin`: `ACHIEVEMENT_FIRST_BLOOD :: "FIRST_BLOOD"`.

**The stub.** Until the Steamworks SDK is part of the engine, every game runs Steam's **stub
backend**:
- Achievements and stats are kept with the game's saves, in the same per-user folder.
- Cloud files are save files named `steam-cloud-<name>`.
- Each unlock is logged in the Console: `Steam (stub): achievement FIRST_BLOOD unlocked`.

Games run from the editor keep theirs apart (as "<name> (dev)"), like saves. So you can write and
test everything now, and the code works unchanged when the real Steam backend arrives.

## Steam in scripts

```odin
Enemy :: struct {
	using script: e.Script,
}

Enemy_defeated :: proc(self: ^Enemy) {
	e.Steam_UnlockAchievement("FIRST_BLOOD")
	e.Steam_AddStat("ENEMIES_DEFEATED", 1)
	if e.Steam_GetStat("ENEMIES_DEFEATED") >= 100 do e.Steam_UnlockAchievement("CENTURION")
	// Steam wants stats sent now and then (a level's end, a pause): not every frame
	e.Steam_StoreStats()
}
```

| Procedure | What it does |
|---|---|
| `e.Steam_UnlockAchievement(name)` | Unlocks it (once; unlocking again does nothing) |
| `e.Steam_IsAchievementUnlocked(name)` | Whether it's unlocked |
| `e.Steam_ClearAchievement(name)` | Locks it again (testing) |
| `e.Steam_SetStat(name, value)`, `e.Steam_AddStat(name, delta)`, `e.Steam_GetStat(name)` | Stats: numbers by name (no list needed) |
| `e.Steam_StoreStats()` | Sends stats and achievements to Steam |
| `e.Steam_CloudWrite(file, data)`, `e.Steam_CloudRead(file)`, `e.Steam_CloudDelete(file)`, `e.Steam_CloudExists(file)` | Cloud files: names of letters, digits, `-`, `_` and `.` |
| `e.Steam_IsRunning()`, `e.Steam_BackendName()` | Whether Steam answers, and which backend runs ("stub") |

To show your own "achievement unlocked" pop-up, listen to `game.steam.onAchievementUnlocked`:
it's notified on each new unlock, with the name as its data.

## How it's stored

Touch controls are nodes in the scene file:

```xml
<node name="Stick" kind="VirtualJoystick" x="140" y="580" layer="7" touchActions="ui_left,ui_right,ui_up,ui_down" floating="true" zoneWidth="600" zoneHeight="500"/>
<node name="Jump" kind="TouchButton" x="1160" y="600" layer="7" touchActions="jump" text="A"/>
```

A joystick's `touchActions` are left, right, up and down, comma-separated (empty ones for none).
Steam is in `project.xml`:

```xml
<project ... steamAppId="480" steamCloud="true">
	<achievement name="FIRST_BLOOD" title="First Blood" description="Defeat an enemy"/>
</project>
```

## Questions

**I don't see the joystick when I play on my desktop.** Its **Shows** is Touch_Screens: it
appears once the screen is touched, and always in Play from the editor. Exported games on a
desktop without a touch screen don't show it. Set **Shows** to Always to see it everywhere.

**Touching the joystick also clicks a menu under it.** SDL turns the first finger into mouse
clicks. Keep touch controls away from mouse-driven UI, or put the menu where thumbs don't rest.

**Can I export to Android or iOS?** Not yet: mobile export targets come later. Touch controls work
now on any touch screen the desktop builds run on (the Steam Deck, Windows and Linux tablets and
touch laptops), and should in web exports opened on a phone (not tested there yet).

**Does the stub talk to Steam?** No. It keeps everything locally, so nothing reaches Steam's
servers until the real backend is in.
