package editor

import "core:encoding/ini"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "gui:skald"

/*
Editor settings: appearance, undo behaviour and the keymap.

	settings.default.ini   the defaults, in source control and built into the editor (#load)
	editor.ini             the user's settings, saved next to the executable by the Settings dialog

Loading parses the defaults, then the user's file over them, so a setting missing from
editor.ini (one added in a newer version, say) keeps its default. Saving writes every setting.

`Settings` is a plain value with no allocations, so the Settings dialog edits a copy and Cancel
just drops it.
*/

SETTINGS_DEFAULT_INI :: #load("settings.default.ini", string)
// The user's settings file, next to the executable
SETTINGS_FILE_NAME :: "editor.ini"

ThemeChoice :: enum {
	Dark,
	Light,
}

Settings :: struct {
	// [appearance]
	theme: ThemeChoice,
	// Body text size (Skald's `size_md`); the other sizes scale with it
	fontSize: f32,
	// Percent of Skald's default spacing scale
	spacing: f32,
	// Browser and scene tree row height
	rowHeight: f32,

	// [editor]
	// Same-target edits closer together than this merge into one undo step (debounce)
	undoMergeMs: int,
	// A merged run is cut after this long, 0 = never (throttle)
	undoGroupMaxMs: int,
	undoLimit: int,
	// Viewport grid spacing, world units
	gridSize: int,
	// The command that opens a script: {file} and {line} are replaced ("zed {file}:{line}")
	codeEditor: FixedText,
	// Build players for Play with -o:speed (about 50 s instead of 4 s per build)
	optimizedPlay: bool,

	// [keymap]
	keymap: Keymap,
}

// Limits the Settings dialog and the loader keep values within
SETTINGS_FONT_SIZE_RANGE :: [2]f32{9, 24}
SETTINGS_SPACING_RANGE :: [2]f32{25, 200}
SETTINGS_ROW_HEIGHT_RANGE :: [2]f32{18, 48}
SETTINGS_UNDO_MS_RANGE :: [2]int{0, 10000}
SETTINGS_UNDO_LIMIT_RANGE :: [2]int{1, 10000}
SETTINGS_GRID_SIZE_RANGE :: [2]int{2, 1024}

/*
Text stored inline, so `Settings` stays a plain value that can be copied (the Settings dialog edits
a copy). Longer text is cut at FIXED_TEXT_SIZE bytes.
*/
FixedText :: struct {
	buffer: [FIXED_TEXT_SIZE]u8,
	length: int,
}

FIXED_TEXT_SIZE :: 256

FixedText_Make :: proc(text: string) -> FixedText {
	t: FixedText
	t.length = copy(t.buffer[:], text)
	return t
}

/*
The text, pointing into `t`. It's only valid as long as `t` is: copy it before handing it to a view
(a view's state is a copy that's gone by the time Skald draws).
*/
FixedText_String :: proc(t: ^FixedText) -> string {
	return string(t.buffer[:t.length])
}

/*
The default settings, from `settings.default.ini`.
*/
Settings_Default :: proc() -> Settings {
	settings: Settings
	_ = Settings_Parse(&settings, SETTINGS_DEFAULT_INI)
	return settings
}

