# Legacy of the Wardens

The editor's demo game: a 2D platformer in three levels, made to show as much of the Crossfire
Engine and Editor working together as one game can. Lyra, the last Warden's daughter, crosses a
forest whose creatures the Withering has turned evil, to its heart, where the great boar Grimtusk
waits. Open it with `task run` (it's the project the editor opens by default; releases ship it
beside the editor) and press **F5**. `task play:demo` plays it without the editor.

## How to play

| | Keyboard | Gamepad |
|---|---|---|
| Run | A / D, or the arrows | D-pad, left stick |
| Jump (hold it to jump higher) | Space or K | South (A / Cross) |
| Attack (two slashes) | J, or the left mouse button | West (X / Square) |
| Drop through a wooden plank | hold S or Down, then jump | hold down, then South |
| Read a rune stone's words | W or Up | North (Y / Triangle) |
| Pause | Escape or P | Start |
| Menus | the arrows, Enter, Escape, or the mouse | D-pad, South, East |

Every one of these can be changed in **Options** (title screen or pause menu), as can the music's
and the sounds' volumes and fullscreen; it's all saved.

- **The Whispering Woods** teaches the moves: snails, a boar that charges when it sees you, bees
  that dive, a poisoned pond, moving platforms over a gorge, pots full of coins, three hidden gems.
- **The Shadowed Hollow** is dark: a hill over a cave lit by your lantern and candles, where bees
  hunt you through the tunnels, then a climb up a chasm.
- **The Heart of the Forest**: a short road under a red night, and Grimtusk. Make it charge into a
  wall: stunned, it takes double damage. Below two thirds of its health it leaps and slams (jump
  the shockwaves) and calls bees; below a third it rages.

Touching a creature costs a heart (land on one from above to stomp it); so do water and pits.
Glowing **rune stones** save your progress: Continue on the title screen, or Try again after a
defeat, starts from the last one you touched.

## What it demonstrates, and where

**Scenes and their flow**

| Feature | Where to look |
|---|---|
| **Scene changes with a transition** | Project Settings > General: a fade between scenes (`transition` in project.xml); Buttons' `scene:` actions use it, so does `e.Game_ChangeScene` (`scripts/game_state.odin`) |
| **A loading screen** | `LoadingScene`, the project's loading scene: levels are built when entered while it shows a tip (`Loading` in `scripts/menus.odin`) and a ProgressBar whose **Shows loading** follows the loading by itself |
| **Scenes over scenes** | Options and Credits open over the title (`push:OptionsScene` actions: no code), the pause menu over a level (`e.Game_PushScene` in `scripts/level.odin`); Back closes them (`pop`) |
| **Global scripts, saves, data that outlives scenes** | `scripts/game_state.odin`: `GameState` (Project Settings > Globals) keeps the run, the save and the options; `e.Save_Game` / `e.Load_Game`, `save:"-"` fields that aren't saved |

**UI: the title, options, HUD, pause, results**

