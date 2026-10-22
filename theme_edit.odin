package crossfire_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
UI themes in the editor (the engine's ui_theme.odin): `.theme.xml` assets of kind Theme, how
UI controls look.

- **Data:** `Project.themes` (`ThemeDef`: the file's font and `e.UITheme`), loaded with the
  project and imports, written by `Project_Save` when changed (`Project_SaveThemes`).
  `Project.uiTheme` is the project's theme (project.xml's `uiTheme`).
- **Editing:** selecting a theme in the browser shows it in the inspector (`themeInspector`,
  `State.themeSelection`): a slider or color picker per field of `e.UITheme_Fields`, the font,
  and Use for the Whole Project. Edits are `.Project` undo steps (the snapshot holds every
  theme), merged while a slider drags.
- **New Theme** (the browser's menu, `Theme_Created`): `themes/theme.theme.xml` (numbered when
  taken) with the defaults.
- **Viewport:** the preview game gets the in-memory themes before each build (`provideThemes`),
  and the rebuild signature includes them, so an edit shows at once.
*/

// Where new themes go, and their extension
THEME_FOLDER :: "themes"
THEME_EXTENSION :: ".theme.xml"

// A theme asset: its file, font and values (strings owned)
ThemeDef :: struct {
	path: string,
	font: string,
	theme: e.UITheme,
}

// A field of the selected theme changed (`field` an `e.UITheme` field's name, `text` its value)
Theme_Field_Changed :: struct {
	field: string,
	text: string,
}
// The selected theme's font ("" the built-in one)
Theme_Font_Changed :: distinct string
// The browser's New Theme; from a control's inspector (`forSelected`) the control gets it and stays
// selected
Theme_Created :: struct {
	forSelected: bool,
}
// The selected theme becomes the project's (or, false, stops being it)
Theme_Project_Set :: distinct bool

// The font choice for the built-in font
THEME_FONT_DEFAULT :: "(built-in font)"

ThemeDef_Clone :: proc(t: ThemeDef) -> ThemeDef {
	return {strings.clone(t.path), strings.clone(t.font), t.theme}
}

ThemeDef_Destroy :: proc(t: ^ThemeDef) {
	delete(t.path)
	delete(t.font)
	t^ = {}
}

ThemeDef_Equal :: proc(a, b: ThemeDef) -> bool {
	return a.path == b.path && a.font == b.font && a.theme == b.theme
}

// The theme's file text
ThemeDef_ToXML :: proc(t: ^ThemeDef, allocator := context.allocator) -> string {
	return e.FormatTheme({font = t.font, theme = t.theme}, allocator)
}

// Reads a `.theme.xml` file (owned), or the default theme and why
Project_LoadTheme :: proc(rootPath, path: string) -> (ThemeDef, string) {
	def := ThemeDef{path = strings.clone(path), theme = e.DEFAULT_UI_THEME}
	text, err := os.read_entire_file(joinPath(rootPath, path, allocator = context.temp_allocator), context.temp_allocator)
	if err != nil do return def, fmt.tprintf("Couldn't read %s", path)
	parsed, parseErr := e.ParseTheme(string(text), context.temp_allocator)
	if parseErr != .None do return def, fmt.tprintf("%s isn't a theme file (%v)", path, parseErr)
	def.font = strings.clone(parsed.font)
	def.theme = parsed.theme
	return def, ""
}

// The project's theme for a file (-1 if none)
Project_FindTheme :: proc(project: ^Project, path: string) -> int {
	for t, i in project.themes do if t.path == path do return i
	return -1
}

// Writes every theme's file (Project_Save); only changed files are touched
Project_SaveThemes :: proc(project: ^Project) -> string {
	for &t in project.themes {
		text := ThemeDef_ToXML(&t, context.temp_allocator)
		full := joinPath(project.rootPath, t.path, allocator = context.temp_allocator)
		existing, readErr := os.read_entire_file(full, context.temp_allocator)
		if readErr == nil && string(existing) == text do continue
		_ = os.make_directory_all(filepath.dir(full))
		if err := os.write_entire_file(full, text); err != nil do return fmt.tprintf("Couldn't write %s: %v", t.path, err)
	}
	return ""
}

/*
Makes a new theme, `themes/<name>.theme.xml` (numbered when taken), with the default values, and
writes its file.

Returns:
- Its index in `project.themes`, or -1 and why
*/
Project_CreateTheme :: proc(project: ^Project, name: string) -> (int, string) {
	base := strings.to_lower(strings.trim_space(name), context.temp_allocator)
	if base == "" do base = "theme"
	taken :: proc(project: ^Project, path: string) -> bool {
		for asset in project.assets do if strings.equal_fold(asset.path, path) do return true
		return os.exists(joinPath(project.rootPath, path, allocator = context.temp_allocator))
	}
	path := fmt.tprintf("%s/%s%s", THEME_FOLDER, base, THEME_EXTENSION)
	for n := 2; taken(project, path); n += 1 do path = fmt.tprintf("%s/%s_%d%s", THEME_FOLDER, base, n, THEME_EXTENSION)
	def := ThemeDef{path = strings.clone(path), theme = e.DEFAULT_UI_THEME}
	full := joinPath(project.rootPath, path, allocator = context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(full))
	if err := os.write_entire_file(full, ThemeDef_ToXML(&def, context.temp_allocator)); err != nil {
		ThemeDef_Destroy(&def)
		return -1, fmt.tprintf("Couldn't write %s: %v", path, err)
	}
	append(&project.assets, AssetDef{path = strings.clone(path), kind = .Theme})
	append(&project.themes, def)
	return len(project.themes) - 1, ""
}

/*
Handles the theme messages.

Returns:
- Whether the message was this file's
*/
ThemeEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	selected: ^ThemeDef
	if s.themeSelection >= 0 && s.themeSelection < len(s.project.themes) do selected = &s.project.themes[s.themeSelection]
	#partial switch v in m {
	case Theme_Field_Changed:
		if selected != nil do e.UITheme_Set(&selected.theme, v.field, v.text)
	case Theme_Font_Changed:
		if selected == nil do break
		delete(selected.font)
		selected.font = strings.clone(string(v) == THEME_FONT_DEFAULT ? "" : string(v))
	case Theme_Project_Set:
		if selected == nil do break
		delete(s.project.uiTheme)
		s.project.uiTheme = strings.clone(bool(v) ? selected.path : "")
	case Theme_Created:
		index, problem := Project_CreateTheme(&s.project, "theme")
		if problem != "" {
			logLine(s, .Error, strings.clone(problem))
			break
		}
		s.session.assetsChanged = true
		path := s.project.themes[index].path
		logLine(s, .Info, fmt.aprintf("Made %s", path))
		scene := &s.project.scenes[s.currentScene]
		if v.forSelected && s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) && NodeKind_IsControl(scene.nodes[s.selectedNode].kind) {
			u := &scene.nodes[s.selectedNode].ui
			delete(u.theme)
			u.theme = strings.clone(path)
			break
		}
		// Shown in the browser and the inspector
		for asset, i in s.project.assets do if asset.path == path do s.browserSelection = {kind = .Asset, index = i}
		s.themeSelection = index
		s.selectedNode = -1
	case:
		return false
	}
	return true
}

