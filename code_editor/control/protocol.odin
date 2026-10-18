// Package control is an out-of-process automation hook for an SDL app that
// hosts an `editor.Editor`. It listens on a localhost TCP port for a small
// line-based command protocol and turns commands into *real* SDL events
// pushed with `sdl.PushEvent`, so they arrive through the host's normal
// `SDL_PollEvent` loop exactly like keyboard/mouse input would (host-level
// shortcuts included). It can also report editor state as JSON, block
// until a condition holds (e.g. "completion popup visible"), and capture
// screenshots — enough to drive and verify the GUI from a script or an
// external test runner. See README.md "Remote control hook".
//
// This file is the pure, SDL-independent part: parsing command lines and
// key chords. It's unit tested in control_test.odin.
package control

import km "../keymap"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

Wait_Condition :: enum {
	Completion,     // completion popup visible
	No_Completion,  // completion popup closed
	Signature,      // signature-help tooltip visible
	No_Signature,   // signature-help tooltip closed
	Lsp_Ready,      // server initialized and document opened
	Lsp_Idle,       // no LSP requests in flight
	Lsp_Down,       // server not running (crashed/restarting/failed)
	Diagnostics,    // the document has at least one diagnostic
	No_Diagnostics, // the document has none
	Tooltip,        // the diagnostic tooltip is showing
	Code_Actions,   // the quick-fix menu has the server's answer
	Hover,          // the LSP hover tooltip is showing
	Peek,           // the peek-definition window is open
	References,     // the references panel is open
	Frames,         // a fixed number of frames has elapsed
}

Cmd_Key :: struct {
	key:   sdl.Keycode,
	mod:   sdl.Keymod,
	count: int,
	// `key @<action>` (e.g. `key @replace`): press whatever chord the
	// editor's keymap binds to that action on this platform. Resolved by
	// the server against the live keymap; empty for ordinary chords.
	action: string,
}
// Cmd_Text pushes one TEXT_INPUT event carrying the whole string.
Cmd_Text :: struct {
	text: string,
}
// Cmd_Type pushes one TEXT_INPUT event per character, like real typing,
// so per-character triggers (e.g. '.' -> completion) fire.
Cmd_Type :: struct {
	text: string,
}
Cmd_State :: struct {}
Cmd_Wait :: struct {
	cond:       Wait_Condition,
	// Timeout in milliseconds, or the frame count for `.Frames`.
	amount:     int,
}
Cmd_Screenshot :: struct {
	path: string,
}
Cmd_Open :: struct {
	path: string,
}
Cmd_Cursor :: struct {
	line, col: int,
}
Cmd_Quit :: struct {}
Cmd_Help :: struct {}
// Cmd_Lsp_Kill SIGKILLs the language server (crash-recovery testing).
Cmd_Lsp_Kill :: struct {}

