// File URIs and LSP positions.
//
// - file_uri / uri_to_path: RFC 3986 percent-encoding, so paths with
//   spaces or non-ASCII characters round-trip.
// - uri_key: the identity used to match a server's URIs to ours. Servers
//   don't echo our spelling: OLS reports `odin check` results under the
//   compiler's resolved path (e.g. /private/tmp/... for a file we opened as
//   /tmp/... on macOS), so keys are decoded and symlink-resolved.
// - utf16_col_to_byte / byte_col_to_utf16: LSP `character` offsets count
//   UTF-16 code units; the buffer stores UTF-8 byte offsets.
package lsp

import "core:strings"
import "core:unicode/utf8"

@(private)
HEX := "0123456789ABCDEF"

@(private)
uri_keep_byte :: proc(c: u8) -> bool {
	switch c {
	case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~', '/', ':':
		return true
	}
	return false
}

// file_uri converts an absolute filesystem path to a `file://` URI.
file_uri :: proc(path: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(0, len(path) + 8, allocator)
	strings.write_string(&sb, "file://")
	p := path
	when ODIN_OS == .Windows {
		// C:\x\y -> file:///C:/x/y
		strings.write_byte(&sb, '/')
	}
	for i in 0 ..< len(p) {
		c := p[i]
		when ODIN_OS == .Windows {
			if c == '\\' {
				c = '/'
			}
		}
		if uri_keep_byte(c) {
			strings.write_byte(&sb, c)
		} else {
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, HEX[c >> 4])
			strings.write_byte(&sb, HEX[c & 0xF])
		}
	}
	return strings.to_string(sb)
}

@(private)
hex_val :: proc(c: u8) -> (int, bool) {
	switch c {
	case '0' ..= '9': return int(c - '0'), true
	case 'a' ..= 'f': return int(c - 'a' + 10), true
	case 'A' ..= 'F': return int(c - 'A' + 10), true
	}
	return 0, false
}

// uri_to_path decodes a `file://` URI back into a filesystem path
// (non-file URIs are returned decoded but otherwise unchanged).
uri_to_path :: proc(uri: string, allocator := context.allocator) -> string {
	s := uri
	if strings.has_prefix(s, "file://") {
		s = s[len("file://"):]
		when ODIN_OS == .Windows {
			if len(s) >= 3 && s[0] == '/' && s[2] == ':' {
				s = s[1:]
			}
		}
	}
	sb := strings.builder_make(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			hi, ok1 := hex_val(s[i + 1])
			lo, ok2 := hex_val(s[i + 2])
			if ok1 && ok2 {
				strings.write_byte(&sb, u8(hi << 4 | lo))
				i += 2
				continue
			}
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// uri_key normalizes a URI for identity comparison (see file comment).
uri_key :: proc(uri: string, allocator := context.allocator) -> string {
	path := uri_to_path(uri, context.temp_allocator)
	return resolve_path(path, allocator)
}

// utf16_col_to_byte converts an LSP `character` (UTF-16 code units) on
// `line` to a byte offset, clamped to the line.
utf16_col_to_byte :: proc(line: string, character: int) -> int {
	units := 0
	for r, i in line {
		if units >= character {
			return i
		}
		units += 2 if r > 0xFFFF else 1
	}
	return len(line)
}

// byte_col_to_utf16 converts a byte offset on `line` to UTF-16 code units.
byte_col_to_utf16 :: proc(line: string, col: int) -> int {
	units := 0
	limit := min(col, len(line))
	for i := 0; i < limit; {
		r, size := utf8.decode_rune_in_string(line[i:])
		units += 2 if r > 0xFFFF else 1
		i += size
	}
	return units
}
