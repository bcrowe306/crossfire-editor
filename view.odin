package editor

import "core:fmt"
import "core:time"
import "core:math"
import "core:path/filepath"
import "gui:skald"

/*
Draws the whole editor window from the state. Called every frame.
*/
view :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	FrameStats_Begin()
	ensureIconFont(ctx)
	th := ctx.theme
	state := s
	ScriptDriver_Frame(&state, ctx)
	// Before anything else registers shortcuts (see keymap.odin)
	// Dialogs and the open context menu take Escape (and every other key) themselves
	menu, drawn := ctx.widgets.states[skald.hash_id("scene-tree-menu")]
	browserMenu, browserMenuDrawn := ctx.widgets.states[skald.hash_id("browser-menu")]
	keysTaken := state.addNode.open || state.removeConfirm.open || state.settingsDialog.open ||
		state.session.confirm.open || state.session.newProject.open || state.newScript.open || state.newData.open || state.projectSettings.open ||
		(drawn && menu.open) || (browserMenuDrawn && browserMenu.open)
	// A project with scripts is built once in the background when it opens, so the inspector
	// knows their fields
	if len(state.scriptFiles) > 0 && !state.scriptsAutoBuilt && state.play.stage == .None {
		skald.send(ctx, Msg(Scripts_Auto_Build{}))
	}
	Session_UpdateTitle(&state)
	KeymapDispatch(ctx, &state.settings.keymap, ViewportHovered(ctx), dialogOpen = keysTaken)

	return skald.col(
		menuBarView(&state, ctx, keysTaken),
		toolbarView(&state, ctx),
		skald.divider(ctx),
		// The workspace needs its own size to place the panels, so it's built once layout knows it
		skald.flex(1, skald.sized(ctx, &state, workspaceView)),
		skald.divider(ctx),
		statusBarView(&state, ctx),
		removeAssetDialog(&state, ctx),
		addNodeDialog(&state, ctx),
		settingsDialogView(&state, ctx),
		newProjectDialogView(&state, ctx),
		newScriptDialogView(&state, ctx),
		newDataDialogView(&state, ctx),
		projectSettingsDialogView(&state, ctx),
		confirmDialogView(&state, ctx),
		cross_align = .Stretch,
		bg = th.color.bg,
	)
}

