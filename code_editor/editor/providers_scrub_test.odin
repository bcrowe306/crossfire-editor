package code_editor

import buf "../buffer"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// What the scrub, menu, gutter-line and clickable-inlay providers heard (their user data)
@(private="file")
Scrub_Probe :: struct {
	changes:      [dynamic]string,
	ended:        int,
	end_text:     string,
	choice:       int,
	choice_text:  string,
	menu_index:   int,
	menu_line:    int,
	gutter_line:  int,
	inlay_choice: int,
	inlay_clicks: int,
}

@(private="file")
scrub_registry :: proc(probe: ^Scrub_Probe) -> Provider_Registry {
	reg: Provider_Registry
	// "speed: f32 `export:\"default=250 min=0 max=300\"`": 250 can be scrubbed, starting from the
	// running game's 260
	provider_register(&reg, Provider{kind = .Scrub, name = "numbers", user_data = probe,
		scrub_target = proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^Scrub_Target) -> bool {
			line := buf.buffer_line_str(doc.buffer, pos.line)
			at := strings.index(line, "250")
			if at < 0 || pos.col < at || pos.col > at + 3 do return false
			out^ = {start = {pos.line, at}, end = {pos.line, at + 3}, value = 260, step = 0, decimals = -1, max = 300, id = 7}
			return true
		},
		on_scrub = proc(doc: Provider_Document, target: Scrub_Target, value: f64, text: string, phase: Scrub_Phase, user_data: rawptr, choices: ^[dynamic]string) {
			p := (^Scrub_Probe)(user_data)
			switch phase {
			case .Change: append(&p.changes, strings.clone(text))
			case .End:
				p.ended += 1
				delete(p.end_text)
				p.end_text = strings.clone(text)
				append(choices, "Keep it in the game", "Write it to the default")
			}
		},
		on_scrub_choice = proc(doc: Provider_Document, target: Scrub_Target, value: f64, text: string, choice: int, user_data: rawptr) {
			p := (^Scrub_Probe)(user_data)
			p.choice = choice
			delete(p.choice_text)
			p.choice_text = strings.clone(text)
		},
	})
	provider_register(&reg, Provider{kind = .Menu, name = "log points", user_data = probe,
		menu_items = proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^[dynamic]string) {
			append(out, "Add Log Point...", "Something else")
		},
		on_menu_item = proc(doc: Provider_Document, pos: buf.Position, index: int, user_data: rawptr) {
			p := (^Scrub_Probe)(user_data)
			p.menu_index = index
			p.menu_line = pos.line
		},
	})
	provider_register(&reg, Provider{kind = .Gutter, name = "log points", user_data = probe,
		gutter = proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Gutter_Marker) {
			append(out, Gutter_Marker{line = 2, icon = .Diamond, tooltip = "a log point"})
		},
		on_click = proc(doc: Provider_Document, marker: Gutter_Marker, user_data: rawptr) {},
		on_gutter_line = proc(doc: Provider_Document, line: int, user_data: rawptr) -> bool {
			p := (^Scrub_Probe)(user_data)
			p.gutter_line = line
			return true
		},
	})
	provider_register(&reg, Provider{kind = .Inlay, name = "live", user_data = probe,
		inlay = proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Inlay_Hint) {
			choices := make([]string, 2, ctx.allocator)
			choices[0], choices[1] = "Hero", "Hero2"
			append(out, Inlay_Hint{pos = {0, 13}, label = "live: Hero", clickable = true, choices = choices, id = 3})
			append(out, Inlay_Hint{pos = {1, 1}, label = "= 260", kind = .Value, id = 4})
		},
		on_inlay_click = proc(doc: Provider_Document, hint: Inlay_Hint, user_data: rawptr) {
			p := (^Scrub_Probe)(user_data)
			p.inlay_clicks += 1
			p.inlay_choice = hint.choice
		},
	})
	return reg
}

@(private="file")
scrub_probe_free :: proc(p: ^Scrub_Probe) {
	for c in p.changes do delete(c)
	delete(p.changes)
	delete(p.end_text)
	delete(p.choice_text)
}

