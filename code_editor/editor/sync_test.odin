package code_editor

import lspc "../lsp"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_edits_queue_as_incremental_lsp_changes :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("é = 1\nnext")
		defer editor_destroy(&ed)
		ed.lsp.sync_kind = 2
		editor_update(&ed) // didOpen
		testing.expect(t, ed.lsp_doc_open, "document open")

		ed.buf.cursors[0].pos = {0, 2} // after 'é' (2 bytes, 1 UTF-16 unit)
		editor_inject_text(&ed, "+") // not an identifier char: no completion request (which would sync)
		editor_pump_injected_events(&ed)
		ed.buf.cursors[0] = {pos = {1, 4}, sel = {anchor = {1, 0}, active = true}}
		editor_inject_key(&ed, sdl.K_BACKSPACE)
		editor_pump_injected_events(&ed)

		editor_consume_buffer_changes(&ed)
		testing.expect_value(t, len(ed.lsp_pending), 2)
		if len(ed.lsp_pending) != 2 {
			return
		}
		testing.expect_value(t, ed.lsp_pending[0].range, lspc.Range{{0, 1}, {0, 1}}) // UTF-16 column
		testing.expect_value(t, ed.lsp_pending[0].text, "+")
		testing.expect_value(t, ed.lsp_pending[1].range, lspc.Range{{1, 0}, {1, 4}})
		testing.expect_value(t, ed.lsp_pending[1].text, "")

		v := ed.lsp_version
		editor_sync_lsp(&ed)
		testing.expect_value(t, len(ed.lsp_pending), 0)
		testing.expect_value(t, ed.lsp_version, v + 1)
		testing.expect_value(t, ed.lsp_synced_version, ed.buf.version)
	})
}

@(test)
test_reset_forces_full_sync :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("abc")
		defer editor_destroy(&ed)
		ed.lsp.sync_kind = 2
		editor_update(&ed)
		editor_set_text(&ed, "replaced entirely")
		editor_consume_buffer_changes(&ed)
		testing.expect(t, ed.lsp_need_full, "set_text needs a full sync")
		testing.expect_value(t, len(ed.lsp_pending), 0)
		editor_sync_lsp(&ed)
		testing.expect(t, !ed.lsp_need_full, "cleared after syncing")
		testing.expect_value(t, ed.lsp_synced_version, ed.buf.version)
	})
}

@(test)
test_width_cache_follows_edits :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := editor_init(.Other)
		defer editor_destroy(&ed)
		ed.visible_cols = 10
		editor_set_text(&ed, "short\n0123456789012345678901234567890123456789")
		testing.expect_value(t, editor_max_visual_width(&ed), 40)
		ed.scroll_col = 25
		editor_clamp_scroll(&ed)
		testing.expect_value(t, ed.scroll_col, 25)

		// Shorten the long line: the cached width must be recomputed.
		ed.buf.cursors[0] = {pos = {1, 40}, sel = {anchor = {1, 15}, active = true}}
		editor_apply_action(&ed, .Backspace)
		editor_clamp_scroll(&ed)
		testing.expect_value(t, editor_max_visual_width(&ed), 15)
		testing.expect_value(t, ed.scroll_col, 15 - 10 + 1)
	})
}
