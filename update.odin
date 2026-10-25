package crossfire_editor

import "core:fmt"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
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
	// One copy of the State, changed in place (applyMsg takes a pointer): every State value in
	// this frame is 35 KB of stack in debug builds, and a Windows test thread has 1 MB
	out := s
	out.selectionSet = false
	// Also before: code outside update (tests, the test driver) may have set selectedNode alone
	Selection_Normalize(&out)
	// What the checks below compare with: the state before the message
	state := Update_Before{
		selectedNode = out.selectedNode,
		currentScene = out.currentScene,
		codeTab = out.codeTab,
		browserSelection = out.browserSelection,
		session = {opened = out.session.opened},
	}
	info := History_Classify(&out, m)
	snap: ^EditSnapshot
	if info.scope != .None do snap = History_Snapshot(&out, info)
	command := applyMsg(&out, m)
	// The Timeline follows the selected Animator; an edit elsewhere shows the scene as it is
	// again, not the clip at the playhead
	if info.scope != .None && !Timeline_IsEdit(m) do out.timeline.previewing = false
	Timeline_Follow(&out)
	States_Follow(&out)
	Particles_Follow(&out)
	// The Level mode's levels by iid after an LDtk step (a rename, an undo of one)
	isUndo := false
	if a, ok := m.(Action); ok do isUndo = a == .Undo || a == .Redo
	if info.scope == .Files || isUndo do LevelMode_Follow(&out)
	// The inspector shows a data resource chosen in the browser, until a node is selected
	if out.browserSelection != state.browserSelection && out.browserSelection.kind == .Asset &&
	   out.browserSelection.index < len(out.project.assets) && out.project.assets[out.browserSelection.index].kind == .Data {
		out.dataSelection = Project_FindData(&out.project, out.project.assets[out.browserSelection.index].path)
	}
	if out.selectedNode >= 0 && out.selectedNode != state.selectedNode do out.dataSelection = -1
	if out.dataSelection >= len(out.project.data) do out.dataSelection = -1
	// The inspector shows a theme chosen in the browser, the same way
	if out.browserSelection != state.browserSelection && out.browserSelection.kind == .Asset &&
	   out.browserSelection.index < len(out.project.assets) && out.project.assets[out.browserSelection.index].kind == .Theme {
		out.themeSelection = Project_FindTheme(&out.project, out.project.assets[out.browserSelection.index].path)
	}
	if out.selectedNode >= 0 && out.selectedNode != state.selectedNode do out.themeSelection = -1
	if out.themeSelection >= len(out.project.themes) do out.themeSelection = -1
	// And a physics material
	if out.browserSelection != state.browserSelection && out.browserSelection.kind == .Asset &&
	   out.browserSelection.index < len(out.project.assets) && out.project.assets[out.browserSelection.index].kind == .PhysicsMaterial {
		out.materialSelection = Project_FindMaterial(&out.project, out.project.assets[out.browserSelection.index].path)
	}
	if out.browserSelection != state.browserSelection && !(out.browserSelection.kind == .Asset && out.browserSelection.index < len(out.project.assets) &&
	   out.project.assets[out.browserSelection.index].kind == .PhysicsMaterial) && out.browserSelection.kind != .None {
		out.materialSelection = -1
	}
	if out.selectedNode >= 0 && out.selectedNode != state.selectedNode do out.materialSelection = -1
	if out.materialSelection >= len(out.project.materials) do out.materialSelection = -1
	// A dialogue chosen in the browser shows in the Dialogue tab (dialogue_edit.odin)
	if out.browserSelection != state.browserSelection && out.browserSelection.kind == .Asset &&
	   out.browserSelection.index < len(out.project.assets) && out.project.assets[out.browserSelection.index].kind == .Dialogue {
		path := out.project.assets[out.browserSelection.index].path
		if path != out.dialogue.path {
			delete(out.dialogue.path)
			out.dialogue = {path = strings.clone(path), node = 0, step = -1}
		}
	}
	// An LDtk project chosen in the browser is the world the Level mode shows (level_mode.odin)
	if out.browserSelection != state.browserSelection && out.browserSelection.kind == .Asset &&
	   out.browserSelection.index < len(out.project.assets) && out.project.assets[out.browserSelection.index].kind == .LDtk {
		path := out.project.assets[out.browserSelection.index].path
		if path != out.level.file {
			delete(out.level.file)
			out.level.file = strings.clone(path)
			delete(out.level.level)
			out.level.level = ""
			Mode_Save(&out)
		}
	}
	// And an atlas (atlas_edit.odin)
	if out.browserSelection != state.browserSelection && out.browserSelection.kind == .Asset &&
	   out.browserSelection.index < len(out.project.assets) && out.project.assets[out.browserSelection.index].kind == .Atlas {
		out.atlasSelection = Project_FindAtlas(&out.project, out.project.assets[out.browserSelection.index].path)
	}
	if out.browserSelection != state.browserSelection && !(out.browserSelection.kind == .Asset && out.browserSelection.index < len(out.project.assets) &&
	   out.project.assets[out.browserSelection.index].kind == .Atlas) && out.browserSelection.kind != .None {
		out.atlasSelection = -1
	}
	if out.selectedNode >= 0 && out.selectedNode != state.selectedNode do out.atlasSelection = -1
	if out.atlasSelection >= len(out.project.atlases) do out.atlasSelection = -1
	// A bus opened from the Mixer: until a node or something in the browser is chosen
	if (out.selectedNode >= 0 && out.selectedNode != state.selectedNode) || (out.browserSelection != state.browserSelection && out.browserSelection.kind != .None) do out.busSelection = -1
	if out.busSelection >= len(out.project.buses) do out.busSelection = -1
	// What belongs to the Scene mode shows it (editor_modes.odin): another scene opened, a node
	// selected, a code tab picked (CodeTabs_Open shows the mode itself). Undo and redo go to
	// their step's own mode (history.odin); a project opened, to the mode it was left in
	if out.mode != .Scene && !isUndoRedo(m) && out.session.opened == state.session.opened {
		if out.currentScene != state.currentScene || (out.selectedNode >= 0 && out.selectedNode != state.selectedNode) || (out.codeTab > 0 && out.codeTab != state.codeTab) {
			Mode_Set(&out, .Scene)
		}
	}
	// A code tab picked hides the slicer (slicer_edit.odin)
	if out.codeTab > 0 && out.codeTab != state.codeTab do out.slicer.shown = 0
	// Anything that opens another scene shows it (not a code tab, not the slicer), in its tab
	if out.currentScene != state.currentScene {
		out.codeTab = 0
		out.slicer.shown = 0
		if out.currentScene >= 0 && out.currentScene < len(out.project.scenes) do out.project.scenes[out.currentScene].tabClosed = false
	}
	// A structural edit renumbers nodes: the old multi-selection is meaningless unless the edit
	// chose a new one. Then make the selection agree with selectedNode (selection.odin)
	if (info.scope == .Scene || info.scope == .Project) && !out.selectionSet do clear(&out.selection)
	Selection_Normalize(&out)
	if snap != nil do History_Commit(&out, snap, time.tick_now())
	return out, command
}

// What `update` remembers of the State before a message, to see what the message changed
@(private="file")
Update_Before :: struct {
	selectedNode, currentScene, codeTab: int,
	browserSelection: BrowserItem,
	session: struct { opened: int },
}

// Undo or Redo (they restore their step's mode themselves)
@(private="file")
isUndoRedo :: proc(m: Msg) -> bool {
	a, isAction := m.(Action)
	return isAction && (a == .Undo || a == .Redo)
}

