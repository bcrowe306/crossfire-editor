// Message dispatch: turns raw accumulated bytes into complete JSON-RPC
// bodies and routes them (diagnostics notifications vs. request
// responses). Exposed as its own entry point (`client_feed_bytes`) so unit
// tests can exercise the full parsing/dispatch pipeline with synthetic
// byte streams instead of a real `ols` subprocess.
package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// client_feed_bytes appends `data` to the client's receive buffer and
// extracts+dispatches every complete message currently available.
client_feed_bytes :: proc(c: ^Client, data: []u8) {
	append(&c.recv_buf, ..data)
	for {
		body, consumed, ok := try_extract_message(c.recv_buf[:])
		if !ok {
			return
		}
		body_copy := make([]u8, len(body), context.temp_allocator)
		copy(body_copy, body)
		remove_range(&c.recv_buf, 0, consumed)
		client_handle_message_body(c, body_copy)
	}
}

@(private)
remove_range :: proc(buf: ^[dynamic]u8, lo, hi: int) {
	n := hi - lo
	if n <= 0 {
		return
	}
	copy(buf[lo:], buf[hi:])
	resize(buf, len(buf) - n)
}

client_handle_message_body :: proc(c: ^Client, body: []u8) {
	value, err := decode_message(body, context.temp_allocator)
	if err != nil {
		return
	}
	defer json.destroy_value(value, context.temp_allocator)

	if method_val, has_method := json_object_get(value, "method"); has_method {
		method, _ := json_as_string(method_val)
		params, _ := json_object_get(value, "params")
		client_handle_server_message(c, method, params)
		return
	}

	id_val, has_id := json_object_get(value, "id")
	if !has_id {
		return
	}
	id, _ := json_as_int(id_val)
	kind, found := c.pending_kind[id]
	if !found {
		return
	}
	delete_key(&c.pending_kind, id)

	if kind == .Initialize {
		c.initialized = true
		// textDocumentSync is either a kind number or {change: kind}.
		if res, ok := json_object_get(value, "result"); ok {
			caps, _ := json_object_get(res, "capabilities")
			if sync, has := json_object_get(caps, "textDocumentSync"); has {
				if n, is_num := json_as_int(sync); is_num {
					c.sync_kind = n
				} else if change, has_change := json_object_get(sync, "change"); has_change {
					c.sync_kind, _ = json_as_int(change)
				}
			}
		}
		// The spec requires the client to acknowledge the initialize
		// result before the server will treat the session as live.
		client_notify_initialized(c)
		return
	}

	// An error response (or a missing result) still counts as "the server
	// answered", so it's stored as an empty result rather than ignored —
	// otherwise a UI waiting on the seq counter would wait forever.
	result, _ := json_object_get(value, "result")

	switch kind {
	case .Completion:
		if id != c.latest_completion_id {
			return
		}
		client_store_completion(c, result)
	case .SignatureHelp:
		if id != c.latest_signature_id {
			return
		}
		client_store_signature_help(c, result)
	case .CodeAction:
		if id != c.latest_code_action_id {
			return
		}
		client_store_code_actions(c, result)
	case .Definition, .References:
		if id != c.latest_location_id {
			return
		}
		client_store_locations(c, kind, result)
	case .Hover:
		if id != c.latest_hover_id {
			return
		}
		client_store_hover(c, result)
	case .Initialize, .Other:
		// No persistent storage needed for these yet.
	}
}

@(private)
client_handle_server_message :: proc(c: ^Client, method: string, params: json.Value) {
	if method == "textDocument/publishDiagnostics" {
		client_store_diagnostics(c, params)
	}
}

