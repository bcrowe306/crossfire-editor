package lsp

import "core:fmt"
import "core:os"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

run_leak_free :: proc(t: ^testing.T, body: proc(t: ^testing.T)) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	old := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	body(t)
	context.allocator = old

	for _, entry in track.allocation_map {
		testing.expectf(t, false, "Memory leak: %v bytes at %v", entry.size, entry.location)
	}
	for bf in track.bad_free_array {
		testing.expectf(t, false, "Bad free: %p at %v", bf.memory, bf.location)
	}
}

@(test)
test_frame_message_adds_content_length_header :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		framed := frame_message(`{"a":1}`, context.allocator)
		defer delete(framed)
		testing.expect(t, strings.has_prefix(framed, "Content-Length: 7\r\n\r\n"), "expected header with correct length")
		testing.expect(t, strings.has_suffix(framed, `{"a":1}`), "expected body to follow header")
	})
}

@(test)
test_try_extract_message_waits_for_full_body :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		partial := transmute([]u8)string("Content-Length: 10\r\n\r\n{\"a\":1}")
		_, _, ok := try_extract_message(partial)
		testing.expect(t, !ok, "expected no message until full body is present")

		full := transmute([]u8)string(`Content-Length: 7` + "\r\n\r\n" + `{"a":1}`)
		body, consumed, ok2 := try_extract_message(full)
		testing.expect(t, ok2, "expected message to be extracted")
		testing.expect_value(t, string(body), `{"a":1}`)
		testing.expect_value(t, consumed, len(full))
	})
}

@(test)
test_try_extract_message_handles_trailing_data :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		msg1 := `Content-Length: 7` + "\r\n\r\n" + `{"a":1}`
		msg2 := `Content-Length: 7` + "\r\n\r\n" + `{"b":2}`
		combined := transmute([]u8)strings.concatenate({msg1, msg2}, context.temp_allocator)

		body, consumed, ok := try_extract_message(combined)
		testing.expect(t, ok, "expected first message to extract")
		testing.expect_value(t, string(body), `{"a":1}`)

		remaining := combined[consumed:]
		body2, _, ok2 := try_extract_message(remaining)
		testing.expect(t, ok2, "expected second message to extract")
		testing.expect_value(t, string(body2), `{"b":2}`)
	})
}

@(test)
test_encode_request_shape :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		Params :: struct {
			foo: string `json:"foo"`,
		}
		framed := encode_request(1, "textDocument/completion", Params{foo = "bar"}, context.allocator)
		defer delete(framed)
		testing.expect(t, strings.contains(framed, `"id":1`), "expected id field")
		testing.expect(t, strings.contains(framed, `"method":"textDocument/completion"`), "expected method field")
		testing.expect(t, strings.contains(framed, `"foo":"bar"`), "expected params to be marshaled")
	})
}

@(test)
test_feed_bytes_dispatches_diagnostics :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		body := `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///x.odin","diagnostics":[{"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}},"severity":1,"message":"undeclared identifier"}]}}`
		framed := frame_message(body, context.temp_allocator)
		client_feed_bytes(&c, transmute([]u8)framed)

		diags := client_diagnostics_for(&c, "file:///x.odin")
		testing.expect_value(t, len(diags), 1)
		testing.expect_value(t, diags[0].message, "undeclared identifier")
		testing.expect_value(t, diags[0].severity, 1)
		testing.expect_value(t, diags[0].range.start, Position{line = 1, character = 2})
	})
}

