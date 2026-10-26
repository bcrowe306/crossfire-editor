package crossfire_editor

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "gui:skald"

@(private="file")
near :: proc(a, b: [2]f32) -> bool {
	return math.abs(a.x - b.x) < 0.01 && math.abs(a.y - b.y) < 0.01
}

/*
The tileset views' transform (tile_zoom.odin): Fit shows the whole tileset; zooming around a
point keeps that point over the same tileset pixel; pans stop at the tileset's edges; and a tile
is hit where it's drawn at every zoom and pan (one transform for both).
*/
@(test)
tile_zoom_transform_zooms_pans_and_hits_tiles :: proc(t: ^testing.T) {
	content := [2]f32{256, 128}
	rect := skald.Rect{40, 30, 128, 128}
	// Fit: the width limits it (half size), centered on the other axis
	fit := TileZoom_Transform({}, content, rect)
	testing.expect_value(t, fit.scale, 0.5)
	testing.expect(t, near(fit.origin, {40, 30 + 32}), "fitted: centered")
	testing.expect_value(t, TileZoom_FitScale({8, 8}, {4000, 4000}), f32(TILE_ZOOM_MAX))

	// Zooming around a point keeps it fixed, from Fit and again from a zoom
	point := [2]f32{90, 100}
	z := TileZoom{}
	for factor in ([]f32{4, 1.15, 2, 0.6}) {
		before := TileZoom_ToContent(TileZoom_Transform(z, content, rect), point)
		z = TileZoom_ZoomAt(z, content, rect, point, factor)
		after := TileZoom_ToContent(TileZoom_Transform(z, content, rect), point)
		testing.expectf(t, near(before, after), "zoom x%v keeps %v (now %v)", factor, before, after)
	}
	testing.expect(t, z.zoom > 0.5, "zoomed in")
	// The zoom's bounds
	testing.expect_value(t, TileZoom_ZoomAt(z, content, rect, point, 1000).zoom, f32(TILE_ZOOM_MAX))
	testing.expect_value(t, TileZoom_ZoomAt(z, content, rect, point, 0.0001).zoom, f32(TILE_ZOOM_MIN))

	// A pan moves the tileset with the pointer, and stops at its edges
	z = {zoom = 2, center = {128, 64}}
	moved := TileZoom_Pan(z, content, rect, {20, -10})
	testing.expect(t, near(moved.center, {118, 69}), "panned")
	far := TileZoom_Pan(z, content, rect, {10000, 10000})
	testing.expect(t, near(far.center, {32, 32}), "the tileset's corner reaches the view's")
	tf := TileZoom_Transform(far, content, rect)
	testing.expect(t, near(tf.origin, {rect.x, rect.y}), "no empty space past the edge")
	// Fit again: zoom 0
	testing.expect_value(t, TileZoom_Transform(TileZoom{}, content, rect), fit)

	// Hit-testing: the middle of each drawn tile is that tile, at several zooms and pans
	grid, spacing, padding := f32(16), f32(2), f32(4)
	cWid, cHei := 13, 6
	for zoom in ([]TileZoom{{}, {zoom = 1, center = {100, 60}}, {zoom = 3.5, center = {200, 90}}, {zoom = 8, center = {20, 20}}}) {
		tz := TileZoom_Transform(zoom, content, rect)
		for cell in ([][2]int{{0, 0}, {5, 2}, {12, 5}, {7, 3}}) {
			src := skald.Rect{padding + f32(cell.x) * (grid + spacing), padding + f32(cell.y) * (grid + spacing), grid, grid}
			drawn := TileZoom_ScreenRect(tz, src)
			hit, on := TileZoom_CellAt(tz, {drawn.x + drawn.w / 2, drawn.y + drawn.h / 2}, grid, spacing, padding, cWid, cHei)
			testing.expectf(t, on && hit == cell, "zoom %v: tile %v hit as %v (on %v)", zoom, cell, hit, on)
		}
	}
	// Off the tileset (the letterbox of a fitted view): no tile
	_, on := TileZoom_CellAt(fit, {rect.x + 10, rect.y + 2}, grid, spacing, padding, cWid, cHei)
	testing.expect(t, !on, "above the tileset")
}

/*
The zooms are kept per tileset view through `Tile_Zoom_Changed`, written to
`.editor/tile_zoom.ini` (not a pan's moves: its release), read again when the project opens; Fit
drops the entry.
*/
@(test)
tile_zooms_are_remembered_per_tileset :: proc(t: ^testing.T) {
	dir := tempDir("crossfire_tile_zoom")
	defer removeAll(dir)
	state := State{project = Project_CreateTestProject("unused"), browserSelection = {kind = .None}, selectedNode = -1, busSelection = -1, settings = Settings_Default()}
	state.settings.builtInCodeEditor = false
	delete(state.project.rootPath)
	state.project.rootPath = strings.clone(dir)
	defer State_Destroy(&state)
	step :: proc(state: ^State, m: Msg) { state^, _ = update(state^, m) }

	palette := TileZoom_Key("palette", 7, "assets/levels/my world.ldtk")
	picker := TileZoom_Key("picker", 7, "assets/levels/my world.ldtk")
	other := TileZoom_Key("palette", 9, "assets/levels/my world.ldtk")
	step(&state, Tile_Zoom_Changed{key = palette, zoom = {zoom = 3, center = {40, 24}}, save = true})
	step(&state, Tile_Zoom_Changed{key = other, zoom = {zoom = 0.5, center = {8, 8}}, save = true})
	// A pan's move isn't written
	step(&state, Tile_Zoom_Changed{key = picker, zoom = {zoom = 2, center = {1, 2}}})
	testing.expect_value(t, TileZoom_Get(&state, picker).zoom, 2)
	testing.expect_value(t, TileZoom_Get(&state, palette), TileZoom{zoom = 3, center = {40, 24}})
	testing.expect_value(t, TileZoom_Get(&state, TileZoom_Key("palette", 8, "x.ldtk")), TileZoom{})

	// Read again: the saved ones (the picker's move came after the last save: not in the file)
	TileZoom_Load(&state)
	testing.expect_value(t, TileZoom_Get(&state, palette), TileZoom{zoom = 3, center = {40, 24}})
	testing.expect_value(t, TileZoom_Get(&state, other).zoom, 0.5)
	testing.expect_value(t, TileZoom_Get(&state, picker), TileZoom{})

	// Fit drops it, from the map and the file
	step(&state, Tile_Zoom_Changed{key = palette, save = true})
	testing.expect_value(t, TileZoom_Get(&state, palette), TileZoom{})
	Mode_Load(&state)
	testing.expect_value(t, TileZoom_Get(&state, palette), TileZoom{})
	testing.expect_value(t, TileZoom_Get(&state, other).zoom, 0.5)
	text, err := os.read_entire_file(joinPath(dir, TILE_ZOOM_FILE, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, err == nil, "written")
	testing.expect_value(t, string(text), TileZoom_Text(state.level.tileZooms))

	// Bad lines are skipped
	zooms: map[string]TileZoom
	defer { TileZoom_Clear(&zooms); delete(zooms) }
	TileZoom_Parse("; comment\nnot a line\n2 x 3 key\n0 1 1 fit\n1.5 10 20 palette 3 a b.ldtk\n", &zooms)
	testing.expect_value(t, len(zooms), 1)
	testing.expect_value(t, zooms["palette 3 a b.ldtk"], TileZoom{zoom = 1.5, center = {10, 20}})
}
