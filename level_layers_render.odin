package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:math"
import "core:slice"
import "core:strings"
import "core:time"
import "gui:skald"
import stbi "vendor:stb/image"

/*
The Level mode's level pictures, drawn as LDtk's editor draws levels (its LayerRender): from the
decoded levels (ldtk_level_model.odin), in pieces (`LEVEL_CHUNK` picture pixels square, each a
Skald image), so painting uploads only the pieces a stroke changed.

- **The focused level** has a picture per layer (and one for its background image): the canvas
  draws them bottom first, each at its opacity (LDtk's `displayOpacity`; the layers that aren't
  selected at their `inactiveOpacity` too, and faded further in LDtk's single layer mode,
  Shift+A), hidden ones not at all. They're drawn from the painting model
  (`LevelPaint_Model`): a cell a tool or a rule changed marks its pieces (the rules' tiles reach
  as far as their stamps and offsets move them: `levelLayerMargin`), and only those are drawn
  again and uploaded. A new model (undo, another edit) draws every piece again.
- **The other levels** have one picture each (the background and every visible layer, LDtk's
  world view), drawn again when what they show changes (`levelContentKeys`).
- **What a layer draws** (LayerRender.render): an IntGrid layer its values' colors; an auto layer
  (an IntGrid layer with a tileset, or an AutoLayer) its rules' tiles in the file's order (the
  IntGrid's colors instead while auto-layer tiles are hidden, Shift+R); a Tiles layer its tiles,
  each cell's stack bottom first; tiles flipped and placed by the layer's tile pivot as LDtk does
  (its grid tiles' vertical pivot is the horizontal one: LayerRender.renderGridTile's slip, kept).
  Entities are the canvas's to draw (level_canvas.odin).
- **The budget:** pieces are drawn for at most `LEVEL_RENDER_BUDGET_MS` a frame (the first frame
  of a big level shows its background meanwhile); a frame is asked for while some are waiting.

Images: `level-<hash>-<plane>-<x>-<y>`. Tileset and background images are read once (stb_image).
*/

// A piece's side, in picture pixels
LEVEL_CHUNK :: 256
// Time a frame spends drawing pieces
LEVEL_RENDER_BUDGET_MS :: 10

// What a picture plane draws
@(private="file")
PlaneKind :: enum u8 {
	// The level's background image
	Background,
	// One layer (the focused level's)
	Layer,
	// Everything (another level's)
	Composite,
}

// A plane's pieces
@(private="file")
Plane :: struct {
	kind: PlaneKind,
	// The layer (its index in the model's layers)
	layer: int,
	// Per piece: uploaded (its image exists), empty (nothing drawn: no image needed)
	uploaded, empty: []bool,
}

// A level's pictures
@(private="file")
LevelPictures :: struct {
	// What they show: the content key (another level's) or the model's generation (the focused one's)
	key: u64,
	focused: bool,
	scale: f32,
	size: [2]int,
	chunks: [2]int,
	planes: [dynamic]Plane,
	// Pieces waiting to be drawn: (plane, x, y)
	pending: [dynamic][3]int,
	// The level's pixels (its world rectangle's size)
	levelSize: [2]int,
}

@(private="file", thread_local)
pictures: map[string]LevelPictures

// Levels being drawn that aren't the focused one: decoded while their pieces wait (by iid)
@(private="file", thread_local)
drawModels: map[string]^LDtkLevelModel

// An image read for drawing (RGBA8)
@(private="file")
LoadedImage :: struct {
	pixels: []u8,
	size: [2]int,
}

@(private="file", thread_local)
loadedImages: map[string]LoadedImage

// Frees the pictures' state (tests, quitting); the images go with Skald's renderer
LevelPictures_Destroy :: proc() {
	for name, &p in pictures {
		delete(name)
		picturesFree(&p)
	}
	delete(pictures)
	pictures = nil
	for iid, m in drawModels {
		delete(iid)
		LDtkLevel_Destroy(m)
		free(m)
	}
	delete(drawModels)
	drawModels = nil
	for path, img in loadedImages {
		delete(path)
		delete(img.pixels)
	}
	delete(loadedImages)
	loadedImages = nil
}

@(private="file")
picturesFree :: proc(p: ^LevelPictures) {
	for &plane in p.planes {
		delete(plane.uploaded)
		delete(plane.empty)
	}
	delete(p.planes)
	delete(p.pending)
	p^ = {}
}

