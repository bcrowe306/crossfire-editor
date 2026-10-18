// File load/save API for the host application. Kept dependency-free (just
// core:os) so the buffer package has no SDL/platform requirements.
package buffer

import "core:os"
import "core:strings"

// buffer_load_file reads `path` from disk and replaces the buffer contents.
// Returns false (buffer left untouched) if the file could not be read.
buffer_load_file :: proc(b: ^Buffer, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	buffer_set_text(b, string(data))
	if len(b.file_path) > 0 {
		delete(b.file_path, b.allocator)
	}
	b.file_path = strings.clone(path, b.allocator)
	b.dirty = false
	return true
}

// buffer_save_file writes the buffer contents to `path` and records it as
// the buffer's associated file path.
buffer_save_file :: proc(b: ^Buffer, path: string) -> bool {
	text := buffer_to_string(b, context.temp_allocator)
	err := os.write_entire_file(path, transmute([]u8)text)
	if err != nil {
		return false
	}
	if b.file_path != path {
		if len(b.file_path) > 0 {
			delete(b.file_path, b.allocator)
		}
		b.file_path = strings.clone(path, b.allocator)
	}
	b.dirty = false
	return true
}

// buffer_save saves to the buffer's currently associated file path. Returns
// false if there is no associated path yet (host should prompt and call
// buffer_save_file instead).
buffer_save :: proc(b: ^Buffer) -> bool {
	if len(b.file_path) == 0 {
		return false
	}
	return buffer_save_file(b, b.file_path)
}
