// Themes: the editor owns its Theme (editor_set_theme / ed.theme). It
// starts from a built-in preset; the theme editor window changes single
// colours, and the result persists in <config dir>/theme.json as the
// preset name plus the colours that differ from it:
//   {"base": "Ayu Dark", "colors": {"text_keyword": "#ff8f40ff"}}
package code_editor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

THEME_FILE :: "theme.json"

Theme_Preset :: enum {
	Ayu_Dark,
	Ayu_Light,
	Dark_Plus,
}

preset_name :: proc(p: Theme_Preset) -> string {
	switch p {
	case .Ayu_Dark: return "Ayu Dark"
	case .Ayu_Light: return "Ayu Light"
	case .Dark_Plus: return "Dark+"
	}
	return ""
}

preset_theme :: proc(p: Theme_Preset) -> Theme {
	switch p {
	case .Ayu_Dark: return ayu_dark_theme()
	case .Ayu_Light: return ayu_light_theme()
	case .Dark_Plus: return vscode_dark_theme()
	}
	return default_theme()
}

// ayu_light_theme is the light variant of Ayu (Zed's "Ayu Light").
ayu_light_theme :: proc() -> Theme {
	t := ayu_dark_theme()
	t.background, t.gutter_bg, t.current_line = {252, 252, 252, 255}, {252, 252, 252, 255}, {240, 241, 243, 255}
	t.selection, t.cursor, t.text_default = {3, 91, 214, 40}, {255, 170, 51, 255}, {92, 97, 102, 255}
	t.text_keyword, t.text_string, t.text_number = {250, 141, 62, 255}, {134, 179, 0, 255}, {163, 122, 204, 255}
	t.text_comment, t.text_type = {173, 174, 177, 255}, {57, 158, 230, 255}
	t.text_builtin, t.text_function = {235, 160, 50, 255}, {235, 160, 50, 255}
	t.text_constant, t.text_property = {163, 122, 204, 255}, {240, 113, 113, 255}
	t.text_operator, t.text_punct = {237, 147, 102, 255}, {130, 135, 140, 255}
	t.text_directive, t.text_attribute = {250, 141, 62, 255}, {230, 186, 126, 255}
	t.gutter_text, t.header_bg, t.header_text = {175, 180, 186, 255}, {243, 244, 245, 255}, {92, 97, 102, 255}
	t.popup_bg, t.popup_border, t.popup_selected = {255, 255, 255, 255}, {220, 222, 226, 255}, {222, 233, 248, 255}
	t.popup_text, t.popup_text_dim, t.popup_match = {92, 97, 102, 255}, {140, 145, 150, 255}, {250, 141, 62, 255}
	t.popup_active_param = {250, 141, 62, 255}
	t.diag_error, t.diag_warning, t.diag_info, t.diag_hint = {230, 80, 80, 255}, {235, 160, 50, 255}, {57, 158, 230, 255}, {150, 155, 160, 255}
	t.find_match, t.find_current = {255, 170, 51, 70}, {57, 158, 230, 80}
	t.scrollbar_thumb, t.scrollbar_thumb_hover, t.scrollbar_track = {120, 125, 135, 80}, {100, 105, 115, 140}, {0, 0, 0, 8}
	return t
}

editor_set_theme :: proc(ed: ^Editor, theme: Theme) {
	ed.theme = theme
}

// --- fields (every Theme field is an sdl.Color) ----------------------------

theme_field_names :: proc() -> []string {
	return reflect.struct_field_names(Theme)
}

theme_field_count :: proc() -> int {
	return len(reflect.struct_field_names(Theme))
}

// theme_color_ptr returns the i'th colour of `t` (Theme field order).
theme_color_ptr :: proc(t: ^Theme, i: int) -> ^sdl.Color {
	offsets := reflect.struct_field_offsets(Theme)
	return (^sdl.Color)(uintptr(t) + offsets[i])
}

theme_field_index :: proc(name: string) -> int {
	for n, i in theme_field_names() {
		if n == name {
			return i
		}
	}
	return -1
}

