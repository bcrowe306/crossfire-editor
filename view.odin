package crossfire_editor

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
	rowTipCount = 0
	ensureIconFont(ctx)
	// The viewport and code tabs draw on Skald's GPU device (gpu_share.odin)
	SharedGPU_SetSkald(ctx.renderer)
	th := ctx.theme
	state := s
	ScriptDriver_Frame(&state, ctx)
	// Before anything else registers shortcuts (see keymap.odin)
	// Dialogs and the open context menu take Escape (and every other key) themselves
	// Tab gives the keyboard back to the code editor that had it (code_editor_host.odin)
	// Code tabs show in the Scene mode only (editor_modes.odin)
	coding := CodeEditor_Frame(ctx, state.mode == .Scene && CodeTabs_Active(&state) != "")
	keysTaken := state.addNode.open || state.removeConfirm.open || state.settingsDialog.open || state.codeClose.open ||
		state.session.confirm.open || state.session.newProject.open || state.newScript.open || state.listenerDialog.open || state.newEvent.open || state.componentClose.open || state.newData.open || state.projectSettings.open || state.aboutOpen || state.git.discardAsk != "" ||
		state.contextMenu.open || state.logPoints.dialog.open || state.docs.open || state.level.conflict.open
	// The running game's values a code tab shows (code_live.odin)
	CodeLive_Frame(&state, ctx)
	// The States tab's machine in the running game (state_machine_edit.odin)
	States_LiveFrame(&state, ctx)
	// A project with scripts is built once in the background when it opens, so the inspector
	// knows their fields
	if len(state.scriptFiles) > 0 && !state.scriptsAutoBuilt && state.play.stage == .None {
		skald.send(ctx, Msg(Scripts_Auto_Build{}))
	}
	// Plugins are built and loaded while the project has a plugins/ folder (plugin_host.odin)
	if !state.pluginsTicking && Plugins_Present(&state) do skald.send(ctx, Msg(Plugins_Tick{}))
	// The script index follows the scripts' source while a project is open (script_index.odin)
	if !state.scriptIndex.ticking && state.project.rootPath != "" do skald.send(ctx, Msg(ScriptIndex_Tick{}))
	Session_UpdateTitle(&state)
	Branding_SetWindowIcon()
	Git_View_Tick(&state, ctx)
	// Where F1 (Help > User Manual) is pressed: the docs window opens at that panel's page
	Docs_TrackPointer(ctx, state.mode)
	// The viewport is the Scene mode's (its last rect stays in Skald's store while another mode shows)
	KeymapDispatch(ctx, &state.settings.keymap, state.mode == .Scene && ViewportHovered(ctx), dialogOpen = keysTaken,
		mode = state.mode, browserFocused = state.browserFocused)

	// The right-click menu, built first so it takes its clicks before the widgets under it
	contextMenu := contextMenuView(&state, ctx)
	return skald.col(
		contextMenu,
		// The menu bar's shortcuts are off while the code editor has the keyboard (the keymap's few
		// that still work fire through KeymapDispatch). The mode bar sits in its row, centered in
		// what the menus leave (no taller than it: the Scene mode's layout is as it was)
		skald.row(
			menuBarView(&state, ctx, keysTaken || coding),
			skald.flex(1, skald.spacer(0)),
			modeBarView(&state, ctx),
			skald.flex(1, skald.spacer(0)),
			cross_align = .Center,
		),
		toolbarView(&state, ctx),
		skald.divider(ctx),
		// The mode's workspace needs its own size to place the panels, so it's built once layout
		// knows it (editor_modes.odin)
		skald.flex(1, skald.sized(ctx, &state, modeWorkspaceView)),
		skald.divider(ctx),
		statusBarView(&state, ctx),
		removeAssetDialog(&state, ctx),
		addNodeDialog(&state, ctx),
		settingsDialogView(&state, ctx),
		newProjectDialogView(&state, ctx),
		newScriptDialogView(&state, ctx),
		CodeColorDialogView(&state, ctx),
		CodeRangeDialogView(&state, ctx),
		LogPointDialogView(&state, ctx),
		listenerDialogView(&state, ctx),
		newEventDialogView(&state, ctx),
		newDataDialogView(&state, ctx),
		projectSettingsDialogView(&state, ctx),
		confirmDialogView(&state, ctx),
		codeCloseDialogView(&state, ctx),
		componentCloseDialogView(&state, ctx),
		aboutDialogView(&state, ctx),
		gitDiscardDialog(&state, ctx),
		// An undo over an LDtk file changed outside (level_mode.odin)
		ldtkConflictDialogView(&state, ctx),
		// The docs window (view_docs.odin)
		docsWindowView(&state, ctx),
		// A drag into code: its label, its drop (code_drag.odin)
		CodeDrag_View(&state, ctx),
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
	Keys :: struct { keymap: ^Keymap, typing, taken: bool, mode: EditorMode, browserFocused: bool }
	keys := Keys{&s.settings.keymap, IsTyping(ctx), keysTaken, s.mode, s.browserFocused}
	// An item for another mode is disabled: the menu bar registers no shortcut for it then
	item :: proc(label: string, action: Action, keys: Keys, checked := false) -> skald.Menu_Item(Msg) {
		disabled := !Action_InMode(action, keys.mode, keys.browserFocused)
		if keys.taken do return {label = label, msg = action, disabled = disabled, checked = checked}
		return {label = label, shortcut = Chord_OnPlatform(Keymap_Shortcut(keys.keymap, action, keys.typing)), msg = action, disabled = disabled, checked = checked}
	}
	// "Undo Rename Spaceship"
	undoLabel := History_NextLabel(&s.history, false)
	redoLabel := History_NextLabel(&s.history, true)
	// File: the project, its recent ones (recent_projects.odin), import, export, quit
	fileItems := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
	// Open Recent: a submenu of the recent projects (disabled when there are none)
	recent := Recent_Shown(s)
	recentItem := skald.Menu_Item(Msg){label = "Open Recent", disabled = true}
	if len(recent) > 0 {
		recentItems := make([dynamic]skald.Menu_Item(Msg), context.temp_allocator)
		for i in recent do append(&recentItems, skald.Menu_Item(Msg){label = Recent_Label(s.recentProjects.folders[i]), msg = Msg(Recent_Project_Chosen(i))})
		append(&recentItems, skald.Menu_Item(Msg){separator = true}, skald.Menu_Item(Msg){label = "Clear Recent Projects", msg = Msg(Recent_Projects_Cleared{})})
		recentItem = {label = "Open Recent", submenu = recentItems[:]}
	}
	append(&fileItems,
		item("New Project", .New_Project, keys),
		item("Open Project", .Open_Project, keys),
		recentItem,
		item("Open Project Archive...", .Open_Project_Archive, keys),
		item("Save", .Save_Project, keys),
		item("Save Project As...", .Save_Project_As, keys),
	)
	append(&fileItems,
		skald.Menu_Item(Msg){separator = true},
		item("Import Asset...", .Import_Asset, keys),
		item("Project Settings...", .Open_Project_Settings, keys),
		skald.Menu_Item(Msg){separator = true},
		item("Export...", .Export, keys),
		item("Export Project Archive...", .Export_Project_Archive, keys),
		item("Export Project Archive with History...", .Export_Project_Archive_With_History, keys),
		skald.Menu_Item(Msg){separator = true},
		item("Quit", .Quit, keys),
	)
	return skald.menu_bar(ctx, []skald.Menu_Entry(Msg){
		{"File", fileItems[:]},
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
			{label = "New Script...", msg = Msg(New_Script_Opened{}), disabled = s.mode != .Scene},
			item("Open Script", .Open_Script, keys),
			item("Build Scripts", .Build_Scripts, keys),
			item("Close Code Tab", .Close_Code_Tab, keys),
		}},
		{"View", []skald.Menu_Item(Msg){
			// The editor's modes (editor_modes.odin), the one showing checked
			item("Scene Mode", .Mode_Scene, keys, checked = s.mode == .Scene),
			item("Level Mode", .Mode_Level, keys, checked = s.mode == .Level),
			{separator = true},
			item("Select Tool", .Tool_Select, keys),
			item("Move Tool", .Tool_Move, keys),
			item("Rotate Tool", .Tool_Rotate, keys),
			item("Scale Tool", .Tool_Scale, keys),
			item("Transform Tool", .Tool_Transform, keys),
			item("Zoom Tool", .Tool_Zoom, keys),
			item("Pan Tool", .Tool_Pan, keys),
			item("Move Along the Node's Axes", .Toggle_Local_Axes, keys, checked = s.viewport.localAxes),
			item("Show Guides", .Toggle_Guides, keys, checked = !s.viewport.guidesHidden),
			{separator = true},
			item("Frame Selected", .Frame_Selected, keys),
			item("Fit Game Area", .View_Fit, keys),
			item("Zoom In", .Zoom_In, keys),
			item("Zoom Out", .Zoom_Out, keys),
			item("Zoom to 100%", .Zoom_100, keys),
			item("Play/Pause Animations", .Toggle_Animation, keys),
			{separator = true},
			item("Show Grid", .Toggle_Grid, keys),
			item("Show Collision Shapes", .Toggle_Collision_Shapes, keys, checked = s.viewport.showShapes),
			item("Snap to Grid", .Toggle_Snap, keys),
			{label = "Grid Settings...", msg = Msg(Open_Grid_Settings{}), disabled = s.mode != .Scene},
			{separator = true},
			item("Toggle Bottom Panel", .Toggle_Bottom_Panel, keys),
			item("Clear Console", .Clear_Console, keys),
		}},
		{"Scene", []skald.Menu_Item(Msg){
			item("Play", .Play, keys),
			item("Play This Scene", .Play_Scene, keys),
			{label = "Show Collision Shapes in Game", msg = Msg(Action.Toggle_Physics_Debug),
			 shortcut = keys.taken ? {} : Chord_OnPlatform(Keymap_Shortcut(keys.keymap, .Toggle_Physics_Debug, keys.typing)),
			 checked = PhysicsDebug_Shown(s)},
			{label = "New Scene", msg = Msg(Scene_Action{.New, -1})},
			item("Pause", .Pause, keys),
			item("Stop", .Stop, keys),
			{label = "Restart", msg = Msg(Action.Restart), disabled = s.playState == .Stopped,
			 shortcut = keys.taken ? {} : Chord_OnPlatform(Keymap_Shortcut(keys.keymap, .Restart, keys.typing))},
		}},
		{"Help", []skald.Menu_Item(Msg){
			item("User Manual", .User_Manual, keys),
			{label = "Keyboard Shortcuts", msg = Msg(Open_Keyboard_Settings{})},
			item("About", .About, keys),
		}},
	})
}

