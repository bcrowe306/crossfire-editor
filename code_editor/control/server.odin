// The control server: a non-blocking localhost TCP listener the host polls
// once per frame. Each connected client sends newline-terminated commands
// (see protocol.odin) and receives exactly one newline-terminated reply per
// command: `ok ...`, `err <reason>`, `timeout <condition>`, or (for
// `state`) one line of JSON.
//
// Host integration (see example/main.odin):
//
//     srv: control.Server
//     control.server_start(&srv, port, window, platform)
//     for running {
//         control.server_poll(&srv, &editor)          // before SDL_PollEvent
//         for sdl.PollEvent(&ev) { ... }              // injected events arrive here
//         editor_update(&editor)
//         editor_render(...)
//         control.server_after_render(&srv, &editor, renderer)  // before present
//         sdl.RenderPresent(renderer)
//     }
//
// Commands for one client run strictly in order. Any command that pushes
// SDL events holds back that client's next command until the following
// frame, so the events have been polled and handled before e.g. `state`
// or `wait` looks at the result.
package control

import ed "../editor"
import km "../keymap"
import "core:c/libc"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

@(private)
Conn :: struct {
	sock:        net.TCP_Socket,
	recv:        [dynamic]u8,
	queue:       [dynamic]string,
	peer_closed: bool,
	// Don't run the next queued command before this frame.
	resume_frame: int,
	// Command currently blocked on a wait/screenshot, if any.
	blocked:      bool,
	wait:         Cmd_Wait,
	wait_start:   time.Tick,
	wait_frame:   int,
	screenshot:   string,
}

Server :: struct {
	listener:  net.TCP_Socket,
	running:   bool,
	port:      int,
	window:    ^sdl.Window,
	platform:  km.Platform,
	conns:     [dynamic]^Conn,
	frame:     int,
	// TEXT_INPUT payloads pushed to SDL: SDL doesn't copy them, so they
	// must outlive the frame in which the host polls them.
	texts:     [dynamic]cstring,
	old_texts: [dynamic]cstring,
}

// server_start begins listening on 127.0.0.1:`port` (loopback only — the
// hook is never reachable from other machines). Returns false if the port
// can't be bound.
server_start :: proc(srv: ^Server, port: int, window: ^sdl.Window, platform: km.Platform) -> bool {
	// Writing a reply to a client that already hung up must not kill the
	// host with SIGPIPE.
	libc.signal(13 /* SIGPIPE */, auto_cast libc.SIG_IGN)

	ep := net.Endpoint{address = net.IP4_Loopback, port = port}
	sock, err := net.listen_tcp(ep)
	if err != nil {
		fmt.eprintfln("control: cannot listen on 127.0.0.1:%d: %v", port, err)
		return false
	}
	net.set_blocking(sock, false)
	srv.listener = sock
	srv.running = true
	srv.port = port
	srv.window = window
	srv.platform = platform
	srv.conns = make([dynamic]^Conn)
	srv.texts = make([dynamic]cstring)
	srv.old_texts = make([dynamic]cstring)
	return true
}

server_stop :: proc(srv: ^Server) {
	if !srv.running {
		return
	}
	for c in srv.conns {
		conn_destroy(c)
	}
	delete(srv.conns)
	net.close(srv.listener)
	free_texts(&srv.old_texts)
	free_texts(&srv.texts)
	delete(srv.texts)
	delete(srv.old_texts)
	srv.running = false
}

@(private)
free_texts :: proc(list: ^[dynamic]cstring) {
	for t in list {
		delete(t)
	}
	clear(list)
}

@(private)
conn_destroy :: proc(c: ^Conn) {
	net.close(c.sock)
	delete(c.recv)
	for line in c.queue {
		delete(line)
	}
	delete(c.queue)
	delete(c.screenshot)
	free(c)
}

// server_poll accepts connections, reads commands and runs every command
// that is ready. Call once per frame, before the host's SDL_PollEvent loop.
server_poll :: proc(srv: ^Server, e: ^ed.Editor) {
	if !srv.running {
		return
	}
	srv.frame += 1

	// Payloads pushed two polls ago have certainly been consumed.
	free_texts(&srv.old_texts)
	srv.old_texts, srv.texts = srv.texts, srv.old_texts

	for {
		client, _, err := net.accept_tcp(srv.listener)
		if err != nil {
			break
		}
		net.set_blocking(client, false)
		c := new(Conn)
		c.sock = client
		c.recv = make([dynamic]u8)
		c.queue = make([dynamic]string)
		append(&srv.conns, c)
	}

	for i := 0; i < len(srv.conns); {
		c := srv.conns[i]
		conn_read(c)
		conn_run(srv, c, e)
		if c.peer_closed && len(c.queue) == 0 && !c.blocked {
			conn_destroy(c)
			ordered_remove(&srv.conns, i)
			continue
		}
		i += 1
	}
}

