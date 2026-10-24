// Providers for a running program (the host's): scrubbing numbers, the host's entries in the
// right-click menu, and clicks in the marker column of a line without a marker.
//
// **Scrubbing** (`.Scrub` providers): Alt+press on a number a provider can scrub (its
// `scrub_target` says so, with the value to start from, the step and the range), then a drag
// sideways, changes the value by a step every SCRUB_PIXELS_PER_STEP pixels (scaled with the font;
// Shift: a tenth of a step); the provider's `on_scrub` hears each new value (`.Change`) and the
// release (`.End`), when it may offer choices (where to write the value): they're listed in the
// code actions menu and the one picked goes to `on_scrub_choice`. The buffer isn't edited: while
// dragging, the new value is drawn over the literal. An Alt+click that doesn't move is still an
// Alt+click (a cursor added or removed).
//
// **Menu items** (`.Menu` providers): `menu_items` lists entries for the position right-clicked
// (asked when the menu opens), drawn after the editor's own; `on_menu_item` gets the one picked.
//
// **Gutter line clicks**: a gutter provider's `on_gutter_line` is called for a click in the
// marker column of a line without a marker (a marker's click goes to its `on_click`).
package code_editor

import buf "../buffer"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// Pixels (at a cell 8 px wide: it follows the font) a drag moves for one step
SCRUB_PIXELS_PER_STEP :: 4
// Pixels a press must move before it scrubs (an Alt+click below it)
SCRUB_THRESHOLD :: 3

// A number a provider lets the user scrub
Scrub_Target :: struct {
	// The literal (one line; `end` exclusive)
	start, end: buf.Position,
	// The value the drag starts from (the running program's, which may differ from the text)
	value:    f64,
	// One step (0: from the literal: 1, or 0.1 for "0.5", 0.01 for "0.25")
	step:     f64,
	// Decimals shown (-1: the step's)
	decimals: int,
	min, max: Maybe(f64),
	// Whole numbers only
	integer:  bool,
	// The host's own number
	id:       int,
}

// Where a scrub is (`Scrub_Proc`)
Scrub_Phase :: enum {
	// The value changed while dragging
	Change,
	// The mouse was released: the provider may append choices
	End,
}

// Whether a number at a position can be scrubbed (filling `out`; the first provider saying yes wins)
Scrub_Target_Proc :: proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^Scrub_Target) -> bool
// A scrub's new value (`text` as the editor shows it), or its end: then `choices` (temp
// allocated) offers what to do with it, in a menu
Scrub_Proc        :: proc(doc: Provider_Document, target: Scrub_Target, value: f64, text: string, phase: Scrub_Phase, user_data: rawptr, choices: ^[dynamic]string)
// A choice picked from a scrub's menu
Scrub_Choice_Proc :: proc(doc: Provider_Document, target: Scrub_Target, value: f64, text: string, choice: int, user_data: rawptr)
// The right-click menu's entries for a position (labels, temp allocated)
Menu_Items_Proc   :: proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^[dynamic]string)
// A provider's menu entry picked (its index in what `menu_items` gave)
Menu_Item_Proc    :: proc(doc: Provider_Document, pos: buf.Position, index: int, user_data: rawptr)

// A scrub in progress (`Editor.scrub`)
Scrub_State :: struct {
	// Alt was pressed on a scrubbable number / the drag moved past SCRUB_THRESHOLD
	pending, active: bool,
	provider: int,
	target:   Scrub_Target,
	press_x:  f32,
	press_pos: buf.Position,
	// The value now, its text (owned) and its step
	value:    f64,
	text:     string,
	step:     f64,
	decimals: int,
}

