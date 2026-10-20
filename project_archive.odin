package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "gui:skald"

/*
Project archives: a whole project in one file, to move it to another computer or send it to
someone. An archive is a zip (zip.odin) with the extension PROJECT_ARCHIVE_EXTENSION, holding one
folder, the project's: `MyGame/project.xml`, `MyGame/scenes/...`, `MyGame/assets/...`, its
scripts, components, data and export.ini. Any unzip tool opens it.

- **File > Export Project Archive...** saves the project, then writes the archive
  (`ProjectArchive_Create`, on a worker thread). Left out: exported games (`export/`, and output
  folders set inside the project), `.git/`, `build/`, `.DS_Store`, `Thumbs.db`.
- **Assets outside the project folder** (a hand-edited path like `../art/ship.png`, or an
  absolute one) are copied into the archive's `assets/external/`, and the archive's copies of
  project.xml, the scenes, components, data files and scripts point at them there (quoted
  paths, replaced). The project on disk isn't changed: only the archive is portable.
- **File > Open Project Archive...** picks an archive (or any zip of a project), then the folder
  to unpack it into: it becomes `<folder>/<project folder>` (`_2`, `_3`... when taken), and opens
  (`ProjectArchive_Extract`). Names that would land outside it ("..", absolute) are refused.

Example:
	input := ArchiveInput{root = "my_game", folder = "MyGame", archive = "MyGame.odinsdl"}
	result := ProjectArchive_Create(input)
*/

// A project archive's extension (a zip)
PROJECT_ARCHIVE_EXTENSION :: "odinsdl"

// The file dialogs' filters for project archives
@(private="file")
ARCHIVE_FILTERS := []skald.File_Filter{{name = "Project archive", pattern = PROJECT_ARCHIVE_EXTENSION}}
@(private="file")
OPEN_ARCHIVE_FILTERS := []skald.File_Filter{{name = "Project archive", pattern = PROJECT_ARCHIVE_EXTENSION}, {name = "Zip", pattern = "zip"}}

// Top-level folders an archive leaves out
@(private="file")
ARCHIVE_SKIPPED_FOLDERS := []string{"export", ".git", "build"}
// Files left out wherever they are
@(private="file")
ARCHIVE_SKIPPED_FILES := []string{".DS_Store", "Thumbs.db", "desktop.ini"}
// Files whose asset paths are rewritten when assets from outside the project are brought in
@(private="file")
ARCHIVE_TEXT_EXTENSIONS := []string{".xml", ".json", ".odin", ".ini"}

// What ProjectArchive_Create needs (copied for the worker thread: ProjectArchive_Input)
ArchiveInput :: struct {
	// The project folder
	root: string,
	// The folder name inside the archive
	folder: string,
	// The archive to write
	archive: string,
	// The project's asset paths, as in project.xml
	assets: []string,
	// More folders to leave out (absolute): export output folders inside the project
	skip: []string,
	// Keep the project's version control history (`.git/`), which archives leave out otherwise
	includeGit: bool,
}

// What writing an archive did
ArchiveResult :: struct {
	// "" when it worked, else what went wrong
	problem: string,
	files: int,
	// Assets from outside the project folder, copied into assets/external/
	external: int,
	bytes: i64,
}