// A picture piece's image name
@(private="file")
chunkName :: proc(base: string, plane, x, y: int) -> string {
	return fmt.tprintf("%s-%d-%d-%d", base, plane, x, y)
}

// An image file as RGBA8 (cached by full path; nothing when it can't be read)
@(private="file")
loadImage :: proc(path: string) -> (LoadedImage, bool) {
	if img, found := loadedImages[path]; found do return img, img.pixels != nil
	w, h, channels: i32
	data := stbi.load(strings.clone_to_cstring(path, context.temp_allocator), &w, &h, &channels, 4)
	img := LoadedImage{}
	if data != nil {
		img.pixels = make([]u8, int(w) * int(h) * 4)
		copy(img.pixels, data[:int(w) * int(h) * 4])
		img.size = {int(w), int(h)}
		stbi.image_free(data)
	}
	loadedImages[strings.clone(path)] = img
	return img, img.pixels != nil
}

/*
How far a layer's tiles can be drawn from their cell (cells): a rule's stamp and offsets, a
tileset tile bigger than the grid. A changed cell's pieces are widened by it.
*/
@(private="file")
levelLayerMargin :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) -> int {
	d := &m.defs[l.def]
	margin := 1
	td := LDtkLevel_LayerTileset(m, l)
	if td != nil do margin = max(margin, td.tileGridSize / max(d.gridSize, 1) + 1)
	for &g in d.groups do for &r in g.rules {
		reach := (abs(r.tileXOffset) + max(abs(r.tileRandomXMin), abs(r.tileRandomXMax)) + abs(r.tileYOffset) + max(abs(r.tileRandomYMin), abs(r.tileRandomYMax))) / max(d.gridSize, 1) + 1
		if r.tileMode == .Stamp && td != nil {
			for ids in r.tileRectsIds {
				b := LDtkTileBrush_Bounds(td, ids[:])
				reach += max(b[2] - b[0], b[3] - b[1]) + 1
			}
		}
		margin = max(margin, reach)
	}
	return margin
}

