// Default keybinding tables matching VSCode/Zed conventions. `primary` is
// the platform's "command" modifier: Super (Cmd) on macOS, Ctrl everywhere
// else. Word-jump/outdent etc. use Alt on macOS and Ctrl elsewhere to match
// each platform's native text-editing conventions.
package keymap

Platform :: enum {
	MacOS,
	Other,
}

// keymap_default builds the standard editor keymap for `platform`.
keymap_default :: proc(platform: Platform, allocator := context.allocator) -> Keymap {
	km := keymap_init(allocator)

	primary: Modifiers
	word_mod: Modifiers
	if platform == .MacOS {
		primary = {.Super}
		word_mod = {.Alt}
	} else {
		primary = {.Ctrl}
		word_mod = {.Ctrl}
	}

	// Navigation.
	keymap_bind(&km, Chord{.Left, {}}, .MoveLeft)
	keymap_bind(&km, Chord{.Right, {}}, .MoveRight)
	keymap_bind(&km, Chord{.Up, {}}, .MoveUp)
	keymap_bind(&km, Chord{.Down, {}}, .MoveDown)
	keymap_bind(&km, Chord{.Home, {}}, .MoveLineStart)
	keymap_bind(&km, Chord{.End, {}}, .MoveLineEnd)
	keymap_bind(&km, Chord{.PageUp, {}}, .MovePageUp)
	keymap_bind(&km, Chord{.PageDown, {}}, .MovePageDown)
	keymap_bind(&km, Chord{.Left, word_mod}, .MoveWordLeft)
	keymap_bind(&km, Chord{.Right, word_mod}, .MoveWordRight)
	keymap_bind(&km, Chord{.Home, primary}, .MoveDocStart)
	keymap_bind(&km, Chord{.End, primary}, .MoveDocEnd)

	// Selection: Shift + any navigation chord becomes the Extend variant.
	keymap_bind(&km, Chord{.Left, {.Shift}}, .ExtendLeft)
	keymap_bind(&km, Chord{.Right, {.Shift}}, .ExtendRight)
	keymap_bind(&km, Chord{.Up, {.Shift}}, .ExtendUp)
	keymap_bind(&km, Chord{.Down, {.Shift}}, .ExtendDown)
	keymap_bind(&km, Chord{.Home, {.Shift}}, .ExtendLineStart)
	keymap_bind(&km, Chord{.End, {.Shift}}, .ExtendLineEnd)
	keymap_bind(&km, Chord{.PageUp, {.Shift}}, .ExtendPageUp)
	keymap_bind(&km, Chord{.PageDown, {.Shift}}, .ExtendPageDown)
	keymap_bind(&km, Chord{.Left, word_mod | {.Shift}}, .ExtendWordLeft)
	keymap_bind(&km, Chord{.Right, word_mod | {.Shift}}, .ExtendWordRight)
	keymap_bind(&km, Chord{.Home, primary | {.Shift}}, .ExtendDocStart)
	keymap_bind(&km, Chord{.End, primary | {.Shift}}, .ExtendDocEnd)
	keymap_bind(&km, Chord{.A, primary}, .SelectAll)
	keymap_bind(&km, Chord{.L, primary}, .SelectLine)
	keymap_bind(&km, Chord{.D, primary}, .SelectNextOccurrence)
	keymap_bind(&km, Chord{.L, primary | {.Shift}}, .SelectAllOccurrences)

	// Editing.
	keymap_bind(&km, Chord{.Backspace, {}}, .Backspace)
	keymap_bind(&km, Chord{.Backspace, word_mod}, .BackspaceWord)
	keymap_bind(&km, Chord{.Delete, {}}, .DeleteForward)
	keymap_bind(&km, Chord{.Delete, word_mod}, .DeleteForwardWord)
	keymap_bind(&km, Chord{.Enter, {}}, .Newline)
	keymap_bind(&km, Chord{.Tab, {}}, .IndentOrTab)
	keymap_bind(&km, Chord{.Tab, {.Shift}}, .Outdent)
	keymap_bind(&km, Chord{.Up, {.Alt}}, .MoveLineUp)
	keymap_bind(&km, Chord{.Down, {.Alt}}, .MoveLineDown)
	keymap_bind(&km, Chord{.Up, {.Alt, .Shift}}, .DuplicateLineUp)
	keymap_bind(&km, Chord{.Down, {.Alt, .Shift}}, .DuplicateLineDown)
	keymap_bind(&km, Chord{.Slash, primary}, .ToggleLineComment)
	keymap_bind(&km, Chord{.K, primary | {.Shift}}, .DeleteLine)
	keymap_bind(&km, Chord{.Enter, primary}, .InsertLineBelow)
	keymap_bind(&km, Chord{.Enter, primary | {.Shift}}, .InsertLineAbove)

	// Clipboard & history.
	keymap_bind(&km, Chord{.C, primary}, .Copy)
	keymap_bind(&km, Chord{.X, primary}, .Cut)
	keymap_bind(&km, Chord{.V, primary}, .Paste)
	keymap_bind(&km, Chord{.Z, primary}, .Undo)
	keymap_bind(&km, Chord{.Z, primary | {.Shift}}, .Redo)
	if platform != .MacOS {
		keymap_bind(&km, Chord{.Y, primary}, .Redo)
	}

	// File operations.
	keymap_bind(&km, Chord{.S, primary}, .Save)
	keymap_bind(&km, Chord{.S, primary | {.Shift}}, .SaveAs)
	keymap_bind(&km, Chord{.O, primary}, .Open)

	// Multi-cursor.
	keymap_bind(&km, Chord{.Up, primary | {.Alt}}, .AddCursorAbove)
	keymap_bind(&km, Chord{.Down, primary | {.Alt}}, .AddCursorBelow)

	// Language features.
	keymap_bind(&km, Chord{.Space, primary}, .TriggerCompletion)
	keymap_bind(&km, Chord{.Space, primary | {.Shift}}, .TriggerSignatureHelp)
	keymap_bind(&km, Chord{.F8, {}}, .NextDiagnostic)
	keymap_bind(&km, Chord{.F8, {.Shift}}, .PrevDiagnostic)
	keymap_bind(&km, Chord{.Period, primary}, .QuickFix)
	keymap_bind(&km, Chord{.F12, {}}, .GotoDefinition)
	keymap_bind(&km, Chord{.F12, {.Alt}}, .PeekDefinition)
	keymap_bind(&km, Chord{.F12, {.Shift}}, .FindReferences)
	keymap_bind(&km, Chord{.F4, {}}, .NextReference)
	keymap_bind(&km, Chord{.F4, {.Shift}}, .PrevReference)
	// Back/forward: VSCode uses Ctrl+- on macOS, Alt+Left elsewhere.
	if platform == .MacOS {
		keymap_bind(&km, Chord{.Minus, {.Ctrl}}, .NavigateBack)
		keymap_bind(&km, Chord{.Minus, {.Ctrl, .Shift}}, .NavigateForward)
	} else {
		keymap_bind(&km, Chord{.Left, {.Alt}}, .NavigateBack)
		keymap_bind(&km, Chord{.Right, {.Alt}}, .NavigateForward)
	}
	keymap_bind(&km, Chord{.M, primary | {.Shift}}, .ToggleProblems)

	// Search (VSCode: replace is Ctrl+H, or Cmd+Alt+F on macOS).
	keymap_bind(&km, Chord{.F, primary}, .Find)
	if platform == .MacOS {
		keymap_bind(&km, Chord{.F, primary | {.Alt}}, .Replace)
	} else {
		keymap_bind(&km, Chord{.H, primary}, .Replace)
	}
	keymap_bind(&km, Chord{.F3, {}}, .FindNext)
	keymap_bind(&km, Chord{.F3, {.Shift}}, .FindPrev)
	keymap_bind(&km, Chord{.G, primary}, .FindNext)
	keymap_bind(&km, Chord{.G, primary | {.Shift}}, .FindPrev)

	// Zoom: '+' is Shift+'=' on most layouts, so bind both.
	keymap_bind(&km, Chord{.Equals, primary}, .ZoomIn)
	keymap_bind(&km, Chord{.Equals, primary | {.Shift}}, .ZoomIn)
	keymap_bind(&km, Chord{.Minus, primary}, .ZoomOut)
	keymap_bind(&km, Chord{.Num0, primary}, .ZoomReset)

	// Command palette: Cmd/Ctrl+P, plus VSCode's Cmd/Ctrl+Shift+P and F1.
	keymap_bind(&km, Chord{.P, primary}, .CommandPalette)
	keymap_bind(&km, Chord{.P, primary | {.Shift}}, .CommandPalette)
	keymap_bind(&km, Chord{.F1, {}}, .CommandPalette)

	keymap_bind(&km, Chord{.Escape, {}}, .Escape)

	return km
}
