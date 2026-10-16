package editor

import "core:fmt"
import "core:path/filepath"
import "gui:skald"

/*
Draws the whole editor window from the state. Called every frame.
*/
view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	ensureIconFont(ctx)
	th := ctx.theme
	state := s
	ScriptDriver_Frame(&state, ctx)
	// Before anything else registers shortcuts (see keymap.odin)
	KeymapDispatch(ctx, ViewportHovered(ctx))

	return skald.col(
		menuBarView(ctx),
		toolbarView(&state, ctx),
		skald.divider(ctx),
		// The workspace needs its own size to place the panels, so it's built once layout knows it
		skald.flex(1, skald.sized(ctx, &state, workspaceView)),
		skald.divider(ctx),
		statusBarView(&state, ctx),
		removeAssetDialog(&state, ctx),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

// Menu items take their shortcut hints from the keymap. The keymap already dispatched them this
// frame, so the menu bar's own registration finds the key consumed and doesn't fire twice
@(private="file")
menuBarView :: proc(ctx: ^skald.Ctx(Msg)) -> skald.View {
	typing := IsTyping(ctx)
	item :: proc(label: string, action: Action, typing: bool) -> skald.Menu_Item(Msg) {
		return {label = label, shortcut = Keymap_Shortcut(action, typing), msg = action}
	}
	return skald.menu_bar(ctx, []skald.Menu_Entry(Msg){
		{"File", []skald.Menu_Item(Msg){
			item("New Project", .New_Project, typing),
			item("Open Project", .Open_Project, typing),
			item("Save", .Save_Project, typing),
			{separator = true},
			item("Import Asset...", .Import_Asset, typing),
			{separator = true},
			item("Export...", .Export, typing),
			{separator = true},
			item("Quit", .Quit, typing),
		}},
		{"Edit", []skald.Menu_Item(Msg){
			item("Undo", .Undo, typing),
			item("Redo", .Redo, typing),
			{separator = true},
			item("Add Node", .Add_Node, typing),
			item("Delete Node", .Delete_Node, typing),
			item("Deselect", .Deselect, typing),
		}},
		{"View", []skald.Menu_Item(Msg){
			item("Select Tool", .Tool_Select, typing),
			item("Move Tool", .Tool_Move, typing),
			item("Rotate Tool", .Tool_Rotate, typing),
			item("Scale Tool", .Tool_Scale, typing),
			{separator = true},
			item("Frame Selected", .Frame_Selected, typing),
			item("Fit Game Area", .View_Fit, typing),
			item("Zoom In", .Zoom_In, typing),
			item("Zoom Out", .Zoom_Out, typing),
			item("Zoom to 100%", .Zoom_100, typing),
			item("Play/Pause Animations", .Toggle_Animation, typing),
			{separator = true},
			item("Toggle Bottom Panel", .Toggle_Bottom_Panel, typing),
			item("Clear Console", .Clear_Console, typing),
		}},
		{"Scene", []skald.Menu_Item(Msg){
			item("Play", .Play, typing),
			item("Pause", .Pause, typing),
			item("Stop", .Stop, typing),
		}},
		{"Help", []skald.Menu_Item(Msg){
			{label = "Keyboard Shortcuts", msg = Bottom_Tab_Changed(int(BottomTab.Keys))},
			item("About", .About, typing),
		}},
	})
}

@(private="file")
toolbarView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	running := s.playState == .Playing || s.playState == .Building
	playTip := "Play (F5)"
	switch s.playState {
	case .Building: playTip = "Building the player..."
	case .Paused:   playTip = "Resume (F5)"
	case .Playing, .Stopped:
	}
	return skald.row(
		toolButton(ctx, "new", ICON_FILE, "New project (Ctrl+N)", Action.New_Project),
		toolButton(ctx, "open", ICON_FOLDER_OPEN, "Open project (Ctrl+O)", Action.Open_Project),
		toolButton(ctx, "save", ICON_SAVE, "Save (Ctrl+S)", Action.Save_Project),
		toolbarSeparator(ctx),
		toolButton(ctx, "undo", ICON_UNDO, "Undo (Ctrl+Z)", Action.Undo),
		toolButton(ctx, "redo", ICON_REDO, "Redo (Ctrl+Shift+Z)", Action.Redo),
		toolbarSeparator(ctx),
		toolButton(ctx, "select", ICON_POINTER, "Select (Q)", Action.Tool_Select, active = s.tool == .Select),
		toolButton(ctx, "move", ICON_MOVE, "Move (W)", Action.Tool_Move, active = s.tool == .Move),
		toolButton(ctx, "rotate", ICON_ROTATE, "Rotate (E)", Action.Tool_Rotate, active = s.tool == .Rotate),
		toolButton(ctx, "scale", ICON_SCALE, "Scale (R)", Action.Tool_Scale, active = s.tool == .Scale),

		// Play controls sit in the middle of the toolbar
		skald.flex(1, skald.spacer(0)),
		toolButton(ctx, "play", ICON_PLAY, playTip, Action.Play, active = running),
		toolButton(ctx, "pause", ICON_PAUSE, "Pause (F6)", Action.Pause, active = s.playState == .Paused, disabled = s.playState != .Playing),
		toolButton(ctx, "stop", ICON_STOP, "Stop (Shift+F5)", Action.Stop, disabled = s.playState == .Stopped),
		skald.flex(1, skald.spacer(0)),

		toolButton(ctx, "export", ICON_EXPORT, "Export (Ctrl+Shift+E)", Action.Export),
		spacing = th.spacing.xs,
		padding = th.spacing.sm,
		cross_align = .Center,
		bg = th.color.surface,
	)
}