Expect_Field :: enum {
	Line,                // current line text equals
	Cursor,              // "line col"
	Text_Contains,       // whole buffer contains substring
	Completion_Selected, // highlighted completion label equals
	Completion_Has,      // some listed completion label equals
	Signature,           // signature label contains substring
	Signature_Param,     // active parameter label equals
	Selection,           // primary selection "l1 c1 l2 c2" (normalized) or "none"
	Selected_Text,       // primary selection's text equals
	Cursors,             // number of cursors
	Mouse_Cursor,        // pointer shape: "text" or "default"
	Scroll,              // "line col"
	Lsp_Status,          // off|starting|running|restarting|failed
	Errors,              // number of error diagnostics
	Warnings,            // number of warning diagnostics
	Diagnostics_Has,     // some diagnostic message contains substring
	Line_Severity,       // "<line> error|warning|info|hint|none" (gutter marker)
	Tooltip,             // tooltip text contains substring, or "none"
	Problems_Open,       // "true" / "false"
	Problems_Has,        // some problems-panel row ("file:line:col message") contains substring
	Actions_Has,         // some quick-fix title contains substring
	Diag_Range,          // some diagnostic spans exactly "l1 c1 l2 c2" (bytes)
	Find_Status,         // find bar status text equals ("2 of 5", "No results", ...)
	Find_Open,           // "true" / "false"
	Completion_Doc,      // the completion docs panel contains substring
	Snippet_Active,      // "true" / "false"
	Snippet_Stop,        // index of the current snippet tab stop ($N)
	Hover,               // hover tooltip text contains substring, or "none"
	Menu_Open,           // context menu "true" / "false"
	Font_Size,           // requested editor font size (zoom), integer points
	Palette_Open,        // "true" / "false"
	Palette_Selected,    // label of the highlighted palette entry
	Peek_Open,           // "true" / "false"
	Refs_Count,          // number of references in the panel
	Status,              // header status message contains substring
	Window,              // current editor window ("text", "keymap", ...)
	Keymap_Selected,     // title of the keymap editor's selected row
	Keymap_Capturing,    // keymap editor is recording a chord: "true" / "false"
	Binding,             // "<action>=<chord>": chord is bound to action ("<action>=none": unbound)
	Last_Import,         // last keymap import summary contains substring
	Theme_Color,         // "<field>=<#hex>": a theme colour (#rgb / #rrggbb / #rrggbbaa)
	Theme_Selected,      // theme editor's selected field name ("text_keyword")
	Theme_Base,          // theme preset name ("Ayu Dark")
}

// Cmd_Expect asserts on editor state; replies `ok` or
// `fail expected <want> got <actual>` so scripts can verify themselves.
Cmd_Expect :: struct {
	field: Expect_Field,
	want:  string,
}

Command :: union {
	Cmd_Key,
	Cmd_Text,
	Cmd_Type,
	Cmd_Click,
	Cmd_Wheel,
	Cmd_State,
	Cmd_Wait,
	Cmd_Screenshot,
	Cmd_Open,
	Cmd_Cursor,
	Cmd_Quit,
	Cmd_Help,
	Cmd_Expect,
	Cmd_Mouse_Down,
	Cmd_Mouse_Up,
	Cmd_Move,
	Cmd_Drag,
	Cmd_Locate,
	Cmd_Lsp_Kill,
}

DEFAULT_WAIT_TIMEOUT_MS :: 5000

HELP_TEXT :: "commands: key <chord>|@<action> [count] | type <text> | text <text> | " +
	"click|mousedown|mouseup <where> [clicks=N] [mods=shift+alt] [button=left|middle|right] | move <where> | " +
	"drag <from> <to> [steps=N] [mods=..] [clicks=N] | wheel <dy> [dx=N] [at=<where>] [mods=..] | locate <where> | " +
	"where = <x> <y> | @line:col | @gutter:line | @completion:row | @problem:index | @menu:index | @palette:row | @keymap:row | @theme:row | @slider-r|g|b|a:pct | @utility:row | @vthumb | @hthumb | @vtrack:pct | @htrack:pct | @find:query|replace|case|word|regex | lsp-kill | " +
	"state | wait <completion|no-completion|signature|no-signature|lsp-ready|lsp-idle|lsp-down|diagnostics|no-diagnostics|tooltip|code-actions> [timeout_ms] | " +
	"wait frames <n> | screenshot <path.png> | open <path> | cursor <line> <col> | quit | help | " +
	"expect <line|cursor|text-contains|completion-selected|completion-has|signature|signature-param|" +
	"selection|selected-text|cursors|mouse-cursor|scroll|lsp-status|errors|warnings|diagnostics-has|line-severity|tooltip|" +
	"problems-open|problems-has|actions-has|diag-range|find-status|find-open|completion-doc|snippet-active|snippet-stop|hover|menu-open|font-size|palette-open|palette-selected|peek-open|refs-count|status|window|keymap-selected|keymap-capturing|binding|last-import|theme-color|theme-selected|theme-base> <value>. " +
	"chords: [primary+|cmd+|ctrl+|alt+|shift+]<key>, e.g. primary+space, shift+end, down. " +
	"text escapes: \\n \\t \\\\"

