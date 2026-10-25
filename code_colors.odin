package crossfire_editor

import "core:fmt"
import "core:strconv"
import "core:strings"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import "gui:skald"
import sdl "vendor:sdl3"

/*
Color literals in the code: a swatch after the line (an inlay hint with `swatch`, code_editor's
providers.odin), and a click on it opens the Color dialog (Skald's color picker, the hex, the
alpha), whose OK rewrites the literal in place: one edit, one undo step in the code tab.

The engine's color type is `sdl.Color` (`[4]u8`: r, g, b, a). What counts as one of its literals
(`ColorLiterals_InLine`):
- a typed composite literal, `sdl.Color{255, 128, 0, 255}` (whatever the file imports
  vendor:sdl3 as), with three or four integer values (decimal or `0x`) or named ones
  (`{r = 255, g = 128, b = 0, a = 255}`)
- an untyped one given to a declared color, `tint: sdl.Color = {255, 255, 255, 255}`
- hex text where the engine reads it: an exported color field's default in its tag
  (`tint: sdl.Color \`export:"default=#ff8000"\``, the engine's `#rrggbb` / `#rrggbbaa`) and the
  argument of `e.ParseColor("#ff8000")`

A value written as anything else (a constant, an expression) gets no swatch: the editor only
rewrites what it can read back. The rewrite keeps the literal's form: composites keep their
names or positions and get four values; hex gets `#rrggbb`, or `#rrggbbaa` when not opaque (the
engine's FormatColor).
*/

// How a color literal is written
ColorLiteralForm :: enum {
	// `{r, g, b, a}` (typed or not), positional
	Composite,
	// `{r = .., g = .., b = .., a = ..}`
	Named,
	// `#rrggbb` / `#rrggbbaa` in a string or tag
	Hex,
}

// A color literal on a line: the bytes the rewrite replaces (`start ..< end`: the braces, or the
// hex text with its `#`) and the color it says
ColorLiteral :: struct {
	start, end: int,
	color:      [4]u8,
	form:       ColorLiteralForm,
}

/*
The color literals on a line of code (this file's doc: which ones count).

Inputs:
- line: The line's text
- sdlAlias: The file's import name of vendor:sdl3 ("sdl")
- engineAlias: The file's import name of the engine ("e"), for `e.ParseColor`

Returns:
- The literals, left to right (temp allocated)
*/
ColorLiterals_InLine :: proc(line, sdlAlias, engineAlias: string) -> []ColorLiteral {
	out := make([dynamic]ColorLiteral, context.temp_allocator)
	code := line
	if comment := commentStart(line); comment >= 0 do code = line[:comment]
	typeName := fmt.tprintf("%s.Color", sdlAlias)
	// Composites: `sdl.Color{`, or `sdl.Color = {`
	for at := 0; at < len(code); {
		i := strings.index(code[at:], typeName)
		if i < 0 do break
		i += at
		at = i + len(typeName)
		if i > 0 && isIdentByte(code[i - 1]) do continue
		if at < len(code) && isIdentByte(code[at]) do continue
		// `sdl.Color{` right after the type, or `sdl.Color = {` (not `-> sdl.Color {`: a body)
		rest := at
		if rest < len(code) && code[rest] != '{' {
			for rest < len(code) && (code[rest] == ' ' || code[rest] == '\t') do rest += 1
			if rest >= len(code) || code[rest] != '=' do continue
			rest += 1
			for rest < len(code) && (code[rest] == ' ' || code[rest] == '\t') do rest += 1
		}
		if rest >= len(code) || code[rest] != '{' do continue
		close := strings.index_byte(code[rest:], '}')
		if close < 0 do continue
		end := rest + close + 1
		if color, form, ok := parseComposite(code[rest + 1:end - 1]); ok {
			append(&out, ColorLiteral{rest, end, color, form})
			at = end
		}
	}
	// Hex in a color field's tag (`default=#...`) or e.ParseColor("#...")
	hexAt :: proc(out: ^[dynamic]ColorLiteral, code: string, from: int) {
		end := from + 1
		for end < len(code) && isHexByte(code[end]) do end += 1
		if color, ok := parseHexColor(code[from:end]); ok do append(out, ColorLiteral{from, end, color, .Hex})
	}
	if strings.contains(code, typeName) {
		if tag := strings.index(code, "default=#"); tag >= 0 && strings.index_byte(code, '`') >= 0 do hexAt(&out, code, tag + len("default="))
	}
	parse := fmt.tprintf("%s.ParseColor(\"#", engineAlias)
	for at := 0; at < len(code); {
		i := strings.index(code[at:], parse)
		if i < 0 do break
		i += at
		at = i + len(parse)
		hexAt(&out, code, at - 1)
	}
	// Left to right
	for i in 1 ..< len(out) {
		for j := i; j > 0 && out[j].start < out[j - 1].start; j -= 1 do out[j], out[j - 1] = out[j - 1], out[j]
	}
	return out[:]
}

