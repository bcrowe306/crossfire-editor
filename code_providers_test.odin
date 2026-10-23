package crossfire_editor

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"

@(private="file")
PROBE_SOURCE :: `package scripts

import e "engine:."

Probe :: struct {
	using script: e.Script,
	speed: f32 ` + "`export:\"default=1\"`" + `,
	grid: [3]f32 ` + "`export:\"\"`" + `,
}

@(init)
register_Probe :: proc "contextless" () {
	e.Script_Register(Probe, {
		ready = proc(self: ^Probe) {
			target := e.Node_FindPath(self.node, )
			_ = target
		},
	})
}
`

// The host's providers in a code tab: the project's constants complete, the index's problems
// show, Script_Register's line gets a marker and a hint, a node dropped on a call's argument
// inserts its path constant
@(test)
code_providers_in_a_code_tab :: proc(t: ^testing.T) {
	// The code editors are package state, and SDL_ttf isn't thread-safe: these tests take turns
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, "editor_test_code_providers"}, context.temp_allocator)
	_ = removeAll(dir)
	defer removeAll(dir)
	folder := joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	path := absolutePath(joinPath(folder, "probe.odin", allocator = context.temp_allocator))
	_ = os.write_entire_file(path, transmute([]u8)string(PROBE_SOURCE))

	state := State{project = Project_CreateTestProject(dir), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(), currentScene = 1}
	defer State_Destroy(&state)
	state.settings.olsPath = FixedText_Make("/nonexistent/ols")
	state.settings.builtInCodeEditor = true
	play := &state.project.scenes[1]
	ship := -1
	for n, i in play.nodes do if n.name == "Spaceship" do ship = i
	delete(play.nodes[ship].script)
	play.nodes[ship].script = strings.clone("Probe")

	// The index reads the folder
	sources := ScriptIndex_Plan(&state.scriptIndex, absolutePath(folder))
	files, _ := ScriptIndex_ParseAll(sources[:])
	for s in sources { delete(s.path); delete(s.text) }
	delete(sources)
	ScriptIndex_Take(&state.scriptIndex, files)
	delete(files)
	ScriptIndex_Apply(&state)
	testing.expect(t, ScriptCatalog_Find(&state.scripts, "Probe") != nil, "the catalog knows Probe before a build")

	_ = Script_Open(&state, path, 1)
	c := CodeEditor_Find(path)
	testing.expect(t, c != nil, "open")
	if c == nil do return

	CodeProviders_Begin(&state)
	ce.editor_run_cached_providers(&c.ed)
	CodeProviders_End()
	inlays, marker := CodeEditor_LineNotes(path, 12)
	testing.expect(t, marker && inlays == "1 node", "Script_Register's line: a marker, 1 node")
	testing.expect(t, CodeEditor_DiagnosticHas(path, "[3]f32 can't be exported"), "the index's problem")

	// Completion: the project's constants, not after a `.`
	CodeProviders_Begin(&state)
	cebuf.buffer_insert_text(&c.ed.buf, {15, 0}, "\t\t\tSCENE_PL\n")
	c.ed.buf.cursors[0] = {pos = {15, 11}}
	ce.editor_request_completion(&c.ed)
	testing.expect(t, CodeEditor_CompletionProvided(path, "SCENE_PLAY_SCENE"), "a scene's constant")
	ce.editor_close_completion(&c.ed)
	c.ed.buf.cursors[0] = {pos = {14, 15}} // after "e."
	ce.editor_request_completion(&c.ed)
	testing.expect(t, !ce.editor_completion_visible(&c.ed), "nothing after a dot")

	// A node dropped on the call's argument: its path constant
	line := cebuf.buffer_line_str(&c.ed.buf, 14)
	at := strings.index(line, ", )") + 2
	message, handled := ce.editor_drop_at(&c.ed, {14, at}, ce.Drop_Request{kind = CODE_DROP_NODE, data = rawptr(uintptr(ship))})
	CodeProviders_End()
	testing.expect(t, handled && strings.contains(message, "PATH_PLAY_SCENE_WORLD_SPACESHIP"), "taken")
	testing.expect(t, strings.contains(cebuf.buffer_line_str(&c.ed.buf, 14), "e.Node_FindPath(self.node, PATH_PLAY_SCENE_WORLD_SPACESHIP)"), "inserted")
	free_all(context.temp_allocator)
}
