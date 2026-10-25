package crossfire_editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import "gui:skald"
import stbi "vendor:stb/image"
import e "engine:."

/*
Aseprite files (`.aseprite`, `.ase`; the engine's aseprite.odin reads them) in the editor:
- **Images:** they're assets of kind Image, so every image field takes them (Sprite textures,
  particle textures, script fields). The engine draws their first frame, all visible layers.
- **The browser's preview** draws the sprite as the engine composites it, and lists its frames,
  layers, tags and tilesets, with Open in Aseprite (also on the browser's menu, and a double-click).
- **Open in Aseprite** starts Settings > Editor > Aseprite program (`aseprite` in PATH when empty).
- **Saved in Aseprite:** the viewport (`Preview_Render`, through the engine's
  `ResourceManager_ReloadChangedTextures`), the preview (keyed by the file's time) and a game
  run with Play (the engine does it in development runs) show the new pixels.

Widget keys: `browser-aseprite-open`.
*/

/*
A file as parsed for the editor, read again when it changes (kept between frames; nil when it
can't be read).

Inputs:
- root: The project folder
- path: The file, relative to it
*/
AsepriteEdit_File :: proc(root, path: string) -> ^e.Aseprite {
	if path == "" do return nil
	full := joinPath(root, path, allocator = context.temp_allocator)
	modified := ldtkModified(full)
	if entry, found := &asepriteCache[full]; found {
		if entry.modified == modified do return entry.file
		e.Aseprite_Destroy(entry.file)
		entry.file, _ = e.Aseprite_Load(full)
		entry.modified = modified
		return entry.file
	}
	file, _ := e.Aseprite_Load(full)
	asepriteCache[strings.clone(full)] = {file, modified}
	return file
}

// Frees the parsed files (tests, quitting)
AsepriteEdit_Destroy :: proc() {
	for path, entry in asepriteCache {
		e.Aseprite_Destroy(entry.file)
		delete(path)
	}
	delete(asepriteCache)
	asepriteCache = nil
	sync.guard(&imageSizesLock)
	for path in imageSizes do delete(path, runtime.heap_allocator())
	delete(imageSizes)
	imageSizes = nil
}

/*
An image's size in pixels, as `Image_LoadRGBA` would read it (an Aseprite file's first frame, or
its `#sheet` of every frame), read again only when the file changes (stb_image reads the header
alone).

Inputs:
- path: The image's full path

Returns:
- Its width and height, and false when it can't be read
*/
Image_Size :: proc(path: string) -> (size: [2]int, ok: bool) {
	if path == "" do return
	file := strings.trim_suffix(path, e.ASEPRITE_SHEET_SUFFIX)
	modified := ldtkModified(file)
	{
		sync.guard(&imageSizesLock)
		if entry, found := imageSizes[path]; found && entry.modified == modified do return entry.size, entry.ok
	}
	if e.Aseprite_IsFile(file) {
		if ase, err := e.Aseprite_Load(file); err == .None {
			size, ok = {ase.width, ase.height}, ase.width > 0 && ase.height > 0
			if file != path {
				columns, rows := e.Aseprite_SheetGrid(ase)
				size = {columns * ase.width, rows * ase.height}
			}
			e.Aseprite_Destroy(ase)
		}
	} else {
		w, h, channels: i32
		if stbi.info(strings.clone_to_cstring(path, context.temp_allocator), &w, &h, &channels) != 0 do size, ok = {int(w), int(h)}, w > 0 && h > 0
	}
	// Shared by every thread (the tests run on several): on the heap, under a lock
	sync.guard(&imageSizesLock)
	if entry, found := &imageSizes[path]; found {
		entry^ = {size, ok, modified}
	} else {
		if imageSizes == nil do imageSizes = make(map[string]ImageSizeEntry, runtime.heap_allocator())
		imageSizes[strings.clone(path, runtime.heap_allocator())] = {size, ok, modified}
	}
	return
}

@(private="file")
imageSizesLock: sync.Mutex

@(private="file")
ImageSizeEntry :: struct {
	size: [2]int,
	ok: bool,
	modified: time.Time,
}

// Images' sizes by full path (Image_Size), with the file's time when read
@(private="file")
imageSizes: map[string]ImageSizeEntry

@(private="file")
AsepriteCacheEntry :: struct {
	file: ^e.Aseprite,
	modified: time.Time,
}

// Thread-local, like the LDtk cache: unit tests run on several threads, each with its allocator
@(private="file", thread_local)
asepriteCache: map[string]AsepriteCacheEntry