@(private="file")
right_click :: proc(ed: ^Editor, x, y: f32) {
	ev: sdl.Event
	ev.type = .MOUSE_BUTTON_DOWN
	ev.button.button = 3
	ev.button.down = true
	ev.button.clicks = 1
	ev.button.x, ev.button.y = x, y
	editor_handle_event(ed, ev)
	ev.type = .MOUSE_BUTTON_UP
	ev.button.down = false
	editor_handle_event(ed, ev)
}

SCRUB_TEST_TEXT :: "Hero :: struct {\n\tspeed: f32 `export:\"default=250 max=300\"`,\n\tx := 1\n}\n"

// The step from a literal, the value a drag reaches (rounded, in range, finer with Shift), the text
@(test)
test_scrub_mapping :: proc(t: ^testing.T) {
	step, decimals := scrub_step({decimals = -1}, "250")
	testing.expect_value(t, step, 1)
	testing.expect_value(t, decimals, 0)
	step, decimals = scrub_step({decimals = -1}, "0.45")
	testing.expect(t, abs(step - 0.01) < 1e-12, "a hundredth")
	testing.expect_value(t, decimals, 2)
	step, decimals = scrub_step({decimals = -1, step = 0.25}, "1")
	testing.expect_value(t, decimals, 2)
	step, decimals = scrub_step({decimals = -1, integer = true, step = 0.3}, "4")
	testing.expect_value(t, step, 1)
	testing.expect_value(t, decimals, 0)

	target := Scrub_Target{min = 0, max = 300}
	testing.expect_value(t, scrub_value(target, 250, 1, 40, 4), 260)
	testing.expect_value(t, scrub_value(target, 250, 1, -41, 4), 240)
	testing.expect_value(t, scrub_value(target, 250, 1, 1000, 4), 300)
	testing.expect_value(t, scrub_value(target, 250, 1, -5000, 4), 0)
	testing.expect(t, abs(scrub_value(target, 250, 1, 40, 4, fine = true) - 251) < 1e-9, "a tenth of a step")
	testing.expect(t, abs(scrub_value({}, 0.45, 0.01, 12, 4) - 0.48) < 1e-9, "three hundredths")
	testing.expect_value(t, scrub_value({integer = true}, 3, 1, 8, 4, fine = true), 5)

	testing.expect_value(t, scrub_format(260, 0), "260")
	testing.expect_value(t, scrub_format(0.48, 2), "0.48")
	testing.expect_value(t, scrub_format(-0.001, 2), "0.00")
	testing.expect_value(t, scrub_format(-0.4, 0, integer = true), "0")
	testing.expect_value(t, scrub_format(12.5, 1), "12.5")
	free_all(context.temp_allocator)
}

