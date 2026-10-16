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
	info := History_Classify(&state, m)
	if info.scope == .None do return applyMsg(s, m)
	snap := History_Snapshot(&state, info)
	out, command := applyMsg(s, m)
	History_Commit(&out, snap, time.tick_now())
	return out, command
}

@(private="file")
applyMsg :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	if command, handled := SettingsDialog_Update(&out, m); handled do return out, command
	layout := &out.layout

	switch v in m {
	case Action:
		return handleAction(out, v)
	case Play_Tick:
		cmd := playTick(&out)
		return out, cmd
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
		if message := Project_RemoveAsset(&out.project, index, v.deleteFile); message != "" {
			logLine(&out, .Error, fmt.aprintf("%s", message))
		} else {
			logLine(&out, .Info, fmt.aprintf("%s %s%s", v.deleteFile ? "Deleted" : "Removed", name,
				usage > 0 ? fmt.tprintf(" (still used by %d node%s)", usage, usage == 1 ? "" : "s") : ""))
		}
		out.browserSelection = {kind = .None}
	case Asset_Remove_Cancelled:
		out.removeConfirm = {}

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
		drag := ViewportDrag{mode = v.mode, node = v.node, startMouse = v.mouse}
		if v.mode != .Pan {
			scene := &out.project.scenes[out.currentScene]
			if v.node < 0 || v.node >= len(scene.nodes) do break
			out.selectedNode = v.node
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
		if drag.mode == .None || drag.mode == .Pan || drag.node < 0 || drag.node >= len(scene.nodes) do break
		Viewport_ApplyDrag(&scene.nodes[drag.node], drag, v.mouse, v.constrain)
	case Viewport_Drag_End:
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
	case Node_Selected:
		rows := SceneTreeRows(&out.project.scenes[out.currentScene])
		if int(v) < len(rows) do out.selectedNode = rows[v]
	case Node_Picked:
		out.selectedNode = int(v)
	case Node_Right_Clicked:
		rows := SceneTreeRows(&out.project.scenes[out.currentScene])
		out.selectedNode = int(v) >= 0 && int(v) < len(rows) ? rows[v] : -1

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
	case Node_Field_Changed:
		node := selectedNode(&out)
		if node == nil do break
		value := f32(v.value)
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
			node.texture = strings.clone(v.value)
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
		// Don't leave a game running after the editor closes
		playStop(&out)
		return out, skald.cmd_quit(Msg)

	case .Save_Project:
		if message := Project_Save(&out.project); message != "" {
			logLine(&out, .Error, fmt.aprintf("Save failed: %s", message))
		} else {
			logLine(&out, .Info, fmt.aprintf("Saved to %s", out.project.rootPath))
		}
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
	case .Duplicate_Node:
		if selectedNode(&out) == nil do break
		scene := &out.project.scenes[out.currentScene]
		out.selectedNode = Scene_DuplicateNode(scene, out.selectedNode)
		logLine(&out, .Info, fmt.aprintf("Duplicated as %s", scene.nodes[out.selectedNode].name))
	case .Copy_Node, .Cut_Node:
		node := selectedNode(&out)
		if node == nil do break
		Subtree_Destroy(&out.clipboard)
		out.clipboard = Scene_CopySubtree(&out.project.scenes[out.currentScene], out.selectedNode)
		if action == .Copy_Node {
			logLine(&out, .Info, fmt.aprintf("Copied %s", node.name))
			break
		}
		logLine(&out, .Info, fmt.aprintf("Cut %s", node.name))
		Scene_RemoveNode(&out.project.scenes[out.currentScene], out.selectedNode)
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
		out.selectedNode = Scene_PasteSubtree(scene, out.clipboard[:], parent)
		logLine(&out, .Info, fmt.aprintf("Pasted %s", scene.nodes[out.selectedNode].name))

	case .Delete_Node:
		if out.selectedNode < 0 do break
		scene := &out.project.scenes[out.currentScene]
		logLine(&out, .Info, fmt.aprintf("Deleted %s", scene.nodes[out.selectedNode].name))
		Scene_RemoveNode(scene, out.selectedNode)
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
		// The nudge is in world units; convert it into the parent's space
		node := &scene.nodes[out.selectedNode]
		if node.parent >= 0 {
			delta = e.Transform2D_ApplyVector(e.Transform2D_Inverse(Scene_WorldTransforms(scene)[node.parent]), delta)
		}
		node.position += delta

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
	case .Open_Settings:
		SettingsDialog_Open(&out)
	case .New_Project, .Open_Project, .Export, .About:
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
