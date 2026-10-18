#+build windows
package lsp

import "core:strings"

// resolve_path normalizes case-insensitively compared Windows paths.
resolve_path :: proc(path: string, allocator := context.allocator) -> string {
	return strings.to_lower(path, allocator)
}