@(test)
test_feed_bytes_dispatches_completion_response :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		id := client_next_id(&c)
		c.pending_kind[id] = .Completion
		c.latest_completion_id = id

		body := fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"result":[{{"label":"foo","kind":3,"detail":"proc()"}},{{"label":"bar","kind":6,"detail":""}}]}}`,
			id,
		)
		framed := frame_message(body, context.temp_allocator)
		client_feed_bytes(&c, transmute([]u8)framed)

		testing.expect_value(t, len(c.last_completion), 2)
		testing.expect_value(t, c.last_completion[0].label, "foo")
		testing.expect_value(t, c.last_completion[0].kind, 3)
		testing.expect_value(t, c.last_completion[1].label, "bar")
		_, still_pending := c.pending_kind[id]
		testing.expect(t, !still_pending, "expected pending request to be cleared")
	})
}

@(test)
test_feed_bytes_dispatches_signature_help_response :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		id := client_next_id(&c)
		c.pending_kind[id] = .SignatureHelp
		c.latest_signature_id = id

		body := fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"result":{{"signatures":[{{"label":"foo(a: int) -> int","parameters":[{{"label":"a: int"}}]}}]}}}}`,
			id,
		)
		framed := frame_message(body, context.temp_allocator)
		client_feed_bytes(&c, transmute([]u8)framed)

		testing.expect_value(t, len(c.last_signatures), 1)
		testing.expect_value(t, c.last_signatures[0].label, "foo(a: int) -> int")
		testing.expect_value(t, len(c.last_signatures[0].parameters), 1)
		testing.expect_value(t, c.last_signatures[0].parameters[0].label, "a: int")
	})
}

@(test)
test_feed_bytes_handles_split_across_two_calls :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		id := client_next_id(&c)
		c.pending_kind[id] = .Completion
		c.latest_completion_id = id
		body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":[{{"label":"x","kind":1,"detail":""}}]}}`, id)
		framed := frame_message(body, context.temp_allocator)

		split := len(framed) / 2
		client_feed_bytes(&c, transmute([]u8)framed[:split])
		testing.expect_value(t, len(c.last_completion), 0)
		client_feed_bytes(&c, transmute([]u8)framed[split:])
		testing.expect_value(t, len(c.last_completion), 1)
		testing.expect_value(t, c.last_completion[0].label, "x")
	})
}

@(test)
test_initialize_marks_client_initialized :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		id := client_next_id(&c)
		c.pending_kind[id] = .Initialize
		body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":{{"capabilities":{{}}}}}}`, id)
		framed := frame_message(body, context.temp_allocator)
		client_feed_bytes(&c, transmute([]u8)framed)

		testing.expect(t, c.initialized, "expected client to be marked initialized")
	})
}

@(test)
test_file_uri_formats_path :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		uri := file_uri("/tmp/foo.odin", context.allocator)
		defer delete(uri)
		testing.expect_value(t, uri, "file:///tmp/foo.odin")
	})
}

