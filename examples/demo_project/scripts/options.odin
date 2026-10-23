package scripts

import "core:fmt"
import "core:strings"
import e "engine:."
import sdl "vendor:sdl3"

/*
Options: OptionsScene, pushed over the title or the pause menu (`push:OptionsScene`; Back pops it).
Everything is saved and applied at once:

- **Music** and **Sounds**: Sliders setting the Music and SFX mix buses' volumes
  (`e.Audio_SetBusVolume`; every sound effect plays on SFX: `Sfx`). A tick plays as the sound
  slider moves, at its new volume.
- **Fullscreen**: a CheckBox (`e.Game_SetFullscreen`).
- **Controls**: for each of the game's actions, a button showing its keyboard binding and one its
  gamepad binding. Press one, then the key or button you want: the engine captures the next input
  (`e.Input_StartCapture` / `e.Input_GetCapturedBinding`, which stops it from also acting),
  the action's bindings of that kind are replaced (`e.Input_SetBindings`), an action that used it
  gets yours in exchange, and the bindings are saved (`e.Input_SaveBindings`; GameState loads them
  when the game starts). Escape cancels. **Reset** puts the project's bindings back
  (`e.Input_ResetBindings`).

The options themselves (volumes, fullscreen) are GameState's fields, saved with `e.Save_Game()`.
*/
Options :: struct {
	using script: e.Script,
	music: ^e.Slider `export:"default=../Panel/Music/Slider"`,
	sounds: ^e.Slider `export:"default=../Panel/Sounds/Slider"`,
	fullscreen: ^e.CheckBox `export:"default=../Panel/Fullscreen"`,
	controls: ^e.Node `export:"default=../Panel/Controls"`,
	back: ^e.Button `export:"default=../Panel/Buttons/Back"`,
	hint: ^e.RichText `export:"default=../Panel/Hint"`,
	slots: [len(REBINDABLE) * 2]RebindSlot,
	// The slot waiting for an input (-1: none)
	capturing: int,
	// Seconds since the sound slider last ticked
	tick: f32,
}

// The actions players can rebind, as the options list them
REBINDABLE :: [?][2]string{
	{ACTION_LEFT, "Left"},
	{ACTION_RIGHT, "Right"},
	{ACTION_DOWN, "Down / drop"},
	{ACTION_JUMP, "Jump"},
	{ACTION_ATTACK, "Attack"},
	{ACTION_INTERACT, "Read"},
	{ACTION_PAUSE, "Pause"},
}

// A rebinding button: which action, and which kind of binding it shows
RebindSlot :: struct {
	options: ^Options,
	action: string,
	pad: bool,
	button: ^e.Button,
}

// Whether a binding is a gamepad's (else the keyboard's or mouse's)
@(private="file")
isPad :: proc(b: e.InputBinding) -> bool {
	#partial switch _ in b {
	case e.GamepadButtonBinding, e.GamepadAxisBinding: return true
	}
	return false
}

// A slot's text: its bindings of its kind
@(private="file")
slotText :: proc(slot: ^RebindSlot) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for b in e.Input_GetBindings(slot.action) do if isPad(b) == slot.pad {
		// "Gamepad South" is "South" in the gamepad column
		append(&names, strings.trim_prefix(e.InputBinding_Describe(b), "Gamepad "))
	}
	if len(names) == 0 do return "-"
	// The keyboard's first two ("A, Left"); a gamepad's first (its stick's names are long)
	if len(names) > 1 && !slot.pad do return fmt.tprintf("%s, %s", names[0], names[1])
	return names[0]
}

@(private="file")
refresh :: proc(self: ^Options) {
	for &slot, i in self.slots {
		if slot.button == nil do continue
		e.Control_SetText(slot.button, i == self.capturing ? "Press..." : slotText(&slot))
	}
	if self.hint != nil {
		e.Control_SetText(self.hint, self.capturing >= 0 ? "[color=#ffe08a]Press a key or a gamepad button (Escape cancels)[/color]" : "Choose a control to change it")
	}
}

@(private="file")
pressed :: proc(_: ^e.EventSubject, _: rawptr, _: e.EventData, user: rawptr) {
	slot := cast(^RebindSlot)user
	self := slot.options
	if self.capturing >= 0 do return
	for &s, i in self.slots do if &s == slot do self.capturing = i
	e.Input_StartCapture()
	refresh(self)
}

// The captured input becomes the slot's binding; an action that had it gets the slot's old one
@(private="file")
rebind :: proc(self: ^Options, slot: ^RebindSlot, binding: e.InputBinding) {
	old: e.InputBinding
	kept := make([dynamic]e.InputBinding, context.temp_allocator)
	for b in e.Input_GetBindings(slot.action) {
		if isPad(b) == slot.pad {
			if old == nil do old = b
		} else {
			append(&kept, b)
		}
	}
	// Taken from another of the game's actions (not the menus' ui_* ones): they swap
	for other in e.Input_ActionsUsing(binding) {
		if other == slot.action || len(other) > 3 && other[:3] == "ui_" do continue
		rest := make([dynamic]e.InputBinding, context.temp_allocator)
		for b in e.Input_GetBindings(other) do if b != binding do append(&rest, b)
		if old != nil do append(&rest, old)
		e.Input_SetBindings(other, rest[:])
	}
	append(&kept, binding)
	e.Input_SetBindings(slot.action, kept[:])
	e.Input_SaveBindings()
}

