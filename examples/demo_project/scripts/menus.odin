package scripts

import "core:fmt"
import "core:math/rand"
import e "engine:."
import sdl "vendor:sdl3"

/*
The screens around the levels, made of UI controls (Panels, Buttons, RichText) themed by
themes/legacy.theme.xml:

- **TitleScene** (`Title`): a parallax forest drifting by (ParallaxLayers under a camera that
  moves), fireflies (particles), warm light (2D lighting), and the menu: Continue (only with a
  save), New Game, Options and Credits (pushed over the title: `push:` actions), Quit. The
  buttons' presses reach this script through listeners in the scene file (`Title_onContinue`,
  `Title_onNewGame`: the inspector's Events). The menu slides in with an Animator clip.
- **PauseScene** (`Pause`): pushed over a level (it stops under it); the music goes muffled
  through a low-pass on the Music bus (`e.Audio_SetBusEffects`) until it's closed.
- **GameOverScene**, **VictoryScene** (`Results`): what the run did, and where to go next.
- **CreditsScene** (`Credits`): the credits rolling up (the RichText's offset, moved every frame).
- **LoadingScene** (`Loading`): the project's loading scene: a tip, the hero running, and a
  ProgressBar with "Shows loading" set, which follows `e.Game_LoadingProgress` by itself.

`MenuSounds` gives any menu its sounds: a tick when the focus moves, a click when a button is
pressed, through the controls' onFocusChanged / onPressed / onValueChanged / onToggled events.
*/

Title :: struct {
	using script: e.Script,
	continueButton: ^e.Button `export:"default=../Menu/Continue"`,
	newGameButton: ^e.Button `export:"default=../Menu/NewGame"`,
	best: ^e.RichText `export:"default=../Best"`,
	// How fast the forest drifts by, px/s
	drift: f32 `export:"default=18 min=0 max=200"`,
	starting: bool,
}

@(init)
register_Title :: proc "contextless" () {
	e.Script_Register(Title, {
		ready = proc(self: ^Title) {
			state := State()
			can := GameState_CanContinue(state)
			if self.continueButton != nil {
				self.continueButton.visible = can
				self.continueButton.settings.disabled = !can
			}
			// The focus starts on what you'd most likely press
			first := can ? self.continueButton : self.newGameButton
			if first != nil do e.Control_Focus(self.scene, first)
			if self.best != nil && state != nil && state.bestScore > 0 {
				e.Control_SetText(self.best, fmt.tprintf("Best: [color=#ffe08a]%d[/color]", state.bestScore))
			}
		},
		update = proc(self: ^Title, _: []sdl.Event, dt: f64) {
			// The forest drifts by: the camera moves, the ParallaxLayers follow it by their factors
			if camera := self.scene.camera; camera != nil do camera.position.x += self.drift * f32(dt)
		},
	})
}

Title_onContinue :: proc(self: ^Title, source: ^e.Node, data: e.EventData) {
	if self.starting do return
	self.starting = true
	if state := State(); state != nil do GameState_Continue(state)
}

Title_onNewGame :: proc(self: ^Title, source: ^e.Node, data: e.EventData) {
	if self.starting do return
	self.starting = true
	if state := State(); state != nil do GameState_NewGame(state)
}

@(init)
register_Title_listeners :: proc "contextless" () {
	e.Script_Listener(Title, "onContinue", Title_onContinue)
	e.Script_Listener(Title, "onNewGame", Title_onNewGame)
}

Pause :: struct {
	using script: e.Script,
	resume: ^e.Button `export:"default=../Menu/Resume"`,
	// The music's muffle while paused (Hz)
	cutoff: f32 `export:"default=700 min=100 max=8000"`,
	// Updates since it opened: the press that opened it is still "just pressed" in the first
	updates: int,
}

// Closes the pause menu: the level goes on
Pause_Close :: proc(self: ^Pause) {
	e.Audio_SetBusEffects(BUS_MUSIC, {})
	Sfx(self.game, SOUND_UI_BACK)
	e.Game_PopScene(self.game)
}

@(init)
register_Pause :: proc "contextless" () {
	e.Script_Register(Pause, {
		ready = proc(self: ^Pause) {
			muffle := e.AudioEffect_Make(.LowPass)
			muffle.cutoff = self.cutoff
			e.Audio_SetBusEffects(BUS_MUSIC, {muffle})
			if self.resume != nil do e.Control_Focus(self.scene, self.resume)
		},
		update = proc(self: ^Pause, _: []sdl.Event, _: f64) {
			// Only the pause menu itself, not the options over it; not the frame it opened in
			self.updates += 1
			if e.Game_TopScene(self.game) != self.scene || self.updates == 1 do return
			if e.Input_IsActionJustPressed(ACTION_PAUSE) || e.Input_IsActionJustPressed(ACTION_UI_CANCEL) do Pause_Close(self)
		},
	})
}

Pause_onResume :: proc(self: ^Pause, source: ^e.Node, data: e.EventData) {
	Pause_Close(self)
}

// Back to the last rune stone
Pause_onRestart :: proc(self: ^Pause, source: ^e.Node, data: e.EventData) {
	e.Audio_SetBusEffects(BUS_MUSIC, {})
	if state := State(); state != nil do GameState_Retry(state)
}

Pause_onQuit :: proc(self: ^Pause, source: ^e.Node, data: e.EventData) {
	e.Audio_SetBusEffects(BUS_MUSIC, {})
	e.Game_ChangeScene(self.game, SCENE_TITLE_SCENE)
}

@(init)
register_Pause_listeners :: proc "contextless" () {
	e.Script_Listener(Pause, "onResume", Pause_onResume)
	e.Script_Listener(Pause, "onRestart", Pause_onRestart)
	e.Script_Listener(Pause, "onQuit", Pause_onQuit)
}