@(private)
conn_read :: proc(c: ^Conn) {
	if c.peer_closed {
		return
	}
	for {
		chunk: [4096]u8
		n, err := net.recv_tcp(c.sock, chunk[:])
		if err != nil {
			if err != .Would_Block {
				c.peer_closed = true
			}
			break
		}
		if n == 0 {
			c.peer_closed = true
			break
		}
		append(&c.recv, ..chunk[:n])
	}
	// Split complete lines into the command queue.
	for {
		nl := -1
		for b, j in c.recv {
			if b == '\n' {
				nl = j
				break
			}
		}
		if nl < 0 {
			break
		}
		line := strings.clone(string(c.recv[:nl]))
		remove_range(&c.recv, 0, nl + 1)
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' {
			delete(line)
			continue
		}
		append(&c.queue, line)
	}
	// A final unterminated line counts once the peer is done sending.
	if c.peer_closed && len(c.recv) > 0 {
		append(&c.queue, strings.clone(string(c.recv[:])))
		clear(&c.recv)
	}
}

@(private)
remove_range :: proc(b: ^[dynamic]u8, lo, hi: int) {
	copy(b[lo:], b[hi:])
	resize(b, len(b) - (hi - lo))
}

@(private)
reply :: proc(c: ^Conn, msg: string) {
	out := strings.concatenate({msg, "\n"}, context.temp_allocator)
	data := transmute([]u8)out
	// Replies are small; retry briefly if the socket buffer is full.
	for tries := 0; len(data) > 0 && tries < 1000; tries += 1 {
		n, err := net.send_tcp(c.sock, data)
		if err != nil && err != .Would_Block {
			return
		}
		data = data[n:]
	}
}

@(private)
conn_run :: proc(srv: ^Server, c: ^Conn, e: ^ed.Editor) {
	for {
		if c.blocked {
			if c.screenshot != "" {
				return // finished in server_after_render
			}
			if !wait_check(srv, c, e) {
				return
			}
		}
		if len(c.queue) == 0 || srv.frame < c.resume_frame {
			return
		}
		line := c.queue[0]
		ordered_remove(&c.queue, 0)
		run_command(srv, c, e, line)
		delete(line)
	}
}

@(private)
run_command :: proc(srv: ^Server, c: ^Conn, e: ^ed.Editor, line: string) {
	cmd, perr := parse_command(line, srv.platform)
	defer command_destroy(cmd)
	if cmd == nil {
		reply(c, strings.concatenate({"err ", perr}, context.temp_allocator))
		return
	}

	switch v in cmd {
	case Cmd_Key:
		key, mod := v.key, v.mod
		if v.action != "" {
			ok: bool
			key, mod, ok = chord_for_action(e, v.action)
			if !ok {
				reply(c, fmt.tprintf("err no key bound to action %q", v.action))
				return
			}
		}
		for _ in 0 ..< v.count {
			push_key(srv, key, mod)
		}
		c.resume_frame = srv.frame + 1
		reply(c, "ok")
	case Cmd_Text:
		push_text(srv, v.text)
		c.resume_frame = srv.frame + 1
		reply(c, "ok")
	case Cmd_Type:
		for ch in v.text {
			bytes, n := utf8.encode_rune(ch)
			push_text(srv, string(bytes[:n]))
		}
		c.resume_frame = srv.frame + 1
		reply(c, "ok")
	case Cmd_Click, Cmd_Mouse_Down, Cmd_Mouse_Up, Cmd_Move, Cmd_Drag, Cmd_Wheel, Cmd_Locate:
		msg := run_mouse_command(srv, e, cmd)
		if strings.has_prefix(msg, "ok") {
			c.resume_frame = srv.frame + 1
		}
		reply(c, msg)
	case Cmd_Lsp_Kill:
		if !e.lsp_enabled || !e.lsp.has_process {
			reply(c, "err no language server process")
		} else {
			pid := e.lsp.process.pid
			_ = os.process_kill(e.lsp.process)
			reply(c, fmt.tprintf("ok killed pid %d", pid))
		}
	case Cmd_State:
		reply(c, state_json(e, srv.frame))
	case Cmd_Wait:
		c.blocked = true
		c.wait = v
		c.wait_start = time.tick_now()
		c.wait_frame = srv.frame
	case Cmd_Screenshot:
		c.blocked = true
		c.screenshot = strings.clone(v.path)
	case Cmd_Open:
		if ed.editor_load_file(e, v.path) {
			reply(c, "ok")
		} else {
			reply(c, strings.concatenate({"err cannot open ", v.path}, context.temp_allocator))
		}
	case Cmd_Cursor:
		resize(&e.buf.cursors, 1)
		cur := ed.editor_primary_cursor(e)
		cur.pos = ed.editor_clamp_to_buffer(e, v.line, v.col)
		cur.sel.active = false
		ed.editor_ensure_cursor_visible(e)
		reply(c, fmt.tprintf("ok %d %d", cur.pos.line, cur.pos.col))
	case Cmd_Quit:
		ev: sdl.Event
		ev.type = .QUIT
		_ = sdl.PushEvent(&ev)
		reply(c, "ok")
	case Cmd_Help:
		reply(c, strings.concatenate({"ok ", HELP_TEXT}, context.temp_allocator))
	case Cmd_Expect:
		reply(c, check_expect(e, v))
	}
}

