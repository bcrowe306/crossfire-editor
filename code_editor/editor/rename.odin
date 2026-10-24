// Rename Symbol (F2): a small box under the name at the caret, the new name typed in it, Enter
// renames, Escape (or a click elsewhere) cancels. A host's rename provider (providers.odin:
// `prepare_rename`, `rename`) is asked first: it says what it would rename (its title and a note
// on what else changes) and does it, its edits to this document applied as one undo step.
// Without one the language server renames (textDocument/rename): the edits to this document are
// applied the same way, and those to other files are left for the host
// (`editor_take_file_edits`), which applies them where those files are open
// (`editor_apply_lsp_edits`).
package code_editor

import buf "../buffer"
import km "../keymap"
import lspc "../lsp"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// The rename box
Rename_Box :: struct {
	open:     bool,
	// The provider offering it (an index of the registry's), or -1: the language server
	provider: int,
	// What it renames (its strings owned)
	target:   Rename_Target,
	// The name typed, and the caret in it (a byte offset)
	text:     [dynamic]u8,
	caret:    int,
	// The whole name is selected, as when it opens: typing replaces it
	selected: bool,
	// Why the last name didn't do (owned; "" none)
	error:    string,
	// Waiting for the server's answer (its rename_seq when asked)
	waiting:  bool,
	seen_seq: int,
}

@(private)
rename_box_clear :: proc(r: ^Rename_Box) {
	delete(r.target.name)
	delete(r.target.title)
	delete(r.target.note)
	delete(r.error)
	clear(&r.text)
	text := r.text
	r^ = {text = text, provider = -1}
}

@(private)
rename_destroy :: proc(ed: ^Editor) {
	rename_box_clear(&ed.rename)
	delete(ed.rename.text)
	for e in ed.file_edits {
		delete(e.key)
		delete(e.new_text)
	}
	delete(ed.file_edits)
}

// Whether the rename box shows
editor_rename_open :: proc(ed: ^Editor) -> bool {
	return ed.rename.open
}

// The name typed in the rename box (the editor's)
editor_rename_text :: proc(ed: ^Editor) -> string {
	return string(ed.rename.text[:])
}

/*
Opens the rename box for the symbol at the caret: the first rename provider that knows it, else
the language server (the identifier at the caret). Says why in the status line when neither can.
*/
editor_start_rename :: proc(ed: ^Editor) {
	editor_close_completion(ed)
	editor_close_code_actions(ed)
	editor_close_context_menu(ed)
	editor_consume_buffer_changes(ed)
	pos := editor_primary_cursor(ed).pos
	if ed.providers != nil {
		doc := editor_provider_document(ed)
		syntax := editor_syntax_context_at(ed, pos, context.temp_allocator)
		for &prov, i in ed.providers.providers {
			if prov.kind != .Rename || prov.prepare_rename == nil || prov.rename == nil do continue
			ctx := provider_context(&prov, .Invoked)
			ctx.syntax = syntax
			target: Rename_Target
			start := time.tick_now()
			ok := prov.prepare_rename(doc, pos, ctx, &target)
			provider_timed(&prov, start)
			if !ok do continue
			rename_open(ed, i, target)
			return
		}
	}
	if !editor_lsp_ready(ed) {
		editor_set_status(ed, "Nothing to rename here (no language server)")
		return
	}
	start, end := word_range_at(ed, pos)
	line := buf.buffer_line_str(&ed.buf, pos.line)
	if start == end || start.line != end.line || !is_ident_byte(line[start.col]) {
		editor_set_status(ed, "No symbol at the caret")
		return
	}
	name := line[start.col:end.col]
	rename_open(ed, -1, Rename_Target{start = start, end = end, name = name, title = fmt.tprintf("Rename %s", name)})
}

@(private)
rename_open :: proc(ed: ^Editor, provider: int, target: Rename_Target) {
	r := &ed.rename
	rename_box_clear(r)
	r.open = true
	r.provider = provider
	r.target = {
		start = target.start, end = target.end,
		name = strings.clone(target.name), title = strings.clone(target.title), note = strings.clone(target.note),
	}
	append(&r.text, ..transmute([]u8)target.name)
	r.caret = len(r.text)
	r.selected = true
	editor_ensure_cursor_visible(ed)
}