/*
Brings a level's pictures up to date and draws what's waiting (within the frame's budget). Call
it for every level the canvas shows, each frame.

Inputs:
- base: The level's image name (its pieces add their plane and place)
- file, iid, identifier: The document and the level
- world: The level's world rectangle (its size is the level's)
- key: What another level's picture shows (`levelContentKeys`); ignored for the focused level

Returns:
- Whether pieces are still waiting (the canvas asks for another frame)
*/
LevelPictures_Update :: proc(ctx: ^skald.Ctx(Msg), s: ^State, doc: ^LDtkDoc, base, iid, identifier: string, world: [4]f32, key: u64, deadline: time.Tick) -> bool {
	if ctx.renderer == nil do return false
	focused := s.level.focus == identifier
	size := [2]int{max(int(world[2]), 1), max(int(world[3]), 1)}
	scale := min(1, f32(LEVEL_IMAGE_MAX) / f32(max(size.x, size.y)))
	options := u64(s.level.paint.hideAutoLayers ? 1 : 0)
	m: ^LDtkLevelModel
	want := key ~ options
	if focused {
		m = LevelPaint_Model(s)
		if m == nil do return false
		want = u64(m.gen) * 1000003 + options
	}
	p, found := &pictures[base]
	if !found {
		pictures[strings.clone(base)] = {}
		p = &pictures[base]
	}
	if p.key != want || p.focused != focused || p.levelSize != size || len(p.planes) == 0 {
		// Every piece again
		if !focused {
			if _, had := drawModels[iid]; had {
				key, old := delete_key(&drawModels, iid)
				delete(key)
				LDtkLevel_Destroy(old)
				free(old)
			}
			level := LDtkDoc_FindLevel(doc, identifier)
			read, ok := LDtkLevel_Read(doc, LevelMode_File(s), level)
			if !ok do return false
			dm := new(LDtkLevelModel)
			dm^ = read
			drawModels[strings.clone(iid)] = dm
			m = dm
		}
		// Old pieces stay until drawn again (their images keep their names)
		keepUploaded := len(p.planes) > 0 && p.focused == focused && p.levelSize == size && p.scale == scale
		oldPlanes := p.planes
		p.planes = {}
		clear(&p.pending)
		p.key, p.focused, p.scale, p.levelSize = want, focused, scale, size
		p.size = {max(int(math.ceil(f32(size.x) * scale)), 1), max(int(math.ceil(f32(size.y) * scale)), 1)}
		p.chunks = {(p.size.x + LEVEL_CHUNK - 1) / LEVEL_CHUNK, (p.size.y + LEVEL_CHUNK - 1) / LEVEL_CHUNK}
		count := p.chunks.x * p.chunks.y
		addPlane :: proc(p: ^LevelPictures, kind: PlaneKind, layer, count: int) {
			append(&p.planes, Plane{kind = kind, layer = layer, uploaded = make([]bool, count), empty = make([]bool, count)})
		}
		if focused {
			addPlane(p, .Background, -1, count)
			// Bottom first
			#reverse for _, i in m.layers do addPlane(p, .Layer, i, count)
		} else {
			addPlane(p, .Composite, -1, count)
		}
		for &plane, pi in p.planes {
			if keepUploaded && pi < len(oldPlanes) && len(oldPlanes[pi].uploaded) == count do copy(plane.uploaded, oldPlanes[pi].uploaded)
			for y in 0 ..< p.chunks.y do for x in 0 ..< p.chunks.x do append(&p.pending, [3]int{pi, x, y})
		}
		for &plane in oldPlanes {
			delete(plane.uploaded)
			delete(plane.empty)
		}
		delete(oldPlanes)
		if focused do for &l in m.layers do l.dirtyAny = false
	} else if focused {
		// The pieces a stroke changed
		for &plane, pi in p.planes {
			if plane.kind != .Layer || plane.layer >= len(m.layers) do continue
			l := &m.layers[plane.layer]
			if !l.dirtyAny do continue
			l.dirtyAny = false
			d := &m.defs[l.def]
			margin := levelLayerMargin(m, l)
			grid := f32(d.gridSize)
			off := LDtkLayer_Offset(m, l)
			x0 := (f32(l.dirty[0] - margin) * grid + f32(off.x)) * scale
			y0 := (f32(l.dirty[1] - margin) * grid + f32(off.y)) * scale
			x1 := (f32(l.dirty[2] + 1 + margin) * grid + f32(off.x)) * scale
			y1 := (f32(l.dirty[3] + 1 + margin) * grid + f32(off.y)) * scale
			cx0, cy0 := max(int(x0) / LEVEL_CHUNK, 0), max(int(y0) / LEVEL_CHUNK, 0)
			cx1, cy1 := min(int(x1) / LEVEL_CHUNK, p.chunks.x - 1), min(int(y1) / LEVEL_CHUNK, p.chunks.y - 1)
			for y in cy0 ..= cy1 do for x in cx0 ..= cx1 {
				piece := [3]int{pi, x, y}
				if !slice.contains(p.pending[:], piece) do append(&p.pending, piece)
			}
		}
	}
	if len(p.pending) == 0 do return false
	if !focused {
		dm, has := drawModels[iid]
		if !has do return false
		m = dm
	}
	// Draw what fits in the frame's budget
	buf := make([]u8, LEVEL_CHUNK * LEVEL_CHUNK * 4, context.temp_allocator)
	for len(p.pending) > 0 {
		if time.tick_diff(deadline, time.tick_now()) > 0 do break
		piece := pop_front(&p.pending)
		plane := &p.planes[piece[0]]
		i := piece[1] + piece[2] * p.chunks.x
		rect := [4]int{piece[1] * LEVEL_CHUNK, piece[2] * LEVEL_CHUNK, min(LEVEL_CHUNK, p.size.x - piece[1] * LEVEL_CHUNK), min(LEVEL_CHUNK, p.size.y - piece[2] * LEVEL_CHUNK)}
		pixels := buf[:rect[2] * rect[3] * 4]
		slice.zero(pixels)
		drawn := LevelPictures_Draw(s, doc, m, plane.kind, plane.layer, rect, p.scale, pixels)
		name := chunkName(base, piece[0], piece[1], piece[2])
		plane.empty[i] = !drawn
		if !drawn do continue
		if plane.uploaded[i] && skald.image_update_pixels(ctx.renderer, name, u32(rect[2]), u32(rect[3]), pixels) do continue
		if plane.uploaded[i] do skald.image_unload(ctx.renderer, name)
		skald.image_load_pixels(ctx.renderer, name, u32(rect[2]), u32(rect[3]), pixels, mipmaps = false)
		plane.uploaded[i] = true
	}
	// Done with another level's model
	if len(p.pending) == 0 && !focused {
		if _, has := drawModels[iid]; has {
			// The key is freed only once it's out of the map (the lookup reads it)
			key, dm := delete_key(&drawModels, iid)
			delete(key)
			LDtkLevel_Destroy(dm)
			free(dm)
		}
	}
	return len(p.pending) > 0
}

