package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import e "engine:."
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

/*
Previews in the code editor's hovers: what an asset constant, a handle field's default or a
string literal names, shown as it is (the hover provider in code_providers.odin asks).

| What | The hover shows |
|---|---|
| An image (`TEXTURE_SHIP`, `"assets/ship.png"`, an Aseprite file) | a thumbnail (at most 160 px tall), its size |
| A sound or music | its length, and a play / stop button (the editor's audio preview, as the browser's) |
| An animation (`ANIM_HERO_RUN`), or an animation asset | its frames as a strip (8 at most), its fps and frame count |
| A dialogue node (`DIALOGUE_NODE_...`), or a dialogue | the node's first lines and options |
| A component | its thumbnail (the browser preview's picture, `Preview_RenderComponent`) |
| A scene (`SCENE_FOREST`) | its facts (nodes by kind, camera, scripts); no picture: drawing a level took 200 ms |
| A font | a sample line drawn with it (SDL_ttf); a bitmap font's facts |

- **Fast:** pictures are made once and kept (`previews.cache`, keyed by the file's path and
  modification time, or a component's content), small (scaled
  down when they're made), at most `PREVIEW_CACHE_MAX` of them (then they're all dropped).
  `code_previews_timing` measures a cold and a warm hover of each kind on the demo.
- **The play button** is a `ce.Hover_Widget` (code_editor's widgets take clicks): its click can't
  change State inside the code editor, so it leaves the request (`previews.audioRequest`) for the
  code view to send as `Code_Hover_Audio`; update plays the file through `AudioPreview_*` (or
  stops it). The button shows ■ while that file plays (the code tab is drawn again when playing
  starts or stops: `codeRenderKey`).
- **Strings:** a literal (or a tag's `default=...`) whose text is an asset's path, or a scene's
  name, previews that asset or scene.
*/

// The most pictures kept for hovers (then they're all dropped and made again as asked)
PREVIEW_CACHE_MAX :: 64
// A hover's thumbnail fits in this (pixels); a strip of frames is as tall as FRAME and up to
// PREVIEW_STRIP_FRAMES long
PREVIEW_THUMB :: 160
PREVIEW_FRAME :: 48
PREVIEW_STRIP_FRAMES :: 8
// A font's sample line and its size
PREVIEW_FONT_SAMPLE :: "The quick brown fox 0123"
PREVIEW_FONT_SIZE :: 22

// One made picture (owned)
@(private="file")
PreviewPicture :: struct {
	pixels: []u8,
	width, height: int,
	// What it is ("64 x 48 px"; owned)
	note: string,
}

// Play or stop a sound from a hover's button (the code view sends it)
Code_Hover_Audio :: struct {
	// The file, relative to the project (temp: copied in update)
	path: string,
	play: bool,
}

@(private="file")
previews: struct {
	cache: map[string]PreviewPicture,
	// Sound lengths by path@time (ms; -1 unknown)
	lengths: map[string]i64,
	// The sound the hover's button plays (owned): its widget's data points here
	audio: struct { path: string, absolute: string },
	// The button's click, for the code view to send (owned path)
	audioRequest: Maybe(Code_Hover_Audio),
}

// Frees the previews' package state (tests, quitting)
CodePreviews_Shutdown :: proc() {
	for key, p in previews.cache { delete(key); delete(p.pixels); delete(p.note) }
	delete(previews.cache)
	for key in previews.lengths do delete(key)
	delete(previews.lengths)
	delete(previews.audio.path)
	delete(previews.audio.absolute)
	if r, ok := previews.audioRequest.?; ok do delete(r.path)
	previews = {}
}

@(private="file")
cacheGet :: proc(key: string) -> (PreviewPicture, bool) {
	p, ok := previews.cache[key]
	return p, ok
}

@(private="file")
cachePut :: proc(key: string, pixels: []u8, width, height: int, note: string) -> PreviewPicture {
	if len(previews.cache) >= PREVIEW_CACHE_MAX {
		for k, p in previews.cache { delete(k); delete(p.pixels); delete(p.note) }
		clear(&previews.cache)
	}
	p := PreviewPicture{slice.clone(pixels), width, height, strings.clone(note)}
	previews.cache[strings.clone(key)] = p
	return p
}

