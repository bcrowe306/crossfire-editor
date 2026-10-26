package crossfire_editor

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "gui:skald"

/*
Zoomable tileset views: the Level mode's tile palette and the tabs' tile pickers (the Auto-layer
Rules tab's `rTilePicker`, the definitions' `tilesetPicker`) zoom and pan like the Level canvas.

- **The wheel** does what it does on the canvas (`wheelAction`, Settings > Editor > Wheel pans):
  it zooms around the pointer (Ctrl + wheel with Wheel pans on), Shift + wheel pans sideways,
  Ctrl + wheel up and down. A pan that moves nothing (the tileset fits) leaves the wheel to the
  scroll around the picker.
- **Pan** with a middle drag or Space + drag (the pointer Grab, then Grabbing). The right button
  keeps its LDtk meaning in these views (it removes tiles from the selection), so it doesn't pan.
- **+ / − / Fit** buttons (`tileZoomControls`: keys `<view key>-zoom-out`, `-zoom-in`, `-fit`, the
  zoom shown beside them). Fit (zoom 0, the default) shows the whole tileset.
- **Crisp pixels at every zoom:** the tileset is drawn with Skald's nearest sampling
  (`draw_image_region(..., nearest = true)`).
- **One transform** (`TileZoom_Transform`) draws the view and hit-tests it (`TileZoom_CellAt`), so a
  pick lands on the tile under the pointer at any zoom and pan.
- **Remembered per tileset** (`LevelMode.tileZooms`, keyed by `TileZoom_Key`: the place, the
  tileset's uid and its .ldtk file): the palette and the tabs' pickers each keep their own, saved
  in `.editor/tile_zoom.ini` (`TileZoom_Save`, read with the mode: `TileZoom_Load`).
*/

// The zoom's bounds (screen pixels per tileset pixel); Fit may go under the minimum for a big
// tileset in a small view
TILE_ZOOM_MIN :: 0.25
TILE_ZOOM_MAX :: 16

// Where the tileset views' zooms are kept, in the project's folder
TILE_ZOOM_FILE :: ".editor/tile_zoom.ini"

/*
A tileset view's zoom and pan: `zoom` screen pixels per tileset pixel (0: fitted, the whole
tileset in view), `center` the tileset point at the view's center (tileset pixels; with a zoom).
*/
TileZoom :: struct {
	zoom: f32,
	center: [2]f32,
}

// Tileset pixels to the screen: `screen = origin + point * scale`
TileZoomTransform :: struct {
	origin: [2]f32,
	scale: f32,
}

// The zoom showing all of `content` in `view` (at most TILE_ZOOM_MAX)
TileZoom_FitScale :: proc(content, view: [2]f32) -> f32 {
	if content.x <= 0 || content.y <= 0 || view.x <= 0 || view.y <= 0 do return 1
	return min(view.x / content.x, view.y / content.y, TILE_ZOOM_MAX)
}

// The scale a zoom draws at in `view` (Fit's when 0)
TileZoom_Scale :: proc(z: TileZoom, content, view: [2]f32) -> f32 {
	return z.zoom > 0 ? z.zoom : TileZoom_FitScale(content, view)
}

/*
The center kept so the tileset stays in view: on an axis the tileset fits, its middle; else as
far as its edge reaches the view's.
*/
TileZoom_ClampCenter :: proc(center, content, view: [2]f32, scale: f32) -> [2]f32 {
	out := center
	for i in 0 ..< 2 {
		half := view[i] / (2 * scale)
		if content[i] * scale <= view[i] do out[i] = content[i] / 2
		else do out[i] = clamp(center[i], half, content[i] - half)
	}
	return out
}

