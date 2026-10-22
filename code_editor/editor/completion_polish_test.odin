package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:fmt"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_parse_snippet_grammar :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		text, stops := parse_snippet("println($0)", context.temp_allocator)
		testing.expect_value(t, text, "println()")
		testing.expect(t, len(stops) == 1 && stops[0].index == 0 && stops[0].start == 8, "final stop inside parens")

		text, stops = parse_snippet("for ${1:i} in 0..<${2:n} {\n\t$0\n}", context.temp_allocator)
		testing.expect_value(t, text, "for i in 0..<n {\n\t\n}")
		testing.expect_value(t, stops[0], Snippet_Stop{1, 4, 5})
		testing.expect_value(t, stops[1], Snippet_Stop{2, 13, 14})

		text, _ = parse_snippet("${1:outer ${2:inner}} \\$x ${3|a,b|} $TM_FILENAME ${VAR:def}", context.temp_allocator)
		testing.expect_value(t, text, "outer inner $x a  def")
	})
}

@(private)
fake_completion_list :: proc(ed: ^Editor, items_json: string, incomplete := false) {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":{{"isIncomplete":%v,"items":[%s]}}}}`, ed.lsp.latest_completion_id, incomplete, items_json)
	lspc.client_feed_bytes(&ed.lsp, transmute([]u8)lspc.frame_message(body, context.temp_allocator))
}

@(test)
test_snippet_completion_session :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		type_and_update(&ed, "fo")
		fake_completion_list(&ed, `{"label":"for","kind":15,"insertTextFormat":2,"insertText":"for ${1:i} in 0..<${2:n} {\n\t$0\n}"}`)
		editor_update(&ed)
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "for i in 0..<n {\n\t\n}")
		testing.expect(t, ed.snippet.active, "session started")
		s, e, _ := buf.selection_range(ed.buf.cursors[0])
		testing.expect(t, s == {0, 4} && e == {0, 5}, "first placeholder selected")

		type_and_update(&ed, "idx") // replaces "i"; the stop grows with it
		key_and_update(&ed, sdl.K_TAB)
		s, e, _ = buf.selection_range(ed.buf.cursors[0])
		testing.expect_value(t, s, buf.Position{0, 15}) // "n", shifted by 2
		testing.expect_value(t, e, buf.Position{0, 16})
		key_and_update(&ed, sdl.K_TAB, sdl.KMOD_LSHIFT)
		s, e, _ = buf.selection_range(ed.buf.cursors[0])
		testing.expect(t, s == {0, 4} && e == {0, 7}, "Shift+Tab back to the grown first stop")
		key_and_update(&ed, sdl.K_TAB)
		key_and_update(&ed, sdl.K_TAB) // to $0: session ends
		testing.expect(t, !ed.snippet.active, "reaching $0 ends the session")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{1, 1})
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "for idx in 0..<n {\n\t\n}")

		key_and_update(&ed, sdl.K_TAB) // plain Tab again
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 1), "\t    ")
		editor_apply_action(&ed, .Undo)
		editor_apply_action(&ed, .Undo)
		editor_apply_action(&ed, .Undo)
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "fo") // snippet insert was one step
	})
}

@(test)
test_procedure_snippet_triggers_parameter_hints :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		type_and_update(&ed, "fmt.pri")
		fake_completion_list(&ed, `{"label":"println","kind":3,"insertTextFormat":2,"insertText":"println($0)","command":{"title":"","command":"editor.action.triggerParameterHints"}}`)
		editor_update(&ed)
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 0), "fmt.println()")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 12})
		testing.expect(t, ed.signature.active && ed.signature.waiting, "parameter hints requested")
		testing.expect(t, !ed.snippet.active, "only $0: no session")
	})
}

@(test)
test_escape_and_caret_leaving_end_snippet :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("x")
		defer editor_destroy(&ed)
		editor_insert_snippet(&ed, {0, 1}, {0, 1}, " ${1:a} ${2:b}")
		testing.expect(t, ed.snippet.active, "active")
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.snippet.active, "Escape ends it")
		editor_insert_snippet(&ed, {0, 0}, {0, 0}, "${1:p} ${2:q}")
		key_and_update(&ed, sdl.K_DOWN)
		key_and_update(&ed, sdl.K_END)
		testing.expect(t, !ed.snippet.active, "leaving the stop ends it")
	})
}

@(test)
test_completion_docs_lines :: proc(t: ^testing.T) {
	item := lspc.CompletionItem{
		detail = "proc(a: int) -> int",
		documentation = "# Adds\nReturns **a** plus `one`.\n```odin\nadd(1)\n```",
		doc_markdown = true,
	}
	lines := completion_doc_lines(item)
	testing.expect(t, lines[0].code && lines[0].text == "proc(a: int) -> int", "detail first, as code")
	found_prose, found_code := false, false
	for l in lines {
		found_prose ||= !l.code && l.text == "Returns a plus one."
		found_code ||= l.code && l.text == "add(1)"
	}
	testing.expect(t, found_prose, "markdown stripped from prose")
	testing.expect(t, found_code, "fenced block becomes a code line")
	for l in lines {
		testing.expect(t, !strings.contains(l.text, "```"), "fences removed")
	}
}

