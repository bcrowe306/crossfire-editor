package code_editor

import buf "../buffer"
import km "../keymap"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
test_fuzzy_score :: proc(t: ^testing.T) {
	_, ok := fuzzy_score("Select All Occurrences", "sao")
	testing.expect(t, ok, "subsequence matches")
	_, ok = fuzzy_score("Find", "xyz")
	testing.expect(t, !ok, "non-subsequence rejected")
	a, _ := fuzzy_score("Select All", "sel all")
	b, _ := fuzzy_score("Delete Word Left", "sel all")
	testing.expect(t, a.score > b.score || b.score == 0, "word-start matches outrank scattered ones")
	m, _ := fuzzy_score("Go to Next Problem", "gnp")
	testing.expect_value(t, m.n_pos, 3)
	testing.expect_value(t, int(m.positions[1]), 6) // the N of Next
}

@(test)
test_palette_filters_and_runs_commands :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("alpha\nbeta")
		defer editor_destroy(&ed)
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL)
		testing.expect(t, ed.palette.open, "Ctrl+P opens the palette")
		type_and_update(&ed, "select all")
		entries, matches := editor_palette_matches(&ed)
		testing.expect(t, len(matches) > 0 && entries[matches[0].entry].label == "Select All", "best match first")
		testing.expect_value(t, entries[matches[0].entry].detail, "Ctrl+A")
		testing.expect_value(t, editor_to_string(&ed, context.temp_allocator), "alpha\nbeta") // typing went to the palette
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, !ed.palette.open, "Enter runs and closes")
		_, e, ok := buf.selection_range(ed.buf.cursors[0])
		testing.expect(t, ok && e == buf.Position{1, 4}, "Select All ran")

		// Recently used commands come first with an empty query.
		key_and_update(&ed, sdl.K_F1)
		entries, matches = editor_palette_matches(&ed)
		testing.expect_value(t, entries[matches[0].entry].action, km.Action.SelectAll)
		key_and_update(&ed, sdl.K_ESCAPE)
		testing.expect(t, !ed.palette.open, "Escape closes")

		// Clicking a row runs it.
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		type_and_update(&ed, "problems panel")
		rect, _, _ := editor_palette_layout(&ed)
		mouse_click(&ed, rect.x + 20, rect.y + POPUP_PAD + ed.char_h + 4 + ed.char_h / 2)
		testing.expect(t, ed.problems.open, "clicked command ran")
		testing.expect(t, !ed.palette.open, "and closed the palette")

		// The shortcut toggles it closed again; no match = nothing runs.
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL)
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL)
		testing.expect(t, !ed.palette.open, "Ctrl+P toggles")
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL)
		type_and_update(&ed, "zzzzqqq")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, !ed.palette.open, "Enter with no match just closes")
	})
}

@(test)
test_every_user_action_has_a_palette_label :: proc(t: ^testing.T) {
	hidden := []km.Action{.None, .Escape, .SaveAs, .Open, .CommandPalette, .OpenKeymapEditor} // OpenKeymapEditor: listed as a window
	outer: for a in km.Action {
		for h in hidden {
			if a == h {
				continue outer
			}
		}
		testing.expectf(t, len(action_label(a)) > 0, "action %v has no palette label", a)
	}
}