// A file's key for the cache: its path and modification time
@(private="file")
fileKey :: proc(kind, path: string) -> string {
	info, err := os.stat(path, context.temp_allocator)
	stamp := err == nil ? info.modification_time : time.Time{}
	return fmt.tprintf("%s:%s@%v", kind, path, stamp)
}

/*
RGBA pixels scaled down (nearest: pixel art stays crisp) to fit `maxW` x `maxH`, never up.

Returns:
- The pixels (temp allocated) and their size
*/
Preview_Fit :: proc(pixels: []u8, width, height, maxW, maxH: int) -> (out: []u8, w, h: int) {
	if width <= 0 || height <= 0 || len(pixels) < width * height * 4 do return nil, 0, 0
	scale := min(1, f32(maxW) / f32(width), f32(maxH) / f32(height))
	w, h = max(int(f32(width) * scale), 1), max(int(f32(height) * scale), 1)
	if w == width && h == height do return pixels[:width * height * 4], w, h
	out = make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h {
		sy := min(y * height / h, height - 1)
		for x in 0 ..< w {
			sx := min(x * width / w, width - 1)
			copy(out[(y * w + x) * 4:][:4], pixels[(sy * width + sx) * 4:][:4])
		}
	}
	return
}

// The image block and its note
@(private="file")
addPicture :: proc(out: ^ce.Hover_Content, p: PreviewPicture) {
	if len(p.pixels) > 0 do append(&out.blocks, ce.Hover_Block(ce.Hover_Image{pixels = p.pixels, width = p.width, height = p.height}))
}

@(private="file")
addText :: proc(out: ^ce.Hover_Content, text: string, markdown := false) {
	append(&out.blocks, ce.Hover_Block(ce.Hover_Text{text = text, markdown = markdown}))
}

/*
The hover's preview of an asset of the project: by its kind (the table in this file's doc).

Inputs:
- path: The asset's path, relative to the project (as assets.odin and the scenes have it)

Returns:
- Whether it's one of the project's assets (blocks were added)
*/
CodePreviews_Asset :: proc(state: ^State, path: string, out: ^ce.Hover_Content) -> bool {
	index := -1
	for asset, i in state.project.assets do if asset.path == path { index = i; break }
	if index < 0 do return false
	asset := state.project.assets[index]
	full := AssetFilePath(&state.project, asset)
	#partial switch asset.kind {
	case .Image:
		key := fileKey("image", full)
		p, ok := cacheGet(key)
		if !ok {
			pixels, w, h, loaded := Image_LoadRGBA(full)
			if !loaded {
				addText(out, fmt.tprintf("%s can't be read", filepath.base(path)))
				return true
			}
			small, sw, sh := Preview_Fit(pixels, w, h, PREVIEW_THUMB * 2, PREVIEW_THUMB)
			frames := ""
			if e.Aseprite_IsFile(full) {
				if ase, err := e.Aseprite_Load(full); err == .None {
					frames = fmt.tprintf(", %d frame%s, %d tag%s", len(ase.frames), len(ase.frames) == 1 ? "" : "s", len(ase.tags), len(ase.tags) == 1 ? "" : "s")
					e.Aseprite_Destroy(ase)
				}
			}
			p = cachePut(key, small, sw, sh, fmt.tprintf("%s: %d x %d px%s", filepath.base(path), w, h, frames))
		}
		addText(out, p.note)
		addPicture(out, p)
	case .Audio, .Music:
		ms := soundLength(full)
		what := asset.kind == .Music ? "music (streamed)" : "a sound"
		length := ms >= 0 ? FormatDuration(ms) : "length unknown"
		addAudioButton(out, path, full)
		addText(out, fmt.tprintf("%s: %s, %s", filepath.base(path), what, length))
	case .Font:
		addFontSample(out, path, full)
	case .Component:
		addComponent(out, state, path)
	case .Animation:
		set := Project_FindAnimationSet(&state.project, path)
		if set < 0 do return false
		s := &state.project.animationSets[set]
		names := make([dynamic]string, context.temp_allocator)
		for a in s.animations do append(&names, a.name)
		addText(out, fmt.tprintf("%s: %d animation%s (%s)", filepath.base(path), len(names), len(names) == 1 ? "" : "s", strings.join(names[:], ", ", context.temp_allocator)))
		if len(s.animations) > 0 do addAnimationStrip(out, state, s.animations[0], fmt.tprintf("set:%s", path))
	case .Dialogue:
		addDialogueNode(out, state, path, "")
	case:
		addText(out, fmt.tprintf("%s: %v", path, asset.kind))
	}
	return true
}