@(test)
test_completion_parses_insert_text_and_text_edit :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		id := client_next_id(&c)
		c.pending_kind[id] = .Completion
		c.latest_completion_id = id
		body := fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"result":{{"isIncomplete":false,"items":[` +
			`{{"label":"println","kind":3,"insertText":"println","filterText":"println"}},` +
			`{{"label":"printf","kind":3,"textEdit":{{"newText":"printf","range":{{"start":{{"line":5,"character":5}},"end":{{"line":5,"character":8}}}}}}}}` +
			`]}}}}`,
			id,
		)
		client_feed_bytes(&c, transmute([]u8)frame_message(body, context.temp_allocator))

		testing.expect_value(t, len(c.last_completion), 2)
		testing.expect_value(t, c.last_completion[0].insert_text, "println")
		testing.expect_value(t, c.last_completion[0].filter_text, "println")
		testing.expect(t, !c.last_completion[0].has_text_edit, "first item has no textEdit")
		testing.expect(t, c.last_completion[1].has_text_edit, "second item has a textEdit")
		testing.expect_value(t, c.last_completion[1].insert_text, "printf")
		testing.expect_value(t, c.last_completion[1].text_edit_range.start, Position{5, 5})
		testing.expect_value(t, c.completion_seq, 1)
	})
}

@(test)
test_signature_help_parses_active_parameter :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		id := client_next_id(&c)
		c.pending_kind[id] = .SignatureHelp
		c.latest_signature_id = id
		body := fmt.tprintf(
			`{{"jsonrpc":"2.0","id":%d,"result":{{"activeSignature":0,"activeParameter":1,"signatures":[` +
			`{{"label":"add(a: int, b: int) -> int","parameters":[{{"label":"a: int"}},{{"label":"b: int"}}]}}]}}}}`,
			id,
		)
		client_feed_bytes(&c, transmute([]u8)frame_message(body, context.temp_allocator))

		testing.expect_value(t, len(c.last_signatures), 1)
		testing.expect_value(t, c.active_parameter, 1)
		testing.expect_value(t, c.last_signatures[0].active_parameter, -1)
		testing.expect_value(t, c.signature_seq, 1)
	})
}

@(test)
test_null_result_clears_and_bumps_seq :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		id := client_next_id(&c)
		c.pending_kind[id] = .SignatureHelp
		c.latest_signature_id = id
		ok_body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":{{"signatures":[{{"label":"f()"}}]}}}}`, id)
		client_feed_bytes(&c, transmute([]u8)frame_message(ok_body, context.temp_allocator))
		testing.expect_value(t, len(c.last_signatures), 1)

		id2 := client_next_id(&c)
		c.pending_kind[id2] = .SignatureHelp
		c.latest_signature_id = id2
		null_body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":null}}`, id2)
		client_feed_bytes(&c, transmute([]u8)frame_message(null_body, context.temp_allocator))
		testing.expect_value(t, len(c.last_signatures), 0)
		testing.expect_value(t, c.signature_seq, 2)
	})
}

@(test)
test_stale_completion_response_is_dropped :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		old_id := client_next_id(&c)
		c.pending_kind[old_id] = .Completion
		new_id := client_next_id(&c)
		c.pending_kind[new_id] = .Completion
		c.latest_completion_id = new_id

		new_body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":[{{"label":"fresh"}}]}}`, new_id)
		client_feed_bytes(&c, transmute([]u8)frame_message(new_body, context.temp_allocator))
		old_body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":[{{"label":"stale"}}]}}`, old_id)
		client_feed_bytes(&c, transmute([]u8)frame_message(old_body, context.temp_allocator))

		testing.expect_value(t, len(c.last_completion), 1)
		testing.expect_value(t, c.last_completion[0].label, "fresh")
		testing.expect_value(t, c.completion_seq, 1)
		_, still_pending := c.pending_kind[old_id]
		testing.expect(t, !still_pending, "stale request should still be removed from pending")
	})
}

@(test)
test_dead_server_is_detected_and_writes_dont_crash :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		// A "server" that exits immediately with status 3.
		ok := client_start(&c, []string{"/bin/sh", "-c", "exit 3"})
		testing.expect(t, ok, "spawned the fake server")
		c.initialized = true
		c.pending_kind[client_next_id(&c)] = .Completion

		for i := 0; i < 200 && !c.dead; i += 1 {
			client_poll(&c)
			time.sleep(5 * time.Millisecond)
		}
		testing.expect(t, c.dead, "poll notices the server exited")
		testing.expect_value(t, c.exit_code, 3)
		testing.expect(t, !c.initialized, "a dead server is no longer initialized")
		testing.expect_value(t, len(c.pending_kind), 0)

		// Writing to it must fail quietly, not raise SIGPIPE.
		testing.expect(t, !client_send_raw(&c, frame_message("{}", context.temp_allocator)), "send to dead server fails")
		client_request_completion(&c, "file:///x.odin", 0, 0)
		client_poll(&c)
	})
}

@(test)
test_write_to_crashed_server_marks_dead :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)

		// Closes stdin right away, then lingers: our writes hit EPIPE
		// while the process itself is still alive.
		ok := client_start(&c, []string{"/bin/sh", "-c", "exec 0<&-; sleep 5"})
		testing.expect(t, ok, "spawned the fake server")
		time.sleep(100 * time.Millisecond)

		body := strings.repeat("x", 1 << 16, context.temp_allocator)
		for i := 0; i < 10 && !c.dead; i += 1 {
			client_send_raw(&c, frame_message(body, context.temp_allocator))
		}
		testing.expect(t, c.dead, "a failed write marks the server dead")
		testing.expect(t, !c.has_process, "process was killed and reaped")
	})
}