/*
The inspector for a theme chosen in the browser: its font, every field, and whether it's the
project's. Keys `theme-font`, `theme-project`, `theme-<field>` (colors: `-alpha` too).
*/
themeInspector :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	t := &s.project.themes[s.themeSelection]
	_, sidebarWidth := FittedSidebarWidths(&s.layout)
	controlWidth := min(max(sidebarWidth - th.spacing.md * 2 - INSPECTOR_LABEL_WIDTH - th.spacing.sm - INSPECTOR_SCROLLBAR_WIDTH, 80), INSPECTOR_MAX_TEXT_WIDTH)
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows,
		skald.text(fmt.tprintf("%s  %s", ICON_PALETTE, filepath.stem(filepath.stem(t.path))), th.color.fg, th.font.size_md),
		skald.text(fmt.tprintf("Theme  ·  %s", t.path), th.color.fg_muted, th.font.size_xs, max_width = 260),
	)
	isProject := s.project.uiTheme == t.path
	append(&rows, skald.checkbox(ctx, isProject, "The whole project's theme", proc(v: bool) -> Msg { return Theme_Project_Set(v) },
		id = skald.hash_id("theme-project")))
	append(&rows, skald.text(isProject ? "Every control uses it unless it or a parent names another." : "Controls use it when they (or a parent) name it in their Theme.",
		th.color.fg_muted, th.font.size_xs, max_width = controlWidth + INSPECTOR_LABEL_WIDTH))
	append(&rows, skald.divider(ctx))
	fonts := make([dynamic]string, context.temp_allocator)
	append(&fonts, THEME_FONT_DEFAULT)
	for asset in s.project.assets do if asset.kind == .Font do append(&fonts, asset.path)
	append(&rows, inspectorRow(ctx, "Font", skald.select(ctx, t.font == "" ? THEME_FONT_DEFAULT : t.font, fonts[:], proc(v: string) -> Msg { return Theme_Font_Changed(v) },
		id = skald.hash_id("theme-font"), width = controlWidth)))
	for field in e.UITheme_Fields() {
		if field.group != "" {
			append(&rows, skald.divider(ctx), skald.text(field.group, th.color.fg, th.font.size_sm))
		}
		value, _ := e.UITheme_Get(t.theme, field.name)
		defaultText, _ := e.UITheme_Get(e.DEFAULT_UI_THEME, field.name)
		key := fmt.tprintf("theme-%s", field.name)
		control: skald.View
		switch field.type {
		case f32:
			number := parseThemeNumber(value)
			Payload :: struct { name: string }
			control = valueSlider(ctx, key, number, Payload{field.name}, proc(p: Payload, v: f32) -> Msg {
				return Theme_Field_Changed{p.name, fmt.tprintf("%v", math.round(v))}
			}, field.min, field.max, step = 1, decimals = 0, defaultValue = parseThemeNumber(defaultText), width = controlWidth)
		case sdl.Color:
			color, _ := e.ParseColor(value)
			defaultColor, _ := e.ParseColor(defaultText)
			control = themeColor(ctx, field.name, color, defaultColor.a, key, controlWidth)
		case:
			control = skald.text(value, th.color.fg_muted, th.font.size_sm)
		}
		append(&rows, inspectorRow(ctx, field.label, control))
	}
	return skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.md)
}

