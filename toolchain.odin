package editor

import "core:fmt"
import "core:os"
import "core:strings"
import "gui:skald"
import sdl "vendor:sdl3"

/*
The toolchain: what building a game needs, found at run time.

- **Odin** (`Toolchain_Odin`): Settings > Toolchain's path, else `odin` in PATH, else the one the
  editor installed (`Toolchain_InstallOdin`: the pinned release, `ODIN_VERSION`, downloaded with
  curl and unpacked with tar into the editor's data folder, `Toolchain_DataDir`).
- **The engine's sources** (`Toolchain_EngineDir`): `ENGINE_DIR` (the checkout the editor was built
  with), else `engine/` next to the editor (a release ships it).
- **A linker:** Odin links through `clang` on Linux and macOS (Xcode's command line tools on
  macOS), and through Visual Studio's linker on Windows (its Build Tools). Neither can ship with
  the editor; Settings > Toolchain says how to get them.
- **Prebuilt players** (`Toolchain_PrebuiltPlayer`): `prebuilt/<target>/player` next to the editor
  (releases have them). A project without scripts plays and exports with one: no compiler at all.

`Toolchain_Check` lists them for Settings > Toolchain.
*/

// The Odin release the engine and editor are built with (the one the editor installs)
ODIN_VERSION :: "dev-2026-10"

// One thing the toolchain needs, as Settings > Toolchain shows it
ToolStatus :: struct {
	name: string,
	found: bool,
	// Where it is ("" when missing)
	path: string,
	// What it's for, or how to get it when it's missing
	note: string,
}

/*
The odin compiler to build with: the setting, else `odin` in PATH, else the installed one.

Returns:
- Its path, or "" when there's none (temp allocated)
*/
Toolchain_Odin :: proc(setting: string) -> string {
	if setting != "" {
		found, ok := Script_FindEditorProgram(setting)
		return ok ? found : ""
	}
	if found, ok := Script_FindEditorProgram("odin"); ok do return found
	return Toolchain_InstalledOdin()
}

// The odin the editor installed, or "" (temp allocated)
Toolchain_InstalledOdin :: proc() -> string {
	root := joinPath(Toolchain_DataDir(), "odin", ODIN_VERSION, allocator = context.temp_allocator)
	return findOdinBinary(root)
}

// The editor's data folder: the OS's per-user application data (SDL's pref path; temp allocated)
Toolchain_DataDir :: proc() -> string {
	raw := sdl.GetPrefPath("", "odin_sdl_editor")
	if raw == nil do return ""
	defer sdl.free(raw)
	return strings.trim_right(strings.clone(string(cstring(raw)), context.temp_allocator), "/\\")
}

/*
The engine's sources: the checkout the editor was built with, else `engine/` next to the editor.

Returns:
- The folder (absolute when found; temp allocated), and whether it has the engine
*/
Toolchain_EngineDir :: proc() -> (string, bool) {
	if os.exists(joinPath(ENGINE_DIR, "player", allocator = context.temp_allocator)) do return absolutePath(ENGINE_DIR), true
	if exeDir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		bundled := joinPath(exeDir, "engine", allocator = context.temp_allocator)
		if os.exists(joinPath(bundled, "player", allocator = context.temp_allocator)) do return bundled, true
		// A macOS app bundle keeps it in Contents/Resources (bundle.odin)
		resources := joinPath(exeDir, "..", "Resources", "engine", allocator = context.temp_allocator)
		if os.exists(joinPath(resources, "player", allocator = context.temp_allocator)) do return absolutePath(resources), true
	}
	return absolutePath(ENGINE_DIR), false
}

/*
A prebuilt player for a desktop target: `prebuilt/<target>/player` (`.exe` for Windows) next to the
editor. Projects without scripts play and export with it, without compiling.

Returns:
- Its path, or "" (temp allocated)
*/
Toolchain_PrebuiltPlayer :: proc(target: ExportTarget) -> string {
	exeDir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do return ""
	name := target == .Windows_x64 || target == .Windows_ARM64 ? "player.exe" : "player"
	path := joinPath(exeDir, "prebuilt", Toolchain_TargetFolder(target), name, allocator = context.temp_allocator)
	return os.exists(path) ? path : ""
}

