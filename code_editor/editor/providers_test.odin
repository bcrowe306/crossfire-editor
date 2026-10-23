package code_editor

import buf "../buffer"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

// What the test providers report and count (their user data)
@(private="file")
Probe :: struct {
	completions, hovers, diagnostics, gutters, inlays, clicks, drops: int,
	clicked_id: int,
	syntax:     Syntax_Kind,
	call:       string,
	argument:   int,
}

@(private="file")
probe_registry :: proc(probe: ^Probe) -> Provider_Registry {
	reg: Provider_Registry
	provider_register(&reg, Provider{kind = .Completion, name = "project", user_data = probe, completion = proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^[dynamic]Provider_Completion) {
		p := (^Probe)(ctx.user_data)
		p.completions += 1
		append(out, Provider_Completion{label = "ANIM_HERO_RUN", detail = "animation", documentation = "hero.aseprite's run", kind = 21, priority = 10})
		// Also offered by the server: folds into its item
		append(out, Provider_Completion{label = "println", documentation = "From the project too"})
		// Offered twice: the first wins
		append(out, Provider_Completion{label = "ANIM_HERO_RUN", detail = "duplicate"})
	}})
	provider_register(&reg, Provider{kind = .Hover, name = "project", user_data = probe, hover = proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^Hover_Content) {
		p := (^Probe)(ctx.user_data)
		p.hovers += 1
		p.syntax = ctx.syntax.kind
		append(&out.blocks, Hover_Block(Hover_Text{text = "**Hero**: 3 nodes", markdown = true}))
		pixels := make([]u8, 4 * 4 * 4, ctx.allocator)
		append(&out.blocks, Hover_Block(Hover_Image{pixels = pixels, width = 4, height = 4}))
	}})
	provider_register(&reg, Provider{kind = .Diagnostics, name = "project", user_data = probe, diagnostic = proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Provider_Diagnostic) {
		p := (^Probe)(ctx.user_data)
		p.diagnostics += 1
		// "bad" on line 1, wherever it is now
		for i in 0 ..< buf.buffer_line_count(doc.buffer) {
			line := buf.buffer_line_str(doc.buffer, i)
			if at := strings.index(line, "bad"); at >= 0 {
				append(out, Provider_Diagnostic{start = {i, at}, end = {i, at + 3}, severity = .Warning, message = "bad is a project word", source = "crossfire"})
			}
		}
	}})
	provider_register(&reg, Provider{kind = .Gutter, name = "project", user_data = probe,
		gutter = proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Gutter_Marker) {
			p := (^Probe)(ctx.user_data)
			p.gutters += 1
			append(out, Gutter_Marker{line = 0, icon = .Diamond, tooltip = "Used by 3 nodes", id = 7})
		},
		on_click = proc(doc: Provider_Document, marker: Gutter_Marker, user_data: rawptr) {
			p := (^Probe)(user_data)
			p.clicks += 1
			p.clicked_id = marker.id
		},
	})
	provider_register(&reg, Provider{kind = .Inlay, name = "project", user_data = probe, inlay = proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Inlay_Hint) {
		p := (^Probe)(ctx.user_data)
		p.inlays += 1
		append(out, Inlay_Hint{pos = {0, 3}, label = "3 nodes", kind = .Note})
	}})
	provider_register(&reg, Provider{kind = .Drop, name = "nodes", user_data = probe, drop = proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, drop: Drop_Request, out: ^Drop_Result) -> bool {
		p := (^Probe)(ctx.user_data)
		p.drops += 1
		p.syntax = ctx.syntax.kind
		p.call = strings.clone(ctx.syntax.call_name, context.temp_allocator)
		p.argument = ctx.syntax.argument
		if drop.kind != "node" do return false
		if ctx.syntax.kind == .Call_Argument {
			append(&out.edits, Text_Edit{start = pos, end = pos, text = drop.value})
		} else {
			append(&out.edits, Text_Edit{start = {pos.line, 0}, end = {pos.line, 0}, text = "\tfield: int,\n"})
		}
		out.message = "dropped"
		return true
	}})
	return reg
}

