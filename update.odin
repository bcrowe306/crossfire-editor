package editor

import "core:fmt"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:time"
import e "engine:."
import "gui:skald"

/*
Applies a message to the editor state. The only place State changes.

Edits to the project are recorded for undo here: `History_Classify` says what a message edits,
which is copied before the message is applied and compared after (see history.odin).
*/
update :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	state := s
	state.selectionSet = false
	// Also before: code outside update (tests, the test driver) may have set selectedNode alone
	Selection_Normalize(&state)
	info := History_Classify(&state, m)
	snap: EditSnapshot
	if info.scope != .None do snap = History_Snapshot(&state, info)
	out, command := applyMsg(state, m)
	// A structural edit renumbers nodes: the old multi-selection is meaningless unless the edit
	// chose a new one. Then make the selection agree with selectedNode (selection.odin)
	if info.scope == .Scene && !out.selectionSet do clear(&out.selection)
	Selection_Normalize(&out)
	if info.scope != .None do History_Commit(&out, snap, time.tick_now())
	return out, command
}

@(private="file")
applyMsg :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	if command, handled := SettingsDialog_Update(&out, m); handled do return out, command
	if command, handled := Session_Update(&out, m); handled do return out, command
	layout := &out.layout

	switch v in m {
	case Action:
		return handleAction(out, v)
	case Play_Tick:
		cmd := playTick(&out)
		return out, cmd
	case Confirm_Chosen, New_Project_Name_Changed, New_Project_Location_Changed, New_Project_Browse,
	     New_Project_Location_Chosen, New_Project_Created, New_Project_Cancelled, Open_Project_Chosen:
		// Handled by Session_Update above
	case Settings_Tab_Changed, Settings_Theme_Changed, Settings_Value_Changed, Settings_Search_Changed,
	     Settings_Capture_Started, Settings_Key_Captured, Settings_Capture_Cancelled, Settings_Key_Cleared,
	     Settings_Key_Reset, Settings_Tab_Reset, Settings_Applied, Settings_Cancelled:
		// Handled by SettingsDialog_Update above
	case Viewport_Tick:
		out.viewport.animationFrame += 1
		// Schedule the next frame here rather than from the view, which would cost extra redraws.
		// Stops when animations are off or the window loses focus; the view restarts it
		if !out.viewport.animate || !Preview_IsAnimated() || !EditorFocused() {
			out.viewport.tickPending = false
			break
		}
		return out, nextViewportTick(&out.viewport)
	case Viewport_Tick_Requested:
		if out.viewport.tickPending do break
		out.viewport.tickPending = true
		out.viewport.nextTick = time.tick_now()
		return out, nextViewportTick(&out.viewport)
	case Script_Tick, Preview_Tick:
		// Only keep frames coming (test script, viewport animations, audio progress)

	case Browser_Search_Changed:
		// Msg strings only live for the frame
		delete(out.browserSearch)
		out.browserSearch = strings.clone(string(v))
	case Browser_Body_Measured:
		out.layout.browserBodyHeight = f32(v)
	case Browser_Tree_Resized:
		// The preview keeps its own height, so it stays put when the window resizes
		out.layout.previewHeight = max(out.layout.browserBodyHeight - f32(v) - DIVIDER, MIN_PREVIEW_HEIGHT)

	case Asset_Import_Result:
		if v.cancelled || v.path == "" do break
		importAsset(&out, v.path)

	case Asset_Remove_Confirmed:
		index := out.removeConfirm.asset
		out.removeConfirm = {}
		if index < 0 || index >= len(out.project.assets) do break
		asset := out.project.assets[index]
		name := strings.clone(filepath.base(asset.path), context.temp_allocator)
		if AudioPreview_IsLoaded(AssetFilePath(&out.project, asset)) do AudioPreview_Unload()
		usage := AssetUsage(&out.project, asset.path)
		out.session.assetsChanged = true
		if message := Project_RemoveAsset(&out.project, index, v.deleteFile); message != "" {
			logLine(&out, .Error, fmt.aprintf("%s", message))
		} else {
			logLine(&out, .Info, fmt.aprintf("%s %s%s", v.deleteFile ? "Deleted" : "Removed", name,
				usage > 0 ? fmt.tprintf(" (still used by %d node%s)", usage, usage == 1 ? "" : "s") : ""))
		}
		out.browserSelection = {kind = .None}
	case Asset_Remove_Cancelled:
		out.removeConfirm = {}

	case Rename_Started:
		startRename(&out, int(v))
	case Rename_Text_Changed:
		delete(out.rename.text)
		out.rename.text = strings.clone(string(v))
	case Rename_Focused:
		out.rename.focused = true
	case Rename_Committed:
		scene := &out.project.scenes[out.currentScene]
		index, text := out.rename.node, strings.trim_space(out.rename.text)
		if out.rename.active && index >= 0 && index < len(scene.nodes) && text != "" && text != scene.nodes[index].name {
			logLine(&out, .Info, fmt.aprintf("Renamed %s to %s", scene.nodes[index].name, text))
			delete(scene.nodes[index].name)
			scene.nodes[index].name = strings.clone(text)
		}
		delete(out.rename.text)
		out.rename = {}
	case Rename_Cancelled:
		delete(out.rename.text)
		out.rename = {}
	case Number_Text_Changed:
		// Applies when the text is a number, through the field's own message
		if apply := NumberEdit_Update(&out, v); apply != nil do return applyMsg(out, apply)
	case Number_Edit_Ended:
		if out.numberEdit.id == skald.Widget_ID(v) {
			delete(out.numberEdit.text)
			out.numberEdit = {}
		}
	case Frame_Requested:
	case Quit_Without_Asking:
		playStop(&out)
		return out, skald.cmd_quit(Msg)

	case Asset_Drag_Pressed:
		out.assetDrag = {pressed = true, asset = v.asset, start = v.start}
	case Asset_Drag_Started:
		out.assetDrag.active = true
	case Asset_Drag_Cancelled:
		out.assetDrag = {}
	case Asset_Dropped:
		asset := out.assetDrag.asset
		out.assetDrag = {}
		if asset < 0 || asset >= len(out.project.assets) || out.project.assets[asset].kind != .Image do break
		index := Scene_AddSpriteAt(&out.project.scenes[out.currentScene], out.project.assets[asset].path, out.selectedNode, v.world)
		out.selectedNode = index
		logLine(&out, .Info, fmt.aprintf("Added %s", out.project.scenes[out.currentScene].nodes[index].name))

	case Add_Node_Search_Changed:
		delete(out.addNode.search)
		out.addNode.search = strings.clone(string(v))
		out.addNode.highlight = 0
	case Add_Node_Highlight_Moved:
		count := len(AddNode_Kinds(out.addNode.search))
		if count > 0 do out.addNode.highlight = clamp(out.addNode.highlight + int(v), 0, count - 1)
	case Add_Node_Confirmed:
		kinds := AddNode_Kinds(out.addNode.search)
		if out.addNode.highlight < len(kinds) do addNodeOfKind(&out, kinds[out.addNode.highlight])
	case Add_Node_Kind_Chosen:
		addNodeOfKind(&out, NodeKind(v))
	case Add_Node_Cancelled:
		out.addNode.open = false

	case Viewport_Measured:
		out.viewport.size = cast([2]f32)v
		if out.viewport.zoom == 0 do Viewport_Fit(&out.viewport, out.project.gameSize)
	case Viewport_Panned:
		Viewport_Pan(&out.viewport, cast([2]f32)v)
	case Viewport_Zoomed:
		Viewport_ZoomAt(&out.viewport, v.factor, v.anchor)

	case Viewport_Drag_Begin:
		// A new gesture: it won't merge with the previous drag's undo step
		out.history.gesture += 1
		drag := ViewportDrag{mode = v.mode, node = v.node, startMouse = v.mouse, current = v.mouse, additive = v.additive}
		if v.mode != .Pan && v.mode != .Box {
			scene := &out.project.scenes[out.currentScene]
			if v.node < 0 || v.node >= len(scene.nodes) do break
			// Keeps a multi-selection that includes it (they move together)
			out.selectedNode = v.node
			if Selection_Contains(&out, v.node) do out.selectionSet = true
			node := &scene.nodes[v.node]
			world := Scene_WorldTransforms(scene)
			drag.startPosition = node.position
			drag.startRotation = node.rotation
			drag.startScale = node.scale
			drag.startWorld = world[v.node]
			drag.parentWorld = node.parent >= 0 ? world[node.parent] : e.TRANSFORM2D_IDENTITY
		}
		out.viewport.drag = drag
	case Viewport_Drag_Move:
		drag := &out.viewport.drag
		scene := &out.project.scenes[out.currentScene]
		if drag.mode == .Box {
			drag.current = v.mouse
			break
		}
		if drag.mode == .None || drag.mode == .Pan || drag.node < 0 || drag.node >= len(scene.nodes) do break
		before := scene.nodes[drag.node]
		grid := out.viewport.snap ? f32(out.settings.gridSize) : 0
		Viewport_ApplyDrag(&scene.nodes[drag.node], drag, v.mouse, v.constrain, grid)
		// The rest of the selection follows
		if len(out.selection) > 1 && Selection_Contains(&out, drag.node) {
			Viewport_FollowDrag(scene, drag.node, before, Selection_Roots(&out))
			out.selectionSet = true
		}
	case Viewport_Drag_End:
		if out.viewport.drag.mode == .Box do boxSelect(&out, out.viewport.drag)
		out.viewport.drag = {}

	// Panel sizes. Splits report the size of their first pane; sidebars and the bottom panel
	// are stored as their own size so they stay put when the window resizes
	case Left_Resized:
		layout.leftWidth = max(f32(v), MIN_SIDEBAR_WIDTH)
	case Center_Resized:
		left, _ := FittedSidebarWidths(layout)
		rest := layout.workspace.x - left - DIVIDER
		layout.rightWidth = max(rest - f32(v) - DIVIDER, MIN_SIDEBAR_WIDTH)
	case Viewport_Resized:
		layout.bottomHeight = max(layout.workspace.y - f32(v) - DIVIDER, MIN_BOTTOM_HEIGHT)
	case Scene_Tree_Resized:
		layout.sceneTreeHeight = max(f32(v), MIN_SCENE_TREE_HEIGHT)
	case Workspace_Measured:
		layout.workspace = cast([2]f32)v

	case Bottom_Tab_Changed:
		out.bottomTab = BottomTab(int(v))
		layout.bottomOpen = true
	case Scene_Tab_Changed:
		openScene(&out, int(v))
	case Tool_Selected:
		out.tool = Tool(v)

	case Browser_Toggled:
		rows := BrowserRows(&out)
		if int(v) < len(rows) && rows[v].kind == .Folder {
			out.browserOpen[rows[v].folder] = !out.browserOpen[rows[v].folder]
		}
	case Browser_Selected:
		rows := BrowserRows(&out)
		if int(v) >= len(rows) do break
		item := rows[v]
		out.browserSelection = item
		switch item.kind {
		case .Folder:
			out.browserOpen[item.folder] = !out.browserOpen[item.folder]
		case .Scene:
			openScene(&out, item.index)
		case .Asset:
			selectAsset(&out, item.index)
		case .None:
		}

	case Node_Toggled:
		scene := &out.project.scenes[out.currentScene]
		rows := SceneTreeRows(scene)
		if int(v) < len(rows) {
			node := &scene.nodes[rows[v]]
			node.expanded = !node.expanded
		}
	// A plain click selects just that node
	case Node_Selected:
		rows := SceneTreeRows(&out.project.scenes[out.currentScene])
		if int(v) < len(rows) {
			clear(&out.selection)
			out.selectedNode = rows[v]
		}
	case Node_Picked:
		clear(&out.selection)
		out.selectedNode = int(v)
	case Node_Pick_Toggled:
		if int(v) >= 0 do Selection_Toggle(&out, int(v))
	case Node_Pick_Added:
		if int(v) >= 0 && !Selection_Contains(&out, int(v)) do Selection_Toggle(&out, int(v))
	case Node_Primary_Picked:
		out.selectedNode = int(v)
		out.selectionSet = true
	case Tree_Selection_Clicked:
		rows := SceneTreeRows(&out.project.scenes[out.currentScene])
		if v.row < 0 || v.row >= len(rows) do break
		node := rows[v.row]
		if !v.range || out.selectedNode < 0 {
			Selection_Toggle(&out, node)
			break
		}
		// Shift: every row between the primary node's row and this one
		from := v.row
		for r, i in rows do if r == out.selectedNode do from = i
		nodes := make([dynamic]int, context.temp_allocator)
		append(&nodes, ..out.selection[:])
		for i in min(from, v.row)..=max(from, v.row) do append(&nodes, rows[i])
		Selection_Set(&out, nodes[:], node)
	case Node_Right_Clicked:
		// On a node of a multi-selection the menu acts on all of them; elsewhere, just that node
		rows := SceneTreeRows(&out.project.scenes[out.currentScene])
		node := int(v) >= 0 && int(v) < len(rows) ? rows[v] : -1
		if node >= 0 && Selection_Contains(&out, node) {
			out.selectedNode = node
			out.selectionSet = true
		} else {
			clear(&out.selection)
			out.selectedNode = node
		}

	case Tree_Drag_Pressed:
		out.treeDrag = {pressed = true, node = v.node, start = v.start}
	case Tree_Drag_Started:
		out.treeDrag.active = true
	case Tree_Drag_Cancelled:
		out.treeDrag = {}
	case Tree_Drag_Dropped:
		scene := &out.project.scenes[out.currentScene]
		node := out.treeDrag.node
		out.treeDrag = {}
		if node < 0 || node >= len(scene.nodes) do break
		name := scene.nodes[node].name
		if index, moved := Scene_MoveNode(scene, node, v.target, v.position); moved {
			out.selectedNode = index
			out.viewport.drag = {}
			parent := scene.nodes[index].parent
			logLine(&out, .Info, parent >= 0 ? fmt.aprintf("Moved %s into %s", name, scene.nodes[parent].name) : fmt.aprintf("Moved %s to the top level", name))
		}

	case Node_Renamed:
		if node := selectedNode(&out); node != nil {
			// Msg strings only live for the frame (see Skald's gotchas), so keep a copy
			delete(node.name)
			node.name = strings.clone(string(v))
		}
	case Node_Visibility_Changed:
		if node := selectedNode(&out); node != nil do node.visible = bool(v)
	case Inspector_Link_Toggled:
		out.inspectorLinks[LinkedPair(v)] = !out.inspectorLinks[LinkedPair(v)]
	case Node_Field_Changed:
		node := selectedNode(&out)
		if node == nil do break
		value := f32(v.value)
		// A linked pair: the other axis follows in proportion
		#partial switch v.field {
		case .Position_X: if out.inspectorLinks[.Position] do node.position.y = LinkedAxis(node.position.x, value, node.position.y)
		case .Position_Y: if out.inspectorLinks[.Position] do node.position.x = LinkedAxis(node.position.y, value, node.position.x)
		case .Scale_X:    if out.inspectorLinks[.Scale] do node.scale.y = LinkedAxis(node.scale.x, value, node.scale.y)
		case .Scale_Y:    if out.inspectorLinks[.Scale] do node.scale.x = LinkedAxis(node.scale.y, value, node.scale.x)
		}
		switch v.field {
		case .Position_X: node.position.x = value
		case .Position_Y: node.position.y = value
		case .Rotation:   node.rotation = value
		case .Scale_X:    node.scale.x = value
		case .Scale_Y:    node.scale.y = value
		case .Layer:      node.layer = clamp(int(v.value), 0, 7)
		case .Font_Size:  node.fontSize = max(value, 1)
		case .Zoom:       node.zoom = max(value, 0.05)
		case .Columns:    node.columns = max(int(v.value), 1)
		case .Rows:       node.rows = max(int(v.value), 1)
		case .FPS:        node.fps = max(value, 0)
		}
	case Node_Text_Changed:
		node := selectedNode(&out)
		if node == nil do break
		// Msg strings only live for the frame, so keep copies
		switch v.field {
		case .Text:
			delete(node.text)
			node.text = strings.clone(v.value)
		case .Texture:
			delete(node.texture)
			node.texture = strings.clone(v.value == TEXTURE_NONE ? "" : v.value)
		case .Color:
			if color, ok := e.ParseColor(v.value); ok do node.color = color
		case .Play_Mode:
			if mode, ok := reflect.enum_from_name(e.AnimationPlayMode, v.value); ok do node.playMode = mode
		}
	case Node_Flag_Changed:
		node := selectedNode(&out)
		if node == nil do break
		switch v.flag {
		case .Loop:     node.loop = v.value
		case .Centered: node.centered = v.value
		}
	}
	return out, {}
}

