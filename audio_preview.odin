package crossfire_editor

import "core:fmt"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"
import mix "vendor:sdl3/mixer"
import e "engine:."

/*
Audio playback for the browser's preview panel, through SDL3_mixer (the engine's audio library,
so whatever the game can play, the preview can play).

Holds SDL resources, so it lives here as package state rather than in `State`. The audio device
opens on first use; if there's no device, the preview reports it and stays silent.

It plays through a bus like the game (the engine's audio_meter.odin): the track carries the
sound's own gains and its bus's, a group meters it (the bus's level), and Master's gains go on
the final mix, which a second meter reads. The Mixer tab shows both and changes them as it's
edited (`AudioPreview_SetRouting`). The browser's previews go to Master.
*/

@(private="file")
AudioPreview :: struct {
	failed: bool,
	mixer: ^mix.Mixer,
	track: ^mix.Track,
	audio: ^mix.Audio,
	// File the loaded audio came from
	path: string,
	durationMS: i64,
	// The sound's own volume and pan, and the bus it plays on ("" = Master; owned)
	volume, pan: f32,
	bus: string,
	busGain, busLeft, busRight: f32,
	group: ^mix.Group,
	busMeter, masterMeter: e.AudioMeter,
}

@(private="file")
preview: AudioPreview

/*
Loads a sound for previewing, replacing the previous one (and stopping it).

Inputs:
- path: Audio file path

Returns:
- An error message, "" on success (temp allocated)
*/
AudioPreview_Load :: proc(path: string) -> string {
	if preview.path == path && preview.audio != nil do return ""
	AudioPreview_Unload()
	if !ensureMixer() do return "No audio device available"

	preview.audio = mix.LoadAudio(preview.mixer, strings.clone_to_cstring(path, context.temp_allocator), true)
	if preview.audio == nil {
		return fmt.tprintf("Couldn't load %s: %s", path, sdl.GetError())
	}
	preview.path = strings.clone(path)
	preview.durationMS = i64(mix.AudioFramesToMS(preview.audio, mix.GetAudioDuration(preview.audio)))
	AudioPreview_SetSettings(1, 1, 0)
	AudioPreview_SetRouting("", 1, 1, 1, 1, 1, 1)
	return ""
}

// Stops playback and frees the loaded sound
AudioPreview_Unload :: proc() {
	if preview.track != nil do _ = mix.StopTrack(preview.track, 0)
	if preview.audio != nil do mix.DestroyAudio(preview.audio)
	preview.audio = nil
	delete(preview.path)
	preview.path = ""
	preview.durationMS = 0
}

// Plays the loaded sound from the start
AudioPreview_Play :: proc() {
	if preview.audio == nil || preview.track == nil do return
	_ = mix.SetTrackAudio(preview.track, preview.audio)
	if !mix.PlayTrack(preview.track, 0) {
		log.warnf("Audio preview: couldn't play: %s", sdl.GetError())
	}
}

/*
How the preview sounds: a sound node's volume, pitch (speed) and pan (balance), so its
inspector's Preview plays it as the game will (its bus isn't applied). Loading a sound resets it.
*/
AudioPreview_SetSettings :: proc(volume, pitch, pan: f32) {
	preview.volume, preview.pan = max(volume, 0), clamp(pan, -1, 1)
	if preview.track == nil do return
	_ = mix.SetTrackFrequencyRatio(preview.track, clamp(pitch, 0.01, 100))
	applyTrackOutput()
}

/*
Where the preview plays: its bus ("" = Master) with that bus's gain and stereo gains (from its
volume, pan and mute), and Master's, which go on the final mix.
*/
AudioPreview_SetRouting :: proc(bus: string, busGain, busLeft, busRight, masterGain, masterLeft, masterRight: f32) {
	if preview.bus != bus {
		delete(preview.bus)
		preview.bus = strings.clone(bus)
	}
	preview.busGain, preview.busLeft, preview.busRight = busGain, busLeft, busRight
	e.AudioMeter_SetGains(&preview.masterMeter, masterGain * masterLeft, masterGain * masterRight)
	applyTrackOutput()
}

// The bus the preview plays on ("" = Master)
AudioPreview_Bus :: proc() -> string {
	return preview.bus
}

// The levels since the last call: the bus's (after its fader) and the final mix's (0 to 1)
AudioPreview_Levels :: proc() -> (bus, master: [2]f32) {
	bus.x, bus.y = e.AudioMeter_Read(&preview.busMeter)
	master.x, master.y = e.AudioMeter_Read(&preview.masterMeter)
	return
}

@(private="file")
applyTrackOutput :: proc() {
	if preview.track == nil do return
	_ = mix.SetTrackGain(preview.track, preview.volume * preview.busGain)
	p := preview.pan
	gains := mix.StereoGains{min(1, 1 - p) * preview.busLeft, min(1, 1 + p) * preview.busRight}
	_ = mix.SetTrackStereo(preview.track, &gains)
}

AudioPreview_Stop :: proc() {
	if preview.track != nil do _ = mix.StopTrack(preview.track, 0)
}

AudioPreview_IsPlaying :: proc() -> bool {
	return preview.track != nil && preview.audio != nil && bool(mix.TrackPlaying(preview.track))
}

// Whether `path` is the loaded sound
AudioPreview_IsLoaded :: proc(path: string) -> bool {
	return preview.audio != nil && preview.path == path
}

// Playback position and length, in milliseconds
AudioPreview_Progress :: proc() -> (positionMS, durationMS: i64) {
	if preview.track != nil && AudioPreview_IsPlaying() {
		positionMS = i64(mix.TrackFramesToMS(preview.track, mix.GetTrackPlaybackPosition(preview.track)))
	}
	return positionMS, preview.durationMS
}

// "1:03.4"
FormatDuration :: proc(ms: i64) -> string {
	seconds := f64(ms) / 1000
	minutes := int(seconds / 60)
	return fmt.tprintf("%d:%04.1f", minutes, seconds - f64(minutes) * 60)
}

@(private="file")
ensureMixer :: proc() -> bool {
	if preview.mixer != nil do return true
	if preview.failed do return false
	if !sdl.InitSubSystem({.AUDIO}) || !mix.Init() {
		log.warnf("Audio preview unavailable: %s", sdl.GetError())
		preview.failed = true
		return false
	}
	preview.mixer = mix.CreateMixerDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
	if preview.mixer != nil do preview.track = mix.CreateTrack(preview.mixer)
	if preview.mixer == nil || preview.track == nil {
		log.warnf("Audio preview unavailable: %s", sdl.GetError())
		preview.failed = true
		return false
	}
	preview.group = mix.CreateGroup(preview.mixer)
	_ = mix.SetTrackGroup(preview.track, preview.group)
	e.AudioMeter_AttachGroup(&preview.busMeter, preview.group)
	e.AudioMeter_AttachMixer(&preview.masterMeter, preview.mixer)
	return true
}