@(test)
test_provider_completions_merge_with_the_servers :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		probe: Probe
		reg := probe_registry(&probe)
		defer provider_registry_destroy(&reg)
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)

		type_and_update(&ed, "p")
		testing.expect_value(t, probe.completions, 1)
		testing.expect(t, ed.completion.waiting, "waits for the server")
		fake_completion_response(&ed, `{"label":"println","kind":3},{"label":"printf","kind":3}`)
		editor_update(&ed)
		// println folded (the server's, with the provider's docs); ANIM_HERO_RUN once, though
		// offered twice; it doesn't match "p" so it's filtered out
		testing.expect_value(t, len(ed.completion.items), 3)
		testing.expect_value(t, len(ed.completion.filtered), 2)
		item := editor_completion_item(&ed, 0)
		testing.expect_value(t, item.label, "println")
		testing.expect(t, editor_completion_item_provided(&ed, 0), "println was folded into")
		testing.expect(t, strings.contains(item.documentation, "From the project too"), "the provider's docs added")

		// Backspace, then the empty prefix: the provider's priority puts its item first
		editor_close_completion(&ed)
		key_and_update(&ed, sdl.K_BACKSPACE)
		editor_request_completion(&ed)
		fake_completion_response(&ed, `{"label":"println","kind":3},{"label":"printf","kind":3}`)
		editor_update(&ed)
		testing.expect(t, editor_completion_visible(&ed), "listed")
		sel, ok := editor_completion_selected_item(&ed)
		testing.expect(t, ok && sel.label == "ANIM_HERO_RUN" && sel.detail == "animation", "priority 10 first; the first provider's copy")
		testing.expect(t, editor_accept_completion(&ed), "accepted")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "ANIM_HERO_RUN")
	})
}

@(test)
test_provider_completions_without_a_server :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		probe: Probe
		reg := probe_registry(&probe)
		defer provider_registry_destroy(&reg)
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)
		// Typed in one burst (faster than frames): the list follows the last word
		type_and_update(&ed, "go AN")
		testing.expect(t, editor_completion_visible(&ed), "the providers' items show at once")
		testing.expect_value(t, ed.completion.anchor, buf.Position{0, 3})
		sel, ok := editor_completion_selected_item(&ed)
		testing.expect(t, ok && sel.label == "ANIM_HERO_RUN", "the project's item")
		type_and_update(&ed, "IMX")
		testing.expect(t, !editor_completion_visible(&ed), "nothing matches: closed")
	})
}

@(test)
test_provider_hover_blocks_and_gutter_tooltips :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		probe: Probe
		reg := probe_registry(&probe)
		defer provider_registry_destroy(&reg)
		ed := make_diag_editor("Hero :: struct {\n\tspeed: f32,\n}")
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)
		editor_run_cached_providers(&ed)

		mouse_move(&ed, editor_gutter_width(&ed) + 1 * 10 + 5, 10) // over "Hero"
		ed.diag_tip.hover_since = time.tick_add(time.tick_now(), -DIAG_HOVER_DELAY)
		editor_update(&ed)
		testing.expect(t, ed.hover.visible && ed.hover.requested, "the provider's blocks show at once; the server is asked")
		testing.expect_value(t, probe.hovers, 1)
		testing.expect_value(t, probe.syntax, Syntax_Kind.Top_Level)
		_, lines, ok := editor_hover_layout(&ed)
		testing.expect(t, ok && lines[0].text == "Hero: 3 nodes", "markdown text first")
		image_lines := 0
		for l in lines do if l.block == 2 do image_lines += 1
		testing.expect_value(t, image_lines, 1) // 4 px: one line
		fake_hover(&ed, `{"contents":{"kind":"plaintext","value":"Hero :: struct"}}`)
		editor_update(&ed)
		_, lines, ok = editor_hover_layout(&ed)
		testing.expect(t, ok && lines[len(lines) - 1].text == "Hero :: struct", "the server's answer after the providers'")

		// The gutter: the marker's tooltip, no server request
		id := ed.lsp.latest_hover_id
		mouse_move(&ed, 4, 10)
		ed.diag_tip.hover_since = time.tick_add(time.tick_now(), -DIAG_HOVER_DELAY)
		editor_update(&ed)
		_, lines, ok = editor_hover_layout(&ed)
		testing.expect(t, ok && ed.hover.line_only && lines[0].text == "Used by 3 nodes", "a marker's tooltip")
		testing.expect_value(t, ed.lsp.latest_hover_id, id)

		// A click on the marker column calls the marker's callback
		mouse_click(&ed, editor_gutter_width(&ed) - 4, 10)
		testing.expect(t, probe.clicks == 1 && probe.clicked_id == 7, "the click callback got its marker")
	})
}