@(private="file")
handleAction :: proc(s: State, action: Action) -> (State, skald.Command(Msg)) {
	out := s
	switch action {
	case .Quit:
		return out, Session_Request(&out, .Quit)
	case .New_Project:
		return out, Session_Request(&out, .New_Project)
	case .Open_Project:
		return out, Session_Request(&out, .Open_Project)

	case .Save_Project:
		Session_Save(&out)
	case .Play:
		cmd := playStart(&out)
		return out, cmd
	case .Pause:
		playPause(&out)
	case .Stop:
		playStop(&out)

	case .Add_Node:
		// Opens the dialog; the node is added when a kind is picked
		delete(out.addNode.search)
		out.addNode = {open = true}
	// These act on every selected node (the selection's roots: see selection.odin)
	case .Duplicate_Node:
		roots := Selection_Roots(&out)
		if len(roots) == 0 do break
		scene := &out.project.scenes[out.currentScene]
		primary := slice_index(roots, out.selectedNode)
		copies := Scene_DuplicateNodes(scene, roots)
		Selection_Set(&out, copies, primary >= 0 ? copies[primary] : -1)
		logLine(&out, .Info, fmt.aprintf("Duplicated %s", describeNodes(scene, copies)))
	case .Copy_Node, .Cut_Node:
		roots := Selection_Roots(&out)
		if len(roots) == 0 do break
		scene := &out.project.scenes[out.currentScene]
		Subtree_Destroy(&out.clipboard)
		out.clipboard = Scene_CopyNodes(scene, roots)
		names := describeNodes(scene, roots)
		if action == .Copy_Node {
			logLine(&out, .Info, fmt.aprintf("Copied %s", names))
			break
		}
		logLine(&out, .Info, fmt.aprintf("Cut %s", names))
		Scene_RemoveNodes(scene, roots)
		out.selectedNode = -1
		out.viewport.drag = {}
	case .Paste_Node:
		if len(out.clipboard) == 0 {
			logLine(&out, .Info, strings.clone("Nothing to paste: copy a node first"))
			break
		}
		// Into the selected node, like Add Node
		scene := &out.project.scenes[out.currentScene]
		parent := selectedNode(&out) != nil ? out.selectedNode : -1
		roots := Scene_PasteNodes(scene, out.clipboard[:], parent)
		Selection_Set(&out, roots, roots[0])
		logLine(&out, .Info, fmt.aprintf("Pasted %s", describeNodes(scene, roots)))
	case .Select_All:
		scene := &out.project.scenes[out.currentScene]
		all := make([]int, len(scene.nodes), context.temp_allocator)
		for &n, i in all do n = i
		if len(all) > 0 do Selection_Set(&out, all, out.selectedNode >= 0 ? out.selectedNode : 0)
	case .Toggle_Grid:
		out.viewport.gridVisible = !out.viewport.gridVisible
	case .Toggle_Snap:
		out.viewport.snap = !out.viewport.snap

	case .Delete_Node:
		roots := Selection_Roots(&out)
		if len(roots) == 0 do break
		scene := &out.project.scenes[out.currentScene]
		logLine(&out, .Info, fmt.aprintf("Deleted %s", describeNodes(scene, roots)))
		Scene_RemoveNodes(scene, roots)
		out.selectedNode = -1
		out.viewport.drag = {}

	case .Toggle_Bottom_Panel:
		out.layout.bottomOpen = !out.layout.bottomOpen
	case .Clear_Console:
		// Clears whichever log tab is showing
		lines := out.bottomTab == .Output ? &out.output : &out.console
		for line in lines do delete(line.text)
		clear(lines)

	case .Tool_Select: out.tool = .Select
	case .Tool_Move:   out.tool = .Move
	case .Tool_Rotate: out.tool = .Rotate
	case .Tool_Scale:  out.tool = .Scale

	case .View_Fit:
		Viewport_Fit(&out.viewport, out.project.gameSize)
	case .Zoom_In:
		Viewport_ZoomAt(&out.viewport, VIEWPORT_ZOOM_STEP, out.viewport.center)
	case .Zoom_Out:
		Viewport_ZoomAt(&out.viewport, 1 / VIEWPORT_ZOOM_STEP, out.viewport.center)
	case .Zoom_100:
		out.viewport.zoom = 1
	case .Frame_Selected:
		scene := &out.project.scenes[out.currentScene]
		if out.selectedNode >= 0 && out.selectedNode < len(scene.nodes) {
			out.viewport.center = Scene_WorldTransforms(scene)[out.selectedNode].origin
		}
	case .Toggle_Animation:
		out.viewport.animate = !out.viewport.animate
	case .Deselect:
		out.selectedNode = -1

	case .Nudge_Left, .Nudge_Right, .Nudge_Up, .Nudge_Down,
	     .Nudge_Left_Large, .Nudge_Right_Large, .Nudge_Up_Large, .Nudge_Down_Large:
		scene := &out.project.scenes[out.currentScene]
		if out.selectedNode < 0 || out.selectedNode >= len(scene.nodes) do break
		delta: [2]f32
		#partial switch action {
		case .Nudge_Left:        delta = {-NUDGE_SMALL, 0}
		case .Nudge_Right:       delta = {NUDGE_SMALL, 0}
		case .Nudge_Up:          delta = {0, -NUDGE_SMALL}
		case .Nudge_Down:        delta = {0, NUDGE_SMALL}
		case .Nudge_Left_Large:  delta = {-NUDGE_LARGE, 0}
		case .Nudge_Right_Large: delta = {NUDGE_LARGE, 0}
		case .Nudge_Up_Large:    delta = {0, -NUDGE_LARGE}
		case .Nudge_Down_Large:  delta = {0, NUDGE_LARGE}
		}
		// The nudge is in world units; convert it into each parent's space
		world := Scene_WorldTransforms(scene)
		for root in Selection_Roots(&out) {
			node := &scene.nodes[root]
			local := delta
			if node.parent >= 0 do local = e.Transform2D_ApplyVector(e.Transform2D_Inverse(world[node.parent]), delta)
			node.position += local
		}
		out.selectionSet = true

	case .Import_Asset:
		@(static) filters := [?]skald.File_Filter{
			{"Images, audio and fonts", IMPORT_IMAGE_PATTERN + ";" + IMPORT_AUDIO_PATTERN + ";" + IMPORT_FONT_PATTERN},
			{"Images", IMPORT_IMAGE_PATTERN},
			{"Audio", IMPORT_AUDIO_PATTERN},
			{"Fonts", IMPORT_FONT_PATTERN},
		}
		return out, skald.cmd_open_file_dialog(filters[:], proc(r: skald.File_Dialog_Result) -> Msg { return Asset_Import_Result(r) })
	case .Remove_Asset:
		if out.browserSelection.kind == .Asset {
			out.removeConfirm = {open = true, asset = out.browserSelection.index}
		}
	case .Toggle_Preview_Panel:
		out.layout.previewOpen = !out.layout.previewOpen
	case .Play_Audio_Preview:
		AudioPreview_Play()
	case .Stop_Audio_Preview:
		AudioPreview_Stop()

	case .Undo:
		if label, ok := History_Undo(&out); ok {
			logLine(&out, .Info, fmt.aprintf("Undo: %s", label))
		} else {
			logLine(&out, .Info, strings.clone("Nothing to undo"))
		}
	case .Redo:
		if label, ok := History_Redo(&out); ok {
			logLine(&out, .Info, fmt.aprintf("Redo: %s", label))
		} else {
			logLine(&out, .Info, strings.clone("Nothing to redo"))
		}
	case .Rename_Node:
		startRename(&out, out.selectedNode)
	case .Open_Settings:
		SettingsDialog_Open(&out)
	case .Export, .About:
		logLine(&out, .Warning, fmt.aprintf("%v is not implemented yet", action))
	}
	return out, {}
}