// A sound's length (ms; -1 unknown), read once per file version without playing it
@(private="file")
soundLength :: proc(full: string) -> i64 {
	key := fileKey("length", full)
	if ms, ok := previews.lengths[key]; ok do return ms
	ms := AudioPreview_Length(full)
	previews.lengths[strings.clone(key)] = ms
	return ms
}

// The play / stop button: a widget drawing ▶ or ■, its click left for the code view
@(private="file")
addAudioButton :: proc(out: ^ce.Hover_Content, path, full: string) {
	delete(previews.audio.path)
	delete(previews.audio.absolute)
	previews.audio.path = strings.clone(path)
	previews.audio.absolute = strings.clone(full)
	append(&out.blocks, ce.Hover_Block(ce.Hover_Widget{
		width = 64, height = 22, data = &previews.audio,
		draw = proc(r: ^sdl.Renderer, rect: sdl.FRect, data: rawptr) {
			playing := CodePreviews_AudioPlaying()
			box := rect
			sdl.SetRenderDrawColor(r, 60, 120, 220, 255)
			_ = sdl.RenderFillRect(r, &box)
			sdl.SetRenderDrawColor(r, 255, 255, 255, 255)
			cx, cy := rect.x + rect.w * 0.5, rect.y + rect.h * 0.5
			if playing {
				square := sdl.FRect{cx - 5, cy - 5, 10, 10}
				_ = sdl.RenderFillRect(r, &square)
				return
			}
			// A triangle pointing right
			white := sdl.FColor{1, 1, 1, 1}
			vertices := [3]sdl.Vertex{
				{position = {cx - 5, cy - 7}, color = white},
				{position = {cx - 5, cy + 7}, color = white},
				{position = {cx + 7, cy}, color = white},
			}
			_ = sdl.RenderGeometry(r, nil, &vertices[0], 3, nil, 0)
		},
		click = proc(x, y: f32, data: rawptr) -> bool {
			CodePreviews_RequestAudio(!CodePreviews_AudioPlaying())
			return true
		},
	}))
}

// Whether the hover's sound is playing (its button shows ■)
CodePreviews_AudioPlaying :: proc() -> bool {
	return previews.audio.absolute != "" && AudioPreview_IsLoaded(previews.audio.absolute) && AudioPreview_IsPlaying()
}

// Leaves the hover button's play or stop for the code view to send (the button's click; tests)
CodePreviews_RequestAudio :: proc(play: bool) {
	if previews.audio.path == "" do return
	if r, ok := previews.audioRequest.?; ok do delete(r.path)
	previews.audioRequest = Code_Hover_Audio{path = strings.clone(previews.audio.path), play = play}
}

// The button's request, once (path temp allocated)
CodePreviews_TakeAudio :: proc() -> (Code_Hover_Audio, bool) {
	r, ok := previews.audioRequest.?
	if !ok do return {}, false
	previews.audioRequest = nil
	out := r
	out.path = strings.clone(r.path, context.temp_allocator)
	delete(r.path)
	return out, true
}

/*
Plays a project sound from the start (the hover's button), or stops what plays.

Returns:
- "" or why it couldn't play (temp allocated)
*/
CodePreviews_PlayAudio :: proc(state: ^State, path: string, play: bool) -> string {
	if !play {
		AudioPreview_Stop()
		return ""
	}
	full := joinPath(state.project.rootPath, path, allocator = context.temp_allocator)
	if !AudioPreview_IsLoaded(full) {
		if message := AudioPreview_Load(full); message != "" do return message
	}
	AudioPreview_SetSettings(1, 1, 0)
	AudioPreview_SetRouting("", 1, 1, 1, 1, 1, 1)
	AudioPreview_Play()
	return ""
}

