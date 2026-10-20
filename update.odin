package editor

import "core:fmt"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
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
	// The inspector shows a data resource chosen in the browser, until a node is selected
	if out.browserSelection != state.browserSelection && out.browserSelection.kind == .Asset &&
	   out.browserSelection.index < len(out.project.assets) && out.project.assets[out.browserSelection.index].kind == .Data {
		out.dataSelection = Project_FindData(&out.project, out.project.assets[out.browserSelection.index].path)
	}
	if out.selectedNode >= 0 && out.selectedNode != state.selectedNode do out.dataSelection = -1
	if out.dataSelection >= len(out.project.data) do out.dataSelection = -1
	// Anything that opens another scene shows it (not a code tab), in its tab
	if out.currentScene != state.currentScene {
		out.codeTab = 0
		if out.currentScene >= 0 && out.currentScene < len(out.project.scenes) do out.project.scenes[out.currentScene].tabClosed = false
	}
	// A structural edit renumbers nodes: the old multi-selection is meaningless unless the edit
	// chose a new one. Then make the selection agree with selectedNode (selection.odin)
	if (info.scope == .Scene || info.scope == .Project) && !out.selectionSet do clear(&out.selection)
	Selection_Normalize(&out)
	if info.scope != .None do History_Commit(&out, snap, time.tick_now())
	return out, command
}

