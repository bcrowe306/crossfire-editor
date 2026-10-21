package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
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
}

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
	th := ctx.theme
	full := joinPath(s.project.rootPath, asset.path, allocator = context.temp_allocator)
	ase := AsepriteEdit_File(s.project.rootPath, asset.path)
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm, max_width = previewTextWidth))
	// First, so a short preview panel still shows it
	append(&rows, skald.row(
		skald.button(ctx, fmt.tprintf("%s  Open in Aseprite", ICON_IMAGE), Msg(Aseprite_Asset_Open_Requested(index)),
			id = skald.hash_id("browser-aseprite-open"), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm),
		skald.button(ctx, fmt.tprintf("%s  Animations", ICON_FILM), Msg(Anim_Asset_Shown(asset.path)),
			id = skald.hash_id("browser-aseprite-animations"), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm),
		spacing = th.spacing.xs,
	))
	picture: skald.View
	if ase == nil {
		append(&rows, skald.text(fmt.tprintf("%s couldn't be read as an Aseprite file.", asset.path), th.color.danger, th.font.size_xs, max_width = previewTextWidth))
		picture = skald.spacer(1)
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
		append(&rows, skald.text(fmt.tprintf("%s · %s", info, fileInfo(full, "")), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
		if len(ase.tags) > 0 {
			names := make([dynamic]string, context.temp_allocator)
			for tag in ase.tags do append(&names, fmt.tprintf("%s (%d-%d)", tag.name, tag.from + 1, tag.to + 1))
			append(&rows, skald.text(fmt.tprintf("Tags: %s", strings.join(names[:], ", ", context.temp_allocator)), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
		}
		layers := make([dynamic]string, context.temp_allocator)
		for layer, i in ase.layers do if layer.type != .Group {
			append(&layers, e.Aseprite_LayerShown(ase, i) ? layer.name : fmt.tprintf("%s (hidden)", layer.name))
		}
		append(&rows, skald.text(fmt.tprintf("Layers: %s", strings.join(layers[:], ", ", context.temp_allocator)), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
		append(&rows, skald.text("Used as an image, it's the first frame with every visible layer; as an AnimatedSprite's animations, its tags.", th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
		if TileMapEdit_HasTilemaps(s.project.rootPath, asset.path) {
			append(&rows, skald.text("It has tilemap layers: drag it into the viewport for a TileMap of them.", th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
		}
	}
	return skald.col(
		skald.flex(3, picture),
		skald.flex(2, skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.sm), id = skald.hash_id("browser-aseprite-preview"))),
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