/*
A scrub's step and decimals: the target's, else from the literal (1 for "250", 0.1 for "0.5",
0.01 for "0.25").
*/
scrub_step :: proc(target: Scrub_Target, literal: string) -> (step: f64, decimals: int) {
	decimals = 0
	if dot := strings.index_byte(literal, '.'); dot >= 0 {
		for c in literal[dot + 1:] {
			if c < '0' || c > '9' do break
			decimals += 1
		}
	}
	step = target.step
	if step <= 0 do step = math.pow(10, -f64(decimals))
	if target.integer do step = max(math.round(step), 1)
	if target.decimals >= 0 do decimals = target.decimals
	else {
		// As many decimals as the step needs
		d := 0
		for s := step; d < 6 && math.abs(s - math.round(s)) > 1e-9; s *= 10 do d += 1
		decimals = max(decimals, d)
	}
	if target.integer do decimals = 0
	return
}

/*
The value a scrub reaches: the start moved a step for every `pixels_per_step` of `dx`, a tenth of
one with `fine`, rounded to the step and kept in the target's range.
*/
scrub_value :: proc(target: Scrub_Target, start, step: f64, dx, pixels_per_step: f32, fine := false) -> f64 {
	unit := fine && !target.integer ? step / 10 : step
	steps := math.trunc(f64(dx) / f64(max(pixels_per_step, 0.5)))
	v := start + steps * unit
	// Rounded to the unit, so repeated drags don't collect float noise
	if unit > 0 do v = math.round(v / unit) * unit
	if target.integer do v = math.round(v)
	if lo, ok := target.min.?; ok do v = max(v, lo)
	if hi, ok := target.max.?; ok do v = min(v, hi)
	return v
}

// A scrubbed value as text: `decimals` places (none for whole numbers), never "-0" (temp allocated)
scrub_format :: proc(value: f64, decimals: int, integer := false) -> string {
	if integer || decimals <= 0 {
		text := fmt.tprintf("%d", i64(math.round(value)))
		return text == "-0" ? "0" : text
	}
	text := fmt.tprintf(fmt.tprintf("%%.%df", decimals), value)
	if strings.trim_left(text, "-0.") == "" && text[0] == '-' do text = text[1:]
	return text
}

// An Alt+press at a position: a scrub may start (pending until the mouse moves)
@(private)
editor_scrub_press :: proc(ed: ^Editor, pos: buf.Position, x: f32) -> bool {
	if ed.providers == nil do return false
	doc := editor_provider_document(ed)
	for &prov, i in ed.providers.providers {
		if prov.kind != .Scrub || prov.scrub_target == nil do continue
		target := Scrub_Target{decimals = -1}
		start := time.tick_now()
		ok := prov.scrub_target(doc, pos, provider_context(&prov, .Invoked), &target)
		provider_timed(&prov, start)
		if !ok do continue
		if target.start.line != target.end.line || !buf.position_less(target.start, target.end) do continue
		line := buf.buffer_line_str(&ed.buf, target.start.line)
		if target.end.col > len(line) do continue
		literal := line[target.start.col:target.end.col]
		step, decimals := scrub_step(target, literal)
		delete(ed.scrub.text)
		ed.scrub = {pending = true, provider = i, target = target, press_x = x, press_pos = pos, value = target.value, step = step, decimals = decimals}
		ed.scrub.text = strings.clone(scrub_format(target.value, decimals, target.integer))
		return true
	}
	return false
}

// The mouse moved during a scrub: past the threshold it scrubs, telling the provider of new values
@(private)
editor_scrub_motion :: proc(ed: ^Editor, x: f32) {
	s := &ed.scrub
	if !s.pending && !s.active do return
	dx := x - s.press_x
	if !s.active {
		if abs(dx) < SCRUB_THRESHOLD do return
		s.active = true
		s.pending = false
	}
	fine := .Shift in editor_current_mods(ed)
	per := f32(SCRUB_PIXELS_PER_STEP) * max(ed.char_w, 1) / 8
	value := scrub_value(s.target, s.target.value, s.step, dx, per, fine)
	decimals := fine && !s.target.integer ? s.decimals + 1 : s.decimals
	text := scrub_format(value, decimals, s.target.integer)
	if text == s.text do return
	s.value = value
	delete(s.text)
	s.text = strings.clone(text)
	editor_scrub_tell(ed, .Change, nil)
}

