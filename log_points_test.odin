package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Lines (1-based): 8 the proc, 9 `self.hp -= amount`, 10 `if self.hp < 0 {`, 11 `self.hp = 0`,
// 13 `switch amount {`, 14 `case 1:`, 17 `x := Hit{`, 18 `a = 1,`, 20 `total := amount +`, 21 `1`
@(private="file")
LOG_POINT_SOURCE :: `package scripts

import e "engine:."

Hero :: struct { using script: e.Script, hp: int }
Hit :: struct { a: int }

hurt :: proc(self: ^Hero, amount: int) {
	self.hp -= amount
	if self.hp < 0 {
		self.hp = 0
	}
	switch amount {
	case 1:
		self.hp += 0
	}
	x := Hit{
		a = 1,
	}
	total := amount +
		1
	_, _ = x, total
}
`

@(private="file")
logPointProcs :: proc(text: string) -> []IndexProc {
	f := ScriptIndex_ParseSource("hero.odin", text, context.temp_allocator)
	return f.procs[:]
}

// The statement a log point puts before its line, its expressions split, its text escaped
@(test)
log_point_statements :: proc(t: ^testing.T) {
	testing.expect_value(t, LogPoint_Statement("e", "hero.odin", 42, "self.hp"), `e.Log_Debug("hero.odin:42: self.hp = %v", self.hp, category = "logpoint"); `)
	testing.expect_value(t, LogPoint_Statement("e", "hero.odin", 3, "self.hp, f(a, b), \"x, y\""), `e.Log_Debug("hero.odin:3: self.hp = %v, f(a, b) = %v, \"x, y\" = %v", self.hp, f(a, b), "x, y", category = "logpoint"); `)
	testing.expect_value(t, LogPoint_Statement("e", "a.odin", 1, "n % 2"), `e.Log_Debug("a.odin:1: n %% 2 = %v", n % 2, category = "logpoint"); `)
	parts := LogPoint_SplitExpressions(" a ,b[1, 2], {c, d} ,")
	testing.expect_value(t, len(parts), 3)
	if len(parts) == 3 do testing.expect(t, parts[0] == "a" && parts[1] == "b[1, 2]" && parts[2] == "{c, d}", "split at the top level")
	free_all(context.temp_allocator)
}

// Where one can go: inside a procedure, starting a statement
@(test)
log_point_lines :: proc(t: ^testing.T) {
	lines := strings.split_lines(LOG_POINT_SOURCE, context.temp_allocator)
	procs := logPointProcs(LOG_POINT_SOURCE)
	ok :: proc(t: ^testing.T, lines: []string, procs: []IndexProc, line: int) {
		why := LogPoint_Check(lines, line - 1, procs)
		testing.expectf(t, why == "", "line %d (%q) takes one: %s", line, lines[line - 1], why)
	}
	refused :: proc(t: ^testing.T, lines: []string, procs: []IndexProc, line: int, reason: string) {
		why := LogPoint_Check(lines, line - 1, procs)
		testing.expectf(t, strings.contains(why, reason), "line %d (%q): %q, wanted %q", line, lines[line - 1], why, reason)
	}
	ok(t, lines, procs, 9)
	ok(t, lines, procs, 10)
	ok(t, lines, procs, 11)
	ok(t, lines, procs, 15)
	ok(t, lines, procs, 17)
	refused(t, lines, procs, 5, "inside a procedure")
	refused(t, lines, procs, 8, "inside a procedure")
	refused(t, lines, procs, 14, "case line")
	refused(t, lines, procs, 18, "inside a literal")
	refused(t, lines, procs, 21, "continues the statement above")
	free_all(context.temp_allocator)
}