/*
The transform a view at `rect` (screen) draws and hit-tests with.

Example:
	t := TileZoom_Transform({}, {256, 128}, {10, 20, 128, 64})
	// Fitted: half size, the tileset's corner at the view's
	assert(t.scale == 0.5 && t.origin == {10, 20})
*/
TileZoom_Transform :: proc(z: TileZoom, content: [2]f32, rect: skald.Rect) -> TileZoomTransform {
	view := [2]f32{rect.w, rect.h}
	scale := TileZoom_Scale(z, content, view)
	center := z.zoom > 0 ? TileZoom_ClampCenter(z.center, content, view, scale) : content / 2
	return {origin = {rect.x + rect.w / 2 - center.x * scale, rect.y + rect.h / 2 - center.y * scale}, scale = scale}
}

// A screen point in tileset pixels
TileZoom_ToContent :: proc(t: TileZoomTransform, screen: [2]f32) -> [2]f32 {
	return (screen - t.origin) / t.scale
}

// A rectangle of tileset pixels on the screen
TileZoom_ScreenRect :: proc(t: TileZoomTransform, r: skald.Rect) -> skald.Rect {
	return {t.origin.x + r.x * t.scale, t.origin.y + r.y * t.scale, r.w * t.scale, r.h * t.scale}
}

// The center a transform shows in `rect`
@(private="file")
transformCenter :: proc(t: TileZoomTransform, rect: skald.Rect) -> [2]f32 {
	return ([2]f32{rect.x + rect.w / 2, rect.y + rect.h / 2} - t.origin) / t.scale
}

/*
The zoom multiplied by `factor` around a screen point, which stays over the same tileset point
(unless the tileset's edge stops it).
*/
TileZoom_ZoomAt :: proc(z: TileZoom, content: [2]f32, rect: skald.Rect, point: [2]f32, factor: f32) -> TileZoom {
	view := [2]f32{rect.w, rect.h}
	t := TileZoom_Transform(z, content, rect)
	fixed := TileZoom_ToContent(t, point)
	scale := clamp(t.scale * factor, min(f32(TILE_ZOOM_MIN), TileZoom_FitScale(content, view)), TILE_ZOOM_MAX)
	origin := point - fixed * scale
	center := ([2]f32{rect.x + rect.w / 2, rect.y + rect.h / 2} - origin) / scale
	return {zoom = scale, center = TileZoom_ClampCenter(center, content, view, scale)}
}

// The view moved by `delta` screen pixels (the tileset follows the pointer)
TileZoom_Pan :: proc(z: TileZoom, content: [2]f32, rect: skald.Rect, delta: [2]f32) -> TileZoom {
	view := [2]f32{rect.w, rect.h}
	t := TileZoom_Transform(z, content, rect)
	center := transformCenter(t, rect) - delta / t.scale
	return {zoom = t.scale, center = TileZoom_ClampCenter(center, content, view, t.scale)}
}

/*
The tile cell under a screen point (clamped to the tileset), and whether the point is on the
tileset at all.

Inputs:
- grid, spacing, padding: The tileset's tile size, the gap between tiles, the margin (pixels)
- cWid, cHei: Its columns and rows
*/
TileZoom_CellAt :: proc(t: TileZoomTransform, point: [2]f32, grid, spacing, padding: f32, cWid, cHei: int) -> (cell: [2]int, inside: bool) {
	local := TileZoom_ToContent(t, point)
	step := max(grid + spacing, 1)
	cx := int(math.floor((local.x - padding) / step))
	cy := int(math.floor((local.y - padding) / step))
	inside = cx >= 0 && cy >= 0 && cx < cWid && cy < cHei
	return {clamp(cx, 0, max(cWid - 1, 0)), clamp(cy, 0, max(cHei - 1, 0))}, inside
}

// The key a tileset view's zoom is kept under (temp): the place ("palette", "picker"), the
// tileset's uid, its .ldtk file
TileZoom_Key :: proc(place: string, tileset: int, file: string) -> string {
	return fmt.tprintf("%s %d %s", place, tileset, file)
}

// A tileset view's zoom (Fit when none is kept)
TileZoom_Get :: proc(s: ^State, key: string) -> TileZoom {
	return s.level.tileZooms[key] or_else {}
}

