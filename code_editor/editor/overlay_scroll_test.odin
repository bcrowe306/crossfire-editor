package code_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

// Overlays in a short view (overlay_scroll.odin): each fits inside the visible area, scrolls
// what doesn't fit (the wheel, the keys), maps clicks through its scroll, and says it scrolls
// (a scrollbar: overlay_scrollbar_rect)

// The bottom of the text area overlays must stay above
@(private="file")
view_bottom :: proc(ed: ^Editor) -> f32 {
	return ed.origin_y + f32(editor_text_rows(ed)) * ed.char_h
}

@(private="file")
inside_view :: proc(ed: ^Editor, r: sdl.FRect) -> bool {
	return r.y >= ed.origin_y - 0.5 && r.y + r.h <= view_bottom(ed) + 0.5
}

@(test)
test_overlay_scroll_helpers :: proc(t: ^testing.T) {
	ed := Editor{char_h = 20}
	testing.expect_value(t, overlay_rows_fit(&ed, 100, 10), 4) // (100 - 8) / 20
	testing.expect_value(t, overlay_rows_fit(&ed, 1000, 10), 10)
	testing.expect_value(t, overlay_rows_fit(&ed, 5, 10), 1)
	testing.expect_value(t, overlay_scroll_clamp(30, 25, 10), 15)
	testing.expect_value(t, overlay_scroll_clamp(-3, 25, 10), 0)
	testing.expect_value(t, overlay_scroll_reveal(0, 12, 25, 10), 3)
	testing.expect_value(t, overlay_scroll_reveal(8, 2, 25, 10), 2)
	testing.expect_value(t, overlay_scroll_reveal(4, 6, 25, 10), 4)
	_, shown := overlay_scrollbar_rect({0, 0, 100, 100}, 10, 10)
	testing.expect(t, !shown, "no scrollbar when it all fits")
	track, more := overlay_scrollbar_rect({0, 0, 100, 100}, 25, 10)
	testing.expect(t, more && track.x > 80 && track.w == OVERLAY_SCROLLBAR_W, "a scrollbar on the right")
}

@(test)
test_completion_fits_a_short_view_and_scrolls :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		ed.char_w, ed.char_h = 10, 20
		ed.visible_rows, ed.visible_cols = 6, 60
		items := ""
		for i in 0 ..< 25 do items = strings.concatenate({items, i > 0 ? "," : "", fmt.tprintf(`{{"label":"item%d"}}`, i)}, context.temp_allocator)
		type_and_update(&ed, "x.")
		fake_completion_response(&ed, items)
		editor_update(&ed)

		layout := editor_popup_layout(&ed)
		rows := editor_completion_rows(&ed)
		testing.expect(t, layout.completion_visible && inside_view(&ed, layout.completion), "inside the view")
		testing.expectf(t, rows < COMPLETION_MAX_VISIBLE && rows >= 1, "fewer rows than usual: %d", rows)
		_, shown := overlay_scrollbar_rect(layout.completion, len(ed.completion.filtered), rows)
		testing.expect(t, shown, "a scrollbar")

		// The selection stays in view going down; PageDown moves by the rows shown
		for _ in 0 ..< rows do key_and_update(&ed, sdl.K_DOWN)
		testing.expect_value(t, ed.completion.selected, rows)
		testing.expect(t, ed.completion.scroll > 0 && ed.completion.selected < ed.completion.scroll + rows, "scrolled to the selection")
		key_and_update(&ed, sdl.K_PAGEDOWN)
		testing.expect_value(t, ed.completion.selected, 2 * rows)

		// A click maps through the scroll
		hit := editor_hit_test(&ed, layout.completion.x + 5, layout.completion.y + POPUP_PAD + 2)
		testing.expect_value(t, hit.row, ed.completion.scroll)
	})
}

