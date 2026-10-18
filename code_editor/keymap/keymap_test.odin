package keymap

import "core:strings"
import "core:testing"

@(test)
test_bind_and_resolve :: proc(t: ^testing.T) {
	km := keymap_init()
	defer keymap_destroy(&km)

	keymap_bind(&km, Chord{.A, {.Ctrl}}, .SelectAll)
	action, ok := keymap_resolve(&km, Chord{.A, {.Ctrl}})
	testing.expect(t, ok, "expected chord to resolve")
	testing.expect_value(t, action, Action.SelectAll)
}

@(test)
test_resolve_unbound_chord_fails :: proc(t: ^testing.T) {
	km := keymap_init()
	defer keymap_destroy(&km)

	_, ok := keymap_resolve(&km, Chord{.Z, {.Ctrl, .Alt}})
	testing.expect(t, !ok, "expected unbound chord to fail resolution")
}

@(test)
test_rebind_overwrites :: proc(t: ^testing.T) {
	km := keymap_init()
	defer keymap_destroy(&km)

	keymap_bind(&km, Chord{.S, {.Ctrl}}, .Save)
	keymap_bind(&km, Chord{.S, {.Ctrl}}, .SaveAs)
	action, ok := keymap_resolve(&km, Chord{.S, {.Ctrl}})
	testing.expect(t, ok, "expected chord to resolve")
	testing.expect_value(t, action, Action.SaveAs)
}

@(test)
test_unbind_removes_chord :: proc(t: ^testing.T) {
	km := keymap_init()
	defer keymap_destroy(&km)

	keymap_bind(&km, Chord{.U, {.Ctrl}}, .Undo)
	keymap_unbind(&km, Chord{.U, {.Ctrl}})
	_, ok := keymap_resolve(&km, Chord{.U, {.Ctrl}})
	testing.expect(t, !ok, "expected chord to be unbound")
}

@(test)
test_default_keymap_other_platform_core_bindings :: proc(t: ^testing.T) {
	km := keymap_default(.Other)
	defer keymap_destroy(&km)

	cases := [][2]any{
		{Chord{.Left, {}}, Action.MoveLeft},
		{Chord{.Right, {.Shift}}, Action.ExtendRight},
		{Chord{.Z, {.Ctrl}}, Action.Undo},
		{Chord{.Z, {.Ctrl, .Shift}}, Action.Redo},
		{Chord{.Y, {.Ctrl}}, Action.Redo},
		{Chord{.S, {.Ctrl}}, Action.Save},
		{Chord{.A, {.Ctrl}}, Action.SelectAll},
		{Chord{.Left, {.Ctrl}}, Action.MoveWordLeft},
		{Chord{.Backspace, {}}, Action.Backspace},
		{Chord{.Tab, {}}, Action.IndentOrTab},
		{Chord{.Tab, {.Shift}}, Action.Outdent},
	}

	for case_ in cases {
		chord := case_[0].(Chord)
		expected := case_[1].(Action)
		action, ok := keymap_resolve(&km, chord)
		testing.expectf(t, ok, "expected chord %v to be bound", chord)
		testing.expect_value(t, action, expected)
	}
}

@(test)
test_default_keymap_macos_uses_super_and_alt :: proc(t: ^testing.T) {
	km := keymap_default(.MacOS)
	defer keymap_destroy(&km)

	action, ok := keymap_resolve(&km, Chord{.S, {.Super}})
	testing.expect(t, ok, "expected Cmd+S to be bound on macOS")
	testing.expect_value(t, action, Action.Save)

	action2, ok2 := keymap_resolve(&km, Chord{.Left, {.Alt}})
	testing.expect(t, ok2, "expected Alt+Left to be bound on macOS")
	testing.expect_value(t, action2, Action.MoveWordLeft)

	// Ctrl+S should NOT be bound to Save on macOS (Super is primary there).
	_, ok3 := keymap_resolve(&km, Chord{.S, {.Ctrl}})
	testing.expect(t, !ok3, "expected Ctrl+S to be unbound on macOS")

	// Cmd+Y is not a redo binding on macOS (only Cmd+Shift+Z is).
	_, ok4 := keymap_resolve(&km, Chord{.Y, {.Super}})
	testing.expect(t, !ok4, "expected Cmd+Y to be unbound on macOS")
}

