package crossfire_editor

import "core:encoding/ini"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import "gui:skald"

/*
Log points: "log this expression here" on a line of a script procedure, without editing the
script (round 6 of the code editor integration).

- **Setting one:** a click in a code tab's marker column on a line inside a procedure, or the
  right-click menu's Add Log Point..., opens the Log Point dialog (the expression, OK, Remove);
  `LogPoint_Check` says when a line can't take one (outside a procedure, a `case` or `else`
  line, a line continuing an expression or inside a literal). A log point shows as a marker
  (a diamond; dim when off) and a hint with its expression; a click on the marker offers Edit,
  Turn Off / On and Remove.
- **Kept per project** in `.editor/logpoints.ini` (per user, like the guides): the file, the line,
  the expression, on or off, and the line's text then, so a log point follows its line when
  lines are added above it (`LogPoints_Relocate`: the nearest line with that text, 200 either
  way); one whose line is gone is skipped (and said so in the Output tab) until it's moved.
- **Applied through a build, never in the user's file:** while any log point is on, Play and hot
  reload build the game from a copy of the scripts folder
  (`build/players/<project>/logpoints/scripts`, `LogPoints_WriteBuild`) in which each log
  point's line starts with
  `e.Log_Debug("hero.odin:42: self.hp = %v", self.hp, category = "logpoint"); ` (`LogPoint_Inject`:
  on the same line, so every other line keeps its number and compiler errors point at the
  user's lines; the build's paths are turned back into the project's in the Output tab). The
  generated main imports `logpoints:scripts` then (`playerMainSource`). Adding, changing or
  removing one while the game plays starts a hot reload (`PlayReload.builtLogPoints`).
- **In the Console** the game's lines come in the "logpoint" category, `hero.odin:42: self.hp =
  3`, and a click on the location opens the script at the line (clickable errors).
*/

// Where a project's log points are kept (beside the guides)
LOG_POINTS_FILE :: ".editor/logpoints.ini"
// The Console category of their lines
LOG_POINT_CATEGORY :: "logpoint"
// The folder of a player's build holding the scripts with log points (under build/players/<project>/)
LOG_POINTS_BUILD :: "logpoints"

// A log point (strings owned)
LogPoint :: struct {
	// The script's file in scripts/ ("hero.odin")
	file: string,
	// 1-based
	line: int,
	expression: string,
	enabled: bool,
	// The line's text when it was set (trimmed): found again after lines move
	text: string,
}

// The project's log points (`State.logPoints`)
LogPoints :: struct {
	points: [dynamic]LogPoint,
	// The project folder they were read for (owned; "" none yet)
	root: string,
	// Bumped by every change (a running game is built again)
	generation: int,
	dialog: LogPointDialog,
}

// The Log Point dialog (strings owned)
LogPointDialog :: struct {
	open: bool,
	file: string,
	line: int,
	text: string,
	expression: string,
	// It edits a log point that's there (Remove shows)
	existing: bool,
}

// Opens the Log Point dialog for a line of a script (file in scripts/, 1-based line; strings temp)
Log_Point_Dialog_Opened :: struct {
	file: string,
	line: int,
	text: string,
}
Log_Point_Expression_Changed :: distinct string
Log_Point_Saved :: struct {}
Log_Point_Cancelled :: struct {}
// A marker's choice: edit it (the dialog), turn it off or on, remove it
Log_Point_Command :: struct {
	file: string,
	line: int,
	op: LogPointOp,
}
LogPointOp :: enum {
	Edit,
	Toggle,
	Remove,
}
// Something set where a log point can't go: the reason, for the Console (temp)
Log_Point_Refused :: distinct string

// What the log point providers left for the view to send (package state, like the others')
@(private="file")
logPointsLeft: struct {
	open: Maybe(Log_Point_Dialog_Opened),
	command: Maybe(Log_Point_Command),
	refused: string,
}

// --- the list -------------------------------------------------------------------