@(test)
test_provider_diagnostics_merge_shift_and_debounce :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		probe: Probe
		reg := probe_registry(&probe)
		defer provider_registry_destroy(&reg)
		ed := make_diag_editor("x := 1\ny := bad")
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)
		editor_update(&ed)
		testing.expect_value(t, probe.diagnostics, 1)
		diags := editor_diagnostics(&ed)
		testing.expect(t, len(diags) == 1 && diags[0].provided && diags[0].start == {1, 5} && diags[0].source == "crossfire", "the provider's warning")

		// The server's: merged; one with the same line and message isn't repeated
		publish(&ed, {{0, 0, 0, 1, 1, "server error"}, {1, 5, 1, 8, 2, "bad is a project word"}})
		diags = editor_diagnostics(&ed)
		testing.expect_value(t, len(diags), 2)

		// An edit: the provider's diagnostic moves with it at once; providers wait for the text to be still
		ed.buf.cursors[0].pos = {1, 0}
		type_and_update(&ed, "  ")
		testing.expect_value(t, probe.diagnostics, 1)
		testing.expect_value(t, ed.provided.diagnostics[0].start, buf.Position{1, 7})
		testing.expect_value(t, len(editor_diagnostics(&ed)), 2)
		ed.provided.changed_at = time.tick_add(time.tick_now(), -PROVIDER_DEBOUNCE)
		editor_update(&ed)
		testing.expect_value(t, probe.diagnostics, 2)
		testing.expect_value(t, len(ed.provided.inlays), 1)
		testing.expect_value(t, editor_inlays_on(&ed, 0)[0].label, "3 nodes")
		testing.expect_value(t, len(editor_gutter_markers_on(&ed, 0)), 1)
		testing.expect_value(t, len(editor_gutter_markers_on(&ed, 1)), 0)

		// Invalidating asks again without an edit
		provider_registry_invalidate(&reg)
		editor_update(&ed)
		testing.expect_value(t, probe.diagnostics, 3)
		for s in editor_provider_stats(&ed) do if s.kind == .Diagnostics do testing.expect_value(t, s.calls, 3)
	})
}

@(test)
test_provider_diagnostics_without_a_server :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		probe: Probe
		reg := probe_registry(&probe)
		defer provider_registry_destroy(&reg)
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "bad")
		editor_set_providers(&ed, &reg)
		editor_update(&ed)
		testing.expect_value(t, len(editor_diagnostics(&ed)), 1)
		counts := editor_diagnostic_counts(&ed)
		testing.expect_value(t, counts[.Warning], 1)
		// Replacing the text drops them until the providers run again
		editor_set_text(&ed, "good")
		testing.expect_value(t, len(editor_diagnostics(&ed)), 0)
	})
}

@(test)
test_syntax_contexts :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, `package scripts

Hero :: struct {
	using script: e.Script,
	cb: proc(x: int),
	speed: f32,
}

@(init)
register_Hero :: proc "contextless" () {
	e.Script_Register(Hero, {
		ready = proc(self: ^Hero) {
			if self.speed > 0 {
				x := e.Node_FindPath(self.node, "Sword")
			}
			// a comment
		},
	})
}
`)
		at :: proc(ed: ^Editor, line, col: int) -> Syntax_Context {
			return editor_syntax_context_at(ed, {line, col})
		}
		c := at(&ed, 5, 1)
		testing.expect(t, c.kind == .Struct_Body && c.name == "Hero", "inside the struct (after a proc-typed field)")
		testing.expect_value(t, c.open, buf.Position{2, 15})
		testing.expect_value(t, c.close, buf.Position{6, 0})
		testing.expect_value(t, at(&ed, 7, 0).kind, Syntax_Kind.Top_Level)
		c = at(&ed, 13, 3)
		testing.expect(t, c.kind == .Proc_Body && c.proc_name == "ready" && c.in_proc, "the hook's body, through an if block")
		c = at(&ed, 13, 27)
		testing.expect(t, c.kind == .Call_Argument && c.call_name == "e.Node_FindPath" && c.argument == 0, "the first argument")
		c = at(&ed, 13, 39)
		testing.expect(t, c.kind == .Call_Argument && c.argument == 1 && c.in_string && c.proc_name == "ready", "inside the string argument")
		c = at(&ed, 11, 22)
		testing.expect(t, c.kind == .Call_Argument && c.call_name == "e.Script_Register" && c.argument == 1, "the hooks literal")
		c = at(&ed, 15, 6)
		testing.expect(t, c.kind == .Comment && c.in_proc, "a comment in the proc")
		c = at(&ed, 10, 0)
		testing.expect(t, c.kind == .Proc_Body && c.proc_name == "register_Hero", "a contextless proc's body")
	})
}

@(test)
test_provider_drops_by_context :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		probe: Probe
		reg := probe_registry(&probe)
		defer provider_registry_destroy(&reg)
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)
		editor_set_text(&ed, "Hero :: struct {\n}\nf :: proc() {\n\tg(1, )\n}\n")

		msg, ok := editor_drop_at(&ed, {3, 6}, Drop_Request{kind = "node", value = "PATH_HUD"})
		testing.expect(t, ok && msg == "dropped", "taken")
		testing.expect(t, probe.syntax == .Call_Argument && probe.call == "g" && probe.argument == 1, "on g's second argument")
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 3), "\tg(1, PATH_HUD)")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{3, 14})

		_, ok = editor_drop_at(&ed, {1, 0}, Drop_Request{kind = "node", value = "x"})
		testing.expect(t, ok && probe.syntax == .Struct_Body, "in the struct: a field")
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 1), "\tfield: int,")
		buf.buffer_undo(&ed.buf)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 1), "}")

		_, ok = editor_drop_at(&ed, {1, 0}, Drop_Request{kind = "sound"})
		testing.expect(t, !ok, "a kind no provider takes")
	})
}
