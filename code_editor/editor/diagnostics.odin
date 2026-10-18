// Diagnostics (errors/warnings from textDocument/publishDiagnostics):
// conversion of the server's UTF-16 ranges to buffer positions, per-line
// severity for gutter markers, lookup at a position, F8 / Shift+F8
// navigation, and the tooltip state for showing a diagnostic's message on
// mouse hover (after a short dwell) or after keyboard navigation.
// Rendering lives in render_diagnostics.odin.
package code_editor

import buf "../buffer"
import lspc "../lsp"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

DIAG_HOVER_DELAY :: 350 * time.Millisecond

Diagnostic_Severity :: enum {
	Error       = 1,
	Warning     = 2,
	Information = 3,
	Hint        = 4,
}

// Diag is a diagnostic in buffer coordinates. `end` is exclusive and
// always > `start` on the same line for empty server ranges (widened to
// one character, or the phantom cell past the end of the line).
Diag :: struct {
	start, end:  buf.Position,
	severity:    Diagnostic_Severity,
	message:     string, // owned by the overlay
	source:      string,
	unnecessary: bool,   // tag 1: render faded
	deprecated:  bool,   // tag 2: render struck through
	// The range as the server sent it (UTF-16, server's text version),
	// used to recognise the same diagnostic when it's republished.
	raw:         lspc.Range,
}

// Diag_Overlay is the editor's own copy of the current document's
// diagnostics in buffer coordinates. It's rebuilt whenever the server
// publishes (or restarts), and between publishes every buffer edit is
// applied to it, so squiggles follow the text as you type instead of
// sitting at stale positions until the next publish (which for
// `odin check` results is the next save).
Diag_Overlay :: struct {
	items:        [dynamic]Diag,
	built_seq:    int, // lsp.diagnostics_seq the items came from (-1: never)
	built_server: int, // supervisor crash count at build time
	built_key:    string,
	// The buffer was reset (text replaced) since the last refresh: shifted
	// positions are meaningless, rebuild from scratch.
	reset_pending: bool,
}

@(private)
diag_overlay_clear :: proc(o: ^Diag_Overlay) {
	for d in o.items {
		delete(d.message)
		delete(d.source)
	}
	clear(&o.items)
}

@(private)
diag_overlay_destroy :: proc(o: ^Diag_Overlay) {
	diag_overlay_clear(o)
	delete(o.items)
	delete(o.built_key)
}

Tip_Source :: enum {
	None,
	Mouse,
	Keyboard,
}

Diagnostic_Tooltip :: struct {
	source:    Tip_Source,
	// Diagnostics covering `pos` (or, when line_only, any on pos.line) are
	// shown; the tip disappears as soon as there are none.
	pos:       buf.Position,
	line_only: bool,

	// Pending mouse hover: shown once the pointer rests on the same cell
	// for DIAG_HOVER_DELAY.
	hover_valid:     bool,
	hover_pos:       buf.Position,
	hover_line_only: bool,
	hover_since:     time.Tick,
}

// editor_diagnostics returns the current document's diagnostics in buffer
// coordinates, sorted by start position. The slice is owned by the editor
// and valid until the next edit or publish.
editor_diagnostics :: proc(ed: ^Editor) -> []Diag {
	editor_refresh_diag_overlay(ed)
	return ed.diag_overlay.items[:]
}