// A sample line drawn with a font (TrueType), or a bitmap font's facts
@(private="file")
addFontSample :: proc(out: ^ce.Hover_Content, path, full: string) {
	if e.Font_IsBitmap(path) {
		data, err := os.read_entire_file(full, context.temp_allocator)
		font, ok := e.ParseBMFont(string(data), context.temp_allocator)
		if err != nil || !ok {
			addText(out, fmt.tprintf("%s: a bitmap font this engine can't read", filepath.base(path)))
			return
		}
		addText(out, fmt.tprintf("%s: a bitmap font, %.0f px, %d glyphs", filepath.base(path), font.size, len(font.chars)))
		return
	}
	key := fileKey("font", full)
	p, ok := cacheGet(key)
	if !ok {
		pixels, w, h, drawn := Preview_FontSample(full, PREVIEW_FONT_SAMPLE, PREVIEW_FONT_SIZE)
		note := drawn ? fmt.tprintf("%s: a font", filepath.base(path)) : fmt.tprintf("%s: a font that can't be drawn", filepath.base(path))
		small, sw, sh := Preview_Fit(pixels, w, h, PREVIEW_THUMB * 2, PREVIEW_THUMB)
		p = cachePut(key, small, sw, sh, note)
	}
	addText(out, p.note)
	addPicture(out, p)
}

/*
A line of text drawn with a TrueType font, white on a dark background, as RGBA pixels.

Returns:
- The pixels (temp allocated), their size, and false when the font can't be opened
*/
Preview_FontSample :: proc(path, text: string, size: f32) -> (pixels: []u8, width, height: int, ok: bool) {
	if ttf.WasInit() == 0 && !ttf.Init() do return
	font := ttf.OpenFont(strings.clone_to_cstring(path, context.temp_allocator), size)
	if font == nil do return
	defer ttf.CloseFont(font)
	surface := ttf.RenderText_Blended(font, raw_data(text), uint(len(text)), {255, 255, 255, 255})
	if surface == nil do return
	defer sdl.DestroySurface(surface)
	rgba := sdl.ConvertSurface(surface, .RGBA32)
	if rgba == nil do return
	defer sdl.DestroySurface(rgba)
	pad := 6
	width, height = int(rgba.w) + 2 * pad, int(rgba.h) + 2 * pad
	pixels = make([]u8, width * height * 4, context.temp_allocator)
	for i in 0 ..< width * height do copy(pixels[i * 4:][:4], []u8{24, 26, 32, 255})
	src := ([^]u8)(rgba.pixels)
	for y in 0 ..< int(rgba.h) do for x in 0 ..< int(rgba.w) {
		s := src[y * int(rgba.pitch) + x * 4:][:4]
		d := pixels[((y + pad) * width + x + pad) * 4:][:4]
		a := u32(s[3])
		for c in 0 ..< 3 do d[c] = u8((u32(s[c]) * a + u32(d[c]) * (255 - a)) / 255)
	}
	return pixels, width, height, true
}

// A component's picture (the browser's thumbnail renderer) and what it holds
@(private="file")
addComponent :: proc(out: ^ce.Hover_Content, state: ^State, path: string) {
	index := Project_FindComponent(&state.project, path)
	if index < 0 do return
	scene := &state.project.scenes[index]
	addText(out, fmt.tprintf("Component %s: %d node%s", ComponentName(path), len(scene.nodes), len(scene.nodes) == 1 ? "" : "s"))
	addScenePicture(out, state, index)
}

// A component's picture, made once per version of its content (its XML: what the browser's
// thumbnail is keyed by too)
@(private="file")
addScenePicture :: proc(out: ^ce.Hover_Content, state: ^State, index: int) {
	key := fmt.tprintf("component:%x", hash.fnv64a(transmute([]u8)SceneToXML(&state.project.scenes[index], context.temp_allocator)))
	p, ok := cacheGet(key)
	if !ok {
		pixels, _, rendered := Preview_RenderComponent(state, index, {PREVIEW_THUMB + PREVIEW_THUMB / 2, PREVIEW_THUMB})
		if !rendered do return
		p = cachePut(key, pixels, PREVIEW_THUMB + PREVIEW_THUMB / 2, PREVIEW_THUMB, "")
	}
	addPicture(out, p)
}