@(test)
test_file_uri_percent_encoding_round_trips :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		path := "/Users/me/My Project/naïve#1.odin"
		uri := file_uri(path, context.temp_allocator)
		testing.expect_value(t, uri, "file:///Users/me/My%20Project/na%C3%AFve%231.odin")
		testing.expect_value(t, uri_to_path(uri, context.temp_allocator), path)
		// Lower-case hex from other clients decodes too.
		testing.expect_value(t, uri_to_path("file:///a%2fb%20c", context.temp_allocator), "/a/b c")
	})
}

@(test)
test_uri_key_resolves_symlinks :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	run_leak_free(t, proc(t: ^testing.T) {
		real_dir :: "/tmp/odin_editor_urikey_real"
		link_dir :: "/tmp/odin_editor_urikey_link"
		os.remove_all(real_dir)
		os.remove(link_dir)
		os.make_directory(real_dir)
		defer os.remove_all(real_dir)
		_ = os.write_entire_file(real_dir + "/a.odin", transmute([]u8)string("package a"))
		testing.expect(t, os.symlink(real_dir, link_dir) == nil, "created symlink")
		defer os.remove(link_dir)

		via_link := uri_key(file_uri(link_dir + "/a.odin", context.temp_allocator), context.temp_allocator)
		via_real := uri_key(file_uri(real_dir + "/a.odin", context.temp_allocator), context.temp_allocator)
		testing.expect_value(t, via_link, via_real)
	})
}

@(test)
test_diagnostics_match_across_uri_spellings :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)
		// Like OLS: the compiler reports the resolved /private/tmp path
		// (on macOS /tmp is a symlink; elsewhere both spell the same file).
		os.make_directory("/tmp/odin_editor_diag_key")
		defer os.remove_all("/tmp/odin_editor_diag_key")
		_ = os.write_entire_file("/tmp/odin_editor_diag_key/m.odin", transmute([]u8)string("package m"))
		resolved := resolve_path("/tmp/odin_editor_diag_key/m.odin", context.temp_allocator)

		body := fmt.tprintf(
			`{{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{{"uri":"%s","diagnostics":[{{"range":{{"start":{{"line":0,"character":0}},"end":{{"line":0,"character":1}}}},"message":"m","source":"odin"}}]}}}}`,
			file_uri(resolved, context.temp_allocator))
		client_feed_bytes(&c, transmute([]u8)frame_message(body, context.temp_allocator))

		diags := client_diagnostics_for(&c, "file:///tmp/odin_editor_diag_key/m.odin")
		testing.expect_value(t, len(diags), 1)
		if len(diags) == 1 {
			testing.expect_value(t, diags[0].severity, 1) // absent -> error
			testing.expect_value(t, diags[0].source, "odin")
		}
		testing.expect_value(t, c.diagnostics_seq, 1)

		// A new publish replaces (and frees) the old list.
		client_feed_bytes(&c, transmute([]u8)frame_message(body, context.temp_allocator))
		testing.expect_value(t, len(client_diagnostics_for(&c, "file:///tmp/odin_editor_diag_key/m.odin")), 1)
	})
}

@(test)
test_utf16_column_conversion :: proc(t: ^testing.T) {
	line := "é😀x" // é = 2 bytes/1 unit, 😀 = 4 bytes/2 units
	testing.expect_value(t, byte_col_to_utf16(line, 0), 0)
	testing.expect_value(t, byte_col_to_utf16(line, 2), 1)
	testing.expect_value(t, byte_col_to_utf16(line, 6), 3)
	testing.expect_value(t, byte_col_to_utf16(line, 7), 4)
	testing.expect_value(t, utf16_col_to_byte(line, 1), 2)
	testing.expect_value(t, utf16_col_to_byte(line, 3), 6)
	testing.expect_value(t, utf16_col_to_byte(line, 4), 7)
	testing.expect_value(t, utf16_col_to_byte(line, 99), 7) // clamped
}