@(private="file")
musicChanged :: proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, user: rawptr) {
	state := State()
	value, _ := data.(f32)
	if state == nil do return
	state.musicVolume = value
	GameState_ApplySettings(state)
}

@(private="file")
soundsChanged :: proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, user: rawptr) {
	self := cast(^Options)user
	state := State()
	value, _ := data.(f32)
	if state == nil do return
	state.sfxVolume = value
	GameState_ApplySettings(state)
	if self.tick > 0.08 {
		self.tick = 0
		Sfx(self.game, SOUND_COIN, 0.6)
	}
}

@(private="file")
fullscreenToggled :: proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, user: rawptr) {
	state := State()
	value, _ := data.(bool)
	if state == nil do return
	state.fullscreen = value
	GameState_ApplySettings(state)
}

// Leaves the options (Back, or Escape): saved, and the screen under them comes back
Options_Close :: proc(self: ^Options) {
	if self.capturing >= 0 do e.Input_CancelCapture()
	e.Save_Game()
	// A soft chime: the options are kept
	Sfx(self.game, SOUND_SAVED, 0.6)
	if e.Game_TopScene(self.game) == self.scene do e.Game_PopScene(self.game)
	else do e.Game_ChangeScene(self.game, SCENE_TITLE_SCENE)
}

Options_onBack :: proc(self: ^Options, source: ^e.Node, data: e.EventData) {
	Options_Close(self)
}

// Reset: the project's own bindings again (and saved so)
Options_onReset :: proc(self: ^Options, source: ^e.Node, data: e.EventData) {
	e.Input_ResetBindings()
	e.Input_SaveBindings()
	refresh(self)
}

@(init)
register_Options_listeners :: proc "contextless" () {
	e.Script_Listener(Options, "onBack", Options_onBack)
	e.Script_Listener(Options, "onReset", Options_onReset)
}

@(init)
register_Options :: proc "contextless" () {
	e.Script_Register(Options, {
		ready = proc(self: ^Options) {
			self.capturing = -1
			state := State()
			if state != nil {
				if self.music != nil do e.Slider_SetValue(self.music, state.musicVolume)
				if self.sounds != nil do e.Slider_SetValue(self.sounds, state.sfxVolume)
				if self.fullscreen != nil do e.CheckBox_SetChecked(self.fullscreen, e.Game_IsFullscreen(self.game))
			}
			if self.music != nil do e.Event_Subscribe(&self.music.onValueChanged, musicChanged, self)
			if self.sounds != nil do e.Event_Subscribe(&self.sounds.onValueChanged, soundsChanged, self)
			if self.fullscreen != nil do e.Event_Subscribe(&self.fullscreen.onToggled, fullscreenToggled, self)
			// The controls' rows: "<Action>/Key" and "<Action>/Pad" buttons under Controls
			actions := REBINDABLE
			for a, i in actions {
				for pad in ([2]bool{false, true}) {
					slot := &self.slots[i * 2 + (pad ? 1 : 0)]
					slot.options, slot.action, slot.pad = self, a[0], pad
					if self.controls == nil do continue
					node := e.Node_FindChild(self.controls, fmt.tprintf("%s/%s", a[1] == "Down / drop" ? "Down" : a[1], pad ? "Pad" : "Key"))
					if node != nil && e.Node_Is(node, e.Button) {
						slot.button = cast(^e.Button)node
						e.Event_Subscribe(&slot.button.onPressed, pressed, slot)
					}
				}
			}
			if self.music != nil do e.Control_Focus(self.scene, self.music)
			refresh(self)
		},
		update = proc(self: ^Options, _: []sdl.Event, dt: f64) {
			self.tick += f32(dt)
			if self.capturing >= 0 {
				binding, ok := e.Input_GetCapturedBinding()
				if !ok do return
				slot := &self.slots[self.capturing]
				if binding == e.InputBinding(e.KeyBinding{.Escape}) {
					self.capturing = -1
				} else if isPad(binding) != slot.pad {
					// The keyboard's button got a gamepad's press (or the other way): keep waiting
					e.Input_StartCapture()
					return
				} else {
					rebind(self, slot, binding)
					self.capturing = -1
					Sfx(self.game, SOUND_UI_SELECT)
				}
				refresh(self)
				return
			}
			if e.Game_TopScene(self.game) == self.scene && e.Input_IsActionJustPressed(ACTION_UI_CANCEL) do Options_Close(self)
		},
	})
}
