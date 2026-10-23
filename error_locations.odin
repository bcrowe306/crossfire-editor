package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "gui:skald"

/*
Clickable errors: a Console or Output line naming a source location opens that file in a code
tab at the line and column (`Script_Open`: the built-in code editor, or the external one with
its `{line}` and `{column}`).

What counts as a location (`ErrorLocation_Parse`): a file path with an extension followed by
`(line:column)` or `(line)`, Odin's style (compile errors, and a panic's or failed assertion's
`#caller_location`), or by `:line:column` or `:line` (glslang, most other tools). Windows paths
with a drive letter (`C:\game\scripts\hero.odin(3:7)`) work too.

Relative paths are resolved where the line came from (`ErrorLocation_Resolve`): the Output tab's
builds ran in the editor's working folder, the game in the project's; then the project, its
scripts folder and the engine. Files outside the project (the engine's sources, Odin's library)
open read-only in the built-in editor: they're shared with every other project.

In the view (view_bottom.odin): a line with a location turns the accent color under the pointer,
which becomes a hand; a click opens it. Its menu has Go to Error. Widgets:
`<list key>-link-<index>` (the line's text).
*/

// A source location named in a line of output
ErrorLocation :: struct {
	// The file as the line spells it (a slice of the line)
	path: string,
	// The same, without what came before the last space in it: the line's start may be a path
	// with spaces ("/home/me/My Game/scripts/hero.odin(3:7) Error"), or text before a path
	// ("boom at scripts/hero.odin:3"). `path` is tried first, then this ("" when the same)
	shortPath: string,
	// 1-based; column 0 when the line gave none
	line, column: int,
}

/*
Finds the first source location in a line of output.

Inputs:
- text: The line

Returns:
- The location (its paths are slices of `text`), and whether there was one

Example:
	location, ok := ErrorLocation_Parse("/game/scripts/hero.odin(12:5) Error: Undeclared name: speed")
	// ok, location.path == "/game/scripts/hero.odin", location.line == 12, location.column == 5
*/
ErrorLocation_Parse :: proc(text: string) -> (location: ErrorLocation, ok: bool) {
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c != '(' && c != ':' do continue
		line, column, valid := locationNumbers(text, i)
		if !valid do continue
		// The path: back to a space or a delimiter
		start := i
		for start > 0 && !isPathStop(text[start - 1]) do start -= 1
		short := text[start:i]
		// A URL's port isn't a line
		if !hasExtension(short) || strings.contains(short, "://") do continue
		path := short
		// The line may start with a path with spaces in it (an absolute one)
		whole := strings.trim_left_space(text[:i])
		if whole != short && looksAbsolute(whole) && hasExtension(whole) do path = whole
		return {path = path, shortPath = path == short ? "" : short, line = line, column = column}, true
	}
	return {}, false
}

// `(12:5)`, `(12)`, `:12:5` or `:12` at `text[at]`: the line and column (0 when none)
@(private="file")
locationNumbers :: proc(text: string, at: int) -> (line, column: int, ok: bool) {
	open := text[at]
	i := at + 1
	digits :: proc(text: string, i: ^int) -> (int, bool) {
		start := i^
		for i^ < len(text) && text[i^] >= '0' && text[i^] <= '9' do i^ += 1
		if i^ == start || i^ - start > 9 do return 0, false
		n, _ := strconv.parse_int(text[start:i^])
		return n, true
	}
	n, found := digits(text, &i)
	if !found || n < 1 do return 0, 0, false
	line = n
	if i + 1 < len(text) && text[i] == ':' && text[i + 1] >= '0' && text[i + 1] <= '9' {
		i += 1
		column, _ = digits(text, &i)
	}
	if open == '(' {
		if i >= len(text) || text[i] != ')' do return 0, 0, false
	} else if i < len(text) && (text[i] == '.' || (text[i] >= 'a' && text[i] <= 'z') || (text[i] >= 'A' && text[i] <= 'Z')) {
		// "1.5:2.5", "x:12px": not a line number
		return 0, 0, false
	}
	return line, column, true
}

// Characters a path in a line of output doesn't contain
@(private="file")
isPathStop :: proc(c: u8) -> bool {
	switch c {
	case ' ', '\t', '"', '\'', '`', '[', '<', '(', '=', ',', ';': return true
	}
	return false
}