| Feature | Where to look |
|---|---|
| **UI controls and themes** | Every menu is Panels, Buttons, RichText, Sliders, a CheckBox and a ScrollBox, themed by `themes/legacy.theme.xml` (the project's UI theme: Project Settings > General) with a pixel font; the title's lettering is `themes/title.theme.xml`. The panels are a 9-patch picture from the HUD sheet (`patchMargins`) |
| **Keyboard, gamepad and mouse in menus** | The project's `ui_*` actions move the focus and press (Project Settings > Input). A scroll box scrolls to the control the keys move to |
| **Listeners from the inspector** | The title's Continue and New Game, the pause menu's buttons, Options' Back and Reset: their `onPressed` events call script handlers (`Title_onContinue`... registered with `e.Script_Listener`): select one and look at the inspector's **Events** |
| **Menu sounds from events** | `MenuSounds` (`scripts/menus.odin`): a tick on `onFocusChanged`, a click on `onPressed` and `onToggled`, for every control of a menu |
| **Animation in the Timeline** | The title's `Director/Intro` Animator fades the title in and slides the menu up (a control's `position` track moves its offset) |
| **Options: rebinding, volumes, fullscreen** | `scripts/options.odin`: each action's keyboard and gamepad buttons (`e.Input_StartCapture`, `e.Input_GetCapturedBinding`, `e.Input_SetBindings`, `e.Input_SaveBindings`; an action that had the key gets yours), the Music and SFX buses' volumes (`e.Audio_SetBusVolume`), `e.Game_SetFullscreen`. GameState applies them all when the game starts |
| **A HUD of controls** | `components/hud.component.xml` (on a screen layer: the camera doesn't move it) and `scripts/hud.odin`: hearts in a ProgressBar that drains after a hit, coins, gems, score, a toast, the boss's health bar |
| **Dialogue** | `dialogues/story.dialogue.xml` (the editor's Dialogue tab): the opening, the rune stones' words, the boss's speech, the ending; options, a variable (`$doubted`), conditions, commands (`<<shake>>`). The HUD's DialogueBox plays them (`Dialogue_Play` in `scripts/level.odin`), with the player's own keys in the lines (`{$jump}`: dialogue variables set from the input bindings); a blip as each line starts (the box's `onLine`, a listener in `components/hud.component.xml`) |

**The levels**

| Feature | Where to look |
|---|---|
| **LDtk levels** | `assets/levels/legacy.ldtk`: three levels in one LDtk project (Open in LDtk from the browser's Levels folder), each in its own scene's LDtkLevel node (ForestScene, HollowScene, LairScene) |
| **Auto-layer rules, IntGrid collision kinds** | The Ground layer: grass and stone tile themselves by rules; grass and stone are solid, planks one-way (`oneWayValues`: drop through them), water an Area named Water that hurts (`areaValues`) |
| **Entities as components, scripts named like them, fields** | Each LDtk entity type is a component in `components/` running the script of its name; LDtk fields set script fields (a patrol Point, speed, health, a pot's coins, a rune stone's dialogue node, an exit's next scene). The boss's trigger is made as its rectangle (`make="Rectangle"`) and closes the gate its "gate" field points at: an entity reference (an arrow in LDtk; `e.LDtk_EntityRefNode`) |
| **Parallax** | Each level's sky and two forests are ParallaxLayer nodes moving at their own factors behind the level |
| **Camera follow, limits, look-ahead, zones, zoom** | The Camera node's target settings (SmoothDamp, a dead zone, look-ahead, an aim offset; `Hero` points it at her and sets its limits to the level), a CameraZone keeping it in the boss's arena, `e.Camera2D_ZoomTo` for the fight, `e.Camera2D_MoveTo` in the boss's entrance |
| **2D lighting** | HollowScene and LairScene: `lighting` on with an ambient color, shadows from the level's walls (`bodyShadows`), the hero's lantern, candles (`Candle` flickers them), glowing gems and rune stones (a tween brightens a lit stone), the boss's aura; the title screen's warm light |
| **Navigation** | HollowScene's NavRegion over the caves; hunting bees' NavAgents find a way to the hero around the rock (`Bee` in `scripts/creatures.odin`) |
| **Moving platforms with the Timeline** | `components/platform.component.xml`: its Animator moves the `Platform` script's `t` 0 → 1 → 0, eased; the script places it between its LDtk path's ends and carries the hero |
| **A cutscene with event tracks** | LairScene's `Director/BossIntro` Animator: its event track ("gate", "pan", "roar", "talk") calls `Level_onIntroEvent` (a listener in the scene file); the gate's own Animator drops it with an OutBounce key |

**The hero, the creatures, the boss**

| Feature | Where to look |
|---|---|
| **A platformer on a CharacterMover** | `scripts/hero.odin`: acceleration and friction, a jump cut when let go, a hang at the top, coyote time and jump buffering, one-way planks, knockback, pits and water |
| **A state machine and Aseprite animations** | The hero's `Brain` StateMachine (the editor's States tab) picks her animation from parameters the script sets; the animations are the tags of `assets/characters/hero.aseprite` (made by `tools/demo/hero.lua` from the pack's files) with a pivot slice at her feet |
| **Aseprite frame events** | "step" and "slash" in hero.aseprite's cels: footsteps with dust, and the sword's hits, on the frames they happen (`onFrameEvent`) |
| **Animation assets, a sheet per animation** | `animations/boar.anim.xml` and `bee.anim.xml` put one Aseprite file per animation together; `snail.anim.xml` cuts PNG sheets by cell size |
| **A shader: the hit flash** | Sprites use `builtin:hit_flash` (set in their components); scripts drive its `amount` (`e.Node_SetShaderParam`). The project turns shaders on (Project Settings), so the GPU renderer runs it; without one a tint stands in |
| **Hit feel** | `scripts/effects.odin`: particle bursts added from code (`e.Scene_AddComponent`, removed by their `Burst` script on `onFinished`), a hitstop (`e.Game_HitStop`), a camera shake, gamepad rumble (`e.Input_Rumble`), floating score text (a Label moved and faded by tweens) |
| **Creatures** | `scripts/enemy.odin` (health, knockback that never leaves the ground, stomps, the flash) and `scripts/creatures.odin`: snails, boars that snort then charge, bees that dive or hunt |
| **A boss with phases** | `scripts/boss.odin`: charges into walls (stunned: double damage), leaps with shockwaves, calls bees; a roar between phases; its health in the HUD |
| **Collectibles and checkpoints** | `scripts/pickups.odin` (coins, gems, potions, pots that spill coins with tweens) and the rune stones (`scripts/world.odin`): taken pickups are remembered by their LDtk iid, so a Continue doesn't bring them back |
| **Names the compiler checks** | `scripts/assets.odin`, written by the editor: besides the assets, the scripts name scenes (`SCENE_VICTORY_SCENE` in `scripts/game_state.odin`), buses (`BUS_SFX`), animations (`ANIM_BOAR_RUN` in `scripts/creatures.odin` and `scripts/boss.odin`) and the hero's state machine parameters (`PARAM_HERO_BRAIN_SPEED` in `scripts/hero.odin`) through its constants, so a renamed one is a build error |

**Sound**

| Feature | Where to look |
|---|---|
| **Mix buses** | Music and SFX (the Mixer tab): every sound effect (each creature with its own cries: `Enemy.hurtSound` / `defeatSound` in `scripts/enemy.odin`) plays on SFX (`Sfx` in `scripts/game_state.odin`: `e.Game_PlaySound` with a bus, a volume and a pitch); the options set the buses' volumes |
| **Music layers** | Each level's MusicPlayer streams its theme with a drums layer at volume 0 that fades in when creatures come near (`e.MusicPlayer_SetLayerVolume` in `scripts/level.odin`) |
| **Crossfades** | The boss's theme crossfades in after its speech, the victory theme after its defeat (`e.MusicPlayer_CrossfadeTo`) |
| **Bus effects** | A reverb on SFX in the caves (`e.Audio_SetBusEffects`), a low-pass on Music while paused |

## How it's made

- `tools/demo/make_demo.py` (in the editor's repository) makes the pictures from the asset pack and
  the three levels from their layouts (it was run once; the levels are now meant to be edited in
  LDtk). `tools/demo/hero.lua` (run by it, with Aseprite) puts the hero's animations into one
  Aseprite file.
- `tools/demo/pick_sounds.py` copies the sound effects from the GameSounds pack (the file for each
  effect is listed there); `tools/demo/make_sounds.py` synthesizes the music and the bees' buzz.
- `tools/demo/playtest` plays the demo headless (`task demo:playtest`): a bot presses keys through
  the title, the options, each level and the boss, checks every mechanic and saves frames as PNG
  files (`build/playtest/`).

## Where saves go

- Played from the editor (`--dev`): your user data folder's `Legacy of the Wardens (dev)/saves/`
  (on Linux `~/.local/share/Legacy of the Wardens (dev)/`): `save.json` (the run, the options) and
  `bindings.json` (the controls). Testing never touches an exported game's saves.
- Exported for the desktop: `Legacy of the Wardens/saves/` in the same place; for the web, the
  browser's localStorage.

Delete them to start over.

## Credits and licenses

- **Art:** "Legacy Fantasy - High Forest" by Anokolisa (anokolisa.itch.io), used with the
  permission of its owner; the project's owner will update the license to say so. The pictures
  here are cut, combined and tinted from the pack (`tools/demo/make_demo.py`).
- **Sound effects:** from the GameSounds pack by GameBurp, used with the permission of its owner;
  the license will be updated the same way. `tools/demo/pick_sounds.py` lists which file each
  effect is.
- **Music** (and the bees' buzz): made for this demo by `tools/demo/make_sounds.py`, under the
  editor's license (MIT).
- **Fonts:** Pixelify Sans (Copyright 2021 The Pixelify Sans Project Authors) and Jacquarda
  Bastarda 9 (Copyright 2023 The Soft Type Project Authors), both under the SIL Open Font
  License 1.1: `assets/fonts/*-OFL.txt`.
- **Levels:** in LDtk's format (ldtk.io, by Sébastien Bénard).
- **Code and the project's other files:** MIT, like the editor.

The game's Credits screen says the same.
