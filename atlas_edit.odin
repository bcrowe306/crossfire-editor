package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."
import stbi "vendor:stb/image"

/*
Texture atlases (the engine's atlas.odin): many images packed into one picture, which Sprites
draw a region of.

- **Data:** `Project.atlases` (`AtlasDef`: the `.atlas.xml` file and its `e.AtlasData`), assets of
  kind Atlas in `atlases/`, loaded with the project. Each region names an image of the project
  (`AtlasRegion.source`) and where it is in the packed picture (`atlases/<name>.png`).
- **Editing** (the inspector when the browser selects one: `atlasInspector`,
  `State.atlasSelection`): add images (`Atlas_Image_Added`; the browser's New Atlas makes an
  empty one), remove one, padding, filtering. **Every edit packs again** (`Atlas_PackFiles`:
  the images read with `Image_LoadRGBA`, placed by `e.Atlas_Pack`, written as a PNG with stb,
  then the `.atlas.xml`): the files are always current, so the viewport, Play and exports read
  them as they are. **Pack Again** repacks after the images changed on disk. Not undoable (it
  writes files), like imports.
- **Using one:** a Sprite's Texture lists atlases too; with one chosen, its **Region** row picks
  the region (`NodeDef.region`, scene files' `region`). Scripts: `ATLAS_X` path constants,
  `e.Sprite_SetRegion(sprite, ATLAS_ITEMS, "coin")`.

Widget keys: `atlas-add`, `atlas-remove-<i>`, `atlas-padding`, `atlas-filter`, `atlas-pack`,
`inspector-region-<node>`.
*/

ATLAS_FOLDER :: "atlases"

// An atlas asset: its file (owned) and what it holds (owned, the default allocator)
AtlasDef :: struct {
	path: string,
	data: e.AtlasData,
}

// The browser's New Atlas
Atlas_Created :: struct {}
// An image added to the shown atlas (its path; the message's string lives for the frame)
Atlas_Image_Added :: distinct string
// A region removed from the shown atlas, by index
Atlas_Image_Removed :: distinct int
// The shown atlas's padding
Atlas_Padding_Changed :: distinct int
// The shown atlas's filtering
Atlas_Filter_Changed :: distinct e.TextureFilter
// Pack the shown atlas again (its images changed)
Atlas_Pack_Requested :: struct {}

// The choice for no region (the whole picture)
REGION_NONE :: "(choose a region)"
// The atlas inspector's first choice
ATLAS_ADD_PROMPT :: "Add an image..."

// Reads an `.atlas.xml` file (owned), or an empty atlas and why
Project_LoadAtlas :: proc(rootPath, path: string) -> (AtlasDef, string) {
	def := AtlasDef{path = strings.clone(path)}
	text, err := os.read_entire_file(joinPath(rootPath, path, allocator = context.temp_allocator), context.temp_allocator)
	if err != nil do return def, fmt.tprintf("Couldn't read %s", path)
	parsed, parseErr := e.ParseAtlas(string(text))
	if parseErr != .None do return def, fmt.tprintf("%s isn't an atlas file (%v)", path, parseErr)
	def.data = parsed
	return def, ""
}

AtlasDef_Destroy :: proc(a: ^AtlasDef) {
	delete(a.path)
	e.AtlasData_Destroy(&a.data)
	a^ = {}
}

// The project's atlas for a file (-1 if none)
Project_FindAtlas :: proc(project: ^Project, path: string) -> int {
	for a, i in project.atlases do if a.path == path do return i
	return -1
}