// Injected on their lines (no line moves), following lines added above, skipped when off, gone or
// refused; a file without the engine imported gets an import at its end
@(test)
log_point_injection :: proc(t: ^testing.T) {
	procs := logPointProcs(LOG_POINT_SOURCE)
	points := []LogPoint{
		{file = "hero.odin", line = 9, expression = "self.hp, amount", enabled = true, text = "self.hp -= amount"},
		{file = "hero.odin", line = 11, expression = "self.hp", enabled = false, text = "self.hp = 0"},
		{file = "hero.odin", line = 14, expression = "amount", enabled = true, text = "case 1:"},
		{file = "other.odin", line = 9, expression = "x", enabled = true, text = "self.hp -= amount"},
	}
	out, problems := LogPoint_Inject(LOG_POINT_SOURCE, "hero.odin", points, procs)
	lines := strings.split_lines(out, context.temp_allocator)
	testing.expect_value(t, len(lines), len(strings.split_lines(LOG_POINT_SOURCE, context.temp_allocator)))
	testing.expect_value(t, lines[8], "\te.Log_Debug(\"hero.odin:9: self.hp = %v, amount = %v\", self.hp, amount, category = \"logpoint\"); self.hp -= amount")
	testing.expect_value(t, lines[10], "\t\tself.hp = 0")
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 do testing.expectf(t, strings.contains(problems[0], "hero.odin:14") && strings.contains(problems[0], "case"), "%q", problems[0])

	// Two lines added above: it follows its line
	moved := strings.concatenate({"// one\n// two\n", LOG_POINT_SOURCE}, context.temp_allocator)
	out, problems = LogPoint_Inject(moved, "hero.odin", points[:1], logPointProcs(moved))
	lines = strings.split_lines(out, context.temp_allocator)
	testing.expectf(t, strings.contains(lines[10], "hero.odin:11: self.hp") && strings.has_suffix(lines[10], "self.hp -= amount"), "%q", lines[10])
	lp: LogPoints
	append(&lp.points, LogPoint{file = strings.clone("hero.odin"), line = 9, expression = strings.clone("self.hp"), enabled = true, text = strings.clone("self.hp -= amount")})
	testing.expect(t, LogPoints_Relocate(&lp, "hero.odin", moved), "moved")
	testing.expect_value(t, lp.points[0].line, 11)
	LogPoints_Destroy(&lp)
	// Its line gone
	gone, _ := strings.replace_all(LOG_POINT_SOURCE, "self.hp -= amount", "self.hp -= amount * 2", context.temp_allocator)
	_, problems = LogPoint_Inject(gone, "hero.odin", points[:1], logPointProcs(gone))
	testing.expect(t, len(problems) == 1 && strings.contains(problems[0], "gone"), "said")

	// No engine import
	plain := "package scripts\n\ncount :: proc(n: int) {\n\tx := n\n\t_ = x\n}\n"
	out, _ = LogPoint_Inject(plain, "count.odin", []LogPoint{{file = "count.odin", line = 4, expression = "n", enabled = true, text = "x := n"}}, logPointProcs(plain))
	testing.expect(t, strings.contains(out, "\t__logpoint_engine.Log_Debug(\"count.odin:4: n = %v\", n, category = \"logpoint\"); x := n"), "the alias")
	testing.expect(t, strings.has_suffix(out, "import __logpoint_engine \"engine:.\"\n"), "imported at the end")
	free_all(context.temp_allocator)
}