@(test)
test_initialize_advertises_tags_and_code_action_literals :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		params := InitializeParams{capabilities = default_client_capabilities()}
		msg := encode_request(1, "initialize", params, context.temp_allocator)
		testing.expect(t, strings.contains(msg, `"tagSupport":{"valueSet":[1,2]}`), msg)
		testing.expect(t, strings.contains(msg, `"codeActionLiteralSupport"`), msg)
		testing.expect(t, strings.contains(msg, `"quickfix"`), msg)
	})
}

@(test)
test_diagnostic_tags_are_parsed :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)
		body := `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///t.odin","diagnostics":[` +
			`{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"severity":4,"message":"unused import","tags":[1]},` +
			`{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},"severity":2,"message":"old","tags":[2]}]}}`
		client_feed_bytes(&c, transmute([]u8)frame_message(body, context.temp_allocator))
		d := client_diagnostics_for(&c, "file:///t.odin")
		testing.expect_value(t, len(d), 2)
		testing.expect(t, d[0].unnecessary && !d[0].deprecated, "first is unnecessary")
		testing.expect(t, d[1].deprecated && !d[1].unnecessary, "second is deprecated")
	})
}

@(test)
test_code_actions_parse_both_edit_shapes_and_skip_commands :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)
		id := client_request_code_action(&c, "file:///t.odin", {}, nil)
		body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":[` +
			`{{"title":"Remove unused imports","kind":"quickfix","isPreferred":true,"edit":{{"changes":{{"file:///t.odin":[{{"range":{{"start":{{"line":2,"character":0}},"end":{{"line":3,"character":0}}}},"newText":""}}]}}}}}},` +
			`{{"title":"Run something","command":"x.y"}},` +
			`{{"title":"Add import","kind":"quickfix","edit":{{"documentChanges":[{{"textDocument":{{"uri":"file:///t.odin","version":3}},"edits":[{{"range":{{"start":{{"line":1,"character":0}},"end":{{"line":1,"character":0}}}},"newText":"import \"core:strings\"\n"}}]}}]}}}}` +
			`]}}`, id)
		client_feed_bytes(&c, transmute([]u8)frame_message(body, context.temp_allocator))
		testing.expect_value(t, c.code_action_seq, 1)
		testing.expect_value(t, len(c.last_code_actions), 2)
		a := c.last_code_actions[0]
		testing.expect(t, a.title == "Remove unused imports" && a.preferred && a.kind == "quickfix", "first action")
		testing.expect_value(t, len(a.edits), 1)
		testing.expect_value(t, a.edits[0].key, "/t.odin")
		testing.expect_value(t, a.edits[0].range.end, Position{3, 0})
		b := c.last_code_actions[1]
		testing.expect_value(t, b.edits[0].new_text, "import \"core:strings\"\n")
	})
}

@(test)
test_initialize_result_sets_sync_kind :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)
		testing.expect_value(t, c.sync_kind, 1) // full until told otherwise
		id := client_next_id(&c)
		c.pending_kind[id] = .Initialize
		body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":{{"capabilities":{{"textDocumentSync":{{"openClose":true,"change":2}}}}}}}}`, id)
		client_feed_bytes(&c, transmute([]u8)frame_message(body, context.temp_allocator))
		testing.expect_value(t, c.sync_kind, 2)

		msg := encode_notification("textDocument/didChange", DidChangeIncrementalParams{
			textDocument = {uri = "file:///x", version = 3},
			contentChanges = {{range = {{1, 2}, {1, 4}}, text = "ab"}},
		}, context.temp_allocator)
		testing.expect(t, strings.contains(msg, `"contentChanges":[{"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":4}},"text":"ab"}]`), msg)
	})
}