// Whether a path's file name has an extension with a letter in it ("hero.odin", "a.frag": not
// "1.2" or "host")
@(private="file")
hasExtension :: proc(path: string) -> bool {
	base := path
	if slash := strings.last_index_any(path, "/\\"); slash >= 0 do base = path[slash + 1:]
	dot := strings.last_index_byte(base, '.')
	if dot < 0 || dot == len(base) - 1 || len(base) - dot > 9 do return false
	letter := false
	for c in transmute([]u8)base[dot + 1:] {
		switch c {
		case 'a'..='z', 'A'..='Z': letter = true
		case '0'..='9', '_':
		case: return false
		}
	}
	return letter
}

// "/home/...", "C:\...", "C:/...", "\\server\..."
@(private="file")
looksAbsolute :: proc(path: string) -> bool {
	if strings.has_prefix(path, "/") || strings.has_prefix(path, "\\\\") do return true
	return len(path) > 2 && ((path[0] >= 'a' && path[0] <= 'z') || (path[0] >= 'A' && path[0] <= 'Z')) && path[1] == ':' && (path[2] == '\\' || path[2] == '/')
}

/*
Where a location's file is on disk: the path as given if absolute, else under where the line
came from (the Output tab's builds: the editor's working folder; the game: the project), the
project, its scripts folder, or the engine.

Inputs:
- state: The editor state (the project)
- location: From `ErrorLocation_Parse`
- output: The line is the Output tab's

Returns:
- The file's absolute path (temp allocated), or "" if none of them exists
*/
ErrorLocation_Resolve :: proc(state: ^State, location: ErrorLocation, output: bool) -> string {
	project := absolutePath(state.project.rootPath)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	engine, _ := Toolchain_EngineDir()
	bases := make([dynamic]string, context.temp_allocator)
	append(&bases, output ? cwd : project, project, joinPath(project, SCRIPTS_FOLDER, allocator = context.temp_allocator), cwd)
	if engine != "" do append(&bases, engine)
	for path in ([]string{location.path, location.shortPath}) {
		if path == "" do continue
		if filepath.is_abs(path) {
			if os.is_file(path) do return absolutePath(path)
			continue
		}
		for base in bases {
			if base == "" do continue
			candidate := joinPath(base, path, allocator = context.temp_allocator)
			if os.is_file(candidate) do return absolutePath(candidate)
		}
	}
	return ""
}

/*
The location in a Console or Output line, by the line's serial number (`LogList.serial` + its
index).

Returns:
- The location and whether the line has one
*/
ErrorLocation_OfLine :: proc(state: ^State, output: bool, serial: int) -> (ErrorLocation, bool) {
	list := logListOf(state, output)
	lines := LogList_Lines(list)
	index := serial - list.serial
	if index < 0 || index >= len(lines) do return {}, false
	return ErrorLocation_Parse(lines[index].text)
}

/*
Go to Error: opens a Console or Output line's location in the code editor (`Script_Open`), a
file outside the project read-only. A file that isn't found is logged.

Inputs:
- state: The editor state
- output: The line is the Output tab's
- serial: The line's serial number

Returns:
- The command `Script_Open` gives (the external editor's watch)
*/
ErrorLocation_Open :: proc(state: ^State, output: bool, serial: int) -> skald.Command(Msg) {
	location, ok := ErrorLocation_OfLine(state, output, serial)
	if !ok do return {}
	path := ErrorLocation_Resolve(state, location, output)
	if path == "" {
		logLine(state, .Warning, fmt.aprintf("Couldn't find %s", location.path))
		return {}
	}
	return Script_Open(state, path, location.line, location.column, readOnly = !Path_InProject(state, path))
}

/*
Whether a file is inside the open project's folder.

Inputs:
- state: The editor state
- path: An absolute path

Returns:
- true if it's under the project's folder
*/
Path_InProject :: proc(state: ^State, path: string) -> bool {
	project, _ := filepath.clean(absolutePath(state.project.rootPath), context.temp_allocator)
	file, _ := filepath.clean(path, context.temp_allocator)
	return isInside(file, project)
}
