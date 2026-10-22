package crossfire_editor

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// Recent projects (recent_projects.odin) and Save As (project_session.odin)

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(test)
recent_projects_list :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_recent"
	removeAll(dir)
	os.make_directory(dir)
	defer removeAll(dir)
	settings := "build/test_recent/editor.ini"

	recent := Recent_Load(settings)
	testing.expect_value(t, len(recent.folders), 0)
	Recent_Add(&recent, "/games/a")
	Recent_Add(&recent, "/games/b")
	Recent_Add(&recent, "/games/a")
	testing.expect(t, len(recent.folders) == 2 && recent.folders[0] == "/games/a" && recent.folders[1] == "/games/b", "moved to the front, once")
	for i in 0 ..< 12 do Recent_Add(&recent, strings.concatenate({"/games/n", string([]u8{u8('a' + i)})}, context.temp_allocator))
	testing.expect_value(t, len(recent.folders), RECENT_PROJECTS_MAX)
	testing.expect_value(t, recent.folders[0], "/games/nl")
	Recent_Destroy(&recent)

	// Saved beside the settings file, read back the same
	again := Recent_Load(settings)
	defer Recent_Destroy(&again)
	testing.expect(t, os.exists("build/test_recent/recent_projects.txt"), "the file")
	testing.expect_value(t, len(again.folders), RECENT_PROJECTS_MAX)
	testing.expect_value(t, again.folders[0], "/games/nl")
	Recent_Remove(&again, "/games/nl")
	testing.expect_value(t, again.folders[0], "/games/nk")
	testing.expect_value(t, Recent_Label("/games/nk"), "nk   /games")
	Recent_Clear(&again)
	cleared := Recent_Load(settings)
	defer Recent_Destroy(&cleared)
	testing.expect_value(t, len(cleared.folders), 0)

	// No settings file (test runs): nothing kept
	none := Recent_Load("")
	Recent_Add(&none, "/games/x")
	testing.expect_value(t, none.path, "")
	Recent_Destroy(&none)
}

@(test)
save_as_copies_the_project_and_opens_the_copy :: proc(t: ^testing.T) {
	context.logger = log.nil_logger()
	os.make_directory("build")
	dir := "build/test_save_as"
	removeAll(dir)
	os.make_directory(dir)
	defer removeAll(dir)
	root := "build/test_save_as/Game"
	project := Project_CreateEmpty(root, "Game")
	testing.expect_value(t, Project_Save(&project), "")
	// The project's files, and what isn't the project's (build output, Git history)
	os.make_directory("build/test_save_as/Game/assets")
	_ = os.write_entire_file("build/test_save_as/Game/assets/notes.txt", transmute([]byte)string("hello"))
	os.make_directory("build/test_save_as/Game/build")
	_ = os.write_entire_file("build/test_save_as/Game/build/junk.bin", transmute([]byte)string("junk"))
	os.make_directory("build/test_save_as/Game/.git")
	_ = os.write_entire_file("build/test_save_as/Game/.git/HEAD", transmute([]byte)string("ref"))

	state := State{project = project, browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	state.recentProjects = Recent_Load("build/test_save_as/editor.ini")
	defer State_Destroy(&state)
	// An unsaved change: it goes to the copy, not to the project where it was
	sendTo(&state, Node_Picked(0))
	sendTo(&state, Node_Field_Changed{.Rotation, 30})
	testing.expect(t, Project_IsModified(&state), "modified")

	sendTo(&state, Action.Save_Project_As)
	testing.expect(t, state.session.newProject.open && state.session.newProject.saveAs, "the dialog, as Save As")
	testing.expect_value(t, state.session.newProject.name, "Game Copy")
	// A folder that exists is refused
	sendTo(&state, New_Project_Name_Changed("Game"))
	sendTo(&state, New_Project_Created{})
	testing.expect(t, state.session.newProject.open, "refused")
	sendTo(&state, New_Project_Name_Changed("Game2"))
	sendTo(&state, New_Project_Created{})
	testing.expect(t, !state.session.newProject.open, "saved")

	copy := "build/test_save_as/Game2"
	testing.expect(t, os.exists(joinPath(copy, "project.xml", allocator = context.temp_allocator)), "project.xml")
	testing.expect(t, os.exists(joinPath(copy, "assets/notes.txt", allocator = context.temp_allocator)), "its files")
	testing.expect(t, !os.exists(joinPath(copy, "build", allocator = context.temp_allocator)), "no build output")
	testing.expect(t, !os.exists(joinPath(copy, ".git", allocator = context.temp_allocator)), "no Git history")
	// The copy is open, saved, with the change; the project where it was is as it was saved
	testing.expect_value(t, absolutePath(state.project.rootPath), absolutePath(copy))
	testing.expect_value(t, state.project.name, "Game2")
	testing.expect(t, !Project_IsModified(&state), "saved")
	testing.expect_value(t, state.project.scenes[0].nodes[0].rotation, f32(30))
	original, message, _ := Project_Load(root)
	defer Project_Destroy(&original)
	testing.expect_value(t, message, "")
	testing.expect_value(t, original.scenes[0].nodes[0].rotation, f32(0))
	testing.expect_value(t, original.name, "Game")
	// And it's the most recent project
	testing.expect(t, len(state.recentProjects.folders) > 0 && state.recentProjects.folders[0] == absolutePath(copy), "recent")

	// A recent project that's gone is reported and dropped
	Recent_Add(&state.recentProjects, "build/test_save_as/Gone")
	sendTo(&state, Recent_Project_Chosen(0))
	testing.expect_value(t, absolutePath(state.project.rootPath), absolutePath(copy))
	for folder in state.recentProjects.folders do testing.expect(t, !strings.has_suffix(folder, "Gone"), "dropped")
	// One that's there opens
	Recent_Add(&state.recentProjects, root)
	sendTo(&state, Recent_Project_Chosen(0))
	testing.expect_value(t, absolutePath(state.project.rootPath), absolutePath(root))
}