// Closes the rename box without renaming
editor_close_rename :: proc(ed: ^Editor) {
	rename_box_clear(&ed.rename)
}

// Types into the rename box (replacing the name while it's all selected)
editor_rename_text_input :: proc(ed: ^Editor, text: string) {
	r := &ed.rename
	if r.waiting do return
	if r.selected {
		clear(&r.text)
		r.caret = 0
		r.selected = false
	}
	// One line: the first of what's pasted or typed
	line, _, _ := strings.partition(text, "\n")
	line = strings.trim_right(line, "\r")
	inject_at(&r.text, r.caret, ..transmute([]u8)line)
	r.caret += len(line)
	delete(r.error)
	r.error = ""
}

// The rename box's keys: editing the name, Enter renames, Escape cancels (every key is its own)
@(private)
editor_rename_handle_key :: proc(ed: ^Editor, chord: km.Chord) -> bool {
	r := &ed.rename
	primary := .Super in chord.mods || .Ctrl in chord.mods
	prev :: proc(text: []u8, at: int) -> int {
		k := at - 1
		for k > 0 && text[k] & 0xC0 == 0x80 do k -= 1
		return max(k, 0)
	}
	next :: proc(text: []u8, at: int) -> int {
		k := at + 1
		for k < len(text) && text[k] & 0xC0 == 0x80 do k += 1
		return min(k, len(text))
	}
	#partial switch chord.key {
	case .Escape:
		editor_close_rename(ed)
	case .Enter:
		editor_commit_rename(ed)
	case .Backspace:
		if r.waiting do break
		if r.selected {
			clear(&r.text)
			r.caret = 0
			r.selected = false
		} else if r.caret > 0 {
			at := prev(r.text[:], r.caret)
			remove_range(&r.text, at, r.caret)
			r.caret = at
		}
	case .Delete:
		if r.waiting do break
		if r.selected {
			clear(&r.text)
			r.caret = 0
			r.selected = false
		} else if r.caret < len(r.text) {
			remove_range(&r.text, r.caret, next(r.text[:], r.caret))
		}
	case .Left:
		if r.selected do r.caret = 0
		else if r.caret > 0 do r.caret = prev(r.text[:], r.caret)
		r.selected = false
	case .Right:
		if !r.selected && r.caret < len(r.text) do r.caret = next(r.text[:], r.caret)
		if r.selected do r.caret = len(r.text)
		r.selected = false
	case .Home:
		r.caret = 0
		r.selected = false
	case .End:
		r.caret = len(r.text)
		r.selected = false
	case .A:
		if primary do r.selected = true
	case .V:
		if primary && sdl.HasClipboardText() {
			raw := sdl.GetClipboardText()
			if raw != nil do editor_rename_text_input(ed, string(cstring(raw)))
		}
	}
	return true
}

/*
Renames to the name typed: the provider's rename (its edits applied to this document as one undo
step), else the language server's (asked now; its answer is applied when it comes). An invalid
name, or the provider's error, keeps the box open with the reason.
*/
editor_commit_rename :: proc(ed: ^Editor) {
	r := &ed.rename
	if !r.open || r.waiting do return
	name := strings.clone(string(r.text[:]), context.temp_allocator)
	if name == r.target.name {
		editor_close_rename(ed)
		return
	}
	if !rename_is_identifier(name) {
		rename_set_error(r, fmt.tprintf("%q isn't a name (letters, digits and _, not starting with a digit)", name))
		return
	}
	editor_consume_buffer_changes(ed)
	if r.provider >= 0 && ed.providers != nil && r.provider < len(ed.providers.providers) {
		prov := &ed.providers.providers[r.provider]
		result := Rename_Result{edits = make([dynamic]Text_Edit, context.temp_allocator)}
		ctx := provider_context(prov, .Invoked)
		target := r.target
		start := time.tick_now()
		ok := prov.rename(editor_provider_document(ed), target, name, ctx, &result)
		provider_timed(prov, start)
		if result.error != "" || !ok {
			rename_set_error(r, result.error != "" ? result.error : fmt.tprintf("%s can't be renamed", target.name))
			return
		}
		caret := editor_position_after_edits(target.start, result.edits[:])
		if len(result.edits) > 0 do editor_apply_edits(ed, result.edits[:], caret)
		editor_close_rename(ed)
		editor_set_status(ed, result.message != "" ? result.message : fmt.tprintf("Renamed to %s", name))
		return
	}
	if !editor_lsp_ready(ed) {
		rename_set_error(r, "No language server to rename it")
		return
	}
	editor_sync_lsp(ed)
	lspc.client_request_rename(&ed.lsp, ed.document_uri, r.target.start.line, editor_lsp_col(ed, r.target.start), name)
	r.waiting = true
	r.seen_seq = ed.lsp.rename_seq
	r.selected = false
}

