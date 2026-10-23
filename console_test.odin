package crossfire_editor

import "core:fmt"
import "core:strings"
import "core:testing"
import e "engine:."

// The Console and Output tabs' lines (console.odin): categories, the history limit, filters,
// following, the game's lines read with their category and level, the menus' commands

@(private="file")
consoleState :: proc() -> State {
	return State{
		project = Project_CreateTestProject("unused"),
		browserSelection = {kind = .None},
		selectedNode = -1,
		busSelection = -1,
		settings = Settings_Default(),
	}
}

@(private="file")
send :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
log_lists_keep_categories_and_a_limit :: proc(t: ^testing.T) {
	list: LogList
	defer LogList_Destroy(&list)
	LogList_Append(&list, .Info, "engine", strings.clone("Playing"), 0)
	LogList_Append(&list, .Warning, "player", strings.clone("Low health"), 0)
	LogList_Append(&list, .Info, "", strings.clone("plain"), 0)
	testing.expect_value(t, len(list.categories), 3)
	testing.expect_value(t, list.categories[2].name, e.LOG_DEFAULT_CATEGORY)
	testing.expect_value(t, LogList_CategoryName(&list, LogList_Lines(&list)[1]), "player")
	testing.expect_value(t, list.counts[.Warning], 1)

	// Past the limit the oldest go; counts and serial numbers follow
	for i in 0..<100 do LogList_Append(&list, i % 2 == 0 ? .Error : .Debug, "spam", fmt.aprintf("spam %d", i), 10)
	lines := LogList_Lines(&list)
	testing.expect_value(t, len(lines), 10)
	testing.expect_value(t, lines[0].text, "spam 90")
	testing.expect_value(t, lines[9].text, "spam 99")
	testing.expect_value(t, list.serial, 93)
	testing.expect_value(t, list.counts[.Error] + list.counts[.Debug], 10)
	testing.expect_value(t, list.counts[.Info], 0)
	testing.expect_value(t, list.categories[0].count, 0)
	testing.expect_value(t, list.categories[3].count, 10)
	// Compacted as it goes: the array doesn't grow with everything ever logged
	testing.expect(t, len(list.lines) < 25, "compacted")

	// A lower limit at once; clearing keeps the categories (the menu lists them)
	LogList_Trim(&list, 4)
	testing.expect_value(t, len(LogList_Lines(&list)), 4)
	testing.expect_value(t, LogList_Lines(&list)[0].text, "spam 96")
	LogList_Clear(&list)
	testing.expect_value(t, len(LogList_Lines(&list)), 0)
	testing.expect_value(t, len(list.categories), 4)
	testing.expect_value(t, list.serial, 103)
	testing.expect_value(t, list.counts, [LogLevel]int{})
}

@(test)
log_filters_by_level_category_and_text :: proc(t: ^testing.T) {
	list: LogList
	defer LogList_Destroy(&list)
	LogList_Append(&list, .Info, "engine", strings.clone("Playing 'Asteroids'"), 0)
	LogList_Append(&list, .Warning, "player", strings.clone("Low HEALTH: 12"), 0)
	LogList_Append(&list, .Error, "SDL", strings.clone("No audio device"), 0)
	LogList_Append(&list, .Debug, "player", strings.clone("health 12"), 0)
	testing.expect(t, !LogList_Filtered(&list), "nothing filtered")
	testing.expect_value(t, len(LogList_Shown(&list)), 4)

	list.hiddenLevels = {.Debug}
	testing.expect(t, LogList_Filtered(&list), "a level hidden")
	testing.expect_value(t, len(LogList_Shown(&list)), 3)
	list.categories[LogList_Category(&list, "player")].hidden = true
	shown := LogList_Shown(&list)
	testing.expect(t, len(shown) == 2 && shown[0] == 0 && shown[1] == 2, "engine and SDL")

	// Search: any case, with the other filters
	list.hiddenLevels = {}
	list.categories[LogList_Category(&list, "player")].hidden = false
	list.search = strings.clone("health")
	shown = LogList_Shown(&list)
	testing.expect(t, len(shown) == 2 && shown[0] == 1 && shown[1] == 3, "both health lines")
	list.hiddenLevels = {.Warning}
	shown = LogList_Shown(&list)
	testing.expect(t, len(shown) == 1 && shown[0] == 3, "the debug one")
}

@(test)
game_lines_arrive_with_category_and_level :: proc(t: ^testing.T) {
	// The engine's logger
	text, level, category := parseLogLine(e.Log_FormatLine(.Warning, "player", "Low health", context.temp_allocator))
	testing.expect(t, text == "Low health" && level == .Warning && category == "player", text)
	text, level, category = parseLogLine("[DEBUG] [SDL] Created renderer")
	testing.expect(t, text == "Created renderer" && level == .Debug && category == "SDL", text)
	// Odin's console logger: no category
	text, level, category = parseLogLine("[WARN ] --- [2026-10-15 18:17:10] [main.odin:45:run()] message")
	testing.expect(t, strings.has_suffix(text, "] message") && !strings.contains(text, "2026") && level == .Warning && category == "", text)
	// A compiler error and a plain print
	_, level, category = parseLogLine("hero.odin(3:1) Error: Undeclared name")
	testing.expect(t, level == .Error && category == "", "compiler error")
	text, level, category = parseLogLine("hello")
	testing.expect(t, text == "hello" && level == .Info && category == "", text)
}

