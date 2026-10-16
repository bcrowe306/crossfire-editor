package editor

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import stbi "vendor:stb/image"

/*
Left sidebar: the project browser.

	header     project name, Import and Remove buttons
	search     filters scenes and assets by name
	tree       Scenes / Images / Audio / Fonts; selecting a scene opens it
	preview    collapsible: the selected image, or a player for the selected sound
*/
browserView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	selectedAsset := s.browserSelection.kind == .Asset

	header := panelHeader(ctx, ICON_FOLDER, fmt.tprintf("Project: %s", s.project.name),
		panelButton(ctx, "import-asset", ICON_PLUS, actionTip(s, "Import asset", .Import_Asset), Action.Import_Asset),
		panelButton(ctx, "remove-asset", ICON_TRASH, "Remove asset", Action.Remove_Asset, disabled = !selectedAsset),
	)
	// flex: a text input in a row has no width of its own
	search := skald.row(
		skald.flex(1, skald.text_input(ctx, s.browserSearch,
			proc(v: string) -> Msg { return Browser_Search_Changed(v) },
			id = skald.hash_id("browser-search"),
			placeholder = "Search scenes and assets",
			clear_button = true,
			escape_clears = true)),
		padding = th.spacing.xs,
		cross_align = .Center,
	)

	// The tree and preview share the space below the search box; it's built once layout knows
	// that space's height, so the preview keeps its own height when the window resizes
	body := skald.sized(ctx, s, proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
		if size.y != s.layout.browserBodyHeight do skald.send(ctx, Browser_Body_Measured(size.y))
		tree := browserTree(s, ctx)
		if !s.layout.previewOpen {
			return skald.col(skald.flex(1, tree), previewHeader(s, ctx), cross_align = .Stretch)
		}
		previewHeight := clamp(s.layout.previewHeight, MIN_PREVIEW_HEIGHT, max(size.y - MIN_BROWSER_TREE_HEIGHT - DIVIDER, MIN_PREVIEW_HEIGHT))
		return skald.split(ctx,
			first = tree,
			second = previewPanel(s, ctx),
			first_size = max(size.y - previewHeight - DIVIDER, MIN_BROWSER_TREE_HEIGHT),
			// The split reports the tree's height; store the preview's
			on_resize = proc(treeHeight: f32) -> Msg { return Browser_Tree_Resized(treeHeight) },
			id = skald.hash_id("split-browser-preview"),
			direction = .Column,
			min_first = MIN_BROWSER_TREE_HEIGHT,
			min_second = MIN_PREVIEW_HEIGHT,
		)
	})

	return skald.col(
		header,
		search,
		skald.divider(ctx),
		skald.flex(1, body),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

@(private="file")
browserTree :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	items := BrowserRows(s)
	if len(items) == 0 {
		return skald.col(
			skald.text(fmt.tprintf("Nothing matches '%s'", s.browserSearch), th.color.fg_muted, th.font.size_sm),
			padding = th.spacing.md,
		)
	}

	rows := make([]skald.Tree_Row, len(items), context.temp_allocator)
	for item, i in items {
		row := &rows[i]
		row.selected = item == s.browserSelection
		switch item.kind {
		case .Folder:
			open := s.browserOpen[item.folder] || s.browserSearch != ""
			row.label = fmt.tprintf("%v", item.folder)
			row.icon = open ? ICON_FOLDER_OPEN : ICON_FOLDER
			row.expandable = true
			row.expanded = open
		case .Scene:
			row.depth = 1
			row.label = s.project.scenes[item.index].name
			row.icon = ICON_SITEMAP
			// Highlight the scene open in the viewport
			row.selected = item.index == s.currentScene
		case .Asset:
			asset := s.project.assets[item.index]
			row.depth = 1
			row.label = filepath.base(asset.path)
			row.icon = assetIcon(asset.kind)
		case .None:
		}
	}

	return skald.scroll(ctx, {0, 0},
		skald.tree(ctx, rows,
			on_toggle = proc(row: int) -> Msg { return Browser_Toggled(row) },
			on_select = proc(row: int) -> Msg { return Browser_Selected(row) },
			id = skald.hash_id("browser-tree"),
			row_height = s.settings.rowHeight,
		),
		id = skald.hash_id("browser-scroll"),
	)
}

@(private="file")
previewHeader :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	open := s.layout.previewOpen
	return panelHeader(ctx, ICON_IMAGE, "Preview",
		panelButton(ctx, "toggle-preview", open ? ICON_CHEVRON_DOWN : ICON_CHEVRON_UP,
			open ? "Collapse preview" : "Expand preview", Action.Toggle_Preview_Panel),
	)
}

/*
Space the image preview was given by the last layout pass, {0, 0} when no image is previewed.
Lets UI tests check the preview is actually visible (`expect preview_visible true`).
*/
previewImageArea: [2]f32

