package crossfire_editor

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"

// Clickable errors (error_locations.odin): what counts as a location, where the file is, and Go
// to Error opening it in a code tab (read-only outside the project)

@(test)
error_locations_are_found_in_lines :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		path, shortPath: string,
		line, column: int,
	}
	cases := []Case{
		// Odin's compile errors and a panic's location
		{"/home/me/game/scripts/hero.odin(12:5) Error: Undeclared name: speed", "/home/me/game/scripts/hero.odin", "", 12, 5},
		{"/home/me/game/scripts/hero.odin(40:3) panic: out of coins", "/home/me/game/scripts/hero.odin", "", 40, 3},
		{"scripts/hero.odin(7) Error: Expected ;", "scripts/hero.odin", "", 7, 0},
		// Windows, with a drive letter, either separator
		{`C:\Users\me\game\scripts\hero.odin(12:5) Error: Undeclared name: speed`, `C:\Users\me\game\scripts\hero.odin`, "", 12, 5},
		{"D:/games/My Game/scripts/hero.odin(3:1) Syntax Error: x", "D:/games/My Game/scripts/hero.odin", "Game/scripts/hero.odin", 3, 1},
		{`\\server\share\hero.odin(2:4) Error: x`, `\\server\share\hero.odin`, "", 2, 4},
		// A path with spaces at the start of the line, and text before a path
		{"/home/me/My Game/scripts/hero.odin(3:7) Error: x", "/home/me/My Game/scripts/hero.odin", "Game/scripts/hero.odin", 3, 7},
		{"runtime assertion at scripts/coin.odin(9:2): picked twice", "scripts/coin.odin", "", 9, 2},
		// The colon style (glslang, most tools), a log line's [file:line:proc()]
		{"ERROR: /home/me/game/shaders/flash.frag:14: 'tint' : undeclared identifier", "/home/me/game/shaders/flash.frag", "", 14, 0},
		{"hero.odin:22:9: warning: unused", "hero.odin", "", 22, 9},
		{"[main.odin:45:run()] message", "main.odin", "", 45, 0},
		{`C:\game\shaders\flash.frag:3: error`, `C:\game\shaders\flash.frag`, "", 3, 0},
		// The first location wins
		{"a.odin(1:2) and b.odin(3:4)", "a.odin", "", 1, 2},
	}
	for c in cases {
		location, ok := ErrorLocation_Parse(c.text)
		testing.expectf(t, ok, "a location in %q", c.text)
		testing.expectf(t, location.path == c.path, "%q: path %q, not %q", c.text, location.path, c.path)
		testing.expectf(t, location.shortPath == c.shortPath, "%q: short path %q, not %q", c.text, location.shortPath, c.shortPath)
		testing.expectf(t, location.line == c.line && location.column == c.column, "%q: %d:%d, not %d:%d", c.text, location.line, location.column, c.line, c.column)
	}
	// Lines that only look like it
	for text in ([]string{
		"Playing /home/me/game",
		"Game exited (exit code 1)",
		"[2026-10-15 18:17:10] started",
		"Connected to localhost:8080",
		"http://example.com:80/x",
		"Version 1.2:3",
		"call(12) failed",
		"hero.odin(12:5",
		"hero.odin(0:1) Error",
		"size 3x4.5:2px",
		"",
	}) {
		_, ok := ErrorLocation_Parse(text)
		testing.expectf(t, !ok, "no location in %q", text)
	}
}

