package code_editor

import buf "../buffer"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

// What the preview providers saw (their user data)
@(private="file")
Preview_Probe :: struct {
	widget_clicks:  int,
	clicked_at:     [2]f32,
	swatch_clicks:  int,
	swatch_id:      int,
	replace_server: bool,
}

@(private="file")
preview_registry :: proc(probe: ^Preview_Probe) -> Provider_Registry {
	reg: Provider_Registry
	provider_register(&reg, Provider{kind = .Hover, name = "previews", user_data = probe, hover = proc(doc: Provider_Document, pos: buf.Position, ctx: Provider_Context, out: ^Hover_Content) {
		p := (^Preview_Probe)(ctx.user_data)
		append(&out.blocks, Hover_Block(Hover_Text{text = "jump.wav: 0:01.2"}))
		// A strip of frames: 6 of 40 px, wider than tall
		strip := make([]u8, 240 * 40 * 4, ctx.allocator)
		append(&out.blocks, Hover_Block(Hover_Image{pixels = strip, width = 240, height = 40}))
		append(&out.blocks, Hover_Block(Hover_Widget{width = 40, height = 20, data = p,
			draw = proc(renderer: ^sdl.Renderer, rect: sdl.FRect, data: rawptr) {},
			click = proc(x, y: f32, data: rawptr) -> bool {
				p := (^Preview_Probe)(data)
				p.widget_clicks += 1
				p.clicked_at = {x, y}
				return true
			},
		}))
		out.replace_server = p.replace_server
	}})
	provider_register(&reg, Provider{kind = .Inlay, name = "colors", user_data = probe,
		inlay = proc(doc: Provider_Document, ctx: Provider_Context, out: ^[dynamic]Inlay_Hint) {
			append(out, Inlay_Hint{pos = {0, 5}, swatch = sdl.Color{255, 0, 0, 255}, id = 1})
			append(out, Inlay_Hint{pos = {0, 9}, swatch = sdl.Color{0, 0, 255, 128}, label = "50%", id = 2})
		},
		on_inlay_click = proc(doc: Provider_Document, hint: Inlay_Hint, user_data: rawptr) {
			p := (^Preview_Probe)(user_data)
			p.swatch_clicks += 1
			p.swatch_id = hint.id
		},
	})
	return reg
}

// A hover's widget takes a press (the hover stays open), a strip image may be twice as wide as tall,
// and a provider can stand in for the server's answer
@(test)
test_provider_hover_widgets_take_clicks :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		probe: Preview_Probe
		reg := preview_registry(&probe)
		defer provider_registry_destroy(&reg)
		ed := make_diag_editor("JUMP :: \"jump.wav\"\nx := 1\ny := 2\nz := 3\nw := 4\nv := 5\nu := 6\nt := 7\ns := 8\nr := 9\nq := 10\np := 11\n")
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)
		// Hovered from below so the hover fits above: line 11
		mouse_move(&ed, editor_gutter_width(&ed) + 1 * 10 + 5, 11 * 20 + 10)
		ed.diag_tip.hover_since = time.tick_add(time.tick_now(), -DIAG_HOVER_DELAY)
		editor_update(&ed)
		rect, lines, ok := editor_hover_layout(&ed)
		testing.expect(t, ok, "the hover shows")
		w, h := hover_block_size(ed.provided.hover[1])
		testing.expect_value(t, w, f32(240))
		testing.expect_value(t, h, f32(40))
		// The widget's first line
		row := -1
		for l, i in lines do if l.block == 3 && l.block_row == 0 { row = i; break }
		testing.expect(t, row >= 0, "the widget has lines")
		x := rect.x + POPUP_PAD + 10
		y := rect.y + POPUP_PAD + f32(row) * ed.char_h + 5
		mouse_click(&ed, x, y)
		testing.expect_value(t, probe.widget_clicks, 1)
		testing.expect_value(t, probe.clicked_at, [2]f32{10, 5})
		testing.expect(t, ed.hover.visible, "the hover stays open")
		// A press beside the widget goes to the text (the hover closes)
		mouse_click(&ed, x + 100, y)
		testing.expect_value(t, probe.widget_clicks, 1)
		testing.expect(t, !ed.hover.visible, "a press elsewhere closes it")

		// Standing in for the server: it isn't asked, its answer isn't shown
		probe.replace_server = true
		mouse_move(&ed, editor_gutter_width(&ed) + 2 * 10 + 5, 10 * 20 + 10)
		ed.diag_tip.hover_since = time.tick_add(time.tick_now(), -DIAG_HOVER_DELAY)
		editor_update(&ed)
		testing.expect(t, ed.hover.visible && !ed.hover.requested, "the server isn't asked")
		testing.expect(t, ed.provided.hover_replaces_server, "noted")
	})
}

// A swatch inlay draws before its label and a click on it calls its provider with the hint
@(test)
test_provider_swatch_inlays_take_clicks :: proc(t: ^testing.T) {
	run_leak_free(t, proc(t: ^testing.T) {
		probe: Preview_Probe
		reg := preview_registry(&probe)
		defer provider_registry_destroy(&reg)
		ed := make_diag_editor("tint := sdl.Color{255, 0, 0, 255}\nx := 1\n")
		defer editor_destroy(&ed)
		editor_set_providers(&ed, &reg)
		editor_run_cached_providers(&ed)
		testing.expect_value(t, len(editor_inlays_on(&ed, 0)), 2)
		testing.expect_value(t, len(ed.provided.inlay_providers), 2)
		places := editor_inlay_places(&ed, 0, editor_gutter_width(&ed))
		testing.expect_value(t, places[0].swatch_w, f32(INLAY_SWATCH_COLS * 10))
		testing.expect(t, places[1].x > places[0].x + places[0].swatch_w, "the second after the first")
		x, y, ok := editor_inlay_swatch_point(&ed, 0, 1)
		testing.expect(t, ok, "the second swatch is in view")
		mouse_click(&ed, x, y)
		testing.expect_value(t, probe.swatch_clicks, 1)
		testing.expect_value(t, probe.swatch_id, 2)
		// Past the swatches: the text's (the caret moves, no callback)
		mouse_click(&ed, x + 200, y)
		testing.expect_value(t, probe.swatch_clicks, 1)
		_, _, ok = editor_inlay_swatch_point(&ed, 1, 0)
		testing.expect(t, !ok, "no swatch on line 2")
	})
}