@(test)
test_f8_navigates_diagnostics :: proc(t: ^testing.T) {
	km := keymap_default(.MacOS)
	defer keymap_destroy(&km)
	action, ok := keymap_resolve(&km, Chord{.F8, {}})
	testing.expect(t, ok && action == .NextDiagnostic, "F8 = next problem")
	action, ok = keymap_resolve(&km, Chord{.F8, {.Shift}})
	testing.expect(t, ok && action == .PrevDiagnostic, "Shift+F8 = previous problem")
}

@(test)
test_quick_fix_and_problems_bindings :: proc(t: ^testing.T) {
	km := keymap_default(.Other)
	defer keymap_destroy(&km)
	action, ok := keymap_resolve(&km, Chord{.Period, {.Ctrl}})
	testing.expect(t, ok && action == .QuickFix, "Ctrl+. = quick fix")
	action, ok = keymap_resolve(&km, Chord{.M, {.Ctrl, .Shift}})
	testing.expect(t, ok && action == .ToggleProblems, "Ctrl+Shift+M = problems")
}

@(test)
test_search_bindings_per_platform :: proc(t: ^testing.T) {
	mac := keymap_default(.MacOS)
	defer keymap_destroy(&mac)
	other := keymap_default(.Other)
	defer keymap_destroy(&other)
	a, ok := keymap_resolve(&mac, Chord{.F, {.Super, .Alt}})
	testing.expect(t, ok && a == .Replace, "Cmd+Alt+F replaces on macOS")
	a, ok = keymap_resolve(&other, Chord{.H, {.Ctrl}})
	testing.expect(t, ok && a == .Replace, "Ctrl+H replaces elsewhere")
	a, ok = keymap_resolve(&other, Chord{.D, {.Ctrl}})
	testing.expect(t, ok && a == .SelectNextOccurrence, "Ctrl+D = next occurrence")
	a, ok = keymap_resolve(&other, Chord{.F3, {.Shift}})
	testing.expect(t, ok && a == .FindPrev, "Shift+F3 = previous match")
}

@(test)
test_palette_bindings :: proc(t: ^testing.T) {
	mac := keymap_default(.MacOS)
	defer keymap_destroy(&mac)
	for chord in ([]Chord{{.P, {.Super}}, {.P, {.Super, .Shift}}, {.F1, {}}}) {
		a, ok := keymap_resolve(&mac, chord)
		testing.expectf(t, ok && a == .CommandPalette, "%v opens the palette", chord)
	}
}

@(test)
test_chord_text_round_trip :: proc(t: ^testing.T) {
	c, ok := chord_parse("cmd+shift+p")
	testing.expect(t, ok && c == Chord{.P, {.Super, .Shift}}, "vscode style")
	c, ok = chord_parse("ctrl-alt-up")
	testing.expect(t, ok && c == Chord{.Up, {.Ctrl, .Alt}}, "zed style")
	c, ok = chord_parse("ctrl+-")
	testing.expect(t, ok && c == Chord{.Minus, {.Ctrl}}, "minus key after +")
	c, ok = chord_parse("cmd--")
	testing.expect(t, ok && c == Chord{.Minus, {.Super}}, "minus key after -")
	c, ok = chord_parse("f12")
	testing.expect(t, ok && c == Chord{.F12, {}}, "bare function key")
	_, ok = chord_parse("cmd+k cmd+s")
	testing.expect(t, !ok, "sequences are not chords")
	_, ok = chord_parse("hyper+x")
	testing.expect(t, !ok, "unknown modifier")
	testing.expect_value(t, chord_format(Chord{.Slash, {.Super, .Shift}}), "cmd+shift+/")
	back, _ := chord_parse(chord_format(Chord{.Equals, {.Ctrl, .Alt}}))
	testing.expect_value(t, back, Chord{.Equals, {.Ctrl, .Alt}})
}