// A piece of a level's picture as the canvas draws it
LevelPicturePiece :: struct {
	image: string,
	// Where it goes in the level (level pixels) and its pixels' size
	rect: [4]f32,
	size: [2]f32,
	// The layer it's of (an index in the model's layers; -1: the background, -2: everything)
	layer: int,
}

/*
The pieces of a level's pictures to draw (temp allocated), planes bottom first.

Returns:
- The pieces, and whether the level has pictures (false: only its background color shows yet)
*/
LevelPictures_Pieces :: proc(base: string) -> ([]LevelPicturePiece, bool) {
	p, found := &pictures[base]
	if !found || len(p.planes) == 0 do return nil, false
	out := make([dynamic]LevelPicturePiece, context.temp_allocator)
	for &plane, pi in p.planes {
		layer := plane.kind == .Background ? -1 : plane.kind == .Composite ? -2 : plane.layer
		for y in 0 ..< p.chunks.y do for x in 0 ..< p.chunks.x {
			i := x + y * p.chunks.x
			if !plane.uploaded[i] || plane.empty[i] do continue
			w := f32(min(LEVEL_CHUNK, p.size.x - x * LEVEL_CHUNK))
			h := f32(min(LEVEL_CHUNK, p.size.y - y * LEVEL_CHUNK))
			append(&out, LevelPicturePiece{
				image = chunkName(base, pi, x, y),
				rect = {f32(x * LEVEL_CHUNK) / p.scale, f32(y * LEVEL_CHUNK) / p.scale, w / p.scale, h / p.scale},
				size = {w, h},
				layer = layer,
			})
		}
	}
	return out[:], true
}

// Blends a source pixel (straight alpha, `alpha` more) over a destination one
@(private="file")
blend :: #force_inline proc(dst: []u8, src: []u8, alpha: f32) {
	sa := f32(src[3]) / 255 * alpha
	if sa <= 0 do return
	da := f32(dst[3]) / 255
	oa := sa + da * (1 - sa)
	if oa <= 0 do return
	for c in 0 ..< 3 {
		v := (f32(src[c]) * sa + f32(dst[c]) * da * (1 - sa)) / oa
		dst[c] = u8(clamp(v + 0.5, 0, 255))
	}
	dst[3] = u8(clamp(oa * 255 + 0.5, 0, 255))
}

/*
One tile drawn into a piece: the tileset image's tile at `src` (`tileSize` square), its top-left
at `at` (level pixels), mirrored by `flips`.
*/
@(private="file")
drawTile :: proc(out: []u8, rect: [4]int, scale: f32, img: LoadedImage, src: [2]int, tileSize: [2]int, at: [2]f32, flips: u8, alpha: f32, clip: [4]f32) {
	// The piece's pixels the tile covers
	lx0, ly0 := max(at.x, clip[0]), max(at.y, clip[1])
	lx1, ly1 := min(at.x + f32(tileSize.x), clip[2]), min(at.y + f32(tileSize.y), clip[3])
	if lx1 <= lx0 || ly1 <= ly0 do return
	px0 := max(int(math.floor(lx0 * scale)) - rect[0], 0)
	py0 := max(int(math.floor(ly0 * scale)) - rect[1], 0)
	px1 := min(int(math.ceil(lx1 * scale)) - rect[0], rect[2])
	py1 := min(int(math.ceil(ly1 * scale)) - rect[1], rect[3])
	for py in py0 ..< py1 {
		ly := (f32(rect[1] + py) + 0.5) / scale
		if ly < ly0 || ly >= ly1 do continue
		v := int(ly - at.y)
		if flips & 2 != 0 do v = tileSize.y - 1 - v
		sy := src.y + v
		if sy < 0 || sy >= img.size.y do continue
		for px in px0 ..< px1 {
			lx := (f32(rect[0] + px) + 0.5) / scale
			if lx < lx0 || lx >= lx1 do continue
			u := int(lx - at.x)
			if flips & 1 != 0 do u = tileSize.x - 1 - u
			sx := src.x + u
			if sx < 0 || sx >= img.size.x do continue
			s := (sy * img.size.x + sx) * 4
			d := (py * rect[2] + px) * 4
			blend(out[d:d + 4], img.pixels[s:s + 4], alpha)
		}
	}
}