// A target's folder name for prebuilt players: "linux_x64", "windows_x64", "macos_arm64"
Toolchain_TargetFolder :: proc(target: ExportTarget) -> string {
	return strings.to_lower(fmt.tprint(target), context.temp_allocator)
}

/*
The desktop target this editor runs on (Linux_x64 on Linux x86_64...), and whether it is one: from
what the editor was compiled for, not from which exports are implemented (on a Mac, where no
export is yet, it once found no host, so Play never used the bundle's prebuilt player).
*/
Toolchain_HostTarget :: proc() -> (ExportTarget, bool) {
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 do return .Linux_x64, true
	when ODIN_OS == .Linux && ODIN_ARCH == .arm64 do return .Linux_ARM64, true
	when ODIN_OS == .Windows && ODIN_ARCH == .amd64 do return .Windows_x64, true
	when ODIN_OS == .Windows && ODIN_ARCH == .arm64 do return .Windows_ARM64, true
	when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 do return .macOS_x64, true
	when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 do return .macOS_ARM64, true
	return .Linux_x64, false
}

// Everything building games needs, found or not, for Settings > Toolchain
Toolchain_Check :: proc(settings: ^Settings) -> []ToolStatus {
	list := make([dynamic]ToolStatus, context.temp_allocator)
	odin := Toolchain_Odin(FixedText_String(&settings.odinPath))
	installed := Toolchain_InstalledOdin()
	odinNote := fmt.tprintf("Builds games with scripts. The engine uses Odin %s: Install puts it in the editor's data folder.", ODIN_VERSION)
	if odin != "" && odin == installed do odinNote = fmt.tprintf("Odin %s, installed by the editor.", ODIN_VERSION)
	append(&list, ToolStatus{"Odin compiler", odin != "", odin, odinNote})

	engine, engineFound := Toolchain_EngineDir()
	append(&list, ToolStatus{"Engine sources", engineFound, engineFound ? engine : "",
		engineFound ? "The engine games are built from." : "Not found at ../odin_sdl_engine or engine/ next to the editor: git clone --recursive https://github.com/bcrowe306/odin_sdl_engine"})

	when ODIN_OS == .Windows {
		vswhere := "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
		found := os.exists(vswhere)
		append(&list, ToolStatus{"Linker (Visual Studio)", found, found ? vswhere : "",
			found ? "Odin finds Visual Studio's linker and the Windows SDK itself." : "Install Visual Studio Build Tools with the \"Desktop development with C++\" workload."})
	} else {
		clang, found := Script_FindEditorProgram("clang")
		fix := ODIN_OS == .Darwin ? "Install Xcode's command line tools: xcode-select --install" : "Install clang with your package manager (e.g. sudo apt install clang, sudo pacman -S clang)."
		append(&list, ToolStatus{"Linker (clang)", found, found ? clang : "", found ? "Odin links games through it." : fix})
	}

	if host, ok := Toolchain_HostTarget(); ok {
		prebuilt := Toolchain_PrebuiltPlayer(host)
		append(&list, ToolStatus{"Prebuilt player", prebuilt != "", prebuilt,
			prebuilt != "" ? "Projects without scripts play and export with it, without compiling." : "None next to the editor (releases have one): projects without scripts are compiled like the others."})
	}
	if engineFound {
		host, _ := Toolchain_HostTarget()
		static := Export_StaticSDLBuilt(engine, host)
		append(&list, ToolStatus{"Static SDL", static, static ? joinPath(engine, "sdl", "lib", allocator = context.temp_allocator) : "",
			static ? "Linked into games: they're one file." : "Games need the SDL3 libraries beside them. Build it with the engine's tools/build_sdl_static.sh (CMake)."})
	}
	git, gitFound := Script_FindEditorProgram("git")
	append(&list, ToolStatus{"Git", gitFound, gitFound ? git : "", gitFound ? "Version control for your projects (the Git tab)." : "Optional: version control in the Git tab. Install it from git-scm.com or your package manager."})
	ols := Code_FindOLS(FixedText_String(&settings.olsPath))
	append(&list, ToolStatus{"Odin language server", ols != "", ols, ols != "" ? "Completion and diagnostics in the code editor." : "Optional: completion and diagnostics in the code editor (ols in PATH, or task ols)."})
	return list[:]
}

