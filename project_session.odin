package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
The open project's lifecycle: unsaved changes, New and Open Project, and the "save changes?"
prompt before quitting or switching projects. The dialogs are in view_project_dialogs.odin.

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
	newProject: struct {
		open: bool,
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
			logLine(state, .Error, fmt.aprintf("New project: %s", message))
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
	}
	return {}
}

// Replaces the open project, resetting everything that belonged to the old one
@(private="file")
switchProject :: proc(state: ^State, project: Project) {
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
