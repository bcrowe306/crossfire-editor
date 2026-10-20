package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

/*
Running from a macOS app bundle (`Crossfire Editor.app`, made by Taskfile.macos.yml): the
editor's executable is in `Contents/MacOS`, beside OLS and the prebuilt player; the engine's
sources are in `Contents/Resources/engine`; the Vulkan loader and MoltenVK are in
`Contents/Frameworks`. A bundle is read-only (it's signed, and usually in /Applications), and an
app started from the Finder runs in `/`, so `Editor_SetupBundle`, first thing in `main`:

- makes the editor's data folder (`Toolchain_DataDir`: `~/Library/Application Support/
  crossfire-editor`) the working folder: Play's and Export's `build/` folders go there;
- keeps the settings there (`Settings_DefaultPath`), not next to the executable;
- puts the demo project in `~/Documents/Crossfire Editor/demo_project` (`Editor_DemoProject`),
  copied there on first run from the bundle's `Contents/Resources/demo_project`
  (`Editor_ShippedDemo`);
- points SDL at the bundled Vulkan loader (`SDL_VULKAN_LIBRARY`) and the loader at the bundled
  MoltenVK driver (`VK_DRIVER_FILES` / `VK_ICD_FILENAMES`, unless they're set already), so nothing
  needs installing.

Outside a bundle none of this happens: the editor works from the folder it's started in, as
before.
*/

// The bundle's Contents folder, when the editor runs from one (temp allocated)
Editor_BundleContents :: proc() -> (string, bool) {
	exeDir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do return "", false
	exeDir = strings.trim_right(exeDir, "/")
	if !strings.has_suffix(exeDir, ".app/Contents/MacOS") do return "", false
	return filepath.dir(exeDir), true
}

// The folder the editor was started in (before Editor_SetupBundle moved to its data folder), for
// relative paths on the command line
launchDir: string

// Sets up running from an app bundle (see above); nothing outside one
Editor_SetupBundle :: proc() {
	contents, inBundle := Editor_BundleContents()
	if !inBundle do return
	if cwd, err := os.get_working_directory(context.temp_allocator); err == nil do launchDir = strings.clone(cwd)
	if data := Toolchain_DataDir(); data != "" {
		_ = os.make_directory_all(data)
		_ = os.set_working_directory(data)
	}
	setupBundleVulkan(contents)
}

/*
The project opened when none is given: in ~/Documents/Crossfire Editor from a bundle (copied
there from the bundle on first run: `Editor_ShippedDemo`); the demo shipped beside the
executable (a release archive's examples/demo_project); else examples/demo_project in the
working folder (a checkout).
*/
Editor_DemoProject :: proc() -> string {
	if _, inBundle := Editor_BundleContents(); inBundle {
		if home, err := os.user_home_dir(context.temp_allocator); err == nil {
			return filepath.join({home, "Documents", "Crossfire Editor", "demo_project"}, context.allocator) or_else DEMO_PROJECT
		}
	}
	if exeDir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		beside := filepath.join({exeDir, DEMO_PROJECT}, context.temp_allocator) or_else ""
		if beside != "" && os.exists(filepath.join({beside, "project.xml"}, context.temp_allocator) or_else "") {
			return strings.clone(beside)
		}
	}
	return DEMO_PROJECT
}

// The demo project a bundle carries (`Contents/Resources/demo_project`), to copy where it can be
// edited; "" outside a bundle or when it has none (temp allocated)
Editor_ShippedDemo :: proc() -> string {
	contents, inBundle := Editor_BundleContents()
	if !inBundle do return ""
	path := filepath.join({contents, "Resources", "demo_project"}, context.temp_allocator) or_else ""
	if path == "" || !os.exists(filepath.join({path, "project.xml"}, context.temp_allocator) or_else "") do return ""
	return path
}

/*
Copies a folder, with everything in it, to `to` (made, with its parents). Existing files are
replaced.

Returns:
- What went wrong ("" when nothing did; temp allocated)
*/
Folder_Copy :: proc(from, to: string) -> string {
	if err := os.make_directory_all(to); err != nil do return fmt.tprintf("couldn't make %s: %v", to, err)
	entries, err := os.read_all_directory_by_path(from, context.temp_allocator)
	if err != nil do return fmt.tprintf("couldn't read %s: %v", from, err)
	for entry in entries {
		target := filepath.join({to, entry.name}, context.temp_allocator) or_else ""
		if entry.type == .Directory {
			if problem := Folder_Copy(entry.fullpath, target); problem != "" do return problem
		} else if copyErr := os.copy_file(target, entry.fullpath); copyErr != nil {
			return fmt.tprintf("couldn't copy %s: %v", entry.fullpath, copyErr)
		}
	}
	return ""
}

// A path from the command line (or a UI test script), made absolute against the folder the
// editor was started in: from a bundle the working folder is the data folder by then (allocated)
Editor_ArgumentPath :: proc(path: string) -> string {
	if launchDir == "" || filepath.is_abs(path) do return strings.clone(path)
	return filepath.join({launchDir, path}, context.allocator) or_else path
}