/*
Reads the project's log points when the project changed (called by `update` for every message:
a string compare when it hasn't).
*/
LogPoints_Follow :: proc(state: ^State) {
	lp := &state.logPoints
	if lp.root == state.project.rootPath do return
	LogPoints_Clear(lp)
	delete(lp.root)
	lp.root = strings.clone(state.project.rootPath)
	path, _ := filepath.join({state.project.rootPath, LOG_POINTS_FILE}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	LogPoints_Parse(lp, string(data))
}

/*
Reads log points from their file's text (`[hero.odin:42]` sections with `expression`, `enabled`,
`text`), adding them to `lp`.
*/
LogPoints_Parse :: proc(lp: ^LogPoints, text: string) {
	it := ini.iterator_from_string(text)
	current := -1
	section := ""
	for key, value in ini.iterate(&it) {
		if it.section != section || current < 0 {
			section = it.section
			file, _, number := strings.partition(section, ":")
			line, ok := strconv.parse_int(number)
			if !ok || file == "" {
				current = -1
				continue
			}
			append(&lp.points, LogPoint{file = strings.clone(file), line = line, enabled = true, expression = strings.clone(""), text = strings.clone("")})
			current = len(lp.points) - 1
		}
		p := &lp.points[current]
		switch key {
		case "expression":
			delete(p.expression)
			p.expression = strings.clone(strings.trim_space(value))
		case "enabled":
			p.enabled = strings.trim_space(value) != "false"
		case "text":
			delete(p.text)
			p.text = strings.clone(strings.trim_space(value))
		}
	}
	// One without an expression logs nothing
	for i := len(lp.points) - 1; i >= 0; i -= 1 {
		if lp.points[i].expression != "" do continue
		logPointFree(&lp.points[i])
		ordered_remove(&lp.points, i)
	}
}

/*
The log points as their file keeps them (temp allocated).
*/
LogPoints_Format :: proc(lp: ^LogPoints) -> string {
	b := strings.builder_make(context.temp_allocator)
	for p in lp.points {
		fmt.sbprintf(&b, "[%s:%d]\nexpression = %s\nenabled = %v\ntext = %s\n", p.file, p.line, p.expression, p.enabled, p.text)
	}
	return strings.to_string(b)
}

/*
Writes the project's log points (the file goes when there are none).

Returns:
- "" or what went wrong (temp allocated)
*/
LogPoints_Save :: proc(state: ^State) -> string {
	lp := &state.logPoints
	path, _ := filepath.join({state.project.rootPath, LOG_POINTS_FILE}, context.temp_allocator)
	if len(lp.points) == 0 {
		if os.exists(path) do _ = os.remove(path)
		return ""
	}
	_ = os.make_directory_all(filepath.dir(path))
	text := LogPoints_Format(lp)
	if old, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(old) == text do return ""
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil do return fmt.tprintf("Couldn't write %s: %v", path, err)
	return ""
}

// The log point on a line of a file (nil none)
LogPoints_Find :: proc(lp: ^LogPoints, file: string, line: int) -> ^LogPoint {
	for &p in lp.points do if p.file == file && p.line == line do return &p
	return nil
}

// Whether any log point is on (the game is built from the copy with them)
LogPoints_Active :: proc(lp: ^LogPoints) -> bool {
	for p in lp.points do if p.enabled do return true
	return false
}

// What the running game's log points must be: a change builds it again
LogPoints_Signature :: proc(lp: ^LogPoints) -> u64 {
	h := hash.fnv64a(nil)
	for p in lp.points do if p.enabled {
		h = hash.fnv64a(transmute([]byte)fmt.tprintf("%s:%d:%s\n", p.file, p.line, p.expression), h)
	}
	return h
}

// Frees the list and the dialog
LogPoints_Clear :: proc(lp: ^LogPoints) {
	for &p in lp.points do logPointFree(&p)
	clear(&lp.points)
	logPointDialogFree(&lp.dialog)
}

// Frees everything (State_Destroy)
LogPoints_Destroy :: proc(lp: ^LogPoints) {
	LogPoints_Clear(lp)
	delete(lp.points)
	delete(lp.root)
	lp^ = {}
}

@(private="file")
logPointFree :: proc(p: ^LogPoint) {
	delete(p.file)
	delete(p.expression)
	delete(p.text)
	p^ = {}
}

@(private="file")
logPointDialogFree :: proc(d: ^LogPointDialog) {
	delete(d.file)
	delete(d.text)
	delete(d.expression)
	d^ = {}
}

/*
Moves log points to where their lines went in a file's text (lines added or removed above them):
the nearest line with the text they were set on, 200 lines either way. Ones whose line is gone
stay where they were.

Inputs:
- file: The script's file name ("hero.odin")
- text: Its text now

Returns:
- Whether any moved
*/
LogPoints_Relocate :: proc(lp: ^LogPoints, file, text: string) -> bool {
	lines := strings.split_lines(text, context.temp_allocator)
	moved := false
	for &p in lp.points {
		if p.file != file || p.text == "" do continue
		at := logPointLine(lines, p.line - 1, p.text)
		if at >= 0 && at + 1 != p.line {
			p.line = at + 1
			moved = true
		}
	}
	return moved
}

// The line (0-based) with a log point's text nearest to `line`; -1 none
@(private="file")
logPointLine :: proc(lines: []string, line: int, text: string) -> int {
	for d in 0 ..< 200 {
		for at in ([2]int{line - d, line + d}) {
			if at >= 0 && at < len(lines) && strings.trim_space(lines[at]) == text do return at
		}
		if line - d < 0 && line + d >= len(lines) do break
	}
	return -1
}

// --- where one can go -----------------------------------------------------------

/*
Whether a line can take a log point: inside a procedure (the index's procedures), and starting a
statement (not a `case` or `else` line, not continuing an expression from the line above, not
inside a literal).

Inputs:
- lines: The file's lines
- line: 0-based
- procs: The file's procedures (the index's; 1-based lines)

Returns:
- "" or why not
*/
LogPoint_Check :: proc(lines: []string, line: int, procs: []IndexProc) -> string {
	if line < 0 || line >= len(lines) do return "That line isn't in the file"
	inside := false
	for p in procs do if p.startLine - 1 < line && line < p.endLine - 1 do inside = true
	if !inside do return "Log points go on lines inside a procedure"
	text := strings.trim_space(lines[line])
	if strings.has_prefix(text, "case ") || strings.has_prefix(text, "case:") || text == "case" do return "A log point can't go on a case line: put it on the line below"
	if strings.has_prefix(text, "else") do return "A log point can't go on an else line: put it on the line below"
	if strings.has_prefix(text, "//") || strings.has_prefix(text, "/*") {
		// A comment line is fine (the statement goes before it)
	}
	// The line above: a statement continuing onto this one
	for above := line - 1; above >= 0; above -= 1 {
		prev := strings.trim_space(stripComment(lines[above]))
		if prev == "" do continue
		last := prev[len(prev) - 1]
		switch last {
		case ',', '(', '[', '+', '-', '*', '/', '|', '&', '=', '.', '\\', '%', '<', '>', '!', '~', '^':
			return "That line continues the statement above: put the log point on its first line"
		case '{':
			// A block opened, unless it's a literal (`x := Foo{`, `{` after `=`)
			before := strings.trim_space(prev[:len(prev) - 1])
			if strings.has_suffix(before, "=") || strings.has_suffix(before, "return") || (len(before) > 0 && isIdentChar(before[len(before) - 1]) && !blockOpener(before)) {
				return "That line is inside a literal: put the log point on a statement"
			}
		}
		break
	}
	return ""
}

// A line that opens a block with its `{` (`if x {`, `for ... {`, `proc(...) {`, `switch {`...)
@(private="file")
blockOpener :: proc(text: string) -> bool {
	first, _, _ := strings.partition(text, " ")
	switch first {
	case "if", "for", "switch", "when", "else", "defer", "do": return true
	}
	if strings.contains(text, "proc") || strings.has_suffix(text, ")") || strings.contains(text, "} else") do return true
	if strings.has_suffix(text, "struct") || strings.has_suffix(text, "union") || strings.has_suffix(text, "enum") do return true
	return false
}

@(private="file")
isIdentChar :: proc(c: u8) -> bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

// A line without its `//` comment (not inside a string)
@(private="file")
stripComment :: proc(text: string) -> string {
	quote: u8 = 0
	escaped := false
	for i in 0 ..< len(text) {
		c := text[i]
		if quote != 0 {
			if escaped do escaped = false
			else if c == '\\' && quote == '"' do escaped = true
			else if c == quote do quote = 0
			continue
		}
		if c == '"' || c == '`' || c == '\'' do quote = c
		if c == '/' && i + 1 < len(text) && text[i + 1] == '/' do return text[:i]
	}
	return text
}

// --- injecting them -------------------------------------------------------------

/*
The statement a log point puts before its line's code: an engine debug line in the "logpoint"
category with the file, the line and each expression's value (expressions split at top-level
commas).

Inputs:
- alias: The file's name for the engine (`e`)
- file: The script's file name
- line: 1-based
- expression: What to log (`self.hp`, `self.hp, delta`)

Returns:
- The statement, ending with "; " (temp allocated)

Example:
	// LogPoint_Statement("e", "hero.odin", 42, "self.hp") ==
	// `e.Log_Debug("hero.odin:42: self.hp = %v", self.hp, category = "logpoint"); `
*/
LogPoint_Statement :: proc(alias, file: string, line: int, expression: string) -> string {
	parts := LogPoint_SplitExpressions(expression)
	format := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&format, "%s:%d: ", file, line)
	for p, i in parts {
		if i > 0 do strings.write_string(&format, ", ")
		strings.write_string(&format, p)
		strings.write_string(&format, " = %v")
	}
	escaped := strings.builder_make(context.temp_allocator)
	text := strings.to_string(format)
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '"': strings.write_string(&escaped, `\"`)
		case '\\': strings.write_string(&escaped, `\\`)
		case '%':
			// Our own verbs stay; a % of the expression's text is doubled
			if strings.has_prefix(text[i:], "%v") && (i + 2 >= len(text) || text[i + 2] == ',' ) {
				strings.write_byte(&escaped, '%')
			} else {
				strings.write_string(&escaped, "%%")
			}
		case: strings.write_byte(&escaped, c)
		}
	}
	return fmt.tprintf(`%s.Log_Debug("%s", %s, category = "%s"); `, alias, strings.to_string(escaped), strings.join(parts, ", ", context.temp_allocator), LOG_POINT_CATEGORY)
}