// editor_refresh_diag_overlay applies pending buffer edits to the overlay
// and rebuilds it if the server published since it was built.
editor_refresh_diag_overlay :: proc(ed: ^Editor) {
	o := &ed.diag_overlay
	editor_consume_buffer_changes(ed)
	reset := o.reset_pending
	o.reset_pending = false
	if !ed.lsp_enabled || len(ed.document_key) == 0 {
		diag_overlay_clear(o)
		o.built_seq = -1
		return
	}
	stale := reset || o.built_seq != ed.lsp.diagnostics_seq ||
		o.built_server != ed.lsp_supervisor.total_crashes || o.built_key != ed.document_key
	if !stale {
		return // edits were already applied by editor_consume_buffer_changes
	}

	// Servers often republish diagnostics they haven't recomputed (OLS
	// re-sends the last `odin check` results with every parse-only
	// update). An identical republished entry is the same diagnostic, so
	// it keeps the position we've been shifting instead of snapping back.
	old := o.items
	o.items = make([dynamic]Diag, 0, len(old))
	defer {
		for d in old {
			delete(d.message)
			delete(d.source)
		}
		delete(old)
	}
	keep_old := !reset && o.built_key == ed.document_key && o.built_server == ed.lsp_supervisor.total_crashes
	o.built_seq = ed.lsp.diagnostics_seq
	o.built_server = ed.lsp_supervisor.total_crashes
	if o.built_key != ed.document_key {
		delete(o.built_key)
		o.built_key = strings.clone(ed.document_key)
	}
	raw := lspc.client_diagnostics_for_key(&ed.lsp, ed.document_key)
	count := buf.buffer_line_count(&ed.buf)
	for d in raw {
		start := to_buffer_pos(ed, d.range.start, count)
		end := to_buffer_pos(ed, d.range.end, count)
		if buf.position_less(end, start) {
			start, end = end, start
		}
		if keep_old {
			for prev in old {
				if prev.raw == d.range && prev.message == d.message && int(prev.severity) == clamp(d.severity, 1, 4) {
					start, end = prev.start, prev.end
					break
				}
			}
		}
		append(&o.items, Diag{
			raw         = d.range,
			start       = start,
			end         = end,
			severity    = Diagnostic_Severity(clamp(d.severity, 1, 4)),
			message     = strings.clone(d.message),
			source      = strings.clone(d.source),
			unnecessary = d.unnecessary,
			deprecated  = d.deprecated,
		})
	}
	slice.sort_by(o.items[:], proc(a, b: Diag) -> bool {
		return buf.position_less(a.start, b.start)
	})
}

// diag_extent returns the range to draw/hit-test for `d`: zero-width
// ranges (e.g. "expected ';'") cover the next character, or the phantom
// cell just past the end of the line.
diag_extent :: proc(ed: ^Editor, d: Diag) -> (start, end: buf.Position) {
	start, end = d.start, d.end
	if end == start {
		end.col = start.col + 1
		line := buf.buffer_line_str(&ed.buf, start.line)
		if start.col < len(line) {
			_, size := utf8.decode_rune_in_string(line[start.col:])
			end.col = start.col + size
		}
	}
	return
}

@(private)
to_buffer_pos :: proc(ed: ^Editor, p: lspc.Position, line_count: int) -> buf.Position {
	// Ranges can be stale by a keystroke or two (the server answers the
	// previous version); clamp instead of trusting them.
	line := clamp(p.line, 0, max(line_count - 1, 0))
	return {line, lspc.utf16_col_to_byte(buf.buffer_line_str(&ed.buf, line), p.character)}
}

// editor_diagnostic_counts tallies the current document's diagnostics by
// severity (index with Diagnostic_Severity).
editor_diagnostic_counts :: proc(ed: ^Editor) -> (counts: [Diagnostic_Severity]int) {
	for d in editor_diagnostics(ed) {
		counts[d.severity] += 1
	}
	return
}

// diag_covers_line reports whether `d` touches `line`.
diag_covers_line :: proc(d: Diag, line: int) -> bool {
	return d.start.line <= line && line <= d.end.line
}

// diag_contains reports whether the character at `pos` is inside `d`
// (with zero-width ranges widened by diag_extent).
diag_contains :: proc(ed: ^Editor, d: Diag, pos: buf.Position) -> bool {
	start, end := diag_extent(ed, d)
	return !buf.position_less(pos, start) && buf.position_less(pos, end)
}

// line_severity returns the most severe diagnostic on `line` (ok=false if
// none).
line_severity :: proc(diags: []Diag, line: int) -> (sev: Diagnostic_Severity, ok: bool) {
	sev = .Hint
	for d in diags {
		if diag_covers_line(d, line) && d.severity <= sev {
			sev, ok = d.severity, true
		}
	}
	return
}

// editor_diagnostics_at returns the diagnostics covering `pos` (or every
// diagnostic on pos.line when `line_only`), most severe first.
editor_diagnostics_at :: proc(ed: ^Editor, pos: buf.Position, line_only := false) -> []Diag {
	hits := make([dynamic]Diag, context.temp_allocator)
	for d in editor_diagnostics(ed) {
		if line_only ? diag_covers_line(d, pos.line) : diag_contains(ed, d, pos) {
			append(&hits, d)
		}
	}
	slice.stable_sort_by(hits[:], proc(a, b: Diag) -> bool {return a.severity < b.severity})
	return hits[:]
}

