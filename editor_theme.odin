package crossfire_editor

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "gui:skald"

/*
The editor's own look, edited live in Settings > Appearance (not a game's UI themes: theme_edit.odin).

On top of the base theme (Skald's Dark or Light) the user can set any of Skald's theme colors
(`ThemeColor`: backgrounds, borders, text, the accent, selection, states) and the corners'
roundness, or start from a preset (`THEME_PRESETS`). Only what was set is kept
(`Settings.themeColors` with `themeColorsSet`), so a set color stays whichever base is chosen and
the rest follow the base. `Settings_Theme` applies them.

**Live:** every Appearance change in the dialog's draft is shown at once (the dialog returns
`skald.cmd_set_theme` with the draft's theme); Cancel puts the applied settings' theme back, Apply
and Save keep it.

**Saved** in editor.ini's `[theme]` section: `corner_radius` (percent of Skald's) and one line per
color set, `#RRGGBB` or `#RRGGBBAA` (`bg = #1e2130`).

**The canvases' colors** (`ViewportColor`: the viewport's background around the game area, its
grid, game frame, selection outline, gizmo and guides; the Level canvas's background and grid) are
set the same way (`Settings.viewportColors` with `viewportColorsSet`, the same `[theme]` section:
`viewport_bg = #101218`) but aren't Skald's: the views read them (`ViewportColors`: the Settings
dialog's draft while it's open, so they're live too; Cancel drops the draft). Unset, each is its
default (`ViewportColor_Default`): today's constants, or the theme's color it always followed
(the selection outline the accent, the Level canvas the window background).
*/

// One of the theme's colors (Skald's `Theme_Colors` roles)
ThemeColor :: enum {
	Bg,
	Surface,
	Elevated,
	Border,
	Fg,
	Fg_Muted,
	Primary,
	On_Primary,
	Selection,
	Success,
	Warning,
	Danger,
}

// Each color's name in Settings (each has a tooltip: tooltips.odin)
THEME_COLOR_LABELS := [ThemeColor]string {
	.Bg         = "Window background",
	.Surface    = "Panels",
	.Elevated   = "Popups",
	.Border     = "Borders",
	.Fg         = "Main text",
	.Fg_Muted   = "Muted text",
	.Primary    = "Accent",
	.On_Primary = "Text on accent",
	.Selection  = "Selection",
	.Success    = "Success",
	.Warning    = "Warning",
	.Danger     = "Danger",
}

// Each color's key in editor.ini's [theme] section
THEME_COLOR_KEYS := [ThemeColor]string {
	.Bg = "bg", .Surface = "surface", .Elevated = "elevated", .Border = "border",
	.Fg = "fg", .Fg_Muted = "fg_muted", .Primary = "primary", .On_Primary = "on_primary",
	.Selection = "selection", .Success = "success", .Warning = "warning", .Danger = "danger",
}

// One of the canvases' colors (the viewport's and the Level canvas's), set in Settings > Appearance
ViewportColor :: enum {
	Viewport_Bg,
	Grid,
	Grid_Major,
	Grid_Axis,
	Game_Frame,
	Selection_Outline,
	Gizmo_X,
	Gizmo_Y,
	Gizmo_Handles,
	Guides,
	Level_Bg,
	Level_Grid,
}

// Each canvas color's name in Settings (each has a tooltip: tooltips.odin)
VIEWPORT_COLOR_LABELS := [ViewportColor]string {
	.Viewport_Bg       = "Viewport background",
	.Grid              = "Grid lines",
	.Grid_Major        = "Major grid lines",
	.Grid_Axis         = "Grid axes",
	.Game_Frame        = "Game frame",
	.Selection_Outline = "Selection outline",
	.Gizmo_X           = "Gizmo X arrow",
	.Gizmo_Y           = "Gizmo Y arrow",
	.Gizmo_Handles     = "Gizmo handles",
	.Guides            = "Guide lines",
	.Level_Bg          = "Level canvas background",
	.Level_Grid        = "Level canvas grid",
}