/*
An expression list split at its top-level commas (not inside brackets or strings), each trimmed
(temp allocated).
*/
LogPoint_SplitExpressions :: proc(expression: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	depth := 0
	quote: u8 = 0
	escaped := false
	start := 0
	for i in 0 ..< len(expression) {
		c := expression[i]
		if quote != 0 {
			if escaped do escaped = false
			else if c == '\\' && quote == '"' do escaped = true
			else if c == quote do quote = 0
			continue
		}
		switch c {
		case '"', '`', '\'': quote = c
		case '(', '[', '{': depth += 1
		case ')', ']', '}': depth -= 1
		case ',':
			if depth == 0 {
				if part := strings.trim_space(expression[start:i]); part != "" do append(&out, part)
				start = i + 1
			}
		}
	}
	if part := strings.trim_space(expression[start:]); part != "" do append(&out, part)
	return out[:]
}

/*
A script's text with its log points in (on their lines, before the line's code: line numbers
don't change). Off ones and ones whose line is gone or refused are left out, said in `problems`.

Inputs:
- text: The script's text (the user's file is never written)
- file: Its file name ("hero.odin")
- points: The project's log points (only this file's are used)
- procs: The file's procedures (the index's), for LogPoint_Check

Returns:
- The text to build, and what was left out (temp allocated)
*/
LogPoint_Inject :: proc(text, file: string, points: []LogPoint, procs: []IndexProc) -> (out: string, problems: []string) {
	lines := strings.split_lines(text, context.temp_allocator)
	problemList := make([dynamic]string, context.temp_allocator)
	at := make(map[int]string, context.temp_allocator)
	alias := engineAliasIn(text)
	for p in points {
		if p.file != file || !p.enabled || p.expression == "" do continue
		line := p.text != "" ? logPointLine(lines, p.line - 1, p.text) : p.line - 1
		if line < 0 {
			append(&problemList, fmt.tprintf("%s:%d: the log point's line is gone (it logs nothing until set again)", file, p.line))
			continue
		}
		if why := LogPoint_Check(lines, line, procs); why != "" {
			append(&problemList, fmt.tprintf("%s:%d: %s", file, line + 1, why))
			continue
		}
		statement := LogPoint_Statement(alias != "" ? alias : LOG_POINT_ALIAS, file, line + 1, p.expression)
		at[line] = strings.concatenate({at[line], statement}, context.temp_allocator)
	}
	if len(at) == 0 do return text, problemList[:]
	b := strings.builder_make(context.temp_allocator)
	for l, i in lines {
		if i > 0 do strings.write_byte(&b, '\n')
		if statement, has := at[i]; has {
			indent := len(l) - len(strings.trim_left(l, " \t"))
			strings.write_string(&b, l[:indent])
			strings.write_string(&b, statement)
			strings.write_string(&b, l[indent:])
		} else {
			strings.write_string(&b, l)
		}
	}
	// No engine import: one at the end, so no line moves
	if alias == "" do fmt.sbprintf(&b, "\nimport %s \"engine:.\"\n", LOG_POINT_ALIAS)
	return strings.to_string(b), problemList[:]
}