// check_expect evaluates an `expect` assertion against the live editor.
check_expect :: proc(e: ^ed.Editor, x: Cmd_Expect) -> string {
	s := snapshot_state(e, 0)
	actual: string
	pass: bool
	switch x.field {
	case .Line:
		actual = s.current_line
		pass = actual == x.want
	case .Cursor:
		actual = fmt.tprintf("%d %d", s.cursor[0], s.cursor[1])
		pass = actual == strings.trim_space(x.want)
	case .Text_Contains:
		actual = s.text
		pass = strings.contains(actual, x.want)
	case .Completion_Selected:
		actual = s.completion.selected_label
		pass = s.completion.visible && actual == x.want
	case .Completion_Has:
		// Search every listed item, not just the snapshot's first few.
		actual = fmt.tprintf("%d items starting %v", s.completion.count, s.completion.items)
		for idx in e.completion.filtered {
			pass ||= s.completion.visible && e.lsp.last_completion[idx].label == x.want
		}
	case .Signature:
		actual = s.signature.label
		pass = s.signature.visible && strings.contains(actual, x.want)
	case .Signature_Param:
		actual = s.signature.active_param
		pass = s.signature.visible && actual == x.want
	case .Selection:
		actual = "none"
		if len(s.selections) > 0 && s.selection {
			r := s.selections[0]
			lo, hi := [2]int{r[0], r[1]}, [2]int{r[2], r[3]}
			if hi[0] < lo[0] || (hi[0] == lo[0] && hi[1] < lo[1]) {
				lo, hi = hi, lo
			}
			actual = fmt.tprintf("%d %d %d %d", lo[0], lo[1], hi[0], hi[1])
		}
		pass = actual == strings.join(strings.fields(x.want, context.temp_allocator), " ", context.temp_allocator)
	case .Selected_Text:
		actual = s.selected_text
		pass = s.selection && actual == x.want
	case .Cursors:
		actual = fmt.tprint(s.cursors)
		pass = actual == strings.trim_space(x.want)
	case .Mouse_Cursor:
		actual = s.mouse.cursor
		pass = actual == strings.trim_space(x.want)
	case .Scroll:
		actual = fmt.tprintf("%d %d", s.scroll[0], s.scroll[1])
		pass = actual == strings.join(strings.fields(x.want, context.temp_allocator), " ", context.temp_allocator)
	case .Lsp_Status:
		actual = s.lsp.status
		pass = actual == strings.trim_space(x.want)
	case .Errors:
		actual = fmt.tprint(s.diagnostic_counts.errors)
		pass = actual == strings.trim_space(x.want)
	case .Warnings:
		actual = fmt.tprint(s.diagnostic_counts.warnings)
		pass = actual == strings.trim_space(x.want)
	case .Diagnostics_Has:
		msgs := make([dynamic]string, context.temp_allocator)
		for d in s.diagnostics {
			append(&msgs, d.message)
			pass ||= strings.contains(d.message, x.want)
		}
		actual = strings.join(msgs[:], " | ", context.temp_allocator)
	case .Line_Severity:
		parts := strings.fields(x.want, context.temp_allocator)
		if len(parts) != 2 {
			return "err usage: expect line-severity <line> <error|warning|info|hint|none>"
		}
		line, _ := strconv.parse_int(parts[0])
		actual = "none"
		if sev, ok := ed.line_severity(ed.editor_diagnostics(e), line); ok {
			actual = ed.severity_label(sev)
		}
		pass = actual == parts[1]
	case .Problems_Open:
		actual = "true" if s.problems.open else "false"
		pass = actual == strings.trim_space(x.want)
	case .Problems_Has:
		actual = strings.join(s.problems.rows, " | ", context.temp_allocator)
		for r in s.problems.rows {
			pass ||= strings.contains(r, x.want)
		}
	case .Actions_Has:
		actual = strings.join(s.code_actions.titles, " | ", context.temp_allocator)
		for title in s.code_actions.titles {
			pass ||= s.code_actions.visible && strings.contains(title, x.want)
		}
	case .Hover:
		actual = s.hover.text if s.hover.visible else "none"
		want := strings.trim_space(x.want)
		pass = want == "none" ? !s.hover.visible : s.hover.visible && strings.contains(actual, want)
	case .Peek_Open:
		actual = "true" if e.nav.peek.open else "false"
		pass = actual == strings.trim_space(x.want)
	case .Refs_Count:
		actual = fmt.tprint(len(e.nav.refs.items) if e.nav.refs.open else -1)
		pass = actual == strings.trim_space(x.want)
	case .Status:
		actual = ed.editor_status_text(e)
		pass = strings.contains(actual, x.want)
	case .Window:
		actual = s.window
		pass = actual == strings.trim_space(x.want)
	case .Keymap_Selected:
		actual = s.keymap_editor.selected_title
		pass = s.window == "keymap" && actual == strings.trim_space(x.want)
	case .Keymap_Capturing:
		actual = "true" if s.keymap_editor.capturing else "false"
		pass = actual == strings.trim_space(x.want)
	case .Binding:
		pass, actual = expect_binding(e, strings.trim_space(x.want))
	case .Last_Import:
		actual = e.config.last_import
		pass = strings.contains(actual, x.want)
	case .Theme_Color:
		pass, actual = expect_theme_color(e, strings.trim_space(x.want))
	case .Theme_Selected:
		actual = ed.theme_field_names()[e.theme_editor.selected]
		pass = s.window == "theme" && actual == strings.trim_space(x.want)
	case .Theme_Base:
		actual = ed.preset_name(e.theme_editor.base)
		pass = actual == strings.trim_space(x.want)
	case .Palette_Open:
		actual = "true" if s.palette.open else "false"
		pass = actual == strings.trim_space(x.want)
	case .Palette_Selected:
		actual = s.palette.selected_label
		pass = s.palette.open && actual == strings.trim_space(x.want)
	case .Font_Size:
		actual = fmt.tprint(int(e.font_size))
		pass = actual == strings.trim_space(x.want)
	case .Menu_Open:
		actual = "true" if s.menu.open else "false"
		pass = actual == strings.trim_space(x.want)
	case .Completion_Doc:
		actual = s.completion.doc
		pass = strings.contains(actual, x.want)
	case .Snippet_Active:
		actual = "true" if s.snippet.active else "false"
		pass = actual == strings.trim_space(x.want)
	case .Snippet_Stop:
		actual = fmt.tprint(s.snippet.stop_index)
		pass = s.snippet.active && actual == strings.trim_space(x.want)
	case .Find_Status:
		actual = s.find.status
		pass = actual == strings.trim_space(x.want)
	case .Find_Open:
		actual = "true" if s.find.open else "false"
		pass = actual == strings.trim_space(x.want)
	case .Diag_Range:
		want := strings.join(strings.fields(x.want, context.temp_allocator), " ", context.temp_allocator)
		ranges := make([dynamic]string, context.temp_allocator)
		for d in s.diagnostics {
			r := fmt.tprintf("%d %d %d %d", d.range[0], d.range[1], d.range[2], d.range[3])
			append(&ranges, r)
			pass ||= r == want
		}
		actual = strings.join(ranges[:], " | ", context.temp_allocator)
	case .Tooltip:
		actual = s.tooltip.text if s.tooltip.visible else "none"
		want := strings.trim_space(x.want)
		pass = want == "none" ? !s.tooltip.visible : s.tooltip.visible && strings.contains(actual, want)
	}
	if pass {
		return "ok"
	}
	return fmt.tprintf("fail expected %q got %q", x.want, actual)
}

