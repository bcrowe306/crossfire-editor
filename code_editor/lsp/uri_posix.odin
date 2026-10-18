#+build !windows
package lsp

import "core:strings"
import "core:sys/posix"

// resolve_path returns the canonical (symlink-free) form of `path`, or
// `path` itself if it doesn't exist.
resolve_path :: proc(path: string, allocator := context.allocator) -> string {
	buf: [4096]u8
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if res := posix.realpath(cpath, raw_data(buf[:])); res != nil {
		return strings.clone(string(res), allocator)
	}
	return strings.clone(path, allocator)
}