/*
A scene's facts and picture (a SCENE_ constant, or its name in a string).

Returns:
- Whether the project has the scene
*/
CodePreviews_Scene :: proc(state: ^State, name: string, out: ^ce.Hover_Content) -> bool {
	index := Project_FindScene(&state.project, name)
	if index < 0 do return false
	scene := &state.project.scenes[index]
	counts: [NodeKind]int
	for node in scene.nodes do counts[node.kind] += 1
	Count :: struct { kind: NodeKind, n: int }
	list := make([dynamic]Count, context.temp_allocator)
	for n, kind in counts do if n > 0 do append(&list, Count{kind, n})
	slice.sort_by(list[:], proc(a, b: Count) -> bool { return a.n > b.n || (a.n == b.n && a.kind < b.kind) })
	parts := make([dynamic]string, context.temp_allocator)
	for c, i in list {
		if i == 5 { append(&parts, "..."); break }
		append(&parts, fmt.tprintf("%d %v", c.n, c.kind))
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "Scene %s%s: %d node%s", name, state.project.startScene == name ? " (the start scene)" : "", len(scene.nodes), len(scene.nodes) == 1 ? "" : "s")
	if len(parts) > 0 do fmt.sbprintf(&b, " (%s)", strings.join(parts[:], ", ", context.temp_allocator))
	camera := ""
	for node in scene.nodes do if node.kind == .Camera { camera = node.name; break }
	fmt.sbprintf(&b, "\n%s", camera == "" ? "No camera" : fmt.tprintf("Camera: %s", camera))
	scripts := make([dynamic]string, context.temp_allocator)
	for node in scene.nodes do if node.script != "" && !slice.contains(scripts[:], node.script) do append(&scripts, node.script)
	if len(scripts) > 0 do fmt.sbprintf(&b, "\nScripts: %s", strings.join(scripts[:], ", ", context.temp_allocator))
	// Facts, no picture: drawing a whole level took 200 ms (the demo's ForestScene), too long for a
	// hover on the editor's thread
	addText(out, strings.to_string(b))
	return true
}

// A dialogue node's first lines ("": the start node)
@(private="file")
addDialogueNode :: proc(out: ^ce.Hover_Content, state: ^State, path, node: string) {
	index := Project_FindDialogue(&state.project, path)
	if index < 0 do return
	data := &state.project.dialogues[index].data
	want := node != "" ? node : data.start
	at := -1
	for n, i in data.nodes do if n.name == want || (want == "" && i == 0) { at = i; break }
	if at < 0 {
		addText(out, fmt.tprintf("%s has no node %q", filepath.base(path), want))
		return
	}
	n := data.nodes[at]
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s, node %s:", filepath.base(path), n.name)
	shown := 0
	for step in n.steps {
		if shown == 3 { strings.write_string(&b, "\n..."); break }
		#partial switch step.kind {
		case .Line:
			if step.speaker != "" do fmt.sbprintf(&b, "\n%s: %s", step.speaker, step.text)
			else do fmt.sbprintf(&b, "\n%s", step.text)
			shown += 1
		case .Options:
			for o in step.options do fmt.sbprintf(&b, "\n- %s", o.text)
			shown += 1
		case .Jump:
			fmt.sbprintf(&b, "\n(jumps to %s)", step.target)
			shown += 1
		}
	}
	if shown == 0 do strings.write_string(&b, "\n(no lines)")
	addText(out, strings.to_string(b))
}

