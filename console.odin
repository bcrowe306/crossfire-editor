package crossfire_editor

import "core:fmt"
import "core:strings"
import e "engine:."

/*
The Console's and the Output tab's lines (`LogList`: `State.console`, `State.output`) and their
filters.

Every line has a level (`LogLevel`, the engine's: Debug, Info, Warning, Error) and a category:
the running game's come with theirs (the engine's logger writes `[LEVEL] [category] text`, read
back by `parseLogLine` with `e.Log_ParseLine`: "engine", "SDL", "game" or a script's own);
the editor's own messages are "editor", plugins' "plugin", builds' "build" and exports' "export".
A list keeps the categories it has seen (`LogList.categories`, in the order they first came; a
line holds its category's index), even after it's cleared.

- **History limit:** a list keeps the newest `Settings.consoleLimit` lines (Settings > Editor >
  Console lines kept), dropping the oldest. The kept lines are `lines[start:]`
  (`LogList_Lines`): dropping one moves `start`, and the array is compacted once `start` passes
  half of it, so a full list costs no more per line than an empty one.
- **Filters:** levels and categories can be hidden, and `search` keeps the lines containing it
  (any case). `LogList_Shown` lists the lines that pass, which is all the view builds rows for
  (a `virtual_list`: only the visible ones become widgets).
- **Following:** `paused` false (the zero value) keeps the newest line in view. Scrolling up
  pauses it, scrolling back to the end resumes it (the view sees the scroll and sends
  `Log_Follow_Set`), and the header's toggle flips it (`Log_Follow_Toggled`).

None of this is undoable: it's the editor's view, not the project.
*/

// The category of the editor's own messages
LOG_EDITOR_CATEGORY :: "editor"
// The category of plugins' messages (plugin_host.odin)
LOG_PLUGIN_CATEGORY :: "plugin"
// The category of build output (the Output tab: Play's and hot reload's builds)
LOG_BUILD_CATEGORY :: "build"
// The category of exports' output (the Output tab)
LOG_EXPORT_CATEGORY :: "export"

// The engine's levels: Debug, Info, Warning, Error
LogLevel :: e.LogLevel

// One line of the Console or the Output tab
LogLine :: struct {
	level: LogLevel,
	// Index into its list's `categories`
	category: int,
	// The text (owned by the list)
	text: string,
}

// A category a list has seen
LogCategory :: struct {
	// Its name (owned)
	name: string,
	// Its lines are filtered out
	hidden: bool,
	// Lines of it kept now
	count: int,
}

// The lines of the Console or the Output tab, with their filters
LogList :: struct {
	// The kept lines are `lines[start:]` (`LogList_Lines`)
	lines: [dynamic]LogLine,
	start: int,
	// How many lines came before the first kept one (dropped or cleared): a line's serial
	// number is `serial + its index`
	serial: int,
	// Every category seen, in the order they first came
	categories: [dynamic]LogCategory,
	// Lines kept per level
	counts: [LogLevel]int,
	// Levels filtered out
	hiddenLevels: bit_set[LogLevel],
	// Only lines containing this text, in any case ("": all; owned)
	search: string,
	// Not following the newest line (the user scrolled up or turned it off)
	paused: bool,
}

/*
The lines a list keeps, oldest first.

Inputs:
- list: The list

Returns:
- Its lines (the list's own memory: valid until it changes)
*/
LogList_Lines :: proc(list: ^LogList) -> []LogLine {
	return list.lines[list.start:]
}

/*
A category's index in the list, added if it's new.

Inputs:
- list: The list
- name: The category ("" counts as the engine's default, "game")

Returns:
- Its index in `list.categories`
*/
LogList_Category :: proc(list: ^LogList, name: string) -> int {
	name := name == "" ? e.LOG_DEFAULT_CATEGORY : name
	for c, i in list.categories do if c.name == name do return i
	append(&list.categories, LogCategory{name = strings.clone(name)})
	return len(list.categories) - 1
}

/*
The name of a line's category.

Inputs:
- list: The line's list
- line: The line

Returns:
- The name (the list's memory)
*/
LogList_CategoryName :: proc(list: ^LogList, line: LogLine) -> string {
	return line.category >= 0 && line.category < len(list.categories) ? list.categories[line.category].name : ""
}

/*
Adds a line, then drops the oldest lines past `limit`.

Inputs:
- list: The list
- level: The line's level
- category: Its category's name
- text: Its text, heap-allocated: the list owns it from now on
- limit: Lines kept at most (0 or less: no limit)
*/
LogList_Append :: proc(list: ^LogList, level: LogLevel, category: string, text: string, limit: int) {
	index := LogList_Category(list, category)
	append(&list.lines, LogLine{level = level, category = index, text = text})
	list.counts[level] += 1
	list.categories[index].count += 1
	if limit > 0 do LogList_Trim(list, limit)
}