/*
Applies an ini file's values over `settings`. Unknown sections and keys, and values that don't
parse, are skipped and reported.

Inputs:
- settings: Settings to update
- text: The ini file's contents

Returns:
- One message per problem (temp allocated), empty if the file was fine
*/
Settings_Parse :: proc(settings: ^Settings, text: string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	problem :: proc(problems: ^[dynamic]string, section, key, value, why: string) {
		append(problems, fmt.tprintf("[%s] %s = %s: %s", section, key, value, why))
	}

	it := ini.iterator_from_string(text)
	for key, value in ini.iterate(&it) {
		switch it.section {
		case "appearance":
			switch key {
			case "theme":
				switch strings.to_lower(value, context.temp_allocator) {
				case "dark":  settings.theme = .Dark
				case "light": settings.theme = .Light
				case: problem(&problems, it.section, key, value, "expected dark or light")
				}
			case "font_size":  parseNumber(&settings.fontSize, SETTINGS_FONT_SIZE_RANGE, it.section, key, value, &problems)
			case "spacing":    parseNumber(&settings.spacing, SETTINGS_SPACING_RANGE, it.section, key, value, &problems)
			case "row_height": parseNumber(&settings.rowHeight, SETTINGS_ROW_HEIGHT_RANGE, it.section, key, value, &problems)
			case: problem(&problems, it.section, key, value, "unknown setting")
			}
		case "editor":
			target: ^int
			limits: [2]int
			switch key {
			case "undo_merge_ms":     target, limits = &settings.undoMergeMs, SETTINGS_UNDO_MS_RANGE
			case "undo_group_max_ms": target, limits = &settings.undoGroupMaxMs, SETTINGS_UNDO_MS_RANGE
			case "undo_limit":        target, limits = &settings.undoLimit, SETTINGS_UNDO_LIMIT_RANGE
			case "grid_size":         target, limits = &settings.gridSize, SETTINGS_GRID_SIZE_RANGE
			case "code_editor":
				settings.codeEditor = FixedText_Make(value)
				continue
			case "optimized_play":
				switch strings.to_lower(value, context.temp_allocator) {
				case "true":  settings.optimizedPlay = true
				case "false": settings.optimizedPlay = false
				case: problem(&problems, it.section, key, value, "expected true or false")
				}
				continue
			case:
				problem(&problems, it.section, key, value, "unknown setting")
				continue
			}
			if n, ok := strconv.parse_int(value); ok {
				target^ = clamp(n, limits[0], limits[1])
			} else {
				problem(&problems, it.section, key, value, "expected a whole number")
			}
		case "keymap":
			action, known := reflect.enum_from_name(Action, key)
			if !known {
				problem(&problems, it.section, key, value, "unknown action")
				continue
			}
			chords: [KEYMAP_SLOTS]skald.Shortcut
			parts := strings.split(value, "|", context.temp_allocator)
			valid := true
			for part, i in parts {
				text := strings.trim_space(part)
				if text == "" do continue
				chord, ok := Shortcut_Parse(text)
				if !ok || i >= KEYMAP_SLOTS {
					problem(&problems, it.section, key, value, ok ? "too many chords" : fmt.tprintf("can't read '%s'", text))
					valid = false
					break
				}
				chords[i] = chord
			}
			if valid do settings.keymap[action] = chords
		case:
			problem(&problems, it.section, key, value, "unknown section")
		}
	}
	return problems[:]
}

@(private="file")
parseNumber :: proc(target: ^f32, limits: [2]f32, section, key, value: string, problems: ^[dynamic]string) {
	if n, ok := strconv.parse_f32(value); ok {
		target^ = clamp(n, limits[0], limits[1])
	} else {
		append(problems, fmt.tprintf("[%s] %s = %s: expected a number", section, key, value))
	}
}

/*
The settings as an ini file, with every setting written out.

Returns:
- The file's contents (temp allocated)
*/
Settings_ToINI :: proc(settings: ^Settings) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "; Odin SDL Editor settings, saved by the Settings dialog (Edit > Settings).\n")
	strings.write_string(&b, "; Defaults and what each setting means: settings.default.ini in the editor's source.\n\n")
	fmt.sbprintf(&b, "[appearance]\ntheme = %s\nfont_size = %v\nspacing = %v\nrow_height = %v\n\n",
		settings.theme == .Dark ? "dark" : "light", settings.fontSize, settings.spacing, settings.rowHeight)
	fmt.sbprintf(&b, "[editor]\nundo_merge_ms = %d\nundo_group_max_ms = %d\nundo_limit = %d\ngrid_size = %d\ncode_editor = %s\noptimized_play = %v\n\n",
		settings.undoMergeMs, settings.undoGroupMaxMs, settings.undoLimit, settings.gridSize,
		FixedText_String(&settings.codeEditor), settings.optimizedPlay)
	strings.write_string(&b, "[keymap]\n")
	for chords, action in settings.keymap {
		fmt.sbprintf(&b, "%v = %s\n", action, Keymap_FormatChords(chords))
	}
	return strings.to_string(b)
}

