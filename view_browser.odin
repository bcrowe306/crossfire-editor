package crossfire_editor

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import e "engine:."
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
		// Preview text wraps to the panel's width: its padding and a scrollbar's room off
		previewTextWidth = max(size.x - ctx.theme.spacing.sm * 2 - 14, 80)
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

	ghost := browserDrag(s, ctx, items)
	browserMouse(s, ctx, items)
	renameField := browserRename(s, ctx, items)

	rows := make([]ColoredTreeRow, len(items), context.temp_allocator)
	for item, i in items {
		row := &rows[i]
		// Each type in its own color: folders by what they hold, scenes, images, audio, fonts
		color := BrowserItemColor(s, item)
		row.iconColor = color
		row.labelColor = item.kind == .Folder ? {} : TintLabel(th, color)
		row.selected = item == s.browserSelection
		switch item.kind {
		case .Folder:
			open := s.browserOpen[item.folder] || s.browserSearch != ""
			row.label = fmt.tprintf("%v", item.folder)
			row.icon = open ? ICON_FOLDER_OPEN : ICON_FOLDER
			row.expandable = true
			row.expanded = open
		case .Script:
			row.depth = 1
			row.label = filepath.base(s.scriptFiles[item.index])
			row.icon = ICON_FILE_CODE
		case .Scene:
			row.depth = 1
			name := s.project.scenes[item.index].name
			row.label = name == s.project.startScene ? fmt.tprintf("%s  (start)", name) : name
			row.icon = ICON_SITEMAP
			// The selected scene, or else the one open in the viewport
			row.selected = item == s.browserSelection || (s.browserSelection.kind != .Scene && item.index == s.currentScene)
		case .Asset:
			asset := s.project.assets[item.index]
			row.depth = 1
			row.label = filepath.base(asset.path)
			row.icon = assetIcon(asset.kind)
		case .None:
		}
	}

	Tree_RevealSelected(ctx, rows, "browser-tree", "browser-scroll", s.settings.rowHeight)
	tree := skald.scroll(ctx, {0, 0},
		coloredTree(ctx, rows,
			on_toggle = proc(row: int) -> Msg { return Browser_Toggled(row) },
			on_select = proc(row: int) -> Msg { return Browser_Selected(row) },
			id = skald.hash_id("browser-tree"),
			row_height = s.settings.rowHeight,
		),
		id = skald.hash_id("browser-scroll"),
		reveal_focus = false,
	)
	// The right-click menu: what it offers depends on the row (set by browserMenuItems)
	labels := browserMenuItems(s)
	menu := skald.context_menu(ctx, tree, labels,
		proc(i: int) -> Msg { return i < len(browserMenuMsgs) ? browserMenuMsgs[i] : nil },
		id = skald.hash_id("browser-menu"),
		width = 240,
	)

	// flex: a scroll in a content-sized column gets no height
	return skald.col(
		skald.flex(1, menu),
		ghost,
		renameField,
		cross_align = .Stretch,
	)
}

