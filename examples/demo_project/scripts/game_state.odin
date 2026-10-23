package scripts

import "core:log"
import "core:strings"
import e "engine:."
import sdl "vendor:sdl3"

/*
GameState: a GLOBAL SCRIPT (Project Settings > Globals). The game makes one when it starts and
keeps it across every scene, so it holds what outlives a level: the run, the save, the options.

- **The run** (`run`): the level being played, the last rune stone touched, score, coins, gems,
  what was picked up (by LDtk entity iid, so a Continue doesn't bring it back), deaths and time.
- **The save** (`saved`): a copy of the run made at every rune stone and at the start of every
  level (`GameState_Checkpoint`). `e.Save_Game()` writes the globals' fields as JSON: `saved`,
  the best score and the options are saved; `run` and the health are tagged `save:"-"`, so a
  Continue or a Retry starts again from the last rune stone (`GameState_Continue`).
- **The options** (`musicVolume`, `sfxVolume`, `fullscreen`): the Music and SFX mix buses'
  volumes (`e.Audio_SetBusVolume`) and the window (`e.Game_SetFullscreen`), applied when the
  game starts (`ready`, after `e.Load_Game()`) and whenever they change. The controls are the
  engine's input bindings, kept in their own save slot (`e.Input_LoadBindings` here,
  `e.Input_SaveBindings` in the options screen).

Any script reaches it with `e.Global(GameState)` (or `State()` below).
*/
GameState :: struct {
	using script: e.Script,
	// Hearts the hero has (Project Settings > Globals)
	maxHealth: int `export:"default=5 min=1 max=12"`,
	// Gems hidden in the game (the victory screen counts them)
	totalGems: int `export:"default=6 min=0 max=99"`,

	// What Continue brings back: the run at the last rune stone (saved)
	saved: Progress,
	// The best score of a finished game (saved)
	bestScore: int,
	// The game has been finished once (saved)
	finished: bool,
	// Options (saved)
	musicVolume: f32,
	sfxVolume: f32,
	fullscreen: bool,

	// The run being played (not saved: Continue and Retry start from `saved`)
	run: Progress `save:"-"`,
	// Hearts left
	health: int `save:"-"`,
	// Seconds of safety left after a hit
	invulnerable: f32 `save:"-"`,
	// The forest's opening dialogue plays (a new game)
	intro: bool `save:"-"`,
	// While above 0 the hero doesn't take input: a dialogue or a cutscene runs
	cutscene: int `save:"-"`,
}

// A run's progress: what a save holds (GameState.saved) and what's being played (GameState.run)
Progress :: struct {
	// The scene of the level ("" before a game starts)
	level: string,
	// The LDtk iid of the last rune stone touched in it ("": the level's start)
	checkpoint: string,
	score: int,
	coins: int,
	gems: int,
	deaths: int,
	// Seconds played
	time: f64,
	// Pickups and gems taken, by LDtk entity iid
	taken: map[string]bool,
}

// The levels in order, and what they're called
LEVELS :: [?]string{"ForestScene", "HollowScene", "LairScene"}

// The game state (the global), or nil outside a game
State :: proc() -> ^GameState {
	return e.Global(GameState)
}

// Replaces a run's string with a copy of `text` (the old one freed; "" is the zero string)
@(private="file")
setText :: proc(field: ^string, text: string) {
	delete(field^)
	field^ = text == "" ? {} : strings.clone(text)
}

// A deep copy of a run (its strings and map its own)
Progress_Clone :: proc(p: Progress) -> Progress {
	c := p
	c.level = p.level == "" ? {} : strings.clone(p.level)
	c.checkpoint = p.checkpoint == "" ? {} : strings.clone(p.checkpoint)
	c.taken = make(map[string]bool)
	for k, v in p.taken do c.taken[strings.clone(k)] = v
	return c
}

// Frees a run's strings and map
Progress_Destroy :: proc(p: ^Progress) {
	delete(p.level)
	delete(p.checkpoint)
	for k in p.taken do delete(k)
	delete(p.taken)
	p^ = {}
}

// Whether a saved game exists to Continue
GameState_CanContinue :: proc(state: ^GameState) -> bool {
	return state != nil && state.saved.level != ""
}

// A new game: a fresh run from the forest, saved at once (so Continue comes back to it)
GameState_NewGame :: proc(state: ^GameState) {
	Progress_Destroy(&state.run)
	state.run = Progress{level = strings.clone(LEVELS[0]), taken = make(map[string]bool)}
	state.intro = true
	GameState_Save(state)
	enterLevel(state)
}

// Plays on from the save: its level, from its rune stone
GameState_Continue :: proc(state: ^GameState) {
	Progress_Destroy(&state.run)
	state.run = Progress_Clone(state.saved)
	state.intro = false
	enterLevel(state)
}

// After a defeat: back to the last rune stone (what was gathered since is lost)
GameState_Retry :: proc(state: ^GameState) {
	GameState_Continue(state)
}