// The engine's name in a file without its own import of it
LOG_POINT_ALIAS :: "__logpoint_engine"

// The name a file imports the engine as (`import e "engine:."`; "" none)
@(private="file")
engineAliasIn :: proc(text: string) -> string {
	for line in strings.split_lines(text, context.temp_allocator) {
		t := strings.trim_space(line)
		if !strings.has_prefix(t, "import ") || !strings.contains(t, `"engine:."`) do continue
		rest := strings.trim_space(t[len("import "):])
		if strings.has_prefix(rest, `"`) do return "crossfire"
		name, _, _ := strings.partition(rest, " ")
		return name
	}
	return ""
}

/*
Writes the scripts folder with the log points in it for a build: every .odin file of scripts/
into `<dir>/scripts`, those with log points injected (`LogPoint_Inject`); only files whose text
changed are written (the build's dates), and files no longer in scripts/ are removed.

Inputs:
- state: Editor state
- dir: The copy's root (the `logpoints` collection)

Returns:
- What was left out (temp allocated)
*/
LogPoints_WriteBuild :: proc(state: ^State, dir: string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	src := absolutePath(joinPath(state.project.rootPath, SCRIPTS_FOLDER, allocator = context.temp_allocator))
	dst, _ := filepath.join({dir, SCRIPTS_FOLDER}, context.temp_allocator)
	_ = os.make_directory_all(dst)
	entries, _ := os.read_all_directory_by_path(src, context.temp_allocator)
	names := make(map[string]bool, context.temp_allocator)
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") do continue
		names[entry.name] = true
		from, _ := filepath.join({src, entry.name}, context.temp_allocator)
		data, err := os.read_entire_file(from, context.temp_allocator)
		if err != nil do continue
		text := string(data)
		// The log points follow their lines in the saved text
		if LogPoints_Relocate(&state.logPoints, entry.name, text) do _ = LogPoints_Save(state)
		procs: []IndexProc
		if f := ScriptIndex_File(&state.scriptIndex, from); f != nil do procs = f.procs[:]
		if len(procs) == 0 {
			parsed := ScriptIndex_ParseSource(from, text, context.temp_allocator)
			procs = parsed.procs[:]
		}
		out, left := LogPoint_Inject(text, entry.name, state.logPoints.points[:], procs)
		append(&problems, ..left)
		to, _ := filepath.join({dst, entry.name}, context.temp_allocator)
		if old, readErr := os.read_entire_file(to, context.temp_allocator); readErr == nil && string(old) == out do continue
		_ = os.write_entire_file(to, transmute([]u8)out)
	}
	old, _ := os.read_all_directory_by_path(dst, context.temp_allocator)
	for entry in old do if entry.type == .Regular && !names[entry.name] {
		path, _ := filepath.join({dst, entry.name}, context.temp_allocator)
		_ = os.remove(path)
	}
	return problems[:]
}