/*
The browser's context menu for the selected row, as labels; the message for each is put in
`browserMenuMsgs` (the menu's callback can't capture, so it reads them from there).

	scene          Open, Play Scene, Rename, Duplicate, Copy, Cut, Paste, Delete, Set as Start Scene, New Scene
	Scenes, none   New Scene, Paste
	asset          Remove from Project (components: Open, Add to Scene, New Component too)
	Components     New Component
	script         Open in Editor
*/
@(private="file")
browserMenuItems :: proc(s: ^State) -> []string {
	labels := make([dynamic]string, context.temp_allocator)
	clear(&browserMenuMsgs)
	add :: proc(labels: ^[dynamic]string, label: string, msg: Msg) {
		append(labels, label)
		append(&browserMenuMsgs, msg)
	}
	shortcut :: proc(s: ^State, label: string, action: Action) -> string {
		chord := skald.shortcut_format(Keymap_Shortcut(&s.settings.keymap, action))
		return chord == "" ? label : fmt.tprintf("%s   (%s)", label, chord)
	}
	selection := s.browserSelection
	switch selection.kind {
	case .Scene:
		i := selection.index
		add(&labels, "Open", Msg(Scene_Action{.Open, i}))
		add(&labels, "Play Scene", Msg(Scene_Action{.Play, i}))
		add(&labels, shortcut(s, "Rename", .Rename_Node), Msg(Scene_Action{.Rename, i}))
		add(&labels, shortcut(s, "Duplicate", .Duplicate_Node), Msg(Scene_Action{.Duplicate, i}))
		add(&labels, shortcut(s, "Copy", .Copy_Node), Msg(Scene_Action{.Copy, i}))
		add(&labels, shortcut(s, "Cut", .Cut_Node), Msg(Scene_Action{.Cut, i}))
		if s.hasSceneClipboard do add(&labels, shortcut(s, "Paste", .Paste_Node), Msg(Scene_Action{.Paste, i}))
		add(&labels, shortcut(s, "Delete", .Delete_Node), Msg(Scene_Action{.Delete, i}))
		if s.project.scenes[i].name != s.project.startScene do add(&labels, "Set as Start Scene", Msg(Scene_Action{.Set_Start, i}))
		add(&labels, "New Scene", Msg(Scene_Action{.New, i}))
	case .Asset:
		if selection.folder == .Data do add(&labels, "New Data Resource...", Msg(New_Data_Opened{}))
		if selection.folder == .Components && selection.index < len(s.project.assets) {
			if i := Project_FindComponent(&s.project, s.project.assets[selection.index].path); i >= 0 do add(&labels, "Edit", Msg(Component_Opened(i)))
			add(&labels, "Add to Scene", Msg(Component_Instance_Added(selection.index)))
			add(&labels, "Rename", Msg(Component_Rename_Started(selection.index)))
			add(&labels, "New Component", Msg(Component_New{}))
		}
		// Sounds load whole; music streams: the same files, used one way or the other
		if selection.index < len(s.project.assets) {
			switch s.project.assets[selection.index].kind {
			case .Audio: add(&labels, "Use as Music (streamed)", Msg(Asset_Kind_Changed{selection.index, .Music}))
			case .Music: add(&labels, "Use as a Sound", Msg(Asset_Kind_Changed{selection.index, .Audio}))
			case .LDtk: add(&labels, "Open in LDtk", Msg(LDtk_Asset_Open_Requested(selection.index)))
			case .Image, .Font, .Data, .Component, .Translation:
			}
		}
		add(&labels, "Remove from Project...", Msg(Action.Remove_Asset))
	case .Script:
		if selection.index < len(s.scriptFiles) {
			path, _ := filepath.join({s.project.rootPath, s.scriptFiles[selection.index]}, context.temp_allocator)
			absolute, err := os.get_absolute_path(path, context.temp_allocator)
			add(&labels, "Open in Editor", Msg(Script_Open_File{file = err == nil ? absolute : path, line = 1}))
		}
	case .Folder, .None:
		if selection.kind == .Folder && selection.folder == .Data {
			add(&labels, "New Data Resource...", Msg(New_Data_Opened{}))
			break
		}
		if selection.kind == .Folder && selection.folder == .Components {
			add(&labels, "New Component", Msg(Component_New{}))
			break
		}
		add(&labels, "New Scene", Msg(Scene_Action{.New, -1}))
		if s.hasSceneClipboard do add(&labels, shortcut(s, "Paste Scene", .Paste_Node), Msg(Scene_Action{.Paste, -1}))
	}
	return labels[:]
}

// The messages of the browser menu's items, in order (see browserMenuItems). Package state: the
// menu's callback can't capture
@(private="file")
browserMenuMsgs: [dynamic]Msg