// Full health, then into the run's level (through the loading screen)
@(private="file")
enterLevel :: proc(state: ^GameState) {
	state.health = state.maxHealth
	state.invulnerable = 0
	state.cutscene = 0
	e.Game_ChangeScene(state.game, state.run.level)
}

/*
A rune stone touched: the run is saved here (Continue and Retry come back to it) and the hero
is healed.

Inputs:
- key: The rune stone's LDtk iid ("" for the level's start)
*/
GameState_Checkpoint :: proc(state: ^GameState, key: string) {
	if state.game.currentScene != nil do setText(&state.run.level, state.game.currentScene.name)
	setText(&state.run.checkpoint, key)
	state.health = state.maxHealth
	GameState_Save(state)
}

// Copies the run into the save and writes it (with the options)
GameState_Save :: proc(state: ^GameState) {
	Progress_Destroy(&state.saved)
	state.saved = Progress_Clone(state.run)
	if !e.Save_Game() do log.warn("The game couldn't be saved")
}

// The level's end: the next one starts (saved at its start), or the game is won
GameState_LevelComplete :: proc(state: ^GameState, next: string) {
	if next == "" || next == "VictoryScene" {
		GameState_Victory(state)
		return
	}
	setText(&state.run.level, next)
	setText(&state.run.checkpoint, "")
	GameState_Save(state)
	enterLevel(state)
}

// The boss is beaten: the best score kept, the save cleared (the story is over), the victory screen
GameState_Victory :: proc(state: ^GameState) {
	state.finished = true
	state.bestScore = max(state.bestScore, state.run.score)
	Progress_Destroy(&state.saved)
	if !e.Save_Game() do log.warn("The game couldn't be saved")
	e.Game_ChangeScene(state.game, "VictoryScene")
}

// The hero fell: a death counted (and saved), then the game over screen
GameState_Defeated :: proc(state: ^GameState) {
	state.saved.deaths += 1
	state.run.deaths = state.saved.deaths
	if !e.Save_Game() do log.warn("The game couldn't be saved")
	e.Game_ChangeScene(state.game, "GameOverScene")
}

/*
Takes hearts (unless the hero is still safe from the last hit) and gives a moment of safety.

Returns:
- true when that was the last of them
*/
GameState_Damage :: proc(state: ^GameState, amount: int) -> bool {
	if state.invulnerable > 0 || state.health <= 0 do return false
	state.health = max(state.health - amount, 0)
	state.invulnerable = 1.3
	return state.health == 0
}

// Gives back hearts, up to the most
GameState_Heal :: proc(state: ^GameState, amount: int) {
	state.health = min(state.health + amount, state.maxHealth)
}

// Marks a pickup (its LDtk iid) taken, so the level doesn't bring it back from this run's save
GameState_Take :: proc(state: ^GameState, key: string) {
	if key != "" do state.run.taken[strings.clone(key)] = true
}

// Whether a pickup was taken in this run
GameState_Taken :: proc(state: ^GameState, key: string) -> bool {
	return key != "" && state.run.taken[key]
}

// Applies the options: the buses' volumes and the window
GameState_ApplySettings :: proc(state: ^GameState) {
	e.Audio_SetBusVolume("Music", state.musicVolume)
	e.Audio_SetBusVolume("SFX", state.sfxVolume)
	if e.Game_IsFullscreen(state.game) != state.fullscreen do e.Game_SetFullscreen(state.game, state.fullscreen)
}

// Plays a sound effect on the SFX bus (the options' sound volume)
Sfx :: proc(game: ^e.Game, sound: e.SoundAsset, volume: f32 = 1, pitch: f32 = 1) {
	e.Game_PlaySound(game, sound, bus = "SFX", volume = volume, pitch = pitch)
}

@(init)
register_GameState :: proc "contextless" () {
	e.Script_Register(GameState, {
		// Once, when the game starts: the options' defaults, then the save over them
		ready = proc(self: ^GameState) {
			self.musicVolume, self.sfxVolume = 0.8, 0.9
			self.run.taken = make(map[string]bool)
			if e.Load_Game() {
				log.infof("Welcome back: %s, best score %d", self.saved.level == "" ? "no game going" : self.saved.level, self.bestScore)
			}
			if self.saved.taken == nil do self.saved.taken = make(map[string]bool)
			e.Input_LoadBindings()
			GameState_ApplySettings(self)
			self.health = self.maxHealth
		},
		update = proc(self: ^GameState, _: []sdl.Event, dt: f64) {
			self.invulnerable = max(self.invulnerable - f32(dt), 0)
			if scene := self.game.currentScene; scene != nil && IsLevel(scene.name) && self.cutscene == 0 do self.run.time += dt
		},
		// Started in a level directly (Play Scene in the editor): a run there
		sceneChanged = proc(self: ^GameState, scene: ^e.Scene) {
			if IsLevel(scene.name) && self.run.level != scene.name {
				setText(&self.run.level, scene.name)
				setText(&self.run.checkpoint, "")
				self.health = self.maxHealth
			}
			self.cutscene = 0
		},
	})
}

// Whether a scene is one of the levels
IsLevel :: proc(name: string) -> bool {
	for level in LEVELS do if level == name do return true
	return false
}
