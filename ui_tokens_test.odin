package crossfire_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "gui:skald"

// The design tokens (ui_tokens.odin): the sizes the views had at the default look, and how they
// scale with the Text size and Spacing settings

@(test)
design_tokens_scale_with_the_look :: proc(t: ^testing.T) {
	settings := Settings_Default()
	theme := Settings_Theme(&settings)
	tk := UiTokens_Of(&theme, settings.rowHeight)
	// The default look (13 px text, 75% spacing): the sizes the views always had
	testing.expect_value(t, tk.xxs, 2)
	testing.expect_value(t, tk.xs, 3)
	testing.expect_value(t, tk.s, 6)
	testing.expect_value(t, tk.m, 9)
	testing.expect_value(t, tk.labelWidth, INSPECTOR_LABEL_WIDTH)
	testing.expect_value(t, tk.toolButtonWidth, 31)
	testing.expect_value(t, tk.rowHeight, 26)
	testing.expect_value(t, tk.fieldPadding, [2]f32{6, 2})
	testing.expect_value(t, tk.squareButton, LINK_BUTTON_WIDTH)
	// The scale is ordered, and at 100% Spacing it's Skald's 4 px grid
	testing.expect(t, tk.hair <= tk.xxs && tk.xxs <= tk.xs && tk.xs < tk.s && tk.s < tk.m && tk.m < tk.l && tk.l < tk.xl, "ordered")
	settings.spacing = 100
	theme = Settings_Theme(&settings)
	tk = UiTokens_Of(&theme, settings.rowHeight)
	for v in ([]f32{tk.xs, tk.s, tk.m, tk.l, tk.xl}) do testing.expectf(t, int(v) % 4 == 0, "%v on the 4 px grid", v)
	// Bigger text: every length in text units grows with it, the spacing doesn't
	settings.spacing = 75
	settings.fontSize = 26
	theme = Settings_Theme(&settings)
	big := UiTokens_Of(&theme, settings.rowHeight)
	testing.expect_value(t, big.labelWidth, INSPECTOR_LABEL_WIDTH * 2)
	testing.expect_value(t, big.fieldM, 300)
	testing.expect_value(t, big.s, 6)
	testing.expect(t, big.iconMedium > tk.iconMedium && big.controlHeight > tk.controlHeight, "icons and controls grow")
	// The text hierarchy: titles over sections over labels over muted text, each in the theme's colors
	ts, _ := TextRole_Style(&theme, .Title)
	ss, sc := TextRole_Style(&theme, .Section)
	ls, lc := TextRole_Style(&theme, .Label)
	ms, mc := TextRole_Style(&theme, .Muted)
	testing.expect(t, ts > ss && ss >= ls && ls > ms, "sizes step down")
	testing.expect(t, sc == theme.color.fg && lc == theme.color.fg_muted && mc == theme.color.fg_muted, "sections stand out, labels and muted text are muted")
}