// Alt+drag on a number a provider can scrub: values while dragging (from the provider's start, the
// buffer untouched), the release's choices in the menu, the one picked; Alt+click still adds a cursor
@(test)
test_provider_scrubs_a_number :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		probe: Scrub_Probe
		defer scrub_probe_free(&probe)
		reg := scrub_registry(&probe)
		defer provider_registry_destroy(&reg)
		ed := make_diag_editor(SCRUB_TEST_TEXT)
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)
		at := strings.index(buf.buffer_line_str(&ed.buf, 1), "250")
		x, y, ok := editor_text_point(&ed, {1, at + 1})
		testing.expect(t, ok, "the literal is in view")
		version := ed.buf.version

		modifier_key(&ed, sdl.K_LALT, true)
		mouse_button(&ed, true, x, y)
		testing.expect(t, ed.scrub.pending && !ed.scrub.active, "pending until it moves")
		mouse_move(&ed, x + 1, y)
		testing.expect(t, !ed.scrub.active, "under the threshold")
		// 5 px a step at a 10 px cell: 8 steps
		mouse_move(&ed, x + 40, y)
		testing.expect(t, editor_scrubbing(&ed), "scrubbing")
		testing.expect_value(t, editor_scrub_text(&ed), "268")
		testing.expect_value(t, editor_mouse_cursor(&ed), Mouse_Cursor.Scrub)
		// Within the same step: nothing new
		mouse_move(&ed, x + 42, y)
		testing.expect_value(t, len(probe.changes), 1)
		mouse_move(&ed, x + 1000, y)
		testing.expect_value(t, editor_scrub_text(&ed), "300")
		mouse_move(&ed, x - 20, y)
		testing.expect_value(t, editor_scrub_text(&ed), "256")
		testing.expect_value(t, ed.buf.version, version)
		mouse_button(&ed, false, x - 20, y)
		modifier_key(&ed, sdl.K_LALT, false)
		testing.expect(t, !editor_scrubbing(&ed), "over")
		testing.expect_value(t, probe.ended, 1)
		testing.expect_value(t, probe.end_text, "256")
		testing.expect_value(t, len(probe.changes), 3)
		testing.expect(t, editor_code_actions_visible(&ed), "the choices in the menu")
		testing.expect_value(t, editor_code_action_count(&ed), 2)
		title, _ := editor_code_action_title(&ed, 1)
		testing.expect_value(t, title, "Write it to the default")
		testing.expect(t, editor_apply_code_action(&ed, 1), "picked")
		testing.expect_value(t, probe.choice, 1)
		testing.expect_value(t, probe.choice_text, "256")
		testing.expect_value(t, ed.buf.version, version)

		// An Alt+click that doesn't move: a cursor added there, no scrub
		modifier_key(&ed, sdl.K_LALT, true)
		mouse_click(&ed, x, y)
		modifier_key(&ed, sdl.K_LALT, false)
		testing.expect_value(t, len(ed.buf.cursors), 2)
		testing.expect_value(t, probe.ended, 1)
		// Elsewhere Alt+click is as before
		ox, oy := px(&ed, 2, 2)
		modifier_key(&ed, sdl.K_LALT, true)
		mouse_click(&ed, ox, oy)
		modifier_key(&ed, sdl.K_LALT, false)
		testing.expect_value(t, len(ed.buf.cursors), 3)
		free_all(context.temp_allocator)
	})
}

// The host's right-click entries after the editor's; the marker column of a line without a marker
// goes to a gutter provider's on_gutter_line; a clickable hint with choices opens their menu
@(test)
test_provider_menu_items_gutter_lines_and_clickable_hints :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		probe := Scrub_Probe{menu_index = -1, gutter_line = -1, inlay_choice = -1}
		defer scrub_probe_free(&probe)
		reg := scrub_registry(&probe)
		defer provider_registry_destroy(&reg)
		ed := make_diag_editor(SCRUB_TEST_TEXT)
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)
		editor_run_cached_providers(&ed)

		// The menu, on line 3
		mx, my := px(&ed, 2, 1)
		right_click(&ed, mx, my)
		items := editor_context_menu_items(&ed)
		testing.expect_value(t, items[len(items) - 2].label, "Add Log Point...")
		testing.expect_value(t, items[len(items) - 3].label, "")
		editor_context_menu_activate(&ed, len(items) - 2)
		testing.expect_value(t, probe.menu_index, 0)
		testing.expect_value(t, probe.menu_line, 2)
		testing.expect(t, !ed.menu.open, "closed")

		// The marker column: line 2 has a marker (its click), line 1 none (the provider's)
		gx, gy, ok := editor_marker_column_point(&ed, 1)
		testing.expect(t, ok, "line 2 is in view")
		mouse_click(&ed, gx, gy)
		testing.expect_value(t, probe.gutter_line, 1)
		probe.gutter_line = -1
		gx, gy, _ = editor_marker_column_point(&ed, 2)
		mouse_click(&ed, gx, gy)
		testing.expect_value(t, probe.gutter_line, -1)

		// A clickable hint's label: its menu, then the choice
		hx, hy, found := editor_inlay_label_point(&ed, 0, 0)
		testing.expect(t, found, "the clickable hint is in view")
		_, _, found = editor_inlay_label_point(&ed, 1, 0)
		testing.expect(t, !found, "a plain hint isn't clickable")
		mouse_click(&ed, hx, hy)
		testing.expect(t, editor_code_actions_visible(&ed), "its choices")
		testing.expect_value(t, editor_code_action_count(&ed), 2)
		testing.expect(t, editor_apply_code_action(&ed, 1), "picked")
		testing.expect_value(t, probe.inlay_clicks, 1)
		testing.expect_value(t, probe.inlay_choice, 1)
		free_all(context.temp_allocator)
	})
}
