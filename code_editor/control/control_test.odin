package control

import ed "../editor"
import "core:encoding/json"
import "core:mem"
import "core:testing"
import sdl "vendor:sdl3"

run_leak_free :: proc(t: ^testing.T, body: proc(t: ^testing.T)) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	old := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	body(t)
	context.allocator = old

	for _, entry in track.allocation_map {
		testing.expectf(t, false, "Memory leak: %v bytes at %v", entry.size, entry.location)
	}
	for bf in track.bad_free_array {
		testing.expectf(t, false, "Bad free: %p at %v", bf.memory, bf.location)
	}
}

@(test)
test_parse_chord_plain_and_named_keys :: proc(t: ^testing.T) {
	key, mod, ok := parse_chord("down", .Other)
	testing.expect(t, ok, "named key parses")
	testing.expect_value(t, key, sdl.K_DOWN)
	testing.expect_value(t, mod, sdl.Keymod{})

	key, _, ok = parse_chord("A", .Other)
	testing.expect(t, ok && key == sdl.K_A, "letters are case-insensitive")

	key, _, ok = parse_chord(".", .Other)
	testing.expect(t, ok && key == sdl.K_PERIOD, "punctuation maps to its keycode")

	_, _, ok = parse_chord("nosuchkey", .Other)
	testing.expect(t, !ok, "unknown key name rejected")
	_, _, ok = parse_chord("hyper+a", .Other)
	testing.expect(t, !ok, "unknown modifier rejected")
}

@(test)
test_parse_chord_modifiers_and_primary :: proc(t: ^testing.T) {
	key, mod, ok := parse_chord("primary+shift+space", .MacOS)
	testing.expect(t, ok, "chord parses")
	testing.expect_value(t, key, sdl.K_SPACE)
	testing.expect_value(t, mod, sdl.KMOD_LGUI | sdl.KMOD_LSHIFT)

	_, mod, ok = parse_chord("primary+space", .Other)
	testing.expect(t, ok && mod == sdl.KMOD_LCTRL, "primary is Ctrl off macOS")

	_, mod, ok = parse_chord("Ctrl+Alt+Cmd+x", .Other)
	testing.expect(t, ok && mod == sdl.KMOD_LCTRL | sdl.KMOD_LALT | sdl.KMOD_LGUI, "modifier names are case-insensitive")

	key, mod, ok = parse_chord("ctrl++", .Other)
	testing.expect(t, ok && key == sdl.K_PLUS && mod == sdl.KMOD_LCTRL, "trailing '+' is the plus key")
}

@(test)
test_parse_command_variants :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		cmd, err := parse_command("key down 3", .Other)
		k, is_key := cmd.(Cmd_Key)
		testing.expect(t, is_key && k.key == sdl.K_DOWN && k.count == 3, err)

		cmd, err = parse_command("type fmt.pri  ", .Other)
		ty, is_type := cmd.(Cmd_Type)
		testing.expect(t, is_type, err)
		testing.expect_value(t, ty.text, "fmt.pri  ") // payload spaces preserved
		command_destroy(cmd)

		cmd, err = parse_command("text a\\nb\\t\\\\", .Other)
		tx, is_text := cmd.(Cmd_Text)
		testing.expect(t, is_text, err)
		testing.expect_value(t, tx.text, "a\nb\t\\")
		command_destroy(cmd)

		cmd, err = parse_command("wait completion 2500", .Other)
		w, is_wait := cmd.(Cmd_Wait)
		testing.expect(t, is_wait && w.cond == .Completion && w.amount == 2500, err)

		cmd, _ = parse_command("wait no-signature", .Other)
		w, _ = cmd.(Cmd_Wait)
		testing.expect_value(t, w.amount, DEFAULT_WAIT_TIMEOUT_MS)

		cmd, _ = parse_command("wait frames", .Other)
		w, _ = cmd.(Cmd_Wait)
		testing.expect(t, w.cond == .Frames && w.amount == 1, "frames defaults to 1")

		cmd, err = parse_command("click 10.5 20", .Other)
		cl, is_click := cmd.(Cmd_Click)
		testing.expect(t, is_click && cl.target.kind == .Pixels && cl.target.x == 10.5 && cl.target.y == 20, err)
		testing.expect(t, cl.opts.clicks == 1 && cl.opts.button == 1, "click defaults to one left click")

		cmd, err = parse_command("cursor 4 2\r\n", .Other)
		cu, is_cursor := cmd.(Cmd_Cursor)
		testing.expect(t, is_cursor && cu.line == 4 && cu.col == 2, err)

		cmd, err = parse_command("expect signature-param b: int", .Other)
		ex, is_expect := cmd.(Cmd_Expect)
		testing.expect(t, is_expect && ex.field == .Signature_Param && ex.want == "b: int", err)
		command_destroy(cmd)

		cmd, err = parse_command("screenshot /tmp/x.png", .Other)
		sc, is_shot := cmd.(Cmd_Screenshot)
		testing.expect(t, is_shot && sc.path == "/tmp/x.png", err)
		command_destroy(cmd)
	})
}

