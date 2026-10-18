// Problems panel: a list of every diagnostic the language server has
// reported — the open document's (from the edit-tracking overlay) and
// other files' (e.g. the rest of the package after `odin check`) — docked
// at the bottom of the editor. Toggle with Ctrl/Cmd+Shift+M (VSCode);
// click a row to jump to it. Problems in other files raise an "open file"
// request the host services via editor_take_open_request, since only the
// host knows how it manages documents. Hosts with their own UI can call
// editor_problems and leave the panel closed.
package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

PROBLEMS_PANEL_ROWS :: 8 // header + 7 entries

Problems_Panel :: struct {
	open:   bool,
	scroll: int, // first visible problem index
	// Pending "open this file at this position" for the host.
	open_request:     bool,
	open_request_path: string,
	open_request_pos:  buf.Position,
}

Problem :: struct {
	path:     string, // filesystem path (temp)
	current:  bool,   // in the open document
	pos:      buf.Position, // byte position (current doc) or UTF-16 column (others)
	severity: Diagnostic_Severity,
	message:  string,
}

// editor_text_rows is the number of rows available for text (the visible
// rows minus the problems panel when it's open).
editor_text_rows :: proc(ed: ^Editor) -> int {
	if ed.problems.open || ed.nav.refs.open {
		return max(1, ed.visible_rows - PROBLEMS_PANEL_ROWS)
	}
	return ed.visible_rows
}

editor_toggle_problems :: proc(ed: ^Editor) {
	ed.problems.open = !ed.problems.open
	ed.problems.scroll = 0
	if ed.problems.open {
		ed.nav.refs.open = false // they share the bottom panel
	}
	editor_ensure_cursor_visible(ed)
}

// editor_problems lists all known problems: the current document's first
// (in order), then other files sorted by path and line (temp-allocated).
editor_problems :: proc(ed: ^Editor) -> []Problem {
	out := make([dynamic]Problem, context.temp_allocator)
	if !ed.lsp_enabled {
		return out[:]
	}
	cur_path := ed.document_key
	for d in editor_diagnostics(ed) {
		append(&out, Problem{path = cur_path, current = true, pos = d.start, severity = d.severity, message = d.message})
	}
	others := make([dynamic]Problem, context.temp_allocator)
	for key, list in ed.lsp.diagnostics {
		if key == ed.document_key {
			continue
		}
		for d in list {
			append(&others, Problem{
				path     = key,
				pos      = {d.range.start.line, d.range.start.character},
				severity = Diagnostic_Severity(clamp(d.severity, 1, 4)),
				message  = d.message,
			})
		}
	}
	slice.sort_by(others[:], proc(a, b: Problem) -> bool {
		if a.path != b.path {
			return a.path < b.path
		}
		return buf.position_less(a.pos, b.pos)
	})
	append(&out, ..others[:])
	return out[:]
}

// problems_row_at maps a window y inside the panel to a problem index
// (-1 for the header row).
problems_row_at :: proc(ed: ^Editor, y: f32) -> int {
	top := ed.origin_y + f32(editor_text_rows(ed)) * ed.char_h
	row := int((y - top) / ed.char_h)
	if row <= 0 {
		return -1
	}
	return ed.problems.scroll + row - 1
}

// editor_open_problem jumps to problem `index`: in the current document
// the caret moves there; otherwise an open request is queued for the host.
editor_open_problem :: proc(ed: ^Editor, index: int) -> bool {
	problems := editor_problems(ed)
	if index < 0 || index >= len(problems) {
		return false
	}
	p := problems[index]
	if p.current {
		resize(&ed.buf.cursors, 1)
		ed.buf.cursors[0] = {pos = editor_clamp_to_buffer(ed, p.pos.line, p.pos.col)}
		editor_close_completion(ed)
		editor_ensure_cursor_visible(ed)
		ed.diag_tip = {source = .Keyboard, pos = ed.buf.cursors[0].pos}
		return true
	}
	pr := &ed.problems
	delete(pr.open_request_path)
	pr.open_request = true
	pr.open_request_path = strings.clone(p.path)
	pr.open_request_pos = p.pos // UTF-16 column; the host converts after loading
	return true
}