// wait_check evaluates a blocked `wait`; replies and unblocks once the
// condition holds or the timeout expires. Conditions are only checked
// from the frame after the wait was issued, so events pushed by earlier
// commands have been handled first.
@(private)
wait_check :: proc(srv: ^Server, c: ^Conn, e: ^ed.Editor) -> bool {
	w := c.wait
	frames := srv.frame - c.wait_frame
	if w.cond == .Frames {
		if frames < w.amount {
			return false
		}
		c.blocked = false
		reply(c, fmt.tprintf("ok %d frames", frames))
		return true
	}

	met := false
	if frames >= 1 {
		switch w.cond {
		case .Completion: met = ed.editor_completion_visible(e)
		case .No_Completion: met = !ed.editor_completion_visible(e)
		case .Signature: met = ed.editor_signature_visible(e)
		case .No_Signature: met = !ed.editor_signature_visible(e)
		case .Lsp_Ready: met = e.lsp_enabled && e.lsp.initialized && e.lsp_doc_open
		case .Lsp_Idle: met = e.lsp_enabled && len(e.lsp.pending_kind) == 0
		case .Lsp_Down: met = ed.editor_lsp_status(e) != .Running
		case .Diagnostics: met = len(ed.editor_diagnostics(e)) > 0
		case .No_Diagnostics: met = len(ed.editor_diagnostics(e)) == 0
		case .Tooltip: met = len(ed.editor_diag_tooltip_items(e)) > 0
		case .Code_Actions: met = ed.editor_code_actions_visible(e)
		case .Hover: met = e.hover.visible
		case .Peek: met = e.nav.peek.open
		case .References: met = e.nav.refs.open
		case .Frames:
		}
	}
	elapsed := time.duration_milliseconds(time.tick_since(c.wait_start))
	name := wait_name(w.cond)
	if met {
		c.blocked = false
		reply(c, fmt.tprintf("ok %s after %.0fms", name, elapsed))
		return true
	}
	if elapsed >= f64(w.amount) {
		c.blocked = false
		reply(c, fmt.tprintf("timeout %s after %.0fms", name, elapsed))
		return true
	}
	return false
}

@(private)
wait_name :: proc(cond: Wait_Condition) -> string {
	switch cond {
	case .Completion: return "completion"
	case .No_Completion: return "no-completion"
	case .Signature: return "signature"
	case .No_Signature: return "no-signature"
	case .Lsp_Ready: return "lsp-ready"
	case .Lsp_Idle: return "lsp-idle"
	case .Lsp_Down: return "lsp-down"
	case .Diagnostics: return "diagnostics"
	case .No_Diagnostics: return "no-diagnostics"
	case .Tooltip: return "tooltip"
	case .Code_Actions: return "code-actions"
	case .Hover: return "hover"
	case .Peek: return "peek"
	case .References: return "references"
	case .Frames: return "frames"
	}
	return "?"
}

// server_after_render services pending `screenshot` commands. Call after
// editor_render and before SDL_RenderPresent (the back buffer is only
// guaranteed to hold the frame until it's presented).
server_after_render :: proc(srv: ^Server, e: ^ed.Editor, renderer: ^sdl.Renderer) {
	if !srv.running {
		return
	}
	for c in srv.conns {
		if !c.blocked || c.screenshot == "" {
			continue
		}
		path := c.screenshot
		c.screenshot = ""
		c.blocked = false
		defer delete(path)

		surface := sdl.RenderReadPixels(renderer, nil)
		if surface == nil {
			reply(c, fmt.tprintf("err RenderReadPixels: %s", sdl.GetError()))
			continue
		}
		defer sdl.DestroySurface(surface)
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		if !sdl.SavePNG(surface, cpath) {
			reply(c, fmt.tprintf("err SavePNG: %s", sdl.GetError()))
			continue
		}
		reply(c, fmt.tprintf("ok %s %dx%d", path, surface.w, surface.h))
	}
}