/*
Browser mouse and focus handling the tree widget doesn't do: a right-click selects the row under
the cursor (so the context menu acts on it), a double-click on a scene renames it, and the state
is told when the browser gains or loses keyboard focus (its keys act on scenes then).
*/
@(private="file")
browserMouse :: proc(s: ^State, ctx: ^skald.Ctx(Msg), items: []BrowserItem) {
	treeId := skald.hash_id("browser-tree")
	if s.refocus == .Browser {
		skald.widget_focus(ctx, treeId)
		skald.send(ctx, Msg(Refocus_Done{}))
	}
	focused := skald.widget_has_focus(ctx, treeId)
	if focused != s.browserFocused do skald.send(ctx, Msg(Browser_Focus_Changed(focused)))

	treeState, drawn := ctx.widgets.states[treeId]
	areaState, _ := ctx.widgets.states[skald.hash_id("browser-scroll")]
	if !drawn do return
	mouse := ctx.input.mouse_pos
	area := areaState.last_rect
	over := mouse.x >= area.x && mouse.x < area.x + area.w && mouse.y >= area.y && mouse.y < area.y + area.h &&
		!skald.mouse_over_overlay(ctx) && ctx.widgets.modal_rect_prev.w == 0
	if !over do return
	row := int(math.floor((mouse.y - treeState.last_rect.y) / s.settings.rowHeight))
	onRow := row >= 0 && row < len(items)
	if ctx.input.mouse_pressed[.Right] {
		skald.send(ctx, Msg(Browser_Right_Clicked(onRow ? row : -1)))
		// Keys then act on the browser, like after a left click
		skald.widget_focus(ctx, treeId)
	}
	if ctx.input.mouse_pressed[.Left] && onRow && ctx.input.mouse_click_count[.Left] >= 2 && items[row].kind == .Scene {
		skald.send(ctx, Msg(Scene_Action{.Rename, items[row].index}))
	}
	// A double-click on a script opens it (in a code tab, or the external editor)
	if ctx.input.mouse_pressed[.Left] && onRow && ctx.input.mouse_click_count[.Left] >= 2 && items[row].kind == .Script && items[row].index < len(s.scriptFiles) {
		path := joinPath(s.project.rootPath, s.scriptFiles[items[row].index], allocator = context.temp_allocator)
		if absolute, err := os.get_absolute_path(path, context.temp_allocator); err == nil do path = absolute
		skald.send(ctx, Msg(Script_Open_File{file = path, line = 1}))
	}
	// A double-click on a component opens it; on an LDtk project, it opens in LDtk
	if ctx.input.mouse_pressed[.Left] && onRow && ctx.input.mouse_click_count[.Left] >= 2 && items[row].kind == .Asset && items[row].index < len(s.project.assets) {
		#partial switch asset := s.project.assets[items[row].index]; asset.kind {
		case .Component:
			if i := Project_FindComponent(&s.project, asset.path); i >= 0 do skald.send(ctx, Msg(Component_Opened(i)))
		case .LDtk:
			skald.send(ctx, Msg(LDtk_Asset_Open_Requested(items[row].index)))
		}
	}
}

/*
The text field for renaming a scene in place: an overlay over its row. Enter or clicking elsewhere
keeps the name (if it's valid), Escape cancels.
*/
@(private="file")
browserRename :: proc(s: ^State, ctx: ^skald.Ctx(Msg), items: []BrowserItem) -> skald.View {
	th := ctx.theme
	none := skald.View(skald.View_Spacer{size = 0})
	if !s.rename.active || s.rename.target == .Node do return none
	// A scene's row, or a component's (an asset row)
	component := s.rename.target == .Component
	row := -1
	for item, i in items {
		if component ? (item.kind == .Asset && item.index == s.rename.node) : (item.kind == .Scene && item.index == s.rename.node) do row = i
	}
	treeState, drawn := ctx.widgets.states[skald.hash_id("browser-tree")]
	if row < 0 || !drawn {
		skald.send(ctx, Msg(Rename_Cancelled{}))
		return none
	}
	id := skald.hash_id("browser-rename")
	skald.shortcut(ctx, {.Enter, {}}, Msg(Rename_Committed{byKey = true}))
	skald.shortcut(ctx, {.Escape, {}}, Msg(Rename_Cancelled{}))
	if !s.rename.focused {
		skald.widget_focus(ctx, id)
		skald.send(ctx, Msg(Rename_Focused{}))
	} else if !skald.widget_has_focus(ctx, id) {
		skald.send(ctx, Msg(Rename_Committed{}))
	}
	tree := treeState.last_rect
	rowHeight := s.settings.rowHeight
	// After the indent (depth 1), the chevron space and the icon, as coloredTree lays rows out
	x := tree.x + th.spacing.sm + th.spacing.lg + 16 + th.font.size_md + th.spacing.xs
	y := tree.y + f32(row) * rowHeight
	area := treeState.clip_rect.w > 0 ? treeState.clip_rect : tree
	if y < area.y || y + rowHeight > area.y + area.h {
		// Scrolled out of view (the browser was scrolled away from it): bring the
		// row back, so the field can be shown and focused next frame
		scroll := &ctx.widgets.states[skald.hash_id("browser-scroll")]
		scroll.scroll_y = max(scroll.scroll_y + (y + rowHeight * 0.5) - (area.y + area.h * 0.5), 0)
		skald.send(ctx, Msg(Frame_Requested{}))
		return none
	}
	problem := component ? ComponentNameProblem(&s.project, s.rename.node, s.rename.text) : SceneNameProblem(&s.project, strings.trim_space(s.rename.text), s.rename.node)
	return skald.overlay({x, y, 0, 0},
		skald.text_input(ctx, s.rename.text,
			proc(v: string) -> Msg { return Rename_Text_Changed(v) },
			id = id, width = max(tree.x + tree.w - x - th.spacing.xs, 80), height = rowHeight, font_size = th.font.size_sm,
			invalid = problem != "", error = problem),
		no_shadow = true, pin = true)
}

