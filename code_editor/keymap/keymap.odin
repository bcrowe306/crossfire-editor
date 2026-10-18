// Package keymap is a platform-agnostic hotkey table: it knows nothing
// about SDL. The host (the `editor` package) translates raw input events
// into `Chord` values and resolves them through a `Keymap` to get an
// `Action`. This keeps the bindings data-driven, remappable, and testable
// without any windowing/input library.
package keymap

Modifier :: enum {
	Shift,
	Ctrl,
	Alt,
	Super, // Cmd on macOS, Win key elsewhere.
}

Modifiers :: bit_set[Modifier]

// Key is a small, platform-independent enumeration of the physical keys the
// editor cares about. Hosts map their native keycodes onto this set.
Key :: enum {
	Unknown,
	A, B, C, D, E, F, G, H, I, J, K, L, M,
	N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	Num0, Num1, Num2, Num3, Num4, Num5, Num6, Num7, Num8, Num9,
	Left, Right, Up, Down,
	Home, End, PageUp, PageDown,
	Backspace, Delete, Enter, Tab, Escape, Space,
	Slash, Backslash, Minus, Equals, LeftBracket, RightBracket,
	Semicolon, Quote, Comma, Period, Grave,
	F8, F3, F1, F12, F4,
}

Chord :: struct {
	key:  Key,
	mods: Modifiers,
}

Action :: enum {
	None,

	// Navigation.
	MoveLeft, MoveRight, MoveUp, MoveDown,
	MoveWordLeft, MoveWordRight,
	MoveLineStart, MoveLineEnd,
	MoveDocStart, MoveDocEnd,
	MovePageUp, MovePageDown,

	// Selection (extend variants of navigation).
	ExtendLeft, ExtendRight, ExtendUp, ExtendDown,
	ExtendWordLeft, ExtendWordRight,
	ExtendLineStart, ExtendLineEnd,
	ExtendDocStart, ExtendDocEnd,
	ExtendPageUp, ExtendPageDown,
	SelectAll, SelectLine, SelectWord,

	// Editing.
	Backspace, BackspaceWord,
	DeleteForward, DeleteForwardWord,
	Newline,
	IndentOrTab, Outdent,
	DuplicateLineUp, DuplicateLineDown,
	MoveLineUp, MoveLineDown,
	ToggleLineComment, DeleteLine,
	InsertLineBelow, InsertLineAbove,

	// Clipboard & history.
	Cut, Copy, Paste,
	Undo, Redo,

	// File operations (host wires these up).
	Save, SaveAs, Open,

	// Multi-cursor.
	AddCursorAbove, AddCursorBelow,

	// Language features.
	TriggerCompletion, TriggerSignatureHelp,
	NextDiagnostic, PrevDiagnostic,
	QuickFix, ToggleProblems,
	GotoDefinition, PeekDefinition, FindReferences,
	NextReference, PrevReference,
	NavigateBack, NavigateForward,

	// Search.
	Find, Replace, FindNext, FindPrev,
	SelectNextOccurrence, SelectAllOccurrences,

	// View.
	ZoomIn, ZoomOut, ZoomReset,
	CommandPalette,

	// Preferences.
	OpenKeymapEditor, ImportZedKeymap, ImportVSCodeKeymap,

	// Misc.
	Escape,
}

Keymap :: struct {
	bindings: map[Chord]Action,
}

keymap_init :: proc(allocator := context.allocator) -> Keymap {
	return Keymap{bindings = make(map[Chord]Action, allocator)}
}

keymap_destroy :: proc(km: ^Keymap) {
	delete(km.bindings)
}

keymap_bind :: proc(km: ^Keymap, chord: Chord, action: Action) {
	km.bindings[chord] = action
}

keymap_unbind :: proc(km: ^Keymap, chord: Chord) {
	delete_key(&km.bindings, chord)
}

// keymap_resolve looks up the action bound to `chord`. `ok` is false if the
// chord is unbound.
keymap_resolve :: proc(km: ^Keymap, chord: Chord) -> (action: Action, ok: bool) {
	action, ok = km.bindings[chord]
	return
}
