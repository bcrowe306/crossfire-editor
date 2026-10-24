// Package editor glues together `buffer`, `keymap`, `syntax`, and `lsp`
// into a complete, embeddable code editor widget, plus SDL3-based rendering
// and input handling. The host owns an `Editor` value and drives it
// explicitly via `editor_handle_event` / `editor_update` / `editor_render` —
// there is no global/singleton state, so multiple independent editors can
// coexist in one process.
package code_editor

import buf "../buffer"
import km "../keymap"
import lspc "../lsp"
import syn "../syntax"
import "core:strings"
import sdl "vendor:sdl3"

Editor :: struct {
	buf:       buf.Buffer,
	keymap:    km.Keymap,
	platform:  km.Platform,
	language:  syn.Language,

	lsp:          lspc.Client,
	lsp_enabled:  bool,
	document_uri: string,
	// uri_key of document_uri (decoded + symlink-resolved), used to look up
	// diagnostics the server may publish under a different spelling.
	document_key: string,
	lsp_version:  int,
	// didOpen has been sent for document_uri (deferred until the server
	// has answered `initialize`, as the spec requires).
	lsp_doc_open: bool,
	// buf.version last pushed to the server via didOpen/didChange.
	lsp_synced_version: int,
	lsp_supervisor: Lsp_Supervisor,
	// Edits since the last didChange, as LSP incremental changes (texts
	// owned); lsp_need_full forces a full-text sync instead (after a reset
	// or if the queue grows too long).
	lsp_pending:   [dynamic]lspc.Incremental_Change,
	lsp_need_full: bool,

	// Widest line (visual columns), cached per buffer version + tab width
	// for the horizontal scroll clamp.
	width_cache:         int,
	width_cache_version: int,
	width_cache_tab:     int,

	completion: Completion_State,
	signature:  Signature_State,
	diag_tip:     Diagnostic_Tooltip,
	diag_overlay: Diag_Overlay,
	problems:     Problems_Panel,
	actions:      Code_Action_Menu,
	// Rename Symbol's box (rename.odin), and a server's rename's edits to other files, for the
	// host (editor_take_file_edits; owned)
	rename:       Rename_Box,
	file_edits:   [dynamic]lspc.Code_Action_Edit,
	find:         Find_State,
	snippet:      Snippet_Session,
	menu:         Context_Menu,
	palette:      Palette_State,
	window:       Editor_Window,
	keymap_editor: Keymap_Editor,
	theme_editor: Theme_Editor,
	theme:        Theme,
	utilities:    Utilities_State,
	config:       Config,
	nav:          Navigation,
	hover:        Hover_Info,

	// The host's providers (providers.odin; nil: none) and what the cached ones last said
	providers: ^Provider_Registry,
	provided:  Provided,

	// Viewport / scrolling (in cells, not pixels). scroll_col is a visual
	// column (tabs expanded), not a byte offset.
	scroll_line: int,
	scroll_col:  int,
	tab_width:   int,
	// Tab indents with a tab character (Odin's style, odinfmt's) instead of spaces
	indent_with_tabs: bool,
	// Brackets and quotes close themselves as they're typed, Backspace removes an empty pair,
	// Enter between brackets opens an indented line (buffer's autopairs.odin). On by default
	auto_close_pairs: bool,
	visible_rows: int,
	visible_cols: int,

	// Font metrics used both for rendering and for mouse-position hit
	// testing; set by the host once a font is loaded.
	char_w: f32,
	char_h: f32, // row height (glyph height x line_spacing)

	// Glyph height from the font (0 = same as char_h) and the row height
	// multiplier editor_set_font applies; show_header toggles the
	// file-name strip.
	glyph_h:      f32,
	line_spacing: f32,
	show_header:  bool,

	// Zoom (Ctrl/Cmd +/-/0): the font size the user asked for. The host
	// owns the fonts, so it picks changes up with
	// editor_take_font_size_change, resizes its font(s) and calls
	// editor_set_font + editor_set_viewport.
	font_size:         f32,
	base_font_size:    f32,
	font_size_changed: bool,

	// Top-left of the editor in window pixels as of the last
	// editor_render, so mouse hit-testing works for hosts that draw the
	// editor at an offset.
	origin_x: f32,
	origin_y: f32,

	mouse: Mouse_State,
	// Modifier keys currently held, tracked from the KEY_DOWN/KEY_UP
	// events the editor receives (so injected modifier presses work for
	// mouse gestures like Shift+click, which SDL mouse events don't carry).
	key_mods: km.Modifiers,

	injected_events: [dynamic]sdl.Event,
}

editor_init :: proc(
	platform: km.Platform,
	language: syn.Language = {},
	allocator := context.allocator,
) -> Editor {
	ed := Editor{
		buf      = buf.buffer_init(allocator),
		keymap   = km.keymap_default(platform, allocator),
		platform = platform,
		language = language,
		char_w   = 8,
		char_h   = 16,
		visible_rows = 32,
		visible_cols = 80,
		tab_width    = DEFAULT_TAB_WIDTH,
		auto_close_pairs = true,
		line_spacing = DEFAULT_LINE_SPACING,
		show_header  = true,
	}
	if ed.language.tokenize == nil {
		ed.language = syn.odin_language()
	}
	ed.injected_events = make([dynamic]sdl.Event, allocator)
	ed.completion.filtered = make([dynamic]int, allocator)
	ed.completion.items = make([dynamic]Completion_Entry, allocator)
	ed.completion.provided = make([dynamic]Provider_Completion, allocator)
	ed.provided.version = -1
	ed.provided.generation = -1
	ed.provided.seen_version = -1
	ed.signature.selected = -1
	ed.diag_overlay.built_seq = -1
	ed.width_cache_version = -1
	ed.lsp_pending = make([dynamic]lspc.Incremental_Change, allocator)
	find_init(&ed.find)
	palette_init(&ed.palette)
	ed.keymap_editor.filter = strings.builder_make(allocator)
	ed.theme = default_theme()
	theme_editor_init(&ed.theme_editor, allocator)
	// Diagnostics follow edits between server publishes (see Diag_Overlay).
	ed.buf.track_changes = true
	return ed
}

