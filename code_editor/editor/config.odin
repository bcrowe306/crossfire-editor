// User configuration: the host points the editor at a config directory
// (editor_set_config_dir); the editor keeps its settings there —
// keymap.json holds the user's key bindings as overrides of the defaults
// ({"bind": {chord: action}, "unbind": [chord]}). With no config dir
// nothing is persisted.
//
// Key bindings can also be imported from Zed (~/.config/zed/keymap.json)
// or VSCode (keybindings.json in the platform's Code/User directory); the
// result is merged into the current keymap and saved.
package code_editor

import km "../keymap"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

KEYMAP_FILE :: "keymap.json"

Keymap_Source :: enum {
	Zed,
	VSCode,
}

Config :: struct {
	dir: string, // owned; "" = don't persist
	// Host overrides for where imports read from ("" = the default path).
	import_paths: [Keymap_Source]string,
	// Result of the last import (for the status line and the hook).
	last_import: string,
}

config_destroy :: proc(c: ^Config) {
	delete(c.dir)
	for p in c.import_paths {
		delete(p)
	}
	delete(c.last_import)
}

// editor_set_config_dir sets (and creates) the config directory and loads
// the settings stored there.
editor_set_config_dir :: proc(ed: ^Editor, dir: string) {
	delete(ed.config.dir)
	ed.config.dir = strings.clone(dir)
	if len(dir) == 0 {
		return
	}
	_ = os.make_directory_all(dir)
	editor_load_keymap(ed)
	editor_load_theme(ed)
}

// editor_set_import_path overrides where an import reads from.
editor_set_import_path :: proc(ed: ^Editor, src: Keymap_Source, path: string) {
	delete(ed.config.import_paths[src])
	ed.config.import_paths[src] = strings.clone(path)
}

@(private)
config_path :: proc(ed: ^Editor, name: string) -> string {
	if len(ed.config.dir) == 0 {
		return ""
	}
	p, _ := filepath.join({ed.config.dir, name}, context.temp_allocator)
	return p
}

// editor_load_keymap resets the keymap to the defaults plus the saved
// overrides.
editor_load_keymap :: proc(ed: ^Editor) -> bool {
	km.keymap_destroy(&ed.keymap)
	ed.keymap = km.keymap_default(ed.platform)
	path := config_path(ed, KEYMAP_FILE)
	if len(path) == 0 || !os.exists(path) {
		return false
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	return km.keymap_apply_overrides(&ed.keymap, string(data))
}

// editor_save_keymap writes the keymap's differences from the defaults.
editor_save_keymap :: proc(ed: ^Editor) -> bool {
	path := config_path(ed, KEYMAP_FILE)
	if len(path) == 0 {
		return false
	}
	defaults := km.keymap_default(ed.platform, context.temp_allocator)
	text := km.keymap_overrides_json(&ed.keymap, &defaults, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

// default_import_path: where Zed / VSCode keep the user's key bindings.
default_import_path :: proc(src: Keymap_Source) -> string {
	home, _ := os.user_home_dir(context.temp_allocator)
	switch src {
	case .Zed:
		when ODIN_OS == .Windows {
			appdata := os.get_env("APPDATA", context.temp_allocator)
			p, _ := filepath.join({appdata, "Zed", "keymap.json"}, context.temp_allocator)
			return p
		} else {
			p, _ := filepath.join({home, ".config", "zed", "keymap.json"}, context.temp_allocator)
			return p
		}
	case .VSCode:
		when ODIN_OS == .Darwin {
			p, _ := filepath.join({home, "Library", "Application Support", "Code", "User", "keybindings.json"}, context.temp_allocator)
			return p
		} else when ODIN_OS == .Windows {
			appdata := os.get_env("APPDATA", context.temp_allocator)
			p, _ := filepath.join({appdata, "Code", "User", "keybindings.json"}, context.temp_allocator)
			return p
		} else {
			p, _ := filepath.join({home, ".config", "Code", "User", "keybindings.json"}, context.temp_allocator)
			return p
		}
	}
	return ""
}

// editor_import_keymap merges the Zed/VSCode bindings into the keymap,
// saves it, and reports what happened on the status line.
editor_import_keymap :: proc(ed: ^Editor, src: Keymap_Source) -> bool {
	name := "Zed" if src == .Zed else "VSCode"
	path := ed.config.import_paths[src]
	if len(path) == 0 {
		path = default_import_path(src)
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		editor_report_import(ed, fmt.tprintf("No %s keymap at %s", name, path))
		return false
	}
	report: km.Import_Report
	ok: bool
	switch src {
	case .Zed:
		report, ok = km.keymap_import_zed(&ed.keymap, string(data))
	case .VSCode:
		report, ok = km.keymap_import_vscode(&ed.keymap, string(data))
	}
	if !ok {
		editor_report_import(ed, fmt.tprintf("Could not parse %s", path))
		return false
	}
	editor_save_keymap(ed)
	editor_report_import(ed, import_summary(name, report))
	return true
}

@(private)
editor_report_import :: proc(ed: ^Editor, msg: string) {
	delete(ed.config.last_import)
	ed.config.last_import = strings.clone(msg)
	editor_set_status(ed, msg)
}

// import_summary: "Imported from Zed: 3 bound, 1 removed, 2 unsupported
// (editor::ToggleFocus, ...), 1 key sequence skipped".
import_summary :: proc(name: string, r: km.Import_Report) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "Imported from %s: %d bound", name, r.bound)
	if r.unbound > 0 {
		fmt.sbprintf(&sb, ", %d removed", r.unbound)
	}
	if r.unknown > 0 {
		fmt.sbprintf(&sb, ", %d unsupported", r.unknown)
		if len(r.unknown_names) > 0 {
			strings.write_string(&sb, " (")
			for n, i in r.unknown_names {
				if i > 0 {
					strings.write_string(&sb, ", ")
				}
				strings.write_string(&sb, n)
			}
			if r.unknown > len(r.unknown_names) {
				strings.write_string(&sb, ", ...")
			}
			strings.write_string(&sb, ")")
		}
	}
	if r.sequences > 0 {
		fmt.sbprintf(&sb, ", %d key sequence%s skipped", r.sequences, "" if r.sequences == 1 else "s")
	}
	if r.skipped > 0 {
		fmt.sbprintf(&sb, ", %d other-context binding%s skipped", r.skipped, "" if r.skipped == 1 else "s")
	}
	return strings.to_string(sb)
}
