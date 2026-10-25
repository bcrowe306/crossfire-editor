---
title: "Node guides: sound"
description: How to use the sound nodes (AudioPlayer, AudioPlayer2D and MusicPlayer) in the editor and from scripts.
order: 52
---

# Node guides: sound

The sound nodes play sound effects and music: a sound that's the same wherever it is, a sound
placed in the world, and streamed music. Each section below is one node kind's guide: what it
does, its properties, how to set it up in the editor, how a script uses it, an example and its
API. See [Node guides](nodes.md) for the other kinds, and [Sound and music](sound.md) and
[Bus effects, crossfades and music layers](audio_effects_and_music.md) for the whole picture.

- [AudioPlayer](#audioplayer)
- [AudioPlayer2D](#audioplayer2d)
- [MusicPlayer](#musicplayer)
- [Questions](#questions)

## AudioPlayer

An AudioPlayer plays a sound at the same volume and pan wherever the node is: interface clicks,
the player's own jump or footsteps, a voice line. It plays through a mix **bus**, so the Mixer
(and an options menu) can turn it down with the other sounds on that bus. Use it when a sound
needs settings of its own (a bus, looping, a volume) or has to be stopped and paused; for a quick
one-off sound, `e.Game_PlaySound` needs no node at all. In code it's an `e.AudioPlayer`.

**Properties**

| Property | What it does |
|---|---|
| **Sound** | The file it plays: one of the project's Sounds (not Music) |
| **Bus** | The mixer bus it plays through (empty: Master). **Open Mixer** shows the Mixer tab |
| **Volume** | 0 silent, 1 as recorded, up to 2 (louder, but it may distort) |
| **Pitch** | Playback speed: 1 normal, 2 twice as fast and an octave up, 0.5 half as fast |
| **Pan** | -1 left, 0 the middle, 1 right |
| **Loop** | Plays again from the start when it ends, until stopped |
| **Autostart** | Starts by itself when the scene starts (and each time the game comes back to it) |
| **Preview** | Plays the sound with the node's volume, pitch and pan, through its bus (**Stop** stops it) |

**In the editor**

1. Import the sound (File > **Import Asset...**, Ctrl+I). It's a Sound unless you made it Music.
2. Add Node (Ctrl+Shift+A) > **AudioPlayer**. Put it under the node it belongs to (the player,
   a door, the menu): it needs no children, and its position doesn't change what you hear.
3. Choose its **Sound** and its **Bus** (say **SFX**: add buses in the **Mixer** bottom tab).
4. Set **Volume**, **Pitch** and **Pan**, and press **Preview** to hear it. The viewport never
   plays sounds.
5. Tick **Autostart** if it should start with the scene, or play it from a script.
6. Press Play (F5) and check you hear it when it should play.

**From code**

A script reaches the node through a node field, `^e.AudioPlayer` with
`export:"default=<path>"` (drop the node from the scene tree onto the code tab to add one).
`e.AudioPlayer_Play` plays it from the start (again, if it was playing), `e.AudioPlayer_Stop`
stops it, `e.AudioPlayer_Pause` and `e.AudioPlayer_Resume` pause and carry on, and
`e.AudioPlayer_IsPlaying` says whether it's playing. Its `settings` (`volume`, `pitch`, `pan`,
`loop`, `autostart`) can change at any time. `e.AudioPlayer_SetSound` and `e.AudioPlayer_SetBus`
change what it plays and where. Its **onFinished** event fires when the sound ends by itself.

**Example**

A door that creaks when it opens, a little higher or lower each time:

```odin
CreakyDoor :: struct {
	using script: e.Script,
	creak: ^e.AudioPlayer `export:"default=Creak"`,
	open: bool,
}

CreakyDoor_update :: proc(self: ^CreakyDoor, events: []sdl.Event, dt: f64) {
	if !e.Input_IsActionJustPressed("ui_accept") do return
	self.open = !self.open
	// Vary the pitch so the creak doesn't sound the same every time
	self.creak.settings.pitch = 0.9 + 0.2 * rand.float32()
	e.AudioPlayer_Play(self.creak)
}

@(init)
register_CreakyDoor :: proc "contextless" () {
	e.Script_Register(CreakyDoor, {update = CreakyDoor_update})
}
```

**API**

[e.AudioPlayer](https://crossfireengine.io/api/audio/#audioplayer),
[e.AudioSettings](https://crossfireengine.io/api/audio/#audiosettings),
[e.AudioPlayer_Play](https://crossfireengine.io/api/audio/#audioplayer_play),
[e.AudioPlayer_Stop](https://crossfireengine.io/api/audio/#audioplayer_stop),
[e.AudioPlayer_Pause](https://crossfireengine.io/api/audio/#audioplayer_pause),
[e.AudioPlayer_Resume](https://crossfireengine.io/api/audio/#audioplayer_resume),
[e.AudioPlayer_IsPlaying](https://crossfireengine.io/api/audio/#audioplayer_isplaying),
[e.AudioPlayer_SetSound](https://crossfireengine.io/api/audio/#audioplayer_setsound),
[e.AudioPlayer_SetBus](https://crossfireengine.io/api/audio/#audioplayer_setbus),
[e.CreateAudioPlayer](https://crossfireengine.io/api/audio/#createaudioplayer),
[e.Audio_SetBusVolume](https://crossfireengine.io/api/audio/#audio_setbusvolume)

More: [Sound and music](sound.md#sound-in-scripts)

## AudioPlayer2D

An AudioPlayer2D plays a sound **in the world**: loudest at the listener (the scene's camera, or
the middle of the game area when there's none), quieter with distance, silent past its
**Range**, and panned toward the side it's on. Use it for a waterfall you walk past, an enemy's
growl, a machine humming across the room. Its settings are an AudioPlayer's plus two; in code
it's an `e.AudioPlayer2D` (the same struct as `e.AudioPlayer`, with `kind` set to `.Positional`).

**Properties**

| Property | What it does |
|---|---|
| **Sound**, **Bus** | The sound it plays and the bus it goes through, as for an AudioPlayer |
| **Volume**, **Pitch**, **Pan** | Its volume at the listener, its speed, and a pan added to the one its place gives |
| **Loop**, **Autostart** | Plays again when it ends; starts with the scene |
| **Range** | Pixels from the listener where it can no longer be heard (1000 by default) |
| **Falloff** | How the volume falls with distance: 1 evenly to the range, 2 and more drops quickly near the source, below 1 stays loud longer |
| **Preview** | Plays it as the node plays it, without the distance |

**In the editor**

1. Add Node (Ctrl+Shift+A) > **AudioPlayer2D**, under the node the sound comes from (the enemy,
   the waterfall's sprite), so it moves with it. It needs no children.
2. Place it where the sound comes from in the viewport, and choose its **Sound** and **Bus**.
3. Set its **Range**: selected, it shows the range as a ring in the viewport. Set **Falloff**.
4. Tick **Loop** and **Autostart** for a sound that's always there (a waterfall, a hum).
5. Press Play (F5) and move the camera toward it and past it: it gets louder, then moves from
   one side to the other.

**From code**

The same as an AudioPlayer: a node field of type `^e.AudioPlayer2D`, and the `e.AudioPlayer_*`
procedures. `settings.maxDistance` is the **Range** and `settings.attenuation` the **Falloff**.
The distance and side come from the node's world position each frame, so moving the node (or its
parent) is all it takes. `e.Audio_Positional` computes the volume and pan the engine uses.

**Example**

A buzzing drone that flies back and forth: its AudioPlayer2D child follows it, so the buzz moves
from side to side.

```odin
Drone :: struct {
	using script: e.Script,
	buzz: ^e.AudioPlayer2D `export:"default=Buzz"`,
	// Pixels it flies to each side of where it starts
	reach: f32 `export:""`,
	start: [2]f32,
	time: f32,
}

Drone_ready :: proc(self: ^Drone) {
	self.start = self.node.position
	if self.reach == 0 do self.reach = 300
	self.buzz.settings.loop = true
	e.AudioPlayer_Play(self.buzz)
}

Drone_update :: proc(self: ^Drone, events: []sdl.Event, dt: f64) {
	self.time += f32(dt)
	self.node.position.x = self.start.x + self.reach * math.sin(self.time)
}

@(init)
register_Drone :: proc "contextless" () {
	e.Script_Register(Drone, {ready = Drone_ready, update = Drone_update})
}
```

**API**

[e.AudioPlayer2D](https://crossfireengine.io/api/audio/#audioplayer2d),
[e.AudioSettings](https://crossfireengine.io/api/audio/#audiosettings),
[e.AudioPlayerKind](https://crossfireengine.io/api/audio/#audioplayerkind),
[e.Audio_Positional](https://crossfireengine.io/api/audio/#audio_positional),
[e.AudioPlayer_Play](https://crossfireengine.io/api/audio/#audioplayer_play),
[e.AudioPlayer_Stop](https://crossfireengine.io/api/audio/#audioplayer_stop)

More: [Sound and music](sound.md#sounds-in-the-world-audioplayer2d)

## MusicPlayer

A MusicPlayer **streams** music: it reads the file bit by bit as it plays, so a long song doesn't
fill the memory. It fades in and out, seeks, crossfades to another song and plays **layers**
(stems of one song) in step with it. Use it for a level's song or a menu theme. Its sound must be
a Music asset (right-click a sound in the browser > **Use as Music (streamed)**). In code it's an
`e.MusicPlayer` (the same struct as `e.AudioPlayer`, with `kind` set to `.Music`).

**Properties**

| Property | What it does |
|---|---|
| **Music** | The file it streams: one of the project's Music |
| **Bus** | The mixer bus it plays through (a **Music** bus lets the options menu turn it down) |
| **Volume**, **Speed**, **Pan** | Its volume, playback speed (1 normal) and pan |
| **Loop**, **Autostart** | Plays again when it ends; starts with the scene |
| **Fade in (s)** | Seconds it fades in when it starts (0: no fade) |
| **Fade out (s)** | Seconds it fades out when it's stopped (0: no fade) |
| **Layers** | **Add Layer**, then each layer's **Layer name**, **Layer music** and **Layer volume** (the bin removes it) |
| **Preview** | Plays the main music through its bus (not the layers) |

**In the editor**

1. Import the song, then right-click it in the browser > **Use as Music (streamed)**.
2. Add Node (Ctrl+Shift+A) > **MusicPlayer**, anywhere in the level's scene (often near the root,
   named Music). It needs no children.
3. Choose its **Music**, its **Bus**, and tick **Loop** and **Autostart** for a level's song. Set
   **Fade in (s)** and **Fade out (s)** for smooth starts and stops.
4. For adaptive music, press **Add Layer** under **Layers**, give the layer a **Layer name**
   (scripts use it), its **Layer music**, and a **Layer volume** (0: silent until a script fades
   it in).
5. Press Play (F5): the song (and its layers) should start, and loop when it ends.

**From code**

A node field of type `^e.MusicPlayer` reaches it. The `e.AudioPlayer_*` procedures play, stop
(fading over **Fade out (s)**), pause and resume it. `e.MusicPlayer_FadeOut` fades it out over any
number of seconds, `e.MusicPlayer_Seek` jumps in the song, and `e.MusicPlayer_GetPosition` and
`e.MusicPlayer_GetDuration` say where it is and how long it is (seconds).
`e.MusicPlayer_CrossfadeTo` fades to another song. Layers: `e.MusicPlayer_SetLayerVolume` fades
one by name, `e.MusicPlayer_AddLayer` and `e.MusicPlayer_RemoveLayer` add and remove them, and
`e.MusicPlayer_GetLayer` finds one.

**Example**

A level's music: the drums layer comes in when a fight starts and goes when it ends, the boss
gets its own song, and P pauses the music.

```odin
LevelMusic :: struct {
	using script: e.Script,
	music: ^e.MusicPlayer `export:"default=Music"`,
	fighting: bool,
}

LevelMusic_update :: proc(self: ^LevelMusic, events: []sdl.Event, dt: f64) {
	if e.Input_IsKeyJustPressed(.F) {
		self.fighting = !self.fighting
		// The drums fade in (or out) over two seconds
		e.MusicPlayer_SetLayerVolume(self.music, "drums", self.fighting ? 1 : 0, seconds = 2)
	}
	if e.Input_IsKeyJustPressed(.B) {
		e.MusicPlayer_CrossfadeTo(self.music, "assets/boss_theme.ogg", 3)
	}
	if e.Input_IsKeyJustPressed(.P) {
		if e.AudioPlayer_IsPlaying(self.music) {
			e.AudioPlayer_Pause(self.music)
		} else {
			e.AudioPlayer_Resume(self.music)
		}
	}
}

@(init)
register_LevelMusic :: proc "contextless" () {
	e.Script_Register(LevelMusic, {update = LevelMusic_update})
}
```

**API**

[e.MusicPlayer](https://crossfireengine.io/api/audio/#musicplayer),
[e.MusicPlayer_FadeOut](https://crossfireengine.io/api/audio/#musicplayer_fadeout),
[e.MusicPlayer_Seek](https://crossfireengine.io/api/audio/#musicplayer_seek),
[e.MusicPlayer_GetPosition](https://crossfireengine.io/api/audio/#musicplayer_getposition),
[e.MusicPlayer_GetDuration](https://crossfireengine.io/api/audio/#musicplayer_getduration),
[e.MusicPlayer_CrossfadeTo](https://crossfireengine.io/api/audio/#musicplayer_crossfadeto),
[e.MusicPlayer_AddLayer](https://crossfireengine.io/api/audio/#musicplayer_addlayer),
[e.MusicPlayer_SetLayerVolume](https://crossfireengine.io/api/audio/#musicplayer_setlayervolume),
[e.MusicPlayer_RemoveLayer](https://crossfireengine.io/api/audio/#musicplayer_removelayer),
[e.MusicLayer](https://crossfireengine.io/api/audio/#musiclayer)

More: [Bus effects, crossfades and music layers](audio_effects_and_music.md#music-layers)

## Questions

**Playing an AudioPlayer again cuts the sound off.** A sound node plays one sound at a time:
`e.AudioPlayer_Play` restarts it. For sounds that overlap (rapid gunshots, coins), use
`e.Game_PlaySound`, which plays up to 32 at once.

**I changed `settings.loop` but the sound still stops (or keeps looping).** Volume, pitch and pan
apply the next frame, but looping is decided when it starts: call `e.AudioPlayer_Play` again.

**My MusicPlayer's list doesn't show my song.** A MusicPlayer only lists Music, and the other
sound nodes only Sounds. Right-click the file in the browser > **Use as Music (streamed)** (or
**Use as a Sound**).

**My AudioPlayer2D is silent in the game.** It's further from the camera than its **Range**.
The listener is the scene's camera (where it looks), or the middle of the game area without one.

**Preview doesn't play my music's layers.** Preview plays the main music only; layers play in the
game (Play, F5). A layer with no name, or two with the same name, gets a warning: scripts fade
layers by name, and the game keeps the last one of a name.

**`onFinished` never fires.** It fires when the sound ends by itself: not when a script stops it,
and never for a looping sound.
