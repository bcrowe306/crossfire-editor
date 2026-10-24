package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Asset import settings (the engine's asset_import.odin and fonts.odin), set in the browser's
preview of each asset:

- **Images:** Filtering, Smooth or Pixels (`AssetDef.filter`; Project default: Project Settings >
  General > Image filtering, `Project.textureFilter`). The viewport follows at once
  (`Preview_ImportSettings`).
- **Fonts:** a TrueType or OpenType font's **Sharp at any size (MSDF)** (`AssetDef.msdf`): the
  editor makes its atlas with msdf-atlas-gen (one of the shader tools: `Fonts_MakeMSDF`, on save,
  before Play and exports, and when the font changes), and games draw it through the MSDF shader
  on the GPU renderer. Bitmap fonts (`.fnt`, BMFont) are fonts too: the preview tells their size
  and glyphs; exports take their page images.
- **Sounds:** **Convert to Ogg Vorbis** (`Audio_Convert_Requested`) runs ffmpeg on a worker
  (`Audio_Converted`) and points the project at the new file (nodes and script values using the
  old one follow); files SDL_mixer can't read (`AUDIO_CONVERT_EXTENSIONS`: m4a, aac, opus...) are
  converted to Ogg on import. Without ffmpeg (Settings > Toolchain), both say so.

Changing these is an asset change, like imports: saved with the project, not undoable.
Widget keys: `asset-filter`, `asset-msdf`, `asset-msdf-make`, `asset-convert`.
*/

// Sound files SDL_mixer doesn't read: converted to Ogg Vorbis on import (with ffmpeg)
AUDIO_CONVERT_EXTENSIONS :: []string{".m4a", ".aac", ".opus", ".wma", ".webm", ".mp4", ".m4b", ".amr", ".ac3"}
// The import dialog's pattern for them
IMPORT_CONVERT_PATTERN :: "m4a;aac;opus;wma;webm;mp4;m4b;amr;ac3"

// An image's filtering chosen in the preview (an asset index)
Asset_Filter_Changed :: struct {
	index: int,
	filter: e.TextureFilter,
}
// A font's MSDF atlas on or off
Asset_MSDF_Changed :: struct {
	index: int,
	on: bool,
}
// Make a font's MSDF atlas now (an asset index)
Font_MSDF_Make_Requested :: distinct int
// Convert a sound asset to Ogg Vorbis (an asset index)
Audio_Convert_Requested :: distinct int
// ffmpeg is done (`index`: the asset converted, -1 for an import); strings owned
Audio_Converted :: struct {
	index: int,
	source, output, problem: string,
}

/*
Handles the import settings' messages.

Returns:
- A command to run, and whether `m` was one of them
*/
AssetImport_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Asset_Filter_Changed:
		if v.index < 0 || v.index >= len(state.project.assets) do break
		asset := &state.project.assets[v.index]
		if asset.filter == v.filter do break
		asset.filter = v.filter
		state.session.assetsChanged = true
		logLine(state, .Info, fmt.aprintf("%s: %s", filepath.base(asset.path), textureFilterLabel(v.filter, false)))
	case Asset_MSDF_Changed:
		if v.index < 0 || v.index >= len(state.project.assets) do break
		asset := &state.project.assets[v.index]
		if asset.msdf == v.on || Font_IsBitmapPath(asset.path) do break
		asset.msdf = v.on
		state.session.assetsChanged = true
		if v.on do _ = fontMakeMSDF(state, asset^, false)
	case Font_MSDF_Make_Requested:
		if int(v) < 0 || int(v) >= len(state.project.assets) do break
		_ = fontMakeMSDF(state, state.project.assets[v], true)
	case Audio_Convert_Requested:
		if int(v) < 0 || int(v) >= len(state.project.assets) do break
		return Audio_Convert(state, AssetFilePath(&state.project, state.project.assets[v]), int(v)), true
	case Audio_Converted:
		defer { delete(v.source); delete(v.output); delete(v.problem) }
		if v.problem != "" {
			logLine(state, .Error, fmt.aprintf("Converting %s: %s", filepath.base(v.source), v.problem))
			break
		}
		if v.index < 0 {
			importAsset(state, v.output)
			break
		}
		if v.index >= len(state.project.assets) do break
		audioReplace(state, v.index, v.output)
	case:
		return {}, false
	}
	return {}, true
}

// Whether a sound file needs converting before games can play it
Audio_NeedsConversion :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	for x in AUDIO_CONVERT_EXTENSIONS do if ext == x do return true
	return false
}

// Whether a font path is a bitmap font (the engine's BMFont)
Font_IsBitmapPath :: proc(path: string) -> bool {
	return e.Font_IsBitmap(path)
}

