// Per-frame update: drains injected/synthetic events, polls the LSP client
// (if attached) for responses/diagnostics, keeps the server's copy of the
// document in sync, and refreshes the completion/signature-help popups.
package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:strings"

editor_update :: proc(ed: ^Editor) {
	editor_pump_injected_events(ed)
	editor_update_mouse(ed)
	editor_update_diagnostics(ed)
	editor_consume_buffer_changes(ed)
	editor_update_snippet(ed)
	editor_update_providers(ed)
	if ed.lsp_enabled {
		lspc.client_poll(&ed.lsp)
		editor_supervise_lsp(ed)
		editor_sync_lsp(ed)
	}
	// The completion list works with providers alone too
	editor_update_lsp_ui(ed)
	if ed.lsp_enabled {
		editor_update_code_actions(ed)
		editor_update_navigation(ed)
	}
}

// editor_lsp_ready reports whether requests about the current document can
// be sent: a server is attached and initialized and there's a document URI
// (requests call editor_sync_lsp first, which sends the deferred didOpen).
editor_lsp_ready :: proc(ed: ^Editor) -> bool {
	return ed.lsp_enabled && len(ed.document_uri) > 0 && ed.lsp.initialized
}

// editor_sync_lsp sends the deferred didOpen once the server is
// initialized, then a full-document didChange whenever the buffer has
// changed since the last sync. Called every update and before every
// request, so the server always sees the text the request refers to.
editor_sync_lsp :: proc(ed: ^Editor) {
	if !ed.lsp_enabled || len(ed.document_uri) == 0 || !ed.lsp.initialized {
		return
	}
	editor_consume_buffer_changes(ed)
	if !ed.lsp_doc_open {
		text := buf.buffer_to_string(&ed.buf, context.temp_allocator)
		lspc.client_did_open(&ed.lsp, ed.document_uri, "odin", text, ed.lsp_version)
		ed.lsp_doc_open = true
		ed.lsp_synced_version = ed.buf.version
		editor_clear_lsp_pending(ed)
		ed.lsp_need_full = false
		return
	}
	if ed.buf.version == ed.lsp_synced_version {
		return
	}
	if !ed.lsp_need_full && ed.lsp.sync_kind == 2 && len(ed.lsp_pending) > 0 {
		// Incremental sync: just the edited ranges, in order.
		ed.lsp_version += 1
		ed.lsp_synced_version = ed.buf.version
		lspc.client_did_change_incremental(&ed.lsp, ed.document_uri, ed.lsp_pending[:], ed.lsp_version)
	} else {
		editor_notify_lsp_changed(ed)
	}
	editor_clear_lsp_pending(ed)
	ed.lsp_need_full = false
}

LSP_MAX_PENDING_CHANGES :: 1000

// editor_consume_buffer_changes drains the buffer's change log once and
// hands each edit to everything that tracks positions: the diagnostic
// overlay (shifted in place) and the queue of incremental LSP changes.
editor_consume_buffer_changes :: proc(ed: ^Editor) {
	changes, reset := buf.buffer_take_changes(&ed.buf)
	if reset {
		ed.diag_overlay.reset_pending = true
		// The text was replaced: what providers said about it is gone until they're asked again
		if len(ed.provided.diagnostics) > 0 do ed.provided.diag_seq += 1
		provided_clear_diagnostics(&ed.provided)
		provided_clear_markers(&ed.provided)
		provided_clear_inlays(&ed.provided)
		ed.provided.version = -1
		ed.provided.seq += 1
		editor_clear_lsp_pending(ed)
		ed.lsp_need_full = true
	}
	for ch in changes {
		snippet_shift_stops(ed, ch)
		provided_shift(&ed.provided, ch)
		for &d in ed.diag_overlay.items {
			d.start = buf.position_after_change(d.start, ch)
			d.end = buf.position_after_change(d.end, ch)
		}
		if ed.lsp_enabled && ed.lsp_doc_open && !ed.lsp_need_full {
			if len(ed.lsp_pending) >= LSP_MAX_PENDING_CHANGES {
				editor_clear_lsp_pending(ed)
				ed.lsp_need_full = true
				continue
			}
			append(&ed.lsp_pending, lspc.Incremental_Change{
				range = {{ch.start.line, ch.start_u16}, {ch.old_end.line, ch.old_end_u16}},
				text  = strings.clone(ch.text),
			})
		}
	}
}

editor_clear_lsp_pending :: proc(ed: ^Editor) {
	for c in ed.lsp_pending {
		delete(c.text)
	}
	clear(&ed.lsp_pending)
}