// A tileset view zoomed or panned (`save`: written to `.editor/tile_zoom.ini`; a pan's moves
// aren't, its release is)
Tile_Zoom_Changed :: struct {
	key: string,
	zoom: TileZoom,
	save: bool,
}

// Handles `Tile_Zoom_Changed` (view state: not undone). Returns whether `m` was one
TileZoom_Update :: proc(state: ^State, m: Msg) -> bool {
	v, ok := m.(Tile_Zoom_Changed)
	if !ok do return false
	if v.zoom.zoom > 0 {
		if _, has := state.level.tileZooms[v.key]; has do state.level.tileZooms[v.key] = v.zoom
		else do state.level.tileZooms[strings.clone(v.key)] = v.zoom
	} else if v.key in state.level.tileZooms {
		k, _ := delete_key(&state.level.tileZooms, v.key)
		delete(k)
	}
	if v.save do if problem := TileZoom_Save(state); problem != "" do logLine(state, .Warning, problem)
	return true
}

// The kept zooms as `.editor/tile_zoom.ini` holds them (temp): a line per view, `zoom x y key`
TileZoom_Text :: proc(zooms: map[string]TileZoom) -> string {
	keys := make([dynamic]string, context.temp_allocator)
	for k in zooms do append(&keys, k)
	slice.sort(keys[:])
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "; The Level mode's tileset views' zooms (Crossfire Editor): zoom, center x, center y, the view\n")
	for k in keys {
		z := zooms[k]
		fmt.sbprintf(&b, "%.4g %.6g %.6g %s\n", z.zoom, z.center.x, z.center.y, k)
	}
	return strings.to_string(b)
}

// Reads `TileZoom_Text`'s lines into `zooms` (keys owned); bad lines are skipped
TileZoom_Parse :: proc(text: string, zooms: ^map[string]TileZoom) {
	it := text
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_space(line)
		if l == "" || l[0] == ';' do continue
		fields: [3]f32
		rest := l
		ok := true
		for i in 0 ..< 3 {
			space := strings.index_byte(rest, ' ')
			if space < 0 { ok = false; break }
			v, parsed := strconv.parse_f32(rest[:space])
			if !parsed { ok = false; break }
			fields[i] = v
			rest = strings.trim_left_space(rest[space + 1:])
		}
		if !ok || rest == "" || fields[0] <= 0 do continue
		z := TileZoom{zoom = clamp(fields[0], 0.01, TILE_ZOOM_MAX), center = {fields[1], fields[2]}}
		if _, has := zooms[rest]; has do zooms[rest] = z
		else do zooms[strings.clone(rest)] = z
	}
}

// Writes the kept zooms (only for a project folder on disk; nothing when unchanged). Returns a
// problem ("" when written or nothing to do)
TileZoom_Save :: proc(state: ^State) -> string {
	root := state.project.rootPath
	if root == "" || !os.exists(root) do return ""
	path, _ := filepath.join({root, TILE_ZOOM_FILE}, context.temp_allocator)
	text := TileZoom_Text(state.level.tileZooms)
	if old, err := os.read_entire_file(path, context.temp_allocator); err == nil && string(old) == text do return ""
	if len(state.level.tileZooms) == 0 && !os.exists(path) do return ""
	_ = os.make_directory_all(filepath.dir(path))
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil do return fmt.tprintf("Couldn't write %s: %v", path, err)
	return ""
}

