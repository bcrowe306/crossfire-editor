package code_editor

import buf "../buffer"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

// The server's copy of a document is the text it was opened with, changed by every incremental
// edit the editor sends. These tests keep that copy (a shadow, built only from what's sent) and
// compare it with the buffer after each kind of edit: any difference is text the language server
// gets wrong (completions missing for code it can't see).

// Replays what the client sent (didOpen, then each didChange: incremental ranges or whole text)
// onto the server's copy. ASCII text: UTF-16 columns are byte columns
@(private="file")
replay :: proc(shadow: string, log: ^[dynamic]string) -> string {
	result := shadow
	for framed in log {
		body := framed[strings.index(framed, "\r\n\r\n") + 4:]
		value, err := json.parse_string(body, allocator = context.temp_allocator)
		if err != nil do continue
		message := value.(json.Object)
		method, _ := message["method"].(json.String)
		params, _ := message["params"].(json.Object)
		switch method {
		case "textDocument/didOpen":
			result = params["textDocument"].(json.Object)["text"].(json.String)
		case "textDocument/didChange":
			for change in params["contentChanges"].(json.Array) {
				c := change.(json.Object)
				text := c["text"].(json.String)
				r, ranged := c["range"].(json.Object)
				if !ranged {
					result = text
					continue
				}
				lines := strings.split(result, "\n", context.temp_allocator)
				offset :: proc(lines: []string, p: json.Object) -> int {
					line, col := int(p["line"].(json.Float) or_else 0), int(p["character"].(json.Float) or_else 0)
					if l, ok := p["line"].(json.Integer); ok do line = int(l)
					if c, ok := p["character"].(json.Integer); ok do col = int(c)
					at := 0
					for i in 0 ..< line do at += len(lines[i]) + 1
					return at + col
				}
				a, b := offset(lines, r["start"].(json.Object)), offset(lines, r["end"].(json.Object))
				result = strings.concatenate({result[:a], text, result[b:]}, context.temp_allocator)
			}
		}
	}
	for m in log do delete(m)
	clear(log)
	return result
}

// What the server has after the editor syncs
@(private="file")
syncShadow :: proc(ed: ^Editor, shadow: string) -> string {
	editor_sync_lsp(ed)
	return replay(shadow, ed.lsp.sent_log)
}