// Each canvas color's key in editor.ini's [theme] section
VIEWPORT_COLOR_KEYS := [ViewportColor]string {
	.Viewport_Bg = "viewport_bg", .Grid = "viewport_grid", .Grid_Major = "viewport_grid_major",
	.Grid_Axis = "viewport_grid_axis", .Game_Frame = "viewport_game_frame",
	.Selection_Outline = "viewport_selection", .Gizmo_X = "viewport_gizmo_x", .Gizmo_Y = "viewport_gizmo_y",
	.Gizmo_Handles = "viewport_gizmo_handles", .Guides = "viewport_guides",
	.Level_Bg = "level_bg", .Level_Grid = "level_grid",
}

/*
A canvas color's default, unset: the viewport's constants (the grid's dark grays are the user's
choice of 2026-10-22, apart from the editor's colors), or the theme's color it follows (`theme`:
the look shown, `ctx.theme`).
*/
ViewportColor_Default :: proc(which: ViewportColor, theme: ^skald.Theme) -> skald.Color {
	switch which {
	case .Viewport_Bg:       return skald.rgb(VIEWPORT_BG_HEX)
	case .Grid:              return GRID_LINE_COLOR
	case .Grid_Major:        return GRID_MAJOR_COLOR
	case .Grid_Axis:         return GRID_AXIS_COLOR
	case .Game_Frame:        return GAME_FRAME_COLOR
	case .Selection_Outline: return theme.color.primary
	case .Gizmo_X:           return X_COLOR
	case .Gizmo_Y:           return Y_COLOR
	case .Gizmo_Handles:     return theme.color.fg
	case .Guides:            return GUIDE_COLOR
	case .Level_Bg:          return theme.color.bg
	case .Level_Grid:        return theme.color.border
	}
	return {}
}

// The canvases' colors of a settings value: the ones set, the rest their defaults over `theme`
ViewportColors_Of :: proc(settings: ^Settings, theme: ^skald.Theme) -> (colors: [ViewportColor]skald.Color) {
	for which in ViewportColor {
		colors[which] = which in settings.viewportColorsSet ? settings.viewportColors[which] : ViewportColor_Default(which, theme)
	}
	return
}

/*
The canvases' colors the editor shows now: the Settings dialog's draft while it's open (Appearance
is live; Cancel drops the draft), else the applied settings'. `theme` is the look shown
(`ctx.theme`), for the colors that follow it.
*/
ViewportColors :: proc(s: ^State, theme: ^skald.Theme) -> [ViewportColor]skald.Color {
	return ViewportColors_Of(s.settingsDialog.open ? &s.settingsDialog.draft : &s.settings, theme)
}

// The viewport's background around the game area as SDL's bytes (sRGB), for the engine's render
ViewportBg_Bytes :: proc(s: ^State) -> [4]u8 {
	look := s.settingsDialog.open ? &s.settingsDialog.draft : &s.settings
	c := .Viewport_Bg in look.viewportColorsSet ? look.viewportColors[.Viewport_Bg] : skald.rgb(VIEWPORT_BG_HEX)
	hex, _ := strconv.parse_uint(skald.color_to_hex(c), 16)
	return {u8(hex >> 16), u8(hex >> 8), u8(hex), 255}
}

// The roundness of corners: percent of Skald's radii
SETTINGS_CORNER_RADIUS_RANGE :: [2]f32{0, 300}

// A theme color of Skald's palette
ThemeColor_Field :: proc(colors: ^skald.Theme_Colors, which: ThemeColor) -> ^skald.Color {
	switch which {
	case .Bg:         return &colors.bg
	case .Surface:    return &colors.surface
	case .Elevated:   return &colors.elevated
	case .Border:     return &colors.border
	case .Fg:         return &colors.fg
	case .Fg_Muted:   return &colors.fg_muted
	case .Primary:    return &colors.primary
	case .On_Primary: return &colors.on_primary
	case .Selection:  return &colors.selection
	case .Success:    return &colors.success
	case .Warning:    return &colors.warning
	case .Danger:     return &colors.danger
	}
	return &colors.bg
}

// The base theme's colors (what a color not set falls back to)
EditorTheme_Base :: proc(choice: ThemeChoice) -> skald.Theme {
	return choice == .Light ? skald.theme_light() : skald.theme_dark()
}

