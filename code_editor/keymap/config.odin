// Keymap text forms and persistence:
//   - chords as text: "cmd+shift+p" (VSCode style) or "cmd-shift-p" (Zed
//     style) — both parse; chord_format writes the "+" form;
//   - actions by name ("SelectNextOccurrence");
//   - the user's remapping saved as a small JSON diff against the platform
//     defaults ({"bind": {"cmd+d": "SelectWord"}, "unbind": ["f12"]}), so
//     future default changes still reach users who customised a few keys.
package keymap

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

// key_from_name maps a key token ("p", "f12", "enter", "/", "minus").
key_from_name :: proc(name: string) -> (Key, bool) {
	n := strings.to_lower(name, context.temp_allocator)
	if len(n) == 1 {
		c := n[0]
		switch {
		case c >= 'a' && c <= 'z': return Key(int(Key.A) + int(c - 'a')), true
		case c >= '0' && c <= '9': return Key(int(Key.Num0) + int(c - '0')), true
		}
		switch c {
		case '/': return .Slash, true
		case '\\': return .Backslash, true
		case '-': return .Minus, true
		case '=': return .Equals, true
		case '[': return .LeftBracket, true
		case ']': return .RightBracket, true
		case ';': return .Semicolon, true
		case '\'': return .Quote, true
		case ',': return .Comma, true
		case '.': return .Period, true
		case '`': return .Grave, true
		}
		return .Unknown, false
	}
	switch n {
	case "left": return .Left, true
	case "right": return .Right, true
	case "up": return .Up, true
	case "down": return .Down, true
	case "home": return .Home, true
	case "end": return .End, true
	case "pageup": return .PageUp, true
	case "pagedown": return .PageDown, true
	case "backspace": return .Backspace, true
	case "delete": return .Delete, true
	case "enter", "return": return .Enter, true
	case "tab": return .Tab, true
	case "escape", "esc": return .Escape, true
	case "space": return .Space, true
	case "slash": return .Slash, true
	case "backslash": return .Backslash, true
	case "minus": return .Minus, true
	case "equal", "equals": return .Equals, true
	case "bracketleft": return .LeftBracket, true
	case "bracketright": return .RightBracket, true
	case "semicolon": return .Semicolon, true
	case "quote": return .Quote, true
	case "comma": return .Comma, true
	case "period": return .Period, true
	case "backquote": return .Grave, true
	case "f1": return .F1, true
	case "f3": return .F3, true
	case "f4": return .F4, true
	case "f8": return .F8, true
	case "f12": return .F12, true
	}
	return .Unknown, false
}

// key_name is the text form of a key ("p", "f12", "enter", "/").
key_name :: proc(k: Key) -> string {
	#partial switch k {
	case .A ..= .Z:
		b := []u8{u8('a' + int(k) - int(Key.A))}
		return strings.clone(string(b), context.temp_allocator)
	case .Num0 ..= .Num9:
		b := []u8{u8('0' + int(k) - int(Key.Num0))}
		return strings.clone(string(b), context.temp_allocator)
	case .Slash: return "/"
	case .Backslash: return "\\"
	case .Minus: return "-"
	case .Equals: return "="
	case .LeftBracket: return "["
	case .RightBracket: return "]"
	case .Semicolon: return ";"
	case .Quote: return "'"
	case .Comma: return ","
	case .Period: return "."
	case .Grave: return "`"
	}
	return strings.to_lower(fmt.tprint(k), context.temp_allocator)
}

