// Package lsp implements a JSON-RPC 2.0 client for the Language Server
// Protocol (LSP), used to drive an embedded Odin Language Server (OLS,
// https://github.com/DanielGavin/ols) subprocess. This file implements the
// wire-format pieces (message framing + encode/decode) independent of any
// actual process, so they can be unit tested without spawning `ols`.
package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

JSONRPC_VERSION :: "2.0"

// frame_message wraps a JSON body with the LSP `Content-Length` header
// framing used over stdio.
frame_message :: proc(body: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "Content-Length: %d\r\n\r\n%s", len(body), body)
	return strings.to_string(sb)
}

// encode_request builds a framed JSON-RPC request string for `method` with
// the given already-marshalable `params` value.
encode_request :: proc(id: int, method: string, params: $T, allocator := context.allocator) -> string {
	params_bytes, _ := json.marshal(params, allocator = context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"jsonrpc":"2.0","id":`)
	strings.write_int(&sb, id)
	strings.write_string(&sb, `,"method":"`)
	strings.write_string(&sb, method)
	strings.write_string(&sb, `","params":`)
	strings.write_string(&sb, len(params_bytes) > 0 ? string(params_bytes) : "null")
	strings.write_byte(&sb, '}')
	return frame_message(strings.to_string(sb), allocator)
}

// encode_notification is identical to encode_request but omits the `id`
// field, per the JSON-RPC spec for notifications (no response expected).
encode_notification :: proc(method: string, params: $T, allocator := context.allocator) -> string {
	params_bytes, _ := json.marshal(params, allocator = context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"jsonrpc":"2.0","method":"`)
	strings.write_string(&sb, method)
	strings.write_string(&sb, `","params":`)
	strings.write_string(&sb, len(params_bytes) > 0 ? string(params_bytes) : "null")
	strings.write_byte(&sb, '}')
	return frame_message(strings.to_string(sb), allocator)
}

// try_extract_message scans `buf` for one complete `Content-Length`-framed
// message. If found, it returns the JSON body (a slice into `buf`, valid
// until `buf` is mutated) and the total number of bytes (headers + body)
// consumed so the caller can remove them from the front of the buffer.
try_extract_message :: proc(buf: []u8) -> (body: []u8, consumed: int, ok: bool) {
	header_end := find_substring(buf, "\r\n\r\n")
	if header_end < 0 {
		return nil, 0, false
	}
	header_text := string(buf[:header_end])
	content_length := -1
	for line in strings.split_lines_iterator(&header_text) {
		lower_colon := strings.index(line, ":")
		if lower_colon < 0 {
			continue
		}
		key := strings.trim_space(line[:lower_colon])
		val := strings.trim_space(line[lower_colon + 1:])
		if strings.equal_fold(key, "Content-Length") {
			n, parsed_ok := strconv.parse_int(val)
			if parsed_ok {
				content_length = n
			}
		}
	}
	if content_length < 0 {
		return nil, 0, false
	}
	body_start := header_end + 4
	if len(buf) < body_start + content_length {
		return nil, 0, false
	}
	return buf[body_start:body_start + content_length], body_start + content_length, true
}

@(private)
find_substring :: proc(buf: []u8, needle: string) -> int {
	if len(needle) == 0 || len(buf) < len(needle) {
		return -1
	}
	outer: for i := 0; i <= len(buf) - len(needle); i += 1 {
		for j := 0; j < len(needle); j += 1 {
			if buf[i + j] != needle[j] {
				continue outer
			}
		}
		return i
	}
	return -1
}

// decode_message parses a raw JSON body into a generic json.Value so the
// caller can branch on whether it's a request/response/notification by
// inspecting its fields (id/method/result/error).
decode_message :: proc(body: []u8, allocator := context.allocator) -> (value: json.Value, err: json.Error) {
	return json.parse(body, allocator = allocator)
}

json_object_get :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	obj, ok := v.(json.Object)
	if !ok {
		return nil, false
	}
	val, found := obj[key]
	return val, found
}

json_as_int :: proc(v: json.Value) -> (int, bool) {
	#partial switch x in v {
	case json.Integer:
		return int(x), true
	case json.Float:
		return int(x), true
	}
	return 0, false
}

json_as_string :: proc(v: json.Value) -> (string, bool) {
	s, ok := v.(json.String)
	return s, ok
}