// What an Odin install did (Toolchain_InstallOdin), as a message
Toolchain_Install_Finished :: struct {
	// "" when it worked, else what went wrong (heap allocated: update frees it)
	problem: string,
	path: string,
}

/*
Downloads the pinned Odin release (curl) and unpacks it (tar) into the editor's data folder, on a
worker thread. Sends Toolchain_Install_Finished.
*/
Toolchain_InstallOdin :: proc() -> skald.Command(Msg) {
	Job :: struct {
		url, archive, folder: string,
	}
	platform := ""
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 do platform = "linux-amd64"
	when ODIN_OS == .Linux && ODIN_ARCH == .arm64 do platform = "linux-arm64"
	when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 do platform = "macos-arm64"
	when ODIN_OS == .Windows && ODIN_ARCH == .amd64 do platform = "windows-amd64"
	if platform == "" do return skald.cmd_now(Msg(Toolchain_Install_Finished{problem = strings.clone("Odin has no release for this OS and CPU")}))
	extension := ODIN_OS == .Windows ? "zip" : "tar.gz"
	folder := joinPath(Toolchain_DataDir(), "odin", ODIN_VERSION, allocator = context.temp_allocator)
	job := Job{
		url = fmt.aprintf("https://github.com/odin-lang/Odin/releases/download/%s/odin-%s-%s.%s", ODIN_VERSION, platform, ODIN_VERSION, extension),
		archive = strings.clone(joinPath(Toolchain_DataDir(), fmt.tprintf("odin-%s.%s", ODIN_VERSION, extension), allocator = context.temp_allocator)),
		folder = strings.clone(folder),
	}
	return skald.cmd_thread(Msg, job, proc(job: Job) -> Msg {
		defer {
			delete(job.url)
			delete(job.archive)
		}
		if err := os.make_directory_all(job.folder); err != nil && !os.exists(job.folder) {
			return Toolchain_Install_Finished{problem = fmt.aprintf("Couldn't create %s", job.folder)}
		}
		run :: proc(command: []string) -> string {
			state, _, stderr, err := os.process_exec({command = command}, context.temp_allocator)
			if err != nil do return fmt.aprintf("Couldn't run %s: %v", command[0], err)
			// The exit code, not state.success: Odin's Windows process_wait always sets that
			if state.exit_code != 0 do return fmt.aprintf("%s failed: %s", command[0], strings.trim_space(string(stderr)))
			return ""
		}
		if problem := run({"curl", "-fL", "--silent", "--show-error", "-o", job.archive, job.url}); problem != "" {
			return Toolchain_Install_Finished{problem = problem}
		}
		defer os.remove(job.archive)
		if problem := run({"tar", "-xf", job.archive, "-C", job.folder}); problem != "" {
			return Toolchain_Install_Finished{problem = problem}
		}
		binary := findOdinBinary(job.folder)
		if binary == "" do return Toolchain_Install_Finished{problem = fmt.aprintf("No odin program in the download (%s)", job.folder)}
		when ODIN_OS != .Windows do _ = os.chmod(binary, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})
		return Toolchain_Install_Finished{path = strings.clone(binary)}
	})
}

// The odin program in an unpacked release: in the folder, or one folder down (temp allocated)
@(private="file")
findOdinBinary :: proc(root: string) -> string {
	name := ODIN_OS == .Windows ? "odin.exe" : "odin"
	direct := joinPath(root, name, allocator = context.temp_allocator)
	if os.exists(direct) && !os.is_dir(direct) do return direct
	handle, err := os.open(root)
	if err != nil do return ""
	defer os.close(handle)
	entries, _ := os.read_dir(handle, -1, context.temp_allocator)
	for entry in entries {
		if entry.type != .Directory do continue
		candidate := joinPath(entry.fullpath, name, allocator = context.temp_allocator)
		if os.exists(candidate) && !os.is_dir(candidate) do return candidate
	}
	return ""
}