/*
Makes a new empty atlas, `atlases/<name>.atlas.xml` (numbered when taken), and writes its file.

Returns:
- Its index in `project.atlases`, or -1 and why
*/
Project_CreateAtlas :: proc(project: ^Project, name: string) -> (int, string) {
	base := strings.to_lower(strings.trim_space(name), context.temp_allocator)
	if base == "" do base = "atlas"
	taken :: proc(project: ^Project, path: string) -> bool {
		for asset in project.assets do if strings.equal_fold(asset.path, path) do return true
		return os.exists(joinPath(project.rootPath, path, allocator = context.temp_allocator))
	}
	path := fmt.tprintf("%s/%s%s", ATLAS_FOLDER, base, e.ATLAS_EXTENSION)
	stem := base
	for n := 2; taken(project, path); n += 1 {
		stem = fmt.tprintf("%s_%d", base, n)
		path = fmt.tprintf("%s/%s%s", ATLAS_FOLDER, stem, e.ATLAS_EXTENSION)
	}
	def := AtlasDef{path = strings.clone(path), data = {image = fmt.aprintf("%s/%s.png", ATLAS_FOLDER, stem), padding = 2, regions = make([dynamic]e.AtlasRegion)}}
	if problem := Atlas_PackFiles(project, &def); problem != "" {
		AtlasDef_Destroy(&def)
		return -1, problem
	}
	append(&project.assets, AssetDef{path = strings.clone(path), kind = .Atlas})
	append(&project.atlases, def)
	return len(project.atlases) - 1, ""
}

/*
Packs an atlas's images into its picture and writes both files: the PNG (a 1 x 1 clear one when
it has no images) and the `.atlas.xml` with every region's place.

Returns:
- "" or what went wrong (an image that can't be read, too big to fit)
*/
Atlas_PackFiles :: proc(project: ^Project, def: ^AtlasDef) -> string {
	Image :: struct { pixels: []u8, size: [2]int }
	images := make([]Image, len(def.data.regions), context.temp_allocator)
	sizes := make([][2]int, len(def.data.regions), context.temp_allocator)
	for r, i in def.data.regions {
		pixels, w, h, ok := Image_LoadRGBA(joinPath(project.rootPath, r.source, allocator = context.temp_allocator))
		if !ok do return fmt.tprintf("%s: couldn't read %s", def.path, r.source)
		images[i] = {pixels, {w, h}}
		sizes[i] = {w, h}
	}
	positions, size, fits := e.Atlas_Pack(sizes, def.data.padding)
	if !fits do return fmt.tprintf("%s: its images don't fit in %d x %d pixels", def.path, e.ATLAS_MAX_SIZE, e.ATLAS_MAX_SIZE)
	picture := make([]u8, size.x * size.y * 4, context.temp_allocator)
	for &r, i in def.data.regions {
		p, img := positions[i], images[i]
		for y in 0 ..< img.size.y {
			copy(picture[((p.y + y) * size.x + p.x) * 4:][:img.size.x * 4], img.pixels[y * img.size.x * 4:][:img.size.x * 4])
		}
		r.rect = {p.x, p.y, img.size.x, img.size.y}
	}
	imagePath := joinPath(project.rootPath, def.data.image, allocator = context.temp_allocator)
	_ = os.make_directory_all(filepath.dir(imagePath))
	if stbi.write_png(strings.clone_to_cstring(imagePath, context.temp_allocator), i32(size.x), i32(size.y), 4, raw_data(picture), i32(size.x * 4)) == 0 {
		return fmt.tprintf("Couldn't write %s", def.data.image)
	}
	full := joinPath(project.rootPath, def.path, allocator = context.temp_allocator)
	if err := os.write_entire_file(full, e.FormatAtlas(def.data, context.temp_allocator)); err != nil do return fmt.tprintf("Couldn't write %s: %v", def.path, err)
	Preview_AtlasChanged(def.path, imagePath)
	return ""
}

// Whether a path is an atlas file
Asset_IsAtlas :: proc(path: string) -> bool {
	return e.Atlas_IsFile(path)
}

// The region names of an atlas (temp allocated)
Atlas_RegionNames :: proc(project: ^Project, path: string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	if i := Project_FindAtlas(project, path); i >= 0 do for r in project.atlases[i].data.regions do append(&names, r.name)
	return names[:]
}