// The selected asset: an image fitted to the panel, or a player for a sound
@(private="file")
previewPanel :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	previewImageArea = {}
	content: skald.View
	if s.browserSelection.kind != .Asset || s.browserSelection.index >= len(s.project.assets) {
		content = skald.text("Select an image or sound to preview it.", th.color.fg_muted, th.font.size_sm)
	} else {
		asset := s.project.assets[s.browserSelection.index]
		path := AssetFilePath(&s.project, asset)
		switch asset.kind {
		case .Image: content = imagePreview(s, ctx, asset, path)
		case .Audio: content = audioPreview(s, ctx, asset, path)
		case .Font:
			content = skald.col(
				skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm),
				skald.text(fileInfo(path, ""), th.color.fg_muted, th.font.size_xs),
				skald.text("Font previews aren't supported yet.", th.color.fg_muted, th.font.size_xs),
				spacing = th.spacing.xs,
			)
		}
	}
	return skald.col(
		previewHeader(s, ctx),
		skald.divider(ctx),
		// flex on the content too: the image preview flexes inside it, and a flex child of a
		// content-sized column gets no height (the image was drawn at 1x1 before this)
		skald.flex(1, skald.col(skald.flex(1, content), padding = th.spacing.sm, cross_align = .Stretch)),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

@(private="file")
imagePreview :: proc(s: ^State, ctx: ^skald.Ctx(Msg), asset: AssetDef, path: string) -> skald.View {
	th := ctx.theme
	// Header info without decoding the whole image
	w, h, channels: c.int
	dimensions := ""
	if stbi.info(strings.clone_to_cstring(path, context.temp_allocator), &w, &h, &channels) != 0 {
		dimensions = fmt.tprintf("%d x %d", w, h)
	}
	if !os.exists(path) {
		return skald.text(fmt.tprintf("%s is missing from the project folder.", asset.path), th.color.danger, th.font.size_sm)
	}

	// Fit the image into whatever space the panel has left
	Data :: struct { path: string }
	data := Data{path}
	image := skald.sized(ctx, &data, proc(ctx: ^skald.Ctx(Msg), data: ^Data, size: [2]f32) -> skald.View {
		previewImageArea = size
		return skald.image(ctx, data.path, width = max(size.x, 1), height = max(size.y, 1), fit = .Contain)
	})
	return skald.col(
		skald.flex(1, image),
		skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm),
		skald.text(fileInfo(path, dimensions), th.color.fg_muted, th.font.size_xs),
		spacing = th.spacing.xs,
		cross_align = .Stretch,
	)
}

@(private="file")
audioPreview :: proc(s: ^State, ctx: ^skald.Ctx(Msg), asset: AssetDef, path: string) -> skald.View {
	th := ctx.theme
	playing := AudioPreview_IsPlaying()
	position, duration := AudioPreview_Progress()
	// Keep frames coming while it plays, so the time and bar move
	if playing do skald.send(ctx, Msg(Preview_Tick{}))

	if !AudioPreview_IsLoaded(path) {
		return skald.col(
			skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm),
			skald.text("Couldn't load this sound (see the Console).", th.color.fg_muted, th.font.size_xs),
			spacing = th.spacing.xs,
		)
	}

	fraction := duration > 0 ? f32(position) / f32(duration) : 0
	Bar :: struct { fraction: f32, color, track: skald.Color }
	bar := Bar{fraction, th.color.primary, th.color.surface}
	return skald.col(
		skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm),
		skald.row(
			skald.button(ctx, playing ? fmt.tprintf("%s  Stop", ICON_STOP) : fmt.tprintf("%s  Play", ICON_PLAY),
				Msg(playing ? Action.Stop_Audio_Preview : Action.Play_Audio_Preview),
				id = skald.hash_id("preview-play"), width = 90),
			skald.text(fmt.tprintf("%s / %s", FormatDuration(position), FormatDuration(duration)), th.color.fg_muted, th.font.size_sm),
			spacing = th.spacing.sm,
			cross_align = .Center,
		),
		skald.canvas(ctx, new_clone(bar, context.temp_allocator), proc(bar: ^Bar, p: skald.Canvas_Painter) {
			skald.draw_rect(p.r, p.bounds, bar.track, 3)
			skald.draw_rect(p.r, {p.bounds.x, p.bounds.y, p.bounds.w * clamp(bar.fraction, 0, 1), p.bounds.h}, bar.color, 3)
		}, height = 6),
		skald.text(fileInfo(path, ""), th.color.fg_muted, th.font.size_xs),
		spacing = th.spacing.sm,
		cross_align = .Stretch,
	)
}

// "96 x 96  ·  3.2 KB"
@(private="file")
fileInfo :: proc(path, dimensions: string) -> string {
	size := ""
	if info, err := os.stat(path, context.temp_allocator); err == nil {
		bytes := f64(info.size)
		switch {
		case bytes >= 1024 * 1024: size = fmt.tprintf("%.1f MB", bytes / (1024 * 1024))
		case bytes >= 1024:        size = fmt.tprintf("%.1f KB", bytes / 1024)
		case:                      size = fmt.tprintf("%.0f B", bytes)
		}
	}
	if dimensions == "" do return size
	return fmt.tprintf("%s  ·  %s", dimensions, size)
}

@(private="file")
assetIcon :: proc(kind: AssetKind) -> string {
	switch kind {
	case .Image: return ICON_IMAGE
	case .Audio: return ICON_MUSIC
	case .Font:  return ICON_FONT_GLYPH
	}
	return ICON_FILE
}