@(test)
test_completion_docs_scroll_and_keep_the_list_open :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		ed.char_w, ed.char_h = 10, 20
		ed.visible_rows, ed.visible_cols = 10, 120
		doc := strings.builder_make(context.temp_allocator)
		for i in 0 ..< 40 do fmt.sbprintf(&doc, "Line %d of the docs.\\n", i)
		type_and_update(&ed, "x.")
		fake_completion_response(&ed, fmt.tprintf(`{{"label":"thing","documentation":"%s"}}`, strings.to_string(doc)))
		editor_update(&ed)

		rect, lines, ok := editor_completion_doc_layout(&ed)
		testing.expect(t, ok && len(lines) == 40, "every line kept")
		testing.expect(t, rect.y + rect.h <= view_bottom(&ed) + 0.5, "the docs fit above the view's bottom")
		rows := popup_rows_of(&ed, rect)
		testing.expect(t, rows < 40, "fewer rows than lines")
		mouse_wheel(&ed, rect.x + 5, rect.y + 5, 0, -3)
		testing.expect_value(t, popup_scroll_get(&ed.completion.doc_scroll, completion_doc_scroll_key(&ed)), 3)
		testing.expect_value(t, ed.scroll_line, 0)
		// A click on the docs doesn't close the list (it moved the caret before)
		mouse_click(&ed, rect.x + 5, rect.y + 5)
		testing.expect(t, editor_completion_visible(&ed), "still open")
	})
}

@(test)
test_code_actions_past_the_eighth_are_reachable :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("package p\n\nmain :: proc() {}")
		defer editor_destroy(&ed)
		ed.visible_rows = 8
		uri := ed.document_uri
		key_and_update(&ed, sdl.K_PERIOD, sdl.KMOD_LCTRL)
		actions := strings.builder_make(context.temp_allocator)
		for i in 0 ..< 12 {
			if i > 0 do strings.write_string(&actions, ",")
			fmt.sbprintf(&actions, `{{"title":"Fix %d","kind":"quickfix","edit":{{"changes":{{"%s":[{{"range":{{"start":{{"line":0,"character":0}},"end":{{"line":0,"character":0}}}},"newText":"x"}}]}}}}}}`, i, uri)
		}
		fake_code_actions(&ed, strings.to_string(actions))
		editor_update(&ed)
		testing.expect_value(t, len(ed.lsp.last_code_actions), 12)
		rect, _ := editor_code_actions_layout(&ed)
		testing.expect(t, inside_view(&ed, rect), "inside the view")
		rows := popup_rows_of(&ed, rect)
		for _ in 0 ..< 10 do key_and_update(&ed, sdl.K_DOWN)
		testing.expect_value(t, ed.actions.selected, 10)
		testing.expect(t, ed.actions.selected >= ed.actions.scroll && ed.actions.selected < ed.actions.scroll + rows, "the 11th action shows")
		hit := editor_hit_test(&ed, rect.x + 5, rect.y + POPUP_PAD + 2)
		testing.expect_value(t, hit.row, ed.actions.scroll)
	})
}

@(test)
test_panels_fit_and_references_click_their_own_rows :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("a\nb\nc")
		defer editor_destroy(&ed)
		ed.visible_rows = 6
		r := &ed.nav.refs
		r.open = true
		for i in 0 ..< 20 do append(&r.items, Ref_Item{key = strings.clone("file:///x.odin"), line = i, preview = strings.clone("x")})
		// A short view: the panel takes 3 rows (header + 2), the text keeps 3
		testing.expect_value(t, editor_panel_rows(&ed), 3)
		testing.expect_value(t, editor_text_rows(&ed), 3)
		// The wheel scrolls the references; a click picks from where they're scrolled to (it used the
		// problems panel's scroll)
		top := f32(editor_text_rows(&ed)) * ed.char_h
		mouse_wheel(&ed, 50, top + ed.char_h + 5, 0, -5)
		testing.expect_value(t, r.scroll, 5)
		testing.expect_value(t, ed.problems.scroll, 0)
		hit := editor_hit_test(&ed, 50, top + ed.char_h + 5)
		testing.expect(t, hit.zone == .References && hit.row == 5, "the 6th reference")
	})
}