// A rectangle of one color drawn into a piece (an IntGrid cell)
@(private="file")
fillRect :: proc(out: []u8, rect: [4]int, scale: f32, r: [4]f32, color: u32, alpha: f32, clip: [4]f32) {
	lx0, ly0 := max(r[0], clip[0]), max(r[1], clip[1])
	lx1, ly1 := min(r[0] + r[2], clip[2]), min(r[1] + r[3], clip[3])
	if lx1 <= lx0 || ly1 <= ly0 do return
	px0 := max(int(math.floor(lx0 * scale)) - rect[0], 0)
	py0 := max(int(math.floor(ly0 * scale)) - rect[1], 0)
	px1 := min(int(math.ceil(lx1 * scale)) - rect[0], rect[2])
	py1 := min(int(math.ceil(ly1 * scale)) - rect[1], rect[3])
	src := [4]u8{u8(color >> 16), u8(color >> 8), u8(color), 255}
	for py in py0 ..< py1 {
		ly := (f32(rect[1] + py) + 0.5) / scale
		if ly < ly0 || ly >= ly1 do continue
		for px in px0 ..< px1 {
			lx := (f32(rect[0] + px) + 0.5) / scale
			if lx < lx0 || lx >= lx1 do continue
			d := (py * rect[2] + px) * 4
			blend(out[d:d + 4], src[:], alpha)
		}
	}
}

/*
Draws a plane of a level into a piece (`rect`: the piece in picture pixels; `out` its RGBA8, cleared).

Returns:
- Whether anything was drawn
*/
LevelPictures_Draw :: proc(s: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel, kind: PlaneKind, layer: int, rect: [4]int, scale: f32, out: []u8) -> bool {
	return levelDraw(doc, m, kind, layer, rect, scale, out, s.level.paint.hideAutoLayers)
}

/*
A level drawn whole into an RGBA8 picture of its size (`out`: width * height * 4, cleared), as the
canvas draws it: its background image (`background`), a layer (`layer` >= 0: at full opacity) or
every visible layer at its opacity (`layer` -1). PNG exports draw with it (ldtk_save_extras.odin).

Returns:
- Whether anything was drawn
*/
LevelPictures_Render :: proc(doc: ^LDtkDoc, m: ^LDtkLevelModel, layer: int, background: bool, out: []u8) -> bool {
	rect := [4]int{0, 0, m.pxWid, m.pxHei}
	if background do return levelDraw(doc, m, .Background, -1, rect, 1, out, false)
	if layer >= 0 do return levelDraw(doc, m, .Layer, layer, rect, 1, out, false)
	drawn := false
	#reverse for &l in m.layers {
		if !l.visible do continue
		if drawLayer(false, m, &l, rect, 1, out, LDtkDoc_Folder(doc), {0, 0, f32(m.pxWid), f32(m.pxHei)}, f32(m.defs[l.def].displayOpacity)) do drawn = true
	}
	return drawn
}

// A plane drawn into a piece (LevelPictures_Draw's, with auto-layer tiles hidden or not)
@(private="file")
levelDraw :: proc(doc: ^LDtkDoc, m: ^LDtkLevelModel, kind: PlaneKind, layer: int, rect: [4]int, scale: f32, out: []u8, hideAuto: bool) -> bool {
	folder := LDtkDoc_Folder(doc)
	// The piece in level pixels (a margin of a cell: tiles reaching into it)
	view := [4]f32{f32(rect[0]) / scale, f32(rect[1]) / scale, f32(rect[0] + rect[2]) / scale, f32(rect[1] + rect[3]) / scale}
	drawn := false
	switch kind {
	case .Background:
		drawn = drawBackground(doc, m, rect, scale, out, folder)
	case .Layer:
		if layer < len(m.layers) do drawn = drawLayer(hideAuto, m, &m.layers[layer], rect, scale, out, folder, view, 1)
	case .Composite:
		drawn = drawBackground(doc, m, rect, scale, out, folder)
		#reverse for &l in m.layers {
			if !l.visible do continue
			if drawLayer(hideAuto, m, &l, rect, scale, out, folder, view, f32(m.defs[l.def].displayOpacity)) do drawn = true
		}
	}
	return drawn
}