// The colors set and the corners' roundness, over a theme built from the base
EditorTheme_Apply :: proc(theme: ^skald.Theme, settings: ^Settings) {
	for which in ThemeColor do if which in settings.themeColorsSet do ThemeColor_Field(&theme.color, which)^ = settings.themeColors[which]
	f := settings.cornerRadius / 100
	theme.radius.sm = math.round(theme.radius.sm * f)
	theme.radius.md = math.round(theme.radius.md * f)
	theme.radius.lg = math.round(theme.radius.lg * f)
	theme.radius.xl = math.round(theme.radius.xl * f)
}

// A color as editor.ini writes it: "#RRGGBB", or "#RRGGBBAA" when it isn't opaque
ThemeColor_Format :: proc(c: skald.Color) -> string {
	hex := skald.color_to_hex(c)
	if c[3] >= 0.999 do return fmt.tprintf("#%s", hex)
	return fmt.tprintf("#%s%02X", hex, u8(math.round(clamp(c[3], 0, 1) * 255)))
}

// Reads "#RRGGBB" or "#RRGGBBAA" (the # optional)
ThemeColor_Parse :: proc(text: string) -> (skald.Color, bool) {
	t := strings.trim_space(text)
	t = strings.trim_prefix(t, "#")
	if len(t) != 6 && len(t) != 8 do return {}, false
	c, ok := skald.hex_to_color(t[:6])
	if !ok do return {}, false
	if len(t) == 8 {
		// Alpha is a plain 0..1 value (not on the sRGB curve)
		alpha, aok := strconv.parse_uint(t[6:], 16)
		if !aok || alpha > 255 do return {}, false
		c[3] = f32(alpha) / 255
	}
	return c, true
}

// A look to start from: a base theme and the colors it sets (0: the base's)
ThemePreset :: struct {
	name: string,
	base: ThemeChoice,
	// 0xRRGGBBAA; 0 leaves the base's color
	colors: [ThemeColor]u32,
	// The canvases' colors it sets (0: the default)
	viewport: [ViewportColor]u32,
}

// The presets of Settings > Appearance > Preset
THEME_PRESETS := [?]ThemePreset {
	{name = "Dark", base = .Dark},
	{name = "Light", base = .Light},
	// Midnight's accent was #5B8CFF (white on it 3.2:1), Graphite's danger #E5534B and Paper's
	// warning the Light theme's (under 4.5:1 on their panels): darkened or lightened to read
	{name = "Midnight", base = .Dark, colors = {
		.Bg = 0x0F1420FF, .Surface = 0x161D2CFF, .Elevated = 0x1E2739FF, .Border = 0x2B3650FF,
		.Fg = 0xDFE6F3FF, .Fg_Muted = 0x8B97ADFF, .Primary = 0x3A6FE6FF, .On_Primary = 0xFFFFFFFF,
		.Selection = 0x3A6FE655, .Success = 0x4CC38AFF, .Warning = 0xE9B44CFF, .Danger = 0xF0616DFF,
	}, viewport = #partial [ViewportColor]u32{
		.Viewport_Bg = 0x0A0E17FF, .Grid = 0x1F2738FF, .Grid_Major = 0x2C3850FF, .Grid_Axis = 0x3E4D6CFF,
	}},
	{name = "Graphite", base = .Dark, colors = {
		.Bg = 0x1B1B1BFF, .Surface = 0x242424FF, .Elevated = 0x2D2D2DFF, .Border = 0x3A3A3AFF,
		.Fg = 0xE6E6E6FF, .Fg_Muted = 0x9A9A9AFF, .Primary = 0xE8833AFF, .On_Primary = 0x1B1B1BFF,
		.Selection = 0xE8833A50, .Success = 0x6CC070FF, .Warning = 0xE8B83AFF, .Danger = 0xF06A6EFF,
	}, viewport = #partial [ViewportColor]u32{
		.Viewport_Bg = 0x141414FF, .Grid = 0x2A2A2AFF, .Grid_Major = 0x383838FF, .Grid_Axis = 0x4A4A4AFF,
	}},
	{name = "High Contrast", base = .Dark, colors = {
		.Bg = 0x000000FF, .Surface = 0x0A0A0AFF, .Elevated = 0x161616FF, .Border = 0xFFFFFFFF,
		.Fg = 0xFFFFFFFF, .Fg_Muted = 0xD4D4D4FF, .Primary = 0xFFD400FF, .On_Primary = 0x000000FF,
		.Selection = 0xFFD40066, .Success = 0x00FF66FF, .Warning = 0xFFD400FF, .Danger = 0xFF4040FF,
	}, viewport = #partial [ViewportColor]u32{
		.Viewport_Bg = 0x000000FF, .Grid = 0x4A4A4AFF, .Grid_Major = 0x8A8A8AFF, .Grid_Axis = 0xFFFFFFFF,
		.Game_Frame = 0xFF4040FF, .Guides = 0x00E5FFFF,
	}},
	{name = "Paper", base = .Light, colors = #partial [ThemeColor]u32{
		.Bg = 0xF4F1EAFF, .Surface = 0xFBF9F4FF, .Elevated = 0xFFFFFFFF, .Border = 0xD8D2C4FF,
		.Fg = 0x2B2A27FF, .Fg_Muted = 0x6F6A60FF, .Primary = 0x2F6FDFFF, .On_Primary = 0xFFFFFFFF,
		.Selection = 0x2F6FDF40, .Warning = 0x8A5C00FF,
	}, viewport = #partial [ViewportColor]u32{
		.Viewport_Bg = 0xD9D4C8FF, .Grid = 0xC4BEB0FF, .Grid_Major = 0xAFA898FF, .Grid_Axis = 0x8E8676FF,
		.Game_Frame = 0xC8473EB0, .Gizmo_Y = 0x2E9E48FF, .Guides = 0x1C8FB0D9,
	}},
}