/*
Dragging an image from the browser into the viewport (which adds a Sprite there): a press on an
image row, then moving the mouse, starts it; releasing over the viewport drops it. Returns the
label that follows the cursor while dragging (an overlay; empty otherwise).
*/
@(private="file")
browserDrag :: proc(s: ^State, ctx: ^skald.Ctx(Msg), items: []BrowserItem) -> skald.View {
	th := ctx.theme
	none := skald.View(skald.View_Spacer{size = 0})
	treeState, drawn := ctx.widgets.states[skald.hash_id("browser-tree")]
	areaState, _ := ctx.widgets.states[skald.hash_id("browser-scroll")]
	if !drawn do return none
	mouse := ctx.input.mouse_pos
	area := areaState.last_rect
	overArea := mouse.x >= area.x && mouse.x < area.x + area.w && mouse.y >= area.y && mouse.y < area.y + area.h
	row := int(math.floor((mouse.y - treeState.last_rect.y) / s.settings.rowHeight))

	if ctx.input.mouse_pressed[.Left] && overArea && !skald.mouse_over_overlay(ctx) && row >= 0 && row < len(items) {
		item := items[row]
		if item.kind == .Asset && (s.project.assets[item.index].kind == .Image || s.project.assets[item.index].kind == .Component) {
			skald.send(ctx, Msg(Asset_Drag_Pressed{asset = item.index, start = mouse}))
		}
		return none
	}
	if !s.assetDrag.pressed do return none
	if !ctx.input.mouse_buttons[.Left] {
		world, overViewport := ViewportWorldAt(s, ctx, mouse)
		if s.assetDrag.active && overViewport {
			skald.send(ctx, Msg(Asset_Dropped{world = world}))
		} else {
			skald.send(ctx, Msg(Asset_Drag_Cancelled{}))
		}
		return none
	}
	if !s.assetDrag.active {
		d := mouse - s.assetDrag.start
		if d.x * d.x + d.y * d.y >= ASSET_DRAG_THRESHOLD * ASSET_DRAG_THRESHOLD {
			skald.send(ctx, Msg(Asset_Drag_Started{}))
		}
		return none
	}
	if s.assetDrag.asset >= len(s.project.assets) do return none
	label := fmt.tprintf("%s  %s", ICON_IMAGE, filepath.base(s.project.assets[s.assetDrag.asset].path))
	_, overViewport := ViewportWorldAt(s, ctx, mouse)
	hint := overViewport ? "drop to add a Sprite" : "drag into the viewport"
	return skald.overlay({mouse.x + 14, mouse.y + 10, 0, 0},
		skald.col(
			skald.text(label, th.color.fg, th.font.size_sm),
			skald.text(hint, th.color.fg_muted, th.font.size_xs),
			padding = th.spacing.sm,
			bg = th.color.elevated,
			radius = th.radius.sm,
		),
		pin = true)
}

// How far the mouse moves with the button down before a press on an image becomes a drag
ASSET_DRAG_THRESHOLD :: 5