// Set, kept in .editor/logpoints.ini, built from a copy (the user's file unchanged; the copy
// compiles with it), turned off and removed
@(test)
log_points_kept_and_built :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, "editor_test_log_points"}, context.temp_allocator)
	_ = removeAll(dir)
	defer removeAll(dir)
	folder := joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	path := joinPath(folder, "hero.odin", allocator = context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)string(LOG_POINT_SOURCE))
	_ = os.write_entire_file(joinPath(folder, "other.odin", allocator = context.temp_allocator), transmute([]u8)string("package scripts\n"))
	state := State{project = Project_CreateTestProject(dir), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(), currentScene = 1}
	defer State_Destroy(&state)
	LogPoints_Follow(&state)
	testing.expect_value(t, len(state.logPoints.points), 0)

	// The dialog: opened on line 9, typed, OK
	state, _ = update(state, Msg(Log_Point_Dialog_Opened{"hero.odin", 9, "self.hp -= amount"}))
	testing.expect(t, state.logPoints.dialog.open && !state.logPoints.dialog.existing, "a new one")
	state, _ = update(state, Msg(Log_Point_Expression_Changed("self.hp, amount")))
	state, _ = update(state, Msg(Log_Point_Saved{}))
	testing.expect(t, !state.logPoints.dialog.open, "closed")
	testing.expect_value(t, len(state.logPoints.points), 1)
	testing.expect(t, LogPoints_Active(&state.logPoints), "on")
	saved, err := os.read_entire_file(joinPath(dir, LOG_POINTS_FILE, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, err == nil && strings.contains(string(saved), "[hero.odin:9]") && strings.contains(string(saved), "expression = self.hp, amount"), "kept")
	// Read back
	again: LogPoints
	LogPoints_Parse(&again, string(saved))
	testing.expect(t, len(again.points) == 1 && again.points[0].line == 9 && again.points[0].enabled && again.points[0].text == "self.hp -= amount", "read back")
	LogPoints_Destroy(&again)

	// The build's copy: the line in it, the user's file as it was, other files copied
	buildDir := joinPath(dir, "build_copy", allocator = context.temp_allocator)
	problems := LogPoints_WriteBuild(&state, buildDir)
	testing.expect_value(t, len(problems), 0)
	copied, _ := os.read_entire_file(joinPath(buildDir, SCRIPTS_FOLDER, "hero.odin", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(copied), "e.Log_Debug(\"hero.odin:9: self.hp = %v, amount = %v\", self.hp, amount, category = \"logpoint\"); self.hp -= amount"), "the copy has it")
	original, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(original), LOG_POINT_SOURCE)
	testing.expect(t, os.exists(joinPath(buildDir, SCRIPTS_FOLDER, "other.odin", allocator = context.temp_allocator)), "every file")
	// It compiles (the engine's Log_Debug as the statement calls it)
	odin := Toolchain_Odin("")
	engine, found := Toolchain_EngineDir()
	if odin != "" && found {
		mainDir := joinPath(dir, "main", allocator = context.temp_allocator)
		_ = os.make_directory_all(mainDir)
		_ = os.write_entire_file(joinPath(mainDir, "main.odin", allocator = context.temp_allocator), transmute([]u8)playerMainSource(logPoints = true))
		status, stdout, stderr, runErr := Process_Exec({command = {odin, "check", mainDir, fmt.tprintf("-collection:engine=%s", engine), fmt.tprintf("-collection:logpoints=%s", buildDir)}}, context.temp_allocator)
		testing.expectf(t, runErr == nil && status.exit_code == 0, "the copy compiles: %s%s", string(stdout), string(stderr))
	}

	// A marker's commands: off (the copy is the file again), then removed (the file goes)
	state, _ = update(state, Msg(Log_Point_Command{"hero.odin", 9, .Toggle}))
	testing.expect(t, !LogPoints_Active(&state.logPoints), "off")
	_ = LogPoints_WriteBuild(&state, buildDir)
	copied, _ = os.read_entire_file(joinPath(buildDir, SCRIPTS_FOLDER, "hero.odin", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, string(copied), LOG_POINT_SOURCE)
	state, _ = update(state, Msg(Log_Point_Command{"hero.odin", 9, .Edit}))
	testing.expect(t, state.logPoints.dialog.open && state.logPoints.dialog.existing && state.logPoints.dialog.expression == "self.hp, amount", "editing it")
	state, _ = update(state, Msg(Log_Point_Command{"hero.odin", 9, .Remove}))
	testing.expect(t, !state.logPoints.dialog.open, "its dialog closes")
	testing.expect_value(t, len(state.logPoints.points), 0)
	testing.expect(t, !os.exists(joinPath(dir, LOG_POINTS_FILE, allocator = context.temp_allocator)), "the file goes")

	// The build's paths read as the project's in the Output tab
	state, _ = update(state, Msg(Log_Point_Dialog_Opened{"hero.odin", 11, "self.hp = 0"}))
	state, _ = update(state, Msg(Log_Point_Expression_Changed("self.hp")))
	state, _ = update(state, Msg(Log_Point_Saved{}))
	copyScripts := joinPath(LogPoints_BuildDir(&state), SCRIPTS_FOLDER, allocator = context.temp_allocator)
	mapped := LogPoints_ProjectPaths(&state, fmt.tprintf("%s/hero.odin(11:5) Error: Undeclared name: nope", copyScripts))
	testing.expectf(t, strings.has_prefix(mapped, absolutePath(folder)), "%q", mapped)
	free_all(context.temp_allocator)
}