@(private="file")
applyMsg :: proc(s: State, m: Msg) -> (State, skald.Command(Msg)) {
	out := s
	if command, handled := SettingsDialog_Update(&out, m); handled do return out, command
	if command, handled := Session_Update(&out, m); handled do return out, command
	if command, handled := ProjectArchive_Update(&out, m); handled do return out, command
	if command, handled := Git_Update(&out, m); handled do return out, command
	if command, handled := LDtkEdit_Update(&out, m); handled do return out, command
	if command, handled := ProjectSettings_Update(&out, m); handled do return out, command
	if command, handled := AnimEdit_Update(&out, m); handled do return out, command
	if command, handled := CodeTabs_Update(&out, m); handled do return out, command
	if Mixer_Update(&out, m) do return out, {}
	layout := &out.layout

	switch v in m {
	case Action:
		return handleAction(out, v)
	case Play_Tick:
		cmd := playTick(&out)
		return out, cmd
	case Export_Tick:
		return out, exportTick(&out)
	case Export_Requested:
		return out, Export_Start(&out, bit_set[ExportTarget](v))
	case Settings_Code_Editor_Path_Changed, Settings_Code_Editor_Args_Changed, Settings_Code_Editor_Browse,
	     Settings_Code_Editor_Picked, Settings_Optimized_Play_Changed, Settings_Wheel_Pans_Changed, Settings_Builtin_Editor_Changed, Settings_OLS_Path_Changed, Settings_Odin_Path_Changed, Settings_LDtk_Path_Changed:
		// Handled by SettingsDialog_Update above

	case Anim_Selected, Anim_Added, Anim_Duplicated, Anim_Removed, Anim_Moved, Anim_Name_Typed, Anim_Field_Changed,
	     Anim_Loop_Changed, Anim_Mode_Changed, Anim_Autoplay_Set, Anim_Frame_Clicked, Anim_Playback_Toggled,
	     Anim_Tick, Anim_Tick_Requested:
		// Handled by AnimEdit_Update above
	case Input_New_Name_Changed, Input_Action_Added, Input_Defaults_Added, Input_Action_Selected, Input_Action_Removed,
	     Input_Action_Moved, Input_Action_Renamed, Input_Deadzone_Changed, Input_Binding_Added, Input_Binding_Removed,
	     Input_Capture_Started, Input_Capture_Cancelled, Input_Device_Changed:
		// Handled by ProjectSettings_Update above
	case Code_Tab_Selected, Code_Tab_Close_Requested, Code_Close_Chosen, Code_Open_Requested, Code_Save_Requested,
	     Code_Tick_Requested, Code_Tick, Code_Focused, Code_Reloaded, Code_Disk_Chosen,
	     Code_Dialog_Requested, Code_Dialog_Picked:
		// Handled by CodeTabs_Update above
	case Bus_Added, Bus_Removed, Bus_Renamed, Bus_Volume_Changed, Bus_Pan_Changed, Bus_Mute_Toggled:
		// Handled by Mixer_Update above
	case Audio_Field_Changed:
		node := selectedNode(&out)
		if node == nil || !isSoundKind(node.kind) do break
		a := &node.audio
		switch v.field {
		case .Volume:       a.volume = clamp(v.value, 0, 2)
		case .Pitch:        a.pitch = clamp(v.value, 0.1, 4)
		case .Pan:          a.pan = clamp(v.value, -1, 1)
		case .Max_Distance: a.maxDistance = max(v.value, 1)
		case .Attenuation:  a.attenuation = clamp(v.value, 0.1, 8)
		case .Fade_In:      a.fadeIn = max(v.value, 0)
		case .Fade_Out:     a.fadeOut = max(v.value, 0)
		}
	case Audio_Flag_Changed:
		node := selectedNode(&out)
		if node == nil || !isSoundKind(node.kind) do break
		switch v.flag {
		case .Loop:      node.audio.loop = v.value
		case .Autostart: node.audio.autostart = v.value
		}
	case Audio_Preview_Requested:
		node := selectedNode(&out)
		if !bool(v) || node == nil || node.sound == "" {
			AudioPreview_Stop()
			break
		}
		path := joinPath(out.project.rootPath, node.sound, allocator = context.temp_allocator)
		if !AudioPreview_IsLoaded(path) {
			if message := AudioPreview_Load(path); message != "" {
				logLine(&out, .Warning, fmt.aprintf("Preview: %s", message))
				break
			}
		}
		AudioPreview_SetSettings(node.audio.volume, node.audio.pitch, node.audio.pan)
		Mixer_RoutePreview(&out.project, node.bus)
		AudioPreview_Play()
	case Asset_Kind_Changed:
		if v.index < 0 || v.index >= len(out.project.assets) do break
		asset := &out.project.assets[v.index]
		if (asset.kind != .Audio && asset.kind != .Music) || (v.kind != .Audio && v.kind != .Music) do break
		asset.kind = v.kind
		out.session.assetsChanged = true
		out.browserSelection = {kind = .Asset, folder = AssetFolder(v.kind), index = v.index}
		out.browserOpen[AssetFolder(v.kind)] = true
		logLine(&out, .Info, fmt.aprintf("%s is %s now", filepath.base(asset.path), v.kind == .Music ? "music (streamed)" : "a sound"))
		if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(&out, .Warning, strings.clone(message))
	case Toolchain_Install_Requested:
		if out.toolchainInstalling do break
		out.toolchainInstalling = true
		logLine(&out, .Info, fmt.aprintf("Installing Odin %s (about 70 MB)...", ODIN_VERSION))
		return out, Toolchain_InstallOdin()
	case Toolchain_Install_Finished:
		out.toolchainInstalling = false
		if v.problem != "" {
			logLine(&out, .Error, fmt.aprintf("Installing Odin failed: %s", v.problem))
			delete(v.problem)
		} else {
			logLine(&out, .Info, fmt.aprintf("Installed Odin %s: %s", ODIN_VERSION, v.path))
			delete(v.path)
		}
	case Open_Keyboard_Settings:
		SettingsDialog_Open(&out)
		out.settingsDialog.tab = .Keyboard

	case Scripts_Auto_Build:
		if out.scriptsAutoBuilt do break
		out.scriptsAutoBuilt = true
		return out, scriptsBuild(&out)
	case Node_Script_Changed:
		node := selectedNode(&out)
		if node == nil do break
		name := string(v) == TEXTURE_NONE ? "" : string(v)
		if name == node.script do break
		delete(node.script)
		node.script = strings.clone(name)
		// Values belonged to the old script
		for prop in node.props { delete(prop.name); delete(prop.value) }
		clear(&node.props)
		logLine(&out, .Info, name == "" ? fmt.aprintf("Removed the script from %s", node.name) : fmt.aprintf("Attached %s to %s", name, node.name))
	case New_Script_Kind_Changed:
		out.newScript.kind = ScriptKind(v)
	case New_Data_Opened:
		delete(out.newData.name)
		delete(out.newData.type)
		first := len(out.scripts.dataTypes) > 0 ? out.scripts.dataTypes[0].name : ""
		out.newData = {open = true, name = strings.clone(""), type = strings.clone(first)}
	case New_Data_Name_Changed:
		delete(out.newData.name)
		out.newData.name = strings.clone(string(v))
	case New_Data_Type_Changed:
		delete(out.newData.type)
		out.newData.type = strings.clone(string(v))
	case New_Data_Cancelled:
		out.newData.open = false
	case New_Data_Created:
		index, problem := Project_CreateData(&out.project, out.newData.name, out.newData.type)
		if problem != "" {
			logLine(&out, .Error, fmt.aprintf("New data resource: %s", problem))
			break
		}
		out.newData.open = false
		out.session.assetsChanged = true
		out.browserOpen[.Data] = true
		out.dataSelection = index
		for asset, i in out.project.assets do if asset.path == out.project.data[index].path do out.browserSelection = {kind = .Asset, folder = .Data, index = i}
		if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(&out, .Warning, strings.clone(message))
		logLine(&out, .Info, fmt.aprintf("Created %s (%s)", out.project.data[index].path, out.project.data[index].type))
	case Script_Prop_Changed:
		switch t in v.target {
		case SelectedNodeTarget:
			if node := selectedNode(&out); node != nil do NodeDef_SetScriptValue(node, v.name, v.value, v.defaultValue)
		case DraftGlobalTarget:
			globals := &out.projectSettings.globals
			if int(t) >= 0 && int(t) < len(globals) do Props_Set(&globals[t].props, v.name, v.value, v.defaultValue)
		case DataTarget:
			if int(t) >= 0 && int(t) < len(out.project.data) do Props_Set(&out.project.data[t].values, v.name, v.value, v.defaultValue)
		}
	case Script_Open_File:
		return out, Script_Open(&out, v.file, v.line)
	case Editor_Process_Check:
		return out, Editor_CheckProcesses(&out)
	case New_Script_Opened:
		delete(out.newScript.name)
		out.newScript = {open = true, name = strings.clone(""), kind = out.newScript.kind}
	case New_Script_Name_Changed:
		delete(out.newScript.name)
		out.newScript.name = strings.clone(string(v))
	case New_Script_Cancelled:
		out.newScript.open = false
	case New_Script_Created:
		name := strings.trim_space(out.newScript.name)
		kind := out.newScript.kind
		file, message := Project_CreateScript(&out.project, name, kind)
		if message != "" {
			logLine(&out, .Error, fmt.aprintf("New script: %s", message))
			break
		}
		out.newScript.open = false
		Scripts_Refresh(&out)
		logLine(&out, .Info, fmt.aprintf("Created %s", file))
		switch kind {
		case .Node:
			// Attach it to the selected node, open it, and build so its fields show up
			if node := selectedNode(&out); node != nil {
				delete(node.script)
				node.script = strings.clone(name)
			}
		case .Global:
			// Runs for the whole game from the next Play (Project Settings > Globals lists it)
			append(&out.project.globals, GlobalDef{script = strings.clone(name)})
		case .Data:
		}
		path, line := Script_Location(&out, name)
		return out, skald.cmd_batch(Script_Open(&out, path, line), scriptsBuild(&out))

	case Project_Settings_Name_Changed, Project_Settings_Scale_Changed, Project_Settings_Renderer_Changed, Project_Settings_Background_Changed,
	     Project_Settings_Start_Changed, Project_Settings_Locale_Changed, Project_Settings_Size_Changed, Project_Settings_Applied, Project_Settings_Cancelled,
	     Project_Settings_Tab_Changed, Export_Target_Selected, Export_Target_Enabled, Export_Text_Changed, Export_Flag_Changed,
	     Export_Target_Run, Export_Cancel_Requested, Project_Settings_Physics_Changed, Project_Settings_Physics_Debug_Changed,
	     Project_Settings_Physics_Smoothing_Changed, Project_Settings_Window_Changed, Global_Added, Global_Removed, Global_Selected, Global_Moved:
		// Handled by ProjectSettings_Update above
	case Scene_Action:
		return out, Scene_DoAction(&out, v)
	case Browser_Focus_Changed:
		out.browserFocused = bool(v)
	case Browser_Right_Clicked:
		// Select the row (without opening a scene), so the context menu acts on it
		rows := BrowserRows(&out)
		out.browserSelection = int(v) >= 0 && int(v) < len(rows) ? rows[v] : BrowserItem{kind = .None}
	case Confirm_Chosen, New_Project_Name_Changed, New_Project_Location_Changed, New_Project_Browse,
	     New_Project_Location_Chosen, New_Project_Created, New_Project_Cancelled, Open_Project_Chosen:
		// Handled by Session_Update above
	case Project_Archive_Path_Chosen, Project_Archive_Open_Chosen, Project_Archive_Destination_Chosen,
	     Project_Archive_Written, Project_Archive_Extracted:
		// Handled by ProjectArchive_Update above
	case LDtk_Setting_Changed, LDtk_Open_Requested, LDtk_Asset_Open_Requested:
		// Handled by LDtkEdit_Update above
	case Git_Refresh_Requested, Git_Snapshot_Read, Git_Op_Requested, Git_Op_Finished, Git_Message_Changed,
	     Git_New_Branch_Changed, Git_Remote_URL_Changed:
		// Handled by Git_Update above
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
		// A component's SceneDef goes too: the viewport and the undo steps leave it
		if component := Project_FindComponent(&out.project, asset.path); component >= 0 {
			if out.currentScene == component do openScene(&out, Project_FirstScene(&out.project))
			if out.currentScene > component do out.currentScene -= 1
			History_SceneRemoved(&out.history, component)
		}
		if message := Project_RemoveAsset(&out.project, index, v.deleteFile); message != "" {
			logLine(&out, .Error, fmt.aprintf("%s", message))
		} else {
			logLine(&out, .Info, fmt.aprintf("%s %s%s", v.deleteFile ? "Deleted" : "Removed", name,
				usage > 0 ? fmt.tprintf(" (still used by %d node%s)", usage, usage == 1 ? "" : "s") : ""))
		}
		out.browserSelection = {kind = .None}
		if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(&out, .Warning, strings.clone(message))
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
		// After Enter, keys go back to the tree the rename was in (not after a click elsewhere)
		if v.byKey do out.refocus = out.rename.target != .Node ? .Browser : .Scene_Tree
		if out.rename.active && out.rename.target == .Component {
			old := ""
			if out.rename.node >= 0 && out.rename.node < len(out.project.assets) do old = strings.clone(ComponentName(out.project.assets[out.rename.node].path), context.temp_allocator)
			references, message := Project_RenameComponent(&out.project, out.rename.node, out.rename.text)
			if message != "" {
				logLine(&out, .Error, fmt.aprintf("Can't rename %s: %s", old, message))
			} else if old != strings.trim_space(out.rename.text) {
				out.session.assetsChanged = true
				logLine(&out, .Info, fmt.aprintf("Renamed component %s to %s (%d instance%s updated)", old, strings.trim_space(out.rename.text), references, references == 1 ? "" : "s"))
				if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(&out, .Warning, strings.clone(message))
			}
			delete(out.rename.text)
			out.rename = {}
			break
		}
		if out.rename.active && out.rename.target == .Scene {
			Scene_CommitRename(&out)
			delete(out.rename.text)
			out.rename = {}
			break
		}
		scene := &out.project.scenes[out.currentScene]
		index, text := out.rename.node, strings.trim_space(out.rename.text)
		if out.rename.active && index >= 0 && index < len(scene.nodes) && text != "" && text != scene.nodes[index].name {
			logLine(&out, .Info, fmt.aprintf("Renamed %s to %s", scene.nodes[index].name, text))
			if isBodyKind(scene.nodes[index].kind) do Scene_RenameJointReferences(scene, scene.nodes[index].name, text)
			delete(scene.nodes[index].name)
			scene.nodes[index].name = strings.clone(text)
		}
		delete(out.rename.text)
		out.rename = {}
	case Rename_Cancelled:
		out.refocus = out.rename.target != .Node ? .Browser : .Scene_Tree
		delete(out.rename.text)
		out.rename = {}
	case Refocus_Done:
		out.refocus = .None
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
		Export_Cancel(&out)
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
		if asset >= 0 && asset < len(out.project.assets) && out.project.assets[asset].kind == .Component {
			addInstance(&out, out.project.assets[asset].path, v.world)
			break
		}
		if asset >= 0 && asset < len(out.project.assets) && out.project.assets[asset].kind == .LDtk {
			index := Scene_AddLDtkAt(&out.project.scenes[out.currentScene], out.project.assets[asset].path, out.selectedNode, v.world)
			out.selectedNode = index
			logLine(&out, .Info, fmt.aprintf("Added %s, a level of %s", out.project.scenes[out.currentScene].nodes[index].name, filepath.base(out.project.assets[asset].path)))
			break
		}
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
		if out.addNode.highlight < len(kinds) do addNodeChosen(&out, kinds[out.addNode.highlight])
	case Add_Node_Kind_Chosen:
		addNodeChosen(&out, NodeKind(v))
	case Add_Node_Cancelled:
		out.addNode.open = false

	case Viewport_Measured:
		out.viewport.size = cast([2]f32)v
		if out.viewport.zoom == 0 do Viewport_Fit(&out.viewport, out.project.gameSize)
	case Viewport_Content_Measured:
		if out.viewport.fitContent && out.viewport.size.x > 0 {
			out.viewport.fitContent = false
			Viewport_FitRect(&out.viewport, cast([4]f32)v)
		}
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
		// What git says may have changed since it was read
		if out.bottomTab == .Git do return out, Git_Refresh(&out)
	case Scene_Tab_Changed:
		out.codeTab = 0
		tabs := ViewportTabScenes(&out)
		if int(v) >= 0 && int(v) < len(tabs) do openScene(&out, tabs[v])
	case Scene_Tab_Closed:
		tabs := ViewportTabScenes(&out)
		if int(v) < 0 || int(v) >= len(tabs) || len(tabs) < 2 do break
		index := tabs[v]
		scene := &out.project.scenes[index]
		if Scene_IsComponent(scene) do scene.opened = false
		else do scene.tabClosed = true
		// The tab that shows closes: its neighbour shows instead
		if index == out.currentScene {
			next := int(v) + 1 < len(tabs) ? tabs[v + 1] : tabs[v - 1]
			out.codeTab = 0
			openScene(&out, next)
		}
	case Component_Opened:
		if int(v) < 0 || int(v) >= len(out.project.scenes) || !Scene_IsComponent(&out.project.scenes[v]) do break
		out.project.scenes[v].opened = true
		openScene(&out, int(v))
	case Component_Rename_Started:
		if int(v) < 0 || int(v) >= len(out.project.assets) || out.project.assets[v].kind != .Component do break
		delete(out.rename.text)
		out.rename = {active = true, target = .Component, node = int(v), text = strings.clone(ComponentName(out.project.assets[v].path))}
		out.browserSelection = {kind = .Asset, folder = .Components, index = int(v)}
		out.browserOpen[.Components] = true
	case Component_Made_Unique:
		old := ""
		if node := selectedNode(&out); node != nil do old = strings.clone(ComponentName(node.component), context.temp_allocator)
		path, message := Scene_MakeInstanceUnique(&out.project, out.currentScene, out.selectedNode)
		if message != "" {
			logLine(&out, .Error, fmt.aprintf("Can't make it unique: %s", message))
			break
		}
		out.session.assetsChanged = true
		logLine(&out, .Info, fmt.aprintf("This instance has its own copy of %s now: %s", old, path))
		if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(&out, .Warning, strings.clone(message))
	case Component_New:
		// The Add Node dialog picks its root's kind (newComponent makes it)
		delete(out.addNode.search)
		out.addNode = {open = true, forComponent = true}
	case Component_Instance_Added:
		if int(v) < 0 || int(v) >= len(out.project.assets) || out.project.assets[v].kind != .Component do break
		// At the selected node's origin (inside it), else the middle of the view
		world := out.viewport.center
		if out.selectedNode >= 0 && out.selectedNode < len(out.project.scenes[out.currentScene].nodes) {
			world = Scene_WorldTransforms(&out.project.scenes[out.currentScene])[out.selectedNode].origin
		}
		addInstance(&out, out.project.assets[v].path, world)
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
		case .Script:
			// The preview shows its source; a double-click opens it (view_browser.odin's browserMouse)
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
			// Joints follow a renamed body
			if isBodyKind(node.kind) do Scene_RenameJointReferences(&out.project.scenes[out.currentScene], node.name, string(v))
			// Msg strings only live for the frame (see Skald's gotchas), so keep a copy
			delete(node.name)
			node.name = strings.clone(string(v))
		}
	case Node_Visibility_Changed:
		if node := selectedNode(&out); node != nil do node.visible = bool(v)
	case Inspector_Link_Toggled:
		out.inspectorLinks[LinkedPair(v)] = !out.inspectorLinks[LinkedPair(v)]
	case Particle_Field_Changed:
		if node := selectedNode(&out); node != nil && node.kind == .ParticleEmitter do e.ParticleSettings_Set(&node.particles, v.name, v.value)
	case Particle_Axis_Changed:
		node := selectedNode(&out)
		if node == nil || node.kind != .ParticleEmitter || v.axis < 0 || v.axis > 1 do break
		ParticleSettings_SetAxis(&node.particles, v.name, v.axis, v.value, ParticleField_Index(v.name) in out.particleLinks)
	case Particle_Link_Toggled:
		if int(v) >= 0 && int(v) < 64 do out.particleLinks ~= {int(v)}
	case Particles_Reset:
		node := selectedNode(&out)
		if node == nil || node.kind != .ParticleEmitter do break
		node.particles = e.DEFAULT_PARTICLE_SETTINGS
		delete(node.texture)
		node.texture = strings.clone("")
	case Ramp_Edited:
		node := selectedNode(&out)
		if node == nil || node.kind != .ParticleEmitter do break
		if e.ParticleSettings_Set(&node.particles, "colorRamp", v.text) do out.rampStop = v.selected
	case Ramp_Stop_Selected:
		out.rampStop = int(v)
	case Ramp_Drag_Changed:
		out.rampDragging = bool(v)
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
		case .Z_Index:    node.zIndex = i32(clamp(v.value, -1_000_000, 1_000_000))
		case .Font_Size:  node.fontSize = max(value, 1)
		case .Zoom:       node.zoom = max(value, 0.05)
		case .Columns:    node.columns = max(int(v.value), 1)
		case .Rows:       node.rows = max(int(v.value), 1)
		case .Margin:     node.margin = max(value, 0)
		case .Spacing:    node.spacing = max(value, 0)
		case .Friction:        node.friction = max(value, 0)
		case .Restitution:     node.restitution = clamp(value, 0, 1)
		case .Density:         node.density = max(value, 0)
		case .Gravity_Scale:   node.gravityScale = value
		case .Linear_Damping:  node.linearDamping = max(value, 0)
		case .Angular_Damping: node.angularDamping = max(value, 0)
		case .Floor_Max_Angle: node.floorMaxAngle = clamp(value, 0, 89)
		case .Shape_Width:     node.shapeSize.x = max(value, 1)
		case .Shape_Height:    node.shapeSize.y = max(value, 1)
		case .Radius:          node.radius = max(value, 0.5)
		case .Target_X:        node.target.x = value
		case .Target_Y:        node.target.y = value
		case .Offset_X:        node.jointOffset.x = value
		case .Offset_Y:        node.jointOffset.y = value
		case .Lower:           node.lower = value
		case .Upper:           node.upper = value
		case .Motor_Speed:     node.motorSpeed = value
		case .Max_Motor:       node.maxMotor = max(value, 0)
		case .Hertz:           node.hertz = max(value, 0)
		case .Damping:         node.dampingRatio = max(value, 0)
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
		case .Sound:
			delete(node.sound)
			node.sound = strings.clone(v.value == TEXTURE_NONE ? "" : v.value)
		case .Bus:
			delete(node.bus)
			node.bus = strings.clone(v.value == e.MASTER_BUS ? "" : v.value)
		case .Component:
			path := v.value == TEXTURE_NONE ? "" : v.value
			current := &out.project.scenes[out.currentScene]
			if path != "" && Component_Contains(&out.project, path, current.component) {
				logLine(&out, .Warning, fmt.aprintf("%s holds %s: an instance of it can't go inside it", ComponentName(path), current.name))
				break
			}
			delete(node.component)
			node.component = strings.clone(path)
		case .Autoplay:
			delete(node.autoplay)
			node.autoplay = strings.clone(v.value == ANIMATION_FIRST ? "" : v.value)
		case .Shape:
			if shape, ok := reflect.enum_from_name(e.CollisionShapeKind, v.value); ok do node.shape = shape
		case .Process_Mode:
			if mode, ok := reflect.enum_from_name(e.ProcessMode, v.value); ok do node.processMode = mode
		case .Blend_Mode:
			if mode, ok := reflect.enum_from_name(e.BlendMode, v.value); ok do node.blendMode = mode
		case .Groups:
			delete(node.groups)
			node.groups = strings.clone(v.value)
		case .Joint_Kind:
			if kind, ok := reflect.enum_from_name(e.JointKind, v.value); ok do node.jointKind = kind
		case .Body_A:
			delete(node.bodyA)
			node.bodyA = strings.clone(v.value == JOINT_BODY_DEFAULT ? "" : v.value)
		case .Body_B:
			delete(node.bodyB)
			node.bodyB = strings.clone(v.value == JOINT_BODY_NONE ? "" : v.value)
		}
	case Node_Flag_Changed:
		node := selectedNode(&out)
		if node == nil do break
		switch v.flag {
		case .Centered:       node.centered = v.value
		case .Y_Sort:         node.ySort = v.value
		case .Fixed_Rotation: node.fixedRotation = v.value
		case .Bullet:         node.bullet = v.value
		case .Disabled:       node.disabled = v.value
		case .One_Way:        node.oneWay = v.value
		case .Enabled:        node.enabled = v.value
		case .Exclude_Parent: node.excludeParent = v.value
		case .Limit:          node.enableLimit = v.value
		case .Motor:          node.enableMotor = v.value
		case .Spring:         node.enableSpring = v.value
		case .Collide_Connected: node.collideConnected = v.value
		}
	case Node_Layer_Toggled:
		node := selectedNode(&out)
		if node == nil || v.layer < 1 || v.layer > 64 do break
		bits := v.mask ? &node.collisionMask : &node.collisionLayer
		bits^ ~= 1 << u64(v.layer - 1)
	case Node_Points_Changed:
		// Keep the typed text (like a number field), apply it when every point reads
		delete(out.numberEdit.text)
		out.numberEdit = {id = v.id, text = strings.clone(v.text)}
		node := selectedNode(&out)
		points, ok := e.ParsePoints(v.text)
		if node == nil || !ok do break
		clear(&node.points)
		append(&node.points, ..points)
	}
	return out, {}
}

