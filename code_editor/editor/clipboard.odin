// Clipboard integration via SDL3. Copy/cut extract the primary cursor's
// selected text (joining multi-cursor selections with newlines); paste
// inserts clipboard text at every cursor through the normal
// `editor_insert_text` path so it participates in undo history.
package code_editor

import buf "../buffer"
import km "../keymap"
import "core:strings"
import sdl "vendor:sdl3"

editor_handle_clipboard_action :: proc(ed: ^Editor, action: km.Action) {
	#partial switch action {
	case .Copy:
		editor_copy(ed)
	case .Cut:
		editor_cut(ed)
	case .Paste:
		editor_paste(ed)
	case:
	}
}

@(private)
editor_selected_text :: proc(ed: ^Editor, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for c, i in ed.buf.cursors {
		start, end, ok := buf.selection_range(c)
		if !ok {
			continue
		}
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		if start.line == end.line {
			strings.write_string(&sb, buf.buffer_line_str(&ed.buf, start.line)[start.col:end.col])
		} else {
			strings.write_string(&sb, buf.buffer_line_str(&ed.buf, start.line)[start.col:])
			for ln := start.line + 1; ln < end.line; ln += 1 {
				strings.write_byte(&sb, '\n')
				strings.write_string(&sb, buf.buffer_line_str(&ed.buf, ln))
			}
			strings.write_byte(&sb, '\n')
			strings.write_string(&sb, buf.buffer_line_str(&ed.buf, end.line)[:end.col])
		}
	}
	return strings.to_string(sb)
}

editor_copy :: proc(ed: ^Editor) {
	text := editor_selected_text(ed)
	if len(text) == 0 {
		return
	}
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	_ = sdl.SetClipboardText(cstr)
}

editor_cut :: proc(ed: ^Editor) {
	editor_copy(ed)
	group := buf.buffer_next_group(&ed.buf)
	for &c in ed.buf.cursors {
		buf.buffer_delete_selection_for_cursor(&ed.buf, &c, group)
	}
}

editor_paste :: proc(ed: ^Editor) {
	if !sdl.HasClipboardText() {
		return
	}
	raw := sdl.GetClipboardText()
	if raw == nil {
		return
	}
	text := string(cstring(raw))
	if len(text) == 0 {
		return
	}
	editor_insert_text(ed, text)
}
