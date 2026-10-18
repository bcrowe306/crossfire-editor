// High-level LSP requests/notifications built on top of the jsonrpc +
// protocol layers. Each proc sends the framed message to the subprocess
// stdin and (for requests) records the pending request id so the response
// can be routed back to the right storage slot when it arrives.
package lsp

import "core:encoding/json"

client_initialize :: proc(c: ^Client, root_uri: string) -> int {
	id := client_next_id(c)
	params := InitializeParams{
		processId    = nil,
		rootUri      = root_uri,
		capabilities = default_client_capabilities(),
	}
	if len(c.init_options) > 0 {
		if v, err := json.parse_string(c.init_options, allocator = context.temp_allocator); err == nil {
			params.initializationOptions = v
		}
	}
	msg := encode_request(id, "initialize", params, context.temp_allocator)
	c.pending_kind[id] = .Initialize
	client_send_raw(c, msg)
	return id
}

client_notify_initialized :: proc(c: ^Client) {
	msg := encode_notification("initialized", struct{}{}, context.temp_allocator)
	client_send_raw(c, msg)
}

client_did_open :: proc(c: ^Client, uri: string, language_id: string, text: string, version := 1) {
	params := DidOpenTextDocumentParams{
		textDocument = TextDocumentItem{
			uri        = uri,
			languageId = language_id,
			version    = version,
			text       = text,
		},
	}
	msg := encode_notification("textDocument/didOpen", params, context.temp_allocator)
	client_send_raw(c, msg)
}

// client_did_change sends a full-document-sync update (simplest correct
// strategy; incremental sync can be added later without changing the
// public API).
client_did_change :: proc(c: ^Client, uri: string, full_text: string, version: int) {
	params := DidChangeTextDocumentParams{
		textDocument = VersionedTextDocumentIdentifier{uri = uri, version = version},
		contentChanges = []TextDocumentContentChangeEvent{{text = full_text}},
	}
	msg := encode_notification("textDocument/didChange", params, context.temp_allocator)
	client_send_raw(c, msg)
}

// client_did_change_incremental sends ordered range edits (servers whose
// sync_kind is 2 apply them in sequence).
client_did_change_incremental :: proc(c: ^Client, uri: string, changes: []Incremental_Change, version: int) {
	params := DidChangeIncrementalParams{
		textDocument   = VersionedTextDocumentIdentifier{uri = uri, version = version},
		contentChanges = changes,
	}
	msg := encode_notification("textDocument/didChange", params, context.temp_allocator)
	client_send_raw(c, msg)
}

client_did_close :: proc(c: ^Client, uri: string) {
	params := DidCloseTextDocumentParams{textDocument = TextDocumentIdentifier{uri = uri}}
	msg := encode_notification("textDocument/didClose", params, context.temp_allocator)
	client_send_raw(c, msg)
}

client_did_save :: proc(c: ^Client, uri: string, text: string) {
	params := DidSaveTextDocumentParams{textDocument = TextDocumentIdentifier{uri = uri}, text = text}
	msg := encode_notification("textDocument/didSave", params, context.temp_allocator)
	client_send_raw(c, msg)
}

client_request_completion :: proc(c: ^Client, uri: string, line, character: int) -> int {
	id := client_next_id(c)
	params := CompletionParams{
		textDocument = TextDocumentIdentifier{uri = uri},
		position     = Position{line = line, character = character},
	}
	msg := encode_request(id, "textDocument/completion", params, context.temp_allocator)
	c.pending_kind[id] = .Completion
	c.latest_completion_id = id
	client_send_raw(c, msg)
	return id
}

client_request_signature_help :: proc(c: ^Client, uri: string, line, character: int) -> int {
	id := client_next_id(c)
	params := SignatureHelpParams{
		textDocument = TextDocumentIdentifier{uri = uri},
		position     = Position{line = line, character = character},
	}
	msg := encode_request(id, "textDocument/signatureHelp", params, context.temp_allocator)
	c.pending_kind[id] = .SignatureHelp
	c.latest_signature_id = id
	client_send_raw(c, msg)
	return id
}

// client_request_definition asks where the symbol at a position is
// defined.
client_request_definition :: proc(c: ^Client, uri: string, line, character: int) -> int {
	id := client_next_id(c)
	params := TextDocumentPositionParams{textDocument = {uri = uri}, position = {line, character}}
	msg := encode_request(id, "textDocument/definition", params, context.temp_allocator)
	c.pending_kind[id] = .Definition
	c.latest_location_id = id
	client_send_raw(c, msg)
	return id
}

// client_request_references asks for every use of the symbol at a
// position (including its declaration).
client_request_references :: proc(c: ^Client, uri: string, line, character: int) -> int {
	id := client_next_id(c)
	params := ReferenceParams{textDocument = {uri = uri}, position = {line, character}}
	params.context_.includeDeclaration = true
	msg := encode_request(id, "textDocument/references", params, context.temp_allocator)
	c.pending_kind[id] = .References
	c.latest_location_id = id
	client_send_raw(c, msg)
	return id
}

// client_request_hover asks for hover info (type, docs) at a position.
client_request_hover :: proc(c: ^Client, uri: string, line, character: int) -> int {
	id := client_next_id(c)
	params := HoverParams{
		textDocument = TextDocumentIdentifier{uri = uri},
		position     = Position{line = line, character = character},
	}
	msg := encode_request(id, "textDocument/hover", params, context.temp_allocator)
	c.pending_kind[id] = .Hover
	c.latest_hover_id = id
	client_send_raw(c, msg)
	return id
}

// client_request_code_action asks for code actions (quick fixes,
// refactors) over `range`, passing the diagnostics that overlap it.
client_request_code_action :: proc(c: ^Client, uri: string, range: Range, diagnostics: []Diagnostic) -> int {
	id := client_next_id(c)
	params := CodeActionParams{
		textDocument = TextDocumentIdentifier{uri = uri},
		range        = range,
		context_     = CodeActionContext{diagnostics = diagnostics},
	}
	msg := encode_request(id, "textDocument/codeAction", params, context.temp_allocator)
	c.pending_kind[id] = .CodeAction
	c.latest_code_action_id = id
	client_send_raw(c, msg)
	return id
}