/*
Writes a project's archive.

Returns:
- What it did (`problem` temp allocated)
*/
ProjectArchive_Create :: proc(input: ArchiveInput) -> ArchiveResult {
	root := absolutePath(input.root)
	if !os.exists(joinPath(root, "project.xml", allocator = context.temp_allocator)) {
		return {problem = fmt.tprintf("%s has no project.xml", root)}
	}
	archive := absolutePath(input.archive)
	_ = os.make_directory_all(filepath.dir(archive))
	skip := make([dynamic]string, context.temp_allocator)
	for folder in ARCHIVE_SKIPPED_FOLDERS {
		if folder == ".git" && input.includeGit do continue
		append(&skip, joinPath(root, folder, allocator = context.temp_allocator))
	}
	for folder in input.skip do append(&skip, absolutePath(folder))

	relative := make([dynamic]string, context.temp_allocator)
	collectFiles(root, "", skip[:], archive, &relative)
	slice.sort(relative[:])

	// Assets outside the folder: into assets/external/, under names not taken yet
	rewrites := make([dynamic][2]string, context.temp_allocator)
	externals := make([dynamic][2]string, context.temp_allocator)
	taken := make(map[string]bool, allocator = context.temp_allocator)
	for path in relative do taken[path] = true
	for asset in input.assets {
		if !isOutside(asset) do continue
		source := filepath.is_abs(asset) ? asset : joinPath(root, asset, allocator = context.temp_allocator)
		if !os.exists(source) || os.is_dir(source) do continue
		known := false
		for r in rewrites do if r[0] == asset do known = true
		if known do continue
		base := filepath.base(source)
		name := fmt.tprintf("assets/external/%s", base)
		for i := 1; (name in taken); i += 1 {
			name = fmt.tprintf("assets/external/%s_%d%s", filepath.stem(base), i, filepath.ext(base))
		}
		taken[name] = true
		append(&rewrites, [2]string{asset, name})
		append(&externals, [2]string{name, source})
	}

	files := make([dynamic]ZipSource, context.temp_allocator)
	total: i64
	for path in relative {
		source := joinPath(root, path, allocator = context.temp_allocator)
		entry := ZipSource{name = fmt.tprintf("%s/%s", input.folder, path), path = source}
		if len(rewrites) > 0 && slice.contains(ARCHIVE_TEXT_EXTENSIONS, strings.to_lower(filepath.ext(path), context.temp_allocator)) {
			data, err := os.read_entire_file(source, context.temp_allocator)
			if err != nil do return {problem = fmt.tprintf("can't read %s: %v", path, err)}
			entry.data = transmute([]byte)rewritePaths(string(data), rewrites[:])
			entry.hasData = true
		}
		append(&files, entry)
		if info, err := os.stat(source, context.temp_allocator); err == nil do total += info.size
	}
	for external in externals {
		append(&files, ZipSource{name = fmt.tprintf("%s/%s", input.folder, external[0]), path = external[1]})
		if info, err := os.stat(external[1], context.temp_allocator); err == nil do total += info.size
	}
	if problem := Zip_Write(archive, files[:]); problem != "" do return {problem = problem}
	return {files = len(files), external = len(externals), bytes = total}
}

/*
Unpacks a project archive (or a zip of a project folder) into a new folder.

Inputs:
- archive: The archive
- parent: The folder to unpack into: the project becomes `<parent>/<its folder>`

Returns:
- The project's folder (temp allocated), how many files were written, and "" or what went wrong
*/
ProjectArchive_Extract :: proc(archive, parent: string) -> (root: string, files: int, problem: string) {
	data, err := os.read_entire_file(archive, context.temp_allocator)
	if err != nil do return "", 0, fmt.tprintf("can't read %s: %v", archive, err)
	entries, listProblem := Zip_List(data)
	if listProblem != "" do return "", 0, fmt.tprintf("%s: %s", filepath.base(archive), listProblem)
	for entry in entries {
		if !Zip_SafeName(entry.name) do return "", 0, fmt.tprintf("%s holds a file that would go outside its folder (%s)", filepath.base(archive), entry.name)
	}

	// One top folder holding project.xml (what Export Project Archive writes), or project.xml at the top
	prefix, folder := "", filepath.stem(archive)
	hasProject := false
	for entry in entries do if entry.name == "project.xml" do hasProject = true
	if !hasProject {
		top := ""
		for entry in entries {
			if strings.has_suffix(entry.name, "/project.xml") && strings.count(entry.name, "/") == 1 {
				top = entry.name[:len(entry.name) - len("/project.xml")]
				break
			}
		}
		if top == "" do return "", 0, fmt.tprintf("%s has no project in it (no project.xml)", filepath.base(archive))
		prefix, folder = fmt.tprintf("%s/", top), top
	}

	if !os.is_dir(parent) do return "", 0, fmt.tprintf("%s isn't a folder", parent)
	root = joinPath(parent, folder, allocator = context.temp_allocator)
	for i := 2; os.exists(root); i += 1 {
		root = joinPath(parent, fmt.tprintf("%s_%d", folder, i), allocator = context.temp_allocator)
	}
	if mkErr := os.make_directory_all(root); mkErr != nil do return "", 0, fmt.tprintf("can't create %s: %v", root, mkErr)
	for entry in entries {
		if !strings.has_prefix(entry.name, prefix) || strings.has_suffix(entry.name, "/") do continue
		name := entry.name[len(prefix):]
		bytes, readProblem := Zip_Read(data, entry)
		if readProblem != "" do return root, files, readProblem
		path := joinPath(root, name, allocator = context.temp_allocator)
		_ = os.make_directory_all(filepath.dir(path))
		if writeErr := os.write_entire_file(path, bytes); writeErr != nil {
			return root, files, fmt.tprintf("can't write %s: %v", path, writeErr)
		}
		files += 1
	}
	return root, files, ""
}

// What a worker thread needs to write an archive: ArchiveInput's strings, owned
ProjectArchive_Job :: struct {
	input: ArchiveInput,
}