// Shows another scene in the viewport, clearing the selection
openScene :: proc(state: ^State, index: int) {
	if index < 0 || index >= len(state.project.scenes) || index == state.currentScene do return
	state.currentScene = index
	state.selectedNode = -1
	state.viewport.drag = {}
	// Show the whole game area of the newly opened scene. Before the viewport has been measured,
	// zoom 0 makes the first Viewport_Measured fit it instead
	if state.viewport.size.x > 0 && state.viewport.size.y > 0 {
		Viewport_Fit(&state.viewport, state.project.gameSize)
	} else {
		state.viewport.zoom = 0
	}
}

@(private="file")
selectedNode :: proc(state: ^State) -> ^NodeDef {
	scene := &state.project.scenes[state.currentScene]
	if state.selectedNode < 0 || state.selectedNode >= len(scene.nodes) do return nil
	return &scene.nodes[state.selectedNode]
}

// Imports a file and selects it in the browser
@(private="file")
importAsset :: proc(state: ^State, path: string) {
	index, message := Project_ImportAsset(&state.project, path)
	if message == "" do state.session.assetsChanged = true
	if message != "" {
		logLine(state, .Error, fmt.aprintf("Import failed: %s", message))
		return
	}
	asset := state.project.assets[index]
	logLine(state, .Info, fmt.aprintf("Imported %s (Save to keep it in the project)", asset.path))
	state.browserOpen[AssetFolder(asset.kind)] = true
	selectAsset(state, index)
}