/*
Puts a preset into settings: its base theme, and exactly its colors (any set before are dropped).

Returns:
- false when there's no preset by that name
*/
EditorTheme_ApplyPreset :: proc(settings: ^Settings, name: string) -> bool {
	for preset in THEME_PRESETS {
		if preset.name != name do continue
		settings.theme = preset.base
		settings.themeColorsSet = {}
		for which in ThemeColor {
			if hex := preset.colors[which]; hex != 0 {
				settings.themeColors[which] = skald.rgba(hex)
				settings.themeColorsSet += {which}
			}
		}
		settings.viewportColorsSet = {}
		for which in ViewportColor {
			if hex := preset.viewport[which]; hex != 0 {
				settings.viewportColors[which] = skald.rgba(hex)
				settings.viewportColorsSet += {which}
			}
		}
		return true
	}
	return false
}

// The preset the settings match exactly, or "" (the dropdown shows "Custom")
EditorTheme_PresetName :: proc(settings: ^Settings) -> string {
	for preset in THEME_PRESETS {
		if preset.base != settings.theme do continue
		same := true
		for which in ThemeColor {
			hex := preset.colors[which]
			set := which in settings.themeColorsSet
			if (hex != 0) != set || (set && ThemeColor_Format(settings.themeColors[which]) != ThemeColor_Format(skald.rgba(hex))) {
				same = false
				break
			}
		}
		for which in ViewportColor {
			hex := preset.viewport[which]
			set := which in settings.viewportColorsSet
			if (hex != 0) != set || (set && ThemeColor_Format(settings.viewportColors[which]) != ThemeColor_Format(skald.rgba(hex))) {
				same = false
				break
			}
		}
		if same do return preset.name
	}
	return ""
}

// A theme color set in Settings > Appearance (live; Apply or Save keeps it)
Settings_Theme_Color_Changed :: struct {
	color: ThemeColor,
	value: skald.Color,
}
// A theme color back to the base theme's
Settings_Theme_Color_Reset :: distinct ThemeColor
// A preset chosen (its name)
Settings_Theme_Preset_Chosen :: distinct string
// A canvas color set in Settings > Appearance (shown at once; Apply or Save keeps it)
Settings_Viewport_Color_Changed :: struct {
	color: ViewportColor,
	value: skald.Color,
}
// A canvas color back to its default
Settings_Viewport_Color_Reset :: distinct ViewportColor