// Menu items take their shortcut hints from the keymap. The keymap already dispatched them this
// frame, so the menu bar's own registration finds the key consumed and doesn't fire twice.
// `keysTaken` (a dialog or context menu is open) drops the shortcuts, since the menu bar would
// otherwise fire them itself (Escape would deselect instead of closing the dialog)
@(private="file")
menuBarView :: proc(s: ^State, ctx: ^skald.Ctx(Msg), keysTaken: bool) -> skald.View {
	Keys :: struct { keymap: ^Keymap, typing, taken: bool }
	keys := Keys{&s.settings.keymap, IsTyping(ctx), keysTaken}
	item :: proc(label: string, action: Action, keys: Keys) -> skald.Menu_Item(Msg) {
		if keys.taken do return {label = label, msg = action}
		return {label = label, shortcut = Keymap_Shortcut(keys.keymap, action, keys.typing), msg = action}
	}
	// "Undo Rename Spaceship"
	undoLabel := History_NextLabel(&s.history, false)
	redoLabel := History_NextLabel(&s.history, true)
	return skald.menu_bar(ctx, []skald.Menu_Entry(Msg){
		{"File", []skald.Menu_Item(Msg){
			item("New Project", .New_Project, keys),
			item("Open Project", .Open_Project, keys),
			item("Save", .Save_Project, keys),
			{separator = true},
			item("Import Asset...", .Import_Asset, keys),
			item("Project Settings...", .Open_Project_Settings, keys),
			{separator = true},
			item("Export...", .Export, keys),
			{separator = true},
			item("Quit", .Quit, keys),
		}},
		{"Edit", []skald.Menu_Item(Msg){
			item(undoLabel == "" ? "Undo" : fmt.tprintf("Undo %s", undoLabel), .Undo, keys),
			item(redoLabel == "" ? "Redo" : fmt.tprintf("Redo %s", redoLabel), .Redo, keys),
			{separator = true},
			item("Add Node...", .Add_Node, keys),
			item("Duplicate Node", .Duplicate_Node, keys),
			item("Copy Node", .Copy_Node, keys),
			item("Cut Node", .Cut_Node, keys),
			item("Paste Node", .Paste_Node, keys),
			item("Rename Node", .Rename_Node, keys),
			item("Delete Node", .Delete_Node, keys),
			item("Deselect", .Deselect, keys),
			{separator = true},
			item("Settings...", .Open_Settings, keys),
		}},
		{"Scripts", []skald.Menu_Item(Msg){
			{label = "New Script...", msg = Msg(New_Script_Opened{})},
			item("Open Script", .Open_Script, keys),
			item("Build Scripts", .Build_Scripts, keys),
		}},
		{"View", []skald.Menu_Item(Msg){
			item("Select Tool", .Tool_Select, keys),
			item("Move Tool", .Tool_Move, keys),
			item("Rotate Tool", .Tool_Rotate, keys),
			item("Scale Tool", .Tool_Scale, keys),
			{separator = true},
			item("Frame Selected", .Frame_Selected, keys),
			item("Fit Game Area", .View_Fit, keys),
			item("Zoom In", .Zoom_In, keys),
			item("Zoom Out", .Zoom_Out, keys),
			item("Zoom to 100%", .Zoom_100, keys),
			item("Play/Pause Animations", .Toggle_Animation, keys),
			{separator = true},
			item("Toggle Bottom Panel", .Toggle_Bottom_Panel, keys),
			item("Clear Console", .Clear_Console, keys),
		}},
		{"Scene", []skald.Menu_Item(Msg){
			item("Play", .Play, keys),
			item("Play This Scene", .Play_Scene, keys),
			{label = "Show Collision Shapes in Game", msg = Msg(Action.Toggle_Physics_Debug),
			 shortcut = keys.taken ? {} : Keymap_Shortcut(keys.keymap, .Toggle_Physics_Debug, keys.typing),
			 checked = s.project.physics.debugDraw},
			{label = "New Scene", msg = Msg(Scene_Action{.New, -1})},
			item("Pause", .Pause, keys),
			item("Stop", .Stop, keys),
		}},
		{"Help", []skald.Menu_Item(Msg){
			{label = "Keyboard Shortcuts", msg = Msg(Open_Keyboard_Settings{})},
			item("About", .About, keys),
		}},
	})
}

@(private="file")
toolbarView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	running := s.playState == .Playing || s.playState == .Building
	playTip := actionTip(s, "Play", .Play)
	switch s.playState {
	case .Building: playTip = "Building the player..."
	case .Paused:   playTip = actionTip(s, "Resume", .Play)
	case .Playing, .Stopped:
	}
	return skald.row(
		toolButton(ctx, "new", ICON_FILE, actionTip(s, "New project", .New_Project), Action.New_Project),
		toolButton(ctx, "open", ICON_FOLDER_OPEN, actionTip(s, "Open project", .Open_Project), Action.Open_Project),
		toolButton(ctx, "save", ICON_SAVE, actionTip(s, "Save", .Save_Project), Action.Save_Project),
		toolbarSeparator(ctx),
		toolButton(ctx, "undo", ICON_UNDO, actionTip(s, "Undo", .Undo), Action.Undo),
		toolButton(ctx, "redo", ICON_REDO, actionTip(s, "Redo", .Redo), Action.Redo),
		toolbarSeparator(ctx),
		toolButton(ctx, "select", ICON_POINTER, actionTip(s, "Select", .Tool_Select), Action.Tool_Select, active = s.tool == .Select),
		toolButton(ctx, "move", ICON_MOVE, actionTip(s, "Move", .Tool_Move), Action.Tool_Move, active = s.tool == .Move),
		toolButton(ctx, "rotate", ICON_ROTATE, actionTip(s, "Rotate", .Tool_Rotate), Action.Tool_Rotate, active = s.tool == .Rotate),
		toolButton(ctx, "scale", ICON_SCALE, actionTip(s, "Scale", .Tool_Scale), Action.Tool_Scale, active = s.tool == .Scale),

		// Play controls sit in the middle of the toolbar
		skald.flex(1, skald.spacer(0)),
		toolButton(ctx, "play", ICON_PLAY, playTip, Action.Play, active = running),
		toolButton(ctx, "play-scene", ICON_PLAY_SCENE, actionTip(s, fmt.tprintf("Play %s (this scene)", s.project.scenes[s.currentScene].name), .Play_Scene), Action.Play_Scene, disabled = running),
		toolButton(ctx, "pause", ICON_PAUSE, actionTip(s, "Pause", .Pause), Action.Pause, active = s.playState == .Paused, disabled = s.playState != .Playing),
		toolButton(ctx, "stop", ICON_STOP, actionTip(s, "Stop", .Stop), Action.Stop, disabled = s.playState == .Stopped),
		skald.flex(1, skald.spacer(0)),

		toolButton(ctx, "export", ICON_EXPORT, actionTip(s, "Export", .Export), Action.Export),
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
		bg = bg, fg = fg, width = math.round(th.font.size_md * 2.4), padding = {0, th.spacing.xs + 2}, disabled = disabled)
	return skald.tooltip(ctx, button, tip, id = skald.hash_id(fmt.tprintf("toolbar-tip-%s", key)))
}

