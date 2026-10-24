---
title: Bus effects, crossfades and music layers
description: Put filters, echo and reverb on mix buses, fade from one song to another, and build music from layers that come and go with the game.
order: 15
---

# Bus effects, crossfades and music layers

Every sound in a game plays on a **bus**: a channel of the **Mixer** (the bottom panel's Mixer
tab) with its own volume, pan and mute. **Master** is the bus everything ends up on; you add
others (SFX, Music, Voices) and choose one for each sound node in its inspector.

This page covers three things built on top of buses and music:

- **Bus effects**: a low-pass or high-pass filter, an echo or a reverb on a bus, so everything on
  it sounds muffled (underwater, behind a wall), in a cave, or far away. Master's effects change
  the whole game.
- **Crossfades**: one song fading out while the next fades in.
- **Music layers**: extra music files that play in step with a song (drums, strings, a danger
  theme), each faded in or out by your scripts as the game changes.

- [Bus effects](#bus-effects)
- [The effects](#the-effects)
- [Music layers](#music-layers)
- [Crossfades](#crossfades)
- [In scripts](#in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Bus effects

1. Open the **Mixer** tab in the bottom panel (or a sound node's **Open Mixer** button).
2. Each bus's strip has an **FX** button above its name. Press it: the inspector shows that bus's
   effects (the button shows how many it has: **FX 2**).
3. Under **Add effect**, choose **Low-pass filter**, **High-pass filter**, **Echo** or
   **Reverb**. It's added at the end of the bus's effects with its default settings.
4. Change its settings with the sliders (type a value into the box beside a slider, or press its
   reset button for the default).

Effects run **in order**, top to bottom, on everything mixed on the bus: a low-pass then a
reverb muffles the sound and then puts it in a room, which isn't the same as a reverb then a
low-pass (a muffled room). The arrows beside an effect's name move it up or down; the bin
removes it. A bus takes up to 8 effects.

**Bypass** skips an effect but keeps it in the chain with its settings, so you can compare the
bus with and without it.

**Hearing them in the editor:** a sound node's **Preview** button (in its inspector) plays the
sound through its bus and Master, with their effects, so you hear a change as you make it. The
bus's level meter in the Mixer moves while it plays. The browser's preview (selecting a sound
file) plays on Master.

Every change is an undo step (Ctrl+Z); a slider's drag is one step.

## The effects

| Effect | Setting | What it does |
|---|---|---|
| **Low-pass filter** | **Cutoff Hz** | Lets through what's below this frequency: 20000 changes nothing, 1000 (the default) is muffled, 300 is behind a wall |
| | **Resonance** | How much the filter rings at its cutoff: 0.707 is flat, higher makes a peak there |
| **High-pass filter** | **Cutoff Hz** | Lets through what's above this frequency: 300 sounds thin, like a radio or a phone |
| | **Resonance** | As above |
| **Echo** | **Delay s** | Seconds between repeats (up to 2) |
| | **Feedback** | How loud each repeat is compared with the one before (0: a single repeat; at most 0.95) |
| | **Wet mix** | How much of the echo you hear: 0 none, 1 only the echo |
| **Reverb** | **Room size** | 0 a small room, 1 a large hall (a longer tail) |
| | **Damp highs** | How dull the reflections are: 0 bright (tiles, stone), 1 dull (curtains, a forest) |
| | **Wet mix** | How much of the reverb you hear |

Hover a setting's name in the inspector to see this explanation there.

Some uses:
- **Underwater or behind a door**: a low-pass at 400 to 800 Hz on the SFX bus, switched on from a
  script when the player dives (see [In scripts](#in-scripts)).
- **A cave level**: a reverb with a large room on the SFX bus, a little echo on voices.
- **A pause menu**: a low-pass on the Music bus while the menu is open.

## Music layers

A **MusicPlayer** node streams one music file. Layers add more files that play **in step** with
it: they start on the same sample, loop with it, and go through the player's volume, pan and bus.
Make them as stems of one song (the same length and tempo, exported from your music program), so
they loop together.

1. Select the MusicPlayer and choose its **Music** (import a sound, then right-click it in the
   browser > **Use as Music (streamed)**).
2. Under **Layers**, press **Add Layer**.
3. Give it a **Layer name** (scripts fade it by that name: `drums`, `strings`, `danger`).
4. Choose its **Layer music**.
5. Set its **Layer volume**: what it starts at. **0** means silent until a script fades it in,
   which is the usual way: the song starts with its base and layers come in as the game gets
   tense.

The bin beside a layer removes it. Layers play in the game (Play): the inspector's Preview plays
the main music only.

## Crossfades

A crossfade is done from a script: the song playing fades out while the next one fades in, over
the seconds you give. The old song keeps playing until its fade ends. Its layers fade out with it;
add the new song's layers after the crossfade if it has some.

```odin
// Given: music: ^e.MusicPlayer
e.MusicPlayer_CrossfadeTo(music, "assets/boss_theme.ogg", 3)
```

When the player isn't playing, it just starts the new song, fading in.

## In scripts

Scripts reach a MusicPlayer through a node field (drop the node onto the code tab) and buses by
name.

```odin
Level :: struct {
	using script: e.Script,
	music: ^e.MusicPlayer `export:"default=../Music"`,
}

// A fight starts: the drums come in over two seconds
Level_fightStarted :: proc(self: ^Level) {
	e.MusicPlayer_SetLayerVolume(self.music, "drums", 1, seconds = 2)
}

// The boss: a new song
Level_bossAppears :: proc(self: ^Level) {
	e.MusicPlayer_CrossfadeTo(self.music, "assets/boss.ogg", 3)
}

// Diving: everything on SFX muffled; surfacing: back to what the project set
Level_dive :: proc(self: ^Level, under: bool) {
	if under {
		e.Audio_SetBusEffects("SFX", {e.AudioEffect_Make(.LowPass)})
	} else {
		e.Audio_SetBusEffects("SFX", {})
	}
}
```

| Procedure | What it does |
|---|---|
| `e.MusicPlayer_AddLayer(music, name, path, volume)` | Adds a layer (joins in step if the music is playing) |
| `e.MusicPlayer_RemoveLayer(music, name)` | Removes a layer |
| `e.MusicPlayer_SetLayerVolume(music, name, volume, seconds)` | Fades a layer to a volume (0 silent, 1 full) over `seconds` (0: at once) |
| `e.MusicPlayer_GetLayer(music, name)` | A layer (its `volume`, `target`) or nil |
| `e.MusicPlayer_CrossfadeTo(music, path, seconds)` | Fades to another song |
| `e.Audio_SetBusEffects(bus, effects)` | Replaces a bus's effects (`"Master"` for Master) |
| `e.Audio_SetBusEffect(bus, index, effect)` | Changes one effect's settings (keeps its echo or reverb tail going) |
| `e.Audio_GetBusEffects(bus)` | A copy of a bus's effects |
| `e.AudioEffect_Make(kind)` | An effect (`.LowPass`, `.HighPass`, `.Echo`, `.Reverb`) with the default settings |

To change one setting from code, read the effects, change it and set it back:

```odin
effects := e.Audio_GetBusEffects("SFX")
if len(effects) > 0 {
	fx := effects[0]
	fx.cutoff = 500
	e.Audio_SetBusEffect("SFX", 0, fx)
}
```

## How it's stored

A bus's effects are `<effect>` elements under its `<bus>` in `project.xml`, with only the
settings that differ from the defaults (Master is written once it has effects):

```xml
<bus name="SFX" volume="0.8">
	<effect kind="LowPass" cutoff="600"/>
	<effect kind="Reverb" roomSize="0.8" mix="0.4"/>
</bus>
```

A MusicPlayer's layers are `<layer>` elements in its scene file:

```xml
<node name="Music" kind="MusicPlayer" sound="assets/base.ogg" loop="true" autostart="true">
	<layer name="drums" sound="assets/drums.ogg" volume="0"/>
</node>
```

## Questions

**I added a reverb and hear nothing different.** Check the sound node is on that bus (its **Bus**
in the inspector) and that the bus isn't muted; a **Wet mix** of 0 or **Bypass** on also leaves
the sound dry. Press the node's **Preview** to hear it through the bus.

**The layers drift apart.** They don't drift (they share one clock), but files of different
lengths loop at different times. Export every stem at the same length.

**Can a sound skip the bus's effects?** Put it on another bus. Effects apply to everything on a
bus.

**Do effects work in web exports?** They're the engine's own code, run in SDL_mixer's mix on
every platform, the browser's included; they've been tested on the desktop, not yet in a
browser.
