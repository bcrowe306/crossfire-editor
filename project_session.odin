package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
The open project's lifecycle: unsaved changes, New and Open Project, Save As, recent projects
(recent_projects.odin), and the "save changes?" prompt before quitting or switching projects. The
dialogs are in view_project_dialogs.odin.

Save As (`Session_OpenSaveAs`, the New Project dialog with `saveAs` set) copies the project's own
files (`Project_OwnFiles`: not build output, exported games or `.git`) into the new folder, writes
what's open there (the project as it is, unsaved code tabs' text), then opens the copy: the
project on disk where it was stays as it was last saved. Assets outside the project folder keep
their paths and are reported (a relative one may not resolve from the new place).

Unsaved changes: every undo step pushed, merged, undone or redone bumps `history.version`, so the
project is modified when that differs from the version at the last save, or when assets were
imported or removed since (those aren't in the history). Undoing back to the saved state still
counts as modified.
*/

// What waits on the "save changes?" prompt
PendingAction :: enum {
	None,
	Quit,
	New_Project,
	Open_Project,
	Open_Project_Archive,
	// A recent project (SessionState.recent)
	Open_Recent,
}

SessionState :: struct {
	// `history.version` at the last save
	savedVersion: int,
	// Assets were imported or removed since the last save
	assetsChanged: bool,
	// The "save changes?" prompt, and what to do after it
	confirm: struct {
		open: bool,
		pending: PendingAction,
	},
	// The recent project waiting on the prompt (owned)
	recent: string,
	newProject: struct {
		open: bool,
		// Save As: the dialog names the copy instead of a new project
		saveAs: bool,
		// Owned
		name: string,
		location: string,
	},
}

// Whether the project has changes that aren't saved
Project_IsModified :: proc(state: ^State) -> bool {
	return state.history.version != state.session.savedVersion || state.session.assetsChanged || CodeTabs_AnyDirty(state)
}

// Records a successful save
Session_MarkSaved :: proc(state: ^State) {
	state.session.savedVersion = state.history.version
	state.session.assetsChanged = false
}

/*
Saves the project and logs the result.

Returns:
- Whether it saved
*/
Session_Save :: proc(state: ^State) -> bool {
	if !CodeTabs_SaveAll(state) do return false
	if message := Project_Save(&state.project); message != "" {
		logLine(state, .Error, fmt.aprintf("Save failed: %s", message))
		return false
	}
	Session_MarkSaved(state)
	state.git.stale = true
	_ = Shaders_Compile(state)
	_ = Fonts_MakeMSDF(state)
	logLine(state, .Info, fmt.aprintf("Saved to %s", state.project.rootPath))
	return true
}

/*
Runs an action that would lose unsaved changes (quit, new, open), asking first if there are any.

Returns:
- The command to run
*/
Session_Request :: proc(state: ^State, action: PendingAction) -> skald.Command(Msg) {
	if Project_IsModified(state) {
		state.session.confirm = {open = true, pending = action}
		return {}
	}
	return runPending(state, action)
}

/*
Handles a project session message.

Returns:
- A command to run, and whether `m` was a session message
*/
Session_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	session := &state.session
	#partial switch v in m {
	case Confirm_Chosen:
		pending := session.confirm.pending
		session.confirm = {}
		switch v {
		case .Cancel:
			return {}, true
		case .Save:
			if !Session_Save(state) do return {}, true
		case .Discard:
		}
		return runPending(state, pending), true
	case New_Project_Name_Changed:
		delete(session.newProject.name)
		session.newProject.name = strings.clone(string(v))
	case New_Project_Location_Changed:
		delete(session.newProject.location)
		session.newProject.location = strings.clone(string(v))
	case New_Project_Browse:
		return skald.cmd_open_folder_dialog(proc(r: skald.File_Dialog_Result) -> Msg { return New_Project_Location_Chosen(r) },
			default_location = session.newProject.location), true
	case New_Project_Location_Chosen:
		if !v.cancelled && v.path != "" {
			delete(session.newProject.location)
			session.newProject.location = strings.clone(v.path)
		}
	case New_Project_Created:
		name := strings.trim_space(session.newProject.name)
		root, _ := filepath.join({session.newProject.location, name}, context.temp_allocator)
		if message := newProjectProblem(name, session.newProject.location, root); message != "" {
			logLine(state, .Error, fmt.aprintf("%s: %s", session.newProject.saveAs ? "Save As" : "New project", message))
			return {}, true
		}
		if session.newProject.saveAs {
			if saveProjectAs(state, root, name) do session.newProject.open = false
			return {}, true
		}
		project := Project_CreateEmpty(root, name)
		if message := Project_Save(&project); message != "" {
			logLine(state, .Error, fmt.aprintf("New project: couldn't create it: %s", message))
			Project_Destroy(&project)
			return {}, true
		}
		session.newProject.open = false
		switchProject(state, project)
		logLine(state, .Info, fmt.aprintf("Created '%s' in %s", name, root))
	case New_Project_Cancelled:
		session.newProject.open = false
	case Open_Project_Chosen:
		if v.cancelled || v.path == "" do return {}, true
		Session_OpenProject(state, v.path)
	case Recent_Project_Chosen:
		if int(v) < 0 || int(v) >= len(state.recentProjects.folders) do return {}, true
		delete(session.recent)
		session.recent = strings.clone(state.recentProjects.folders[int(v)])
		return Session_Request(state, .Open_Recent), true
	case Recent_Projects_Cleared:
		Recent_Clear(&state.recentProjects)
	case:
		return {}, false
	}
	return {}, true
}

