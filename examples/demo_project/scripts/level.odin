package scripts

import "core:strings"
import e "engine:."
import sdl "vendor:sdl3"

/*
Level: the director of a level scene (a Node2D named "Director" in each), what isn't any one
thing's:

- **Music with layers:** the scene's MusicPlayer streams the level's theme with a drums layer at
  volume 0; when creatures come close to the hero (or the boss fights) the drums fade in
  (`e.MusicPlayer_SetLayerVolume`), and fade out once it's calm. The boss's arrival crossfades
  to its own theme (`e.MusicPlayer_CrossfadeTo`), its defeat to the victory theme.
- **Bus effects:** in the caves the SFX bus gets a reverb (`e.Audio_SetBusEffects`), taken off when
  the scene ends.
- **Dialogue:** the HUD's DialogueBox plays nodes of `dialogues/story.dialogue.xml`
  (`Dialogue_Play`): the opening of a new game, the lore stones, the boss. While one plays the hero
  doesn't take input (GameState.cutscene) and black bars slide in (tweens on two Panels). The
  dialogue's commands (`<<shake>>`, `<<drums>>`) come through the box's onCommand event.
- **The boss's entrance:** an Animator clip made in the Timeline ("BossIntro"): an event track
  ("gate", "pan", "roar", "talk") that this script listens to (`Level_onIntroEvent`, a listener
  in the scene file), while its other tracks slide the bars in.
- **The arena's camera:** a CameraZone keeps the camera in the boss's arena once she's in it, and
  the fight zooms out (`e.Camera2D_ZoomTo`).
- **Pause:** the pause action opens PauseScene over the level (`e.Game_PushScene`: the level
  stops under it).
*/
Level :: struct {
	using script: e.Script,
	// The level's name, shown when it starts
	title: string `export:"default=The Whispering Woods"`,
	// A dialogue node played when a new game starts here ("": none)
	intro: string `export:""`,
	// The SFX bus echoes (caves)
	reverb: bool `export:""`,
	music: ^e.MusicPlayer `export:"default=../Music"`,
	box: ^e.DialogueBox `export:"default=../HUD/Dialogue"`,
	barTop: ^e.Control `export:"default=../HUD/BarTop"`,
	barBottom: ^e.Control `export:"default=../HUD/BarBottom"`,
	// The boss entrance's Animator (the Lair's), under this node
	introClip: ^e.Animator `export:""`,
	// The gate the boss's trigger closes (found by its entity reference)
	gate: e.EntityId,
	// Seconds the danger lasts after the last creature near the hero
	danger: f32,
	drums: bool,
	// What happens when the dialogue playing ends
	after: DialogueAfter,
	// The boss is down: seconds before the ending
	ending: f32,
	started: bool,
}

// What a dialogue's end leads to
DialogueAfter :: enum {
	Nothing,
	// The opening ended: the level's name
	Title,
	// The boss's speech ended: the fight
	Fight,
	// The ending ended: the victory screen
	Victory,
}

// The scene's director, or nil
Level_Get :: proc(scene: ^e.Scene) -> ^Level {
	if node := e.Scene_FindNode(scene, "Director"); node != nil do return e.Node_GetScript(node, Level)
	return nil
}

// Whether a dialogue is playing in the scene
Dialogue_Playing :: proc(scene: ^e.Scene) -> bool {
	level := Level_Get(scene)
	return level != nil && level.box != nil && e.DialogueBox_IsPlaying(level.box)
}

/*
Plays a node of the story's dialogue in the HUD's box; the hero waits until it ends.

Inputs:
- node: The dialogue node ("Intro", "Sign_Move"...)
- after: What its end leads to
*/
Dialogue_Play :: proc(scene: ^e.Scene, node: string, after := DialogueAfter.Nothing) {
	level := Level_Get(scene)
	if level == nil || level.box == nil || node == "" do return
	// The player's own keys, for lines like "Jump with {$jump}"
	vars := &scene.game.dialogueVariables
	for pair in ([?][2]string{{"$left", ACTION_LEFT}, {"$right", ACTION_RIGHT}, {"$down", ACTION_DOWN}, {"$jump", ACTION_JUMP}, {"$attack", ACTION_ATTACK}, {"$read", ACTION_INTERACT}}) {
		e.DialogueVariables_Set(vars, pair[0], BindingName(pair[1]))
	}
	if !e.DialogueBox_Start(level.box, node) do return
	level.after = after
	if state := State(); state != nil do state.cutscene += 1
	bars(level, true)
}

// The black bars of a cutscene, in or out
@(private="file")
bars :: proc(level: ^Level, show: bool) {
	for bar, i in ([2]^e.Control{level.barTop, level.barBottom}) {
		if bar == nil do continue
		h := bar.settings.size.y
		out := i == 0 ? -h : h
		e.Tween_To(e.Tween_Create(bar), &bar.offset, [2]f32{0, show ? 0 : out}, 0.35, .OutCubic)
	}
}

// The music fades out (leaving the level)
Level_FadeMusic :: proc(scene: ^e.Scene, seconds: f32) {
	if level := Level_Get(scene); level != nil && level.music != nil do e.MusicPlayer_FadeOut(level.music, seconds)
}

/*
The arena's trigger: the boss's entrance plays (its Animator clip), and the gate the trigger's
LDtk "gate" field points at (an entity reference) drops.
*/
Level_StartBoss :: proc(scene: ^e.Scene, trigger: ^e.Node) {
	level := Level_Get(scene)
	if level == nil do return
	if gate := e.LDtk_EntityRefNode(trigger, "gate"); gate != nil do level.gate = gate.id
	if state := State(); state != nil do state.cutscene += 1
	bars(level, true)
	if level.introClip != nil do e.Animator_Play(level.introClip, "intro", true)
	else do Level_onIntroEvent(level, nil, "talk")
}

