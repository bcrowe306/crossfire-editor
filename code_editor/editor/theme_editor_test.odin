package code_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

@(test)
test_parse_color_hex :: proc(t: ^testing.T) {
	c, ok := parse_color_hex("#ff8040")
	testing.expect(t, ok && c == sdl.Color{255, 128, 64, 255}, "rrggbb")
	c, ok = parse_color_hex("10203040")
	testing.expect(t, ok && c == sdl.Color{16, 32, 48, 64}, "rrggbbaa without #")
	c, ok = parse_color_hex("#fa0")
	testing.expect(t, ok && c == sdl.Color{255, 170, 0, 255}, "rgb")
	_, ok = parse_color_hex("#12345")
	testing.expect(t, !ok, "bad length")
	_, ok = parse_color_hex("#gg0000")
	testing.expect(t, !ok, "bad digit")
	testing.expect_value(t, color_hex({255, 128, 64, 255}), "#ff8040ff")
}

@(test)
test_theme_json_round_trip :: proc(t: ^testing.T) {
	th := preset_theme(.Dark_Plus)
	th.text_keyword = {1, 2, 3, 4}
	text := theme_overrides_json(th, .Dark_Plus, context.temp_allocator)
	testing.expect(t, strings.contains(text, `"text_keyword": "#01020304"`), "only the edit is stored")
	testing.expect(t, !strings.contains(text, "text_string"), "unchanged colours omitted")
	back, base, ok := theme_from_json(text)
	testing.expect(t, ok && base == .Dark_Plus, "preset restored")
	testing.expect(t, back == th, "colours restored")
	testing.expect_value(t, theme_field_title("text_keyword"), "Text Keyword")
	testing.expect_value(t, theme_field_count(), len(theme_field_names()))
}

@(test)
test_theme_editor_edits_and_persists :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		dir := fmt.tprintf("/tmp/oe_theme_%d", time.tick_now()._nsec)
		_ = os.make_directory_all(dir)
		defer os.remove_all(dir)

		ed := make_mouse_test_editor("x := 1")
		editor_set_config_dir(&ed, dir)
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT)
		type_and_update(&ed, "theme editor")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect_value(t, ed.window, Editor_Window.Theme)

		// Select text_keyword, then nudge its red channel.
		ed.theme_editor.selected = theme_field_index("text_keyword")
		before := ed.theme.text_keyword
		key_and_update(&ed, sdl.K_RIGHT, sdl.KMOD_LSHIFT) // R is 255 already: clamps
		testing.expect_value(t, ed.theme.text_keyword.r, 255)
		key_and_update(&ed, sdl.K_TAB) // -> G
		key_and_update(&ed, sdl.K_LEFT, sdl.KMOD_LSHIFT)
		testing.expect_value(t, int(ed.theme.text_keyword.g), int(before.g) - 16)
		testing.expect(t, editor_theme_modified(&ed, theme_field_index("text_keyword")), "marked edited")

		// Typing a hex value (typing elsewhere is ignored).
		type_and_update(&ed, "zz")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, ed.theme_editor.editing, "hex entry")
		for _ in 0 ..< 8 {
			key_and_update(&ed, sdl.K_BACKSPACE)
		}
		type_and_update(&ed, "12ab34")
		testing.expect(t, ed.theme.text_keyword == sdl.Color{0x12, 0xab, 0x34, 255}, "live preview")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect(t, !ed.theme_editor.editing, "applied")

		// A slider drag sets a channel from the pointer.
		r := editor_theme_slider_rect(&ed, 3)
		mouse_click(&ed, r.x + r.w / 2, r.y + r.h / 2)
		testing.expect(t, abs(int(ed.theme.text_keyword.a) - 128) <= 1, "alpha ~ half")
		testing.expect_value(t, ed.theme_editor.channel, 3)
		editor_destroy(&ed)

		// Reloads from theme.json.
		data, err := os.read_entire_file(filepath.join({dir, THEME_FILE}, context.temp_allocator) or_else "", context.temp_allocator)
		testing.expect(t, err == nil && strings.contains(string(data), "text_keyword"), "saved")
		ed2 := make_mouse_test_editor("y")
		defer editor_destroy(&ed2)
		editor_set_config_dir(&ed2, dir)
		testing.expect_value(t, ed2.theme.text_keyword.g, 0xab)

		// Delete resets one colour; P switches presets; Escape closes.
		editor_show_window(&ed2, .Theme)
		ed2.theme_editor.selected = theme_field_index("text_keyword")
		key_and_update(&ed2, sdl.K_DELETE)
		testing.expect(t, ed2.theme.text_keyword == ayu_dark_theme().text_keyword, "reset")
		key_and_update(&ed2, sdl.K_P)
		testing.expect_value(t, ed2.theme_editor.base, Theme_Preset.Ayu_Light)
		testing.expect(t, ed2.theme == ayu_light_theme(), "preset applied")
		key_and_update(&ed2, sdl.K_ESCAPE)
		testing.expect_value(t, ed2.window, Editor_Window.Text)
	})
}

@(test)
test_palette_switches_theme_preset :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		ed := make_mouse_test_editor("x")
		defer editor_destroy(&ed)
		key_and_update(&ed, sdl.K_P, sdl.KMOD_LCTRL)
		type_and_update(&ed, "color theme dark+")
		key_and_update(&ed, sdl.K_RETURN)
		testing.expect_value(t, ed.theme_editor.base, Theme_Preset.Dark_Plus)
		testing.expect(t, ed.theme == vscode_dark_theme(), "Dark+ applied")
	})
}