// Where a line's `//` comment starts, outside strings (-1 none)
@(private="file")
commentStart :: proc(line: string) -> int {
	quote: u8
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		if quote != 0 {
			if quote == '"' && c == '\\' do i += 1
			else if c == quote do quote = 0
			continue
		}
		if c == '"' || c == '`' || c == '\'' do quote = c
		else if c == '/' && i + 1 < len(line) && line[i + 1] == '/' do return i
	}
	return -1
}

@(private="file")
isIdentByte :: proc(c: u8) -> bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

@(private="file")
isHexByte :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F'
}

// `255, 128, 0` or `r = 255, ...`: integers 0 to 255 only
@(private="file")
parseComposite :: proc(inner: string) -> (color: [4]u8, form: ColorLiteralForm, ok: bool) {
	parts := strings.split(inner, ",", context.temp_allocator)
	values := make([dynamic]string, context.temp_allocator)
	for p in parts do if t := strings.trim_space(p); t != "" do append(&values, t)
	if len(values) < 3 || len(values) > 4 do return
	color = {0, 0, 0, 0}
	named := strings.contains(values[0], "=")
	form = named ? .Named : .Composite
	for v, i in values {
		text := v
		channel := i
		if named {
			name, _, value := strings.partition(v, "=")
			switch strings.trim_space(name) {
			case "r": channel = 0
			case "g": channel = 1
			case "b": channel = 2
			case "a": channel = 3
			case: return
			}
			text = strings.trim_space(value)
		} else if strings.contains(v, "=") {
			return
		}
		n, parsed := strconv.parse_int(text)
		if !parsed || n < 0 || n > 255 do return
		color[channel] = u8(n)
	}
	return color, form, true
}

// `#rrggbb` or `#rrggbbaa` (the engine's ParseColor)
@(private="file")
parseHexColor :: proc(text: string) -> (color: [4]u8, ok: bool) {
	if len(text) != 7 && len(text) != 9 || text[0] != '#' do return
	color.a = 255
	for i in 0 ..< (len(text) - 1) / 2 {
		n, parsed := strconv.parse_int(text[1 + i * 2:][:2], 16)
		if !parsed do return
		color[i] = u8(n)
	}
	return color, true
}

/*
A color literal written again with another color, in its own form.

Inputs:
- old: The literal's text as it is (the braces, or the hex)
- form: How it's written
- color: The new color

Returns:
- The new text (temp allocated)
*/
ColorLiteral_Write :: proc(old: string, form: ColorLiteralForm, color: [4]u8) -> string {
	switch form {
	case .Hex:
		if color.a == 255 do return fmt.tprintf("#%02x%02x%02x", color.r, color.g, color.b)
		return fmt.tprintf("#%02x%02x%02x%02x", color.r, color.g, color.b, color.a)
	case .Named:
		return fmt.tprintf("{{r = %d, g = %d, b = %d, a = %d}}", color.r, color.g, color.b, color.a)
	case .Composite:
	}
	// Hex values stay hex
	if strings.contains(old, "0x") || strings.contains(old, "0X") {
		return fmt.tprintf("{{0x%02x, 0x%02x, 0x%02x, 0x%02x}}", color.r, color.g, color.b, color.a)
	}
	return fmt.tprintf("{{%d, %d, %d, %d}}", color.r, color.g, color.b, color.a)
}

// A file's import names of vendor:sdl3 and the engine, from its import lines ("" when it has none)
@(private)
colorAliases :: proc(doc: ce.Provider_Document) -> (sdlAlias, engineAlias: string) {
	count := cebuf.buffer_line_count(doc.buffer)
	for i in 0 ..< min(count, 80) {
		line := strings.trim_space(cebuf.buffer_line_str(doc.buffer, i))
		if !strings.has_prefix(line, "import ") do continue
		rest := strings.trim_space(line[len("import "):])
		name := ""
		if !strings.has_prefix(rest, "\"") {
			name, _, rest = strings.partition(rest, " ")
			rest = strings.trim_space(rest)
		}
		path := strings.trim(rest, "\"")
		switch path {
		case "vendor:sdl3": sdlAlias = name != "" ? name : "sdl3"
		case "engine:.", "engine:": engineAlias = name != "" ? name : "crossfire"
		}
	}
	return
}

// --- the provider: swatches and their clicks ------------------------------------------