@(test)
test_completion_item_docs_snippet_command_and_incomplete :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)
		c.init_options = strings.clone(`{"enable_snippets": true}`)
		params := InitializeParams{capabilities = default_client_capabilities()}
		testing.expect(t, strings.contains(encode_request(1, "initialize", params, context.temp_allocator), `"snippetSupport":true`), "snippet capability")

		id := client_request_completion(&c, "file:///x", 0, 0)
		body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":{{"isIncomplete":true,"items":[` +
			`{{"label":"a","insertTextFormat":2,"insertText":"a($0)","documentation":{{"kind":"markdown","value":"**doc**"}},"command":{{"title":"","command":"editor.action.triggerParameterHints"}}}},` +
			`{{"label":"b","documentation":"plain"}}]}}}}`, id)
		client_feed_bytes(&c, transmute([]u8)frame_message(body, context.temp_allocator))
		testing.expect(t, c.completion_incomplete, "isIncomplete parsed")
		a := c.last_completion[0]
		testing.expect(t, a.is_snippet && a.doc_markdown && a.documentation == "**doc**" && a.command == "editor.action.triggerParameterHints", "first item fields")
		b := c.last_completion[1]
		testing.expect(t, !b.is_snippet && !b.doc_markdown && b.documentation == "plain", "plain string documentation")
	})
}

@(test)
test_hover_contents_shapes :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)
		send :: proc(c: ^Client, result: string) {
			id := client_request_hover(c, "file:///x", 0, 0)
			body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":%s}}`, id, result)
			client_feed_bytes(c, transmute([]u8)frame_message(body, context.temp_allocator))
		}
		send(&c, `{"contents":{"kind":"plaintext","value":"plain"}}`)
		testing.expect(t, c.last_hover == "plain" && !c.last_hover_markdown, "MarkupContent plaintext")
		send(&c, `{"contents":[{"language":"odin","value":"x: int"},"note"]}`)
		testing.expect_value(t, c.last_hover, "```odin\nx: int\n```\n\nnote")
		testing.expect(t, c.last_hover_markdown, "MarkedString array is markdown")
		send(&c, `null`)
		testing.expect_value(t, c.last_hover, "")
		testing.expect_value(t, c.hover_seq, 3)
	})
}

@(test)
test_definition_and_reference_results :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		c := client_init()
		defer client_destroy(&c)
		id := client_request_definition(&c, "file:///a.odin", 1, 2)
		body := fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":{{"uri":"file:///b.odin","range":{{"start":{{"line":4,"character":1}},"end":{{"line":4,"character":5}}}}}}}}`, id)
		client_feed_bytes(&c, transmute([]u8)frame_message(body, context.temp_allocator))
		testing.expect(t, len(c.last_locations) == 1 && c.last_locations[0].key == "/b.odin" && c.last_locations[0].range.start == {4, 1}, "single Location")
		testing.expect_value(t, c.locations_kind, RequestKind.Definition)

		id = client_request_references(&c, "file:///a.odin", 1, 2)
		msg := encode_request(id, "textDocument/references", ReferenceParams{}, context.temp_allocator)
		testing.expect(t, strings.contains(msg, `"context":{"includeDeclaration":false}`), msg) // shape check
		body = fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"result":[{{"uri":"file:///a.odin","range":{{"start":{{"line":0,"character":0}},"end":{{"line":0,"character":1}}}}}},{{"uri":"file:///c.odin","range":{{"start":{{"line":2,"character":3}},"end":{{"line":2,"character":4}}}}}}]}}`, id)
		client_feed_bytes(&c, transmute([]u8)frame_message(body, context.temp_allocator))
		testing.expect_value(t, len(c.last_locations), 2)
		testing.expect_value(t, c.locations_kind, RequestKind.References)
		testing.expect_value(t, c.location_seq, 2)
	})
}