@(private)
client_store_diagnostics :: proc(c: ^Client, params: json.Value) {
	uri_val, has_uri := json_object_get(params, "uri")
	if !has_uri {
		return
	}
	uri_raw, _ := json_as_string(uri_val)
	uri := uri_key(uri_raw, context.temp_allocator)
	diags_val, has_diags := json_object_get(params, "diagnostics")
	if !has_diags {
		return
	}
	arr, is_arr := diags_val.(json.Array)
	if !is_arr {
		return
	}

	list := make([dynamic]Diagnostic, c.allocator)
	for item in arr {
		d: Diagnostic
		if msg_val, ok := json_object_get(item, "message"); ok {
			msg, _ := json_as_string(msg_val)
			d.message = strings.clone(msg, c.allocator)
		}
		if sev_val, ok := json_object_get(item, "severity"); ok {
			sev, _ := json_as_int(sev_val)
			d.severity = sev
		}
		if d.severity < 1 || d.severity > 4 {
			d.severity = 1
		}
		d.source = json_clone_string_field(c, item, "source")
		if tags_val, ok := json_object_get(item, "tags"); ok {
			if tags, is_arr := tags_val.(json.Array); is_arr {
				for tag in tags {
					switch v, _ := json_as_int(tag); v {
					case 1: d.unnecessary = true
					case 2: d.deprecated = true
					}
				}
			}
		}
		if range_val, ok := json_object_get(item, "range"); ok {
			if start_val, ok2 := json_object_get(range_val, "start"); ok2 {
				d.range.start = parse_position(start_val)
			}
			if end_val, ok2 := json_object_get(range_val, "end"); ok2 {
				d.range.end = parse_position(end_val)
			}
		}
		append(&list, d)
	}

	if uri in c.diagnostics {
		old_key, old := delete_key(&c.diagnostics, uri)
		free_diagnostics(c, old)
		delete(old_key, c.allocator)
	}
	c.diagnostics[strings.clone(uri, c.allocator)] = list
	c.diagnostics_seq += 1
}

@(private)
free_diagnostics :: proc(c: ^Client, list: [dynamic]Diagnostic) {
	for d in list {
		delete(d.message, c.allocator)
		delete(d.source, c.allocator)
	}
	delete(list)
}

@(private)
parse_position :: proc(v: json.Value) -> Position {
	p: Position
	if line_val, ok := json_object_get(v, "line"); ok {
		p.line, _ = json_as_int(line_val)
	}
	if char_val, ok := json_object_get(v, "character"); ok {
		p.character, _ = json_as_int(char_val)
	}
	return p
}

// client_clear_completion frees and empties `last_completion`.
client_clear_completion :: proc(c: ^Client) {
	for item in c.last_completion {
		delete(item.label, c.allocator)
		delete(item.detail, c.allocator)
		delete(item.insert_text, c.allocator)
		delete(item.filter_text, c.allocator)
		delete(item.documentation, c.allocator)
		delete(item.command, c.allocator)
	}
	clear(&c.last_completion)
}

// client_clear_signatures frees and empties `last_signatures`.
client_clear_signatures :: proc(c: ^Client) {
	for sig in c.last_signatures {
		delete(sig.label, c.allocator)
		for p in sig.parameters {
			delete(p.label, c.allocator)
		}
		delete(sig.parameters, c.allocator)
	}
	clear(&c.last_signatures)
	c.active_signature = 0
	c.active_parameter = 0
}

@(private)
json_clone_string_field :: proc(c: ^Client, v: json.Value, key: string) -> string {
	if field, ok := json_object_get(v, key); ok {
		if s, is_str := json_as_string(field); is_str {
			return strings.clone(s, c.allocator)
		}
	}
	return ""
}

@(private)
client_store_completion :: proc(c: ^Client, result: json.Value) {
	client_clear_completion(c)
	c.completion_seq += 1

	items: json.Array
	c.completion_incomplete = false
	#partial switch v in result {
	case json.Array:
		items = v
	case json.Object:
		// CompletionList shape: { isIncomplete, items: [...] }
		if list_val, ok := json_object_get(result, "items"); ok {
			items, _ = list_val.(json.Array)
		}
		if inc, ok := json_object_get(result, "isIncomplete"); ok {
			c.completion_incomplete, _ = inc.(json.Boolean)
		}
	}

	for item in items {
		ci: CompletionItem
		ci.label = json_clone_string_field(c, item, "label")
		ci.detail = json_clone_string_field(c, item, "detail")
		ci.insert_text = json_clone_string_field(c, item, "insertText")
		ci.filter_text = json_clone_string_field(c, item, "filterText")
		if kind_val, ok := json_object_get(item, "kind"); ok {
			ci.kind, _ = json_as_int(kind_val)
		}
		if fmt_val, ok := json_object_get(item, "insertTextFormat"); ok {
			f, _ := json_as_int(fmt_val)
			ci.is_snippet = f == 2
		}
		if doc, ok := json_object_get(item, "documentation"); ok {
			// Either a plain string or MarkupContent {kind, value}.
			if s, is_str := json_as_string(doc); is_str {
				ci.documentation = strings.clone(s, c.allocator)
			} else {
				ci.documentation = json_clone_string_field(c, doc, "value")
				if k, has_kind := json_object_get(doc, "kind"); has_kind {
					ks, _ := json_as_string(k)
					ci.doc_markdown = ks == "markdown"
				}
			}
		}
		if cmd, ok := json_object_get(item, "command"); ok {
			ci.command = json_clone_string_field(c, cmd, "command")
		}
		// A textEdit (plain TextEdit or InsertReplaceEdit) overrides
		// insertText per the spec.
		if edit_val, ok := json_object_get(item, "textEdit"); ok {
			range_val, has_range := json_object_get(edit_val, "range")
			if !has_range {
				range_val, has_range = json_object_get(edit_val, "insert")
			}
			if has_range {
				ci.has_text_edit = true
				ci.text_edit_range = parse_range(range_val)
			}
			if new_text_val, ok2 := json_object_get(edit_val, "newText"); ok2 {
				if new_text, is_str := json_as_string(new_text_val); is_str {
					delete(ci.insert_text, c.allocator)
					ci.insert_text = strings.clone(new_text, c.allocator)
				}
			}
		}
		append(&c.last_completion, ci)
	}
}