// The level's background image (Level.getBgTileInfos / createBgTiledTexture, from its `__bgPos`)
@(private="file")
drawBackground :: proc(doc: ^LDtkDoc, m: ^LDtkLevelModel, rect: [4]int, scale: f32, out: []u8, folder: string) -> bool {
	main := LDtkDoc_Main(doc)
	entry := doc.levels[m.level].entry
	rel := Json_String(main, Json_Get(main, entry, "bgRelPath"))
	pos := Json_Get(main, entry, "__bgPos")
	if rel == "" || Json_Kind(main, pos) != .Object do return false
	img, ok := loadImage(joinPath(folder, rel, allocator = context.temp_allocator))
	if !ok do return false
	tl := Json_Get(main, pos, "topLeftPx")
	sc := Json_Get(main, pos, "scale")
	crop := Json_Get(main, pos, "cropRect")
	at := [2]f32{f32(Json_Float(main, Json_At(main, tl, 0))), f32(Json_Float(main, Json_At(main, tl, 1)))}
	sx, sy := f32(Json_Float(main, Json_At(main, sc, 0), 1)), f32(Json_Float(main, Json_At(main, sc, 1), 1))
	c := [4]f32{f32(Json_Float(main, Json_At(main, crop, 0))), f32(Json_Float(main, Json_At(main, crop, 1))), f32(Json_Float(main, Json_At(main, crop, 2))), f32(Json_Float(main, Json_At(main, crop, 3)))}
	repeat := Json_String(main, Json_Get(main, entry, "bgPos")) == "Repeat"
	if c[2] <= 0 || c[3] <= 0 || sx <= 0 || sy <= 0 do return false
	drawn := false
	for py in 0 ..< rect[3] {
		ly := (f32(rect[1] + py) + 0.5) / scale
		for px in 0 ..< rect[2] {
			lx := (f32(rect[0] + px) + 0.5) / scale
			u, v: f32
			if repeat {
				u = math.mod(math.mod(lx / sx, c[2]) + c[2], c[2])
				v = math.mod(math.mod(ly / sy, c[3]) + c[3], c[3])
			} else {
				u, v = (lx - at.x) / sx, (ly - at.y) / sy
				if u < 0 || v < 0 || u >= c[2] || v >= c[3] do continue
			}
			ix, iy := int(c[0] + u), int(c[1] + v)
			if ix < 0 || iy < 0 || ix >= img.size.x || iy >= img.size.y do continue
			s := (iy * img.size.x + ix) * 4
			d := (py * rect[2] + px) * 4
			blend(out[d:d + 4], img.pixels[s:s + 4], 1)
			drawn = true
		}
	}
	return drawn
}

