package crossfire_editor

import "core:math"
import "gui:skald"

/*
The editor's design tokens: the sizes every view lays out with, so spacing, heights, text and icons
stay even and scale together (TODO.md's "UI and UX" round 3, 2026-10-25).

Everything is derived from the look shown (`ctx.theme`: Settings > Appearance's Text size and
Spacing, which `Settings_Theme` folds into Skald's theme) and the Row height setting, so a bigger
font or more spacing moves every view the same way:
- **Spacing** is Skald's 5-step scale (`theme.spacing`: 4, 8, 12, 16, 24 px at 100% Spacing, a
  4 px grid; the editor's default Spacing is 75%, so 3, 6, 9, 12, 18), plus two steps under it for
  dense rows: `xxs` (half of `xs`, 2 px at the default) and `hair` (1 px).
- **Heights and widths** are in units of the body text size (`theme.font.size_md`, 13 px at the
  default), rounded to whole pixels: at the default look they are the sizes the views always had.
- **Rules for new UI** (CLAUDE.md's "Design tokens"): lay out with `uiTokens(ctx)`, never a pixel
  number in a `padding`, `spacing`, `width`, `height` or `spacer` (the unit test
  `view_layout_uses_design_tokens` flags them, with an allow-list for drawing math); text through
  `uiText` and its roles; icons from `ACTION_ICONS` at the context's size.
*/

// The editor's sizes for the look shown (`uiTokens`)
Ui_Tokens :: struct {
	// The spacing scale: 1 px, half of xs, then Skald's xs / s / m / l / xl
	hair, xxs, xs, s, m, l, xl: f32,

	// Padding inside a panel (its header, its content's edges)
	panelPadding: f32,
	// Between sections of a panel, dialog or Settings page
	sectionGap: f32,
	// Between the rows of a form (the inspector's, Settings', a dialog's)
	rowGap: f32,
	// Between buttons in a group (a toolbar row, a dialog's buttons, a panel header's actions)
	buttonGap: f32,
	// A dense field's padding (the inspector's, the list tabs'): s across, xxs down
	fieldPadding: [2]f32,
	// A small text button's padding (`smallButton`, the list tabs' buttons): s across, xxs down
	buttonPadding: [2]f32,

	// A text field's, button's or dropdown's height at the body text size
	controlHeight: f32,
	// A list row's height (the scene tree, browser, Level sidebars: the Row height setting)
	rowHeight: f32,
	// A panel header's height (`panelHeader`: the title and its buttons)
	headerHeight: f32,

	// The label column beside a form's controls (the inspector's, the list tabs')
	labelWidth: f32,
	// A wider label column (Settings', Project Settings')
	labelWidthWide: f32,
	// Control widths: a short number, a small, medium, large and extra large field
	fieldXS, fieldS, fieldM, fieldL, fieldXL: f32,
	// Where text wraps: in a sidebar or the inspector, in a dialog, in Settings' pages, in a wide panel
	textNarrow, textDialog, textMeasure, textWide: f32,
	// Dialog widths: a small (a question), medium (a form) and large (a list) dialog; Settings'
	// and Project Settings' pages, and theirs with a list beside the form
	dialogS, dialogM, dialogL, dialogSettings, dialogWide: f32,

	// Icons per context: small (rows, tabs, inline), medium (panel header buttons), large (toolbar)
	iconSmall, iconMedium, iconLarge: f32,
	// The toolbar's buttons' width and a panel header button's width
	toolButtonWidth, panelButtonWidth: f32,
	// A small square button beside a field (a link toggle, a reset, a remove)
	squareButton: f32,
	// A column holding one icon or letter (a status mark), a tiny number field, a color chip
	iconColumn, fieldXXS, swatch: f32,
}

// The body text size the token units were measured at: the default look's (settings.default.ini)
TOKENS_BASE_FONT :: f32(13)

/*
The row height the views read while `view` runs (the Row height setting: `view` sets it, so helpers
without the state see it too). Not live while Settings is open: it applies on Apply or Save.
*/
@(thread_local)
uiRowHeight: f32

// The Row height setting's default, for tokens asked for before `view` set `uiRowHeight` (tests)
TOKENS_DEFAULT_ROW_HEIGHT :: f32(26)