// Icon button with a tooltip. Its widget id is hash_id("toolbar-<key>"): buttons made by a
// shared helper all have the same call site, which would otherwise make them share widget
// state. The key is also how test scripts click it (`click_widget toolbar-play`)
@(private="file")
toolButton :: proc(ctx: ^skald.Ctx(Msg), key, icon, tip: string, msg: Msg, active := false, disabled := false) -> skald.View {
	th := ctx.theme
	bg := active ? th.color.primary : th.color.surface
	fg := active ? th.color.on_primary : th.color.fg
	button := skald.button(ctx, icon, msg,
		id = skald.hash_id(fmt.tprintf("toolbar-%s", key)),
		bg = bg, fg = fg, width = 34, padding = {0, 6}, disabled = disabled)
	return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("toolbar-tip-%s", key)))
}

@(private="file")
toolbarSeparator :: proc(ctx: ^skald.Ctx(Msg)) -> skald.View {
	return skald.row(skald.divider(ctx, vertical = true), height = 22, padding = ctx.theme.spacing.xs)
}

/*
The resizable panels. Built by `sized`, so it knows the space it has: the left sidebar and the
bottom panel are stored as their own sizes and the viewport gets what is left.
*/
@(private="file")
workspaceView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	// update needs the workspace size to turn divider drags into sidebar sizes
	if size != s.layout.workspace {
		skald.send(ctx, Workspace_Measured(size))
	}

	// Use this frame's size even if update hasn't stored it yet
	layout := s.layout
	layout.workspace = size
	left, right := FittedSidebarWidths(&layout)
	centerWidth := max(size.x - left - right - DIVIDER * 2, MIN_CENTER_WIDTH)

	centerAndRight := skald.split(ctx,
		first = centerView(s, ctx, &layout),
		second = rightSidebarView(s, ctx),
		first_size = centerWidth,
		on_resize = proc(v: f32) -> Msg { return Center_Resized(v) },
		id = skald.hash_id("split-center-right"),
		min_first = MIN_CENTER_WIDTH,
		min_second = MIN_SIDEBAR_WIDTH,
	)
	return skald.split(ctx,
		first = browserView(s, ctx),
		second = centerAndRight,
		first_size = left,
		on_resize = proc(v: f32) -> Msg { return Left_Resized(v) },
		id = skald.hash_id("split-left"),
		min_first = MIN_SIDEBAR_WIDTH,
		min_second = MIN_CENTER_WIDTH + MIN_SIDEBAR_WIDTH + DIVIDER,
	)
}

// Viewport above, bottom panel below (or just its header when collapsed)
@(private="file")
centerView :: proc(s: ^State, ctx: ^skald.Ctx(Msg), layout: ^Layout) -> skald.View {
	viewport := viewportView(s, ctx)
	if !s.layout.bottomOpen {
		return skald.col(
			skald.flex(1, viewport),
			bottomPanelView(s, ctx),
			cross_align = .Stretch,
		)
	}
	viewportHeight := max(layout.workspace.y - FittedBottomHeight(layout) - DIVIDER, MIN_VIEWPORT_HEIGHT)
	return skald.split(ctx,
		first = viewport,
		second = bottomPanelView(s, ctx),
		first_size = viewportHeight,
		on_resize = proc(v: f32) -> Msg { return Viewport_Resized(v) },
		id = skald.hash_id("split-viewport-bottom"),
		direction = .Column,
		min_first = MIN_VIEWPORT_HEIGHT,
		min_second = MIN_BOTTOM_HEIGHT,
	)
}

