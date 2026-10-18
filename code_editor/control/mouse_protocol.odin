// Mouse command parsing: where-specs and key=value options shared by
// click / mousedown / mouseup / move / drag / wheel / locate.
//
// A <where> is either two numbers (window pixels) or one @-token that is
// resolved against the live editor when the command runs, so scripts don't
// depend on font metrics or scroll position:
//   @3:5            caret position line 3, column 5 (0-based, byte column)
//   @gutter:3       the line-number gutter next to line 3
//   @completion:2   row 2 of the completion popup (filtered index)
package control

import km "../keymap"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

Where_Kind :: enum {
	Pixels,
	Text,
	Gutter,
	Completion,
	Problem,
	Find_Part, // line: 0 query, 1 replace, 2 case, 3 word, 4 regex
	Menu_Item, // line = context menu item index
	Scrollbar, // line: 0 vthumb, 1 hthumb, 2 vtrack, 3 htrack; col = percent along the track
	Palette_Row, // line = result row (display order)
	Keymap_Row,  // line = keymap editor row (display order)
	Theme_Row,   // line = theme colour index
	Theme_Slider, // line = channel 0..3, col = percent
	Utility_Row,  // line = utilities action index
}

Where :: struct {
	kind:      Where_Kind,
	x, y:      f32, // .Pixels
	line, col: int, // .Text (line, col), .Gutter (line), .Completion (line = row)
}

Mouse_Opts :: struct {
	clicks: int,        // click count (1 = single, 2 = double, ...)
	button: u8,         // 1 left, 2 middle, 3 right
	mod:    sdl.Keymod, // modifier keys held around the gesture
	steps:  int,        // drag: intermediate motion events
	dx:     f32,        // wheel: horizontal amount
	at:     Where,      // wheel: pointer position
	has_at: bool,
}

DEFAULT_MOUSE_OPTS :: Mouse_Opts{clicks = 1, button = 1, steps = 8}

Cmd_Click :: struct {
	target: Where,
	opts:  Mouse_Opts,
}
Cmd_Mouse_Down :: struct {
	target: Where,
	opts:  Mouse_Opts,
}
Cmd_Mouse_Up :: struct {
	target: Where,
	opts:  Mouse_Opts,
}
Cmd_Move :: struct {
	target: Where,
}
Cmd_Drag :: struct {
	from, to: Where,
	opts:     Mouse_Opts,
}
Cmd_Wheel :: struct {
	dy:   f32,
	opts: Mouse_Opts,
}
Cmd_Locate :: struct {
	target: Where,
}

// parse_where consumes one <where> from the front of `parts`.
parse_where :: proc(parts: []string) -> (w: Where, used: int, ok: bool) {
	if len(parts) == 0 {
		return
	}
	tok := parts[0]
	if strings.has_prefix(tok, "@") {
		body := tok[1:]
		switch body {
		case "vthumb": return Where{kind = .Scrollbar, line = 0}, 1, true
		case "hthumb": return Where{kind = .Scrollbar, line = 1}, 1, true
		}
		colon := strings.index_byte(body, ':')
		if colon < 0 {
			return
		}
		head, tail := body[:colon], body[colon + 1:]
		switch head {
		case "gutter":
			w.kind = .Gutter
			w.line, ok = strconv.parse_int(tail)
		case "completion":
			w.kind = .Completion
			w.line, ok = strconv.parse_int(tail)
		case "problem":
			w.kind = .Problem
			w.line, ok = strconv.parse_int(tail)
		case "menu":
			w.kind = .Menu_Item
			w.line, ok = strconv.parse_int(tail)
		case "palette":
			w.kind = .Palette_Row
			w.line, ok = strconv.parse_int(tail)
		case "keymap":
			w.kind = .Keymap_Row
			w.line, ok = strconv.parse_int(tail)
		case "utility":
			w.kind = .Utility_Row
			w.line, ok = strconv.parse_int(tail)
		case "theme":
			w.kind = .Theme_Row
			w.line, ok = strconv.parse_int(tail)
		case "slider-r", "slider-g", "slider-b", "slider-a":
			w.kind = .Theme_Slider
			w.line = strings.index_byte("rgba", head[7])
			w.col, ok = strconv.parse_int(tail)
			ok &&= w.col >= 0 && w.col <= 100
		case "vtrack", "htrack":
			w.kind = .Scrollbar
			w.line = 2 if head == "vtrack" else 3
			w.col, ok = strconv.parse_int(tail)
			ok &&= w.col <= 100
		case "find":
			w.kind = .Find_Part
			ok = true
			switch tail {
			case "query": w.line = 0
			case "replace": w.line = 1
			case "case": w.line = 2
			case "word": w.line = 3
			case "regex": w.line = 4
			case: ok = false
			}
		case:
			w.kind = .Text
			l, okl := strconv.parse_int(head)
			c, okc := strconv.parse_int(tail)
			w.line, w.col, ok = l, c, okl && okc
		}
		return w, 1, ok && w.line >= 0 && w.col >= 0
	}
	if len(parts) < 2 {
		return
	}
	x, okx := strconv.parse_f32(parts[0])
	y, oky := strconv.parse_f32(parts[1])
	return Where{kind = .Pixels, x = x, y = y}, 2, okx && oky
}