/*
Contrast: Settings > Appearance warns when a text color is hard to read on the colors it's drawn on,
by WCAG 2's contrast ratio (1:1 to 21:1). Body text needs `CONTRAST_TEXT_MIN` (4.5:1, WCAG AA).
`CONTRAST_PAIRS` lists what the editor draws on what: the main and muted text on the window, the
panels and popups; text on the accent (buttons, the selected tab); warning and danger text on the
panels and popups. Every preset meets it (`theme_presets_are_readable`).
*/
CONTRAST_TEXT_MIN :: f32(4.5)

// A text color and a background it's drawn on
ContrastPair :: struct { text, back: ThemeColor }

// What the editor draws on what (`EditorTheme_ContrastProblems` checks each)
CONTRAST_PAIRS := [?]ContrastPair{
	{.Fg, .Bg}, {.Fg, .Surface}, {.Fg, .Elevated},
	{.Fg_Muted, .Bg}, {.Fg_Muted, .Surface}, {.Fg_Muted, .Elevated},
	{.On_Primary, .Primary},
	{.Warning, .Surface}, {.Warning, .Elevated},
	{.Danger, .Surface}, {.Danger, .Elevated},
}

/*
WCAG 2's relative luminance of a color. Skald's colors are linear already (`skald.rgb` decodes
sRGB), so it's the weighted sum; a translucent color is first blended over `over`.
*/
Color_Luminance :: proc(c: skald.Color, over := skald.Color{0, 0, 0, 1}) -> f32 {
	a := clamp(c[3], 0, 1)
	r := c[0] * a + over[0] * (1 - a)
	g := c[1] * a + over[1] * (1 - a)
	b := c[2] * a + over[2] * (1 - a)
	return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/*
WCAG 2's contrast ratio of a text color on a background: (lighter + 0.05) / (darker + 0.05), from
1 (none) to 21 (black on white). A translucent text color is blended over the background.
*/
Contrast_Ratio :: proc(text, back: skald.Color) -> f32 {
	opaque := back
	opaque[3] = 1
	l1, l2 := Color_Luminance(text, opaque), Color_Luminance(opaque)
	if l1 < l2 do l1, l2 = l2, l1
	return (l1 + 0.05) / (l2 + 0.05)
}

/*
A text color readable on `back` that is as close to `text` as it gets: mixed toward white or black
(whichever the background leaves room for) in small steps until the ratio reaches `minimum`.
*/
Contrast_Suggest :: proc(text, back: skald.Color, minimum := CONTRAST_TEXT_MIN) -> skald.Color {
	toward := Color_Luminance(back) < 0.18 ? skald.Color{1, 1, 1, 1} : skald.Color{0, 0, 0, 1}
	// The other way when that one can't reach it (a mid-gray background)
	if Contrast_Ratio(toward, back) < minimum do toward = toward[0] > 0.5 ? skald.Color{0, 0, 0, 1} : skald.Color{1, 1, 1, 1}
	for step in 0 ..= 40 {
		t := f32(step) / 40
		c := skald.Color{text[0] + (toward[0] - text[0]) * t, text[1] + (toward[1] - text[1]) * t, text[2] + (toward[2] - text[2]) * t, 1}
		// Round to what a hex color can say, then check again
		parsed, _ := skald.hex_to_color(skald.color_to_hex(c))
		if Contrast_Ratio(parsed, back) >= minimum do return parsed
	}
	return toward
}

// A pair that's hard to read: its ratio and a text color that would be readable
ContrastProblem :: struct {
	pair: ContrastPair,
	ratio: f32,
	suggestion: skald.Color,
}

// The pairs of `CONTRAST_PAIRS` under `CONTRAST_TEXT_MIN` in a theme
EditorTheme_ContrastProblems :: proc(theme: ^skald.Theme, allocator := context.temp_allocator) -> []ContrastProblem {
	problems := make([dynamic]ContrastProblem, allocator)
	for pair in CONTRAST_PAIRS {
		text := ThemeColor_Field(&theme.color, pair.text)^
		back := ThemeColor_Field(&theme.color, pair.back)^
		ratio := Contrast_Ratio(text, back)
		if ratio < CONTRAST_TEXT_MIN do append(&problems, ContrastProblem{pair, ratio, Contrast_Suggest(text, back)})
	}
	return problems[:]
}