Results :: struct {
	using script: e.Script,
	stats: ^e.RichText `export:"default=../Panel/Stats"`,
	first: ^e.Button `export:"default=../Panel/Buttons/First"`,
	// The victory screen (the run's totals), else the game over screen
	victory: bool `export:""`,
}

@(init)
register_Results :: proc "contextless" () {
	e.Script_Register(Results, {
		ready = proc(self: ^Results) {
			if self.first != nil do e.Control_Focus(self.scene, self.first)
			state := State()
			if state == nil || self.stats == nil do return
			r := state.run
			if self.victory {
				// A fanfare over the victory theme's fade in
				Sfx(self.game, SOUND_VICTORY, 0.8)
				minutes := int(r.time) / 60
				e.Control_SetText(self.stats, fmt.tprintf(
					"Score  [color=#9a4f12]%d[/color]\nCoins  [color=#9a4f12]%d[/color]\nGems  [color=#2a6a9a]%d / %d[/color]\nTime  %d:%02d\nFalls  %d\n\nBest  [color=#9a4f12]%d[/color]",
					r.score, r.coins, r.gems, state.totalGems, minutes, int(r.time) % 60, r.deaths, state.bestScore))
			} else {
				e.Control_SetText(self.stats, fmt.tprintf("Score  [color=#9a4f12]%d[/color]\nFalls  %d\n\nThe last rune stone\nremembers you.", r.score, r.deaths))
			}
		},
	})
}

Results_onRetry :: proc(self: ^Results, source: ^e.Node, data: e.EventData) {
	if state := State(); state != nil do GameState_Retry(state)
}

@(init)
register_Results_listeners :: proc "contextless" () {
	e.Script_Listener(Results, "onRetry", Results_onRetry)
}

Credits :: struct {
	using script: e.Script,
	roll: ^e.RichText `export:"default=../Roll"`,
	back: ^e.Button `export:"default=../Back"`,
	// How fast they roll, px/s
	speed: f32 `export:"default=40 min=0 max=400"`,
	start: f32,
}

@(init)
register_Credits :: proc "contextless" () {
	e.Script_Register(Credits, {
		ready = proc(self: ^Credits) {
			if self.back != nil do e.Control_Focus(self.scene, self.back)
			if self.roll != nil do self.start = self.roll.offset.y
		},
		update = proc(self: ^Credits, _: []sdl.Event, dt: f64) {
			if self.roll != nil {
				self.roll.offset.y -= self.speed * f32(dt)
				// Round again once it's gone off the top
				if self.roll.offset.y < self.start - self.roll.size.y - 700 do self.roll.offset.y = self.start
			}
			if e.Game_TopScene(self.game) == self.scene && e.Input_IsActionJustPressed(ACTION_UI_CANCEL) {
				Sfx(self.game, SOUND_UI_BACK)
				e.Game_PopScene(self.game)
			}
		},
	})
}

Loading :: struct {
	using script: e.Script,
	tip: ^e.RichText `export:"default=../Tip"`,
}

// What the loading screen tells
TIPS :: [?]string{
	"Hold jump to jump higher; let go early for a short hop.",
	"Rune stones remember you: Continue and Retry start from the last one you touched.",
	"Land on a creature to stomp it. Bees can be stomped too.",
	"A boar paws the ground before it charges. Jump it!",
	"Hold down and press jump to drop through a wooden plank.",
	"Pots hide coins. Break them with your sword.",
	"Every level hides three gems. Look up, and look around.",
	"Controls can be changed in Options: keyboard and gamepad.",
	"Water hurts. So does falling.",
	"A stunned boss takes double damage.",
}

@(init)
register_Loading :: proc "contextless" () {
	e.Script_Register(Loading, {
		ready = proc(self: ^Loading) {
			tips := TIPS
			if self.tip != nil do e.Control_SetText(self.tip, fmt.tprintf("[color=#d8c8a8]%s[/color]", tips[rand.int_max(len(tips))]))
		},
	})
}

MenuSounds :: struct {
	using script: e.Script,
	time: f32,
}

@(private="file")
menuSound :: proc(_: ^e.EventSubject, source: rawptr, data: e.EventData, user: rawptr) {
	self := cast(^MenuSounds)user
	// The first frame's focus isn't the player's doing
	if self.time < 0.1 do return
	node := cast(^e.Node)source
	sound := SOUND_UI_SELECT
	#partial switch d in data {
	case bool:
		if e.Node_Is(node, e.CheckBox) do sound = SOUND_UI_TOGGLE
		else if d do sound = SOUND_UI_MOVE
		else do return
	case f32:
		sound = SOUND_UI_MOVE
	}
	Sfx(node.scene.game, sound, 0.7)
}

@(private="file")
listenToControls :: proc(self: ^MenuSounds, node: ^e.Node) {
	for child in node.children {
		if e.Node_IsControl(child) {
			c := cast(^e.Control)child
			e.Event_Subscribe(&c.onFocusChanged, menuSound, self)
			if e.Node_Is(child, e.Button) do e.Event_Subscribe(&(cast(^e.Button)child).onPressed, menuSound, self)
			if e.Node_Is(child, e.CheckBox) do e.Event_Subscribe(&(cast(^e.CheckBox)child).onToggled, menuSound, self)
		}
		listenToControls(self, child)
	}
}

@(init)
register_MenuSounds :: proc "contextless" () {
	e.Script_Register(MenuSounds, {
		ready = proc(self: ^MenuSounds) {
			listenToControls(self, self.node)
		},
		update = proc(self: ^MenuSounds, _: []sdl.Event, dt: f64) {
			self.time += f32(dt)
		},
	})
}
