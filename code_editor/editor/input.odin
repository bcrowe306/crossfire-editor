// Translates SDL3 keyboard input into the platform-agnostic `keymap.Chord`
// type. Pure data mapping — no SDL subsystems need to be initialized to
// exercise this code, so it's fully unit testable.
package code_editor

import km "../keymap"
import sdl "vendor:sdl3"

sdl_keycode_to_key :: proc(code: sdl.Keycode) -> km.Key {
	switch code {
	case sdl.K_A: return .A
	case sdl.K_B: return .B
	case sdl.K_C: return .C
	case sdl.K_D: return .D
	case sdl.K_E: return .E
	case sdl.K_F: return .F
	case sdl.K_G: return .G
	case sdl.K_H: return .H
	case sdl.K_I: return .I
	case sdl.K_J: return .J
	case sdl.K_K: return .K
	case sdl.K_L: return .L
	case sdl.K_M: return .M
	case sdl.K_N: return .N
	case sdl.K_O: return .O
	case sdl.K_P: return .P
	case sdl.K_Q: return .Q
	case sdl.K_R: return .R
	case sdl.K_S: return .S
	case sdl.K_T: return .T
	case sdl.K_U: return .U
	case sdl.K_V: return .V
	case sdl.K_W: return .W
	case sdl.K_X: return .X
	case sdl.K_Y: return .Y
	case sdl.K_Z: return .Z
	case sdl.K_0: return .Num0
	case sdl.K_1: return .Num1
	case sdl.K_2: return .Num2
	case sdl.K_3: return .Num3
	case sdl.K_4: return .Num4
	case sdl.K_5: return .Num5
	case sdl.K_6: return .Num6
	case sdl.K_7: return .Num7
	case sdl.K_8: return .Num8
	case sdl.K_9: return .Num9
	case sdl.K_LEFT: return .Left
	case sdl.K_RIGHT: return .Right
	case sdl.K_UP: return .Up
	case sdl.K_DOWN: return .Down
	case sdl.K_HOME: return .Home
	case sdl.K_END: return .End
	case sdl.K_PAGEUP: return .PageUp
	case sdl.K_PAGEDOWN: return .PageDown
	case sdl.K_BACKSPACE: return .Backspace
	case sdl.K_DELETE: return .Delete
	case sdl.K_RETURN: return .Enter
	case sdl.K_KP_ENTER: return .Enter
	case sdl.K_TAB: return .Tab
	case sdl.K_ESCAPE: return .Escape
	case sdl.K_SPACE: return .Space
	case sdl.K_SLASH: return .Slash
	case sdl.K_BACKSLASH: return .Backslash
	case sdl.K_MINUS, sdl.K_KP_MINUS: return .Minus
	case sdl.K_EQUALS, sdl.K_PLUS, sdl.K_KP_PLUS: return .Equals
	case sdl.K_LEFTBRACKET: return .LeftBracket
	case sdl.K_RIGHTBRACKET: return .RightBracket
	case sdl.K_SEMICOLON: return .Semicolon
	case sdl.K_APOSTROPHE: return .Quote
	case sdl.K_COMMA: return .Comma
	case sdl.K_PERIOD: return .Period
	case sdl.K_GRAVE: return .Grave
	case sdl.K_F8: return .F8
	case sdl.K_F3: return .F3
	case sdl.K_F1: return .F1
	case sdl.K_F12: return .F12
	case sdl.K_F4: return .F4
	}
	return .Unknown
}

sdl_mod_to_keymap_mods :: proc(mod: sdl.Keymod) -> km.Modifiers {
	mods: km.Modifiers
	if .LSHIFT in mod || .RSHIFT in mod {
		mods |= {.Shift}
	}
	if .LCTRL in mod || .RCTRL in mod {
		mods |= {.Ctrl}
	}
	if .LALT in mod || .RALT in mod {
		mods |= {.Alt}
	}
	if .LGUI in mod || .RGUI in mod {
		mods |= {.Super}
	}
	return mods
}

sdl_event_to_chord :: proc(key: sdl.KeyboardEvent) -> km.Chord {
	return km.Chord{
		key  = sdl_keycode_to_key(key.key),
		mods = sdl_mod_to_keymap_mods(key.mod),
	}
}