// The swatches of a document: one inlay hint per literal, at its end (id: the literal's index on
// its line)
@(private)
colorInlays :: proc(doc: ce.Provider_Document, ctx: ce.Provider_Context, out: ^[dynamic]ce.Inlay_Hint) {
	state := codeProvidersState()
	if !isProjectScript(state, doc.path) do return
	sdlAlias, engineAlias := colorAliases(doc)
	if sdlAlias == "" do return
	for i in 0 ..< cebuf.buffer_line_count(doc.buffer) {
		line := cebuf.buffer_line_str(doc.buffer, i)
		if !strings.contains(line, "Color") do continue
		for lit, n in ColorLiterals_InLine(line, sdlAlias, engineAlias) {
			append(out, ce.Inlay_Hint{pos = {i, lit.end}, swatch = sdl.Color{lit.color.r, lit.color.g, lit.color.b, lit.color.a}, id = n})
		}
	}
}

// A swatch clicked: the dialog opens for its literal (sent by the code view: Code_Color_Requested)
@(private)
colorSwatchClicked :: proc(doc: ce.Provider_Document, hint: ce.Inlay_Hint, user_data: rawptr) {
	if hint.pos.line < 0 || hint.pos.line >= cebuf.buffer_line_count(doc.buffer) do return
	sdlAlias, engineAlias := colorAliases(doc)
	line := cebuf.buffer_line_str(doc.buffer, hint.pos.line)
	for lit in ColorLiterals_InLine(line, sdlAlias, engineAlias) {
		if lit.end != hint.pos.col do continue
		codeColors.request = Code_Color_Requested{
			path = strings.clone(doc.path), line = hint.pos.line, start = lit.start, end = lit.end,
			text = strings.clone(line[lit.start:lit.end]), color = lit.color, form = lit.form,
		}
		return
	}
}

// Open the Color dialog for a literal (owned strings in the request; copied in update)
Code_Color_Requested :: struct {
	path: string,
	// Its line (0-based) and bytes, and its text then (it's checked again before the rewrite)
	line, start, end: int,
	text: string,
	color: [4]u8,
	form: ColorLiteralForm,
}
// The picker changed the color (its alpha stays)
Code_Color_Changed :: distinct skald.Color
// The hex field typed (`#rrggbb` or `#rrggbbaa`)
Code_Color_Hex_Changed :: distinct string
Code_Color_Alpha_Changed :: distinct f32
Code_Color_Applied :: struct {}
Code_Color_Cancelled :: struct {}

// The Color dialog (State.codeColor)
CodeColorDialog :: struct {
	open: bool,
	// The literal (`Code_Color_Requested`, strings owned)
	literal: Code_Color_Requested,
	color: [4]u8,
	// The hex field's text (owned)
	hex: string,
}

@(private="file")
codeColors: struct {
	// A swatch's click, for the code view to send (owned strings)
	request: Maybe(Code_Color_Requested),
}

// The swatch's request, once (strings temp allocated)
CodeColors_TakeRequest :: proc() -> (Code_Color_Requested, bool) {
	r, ok := codeColors.request.?
	if !ok do return {}, false
	codeColors.request = nil
	out := r
	out.path = strings.clone(r.path, context.temp_allocator)
	out.text = strings.clone(r.text, context.temp_allocator)
	delete(r.path)
	delete(r.text)
	return out, true
}

// Frees the dialog's strings
CodeColorDialog_Destroy :: proc(d: ^CodeColorDialog) {
	delete(d.literal.path)
	delete(d.literal.text)
	delete(d.hex)
	d^ = {}
}

// Frees the package state (tests, quitting)
CodeColors_Shutdown :: proc() {
	if r, ok := codeColors.request.?; ok { delete(r.path); delete(r.text) }
	codeColors = {}
}

@(private="file")
hexOf :: proc(c: [4]u8) -> string {
	return ColorLiteral_Write("", .Hex, c)
}

/*
The Color dialog's messages: opened by a swatch, edited by the picker, the hex and the alpha, and
OK writing the literal (one edit in the code tab: one undo step there).

Returns:
- A command, and whether `m` was one of them
*/
CodeColors_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	d := &state.codeColor
	#partial switch v in m {
	case Code_Color_Requested:
		CodeColorDialog_Destroy(d)
		d.open = true
		d.literal = v
		d.literal.path = strings.clone(v.path)
		d.literal.text = strings.clone(v.text)
		d.color = v.color
		d.hex = strings.clone(hexOf(v.color))
		return {}, true
	case Code_Color_Changed:
		c := skald.Color(v)
		srgb := [3]u8{linearByte(c[0]), linearByte(c[1]), linearByte(c[2])}
		d.color = {srgb[0], srgb[1], srgb[2], d.color.a}
		delete(d.hex)
		d.hex = strings.clone(hexOf(d.color))
		return {}, true
	case Code_Color_Hex_Changed:
		delete(d.hex)
		d.hex = strings.clone(string(v))
		text := strings.trim_space(string(v))
		if !strings.has_prefix(text, "#") do text = fmt.tprintf("#%s", text)
		if color, ok := parseHexColor(text); ok do d.color = color
		return {}, true
	case Code_Color_Alpha_Changed:
		d.color.a = u8(clamp(f32(v), 0, 255) + 0.5)
		delete(d.hex)
		d.hex = strings.clone(hexOf(d.color))
		return {}, true
	case Code_Color_Cancelled:
		CodeColorDialog_Destroy(d)
		return {}, true
	case Code_Color_Applied:
		defer CodeColorDialog_Destroy(d)
		message := CodeColors_Rewrite(d.literal, d.color)
		logLine(state, message == "" ? .Info : .Warning, strings.clone(message == "" ? fmt.tprintf("Color set to %s", hexOf(d.color)) : message))
		return {}, true
	}
	return {}, false
}