// --- SDL event construction -------------------------------------------------

// Device id stamped on injected keyboard/mouse events so hosts can tell
// them apart from real input (see event_is_injected).
INJECTED_DEVICE_ID :: 0x0EDC7

// event_is_user_input reports whether `ev` is keyboard/text/mouse input.
event_is_user_input :: proc(ev: sdl.Event) -> bool {
	#partial switch ev.type {
	case .KEY_DOWN, .KEY_UP, .TEXT_INPUT, .TEXT_EDITING,
	     .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP, .MOUSE_WHEEL, .MOUSE_MOTION:
		return true
	}
	return false
}

// event_is_injected reports whether an input event was pushed by this
// server rather than coming from a real device. Hosts running scripted
// tests can drop real input (`--control-only` in the demo) so a person
// typing elsewhere can't leak keystrokes into the run.
event_is_injected :: proc(srv: ^Server, ev: sdl.Event) -> bool {
	#partial switch ev.type {
	case .KEY_DOWN, .KEY_UP:
		return ev.key.which == INJECTED_DEVICE_ID
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		return ev.button.which == INJECTED_DEVICE_ID
	case .MOUSE_WHEEL:
		return ev.wheel.which == INJECTED_DEVICE_ID
	case .MOUSE_MOTION:
		return ev.motion.which == INJECTED_DEVICE_ID
	case .TEXT_INPUT:
		// Text events carry no device id; match the payload pointer
		// against the strings this server pushed.
		for t in srv.texts {
			if t == ev.text.text {
				return true
			}
		}
		for t in srv.old_texts {
			if t == ev.text.text {
				return true
			}
		}
	}
	return false
}

@(private)
window_id :: proc(srv: ^Server) -> sdl.WindowID {
	return sdl.GetWindowID(srv.window) if srv.window != nil else 0
}

// push_key pushes a KEY_DOWN followed by a KEY_UP, as a real key press
// produces.
push_key :: proc(srv: ^Server, key: sdl.Keycode, mod: sdl.Keymod) {
	ev: sdl.Event
	ev.type = .KEY_DOWN
	ev.key.windowID = window_id(srv)
	ev.key.which = INJECTED_DEVICE_ID
	ev.key.key = key
	ev.key.mod = mod
	ev.key.scancode = sdl.GetScancodeFromKey(key, nil)
	ev.key.down = true
	ev.key.timestamp = sdl.GetTicksNS()
	_ = sdl.PushEvent(&ev)

	ev.type = .KEY_UP
	ev.key.down = false
	_ = sdl.PushEvent(&ev)
}

push_text :: proc(srv: ^Server, text: string) {
	ctext := strings.clone_to_cstring(text)
	append(&srv.texts, ctext)
	ev: sdl.Event
	ev.type = .TEXT_INPUT
	ev.text.windowID = window_id(srv)
	ev.text.text = ctext
	ev.text.timestamp = sdl.GetTicksNS()
	_ = sdl.PushEvent(&ev)
}

// chord_for_action finds the chord the editor's keymap binds to the named
// action (case-insensitive, e.g. "replace", "SelectNextOccurrence") and
// converts it to an SDL keycode + modifiers. With several bindings, the
// one with the fewest modifiers wins (ties: the lowest key).
chord_for_action :: proc(e: ^ed.Editor, name: string) -> (key: sdl.Keycode, mod: sdl.Keymod, ok: bool) {
	best: km.Chord
	found := false
	for chord, action in e.keymap.bindings {
		if !strings.equal_fold(fmt.tprint(action), name) {
			continue
		}
		if !found || card(chord.mods) < card(best.mods) || (card(chord.mods) == card(best.mods) && chord.key < best.key) {
			best, found = chord, true
		}
	}
	if !found {
		return
	}
	// Reverse of editor.sdl_keycode_to_key over the keys it knows.
	candidates := [?]sdl.Keycode{
		sdl.K_A, sdl.K_B, sdl.K_C, sdl.K_D, sdl.K_E, sdl.K_F, sdl.K_G, sdl.K_H, sdl.K_I, sdl.K_J, sdl.K_K, sdl.K_L, sdl.K_M,
		sdl.K_N, sdl.K_O, sdl.K_P, sdl.K_Q, sdl.K_R, sdl.K_S, sdl.K_T, sdl.K_U, sdl.K_V, sdl.K_W, sdl.K_X, sdl.K_Y, sdl.K_Z,
		sdl.K_0, sdl.K_1, sdl.K_2, sdl.K_3, sdl.K_4, sdl.K_5, sdl.K_6, sdl.K_7, sdl.K_8, sdl.K_9,
		sdl.K_LEFT, sdl.K_RIGHT, sdl.K_UP, sdl.K_DOWN, sdl.K_HOME, sdl.K_END, sdl.K_PAGEUP, sdl.K_PAGEDOWN,
		sdl.K_BACKSPACE, sdl.K_DELETE, sdl.K_RETURN, sdl.K_TAB, sdl.K_ESCAPE, sdl.K_SPACE,
		sdl.K_SLASH, sdl.K_BACKSLASH, sdl.K_MINUS, sdl.K_EQUALS, sdl.K_LEFTBRACKET, sdl.K_RIGHTBRACKET,
		sdl.K_SEMICOLON, sdl.K_APOSTROPHE, sdl.K_COMMA, sdl.K_PERIOD, sdl.K_GRAVE, sdl.K_F1, sdl.K_F3, sdl.K_F8, sdl.K_F4, sdl.K_F12,
	}
	for code in candidates {
		if ed.sdl_keycode_to_key(code) == best.key {
			key, ok = code, true
			break
		}
	}
	if .Shift in best.mods {mod |= sdl.KMOD_LSHIFT}
	if .Ctrl in best.mods {mod |= sdl.KMOD_LCTRL}
	if .Alt in best.mods {mod |= sdl.KMOD_LALT}
	if .Super in best.mods {mod |= sdl.KMOD_LGUI}
	return
}