/*
The tokens for a theme and a row height. Pure: the unit tests check its scale. Lengths in body text
units are `TOKENS_BASE_FONT`-relative, so at the default look they equal the sizes the views used
before the tokens (the label column 82 px, the toolbar's buttons 31 px...).
*/
UiTokens_Of :: proc(th: ^skald.Theme, rowHeight: f32) -> (t: Ui_Tokens) {
	sp := th.spacing
	f := th.font.size_md
	// A length given at the base font, scaled to this one
	em :: proc(f, px: f32) -> f32 { return math.round(px * f / TOKENS_BASE_FONT) }

	t.hair = 1
	t.xxs = max(math.round(sp.xs / 2), 1)
	t.xs, t.s, t.m, t.l, t.xl = sp.xs, sp.sm, sp.md, sp.lg, sp.xl

	t.panelPadding = sp.sm
	t.sectionGap = sp.sm
	t.rowGap = sp.xs
	t.buttonGap = sp.xs
	t.fieldPadding = {sp.sm, t.xxs}
	t.buttonPadding = {sp.sm, t.xxs}

	t.controlHeight = math.round(f * 1.35 + t.xxs * 2 + 2)
	t.rowHeight = rowHeight
	t.headerHeight = math.round(th.font.size_sm * 1.35 + sp.sm * 2)

	t.labelWidth = em(f, INSPECTOR_LABEL_WIDTH)
	t.labelWidthWide = em(f, 170)
	t.fieldXS = em(f, 72)
	t.fieldS = em(f, 120)
	t.fieldM = em(f, 150)
	t.fieldL = em(f, 220)
	t.fieldXL = em(f, 280)
	t.textNarrow = em(f, 260)
	t.textDialog = em(f, 380)
	t.textMeasure = em(f, 420)
	t.textWide = em(f, 600)
	t.dialogS = em(f, 380)
	t.dialogM = em(f, 440)
	t.dialogL = em(f, 520)
	t.dialogSettings = em(f, 640)
	t.dialogWide = em(f, 760)

	t.iconSmall = th.font.size_sm
	t.iconMedium = th.font.size_sm
	t.iconLarge = th.font.size_md
	t.toolButtonWidth = math.round(f * 2.4)
	t.panelButtonWidth = math.round(f * 1.9)
	t.squareButton = em(f, LINK_BUTTON_WIDTH)
	t.iconColumn = em(f, 20)
	t.fieldXXS = em(f, 44)
	t.swatch = em(f, 16)
	return
}

// The tokens for the look shown (`ctx.theme`, the Settings dialog's draft while it's open)
uiTokens :: proc(ctx: ^skald.Ctx(Msg)) -> Ui_Tokens {
	return UiTokens_Of(ctx.theme, uiRowHeight > 0 ? uiRowHeight : TOKENS_DEFAULT_ROW_HEIGHT)
}

/*
The text hierarchy: every label in the editor is one of these (`uiText`), so a size or color change
is one place. Sizes are Skald's text sizes (scaled by the Text size setting), colors the theme's.
*/
Text_Role :: enum {
	// A dialog's or window's title (Settings, Add Node, the docs window's page title)
	Title,
	// A panel header's title, a tab's name (`panelHeader`, the tab strips)
	Panel_Title,
	// A section's header inside a panel, dialog or Settings page ("Colors", "Size and shape"): the
	// values' size and color, set apart by the section gap above it (`uiSection`)
	Section,
	// A form row's label (the inspector's, Settings')
	Label,
	// A value shown as text, a list item, a button's caption
	Value,
	// Secondary text: help under a row, captions, counts, hints, placeholders
	Muted,
	// Code, paths and numbers that line up (the Console, the docs' code): the code editor's font
	Code,
}

// A role's text size and color in a theme
TextRole_Style :: proc(th: ^skald.Theme, role: Text_Role) -> (size: f32, color: skald.Color) {
	switch role {
	case .Title:       return th.font.size_lg, th.color.fg
	case .Panel_Title: return th.font.size_sm, th.color.fg
	case .Section:     return th.font.size_sm, th.color.fg
	case .Label:       return th.font.size_sm, th.color.fg_muted
	case .Value:       return th.font.size_sm, th.color.fg
	case .Muted:       return th.font.size_xs, th.color.fg_muted
	case .Code:        return th.font.size_sm, th.color.fg
	}
	return th.font.size_sm, th.color.fg
}

/*
A text in one of the hierarchy's roles. `color` overrides the role's color (a warning's, a kind's
tint) and keeps its size.
*/
uiText :: proc(th: ^skald.Theme, role: Text_Role, str: string, max_width: f32 = 0, overflow := skald.Text_Overflow.Visible,
	align := skald.Cross_Align.Start, color := skald.Color{}) -> skald.View {
	size, fg := TextRole_Style(th, role)
	if color[3] != 0 do fg = color
	font := role == .Code ? uiMonoFont : skald.Font(0)
	return skald.text(str, fg, size, font, max_width = max_width, overflow = overflow, align = align)
}

/*
A section's header: the section gap above it, then its title (`Text_Role.Section`). Every panel,
dialog and Settings page starts its sections with it, so sections are one distance apart.
*/
uiSection :: proc(th: ^skald.Theme, tk: Ui_Tokens, title: string, max_width: f32 = 0) -> skald.View {
	return skald.col(skald.spacer(tk.sectionGap), uiText(th, .Section, title, max_width = max_width))
}

/*
The monospace font (the code editor's: `CODE_FONT`) for `Text_Role.Code`, loaded once by `view`
(`uiLoadFonts`); 0 (the default font) until then.
*/
uiMonoFont: skald.Font
@(private="file")
uiMonoLoaded: bool

// Loads the hierarchy's fonts once (called by `view`)
uiLoadFonts :: proc(ctx: ^skald.Ctx(Msg)) {
	if uiMonoLoaded || ctx.renderer == nil do return
	uiMonoFont = skald.font_load(ctx.renderer, "ui-mono", CODE_FONT)
	uiMonoLoaded = true
}