// One layer into a piece, at an opacity (LayerRender.render)
@(private="file")
drawLayer :: proc(hideAuto: bool, m: ^LDtkLevelModel, l: ^LDtkLayerData, rect: [4]int, scale: f32, out: []u8, folder: string, view: [4]f32, alpha: f32) -> bool {
	d := &m.defs[l.def]
	grid := d.gridSize
	off := LDtkLayer_Offset(m, l)
	// LDtk masks a layer to its size
	clip := [4]f32{max(view[0], f32(off.x) - f32(l.pxOffset.x)), max(view[1], f32(off.y) - f32(l.pxOffset.y)), min(view[2], f32(m.pxWid)), min(view[3], f32(m.pxHei))}
	margin := levelLayerMargin(m, l)
	// The cells whose tiles may reach the piece
	cx0 := max(int(math.floor((view[0] - f32(off.x)) / f32(grid))) - margin, 0)
	cy0 := max(int(math.floor((view[1] - f32(off.y)) / f32(grid))) - margin, 0)
	cx1 := min(int(math.floor((view[2] - f32(off.x)) / f32(grid))) + margin, l.cWid - 1)
	cy1 := min(int(math.floor((view[3] - f32(off.y)) / f32(grid))) + margin, l.cHei - 1)
	if cx1 < cx0 || cy1 < cy0 do return false
	td := LDtkLevel_LayerTileset(m, l)
	img: LoadedImage
	hasImg := false
	if td != nil do img, hasImg = loadImage(joinPath(folder, td.relPath, allocator = context.temp_allocator))
	drawn := false
	showAuto := LDtkLayerInfo_IsAuto(d) && !hideAuto && hasImg
	switch d.kind {
	case .IntGrid, .AutoLayer:
		if showAuto {
			// The rules' tiles in the file's order: display order, then cells in order
			Pending :: struct {
				order, coord, index: int,
				t: ^LDtkAutoTile,
			}
			rulePos := make(map[i32]int, 64, context.temp_allocator)
			for r, i in LDtkRules_DisplayOrder(m, l) do rulePos[i32(r.uid)] = i
			list := make([dynamic]Pending, context.temp_allocator)
			for cy in cy0 ..= cy1 do for cx in cx0 ..= cx1 {
				coord := cx + cy * l.cWid
				for &t, k in l.auto[coord] {
					pos, active := rulePos[t.rule]
					if !active do continue
					append(&list, Pending{pos, coord, k, &t})
				}
			}
			slice.sort_by(list[:], proc(a, b: Pending) -> bool {
				if a.order != b.order do return a.order < b.order
				if a.coord != b.coord do return a.coord < b.coord
				return a.index < b.index
			})
			ts := td.tileGridSize
			for p in list {
				t := p.t
				// LayerRender.renderAutoTileInfos: flipped tiles mirror around their cell
				x := f32(t.x) + f32(grid) * ((t.flips & 1 != 0 ? 1 : 0) + f32(d.tilePivot.x)) + f32(off.x)
				y := f32(t.y) + f32(grid) * ((t.flips & 2 != 0 ? 1 : 0) + f32(d.tilePivot.y)) + f32(off.y)
				if t.flips & 1 != 0 do x -= f32(ts)
				if t.flips & 2 != 0 do y -= f32(ts)
				drawTile(out, rect, scale, img, {int(t.srcX), int(t.srcY)}, {ts, ts}, {x, y}, t.flips, alpha * f32(t.alpha), clip)
				drawn = true
			}
		} else if d.kind == .IntGrid {
			for cy in cy0 ..= cy1 do for cx in cx0 ..= cx1 {
				v := LDtkLayer_IntGrid(l, cx, cy)
				if v == 0 do continue
				info := LDtkLayerInfo_Value(d, v)
				if info == nil do continue
				fillRect(out, rect, scale, {f32(cx * grid + off.x), f32(cy * grid + off.y), f32(grid), f32(grid)}, info.color, alpha, clip)
				drawn = true
			}
		}
	case .Tiles:
		if !hasImg do return false
		ts := td.tileGridSize
		px, py := f32(d.tilePivot.x), f32(d.tilePivot.y)
		for cy in cy0 ..= cy1 do for cx in cx0 ..= cx1 {
			for t in l.tiles[cx + cy * l.cWid] {
				src := LDtkTileset_Source(td, int(t.tile))
				fx, fy := t.flips & 1 != 0, t.flips & 2 != 0
				// LayerRender.renderGridTile (its y uses the x pivot, as LDtk does)
				tx := (f32(cx) + px + (fx ? 1 : 0)) * f32(grid) + f32(off.x)
				ty := (f32(cy) + px + (fy ? 1 : 0)) * f32(grid) + f32(off.y)
				x := fx ? tx - (1 - px) * f32(ts) : tx - px * f32(ts)
				y := fy ? ty - (1 - py) * f32(ts) : ty - py * f32(ts)
				drawTile(out, rect, scale, img, src, {ts, ts}, {x, y}, t.flips, alpha, clip)
				drawn = true
			}
		}
	case .Entities:
	}
	return drawn
}