@(private="file")
handleAction :: proc(s: State, action: Action) -> (State, skald.Command(Msg)) {
	out := s
	// With the browser focused, Delete, Ctrl+D/C/X/V and F2 act on its selected scene
	if sceneAction, routed := Browser_RouteAction(&out, action); routed {
		return out, Scene_DoAction(&out, sceneAction)
	}
	switch action {
	case .Quit:
		return out, Session_Request(&out, .Quit)
	case .New_Project:
		return out, Session_Request(&out, .New_Project)
	case .Open_Project:
		return out, Session_Request(&out, .Open_Project)
	case .Open_Project_Archive:
		return out, Session_Request(&out, .Open_Project_Archive)
	case .Export_Project_Archive:
		return out, ProjectArchive_Export(&out)
	case .Export_Project_Archive_With_History:
		return out, ProjectArchive_Export(&out, includeGit = true)

	case .Save_Project:
		// Saved scripts are built again in the background: the inspector learns new fields
		scripts := CodeTabs_AnyDirty(&out)
		if Session_Save(&out) && scripts do return out, scriptsBuildQuietly(&out)
	case .Play:
		cmd := playStart(&out)
		return out, cmd
	case .Play_Scene:
		if Scene_IsComponent(&out.project.scenes[out.currentScene]) {
			logLine(&out, .Warning, strings.clone("A component can't play on its own: play a scene that has an instance of it"))
			break
		}
		return out, playStart(&out, out.project.scenes[out.currentScene].name)
	case .Save_As_Component:
		name := out.selectedNode >= 0 && out.selectedNode < len(out.project.scenes[out.currentScene].nodes) ? strings.clone(out.project.scenes[out.currentScene].nodes[out.selectedNode].name, context.temp_allocator) : ""
		index, message := Scene_SaveBranchAsComponent(&out.project, out.currentScene, out.selectedNode)
		if message != "" {
			logLine(&out, .Error, fmt.aprintf("Can't save as a component: %s", message))
			break
		}
		out.session.assetsChanged = true
		clear(&out.selection)
		logLine(&out, .Info, fmt.aprintf("Saved %s as component %s; it's an instance of it now", name, out.project.scenes[index].component))
		if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(&out, .Warning, strings.clone(message))
	case .Open_Project_Settings:
		ProjectSettings_Open(&out)
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
	case .Toggle_Collision_Shapes:
		out.viewport.showShapes = !out.viewport.showShapes
	case .Toggle_Physics_Debug:
		// A project setting (undoable, saved with the project); exports turn it off
		out.project.physics.debugDraw = !out.project.physics.debugDraw
		message := out.project.physics.debugDraw ? "The game shows its collision shapes (not in exports; F9 toggles them while playing)" : "The game hides its collision shapes (F9 shows them while playing)"
		logLine(&out, .Info, strings.clone(message))
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
	case .Tool_Pan:    out.tool = .Pan

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
			{"Images, audio, fonts, LDtk levels and translations", IMPORT_IMAGE_PATTERN + ";" + IMPORT_AUDIO_PATTERN + ";" + IMPORT_FONT_PATTERN + ";" + IMPORT_LDTK_PATTERN + ";" + IMPORT_TRANSLATION_PATTERN},
			{"Images", IMPORT_IMAGE_PATTERN},
			{"Audio", IMPORT_AUDIO_PATTERN},
			{"Fonts", IMPORT_FONT_PATTERN},
			{"LDtk projects", IMPORT_LDTK_PATTERN},
			{"Translations (CSV)", IMPORT_TRANSLATION_PATTERN},
		}
		return out, skald.cmd_open_file_dialog(filters[:], proc(r: skald.File_Dialog_Result) -> Msg { return Asset_Import_Result(r) })
	case .Remove_Asset:
		if out.browserSelection.kind == .Asset {
			out.removeConfirm = {open = true, asset = out.browserSelection.index}
		}
	case .Toggle_Preview_Panel:
		out.layout.previewOpen = !out.layout.previewOpen
	case .Play_Audio_Preview:
		// The browser's previews go to Master
		Mixer_RoutePreview(&out.project, "")
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
	case .Build_Scripts:
		Scripts_Refresh(&out)
		return out, scriptsBuild(&out)
	case .Open_Script:
		node := selectedNode(&out)
		if node == nil || node.script == "" {
			logLine(&out, .Info, strings.clone("The selected node has no script"))
			break
		}
		path, line := Script_Location(&out, node.script)
		return out, Script_Open(&out, path, line)
	case .Close_Code_Tab:
		if out.codeTab > 0 do return out, skald.cmd_now(Msg(Code_Tab_Close_Requested(out.codeTab - 1)))
	case .Open_Settings:
		SettingsDialog_Open(&out)
	case .Export:
		enabled: bit_set[ExportTarget]
		for t, target in out.project.exports.targets do if t.enabled do enabled += {target}
		return out, Export_Start(&out, enabled)
	case .About:
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
	// A component is usually much smaller than the game: the view fits what it draws, once the
	// preview has built it (the viewport sends Viewport_Content_Measured)
	state.viewport.fitContent = Scene_IsComponent(&state.project.scenes[index])
}