// theme_field_title: "text_keyword" -> "Text Keyword".
theme_field_title :: proc(name: string) -> string {
	b := transmute([]u8)strings.clone(name, context.temp_allocator)
	start := true
	for &c in b {
		if c == '_' {
			c = ' '
			start = true
		} else if start {
			if c >= 'a' && c <= 'z' {
				c -= 32
			}
			start = false
		}
	}
	return string(b)
}

color_hex :: proc(c: sdl.Color) -> string {
	return fmt.tprintf("#%02x%02x%02x%02x", c.r, c.g, c.b, c.a)
}

// parse_color_hex accepts #rgb, #rrggbb and #rrggbbaa ('#' optional).
parse_color_hex :: proc(s: string) -> (c: sdl.Color, ok: bool) {
	h := strings.trim_space(s)
	h = strings.trim_prefix(h, "#")
	for ch in h {
		if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')) {
			return
		}
	}
	byte_at :: proc(h: string, i: int) -> u8 {
		v, _ := strconv.parse_uint(h[i:i + 2], 16)
		return u8(v)
	}
	switch len(h) {
	case 3:
		nib :: proc(h: string, i: int) -> u8 {
			v, _ := strconv.parse_uint(h[i:i + 1], 16)
			return u8(v * 17)
		}
		return {nib(h, 0), nib(h, 1), nib(h, 2), 255}, true
	case 6:
		return {byte_at(h, 0), byte_at(h, 2), byte_at(h, 4), 255}, true
	case 8:
		return {byte_at(h, 0), byte_at(h, 2), byte_at(h, 4), byte_at(h, 6)}, true
	}
	return
}

// --- persistence -----------------------------------------------------------

// theme_overrides_json: the preset name plus every colour that differs.
theme_overrides_json :: proc(t: Theme, base: Theme_Preset, allocator := context.allocator) -> string {
	ref := preset_theme(base)
	t := t
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "{{\n  \"base\": %q,\n  \"colors\": {{", preset_name(base))
	first := true
	for name, i in theme_field_names() {
		c := theme_color_ptr(&t, i)^
		if c == theme_color_ptr(&ref, i)^ {
			continue
		}
		fmt.sbprintf(&sb, "%s\n    %q: %q", "" if first else ",", name, color_hex(c))
		first = false
	}
	strings.write_string(&sb, "\n  }\n}\n" if !first else "}\n}\n")
	return strings.to_string(sb)
}

// theme_from_json rebuilds a theme from theme_overrides_json output
// (unknown fields / bad colours are ignored).
theme_from_json :: proc(text: string) -> (t: Theme, base: Theme_Preset, ok: bool) {
	value, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil {
		return default_theme(), .Ayu_Dark, false
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return default_theme(), .Ayu_Dark, false
	}
	if name, is_str := obj["base"].(json.String); is_str {
		for p in Theme_Preset {
			if preset_name(p) == name {
				base = p
			}
		}
	}
	t = preset_theme(base)
	if colors, is_colors := obj["colors"].(json.Object); is_colors {
		for name, v in colors {
			i := theme_field_index(name)
			hex, is_str := v.(json.String)
			if i < 0 || !is_str {
				continue
			}
			if c, cok := parse_color_hex(hex); cok {
				theme_color_ptr(&t, i)^ = c
			}
		}
	}
	return t, base, true
}

editor_load_theme :: proc(ed: ^Editor) -> bool {
	path := config_path(ed, THEME_FILE)
	if len(path) == 0 || !os.exists(path) {
		return false
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	t, base, ok := theme_from_json(string(data))
	if ok {
		ed.theme, ed.theme_editor.base = t, base
	}
	return ok
}

editor_save_theme :: proc(ed: ^Editor) -> bool {
	path := config_path(ed, THEME_FILE)
	if len(path) == 0 {
		return false
	}
	text := theme_overrides_json(ed.theme, ed.theme_editor.base, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)text) == nil
}

// editor_apply_preset switches to a built-in theme (dropping edits).
editor_apply_preset :: proc(ed: ^Editor, p: Theme_Preset) {
	ed.theme = preset_theme(p)
	ed.theme_editor.base = p
	editor_save_theme(ed)
	editor_set_status(ed, fmt.tprintf("Color theme: %s", preset_name(p)))
}