// parse_mouse_opts parses trailing key=value options.
parse_mouse_opts :: proc(parts: []string, platform: km.Platform) -> (o: Mouse_Opts, err: string) {
	o = DEFAULT_MOUSE_OPTS
	for p in parts {
		eq := strings.index_byte(p, '=')
		if eq < 0 {
			return o, strings.concatenate({"expected key=value option, got ", p}, context.temp_allocator)
		}
		key, val := p[:eq], p[eq + 1:]
		ok := true
		switch key {
		case "clicks":
			o.clicks, ok = strconv.parse_int(val)
			ok &&= o.clicks >= 1
		case "steps":
			o.steps, ok = strconv.parse_int(val)
			ok &&= o.steps >= 1
		case "dx":
			o.dx, ok = strconv.parse_f32(val)
		case "button":
			switch val {
			case "left": o.button = 1
			case "middle": o.button = 2
			case "right": o.button = 3
			case: ok = false
			}
		case "mods":
			o.mod, ok = parse_mods(val, platform)
		case "at":
			w, used, okw := parse_where({val})
			ok = okw && used == 1
			o.at, o.has_at = w, true
		case:
			return o, strings.concatenate({"unknown option: ", key}, context.temp_allocator)
		}
		if !ok {
			return o, strings.concatenate({"bad value for ", key, ": ", val}, context.temp_allocator)
		}
	}
	return o, ""
}

// parse_mods parses "shift+alt" style modifier lists (no key).
parse_mods :: proc(spec: string, platform: km.Platform) -> (mod: sdl.Keymod, ok: bool) {
	// Reuse the chord parser by appending a dummy key.
	_, mod, ok = parse_chord(strings.concatenate({spec, "+a"}, context.temp_allocator), platform)
	return
}

// parse_mouse_command handles the mouse verbs; `handled` is false for
// any other verb.
parse_mouse_command :: proc(verb, rest: string, platform: km.Platform) -> (cmd: Command, err: string, handled: bool) {
	parts := strings.fields(rest, context.temp_allocator)
	handled = true
	switch verb {
	case "click", "mousedown", "mouseup", "move", "locate":
		w, used, ok := parse_where(parts)
		if !ok {
			return nil, strings.concatenate({"usage: ", verb, " <x> <y> | @line:col | @gutter:line | @completion:row [options]"}, context.temp_allocator), true
		}
		opts, oerr := parse_mouse_opts(parts[used:], platform)
		if oerr != "" {
			return nil, oerr, true
		}
		switch verb {
		case "click": return Cmd_Click{w, opts}, "", true
		case "mousedown": return Cmd_Mouse_Down{w, opts}, "", true
		case "mouseup": return Cmd_Mouse_Up{w, opts}, "", true
		case "move": return Cmd_Move{w}, "", true
		}
		return Cmd_Locate{w}, "", true
	case "drag":
		from, used1, ok1 := parse_where(parts)
		if !ok1 {
			return nil, "usage: drag <from> <to> [steps=N] [mods=...] [clicks=N]", true
		}
		to, used2, ok2 := parse_where(parts[used1:])
		if !ok2 {
			return nil, "usage: drag <from> <to> [steps=N] [mods=...] [clicks=N]", true
		}
		opts, oerr := parse_mouse_opts(parts[used1 + used2:], platform)
		if oerr != "" {
			return nil, oerr, true
		}
		return Cmd_Drag{from, to, opts}, "", true
	case "wheel":
		if len(parts) == 0 {
			return nil, "usage: wheel <dy> [dx=N] [at=<where>] [mods=...]", true
		}
		dy, ok := strconv.parse_f32(parts[0])
		if !ok {
			return nil, "usage: wheel <dy> [dx=N] [at=<where>] [mods=...]", true
		}
		opts, oerr := parse_mouse_opts(parts[1:], platform)
		if oerr != "" {
			return nil, oerr, true
		}
		return Cmd_Wheel{dy, opts}, "", true
	}
	return nil, "", false
}