@(test)
test_parse_command_errors :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		bad := []string{"", "frobnicate", "key", "key down 0", "key bogus", "wait sometimes", "click 1", "type", "cursor x y", "expect nonsense 1"}
		for line in bad {
			cmd, err := parse_command(line, .Other)
			testing.expectf(t, cmd == nil && len(err) > 0, "expected %q to be rejected", line)
		}
	})
}

@(test)
test_state_json_reports_editor_and_popups :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		e := ed.editor_init(.Other)
		defer ed.editor_destroy(&e)
		ed.editor_set_text(&e, "alpha\nbeta")
		e.buf.cursors[0].pos = {1, 2}

		text := state_json(&e, 7)
		value, err := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
		testing.expectf(t, err == nil, "state is valid JSON: %v\n%s", err, text)
		obj, is_obj := value.(json.Object)
		testing.expectf(t, is_obj, "state is a JSON object: %s", text)
		if !is_obj {
			return
		}
		frame, _ := obj["frame"].(json.Integer)
		testing.expect_value(t, frame, 7)
		line, _ := obj["current_line"].(json.String)
		testing.expect_value(t, line, "beta")
		full, _ := obj["text"].(json.String)
		testing.expect_value(t, full, "alpha\nbeta")
		cursor, _ := obj["cursor"].(json.Array)
		testing.expectf(t, len(cursor) == 2, "cursor is [line, col]: %s", text)
		if len(cursor) == 2 {
			l, _ := cursor[0].(json.Integer)
			c, _ := cursor[1].(json.Integer)
			testing.expect_value(t, l, 1)
			testing.expect_value(t, c, 2)
		}
		completion, _ := obj["completion"].(json.Object)
		visible, has_visible := completion["visible"].(json.Boolean)
		testing.expect(t, has_visible && !visible, "completion.visible is false")
		lsp, _ := obj["lsp"].(json.Object)
		enabled, has_enabled := lsp["enabled"].(json.Boolean)
		testing.expect(t, has_enabled && !enabled, "lsp.enabled is false")
	})
}

@(test)
test_parse_mouse_commands :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		cmd, err := parse_command("click @3:5 clicks=2 mods=shift+alt", .Other)
		cl, ok := cmd.(Cmd_Click)
		testing.expect(t, ok, err)
		testing.expect(t, cl.target.kind == .Text && cl.target.line == 3 && cl.target.col == 5, "text target")
		testing.expect_value(t, cl.opts.clicks, 2)
		testing.expect_value(t, cl.opts.mod, sdl.KMOD_LSHIFT | sdl.KMOD_LALT)

		cmd, err = parse_command("drag @gutter:1 400 900.5 steps=3", .Other)
		dr, okd := cmd.(Cmd_Drag)
		testing.expect(t, okd, err)
		testing.expect(t, dr.from.kind == .Gutter && dr.from.line == 1, "gutter source")
		testing.expect(t, dr.to.kind == .Pixels && dr.to.x == 400 && dr.to.y == 900.5, "pixel destination")
		testing.expect_value(t, dr.opts.steps, 3)

		cmd, err = parse_command("wheel -2 dx=1 at=@completion:4 mods=primary", .MacOS)
		wh, okw := cmd.(Cmd_Wheel)
		testing.expect(t, okw, err)
		testing.expect(t, wh.dy == -2 && wh.opts.dx == 1, "wheel amounts")
		testing.expect(t, wh.opts.has_at && wh.opts.at.kind == .Completion && wh.opts.at.line == 4, "wheel position")
		testing.expect_value(t, wh.opts.mod, sdl.KMOD_LGUI)

		cmd, err = parse_command("click @2:0 button=right", .Other)
		cl, _ = cmd.(Cmd_Click)
		testing.expect_value(t, cl.opts.button, 3)

		cmd, err = parse_command("expect selection 0 1 2 3", .Other)
		ex, _ := cmd.(Cmd_Expect)
		testing.expect(t, ex.field == .Selection, err)
		command_destroy(cmd)

		bad := []string{"click", "click @x", "click @1:2 clicks=0", "click 1 2 frob=1", "drag @1:1", "wheel", "move @gutter:", "click @1:2 mods=hyper"}
		for line in bad {
			c, e := parse_command(line, .Other)
			testing.expectf(t, c == nil && len(e) > 0, "expected %q to be rejected", line)
		}
	})
}

@(test)
test_key_action_reference_resolves_per_platform :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		cmd, err := parse_command("key @Replace 2", .MacOS)
		k, ok := cmd.(Cmd_Key)
		testing.expect(t, ok && k.action == "Replace" && k.count == 2, err)
		command_destroy(cmd)

		mac := ed.editor_init(.MacOS)
		defer ed.editor_destroy(&mac)
		key, mod, found := chord_for_action(&mac, "replace")
		testing.expect(t, found && key == sdl.K_F && mod == sdl.KMOD_LALT | sdl.KMOD_LGUI, "Cmd+Alt+F on macOS")

		other := ed.editor_init(.Other)
		defer ed.editor_destroy(&other)
		key, mod, found = chord_for_action(&other, "Replace")
		testing.expect(t, found && key == sdl.K_H && mod == sdl.KMOD_LCTRL, "Ctrl+H elsewhere")
		_, _, found = chord_for_action(&other, "no_such_action")
		testing.expect(t, !found, "unknown action")
	})
}