// editor_take_open_request returns (and clears) a pending request to open
// another file at a position. `path` stays valid until the next request.
// Positions use the server's UTF-16 column; pass them to
// editor_goto_lsp_position after loading the file.
editor_take_open_request :: proc(ed: ^Editor) -> (path: string, line, character: int, ok: bool) {
	pr := &ed.problems
	if !pr.open_request {
		return
	}
	pr.open_request = false
	return pr.open_request_path, pr.open_request_pos.line, pr.open_request_pos.col, true
}

// editor_goto_lsp_position puts the caret at an LSP (line, UTF-16
// character) position in the current document.
editor_goto_lsp_position :: proc(ed: ^Editor, line, character: int) {
	l := clamp(line, 0, buf.buffer_line_count(&ed.buf) - 1)
	col := lspc.utf16_col_to_byte(buf.buffer_line_str(&ed.buf, l), character)
	resize(&ed.buf.cursors, 1)
	ed.buf.cursors[0] = {pos = {l, col}}
	editor_ensure_cursor_visible(ed)
}

@(private)
problems_destroy :: proc(pr: ^Problems_Panel) {
	delete(pr.open_request_path)
}

@(private)
problems_scroll_by :: proc(ed: ^Editor, delta: int) {
	n := len(editor_problems(ed))
	ed.problems.scroll = clamp(ed.problems.scroll + delta, 0, max(0, n - (PROBLEMS_PANEL_ROWS - 1)))
}

@(private)
render_problems_panel :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, theme: Theme, origin_x, origin_y: f32) {
	if !ed.problems.open || font == nil {
		return
	}
	top := origin_y + f32(editor_text_rows(ed)) * ed.char_h
	width := editor_gutter_width(ed) + f32(ed.visible_cols) * ed.char_w
	fill_rect(renderer, {origin_x, top, width, f32(PROBLEMS_PANEL_ROWS) * ed.char_h}, theme.popup_bg)
	fill_rect(renderer, {origin_x, top, width, 1}, theme.popup_border)

	problems := editor_problems(ed)
	counts: [Diagnostic_Severity]int
	for p in problems {
		counts[p.severity] += 1
	}
	header := fmt.tprintf("PROBLEMS  %d errors  %d warnings  %d info  %d hints",
		counts[.Error], counts[.Warning], counts[.Information], counts[.Hint])
	draw_text(renderer, font, header, origin_x + POPUP_PAD, top + 1, theme.popup_text_dim, ed.char_h)
	if len(problems) == 0 {
		draw_text(renderer, font, "No problems have been detected.", origin_x + 2 * POPUP_PAD, top + ed.char_h, theme.popup_text_dim, ed.char_h)
		return
	}

	last := min(len(problems), ed.problems.scroll + PROBLEMS_PANEL_ROWS - 1)
	for i in ed.problems.scroll ..< last {
		p := problems[i]
		y := top + f32(i - ed.problems.scroll + 1) * ed.char_h
		x := origin_x + 2 * POPUP_PAD
		if ed.mouse.zone == .Problems && problems_row_at(ed, ed.mouse.y) == i {
			fill_rect(renderer, {origin_x, y, width, ed.char_h}, theme.popup_selected)
		}
		label := severity_label(p.severity)
		draw_text(renderer, font, label, x, y, severity_color(theme, p.severity), ed.char_h)
		x += 8 * ed.char_w
		loc := fmt.tprintf("%s:%d:%d", filepath.base(p.path), p.pos.line + 1, p.pos.col + 1)
		draw_text(renderer, font, loc, x, y, theme.popup_text_dim, ed.char_h)
		x += f32(max(text_cols(loc) + 2, 20)) * ed.char_w
		first_line := p.message
		if nl := strings.index_byte(first_line, '\n'); nl >= 0 {
			first_line = first_line[:nl]
		}
		room := int((origin_x + width - x) / ed.char_w) - 1
		draw_text(renderer, font, truncate_cols(first_line, room), x, y, theme.popup_text, ed.char_h)
	}
}