// Selects an asset in the browser; a sound gets loaded for the preview panel
@(private="file")
selectAsset :: proc(state: ^State, index: int) {
	asset := state.project.assets[index]
	state.browserSelection = {kind = .Asset, folder = AssetFolder(asset.kind), index = index}
	if asset.kind == .Audio {
		if message := AudioPreview_Load(AssetFilePath(&state.project, asset)); message != "" {
			logLine(state, .Warning, fmt.aprintf("Audio preview: %s", message))
		}
	} else {
		AudioPreview_Unload()
	}
}

// Adds a node from the Add Node dialog and closes it
@(private="file")
addNodeOfKind :: proc(state: ^State, kind: NodeKind) {
	index := AddNode_Create(state, kind)
	state.addNode.open = false
	scene := &state.project.scenes[state.currentScene]
	logLine(state, .Info, fmt.aprintf("Added %s to %s", scene.nodes[index].name, scene.name))
}

// A timer for the next viewport animation frame, due 1 / VIEWPORT_ANIMATION_FPS after the last one
@(private="file")
nextViewportTick :: proc(v: ^ViewportState) -> skald.Command(Msg) {
	period := time.Second / VIEWPORT_ANIMATION_FPS
	now := time.tick_now()
	v.nextTick = time.tick_add(v.nextTick, period)
	wait := time.tick_diff(now, v.nextTick)
	// Fell behind (a slow frame, a stall): start again from now
	if wait <= 0 {
		v.nextTick = time.tick_add(now, period)
		wait = period
	}
	return skald.cmd_delay(f32(time.duration_seconds(wait)), Msg(Viewport_Tick{}))
}