@(private="file")
statusBarView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	scene := &s.project.scenes[s.currentScene]
	selection := "nothing selected"
	if s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) {
		selection = fmt.tprintf("%s (%v)", scene.nodes[s.selectedNode].name, scene.nodes[s.selectedNode].kind)
	}
	return skald.row(
		statusText(ctx, fmt.tprintf("%s  %s", ICON_SITEMAP, s.project.name)),
		statusText(ctx, fmt.tprintf("Scene: %s", scene.name)),
		statusText(ctx, fmt.tprintf("%d nodes", len(scene.nodes))),
		statusText(ctx, fmt.tprintf("Selection: %s", selection)),
		skald.flex(1, skald.spacer(0)),
		statusText(ctx, fmt.tprintf("Tool: %v", s.tool)),
		statusText(ctx, fmt.tprintf("%v", s.playState)),
		statusText(ctx, fmt.tprintf("%.0fx%.0f", s.project.gameSize.x, s.project.gameSize.y)),
		spacing = th.spacing.lg,
		padding = th.spacing.xs,
		cross_align = .Center,
		bg = th.color.surface,
	)
}

@(private="file")
statusText :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
	return skald.text(text, ctx.theme.color.fg_muted, ctx.theme.font.size_sm)
}

/*
Header strip at the top of a panel: an icon and title, plus optional action buttons on the right.
*/
panelHeader :: proc(ctx: ^skald.Ctx(Msg), icon, title: string, actions: ..skald.View) -> skald.View {
	th := ctx.theme
	children := make([dynamic]skald.View, context.temp_allocator)
	append(&children, skald.text(fmt.tprintf("%s  %s", icon, title), th.color.fg, th.font.size_sm))
	append(&children, skald.flex(1, skald.spacer(0)))
	append(&children, ..actions)
	return skald.row(..children[:],
		spacing = th.spacing.xs,
		padding = th.spacing.sm,
		cross_align = .Center,
		bg = th.color.surface,
	)
}

/*
Small icon button for panel headers. `key` must be unique among panel buttons.
*/
panelButton :: proc(ctx: ^skald.Ctx(Msg), key, icon, tip: string, msg: Msg, disabled := false) -> skald.View {
	th := ctx.theme
	button := skald.button(ctx, icon, msg,
		id = skald.hash_id(fmt.tprintf("panel-%s", key)),
		bg = th.color.surface, fg = th.color.fg_muted,
		width = 26, padding = {0, 3}, font_size = th.font.size_sm, disabled = disabled)
	return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("panel-tip-%s", key)))
}

// Confirmation before removing an asset: remove it from the project, or also delete its file
@(private="file")
removeAssetDialog :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	name, usage := "", 0
	if index := s.removeConfirm.asset; s.removeConfirm.open && index >= 0 && index < len(s.project.assets) {
		name = filepath.base(s.project.assets[index].path)
		usage = AssetUsage(&s.project, s.project.assets[index].path)
	}
	usageText := "No nodes use it."
	if usage > 0 {
		usageText = fmt.tprintf("%d node%s use%s it and will draw nothing until changed.", usage, usage == 1 ? "" : "s", usage == 1 ? "s" : "")
	}
	return skald.dialog(ctx,
		open = s.removeConfirm.open,
		on_dismiss = proc() -> Msg { return Asset_Remove_Cancelled{} },
		content = skald.col(
			skald.text(fmt.tprintf("Remove %s?", name), th.color.fg, th.font.size_lg),
			skald.text(usageText, th.color.fg_muted, th.font.size_sm),
			skald.text("Deleting the file can't be undone.", th.color.fg_muted, th.font.size_sm),
			skald.spacer(th.spacing.sm),
			skald.row(
				skald.button(ctx, "Cancel", Msg(Asset_Remove_Cancelled{}), id = skald.hash_id("dialog-cancel")),
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Delete File", Msg(Asset_Remove_Confirmed{deleteFile = true}),
					id = skald.hash_id("dialog-delete-file"), bg = th.color.danger, fg = th.color.on_primary),
				skald.button(ctx, "Remove from Project", Msg(Asset_Remove_Confirmed{deleteFile = false}),
					id = skald.hash_id("dialog-remove"), bg = th.color.primary, fg = th.color.on_primary),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.xs,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("remove-asset-dialog"),
	)
}