editor_destroy :: proc(ed: ^Editor) {
	buf.buffer_destroy(&ed.buf)
	km.keymap_destroy(&ed.keymap)
	if ed.lsp_enabled {
		lspc.client_destroy(&ed.lsp)
	}
	lsp_supervisor_end(&ed.lsp_supervisor)
	if len(ed.document_uri) > 0 {
		delete(ed.document_uri)
	}
	delete(ed.document_key)
	delete(ed.injected_events)
	diag_overlay_destroy(&ed.diag_overlay)
	editor_clear_lsp_pending(ed)
	delete(ed.lsp_pending)
	problems_destroy(&ed.problems)
	find_destroy(&ed.find)
	palette_destroy(&ed.palette)
	keymap_editor_destroy(&ed.keymap_editor)
	theme_editor_destroy(&ed.theme_editor)
	config_destroy(&ed.config)
	navigation_destroy(&ed.nav)
	delete(ed.snippet.stops)
	delete(ed.completion.filtered)
	completion_entries_free(&ed.completion.items)
	delete(ed.completion.items)
	provided_completions_free(&ed.completion.provided)
	delete(ed.completion.provided)
	provided_destroy(&ed.provided)
	provider_fixes_free(ed.actions.fixes)
	marker_choices_free(ed.actions.choices)
	rename_destroy(ed)
}

DEFAULT_LINE_SPACING :: 1.4
GUTTER_MARKER_SPACE :: 14 // gutter room right of the numbers (diagnostic marker)

// editor_set_font sets the cell metrics from the font: `char_w` is the
// advance of one monospace cell, `glyph_h` the font's line height. Rows
// are glyph_h x line_spacing tall.
editor_set_font :: proc(ed: ^Editor, char_w, glyph_h: f32) {
	ed.char_w = char_w
	ed.glyph_h = glyph_h
	ed.char_h = f32(int(glyph_h * max(ed.line_spacing, 1) + 0.5))
}

MIN_FONT_SIZE :: 8
MAX_FONT_SIZE :: 48

// editor_set_font_size records the host's starting font size (the zoom
// reset target).
editor_set_font_size :: proc(ed: ^Editor, size: f32) {
	ed.font_size = size
	ed.base_font_size = size
}

// editor_zoom changes the requested font size by `delta` points (0 = back
// to the base size).
editor_zoom :: proc(ed: ^Editor, delta: f32) {
	if ed.base_font_size <= 0 {
		return // host hasn't opted in
	}
	size := ed.base_font_size if delta == 0 else clamp(ed.font_size + delta, MIN_FONT_SIZE, MAX_FONT_SIZE)
	if size != ed.font_size {
		ed.font_size = size
		ed.font_size_changed = true
	}
}

// editor_take_font_size_change returns a pending zoom request (once).
editor_take_font_size_change :: proc(ed: ^Editor) -> (size: f32, ok: bool) {
	if !ed.font_size_changed {
		return
	}
	ed.font_size_changed = false
	return ed.font_size, true
}

// editor_glyph_height is the font's glyph height (falls back to the row
// height for hosts that only set char_h).
editor_glyph_height :: proc(ed: ^Editor) -> f32 {
	return ed.glyph_h if ed.glyph_h > 0 else ed.char_h
}

// editor_header_height is the height of the file-name strip (0 if hidden).
editor_header_height :: proc(ed: ^Editor) -> f32 {
	if !ed.show_header {
		return 0
	}
	return f32(int(editor_glyph_height(ed) * 1.8))
}

// editor_gutter_width fits the widest line number plus the marker column.
editor_gutter_width :: proc(ed: ^Editor) -> f32 {
	digits := 1
	for n := buf.buffer_line_count(&ed.buf); n >= 10; n /= 10 {
		digits += 1
	}
	return max(f32(MIN_GUTTER_WIDTH), f32(digits) * ed.char_w + GUTTER_MARKER_SPACE + 10)
}

// editor_set_viewport sizes the editor to a w x h pixel area (header,
// gutter and line spacing accounted for). Call after editor_set_font and
// on window resize.
editor_set_viewport :: proc(ed: ^Editor, w, h: f32) {
	if ed.char_w <= 0 || ed.char_h <= 0 {
		return
	}
	// Room is kept for the scrollbars at the right and bottom.
	ed.visible_cols = max(1, int((w - editor_gutter_width(ed) - SCROLLBAR_SIZE) / ed.char_w))
	ed.visible_rows = max(1, int((h - editor_header_height(ed) - SCROLLBAR_SIZE) / ed.char_h))
}

// editor_display_name returns the open file's base name and directory
// ("untitled" when there's no file).
editor_display_name :: proc(ed: ^Editor) -> (name, dir: string) {
	path := ed.buf.file_path
	if len(path) == 0 {
		return "untitled", ""
	}
	i := len(path) - 1
	for i >= 0 && path[i] != '/' && path[i] != '\\' {
		i -= 1
	}
	if i < 0 {
		return path, ""
	}
	return path[i + 1:], path[:i]
}

// editor_primary_cursor returns a pointer to the first (primary) cursor.
editor_primary_cursor :: proc(ed: ^Editor) -> ^buf.Cursor {
	return &ed.buf.cursors[0]
}