/*
The toolbar: file buttons, undo / redo and the tools on the left, the play controls in the middle,
Export on the right. When the window is too narrow for all of it (a tiled window is about 650 px
wide), the tools go into an overflow button's menu (`toolbar-more`, `Ctx_Toolbar_More`), and
narrower still the file and undo buttons too (`Toolbar_Overflow`): the play controls and Export
always show.
*/
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
	// The viewport's tools are the Scene mode's (editor_modes.odin)
	tools := s.mode == .Scene
	overflow := Toolbar_Overflow(s.layout.workspace.x, math.round(th.font.size_md * 2.4), th.spacing.xs, th.spacing.sm, tools)
	items := make([dynamic]skald.View, context.temp_allocator)
	if overflow < .Files {
		append(&items,
			toolButton(ctx, "new", ICON_FILE, actionTip(s, "New project", .New_Project), Action.New_Project),
			toolButton(ctx, "open", ICON_FOLDER_OPEN, actionTip(s, "Open project", .Open_Project), Action.Open_Project),
			toolButton(ctx, "save", ICON_SAVE, actionTip(s, "Save", .Save_Project), Action.Save_Project),
			toolbarSeparator(ctx),
			toolButton(ctx, "undo", ICON_UNDO, actionTip(s, "Undo", .Undo), Action.Undo),
			toolButton(ctx, "redo", ICON_REDO, actionTip(s, "Redo", .Redo), Action.Redo),
			toolbarSeparator(ctx))
	}
	if overflow == .None && tools {
		append(&items,
			toolButton(ctx, "select", ICON_POINTER, actionTip(s, "Select", .Tool_Select), Action.Tool_Select, active = s.tool == .Select),
			toolButton(ctx, "move", ICON_MOVE, actionTip(s, "Move", .Tool_Move), Action.Tool_Move, active = s.tool == .Move),
			toolButton(ctx, "rotate", ICON_ROTATE, actionTip(s, "Rotate", .Tool_Rotate), Action.Tool_Rotate, active = s.tool == .Rotate),
			toolButton(ctx, "scale", ICON_SCALE, actionTip(s, "Scale", .Tool_Scale), Action.Tool_Scale, active = s.tool == .Scale),
			toolButton(ctx, "transform", ICON_VECTOR_SQUARE, actionTip(s, "Transform: move, rotate and scale handles at once", .Tool_Transform), Action.Tool_Transform, active = s.tool == .Transform),
			toolButton(ctx, "zoom", ICON_ZOOM, actionTip(s, "Zoom: click to zoom in (Alt: out), drag a box to zoom to it", .Tool_Zoom), Action.Tool_Zoom, active = s.tool == .Zoom),
			toolButton(ctx, "pan", ICON_HAND, actionTip(s, "Pan the view", .Tool_Pan), Action.Tool_Pan, active = s.tool == .Pan))
	} else if overflow != .None {
		// The menu opens under the button
		r := lastRect(ctx, skald.hash_id("toolbar-more"))
		append(&items, toolButton(ctx, "more", ICON_ELLIPSIS,
			!tools ? "File and undo" : overflow == .Files ? "File, undo and the viewport's tools" : "The viewport's tools",
			Msg(Context_Menu_Opened{at = {r.x, r.y + r.h}, target = Ctx_Toolbar_More{files = overflow == .Files, noTools = !tools}})))
	}
	append(&items,
		// Play controls sit in the middle of the toolbar
		skald.flex(1, skald.spacer(0)),
		toolButton(ctx, "play", ICON_PLAY, playTip, Action.Play, active = running),
		toolButton(ctx, "play-scene", ICON_PLAY_SCENE, actionTip(s, fmt.tprintf("Play %s (this scene)", s.project.scenes[s.currentScene].name), .Play_Scene), Action.Play_Scene, disabled = running),
		toolButton(ctx, "pause", ICON_PAUSE, actionTip(s, "Pause", .Pause), Action.Pause, active = s.playState == .Paused, disabled = s.playState != .Playing),
		toolButton(ctx, "stop", ICON_STOP, actionTip(s, "Stop", .Stop), Action.Stop, disabled = s.playState == .Stopped),
		toolButton(ctx, "restart", ICON_RESTART, actionTip(s, "Restart: stop the game and play it again", .Restart), Action.Restart, disabled = !Play_CanRestart(s)),
		// The game's collision shapes (project.physics.debugDraw; a running game's at once, over the live link)
		toolButton(ctx, "physics-debug", ICON_POLYGON, actionTip(s, physicsDebugTip(s), .Toggle_Physics_Debug), Action.Toggle_Physics_Debug, active = PhysicsDebug_Shown(s)),
		skald.flex(1, skald.spacer(0)),
		toolButton(ctx, "export", ICON_EXPORT, actionTip(s, "Export", .Export), Action.Export))
	return skald.row(..items[:],
		spacing = th.spacing.xs,
		padding = th.spacing.sm,
		cross_align = .Center,
		bg = th.color.surface,
	)
}