// --- mouse commands ----------------------------------------------------------

// resolve_where turns a <where> into window pixels using the live editor
// geometry. Text positions resolve to the caret boundary (+1px) at the
// vertical center of the line.
resolve_where :: proc(e: ^ed.Editor, w: Where) -> (x, y: f32, err: string) {
	switch w.kind {
	case .Pixels:
		return w.x, w.y, ""
	case .Text:
		pos := ed.editor_clamp_to_buffer(e, w.line, w.col)
		if pos.line < e.scroll_line || pos.line >= e.scroll_line + ed.editor_text_rows(e) {
			return 0, 0, fmt.tprintf("line %d is not visible (scroll_line=%d)", pos.line, e.scroll_line)
		}
		if vcol := ed.editor_visual_col(e, pos); vcol < e.scroll_col || vcol > e.scroll_col + e.visible_cols {
			return 0, 0, fmt.tprintf("column %d of line %d is scrolled out of view (scroll_col=%d)", pos.col, pos.line, e.scroll_col)
		}
		px, py := ed.editor_position_to_screen(e, pos)
		return px + 1, py + e.char_h / 2, ""
	case .Gutter:
		if w.line < e.scroll_line || w.line >= e.scroll_line + ed.editor_text_rows(e) {
			return 0, 0, fmt.tprintf("line %d is not visible", w.line)
		}
		return e.origin_x + ed.editor_gutter_width(e) / 2, e.origin_y + f32(w.line - e.scroll_line) * e.char_h + e.char_h / 2, ""
	case .Scrollbar:
		l := ed.editor_scrollbar_layout(e)
		f := f32(w.col) / 100
		switch w.line {
		case 0, 2:
			if !l.v_shown {
				return 0, 0, "vertical scrollbar is not shown"
			}
			if w.line == 0 {
				return l.v_thumb.x + l.v_thumb.w / 2, l.v_thumb.y + l.v_thumb.h / 2, ""
			}
			return l.v_track.x + l.v_track.w / 2, l.v_track.y + l.v_track.h * f, ""
		case:
			if !l.h_shown {
				return 0, 0, "horizontal scrollbar is not shown"
			}
			if w.line == 1 {
				return l.h_thumb.x + l.h_thumb.w / 2, l.h_thumb.y + l.h_thumb.h / 2, ""
			}
			return l.h_track.x + l.h_track.w * f, l.h_track.y + l.h_track.h / 2, ""
		}
	case .Utility_Row:
		if e.window != .Utilities {
			return 0, 0, "utilities window is not open"
		}
		area := ed.editor_area_rect(e)
		return area.x + area.w / 4, ed.editor_utilities_layout(e) + f32(w.line) * e.char_h + e.char_h / 2, ""
	case .Theme_Row:
		if e.window != .Theme {
			return 0, 0, "theme editor is not open"
		}
		top, rows := ed.editor_theme_layout(e)
		r := w.line - e.theme_editor.scroll
		if r < 0 || r >= rows {
			return 0, 0, fmt.tprintf("theme row %d is not on screen", w.line)
		}
		area := ed.editor_area_rect(e)
		return area.x + area.w / 5, top + f32(r) * e.char_h + e.char_h / 2, ""
	case .Theme_Slider:
		if e.window != .Theme {
			return 0, 0, "theme editor is not open"
		}
		r := ed.editor_theme_slider_rect(e, w.line)
		return r.x + r.w * f32(w.col) / 100, r.y + r.h / 2, ""
	case .Keymap_Row:
		if e.window != .Keymap {
			return 0, 0, "keymap editor is not open"
		}
		top, rows := ed.editor_keymap_layout(e)
		r := w.line - e.keymap_editor.scroll
		if r < 0 || r >= rows {
			return 0, 0, fmt.tprintf("keymap row %d is not on screen", w.line)
		}
		area := ed.editor_area_rect(e)
		return area.x + area.w / 3, top + f32(r) * e.char_h + e.char_h / 2, ""
	case .Palette_Row:
		rect, rows, ok := ed.editor_palette_layout(e)
		if !ok {
			return 0, 0, "command palette is not open"
		}
		r := w.line - e.palette.scroll
		if r < 0 || r >= rows {
			return 0, 0, fmt.tprintf("palette row %d is not on screen", w.line)
		}
		return rect.x + rect.w / 2, rect.y + ed.POPUP_PAD + e.char_h + 4 + f32(r) * e.char_h + e.char_h / 2, ""
	case .Menu_Item:
		rect, ok := ed.editor_context_menu_layout(e)
		if !ok {
			return 0, 0, "context menu is not open"
		}
		return rect.x + rect.w / 2, rect.y + ed.POPUP_PAD + f32(w.line) * e.char_h + e.char_h / 2, ""
	case .Find_Part:
		l, ok := ed.editor_find_layout(e)
		if !ok {
			return 0, 0, "find bar is not open"
		}
		r: sdl.FRect
		switch w.line {
		case 0: r = l.query
		case 1: r = l.replace
		case 2: r = l.opt_case
		case 3: r = l.opt_word
		case 4: r = l.opt_regex
		}
		if r.w == 0 {
			return 0, 0, "that part of the find bar is not shown"
		}
		if w.line <= 1 {
			return r.x + 40, r.y + r.h / 2, ""
		}
		return r.x + r.w / 2, r.y + r.h / 2, ""
	case .Problem:
		if !e.problems.open {
			return 0, 0, "problems panel is not open"
		}
		row := w.line - e.problems.scroll
		if row < 0 || row >= ed.PROBLEMS_PANEL_ROWS - 1 || w.line >= len(ed.editor_problems(e)) {
			return 0, 0, fmt.tprintf("problem %d is not on screen", w.line)
		}
		top := e.origin_y + f32(ed.editor_text_rows(e)) * e.char_h
		return e.origin_x + 200, top + f32(row + 1) * e.char_h + e.char_h / 2, ""
	case .Completion:
		layout := ed.editor_popup_layout(e)
		cs := &e.completion
		if !layout.completion_visible {
			return 0, 0, "completion popup is not visible"
		}
		if w.line < cs.scroll || w.line >= min(cs.scroll + ed.COMPLETION_MAX_VISIBLE, len(cs.filtered)) {
			return 0, 0, fmt.tprintf("completion row %d is not on screen (first visible row %d)", w.line, cs.scroll)
		}
		row := w.line - cs.scroll
		return layout.completion.x + layout.completion.w / 2,
			layout.completion.y + ed.POPUP_PAD + f32(row) * e.char_h + e.char_h / 2, ""
	}
	return 0, 0, "bad target"
}

