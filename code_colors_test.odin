package crossfire_editor

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import "gui:skald"

// Which color literals a line has, read and written back in their own form
@(test)
code_color_literals_parse_and_write :: proc(t: ^testing.T) {
	Case :: struct { line: string, colors: [][4]u8, forms: []ColorLiteralForm }
	cases := []Case{
		{"\ttint = sdl.Color{255, 128, 0, 255}", {{255, 128, 0, 255}}, {.Composite}},
		{"x := sdl.Color{0x10, 0x20, 0x30}", {{0x10, 0x20, 0x30, 0}}, {.Composite}},
		{"popup :: proc(color: sdl.Color = {255, 230, 140, 255}, b := sdl.Color{r = 1, g = 2, b = 3, a = 4}) {", {{255, 230, 140, 255}, {1, 2, 3, 4}}, {.Composite, .Named}},
		{"\ttint: sdl.Color `export:\"default=#ff8000\"`,", {{255, 128, 0, 255}}, {.Hex}},
		{"c, _ := e.ParseColor(\"#10203040\")", {{0x10, 0x20, 0x30, 0x40}}, {.Hex}},
		// Not literals the editor can read back: an expression, out of range, a comment, another type
		{"x := sdl.Color{v, 0, 0, 255}", {}, {}},
		{"x := sdl.Color{300, 0, 0, 255}", {}, {}},
		{"// sdl.Color{1, 2, 3, 4}", {}, {}},
		{"x := mysdl.Color{1, 2, 3, 4}", {}, {}},
		{"name: string `export:\"default=#ff8000\"`,", {}, {}},
	}
	for c in cases {
		found := ColorLiterals_InLine(c.line, "sdl", "e")
		if !testing.expectf(t, len(found) == len(c.colors), "%q: %d literals (%d)", c.line, len(c.colors), len(found)) do continue
		for lit, i in found {
			testing.expectf(t, lit.color == c.colors[i] && lit.form == c.forms[i], "%q: %v %v", c.line, lit.color, lit.form)
			// Written back with its own color: the same color read again
			again := ColorLiteral_Write(c.line[lit.start:lit.end], lit.form, lit.color)
			line := strings.concatenate({c.line[:lit.start], again, c.line[lit.end:]}, context.temp_allocator)
			reread := ColorLiterals_InLine(line, "sdl", "e")
			testing.expectf(t, len(reread) == len(found) && reread[i].color == lit.color, "%q written back: %q", c.line, line)
		}
	}
	testing.expect_value(t, ColorLiteral_Write("{255, 0, 0, 255}", .Composite, {1, 2, 3, 4}), "{1, 2, 3, 4}")
	testing.expect_value(t, ColorLiteral_Write("{0xff, 0, 0, 0xff}", .Composite, {1, 2, 3, 4}), "{0x01, 0x02, 0x03, 0x04}")
	testing.expect_value(t, ColorLiteral_Write("{r = 1}", .Named, {1, 2, 3, 4}), "{r = 1, g = 2, b = 3, a = 4}")
	testing.expect_value(t, ColorLiteral_Write("#ff0000", .Hex, {0, 255, 0, 255}), "#00ff00")
	testing.expect_value(t, ColorLiteral_Write("#ff0000", .Hex, {0, 255, 0, 128}), "#00ff0080")
	// Another import name
	testing.expect_value(t, len(ColorLiterals_InLine("x := sdl3.Color{1, 2, 3, 4}", "sdl3", "e")), 1)
	free_all(context.temp_allocator)
}