// What the toolbar puts in its overflow menu (`Toolbar_Overflow`)
ToolbarOverflow :: enum {
	// Everything fits
	None,
	// The viewport's seven tools
	Tools,
	// The tools, and the file and undo / redo buttons
	Files,
}

/*
How much of the toolbar goes into its overflow menu at a window width: the toolbar's buttons all
have one width, so its width is known without laying it out.

Inputs:
- width: The window's width (0: not measured yet, everything shows)
- button: A tool button's width
- spacing: Between items
- padding: At each end
- tools: The viewport's tools are on it (the Scene mode; other modes have none)

Returns:
- What overflows (without the tools: None or Files)
*/
Toolbar_Overflow :: proc(width, button, spacing, padding: f32, tools := true) -> ToolbarOverflow {
	if width <= 0 do return .None
	separator := 1 + spacing * 2
	// items: buttons and separators, and the two spacers around the play controls
	needed :: proc(buttons, separators: int, button, separator, spacing, padding: f32) -> f32 {
		items := buttons + separators + 2
		return padding * 2 + f32(buttons) * button + f32(separators) * separator + f32(items - 1) * spacing
	}
	// File 3, undo 2, tools 7, play controls 6, Export 1; the overflow button replaces what it holds
	if !tools do return needed(12, 2, button, separator, spacing, padding) <= width ? .None : .Files
	if needed(19, 2, button, separator, spacing, padding) <= width do return .None
	if needed(13, 2, button, separator, spacing, padding) <= width do return .Tools
	return .Files
}