// Open in Aseprite on an asset (by index), from the browser's preview, menu or a double-click
Aseprite_Asset_Open_Requested :: distinct int

/*
Handles Aseprite messages.

Returns:
- A command to run, and whether `m` was one of them
*/
AsepriteEdit_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Aseprite_Asset_Open_Requested:
		if int(v) < 0 || int(v) >= len(state.project.assets) do return {}, true
		return AsepriteEdit_Open(state, state.project.assets[v].path), true
	case Aseprite_Layer_Toggled:
		toggleLayer(state, v)
		return {}, true
	}
	return {}, false
}

/*
Starts Aseprite on a file (Settings > Editor > Aseprite program, else `aseprite` in PATH).
*/
AsepriteEdit_Open :: proc(state: ^State, path: string) -> skald.Command(Msg) {
	setting := FixedText_String(&state.settings.asepritePath)
	program, found := Script_FindEditorProgram(setting == "" ? "aseprite" : setting)
	if !found {
		logLine(state, .Error, fmt.aprintf("Couldn't find Aseprite ('%s'). Get it from aseprite.org (or Steam), then set its path in Settings > Editor", program))
		return {}
	}
	file := absolutePath(joinPath(state.project.rootPath, path, allocator = context.temp_allocator))
	process, err := os.process_start({command = {program, file}, working_dir = filepath.dir(file)})
	if err != nil {
		logLine(state, .Error, fmt.aprintf("Couldn't start Aseprite (%s): %v", program, err))
		return {}
	}
	logLine(state, .Info, fmt.aprintf("Opened %s in Aseprite", filepath.base(path)))
	return Editor_WatchProcess(process, program)
}

// The browser preview's picture of an Aseprite file, and what it was made from
@(private="file")
ASEPRITE_PREVIEW_IMAGE :: "aseprite-preview"
@(private="file")
previewKey: string
@(private="file")
previewSize: [2]int

/*
The browser's preview of an Aseprite file: the sprite (its first frame, as the engine draws it),
its frames, layers, tags and tilesets, and Open in Aseprite.
*/
AsepriteEdit_Preview :: proc(s: ^State, ctx: ^skald.Ctx(Msg), asset: AssetDef, index: int) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	full := joinPath(s.project.rootPath, asset.path, allocator = context.temp_allocator)
	ase := AsepriteEdit_File(s.project.rootPath, asset.path)
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, uiText(th, .Value, filepath.base(asset.path), max_width = previewTextWidth))
	// Outside the scroll, between the picture and the text: in a short window (900x500) the scroll
	// is a line tall and the buttons were half cut off at its edge
	actions := skald.row(
		skald.button(ctx, fmt.tprintf("%s  Open in Aseprite", ICON_IMAGE), Msg(Aseprite_Asset_Open_Requested(index)),
			id = skald.hash_id("browser-aseprite-open"), bg = th.color.surface, fg = th.color.fg,
			padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm),
		skald.button(ctx, fmt.tprintf("%s  Animations", ICON_FILM), Msg(Anim_Asset_Shown(asset.path)),
			id = skald.hash_id("browser-aseprite-animations"), bg = th.color.surface, fg = th.color.fg,
			padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm),
		spacing = th.spacing.xs,
		padding = th.spacing.xs,
	)
	picture: skald.View
	if ase == nil {
		append(&rows, uiText(th, .Muted, fmt.tprintf("%s couldn't be read as an Aseprite file.", asset.path), max_width = previewTextWidth, color = th.color.danger))
		picture = skald.spacer(tk.hair)
	} else {
		// Uploaded when the file (or its time) changes
		key := fmt.tprintf("%s@%v", full, ldtkModified(full))
		if ctx.renderer != nil && (key != previewKey || previewSize != {ase.width, ase.height}) && ase.width > 0 && ase.height > 0 {
			pixels := e.Aseprite_FramePixels(ase, 0, context.temp_allocator)
			if previewSize == {ase.width, ase.height} do skald.image_update_pixels(ctx.renderer, ASEPRITE_PREVIEW_IMAGE, u32(ase.width), u32(ase.height), pixels)
			else do skald.image_load_pixels(ctx.renderer, ASEPRITE_PREVIEW_IMAGE, u32(ase.width), u32(ase.height), pixels)
			delete(previewKey)
			previewKey = strings.clone(key)
			previewSize = {ase.width, ase.height}
		}
		Data :: struct { _: u8 }
		data := new(Data, context.temp_allocator)
		picture = skald.sized(ctx, data, proc(ctx: ^skald.Ctx(Msg), data: ^Data, size: [2]f32) -> skald.View {
			previewImageArea = size
			return skald.canvas(ctx, data, proc(_: ^Data, p: skald.Canvas_Painter) {
				skald.draw_image(p.r, ASEPRITE_PREVIEW_IMAGE, p.bounds, .Contain)
			}, width = max(size.x, 1), height = max(size.y, 1))
		})
		info := AsepriteEdit_Summary(ase)
		append(&rows, uiText(th, .Muted, fmt.tprintf("%s · %s", info, fileInfo(full, "")), max_width = previewTextWidth))
		if len(ase.tags) > 0 {
			names := make([dynamic]string, context.temp_allocator)
			for tag in ase.tags do append(&names, fmt.tprintf("%s (%d-%d)", tag.name, tag.from + 1, tag.to + 1))
			append(&rows, uiText(th, .Muted, fmt.tprintf("Tags: %s", strings.join(names[:], ", ", context.temp_allocator)), max_width = previewTextWidth))
		}
		layers := make([dynamic]string, context.temp_allocator)
		for layer, i in ase.layers do if layer.type != .Group {
			append(&layers, e.Aseprite_LayerShown(ase, i) ? layer.name : fmt.tprintf("%s (hidden)", layer.name))
		}
		append(&rows, uiText(th, .Muted, fmt.tprintf("Layers: %s", strings.join(layers[:], ", ", context.temp_allocator)), max_width = previewTextWidth))
		append(&rows, uiText(th, .Muted, "Used as an image, it's the first frame with every visible layer; as an AnimatedSprite's animations, its tags.", max_width = previewTextWidth))
		if TileMapEdit_HasTilemaps(s.project.rootPath, asset.path) {
			append(&rows, uiText(th, .Muted, "It has tilemap layers: drag it into the viewport for a TileMap of them.", max_width = previewTextWidth))
		}
	}
	return skald.col(
		skald.flex(3, picture),
		actions,
		// The picture keeps most of a short panel: the text scrolls, the buttons are above it
		skald.flex(1, skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.sm), id = skald.hash_id("browser-aseprite-preview"))),
		cross_align = .Stretch,
	)
}

