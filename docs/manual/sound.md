---
title: Sound and music
description: Play sound effects and music with AudioPlayer, AudioPlayer2D and MusicPlayer nodes, mix them on buses in the Mixer tab, and play sounds from scripts.
order: 13
---

# Sound and music

Sound brings a game to life: a jump's whoosh, a coin's chime, footsteps, an explosion off to the
left, music that sets the mood. This page covers the basics: getting sounds into the project,
the nodes that play them, the **Mixer** that balances them, and playing sounds from your code.

Effects on buses (muffled, echo, reverb), fading from one song to another and music made of
layers are on their own page: [Bus effects, crossfades and music layers](audio_effects_and_music.md).

- [Sounds and music in the project](#sounds-and-music-in-the-project)
- [The sound nodes](#the-sound-nodes)
- [The inspector's settings](#the-inspectors-settings)
- [Sounds in the world: AudioPlayer2D](#sounds-in-the-world-audioplayer2d)
- [The Mixer: buses](#the-mixer-buses)
- [Sound in scripts](#sound-in-scripts)
- [The sound device and output format](#the-sound-device-and-output-format)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Sounds and music in the project

**Importing:** File > **Import Asset...** (Ctrl+I) and pick a sound file. WAV, OGG, MP3 and FLAC
play as they are; other formats (M4A, AAC, Opus...) are converted to Ogg Vorbis as they're
imported, when ffmpeg is installed (see
[Asset import settings](asset_import.md)). Select a sound in the browser to hear it: its preview,
under the browser, plays it.

A sound file is used in one of two ways:

| Kind | How it plays | Use it for |
|---|---|---|
| **Sound** (the browser's **Audio** folder) | Loaded whole into memory once, then plays at once, as many times as you like, even overlapping | Short effects: jumps, hits, coins, footsteps, voices |
| **Music** (the browser's **Music** folder) | **Streamed**: read from the file bit by bit as it plays, so a long song doesn't fill the memory | Songs and long ambient loops, played by a MusicPlayer |

Imported files are Sounds. To make one Music, right-click it in the browser > **Use as Music
(streamed)**; **Use as a Sound** turns it back.

## The sound nodes

They're in **Add Node** (Ctrl+Shift+A) under Sound.

| Node | What it plays | Use it for |
|---|---|---|
| **AudioPlayer** | A sound, the same wherever it is | Interface sounds, the player's own sounds, anything that needn't come from a place |
| **AudioPlayer2D** | A sound **in the world**: louder near the camera, quieter far away, and from the left or right side it's on | A waterfall you walk past, an enemy's growl, a door creaking across the room |
| **MusicPlayer** | Music, streamed | The level's song, a menu theme |

Put a player where it belongs: an AudioPlayer2D under the enemy that growls moves with it. Then
start it from a script, or tick **Autostart** to have it start with the scene.

The viewport never plays sounds; press **Preview** in the inspector, or Play.

## The inspector's settings

| Setting | What it does |
|---|---|
| **Sound** (**Music** for a MusicPlayer) | The file it plays: the project's Sounds (or Music) |
| **Bus** | The mixer bus it plays through ([The Mixer](#the-mixer-buses)). **Open Mixer** shows the Mixer tab |
| **Volume** | 0 silent, 1 as recorded, up to 2 (louder, but it may distort) |
| **Pitch** (**Speed** for music) | Playback speed: 1 normal, 2 twice as fast and an octave higher, 0.5 half as fast and an octave lower. A little random pitch (from a script) keeps repeated sounds from sounding the same |
| **Pan** | -1 left, 0 the middle, 1 right |
| **Loop** | Plays again from the start when it ends, until stopped |
| **Autostart** | Starts by itself when the scene starts (and again each time the game comes back to the scene) |
| **Range**, **Falloff** | AudioPlayer2D only ([below](#sounds-in-the-world-audioplayer2d)) |
| **Fade in (s)**, **Fade out (s)** | MusicPlayer only: seconds it fades in when it starts, and out when it's stopped (0: no fade) |
| **Layers** | MusicPlayer only: more music playing in step with it ([Music layers](audio_effects_and_music.md#music-layers)) |

**Preview** plays the node's sound with its volume, pitch and pan, through its bus (so the
Mixer's fader, mute and effects for that bus change what you hear, and its meter moves). Press it
again (it reads **Stop** while playing) to stop.

The sliders are like everywhere in the editor: drag, type a value into the box beside one, hold
Shift for fine steps, and the reset button goes back to the default. Every change is an undo
step.

## Sounds in the world: AudioPlayer2D

An AudioPlayer2D is heard from a **listener**: the scene's camera (or the middle of the game area
when there's none). It's loudest at the listener, fades with distance and is panned toward the
side it's on.

| Setting | What it does |
|---|---|
| **Range** | Pixels from the listener where it can no longer be heard (1000 by default) |
| **Falloff** | How the volume falls with distance: 1 evenly all the way to the range; 2 and more drops quickly near the source, then trails off; below 1 stays loud longer, then drops near the range |

Selected, it shows its **Range** as a ring in the viewport.

## The Mixer: buses

A **bus** is a channel that sounds go through on their way out, with its own volume, pan and
mute. Put all the sound effects on an **SFX** bus and the music on a **Music** bus, and the game's
options menu can turn the music down without touching the effects. Every bus ends in **Master**,
the bus for the whole game.

What you hear from a sound is: its own volume × its bus's × Master's (and nothing when either bus
is muted).

**The Mixer tab** (in the bottom panel; Ctrl+J shows the panel) looks like a music program's
mixing desk: a **strip** per bus, with Master always on the far right. Buses that don't fit
scroll sideways (the wheel, or the bar under them).

1. Press **+** (beside Master) to add a bus. It's called **Bus** (then **Bus 2**...).
2. Click its name at the bottom of its strip and type a better one: **SFX**, **Music**, **Voices**.
3. Choose it as the **Bus** of your sound nodes.

Each strip, top to bottom:

| Part | What it does |
|---|---|
| Speaker and number | How many sound nodes use this bus (hover for more) |
| Bin | Removes the bus (not Master); its sound nodes go to Master |
| **FX** | The bus's effects, shown in the inspector ([Bus effects](audio_effects_and_music.md#bus-effects)) |
| Pan | Drag left or right: where the whole bus sits, left to right |
| Fader | The bus's volume, in decibels: the bottom is silence, 0 dB unchanged (it snaps there), +6 dB twice as loud |
| Meter | Beside the fader: how loud the bus is right now, left and right, with the peak held for a moment and a light that shows clipping (too loud) |
| dB | The fader's value |
| **M** | Mutes the bus (it turns orange); click again to hear it |
| Name | Its name; sounds using the bus follow a rename. A name must not be empty, start or end with a space, or be another bus's (ignoring case) |

On the fader and the pan: drag (Shift: ten times finer), **double-click** or **Ctrl+click** to
reset; once it has the focus, the arrow keys step it. Every change is an undo step.

The meters show what the **editor** plays: a node's Preview, through its bus, and the browser's
previews, through Master. A game started with Play runs separately, so its levels don't show
here.

## Sound in scripts

**A sound once**, from anywhere: `e.Game_PlaySound` plays a sound, loading it the first time.
Give it a `SoundAsset`: a field the inspector fills in, or a constant from
`scripts/assets.odin` (the editor writes one for each sound: `SOUND_LASER`). It plays on Master
unless you name a **bus**, and it can be quieter, higher or panned:

```odin
// Given: self: ^e.Script, SOUND_COIN: e.SoundAsset
// On the "SFX" bus, so the options' sound volume (that bus's) turns it down too
e.Game_PlaySound(self.game, SOUND_COIN, bus = "SFX")
// Quieter and a little lower (vary the pitch to keep repeats from sounding the same)
e.Game_PlaySound(self.game, SOUND_COIN, bus = "SFX", volume = 0.6, pitch = 0.9)
```

A sound played this way follows its bus while it plays: turn the bus down and it gets quieter.
Up to 32 play at once; another one cuts the oldest off.

```odin
Player :: struct {
	using script: e.Script,
	// A sound picked in the inspector
	jumpSound: e.SoundAsset `export:""`,
	// Sound nodes of the scene
	engine: ^e.AudioPlayer `export:"default=EngineSound"`,
	music: ^e.MusicPlayer `export:"default=../Music"`,
}

@(init)
register_Player :: proc "contextless" () {
	e.Script_Register(Player, {
		update = proc(self: ^Player, events: []sdl.Event, dt: f64) {
			if e.Input_IsActionJustPressed("ui_accept") do e.Game_PlaySound(self.game, self.jumpSound)
			if e.Input_IsKeyJustPressed(.Space) do e.Game_PlaySound(self.game, SOUND_LASER)
			// The engine sound gets higher with speed
			self.engine.settings.pitch = 1 + 0.5 * e.Input_GetAxis("ui_down", "ui_up")
		},
	})
}
```

**Sound nodes** are reached through a node field (drop the node from the scene tree onto the
code tab to add one), like `engine` and `music` above.

| Code | What it does |
|---|---|
| `e.Game_PlaySound(game, SOUND_X)` | Plays a sound once, on Master (a path works too: `"assets/hit.wav"`) |
| `e.Game_PlaySound(game, SOUND_X, bus = "SFX", volume = 0.5, pitch = 1.2, pan = -1)` | The same on a bus, at a volume, pitch and pan |
| `e.AudioPlayer_Play(player)` | Plays a node's sound from the start (again, if it was playing) |
| `e.AudioPlayer_Stop(player)` | Stops it (music fades out over its **Fade out**) |
| `e.AudioPlayer_Pause(player)`, `e.AudioPlayer_Resume(player)` | Pauses and carries on |
| `e.AudioPlayer_IsPlaying(player)` | Whether it's playing |
| `player.settings.volume`, `.pitch`, `.pan` | Its settings: change them any time, they apply the next frame |
| `player.settings.loop` | Whether it loops: read when it starts playing, so set it before `e.AudioPlayer_Play` (a sound already playing keeps looping or not) |
| `e.AudioPlayer_SetSound(player, "assets/slam.wav")`, `e.AudioPlayer_SetBus(player, "SFX")` | Another sound, another bus |
| `e.MusicPlayer_FadeOut(music, 3)` | Fades the music out over 3 seconds, then stops it |
| `e.MusicPlayer_Seek(music, 30)`, `e.MusicPlayer_GetPosition(music)`, `e.MusicPlayer_GetDuration(music)` | Jumps in the song; where it is; how long it is (seconds) |
| `e.Audio_SetBusVolume("Music", 0.5)`, `e.Audio_SetBusPan(...)`, `e.Audio_SetBusMute("SFX", true)` | A bus's fader, pan and mute (an options menu's sliders). `"Master"` for Master |
| `e.Audio_AddBus("Voices")` | A bus the project doesn't have |
| `left, right := e.Audio_GetBusLevel("Music")` | How loud a bus is right now (0 to 1) |

A sound node's **onFinished** event (in the inspector's **Events**, with **Listen...**) fires
when what it played ends by itself (not when it's stopped; a looping sound never ends).

When the game switches to another scene, that scene's players stop; ones with **Autostart** start
again when the game comes back.

## The sound device and output format

**Which device** (speakers, headphones, an HDMI screen) is a setting of your computer, not the
project: **Edit > Settings... > Editor > Audio device** (Ctrl+,). Play's game and the editor's
previews use it; **System default** follows your system. Exported games use the player's system
default (players can pick another with `--audio-device`).

**The output format** is the project's: **File > Project Settings... > General > Sound output**,
the rate (**48000 Hz**, **44100 Hz**) and channels (**Stereo**, **Mono**). Stereo at 48 kHz works
everywhere and is the default. **The device's own** asks for the device's native format instead,
which some outputs (multichannel interfaces, some Bluetooth and HDMI outputs) refuse. If a format
won't open, the game tries the others, then other devices, and writes in the Console what it got
(`Audio: <device>, 48000 Hz, 2 channels`).

With no sound device at all, games run silently, without errors.

In web exports, browsers only start sound after the player's first click or key press.

## How it's stored

Sound nodes are nodes of the scene file, with the settings that aren't the defaults:

```xml
<node kind="AudioPlayer2D" name="Waterfall" x="820" y="300" sound="assets/water.ogg" bus="SFX" volume="0.7" loop="true" autostart="true" maxDistance="600"/>
<node kind="MusicPlayer" name="Music" sound="assets/theme.ogg" bus="Music" loop="true" autostart="true" fadeIn="2"/>
```

Buses are `<bus>` elements in project.xml (Master only once it's changed), and a format other
than stereo 48 kHz is on its root (`audioFrequency`, `audioChannels`):

```xml
<bus name="SFX" volume="0.8"/>
<bus name="Music" volume="0.6" pan="0" mute="false"/>
```

## Questions

**I hear nothing.** Check the node has a **Sound**, its **Volume**, that its bus and Master aren't
muted or at the bottom, and **Autostart** (or a script that plays it). In the Console, look for the
`Audio:` line when the game starts: it says which device opened, or that none did.

**My sound is missing from the Sound list.** It's Music: right-click it > **Use as a Sound**. A
MusicPlayer only lists Music, the others only Sounds.

**The inspector says "No bus is called ...".** The bus was renamed or removed outside the editor:
pick another. It plays on Master meanwhile.

**My positional sound is silent.** It's further from the camera than its **Range**: raise it.

**Why don't the meters move while the game plays?** The game is a separate program; the meters
show the editor's own previews.