@(private)
run_mouse_command :: proc(srv: ^Server, e: ^ed.Editor, cmd: Command) -> string {
	#partial switch v in cmd {
	case Cmd_Locate:
		x, y, err := resolve_where(e, v.target)
		if err != "" {
			return strings.concatenate({"err ", err}, context.temp_allocator)
		}
		return fmt.tprintf("ok %.1f %.1f", x, y)
	case Cmd_Move:
		x, y, err := resolve_where(e, v.target)
		if err != "" {
			return strings.concatenate({"err ", err}, context.temp_allocator)
		}
		push_motion(srv, x, y, 0)
	case Cmd_Click:
		x, y, err := resolve_where(e, v.target)
		if err != "" {
			return strings.concatenate({"err ", err}, context.temp_allocator)
		}
		push_mods(srv, v.opts.mod, true)
		push_motion(srv, x, y, 0)
		// A double/triple click arrives as successive presses with a
		// rising click count, exactly as SDL reports real ones.
		for n in 1 ..= v.opts.clicks {
			push_button(srv, x, y, v.opts.button, u8(n), true)
			push_button(srv, x, y, v.opts.button, u8(n), false)
		}
		push_mods(srv, v.opts.mod, false)
	case Cmd_Mouse_Down:
		x, y, err := resolve_where(e, v.target)
		if err != "" {
			return strings.concatenate({"err ", err}, context.temp_allocator)
		}
		push_mods(srv, v.opts.mod, true)
		push_motion(srv, x, y, 0)
		push_button(srv, x, y, v.opts.button, u8(v.opts.clicks), true)
		push_mods(srv, v.opts.mod, false)
	case Cmd_Mouse_Up:
		x, y, err := resolve_where(e, v.target)
		if err != "" {
			return strings.concatenate({"err ", err}, context.temp_allocator)
		}
		push_button(srv, x, y, v.opts.button, u8(v.opts.clicks), false)
	case Cmd_Drag:
		x0, y0, err0 := resolve_where(e, v.from)
		if err0 != "" {
			return strings.concatenate({"err ", err0}, context.temp_allocator)
		}
		x1, y1, err1 := resolve_where(e, v.to)
		if err1 != "" {
			return strings.concatenate({"err ", err1}, context.temp_allocator)
		}
		push_motion(srv, x0, y0, 0)
		for n in 1 ..< v.opts.clicks {
			push_button(srv, x0, y0, 1, u8(n), true)
			push_button(srv, x0, y0, 1, u8(n), false)
		}
		push_button(srv, x0, y0, 1, u8(v.opts.clicks), true)
		// Modifiers go down after the press, like a person starting a
		// drag and then holding Alt/Ctrl to copy.
		push_mods(srv, v.opts.mod, true)
		for i in 1 ..= v.opts.steps {
			t := f32(i) / f32(v.opts.steps)
			push_motion(srv, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, 1)
		}
		push_button(srv, x1, y1, 1, u8(v.opts.clicks), false)
		push_mods(srv, v.opts.mod, false)
	case Cmd_Wheel:
		x, y := e.mouse.x, e.mouse.y
		if v.opts.has_at {
			err: string
			x, y, err = resolve_where(e, v.opts.at)
			if err != "" {
				return strings.concatenate({"err ", err}, context.temp_allocator)
			}
		}
		push_mods(srv, v.opts.mod, true)
		push_wheel(srv, x, y, v.opts.dx, v.dy)
		push_mods(srv, v.opts.mod, false)
	}
	return "ok"
}