/*
A tile brush drawn as an image (the canvas's cursor preview of a stamp: Skald can't mirror an
image region): the picked tiles in their shape, flipped. Cached by brush.

Returns:
- The image's name and its size in level pixels ("" when there's nothing to draw)
*/
LevelPictures_BrushImage :: proc(ctx: ^skald.Ctx(Msg), doc: ^LDtkDoc, m: ^LDtkLevelModel, l: ^LDtkLayerData, brush: LDtkTileBrush) -> (string, [2]f32) {
	@(thread_local) shown: u64
	td := LDtkLevel_LayerTileset(m, l)
	if ctx.renderer == nil || td == nil || len(brush.ids) == 0 do return "", {}
	img, ok := loadImage(joinPath(LDtkDoc_Folder(doc), td.relPath, allocator = context.temp_allocator))
	if !ok do return "", {}
	b := LDtkTileBrush_Bounds(td, brush.ids)
	ts := td.tileGridSize
	w, h := (b[2] - b[0] + 1) * ts, (b[3] - b[1] + 1) * ts
	if w <= 0 || h <= 0 || w * h > 1024 * 1024 do return "", {}
	key := hash.fnv64a(transmute([]u8)fmt.tprintf("%s|%v|%d", td.relPath, brush.ids, brush.flips))
	name := "level-brush-preview"
	if key != shown {
		pixels := make([]u8, w * h * 4, context.temp_allocator)
		fx, fy := brush.flips & 1 != 0, brush.flips & 2 != 0
		for id in brush.ids {
			c := LDtkTileset_TileCell(td, id)
			col := fx ? b[2] - c.x : c.x - b[0]
			row := fy ? b[3] - c.y : c.y - b[1]
			drawTile(pixels, {0, 0, w, h}, 1, img, LDtkTileset_Source(td, id), {ts, ts}, {f32(col * ts), f32(row * ts)}, brush.flips, 1, {0, 0, f32(w), f32(h)})
		}
		skald.image_unload(ctx.renderer, name)
		skald.image_load_pixels(ctx.renderer, name, u32(w), u32(h), pixels, mipmaps = false)
		shown = key
	}
	return name, {f32(w), f32(h)}
}

/*
Draws the pieces of a level's layers its tools changed (the cells marked dirty), into a scratch
buffer, as `LevelPictures_Update` does before uploading them: the CPU side of a stroke's frame,
for the tests and timings (no renderer needed). The dirty marks are cleared.

Returns:
- How many pieces were drawn
*/
LevelPictures_RedrawDirty :: proc(s: ^State, doc: ^LDtkDoc, m: ^LDtkLevelModel) -> int {
	scale := min(1, f32(LEVEL_IMAGE_MAX) / f32(max(m.pxWid, m.pxHei, 1)))
	buf := make([]u8, LEVEL_CHUNK * LEVEL_CHUNK * 4, context.temp_allocator)
	size := [2]int{max(int(math.ceil(f32(m.pxWid) * scale)), 1), max(int(math.ceil(f32(m.pxHei) * scale)), 1)}
	chunks := [2]int{(size.x + LEVEL_CHUNK - 1) / LEVEL_CHUNK, (size.y + LEVEL_CHUNK - 1) / LEVEL_CHUNK}
	drawn := 0
	for &l, li in m.layers {
		if !l.dirtyAny do continue
		l.dirtyAny = false
		d := &m.defs[l.def]
		margin := levelLayerMargin(m, &l)
		grid := f32(d.gridSize)
		off := LDtkLayer_Offset(m, &l)
		x0 := (f32(l.dirty[0] - margin) * grid + f32(off.x)) * scale
		y0 := (f32(l.dirty[1] - margin) * grid + f32(off.y)) * scale
		x1 := (f32(l.dirty[2] + 1 + margin) * grid + f32(off.x)) * scale
		y1 := (f32(l.dirty[3] + 1 + margin) * grid + f32(off.y)) * scale
		for y in max(int(y0) / LEVEL_CHUNK, 0) ..= min(int(y1) / LEVEL_CHUNK, chunks.y - 1) do for x in max(int(x0) / LEVEL_CHUNK, 0) ..= min(int(x1) / LEVEL_CHUNK, chunks.x - 1) {
			rect := [4]int{x * LEVEL_CHUNK, y * LEVEL_CHUNK, min(LEVEL_CHUNK, size.x - x * LEVEL_CHUNK), min(LEVEL_CHUNK, size.y - y * LEVEL_CHUNK)}
			pixels := buf[:rect[2] * rect[3] * 4]
			slice.zero(pixels)
			LevelPictures_Draw(s, doc, m, .Layer, li, rect, scale, pixels)
			drawn += 1
		}
	}
	return drawn
}