@(private="package")
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
	if message := Scripts_WriteAssetsFile(&state.project); message != "" do logLine(state, .Warning, strings.clone(message))
	state.browserOpen[AssetFolder(asset.kind)] = true
	selectAsset(state, index)
}

// Selects an asset in the browser; a sound gets loaded for the preview panel
@(private="file")
selectAsset :: proc(state: ^State, index: int) {
	asset := state.project.assets[index]
	state.browserSelection = {kind = .Asset, folder = AssetFolder(asset.kind), index = index}
	if asset.kind == .Audio || asset.kind == .Music {
		if message := AudioPreview_Load(AssetFilePath(&state.project, asset)); message != "" {
			logLine(state, .Warning, fmt.aprintf("Audio preview: %s", message))
		}
	} else {
		AudioPreview_Unload()
	}
}

// Adds an instance of a component to the open scene at a world point, under the selection, and selects it
@(private="file")
addInstance :: proc(state: ^State, path: string, world: [2]f32) {
	index, message := Scene_AddInstanceAt(&state.project, state.currentScene, path, state.selectedNode, world)
	if message != "" {
		logLine(state, .Warning, fmt.aprintf("Can't add it here: %s", message))
		return
	}
	clear(&state.selection)
	state.selectedNode = index
	logLine(state, .Info, fmt.aprintf("Added %s", state.project.scenes[state.currentScene].nodes[index].name))
}

