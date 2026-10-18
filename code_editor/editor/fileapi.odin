// Host-facing file load/save API. Wraps `buffer` file IO and (when an LSP
// client is attached) keeps the language server's view of the document in
// sync via didOpen/didChange/didSave notifications.
package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:os"
import "core:path/filepath"
import "core:strings"

// DEFAULT_LSP_INIT_OPTIONS is sent as initializationOptions: OLS reads its
// ols.json settings from it (snippets are off in OLS unless enabled).
DEFAULT_LSP_INIT_OPTIONS :: `{"enable_snippets": true, "enable_procedure_snippet": true}`

editor_attach_lsp :: proc(ed: ^Editor, command: []string, working_dir := "", init_options := DEFAULT_LSP_INIT_OPTIONS) -> bool {
	if len(command) == 0 {
		return false
	}
	// The server runs in `working_dir`, so a relative executable path
	// (e.g. "third_party/ols/ols") must be resolved against *our* current
	// directory first. Bare names ("ols") are left for PATH lookup.
	cmd := make([]string, len(command), context.temp_allocator)
	copy(cmd, command)
	if strings.contains_rune(cmd[0], '/') && !filepath.is_abs(cmd[0]) {
		cmd[0] = absolute_path(cmd[0], context.temp_allocator)
	}

	root := lspc.resolve_path(absolute_path(working_dir if len(working_dir) > 0 else ".", context.temp_allocator), context.temp_allocator)
	ed.lsp = lspc.client_init()
	if !lspc.client_start(&ed.lsp, cmd, root) {
		lspc.client_destroy(&ed.lsp)
		return false
	}
	ed.lsp.init_options = strings.clone(init_options, ed.lsp.allocator)
	ed.lsp_enabled = true
	ed.lsp_doc_open = false
	lsp_supervisor_begin(&ed.lsp_supervisor, cmd, root, init_options)
	lspc.client_initialize(&ed.lsp, lspc.file_uri(root, context.temp_allocator))
	return true
}

// absolute_path resolves `path` against the current directory. LSP
// requires absolute `file://` URIs; a relative one silently breaks
// completion because the server can't match it to a file.
@(private)
absolute_path :: proc(path: string, allocator := context.allocator) -> string {
	abs, err := os.get_absolute_path(path, allocator)
	if err != nil {
		return path
	}
	return abs
}

editor_detach_lsp :: proc(ed: ^Editor) {
	lsp_supervisor_end(&ed.lsp_supervisor)
	if !ed.lsp_enabled {
		return
	}
	lspc.client_destroy(&ed.lsp)
	ed.lsp_enabled = false
	ed.lsp_doc_open = false
	editor_close_completion(ed)
	editor_close_signature_help(ed)
}

// editor_load_file loads `path` into the buffer and (re)associates the LSP
// document URI, sending `didOpen` if an LSP client is attached.
editor_load_file :: proc(ed: ^Editor, path: string) -> bool {
	if !buf.buffer_load_file(&ed.buf, path) {
		return false
	}
	if ed.lsp_enabled && ed.lsp_doc_open && len(ed.document_uri) > 0 {
		lspc.client_did_close(&ed.lsp, ed.document_uri)
	}
	if len(ed.document_uri) > 0 {
		delete(ed.document_uri)
	}
	delete(ed.document_key)
	// Use the symlink-resolved path: OLS matches the compiler's (resolved)
	// paths against ours when clearing old `odin check` results, so a
	// symlinked spelling (e.g. /tmp on macOS) would leave fixed errors
	// on screen forever.
	ed.document_uri = lspc.file_uri(lspc.resolve_path(absolute_path(path, context.temp_allocator), context.temp_allocator))
	ed.document_key = lspc.uri_key(ed.document_uri)
	ed.diag_tip = {}
	ed.lsp_version = 1
	ed.lsp_doc_open = false
	editor_close_completion(ed)
	editor_close_signature_help(ed)
	// didOpen is sent by editor_sync_lsp as soon as the server is
	// initialized (immediately, if it already is).
	editor_sync_lsp(ed)
	return true
}

editor_save_file :: proc(ed: ^Editor, path: string) -> bool {
	ok := buf.buffer_save_file(&ed.buf, path)
	if ok && ed.lsp_enabled && len(ed.document_uri) > 0 {
		editor_sync_lsp(ed)
		lspc.client_did_save(&ed.lsp, ed.document_uri, buf.buffer_to_string(&ed.buf, context.temp_allocator))
	}
	return ok
}

editor_save_file_as :: proc(ed: ^Editor, path: string) -> bool {
	return editor_save_file(ed, path)
}

editor_save :: proc(ed: ^Editor) -> bool {
	ok := buf.buffer_save(&ed.buf)
	if ok && ed.lsp_enabled && len(ed.document_uri) > 0 {
		editor_sync_lsp(ed)
		lspc.client_did_save(&ed.lsp, ed.document_uri, buf.buffer_to_string(&ed.buf, context.temp_allocator))
	}
	return ok
}

// editor_set_text loads `text` directly into the buffer (for hosts that
// don't go through disk files, e.g. embedded script buffers), resetting
// undo history.
editor_set_text :: proc(ed: ^Editor, text: string) {
	buf.buffer_set_text(&ed.buf, text)
}

// editor_to_string returns the current buffer contents as a string owned
// by the caller.
editor_to_string :: proc(ed: ^Editor, allocator := context.allocator) -> string {
	return buf.buffer_to_string(&ed.buf, allocator)
}

// editor_notify_lsp_changed should be called by the host after any edit
// that should be reflected to the language server (full-document sync).
editor_notify_lsp_changed :: proc(ed: ^Editor) {
	if !ed.lsp_enabled || len(ed.document_uri) == 0 {
		return
	}
	ed.lsp_version += 1
	ed.lsp_synced_version = ed.buf.version
	text := buf.buffer_to_string(&ed.buf, context.temp_allocator)
	lspc.client_did_change(&ed.lsp, ed.document_uri, text, ed.lsp_version)
}