/*
Opens the project in a folder, replacing the current one (without asking: callers check for
unsaved changes first). On failure the current project stays open and the error is logged.
*/
Session_OpenProject :: proc(state: ^State, root: string) {
	project, message, warnings := Project_Load(root)
	if message != "" {
		logLine(state, .Error, fmt.aprintf("Open project: %s", message))
		return
	}
	switchProject(state, project)
	logLine(state, .Info, fmt.aprintf("Opened '%s' from %s", project.name, root))
	for warning in warnings do logLine(state, .Warning, strings.clone(warning))
}

/*
An empty project: one scene, "Main", with a top-level Node2D, a 1280x720 game area.

Inputs:
- root: The project folder; copied
- name: Project name; copied

Returns:
- The project (not saved yet). Free with `Project_Destroy`
*/
Project_CreateEmpty :: proc(root, name: string) -> Project {
	project := Project{
		name = strings.clone(name),
		rootPath = strings.clone(root),
		gameSize = {1280, 720},
		scaleMode = .Letterbox,
		background = {18, 20, 28, 255},
		startScene = strings.clone("Main"),
		physics = e.DEFAULT_PHYSICS,
		window = e.DEFAULT_WINDOW_SETTINGS,
		grid = e.DEFAULT_GRID_SETTINGS,
		players = e.DEFAULT_PLAYER_SETTINGS,
		audioOutput = e.DEFAULT_AUDIO_OUTPUT,
		exports = ExportSettings_Default(),
	}
	scene := SceneDef{name = strings.clone("Main")}
	Scene_InsertNode(&scene, "World", .Node2D, -1)
	append(&project.scenes, scene)
	// Like Godot: ui_left / right / up / down, ui_accept, ui_cancel
	project.actions = DefaultActions()
	project.buses = Buses_FromData(nil)
	return project
}

// Why a new project can't be created there, or ""
@(private="file")
newProjectProblem :: proc(name, location, root: string) -> string {
	if name == "" do return "give the project a name"
	if strings.contains_any(name, "/\\") do return "the name can't contain / or \\"
	if location == "" || !os.is_dir(location) do return fmt.tprintf("the location '%s' isn't a folder", location)
	if os.exists(root) do return fmt.tprintf("%s already exists", root)
	return ""
}

// Does what was waiting on the "save changes?" prompt
@(private="file")
runPending :: proc(state: ^State, action: PendingAction) -> skald.Command(Msg) {
	switch action {
	case .None:
	case .Quit:
		// Don't leave a game or an export running after the editor closes
		playStop(state)
		Export_Cancel(state)
		return skald.cmd_quit(Msg)
	case .New_Project:
		newProject := &state.session.newProject
		delete(newProject.name)
		delete(newProject.location)
		// Next to the current project by default
		newProject^ = {open = true, name = strings.clone("NewGame"), location = strings.clone(filepath.dir(state.project.rootPath))}
	case .Open_Project:
		return skald.cmd_open_folder_dialog(proc(r: skald.File_Dialog_Result) -> Msg { return Open_Project_Chosen(r) },
			default_location = filepath.dir(state.project.rootPath))
	case .Open_Project_Archive:
		return ProjectArchive_Open(state)
	case .Open_Recent:
		folder := strings.clone(state.session.recent, context.temp_allocator)
		if !os.exists(filepath.join({folder, "project.xml"}, context.temp_allocator) or_else "") {
			logLine(state, .Error, fmt.aprintf("Open recent: %s has no project any more; it's off the list", folder))
			Recent_Remove(&state.recentProjects, folder)
			return {}
		}
		Session_OpenProject(state, folder)
	}
	return {}
}