// editor_goto_diagnostic moves the caret to the next (dir=+1) or previous
// (dir=-1) diagnostic, wrapping around, and shows its message — VSCode's
// F8 / Shift+F8.
editor_goto_diagnostic :: proc(ed: ^Editor, dir: int) -> bool {
	diags := editor_diagnostics(ed)
	if len(diags) == 0 {
		return true
	}
	p := editor_primary_cursor(ed).pos
	target := diags[0] if dir > 0 else diags[len(diags) - 1]
	if dir > 0 {
		for d in diags {
			if buf.position_less(p, d.start) {
				target = d
				break
			}
		}
	} else {
		#reverse for d in diags {
			if buf.position_less(d.start, p) {
				target = d
				break
			}
		}
	}
	resize(&ed.buf.cursors, 1)
	ed.buf.cursors[0] = {pos = target.start}
	editor_close_completion(ed)
	editor_ensure_cursor_visible(ed)
	ed.diag_tip = {source = .Keyboard, pos = target.start}
	return true
}

// editor_diag_tooltip_items returns the diagnostics the tooltip should
// show right now (empty = hidden). Hidden while the completion list is up.
editor_diag_tooltip_items :: proc(ed: ^Editor) -> []Diag {
	tip := &ed.diag_tip
	if tip.source == .None || editor_completion_visible(ed) {
		return nil
	}
	return editor_diagnostics_at(ed, tip.pos, tip.line_only)
}

// editor_track_diag_hover records what the pointer is over (called on
// mouse motion). Resting on the same cell arms the hover tooltip; moving
// to a cell without diagnostics hides a mouse-opened tooltip — unless the
// pointer is over the tooltip itself, so its text can be read.
@(private)
editor_track_diag_hover :: proc(ed: ^Editor, hit: Hit, x, y: f32) {
	tip := &ed.diag_tip
	if layout, ok := editor_diag_tooltip_layout(ed); ok && in_rect(layout.rect, x, y) {
		tip.hover_valid = false
		return
	}
	if rect, _, ok := editor_hover_layout(ed); ok && in_rect(rect, x, y) {
		return // reading the hover tooltip
	}
	pos := hit.pos
	line_only := false
	valid := false
	switch hit.zone {
	case .Text:
		if cell, inside := editor_screen_to_cell(ed, x, y); inside {
			pos, valid = cell, true
		}
	case .Gutter:
		line_only, valid = true, true
	case .Outside, .Completion, .Signature, .Problems, .Code_Actions, .Find, .Context_Menu, .Scrollbar, .Palette, .References, .Peek, .Tool_Window:
	}
	if !valid || (tip.hover_valid && (pos != tip.hover_pos || line_only != tip.hover_line_only)) || !tip.hover_valid {
		tip.hover_since = time.tick_now()
	}
	tip.hover_valid = valid
	tip.hover_pos = pos
	tip.hover_line_only = line_only
	if ed.hover.visible && (!valid || line_only || pos != ed.hover.pos) {
		editor_hide_hover(ed)
	}
	if tip.source == .Mouse && (!valid || len(editor_diagnostics_at(ed, pos, line_only)) == 0) {
		tip.source = .None
	}
}

// editor_screen_to_cell maps window pixels to the character cell under
// them (floored, unlike editor_screen_to_position which rounds to the
// nearest caret boundary).
editor_screen_to_cell :: proc(ed: ^Editor, x, y: f32) -> (pos: buf.Position, inside: bool) {
	if ed.char_w <= 0 || ed.char_h <= 0 || y < ed.origin_y {
		return {}, false
	}
	line := ed.scroll_line + int((y - ed.origin_y) / ed.char_h)
	if line >= buf.buffer_line_count(&ed.buf) {
		return {}, false
	}
	vcol := f32(ed.scroll_col) + (x - ed.origin_x - editor_gutter_width(ed)) / ed.char_w
	col, ok := byte_col_at_cell(buf.buffer_line_str(&ed.buf, line), vcol, ed.tab_width)
	return {line, col}, ok
}

// editor_update_diagnostics advances the tooltip state each frame.
editor_update_diagnostics :: proc(ed: ^Editor) {
	editor_update_hover(ed)
	tip := &ed.diag_tip
	switch tip.source {
	case .Keyboard:
		// A keyboard-opened tip stays until the caret moves away.
		if editor_primary_cursor(ed).pos != tip.pos {
			tip.source = .None
		}
	case .Mouse, .None:
		if tip.hover_valid && ed.mouse.drag == .None &&
		   time.tick_since(tip.hover_since) >= DIAG_HOVER_DELAY &&
		   len(editor_diagnostics_at(ed, tip.hover_pos, tip.hover_line_only)) > 0 {
			tip.source = .Mouse
			tip.pos = tip.hover_pos
			tip.line_only = tip.hover_line_only
		}
	}
}