@(private)
client_store_signature_help :: proc(c: ^Client, result: json.Value) {
	client_clear_signatures(c)
	c.signature_seq += 1

	if v, ok := json_object_get(result, "activeSignature"); ok {
		c.active_signature, _ = json_as_int(v)
	}
	if v, ok := json_object_get(result, "activeParameter"); ok {
		c.active_parameter, _ = json_as_int(v)
	}

	sigs_val, has_sigs := json_object_get(result, "signatures")
	if !has_sigs {
		return
	}
	sigs, is_arr := sigs_val.(json.Array)
	if !is_arr {
		return
	}

	for sig_v in sigs {
		si := SignatureInformation{active_parameter = -1}
		si.label = json_clone_string_field(c, sig_v, "label")
		if v, ok := json_object_get(sig_v, "activeParameter"); ok {
			si.active_parameter, _ = json_as_int(v)
		}
		if params_val, ok := json_object_get(sig_v, "parameters"); ok {
			if params_arr, is_parr := params_val.(json.Array); is_parr {
				params_list := make([]ParameterInformation, len(params_arr), c.allocator)
				for p_v, i in params_arr {
					params_list[i].label = json_clone_string_field(c, p_v, "label")
				}
				si.parameters = params_list
			}
		}
		append(&c.last_signatures, si)
	}
}

client_clear_locations :: proc(c: ^Client) {
	for l in c.last_locations {
		delete(l.uri, c.allocator)
		delete(l.key, c.allocator)
	}
	clear(&c.last_locations)
}

// client_store_locations accepts Location, Location[] and LocationLink[]
// (targetUri + targetSelectionRange).
@(private)
client_store_locations :: proc(c: ^Client, kind: RequestKind, result: json.Value) {
	client_clear_locations(c)
	c.locations_kind = kind
	c.location_seq += 1
	add :: proc(c: ^Client, v: json.Value) {
		uri_v, has_uri := json_object_get(v, "uri")
		range_v, _ := json_object_get(v, "range")
		if !has_uri {
			uri_v, has_uri = json_object_get(v, "targetUri")
			range_v, _ = json_object_get(v, "targetSelectionRange")
		}
		uri, ok := json_as_string(uri_v)
		if !has_uri || !ok {
			return
		}
		append(&c.last_locations, Location{
			uri   = strings.clone(uri, c.allocator),
			key   = uri_key(uri, c.allocator),
			range = parse_range(range_v),
		})
	}
	if arr, is_arr := result.(json.Array); is_arr {
		for v in arr {
			add(c, v)
		}
	} else if _, is_obj := result.(json.Object); is_obj {
		add(c, result)
	}
}