@(test)
test_incomplete_list_requeries_as_prefix_changes :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		type_and_update(&ed, "a")
		first := ed.lsp.latest_completion_id
		fake_completion_list(&ed, `{"label":"abc"},{"label":"abd"}`, incomplete = true)
		editor_update(&ed)
		type_and_update(&ed, "b")
		testing.expect(t, ed.lsp.latest_completion_id > first, "incomplete list re-queried")
		second := ed.lsp.latest_completion_id
		fake_completion_list(&ed, `{"label":"abc"}`, incomplete = false)
		editor_update(&ed)
		type_and_update(&ed, "c")
		testing.expect_value(t, ed.lsp.latest_completion_id, second) // complete list: local filter only
	})
}

@(test)
test_signature_overloads_cycle_with_up_down :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		type_and_update(&ed, "area(")
		fake_signature_response(&ed, `{"activeSignature":0,"activeParameter":0,"signatures":[` +
			`{"label":"area_circle :: proc(r: f32) -> f32","parameters":[{"label":"r: f32"}]},` +
			`{"label":"area_rect :: proc(w: f32, h: f32) -> f32","parameters":[{"label":"w: f32"},{"label":"h: f32"}]}]}`)
		editor_update(&ed)
		testing.expect_value(t, signature_counter(&ed), "1/2  ")
		key_and_update(&ed, sdl.K_DOWN)
		label, _, active, _ := editor_signature_active_parts(&ed)
		testing.expect(t, strings.has_prefix(label, "area_rect"), "Down shows the next overload")
		testing.expect_value(t, active, "w: f32")
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{0, 5}) // caret didn't move
		key_and_update(&ed, sdl.K_DOWN) // wraps
		testing.expect_value(t, signature_counter(&ed), "1/2  ")
	})
}

@(test)
test_snippet_lines_take_insertion_indent :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("\t")
		defer editor_destroy(&ed)
		editor_insert_snippet(&ed, {0, 1}, {0, 1}, "if ${1} {\n\t${0}\n}")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "\tif  {\n\t\t\n\t}")
		key_and_update(&ed, sdl.K_TAB) // $1 -> $0
		testing.expect_value(t, ed.buf.cursors[0].pos, buf.Position{1, 2})
	})
}

// Popups wrap to the editor's width: a long signature in a hover's code block too (it ran off
// the editor), its continuation lines indented, nothing lost
@(test)
test_popup_text_wraps_to_the_editor :: proc(t: ^testing.T) {
	long := "Scene_AddComponent :: proc(scene: ^Scene, component: ComponentAsset, parent: ^Node = nil, position: [2]f32 = {}) -> ^Node"
	lines := wrap_code(long, 40)
	testing.expect(t, len(lines) > 1, "wrapped")
	joined := strings.builder_make(context.temp_allocator)
	for l, i in lines {
		testing.expectf(t, text_cols(l) <= 40, "line %d fits: %q", i, l)
		if i > 0 do testing.expect(t, strings.has_prefix(l, "    "), "indented")
		strings.write_string(&joined, strings.trim_space(l))
		strings.write_byte(&joined, ' ')
	}
	testing.expect_value(t, strings.trim_space(strings.to_string(joined)), long)
	testing.expect_value(t, len(wrap_code("x := 1", 40)), 1)

	// The hover: markdown with the signature in a code block and prose, in a 30-column editor
	item := lspc.CompletionItem{documentation = strings.concatenate({"```odin\n", long, "\n```\nAdds an instance of a component to a scene: its whole node tree, built like a scene file's."}, context.temp_allocator), doc_markdown = true}
	for l in completion_doc_lines(item, 30, 40) do testing.expectf(t, text_cols(l.text) <= 30, "fits 30 columns: %q", l.text)
	free_all(context.temp_allocator)
}

// Fields show as code declares them (`speed: f32`) with their comment, not a "field" tag
@(test)
test_completion_fields_show_their_type :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		field_type, about := completion_field_doc("```odin\nHero.speed: f32\n```\n---\nPixels a second", "speed")
		testing.expect_value(t, field_type, ": f32")
		testing.expect_value(t, about, "Pixels a second")
		// No comment; a type with spaces and brackets
		field_type, about = completion_field_doc("```odin\nHero.struck: [2][dynamic]^Enemy\n```", "struck")
		testing.expect_value(t, field_type, ": [2][dynamic]^Enemy")
		testing.expect_value(t, about, "")

		tag, suffix, right := completion_row_parts(lspc.CompletionItem{label = "lives", kind = 5, documentation = "```odin\nHero.lives: int\n```\n---\nhow many tries"})
		testing.expect_value(t, tag, "")
		testing.expect_value(t, suffix, ": int")
		testing.expect_value(t, right, "how many tries")
		// Other kinds keep their tag and the server's detail
		tag, suffix, right = completion_row_parts(lspc.CompletionItem{label = "move", kind = 3, detail = "proc(dt: f32)"})
		testing.expect_value(t, tag, "fn")
		testing.expect_value(t, suffix, "")
		testing.expect_value(t, right, "proc(dt: f32)")
		// A field the documentation doesn't describe keeps its tag
		tag, _, _ = completion_row_parts(lspc.CompletionItem{label = "x", kind = 5})
		testing.expect_value(t, tag, "field")
	})
}
