package crossfire_editor

import "core:testing"

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
	testing.expect(t, big.iconLarge > tk.iconLarge && big.controlHeight > tk.controlHeight, "icons and controls grow")
	// The text hierarchy: titles over sections over labels over muted text, each in the theme's colors
	ts, _ := TextRole_Style(&theme, .Title)
	ss, _ := TextRole_Style(&theme, .Section)
	ls, lc := TextRole_Style(&theme, .Label)
	ms, mc := TextRole_Style(&theme, .Muted)
	testing.expect(t, ts > ss && ss > ls && ls > ms, "sizes step down")
	testing.expect(t, lc == theme.color.fg_muted && mc == theme.color.fg_muted, "labels and muted text are muted")
}