// Starts renaming a node in place in the scene tree, and selects it
@(private="file")
startRename :: proc(state: ^State, index: int) {
	scene := &state.project.scenes[state.currentScene]
	if index < 0 || index >= len(scene.nodes) do return
	delete(state.rename.text)
	state.rename = {active = true, node = index, text = strings.clone(scene.nodes[index].name)}
	state.selectedNode = index
}

// "Spaceship", or "3 nodes" (temp allocated)
@(private="file")
describeNodes :: proc(scene: ^SceneDef, nodes: []int) -> string {
	if len(nodes) == 1 do return scene.nodes[nodes[0]].name
	return fmt.tprintf("%d nodes", len(nodes))
}

@(private="file")
slice_index :: proc(values: []int, value: int) -> int {
	for v, i in values do if v == value do return i
	return -1
}

// Selects the nodes inside a box drag's rectangle (their bounds overlap it, or their marker is in it)
@(private="file")
boxSelect :: proc(state: ^State, drag: ViewportDrag) {
	lo := [2]f32{min(drag.startMouse.x, drag.current.x), min(drag.startMouse.y, drag.current.y)}
	hi := [2]f32{max(drag.startMouse.x, drag.current.x), max(drag.startMouse.y, drag.current.y)}
	// A click without a drag
	if hi.x - lo.x < 1e-3 && hi.y - lo.y < 1e-3 do return
	hits := ViewportNodesInRect(state, lo, hi)
	nodes := make([dynamic]int, context.temp_allocator)
	if drag.additive do append(&nodes, ..state.selection[:])
	append(&nodes, ..hits)
	if len(nodes) == 0 {
		state.selectedNode = -1
		return
	}
	Selection_Set(state, nodes[:], len(hits) > 0 ? hits[len(hits) - 1] : -1)
}

/*
The other axis of a linked X/Y pair after one axis changed from `old` to `new`: scaled by the same
ratio, so 2 x 1 becomes 4 x 2. When either is 0 there's no ratio, so it moves by the same amount.
*/
LinkedAxis :: proc(old, new, other: f32) -> f32 {
	if abs(old) < 1e-6 || abs(other) < 1e-6 do return other + (new - old)
	return other * (new / old)
}