/*
The archive's input for the open project, heap allocated for a worker (ProjectArchive_JobFree
frees it).
*/
ProjectArchive_Input :: proc(state: ^State, archive: string) -> ProjectArchive_Job {
	p := &state.project
	assets := make([]string, len(p.assets))
	for asset, i in p.assets do assets[i] = strings.clone(asset.path)
	skip := make([dynamic]string)
	for target in ExportTarget {
		settings := p.exports.targets[target]
		append(&skip, strings.clone(absolutePath(Export_OutputDir(p.rootPath, target, &settings, context.temp_allocator))))
	}
	return {input = {
		root = strings.clone(p.rootPath),
		folder = strings.clone(archiveFolderName(p)),
		archive = strings.clone(archive),
		assets = assets,
		skip = skip[:],
		includeGit = state.archive.includeGit,
	}}
}

// Frees ProjectArchive_Input's copies
ProjectArchive_JobFree :: proc(job: ProjectArchive_Job) {
	delete(job.input.root)
	delete(job.input.folder)
	delete(job.input.archive)
	for path in job.input.assets do delete(path)
	delete(job.input.assets)
	for path in job.input.skip do delete(path)
	delete(job.input.skip)
}

// Writing an archive finished (strings heap allocated: the handler frees them)
Project_Archive_Written :: struct {
	archive: string,
	result: ArchiveResult,
}

// Unpacking an archive finished (strings heap allocated: the handler frees them)
Project_Archive_Extracted :: struct {
	archive, root, problem: string,
	files: int,
}

// The archive and folder Open Project Archive unpacks, on a worker
@(private="file")
ExtractJob :: struct {
	archive, parent: string,
}

/*
Handles the project archive messages.

Returns:
- A command to run, and whether `m` was one
*/
ProjectArchive_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	archive := &state.archive
	#partial switch v in m {
	case Project_Archive_Path_Chosen:
		if v.cancelled || v.path == "" do return {}, true
		if archive.busy {
			logLine(state, .Warning, strings.clone("An archive is being written or unpacked already"))
			return {}, true
		}
		path := v.path
		if strings.to_lower(filepath.ext(path), context.temp_allocator) != "." + PROJECT_ARCHIVE_EXTENSION {
			path = fmt.tprintf("%s.%s", path, PROJECT_ARCHIVE_EXTENSION)
		}
		// The archive holds what's on disk: save first
		if !Session_Save(state) do return {}, true
		archive.busy = true
		logLine(state, .Info, fmt.aprintf("Writing the project archive %s...", path))
		return skald.cmd_thread(Msg, ProjectArchive_Input(state, path), proc(job: ProjectArchive_Job) -> Msg {
			defer ProjectArchive_JobFree(job)
			result := ProjectArchive_Create(job.input)
			result.problem = strings.clone(result.problem)
			return Project_Archive_Written{archive = strings.clone(job.input.archive), result = result}
		}), true
	case Project_Archive_Written:
		archive.busy = false
		defer {
			delete(v.archive)
			delete(v.result.problem)
		}
		if v.result.problem != "" {
			logLine(state, .Error, fmt.aprintf("Export Project Archive failed: %s", v.result.problem))
			break
		}
		logLine(state, .Info, fmt.aprintf("Wrote the project archive %s (%d files, %s)", v.archive, v.result.files, archiveSize(v.result.bytes)))
		if v.result.external > 0 {
			logLine(state, .Info, fmt.aprintf("%d asset%s from outside the project folder went into the archive's assets/external/", v.result.external, v.result.external == 1 ? "" : "s"))
		}
	case Project_Archive_Open_Chosen:
		if v.cancelled || v.path == "" do return {}, true
		delete(archive.openPath)
		archive.openPath = strings.clone(v.path)
		// Then where to unpack it: next to it by default
		return skald.cmd_open_folder_dialog(proc(r: skald.File_Dialog_Result) -> Msg { return Project_Archive_Destination_Chosen(r) },
			default_location = filepath.dir(v.path)), true
	case Project_Archive_Destination_Chosen:
		if v.cancelled || v.path == "" || archive.openPath == "" do return {}, true
		if archive.busy {
			logLine(state, .Warning, strings.clone("An archive is being written or unpacked already"))
			return {}, true
		}
		archive.busy = true
		logLine(state, .Info, fmt.aprintf("Unpacking %s into %s...", archive.openPath, v.path))
		job := ExtractJob{archive = strings.clone(archive.openPath), parent = strings.clone(v.path)}
		return skald.cmd_thread(Msg, job, proc(job: ExtractJob) -> Msg {
			root, files, problem := ProjectArchive_Extract(job.archive, job.parent)
			delete(job.parent)
			return Project_Archive_Extracted{archive = job.archive, root = strings.clone(root), problem = strings.clone(problem), files = files}
		}), true
	case Project_Archive_Extracted:
		archive.busy = false
		defer {
			delete(v.archive)
			delete(v.root)
			delete(v.problem)
		}
		if v.problem != "" {
			logLine(state, .Error, fmt.aprintf("Open Project Archive failed: %s", v.problem))
			break
		}
		logLine(state, .Info, fmt.aprintf("Unpacked %s into %s (%d files)", filepath.base(v.archive), v.root, v.files))
		Session_OpenProject(state, v.root)
	case:
		return {}, false
	}
	return {}, true
}