@(test)
test_palette_fits_and_takes_the_wheel :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np")
		defer editor_destroy(&ed)
		ed.visible_rows = 7
		editor_open_palette(&ed)
		rect, rows, ok := editor_palette_layout(&ed)
		_, matches := editor_palette_matches(&ed)
		testing.expect(t, ok && rows < min(len(matches), PALETTE_ROWS), "fewer rows than results")
		testing.expect(t, rect.y + rect.h <= ed.origin_y + f32(ed.visible_rows) * ed.char_h + 0.5, "inside the view")
		mouse_wheel(&ed, rect.x + 5, rect.y + rect.h - 5, 0, -2)
		testing.expect_value(t, ed.palette.scroll, 2)
		testing.expect_value(t, ed.scroll_line, 0) // the text behind it didn't scroll
	})
}

@(test)
test_hover_taller_than_the_view_scrolls :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_diag_editor("x := compute(1)")
		defer editor_destroy(&ed)
		ed.visible_rows = 8
		mouse_move(&ed, editor_gutter_width(&ed) + 7 * 10 + 5, 10) // over "compute"
		ed.diag_tip.hover_since = time.tick_add(time.tick_now(), -DIAG_HOVER_DELAY)
		editor_update(&ed)
		doc := strings.builder_make(context.temp_allocator)
		for i in 0 ..< 30 do fmt.sbprintf(&doc, "Line %d.\\n\\n", i)
		fake_hover(&ed, fmt.tprintf(`{{"contents":{{"kind":"plaintext","value":"%s"}}}}`, strings.to_string(doc)))
		editor_update(&ed)
		rect, lines, ok := editor_hover_layout(&ed)
		testing.expect(t, ok && inside_view(&ed, rect), "inside the view")
		rows := popup_rows_of(&ed, rect)
		testing.expectf(t, rows < len(lines), "fewer rows (%d) than lines (%d)", rows, len(lines))
		mouse_wheel(&ed, rect.x + 5, rect.y + 5, 0, -2)
		testing.expect_value(t, popup_scroll_get(&ed.hover.scroll, u64(ed.hover.seen_seq)), 2)
		testing.expect(t, ed.hover.visible, "still showing")
	})
}

@(test)
test_utilities_scroll_in_a_short_window :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("a")
		defer editor_destroy(&ed)
		ed.visible_rows = 8
		editor_show_window(&ed, .Utilities)
		content, rows := utilities_content_rect(&ed)
		testing.expect(t, rows < utilities_content_rows(&ed), "taller than the window")
		mouse_wheel(&ed, content.x + 5, content.y + 5, 0, -1)
		testing.expect(t, ed.utilities.scroll > 0, "the wheel scrolls it")
		// Rows map through the scroll: the first action's row moved up with it
		top := editor_utilities_layout(&ed)
		if top >= content.y {
			testing.expect_value(t, editor_utilities_row_at(&ed, top + 2), 0)
		}
		// Down to the last action keeps it in view
		for _ in 0 ..< len(Utility) - 1 do editor_utilities_handle_key(&ed, {key = .Down})
		last := editor_utilities_layout(&ed) + f32(len(Utility) - 1) * ed.char_h
		testing.expect(t, last >= content.y && last + ed.char_h <= content.y + content.h + 0.5, "the selected action shows")
	})
}

@(test)
test_popups_fit_a_narrow_view :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_lsp_test_editor("")
		defer editor_destroy(&ed)
		ed.char_w, ed.char_h = 10, 20
		ed.visible_rows, ed.visible_cols = 20, 14
		type_and_update(&ed, "x.")
		fake_completion_response(&ed, `{"label":"a_really_long_completion_label_here","detail":"proc(a: int, b: int) -> string"}`)
		editor_update(&ed)
		layout := editor_popup_layout(&ed)
		left := ed.origin_x + editor_gutter_width(&ed)
		right := left + f32(ed.visible_cols) * ed.char_w
		testing.expect(t, layout.completion.x >= left - 0.5 && layout.completion.x + layout.completion.w <= right + 0.5, "the list fits the width")
		if rect, _, ok := editor_completion_doc_layout(&ed); ok {
			testing.expect(t, rect.x + rect.w <= right + 0.5, "the docs fit the width")
		}
		testing.expect(t, popup_max_cols(&ed, 100) <= ed.visible_cols - 2, "text popups wrap to the view")
	})
}