/*
Layout calls take their sizes from the design tokens (ui_tokens.odin), not pixel numbers: this scans
every source file (strings and comments left out) for a number in a layout argument (`padding`,
`spacing`, `width`, `height`, `max_width`... and `skald.spacer`). A bare 0 is fine (none); in an
expression 0 and 1 are fine, and so is a factor (`* 2`, `/ 2`). The allow-list holds the genuine
exceptions (drawing math, canvases, images, data that isn't layout), each with its reason.
*/
@(test)
view_layout_uses_design_tokens :: proc(t: ^testing.T) {
	Allowed :: struct { file, value, reason: string }
	allowed := []Allowed{
		{"atlas_edit.odin", "padding = 2", "an atlas's packing padding, in the packed image's pixels"},
		{"code_previews.odin", "width = 64", "a code hover's play button: code_editor's widget, not Skald's"},
		{"code_previews.odin", "height = 22", "a code hover's play button: code_editor's widget, not Skald's"},
		{"level_mode.odin", "max_width = 2000", "the disk bar's text stays on one line"},
		{"mixer_widgets.odin", "spacing = thin ? 0 : 2", "the meter's own drawing (a generic widget without the editor's tokens)"},
		{"mixer_widgets.odin", "height = 14", "the pan control's drawn track (a generic widget)"},
		{"value_slider.odin", "height = 18", "the slider's drawn track (a generic widget)"},
		{"view_about.odin", "width = 128", "the logo image's pixel size"},
		{"view_about.odin", "height = 128", "the logo image's pixel size"},
		{"view_dialogue.odin", "height = max(height, n.position.y + DIALOGUE_BOX.y + 30)", "the graph canvas's room under its lowest box, in graph pixels"},
		{"view_states.odin", "height = max(height, st.position.y + STATE_BOX.y + 30)", "the graph canvas's room under its lowest box, in graph pixels"},
		{"view_docs.odin", "max_width = width - (wide ? 470 : 230)", "the docs header's buttons, measured"},
		{"view_inspector_particles.odin", "height = RAMP_BAR_HEIGHT + RAMP_MARKER_HEIGHT + 2", "the ramp canvas's drawing"},
		{"view_ldtk_rules.odin", "width = 40", "a rule's pattern preview canvas"},
		{"view_ldtk_rules.odin", "height = 40", "a rule's pattern preview canvas"},
		{"view_live.odin", "height = 40", "the frame-time graph's canvas"},
		{"view_settings.odin", "height = ctx.renderer != nil ? clamp(f32(ctx.renderer.fb_size.y) - 220, 160, 380) : 380", "the dialog's body fits the window: the room its title and buttons take"},
		{"editor.odin", "", "the window's starting size and data, not layout calls"},
		{"project.odin", "", "the demo outline's game UI (the engine's units), not the editor's"},
		{"level_paint.odin", "", "entity sizes in level pixels"},
	}
	NAMES :: []string{"padding", "spacing", "width", "height", "max_width", "min_width", "min_height", "max_height", "first_size", "min_first", "min_second", "font_size"}
	isWord :: proc(c: u8) -> bool { return c == '_' || c == '.' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
	isDigit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
	// Strings, characters and comments blanked out (kept the same length, so lines stay)
	blank :: proc(text: string) -> []u8 {
		out := make([]u8, len(text), context.temp_allocator)
		copy(out, text)
		i := 0
		for i < len(out) {
			switch {
			case i + 1 < len(out) && out[i] == '/' && out[i + 1] == '/':
				for i < len(out) && out[i] != '\n' { out[i] = ' '; i += 1 }
			case i + 1 < len(out) && out[i] == '/' && out[i + 1] == '*':
				depth := 0
				for i < len(out) {
					if i + 1 < len(out) && out[i] == '/' && out[i + 1] == '*' { depth += 1; out[i], out[i + 1] = ' ', ' '; i += 2 }
					else if i + 1 < len(out) && out[i] == '*' && out[i + 1] == '/' { depth -= 1; out[i], out[i + 1] = ' ', ' '; i += 2; if depth == 0 do break }
					else { if out[i] != '\n' do out[i] = ' '; i += 1 }
				}
			case out[i] == '"' || out[i] == '\'':
				quote := out[i]
				i += 1
				for i < len(out) && out[i] != quote {
					if out[i] == '\\' { out[i] = ' '; i += 1 }
					if i < len(out) && out[i] != '\n' do out[i] = ' '
					i += 1
				}
				i += 1
			case out[i] == '`':
				i += 1
				for i < len(out) && out[i] != '`' { if out[i] != '\n' do out[i] = ' '; i += 1 }
				i += 1
			case:
				i += 1
			}
		}
		return out
	}
	// The flagged number in a value, if any
	flagged :: proc(value: string) -> bool {
		bare := true
		for c in transmute([]u8)value do if !isDigit(c) && c != '.' && c != '-' do bare = false
		if bare {
			for c in transmute([]u8)value do if c >= '1' && c <= '9' do return true
			return false
		}
		i := 0
		for i < len(value) {
			if !isDigit(value[i]) || (i > 0 && isWord(value[i - 1])) { i += 1; continue }
			start := i
			for i < len(value) && (isDigit(value[i]) || value[i] == '.') do i += 1
			if i < len(value) && isWord(value[i]) do continue
			number := value[start:i]
			before := strings.trim_right_space(value[:start])
			after := strings.trim_left_space(value[i:])
			if strings.has_suffix(before, "*") || strings.has_suffix(before, "/") || strings.has_prefix(after, "*") do continue
			if number == "0" || number == "1" || number == "0.5" do continue
			return true
		}
		return false
	}
	files, err := os.read_all_directory_by_path(".", context.temp_allocator)
	testing.expect(t, err == nil, "read the sources")
	fileLoop: for file in files {
		if !strings.has_suffix(file.name, ".odin") || strings.has_suffix(file.name, "_test.odin") do continue
		for a in allowed do if a.file == file.name && a.value == "" do continue fileLoop
		data, readErr := os.read_entire_file(file.fullpath, context.temp_allocator)
		if readErr != nil do continue
		code := string(blank(string(data)))
		for name in NAMES {
			rest := code
			for {
				at := strings.index(rest, name)
				if at < 0 do break
				offset := len(code) - len(rest) + at
				rest = rest[at + len(name):]
				if offset > 0 && isWord(code[offset - 1]) do continue
				after := strings.trim_left(rest, " \t")
				if len(after) < 2 || after[0] != '=' || after[1] == '=' do continue
				// The value: up to a comma, a newline or a closing bracket at its own depth
				valueStart := len(code) - len(after) + 1
				end, depth := valueStart, 0
				scan: for end < len(code) {
					switch code[end] {
					case '(', '[', '{': depth += 1
					case ')', ']', '}': if depth == 0 do break scan; depth -= 1
					case ',', '\n': if depth == 0 do break scan
					}
					end += 1
				}
				value := strings.trim_space(code[valueStart:end])
				if !flagged(value) do continue
				text := fmt.tprintf("%s = %s", name, value)
				ok := false
				for a in allowed do if a.file == file.name && a.value == text do ok = true
				if ok do continue
				line := strings.count(code[:offset], "\n") + 1
				testing.expectf(t, false, "%s:%d: a pixel number in a layout call: %s (use the design tokens, ui_tokens.odin; or allow it here with a reason)", file.name, line, text)
			}
		}
		rest := code
		for {
			at := strings.index(rest, "skald.spacer(")
			if at < 0 do break
			rest = rest[at + len("skald.spacer("):]
			close := strings.index_byte(rest, ')')
			if close < 0 do break
			value := strings.trim_space(rest[:close])
			if flagged(value) && strings.trim_left(value, "-0123456789.") == "" {
				testing.expectf(t, false, "%s: a pixel number in a spacer: skald.spacer(%s) (use the design tokens)", file.name, value)
			}
		}
	}
	free_all(context.temp_allocator)
}

// WCAG's contrast ratio, the suggestion, and every preset readable (editor_theme.odin's contrast check)
@(test)
theme_presets_are_readable :: proc(t: ^testing.T) {
	white, black := skald.rgb(0xFFFFFF), skald.rgb(0x000000)
	testing.expectf(t, abs(Contrast_Ratio(black, white) - 21) < 0.01, "black on white is 21:1, got %v", Contrast_Ratio(black, white))
	testing.expectf(t, abs(Contrast_Ratio(white, white) - 1) < 0.001, "a color on itself is 1:1")
	// #767676 on white is the classic 4.54:1
	testing.expectf(t, abs(Contrast_Ratio(skald.rgb(0x767676), white) - 4.54) < 0.02, "gray on white, got %v", Contrast_Ratio(skald.rgb(0x767676), white))
	// A suggestion reads, and stays near the color it fixes
	dim := skald.rgb(0x444444)
	fixed := Contrast_Suggest(dim, skald.rgb(0x101010))
	testing.expect(t, Contrast_Ratio(fixed, skald.rgb(0x101010)) >= CONTRAST_TEXT_MIN, "the suggestion reads")
	testing.expect(t, Contrast_Ratio(dim, fixed) < 3, "and is still a gray near it")
	// Every preset, and the two bases unchanged, meet 4.5:1 for every pair
	for preset in THEME_PRESETS {
		settings := Settings_Default()
		testing.expect(t, EditorTheme_ApplyPreset(&settings, preset.name), preset.name)
		theme := Settings_Theme(&settings)
		for p in EditorTheme_ContrastProblems(&theme) {
			testing.expectf(t, false, "%s: %v on %v is %.2f:1", preset.name, p.pair.text, p.pair.back, p.ratio)
		}
	}
	// A color made unreadable is reported, with a fix that reads
	settings := Settings_Default()
	settings.themeColors[.Fg_Muted] = skald.rgb(0x30343C)
	settings.themeColorsSet += {.Fg_Muted}
	theme := Settings_Theme(&settings)
	problems := EditorTheme_ContrastProblems(&theme)
	testing.expect(t, len(problems) >= 3, "muted text on the window, panels and popups")
	for p in problems {
		back := ThemeColor_Field(&theme.color, p.pair.back)^
		testing.expect(t, p.pair.text == .Fg_Muted && Contrast_Ratio(p.suggestion, back) >= CONTRAST_TEXT_MIN, "the fix reads")
	}
	free_all(context.temp_allocator)
}

/*
One icon per action: buttons take theirs from `ACTION_ICONS` / `Action_Icon` (icons.odin), so the
glyphs of the table's actions appear nowhere else in the views.
*/
@(test)
action_icons_are_the_single_source :: proc(t: ^testing.T) {
	for icon, action in ACTION_ICONS do testing.expectf(t, icon != "", "%v has an icon", action)
	for action in ([]Action{.New_Project, .Open_Project, .Save_Project, .Undo, .Redo, .Play, .Play_Scene, .Pause, .Stop, .Restart, .Export, .Tool_Select, .Tool_Move, .Tool_Rotate, .Tool_Scale, .Tool_Pan, .Tool_Zoom}) {
		testing.expectf(t, Action_Icon(action) != "", "the toolbar's %v has an icon", action)
	}
	testing.expect(t, Action_Icon(.Delete_Node) == ACTION_ICONS[.Delete] && Action_Icon(.View_Fit) == ACTION_ICONS[.Fit_View], "the keymap's actions use the table")
	files, err := os.read_all_directory_by_path(".", context.temp_allocator)
	testing.expect(t, err == nil, "read the sources")
	for file in files {
		if !strings.has_suffix(file.name, ".odin") || strings.has_suffix(file.name, "_test.odin") || file.name == "icons.odin" do continue
		data, readErr := os.read_entire_file(file.fullpath, context.temp_allocator)
		if readErr != nil do continue
		for name in ([]string{"ICON_TRASH", "ICON_PLUS", "ICON_CLONE", "ICON_FIT", "ICON_DICE", "ICON_EXTERNAL"}) {
			testing.expectf(t, !strings.contains(string(data), name), "%s uses %s: take it from ACTION_ICONS", file.name, name)
		}
	}
	free_all(context.temp_allocator)
}