// The mouse was released: a scrub ends (its provider may offer choices), a press that never moved
// is an Alt+click. Returns whether there was a scrub to end
@(private)
editor_scrub_release :: proc(ed: ^Editor) -> bool {
	s := &ed.scrub
	if s.pending {
		pos := s.press_pos
		editor_scrub_clear(ed)
		editor_toggle_cursor_at(ed, pos)
		return true
	}
	if !s.active do return false
	choices := make([dynamic]string, context.temp_allocator)
	editor_scrub_tell(ed, .End, &choices)
	provider, target, value := s.provider, s.target, s.value
	text := strings.clone(s.text, context.temp_allocator)
	editor_scrub_clear(ed)
	if len(choices) > 0 do editor_open_scrub_menu(ed, provider, target, value, text, choices[:])
	return true
}

// Whether a scrub is being dragged (the editor draws its value over the literal)
editor_scrubbing :: proc(ed: ^Editor) -> bool {
	return ed.scrub.active
}

// Whether a scrub holds the mouse (pressed on a number, dragging or not): the host keeps sending
// it the mouse outside the editor until the release, as for a selection drag
editor_scrub_held :: proc(ed: ^Editor) -> bool {
	return ed.scrub.pending || ed.scrub.active
}

@(private)
editor_scrub_tell :: proc(ed: ^Editor, phase: Scrub_Phase, choices: ^[dynamic]string) {
	s := &ed.scrub
	if ed.providers == nil || s.provider < 0 || s.provider >= len(ed.providers.providers) do return
	prov := &ed.providers.providers[s.provider]
	if prov.on_scrub == nil do return
	sink := choices
	if sink == nil do sink = new_clone(make([dynamic]string, context.temp_allocator), context.temp_allocator)
	start := time.tick_now()
	prov.on_scrub(editor_provider_document(ed), s.target, s.value, s.text, phase, prov.user_data, sink)
	provider_timed(prov, start)
}

@(private)
editor_scrub_clear :: proc(ed: ^Editor) {
	delete(ed.scrub.text)
	ed.scrub = {}
}

// Calls a scrub provider's `on_scrub_choice` (the scrub menu's pick)
@(private)
editor_choose_scrub :: proc(ed: ^Editor, provider: int, target: Scrub_Target, value: f64, text: string, choice: int) {
	if ed.providers == nil || provider < 0 || provider >= len(ed.providers.providers) do return
	prov := &ed.providers.providers[provider]
	if prov.on_scrub_choice == nil do return
	start := time.tick_now()
	prov.on_scrub_choice(editor_provider_document(ed), target, value, text, choice, prov.user_data)
	provider_timed(prov, start)
}

// While scrubbing: the value over the literal, highlighted
@(private)
render_scrub :: proc(ed: ^Editor, renderer: ^sdl.Renderer, font: ^ttf.Font, line: int, x, y: f32, theme: Theme) {
	s := &ed.scrub
	if !s.active || font == nil || s.target.start.line != line do return
	text := buf.buffer_line_str(&ed.buf, line)
	if s.target.end.col > len(text) do return
	col := visual_col_of(text, s.target.start.col, ed.tab_width) - ed.scroll_col
	literal_cols := visual_col_of(text, s.target.end.col, ed.tab_width) - visual_col_of(text, s.target.start.col, ed.tab_width)
	cols := max(literal_cols, text_cols(s.text))
	px := x + f32(col) * ed.char_w
	fill_rect(renderer, {px - 2, y + 1, f32(cols) * ed.char_w + 4, ed.char_h - 2}, theme.popup_selected)
	fill_rect(renderer, {px - 2, y + ed.char_h - 2, f32(cols) * ed.char_w + 4, 1}, theme.text_constant)
	draw_text(renderer, font, s.text, px, y, theme.popup_text, ed.char_h)
}

