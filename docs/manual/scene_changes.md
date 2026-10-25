---
title: Scene changes
description: Transitions between scenes, scenes opened over others like pause menus, and loading screens.
order: 31
---

# Scene changes: transitions, pause menus, loading screens

A game moves between scenes: from the title to the first level, from level to level, to a game
over screen. This page covers how those changes look (**transitions**), opening a scene **over**
another (a pause menu, an inventory, a dialog), and showing a **loading screen** while the next
scene gets ready.

- [Going to another scene](#going-to-another-scene)
- [Transitions: fades and wipes](#transitions-fades-and-wipes)
- [Scenes over scenes: pause menus](#scenes-over-scenes-pause-menus)
- [Loading screens](#loading-screens)
- [Scene changes in scripts](#scene-changes-in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Going to another scene

Three ways:

- A **Button**'s **Action**: **Go to (scene)**.
- A **Menu** item's action `scene:Level1` (Menus made in scene files).
- A script: `e.Game_ChangeScene(self.game, "Level1")`.

Every scene starts fresh each time it's entered: its nodes are made again from its file, as they
were when the game started.

## Transitions: fades and wipes

Project Settings (File > Project Settings) > **General** > **Scene change**:

| Kind | The screen |
|---|---|
| **None** | Changes at once |
| **Fade** | Fades to a color, then fades the new scene in |
| **Wipe_Left**, **Wipe_Right**, **Wipe_Up**, **Wipe_Down** | A color sweeps across from that side, then away |
| **Circle** | A circle closes on the middle, then opens on the new scene |

**Change time** is the whole change in seconds (covering takes half, uncovering the other half);
**Change color** the cover's color. Every scene change by an action uses it; scripts can use
another (below).

## Scenes over scenes: pause menus

A pause menu is its own scene (with a Panel and Buttons: see [the UI system](ui.md)) opened
**over** the level: the level stays where it is, frozen, drawn under the menu.

1. Make a scene **PauseMenu** with a half-transparent Panel and buttons **Resume** and **Quit to
   Title**.
2. On **Resume**, set **Action** to **Close this (back to the scene under it)**.
3. On **Quit to Title**, **Go to Title**.
4. Open it from the level: a Button whose action is **Open PauseMenu over this**, or a script
   when Escape is pressed:

```odin
Level_update :: proc(self: ^Level, events: []sdl.Event, dt: f64) {
	if e.Input_IsActionJustPressed("pause", self.game) do e.Game_PushScene(self.game, "PauseMenu")
}
```

While a scene is open over another, the one under it **doesn't update** (its scripts, physics
and animations wait) but is still drawn. For a HUD that runs alongside the level, open it with
`e.Game_PushScene(game, "Hud", pauseBelow = false)`: both update.

A scene opened over another starts fresh each time, like a scene you go to: its scripts get
`ready` again (a pause menu can focus its first button there), and the key or button press that
opened it doesn't also press anything in it.

Going to another scene closes everything open over the old one.

## Loading screens

Normally a game builds all its scenes when it starts. A big game can start faster, and show
something while each level gets ready:

1. Make a scene **Loading**: a background, a "Loading..." text, and a **ProgressBar** with **Shows
   loading** ticked (it fills as the loading goes).
2. Project Settings > General > **Loading scene**: **Loading**.

Now the game builds only its start scene and the loading scene when it starts. Going to any other
scene shows the loading scene (with the transition) while that scene's images and sounds load, a
few each frame, for at least half a second; then the scene is built and shown.

## Scene changes in scripts

| Code | What it does |
|---|---|
| `e.Game_ChangeScene(game, "Level2")` | Goes there with the project's transition |
| `e.Game_ChangeScene(game, "Level2", e.Transition{kind = .Fade, duration = 1, color = {255, 255, 255, 255}})` | With another transition (`{kind = .None}`: at once) |
| `e.Game_PushScene(game, "PauseMenu")` | Opens a scene over the playing one (`pauseBelow = false`: both update) |
| `e.Game_PopScene(game)` | Closes the scene on top |
| `e.Game_TopScene(game)` | The scene on top |
| `e.Game_IsChangingScene(game)` | A transition is under way (ignore input meanwhile, say) |
| `e.Game_LoadingProgress(game)` | How far the loading screen has got, 0 to 1 |
| `e.Game_RunAction(game, "push:Shop")` | Runs an action like a Button's (`scene:`, `push:`, `pop`, `quit`) |

A scene's **onEnter** and **onExit** events (and globals' `sceneChanged`) still come as the scene
changes, under the cover.

## How it's stored

On project.xml's root:

```xml
<project name="My Game" startScene="Title" transition="Fade" transitionTime="0.6" transitionColor="#000000ff" loadingScene="Loading">
```

Button actions: `action="scene:Level1"`, `action="push:PauseMenu"`, `action="pop"`,
`action="quit"`; a ProgressBar's `showLoading="true"`.

## Questions

**My pause menu's buttons don't react.** Its scene needs the buttons, and the level must not
take the same keys: the level waits while the menu is open (unless it was opened with
`pauseBelow = false`).

**The loading screen flashes by.** It shows at least half a second; with a transition, plus the
transition. Most scenes load quickly: that's fine.

**A script looks for a node in another scene and finds nothing.** With a loading scene, scenes
that haven't been entered aren't built yet. Look nodes up in the scene that's playing.