@(test)
test_incremental_sync_matches_the_buffer_after_every_edit :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		start := "package scripts\n\nHero :: struct {\n\tspeed: f32,\n}\n\nmove :: proc(h: ^Hero) {\n\th.speed = 1\n}\n"
		ed := make_lsp_test_editor(start)
		defer editor_destroy(&ed)
		ed.lsp.sync_kind = 2
		log: [dynamic]string
		defer { for m in log do delete(m); delete(log) }
		ed.lsp.sent_log = &log
		editor_update(&ed) // didOpen with the start text
		shadow := replay("", &log)
		check :: proc(t: ^testing.T, ed: ^Editor, shadow: ^string, step: string) {
			shadow^ = syncShadow(ed, shadow^)
			text := buf.buffer_to_string(&ed.buf, context.temp_allocator)
			testing.expectf(t, shadow^ == text, "after %s the server has:\n%s\nbut the buffer is:\n%s", step, shadow^, text)
			// Back in step, so one difference doesn't fail every later step
			shadow^ = text
		}
		at :: proc(ed: ^Editor, line, col: int) {
			clear(&ed.buf.cursors)
			append(&ed.buf.cursors, buf.Cursor{pos = {line, col}})
		}
		typeText :: proc(ed: ^Editor, text: string) {
			editor_inject_text(ed, text)
			editor_pump_injected_events(ed)
		}
		steps := []struct { name: string, run: proc(ed: ^Editor) }{
			{"typing", proc(ed: ^Editor) { at(ed, 3, 12); typeText(ed, " // fast") }},
			{"a new line (auto-indent)", proc(ed: ^Editor) { at(ed, 3, 12); _ = editor_run_action(ed, .Newline); typeText(ed, "jump: f32,") }},
			{"brackets (auto-pairing)", proc(ed: ^Editor) { at(ed, 8, 12); typeText(ed, " + f32(2") }},
			{"backspace", proc(ed: ^Editor) { at(ed, 8, 10); _ = editor_run_action(ed, .Backspace); _ = editor_run_action(ed, .Backspace) }},
			{"backspace a word", proc(ed: ^Editor) { at(ed, 3, 7); _ = editor_run_action(ed, .BackspaceWord) }},
			{"delete forward a word", proc(ed: ^Editor) { at(ed, 0, 0); _ = editor_run_action(ed, .DeleteForwardWord) }},
			{"typing over a selection", proc(ed: ^Editor) {
				clear(&ed.buf.cursors)
				append(&ed.buf.cursors, buf.Cursor{pos = {2, 4}, sel = {anchor = {2, 0}, active = true}})
				typeText(ed, "Player")
			}},
			{"two cursors typing", proc(ed: ^Editor) { at(ed, 3, 1); _ = editor_run_action(ed, .AddCursorBelow); typeText(ed, "x_") }},
			{"duplicating a line", proc(ed: ^Editor) { at(ed, 3, 0); _ = editor_run_action(ed, .DuplicateLineDown) }},
			{"moving a line up", proc(ed: ^Editor) { at(ed, 4, 0); _ = editor_run_action(ed, .MoveLineUp) }},
			{"moving a line down", proc(ed: ^Editor) { at(ed, 2, 0); _ = editor_run_action(ed, .MoveLineDown) }},
			{"toggling a comment", proc(ed: ^Editor) { at(ed, 3, 0); _ = editor_run_action(ed, .ToggleLineComment) }},
			{"untoggling it", proc(ed: ^Editor) { at(ed, 3, 0); _ = editor_run_action(ed, .ToggleLineComment) }},
			{"indenting a selection", proc(ed: ^Editor) {
				clear(&ed.buf.cursors)
				append(&ed.buf.cursors, buf.Cursor{pos = {5, 2}, sel = {anchor = {3, 0}, active = true}})
				_ = editor_run_action(ed, .IndentOrTab)
			}},
			{"outdenting it", proc(ed: ^Editor) { _ = editor_run_action(ed, .Outdent) }},
			{"inserting a line below", proc(ed: ^Editor) { at(ed, 1, 0); _ = editor_run_action(ed, .InsertLineBelow); typeText(ed, "import e \"engine:.\"") }},
			{"inserting a line above", proc(ed: ^Editor) { at(ed, 1, 0); _ = editor_run_action(ed, .InsertLineAbove) }},
			{"deleting a line", proc(ed: ^Editor) { at(ed, 1, 0); _ = editor_run_action(ed, .DeleteLine) }},
			{"undo", proc(ed: ^Editor) { _ = editor_run_action(ed, .Undo) }},
			{"undo again", proc(ed: ^Editor) { _ = editor_run_action(ed, .Undo); _ = editor_run_action(ed, .Undo) }},
			{"redo", proc(ed: ^Editor) { _ = editor_run_action(ed, .Redo) }},
			{"undo all the way", proc(ed: ^Editor) { for _ in 0 ..< 40 do _ = editor_run_action(ed, .Undo) }},
			{"redo all the way", proc(ed: ^Editor) { for _ in 0 ..< 40 do _ = editor_run_action(ed, .Redo) }},
		}
		for step in steps {
			step.run(&ed)
			check(t, &ed, &shadow, step.name)
		}
		_ = fmt.tprint
	})
}

// A host inserting text through the buffer (an editor inserting a field), then telling the
// server with a full sync: the insert mustn't also go out again as an incremental change
@(test)
test_host_insert_then_full_sync_isnt_sent_twice :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		start := "package scripts\n\nHero :: struct {\n}\n"
		ed := make_lsp_test_editor(start)
		defer editor_destroy(&ed)
		ed.lsp.sync_kind = 2
		log: [dynamic]string
		defer { for m in log do delete(m); delete(log) }
		ed.lsp.sent_log = &log
		editor_update(&ed)
		buf.buffer_insert_text(&ed.buf, {3, 0}, "\tspeed: f32,\n")
		editor_notify_lsp_changed(&ed) // the host tells the server: the whole text
		shadow := replay("", &log)
		// The next edit: only it goes out
		clear(&ed.buf.cursors)
		append(&ed.buf.cursors, buf.Cursor{pos = {4, 1}})
		editor_inject_text(&ed, "x")
		editor_pump_injected_events(&ed)
		shadow = syncShadow(&ed, shadow)
		testing.expect_value(t, shadow, buf.buffer_to_string(&ed.buf, context.temp_allocator))
	})
}