// chord_parse reads "cmd+shift+p" / "cmd-shift-p" / "ctrl+-" / "ctrl--".
// Multi-key sequences ("cmd+k cmd+s") are not chords: ok = false.
chord_parse :: proc(text: string) -> (chord: Chord, ok: bool) {
	s := strings.trim_space(text)
	if len(s) == 0 || strings.index_byte(s, ' ') >= 0 {
		return
	}
	// Split on '+'/'-' separators; a trailing doubled separator is the
	// key itself ("ctrl+-", "cmd--", "shift++").
	parts := make([dynamic]string, context.temp_allocator)
	start := 0
	for i := 0; i < len(s); i += 1 {
		if (s[i] == '+' || s[i] == '-') && i > start {
			append(&parts, s[start:i])
			start = i + 1
		}
	}
	if start < len(s) {
		append(&parts, s[start:])
	} else if start == len(s) && len(s) > 0 {
		append(&parts, s[len(s) - 1:])
	}
	if len(parts) == 0 {
		return
	}
	for m in parts[:len(parts) - 1] {
		switch strings.to_lower(m, context.temp_allocator) {
		case "cmd", "command", "super", "win", "meta": chord.mods += {.Super}
		case "ctrl", "control": chord.mods += {.Ctrl}
		case "alt", "option", "opt": chord.mods += {.Alt}
		case "shift": chord.mods += {.Shift}
		case: return {}, false
		}
	}
	chord.key, ok = key_from_name(parts[len(parts) - 1])
	return
}

// chord_format writes a chord as "ctrl+cmd+alt+shift+key".
chord_format :: proc(c: Chord, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	if .Ctrl in c.mods {strings.write_string(&sb, "ctrl+")}
	if .Super in c.mods {strings.write_string(&sb, "cmd+")}
	if .Alt in c.mods {strings.write_string(&sb, "alt+")}
	if .Shift in c.mods {strings.write_string(&sb, "shift+")}
	strings.write_string(&sb, key_name(c.key))
	return strings.to_string(sb)
}

action_name :: proc(a: Action) -> string {
	return fmt.tprint(a)
}

action_from_name :: proc(name: string) -> (Action, bool) {
	for a in Action {
		if strings.equal_fold(fmt.tprint(a), name) {
			return a, true
		}
	}
	return .None, false
}

// keymap_chords_for lists the chords bound to `action`, sorted.
keymap_chords_for :: proc(km: ^Keymap, action: Action) -> []Chord {
	out := make([dynamic]Chord, context.temp_allocator)
	for c, a in km.bindings {
		if a == action {
			append(&out, c)
		}
	}
	slice.sort_by(out[:], proc(x, y: Chord) -> bool {
		if card(x.mods) != card(y.mods) {
			return card(x.mods) < card(y.mods)
		}
		return x.key < y.key
	})
	return out[:]
}

// keymap_overrides_json serialises how `km` differs from `defaults`.
keymap_overrides_json :: proc(km, defaults: ^Keymap, allocator := context.allocator) -> string {
	bind := make([dynamic]string, context.temp_allocator)
	unbind := make([dynamic]string, context.temp_allocator)
	for c, a in km.bindings {
		if d, ok := defaults.bindings[c]; !ok || d != a {
			append(&bind, fmt.tprintf("    %q: %q", chord_format(c), action_name(a)))
		}
	}
	for c, _ in defaults.bindings {
		if _, ok := km.bindings[c]; !ok {
			append(&unbind, fmt.tprintf("%q", chord_format(c)))
		}
	}
	slice.sort(bind[:])
	slice.sort(unbind[:])
	return fmt.aprintf("{{\n  \"bind\": {{\n%s\n  }},\n  \"unbind\": [%s]\n}}\n",
		strings.join(bind[:], ",\n", context.temp_allocator),
		strings.join(unbind[:], ", ", context.temp_allocator), allocator = allocator)
}

// keymap_apply_overrides applies a saved diff (bind wins over unbind).
keymap_apply_overrides :: proc(km: ^Keymap, text: string) -> bool {
	v, err := json.parse_string(text, json.Specification.JSON5, allocator = context.temp_allocator)
	if err != nil {
		return false
	}
	obj, ok := v.(json.Object)
	if !ok {
		return false
	}
	if arr, is_arr := obj["unbind"].(json.Array); is_arr {
		for e in arr {
			if s, is_str := e.(json.String); is_str {
				if c, ok2 := chord_parse(s); ok2 {
					keymap_unbind(km, c)
				}
			}
		}
	}
	if b, is_obj := obj["bind"].(json.Object); is_obj {
		for key, val in b {
			name, _ := val.(json.String)
			c, ok_c := chord_parse(key)
			a, ok_a := action_from_name(name)
			if ok_c && ok_a {
				keymap_bind(km, c, a)
			}
		}
	}
	return true
}