// push_mods presses (or releases) the modifier keys in `mod`, so the
// gesture between them sees them held — SDL mouse events carry no
// modifier state of their own.
push_mods :: proc(srv: ^Server, mod: sdl.Keymod, down: bool) {
	keys := [4]struct {
		m: sdl.Keymod,
		k: sdl.Keycode,
	}{{sdl.KMOD_LSHIFT, sdl.K_LSHIFT}, {sdl.KMOD_LCTRL, sdl.K_LCTRL}, {sdl.KMOD_LALT, sdl.K_LALT}, {sdl.KMOD_LGUI, sdl.K_LGUI}}
	for entry in keys {
		if entry.m <= mod && entry.m != {} {
			ev: sdl.Event
			ev.type = .KEY_DOWN if down else .KEY_UP
			ev.key.windowID = window_id(srv)
			ev.key.which = INJECTED_DEVICE_ID
			ev.key.key = entry.k
			ev.key.scancode = sdl.GetScancodeFromKey(entry.k, nil)
			ev.key.mod = mod if down else {}
			ev.key.down = down
			ev.key.timestamp = sdl.GetTicksNS()
			_ = sdl.PushEvent(&ev)
		}
	}
}

push_button :: proc(srv: ^Server, x, y: f32, button: u8, clicks: u8, down: bool) {
	ev: sdl.Event
	ev.type = .MOUSE_BUTTON_DOWN if down else .MOUSE_BUTTON_UP
	ev.button.windowID = window_id(srv)
	ev.button.which = INJECTED_DEVICE_ID
	ev.button.button = button
	ev.button.down = down
	ev.button.clicks = clicks
	ev.button.x = x
	ev.button.y = y
	ev.button.timestamp = sdl.GetTicksNS()
	_ = sdl.PushEvent(&ev)
}

push_motion :: proc(srv: ^Server, x, y: f32, buttons: u32) {
	ev: sdl.Event
	ev.type = .MOUSE_MOTION
	ev.motion.windowID = window_id(srv)
	ev.motion.which = INJECTED_DEVICE_ID
	ev.motion.state = transmute(sdl.MouseButtonFlags)buttons
	ev.motion.x = x
	ev.motion.y = y
	ev.motion.timestamp = sdl.GetTicksNS()
	_ = sdl.PushEvent(&ev)
}

push_wheel :: proc(srv: ^Server, x, y, dx, dy: f32) {
	ev: sdl.Event
	ev.type = .MOUSE_WHEEL
	ev.wheel.windowID = window_id(srv)
	ev.wheel.which = INJECTED_DEVICE_ID
	ev.wheel.x = dx
	ev.wheel.y = dy
	ev.wheel.integer_x = i32(dx)
	ev.wheel.integer_y = i32(dy)
	ev.wheel.mouse_x = x
	ev.wheel.mouse_y = y
	ev.wheel.timestamp = sdl.GetTicksNS()
	_ = sdl.PushEvent(&ev)
}

// expect_binding checks "<action>=<chord>" (chord bound to action) or
// "<action>=none" (action has no bindings).
@(private)
expect_binding :: proc(e: ^ed.Editor, want: string) -> (pass: bool, actual: string) {
	eq := strings.index_byte(want, '=')
	if eq < 0 {
		return false, "want <action>=<chord>"
	}
	action, ok := km.action_from_name(strings.trim_space(want[:eq]))
	if !ok {
		return false, fmt.tprintf("unknown action %q", want[:eq])
	}
	chords := make([dynamic]string, context.temp_allocator)
	for c in km.keymap_chords_for(&e.keymap, action) {
		append(&chords, km.chord_format(c))
	}
	actual = strings.join(chords[:], ", ", context.temp_allocator)
	if len(chords) == 0 {
		actual = "none"
	}
	chord_text := strings.trim_space(want[eq + 1:])
	if chord_text == "none" {
		return len(chords) == 0, actual
	}
	chord, cok := km.chord_parse(chord_text)
	if !cok {
		return false, fmt.tprintf("bad chord %q", chord_text)
	}
	bound, bok := km.keymap_resolve(&e.keymap, chord)
	return bok && bound == action, actual
}

// expect_theme_color checks "<field>=<#hex>" against the editor's theme.
@(private)
expect_theme_color :: proc(e: ^ed.Editor, want: string) -> (pass: bool, actual: string) {
	eq := strings.index_byte(want, '=')
	if eq < 0 {
		return false, "want <field>=<#hex>"
	}
	i := ed.theme_field_index(strings.trim_space(want[:eq]))
	if i < 0 {
		return false, fmt.tprintf("unknown theme field %q", want[:eq])
	}
	c := ed.theme_color_ptr(&e.theme, i)^
	actual = ed.color_hex(c)
	wc, ok := ed.parse_color_hex(want[eq + 1:])
	return ok && wc == c, actual
}