@(test)
console_messages_filter_follow_and_copy :: proc(t: ^testing.T) {
	state := consoleState()
	defer State_Destroy(&state)
	state.settings.consoleLimit = 50
	logLine(&state, .Info, strings.clone("Opened"), echo = false)
	send(&state, Log_Test_Lines{count = 3, level = .Warning, category = "player"})
	send(&state, Log_Test_Lines{count = 2, level = .Error, category = "ai"})
	console := &state.console
	testing.expect_value(t, len(LogList_Lines(console)), 6)
	testing.expect_value(t, LogList_CategoryName(console, LogList_Lines(console)[0]), LOG_EDITOR_CATEGORY)

	// Levels and search
	send(&state, Log_Level_Toggled{false, .Warning})
	testing.expect_value(t, len(LogList_Shown(console)), 3)
	send(&state, Log_Level_Toggled{false, .Warning})
	send(&state, Log_Search_Changed{false, "AI LINE"})
	testing.expect_value(t, len(LogList_Shown(console)), 2)
	testing.expect_value(t, console.search, "AI LINE")
	send(&state, Log_Search_Changed{false, ""})

	// The category menu stays open while several are picked; a click elsewhere closes it
	send(&state, Context_Menu_Opened{at = {10, 10}, target = Ctx_Log_Categories{false}})
	items := ContextMenu_Items(&state)
	testing.expect(t, len(items) == 5 && items[0].disabled, "Show All (disabled), a separator, three categories")
	testing.expect(t, items[3].checked && strings.has_prefix(items[3].label, "player (3)"), items[3].label)
	player := LogList_Category(console, "player")
	send(&state, Log_Category_Toggled{false, player})
	send(&state, Context_Menu_Closed{})
	testing.expect(t, state.contextMenu.open, "still open after a pick")
	testing.expect(t, console.categories[player].hidden, "player hidden")
	send(&state, Log_Category_Toggled{false, LogList_Category(console, "ai")})
	send(&state, Context_Menu_Closed{})
	testing.expect_value(t, len(LogList_Shown(console)), 1)
	send(&state, Context_Menu_Closed{})
	testing.expect(t, !state.contextMenu.open, "closed")
	send(&state, Log_Categories_Shown{false})
	send(&state, Context_Menu_Closed{})
	send(&state, Context_Menu_Closed{})
	testing.expect_value(t, len(LogList_Shown(console)), 6)

	// A line's menu: its category alone, hidden, everything again
	aiLine := console.serial + 4
	send(&state, Log_Command{.Only_Category, false, aiLine})
	testing.expect_value(t, len(LogList_Shown(console)), 2)
	send(&state, Log_Filters_Cleared{false})
	send(&state, Log_Command{.Hide_Category, false, aiLine})
	testing.expect_value(t, len(LogList_Shown(console)), 4)
	send(&state, Log_Filters_Cleared{false})
	testing.expect(t, !LogList_Filtered(console), "cleared")

	// Following: on by default, toggled, set by the view's scrolling
	testing.expect(t, !console.paused, "follows by default")
	send(&state, Log_Follow_Toggled{false})
	testing.expect(t, console.paused, "paused")
	send(&state, Log_Follow_Set{false, true})
	testing.expect(t, !console.paused, "resumed")

	// The limit: the oldest go, and a menu opened on a line still finds it by its serial number
	send(&state, Log_Test_Lines{count = 60, level = .Info, category = "spam"})
	testing.expect_value(t, len(LogList_Lines(console)), 50)
	first := console.serial
	testing.expect_value(t, LogList_Lines(console)[0].text, fmt.tprintf("spam line %d", first))
	send(&state, Log_Test_Lines{count = 5, level = .Info, category = "spam"})
	testing.expect_value(t, console.serial, first + 5)

	// A lower limit in Settings applies at once
	send(&state, Action.Open_Settings)
	send(&state, Settings_Value_Changed{.Console_Limit, 20})
	testing.expect_value(t, state.settingsDialog.draft.consoleLimit, SETTINGS_CONSOLE_LIMIT_RANGE[0])
	state.settingsDialog.draft.consoleLimit = 20
	send(&state, Settings_Applied{close = true})
	testing.expect_value(t, len(LogList_Lines(console)), 20)
}

@(test)
console_limit_setting_defaults_and_saves :: proc(t: ^testing.T) {
	defaults := Settings_Default()
	testing.expect_value(t, defaults.consoleLimit, 5000)
	text := Settings_ToINI(&defaults)
	testing.expect(t, strings.contains(text, "console_limit = 5000"), "written")
	testing.expect(t, fieldTip("Console lines kept") != "", "the setting has a tooltip")
}
