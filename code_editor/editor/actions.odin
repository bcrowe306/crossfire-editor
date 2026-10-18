// Maps resolved `keymap.Action`s onto `buffer` operations, applied to every
// cursor. Entirely independent of SDL — testable by constructing an Editor
// and calling `editor_apply_action` directly.
package code_editor

import buf "../buffer"
import km "../keymap"

// editor_apply_action executes a non-text-insertion action (navigation,
// selection, editing commands, clipboard, undo/redo) against every cursor
// in the buffer. Returns false if the action isn't handled here (e.g. it's
// a host-level action like Save/Open that the embedding app must wire up).
editor_apply_action :: proc(ed: ^Editor, action: km.Action) -> bool {
	b := &ed.buf
	switch action {
	case .None:
		return true

	case .MoveLeft, .MoveRight, .MoveUp, .MoveDown,
	     .MoveWordLeft, .MoveWordRight,
	     .MoveLineStart, .MoveLineEnd,
	     .MoveDocStart, .MoveDocEnd,
	     .MovePageUp, .MovePageDown,
	     .ExtendLeft, .ExtendRight, .ExtendUp, .ExtendDown,
	     .ExtendWordLeft, .ExtendWordRight,
	     .ExtendLineStart, .ExtendLineEnd,
	     .ExtendDocStart, .ExtendDocEnd,
	     .ExtendPageUp, .ExtendPageDown:
		for &c in b.cursors {
			#partial switch action {
			case .MoveUp, .MoveDown, .MovePageUp, .MovePageDown,
			     .ExtendUp, .ExtendDown, .ExtendPageUp, .ExtendPageDown:
				vertical_move(ed, &c, action)
			case:
				apply_movement(b, &c, action)
			}
		}
		return true

	case .SelectAll:
		// Select-all collapses to a single cursor spanning the document.
		resize(&b.cursors, 1)
		buf.cursor_select_all(b, &b.cursors[0])
		return true

	case .SelectLine:
		for &c in b.cursors {
			buf.cursor_select_line(b, &c)
		}
		return true

	case .SelectWord:
		for &c in b.cursors {
			buf.cursor_select_word(b, &c)
		}
		return true

	case .Backspace:
		buf.buffer_backspace(b)
		return true
	case .BackspaceWord:
		buf.buffer_backspace(b, word_mode = true)
		return true
	case .DeleteForward:
		buf.buffer_delete_forward(b)
		return true
	case .DeleteForwardWord:
		buf.buffer_delete_forward(b, word_mode = true)
		return true
	case .Newline:
		buf.buffer_newline(b)
		return true
	case .IndentOrTab:
		buf.buffer_indent(b, ed.indent_with_tabs)
		return true
	case .DuplicateLineUp, .DuplicateLineDown:
		buf.buffer_duplicate_lines(b, down = action == .DuplicateLineDown)
		return true
	case .MoveLineUp, .MoveLineDown:
		buf.buffer_move_lines(b, -1 if action == .MoveLineUp else 1)
		return true
	case .ToggleLineComment:
		prefix := ed.language.line_comment if len(ed.language.line_comment) > 0 else "//"
		buf.buffer_toggle_line_comment(b, prefix)
		return true
	case .DeleteLine:
		buf.buffer_delete_lines(b)
		return true
	case .InsertLineBelow, .InsertLineAbove:
		buf.buffer_insert_line(b, above = action == .InsertLineAbove)
		return true
	case .OpenKeymapEditor:
		editor_show_window(ed, .Keymap)
		return true
	case .ImportZedKeymap:
		editor_import_keymap(ed, .Zed)
		return true
	case .ImportVSCodeKeymap:
		editor_import_keymap(ed, .VSCode)
		return true
	case .Outdent:
		buf.buffer_outdent(b)
		return true

	case .Undo:
		buf.buffer_undo(b)
		return true
	case .Redo:
		buf.buffer_redo(b)
		return true

	case .Cut, .Copy, .Paste:
		// Clipboard requires SDL; handled in clipboard.odin, which calls
		// back into buffer ops. Reported as unhandled here so the SDL glue
		// layer takes over.
		return false

	case .Save, .SaveAs, .Open:
		return false

	case .AddCursorAbove, .AddCursorBelow:
		editor_add_cursor(ed, action == .AddCursorAbove ? -1 : 1)
		return true

	case .TriggerCompletion, .TriggerSignatureHelp:
		return false

	case .NextDiagnostic:
		return editor_goto_diagnostic(ed, 1)
	case .PrevDiagnostic:
		return editor_goto_diagnostic(ed, -1)
	case .QuickFix:
		editor_request_code_actions(ed)
		return true
	case .ToggleProblems:
		editor_toggle_problems(ed)
		return true
	case .GotoDefinition:
		editor_request_navigation(ed, .Goto)
		return true
	case .PeekDefinition:
		editor_request_navigation(ed, .Peek)
		return true
	case .FindReferences:
		editor_request_navigation(ed, .References)
		return true
	case .NextReference:
		editor_step_reference(ed, 1)
		return true
	case .PrevReference:
		editor_step_reference(ed, -1)
		return true
	case .NavigateBack:
		editor_navigate_back(ed)
		return true
	case .NavigateForward:
		editor_navigate_forward(ed)
		return true

	case .Find:
		editor_open_find(ed)
		return true
	case .Replace:
		editor_open_find(ed, replace = true)
		return true
	case .FindNext:
		editor_find_step(ed, 1)
		return true
	case .FindPrev:
		editor_find_step(ed, -1)
		return true
	case .SelectNextOccurrence:
		editor_select_next_occurrence(ed)
		return true
	case .SelectAllOccurrences:
		editor_select_all_occurrences(ed)
		return true

	case .ZoomIn:
		editor_zoom(ed, 1)
		return true
	case .ZoomOut:
		editor_zoom(ed, -1)
		return true
	case .ZoomReset:
		editor_zoom(ed, 0)
		return true
	case .CommandPalette:
		editor_open_palette(ed)
		return true

	case .Escape:
		for &c in b.cursors {
			c.sel.active = false
		}
		if len(b.cursors) > 1 {
			resize(&b.cursors, 1)
		}
		return true
	}
	return false
}