// parse_command parses one protocol line. Strings in the returned command
// (text, paths) are allocated with `allocator`; `err` describes why a line
// was rejected.
parse_command :: proc(line: string, platform: km.Platform, allocator := context.allocator) -> (cmd: Command, err: string) {
	trimmed := strings.trim_right(line, "\r\n")
	verb, rest := split_verb(trimmed)
	if mcmd, merr, handled := parse_mouse_command(verb, rest, platform); handled {
		return mcmd, merr
	}
	switch verb {
	case "key":
		parts := strings.fields(rest, context.temp_allocator)
		if len(parts) < 1 || len(parts) > 2 {
			return nil, "usage: key <chord> [count]"
		}
		if strings.has_prefix(parts[0], "@") {
			count := 1
			if len(parts) == 2 {
				n, ok := strconv.parse_int(parts[1])
				if !ok || n < 1 {
					return nil, "key count must be a positive integer"
				}
				count = n
			}
			return Cmd_Key{count = count, action = strings.clone(parts[0][1:], allocator)}, ""
		}
		key, mod, ok := parse_chord(parts[0], platform)
		if !ok {
			return nil, strings.concatenate({"unknown key chord: ", parts[0]}, context.temp_allocator)
		}
		count := 1
		if len(parts) == 2 {
			count, ok = strconv.parse_int(parts[1])
			if !ok || count < 1 {
				return nil, "key count must be a positive integer"
			}
		}
		return Cmd_Key{key = key, mod = mod, count = count}, ""
	case "text", "type":
		if len(rest) == 0 {
			return nil, "usage: text|type <text>"
		}
		text := unescape(rest, allocator)
		if verb == "text" {
			return Cmd_Text{text}, ""
		}
		return Cmd_Type{text}, ""
	case "state":
		return Cmd_State{}, ""
	case "wait":
		return parse_wait(rest)
	case "screenshot":
		path := strings.trim_space(rest)
		if len(path) == 0 {
			return nil, "usage: screenshot <path.png>"
		}
		return Cmd_Screenshot{strings.clone(path, allocator)}, ""
	case "open":
		path := strings.trim_space(rest)
		if len(path) == 0 {
			return nil, "usage: open <path>"
		}
		return Cmd_Open{strings.clone(path, allocator)}, ""
	case "cursor":
		parts := strings.fields(rest, context.temp_allocator)
		if len(parts) != 2 {
			return nil, "usage: cursor <line> <col>"
		}
		l, okl := strconv.parse_int(parts[0])
		c, okc := strconv.parse_int(parts[1])
		if !okl || !okc {
			return nil, "cursor line/col must be integers"
		}
		return Cmd_Cursor{l, c}, ""
	case "lsp-kill":
		return Cmd_Lsp_Kill{}, ""
	case "quit":
		return Cmd_Quit{}, ""
	case "help":
		return Cmd_Help{}, ""
	case "expect":
		name, value := split_verb(rest)
		field: Expect_Field
		switch name {
		case "line": field = .Line
		case "cursor": field = .Cursor
		case "text-contains": field = .Text_Contains
		case "completion-selected": field = .Completion_Selected
		case "completion-has": field = .Completion_Has
		case "signature": field = .Signature
		case "signature-param": field = .Signature_Param
		case "selection": field = .Selection
		case "selected-text": field = .Selected_Text
		case "cursors": field = .Cursors
		case "mouse-cursor": field = .Mouse_Cursor
		case "scroll": field = .Scroll
		case "lsp-status": field = .Lsp_Status
		case "errors": field = .Errors
		case "warnings": field = .Warnings
		case "diagnostics-has": field = .Diagnostics_Has
		case "line-severity": field = .Line_Severity
		case "tooltip": field = .Tooltip
		case "problems-open": field = .Problems_Open
		case "problems-has": field = .Problems_Has
		case "actions-has": field = .Actions_Has
		case "diag-range": field = .Diag_Range
		case "find-status": field = .Find_Status
		case "find-open": field = .Find_Open
		case "completion-doc": field = .Completion_Doc
		case "snippet-active": field = .Snippet_Active
		case "snippet-stop": field = .Snippet_Stop
		case "hover": field = .Hover
		case "menu-open": field = .Menu_Open
		case "font-size": field = .Font_Size
		case "palette-open": field = .Palette_Open
		case "palette-selected": field = .Palette_Selected
		case "peek-open": field = .Peek_Open
		case "refs-count": field = .Refs_Count
		case "status": field = .Status
		case "window": field = .Window
		case "keymap-selected": field = .Keymap_Selected
		case "keymap-capturing": field = .Keymap_Capturing
		case "binding": field = .Binding
		case "last-import": field = .Last_Import
		case "theme-color": field = .Theme_Color
		case "theme-selected": field = .Theme_Selected
		case "theme-base": field = .Theme_Base
		case:
			return nil, strings.concatenate({"unknown expect field: ", name}, context.temp_allocator)
		}
		return Cmd_Expect{field, unescape(value, allocator)}, ""
	}
	return nil, strings.concatenate({"unknown command: ", verb}, context.temp_allocator)
}