// A linear Skald channel as an sRGB byte
@(private="file")
linearByte :: proc(c: f32) -> u8 {
	srgb := skald.color_to_hex(skald.Color{c, c, c, 1})
	n, _ := strconv.parse_int(srgb[:2], 16)
	return u8(n)
}

/*
Writes a literal again with a color, in the code tab that has it: one edit (one undo step there).
The literal must still be where it was, as it was (the code may have changed while the dialog
was open).

Returns:
- "" or why it wasn't written (temp allocated)
*/
CodeColors_Rewrite :: proc(literal: Code_Color_Requested, color: [4]u8) -> string {
	text, _, _ := CodeEditor_Buffer(literal.path, true)
	lines := strings.split_lines(text, context.temp_allocator)
	if literal.line >= len(lines) || literal.end > len(lines[literal.line]) || lines[literal.line][literal.start:literal.end] != literal.text {
		return "The color's literal changed in the code meanwhile: nothing was written"
	}
	edit := ce.Text_Edit{start = {literal.line, literal.start}, end = {literal.line, literal.end}, text = ColorLiteral_Write(literal.text, literal.form, color)}
	if !CodeEditor_ApplyEdits(literal.path, {edit}) do return "The code tab with the color isn't open"
	return ""
}

/*
The Color dialog: the literal as written, Skald's color picker, the hex (`code-color-hex`), the
alpha (`code-color-alpha`), OK (`code-color-ok`) and Cancel (`code-color-cancel`).
*/
CodeColorDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	if !s.codeColor.open do return closedDialog(ctx, "code-color-dialog")
	th := ctx.theme
	d := &s.codeColor
	linear := skald.rgb(u32(d.color.r) << 16 | u32(d.color.g) << 8 | u32(d.color.b))
	label :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
		tk := uiTokens(ctx)
		return skald.col(uiText(ctx.theme, .Value, text), width = tk.fieldXS)
	}
	return skald.dialog(ctx,
		open = true,
		on_dismiss = proc() -> Msg { return Code_Color_Cancelled{} },
		on_confirm = proc() -> Msg { return Code_Color_Applied{} },
		content = skald.col(
			uiText(th, .Title, "Color"),
			uiText(th, .Muted, fmt.tprintf("%s, line %d: %s", filenameOf(d.literal.path), d.literal.line + 1, d.literal.text), max_width = tk.textDialog),
			skald.row(label(ctx, "Color"),
				skald.color_picker(ctx, linear, proc(c: skald.Color) -> Msg { return Code_Color_Changed(c) }, id = skald.hash_id("code-color-picker"), width = tk.fieldL),
				spacing = th.spacing.sm, cross_align = .Center),
			skald.row(label(ctx, "Hex"),
				skald.text_input(ctx, d.hex, proc(v: string) -> Msg { return Code_Color_Hex_Changed(v) }, id = skald.hash_id("code-color-hex"), width = tk.fieldL),
				spacing = th.spacing.sm, cross_align = .Center),
			skald.row(label(ctx, "Alpha"),
				skald.slider(ctx, f32(d.color.a), proc(v: f32) -> Msg { return Code_Color_Alpha_Changed(v) }, id = skald.hash_id("code-color-alpha"), min_value = 0, max_value = 255, step = 1, width = tk.fieldM),
				uiText(th, .Label, fmt.tprintf("%d", d.color.a)),
				spacing = th.spacing.sm, cross_align = .Center),
			uiText(th, .Muted, fmt.tprintf("Writes %s", ColorLiteral_Write(d.literal.text, d.literal.form, d.color)), max_width = tk.textDialog),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(Code_Color_Cancelled{}), id = skald.hash_id("code-color-cancel"), bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, "OK", Msg(Code_Color_Applied{}), id = skald.hash_id("code-color-ok"), font_size = th.font.size_sm),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("code-color-dialog"),
		width = tk.dialogS,
	)
}

@(private="file")
filenameOf :: proc(path: string) -> string {
	i := strings.last_index_any(path, "/\\")
	return i >= 0 ? path[i + 1:] : path
}