// An animation's frames as a strip (8 at most) and its facts
@(private="file")
addAnimationStrip :: proc(out: ^ce.Hover_Content, state: ^State, a: AnimationDef, owner: string) {
	if a.sheet == "" {
		addText(out, fmt.tprintf("Animation %q: no sprite sheet", a.name))
		return
	}
	full := joinPath(state.project.rootPath, a.sheet, allocator = context.temp_allocator)
	Key :: struct { grid: e.SheetGrid, start, end: int }
	k := Key{a.grid, a.start, a.end}
	key := fmt.tprintf("%s|%s|%x|%s", owner, a.name, hash.fnv64a(([^]u8)(&k)[:size_of(k)]), fileKey("sheet", strings.trim_suffix(full, e.ASEPRITE_SHEET_SUFFIX)))
	p, ok := cacheGet(key)
	if !ok {
		pixels, w, h, loaded := Image_LoadRGBA(full)
		if !loaded {
			addText(out, fmt.tprintf("Animation %q: %s can't be read", a.name, a.sheet))
			return
		}
		size := [2]f32{f32(w), f32(h)}
		cells := e.SheetGrid_CellCount(a.grid, size)
		start, end := AnimationDef_Range(a, cells)
		count := cells > 0 ? end - start + 1 : 0
		frames := make([dynamic]FrameCell, context.temp_allocator)
		for i in 0 ..< min(count, PREVIEW_STRIP_FRAMES) {
			cell := e.SheetGrid_CellRect(a.grid, size, start + i)
			append(&frames, FrameCell{int(cell.x), int(cell.y), int(cell.w), int(cell.h)})
		}
		strip, sw, sh := Preview_Strip(pixels, w, h, frames[:], PREVIEW_FRAME)
		fps := a.fps > 0 ? fmt.tprintf("%.0f fps", a.fps) : "its own frame times"
		p = cachePut(key, strip, sw, sh, fmt.tprintf("Animation %q: %d frame%s at %s%s%s", a.name, count, count == 1 ? "" : "s", fps, a.loop ? ", looping" : "", count > PREVIEW_STRIP_FRAMES ? fmt.tprintf(" (the first %d)", PREVIEW_STRIP_FRAMES) : ""))
	}
	addText(out, p.note)
	addPicture(out, p)
}

// A cell of a sheet (pixels)
FrameCell :: struct {
	x, y, w, h: int,
}

/*
Cells of a picture side by side, each scaled (nearest) to `height` pixels tall, 2 pixels apart.

Returns:
- The strip's RGBA pixels (temp allocated) and its size (0 when there are no cells)
*/
Preview_Strip :: proc(pixels: []u8, width, height: int, cells: []FrameCell, frameHeight: int) -> (out: []u8, w, h: int) {
	GAP :: 2
	h = frameHeight
	widths := make([]int, len(cells), context.temp_allocator)
	for c, i in cells {
		if c.w <= 0 || c.h <= 0 do continue
		widths[i] = max(c.w * frameHeight / c.h, 1)
		w += widths[i] + (i > 0 ? GAP : 0)
	}
	if w <= 0 do return nil, 0, 0
	out = make([]u8, w * h * 4, context.temp_allocator)
	x0 := 0
	for c, i in cells {
		if widths[i] == 0 do continue
		for y in 0 ..< h {
			sy := c.y + min(y * c.h / h, c.h - 1)
			if sy < 0 || sy >= height do continue
			for x in 0 ..< widths[i] {
				sx := c.x + min(x * c.w / widths[i], c.w - 1)
				if sx < 0 || sx >= width do continue
				copy(out[(y * w + x0 + x) * 4:][:4], pixels[(sy * width + sx) * 4:][:4])
			}
		}
		x0 += widths[i] + GAP
	}
	return
}

/*
The hover's preview of a constant of scripts/assets.odin: its asset (assets), its frames
(animations), its node's lines (dialogue nodes), its facts and picture (scenes).
*/
CodePreviews_Constant :: proc(state: ^State, c: ^GeneratedConstant, out: ^ce.Hover_Content) {
	#partial switch c.section {
	case .Assets:
		_ = CodePreviews_Asset(state, c.target, out)
	case .Scenes:
		_ = CodePreviews_Scene(state, c.target, out)
	case .Dialogue_Nodes:
		addDialogueNode(out, state, c.target, strings.trim(c.value, "\""))
	case .Animations:
		name := strings.trim(c.value, "\"")
		// A set's (an animation asset's), an Aseprite file's tag, or a sprite's own in a scene
		if set := Project_FindAnimationSet(&state.project, c.target); set >= 0 {
			for a in state.project.animationSets[set].animations do if a.name == name {
				addAnimationStrip(out, state, a, fmt.tprintf("set:%s", c.target))
				return
			}
		}
		if e.Aseprite_IsFile(c.target) {
			addAsepriteTag(out, state, c.target, name)
			return
		}
		for &scene in state.project.scenes {
			owner := Scene_IsComponent(&scene) ? ComponentName(scene.component) : scene.name
			if owner != c.target do continue
			for node in scene.nodes {
				if node.kind != .AnimatedSprite || node.animationSet != "" do continue
				for a in node.animations do if a.name == name {
					addAnimationStrip(out, state, a, fmt.tprintf("node:%s/%s", owner, node.name))
					return
				}
			}
		}
	}
}