/*
Where a project's player build keeps the scripts with log points in (the `logpoints`
collection: `<players>/<project>/logpoints`, absolute; temp allocated).
*/
LogPoints_BuildDir :: proc(state: ^State) -> string {
	projectDir := absolutePath(state.project.rootPath)
	dir, _ := filepath.join({PROJECT_PLAYERS_DIR, projectBuildFolder(projectDir), LOG_POINTS_BUILD}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	return absolutePath(dir)
}

// --- the providers ----------------------------------------------------------------

// The script's file name in scripts/ ("" when the document isn't one of the project's scripts)
@(private="file")
logPointFileOf :: proc(state: ^State, path: string) -> string {
	if !isProjectScript(state, path) do return ""
	return filepath.base(path)
}

// Log points as markers: a diamond (dim when off)
@(private)
logPointMarkers :: proc(doc: ce.Provider_Document, ctx: ce.Provider_Context, out: ^[dynamic]ce.Gutter_Marker) {
	state := codeProvidersState()
	file := logPointFileOf(state, doc.path)
	if file == "" do return
	for p in state.logPoints.points {
		if p.file != file do continue
		line := logPointBufferLine(doc, p)
		if line < 0 do continue
		choices := make([]string, 3, ctx.allocator)
		choices[0] = "Edit Log Point..."
		choices[1] = p.enabled ? "Turn Log Point Off" : "Turn Log Point On"
		choices[2] = "Remove Log Point"
		append(out, ce.Gutter_Marker{line = line, icon = .Diamond, color = p.enabled ? {230, 140, 40, 255} : {130, 130, 130, 255},
			tooltip = fmt.aprintf("Log point%s: %s (a click: edit, turn off, remove)", p.enabled ? "" : " (off)", p.expression, allocator = ctx.allocator),
			id = p.line, choices = choices})
	}
}

// A log point's line in a buffer (moved with its text; -1 when it's gone)
@(private="file")
logPointBufferLine :: proc(doc: ce.Provider_Document, p: LogPoint) -> int {
	count := cebuf.buffer_line_count(doc.buffer)
	if p.text == "" do return p.line - 1 < count ? p.line - 1 : -1
	for d in 0 ..< 200 {
		for at in ([2]int{p.line - 1 - d, p.line - 1 + d}) {
			if at >= 0 && at < count && strings.trim_space(cebuf.buffer_line_str(doc.buffer, at)) == p.text do return at
		}
	}
	return -1
}

// Their expressions after their lines
@(private)
logPointInlays :: proc(doc: ce.Provider_Document, ctx: ce.Provider_Context, out: ^[dynamic]ce.Inlay_Hint) {
	state := codeProvidersState()
	file := logPointFileOf(state, doc.path)
	if file == "" do return
	for p in state.logPoints.points {
		if p.file != file do continue
		line := logPointBufferLine(doc, p)
		if line < 0 do continue
		label := fmt.aprintf("◆ log %s%s", p.expression, p.enabled ? "" : " (off)", allocator = ctx.allocator)
		append(out, ce.Inlay_Hint{pos = {line, len(cebuf.buffer_line_str(doc.buffer, line))}, label = label, kind = .Parameter})
	}
}

// A log point marker's choice: edit, turn off or on, remove
@(private)
logPointMarkerClicked :: proc(doc: ce.Provider_Document, marker: ce.Gutter_Marker, userData: rawptr) {
	state := codeProvidersState()
	file := logPointFileOf(state, doc.path)
	if file == "" do return
	ops := [3]LogPointOp{.Edit, .Toggle, .Remove}
	logPointsLeft.command = Log_Point_Command{file = strings.clone(file), line = marker.id, op = ops[clamp(marker.choice, 0, 2)]}
}

// A click in the marker column of a line without a marker: a new log point there
@(private)
logPointGutterLine :: proc(doc: ce.Provider_Document, line: int, userData: rawptr) -> bool {
	state := codeProvidersState()
	file := logPointFileOf(state, doc.path)
	if file == "" do return false
	return logPointAsk(state, doc, file, line)
}

// The right-click menu: Add Log Point... (or Edit / Remove on one) on a procedure's line
@(private)
logPointMenuItems :: proc(doc: ce.Provider_Document, pos: cebuf.Position, ctx: ce.Provider_Context, out: ^[dynamic]string) {
	state := codeProvidersState()
	file := logPointFileOf(state, doc.path)
	if file == "" do return
	if p := logPointAt(state, doc, file, pos.line); p != nil {
		append(out, "Edit Log Point...", p.enabled ? "Turn Log Point Off" : "Turn Log Point On", "Remove Log Point")
		return
	}
	if logPointWhyNot(state, doc, file, pos.line) == "" do append(out, "Add Log Point...")
}

@(private)
logPointMenuPicked :: proc(doc: ce.Provider_Document, pos: cebuf.Position, index: int, userData: rawptr) {
	state := codeProvidersState()
	file := logPointFileOf(state, doc.path)
	if file == "" do return
	if p := logPointAt(state, doc, file, pos.line); p != nil {
		ops := [3]LogPointOp{.Edit, .Toggle, .Remove}
		logPointsLeft.command = Log_Point_Command{file = strings.clone(file), line = p.line, op = ops[clamp(index, 0, 2)]}
		return
	}
	_ = logPointAsk(state, doc, file, pos.line)
}

// The log point shown on a buffer's line (nil none)
@(private="file")
logPointAt :: proc(state: ^State, doc: ce.Provider_Document, file: string, line: int) -> ^LogPoint {
	for &p in state.logPoints.points do if p.file == file && logPointBufferLine(doc, p) == line do return &p
	return nil
}

// Why a buffer's line can't take a log point ("" it can)
@(private="file")
logPointWhyNot :: proc(state: ^State, doc: ce.Provider_Document, file: string, line: int) -> string {
	count := cebuf.buffer_line_count(doc.buffer)
	lines := make([]string, count, context.temp_allocator)
	for i in 0 ..< count do lines[i] = cebuf.buffer_line_str(doc.buffer, i)
	procs: []IndexProc
	if f := ScriptIndex_File(&state.scriptIndex, absolutePath(doc.path)); f != nil do procs = f.procs[:]
	return LogPoint_Check(lines, line, procs)
}

// Opens the dialog for a line (leaves it for the view), or says why it can't take one
@(private="file")
logPointAsk :: proc(state: ^State, doc: ce.Provider_Document, file: string, line: int) -> bool {
	if why := logPointWhyNot(state, doc, file, line); why != "" {
		delete(logPointsLeft.refused)
		logPointsLeft.refused = strings.clone(why)
		return true
	}
	text := strings.trim_space(cebuf.buffer_line_str(doc.buffer, line))
	logPointsLeft.open = Log_Point_Dialog_Opened{strings.clone(file), line + 1, strings.clone(text)}
	return true
}

// What the providers left, sent by the code view
LogPoints_Take :: proc(ctx: ^skald.Ctx(Msg)) {
	for m in LogPoints_Messages() do skald.send(ctx, m)
}

/*
What the log point providers left (the dialog to open, a marker's command, a refusal) as
messages, once: the code view sends them; tests take them.

Returns:
- The messages (strings temp allocated)
*/
LogPoints_Messages :: proc() -> []Msg {
	out := make([dynamic]Msg, context.temp_allocator)
	if o, ok := logPointsLeft.open.?; ok {
		append(&out, Msg(Log_Point_Dialog_Opened{strings.clone(o.file, context.temp_allocator), o.line, strings.clone(o.text, context.temp_allocator)}))
		delete(o.file)
		delete(o.text)
		logPointsLeft.open = nil
	}
	if c, ok := logPointsLeft.command.?; ok {
		append(&out, Msg(Log_Point_Command{strings.clone(c.file, context.temp_allocator), c.line, c.op}))
		delete(c.file)
		logPointsLeft.command = nil
	}
	if logPointsLeft.refused != "" {
		append(&out, Msg(Log_Point_Refused(strings.clone(logPointsLeft.refused, context.temp_allocator))))
		delete(logPointsLeft.refused)
		logPointsLeft.refused = ""
	}
	return out[:]
}

// Frees the package state (tests, quitting)
LogPoints_Shutdown :: proc() {
	if o, ok := logPointsLeft.open.?; ok { delete(o.file); delete(o.text) }
	if c, ok := logPointsLeft.command.?; ok do delete(c.file)
	delete(logPointsLeft.refused)
	logPointsLeft = {}
}

// --- the messages ---------------------------------------------------------------

/*
The log points' messages: the dialog (open, typed, OK, Remove, Cancel), a marker's commands, a
refusal.

Returns:
- Whether `m` was one of them
*/
LogPoints_Update :: proc(state: ^State, m: Msg) -> bool {
	lp := &state.logPoints
	d := &lp.dialog
	#partial switch v in m {
	case Log_Point_Dialog_Opened:
		logPointDialogFree(d)
		existing := LogPoints_Find(lp, v.file, v.line)
		d^ = {open = true, file = strings.clone(v.file), line = v.line, text = strings.clone(v.text), existing = existing != nil,
			expression = strings.clone(existing != nil ? existing.expression : "")}
	case Log_Point_Expression_Changed:
		delete(d.expression)
		d.expression = strings.clone(string(v))
	case Log_Point_Cancelled:
		logPointDialogFree(d)
	case Log_Point_Saved:
		expression := strings.trim_space(d.expression)
		if expression == "" {
			logLine(state, .Warning, fmt.aprintf("Log point: say what to log (an expression, or several with commas)"))
			break
		}
		if p := LogPoints_Find(lp, d.file, d.line); p != nil {
			delete(p.expression)
			p.expression = strings.clone(expression)
			p.enabled = true
		} else {
			append(&lp.points, LogPoint{file = strings.clone(d.file), line = d.line, expression = strings.clone(expression), enabled = true, text = strings.clone(d.text)})
		}
		logLine(state, .Info, fmt.aprintf("Log point on line %d of %s: %s%s", d.line, d.file, expression, logPointApplies(state)))
		logPointDialogFree(d)
		logPointsChanged(state)
	case Log_Point_Command:
		p := LogPoints_Find(lp, v.file, v.line)
		if p == nil do break
		switch v.op {
		case .Edit:
			logPointDialogFree(d)
			d^ = {open = true, file = strings.clone(p.file), line = p.line, text = strings.clone(p.text), expression = strings.clone(p.expression), existing = true}
			return true
		case .Toggle:
			p.enabled = !p.enabled
			logLine(state, .Info, fmt.aprintf("Log point on line %d of %s %s%s", p.line, p.file, p.enabled ? "on" : "off", logPointApplies(state)))
		case .Remove:
			logLine(state, .Info, fmt.aprintf("Log point on line %d of %s removed%s", p.line, p.file, logPointApplies(state)))
			for &q, i in lp.points do if &q == p {
				logPointFree(&q)
				ordered_remove(&lp.points, i)
				break
			}
			if d.open && d.file == v.file && d.line == v.line do logPointDialogFree(d)
		}
		logPointsChanged(state)
	case Log_Point_Refused:
		logLine(state, .Info, fmt.aprintf("Log point: %s", string(v)))
	case:
		return false
	}
	return true
}