// The toolbar's collision shapes button's tooltip: what a click does, now and when played
@(private="file")
physicsDebugTip :: proc(s: ^State) -> string {
	shown := PhysicsDebug_Shown(s)
	if s.live.connected && s.playState != .Stopped {
		return shown ? "Hide the running game's collision shapes (and when played)" : "Show the running game's collision shapes (and when played)"
	}
	return shown ? "The game shows its collision shapes: click to hide them (development only, not in exports)" : "Show collision shapes in the game (development only, not in exports)"
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
The Scene mode's workspace (editor_modes.odin), its resizable panels. Built by `sized`, so it knows
the space it has: the left sidebar and the bottom panel are stored as their own sizes and the
viewport gets what is left.
*/
sceneModeView :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	// Use this frame's size even if update hasn't stored it yet (modeWorkspaceView reports it)
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
	// The Git branch (and how far it is from its upstream): a click opens the Git tab
	branch: skald.View = skald.View_Spacer{size = 0}
	if git := &s.git.snapshot; git.availability == .Repo {
		text := fmt.tprintf("%s  %s%s%s%s", ICON_CODE_BRANCH, git.branch == "" ? "(no branch)" : git.branch,
			git.ahead > 0 ? fmt.tprintf("  %s%d", ICON_ARROW_UP, git.ahead) : "",
			git.behind > 0 ? fmt.tprintf("  %s%d", ICON_ARROW_DOWN, git.behind) : "",
			git.merging ? "  (merging)" : "")
		branch = skald.button(ctx, text, Msg(Bottom_Tab_Changed(int(BottomTab.Git))), id = skald.hash_id("status-git-branch"),
			bg = {}, fg = git.merging ? th.color.warning : th.color.fg_muted, padding = {th.spacing.xs, 0}, font_size = th.font.size_sm)
	}
	// The Scene mode's scene, nodes, selection and tool; the Level mode's world and level
	middle: [3]skald.View
	tool: skald.View = skald.View_Spacer{size = 0}
	switch s.mode {
	case .Scene:
		middle = {statusText(ctx, fmt.tprintf("Scene: %s", scene.name)), statusText(ctx, fmt.tprintf("%d nodes", len(scene.nodes))), statusText(ctx, fmt.tprintf("Selection: %s", selection))}
		tool = statusText(ctx, fmt.tprintf("Tool: %v", s.tool))
	case .Level:
		world, level, outside := LevelMode_Status(s)
		middle = {statusText(ctx, "Level mode"), statusText(ctx, world), statusText(ctx, level)}
		if outside != "" do tool = skald.text(outside, th.color.warning, th.font.size_sm)
	}
	return skald.row(
		statusText(ctx, fmt.tprintf("%s  %s", ICON_SITEMAP, s.project.name)),
		Project_IsModified(s) ? skald.text("Modified", th.color.warning, th.font.size_sm) : skald.text("Saved", th.color.fg_muted, th.font.size_sm),
		branch,
		middle[0],
		middle[1],
		middle[2],
		skald.flex(1, skald.spacer(0)),
		statusText(ctx, FrameStats_Text()),
		tool,
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
	return fmt.tprintf("%s (%s)", label, Chord_Format(chord))
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
	// Closed: no content (its buttons would stay clickable where they were drawn: closedDialog)
	if !s.removeConfirm.open do return closedDialog(ctx, "remove-asset-dialog")
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

/*
A closed dialog, with no content. Dialogs build their content before skald.dialog decides not to
show it, and Skald hit-tests a widget by its rect from the last frame it was *built* in, not
drawn: a closed dialog's buttons and rows stayed clickable where they had been (a click in the
viewport where the Add Node dialog's "Sprite" row had been added a Sprite). Called with the
dialog's id, so it still hands focus back when it closes.
*/
closedDialog :: proc(ctx: ^skald.Ctx(Msg), key: string) -> skald.View {
	return skald.dialog(ctx, open = false, on_dismiss = proc() -> Msg { return nil }, content = skald.spacer(0), id = skald.hash_id(key))
}