/*
A line about an Aseprite file: "32 x 32 · 12 frames · 3 layers · 2 tags · 1 tileset".

Returns:
- The line (temp allocated)
*/
AsepriteEdit_Summary :: proc(ase: ^e.Aseprite) -> string {
	plural :: proc(n: int, word: string) -> string { return fmt.tprintf("%d %s%s", n, word, n == 1 ? "" : "s") }
	layers := 0
	for layer in ase.layers do if layer.type != .Group do layers += 1
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, fmt.tprintf("%d x %d", ase.width, ase.height), plural(len(ase.frames), "frame"), plural(layers, "layer"))
	if len(ase.tags) > 0 do append(&parts, plural(len(ase.tags), "tag"))
	if len(ase.tilesets) > 0 do append(&parts, plural(len(ase.tilesets), "tileset"))
	if len(ase.slices) > 0 do append(&parts, plural(len(ase.slices), "slice"))
	return strings.join(parts[:], " · ", context.temp_allocator)
}

/*
An image file's pixels, RGBA: an Aseprite file's first frame (composited by the engine), any other
image through stb_image.

Inputs:
- path: The file (absolute or relative to the working folder)

Returns:
- The pixels (temp allocated), the size, and false if it can't be read
*/
Image_LoadRGBA :: proc(path: string) -> (pixels: []u8, width, height: int, ok: bool) {
	// An Aseprite sheet (`<file>#sheet`, an animation asset's): every frame on a grid
	file := strings.trim_suffix(path, e.ASEPRITE_SHEET_SUFFIX)
	if e.Aseprite_IsFile(file) {
		ase, err := e.Aseprite_Load(file)
		if err != .None do return
		defer e.Aseprite_Destroy(ase)
		if ase.width <= 0 || ase.height <= 0 do return
		if file != path {
			sheet, columns, rows := e.Aseprite_SheetPixels(ase, context.temp_allocator)
			return sheet, columns * ase.width, rows * ase.height, true
		}
		return e.Aseprite_FramePixels(ase, 0, context.temp_allocator), ase.width, ase.height, true
	}
	w, h, channels: i32
	loaded := stbi.load(strings.clone_to_cstring(path, context.temp_allocator), &w, &h, &channels, 4)
	if loaded == nil do return
	defer stbi.image_free(loaded)
	pixels = make([]u8, int(w) * int(h) * 4, context.temp_allocator)
	copy(pixels, loaded[:w * h * 4])
	return pixels, int(w), int(h), true
}

// The slice choices' "none" (stored as "")
SLICE_NONE :: "(none)"