@(private="file")
toolbarSeparator :: proc(ctx: ^skald.Ctx(Msg)) -> skald.View {
	return skald.row(skald.divider(ctx, vertical = true), height = math.round(ctx.theme.font.size_md * 1.6), padding = ctx.theme.spacing.xs)
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
		Project_IsModified(s) ? skald.text("Modified", th.color.warning, th.font.size_sm) : skald.text("Saved", th.color.fg_muted, th.font.size_sm),
		statusText(ctx, fmt.tprintf("Scene: %s", scene.name)),
		statusText(ctx, fmt.tprintf("%d nodes", len(scene.nodes))),
		statusText(ctx, fmt.tprintf("Selection: %s", selection)),
		skald.flex(1, skald.spacer(0)),
		statusText(ctx, FrameStats_Text()),
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
A tooltip naming an action and its shortcut from the keymap: "Undo (Ctrl+Z)", or just "Undo"
when it has none.
*/
actionTip :: proc(s: ^State, label: string, action: Action) -> string {
	chord := Keymap_Shortcut(&s.settings.keymap, action)
	if chord == {} do return label
	return fmt.tprintf("%s (%s)", label, skald.shortcut_format(chord))
}

/*
Small icon button for panel headers. `key` must be unique among panel buttons.
*/
panelButton :: proc(ctx: ^skald.Ctx(Msg), key, icon, tip: string, msg: Msg, disabled := false) -> skald.View {
	th := ctx.theme
	button := skald.button(ctx, icon, msg,
		id = skald.hash_id(fmt.tprintf("panel-%s", key)),
		bg = th.color.surface, fg = th.color.fg_muted,
		width = math.round(th.font.size_md * 1.9), padding = {0, 3}, font_size = th.font.size_sm, disabled = disabled)
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

/*
Frame statistics for the status bar, so slowdowns are visible: frames drawn in the last second,
and what the last viewport render cost (the engine's software render plus the upload to Skald).
The editor only draws when something changes, so while idle these show the last busy moment.
*/
FrameStats :: struct {
	// Start of the current one-second window, and frames drawn in it
	windowStart: time.Tick,
	frames: int,
	// Frames drawn in the last full second
	fps: int,
	// The last viewport render and upload, in milliseconds
	viewportMs: f64,
}

frameStats: FrameStats

// Counts a frame. Called at the start of `view`
FrameStats_Begin :: proc() {
	now := time.tick_now()
	if frameStats.windowStart == {} do frameStats.windowStart = now
	frameStats.frames += 1
	if time.tick_diff(frameStats.windowStart, now) >= time.Second {
		frameStats.fps = frameStats.frames
		frameStats.frames = 0
		frameStats.windowStart = now
	}
}

// "30 fps · viewport 1.2 ms"
FrameStats_Text :: proc() -> string {
	return fmt.tprintf("%d fps · viewport %.1f ms", frameStats.fps, frameStats.viewportMs)
}