/*
Handles the atlas messages.

Returns:
- Whether the message was this file's
*/
AtlasEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	selected: ^AtlasDef
	if s.atlasSelection >= 0 && s.atlasSelection < len(s.project.atlases) do selected = &s.project.atlases[s.atlasSelection]
	repack :: proc(s: ^State, def: ^AtlasDef) {
		s.session.assetsChanged = true
		if problem := Atlas_PackFiles(&s.project, def); problem != "" do logLine(s, .Error, strings.clone(problem))
	}
	#partial switch v in m {
	case Atlas_Created:
		index, problem := Project_CreateAtlas(&s.project, "atlas")
		if problem != "" {
			logLine(s, .Error, strings.clone(problem))
			break
		}
		s.session.assetsChanged = true
		path := s.project.atlases[index].path
		logLine(s, .Info, fmt.aprintf("Made %s: add images to it in the inspector", path))
		for asset, i in s.project.assets do if asset.path == path do s.browserSelection = {kind = .Asset, folder = .Atlases, index = i}
		s.browserOpen[.Atlases] = true
		s.atlasSelection = index
		s.selectedNode = -1
		if message := Scripts_WriteAssetsFile(&s.project); message != "" do logLine(s, .Warning, strings.clone(message))
	case Atlas_Image_Added:
		source := string(v)
		if selected == nil || source == "" || source == ATLAS_ADD_PROMPT do break
		for r in selected.data.regions do if r.source == source do return true
		// Named after the file, unique in the atlas
		base := strings.trim_suffix(filepath.base(source), filepath.ext(source))
		name := base
		taken :: proc(def: ^AtlasDef, name: string) -> bool {
			for r in def.data.regions do if r.name == name do return true
			return false
		}
		for n := 2; taken(selected, name); n += 1 do name = fmt.tprintf("%s_%d", base, n)
		append(&selected.data.regions, e.AtlasRegion{name = strings.clone(name), source = strings.clone(source)})
		repack(s, selected)
	case Atlas_Image_Removed:
		i := int(v)
		if selected == nil || i < 0 || i >= len(selected.data.regions) do break
		delete(selected.data.regions[i].name)
		delete(selected.data.regions[i].source)
		ordered_remove(&selected.data.regions, i)
		repack(s, selected)
	case Atlas_Padding_Changed:
		if selected == nil do break
		selected.data.padding = clamp(int(v), 0, 32)
		repack(s, selected)
	case Atlas_Filter_Changed:
		if selected == nil do break
		selected.data.filter = e.TextureFilter(v)
		repack(s, selected)
	case Atlas_Pack_Requested:
		if selected == nil do break
		repack(s, selected)
		logLine(s, .Info, fmt.aprintf("Packed %s", selected.path))
	case:
		return false
	}
	return true
}