/*
The boss entrance's event track (the "BossIntro" Animator's onEvent, a listener in LairScene's
file): "gate" drops the gate, "pan" shows the boss, "roar" wakes it, "talk" plays its speech.
*/
Level_onIntroEvent :: proc(self: ^Level, source: ^e.Node, data: e.EventData) {
	name, _ := data.(string)
	switch name {
	case "gate":
		if node := e.Scene_GetNode(self.scene, self.gate); node != nil {
			if gate := e.Node_GetScript(node, Gate); gate != nil do Gate_Close(gate)
		}
	case "pan":
		if boss := currentBoss; boss != nil && self.scene.camera != nil {
			e.Camera2D_MoveTo(self.scene.camera, e.Node_GetWorldPosition(boss.node) - {0, 40}, 1.2)
		}
		if self.music != nil do e.MusicPlayer_FadeOut(self.music, 1.5)
	case "roar":
		if boss := currentBoss; boss != nil {
			Sfx(self.game, SOUND_BOSS_ROAR)
			e.Camera2D_Shake(self.scene.camera, 6, 1.2)
			e.Input_Rumble(0.8, 0.8, 0.8)
		}
	case "talk":
		if state := State(); state != nil do state.cutscene = max(state.cutscene - 1, 0)
		Dialogue_Play(self.scene, "Lair_Boss", .Fight)
	}
}

@(init)
register_Level_onIntroEvent :: proc "contextless" () {
	e.Script_Listener(Level, "onIntroEvent", Level_onIntroEvent)
}

// A conversation ended (the box's onFinished)
@(private="file")
dialogueFinished :: proc(_: ^e.EventSubject, _: rawptr, _: e.EventData, user: rawptr) {
	level := cast(^Level)user
	state := State()
	if state != nil do state.cutscene = max(state.cutscene - 1, 0)
	bars(level, false)
	after := level.after
	level.after = .Nothing
	switch after {
	case .Nothing:
	case .Title:
		Hud_Toast(level.scene, level.title)
	case .Fight:
		if self := level; self.music != nil {
			e.MusicPlayer_CrossfadeTo(self.music, MUSIC_BOSS.path, 1.5)
			self.drums = false
		}
		if boss := currentBoss; boss != nil do Boss_Wake(boss)
		// The arena's whole width in view for the fight (a smooth zoom)
		if camera := level.scene.camera; camera != nil do e.Camera2D_ZoomTo(camera, 2.2, 1.5)
	case .Victory:
		if state != nil do GameState_Victory(state)
	}
}

// The dialogue's commands (<<shake>>, <<drums>>): the box's onCommand
@(private="file")
dialogueCommand :: proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, user: rawptr) {
	level := cast(^Level)user
	text, _ := data.(string)
	switch {
	case strings.has_prefix(text, "shake"):
		e.Camera2D_Shake(level.scene.camera, 4, 0.5)
	case strings.has_prefix(text, "drums"):
		if level.music != nil do e.MusicPlayer_SetLayerVolume(level.music, "drums", 1, seconds = 1)
	}
}

@(init)
register_Level :: proc "contextless" () {
	e.Script_Register(Level, {
		ready = proc(self: ^Level) {
			if self.box != nil {
				e.Event_Subscribe(&self.box.onFinished, dialogueFinished, self)
				e.Event_Subscribe(&self.box.onCommand, dialogueCommand, self)
			}
			if self.reverb {
				hall := e.AudioEffect_Make(.Reverb)
				e.Audio_SetBusEffects("SFX", {hall})
			}
		},
		destroy = proc(self: ^Level) {
			if self.reverb && self.game != nil do e.Audio_SetBusEffects("SFX", {}, self.game)
		},
		update = proc(self: ^Level, _: []sdl.Event, deltaTime: f64) {
			dt := f32(deltaTime)
			state := State()
			// On the first frame (every node is ready): a new game's opening, else the level's name
			if !self.started {
				self.started = true
				if state != nil && state.intro && self.intro != "" {
					state.intro = false
					Dialogue_Play(self.scene, self.intro, .Title)
				} else {
					Hud_Toast(self.scene, self.title)
				}
			}

			// Pause: the pause menu over the level
			if e.Input_IsActionJustPressed(ACTION_PAUSE) && (state == nil || state.cutscene == 0) && currentHero != nil && !currentHero.dead {
				Sfx(self.game, SOUND_PAUSE)
				e.Game_PushScene(self.game, "PauseScene")
				return
			}

			// Danger: creatures near the hero bring the drums in
			if hero := currentHero; hero != nil && self.music != nil {
				near := false
				for enemy in liveEnemies do if Enemy_Alive(enemy) && Hero_Near(Enemy_Center(enemy), 200) do near = true
				if boss := currentBoss; boss != nil && boss.mode != .Asleep && !boss.defeated do near = false
				self.danger = near ? 3 : max(self.danger - dt, 0)
				drums := self.danger > 0
				if drums != self.drums {
					self.drums = drums
					e.MusicPlayer_SetLayerVolume(self.music, "drums", drums ? 1 : 0, seconds = drums ? 1 : 2.5)
				}
			}

			// The boss down: its fall, then the ending
			if boss := currentBoss; boss != nil && boss.defeated && self.ending == 0 {
				self.ending = 3.5
				if self.music != nil do e.MusicPlayer_CrossfadeTo(self.music, MUSIC_VICTORY.path, 3)
				if state != nil do state.run.score += 1000
			}
			if self.ending > 0 {
				self.ending -= dt
				if self.ending <= 0 {
					self.ending = -1
					Dialogue_Play(self.scene, "Ending", .Victory)
				}
			}
		},
	})
}
