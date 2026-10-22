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
}

// The presets of Settings > Appearance > Preset
THEME_PRESETS := [?]ThemePreset {
	{name = "Dark", base = .Dark},
	{name = "Light", base = .Light},
	{name = "Midnight", base = .Dark, colors = {
		.Bg = 0x0F1420FF, .Surface = 0x161D2CFF, .Elevated = 0x1E2739FF, .Border = 0x2B3650FF,
		.Fg = 0xDFE6F3FF, .Fg_Muted = 0x8B97ADFF, .Primary = 0x5B8CFFFF, .On_Primary = 0xFFFFFFFF,
		.Selection = 0x5B8CFF55, .Success = 0x4CC38AFF, .Warning = 0xE9B44CFF, .Danger = 0xF0616DFF,
	}},
	{name = "Graphite", base = .Dark, colors = {
		.Bg = 0x1B1B1BFF, .Surface = 0x242424FF, .Elevated = 0x2D2D2DFF, .Border = 0x3A3A3AFF,
		.Fg = 0xE6E6E6FF, .Fg_Muted = 0x9A9A9AFF, .Primary = 0xE8833AFF, .On_Primary = 0x1B1B1BFF,
		.Selection = 0xE8833A50, .Success = 0x6CC070FF, .Warning = 0xE8B83AFF, .Danger = 0xE5534BFF,
	}},
	{name = "High Contrast", base = .Dark, colors = {
		.Bg = 0x000000FF, .Surface = 0x0A0A0AFF, .Elevated = 0x161616FF, .Border = 0xFFFFFFFF,
		.Fg = 0xFFFFFFFF, .Fg_Muted = 0xD4D4D4FF, .Primary = 0xFFD400FF, .On_Primary = 0x000000FF,
		.Selection = 0xFFD40066, .Success = 0x00FF66FF, .Warning = 0xFFD400FF, .Danger = 0xFF4040FF,
	}},
	{name = "Paper", base = .Light, colors = #partial [ThemeColor]u32{
		.Bg = 0xF4F1EAFF, .Surface = 0xFBF9F4FF, .Elevated = 0xFFFFFFFF, .Border = 0xD8D2C4FF,
		.Fg = 0x2B2A27FF, .Fg_Muted = 0x6F6A60FF, .Primary = 0x2F6FDFFF, .On_Primary = 0xFFFFFFFF,
		.Selection = 0x2F6FDF40,
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