// "Ctrl+Shift+Z | Ctrl+Y", or "" when unbound (temp allocated)
Keymap_FormatChords :: proc(chords: [KEYMAP_SLOTS]skald.Shortcut) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for chord in chords do if chord != {} do append(&parts, skald.shortcut_format(chord))
	return strings.join(parts[:], " | ", context.temp_allocator)
}

/*
Reads a chord written the way `skald.shortcut_format` writes it: "Ctrl+Shift+A", "Del", "Ctrl+=".
Modifier and key names are case-insensitive; Skald's key enum names ("Delete", "N0") also work.

Returns:
- The chord, and whether the text was one. Plain Backspace isn't (it's Skald's empty shortcut)
*/
Shortcut_Parse :: proc(text: string) -> (skald.Shortcut, bool) {
	chord: skald.Shortcut
	rest := text
	// Split off modifiers; the key itself may be "+"-free punctuation like "=" or "-"
	for {
		plus := strings.index_byte(rest, '+')
		if plus <= 0 || plus == len(rest) - 1 do break
		switch strings.to_lower(rest[:plus], context.temp_allocator) {
		case "ctrl", "control": chord.mods += {.Ctrl}
		case "shift": chord.mods += {.Shift}
		case "alt": chord.mods += {.Alt}
		case "super", "cmd", "win": chord.mods += {.Super}
		case: return {}, false
		}
		rest = rest[plus + 1:]
	}
	for key in skald.Key {
		if strings.equal_fold(rest, skald.shortcut_format({key, {.Ctrl}})[len("Ctrl+"):]) ||
		   strings.equal_fold(rest, fmt.tprintf("%v", key)) {
			chord.key = key
			if chord == {} do return {}, false
			return chord, true
		}
	}
	return {}, false
}

/*
Loads settings: the defaults, then the file at `path` over them, if it exists.

Inputs:
- path: The user's settings file; "" for defaults only

Returns:
- The settings, and problems found in the file (temp allocated)
*/
Settings_Load :: proc(path: string) -> (Settings, []string) {
	settings := Settings_Default()
	if path == "" || !os.exists(path) do return settings, nil
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		problems := make([]string, 1, context.temp_allocator)
		problems[0] = fmt.tprintf("Couldn't read %s: %v", path, err)
		return settings, problems
	}
	return settings, Settings_Parse(&settings, string(data))
}

/*
Writes settings to a file.

Returns:
- An error message ("" on success; temp allocated)
*/
Settings_Save :: proc(settings: ^Settings, path: string) -> string {
	if path == "" do return "No settings file (the editor was started with --settings \"\")"
	if err := os.write_entire_file(path, transmute([]byte)Settings_ToINI(settings)); err != nil {
		return fmt.tprintf("Couldn't save %s: %v", path, err)
	}
	return ""
}

/*
Where the user's settings live: editor.ini next to the executable.

Returns:
- The path (allocated), or "" if the executable's folder can't be found
*/
Settings_DefaultPath :: proc(allocator := context.allocator) -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do return ""
	path, _ := filepath.join({dir, SETTINGS_FILE_NAME}, allocator)
	return path
}

/*
The Skald theme for the appearance settings: dark or light colors, with text sizes scaled from
`fontSize` and spacing from `spacing`.
*/
Settings_Theme :: proc(settings: ^Settings) -> skald.Theme {
	theme := settings.theme == .Light ? skald.theme_light() : skald.theme_dark()
	// Skald's defaults are xs 11, sm 13, md 14, lg 18, xl 24, display 36
	f := settings.fontSize / theme.font.size_md
	theme.font = {
		size_xs = math.round(theme.font.size_xs * f),
		size_sm = math.round(theme.font.size_sm * f),
		size_md = settings.fontSize,
		size_lg = math.round(theme.font.size_lg * f),
		size_xl = math.round(theme.font.size_xl * f),
		size_display = math.round(theme.font.size_display * f),
	}
	g := settings.spacing / 100
	theme.spacing = {
		xs = math.round(theme.spacing.xs * g),
		sm = math.round(theme.spacing.sm * g),
		md = math.round(theme.spacing.md * g),
		lg = math.round(theme.spacing.lg * g),
		xl = math.round(theme.spacing.xl * g),
	}
	return theme
}