// How wide preview text may be: the browser's width less padding, measured each frame (the
// browser body's `sized`); previews wrap their text to it
@(private)
previewTextWidth: f32 = 240

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
	if s.browserSelection.kind == .Script && s.browserSelection.index < len(s.scriptFiles) {
		content = scriptInfoPreview(s, ctx, s.scriptFiles[s.browserSelection.index])
	} else if s.browserSelection.kind == .Scene && s.browserSelection.index >= 0 && s.browserSelection.index < len(s.project.scenes) {
		content = scenePreview(s, ctx, s.browserSelection.index)
	} else if s.browserSelection.kind != .Asset || s.browserSelection.index >= len(s.project.assets) {
		content = skald.text("Select a scene, image, sound or script to preview it.", th.color.fg_muted, th.font.size_sm, max_width = previewTextWidth)
	} else {
		asset := s.project.assets[s.browserSelection.index]
		path := AssetFilePath(&s.project, asset)
		switch asset.kind {
		case .Image: content = imagePreview(s, ctx, asset, path)
		case .Audio, .Music: content = audioPreview(s, ctx, asset, path)
		case .Font:
			content = skald.col(
				skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm, max_width = previewTextWidth),
				skald.text(fileInfo(path, ""), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth),
				skald.text("Font previews aren't supported yet.", th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth),
				spacing = th.spacing.xs,
			)
		case .Component:
			content = componentPreview(s, ctx, asset)
		case .LDtk:
			content = ldtkPreview(s, ctx, asset, path)
		case .Translation:
			content = translationPreview(ctx, asset, path)
		case .Data:
			i := Project_FindData(&s.project, asset.path)
			type := i >= 0 ? s.project.data[i].type : "?"
			content = skald.col(
				skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm, max_width = previewTextWidth),
				skald.text(fmt.tprintf("%s data resource; edit it in the inspector", type), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth),
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
		return skald.text(fmt.tprintf("%s is missing from the project folder.", asset.path), th.color.danger, th.font.size_sm, max_width = previewTextWidth)
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
		skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm, max_width = previewTextWidth),
		skald.text(fileInfo(path, dimensions), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth),
		spacing = th.spacing.xs,
		cross_align = .Stretch,
	)
}

// The image of the component's last thumbnail upload, and its key (so it uploads only on changes)
@(private="file")
COMPONENT_THUMBNAIL :: "component-thumbnail"
@(private="file")
thumbnailKey: u64
@(private="file")
thumbnailSize: [2]int