@(private="file")
applyMsg :: proc(out: ^State, m: Msg) -> skald.Command(Msg) {
	// The open project's log points (read when the project changes: log_points.odin)
	LogPoints_Follow(out)
	if command, handled := ContextMenu_Update(out, m); handled do return command
	// Switching modes, and the Level mode's messages (before the LDtk ones: a level picked on the
	// browser's world map selects it there while the Level mode shows)
	if command, handled := Modes_Update(out, m); handled do return command
	if Particles_Update(out, m) do return {}
	if command, handled := LevelMode_Update(out, m); handled do return command
	if Console_Update(out, m) do return {}
	if ViewportTools_Update(out, m) do return {}
	if command, handled := SettingsDialog_Update(out, m); handled do return command
	if command, handled := Session_Update(out, m); handled do return command
	if command, handled := ProjectArchive_Update(out, m); handled do return command
	if command, handled := Git_Update(out, m); handled do return command
	if command, handled := LDtkEdit_Update(out, m); handled do return command
	if command, handled := AsepriteEdit_Update(out, m); handled do return command
	if command, handled := TileMapEdit_Update(out, m); handled do return command
	if TilePaint_Update(out, m) do return {}
	if command, handled := Timeline_Update(out, m); handled do return command
	if UIEdit_Update(out, m) do return {}
	if LightEdit_Update(out, m) do return {}
	if TouchEdit_Update(out, m) do return {}
	if command, handled := NodeScripts_Update(out, m); handled do return command
	if command, handled := AssetImport_Update(out, m); handled do return command
	if AtlasEdit_Update(out, m) do return {}
	if SkeletonEdit_Update(out, m) do return {}
	if DialogueEdit_Update(out, m) do return {}
	if command, handled := Plugins_Update(out, m); handled do return command
	if command, handled := ScriptIndex_Update(out, m); handled do return command
	if command, handled := CodeProviders_Update(out, m); handled do return command
	if command, handled := CodeColors_Update(out, m); handled do return command
	if command, handled := Docs_Update(out, m); handled do return command
	if command, handled := CodeActions_Update(out, m); handled do return command
	if CodeLive_Update(out, m) do return {}
	if LogPoints_Update(out, m) do return {}
	if command, handled := CodeDrag_Update(out, m); handled do return command
	if DialogueBoxEdit_Update(out, m) do return {}
	if LineEdit_Update(out, m) do return {}
	if command, handled := ShaderEdit_Update(out, m); handled do return command
	if NavEdit_Update(out, m) do return {}
	if Live_Update(out, m) do return {}
	if States_Update(out, m) do return {}
	if CameraTools_Update(out, m) do return {}
	if CameraEdit_Update(out, m) do return {}
	if SceneFlowEdit_Update(out, m) do return {}
	if ThemeEdit_Update(out, m) do return {}
	if MaterialEdit_Update(out, m) do return {}
	if TraceEdit_Update(out, m) do return {}
	if command, handled := ProjectSettings_Update(out, m); handled do return command
	if SceneSettings_Update(out, m) do return {}
	if command, handled := AnimEdit_Update(out, m); handled do return command
	if command, handled := Slicer_Update(out, m); handled do return command
	if command, handled := CodeTabs_Update(out, m); handled do return command
	if Mixer_Update(out, m) do return {}
	if BusEffects_Update(out, m) do return {}
	if MusicLayers_Update(out, m) do return {}
	// The shown mode's panel sizes (editor_modes.odin): the Scene mode's or the Level mode's
	layout := Mode_Layout(out)

	switch v in m {
	case Action:
		return handleAction(out, v)
	case Play_Tick:
		out.playTickPending = false
		cmd := playTick(out)
		return cmd
	case Export_Tick:
		return exportTick(out)
	case Export_Requested:
		return Export_Start(out, bit_set[ExportTarget](v))
	case Settings_Code_Editor_Path_Changed, Settings_Code_Editor_Args_Changed, Settings_Code_Editor_Browse,
	     Settings_Code_Editor_Picked, Settings_Optimized_Play_Changed, Settings_Hot_Reload_Changed, Settings_Wheel_Pans_Changed, Settings_Builtin_Editor_Changed, Settings_Auto_Close_Changed, Settings_OLS_Path_Changed, Settings_Odin_Path_Changed, Settings_LDtk_Path_Changed, Settings_Aseprite_Path_Changed, Settings_Audio_Device_Changed:
		// Handled by SettingsDialog_Update above
	case Node_Script_Added, Node_Script_Removed, Node_Script_Open:
		// Handled by NodeScripts_Update above
	case Asset_Filter_Changed, Asset_MSDF_Changed, Font_MSDF_Make_Requested, Audio_Convert_Requested, Audio_Converted:
		// Handled by AssetImport_Update above
	case Atlas_Created, Atlas_Image_Added, Atlas_Image_Removed, Atlas_Padding_Changed, Atlas_Filter_Changed, Atlas_Pack_Requested:
		// Handled by AtlasEdit_Update above
	case Skeleton_Setting_Changed, Skeleton_Bone_Added, Mesh_Made, Mesh_Bound:
		// Handled by SkeletonEdit_Update above
	case Dialogue_Changed, Dialogue_View, Dialogue_Created, DialogueBox_Setting_Changed:
		// Handled by DialogueEdit_Update and DialogueBoxEdit_Update above
	case Plugins_Tick, Plugin_Command_Run, Plugin_Row_Changed, Plugin_New_Requested, Plugins_Rebuild_Requested:
		// Handled by Plugins_Update above
	case ScriptIndex_Tick, ScriptIndex_Parsed:
		// Handled by ScriptIndex_Update above
	case Docs_Opened, Docs_Link_Clicked, Docs_Hit_Chosen, Docs_Back, Docs_Forward, Docs_Closed, Docs_Search_Changed, Docs_Open_On_Web:
		// Handled by Docs_Update above
	case Code_Usage_Opened, Code_Rename_Requested, NameTable_Loaded, EngineDocs_Loaded, Code_Hover_Audio, Code_Help_Requested:
		// Handled by CodeProviders_Update above
	case Code_Color_Requested, Code_Color_Changed, Code_Color_Hex_Changed, Code_Color_Alpha_Changed, Code_Color_Applied, Code_Color_Cancelled:
		// Handled by CodeColors_Update above
	case Code_Range_Requested, Code_Range_Field_Changed, Code_Range_Applied, Code_Range_Cancelled, Code_Field_Reveal_Requested, Script_Field_Declaration_Requested:
		// Handled by CodeActions_Update above
	case Code_Live_Watch, Code_Live_Picked, Code_Scrub_Changed, Code_Scrub_Write:
		// Handled by CodeLive_Update above
	case Log_Point_Dialog_Opened, Log_Point_Expression_Changed, Log_Point_Saved, Log_Point_Cancelled, Log_Point_Command, Log_Point_Refused:
		// Handled by LogPoints_Update above
	case Code_Drag_Pressed, Code_Drag_Started, Code_Drag_Cancelled, Code_Source_Dropped, Code_Drop_Chosen:
		// Handled by CodeDrag_Update above
	case Aseprite_Asset_Open_Requested, Aseprite_Layer_Toggled:
		// Handled by AsepriteEdit_Update above
	case TileMap_Setting_Changed:
		// Handled by TileMapEdit_Update above
	case Tile_Brush, Tile_Tool_Chosen, Tile_Brush_Chosen, Tile_Layer_Chosen, Tile_Terrain_Chosen, Tile_Tileset_Chosen, Tile_Brush_Turned, Tile_Layer_Added, Tile_Layer_Reverted:
		// Handled by TilePaint_Update above
	case Timeline_Changed, Timeline_View, Timeline_Tick, Timeline_Tick_Requested, Timeline_Key_Here:
		// Handled by Timeline_Update above
	case Nav_Setting_Changed:
		// Handled by NavEdit_Update above
	case Project_Settings_Transition_Changed, Project_Settings_Loading_Changed:
		// Handled by SceneFlowEdit_Update above
	case Camera_Tool_Changed:
		// Handled by CameraTools_Update above
	case Camera_Changed:
		// Handled by CameraEdit_Update above
	case SM_Changed, SM_View, States_Live_Watch:
		// Handled by States_Update above
	case Live_Command, Live_Selected, Live_Property_Edited:
		// Handled by Live_Update above
	case Light_Setting_Changed, Scene_Lighting_Changed, Touch_Setting_Changed, Line_Setting_Changed, Node_Shader_Changed, Node_Shader_Param_Changed, Shader_New_Requested:
		// Handled by LightEdit_Update above
	case UI_Setting_Changed, Theme_Field_Changed, Theme_Font_Changed, Theme_Created, Theme_Project_Set, Material_Field_Changed, Material_Created, Trace_Setting_Changed, Trace_Sprite_Chosen, Collision_Traced:
		// Handled by UIEdit_Update and ThemeEdit_Update above

	case Anim_Selected, Anim_Added, Anim_Duplicated, Anim_Removed, Anim_Moved, Anim_Name_Typed, Anim_Field_Changed,
	     Anim_Sheet_Texture_Changed, Anim_Sheet_Dropped, Anim_Grid_Mode_Changed, Anim_Asset_Shown, Anim_Set_From_Node, Anim_Set_New,
	     Anim_Loop_Changed, Anim_Mode_Changed, Anim_Autoplay_Set, Anim_Frame_Clicked, Anim_Durations_Toggled, Anim_Duration_Changed, Anim_Playback_Toggled,
	     Anim_Tick, Anim_Tick_Requested, Anim_Rects_Cleared:
		// Handled by AnimEdit_Update above
	case Slicer_Opened, Slicer_Tab_Selected, Slicer_Tab_Closed, Slicer_Changed, Slicer_Number_Changed, Slicer_Duration_Changed,
	     Slicer_Detected, Slicer_Tick, Slicer_Tick_Requested, Slicer_Asset_Created, Slicer_Applied, Slicer_Added_To_Scene:
		// Handled by Slicer_Update above
	case Input_New_Name_Changed, Input_Action_Added, Input_Defaults_Added, Input_Action_Selected, Input_Action_Removed,
	     Input_Action_Moved, Input_Action_Renamed, Input_Deadzone_Changed, Input_Binding_Added, Input_Binding_Removed,
	     Input_Capture_Started, Input_Capture_Cancelled, Input_Device_Changed:
		// Handled by ProjectSettings_Update above
	case Code_Tab_Selected, Code_Tab_Close_Requested, Code_Close_Chosen, Code_Open_Requested, Code_File_Edits_Requested, Code_Save_Requested,
	     Code_Tick_Requested, Code_Tick, Code_Focused, Code_Reloaded, Code_Disk_Chosen,
	     Code_Dialog_Requested, Code_Dialog_Picked:
		// Handled by CodeTabs_Update above
	case Bus_Added, Bus_Removed, Bus_Renamed, Bus_Volume_Changed, Bus_Pan_Changed, Bus_Mute_Toggled,
	     Bus_Effects_Opened, Bus_Effect_Added, Bus_Effect_Removed, Bus_Effect_Moved, Bus_Effect_Changed,
	     Music_Layer_Added, Music_Layer_Removed, Music_Layer_Changed:
		// Handled by Mixer_Update, BusEffects_Update and MusicLayers_Update above
	case Context_Menu_Opened, Context_Menu_Closed, Node_Command, Add_Node_Here, Paste_Here, Tab_Command,
	     File_Command, Log_Command, Script_Open_External, Asset_Add_To_Scene, Graph_Command, Align_Nodes,
	     Guide_Added, Guide_Moved, Guide_Removed, Guides_Cleared,
	     Text_Copied:
		// Handled by ContextMenu_Update and ViewportTools_Update above
	case Mode_Changed, Bottom_Tab_Picked, Level_File_Chosen, Level_Map_Clicked, Level_Scene_Opened, Level_Scene_Created,
	     Level_Canvas_Measured, Level_Canvas_Pressed, Level_Canvas_Moved, Level_Canvas_Released, Level_Canvas_Zoomed, Level_Canvas_Panned,
	     Level_Canvas_Fit, Level_Entity_Picked, Level_Collision_Kind_Changed, LDtk_Item_Picked, LDtk_Text_Typed,
	     LDtk_New_Name_Typed, LDtk_Def_Picked, LDtk_Edit, LDtk_Conflict_Chosen, Level_World_Chosen, Level_Row_Clicked, Level_Focus_Changed,
	     Level_Open_Showing, Level_Layer_Picked, Level_Tool_Picked, LDtk_Disk_Chosen,
	     Level_Value_Picked, Level_Tiles_Picked, Level_Entity_Type_Picked, Level_Pick_Started, Rules_View,
	     Level_Spot_Started, Level_Depth_Shown, Level_Rename_Started, Level_Field_Focused, Level_Size_Typed:
		// Handled by Modes_Update and LevelMode_Update above
	case Log_Follow_Toggled, Log_Follow_Set, Log_Level_Toggled, Log_Category_Toggled,
	     Log_Categories_Shown, Log_Search_Changed, Log_Filters_Cleared, Log_Test_Lines:
		// Handled by Console_Update above
	case Audio_Field_Changed:
		node := selectedNode(out)
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
		node := selectedNode(out)
		if node == nil || !isSoundKind(node.kind) do break
		switch v.flag {
		case .Loop:      node.audio.loop = v.value
		case .Autostart: node.audio.autostart = v.value
		}
	case Audio_Preview_Requested:
		node := selectedNode(out)
		if !bool(v) || node == nil || node.sound == "" {
			AudioPreview_Stop()
			break
		}
		path := joinPath(out.project.rootPath, node.sound, allocator = context.temp_allocator)
		if !AudioPreview_IsLoaded(path) {
			if message := AudioPreview_Load(path); message != "" {
				logLine(out, .Warning, fmt.aprintf("Preview: %s", message))
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
		logLine(out, .Info, fmt.aprintf("%s is %s now", filepath.base(asset.path), v.kind == .Music ? "music (streamed)" : "a sound"))
		if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(out, .Warning, strings.clone(message))
	case Toolchain_Install_Requested:
		if out.toolchainInstalling do break
		out.toolchainInstalling = true
		logLine(out, .Info, fmt.aprintf("Installing Odin %s (about 70 MB)...", ODIN_VERSION))
		return Toolchain_InstallOdin()
	case Toolchain_Emscripten_Requested:
		if out.emscriptenInstalling do break
		out.emscriptenInstalling = true
		Mode_ShowLogTab(out, .Output)
		Mode_Layout(out).bottomOpen = true
		logLine(out, .Info, fmt.aprintf("Installing Emscripten %s for web exports (about 1 GB, a few minutes; once per machine) into %s...", EMSDK_VERSION, Toolchain_DataDir()))
		return Toolchain_InstallEmscripten()
	case Toolchain_Emscripten_Finished:
		out.emscriptenInstalling = false
		waiting := out.exportAfterEmscripten
		out.exportAfterEmscripten = {}
		if v.problem != "" {
			logLine(out, .Error, fmt.aprintf("Installing Emscripten failed: %s", v.problem))
			delete(v.problem)
			break
		}
		logLine(out, .Info, fmt.aprintf("Installed Emscripten %s", EMSDK_VERSION))
		// The export that asked for it goes on
		if waiting != {} do return Export_Start(out, waiting)
	case Toolchain_Install_Finished:
		out.toolchainInstalling = false
		if v.problem != "" {
			logLine(out, .Error, fmt.aprintf("Installing Odin failed: %s", v.problem))
			delete(v.problem)
		} else {
			logLine(out, .Info, fmt.aprintf("Installed Odin %s: %s", ODIN_VERSION, v.path))
			delete(v.path)
		}
	case Open_Keyboard_Settings:
		SettingsDialog_Open(out)
		out.settingsDialog.tab = .Keyboard
	case Open_Grid_Settings:
		ProjectSettings_Open(out, .Grid)

	case Scripts_Auto_Build:
		if out.scriptsAutoBuilt do break
		out.scriptsAutoBuilt = true
		return scriptsBuild(out)
	case Node_Script_Changed:
		node := selectedNode(out)
		if node == nil do break
		name := string(v) == TEXTURE_NONE ? "" : string(v)
		if name == node.script do break
		// None: the next of its more scripts becomes the first (node_scripts_edit.odin)
		if name == "" {
			NodeDef_RemoveFirstScript(node)
			logLine(out, .Info, fmt.aprintf("Removed the script from %s", node.name))
			break
		}
		// One of its more scripts chosen as the first: it isn't there twice
		for extra, i in node.moreScripts do if extra.name == name {
			delete(extra.name)
			Props_Destroy(&node.moreScripts[i].props)
			ordered_remove(&node.moreScripts, i)
			break
		}
		delete(node.script)
		node.script = strings.clone(name)
		// Values belonged to the old script
		for prop in node.props { delete(prop.name); delete(prop.value) }
		clear(&node.props)
		logLine(out, .Info, name == "" ? fmt.aprintf("Removed the script from %s", node.name) : fmt.aprintf("Attached %s to %s", name, node.name))
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
			logLine(out, .Error, fmt.aprintf("New data resource: %s", problem))
			break
		}
		out.newData.open = false
		out.session.assetsChanged = true
		out.browserOpen[.Data] = true
		out.dataSelection = index
		for asset, i in out.project.assets do if asset.path == out.project.data[index].path do out.browserSelection = {kind = .Asset, folder = .Data, index = i}
		if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(out, .Warning, strings.clone(message))
		logLine(out, .Info, fmt.aprintf("Created %s (%s)", out.project.data[index].path, out.project.data[index].type))
	case Script_Prop_Changed:
		switch t in v.target {
		case SelectedNodeTarget:
			if node := selectedNode(out); node != nil do NodeDef_SetScriptValue(node, v.name, v.value, v.defaultValue)
		case DraftGlobalTarget:
			globals := &out.projectSettings.globals
			if int(t) >= 0 && int(t) < len(globals) do Props_Set(&globals[t].props, v.name, v.value, v.defaultValue)
		case DataTarget:
			if int(t) >= 0 && int(t) < len(out.project.data) do Props_Set(&out.project.data[t].values, v.name, v.value, v.defaultValue)
		case NodeScriptTarget:
			if node := selectedNode(out); node != nil && int(t) >= 0 && int(t) < len(node.moreScripts) do Props_Set(&node.moreScripts[t].props, v.name, v.value, v.defaultValue)
		case NodeCustomTarget:
			if node := selectedNode(out); node != nil do Props_Set(&node.customProps, v.name, v.value, v.defaultValue)
		}
	case Script_Open_File:
		return Script_Open(out, v.file, v.line)
	case Editor_Process_Check:
		return Editor_CheckProcesses(out)
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
			logLine(out, .Error, fmt.aprintf("New script: %s", message))
			break
		}
		out.newScript.open = false
		Scripts_Refresh(out)
		logLine(out, .Info, fmt.aprintf("Created %s", file))
		switch kind {
		case .Node:
			// Attach it to the selected node, open it, and build so its fields show up
			if node := selectedNode(out); node != nil {
				delete(node.script)
				node.script = strings.clone(name)
			}
		case .Global:
			// Runs for the whole game from the next Play (Project Settings > Globals lists it)
			append(&out.project.globals, GlobalDef{script = strings.clone(name)})
		case .Data:
		}
		path, line := Script_Location(out, name)
		// The index reads it now: the Script section's rows don't move under the pointer later
		ScriptIndex_ReadNow(out, path)
		return skald.cmd_batch(Script_Open(out, path, line), scriptsBuild(out))

	case Project_Settings_Name_Changed, Project_Settings_Scale_Changed, Project_Settings_Renderer_Changed, Project_Settings_Texture_Filter_Changed, Project_Settings_Background_Changed,
	     Project_Settings_Start_Changed, Project_Settings_Locale_Changed, Project_Settings_Icon_Changed, Project_Settings_Size_Changed, Project_Settings_Applied, Project_Settings_Cancelled,
	     Project_Settings_Tab_Changed, Export_Target_Selected, Export_Target_Enabled, Export_Text_Changed, Export_Flag_Changed,
	     Export_Target_Run, Export_Cancel_Requested, Project_Settings_Physics_Changed, Project_Settings_Physics_Debug_Changed,
	     Project_Settings_Physics_Smoothing_Changed, Project_Settings_Window_Changed, Project_Settings_Grid_Changed, Project_Settings_Audio_Changed, Scene_Screen_Layer_Toggled, Scene_Background_Changed,
	     Scene_Gravity_Toggled, Scene_Gravity_Changed, Global_Added, Global_Removed, Global_Selected, Global_Moved,
	     Steam_Setting_Changed, Steam_Achievement_Added, Steam_Achievement_Removed, Players_Setting_Changed:
		// Handled by ProjectSettings_Update above
	case Scene_Action:
		return Scene_DoAction(out, v)
	case Browser_Focus_Changed:
		out.browserFocused = bool(v)
	case Browser_Right_Clicked:
		// Select the row (without opening a scene), so the context menu acts on it
		rows := BrowserRows(out)
		out.browserSelection = int(v) >= 0 && int(v) < len(rows) ? rows[v] : BrowserItem{kind = .None}
	case Confirm_Chosen, New_Project_Name_Changed, New_Project_Location_Changed, New_Project_Browse,
	     New_Project_Location_Chosen, New_Project_Created, New_Project_Cancelled, Open_Project_Chosen,
	     Recent_Project_Chosen, Recent_Projects_Cleared:
		// Handled by Session_Update above
	case Project_Archive_Path_Chosen, Project_Archive_Open_Chosen, Project_Archive_Destination_Chosen,
	     Project_Archive_Written, Project_Archive_Extracted:
		// Handled by ProjectArchive_Update above
	case LDtk_Setting_Changed, LDtk_Level_Picked, LDtk_Open_Requested, LDtk_Asset_Open_Requested:
		// Handled by LDtkEdit_Update above
	case Git_Refresh_Requested, Git_Snapshot_Read, Git_Op_Requested, Git_Op_Finished, Git_Message_Changed, Git_Diff_Requested, Git_Diff_Read, Git_Discard_Asked,
	     Git_New_Branch_Changed, Git_Remote_URL_Changed:
		// Handled by Git_Update above
	case Settings_Tab_Changed, Settings_Theme_Changed, Settings_Value_Changed, Settings_Search_Changed,
	     Settings_Theme_Color_Changed, Settings_Theme_Color_Reset, Settings_Theme_Preset_Chosen,
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
		return nextViewportTick(&out.viewport)
	case Viewport_Tick_Requested:
		if out.viewport.tickPending do break
		out.viewport.tickPending = true
		out.viewport.nextTick = time.tick_now()
		return nextViewportTick(&out.viewport)
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
		return importChosen(out, skald.File_Dialog_Result(v))

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
			if out.currentScene == component do openScene(out, Project_FirstScene(&out.project))
			if out.currentScene > component do out.currentScene -= 1
			History_SceneRemoved(&out.history, component)
		}
		if message := Project_RemoveAsset(&out.project, index, v.deleteFile); message != "" {
			logLine(out, .Error, fmt.aprintf("%s", message))
		} else {
			logLine(out, .Info, fmt.aprintf("%s %s%s", v.deleteFile ? "Deleted" : "Removed", name,
				usage > 0 ? fmt.tprintf(" (still used by %d node%s)", usage, usage == 1 ? "" : "s") : ""))
		}
		out.browserSelection = {kind = .None}
		if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(out, .Warning, strings.clone(message))
	case Asset_Remove_Cancelled:
		out.removeConfirm = {}

	case Rename_Started:
		startRename(out, int(v))
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
				logLine(out, .Error, fmt.aprintf("Can't rename %s: %s", old, message))
			} else if old != strings.trim_space(out.rename.text) {
				out.session.assetsChanged = true
				logLine(out, .Info, fmt.aprintf("Renamed component %s to %s (%d instance%s updated)", old, strings.trim_space(out.rename.text), references, references == 1 ? "" : "s"))
				if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(out, .Warning, strings.clone(message))
			}
			delete(out.rename.text)
			out.rename = {}
			break
		}
		if out.rename.active && out.rename.target == .Scene {
			Scene_CommitRename(out)
			delete(out.rename.text)
			out.rename = {}
			break
		}
		scene := &out.project.scenes[out.currentScene]
		index, text := out.rename.node, strings.trim_space(out.rename.text)
		if out.rename.active && index >= 0 && index < len(scene.nodes) && text != "" && text != scene.nodes[index].name {
			logLine(out, .Info, fmt.aprintf("Renamed %s to %s", scene.nodes[index].name, text))
			if isBodyKind(scene.nodes[index].kind) do Scene_RenameJointReferences(scene, scene.nodes[index].name, text)
			// Stored paths (cameras' targets, script node fields...) keep leading to the same nodes
			paths := NodePaths_Resolve(scene, &out.scripts)
			delete(scene.nodes[index].name)
			scene.nodes[index].name = strings.clone(text)
			NodePaths_Repath(scene, paths)
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
		if apply := NumberEdit_Update(out, v); apply != nil do return applyMsg(out, apply)
	case Number_Edit_Ended:
		if out.numberEdit.id == skald.Widget_ID(v) {
			delete(out.numberEdit.text)
			out.numberEdit = {}
		}
	case About_Closed:
		out.aboutOpen = false
	case About_Link_Opened:
		About_OpenLink(string(v))
	case Manual_Opened:
		Docs_Navigate(&out.docs, Docs_ManualAddress(string(v)))
	case Frame_Requested:
	case Quit_Without_Asking:
		playStop(out)
		Export_Cancel(out)
		return skald.cmd_quit(Msg)

	case Asset_Drag_Pressed:
		out.assetDrag = {pressed = true, asset = v.asset, start = v.start}
	case Asset_Drag_Started:
		out.assetDrag.active = true
	case Asset_Drag_Cancelled:
		out.assetDrag = {}
	case Asset_Dropped_On_Code:
		asset := out.assetDrag.asset
		out.assetDrag = {}
		// Where it lands decides what goes in (code_drops.odin)
		message, added := CodeEditor_Drop(out, CodeTabs_Active(out), v.mouse, DropSource{kind = .Asset, node = -1, index = asset}, v.menu)
		if message != "" do logLine(out, added ? .Info : .Warning, strings.clone(message))
	case Asset_Dropped:
		asset := out.assetDrag.asset
		out.assetDrag = {}
		if asset >= 0 && asset < len(out.project.assets) && out.project.assets[asset].kind == .Component {
			addInstance(out, out.project.assets[asset].path, v.world)
			break
		}
		// An animation asset: an AnimatedSprite playing it
		if asset >= 0 && asset < len(out.project.assets) && out.project.assets[asset].kind == .Animation {
			path := out.project.assets[asset].path
			scene := &out.project.scenes[out.currentScene]
			index := Scene_AddAnimatedSpriteAt(scene, path, out.selectedNode, v.world)
			out.selectedNode = index
			logLine(out, .Info, fmt.aprintf("Added %s, playing %s", scene.nodes[index].name, filepath.base(path)))
			break
		}
		if asset >= 0 && asset < len(out.project.assets) && out.project.assets[asset].kind == .LDtk {
			index := Scene_AddLDtkAt(&out.project.scenes[out.currentScene], out.project.assets[asset].path, out.selectedNode, v.world)
			out.selectedNode = index
			logLine(out, .Info, fmt.aprintf("Added %s, a level of %s", out.project.scenes[out.currentScene].nodes[index].name, filepath.base(out.project.assets[asset].path)))
			break
		}
		if asset < 0 || asset >= len(out.project.assets) || out.project.assets[asset].kind != .Image do break
		// An Aseprite file with tilemap layers: a TileMap of them
		if path := out.project.assets[asset].path; TileMapEdit_HasTilemaps(out.project.rootPath, path) {
			index := Scene_AddTileMapAt(&out.project.scenes[out.currentScene], path, out.selectedNode, v.world)
			out.selectedNode = index
			logLine(out, .Info, fmt.aprintf("Added %s, the tilemaps of %s", out.project.scenes[out.currentScene].nodes[index].name, filepath.base(path)))
			break
		}
		index := Scene_AddSpriteAt(&out.project.scenes[out.currentScene], out.project.assets[asset].path, out.selectedNode, v.world)
		out.selectedNode = index
		logLine(out, .Info, fmt.aprintf("Added %s", out.project.scenes[out.currentScene].nodes[index].name))

	case Add_Node_Search_Changed:
		delete(out.addNode.search)
		out.addNode.search = strings.clone(string(v))
		out.addNode.highlight = 0
	case Add_Node_Highlight_Moved:
		count := len(AddNode_Entries(out.addNode.search, &out.scripts))
		if count > 0 do out.addNode.highlight = clamp(out.addNode.highlight + int(v), 0, count - 1)
	case Add_Node_Confirmed:
		entries := AddNode_Entries(out.addNode.search, &out.scripts)
		if out.addNode.highlight < len(entries) do addNodeChosen(out, entries[out.addNode.highlight].kind, entries[out.addNode.highlight].custom)
	case Add_Node_Kind_Chosen:
		addNodeChosen(out, NodeKind(v))
	case Add_Node_Type_Chosen:
		if t := ScriptCatalog_FindNodeType(&out.scripts, string(v)); t != nil do addNodeChosen(out, t.base, t.name)
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
		drag := ViewportDrag{mode = v.mode, node = v.node, startMouse = v.mouse, current = v.mouse, additive = v.additive, localAxes = out.viewport.localAxes}
		if v.mode != .Pan && v.mode != .Box && v.mode != .Zoom_Box {
			scene := &out.project.scenes[out.currentScene]
			if v.node < 0 || v.node >= len(scene.nodes) do break
			// Alt+drag: the selection (the node with it) is duplicated, and the copies are dragged
			if v.duplicate {
				if !Selection_Contains(out, v.node) {
					clear(&out.selection)
					out.selectedNode = v.node
					Selection_Normalize(out)
				}
				roots := slice.clone(Selection_Roots(out), context.temp_allocator)
				at := slice_index(roots, v.node)
				if at < 0 do break
				copies := Scene_DuplicateNodes(scene, roots)
				Selection_Set(out, copies, copies[at])
				drag.node = copies[at]
				drag.duplicated = true
			}
			v := v
			v.node = drag.node
			// Keeps a multi-selection that includes it (they move together)
			out.selectedNode = v.node
			if Selection_Contains(out, v.node) do out.selectionSet = true
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
		if drag.mode == .Box || drag.mode == .Zoom_Box {
			drag.current = v.mouse
			break
		}
		if drag.mode == .None || drag.mode == .Pan || drag.node < 0 || drag.node >= len(scene.nodes) do break
		before := scene.nodes[drag.node]
		grid: [2]f32
		if out.viewport.snap do grid = {f32(out.project.grid.size.x), f32(out.project.grid.size.y)}
		Viewport_ApplyDrag(&scene.nodes[drag.node], drag, v.mouse, v.constrain, grid, out.settings.rotateSnap, out.settings.scaleSnap)
		// Snapping on: the origin also snaps to the scene's guides, within a few pixels
		if out.viewport.snap && (drag.mode == .Move || drag.mode == .Move_X || drag.mode == .Move_Y) && len(scene.guides) > 0 && !out.viewport.guidesHidden {
			Guides_SnapNode(scene, drag.node, GUIDE_SNAP_PIXELS / max(out.viewport.zoom, VIEWPORT_MIN_ZOOM), drag.mode)
		}
		// The rest of the selection follows
		if len(out.selection) > 1 && Selection_Contains(out, drag.node) {
			Viewport_FollowDrag(scene, drag.node, before, Selection_Roots(out))
			out.selectionSet = true
		}
	case Viewport_Drag_End:
		if out.viewport.drag.mode == .Box do boxSelect(out, out.viewport.drag)
		if out.viewport.drag.mode == .Zoom_Box do ViewportTools_ZoomBox(&out.viewport, out.viewport.drag)
		out.viewport.drag = {}

	// Panel sizes. Splits report the size of their first pane; sidebars and the bottom panel
	// are stored as their own size so they stay put when the window resizes
	case Left_Resized:
		layout.leftWidth = max(f32(v), MIN_SIDEBAR_WIDTH)
	case Center_Resized:
		left, _ := FittedSidebarWidths(layout)
		// The Level mode's sidebars have their own rules (level_mode.odin)
		if out.mode == .Level do left, _, _ = LevelMode_Sidebars(layout)
		rest := layout.workspace.x - left - DIVIDER
		layout.rightWidth = max(rest - f32(v) - DIVIDER, MIN_SIDEBAR_WIDTH)
	case Viewport_Resized:
		layout.bottomHeight = max(layout.workspace.y - f32(v) - DIVIDER, MIN_BOTTOM_HEIGHT)
	case Scene_Tree_Resized:
		out.layout.sceneTreeHeight = max(f32(v), MIN_SCENE_TREE_HEIGHT)
	case Workspace_Measured:
		// Every mode's workspace is the same area
		for mode in EditorMode do Mode_LayoutOf(out, mode).workspace = cast([2]f32)v

	case Bottom_Tab_Changed:
		// A tab only another mode has shows that mode (editor_modes.odin)
		Mode_ShowBottomTab(out, BottomTab(int(v)))
		// What git says may have changed since it was read
		if BottomTab(int(v)) == .Git do return Git_Refresh(out)
	case Scene_Tab_Changed:
		out.codeTab = 0
		out.slicer.shown = 0
		tabs := ViewportTabScenes(out)
		if int(v) >= 0 && int(v) < len(tabs) do openScene(out, tabs[v])
	case Scene_Tab_Closed:
		tabs := ViewportTabScenes(out)
		if int(v) < 0 || int(v) >= len(tabs) || len(tabs) < 2 do break
		// A component with unsaved changes asks first (a scene stays in the project: its changes
		// are saved with it)
		if Scene_IsComponent(&out.project.scenes[tabs[v]]) && Scene_IsDirty(out, tabs[v]) {
			out.componentClose = {open = true, scene = tabs[v]}
			break
		}
		closeSceneTab(out, tabs[v])
	case Component_Close_Chosen:
		index := out.componentClose.scene
		out.componentClose = {}
		if index < 0 || index >= len(out.project.scenes) || !Scene_IsComponent(&out.project.scenes[index]) do break
		scene := &out.project.scenes[index]
		switch ConfirmChoice(v) {
		case .Save:
			if message := Project_WriteComponent(&out.project, scene); message != "" {
				logLine(out, .Error, strings.clone(message))
				break
			}
			logLine(out, .Info, fmt.aprintf("Saved %s", scene.component))
			closeSceneTab(out, index)
		case .Discard:
			// Back to its file; its undo steps go (they'd undo into what was thrown away)
			reloaded, problem := Project_LoadComponent(out.project.rootPath, scene.component)
			if problem != "" {
				SceneDef_Destroy(&reloaded)
				logLine(out, .Error, strings.clone(problem))
				break
			}
			for &node in scene.nodes do NodeDef_Destroy(&node)
			delete(scene.nodes)
			scene.nodes = reloaded.nodes
			delete(reloaded.name)
			delete(reloaded.component)
			Scene_MarkSaved(scene)
			History_DropScene(&out.history, index)
			if index == out.currentScene do out.selectedNode = -1
			logLine(out, .Info, fmt.aprintf("%s: changes thrown away", scene.component))
			closeSceneTab(out, index)
		case .Cancel:
		}
	case Listener_Dialog_Opened:
		delete(out.listenerDialog.event)
		out.listenerDialog = {open = true, node = v.node, event = strings.clone(v.event)}
	case Listener_Dialog_Cancelled:
		out.listenerDialog.open = false
	case Listener_Target_Chosen:
		message, attached := Listener_Attach(out, int(v))
		out.listenerDialog.open = false
		logLine(out, attached ? .Info : .Warning, strings.clone(message))
	case Listener_Removed:
		scene := &out.project.scenes[out.currentScene]
		if v.node < 0 || v.node >= len(scene.nodes) || v.index < 0 || v.index >= len(scene.nodes[v.node].listeners) do break
		l := scene.nodes[v.node].listeners[v.index]
		delete(l.event); delete(l.target); delete(l.handler); delete(l.global)
		ordered_remove(&scene.nodes[v.node].listeners, v.index)
	case Inspector_Events_Toggled:
		out.inspectorEventsOpen = !out.inspectorEventsOpen
	case LDtk_Instances_Toggled:
		out.ldtkInstancesOpen = !out.ldtkInstancesOpen
	case LDtk_Entity_Framed:
		out.viewport.center = cast([2]f32)v
	case Global_Listen_Requested:
		message, attached := Listener_Connect(out, v.node, v.node, v.event, v.global)
		logLine(out, attached ? .Info : .Warning, strings.clone(message))
	case New_Event_Opened:
		NewEventDialog_Destroy(&out.newEvent)
		out.newEvent = {open = true, script = strings.clone(string(v)), name = strings.clone("on"), description = strings.clone("")}
	case New_Event_Name_Changed:
		delete(out.newEvent.name)
		out.newEvent.name = strings.clone(string(v))
	case New_Event_Description_Changed:
		delete(out.newEvent.description)
		out.newEvent.description = strings.clone(string(v))
	case New_Event_Kind_Changed:
		out.newEvent.kind = EventDataKind(v)
	case New_Event_Cancelled:
		out.newEvent.open = false
	case New_Event_Created:
		message, added := NewEvent_Insert(out)
		if added do out.newEvent.open = false
		logLine(out, added ? .Info : .Warning, strings.clone(message))
	case Script_Usage_Clicked:
		if v.scene < 0 || v.scene >= len(out.project.scenes) || v.node < 0 || v.node >= len(out.project.scenes[v.scene].nodes) do break
		if Scene_IsComponent(&out.project.scenes[v.scene]) do out.project.scenes[v.scene].opened = true
		openScene(out, v.scene)
		out.selectedNode = v.node
	case Component_Opened:
		if int(v) < 0 || int(v) >= len(out.project.scenes) || !Scene_IsComponent(&out.project.scenes[v]) do break
		out.project.scenes[v].opened = true
		openScene(out, int(v))
	case Component_Rename_Started:
		if int(v) < 0 || int(v) >= len(out.project.assets) || out.project.assets[v].kind != .Component do break
		delete(out.rename.text)
		out.rename = {active = true, target = .Component, node = int(v), text = strings.clone(ComponentName(out.project.assets[v].path))}
		out.browserSelection = {kind = .Asset, folder = .Components, index = int(v)}
		out.browserOpen[.Components] = true
	case Component_Made_Unique:
		old := ""
		if node := selectedNode(out); node != nil do old = strings.clone(ComponentName(node.component), context.temp_allocator)
		path, message := Scene_MakeInstanceUnique(&out.project, out.currentScene, out.selectedNode)
		if message != "" {
			logLine(out, .Error, fmt.aprintf("Can't make it unique: %s", message))
			break
		}
		out.session.assetsChanged = true
		logLine(out, .Info, fmt.aprintf("This instance has its own copy of %s now: %s", old, path))
		if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(out, .Warning, strings.clone(message))
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
		addInstance(out, out.project.assets[v].path, world)
	case Tool_Selected:
		out.tool = Tool(v)

	case Browser_Toggled:
		rows := BrowserRows(out)
		if int(v) < len(rows) && rows[v].kind == .Folder {
			out.browserOpen[rows[v].folder] = !out.browserOpen[rows[v].folder]
		}
	case Browser_Selected:
		rows := BrowserRows(out)
		if int(v) >= len(rows) do break
		item := rows[v]
		out.browserSelection = item
		switch item.kind {
		case .Folder:
			out.browserOpen[item.folder] = !out.browserOpen[item.folder]
		case .Scene:
			openScene(out, item.index)
		case .Asset:
			selectAsset(out, item.index)
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
		if int(v) >= 0 do Selection_Toggle(out, int(v))
	case Node_Pick_Added:
		if int(v) >= 0 && !Selection_Contains(out, int(v)) do Selection_Toggle(out, int(v))
	case Node_Primary_Picked:
		out.selectedNode = int(v)
		out.selectionSet = true
	case Tree_Selection_Clicked:
		rows := SceneTreeRows(&out.project.scenes[out.currentScene])
		if v.row < 0 || v.row >= len(rows) do break
		node := rows[v.row]
		if !v.range || out.selectedNode < 0 {
			Selection_Toggle(out, node)
			break
		}
		// Shift: every row between the primary node's row and this one
		from := v.row
		for r, i in rows do if r == out.selectedNode do from = i
		nodes := make([dynamic]int, context.temp_allocator)
		append(&nodes, ..out.selection[:])
		for i in min(from, v.row)..=max(from, v.row) do append(&nodes, rows[i])
		Selection_Set(out, nodes[:], node)
	case Node_Right_Clicked:
		// On a node of a multi-selection the menu acts on all of them; elsewhere, just that node
		rows := SceneTreeRows(&out.project.scenes[out.currentScene])
		node := int(v) >= 0 && int(v) < len(rows) ? rows[v] : -1
		if node >= 0 && Selection_Contains(out, node) {
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
	case Tree_Drag_Dropped_On_Code:
		node := out.treeDrag.node
		out.treeDrag = {}
		// Where it lands decides what goes in (code_drops.odin)
		scene := &out.project.scenes[out.currentScene]
		name := node >= 0 && node < len(scene.nodes) ? scene.nodes[node].name : ""
		message, added := CodeEditor_Drop(out, CodeTabs_Active(out), v.mouse, DropSource{kind = .Node, name = name, node = node, index = -1}, v.menu)
		if message != "" do logLine(out, added ? .Info : .Warning, strings.clone(message))
	case Tree_Drag_Dropped:
		scene := &out.project.scenes[out.currentScene]
		node := out.treeDrag.node
		out.treeDrag = {}
		if node < 0 || node >= len(scene.nodes) do break
		name := scene.nodes[node].name
		if index, moved := Scene_MoveNode(scene, node, v.target, v.position, &out.scripts); moved {
			out.selectedNode = index
			out.viewport.drag = {}
			parent := scene.nodes[index].parent
			logLine(out, .Info, parent >= 0 ? fmt.aprintf("Moved %s into %s", name, scene.nodes[parent].name) : fmt.aprintf("Moved %s to the top level", name))
		}

	case Node_Renamed:
		if node := selectedNode(out); node != nil {
			// Joints follow a renamed body
			if isBodyKind(node.kind) do Scene_RenameJointReferences(&out.project.scenes[out.currentScene], node.name, string(v))
			// Stored paths (cameras' targets, script node fields...) keep leading to the same nodes
			paths := NodePaths_Resolve(&out.project.scenes[out.currentScene], &out.scripts)
			// Msg strings only live for the frame (see Skald's gotchas), so keep a copy
			delete(node.name)
			node.name = strings.clone(string(v))
			NodePaths_Repath(&out.project.scenes[out.currentScene], paths)
		}
	case Node_Visibility_Changed:
		if node := selectedNode(out); node != nil do node.visible = bool(v)
	case Inspector_Link_Toggled:
		out.inspectorLinks[LinkedPair(v)] = !out.inspectorLinks[LinkedPair(v)]
	// The selected emitter's, else the Particles tab's (particles_edit.odin)
	case Particle_Field_Changed:
		if node, _ := Particles_Target(out); node != nil do e.ParticleSettings_Set(&node.particles, v.name, v.value)
	case Particle_Axis_Changed:
		node, _ := Particles_Target(out)
		if node == nil || v.axis < 0 || v.axis > 1 do break
		ParticleSettings_SetAxis(&node.particles, v.name, v.axis, v.value, ParticleField_Index(v.name) in out.particleLinks)
	case Particle_Link_Toggled:
		if int(v) >= 0 && int(v) < 64 do out.particleLinks ~= {int(v)}
	case Particles_Reset:
		node, _ := Particles_Target(out)
		if node == nil do break
		node.particles = e.DEFAULT_PARTICLE_SETTINGS
		delete(node.texture)
		node.texture = strings.clone("")
	case Ramp_Edited:
		node, _ := Particles_Target(out)
		if node == nil do break
		if e.ParticleSettings_Set(&node.particles, "colorRamp", v.text) do out.rampStop = v.selected
	case Particles_Category_Picked, Particles_Tab_Opened, Particles_Restart, Particles_Preset_Applied:
		// Particles_Update (particles_edit.odin), above
	case Ramp_Stop_Selected:
		out.rampStop = int(v)
	case Ramp_Drag_Changed:
		out.rampDrag = skald.Widget_ID(v)
	case Node_Field_Changed:
		node := selectedNode(out)
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
		case .Nine_Width:      node.nineSize.x = max(value, 0)
		case .Nine_Height:     node.nineSize.y = max(value, 0)
		}
	case Node_Text_Changed:
		node := selectedNode(out)
		if node == nil do break
		// Msg strings only live for the frame, so keep copies
		switch v.field {
		case .Text:
			delete(node.text)
			node.text = strings.clone(v.value)
		case .Texture:
			delete(node.texture)
			node.texture = strings.clone(v.value == TEXTURE_NONE ? "" : v.value)
			// An atlas: its first region (a Sprite draws one); another picture: none
			if node.kind == .Sprite {
				regions := Atlas_RegionNames(&out.project, node.texture)
				delete(node.region)
				node.region = strings.clone(len(regions) > 0 ? regions[0] : "")
			}
		case .Color:
			if color, ok := e.ParseColor(v.value); ok do node.color = color
		case .Sound:
			delete(node.sound)
			node.sound = strings.clone(v.value == TEXTURE_NONE ? "" : v.value)
		case .Material:
			delete(node.material)
			node.material = strings.clone(v.value == MATERIAL_NONE ? "" : v.value)
		case .Bus:
			delete(node.bus)
			node.bus = strings.clone(v.value == e.MASTER_BUS ? "" : v.value)
		case .Component:
			path := v.value == TEXTURE_NONE ? "" : v.value
			current := &out.project.scenes[out.currentScene]
			if path != "" && Component_Contains(&out.project, path, current.component) {
				logLine(out, .Warning, fmt.aprintf("%s holds %s: an instance of it can't go inside it", ComponentName(path), current.name))
				break
			}
			delete(node.component)
			node.component = strings.clone(path)
		case .Autoplay:
			delete(node.autoplay)
			node.autoplay = strings.clone(v.value == ANIMATION_FIRST ? "" : v.value)
		case .Pivot_Slice:
			delete(node.pivotSlice)
			node.pivotSlice = strings.clone(v.value == SLICE_NONE ? "" : v.value)
		case .Nine_Slice:
			delete(node.nineSlice)
			node.nineSlice = strings.clone(v.value == SLICE_NONE ? "" : v.value)
		case .Region:
			delete(node.region)
			node.region = strings.clone(v.value == REGION_NONE ? "" : v.value)
		case .Slice:
			delete(node.slice)
			node.slice = strings.clone(v.value == SLICE_NONE ? "" : v.value)
			// A slice's rectangle: the shape is a rectangle
			if node.slice != "" do node.shape = .Rectangle
		case .Animation_Set:
			delete(node.animationSet)
			node.animationSet = strings.clone(v.value == ANIMATION_OWN ? "" : v.value)
			// Its own animations again: at least one
			if node.animationSet == "" && len(node.animations) == 0 do append(&node.animations, AnimationDef_Default())
			// The panel follows the sprite
			delete(out.animEditor.asset)
			out.animEditor.asset = strings.clone("")
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
		node := selectedNode(out)
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
		case .Effect_Screen_Layers: node.effectScreenLayers = v.value
		}
	case Node_Layer_Toggled:
		node := selectedNode(out)
		if node == nil || v.layer < 1 || v.layer > 64 do break
		bits := v.mask ? &node.collisionMask : &node.collisionLayer
		bits^ ~= 1 << u64(v.layer - 1)
	case Node_Points_Changed:
		// Keep the typed text (like a number field), apply it when every point reads
		delete(out.numberEdit.text)
		out.numberEdit = {id = v.id, text = strings.clone(v.text)}
		node := selectedNode(out)
		points, ok := e.ParsePoints(v.text)
		if node == nil || !ok do break
		clear(&node.points)
		append(&node.points, ..points)
	}
	return {}
}

@(private="file")
handleAction :: proc(out: ^State, action: Action) -> skald.Command(Msg) {
	// With the browser focused, Delete, Ctrl+D/C/X/V and F2 act on its selected scene
	if sceneAction, routed := Browser_RouteAction(out, action); routed {
		return Scene_DoAction(out, sceneAction)
	}
	switch action {
	case .Quit:
		return Session_Request(out, .Quit)
	case .New_Project:
		return Session_Request(out, .New_Project)
	case .Open_Project:
		return Session_Request(out, .Open_Project)
	case .Save_Project_As:
		Session_OpenSaveAs(out)
	case .Open_Project_Archive:
		return Session_Request(out, .Open_Project_Archive)
	case .Export_Project_Archive:
		return ProjectArchive_Export(out)
	case .Export_Project_Archive_With_History:
		return ProjectArchive_Export(out, includeGit = true)

	case .Save_Project:
		// Saved scripts are built again in the background: the inspector learns new fields
		scripts := CodeTabs_AnyDirty(out)
		if Session_Save(out) && scripts do return scriptsBuildQuietly(out)
	case .Play:
		cmd := playStart(out)
		return cmd
	case .Play_Scene:
		if Scene_IsComponent(&out.project.scenes[out.currentScene]) {
			logLine(out, .Warning, strings.clone("A component can't play on its own: play a scene that has an instance of it"))
			break
		}
		return playStart(out, out.project.scenes[out.currentScene].name)
	case .Save_As_Component:
		name := out.selectedNode >= 0 && out.selectedNode < len(out.project.scenes[out.currentScene].nodes) ? strings.clone(out.project.scenes[out.currentScene].nodes[out.selectedNode].name, context.temp_allocator) : ""
		index, message := Scene_SaveBranchAsComponent(&out.project, out.currentScene, out.selectedNode)
		if message != "" {
			logLine(out, .Error, fmt.aprintf("Can't save as a component: %s", message))
			break
		}
		out.session.assetsChanged = true
		clear(&out.selection)
		logLine(out, .Info, fmt.aprintf("Saved %s as component %s; it's an instance of it now", name, out.project.scenes[index].component))
		if message := Scripts_WriteAssetsFile(&out.project); message != "" do logLine(out, .Warning, strings.clone(message))
	case .Open_Project_Settings:
		ProjectSettings_Open(out)
	case .Pause:
		playPause(out)
	case .Stop:
		playStop(out)
	case .Restart:
		return playRestart(out)

	case .Add_Node:
		// Opens the dialog; the node is added when a kind is picked
		delete(out.addNode.search)
		out.addNode = {open = true}
	// These act on every selected node (the selection's roots: see selection.odin)
	case .Duplicate_Node:
		roots := Selection_Roots(out)
		if len(roots) == 0 do break
		scene := &out.project.scenes[out.currentScene]
		primary := slice_index(roots, out.selectedNode)
		copies := Scene_DuplicateNodes(scene, roots)
		Selection_Set(out, copies, primary >= 0 ? copies[primary] : -1)
		logLine(out, .Info, fmt.aprintf("Duplicated %s", describeNodes(scene, copies)))
	case .Copy_Node, .Cut_Node:
		roots := Selection_Roots(out)
		if len(roots) == 0 do break
		scene := &out.project.scenes[out.currentScene]
		Subtree_Destroy(&out.clipboard)
		out.clipboard = Scene_CopyNodes(scene, roots)
		names := describeNodes(scene, roots)
		if action == .Copy_Node {
			logLine(out, .Info, fmt.aprintf("Copied %s", names))
			break
		}
		logLine(out, .Info, fmt.aprintf("Cut %s", names))
		Scene_RemoveNodes(scene, roots)
		out.selectedNode = -1
		out.viewport.drag = {}
	case .Paste_Node:
		if len(out.clipboard) == 0 {
			logLine(out, .Info, strings.clone("Nothing to paste: copy a node first"))
			break
		}
		// Into the selected node, like Add Node
		scene := &out.project.scenes[out.currentScene]
		parent := selectedNode(out) != nil ? out.selectedNode : -1
		roots := Scene_PasteNodes(scene, out.clipboard[:], parent)
		Selection_Set(out, roots, roots[0])
		logLine(out, .Info, fmt.aprintf("Pasted %s", describeNodes(scene, roots)))
	case .Select_All:
		scene := &out.project.scenes[out.currentScene]
		all := make([]int, len(scene.nodes), context.temp_allocator)
		for &n, i in all do n = i
		if len(all) > 0 do Selection_Set(out, all, out.selectedNode >= 0 ? out.selectedNode : 0)
	case .Toggle_Grid:
		out.viewport.gridVisible = !out.viewport.gridVisible
	case .Toggle_Collision_Shapes:
		out.viewport.showShapes = !out.viewport.showShapes
	case .Toggle_Lighting:
		out.viewport.unlit = !out.viewport.unlit
	case .Toggle_Physics_Debug:
		// A project setting (undoable, saved with the project); exports turn it off. It flips
		// what the toolbar shows: a running game's shapes (F9 may have changed them there), which
		// the project then agrees with, and the game too, over the live link
		on := !PhysicsDebug_Shown(out)
		out.project.physics.debugDraw = on
		sent := Live_SetShapes(out, on)
		message := on ? "The game shows its collision shapes (not in exports; F9 toggles them while playing)" : "The game hides its collision shapes (F9 shows them while playing)"
		if sent do message = on ? "The game shows its collision shapes, now and when played (not in exports)" : "The game hides its collision shapes, now and when played"
		logLine(out, .Info, strings.clone(message))
	case .Toggle_Snap:
		out.viewport.snap = !out.viewport.snap

	case .Delete_Node:
		roots := Selection_Roots(out)
		if len(roots) == 0 do break
		scene := &out.project.scenes[out.currentScene]
		logLine(out, .Info, fmt.aprintf("Deleted %s", describeNodes(scene, roots)))
		Scene_RemoveNodes(scene, roots)
		out.selectedNode = -1
		out.viewport.drag = {}

	case .Toggle_Bottom_Panel:
		Mode_Layout(out).bottomOpen = !Mode_Layout(out).bottomOpen
	case .Clear_Console:
		// Clears whichever log tab is showing
		LogList_Clear(logListOf(out, Mode_BottomTab(out) == .Output))

	case .Tool_Select: out.tool = .Select
	case .Tool_Move:   out.tool = .Move
	case .Tool_Rotate: out.tool = .Rotate
	case .Tool_Scale:  out.tool = .Scale
	case .Tool_Pan:    out.tool = .Pan
	case .Tool_Transform: out.tool = .Transform
	case .Tool_Zoom:   out.tool = .Zoom
	case .Toggle_Local_Axes:
		out.viewport.localAxes = !out.viewport.localAxes
	case .Toggle_Guides:
		out.viewport.guidesHidden = !out.viewport.guidesHidden

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
		for root in Selection_Roots(out) {
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
		// Several files at once, from where the last ones came from
		return skald.cmd_open_file_dialog(filters[:], importDialogResult,
			default_location = FixedText_String(&out.settings.importFolder), allow_many = true)
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
		shapes := out.project.physics.debugDraw
		if label, ok := History_Undo(out); ok {
			logLine(out, .Info, fmt.aprintf("Undo: %s", label))
		} else {
			logLine(out, .Info, strings.clone("Nothing to undo"))
		}
		// The game's collision shapes follow an undone toggle (Toggle_Physics_Debug)
		if out.project.physics.debugDraw != shapes do Live_SetShapes(out, out.project.physics.debugDraw)
	case .Redo:
		shapes := out.project.physics.debugDraw
		if label, ok := History_Redo(out); ok {
			logLine(out, .Info, fmt.aprintf("Redo: %s", label))
		} else {
			logLine(out, .Info, strings.clone("Nothing to redo"))
		}
		if out.project.physics.debugDraw != shapes do Live_SetShapes(out, out.project.physics.debugDraw)
	case .Rename_Node:
		startRename(out, out.selectedNode)
	case .Build_Scripts:
		Scripts_Refresh(out)
		return scriptsBuild(out)
	case .Add_Script:
		// From the scene tree's menu: a node without a script gets New Script (a node script)
		node := selectedNode(out)
		if node == nil do break
		if node.script != "" {
			path, line := Script_Location(out, node.script)
			return Script_Open(out, path, line)
		}
		delete(out.newScript.name)
		out.newScript = {open = true, name = strings.clone(""), kind = .Node}
	case .Open_Script:
		node := selectedNode(out)
		if node == nil || node.script == "" {
			logLine(out, .Info, strings.clone("The selected node has no script"))
			break
		}
		path, line := Script_Location(out, node.script)
		return Script_Open(out, path, line)
	case .Close_Code_Tab:
		if out.codeTab > 0 do return skald.cmd_now(Msg(Code_Tab_Close_Requested(out.codeTab - 1)))
		// The slicer's tab closes the same way
		if out.slicer.shown > 0 do Slicer_Close(out, out.slicer.shown - 1)
	case .Mode_Scene, .Mode_Level:
		// Modes_Update switches (editor_modes.odin)
	case .Level_Flip_X, .Level_Flip_Y, .Level_Random_Mode, .Level_Toggle_Grid, .Level_Single_Layer, .Level_Tile_Stacking,
	     .Level_Auto_Layers, .Level_Delete, .Level_Duplicate, .Level_Cancel, .Level_World_Mode,
	     .Level_Depth_Further, .Level_Depth_Closer, .Level_Move_Further, .Level_Move_Closer, .Level_Select_All, .Level_Empty_Space, .Level_Save_Tile_Selection,
	     .Level_Panel_Project, .Level_Panel_Layers, .Level_Panel_Entities, .Level_Panel_Enums, .Level_Panel_Tilesets, .Level_Panel_Level, .Level_Layer_1, .Level_Layer_2, .Level_Layer_3, .Level_Layer_4, .Level_Layer_5, .Level_Layer_6, .Level_Layer_7, .Level_Layer_8, .Level_Layer_9, .Level_Layer_10:
		// LevelMode_Update handles them (level_paint.odin)
	case .Open_Settings:
		SettingsDialog_Open(out)
	case .Export:
		enabled: bit_set[ExportTarget]
		for t, target in out.project.exports.targets do if t.enabled do enabled += {target}
		return Export_Start(out, enabled)
	case .About:
		out.aboutOpen = true
	case .User_Manual:
		Docs_Navigate(&out.docs, Docs_HelpAddress(out, docsPointerPanel))
	}
	return {}
}

// Shows another scene in the viewport, clearing the selection
// Closes a scene's or component's viewport tab (the scene stays in the project); the tab that
// shows closes and its neighbour shows instead
closeSceneTab :: proc(state: ^State, index: int) {
	tabs := ViewportTabScenes(state)
	at := -1
	for t, i in tabs do if t == index do at = i
	if at < 0 || len(tabs) < 2 do return
	scene := &state.project.scenes[index]
	if Scene_IsComponent(scene) do scene.opened = false
	else do scene.tabClosed = true
	if index == state.currentScene {
		next := at + 1 < len(tabs) ? tabs[at + 1] : tabs[at - 1]
		state.codeTab = 0
		openScene(state, next)
	}
}

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

/*
The import dialog's files (one or several): each imported, sounds games can't play converted to Ogg
Vorbis first (asset_import_edit.odin); their folder is remembered for next time (Settings'
`importFolder`, written to editor.ini). The paths are the frame's (`importDialogResult`).
*/
importChosen :: proc(state: ^State, r: skald.File_Dialog_Result) -> skald.Command(Msg) {
	paths := r.paths
	if paths == nil && r.path != "" {
		single := make([]string, 1, context.temp_allocator)
		single[0] = r.path
		paths = single
	}
	if r.cancelled || len(paths) == 0 do return {}

	// Next time the dialog opens where these came from
	folder := filepath.dir(paths[0])
	if folder != FixedText_String(&state.settings.importFolder) {
		state.settings.importFolder = FixedText_Make(folder)
		if state.settingsPath != "" {
			if message := Settings_Save(&state.settings, state.settingsPath); message != "" do logLine(state, .Warning, fmt.aprintf("Couldn't remember the import folder: %s", message))
		}
	}

	commands := make([dynamic]skald.Command(Msg), context.temp_allocator)
	for path in paths {
		// A sound games can't play: converted to Ogg Vorbis first
		if Audio_NeedsConversion(path) {
			append(&commands, Audio_Convert(state, path, -1))
			continue
		}
		importAsset(state, path)
	}
	if len(paths) > 1 do logLine(state, .Info, fmt.aprintf("Imported %d files", len(paths)))
	if len(commands) == 0 do return {}
	command := commands[0]
	for c in commands[1:] do command = skald.cmd_batch(command, c)
	return command
}

// The import dialog's answer as a message: Skald's heap paths copied to the frame's memory (the
// message is handled this frame) and freed
@(private="file")
importDialogResult :: proc(r: skald.File_Dialog_Result) -> Msg {
	out := r
	if r.paths != nil {
		paths := make([]string, len(r.paths), context.temp_allocator)
		for p, i in r.paths {
			paths[i] = strings.clone(p, context.temp_allocator)
			delete(p)
		}
		delete(r.paths)
		out.paths, out.path = paths, paths[0]
	} else if r.path != "" {
		out.path = strings.clone(r.path, context.temp_allocator)
		delete(r.path)
	}
	return Asset_Import_Result(out)
}

// Imports a file and selects it in the browser
@(private="package")
importAsset :: proc(state: ^State, path: string) {
	// A plugin's importer takes its extensions first (plugin_host.odin)
	if handled, asset, problem := Plugins_Import(state, path); handled {
		if problem != "" {
			logLine(state, .Error, fmt.aprintf("Import failed: %s", problem))
			return
		}
		state.session.assetsChanged = true
		logLine(state, .Info, fmt.aprintf("Imported %s as %s (a plugin's importer)", filepath.base(path), asset))
		if message := Scripts_WriteAssetsFile(&state.project); message != "" do logLine(state, .Warning, strings.clone(message))
		for a, i in state.project.assets do if a.path == asset {
			state.browserOpen[AssetFolder(a.kind)] = true
			selectAsset(state, i)
		}
		return
	}
	// A Yarn Spinner file: a dialogue (dialogue_edit.odin), and what wasn't converted
	if Yarn_IsFile(path) {
		index, warnings, problem := Yarn_Import(&state.project, path)
		if problem != "" {
			logLine(state, .Error, fmt.aprintf("Import failed: %s", problem))
			return
		}
		state.session.assetsChanged = true
		for w in warnings do logLine(state, .Warning, fmt.aprintf("Yarn: %s", w))
		logLine(state, .Info, fmt.aprintf("Imported %s as %s", filepath.base(path), state.project.assets[index].path))
		if message := Scripts_WriteAssetsFile(&state.project); message != "" do logLine(state, .Warning, strings.clone(message))
		state.browserOpen[.Dialogues] = true
		selectAsset(state, index)
		return
	}
	// A DragonBones skeleton: a component and an atlas (skeleton_edit.odin), and what wasn't converted
	if DragonBones_IsSkeleton(path) {
		index, warnings, problem := DragonBones_Import(&state.project, path)
		if problem != "" {
			logLine(state, .Error, fmt.aprintf("Import failed: %s", problem))
			return
		}
		state.session.assetsChanged = true
		for w in warnings do logLine(state, .Warning, fmt.aprintf("DragonBones: %s", w))
		logLine(state, .Info, fmt.aprintf("Imported %s as %s (its atlas too)", filepath.base(path), state.project.assets[index].path))
		if message := Scripts_WriteAssetsFile(&state.project); message != "" do logLine(state, .Warning, strings.clone(message))
		state.browserOpen[.Components] = true
		selectAsset(state, index)
		return
	}
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
addNodeChosen :: proc(state: ^State, kind: NodeKind, custom := "") {
	if state.addNode.forComponent {
		state.addNode.open = false
		newComponent(state, kind, custom)
	} else {
		addNodeOfKind(state, kind, custom)
	}
}

// A new component with a root of `kind`, named after it, opened in its tab (New Component)
@(private="file")
newComponent :: proc(state: ^State, kind: NodeKind, custom := "") {
	index, message := Project_NewComponent(&state.project, custom != "" ? custom : fmt.tprint(kind), kind)
	if message != "" {
		logLine(state, .Error, fmt.aprintf("Couldn't make a component: %s", message))
		return
	}
	// A node type of the project's code: the root is one
	if custom != "" && len(state.project.scenes[index].nodes) > 0 do state.project.scenes[index].nodes[0].customKind = strings.clone(custom)
	state.session.assetsChanged = true
	state.project.scenes[index].opened = true
	openScene(state, index)
	state.selectedNode = 0
	logLine(state, .Info, fmt.aprintf("Made component %s (%s)", state.project.scenes[index].name, state.project.scenes[index].component))
	if message := Scripts_WriteAssetsFile(&state.project); message != "" do logLine(state, .Warning, strings.clone(message))
}

@(private="file")
addNodeOfKind :: proc(state: ^State, kind: NodeKind, custom := "") {
	index := AddNode_Create(state, kind, custom)
	state.addNode.open = false
	scene := &state.project.scenes[state.currentScene]
	// Asked for at a point (the viewport's Add Node Here): placed there, in its parent's space
	if at, ok := state.addNode.at.?; ok && index >= 0 && index < len(scene.nodes) {
		node := &scene.nodes[index]
		parentWorld := node.parent >= 0 ? Scene_WorldTransforms(scene)[node.parent] : e.TRANSFORM2D_IDENTITY
		local := e.Transform2D_Apply(e.Transform2D_Inverse(parentWorld), at)
		node.position = {math_tidy(local.x), math_tidy(local.y)}
	}
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
describeNodes :: proc(scene: ^SceneDef, nodes: []int) -> string {
	if len(nodes) == 1 do return scene.nodes[nodes[0]].name
	return fmt.tprintf("%d nodes", len(nodes))
}

// The index of `value` in `values`, -1 when it isn't there
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