@(test)
go_to_error_opens_the_file_at_the_line :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	dir := scratchDir("editor_test_error_locations")
	defer removeAll(dir)
	outside := scratchDir("editor_test_error_outside")
	defer removeAll(outside)
	state := State{
		project = Project_CreateDemo("unused"),
		browserSelection = {kind = .None},
		selectedNode = -1,
		busSelection = -1,
		settings = Settings_Default(),
	}
	defer State_Destroy(&state)
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone(dir)
	_ = os.make_directory(joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator))
	hero := joinPath(dir, "scripts/hero.odin", allocator = context.temp_allocator)
	_ = os.write_entire_file(hero, transmute([]byte)string("package scripts\n\nHero :: struct {\n\tspeed: f32,\n}\n"))
	library := joinPath(outside, "library.odin", allocator = context.temp_allocator)
	_ = os.write_entire_file(library, transmute([]byte)string("package library\n\nx := 1\ny := 2\n"))
	state.settings.olsPath = FixedText_Make("/nonexistent/ols")
	state.settings.builtInCodeEditor = true

	// Absolute, relative to the project and to its scripts folder, missing
	resolve :: proc(state: ^State, text: string, output := false) -> string {
		location, _ := ErrorLocation_Parse(text)
		return ErrorLocation_Resolve(state, location, output)
	}
	testing.expect_value(t, filepath.base(resolve(&state, "scripts/hero.odin(4:2) Error")), "hero.odin")
	testing.expect_value(t, filepath.base(resolve(&state, "[hero.odin:4:ready()] x")), "hero.odin")
	testing.expect_value(t, resolve(&state, "missing.odin(1:1) Error"), "")
	testing.expect(t, Path_InProject(&state, absolutePath(hero)), "in the project")
	testing.expect(t, !Path_InProject(&state, absolutePath(library)), "outside it")

	// A Console line with a location: the menu offers Go to Error, which opens it at the column
	logLine(&state, .Info, strings.clone("Nothing here"), echo = false)
	logLine(&state, .Error, strings.concatenate({absolutePath(hero), "(4:3) Error: Undeclared name: f33"}), echo = false)
	serial := state.console.serial
	state.contextMenu = {open = true, target = Ctx_Log{line = serial}}
	testing.expect(t, !menuHas(&state, "Go to Error"), "not on a plain line")
	state.contextMenu = {open = true, target = Ctx_Log{line = serial + 1}}
	testing.expect(t, menuHas(&state, "Go to Error"), "on a located line")
	state.contextMenu = {}
	send(&state, Log_Command{.Go_To_Error, false, serial + 1})
	testing.expect_value(t, filepath.base(CodeTabs_Active(&state)), "hero.odin")
	line, column := CodeEditor_Caret(CodeTabs_Active(&state))
	testing.expect_value(t, line, 4)
	testing.expect_value(t, column, 3)
	testing.expect(t, !CodeEditor_IsReadOnly(CodeTabs_Active(&state)), "the project's own file is editable")

	// An Output line naming a file outside the project opens it read-only
	outputLine(&state, .Error, strings.concatenate({absolutePath(library), "(3:1) Error: x"}))
	send(&state, Log_Command{.Go_To_Error, true, state.output.serial})
	testing.expect_value(t, filepath.base(CodeTabs_Active(&state)), "library.odin")
	testing.expect(t, CodeEditor_IsReadOnly(CodeTabs_Active(&state)), "outside the project: read-only")
	testing.expect(t, !CodeEditor_InsertAtLine(CodeTabs_Active(&state), 1, "// nope\n") || !strings.contains(CodeEditor_Text(CodeTabs_Active(&state)), "nope"), "no edits")
	testing.expect(t, !CodeEditor_IsDirty(CodeTabs_Active(&state)), "nothing to save")
	testing.expect_value(t, len(state.codeTabs), 2)

	// The external editor gets the column too
	command := Script_EditorCommand("zed", "{file}:{line}:{column}", "/a/b.odin", 4, column = 3)
	testing.expect_value(t, command[1], "/a/b.odin:4:3")
	free_all(context.temp_allocator)
}

// A fresh empty folder under the system temp directory
@(private="file")
scratchDir :: proc(name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir := joinPath(base, name, allocator = context.temp_allocator)
	_ = removeAll(dir)
	_ = os.make_directory_all(dir)
	return dir
}

// Whether the open context menu has an item with this label
@(private="file")
menuHas :: proc(state: ^State, label: string) -> bool {
	for item in ContextMenu_Items(state) do if item.label == label do return true
	return false
}

@(private="file")
send :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}