@(private="file")
parseThemeNumber :: proc(text: string) -> f32 {
	theme: e.UITheme
	e.UITheme_Set(&theme, "textSize", text)
	return theme.textSize
}

// A theme color: a picker and an alpha slider
@(private="file")
themeColor :: proc(ctx: ^skald.Ctx(Msg), name: string, color: sdl.Color, defaultAlpha: u8, key: string, width: f32) -> skald.View {
	th := ctx.theme
	Payload :: struct { name: string, color: sdl.Color }
	payload := Payload{name, color}
	linear := skald.rgb(u32(color.r) << 16 | u32(color.g) << 8 | u32(color.b))
	return skald.col(
		skald.color_picker(ctx, linear, payload, proc(p: Payload, c: skald.Color) -> Msg {
			picked, _ := e.ParseColor(fmt.tprintf("#%s", skald.color_to_hex(c)))
			picked.a = p.color.a
			return Theme_Field_Changed{p.name, e.FormatColor(picked, context.temp_allocator)}
		}, id = skald.hash_id(key), width = width),
		skald.row(
			skald.col(skald.text("Alpha", th.color.fg_muted, th.font.size_xs), width = 34),
			valueSlider(ctx, fmt.tprintf("%s-alpha", key), f32(color.a), payload, proc(p: Payload, v: f32) -> Msg {
				c := p.color
				c.a = u8(math.clamp(math.round(v), 0, 255))
				return Theme_Field_Changed{p.name, e.FormatColor(c, context.temp_allocator)}
			}, 0, 255, step = 1, decimals = 0, defaultValue = f32(defaultAlpha), width = width - 34 - th.spacing.xs),
			spacing = th.spacing.xs, cross_align = .Center,
		),
		spacing = 2,
	)
}