// --- the host's menu items ------------------------------------------------------

// A provider's entry in the right-click menu (owned label)
Menu_Provided :: struct {
	label:    string,
	provider: int,
	index:    int,
}

// Asks the menu providers for their entries at the caret (the menu opening)
@(private)
editor_collect_menu_items :: proc(ed: ^Editor) {
	menu_provided_clear(ed)
	if ed.providers == nil do return
	pos := editor_primary_cursor(ed).pos
	ed.menu.pos = pos
	doc := editor_provider_document(ed)
	for &prov, i in ed.providers.providers {
		if prov.kind != .Menu || prov.menu_items == nil do continue
		labels := make([dynamic]string, context.temp_allocator)
		start := time.tick_now()
		prov.menu_items(doc, pos, provider_context(&prov, .Invoked), &labels)
		provider_timed(&prov, start)
		for l, n in labels do append(&ed.menu.provided, Menu_Provided{strings.clone(l), i, n})
	}
}

@(private)
menu_provided_clear :: proc(ed: ^Editor) {
	for m in ed.menu.provided do delete(m.label)
	clear(&ed.menu.provided)
}

// Runs a provider's menu entry
@(private)
editor_run_menu_item :: proc(ed: ^Editor, item: Menu_Item) {
	if ed.providers == nil || item.provider < 0 || item.provider >= len(ed.providers.providers) do return
	prov := &ed.providers.providers[item.provider]
	if prov.on_menu_item == nil do return
	start := time.tick_now()
	prov.on_menu_item(editor_provider_document(ed), ed.menu.pos, item.index, prov.user_data)
	provider_timed(prov, start)
}

// --- gutter line clicks ---------------------------------------------------------

// A click in the marker column of a line no marker took: the gutter providers' `on_gutter_line`
@(private)
editor_click_gutter_line :: proc(ed: ^Editor, line: int) -> bool {
	if ed.providers == nil do return false
	doc := editor_provider_document(ed)
	for &prov in ed.providers.providers {
		if prov.kind != .Gutter || prov.on_gutter_line == nil do continue
		start := time.tick_now()
		took := prov.on_gutter_line(doc, line, prov.user_data)
		provider_timed(&prov, start)
		if took do return true
	}
	return false
}

/*
The window point (the editor's pixels) of a line's marker column, for hosts' tests that click it.
Returns false when the line isn't in view.
*/
editor_marker_column_point :: proc(ed: ^Editor, line: int) -> (x, y: f32, ok: bool) {
	if line < ed.scroll_line || line >= ed.scroll_line + editor_text_rows(ed) do return
	return ed.origin_x + editor_gutter_width(ed) - GUTTER_MARKER_SPACE * 0.5, ed.origin_y + (f32(line - ed.scroll_line) + 0.5) * ed.char_h, true
}

/*
The window point of the middle of a literal's first character, for hosts' tests that scrub it.
Returns false when the line isn't in view.
*/
editor_text_point :: proc(ed: ^Editor, pos: buf.Position) -> (x, y: f32, ok: bool) {
	if pos.line < ed.scroll_line || pos.line >= ed.scroll_line + editor_text_rows(ed) do return
	text := buf.buffer_line_str(&ed.buf, pos.line)
	col := visual_col_of(text, min(pos.col, len(text)), ed.tab_width) - ed.scroll_col
	return ed.origin_x + editor_gutter_width(ed) + (f32(col) + 0.5) * ed.char_w, ed.origin_y + (f32(pos.line - ed.scroll_line) + 0.5) * ed.char_h, true
}

// The scrub's value now, for hosts and tests ("" when none is being dragged; temp allocated)
editor_scrub_text :: proc(ed: ^Editor) -> string {
	return ed.scrub.active ? strings.clone(ed.scrub.text, context.temp_allocator) : ""
}