/*
Drops the oldest lines until at most `limit` are left (a lower Settings limit applies at once).

Inputs:
- list: The list
- limit: Lines kept at most (0 or less: no limit)
*/
LogList_Trim :: proc(list: ^LogList, limit: int) {
	if limit <= 0 do return
	for len(list.lines) - list.start > limit {
		line := list.lines[list.start]
		list.counts[line.level] -= 1
		if line.category >= 0 && line.category < len(list.categories) do list.categories[line.category].count -= 1
		delete(line.text)
		list.start += 1
		list.serial += 1
	}
	// Compact once the dropped part is half the array: each line moves about once
	if list.start > 0 && list.start * 2 >= len(list.lines) {
		remove_range(&list.lines, 0, list.start)
		list.start = 0
	}
}

/*
Removes every line. The categories stay (the filter's menu still lists them), with no lines.

Inputs:
- list: The list
*/
LogList_Clear :: proc(list: ^LogList) {
	for line in LogList_Lines(list) do delete(line.text)
	list.serial += len(list.lines) - list.start
	clear(&list.lines)
	list.start = 0
	list.counts = {}
	for &c in list.categories do c.count = 0
}

/*
Frees a list: its lines, categories and search.

Inputs:
- list: The list
*/
LogList_Destroy :: proc(list: ^LogList) {
	for line in LogList_Lines(list) do delete(line.text)
	delete(list.lines)
	for c in list.categories do delete(c.name)
	delete(list.categories)
	delete(list.search)
	list^ = {}
}

/*
Whether any filter is on (a hidden level or category, or a search).

Inputs:
- list: The list

Returns:
- true if some lines may be filtered out
*/
LogList_Filtered :: proc(list: ^LogList) -> bool {
	if list.hiddenLevels != {} || list.search != "" do return true
	for c in list.categories do if c.hidden do return true
	return false
}

/*
The lines that pass the filters, as indexes into `LogList_Lines`.

Inputs:
- list: The list
- allocator: Allocates the result

Returns:
- The indexes, oldest first
*/
LogList_Shown :: proc(list: ^LogList, allocator := context.temp_allocator) -> []int {
	lines := LogList_Lines(list)
	shown := make([dynamic]int, 0, len(lines), allocator)
	hidden := make([]bool, len(list.categories), context.temp_allocator)
	for c, i in list.categories do hidden[i] = c.hidden
	search := strings.to_lower(list.search, context.temp_allocator)
	for line, i in lines {
		if line.level in list.hiddenLevels do continue
		if line.category >= 0 && line.category < len(hidden) && hidden[line.category] do continue
		if search != "" && !containsFold(line.text, search) do continue
		append(&shown, i)
	}
	return shown[:]
}

// Whether `text` contains `lower` (already lower case), ignoring ASCII case
@(private="file")
containsFold :: proc(text, lower: string) -> bool {
	n := len(lower)
	if n == 0 do return true
	first := lower[0]
	for i := 0; i + n <= len(text); i += 1 {
		c := text[i]
		if c >= 'A' && c <= 'Z' do c += 'a' - 'A'
		if c != first do continue
		match := true
		for j in 1..<n {
			d := text[i + j]
			if d >= 'A' && d <= 'Z' do d += 'a' - 'A'
			if d != lower[j] {
				match = false
				break
			}
		}
		if match do return true
	}
	return false
}

// The Console's list, or the Output tab's
@(private="package")
logListOf :: proc(state: ^State, output: bool) -> ^LogList {
	return output ? &state.output : &state.console
}

/*
The Console's and Output tab's messages: following, the level and category filters, the search.

Inputs:
- state: The editor state
- m: The message

Returns:
- Whether it was one of them
*/
Console_Update :: proc(state: ^State, m: Msg) -> bool {
	#partial switch v in m {
	case Log_Follow_Toggled:
		list := logListOf(state, v.output)
		list.paused = !list.paused
	case Log_Follow_Set:
		logListOf(state, v.output).paused = !v.follow
	case Log_Level_Toggled:
		list := logListOf(state, v.output)
		list.hiddenLevels ~= {v.level}
	case Log_Category_Toggled:
		list := logListOf(state, v.output)
		if v.category >= 0 && v.category < len(list.categories) do list.categories[v.category].hidden = !list.categories[v.category].hidden
		// Several can be picked in a row: the menu stays open
		state.contextMenu.keepOpen = true
	case Log_Categories_Shown:
		list := logListOf(state, v.output)
		for &c in list.categories do c.hidden = false
		state.contextMenu.keepOpen = true
	case Log_Search_Changed:
		list := logListOf(state, v.output)
		delete(list.search)
		list.search = strings.clone(v.text)
	case Log_Test_Lines:
		for _ in 0..<v.count {
			logLine(state, v.level, fmt.aprintf("%s line %d", v.category, state.console.serial + len(LogList_Lines(&state.console))), echo = false, category = v.category)
		}
	case Log_Filters_Cleared:
		list := logListOf(state, v.output)
		list.hiddenLevels = {}
		for &c in list.categories do c.hidden = false
		delete(list.search)
		list.search = ""
	case:
		return false
	}
	return true
}