/*
A component: a picture of it (drawn by the engine, like the viewport), how many nodes it has and
how many instances use it, and Open and Add to Scene.
*/
@(private="file")
componentPreview :: proc(s: ^State, ctx: ^skald.Ctx(Msg), asset: AssetDef) -> skald.View {
	th := ctx.theme
	index := Project_FindComponent(&s.project, asset.path)
	if index < 0 do return skald.text(fmt.tprintf("%s couldn't be read.", asset.path), th.color.danger, th.font.size_sm, max_width = previewTextWidth)
	Data :: struct { s: ^State, index: int }
	data := new_clone(Data{s, index}, context.temp_allocator)
	picture := skald.sized(ctx, data, proc(ctx: ^skald.Ctx(Msg), data: ^Data, size: [2]f32) -> skald.View {
		previewImageArea = size
		pixelSize := [2]int{max(int(size.x), 1), max(int(size.y), 1)}
		pixels, key, ok := Preview_RenderComponent(data.s, data.index, pixelSize)
		if ok && ctx.renderer != nil && (key != thumbnailKey || pixelSize != thumbnailSize) {
			if pixelSize == thumbnailSize do skald.image_update_pixels(ctx.renderer, COMPONENT_THUMBNAIL, u32(pixelSize.x), u32(pixelSize.y), pixels)
			else do skald.image_load_pixels(ctx.renderer, COMPONENT_THUMBNAIL, u32(pixelSize.x), u32(pixelSize.y), pixels)
			thumbnailKey, thumbnailSize = key, pixelSize
		}
		return skald.canvas(ctx, data, proc(d: ^Data, p: skald.Canvas_Painter) {
			skald.draw_image(p.r, COMPONENT_THUMBNAIL, p.bounds, .Fill)
		}, width = max(size.x, 1), height = max(size.y, 1))
	})
	component := &s.project.scenes[index]
	instances := Component_InstanceCount(&s.project, asset.path)
	root := len(component.nodes) > 0 ? fmt.tprintf("%v", component.nodes[0].kind) : "empty"
	button :: proc(ctx: ^skald.Ctx(Msg), key, label: string, msg: Msg) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	return skald.col(
		skald.flex(1, picture),
		skald.text(fmt.tprintf("%s  %s", ICON_CUBES, component.name), th.color.fg, th.font.size_sm, max_width = previewTextWidth),
		skald.text(fmt.tprintf("%d node%s (%s root) · %d instance%s", len(component.nodes), len(component.nodes) == 1 ? "" : "s", root,
			instances, instances == 1 ? "" : "s"), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth),
		skald.row(
			button(ctx, "component-open", fmt.tprintf("%s  Edit", ICON_CUBES), Msg(Component_Opened(index))),
			button(ctx, "component-add", fmt.tprintf("%s  Add to Scene", ICON_PLUS), Msg(Component_Instance_Added(s.browserSelection.index))),
			spacing = th.spacing.xs,
		),
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
			skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm, max_width = previewTextWidth),
			skald.text("Couldn't load this sound (see the Console).", th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth),
			spacing = th.spacing.xs,
		)
	}

	fraction := duration > 0 ? f32(position) / f32(duration) : 0
	Bar :: struct { fraction: f32, color, track: skald.Color }
	bar := Bar{fraction, th.color.primary, th.color.surface}
	return skald.col(
		skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm, max_width = previewTextWidth),
		skald.row(
			skald.button(ctx, playing ? fmt.tprintf("%s  Stop", ICON_STOP) : fmt.tprintf("%s  Play", ICON_PLAY),
				Msg(playing ? Action.Stop_Audio_Preview : Action.Play_Audio_Preview),
				id = skald.hash_id("preview-play"), width = 90),
			skald.text(fmt.tprintf("%s / %s", FormatDuration(position), FormatDuration(duration)), th.color.fg_muted, th.font.size_sm, max_width = previewTextWidth),
			spacing = th.spacing.sm,
			cross_align = .Center,
		),
		skald.canvas(ctx, new_clone(bar, context.temp_allocator), proc(bar: ^Bar, p: skald.Canvas_Painter) {
			skald.draw_rect(p.r, p.bounds, bar.track, 3)
			skald.draw_rect(p.r, {p.bounds.x, p.bounds.y, p.bounds.w * clamp(bar.fraction, 0, 1), p.bounds.h}, bar.color, 3)
		}, height = 6),
		skald.text(fileInfo(path, ""), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth),
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
	case .Audio: return ICON_VOLUME
	case .Music: return ICON_MUSIC
	case .Font:  return ICON_FONT_GLYPH
	case .Data:  return ICON_DATABASE
	case .Component: return ICON_CUBES
	case .LDtk:  return ICON_MAP
	case .Translation: return ICON_GLOBE
	}
	return ICON_FILE
}

// A translation table: its languages, how many keys, the first few in the first language
@(private="file")
translationPreview :: proc(ctx: ^skald.Ctx(Msg), asset: AssetDef, path: string) -> skald.View {
	th := ctx.theme
	lines := make([dynamic]skald.View, context.temp_allocator)
	append(&lines, skald.text(filepath.base(asset.path), th.color.fg, th.font.size_sm, max_width = previewTextWidth))
	data, err := os.read_entire_file(path, context.temp_allocator)
	// Parsed by the engine, as the game will (a scratch game's tables, freed below)
	game: e.Game
	defer if game.arenaReady do e.MemoryArena_Destroy(&game.arena)
	ok := false
	if err == nil {
		context.logger = log.nil_logger()
		ok = e.Locale_LoadCSV(&game, string(data), asset.path)
	}
	if !ok {
		append(&lines, skald.text("Not a translation table: the first row must be key,<language>,<language>...", th.color.danger, th.font.size_xs, max_width = previewTextWidth))
	} else {
		locales := e.Locale_List(&game)
		append(&lines, skald.text(fmt.tprintf("%d keys in %s", len(game.localization.texts), strings.join(locales, ", ", context.temp_allocator)), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
		append(&lines, skald.text("Labels and menu items show a key's text when theirs is @key; scripts call e.Tr(key).", th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
		shown := 0
		for key, values in game.localization.texts {
			if shown == 12 do break
			first := len(values) > 0 ? values[0] : ""
			append(&lines, skald.text(fmt.tprintf("%s: %s", key, first), th.color.fg_muted, th.font.size_xs, max_width = previewTextWidth))
			shown += 1
		}
	}
	return skald.col(..lines[:], spacing = th.spacing.xs)
}
