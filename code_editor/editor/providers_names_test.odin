package code_editor

import buf "../buffer"
import "core:fmt"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// What round 2 of the host's integration needs from the providers: quick fixes on their
// diagnostics, completions replacing more than the typed word (names in strings), characters
// that open the list for a provider, and the syntax context of a string being typed.

// A provider registry that knows one scene, "Forest", inside `go("...")` strings
@(private="file")
scenes_registry :: proc() -> Provider_Registry {
	reg: Provider_Registry
	provider_register(&reg, Provider{kind = .Diagnostics, name = "scenes", diagnostic = proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Provider_Diagnostic) {
		for i in 0 ..< buf.buffer_line_count(doc.buffer) {
			line := buf.buffer_line_str(doc.buffer, i)
			at := strings.index(line, `"Forrest"`)
			if at < 0 do continue
			edits := make([]Text_Edit, 1, ctx.allocator)
			edits[0] = {start = {i, at}, end = {i, at + 9}, text = `"Forest"`}
			constant := make([]Text_Edit, 1, ctx.allocator)
			constant[0] = {start = {i, at}, end = {i, at + 9}, text = "SCENE_FOREST"}
			fixes := make([]Provider_Fix, 2, ctx.allocator)
			fixes[0] = {title = `Replace with "Forest"`, edits = edits, preferred = true}
			fixes[1] = {title = "Use SCENE_FOREST", edits = constant}
			append(out, Provider_Diagnostic{start = {i, at}, end = {i, at + 9}, severity = .Warning, message = `No scene "Forrest": did you mean "Forest"?`, source = "crossfire", fixes = fixes})
		}
	}})
	provider_register(&reg, Provider{kind = .Completion, name = "scenes", trigger_chars = "\"/", completion = proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^[dynamic]Provider_Completion) {
		if !ctx.syntax.in_string do return
		line := buf.buffer_line_str(doc.buffer, pos.line)
		open := strings.last_index_byte(line[:pos.col], '"') + 1
		typed := line[open:pos.col]
		// What was typed before the word the list filters by ("Boss " of "Boss R")
		before := typed[:len(typed) - len(ctx.prefix)]
		for name in ([]string{"Forest", "Boss Room"}) {
			if !strings.has_prefix(name, before) do continue
			append(out, Provider_Completion{label = name, filter_text = name[len(before):], replace_start = open, priority = 5})
		}
	}})
	return reg
}

@(test)
test_provider_quick_fixes_in_the_code_actions_menu :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		reg := scenes_registry()
		defer provider_registry_destroy(&reg)
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "f :: proc() {\n\tgo(\"Forrest\")\n}\n")
		editor_set_providers(&ed, &reg)
		editor_run_cached_providers(&ed)
		testing.expect_value(t, len(editor_diagnostics(&ed)), 1)

		// An edit before it moves the fix with the problem
		ed.buf.cursors[0].pos = {1, 0}
		type_and_update(&ed, "\t")
		ed.buf.cursors[0].pos = {1, 8}
		// Without a server: the providers' fixes alone, at once, the preferred one selected
		key_and_update(&ed, sdl.K_PERIOD, sdl.KMOD_LCTRL)
		testing.expect(t, editor_code_actions_visible(&ed), "the fixes show without a server")
		testing.expect_value(t, editor_code_action_count(&ed), 2)
		title, preferred := editor_code_action_title(&ed, 0)
		testing.expect(t, title == `Replace with "Forest"` && preferred, "the preferred fix first")
		testing.expect_value(t, ed.actions.selected, 0)
		key_and_update(&ed, sdl.K_DOWN)
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, !ed.actions.active, "applied and closed")
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 1), "\t\tgo(SCENE_FOREST)")
		buf.buffer_undo(&ed.buf)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 1), "\t\tgo(\"Forrest\")")
		editor_run_cached_providers(&ed)

		// Elsewhere on the line: the line's fixes; on a line without a problem: no menu
		ed.buf.cursors[0].pos = {1, 0}
		editor_request_code_actions(&ed)
		testing.expect_value(t, editor_code_action_count(&ed), 2)
		testing.expect(t, editor_apply_code_action(&ed, 0), "the first fix")
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 1), "\t\tgo(\"Forest\")")
		editor_run_cached_providers(&ed)
		ed.buf.cursors[0].pos = {0, 0}
		editor_request_code_actions(&ed)
		testing.expect(t, !ed.actions.active, "nothing to fix and no server: no menu")
	})
}

@(test)
test_provider_fixes_come_before_the_servers_actions :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		reg := scenes_registry()
		defer provider_registry_destroy(&reg)
		ed := make_lsp_test_editor("go(\"Forrest\")")
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)
		editor_run_cached_providers(&ed)
		ed.buf.cursors[0].pos = {0, 5}
		editor_request_code_actions(&ed)
		testing.expect(t, ed.actions.waiting && editor_code_actions_visible(&ed), "the fixes show while the server answers")
		testing.expect_value(t, editor_code_action_count(&ed), 2)
		fake_code_actions(&ed, fmt.tprintf(`{{"title":"Server fix","kind":"quickfix","isPreferred":true,"edit":{{"changes":{{"%s":[` +
			`{{"range":{{"start":{{"line":0,"character":0}},"end":{{"line":0,"character":2}}}},"newText":"run"}}]}}}}}}`, ed.document_uri))
		editor_update(&ed)
		testing.expect_value(t, editor_code_action_count(&ed), 3)
		title, _ := editor_code_action_title(&ed, 2)
		testing.expect_value(t, title, "Server fix")
		testing.expect_value(t, ed.actions.selected, 0) // the provider's preferred fix stays selected
		testing.expect(t, editor_apply_code_action(&ed, 2), "the server's action")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "run(\"Forrest\")")
	})
}

@(test)
test_provider_trigger_characters_and_replace_start :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		reg := scenes_registry()
		defer provider_registry_destroy(&reg)
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)

		// '"' opens the list from the providers alone (the server isn't asked)
		type_and_update(&ed, "go(\"")
		testing.expect(t, editor_completion_visible(&ed), "the quote opened it")
		testing.expect(t, !ed.completion.waiting && ed.completion.providers_only, "no server request")
		testing.expect_value(t, len(ed.completion.filtered), 2)

		// A name with a space: "Boss R" filters by "R", and accepting replaces the whole name
		type_and_update(&ed, "Boss R")
		fake_completion_response(&ed, "")
		editor_update(&ed)
		testing.expect(t, editor_completion_visible(&ed), "listed again for the word after the space")
		sel, ok := editor_completion_selected_item(&ed)
		testing.expect(t, ok && sel.label == "Boss Room", "the name")
		testing.expect(t, editor_accept_completion(&ed), "accepted")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "go(\"Boss Room")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 13})
	})
}

@(test)
test_syntax_context_of_a_string_being_typed :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "f :: proc() {\n\te.Game_ChangeScene(game, \"Fo\n\tx := \"a\\\"\n\ty := \"done\"\n}")
		c := editor_syntax_context_at(&ed, {1, 29})
		testing.expect(t, c.kind == .Call_Argument && c.in_string && c.argument == 1 && c.call_name == "e.Game_ChangeScene", "the end of a string not closed yet")
		c = editor_syntax_context_at(&ed, {2, 10})
		testing.expect(t, c.in_string, "an escaped quote doesn't close it")
		c = editor_syntax_context_at(&ed, {3, 12})
		testing.expect(t, !c.in_string, "after a closed string")
	})
}