// A sprite's Aseprite layer ticked or not in the inspector (the layer's name)
Aseprite_Layer_Toggled :: struct {
	name: string,
	on: bool,
}

/*
The Aseprite file a node shows (relative to the project), "" when it doesn't: a Sprite's
texture, an AnimatedSprite's animation asset or the first of its own animations' sheets that is one.
*/
AsepriteEdit_NodeSource :: proc(node: ^NodeDef) -> string {
	#partial switch node.kind {
	case .Sprite:
		if e.Aseprite_IsFile(node.texture) do return node.texture
	case .AnimatedSprite:
		if node.animationSet != "" do return e.Aseprite_IsFile(node.animationSet) ? node.animationSet : ""
		// Its own animations: the first whose sheet is an Aseprite file (its frames, or its first
		// frame cut into cells)
		for a in node.animations {
			if file := strings.trim_suffix(a.sheet, e.ASEPRITE_SHEET_SUFFIX); e.Aseprite_IsFile(file) do return file
		}
	}
	return ""
}

/*
The sprite a slice-following CollisionShape takes its slice from, as the engine finds it: the
nearest ancestor showing an Aseprite file, or such a sprite among an ancestor's children.

Returns:
- The sprite's index, or -1
*/
AsepriteEdit_ShapeSprite :: proc(scene: ^SceneDef, shape: int) -> int {
	for at := scene.nodes[shape].parent; at >= 0; at = scene.nodes[at].parent {
		if AsepriteEdit_NodeSource(&scene.nodes[at]) != "" do return at
		for &n, i in scene.nodes do if i != shape && n.parent == at && AsepriteEdit_NodeSource(&n) != "" do return i
	}
	return -1
}

/*
Ticks a layer on or off in a layers setting ("" = every visible layer): from the layers drawn
now, in the file's order; the last one stays.

Returns:
- The new setting (owned), and false when it would draw no layer
*/
AsepriteEdit_ToggleLayer :: proc(ase: ^e.Aseprite, setting, name: string, on: bool) -> (string, bool) {
	drawn := e.Aseprite_LayersNamed(ase, setting)
	names := make([dynamic]string, context.temp_allocator)
	for layer, i in ase.layers {
		if layer.type == .Group do continue
		now := setting == "" ? e.Aseprite_LayerShown(ase, i) : slice_contains(drawn, i)
		if layer.name == name do now = on
		if now do append(&names, layer.name)
	}
	if len(names) == 0 do return "", false
	return strings.join(names[:], ","), true
}

@(private="file")
slice_contains :: proc(list: []int, value: int) -> bool {
	for v in list do if v == value do return true
	return false
}

// Handles Aseprite_Layer_Toggled on the selected node (from AsepriteEdit_Update)
@(private="file")
toggleLayer :: proc(state: ^State, v: Aseprite_Layer_Toggled) {
	node := selectedNode(state)
	if node == nil do return
	path := AsepriteEdit_NodeSource(node)
	ase := AsepriteEdit_File(state.project.rootPath, path)
	if ase == nil do return
	setting, ok := AsepriteEdit_ToggleLayer(ase, node.asepriteLayers, v.name, v.on)
	if !ok {
		logLine(state, .Warning, fmt.aprintf("%s keeps %s: it draws at least one layer", node.name, v.name))
		return
	}
	delete(node.asepriteLayers)
	node.asepriteLayers = setting
}

