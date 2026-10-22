// SDL3 event handling: translates keyboard/text-input events into keymap
// chords/actions and buffer mutations. This is the thin glue layer that
// depends on SDL; the pure logic it calls into (editor_apply_action,
// buffer ops) is unit tested independently.
package code_editor

import km "../keymap"
import sdl "vendor:sdl3"

// editor_handle_event processes one SDL event. Returns true if the editor
// consumed it (host can use this to decide whether to also forward the
// event elsewhere, e.g. UI focus chrome around the editor widget).
editor_handle_event :: proc(ed: ^Editor, ev: sdl.Event) -> bool {
	#partial switch ev.type {
	case .KEY_DOWN:
		return editor_handle_key_down(ed, ev.key)
	case .TEXT_INPUT:
		text := string(ev.text.text)
		editor_hide_hover(ed)
		editor_close_context_menu(ed)
		if len(text) > 0 && ed.palette.open {
			editor_palette_text_input(ed, text)
			return true
		}
		if ed.window != .Text {
			editor_window_text_input(ed, text)
			return true
		}
		if len(text) > 0 && ed.find.focused {
			editor_find_text_input(ed, text)
			return true
		}
		if len(text) > 0 {
			editor_insert_text(ed, text)
			editor_ensure_cursor_visible(ed)
			editor_after_text_input(ed, text)
			return true
		}
	case .KEY_UP:
		editor_track_modifier_key(ed, ev.key)
	case .MOUSE_WHEEL:
		return editor_handle_mouse_wheel(ed, ev.wheel)
	case .MOUSE_BUTTON_DOWN:
		return editor_handle_mouse_down(ed, ev.button)
	case .MOUSE_BUTTON_UP:
		return editor_handle_mouse_up(ed, ev.button)
	case .MOUSE_MOTION:
		return editor_handle_mouse_motion(ed, ev.motion)
	case .WINDOW_MOUSE_LEAVE:
		ed.mouse.zone = .Outside
	case .WINDOW_FOCUS_LOST:
		// Key-ups for held modifiers go to whichever window has focus now.
		ed.key_mods = {}
		ed.mouse.drag = .None
	}
	return false
}

@(private)
editor_handle_key_down :: proc(ed: ^Editor, key: sdl.KeyboardEvent) -> bool {
	editor_track_modifier_key(ed, key)
	chord := sdl_event_to_chord(key)
	if ed.palette.open && chord.key != .Unknown {
		// The palette owns the keyboard while open.
		return editor_palette_handle_key(ed, chord)
	}
	if ed.window != .Text {
		// A tool window owns the keyboard (modifier presses are ignored).
		return chord.key == .Unknown || editor_window_handle_key(ed, chord)
	}
	if ed.menu.open && chord.key != .Unknown {
		// An open context menu owns the keyboard, even over the find bar.
		editor_handle_menu_key(ed, chord)
		return true
	}
	if ed.find.focused && editor_find_handle_key(ed, chord) {
		return true
	}
	if editor_handle_popup_key(ed, chord) {
		return true
	}
	action, bound := km.keymap_resolve(&ed.keymap, chord)
	if !bound {
		return false
	}
	return editor_run_action(ed, action)
}

// editor_run_action performs an action however it was invoked (key,
// context menu, command palette). Returns false for host-level actions the
// editor can't do itself (Save As / Open need the host's file dialogs).
editor_run_action :: proc(ed: ^Editor, action: km.Action) -> bool {
	#partial switch action {
	case .Copy, .Cut, .Paste:
		editor_handle_clipboard_action(ed, action)
		return true
	case .TriggerCompletion:
		editor_request_completion(ed)
		return true
	case .TriggerSignatureHelp:
		editor_request_signature_help(ed)
		return true
	}
	handled := editor_apply_action(ed, action)
	if handled {
		editor_ensure_cursor_visible(ed)
	}
	return handled
}

// editor_handle_menu_key: Up/Down move, Enter activates, anything else
// closes the context menu.
@(private)
editor_handle_menu_key :: proc(ed: ^Editor, chord: km.Chord) {
	#partial switch chord.key {
	case .Up:
		editor_context_menu_move(ed, -1)
	case .Down:
		editor_context_menu_move(ed, 1)
	case .Enter:
		editor_context_menu_activate(ed, ed.menu.selected)
	case:
		editor_close_context_menu(ed)
	}
}

// editor_handle_popup_key gives open popups first claim on navigation
// keys: Up/Down/PageUp/PageDown move the completion selection, Enter/Tab
// accept it, and Escape dismisses the topmost popup.
@(private)
editor_handle_popup_key :: proc(ed: ^Editor, chord: km.Chord) -> bool {
	// An active snippet owns Tab / Shift+Tab (unless the completion list
	// is up, where Tab accepts).
	if ed.snippet.active && !editor_completion_visible(ed) {
		switch {
		case chord.key == .Tab && chord.mods == {}:
			editor_snippet_step(ed, 1)
			return true
		case chord.key == .Tab && chord.mods == {.Shift}:
			editor_snippet_step(ed, -1)
			return true
		case chord.key == .Escape && chord.mods == {} && !ed.signature.active && !ed.completion.active:
			editor_end_snippet(ed)
			return true
		}
	}
	if chord.mods != {} {
		return false
	}
	if ed.nav.peek.open && (chord.key == .Escape || chord.key == .Enter) {
		if chord.key == .Enter {
			p := &ed.nav.peek
			editor_jump_to(ed, p.key, p.target_line, p.target_char, record = true)
		}
		editor_close_peek(ed)
		return true
	}
	// Up/Down cycle overloads while signature help shows several.
	if editor_signature_visible(ed) && !editor_completion_visible(ed) && len(ed.lsp.last_signatures) > 1 &&
	   (chord.key == .Up || chord.key == .Down) {
		n := len(ed.lsp.last_signatures)
		cur := editor_signature_index(ed)
		ed.signature.selected = (cur + (1 if chord.key == .Down else -1) + n) % n
		return true
	}
	if ed.hover.visible && chord.key == .Escape {
		editor_hide_hover(ed)
		return true
	}
	if ed.actions.active {
		#partial switch chord.key {
		case .Up:
			editor_code_actions_move(ed, -1)
			return true
		case .Down:
			editor_code_actions_move(ed, 1)
			return true
		case .Enter, .Tab:
			if editor_code_actions_visible(ed) {
				editor_apply_code_action(ed, ed.actions.selected)
			}
			return true
		case .Escape:
			editor_close_code_actions(ed)
			return true
		}
	}
	if editor_completion_visible(ed) {
		#partial switch chord.key {
		case .Up:
			editor_completion_move(ed, -1)
			return true
		case .Down:
			editor_completion_move(ed, 1)
			return true
		case .PageUp:
			editor_completion_move(ed, -editor_completion_rows(ed))
			return true
		case .PageDown:
			editor_completion_move(ed, editor_completion_rows(ed))
			return true
		case .Enter, .Tab:
			return editor_accept_completion(ed)
		case .Escape:
			editor_close_completion(ed)
			return true
		}
	}
	if chord.key == .Escape && ed.nav.refs.open && !ed.completion.active && !ed.signature.active && ed.diag_tip.source == .None {
		editor_close_references(ed)
		return true
	}
	if chord.key == .Escape && (ed.completion.active || ed.signature.active || ed.diag_tip.source != .None) {
		editor_close_completion(ed)
		editor_close_signature_help(ed)
		ed.diag_tip.source = .None
		ed.diag_tip.hover_valid = false
		return true
	}
	return false
}