// Reads the project's kept zooms (a project opened: `Mode_Load`)
TileZoom_Load :: proc(state: ^State) {
	TileZoom_Clear(&state.level.tileZooms)
	path, _ := filepath.join({state.project.rootPath, TILE_ZOOM_FILE}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	TileZoom_Parse(string(data), &state.level.tileZooms)
}

// Empties a zoom map (its keys freed)
TileZoom_Clear :: proc(zooms: ^map[string]TileZoom) {
	for k in zooms do delete(k)
	clear(zooms)
}

// The pan drag running (its view's widget id; 0 none): view state, as `slicerPanning`
@(private="file", thread_local)
tileZoomPanning: skald.Widget_ID

/*
What a tileset view does with the pointer this frame, from its last rect: the transform it
hit-tests with, whether the pointer is over it, whether a pan runs or a press would pan (Space
held: not a pick), and the pointer's shape.
*/
TileZoomInput :: struct {
	t: TileZoomTransform,
	hovered, panning: bool,
	cursor: skald.Cursor_Shape,
}

/*
A tileset view's wheel and pan handling (before it's built): zooms and pans are sent as
`Tile_Zoom_Changed`, the wheel it uses is taken from the input.

Inputs:
- key: The view's `TileZoom_Key`
- id: Its canvas's widget id
- content: The tileset's size (pixels)
*/
tileZoomInput :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key: string, id: skald.Widget_ID, content: [2]f32) -> TileZoomInput {
	out := TileZoomInput{cursor = .Crosshair}
	z := TileZoom_Get(s, key)
	st, ok := ctx.widgets.states[id]
	if !ok {
		out.t = TileZoom_Transform(z, content, {0, 0, content.x, content.y})
		if tileZoomPanning == id do tileZoomPanning = 0
		return out
	}
	r := st.last_rect
	out.t = TileZoom_Transform(z, content, r)
	input := ctx.input
	if tileZoomPanning == id {
		out.panning = true
		out.cursor = .Grabbing
		skald.cursor_request_top(ctx, .Grabbing)
		if !input.mouse_buttons[.Middle] && !input.mouse_buttons[.Left] {
			tileZoomPanning = 0
			skald.send(ctx, Msg(Tile_Zoom_Changed{key = key, zoom = z.zoom > 0 ? z : TileZoom{}, save = true}))
		} else if input.mouse_delta != {} {
			skald.send(ctx, Msg(Tile_Zoom_Changed{key = key, zoom = TileZoom_Pan(z, content, r, input.mouse_delta)}))
		}
		return out
	}
	hovered := skald.widget_hovered(ctx, id) && !skald.mouse_over_overlay(ctx) && !Overlay_PopupOpen(ctx)
	if st.clip_rect.w > 0 {
		m := input.mouse_pos
		c := st.clip_rect
		if m.x < c.x || m.y < c.y || m.x >= c.x + c.w || m.y >= c.y + c.h do hovered = false
	}
	out.hovered = hovered
	if !hovered do return out
	if input.scroll != {} {
		wheelZoom, pan := wheelAction(input.scroll, input.modifiers, s.settings.wheelPans)
		next := z
		if wheelZoom != 0 do next = TileZoom_ZoomAt(next, content, r, input.mouse_pos, math.pow(f32(WHEEL_ZOOM_STEP), wheelZoom))
		if pan != {} do next = TileZoom_Pan(next, content, r, pan)
		moved := TileZoom_Transform(next, content, r) != out.t
		// A pan that moves nothing (the tileset fits) leaves the wheel to the scroll around it
		if moved || wheelZoom != 0 {
			skald.send(ctx, Msg(Tile_Zoom_Changed{key = key, zoom = next, save = true}))
			ctx.input.scroll = {}
		}
	}
	spaceHeld := .Space in input.keys_down && !IsTyping(ctx)
	if input.mouse_pressed[.Middle] || (input.mouse_pressed[.Left] && spaceHeld) {
		tileZoomPanning = id
		out.panning = true
		out.cursor = .Grabbing
	} else if spaceHeld {
		out.panning = true
		out.cursor = .Grab
	}
	return out
}