// When a change reaches the game ("" when it's on its way; temp allocated)
@(private="file")
logPointApplies :: proc(state: ^State) -> string {
	if state.playState == .Stopped do return " (from the next Play)"
	if !state.settings.hotReload do return " (from the next Play: hot reload is off)"
	return " (the game is built again with it: hot reload)"
}

// Saved, and the code tabs' markers asked again
@(private="file")
logPointsChanged :: proc(state: ^State) {
	lp := &state.logPoints
	lp.generation += 1
	if message := LogPoints_Save(state); message != "" do logLine(state, .Warning, strings.clone(message))
}

/*
The Log Point dialog: the line, the expression (`logpoint-expression`), OK (`logpoint-ok`),
Remove (`logpoint-remove`, for one that's there) and Cancel (`logpoint-cancel`).
*/
LogPointDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	d := &s.logPoints.dialog
	if !d.open do return closedDialog(ctx, "logpoint-dialog")
	th := ctx.theme
	buttons := make([dynamic]skald.View, context.temp_allocator)
	append(&buttons, skald.flex(1, skald.spacer(0)))
	if d.existing do append(&buttons, skald.button(ctx, "Remove", Msg(Log_Point_Command{strings.clone(d.file, context.temp_allocator), d.line, .Remove}), id = skald.hash_id("logpoint-remove"), bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm))
	append(&buttons, skald.button(ctx, "Cancel", Msg(Log_Point_Cancelled{}), id = skald.hash_id("logpoint-cancel"), bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm))
	append(&buttons, skald.button(ctx, "OK", Msg(Log_Point_Saved{}), id = skald.hash_id("logpoint-ok"), font_size = th.font.size_sm))
	return skald.dialog(ctx,
		open = true,
		on_dismiss = proc() -> Msg { return Log_Point_Cancelled{} },
		content = skald.col(
			uiText(th, .Title, "Log Point"),
			uiText(th, .Muted, fmt.tprintf("%s, line %d: %s", d.file, d.line, d.text), max_width = tk.textDialog),
			uiText(th, .Value, "Log"),
			skald.text_input(ctx, strings.clone(d.expression, context.temp_allocator), proc(v: string) -> Msg { return Log_Point_Expression_Changed(v) }, id = skald.hash_id("logpoint-expression"), width = tk.dialogS),
			uiText(th, .Muted, "An expression, or several with commas (self.hp, delta). It's logged each time the line is reached, before it runs, in the Console's logpoint category. The script isn't changed: the game is built with it (hot reload while it plays).", max_width = tk.textDialog),
			skald.row(..buttons[:], spacing = th.spacing.sm),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("logpoint-dialog"),
		width = tk.dialogM,
	)
}

/*
Turns a log point build's paths back into the project's in a line of build output (the copy's
scripts folder is the project's, line for line).

Inputs:
- state: Editor state
- line: A line of the build's output

Returns:
- The line (temp allocated, or `line` itself)
*/
LogPoints_ProjectPaths :: proc(state: ^State, line: string) -> string {
	if !LogPoints_Active(&state.logPoints) do return line
	copy, _ := filepath.join({LogPoints_BuildDir(state), SCRIPTS_FOLDER}, context.temp_allocator)
	if !strings.contains(line, copy) do return line
	real := absolutePath(joinPath(state.project.rootPath, SCRIPTS_FOLDER, allocator = context.temp_allocator))
	out, _ := strings.replace_all(line, copy, real, context.temp_allocator)
	return out
}