// command_destroy frees strings owned by a parsed command.
command_destroy :: proc(cmd: Command, allocator := context.allocator) {
	#partial switch c in cmd {
	case Cmd_Key: delete(c.action, allocator)
	case Cmd_Text: delete(c.text, allocator)
	case Cmd_Type: delete(c.text, allocator)
	case Cmd_Screenshot: delete(c.path, allocator)
	case Cmd_Open: delete(c.path, allocator)
	case Cmd_Expect: delete(c.want, allocator)
	}
}

// split_verb splits "verb rest of line" at the first space. `rest` is not
// trimmed further, so `type` / `text` payloads keep meaningful spaces.
@(private)
split_verb :: proc(line: string) -> (verb, rest: string) {
	l := strings.trim_left_space(line)
	i := strings.index_byte(l, ' ')
	if i < 0 {
		return l, ""
	}
	return l[:i], l[i + 1:]
}

@(private)
parse_wait :: proc(rest: string) -> (cmd: Command, err: string) {
	parts := strings.fields(rest, context.temp_allocator)
	if len(parts) < 1 || len(parts) > 2 {
		return nil, "usage: wait <condition> [timeout_ms] | wait frames <n>"
	}
	cond: Wait_Condition
	switch parts[0] {
	case "completion": cond = .Completion
	case "no-completion": cond = .No_Completion
	case "signature": cond = .Signature
	case "no-signature": cond = .No_Signature
	case "lsp-ready": cond = .Lsp_Ready
	case "lsp-idle": cond = .Lsp_Idle
	case "lsp-down": cond = .Lsp_Down
	case "diagnostics": cond = .Diagnostics
	case "no-diagnostics": cond = .No_Diagnostics
	case "tooltip": cond = .Tooltip
	case "code-actions": cond = .Code_Actions
	case "hover": cond = .Hover
	case "peek": cond = .Peek
	case "references": cond = .References
	case "frames": cond = .Frames
	case:
		return nil, strings.concatenate({"unknown wait condition: ", parts[0]}, context.temp_allocator)
	}
	amount := cond == .Frames ? 1 : DEFAULT_WAIT_TIMEOUT_MS
	if len(parts) == 2 {
		n, ok := strconv.parse_int(parts[1])
		if !ok || n < 0 {
			return nil, "wait amount must be a non-negative integer"
		}
		amount = n
	}
	return Cmd_Wait{cond, amount}, ""
}