// Opens the Save As dialog: a name and a place for the copy (beside the project by default)
Session_OpenSaveAs :: proc(state: ^State) {
	newProject := &state.session.newProject
	delete(newProject.name)
	delete(newProject.location)
	newProject^ = {
		open = true,
		saveAs = true,
		name = fmt.aprintf("%s Copy", filepath.base(absolutePath(state.project.rootPath))),
		location = strings.clone(filepath.dir(absolutePath(state.project.rootPath))),
	}
}

/*
Save As: the project's own files copied into `root`, what's open written over them (the project,
unsaved code tabs), then the copy opened.

Returns:
- Whether it was saved (else the error is logged and the project stays as it was)
*/
@(private="file")
saveProjectAs :: proc(state: ^State, root, name: string) -> bool {
	from := absolutePath(state.project.rootPath)
	files := Project_OwnFiles(&state.project)
	for file in files {
		target := joinPath(root, file, allocator = context.temp_allocator)
		_ = os.make_directory_all(filepath.dir(target))
		if err := os.copy_file(target, joinPath(from, file, allocator = context.temp_allocator)); err != nil {
			logLine(state, .Error, fmt.aprintf("Save As: couldn't copy %s: %v", file, err))
			return false
		}
	}
	// Unsaved scripts: their text goes to the copy (the files where they were stay as saved)
	for path in state.codeTabs {
		rel, err := filepath.rel(from, absolutePath(path), context.temp_allocator)
		if err != nil || strings.has_prefix(rel, "..") || !CodeEditor_IsDirty(path) do continue
		text := CodeEditor_Text(path)
		_ = os.write_entire_file(joinPath(root, rel, allocator = context.temp_allocator), transmute([]byte)text)
	}
	// The project as it's open, written into the copy
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone(root)
	delete(state.project.name)
	state.project.name = strings.clone(name)
	if message := Project_Save(&state.project); message != "" {
		logLine(state, .Error, fmt.aprintf("Save As: %s", message))
		// Back where it was, unsaved as it was
		delete(state.project.rootPath)
		state.project.rootPath = strings.clone(from)
		return false
	}
	for asset in state.project.assets {
		if Asset_IsOutside(asset.path) do logLine(state, .Warning, fmt.aprintf("Save As: %s is outside the project folder; the copy uses the same path, which may not find it from %s", asset.path, root))
	}
	logLine(state, .Info, fmt.aprintf("Saved a copy as '%s' in %s (%d files); opening it", name, root, len(files)))
	Session_OpenProject(state, root)
	return true
}

// Replaces the open project, resetting everything that belonged to the old one
@(private="file")
switchProject :: proc(state: ^State, project: Project) {
	Recent_Add(&state.recentProjects, project.rootPath)
	playStop(state)
	// The save prompt came first: what's still unsaved is dropped
	CodeTabs_CloseAll(state)
	AudioPreview_Unload()
	Project_Destroy(&state.project)
	state.project = project
	History_Destroy(&state.history)
	state.session.savedVersion = 0
	state.session.assetsChanged = false
	state.currentScene = 0
	for scene, i in project.scenes do if scene.name == project.startScene do state.currentScene = i
	state.selectedNode = -1
	state.browserSelection = {kind = .None}
	state.viewport.drag = {}
	// Fit the new game area on the next measure
	state.viewport.zoom = 0
	delete(state.rename.text)
	state.rename = {}
	state.treeDrag = {}
	state.assetDrag = {}
	// The new project's scripts haven't been built
	ScriptCatalog_Clear(&state.scripts)
	state.scripts.status = .Unknown
	state.scriptsAutoBuilt = false
	Scripts_Refresh(state)
	// Another folder: its version control is read again
	state.git.stale = true
}

/*
Keeps the window title showing the project and whether it has unsaved changes:
"NewGame* - Crossfire Editor". Called from `view`; only touches the window when the text changes.
*/
Session_UpdateTitle :: proc(state: ^State) {
	title := fmt.tprintf("%s%s - %s", state.project.name, Project_IsModified(state) ? "*" : "", APP_NAME)
	if title == lastWindowTitle do return
	count: i32
	windows := sdl.GetWindows(&count)
	if windows == nil || count == 0 do return
	defer sdl.free(windows)
	if sdl.SetWindowTitle(windows[0], strings.clone_to_cstring(title, context.temp_allocator)) {
		delete(lastWindowTitle)
		lastWindowTitle = strings.clone(title)
	}
}

// The window title last set, so it's only set when it changes. Package state: the view sets the
// title, and the view can't change State
@(private="file")
lastWindowTitle: string