// An Aseprite tag's frames as a strip
@(private="file")
addAsepriteTag :: proc(out: ^ce.Hover_Content, state: ^State, path, tag: string) {
	full := joinPath(state.project.rootPath, path, allocator = context.temp_allocator)
	key := fmt.tprintf("tag:%s|%s", tag, fileKey("ase", full))
	p, ok := cacheGet(key)
	if !ok {
		ase, err := e.Aseprite_Load(full)
		if err != .None do return
		defer e.Aseprite_Destroy(ase)
		from, to := -1, -1
		for t in ase.tags do if t.name == tag { from, to = t.from, t.to; break }
		if from < 0 do return
		count := to - from + 1
		shown := min(count, PREVIEW_STRIP_FRAMES)
		// The frames side by side in one picture, then cut as cells
		sheetW := ase.width * shown
		sheet := make([]u8, sheetW * ase.height * 4, context.temp_allocator)
		cells := make([]FrameCell, shown, context.temp_allocator)
		for i in 0 ..< shown {
			frame := e.Aseprite_FramePixels(ase, from + i, context.temp_allocator)
			for y in 0 ..< ase.height do copy(sheet[(y * sheetW + i * ase.width) * 4:][:ase.width * 4], frame[y * ase.width * 4:][:ase.width * 4])
			cells[i] = {i * ase.width, 0, ase.width, ase.height}
		}
		strip, sw, sh := Preview_Strip(sheet, sheetW, ase.height, cells, PREVIEW_FRAME)
		p = cachePut(key, strip, sw, sh, fmt.tprintf("Animation %q of %s: %d frame%s%s", tag, filepath.base(path), count, count == 1 ? "" : "s", count > shown ? fmt.tprintf(" (the first %d)", shown) : ""))
	}
	addText(out, p.note)
	addPicture(out, p)
}

/*
What a string literal (or a tag's `default=...`) at a position names, previewed: an asset's path
or a scene's name.

Returns:
- Whether it named one (blocks were added)
*/
CodePreviews_Literal :: proc(state: ^State, doc: ce.Provider_Document, pos: cebuf.Position, out: ^ce.Hover_Content) -> bool {
	if pos.line < 0 || pos.line >= cebuf.buffer_line_count(doc.buffer) do return false
	text, ok := Preview_LiteralAt(cebuf.buffer_line_str(doc.buffer, pos.line), pos.col)
	if !ok do return false
	for asset in state.project.assets do if asset.path == text do return CodePreviews_Asset(state, text, out)
	return CodePreviews_Scene(state, text, out)
}

/*
The text of the string literal at a column of a line: a "..." string's contents, or in a
`...` tag the `key=value` value under the column (`default=assets/ship.png`).

Returns:
- The text, and whether the column is in a literal
*/
Preview_LiteralAt :: proc(line: string, column: int) -> (string, bool) {
	start := -1
	quote: u8
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		if start < 0 {
			if c == '/' && i + 1 < len(line) && line[i + 1] == '/' do return "", false
			if c == '"' || c == '`' { start, quote = i, c }
			continue
		}
		if quote == '"' && c == '\\' { i += 1; continue }
		if c != quote do continue
		// The literal start+1 ..< i
		if column > start && column <= i {
			inner := line[start + 1:i]
			if quote == '"' do return inner, true
			// A tag: the space-separated word under the column, after its `=`
			at := column - start - 1
			from, to := at, at
			for from > 0 && inner[from - 1] != ' ' && inner[from - 1] != '"' do from -= 1
			for to < len(inner) && inner[to] != ' ' && inner[to] != '"' do to += 1
			word := inner[from:to]
			if eq := strings.index_byte(word, '='); eq >= 0 do word = word[eq + 1:]
			return word, word != ""
		}
		start = -1
	}
	return "", false
}
