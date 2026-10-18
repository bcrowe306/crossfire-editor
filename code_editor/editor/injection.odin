// Event injection hook: lets a host (or an automated test/demo script)
// push synthetic SDL events into the editor without a real display/input
// device. This is the mechanism requirement #8 asks for — it enables
// scripted end-to-end testing of typing, navigation, and hotkeys.
package code_editor

import sdl "vendor:sdl3"
import "core:strings"

// editor_inject_event queues a synthetic SDL event to be processed on the
// next `editor_pump_injected_events` (typically called once per frame from
// `editor_update`, before/instead of real `SDL_PollEvent` events).
editor_inject_event :: proc(ed: ^Editor, ev: sdl.Event) {
	append(&ed.injected_events, ev)
}

// editor_inject_key injects a synthetic key-down event for `key` with the
// given modifiers — a convenience wrapper over editor_inject_event for
// scripted hotkey tests/demos.
editor_inject_key :: proc(ed: ^Editor, key: sdl.Keycode, mod: sdl.Keymod = {}) {
	ev: sdl.Event
	ev.type = .KEY_DOWN
	ev.key.key = key
	ev.key.mod = mod
	ev.key.down = true
	editor_inject_event(ed, ev)
}

// editor_inject_text injects a synthetic text-input event carrying `text`
// — the usual path real typed characters arrive through from SDL. The
// underlying cstring is allocated here and freed once
// `editor_pump_injected_events` processes it.
editor_inject_text :: proc(ed: ^Editor, text: string) {
	ev: sdl.Event
	ev.type = .TEXT_INPUT
	ev.text.text = strings.clone_to_cstring(text)
	editor_inject_event(ed, ev)
}

// editor_pump_injected_events drains and processes every currently queued
// injected event, in FIFO order. Synthetic TEXT_INPUT events own a heap
// cstring (see editor_inject_text) which is freed here after dispatch.
editor_pump_injected_events :: proc(ed: ^Editor) {
	for ev in ed.injected_events {
		editor_handle_event(ed, ev)
		if ev.type == .TEXT_INPUT && ev.text.text != nil {
			delete(ev.text.text)
		}
	}
	clear(&ed.injected_events)
}