@(test)
test_overrides_round_trip :: proc(t: ^testing.T) {
	defaults := keymap_default(.MacOS)
	defer keymap_destroy(&defaults)
	km := keymap_default(.MacOS)
	defer keymap_destroy(&km)
	keymap_bind(&km, Chord{.D, {.Super}}, .SelectWord)      // changed
	keymap_bind(&km, Chord{.J, {.Ctrl}}, .DeleteLine)       // added
	keymap_unbind(&km, Chord{.F12, {}})                     // removed
	text := keymap_overrides_json(&km, &defaults)
	defer delete(text)
	testing.expect(t, strings.contains(text, `"cmd+d": "SelectWord"`), text)
	testing.expect(t, strings.contains(text, `"f12"`), text)

	fresh := keymap_default(.MacOS)
	defer keymap_destroy(&fresh)
	testing.expect(t, keymap_apply_overrides(&fresh, text), "applies")
	a, _ := keymap_resolve(&fresh, Chord{.D, {.Super}})
	testing.expect_value(t, a, Action.SelectWord)
	a, _ = keymap_resolve(&fresh, Chord{.J, {.Ctrl}})
	testing.expect_value(t, a, Action.DeleteLine)
	_, bound := keymap_resolve(&fresh, Chord{.F12, {}})
	testing.expect(t, !bound, "unbind applied")
	testing.expect_value(t, len(fresh.bindings), len(km.bindings))
}

@(test)
test_import_vscode_keybindings :: proc(t: ^testing.T) {
	km := keymap_default(.MacOS)
	defer keymap_destroy(&km)
	text := `// comment
[
	{ "key": "cmd+shift+d", "command": "editor.action.copyLinesDownAction" },
	{ "key": "cmd+d", "command": "-editor.action.addSelectionToNextFindMatch" },
	{ "key": "cmd+k cmd+\\", "command": "workbench.action.splitEditorUp" },
	{ "key": "ctrl+t", "command": "workbench.action.terminal.toggleTerminal" },
	{ "key": "cmd+j", "command": "editor.action.revealDefinition", "when": "editorTextFocus" },
	{ "key": "cmd+l", "command": "workbench.action.files.save", "when": "terminalFocus" },
]`
	r, ok := keymap_import_vscode(&km, text)
	testing.expect(t, ok, "parsed (comments + trailing comma)")
	testing.expect_value(t, r.bound, 2)
	testing.expect_value(t, r.unbound, 1)
	testing.expect_value(t, r.sequences, 1)
	testing.expect_value(t, r.unknown, 1)
	testing.expect_value(t, r.skipped, 1)
	a, _ := keymap_resolve(&km, Chord{.D, {.Super, .Shift}})
	testing.expect_value(t, a, Action.DuplicateLineDown)
	_, bound := keymap_resolve(&km, Chord{.D, {.Super}})
	testing.expect(t, !bound, "-command removed the default binding")
	a, _ = keymap_resolve(&km, Chord{.J, {.Super}})
	testing.expect_value(t, a, Action.GotoDefinition)
}

@(test)
test_import_zed_keymap :: proc(t: ^testing.T) {
	km := keymap_default(.MacOS)
	defer keymap_destroy(&km)
	text := `[
  { "context": "Workspace", "bindings": { "cmd-shift-p": "command_palette::Toggle" } },
  { "context": "Editor && vim_mode == insert", "bindings": { "j k": "vim::NormalBefore" } },
  { "context": "Editor", "bindings": { "cmd-shift-d": "editor::DuplicateLineUp", "ctrl-g": ["editor::SelectNext", {"replace_newest": false}], "f12": null } },
  { "context": "Editor", "unbind": { "alt-shift-up": "editor::DuplicateLineUp" } },
  { "bindings": { "ctrl-q": "editor::ToggleFocus" } },
  { "context": "Terminal", "bindings": { "cmd-k": "terminal::Clear" } },
]`
	r, ok := keymap_import_zed(&km, text)
	testing.expect(t, ok, "parsed")
	a, _ := keymap_resolve(&km, Chord{.D, {.Super, .Shift}})
	testing.expect_value(t, a, Action.DuplicateLineUp)
	a, _ = keymap_resolve(&km, Chord{.G, {.Ctrl}})
	testing.expect_value(t, a, Action.SelectNextOccurrence) // [action, args] form
	_, bound := keymap_resolve(&km, Chord{.F12, {}})
	testing.expect(t, !bound, "null unbinds")
	_, bound = keymap_resolve(&km, Chord{.Up, {.Alt, .Shift}})
	testing.expect(t, !bound, "unbind section")
	testing.expect_value(t, r.unknown, 1) // editor::ToggleFocus
	testing.expect_value(t, r.skipped, 2) // vim + terminal
	testing.expect_value(t, r.bound, 3)
}