@(private)
rename_set_error :: proc(r: ^Rename_Box, message: string) {
	delete(r.error)
	r.error = strings.clone(message)
}

// Whether a name is an Odin identifier (ASCII letters, digits and _, not starting with a digit)
@(private)
rename_is_identifier :: proc(name: string) -> bool {
	if len(name) == 0 || name[0] >= '0' && name[0] <= '9' do return false
	for c in transmute([]u8)name do if !is_ident_byte(c) do return false
	return name != "_"
}

// Where a position ends up after edits (positions in the text before them; they don't overlap):
// moved by those before it, at the start of one it's inside
editor_position_after_edits :: proc(pos: buf.Position, edits: []Text_Edit) -> buf.Position {
	sorted := slice.clone(edits, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Text_Edit) -> bool { return buf.position_less(b.start, a.start) })
	at := pos
	for e in sorted {
		if buf.position_less(at, e.start) do continue
		new_end := text_end_from(e.start, e.text)
		if buf.position_less(at, e.end) {
			// Inside the edit (the renamed name itself): its start
			at = e.start
			continue
		}
		at = buf.position_after_change(at, {start = e.start, old_end = e.end, new_end = new_end})
	}
	return at
}

// The position after `text` inserted at `start`
@(private)
text_end_from :: proc(start: buf.Position, text: string) -> buf.Position {
	lines := strings.count(text, "\n")
	if lines == 0 do return {start.line, start.col + len(text)}
	return {start.line + lines, len(text) - strings.last_index_byte(text, '\n') - 1}
}

// Picks up the server's answer to a rename (from editor_update)
@(private)
editor_update_rename :: proc(ed: ^Editor) {
	r := &ed.rename
	if !r.open || !r.waiting do return
	if !ed.lsp_enabled {
		r.waiting = false
		rename_set_error(r, "The language server stopped")
		return
	}
	if ed.lsp.rename_seq == r.seen_seq do return
	r.waiting = false
	if ed.lsp.rename_error != "" {
		rename_set_error(r, ed.lsp.rename_error)
		return
	}
	edits := ed.lsp.last_rename[:]
	if len(edits) == 0 {
		rename_set_error(r, "The language server found nothing to rename")
		return
	}
	mine := make([dynamic]lspc.Code_Action_Edit, context.temp_allocator)
	files := make(map[string]bool, allocator = context.temp_allocator)
	for e in edits {
		files[e.key] = true
		if e.key == ed.document_key {
			append(&mine, e)
		} else {
			append(&ed.file_edits, lspc.Code_Action_Edit{key = strings.clone(e.key), range = e.range, new_text = strings.clone(e.new_text)})
		}
	}
	editor_apply_lsp_edits(ed, mine[:])
	editor_set_status(ed, fmt.tprintf("Renamed %s to %s: %d place%s in %d file%s", r.target.name, string(r.text[:]),
		len(edits), len(edits) == 1 ? "" : "s", len(files), len(files) == 1 ? "" : "s"))
	editor_close_rename(ed)
}