// In a real code tab: swatches on the literals, a click opens the dialog, OK rewrites the literal
// as one undo step
@(test)
code_color_swatches_in_a_code_tab :: proc(t: ^testing.T) {
	sync.guard(&previewTestLock)
	defer CodeEditor_Shutdown()
	base := testTempBase()
	dir, _ := filepath.join({base, "editor_test_code_colors"}, context.temp_allocator)
	_ = removeAll(dir)
	defer removeAll(dir)
	folder := joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(folder)
	path := absolutePath(joinPath(folder, "tints.odin", allocator = context.temp_allocator))
	SOURCE :: "package scripts\n\nimport e \"engine:.\"\nimport sdl \"vendor:sdl3\"\n\nTints :: struct {\n\tusing script: e.Script,\n\ttint: sdl.Color `export:\"default=#ff8000\"`,\n}\n\nred :: proc() -> sdl.Color { return sdl.Color{255, 0, 0, 255} }\n"
	_ = os.write_entire_file(path, transmute([]u8)string(SOURCE))
	path = absolutePath(path)
	state := State{project = Project_CreateTestProject(dir), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(), currentScene = 1}
	defer State_Destroy(&state)
	state.settings.olsPath = FixedText_Make("/nonexistent/ols")
	state.settings.builtInCodeEditor = true
	_ = Script_Open(&state, path, 1)
	c := CodeEditor_Find(path)
	if !testing.expect(t, c != nil, "the code tab opened") do return

	CodeProviders_Begin(&state)
	ce.editor_run_cached_providers(&c.ed)
	CodeProviders_End()
	testing.expect(t, CodeEditor_HasSwatch(path, 7), "the tag's hex")
	testing.expect(t, CodeEditor_HasSwatch(path, 10), "the composite")
	testing.expect(t, !CodeEditor_HasSwatch(path, 6), "no color there")

	// The composite's swatch clicked (as the code editor calls it): the dialog's request
	line := cebuf.buffer_line_str(&c.ed.buf, 10)
	end := strings.index(line, "255} }") + 4
	CodeProviders_Begin(&state)
	colorSwatchClicked(ce.editor_provider_document(&c.ed), ce.Inlay_Hint{pos = {10, end}}, nil)
	CodeProviders_End()
	request, ok := CodeColors_TakeRequest()
	if !testing.expect(t, ok && request.color == {255, 0, 0, 255} && request.form == .Composite, "the literal's request") do return
	state, _ = update(state, Msg(request))
	testing.expect(t, state.codeColor.open, "the dialog opens")
	testing.expect_value(t, state.codeColor.hex, "#ff0000")
	state, _ = update(state, Msg(Code_Color_Hex_Changed("#00ff00")))
	state, _ = update(state, Msg(Code_Color_Alpha_Changed(128)))
	testing.expect_value(t, state.codeColor.color, [4]u8{0, 255, 0, 128})
	// The picker's colors are linear: they come back as the same sRGB bytes
	state, _ = update(state, Msg(Code_Color_Changed(skald.rgb(0x3080c0))))
	testing.expect_value(t, state.codeColor.color, [4]u8{0x30, 0x80, 0xc0, 128})
	state, _ = update(state, Msg(Code_Color_Applied{}))
	testing.expect(t, !state.codeColor.open, "OK closes it")
	testing.expect(t, strings.contains(cebuf.buffer_line_str(&c.ed.buf, 10), "sdl.Color{48, 128, 192, 128}"), "rewritten")
	// One undo step puts it back
	cebuf.buffer_undo(&c.ed.buf)
	testing.expect(t, strings.contains(cebuf.buffer_line_str(&c.ed.buf, 10), "sdl.Color{255, 0, 0, 255}"), "undone")

	// The tag's hex: written as hex; a literal changed meanwhile isn't touched
	hexLine := cebuf.buffer_line_str(&c.ed.buf, 7)
	hexEnd := strings.index(hexLine, "#ff8000") + 7
	CodeProviders_Begin(&state)
	colorSwatchClicked(ce.editor_provider_document(&c.ed), ce.Inlay_Hint{pos = {7, hexEnd}}, nil)
	CodeProviders_End()
	request, ok = CodeColors_TakeRequest()
	testing.expect(t, ok && request.form == .Hex, "the hex's request")
	state, _ = update(state, Msg(request))
	state, _ = update(state, Msg(Code_Color_Hex_Changed("#123456")))
	state, _ = update(state, Msg(Code_Color_Applied{}))
	testing.expect(t, strings.contains(cebuf.buffer_line_str(&c.ed.buf, 7), "default=#123456"), "hex rewritten")
	state, _ = update(state, Msg(request))
	state, _ = update(state, Msg(Code_Color_Applied{}))
	testing.expect(t, strings.contains(cebuf.buffer_line_str(&c.ed.buf, 7), "default=#123456"), "a stale literal isn't touched")
	free_all(context.temp_allocator)
}