/*
The inspector's rows for a Sprite or AnimatedSprite showing an Aseprite file: its layers (ticked:
drawn), the pivot slice, a Sprite's 9-patch slice and size, an AnimatedSprite's frame events.
*/
asepriteSpriteRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth, numberWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	path := AsepriteEdit_NodeSource(node)
	if path == "" do return rows[:]
	ase := AsepriteEdit_File(s.project.rootPath, path)
	if ase == nil do return rows[:]
	width := inspectorRowWidth(controlWidth)
	onText :: proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} }
	append(&rows, uiText(th, .Value, fmt.tprintf("%s  Aseprite: %s", ICON_IMAGE, filepath.base(path)), max_width = width))
	// Layers: ticked are drawn (none named: every visible one)
	drawn := e.Aseprite_LayersNamed(ase, node.asepriteLayers)
	for layer, i in ase.layers do if layer.type != .Group {
		on := node.asepriteLayers == "" ? e.Aseprite_LayerShown(ase, i) : slice_contains(drawn, i)
		name := strings.clone(layer.name, context.temp_allocator)
		append(&rows, skald.checkbox(ctx, on, layer.visible ? name : fmt.tprintf("%s (hidden in Aseprite)", name), name,
			proc(name: string, on: bool) -> Msg { return Aseprite_Layer_Toggled{name, on} },
			id = skald.hash_id(fmt.tprintf("inspector-aseprite-layer-%s-%d", layer.name, key))))
	}
	// Slices: with a pivot, for the pivot; with a center, for a Sprite's 9-patch
	pivots := make([dynamic]string, context.temp_allocator)
	nines := make([dynamic]string, context.temp_allocator)
	append(&pivots, SLICE_NONE)
	append(&nines, SLICE_NONE)
	for slice in ase.slices {
		if slice.hasPivot do append(&pivots, slice.name)
		if slice.nineSlice do append(&nines, slice.name)
	}
	if len(pivots) > 1 || node.pivotSlice != "" {
		append(&rows, inspectorRow(ctx, "Pivot slice", skald.select(ctx, node.pivotSlice == "" ? SLICE_NONE : node.pivotSlice, pivots[:], NodeTextField.Pivot_Slice, onText,
			id = skald.hash_id(fmt.tprintf("inspector-pivot-slice-%d", key)), width = controlWidth)))
	}
	if node.kind == .Sprite && (len(nines) > 1 || node.nineSlice != "") {
		append(&rows, inspectorRow(ctx, "9-patch", skald.select(ctx, node.nineSlice == "" ? SLICE_NONE : node.nineSlice, nines[:], NodeTextField.Nine_Slice, onText,
			id = skald.hash_id(fmt.tprintf("inspector-nine-slice-%d", key)), width = controlWidth)))
		if node.nineSlice != "" {
			half := max((controlWidth - th.spacing.xs) * 0.5, 50)
			append(&rows, inspectorRow(ctx, "9-patch size", skald.row(
				numberField(ctx, s, fmt.tprintf("inspector-Nine_Width-%d", key), NodeField.Nine_Width, f64(node.nineSize.x), 1, 0, half, 0, 10000),
				numberField(ctx, s, fmt.tprintf("inspector-Nine_Height-%d", key), NodeField.Nine_Height, f64(node.nineSize.y), 1, 0, half, 0, 10000),
				spacing = th.spacing.xs)))
			append(&rows, uiText(th, .Muted, "0: the slice's own size. The corners keep their size; the edges and middle stretch.", max_width = width))
		}
	}
	// Frame events (cels' text or `event` property), for listeners of animation.onFrameEvent
	if node.kind == .AnimatedSprite {
		events := make([dynamic]string, context.temp_allocator)
		for f in 0..<len(ase.frames) do if text := e.Aseprite_FrameEvents(ase, f); text != "" do append(&events, fmt.tprintf("frame %d: %s", f, text))
		if len(events) > 0 {
			append(&rows, uiText(th, .Muted, fmt.tprintf("Frame events (animation.onFrameEvent): %s", strings.join(events[:], "; ", context.temp_allocator)), max_width = width))
		}
	}
	return rows[:]
}

/*
A CollisionShape's Slice row: the slices of the sprite it follows (`AsepriteEdit_ShapeSprite`),
and what it does.
*/
sliceShapeRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, node: ^NodeDef, key: int, controlWidth: f32) -> []skald.View {
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	scene := &s.project.scenes[s.currentScene]
	sprite := AsepriteEdit_ShapeSprite(scene, s.selectedNode)
	if sprite < 0 && node.slice == "" do return rows[:]
	choices := make([dynamic]string, context.temp_allocator)
	append(&choices, SLICE_NONE)
	if sprite >= 0 {
		if ase := AsepriteEdit_File(s.project.rootPath, AsepriteEdit_NodeSource(&scene.nodes[sprite])); ase != nil {
			for slice in ase.slices do append(&choices, slice.name)
		}
	}
	onText :: proc(field: NodeTextField, value: string) -> Msg { return Node_Text_Changed{field, value} }
	append(&rows, inspectorRow(ctx, "Slice", skald.select(ctx, node.slice == "" ? SLICE_NONE : node.slice, choices[:], NodeTextField.Slice, onText,
		id = skald.hash_id(fmt.tprintf("inspector-slice-%d", key)), width = controlWidth)))
	note := sprite >= 0 ? fmt.tprintf("Follows %s's Aseprite slice frame by frame (a hitbox); off where it's hidden.", scene.nodes[sprite].name) : "No sprite showing an Aseprite file near it: the slice does nothing."
	append(&rows, skald.text(note, sprite >= 0 ? th.color.fg_muted : th.color.warning, th.font.size_xs, max_width = inspectorRowWidth(controlWidth)))
	return rows[:]
}