// unescape expands \n, \t and \\ in a protocol text payload.
unescape :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&sb, '\n')
				i += 1
				continue
			case 't':
				strings.write_byte(&sb, '\t')
				i += 1
				continue
			case '\\':
				strings.write_byte(&sb, '\\')
				i += 1
				continue
			}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// parse_chord parses specs like "primary+shift+space", "cmd+s", "down",
// "." into an SDL keycode + modifier set. `primary` is Cmd on macOS and
// Ctrl elsewhere, so scripts can be written once for every platform.
parse_chord :: proc(spec: string, platform: km.Platform) -> (key: sdl.Keycode, mod: sdl.Keymod, ok: bool) {
	s := spec
	// A trailing "+" is the plus key itself, e.g. "ctrl++" — but "+" alone
	// is also just the key.
	key_part: string
	if strings.has_suffix(s, "++") {
		key_part = "+"
		s = s[:len(s) - 2]
	} else if s == "+" {
		key_part = "+"
		s = ""
	} else {
		i := strings.last_index_byte(s, '+')
		key_part = s[i + 1:]
		s = s[:max(i, 0)]
	}

	for len(s) > 0 {
		i := strings.index_byte(s, '+')
		name := s if i < 0 else s[:i]
		s = "" if i < 0 else s[i + 1:]
		switch strings.to_lower(name, context.temp_allocator) {
		case "shift": mod |= sdl.KMOD_LSHIFT
		case "ctrl", "control": mod |= sdl.KMOD_LCTRL
		case "alt", "opt", "option": mod |= sdl.KMOD_LALT
		case "cmd", "command", "gui", "super", "meta", "win": mod |= sdl.KMOD_LGUI
		case "primary":
			mod |= platform == .MacOS ? sdl.KMOD_LGUI : sdl.KMOD_LCTRL
		case:
			return 0, {}, false
		}
	}

	key, ok = key_from_name(key_part)
	return
}

@(private)
key_from_name :: proc(name: string) -> (sdl.Keycode, bool) {
	if len(name) == 1 {
		ch := name[0]
		if ch >= 'A' && ch <= 'Z' {
			ch += 32
		}
		// SDL keycodes for printable ASCII keys are the (lowercase)
		// character code itself.
		if ch > ' ' && ch < 0x7f {
			return sdl.Keycode(ch), true
		}
		return 0, false
	}
	switch strings.to_lower(name, context.temp_allocator) {
	case "space": return sdl.K_SPACE, true
	case "enter", "return": return sdl.K_RETURN, true
	case "tab": return sdl.K_TAB, true
	case "esc", "escape": return sdl.K_ESCAPE, true
	case "backspace", "bs": return sdl.K_BACKSPACE, true
	case "delete", "del": return sdl.K_DELETE, true
	case "up": return sdl.K_UP, true
	case "down": return sdl.K_DOWN, true
	case "left": return sdl.K_LEFT, true
	case "right": return sdl.K_RIGHT, true
	case "home": return sdl.K_HOME, true
	case "end": return sdl.K_END, true
	case "pageup", "pgup": return sdl.K_PAGEUP, true
	case "pagedown", "pgdn": return sdl.K_PAGEDOWN, true
	case "plus": return sdl.K_PLUS, true
	case "f1": return sdl.K_F1, true
	case "f2": return sdl.K_F2, true
	case "f3": return sdl.K_F3, true
	case "f4": return sdl.K_F4, true
	case "f5": return sdl.K_F5, true
	case "f6": return sdl.K_F6, true
	case "f7": return sdl.K_F7, true
	case "f8": return sdl.K_F8, true
	case "f9": return sdl.K_F9, true
	case "f10": return sdl.K_F10, true
	case "f11": return sdl.K_F11, true
	case "f12": return sdl.K_F12, true
	}
	return 0, false
}