// ffmpeg, if this computer has it ("" when not)
Toolchain_FFmpeg :: proc() -> string {
	path, found := Script_FindEditorProgram("ffmpeg")
	return found ? path : ""
}

/*
Converts a sound to Ogg Vorbis with ffmpeg on a worker thread: beside the asset (`index` >= 0),
or into the project's assets (an import, `index` -1). Sends Audio_Converted.
*/
Audio_Convert :: proc(state: ^State, source: string, index: int) -> skald.Command(Msg) {
	ffmpeg := Toolchain_FFmpeg()
	if ffmpeg == "" {
		logLine(state, .Error, fmt.aprintf("Converting %s needs ffmpeg (ffmpeg.org, or your package manager): Settings > Toolchain", filepath.base(source)))
		return {}
	}
	output := ""
	stem := strings.trim_suffix(filepath.base(source), filepath.ext(source))
	if index >= 0 {
		dir := filepath.dir(source)
		output = joinPath(dir, uniqueFileName(dir, fmt.tprintf("%s.ogg", stem)), allocator = context.temp_allocator)
	} else {
		dir := joinPath(state.project.rootPath, ASSETS_FOLDER, allocator = context.temp_allocator)
		_ = os.make_directory_all(dir)
		output = joinPath(dir, uniqueFileName(dir, fmt.tprintf("%s.ogg", stem)), allocator = context.temp_allocator)
	}
	logLine(state, .Info, fmt.aprintf("Converting %s to Ogg Vorbis...", filepath.base(source)))
	Job :: struct { ffmpeg, source, output: string, index: int }
	job := Job{strings.clone(ffmpeg), strings.clone(source), strings.clone(output), index}
	return skald.cmd_thread(Msg, job, proc(job: Job) -> Msg {
		defer delete(job.ffmpeg)
		return Audio_Converted{index = job.index, source = job.source, output = job.output, problem = Audio_ConvertFile(job.ffmpeg, job.source, job.output)}
	})
}