// vertical_move moves a caret up/down (by line or page) aiming for its
// sticky visual column, so moving across short lines or between tab- and
// space-indented lines doesn't drift, and the caret always lands on a
// character boundary.
@(private)
vertical_move :: proc(ed: ^Editor, c: ^buf.Cursor, action: km.Action) {
	b := &ed.buf
	if !c.has_goal || c.pos != c.goal_at {
		c.goal = editor_visual_col(ed, c.pos)
		c.has_goal = true
	}
	from_line := c.pos.line
	apply_movement(b, c, action)
	if c.pos.line != from_line {
		line := buf.buffer_line_str(b, c.pos.line)
		c.pos.col = byte_col_at_visual(line, f32(c.goal), ed.tab_width)
	}
	c.goal_at = c.pos
}

@(private)
apply_movement :: proc(b: ^buf.Buffer, c: ^buf.Cursor, action: km.Action) {
	#partial switch action {
	case .MoveLeft: buf.cursor_move_left(b, c, false)
	case .ExtendLeft: buf.cursor_move_left(b, c, true)
	case .MoveRight: buf.cursor_move_right(b, c, false)
	case .ExtendRight: buf.cursor_move_right(b, c, true)
	case .MoveUp: buf.cursor_move_up(b, c, false)
	case .ExtendUp: buf.cursor_move_up(b, c, true)
	case .MoveDown: buf.cursor_move_down(b, c, false)
	case .ExtendDown: buf.cursor_move_down(b, c, true)
	case .MoveWordLeft: buf.cursor_move_word_left(b, c, false)
	case .ExtendWordLeft: buf.cursor_move_word_left(b, c, true)
	case .MoveWordRight: buf.cursor_move_word_right(b, c, false)
	case .ExtendWordRight: buf.cursor_move_word_right(b, c, true)
	case .MoveLineStart: buf.cursor_move_line_start(b, c, false)
	case .ExtendLineStart: buf.cursor_move_line_start(b, c, true)
	case .MoveLineEnd: buf.cursor_move_line_end(b, c, false)
	case .ExtendLineEnd: buf.cursor_move_line_end(b, c, true)
	case .MoveDocStart: buf.cursor_move_doc_start(b, c, false)
	case .ExtendDocStart: buf.cursor_move_doc_start(b, c, true)
	case .MoveDocEnd: buf.cursor_move_doc_end(b, c, false)
	case .ExtendDocEnd: buf.cursor_move_doc_end(b, c, true)
	case .MovePageUp: buf.cursor_move_page(b, c, -20, false)
	case .ExtendPageUp: buf.cursor_move_page(b, c, -20, true)
	case .MovePageDown: buf.cursor_move_page(b, c, 20, false)
	case .ExtendPageDown: buf.cursor_move_page(b, c, 20, true)
	}
}

// editor_add_cursor adds a new cursor one line above/below (dir = -1/+1)
// the current primary cursor, at the same column — mirrors VSCode/Zed's
// Ctrl/Cmd+Alt+Up/Down multi-cursor shortcut.
editor_add_cursor :: proc(ed: ^Editor, dir: int) {
	b := &ed.buf
	last := b.cursors[len(b.cursors) - 1]
	target_line := last.pos.line + dir
	if target_line < 0 || target_line >= buf.buffer_line_count(b) {
		return
	}
	col := min(last.pos.col, buf.buffer_line_len(b, target_line))
	append(&b.cursors, buf.Cursor{pos = buf.Position{line = target_line, col = col}})
}

// editor_insert_text types `text` at every cursor (used for both regular
// text-input events and programmatic insertion).
editor_insert_text :: proc(ed: ^Editor, text: string) {
	buf.buffer_type_text(&ed.buf, text)
}