/*
A tileset view's zoom buttons: −, +, Fit (around the view's middle), then the zoom. Keys
`<widgetKey>-zoom-out`, `-zoom-in`, `-fit`.

Inputs:
- key: The view's `TileZoom_Key`
- widgetKey: Its canvas's widget key (the buttons' keys start with it)
- content: The tileset's size (pixels)
*/
tileZoomControls :: proc(ctx: ^skald.Ctx(Msg), s: ^State, key, widgetKey: string, content: [2]f32) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	z := TileZoom_Get(s, key)
	r := skald.Rect{0, 0, content.x, content.y}
	if st, ok := ctx.widgets.states[skald.hash_id(widgetKey)]; ok do r = st.last_rect
	middle := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	scale := TileZoom_Scale(z, content, {r.w, r.h})
	out := TileZoom_ZoomAt(z, content, r, middle, 1 / f32(WHEEL_ZOOM_STEP))
	in_ := TileZoom_ZoomAt(z, content, r, middle, WHEEL_ZOOM_STEP)
	return skald.row(
		panelToolButton(ctx, fmt.tprintf("%s-zoom-out", widgetKey), ACTION_ICONS[.Zoom_Out], "Zoom out (the wheel zooms around the pointer)", Msg(Tile_Zoom_Changed{key = key, zoom = out, save = true})),
		panelToolButton(ctx, fmt.tprintf("%s-zoom-in", widgetKey), ACTION_ICONS[.Zoom_In], "Zoom in (middle drag or Space + drag pans)", Msg(Tile_Zoom_Changed{key = key, zoom = in_, save = true})),
		panelToolButton(ctx, fmt.tprintf("%s-fit", widgetKey), ACTION_ICONS[.Fit_View], "Fit: the whole tileset", Msg(Tile_Zoom_Changed{key = key, save = true}), on = z.zoom == 0),
		uiText(th, .Muted, fmt.tprintf("%d%%", int(math.round(scale * 100)))),
		spacing = tk.buttonGap, cross_align = .Center,
	)
}

/*
Draws a tileset through a view's transform, clipped to the view, its pixels crisp (nearest
sampling); the caller draws its marks over it with the same transform.
*/
TileZoom_DrawImage :: proc(r: ^skald.Renderer, bounds: skald.Rect, t: TileZoomTransform, image: string, content: [2]f32) {
	skald.draw_rect(r, bounds, {0.1, 0.1, 0.12, 1})
	skald.draw_image_region(r, image, TileZoom_ScreenRect(t, {0, 0, content.x, content.y}), {0, 0, content.x, content.y}, inset = false, nearest = true)
}

/*
What each tileset view showed last frame, by its widget key, for the test driver (`click_tileset_tile`,
the `tile_zoom` check): the transform it hit-tests with, the tileset's grid, its zoom.
*/
TileViewProbe :: struct {
	t: TileZoomTransform,
	zoom: TileZoom,
	grid, spacing, padding: f32,
	cWid: int,
}

@(private="file", thread_local)
tileViewProbes: map[string]TileViewProbe

// Records a view's probe (from its build)
TileZoom_Record :: proc(widgetKey: string, probe: TileViewProbe) {
	if _, has := tileViewProbes[widgetKey]; has do tileViewProbes[widgetKey] = probe
	else do tileViewProbes[strings.clone(widgetKey)] = probe
}

// The screen point at the middle of tile `id` of a view, and its probe (false: no such view)
TileZoom_TileCenter :: proc(widgetKey: string, id: int) -> ([2]f32, TileViewProbe, bool) {
	p, ok := tileViewProbes[widgetKey]
	if !ok do return {}, {}, false
	step := p.grid + p.spacing
	cx, cy := id % max(p.cWid, 1), id / max(p.cWid, 1)
	center := [2]f32{p.padding + f32(cx) * step + p.grid / 2, p.padding + f32(cy) * step + p.grid / 2}
	return p.t.origin + center * p.t.scale, p, true
}

// Frees the probes (tests, quitting)
TileZoom_Destroy :: proc() {
	for k in tileViewProbes do delete(k)
	delete(tileViewProbes)
	tileViewProbes = nil
	tileZoomPanning = 0
}