// Asks where to write the open project's archive (File > Export Project Archive..., or with
// History: `.git/` too)
ProjectArchive_Export :: proc(state: ^State, includeGit := false) -> skald.Command(Msg) {
	state.archive.includeGit = includeGit
	location := joinPath(filepath.dir(absolutePath(state.project.rootPath)),
		fmt.tprintf("%s.%s", archiveFolderName(&state.project), PROJECT_ARCHIVE_EXTENSION), allocator = context.temp_allocator)
	return skald.cmd_save_file_dialog(ARCHIVE_FILTERS, proc(r: skald.File_Dialog_Result) -> Msg { return Project_Archive_Path_Chosen(r) },
		default_location = location)
}

// Asks for an archive to open (File > Open Project Archive..., after the unsaved-changes prompt)
ProjectArchive_Open :: proc(state: ^State) -> skald.Command(Msg) {
	return skald.cmd_open_file_dialog(OPEN_ARCHIVE_FILTERS, proc(r: skald.File_Dialog_Result) -> Msg { return Project_Archive_Open_Chosen(r) },
		default_location = filepath.dir(absolutePath(state.project.rootPath)))
}

/*
Unpacks an archive given on the command line (`odin_sdl_editor game.odinsdl`) next to it, as Open
Project Archive would into the archive's folder.

Returns:
- The unpacked project's folder (temp allocated), or "" and why not
*/
ProjectArchive_ExtractArgument :: proc(archive: string) -> (root: string, problem: string) {
	unpacked, _, message := ProjectArchive_Extract(archive, filepath.dir(absolutePath(archive)))
	return unpacked, message
}

// Whether a command-line path is a project archive (opened by unpacking it)
ProjectArchive_IsArchivePath :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	return ext == "." + PROJECT_ARCHIVE_EXTENSION || ext == ".zip"
}

// The archive's folder: the project folder's name (what unpacking it recreates)
@(private="file")
archiveFolderName :: proc(project: ^Project) -> string {
	name := filepath.base(absolutePath(project.rootPath))
	if name == "" || name == "." || name == "/" do name = project.name
	return name
}

// Every file under a folder (relative, "/"-separated), leaving out what archives skip
@(private="file")
collectFiles :: proc(root, relative: string, skip: []string, archive: string, out: ^[dynamic]string) {
	folder := relative == "" ? root : joinPath(root, relative, allocator = context.temp_allocator)
	infos, err := os.read_directory_by_path(folder, -1, context.temp_allocator)
	if err != nil do return
	for info in infos {
		path := relative == "" ? info.name : fmt.tprintf("%s/%s", relative, info.name)
		full := joinPath(root, path, allocator = context.temp_allocator)
		#partial switch info.type {
		case .Directory:
			skipped := false
			for s in skip do if full == s do skipped = true
			if !skipped do collectFiles(root, path, skip, archive, out)
		case .Regular:
			if slice.contains(ARCHIVE_SKIPPED_FILES, info.name) || full == archive || strings.has_suffix(info.name, ".partial") do continue
			append(out, path)
		}
	}
}

// Whether an asset path points outside the project folder
@(private="file")
isOutside :: proc(path: string) -> bool {
	return filepath.is_abs(path) || path == ".." || strings.has_prefix(path, "../") || strings.has_prefix(path, "..\\")
}

// A file's text with each quoted old path (plain or XML-escaped) replaced by its new one
@(private="file")
rewritePaths :: proc(text: string, rewrites: [][2]string) -> string {
	result := text
	for r in rewrites {
		forms := [2][2]string{{r[0], r[1]}, {EscapeXML(r[0], context.temp_allocator), EscapeXML(r[1], context.temp_allocator)}}
		for form in forms {
			result, _ = strings.replace_all(result, fmt.tprintf("\"%s\"", form[0]), fmt.tprintf("\"%s\"", form[1]), context.temp_allocator)
		}
	}
	return result
}

// "1.2 MB", "340 KB"
@(private="file")
archiveSize :: proc(size: i64) -> string {
	if size >= 1024 * 1024 do return fmt.tprintf("%.1f MB", f64(size) / (1024 * 1024))
	return fmt.tprintf("%d KB", (size + 1023) / 1024)
}