// client_store_hover keeps the hover contents: MarkupContent, a
// MarkedString, or an array of MarkedStrings (joined).
@(private)
client_store_hover :: proc(c: ^Client, result: json.Value) {
	delete(c.last_hover, c.allocator)
	c.last_hover = ""
	c.last_hover_markdown = false
	c.hover_seq += 1
	contents, ok := json_object_get(result, "contents")
	if !ok {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	marked :: proc(sb: ^strings.Builder, v: json.Value) -> (markdown: bool) {
		if s, is_str := json_as_string(v); is_str {
			strings.write_string(sb, s)
			return true // MarkedString strings are markdown
		}
		if val, has := json_object_get(v, "value"); has {
			s, _ := json_as_string(val)
			if lang, has_lang := json_object_get(v, "language"); has_lang {
				l, _ := json_as_string(lang)
				fmt.sbprintf(sb, "```%s\n%s\n```", l, s)
				return true
			}
			strings.write_string(sb, s)
			if kind, has_kind := json_object_get(v, "kind"); has_kind {
				k, _ := json_as_string(kind)
				return k == "markdown"
			}
		}
		return false
	}
	if arr, is_arr := contents.(json.Array); is_arr {
		for v, i in arr {
			if i > 0 {
				strings.write_string(&sb, "\n\n")
			}
			// Evaluate marked() for every part: `||=` would short-circuit.
			md := marked(&sb, v)
			c.last_hover_markdown ||= md
		}
	} else {
		c.last_hover_markdown = marked(&sb, contents)
	}
	c.last_hover = strings.clone(strings.to_string(sb), c.allocator)
}

// client_clear_code_actions frees and empties `last_code_actions`.
client_clear_code_actions :: proc(c: ^Client) {
	for a in c.last_code_actions {
		delete(a.title, c.allocator)
		delete(a.kind, c.allocator)
		for e in a.edits {
			delete(e.key, c.allocator)
			delete(e.new_text, c.allocator)
		}
		delete(a.edits, c.allocator)
	}
	clear(&c.last_code_actions)
}

// client_store_code_actions keeps the CodeAction literals that carry an
// edit (bare Commands would need workspace/executeCommand, which this
// client doesn't implement). Both WorkspaceEdit shapes are accepted:
// `changes` (uri -> TextEdit[]) and `documentChanges` (TextDocumentEdit[]).
@(private)
client_store_code_actions :: proc(c: ^Client, result: json.Value) {
	client_clear_code_actions(c)
	c.code_action_seq += 1
	items, _ := result.(json.Array)
	for item in items {
		edit_val, has_edit := json_object_get(item, "edit")
		if !has_edit {
			continue
		}
		edits := make([dynamic]Code_Action_Edit, c.allocator)
		if changes, ok := json_object_get(edit_val, "changes"); ok {
			if obj, is_obj := changes.(json.Object); is_obj {
				for uri, list in obj {
					append_text_edits(c, &edits, uri, list)
				}
			}
		}
		if doc_changes, ok := json_object_get(edit_val, "documentChanges"); ok {
			if arr, is_arr := doc_changes.(json.Array); is_arr {
				for dc in arr {
					td, _ := json_object_get(dc, "textDocument")
					uri_val, _ := json_object_get(td, "uri")
					uri, _ := json_as_string(uri_val)
					list, _ := json_object_get(dc, "edits")
					append_text_edits(c, &edits, uri, list)
				}
			}
		}
		if len(edits) == 0 {
			delete(edits)
			continue
		}
		a := Code_Action{
			title = json_clone_string_field(c, item, "title"),
			kind  = json_clone_string_field(c, item, "kind"),
			edits = edits[:],
		}
		if p, ok := json_object_get(item, "isPreferred"); ok {
			a.preferred, _ = p.(json.Boolean)
		}
		append(&c.last_code_actions, a)
	}
}

@(private)
append_text_edits :: proc(c: ^Client, edits: ^[dynamic]Code_Action_Edit, uri: string, list: json.Value) {
	arr, ok := list.(json.Array)
	if !ok {
		return
	}
	for e in arr {
		r, has_range := json_object_get(e, "range")
		if !has_range {
			continue
		}
		append(edits, Code_Action_Edit{
			key      = uri_key(uri, c.allocator),
			range    = parse_range(r),
			new_text = json_clone_string_field(c, e, "newText"),
		})
	}
}

@(private)
parse_range :: proc(v: json.Value) -> Range {
	r: Range
	if start_val, ok := json_object_get(v, "start"); ok {
		r.start = parse_position(start_val)
	}
	if end_val, ok := json_object_get(v, "end"); ok {
		r.end = parse_position(end_val)
	}
	return r
}

// client_diagnostics_for returns the last-known diagnostics for a file URI
// (empty slice if none/unknown). The URI is normalized with uri_key, so it
// matches whatever spelling the server used; hosts calling this every
// frame can precompute the key and use client_diagnostics_for_key.
client_diagnostics_for :: proc(c: ^Client, uri: string) -> []Diagnostic {
	return client_diagnostics_for_key(c, uri_key(uri, context.temp_allocator))
}

client_diagnostics_for_key :: proc(c: ^Client, key: string) -> []Diagnostic {
	list, ok := c.diagnostics[key]
	if !ok {
		return nil
	}
	return list[:]
}