/*
Runs ffmpeg: a sound file to Ogg Vorbis (quality 5, about 160 kb/s stereo: smaller than WAV, near
enough to the original). Blocks: Audio_Convert runs it on a worker.

Returns:
- "" or what went wrong (owned)
*/
Audio_ConvertFile :: proc(ffmpeg, source, output: string) -> string {
	state, stdout, stderr, err := Process_Exec({command = {ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", source, "-vn", "-c:a", "libvorbis", "-q:a", "5", output}}, context.allocator)
	defer { delete(stdout); delete(stderr) }
	if err != nil do return fmt.aprintf("couldn't run ffmpeg: %v", err)
	if !state.exited || state.exit_code != 0 || !os.exists(output) {
		text := strings.trim_space(string(stderr))
		return strings.clone(text != "" ? text : "ffmpeg failed")
	}
	return ""
}

/*
Makes the MSDF atlases of the project's fonts that have the setting on and changed (all, `force`).
Problems are logged.

Returns:
- false if one couldn't be made
*/
Fonts_MakeMSDF :: proc(state: ^State, force := false) -> bool {
	ok := true
	for asset in state.project.assets do if asset.kind == .Font && asset.msdf {
		if !fontMakeMSDF(state, asset, force) do ok = false
	}
	return ok
}

/*
The project's files an export takes for its fonts: MSDF atlases, bitmap fonts' page images
(relative paths).
*/
Fonts_ExportFiles :: proc(project: ^Project, allocator := context.allocator) -> []string {
	files := make([dynamic]string, allocator)
	for asset in project.assets do if asset.kind == .Font {
		if asset.msdf {
			append(&files, strings.concatenate({asset.path, e.MSDF_ATLAS_SUFFIX}, allocator), strings.concatenate({asset.path, e.MSDF_IMAGE_SUFFIX}, allocator))
		}
		if e.Font_IsBitmap(asset.path) {
			data, read := os.read_entire_file(AssetFilePath(project, asset), context.temp_allocator)
			if read != nil do continue
			font, parsed := e.ParseBMFont(string(data), context.temp_allocator)
			if !parsed do continue
			dir := filepath.dir(asset.path)
			for page in font.pages do append(&files, strings.clone(dir == "." ? page : fmt.tprintf("%s/%s", dir, page), allocator))
		}
	}
	return files[:]
}

/*
The image filtering choice: the project's default (for an image) or Default meaning Smooth (the
project's own setting), Smooth, Pixels.
*/
textureFilterSelect :: proc(ctx: ^skald.Ctx(Msg), value: e.TextureFilter, key: string, project: bool, on: proc(f: e.TextureFilter) -> Msg) -> skald.View {
	labels := make([]string, len(e.TextureFilter), context.temp_allocator)
	for f, i in e.TextureFilter do labels[i] = textureFilterLabel(f, project)
	Payload :: struct { on: proc(f: e.TextureFilter) -> Msg, project: bool }
	return skald.select(ctx, textureFilterLabel(value, project), labels, Payload{on, project},
		proc(p: Payload, label: string) -> Msg {
			for f in e.TextureFilter do if textureFilterLabel(f, p.project) == label do return p.on(f)
			return p.on(.Default)
		},
		id = skald.hash_id(key), width = 220)
}

@(private="file")
textureFilterLabel :: proc(f: e.TextureFilter, project: bool) -> string {
	switch f {
	case .Default: return project ? "Smooth (Aseprite files: pixels)" : "The project's setting"
	case .Smooth:  return "Smooth"
	case .Pixel:   return "Pixels (pixel art)"
	}
	return ""
}

// The image preview's import rows: its filtering
imageImportRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, index: int) -> skald.View {
	th := ctx.theme
	asset := s.project.assets[index]
	on :: proc(f: e.TextureFilter) -> Msg { return Asset_Filter_Changed{index = previewAsset, filter = f} }
	previewAsset = index
	effective := asset.filter != .Default ? asset.filter : s.project.textureFilter
	if effective == .Default do effective = e.Aseprite_IsFile(asset.path) ? .Pixel : .Smooth
	// The sprite sheet slicer, on this image (slicer_edit.odin)
	slice := skald.button(ctx, fmt.tprintf("%s  Slice Sprite Sheet…", ICON_SCISSORS), Msg(Slicer_Opened(strings.clone(asset.path, context.temp_allocator))),
		id = skald.hash_id("browser-slice"), bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	// Beside the Filtering label, not on a line of its own: a short browser keeps room for the picture
	return skald.col(
		skald.row(
			skald.text("Filtering", th.color.fg, th.font.size_xs),
			skald.flex(1, skald.spacer(0)),
			skald.tooltip(ctx, slice, "Cut it into frames (by a grid, or by finding its sprites) and name animations from them", id = skald.hash_id("browser-slice-tip")),
			spacing = th.spacing.xs, cross_align = .Center, width = previewTextWidth),
		textureFilterSelect(ctx, asset.filter, "asset-filter", false, on),
		skald.text(effective == .Pixel ? "Drawn with hard square pixels when scaled or turned." : "Drawn smoothly when scaled or turned.", th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth),
		spacing = th.spacing.xs,
	)
}

// The asset the preview's filtering choice is for (the select's callback can't capture it)
@(private="file")
previewAsset: int

// A font's preview: what it is, and its MSDF setting (TrueType) or its glyphs (bitmap)
fontPreview :: proc(ctx: ^skald.Ctx(Msg), s: ^State, index: int) -> skald.View {
	th := ctx.theme
	asset := s.project.assets[index]
	path := AssetFilePath(&s.project, asset)
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm, max_width = previewTextWidth))
	if e.Font_IsBitmap(asset.path) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		font, ok := e.ParseBMFont(string(data), context.temp_allocator)
		if err != nil || !ok {
			append(&rows, skald.text("Not a BMFont file this engine reads (export text or XML .fnt files).", th.color.danger, th.font.size_xs, max_width = previewTextWidth))
		} else {
			missing := 0
			dir := filepath.dir(path)
			for page in font.pages do if !os.exists(joinPath(dir, page, allocator = context.temp_allocator)) do missing += 1
			append(&rows, skald.text(fmt.tprintf("A bitmap font: %.0f px, %d glyphs on %d page%s%s.", font.size, len(font.chars), len(font.pages), len(font.pages) == 1 ? "" : "s",
				missing > 0 ? fmt.tprintf(" %d page image%s missing beside it", missing, missing == 1 ? " is" : "s are") : ""), missing > 0 ? th.color.danger : th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
			append(&rows, skald.text("Each letter is a picture: crisp at its own size and whole multiples of it, for pixel-art text.", th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
		}
		return skald.col(..rows[:], spacing = th.spacing.xs)
	}
	append(&rows, skald.text(fileInfo(path, ""), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
	Payload :: struct { index: int }
	append(&rows, skald.checkbox(ctx, asset.msdf, "Sharp at any size (MSDF)", Payload{index},
		proc(p: Payload, on: bool) -> Msg { return Asset_MSDF_Changed{p.index, on} },
		id = skald.hash_id("asset-msdf")))
	status := "Text in it stays sharp when it's big, zoomed or turned: drawn from a distance-field atlas on the GPU renderer (elsewhere as usual)."
	if asset.msdf {
		atlas := strings.concatenate({path, e.MSDF_ATLAS_SUFFIX}, context.temp_allocator)
		tools, found := Toolchain_ShaderTools()
		switch {
		case !found || tools.msdfAtlasGen == "":
			status = "The font tool (msdf-atlas-gen, one of the shader tools) isn't here: Settings > Toolchain."
		case !os.exists(atlas):
			status = "Its atlas isn't made yet: Make Atlas (or save)."
		case:
			status = fmt.tprintf("Atlas made (%s); made again when the font changes.", e.MSDF_IMAGE_SUFFIX[1:])
		}
		append(&rows, skald.button(ctx, "Make Atlas", Msg(Font_MSDF_Make_Requested(index)), id = skald.hash_id("asset-msdf-make"),
			bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm))
	}
	append(&rows, skald.text(status, th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
	return skald.col(..rows[:], spacing = th.spacing.xs)
}

// A sound's Convert to Ogg Vorbis (not for Ogg files)
audioImportRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State, index: int) -> skald.View {
	th := ctx.theme
	asset := s.project.assets[index]
	if strings.to_lower(filepath.ext(asset.path), context.temp_allocator) == ".ogg" do return skald.View(skald.View_Spacer{size = 0})
	button := skald.button(ctx, "Convert to Ogg Vorbis", Msg(Audio_Convert_Requested(index)), id = skald.hash_id("asset-convert"),
		bg = th.color.surface, fg = th.color.fg, padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm,
		disabled = Toolchain_FFmpeg() == "")
	note := Toolchain_FFmpeg() == "" ? "Needs ffmpeg (Settings > Toolchain)." : "A smaller file beside it (quality about 160 kb/s); the project uses it from then on."
	return skald.col(
		skald.tooltip(ctx, button, "Make an Ogg Vorbis copy with ffmpeg and use it instead of this file", id = skald.hash_id("asset-convert-tip")),
		skald.text(note, th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth),
		spacing = th.spacing.xs,
	)
}

// INTERNAL

@(private="file")
fontMakeMSDF :: proc(state: ^State, asset: AssetDef, force: bool) -> bool {
	tools, found := Toolchain_ShaderTools()
	if !found || tools.msdfAtlasGen == "" {
		logLine(state, .Warning, fmt.aprintf("%s: no font tool (Settings > Toolchain): its MSDF atlas isn't made", filepath.base(asset.path)))
		return false
	}
	path := absolutePath(AssetFilePath(&state.project, asset))
	// The project's own (another editor may write the charset file at once)
	scratch := absolutePath(joinPath("build", "fonts", projectBuildFolder(absolutePath(state.project.rootPath)), allocator = context.temp_allocator))
	messages, ok, made := e.Font_MakeMSDF(tools, path, scratch, force = force)
	if !ok {
		logLine(state, .Error, fmt.aprintf("%s: %s", asset.path, messages))
		return false
	}
	if made {
		logLine(state, .Info, fmt.aprintf("Made the MSDF atlas of %s", asset.path))
		Preview_FontChanged(path)
	}
	return true
}

// Points the project at a converted sound: the asset, nodes playing it, script values naming it
@(private="file")
audioReplace :: proc(state: ^State, index: int, output: string) {
	root := absolutePath(state.project.rootPath)
	relative, err := filepath.rel(root, absolutePath(output), context.temp_allocator)
	if err != nil do return
	relative = toSlashes(relative)
	old := strings.clone(state.project.assets[index].path, context.temp_allocator)
	if AudioPreview_IsLoaded(AssetFilePath(&state.project, state.project.assets[index])) do AudioPreview_Unload()
	delete(state.project.assets[index].path)
	state.project.assets[index].path = strings.clone(relative)
	followed := 0
	replace :: proc(value: ^string, old, new: string) -> int {
		if value^ != old do return 0
		delete(value^)
		value^ = strings.clone(new)
		return 1
	}
	for &scene in state.project.scenes do for &node in scene.nodes {
		followed += replace(&node.sound, old, relative)
		for &layer in node.musicLayers do followed += replace(&layer.sound, old, relative)
		for &p in node.props do followed += replace(&p.value, old, relative)
		for &extra in node.moreScripts do for &p in extra.props do followed += replace(&p.value, old, relative)
		for &p in node.customProps do followed += replace(&p.value, old, relative)
	}
	for &g in state.project.globals do for &p in g.props do followed += replace(&p.value, old, relative)
	state.session.assetsChanged = true
	if message := Scripts_WriteAssetsFile(&state.project); message != "" do logLine(state, .Warning, strings.clone(message))
	logLine(state, .Info, fmt.aprintf("Converted %s to %s%s (the old file is still there)", old, relative,
		followed > 0 ? fmt.tprintf("; %d use%s now play%s it", followed, followed == 1 ? "" : "s", followed == 1 ? "s" : "") : ""))
}