/*
The inspector for an atlas chosen in the browser: its regions (each removable), Add an image,
padding, filtering, the packed picture's size, Pack Again.
*/
atlasInspector :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	def := &s.project.atlases[s.atlasSelection]
	_, sidebarWidth := FittedSidebarWidths(&s.layout)
	controlWidth := min(inspectorControlWidth(th, sidebarWidth), INSPECTOR_MAX_TEXT_WIDTH)
	rows := make([dynamic]skald.View, context.temp_allocator)
	append(&rows, uiText(th, .Value, fmt.tprintf("%s  %s", ICON_IMAGE, filepath.base(def.path))))
	picture := [2]int{}
	for r in def.data.regions do picture = {max(picture.x, r.rect[0] + r.rect[2]), max(picture.y, r.rect[1] + r.rect[3])}
	append(&rows, uiText(th, .Muted, len(def.data.regions) == 0 ? "No images yet: add the project's images below. Sprites then draw one of them from the packed picture." :
		fmt.tprintf("%d image%s packed into %s (at least %d x %d).", len(def.data.regions), len(def.data.regions) == 1 ? "" : "s", def.data.image, picture.x, picture.y), max_width = inspectorRowWidth(controlWidth)))
	// The project's images not in it yet (atlases' own pictures left out)
	choices := make([dynamic]string, context.temp_allocator)
	append(&choices, ATLAS_ADD_PROMPT)
	for asset in s.project.assets do if asset.kind == .Image && !strings.has_prefix(asset.path, ATLAS_FOLDER + "/") {
		inside := false
		for r in def.data.regions do if r.source == asset.path do inside = true
		if !inside do append(&choices, asset.path)
	}
	append(&rows, inspectorRow(ctx, "Add image", skald.select(ctx, ATLAS_ADD_PROMPT, choices[:],
		proc(v: string) -> Msg { return Atlas_Image_Added(v) }, id = skald.hash_id("atlas-add"), width = controlWidth)))
	for r, i in def.data.regions {
		remove := skald.button(ctx, ACTION_ICONS[.Remove], Msg(Atlas_Image_Removed(i)), id = skald.hash_id(fmt.tprintf("atlas-remove-%d", i)),
			bg = th.color.surface, fg = th.color.fg_muted, padding = {tk.s, tk.hair}, font_size = th.font.size_xs, radius = th.radius.sm)
		append(&rows, skald.row(
			skald.text(fmt.tprintf("%s  %d x %d", r.name, r.rect[2], r.rect[3]), th.color.fg, th.font.size_xs, max_width = inspectorRowWidth(controlWidth) - tk.fieldXXS),
			skald.flex(1, skald.spacer(0)),
			skald.tooltip(ctx, remove, fmt.tprintf("Take %s out of the atlas (the image stays in the project)", r.source), id = skald.hash_id(fmt.tprintf("atlas-remove-tip-%d", i))),
			cross_align = .Center,
		))
	}
	append(&rows, inspectorRow(ctx, "Image gap", numberField(ctx, s, "atlas-padding", AtlasPaddingTarget{}, f64(def.data.padding), 1, 0, min(controlWidth, INSPECTOR_MAX_NUMBER_WIDTH), 0, 32)))
	on :: proc(f: e.TextureFilter) -> Msg { return Atlas_Filter_Changed(f) }
	append(&rows, inspectorRow(ctx, "Filtering", textureFilterSelect(ctx, def.data.filter, "atlas-filter", false, on)))
	append(&rows, skald.button(ctx, "Pack Again", Msg(Atlas_Pack_Requested{}), id = skald.hash_id("atlas-pack"),
		bg = th.color.surface, fg = th.color.fg, padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm))
	append(&rows, uiText(th, .Muted, "Packs the images again (after they changed). Adding or removing one packs at once.", max_width = inspectorRowWidth(controlWidth)))
	return skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.md, cross_align = .Stretch)
}

// The atlas padding's number field target (number_field.odin)
AtlasPaddingTarget :: struct {}

// The browser's preview of an atlas: its packed picture and what it holds
atlasPreview :: proc(s: ^State, ctx: ^skald.Ctx(Msg), asset: AssetDef) -> skald.View {
	th := ctx.theme
	i := Project_FindAtlas(&s.project, asset.path)
	if i < 0 do return skald.text(fmt.tprintf("%s couldn't be read.", asset.path), th.color.danger, th.font.size_sm, max_width = previewTextWidth)
	def := &s.project.atlases[i]
	image := joinPath(s.project.rootPath, def.data.image, allocator = context.temp_allocator)
	rows := make([dynamic]skald.View, context.temp_allocator)
	if len(def.data.regions) > 0 && os.exists(image) {
		Data :: struct { path: string }
		data := Data{image}
		append(&rows, skald.flex(1, skald.sized(ctx, &data, proc(ctx: ^skald.Ctx(Msg), data: ^Data, size: [2]f32) -> skald.View {
			return skald.image(ctx, data.path, width = max(size.x, 1), height = max(size.y, 1), fit = .Contain)
		})))
	}
	append(&rows, uiText(th, .Value, filepath.base(asset.path), max_width = previewTextWidth))
	append(&rows, uiText(th, .Muted, fmt.tprintf("A texture atlas of %d image%s; edit it in the inspector. A Sprite draws one of them: Texture this atlas, then its Region.", len(def.data.regions), len(def.data.regions) == 1 ? "" : "s"), max_width = previewTextWidth))
	return skald.col(..rows[:], spacing = th.spacing.xs, cross_align = .Stretch)
}
