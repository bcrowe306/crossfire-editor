package code_editor

import buf "../buffer"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

// Code action providers (Ctrl+.): their actions after the diagnostics' fixes, only where they
// say, their preview beside the menu, the edits as one undo step, and `on_action` after them.

@(private="file")
Action_Log :: struct {
	ran:  int,
	id:   int,
	text: string,
}

// Offers "Add a field" inside `S :: struct {`, and "Say hello" (no edits) on any line saying hi
@(private="file")
actions_registry :: proc(log: ^Action_Log) -> Provider_Registry {
	reg: Provider_Registry
	provider_register(&reg, Provider{kind = .Action, name = "fields", user_data = log,
		actions = proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^[dynamic]Provider_Action) {
			if ctx.syntax.kind == .Struct_Body {
				edits := make([]Text_Edit, 1, ctx.allocator)
				edits[0] = {start = {pos.line + 1, 0}, end = {pos.line + 1, 0}, text = "\tadded: int,\n"}
				append(out, Provider_Action{title = "Add a field", edits = edits, preview = "\tadded: int,", caret = buf.Position{pos.line + 1, 7}, id = 1})
			}
			if strings.contains(buf.buffer_line_str(doc.buffer, pos.line), "hi") {
				append(out, Provider_Action{title = "Say hello", id = 2, preferred = true})
			}
		},
		on_action = proc(doc: Provider_Document, action: Provider_Action, user_data: rawptr) {
			log := (^Action_Log)(user_data)
			log.ran += 1
			log.id = action.id
			delete(log.text)
			log.text = strings.clone(buf.buffer_line_str(doc.buffer, 2))
		}})
	return reg
}

@(test)
test_provider_code_actions_in_the_menu :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		log: Action_Log
		defer delete(log.text)
		reg := actions_registry(&log)
		defer provider_registry_destroy(&reg)
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		editor_set_text(&ed, "package p\n\nS :: struct {\n\tx: int,\n}\n\nf :: proc() {\n\t// hi\n}\n")
		editor_set_providers(&ed, &reg)

		// In the struct: its action, with its preview, without a server
		ed.buf.cursors[0].pos = {3, 2}
		key_and_update(&ed, sdl.K_PERIOD, sdl.KMOD_LCTRL)
		testing.expect(t, editor_code_actions_visible(&ed), "the action shows without a server")
		testing.expect_value(t, editor_code_action_count(&ed), 1)
		title, _ := editor_code_action_title(&ed, 0)
		testing.expect_value(t, title, "Add a field")
		lines, _, shown := editor_drop_preview_layout(&ed)
		testing.expect(t, shown && len(lines) == 1 && strings.contains(lines[0], "added: int"), "its preview beside the menu")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, !ed.actions.active, "applied and closed")
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 4), "\tadded: int,")
		testing.expect_value(t, editor_primary_cursor(&ed).pos, buf.Position{4, 7})
		testing.expect(t, log.ran == 1 && log.id == 1, "on_action after the edits")
		buf.buffer_undo(&ed.buf)
		testing.expect_value(t, buf.buffer_line_str(&ed.buf, 4), "}")
		testing.expect(t, !strings.contains(editor_to_string(&ed, context.temp_allocator), "added"), "one undo step")

		// An action that only runs the host's code, preferred: selected first
		ed.buf.cursors[0].pos = {7, 4}
		editor_request_code_actions(&ed)
		testing.expect_value(t, editor_code_action_count(&ed), 1)
		testing.expect_value(t, ed.actions.selected, 0)
		testing.expect(t, editor_apply_code_action(&ed, 0), "ran")
		testing.expect(t, log.ran == 2 && log.id == 2, "the host's callback")

		// Where none applies: no menu
		ed.buf.cursors[0].pos = {0, 0}
		editor_request_code_actions(&ed)
		testing.expect(t, !editor_code_actions_visible(&ed), "nothing offered: no menu")
	})
}