// Adds a node from the Add Node dialog and closes it
// The Add Node dialog's choice (a click or Enter): a node for the scene, or a new component's root
@(private="file")
addNodeChosen :: proc(state: ^State, kind: NodeKind) {
	if state.addNode.forComponent {
		state.addNode.open = false
		newComponent(state, kind)
	} else {
		addNodeOfKind(state, kind)
	}
}

// A new component with a root of `kind`, named after it, opened in its tab (New Component)
@(private="file")
newComponent :: proc(state: ^State, kind: NodeKind) {
	index, message := Project_NewComponent(&state.project, fmt.tprint(kind), kind)
	if message != "" {
		logLine(state, .Error, fmt.aprintf("Couldn't make a component: %s", message))
		return
	}
	state.session.assetsChanged = true
	state.project.scenes[index].opened = true
	openScene(state, index)
	state.selectedNode = 0
	logLine(state, .Info, fmt.aprintf("Made component %s (%s)", state.project.scenes[index].name, state.project.scenes[index].component))
	if message := Scripts_WriteAssetsFile(&state.project); message != "" do logLine(state, .Warning, strings.clone(message))
}

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
/*
Sets one axis of an [2]f32 particle setting; with `linked`, the other axis follows in proportion
(`LinkedAxis`).
*/
ParticleSettings_SetAxis :: proc(settings: ^e.ParticleSettings, name: string, axis: int, value: f32, linked: bool) {
	text, found := e.ParticleSettings_Get(settings^, name)
	if !found do return
	xs, _, ys := strings.partition(text, ",")
	x, okX := strconv.parse_f32(strings.trim_space(xs))
	y, okY := strconv.parse_f32(strings.trim_space(ys))
	if !okX || !okY do return
	pair := [2]f32{x, y}
	if linked do pair[1 - axis] = LinkedAxis(pair[axis], value, pair[1 - axis])
	pair[axis] = value
	e.ParticleSettings_Set(settings, name, fmt.tprintf("%s,%s", formatSliderValue(pair.x, 4), formatSliderValue(pair.y, 4)))
}

// A particle setting's index in e.ParticleSettings_Fields (-1 if there's none by that name)
ParticleField_Index :: proc(name: string) -> int {
	for field, i in e.ParticleSettings_Fields() do if field.name == name do return i
	return -1
}

LinkedAxis :: proc(old, new, other: f32) -> f32 {
	if abs(old) < 1e-6 || abs(other) < 1e-6 do return other + (new - old)
	return other * (new / old)
}