/*
Applies a language server's edits (UTF-16 ranges) meant for this document as one undo step,
skipping those for other files.

Returns:
- How many were applied
*/
editor_apply_lsp_edits :: proc(ed: ^Editor, edits: []lspc.Code_Action_Edit) -> int {
	count := buf.buffer_line_count(&ed.buf)
	out := make([dynamic]Text_Edit, context.temp_allocator)
	for e in edits {
		if e.key != ed.document_key do continue
		append(&out, Text_Edit{to_buffer_pos(ed, e.range.start, count), to_buffer_pos(ed, e.range.end, count), e.new_text})
	}
	if len(out) == 0 do return 0
	caret := editor_position_after_edits(editor_primary_cursor(ed).pos, out[:])
	editor_apply_edits(ed, out[:], caret)
	return len(out)
}

/*
The edits the language server's last rename made to other files than this one (UTF-16 ranges,
by uri_key), for the host to apply where they're open (`editor_apply_lsp_edits`); taken once.

Returns:
- The edits (temp allocated)
*/
editor_take_file_edits :: proc(ed: ^Editor) -> []lspc.Code_Action_Edit {
	out := make([]lspc.Code_Action_Edit, len(ed.file_edits), context.temp_allocator)
	for e, i in ed.file_edits {
		out[i] = {key = strings.clone(e.key, context.temp_allocator), range = e.range, new_text = strings.clone(e.new_text, context.temp_allocator)}
		delete(e.key)
		delete(e.new_text)
	}
	clear(&ed.file_edits)
	return out
}

// --- layout & rendering ----------------------------------------------------------------

// The rename box: under the name (above it near the bottom), as wide as its text needs
editor_rename_layout :: proc(ed: ^Editor) -> (rect: sdl.FRect, ok: bool) {
	r := &ed.rename
	if !r.open do return
	lines := 3
	cols := max(text_cols(r.target.title), text_cols(string(r.text[:])) + 4, 24)
	note := rename_note(r)
	cols = max(cols, min(text_cols(note), 60))
	x, y := editor_position_to_screen(ed, r.target.start)
	top, h, _ := place_popup(ed, lines, y, y + ed.char_h, prefer_above = false)
	left := ed.origin_x + editor_gutter_width(ed)
	right := left + f32(ed.visible_cols) * ed.char_w
	w := min(f32(cols + 2) * ed.char_w + 2 * POPUP_PAD, right - left)
	return {clamp(x - POPUP_PAD, left, max(left, right - w)), top, w, h}, true
}

// The box's last line: the error, "Renaming...", or the provider's note
@(private)
rename_note :: proc(r: ^Rename_Box) -> string {
	switch {
	case r.error != "": return r.error
	case r.waiting: return "Renaming..."
	}
	return r.target.note != "" ? r.target.note : "Enter to rename, Escape to cancel"
}

@(private)
render_rename_box :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme) {
	rect, ok := editor_rename_layout(ed)
	if !ok || font == nil do return
	r := &ed.rename
	draw_popup_box(renderer, rect, theme)
	saved := clip_push(renderer, rect)
	defer clip_pop(renderer, saved)
	room := max(int((rect.w - 2 * POPUP_PAD) / ed.char_w), 1)
	x := rect.x + POPUP_PAD
	y := rect.y + POPUP_PAD
	draw_text(renderer, font, truncate_cols(r.target.title, room), x, y, theme.popup_text_dim, ed.char_h)
	// The name in a field, the caret (or the selection) in it
	y += ed.char_h
	field := sdl.FRect{x, y + 1, rect.w - 2 * POPUP_PAD, ed.char_h - 2}
	fill_rect(renderer, field, theme.background)
	text := string(r.text[:])
	tx := x + ed.char_w * 0.5
	if r.selected && len(text) > 0 {
		fill_rect(renderer, {tx, y + 2, f32(text_cols(text)) * ed.char_w, ed.char_h - 4}, theme.selection)
	}
	draw_text(renderer, font, truncate_cols(text, room - 1), tx, y, theme.text_default, ed.char_h)
	if !r.selected && !r.waiting {
		cx := tx + f32(text_cols(text[:min(r.caret, len(text))])) * ed.char_w
		fill_rect(renderer, {cx, y + 2, 2, ed.char_h - 4}, theme.cursor)
	}
	y += ed.char_h
	color := r.error != "" ? theme.diag_error : theme.popup_text_dim
	draw_text(renderer, font, truncate_cols(rename_note(r), room), x, y, color, ed.char_h)
}
