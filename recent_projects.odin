package crossfire_editor

import "core:os"
import "core:path/filepath"
import "core:strings"

/*
Recent projects: the folders of the projects opened lately, most recent first, listed in the
File menu (`fileMenuRecent` in view.odin) to open again in one click.

- Kept in `recent_projects.txt` beside the settings file (`editor.ini`; a UI test's scratch
  settings file has its own list), one absolute folder per line. Test runs without a settings
  file keep none (`RecentProjects.path` is "").
- `Recent_Add` runs whenever a project opens (start-up, Open, New, an archive, Save As): it moves
  to the front, at most `RECENT_PROJECTS_MAX` are kept, and the file is written straight away.
- A folder that's gone (moved, deleted) is reported when chosen and dropped from the list
  (`Recent_Remove`).
*/

// How many recent projects are kept, and how many the File menu lists
RECENT_PROJECTS_MAX :: 10
RECENT_PROJECTS_SHOWN :: 8

// The recent projects list's file, beside the settings file
RECENT_PROJECTS_FILE :: "recent_projects.txt"

// The recent projects and where they're saved
RecentProjects :: struct {
	// Absolute folders, most recent first (owned)
	folders: [dynamic]string,
	// The list's file ("": not saved)
	path: string,
}

/*
Reads the list kept beside a settings file.

Inputs:
- settingsPath: The settings file ("": no list is kept)

Returns:
- The list (Recent_Destroy frees it)
*/
Recent_Load :: proc(settingsPath: string) -> RecentProjects {
	recent: RecentProjects
	if settingsPath == "" do return recent
	recent.path = filepath.join({filepath.dir(settingsPath), RECENT_PROJECTS_FILE}) or_else ""
	data, err := os.read_entire_file(recent.path, context.temp_allocator)
	if err != nil do return recent
	for line in strings.split_lines(string(data), context.temp_allocator) {
		folder := strings.trim_space(line)
		if folder == "" || len(recent.folders) >= RECENT_PROJECTS_MAX do continue
		duplicate := false
		for known in recent.folders do if known == folder do duplicate = true
		if !duplicate do append(&recent.folders, strings.clone(folder))
	}
	return recent
}

// Frees the list
Recent_Destroy :: proc(recent: ^RecentProjects) {
	for folder in recent.folders do delete(folder)
	delete(recent.folders)
	delete(recent.path)
	recent^ = {}
}

/*
Puts a project's folder first (moving it if it's listed), keeps at most RECENT_PROJECTS_MAX, and
writes the file.

Inputs:
- recent: The list
- root: The project's folder (made absolute; copied)
*/
Recent_Add :: proc(recent: ^RecentProjects, root: string) {
	if root == "" do return
	folder := absolutePath(root)
	removeFolder(recent, folder)
	inject_at(&recent.folders, 0, strings.clone(folder))
	for len(recent.folders) > RECENT_PROJECTS_MAX do delete(pop(&recent.folders))
	Recent_Save(recent)
}

// Drops a folder from the list (it's gone) and writes the file
Recent_Remove :: proc(recent: ^RecentProjects, root: string) {
	removeFolder(recent, root)
	Recent_Save(recent)
}

// Empties the list and writes the file
Recent_Clear :: proc(recent: ^RecentProjects) {
	for folder in recent.folders do delete(folder)
	clear(&recent.folders)
	Recent_Save(recent)
}

// Writes the list to its file (nothing without one)
Recent_Save :: proc(recent: ^RecentProjects) {
	if recent.path == "" do return
	text := strings.join(recent.folders[:], "\n", context.temp_allocator)
	_ = os.write_entire_file(recent.path, transmute([]byte)strings.concatenate({text, "\n"}, context.temp_allocator))
}

/*
How the File menu shows a recent project: its folder's name, then where it is (the home folder
as ~).
*/
Recent_Label :: proc(folder: string) -> string {
	dir := filepath.dir(folder)
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do home = os.get_env("USERPROFILE", context.temp_allocator)
	if home != "" && strings.has_prefix(dir, home) do dir = strings.concatenate({"~", dir[len(home):]}, context.temp_allocator)
	return strings.concatenate({filepath.base(folder), "   ", dir}, context.temp_allocator)
}

/*
The recent projects the File menu lists: their indices in the list, most recent first, at most
RECENT_PROJECTS_SHOWN, without the open project.

Returns:
- Indices into `state.recentProjects.folders` (temp allocated)
*/
Recent_Shown :: proc(state: ^State) -> []int {
	shown := make([dynamic]int, context.temp_allocator)
	open := absolutePath(state.project.rootPath)
	for folder, i in state.recentProjects.folders {
		if folder == open || len(shown) >= RECENT_PROJECTS_SHOWN do continue
		append(&shown, i)
	}
	return shown[:]
}

@(private="file")
removeFolder :: proc(recent: ^RecentProjects, folder: string) {
	for i := 0; i < len(recent.folders); {
		if recent.folders[i] == folder {
			delete(recent.folders[i])
			ordered_remove(&recent.folders, i)
		} else {
			i += 1
		}
	}
}
